# Homeostat source index

Snapshot: October 9, 2026. Companion to the [codebase guide](/Users/susil/Health_widgets/docs/CODEBASE_GUIDE.md). This inventory includes production Python/Swift files, every test source, schema migrations and project infrastructure; generated caches, dependencies and private Xcode UI state are excluded.

## Production source files

### iPhone app

| File | Responsibility |
|---|---|
| [ios/Homeostat/Homeostat/App/AppDelegate.swift](/Users/susil/Health_widgets/ios/Homeostat/Homeostat/App/AppDelegate.swift) | Background task registration and protected-data lifecycle callbacks. |
| [ios/Homeostat/Homeostat/App/AppModel.swift](/Users/susil/Health_widgets/ios/Homeostat/Homeostat/App/AppModel.swift) | Main app coordinator for storage, accounts, import, sync, calculation, UI actions and diagnostics. |
| [ios/Homeostat/Homeostat/App/EngineInputsFile.swift](/Users/susil/Health_widgets/ios/Homeostat/Homeostat/App/EngineInputsFile.swift) | Atomic App Group input-snapshot write and removal on failure/scope change. |
| [ios/Homeostat/Homeostat/App/Keychain.swift](/Users/susil/Health_widgets/ios/Homeostat/Homeostat/App/Keychain.swift) | App credential storage wrapper. |
| [ios/Homeostat/Homeostat/HealthKit/HealthKitSource.swift](/Users/susil/Health_widgets/ios/Homeostat/Homeostat/HealthKit/HealthKitSource.swift) | Read-only HealthKit adapter for anchored samples and hourly step statistics. |
| [ios/Homeostat/Homeostat/HomeostatApp.swift](/Users/susil/Health_widgets/ios/Homeostat/Homeostat/HomeostatApp.swift) | SwiftUI app entry, Today root, scene lifecycle and explanation URL handling. |
| [ios/Homeostat/Homeostat/Views/AvatarViews.swift](/Users/susil/Health_widgets/ios/Homeostat/Homeostat/Views/AvatarViews.swift) | App live-avatar animation, appearance editor and demo controls. |
| [ios/Homeostat/Homeostat/Views/DebugView.swift](/Users/susil/Health_widgets/ios/Homeostat/Homeostat/Views/DebugView.swift) | Diagnostics, manual import/upload controls and the nested Settings/device-management UI. |
| [ios/Homeostat/Homeostat/Views/ExplanationView.swift](/Users/susil/Health_widgets/ios/Homeostat/Homeostat/Views/ExplanationView.swift) | Measurement/comparison/source explanation and detailed driver display. |
| [ios/Homeostat/Homeostat/Views/TodayView.swift](/Users/susil/Health_widgets/ios/Homeostat/Homeostat/Views/TodayView.swift) | Today layout, summary and domain cards, Health connection and energy UI. |

### Widget extension

| File | Responsibility |
|---|---|
| [ios/Homeostat/HomeostatWidget/HomeostatWidget.swift](/Users/susil/Health_widgets/ios/Homeostat/HomeostatWidget/HomeostatWidget.swift) | Widget timeline provider, safe display states, small/medium layouts and energy buttons. |
| [ios/Homeostat/HomeostatWidget/HomeostatWidgetBundle.swift](/Users/susil/Health_widgets/ios/Homeostat/HomeostatWidget/HomeostatWidgetBundle.swift) | Widget extension entry point. |
| [ios/Homeostat/HomeostatWidget/LogEnergyIntent.swift](/Users/susil/Health_widgets/ios/Homeostat/HomeostatWidget/LogEnergyIntent.swift) | Widget energy action writing an App Group inbox command. |
| [ios/Homeostat/HomeostatWidget/WidgetRefresh.swift](/Users/susil/Health_widgets/ios/Homeostat/HomeostatWidget/WidgetRefresh.swift) | Deadline-bounded HealthKit step query and shared-engine widget recalculation. |

### HomeostatShared

