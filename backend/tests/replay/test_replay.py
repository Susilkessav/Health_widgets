"""Exact replay of recorded runs and daily rebuilds (Step 6-8 plan section 10)."""
import os
import subprocess
import sys
from datetime import date, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select, text, update

from app.db import calculation_runs, run_outputs
from app.main import create_app
from app.recalc import run_pending
from app.replay import rebuild, verify_runs
from tests.api.test_api import KEY, FixedClock, payload, runtime
from tests.db.test_ingest import NOW, USER, ZONE, hrv
from tests.db.test_recalc import SETTINGS, history

pytestmark = pytest.mark.db
FIRST, LAST = date(2026, 8, 1), date(2026, 9, 30)
BACKEND = Path(__file__).resolve().parents[2]


@pytest.fixture
def built(db_engine):
    """History, a later correction, and an after-midnight finalization, all via the API."""
    clock = FixedClock(NOW)
    with TestClient(create_app(runtime(), clock=clock, engine=db_engine)) as client:
        client.post("/v1/health/sync", headers=KEY, json=payload(history()))
        clock.now = NOW.replace(hour=18)
        client.post("/v1/health/sync", headers=KEY, json=payload([hrv(58, key="later")]))
        midnight = datetime(2026, 9, 23, 0, 30, tzinfo=ZoneInfo(ZONE))
        run_pending(db_engine, SETTINGS, midnight)
    return db_engine


def test_every_recorded_run_replays_identically(built):
    checks = verify_runs(built, USER, FIRST, LAST)
    assert checks and all(check.status == "identical" for check in checks)


def test_an_edited_output_is_detected(built):
    with built.begin() as conn:
        run_id = conn.execute(select(calculation_runs.c.run_id).order_by(calculation_runs.c.run_id.desc())).first()[0]
        conn.execute(text("UPDATE run_outputs SET state = jsonb_set(state, '{recovery,state}', '\"strained\"') "
                          "WHERE run_id = :run_id"), {"run_id": run_id})
    [bad] = [c for c in verify_runs(built, USER, FIRST, LAST) if c.status != "identical"]
    assert bad.status == "mismatch" and bad.differences == ["state.recovery"]


def test_a_different_code_version_is_reported_not_failed(built):
    with built.begin() as conn:
        conn.execute(update(calculation_runs).where(calculation_runs.c.run_id == 1)
                     .values(presentation_version="presentation@0.0.9"))
    [other] = [c for c in verify_runs(built, USER, FIRST, LAST) if c.status != "identical"]
    assert other.status == "not_reproducible"


def outputs_by_day(engine):
    with engine.connect() as conn:
        rows = conn.execute(select(calculation_runs.c.day, run_outputs.c.state, run_outputs.c.widget_state,
                                   run_outputs.c.report)
                            .join(run_outputs, run_outputs.c.run_id == calculation_runs.c.run_id)
                            .where(calculation_runs.c.kind == "rebuild").order_by(calculation_runs.c.day)).all()
    return [tuple(row) for row in rows]


def test_rebuild_twice_adds_nothing_and_never_needs_future_knowledge(built):
    first = rebuild(built, USER, SETTINGS, date(2026, 9, 1), date(2026, 9, 22), None, NOW)
    # Revision 2 was received at 18:00 on 09-22, before that day closed, so 09-22 is skipped.
    assert first.created == 21 and len(first.skipped) == 1 and first.skipped[0].startswith("2026-09-22")
    again = rebuild(built, USER, SETTINGS, date(2026, 9, 1), date(2026, 9, 22), None, NOW)
    assert (again.created, again.unchanged) == (0, 21)
    with built.connect() as conn:
        assert not conn.execute(select(calculation_runs).where(
            calculation_runs.c.known_at < calculation_runs.c.effective_at)).all()


def test_rebuilding_after_deleting_derived_rows_reproduces_the_summaries(built):
    rebuild(built, USER, SETTINGS, date(2026, 9, 1), date(2026, 9, 21), 1, NOW)
    before = outputs_by_day(built)
    with built.begin() as conn:
        conn.execute(text("TRUNCATE run_outputs, calculation_runs RESTART IDENTITY CASCADE"))
    rebuild(built, USER, SETTINGS, date(2026, 9, 1), date(2026, 9, 21), 1, NOW)
    assert outputs_by_day(built) == before and len(before) == 21


def test_the_cli(built, database_url):
    env = dict(os.environ, DATABASE_URL=database_url, HOMEOSTAT_DEV_USER_ID=str(USER))
    runs = subprocess.run([sys.executable, "-m", "app.replay", "runs", "--user", "dev", "--from", "2026-08-01",
                           "--to", "2026-09-30"], cwd=BACKEND, env=env, capture_output=True, text=True, timeout=120)
    assert runs.returncode == 0 and "0 mismatched" in runs.stdout, runs.stdout + runs.stderr
    bad = subprocess.run([sys.executable, "-m", "app.replay", "rebuild", "--user", "dev", "--from", "2026-09-01",
                          "--to", "2026-09-02", "--cutoff-revision", "99"], cwd=BACKEND, env=env,
                         capture_output=True, text=True, timeout=120)
    assert bad.returncode == 2 and "error:" in bad.stderr


def test_missing_outputs_are_detected_and_rebuilt_without_deleting_ledger(built):
    rebuild(built, USER, SETTINGS, date(2026, 9, 1), date(2026, 9, 2), 1, NOW)
    with built.begin() as conn:
        ids = list(conn.execute(select(calculation_runs.c.run_id).where(calculation_runs.c.kind == "rebuild")).scalars())
        before = conn.execute(select(run_outputs).where(run_outputs.c.run_id.in_(ids)).order_by(run_outputs.c.run_id)).all()
        conn.execute(run_outputs.delete().where(run_outputs.c.run_id.in_(ids)))
    bad = [check for check in verify_runs(built, USER, FIRST, LAST) if check.status != "identical"]
    assert {check.run_id for check in bad} == set(ids)
    assert all(check.differences == ["missing_output"] for check in bad)
    restored = rebuild(built, USER, SETTINGS, date(2026, 9, 1), date(2026, 9, 2), 1, NOW)
    assert restored.created == 2 and restored.unchanged == 0
    with built.connect() as conn:
        after = conn.execute(select(run_outputs).where(run_outputs.c.run_id.in_(ids)).order_by(run_outputs.c.run_id)).all()
    assert before == after
