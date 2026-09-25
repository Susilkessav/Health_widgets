"""Step 1 contract tests.

Fixtures are complete versions of plan_G1.md's abbreviated examples. They
differ from the examples where backend/README.md "Deviations from the G1
examples" says the contract requires more (real UUIDs, source metadata,
per-domain calibration, provenance, config_sha256, driver domains).

Round-trip tests compare serialized JSON rather than models, because Python
never treats a datetime inside a DST-ambiguous hour as equal to one in another
zone (PEP 495), even when both are the same instant.
"""
from __future__ import annotations

import hashlib
import math
from datetime import date, datetime, timedelta
from itertools import combinations, permutations
from uuid import uuid4
from zoneinfo import ZoneInfo

import pytest
from hypothesis import given, strategies as st
from pydantic import TypeAdapter, ValidationError

from app.contracts._types import utc
from app.contracts.canonical_events import (
    CanonicalEvent,
    DailyActivitySnapshot,
    IntervalEvent,
    PointMeasurement,
    SampleMetadata,
    SnapshotConflictError,
    WorkoutEvent,
    resolve_snapshot_bucket,
    snapshot_record_id,
)
from app.contracts.features import DailyFeatures, HRVFeatures, MovementFeatures, SleepFeatures, WorkoutFeatures
from app.contracts.health_state import Calibration, Driver, HealthState, RecoveryState, SleepState
from app.contracts.widget_state import WidgetState

CHI = ZoneInfo("America/Chicago")
DAY = date(2026, 9, 22)
NOW = datetime(2026, 9, 22, 13, 20, tzinfo=CHI)
CONFIG = hashlib.sha256(b"homeostat-test-config").hexdigest()

events = TypeAdapter(CanonicalEvent)


def round_trips(adapter: TypeAdapter, value) -> bool:
    dumped = adapter.dump_json(value)
    return adapter.dump_json(adapter.validate_json(dumped)) == dumped


# ---------------------------------------------------------------------------
# Canonical event fixtures
# ---------------------------------------------------------------------------

def sample_meta(start: datetime, end: datetime, **overrides) -> dict:
    return {
        "healthkit_type": "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        "source_name": "Apple Watch",
        "source_bundle_id": "com.apple.health.8F2A",
        "source_revision": "11.0",
        "device_product_type": "Watch7,1",
        "timezone": "America/Chicago",
        "timezone_source": "sample_metadata",
        "sample_start_at": start,
        "sample_end_at": end,
        **overrides,
    }


def point_event(**overrides) -> dict:
    observed = datetime(2026, 9, 22, 6, 40, tzinfo=CHI)
    return {
        "event_id": uuid4(),
        "source": "healthkit",
        "source_record_id": "hk-hrv-1",
        "event_type": "point_measurement",
        "metric": "hrv_sdnn_ms",
        "observed_at": observed,
        "value": 54.2,
        "unit": "ms",
        "metadata": sample_meta(observed - timedelta(minutes=1), observed),
        **overrides,
    }


def rhr_point_event(**overrides) -> dict:
    observed = datetime(2026, 9, 22, 7, 0, tzinfo=CHI)
    return point_event(**{
        "metric": "resting_hr_bpm", "unit": "bpm", "value": 58, "source_record_id": "hk-rhr-1",
        "observed_at": observed,
        "metadata": sample_meta(observed - timedelta(minutes=1), observed,
                                healthkit_type="HKQuantityTypeIdentifierRestingHeartRate"),
        **overrides,
    })


def interval_event(start: datetime, end: datetime, **overrides) -> dict:
    return {
        "event_id": uuid4(),
        "source": "healthkit",
        "source_record_id": "hk-sleep-1",
        "event_type": "interval",
        "kind": "sleep_stage",
        "value": "asleep_core",
        "start_at": start,
        "end_at": end,
        "metadata": sample_meta(start, end, healthkit_type="HKCategoryTypeIdentifierSleepAnalysis"),
        **overrides,
    }


def workout_event(start: datetime, end: datetime, duration_minutes: float, **overrides) -> dict:
    return {
        "event_id": uuid4(),
        "source": "healthkit",
        "source_record_id": "hk-workout-1",
        "event_type": "workout",
        "workout_type": "traditional_strength_training",
        "start_at": start,
        "end_at": end,
        "duration_minutes": duration_minutes,
        "metadata": sample_meta(start, end, healthkit_type="HKWorkoutTypeIdentifier"),
        **overrides,
    }


def snapshot_event(as_of=NOW, queried_at=NOW, timezone="America/Chicago", day=DAY, steps=4821, **overrides) -> dict:
    return {
        "event_id": uuid4(),
        "source": "healthkit",
        "source_record_id": snapshot_record_id(timezone, day, as_of, queried_at, steps),
        "event_type": "daily_activity_snapshot",
        "day": day,
        "timezone": timezone,
        "as_of": as_of,
        "queried_at": queried_at,
        "steps": steps,
        **overrides,
    }


def delete_event(**overrides) -> dict:
    return {
        "event_id": uuid4(),
        "source": "healthkit",
        "source_record_id": "hk-sleep-1",
        "event_type": "delete",
        "deleted_at": NOW,
        **overrides,
    }


# ---------------------------------------------------------------------------
# Canonical events: valid shapes and routing
# ---------------------------------------------------------------------------