| File | Responsibility |
|---|---|
| [ios/HomeostatCore/Sources/HomeostatShared/AvatarState.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatShared/AvatarState.swift) | Shared avatar/effect/identity contracts, validity and appearance-file storage. |
| [ios/HomeostatCore/Sources/HomeostatShared/AvatarView.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatShared/AvatarView.swift) | Procedural avatar rendering, palette, poses and visual accessibility handling. |
| [ios/HomeostatCore/Sources/HomeostatShared/CheckIn.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatShared/CheckIn.swift) | Versioned energy commands and scoped atomic file inbox. |
| [ios/HomeostatCore/Sources/HomeostatShared/DailySummary.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatShared/DailySummary.swift) | DisplayFacts, ReportedEnergy and shared native daily-summary wording/readiness. |
| [ios/HomeostatCore/Sources/HomeostatShared/ExplanationLink.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatShared/ExplanationLink.swift) | Scope/run explanation deep-link encoding, parsing and resolution. |
| [ios/HomeostatCore/Sources/HomeostatShared/Instant.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatShared/Instant.swift) | Microsecond UTC instants, local days, timezone arithmetic and wire time handling. |
| [ios/HomeostatCore/Sources/HomeostatShared/ProbeLog.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatShared/ProbeLog.swift) | Shared diagnostic probe logging and process-memory measurement. |
| [ios/HomeostatCore/Sources/HomeostatShared/SharedWidgetStore.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatShared/SharedWidgetStore.swift) | App Group manifest/cache, compatibility, atomic coordination and publication ordering. |
| [ios/HomeostatCore/Sources/HomeostatShared/WidgetClient.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatShared/WidgetClient.swift) | Optional credentialed widget HTTP refresh and bounded HTTP/credential helpers. |
| [ios/HomeostatCore/Sources/HomeostatShared/WidgetPolicy.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatShared/WidgetPolicy.swift) | Stale/current/earlier-day policy, redacted avatar and display-change timeline dates. |
| [ios/HomeostatCore/Sources/HomeostatShared/WidgetState.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatShared/WidgetState.swift) | Shared Swift widget wire contract. |

### HomeostatEngine

| File | Responsibility |
|---|---|
| [ios/HomeostatCore/Sources/HomeostatEngine/CanonicalEvent.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatEngine/CanonicalEvent.swift) | Swift canonical data models, JSON support and deterministic event serialization. |
| [ios/HomeostatCore/Sources/HomeostatEngine/EngineInput.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatEngine/EngineInput.swift) | Parsed engine observations, provenance, coverage, context and date/statistics helpers. |
| [ios/HomeostatCore/Sources/HomeostatEngine/EngineSettings.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatEngine/EngineSettings.swift) | Immutable standard policies and Python-compatible settings identity. |
| [ios/HomeostatCore/Sources/HomeostatEngine/Exports.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatEngine/Exports.swift) | Re-export lower-level modules for existing clients. |
| [ios/HomeostatCore/Sources/HomeostatEngine/Facts.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatEngine/Facts.swift) | HealthState JSON to shared DisplayFacts mapping. |
| [ios/HomeostatCore/Sources/HomeostatEngine/Features.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatEngine/Features.swift) | Pure Swift feature implementation, source selection and domain calculations. |
| [ios/HomeostatCore/Sources/HomeostatEngine/Snapshot.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatEngine/Snapshot.swift) | LocalInputs/LocalEngine and bounded versioned engine-input file format/recalculation. |
| [ios/HomeostatCore/Sources/HomeostatEngine/StateEngine.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatEngine/StateEngine.swift) | Swift HealthState construction, recovery/calibration and original widget/avatar mapper. |
| [ios/HomeostatCore/Sources/HomeostatEngine/Steps.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatEngine/Steps.swift) | Hourly step buckets to cumulative canonical snapshots. |

### HomeostatCore

| File | Responsibility |
|---|---|
| [ios/HomeostatCore/Sources/HomeostatCore/BackgroundSyncRunner.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatCore/BackgroundSyncRunner.swift) | Coalesced, bounded background upload/state-refresh orchestration. |
| [ios/HomeostatCore/Sources/HomeostatCore/Exports.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatCore/Exports.swift) | Re-export lower-level modules for existing clients. |
| [ios/HomeostatCore/Sources/HomeostatCore/ImportEngine.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatCore/ImportEngine.swift) | HealthDataSource protocol and actor coordinating anchored imports/history repair. |
| [ios/HomeostatCore/Sources/HomeostatCore/Journal.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatCore/Journal.swift) | Transactional subjective-entry commands, revision conflicts and inbox ingestion. |
| [ios/HomeostatCore/Sources/HomeostatCore/LocalCalculation.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatCore/LocalCalculation.swift) | Consistent local database inputs, on-device calculation and current-state persistence. |
| [ios/HomeostatCore/Sources/HomeostatCore/LocalStore.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatCore/LocalStore.swift) | GRDB schema/migrations, durable import commits, anchors, repair and diagnostics. |
| [ios/HomeostatCore/Sources/HomeostatCore/Normalizer.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatCore/Normalizer.swift) | Raw samples to canonical events or repairable quarantine. |
| [ios/HomeostatCore/Sources/HomeostatCore/Outbox.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatCore/Outbox.swift) | Immutable upload requests, acknowledgment handling, coverage/scan ordering and splitting. |
| [ios/HomeostatCore/Sources/HomeostatCore/SyncContracts.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatCore/SyncContracts.swift) | Upload-response and returned-state wire contracts/validation. |
| [ios/HomeostatCore/Sources/HomeostatCore/SyncEngine.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatCore/SyncEngine.swift) | Single uploader actor, HTTP outcome handling, backoff and server-state fetching. |
| [ios/HomeostatCore/Sources/HomeostatCore/UploadRetryScheduler.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatCore/UploadRetryScheduler.swift) | Foreground retry scheduling/cancellation. |

