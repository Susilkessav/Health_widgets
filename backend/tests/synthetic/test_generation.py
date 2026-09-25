from datetime import date, timedelta
from uuid import uuid4
from zoneinfo import ZoneInfo

import pytest
from pydantic import TypeAdapter, ValidationError

from app.contracts._types import utc
from app.contracts.canonical_events import (
    CanonicalEvent, DailyActivitySnapshot, DeleteEvent, PointMeasurement,
)
from app.synthetic.generator import generate_demo, recorded_at
from app.synthetic.models import Dataset, GenerationConfig
from app.synthetic.writer import json_bytes


def test_all_events_validate_roundtrip_and_have_consistent_deliveries(demo, scenarios):
    adapter = TypeAdapter(CanonicalEvent)
    client_ids = set()
    for dataset in (demo, *scenarios.values()):
        assert dataset.context.synthetic
        assert json_bytes(Dataset.model_validate_json(json_bytes(dataset))) == json_bytes(dataset)
        events = {event.event_id: event for event in dataset.events}
        assert not client_ids.intersection(events)
        client_ids.update(events)
        assert {eid for batch in dataset.deliveries for eid in batch.event_ids} == set(events)
        assert list(dataset.deliveries) == sorted(dataset.deliveries, key=lambda d: (utc(d.delivered_at), d.id))
        for event in dataset.events:
            assert json_bytes(adapter.validate_json(json_bytes(event))) == json_bytes(event)
            if hasattr(event, "metadata"):
                assert event.metadata.source_bundle_id.startswith("org.homeostat.synthetic.")
            if isinstance(event, DeleteEvent):
                assert any(e.source_record_id == event.source_record_id and not isinstance(e, DeleteEvent)
                           for e in dataset.events)
        for delivery in dataset.deliveries:
            assert all(utc(delivery.delivered_at) >= recorded_at(events[eid]) for eid in delivery.event_ids)


def test_default_demo_days_checkpoints_and_closing_snapshots(demo):
    expected = {date(2026, 8, 14) + timedelta(days=i) for i in range(40)}
    snapshots = [e for e in demo.events if isinstance(e, DailyActivitySnapshot)]
    assert {e.day for e in snapshots} == expected
    assert len(snapshots) == 160
    assert len(demo.context.checkpoints) == 120
    zone = ZoneInfo("America/Chicago")
    for day in expected:
        reads = sorted((e for e in snapshots if e.day == day), key=lambda e: e.as_of)
        assert [e.as_of.astimezone(zone).hour for e in reads] == [8, 13, 18, 0]
        assert reads[-1].as_of.astimezone(zone).date() == day + timedelta(days=1)
        assert [e.steps for e in reads] == sorted(e.steps for e in reads)


def test_demo_variation_and_seed_scoped_ids(demo):
    other = generate_demo(GenerationConfig(seed=17))
    assert json_bytes(other) != json_bytes(demo)
    assert {e.event_id for e in demo.events}.isdisjoint(e.event_id for e in other.events)
    def measurements(dataset):
        return sorted((e.observed_at, e.metric, e.value) for e in dataset.events if isinstance(e, PointMeasurement))
    assert measurements(demo) != measurements(other)
    assert json_bytes(generate_demo(GenerationConfig())) == json_bytes(demo)


def test_custom_date_duration_and_zone():
    config = GenerationConfig(seed=17, start_date=date(2025, 1, 1), days=45, timezone="UTC")
    data = generate_demo(config)
    snapshots = [e for e in data.events if isinstance(e, DailyActivitySnapshot)]
    assert len({e.day for e in snapshots}) == 45
    assert data.context.end_day == date(2025, 2, 14)
    assert {e.timezone for e in snapshots} == {"UTC"}


@pytest.mark.parametrize("mutation", ["delivery", "checkpoint", "event", "duplicate"])
def test_broken_fixture_references_are_rejected(scenarios, mutation):
    data = scenarios["steps_upward"].model_dump()
    if mutation == "delivery":
        data["deliveries"][0]["event_ids"] = (uuid4(),)
    elif mutation == "checkpoint":
        data["expectations"]["assertions"][0]["checkpoint"] = "unknown"
    elif mutation == "event":
        data["expectations"]["assertions"][0]["event_ids"] = (uuid4(),)
    else:
        data["events"] += (data["events"][0],)
    with pytest.raises(ValidationError):
        Dataset.model_validate(data)


def test_zone_where_dst_skips_midnight_generates_a_valid_closing_boundary():
    # America/Santiago jumps from 2026-09-05 23:59:59 to 2026-09-06 01:00.
    data = generate_demo(GenerationConfig(timezone="America/Santiago"))
    closing = next(e for e in data.events if isinstance(e, DailyActivitySnapshot)
                   and e.day == date(2026, 9, 5) and e.as_of.astimezone(ZoneInfo("America/Santiago")).day == 6)
    assert closing.as_of.astimezone(ZoneInfo("America/Santiago")).hour == 1