def test_every_event_type_validates_and_routes_by_event_type():
    fixtures = [
        point_event(),
        rhr_point_event(),
        interval_event(NOW - timedelta(hours=7), NOW - timedelta(hours=6)),
        workout_event(NOW - timedelta(hours=1), NOW, 56),
        snapshot_event(),
        delete_event(),
    ]
    for data in fixtures:
        event = events.validate_python(data)
        assert event.event_type == data["event_type"]
        assert round_trips(events, event)


_zoned = st.datetimes(
    min_value=datetime(2000, 1, 1),
    max_value=datetime(2037, 12, 31),
    timezones=st.timezones(),
    allow_imaginary=False,
)


@given(
    kind=st.sampled_from(["point", "interval", "workout", "snapshot", "delete"]),
    start=_zoned,
    minutes=st.integers(min_value=1, max_value=600),
)
def test_every_event_type_round_trips_in_any_timezone(kind, start, minutes):
    zone = start.tzinfo
    end = (utc(start) + timedelta(minutes=minutes)).astimezone(zone)
    def meta(healthkit_type: str) -> dict:
        return sample_meta(start, end, timezone=zone.key, healthkit_type=healthkit_type)

    data = {
        "point": lambda: point_event(
            observed_at=end, metadata=meta("HKQuantityTypeIdentifierHeartRateVariabilitySDNN")
        ),
        "interval": lambda: interval_event(start, end, metadata=meta("HKCategoryTypeIdentifierSleepAnalysis")),
        "workout": lambda: workout_event(start, end, minutes, metadata=meta("HKWorkoutTypeIdentifier")),
        "snapshot": lambda: snapshot_event(
            as_of=start, queried_at=end, timezone=zone.key, day=utc(start).astimezone(zone).date()
        ),
        "delete": lambda: delete_event(deleted_at=start),
    }[kind]()
    assert round_trips(events, events.validate_python(data))


# ---------------------------------------------------------------------------
# Canonical events: rejections
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "overrides",
    [
        {"unit": "bpm"},                                            # INVALID_UNIT
        {"metric": "vo2_max", "unit": "ml/kg/min"},                 # UNKNOWN_METRIC
        {"observed_at": datetime(2026, 9, 22, 6, 40)},              # naive
        {"value": math.nan},
        {"value": math.inf},
        {"value": True},                                            # bool is not a measurement
        {"value": "54.2"},                                          # numeric string
        {"source_record_id": ""},
        {"source_record_id": "   "},
        {"eyes": "tired"},                                          # extra field
        {"observed_at": datetime(2026, 9, 22, 7, 0, tzinfo=CHI)},   # outside the sample window
    ],
)
def test_point_measurement_rejects(overrides):
    with pytest.raises(ValidationError):
        PointMeasurement(**point_event(**overrides))


def test_wrong_unit_error_is_coded():
    with pytest.raises(ValidationError, match="INVALID_UNIT"):
        PointMeasurement(**point_event(unit="bpm"))


# America/Chicago falls back at 2026-11-01 02:00 CDT -> 01:00 CST, so 01:00-02:00 happens twice.
FIRST_0150 = datetime(2026, 11, 1, 1, 50, tzinfo=CHI)           # CDT, 06:50Z
SECOND_0110 = datetime(2026, 11, 1, 1, 10, tzinfo=CHI, fold=1)  # CST, 07:10Z


def test_interval_across_dst_fall_back_is_ordered_by_instant():
    valid = IntervalEvent(**interval_event(FIRST_0150, SECOND_0110))
    assert (utc(valid.end_at) - utc(valid.start_at)) == timedelta(minutes=20)
    assert round_trips(events, valid)
    with pytest.raises(ValidationError):
        IntervalEvent(**interval_event(SECOND_0110, FIRST_0150))  # -20 minutes


def test_workout_across_dst_fall_back_is_ordered_by_instant():
    assert WorkoutEvent(**workout_event(FIRST_0150, SECOND_0110, 20))
    with pytest.raises(ValidationError):
        WorkoutEvent(**workout_event(SECOND_0110, FIRST_0150, 20))


def test_interval_rejects_end_before_start():
    with pytest.raises(ValidationError):
        IntervalEvent(**interval_event(NOW, NOW - timedelta(hours=1)))


@pytest.mark.parametrize(
    "overrides",
    [
        {"duration_minutes": 500},   # far longer than the one-minute interval
        {"workout_type": ""},
        {"duration_minutes": -1},
    ],
)
def test_workout_rejects(overrides):
    with pytest.raises(ValidationError):
        WorkoutEvent(**{**workout_event(NOW - timedelta(minutes=1), NOW, 1), **overrides})


def test_workout_duration_may_be_shorter_than_elapsed_because_of_pauses():
    assert WorkoutEvent(**workout_event(NOW - timedelta(minutes=60), NOW, 45)).duration_minutes == 45


# ---------------------------------------------------------------------------
# Sample metadata
# ---------------------------------------------------------------------------

def test_sample_metadata_preserves_unmodelled_healthkit_metadata():
    meta = sample_meta(
        NOW - timedelta(minutes=1),
        NOW,
        timezone_source="device_at_ingestion",
        provider_metadata=[
            {"key": "HKMetadataKeyHeartRateMotionContext", "value": "1"},
            {"key": "HKMetadataKeyDeviceSerialNumber", "value": "ABC123"},
        ],
    )
    event = PointMeasurement(**point_event(observed_at=NOW, metadata=meta))
    restored = events.validate_json(events.dump_json(event))
    assert restored.metadata.provider_metadata == event.metadata.provider_metadata
    assert restored.metadata.healthkit_type == "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
    assert utc(restored.metadata.sample_start_at) == utc(NOW - timedelta(minutes=1))


