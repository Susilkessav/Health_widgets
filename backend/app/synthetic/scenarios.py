"""Independent, authored golden cases. Expected state is a specification, not engine output."""
from __future__ import annotations

from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from app.contracts._types import utc
from app.contracts.canonical_events import IntervalEvent, PointMeasurement
from app.synthetic.generator import Builder, checkpoint, local_at, stable_id
from app.synthetic.models import Assertion, Coverage, Dataset, Delivery, Expectations

DAY = date(2026, 9, 22)
ZONE = "America/Chicago"
SLEEP = (420, 435, 450, 450, 450, 465, 480)
HRV = (44, 47, 50, 50, 50, 53, 56)
RHR = (56, 58, 60, 60, 60, 62, 64)
STEPS = (4600, 4900, 5200, 5200, 5200, 5500, 5800)
# On-demand statistics reads land at irregular local times; only 12:30 and
# 13:00 fall in the 60-minute window before a 13:00 comparison.
IRREGULAR_READS = ((9, 0), (10, 30), (12, 30), (15, 0), (17, 45), (13, 0), (20, 10))

# Configuration assumptions for future calculators, not an implemented engine config.
RULES = {
    "baseline": {"calendar_days": 28, "minimum_valid_days": 14, "exclude_evaluation_day": True},
    "sleep_threshold_minutes": 60,
    "robust_z_thresholds": [-1, 1],
    # Step 3 proposal: the robust-z denominator is max(1.4826 * MAD, floor).
    "robust_scale_floor": {"hrv_sdnn_ms": 1, "resting_hr_bpm": 1},
    "movement_ratio_thresholds": [0.7, 1.3],
    "workout_hours": {"just_completed": 2, "recent": 12},
    "sleep_source_priority": ["org.homeostat.synthetic.watch", "org.homeostat.synthetic.phone",
                              "org.homeostat.synthetic.sleepapp"],
    "primary_sleep": "longest episode overlapping the local overnight window; naps separate",
    "recovery": "at least two calibrated measured inputs; coverage scales confidence",
    "execution": "raw/resolution assertions checked in Step 2; features/state deferred to Steps 3-4",
}

TWO_THIRDS = 2 / 3
# Step 4 state expectations beyond those authored with each case below.
STATE_EXPECTATIONS = {
    "calibration_3": (("calibration.status", "calibrating", "3 < 14 usable days in every domain."),
                      ("sleep.state", "calibrating", "No baseline claim before readiness.")),
    "calibration_14": (("calibration.status", "ready", "14 usable days reach readiness."),),
    "missing_hrv": (("recovery.confidence", TWO_THIRDS, "min(1, 1) x 2 usable inputs / 3."),),
    "multi_source_sleep": (("sleep.state", "typical", "The selected watch night is 450 minutes, the median."),),
    "awake_intervals": (("sleep.state", "typical", "410 minutes is 40 below the median, inside 60."),),
    "favorable_without_sleep": (
        ("recovery.state", "favorable", "HRV above and RHR below; missing sleep can't veto."),
        ("recovery.confidence", TWO_THIRDS, "Two usable inputs of three.")),
    "strained_two_inputs": (
        ("recovery.state", "strained", "Both usable inputs are adverse."),
        ("recovery.confidence", TWO_THIRDS, "Two usable inputs of three.")),
    "no_visible_data": (
        ("calibration.status", "calibrating", "No domain has any usable day."),
        ("calibration.usable_days", 0, "No participating domains."),
        ("recovery.state", "insufficient_data", "No usable recovery inputs.")),
}
# Step 4 widget expectations (Plan/archive/Step_4_plan.md section 6):
# (primary trait, headline, detail, secondary, explainable).
WIDGET_FIELDS = ("primary_trait.id", "presentation.headline", "presentation.detail",
                 "presentation.secondary", "primary_trait.explainable")
