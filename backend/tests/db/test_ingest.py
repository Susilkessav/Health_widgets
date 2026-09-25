"""Ingestion classification, idempotency and revisions (Step 6-8 plan section 5)."""
import json
import threading
from datetime import date, datetime, timedelta
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

import pytest
from pydantic import ValidationError
from sqlalchemy import func, select

from app import store
from app.contracts._types import json_value
from app.contracts.canonical_events import DeleteEvent, PointMeasurement
from app.db import coverage_declarations, event_receipts, health_events, recalc_jobs
from app.ingest import RequestIdReused, SyncRequest, ingest
from app.synthetic.generator import Builder, stable_id

pytestmark = pytest.mark.db
ZONE = "America/Chicago"
NOW = datetime(2026, 9, 22, 13, 0, tzinfo=ZoneInfo(ZONE))
USER = UUID("00000000-0000-4000-8000-00000000000b")


def body(events, request_id=None, coverage=()):
    return json.dumps({"request_id": str(request_id or uuid4()), "device_timezone": ZONE,
                       "coverage": list(coverage),
                       "events": [e if isinstance(e, dict) else json_value(e) for e in events]}).encode()


def sync(engine, raw: bytes, now=NOW, user=USER):
    with engine.begin() as conn:
        return ingest(conn, user, raw, SyncRequest.model_validate_json(raw), now)


def statuses(result):
    return [(r["status"], r.get("code")) for r in result.response["results"]]


def hrv(value=50, key=""):
    return Builder("ingest", ZONE).point(date(2026, 9, 22), "hrv_sdnn_ms", value, key)


def count(engine, table):
    with engine.connect() as conn:
        return conn.execute(select(func.count()).select_from(table)).scalar_one()


def test_accepted_then_the_same_request_replays_its_response(db_engine):
    raw = body([hrv()])
    first = sync(db_engine, raw)
    assert statuses(first) == [("accepted", None)] and first.revision == 1
    again = sync(db_engine, raw)
    assert again.replayed and again.response == first.response
    assert count(db_engine, health_events) == 1 and count(db_engine, recalc_jobs) == 1


def test_the_same_request_id_with_a_different_body_is_refused(db_engine):
    request_id = uuid4()
    sync(db_engine, body([hrv()], request_id))
    with pytest.raises(RequestIdReused):
        sync(db_engine, body([hrv(51)], request_id))


@pytest.mark.parametrize(("mutate", "code"), [
    (lambda e: {**e, "unit": "bpm"}, "INVALID_UNIT"),
    (lambda e: {**e, "metric": "vo2_max"}, "UNKNOWN_METRIC"),
    (lambda e: {k: v for k, v in e.items() if k != "observed_at"}, "INVALID_EVENT_SCHEMA"),
])
def test_invalid_events_are_rejected_with_a_code_and_the_rest_accepted(db_engine, mutate, code):
    good, bad = hrv(key="good"), mutate(json_value(hrv(key="bad")))
    result = sync(db_engine, body([bad, good]))
    assert statuses(result) == [("rejected", code), ("accepted", None)]


def test_an_event_without_a_readable_id_gets_an_index_and_no_receipt(db_engine):
    result = sync(db_engine, body([{"event_type": "point_measurement"}]))
    assert result.response["results"][0]["client_event_id"] is None
    assert result.response["results"][0]["index"] == 0 and count(db_engine, event_receipts) == 0


def test_a_client_id_reused_with_different_content_is_rejected(db_engine):
    original = hrv()
    sync(db_engine, body([original]))
    changed = PointMeasurement.model_validate({**original.model_dump(), "value": 60})
    assert statuses(sync(db_engine, body([changed]))) == [("rejected", "CLIENT_EVENT_ID_REUSED")]


def test_a_reimport_is_a_duplicate_and_its_client_id_is_remembered(db_engine):
    original = hrv()
    sync(db_engine, body([original]))
    reimport = PointMeasurement.model_validate({**original.model_dump(), "event_id": stable_id("reimport")})
    assert statuses(sync(db_engine, body([reimport]))) == [("duplicate", None)]
    assert count(db_engine, health_events) == 1
    reused = PointMeasurement.model_validate({**reimport.model_dump(), "value": 70})
    assert statuses(sync(db_engine, body([reused]))) == [("rejected", "CLIENT_EVENT_ID_REUSED")]


