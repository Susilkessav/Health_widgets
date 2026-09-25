# Homeostat backend

G1 backend: canonical events → features → HealthState → WidgetState. See `../Plan/G1_plan.md`.

```bash
docker compose up -d db     # from the repo root; Postgres on localhost:5433
cd backend
uv sync
uv run pytest
```

## Synthetic dataset — Step 2

Generate the default corpus from `backend/`:

```bash
uv run python -m app.synthetic generate \
  --seed 20260923 --start-date 2026-08-14 --days 40 \
  --timezone America/Chicago --output ../data/synthetic
uv run pytest -q
```

No new dependencies or running database are needed for generation. The demo
contains 40 local days for one fictional person. All five canonical event types
are represented. The 44 isolated scenarios include all 14 G1 golden cases plus
calibration, missing history, zero and near-zero MAD, outliers, overlapping sleep, retries,
corrections, deletions, delayed delivery, irregular step history, DST, travel,
two-input recovery and a device with no visible data.

`data/synthetic/` at the repository root contains 181 managed files:
canonical event JSONL, context, delivery batches, authored expectations and a
manifest with versions, inputs, timezone provenance, counts and SHA-256 hashes.
Read its `README.md` before consuming the fixtures. Load each dataset separately;
the isolated scenarios describe alternative histories and must not be combined.
Use `known_at` to filter deliveries and `effective_at` to select observations.
Coverage explicitly distinguishes known-empty history from unavailable history.

Changing the seed/date/day count/timezone changes the demo; golden scenarios
stay fixed. A minimum of 40 demo days is required. Regeneration overwrites managed
files and preserves unrelated files. Use a temporary output directory to compare
versions. Stable byte output requires the same generator, inputs, Python runtime
and timezone data; the manifest records that provenance. Demo client/sample IDs
are scoped to the seed, starting date and zone, while retries preserve their IDs.

Step 2 verifies canonical records, scenario facts, snapshot conflicts/corrections,
manifest integrity and fresh-process determinism across ambient timezones.
Feature assertions run in Step 3; state assertions await the Step 4 engine.

## Feature calculations — Step 3

```bash
uv run python -m app.features calculate \
  --dataset ../data/synthetic/scenarios/typical --checkpoint evaluation \
  [--config config/homeostat.yaml] [--output report.json]
```

`calculate_features(observations, context, settings)` in `app/features/` turns
canonical events into a `CalculationReport`: the contract `DailyFeatures`, the
resolved settings and their hash, an input hash, per-domain evidence and
diagnostics. It is pure: no clock, files, network or database. Settings live in
`config/homeostat.yaml` (validated by `app/config.py`; quote times such as
`"18:00"`). Policies and their reasons are in `../Plan/Step_3_plan.md`:

- **Inputs:** deliveries visible by `known_at`; retries collapse by client ID;
  reimports add no weight; conflicting provider records are quarantined; visible
  tombstones remove their record whenever the original arrives.
- **Sleep:** union of asleep stages minus overlapping awake time, per source;
  primary = longest overnight episode of the highest-priority source; naps and
  in-bed-only data never count as primary sleep.
- **HRV/RHR:** one fixed reading per day (latest inside primary sleep, else first
  after waking); robust z = (x - median) / max(1.4826 * MAD, floor).
- **Movement:** current total vs the median total at the same local wall time
  (any zone, up to 60 minutes earlier) over the previous 28 days. Real history
  needs hourly buckets from the HealthKit adapter.
- **Workouts:** overlapping sources split into segments, highest priority wins;
  unknown coverage is `missing`, known-empty history is `none_recent`.
- **Confidence:** maturity x freshness x coverage x source weight. Once-daily
  values stay fresh through their day. "Complete" coverage in production means
  the query finished after authorization was requested; HealthKit hides denials.

## State engine and widget mapper — Step 4

```bash
uv run python -m app.pipeline run --dataset ../data/synthetic/scenarios/short_sleep --checkpoint evaluation
uv run python -m app.pipeline timeline --dataset ../data/synthetic/demo
```

