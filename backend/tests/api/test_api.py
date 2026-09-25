"""HTTP behavior of the API (Step 6-8 plan sections 5.1, 9, 11, 12)."""
import json
import logging
from datetime import datetime, timedelta
from uuid import uuid4
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from app import recalc
from app.config import DEFAULT_PATH
from app.contracts._types import json_value
from app.db import make_engine
from app.main import create_app
from app.recalc import run_pending
from app.runtime import Runtime
from tests.db.test_ingest import NOW, USER, ZONE, hrv
from tests.db.test_recalc import SETTINGS, history

pytestmark = pytest.mark.db
KEY = {"X-Homeostat-Key": "test-key"}


class FixedClock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


def runtime(development=True):
    return Runtime(database_url="unused", api_key="test-key", dev_user_id=USER, development=development,
                   config_path=DEFAULT_PATH, worker_interval_seconds=0)


@pytest.fixture
def api(db_engine):
    clock = FixedClock(NOW)
    with TestClient(create_app(runtime(), clock=clock, engine=db_engine)) as client:
        yield client, clock


def payload(events=(), request_id=None, coverage=()):
    return {"request_id": str(request_id or uuid4()), "device_timezone": ZONE, "coverage": list(coverage),
            "events": [json_value(e) for e in events]}


def test_auth_is_required_except_for_healthz(api):
    client, _ = api
    assert client.get("/healthz").json() == {"database": "ok"}
    assert client.get("/v1/state/current").status_code == 401
    assert client.get("/v1/state/current", headers={"X-Homeostat-Key": "wrong"}).json() == {"code": "UNAUTHORIZED"}


def test_upload_publishes_and_the_state_endpoints_serve_it(api):
    client, _ = api
    assert client.get("/v1/state/current", headers=KEY).json() == {"code": "NO_STATE_YET"}
    response = client.post("/v1/health/sync", headers=KEY, json=payload(history())).json()
    assert response["revision"] == 1 and response["state"]["status"] == "published"
    assert response["state"]["widget_state"]["presentation"]["headline"]
    current = client.get("/v1/state/current", headers=KEY).json()
    assert current["day"] == "2026-09-22" and current["is_today"] and current["input_revision"] == 1
    assert client.get("/v1/state/2026-09-22", headers=KEY).json()["finalized"] is False
    assert client.get("/v1/state/2026-09-21", headers=KEY).json()["finalized"] is True
    assert client.get("/v1/state/2020-01-01", headers=KEY).json() == {"code": "NO_STATE_FOR_DAY"}
    assert client.get("/v1/debug/features/2026-09-22", headers=KEY).json()["features"]["day"] == "2026-09-22"


def test_a_resent_request_gets_the_same_response_and_a_changed_one_409(api):
    client, _ = api
    body = payload([hrv()])
    first = client.post("/v1/health/sync", headers=KEY, json=body).json()
    again = client.post("/v1/health/sync", headers=KEY, json=body).json()
    assert {k: v for k, v in again.items() if k != "state"} == {k: v for k, v in first.items() if k != "state"}
    changed = {**body, "events": [json_value(hrv(51))]}
    response = client.post("/v1/health/sync", headers=KEY, json=changed)
    assert response.status_code == 409 and response.json() == {"code": "REQUEST_ID_REUSED"}


def test_limits(api):
    client, _ = api
    response = client.post("/v1/health/sync", headers=KEY, json={**payload(), "events": [{}] * 501})
    assert (response.status_code, response.json()) == (413, {"code": "TOO_MANY_EVENTS"})
    big = client.post("/v1/health/sync", headers={**KEY, "Content-Type": "application/json"},
                      content=b"{" + b" " * (5 * 1024 * 1024 + 1) + b"}")
    assert big.status_code == 413


def test_invalid_envelopes_are_sanitized(api):
    client, _ = api
    secret = "Mars/Base-7"
    response = client.post("/v1/health/sync", headers=KEY, json={**payload(), "device_timezone": secret})
    assert response.status_code == 422 and secret not in response.text
    assert response.json()["errors"] == [{"code": "value_error", "field_path": "device_timezone"}]
    not_json = client.post("/v1/health/sync", headers={**KEY, "Content-Type": "application/json"}, content=b"{oops")
    assert not_json.status_code == 422 and "oops" not in not_json.text
    bad_day = client.get("/v1/state/2026-99-99", headers=KEY)
    assert bad_day.status_code == 422 and "2026-99-99" not in bad_day.text