@pytest.mark.parametrize(
    "overrides",
    [
        {"timezone": "not/a/timezone"},
        {"timezone": "../../etc/passwd"},
        {"timezone": ""},
        {"source_name": ""},
        {"source_bundle_id": None},
        {"healthkit_type": " "},
        {"timezone_source": "guess"},
        {"provider_metadata": [{"key": "k", "value": "a"}, {"key": "k", "value": "b"}]},
    ],
)
def test_sample_metadata_rejects(overrides):
    with pytest.raises(ValidationError):
        SampleMetadata(**sample_meta(NOW - timedelta(minutes=1), NOW, **overrides))


def test_sample_metadata_rejects_end_before_start():
    with pytest.raises(ValidationError):
        SampleMetadata(**sample_meta(NOW, NOW - timedelta(minutes=1)))


def test_sample_events_require_metadata():
    data = point_event()
    del data["metadata"]
    with pytest.raises(ValidationError):
        PointMeasurement(**data)


# ---------------------------------------------------------------------------
# Step snapshots: identity, corrections, local day
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("corrected_steps", [4000, 4350])
def test_recalculated_bucket_is_resolved_by_query_time_not_upload_order(corrected_steps):
    bucket_end = datetime(2026, 9, 22, 13, 0, tzinfo=CHI)
    first_read = DailyActivitySnapshot(**snapshot_event(as_of=bucket_end, queried_at=bucket_end, steps=4100))
    corrected = DailyActivitySnapshot(
        **snapshot_event(as_of=bucket_end, queried_at=bucket_end + timedelta(hours=2), steps=corrected_steps)
    )
    assert first_read.bucket == corrected.bucket
    assert first_read.source_record_id != corrected.source_record_id
    # The later query wins whichever order the uploads arrived in.
    for arrival in ([first_read, corrected], [corrected, first_read]):
        assert resolve_snapshot_bucket(arrival).steps == corrected_steps


def test_intraday_snapshots_are_distinct_buckets():
    morning = DailyActivitySnapshot(**snapshot_event(as_of=NOW - timedelta(hours=4), queried_at=NOW))
    afternoon = DailyActivitySnapshot(**snapshot_event(as_of=NOW, queried_at=NOW))
    assert morning.bucket != afternoon.bucket


def test_snapshot_accepts_the_days_closing_midnight():
    midnight = datetime(2026, 9, 23, 0, 0, tzinfo=CHI)
    assert DailyActivitySnapshot(**snapshot_event(as_of=midnight, queried_at=midnight)).day == DAY


@pytest.mark.parametrize(
    "overrides",
    [
        {"steps": -1},
        {"steps": 4821.5},
        {"steps": True},
        {"steps": "4821"},
        {"source_record_id": "steps:2026-09-22"},   # not the canonical snapshot id
    ],
)
def test_snapshot_rejects(overrides):
    with pytest.raises(ValidationError):
        DailyActivitySnapshot(**snapshot_event(**overrides))


def test_snapshot_rejects_as_of_outside_its_local_day():
    # 2026-09-23 01:00 in Chicago is not on 2026-09-22.
    late = datetime(2026, 9, 23, 1, 0, tzinfo=CHI)
    with pytest.raises(ValidationError):
        DailyActivitySnapshot(**snapshot_event(as_of=late, queried_at=late))


def test_snapshot_rejects_query_before_as_of():
    with pytest.raises(ValidationError):
        DailyActivitySnapshot(**snapshot_event(as_of=NOW, queried_at=NOW - timedelta(minutes=1)))


def test_snapshot_rejects_invalid_timezone():
    with pytest.raises(ValidationError):
        DailyActivitySnapshot(**snapshot_event(timezone="Mars/Olympus"))


# ---------------------------------------------------------------------------
# DailyFeatures fixtures
# ---------------------------------------------------------------------------

SLEEP_START = datetime(2026, 9, 21, 23, 41, tzinfo=CHI)
SLEEP_END = datetime(2026, 9, 22, 6, 3, tzinfo=CHI)
WORKOUT_END = NOW - timedelta(minutes=78)
WORKOUT_START = WORKOUT_END - timedelta(minutes=62)


def calibrating(**overrides) -> dict:
    return {"baseline_status": "calibrating", "usable_days": 3, "required_days": 14,
            "confidence": 0.4, "state": "calibrating", **overrides}


def sleep_ready(**overrides) -> dict:
    return {
        "baseline_status": "ready", "usable_days": 19, "required_days": 14, "confidence": 0.97,
        "state": "below_baseline",
        "hours": 5.97, "sleep_start": SLEEP_START, "sleep_end": SLEEP_END, "span_hours": 382 / 60,
        "in_bed_hours": 6.8, "awake_minutes": 12, "timezone": "America/Chicago",
        "source": "Apple Watch", "source_policy_version": "sleep-source-policy@0.1.0",
        "baseline_hours": 7.27, "baseline_mad_hours": 0.4, "delta_hours": -1.30, "ratio": 0.821,
        **overrides,
    }


