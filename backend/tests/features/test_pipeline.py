"""Step 3 gates: fixture expectations, all demo checkpoints, determinism, CLI."""
import os
import random
import subprocess
import sys
from pathlib import Path

import pytest

from app.config import load_settings
from app.contracts._types import json_value
from app.features.calculate import calculate_features
from app.features.models import CalculationReport
from app.features.synthetic import calculate_checkpoint, context_for, load_dataset, observations
from app.synthetic.scenarios import CASES
from app.synthetic.writer import json_bytes

BACKEND = Path(__file__).resolve().parents[2]
CORPUS = BACKEND.parent / "data" / "synthetic"
SETTINGS = load_settings()
# Fixture fields that live in report evidence rather than DailyFeatures.
ALIASES = ("sleep.selected_source", "movement.timezone", "steps", "recovery_usable_inputs")


def lookup(report: CalculationReport, field: str):
    features, evidence = json_value(report.features), report.evidence
    if field == "recovery_usable_inputs":
        # Test-side count of ready, measured recovery inputs; not a recovery decision.
        current = {"sleep": "hours", "hrv": "value", "rhr": "value"}
        return sum(features[d]["baseline_status"] == "ready" and features[d][k] is not None
                   for d, k in current.items())
    if field == "sleep.selected_source":
        return evidence["sleep"]["selected_source_bundle_ids"]
    if field == "movement.timezone":
        return evidence["movement"]["timezone"]
    if field == "steps":
        steps = features["movement"]["steps"]
        conflicted = any(d.startswith("movement_conflict") for d in report.diagnostics)
        return "conflict" if steps is None and conflicted else steps
    value = features
    for part in field.split("."):
        value = value[part]
    return value


@pytest.mark.parametrize("name", [name for name, _, _ in CASES])
def test_every_feature_expectation_in_every_scenario(scenarios, name):
    dataset = scenarios[name]
    claims = [a for a in dataset.expectations.assertions if a.layer == "features" or a.field in ALIASES]
    for claim in claims:
        report = calculate_checkpoint(dataset, claim.checkpoint, SETTINGS)
        actual = lookup(report, claim.field)
        if claim.field == "sleep.selected_source":
            assert actual == [claim.expected], name
        elif isinstance(claim.expected, float) or isinstance(actual, float):
            assert actual == pytest.approx(claim.expected), (name, claim.field)
        else:
            assert actual == claim.expected, (name, claim.field)
    # State-layer assertions wait for the Step 4 engine.


def test_every_demo_checkpoint_produces_valid_features(demo):
    first = demo.context.start_day
    for point in demo.context.checkpoints:
        report = calculate_checkpoint(demo, point.id, SETTINGS)
        CalculationReport.model_validate_json(json_bytes(report))
        # The 7-day workout window needs coverage before the corpus starts.
        early = (report.features.day - first).days < SETTINGS.workout.totals_days - 1
        assert (report.features.workout.state == "missing") == early, point.id


def test_input_order_and_retries_do_not_change_the_result(scenarios):
    dataset = scenarios["delivery_retries"]
    context = context_for(dataset, "after_delivery")
    inputs = list(observations(dataset))
    expected = json_bytes(calculate_features(inputs, context, SETTINGS))
    for seed in range(5):
        random.Random(seed).shuffle(inputs)
        assert json_bytes(calculate_features(inputs, context, SETTINGS)) == expected
    before = calculate_checkpoint(dataset, "evaluation", SETTINGS)
    after = calculate_checkpoint(dataset, "after_delivery", SETTINGS)
    assert before.features.hrv == after.features.hrv       # retries and a reimport add no weight
    assert before.input_sha256 != after.input_sha256       # but the visible input set did change


def test_corrected_knowledge_can_change_the_result(scenarios):
    dataset = scenarios["delayed_arrival"]
    assert calculate_checkpoint(dataset, "evaluation", SETTINGS).features.hrv.value is None
    assert calculate_checkpoint(dataset, "after_delivery", SETTINGS).features.hrv.value == 50


def run_cli(*args, env=None):
    return subprocess.run([sys.executable, "-m", "app.features", "calculate", *args], cwd=BACKEND, env=env,
                          capture_output=True, timeout=60)


def test_cli_output_is_identical_across_processes_and_ambient_timezones(tmp_path):
    outputs = []
    for index, zone in enumerate(("UTC", "Pacific/Auckland")):
        target = tmp_path / f"{index}.json"
        result = run_cli("--dataset", str(CORPUS / "scenarios" / "typical"), "--checkpoint", "evaluation",
                         "--output", str(target), env=dict(os.environ, TZ=zone, PYTHONHASHSEED=str(index)))
        assert result.returncode == 0, result.stderr
        outputs.append(target.read_bytes())
    assert outputs[0] == outputs[1]
    report = CalculationReport.model_validate_json(outputs[0])
    dataset = load_dataset(CORPUS / "scenarios" / "typical")
    assert json_bytes(report) == json_bytes(calculate_checkpoint(dataset, "evaluation", SETTINGS))


@pytest.mark.parametrize("args", [["--checkpoint", "nope"], ["--checkpoint", "evaluation", "--config", "missing.yaml"]])
def test_cli_rejects_bad_inputs(args):
    result = run_cli("--dataset", str(CORPUS / "scenarios" / "typical"), *args)
    assert result.returncode == 2 and b"error:" in result.stderr
