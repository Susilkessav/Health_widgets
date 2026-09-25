"""Small builders for calculator tests. Events come from the synthetic Builder
so they are always contract-valid."""
from datetime import date, datetime, timedelta

from app.config import Settings
from app.contracts.canonical_events import PointMeasurement, WorkoutEvent
from app.features.calculate import calculate_features
from app.features.models import DOMAINS, CalculationContext, CoverageWindow, Observation
from app.synthetic.generator import Builder, local_at

ZONE = "America/Chicago"
DAY = date(2026, 9, 22)
SETTINGS = Settings()


def at(hour: int, minute: int = 0, day: date = DAY, zone: str = ZONE) -> datetime:
    return local_at(day, hour, zone, minute)


def observations(builder: Builder) -> list[Observation]:
    events = {event.event_id: event for event in builder.events}
    return [Observation(event=events[event_id], delivered_at=batch.delivered_at)
            for batch in builder.deliveries for event_id in batch.event_ids]


def context(day=DAY, effective=None, known=None, zone=ZONE, first=None, unavailable=()) -> CalculationContext:
    effective = effective or at(13, day=day, zone=zone)
    first = first or day - timedelta(days=40)
    return CalculationContext(
        day=day, timezone=zone, effective_at=effective, known_at=known or effective,
        coverage=tuple(CoverageWindow(domain=d, start_day=first, end_day=day, timezone=zone,
                                      status="unavailable" if d in unavailable else "complete") for d in DOMAINS))


def calc(builder: Builder, settings: Settings = SETTINGS, **kwargs):
    return calculate_features(observations(builder), context(**kwargs), settings)


def history(builder: Builder, day=DAY, days=28, **daily):
    for index in range(days):
        builder.daily(day - timedelta(days=days - index), **daily)


def point(builder: Builder, key: str, metric: str, value: float, observed: datetime, source="watch"):
    unit = "ms" if metric == "hrv_sdnn_ms" else "bpm"
    event = PointMeasurement(**builder.identity(key), metric=metric, value=value, unit=unit, observed_at=observed,
                             metadata=builder.metadata(metric, observed - timedelta(minutes=1), observed, source))
    builder.add(event)
    return event


def workout(builder: Builder, key: str, start: datetime, end: datetime, active: float, source="watch"):
    event = WorkoutEvent(**builder.identity(key), workout_type="running", start_at=start, end_at=end,
                         duration_minutes=active, metadata=builder.metadata("workout", start, end, source))
    builder.add(event)
    return event