- **`app/engine.py`:** `compute_health_state(features, settings)` turns
  `DailyFeatures` into `HealthState`. It is pure, and it rejects features made
  under different settings, an unsupported feature version, or an `active`
  workout. Its recovery rule follows G1:
  - an input votes only when it is ready, classified and has confidence > 0;
  - two or more adverse inputs → `strained`;
  - HRV above plus RHR below, with no usable short sleep → `favorable`;
  - fewer than two inputs → `insufficient_data`;
  - confidence = min(input confidence) × inputs / 3.
  
  Every claim is backed by a driver built from features.
- **`app/presentation.py`:** `map_widget_state(state)` is the only place health
  meaning becomes icons and text.
  - Rules are ranked: shorter sleep, strained recovery, less active, workout
    complete, longer sleep, favorable recovery, more active, recent workout,
    learning your baseline, typical day, waiting for data.
  - Nothing with confidence below 0.5 is shown anywhere.
  - The text contains no clock or relative times.
  - Unknown workout types display as "Workout".
- **`app/pipeline.py`:** runs events → features → state → widget for one
  checkpoint, or prints a timeline of every demo checkpoint.

Decisions and their reasons are in `../Plan/Step_4_plan.md`.

## Persistence, API and replay — Steps 6-8

```bash
docker compose up -d db                                   # from the repo root
uv run alembic upgrade head                               # migrate the development database
HOMEOSTAT_API_KEY=dev-key HOMEOSTAT_ENV=development uv run uvicorn app.main:app
uv run python -m app.worker --once                        # run any pending recalculation now
uv run python -m app.replay runs    --user dev --from 2026-08-01 --to 2026-09-30
uv run python -m app.replay rebuild --user dev --from 2026-08-01 --to 2026-09-30
```

The API can also run in a container:

```bash
HOMEOSTAT_API_KEY=dev-key docker compose --profile api up -d --build
```

The container migrates on start and serves on port 8000.

**Endpoints.** All except `/healthz` need the `X-Homeostat-Key` header.

| Endpoint | Purpose |
|---|---|
| `POST /v1/health/sync` | Upload events and coverage. Returns a result per event, the new revision, and the state (`published`, `pending` or `unchanged`). |
| `GET /v1/state/current` | The latest state for any day, flagged `is_today`. 404 only if no state has ever existed. |
| `GET /v1/state/{day}` | The latest state for one day, flagged `finalized`. |
| `GET /v1/debug/features/{day}` | The latest features report. Only with `HOMEOSTAT_ENV=development`. |
| `GET /healthz` | Database status. |

**How it works** (the full design and its reasons are in `../Plan/Step_6_8_plan.md`):

- **Uploads are idempotent.**
  - A resent `request_id` returns the original response.
  - Every client event ID keeps a permanent receipt, so a retry returns the recorded outcome.
  - An event ID reused with different content is rejected.
  - Each distinct provider version is stored once. Contradictory versions of one record are both stored and quarantined until that record is tombstoned.
- **Revisions decide visibility.** Each committed upload gets the next per-user revision. A calculation sees exactly the data at its input revision, and results are ordered by revision, so an older calculation finishing late never becomes "latest".
- **Recalculation is durable.**
  - The upload and its recalculation job commit together. The job is tried inline, then by a background worker until it succeeds, including after crashes.
  - Pending jobs merge into one calculation at the newest revision.
  - Past days are computed at their closing boundary and today at the upload time, up to 35 days back.
  - A sweep finalizes yesterday after midnight even without an upload.
- **Coverage.** A later declaration supersedes an earlier one. Coverage is resolved over UTC time spans, so travel and DST days are checked correctly.
  - A declaration gives either whole local days (`start_day`/`end_day`) or exact instants (`start_at`/`end_at`) for a partial day, never both.
  - Coverage is needed only up to the calculation's effective time.
  - A timezone-only upload recalculates today.
- **Ordering.** State responses carry `input_revision` and `run_id`. Clients keep the state with the higher `(input_revision, run_id)`.
- **The run ledger.** Every calculation records its context, input revision, configuration snapshot hash and feature/engine/presentation versions:
  - `replay runs` re-executes each recorded run and compares outputs;
  - `replay rebuild` recomputes daily summaries at a cutoff revision.
- **Private logs and errors.** They contain counts, codes and field paths only, never health values or event and record IDs.

