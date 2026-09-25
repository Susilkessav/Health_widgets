"""map_widget_state rules (Plan/Step_4_plan.md sections 5-6)."""
import itertools
import re

import pytest
from hypothesis import given, settings, strategies as st

from app.contracts.widget_state import WidgetState
from app.engine import compute_health_state
from app.presentation import (
    MIN_DISPLAY_CONFIDENCE,
    RULES,
    WORKOUT_LABELS,
    format_hours,
    format_steps,
    join,
    map_widget_state,
    workout_label,
)
from app.synthetic.writer import json_bytes

from .conftest import (
    MOVEMENT_STATES,
    POINT_STATES,
    SETTINGS,
    SLEEP_STATES,
    WORKOUT_STATES,
    features,
    workout_block,
)

BANNED = re.compile(r"\b(bad|poor|unhealthy|fail\w*|warning|danger\w*|sick|lazy|alarming|diagnos\w*)\b", re.I)
TIME = re.compile(r"\d{1,2}:\d{2}|\bago\b|\b[ap]\.?m\b|yesterday|tonight", re.I)
HEADLINES = {domain: {r.headline for r in RULES if r.domain == domain}
             for domain in ("sleep", "recovery", "movement", "workout")}


def widget(*states, **kwargs):
    return map_widget_state(compute_health_state(features(*states, **kwargs), SETTINGS))


def texts(result: WidgetState) -> list[str]:
    p = result.presentation
    return [t for t in (p.icon, p.headline, p.detail, p.secondary) if t]


COMBOS = list(itertools.product(SLEEP_STATES, POINT_STATES, POINT_STATES, MOVEMENT_STATES, WORKOUT_STATES))


@pytest.mark.parametrize("combo", COMBOS)  # 5 x 5 x 5 x 5 x 4 = 2,500 valid G1 combinations
def test_every_valid_state_combination_maps_safely(combo):
    state = compute_health_state(features(*combo), SETTINGS)
    result = map_widget_state(state)
    WidgetState.model_validate_json(json_bytes(result))
    assert result.presentation.headline.strip()
    assert not any(BANNED.search(t) or TIME.search(t) for t in texts(result))
    assert json_bytes(map_widget_state(state)) == json_bytes(result)
    assert result.freshness.last_updated_at == state.effective_at == result.effective_at
    trait = result.primary_trait
    # Every domain in the displayed explanation is backed by a driver (section 5).
    assert trait.explainable == (trait.id not in ("calibration", "no_data"))


CONFIDENCES = st.sampled_from((0.0, 0.49, 0.5, 1.0))


@settings(max_examples=400, deadline=None)
@given(combo=st.sampled_from(COMBOS), sleep=CONFIDENCES, hrv=CONFIDENCES, rhr=CONFIDENCES,
       movement=CONFIDENCES, workout=CONFIDENCES)
def test_nothing_below_display_confidence_is_shown(combo, sleep, hrv, rhr, movement, workout):
    state = compute_health_state(features(*combo, confidence={"sleep": sleep, "hrv": hrv, "rhr": rhr,
                                                             "movement": movement, "workout": workout}), SETTINGS)
    result = map_widget_state(state)
    p = result.presentation
    for domain in ("sleep", "recovery", "movement", "workout"):
        if getattr(state, domain).confidence >= MIN_DISPLAY_CONFIDENCE:
            continue
        assert result.primary_trait.id != domain
        assert p.secondary not in HEADLINES[domain]
        if domain == "workout":
            assert not (p.secondary or "").endswith("completed recently")
        if result.primary_trait.id == "typical":
            assert domain not in p.detail.lower()


def test_display_confidence_threshold_is_inclusive():
    assert widget("below_baseline", confidence={"sleep": 0.5}).presentation.headline == "Shorter sleep"
    below = widget("below_baseline", confidence={"sleep": 0.49})
    assert below.presentation.headline == "Typical day" and "sleep" not in below.presentation.detail.lower()


