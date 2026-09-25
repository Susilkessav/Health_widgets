"""Verify fixture facts independently; these tests do not calculate HealthState."""
from datetime import timedelta
from itertools import permutations
from statistics import median
from zoneinfo import ZoneInfo

import pytest

from app.contracts._types import local_day_minutes, utc
from app.contracts.canonical_events import (
    DailyActivitySnapshot, DeleteEvent, IntervalEvent, PointMeasurement,
    SnapshotConflictError, WorkoutEvent, resolve_snapshot_bucket,
)
from app.synthetic.scenarios import CASES


def evaluation(dataset, checkpoint="evaluation"):
    return next(p for p in dataset.context.checkpoints if p.id == checkpoint)


def visible(dataset, checkpoint="evaluation"):
    point = evaluation(dataset, checkpoint)
    ids = {eid for batch in dataset.deliveries if utc(batch.delivered_at) <= utc(point.known_at) for eid in batch.event_ids}
    return [e for e in dataset.events if e.event_id in ids]


def current(dataset, kind):
    zone = ZoneInfo(dataset.context.timezone)
    if kind is IntervalEvent:
        # A current night's early stages can end before midnight on the prior day.
        cutoff = evaluation(dataset).effective_at.astimezone(zone).replace(hour=18, minute=0) - timedelta(days=1)
        return [e for e in visible(dataset) if isinstance(e, IntervalEvent) and e.end_at > cutoff]
    def day(e):
        if isinstance(e, DailyActivitySnapshot):
            return e.day
        moment = e.observed_at if isinstance(e, PointMeasurement) else e.end_at
        return moment.astimezone(zone).date()
    return [e for e in visible(dataset) if isinstance(e, kind) and day(e) == dataset.context.end_day]


def history_points(dataset, metric):
    zone = ZoneInfo(dataset.context.timezone)
    return [e.value for e in dataset.events if isinstance(e, PointMeasurement) and e.metric == metric
            and dataset.context.end_day - timedelta(days=28) <= e.observed_at.astimezone(zone).date()
            < dataset.context.end_day]


def minutes(intervals):
    return sum((utc(e.end_at) - utc(e.start_at)).total_seconds() / 60 for e in intervals)


def union_minutes(intervals):
    # Independent interval-union check for the authored sleep records, not a sleep resolver.
    endpoints = sorted((utc(e.start_at), utc(e.end_at)) for e in intervals)
    merged = []
    for start, end in endpoints:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
        else:
            merged.append((start, end))
    return sum((end - start).total_seconds() / 60 for start, end in merged)


def test_scenario_catalog(scenarios):
    assert len(scenarios) == 44
    assert sorted(d.context.golden_case for d in scenarios.values() if d.context.golden_case) == list(range(1, 15))
    assert all(d.expectations and d.expectations.assertions for d in scenarios.values())


@pytest.mark.parametrize("name", [name for name, _, _ in CASES])
def test_every_authored_raw_and_resolution_claim(scenarios, name):
    dataset = scenarios[name]
    events = {e.event_id: e for e in dataset.events}
    for claim in dataset.expectations.assertions:
        if claim.layer not in ("raw", "resolution"):
            continue  # Features and semantic state become executable in Steps 3-4.
        point = evaluation(dataset, claim.checkpoint)
        refs = [events[eid] for eid in claim.event_ids]
        field = claim.field
        if field == "history.calendar_days":
            actual = (dataset.context.end_day - dataset.context.start_day).days
        elif field == "workout.age_minutes":
            actual = (point.effective_at - refs[0].end_at).total_seconds() / 60
        elif field in ("sleep.asleep_minutes", "sleep.in_bed_minutes", "sleep.awake_minutes"):
            stage = {"sleep.asleep_minutes": "asleep_", "sleep.in_bed_minutes": "in_bed",
                     "sleep.awake_minutes": "awake"}[field]
            actual = minutes(e for e in refs if isinstance(e, IntervalEvent) and e.value.startswith(stage))
        elif field in ("sleep.elapsed_minutes", "fold.elapsed_minutes"):
            actual = minutes(refs)
        elif field == "local_day_minutes":
            actual = local_day_minutes(dataset.context.end_day, dataset.context.timezone)
        elif field == "sleep.selected_source":
            bundles = {e.metadata.source_bundle_id for e in current(dataset, IntervalEvent)}
            priority = dataset.expectations.assumptions["sleep_source_priority"]
            assert len(bundles) == 3
            actual = next(bundle for bundle in priority if bundle in bundles)
        elif field == "deleted_source_record_id":
            original = next(e for e in refs if isinstance(e, PointMeasurement))
            deletion = next(e for e in refs if isinstance(e, DeleteEvent))
            assert original.source_record_id == deletion.source_record_id
            assert deletion in visible(dataset, claim.checkpoint)
            actual = deletion.source_record_id
        elif field == "replacement_source_record_id":
            assert len(refs) == 1 and refs[0] in visible(dataset, claim.checkpoint)
            assert refs[0].source_record_id not in {e.source_record_id for e in dataset.events if isinstance(e, DeleteEvent)}
            actual = refs[0].source_record_id
        elif field == "steps":
            eligible = [e for e in visible(dataset, claim.checkpoint) if isinstance(e, DailyActivitySnapshot)
                        and e.as_of <= point.effective_at]
            assert set(e.event_id for e in eligible) == set(claim.event_ids)
            for ordered in permutations(eligible):
                if claim.expected == "conflict":
                    with pytest.raises(SnapshotConflictError):
                        resolve_snapshot_bucket(ordered)
                else:
                    assert resolve_snapshot_bucket(ordered).steps == claim.expected
            continue
        elif field == "delivery_attempts":
            actual = sum(len(d.event_ids) for d in dataset.deliveries if d.delivered_at <= point.known_at)
        elif field == "logical_provider_records":
            actual = len({(e.source, e.source_record_id, e.event_type) for e in visible(dataset, claim.checkpoint)})
            assert refs[0].event_id != refs[1].event_id
            assert refs[0].model_dump(exclude={"event_id"}) == refs[1].model_dump(exclude={"event_id"})
        elif field == "visible_events":
            actual = len(visible(dataset, claim.checkpoint))
        elif field == "first_delivered_event":
            actual = str(dataset.deliveries[0].event_ids[0])
            assert events[dataset.deliveries[0].event_ids[0]].observed_at > events[dataset.deliveries[1].event_ids[0]].observed_at
        elif field == "movement.timezone":
            snapshots = [e for e in visible(dataset, claim.checkpoint) if isinstance(e, DailyActivitySnapshot)
                         and e.as_of <= point.effective_at]
            assert len({e.timezone for e in snapshots}) == 2
            actual = max(snapshots, key=lambda e: e.as_of).timezone
        else:
            pytest.fail(f"Unverified fixture claim: {name}/{field}")
        assert actual == claim.expected, (name, field)


