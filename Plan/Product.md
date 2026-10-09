# Homeostat — app and widget experience

Updated: 2026-10-09. What the app and widget should do and look like. Order,
status and the checklist are in [Plan.md](Plan.md); the long-term vision is in
[specs/Whole_project.md](specs/Whole_project.md).

Status: review in progress; confirmation required before implementation. Redesign remains design studies, not native P1.
**Visual design stays flexible:** Companion and separate rings are working
options. Real-data findings and implementation contracts are in
[Daily_loop_contract.md](specs/Daily_loop_contract.md).

## 1. Experience goal

Use the phone’s current system timezone by default for displayed times and current local-day boundaries. Follow timezone changes during travel while preserving original event timezone/provenance. No fixed Chicago default in the product experience.

Answer three questions: **What changed? Why does it matter to me? What can I do
next?** The widget supplies one useful observation; the app provides its
evidence, history and controls. The user can respond and see that response
acknowledged. No opaque global health score is needed.

The first product loop is: glance → understand → optionally check in → see the
response reflected. Workout logging becomes the next substantial expansion.
Design work can proceed alongside reliability work; it is not proof of native
functionality or permission to skip acceptance.

### Validate the premise first

Synthetic studies cannot show whether real data produces observations worth a
glance. Before more design work, replay the user's last 30–60 days through the
engine (existing device replay tests) and record, per day: headline produced,
quiet ("no meaningful change"), or calibrating. Read the actual headlines. If
quiet days dominate, the quiet-day widget is the primary design, not an edge case.

After P1 ships, each energy check-in also asks one optional question: does the
widget's observation match how you feel (Yes / Not really)? Store it with the
entry. This is the product's usefulness measure; §7 usability goals use it.

### First two weeks

Comparisons need a per-domain personal baseline. Installation age does not
predict readiness: imported history may make a domain ready immediately, while
gaps can leave another learning beyond two weeks. The current minimum is 14
usable days; read it from settings/feature metadata, never hard-code a promise.

- **First use:** available sleep/steps as plain values with their times;
  each domain's actual “learning your usual: N of M usable days” progress.
- **Partial readiness:** show comparisons for ready domains while keeping
  learning/missing labels on the others. Do not hide a ready domain behind
  global calibration.
- **Ready domains:** normal supported comparisons; never imply readiness from
  “day 10+” or a count of days since installation.

Quiet/new-user copy, actions and evidence rules are specified in the
[daily-loop contract](specs/Daily_loop_contract.md). Interactive/native validation
remains open in the tracker.

## 2. Data inventory and boundaries

| Input | Collection today | Useful features | Boundary / additional work |
|---|---|---|---|
| Sleep intervals and recorded stages | HealthKit import built | Duration, timing, baseline comparison; proposed stage timeline, regularity and separate naps | Stage availability varies; naps/regularity require new presentation or feature work. Shift-work episode policy needs explicit support |
| HRV SDNN | HealthKit import and comparison built | Compatible personal trends; one input to recovery context | Not interchangeable with other HRV methods; not a standalone stress or illness detector |
| Resting heart rate | HealthKit import and comparison built | Personal trends and changes alongside other signals | Do not invent a cause or describe exercise clearance |
| Hourly steps / cumulative snapshots | Import and time-matched comparison built | Movement pacing, hourly history, user goals | Low steps do not establish sitting, inactivity or lack of exercise |
| Completed workout type, start/end and duration | HealthKit import built | Recent workout, weekly minutes and frequency | No live tracking, sets, intensity, muscle fatigue or training load from duration alone |
| Sources, timestamps, coverage and baseline counts | Built in current pipeline | Explanation, freshness, missing-data and calibration states | A completed query or absent result does not prove access or zero activity |
| Energy, mood, stress, soreness and notes | New optional local logging | Check-ins, subjective trends, user-reported soreness map | Store separately from measured state; never overrule a report with sensors |
| Goals, preferences, available time, rest/travel context | New user settings/logging | Relevant suggestions, reminder controls, context annotations | Explicit choices take precedence over inferred habits |
| Workout effort, exercises, sets/reps/load | New workout journal | Perceived load, progression and recently trained regions | Planned sets are not performed sets; recently trained is not sore |
| Plans and calendar availability | New planner; optional calendar integration | Reminders, conflicts and proposed rescheduling | Request access only when enabled; preview changes before committing |
| Caffeine, water, meals | New logging / expanded compatible HealthKit import | Consumption timelines, reminders, exploratory associations | Say water logged, not hydration status; missing food logs are not zero intake |
| Exercise heart rate, pace, distance | Expanded HealthKit/session collection | Richer workout summaries and session feedback | Not currently imported by Homeostat's adapter |

