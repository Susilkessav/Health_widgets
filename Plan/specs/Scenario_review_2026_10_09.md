# Interactive and physical review — 2026-10-09

Review only. The user requires confirmation before implementation. No native
code, tests or source previews were edited in this review. Companion and
separate rings remain working directions. Status is tracked in [Plan.md](../Plan.md).

## Interactive results

Reviewed the existing app and activity studies using temporary standalone
wrappers, browser interactions and screenshots. Both alternatives remain
available. Tested 780, 400 and 352 px browser widths; no horizontal overflow or
JavaScript page errors. These checks do not establish native WidgetKit sizing,
Dynamic Type, VoiceOver or real persistence.

| Scenario | Result | Evidence / remaining work |
|---|---|---|
| Typical sleep | Pass for available preview | Shows personal usual; no implied health score. Whole-product quiet state remains unrepresented |
| Short sleep + low/high energy | Pass for available preview | Report acknowledged; measured sleep remains unchanged; widget copy reflects the report |
| Undo / repeated selection | Pass for local preview behavior | Undo removes local acknowledgment; idempotent persistence, delete, save error and retry are not implemented in the study |
| Missing sleep | Pass for one missing domain | “No reading”; absent night excluded from average; explanation does not infer no sleep or denied access |
| All data missing / partial calibration / first-use days | Not represented | Written contract exists; needs interactive scenarios before acceptance |
| Two-hour-old reading | Partial | Age label updates, but medium widget remains full opacity. Existing 90-minute dimming requirement is not demonstrated |
| Previous-day / locked state | Not represented | Needs explicit dated fallback and locked/private scenarios |
| Privacy | Pass for available preview | Small/medium readings redact; private small-widget action opens Today |
| Fewer steps + cycling | Pass for available preview | Separate 42-minute cycling context; explanation says fewer steps do not imply inactivity |
| Late correction / source change | Not represented | Needs visible corrected evidence without duplicate totals |
| Evidence navigation | Pass for available preview | Small widget opens sleep evidence; movement card opens movement evidence. Expired/wrong-scope references remain native-contract tests |
| Calendar: zero / missing / rest / future | Pass | Zero workout day differs from “No data”; rest retains recorded steps; future cells disabled |
| Ring: missing / rest / over goal | Pass | Missing steps has no progress arc; weekly training remains independent; over-goal quantity stays visible |
| Goal and routine edits | Pass for local preview | Valid goal updates ring; zero goal rejected without changing it; Enter saves; routine updates calendar |
| Keyboard / narrow layout | Pass for tested controls | Enter activates energy, goal save and day details; narrow calendar targets at least 44 px; sampled Companion buttons at least 44 px |
| Light/dark / reduced motion | Partial | Light/narrow Companion and dark separate rings visually inspected; browser reduced-motion setting did not prevent interaction. Native accessibility remains open |
| Reminder preferences / rest context | Partial | Reminder toggle explicitly schedules nothing; rest scenario works. Quiet hours, repeated dismissals and travel are not represented |

## Proposed preview work — confirmation required

1. Add quiet, all-missing and per-domain calibration scenarios, using the actual
   readiness/count rules rather than a promised installation day.
2. Add prior-day and locked/private scenarios, and demonstrate the 90-minute
   stale appearance alongside the age label.
3. Add save failure/retry and correction/source-change demonstrations; clearly
   label them as simulated behavior, not persistence or HealthKit integration.
4. Re-run scenario, keyboard and layout checks. Keep Companion/separate rings
   revisable. No native redesign is included in this proposed scope.

## Physical checks

Device: iPhone 16 Pro Max, iOS 27.2 (24B5099f), app 1.0 build 1. Xcode reports a
wired connection. Power mode, charging and network state have not been verified.
No debugger was attached by this review, no build installed and no records deleted.
A physical walk was requested; the user said they would perform A1. A screen
check did not show the Home Screen widget, so it could not verify widget
changes; the unrelated capture was discarded. Await the user's completion
report before taking another screen observation.

Baseline app snapshot: run 534, revision 2036, effective 2026-10-09 17:59:30 UTC
(12:59:30 America/Chicago). SQLite integrity check passed. A later during-test
copy had the same result and no new background log lines. This is not yet an
A1 pass or failure: completion time, widget observation and delivery opportunity
must be recorded before interpreting it.

Historical logs show successful observer callbacks while the app was in the
background, followed by imports and local calculation (including 16:55 UTC).
These support the app background path, but do not establish that the visible
widget updated during this controlled test.

