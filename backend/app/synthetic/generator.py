"""Event construction and seeded demo variation; no feature/state calculations."""
from __future__ import annotations

import hashlib
import json
import random
from datetime import date, datetime, time, timedelta
from uuid import UUID, uuid5
from zoneinfo import ZoneInfo

from app.contracts._types import local_day_start, utc
from app.contracts.canonical_events import (
    HEALTHKIT_TYPES, CanonicalEvent, DailyActivitySnapshot, DeleteEvent,
    IntervalEvent, PointMeasurement, SampleMetadata, WorkoutEvent, snapshot_record_id,
)
from app.synthetic import GENERATOR_VERSION
from app.synthetic.models import (
    Checkpoint, Context, Coverage, CoverageWindow, Dataset, Delivery, Expectations, GenerationConfig,
)

NAMESPACE = UUID("2caa67fe-ddba-5a56-bb1a-07a707848b77")
SOURCES = {
    "watch": ("Synthetic Watch", "org.homeostat.synthetic.watch", "SyntheticWatch1,1"),
    "phone": ("Synthetic Phone", "org.homeostat.synthetic.phone", "SyntheticPhone1,1"),
    "third_party": ("Synthetic Sleep App", "org.homeostat.synthetic.sleepapp", "SyntheticDevice1,1"),
}


def stable_id(*parts: object) -> UUID:
    return uuid5(NAMESPACE, json.dumps([GENERATOR_VERSION, *parts], separators=(",", ":")))


def local_at(day: date, hour: int, zone: str, minute: int = 0) -> datetime:
    """Validate local construction rather than silently emitting a nonexistent time."""
    result = datetime.combine(day, time(hour, minute), ZoneInfo(zone))
    if utc(result).astimezone(result.tzinfo).replace(tzinfo=None) != result.replace(tzinfo=None):
        raise ValueError(f"nonexistent local time: {day} {hour:02}:{minute:02} in {zone}")
    return result


def recorded_at(event: CanonicalEvent) -> datetime:
    if isinstance(event, DailyActivitySnapshot):
        return utc(event.queried_at)
    if isinstance(event, DeleteEvent):
        return utc(event.deleted_at)
    if isinstance(event, PointMeasurement):
        return utc(event.metadata.sample_end_at)
    return utc(event.end_at)