Use only required permissions, with a plain explanation of the feature each
enables. No HealthKit write permission is introduced by this design. Additional
types need data contracts, compatible sources and appropriate coverage handling.

## 3. Widget family

Default: **Your day**, the only P1 widget. In P1b users can pin sleep, movement,
recovery context or recent workout instead. Avoid rapid headline rotation and retain the selected focus.

| Widget / mode | Information | Interaction | Delivery |
|---|---|---|---|
| Your day | Avatar, strongest relevant supported change, one comparison, last update | Open exact explanation; medium adds check-in entry | P1 |
| Morning sleep | Duration, usual duration/difference | Open sleep; optionally report energy | P1b focused configuration |
| Movement pace | Steps and usual steps by comparable local time | Open movement detail | P1b only if M2 passes (widget reads HealthKit itself); otherwise later, with a prominent "as of" time |
| Recovery context | Supported sleep/HRV/resting-HR interpretation, mixed/missing signals | Open contributing evidence | P1b focused configuration |
| Recent workout | Type, duration, completion time | Open journal; effort after workout logging ships | P1b summary; P2 effort |
| Quick check-in | One question with Low / Okay / High | Save with acknowledgment and undo | P1 in app; widget save via the App Group inbox (§5) |
| Pinned goal | User-selected metric/goal, distinct from usual baseline | Open goal settings/detail | P2 |
| Data status | Per-domain baseline progress or age/missing input | Open data explanation | P1, also a fallback in every mode |

### Layouts

- **Small:** avatar or metric emphasis, one headline, one comparison, update
  time; one whole-widget deep link. No tiny independent tap regions.
- **Medium:** avatar + headline + comparison + one labeled action + update time.
- **Large:** primary message plus at most two supporting metrics and a compact
  trend; defer native build until small/medium usability is verified.
- **Lock Screen:** later, opt-in private glance with suitable redaction.
- **Workout Live Activity:** P2 active-session timer, exercise, set/rest state
  and validated controls. Do not simulate this with Home Screen refreshes.

WidgetKit controls use App Intents; detailed forms open the app. A reload request
does not guarantee current health readings. Always preserve existing stale,
prior-day, scope, privacy and cache-ordering policies. New focus ranking belongs
in the shared presentation mapping, not duplicated in a SwiftUI view.

## 4. App information architecture

Three initial destinations: **Today · Trends · Journal**. Profile/settings is a
separate toolbar entry. Add Plan only once workout scheduling is substantial.

| Screen | Primary content | Action / next layer |
|---|---|---|
| Today | Time-aware greeting; avatar and supported headline; Sleep, Movement, Recovery and recent workout; per-domain freshness | Explain a card, record energy, open journal |
| Explanation | Current value, personal baseline, difference, observation time, source and evidence limitations | Expand data details; return to the exact originating context |
| Activity history (within Trends, P1b) | GitHub-style daily calendar, filtered by workouts, steps or routines; rest/missing/zero distinct | Select a day to see actual events and provenance; §10 |
| Goal rings (P3, optional; Today) | Separate or nested labeled rings; daily movement, weekly workouts and optional daily routine | Open evidence, edit a goal or log a chosen routine; §10 |
| Trends | 7/28 days initially; 90 days only once retention and coverage support it; typical ranges and explicit gaps | Select a day/metric, inspect observations; annotate context |
| Sleep | Asleep versus in-bed time, interval timeline, timing consistency and separately identified naps | View baseline and source; set preferred schedule |
| Movement | Hourly steps and same-time comparison; workouts alongside steps; separate personal goal | Inspect hour/day, edit goal |
| Recovery | Contributing measurements and their distinct ages; mixed or insufficient input states | Explain each contribution; add subjective energy |
| Journal | Workouts, check-ins and context events; event time distinct from arrival time | Add/edit/delete own entries; expand imported session |
| Weekly review | Three supported observations, stable/positive patterns, one optional goal adjustment | Inspect the underlying days; adjust a preference |
| Pattern discovery | Exploratory associations, sample count, uncertainty and possible confounders | Review data, optionally plan a personal experiment |
| Data & privacy | Sources, coverage, per-domain calibration, optional sync, export/delete and widget visibility | Manage permissions/settings with accurate explanatory text |