### Python backend

| File | Responsibility |
|---|---|
| [backend/app/__init__.py](/Users/susil/Health_widgets/backend/app/__init__.py) | Python package marker or package exports. |
| [backend/app/accounts.py](/Users/susil/Health_widgets/backend/app/accounts.py) | Account enrollment, device-token authentication, pairing codes and device revocation. |
| [backend/app/config.py](/Users/susil/Health_widgets/backend/app/config.py) | Validated calculation settings, defaults, loading and canonical settings hash. |
| [backend/app/contracts/__init__.py](/Users/susil/Health_widgets/backend/app/contracts/__init__.py) | Python package marker or package exports. |
| [backend/app/contracts/_types.py](/Users/susil/Health_widgets/backend/app/contracts/_types.py) | Shared strict numeric/string/time validators and canonical JSON helpers. |
| [backend/app/contracts/avatar_state.py](/Users/susil/Health_widgets/backend/app/contracts/avatar_state.py) | Versioned avatar channels, effects and evidence contract. |
| [backend/app/contracts/canonical_events.py](/Users/susil/Health_widgets/backend/app/contracts/canonical_events.py) | Strict five-shape canonical event contracts and step-bucket resolution. |
| [backend/app/contracts/features.py](/Users/susil/Health_widgets/backend/app/contracts/features.py) | Per-domain DailyFeatures contracts and consistency checks. |
| [backend/app/contracts/health_state.py](/Users/susil/Health_widgets/backend/app/contracts/health_state.py) | HealthState, calibration and driver contracts with evidence invariants. |
| [backend/app/contracts/widget_state.py](/Users/susil/Health_widgets/backend/app/contracts/widget_state.py) | Versioned widget presentation, primary-trait and freshness contract. |
| [backend/app/db.py](/Users/susil/Health_widgets/backend/app/db.py) | SQLAlchemy table definitions, database engine and per-user calculation lock. |
| [backend/app/device_check.py](/Users/susil/Health_widgets/backend/app/device_check.py) | Read an exported phone database and compare reconstructed Python/Swift results. |
| [backend/app/engine.py](/Users/susil/Health_widgets/backend/app/engine.py) | DailyFeatures to HealthState, recovery rules, calibration and drivers. |
| [backend/app/experience_audit.py](/Users/susil/Health_widgets/backend/app/experience_audit.py) | Retrospective daily-checkpoint reports from an exported phone database. |
| [backend/app/features/__init__.py](/Users/susil/Health_widgets/backend/app/features/__init__.py) | Python package marker or package exports. |
| [backend/app/features/__main__.py](/Users/susil/Health_widgets/backend/app/features/__main__.py) | Command-line entry point for this package. |
| [backend/app/features/calculate.py](/Users/susil/Health_widgets/backend/app/features/calculate.py) | Pure feature calculation orchestrator and confidence/report assembly. |
| [backend/app/features/models.py](/Users/susil/Health_widgets/backend/app/features/models.py) | Calculation context, coverage, visibility, observation and report models. |
| [backend/app/features/movement.py](/Users/susil/Health_widgets/backend/app/features/movement.py) | Time-matched historical cumulative steps and pacing classification. |
| [backend/app/features/points.py](/Users/susil/Health_widgets/backend/app/features/points.py) | HRV/resting-HR daily selection, median/MAD baselines and robust z scores. |
| [backend/app/features/selection.py](/Users/susil/Health_widgets/backend/app/features/selection.py) | Visible-event selection, deduplication, conflicts, tombstones and source groups. |
| [backend/app/features/sleep.py](/Users/susil/Health_widgets/backend/app/features/sleep.py) | Sleep interval union/subtraction, episode selection and duration baseline. |
| [backend/app/features/synthetic.py](/Users/susil/Health_widgets/backend/app/features/synthetic.py) | Load synthetic delivery/checkpoint context and calculate a checkpoint. |
| [backend/app/features/workouts.py](/Users/susil/Health_widgets/backend/app/features/workouts.py) | Completed-workout recency and overlap-resolved active-minute totals. |
| [backend/app/ingest.py](/Users/susil/Health_widgets/backend/app/ingest.py) | Sync request contracts, per-event validation, idempotency and revision allocation. |
| [backend/app/main.py](/Users/susil/Health_widgets/backend/app/main.py) | FastAPI lifecycle, app authentication, bounded sync body, state and health routes. |
| [backend/app/pipeline.py](/Users/susil/Health_widgets/backend/app/pipeline.py) | Synthetic checkpoint and timeline CLI joining features, state and presentation. |
| [backend/app/presentation.py](/Users/susil/Health_widgets/backend/app/presentation.py) | Original ranked widget wording and avatar channel/effect mapping. |
| [backend/app/providers/__init__.py](/Users/susil/Health_widgets/backend/app/providers/__init__.py) | Python package marker or package exports. |
| [backend/app/providers/identity.py](/Users/susil/Health_widgets/backend/app/providers/identity.py) | Provider-neutral namespace, version, mirror, stream and coverage helpers for future work. |
| [backend/app/recalc.py](/Users/susil/Health_widgets/backend/app/recalc.py) | Import-aware recalculation, run persistence, retry jobs and midnight finalization. |
| [backend/app/replay.py](/Users/susil/Health_widgets/backend/app/replay.py) | Verify recorded backend runs or rebuild derived daily results. |
| [backend/app/runtime.py](/Users/susil/Health_widgets/backend/app/runtime.py) | Environment configuration and injectable clock. |
| [backend/app/store.py](/Users/susil/Health_widgets/backend/app/store.py) | Backend persistence, hashes, receipts, visibility, revisions and run lookup. |
| [backend/app/synthetic/__init__.py](/Users/susil/Health_widgets/backend/app/synthetic/__init__.py) | Python package marker or package exports. |
| [backend/app/synthetic/__main__.py](/Users/susil/Health_widgets/backend/app/synthetic/__main__.py) | Command-line entry point for this package. |
| [backend/app/synthetic/generator.py](/Users/susil/Health_widgets/backend/app/synthetic/generator.py) | Deterministic fictional demo generation. |
| [backend/app/synthetic/models.py](/Users/susil/Health_widgets/backend/app/synthetic/models.py) | Synthetic generation options, delivery batches, checkpoints and dataset models. |
| [backend/app/synthetic/scenarios.py](/Users/susil/Health_widgets/backend/app/synthetic/scenarios.py) | Definitions of the 44 isolated fictional edge-case scenarios. |
| [backend/app/synthetic/writer.py](/Users/susil/Health_widgets/backend/app/synthetic/writer.py) | Managed artifact serialization, manifests and deterministic file generation. |
| [backend/app/widget_api.py](/Users/susil/Health_widgets/backend/app/widget_api.py) | Read-only widget publication endpoint and credential provisioning/revocation. |
| [backend/app/worker.py](/Users/susil/Health_widgets/backend/app/worker.py) | Background/standalone processing of durable recalculation work. |

