# Homeostat: implemented flow, calculations and revised goals

Reviewed against the working tree on 2026-10-06, including the uncommitted
background and widget prototype work. This is a code review and explanation;
it does not change health thresholds or claim physical-device acceptance.
[Plan.md](../Plan.md) is the plan; §6–7 here are the 2026-10-06 review state, since folded into it.

## 1. What the product currently does

Homeostat reads HealthKit, compares selected measurements with personal history,
produces an explainable state, and displays it in the app and Home Screen widget.
It calculates on the iPhone without a server. The avatar is a presentation of
that state, with code-drawn placeholder art and local customization.

| Capability | Current status | Reason for the feature |
|---|---|---|
| Sleep, HRV SDNN, resting HR, steps, completed workouts | Implemented | Describe the person's observed day using personal comparisons |
| Per-domain baselines and calibration | Implemented | Avoid comparisons before enough compatible history exists |
| Deterministic recovery classification | Implemented | Combine supported signals rather than react to one reading |
| Durable import, corrections, deletions, offline storage | Implemented; physical recovery checks remain | Retries and restarts must not inflate or lose observations |
| Explanations with values, baselines, sources and versions | Implemented | Make the visible state traceable |
| Small/medium widget and freshness handling | Implemented; background acceptance remains | Provide a glance and acknowledge old results |
| Avatar, identity editor, demo and accessibility adaptations | Implemented with placeholder art; device acceptance incomplete | Make different domains recognizable without a single opaque score |
| Unlock retry | Implemented; device evidence remains | Retry imports deferred by protected-data availability |
| Widget step read and input snapshot | M2 prototype code exists | Test whether the extension can update independently of the app |
| Widget calculates a new result from those steps | Planned M3 | Keep movement current when the app is not running |
| Backend persistence, replay and optional upload | Implemented infrastructure | Preserve an optional future sync/audit path |
| Workout sets/reps/weights, planner, Live Activity | Proposed, not implemented | Establish actual training history and support a session |
| Agent explanations, check-ins and food context | Proposed, not implemented | Offer controlled help after reliable logging and preference flows exist |
| Additional providers / Android | Deferred | Require explicit source identity and duplicate policies first |

## 2. The implemented flow, end to end

1. **Open and restore.** The app opens its scoped GRDB store, restores the last
   local result and prepares import/sync services. Scope identifies the data
   context; old asynchronous work must not publish into a new context.
2. **Request Health access.** The app records authorization requests. An empty
   read is not proof that a metric is zero or that read access was granted.
3. **Import.** HealthKit samples become canonical point, interval, workout,
   deletion and cumulative step-snapshot events. Historical import covers
   approximately 35 days, providing enough room for the 28-day baseline.
4. **Persist before advancing.** Events, import progress and anchors are stored
   durably. The outbox also supports optional upload; local calculation uses
   events whether or not they have been uploaded.
5. **Reconcile visibility.** Exact re-reads do not add weight. Tombstones remove
   deleted records. After a lost anchor, only a completed re-read can withdraw
   records no longer returned. Partial scans must not imply deletion.
6. **Build calculation inputs.** `LocalCalculation.swift` selects visible
   observations and coverage. Unresolved quarantine makes relevant coverage
   incomplete. Event time and delivery time have separate meanings.
7. **Choose an effective instant.** The app uses the earliest import cutoff
   that reached into today, capped at now. A domain stuck before today does not
   pull the whole result into yesterday; it lacks current coverage instead.
   This prevents one result from silently mixing incompatible import cutoffs.
8. **Calculate features.** The pure Swift engine selects sources, builds sleep
   episodes and daily readings, calculates baselines, movement pacing, workout
   recency and data-support confidence.
9. **Interpret state.** Features become sleep, recovery, movement and workout
   classifications plus evidence drivers. No model or network is involved.
10. **Map presentation.** The mapper selects wording and avatar channels. It
    does not change measurements or health classifications.
11. **Save and publish.** The app saves a local run, publishes a scoped,
    ordered App Group cache and asks WidgetKit to reload. Calculation work runs
    off the main thread; repeat requests are coalesced.
12. **Display and explain.** The widget reads the cache and applies age,
    calendar-day, privacy and avatar-effect rules. Tapping opens a scoped run
    explanation; an unavailable old run must not be silently substituted.

App-open catch-up, HealthKit observer delivery and background refresh enter the
same import/calculation path. Protected-data availability can retry deferred
work. Scheduling a refresh is a request, not evidence that iOS executed it.

The optional backend has a separate ingestion/persistence/recalculation/replay
path. It is not required to produce the current local result. Python remains
the reference implementation; shared fixtures compare it with Swift.

## 3. Exact calculations and their rationale

### Baseline and calibration

