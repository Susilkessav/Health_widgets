"""Calculation inputs and the report around DailyFeatures (not a contract change)."""
from __future__ import annotations

from dataclasses import dataclass
from dataclasses import field as dataclass_field
from datetime import date, datetime, timedelta
from typing import Literal
from uuid import UUID

from pydantic import AwareDatetime, Field, JsonValue, model_serializer, model_validator

from app.contracts._types import Frozen, IanaTimezone, Sha256Hex, local_day_start, utc
from app.contracts.canonical_events import CanonicalEvent
from app.contracts.features import DailyFeatures

REPORT_VERSION = "feature-report@0.1.0"
Domain = Literal["sleep", "hrv", "rhr", "movement", "workout"]
DOMAINS: tuple[Domain, ...] = ("sleep", "hrv", "rhr", "movement", "workout")


class CalculationInputError(ValueError):
    """The inputs contradict themselves (e.g. one client event ID, two payloads)."""


class CoverageWindow(Frozen):
    """A declared query result, either for whole local days start_day..end_day
    in `timezone`, or for an exact UTC interval start_at..end_at (a partial
    day: a query finished at 13:00 covers only until 13:00). Production:
    "complete" means the query for that window finished after authorization
    was requested. HealthKit hides denials, so denied access looks like
    complete-and-empty; that is accepted, not inferred away."""

    domain: Domain
    timezone: IanaTimezone
    status: Literal["complete", "unavailable"]
    start_day: date | None = None
    end_day: date | None = None
    start_at: AwareDatetime | None = None
    end_at: AwareDatetime | None = None
    # Upload revision that declared it; later revisions supersede earlier ones.
    revision: int = 0

    @model_validator(mode="after")
    def _one_form(self) -> CoverageWindow:
        days = (self.start_day, self.end_day)
        instants = (self.start_at, self.end_at)
        if all(v is not None for v in days) and all(v is None for v in instants):
            if self.end_day < self.start_day:
                raise ValueError("coverage window is reversed")
        elif all(v is not None for v in instants) and all(v is None for v in days):
            if not utc(self.start_at) < utc(self.end_at):
                raise ValueError("coverage start_at must be before end_at")
        else:
            raise ValueError("coverage needs either start_day and end_day, or start_at and end_at")
        return self

    def span(self) -> tuple[datetime, datetime]:
        """The window's UTC interval. Day form: its first local day's start to
        its last local day's closing boundary, in its own timezone."""
        if self.start_at is not None:
            return utc(self.start_at), utc(self.end_at)
        return (local_day_start(self.start_day, self.timezone),
                local_day_start(self.end_day + timedelta(days=1), self.timezone))


class VisibilityScan(Frozen):
    """A completed fresh scan of one HealthKit type (Step 9-13 plan section 3B).
    It lists every provider record of that type visible from scope_start_at
    on. A record of that type ending after scope_start_at, first received at
    an earlier revision and not listed, is withdrawn: no longer visible to
    this app, which isn't proof of deletion, so it is never a tombstone. The
    newest scan that governs a record decides; a later scan can list it again."""

    installation_id: UUID | None = None
    healthkit_type: str
    scope_start_at: AwareDatetime
    scope_end_at: AwareDatetime | None = None
    # Sorted. Left out of stored reports (they can hold thousands of IDs); the
    # report's input_sha256 covers them.
    members: tuple[str, ...] = Field(exclude=True)
    revision: int

    @model_serializer(mode="wrap")
    def _legacy_scan(self, handler):
        result = handler(self)
        if self.installation_id is None:
            result.pop("installation_id", None)
        if self.scope_end_at is None:
            result.pop("scope_end_at", None)
        return result