## Test source files

The guide describes the guarantees each test suite covers. A test file existing here does not mean it was executed during documentation work.

### Backend tests

| File | Subject |
|---|---|
| [backend/tests/__init__.py](/Users/susil/Health_widgets/backend/tests/__init__.py) | Python package marker or package exports. |
| [backend/tests/api/__init__.py](/Users/susil/Health_widgets/backend/tests/api/__init__.py) | Python package marker or package exports. |
| [backend/tests/api/test_accounts.py](/Users/susil/Health_widgets/backend/tests/api/test_accounts.py) | Tests for accounts. |
| [backend/tests/api/test_api.py](/Users/susil/Health_widgets/backend/tests/api/test_api.py) | Tests for api. |
| [backend/tests/api/test_body_stream.py](/Users/susil/Health_widgets/backend/tests/api/test_body_stream.py) | Tests for body stream. |
| [backend/tests/api/test_end_to_end.py](/Users/susil/Health_widgets/backend/tests/api/test_end_to_end.py) | Tests for end to end. |
| [backend/tests/api/test_widget_api.py](/Users/susil/Health_widgets/backend/tests/api/test_widget_api.py) | Tests for widget api. |
| [backend/tests/api/test_wire_fixtures.py](/Users/susil/Health_widgets/backend/tests/api/test_wire_fixtures.py) | Tests for wire fixtures. |
| [backend/tests/conftest.py](/Users/susil/Health_widgets/backend/tests/conftest.py) | Shared fixtures and test setup for this suite. |
| [backend/tests/contracts/__init__.py](/Users/susil/Health_widgets/backend/tests/contracts/__init__.py) | Python package marker or package exports. |
| [backend/tests/contracts/test_contracts.py](/Users/susil/Health_widgets/backend/tests/contracts/test_contracts.py) | Tests for contracts. |
| [backend/tests/db/__init__.py](/Users/susil/Health_widgets/backend/tests/db/__init__.py) | Python package marker or package exports. |
| [backend/tests/db/helpers.py](/Users/susil/Health_widgets/backend/tests/db/helpers.py) | Shared database test helpers. |
| [backend/tests/db/test_conflicts.py](/Users/susil/Health_widgets/backend/tests/db/test_conflicts.py) | Tests for conflicts. |
| [backend/tests/db/test_ingest.py](/Users/susil/Health_widgets/backend/tests/db/test_ingest.py) | Tests for ingest. |
| [backend/tests/db/test_migrations.py](/Users/susil/Health_widgets/backend/tests/db/test_migrations.py) | Tests for migrations. |
| [backend/tests/db/test_recalc.py](/Users/susil/Health_widgets/backend/tests/db/test_recalc.py) | Tests for recalc. |
| [backend/tests/db/test_scoped_visibility.py](/Users/susil/Health_widgets/backend/tests/db/test_scoped_visibility.py) | Tests for scoped visibility. |
| [backend/tests/db/test_store.py](/Users/susil/Health_widgets/backend/tests/db/test_store.py) | Tests for store. |
| [backend/tests/engine/__init__.py](/Users/susil/Health_widgets/backend/tests/engine/__init__.py) | Python package marker or package exports. |
| [backend/tests/engine/conftest.py](/Users/susil/Health_widgets/backend/tests/engine/conftest.py) | Shared fixtures and test setup for this suite. |
| [backend/tests/engine/test_demo_states.py](/Users/susil/Health_widgets/backend/tests/engine/test_demo_states.py) | Tests for demo states. |
| [backend/tests/engine/test_engine.py](/Users/susil/Health_widgets/backend/tests/engine/test_engine.py) | Tests for engine. |
| [backend/tests/engine/test_parity_fixture.py](/Users/susil/Health_widgets/backend/tests/engine/test_parity_fixture.py) | Tests for parity fixture. |
| [backend/tests/engine/test_pipeline.py](/Users/susil/Health_widgets/backend/tests/engine/test_pipeline.py) | Tests for pipeline. |
| [backend/tests/engine/test_presentation.py](/Users/susil/Health_widgets/backend/tests/engine/test_presentation.py) | Tests for presentation. |
| [backend/tests/features/__init__.py](/Users/susil/Health_widgets/backend/tests/features/__init__.py) | Python package marker or package exports. |
| [backend/tests/features/conftest.py](/Users/susil/Health_widgets/backend/tests/features/conftest.py) | Shared fixtures and test setup for this suite. |
| [backend/tests/features/test_config.py](/Users/susil/Health_widgets/backend/tests/features/test_config.py) | Tests for config. |
| [backend/tests/features/test_coverage.py](/Users/susil/Health_widgets/backend/tests/features/test_coverage.py) | Tests for coverage. |
| [backend/tests/features/test_cutoffs.py](/Users/susil/Health_widgets/backend/tests/features/test_cutoffs.py) | Tests for cutoffs. |
| [backend/tests/features/test_domains.py](/Users/susil/Health_widgets/backend/tests/features/test_domains.py) | Tests for domains. |
| [backend/tests/features/test_pipeline.py](/Users/susil/Health_widgets/backend/tests/features/test_pipeline.py) | Tests for pipeline. |
| [backend/tests/features/test_selection.py](/Users/susil/Health_widgets/backend/tests/features/test_selection.py) | Tests for selection. |
| [backend/tests/providers/test_identity.py](/Users/susil/Health_widgets/backend/tests/providers/test_identity.py) | Tests for identity. |
| [backend/tests/replay/__init__.py](/Users/susil/Health_widgets/backend/tests/replay/__init__.py) | Python package marker or package exports. |
| [backend/tests/replay/test_device_check_empty.py](/Users/susil/Health_widgets/backend/tests/replay/test_device_check_empty.py) | Tests for device check empty. |
| [backend/tests/replay/test_experience_audit.py](/Users/susil/Health_widgets/backend/tests/replay/test_experience_audit.py) | Tests for experience audit. |
| [backend/tests/replay/test_replay.py](/Users/susil/Health_widgets/backend/tests/replay/test_replay.py) | Tests for replay. |
| [backend/tests/synthetic/test_artifacts.py](/Users/susil/Health_widgets/backend/tests/synthetic/test_artifacts.py) | Tests for artifacts. |
| [backend/tests/synthetic/test_generation.py](/Users/susil/Health_widgets/backend/tests/synthetic/test_generation.py) | Tests for generation. |
| [backend/tests/synthetic/test_scenarios.py](/Users/susil/Health_widgets/backend/tests/synthetic/test_scenarios.py) | Tests for scenarios. |

