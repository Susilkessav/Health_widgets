# System architecture — remaining features

Updated: 2026-10-09. How everything still to build fits together: modules,
processes, who owns which data, the main flows, and the build order. Rules and
screen behavior live in the linked specs; progress lives only in
[Plan.md](../Plan.md). Nothing here is built unless Plan.md says so, and each
step still needs the user's go-ahead before implementation.

| Feature | Plan step | Detailed rules |
|---|---|---|
| M3 widget self-refresh | 05 | [Plan.md §4](../Plan.md) |
| P1 daily loop: Today, Your day widget, explanations, energy check-in | 08 | [Daily_loop_contract.md](Daily_loop_contract.md) |
| P1b history, calendar, Journal, focused widgets | 10 | [Product.md](../Product.md) §4, §10 |
| P2 workout logging, goals, weekly review, Live Activity | 11 | [Workout_activity_agent_architecture.md](Workout_activity_agent_architecture.md) |
| P3 rings, reminders, calendar, agent | 12 | Product.md §10; workout spec §6–8 |
| P4 food context, patterns, what-if | 13 | Product.md §2, §7 |

## 1. Principles the design keeps

1. **One calculation, one meaning.** The pure engine computes health state; one
   pure presentation mapping turns it into words. App and widget call the same
   code, so they can never disagree.
2. **The app owns the database.** Only the app process opens GRDB. Other
   processes talk to it through small, versioned files in the App Group.
3. **Every write is idempotent.** Commands carry a UUID; repeating one has no
   extra effect. This covers retries, double taps and widget re-runs.
4. **Measured, reported and planned data live in separate tables.** No
   feature writes into another's data.
5. **Health data stays on the phone.** No new feature sends it anywhere.
6. **Derived data can always be rebuilt** from events and entries. Caches and
   summaries are disposable; events, entries and sessions are not.

## 2. Module map

```
                 ┌──────────────────────── App process ────────────────────────┐
                 │  Homeostat app (SwiftUI)                                     │
                 │  Today · Explanation · Trends · Journal · Workout · Settings │
                 │                 │                                            │
                 │                 ▼                                            │
                 │  HomeostatCore (app only)                                    │
                 │  LocalStore/GRDB · Import · Calculation · Journal ·          │
                 │  History · Workout · Goals · Prompts                         │
                 └─────────┬──────────────────────────────────────────┬────────┘
                           │ links                                    │ links
                           ▼                                          ▼
   HomeostatEngine (new, M3; pure, no GRDB) ──links──► HomeostatShared (widget-safe)
   features · state engine · stepSnapshots ·           Instant · WidgetState · AvatarState ·
   engine-input snapshot v1                            cache · DailySummary · inbox · links
                           ▲                                          ▲
                           │ links                                    │ links
                 ┌─────────┴──────────────── Widget extension ────────┴────────┐
                 │  Your day widget · focused widgets (P1b) · LogEnergyIntent  │
                 └──────────────────────────────────────────────────────────────┘
```

| Module | Owns | Must never |
|---|---|---|
| `HomeostatShared` | Time types, widget/avatar contracts, cache, display policy, **`DailySummary` mapping (P1)**, **check-in inbox (P1)**, deep links, probe log | Link GRDB or HealthKit; contain health thresholds |
| `HomeostatEngine` (M3) | Features, state engine, `stepSnapshots`, snapshot v1 encode/decode | Touch files, network or HealthKit; contain UI wording |
| `HomeostatCore` | GRDB store and migrations, import, calculation, publish, and the services below | Be linked by the widget |
| App target | Screens, HealthKit source, notifications, ActivityKit | Contain calculation or wording rules |
| Widget target | Timeline provider, widget views, App Intents | Write GRDB; advance health timestamps |

New `HomeostatCore` services, each one folder with one public entry point:

| Service | Phase | Entry point |
|---|---|---|
| `Journal/` | P1 | `JournalService.apply(_ command: EntryCommand) -> EntryResult`; `ingestInbox()` |
| `History/` | P1b | `HistoryService.rebuild(days:)`; `summaries(range:metric:)` |
| `Workout/` | P2 | `WorkoutSessionService` (state machine), templates, trends |
| `Goals/` | P2/P3 | `GoalService` (versioned goals); ring progress (P3) |
| `Prompts/` | P3 | `PromptPolicy` (quiet hours, cooldown, ledger) |
| `Agent/` | P3 | Typed context builder and proposal validator only |