**Environment variables:**

| Variable | Meaning |
|---|---|
| `DATABASE_URL` | Default: the Compose database on port 5433 |
| `HOMEOSTAT_API_KEY` | Required for the API |
| `HOMEOSTAT_DEV_USER_ID` | The single development user |
| `HOMEOSTAT_ENV` | `development` enables the debug endpoint |
| `HOMEOSTAT_CONFIG` | The settings file |
| `HOMEOSTAT_WORKER_INTERVAL_SECONDS` | Default 30; 0 disables the thread |

**Deviations from G1 section 25:**
- Provider versions are unique on content, not on record identity.
- Client receipts live in their own table.
- A run ledger with outputs replaces `daily_features` and `health_state_history`. It keeps all their fields and adds what exact replay needs.

**Tests.** The full suite has **3,651 passing tests**, which take about 4 minutes:

| Suite | Tests |
|---|---|
| Contract | 170 |
| Synthetic | 91 |
| Feature | 127 |
| Engine and mapper | 3,119 (including the 512-case recovery matrix and all 2,500 valid widget state combinations) |
| Database | 34 |
| API | 104 |
| Replay | 6 |

Database tests use a throwaway database on the Compose server. `uv run pytest -m "not db"` runs the non-database tests in about 15 seconds, without PostgreSQL.

## Contract rules

The Pydantic contracts in `app/contracts/` enforce these rules. This section is the reference for the choices the G1 plan leaves open.

### Identity and retries

| Field | Meaning |
|---|---|
| `event_id` | Generated by the client when it creates the event. It is also the sync API's `client_event_id`. It stays the same across every retry of that event and is never reused. A new observation or operation gets a new `event_id`. |
| `source_record_id` | The provider's identity for the observation: an HKSample UUID, or the snapshot ID below. It is separate from `event_id`. |
| `(user_id, source, source_record_id, event_type)` | The dedup key in `health_events`. An upload that matches a stored row with an identical payload is reported as `duplicate`. The same key with a different payload is a conflict: ingestion reports it explicitly and never silently keeps either version. |

Provider-record deduplication compares logical content, excluding `event_id`:
another import of the same provider observation can have a new client ID. Retries
of the same queued event retain their original client ID. Persistence and API
acknowledgements for these rules are implemented in the later ingestion step.

Retry lifecycle, from plan sections 26–28:
- `accepted` and `duplicate` remove the event from the device queue.
- A permanent validation error moves it to `dead_letter`.
- A temporary error retries with backoff.
- If the device gets no response, the whole batch stays pending and is resent with the same `event_id`s. That's safe because ingestion is idempotent.

### Timestamps and timezones

- **Timestamps must carry an offset.** Naive datetimes are rejected.
- **Timestamps are ordered as UTC instants.** Python compares two datetimes that share a `tzinfo` by wall clock and ignores `fold`, which gives wrong answers inside a DST fall-back hour.
- **Offsets are not zones.** An offset alone can't resolve DST or local days, so every sample's `metadata.timezone` holds a validated IANA name.
  - If HealthKit supplies `HKMetadataKeyTimeZone`, the adapter uses it and sets `timezone_source="sample_metadata"`.
  - Otherwise it records the device's zone at ingestion time and sets `timezone_source="device_at_ingestion"`.
- **Sleep belongs to its wake day.** `DailyFeatures.day` is a local date in `DailyFeatures.timezone`. When a primary sleep episode exists, `day` must be the local date on which it ends, in the episode's own timezone.
- **A step snapshot's `day` is local to its `timezone`.** `as_of` must fall on that day, or exactly on its closing boundary for an end-of-day total. The closing boundary is the next local day's first instant: midnight normally, but 01:00 in zones where DST skips midnight (e.g. America/Santiago).

### Step snapshots and corrections

Each HealthKit statistics read of cumulative steps is its own event:

```
source_record_id = steps:{timezone}:{day}:{as_of as UTC}:{queried_at as UTC}:{steps}
```

- **History is kept.** Every read has its own ID, so intraday history is never overwritten.
- **Equal IDs mean identical reads.** The total is part of the ID, so two reads with different totals always have different IDs. Deduplication therefore only ever discards an exact copy, never a different total.

