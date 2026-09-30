"""Cross-language contract fixtures for the iPhone app (Step 9-13 plan section 3).

Python -> Swift: real server responses and exact snapshot IDs, written to the
Swift package's test fixtures. Swift -> Python: events the Swift encoder
produced (swift_events.jsonl), validated here through the real contracts.

Regenerate the Python-side fixtures with: UPDATE_WIRE_FIXTURES=1 uv run pytest tests/api/test_wire_fixtures.py
"""
import json
import os
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient
from pydantic import TypeAdapter

from app.contracts._types import json_value, local_day_start
from app.contracts.canonical_events import CanonicalEvent, DailyActivitySnapshot, PointMeasurement, snapshot_record_id
from app.main import create_app
from app.synthetic.generator import stable_id
from tests.api.test_api import KEY, FixedClock, runtime
from tests.db.test_ingest import NOW, ZONE, hrv
from tests.db.test_recalc import history

FIXTURES = Path(__file__).resolve().parents[3] / "ios" / "HomeostatCore" / "Tests" / "HomeostatCoreTests" / "Fixtures"
UPDATE = os.environ.get("UPDATE_WIRE_FIXTURES") == "1"
EVENTS = TypeAdapter(CanonicalEvent)


def write_or_compare(name: str, value) -> None:
    text = json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    path = FIXTURES / name
    if UPDATE:
        path.write_text(text, encoding="utf-8")
    assert path.read_text(encoding="utf-8") == text, f"{name} is stale: rerun with UPDATE_WIRE_FIXTURES=1"


def test_snapshot_id_fixtures():
    chicago, santiago = ZoneInfo("America/Chicago"), ZoneInfo("America/Santiago")
    cases = [
        ("America/Chicago", date(2026, 9, 22), datetime(2026, 9, 22, 13, 0, tzinfo=chicago),
         datetime(2026, 9, 22, 13, 0, 5, 123456, tzinfo=chicago), 4821),
        ("America/Chicago", date(2026, 9, 22), local_day_start(date(2026, 9, 23), "America/Chicago"),
         datetime(2026, 9, 23, 8, 0, tzinfo=chicago), 9001),
        # Fall back: 01:00 occurs twice; the second (fold=1) is a later instant.
        ("America/Chicago", date(2026, 11, 1), datetime(2026, 11, 1, 1, 0, tzinfo=chicago, fold=1),
         datetime(2026, 11, 1, 1, 30, tzinfo=chicago, fold=1), 12),
        # Santiago skips midnight: the day's closing boundary is 01:00.
        ("America/Santiago", date(2026, 9, 5), local_day_start(date(2026, 9, 6), "America/Santiago"),
         datetime(2026, 9, 6, 9, 0, 0, 1, tzinfo=santiago), 7000),
        ("UTC", date(2026, 1, 1), datetime(2026, 1, 1, 0, 0, tzinfo=timezone.utc),
         datetime(2026, 1, 1, 0, 0, 0, 999999, tzinfo=timezone.utc), 0),
    ]
    fixtures = []
    for zone, day, as_of, queried_at, steps in cases:
        event = DailyActivitySnapshot(event_id=stable_id("snapshot", zone, str(as_of)), source="healthkit",
                                      source_record_id=snapshot_record_id(zone, day, as_of, queried_at, steps),
                                      day=day, timezone=zone, as_of=as_of, queried_at=queried_at, steps=steps)
        fixtures.append({"timezone": zone, "day": day.isoformat(), "as_of": json_value(as_of),
                         "queried_at": json_value(queried_at), "steps": steps,
                         "source_record_id": event.source_record_id})
    write_or_compare("snapshot_ids.json", fixtures)