The last stored background-refresh result was `deferred_or_failed`, with no
current import errors. The cause is not established; do not mark A5 passed.
The most recent app-side snapshot probe reports 1,003 KB, 2,033 events,
187 ms read/decode/calculate, and 57.3→63.8 MB **app** footprint, with full result
matching. These are not widget-extension memory or timing measurements.

The declared shared App Group was verified through installed-app metadata.
The file service exposed only Library/Caches and Library/Preferences; no widget
manifest/probe file was accessible there. Therefore widget step-query outcomes,
extension footprint and timeline publication remain unverified. Do not infer
that the widget never ran from this file-service observation alone.

| Check | Status | What is still needed |
|---|---|---|
| A1 unlocked walking | Partial evidence | 13:29 step observer/import/calculation confirmed; 13:51 visible widget matches the 13:49 background result. Original walking interval and widget probe still unconfirmed |
| A2 locked 30+ min / unlock | Recovery verified; duration criterion open | Pending retry ran at 13:49 with app in background; errors/deferred flag cleared; widget shows new result. Observed lock was about 12 minutes, not ≥30 |
| A3 force-quit / unlocked | Feasibility pass, one observed refresh | Successful widget step read at 19:19:26 UTC within the user-confirmed force-quit window; 36 ms, 9.1 MB. Not a refresh cadence or M3 acceptance claim |
| A4 force-quit / locked | Not run | Confirm lock state and actual probe outcome |
| A5 background-task trigger | Partial evidence | Refresh start recorded at 13:40, with locked imports deferred; controlled trigger and successful completion still open |
| A6 no new data 2 h | Not run | Timed stale/dim/recovery observation |
| A7 reinstall / lost anchor | Deferred | Prepare a safe, backed-up test scope for explicit confirmation before deleting app data or a Health sample |
| 24–48 h normal use | Pending | Dated observations outside debugger after the session |


## Continued physical evidence — 13:41 CDT

The initial copy attempt failed because the phone disconnected. Xcode then
reported it connected; one retry succeeded and SQLite integrity passed.
The new snapshot advances from run 534/revision 2036 to run 540/revision 2044.

- **13:29:42:** step observer callback explicitly records `app background` and
  protected data available. Step import succeeded; calculation at 13:29:43
  produced revision 2043/run 538 in 128 ms. This confirms the background
  observer → import → calculation path during the review window.
- **13:37:12:** protected data became unavailable (locked).
- **13:40:37:** background refresh task start recorded. All five import domains
  returned HealthKit error 6; `import_deferred` is `pending`, and the task result
  is `deferred_or_failed`.
- **13:40:38:** calculation produced run 540 without advancing the input revision.
  Its effective time remains **13:32:59**, the prior data cutoff; no new reading
  is claimed from the locked attempt. Latest app-side snapshot: 1,007 KB,
  2,041 events, 193 ms, 56.9→63.3 MB app footprint, full result match.

This is partial A1/A2/A5 evidence, not acceptance. The user's walking interval,
continuous unlocked state and visible widget behavior are still unconfirmed.
The recorded locked interval does not establish the planned 30+ minutes.
An unlock-on-Home-Screen check was requested; keep Homeostat in the background
to distinguish unlock recovery from the app-open refresh path. Do not install a
build, trigger a debugger refresh or open the app before that observation.

The native widget source already applies 0.6 opacity to stale state and retains
an explicit age policy. The missing dimming found above is in the design
preview; it is not evidence that the installed native widget fails to dim.

## Unlock recovery and visible widget — 13:51 CDT

The user confirmed the phone was ready on the unlocked Home Screen. No app
launch, debugger attachment, installation or implementation change was performed
by this review. The fresh database copy passes SQLite integrity checking.

- **13:49:02:** protected data became available. The log explicitly records
  `unlock retry: import_deferred pending, store reopened false`.
- At the same time, HealthKit observer callbacks record `app background` for
  all five domains. All five import results are `ok`; `import_errors` is empty
  and the `import_deferred` key is cleared.
- **13:49:04:** calculation advances to run 541 / revision 2046, effective
  13:49:02. The full app-side snapshot result matches the calculation.
- **13:51 Home Screen observation:** the visible widget shows the same movement
  headline/value as run 541 and **Updated 13:49**. This establishes that a fresh
  background result reached the displayed widget after unlock.