@pytest.mark.parametrize("name,count", [
    ("calibration_0", 0), ("calibration_3", 3), ("calibration_13", 13), ("calibration_14", 14),
    ("typical", 28), ("missing_history_day", 27),
])
def test_usable_history_boundaries(scenarios, name, count):
    data = scenarios[name]
    assert len(history_points(data, "hrv_sdnn_ms")) == count
    assert len(history_points(data, "resting_hr_bpm")) == count
    zone = ZoneInfo(data.context.timezone)
    nights = {e.end_at.astimezone(zone).date() for e in data.events
              if isinstance(e, IntervalEvent) and e.value == "asleep_rem"
              and e.end_at.astimezone(zone).date() < data.context.end_day}
    assert len(nights) == count
    snapshot_days = {e.day for e in data.events if isinstance(e, DailyActivitySnapshot)
                     and e.day < data.context.end_day}
    assert len(snapshot_days) == count


@pytest.mark.parametrize("name,count", [("absent_hrv_history", 0), ("partial_hrv_history", 3), ("missing_hrv", 28)])
def test_per_domain_missing_history_and_current_values(scenarios, name, count):
    data = scenarios[name]
    assert len(history_points(data, "hrv_sdnn_ms")) == count
    assert len(history_points(data, "resting_hr_bpm")) == 28
    points = current(data, PointMeasurement)
    assert sum(e.metric == "hrv_sdnn_ms" for e in points) == (1 if name == "partial_hrv_history" else 0)
    assert any(e.metric == "resting_hr_bpm" for e in points)
    assert not current(scenarios["insufficient_recovery"], PointMeasurement)


@pytest.mark.parametrize("name,mad", [("typical", 3), ("zero_mad", 0), ("near_zero_mad", 0.25), ("history_outlier", 3)])
def test_authored_median_mad_and_outlier(scenarios, name, mad):
    values = history_points(scenarios[name], "hrv_sdnn_ms")
    assert len(values) == 28
    assert median(values) == 50
    assert median(abs(value - 50) for value in values) == mad
    if name == "history_outlier":
        assert values.count(500) == 1


@pytest.mark.parametrize("name,sleep,hrv,rhr,steps", [
    ("typical", 450, 50, 60, 5200), ("short_sleep", 330, 50, 60, 5200),
    ("low_hrv_only", 450, 20, 60, 5200), ("high_hrv_only", 450, 80, 60, 5200),
    ("adverse_signals", 330, 20, 75, 5200), ("favorable_agreement", 450, 80, 50, 5200),
    ("movement_behind", 450, 50, 60, 2900),
])
def test_golden_measurements_and_independent_history(scenarios, name, sleep, hrv, rhr, steps):
    data = scenarios[name]
    asleep = [e for e in current(data, IntervalEvent) if e.value.startswith("asleep_")]
    assert minutes(asleep) == sleep
    assert {e.metric: e.value for e in current(data, PointMeasurement)} == {"hrv_sdnn_ms": hrv, "resting_hr_bpm": rhr}
    assert max(current(data, DailyActivitySnapshot), key=lambda e: e.as_of).steps == steps
    assert median(history_points(data, "hrv_sdnn_ms")) == 50
    assert median(history_points(data, "resting_hr_bpm")) == 60
    history_steps = [e.steps for e in data.events if isinstance(e, DailyActivitySnapshot)
                     and e.day < data.context.end_day and e.as_of.astimezone(ZoneInfo(e.timezone)).hour == 13]
    assert len(history_steps) == 28 and median(history_steps) == 5200
    historical_sleep = {}
    for e in data.events:
        if isinstance(e, IntervalEvent) and e.value.startswith("asleep_"):
            day = e.end_at.astimezone(ZoneInfo(e.metadata.timezone)).date()
            if day < data.context.end_day:
                historical_sleep[day] = historical_sleep.get(day, 0) + minutes([e])
    assert len(historical_sleep) == 28 and median(historical_sleep.values()) == 450


