"""Validated calculation settings (backend/config/homeostat.yaml) and their replay hash.

The hash covers the fully resolved, validated settings (so omitted and explicit
defaults, YAML formatting, comments, key order and `1` vs `1.0` all hash the
same), serialized as JSON with sorted keys, compact separators and UTF-8, with
no trailing newline.
"""
from __future__ import annotations

import hashlib
import json
from datetime import time
from pathlib import Path
from typing import Annotated, Any, Literal

import yaml
from pydantic import BeforeValidator, Field, model_validator

from app.contracts._types import (
    Confidence,
    FiniteFloat,
    Frozen,
    NonEmptyStr,
    NonNegativeFloat,
    PositiveCount,
    PositiveFloat,
)

DEFAULT_PATH = Path(__file__).resolve().parents[1] / "config" / "homeostat.yaml"


def _quoted_time(value: Any) -> Any:
    # YAML 1.1 reads an unquoted 18:00 as the integer 1080, which would
    # silently become 00:18. Require the quoted "HH:MM" form.
    if not isinstance(value, (str, time)):
        raise ValueError('times must be quoted strings such as "18:00"')
    return value


LocalTime = Annotated[time, BeforeValidator(_quoted_time)]


class Baseline(Frozen):
    window_days: PositiveCount = 28
    minimum_valid_days: PositiveCount = 14

    @model_validator(mode="after")
    def _consistent(self) -> Baseline:
        if self.minimum_valid_days > self.window_days:
            raise ValueError("minimum_valid_days cannot exceed window_days")
        return self


class SleepSettings(Frozen):
    below_minutes: PositiveFloat = 60
    above_minutes: PositiveFloat = 60
    episode_gap_minutes: NonNegativeFloat = 90
    # The overnight window runs from overnight_start on the previous local day
    # to overnight_end on the wake day.
    overnight_start: LocalTime = time(18, 0)
    overnight_end: LocalTime = time(12, 0)
    source_policy_version: NonEmptyStr = "sleep-source-policy@0.1.0"


class PointSettings(Frozen):
    lower_z: FiniteFloat = -1.0
    upper_z: FiniteFloat = 1.0
    # robust_z = (x - median) / max(1.4826 * MAD, scale_floor), in metric units.
    scale_floor: PositiveFloat = 1.0

    @model_validator(mode="after")
    def _consistent(self) -> PointSettings:
        if not self.lower_z < self.upper_z:
            raise ValueError("lower_z must be below upper_z")
        return self


class MovementSettings(Frozen):
    behind_ratio: PositiveFloat = 0.70
    ahead_ratio: PositiveFloat = 1.30
    # History buckets count if their local wall time is at most this much
    # earlier than the current comparison time (any timezone).
    comparison_window_minutes: PositiveFloat = Field(default=60, le=1440)

    @model_validator(mode="after")
    def _consistent(self) -> MovementSettings:
        if not self.behind_ratio < self.ahead_ratio:
            raise ValueError("behind_ratio must be below ahead_ratio")
        return self


class WorkoutSettings(Frozen):
    just_completed_hours: PositiveFloat = 2
    recent_hours: PositiveFloat = 12
    totals_days: PositiveCount = 7

    @model_validator(mode="after")
    def _consistent(self) -> WorkoutSettings:
        if self.just_completed_hours > self.recent_hours:
            raise ValueError("just_completed_hours cannot exceed recent_hours")
        return self


class StateSettings(Frozen):
    # |sleep delta| in minutes at which HealthState sleep severity reaches 1.
    sleep_severity_full_minutes: PositiveFloat = 120


class Freshness(Frozen):
    """Full confidence until full_hours, then linear decay to zero at zero_hours."""

    full_hours: NonNegativeFloat
    zero_hours: PositiveFloat

    @model_validator(mode="after")
    def _consistent(self) -> Freshness:
        if not self.full_hours < self.zero_hours:
            raise ValueError("full_hours must be below zero_hours")
        return self


class FreshnessSettings(Frozen):
    # Once-daily values stay fully fresh through the report day; movement is
    # read roughly hourly, so it decays once the next read is overdue.
    sleep: Freshness = Freshness(full_hours=24, zero_hours=48)
    hrv: Freshness = Freshness(full_hours=24, zero_hours=48)
    rhr: Freshness = Freshness(full_hours=24, zero_hours=48)
    movement: Freshness = Freshness(full_hours=1, zero_hours=3)


