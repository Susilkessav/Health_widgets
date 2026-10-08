# G1 Steps 6-8 — persistence, API and replay

Status: **Approved (revision 2) and implemented — 2026-09-24.**

Prepared: 2026-09-24. This revision replaces the first draft after review. It
fixes the transaction and locking design, adds durable recalculation, per-client
receipts, coverage supersession, a correct input-loading rule, a run ledger for
exact replay, and day-rollover behavior. Steps 1-5 are complete (3,496 passing
tests).

This plan covers milestone E in `Next_steps.md`:

| G1 step | What it adds |
|---|---|
| 6 | PostgreSQL storage |
| 7 | The FastAPI endpoints |
| 8 | Replay |

Sources: `G1_plan.md` sections 25-28, 48, 51-52, 56-58; Step 1-4 plans; `backend/README.md`.

## 1. Outcome and scope

A client can upload canonical events and get a per-event acknowledgement. The
server then:

- stores them durably;
- recalculates the affected days, reliably, even after a crash;
- publishes a WidgetState;
- serves current and past states with explicit freshness;
- can reproduce every recorded calculation exactly.

It can also rebuild daily summaries from stored events.

Deliver:
- PostgreSQL tables and one Alembic migration.
- Idempotent, revisioned ingestion.
- A durable recalculation queue in PostgreSQL.
- Four endpoints plus a health check.
- Replay (exact and rebuild).
- Logs and errors that never contain health data.

Out of scope:

| Item | Belongs to |
|---|---|
| iOS networking, GRDB queue, HealthKit | Steps 9-13 |
| Widget rendering and caching | Steps 14-16 |
| Real authentication and production multi-user | before external beta (G1 §57) |
| A separate queue service | not needed; the PostgreSQL table in §6 is enough for G1 |

## 2. Principles

1. **Events are the source of truth.** Features, states and widgets are derived
   and can be recomputed.
2. **Visibility is by revision, not by clock.** Every committed upload gets the
   next per-user revision number. A calculation captures one revision and sees
   exactly the data committed at or before it. Timestamps can tie or commit out
   of order; revisions can't.
3. **Nothing acknowledged is ever lost or forgotten.** Accepted data commits
   together with a pending-recalculation record. Every client event ID ever
   acknowledged keeps a receipt.
4. **The pure functions stay pure.** `calculate_features`,
   `compute_health_state` and `map_widget_state` are called unchanged, apart
   from the coverage fix in §7. The database layer only chooses their inputs and
   stores their outputs.
5. **Older work never overwrites newer work.** Derived results are ordered by
   input revision. A slow calculation that finishes late can't become "latest".

## 3. Decisions to approve

