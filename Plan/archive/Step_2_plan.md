# G1 Step 2 — synthetic dataset implementation plan

Status: **Approved and implemented — 2026-09-23.**

Prepared: 2026-09-23. Implemented after the user's explicit approval.
Verification: **249 tests pass** (169 existing contract tests and 80 new synthetic
tests). The default corpus contains **161 files**, with a 40-day demo and **39
isolated scenarios**, including all 14 golden cases. No new dependencies or
contract changes were needed. Features and state calculations remain in Steps 3-4.

## 1. Outcome and scope

Produce reproducible synthetic canonical health events that future calculations,
state-engine tests, API tests and demos can consume without real health data.

Step 2 delivers a generator, dataset artifacts, scenario descriptions and tests.
Feature calculations, HealthState generation, widget mapping, database writes,
API requests and iOS integration belong to subsequent steps. Semantic expected
outcomes are authored here as future test expectations, not computed by a new
state engine inside the generator.

Use the existing canonical contracts and standard library, plus the project's
existing Pydantic/pytest/Hypothesis dependencies. Any necessary contract change
must be documented rather than silently introduced as a fixture workaround.

## 2. Two complementary datasets

### A. Continuous demo history

- One fictional person, explicitly labeled synthetic in the dataset manifest.
- Default seed: `20260923`.
- Default first local day: `2026-08-14`; duration: 40 days, ending `2026-09-22`.
- Default timezone: `America/Chicago`.
- Sleep intervals, daily HRV SDNN and resting HR, cumulative step snapshots,
  completed workouts, and selected deletion/replacement events.
- Step snapshots at 08:00, 13:00, 18:00 and the day's closing midnight.
- Controlled variation across days and named anomalies: shorter sleep, missing
  HRV, high/low HRV, elevated RHR, reduced/increased movement and workouts.
- Explicit evaluation checkpoints at selected local times. Events later than a
  checkpoint remain distinguishable; consumers must not use future information.

The generator accepts seed, first day, day count, timezone and output directory.
The main history must contain at least 40 local days. Short-history tests use the
isolated scenarios below instead of shortening the main dataset.

### B. Isolated golden and edge scenarios

Each scenario has its own history and evaluation context so changes cannot alter
another scenario's baseline. Ready-baseline scenarios use 28 prior local days,
excluding the evaluated day. Calibration scenarios explicitly contain 0, 3, 13
or 14 usable prior days.

Use hand-designed, nonzero-MAD history for ordinary golden scenarios and a
separate zero-MAD fixture. Expectations must be supported by explicit fixture
facts rather than broad labels attached to arbitrary random values.

The main history demonstrates realistic variation; isolated cases provide exact
inputs for future assertions. Golden fixture measurements stay fixed across
seeds; seed-dependent variation belongs to the continuous history.

## 3. Scenario coverage

Include all 14 golden cases from G1 section 53:

| Scenario | Expected behavior to record |
|---|---|
| Calibration | No personal-baseline classification before readiness |
| Typical day | Sleep, recovery and movement typical |
| Short sleep only | Sleep below baseline; recovery stays typical |
| Low HRV only | Recovery stays typical |
| High HRV only | Recovery stays typical |
| Multiple adverse signals | Recovery strained |
| Favorable agreement | Recovery favorable |
| Missing HRV | Sleep and RHR remain usable; recovery coverage is 2/3 |
| Insufficient recovery inputs | Insufficient data; recovery confidence zero |
| Workout ended 45 minutes ago | Just completed |
| Movement behind usual | Expected 5,200 steps at 13:00, actual 2,900 |
| Overlapping sleep sources | One selected source; no double counting |
| Awake/in-bed intervals | 6h50 asleep within 8h in bed, with 40m awake |
| Deleted and replaced sample | Deleted A excluded; replacement B retained |

Add focused cases for:

- Calibration at 0, 13 and 14 prior valid days; absent domains versus partially
  calibrated domains; a missing current reading after baseline readiness.
- Zero baseline MAD, an outlier, and a missing day in the baseline window.
- Same-source overlapping asleep intervals, in-bed-only data and a separate nap.
- An older workout and explicitly unavailable workout history.
- Step increases/decreases on re-query, equal-time conflicts, and a newer query
  resolving a conflict. The existing bucket resolver verifies these fixtures.
- Exact retries, a reimport with a new client event ID, delayed delivery,
  out-of-order arrival and a deletion delivered before its original sample.
- Spring-forward and fall-back sleep intervals and step-day boundaries.
- A travel case with explicit zones and an unambiguous evaluation context.

DST cases use fixed transition dates outside the default August/September
history. Fixtures will state whether their expected assertion is about raw data,
source resolution, features or semantic state. Step 2 checks raw data and the
existing resolver; Steps 3-4 execute the calculation/state expectations.

## 4. Artifact format and time/availability context

Write separate directories for the main history and each isolated scenario:

```text
data/synthetic/
  README.md
  manifest.json
  demo/
    events.jsonl
    context.json
    deliveries.json
  scenarios/<scenario-id>/
    events.jsonl
    context.json
    deliveries.json
    expectations.json
```