Use the **previous 28 calendar days**, excluding the report day. A domain needs
**14 valid daily observations** to be ready. Missing days do not extend the
window backwards. The baseline is a median, reducing the effect of outliers.
Source selection keeps a compatible series instead of pooling unrelated values.

Each domain calibrates independently. The overall calibration indicator takes
the minimum count among domains with nonzero history. Zero-history domains are
excluded from that indicator, but remain missing/unusable in their own domain.
Therefore, overall “ready” does not mean every sensor is available or recovery
has sufficient inputs. This distinction should stay visible in explanations.

### Sleep

- Group stages by source and timezone. Join stage clusters separated by at
  most 90 minutes. In-bed-only records cannot create or bridge sleep.
- Duration = union of asleep intervals, minus overlapping awake intervals
  from that source. It is not simply bedtime to wake time.
- Select the highest-priority eligible source, then its longest overnight
  episode waking on the report day. The overnight eligibility window is
  previous-day 18:00 through wake-day 12:00. Other episodes are retained as
  explanation evidence rather than added to the primary-night baseline.
- `delta = primary_sleep_hours - median_historical_hours`.
- At least 60 minutes shorter: `below_baseline`; at least 60 minutes longer:
  `above_baseline`; otherwise `typical`. The boundaries are inclusive.
- Severity = `min(abs(delta_minutes) / 120, 1)` for above/below states.

Example: 6 hours against a 7.5-hour baseline gives a -90-minute difference,
`below_baseline`, and severity 0.75. Sleep confidence separately controls whether
that state is displayed strongly. These are product comparison rules, not
clinical sleep requirements. A consistently short personal baseline remains a
limitation of a purely relative comparison. Shift-work support needs an explicit
episode-policy decision; it should not be assumed from the overnight default.

### HRV and resting heart rate

Select one reading per day: the latest within the primary sleep episode;
otherwise the first after waking on that local day; if no primary sleep exists,
the first reading of the local day. Completed original sample boundaries are
also respected. Ties resolve deterministically by record ID.

This makes selection consistent and explainable, although late-arriving data
can still revise the selected reading. HRV here means **SDNN**, not an
interchangeable score from another HRV method.

```
center = median(previous daily values)
MAD = median(abs(value - center))
scale = max(1.4826 * MAD, 1.0)
z = (current_value - center) / scale
```

The floor is 1 ms for HRV and 1 bpm for resting HR. It avoids division by zero
and exaggerated scores when history barely varies. `z < -1` is below usual;
`z > 1` is above usual; the endpoints are typical. Low HRV and elevated resting
HR are adverse recovery signals. Example: HRV 40 ms, median 50 ms, MAD 5 ms
gives z approximately -1.35, so HRV is below usual.

### Movement

Compare cumulative steps with the median cumulative steps at a comparable
local wall-clock time on historical days. Each historical day contributes its
latest bucket within the previous 60 minutes of the current bucket's position.
This compares 14:00 with approximately 14:00, rather than a partial day with
whole-day totals. It uses each snapshot's local clock across DST and travel.

```
ratio = steps_so_far / expected_steps_at_comparable_time
ratio < 0.70 -> behind_usual
ratio > 1.30 -> ahead_of_usual
otherwise -> typical
```

Exactly 0.70 and 1.30 are typical. If expected steps are zero, the ratio is
undefined and the current policy returns typical. A latest-bucket conflict
invalidates that bucket; the engine does not choose the bigger value or fall
back to an older one. Newer query-time corrections may increase or decrease
counts. Historical hourly buckets matter: sparse totals cannot reliably
calibrate every time of day. Weekday-specific pacing is deferred.

Example: 3,000 steps versus 5,000 expected gives 0.60, behind usual.

### Workouts

Only completed workouts count. Last completion within 2 hours is
`just_completed`; within 12 hours is `recent_workout`; beyond that is
`none_recent`. The 2-hour and 12-hour endpoints are inclusive. Totals cover
today and the last seven local calendar days, with real day lengths for DST.

The current G1 implementation divides overlapping recordings into disjoint
time segments and assigns each segment to a priority winner. Recorded active
duration is spread proportionally over elapsed time because pause positions
are unknown. This avoids counting overlapping minutes twice but may still add
edge minutes from a possible mirrored workout. This is a known mismatch with
the stricter future multi-source plan; resolve it before enabling a second
provider. Incomplete required workout coverage yields `missing`, not a
confident claim that no workout occurred. There is no live workout tracker or
set-level training-load calculation in the current engine.

### Confidence

For sleep, HRV, resting HR and movement:

```
confidence = maturity * freshness * coverage * source_weight
maturity = min(valid_history_days / 14, 1)
```

