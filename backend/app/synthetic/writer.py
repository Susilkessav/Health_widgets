"""Canonical artifact serialization, environment provenance and safe regeneration."""
from __future__ import annotations

import hashlib
import importlib.metadata
import importlib.resources
import json
import os
import platform
import tempfile
from pathlib import Path
from zoneinfo import TZPATH

from app.contracts._types import json_value
from app.synthetic.generator import generate_demo
from app.synthetic.models import DatasetRecord, FileRecord, GenerationConfig, Manifest
from app.synthetic.scenarios import generate_scenarios

README = """# Homeostat synthetic fixtures

All records describe a fictional person. No real health data is included.
`source=healthkit` identifies the canonical adapter format, not real provenance.

The demo contains at least 40 local days. Isolated scenarios use fixed authored
measurements, dates and zones, independent of demo seed/date/timezone options.
Load each dataset independently. Do not concatenate scenarios into one person's
history: their deliberately different observations describe alternative cases.

Files:
- `events.jsonl`: validated canonical events, sorted by event ID, not arrival time.
- `context.json`: coverage declarations and effective/knowledge-time checkpoints.
- `deliveries.json`: simulated arrival batches, including retries and late data.
- `expectations.json`: authored raw/resolution facts and future feature/state checks.
- `manifest.json`: parameters, versions, runtime/timezone provenance and file hashes.

At a checkpoint, select delivery batches with delivered_at <= known_at. Then
consider measurements relevant to effective_at. Correction-time replay can know
more than was originally visible. Never treat every event in a file as already
available at every checkpoint. Closing-boundary snapshots (the next local day's
first instant: midnight, or 01:00 where DST skips midnight) belong to the
preceding local day. An absent event alone says nothing about query coverage.

Raw and snapshot-resolution checks run in Step 2. Feature and state expectations
are specifications for Steps 3-4, not verified engine output or medical claims.

The scenarios cover all 14 G1 golden cases plus calibration boundaries,
missing/partial history, zero/near-zero MAD, outliers, sleep overlaps and naps, workout
coverage/recency, step corrections/conflicts, delivery ordering/retries, DST
and travel. The manifest lists every scenario and its golden-case number.

From the repository's backend directory:

    uv run python -m app.synthetic generate --output ../data/synthetic
    uv run pytest

Defaults: seed 20260923, start 2026-08-14, 40 days, America/Chicago.
Reproducibility requires the same inputs, generator version, Python runtime and
timezone data. Regenerate into a temporary directory when comparing runtimes.
The manifest hashes every managed artifact except itself. Regeneration preserves
unrelated files; it does not clean obsolete files from older generator versions.
"""


def json_bytes(value) -> bytes:
    return (json.dumps(json_value(value), sort_keys=True, ensure_ascii=False,
                       allow_nan=False, separators=(",", ":")) + "\n").encode("utf-8")


def timezone_provenance(zone: str) -> dict[str, str]:
    for root in TZPATH:
        path = Path(root) / zone
        if path.is_file():
            return {"provider": "system", "tzif_sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    # zoneinfo uses the tzdata package when no configured system path contains it.
    data = importlib.resources.files("tzdata.zoneinfo").joinpath(*zone.split("/")).read_bytes()
    return {"provider": "tzdata", "version": importlib.metadata.version("tzdata"),
            "tzif_sha256": hashlib.sha256(data).hexdigest()}


def build_artifacts(config: GenerationConfig) -> dict[str, bytes]:
    datasets = (generate_demo(config), *generate_scenarios())
    files: dict[str, bytes] = {"README.md": README.encode("utf-8")}
    records = {}
    zones = {config.timezone, "America/Chicago", "America/Los_Angeles"}
    for dataset in datasets:
        name = dataset.context.id
        prefix = "demo" if name == "demo" else f"scenarios/{name}"
        files[f"{prefix}/events.jsonl"] = b"".join(json_bytes(event) for event in dataset.events)
        files[f"{prefix}/context.json"] = json_bytes(dataset.context)
        files[f"{prefix}/deliveries.json"] = json_bytes(dataset.deliveries)
        if dataset.expectations:
            files[f"{prefix}/expectations.json"] = json_bytes(dataset.expectations)
        records[name] = DatasetRecord(path=prefix, golden_case=dataset.context.golden_case,
                                      unique_events=len(dataset.events), delivery_batches=len(dataset.deliveries),
                                      event_deliveries=sum(len(d.event_ids) for d in dataset.deliveries))
    manifest = Manifest(
        parameters=config,
        runtime={"python": platform.python_version(), "implementation": platform.python_implementation(),
                 "timezones": {zone: timezone_provenance(zone) for zone in sorted(zones)}},
        datasets=records,
        files={name: FileRecord(sha256=hashlib.sha256(data).hexdigest(), bytes=len(data))
               for name, data in sorted(files.items())},
    )
    files["manifest.json"] = json_bytes(manifest)
    return files


def write_artifacts(output: Path, artifacts: dict[str, bytes]) -> None:
    """Replace managed files atomically, publishing the manifest last; never clean the directory."""
    output = output.resolve()
    # Preflight all destinations before modifying an existing corpus.
    for relative in artifacts:
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("artifact paths must stay within the output directory")
        target = output / path
        if any(part.is_symlink() for part in (target, *target.parents) if part != output.parent):
            raise ValueError(f"refusing a symlink artifact destination: {relative}")
        if target.exists() and not target.is_file():
            raise ValueError(f"artifact destination is not a file: {relative}")
    for name in sorted(artifacts, key=lambda name: (name == "manifest.json", name)):
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=target.parent, prefix=".synthetic-", delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(artifacts[name])
            os.replace(temporary, target)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