class Builder:
    def __init__(self, dataset_id: str, zone: str, identity_scope: str | None = None):
        self.id = dataset_id
        self.identity_scope = identity_scope or dataset_id
        self.zone = zone
        self.events: list[CanonicalEvent] = []
        self.deliveries: list[Delivery] = []

    def identity(self, key: str) -> dict:
        return {"event_id": stable_id(self.identity_scope, "event", key), "source": "healthkit",
                "source_record_id": str(stable_id(self.identity_scope, "sample", key))}

    def metadata(self, kind: str, start: datetime, end: datetime, source: str = "watch",
                 zone: str | None = None) -> SampleMetadata:
        name, bundle, device = SOURCES[source]
        return SampleMetadata(
            healthkit_type=HEALTHKIT_TYPES[kind], source_name=name, source_bundle_id=bundle,
            source_revision="synthetic-1", device_product_type=device,
            timezone=zone or self.zone, timezone_source="sample_metadata",
            sample_start_at=utc(start), sample_end_at=utc(end),
        )

    def add(self, event: CanonicalEvent, delivered_at: datetime | None = None) -> CanonicalEvent:
        self.events.append(event)
        self.deliveries.append(Delivery(id=str(event.event_id), delivered_at=utc(delivered_at or recorded_at(event)),
                                        event_ids=(event.event_id,)))
        return event

    def interval(self, key: str, start: datetime, end: datetime, value: str,
                 source: str = "watch", zone: str | None = None) -> IntervalEvent:
        event = IntervalEvent(**self.identity(key), kind="sleep_stage", value=value,
                              start_at=utc(start), end_at=utc(end),
                              metadata=self.metadata("sleep_stage", start, end, source, zone))
        self.add(event)
        return event

    def sleep(self, day: date, minutes: int = 450, awake: int = 20, source: str = "watch",
              zone: str | None = None) -> list[IntervalEvent]:
        zone = zone or self.zone
        end = utc(local_at(day, 7, zone))
        start = end - timedelta(minutes=minutes + awake)
        prefix = f"{day}/sleep/{source}"
        records = [self.interval(prefix + "/bed", start - timedelta(minutes=10),
                                 end + timedelta(minutes=20), "in_bed", source, zone)]
        first, second = minutes * 4 // 10, minutes * 3 // 10
        cursor = start
        for label, length in [("asleep_core", first), ("awake", awake),
                              ("asleep_deep", second), ("asleep_rem", minutes - first - second)]:
            if length:
                next_time = cursor + timedelta(minutes=length)
                records.append(self.interval(prefix + "/" + label, cursor, next_time, label, source, zone))
                cursor = next_time
        return records

    def point(self, day: date, metric: str, value: float, suffix: str = "",
              delivered_at: datetime | None = None) -> PointMeasurement:
        end = utc(local_at(day, 7, self.zone, 15 if metric == "hrv_sdnn_ms" else 30))
        event = PointMeasurement(**self.identity(f"{day}/{metric}/{suffix}"), metric=metric,
                                 value=value, unit="ms" if metric == "hrv_sdnn_ms" else "bpm",
                                 observed_at=end, metadata=self.metadata(metric, end - timedelta(minutes=1), end))
        self.add(event, delivered_at)
        return event

    def snapshot(self, day: date, as_of: datetime, steps: int, queried_at: datetime | None = None,
                 zone: str | None = None) -> DailyActivitySnapshot:
        zone = zone or self.zone
        query = utc(queried_at or as_of)
        record_id = snapshot_record_id(zone, day, as_of, query, steps)
        event = DailyActivitySnapshot(event_id=stable_id(self.identity_scope, "event", record_id),
                                      source="healthkit", source_record_id=record_id, day=day,
                                      timezone=zone, as_of=utc(as_of), queried_at=query, steps=steps)
        self.add(event)
        return event

    def steps(self, day: date, at_13: int) -> list[DailyActivitySnapshot]:
        points = [(local_at(day, 8, self.zone), at_13 // 2),
                  (local_at(day, 13, self.zone), at_13),
                  (local_at(day, 18, self.zone), at_13 + 2000),
                  (local_day_start(day + timedelta(days=1), self.zone), at_13 + 4000)]
        return [self.snapshot(day, moment, total) for moment, total in points]

    def workout(self, end: datetime, minutes: int = 60, suffix: str = "") -> WorkoutEvent:
        end = utc(end)
        start = end - timedelta(minutes=minutes)
        event = WorkoutEvent(**self.identity(f"workout/{end.isoformat()}/{suffix}"),
                             workout_type="traditional_strength_training", start_at=start, end_at=end,
                             duration_minutes=minutes, metadata=self.metadata("workout", start, end))
        self.add(event)
        return event

    def delete(self, original: CanonicalEvent, at: datetime) -> DeleteEvent:
        event = DeleteEvent(event_id=stable_id(self.identity_scope, "delete", str(original.event_id)), source="healthkit",
                            source_record_id=original.source_record_id, deleted_at=utc(at))
        self.add(event)
        return event

    def daily(self, day: date, sleep: int | None = 450, hrv: float | None = 50,
              rhr: float | None = 60, steps: int | None = 5200, awake: int = 20) -> list[CanonicalEvent]:
        offset = len(self.events)
        if sleep is not None:
            self.sleep(day, sleep, awake)
        if hrv is not None:
            self.point(day, "hrv_sdnn_ms", hrv)
        if rhr is not None:
            self.point(day, "resting_hr_bpm", rhr)
        if steps is not None:
            self.steps(day, steps)
        return self.events[offset:]

    def finish(self, start: date, end: date, checkpoints: list[Checkpoint], note: str,
               golden: int | None = None, labels: tuple[str, ...] = (),
               coverage: Coverage | None = None, expectations: Expectations | None = None) -> Dataset:
        return Dataset(
            context=Context(id=self.id, timezone=self.zone, start_day=start, end_day=end,
                            golden_case=golden, checkpoints=tuple(checkpoints), labels=labels, note=note,
                            coverage=(CoverageWindow(start_day=start, end_day=end,
                                                     domains=coverage or Coverage()),)),
            events=tuple(sorted(self.events, key=lambda e: str(e.event_id))),
            deliveries=tuple(sorted(self.deliveries, key=lambda d: (utc(d.delivered_at), d.id))),
            expectations=expectations,
        )


def checkpoint(at: datetime, id: str = "evaluation", known_at: datetime | None = None,
               note: str = "Use only deliveries available by known_at and observations relevant to effective_at.") -> Checkpoint:
    return Checkpoint(id=id, effective_at=utc(at), known_at=utc(known_at or at), note=note)


def variation(seed: int, day: date, domain: str, low: int, high: int) -> int:
    key = json.dumps([seed, day.isoformat(), domain], separators=(",", ":")).encode()
    return random.Random(int.from_bytes(hashlib.sha256(key).digest(), "big")).randint(low, high)


def generate_demo(config: GenerationConfig) -> Dataset:
    scope = f"demo/{config.seed}/{config.start_date}/{config.timezone}"
    b = Builder("demo", config.timezone, identity_scope=scope)
    checkpoints = []
    for index in range(config.days):
        day = config.start_date + timedelta(days=index)
        sleep = variation(config.seed, day, "sleep", 420, 480)
        hrv = variation(config.seed, day, "hrv", 44, 56)
        rhr = variation(config.seed, day, "rhr", 56, 64)
        steps = variation(config.seed, day, "steps", 4300, 6100)
        if index % 40 == 29:
            sleep = 330
        if index % 40 == 30:
            hrv = None
        if index % 40 == 31:
            hrv = 20
        if index % 40 == 32:
            hrv = 80
        if index % 40 == 33:
            rhr = 75
        if index % 40 == 34:
            steps = 2900
        if index % 40 == 35:
            steps = 8500
        b.daily(day, sleep, hrv, rhr, steps)
        if index % 7 in (1, 4):
            b.workout(local_at(day, 18, config.timezone))
        if index % 40 == 36:
            b.sleep(day, 490, source="phone")
        if index % 40 == 37:
            original = next(e for e in b.events if isinstance(e, PointMeasurement)
                            and e.metric == "hrv_sdnn_ms" and e.observed_at.astimezone(ZoneInfo(config.timezone)).date() == day)
            at = local_at(day, 12, config.timezone)
            b.delete(original, at)
            b.point(day, "hrv_sdnn_ms", 50, "replacement", at + timedelta(minutes=1))
        checkpoints.extend([checkpoint(local_at(day, hour, config.timezone), f"{day}_{hour:02}")
                            for hour in (8, 13, 19)])
    return b.finish(config.start_date, config.start_date + timedelta(days=config.days - 1), checkpoints,
                    "Seeded fictional history. Prior calendar days exclude the evaluation day; not calculated health state.",
                    labels=("short_sleep", "missing_hrv", "low_hrv", "high_hrv", "high_rhr", "steps_variance",
                            "multi_source_sleep", "deletion_replacement"))
