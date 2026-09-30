import json
from datetime import date, timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import select, update

from app import recalc, store
from app.contracts._types import json_value
from app.db import run_outputs
from app.features.selection import select_visible
from app.features.models import CalculationContext
from app.ingest import SyncRequest
from app.replay import verify_runs
from tests.db.test_ingest import NOW, USER, ZONE, body, hrv, sync
from tests.db.test_recalc import SETTINGS
from tests.features.conftest import workout, at
from app.synthetic.generator import Builder

pytestmark = pytest.mark.db
A, B = UUID(int=1), UUID(int=2)
HRV = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"


def upload(engine, installation, events=(), members=None, kind=HRV, start=None, coverage=()):
    payload = json.loads(body(events, coverage=coverage))
    payload["installation_id"] = str(installation)
    if members is not None:
        payload["visibility"] = [{"scan_id": str(uuid4()), "healthkit_type": kind,
            "scope_start_at": (start or NOW - timedelta(days=100)).isoformat(),
            "scope_end_at": NOW.isoformat(), "members": members}]
    return sync(engine, json.dumps(payload).encode())


def selected(engine, revision):
    with engine.connect() as conn:
        events = store.load_all_observations(conn, USER, revision)
        scans = store.load_visibility(conn, USER, revision)
    return select_visible(events, CalculationContext(day=NOW.date(), timezone=ZONE,
        known_at=NOW, effective_at=NOW, visibility=tuple(scans)))


def test_each_installation_withdraws_only_its_own_memberships(db_engine):
    one, two = hrv(key="a"), hrv(key="b")
    upload(db_engine, A, [one])
    upload(db_engine, B, [two])
    scanned = upload(db_engine, A, members=[])
    result = selected(db_engine, scanned.revision)
    assert [e.source_record_id for e in result.records] == [two.source_record_id]
    assert result.withdrawn == (one.source_record_id,)


def test_shared_record_survives_until_every_installation_withdraws_it(db_engine):
    one = hrv(key="shared")
    first = upload(db_engine, A, [one])
    upload(db_engine, B, [one])  # same client ID retry still establishes device B
    a = upload(db_engine, A, members=[])
    assert len(selected(db_engine, a.revision).records) == 1
    b = upload(db_engine, B, members=[])
    assert selected(db_engine, b.revision).withdrawn == (one.source_record_id,)
    restored = upload(db_engine, A, members=[one.source_record_id])
    assert len(selected(db_engine, restored.revision).records) == 1
    assert len(selected(db_engine, first.revision).records) == 1  # historical ownership is immutable


def test_finalization_requires_separate_upload_and_bounded_scope(db_engine):
    with pytest.raises(ValueError, match="acknowledgements"):
        upload(db_engine, A, [hrv()], members=[])
    request = json.loads(body([])) | {"installation_id": str(A), "visibility": [{
        "scan_id": str(uuid4()), "healthkit_type": HRV, "scope_start_at": NOW.isoformat(), "members": []}]}
    with pytest.raises(ValueError, match="scope_end_at"):
        SyncRequest.model_validate(request)
    upload(db_engine, A, [hrv()])
    result = upload(db_engine, A, members=[])
    assert selected(db_engine, result.revision).withdrawn


def test_latest_older_withdrawn_workout_falls_back_to_next_visible_one(db_engine):
    builder = Builder("older-visible", ZONE)
    old_day = NOW.date() - timedelta(days=60)
    older = workout(builder, "older", at(8, day=old_day), at(9, day=old_day), 60)
    recent_day = old_day + timedelta(days=1)
    newer = workout(builder, "newer", at(8, day=recent_day), at(9, day=recent_day), 60)
    upload(db_engine, A, [older, newer])
    scan = upload(db_engine, A, members=[older.source_record_id], kind="HKWorkoutTypeIdentifier", coverage=[{
        "domain": "workout", "timezone": ZONE, "status": "complete",
        "start_day": (NOW.date() - timedelta(days=100)).isoformat(), "end_day": NOW.date().isoformat()}])
    with db_engine.connect() as conn:
        report, _, _ = recalc.compute(conn, USER, SETTINGS, scan.revision, NOW.date(), ZONE, NOW, NOW)
        observations, _ = store.load_inputs(conn, USER, scan.revision, NOW.date(), ZONE, NOW, SETTINGS)
    assert older.source_record_id in [o.event.source_record_id for o in observations]
    assert report.features.workout.last_workout_end == older.end_at


def test_pre_visibility_report_still_replays_after_upgrade(db_engine):
    sync(db_engine, body([hrv()]))
    assert recalc.process_user(db_engine, USER, SETTINGS, NOW)
    with db_engine.begin() as conn:
        row = store.latest_run(conn, USER)
        legacy_report = dict(row.report)
        legacy_report["context"].pop("visibility", None)
        conn.execute(update(run_outputs).where(run_outputs.c.run_id == row.run_id).values(report=legacy_report))
    checks = verify_runs(db_engine, USER, NOW.date(), NOW.date())
    assert checks and all(check.status == "identical" for check in checks)


def test_only_new_memberships_cost_a_revision_and_only_scans_make_them_recalculate(db_engine):
    one = hrv(key="dup")
    upload(db_engine, A, [one])
    resent = one.model_copy(update={"event_id": uuid4()})  # same provider content, new client ID
    assert upload(db_engine, A, [resent]).revision is None  # already seen by A: nothing changes
    second = upload(db_engine, B, [one.model_copy(update={"event_id": uuid4()})])
    assert second.revision is not None  # B's first sighting is recorded...
    assert second.response["affected_days"] == []  # ...but without a scan it can't change any result
    upload(db_engine, A, members=[])
    third = upload(db_engine, UUID(int=3), [one.model_copy(update={"event_id": uuid4()})])
    assert third.response["affected_days"] == [NOW.date().isoformat()]  # a scan may have withdrawn it
