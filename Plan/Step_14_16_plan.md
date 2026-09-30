# G1 Steps 14–16 — App Group cache, real widget, background catch-up

Status: **Implemented with review fixes 2026-09-29. Simulator walkthrough, outage drill and real-iPhone acceptance remain pending (§12–13).**

Planning update 2026-09-30: the requested independent widget fetch extends this
original cache-only design. See [Master implementation plan](Master_implementation_plan.md)
and [G1 completion architecture](G1_completion_architecture.md) for proposed
networking/cache changes and the remaining acceptance gates. Those changes are
not yet implemented.

Prepared: 2026-09-25.

Steps 9–13 are implemented and tested in the simulator (Step_9_13_plan.md §12).
The widget extension renders the shared state cache. The app and the widget
already share the App Group `group.com.susil.homeostat`. Both targets have
iOS 27 as their deployment target.

## 1. Outcome

| Step | Delivers | Done when |
|---|---|---|
| 14 | An atomic, ordered `WidgetState` cache in the App Group | The app and the widget decode the same bytes. An older state never replaces a newer one. |
| 15 | A real small and medium widget, with freshness, calibration and no-data states, that opens an explanation screen when tapped | A Home Screen widget on a real iPhone shows state derived from HealthKit. Tapping it shows the values and provenance behind that state. |
| 16 | Observer-driven updates that work in the background, timeline reloads, app-open catch-up and retry wake-ups | Delayed or missing background delivery never makes the widget wrong. At worst it is visibly stale. The G1 acceptance checklist (G1 §60–61) is run and recorded. |

G1's engineering rule decides every choice below: **the widget only renders the
result.** It never queries HealthKit, never calls the backend, never parses
numbers out of the text, and never decides meaning. It does decide *how old*
what it shows is. That is display policy, not health logic.

## 2. What the backend already gives us

- `GET /v1/state/current` returns `day`, `is_today`, `input_revision`,
  `run_id`, `health_state` and `widget_state`. The app already stores the newest
  one by `(input_revision, run_id)` in GRDB (`LocalStore.storeState`).
- The WidgetState `version` is `widget-state@0.1.0`. `primary_trait.id` is one
  of `sleep | recovery | movement | workout | calibration | typical | no_data`.
- The calibration and missing-data states are already *presentations*. For
  example, 🙂 "Learning your baseline" with "9 / 14 usable days", and ⏳
  "Waiting for new data". The widget shows them as they are and adds no logic.
- `freshness.last_updated_at` equals `effective_at`, the instant the data
  describes. It does not change when a sync finds nothing new. That is the
  honest meaning of "Updated …", so we keep it.
- The sync response's `state` block has no `day` or `health_state`. After a
  sync reports `published`, the app still makes one `GET /v1/state/current`
  (this already happens today).

## 3. Implementation decisions

1. **A shared, lightweight Swift target.** Add a `HomeostatShared` library
   target to the `HomeostatCore` package. It holds `Instant`, `LocalDay`,
   `WidgetState`, the cache envelope, `SharedWidgetStore` and the pure display
   policy (§6). It does **not** depend on GRDB. `HomeostatCore` depends on it
   and re-exports it. Only the widget extension links `HomeostatShared`. The
   compiler then enforces that the widget cannot reach the queue, the
   normalizer or the health payloads, and the widget stays small, well inside
   the extension memory limit.
2. **The app is the only writer; the widget only reads.** The file is written
   atomically (write to a temporary file, then rename). The widget never
   repairs, deletes or migrates it.
3. **The stale threshold is 1.5 hours** (90 minutes) after `last_updated_at`
   (decided 2026-09-25). A state for a
   day before the device's current local day is shown as that day's state
   ("Yesterday"), never as today's. It is a display constant, not engine
   configuration.
4. **Families:** `.systemSmall` and `.systemMedium` now. The code is built so
   that `.systemLarge` can be added later (see §5, "Room for large"), because
   widgets are the main feature (decided 2026-09-25). Lock Screen
   (accessory) families, StandBy tinting and Live Activities stay out of G1,
   because they put health text on a locked screen. Detail and secondary lines
   are marked `.privacySensitive()`, so they are hidden wherever the system
   redacts.
