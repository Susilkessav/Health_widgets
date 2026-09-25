"""Step 4 gates: fixture state/widget expectations, demo, determinism, CLI."""
import os
import subprocess
import sys
from pathlib import Path

import pytest

from app.config import load_settings
from app.pipeline import PipelineResult, run_checkpoint, timeline
from app.synthetic.scenarios import CASES
from app.synthetic.writer import json_bytes

BACKEND = Path(__file__).resolve().parents[2]
CORPUS = BACKEND.parent / "data" / "synthetic"
SETTINGS = load_settings()


@pytest.mark.parametrize("name", [name for name, _, _ in CASES])
def test_every_state_and_widget_expectation(scenarios, name):
    dataset = scenarios[name]
    for claim in dataset.expectations.assertions:
        if claim.layer not in ("state", "widget"):
            continue
        result = run_checkpoint(dataset, claim.checkpoint, SETTINGS)
        value = result.health_state if claim.layer == "state" else result.widget_state
        for part in claim.field.split("."):
            value = getattr(value, part)
        if isinstance(claim.expected, float):
            assert value == pytest.approx(claim.expected), (name, claim.field)
        else:
            assert value == claim.expected, (name, claim.field)


def test_all_fourteen_goldens_have_state_and_widget_expectations(scenarios):
    goldens = [d for d in scenarios.values() if d.context.golden_case]
    assert sorted(d.context.golden_case for d in goldens) == list(range(1, 15))
    for dataset in goldens:
        layers = {claim.layer for claim in dataset.expectations.assertions}
        assert {"state", "widget"} <= layers, dataset.context.id


def test_every_demo_checkpoint_runs_end_to_end(demo):
    first = demo.context.start_day
    for point in demo.context.checkpoints:
        result = run_checkpoint(demo, point.id, SETTINGS)
        PipelineResult.model_validate_json(json_bytes(result))
        headline = result.widget_state.presentation.headline
        if (result.health_state.calibration.status == "calibrating"
                and (result.features_report.features.day - first).days < 14):
            # Before any baseline is ready the widget is learning, unless a
            # workout just finished (P4 outranks P9).
            workout = result.health_state.workout.state
            assert headline == ("Workout complete" if workout == "just_completed" else "Learning your baseline")


def test_timeline_is_deterministic_with_one_line_per_checkpoint(demo):
    lines = timeline(demo, SETTINGS)
    assert len(lines) == len(demo.context.checkpoints) == 120
    assert lines == timeline(demo, SETTINGS)
    assert lines[0] == "2026-08-14 08:00  🙂 Learning your baseline · 0 / 14 usable days"


def run_cli(*args, env=None):
    return subprocess.run([sys.executable, "-m", "app.pipeline", *args], cwd=BACKEND, env=env,
                          capture_output=True, timeout=120)


def test_cli_run_is_identical_across_processes_and_timezones(tmp_path):
    outputs = []
    for index, zone in enumerate(("UTC", "Pacific/Auckland")):
        target = tmp_path / f"{index}.json"
        result = run_cli("run", "--dataset", str(CORPUS / "scenarios" / "short_sleep"), "--checkpoint",
                         "evaluation", "--output", str(target), env=dict(os.environ, TZ=zone, PYTHONHASHSEED=str(index)))
        assert result.returncode == 0, result.stderr
        outputs.append(target.read_bytes())
    assert outputs[0] == outputs[1]
    assert PipelineResult.model_validate_json(outputs[0]).widget_state.presentation.headline == "Shorter sleep"


def test_cli_timeline_prints_the_demo():
    result = run_cli("timeline", "--dataset", str(CORPUS / "demo"))
    assert result.returncode == 0, result.stderr
    assert len(result.stdout.decode("utf-8").splitlines()) == 120


@pytest.mark.parametrize("args", [
    ["run", "--dataset", "missing-dir", "--checkpoint", "evaluation"],
    ["run", "--dataset", str(CORPUS / "scenarios" / "typical"), "--checkpoint", "nope"],
    ["timeline", "--dataset", str(CORPUS / "demo"), "--config", "missing.yaml"],
])
def test_cli_rejects_bad_inputs(args):
    result = run_cli(*args)
    assert result.returncode == 2 and b"error:" in result.stderr and b"Traceback" not in result.stderr