Coverage is currently binary, not a smooth estimate. No current value means
confidence zero. Freshness is full through 24 hours for sleep/HRV/RHR, then
decreases linearly to zero at 48 hours. Movement is full through 1 hour and
zero at 3 hours. Source weight is configured; default matched groups use 1.
Workout confidence is 1 with the required supported coverage, otherwise 0.

Confidence describes data support. It is not a probability of a health outcome.
Feature confidence decay and the widget's 90-minute stale marker have different
purposes: the former qualifies evidence, the latter tells you the displayed
result has not been updated recently.

### Recovery

A signal votes only when its baseline is ready, its current state is usable,
and its confidence is greater than zero. At least two of sleep, HRV and resting
HR must vote. Otherwise recovery is `insufficient_data`, confidence zero.

- **Strained:** at least two adverse signals: shorter sleep, lower HRV,
  elevated resting HR.
- **Favorable:** HRV above usual and resting HR below usual, with no usable
  shorter-sleep signal vetoing it. Missing/unusable sleep cannot veto it.
- **Typical:** other combinations with at least two usable inputs.

`recovery_confidence = min(used_signal_confidences) * used_signal_count / 3`.
Two perfect signals yield about 0.667 confidence. A single unusual HRV reading
cannot independently make recovery strained or favorable. “Typical” means the
implemented combination rule did not find the specified deviation; it is not
a blanket claim about health or readiness for exercise.

## 4. How the visible result is chosen

Displayable claims need confidence at least 0.5. Headline priority is:

1. Shorter sleep.
2. Recovery signals below usual.
3. Less active than usual.
4. Workout complete.
5. Longer sleep.
6. Recovery signals above usual.
7. More active than usual.
8. Recent workout.

This prioritizes deviations worth noticing, then fresh activity and positive
deviations. The secondary line preserves another relevant cue. With no match,
the mapper selects learning-baseline, supported typical-day, or waiting-for-data
wording according to available evidence. The headline is a priority choice,
not a summary of every domain; explanations preserve the other drivers.

Avatar channels stay separate: sleep changes eyes; recovery changes posture;
movement changes motion; workouts produce sweat and activity glow. Sleep-eye
intensity is severity times confidence. Below 0.5 confidence the channel stays
neutral, with an uncertainty marker where appropriate. Missing inputs are named
instead of depicted as a negative trait. Identity is saved locally in the App
Group and shared by app and widget.

Effects fade using `peak * 0.5^(elapsed_minutes / half_life_minutes)` and stop
below 0.05. Sweat's half-life is 20 minutes; glow's is 160 minutes. Timeline
entries let effects and lighting change without another health calculation.
Code-drawn art, poses and accessibility adaptations are implemented; final art
and the remaining physical-device review are open.

The cache becomes stale after **more than 90 minutes** and is dimmed. An earlier
day is labeled as such and does not retain today's daily avatar traits. Private
redaction uses a neutral avatar so visual health cues are hidden with the text.
Invalid or unavailable reads have explicit fallback states.

## 5. Background refresh: current implementation versus intended result

M1 app-wake/unlock diagnostics and retry code exist. M2 currently does two things:

- `StepProbe` queries today's total in the widget, logs the answer/error and
  has a 5-second continuation deadline. It does **not** publish that total into
  the displayed result.
- `EngineInputsProbe` writes `engine/engine_inputs.json` and measures reading,
  decoding and running it **inside the app process**. It checks the headline;
  that is not proof of full result equality or extension memory usage.

The extension currently links `HomeostatShared`; it does not link the pure
calculation engine. M3 must split that engine into a widget-compatible library.
The current timeline requests about 30 minutes, not the proposed 15-minute
policy. WidgetClient remains available but skips network fetching when server
sync configuration is disabled.

M2 is therefore coded but not accepted. Device logs must establish whether
step reads succeed while unlocked, with the app running and force-quit, and how
locked-phone attempts behave. App-process footprint measurements do not prove
the extension fits its own memory limit.

## 6. Revisions needed before M3

These are concrete implementation requirements, not completed fixes:

