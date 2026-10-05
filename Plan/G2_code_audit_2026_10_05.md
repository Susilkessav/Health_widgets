# Current code and G2 audit — 2026-10-05

G2's presentation pipeline is implemented with placeholder artwork. It is not yet a final-art or real-iPhone accepted release. This audit supersedes the earlier review for current implementation status; it does not modify the implementation or mark acceptance tasks complete.

## Scope and evidence

Reviewed the HealthKit adapter, normalization, local import/storage/calculation, Swift feature/state engine, Python reference engine, avatar contracts/mappers/rendering, identity editor, widget/cache/timeline policy, app lifecycle/explanations, optional server ingestion/recalculation/replay, provider identity foundations, tests, CI and G1/G2 plans. Findings below distinguish direct code defects from unmeasured performance and design concerns. Passing tests are evidence for covered paths, not a guarantee that every device behavior works.

Built and launched the current app on the iOS 27 iPhone 18 Pro simulator. `G2_current_code_preview.png` captures its current debug home screen: full-body placeholder avatar, daylight environment, calibration marker, baseline progress and explanation navigation. This is an app preview, not a fresh Home Screen widget acceptance check.

## What belongs where

| Layer | Main code | Responsibility / status |
|---|---|---|
| G1 input | `HealthKitSource.swift`, `Normalizer.swift`, `ImportEngine.swift` | Read-only HealthKit; sleep, HRV, resting HR, workouts and hourly steps; normalization, anchored queries, deletion/visibility handling, coverage and history repair. |
| G1 durable local data | `LocalStore.swift`, `Outbox.swift` | Transactional SQLite event ledger, anchors, visibility generations and durable upload queue. The event log also supplies local calculations. |
| G1 health logic | `Engine/Features.swift`, `Engine/StateEngine.swift`, `LocalCalculation.swift`; Python `features/*`, `engine.py` | Personal baselines, source selection, sleep episodes, point selection, movement/workout summaries, confidence and health state. Swift calculates on device; Python is the reference. |
| G2 mapping | `avatar_state.py`, `presentation.py`, Swift `mapAvatarState` | Converts an existing health state into eyes, posture, motion, workout effects, uncertainty and channel evidence. Does not redefine the G1 health engine. |
| G2 shared presentation | `AvatarState.swift`, `AvatarView.swift`, `WidgetPolicy.swift` | Validated avatar, identity, placeholder drawing, time-based lighting/decay, stale-day and privacy policy. |
| G2 app | `AvatarViews.swift`, `DebugView.swift`, `ExplanationView.swift`, `AppModel.swift` | Identity editor, breathing/blinking, Reduce Motion, real engine demo fixtures, playground, explanation and publishing. Main app remains a development/debug interface. |
| G2 widget | `HomeostatWidget.swift`, `SharedWidgetStore.swift` | Small waist-up and medium full-body layouts; App Group identity/cache; timeline entries for fading, freshness, lighting and midnight. |
| Optional server | `main.py`, `ingest.py`, `store.py`, `recalc.py`, `worker.py`, `accounts.py`, `widget_api.py`; Swift sync files | Authenticated durable uploads, receipts, revisions, recalculation and server reads. Local G2 does not require uploading to calculate. |
| Future scope | `providers/identity.py`, multi-source/workout architecture plans | Provider identity foundation exists. Additional provider adapters, workout planning/agent, sets logging, food logging and check-ins are not implemented G2 features. |

## Current G2 rules

- Confidence below 0.5 neutralizes the applicable channel; 0.5 is included.
- Shorter/longer baseline sleep drives tired/rested eyes; severity and confidence control intensity.
- Strained/favorable recovery drives low/upright posture. Recovery requires sufficient usable inputs; movement drives low/high motion.
- Sweat half-life is 20 minutes; activity glow half-life is 160 minutes. Both use render-time exponential decay and disappear below 0.05. Known workout activity controls glow; an unknown activity can retain sweat without a named glow.
- Channel evidence records the actual driver IDs. Missing measured inputs are listed in explanations; they are not drawn as inferred physical traits.
- Workout uncertainty is deliberately excluded from the daily uncertainty marker. Missing HRV alone need not create a marker when other usable recovery inputs exist.
- Identity is user-selected, device-local App Group JSON; health data does not choose skin, hair, outfit or body. Identity writes complete before the published identity changes, and failures are surfaced.
- Earlier-day widget state loses daily traits while eligible workout effects can continue fading. Privacy rendering uses a neutral avatar and generic headline.
- An active-workout mapper case exists for future compatibility, but G1 does not currently produce a live active-workout state.

