# G1 Steps 9–13 — HealthKit import and durable iPhone synchronization

Status: **Implemented; real-iPhone gates pending.** See §12 for results.

Prepared: 2026-09-24. This is a planning document, not an implementation report.
The iOS app currently shows the starter screen. HealthKit, background-delivery
and App Group entitlements are present; GRDB 7.11.1 is already resolved.
Backend storage work is appearing in the workspace, but the complete Steps 6–8
HTTP/replay acceptance gate has not been verified for this plan. Integration
must target its tested API contract, not assume the draft is already deployed.

## 1. Outcome

An iPhone can read supported Apple Health data, save it locally before upload,
send it safely to Homeostat, and display the returned state in a debug screen.
Network loss, process termination, duplicate deliveries and deleted samples
must not silently lose data or corrupt the server's history.

| Step | Deliverable | Completion evidence |
|---|---|---|
| 9 | Minimal app, authorization-request tracking and debug screen | Visible samples and sync status on a real iPhone |
| 10 | Initial import of approximately 35 days | All supported types normalized and durably queued |
| 11 | Incremental updates, deletions and anchor recovery | Updates survive restart and reach the backend correctly |
| 12 | GRDB queue and atomic anchor persistence | Offline/crash tests show no lost records |
| 13 | HTTP upload, acknowledgements and state retrieval | Real records produce backend state visible in the app |

Implementation order differs from the numbering: **9 → queue foundation from
12 → 10 → 11 → finish 12 → 13**. No import is allowed to depend on an in-memory
queue. App Group widget caching and actual widget rendering remain Steps 14–16.

## 2. Proposed scope and defaults

- Read sleep analysis, HRV SDNN, resting heart rate, workouts and step statistics.
  Request no write access and never modify the user's HealthKit records.
- One configured development backend/user. Partition local sync state by backend
  and account identity; changing either must not send an old queue to a new user.
- Bootstrap 35 prior local days plus the current partial day. Include a one-day
  overlap for overnight sleep and interval boundaries.
- Page sample queries, initially 250 results per page. Persist progress after
  each page. Page limits and wire batch limits are separate settings.
- Upload at most 250 events and 4 MiB of encoded JSON per request, below the
  planned server limits of 500 events and 5 MB.
- Maintain one uploader and serialize imports per HealthKit type. Coalesce
  observer, foreground and manual-sync triggers.
- Retry temporary failures with exponential backoff and jitter: 2 seconds to
  5 minutes; honor a longer server `Retry-After`. Persist the retry schedule.
- Do not promise a background delivery interval. App launch/foreground and a
  manual Sync action always provide a catch-up path.

## 3. Backend handoff — freeze before real upload

Use the revised Steps 6–8 contract: immutable `request_id`, `device_timezone`,
events, coverage, per-event result indexes/IDs, input revision and state status
(`published`, `pending`, `unchanged`). Generate shared request/response examples
from the implemented server and test Swift decoding against them.

Two additions need explicit backend agreement during implementation:

### A. Coverage for a partial day

The current backend plan describes coverage using whole local dates. A query
completed at 13:00 cannot establish coverage through the future closing boundary.
Extend query evidence to include an explicit UTC start/end, query completion
time and a stable declaration ID. The server evaluates coverage only through
the calculation's effective time for the current day. Historical whole-day
declarations remain expressible. Version and test this contract change.

Coverage means a successfully completed query of data visible to this app,
after authorization was requested. It is not proof that every real-world event
is visible. Distinguish query failure/interruption from a successful empty query.
Do not emit complete coverage until all pages are persisted locally and the
corresponding events have server acknowledgements. Upload the coverage marker
after those batches, or atomically with their final batch. A quarantined item
must not silently count as successfully imported coverage.

### B. Lost-anchor reconciliation

A fresh scan can show which records are currently visible, but an absent UUID
alone does not prove deletion. Never fabricate `DeleteEvent` from absence.

Propose a versioned reconciliation protocol, scoped to installation, account,
type, fixed query predicate and UTC interval: `begin generation → upload visible
membership → finalize generation`. Finalization requires all pages and member
uploads acknowledged. It atomically supersedes the previous visible membership
inside that scope while preserving historical versions for replay. Records no
longer visible are marked withdrawn from that visibility scope, not HealthKit
tombstoned. An interrupted scan never finalizes, and reappearing records can
return to membership. Other types, scopes and installations remain untouched.

