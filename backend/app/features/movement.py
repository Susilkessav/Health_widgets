"""Step pacing against the usual total by the same local time (plan §7).

Comparison position is local wall-clock minutes within a snapshot's own day
(1440 for its closing boundary), so 13:00 compares with 13:00 across DST and
across timezones: a trip doesn't reset movement history. The adapter must
supply regular (hourly) historical buckets; sparse on-demand reads leave most
days without a comparable bucket.
"""
from __future__ import annotations

from collections import defaultdict
from datetime import date, timedelta
from statistics import median
from zoneinfo import ZoneInfo

from app.config import Settings
from app.contracts._types import local_day_start, utc
from app.contracts.canonical_events import DailyActivitySnapshot, SnapshotConflictError, resolve_snapshot_bucket
from app.features.models import CalculationContext, Outcome, history_days
from app.features.selection import Selection


def wall_minutes(snapshot: DailyActivitySnapshot) -> float:
    if utc(snapshot.as_of) == local_day_start(snapshot.day + timedelta(days=1), snapshot.timezone):
        return 1440.0
    local = utc(snapshot.as_of).astimezone(ZoneInfo(snapshot.timezone))
    return local.hour * 60 + local.minute + local.second / 60


def _buckets(snapshots: list[DailyActivitySnapshot]) -> dict[tuple, list[DailyActivitySnapshot]]:
    buckets = defaultdict(list)
    for snapshot in snapshots:
        buckets[snapshot.bucket].append(snapshot)
    return buckets


def _order(report_zone: str):
    # Latest position first; equal positions prefer the report zone, then zone name.
    def key(item):
        (zone, _, as_of), reads = item
        return (-wall_minutes(reads[0]), -as_of.timestamp(), zone != report_zone, zone)
    return key


def calculate(selection: Selection, context: CalculationContext, settings: Settings) -> Outcome:
    effective, known, day = utc(context.effective_at), utc(context.known_at), context.day
    snapshots = [s for s in selection.of(DailyActivitySnapshot)
                 if utc(s.as_of) <= effective and utc(s.queried_at) <= known]
    by_day: dict[date, list[DailyActivitySnapshot]] = defaultdict(list)
    for snapshot in snapshots:
        by_day[snapshot.day].append(snapshot)

    rules, required = settings.movement, settings.baseline.minimum_valid_days
    outcome = Outcome(fields={"required_days": required}, evidence={})
    current_buckets = sorted(_buckets(by_day[day]).items(), key=_order(context.timezone))
    current = None
    if current_buckets:
        (zone, _, _), reads = current_buckets[0]
        target = wall_minutes(reads[0])
        outcome.evidence.update(timezone=zone, target_wall_minutes=target)
        try:
            current = resolve_snapshot_bucket(reads)  # never falls back to an older bucket
        except SnapshotConflictError:
            outcome.diagnostics.append(f"movement_conflict:{day}")
    else:
        local = effective.astimezone(ZoneInfo(context.timezone))
        target = 1440.0 if local.date() > day else local.hour * 60 + local.minute + local.second / 60
        outcome.evidence.update(timezone=context.timezone, target_wall_minutes=target)

    values, used = [], []
    for when in history_days(day, settings.baseline.window_days):
        comparable = [(key, reads) for key, reads in _buckets(by_day[when]).items()
                      if target - rules.comparison_window_minutes <= wall_minutes(reads[0]) <= target]
        if not comparable:
            continue
        _, reads = min(comparable, key=_order(context.timezone))
        try:
            chosen = resolve_snapshot_bucket(reads)
        except SnapshotConflictError:
            outcome.diagnostics.append(f"movement_history_conflict:{when}")
            continue  # a conflicted latest bucket invalidates that day
        values.append(chosen.steps)
        used.append(chosen.source_record_id)

    ready = len(values) >= required
    outcome.fields.update(baseline_status="ready" if ready else "calibrating", usable_days=len(values))
    outcome.evidence["baseline_record_ids"] = used
    if ready:
        outcome.fields["expected_steps_now"] = float(median(values))
    if current is None:
        outcome.fields["state"] = "missing" if ready else "calibrating"
        return outcome
    outcome.fields.update(steps=current.steps, as_of=current.as_of, source_record_id=current.source_record_id)
    outcome.present = True
    outcome.age_hours = (effective - utc(current.as_of)).total_seconds() / 3600
    if not ready:
        outcome.fields["state"] = "calibrating"
        return outcome
    expected = outcome.fields["expected_steps_now"]
    if expected == 0:  # ratio undefined; nothing was expected yet
        outcome.fields["state"] = "typical"
        return outcome
    ratio = current.steps / expected
    outcome.fields.update(ratio=ratio, state="behind_usual" if ratio < rules.behind_ratio
                          else "ahead_of_usual" if ratio > rules.ahead_ratio else "typical")
    return outcome
