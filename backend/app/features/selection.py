"""What a calculation may see, and whose data it is.

Order (Step 3 plan §4): deliveries by known_at -> exact retries collapse by
client ID -> provider records compared by (source, source_record_id,
event_type) excluding client ID -> conflicting provider records are
quarantined -> visible tombstones remove their provider IDs, whenever the
original arrives. Effective-time cutoffs are applied per domain.
"""
from __future__ import annotations

import hashlib
import json
from collections import defaultdict
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import date, datetime
from zoneinfo import ZoneInfo

from app.config import Settings
from app.contracts._types import json_value, utc
from app.contracts.canonical_events import (
    CanonicalEvent,
    DailyActivitySnapshot,
    DeleteEvent,
    IntervalEvent,
    PointMeasurement,
    SampleMetadata,
    WorkoutEvent,
)
from app.features.models import CalculationContext, CalculationInputError, Observation


@dataclass(frozen=True, order=True)
class Group:
    """A source group; ordering is priority (configured rank, then id)."""

    rank: int
    id: str
    weight: float = field(default=1.0, compare=False)


def group_of(settings: Settings, metadata: SampleMetadata) -> Group:
    for rank, group in enumerate(settings.source_groups):
        if group.matches(metadata.source_bundle_id, metadata.device_product_type):
            return Group(rank, group.id, group.weight)
    device = metadata.device_product_type or "unknown-device"
    return Group(len(settings.source_groups), f"unknown:{metadata.source_bundle_id}|{device}")


def local_date(moment: datetime, zone: str) -> date:
    return utc(moment).astimezone(ZoneInfo(zone)).date()


def domain_of(event: CanonicalEvent) -> str:
    if isinstance(event, PointMeasurement):
        return "hrv" if event.metric == "hrv_sdnn_ms" else "rhr"
    if isinstance(event, IntervalEvent):
        return "sleep"
    if isinstance(event, WorkoutEvent):
        return "workout"
    return "movement"


def record_day(event: CanonicalEvent) -> date:
    if isinstance(event, DailyActivitySnapshot):
        return event.day
    moment = event.observed_at if isinstance(event, PointMeasurement) else event.end_at
    return local_date(moment, event.metadata.timezone)


def _canonical(event: CanonicalEvent, with_id: bool) -> str:
    data = json_value(event)
    if not with_id:
        del data["event_id"]
    if "metadata" in data:  # metadata entry order carries no meaning
        data["metadata"]["provider_metadata"].sort(key=lambda entry: entry["key"])
    return json.dumps(data, sort_keys=True, separators=(",", ":"))


@dataclass(frozen=True)
class Conflict:
    domain: str
    day: date
    source_record_id: str


@dataclass(frozen=True)
class Selection:
    records: tuple[CanonicalEvent, ...]
    conflicts: tuple[Conflict, ...]
    tombstoned: tuple[str, ...]
    input_sha256: str
    withdrawn: tuple[str, ...] = ()

    def of(self, kind: type) -> list:
        return [record for record in self.records if isinstance(record, kind)]

    def conflict_days(self, domain: str) -> set[date]:
        return {conflict.day for conflict in self.conflicts if conflict.domain == domain}


def select_visible(observations: Iterable[Observation], context: CalculationContext) -> Selection:
    known = utc(context.known_at)
    by_client: dict = {}
    first_revision: dict[str, int] = {}
    installations: dict[tuple[str, str], dict[str, int]] = defaultdict(dict)
    for observation in observations:
        if utc(observation.delivered_at) > known:
            continue
        event = observation.event
        prior = by_client.get(event.event_id)
        if prior is not None and _canonical(prior, True) != _canonical(event, True):
            raise CalculationInputError(f"client event ID {event.event_id} was reused with different content")
        by_client[event.event_id] = event
        scopes = installations[(event.source, event.source_record_id)]
        for installation, revision in observation.installations:
            scopes[installation] = max(scopes.get(installation, 0), revision)
        first_revision[event.source_record_id] = min(first_revision.get(event.source_record_id, observation.revision),
                                                     observation.revision)
    visible = sorted(by_client.values(), key=lambda event: str(event.event_id))
    hashed: list = [json_value(event) for event in visible]
    if context.visibility:  # absent, the hash is unchanged from before scans existed
        hashed.append(sorted([scan.healthkit_type, utc(scan.scope_start_at).isoformat(), sorted(scan.members),
                              scan.revision, *([str(scan.installation_id)] if scan.installation_id is not None else []),
                              *([utc(scan.scope_end_at).isoformat()] if scan.scope_end_at is not None else [])]
                             for scan in context.visibility))
        if any(scan.installation_id is not None for scan in context.visibility):
            hashed.append(sorted([source, record, sorted(scopes.items())]
                                 for (source, record), scopes in installations.items() if scopes))
    input_sha256 = hashlib.sha256(json.dumps(hashed, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    deleted = {event.source_record_id for event in visible if isinstance(event, DeleteEvent)}
    providers = defaultdict(list)
    for event in visible:
        if not isinstance(event, DeleteEvent):
            providers[(event.source, event.source_record_id, event.event_type)].append(event)

    members = {id(scan): set(scan.members) for scan in context.visibility}
    records, conflicts, tombstoned, withdrawn = [], [], set(), set()
    for (source, record_id, _), versions in sorted(providers.items()):
        if record_id in deleted:
            tombstoned.add(record_id)  # a tombstone wins even over a conflict
            continue
        if _withdrawn(versions[0], first_revision[record_id], context, members, installations[(source, record_id)]):
            withdrawn.add(record_id)
            continue
        if len({_canonical(version, False) for version in versions}) > 1:
            first = versions[0]
            conflicts.append(Conflict(domain_of(first), record_day(first), record_id))
            continue
        # Reimports of the same provider record add no weight; keep one.
        records.append(min(versions, key=lambda version: version.event_id.int))
    return Selection(tuple(records), tuple(conflicts), tuple(sorted(tombstoned)), input_sha256,
                     tuple(sorted(withdrawn)))


def _withdrawn(event: CanonicalEvent, revision: int, context: CalculationContext, members: dict,
               installations: dict[str, int] | None = None) -> bool:
    """A provider record is withdrawn only if every installation that observed
    it has subsequently withdrawn it. Legacy scans govern legacy inputs only.
    Explicit HealthKit tombstones remain global and are handled before this.
    """
    if isinstance(event, DailyActivitySnapshot):
        return False
    scopes = installations or {None: revision}
    for installation, seen_at_revision in scopes.items():
        governing = [scan for scan in context.visibility
                     if (str(scan.installation_id) if scan.installation_id else None) == installation
                     and scan.healthkit_type == event.metadata.healthkit_type
                     and seen_at_revision < scan.revision
                     and utc(event.metadata.sample_end_at) > utc(scan.scope_start_at)
                     and (scan.scope_end_at is None or utc(event.metadata.sample_start_at) < utc(scan.scope_end_at))]
        if not governing or event.source_record_id in members[id(max(governing, key=lambda s: s.revision))]:
            return False
    return True