5. **Tapping the widget** opens `homeostat://explain`. The app shows the cached
   HealthState: drivers, calibration and versions (§7).
6. **Background uploads** run inside `beginBackgroundTask` and never use the
   foreground polling loop. A `BGAppRefreshTask` covers retries and the change
   of day.
7. **The G1 acceptance run needs lost-anchor reconciliation.** Step 16a now
   includes installation isolation, bounded scans and acknowledged-event
   finalization. The real-device lost-anchor/deletion demonstration is still required.

## 4. Step 14 — App Group cache

### File and envelope

The file is `<App Group container>/widget/widget_state.json`, created with
`FileProtectionType.completeUntilFirstUserAuthentication`. The widget renders
while the phone is locked after the first unlock. It is never readable before
the first unlock.

```json
{
  "schema": 1,
  "scope": "3f9c…",                 // same hash as the per-account store file
  "day": "2026-09-25",
  "input_revision": 42,
  "run_id": 117,
  "received_at": "2026-09-25T18:04:11Z",
  "widget_state": { …exactly as the server sent it… }
}
```

- `widget_state` is kept as the server's JSON value, re-encoded with sorted
  keys. Unknown fields survive a round trip.
- There is no `health_state` in the App Group. The widget doesn't need it, and
  it keeps the most detailed health data inside the app's own storage.
- `scope` stops the widget from showing the previous account's state after the
  backend or API key changes. Changing scope deletes the file and reloads the
  timelines.

### Write rules (`SharedWidgetStore.write`)

1. Decode and validate before writing. The version must be known, the dates
   must parse and the headline must not be empty. If validation fails, nothing
   is written, and the last valid file stays.
2. Monotonic order: write only if `(input_revision, run_id)` is at least the
   pair in the file, or if the file's scope differs or the file is missing.
   This mirrors `storeState`. A late, older response never wins.
3. Write only when the bytes change. The result says whether the change was
   **meaningful** (§8), which decides whether to reload timelines.
4. Source of truth: after every successful `storeState`, the app writes the
   cache from `storedState()`. On launch, if the file is missing or has a
   different scope, the app rewrites it from `storedState()`. This covers
   reinstalls, app updates and a cache deleted by hand.

### Read rules (`SharedWidgetStore.read`)

- The result is `.state(envelope)`, `.none` (no file), or `.unreadable`
  (corrupt, locked, or an unknown major `schema` or `widget-state` version).
- Version policy: accept `widget-state@0.1.x`, and ignore unknown fields. Any
  other version renders "Update Homeostat" instead of guessing.

### Tests (`swift test`, HomeostatSharedTests)

- A round trip is byte-identical, and the app and the widget decode the same
  value.
- An older pair is ignored. An equal pair is idempotent. A newer pair replaces
  the file. A new scope replaces the file whatever its pair.
- Invalid input leaves the previous file untouched. A partial temporary file
  never becomes visible (simulated by a write that fails mid-way).
- An unknown version or schema reads as `.unreadable`, not as a crash.
- **Cross-language fixture:** the backend exports every distinct
  `(icon, headline, detail, secondary, primary_trait)` among the 2,500 valid
  widget combinations. The export adds a `widget_states.jsonl` generator next
  to `tests/api/test_wire_fixtures.py`, using the same
  `UPDATE_WIRE_FIXTURES=1` mechanism. Swift decodes all of them. The layout
  check in §5 uses the longest ones.

## 5. Step 15 — the widget

### Timeline provider

- `placeholder` shows a fixed sample ("🙂 Typical day"), redacted by the
  system.
- `getSnapshot` (widget gallery) shows the cache if it exists, otherwise the
  sample.
- `getTimeline` reads the cache once and builds entries from the display policy
  in §6, one entry per display change:
  - now;
  - `last_updated_at + 90 min` (turns stale);
  - the next local midnight (turns into "Yesterday").

  The midnight date is computed with `Zone.start(of:)`, so DST and a skipped
  midnight work.
- The reload policy is `.after(next local midnight + 1 min)`, so the widget
  re-reads the cache at least once a day even without app activity.