HealthKit can revise a past time bucket when watch data arrives late. For reads of the same bucket, meaning the same `(timezone, day, as_of)`:
- Use `resolve_snapshot_bucket(reads)`. It selects the greatest `queried_at`, accepting both increased and decreased totals.
- If that latest query time has different totals, it raises `SnapshotConflictError`. Keep the bucket unresolved; do not choose the larger total or fall back to an older read. A strictly newer, unambiguous query resolves the conflict.
- Identical latest reads are duplicates. The helper chooses a stable representative by client ID only after verifying their totals agree.
- Empty input returns `None`; mixing different buckets is rejected. Selection across buckets and evaluation-time filtering belong to the later feature calculator.
- Upload order never decides the winner.

When calculating features:
- The calculator uses the bucket with the latest `as_of` at or before `effective_at`.
- It only considers snapshots in one timezone. If a day has snapshots in several zones (travel), it uses the zone of the latest `as_of`.

### Deletions

`HKDeletedObject` carries no deletion time and no source metadata. A `DeleteEvent` therefore has only `source_record_id` plus `deleted_at`, which is when the adapter observed the deletion.

### Source metadata

HealthKit always reports a sample's source name and bundle identifier, so both are required.

- **Unfamiliar sources:** a source the sleep resolver doesn't recognize is still identified. The resolver ranks it as third-party.
- **Everything else:** HealthKit metadata that the canonical fields don't model is kept in `provider_metadata` as string key/value pairs. Dates are stored as ISO 8601 and HKQuantity values as `"<value> <unit>"`.
- **Original sample times:** each sample's own start and end are kept in `sample_start_at` and `sample_end_at`.
- **Metadata must describe its own event.** It can't contradict the event it's attached to:

| Event | `healthkit_type` must be | Sample times |
|---|---|---|
| HRV point | `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` | must contain `observed_at` |
| RHR point | `HKQuantityTypeIdentifierRestingHeartRate` | must contain `observed_at` |
| sleep interval | `HKCategoryTypeIdentifierSleepAnalysis` | must equal `start_at`/`end_at`, as instants |
| workout | `HKWorkoutTypeIdentifier` | must equal `start_at`/`end_at`, as instants |

### Missing data vs. calibrating

The sleep, HRV, RHR and movement feature blocks all follow the same matrix:

| `baseline_status` | Current value | `state` | Baseline fields | Comparison fields |
|---|---|---|---|---|
| calibrating | any | `calibrating` | unset | unset |
| ready | absent | `missing` | set | unset |
| ready | present | a classification | set | set |

- `baseline_status` is `ready` exactly when `usable_days >= required_days`.
- **Movement's baseline** is `expected_steps_now`, the usual step count by this time of day. It's computed from history, so it stays set whenever movement is ready, even when today's steps are missing. Movement's comparison field is `ratio`.
- A raw value may still be shown while the baseline is calibrating (plan section 17), but no comparison is made against it.
- **Movement with a zero expectation:** if `expected_steps_now` is 0 (for example just after midnight), `ratio` is undefined and unset, and the state can't be `behind_usual` or `ahead_of_usual`. With today's steps it's `typical`; without them it's `missing`.
- **Workouts:**
  - `state="missing"` means no workout history was available. All workout fields are unset.
  - `none_recent` means a confirmed absence of recent workouts. It includes totals (possibly 0) and may still name an older last workout.
  - `active` is reserved. HealthKit only reports completed workouts, so G1 never produces it.

### Calibration summary

`HealthState.calibration` records `required_days` and every domain's usable days (`domains.sleep`, `.hrv`, `.rhr`, `.movement`). The summary fields must equal what those numbers imply:

- **Participating domains:** a domain participates once it has at least one usable day.
- **Status:** `status` is `ready` only if every participating domain has `usable_days >= required_days`.
- **Usable days:** `usable_days` is the minimum across participating domains.
- **No participating domains:** the summary is `calibrating` with 0 usable days.

Each domain's state is checked against its own count, not against the summary. So a domain with no history can show `calibrating` while the summary is `ready`. A domain with some history but fewer than `required_days` holds the summary back.