This requires explicit server storage/API/replay support beyond the existing
event-only sync envelope. Agree its schema and test it with a fake adapter
before implementing recovery. If it is deferred, report recovery as incomplete
and do not claim the G1 lost-anchor/deletion gate has passed.

## 4. Step 9 — app, authorization and device validation

### App setup

- Verify signing, provisioned HealthKit/background capabilities and usage text.
  The current deployment target is iOS 27.0; check the actual test phone and
  installed SDK before choosing a lower target. Do not silently change it.
- Check `HKHealthStore.isHealthDataAvailable()` and show an unsupported-device
  state when appropriate.
- Explain which data is read and that it will be sent to the configured backend
  before enabling upload. Separate reading permission from enabling server sync.

### Authorization ledger

Persist per-type `not_requested`, `requested`, and whether visible data has been
seen, plus request/error timestamps. Do not label a read permission as granted
or denied based on query results or the authorization request's success value.
Respect any supported limited-history access boundary; request only the visible
range and keep older days unknown. Recheck availability when the app returns
to the foreground. [Apple authorization documentation](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data).

### Debug screen

Show request history, visible sample counts/ranges, import progress, last local
query, pending/failed/conflicted queue counts, last server acknowledgement,
backend revision, pending calculation status and returned health/widget text.
Distinguish “No data visible yet”, query error, offline and awaiting calculation.
Health values may appear on this user-visible screen; logs contain status/counts
and sanitized error codes only. Never display the API key.

### Device verification gate

Inspect real samples before freezing normalization:

- HRV/RHR original start/end times and when their records become visible.
- Source bundle ID, product type, revision, timezone metadata availability.
- Sleep stage values and overlapping sources; paused workout duration.
- Hourly statistics boundaries, empty statistics and revised step totals.

Confirm the backend's point `observed_at` policy and original-sample-end cutoff
using this evidence. Document any necessary adapter/calculator/version change;
do not invent a shorter sample interval to pass validation. Keep raw device
exports out of Git; use anonymized or hand-authored regression fixtures.

## 5. Durable local foundation — Step 12, built early

Use an app-private GRDB database with migrations and serialized transactional
writes. Store it in Application Support with iOS data protection; test locked
device behavior, and retry when protected storage is unavailable. Configure
backup exclusion for imported health data. Keep the development API key in
Keychain and out of the SQLite payloads and repository.

| Table | Purpose |
|---|---|
| authorization_ledger | Request/visible-data history by type |
| import_sessions | Fixed predicate, timezone, bounds, generation and page progress |
| query_anchors | Securely encoded anchor by type/predicate version/store generation |
| provider_records | UUID, type, canonical hash, original interval and queued/acknowledged identity |
| event_outbox | Immutable canonical event bytes, stable client ID, state and error code |
| coverage_outbox | Query evidence and dependencies on imported event pages/batches |
| upload_requests | Exact request body, request ID, hash, included outbox IDs, attempt schedule |
| sync_state | Backend/account scope, acknowledged revision, last returned state and recovery markers |

Outbox lifecycle: `pending → assigned to persisted request → acknowledged`.
Terminal rejection becomes `dead_letter`; conflict becomes an acknowledged
conflict record retained for diagnosis. Preserve enough provider identity and
receipts after removing delivered outbox bodies to avoid repeated new events.