### Display states

| Cache / policy result | Shows |
|---|---|
| Fresh state | icon · headline · detail · secondary · "Updated 4:12 PM" |
| Stale (> 90 min, same day) | the same content, dimmed, with "Updated 5h ago" as relative text that stays current |
| An earlier day | the same content, headed "Yesterday" (or the weekday), with "Open Homeostat to update" |
| `calibration` / `no_data` trait | the server's presentation as-is. These *are* the G1 "calibration widget" and "missing-data" states. |
| No cache (`.none`) | 🙂 "Open Homeostat to get started" |
| `.unreadable` | "Update Homeostat" (version) or "Open Homeostat" (locked or corrupt) |

- Small: the icon, a two-line headline, the detail and the freshness line.
  Secondary is shown only if it fits.
- Medium: adds the secondary line and the day label.
- Views are split into parts that any size can reuse: `HeadlineBlock`,
  `DetailLine`, `SecondaryLine`, `FreshnessLine` and `DayLabel`. Each size's
  layout is a small `switch family` that arranges them. No layout code is
  shared by copying.
- Text uses Dynamic Type-friendly styles, `lineLimit` and
  `minimumScaleFactor(0.8)`. It is never truncated in the middle of a number.
- Accessibility: the widget is one combined element. It reads "Shorter sleep,
  5 hours 58 minutes, updated 4:12 PM".
- `widgetURL(homeostat://explain)` is on every state except "get started",
  which opens the app normally.
- The widget kind stays `HomeostatWidget`, and the display name becomes
  "Homeostat". The bundle ID doesn't change, so any widget the user already
  added keeps working.

### Room for large (not built in G1)

- **Adding the size:** add `.systemLarge` to `supportedFamilies` and a
  `LargeLayout` built from the same parts. The cache, display policy, timeline
  and reload rule stay the same for every size.
- **Content needs the backend:** the WidgetState 0.1 contract has only four
  lines of text. A large widget with more content (a line per domain, or
  calibration progress) needs the **backend presentation mapper** to add those
  lines. That would be a minor contract bump to `widget-state@0.2.0` with an
  optional `items` list, keeping the rule that the widget only renders the
  result.
- **Version check:** the read version check (§4) must accept 0.1 and 0.2. Keep
  one decoder with optional fields, so small and medium keep working unchanged.
- **Until then:** a large widget would only show the same content bigger,
  which isn't worth offering.

### Layout verification

- Previews and snapshot entries are built for each display state, plus the
  longest fixture strings in small and medium at the default and the largest
  standard Dynamic Type size.
- A simulator run adds the widget to the Home Screen and takes screenshots.
  This is recorded in §12 of this plan.

## 6. Display policy (pure, in HomeostatShared, unit tested)

```swift
enum Display { case fresh, stale, earlierDay(LocalDay), empty, unreadable(Reason) }
func display(for: SharedWidgetStore.ReadResult, now: Instant, zone: Zone) -> Display
func timelineDates(for: SharedWidgetStore.ReadResult, now: Instant, zone: Zone) -> [Instant]
```

- "Earlier day" compares the envelope's `day` with the device's current local
  day (`TimeZone.current`). This is also correct after travel: a state for the
  previous local day is never shown as today's.
- Tests:
  - the boundaries at exactly 90 min and exactly midnight;
  - the fall-back 25-hour day and the Santiago skipped midnight;
  - a future `last_updated_at` (clock skew), which counts as fresh and never
    as negative age;
  - a travel day change;
  - the entry dates are strictly increasing and deduplicated.

## 7. Explanation screen (G1 demo item 12)

An `ExplanationView` in the app, reached from the widget URL and from the debug
screen, renders the stored `ReturnedState`:

- the same presentation as the widget, plus `day`, `is_today` and the time the
  data describes;
- per domain: state, confidence and severity;
- drivers: value, baseline, difference, unit, source and `observed_at`, as they
  are. No numbers are recomputed;
- calibration: usable/required days per domain and status;
- versions: `engine_version`, `feature_version`, `config_sha256` (shortened),
  `input_revision` and `run_id`, so a replay can be matched to what was shown.