## Actionable code findings

### 1. P1 — Local background refresh is gated by server uploading

`ios/Homeostat/Homeostat/App/AppModel.swift:652` requires `uploadEnabled` before submitting a BGAppRefresh request. But `handleRefreshTask` imports and recalculates locally first, with uploading already optional at line 679. With upload disabled, the local fallback refresh is never scheduled. HealthKit observer delivery and foreground catch-up still work; this finding does not mean all background delivery is broken.

**Improve:** schedule local refresh independently of upload preferences. Keep network work gated separately, and verify local-only scheduling, history repairs and midnight catch-up with upload disabled.

### 2. P2 — Persisted `isToday` does not age with the clock

`ios/HomeostatCore/Sources/HomeostatCore/LocalCalculation.swift:41` writes `isToday: true`; `AppModel.swift:720` reloads that stored value unchanged. `Views/DebugView.swift:114` uses it to decide whether to remove daily avatar traits, and line 121 labels the result “today.” After a day boundary, a retained result can still display yesterday's daily traits and label until another calculation replaces it. The widget's clock-based day policy is better here.

**Improve:** derive whether the stored day is today at display time using an explicit timezone policy. Refresh that decision at midnight and timezone changes; cover an offline/failed-import rollover.

### 3. P2 — Widget explanation links discard scope and run

`ios/Homeostat/HomeostatWidget/HomeostatWidget.swift:166` includes scope and run in the URL. `Homeostat/HomeostatApp.swift:20` ignores both and calls `AppModel.openExplanation()`, which displays the latest local result. A displayed widget can therefore lead to an explanation of a different calculation, especially after foreground catch-up.

**Improve:** validate the local scope and resolve the requested local result, or explicitly say that a newer result replaced the tapped result. Exact historical explanations require retaining local runs; backend run IDs cannot simply substitute for local run IDs.

### 4. P2 — Read operations can erase unsupported avatar payloads

`HomeostatShared/WidgetState.swift:67` intentionally decodes unsupported/invalid avatars as nil for a safe display fallback. `SharedWidgetStore.swift:80` reads through `coordinated`, which re-encodes and may rewrite the manifest at lines 110–114. Thus a reader that cannot understand a newer nested avatar can remove that payload from the shared file merely by reading it. This is a forward-compatibility issue inferred directly from the decode/write path; no mixed-version installation was exercised.

**Improve:** make ordinary reads nonmutating, or preserve unknown raw payloads during round trips. Add a regression check that an unsupported nested version renders safely without changing cache bytes.

### 5. P2 — Device replay assumes at least one event

`HomeostatCoreTests/DeviceReplayTests.swift:23` force-unwraps the latest observation delivery time. A valid initialized database with coverage but no observations can crash the acceptance helper instead of producing an empty-data comparison.

**Improve:** use each checkpoint's effective time when there is no delivery timestamp. Include an initialized, empty-event database in the replay helper's checks. This is acceptance tooling, not the production avatar renderer.

### 6. P2 — Custom settings still report the default settings hash

`Engine/EngineSettings.swift` exposes mutable settings and `LocalCalculation.swift:24` accepts them, but `Engine/StateEngine.swift:267` and `:318` serialize the static default `EngineSettings.configSHA256`. Custom thresholds can change results without changing the reported configuration identity. The current app uses standard settings, so this does not invalidate the default parity results.

**Improve:** either restrict the API to immutable standard settings or calculate and carry the actual configuration hash with the result.

### 7. P2 — Optional server request-size protection buffers before rejecting

