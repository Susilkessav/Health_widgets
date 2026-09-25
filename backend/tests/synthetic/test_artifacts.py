import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

from app.synthetic.models import Dataset, GenerationConfig, Manifest
from app.synthetic.writer import build_artifacts, write_artifacts

BACKEND = Path(__file__).resolve().parents[2]
CORPUS = BACKEND.parent / "data" / "synthetic"


def read_tree(path):
    return {str(file.relative_to(path)): file.read_bytes() for file in path.rglob("*") if file.is_file()}


def test_manifest_hashes_counts_and_saved_corpus(artifacts):
    manifest = Manifest.model_validate_json(artifacts["manifest.json"])
    assert manifest.synthetic
    assert len(manifest.datasets) == 45
    assert set(manifest.files) == set(artifacts) - {"manifest.json"}
    for name, record in manifest.files.items():
        assert record.sha256 == hashlib.sha256(artifacts[name]).hexdigest()
        assert record.bytes == len(artifacts[name])
    for record in manifest.datasets.values():
        path = record.path
        events = [json.loads(line) for line in artifacts[f"{path}/events.jsonl"].splitlines()]
        batches = json.loads(artifacts[f"{path}/deliveries.json"])
        Dataset.model_validate({
            "events": events, "deliveries": batches,
            "context": json.loads(artifacts[f"{path}/context.json"]),
            "expectations": json.loads(artifacts[f"{path}/expectations.json"]) if path != "demo" else None,
        })
        assert len(events) == record.unique_events
        assert len(batches) == record.delivery_batches
        assert sum(len(batch["event_ids"]) for batch in batches) == record.event_deliveries
    # Environment provenance may change on another Python/zoneinfo installation.
    # Fixture bytes must still match; verify recorded provenance separately below.
    saved = read_tree(CORPUS)
    assert saved.keys() == artifacts.keys()
    assert {k: v for k, v in saved.items() if k != "manifest.json"} == {
        k: v for k, v in artifacts.items() if k != "manifest.json"
    }
    saved_manifest = Manifest.model_validate_json(saved["manifest.json"])
    assert saved_manifest.model_dump(exclude={"runtime"}) == manifest.model_dump(exclude={"runtime"})
    if saved_manifest.runtime == manifest.runtime:
        assert saved == artifacts


def test_fresh_processes_and_ambient_timezone_are_byte_identical(tmp_path, artifacts):
    for index, (zone, hashseed) in enumerate((("UTC", "1"), ("Pacific/Auckland", "987"))):
        output = tmp_path / str(index)
        env = dict(os.environ, TZ=zone, PYTHONHASHSEED=hashseed)
        result = subprocess.run([sys.executable, "-m", "app.synthetic", "generate", "--output", str(output)],
                                cwd=BACKEND, env=env, capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stderr
        assert read_tree(output) == artifacts


def test_seed_changes_only_demo_and_manifest(artifacts):
    changed = build_artifacts(GenerationConfig(seed=42))
    assert artifacts["demo/events.jsonl"] != changed["demo/events.jsonl"]
    assert artifacts["manifest.json"] != changed["manifest.json"]
    for name in artifacts:
        if name.startswith("scenarios/"):
            assert changed[name] == artifacts[name]


@pytest.mark.parametrize("args", [
    ["--days", "39"], ["--timezone", "Invalid/Zone"], ["--start-date", "2026-02-30"],
    ["--start-date", "9999-12-31"], ["--seed", "not-a-number"],
])
def test_cli_invalid_inputs_leave_output_untouched(tmp_path, args):
    output = tmp_path / "invalid"
    result = subprocess.run([sys.executable, "-m", "app.synthetic", "generate", *args, "--output", str(output)],
                            cwd=BACKEND, capture_output=True, text=True, timeout=60)
    assert result.returncode == 2
    assert "error:" in result.stderr
    assert not output.exists()


def test_writer_preserves_unrelated_files_and_rejects_symlinks(tmp_path):
    output = tmp_path / "corpus"
    output.mkdir()
    (output / "notes.txt").write_text("keep me")
    write_artifacts(output, {"demo/events.jsonl": b"first\n", "manifest.json": b"{}\n"})
    write_artifacts(output, {"demo/events.jsonl": b"second\n", "manifest.json": b"{}\n"})
    assert (output / "notes.txt").read_text() == "keep me"
    assert (output / "demo/events.jsonl").read_bytes() == b"second\n"
    outside = tmp_path / "outside.txt"
    outside.write_text("untouched")
    (output / "link.json").symlink_to(outside)
    with pytest.raises(ValueError, match="symlink"):
        write_artifacts(output, {"demo/events.jsonl": b"bad", "link.json": b"bad"})
    assert outside.read_text() == "untouched"
    assert (output / "demo/events.jsonl").read_bytes() == b"second\n"
    with pytest.raises(ValueError, match="within"):
        write_artifacts(output, {"../outside.txt": b"bad"})
