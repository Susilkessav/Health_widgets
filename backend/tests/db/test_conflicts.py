"""The three kinds of conflict, through storage (Step 6-8 plan section 5.3)."""
from datetime import date, timedelta

import pytest

from app import recalc
from app.contracts.canonical_events import DeleteEvent, PointMeasurement
from app.synthetic.generator import Builder, stable_id

from .test_ingest import NOW, USER, ZONE, body, hrv, statuses, sync
from .test_recalc import SETTINGS, history

pytestmark = pytest.mark.db
DAY = date(2026, 9, 22)


def features_now(engine, revision):
    with engine.connect() as conn:
        report, _, _ = recalc.compute(conn, USER, SETTINGS, revision, DAY, ZONE, NOW, NOW)
    return report


def test_a_provider_conflict_stays_quarantined_until_its_own_tombstone(db_engine):
    events = history()
    original = next(e for e in events if isinstance(e, PointMeasurement) and e.metric == "hrv_sdnn_ms"
                    and e.observed_at.date() == DAY)
    sync(db_engine, body(events))
    rival = PointMeasurement.model_validate({**original.model_dump(), "event_id": stable_id("rival"), "value": 80})
    assert statuses(sync(db_engine, body([rival]))) == [("conflict", "CONFLICTING_PROVIDER_RECORD")]
    quarantined = features_now(db_engine, 2)
    assert quarantined.features.hrv.value is None and f"hrv_conflict:{DAY}" in quarantined.diagnostics

    # A different replacement record is independent: the quarantine remains.
    replacement = Builder("conflicts", ZONE).point(DAY, "hrv_sdnn_ms", 52, "replacement")
    sync(db_engine, body([replacement]))
    still = features_now(db_engine, 3)
    assert f"hrv_conflict:{DAY}" in still.diagnostics

    # A tombstone for the conflicted record releases it; the replacement is used.
    tombstone = DeleteEvent(event_id=stable_id("release"), source="healthkit",
                            source_record_id=original.source_record_id, deleted_at=NOW)
    sync(db_engine, body([tombstone]))
    released = features_now(db_engine, 4)
    assert f"hrv_conflict:{DAY}" not in released.diagnostics and released.features.hrv.value == 52


def test_a_conflicting_step_bucket_is_resolved_by_a_newer_query(db_engine):
    b = Builder("steps", ZONE)
    at = NOW.replace(hour=13)
    first, second = b.snapshot(DAY, at, 4900), b.snapshot(DAY, at, 4821)  # same query time
    assert statuses(sync(db_engine, body([first, second]))) == [("accepted", None), ("accepted", None)]
    conflicted = features_now(db_engine, 1)
    assert conflicted.features.movement.steps is None and f"movement_conflict:{DAY}" in conflicted.diagnostics
    newer = b.snapshot(DAY, at, 4800, at + timedelta(minutes=30))
    sync(db_engine, body([newer]), now=NOW + timedelta(hours=1))
    with db_engine.connect() as conn:
        report, _, _ = recalc.compute(conn, USER, SETTINGS, 2, DAY, ZONE, NOW + timedelta(hours=1),
                                      NOW + timedelta(hours=1))
    assert report.features.movement.steps == 4800


def test_a_conflict_is_never_reported_as_a_duplicate(db_engine):
    original = hrv()
    sync(db_engine, body([original]))
    rival = PointMeasurement.model_validate({**original.model_dump(), "event_id": stable_id("x"), "value": 70})
    for _ in range(3):
        assert statuses(sync(db_engine, body([rival]))) == [("conflict", "CONFLICTING_PROVIDER_RECORD")]