Explanation layers: (1) plain meaning, (2) comparison/evidence, (3) provenance.
Raw state names, numeric confidence/severity and engine hashes belong in
expanded data details or Debug, not the default user journey. Label confidence
as data support, not a probability of health. A personal baseline is usual,
not necessarily ideal. Goals remain separate.

## 5. Reactive behavior

| Trigger | Product response | Must retain |
|---|---|---|
| Shorter sleep + user reports good energy | Show both, acknowledge energy, suppress repeated tiredness prompts | Original measured sleep and comparison |
| Typical readings + user reports exhaustion | Acknowledge low energy; offer a lower-demand option if wanted | User report without a sensor-based contradiction |
| Low steps + cycling/swimming record | Mention that activity; suppress simplistic inactivity claims | Actual steps, workout type/duration |
| Check-in save/edit/delete | Confirm, update relevant card and journal; undo where possible | Idempotent action and local timestamp |
| Reminder dismissed | Snooze immediately; after repeats offer frequency/topic control | Quiet hours, cooldown, user preference |
| Late/corrected sample | Recalculate and explain a material revision | Event time versus sync time; no duplicate activity |
| Rest day, travel, illness or injury context | Annotate trends; adjust prompts/goals for user-selected duration | No diagnosis or automatic rewriting of measurements |
| Missing/old data | Keep supported domains useful; label affected domain unavailable/old | Never zero-fill, fabricate healthy status or call old data current |
| No meaningful change | Remain quiet | Stable headline and user focus |

Default to in-app prompts. Notifications are opt-in, topic-specific, bounded,
and respect quiet hours and acknowledgment. No AI is required for these rules.
Agent assistance later consumes typed evidence and validated proposals.

### Check-in architecture gate

Add a local `SubjectiveEntry` with stable ID, kind, value, event time, timezone,
created/updated times and optional note/context. Build a single idempotent app
service for create/edit/delete; keep it separate from measured HealthState.
A widget button's App Intent runs in the widget extension, not the app, so it
cannot call the app's service while the app is not running. Instead:

- The intent appends the entry (with its stable ID) to an inbox file in the App
  Group, and shows "saved" only after that write succeeds.
- The app ingests the inbox on launch and on each refresh into GRDB, skipping
  IDs it already has, then removes ingested entries and publishes a new snapshot.
- The extension never writes the app GRDB database. Locked-device writes depend
  on the inbox file's protection class; verify on device. If the write fails,
  open the app instead.

## 6. Visual design direction

**Quiet, human and precise.** Native iOS typography, warm neutral surfaces,
deep green actions, restrained lavender for sleep context, generous spacing.
Use semantic light/dark tokens, text with every status, and clear selected
states. Avoid red/green health grades and invented scores. Goal rings must encode
explicit user-chosen targets and units (see §10), never decorative health grades. Use a customizable human avatar; data never changes body shape.

Two first design studies use the same data and actions:

- **Companion:** avatar-led summary, explanatory sentence and compact evidence
  cards. The current working direction; still revisable.
- **Focus:** metric-led summary with a smaller avatar; denser scan-friendly
  evidence rows. Also informs an eventual user-selectable metric-first mode.

The initial interactive study covers Today, Trends, Journal, sleep explanation,
energy check-in/undo and matching small/medium widget glances. Example values
are synthetic and visibly labeled. Avatar art is a layout placeholder. The
study does not save health data, connect HealthKit or implement WidgetKit.