| Issue | Why it matters | Required implementation / evidence |
|---|---|---|
| Ordering only by outbox event revision | Coverage, visibility and context can change without a new event ID | Introduce a calculation-input generation covering events, coverage, reconciliation, timezone and settings; use it for both writers |
| Independent app/widget run counters | A same-revision widget result could block a later app run or accept stale work | Allocate order under the shared cache lock or compare explicit generation, authority and effective-time keys; test concurrent writers |
| Snapshot reread after app calculation | Inputs can change between the displayed run and exported snapshot | Export the same immutable inputs used by the run, with settings/version identity; compare full outputs at a fixed instant |
| Today-only step refresh | Existing common cutoff can keep effective time behind the new step read | Define mixed-age domain evaluation explicitly; do not advance sleep/HRV/workout coverage merely because steps refreshed |
| Raw log grows over time | Current export includes all visible log rows, not a guaranteed 36-day bound | Select the exact required window plus correction/deletion dependencies, or publish validated summaries; enforce byte and event limits |
| Scope, timezone, day and settings changes | An old snapshot can belong to another context | Validate all identities, clear obsolete snapshots on scope changes, reject unsupported versions and handle rollover/travel |
| Probe error and timeout behavior | A nil result currently logs zero; a timed-out query is not explicitly stopped | Distinguish unavailable from zero, retain the HealthKit store/query and stop outstanding work at deadline |
| Full workout source policy differs from future plan | Mirrored recordings can contribute extra edges | Select one authoritative stream or verified aliases before a second source; change both engines and parity fixtures together |

Do not solve refresh by replacing freshness timestamps with now, assuming every
empty query is zero, or artificially raising confidence. A steps-only update
must preserve honest timestamps and coverage for the other domains.

## 7. Revised order of goals and how to build them

> Superseded by D-D (2026-10-08): current order is in [Plan.md](../Plan.md) §5.

| Order | Goal and reason | Implementation approach | Exit evidence |
|---|---|---|---|
| 1 / M1 | Establish why background imports stop | Use observer/protected-data logs; test unlock retry with a living process | Locked/unlocked evidence and actual retry outcome |
| 2 / M2 | Prove independent widget reads are viable | Use the existing probes; measure snapshot bytes, extension runtime and peak memory | Physical step reads with app running/force-quit; budget results recorded |
| 3 / M3 | Make movement update without opening the app | Shared pure engine, immutable versioned snapshot, bounded step query, honest domain times, coordinated publication and cached fallback | App/widget full-output equality; stale-input/concurrency/error tests; physical update while app is force-quit |
| 4 / M4 | Finish G1 reliability acceptance | Background task, stale/offline recovery, lost-anchor reconciliation, local replay, 24–48-hour normal-use checks | Every acceptance row has dated evidence |
| 5 / M5 | Finish avatar quality | Replace painter through existing layer contracts; test small/medium widgets, VoiceOver, Dynamic Type, contrast and rendering modes | Final art and G2 T11/T12 acceptance after G1 |
| 6 / proposed | Add trustworthy workout logging | GRDB exercise/session/set schema; unit handling; resumable session state machine; edits and optional feedback | A real session survives termination without lost/duplicate sets |
| 7 / proposed | Add workout planning and Live Activity | Templates and deterministic candidates using explicit goals, equipment, time and recorded sessions; typed idempotent actions | Explained candidates and correct live session transitions |
| 8 / proposed | Add opt-in check-ins, then agent explanations | Preference controls, quiet hours, cooldowns and decision ledger; agent uses typed candidates and validated proposals | No unwanted repeat prompts; cited facts and validated actions |
| 9 / later | Food context, another provider, cross-device server | Separate opt-in/data contracts; provider identity gates; server only for a chosen need | Appropriate completeness, duplicate and sync acceptance tests |

No delivery dates are implied. M2 feasibility is a real gate: if the device
cannot support the step read, keep the working app/unlock/cache paths and record
the limitation instead of promising independent updates.

Workout logging comes before an agent because HealthKit's coarse workout
summaries do not contain actual exercise sets, weights, substitutions or effort.
The proposed flow is choose workout → log actual sets → give optional feedback
→ produce explained next options. Keep that path separate from G1 HealthState.
An agent may explain structured options or propose edits; typed services own
validation and storage. Live Activities, notifications and HealthKit writes are
separate additions, not consequences of the existing completed-workout feature.

Detailed proposal: [Workout_activity_agent_architecture.md](Workout_activity_agent_architecture.md).
Second-source gates: [Multi_source_platform_architecture.md](Multi_source_platform_architecture.md).

## 8. Verification for this review

The calculation-focused Python suites were run against this working tree:
`tests/features`, `tests/engine`, `tests/contracts`, `tests/providers`:
**3,502 passed**, two dependency deprecation warnings. This includes the shared
engine fixture comparison. `swift test` also completed successfully for
HomeostatCore and HomeostatShared with zero failures; optional device-database
and image-export checks were skipped when their inputs were not supplied.
The first restricted attempt could compile but did not complete the test run;
the standard-cache run completed. `git diff --check` passed. No app/widget
simulator build or physical-device acceptance was rerun for these documentation
and comment changes.
No new health formula was introduced by this review. Historical verification
counts in other plans are evidence from those dates, not a new run today.

The review updates explanations, prototype status and the work sequence. It does
not close real-iPhone gates, modify existing work in progress, implement M3, or
activate the proposed workout/agent features.