| # | Topic | Rule |
|---|---|---|
| 1 | Revisions | `users.revision` increases by one per committed upload that changes stored data. The upload transaction locks the user row (`SELECT … FOR UPDATE`), which serializes ingestion per user. The revision's `received_at` is `max(clock_now, previous revision's received_at)`, so knowledge time never moves backward. |
| 2 | Locking | Ingestion takes the user row lock inside its single transaction. Calculation takes a transaction-scoped advisory lock on the user inside its own single transaction. Neither spans two transactions (review item 1). |
| 3 | Durable recalculation | The upload transaction inserts a `recalc_jobs` row (user, target revision, earliest affected day). It stays pending until the derived results commit. The request makes one inline attempt; a background worker and a CLI retry anything pending, including after crashes and restarts (§6). |
| 4 | Receipts | Every client event ID with a readable `event_id` gets a permanent receipt: its payload hash, first receipt time, recorded outcome, and a link to the stored version. Retries return the recorded outcome. The same ID with different content is rejected with `CLIENT_EVENT_ID_REUSED` (review item 3). |
| 5 | Stored versions | `health_events` stores each distinct provider version once: unique on `(user_id, source, source_record_id, event_type, payload_sha256)`. Receipts map client IDs to versions. This deviates from G1 §25.1's provider-unique key, so contradictory versions can both be kept. |
| 6 | Request idempotency | Every sync carries a client-generated `request_id`. Resending the same `request_id` with the same body returns the original response and appends nothing: no coverage, no revision, no job. The same `request_id` with a different body gets 409 `REQUEST_ID_REUSED`. |
| 7 | Three kinds of conflict | See §5.3: a reused client ID is rejected; contradictory provider versions are quarantined until that record is tombstoned; a conflicting step bucket is resolved by a newer unambiguous query. |
| 8 | Coverage supersession | Declarations are kept forever and tagged with their revision. Before calculation they're resolved in UTC time: at each instant, the highest-revision declaration covering it wins. A day is complete when its whole UTC span is won by `complete` declarations. So a later successful query supersedes an earlier failure, and historical replay still sees the old answer (§7). |
| 9 | Input loading | A calculation loads measurements in a configuration-derived range, plus every visible tombstone and every visible version of each loaded provider identity, whatever their dates (§8). |
| 10 | Run ledger | Every calculation writes a `calculation_runs` row: the full context, input revision, config hash, and feature, engine and presentation versions. Exact replay re-executes runs; daily rebuild is a separate command with an explicit cutoff revision (§10). |
| 11 | Presentation version | `PRESENTATION_VERSION = "presentation@0.1.0"` in the mapper, recorded on every run, because wording can change without the engine or features changing. |
| 12 | Day rollover | `/state/current` returns the latest published state for any day, with `day`, `is_today` and `effective_at`. 404 means no state has ever existed. A previous day is *finalized* by a closing-boundary run once that boundary has passed; the worker's sweep makes sure it happens even without a new upload (§9). |
| 13 | Derived ordering | Latest = highest `input_revision`, then highest `run_id`. Result identity includes timezone and input revision. |
| 14 | Configuration snapshots | Global and content-addressed by `config_sha256`, with no `user_id`: settings aren't user data. Runs reference them by hash. All user data tables keep `user_id`. |
| 15 | Recalculation window | Up to 35 days back, as in G1 §51. Corrections to older days are stored and affect replay, but their older derived days stay stale until an explicit `rebuild`. The response reports `days_beyond_recalc_window`. |
| 16 | Temporary failures | A database failure during upload gets 503 with `Retry-After`, and nothing is committed. Per-event outcomes are final (`retryable` is always false). |
| 17 | Auth | `X-Homeostat-Key`, checked in constant time, maps to one development user (G1 §57). Every user table has `user_id`, and isolation is tested with two users at the storage layer. |
| 18 | Debug endpoint | Exists only with `HOMEOSTAT_ENV=development`. |
| 19 | Error sanitizing | Framework validation errors are replaced by `{code, field_path}` lists. No input values are echoed. The same rule applies to logs (§12). |
| 20 | SQL and deployment | SQLAlchemy Core with synchronous psycopg 3 and FastAPI sync endpoints. Local `uv run uvicorn` plus a Compose `api` service. No new dependencies. |

## 4. Storage (Step 6)

One Alembic migration, `0001_initial`, creates these tables. User tables carry
`user_id`, and all times are `timestamptz`.

| Table | Purpose | Key columns |
|---|---|---|
| `users` | User; revision counter; latest zone | `id` PK, `timezone`, `revision` (starts at 0), `revision_received_at`, `created_at` |
| `sync_requests` | One per distinct `request_id` | PK `(user_id, request_id)`; `body_sha256`, `revision` (null if nothing changed), `received_at`, `response jsonb` (results, affected days), per-status counts |
| `health_events` | Distinct provider versions | `id` PK; UNIQUE `(user_id, source, source_record_id, event_type, payload_sha256)`; `event_type`, `observed_at`, `start_at`, `end_at`, `payload jsonb`, `revision`, `received_at` |
| `event_receipts` | Every readable client event ID ever received | PK `(user_id, event_id)`; `payload_sha256`, `first_request_id`, `first_received_at`, `outcome`, `code`, `health_event_id` (nullable FK) |
| `coverage_declarations` | Every coverage window, kept | `id` PK; `domain`, `start_day`, `end_day`, `timezone`, `status`, `revision`, `received_at` |
| `recalc_jobs` | Durable pending work | `id` PK; `target_revision`, `from_day`, `kind` (`sync` or `finalize`), `status` (`pending` or `done`), `attempts`, `next_attempt_at`, `last_error_code`, `created_at`, `completed_at` |
| `config_snapshots` | Global settings by hash | `config_sha256` PK; `payload jsonb`; `first_used_at` |
| `calculation_runs` | Ledger of every calculation | `run_id` PK (bigserial); `kind` (`sync`, `finalize`, `rebuild`), `day`, `timezone`, `effective_at`, `known_at`, `input_revision`, `config_sha256` FK, `feature_version`, `engine_version`, `presentation_version`, `job_id`, `created_at`; UNIQUE on everything except `run_id`, `job_id` and `created_at` |
| `run_outputs` | One per run | PK `run_id` FK; `report jsonb` (CalculationReport), `state jsonb`, `widget_state jsonb`, `input_sha256` |

Indexes:

| Table | Indexes |
|---|---|
| `health_events` | `(user_id, source, source_record_id, event_type)`, `(user_id, revision)`, `(user_id, end_at)`, `(user_id, observed_at)`, `(user_id, event_type)` for tombstones |
| `calculation_runs` | `(user_id, day, input_revision DESC, run_id DESC)` |
| `recalc_jobs` | `(status, next_attempt_at)` |

Deviations from G1 §25, documented in the README:

- **Provider-version key** (decision 5).
- **Receipts** as a separate table (decision 4).
- **`daily_features` and `health_state_history` replaced by the run ledger plus
  run outputs.** Every G1 field is still present: day, effective time, versions,
  the state document and a `trigger` equivalent (`kind` plus `job_id`). A run
  also records the context needed to reproduce it.

Round-trip safety: loaded payloads are re-validated through the contracts. A
test stores and reloads every corpus event and report and checks the canonical
JSON bytes are unchanged.

## 5. Ingestion (Step 6/7)

### 5.1 Request and response

```json
{
  "request_id": "7c0e…",
  "device_timezone": "America/Chicago",
  "coverage": [{"domain": "sleep", "start_day": "2026-08-18", "end_day": "2026-09-22",
                "timezone": "America/Chicago", "status": "complete"}],
  "events": [{"event_id": "…", "event_type": "point_measurement", "…": "…"}]
}
```

Limits and envelope errors:
- At most 500 events and 5 MB, otherwise 413.
- An invalid envelope gets 422 with sanitized errors: `request_id`,
  `device_timezone` (must be IANA), `coverage` entries, or `events` not an array.
- Events are validated one by one, so one bad event never rejects the others.

Response, which is also stored for request retries:

```json
{
  "request_id": "7c0e…",
  "revision": 42,
  "results": [
    {"index": 0, "client_event_id": "a", "status": "accepted", "retryable": false},
    {"index": 1, "client_event_id": "b", "status": "duplicate", "retryable": false},
    {"index": 2, "client_event_id": "c", "status": "conflict", "code": "CONFLICTING_PROVIDER_RECORD", "retryable": false},
    {"index": 3, "client_event_id": null, "status": "rejected", "code": "INVALID_EVENT_SCHEMA", "retryable": false}
  ],
  "affected_days": ["2026-09-22"],
  "days_beyond_recalc_window": 0,
  "state": {"status": "published", "widget_state": {"…": "…"}, "input_revision": 42}
}
```

`state.status` values:

| Value | Meaning |
|---|---|
| `published` | The inline calculation succeeded and `widget_state` is included. |
| `pending` | The calculation failed or timed out. A job is queued and will retry. |
| `unchanged` | Nothing new was stored; the latest published state is included. |

### 5.2 Classification

Evaluated in order, inside the upload transaction, with the user row locked:

| # | Situation | Status / code | Stored |
|---|---|---|---|
| 0 | `request_id` seen before, same body hash | the stored original response | nothing |
| 0b | `request_id` seen before, different body | HTTP 409 `REQUEST_ID_REUSED` | nothing |
| 1 | Fails contract validation | `rejected`: `INVALID_UNIT`, `UNKNOWN_METRIC` or `INVALID_EVENT_SCHEMA` | a receipt with the outcome, if `event_id` is readable |
| 2 | Receipt exists, same payload hash | the receipt's recorded outcome and code, e.g. a retried conflict returns `conflict` again | nothing |
| 3 | Receipt exists, different payload hash | `rejected` `CLIENT_EVENT_ID_REUSED` | nothing |
| 4 | Delete for a record that's already tombstoned | `duplicate` | a receipt → the existing tombstone |
| 5 | Identical provider version already stored | `duplicate` (a reimport) | a receipt → the existing version |
| 6 | Same provider identity, different content, not a delete | `conflict` `CONFLICTING_PROVIDER_RECORD` | the new version and a receipt |
| 7 | Otherwise | `accepted` | the version and a receipt |

"Identical" means equal canonical JSON excluding `event_id`, reusing Step 3's
canonical form. Earlier events in the same batch count as already stored.

If any version or coverage declaration was stored, the upload also:
- increments the revision;
- inserts the coverage declarations with that revision;
- updates `users.timezone`;
- inserts one `recalc_jobs` row with `from_day` = the earliest affected day (§8.2).

All of this commits together. If nothing changed, there's no revision and no
job, and the response has `state.status = "unchanged"`.

### 5.3 The three kinds of conflict

| Kind | Example | Outcome | Resolved by |
|---|---|---|---|
| Client ID reused | The device sends event ID *a* again with a different value | `rejected CLIENT_EVENT_ID_REUSED`; nothing stored | Never: it's a client bug; the device dead-letters it |
| Contradictory provider versions | Two versions of HealthKit sample *X* with different values | Both stored; `conflict`; the Step 3 selector quarantines *X*, so its domain/day shows no value (diagnostic `…_conflict:day`) | Only a tombstone for *X* (HealthKit replaces samples by delete + new UUID). A different replacement record is independent and doesn't clear *X*'s quarantine. |
| Conflicting step bucket | Two reads of the same step bucket at the same query time with different totals (their provider IDs differ because the ID includes the total) | Both `accepted`; `resolve_snapshot_bucket` reports the conflict, so movement is missing for that bucket | A newer, unambiguous query of that bucket |

## 6. Durable recalculation

Job flow:

1. **Enqueue:** the upload transaction inserts the job, so data and job commit together.
2. **Inline attempt:** after commit, the request runs the job, with a 10-second budget.
3. **Retry:** a background worker thread polls pending jobs every 30 seconds, and
   also at startup. It claims jobs with `SELECT … FOR UPDATE SKIP LOCKED` and
   runs them. `uv run python -m app.worker --once` does the same from the command
   line, for operations and tests.

Running a job:
1. Start one transaction and take the user's advisory lock.
2. **Coalesce:** read all of this user's pending jobs. Target revision = the
   highest; `from_day` = the earliest.
3. Capture that revision's `received_at` as `known_at`.
4. Calculate the days (§8.2), writing runs and outputs.
5. Mark every coalesced job `done`, in the same transaction.

Failure and ordering:
- **Failure:** roll back, then in a separate transaction increment `attempts`,
  store `last_error_code` and set `next_attempt_at` with backoff (30 s up to
  30 min). The job stays pending forever until it succeeds, and each failed
  attempt is logged. A crash at any point leaves the job pending.
- **Late finishers can't take over:** readers pick the highest `input_revision`,
  so a slow run for an older revision is stored but never becomes latest.
- **Coalescing** means a backlog of jobs becomes one calculation at the newest revision.

## 7. Coverage resolution (a Step 3 calculator change)

`CoverageWindow` gains `revision: int` (default 0).
`CalculationContext.covered(domain, first, last)` is changed:

1. Each window becomes a UTC interval, from its local `start_day` to the closing
   boundary of `end_day`, in its own `timezone`.
2. Each report day becomes its UTC span in the report timezone.
3. The day is covered when every instant of its span lies in some window of the
   domain, and at every instant the highest-revision window there is `complete`.
   Ties at equal revision resolve to `unavailable`, the conservative choice.

Consequences:
- **Failure then success:** an earlier `unavailable` is superseded by a later `complete`.
- **Success then failure:** a later `unavailable` supersedes an earlier `complete`.
- **Travel:** days in a new zone are checked against their true UTC span.
- **Replay:** the calculator only sees declarations with revision ≤ the input
  revision, so historical runs keep their original answer.
- **Synthetic adapter:** it passes revision 0 and one zone, so all existing
  results are unchanged. The existing tests must pass unmodified.

## 8. What a calculation loads and computes

### 8.1 Input loading

Everything is limited to revision ≤ the input revision and to the user.

**1. Measurements** whose times fall in the input range. The range is derived
from settings, not hard-coded:

```
lookback_days  = max(baseline.window_days, workout.totals_days)
                 + 1   (the overnight window starts the previous evening)