### Swift core tests

| File | Subject |
|---|---|
| [ios/HomeostatCore/Tests/HomeostatCoreTests/BackgroundSyncRunnerTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/BackgroundSyncRunnerTests.swift) | Background Sync Runner tests. |
| [ios/HomeostatCore/Tests/HomeostatCoreTests/CoherentImportTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/CoherentImportTests.swift) | Coherent Import tests. |
| [ios/HomeostatCore/Tests/HomeostatCoreTests/ContractTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/ContractTests.swift) | Contract tests. |
| [ios/HomeostatCore/Tests/HomeostatCoreTests/DeviceReplayTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/DeviceReplayTests.swift) | Device Replay tests. |
| [ios/HomeostatCore/Tests/HomeostatCoreTests/EngineParityTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/EngineParityTests.swift) | Engine Parity tests. |
| [ios/HomeostatCore/Tests/HomeostatCoreTests/ImportEngineTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/ImportEngineTests.swift) | Import Engine tests. |
| [ios/HomeostatCore/Tests/HomeostatCoreTests/JournalTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/JournalTests.swift) | Journal tests. |
| [ios/HomeostatCore/Tests/HomeostatCoreTests/LocalCalculationTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/LocalCalculationTests.swift) | Local Calculation tests. |
| [ios/HomeostatCore/Tests/HomeostatCoreTests/RepairRegressionTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/RepairRegressionTests.swift) | Repair Regression tests. |
| [ios/HomeostatCore/Tests/HomeostatCoreTests/StoreTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/StoreTests.swift) | Store tests. |
| [ios/HomeostatCore/Tests/HomeostatCoreTests/SyncEngineTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/SyncEngineTests.swift) | Sync Engine tests. |
| [ios/HomeostatCore/Tests/HomeostatCoreTests/TestSupport.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/TestSupport.swift) | Shared test builders, mocks and fixture access. |

