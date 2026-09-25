"""Calculation inputs and the report around DailyFeatures (not a contract change)."""
from __future__ import annotations

from dataclasses import dataclass
from dataclasses import field as dataclass_field
from datetime import date, timedelta
from typing import Literal

from pydantic import AwareDatetime, JsonValue, model_validator

from app.contracts._types import Frozen, IanaTimezone, Sha256Hex, utc
from app.contracts.canonical_events import CanonicalEvent
from app.contracts.features import DailyFeatures

REPORT_VERSION = "feature-report@0.1.0"
Domain = Literal["sleep", "hrv", "rhr", "movement", "workout"]
DOMAINS: tuple[Domain, ...] = ("sleep", "hrv", "rhr", "movement", "workout")


class CalculationInputError(ValueError):
    """The inputs contradict themselves (e.g. one client event ID, two payloads)."""


class CoverageWindow(Frozen):
    """A declared query result for local days start_day..end_day in `timezone`.
    Production: "complete" means the query for that window finished after
    authorization was requested. HealthKit hides denials, so denied access
    looks like complete-and-empty; that is accepted, not inferred away."""

    domain: Domain
    start_day: date
    end_day: date
    timezone: IanaTimezone
    status: Literal["complete", "unavailable"]

    @model_validator(mode="after")
    def _ordered(self) -> CoverageWindow:
        if self.end_day < self.start_day:
            raise ValueError("coverage window is reversed")
        return self


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
        """Every day in first..last is inside a complete window and no
        unavailable window. An undeclared day is unknown, never complete."""
        day = first
        while day <= last:
            statuses = {w.status for w in self.coverage if w.domain == domain and w.start_day <= day <= w.end_day}
            if statuses != {"complete"}:
                return False
            day += timedelta(days=1)
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