- `events.jsonl`: one validated CanonicalEvent per line, unique by event_id.
  Synthetic sample IDs are UUIDs; snapshots use the existing snapshot ID helper.
  Provider metadata uses fictional sources with the correct HealthKit types.
- `context.json`: scenario identity, dataset version, local dates/timezone,
  explicit evaluation checkpoints, and per-domain data-coverage status.
  Coverage distinguishes known-empty workout history from unavailable history;
  an absence of events alone cannot make that distinction. This is fixture
  context, not a new production canonical event.
- `deliveries.json`: ordered batches with simulated delivery times and event ID
  references. Retry entries repeat the same event ID; reimports use a new client
  ID for equivalent provider content. Repeated deliveries do not require duplicate
  lines in the canonical event file.
- `expectations.json`: authored facts and future assertions, including referenced
  records, selected sleep source, usable history counts, effective time, and the
  particular rules/configuration assumptions supporting each expectation.
- `manifest.json`: synthetic flag, generator/contract versions, generation inputs,
  scenario catalog, file hashes, unique-event counts and delivery counts. The
  manifest excludes itself from its hash list.

The filesystem order of records is deterministic and does not represent arrival
order. Consumers use deliveries and context when simulating ingestion. They must
distinguish measurement time, snapshot query time, simulated arrival time and
evaluation time. Historical-correction fixtures explicitly describe the event
set available before and after the correction.

## 5. Determinism rules

- Fixed defaults; no current clock, random UUIDs, ambient timezone or process hash.
- UUIDv5 identifiers derived from a fixed namespace and stable logical keys.
  Different observations, deletions and reimports have distinct keys; retries
  reuse their original event IDs.
- A local seeded generator for demo variation. Derive streams from stable
  domain/day keys so adding a scenario does not shift unrelated output.
- UTC timestamp serialization, with local IANA zone retained in explicit fields.
  Use integer minute/step inputs where practical and controlled decimal precision.
- Stable sorting, UTF-8, LF newlines, sorted JSON object keys and SHA-256 hashes.
- Record the Python version/timezone-data provenance used for the committed
  artifacts. Byte equality is guaranteed for the same inputs, generator version
  and supported runtime/timezone data; runtime changes require regeneration checks.
- Store the default generated corpus in Git for immediate use and review.
  Regeneration writes only known dataset files and does not remove unrelated files.

## 6. Proposed implementation files

```text
backend/app/synthetic/
  __init__.py
  __main__.py       # CLI arguments and generation entry point
  models.py         # fixture context, delivery and manifest validation
  generator.py      # stable IDs, event builders and demo history
  scenarios.py      # isolated histories, cases and authored expectations
  writer.py         # canonical serialization and manifest hashes

backend/tests/synthetic/
  test_generation.py
  test_scenarios.py
  test_artifacts.py
```

Update `backend/README.md` and the project progress plan with commands and status.
Use the existing contracts directly instead of importing fixtures from the
contract test module. No new runtime dependency is expected.

Proposed command from `backend/` after implementation:

```bash
uv run python -m app.synthetic generate \
  --seed 20260923 --start-date 2026-08-14 --days 40 \
  --timezone America/Chicago --output ../data/synthetic
```

## 7. Implementation order after approval

1. Define fixture context, deliveries, manifest and expectation formats.
2. Build stable IDs, canonical-event constructors and deterministic serialization.
3. Generate and validate the continuous 40-day history.
4. Add independent golden cases and targeted edge scenarios.
5. Add the CLI, manifest/hash writer and default generated artifacts.
6. Run regressions, document usage and update progress to Step 2 complete.

## 8. Acceptance checks

- All prior Step 1 tests continue to pass.
- Every generated event validates through CanonicalEvent and JSON round-trips.
- Independent runs produce identical file sets and bytes for identical inputs,
  including runs in fresh processes and different ambient timezones.
- A changed seed changes demo measurements while keeping them valid; isolated
  golden measurements and their authored expectations remain fixed.
- The default history covers 40 days and every required scenario is present.
- Source timestamps, provider types, units, interval ordering, sleep stages,
  and snapshot identities follow the current contracts.
- Delivery references exist; retry/reimport IDs and deletion targets have the
  intended relationships. Arrival permutations preserve the fixture event set.
- Fixture-specific assertions verify calibration history counts, asleep/awake
  structure, source overlap, deletion/replacement relationships and correction
  conflicts. These do not depend on a future calculator to create expectations.
- Manifest counts/hashes match all generated files, and regenerating the default
  corpus in a temporary directory matches the committed artifacts.
- Documentation clearly separates Step 2 fixture checks from semantic golden
  tests that will run once Steps 3-4 exist.

## Completion

All acceptance checks above are covered. The corpus is saved under
`data/synthetic/`; usage is documented in `backend/README.md` and the generated
corpus README. Project progress and the next implementation scope are recorded
in `Plan/Next_steps.md`.