TYPICAL_ALL = ("typical", "Typical day", "Sleep, recovery and movement as usual", None, True)
WIDGETS = {
    "calibration_3": ("calibration", "Learning your baseline", "3 / 14 usable days", None, False),
    "typical": TYPICAL_ALL,
    "short_sleep": ("sleep", "Shorter sleep", "5h 30m", None, True),
    "low_hrv_only": TYPICAL_ALL,
    "high_hrv_only": TYPICAL_ALL,
    "adverse_signals": ("sleep", "Shorter sleep", "5h 30m", "Recovery signals below usual", True),
    "favorable_agreement": ("recovery", "Recovery signals above usual", "Based on sleep, HRV and resting HR", None, True),
    "missing_hrv": TYPICAL_ALL,
    "insufficient_recovery": ("typical", "Typical day", "Sleep and movement as usual", None, True),
    "workout_45m": ("workout", "Workout complete", "Strength training", None, True),
    "movement_behind": ("movement", "Less active than usual", "2,900 steps", None, True),
    "multi_source_sleep": TYPICAL_ALL,
    "awake_intervals": TYPICAL_ALL,
    "deleted_replaced": TYPICAL_ALL,
    "workout_6h": ("workout", "Recent workout", "Strength training", None, True),
    "workout_24h": TYPICAL_ALL,
    "calibration_0": ("calibration", "Learning your baseline", "0 / 14 usable days", None, False),
    "in_bed_only": ("typical", "Typical day", "Recovery and movement as usual", None, True),
    "favorable_without_sleep": ("recovery", "Recovery signals above usual", "Based on HRV and resting HR", None, True),
    "strained_two_inputs": ("recovery", "Recovery signals below usual", "Based on HRV and resting HR", None, True),
    "no_visible_data": ("no_data", "Waiting for new data", "Open Homeostat to sync Health data", None, False),
}

# (identifier, G1 golden number, prior calendar days)
CASES = (
    ("calibration_3", 1, 3), ("typical", 2, 28), ("short_sleep", 3, 28),
    ("low_hrv_only", 4, 28), ("high_hrv_only", 5, 28), ("adverse_signals", 6, 28),
    ("favorable_agreement", 7, 28), ("missing_hrv", 8, 28), ("insufficient_recovery", 9, 28),
    ("workout_45m", 10, 28), ("movement_behind", 11, 28), ("multi_source_sleep", 12, 28),
    ("awake_intervals", 13, 28), ("deleted_replaced", 14, 28),
    ("calibration_0", None, 0), ("calibration_13", None, 13), ("calibration_14", None, 14),
    ("absent_hrv_history", None, 28), ("partial_hrv_history", None, 28),
    ("zero_mad", None, 28), ("near_zero_mad", None, 28), ("history_outlier", None, 28),
    ("missing_history_day", None, 28),
    ("same_source_overlap", None, 28), ("in_bed_only", None, 28), ("separate_nap", None, 28),
    ("workout_6h", None, 28), ("workout_24h", None, 28), ("workout_unavailable", None, 28),
    ("steps_irregular_history", None, 28),
    ("favorable_without_sleep", None, 28), ("strained_two_inputs", None, 28), ("no_visible_data", None, 0),
    ("steps_upward", None, 0), ("steps_downward", None, 0),
    ("steps_conflict", None, 0), ("steps_conflict_resolved", None, 0),
    ("delivery_retries", None, 0), ("delayed_arrival", None, 0),
    ("out_of_order", None, 0), ("deletion_before_sample", None, 0),
    ("dst_spring", None, 0), ("dst_fall", None, 0), ("travel", None, 0),
)


