# Homeostat — app tracker

Last updated: **2026-10-08**

**Current focus:** app/widget design studies alongside reliable background updates and iPhone acceptance.
**Next product feature:** P1 daily loop (Today, one Your day widget, explanations, energy check-in, first-two-weeks states); P1b trends, calendar, focused widgets; P2 workout logging follows. See D-D in the master plan.

Status: **Built** = implemented · **Verify** = built, device checks open ·
**Prototype** = experiment only · **Planned** = not built · **Later** = deferred.

## Features

| Feature | Status | What remains |
|---|---|---|
| HealthKit import: sleep, HRV, resting HR, steps, workouts | Built | Device recovery checks below |
| Local storage, retries, corrections and deletions | Verify | Lost-anchor and restart/recovery evidence |
| Personal baselines and calibration | Built | 14 usable days within the previous 28 calendar days |
| Sleep, recovery, movement and workout calculations | Built | Planned per-domain cutoffs for independent step refresh |
| Explainable results: values, sources, baselines, versions | Built | Keep explanations aligned with every engine change |
| On-device calculation without a server | Built | Python/Swift parity must stay passing |
| Small and medium widgets, cached results and freshness | Verify | Live background update, stale display and recovery checks |
| App background import and unlock retry | Verify | Locked/unlocked iPhone evidence |
| Independent widget step read | Prototype | Fix probes; prove access and resource budgets on iPhone |
| Independent widget recalculation | Planned | Shared engine, bounded snapshot and ordered publication |
| Avatar, identity customization, demo and fading effects | Verify | Placeholder art; remaining device/accessibility acceptance |
| Final avatar artwork | Planned | Replace code-drawn art using existing layer contracts |
| Optional backend, upload and replay | Built | Cloud hosting/result path deferred |
| App/widget interaction design | Prototype | Companion and Focus remain exploratory; no final design selected |
| Daily activity calendar | Planned / design prototype | Workouts/steps/routines; missing/zero/rest distinct; history retention gate |
| Goal rings | Deferred to P3 | Optional, user-set goals only; design plan §10 |
| Today and three-destination navigation | Planned | Today, Trends, Journal; profile separately |
| Adaptive/focused widgets and user pinning | Planned | Shared presentation policy, stable headlines, exact deep links |
| Consumer explanation redesign | Planned | Plain-language evidence first; technical details expanded |
| Sleep/movement trends and domain detail | Planned | History retention, gaps, typical ranges, per-domain freshness |
| Optional energy check-in and Journal shell | Planned | Local service, durable acknowledgment, edit/delete/undo; widget action gate |
| Data status and privacy controls | Planned | Per-domain calibration, missing-data copy, export/delete and widget privacy |
| Day replay and weekly review | Planned | Event versus sync time; traceable observations |
| Goals, context and reminder preferences | Planned | Separate goals from baselines; quiet hours, snooze and no-action policy |
| Calendar availability and richer workout imports | Later | Opt-in integration and new data contracts |
| Pattern discovery and what-if exploration | Later | Sufficient observations, uncertainty and hypothetical labeling |
| Workout logging: exercises, sets, reps, weights, feedback | Planned | Local schema, session lifecycle and logging screens |
| Workout planning and Live Activity | Planned | Templates, explained options and live session controls |
| Proactive check-in delivery | Planned | P3 preferences, quiet hours, cooldowns and delivery rules; manual energy entry is P1 |
| Optional agent assistance | Planned | Typed evidence, validated proposals and user-controlled actions |
| Food context | Later | Separate opt-in and reliable input data |
| Other providers, Android and cross-device sync | Later | Choose scope; satisfy duplicate and source-policy gates |

## Architecture

### Working today

```text
HealthKit
   ↓
Import and normalization
   ↓
LocalStore (GRDB): events, anchors, coverage, optional upload queue
   ↓
Swift features → HealthState → wording + AvatarState
   ↓
Saved local result + App Group cache
   ↓
iPhone app / Home Screen widget / explanations

Optional: LocalStore → upload → FastAPI + PostgreSQL → history/replay
Reference: Python engine ↔ shared fixtures ↔ Swift engine
```

### Planned additions

| Addition | Intended flow | Rule |
|---|---|---|
| Widget self-refresh | App input snapshot + fresh steps → shared engine → cache | Retain cached result on failure; never advance other domains' timestamps with steps |
| Workout logging | User entries → local sessions/sets → session summary | Actual work stays separate from planned work |
| Planning | Session history + goals/preferences → deterministic options | Explain why an option was selected |
| Live Activity | Active session → compact progress and actions | One validated session service owns changes |
| Check-ins and agent | Supported options + policy → prompt/explanation/proposal | Opt-in controls; agent does not calculate health state |

**Code boundaries:** `HomeostatCore` owns import, storage and calculations;
`HomeostatShared` owns widget contracts, cache and avatar presentation.
Planned `HomeostatEngine` extracts the pure engine for app and widget use.
The widget never writes the app database.