def hrv_ready(**overrides) -> dict:
    return {
        "baseline_status": "ready", "usable_days": 19, "required_days": 14, "confidence": 0.92,
        "state": "typical", "value": 54.2, "observed_at": datetime(2026, 9, 22, 6, 40, tzinfo=CHI),
        "source_record_id": "hk-hrv-1", "source_name": "Apple Watch",
        "baseline": 58.0, "mad": 6.1, "robust_z": -0.42,
        **overrides,
    }


def rhr_ready(**overrides) -> dict:
    return {
        "baseline_status": "ready", "usable_days": 19, "required_days": 14, "confidence": 0.95,
        "state": "typical", "value": 58, "observed_at": datetime(2026, 9, 22, 7, 0, tzinfo=CHI),
        "source_record_id": "hk-rhr-1", "source_name": "Apple Watch",
        "baseline": 57.0, "mad": 2.0, "robust_z": 0.34,
        **overrides,
    }


def movement_ready(**overrides) -> dict:
    return {
        "baseline_status": "ready", "usable_days": 19, "required_days": 14, "confidence": 0.91,
        "state": "typical", "steps": 4821, "as_of": NOW,
        "source_record_id": snapshot_record_id("America/Chicago", DAY, NOW, NOW, 4821),
        "expected_steps_now": 6300, "ratio": 0.765,
        **overrides,
    }


def workout_recent(**overrides) -> dict:
    return {
        "state": "recent_workout", "confidence": 1.0, "type": "traditional_strength_training",
        "last_workout_start": WORKOUT_START, "last_workout_end": WORKOUT_END,
        "source_record_id": "hk-workout-1", "source_name": "Apple Watch", "hours_since": 1.3,
        "workout_minutes_today": 62, "workout_minutes_last_7d": 180,
        **overrides,
    }


def features(**overrides) -> DailyFeatures:
    return DailyFeatures.model_validate({
        "config_sha256": CONFIG, "day": DAY, "timezone": "America/Chicago", "effective_at": NOW,
        "sleep": sleep_ready(), "hrv": hrv_ready(), "rhr": rhr_ready(),
        "movement": movement_ready(), "workout": workout_recent(),
        **overrides,
    })


# ---------------------------------------------------------------------------
# DailyFeatures: valid combinations
# ---------------------------------------------------------------------------

def test_ready_features_validate_and_round_trip():
    assert round_trips(TypeAdapter(DailyFeatures), features())


def test_calibrating_features_validate_and_may_show_raw_values():
    calib = features(
        sleep=calibrating(hours=5.97, sleep_start=SLEEP_START, sleep_end=SLEEP_END, span_hours=382 / 60,
                          timezone="America/Chicago", source="Apple Watch",
                          source_policy_version="sleep-source-policy@0.1.0"),
        hrv=calibrating(), rhr=calibrating(), movement=calibrating(),
        workout={"state": "none_recent", "confidence": 1.0,
                 "workout_minutes_today": 0, "workout_minutes_last_7d": 0},
    )
    assert calib.sleep.baseline_hours is None
    assert calib.sleep.hours == 5.97


def test_hrv_can_be_missing_today_with_a_ready_baseline():
    hrv = HRVFeatures(**hrv_ready(state="missing", value=None, observed_at=None,
                                  source_record_id=None, source_name=None, robust_z=None))
    assert hrv.value is None
    assert hrv.baseline == 58.0


def test_workout_none_recent_keeps_an_older_workout():
    old_end = NOW - timedelta(hours=24)
    workout = features(workout=workout_recent(
        state="none_recent", last_workout_start=old_end - timedelta(hours=1), last_workout_end=old_end,
        hours_since=24.0, workout_minutes_today=0,
    )).workout
    assert workout.state == "none_recent"
    assert workout.last_workout_end == old_end


def test_workout_missing_differs_from_none_recent():
    missing = WorkoutFeatures(state="missing", confidence=0.0)
    assert missing.workout_minutes_today is None
    none_recent = WorkoutFeatures(state="none_recent", confidence=1.0,
                                  workout_minutes_today=0, workout_minutes_last_7d=0)
    assert none_recent.workout_minutes_today == 0


def test_movement_with_zero_expected_steps_is_typical_without_ratio():
    movement = MovementFeatures(**movement_ready(expected_steps_now=0, ratio=None, steps=12))
    assert movement.ratio is None


# ---------------------------------------------------------------------------
# DailyFeatures: rejected combinations
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "block",
    [
        calibrating(state="typical", usable_days=0),                          # typical, no history, no value
        sleep_ready(usable_days=3),                                           # ready with 3 < 14 days
        calibrating(usable_days=14),                                          # calibrating with 14 >= 14 days
        calibrating(baseline_hours=7.0),                                      # baseline while calibrating
        sleep_ready(baseline_hours=None, delta_hours=None, ratio=None),       # below_baseline, no baseline
        sleep_ready(delta_hours=None),                                        # classification without comparison
        sleep_ready(state="missing"),                                         # missing but value present
        sleep_ready(sleep_end=SLEEP_START - timedelta(hours=1)),              # ends before it starts
        sleep_ready(hours=8.0, delta_hours=0.73, ratio=1.1),                  # asleep > span
        sleep_ready(span_hours=9.0),                                          # span != end - start
        sleep_ready(delta_hours=-2.0),                                        # delta arithmetic
        sleep_ready(ratio=0.5),                                               # ratio arithmetic
        sleep_ready(source_policy_version=None),                              # provenance required
        sleep_ready(timezone="not/a/timezone"),
        sleep_ready(confidence=1.5),
        sleep_ready(confidence=True),
    ],
)
def test_sleep_features_reject(block):
    with pytest.raises(ValidationError):
        SleepFeatures(**block)


