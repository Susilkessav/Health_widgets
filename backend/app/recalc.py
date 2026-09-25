"""Durable recalculation (Step 6-8 plan sections 6, 8.2 and 9).

A job is done only when its runs commit. All pending jobs for a user are
coalesced into one calculation at the highest target revision; readers order
results by input revision, so a slow older calculation never becomes latest.
"""
from __future__ import annotations

import logging
import time
from datetime import date, datetime, timedelta
from uuid import UUID

from sqlalchemy import func, select, update
from sqlalchemy.engine import Connection, Engine

from app import store
from app.config import Settings
from app.contracts._types import json_value, local_day_start, utc
from app.db import calculation_runs, coverage_declarations, lock_user, recalc_jobs, sync_requests, users
from app.engine import ENGINE_VERSION, compute_health_state
from app.features.calculate import calculate_features
from app.features.models import CalculationContext, CoverageWindow
from app.features.selection import local_date
from app.ingest import RECALC_WINDOW_DAYS
from app.presentation import PRESENTATION_VERSION, map_widget_state

log = logging.getLogger("homeostat.recalc")
BACKOFF_SECONDS = (30, 60, 120, 300, 600, 1800)


class BudgetExceeded(Exception):
    """The inline attempt ran out of time; the worker continues the job."""


def compute(conn: Connection, user_id: UUID, settings: Settings, revision: int, day: date, zone: str,
            effective_at: datetime, known_at: datetime):
    """One calculation from stored inputs: (report, state, widget)."""
    observations, coverage = store.load_inputs(conn, user_id, revision, day, zone, effective_at, settings)
    context = CalculationContext(day=day, timezone=zone, effective_at=utc(effective_at), known_at=utc(known_at),
                                 coverage=tuple(coverage))
    report = calculate_features(observations, context, settings)
    state = compute_health_state(report.features, settings)
    return report, state, map_widget_state(state)


def save(conn: Connection, user_id: UUID, kind: str, settings: Settings, revision: int, day: date, zone: str,
         effective_at: datetime, known_at: datetime, now: datetime, job_id: int | None):
    report, state, widget = compute(conn, user_id, settings, revision, day, zone, effective_at, known_at)
    digest = store.save_config_snapshot(conn, settings, now)
    run = {"kind": kind, "day": day, "timezone": zone, "effective_at": utc(effective_at), "known_at": utc(known_at),
           "input_revision": revision, "config_sha256": digest, "feature_version": report.features.version,
           "engine_version": ENGINE_VERSION, "presentation_version": PRESENTATION_VERSION, "job_id": job_id,
           "created_at": utc(now)}
    outputs = {"report": json_value(report), "state": json_value(state), "widget_state": json_value(widget),
               "input_sha256": report.input_sha256}
    return store.save_run(conn, user_id, run, outputs), state, widget


def revision_received_at(conn: Connection, user_id: UUID, revision: int) -> datetime:
    return conn.execute(select(sync_requests.c.received_at).where(
        sync_requests.c.user_id == user_id, sync_requests.c.revision == revision)).scalar_one()


def days_for(from_day: date, known_at: datetime, zone: str) -> list[tuple[date, datetime, str]]:
    """(day, effective_at, kind): past days at their closing boundary, today at known_at."""
    today = local_date(known_at, zone)
    first = max(from_day, today - timedelta(days=RECALC_WINDOW_DAYS))
    result, day = [], first
    while day <= today:
        boundary = local_day_start(day + timedelta(days=1), zone)
        result.append((day, boundary, "finalize") if boundary <= utc(known_at) else (day, known_at, "sync"))
        day += timedelta(days=1)
    return result


def import_cutoff(conn: Connection, user_id: UUID, revision: int, day: date,
                  zone: str, known_at: datetime) -> datetime:
    """Use the common query cutoff for today's participating domains.

    Missing domains still fail coverage checks. Unavailable declarations also
    participate: moving the clock must never bypass a recovery warning. Past
    days retain their closing boundary. The chosen instant is saved in the run
    so exact replay doesn't depend on subsequently imported coverage.
    """
    start = local_day_start(day, zone)
    latest: dict[str, tuple[int, datetime]] = {}
    cd = coverage_declarations.c
    for row in conn.execute(select(coverage_declarations).where(cd.user_id == user_id, cd.revision <= revision)):
        window = CoverageWindow(**{key: getattr(row, key) for key in
                                  ("domain", "timezone", "status", "start_day", "end_day", "start_at", "end_at")})
        a, b = window.span()
        if b <= start or a >= known_at:
            continue
        previous = latest.get(row.domain)
        if previous is None or row.revision > previous[0]:
            latest[row.domain] = (row.revision, b)
        elif row.revision == previous[0]:
            latest[row.domain] = (row.revision, max(previous[1], b))
    return min([utc(known_at), *(end for _, end in latest.values())])