## 3. Processes and data ownership

| Data | Where | Written by | Read by | Protection |
|---|---|---|---|---|
| Events, coverage, anchors, entries, sessions, goals, summaries | GRDB, app container | App | App | Until first unlock |
| `widget_cache.json` (WidgetState, `DisplayFacts`, generation) | App Group | App; widget only under the M3 ordering rule | Widget, app | Until first unlock |
| `engine/engine_inputs.json` (snapshot v1) | App Group | App | Widget | Until first unlock |
| `inbox/<scope>/<commandID>.json` | App Group | Widget intent | App (then deletes) | Until first unlock; verify locked writes on the iPhone |
| Avatar identity | App Group | App | Widget, app | As today |
| Probe log | App Group | Both | App Debug view | As today; remove after M3 |

**Cross-process rules:**

- **No shared mutable files except the cache.** The cache keeps today's
  `NSFileCoordinator` write. Everything else has a single writer.
- **The inbox needs no lock.** Each command is its own file, written atomically
  under its UUID. Two widget taps make two files; a retry rewrites the same
  file. This replaces the contract's "append under a cross-process lock" with a
  simpler mechanism that gives the same guarantee.
- **Versioned and scoped.** Every file carries a format version and the store
  scope. A reader ignores unknown versions and other scopes.

## 4. Main flows

### 4.1 App calculation and publish (today, plus the generation number)

```
import finishes ─► LocalStore.localRun(now, zone)            [one read of LocalInputs]
              ─► engine ─► HealthState ─► WidgetState + AvatarState + DisplayFacts
              ─► under cache lock: generation += 1; write widget_cache.json
              ─► write engine_inputs.json (same inputs, same generation)   [M3]
              ─► JournalService.ingestInbox() first, if files are waiting   [P1]
              ─► WidgetCenter.reloadAllTimelines() when the display changed
```

`DisplayFacts` (new in P1; carried in the cache) holds what the presentation
mapping needs and the engine already knows: per-domain readiness and usable/required
days, per-domain observation times, the comparison values, and evidence
references. It is facts, not wording.

### 4.2 Widget timeline (M3, only after the go-ahead)

```
getTimeline
 ├─ locked, no snapshot, other scope/zone/day/version ─► use cache as is
 ├─ query today's hourly steps (5 s deadline, query stopped on timeout)
 │    ├─ error / timeout ─► use cache as is
 │    └─ samples (or none: "no samples", never 0)
 ├─ stepSnapshots + snapshot inputs ─► HomeostatEngine for now
 ├─ publish only if cache.generation == snapshot.generation
 │                and stepsThrough > cache.stepsThrough           [under cache lock]
 └─ DailySummary(cache facts, now, privacy, pending inbox entry) ─► entries
```

### 4.3 Energy check-in from the widget (P1)

```
tap Low/Okay/High ─► LogEnergyIntent.perform()        [widget process]
   ─► write inbox/<scope>/<uuid>.json atomically ─► success? ─► timeline shows
      "You reported … at 9:41 · saving" from the pending file
   ─► failure ─► "Not saved" + open-app action
later, app launch / foreground / background wake:
   JournalService.ingestInbox(): for each file, in one transaction:
      apply command (idempotent on command UUID) ─► commit ─► delete file
   ─► republish cache ─► the widget shows the saved entry
```

The app-side check-in (Today screen) calls `JournalService.apply` directly; it
does not go through the inbox.

### 4.4 Deep links

`ExplanationLink` gains a domain and evidence reference. Resolution order stays:
the exact run → a newer run, labeled as newer → a neutral landing screen.
Wrong scope or bad input always lands safely.

### 4.5 History rollup (P1b)

```
after each calculation ─► HistoryService.rebuild(last 36 local days)
   ─► for each day: engine features at that day's end ─► daily_summary rows
Trends / calendar / weekly review read daily_summary only.
```

Rebuilding a fixed window makes late corrections and deletions flow into
history automatically. Rows older than the event window are kept and frozen;
they carry the engine and rollup version that produced them.

## 5. Feature designs

### 5.1 M3 — widget self-refresh

