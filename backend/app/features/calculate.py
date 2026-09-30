"""calculate_features(observations, context, settings) -> CalculationReport.

Pure: no clock, filesystem, network or database. Confidence (plan §9) is
maturity * freshness * coverage * source weight for sleep, HRV, RHR and
movement; workouts are 1 with complete coverage, else 0 (state "missing").
These describe data support, not a probability of any health condition.
"""
from __future__ import annotations

from collections.abc import Iterable

from app.config import Freshness, Settings, settings_payload, settings_sha256
from app.contracts._types import json_value
from app.contracts.features import (
    DailyFeatures,
    HRVFeatures,
    MovementFeatures,
    RHRFeatures,
    SleepFeatures,
    WorkoutFeatures,
)
from app.features import movement, points, sleep, workouts
from app.features.models import CalculationContext, CalculationReport, Observation, Outcome, history_days
from app.features.selection import select_visible


def freshness(age_hours: float, rules: Freshness) -> float:
    if age_hours <= rules.full_hours:
        return 1.0
    return max(0.0, 1 - (age_hours - rules.full_hours) / (rules.zero_hours - rules.full_hours))


def confidence(outcome: Outcome, domain: str, context: CalculationContext, settings: Settings) -> float:
    if not outcome.present:
        outcome.evidence["confidence"] = {"reason": "no current value"}
        return 0.0
    parts = {
        "maturity": min(outcome.fields["usable_days"] / outcome.fields["required_days"], 1.0),
        "freshness": freshness(outcome.age_hours, getattr(settings.freshness, domain)),
        "coverage": 1.0 if context.covered(domain, context.day, context.day) else 0.0,
        "source_weight": outcome.weight,
    }
    outcome.evidence["confidence"] = parts
    return parts["maturity"] * parts["freshness"] * parts["coverage"] * parts["source_weight"]


def calculate_features(observations: Iterable[Observation], context: CalculationContext,
                       settings: Settings) -> CalculationReport:
    selection = select_visible(observations, context)
    episodes = sleep.eligible_episodes(selection, context, settings)
    days = [*history_days(context.day, settings.baseline.window_days), context.day]
    primaries = {day: sleep.primary(episodes, day, settings) for day in days}

    outcomes = {
        "sleep": sleep.calculate(episodes, selection, context, settings),
        "hrv": points.calculate("hrv_sdnn_ms", selection, context, settings, primaries),
        "rhr": points.calculate("resting_hr_bpm", selection, context, settings, primaries),
        "movement": movement.calculate(selection, context, settings),
        "workout": workouts.calculate(selection, context, settings),
    }
    scores = {domain: confidence(outcomes[domain], domain, context, settings)
              for domain in ("sleep", "hrv", "rhr", "movement")}
    scores["workout"] = 1.0 if outcomes["workout"].present else 0.0

    config_sha256 = settings_sha256(settings)
    models = {"sleep": SleepFeatures, "hrv": HRVFeatures, "rhr": RHRFeatures,
              "movement": MovementFeatures, "workout": WorkoutFeatures}
    features = DailyFeatures(
        config_sha256=config_sha256, day=context.day, timezone=context.timezone, effective_at=context.effective_at,
        **{domain: models[domain](**outcome.fields, confidence=scores[domain]) for domain, outcome in outcomes.items()},
    )
    diagnostics = [d for outcome in outcomes.values() for d in outcome.diagnostics]
    diagnostics += [f"conflict:{c.domain}:{c.day}:{c.source_record_id}" for c in selection.conflicts]
    evidence = {domain: outcome.evidence for domain, outcome in outcomes.items()}
    evidence["input"] = {"records": len(selection.records), "tombstoned": list(selection.tombstoned)}
    if selection.withdrawn:
        evidence["input"]["withdrawn"] = list(selection.withdrawn)
    return CalculationReport(
        features=features, config_sha256=config_sha256, config=settings_payload(settings), context=context,
        input_sha256=selection.input_sha256, evidence=json_value(evidence), diagnostics=tuple(sorted(diagnostics)),
    )
