# Homeostat synthetic fixtures

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
