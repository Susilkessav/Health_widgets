# Homeostat — plan

Updated: 2026-10-09. **This is the one plan.** It holds where the project is,
what to do next (one checklist), the rules every change keeps and the decisions
made. What the app should be and look like is in [Product.md](Product.md).
Everything else is reference ([specs/](specs/)) or history ([archive/](archive/)).

## 1. Where we are

| Area | State |
|---|---|
| Health engine: contracts, features, state, wording | Done. Python is the reference; Swift matches all 170 parity checkpoints |
| iPhone: HealthKit import, local store, on-device calculation, widget | Done, runs with no server. Device acceptance partly open (§5 G1) |
| Background updates | App wake and unlock retry built; widget self-refresh is a probe only (§4) |
| Avatar (G2) | Built with code-drawn placeholder art. Open: final art, accessibility, acceptance (§5 G2) |
| App/widget redesign | Design studies only; nothing native. Visual direction not chosen ([Product.md](Product.md)) |
| Backend (FastAPI + PostgreSQL) | Kept, tested, optional. Not on the path from Health data to the widget |
| More sources and platforms | Deferred until G1 acceptance and a chosen second source |

Constraints (2026-09-30): free Personal Team (no TestFlight, 7-day re-signing),
LAN-only server testing, device-key + pairing-code auth when a server returns.

## 2. Rules

- **Use the phone’s current timezone by default.** Follow system timezone changes, including travel; do not fix the UI or new local-day grouping to the chat timezone. Retain original event timezone/provenance. For manual test instructions, prefer elapsed time; verify the phone timezone before giving timezone-specific clock deadlines.
- **Health data never leaves the phone to produce a result.** Upload is optional
  and only builds a history for later.
- **The widget is always correct, even when old.** It shows the last result and
  its age, dims after 90 minutes, and never shows an earlier day as today.
- **No double counting.** Re-reads, retries and a second route to the same
  record add provenance, never weight.
- **Every result is explainable** from the widget: values, sources, baselines, versions.
- **Measured, usual, intended and reported stay distinct.** Baselines describe
  usual behavior; goals are user choices; check-ins never overwrite sensor data.
  Missing readings never become zero.
- **One observation, one explanation, one optional action.** Stay quiet without
  a meaningful change.
- **Python stays the engine reference.** Engine changes land in both languages
  and keep `engine_parity.json` green. Swift alone owns the new P1 UI presentation
  wording/ranking; existing stored mapper/engine parity remains intact until that layer lands.

### What iOS allows

| Wish | iOS behavior | Consequence |
|---|---|---|
| Read Health data any time | Encrypted while the phone is locked | Reads happen when unlocked; locked attempts are deferred (§4) |
| Run every few minutes | No background timers; widgets refresh ~40–70×/day; HealthKit wakes apps at most hourly for steps | Ask for a 15–30 min widget refresh; iOS decides |
| Keep working after a swipe-away | iOS stops launching a force-quit app | The widget still refreshes; §4 path 3 relies on that |
| Refresh tasks in the Simulator | Always unavailable | Background checks happen on the iPhone |

## 3. Architecture

```
HealthKit ─► ImportEngine ─► LocalStore (GRDB, app container)
                                   │
                                   ▼
                        LocalInputs ─► Swift engine ─► HealthState ─► WidgetState + AvatarState
                                   │                                      │
                                   ▼                                      ▼
                     App Group: engine_inputs.json (§4)        App Group: WidgetCache ─► widget, app
                                   │                                      ▲
                                   └──► widget self-refresh (§4) ─────────┘
Optional: LocalStore ─► upload ─► backend (history now; result path later)
```

| Target | Contents | Linked by |
|---|---|---|
| `HomeostatShared` | Instant, WidgetState, AvatarState, cache, display policy, avatar view, probe log | app, widget |
| `HomeostatEngine` (planned, M3) | Pure Swift engine, `stepSnapshots`, input snapshot format | core, widget |
| `HomeostatCore` | GRDB store, import, outbox, sync, local calculation | app |

The widget never links GRDB and never writes the app's database. Why on-device
and when the server returns: [specs/On_device_plan.md](specs/On_device_plan.md).
Exact formulas: [specs/Calculation_and_product_review_2026_10_06.md](specs/Calculation_and_product_review_2026_10_06.md).

## 4. Background updates

Three paths keep the widget current, all writing through the same ordered cache.

