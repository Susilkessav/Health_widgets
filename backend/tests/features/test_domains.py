"""Domain rules from the Step 3 plan, one behavior per test."""
from datetime import date, timedelta

import pytest

from app.config import Freshness
from app.features.calculate import freshness
from app.features.points import robust_z
from app.synthetic.generator import Builder

from .conftest import DAY, ZONE, at, calc, history, point, workout

LA = "America/Los_Angeles"


# ---------------------------------------------------------------- sleep

def test_awake_time_overlapping_asleep_is_not_sleep():
    b = Builder("t", ZONE)
    b.interval("core", at(0, day=DAY), at(6, day=DAY), "asleep_core")
    b.interval("awake", at(2, day=DAY), at(3, day=DAY), "awake")
    report = calc(b)
    assert report.features.sleep.hours == 5
    assert report.features.sleep.awake_minutes == 60
    assert "sleep_awake_overlap_minutes:60" in report.diagnostics


def test_in_bed_neither_creates_sleep_nor_bridges_episodes():
    b = Builder("t", ZONE)
    b.interval("bed", at(22, day=DAY - timedelta(days=1)), at(11), "in_bed")
    assert calc(b).features.sleep.hours is None
    b.interval("first", at(23, day=DAY - timedelta(days=1)), at(1), "asleep_core")
    b.interval("second", at(4), at(9), "asleep_core")  # 3 h gap > 90 min
    sleep = calc(b).features.sleep
    assert sleep.hours == 5 and sleep.in_bed_hours == 13  # in-bed goes to the larger overlap only


def test_primary_sleep_is_the_longest_overnight_episode_and_naps_stay_separate():
    b = Builder("t", ZONE)
    b.sleep(DAY, 450)
    b.interval("nap", at(11), at(11, 30), "asleep_unspecified")
    report = calc(b)
    assert report.features.sleep.hours == 7.5
    assert [nap["asleep_minutes"] for nap in report.evidence["sleep"]["naps"]] == [30]


def test_source_priority_beats_duration():
    b = Builder("t", ZONE)
    b.sleep(DAY, 400)
    b.sleep(DAY, 480, source="phone")
    report = calc(b)
    assert report.features.sleep.hours == 400 / 60 and report.features.sleep.source == "synthetic_watch"


def test_stages_before_midnight_belong_to_the_wake_day():
    b = Builder("t", ZONE)
    b.interval("early", at(21, day=DAY - timedelta(days=1)), at(23, 59, day=DAY - timedelta(days=1)), "asleep_core")
    b.interval("late", at(23, 59, day=DAY - timedelta(days=1)), at(5), "asleep_deep")
    assert calc(b).features.sleep.hours == 8


@pytest.mark.parametrize(("day", "hours"), [(date(2026, 3, 8), 7), (date(2026, 11, 1), 9)])
def test_sleep_across_dst_uses_elapsed_time(day, hours):
    b = Builder("t", ZONE)
    b.interval("night", at(23, day=day - timedelta(days=1)), at(7, day=day), "asleep_core")
    assert calc(b, day=day).features.sleep.hours == hours


def test_sleep_in_another_zone_is_a_diagnostic_not_an_error():
    b = Builder("t", ZONE)
    b.sleep(DAY, 450, zone=LA)
    report = calc(b, effective=at(13, zone=LA))
    assert report.features.sleep.hours == 7.5 and report.features.sleep.timezone == LA
    assert f"sleep_timezone:{LA}" in report.diagnostics


def test_sleep_boundary_is_60_minutes_either_way():
    b = Builder("t", ZONE)
    history(b, sleep=450)
    b.sleep(DAY, 390)
    assert calc(b).features.sleep.state == "below_baseline"
    b2 = Builder("t", ZONE)
    history(b2, sleep=450)
    b2.sleep(DAY, 391)
    assert calc(b2).features.sleep.state == "typical"


# ---------------------------------------------------------------- HRV / RHR

