"""Pure v2 identity, correction and conservative selection rules.

Transport attempts, installation IDs, API keys and arrival order are deliberately
absent from identity. They belong to delivery receipts and connection state.
This module cannot change v1 replay or accept a second source over HTTP.
"""
from __future__ import annotations

import hashlib
import json
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from uuid import UUID


class Metric(StrEnum):
    STEPS = "steps"
    SLEEP_STAGE = "sleep_stage"
    SLEEP_SUMMARY = "sleep_summary"
    WORKOUT = "workout"
    HRV_SDNN = "hrv_sdnn"
    HRV_RMSSD = "hrv_rmssd"
    RESTING_HEART_RATE = "resting_heart_rate"


@dataclass(frozen=True, order=True)
class Namespace:
    user_id: UUID
    provider: str
    provider_account: str
    store: str

    def __post_init__(self):
        if not all((self.provider, self.provider_account, self.store)):
            raise ValueError("A verified provider account and store are required")


@dataclass(frozen=True, order=True)
class RecordKey:
    namespace: Namespace
    metric: Metric
    record_id: str

    def __post_init__(self):
        if not self.record_id:
            raise ValueError("Provider record ID is required")


@dataclass(frozen=True, order=True)
class SeriesKey:
    namespace: Namespace
    metric: Metric
    method: str
    resolution: str

    def __post_init__(self):
        if not self.method or not self.resolution:
            raise ValueError("Unknown methods must be named explicitly, never inferred")


def content_hash(payload: dict) -> str:
    """Call with normalized provider content, excluding transport receipt IDs."""
    body = json.dumps(payload, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return hashlib.sha256(body.encode()).hexdigest()


@dataclass(frozen=True)
class Version:
    key: RecordKey
    series: SeriesKey
    payload_hash: str
    # Only a provider's documented monotonic version, never HTTP arrival time.
    provider_revision: int | None = None
    deleted: bool = False

    def __post_init__(self):
        if self.key.namespace != self.series.namespace or self.key.metric != self.series.metric:
            raise ValueError("Record and series must share provider namespace and metric")
        if self.provider_revision is not None and self.provider_revision < 0:
            raise ValueError("Negative provider revision")


@dataclass(frozen=True)
class Resolution:
    selected: tuple[Version, ...]
    conflicts: frozenset[RecordKey]
    deleted: frozenset[RecordKey]


def resolve_versions(versions: list[Version]) -> Resolution:
    """Idempotent under repeated deliveries and invariant to arrival order.

    Without authoritative ordering, differing versions remain conflicted. A
    delete affects exactly one namespaced record, not independently visible
    mirrors. Equal-authority contradictions are never resolved by receipt time.
    """
    groups = defaultdict(set)
    for version in versions:
        groups[version.key].add(version)
    selected, conflicts, deleted = [], set(), set()
    for key, records in sorted(groups.items()):
        if all(v.provider_revision is not None for v in records):
            revision = max(v.provider_revision for v in records)
            records = {v for v in records if v.provider_revision == revision}
        signatures = {(v.payload_hash, v.deleted, v.series) for v in records}
        if len(signatures) != 1:
            conflicts.add(key)
        elif next(iter(records)).deleted:
            deleted.add(key)
        else:
            # A deterministic representative, including providers that add a
            # revision without changing their content.
            selected.append(max(records, key=lambda v: v.provider_revision if v.provider_revision is not None else -1))
    return Resolution(tuple(selected), frozenset(conflicts), frozenset(deleted))


@dataclass(frozen=True)
class VerifiedOrigin:
    """An adapter-validated upstream identity, not a similarity fingerprint.

    Adapters must validate ownership and upstream semantics before constructing
    this internal object. It is not accepted from a user-facing JSON field.
    """
    user_id: UUID
    upstream_provider: str
    upstream_account: str
    upstream_record_id: str
    metric: Metric


def mirror_groups(records: list[RecordKey], evidence: dict[RecordKey, VerifiedOrigin]) -> tuple[tuple[RecordKey, ...], ...]:
    groups = defaultdict(list)
    for key in sorted(set(records)):
        origin = evidence.get(key)
        if origin is not None and (origin.user_id != key.namespace.user_id or origin.metric != key.metric):
            raise ValueError("Mirror evidence crosses an account or metric")
        # Exact equality only: no fuzzy or transitive similarity union.
        groups[("origin", origin) if origin else ("record", key)].append(key)
    return tuple(tuple(group) for group in groups.values())


@dataclass(frozen=True)
class Candidate:
    version: Version
    observed_at: datetime
    # Cumulative snapshots need an observation cutoff, not additive summation.
    value: float | None = None


def select_stream(candidates: list[Candidate], *, metric: Metric, cutoff: datetime,
                  priority: tuple[SeriesKey, ...]) -> tuple[Candidate, ...]:
    """Conservative fallback for ambiguous overlap: one configured series.

    Pass candidates for one calculation day/episode. For steps return one latest
    cumulative snapshot, never the sum of source totals. For other metrics keep
    the authoritative stream's distinct records; sleep interval union remains a
    feature-calculation responsibility. Methods are part of the series identity.
    """
    if cutoff.tzinfo is None:
        raise ValueError("A timezone-aware cutoff is required")
    eligible = [c for c in candidates if c.version.key.metric == metric and c.observed_at <= cutoff
                and not c.version.deleted]
    resolved = resolve_versions([c.version for c in eligible])
    accepted = set(resolved.selected)
    eligible = [c for c in eligible if c.version in accepted]
    for series in priority:
        matches = list(set(c for c in eligible if c.version.series == series))
        if not matches:
            continue
        matches.sort(key=lambda c: (c.observed_at, c.version.key))
        if metric == Metric.STEPS:
            latest = [c for c in matches if c.observed_at == matches[-1].observed_at]
            # Equal cutoff contradictory totals need an explicit provider
            # correction; record-ID sorting must not choose a number.
            return (latest[0],) if len({c.value for c in latest}) == 1 else ()
        return tuple(matches)
    return ()


@dataclass(frozen=True)
class Coverage:
    series: SeriesKey
    start: datetime
    end: datetime
    complete: bool

    def __post_init__(self):
        if self.start.tzinfo is None or self.end.tzinfo is None or self.start >= self.end:
            raise ValueError("Coverage must be a nonempty aware interval")


def usable_through(coverage: list[Coverage], selected_series: tuple[SeriesKey, ...],
                   requested_start: datetime, requested_end: datetime) -> datetime | None:
    """Only selected compatible streams constrain a common cutoff.

    Gaps, revoked access and partial scans cannot claim complete visibility or
    imply deletion. Each selected stream must cover from the requested start.
    """
    if not selected_series:
        return None
    ends = []
    for series in selected_series:
        cursor = requested_start
        for window in sorted((w for w in coverage if w.series == series and w.complete), key=lambda w: w.start):
            if window.start > cursor:
                break
            cursor = max(cursor, window.end)
        if cursor <= requested_start:
            return None
        ends.append(min(cursor, requested_end))
    return min(ends)
