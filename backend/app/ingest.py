"""Upload ingestion (Step 6-8 plan section 5): request idempotency, per-event
classification, revisions and the durable recalculation job.

Everything here runs in the caller's single transaction, with the user row
locked for its duration.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from typing import Any, Literal
from uuid import UUID

from pydantic import AwareDatetime, Field, ValidationError, model_validator
from sqlalchemy.engine import Connection

from app import store
from app.contracts._types import Frozen, IanaTimezone, utc
from app.contracts.canonical_events import (
    HEALTHKIT_TYPES,
    DailyActivitySnapshot,
    DeleteEvent,
    IntervalEvent,
    PointMeasurement,
    WorkoutEvent,
)
from app.features.models import CoverageWindow, Domain
from app.features.selection import local_date

MAX_EVENTS = 500
RECALC_WINDOW_DAYS = 35


class CoverageIn(Frozen):
    """A client coverage declaration; the server assigns its revision. Either
    whole local days, or an exact UTC interval ending when the query finished
    (a partial day, Step 9-13 plan section 3A)."""

    domain: Domain
    timezone: IanaTimezone
    status: Literal["complete", "unavailable"]
    start_day: date | None = None
    end_day: date | None = None
    start_at: AwareDatetime | None = None
    end_at: AwareDatetime | None = None

    @model_validator(mode="after")
    def _one_form(self) -> CoverageIn:
        CoverageWindow(**self.model_dump())  # the calculator's own rules
        return self

    def first_day(self, zone: str) -> date:
        return self.start_day if self.start_day is not None else local_date(self.start_at, zone)


MAX_SCAN_MEMBERS = 100_000


class VisibilityIn(Frozen):
    """A completed fresh scan of one HealthKit type: every visible record ID
    from scope_start_at on (Step 9-13 plan section 3B). Sent once all of the
    scan's pages are stored on the device."""

    scan_id: UUID
    healthkit_type: Literal[tuple(HEALTHKIT_TYPES.values())]  # type: ignore[valid-type]
    scope_start_at: AwareDatetime
    scope_end_at: AwareDatetime | None = None
    members: list[str] = Field(max_length=MAX_SCAN_MEMBERS)

    @model_validator(mode="after")
    def _unique(self) -> VisibilityIn:
        if self.scope_end_at is not None and utc(self.scope_end_at) <= utc(self.scope_start_at):
            raise ValueError("scan interval is reversed")
        if len(set(self.members)) != len(self.members):
            raise ValueError("scan members must be unique")
        return self


class SyncRequest(Frozen):
    request_id: UUID
    installation_id: UUID | None = None
    device_timezone: IanaTimezone
    coverage: tuple[CoverageIn, ...] = ()
    visibility: tuple[VisibilityIn, ...] = ()
    # Validated one by one, so one bad event never rejects the others.
    events: list[Any] = Field(max_length=MAX_EVENTS)

    @model_validator(mode="after")
    def _finalization(self):
        if self.installation_id and self.visibility:
            if self.events:
                raise ValueError("visibility finalization must follow event acknowledgements")
            if any(scan.scope_end_at is None for scan in self.visibility):
                raise ValueError("installation scans require scope_end_at")
            if len({scan.healthkit_type for scan in self.visibility}) != len(self.visibility):
                raise ValueError("one scan per type per finalization")
        return self


class RequestIdReused(Exception):
    """The same request_id arrived with a different body (HTTP 409)."""


@dataclass
class IngestResult:
    response: dict
    revision: int | None
    replayed: bool = False
    counts: dict = field(default_factory=dict)
    event_types: list[str] = field(default_factory=list)


def rejection_code(error: ValidationError) -> str:
    text = str(error)
    if "INVALID_UNIT" in text:
        return "INVALID_UNIT"
    if any(entry["loc"][-1:] == ("metric",) for entry in error.errors()):
        return "UNKNOWN_METRIC"
    return "INVALID_EVENT_SCHEMA"


def _readable_event_id(raw: Any) -> UUID | None:
    try:
        return UUID(str(raw["event_id"]))
    except (TypeError, KeyError, ValueError):
        return None


def _raw_sha256(raw: Any) -> str:
    return hashlib.sha256(json.dumps(raw, sort_keys=True, separators=(",", ":"), default=str).encode()).hexdigest()


def _event_days(conn: Connection, user_id: UUID, event, zone: str, received_at: datetime) -> list[date]:
    if isinstance(event, PointMeasurement):
        return [local_date(event.observed_at, zone)]
    if isinstance(event, (IntervalEvent, WorkoutEvent)):
        return [local_date(event.start_at, zone)]
    if isinstance(event, DailyActivitySnapshot):
        return [event.day]
    return store.version_days(conn, user_id, event.source, event.source_record_id, zone) \
        or [local_date(received_at, zone)]


