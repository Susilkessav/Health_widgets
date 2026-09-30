"""The Swift engine's reference: the Python pipeline's output for every
synthetic dataset checkpoint (Plan/On_device_plan.md phase 1).

Regenerate with: UPDATE_WIRE_FIXTURES=1 uv run pytest tests/engine/test_parity_fixture.py
"""
from pathlib import Path

from app.config import load_settings
from app.contracts._types import json_value
from app.features.synthetic import load_dataset
from app.pipeline import run_checkpoint
from tests.api.test_wire_fixtures import write_or_compare

DATA = Path(__file__).resolve().parents[3] / "data" / "synthetic"


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
