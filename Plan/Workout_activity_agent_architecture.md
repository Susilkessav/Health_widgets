# Workout, activity and check-in architecture

Status: proposed design, 2026-10-05. No implementation is claimed here.

## 1. Product goal

Help a person choose, complete and reflect on activity using their own history,
stated preferences and available health context. The system may suggest workouts,
lighter activity, food ideas or a check-in, and must also be able to stay quiet.
The person remains in control of plans, exercise selection, weights, food and
notification preferences. HealthState is wellness context, not exercise clearance.

The first shipped loop should be: choose a workout -> log sets -> reflect on
effort -> see an explained next option. Proactive check-ins and food suggestions
follow only after the input and feedback loops work reliably.

## 2. Current foundation and placement

The current phone path is HealthKit -> ImportEngine -> LocalStore -> Swift
features -> HealthState -> WidgetState -> App Group cache -> widget. Python is
the reference engine and an optional server. Workout history today is coarse
HealthKit workout data; there are no Homeostat exercise/set records, planner,
agent or notification decision service. The app is read-only with respect to
HealthKit. Do not change G1 HealthState semantics to carry workout planning.

Add a separate local planning path:

```
HealthKit events --------> HealthState -----------------------+
                                                               |
Homeostat workout log --> WorkoutSummary --> ActivityPattern   |
User preferences -------> PlanningContext --------------------+--> SuggestionEngine
Optional food log ------> FoodContext -------------------------+         |
                                                                          v
                                                               Policy + CheckInPlanner
                                                                          |
                                                 +------------------------+----------------+
                                                 v                        v                v
                                            App/Widget               Live Activity      Agent
                                                                    during session    explanation
```

The agent consumes typed summaries and suggestion candidates. It does not
calculate HealthState, infer unrecorded sets, or decide independently when a
notification is sent.

## 3. Six decision layers

1. **Evidence and quality.** Determine what was observed, its source, local
   time, age, completeness and confidence. Deduplicate HealthKit workouts that
   correspond to a Homeostat session. Unknown is distinct from zero.
2. **Interpretation.** Calculate trends: usual active windows, session
   frequency, exercise history, recent training volume and explicit user
   feedback. Trends need sample counts and uncertainty; a few occurrences are
   observations, not a fixed routine.
3. **Candidate generation.** Produce 0-3 feasible options from templates and
   rules: planned session, short alternative, lighter activity or rest. Apply
   goals, time, equipment, exercise preferences and recent training history.
4. **Policy and prioritization.** Remove ineligible options, apply user limits
   and rank the remainder. Respect pain/injury flags, disabled topics, missing
   information, notification caps and source confidence. HealthState may adjust
   wording or offer an easier option, never diagnose or prescribe clearance.
5. **Delivery.** Decide whether to show a card, ask a check-in or stay quiet.
   Choose the time from confirmed preferences first, then observed windows.
   Respect quiet hours, cooldowns, snoozes and already-completed activity.
6. **Conversation and action.** An optional agent explains the selected
   evidence, asks one useful question and proposes edits. The user's reply is
   parsed into an explicit command; a typed application service validates and
   commits it. The agent cannot silently create, change or complete a workout.

Each layer emits a versioned result with reason codes so a decision can be
replayed and explained. `NO_ACTION` is a valid output at layers 3-6.

## 4. Data model

Use stable UUIDs, explicit instants plus IANA timezone, created/updated times,
source and schema version. Keep structured workout and preference data in the
phone's GRDB store. Publish only the compact display/action state to the App
Group; the widget should not receive the complete health or food history.

