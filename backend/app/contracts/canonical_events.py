"""Canonical event contracts: what a provider (HealthKit in G1) reported.

Mirrors plan_G1.md section 9. Identity, timezone, snapshot-correction and
deletion rules are documented in backend/README.md.
"""
from __future__ import annotations

from collections.abc import Iterable
from datetime import date, datetime, timedelta
from typing import Annotated, Literal
from uuid import UUID
from zoneinfo import ZoneInfo

from pydantic import AwareDatetime, Field, model_validator

from app.contracts._types import (
    DURATION_TOLERANCE_MINUTES,
    Count,
    Frozen,
    IanaTimezone,
    NonEmptyStr,
    NonNegativeFloat,
    PositiveFloat,
    local_day_start,
    utc,
)

SCHEMA_VERSION = "1.0.0"

# The HealthKit type each canonical event must come from.
HEALTHKIT_TYPES = {
    "hrv_sdnn_ms": "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
    "resting_hr_bpm": "HKQuantityTypeIdentifierRestingHeartRate",
    "sleep_stage": "HKCategoryTypeIdentifierSleepAnalysis",
    "workout": "HKWorkoutTypeIdentifier",
}


class ProviderMetadataEntry(Frozen):
    """A HealthKit metadata entry the canonical fields don't model. The adapter
    stringifies values (ISO 8601 for dates, "<value> <unit>" for HKQuantity)
    so nothing is dropped before normalization."""

    key: NonEmptyStr
    value: str


class SampleMetadata(Frozen):
    """Provenance for one HealthKit sample (plan_G1.md section 8).

    HealthKit always reports a sample's source name and bundle identifier, so
    both are required; an unrecognized source is still identified, and the
    sleep source resolver ranks it as third-party. `timezone` falls back to
    the device's zone at ingestion when the sample has no
    HKMetadataKeyTimeZone, and `timezone_source` records which one it is.
    """

    healthkit_type: NonEmptyStr
    source_name: NonEmptyStr
    source_bundle_id: NonEmptyStr
    source_revision: NonEmptyStr | None = None
    device_product_type: NonEmptyStr | None = None
    timezone: IanaTimezone
    timezone_source: Literal["sample_metadata", "device_at_ingestion"]
    sample_start_at: AwareDatetime
    sample_end_at: AwareDatetime
    provider_metadata: tuple[ProviderMetadataEntry, ...] = ()

    @model_validator(mode="after")
    def _consistent(self) -> SampleMetadata:
        if utc(self.sample_end_at) < utc(self.sample_start_at):
            raise ValueError("sample_end_at must not be before sample_start_at")
        keys = [entry.key for entry in self.provider_metadata]
        if len(keys) != len(set(keys)):
            raise ValueError("provider_metadata keys must be unique")
        return self


class _EventBase(Frozen):
    schema_version: Literal["1.0.0"] = SCHEMA_VERSION
    # Client-generated; also the sync API's client_event_id. Stable across
    # retries of the same event, never reused for a different observation.
    event_id: UUID
    source: Literal["healthkit"]
    # The provider's identity for the observation (an HKSample UUID, or the
    # snapshot ID below). With `source` and `event_type` it's the dedup key.
    source_record_id: NonEmptyStr


class _SampleEvent(_EventBase):
    metadata: SampleMetadata

    def _check_metadata(self, kind: str, start: datetime | None = None, end: datetime | None = None) -> None:
        """Retained metadata must describe this event: the right HealthKit
        type, and (for interval-shaped events) the same start and end."""
        if self.metadata.healthkit_type != HEALTHKIT_TYPES[kind]:
            raise ValueError(f"metadata.healthkit_type must be {HEALTHKIT_TYPES[kind]!r} for {kind}")
        if start is not None and (
            utc(self.metadata.sample_start_at) != utc(start) or utc(self.metadata.sample_end_at) != utc(end)
        ):
            raise ValueError("metadata sample_start_at/sample_end_at must equal the event's start_at/end_at")


class PointMeasurement(_SampleEvent):
    event_type: Literal["point_measurement"] = "point_measurement"
    metric: Literal["hrv_sdnn_ms", "resting_hr_bpm"]
    observed_at: AwareDatetime
    value: PositiveFloat
    unit: Literal["ms", "bpm"]

    @model_validator(mode="after")
    def _consistent(self) -> PointMeasurement:
        expected = {"hrv_sdnn_ms": "ms", "resting_hr_bpm": "bpm"}[self.metric]
        if self.unit != expected:
            raise ValueError(
                f"INVALID_UNIT: metric={self.metric!r} requires unit={expected!r}, got {self.unit!r}"
            )
        self._check_metadata(self.metric)
        start, end = utc(self.metadata.sample_start_at), utc(self.metadata.sample_end_at)
        if not start <= utc(self.observed_at) <= end:
            raise ValueError("observed_at must fall within the sample's start/end")
        return self