### Component and accessibility rules

- Shared components: StateSummary, MetricEvidence, FreshnessLabel,
  BaselineProgress, CheckInControl, TimelineEntry and ExplanationSheet.
- Use native Dynamic Type styles in SwiftUI; 44 pt minimum interactive targets.
  At accessibility sizes, stack content and reduce optional detail rather than
  shrinking essential text. No information only on hover or avatar appearance.
- Support VoiceOver, reduced motion, increased contrast, tinted/clear widgets
  and privacy redaction. Text-first alternative remains complete.
- In the app, avatar regions and equivalent labeled cards reach the same
  explanation. Small widget uses a single unambiguous deep link.
- No looping animation required for understanding. Test light/dark and 320 pt
  layouts, then real widget families; browser sizing is only approximate.

## 7. Phases and acceptance

| Phase | Scope | Exit |
|---|---|---|
| D0 — design now | This plan, flow/layout specifications, interactive Companion and Focus study | Reviewable screens and working sample interactions; no native completion claim |
| P1 — the daily loop | Today, one small/medium **Your day** widget, explanation redesign, energy check-in (app and widget inbox), first-two-weeks states | Widget → exact evidence works; check-in persists/edit/undo works; quiet and calibrating states designed; all data states and accessibility pass; a week of real use on device; G1/G2 gates satisfied before release |
| P1b — after a week of P1 use | Focused/pinned widgets (Movement pace per M2), sleep/movement trends, available-history activity calendar, Journal shell, data controls | Trends show gaps and retention honestly; calendar zero/missing/rest distinct |
| P2 — activity and reflection | Resumable workout logging, effort, goals, richer sleep/movement views, day replay, weekly review; then planner and Live Activity | Real session survives termination; no duplicate sets/workouts; summaries traceable; validated live actions |
| P3 — personalization | Optional goal rings (§10), more subjective fields, temporary contexts, opt-in reminders, calendar integration, expanded workout metrics, optional agent explanations | Preferences and context consistently affect suggestions; approved actions auditable; prompts can stay quiet |
| P4 — optional exploration | Food/caffeine/water context, pattern discovery, experiments and what-if views | Sufficient input quality; associations labeled; forecasts explicitly hypothetical |

Before P1 native implementation, define the presentation and action contracts,
trend retention, deep-link fallback, redaction and check-in persistence. Swift is
the source of truth for presentation wording/ranking (calculation is on device);
Python keeps engine parity; existing stored mapper output stays unchanged until
the new UI presentation layer lands. Do not
introduce health thresholds from mockup copy. The study uses a sleep deviation
of 70 minutes to fit the existing below-baseline rule.

### Required design scenarios

1. Typical day with complete inputs.
2. Short sleep; user reports low energy and then good energy.
3. No data; one domain missing; partial and completed per-domain calibration.
4. Cached result older than 90 minutes, prior-day result, locked/private state.
5. Low steps with a cycling workout; no false inactivity claim.
6. Late correction and source change; explain revised evidence.
7. Save failure, retry, duplicate tap, edit/delete/undo of a check-in.
8. Large text, VoiceOver, reduced motion, light/dark/tinted appearance.
9. Rest/travel context and repeated reminder dismissal before proactive delivery.
10. Quiet day with no meaningful change; new user on days 1, 3 and 10.

Validate that a person can identify the main observation within a brief glance,
find its evidence in one tap, distinguish measured from reported state, and
record energy without a survey. These are usability goals to test, not results
already demonstrated; the check-in agreement answer (§1) is the ongoing measure. Design-only changes need link/consistency and prototype
interaction/layout checks; native changes follow the master verification rules.

## 8. Platform references