class CalculationContext(Frozen):
    day: date
    timezone: IanaTimezone
    effective_at: AwareDatetime
    known_at: AwareDatetime
    coverage: tuple[CoverageWindow, ...] = ()
    visibility: tuple[VisibilityScan, ...] = ()
    # Per-domain import cutoffs (decision D-A). A domain listed here only uses
    # records and coverage up to its own cutoff; ages are still measured at
    # effective_at. Unlisted domains use effective_at, so an empty map is the
    # original single-cutoff calculation.
    cutoffs: dict[Domain, AwareDatetime] = Field(default_factory=dict)

    @model_serializer(mode="wrap")
    def _compatible_context(self, handler):
        result = handler(self)
        if not self.visibility:
            result.pop("visibility", None)  # exact pre-scan report representation
        if not self.cutoffs:
            result.pop("cutoffs", None)  # exact single-cutoff report representation
        return result

    @model_validator(mode="after")
    def _ordered(self) -> CalculationContext:
        if utc(self.known_at) < utc(self.effective_at):
            raise ValueError("known_at cannot precede effective_at")
        if any(utc(at) > utc(self.effective_at) for at in self.cutoffs.values()):
            raise ValueError("a domain cutoff cannot be after effective_at")
        return self

    def cutoff(self, domain: Domain) -> datetime:
        """The latest instant this domain's records and coverage may come from."""
        return utc(self.cutoffs.get(domain, self.effective_at))

    def covered(self, domain: Domain, first: date, last: date) -> bool:
        """Report days first..last (in this context's timezone) are covered when,
        at every instant of their UTC span, the highest-revision declaration
        there is "complete". Later declarations supersede earlier ones; equal
        revisions that disagree count as unavailable; undeclared time is
        unknown, never complete (Step 6-8 plan section 7). Coverage is only
        required up to effective_at: later time can't affect this calculation,
        and a partial-day declaration covers only until its query finished
        (Step 9-13 plan section 3A)."""
        start = local_day_start(first, self.timezone)
        end = min(local_day_start(last + timedelta(days=1), self.timezone), self.cutoff(domain))
        if end <= start:
            return True
        windows = [(w, *w.span()) for w in self.coverage if w.domain == domain]
        windows = [(w, a, b) for w, a, b in windows if a < end and b > start]
        cuts = sorted({start, end} | {t for _, a, b in windows for t in (a, b) if start < t < end})
        for piece_start, piece_end in zip(cuts, cuts[1:]):
            here = [w for w, a, b in windows if a <= piece_start and b >= piece_end]
            if not here:
                return False
            newest = max(w.revision for w in here)
            if any(w.status != "complete" for w in here if w.revision == newest):
                return False
        return True


class Observation(Frozen):
    """One delivery of one canonical event. Retries repeat the event."""

    event: CanonicalEvent
    delivered_at: AwareDatetime
    # The upload revision that delivered it (0 outside the database). Only
    # visibility scans use it, to know which records a scan can withdraw.
    revision: int = 0
    installations: tuple[tuple[str, int], ...] = ()


class CalculationReport(Frozen):
    version: Literal["feature-report@0.1.0"] = REPORT_VERSION
    features: DailyFeatures
    config_sha256: Sha256Hex
    config: dict[str, JsonValue]
    context: CalculationContext
    input_sha256: Sha256Hex
    evidence: dict[str, JsonValue]
    diagnostics: tuple[str, ...] = ()

    @model_validator(mode="after")
    def _consistent(self) -> CalculationReport:
        if self.features.config_sha256 != self.config_sha256:
            raise ValueError("features and report disagree on config_sha256")
        if self.features.day != self.context.day or utc(self.features.effective_at) != utc(self.context.effective_at):
            raise ValueError("features and report disagree on day or effective_at")
        return self


@dataclass
class Outcome:
    """Internal per-domain result, assembled into DailyFeatures by calculate.py."""

    fields: dict
    evidence: dict
    present: bool = False
    age_hours: float | None = None
    weight: float = 1.0
    diagnostics: list[str] = dataclass_field(default_factory=list)


def history_days(day: date, window_days: int) -> list[date]:
    """The baseline window [day - window_days, day), oldest first."""
    return [day - timedelta(days=offset) for offset in range(window_days, 0, -1)]