### Swift shared tests

| File | Subject |
|---|---|
| [ios/HomeostatCore/Tests/HomeostatSharedTests/AvatarRenderTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatSharedTests/AvatarRenderTests.swift) | Avatar Render tests. |
| [ios/HomeostatCore/Tests/HomeostatSharedTests/AvatarSnapshotTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatSharedTests/AvatarSnapshotTests.swift) | Avatar Snapshot tests. |
| [ios/HomeostatCore/Tests/HomeostatSharedTests/BoundedHTTPTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatSharedTests/BoundedHTTPTests.swift) | Bounded HTTP tests. |
| [ios/HomeostatCore/Tests/HomeostatSharedTests/DailySummaryTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatSharedTests/DailySummaryTests.swift) | Daily Summary tests. |
| [ios/HomeostatCore/Tests/HomeostatSharedTests/G2RegressionTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatSharedTests/G2RegressionTests.swift) | G2Regression tests. |
| [ios/HomeostatCore/Tests/HomeostatSharedTests/SharedWidgetTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatSharedTests/SharedWidgetTests.swift) | Shared Widget tests. |
| [ios/HomeostatCore/Tests/HomeostatSharedTests/WidgetClientTests.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatSharedTests/WidgetClientTests.swift) | Widget Client tests. |

## Database migrations

| File | Change |
|---|---|
| [backend/migrations/versions/0001_initial.py](/Users/susil/Health_widgets/backend/migrations/versions/0001_initial.py) | Initial |
| [backend/migrations/versions/0002_partial_day_coverage.py](/Users/susil/Health_widgets/backend/migrations/versions/0002_partial_day_coverage.py) | Partial day coverage |
| [backend/migrations/versions/0003_visibility_scans.py](/Users/susil/Health_widgets/backend/migrations/versions/0003_visibility_scans.py) | Visibility scans |
| [backend/migrations/versions/0004_installation_visibility.py](/Users/susil/Health_widgets/backend/migrations/versions/0004_installation_visibility.py) | Installation visibility |
| [backend/migrations/versions/0005_widget_credentials.py](/Users/susil/Health_widgets/backend/migrations/versions/0005_widget_credentials.py) | Widget credentials |
| [backend/migrations/versions/0006_devices.py](/Users/susil/Health_widgets/backend/migrations/versions/0006_devices.py) | Devices |

The six native migrations are embedded in [LocalStore.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Sources/HomeostatCore/LocalStore.swift), not separate files.

## Build, configuration and resources