| Entity | Important fields | Purpose |
|---|---|---|
| Exercise | ID, name, movement pattern, equipment, muscle regions, aliases | Stable catalog and substitutions |
| WorkoutTemplate | ID, goal, exercises, target sets/reps, estimated minutes, version | Reusable plan |
| PlannedSession | ID, local date/window, template, status, provenance | Intent, separate from actual work |
| WorkoutSession | ID, start/end, type, state, source, linked HealthKit record | Actual workout and duplicate reconciliation |
| ExercisePerformance | Session ID, exercise ID, order, substitution | Exercise within a session |
| SetPerformance | Set ID, reps, load value/unit, set type, completion, time, effort | Actual strength history |
| SessionFeedback | Effort, energy, soreness/discomfort, enjoyment, notes | User-reported context |
| ActivityPattern | Window, weekday, observed count, recency, confidence, version | Explainable timing trend |
| UserPreference | Goals, equipment, time windows, exclusions, food preferences | Explicit user control |
| Suggestion | Type, candidate, evidence refs, reason codes, score, expiry, status | Auditable proposal |
| CheckIn | Suggestion ID, scheduled time, channel, prompt, response, outcome | Prompt lifecycle and cooldown |
| FoodEntry | Optional logged item, portion, nutrient provenance, completeness | Food context, not assumed intake |

For load, store the entered unit and a normalized value; distinguish bodyweight,
assistance, machine stacks and dumbbell per-hand values. A set with missing
weight must remain valid. Never infer a performed set from a plan. Import
HealthKit workouts as activity summaries, and explicitly link a locally
recorded session to its HealthKit sample to avoid double counting.

## 5. Workout and activity rules

### Before a session

- Offer a planned workout if one exists and remains feasible.
- Otherwise generate short options from recent exercises and templates.
- Consider session spacing, recent exercise volume, available time and
  equipment; let user-stated goals and constraints override inferred patterns.
- Show an explanation such as “Legs were trained yesterday; upper body is an
  option today,” citing the underlying sessions and noting missing history.
- Offer Start, Swap and Skip. Do not automatically start a session.

### During a session

- The app owns exercise order, set entry, edits and history. Prefill a proposed
  set from the last comparable performance, clearly marked as a proposal.
- A Live Activity shows current exercise, set count, rest timer and a small
  action. A widget shows a glance and links into the active session.
- Intents write through one session service with idempotent action IDs. They
  validate session ownership, current state and duplicate taps before commit.
- Keep the local database as source of truth; rebuild display state from it.

### After a session

- Confirm the actual record, then ask for one or two optional subjective inputs.
- Update activity patterns and future candidate evidence after the session
  commits. A missed planned session remains a missed plan, not a workout.
- Saving a workout to HealthKit, if implemented, needs separate user permission
  and a reconciliation ID; a write failure must not erase the local log.

## 6. Timing trends and check-ins

Start with a transparent rolling history, for example eight weeks of local
weekday/time windows, and keep the window configurable. Each pattern records
its sample count, recent examples and confidence. Do not turn a pattern into
a user preference without asking. Travel and timezone changes should preserve
the source local time and avoid treating a shifted clock as a changed habit.

Check-in decision order:

1. Is the feature enabled, and is this topic allowed?
2. Is there a useful candidate or an explicit plan to discuss?
3. Is the pattern supported, or has the user confirmed this time window?
4. Has the person already exercised, dismissed, snoozed or answered today?
5. Are quiet hours, channel caps and cooldowns satisfied?
6. Is this still actionable at delivery time? Re-check before showing it.

Initial defaults: at most one proactive workout check-in per day, no repeated
prompt after dismissal that day, and no nutrition prompt without nutrition
opt-in. Make limits user-adjustable. Record decision outcomes, including
`NO_ACTION`, for tests and later tuning. A suggested time is never a promise:
iOS controls background execution and notification delivery.

## 7. Food and broader activity suggestions

Food suggestions begin as preference-aware ideas: e.g. a post-workout meal
option or a reminder to log food if the user opted in. Do not calculate a
precise deficit, protein target or “recovery food requirement” from sparse
HealthKit values. Separate logged intake from unlogged/unknown intake and
record provenance for nutrition imported from HealthKit or another provider.
Respect allergies, dietary restrictions, disordered-eating safeguards and a
user option to disable food advice entirely. A user-reported concern that
requires medical judgment should route to appropriate professional help rather
than an automated personalized prescription.

Broader activity suggestions can offer a walk, mobility or rest choice from
the person's preferences and recent activity. Do not translate a low recovery
label into a command to stop exercising. State the available evidence and
allow the user to choose.

## 8. Agent contract