## Work checklist

### Now — trustworthy probes and device evidence

- [ ] Fix step probe: distinguish no data from zero, stop timed-out queries, measure extension memory.
- [ ] Export the exact calculation inputs; compare full results and record snapshot size/event count.
- [ ] Verify observer delivery and unlock retry on the iPhone.
- [ ] Test widget step reads with the app running, force-quit, unlocked and locked.
- [ ] Record runtime, memory and snapshot budgets; proceed with self-refresh only if feasible.

### Close the health foundation (G1)

- [x] Install, request Health access and import history — recorded 2026-09-25.
- [x] Display a real widget result and open its explanation — recorded 2026-09-25.
- [ ] Repeat replay verification for the current on-device build.
- [ ] Observe a HealthKit change update the widget without opening the app, with app background delivery available.
- [ ] Verify the background refresh task on iPhone.
- [ ] Verify last-result retention, dimming after 90 minutes and recovery.
- [ ] Verify lost-anchor reconciliation after reinstall/deletion.
- [ ] Record 24–48 hours of use outside the debugger.

### Independent widget updates — only if the prototype passes

- [ ] Add per-domain cutoffs in Python and Swift; regenerate parity fixtures.
- [ ] Extract the shared pure engine.
- [ ] Add app-owned generation ordering and a bounded, versioned input snapshot.
- [ ] Implement step query → calculation → coordinated publication with cached fallback.
- [ ] Verify equality, concurrent writers, stale snapshots, rollover and failures.
- [ ] Record an actual widget update with the app force-quit and phone unlocked.

G1 can close on app-wake and unlock paths; force-quit updates have their own acceptance gate.

### Complete the avatar (G2)

- [ ] Replace placeholder artwork — can proceed independently.
- [ ] Finish iPhone accessibility and rendering-mode checks.
- [ ] Record avatar acceptance after G1 closes.

### App/widget design and P1 daily experience

- [x] Add data inventory, feature catalog, reactive behavior and design gates.
- [x] Create and smoke-check the Companion and Focus prototypes — 2026-10-08;
      navigation, explanations, check-in/undo, privacy, four sample states,
      narrow layouts and light/dark visual inspection. Design plan §9.
- [ ] Replay the last 30–60 days; count headline/quiet/calibrating days (design plan §1).
- [ ] Design quiet-day and first-two-weeks states.
- [ ] Review Companion and Focus interactive studies (prototype only; design not frozen).
- [x] Create and browser-check daily activity calendar and separate/nested ring
      prototypes — 2026-10-08; evidence in design plan §10.
- [ ] Refine the calendar after usability review; rings deferred to P3.
- [ ] Define shared display/deep-link contracts and trend retention.
- [ ] Implement Today, Trends and Journal navigation and consumer explanations.
- [ ] Implement the Your day widget with exact evidence links (P1); focused widgets and pinning in P1b.
- [ ] P1b: sleep/movement trends, gaps, calibration and data/privacy controls.
- [ ] Add durable optional energy check-in service, edit/delete/undo, retry and the match question.
- [ ] Widget check-in via App Group inbox; verify locked-device write and idempotent ingest.
- [ ] Verify missing, stale, prior-day, private and sensor/report disagreement states.
- [ ] Run native accessibility and device acceptance before release.

### P2 workout and reflection; later personalization

- [ ] Workout schema and resumable session/set lifecycle.
- [ ] Logging screens, units, edits and optional feedback.
- [ ] Verify a real session survives termination without lost or duplicate sets.
- [ ] Add workout templates, explained planning options and Live Activity.
- [ ] Add day replay, goals and weekly review with traceable evidence.
- [ ] P3: expanded check-ins/context, opt-in delivery, calendar and validated agent assistance.
- [ ] P4: food/caffeine/water context, pattern discovery and hypothetical scenarios.

## Keep this tracker current

Update the date, feature status and checkbox when work changes. Mark device work
complete only with recorded evidence. Keep detailed designs in the linked plans.

| Date | Change / evidence |
|---|---|
| 2026-10-08 | D-D: revise product order; add app/widget feature catalog and first design-study scope. No native or device completion claimed. |
| 2026-10-06 | Tracker created from the current master plan. Built features remain separate from device acceptance and proposed work. |

## Detailed references

- [App/widget design plan](../Product.md) — data, surfaces, interaction rules and P1–P4 gates.
- [Master plan](../Plan.md) — decisions and execution order.
- [Calculation review](../specs/Calculation_and_product_review_2026_10_06.md) — formulas, flow and rationale.
- [iPhone acceptance](Step_14_16_plan.md) — device evidence.
- [Avatar tracker](G2_tracker.md) — art and avatar acceptance.
- [Workout and agent architecture](../specs/Workout_activity_agent_architecture.md) — future product design.
- [Multi-source architecture](../specs/Multi_source_platform_architecture.md) — provider and duplicate rules.