| File | Purpose |
|---|---|
| [backend/pyproject.toml](/Users/susil/Health_widgets/backend/pyproject.toml) | Python package/dependencies and pytest configuration. |
| [backend/uv.lock](/Users/susil/Health_widgets/backend/uv.lock) | Resolved Python dependencies. |
| [backend/config/homeostat.yaml](/Users/susil/Health_widgets/backend/config/homeostat.yaml) | Reference calculation policies. |
| [backend/alembic.ini](/Users/susil/Health_widgets/backend/alembic.ini) | Migration configuration. |
| [backend/migrations/env.py](/Users/susil/Health_widgets/backend/migrations/env.py) | Migration runtime connection/setup. |
| [backend/migrations/script.py.mako](/Users/susil/Health_widgets/backend/migrations/script.py.mako) | Template for new Alembic migrations. |
| [backend/Dockerfile](/Users/susil/Health_widgets/backend/Dockerfile) | Optional backend container, startup migration and API launch. |
| [docker-compose.yml](/Users/susil/Health_widgets/docker-compose.yml) | Local PostgreSQL and optional API profile. |
| [.github/workflows/ci.yml](/Users/susil/Health_widgets/.github/workflows/ci.yml) | Backend/native validation; native SDK skip caveat described in guide. |
| [.gitignore](/Users/susil/Health_widgets/.gitignore) | Generated/local files excluded from version control. |
| [ios/HomeostatCore/Package.swift](/Users/susil/Health_widgets/ios/HomeostatCore/Package.swift) | Three Swift library products, GRDB dependency and tests. |
| [ios/HomeostatCore/Package.resolved](/Users/susil/Health_widgets/ios/HomeostatCore/Package.resolved) | Swift package dependency lock. |
| [ios/Homeostat/Homeostat.xcodeproj/project.pbxproj](/Users/susil/Health_widgets/ios/Homeostat/Homeostat.xcodeproj/project.pbxproj) | Native targets, SDK/deployment settings, links and build configuration. |
| [ios/Homeostat/Homeostat.xcodeproj/xcshareddata/xcschemes/Homeostat.xcscheme](/Users/susil/Health_widgets/ios/Homeostat/Homeostat.xcodeproj/xcshareddata/xcschemes/Homeostat.xcscheme) | App build/run scheme. |
| [ios/Homeostat/Homeostat.xcodeproj/xcshareddata/xcschemes/HomeostatWidgetExtension.xcscheme](/Users/susil/Health_widgets/ios/Homeostat/Homeostat.xcodeproj/xcshareddata/xcschemes/HomeostatWidgetExtension.xcscheme) | Widget extension scheme. |
| [ios/Homeostat/Homeostat/Info.plist](/Users/susil/Health_widgets/ios/Homeostat/Homeostat/Info.plist) | App metadata/permissions/background configuration. |
| [ios/Homeostat/Homeostat/Homeostat.entitlements](/Users/susil/Health_widgets/ios/Homeostat/Homeostat/Homeostat.entitlements) | App capabilities and shared container. |
| [ios/Homeostat/HomeostatWidget/Info.plist](/Users/susil/Health_widgets/ios/Homeostat/HomeostatWidget/Info.plist) | Widget extension metadata. |
| [ios/Homeostat/HomeostatWidgetExtension.entitlements](/Users/susil/Health_widgets/ios/Homeostat/HomeostatWidgetExtension.entitlements) | Widget capabilities and shared container. |
| [ios/Homeostat/Homeostat/Demo/demo_states.json](/Users/susil/Health_widgets/ios/Homeostat/Homeostat/Demo/demo_states.json) | Generated demo states used by avatar/demo UI. |
| [ios/Homeostat/Homeostat/Assets.xcassets](/Users/susil/Health_widgets/ios/Homeostat/Homeostat/Assets.xcassets) | App icons/accent-color asset catalog. |
| [ios/Homeostat/HomeostatWidget/Assets.xcassets](/Users/susil/Health_widgets/ios/Homeostat/HomeostatWidget/Assets.xcassets) | Widget icons/colors/background asset catalog. |
| [ios/Homeostat/Homeostat.xcodeproj/project.xcworkspace/contents.xcworkspacedata](/Users/susil/Health_widgets/ios/Homeostat/Homeostat.xcodeproj/project.xcworkspace/contents.xcworkspacedata) | Xcode workspace metadata. |
| [ios/Homeostat/Homeostat.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved](/Users/susil/Health_widgets/ios/Homeostat/Homeostat.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) | Xcode workspace Swift dependency lock. |

## Fixtures

### Cross-language and native fixtures

- [ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/engine_parity.json](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/engine_parity.json)
- [ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/engine_parity_cutoffs.json](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/engine_parity_cutoffs.json)
- [ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/server_wire.json](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/server_wire.json)
- [ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/snapshot_ids.json](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/snapshot_ids.json)
- [ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/swift_events.jsonl](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/swift_events.jsonl)
- [ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/swift_member_request.json](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/swift_member_request.json)
- [ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/swift_request.json](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/swift_request.json)
- [ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/widget_states.jsonl](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatCoreTests/Fixtures/widget_states.jsonl)

Avatar rendering fixtures: [ios/HomeostatCore/Tests/HomeostatSharedTests/Fixtures/Avatar](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatSharedTests/Fixtures/Avatar). The [fixture README](/Users/susil/Health_widgets/ios/HomeostatCore/Tests/HomeostatSharedTests/Fixtures/Avatar/README.md) explains capture and comparison.

### Synthetic input corpus

Read [the dataset rules](/Users/susil/Health_widgets/data/synthetic/README.md) before consuming fixtures. [manifest.json](/Users/susil/Health_widgets/data/synthetic/manifest.json) describes provenance and managed-file hashes. The [demo](/Users/susil/Health_widgets/data/synthetic/demo) is separate from the alternative scenarios below.

