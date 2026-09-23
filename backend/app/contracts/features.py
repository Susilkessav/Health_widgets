"""DailyFeatures: what the derived numbers are (plan_G1.md sections 29-41).

Every baselined domain obeys the same state matrix (backend/README.md):

  baseline_status  current value  state                   baseline  comparison
  calibrating      any            calibrating             unset     unset
  ready            absent         missing                 set       unset
  ready            present        a classification        set       set

For movement the "baseline" is expected_steps_now and the "comparison" is
ratio, which is undefined (unset) when expected_steps_now is 0.

Features also carry the provenance the state engine needs to build drivers,
because the engine receives features only and has no database access.
"""
from __future__ import annotations

from datetime import date
from typing import Literal
from zoneinfo import ZoneInfo

from pydantic import AwareDatetime, model_validator

from app.contracts._types import (
    DURATION_TOLERANCE_HOURS,
    DURATION_TOLERANCE_MINUTES,
    Confidence,
    Count,
    FiniteFloat,
    Frozen,
    IanaTimezone,
    NonEmptyStr,
    NonNegativeFloat,
    PositiveCount,
    PositiveFloat,
    Sha256Hex,
    close,
    forbid,
    local_day_minutes,
    require,
    utc,
)

FEATURES_VERSION = "features@0.1.0"

BaselineStatus = Literal["calibrating", "ready"]


def _check_state(
    status: str,
    state: str,
    has_value: bool,
    baseline: dict[str, object],
    comparison: dict[str, object],
    classifications: set[str],
) -> None:
    if status == "calibrating":
        if state != "calibrating":
            raise ValueError("baseline_status=calibrating requires state=calibrating")
        forbid({**baseline, **comparison}, "baseline_status=calibrating")
        return
    require(baseline, "baseline_status=ready")
    if not has_value:
        if state != "missing":
            raise ValueError("a ready baseline without a current value requires state=missing")
        forbid(comparison, "state=missing")
        return
    if state not in classifications:
        raise ValueError(f"a current value with a ready baseline requires state in {sorted(classifications)}")
    require(comparison, f"state={state}")


class _Baselined(Frozen):
    baseline_status: BaselineStatus
    usable_days: Count
    required_days: PositiveCount
    confidence: Confidence

    def _check_readiness(self) -> None:
        if (self.baseline_status == "ready") != (self.usable_days >= self.required_days):
            raise ValueError("baseline_status must be 'ready' exactly when usable_days >= required_days")


class SleepFeatures(_Baselined):
    state: Literal["calibrating", "below_baseline", "typical", "above_baseline", "missing"]

    # The primary episode for the wake day. These fields are all set together.
    hours: NonNegativeFloat | None = None
    sleep_start: AwareDatetime | None = None
    sleep_end: AwareDatetime | None = None
    span_hours: NonNegativeFloat | None = None
    in_bed_hours: NonNegativeFloat | None = None
    awake_minutes: NonNegativeFloat | None = None
    timezone: IanaTimezone | None = None
    source: NonEmptyStr | None = None
    source_policy_version: NonEmptyStr | None = None

    baseline_hours: PositiveFloat | None = None
    baseline_mad_hours: NonNegativeFloat | None = None

    delta_hours: FiniteFloat | None = None
    ratio: NonNegativeFloat | None = None

    @model_validator(mode="after")
    def _consistent(self) -> SleepFeatures:
        self._check_readiness()
        episode = {
            "sleep_start": self.sleep_start,
            "sleep_end": self.sleep_end,
            "span_hours": self.span_hours,
            "timezone": self.timezone,
            "source": self.source,
            "source_policy_version": self.source_policy_version,
        }
        if self.hours is None:
            forbid(
                {**episode, "in_bed_hours": self.in_bed_hours, "awake_minutes": self.awake_minutes},
                "hours unset",
            )
        else:
            require(episode, "hours")
            elapsed = (utc(self.sleep_end) - utc(self.sleep_start)).total_seconds() / 3600
            if elapsed <= 0:
                raise ValueError("sleep_end must be after sleep_start")
            if not close(self.span_hours, elapsed, DURATION_TOLERANCE_HOURS):
                raise ValueError("span_hours must equal sleep_end - sleep_start")
            if self.hours > self.span_hours + DURATION_TOLERANCE_HOURS:
                raise ValueError("hours asleep cannot exceed span_hours")
        _check_state(
            self.baseline_status,
            self.state,
            self.hours is not None,
            {"baseline_hours": self.baseline_hours, "baseline_mad_hours": self.baseline_mad_hours},
            {"delta_hours": self.delta_hours, "ratio": self.ratio},
            {"below_baseline", "typical", "above_baseline"},
        )
        if self.delta_hours is not None:
            if not close(self.delta_hours, self.hours - self.baseline_hours):
                raise ValueError("delta_hours must equal hours - baseline_hours")
            if not close(self.ratio, self.hours / self.baseline_hours):
                raise ValueError("ratio must equal hours / baseline_hours")
        return self