**Atomic invariant:** normalize a returned page, insert its events and provider
index updates, and save its new anchor in the same database transaction. If
any of those fail, roll back all of them. Never advance an anchor based on
network success or before durable local persistence. GRDB transactional writes
support this boundary. [GRDB transaction API](https://github.com/groue/GRDB.swift/blob/master/GRDB/Core/DatabaseWriter.swift).

An unencodable/unsupported sample must be recorded in a durable local quarantine
with sufficient fields for later repair before its page can be checkpointed;
otherwise retain the old anchor. Surface the issue and suppress complete
coverage for the affected import scope. Never silently skip it.

## 6. Step 10 — initial import and normalization

### Sample types

Use paged anchored queries for sleep, HRV, RHR and workouts, starting without an
anchor. Choose a fixed lower-bound predicate with interval-overlap semantics;
do not slide that predicate forward while reusing its anchor. Store the exact
predicate version with the anchor. New data observed during bootstrap is handled
by draining subsequent anchored pages after registration of observers.

Map to existing canonical contracts:

- `HKSample.uuid` → provider `source_record_id`; allocate client event UUID once
  on local insertion and reuse it on every retry.
- HRV → SDNN milliseconds; RHR → beats/minute. Preserve original sample times.
- Sleep → individual in-bed, awake and supported asleep-stage intervals. The
  phone does not choose a winning source or calculate sleep duration.
- Workout → completed workout interval, type and recorded active duration.
- Preserve source name/bundle, revision/product type when available, timezone
  and its provenance; stringify supported additional metadata consistently.
- Explicit HealthKit deleted UUID → `DeleteEvent`, with `deleted_at` when the
  adapter first observes it. Persist that timestamp so retries cannot change it.

Cross-language contract tests must verify enums, units, UTC timestamp precision,
nil fields, metadata ordering and snapshot identity strings. Python's exact
snapshot ID formatting must be matched, not approximated with Swift's default
ISO formatter. All emitted payloads must validate through the Python contracts.

### Step history

Use HealthKit statistics rather than uploading raw step samples. Obtain regular
hourly history with `HKStatisticsCollectionQuery`; produce cumulative totals
from each local day's opening boundary through each completed hourly boundary,
plus its closing boundary. Current steps use a statistics query through now.
Query execution time is `queried_at`; the historical boundary is `as_of`, even
when many past buckets are backfilled in one run.

Anchor the collection query using an explicit calendar/timezone, verify its
boundaries, and compare sampled cumulative results with direct statistics
queries. Avoid raw-source summation. Preserve repeated-hour UTC instants during
fall-back and the first valid next-day boundary when midnight is skipped.
Empty successful statistics mean no steps visible to this query; failed queries
must not emit zero totals. [Apple statistics query documentation](https://developer.apple.com/documentation/healthkit/hkstatisticscollectionquery).

For bootstrap, record the chosen device zone as query provenance; it does not
prove where the person was historically. Preserve old snapshots in their own
zones after travel. Never relabel earlier buckets when the device zone changes.

## 7. Step 11 — incremental updates and recovery

- Register observers early on app launch and request supported background
  delivery. Observers trigger a drain; anchored queries supply sample changes
  and deleted UUIDs. One serial drain per type prevents anchor races.
- Persist every page and anchor transactionally, then invoke the observer's
  completion handler exactly once for that callback. Do not wait for an HTTP
  upload. On error/expiration, retain prior anchor and a catch-up marker, finish
  the callback, and retry at the next allowed opportunity. Background execution
  is an optimization; foreground catch-up remains required.
  [Apple observer guidance](https://developer.apple.com/documentation/healthkit/executing-observer-queries).
- Securely archive/unarchive anchors; corrupt/unsupported anchors trigger
  recovery, never a silent reset that discards pending uploads.
- HealthKit step changes trigger statistics refreshes, not raw step uploads.
  Refresh today and the prior day when notified; run a rolling 35-day hourly
  reconciliation at bootstrap and once per local day on foreground. An explicit
  Refresh History repeats it. Older corrections require a wider manual recovery.
- Save refresh progress and query times before enqueuing immutable snapshots.
  New totals, including decreases, become new observations. Rate-limit/coalesce
  refreshes so duplicate observer callbacks cannot create unbounded uploads.
- Anchor recovery uses the scoped generation protocol in §3B. Reconcile visible
  membership as well as additions; do not assume rebootstrap is append-only.
- Database loss/reinstall requires a new store generation, bootstrap and server
  reconciliation. A new Keychain credential alone is not proof that old local
  anchors/provider indexes still exist.

## 8. Step 13 — HTTP upload and returned state

Persist exact encoded request bytes and `request_id` before starting URLSession.
A retry uses those bytes, including the original timezone and coverage; it does
not rebuild the request from today's queue. New changes wait for a new request.

| Result | Device action |
|---|---|
| `accepted` / `duplicate` | Acknowledge that event locally |
| `conflict` | Remove from retry queue; retain receipt and show conflict status |
| `rejected` | Dead-letter with code; correction creates a new client event ID |
| Timeout, connection loss, 429, 5xx | Keep exact request and retry with backoff |
| 401 | Pause upload; show credential/configuration error |
| 409 request-ID reuse | Pause affected request; surface a protocol defect |
| 413 | After a definitive rejection, split into new persisted requests with new request IDs; keep event IDs |
| 422 envelope error | Quarantine request; repair deliberately, not an endless automatic retry |
| Malformed/incomplete response | Acknowledge nothing; retain request and report protocol error |

Validate response request ID, result count, each index and event ID before one
transaction applies all local acknowledgements. A crash before local commit
resends the original request and receives the server's recorded response.

State publication is independent of event acknowledgement. `pending` is not an
upload failure. Poll `/v1/state/current` while the app is active, with bounded
backoff, then stop and check on the next foreground/manual sync. Replayed upload
responses may permanently say pending; do not use them as a live status query.
Accept only a state at least as new as the last stored server revision/run order.
If the API lacks that ordering token, add it before implementation. Keep the
last valid app-visible state on failures and display its age/status.

Development connection settings: explicit base URL and Keychain API key. A real
iPhone needs the Mac's reachable LAN hostname/address, not its own `localhost`.
Prefer HTTPS; if local HTTP is used, scope the exception to Debug development
and configure local-network usage text. Do not ship a broad release ATS bypass.

## 9. Suggested files

Under the existing app target, create small components as responsibilities grow:

```text
HealthKit/HealthKitClient.swift, HealthKitAdapter.swift, StepStatisticsReader.swift
Storage/LocalStore.swift, Migrations.swift, Outbox.swift
Sync/ImportCoordinator.swift, SyncCoordinator.swift, BackendClient.swift
Models/CanonicalEvent.swift, SyncContracts.swift, ReturnedState.swift
Views/OnboardingView.swift, DebugView.swift
HomeostatTests/   # add an iOS unit-test target and scheme configuration
```

Inject query, HTTP and clock protocols for tests. Keep calculation logic in the
backend. Add Swift models only for canonical uploads, sync envelopes and returned
state needed by this screen; shared widget cache/decoding integration stays in
Step 14. Reuse the installed GRDB package rather than replacing it.

## 10. Implementation and acceptance gates

1. **Freeze handoffs:** server wire examples, partial-day coverage, reconciliation
   generation protocol, state ordering and limits. Device/SDK compatibility check.
2. **App + local store:** onboarding/debug UI, ledger, migrations, Keychain
   settings, queue/anchor atomicity and fake query/HTTP tests.
3. **Bootstrap:** real-device sample inspection, normalization and hourly steps;
   validate Swift-produced event fixtures against Python contracts.
4. **Incremental import:** observers, anchored paging, deletions, restart and
   anchor recovery. Inject crashes before/after every commit boundary.
5. **Upload:** immutable requests, per-event acknowledgements, retries and
   pending-state polling against the actual Steps 6–8 backend.
6. **Device demonstration and documentation:** record reproducible commands,
   supported SDK/device, known limitations and the actual test results.

Required tests:

- Offline bootstrap, terminate/relaunch, reconnect: every persisted record is
  eventually acknowledged once logically, even when transmitted repeatedly.
- Kill during query-page commit and during acknowledgement commit: anchor and
  queue remain consistent. Test disk-write failure and protected-data lockout.
- Lost HTTP response, same request replay, partial event rejection, conflict,
  missing/duplicate result indexes, 401/409/413/422/429/503 and pending calculation.
- Coverage is withheld for unfinished or quarantined pages and unsent chunks;
  coverage-only and timezone-only requests are supported and idempotent.
- Delete before original, explicit replacement, reimport, corrupt anchor,
  interrupted reconciliation, successful empty query and reduced visibility.
- Hourly backfill executed at irregular times, downward corrections, spring/fall
  DST, skipped midnight, travel and fractional-second snapshot ID parity.
- HRV/RHR long intervals and irregular readings match the verified device policy.
- Two concurrent sync triggers do not duplicate request assignment or race anchors.
- No sensitive payloads/API keys in logs, and no read-denied inference in the UI.
- On a real iPhone: import available history, observe an actual HealthKit change,
  sync it, and display backend state. Record background catch-up limitations
  separately from deterministic simulated failure tests.

**Complete only when:** real supported HealthKit data reaches the backend,
offline/restart tests preserve it, deletion and recovery behavior is demonstrated,
and returned state appears in the app. At that point the remaining G1 milestone
is Steps 14–16: App Group cache, real widget rendering and full acceptance.

## 11. Approval

Approval is for this scope, implementation order and proposed defaults. Backend
contract additions in §3 must be made concrete and tested before real-data
upload. No iOS or backend implementation is authorized by creation of this draft.

## 12. Implementation result (2026-09-25)

**Decisions taken while implementing:**

- §3A partial-day coverage is **implemented**. Coverage takes either whole days
  (`start_day`/`end_day`) or exact instants (`start_at`/`end_at`), never both
  (migration `0002_partial_day_coverage`). A timezone-only change bumps the
  revision and recalculates today.
- §3B lost-anchor reconciliation is **deferred**. A corrupt anchor starts a new
  query generation and re-reads visible records. Duplicates collapse on the
  server, but deletions are not inferred from records that are missing. **The
  lost-anchor deletion gate is not passed.**
- `run_id` was added to state responses as the ordering token after
  `input_revision`.
- Step snapshots are queued only when a bucket total changes.

**Layout:**

- `ios/HomeostatCore` (a local Swift package) holds everything that doesn't need
  HealthKit: canonical events, normalization, the GRDB store and outbox, the
  sync and import engines, and their tests.
- The app target adds `HealthKit/HealthKitSource.swift`, `App/AppModel.swift`,
  `App/Keychain.swift` and `Views/DebugView.swift`.

**Verified:**

- `swift test` in `ios/HomeostatCore` passes all 38 tests. They cover offline
  bootstrap and relaunch, lost responses, 401/409/413/422/429/5xx handling,
  concurrent triggers, corrupt anchors, DST and skipped-midnight step ladders,
  and corrections.
- The fixtures work in both directions. Swift-made events validate against the
  Python contracts (`tests/api/test_wire_fixtures.py`), and server responses
  decode in Swift.
- The backend suite passes all 3,651 tests.
- The app builds and launches on the iPhone 18 Pro simulator (iOS 27).

**Not yet verified (needs the user on a real iPhone):**

- Inspecting real device samples, including the HRV/RHR interval shapes.
- An observed HealthKit change reaching the backend and showing up in the app.
- Background delivery behavior.
- Kill-during-commit and protected-data lockout, which were tested only through
  the store's atomic transactions.

**Running it:**

1. Start the backend (see `backend/README.md`).
2. In the app, open Settings and enter the backend URL. In the simulator it is
   `http://localhost:8000`; on a phone, use the Mac's LAN address and start
   uvicorn with `--host 0.0.0.0`.
3. Enter the API key there too.
4. Turn on sending, then tap **Request Health access** and **Sync now**.

## 13. Review fixes — 2026-09-25

The code review findings are addressed as follows:

- **Coverage timing:** the backend calculates today's result at the common
  completed import cutoff, retains receipt time as `known_at`, and records both
  for replay. Step coverage ends at the statistics query's requested cutoff,
  never its later completion time.
- **Lost anchors:** resets are per sample type. A durable incomplete marker and
  `unavailable` coverage are queued immediately, including when the fresh query
  fails. Later imports continue to declare that domain unavailable. Complete
  deletion reconciliation remains deferred; a fresh query alone cannot clear
  this marker, and missing records are never treated as inferred deletions.
- **Repairable quarantine:** retain the raw sample, original unknown category
  value, numeric values, source metadata and interval before checkpointing.
  Reprocess unresolved rows on catch-up after normalizer upgrades; successful
  normalization or an explicit provider deletion resolves them. Only unresolved
  rows overlapping a declaration suppress its complete coverage. Legacy rows
  without raw fields require a fresh provider query and remain conservative.
- **Step commits:** snapshots, coverage and the full-refresh completion marker
  commit together. Coverage describes the range actually queried; the marker is
  timezone-specific so travel prompts another full refresh.
- **Retries:** foreground tasks wake at persisted retry deadlines. They cancel
  on background, upload disable or backend/account changes; foreground startup
  resumes from SQLite. New triggers coalesce, and hitting the batch limit
  schedules continuation. State polling does not delay a scheduled retry.
- **Timezone identity:** persist the first fallback timezone for a provider UUID
  and reuse it when the same sample is read again. Actual measurement changes
  still create a new version for the backend to classify.
- **Batching:** budget the entire encoded request, including coverage/envelope.
  A 413 reduces the total item count, splitting coverage as well as events;
  a mixed batch never dead-letters its sole event merely for being the only event.
  Individually oversized items are retained as dead-letter/withheld diagnostics.
- **Replay:** missing outputs are detected and can be restored while preserving
  their calculation ledger entries.

Local SQLite migration `v2_repairable_imports` preserves pending requests and
provider identities, backfills fallback timezones from existing outbox bodies,
invalidates old non-atomic refresh flags, and marks earlier anchor resets or
legacy unrepairable quarantine as requiring recovery. It runs on opening the
store; no manual reset or deletion of user data is required.

These changes do not pass the real-iPhone HealthKit gates or implement the
scoped reconciliation protocol in §3B. Those remain the next validation and
implementation work before declaring Steps 9-13 complete.
