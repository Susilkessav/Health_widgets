"""compute_health_state rules (Plan/Step_4_plan.md sections 3-4)."""
import ast
import itertools
from pathlib import Path

import pytest

import app.engine
import app.presentation
from app.engine import EngineInputError, compute_health_state
from app.synthetic.writer import json_bytes

from .conftest import CONFIG, SETTINGS, features, movement_block, point_block, sleep_block, workout_block

# Each recovery input independently: classification x confidence, or no vote.
DIRECTIONS = {"sleep": ("below_baseline", "typical", "above_baseline"),
              "hrv": ("below_usual", "typical", "above_usual"),
              "rhr": ("above_usual", "typical", "below_usual")}  # (adverse, typical, favorable)
VARIANTS = [(direction, confidence) for direction in range(3) for confidence in (0.0, 0.8)] + \
           [("missing", 0.8), ("calibrating", 0.8)]


def build(sleep, hrv, rhr):
    states, confidences = {}, {}
    for domain, (variant, confidence) in zip(("sleep", "hrv", "rhr"), (sleep, hrv, rhr)):
        states[domain] = DIRECTIONS[domain][variant] if isinstance(variant, int) else variant
        confidences[domain] = confidence
    return features(**states, confidence=confidences), states, confidences


def oracle(states, confidences):
    """The recovery rule restated from the plan, as the test's reference."""
    used = [d for d in ("sleep", "hrv", "rhr")
            if states[d] not in ("missing", "calibrating") and confidences[d] > 0]
    if len(used) < 2:
        return "insufficient_data", 0.0
    adverse = sum(states[d] == DIRECTIONS[d][0] for d in used)
    if adverse >= 2:
        state = "strained"
    elif "hrv" in used and "rhr" in used and states["hrv"] == "above_usual" and states["rhr"] == "below_usual" \
            and not ("sleep" in used and states["sleep"] == "below_baseline"):
        state = "favorable"
    else:
        state = "typical"
    return state, min(confidences[d] for d in used) * len(used) / 3


@pytest.mark.parametrize("combo", list(itertools.product(VARIANTS, repeat=3)))
def test_recovery_matrix(combo):  # 8^3 = 512 combinations
    data, states, confidences = build(*combo)
    recovery = compute_health_state(data, SETTINGS).recovery
    expected_state, expected_confidence = oracle(states, confidences)
    assert recovery.state == expected_state
    assert recovery.confidence == pytest.approx(expected_confidence)
    # An input that doesn't vote never changes the result, whatever it says.
    for index, domain in enumerate(("sleep", "hrv", "rhr")):
        if confidences[domain] == 0:
            replaced = list(combo)
            replaced[index] = ("missing", 0.8)
            assert compute_health_state(build(*replaced)[0], SETTINGS).recovery.state == recovery.state


@pytest.mark.parametrize("hrv", ["below_usual", "typical", "above_usual", "missing", "calibrating"])
def test_hrv_alone_never_moves_recovery(hrv):
    assert compute_health_state(features(hrv=hrv), SETTINGS).recovery.state == "typical"


@pytest.mark.parametrize(("sleep", "hrv", "rhr", "state", "confidence"), [
    ("typical", "below_usual", "typical", "typical", 1),                    # golden 4
    ("typical", "above_usual", "typical", "typical", 1),                    # golden 5
    ("below_baseline", "below_usual", "above_usual", "strained", 1),        # golden 6
    ("typical", "above_usual", "below_usual", "favorable", 1),              # golden 7
    ("typical", "missing", "typical", "typical", 2 / 3),                    # golden 8
    ("typical", "missing", "missing", "insufficient_data", 0),              # golden 9
    ("missing", "above_usual", "below_usual", "favorable", 2 / 3),          # decision 2
    ("missing", "below_usual", "above_usual", "strained", 2 / 3),           # decision 3
    ("below_baseline", "above_usual", "below_usual", "typical", 1),         # sleep blocks favorable
    ("calibrating", "above_usual", "below_usual", "favorable", 2 / 3),
])
def test_worked_examples(sleep, hrv, rhr, state, confidence):
    recovery = compute_health_state(features(sleep, hrv, rhr), SETTINGS).recovery
    assert (recovery.state, recovery.confidence) == (state, pytest.approx(confidence))


def test_unusable_sleep_below_baseline_cannot_veto_favorable():
    data = features("below_baseline", "above_usual", "below_usual", confidence={"sleep": 0})
    recovery = compute_health_state(data, SETTINGS).recovery
    assert (recovery.state, recovery.confidence) == ("favorable", pytest.approx(2 / 3))
    data = features("below_baseline", "below_usual", "typical", confidence={"sleep": 0})
    assert compute_health_state(data, SETTINGS).recovery.state == "typical"