def test_daily_reading_is_fixed_for_the_day():
    b = Builder("t", ZONE)
    b.sleep(DAY, 450)                                # 23:10-07:00
    point(b, "inside", "hrv_sdnn_ms", 44, at(3))
    point(b, "inside2", "hrv_sdnn_ms", 48, at(5))    # latest inside sleep wins
    point(b, "after", "hrv_sdnn_ms", 60, at(9))
    point(b, "evening", "hrv_sdnn_ms", 70, at(17))
    assert calc(b, effective=at(8)).features.hrv.value == 48
    assert calc(b, effective=at(19)).features.hrv.value == 48


def test_first_reading_after_waking_then_first_of_day():
    b = Builder("t", ZONE)
    b.sleep(DAY, 450)
    point(b, "after", "hrv_sdnn_ms", 60, at(9))
    point(b, "later", "hrv_sdnn_ms", 70, at(11))
    assert calc(b).features.hrv.value == 60
    no_sleep = Builder("t", ZONE)
    point(no_sleep, "a", "hrv_sdnn_ms", 55, at(1))
    point(no_sleep, "b", "hrv_sdnn_ms", 65, at(9))
    assert calc(no_sleep).features.hrv.value == 55


def test_yesterday_is_never_carried_into_today():
    b = Builder("t", ZONE)
    history(b)
    b.daily(DAY, hrv=None)
    hrv = calc(b).features.hrv
    assert hrv.state == "missing" and hrv.value is None and hrv.baseline == 50


def test_a_point_counts_only_after_its_sample_ends():
    b = Builder("t", ZONE)
    point(b, "a", "resting_hr_bpm", 60, at(13, 30))
    assert calc(b).features.rhr.value is None
    assert calc(b, effective=at(14)).features.rhr.value == 60


def test_robust_z_uses_the_floor_and_threshold_endpoints_are_typical():
    assert robust_z(53, 50, 0, 1.0) == 3
    assert robust_z(53, 50, 3, 1.0) == pytest.approx(3 / 4.4478)
    b = Builder("t", ZONE)
    history(b, hrv=50)             # MAD 0, so the 1 ms floor sets the scale
    b.daily(DAY, hrv=51)
    assert calc(b).features.hrv.robust_z == 1 and calc(b).features.hrv.state == "typical"


# ---------------------------------------------------------------- movement

def test_history_in_another_zone_is_compared_by_local_wall_time():
    b = Builder("t", ZONE)
    history(b, steps=5200)          # Chicago 13:00 history
    b.snapshot(DAY, at(13, zone=LA), 2600, zone=LA)
    movement = calc(b, effective=at(13, zone=LA), zone=LA).features.movement
    assert movement.baseline_status == "ready" and movement.expected_steps_now == 5200
    assert movement.state == "behind_usual"


def test_only_reads_within_the_window_before_the_target_are_comparable():
    b = Builder("t", ZONE)
    for index in range(28):
        prior = DAY - timedelta(days=28 - index)
        b.snapshot(prior, at(11, 50, day=prior), 5000)   # 70 minutes early
    b.snapshot(DAY, at(13), 5000)
    assert calc(b).features.movement.usable_days == 0


def test_a_delayed_read_is_compared_at_its_own_time():
    b = Builder("t", ZONE)
    history(b, steps=5200)
    b.snapshot(DAY, at(13), 5200, queried_at=at(14))
    movement = calc(b, effective=at(14)).features.movement
    assert movement.expected_steps_now == 5200 and movement.state == "typical"


def test_zero_expectation_is_typical_without_a_ratio():
    b = Builder("t", ZONE)
    for index in range(28):
        prior = DAY - timedelta(days=28 - index)
        b.snapshot(prior, at(0, 30, day=prior), 0)
    b.snapshot(DAY, at(0, 30), 12)
    movement = calc(b, effective=at(0, 30)).features.movement
    assert movement.expected_steps_now == 0 and movement.ratio is None and movement.state == "typical"


