"""Every synthetic dataset through HTTP and PostgreSQL must equal the in-memory
pipeline at every checkpoint, byte for byte (Step 6-8 plan section 15)."""
import itertools
import random
from datetime import timedelta
from uuid import NAMESPACE_URL, uuid5

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app import recalc
from app.contracts._types import json_value, utc
from app.db import sync_requests
from app.features.models import DOMAINS
from app.features.selection import local_date
from app.main import create_app
from app.pipeline import run_checkpoint
from app.synthetic.scenarios import CASES
from app.synthetic.writer import json_bytes
from tests.api.test_api import KEY, FixedClock, runtime
from tests.db.test_ingest import USER
from tests.db.test_recalc import SETTINGS

pytestmark = pytest.mark.db


def post_dataset(client, clock, dataset, resend=False, seed=None):
    events = {event.event_id: event for event in dataset.events}
    zone = dataset.context.timezone
    times = [utc(b.delivered_at) for b in dataset.deliveries] + [utc(p.effective_at) for p in dataset.context.checkpoints]
    clock.now = min(times) - timedelta(seconds=1)
    coverage = [{"domain": d, "start_day": w.start_day.isoformat(), "end_day": w.end_day.isoformat(),
                 "timezone": zone, "status": getattr(w.domains, d)} for w in dataset.context.coverage for d in DOMAINS]
    assert client.post("/v1/health/sync", headers=KEY, json={
        "request_id": str(uuid5(NAMESPACE_URL, f"{dataset.context.id}/coverage")), "device_timezone": zone,
        "coverage": coverage, "events": []}).status_code == 200
    batches = list(dataset.deliveries)
    if seed is not None:  # shuffle batches that share a delivery time
        groups = [list(g) for _, g in itertools.groupby(batches, key=lambda b: utc(b.delivered_at))]
        for group in groups:
            random.Random(seed).shuffle(group)
        batches = [batch for group in groups for batch in group]
    for batch in batches:
        clock.now = utc(batch.delivered_at)
        body = {"request_id": str(uuid5(NAMESPACE_URL, f"{dataset.context.id}/{batch.id}")), "device_timezone": zone,
                "coverage": [], "events": [json_value(events[event_id]) for event_id in batch.event_ids]}
        for _ in range(2 if resend else 1):
            response = client.post("/v1/health/sync", headers=KEY, json=body)
            assert response.status_code == 200, response.text


def assert_parity(engine, dataset):
    zone = dataset.context.timezone
    with engine.connect() as conn:
        for point in dataset.context.checkpoints:
            revision = conn.execute(select(func.max(sync_requests.c.revision)).where(
                sync_requests.c.user_id == USER, sync_requests.c.received_at <= utc(point.known_at))).scalar_one()
            report, state, widget = recalc.compute(conn, USER, SETTINGS, revision or 0,
                                                   local_date(point.effective_at, zone), zone,
                                                   point.effective_at, point.known_at)
            expected = run_checkpoint(dataset, point.id, SETTINGS)
            where = (dataset.context.id, point.id)
            assert json_bytes(report.features) == json_bytes(expected.features_report.features), where
            assert json_bytes(state) == json_bytes(expected.health_state), where
            assert json_bytes(widget) == json_bytes(expected.widget_state), where


def client_for(engine):
    clock = FixedClock(None)
    # Inline recalculation is deferred (budget 0) so thousands of uploads stay
    # fast; parity is checked by recomputing each checkpoint from storage.
    return TestClient(create_app(runtime(), clock=clock, engine=engine, inline_budget_seconds=0)), clock


@pytest.mark.parametrize("name", [name for name, _, _ in CASES])
@pytest.mark.parametrize("variant", ["in_order", "resent_and_shuffled"])
def test_every_scenario_matches_the_pipeline_through_postgres(db_engine, scenarios, name, variant):
    client, clock = client_for(db_engine)
    with client:
        post_dataset(client, clock, scenarios[name], resend=variant != "in_order",
                     seed=None if variant == "in_order" else 7)
    assert_parity(db_engine, scenarios[name])


def test_the_demo_matches_the_pipeline_through_postgres(db_engine, demo):
    client, clock = client_for(db_engine)
    with client:
        post_dataset(client, clock, demo)
    assert_parity(db_engine, demo)
