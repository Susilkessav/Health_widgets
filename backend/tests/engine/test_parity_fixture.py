"""The Swift engine's reference: the Python pipeline's output for every
synthetic dataset checkpoint (Plan/specs/On_device_plan.md phase 1).

Regenerate with: UPDATE_WIRE_FIXTURES=1 uv run pytest tests/engine/test_parity_fixture.py
"""
from datetime import timedelta
from pathlib import Path

from app.config import load_settings
from app.contracts._types import json_value, utc
from app.engine import compute_health_state
from app.features.calculate import calculate_features
from app.features.models import CalculationContext
from app.features.selection import local_date
from app.features.synthetic import context_for, load_dataset, observations
from app.pipeline import run_checkpoint
from app.presentation import map_widget_state
from tests.api.test_wire_fixtures import write_or_compare

DATA = Path(__file__).resolve().parents[3] / "data" / "synthetic"
# Cutoff parity (decision D-A): every checkpoint again, as a widget step read this
# much later, with the other domains held at the checkpoint's own cutoff.
STEP_READ_LATER = timedelta(hours=3)


def test_engine_parity_fixture():
    settings = load_settings()
    entries = []
    for path in [DATA / "demo", *sorted((DATA / "scenarios").iterdir())]:
        dataset = load_dataset(path)
        for point in dataset.context.checkpoints:
            entry = {"dataset": str(path.relative_to(DATA)), "checkpoint": point.id}
            try:
                result = run_checkpoint(dataset, point.id, settings)
            except ValueError as error:  # contradictory inputs must fail on both sides
                entry["error"] = type(error).__name__
            else:
                entry |= {"features": json_value(result.features_report.features),
                          "diagnostics": list(result.features_report.diagnostics),
                          "health_state": json_value(result.health_state),
                          "widget_state": json_value(result.widget_state)}
            entries.append(entry)
    write_or_compare("engine_parity.json", entries)


def test_engine_parity_cutoffs_fixture():
    settings = load_settings()
    entries = []
    for path in [DATA / "demo", *sorted((DATA / "scenarios").iterdir())]:
        dataset = load_dataset(path)
        for point in dataset.context.checkpoints:
            entry = {"dataset": str(path.relative_to(DATA)), "checkpoint": point.id,
                     "later_seconds": int(STEP_READ_LATER.total_seconds())}
            base = context_for(dataset, point.id)
            effective = utc(base.effective_at) + STEP_READ_LATER
            try:
                context = CalculationContext(
                    day=local_date(effective, base.timezone), timezone=base.timezone, effective_at=effective,
                    known_at=max(utc(base.known_at), effective), coverage=base.coverage,
                    cutoffs={d: base.effective_at for d in ("sleep", "hrv", "rhr", "workout")})
                report = calculate_features(observations(dataset), context, settings)
                state = compute_health_state(report.features, settings)
            except ValueError as error:  # contradictory inputs must fail on both sides
                entry["error"] = type(error).__name__
            else:
                entry |= {"features": json_value(report.features), "diagnostics": list(report.diagnostics),
                          "health_state": json_value(state), "widget_state": json_value(map_widget_state(state))}
            entries.append(entry)
    write_or_compare("engine_parity_cutoffs.json", entries)