def test_sleep_overlap_sources_in_bed_and_nap(scenarios):
    overlaps = [e for e in current(scenarios["same_source_overlap"], IntervalEvent) if e.value.startswith("asleep_")]
    assert minutes(overlaps) == 470
    assert union_minutes(overlaps) == 450
    sources = current(scenarios["multi_source_sleep"], IntervalEvent)
    for suffix, expected in (("watch", 450), ("phone", 480), ("sleepapp", 390)):
        assert minutes(e for e in sources if e.value.startswith("asleep_") and e.metadata.source_bundle_id.endswith(suffix)) == expected
    assert {e.value for e in current(scenarios["in_bed_only"], IntervalEvent)} == {"in_bed"}
    nap = [e for e in current(scenarios["separate_nap"], IntervalEvent) if e.value.startswith("asleep_")]
    assert union_minutes(nap) == 480
    assert minutes(e for e in nap if e.end_at.astimezone(ZoneInfo("America/Chicago")).hour <= 7) == 450


def test_workout_coverage_and_deletion_arrival_order(scenarios):
    for name, status in (("typical", "complete"), ("workout_unavailable", "unavailable")):
        data = scenarios[name]
        assert not any(isinstance(e, WorkoutEvent) for e in data.events)
        assert data.context.coverage[0].domains.workout == status
    data = scenarios["deletion_before_sample"]
    deleted = next(e for e in data.events if isinstance(e, DeleteEvent))
    original = next(e for e in data.events if isinstance(e, PointMeasurement) and e.source_record_id == deleted.source_record_id)
    assert deleted in visible(data) and original not in visible(data)
    assert original in visible(data, "after_delivery")


@pytest.mark.parametrize("name", ["dst_spring", "dst_fall"])
def test_dst_closing_midnight_and_travel_context(scenarios, name):
    data = scenarios[name]
    snapshots = [e for e in data.events if isinstance(e, DailyActivitySnapshot)]
    last = max(snapshots, key=lambda e: e.as_of)
    local = last.as_of.astimezone(ZoneInfo(last.timezone))
    assert local.hour == 0 and local.date() == last.day + timedelta(days=1)
    travel = scenarios["travel"]
    assert {e.metadata.timezone for e in current(travel, IntervalEvent)} == {"America/Chicago"}
    assert evaluation(travel).effective_at.astimezone(ZoneInfo("America/Los_Angeles")).hour == 13


def expected(dataset, field, checkpoint="evaluation"):
    return next(a.expected for a in dataset.expectations.assertions
                if a.field == field and a.checkpoint == checkpoint)


@pytest.mark.parametrize("name,checkpoint", [("deleted_replaced", "evaluation"),
                                             ("deletion_before_sample", "after_delivery")])
def test_deletion_expectations_distinguish_the_deleted_sample(scenarios, name, checkpoint):
    # A calculator that ignored the tombstone must fail these expectations.
    data = scenarios[name]
    deleted = {e.source_record_id for e in data.events if isinstance(e, DeleteEvent)}
    zone = ZoneInfo(data.context.timezone)
    hrv = [e for e in visible(data, checkpoint) if isinstance(e, PointMeasurement) and e.metric == "hrv_sdnn_ms"
           and e.observed_at.astimezone(zone).date() == data.context.end_day]
    kept = [e.value for e in hrv if e.source_record_id not in deleted]
    removed = [e.value for e in hrv if e.source_record_id in deleted]
    assert kept == [expected(data, "hrv.value", checkpoint)]
    assert removed and expected(data, "hrv.value", checkpoint) not in removed


@pytest.mark.parametrize("name", ["zero_mad", "near_zero_mad"])
def test_scale_floor_cases_use_a_current_value_away_from_the_median(scenarios, name):
    data = scenarios[name]
    values = history_points(data, "hrv_sdnn_ms")
    current_hrv = next(e.value for e in current(data, PointMeasurement) if e.metric == "hrv_sdnn_ms")
    floor = data.expectations.assumptions["robust_scale_floor"]["hrv_sdnn_ms"]
    mad = median(abs(value - median(values)) for value in values)
    assert current_hrv != median(values)
    assert 1.4826 * mad < floor  # the floor, not MAD, decides the denominator
    assert (current_hrv - median(values)) / max(1.4826 * mad, floor) == expected(data, "hrv.robust_z")
