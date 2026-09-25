"""G1 Step 4 state engine: DailyFeatures -> HealthState (Plan/Step_4_plan.md).

Pure and deterministic: no database, HTTP, HealthKit, LLM, clock, widget or
avatar code. It interprets features only; every number it states comes from a
feature, and every claim is backed by a driver built from those features.
"""
from __future__ import annotations

from app.config import Settings, settings_sha256
from app.contracts.features import DailyFeatures
from app.contracts.health_state import (
    Calibration,
    Driver,
    HealthState,
    MovementState,
    RecoveryState,
    SleepState,
    WorkoutState,
)

ENGINE_VERSION = "state-engine@0.1.0"
SUPPORTED_FEATURE_VERSIONS = frozenset({"features@0.2.0"})
# Fixed by G1 sections 37-40, so not configuration.
RECOVERY_INPUTS = ("sleep", "hrv", "rhr")
EXPECTED_RECOVERY_INPUTS = 3
MIN_RECOVERY_INPUTS = 2
ADVERSE = {"sleep": "below_baseline", "hrv": "below_usual", "rhr": "above_usual"}
MOVEMENT_SOURCE = "HealthKit statistics"  # merged statistics, not one device


class EngineInputError(ValueError):
    """Features the engine must not interpret (wrong version, other config, ...)."""


def usable(block) -> bool:
    """A recovery input votes only with a ready baseline, a current
    classification and some data support (plan decision 1)."""
    return block.baseline_status == "ready" and block.state not in ("missing", "calibrating") \
        and block.confidence > 0


def recovery(features: DailyFeatures) -> RecoveryState:
    blocks = {domain: getattr(features, domain) for domain in RECOVERY_INPUTS}
    used = [domain for domain in RECOVERY_INPUTS if usable(blocks[domain])]
    if len(used) < MIN_RECOVERY_INPUTS:
        return RecoveryState(state="insufficient_data", confidence=0)
    confidence = min(blocks[d].confidence for d in used) * len(used) / EXPECTED_RECOVERY_INPUTS

    def is_(domain: str, state: str) -> bool:
        return domain in used and blocks[domain].state == state

    if sum(is_(domain, ADVERSE[domain]) for domain in used) >= 2:
        state = "strained"
    elif is_("hrv", "above_usual") and is_("rhr", "below_usual") and not is_("sleep", "below_baseline"):
        state = "favorable"  # unusable sleep can't veto, whatever its state says
    else:
        state = "typical"
    return RecoveryState(state=state, confidence=confidence)


def calibration(features: DailyFeatures, settings: Settings) -> Calibration:
    domains = {d: getattr(features, d).usable_days for d in ("sleep", "hrv", "rhr", "movement")}
    required = settings.baseline.minimum_valid_days
    participating = [days for days in domains.values() if days > 0]
    usable_days = min(participating, default=0)
    status = "ready" if participating and usable_days >= required else "calibrating"
    return Calibration(required_days=required, domains=domains, status=status, usable_days=usable_days)


def drivers(features: DailyFeatures) -> list[Driver]:
    """Fixed order. Value drivers carry the feature confidence; a ready
    baseline without a current value is explained with confidence 0."""
    result = []

    def add(driver_id, domain, confidence, value, baseline, unit, source, observed_at, difference=None):
        if value is None and baseline is None:
            return
        if difference is None and value is not None and baseline is not None:
            difference = value - baseline
        result.append(Driver(id=driver_id, domain=domain, confidence=confidence if value is not None else 0,
                             value=value, baseline=baseline, difference=difference, unit=unit,
                             source=source if value is not None else None, observed_at=observed_at))

    s, m, w = features.sleep, features.movement, features.workout
    add("sleep_duration", "sleep", s.confidence, s.hours, s.baseline_hours, "hours", s.source, s.sleep_end,
        difference=s.delta_hours)
    for driver_id, domain, unit in (("hrv_sdnn", "hrv", "ms"), ("resting_hr", "rhr", "bpm")):
        block = getattr(features, domain)
        add(driver_id, domain, block.confidence, block.value, block.baseline, unit, block.source_name,
            block.observed_at)
    add("steps_so_far", "movement", m.confidence, m.steps, m.expected_steps_now, "steps", MOVEMENT_SOURCE, m.as_of)
    if w.last_workout_end is not None:
        add("last_workout", "workout", w.confidence, w.hours_since, None, "hours since end", w.source_name,
            w.last_workout_end)
    return result


def check_inputs(features: DailyFeatures, settings: Settings) -> None:
    if features.version not in SUPPORTED_FEATURE_VERSIONS:
        raise EngineInputError(f"unsupported feature version {features.version!r}")
    if features.config_sha256 != settings_sha256(settings):
        raise EngineInputError("features were calculated with different settings (config_sha256 mismatch)")
    required = {getattr(features, d).required_days for d in ("sleep", "hrv", "rhr", "movement")}
    if required != {settings.baseline.minimum_valid_days}:
        raise EngineInputError(f"inconsistent required_days {sorted(required)}")
    if features.workout.state == "active":
        raise EngineInputError("G1 never produces an active workout state")


def compute_health_state(features: DailyFeatures, settings: Settings) -> HealthState:
    check_inputs(features, settings)
    sleep = features.sleep
    severity = None
    if sleep.state in ("below_baseline", "above_baseline"):
        severity = min(abs(sleep.delta_hours * 60) / settings.state.sleep_severity_full_minutes, 1.0)
    return HealthState(
        engine_version=ENGINE_VERSION, feature_version=features.version, config_sha256=features.config_sha256,
        effective_at=features.effective_at,
        calibration=calibration(features, settings),
        sleep=SleepState(state=sleep.state, severity=severity, confidence=sleep.confidence),
        recovery=recovery(features),
        movement=MovementState(state=features.movement.state, confidence=features.movement.confidence),
        workout=WorkoutState(state=features.workout.state, type=features.workout.type,
                             confidence=features.workout.confidence),
        drivers=tuple(drivers(features)),
    )