A driver without a value shows "No data". The screen also shows
`primary_trait.explainable == false` as "Not enough data to explain this".

## 8. Step 16 — background, reload and catch-up

### Fix a gap in the Step 9–13 code: register observers early

`HKObserverQuery` and background delivery wake the app **without a UI scene**.
Registering in a SwiftUI `.task` is not reliable for that. Add a
`UIApplicationDelegateAdaptor`. Its `didFinishLaunching` does four things:

1. opens the model;
2. registers every observer when access has been requested;
3. registers the `BGTaskScheduler` handler;
4. rewrites the widget cache from `storedState()` if needed.

### Background path, per observer callback

1. Drain that type, or refresh the step statistics, then call the HealthKit
   completion handler. This is already done, and completion never waits for
   the network.
2. `beginBackgroundTask`, then `syncAll(maxRequests: 3)`, then **one** `refreshState()` even when the upload queue is idle, then write the cache,
   then reload if the change was meaningful, then `endBackgroundTask`. There is
   no 2/4/8/16/32 s polling in the background. If the task expires, the
   request stays open in the queue, and replaying it is idempotent.
3. Several observers firing together share one run: coalesce with the existing
   `busy`/rerun pattern so there is only one upload.

### Timeline reloads (the "meaningful change" rule)

Reload `HomeostatWidget` when any of these differ from the file before the
write:

- `presentation`;
- `primary_trait`;
- `day`;
- `freshness.last_updated_at` or the previous state is already stale.

A timestamp change requests a reload in both foreground and background: the
published timeline otherwise retains an obsolete stale deadline. Byte-identical
writes do not request reloads. WidgetKit may still throttle background requests;
we do not promise a refresh frequency the system cannot guarantee.

### Retries and the change of day

- `BGAppRefreshTask` `com.susil.homeostat.refresh`: add
  `BGTaskSchedulerPermittedIdentifiers` and the `fetch` background mode. It is
  scheduled after every sync for the earliest of:
  - the queue's `next_attempt_at`;
  - the next local midnight + 5 min, for the new day's state;
  - now + 1 h while the queue has pending events.

  The handler does a step refresh, then sync, then one state fetch, then the
  cache write. It is best effort: iOS may run it late or never.
- App-open catch-up (already done) is the guaranteed path. It also rewrites
  the cache and always reloads timelines in the foreground.
- Clock or timezone changes (`NSSystemClockDidChange`,
  `NSSystemTimeZoneDidChange`): reload timelines so the "earlier day" and stale
  entries are recomputed.

### Tests

- `swift test`:
  - the reload decision table;
  - coalescing several observer callbacks into one upload;
  - the background path makes no polling calls;
  - the scheduled earliest-begin date;
  - a scope change clears the cache.

  These use fakes for the transport, the clock, the reloader and the
  scheduler.
- Simulator:
  - `xcrun simctl` can trigger background fetch, via Debug → Simulate
    Background Fetch or `e -l objc` on `_simulateLaunchForTaskWithIdentifier`
    in the debugger;
  - check that the cache is written and the widget changes.
- Outage drill:
  1. Stop uvicorn.
  2. Add data and open the app.
  3. Check that the widget keeps its last state and goes stale after the
     threshold (the threshold can be shortened in a DEBUG-only build setting
     for this drill).
  4. Restart and sync, and check that it recovers.

## 9. Suggested files

```
ios/HomeostatCore/Package.swift                     + HomeostatShared target and product
ios/HomeostatCore/Sources/HomeostatShared/
    Instant.swift          (moved from HomeostatCore, no API change)
    WidgetState.swift      (moved from SyncContracts.swift)
    SharedWidgetStore.swift
    WidgetDisplay.swift    (§6 policy)
ios/HomeostatCore/Tests/HomeostatSharedTests/…      (+ Fixtures/widget_states.jsonl)
ios/Homeostat/Homeostat/App/AppDelegate.swift       observers, BG task, cache repair
ios/Homeostat/Homeostat/App/AppModel.swift          cache write + reload, background path
ios/Homeostat/Homeostat/Views/ExplanationView.swift
ios/Homeostat/HomeostatWidget/HomeostatWidget.swift (replaced)
ios/Homeostat/Homeostat.xcodeproj/project.pbxproj   widget links HomeostatShared; URL scheme; BG plist keys
backend/tests/api/test_wire_fixtures.py             exports distinct widget states
```

