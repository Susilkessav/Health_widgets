"""Durable recalculation, coalescing, ordering and finalization (plan sections 6, 8.2, 9)."""
import subprocess
import sys
import textwrap
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest
from sqlalchemy import func, select

from app import recalc, store
from app.config import load_settings
from app.db import calculation_runs, recalc_jobs
from app.recalc import process_user, run_pending, sweep
from app.synthetic.generator import Builder

from .test_ingest import NOW, USER, ZONE, body, hrv, sync

pytestmark = pytest.mark.db
SETTINGS = load_settings()
BACKEND = Path(__file__).resolve().parents[2]


def history(days=20):
    b = Builder("recalc", ZONE)
    for index in range(days):
        b.daily(date(2026, 9, 22) - timedelta(days=days - index))
    b.daily(date(2026, 9, 22))
    return [e for e in b.events]


def jobs(engine, status="pending"):
    with engine.connect() as conn:
        return conn.execute(select(recalc_jobs).where(recalc_jobs.c.status == status)).all()


def test_a_sync_job_publishes_the_affected_days(db_engine):
    sync(db_engine, body(history()))
    assert process_user(db_engine, USER, SETTINGS, NOW)
    assert not jobs(db_engine)
    with db_engine.connect() as conn:
        latest = store.latest_run(conn, USER)
        assert latest.day == date(2026, 9, 22) and latest.kind == "sync" and latest.input_revision == 1
        kinds = dict(conn.execute(select(calculation_runs.c.kind, func.count()).group_by(calculation_runs.c.kind)).all())
    # The first night's sleep starts the evening before its wake day, so 21 past
    # days are affected: each at its closing boundary, today at known_at.
    assert kinds == {"finalize": 21, "sync": 1}


def test_pending_jobs_coalesce_into_one_calculation_at_the_newest_revision(db_engine):
    for key in ("a", "b", "c"):
        sync(db_engine, body([hrv(key=key)]))
    assert len(jobs(db_engine)) == 3
    assert process_user(db_engine, USER, SETTINGS, NOW)
    with db_engine.connect() as conn:
        revisions = set(conn.execute(select(calculation_runs.c.input_revision)).scalars())
    assert revisions == {3} and len(jobs(db_engine, "done")) == 3


def test_an_older_run_finishing_late_never_becomes_latest(db_engine):
    sync(db_engine, body([hrv(key="a")]))
    sync(db_engine, body([hrv(key="b")]))
    assert process_user(db_engine, USER, SETTINGS, NOW)                    # publishes revision 2
    with db_engine.begin() as conn:                                         # a slow revision-1 run lands after
        recalc.save(conn, USER, "sync", SETTINGS, 1, date(2026, 9, 22), ZONE, NOW - timedelta(minutes=1),
                    NOW - timedelta(minutes=1), NOW, None)
    with db_engine.connect() as conn:
        assert store.latest_run(conn, USER).input_revision == 2


def test_a_failed_calculation_stays_pending_and_is_retried(db_engine, monkeypatch):
    sync(db_engine, body([hrv()]))
    original = recalc.compute
    monkeypatch.setattr(recalc, "compute", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
    assert not process_user(db_engine, USER, SETTINGS, NOW)
    [job] = jobs(db_engine)
    assert (job.attempts, job.last_error_code) == (1, "RuntimeError") and job.next_attempt_at > NOW
    monkeypatch.setattr(recalc, "compute", original)
    assert run_pending(db_engine, SETTINGS, NOW) == 0                       # backing off, not due yet
    assert run_pending(db_engine, SETTINGS, NOW + timedelta(minutes=1)) == 1
    assert not jobs(db_engine)


def test_a_crash_after_the_upload_commit_is_recovered_by_the_worker(db_engine, database_url):
    script = textwrap.dedent(f"""
        import os
        from datetime import datetime
        from zoneinfo import ZoneInfo
        from app.db import make_engine
        from tests.db.test_ingest import USER, body, hrv, sync
        sync(make_engine({database_url!r}), body([hrv()]))
        os._exit(1)  # killed between the upload commit and the calculation
    """)
    result = subprocess.run([sys.executable, "-c", script], cwd=BACKEND, capture_output=True, timeout=60)
    assert result.returncode == 1, result.stderr
    assert len(jobs(db_engine)) == 1
    assert run_pending(db_engine, SETTINGS, NOW) == 1
    with db_engine.connect() as conn:
        assert store.latest_run(conn, USER).input_revision == 1


def test_running_out_of_inline_time_defers_without_counting_a_failure(db_engine):
    sync(db_engine, body(history()))
    assert not process_user(db_engine, USER, SETTINGS, NOW, budget_seconds=0)
    [job] = jobs(db_engine)
    assert job.attempts == 0
    assert process_user(db_engine, USER, SETTINGS, NOW)


def test_yesterday_is_finalized_after_midnight_without_an_upload(db_engine):
    sync(db_engine, body(history(3)))
    assert process_user(db_engine, USER, SETTINGS, NOW)
    after_midnight = datetime(2026, 9, 23, 0, 30, tzinfo=ZoneInfo(ZONE))
    assert sweep(db_engine, after_midnight) == 1
    assert run_pending(db_engine, SETTINGS, after_midnight) == 1
    with db_engine.connect() as conn:
        run = conn.execute(select(calculation_runs).where(calculation_runs.c.day == date(2026, 9, 22),
                                                          calculation_runs.c.kind == "finalize")).one()
        assert run.effective_at == datetime(2026, 9, 23, tzinfo=ZoneInfo(ZONE)) and run.known_at >= run.effective_at
    assert sweep(db_engine, after_midnight) == 0                            # nothing left to finalize


def test_upload_latency_uses_common_query_cutoff_and_preserves_receipt_time(db_engine):
    from app.features.models import DOMAINS
    windows = [{"domain": domain, "timezone": ZONE, "status": "complete",
                "start_at": "2026-08-01T00:00:00Z",
                "end_at": (NOW + timedelta(seconds=index)).isoformat()}
               for index, domain in enumerate(DOMAINS)]
    received = NOW + timedelta(seconds=10)
    sync(db_engine, body(history(), coverage=windows), now=received)
    assert process_user(db_engine, USER, SETTINGS, received)
    with db_engine.connect() as conn:
        latest = store.latest_run(conn, USER)
        assert latest.effective_at == NOW
        assert latest.known_at == received
        assert latest.state["recovery"]["state"] != "insufficient_data"
        # Replay at the recorded cutoff sees exactly the same inputs.
        report, state, _ = recalc.compute(conn, USER, SETTINGS, 1, latest.day, ZONE, NOW, received)
        assert report.context.covered("movement", latest.day, latest.day)
        assert state.model_dump(mode="json") == latest.state


def test_unavailable_domain_is_not_bypassed_by_cutoff(db_engine):
    from app.features.models import DOMAINS
    windows = [{"domain": domain, "timezone": ZONE,
                "status": "unavailable" if domain == "hrv" else "complete",
                "start_at": "2026-08-01T00:00:00Z", "end_at": NOW.isoformat()} for domain in DOMAINS]
    sync(db_engine, body(history(), coverage=windows), now=NOW + timedelta(seconds=1))
    assert process_user(db_engine, USER, SETTINGS, NOW + timedelta(seconds=1))
    with db_engine.connect() as conn:
        report, _, _ = recalc.compute(conn, USER, SETTINGS, 1, NOW.date(), ZONE, NOW, NOW + timedelta(seconds=1))
        assert not report.context.covered("hrv", NOW.date(), NOW.date())
        assert report.context.covered("sleep", NOW.date(), NOW.date())
