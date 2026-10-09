"""Completed-workout recency and totals (plan §8).

Overlapping workouts (e.g. the watch and a third-party app recording the same
session) are split into disjoint time segments; each segment goes to the
highest-priority source, then the latest end, then provider ID. A workout's
active duration is spread over its wall time proportionally (pause locations
are unknown), so a workout crossing midnight contributes to both days.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from app.config import Settings
from app.contracts._types import local_day_start, utc
from app.contracts.canonical_events import WorkoutEvent
from app.features.models import CalculationContext, Outcome
from app.features.selection import Selection, group_of, local_date


def segments(workouts: list[WorkoutEvent], settings: Settings) -> list[tuple[datetime, datetime, WorkoutEvent]]:
    bounds = sorted({utc(w.start_at) for w in workouts} | {utc(w.end_at) for w in workouts})
    result = []
    for start, end in zip(bounds, bounds[1:]):
        covering = [w for w in workouts if utc(w.start_at) <= start and utc(w.end_at) >= end]
        if covering:
            winner = min(covering, key=lambda w: (group_of(settings, w.metadata), -utc(w.end_at).timestamp(),
                                                   w.source_record_id))
            result.append((start, end, winner))
    return result


def active_minutes(pieces, window_start: datetime, window_end: datetime) -> float:
    total = 0.0
    for start, end, workout in pieces:
        overlap = (min(end, window_end) - max(start, window_start)).total_seconds() / 60
        if overlap > 0:
            wall = (utc(workout.end_at) - utc(workout.start_at)).total_seconds() / 60
            total += overlap * min(workout.duration_minutes / wall, 1.0)
    return total


def calculate(selection: Selection, context: CalculationContext, settings: Settings) -> Outcome:
    rules, day = settings.workout, context.day
    effective = utc(context.effective_at)
    outcome = Outcome(fields={}, evidence={})
    first_day = min(day - timedelta(days=rules.totals_days - 1),
                    local_date(effective - timedelta(hours=rules.recent_hours), context.timezone))
    conflicted = selection.conflict_days("workout")
    if conflicted:
        outcome.diagnostics.extend(f"workout_conflict:{d}" for d in sorted(conflicted))
    if conflicted or not context.covered("workout", first_day, day):
        # Unknown history is not a confirmed absence.
        outcome.fields["state"] = "missing"
        outcome.evidence["required_coverage"] = [first_day.isoformat(), day.isoformat()]
        return outcome

    cutoff = context.cutoff("workout")
    workouts = [w for w in selection.of(WorkoutEvent) if utc(w.end_at) <= cutoff]
    pieces = segments(workouts, settings)
    today = active_minutes(pieces, local_day_start(day, context.timezone), effective)
    week_start = local_day_start(day - timedelta(days=rules.totals_days - 1), context.timezone)
    outcome.fields.update(workout_minutes_today=today, workout_minutes_last_7d=active_minutes(pieces, week_start, effective))
    outcome.present = True
    winners = {id(w): w for _, _, w in pieces}.values()  # the last workout must win some time
    last = max(winners, key=lambda w: (utc(w.end_at), w.source_record_id), default=None)
    if last is None:
        outcome.fields["state"] = "none_recent"
        return outcome
    hours_since = (effective - utc(last.end_at)).total_seconds() / 3600
    outcome.fields.update(
        type=last.workout_type, last_workout_start=last.start_at, last_workout_end=last.end_at,
        source_record_id=last.source_record_id, source_name=last.metadata.source_name, hours_since=hours_since,
        state="just_completed" if hours_since <= rules.just_completed_hours
        else "recent_workout" if hours_since <= rules.recent_hours else "none_recent",
    )
    outcome.evidence["excluded_overlaps"] = sorted(
        w.source_record_id for w in workouts if id(w) not in {id(x) for x in winners})
    return outcome