- [Widget interactions](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- [Widget update scheduling](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [HealthKit data types](https://developer.apple.com/documentation/healthkit/data-types)

The platform references inform implementation; neither a supported type nor a
scheduled refresh is evidence of a measurement arriving on a user's device.

## 9. Design evidence — 2026-10-08

- Created the interactive Companion and Focus studies in this chat. Both use
  Today, Trends and Journal; sleep/movement explanations; energy entry/undo;
  widget privacy; and small/medium widget glances. Avatar art is a placeholder.
- Local Chromium/Playwright smoke checks passed: navigation, explanation deep
  links, energy acknowledgment reflected in widget copy, undo, privacy toggle
  and reminder preference. No page JavaScript errors were reported.
- Shorter sleep, typical sleep, missing sleep and older-update scenarios passed.
  Missing nights are excluded from averages and explicitly labeled.
- Both variants had no horizontal overflow at browser widths 780, 400 and
  352 px (the smallest gives approximately 320 px to the preview iframe).
- Visually inspected Companion, Focus, explanation, trends, narrow-screen and
  dark-appearance captures. Plan links, fragment syntax and `git diff --check`
  passed. Browser checks do not establish native Dynamic Type, VoiceOver,
  WidgetKit sizing or physical-device acceptance.
- Native implementation, remaining required scenarios in §7, final artwork and
  user usability review remain open. No native/backend code changed for D0.


## 10. Daily activity calendar and goal rings — exploration, 2026-10-08

The user requested GitHub-style daily workout/other-activity status and ring
tracking, while explicitly keeping the overall visual design open. Neither
Companion nor Focus is final. The selected preview variant is not design approval.
Explore these components independently before deciding their place in the app.

### Daily activity calendar

- Place **Activity history** in Trends, with a compact recent-period preview on
  Today if useful. One square per local calendar day, rows Monday–Sunday and
  columns weeks. Label months/week ranges and the current date.
- Switch the measured layer: **Workouts** (recorded minutes), **Steps** (count),
  **Routine** (completed chosen items). Never combine incompatible quantities
  into a hidden activity score. Manual routine entries need new logging support.
- Shade represents quantity in explicit, stable bands, not effort, health or
  deservingness. Example workout bands: 0, 1–19, 20–39, 40–59 and 60+ minutes.
  These are display bins for the study, not medical/activity recommendations.
- Distinguish **0 recorded**, **no data (?)**, **rest planned (R)** and future
  dates. Rest is a user annotation, not an inferred absence of workouts, and
  can coexist with recorded walking or other activity. Preserve the actual
  metric shade underneath its rest marker. Never mark rest as failed activity.
- Selecting a day reveals date, value/unit, recorded workouts, movement,
  routine completion, source/coverage and annotations. Tap, keyboard and touch
  must all expose details without requiring hover. Corrected/deleted events
  update aggregates; retry deliveries never add sessions or minutes.
- A compact 12-week view is appropriate at wider sizes. On narrow/coarse-pointer
  screens, show four weeks with navigation and approximately 44 pt targets,
  rather than shrinking a year's days into untappable pixels. Later year view
  can be a visual overview that opens an accessible month/week detail.
- Historical views require retention beyond the current import/baseline window.
  Native P1b can ship only the period with retained, supported observations;
  do not imply that the synthetic 12-week study is already available in the app.
- Prefer days with recorded activity / supported days and weekly consistency
  over an unbroken daily exercise streak. Do not penalize planned rest or
  silently include unknown days in a denominator. No routine logging is not
  proof that no routine was performed.

**Rings deferred to P3 (revised 2026-10-08).** Apple Fitness already shows
rings, so Homeostat's would invite direct comparison, and they need goal
persistence/versioning, completion rules and routine logging. The calendar is
the differentiated component and continues. If rings return, they show only
user-set goals. The rules below are kept for that point.

### Ring contents — proposed defaults, configurable

| Ring | Example | Period and source | Interpretation |
|---|---|---|---|
| Movement | 4,800 / 6,000 steps | Today; HealthKit step aggregate; user goal | Progress against a chosen goal, not the personal baseline |
| Training | 2 / 3 sessions | This local week; deduplicated completed workout records; user goal | Allows rest days without a daily workout requirement |
| Routine (optional) | 1 / 2 chosen items | Today; new local routine logging | Explicitly logged completion, not inferred wellbeing |

All example goals are illustrative, not recommendations. Each ring must expose
its label, period, actual value, target, unit, freshness and data availability.
A mixed-period group is labeled **Today & this week**, never simply Today.
An optional single-focus widget shows one ring with its period and evidence link.
Do not add active calories, stand hours or training-intensity rings without
collecting the required data and defining a sound calculation first. Recovery
and HRV are explanatory context, not goals to close. Sleep should not imply that
more is always better; a future sleep target needs separate range semantics.

### Ring style alternatives

1. **Separate rings:** one clearly labeled circular measure per row with values
   and period next to it. Easy to scan and independently tap; stacks naturally
   with large text. Leading candidate for readability, not a fixed selection.
2. **Nested rings:** three concentric arcs and matching labeled evidence rows.
   Compact visual summary; outer-to-inner order is Movement, Training, Routine.
   Each matching row is a real accessible tap target; users need not hit an arc.
   The center shows a selected metric, never an invented combined percentage.
3. Discrete session/routine progress may use segments in a future refinement;
   continuous step progress remains smooth. Compare comprehension before adding
   visual complexity; the first study compares alternatives 1 and 2.

### Ring status and action rules

- Progress = actual / positive target for the same metric and period. Cap the
  drawn arc at 100%; retain the true total and label over-goal progress. Do not
  add repeated laps or push the user to keep exceeding a goal.
- No target: show actual value plus Set goal, not an arbitrary denominator.
  Zero/invalid target is rejected, never used as a divisor.
- Missing input: neutral broken/dashed track and No data; do not draw 0% or
  a complete ring. Partial input shows a lower-bound total and coverage note.
- Planned rest: label it explicitly. Weekly training progress remains what was
  recorded; never auto-fill a training ring for resting or label rest a failure.
- Current day/week remains in progress. Old snapshots retain their update time;
  future dates have no progress. Mark paused goals explicitly if pause ships.
- Tap a ring's labeled control to inspect evidence and edit its sample goal.
  Routine check/uncheck updates today's routine ring and calendar together;
  native changes require durable, idempotent create/edit/delete plus undo.
- Goal changes apply prospectively with effective date/period and version.
  Historical progress uses the goal in effect then; do not rewrite history.
- Preserve measured quantities separately from goal status and annotations.
  Week start is explicit and eventually configurable; cross-midnight activity
  duration is assigned by local overlap, session counts by completion day.

### Delivery and acceptance

D0: calendar interactions (ring studies paused). P1b: recorded workout/step
calendar for available history. P2: routine logging; longer history only after
retention work. P3: optional rings with goal persistence/versioning. Integrate
with the existing workout deduplication/source-policy gates before counts ship.

Add `DailyActivitySummary` (local date/zone, metric/unit/value, coverage, evidence
refs, annotations, version) and `GoalDefinition` (metric/unit, target, period,
effective dates, optional pause) to the design contract work. Ring state is
presentation over these values, not a new HealthState score. Imported and local
workout aliases must contribute once.

Required checks: week/day/timezone boundaries; no data versus supported zero;
rest with movement; mixed-period labels; future cells; over-goal capping; no/
invalid goal; late corrections and duplicates; accessible day selection; goal
edits leaving history intact; routine completion reflected in both surfaces.
The prototype uses synthetic history and sample goals. No native functionality
or medical targets are introduced by this study.


### Prototype evidence — 2026-10-08

Created a separate interactive study with Separate rings and Nested rings; the
original app study remains available and neither is a final design. Local
browser checks passed for metric filtering, date selection, future-date
ineligibility, sample goal changes, routine completion reflected in both rings
and calendar, missing-step/rest/over-goal states, both styles at 780/400/352 px,
and four-week navigation with at least 44 px targets on narrow layouts. No page
JavaScript errors were reported. Visually inspected both styles plus narrow and
dark appearances. The sample goal action was repaired after the first browser
check exposed that native form submission is blocked in the preview sandbox.

These checks cover the study, not native accessibility, persistence, HealthKit
coverage, historical goal versions, or workout deduplication. Those gates remain
open. The ring contents, activity bins, color mapping and layout are proposals.