def ingest(conn: Connection, user_id: UUID, body: bytes, request: SyncRequest, now: datetime) -> IngestResult:
    body_hash = store.body_sha256(body)
    store.ensure_user(conn, user_id, request.device_timezone)
    stored_zone = store.lock_user_row(conn, user_id).timezone  # serializes ingestion for this user
    previous = store.find_request(conn, user_id, request.request_id)
    if previous is not None:
        if previous.body_sha256 != body_hash:
            raise RequestIdReused()
        return IngestResult(response=previous.response, revision=previous.revision, replayed=True,
                            counts=previous.status_counts)

    zone = request.device_timezone
    revision: int | None = None
    received_at = utc(now)
    affected: set[date] = set()
    results, types = [], []

    def allocate() -> None:
        nonlocal revision, received_at
        if revision is None:
            revision, received_at = store.next_revision(conn, user_id, now)

    def observe(event) -> None:
        """Record that this installation sees the provider record. Only new
        memberships get a revision, and they only need recalculation where a
        visibility scan could have withdrawn the record."""
        if not request.installation_id or isinstance(event, DeleteEvent) \
                or store.installation_seen(conn, user_id, request.installation_id, event):
            return
        allocate()
        store.record_installation(conn, user_id, request.installation_id, event, revision)
        if not isinstance(event, DailyActivitySnapshot) \
                and store.has_scans(conn, user_id, event.metadata.healthkit_type):
            affected.update(_event_days(conn, user_id, event, zone, received_at))

    for index, raw in enumerate(request.events):
        event_id = _readable_event_id(raw)
        try:
            event = store.EVENTS.validate_python(raw)
        except ValidationError as error:
            outcome, code, digest = "rejected", rejection_code(error), _raw_sha256(raw)
            event = None
        else:
            digest = store.content_sha256(event)
            types.append(event.event_type)

        receipt = store.find_receipt(conn, user_id, event_id) if event_id else None
        if receipt is not None:
            if receipt.payload_sha256 == digest:  # a retry: report what was recorded
                outcome, code = receipt.outcome, receipt.code
                if event is not None and receipt.health_event_id:
                    observe(event)
            else:
                outcome, code = "rejected", "CLIENT_EVENT_ID_REUSED"
            results.append({"index": index, "client_event_id": str(event_id), "status": outcome,
                            **({"code": code} if code else {}), "retryable": False})
            continue

        version_id = None
        if event is not None:
            key = store.identity(event)
            existing = (store.find_tombstone(conn, user_id, event.source, event.source_record_id)
                        if isinstance(event, DeleteEvent) else store.find_version(conn, user_id, key, digest))
            if existing is not None:
                outcome, code, version_id = "duplicate", None, existing
            else:
                conflict = not isinstance(event, DeleteEvent) and store.identity_exists(conn, user_id, key)
                allocate()
                version_id = store.insert_version(conn, user_id, event, digest, revision, received_at)
                affected.update(_event_days(conn, user_id, event, zone, received_at))
                outcome, code = ("conflict", "CONFLICTING_PROVIDER_RECORD") if conflict else ("accepted", None)
        if version_id is not None:
            observe(event)
        if event_id is not None:
            store.save_receipt(conn, user_id, event_id, digest, request.request_id, received_at, outcome, code,
                               version_id)
        results.append({"index": index, "client_event_id": str(event_id) if event_id else None, "status": outcome,
                        **({"code": code} if code else {}), "retryable": False})

    if request.coverage:
        allocate()
        store.insert_coverage(conn, user_id, [CoverageWindow(**c.model_dump()) for c in request.coverage],
                              revision, received_at)
        affected.update(c.first_day(zone) for c in request.coverage)

    if request.visibility:
        allocate()
        if store.insert_scans(conn, user_id, [v.model_dump() for v in request.visibility], revision, received_at, request.installation_id):
            # A scan can withdraw anything in its scope; recalculate from its start.
            affected.update(local_date(v.scope_start_at, zone) for v in request.visibility)

    today = local_date(now, zone)
    if zone != stored_zone:
        # A timezone-only change is still a change: "today" moves (Step 9-13 plan).
        allocate()
        affected.add(today)
    window_start = today - timedelta(days=RECALC_WINDOW_DAYS)
    if revision is not None:
        store.set_timezone(conn, user_id, zone)
        store.enqueue_job(conn, user_id, "sync", revision, max(min(affected, default=today), window_start), now)
    counts = {status: sum(r["status"] == status for r in results)
              for status in ("accepted", "duplicate", "conflict", "rejected")}
    response = {
        "request_id": str(request.request_id), "revision": revision, "results": results,
        "affected_days": sorted(d.isoformat() for d in affected),
        "days_beyond_recalc_window": sum(d < window_start for d in affected),
    }
    store.save_request(conn, user_id, request.request_id, body_hash, revision, received_at, counts, response)
    return IngestResult(response=response, revision=revision, counts=counts, event_types=sorted(set(types)))