The unlock handler and observer callbacks occurred together. This confirms
recovery in the ordinary unlock environment, not that either trigger alone
caused all subsequent work. The recorded lock interval is 13:37:12–13:49:02
(about 12 minutes); the planned 30+ minute A2 test remains incomplete.
`background_last_result` still reads `deferred_or_failed` despite cleared import
errors and the new local result. Keep successful local recovery distinct from
that unresolved task-status diagnostic; A5 is not closed.

The screenshot shows Wi-Fi and an 86% charging battery. Low Power Mode was not
independently verified. The screenshot and read-only database remain local at
`ready-widget.png` and `ready.sqlite` in the diagnostic directory below.

## Force-quit observation started — 13:55 CDT

The user confirmed Homeostat was swiped away, with the widget visible and the
phone unlocked. A filtered process query found only `HomeostatWidgetExtension`
(PID 13281), not the main app. The Home Screen screenshot shows the widget's
last known result, Updated 13:49. Wi-Fi and an 88% charging battery are visible.
The extension being present is not evidence that its HealthKit query succeeded.

A direct read of `widget/probe_log.txt` returned an explicit platform restriction:
CoreDevice 7000 / remote service 11007, access outside permitted **Library,
Documents, tmp** directories. This explains the incomplete App Group listing;
it does not indicate a missing log or a failed probe. No alternative path,
container mutation or new implementation was attempted to bypass it.

Observation window: keep the phone unlocked on the widget Home Screen, with
Homeostat closed, until **14:25 CDT or later**. Then open the existing app,
scroll to **Widget step probe (M2)** and read the timestamped lines. Only
successful step reads recorded after 13:55 and before app reopening count as
A3 evidence. A probe caused by reopening cannot pass this gate. If no eligible
refresh occurs, the result is inconclusive, not automatically a failed query.

M2 is logging only; it does not independently recalculate the displayed result.
An unchanged headline is expected to be possible and is not an A3 failure.
The planned M3 implementation remains conditional and requires confirmation.

## Interim observation — phone clock 14:18

The next screen capture still shows the Home Screen widget, not the M2 Debug
section. It retains Updated 13:49. The read-only database copy has no new log
entries since the prior unlock recovery and the same effective time. Despite
its diagnostic filename `m2-reopened.sqlite`, this copy does not establish that
the app was reopened. The filename is not evidence.

About 23 minutes have elapsed since the force-quit baseline at phone-clock
13:55. The planned 30-minute observation is not yet complete; keep the test
open and inspect timestamped probe entries after the remaining interval.
The user has chosen the phone timezone as the default. `sent_zone=America/Chicago`
in this copy is historical sync metadata, not independent verification of the
current system timezone. Use elapsed time for the remaining test instructions.

## M2 force-quit result — verified from the existing Debug screen

The displayed probe log contains:

`2026-10-09T19:19:26Z widget steps: 115 steps today (36 ms, footprint 9.1→9.1 MB)`

This timestamp is after the 18:55 UTC force-quit baseline and before reopening
near 19:29 UTC. The app was absent at the baseline, and the user had confirmed
it was swiped away with the phone unlocked. The 19:18 database copy still had
no new app log entries or calculation after 18:49. The successful probe arrived
about 24 minutes after the force-quit baseline; it is eligible A3 evidence.

At the end, the Home Screen still showed 104 steps / Updated 13:49, which is
consistent with M2 being a logging-only probe. Its new 115-step reading had not
been used for independent widget recalculation. The main app appeared in the
process list near the end of the window; its exact start time was not captured.
The assistant then explicitly foregrounded the existing app to inspect logs.
New observer/import/calculation activity at 19:29:12 is outside the tested
closed-app window and is not used to establish the M2 pass.

**Decision:** A3's basic read feasibility gate passes on this phone for one
observed refresh. This permits considering M3, subject to the user's explicit
implementation confirmation. It does not establish recurring reliability,
locked-state reads, extension calculation budgets, or any guaranteed cadence.
The 9.1 MB measurement is for the step probe, not the future shared-engine run.

Evidence: `m2-visible-lines.png` shows the timestamped result. Earlier entries
also show successful unlocked widget reads, including 18:49:05 (12 ms),
18:32:59 (9 ms), and 18:29:43 (11 ms). They are outside the force-quit window
and are not counted as additional force-quit successes. `m2-final.sqlite`
remained unchanged before the end-of-window app opening; `m2-after-open.sqlite`
contains the later app activity. The native app and source previews were not
modified or reinstalled.

Local screenshots, copies and browser logs are in
`/tmp/homeostat-scenario-review-20261009/`. They are diagnostic evidence, not
repository health fixtures, and may be removed by system cleanup.
