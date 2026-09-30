# G1 review and next steps

Updated: 2026-09-30

## Direction change — on-device calculation (2026-09-30)

Results are now calculated on the iPhone; the server is optional and scoped
for later. See [On-device plan](On_device_plan.md). Implemented:

- Swift port of features, state engine and wording (`HomeostatCore/Engine/`),
  held to the Python engine by a shared fixture: all 170 synthetic
  checkpoints match (`EngineParityTests`, `tests/engine/test_parity_fixture.py`).
- Local inputs from the phone's own event log and import coverage, including
  lost-anchor withdrawal (`LocalCalculation.swift`).
- The app recalculates after every import (open, HealthKit background delivery,
  background refresh) and hands the result to the widget. No server needed;
  the widget no longer fetches server results. Uploading stays optional.
- Verified in the simulator with no server configured: Health access, import,
  background delivery registration and an on-device result on screen.

For the phone test, the backend no longer needs to run: install, request
Health access (choose **All Recorded Data**), and add the widget.

## Current implementation (server design, kept for later)

The approved G1 completion software is implemented. See
[implementation record and device checklist](Implementation_2026_09_30.md) for
what changed, deployment details and remaining gates. The
[master plan](Master_implementation_plan.md) remains the overall sequence.

- Coherent import cutoffs, bounded/resumable history and import diagnostics.
- Read-only widget credentials, compact publication/status and exact-run APIs.
- Stable account scope, staged settings activation and coordinated shared cache.
- Independent widget fetch, deadlines, leases, retry/backoff and offline fallback.
- Matching run explanations, shared sync toggle and background diagnostics.
- Pure provider identity/correction/selection foundations; no second source enabled.

## Verification completed — 2026-09-30

- **175 backend tests passed:** 148 existing API/database/migration tests plus
  5 new widget API tests and 22 provider-foundation tests. Two dependency
  deprecation warnings remain. The full 3,667-test pre-change baseline passed
  on September 29; it was not rerun in full for this change.
- **84 Swift tests passed:** 64 HomeostatCore + 20 HomeostatShared.
- App and widget Debug simulator build succeeded.
- Local PostgreSQL backed up and upgraded; Alembic reports **0005 (head)**.
- No API was listening on port 8000 and no physical iPhone was connected during
  the deployment check. Real-device acceptance remains open.

## Next steps

1. Start the updated backend with the existing key. The worker must remain enabled.
2. Build/run on the signed iPhone; save Settings once to provision widget access.
3. Enable **Sync with server**, sync Health data, and inspect import/widget diagnostics.
4. Follow the device checklist, including independent fetching while the app is
   not running, locked/offline recovery, exact-run links and the 24–48 hour check.
5. Choose always-available HTTPS hosting if updates must work away from the Mac.
6. Close G1 acceptance before activating another provider. Full v2 ingestion,
   provider connection storage/authentication, Android and wearable adapters
   remain future implementation, gated by D01–D15 in the master plan.

The widget requests a roughly 30-minute refresh; iOS controls the actual timing.
Server fetching cannot force HealthKit to provide new readings while import is
unavailable. A recent server check can correctly return an older health state.

## A. Step 1 review closure

Sections A–G retain the earlier milestone notes and their historical test counts.
The current verification totals and remaining gates are listed above.

The earlier review fixes are implemented and covered by regressions:

- Per-domain calibration counts support excluded zero-history domains, partial
  calibration and ready summaries without contradictions.
- Sample events retain metadata and validate the provider type and original
  interval/workout boundaries. UTC comparisons handle DST transitions.
- Ready movement baselines remain available when today's steps are missing.
- Workout totals use the actual local calendar-day length. Duration checks use
  the implemented, documented common one-minute tolerance.
- Numeric validation, immutable drivers, finite values, missing-data handling,
  provenance and replay configuration identity are represented in the contracts.

The final two findings are now fixed:

1. **Snapshot conflicts:** `resolve_snapshot_bucket` selects the newest query
   within one bucket and raises `SnapshotConflictError` if that query time has
   contradictory totals. It never favors the larger count or falls back to an
   older observation. A newer unambiguous query resolves the conflict. Identical
   reads have a stable representative; empty input and mixed buckets have explicit
   behavior. Regressions cover increases, decreases, retries and arrival order.
