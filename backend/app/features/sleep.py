"""Sleep episodes, primary-sleep selection and the sleep baseline (plan §5).

Duration is the union of asleep stages minus any overlapping awake time of the
same source, never end - start. In-bed records describe an episode but can't
create sleep or bridge two episodes.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from statistics import median
from zoneinfo import ZoneInfo

from app.config import Settings
from app.contracts._types import utc
from app.contracts.canonical_events import IntervalEvent
from app.features.models import CalculationContext, Outcome, history_days
from app.features.selection import Group, Selection, group_of, local_date

Span = tuple[datetime, datetime]


def union(spans) -> list[Span]:
    merged: list[Span] = []
    for start, end in sorted(spans):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
        else:
            merged.append((start, end))
    return merged


def subtract(spans: list[Span], cuts: list[Span]) -> list[Span]:
    result = []
    for start, end in spans:
        pieces = [(start, end)]
        for cut_start, cut_end in cuts:
            pieces = [piece for s, e in pieces for piece in ((s, min(e, cut_start)), (max(s, cut_end), e)) if piece[0] < piece[1]]
        result.extend(pieces)
    return result


def clip(spans: list[Span], start: datetime, end: datetime) -> list[Span]:
    return [(max(s, start), min(e, end)) for s, e in spans if min(e, end) > max(s, start)]


def minutes(spans) -> float:
    return sum((end - start).total_seconds() for start, end in spans) / 60


def _span(event: IntervalEvent) -> Span:
    return (utc(event.start_at), utc(event.end_at))


@dataclass(frozen=True)
class Episode:
    group: Group
    timezone: str
    start: datetime  # first retained asleep instant (UTC)
    end: datetime    # last retained asleep instant (UTC)
    asleep_minutes: float
    awake_minutes: float | None
    in_bed_minutes: float | None
    contradiction_minutes: float
    record_ids: tuple[str, ...]
    bundle_ids: tuple[str, ...]

    @property
    def wake_day(self) -> date:
        return local_date(self.end, self.timezone)


def build_episodes(intervals: list[IntervalEvent], settings: Settings) -> list[Episode]:
    gap = timedelta(minutes=settings.sleep.episode_gap_minutes)
    by_source = defaultdict(list)
    for event in intervals:
        by_source[(group_of(settings, event.metadata), event.metadata.timezone)].append(event)

    episodes = []
    for (group, zone), members in sorted(by_source.items()):
        stages = sorted((e for e in members if e.value != "in_bed"), key=lambda e: (_span(e), e.source_record_id))
        clusters: list[list[IntervalEvent]] = []
        cluster_end = None
        for event in stages:
            start, end = _span(event)
            if clusters and start - cluster_end <= gap:
                clusters[-1].append(event)
                cluster_end = max(cluster_end, end)
            else:
                clusters.append([event])
                cluster_end = end
        drafts = []
        for cluster in clusters:
            asleep = union(_span(e) for e in cluster if e.value.startswith("asleep_"))
            awake = union(_span(e) for e in cluster if e.value == "awake")
            net = subtract(asleep, awake)  # contradictory time is never sleep
            if not net:
                continue
            start, end = net[0][0], net[-1][1]
            has_awake = any(e.value == "awake" for e in cluster)
            drafts.append({
                "start": start, "end": end, "asleep": minutes(net),
                "awake": minutes(clip(awake, start, end)) if has_awake else None,
                "contradiction": minutes(asleep) - minutes(net), "records": cluster, "in_bed": [],
            })
        # Each in-bed record belongs to the one episode it overlaps most.
        for record in sorted((e for e in members if e.value == "in_bed"), key=_span):
            start, end = _span(record)
            overlaps = [(min(end, d["end"]) - max(start, d["start"]), -index) for index, d in enumerate(drafts)]
            best = max(overlaps, default=None)
            if best and best[0] > timedelta(0):
                drafts[-best[1]]["in_bed"].append(record)
        for d in drafts:
            records = d["records"] + d["in_bed"]
            episodes.append(Episode(
                group=group, timezone=zone, start=d["start"], end=d["end"], asleep_minutes=d["asleep"],
                awake_minutes=d["awake"],
                in_bed_minutes=minutes(union(_span(e) for e in d["in_bed"])) if d["in_bed"] else None,
                contradiction_minutes=d["contradiction"],
                record_ids=tuple(sorted(e.source_record_id for e in records)),
                bundle_ids=tuple(sorted({e.metadata.source_bundle_id for e in records})),
            ))
    return episodes


def in_overnight_window(episode: Episode, settings: Settings) -> bool:
    # Boundaries use zoneinfo's fold=0 mapping; a nonexistent boundary maps to
    # the DST transition instant.
    zone, day = ZoneInfo(episode.timezone), episode.wake_day
    start = utc(datetime.combine(day - timedelta(days=1), settings.sleep.overnight_start, zone))
    end = utc(datetime.combine(day, settings.sleep.overnight_end, zone))
    return episode.start < end and episode.end > start


def primary(episodes: list[Episode], day: date, settings: Settings, group: Group | None = None) -> Episode | None:
    """The longest overnight episode waking on `day`, from `group` or else
    from the highest-priority group that has one."""
    candidates = [e for e in episodes if e.wake_day == day and in_overnight_window(e, settings)]
    if group is None and candidates:
        group = min(e.group for e in candidates)
    candidates = [e for e in candidates if e.group == group]
    if not candidates:
        return None
    return min(candidates, key=lambda e: (-e.asleep_minutes, -e.end.timestamp(), e.record_ids))


def eligible_episodes(selection: Selection, context: CalculationContext, settings: Settings) -> list[Episode]:
    cutoff = context.cutoff("sleep")
    intervals = [e for e in selection.of(IntervalEvent) if utc(e.end_at) <= cutoff]
    conflicted = selection.conflict_days("sleep")
    return [e for e in build_episodes(intervals, settings) if e.wake_day not in conflicted]


def calculate(episodes: list[Episode], selection: Selection, context: CalculationContext,
              settings: Settings) -> Outcome:
    day, rules = context.day, settings.sleep
    window = history_days(day, settings.baseline.window_days)
    current = primary(episodes, day, settings)
    group = current.group if current else min(
        (e.group for e in episodes if e.wake_day in window and in_overnight_window(e, settings)), default=None)
    history = {h: primary(episodes, h, settings, group) for h in window} if group else {}
    values = [e.asleep_minutes / 60 for e in history.values() if e]
    ready = len(values) >= settings.baseline.minimum_valid_days
    fields: dict = {"baseline_status": "ready" if ready else "calibrating", "usable_days": len(values),
                    "required_days": settings.baseline.minimum_valid_days}
    outcome = Outcome(fields=fields, evidence={
        "selected_group": group.id if group else None,
        "baseline_days": sorted(h.isoformat() for h, e in history.items() if e),
        "naps": [{"start": e.start, "end": e.end, "asleep_minutes": e.asleep_minutes, "group": e.group.id}
                 for e in episodes if e.wake_day == day and e is not current],
    })
    if day in selection.conflict_days("sleep"):
        outcome.diagnostics.append(f"sleep_conflict:{day}")
    if ready:
        baseline = median(values)
        fields.update(baseline_hours=baseline, baseline_mad_hours=median(abs(v - baseline) for v in values))
    if current is None:
        fields["state"] = "missing" if ready else "calibrating"
        return outcome
    hours = current.asleep_minutes / 60
    fields.update(
        hours=hours, sleep_start=current.start, sleep_end=current.end,
        span_hours=(current.end - current.start).total_seconds() / 3600,
        in_bed_hours=None if current.in_bed_minutes is None else current.in_bed_minutes / 60,
        awake_minutes=current.awake_minutes, timezone=current.timezone, source=current.group.id,
        source_policy_version=rules.source_policy_version,
    )
    outcome.evidence.update(record_ids=list(current.record_ids), selected_source_bundle_ids=list(current.bundle_ids),
                            timezone=current.timezone, contradiction_minutes=current.contradiction_minutes)
    if current.contradiction_minutes:
        outcome.diagnostics.append(f"sleep_awake_overlap_minutes:{current.contradiction_minutes:g}")
    if current.timezone != context.timezone:
        outcome.diagnostics.append(f"sleep_timezone:{current.timezone}")
    outcome.present, outcome.weight = True, current.group.weight
    outcome.age_hours = (utc(context.effective_at) - current.end).total_seconds() / 3600
    if not ready:
        fields["state"] = "calibrating"
        return outcome
    delta_minutes = (hours - fields["baseline_hours"]) * 60
    fields.update(delta_hours=hours - fields["baseline_hours"], ratio=hours / fields["baseline_hours"],
                  state="below_baseline" if delta_minutes <= -rules.below_minutes
                  else "above_baseline" if delta_minutes >= rules.above_minutes else "typical")
    return outcome