class _PointFeatures(_Baselined):
    state: Literal["calibrating", "below_usual", "typical", "above_usual", "missing"]

    value: PositiveFloat | None = None
    observed_at: AwareDatetime | None = None
    source_record_id: NonEmptyStr | None = None
    source_name: NonEmptyStr | None = None

    baseline: PositiveFloat | None = None
    mad: NonNegativeFloat | None = None

    # Not re-derived here: the near-zero-MAD fallback is configuration.
    robust_z: FiniteFloat | None = None

    @model_validator(mode="after")
    def _consistent(self) -> _PointFeatures:
        self._check_readiness()
        provenance = {
            "observed_at": self.observed_at,
            "source_record_id": self.source_record_id,
            "source_name": self.source_name,
        }
        if self.value is None:
            forbid(provenance, "value unset")
        else:
            require(provenance, "value")
        _check_state(
            self.baseline_status,
            self.state,
            self.value is not None,
            {"baseline": self.baseline, "mad": self.mad},
            {"robust_z": self.robust_z},
            {"below_usual", "typical", "above_usual"},
        )
        return self


class HRVFeatures(_PointFeatures):
    metric: Literal["hrv_sdnn_ms"] = "hrv_sdnn_ms"
    unit: Literal["ms"] = "ms"


class RHRFeatures(_PointFeatures):
    unit: Literal["bpm"] = "bpm"


class MovementFeatures(_Baselined):
    state: Literal["calibrating", "behind_usual", "typical", "ahead_of_usual", "missing"]

    # The snapshot selected for effective_at. steps=None means none was
    # visible, which is different from a real reading of 0.
    steps: Count | None = None
    as_of: AwareDatetime | None = None
    source_record_id: NonEmptyStr | None = None

    expected_steps_now: NonNegativeFloat | None = None
    ratio: NonNegativeFloat | None = None

    @model_validator(mode="after")
    def _consistent(self) -> MovementFeatures:
        self._check_readiness()
        provenance = {"as_of": self.as_of, "source_record_id": self.source_record_id}
        if self.steps is None:
            forbid(provenance, "steps unset")
        else:
            require(provenance, "steps")

        nothing_expected = self.expected_steps_now == 0
        _check_state(
            self.baseline_status,
            self.state,
            self.steps is not None,
            {"expected_steps_now": self.expected_steps_now},
            {} if nothing_expected else {"ratio": self.ratio},
            {"behind_usual", "typical", "ahead_of_usual"},
        )
        if nothing_expected:
            # E.g. just after midnight: the ratio is undefined, so the user
            # can't be behind or ahead.
            forbid({"ratio": self.ratio}, "expected_steps_now=0")
            if self.state in ("behind_usual", "ahead_of_usual"):
                raise ValueError("expected_steps_now=0 cannot be behind_usual or ahead_of_usual")
        elif self.ratio is not None and not close(self.ratio, self.steps / self.expected_steps_now):
            raise ValueError("ratio must equal steps / expected_steps_now")
        return self