range_start    = local_day_start(day - lookback_days) - max(recent_hours, 24h)
range_end      = effective_at
```

**2. Every tombstone** for the user, whatever its date. There's one per deleted
record, so the set stays small.

**3. Every version** of any provider identity that appears in (1), whatever its
date, so a conflict is never half-loaded.

**4. Coverage declarations** for the domain windows overlapping the range.

A property test proves the loader is sufficient. For every corpus checkpoint,
calculating from the loaded subset equals calculating from all stored events.

### 8.2 Which days, at which times

1. **Affected days.** The earliest local day touched by the upload:
   - point: the day of `observed_at`;
   - interval or workout: the day of `start_at`;
   - snapshot: its `day`;
   - delete: the day of the stored target, else the receive day;
   - coverage: its `start_day`.
2. **Days recalculated** run from that day to today, clipped to 35 days
   (decision 15).
3. **Past days** use `effective_at` = the closing boundary. Today uses
   `effective_at = known_at`.
4. **Known time.** `known_at` is the revision's `received_at`, and every run
   must satisfy `known_at ≥ effective_at`. A past day's boundary is before
   `known_at` by definition; today uses equality.

## 9. Day rollover and finalization

- **Finalized day.** A day is finalized by a `finalize` run at its closing
  boundary, with a revision received after that boundary.
- **The sweep.** Every worker poll checks each user's local days. For each day
  whose boundary has passed and that has no run at or after the latest
  revision's boundary, it enqueues a `finalize` job.
- **Result.** Yesterday gets its end-of-day state shortly after midnight even if
  no upload arrives. Later corrections re-finalize it (§8.2).
- **`GET /v1/state/current`** returns the latest published state (§3 decision 13) for any day:

  ```json
  {"day": "2026-09-22", "is_today": false, "effective_at": "…", "input_revision": 42,
   "health_state": {"…": "…"}, "widget_state": {"…": "…"}}
  ```

  - `is_today` compares `day` with today in the user's zone.
  - Staleness display stays with the widget (Step 15), which reads
    `freshness.last_updated_at`.
  - 404 `NO_STATE_YET` is returned only when the user has never had a published
    state.

## 10. Replay (Step 8)

```bash
uv run python -m app.replay runs    --user dev --from 2026-08-01 --to 2026-09-22
uv run python -m app.replay rebuild --user dev --from 2026-08-01 --to 2026-09-22 [--cutoff-revision N]
```

**`runs` (exact replay):**
- For every recorded run in the range, it re-executes the calculation. It uses
  the same context, the input revision, the configuration snapshot by hash, and
  loading per §8.1.
- It compares report, state and widget JSON with the stored outputs, ignoring
  operational fields (`run_id`, `job_id`, `created_at`).
- Runs recorded under a different feature, engine or presentation version than
  the running code are reported as `not reproducible with this code`.
- It exits non-zero on any mismatch, printing the differing fields.

**`rebuild` (daily summaries):**
- It computes each day in the range at its closing boundary, with the cutoff
  revision (default: the latest). Days whose closing boundary is after that
  revision's `received_at` are skipped with a note, which keeps
  `known_at ≥ effective_at`.
- It writes `rebuild` runs. The unique key makes a second rebuild add nothing,
  with identical outputs (G1 §52).
- It never deletes history. Rebuilding after deleting all derived rows
  reproduces the daily summaries.
- It does not recreate intraday runs; `runs` covers those while their ledger rows exist.

Both commands take the user's advisory lock, one transaction per day.

## 11. API (Step 7)

| Method and path | Returns | Notes |
|---|---|---|
| `POST /v1/health/sync` | §5.1 | 200; 401 bad key; 409 reused `request_id`; 413 too large; 422 bad envelope (sanitized); 503 + `Retry-After` when the database is unavailable |
| `GET /v1/state/current` | §9 | 404 `NO_STATE_YET` only if a state never existed |
| `GET /v1/state/{day}` | The latest run output for that day (highest input revision, then run ID), with `finalized: true/false` | 404 if none; 422 on a malformed date |
| `GET /v1/debug/features/{day}` | The latest CalculationReport for that day | Development only |
| `GET /healthz` | Database status | No key; no health data |

Runtime settings come from environment variables:

| Variable | Meaning |
|---|---|
| `DATABASE_URL` | Default: the Compose database on port 5433 |
| `HOMEOSTAT_API_KEY` | Required at startup |
| `HOMEOSTAT_DEV_USER_ID` | The single development user |
| `HOMEOSTAT_ENV` | `development` enables the debug endpoint |
| `HOMEOSTAT_CONFIG` | The settings file |
| `HOMEOSTAT_WORKER_INTERVAL_SECONDS` | Default 30; 0 disables the thread, for tests |

The clock is an injectable dependency.

## 12. Logging and errors

- **Upload log:** one JSON line per upload, with only `request_id`, revision,
  counts per status, event types, affected days, `days_beyond_recalc_window`,
  state status and HTTP result.
- **Job log:** one line per job attempt, with job ID, kind, target revision,
  days, duration, versions, outcome and error code.
- **Never logged or echoed:** payload values, record IDs or event IDs, in logs,
  responses or error bodies. Validation errors return only codes and field paths.
- **Enforced by tests:** they capture logs and error bodies for a full scenario
  upload and for malformed input, and assert that no value or ID appears.

## 13. Files

```text
backend/alembic.ini
backend/migrations/env.py, versions/0001_initial.py
backend/app/runtime.py    # environment settings, clock
backend/app/db.py         # tables, engine, locks
backend/app/store.py      # versions, receipts, coverage, runs, outputs, config snapshots, loaders (§8.1)
backend/app/ingest.py     # request idempotency, classification, revision, job enqueue
backend/app/recalc.py     # job claim, coalescing, day selection, runs, finalize sweep
backend/app/worker.py     # background thread and the --once CLI
backend/app/main.py       # FastAPI app, routes, auth, sanitized errors, logging
backend/app/replay.py     # runs and rebuild
backend/Dockerfile; docker-compose.yml (+ api)
backend/tests/db/, tests/api/, tests/replay/
```

Changes to existing code:
- `app/features/models.py`: coverage revision and UTC-span resolution (§7).
- `app/presentation.py`: `PRESENTATION_VERSION`.

## 14. Implementation order

1. The coverage resolution change (§7) with its tests. All 3,496 existing tests
   must still pass.
2. `runtime.py`, tables, migration and test-database fixture. Gate: upgrade,
   downgrade, upgrade; no autogenerate difference.
3. `store.py`: round trips, and the loader sufficiency property test (§8.1).
4. `ingest.py`: every §5.2 row, revisions and job enqueue.
5. `recalc.py` and `worker.py`: coalescing, ordering, retry and the finalize sweep.
6. `main.py`: endpoints, auth, limits, sanitized errors and logging.
7. `replay.py`.
8. Docker; README, `Next_steps.md` and this plan's result section.

## 15. Tests and completion gate

**Database tests** use a throwaway `homeostat_test_<random>` database on the
Compose server. They fail clearly if it's unreachable. `pytest -m "not db"`
runs the rest.

**Migrations:**
- Upgrade on an empty database, downgrade, upgrade again.
- The schema matches the table definitions (no autogenerate difference).

**Coverage:**

| Case | Expected |
|---|---|
| unavailable → complete | the day is covered |
| complete → unavailable | the day is not covered |
| Overlapping windows at different revisions | the latest revision wins per instant |
| An equal-revision tie | not covered |
| Travel: Chicago windows, Los Angeles report day | covered only where the UTC span is covered |
| A DST day | its 23- or 25-hour span is checked |
| Replay at an older revision | sees the old coverage |

**Ingestion:**
- Every §5.2 row.
- A retried conflict returns `conflict`.
- Reimport receipts: a later reuse of a reimport's client ID with different
  content gets `CLIENT_EVENT_ID_REUSED`.
- The same `request_id` gives an identical response and no new rows; a
  different body gets 409.
- Duplicates within a batch.
- Offset and metadata-order equivalence.
- A 501-event request gets 413.
- A database outage gets 503 with nothing committed.

**Conflicts:**
- Contradictory provider versions are quarantined.
- A different replacement record does *not* clear the quarantine.
- A tombstone does.
- A conflicting step bucket is resolved by a newer query.
- A conflict is never reported as `duplicate`.

**Loading:**
- Loader sufficiency on every corpus checkpoint.
- A tombstone received 60 days after its sample still applies.
- Conflicting versions with different dates are both loaded.

**Concurrency and durability:**
- Two threads upload for one user at once: revisions are gap-free, and each
  upload's rows carry its revision.
- A slow run for an older revision finishes after a newer one: the newer stays latest.
- A calculation that fails after the upload commits leaves the job pending; the
  worker completes it later.
- A simulated crash between commit and calculation (process killed) leaves the
  job pending; after a restart the worker publishes the state.
- A lost response, resent with the same `request_id`, returns the same response.
- Coalescing: three pending jobs become one run at the highest revision.

**Day rollover:**
- After midnight, `/state/current` returns yesterday's state with `is_today: false`, not 404.
- The sweep finalizes yesterday without an upload.
- 404 only for a user with no state.

**User isolation:** with two users in storage, no load, receipt, revision, job
or run crosses users.

**End to end through the API:**
- For every synthetic scenario and the demo, deliveries are POSTed in order with
  the fixed clock. Then, for each checkpoint, the stored run computed at that
  checkpoint's revision must equal `app.pipeline.run_checkpoint`, byte for byte.
  So all 137 state and widget expectations pass through PostgreSQL.
- The same holds with every request resent, and with same-time batches shuffled.

**Replay:**
- `runs` verifies everything built through the API.
- It detects a manually edited output.
- It reports a changed presentation version as not reproducible.
- `rebuild` twice adds zero rows the second time, with identical outputs.
- `rebuild` never produces `known_at < effective_at`.
- Rebuilding after deleting all derived rows reproduces the daily summaries.

**Logging and errors:** no health value or record/event ID appears in logs,
responses to malformed input, or 422 bodies.

**Regression:** all existing tests pass. Only the §7 coverage change touches
existing code, and existing results are unchanged.

Complete when all of the above pass. This also satisfies `Next_steps.md` §E:
retries and ordering are safe, migrations are fresh, replay is identical, and
conflicts are never duplicates.

## 16. Result

All gates in section 15 pass. The full suite has 3,642 tests (146 new: 33 database,
99 API, 6 replay and 8 coverage), and all earlier results are unchanged.

What was verified:

- **End-to-end parity.** All 44 scenarios, both in delivery order and with
  every request resent and same-time batches shuffled, plus the whole demo, go
  through HTTP and PostgreSQL. At every checkpoint the features, health state and
  widget are byte-identical to the in-memory pipeline. All 137 state and widget
  expectations therefore also hold end to end.
- **Durability.** A real killed process between the upload commit and the
  calculation leaves the job pending, and the worker publishes it. Failures back
  off and retry. Pending jobs coalesce. A late run for an older revision never
  becomes latest. Six concurrent uploads get gap-free revisions.
- **Replay.**
  - `runs` confirms every recorded run and catches an edited output.
  - `rebuild` twice adds nothing, never violates `known_at ≥ effective_at`, and
    reproduces the summaries after all derived rows are deleted.
- **Container.** It builds, migrates, serves, and passed a live upload of the
  `typical` scenario.

Refinements made during implementation:

- **Loader (§8.1).** Features keep the most recent workout however old it is,
  so the loader also fetches the latest older workout that isn't tombstoned or
  conflicted, plus anything overlapping it. The sufficiency test covers this.
- **Finalize sweep.** It starts from the user's earliest calculated day, not
  from `users.created_at`, because a database-side clock must not decide which
  days need finalizing.
- **Inline budget setting.** `create_app(inline_budget_seconds=...)` lets the
  end-to-end test defer all work to the worker. That is the same path a timeout
  takes.

Known follow-ups:

- **Step 9-13 handoffs.** `Step_9_13_plan.md` §3 needs two backend additions:
  - partial-day coverage (explicit UTC spans evaluated only through the effective
    time), since a whole-day declaration made at 13:00 overclaims the rest of
    that day;
  - a versioned lost-anchor reconciliation protocol.

  Both need schema and API changes and are not part of this milestone.
- **Test warnings.** Two deprecation warnings come from Starlette's test client
  and httpx, not from this code.
- **Test duration.** The full suite takes about 4 minutes, mostly API parity.
  `pytest -m "not db"` runs in 15 seconds.

## 17. Risks and follow-ups

- **Full recomputation of up to 35 days per job.** It's simple and correct;
  optimize later only if replay stays identical.
- **One development user and key.** Replace before any external beta.
- **Device-reported coverage is trusted.** Steps 9-13 must declare `complete`
  only after a query finished.
- **Corrections older than 35 days** need an explicit `rebuild`; the response
  counts them.
- **Receipts and run history grow without limit.** Retention policies come later
  and must keep replay possible for any retained run.
