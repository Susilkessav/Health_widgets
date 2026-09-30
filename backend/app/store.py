"""Database reads and writes. Every query is scoped to one user.

Stored provider versions are re-validated through the canonical contracts on
load, so what the calculator sees is exactly what a client sent.
"""
from __future__ import annotations

import hashlib
import json
from collections import defaultdict
from datetime import date, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from pydantic import TypeAdapter
from sqlalchemy import and_, func, or_, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.engine import Connection

from app.config import Settings, settings_payload, settings_sha256
from app.contracts._types import json_value, local_day_start, utc
from app.contracts.canonical_events import (
    CanonicalEvent,
    DailyActivitySnapshot,
    DeleteEvent,
    IntervalEvent,
    PointMeasurement,
    WorkoutEvent,
)
from app.db import (
    calculation_runs,
    config_snapshots,
    coverage_declarations,
    event_receipts,
    health_events,
    installation_records,
    recalc_jobs,
    run_outputs,
    sync_requests,
    users,
    visibility_scans,
)
from app.features.models import CalculationContext, CoverageWindow, Observation, VisibilityScan
from app.features.selection import _canonical, _withdrawn

EVENTS = TypeAdapter(CanonicalEvent)


def content_sha256(event: CanonicalEvent) -> str:
    """Identity of provider content: canonical JSON without the client event ID."""
    return hashlib.sha256(_canonical(event, with_id=False).encode()).hexdigest()


def identity(event: CanonicalEvent) -> tuple[str, str, str]:
    return (event.source, event.source_record_id, event.event_type)


def _times(event: CanonicalEvent) -> dict:
    if isinstance(event, PointMeasurement):
        return {"observed_at": utc(event.observed_at)}
    if isinstance(event, (IntervalEvent, WorkoutEvent)):
        return {"start_at": utc(event.start_at), "end_at": utc(event.end_at)}
    if isinstance(event, DailyActivitySnapshot):
        return {"observed_at": utc(event.as_of)}
    return {"observed_at": utc(event.deleted_at)}


# ---------------------------------------------------------------- users

def ensure_user(conn: Connection, user_id: UUID, timezone: str) -> None:
    conn.execute(insert(users).values(id=user_id, timezone=timezone).on_conflict_do_nothing())


def lock_user_row(conn: Connection, user_id: UUID):
    """Serializes ingestion for one user until this transaction ends."""
    return conn.execute(select(users).where(users.c.id == user_id).with_for_update()).one()


def next_revision(conn: Connection, user_id: UUID, now: datetime) -> tuple[int, datetime]:
    row = lock_user_row(conn, user_id)
    received_at = max(utc(now), utc(row.revision_received_at)) if row.revision_received_at else utc(now)
    revision = row.revision + 1
    conn.execute(update(users).where(users.c.id == user_id)
                 .values(revision=revision, revision_received_at=received_at))
    return revision, received_at


def set_timezone(conn: Connection, user_id: UUID, zone: str) -> None:
    conn.execute(update(users).where(users.c.id == user_id).values(timezone=zone))


def current_revision(conn: Connection, user_id: UUID) -> tuple[int, datetime | None, str]:
    row = conn.execute(select(users.c.revision, users.c.revision_received_at, users.c.timezone)
                       .where(users.c.id == user_id)).one()
    return row.revision, row.revision_received_at, row.timezone


# ---------------------------------------------------------------- requests and receipts