2. **Recovery calibration:** drivers cannot claim a baseline for an unready
   domain. Recovery classifications require measured, baseline-ready drivers from
   at least two of sleep, HRV and RHR. Raw uncalibrated measurements may still be
   explained. Regressions cover 0/13 usable days and every pair at the 14-day
   readiness boundary.

Database conflict persistence and API acknowledgements remain in Steps 6-7.
The contract helper resolves observations already provided to it; filtering by
knowledge/effective time and selecting across buckets remain calculation work.

## B. Step 2 — deterministic synthetic dataset

**Complete.** Implementation: `backend/app/synthetic/`; tests:
`backend/tests/synthetic/`; default corpus: `data/synthetic/`.
All 14 G1 golden cases are represented among 44 isolated scenarios. The default
demo covers 2026-08-14 through 2026-09-22 in America/Chicago. The corpus contains
181 managed files; the manifest records hashes for the other 180 files, counts,
inputs and runtime provenance.

Generation command from `backend/`:

```bash
uv run python -m app.synthetic generate --output ../data/synthetic
```

Checks verify all canonical events, authored raw facts, snapshot resolution,
delivery/reference integrity, SHA-256 hashes, saved-corpus regeneration, and byte
equality across fresh processes with different ambient timezone/hash settings.
Semantic expectations remain specifications until the Step 3 feature calculator
and Step 4 state engine execute them. No new dependencies were added.

Deliverables:

- A generator under `backend/app/synthetic/` with explicit seed, starting date,
  evaluation times, timezone and generator version.
- At least 40 days of canonical events under `data/synthetic/`.
- A manifest recording generation inputs, scenario names and content hashes.
- Stable synthetic event IDs and provider IDs derived from scenario identity;
  do not use wall-clock time or random UUIDs for reproducible output.

Scenarios:

- Normal days, short sleep, low/high HRV, elevated RHR and step variation.
- Calibration with 0, 3, 13 and 14 usable days; missing data after readiness.
- Workouts within 2 hours, within 12 hours, older workouts and unavailable data.
- Overlapping sleep sources, awake gaps, in-bed-only intervals and naps.
- Duplicate uploads, deleted/replaced samples, delayed arrivals, upward/downward
  step corrections and conflicting same-time snapshots.
- DST transitions and travel; these may use focused fixtures outside the main
  40-day interval.

Completion gate: identical generator inputs yield byte-identical artifacts, all
events validate, and each scenario's intended inputs/expected outcomes are
documented independently of the future calculator.

## C. Step 3 — configuration and feature calculations

**Complete.** Plan, adopted decisions and results: [Step_3_plan.md](Step_3_plan.md).
Implementation: `backend/app/config.py`, `backend/config/homeostat.yaml`,
`backend/app/features/`; tests: `backend/tests/features/`.

Implement in this order:

1. Validated `homeostat.yaml` loading and a shared canonical configuration hash
   function. Save the fully resolved configuration alongside its hash so replay
   can recover the actual settings.
2. Pure event selection helpers: provider identity, tombstones, replacement
   records, snapshot conflicts/corrections and explicit evaluation time.
3. Sleep source selection, interval union, awake/in-bed exclusion, primary sleep
   versus naps and wake-day assignment.
4. Per-metric baseline median, MAD, readiness and configured source grouping.
5. HRV/RHR features, movement pacing, workout recency/totals and confidence.

Decisions to record before calculation code:

- Use the previous 28 calendar days, excluding the evaluated day, with at least
  14 valid daily observations. This resolves the plan's ambiguous phrase
  "previous 28 valid daily values"; do not silently extend the window backward
  through missing days.
- Define source grouping, daily HRV/RHR aggregation and sample selection.
- Use a deterministic near-zero-MAD fallback with per-metric configured scale
  floors; preserve the settings in replay configuration.
- Start movement pacing from comparable local times across prior days. Defer
  weekday-specific baselines until enough comparable history exists.
- Make evaluation day/timezone explicit even when sleep is absent. Define travel
  behavior and ties across zones without relying on input order.
- Separate effective time from knowledge/correction time. Use corrected-history
  recalculation for G1 and preserve emitted state history for any later
  "what the user saw then" replay.
- Define availability/completeness from ingestion coverage; an empty workout
  query alone cannot establish a complete history of no workouts.

Completion gate: feature golden tests pass, including baseline boundaries,
zero MAD, missing data, deletions, overlapping sources, DST and correction
ordering. Output includes the provenance needed by a pure state engine.