`backend/app/main.py:152` reads the complete request body before checking its length when a valid Content-Length header is absent. An authenticated chunked/undeclared oversized request can consume excessive memory despite the stated limit.

**Improve:** count bytes while streaming and stop at the configured limit. This is server hardening rather than a blocker for local-only G2 artwork.

## Remaining plan improvements

1. Fix findings 1–3 before treating real-device freshness and explanations as accepted.
2. Separate “implementation complete” from “acceptance passed.” T6/T8 are checked despite remaining visual/performance/Home Screen evidence. T4 is still open even though the plan's built summary includes it.
3. Reconcile decision checkboxes with recorded outcomes. Most D1–D8 choices are already described but remain unchecked; final art source and final pose specification need explicit closure.
4. Label historical review comments as historical. Demo presets are now actual pipeline fixtures; missing-HRV marker behavior and glow duration now have recorded decisions.
5. Finish T0/T5: art brief, final character/layers, head/pose anchors, export sizes and asset ownership. Align final identity counts with the prototype's five skins and three outfits or document the intended reduction.
6. Complete T4 using a copied real-iPhone database, including avatar outputs and empty/missing inputs. Synthetic parity alone is not phone acceptance.
7. Review small and medium widgets on a Home Screen: dark/light, tinted, increased contrast, larger text, stale/offline, earlier-day, unknown workout and privacy states.
8. Adjust the uncertainty marker's top-right placement so it does not visually compete with the sun/moon. Check the layout across small widget crops and final artwork.
9. Check tired/rested eyes with glasses and all skin/hair choices at actual widget size. Check that low/upright posture is distinguishable without suggesting a clinical diagnosis.
10. Finish T11: VoiceOver, Reduce Motion, accessible swatches, nonjudgmental language and understandable confidence/evidence. Existing improvements need device review.
11. Add approved visual baselines. Render tests establish that images render and differ; they do not establish that layout, contrast or expressions remain visually correct.
12. Measure memory, rendering and timeline behavior with Instruments on a phone. Do not treat planned budgets as measured results.
13. Profile local calculations with realistic accumulated history. They parse the full retained log synchronously in the app's MainActor path while the avatar can animate at 30 fps. Only optimize or move work after measuring; preserve replay data when considering retention.
14. Decide the supported OS explicitly: app/widget currently target iOS 27, while the reusable package supports older systems. Verify that this matches intended devices.
15. Pin or explicitly select a CI Xcode/runner providing the required SDK. The new workflow is defined but no successful remote run was verified here.
16. Complete T12 on physical hardware: signing/App Groups, identity sharing, HealthKit change without opening the app, offline cache, 0.1-to-0.2 migration and effect fading. Keep G1 device acceptance as a prerequisite.

## Resolved since the earlier review

Current code now has per-channel evidence; bounded effect half-lives; the shorter glow decay; versioned identity with write-failure feedback; real engine demo fixtures; Reduce Motion clock updates; improved VoiceOver wording and named 44-point identity controls; explicit threshold/missing-input rules; a CI workflow; and documented renderer/replay decisions. These should not be relisted as absent work.

## Verification

- Python non-database suite: **3,596 passed**, 164 deselected; two dependency deprecation warnings.
- Swift package: **113 executed, 111 passed, two skipped, zero failures**. Skipped optional contact-sheet export and device-database replay because their environment inputs were absent.
- Current app plus widget: unsigned Debug simulator build **succeeded**; current app launched on the iOS 27 simulator.
- Compared parity fixture to HEAD across **170 checkpoints**: checkpoint identities, feature outputs and HealthState outputs are unchanged. Default configuration hash remains `a30f283082908df13b284e1dee3aac071b48f353b2c6d728dfbd836082221b1a`.
- Database suite: one passed, 163 setup errors because PostgreSQL at localhost:5433 was unreachable; Docker daemon was not running. These are environmental failures, not demonstrated database logic failures. The database suite remains unverified in this review.
- No physical-iPhone, mixed-version upgrade, Instruments or remote CI acceptance was claimed. Existing implementation changes were preserved; only this report and the refreshed preview were added.
