import math
from datetime import datetime, timezone

import pytest
from pydantic import ValidationError

from app.config import DEFAULT_PATH, Settings, load_settings, parse_settings, settings_sha256
from app.features.selection import group_of
from app.synthetic.generator import Builder

DEFAULT = settings_sha256(Settings())


def test_saved_file_matches_the_built_in_defaults():
    assert settings_sha256(load_settings(DEFAULT_PATH)) == DEFAULT


@pytest.mark.parametrize("text", [
    "",                                                        # everything omitted
    "# only a comment\n",
    "baseline: {minimum_valid_days: 14, window_days: 28}",    # key order
    "hrv: {lower_z: -1, upper_z: 1, scale_floor: 1}",         # 1 vs 1.0
    "sleep:\n    overnight_start: '18:00'\n",                  # formatting
])
def test_equivalent_configurations_hash_identically(text):
    assert settings_sha256(parse_settings(text)) == DEFAULT


@pytest.mark.parametrize("text", [
    "hrv: {upper_z: 1.5}",
    "source_groups:\n  - {id: synthetic_phone, bundle_id: org.homeostat.synthetic.phone}\n"
    "  - {id: synthetic_watch, bundle_id: org.homeostat.synthetic.watch}",  # priority order matters
])
def test_behavioral_changes_change_the_hash(text):
    assert settings_sha256(parse_settings(text)) != DEFAULT


@pytest.mark.parametrize("text", [
    "baseline: {window_days: 28}\nbaseline: {window_days: 21}",   # duplicate key
    "baseline: {window_days: 28, window_days: 21}",
    "baseline: {windows: 28}",                                    # unknown key
    "hrv: {scale_floor: .nan}",
    "hrv: {upper_z: .inf}",
    "hrv: {lower_z: 1, upper_z: -1}",                             # reversed thresholds
    "movement: {behind_ratio: 1.4, ahead_ratio: 1.3}",
    "workout: {just_completed_hours: 13, recent_hours: 12}",
    "baseline: {window_days: 10, minimum_valid_days: 14}",       # impossible readiness
    "sleep: {overnight_start: 18:00}",                            # YAML reads this as 1080
    "hrv: {scale_floor: true}",
    "schema_version: 2",
    "- not a mapping",
    "freshness: {movement: {full_hours: 3, zero_hours: 1}}",
    "source_groups: [{id: a, bundle_id: x}, {id: a, bundle_id: y}]",               # duplicate ids
    "source_groups: [{id: a, bundle_id: x}, {id: b, bundle_id: x}]",               # identical selectors
    "source_groups: [{id: a, bundle_id: x, bundle_prefix: x}]",                    # ambiguous selector
    "source_groups: [{id: a, bundle_id: x, weight: 1.5}]",
])
def test_invalid_configurations_are_rejected(text):
    with pytest.raises((ValueError, ValidationError)):
        parse_settings(text)


def test_apple_watch_devices_share_one_group_and_unknown_sources_rank_last():
    settings, builder = Settings(), Builder("t", "America/Chicago")
    moment = datetime(2026, 1, 1, tzinfo=timezone.utc)
    meta = builder.metadata("hrv_sdnn_ms", moment, moment)
    old = group_of(settings, meta.model_copy(update={"source_bundle_id": "com.apple.health.AAA", "device_product_type": "Watch6,2"}))
    new = group_of(settings, meta.model_copy(update={"source_bundle_id": "com.apple.health.BBB", "device_product_type": "Watch7,1"}))
    phone = group_of(settings, meta.model_copy(update={"source_bundle_id": "com.apple.health.CCC", "device_product_type": "iPhone15,2"}))
    unknown_b = group_of(settings, meta.model_copy(update={"source_bundle_id": "com.b", "device_product_type": None}))
    unknown_a = group_of(settings, meta.model_copy(update={"source_bundle_id": "com.a", "device_product_type": None}))
    assert old == new and old.id == "apple_watch"
    assert old < phone < unknown_a < unknown_b
    assert unknown_a.id == "unknown:com.a|unknown-device"
    assert not math.isnan(unknown_a.weight)