## 10. Acceptance (the G1 §60–61 run)

Record each item in §12 with its evidence: a test name, a command output or a
screenshot. Items that only a real iPhone can prove are marked 📱 and are done
by the user.

| G1 item | Evidence |
|---|---|
| Real Home Screen widget, reads the cached WidgetState, no HealthKit or backend access | 📱 screenshot, and the widget target links only `HomeostatShared` |
| Calibration and missing-data widgets | fixture previews and simulator screenshots |
| Freshness visible when stale, and it survives a backend outage | the outage drill (§8) |
| Meaningful changes reload the timeline | reload-rule tests, and 📱 a live change |
| Demo 1–16: install → access → 35-day import → state → widget → tap shows provenance → new HealthKit event → widget updates | 📱 a recorded walkthrough |
| Demo 17: replay reproduces the states | `uv run python -m app.replay runs --user dev …` against the device's data |
| Lost-anchor rebootstrap and deleted objects | Scoped implementation tested; 📱 demonstration pending |
| All earlier backend and Swift suites | `pytest -q`, `swift test` |

**Acceptance requirement:** run the scoped reconciliation and deletion walkthrough
on the real iPhone. These gates are not waived.

## 11. Order of work

1. HomeostatShared split, the cache, the display policy and their tests (Step 14).
2. The widget UI, the explanation screen and simulator screenshots (Step 15).
3. The app delegate, the background path, BGAppRefresh, the reload rule and the
   outage drill (Step 16).
4. Verify Step 16a on a real iPhone, then record the G1 acceptance evidence.

## 12. Results (2026-09-25)

**Built:**

- **Step 16a, lost-anchor reconciliation (Step 9–13 §3B).**
  - **Server:** a sync request may carry `visibility` scans: `scan_id`, `healthkit_type`, `scope_start_at` and the `members` visible from then on (migration `0003_visibility_scans`). A record of that type is **withdrawn** from calculations when all of these hold:
    - it ends after the scan's start;
    - it was first received at an earlier revision than the scan;
    - the newest scan covering it doesn't list it.

    A withdrawal is not a tombstone. A later scan that lists the record brings it back. Scans are part of the calculation context and the `input_sha256`, so replay reproduces them. Member lists are left out of stored reports, but the hash covers them.
  - **iPhone:**
    - Every query generation records which records it saw.
    - A generation's first complete drain queues its scan. The member list is read when the request is built, so records added later in the same generation are included.
    - Starting a new generation drops the old generation's unsent scan.
    - An acknowledged scan of the current generation clears `recovery_<type>`, so coverage becomes `complete` again.
    - Existing stores start a new generation once, because they recorded no membership before.
- **Step 14:** a new `HomeostatShared` library target holds `Instant`/`LocalDay`/`Zone`, `WidgetState`, `WidgetCache` + `SharedWidgetStore` (atomic, ordered and scoped per account) and `WidgetPolicy` (stale after 90 min, earlier day, timeline dates). The widget extension links only this target. Its binary contains no GRDB and no store symbols (checked with `nm`).
- **Step 15:** a real small and medium widget, built from parts a large size can reuse, with every display state from §5. Tapping it opens `ExplanationView` (`homeostat://explain`), which shows states, drivers, calibration and versions.
- **Step 16:** an `AppDelegate` registers observers and the `BGAppRefreshTask` at launch, including a background launch with no screen.
  - After a HealthKit change in the background: a short `backgroundSync` (at most 3 requests, one state fetch and the cache write, inside `beginBackgroundTask`, and coalesced).
  - Timelines reload only when the widget would look different. In the foreground they always reload.
  - Clock or timezone changes also reload the timelines.

**Differences from the plan:**