### Explainability

- **Measured values carry provenance.** A driver with a `value` must also have a `unit`, `source` and `observed_at`.
- **`difference` is derived.** It must equal `value - baseline`.
- **A driver for missing data** may leave all of these unset.
- **Some states need drivers.** HealthState rejects these claims unless drivers back them:

| Claim | Required driver(s) |
|---|---|
| sleep `below_baseline`, `typical` or `above_baseline` | a sleep driver with a value and a baseline |
| movement `behind_usual`, `typical` or `ahead_of_usual` | a movement driver with a value and a baseline |
| any recovery state except `insufficient_data` | measured drivers with ready baselines from at least 2 of sleep, HRV and RHR |
| workout `just_completed` or `recent_workout` | a workout driver with `observed_at` |

`insufficient_data` recovery must have confidence 0.

A sleep, HRV, RHR or movement driver cannot carry a baseline until that domain's
usable-day count reaches `required_days`. Raw measurements without baselines may
still be explained during calibration, but do not count as usable recovery inputs.

### Numbers

- **Finite only.** NaN and ±Infinity are rejected everywhere.
- **Real JSON numbers only.** Booleans and numeric strings are rejected. Counts must be whole numbers.
- **Derived-value tolerance.** A derived number must match what it was derived from, within these limits. Calculators must not round more coarsely; the presentation layer does its own rounding.

| Derived value | Tolerance |
|---|---|
| deltas and ratios | 0.01 |
| durations checked against timestamps | 1 minute, for every duration check (sleep span, `hours_since`, workout duration, daily workout minutes) |

- **Workout duration:** `duration_minutes` may be shorter than `end_at - start_at`, because HealthKit excludes pauses. It may not be longer by more than the tolerance.
- **Real day length:** `workout_minutes_today` can't exceed the actual length of `day` in `DailyFeatures.timezone`. That's 1,380 minutes on a spring-forward day, 1,440 normally, and 1,500 on a fall-back day.

### Versions and replay identity

A stored state can be reproduced from its canonical events plus these three values:

| Value | What it identifies |
|---|---|
| `feature_version` | the feature calculations |
| `engine_version` | the state-engine interpretation |
| `config_sha256` | the configuration: SHA-256 of the fully resolved configuration, serialized as JSON with sorted keys, `(",", ":")` separators and UTF-8 encoding |

Feature version history: `features@0.2.0` added `WorkoutFeatures.source_name`
(set together with the last workout), so a workout driver can name its source.
Nothing was persisted under `features@0.1.0`.

Contract schema versions are separate from these: `schema_version` on events, and `version` on DailyFeatures, HealthState and WidgetState. They change only when the contract's shape changes. Sleep features also record `source_policy_version` (plan section 13).

### Deviations from the G1 examples

The plan's JSON examples are abbreviated. The contracts additionally require:

- **Events**
  - Real UUIDs.
  - `metadata` on every sample event.
  - `timezone` and `queried_at` on step snapshots, plus the snapshot ID format above (which includes the total).
- **Features**
  - Per-domain `usable_days` and `required_days`, and measurement provenance.
  - `effective_at`, `timezone` and `config_sha256` on DailyFeatures.
  - RHR's `value_bpm` is renamed to `value`; the unit is carried in `unit="bpm"`.
- **HealthState**
  - `engine_version`, `feature_version` and `config_sha256`.
  - A `domain` on each driver.
  - `required_days` and per-domain usable days in the calibration summary.
  - Sleep `severity` = min(|delta minutes| / 120, 1). G1 requires a severity
    but doesn't define it; its 0.62 example is illustrative.

## Review fixes — 2026-09-25

Live sync calculations use the common completed query cutoff of the domains
with coverage for today. `known_at` remains the server receipt/finalization time;
`effective_at` is saved separately in the calculation ledger. Missing domains and
explicit `unavailable` coverage still reduce confidence. Past days keep their
closing boundary. Exact replay uses the recorded timestamps.

Replay verification now reports a ledger entry with missing derived output as
`missing_output`, instead of silently skipping it. Rebuilding the same context
restores its missing output under the original run ID, without overwriting an
existing output or deleting the ledger.
