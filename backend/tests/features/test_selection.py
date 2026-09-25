from datetime import timedelta

import pytest

from app.contracts.canonical_events import PointMeasurement
from app.features.models import CalculationInputError, Observation
from app.features.selection import select_visible
from app.synthetic.generator import Builder, stable_id

from .conftest import DAY, ZONE, at, calc, context, history, observations, point


def reimport(event):
    return PointMeasurement.model_validate({**event.model_dump(), "event_id": stable_id("reimport", str(event.event_id))})


def test_retries_collapse_and_reimports_add_no_weight():
    b = Builder("t", ZONE)
    original = point(b, "a", "hrv_sdnn_ms", 50, at(7, 15))
    once = select_visible(observations(b), context())
    retried = [*observations(b), Observation(event=original, delivered_at=at(8))]
    copy = reimport(original)
    reimported = [*retried, Observation(event=copy, delivered_at=at(9))]
    assert select_visible(retried, context()).input_sha256 == once.input_sha256  # same client events
    selected = select_visible(reimported, context())
    assert len(selected.records) == 1 and not selected.conflicts
    assert selected.input_sha256 != once.input_sha256  # the reimport is a new visible client event


def test_a_reused_client_id_with_different_content_is_rejected():
    b = Builder("t", ZONE)
    original = point(b, "a", "hrv_sdnn_ms", 50, at(7, 15))
    changed = PointMeasurement.model_validate({**original.model_dump(), "value": 51})
    with pytest.raises(CalculationInputError):
        select_visible([*observations(b), Observation(event=changed, delivered_at=at(8))], context())


def test_equivalent_content_ignores_offsets_and_metadata_order():
    b = Builder("t", ZONE)
    original = point(b, "a", "hrv_sdnn_ms", 50, at(7, 15))
    data = original.model_dump()
    data["event_id"] = stable_id("other")
    data["observed_at"] = data["observed_at"].astimezone(at(7).tzinfo)  # same instant, local offset
    selected = select_visible([*observations(b), Observation(event=PointMeasurement.model_validate(data),
                                                            delivered_at=at(8))], context())
    assert len(selected.records) == 1 and not selected.conflicts


def test_conflicting_provider_records_are_quarantined_not_chosen():
    b = Builder("t", ZONE)
    history(b)
    original = b.point(DAY, "hrv_sdnn_ms", 50)
    rival = PointMeasurement.model_validate({**original.model_dump(), "event_id": stable_id("rival"), "value": 80})
    b.add(rival)
    report = calc(b)
    assert report.features.hrv.state == "missing" and report.features.hrv.value is None
    assert f"hrv_conflict:{DAY}" in report.diagnostics


@pytest.mark.parametrize("delete_first", [True, False])
def test_tombstones_apply_whichever_arrives_first(delete_first):
    b = Builder("t", ZONE)
    history(b)
    original = b.point(DAY, "hrv_sdnn_ms", 20, delivered_at=at(12) if delete_first else None)
    b.delete(original, at(9))
    b.point(DAY, "hrv_sdnn_ms", 50, "replacement", at(9, 1))
    report = calc(b)
    assert report.features.hrv.value == 50
    assert original.source_record_id in report.evidence["input"]["tombstoned"]


def test_repeated_deletions_with_different_times_are_not_a_conflict():
    b = Builder("t", ZONE)
    original = point(b, "a", "hrv_sdnn_ms", 50, at(7, 15))
    b.delete(original, at(8))
    later = b.delete(original, at(8))
    b.events[-1] = later.model_copy(update={"event_id": stable_id("again"), "deleted_at": at(10)})
    b.deliveries[-1] = b.deliveries[-1].model_copy(update={"event_ids": (b.events[-1].event_id,),
                                                           "id": "again", "delivered_at": at(10)})
    selected = select_visible(observations(b), context())
    assert not selected.records and not selected.conflicts


def test_deliveries_after_known_at_are_invisible():
    b = Builder("t", ZONE)
    point(b, "a", "hrv_sdnn_ms", 50, at(7, 15))
    b.deliveries[-1] = b.deliveries[-1].model_copy(update={"delivered_at": at(14)})
    assert not select_visible(observations(b), context()).records
    assert select_visible(observations(b), context(known=at(14))).records
