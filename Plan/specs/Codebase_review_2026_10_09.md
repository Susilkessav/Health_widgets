# Codebase review — 2026-10-09

Reviewed HEAD `2222b08` plus the current uncommitted changes, including Today/explanation styling and bounded widget snapshot reads. A concurrent update to the experience-audit tool (configurable local sample hour) was also reviewed and its tests rerun separately. This is a review, not an implementation pass. Existing source changes were preserved.

The daily loop and on-device calculation foundation are implemented. The broader activity product is not complete: the calendar, native goal rings, workout authoring and history surfaces are still future work. “Built” below does not imply physical-device acceptance.

## Findings

All five findings are P2 (normal-priority fixes). The first three affect the native product; the last two concern verification and the optional backend.

1. **The growing event log eventually disables widget self-refresh.** `LocalCalculation.swift:120` reads the entire event outbox; those rows pass directly into `LocalRun.snapshot`. There is no rolling time/event filter on the snapshot path. `EngineSnapshot.encode` rejects files over 2 MB, and `EngineInputsFile.swift:15` deletes the prior snapshot on that failure. Once the accumulated history exceeds the cap, future widget refreshes have no inputs, even when the recent data needed for calculation would fit. The new bounded reader protects allocation but does not solve retention. Build a bounded calculation snapshot that preserves relevant corrections/tombstones, and test parity and continued refresh with months of accumulated history. The app's own calculation also parses this growing log.

2. **Yesterday's energy report can remain selected after midnight or a timezone change.** `AppModel.swift:127` changes only `displayNow`; the timer and timezone notifications call that method. `todayReport` is loaded separately by `refresh()` and some publish paths. `EnergyCard` reads `todayReport` directly, and `todaySummary` passes it through without a day check. Leave Today open across midnight without a new import: the date/result state changes but yesterday's check-in and Undo can stay visible. Refresh or filter day-scoped report/undo state whenever the current local day changes. Test midnight and travel without a HealthKit callback.

3. **A failed Undo cannot be retried from the UI.** `AppModel.swift:870–875` reports “Couldn't undo. Try again.” for a database failure, but then unconditionally clears `lastEnergy`. `EnergyCard` only shows Undo when that value exists. The entry remains saved and the advertised retry disappears. Preserve the command on retryable failure; clear it only after a successful operation or a deliberately resolved conflict. Test a failing write followed by a successful retry.

4. **CI can pass without testing or building any Swift code.** `.github/workflows/ci.yml:51–63` exits successfully when the required SDK is absent and skips both native checks. This is an explicit workaround, but green CI does not establish native correctness. Use a suitable runner or a required check that reports missing validation as blocking. The local native verification in this review did run successfully; this finding is about the workflow's behavior, not a claim about the most recent remote run.

5. **A failed device registration consumes its pairing code.** `backend/app/accounts.py:103–105` marks a code used before `register` succeeds. A token conflict returns an HTTP 409 rather than raising, so the transaction commits the used code without registering the device. Reproduced against a disposable database: a fresh device ID with an already-registered token returns `409 TOKEN_ALREADY_REGISTERED`; retrying the same code with fresh credentials returns `401 INVALID_PAIRING_CODE`. Mark the code used only after registration succeeds, in the same transaction. This affects optional backend pairing; it is not an account-isolation bypass.

## Implemented versus remaining