@pytest.mark.parametrize(
    "block",
    [
        calibrating(state="below_usual", robust_z=-1.5),                      # abnormal while calibrating
        calibrating(robust_z=-1.5),                                           # comparison while calibrating
        hrv_ready(state="missing", value=None, observed_at=None, source_record_id=None,
                  source_name=None),                                          # missing but robust_z kept
        hrv_ready(robust_z=None),                                             # classification without z
        hrv_ready(baseline=None),                                             # ready without baseline
        hrv_ready(observed_at=None),                                          # value without provenance
        hrv_ready(value=math.nan),
        hrv_ready(value=True),
    ],
)
def test_hrv_features_reject(block):
    with pytest.raises(ValidationError):
        HRVFeatures(**block)


@pytest.mark.parametrize(
    "block",
    [
        movement_ready(state="behind_usual", steps=None, as_of=None, source_record_id=None,
                       expected_steps_now=None, ratio=None),                  # behind with nothing
        movement_ready(expected_steps_now=0),                                 # ratio with zero denominator
        movement_ready(expected_steps_now=0, ratio=None, state="behind_usual"),
        movement_ready(ratio=2.0),                                            # ratio arithmetic
        movement_ready(steps=True),
        calibrating(expected_steps_now=5000),
    ],
)
def test_movement_features_reject(block):
    with pytest.raises(ValidationError):
        MovementFeatures(**block)


@pytest.mark.parametrize(
    "block",
    [
        workout_recent(last_workout_start=WORKOUT_END + timedelta(minutes=5)),  # start after end
        workout_recent(last_workout_end=None),                                   # recent without a workout
        workout_recent(state="missing"),                                         # missing but data present
        {"state": "missing", "confidence": 0.0, "workout_minutes_today": 0,
         "workout_minutes_last_7d": 0},                                          # missing but totals zeroed
        {"state": "none_recent", "confidence": 1.0},                             # confirmed absence needs totals
        workout_recent(workout_minutes_today=200),                               # today > last 7 days
        workout_recent(type=""),
        workout_recent(source_name=None),                                        # last workout needs its source
    ],
)
def test_workout_features_reject(block):
    with pytest.raises(ValidationError):
        WorkoutFeatures(**block)


def test_daily_features_reject_inconsistent_hours_since():
    with pytest.raises(ValidationError):
        features(workout=workout_recent(hours_since=5.0))


def test_daily_features_reject_observations_after_effective_at():
    with pytest.raises(ValidationError):
        features(effective_at=datetime(2026, 9, 22, 6, 30, tzinfo=CHI))


def test_daily_features_reject_sleep_ending_on_another_local_day():
    with pytest.raises(ValidationError):
        features(day=date(2026, 9, 21))


@pytest.mark.parametrize("config", ["", "abc", "Z" * 64])
def test_daily_features_reject_bad_config_hash(config):
    with pytest.raises(ValidationError):
        features(config_sha256=config)


def test_daily_features_reject_extra_field():
    with pytest.raises(ValidationError):
        DailyFeatures.model_validate({**features().model_dump(mode="json"), "eyes": "tired"})


# ---------------------------------------------------------------------------
# HealthState
# ---------------------------------------------------------------------------

DRIVERS = [
    {"id": "sleep_duration", "domain": "sleep", "value": 5.97, "baseline": 7.27, "difference": -1.30,
     "unit": "hours", "source": "Apple Watch", "observed_at": SLEEP_END, "confidence": 0.97},
    {"id": "hrv_sdnn", "domain": "hrv", "value": 54.2, "baseline": 58.0, "difference": -3.8,
     "unit": "ms", "source": "Apple Watch", "observed_at": datetime(2026, 9, 22, 6, 40, tzinfo=CHI),
     "confidence": 0.92},
    {"id": "resting_hr", "domain": "rhr", "value": 58, "baseline": 57, "difference": 1,
     "unit": "bpm", "source": "Apple Watch", "observed_at": datetime(2026, 9, 22, 7, 0, tzinfo=CHI),
     "confidence": 0.95},
    {"id": "steps_so_far", "domain": "movement", "value": 4821, "baseline": 6300, "difference": -1479,
     "unit": "steps", "source": "HealthKit statistics", "observed_at": NOW, "confidence": 0.91},
    {"id": "last_workout", "domain": "workout", "source": "Apple Watch", "observed_at": WORKOUT_END,
     "confidence": 1.0},
]


def calibration(sleep=19, hrv=19, rhr=19, movement=19, required_days=14) -> dict:
    """A summary whose status/usable_days follow the documented rule."""
    days = {"sleep": sleep, "hrv": hrv, "rhr": rhr, "movement": movement}
    participating = [d for d in days.values() if d > 0]
    usable = min(participating, default=0)
    ready = bool(participating) and usable >= required_days
    return {"required_days": required_days, "domains": days,
            "status": "ready" if ready else "calibrating", "usable_days": usable}