def process_user(engine: Engine, user_id: UUID, settings: Settings, now: datetime,
                 budget_seconds: float | None = None) -> bool:
    """Run all of a user's pending jobs as one calculation. True when published."""
    started = time.monotonic()
    job_ids: list[int] = []
    try:
        with engine.begin() as conn:
            lock_user(conn, user_id)
            jobs = conn.execute(select(recalc_jobs).where(recalc_jobs.c.user_id == user_id,
                                                          recalc_jobs.c.status == "pending")
                                .with_for_update(skip_locked=True)).all()
            if not jobs:
                return False
            job_ids = [job.id for job in jobs]
            revision = max(job.target_revision for job in jobs)
            known_at = max([revision_received_at(conn, user_id, revision),
                            *(job.created_at for job in jobs if job.kind == "finalize")])
            zone = conn.execute(select(users.c.timezone).where(users.c.id == user_id)).scalar_one()
            for day, effective_at, kind in days_for(min(job.from_day for job in jobs), known_at, zone):
                if budget_seconds is not None and time.monotonic() - started > budget_seconds:
                    raise BudgetExceeded()
                if kind == "sync":
                    effective_at = import_cutoff(conn, user_id, revision, day, zone, known_at)
                save(conn, user_id, kind, settings, revision, day, zone, effective_at, known_at, now, max(job_ids))
            conn.execute(update(recalc_jobs).where(recalc_jobs.c.id.in_(job_ids))
                         .values(status="done", completed_at=utc(now)))
        log.info("job", extra={"event": {"jobs": job_ids, "target_revision": revision, "outcome": "published",
                                         "milliseconds": round((time.monotonic() - started) * 1000)}})
        return True
    except BudgetExceeded:
        log.info("job", extra={"event": {"jobs": job_ids, "outcome": "deferred_to_worker"}})
        return False
    except Exception as error:  # the job stays pending; record the attempt and back off
        with engine.begin() as conn:
            for job_id in job_ids:
                attempts = conn.execute(select(recalc_jobs.c.attempts).where(recalc_jobs.c.id == job_id)).scalar_one()
                delay = BACKOFF_SECONDS[min(attempts, len(BACKOFF_SECONDS) - 1)]
                conn.execute(update(recalc_jobs).where(recalc_jobs.c.id == job_id).values(
                    attempts=attempts + 1, last_error_code=type(error).__name__,
                    next_attempt_at=utc(now) + timedelta(seconds=delay)))
        log.warning("job", extra={"event": {"jobs": job_ids, "outcome": "failed", "error": type(error).__name__}})
        return False


def due_users(engine: Engine, now: datetime) -> list[UUID]:
    with engine.connect() as conn:
        return list(conn.execute(select(recalc_jobs.c.user_id).where(
            recalc_jobs.c.status == "pending", recalc_jobs.c.next_attempt_at <= utc(now)).distinct()).scalars())


def sweep(engine: Engine, now: datetime) -> int:
    """Enqueue a finalize job for any user whose past days lack a closing-boundary
    run at their latest revision (so yesterday finalizes without an upload)."""
    enqueued = 0
    with engine.connect() as conn:
        candidates = list(conn.execute(select(users.c.id).where(users.c.revision > 0)).scalars())
    for user_id in candidates:
        with engine.begin() as conn:
            user = store.lock_user_row(conn, user_id)  # no upload can commit while we read the revision
            pending = conn.execute(select(func.count()).select_from(recalc_jobs).where(
                recalc_jobs.c.user_id == user_id, recalc_jobs.c.status == "pending")).scalar_one()
            if pending:
                continue
            today = local_date(now, user.timezone)
            # Start from the user's earliest calculated day (not a database
            # clock): days before any calculation have nothing to finalize.
            earliest = conn.execute(select(func.min(calculation_runs.c.day))
                                    .where(calculation_runs.c.user_id == user_id)).scalar_one()
            if earliest is None:
                continue
            first = max(today - timedelta(days=RECALC_WINDOW_DAYS), earliest)
            finalized = set(conn.execute(select(calculation_runs.c.day).where(
                calculation_runs.c.user_id == user_id, calculation_runs.c.input_revision == user.revision,
                calculation_runs.c.kind.in_(("finalize", "rebuild")), calculation_runs.c.day >= first)).scalars())
            missing = [first + timedelta(days=n) for n in range((today - first).days)
                       if first + timedelta(days=n) not in finalized]
            if missing:
                store.enqueue_job(conn, user_id, "finalize", user.revision, missing[0], now)
                enqueued += 1
    return enqueued


def run_pending(engine: Engine, settings: Settings, now: datetime) -> int:
    sweep(engine, now)
    return sum(process_user(engine, user_id, settings, now) for user_id in due_users(engine, now))