| Part | Design |
|---|---|
| Per-domain cutoffs (D-A) | `EngineContext` gains `cutoffs: [Domain: Instant]`. Movement uses the step read time; other domains keep their import cutoff. Python first, fixtures regenerated, Swift parity. Existing results are unchanged when all cutoffs are equal (test). |
| `HomeostatEngine` target | Move `Engine/` plus snapshot code out of `HomeostatCore`; Core re-exports it. No behavior change; full suites pass before anything else changes. |
| Generation | `WidgetCache` gains `generation: Int64` and `stepsThrough: Instant?`. App increments under the cache lock. |
| Snapshot v1 | `engine-inputs@1`: version, scope, zone, local day, settings hash, engine version, generation, lower bound, per-domain cutoffs, coverage, events (36-day window, event and byte caps checked on write). Cleared on scope change. |
| Budget | ≤ 2 MB snapshot, ≤ 3 s, memory well under the extension limit (A3: 9.1 MB). Fallback if exceeded: snapshot carries daily feature summaries instead of raw events. |
| Timeline | 15 min with a valid snapshot, otherwise ~30. iOS decides actual times. |

### 5.2 P1 — the daily loop

**Presentation.** `DailySummary.make(facts:state:now:policy:latestEntry:)` in
`HomeostatShared`, pure and table-tested. Output: kind (one of the states in
the daily-loop contract), headline, one comparison, evidence references, domain
availability, observation times, optional action, version. The existing
parity-tested mapper stays untouched; `DailySummary` reads its output plus
`DisplayFacts`. Python keeps the engine; this layer is Swift-only (decision 1).

**Check-ins.** GRDB migration `v6_subjective_entries`:

```
subjective_entry(id TEXT PK, kind TEXT, value TEXT, event_at, zone,
                 created_at, updated_at, revision INT, deleted INT,
                 match_answer TEXT NULL, match_run_ref TEXT NULL)
entry_command(command_id TEXT PK, entry_id, kind TEXT, expected_revision INT,
              applied_at, outcome TEXT)        -- idempotency + audit
```

`EntryCommand` = create / edit / delete / undo, with `commandID`,
`expectedRevision`. A replayed command returns its recorded outcome. An edit or
undo against an older revision returns `conflict`, never overwrites. Deletes
are tombstones so a late widget command cannot resurrect an entry.

**Screens.** Today (Companion direction: summary, evidence cards, energy entry);
Explanation redesign (plain meaning → evidence → provenance); Settings (privacy,
data access). No empty Trends/Journal tabs until P1b.

**Widget.** Small: summary + one deep link. Medium: summary + three
`Button(intent: LogEnergyIntent(value:))`. Privacy redaction is applied first.

### 5.3 P1b — history, calendar, Journal, focused widgets

- Migration `v7_history`: `daily_summary(local_day, zone, metric, unit, value,
  coverage, source, engine_version, rollup_version, built_at)` keyed by
  (local_day, metric); `day_annotation(id, local_day, kind: rest|travel|illness,
  note, created_at, deleted)`.
- Values are `NULL` for no data and `0` only for a supported zero. Coverage is
  stored with every value, so "no data", "0", "rest" and "future" stay distinct.
- Trends and the calendar are views over `daily_summary`. The calendar shade
  bands are presentation constants, not engine thresholds.
- Journal lists `subjective_entry`, imported workouts and annotations by event time.
- Focused widgets use `AppIntentConfiguration` with a `focus` parameter
  (your day / sleep / movement / recovery / recent workout) passed to
  `DailySummary`. Movement pace only if M3 shipped.

### 5.4 P2 — workouts, goals, weekly review, Live Activity

Data model and rules: workout spec §4–5. Architecture points:

- `WorkoutSessionService` is a persisted state machine
  (`planned → active ⇄ paused → finished | discarded`). Every set is committed
  as it is entered, so a killed app resumes exactly where it was.
- One command path for every surface: app screens, Live Activity buttons and
  any later agent proposal all call the same service with idempotent commands.
- Live Activity buttons use `LiveActivityIntent`, which runs in the app process,
  so they call the service directly (no inbox).
- **No double counting with HealthKit:** a local session links to an imported
  HealthKit workout only when the user confirms the match, or by the exact UUID
  if Homeostat ever writes workouts. Unlinked overlaps are shown as two
  records with a "possible duplicate" note, never summed.
- Goals: `goal_definition(id, metric, unit, target, period, effective_from,
  effective_to, paused)`. A change creates a new version from a date onward;
  history uses the version in force then.
- Weekly review reads `daily_summary`, entries and sessions; every sentence
  links to its days.

### 5.5 P3 — rings, prompts, calendar, agent