Each scenario directory has `events.jsonl`, `context.json`, `deliveries.json` and `expectations.json`.

| Scenario | Directory |
|---|---|
| absent_hrv_history | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/absent_hrv_history) |
| adverse_signals | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/adverse_signals) |
| awake_intervals | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/awake_intervals) |
| calibration_0 | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/calibration_0) |
| calibration_13 | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/calibration_13) |
| calibration_14 | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/calibration_14) |
| calibration_3 | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/calibration_3) |
| delayed_arrival | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/delayed_arrival) |
| deleted_replaced | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/deleted_replaced) |
| deletion_before_sample | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/deletion_before_sample) |
| delivery_retries | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/delivery_retries) |
| dst_fall | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/dst_fall) |
| dst_spring | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/dst_spring) |
| favorable_agreement | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/favorable_agreement) |
| favorable_without_sleep | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/favorable_without_sleep) |
| high_hrv_only | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/high_hrv_only) |
| history_outlier | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/history_outlier) |
| in_bed_only | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/in_bed_only) |
| insufficient_recovery | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/insufficient_recovery) |
| low_hrv_only | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/low_hrv_only) |
| missing_history_day | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/missing_history_day) |
| missing_hrv | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/missing_hrv) |
| movement_behind | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/movement_behind) |
| multi_source_sleep | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/multi_source_sleep) |
| near_zero_mad | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/near_zero_mad) |
| no_visible_data | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/no_visible_data) |
| out_of_order | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/out_of_order) |
| partial_hrv_history | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/partial_hrv_history) |
| same_source_overlap | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/same_source_overlap) |
| separate_nap | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/separate_nap) |
| short_sleep | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/short_sleep) |
| steps_conflict | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/steps_conflict) |
| steps_conflict_resolved | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/steps_conflict_resolved) |
| steps_downward | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/steps_downward) |
| steps_irregular_history | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/steps_irregular_history) |
| steps_upward | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/steps_upward) |
| strained_two_inputs | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/strained_two_inputs) |
| travel | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/travel) |
| typical | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/typical) |
| workout_24h | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/workout_24h) |
| workout_45m | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/workout_45m) |
| workout_6h | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/workout_6h) |
| workout_unavailable | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/workout_unavailable) |
| zero_mad | [Open scenario](/Users/susil/Health_widgets/data/synthetic/scenarios/zero_mad) |

## Planning and reference documents

Status belongs in [Plan.md](/Users/susil/Health_widgets/Plan/Plan.md). The files below include both future contracts and historical reviews; read their dates/status before treating a described feature as implemented.

- [Plan/Plan.md](/Users/susil/Health_widgets/Plan/Plan.md)
- [Plan/Product.md](/Users/susil/Health_widgets/Plan/Product.md)
- [Plan/specs/Calculation_and_product_review_2026_10_06.md](/Users/susil/Health_widgets/Plan/specs/Calculation_and_product_review_2026_10_06.md)
- [Plan/specs/Codebase_review_2026_10_09.md](/Users/susil/Health_widgets/Plan/specs/Codebase_review_2026_10_09.md)
- [Plan/specs/Daily_loop_contract.md](/Users/susil/Health_widgets/Plan/specs/Daily_loop_contract.md)
- [Plan/specs/G2_art_brief.md](/Users/susil/Health_widgets/Plan/specs/G2_art_brief.md)
- [Plan/specs/G2_plan.md](/Users/susil/Health_widgets/Plan/specs/G2_plan.md)
- [Plan/specs/Multi_source_platform_architecture.md](/Users/susil/Health_widgets/Plan/specs/Multi_source_platform_architecture.md)
- [Plan/specs/On_device_plan.md](/Users/susil/Health_widgets/Plan/specs/On_device_plan.md)
- [Plan/specs/Scenario_review_2026_10_09.md](/Users/susil/Health_widgets/Plan/specs/Scenario_review_2026_10_09.md)
- [Plan/specs/System_architecture.md](/Users/susil/Health_widgets/Plan/specs/System_architecture.md)
- [Plan/specs/Whole_project.md](/Users/susil/Health_widgets/Plan/specs/Whole_project.md)
- [Plan/specs/Workout_activity_agent_architecture.md](/Users/susil/Health_widgets/Plan/specs/Workout_activity_agent_architecture.md)

The [archive directory](/Users/susil/Health_widgets/Plan/archive) contains older step-by-step plans, trackers and preview images. Those are historical records, not the current completion checklist.

Inventory check: **87 production Python/Swift files**, **61 test/support Python/Swift files**, **6 backend migrations**, **44 synthetic scenario directories**. Counts include package markers and module re-export files; they are not test-case counts.