class WorkoutFeatures(Frozen):
    """state="missing" means workout history wasn't available at all, which
    differs from a confirmed "none_recent". "active" is reserved for a future
    live-workout signal; G1 never produces it (see WorkoutEvent)."""

    state: Literal["active", "just_completed", "recent_workout", "none_recent", "missing"]
    confidence: Confidence

    # The most recent completed workout, if any. These fields are all set together.
    type: NonEmptyStr | None = None
    last_workout_start: AwareDatetime | None = None
    last_workout_end: AwareDatetime | None = None
    source_record_id: NonEmptyStr | None = None
    hours_since: NonNegativeFloat | None = None

    workout_minutes_today: NonNegativeFloat | None = None
    workout_minutes_last_7d: NonNegativeFloat | None = None

    @model_validator(mode="after")
    def _consistent(self) -> WorkoutFeatures:
        last = {
            "type": self.type,
            "last_workout_start": self.last_workout_start,
            "last_workout_end": self.last_workout_end,
            "source_record_id": self.source_record_id,
            "hours_since": self.hours_since,
        }
        totals = {
            "workout_minutes_today": self.workout_minutes_today,
            "workout_minutes_last_7d": self.workout_minutes_last_7d,
        }
        if self.state == "missing":
            forbid({**last, **totals}, "state=missing")
            return self
        require(totals, f"state={self.state}")
        # The cap against the local day's real length is in DailyFeatures,
        # which knows the day's timezone.
        if self.workout_minutes_today > self.workout_minutes_last_7d:
            raise ValueError("workout_minutes_today cannot exceed workout_minutes_last_7d")
        if self.last_workout_end is None:
            forbid(last, "no last workout")
            if self.state in ("just_completed", "recent_workout"):
                raise ValueError(f"state={self.state} requires a last workout")
        else:
            require(last, "last_workout_end")
            if not utc(self.last_workout_start) < utc(self.last_workout_end):
                raise ValueError("last_workout_start must be before last_workout_end")
        return self


class DailyFeatures(Frozen):
    version: Literal["features@0.1.0"] = FEATURES_VERSION
    # sha256 of the canonical configuration used (backend/README.md).
    config_sha256: Sha256Hex
    # The local calendar day in `timezone`. When a primary sleep episode exists,
    # it's that episode's wake day in the episode's own timezone.
    day: date
    timezone: IanaTimezone
    # When the features were evaluated. `day` alone can't tell a 9 AM run from
    # a 6 PM run, and movement pacing depends on which one this is.
    effective_at: AwareDatetime

    sleep: SleepFeatures
    hrv: HRVFeatures
    rhr: RHRFeatures
    movement: MovementFeatures
    workout: WorkoutFeatures

    @model_validator(mode="after")
    def _consistent(self) -> DailyFeatures:
        now = utc(self.effective_at)
        observed = {
            "sleep.sleep_end": self.sleep.sleep_end,
            "hrv.observed_at": self.hrv.observed_at,
            "rhr.observed_at": self.rhr.observed_at,
            "movement.as_of": self.movement.as_of,
            "workout.last_workout_end": self.workout.last_workout_end,
        }
        for name, moment in observed.items():
            if moment is not None and utc(moment) > now:
                raise ValueError(f"{name} cannot be after effective_at")
        if self.sleep.sleep_end is not None:
            wake_day = utc(self.sleep.sleep_end).astimezone(ZoneInfo(self.sleep.timezone)).date()
            if wake_day != self.day:
                raise ValueError("the primary sleep episode must end on `day` in its timezone")
        if self.workout.last_workout_end is not None:
            elapsed = (now - utc(self.workout.last_workout_end)).total_seconds() / 3600
            if not close(self.workout.hours_since, elapsed, DURATION_TOLERANCE_HOURS):
                raise ValueError("workout.hours_since must equal effective_at - last_workout_end")
        if self.workout.workout_minutes_today is not None:
            day_minutes = local_day_minutes(self.day, self.timezone)
            if self.workout.workout_minutes_today > day_minutes + DURATION_TOLERANCE_MINUTES:
                raise ValueError(f"workout_minutes_today cannot exceed this day's {day_minutes:.0f} minutes")
        return self