class IntervalEvent(_SampleEvent):
    event_type: Literal["interval"] = "interval"
    kind: Literal["sleep_stage"]
    value: Literal[
        "in_bed", "awake", "asleep_unspecified", "asleep_core", "asleep_deep", "asleep_rem"
    ]
    start_at: AwareDatetime
    end_at: AwareDatetime

    @model_validator(mode="after")
    def _consistent(self) -> IntervalEvent:
        if not utc(self.start_at) < utc(self.end_at):
            raise ValueError("start_at must be before end_at")
        self._check_metadata(self.kind, self.start_at, self.end_at)
        return self


class WorkoutEvent(_SampleEvent):
    """A completed workout. HealthKit only surfaces an HKWorkout once it ends,
    so this can't represent an in-progress workout; that's why G1 never
    produces the "active" workout state."""

    event_type: Literal["workout"] = "workout"
    workout_type: NonEmptyStr
    start_at: AwareDatetime
    end_at: AwareDatetime
    # HKWorkout.duration excludes pauses, so it can be shorter than end - start.
    duration_minutes: NonNegativeFloat

    @model_validator(mode="after")
    def _consistent(self) -> WorkoutEvent:
        elapsed = (utc(self.end_at) - utc(self.start_at)).total_seconds() / 60
        if elapsed <= 0:
            raise ValueError("start_at must be before end_at")
        if self.duration_minutes > elapsed + DURATION_TOLERANCE_MINUTES:
            raise ValueError("duration_minutes cannot exceed end_at - start_at")
        self._check_metadata("workout", self.start_at, self.end_at)
        return self


def snapshot_record_id(timezone: str, day: date, as_of: datetime, queried_at: datetime, steps: int) -> str:
    # `steps` is part of the identity, so two reads that share an ID are
    # identical and deduplication can never discard a different total.
    return (
        f"steps:{timezone}:{day.isoformat()}:{utc(as_of).isoformat()}:{utc(queried_at).isoformat()}:{steps}"
    )


class DailyActivitySnapshot(_EventBase):
    """Cumulative steps for local `day` (in `timezone`) from local midnight up
    to `as_of`, read by an HKStatisticsQuery at `queried_at`.

    Each read is its own event (`source_record_id` = snapshot_record_id(...),
    which includes the total), so intraday history is never overwritten and
    equal IDs always mean identical reads. HealthKit can revise a past bucket
    when late watch data arrives. Use resolve_snapshot_bucket to select the
    latest query or report conflicting totals at that query time.
    """

    event_type: Literal["daily_activity_snapshot"] = "daily_activity_snapshot"
    day: date
    timezone: IanaTimezone
    as_of: AwareDatetime
    queried_at: AwareDatetime
    steps: Count

    @model_validator(mode="after")
    def _consistent(self) -> DailyActivitySnapshot:
        local = utc(self.as_of).astimezone(ZoneInfo(self.timezone))
        # The day's closing boundary is the next local day's first instant; that
        # is 01:00, not 00:00, where DST skips midnight.
        closing = utc(self.as_of) == local_day_start(self.day + timedelta(days=1), self.timezone)
        if local.date() != self.day and not closing:
            raise ValueError("as_of must fall on `day` in `timezone` (or be that day's closing boundary)")
        if utc(self.queried_at) < utc(self.as_of):
            raise ValueError("queried_at cannot be before as_of")
        expected = snapshot_record_id(self.timezone, self.day, self.as_of, self.queried_at, self.steps)
        if self.source_record_id != expected:
            raise ValueError(f"source_record_id must be {expected!r}")
        return self

    @property
    def bucket(self) -> tuple[str, date, datetime]:
        return (self.timezone, self.day, utc(self.as_of))


class SnapshotConflictError(ValueError):
    """The newest query time for a bucket contains contradictory totals."""


def resolve_snapshot_bucket(
    snapshots: Iterable[DailyActivitySnapshot],
) -> DailyActivitySnapshot | None:
    """Resolve one bucket independently of upload order.

    No reads returns None. Equal-time contradictory totals raise an explicit
    conflict instead of choosing a number or falling back to stale data. A
    strictly newer, unambiguous query resolves an earlier conflict. This
    helper does not choose between buckets or filter by evaluation time.
    """
    reads = tuple(snapshots)
    if not reads:
        return None
    if any(read.bucket != reads[0].bucket for read in reads):
        raise ValueError("snapshot resolution requires exactly one bucket")
    latest_query = max(utc(read.queried_at) for read in reads)
    latest = [read for read in reads if utc(read.queried_at) == latest_query]
    if len({read.steps for read in latest}) != 1:
        raise SnapshotConflictError("conflicting step totals at the latest query time")
    # Identical reads can have different client IDs. Pick a stable representative;
    # its ID never decides which health value wins.
    return min(latest, key=lambda read: read.event_id.int)


class DeleteEvent(_EventBase):
    """HKDeletedObject carries no deletion time or source metadata, so
    `deleted_at` is when the adapter observed the deletion."""

    event_type: Literal["delete"] = "delete"
    deleted_at: AwareDatetime


CanonicalEvent = Annotated[
    PointMeasurement | IntervalEvent | WorkoutEvent | DailyActivitySnapshot | DeleteEvent,
    Field(discriminator="event_type"),
]