def health_state(**overrides) -> HealthState:
    return HealthState.model_validate({
        "engine_version": "state-engine@0.1.0", "feature_version": "features@0.2.0",
        "config_sha256": CONFIG, "effective_at": NOW,
        "calibration": calibration(),
        "sleep": {"state": "below_baseline", "severity": 0.62, "confidence": 0.97},
        "recovery": {"state": "typical", "confidence": 0.92},
        "movement": {"state": "typical", "confidence": 0.91},
        "workout": {"state": "recent_workout", "type": "strength", "confidence": 1.0},
        "drivers": DRIVERS,
        **overrides,
    })


def test_health_state_validates_and_round_trips():
    assert round_trips(TypeAdapter(HealthState), health_state())


def test_health_state_is_deeply_immutable():
    state = health_state()
    assert isinstance(state.drivers, tuple)
    with pytest.raises(AttributeError):
        state.drivers.append("not a driver")  # type: ignore[attr-defined]
    with pytest.raises(ValidationError):
        state.drivers[0].value = 1.0  # type: ignore[misc]


def test_health_state_with_no_participating_domains_is_calibrating():
    state = health_state(
        calibration=calibration(sleep=0, hrv=0, rhr=0, movement=0),
        sleep={"state": "calibrating", "confidence": 0.0},
        recovery={"state": "insufficient_data", "confidence": 0.0},
        movement={"state": "calibrating", "confidence": 0.0},
        workout={"state": "missing", "confidence": 0.0},
        drivers=[],
    )
    assert state.calibration.status == "calibrating"


@pytest.mark.parametrize(
    "overrides",
    [
        {"eyes": "tired"},                                                        # avatar field
        {"engine_version": ""},
        {"config_sha256": "abc"},
        {"calibration": {**calibration(), "usable_days": 0}},
        {"calibration": {**calibration(), "required_days": 0}},
        {"sleep": {"state": "calibrating", "confidence": 0.3}},                  # contradicts ready calibration
        {"sleep": {"state": "below_baseline", "confidence": 0.97}},              # severity missing
        {"sleep": {"state": "typical", "severity": 0.2, "confidence": 0.97}},    # severity on typical
        {"drivers": [d for d in DRIVERS if d["domain"] != "sleep"]},             # sleep claim, no sleep driver
        {"drivers": [d for d in DRIVERS if d["domain"] not in ("hrv", "rhr")]},  # recovery from 1 input
        {"drivers": [d for d in DRIVERS if d["domain"] != "workout"]},           # workout claim, no driver
        {"drivers": [d for d in DRIVERS if d["domain"] != "movement"]},          # movement claim, no driver
        {"drivers": DRIVERS + [DRIVERS[0]]},                                     # duplicate ids
        {"effective_at": datetime(2026, 9, 22, 12, 0, tzinfo=CHI)},             # driver after effective_at
    ],
)
def test_health_state_rejects(overrides):
    with pytest.raises(ValidationError):
        health_state(**overrides)


def test_recovery_insufficient_data_requires_zero_confidence():
    assert RecoveryState(state="insufficient_data", confidence=0).confidence == 0
    with pytest.raises(ValidationError):
        RecoveryState(state="insufficient_data", confidence=1)


def test_calibration_rejects_summaries_the_domains_dont_imply():
    assert Calibration(**calibration(sleep=0, hrv=0, rhr=0, movement=0)).status == "calibrating"
    for bad in (
        {**calibration(), "usable_days": 0},                            # min of domains is 19
        {**calibration(sleep=5), "status": "ready", "usable_days": 5},  # 5 < 14
        {**calibration(), "status": "calibrating"},                     # all domains ready
        {**calibration(sleep=0, hrv=0, rhr=0, movement=0), "status": "ready"},
        {**calibration(), "required_days": 0},
    ):
        with pytest.raises(ValidationError):
            Calibration(**bad)


@pytest.mark.parametrize(
    "overrides",
    [
        {"value": math.nan},
        {"value": math.inf},
        {"baseline": -math.inf},
        {"difference": math.nan},
        {"value": True},
        {"unit": None},              # measured value without unit
        {"source": None},
        {"observed_at": None},
        {"difference": -3.0},        # != value - baseline
        {"id": ""},
    ],
)
def test_driver_rejects(overrides):
    with pytest.raises(ValidationError):
        Driver(**{**DRIVERS[0], **overrides})


def test_driver_for_unavailable_data_may_omit_everything():
    driver = Driver(id="hrv_missing", domain="hrv", confidence=0.0)
    assert driver.value is None and driver.unit is None


def test_severity_bounds():
    with pytest.raises(ValidationError):
        SleepState(state="below_baseline", severity=1.5, confidence=0.9)


# ---------------------------------------------------------------------------
# WidgetState
# ---------------------------------------------------------------------------

def widget_state(**overrides) -> dict:
    return {
        "effective_at": NOW,
        "presentation": {"icon": "😴", "headline": "Shorter sleep", "detail": "5h 58m",
                         "secondary": "Strength workout completed recently"},
        "primary_trait": {"id": "sleep", "explainable": True},
        "freshness": {"last_updated_at": NOW},
        **overrides,
    }


def test_widget_state_validates_and_round_trips():
    assert round_trips(TypeAdapter(WidgetState), WidgetState.model_validate(widget_state()))


@pytest.mark.parametrize(
    "overrides",
    [
        {"robust_z": -0.82},
        {"presentation": {"icon": "😴", "headline": ""}},
        {"presentation": {"icon": " ", "headline": "Shorter sleep"}},
        {"primary_trait": {"id": "", "explainable": True}},
        {"freshness": {"last_updated_at": datetime(2026, 9, 22, 13, 20)}},
    ],
)
def test_widget_state_rejects(overrides):
    with pytest.raises(ValidationError):
        WidgetState.model_validate(widget_state(**overrides))


