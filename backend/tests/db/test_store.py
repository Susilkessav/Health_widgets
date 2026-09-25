"""Storage round trips and the input loader (Step 6-8 plan sections 4 and 8.1)."""
from datetime import date, timedelta
from uuid import UUID

import pytest
from sqlalchemy import select, text

from app import store
from app.config import load_settings
from app.contracts._types import utc
from app.contracts.canonical_events import DeleteEvent, PointMeasurement
from app.db import health_events
from app.features.calculate import calculate_features
from app.features.models import CalculationContext
from app.features.selection import local_date
from app.synthetic.generator import Builder, stable_id
from app.synthetic.writer import json_bytes

from .helpers import USER, store_dataset

SETTINGS = load_settings()
pytestmark = pytest.mark.db


def test_every_corpus_event_round_trips_exactly(db_engine, demo, scenarios):
    for index, dataset in enumerate([demo, *scenarios.values()]):
        user = store_dataset(db_engine, dataset, user_id=UUID(int=index + 1))
        with db_engine.connect() as conn:
            revision, _, _ = store.current_revision(conn, user)
            loaded = {o.event.event_id: o.event for o in store.load_all_observations(conn, user, revision)}
        for event in dataset.events:
            if event.event_id in loaded:  # reimports share a stored version
                assert json_bytes(loaded[event.event_id]) == json_bytes(event)


def test_loaded_inputs_are_sufficient_at_every_checkpoint(db_engine, demo, scenarios):
    for dataset in [demo, *scenarios.values()]:
        store_dataset(db_engine, dataset)
        zone = dataset.context.timezone
        with db_engine.connect() as conn:
            revision, _, _ = store.current_revision(conn, USER)
            everything = store.load_all_observations(conn, USER, revision)
            for point in dataset.context.checkpoints:
                day = local_date(point.effective_at, zone)
                subset, coverage = store.load_inputs(conn, USER, revision, day, zone, point.effective_at, SETTINGS)
                context = CalculationContext(day=day, timezone=zone, effective_at=utc(point.effective_at),
                                             known_at=utc(point.known_at), coverage=tuple(coverage))
                full = calculate_features(everything, context, SETTINGS)
                part = calculate_features(subset, context, SETTINGS)
                assert json_bytes(part.features) == json_bytes(full.features), (dataset.context.id, point.id)
                assert part.diagnostics == full.diagnostics
        with db_engine.begin() as conn:
            conn.execute(text(
                "TRUNCATE health_events, coverage_declarations, users RESTART IDENTITY CASCADE"))


def test_a_tombstone_received_60_days_later_is_still_loaded(db_engine):
    b = Builder("late", "America/Chicago")
    for index in range(20):
        b.daily(date(2026, 9, 1) + timedelta(days=index))
    target = next(e for e in b.events if isinstance(e, PointMeasurement))
    day = local_date(target.observed_at, "America/Chicago")
    with db_engine.begin() as conn:
        store.ensure_user(conn, USER, "America/Chicago")
        revision, received = store.next_revision(conn, USER, target.observed_at)
        for event in b.events:
            store.insert_version(conn, USER, event, store.content_sha256(event), revision, received)
        tombstone = DeleteEvent(event_id=stable_id("t"), source="healthkit", source_record_id=target.source_record_id,
                                deleted_at=target.observed_at + timedelta(days=60))
        later, received = store.next_revision(conn, USER, tombstone.deleted_at)
        store.insert_version(conn, USER, tombstone, store.content_sha256(tombstone), later, received)
    with db_engine.connect() as conn:
        loaded, _ = store.load_inputs(conn, USER, later, day, "America/Chicago",
                                      target.observed_at + timedelta(hours=1), SETTINGS)
    assert any(isinstance(o.event, DeleteEvent) for o in loaded)


def test_conflicting_versions_on_different_dates_are_both_loaded(db_engine):
    b = Builder("conflict", "America/Chicago")
    here = b.point(date(2026, 9, 22), "hrv_sdnn_ms", 50)
    far = PointMeasurement.model_validate({**here.model_dump(), "event_id": stable_id("far"),
                                           "observed_at": here.observed_at - timedelta(days=90),
                                           "metadata": {**here.metadata.model_dump(),
                                                        "sample_start_at": here.observed_at - timedelta(days=90, minutes=1),
                                                        "sample_end_at": here.observed_at - timedelta(days=90)}})
    with db_engine.begin() as conn:
        store.ensure_user(conn, USER, "America/Chicago")
        revision, received = store.next_revision(conn, USER, here.observed_at)
        for event in (here, far):
            store.insert_version(conn, USER, event, store.content_sha256(event), revision, received)
    with db_engine.connect() as conn:
        loaded, _ = store.load_inputs(conn, USER, revision, here.observed_at.date(), "America/Chicago",
                                      here.observed_at + timedelta(hours=1), SETTINGS)
    assert {o.event.event_id for o in loaded} == {here.event_id, far.event_id}


def test_users_are_isolated(db_engine, scenarios):
    other = UUID(int=99)
    store_dataset(db_engine, scenarios["typical"])
    store_dataset(db_engine, scenarios["short_sleep"], user_id=other)
    with db_engine.connect() as conn:
        mine = {o.event.event_id for o in store.load_all_observations(conn, USER, 10**9)}
        theirs = {o.event.event_id for o in store.load_all_observations(conn, other, 10**9)}
        assert mine == {e.event_id for e in scenarios["typical"].events}
        assert theirs == {e.event_id for e in scenarios["short_sleep"].events}
        assert conn.execute(select(health_events.c.user_id).distinct()).scalars().all()