@pytest.mark.db
def test_server_wire_fixtures(db_engine):
    def request_id(name):
        return str(uuid5(NAMESPACE_URL, f"wire/{name}"))

    def body(name, events=(), coverage=(), zone=ZONE):
        return {"request_id": request_id(name), "device_timezone": zone, "coverage": list(coverage),
                "events": [e if isinstance(e, dict) else json_value(e) for e in events]}

    wire = {}
    clock = FixedClock(NOW)
    with TestClient(create_app(runtime(), clock=clock, engine=db_engine)) as client:
        def call(name, method, path, json_body=None, headers=KEY):
            response = client.request(method, path, json=json_body, headers=headers)
            wire[name] = {"status": response.status_code, "request": json_body, "response": response.json()}

        call("state_before_any", "GET", "/v1/state/current")
        partial = {"domain": "sleep", "timezone": ZONE, "status": "complete",
                   "start_at": "2026-08-16T05:00:00Z", "end_at": "2026-09-22T18:00:00Z"}
        call("sync_published", "POST", "/v1/health/sync", body("published", history(3), [partial]))
        call("sync_replayed", "POST", "/v1/health/sync", body("published", history(3), [partial]))
        call("sync_unchanged", "POST", "/v1/health/sync", body("unchanged", history(3)))
        original = hrv(key="wire")
        rival = PointMeasurement.model_validate({**original.model_dump(), "event_id": stable_id("wire-rival"),
                                                 "value": 90})
        bad_unit = {**json_value(hrv(key="bad")), "unit": "bpm"}
        clock.now = NOW + timedelta(hours=1)
        call("sync_mixed", "POST", "/v1/health/sync", body("mixed", [original, original, rival, bad_unit]))
        call("state_current", "GET", "/v1/state/current")
        call("error_401", "POST", "/v1/health/sync", body("unauthorized"), headers={"X-Homeostat-Key": "wrong"})
        call("error_409", "POST", "/v1/health/sync", body("mixed", [hrv(key="different")]))
        call("error_413", "POST", "/v1/health/sync", {**body("too_many"), "events": [{}] * 501})
        call("error_422", "POST", "/v1/health/sync", {**body("bad_zone"), "device_timezone": "Not/AZone"})
    with TestClient(create_app(runtime(), clock=FixedClock(NOW + timedelta(hours=2)), engine=db_engine,
                               inline_budget_seconds=0)) as client:
        response = client.post("/v1/health/sync", headers=KEY, json=body("pending", [hrv(key="later")]))
        wire["sync_pending"] = {"status": response.status_code, "request": body("pending", [hrv(key="later")]),
                                "response": response.json()}
    write_or_compare("server_wire.json", wire)


def test_swift_encoded_events_validate_through_the_contracts():
    lines = (FIXTURES / "swift_events.jsonl").read_text(encoding="utf-8").splitlines()
    assert lines, "run the Swift tests to produce swift_events.jsonl"
    types = set()
    for line in lines:
        raw = json.loads(line)
        event = EVENTS.validate_python(raw)
        types.add(event.event_type)
        # Nothing was lost or coerced: the validated event re-serializes to the same content.
        assert json_value(event) == json_value(EVENTS.validate_json(line))
        if isinstance(event, DailyActivitySnapshot):
            assert raw["source_record_id"] == snapshot_record_id(event.timezone, event.day, event.as_of,
                                                                 event.queried_at, event.steps)
    assert types == {"point_measurement", "interval", "workout", "daily_activity_snapshot", "delete"}


@pytest.mark.db
def test_a_swift_built_request_with_a_scan_is_accepted(db_engine):
    from app.ingest import SyncRequest
    body = (FIXTURES / "swift_request.json").read_bytes()
    request = SyncRequest.model_validate_json(body)
    member_body = (FIXTURES / "swift_member_request.json").read_bytes()
    member_request = SyncRequest.model_validate_json(member_body)
    assert not request.events and request.installation_id == member_request.installation_id
    assert len(request.visibility) == 1 and request.visibility[0].members == [member_request.events[0]["source_record_id"]]
    with TestClient(create_app(runtime(), clock=FixedClock(NOW), engine=db_engine)) as client:
        member_response = client.post("/v1/health/sync", headers={**KEY, "Content-Type": "application/json"}, content=member_body)
        assert member_response.status_code == 200
        assert [r["status"] for r in member_response.json()["results"]] == ["accepted"]
        response = client.post("/v1/health/sync", headers={**KEY, "Content-Type": "application/json"}, content=body)
    assert response.status_code == 200
    assert response.json()["results"] == []
    assert response.json()["revision"] > member_response.json()["revision"]


def test_distinct_widget_states_fixture():
    """Python -> Swift: every distinct widget payload the valid G1 state
    combinations produce, for the widget's decoding and layout checks."""
    from app.engine import compute_health_state
    from app.presentation import map_widget_state
    from tests.engine.conftest import SETTINGS as ENGINE_SETTINGS, features
    from tests.engine.test_presentation import COMBOS
    seen = {}
    for combo in COMBOS:
        widget = json_value(map_widget_state(compute_health_state(features(*combo), ENGINE_SETTINGS)))
        key = json.dumps([widget["presentation"], widget["primary_trait"]], sort_keys=True)
        seen.setdefault(key, widget)
    lines = [json.dumps(w, sort_keys=True, ensure_ascii=False) for _, w in sorted(seen.items())]
    text = "\n".join(lines) + "\n"
    path = FIXTURES / "widget_states.jsonl"
    if UPDATE:
        path.write_text(text, encoding="utf-8")
    assert path.read_text(encoding="utf-8") == text, "widget_states.jsonl is stale: rerun with UPDATE_WIRE_FIXTURES=1"