class SourceGroup(Frozen):
    """A metadata selector. Groups are matched in list order (first match
    wins), and that order is also the source priority."""

    id: str = Field(pattern=r"^[a-z][a-z0-9_]*$")
    bundle_id: NonEmptyStr | None = None
    bundle_prefix: NonEmptyStr | None = None
    product_type_prefix: NonEmptyStr | None = None
    weight: Confidence = 1.0

    @model_validator(mode="after")
    def _consistent(self) -> SourceGroup:
        if (self.bundle_id is None) == (self.bundle_prefix is None):
            raise ValueError(f"source group {self.id!r} needs exactly one of bundle_id or bundle_prefix")
        return self

    def matches(self, bundle_id: str, product_type: str | None) -> bool:
        if self.bundle_id is not None and bundle_id != self.bundle_id:
            return False
        if self.bundle_prefix is not None and not bundle_id.startswith(self.bundle_prefix):
            return False
        if self.product_type_prefix is not None:
            return product_type is not None and product_type.startswith(self.product_type_prefix)
        return True


DEFAULT_SOURCE_GROUPS = (
    # Apple Watch samples carry per-device bundle IDs (com.apple.health.<UUID>)
    # and model-specific product types; one family group keeps baselines
    # across watch replacements. Verify against real device metadata.
    SourceGroup(id="apple_watch", bundle_prefix="com.apple.health.", product_type_prefix="Watch"),
    SourceGroup(id="synthetic_watch", bundle_id="org.homeostat.synthetic.watch"),
    SourceGroup(id="apple_iphone", bundle_prefix="com.apple.health.", product_type_prefix="iPhone"),
    SourceGroup(id="synthetic_phone", bundle_id="org.homeostat.synthetic.phone"),
    SourceGroup(id="synthetic_sleep_app", bundle_id="org.homeostat.synthetic.sleepapp"),
)


class Settings(Frozen):
    schema_version: Literal[1] = 1
    calculation_version: Literal["features-calc@0.1.0"] = "features-calc@0.1.0"
    baseline: Baseline = Baseline()
    sleep: SleepSettings = SleepSettings()
    hrv: PointSettings = PointSettings()
    rhr: PointSettings = PointSettings()
    movement: MovementSettings = MovementSettings()
    workout: WorkoutSettings = WorkoutSettings()
    freshness: FreshnessSettings = FreshnessSettings()
    state: StateSettings = StateSettings()
    source_groups: tuple[SourceGroup, ...] = DEFAULT_SOURCE_GROUPS

    @model_validator(mode="after")
    def _consistent(self) -> Settings:
        ids = [group.id for group in self.source_groups]
        if len(ids) != len(set(ids)):
            raise ValueError("source group ids must be unique")
        selectors = [(g.bundle_id, g.bundle_prefix, g.product_type_prefix) for g in self.source_groups]
        if len(selectors) != len(set(selectors)):
            raise ValueError("two source groups have identical selectors")
        return self


def settings_payload(settings: Settings) -> dict[str, Any]:
    return settings.model_dump(mode="json")


def settings_sha256(settings: Settings) -> str:
    text = json.dumps(settings_payload(settings), sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class _UniqueKeyLoader(yaml.SafeLoader):
    pass


def _unique_mapping(loader: _UniqueKeyLoader, node: yaml.MappingNode, deep: bool = False) -> dict:
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise yaml.constructor.ConstructorError(None, None, f"duplicate key {key!r}", key_node.start_mark)
        seen.add(key)
    return loader.construct_mapping(node, deep=deep)


_UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _unique_mapping)


def parse_settings(text: str) -> Settings:
    try:
        data = yaml.load(text, Loader=_UniqueKeyLoader)  # noqa: S506 - SafeLoader subclass
    except yaml.YAMLError as error:
        raise ValueError(f"invalid configuration YAML: {error}") from error
    if data is None:
        data = {}
    if not isinstance(data, dict):
        raise ValueError("configuration must be a mapping")
    return Settings.model_validate(data)


def load_settings(path: Path = DEFAULT_PATH) -> Settings:
    return parse_settings(Path(path).read_text(encoding="utf-8"))
