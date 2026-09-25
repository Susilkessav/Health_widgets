"""G1 Step 5 dummy presentation mapper: HealthState -> WidgetState.

The only place health meaning becomes icons and text (Plan/Step_4_plan.md
sections 5-6). Its constants are presentation policy: changing them never
changes HealthState, the engine version or the config hash.
"""
from __future__ import annotations

from dataclasses import dataclass
from math import floor

from app.contracts.health_state import Driver, HealthState
from app.contracts.widget_state import Freshness, Presentation, PrimaryTrait, WidgetState

MIN_DISPLAY_CONFIDENCE = 0.5
# Known labels only. Any other type shows as "Workout" so no unvetted provider
# identifier reaches the widget; the raw type stays in HealthState and drivers.
WORKOUT_LABELS = {
    "traditional_strength_training": "Strength training",
    "functional_strength_training": "Strength training",
    "running": "Run",
    "walking": "Walk",
    "cycling": "Ride",
    "yoga": "Yoga",
    "swimming": "Swim",
    "hiking": "Hike",
}
INPUT_NAMES = {"sleep": "sleep", "hrv": "HRV", "rhr": "resting HR"}


@dataclass(frozen=True)
class Rule:
    domain: str
    state: str
    icon: str
    headline: str


# P1-P8, in priority order: attention-worthy deviations, a fresh workout,
# positive deviations, then a recent workout.
RULES = (
    Rule("sleep", "below_baseline", "😴", "Shorter sleep"),
    Rule("recovery", "strained", "🪫", "Recovery signals below usual"),
    Rule("movement", "behind_usual", "🚶", "Less active than usual"),
    Rule("workout", "just_completed", "🏋️", "Workout complete"),
    Rule("sleep", "above_baseline", "🛌", "Longer sleep"),
    Rule("recovery", "favorable", "🔋", "Recovery signals above usual"),
    Rule("movement", "ahead_of_usual", "🚶", "More active than usual"),
    Rule("workout", "recent_workout", "🏋️", "Recent workout"),
)


def format_hours(hours: float) -> str:
    minutes = floor(hours * 60 + 0.5)  # half-up, unlike round()'s banker's rounding
    return f"{minutes // 60}h {minutes % 60:02d}m"


def format_steps(steps: float) -> str:
    return f"{floor(steps + 0.5):,} steps"


def join(names: list[str]) -> str:
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


def workout_label(workout_type: str | None) -> str:
    return WORKOUT_LABELS.get(workout_type or "", "Workout")


def displayable(state: HealthState, domain: str) -> bool:
    """The one eligibility test for every displayed claim: headline,
    secondary line and domain lists (plan section 6.1)."""
    return getattr(state, domain).confidence >= MIN_DISPLAY_CONFIDENCE


def driver(state: HealthState, domain: str) -> Driver | None:
    return next((d for d in state.drivers if d.domain == domain), None)


def recovery_inputs(state: HealthState) -> list[str]:
    """The inputs recovery used: drivers with value, baseline and confidence > 0,
    the same test as the engine's usable() (plan decision 1)."""
    return [d.domain for d in state.drivers if d.domain in INPUT_NAMES
            and d.value is not None and d.baseline is not None and d.confidence > 0]


def supported(state: HealthState, domain: str) -> bool:
    if domain == "recovery":
        return len(recovery_inputs(state)) >= 2
    found = driver(state, domain)
    if found is None:
        return False
    if domain == "workout":
        return found.observed_at is not None
    return found.value is not None and found.baseline is not None


def detail(state: HealthState, rule: Rule) -> str:
    if rule.domain == "sleep":
        return format_hours(driver(state, "sleep").value)
    if rule.domain == "movement":
        return format_steps(driver(state, "movement").value)
    if rule.domain == "workout":
        return workout_label(state.workout.type)
    return "Based on " + join([INPUT_NAMES[d] for d in recovery_inputs(state)])


def map_widget_state(state: HealthState) -> WidgetState:
    matches = [r for r in RULES if getattr(state, r.domain).state == r.state and displayable(state, r.domain)]
    secondary = None
    if matches:
        primary = matches[0]
        trait, icon, headline, text = primary.domain, primary.icon, primary.headline, detail(state, primary)
        named = [primary.domain]
        workout = state.workout
        if trait != "workout" and workout.state in ("just_completed", "recent_workout") \
                and displayable(state, "workout"):
            secondary = f"{workout_label(workout.type)} completed recently"
        else:
            secondary = next((r.headline for r in matches[1:] if r.domain != trait), None)
    else:
        typical = [d for d in ("sleep", "recovery", "movement")
                   if getattr(state, d).state == "typical" and displayable(state, d)]
        evidence = any(days > 0 for days in state.calibration.domains.model_dump().values()) \
            or any(d.value is not None for d in state.drivers)
        if state.calibration.status == "calibrating" and evidence:
            trait, icon, headline, named = "calibration", "🙂", "Learning your baseline", []
            text = f"{state.calibration.usable_days} / {state.calibration.required_days} usable days"
        elif typical:
            trait, icon, headline, named = "typical", "🙂", "Typical day", typical
            listed = join(typical)
            text = listed[0].upper() + listed[1:] + " as usual"
        else:
            trait, icon, headline, named = "no_data", "⏳", "Waiting for new data", []
            text = "Open Homeostat to sync Health data"
    return WidgetState(
        effective_at=state.effective_at,
        presentation=Presentation(icon=icon, headline=headline, detail=text, secondary=secondary),
        primary_trait=PrimaryTrait(id=trait, explainable=bool(named) and all(supported(state, d) for d in named)),
        freshness=Freshness(last_updated_at=state.effective_at),
    )