## D. Steps 4-5 — state engine and dummy presentation

**Complete.** Plan, decisions and results: [Step_4_plan.md](Step_4_plan.md).
Implementation: `backend/app/engine.py`, `backend/app/presentation.py`,
`backend/app/pipeline.py`; tests: `backend/tests/engine/`.

Deliverables:

- A pure `compute_health_state(features, config)` function.
- Calibration aggregation, sleep/movement/workout classification and the G1
  recovery rule with its coverage-adjusted confidence.
- Provenance drivers assembled entirely from features and configuration.
- A `HealthState -> WidgetState` mapper using text and simple icons.
- A synthetic demonstration that runs events through features, state and widget
  output at explicit evaluation times.

Completion gate:

- All 14 golden scenarios in `G1_plan.md` pass.
- Isolated high or low HRV does not independently change recovery.
- Fewer than two usable recovery inputs yields insufficient_data and confidence 0.
- Calibration and missing-data outputs render valid widget payloads.
- Identical inputs/configuration/versions produce identical deterministic output.

This synthetic pipeline is the next substantial product milestone.

## E. Steps 6-8 — persistence, API and replay

**Complete.** Plan, decisions and results: [Step_6_8_plan.md](Step_6_8_plan.md).
Implementation: `backend/app/{db,store,ingest,recalc,worker,main,replay,runtime}.py`,
`backend/migrations/`, `backend/Dockerfile`; tests: `backend/tests/{db,api,replay}/`.

- Add SQLAlchemy tables and Alembic migrations for canonical events, features,
  state history and recoverable configuration snapshots.
- Implement idempotent ingestion, explicit conflicts, tombstones, per-event
  acknowledgements and historical recalculation.
- Implement the four planned sync/state/debug endpoints; keep debug access local
  to development.
- Add the replay CLI and compare rebuilt payloads independently of operational
  timestamps.
- Use the existing Docker PostgreSQL service on host port 5433; keep user_id in
  every user's stored data even during single-user development.

Completion gate: synthetic ingestion survives retries and ordering variations;
fresh migrations work; replay twice gives identical results; conflicts are not
silently treated as duplicates.

## F. Steps 9-13 — real HealthKit and durable synchronization

Detailed plan and results: [Step_9_13_plan.md](Step_9_13_plan.md) §12.
Implemented on 2026-09-25, with 38 Swift tests; the real-iPhone checks are still open. It builds the durable queue before bootstrap and identifies the
backend handoffs for partial-day coverage and lost-anchor reconciliation.

- Build authorization-request tracking and the iOS debug screen.
- Import approximately 35 historical days and normalize supported samples and
  step statistics into the finalized contracts.
- Add observer/anchored queries, persistent anchors, deletions and bounded
  rebootstrap.
- Write events to the GRDB queue before upload; atomically coordinate durable
  event storage with anchor advancement.
- Apply per-event acknowledgements, retry backoff and dead-letter handling.
- Configure device-reachable backend networking and signing for real-device tests.

Completion gate: real data reaches the backend, offline events survive app
restarts, repeated sync is safe, and deleted/replaced samples update state.

## G. Steps 14-16 — cached widget and complete G1 demo

Detailed plan and results: [Step_14_16_plan.md](Step_14_16_plan.md) §12. Implemented 2026-09-25.

- Add shared Swift decoding for WidgetState and atomic App Group cache writes.
- Implement small/medium widgets, freshness, calibration and missing-data states.
- Reload widget timelines after meaningful updates; perform catch-up on app open
  and tolerate delayed background delivery.
- Run the full acceptance checklist in `G1_plan.md` on a real iPhone.

Completion gate: a HealthKit change flows through the backend into the widget,
temporary outages retain the last valid display, explanations match provenance,
and canonical replay reproduces the resulting states.

## Recommended next implementation task

The original G1 implementation and earlier review fixes are in place. The new
independent-widget requirement and completion architecture above supersede this
earlier implementation status. G1 acceptance is still pending:

1. Apply migration `0004`, then complete the simulator walkthrough and outage
   drill in Step_14_16_plan.md §12.
2. 📱 Complete the real-iPhone G1 acceptance run (Step_14_16_plan.md §10), including a
   live HealthKit change reaching the widget and the lost-anchor demonstration.
3. Record the results, then start the avatar work (G1 §62).