def test_an_unavailable_database_gives_503_and_nothing_is_stored(db_engine):
    dead = make_engine("postgresql+psycopg://postgres:postgres@localhost:1/none")
    with TestClient(create_app(runtime(), clock=FixedClock(NOW), engine=dead)) as client:
        response = client.post("/v1/health/sync", headers=KEY, json=payload([hrv()]))
        assert response.status_code == 503 and response.headers["Retry-After"] == "30"
        assert client.get("/healthz").status_code == 503


def test_after_midnight_current_is_yesterday_not_missing(api):
    client, clock = api
    client.post("/v1/health/sync", headers=KEY, json=payload(history(3)))
    clock.now = datetime(2026, 9, 23, 0, 30, tzinfo=ZoneInfo(ZONE))
    current = client.get("/v1/state/current", headers=KEY).json()
    assert current["day"] == "2026-09-22" and current["is_today"] is False


def test_a_failed_calculation_reports_pending_then_the_worker_publishes(api, db_engine, monkeypatch):
    client, _ = api
    original = recalc.compute
    monkeypatch.setattr(recalc, "compute", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
    response = client.post("/v1/health/sync", headers=KEY, json=payload([hrv()])).json()
    assert response["results"][0]["status"] == "accepted"
    assert response["state"] == {"status": "pending", "widget_state": None, "input_revision": None, "run_id": None}
    monkeypatch.setattr(recalc, "compute", original)
    assert run_pending(db_engine, SETTINGS, NOW + timedelta(minutes=1)) == 1
    assert client.get("/v1/state/current", headers=KEY).json()["input_revision"] == 1


def test_debug_is_absent_outside_development(db_engine):
    with TestClient(create_app(runtime(development=False), clock=FixedClock(NOW), engine=db_engine)) as client:
        assert client.get("/v1/debug/features/2026-09-22", headers=KEY).status_code == 404


def test_logs_carry_no_health_values_or_ids(api, scenarios, caplog):
    client, _ = api
    dataset = scenarios["short_sleep"]
    allowed = {"request_id", "revision", "replayed", "counts", "event_types", "affected_days",
               "days_beyond_recalc_window", "state_status", "http_status", "jobs", "target_revision",
               "outcome", "milliseconds", "error"}
    with caplog.at_level(logging.INFO, logger="homeostat"):
        client.post("/v1/health/sync", headers=KEY, json=payload(dataset.events))
        client.post("/v1/health/sync", headers=KEY, json={**payload(), "device_timezone": "Nowhere/None"})
    forbidden = {str(e.event_id) for e in dataset.events} | {e.source_record_id for e in dataset.events}
    records = [r for r in caplog.records if r.name.startswith("homeostat")]
    assert records
    for record in records:
        event = getattr(record, "event", {})
        assert set(event) <= allowed
        text = json.dumps(event, default=str) + record.getMessage()
        assert not any(identifier in text for identifier in forbidden)


def test_published_states_carry_an_ordering_token(api):
    client, clock = api
    first = client.post("/v1/health/sync", headers=KEY, json=payload(history(3))).json()["state"]
    clock.now = NOW + timedelta(hours=1)
    second = client.post("/v1/health/sync", headers=KEY, json=payload([hrv(key="later")])).json()["state"]
    assert (second["input_revision"], second["run_id"]) > (first["input_revision"], first["run_id"])
    current = client.get("/v1/state/current", headers=KEY).json()
    assert (current["input_revision"], current["run_id"]) == (second["input_revision"], second["run_id"])


def test_partial_day_coverage_round_trips_through_the_api(api, db_engine):
    from app.store import load_inputs
    client, _ = api
    partial = {"domain": "workout", "timezone": ZONE, "status": "complete",
               "start_at": "2026-09-15T05:00:00Z", "end_at": NOW.isoformat()}
    response = client.post("/v1/health/sync", headers=KEY, json=payload(coverage=[partial]))
    assert response.status_code == 200 and response.json()["affected_days"] == ["2026-09-15"]
    with db_engine.connect() as conn:
        _, windows = load_inputs(conn, USER, 1, NOW.date(), ZONE, NOW, SETTINGS)
    assert [w.end_at for w in windows] == [NOW]
    both = {**partial, "start_day": "2026-09-15", "end_day": "2026-09-22"}
    rejected = client.post("/v1/health/sync", headers=KEY, json=payload(coverage=[both]))
    assert rejected.status_code == 422
