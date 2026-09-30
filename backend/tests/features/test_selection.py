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


# ---------------------------------------------------------------- lost-anchor reconciliation (Step 9-13 §3B)

HRV = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"


def scan(members, revision, start=None, kind=HRV):
    from app.features.models import VisibilityScan
    return VisibilityScan(healthkit_type=kind, scope_start_at=start or at(0, day=DAY - timedelta(days=36)),
                          members=tuple(sorted(members)), revision=revision)


def with_scans(*scans):
    return context().model_copy(update={"visibility": scans})


def two_points():
    b = Builder("t", ZONE)
    kept = point(b, "a", "hrv_sdnn_ms", 50, at(7, 15))
    gone = point(b, "b", "hrv_sdnn_ms", 60, at(8, 15))
    delivered = [Observation(event=e, delivered_at=at(9), revision=1) for e in (kept, gone)]
    return kept, gone, delivered


def test_a_scan_withdraws_earlier_records_it_does_not_list():
    kept, gone, delivered = two_points()
    selected = select_visible(delivered, with_scans(scan([kept.source_record_id], revision=2)))
    assert [r.source_record_id for r in selected.records] == [kept.source_record_id]
    assert selected.withdrawn == (gone.source_record_id,) and not selected.tombstoned


def test_a_scan_never_withdraws_records_received_at_or_after_it():
    kept, gone, delivered = two_points()
    later = [Observation(event=e, delivered_at=at(9), revision=2) for e in (kept, gone)]
    assert not select_visible(later, with_scans(scan([], revision=2))).withdrawn
    assert not select_visible(delivered, with_scans(scan([], revision=1))).withdrawn


def test_a_newer_scan_listing_the_record_again_restores_it():
    kept, gone, delivered = two_points()
    both = [kept.source_record_id, gone.source_record_id]
    selected = select_visible(delivered, with_scans(scan([kept.source_record_id], 2), scan(both, 3)))
    assert not selected.withdrawn and len(selected.records) == 2


def test_scans_are_scoped_to_their_type_and_start():
    kept, gone, delivered = two_points()
    other_type = scan([], 2, kind="HKQuantityTypeIdentifierRestingHeartRate")
    after_both = scan([], 2, start=at(9))
    assert not select_visible(delivered, with_scans(other_type, after_both)).withdrawn


def test_scans_change_the_input_hash_only_when_present():
    kept, gone, delivered = two_points()
    plain = select_visible(delivered, context()).input_sha256
    assert select_visible(delivered, with_scans()).input_sha256 == plain
    assert select_visible(delivered, with_scans(scan([kept.source_record_id, gone.source_record_id], 2))
                          ).input_sha256 != plain