| # | Path | Runs when | State |
|---|---|---|---|
| 1 | **App wake**: HealthKit background delivery, refresh task, app open | iOS wakes the app; never after a force-quit | Built |
| 2 | **Unlock retry**: a locked import is marked `import_deferred` and retried at unlock or next wake | App process still alive at unlock | Built; device evidence open (M1) |
| 3 | **Widget self-refresh**: the widget reads today's steps and recalculates itself | Each widget refresh, also after force-quit; phone unlocked | Probes only (M2); M3 not built |

### Path 3 — widget self-refresh

1. **App prepares inputs.** After each calculation the app atomically writes
   `engine_inputs.json` to the App Group: the `LocalInputs` that run used, the
   scope, a generation number and today's step buckets.
2. **Widget refreshes.** If unlocked and the snapshot is valid: query today's
   hourly steps (deadline, stoppable), build `stepSnapshots`, run the shared
   engine for now, publish under the ordering rule, then build the timeline.
3. **App stays the authority.** A widget result never replaces one built from
   newer app inputs.

Only steps are read; other domains arrive in bursts via path 1. The widget has
no health logic of its own, never writes HealthKit or the app database, never
uploads, and keeps the cached result on any failure (locked, invalid snapshot,
query error, timeout).

- **Ordering.** The app alone increments a *generation* under the cache lock and
  writes the snapshot with it. A widget result is keyed `(generation,
  steps_through)` and publishes only if the cache still holds that generation
  and its step read is newer. Every app result beats every widget result.
- **Validity.** No widget calculation when version, scope, zone, settings/engine
  identity or local day differs; day rollover is the app's job.
- **Per-domain cutoffs (D-A).** Movement is evaluated at its step read; other
  domains at their own import cutoff. A step read never advances other domains'
  timestamps or coverage.
- **Budget.** Snapshot ≤ 2 MB (36-day window, event/byte caps on write), widget
  run ≤ 3 s, peak memory under the extension limit. If a limit fails, the
  snapshot carries daily summaries instead of raw observations.
- **G1 rule amended (2026-10-06):** the widget may read today's step statistics
  and run the shared engine on app-prepared inputs; nothing else changes.
- The widget's server fetch (`WidgetClient`) stays off in on-device mode.

## 5. What to do next

**Current action: interactive review and physical background checks only.**
The user requires confirmation before implementation (latest instruction,
2026-10-09). No native, production, test or source-preview changes are authorized
by this review. Companion and separate rings remain flexible working directions.
Review results and the proposed preview-only changes are in
[Scenario_review_2026_10_09.md](specs/Scenario_review_2026_10_09.md).
The earlier start authorization does not waive this new confirmation gate.

Use this file as the only status tracker. `[x]` means the stated deliverable is
complete with evidence; `[ ]` means it remains. A completed study does not mean
the feature is implemented. Update the row, detailed checklist and §6 evidence
together when a step changes. If blocked, record the reason and next action.

| Step | Deliverable | Status | What remains / dependency |
|---|---|---|---|
| 01 | Research and initial feature/design studies | Done for the initial study | User review and later feasibility checks remain in 02/07 |
| 02 | Validate and revise the design | Review performed; gaps open | Existing interactions pass; missing scenarios and stale dimming need confirmation before changes |
| 03 | Foundation checks | Done (2026-10-09) | Swift, app/widget build and backend with PostgreSQL pass (§6) |
| 04 | iPhone acceptance and G1 close | Partly done | Device session, current replay, 24–48 h use; after 03 |
| 05 | Widget self-refresh (M3) | Feasibility passed; not built | A3 passed for one observed refresh; explicit implementation confirmation still required |
| 06 | Final avatar and G2 acceptance | Partly done | Art, accessibility, acceptance; final acceptance after 04 |
| 07 | Review implementation specification | Specified; confirmation required | Contracts written; user now requires confirmation before implementation |
| 08 | Daily loop (P1) | Not started; confirmation and acceptance gates pending | Today + Your day widget + explanations/check-in; after 04/06/07 |
| 09 | One-week P1 review | Not started | Real use, findings and fixes; after 08 |
| 10 | History, activity calendar, focused widgets (P1b) | Not started | After 09 |
| 11 | Workout logging, reflection, then planning (P2) | Later | After 10 and scope review |
| 12 | Optional goal rings and personalization (P3) | Later | After 11 and scope review |
| 13 | Food context, patterns and what-if views (P4) | Later | Input quality and scope review |

