# Daily loop — implementation contract

Updated: 2026-10-09. Implementation requires confirmation under the latest user instruction. Companion is the working
app/widget direction; separate rings are the working P3 option. Both remain
revisable. Progress lives only in [Plan.md](../Plan.md). This specification
prepares P1; G1/G2 device acceptance still precedes the native daily-loop build.

## Evidence driving the design

A read-only copy of the connected iPhone database passed SQLite integrity
checking. The 60-day request yielded **51 supported local-noon checkpoints**,
2026-08-20 through 2026-10-09: **29 observation headlines, 22 calibration
messages, 0 typical/quiet headlines and 0 no-data headlines**. All 29 observation
headlines concern movement. Python and Swift produced identical features,
HealthState and WidgetState at all 51 checkpoints.

This is reconstructed output from retained/corrected observations, not a log
of what appeared on screen. No inference about actual user usefulness follows
from these counts. Missing or deleted historical inputs and sampling at noon
limit the review. Global calibration can remain incomplete while movement has
a ready baseline; a typical ready domain can then be obscured by the global
calibration headline. Zero quiet headlines does not establish zero quiet days.

Consequences:

- Show calibration **by domain**, using its actual usable/required days. Do not
  promise that all comparisons unlock on day 10 or after a fixed installation age.
- Keep usable domains visible when another domain is learning or missing.
- Describe step comparisons as **“Fewer steps than usual by this time”** or
  **“More steps than usual by this time”**. Steps alone do not measure all activity.
- Keep quiet-day design even though the current mapper did not choose it here.
- Evaluate different times and user agreement during P1's week of real use.

Private source/checkpoint files remain outside the repository in
`/tmp/homeostat-device-review-20261009/`; they may be removed by system cleanup.
The repeatable command is documented in the backend README. This spec records
aggregate findings, not raw measurements or the user's day-by-day values.

## Ownership and inputs

Python remains the calculation reference; engine changes retain Swift parity.
P1's new Swift presentation layer will own UI wording/ranking for app and widget.
Keep the existing parity-tested mapper unchanged until native P1 begins; a new
UI summary must not rewrite measured HealthState or old stored run identity.

A proposed `DailySummary` accepts the returned state, per-domain feature and
coverage metadata, current local time/timezone, display/privacy policy, and
optional latest user entry. It returns a kind, headline, one comparison, evidence
references, domain availability, observation times, optional action and version.
This is a contract, not a claim that the type exists. Do not infer coverage or
per-domain times from the global calculation timestamp. If current payloads
lack a field, carry it explicitly from local features before presenting it.

Only one shared mapping determines app/widget meaning. Views choose layout;
settings choose emphasis. No sensor thresholds or inferred health scores live
in view code. Example values and mockup copy never set calculation thresholds.

## State and interaction rules

Privacy redaction applies first; cached freshness/day policy applies before
choosing a daily headline. Missing state never becomes a quiet/healthy state.

| State | Main glance | Supporting information | Action |
|---|---|---|---|
| No visible observations | “Waiting for Health data” | Explain that no visible records cannot distinguish no recordings from unavailable read access | Open data/access explanation |
| Learning, no ready domain | “Getting to know your usual” | Available plain values with times; learning count for each domain; no premature comparison | Open domain details; optional energy entry |
| Some domains ready | Best supported observation, or “Within your usual range” scoped to ready domains | Ready domain comparisons plus separate learning/missing labels | Open exact evidence |
| Quiet with supported typical domains | “Within your usual range” | Name only supported domains; retain update time | Optional energy entry; no unsolicited exercise prompt |
| Supported change | One precise observation and one same-domain comparison | Explain value, baseline and observation time; show relevant completed workout without calling low steps inactivity | Open evidence |
| Stale, same day | Retain result with “Updated …”; existing 90-minute dimming | Never advance a measurement's timestamp because an intent or redraw ran | Open app to refresh |
| Earlier local day | Explicit date and last known result | Remove today's interpretation and daily avatar traits per existing policy | Open app |
| User reports energy | “You reported low/okay/high energy” with time | Keep the measured observation separately; sensor data never contradicts the report | Edit or undo |
| Save failed | Clear “Not saved” status | Preserve the draft for retry; do not show acknowledgment | Retry or open app |

Calibration progress uses `min(usableDays, requiredDays)` for drawing and exposes
actual counts in details. Counts may change as observations roll out or are
corrected; explain that they are usable days within a window, not a streak.
A domain reaches comparison mode only when its baseline is actually ready.
The imported history may make a first-day user ready immediately.

Small widget: one summary and one deep link. Medium: same summary plus a labeled
energy control. Today: Companion summary, available evidence cards, energy entry
and settings. P1b supplies Trends/calendar/Journal; do not ship empty tab shells
as if those features were complete. Rings remain P3.

## Evidence navigation and accessibility

The action carries scope, local day, run identity and domain/evidence references,
using the existing explanation-link infrastructure where possible. Resolve the
referenced result first. If it is gone, label the newer/different result and
explain the fallback; never silently present current data as the old evidence.
An invalid or wrong-scope link opens a neutral safe landing screen.

Every status has text and every action a VoiceOver label. At large text sizes,
stack content and remove optional detail before reducing text. Target sizes,
reduced motion, contrast, tinted widgets and redaction follow Product.md §6.
A placeholder avatar never blocks access to the same evidence via labeled text.

## Energy entry persistence

Each entry has a stable UUID, kind `energy`, value `low|okay|high`, event time,
timezone, created/updated times, revision and optional `matchesObservation`
(`yes|notReally|unanswered`) with the observation's run reference. Editing energy
does not retrospectively change the measured state or the referenced observation.

Use a typed, versioned command with its own idempotency UUID for create, edit,
delete and undo. The app service applies commands transactionally to local GRDB;
retries of a command do not create extra entries. Preserve tombstones/revisions
so a delayed widget command cannot resurrect a later deleted or edited entry.
Undo names the command and expected revision; a newer edit wins and returns a
visible conflict instead of being overwritten.

The widget App Intent writes atomically to a scoped App Group inbox under a
cross-process lock. It never opens the app's database. Confirm durable inbox
write before “Saved”; the app imports commands on launch/refresh, deduplicates,
then acknowledges/removes only ingested commands. Keep the inbox on a failed
transaction. A widget can display its pending durable entry while awaiting
app ingestion, but must not advance health-data freshness. Reject wrong scope
or unsupported versions. Account changes clear scoped pending presentation.
Locked write failures offer the app; verify file protection on the iPhone.

Widget entry is low/okay/high; the optional observation-agreement question and
editing can open the app. No extra HealthKit write permissions are introduced.

## History and data boundaries

Trend/calendar retention must be an explicit local daily-summary contract,
including date/timezone, metric/unit, source coverage, corrections and version.
Keep deduplication and deletions reflected in aggregates. Until P1b implements
that contract, promise only supported retained history, not 90 days or a year.
The audit's 51 replayable days does not establish a retention guarantee.

No new sensor collection is needed for P1. Use existing sleep, HRV, resting
heart rate, steps and workout inputs plus optional local energy reports.
Keep other collected-data proposals in the later phases; permission is requested
when a chosen feature needs it. Calendar integration and reminders are optional.

## Remaining validation

Scenario specifications above cover quiet/new-user/missing/stale/response states.
They still need interactive layout review and native validation; written copy
is not a usability result. G1 physical background checks, G2 art/accessibility
acceptance and the one-week P1 usefulness review remain open in the tracker.