@pytest.mark.parametrize(("states", "trait"), [
    (("below_baseline", "below_usual"), "sleep"),                                          # P1 > P2
    (("typical", "below_usual", "above_usual", "behind_usual"), "recovery"),               # P2 > P3
    (("typical", "typical", "typical", "behind_usual", "just_completed"), "movement"),     # P3 > P4
    (("above_baseline", "typical", "typical", "typical", "just_completed"), "workout"),    # P4 > P5
    (("above_baseline", "above_usual", "below_usual"), "sleep"),                           # P5 > P6
    (("typical", "above_usual", "below_usual", "ahead_of_usual"), "recovery"),             # P6 > P7
    (("typical", "typical", "typical", "ahead_of_usual", "recent_workout"), "movement"),   # P7 > P8
    (("calibrating", "calibrating", "calibrating", "calibrating", "recent_workout"), "workout"),  # P8 > P9
    (("typical", "calibrating"), "calibration"),                                            # P9 > P10
    (("typical", "missing", "missing", "missing"), "typical"),                              # P10 > P11
    (("missing", "missing", "missing", "missing", "missing"), "no_data"),                   # P11
])
def test_rule_order(states, trait):
    assert widget(*states).primary_trait.id == trait


def test_secondary_prefers_a_displayable_workout_then_the_next_rule():
    both = widget("below_baseline", "below_usual", "typical", "typical", "recent_workout")
    assert both.presentation.secondary == "Strength training completed recently"
    assert widget("below_baseline", "below_usual").presentation.secondary == "Recovery signals below usual"
    hidden = widget("below_baseline", "below_usual", "typical", "typical", "recent_workout",
                    confidence={"workout": 0.49})
    assert hidden.presentation.secondary == "Recovery signals below usual"


def test_learning_needs_history_or_current_values():
    history = widget("calibrating", "calibrating", "calibrating", "calibrating", "missing")
    assert (history.presentation.headline, history.presentation.detail) == ("Learning your baseline",
                                                                            "5 / 14 usable days")
    empty = features().model_dump()
    for domain in ("sleep", "hrv", "rhr", "movement"):
        empty[domain] = {"baseline_status": "calibrating", "usable_days": 0, "required_days": 14,
                         "confidence": 0, "state": "calibrating"}
    empty["workout"] = workout_block("missing")
    no_data = map_widget_state(compute_health_state(features().model_validate(empty), SETTINGS))
    assert no_data.primary_trait.id == "no_data" and not no_data.primary_trait.explainable
    current_only = dict(empty, hrv={**empty["hrv"], "confidence": 0.3, "value": 50.0, "source_name": "Watch",
                                    "observed_at": features().hrv.observed_at, "source_record_id": "hk-hrv"})
    learning = map_widget_state(compute_health_state(features().model_validate(current_only), SETTINGS))
    assert (learning.presentation.headline, learning.presentation.detail) == ("Learning your baseline",
                                                                              "0 / 14 usable days")


def test_two_input_recovery_is_explainable():
    result = widget("missing", "above_usual", "below_usual")
    assert result.presentation.detail == "Based on HRV and resting HR" and result.primary_trait.explainable


@pytest.mark.parametrize(("hours", "text"), [(7 + 5 / 60, "7h 05m"), (5 + 58.5 / 60, "5h 59m"),
                                             (5 + 58.49 / 60, "5h 58m"), (0, "0h 00m")])
def test_format_hours(hours, text):
    assert format_hours(hours) == text


def test_other_formatting():
    assert (format_steps(1000), format_steps(999)) == ("1,000 steps", "999 steps")
    assert (join(["a"]), join(["a", "b"]), join(["a", "b", "c"])) == ("a", "a and b", "a, b and c")
    for workout_type, label in WORKOUT_LABELS.items():
        assert workout_label(workout_type) == label
    assert (workout_label("kitesurfing"), workout_label(None)) == ("Workout", "Workout")


def test_unknown_workout_types_show_as_workout_but_keep_the_raw_type():
    data = features().model_validate({**features().model_dump(),
                                      "workout": workout_block("just_completed", workout_type="kitesurfing")})
    state = compute_health_state(data, SETTINGS)
    assert map_widget_state(state).presentation.detail == "Workout"
    assert state.workout.type == "kitesurfing"