# ---------------------------------------------------------------------------
# Regressions from the second review
# ---------------------------------------------------------------------------

# 1. A domain with no history is calibrating without holding the summary back.

def test_zero_history_domain_is_calibrating_while_summary_is_ready():
    state = health_state(
        calibration=calibration(sleep=0),
        sleep={"state": "calibrating", "confidence": 0.0},
        drivers=[d for d in DRIVERS if d["domain"] != "sleep"],
    )
    assert state.calibration.status == "ready"
    assert state.sleep.state == "calibrating"


def test_partially_calibrated_domain_holds_the_summary_back():
    summary = Calibration(**calibration(sleep=5))
    assert (summary.status, summary.usable_days) == ("calibrating", 5)
    with pytest.raises(ValidationError):  # sleep is ready per the summary but claims calibrating
        health_state(sleep={"state": "calibrating", "confidence": 0.3})
    with pytest.raises(ValidationError):  # sleep has 5 < 14 days but claims a classification
        health_state(calibration=calibration(sleep=5))


# 2. Snapshot identity includes the total, so equal IDs mean identical reads.

def test_snapshot_reads_with_different_totals_never_share_an_id():
    same_query = {"as_of": NOW, "queried_at": NOW}
    low = DailyActivitySnapshot(**snapshot_event(**same_query, steps=4821))
    high = DailyActivitySnapshot(**snapshot_event(**same_query, steps=4900))
    assert low.bucket == high.bucket
    assert low.source_record_id != high.source_record_id
    for arrival in ([high, low], [low, high]):
        with pytest.raises(SnapshotConflictError):
            resolve_snapshot_bucket(arrival)


def test_identical_snapshot_reads_share_an_id():
    first = DailyActivitySnapshot(**snapshot_event())
    retry = DailyActivitySnapshot(**snapshot_event())
    assert first.source_record_id == retry.source_record_id
    assert first.event_id != retry.event_id  # a new read, not a retry of the same event


def test_snapshot_id_must_carry_the_total():
    data = snapshot_event(steps=4821)
    with pytest.raises(ValidationError):
        DailyActivitySnapshot(**{**data, "steps": 4900})  # id still says 4821


def test_snapshot_conflict_does_not_fall_back_to_an_older_read():
    reads = [
        DailyActivitySnapshot(**snapshot_event(as_of=NOW - timedelta(hours=1),
                                              queried_at=NOW - timedelta(hours=1), steps=4500)),
        DailyActivitySnapshot(**snapshot_event(as_of=NOW - timedelta(hours=1), steps=4900)),
        DailyActivitySnapshot(**snapshot_event(as_of=NOW - timedelta(hours=1), steps=4821)),
    ]
    for arrival in permutations(reads):
        with pytest.raises(SnapshotConflictError):
            resolve_snapshot_bucket(arrival)


@pytest.mark.parametrize("resolved_steps", [4700, 5000])
def test_newer_snapshot_resolves_an_older_conflict(resolved_steps):
    reads = [
        DailyActivitySnapshot(**snapshot_event(steps=4900)),
        DailyActivitySnapshot(**snapshot_event(steps=4821)),
        DailyActivitySnapshot(**snapshot_event(queried_at=NOW + timedelta(minutes=1), steps=resolved_steps)),
    ]
    for arrival in permutations(reads):
        assert resolve_snapshot_bucket(arrival).steps == resolved_steps


def test_snapshot_resolution_handles_empty_reads_and_identical_retries():
    assert resolve_snapshot_bucket([]) is None
    reads = [DailyActivitySnapshot(**snapshot_event()), DailyActivitySnapshot(**snapshot_event())]
    expected_id = min(read.event_id.int for read in reads)
    for arrival in permutations(reads):
        resolved = resolve_snapshot_bucket(iter(arrival))
        assert resolved.steps == 4821
        assert resolved.event_id.int == expected_id
    assert resolve_snapshot_bucket([reads[0], reads[0]]) == reads[0]


def test_snapshot_resolution_rejects_mixed_buckets():
    reads = [
        DailyActivitySnapshot(**snapshot_event()),
        DailyActivitySnapshot(**snapshot_event(as_of=NOW - timedelta(hours=1))),
    ]
    with pytest.raises(ValueError, match="exactly one bucket"):
        resolve_snapshot_bucket(reads)


@pytest.mark.parametrize("domain", ["sleep", "hrv", "rhr", "movement"])
@pytest.mark.parametrize("usable_days", [0, 13])
def test_driver_baseline_cannot_contradict_domain_calibration(domain, usable_days):
    overrides = {
        "calibration": calibration(**{domain: usable_days}),
        "recovery": {"state": "insufficient_data", "confidence": 0},
    }
    if domain in ("sleep", "movement"):
        overrides[domain] = {"state": "calibrating", "confidence": 0}
    with pytest.raises(ValidationError, match=f"{domain} driver baseline requires a ready domain"):
        health_state(**overrides)


