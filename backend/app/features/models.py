"""Calculation inputs and the report around DailyFeatures (not a contract change)."""
from __future__ import annotations

from dataclasses import dataclass
from dataclasses import field as dataclass_field
from datetime import date, datetime, timedelta
from typing import Literal

from pydantic import AwareDatetime, JsonValue, model_validator

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


class CalculationContext(Frozen):
    day: date
    timezone: IanaTimezone
    effective_at: AwareDatetime
    known_at: AwareDatetime
    coverage: tuple[CoverageWindow, ...] = ()

    @model_validator(mode="after")
    def _ordered(self) -> CalculationContext:
        if utc(self.known_at) < utc(self.effective_at):
            raise ValueError("known_at cannot precede effective_at")
        return self

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
        end = min(local_day_start(last + timedelta(days=1), self.timezone), utc(self.effective_at))
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
