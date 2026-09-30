from datetime import datetime, timedelta, timezone
from itertools import permutations
from uuid import UUID

import pytest

from app.providers.identity import (Namespace, RecordKey, SeriesKey, Metric, Version, VerifiedOrigin,
    Candidate, Coverage, content_hash, mirror_groups, resolve_versions, select_stream, usable_through)

USER = UUID(int=1)
NOW = datetime(2026, 9, 30, 12, tzinfo=timezone.utc)


def version(provider='healthkit', account='account', record='same-id', metric=Metric.STEPS, revision=1, value=100, deleted=False):
    ns = Namespace(USER, provider, account, 'store')
    key = RecordKey(ns, metric, record)
    series = SeriesKey(ns, metric, 'provider-native', 'daily' if metric == Metric.STEPS else 'event')
    return Version(key, series, content_hash({'value': value}), revision, deleted)


def test_colliding_bare_ids_are_distinct_across_provider_account_and_metric():
    records = [version(), version(provider='oura'), version(account='another'), version(metric=Metric.HRV_SDNN)]
    assert len(resolve_versions(records).selected) == 4


def test_repeated_deliveries_and_reinstall_observations_have_one_effect():
    record = version()
    assert resolve_versions([record] * 10).selected == (record,)


@pytest.mark.parametrize('metric', list(Metric))
def test_authoritative_correction_wins_independent_of_delivery_order(metric):
    older = version(metric=metric, value=100, revision=1)
    corrected = version(metric=metric, value=80, revision=2)
    for items in permutations([older, corrected, older]):
        assert resolve_versions(list(items)).selected == (corrected,)


@pytest.mark.parametrize('revision', [1, None])
def test_equal_or_unknown_authority_conflicts_do_not_use_arrival_order(revision):
    a = version(value=100, revision=revision)
    b = version(value=80, revision=revision)
    for items in ([a, b], [b, a]):
        result = resolve_versions(items)
        assert not result.selected and result.conflicts == {a.key}


def test_delete_is_scoped_to_provider_record_and_independent_mirror_survives():
    original = version()
    mirror = version(provider='oura')
    deleted = version(deleted=True, revision=2)
    result = resolve_versions([original, mirror, deleted])
    assert result.selected == (mirror,)
    assert result.deleted == {original.key}


def test_verified_mirrors_group_but_similar_values_do_not():
    a, b, c = version().key, version(provider='oura').key, version(provider='garmin').key
    proof = VerifiedOrigin(USER, 'oura', 'verified-account', 'upstream-id', Metric.STEPS)
    groups = mirror_groups([a, b, c], {a: proof, b: proof})
    assert set(map(frozenset, groups)) == {frozenset([a, b]), frozenset([c])}
    assert len(mirror_groups([a, b, c], {})) == 3
    with pytest.raises(ValueError):
        mirror_groups([a], {a: VerifiedOrigin(UUID(int=2), 'oura', 'account', 'id', Metric.STEPS)})


def test_overlapping_cumulative_steps_choose_one_stream_and_latest_cutoff():
    a, b = version(), version(provider='oura', value=90)
    newer = version(record='later-snapshot', value=120)
    future = version(record='future-snapshot', value=150)
    candidates = [Candidate(a, NOW - timedelta(hours=1), 100), Candidate(b, NOW, 90),
                  Candidate(newer, NOW, 120), Candidate(future, NOW + timedelta(hours=1), 150)]
    assert select_stream(candidates, metric=Metric.STEPS, cutoff=NOW, priority=(a.series, b.series)) == (candidates[2],)


def test_downward_correction_is_selected_without_adding_previous_total():
    old, new = version(value=100, revision=1), version(value=70, revision=2)
    selected = select_stream([Candidate(old, NOW, 100), Candidate(new, NOW, 70)], metric=Metric.STEPS, cutoff=NOW, priority=(new.series,))
    assert len(selected) == 1 and selected[0].value == 70


def test_equal_cutoff_conflicting_snapshots_do_not_pick_by_record_id():
    a, b = version(record='a'), version(record='b', value=90)
    assert not select_stream([Candidate(a, NOW, 100), Candidate(b, NOW, 90)], metric=Metric.STEPS, cutoff=NOW, priority=(a.series,))


@pytest.mark.parametrize('metric', [Metric.SLEEP_STAGE, Metric.SLEEP_SUMMARY, Metric.WORKOUT])
def test_ambiguous_shifted_mirror_streams_are_not_combined(metric):
    a, b = version(metric=metric), version(provider='oura', metric=metric)
    selected = select_stream([Candidate(a, NOW), Candidate(b, NOW - timedelta(minutes=1))], metric=metric, cutoff=NOW, priority=(a.series, b.series))
    assert selected == (Candidate(a, NOW),)


def test_sdnn_rmssd_and_summary_stage_series_remain_incompatible():
    sdnn, rmssd = version(metric=Metric.HRV_SDNN), version(metric=Metric.HRV_RMSSD)
    assert sdnn.series != rmssd.series
    assert not select_stream([Candidate(rmssd, NOW)], metric=Metric.HRV_SDNN, cutoff=NOW, priority=(sdnn.series,))
    assert version(metric=Metric.SLEEP_STAGE).series != version(metric=Metric.SLEEP_SUMMARY).series


def test_unselected_provider_and_partial_scan_do_not_change_selected_coverage():
    selected, unused = version().series, version(provider='oura').series
    start = NOW - timedelta(days=1)
    coverage = [Coverage(selected, start, NOW, True), Coverage(unused, start, NOW - timedelta(hours=6), False)]
    assert usable_through(coverage, (selected,), start, NOW) == NOW
    assert usable_through(coverage, (selected, unused), start, NOW) is None
    assert not resolve_versions([]).deleted  # missing observations are not tombstones


def test_coverage_gap_is_not_inferred_complete():
    series = version().series
    start = NOW - timedelta(days=1)
    windows = [Coverage(series, start, start + timedelta(hours=1), True),
               Coverage(series, start + timedelta(hours=2), NOW, True)]
    assert usable_through(windows, (series,), start, NOW) == start + timedelta(hours=1)
