# Homeostat — plan

Updated: 2026-10-08. **This is the one plan.** It holds where the project is,
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
  and keep `engine_parity.json` green. Proposed: Swift alone owns presentation
  wording/ranking once P1 starts (confirm then).

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

One checklist, in order. Tick items here; record device evidence in §6.

### Step 0 — trustworthy probes (code, now)

- [x] `StepProbe`: no samples ≠ 0 steps; stop the query at the 5 s deadline; log widget memory.
- [x] Snapshot probe compares the full result (revision, effective time, HealthState, WidgetState).
- [x] Write the snapshot from the run's own `LocalInputs` (`LocalStore.LocalRun`), not a second read; log event count and oldest event date.
- [x] `swift test`, app/widget simulator build, commit the M1/M2 probe work.
- [ ] Backend database-backed tests (needs Docker running for PostgreSQL on 5433).

### Device session A — one iPhone session (M1, M2, G1 device rows)

Read the Debug view's background and probe logs after each round, outside the
debugger where possible. Note device, iOS, power and network.

- [ ] **A1** app running, unlocked, walk: observer delivery, import, calculation; widget step reads (value / no samples / error / timeout, ms, MB)
- [ ] **A2** app running, locked 30+ min, walk, unlock: `protected data` lines, `import failed … 6`, whether unlock retry runs (M1)
- [ ] **A3** app force-quit, unlocked, widget on Home Screen: step reads keep succeeding (**M2 gate**)
- [ ] **A4** app force-quit, locked: locked widget read behavior
- [ ] **A5** lldb background-task trigger (G1 row)
- [ ] **A6** no new data 2 h: last result kept, dims after 90 min, recovers (G1 row)
- [ ] **A7** reinstall, delete a sample, re-import: lost-anchor demo (G1 row)
- [ ] Also record snapshot KB, events, calculation ms, footprint.

**Gate:** if A3 fails, record it, drop path 3, and close G1 on paths 1–2.

### G1 close (paths 1–2, D-B)

| Item | State |
|---|---|
| Install, Health access, 35-day import | ✅ 2026-09-25 |
| Real widget result; tap opens the explanation | ✅ 2026-09-25 |
| Replay of device data (1,365 / 1,365 identical) | ✅ 2026-09-25; repeat on the current on-device build |
| Live HealthKit change updates the widget without opening the app | Open → A1/A2 |
| Background refresh task on the iPhone | Open → A5 |
| Outage: last result kept, dims after 90 min, recovers | Open → A6 |
| Lost-anchor demo | Open → A7 |
| 24–48 h of normal use outside the debugger | Open, after session A |

### M3 — widget self-refresh (only if A3 passes)

- [ ] Per-domain cutoffs in Python then Swift; regenerate fixtures (`UPDATE_WIRE_FIXTURES=1`); parity green.
- [ ] Split `HomeostatEngine` out of `HomeostatCore` (no behavior change).
- [ ] App-owned generation ordering, written with both the cache and the snapshot.
- [ ] Snapshot v1: versioned; scope, zone, local day, settings/engine identity, generation; capped; cleared on scope change.
- [ ] Widget path: step query → engine → ordered publish, cache fallback; timeline 15 min with a valid snapshot, else ~30.
- [ ] Tests: identical app/widget output for the same inputs; app beats widget; old generation dropped; newer step read wins; concurrent writers; every failure keeps the cache; no samples never zero; caps hold.
- [ ] **Exit:** app force-quit, phone unlocked, the widget's steps and headline update within ~30–60 min on the iPhone.

### G2 — avatar

- [ ] **T5** final art replaces `AvatarPainter` (any time): [specs/G2_art_brief.md](specs/G2_art_brief.md).
- [ ] **T11** VoiceOver, tinted/clear Home Screens, increased contrast, Dynamic Type, during the 24–48 h period.
- [ ] **T12** acceptance after G1 close: backend/Swift/parity suites pass; `settings_sha256` unchanged; `device_check` on a phone database copy matches including `avatar_state`; a HealthKit change reaches the widget avatar without opening the app; sweat fades across timeline entries; identity edits show in app and widget; offline shows the last valid avatar; the 0.1.0 cache upgrades cleanly.

### Product — design now (D0), build after G1 and G2

Detail and acceptance for every item: [Product.md](Product.md).

- [x] Feature catalog, surfaces, reactive rules; Companion/Focus and calendar studies (2026-10-08).
- [ ] Replay the last 30–60 days: count headline / quiet / calibrating days and read the headlines.
- [ ] Design the quiet-day and first-two-weeks states.
- [ ] Review the Companion and Focus studies; refine the calendar. No design frozen.
- [ ] Specify presentation/deep-link contracts, check-in persistence and trend retention.
- [ ] **P1 — the daily loop:** Today, one **Your day** widget, explanations, energy check-in (app + App Group inbox from the widget) with the "does this match?" question, first-two-weeks states.
- [ ] **P1b — after a week of P1 use:** focused widgets (Movement pace only if A3 passed), sleep/movement trends, activity calendar, Journal, data controls.
- [ ] **P2:** resumable workout logging and effort, goals, day replay, weekly review; then planning and Live Activity ([specs/Workout_activity_agent_architecture.md](specs/Workout_activity_agent_architecture.md)).
- [ ] **P3:** optional goal rings, more check-ins/context, opt-in reminders, calendar, agent explanations.
- [ ] **P4:** food context, pattern discovery, what-if views.

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

## 8. Documents

| Document | Use |
|---|---|
| **Plan.md** (this) | Status, next steps, rules, decisions, evidence |
| **[Product.md](Product.md)** | What the app and widget do and look like; P1–P4 detail |
| [specs/Calculation_and_product_review_2026_10_06.md](specs/Calculation_and_product_review_2026_10_06.md) | How the calculation works today: flow, formulas, rationale |
| [specs/G2_plan.md](specs/G2_plan.md), [specs/G2_art_brief.md](specs/G2_art_brief.md) | Avatar contract and mapping; final-art brief |
| [specs/Workout_activity_agent_architecture.md](specs/Workout_activity_agent_architecture.md) | P2 workout logging/planning and later agent contracts |
| [specs/Multi_source_platform_architecture.md](specs/Multi_source_platform_architecture.md) | Second sources, duplicate-data policy and tests D01–D15 |
| [specs/On_device_plan.md](specs/On_device_plan.md) | Why on-device; what brings the server back |
| [specs/Whole_project.md](specs/Whole_project.md) | Long-term vision (includes ideas not scheduled) |
| [archive/](archive/) | Finished G1 build plans (Step_*), old trackers, reviews and records. Read-only history |