@pytest.mark.parametrize("usable_days", [0, 13])
def test_uncalibrated_raw_measurements_do_not_count_toward_recovery(usable_days):
    drivers = [
        {**driver, "baseline": None, "difference": None}
        if driver["domain"] in ("hrv", "rhr") else driver
        for driver in DRIVERS
    ]
    overrides = {
        "calibration": calibration(hrv=usable_days, rhr=usable_days),
        "drivers": drivers,
    }
    # Raw measurements remain explainable during calibration.
    state = health_state(**overrides, recovery={"state": "insufficient_data", "confidence": 0})
    assert next(d for d in state.drivers if d.domain == "hrv").value == 54.2
    with pytest.raises(ValidationError, match="ready baselines from 2"):
        health_state(**overrides)


@pytest.mark.parametrize("ready_domains", list(combinations(("sleep", "hrv", "rhr"), 2)))
def test_two_calibrated_measured_domains_are_enough_for_recovery(ready_domains):
    missing_domain = ({"sleep", "hrv", "rhr"} - set(ready_domains)).pop()
    overrides = {
        "calibration": calibration(**{domain: 14 if domain in ready_domains else 0
                                      for domain in ("sleep", "hrv", "rhr")}),
        "drivers": [driver for driver in DRIVERS if driver["domain"] != missing_domain],
        "recovery": {"state": "typical", "confidence": 0.6},
    }
    if missing_domain == "sleep":
        overrides["sleep"] = {"state": "calibrating", "confidence": 0}
    assert health_state(**overrides).recovery.state == "typical"


# 3. Retained metadata must describe the event it's attached to.

SLEEP_A, SLEEP_B = NOW - timedelta(hours=7), NOW - timedelta(hours=6)


@pytest.mark.parametrize(
    "overrides",
    [
        {"healthkit_type": "HKWorkoutTypeIdentifier"},
        {"sample_start_at": SLEEP_A - timedelta(days=1), "sample_end_at": SLEEP_B - timedelta(days=1)},
        {"sample_end_at": SLEEP_B + timedelta(minutes=1)},
    ],
)
def test_interval_rejects_metadata_for_a_different_sample(overrides):
    meta = sample_meta(SLEEP_A, SLEEP_B, **{"healthkit_type": "HKCategoryTypeIdentifierSleepAnalysis", **overrides})
    with pytest.raises(ValidationError):
        IntervalEvent(**interval_event(SLEEP_A, SLEEP_B, metadata=meta))


def test_workout_rejects_sleep_metadata():
    start, end = NOW - timedelta(hours=1), NOW
    meta = sample_meta(start, end, healthkit_type="HKCategoryTypeIdentifierSleepAnalysis")
    with pytest.raises(ValidationError):
        WorkoutEvent(**workout_event(start, end, 50, metadata=meta))


def test_point_measurement_metadata_must_match_its_metric():
    with pytest.raises(ValidationError):  # RHR value, HRV metadata
        PointMeasurement(**rhr_point_event(metadata=point_event()["metadata"]))


def test_interval_metadata_equality_is_by_instant():
    # The same instants written in another zone still match.
    meta = sample_meta(utc(SLEEP_A), utc(SLEEP_B), healthkit_type="HKCategoryTypeIdentifierSleepAnalysis")
    assert IntervalEvent(**interval_event(SLEEP_A, SLEEP_B, metadata=meta))


# 4. Missing movement keeps its ready baseline.

def test_missing_movement_keeps_its_expected_steps():
    missing = MovementFeatures(**movement_ready(
        state="missing", steps=None, as_of=None, source_record_id=None, ratio=None,
    ))
    assert missing.expected_steps_now == 6300


def test_missing_movement_rejects_a_dropped_baseline():
    with pytest.raises(ValidationError):
        MovementFeatures(**movement_ready(
            state="missing", steps=None, as_of=None, source_record_id=None, ratio=None,
            expected_steps_now=None,
        ))


# 5. Durations: one tolerance, and real local day lengths.

@pytest.mark.parametrize(
    ("day", "minutes"),
    [(date(2026, 3, 8), 1380), (date(2026, 9, 22), 1440), (date(2026, 11, 1), 1500)],
)
def test_local_day_length_follows_dst(day, minutes):
    from app.contracts._types import local_day_minutes

    assert local_day_minutes(day, "America/Chicago") == minutes


def features_for_day(day: date, minutes_today: float) -> DailyFeatures:
    return DailyFeatures.model_validate({
        "config_sha256": CONFIG, "day": day, "timezone": "America/Chicago",
        "effective_at": datetime.combine(day, datetime.min.time(), CHI) + timedelta(hours=26),
        "sleep": calibrating(), "hrv": calibrating(), "rhr": calibrating(), "movement": calibrating(),
        "workout": {"state": "none_recent", "confidence": 1.0,
                    "workout_minutes_today": minutes_today, "workout_minutes_last_7d": minutes_today},
    })


def test_workout_minutes_today_may_use_the_extra_fall_back_hour():
    assert features_for_day(date(2026, 11, 1), 1470).workout.workout_minutes_today == 1470


@pytest.mark.parametrize(("day", "minutes"), [(date(2026, 3, 8), 1400), (date(2026, 9, 22), 1450)])
def test_workout_minutes_today_cannot_exceed_the_local_day(day, minutes):
    with pytest.raises(ValidationError):
        features_for_day(day, minutes)


def test_workout_duration_uses_the_documented_one_minute_tolerance():
    start, end = NOW - timedelta(minutes=30), NOW
    assert WorkoutEvent(**workout_event(start, end, 30.5))
    with pytest.raises(ValidationError):
        WorkoutEvent(**workout_event(start, end, 31.5))