- The cache stores `WidgetState` as a typed value, not the server's raw JSON. The app and the widget ship together, so a new field arrives in both at once.
- `received_at` was dropped from the envelope. It would have changed every write and defeated the "unchanged" check.
- The widget link needs no registered URL scheme. WidgetKit delivers it to the app that contains the widget.

**Verified at the initial implementation milestone (latest totals in §13):**

- **Backend:** `pytest -q` passes all **3,662 tests**. New tests cover:
  - the withdrawal rules;
  - scan scope and type;
  - restoring a record;
  - the input hash;
  - an API round trip followed by `verify_runs`, where every run is identical;
  - a request built by Swift being accepted by the real API;
  - the distinct-widget-states fixture.
- **Swift:** `swift test` passes all **65 tests**. HomeostatShared has 13, covering cache ordering, scope, invalid and unknown formats, the display policy, DST and skipped midnights, and all 44 distinct backend widget states. HomeostatCore has 52, including 3 new reconciliation tests and the request fixture.
- **The app and widget** build for the iPhone 18 Pro simulator (iOS 27), and the app launches.

**Pending (needs the user):**

1. **Simulator walkthrough.**
   1. Settings → URL `http://localhost:8000` and the API key.
   2. Turn sending on, then Request access, then Sync.
   3. Add the widget, check its states, and tap it to see the explanation.
   4. Simulate a background fetch: Xcode → Debug → Simulate Background Fetch.
   5. Outage drill: stop uvicorn and wait 90 minutes, or change `staleAfterSeconds` locally.
2. 📱 **Real iPhone:** the G1 §60–61 walkthrough (§10), including a live HealthKit change updating the widget.
3. 📱 **Lost-anchor demo:** delete a sample in Health while the app's anchor is invalid. It is withdrawn after the next scan.

**Known limits (updated 2026-09-29):**

- Background execution and WidgetKit reload timing remain controlled by iOS.
- Scans are a single atomic payload, bounded by the server member count and
  request byte limits. Oversized scans stay withheld/incomplete; they do not
  silently finalize a truncated membership list.
- Pre-scope server records with no known device attribution remain legacy data.
  The SQLite upgrade re-delivers locally indexed provider records to establish
  this installation's ownership before scanning. Server-only legacy records
  are not assigned to an arbitrary device or withdrawn by a new installation.
- A reinstall creates a new local installation identity; it cannot withdraw
  another installation's observations. Retiring an unavailable installation
  requires an explicit future account-management operation.

## 13. Review closure — 2026-09-29

- The BG handler registers on the main queue; scene changes and initial launch
  call `setForeground`. Foreground retries resume after a busy background sender.
- `BackgroundSyncRunner` owns cancellation/coalescing. Disabling uploads,
  switching scope, and expiration cancel it. Import loops stop at cancellation
  boundaries. Stale callbacks cannot publish another account's state.
- Every authorized background pass fetches server state once, including an idle
  queue. It never enters the foreground polling loop.
- Timestamp changes reload the widget timeline, so its stale boundary matches
  the latest cache instead of an earlier timestamp.
- Scan finalization follows relevant event acknowledgements and is separate
  from event upload. The server rejects a scoped finalization carrying events.
- Migration `0004` stores per-installation observations and bounded visibility
  intervals. A shared provider record remains visible while any contributing
  installation retains it. Historical ownership is append-only and replayable.
- SQLite `v4_installation_visibility` preserves immutable requests, adds a
  stable per-store installation ID, re-delivers locally indexed records for
  attribution, and starts fresh scan generations. Acknowledged scans restore
  coverage without requiring another observer callback. Old unbounded scans
  returned to the queue after a 413 are superseded; their missing end time is
  never invented and they cannot finalize current recovery.
- The older-workout loader skips withdrawn candidates and finds the next valid
  workout. Empty visibility fields preserve the pre-upgrade replay format.

Final verification: **3,667 backend tests**, **70 Swift tests** (57 core + 13
shared), and a successful Debug simulator app/widget build. Detailed results
are recorded in `Next_steps.md`. Core coordinator
and storage tests plus app/widget compilation do not replace UIKit/HealthKit
execution on a simulator and real phone. The walkthrough and outage drill above
remain required before G1 is accepted.