def test_a_conflicted_current_bucket_does_not_fall_back_to_an_older_one():
    b = Builder("t", ZONE)
    history(b, steps=5200)
    b.snapshot(DAY, at(8), 2000)
    b.snapshot(DAY, at(13), 5000)
    b.snapshot(DAY, at(13), 5100)
    report = calc(b)
    assert report.features.movement.steps is None and report.features.movement.state == "missing"
    assert report.features.movement.expected_steps_now == 5200
    assert f"movement_conflict:{DAY}" in report.diagnostics


# ---------------------------------------------------------------- workouts

@pytest.mark.parametrize(("hours_ago", "state"), [(2, "just_completed"), (2.01, "recent_workout"),
                                                   (12, "recent_workout"), (12.01, "none_recent")])
def test_recency_boundaries_are_inclusive(hours_ago, state):
    b = Builder("t", ZONE)
    end = at(13) - timedelta(hours=hours_ago)
    workout(b, "w", end - timedelta(minutes=30), end, 30)
    assert calc(b).features.workout.state == state


def test_overlapping_sources_are_not_double_counted():
    b = Builder("t", ZONE)
    workout(b, "watch", at(9), at(10), 60)
    workout(b, "app", at(9, 30), at(10, 30), 60, source="third_party")
    report = calc(b)
    assert report.features.workout.workout_minutes_today == 90  # not 120
    assert report.features.workout.last_workout_end == at(10, 30)  # the app still wins 10:00-10:30
    assert report.evidence["workout"]["excluded_overlaps"] == []


def test_a_duplicate_inside_a_higher_priority_workout_is_excluded():
    b = Builder("t", ZONE)
    watch = workout(b, "watch", at(9), at(10), 60)
    duplicate = workout(b, "app", at(9, 10), at(9, 50), 40, source="third_party")
    report = calc(b)
    assert report.features.workout.workout_minutes_today == 60
    assert report.features.workout.source_record_id == watch.source_record_id
    assert report.evidence["workout"]["excluded_overlaps"] == [duplicate.source_record_id]


def test_cross_midnight_and_paused_workouts_are_allocated_proportionally():
    b = Builder("t", ZONE)
    workout(b, "late", at(23, 30, day=DAY - timedelta(days=1)), at(0, 30), 30)  # 30 active of 60 wall
    totals = calc(b).features.workout
    assert totals.workout_minutes_today == 15 and totals.workout_minutes_last_7d == 30


def test_unknown_coverage_is_missing_but_known_empty_is_none_recent():
    missing = calc(Builder("t", ZONE), unavailable=("workout",)).features.workout
    assert missing.state == "missing" and missing.workout_minutes_today is None
    empty = calc(Builder("t", ZONE)).features.workout
    assert empty.state == "none_recent" and empty.workout_minutes_today == 0


def test_totals_fit_a_25_hour_day():
    b, day = Builder("t", ZONE), date(2026, 11, 1)
    workout(b, "long", at(0, day=day), at(23, 59, day=day), 1439 + 60)  # 25 h of wall time
    assert calc(b, day=day, effective=at(23, 59, day=day)).features.workout.workout_minutes_today == 1499


# ---------------------------------------------------------------- confidence

def test_freshness_is_full_through_the_report_day_then_decays():
    rules = Freshness(full_hours=24, zero_hours=48)
    assert [freshness(age, rules) for age in (0, 12, 24, 36, 48, 60)] == [1, 1, 1, 0.5, 0, 0]


def test_evening_confidence_stays_full_for_once_daily_values():
    b = Builder("t", ZONE)
    history(b)
    b.daily(DAY)
    features = calc(b, effective=at(19)).features
    assert features.sleep.confidence == features.hrv.confidence == features.rhr.confidence == 1
    assert features.movement.confidence == 1  # 18:00 read, one hour old


def test_confidence_reflects_maturity_staleness_and_coverage():
    b = Builder("t", ZONE)
    history(b, days=7)
    b.daily(DAY)
    report = calc(b, effective=at(21))  # movement read at 18:00 is 3 h old
    assert report.features.sleep.confidence == pytest.approx(7 / 14)
    assert report.features.movement.confidence == 0
    assert calc(b, unavailable=("hrv",)).features.hrv.confidence == 0