The numbers provide a tracking order, not a requirement to serialize everything:
design review and foundation verification are independent; avatar preparation
can precede G1 close; Step 05 is conditional. There is no overall percentage
because a design study and a native feature are different sizes of work.

### Step 01 — research and initial studies

**Status: initial study done; plan/start approved 2026-10-09.**
**Done when:** a reviewable catalog and exploratory app/widget designs exist.
Evidence: [Product.md §9](Product.md#9-design-evidence--2026-10-08) and §10.

- [x] Catalog initial data-backed app/widget features, surfaces and reactive rules.
- [x] Create Companion and Focus app/widget studies.
- [x] Explore GitHub-style activity history and separate/nested goal rings.
- [x] Record data gaps, freshness, privacy and accessibility design requirements.

### Step 02 — validate and revise the design (D0)

**Status: in progress; replay and state specification complete. Depends on:** Step 01.
**Done when:** real-data usefulness has been reviewed and the proposed flows
cover quiet days, new users and the required data states. Visuals stay revisable.

- [x] Replay and read available real data: 51 local-noon days (2026-08-20–2026-10-09); 29 observation headlines, 22 calibrating, 0 quiet, 0 no-data. All 51 match Swift. Method/limits: [daily-loop contract](specs/Daily_loop_contract.md).
- [x] Specify quiet-day and per-domain new-user states, without a fixed day-10 readiness promise: [daily-loop contract](specs/Daily_loop_contract.md). Interactive layout validation remains below.
- [x] Record Companion and separate rings as working directions from the selected studies; user approved starting the plan.
- [ ] Refine the activity calendar/ring layouts as their phases approach; keep visuals revisable.
- [x] Review existing interactive scenarios against [Product.md §7](Product.md#7-phases-and-acceptance); record passes and unrepresented cases in the [review](specs/Scenario_review_2026_10_09.md).
- [ ] Confirm the proposed preview-only changes, add the missing scenarios and re-review them; review completion is not full scenario acceptance.
- [x] Record user feedback: proceed with the plan; Companion/separate rings as working options, no frozen design.

### Step 03 — finish foundation checks (formerly Step 0)

**Status: done (2026-10-09).** Checks and evidence are recorded in §6.
**Done when:** all checks below pass and their evidence is recorded in §6.

- [x] `StepProbe`: no samples ≠ 0 steps; stop the query at the 5 s deadline; log widget memory.
- [x] Snapshot probe compares the full result (revision, effective time, HealthState, WidgetState).
- [x] Write the snapshot from the run's own `LocalInputs` (`LocalStore.LocalRun`), not a second read; log event count and oldest event date.
- [x] `swift test`, app/widget simulator build, commit the M1/M2 probe work.
- [x] Backend database-backed tests (PostgreSQL via `docker compose up -d db`).

### Step 04 — verify the existing app and close G1

**Status: partly done; current-build device checks remain. Depends on:** Step 03.
**Done when:** session A is recorded and required G1 checks, the current-build
replay and normal-use checks pass. Record the M2 decision separately; an A3
failure stops M3, not G1 acceptance on paths 1–2.

#### Device session A (M1, M2, G1 device rows)

Read the Debug view's background and probe logs after each round, outside the
debugger where possible. Note device, iOS, power and network.

- [ ] **A1** app running, unlocked, walk: observer delivery, import, calculation; widget step reads (value / no samples / error / timeout, ms, MB). Partial 2026-10-09: background step observer/import/calculation seen at 13:29 CDT; widget visible at 13:51 matches the 13:49 background result. Original walking conditions and widget probe outcomes remain open.
- [ ] **A2** app running, locked 30+ min, walk, unlock: `protected data` lines, `import failed … 6`, whether unlock retry runs (M1). Partial 2026-10-09: locked errors/deferred retry at 13:40; unlock retry, successful imports and cleared deferred flag at 13:49; visible widget updated. Recovery verified, but lock interval was ~12 min, not 30+.
- [x] **A3 — M2 feasibility gate:** force-quit, unlocked widget read succeeded at 2026-10-09 19:19:26 UTC during the confirmed closed-app window: 115 steps, 36 ms, 9.1 MB. Verified from existing Debug UI. One observed refresh; repeated reliability and M3 behavior remain unproven.
- [ ] **A4** app force-quit, locked: locked widget read behavior
- [ ] **A5** lldb background-task trigger (G1 row)
- [ ] **A6** no new data 2 h: last result kept, dims after 90 min, recovers (G1 row)
- [ ] **A7** reinstall, delete a sample, re-import: lost-anchor demo (G1 row)
- [ ] Also record snapshot KB, events, calculation ms, footprint.

**Gate:** if A3 fails, record it, drop path 3, and close G1 on paths 1–2.

#### G1 close (paths 1–2, D-B)

- [x] Install, Health access and 35-day import — 2026-09-25.
- [x] Real widget result; tap opens the explanation — 2026-09-25.
- [x] Historical device replay: 1,365 / 1,365 identical — 2026-09-25.
- [x] Repeat replay from the connected phone with current engine code: stored phone HealthState/WidgetState match Python; all 50 standard checkpoints match Swift (2026-10-09). Physical background acceptance remains separate.
- [x] Confirm a new background result reaches the visible widget without opening the app — 2026-10-09 unlock/observer imports at 13:49, run 541/revision 2046, matching Home Screen widget at 13:51. Full timed A1/A2 and M2 checks remain open.
- [ ] Confirm background refresh task — evidence from A5.
- [ ] Confirm stale-result handling and recovery — evidence from A6.
- [ ] Confirm lost-anchor recovery — evidence from A7.
- [ ] Complete 24–48 h of normal use outside the debugger after session A.
- [ ] Record G1 acceptance and the A3/M2 pass-or-stop decision in §6.

### Step 05 — conditional widget self-refresh (M3)

**Status: not built; A3 feasibility passed 2026-10-09. Depends on:** explicit implementation confirmation. A single successful probe does not establish M3 reliability or acceptance.
**Done when:** implementation, tests and the device exit below pass. If A3 fails,
mark this step **Not proceeding**, record why, and continue without path 3.
This step does not block G1, G2 or the basic Your day widget.

- [ ] Per-domain cutoffs in Python then Swift; regenerate fixtures (`UPDATE_WIRE_FIXTURES=1`); parity green.
- [ ] Split `HomeostatEngine` out of `HomeostatCore` (no behavior change).
- [ ] App-owned generation ordering, written with both the cache and the snapshot.
- [ ] Snapshot v1: versioned; scope, zone, local day, settings/engine identity, generation; capped; cleared on scope change.
- [ ] Widget path: step query → engine → ordered publish, cache fallback; timeline 15 min with a valid snapshot, else ~30.
- [ ] Tests: identical app/widget output for the same inputs; app beats widget; old generation dropped; newer step read wins; concurrent writers; every failure keeps the cache; no samples never zero; caps hold.
- [ ] **Exit:** app force-quit, phone unlocked, the widget's steps and headline update within ~30–60 min on the iPhone.

### Step 06 — finish the avatar (G2)

**Status: partly done; placeholder implementation exists. Depends on:** G1 for
final acceptance; art and accessibility work can start earlier after review.
**Done when:** T5, T11 and T12 below pass with final art and device evidence.

- [ ] **T5** final art replaces `AvatarPainter` (any time): [specs/G2_art_brief.md](specs/G2_art_brief.md).
- [ ] **T11** VoiceOver, tinted/clear Home Screens, increased contrast, Dynamic Type, during the 24–48 h period.
- [ ] **T12** acceptance after G1 close: backend/Swift/parity suites pass; `settings_sha256` unchanged; `device_check` on a phone database copy matches including `avatar_state`; a HealthKit change reaches the widget avatar without opening the app; sweat fades across timeline entries; identity edits show in app and widget; offline shows the last valid avatar; the 0.1.0 cache upgrades cleanly.

### Step 07 — agree the implementation specification

**Status: contracts specified; fresh implementation confirmation required. Depends on:** Step 02 scenario validation.
**Done when:** the contracts and P1 scope are reviewable, Step 02 is complete and
the user has confirmed the concrete implementation scope (new requirement 2026-10-09). Contract:
[Daily_loop_contract.md](specs/Daily_loop_contract.md). Native completion is separate.

- [x] Specify presentation wording/ranking ownership; confirm the proposed Swift-only presentation layer while retaining engine parity.
- [x] Define presentation states, deep links and fallback, privacy redaction and accessibility behavior.
- [x] Define check-in persistence, edit/delete/undo and the App Group inbox contract.
- [x] Define trend/calendar retention, source coverage and local-day handling.
- [x] Review the proposed data/feature catalog; choose additions and defer the rest.
- [x] Record the earlier plan/start approval; keep visual choices revisable.
- [ ] Obtain confirmation for the concrete implementation scope after this review; latest user instruction supersedes the earlier start approval.

### Step 08 — build the daily app/widget loop (P1)

**Status: not started; confirmation, G1/G2 and scenario acceptance pending. Depends on:** Steps 04, 06 and 07.
**Done when:** the loop works on the iPhone, all required data states and
accessibility checks pass, and it is ready for the week of use in Step 09.
Full feature acceptance: [Product.md §7](Product.md#7-phases-and-acceptance).

- [ ] Today: one useful observation, its explanation and an optional action.
- [ ] One small/medium **Your day** widget with correct freshness and privacy.
- [ ] Widget → exact evidence, with safe deep-link fallback.
- [ ] Energy check-in in the app and widget; persist through the App Group inbox, with edit/undo and retry handling.
- [ ] Optional “does this match?” feedback on the observation.
- [ ] Quiet days, missing/partial data and first-two-weeks calibration states.
- [ ] Complete required scenarios and native accessibility/device checks; record evidence.

### Step 09 — review one week of real use

**Status: not started. Depends on:** Step 08.
**Done when:** one week of P1 use is reviewed, issues are resolved or explicitly
deferred, and a decision to proceed to P1b is recorded. This is separate from
G1's shorter background-reliability check.

- [ ] Use the daily loop for one week; review observation agreement and quiet/calibrating days.
- [ ] Check whether the widget is useful at a glance and explanations answer “why?”.
- [ ] Review check-in friction, freshness, privacy and missing-data confusion.
- [ ] Record findings, required fixes and the P1 acceptance / P1b scope decision.

### Step 10 — add history and focused widgets (P1b)

**Status: not started. Depends on:** Step 09.
**Done when:** history is traceable, gaps/retention are clear, and the calendar
keeps zero, missing data and planned rest distinct.

- [ ] Sleep/movement trends using supported, retained observations.
- [ ] GitHub-style activity calendar with day details and accessible navigation.
- [ ] Journal shell and data controls.
- [ ] Focused/pinned widgets; Movement pace only if the A3/M2 gate passed.
- [ ] Verify source corrections, duplicates, time-zone/day boundaries and accessibility.

### Step 11 — add activity logging and reflection (P2)

**Status: later, not started. Depends on:** Step 10 and scope review.
**Done when:** sessions survive termination, no workouts/sets are duplicated,
and summaries and live actions are traceable and validated.

- [ ] Resumable workout logging and perceived effort.
- [ ] User-set goals, richer sleep/movement views and day replay.
- [ ] Weekly review.
- [ ] Then workout planning and Live Activity.

Contracts: [workout/activity specification](specs/Workout_activity_agent_architecture.md).

### Step 12 — add optional rings and personalization (P3)

**Status: later; ring design explored, native features not started. Depends on:**
Step 11 and scope review. **Done when:** user goals, context and preferences
consistently affect the UI without turning missing data or rest into failure.

- [ ] Review separate versus nested ring designs; no visual choice is final.
- [ ] Implement optional user-goal rings: daily movement, weekly training and optional routine.
- [ ] Add goal persistence/versioning, routine logging and completion rules.
- [ ] Add selected check-ins/context and expanded workout metrics.
- [ ] Add opt-in reminders, calendar integration and optional agent explanations.
- [ ] Verify units, periods, missing/zero/rest/over-goal states, accessible text and quiet behavior.

Ring specification: [Product.md §10](Product.md#10-daily-activity-calendar-and-goal-rings--exploration-2026-10-08).

### Step 13 — evaluate optional exploration (P4)

**Status: later, not started. Depends on:** sufficient input quality and a scope review;
these ideas are not a commitment to collect every available data type.
**Done when:** selected features meet their acceptance criteria, associations
are labeled and forecasts are explicitly hypothetical.

- [ ] Select useful food/caffeine/water context, with low-effort input.
- [ ] Evaluate pattern discovery and experiments against available data quality.
- [ ] Design and validate hypothetical what-if views.

### Later (not scheduled)

| Work | Trigger |
|---|---|
| Server back in the result path | Second device/platform, cloud wearable, audit need or hosting chosen ([specs/On_device_plan.md](specs/On_device_plan.md)) |
| Second source (Health Connect or wearable API) | User picks one after G1; duplicate tests D01–D15 and one authoritative workout stream first ([specs/Multi_source_platform_architecture.md](specs/Multi_source_platform_architecture.md)) |
| Push-triggered widget refresh (APNs) | Hosting exists; push carries no health data |

## 6. Verification and evidence

1. Code changes: targeted tests, then backend `pytest -q`, `swift test` in
   `ios/HomeostatCore`, and an app + widget simulator build.
2. Engine or wording changes regenerate the shared fixtures
   (`UPDATE_WIRE_FIXTURES=1`); both languages pass.
3. Design-only changes: check links, consistency and prototype interactions.
   A preview never counts as an app build or device acceptance.
4. Background behavior is judged on the iPhone, outside the debugger, with
   device, power and network noted. Exact timing is never asserted.
5. A scheduled task or an implemented function is not evidence. Record each
   result below: date, build, command or round, result.

| Date | Round / check | Build | Result |
|---|---|---|---|
| 2026-10-08 | Step 0: `swift test` | working tree | 81 run, 2 skipped (device DB), 0 failures |
| 2026-10-08 | Step 0: app + widget simulator build | working tree | Succeeded |
| 2026-10-08 | Step 0: backend `pytest -q` without PostgreSQL | working tree | 3,602 passed, 0 failed; 167 errors, all database connection refused |
| 2026-10-09 | Step 0: backend `pytest -q` with PostgreSQL | 99ad217 | 3,769 passed, 0 failed |
| 2026-10-09 | Plan tracking revision | documentation only | Steps 01–13 verified in order; local document links resolve; `git diff --check` passed. No implementation or device checks performed |
| 2026-10-09 | Step 02 real-data experience audit | working tree; connected iPhone database copy | SQLite integrity OK; 51 local-noon days: 29 observation headlines, 22 calibrating, 0 quiet, 0 no-data; all 51 match Swift across features, health and widget state. Retrospective, not actual screen exposure |
| 2026-10-09 | Step 04 standard device replay | working tree; same phone copy | Saved phone HealthState and WidgetState match Python; 50 standard checkpoints match Swift, including avatar. No physical background-use acceptance claimed |
| 2026-10-09 | Experience audit targeted tests / full backend | working tree | 10 new tests pass; full suite 3,779 passed, 2 warnings. Initial sandbox attempt could not access PostgreSQL; normal local access passed |
| 2026-10-09 | Full Swift suite after deterministic import-test fix | working tree | 81 executed, 2 skipped, 0 failures; separate device replay runs passed 3/3. Initial run exposed a scheduling assumption in the coalescing test; test now explicitly suspends the first query |
| 2026-10-09 | App + widget simulator build | working tree | `xcodebuild` Homeostat scheme, generic iOS Simulator, signing disabled: succeeded. No native production code changed in this increment |
| 2026-10-09 | Interactive scenario review | unchanged source previews | Existing app/ring interactions pass at 3 widths; keyboard, invalid goal and privacy checks pass; missing scenarios and stale dimming recorded. No implementation changes |
| 2026-10-09 | A3/M2 force-quit feasibility result | installed app 1.0 (1) | Existing Debug UI shows successful 19:19:26 UTC step read during closed-app window: 115 steps, 36 ms, footprint 9.1→9.1 MB. One refresh; gate passed for feasibility, no M3 implementation or cadence claim |
| 2026-10-09 | A3 force-quit baseline, 13:55 CDT | installed app 1.0 (1) | Main app absent; widget extension PID 13281 present; Home Screen shows last result Updated 13:49. Probe-file access explicitly restricted by CoreDevice; use existing Debug UI after window. No M2 acceptance yet |
| 2026-10-09 | Unlock recovery and visible widget, 13:51 CDT | installed app 1.0 (1) | Unlock retry of pending imports logged at 13:49; all five imports OK, errors empty, deferred flag cleared; new run 541/revision 2046 matches visible widget Updated 13:49. ~12-minute lock interval; 30+ minute A2 criterion and A5 diagnostic remain open |
| 2026-10-09 | Continued physical review, 13:41 CDT | installed app 1.0 (1) | Read-only copy: background step observer/import/calculation at 13:29; locked import errors and deferred retry at 13:40, prior effective time retained. A1/A2/A5 partial; widget display and unlock recovery not yet verified |
| 2026-10-09 | Physical background review baseline | installed app 1.0 (1), iPhone 16 Pro Max / iOS 27.2 | Read-only snapshots identical during A1 preparation; historical background observers/imports/calculation seen. Controlled A1 and visible widget update not yet confirmed; A2–A7 remain open |

Earlier evidence: [archive/Step_14_16_plan.md](archive/Step_14_16_plan.md) §12–13 and
[archive/G2_tracker.md](archive/G2_tracker.md) log.

## 7. Decisions

| Date | Decision |
|---|---|
| 2026-09-30 | Calculate on the iPhone; server optional, for later. Free Personal Team. Device-key + pairing auth. v2 deferred |
| 2026-10-05 | Build G2 with code-drawn placeholder art; G1 acceptance still gates G2 acceptance. Avatar decisions D1–D10 in [specs/G2_plan.md](specs/G2_plan.md) §3 |
| 2026-10-06 | Widget self-refresh (§4 path 3), subject to the M2 gate. Probe fixes before device evidence; one combined device session; app-owned generation ordering |
| 2026-10-06 | **D-A** per-domain cutoffs in the engine (Python first, both languages). **D-B** G1 closes on paths 1–2; force-quit updates are M3's exit |
| 2026-10-08 | **D-D** (supersedes D-C's workout-first order): daily app/widget loop first, then workout logging, then personalization. Design studies proceed now |
| 2026-10-08 | P1 narrowed to the daily loop; validate on replayed real data first; widget check-ins via App Group inbox; goal rings deferred to P3 |
| 2026-10-08 | Plans consolidated: this file + Product.md; specs/ for reference, archive/ for history |
| 2026-10-09 | User preference: phone/system timezone is the default, including travel; use elapsed time for manual checks. A stored `sent_zone` is historical metadata, not verification of the current phone timezone |
| 2026-10-09 | Latest scope: interactive scenario review and physical background checks only; confirm before implementation. Companion/separate rings remain flexible |
| 2026-10-09 | User approved the plan and authorized starting. Companion/separate rings are working directions; daily-loop specification prepared from real-data replay. Native P1 gates remain |
| 2026-10-09 | User go-ahead: build everything in the [architecture](specs/System_architecture.md) build order (M3, then P1 foundations/surfaces, P1b, P2…), stopping at each device or review gate |
| 2026-10-09 | Plan reorganized into numbered steps with status, dependencies and completion criteria. User review precedes further implementation; visual direction remains open |

## 8. Documents

| Document | Use |
|---|---|
| **Plan.md** (this) | Status, next steps, rules, decisions, evidence |
| [specs/Scenario_review_2026_10_09.md](specs/Scenario_review_2026_10_09.md) | Interactive results, physical-check evidence and proposed changes awaiting confirmation |
| [specs/System_architecture.md](specs/System_architecture.md) | Modules, processes, data ownership, flows and build order for everything left (M3, P1–P4); decisions 1–5 |
| [specs/Daily_loop_contract.md](specs/Daily_loop_contract.md) | Real-data findings, quiet/new-user states and P1 presentation/action/persistence contracts |
| **[Product.md](Product.md)** | What the app and widget do and look like; P1–P4 detail |
| [specs/Calculation_and_product_review_2026_10_06.md](specs/Calculation_and_product_review_2026_10_06.md) | How the calculation works today: flow, formulas, rationale |
| [specs/G2_plan.md](specs/G2_plan.md), [specs/G2_art_brief.md](specs/G2_art_brief.md) | Avatar contract and mapping; final-art brief |
| [specs/Workout_activity_agent_architecture.md](specs/Workout_activity_agent_architecture.md) | P2 workout logging/planning and later agent contracts |
| [specs/Multi_source_platform_architecture.md](specs/Multi_source_platform_architecture.md) | Second sources, duplicate-data policy and tests D01–D15 |
| [specs/On_device_plan.md](specs/On_device_plan.md) | Why on-device; what brings the server back |
| [specs/Whole_project.md](specs/Whole_project.md) | Long-term vision (includes ideas not scheduled) |
| [archive/](archive/) | Finished G1 build plans (Step_*), old trackers, reviews and records. Read-only history |