@pytest.mark.parametrize(("hours", "severity"), [(6.5, 0.5), (5.5, 1.0), (4.5, 1.0), (9.5, 1.0), (8.5, 0.5)])
def test_sleep_severity(hours, severity):
    state = "below_baseline" if hours < 7.5 else "above_baseline"
    data = features().model_validate({**features().model_dump(), "sleep": sleep_block(state, hours=hours)})
    assert compute_health_state(data, SETTINGS).sleep.severity == pytest.approx(severity)


@pytest.mark.parametrize("state", ["typical", "missing", "calibrating"])
def test_severity_is_unset_without_a_deviation(state):
    assert compute_health_state(features(sleep=state), SETTINGS).sleep.severity is None


def test_calibration_summary_follows_the_domains():
    ready = compute_health_state(features(), SETTINGS).calibration
    assert (ready.status, ready.usable_days) == ("ready", 28)
    zero = features().model_dump()
    zero["hrv"] = {"baseline_status": "calibrating", "usable_days": 0, "required_days": 14, "confidence": 0,
                   "state": "calibrating"}
    summary = compute_health_state(features().model_validate(zero), SETTINGS).calibration
    assert (summary.status, summary.usable_days, summary.domains.hrv) == ("ready", 28, 0)  # excluded
    partial = compute_health_state(features(hrv="calibrating"), SETTINGS).calibration
    assert (partial.status, partial.usable_days) == ("calibrating", 5)


def test_drivers_are_built_from_features_in_fixed_order():
    state = compute_health_state(features(workout="just_completed"), SETTINGS)
    assert [d.id for d in state.drivers] == ["sleep_duration", "hrv_sdnn", "resting_hr", "steps_so_far", "last_workout"]
    sleep, hrv, _, steps, workout = state.drivers
    assert (sleep.value, sleep.baseline, sleep.difference, sleep.unit) == (7.5, 7.5, 0, "hours")
    assert (hrv.unit, hrv.source, hrv.difference) == ("ms", "Synthetic Watch", 0)
    assert (steps.source, steps.unit, steps.baseline) == ("HealthKit statistics", "steps", 5200)
    assert (workout.source, workout.value, workout.baseline) == ("Synthetic Watch", 1, None)


def test_calibrating_drivers_carry_values_but_no_baseline():
    state = compute_health_state(features("calibrating", "calibrating", "calibrating", "calibrating"), SETTINGS)
    assert all(d.value is not None and d.baseline is None for d in state.drivers)


def test_missing_drivers_carry_the_ready_baseline_with_zero_confidence():
    state = compute_health_state(features("missing", "missing", "missing", "missing"), SETTINGS)
    for d in state.drivers:
        assert d.value is None and d.baseline is not None and d.confidence == 0 and d.source is None


def test_the_raw_workout_type_is_kept():
    data = features().model_validate({**features().model_dump(),
                                      "workout": workout_block("just_completed", workout_type="kitesurfing")})
    assert compute_health_state(data, SETTINGS).workout.type == "kitesurfing"


def test_rejected_inputs():
    other = features().model_copy(update={"config_sha256": "0" * 64})
    old = features().model_copy(update={"version": "features@0.1.0"})
    mismatched = features().model_dump()
    mismatched["hrv"] = {**point_block("hrv"), "required_days": 10}
    active = features().model_dump()
    active["workout"] = workout_block("active")
    for data in (other, old, features().model_validate(mismatched), features().model_validate(active)):
        with pytest.raises(EngineInputError):
            compute_health_state(data, SETTINGS)


def test_output_is_deterministic():
    data = features("below_baseline", "below_usual", "above_usual", "behind_usual", "just_completed")
    assert json_bytes(compute_health_state(data, SETTINGS)) == json_bytes(compute_health_state(data, SETTINGS))
    assert compute_health_state(data, SETTINGS).config_sha256 == CONFIG


@pytest.mark.parametrize(("module", "allowed"), [
    (app.engine, ("__future__", "app.config", "app.contracts")),
    (app.presentation, ("__future__", "dataclasses", "math", "app.contracts")),
])
def test_engine_and_mapper_import_no_io(module, allowed):
    tree = ast.parse(Path(module.__file__).read_text())
    names = [a.name for n in ast.walk(tree) if isinstance(n, ast.Import) for a in n.names]
    names += [n.module for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)]
    assert all(name.startswith(allowed) for name in names), names