def test_contradictory_versions_are_stored_as_a_conflict_and_retries_say_so(db_engine):
    original = hrv()
    sync(db_engine, body([original]))
    rival = PointMeasurement.model_validate({**original.model_dump(), "event_id": stable_id("rival"), "value": 80})
    assert statuses(sync(db_engine, body([rival]))) == [("conflict", "CONFLICTING_PROVIDER_RECORD")]
    assert statuses(sync(db_engine, body([rival]))) == [("conflict", "CONFLICTING_PROVIDER_RECORD")]
    assert count(db_engine, health_events) == 2


def test_repeated_deletions_are_duplicates_not_conflicts(db_engine):
    original = hrv()
    first = DeleteEvent(event_id=stable_id("d1"), source="healthkit", source_record_id=original.source_record_id,
                        deleted_at=NOW)
    second = first.model_copy(update={"event_id": stable_id("d2"), "deleted_at": NOW + timedelta(hours=2)})
    sync(db_engine, body([original]))
    assert statuses(sync(db_engine, body([first]))) == [("accepted", None)]
    assert statuses(sync(db_engine, body([second]))) == [("duplicate", None)]


def test_duplicates_within_one_batch(db_engine):
    event = hrv()
    reimport = PointMeasurement.model_validate({**event.model_dump(), "event_id": stable_id("same")})
    assert statuses(sync(db_engine, body([event, event, reimport]))) == [
        ("accepted", None), ("accepted", None), ("duplicate", None)]


def test_equivalent_content_ignores_offsets_and_metadata_order(db_engine):
    event = hrv()
    local = json_value(event) | {"event_id": str(stable_id("local")),
                                 "observed_at": event.observed_at.astimezone(ZoneInfo(ZONE)).isoformat()}
    assert statuses(sync(db_engine, body([event, local]))) == [("accepted", None), ("duplicate", None)]


def test_nothing_new_means_no_revision_and_no_job(db_engine):
    event = hrv()
    sync(db_engine, body([event]))
    again = sync(db_engine, body([event]))  # a new request, all duplicates
    assert again.revision is None and count(db_engine, recalc_jobs) == 1


def test_coverage_alone_creates_a_revision_and_is_kept(db_engine):
    window = {"domain": "workout", "start_day": "2026-09-01", "end_day": "2026-09-22", "timezone": ZONE,
              "status": "unavailable"}
    first = sync(db_engine, body([], coverage=[window]))
    second = sync(db_engine, body([], coverage=[window | {"status": "complete"}]))
    assert (first.revision, second.revision) == (1, 2)
    assert count(db_engine, coverage_declarations) == 2


def test_jobs_start_at_the_earliest_affected_day_within_35_days(db_engine):
    old = Builder("old", ZONE).point(date(2026, 7, 1), "hrv_sdnn_ms", 50)
    result = sync(db_engine, body([old, hrv()]))
    assert result.response["days_beyond_recalc_window"] == 1
    with db_engine.connect() as conn:
        assert conn.execute(select(recalc_jobs.c.from_day)).scalar_one() == date(2026, 8, 18)


def test_more_than_500_events_is_refused():
    with pytest.raises(ValidationError):
        SyncRequest.model_validate_json(body([{}] * 501))


def test_concurrent_uploads_get_gap_free_revisions(db_engine):
    raws = [body([hrv(key=f"thread{i}")]) for i in range(6)]
    threads = [threading.Thread(target=sync, args=(db_engine, raw)) for raw in raws]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    with db_engine.connect() as conn:
        revisions = sorted(conn.execute(select(health_events.c.revision)).scalars())
        assert revisions == [1, 2, 3, 4, 5, 6]
        assert store.current_revision(conn, USER)[0] == 6


def test_a_timezone_only_change_creates_a_revision_and_is_idempotent(db_engine):
    sync(db_engine, body([hrv()]))
    moved = json.dumps({"request_id": str(uuid4()), "device_timezone": "America/Los_Angeles",
                        "coverage": [], "events": []}).encode()
    first = sync(db_engine, moved)
    assert first.revision == 2 and first.response["affected_days"] == ["2026-09-22"]
    assert sync(db_engine, moved).replayed
    same = json.dumps({"request_id": str(uuid4()), "device_timezone": "America/Los_Angeles",
                       "coverage": [], "events": []}).encode()
    assert sync(db_engine, same).revision is None           # unchanged zone: nothing to do
    with db_engine.connect() as conn:
        assert store.current_revision(conn, USER)[2] == "America/Los_Angeles"
