# Implementation record — 2026-09-30

This records the approved G1 completion work and the bounded provider foundations.
The master plan remains the release-gate definition. Device acceptance is open.

## Implemented

- A common HealthKit import cutoff across sleep, HRV, resting heart rate,
  workouts and steps; single-flight steps; page limits with durable anchors;
  seven-day history repair chunks with restart checkpoints.
- Durable import errors/deferral, background registration results, refresh
  scheduling and expiration diagnostics. Background passes report upload/GET
  failure, cap coalescing and cancel cooperatively at a 20-second deadline.
- Stable verified account scope independent of API-key rotation. The first
  settings upgrade retains the existing SQLite file/installation when the URL
  and credential still match. Subsequent rotations retain the verified mapping.
  Settings validate the account, prepare storage and save credentials before
  activating a coordinated widget configuration. A failed preparation keeps the
  active settings. Unknown legacy identity after simultaneous key/account changes
  is isolated rather than attaching an unverified old queue to a new account.
- `GET /v1/account`; idempotent widget credential provisioning and revocation;
  `GET /v1/widget/current`; owner-checked `GET /v1/state/runs/{run_id}`.
  Widget tokens are 256-bit random, hash-only on the server, installation-scoped,
  and cannot authenticate health uploads or full explanations.
- A shared manifest coordinated with `NSFileCoordinator`, atomic writes,
  scope/generation checks, publication ordering and expiring fetch leases.
  The app's upload key remains private; the read-only widget credential uses
  explicit App Group Keychain access with after-first-unlock protection.
- Widget timeline GETs with a 10-second total deadline, 256 KiB response limit,
  no credential redirects or HTTP cache, 30-minute target, failure backoff,
  Retry-After support and 401 suspension. Cached state remains usable offline.
  Debug builds explicitly permit HTTP for LAN development; release setup requires HTTPS.
- Widget links carry scope/run identity and retrieve that exact explanation.
  The app recognizes a newer shared widget result and will not silently explain
  an older run. Dates outside the device's current day are visibly dated.
- The G1 **Sync with server** toggle affects both app and widget network work.
- Pure v2 foundation rules and tests for namespaced identities, authoritative
  correction order, scoped deletes, verified mirror grouping, conservative
  stream selection, cumulative step selection, distinct SDNN/RMSSD and
  summary/stage series, and coverage gaps. These modules are deliberately not
  connected to v1 ingestion or published calculations.

## Local deployment

The local PostgreSQL service was healthy. A PostgreSQL custom-format backup
was saved at `/private/tmp/homeostat-before-0005-0930.dump` outside the repository. Migrations through `0005` were applied to the local
configured development database after the migration/API tests passed.

No API process was listening on port 8000 during the check. No physical iPhone
was connected; device discovery returned simulators only. Thus the earlier
reported phone behavior has not been reproduced or accepted as fixed on device.

## Next device run

1. Start the updated backend with the existing API key and configuration. Keep
   the worker enabled. Use the Mac's reachable LAN address for Debug testing,
   or an always-available HTTPS deployment for away-from-home testing.
2. Build/run the new app and widget on the signed iPhone. Open Settings and Save
   once to verify the account and provision the shared read-only credential.
3. Enable **Sync with server**, request Health access if needed, and Sync now.
   Allow history repair to finish across subsequent catch-up cycles. Verify
   import errors, accepted/published revisions and widget checks in diagnostics.
4. Background the app normally and verify a server publication reaches the widget
   without reopening it. A timeline request is a scheduling target, not a promise
   of an exact 30-minute refresh. A server fetch cannot read HealthKit while the
   phone prevents import; the widget may correctly show older health data.
5. Test locked-device deferral, offline/online recovery, revoked widget token,
   server restart, timezone/day transition, account/key changes and exact-run
   links. Confirm shared Keychain access in the signed extension after reboot
   and first unlock. Record normal behavior outside the debugger for 24–48 hours.

## Still gated by the plan

- Real-device G1 acceptance, actual-device replay/outage evidence and signed
  shared-Keychain validation.
- Always-on hosting choice, deployment, backups/restore drill and operation.
- Full multi-account authentication, device registration, provider connection
  storage, v2 ingestion/replay dispatch, database migrations and adapters.
  The pure foundation tests do **not** close all D01–D15 integration gates.
- Actual Android/Health Connect, direct wearable integrations, web clients and
  optional push delivery. No second source is enabled by this change.

Verification results are recorded in `Next_steps.md` after the final test run.