def build_scenario(name: str, golden: int | None, history: int) -> Dataset:
    day = {"dst_spring": date(2026, 3, 8), "dst_fall": date(2026, 11, 1)}.get(name, DAY)
    b = Builder(name, ZONE)
    at = utc(local_at(day, 13, ZONE))
    points = [checkpoint(at)]
    assertions: list[Assertion] = []
    coverage = Coverage(workout="unavailable") if name == "workout_unavailable" else Coverage()

    def expect(layer: str, field: str, value, note: str, refs=(), point="evaluation"):
        assertions.append(Assertion(layer=layer, field=field, expected=value, note=note,
                                    event_ids=tuple(event.event_id for event in refs), checkpoint=point))

    for index in range(history):
        prior = day - timedelta(days=history - index)
        if name == "missing_history_day" and index == 10:
            continue
        pos = 3 if name == "zero_mad" else index % 7
        hrv = HRV[pos]
        if name == "absent_hrv_history" or (name == "partial_hrv_history" and index < 25):
            hrv = None
        if name == "history_outlier" and index == 0:
            hrv = 500
        if name == "near_zero_mad":
            # 12 x 50, 8 x 50.25, 8 x 49.75: median 50, MAD 0.25 (exact in binary).
            hrv = (50, 50, 50, 50.25, 50.25, 49.75, 49.75)[index % 7]
        irregular = name == "steps_irregular_history"
        b.daily(prior, SLEEP[pos], hrv, RHR[pos], None if irregular else STEPS[pos])
        if irregular:
            hour, minute = IRREGULAR_READS[index % 7]
            b.snapshot(prior, local_at(prior, hour, ZONE, minute), 5200)

    raw_only = (name.startswith("steps_") and name != "steps_irregular_history") or name in {
        "delivery_retries", "delayed_arrival", "out_of_order", "deletion_before_sample",
        "dst_spring", "dst_fall", "travel", "no_visible_data",
    }
    current = []
    if not raw_only:
        sleep = 330 if name in ("short_sleep", "adverse_signals") else 450
        hrv = 20 if name in ("low_hrv_only", "adverse_signals", "deleted_replaced") else 50
        if name in ("high_hrv_only", "favorable_agreement", "favorable_without_sleep"):
            hrv = 80
        if name == "strained_two_inputs":
            hrv = 20
        if name in ("missing_hrv", "insufficient_recovery", "absent_hrv_history"):
            hrv = None
        if name in ("zero_mad", "near_zero_mad"):
            hrv = 53  # differs from the median, so the scale floor decides z
        rhr = 75 if name in ("adverse_signals", "strained_two_inputs") \
            else 50 if name in ("favorable_agreement", "favorable_without_sleep") else 60
        if name == "insufficient_recovery":
            rhr = None
        if name == "awake_intervals":
            sleep = 410
        if name in ("in_bed_only", "favorable_without_sleep", "strained_two_inputs"):
            sleep = None
        current = b.daily(day, sleep, hrv, rhr, 2900 if name == "movement_behind" else 5200,
                          awake=40 if name == "awake_intervals" else 20)
        expect("raw", "history.calendar_days", history,
               "Prior local days, excluding the current evaluation day.")
        ready_days = 27 if name == "missing_history_day" else history
        expect("features", "sleep.usable_days", ready_days, "Valid nights inside the preceding 28-calendar-day window.")

    if name.startswith("calibration_"):
        state = "calibrating" if history < 14 else "ready"
        expect("features", "sleep.baseline_status", state, "Readiness boundary is 14 prior usable days.")
    elif name == "typical":
        for domain in ("sleep", "recovery", "movement"):
            expect("state", domain + ".state", "typical", "Current values equal the authored historical medians.")
    elif name in ("short_sleep", "low_hrv_only", "high_hrv_only"):
        expect("state", "recovery.state", "typical", "An isolated adverse or favorable signal cannot change recovery.")
        if name == "short_sleep":
            expect("state", "sleep.state", "below_baseline", "330 minutes versus median 450, a 120-minute deficit.")
    elif name in ("adverse_signals", "favorable_agreement"):
        expect("state", "recovery.state", "strained" if name == "adverse_signals" else "favorable",
               "Three adverse indicators, or high HRV and low RHR with typical sleep, respectively.")
    elif name == "missing_hrv":
        expect("features", "hrv.state", "missing", "Ready history but no current HRV measurement.")
        expect("state", "recovery.state", "typical", "Sleep and RHR remain typical and calibrated.")
        expect("features", "recovery_usable_inputs", 2, "Future confidence coverage is 2/3, not a fabricated fixed score.")
    elif name == "insufficient_recovery":
        expect("state", "recovery.state", "insufficient_data", "Only current sleep is available.")
        expect("state", "recovery.confidence", 0, "Fewer than two usable current recovery inputs.")
    elif name in ("workout_45m", "workout_6h", "workout_24h"):
        age = {"workout_45m": 45, "workout_6h": 360, "workout_24h": 1440}[name]
        event = b.workout(at - timedelta(minutes=age))
        expected = {45: "just_completed", 360: "recent_workout", 1440: "none_recent"}[age]
        expect("raw", "workout.age_minutes", age, "Elapsed UTC minutes at evaluation.", [event])
        expect("state", "workout.state", expected, "Configured recency windows are 2 and 12 hours.", [event])
    elif name == "steps_irregular_history":
        expect("features", "movement.usable_days", 8,
               "Only reads at 12:30 and 13:00 (2 of every 7 days) are comparable with 13:00.")
        expect("features", "movement.baseline_status", "calibrating",
               "Sparse on-demand history can't reach 14 days; the adapter must backfill hourly buckets.")
    elif name == "workout_unavailable":
        expect("features", "workout.state", "missing", "Coverage explicitly unavailable; do not infer none_recent.")
    elif name == "movement_behind":
        expect("features", "movement.expected_steps_now", 5200, "Median of the 28 authored 13:00 snapshots.")
        expect("state", "movement.state", "behind_usual", "2900/5200 is below 0.70.")
    elif name == "multi_source_sleep":
        b.sleep(day, 480, source="phone")
        b.sleep(day, 390, source="third_party")
        expect("resolution", "sleep.selected_source", "org.homeostat.synthetic.watch",
               "Explicit source priority selects the watch, not all overlapping intervals.")
        expect("features", "sleep.hours", 7.5, "Selected watch records contain 450 asleep minutes.")
    elif name == "awake_intervals":
        expect("raw", "sleep.asleep_minutes", 410, "Sum of nonoverlapping asleep stages, excluding awake and in-bed.", current)
        expect("raw", "sleep.in_bed_minutes", 480, "In-bed duration is not sleep duration.", current)
        expect("raw", "sleep.awake_minutes", 40, "Awake intervals are preserved.", current)
        expect("features", "sleep.hours", 410 / 60, "The remaining 30 in-bed minutes are unclassified, not assumed asleep.")
    elif name == "deleted_replaced":
        original = next(e for e in current if isinstance(e, PointMeasurement) and e.metric == "hrv_sdnn_ms")
        deletion = b.delete(original, at - timedelta(hours=1))
        replacement = b.point(day, "hrv_sdnn_ms", 50, "replacement", at - timedelta(minutes=59))
        expect("resolution", "deleted_source_record_id", original.source_record_id, "Tombstone must exclude A.", [original, deletion])
        expect("resolution", "replacement_source_record_id", replacement.source_record_id, "B has a different sample UUID.", [replacement])
        # A (20 ms) alone would still leave recovery typical, so assert B directly.
        expect("features", "hrv.value", 50, "Only replacement B (50 ms) remains; deleted A was 20 ms.", [original, deletion, replacement])
        expect("features", "hrv.source_record_id", replacement.source_record_id, "The HRV feature cites B.", [replacement])
        expect("features", "hrv.state", "typical", "B is at the median; A would have been below_usual.", [replacement])
        expect("state", "recovery.state", "typical", "Only the replacement's typical HRV remains.")
    elif name in ("absent_hrv_history", "partial_hrv_history"):
        expect("features", "hrv.usable_days", 0 if name == "absent_hrv_history" else 3,
               "Absent and partially calibrated domains have independent history counts.")
        expect("features", "hrv.baseline_status", "calibrating", "No HRV comparison before readiness.")
        expect("state", "calibration.status", "ready" if name == "absent_hrv_history" else "calibrating",
               "Zero-history domains are excluded; participating partial histories delay the summary.")
    elif name in ("zero_mad", "near_zero_mad", "history_outlier"):
        expect("features", "hrv.baseline", 50, "Authored history median is 50 ms, including with one outlier.")
        mad = {"zero_mad": 0, "near_zero_mad": 0.25, "history_outlier": 3}[name]
        expect("features", "hrv.mad", mad, "Raw MAD is stored; the scale floor applies only to the denominator.")
        if name != "history_outlier":
            expect("features", "hrv.value", 53, "The current value differs from the median.")
            expect("features", "hrv.robust_z", 3.0,
                   "(53 - 50) / max(1.4826 * MAD, 1 ms floor) = 3; without the floor z would be infinite or ~8.1.")
            expect("features", "hrv.state", "above_usual", "z = 3 exceeds the +1 threshold.")
    elif name == "same_source_overlap":
        original = next(e for e in current if isinstance(e, IntervalEvent) and e.value == "asleep_core")
        overlap = b.interval("overlap", original.start_at + timedelta(minutes=10),
                             original.start_at + timedelta(minutes=30), "asleep_unspecified")
        expect("features", "sleep.hours", 7.5, "The extra 20-minute interval is already inside core sleep.", [original, overlap])
    elif name == "in_bed_only":
        event = b.interval("in_bed_only", at - timedelta(hours=14), at - timedelta(hours=6), "in_bed")
        expect("features", "sleep.state", "missing", "In-bed-only data does not establish actual sleep.", [event])
    elif name == "separate_nap":
        nap = b.interval("nap", at - timedelta(hours=2), at - timedelta(minutes=90), "asleep_unspecified")
        expect("features", "sleep.hours", 7.5, "The 30-minute daytime nap remains separate from primary sleep.", [nap])

    if name in ("steps_upward", "steps_downward", "steps_conflict", "steps_conflict_resolved"):
        first = b.snapshot(day, at, 4900)
        if name in ("steps_upward", "steps_downward"):
            total = 5200 if name == "steps_upward" else 4821
            correction = b.snapshot(day, at, total, at + timedelta(hours=1))
            points.append(checkpoint(at, "corrected", at + timedelta(hours=1)))
            expect("resolution", "steps", 4900, "Initial view before the correction arrives.", [first])
            expect("resolution", "steps", total, "Latest query wins even when the total decreases.", [first, correction], "corrected")
        else:
            other = b.snapshot(day, at, 4821)
            expect("resolution", "steps", "conflict", "Equal-time contradictory totals are unresolved.", [first, other])
            if name == "steps_conflict_resolved":
                resolved = b.snapshot(day, at, 4800, at + timedelta(hours=1))
                points.append(checkpoint(at, "resolved", at + timedelta(hours=1)))
                expect("resolution", "steps", 4800, "A newer unambiguous query resolves the conflict.", [first, other, resolved], "resolved")

    if name in ("delivery_retries", "delayed_arrival", "out_of_order", "deletion_before_sample"):
        late = at + timedelta(hours=2)
        original = b.point(day, "hrv_sdnn_ms", 50, delivered_at=late if name in ("delayed_arrival", "deletion_before_sample") else None)
        if name == "delivery_retries":
            for index in (1, 2):
                b.deliveries.append(Delivery(id=f"retry-{index}", delivered_at=at + timedelta(minutes=index),
                                            event_ids=(original.event_id,), note="Retry: same immutable event ID"))
            reimport = PointMeasurement.model_validate({**original.model_dump(), "event_id": stable_id(name, "reimport")})
            b.add(reimport, at + timedelta(minutes=3))
            points.append(checkpoint(at, "after_delivery", at + timedelta(minutes=3)))
            expect("raw", "delivery_attempts", 4, "One initial delivery, two retries and one equivalent reimport.", point="after_delivery")
            expect("resolution", "logical_provider_records", 1, "Client IDs differ on reimport; provider content is equivalent.", [original, reimport], "after_delivery")
        elif name == "delayed_arrival":
            points.append(checkpoint(at, "after_delivery", late))
            expect("raw", "visible_events", 0, "A recorded morning event has not arrived by the initial checkpoint.")
            expect("raw", "visible_events", 1, "Correction-time knowledge reveals the late event.", [original], "after_delivery")
        elif name == "out_of_order":
            b.deliveries[0] = b.deliveries[0].model_copy(update={"delivered_at": at - timedelta(hours=4)})
            later = b.point(day, "resting_hr_bpm", 60, delivered_at=at - timedelta(hours=5))
            expect("raw", "first_delivered_event", str(later.event_id), "Later measurement arrives before the earlier measurement.", [original, later])
        else:
            deletion = b.delete(original, at - timedelta(hours=1))
            replacement = b.point(day, "hrv_sdnn_ms", 54, "replacement", at - timedelta(minutes=59))
            points.append(checkpoint(at, "after_delivery", late))
            expect("resolution", "deleted_source_record_id", original.source_record_id, "Delete is delivered before its original sample; do not resurrect it.", [original, deletion], "after_delivery")
            expect("resolution", "replacement_source_record_id", replacement.source_record_id, "Retain the replacement.", [replacement], "after_delivery")
            expect("features", "hrv.value", 54, "Only replacement B (54 ms) remains; late-arriving A (50 ms) stays deleted.",
                   [original, deletion, replacement], "after_delivery")

    if name in ("dst_spring", "dst_fall"):
        start, end = local_at(day - timedelta(days=1), 23, ZONE), local_at(day, 7, ZONE)
        event = b.interval("dst_overnight", start, end, "asleep_unspecified")
        b.steps(day, 5200)
        expect("raw", "sleep.elapsed_minutes", 420 if name == "dst_spring" else 540,
               "23:00 to 07:00 crosses a DST transition; use UTC elapsed time.", [event])
        expect("raw", "local_day_minutes", 1380 if name == "dst_spring" else 1500,
               "Closing-midnight snapshots use the actual local calendar day.")
        if name == "dst_fall":
            fold_start = datetime(2026, 11, 1, 1, 50, tzinfo=ZoneInfo(ZONE), fold=0)
            fold_end = datetime(2026, 11, 1, 1, 10, tzinfo=ZoneInfo(ZONE), fold=1)
            folded = b.interval("dst_fold", fold_start, fold_end, "asleep_core")
            expect("raw", "fold.elapsed_minutes", 20, "Wall-clock order is reversed while UTC order is valid.", [folded])
    elif name == "travel":
        b.sleep(day)
        b.snapshot(day, local_at(day, 8, ZONE), 1200)
        zone = "America/Los_Angeles"
        selected = b.snapshot(day, local_at(day, 13, zone), 5200, zone=zone)
        points = [checkpoint(local_at(day, 13, zone))]
        expect("resolution", "movement.timezone", zone,
               "Explicit policy selects the zone of the latest eligible snapshot; never sums zones.", [selected])
        expect("features", "sleep.hours", 7.5, "Sleep keeps its original Chicago timezone after travel.")

    for field, value, note in STATE_EXPECTATIONS.get(name, ()):
        expect("state", field, value, note)
    for field, value in zip(WIDGET_FIELDS, WIDGETS.get(name, ())):
        expect("widget", field, value, "Authored Step 4 presentation (Plan/Step_4_plan.md section 6).")

    return b.finish(day - timedelta(days=history), day, points,
                    "Independent authored fixture; raw/resolution checks run now, feature/state assertions await Steps 3-4.",
                    golden=golden, labels=(name,), coverage=coverage,
                    expectations=Expectations(assumptions=RULES, assertions=tuple(assertions)))


def generate_scenarios() -> tuple[Dataset, ...]:
    """Fixed dates, zones and measurements intentionally independent of the demo seed."""
    return tuple(build_scenario(*case) for case in CASES)