def body_sha256(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def find_request(conn: Connection, user_id: UUID, request_id: UUID):
    return conn.execute(select(sync_requests).where(sync_requests.c.user_id == user_id,
                                                    sync_requests.c.request_id == request_id)).one_or_none()


def save_request(conn: Connection, user_id: UUID, request_id: UUID, body_hash: str, revision: int | None,
                 received_at: datetime, counts: dict, response: dict) -> None:
    conn.execute(insert(sync_requests).values(
        user_id=user_id, request_id=request_id, body_sha256=body_hash, revision=revision,
        received_at=received_at, status_counts=counts, response=response))


def find_receipt(conn: Connection, user_id: UUID, event_id: UUID):
    return conn.execute(select(event_receipts).where(event_receipts.c.user_id == user_id,
                                                     event_receipts.c.event_id == event_id)).one_or_none()


def save_receipt(conn: Connection, user_id: UUID, event_id: UUID, payload_hash: str, request_id: UUID,
                 received_at: datetime, outcome: str, code: str | None, version_id: int | None) -> None:
    conn.execute(insert(event_receipts).values(
        user_id=user_id, event_id=event_id, payload_sha256=payload_hash, first_request_id=request_id,
        first_received_at=received_at, outcome=outcome, code=code, health_event_id=version_id))


# ---------------------------------------------------------------- provider versions

def find_version(conn: Connection, user_id: UUID, key: tuple[str, str, str], payload_hash: str) -> int | None:
    source, record_id, event_type = key
    return conn.execute(select(health_events.c.id).where(
        health_events.c.user_id == user_id, health_events.c.source == source,
        health_events.c.source_record_id == record_id, health_events.c.event_type == event_type,
        health_events.c.payload_sha256 == payload_hash)).scalar_one_or_none()


def identity_exists(conn: Connection, user_id: UUID, key: tuple[str, str, str]) -> bool:
    source, record_id, event_type = key
    return conn.execute(select(func.count()).select_from(health_events).where(
        health_events.c.user_id == user_id, health_events.c.source == source,
        health_events.c.source_record_id == record_id, health_events.c.event_type == event_type)).scalar_one() > 0


def find_tombstone(conn: Connection, user_id: UUID, source: str, record_id: str) -> int | None:
    return conn.execute(select(health_events.c.id).where(
        health_events.c.user_id == user_id, health_events.c.event_type == "delete",
        health_events.c.source == source, health_events.c.source_record_id == record_id)
        .order_by(health_events.c.id).limit(1)).scalar_one_or_none()


def insert_version(conn: Connection, user_id: UUID, event: CanonicalEvent, payload_hash: str, revision: int,
                   received_at: datetime) -> int:
    return conn.execute(insert(health_events).values(
        user_id=user_id, source=event.source, source_record_id=event.source_record_id,
        event_type=event.event_type, payload_sha256=payload_hash, payload=json_value(event),
        revision=revision, received_at=received_at, **_times(event)).returning(health_events.c.id)).scalar_one()


def version_days(conn: Connection, user_id: UUID, source: str, record_id: str, zone: str) -> list[date]:
    """Local days of the stored versions a tombstone removes (for affected days)."""
    rows = conn.execute(select(health_events.c.observed_at, health_events.c.start_at).where(
        health_events.c.user_id == user_id, health_events.c.source == source,
        health_events.c.source_record_id == record_id, health_events.c.event_type != "delete"))
    return [utc(row.start_at or row.observed_at).astimezone(ZoneInfo(zone)).date() for row in rows]


# ---------------------------------------------------------------- coverage and jobs

def insert_coverage(conn: Connection, user_id: UUID, windows: list[CoverageWindow], revision: int,
                    received_at: datetime) -> None:
    if windows:
        conn.execute(insert(coverage_declarations), [
            {"user_id": user_id, "domain": w.domain, "start_day": w.start_day, "end_day": w.end_day,
             "start_at": w.start_at, "end_at": w.end_at, "timezone": w.timezone, "status": w.status,
             "revision": revision, "received_at": received_at}
            for w in windows])


def insert_scans(conn: Connection, user_id: UUID, scans: list[dict], revision: int, received_at: datetime,
                 installation_id: UUID | None = None) -> int:
    """Stores completed scans; a scan ID already stored keeps its first version.
    Returns how many were new."""
    if not scans:
        return 0
    rows = conn.execute(insert(visibility_scans).values([
        {"user_id": user_id, "scan_id": scan["scan_id"], "installation_id": installation_id, "healthkit_type": scan["healthkit_type"],
         "scope_start_at": utc(scan["scope_start_at"]), "scope_end_at": scan.get("scope_end_at"), "members": sorted(scan["members"]), "revision": revision,
         "received_at": received_at} for scan in scans])
        .on_conflict_do_nothing(constraint="uq_visibility_scan").returning(visibility_scans.c.id)).all()
    return len(rows)


def load_visibility(conn: Connection, user_id: UUID, revision: int) -> list[VisibilityScan]:
    """Only the newest scan per type and scope start can govern a record, but
    older ones still decide records received between scans, so all are loaded."""
    vs = visibility_scans.c
    return [VisibilityScan(installation_id=r.installation_id, healthkit_type=r.healthkit_type, scope_start_at=r.scope_start_at,
                           members=tuple(r.members), revision=r.revision, scope_end_at=r.scope_end_at)
            for r in conn.execute(select(visibility_scans).where(vs.user_id == user_id, vs.revision <= revision)
                                  .order_by(vs.id))]


def installation_seen(conn, user_id, installation_id, event) -> bool:
    ir = installation_records.c
    return conn.execute(select(ir.id).where(ir.user_id == user_id, ir.installation_id == installation_id,
        ir.source == event.source, ir.source_record_id == event.source_record_id).limit(1)).first() is not None


def has_scans(conn, user_id, healthkit_type) -> bool:
    vs = visibility_scans.c
    return conn.execute(select(vs.id).where(vs.user_id == user_id, vs.healthkit_type == healthkit_type)
                        .limit(1)).first() is not None


def record_installation(conn, user_id, installation_id, event, revision):
    conn.execute(insert(installation_records).values(user_id=user_id, installation_id=installation_id,
        source=event.source, source_record_id=event.source_record_id, revision=revision).on_conflict_do_nothing())


def installation_memberships(conn, user_id, revision):
    ir = installation_records.c
    result = defaultdict(dict)
    for row in conn.execute(select(ir.source, ir.source_record_id, ir.installation_id, func.max(ir.revision).label("revision"))
                            .where(ir.user_id == user_id, ir.revision <= revision)
                            .group_by(ir.source, ir.source_record_id, ir.installation_id)):
        result[(row.source, row.source_record_id)][str(row.installation_id)] = row.revision
    return result


def enqueue_job(conn: Connection, user_id: UUID, kind: str, revision: int, from_day: date, now: datetime) -> int:
    return conn.execute(insert(recalc_jobs).values(
        user_id=user_id, kind=kind, target_revision=revision, from_day=from_day, next_attempt_at=utc(now),
        created_at=utc(now)).returning(recalc_jobs.c.id)).scalar_one()


# ---------------------------------------------------------------- calculation inputs (plan section 8.1)

def input_range(day: date, zone: str, effective_at: datetime, settings: Settings) -> tuple[datetime, datetime]:
    """Derived from settings: the baseline or workout-total lookback, one more
    day for the previous evening's sleep window, and the recency window."""
    lookback = max(settings.baseline.window_days, settings.workout.totals_days) + 1
    margin = timedelta(hours=max(settings.workout.recent_hours, 24))
    return local_day_start(day - timedelta(days=lookback), zone) - margin, utc(effective_at)


def _observations(rows, memberships=None) -> list[Observation]:
    return [Observation(event=EVENTS.validate_python(row.payload), delivered_at=row.received_at, revision=row.revision,
                        installations=tuple(sorted((memberships or {}).get((row.source, row.source_record_id), {}).items())))
            for row in rows]


def load_inputs(conn: Connection, user_id: UUID, revision: int, day: date, zone: str, effective_at: datetime,
                settings: Settings) -> tuple[list[Observation], list[CoverageWindow]]:
    start, end = input_range(day, zone, effective_at, settings)
    memberships = installation_memberships(conn, user_id, revision)
    scans = tuple(load_visibility(conn, user_id, revision))
    scan_context = CalculationContext(day=day, timezone=zone, effective_at=effective_at, known_at=effective_at, visibility=scans)
    scan_members = {id(scan): set(scan.members) for scan in scans}
    he = health_events.c
    visible = and_(he.user_id == user_id, he.revision <= revision)
    in_range = or_(
        and_(he.start_at.is_(None), he.observed_at >= start, he.observed_at <= end),   # points, snapshots
        and_(he.start_at.is_not(None), he.end_at >= start, he.start_at <= end),        # intervals, workouts
    )
    rows = {row.id: row for row in conn.execute(select(health_events).where(visible, in_range, he.event_type != "delete"))}
    # Every tombstone, whenever it arrived: deleting old samples must still apply.
    rows |= {row.id: row for row in conn.execute(select(health_events).where(visible, he.event_type == "delete"))}
    # The latest older workout that isn't deleted or conflicted, plus anything
    # overlapping it: features retain the last workout however old it is.
    deleted = {(r.source, r.source_record_id) for r in rows.values() if r.event_type == "delete"}
    older = conn.execute(select(health_events).where(visible, he.event_type == "workout", he.end_at < start)
                         .order_by(he.end_at.desc(), he.id)).all()
    versions = defaultdict(set)
    for row in older:
        versions[(row.source, row.source_record_id)].add(row.payload_sha256)
    for row in older:
        if (row.source, row.source_record_id) in deleted or len(versions[(row.source, row.source_record_id)]) > 1:
            continue
        event = EVENTS.validate_python(row.payload)
        if _withdrawn(event, row.revision, scan_context, scan_members,
                      memberships.get((row.source, row.source_record_id))):
            continue
        rows |= {r.id: r for r in conn.execute(select(health_events).where(
            visible, he.event_type == "workout", he.end_at > row.start_at, he.end_at < start))}
        break
    # Every version of each loaded identity, whatever its date, so a conflict
    # is never half-loaded.
    keys = {(r.source, r.source_record_id, r.event_type) for r in rows.values() if r.event_type != "delete"}
    for source, record_id, event_type in keys:
        rows |= {r.id: r for r in conn.execute(select(health_events).where(
            visible, he.source == source, he.source_record_id == record_id, he.event_type == event_type))}
    first_day = (start - timedelta(days=1)).date()
    cd = coverage_declarations.c
    overlapping = or_(
        and_(cd.start_day.is_not(None), cd.end_day >= first_day, cd.start_day <= day + timedelta(days=1)),
        and_(cd.start_at.is_not(None), cd.end_at >= start - timedelta(days=1), cd.start_at <= end),
    )
    coverage = [
        CoverageWindow(domain=r.domain, start_day=r.start_day, end_day=r.end_day, start_at=r.start_at,
                       end_at=r.end_at, timezone=r.timezone, status=r.status, revision=r.revision)
        for r in conn.execute(select(coverage_declarations).where(
            cd.user_id == user_id, cd.revision <= revision, overlapping).order_by(cd.id))]
    return _observations(sorted(rows.values(), key=lambda r: r.id), memberships), coverage


def load_all_observations(conn: Connection, user_id: UUID, revision: int) -> list[Observation]:
    return _observations(conn.execute(select(health_events).where(
        health_events.c.user_id == user_id, health_events.c.revision <= revision).order_by(health_events.c.id)),
                         installation_memberships(conn, user_id, revision))


# ---------------------------------------------------------------- configuration and runs

def save_config_snapshot(conn: Connection, settings: Settings, now: datetime) -> str:
    digest = settings_sha256(settings)
    conn.execute(insert(config_snapshots).values(config_sha256=digest, payload=settings_payload(settings),
                                                 first_used_at=utc(now)).on_conflict_do_nothing())
    return digest


def load_config_snapshot(conn: Connection, digest: str) -> Settings:
    payload = conn.execute(select(config_snapshots.c.payload)
                           .where(config_snapshots.c.config_sha256 == digest)).scalar_one()
    settings = Settings.model_validate(payload)
    if settings_sha256(settings) != digest:
        raise ValueError(f"configuration snapshot {digest[:12]} no longer hashes to its key")
    return settings


def save_run(conn: Connection, user_id: UUID, run: dict, outputs: dict) -> int | None:
    """Insert a run and its outputs; an identical context is a no-op (None)."""
    run_id = conn.execute(insert(calculation_runs).values(user_id=user_id, **run)
                          .on_conflict_do_nothing(constraint="uq_calculation_runs_context")
                          .returning(calculation_runs.c.run_id)).scalar_one_or_none()
    if run_id is None:
        # A retained ledger entry may have lost its derived output. Preserve the
        # original run ID and restore only missing output, never overwrite it.
        identity = ("kind", "day", "timezone", "effective_at", "known_at", "input_revision",
                    "config_sha256", "feature_version", "engine_version", "presentation_version")
        run_id = conn.execute(select(calculation_runs.c.run_id).where(
            calculation_runs.c.user_id == user_id,
            *(calculation_runs.c[key] == run[key] for key in identity))).scalar_one()
        return conn.execute(insert(run_outputs).values(run_id=run_id, **outputs)
                            .on_conflict_do_nothing().returning(run_outputs.c.run_id)).scalar_one_or_none()
    conn.execute(insert(run_outputs).values(run_id=run_id, **outputs))
    return run_id


def _latest_runs(user_id: UUID):
    cr = calculation_runs.c
    return (select(calculation_runs, run_outputs).join(run_outputs, run_outputs.c.run_id == cr.run_id)
            .where(cr.user_id == user_id).order_by(cr.input_revision.desc(), cr.run_id.desc()))


def latest_run(conn: Connection, user_id: UUID, day: date | None = None):
    query = _latest_runs(user_id)
    if day is not None:
        query = query.where(calculation_runs.c.day == day)
    else:  # the newest day with a published state
        query = query.order_by(None).order_by(calculation_runs.c.day.desc(), calculation_runs.c.input_revision.desc(),
                                              calculation_runs.c.run_id.desc())
    return conn.execute(query.limit(1)).one_or_none()


def runs_between(conn: Connection, user_id: UUID, first: date, last: date):
    cr = calculation_runs.c
    return conn.execute(select(calculation_runs, run_outputs).outerjoin(run_outputs, run_outputs.c.run_id == cr.run_id)
                        .where(cr.user_id == user_id, cr.day >= first, cr.day <= last)
                        .order_by(cr.day, cr.run_id)).all()


def canonical_bytes(value) -> bytes:
    return json.dumps(json_value(value), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
