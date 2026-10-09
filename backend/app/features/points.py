"""HRV SDNN and resting HR: one reading per local day, robust baselines (plan §6).

Daily reading rule (fixed per day, so the value doesn't drift between the
morning and evening checks, and it still cites one provider record):
  1. the latest reading inside that day's primary sleep episode; else
  2. the first reading after that episode ends, on the same local day; else,
     when there is no primary episode, the first reading of the local day.
Equal times break ties by provider record ID.
"""
from __future__ import annotations

from collections import defaultdict
from datetime import date
from statistics import median

from app.config import PointSettings, Settings
from app.contracts._types import utc
from app.contracts.canonical_events import PointMeasurement
from app.features.models import CalculationContext, Outcome, history_days
from app.features.selection import Group, Selection, group_of, local_date
from app.features.sleep import Episode

ROBUST_SCALE = 1.4826


def median_mad(values: list[float]) -> tuple[float, float]:
    center = median(values)
    return center, median(abs(value - center) for value in values)


def robust_z(value: float, center: float, mad: float, floor: float) -> float:
    return (value - center) / max(ROBUST_SCALE * mad, floor)


def daily_reading(readings: list[PointMeasurement], day: date, episode: Episode | None) -> PointMeasurement | None:
    def key(r):
        return (utc(r.observed_at), r.source_record_id)

    on_day = [r for r in readings if local_date(r.observed_at, r.metadata.timezone) == day]
    if episode is None:
        return min(on_day, key=key, default=None)
    inside = [r for r in readings if episode.start <= utc(r.observed_at) <= episode.end]
    if inside:
        return max(inside, key=key)
    return min((r for r in on_day if utc(r.observed_at) > episode.end), key=key, default=None)


def classify(z: float, rules: PointSettings) -> str:
    return "below_usual" if z < rules.lower_z else "above_usual" if z > rules.upper_z else "typical"


def calculate(metric: str, selection: Selection, context: CalculationContext, settings: Settings,
              primaries: dict[date, Episode | None]) -> Outcome:
    domain = "hrv" if metric == "hrv_sdnn_ms" else "rhr"
    rules: PointSettings = getattr(settings, domain)
    cutoff, effective = context.cutoff(domain), utc(context.effective_at)
    by_group: dict[Group, list[PointMeasurement]] = defaultdict(list)
    for reading in selection.of(PointMeasurement):
        # A point counts once both its observation and its original sample have ended.
        if reading.metric == metric and utc(reading.observed_at) <= cutoff \
                and utc(reading.metadata.sample_end_at) <= cutoff:
            by_group[group_of(settings, reading.metadata)].append(reading)

    day, conflicted = context.day, selection.conflict_days(domain)
    window = [h for h in history_days(day, settings.baseline.window_days) if h not in conflicted]

    def reading(group: Group, when: date) -> PointMeasurement | None:
        return daily_reading(by_group[group], when, primaries.get(when))

    groups = sorted(by_group)
    current_group = None if day in conflicted else next((g for g in groups if reading(g, day)), None)
    group = current_group or next((g for g in groups if any(reading(g, h) for h in window)), None)
    history = {h: reading(group, h) for h in window} if group else {}
    values = [r.value for r in history.values() if r]
    ready = len(values) >= settings.baseline.minimum_valid_days

    fields: dict = {"baseline_status": "ready" if ready else "calibrating", "usable_days": len(values),
                    "required_days": settings.baseline.minimum_valid_days}
    outcome = Outcome(fields=fields, evidence={
        "selected_group": group.id if group else None,
        "baseline_record_ids": sorted(r.source_record_id for r in history.values() if r),
        "rule": "latest in primary sleep, else first after waking, else first of day",
    })
    if day in conflicted:
        outcome.diagnostics.append(f"{domain}_conflict:{day}")
    if ready:
        center, mad = median_mad(values)
        fields.update(baseline=center, mad=mad)
    current = reading(current_group, day) if current_group else None
    if current is None:
        fields["state"] = "missing" if ready else "calibrating"
        return outcome
    fields.update(value=current.value, observed_at=current.observed_at,
                  source_record_id=current.source_record_id, source_name=current.metadata.source_name)
    outcome.present, outcome.weight = True, current_group.weight
    outcome.age_hours = (effective - utc(current.observed_at)).total_seconds() / 3600
    if not ready:
        fields["state"] = "calibrating"
        return outcome
    z = robust_z(current.value, fields["baseline"], fields["mad"], rules.scale_floor)
    fields.update(robust_z=z, state=classify(z, rules))
    outcome.evidence["scale"] = max(ROBUST_SCALE * fields["mad"], rules.scale_floor)
    return outcome