Give the agent only a typed `SuggestionContext`: allowed data categories,
summary facts, provenance IDs, uncertainty, candidate options, user preferences
and current check-in status. Prefer local reasoning or explicit opt-in before
sending sensitive records to a remote model. Do not send raw time series or a
full food diary merely to generate a short prompt.

Agent output is a structured proposal, not an executable instruction:

```
AgentProposal {
  kind: NO_ACTION | EXPLAIN | ASK | SUGGEST | PROPOSE_EDIT
  candidate_id?: UUID
  message: String
  cited_evidence_ids: [UUID]
  proposed_command?: TypedCommand
}
```

The application validates cited IDs, numeric claims, allowed topics and
command parameters. User confirmation is required for plan edits, session
changes, HealthKit writes and external actions. Failed validation falls back
to a deterministic explanation or no action. The agent never directly writes
GRDB, HealthKit or notification schedules.

## 9. UI surfaces

| Surface | Job | Maximum initial interaction |
|---|---|---|
| Small widget | Avatar/health glance plus one workout cue | Open workout or one focused action |
| Medium widget | Cue, reason and active-session summary | Start, swap or open session |
| Live Activity | Current exercise, set/rest and progress | Complete set, pause or open app |
| Main app | Full exercise/set editor, plan, history and explanations | All detailed edits |
| Check-in | One timely question | Answer, snooze, dismiss, change preference |

The widget should remain readable without the workout feature. If an avatar
is added under G2, workout cues compose with AvatarState rather than replacing
sleep, movement and recovery channels with one global mood.

## 10. Services and code boundaries

- `HomeostatCore/Workout/`: contracts, catalog, session state machine,
  template expansion, trend calculator, candidate generator and policies.
- `LocalStore` migrations: workout, preference, suggestion, check-in and
  decision-ledger tables. Never embed this history in `WidgetCache`.
- `HomeostatCore/Agent/`: typed context builder, proposal validator and
  deterministic fallback. Network/model adapter, if any, is separate.
- iOS app: workout screens, feedback screens, notification authorization and
  delivery, HealthKit writing if chosen.
- `HomeostatShared`: minimal widget/Live Activity view models and action IDs.
- Backend: optional account sync later. Preserve per-installation IDs and
  idempotent writes if workout plans cross devices.

Keep G1 `DailyFeatures -> HealthState` independent. A future training-load
feature can be versioned separately and included only after it has a defined
meaning, fixtures and parity tests.

## 11. Verification and rollout

1. **Foundation:** schema migration, workout/session/set state machine,
   duplicate reconciliation and local persistence. Test crash/retry, edits,
   units and repeated widget taps.
2. **Logging:** app session UI and optional Live Activity. Verify a real workout
   with app foreground, background and locked-device transitions.
3. **Planning:** templates and deterministic candidate rules. Golden cases:
   no history, changing schedule, travel, missed plan, unavailable equipment,
   soreness, workout already completed and conflicting sources.
4. **Check-ins:** opt-in settings, timing patterns, policy engine, cooldowns
   and decision ledger. Measure useful response rate and unwanted prompts.
5. **Agent:** explanations and edits restricted to validated candidates. Test
   invented measurements, stale context, invalid command parameters and
   prompt injection in user notes or imported metadata.
6. **Food context:** optional logging and preference-aware ideas after data
   completeness and user-control flows are verified.

Before rollout, complete the outstanding real-iPhone G1 acceptance gate.
Build the logging foundation before agent recommendations: a model cannot
reliably recommend set/weight changes without trustworthy actual-set history.

## 12. Acceptance criteria

- A workout can be started, logged, edited, ended and recovered after app
  termination without losing or duplicating sets.
- Every suggestion shows the evidence and uncertainty that produced it.
- The user can disable or correct any inferred routine or suggestion topic.
- No check-in is sent after a same-day dismissal, completed session or quiet
  hour policy block.
- Missing nutrition or sensor history never becomes a zero value or a confident
  claim; no medical clearance is inferred from HealthState.
- The agent cannot commit an action without the typed service and required
  user confirmation.
- The widget remains responsive and legible without network access, an agent
  service or nutrition data.
