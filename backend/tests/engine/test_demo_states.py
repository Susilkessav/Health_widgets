"""Real pipeline results for the app's avatar demo (G2 T10): selected synthetic
checkpoints run through features -> HealthState -> WidgetState, so the demo shows
what the engine actually produces rather than hand-made avatars.

Regenerate with: UPDATE_WIRE_FIXTURES=1 uv run pytest tests/engine/test_demo_states.py
"""
import json
from pathlib import Path

from app.config import load_settings
from app.contracts._types import json_value
from app.features.synthetic import load_dataset
from app.pipeline import run_checkpoint
from tests.api.test_wire_fixtures import UPDATE

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "ios" / "Homeostat" / "Homeostat" / "Demo" / "demo_states.json"

DEMOS = [
    ("Typical day", "demo", "2026-08-28_08"),
    ("Shorter sleep", "scenarios/short_sleep", "evaluation"),
    ("Short sleep, recovery below usual", "demo", "2026-09-12_08"),
    ("Short sleep, evening workout", "demo", "2026-09-12_19"),
    ("Recovery signals below usual", "demo", "2026-09-07_08"),
    ("Recovery signals above usual", "demo", "2026-09-15_08"),
    ("Recovery without sleep data", "scenarios/favorable_without_sleep", "evaluation"),
    ("Missing HRV", "scenarios/missing_hrv", "evaluation"),
    ("Less active than usual", "demo", "2026-09-17_08"),
    ("More active than usual", "demo", "2026-09-18_08"),
    ("Workout 45 minutes ago", "scenarios/workout_45m", "evaluation"),
    ("Workout 6 hours ago", "scenarios/workout_6h", "evaluation"),
    ("Workout yesterday", "scenarios/workout_24h", "evaluation"),
    ("Learning your baseline", "demo", "2026-08-14_08"),
    ("No data yet", "scenarios/no_visible_data", "evaluation"),
]


def test_demo_states_fixture():
    settings = load_settings()
    entries = []
    for name, dataset_path, checkpoint in DEMOS:
        dataset = load_dataset(ROOT / "data" / "synthetic" / dataset_path)
        result = run_checkpoint(dataset, checkpoint, settings)
        entries.append({"name": name, "dataset": dataset_path, "checkpoint": checkpoint,
                        "timezone": dataset.context.timezone, "widget_state": json_value(result.widget_state)})
    text = json.dumps(entries, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    if UPDATE:
        OUT.write_text(text, encoding="utf-8")
    assert OUT.read_text(encoding="utf-8") == text, "demo_states.json is stale: rerun with UPDATE_WIRE_FIXTURES=1"
