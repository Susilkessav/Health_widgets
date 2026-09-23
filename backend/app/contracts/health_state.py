"""HealthState: what the numbers mean inside Homeostat (plan_G1.md sections
37-44). It has no avatar or widget vocabulary; extra="forbid" rejects a stray
field like "eyes".

Replay identity is (feature_version, engine_version, config_sha256). `version`
is this contract's schema version and changes independently of them
(plan_G1.md section 50).
"""
from __future__ import annotations

from typing import Literal

from pydantic import AwareDatetime, model_validator

from app.contracts._types import (
    Confidence,
    Count,
    FiniteFloat,
    Frozen,
    NonEmptyStr,
    PositiveCount,
    Sha256Hex,
    close,
    require,
    utc,
)
from app.contracts.features import BaselineStatus


class DomainDays(Frozen):
    sleep: Count
    hrv: Count
    rhr: Count
    movement: Count


class Calibration(Frozen):
    """Summary across the baselined domains (sleep, HRV, RHR, movement).

    A domain participates once it has at least one usable day. `status` is
    "ready" only if every participating domain has usable_days >=
    required_days; `usable_days` is the minimum among participating domains.
    With no participating domains the summary is calibrating with 0 usable
    days. Both summary fields must equal what `domains` implies.
    """

    required_days: PositiveCount
    domains: DomainDays
    status: BaselineStatus
    usable_days: Count

    def domain_ready(self, domain: str) -> bool:
        return getattr(self.domains, domain) >= self.required_days

    @model_validator(mode="after")
    def _consistent(self) -> Calibration:
        participating = [days for days in self.domains.model_dump().values() if days > 0]
        usable = min(participating, default=0)
        status = "ready" if participating and usable >= self.required_days else "calibrating"
        if (self.status, self.usable_days) != (status, usable):
            raise ValueError(f"domains imply status={status!r}, usable_days={usable}")
        return self


class Driver(Frozen):
    """Provenance behind a state (plan_G1.md section 44). A driver for missing
    data can omit everything, but a measured value must say what it is,
    where it came from and when."""

    id: NonEmptyStr
    domain: Literal["sleep", "hrv", "rhr", "movement", "workout"]
    confidence: Confidence
    value: FiniteFloat | None = None
    baseline: FiniteFloat | None = None
    difference: FiniteFloat | None = None
    unit: NonEmptyStr | None = None
    source: NonEmptyStr | None = None
    observed_at: AwareDatetime | None = None

    @model_validator(mode="after")
    def _consistent(self) -> Driver:
        if self.value is not None:
            require(
                {"unit": self.unit, "source": self.source, "observed_at": self.observed_at},
                "a driver value",
            )
        if self.baseline is not None:
            require({"unit": self.unit}, "a driver baseline")
        if self.difference is not None:
            require({"value": self.value, "baseline": self.baseline}, "a driver difference")
            if not close(self.difference, self.value - self.baseline):
                raise ValueError("difference must equal value - baseline")
        return self


class SleepState(Frozen):
    state: Literal["calibrating", "below_baseline", "typical", "above_baseline", "missing"]
    severity: Confidence | None = None
    confidence: Confidence

    @model_validator(mode="after")
    def _consistent(self) -> SleepState:
        if (self.severity is not None) != (self.state in ("below_baseline", "above_baseline")):
            raise ValueError("severity is set exactly when state is below_baseline or above_baseline")
        return self


class RecoveryState(Frozen):
    state: Literal["strained", "typical", "favorable", "insufficient_data"]
    confidence: Confidence

    @model_validator(mode="after")
    def _consistent(self) -> RecoveryState:
        if self.state == "insufficient_data" and self.confidence != 0:
            raise ValueError("state=insufficient_data requires confidence=0 (plan_G1.md section 40)")
        return self


class MovementState(Frozen):
    state: Literal["calibrating", "behind_usual", "typical", "ahead_of_usual", "missing"]
    confidence: Confidence


class WorkoutState(Frozen):
    """See WorkoutFeatures: "missing" means history was unavailable, and
    G1 never produces "active"."""

    state: Literal["active", "just_completed", "recent_workout", "none_recent", "missing"]
    type: NonEmptyStr | None = None
    confidence: Confidence


class HealthState(Frozen):
    version: Literal["health-state@0.1.0"] = "health-state@0.1.0"
    engine_version: NonEmptyStr
    feature_version: NonEmptyStr
    config_sha256: Sha256Hex

    effective_at: AwareDatetime
    calibration: Calibration

    sleep: SleepState
    recovery: RecoveryState
    movement: MovementState
    workout: WorkoutState

    drivers: tuple[Driver, ...] = ()

    @model_validator(mode="after")
    def _consistent(self) -> HealthState:
        ids = [driver.id for driver in self.drivers]
        if len(ids) != len(set(ids)):
            raise ValueError("driver ids must be unique")
        now = utc(self.effective_at)
        if any(d.observed_at is not None and utc(d.observed_at) > now for d in self.drivers):
            raise ValueError("a driver cannot be observed after effective_at")

        # Checked per domain, not against the summary: a domain with no history
        # is calibrating yet doesn't hold the summary back.
        for domain, state in (("sleep", self.sleep.state), ("movement", self.movement.state)):
            if (state == "calibrating") == self.calibration.domain_ready(domain):
                raise ValueError(f"{domain}.state=calibrating must match calibration.domains.{domain}")

        for driver in self.drivers:
            if (
                driver.domain != "workout"
                and driver.baseline is not None
                and not self.calibration.domain_ready(driver.domain)
            ):
                raise ValueError(f"{driver.domain} driver baseline requires a ready domain")

        def measured(domain: str, needs_baseline: bool) -> bool:
            return any(
                d.domain == domain and d.value is not None and (d.baseline is not None or not needs_baseline)
                for d in self.drivers
            )

        if self.sleep.state in ("below_baseline", "typical", "above_baseline") and not measured("sleep", True):
            raise ValueError(f"sleep.state={self.sleep.state} requires a sleep driver with value and baseline")
        if self.movement.state in ("behind_usual", "typical", "ahead_of_usual") and not measured("movement", True):
            raise ValueError(
                f"movement.state={self.movement.state} requires a movement driver with value and baseline"
            )
        if self.recovery.state != "insufficient_data":
            inputs = sum(
                self.calibration.domain_ready(domain) and measured(domain, True)
                for domain in ("sleep", "hrv", "rhr")
            )
            if inputs < 2:
                raise ValueError(
                    f"recovery.state={self.recovery.state} requires measured drivers "
                    "with ready baselines from 2 of sleep/hrv/rhr"
                )
        if self.workout.state in ("just_completed", "recent_workout") and not any(
            d.domain == "workout" and d.observed_at is not None for d in self.drivers
        ):
            raise ValueError(f"workout.state={self.workout.state} requires a workout driver with observed_at")
        return self
