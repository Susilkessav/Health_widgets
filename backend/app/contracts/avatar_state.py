"""AvatarState: how HealthState appears on the avatar (Plan/specs/G2_plan.md
section 4). One field per visual channel, each driven by one HealthState
domain. Lighting and decay are not here: the renderer derives them from the
time it draws, so a widget timeline can change them without a recalculation.

Appearance (AvatarIdentity) lives only on the device and never enters this
contract.
"""
from __future__ import annotations

from typing import Annotated, Literal

from pydantic import AwareDatetime, Field, model_validator

from app.contracts._types import Confidence, Frozen, NonEmptyStr, PositiveFloat


class Effect(Frozen):
    """A fading effect: intensity(t) = peak * 0.5 ** ((t - started_at) / half_life)."""

    kind: Literal["sweat", "glow"]
    peak: Confidence
    started_at: AwareDatetime
    # One minute to one week, as the widget's AvatarState.Effect.halfLifeRange.
    half_life_minutes: Annotated[PositiveFloat, Field(ge=1, le=10_080)]


class Evidence(Frozen):
    """Driver ids behind each channel that differs from neutral, so tap-to-explain
    (G3) can show the readings. Posture lists every recovery input that counted."""

    eyes: tuple[NonEmptyStr, ...] = ()
    posture: tuple[NonEmptyStr, ...] = ()
    motion: tuple[NonEmptyStr, ...] = ()
    workout: tuple[NonEmptyStr, ...] = ()


class AvatarState(Frozen):
    version: Literal["avatar-state@0.1.0"] = "avatar-state@0.1.0"

    eyes: Literal["neutral", "rested", "tired"]
    eyes_intensity: Confidence
    posture: Literal["upright", "neutral", "low"]
    motion: Literal["low", "typical", "high"]
    activity: Literal["none", "cardio", "strength", "mobility"]
    effects: tuple[Effect, ...] = ()
    uncertainty: Literal["none", "calibrating", "low_confidence"]
    evidence: Evidence = Evidence()
    # Inputs with no reading today, in this order. Explained in words, never drawn:
    # the marker shows only when a visible channel is uncertain (decided 2026-10-05).
    missing_inputs: tuple[Literal["sleep", "hrv", "rhr", "movement"], ...] = ()

    @model_validator(mode="after")
    def _consistent(self) -> AvatarState:
        if (self.eyes == "neutral") != (self.eyes_intensity == 0):
            raise ValueError("eyes_intensity is 0 exactly when eyes is neutral")
        kinds = [e.kind for e in self.effects]
        if len(kinds) != len(set(kinds)):
            raise ValueError("at most one effect of each kind")
        if ("glow" in kinds) != (self.activity != "none"):
            raise ValueError("a glow effect is present exactly when activity is set")
        shown = {"eyes": self.eyes != "neutral", "posture": self.posture != "neutral",
                 "motion": self.motion != "typical", "workout": bool(self.effects)}
        order = ("sleep", "hrv", "rhr", "movement")
        if list(self.missing_inputs) != [d for d in order if d in self.missing_inputs]:
            raise ValueError("missing_inputs are unique and in sleep, hrv, rhr, movement order")
        if mismatched := [k for k, on in shown.items() if on != bool(getattr(self.evidence, k))]:
            raise ValueError(f"evidence is listed exactly for channels that differ from neutral: {mismatched}")
        return self