| Area | Implemented in code | Remaining |
|---|---|---|
| Health data | Read-only sleep, HRV SDNN, resting heart rate, cumulative steps, completed workouts; source metadata and timestamps | More data types/providers are not built |
| Import and storage | GRDB migrations, anchored imports, duplicate handling, deletions, quarantine, recovery, durable outbox, coverage | Current physical recovery/long-duration acceptance evidence |
| Calculation | Pure Swift engine and Python reference, baselines, source selection, confidence, per-domain cutoff support, parity fixtures | Bounded long-term snapshot inputs; empty-step semantics decision |
| Today | Native root screen, time-of-day styling, summary, per-domain values/learning, freshness, layered explanation | Midnight report fix; device accessibility checks |
| Energy | App save/undo and optional agreement response; durable journal commands; widget inbox and app ingestion | Failed-undo retry; general history/edit/delete UI; locked-phone verification |
| Widget | Small/medium, avatar, shared summary, freshness/stale/earlier-day states, privacy handling, explanation link, medium energy buttons | W1 polish, focus configuration, large/Lock Screen/Control widgets |
| Self-refresh (M3) | HealthKit step query, engine snapshot calculation, ordered cache writes, failure fallback, 2 MB bounded reader | Latest-build force-quit acceptance, sustained runtime/memory evidence, long-history fix |
| Avatar | Procedural rendering, identity choices, health traits, time-based effects and lighting | Final art and physical VoiceOver/tint/contrast acceptance |
| Optional server | FastAPI/PostgreSQL, migrations, idempotent ingestion, durable recalculation, account/device keys, pairing, widget credentials, retrying client | Pairing failure fix; production deployment is outside current scope |
| Activity history | Data/architecture specifications and interactive design studies | Native trends, GitHub-style calendar, day detail and journal shell |
| Workouts | Import and interpretation of completed HealthKit workouts | Manual/session logging, sets, effort, resumable sessions, planning, Live Activity |
| Rings/personalization | Separate rings and Companion remain working design directions | Native rings, goal storage/versioning, routine tracking, completion rules |
| Later features | Research/specification | Food/context, reminders, calendar integrations, patterns and what-if views |

## Verification

- Swift package: 157 tests total, 153 passed, 4 skipped, zero failures. Skips: two optional avatar sheet generators and two tests requiring a supplied physical-device database.
- Current app and widget simulator build: succeeded.
- Backend full suite with PostgreSQL: 3,784 passed, zero failures, two dependency deprecation warnings (317.73 seconds).
- Experience-audit tool changed during that run: its latest targeted suite was rerun separately, 11 passed. The full-suite count reflects collection before the additional test arrived.
- Pairing failure: reproduced through the real API and PostgreSQL in an isolated database, then database removed.
- Logs: `/tmp/homeostat-audit-swift.log`, `/tmp/homeostat-audit-build.log`, `/tmp/homeostat-audit-backend.log`.
- No app installation, new physical test, or production-data mutation was performed for this review.

The review covered the native app/widget paths, shared presentation and cache, engine/input handling, import/store/sync/journal code, backend ingestion/auth/recalculation, migrations, test structure and CI. Static findings are distinguished from the reproduced backend failure. This is not proof that every runtime path or security property is correct.

## Acceptance and plan discrepancies

- The recorded M2 force-quit evidence is one successful widget step read. It does not verify the later M3 recalculation/publication behavior. If a newer physical run has been completed, its build, steps and result need to be recorded before closing the gate.
- The plan still has open physical checks: extended locked/unlocked recovery, locked force-quit, controlled background expiry/task behavior, stale display, recovery after lost anchors, and 24–48 hours of normal use. Some related partial evidence already exists; do not restart completed checks unnecessarily.
- M3 has a 5-second HealthKit timeout, while the plan targets a whole refresh within 3 seconds. No hard overall budget is enforced; device measurement is still needed.
- “No steps recorded yet” improves wording, but the importer still converts an empty hourly result to zero. Missing/denied/true-zero are not separate stored states. This is an existing acknowledged product decision, not a newly discovered regression.
- Widget evidence links from an M3 result show the app's last full calculation with an explanatory notice, not the exact widget recalculation. The plan's “exact evidence” completion claim needs that qualification.
- Step 07 and W1 contain older confirmation language alongside subsequent approval entries. Reconcile the approved scope before treating those checkboxes as implementation blockers or completion evidence.
- The app currently targets iOS 27. Supporting older versions is not implemented.
- Some latest UI and snapshot changes are uncommitted; the reviewed working tree is ahead of HEAD.

## Suggested order

1. Fix the bounded snapshot, day-boundary report and Undo retry issues; add focused regressions.
2. Correct CI's missing-SDK outcome and backend pairing rollback behavior.
3. Complete or attach evidence for the latest-build M3/P1 physical and accessibility checks.
4. Finish the chosen widget polish and final avatar review, then conduct the planned week of daily use.
5. Build activity history/calendar, then workout authoring, then optional goal rings using the reviewed scope.