- **Rings:** pure progress = actual / target for the same metric and period,
  from `daily_summary` and `goal_definition`. Missing data draws a dashed track,
  never 0%. Rules: Product.md §10.
- **Prompts:** local notifications only (`UNUserNotificationCenter`), scheduled
  by the app. `PromptPolicy` decides with quiet hours, cooldowns and dismissal
  history; every decision is written to `prompt_ledger`, so behavior is explainable.
- **Calendar:** EventKit, read-only, opt-in, only free/busy windows used.
- **Agent:** receives a typed context (summaries, entries, candidate options),
  returns a proposal that the validator checks before any service applies it.
  It never computes health state. Where the model runs is decision 3.

### 5.6 P4 — food, patterns, what-if

Separate opt-in tables (`food_entry`), never merged into measured state.
Associations are computed offline over `daily_summary` with sample size and
uncertainty shown; what-if views are labeled hypothetical and never stored as
results.

## 6. Cross-cutting

| Concern | Design |
|---|---|
| Migrations | Append-only GRDB migrations (`v6_…` onward); each has a test that upgrades a copy of a real phone database |
| Cache format | `WidgetCache` version bump per change; old versions read with defaults; an unreadable cache shows the existing safe state |
| Concurrency | `AppModel` on the main actor; services do database work off it; one calculation at a time (existing coalescing); widget work is single-shot per timeline request |
| Privacy | Redaction applied before `DailySummary`; widget files hold only display facts, never history |
| Accessibility | Every state has text; every action a VoiceOver label; large text stacks content first |
| Time | Phone timezone is the default (2026-10-09); events store instant + IANA zone; days are local days |
| Removal | Probes (`StepProbe`, `EngineInputsProbe`, `ProbeLog`) are deleted when M3 ships or is dropped |

**Tests per feature:**

| Feature | Must have |
|---|---|
| M3 | Same inputs → identical app and widget output; ordering (app beats widget, old generation dropped, newer step read wins, concurrent writers); every failure keeps the cache; no samples ≠ 0; caps |
| P1 | `DailySummary` table test for every contract state; command replay/conflict/tombstone tests; inbox: wrong scope, bad version, partial file, ingest crash before delete |
| P1b | Rollup equals engine features per day; corrections and deletions change history; DST and timezone days; null vs zero vs rest |
| P2 | Kill mid-set and resume; duplicate command; HealthKit overlap not summed; goal versions keep history |
| All | Backend `pytest`, `swift test`, app + widget build; device checks recorded in Plan.md §6 |

## 7. Build order

Each row is one Plan.md step and needs the user's go-ahead before code starts.

| Order | Work | Blocked by | Size |
|---|---|---|---|
| 1 | Finish device session A; 24–48 h use; G1 acceptance | — | Device time |
| 2 | **M3**: cutoffs (Python → Swift) → engine split → generation → snapshot v1 → widget path | Go-ahead; repeated A3 passes | M |
| 3 | G2: final art (T5) any time; T11/T12 after G1 | G1 | Art + device time |
| 4 | **P1 foundations**: `DisplayFacts` + `DailySummary` + Journal service + inbox | Go-ahead on step 07 scope | M |
| 5 | **P1 surfaces**: Today, Explanation redesign, Your day widget, energy intent | 4; G1 and G2 for release | M |
| 6 | One week of P1 use and review | 5 | Calendar time |
| 7 | **P1b**: history rollup → Trends/calendar → Journal → focused widgets | 6 | M |
| 8 | **P2**: workout session service → logging screens → goals → weekly review → Live Activity | 7 | L |
| 9 | **P3** then **P4** | Scope review each | L |

Items 2 and 4 don't depend on each other and can be built in either order.

## 8. Decisions needed

| # | Question | Recommendation |
|---|---|---|
| 1 | Swift-only presentation wording, with Python keeping the engine only? | Yes. The Python server isn't on the result path; dual wording doubles P1 work |
| 2 | Inbox as one file per command instead of an append log under a lock? | Yes. Atomic per-file writes need no cross-process lock |
| 3 | Where would an agent's language model run? | On the device only (Apple's on-device model), which keeps "health data never leaves the phone". Revisit only if that model is too weak |
| 4 | Build M3 before or after P1 foundations? | After the extra A3 runs; it's smaller and the probes are fresh |
| 5 | Keep `daily_summary` rows beyond the 36-day event window? | Yes, frozen with their version. Needed for any history longer than five weeks |
