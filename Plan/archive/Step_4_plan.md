# G1 Steps 4-5 — state engine and dummy widget mapper

Status: **Approved and implemented — 2026-09-24.**

Prepared: 2026-09-23. Steps 1-3 are complete (370 passing tests; 41 scenarios,
169 corpus files). This plan covers milestone D in `Next_steps.md`, which is G1
Step 4 (state engine) plus G1 Step 5 (dummy presentation mapper). Together they
complete the synthetic run: events -> features -> HealthState -> WidgetState.
Sources: `G1_plan.md` sections 3, 15-17, 37-48, 50, 53 and 58, and
`Whole_project.md` sections 3 and 28.

## 1. Outcome and scope

Deliver:

- `compute_health_state(features, settings) -> HealthState`, pure and deterministic.
- `map_widget_state(state) -> WidgetState`, the only code that turns health
  meaning into icons and text.
- A pipeline and CLI that run a synthetic dataset checkpoint through features,
  state and widget, and a readable timeline of all demo checkpoints.
- Fixture expectations for every golden case at the state and widget layers,
  plus tests that cover every reachable state combination.

Out of scope, and where each belongs:

| Item | Belongs to |
|---|---|
| Storing states, `health_state_history`, replay CLI | Steps 6-8 |
| API endpoints (`/v1/state/...`) | Step 7 |
| Swift decoding, App Group cache, widget rendering | Steps 14-15 |
| "Updated 2h ago" staleness display | Step 15 (the widget compares `last_updated_at` with its own clock) |
| JSON Schema export for Swift | Step 14 |
| Avatar, LLM, agent, nutrition | Later phases |

## 2. Decisions to approve

These close gaps the G1 plan leaves open. Each has a recommended default.

| # | Question | Proposed rule | Why |
|---|---|---|---|
| 1 | When is a recovery input "usable"? | Its feature is `ready`, has a current classified state (not `missing` or `calibrating`) and confidence > 0. | An input with no data support (e.g. undeclared coverage) shouldn't vote. |
| 2 | Can recovery be `favorable` with only HRV and RHR? | Yes. G1's rule is "HRV above AND RHR below AND sleep != below_baseline". It's read as "no *usable* sleep input is below baseline", so sleep that isn't usable (missing, calibrating or zero confidence) can't veto. The 2/3 coverage lowers confidence. | G1 section 38, applied consistently with decision 1. |
| 3 | Can recovery be `strained` with only two inputs? | Yes, if both are adverse. | Same rule, applied to usable inputs only. |
| 4 | How is sleep `severity` defined? | `min(abs(delta_minutes) / 120, 1)`, set only for below/above. The 120-minute full scale is configurable. G1's 0.62 example is illustrative; this rule gives 0.65 for its -78 minutes. | G1 requires a severity but never defines it. |
| 5 | Workout provenance | Add `source_name` to `WorkoutFeatures` (set together with the last workout) and bump features to `features@0.2.0`. | The engine sees features only, and a driver must say which source produced it. Nothing is persisted yet, so the bump is free. |
| 6 | Movement driver source | The constant `"HealthKit statistics"`. | Step totals are HealthKit's merged statistics, not one device. |
| 7 | One configuration or two? | One `homeostat.yaml` with a new `state` section. The engine requires `features.config_sha256` to equal the settings hash and rejects a mismatch. | A stored state then has one replay identity. |
| 8 | Headline priority and wording | The rule table in section 6. Deviations that need attention come first, then a fresh workout, then positive deviations, then context. | G1's example widget puts short sleep first, with the workout as a secondary line. |
| 9 | Minimum confidence to display a claim | 0.5, a mapper constant, enforced by one eligibility helper for headlines, secondary lines and domain lists (section 6.1). | Stale or unsupported traits shouldn't be shown anywhere (G1 section 3.5). |
| 11 | "Learning your baseline" vs no data | P9 needs evidence: at least one domain with a usable history day, or a current measurement. With neither, the widget says "Waiting for new data". | Calibration shouldn't mask a device that shows nothing at all. |
| 12 | Unknown workout types | Shown as "Workout". Only types in a fixed label table get a specific label. The original identifier stays in HealthState and its driver. | Arbitrary identifiers could break the wording guarantees. |
| 10 | Relative times in widget text | None. The mapper never writes "45 min ago" or clock times. | A cached widget would show a stale "45 min ago" hours later. The widget computes relative time itself in Step 15. |

## 3. Engine interface and inputs

```python
compute_health_state(features: DailyFeatures, settings: Settings) -> HealthState
```

- **No I/O and no clock.** It reads no database, HTTP, HealthKit, LLM, widget or
  avatar code (G1 section 42).
- **Inputs are checked first.** It raises `EngineInputError` when:
  - `features.version` is unsupported;
  - `features.config_sha256` doesn't match `settings_sha256(settings)`;
  - the domains' `required_days` differ from each other or from
    `settings.baseline.minimum_valid_days`;
  - the workout state is `active`, which G1 must never produce (the contract
    keeps the value only for a future live-workout signal).
- **Contract violations surface.** Any `HealthState` validation error propagates;
  it is never caught or softened.
- **Identity fields:** `engine_version = "state-engine@0.1.0"`,
  `feature_version = features.version`, `config_sha256 = features.config_sha256`,
  `effective_at = features.effective_at`.

New settings (they change the config hash; nothing is stored yet):

```yaml
state:
  sleep_severity_full_minutes: 120   # |delta| at which severity reaches 1
```

The recovery constants stay in code, because G1 fixes them:
`total_expected_inputs = 3` and a minimum of 2 usable inputs.

## 4. Engine rules

### 4.1 Calibration summary

- `domains` holds each domain's `usable_days` from features: sleep, HRV, RHR
  and movement.
- `required_days` is the shared `required_days` from features.
- `status` and `usable_days` follow the contract rule: participating domains are
  those with ≥1 usable day; the summary is ready only if all of them are ready;
  with none participating it's calibrating with 0 days.
- The contract already rejects a summary that disagrees with its domains. For
  sleep and movement, a `calibrating` state must match that domain's own count.

### 4.2 Domain states

| HealthState field | Rule |
|---|---|
| `sleep.state`, `sleep.confidence` | Copied from features. |
| `sleep.severity` | Rule 2.4 for below/above; otherwise unset. |
| `movement.state`, `movement.confidence` | Copied from features. |
| `workout.state`, `workout.confidence` | Copied from features. G1 never produces `active`. |
| `workout.type` | Features' `type`, passed through unchanged (e.g. `traditional_strength_training`). Display labels belong to the mapper. |

HRV and RHR have no HealthState domain of their own. They appear through
recovery and drivers.

### 4.3 Recovery (G1 sections 37, 38 and 40)

1. `usable` = those of sleep, HRV and RHR that meet rule 2.1.
2. Fewer than 2 usable inputs → `insufficient_data`, confidence 0.
3. Otherwise count the adverse indicators among usable inputs: sleep
   `below_baseline`, HRV `below_usual`, RHR `above_usual`. Two or more → `strained`.
4. Otherwise, if HRV is usable and `above_usual`, RHR is usable and
   `below_usual`, and no usable sleep input is `below_baseline` → `favorable`.
   Sleep that isn't usable never vetoes, whatever its state says.
5. Otherwise → `typical`.
6. Confidence = `min(confidence of usable inputs) × len(usable) / 3`.

Strained and favorable can't both hold: favorable needs HRV and RHR to be
non-adverse, which leaves at most one adverse indicator.

Worked examples. These become explicit tests; confidences are 1 unless noted.

| Sleep | HRV | RHR | Recovery | Confidence |
|---|---|---|---|---|
| typical | below | typical | typical (isolated HRV, golden 4) | 1 |
| typical | above | typical | typical (golden 5) | 1 |
| below | below | above | strained (golden 6) | 1 |
| typical | above | below | favorable (golden 7) | 1 |
| typical | missing | typical | typical (golden 8) | 2/3 |
| typical | missing | missing | insufficient_data (golden 9) | 0 |
| missing | above | below | favorable (decision 2) | 2/3 |
| missing | below | above | strained (decision 3) | 2/3 |
| below | above | below | typical: one adverse, favorable blocked by sleep | 1 |
| typical | below (confidence 0) | typical | typical from 2 inputs (decision 1) | 2/3 |
| calibrating | above | below | favorable from HRV and RHR | 2/3 |
| below (confidence 0) | above | below | favorable: unusable sleep can't veto (regression) | 2/3 |
| below (confidence 0) | below | typical | typical: only one usable adverse input | 2/3 |

### 4.4 Drivers (provenance, G1 section 44)

Drivers are built from features only, in this fixed order, each with its
domain's feature confidence:

| id | Domain | value | baseline | difference | unit | source | observed_at | Emitted when |
|---|---|---|---|---|---|---|---|---|
| `sleep_duration` | sleep | `hours` | `baseline_hours` if ready | `delta_hours` if set | hours | `sleep.source` | `sleep_end` | the feature has hours or a ready baseline |
| `hrv_sdnn` | hrv | `value` | `baseline` if ready | value − baseline | ms | `source_name` | `observed_at` | the feature has a value or a ready baseline |
| `resting_hr` | rhr | same as HRV | | | bpm | | | same |
| `steps_so_far` | movement | `steps` | `expected_steps_now` if ready | value − baseline | steps | `"HealthKit statistics"` | `as_of` | the feature has steps or a ready expectation |
| `last_workout` | workout | `hours_since` | — | — | hours since end | `source_name` (decision 5) | `last_workout_end` | a last workout exists |

- **Calibrating domains** get a value-only driver. Raw values are explainable,
  but no baseline claim is made (G1 section 17).
- **Missing domains with a ready baseline** get a baseline-only driver with
  confidence 0. This explains what was expected.
- The contract's driver checks then hold by construction: a baseline only when
  the domain is ready, `difference = value − baseline`, and supporting drivers
  for sleep, movement, recovery and workout claims.

## 5. WidgetState fields

`map_widget_state(state: HealthState) -> WidgetState` has no settings input.
Its constants live in the mapper module, are locked by tests, and never affect
HealthState or the config hash.

- `effective_at` = `state.effective_at`.
- `freshness.last_updated_at` = `state.effective_at`, the instant the state
  describes. The widget turns it into "Updated …" itself.
- `primary_trait.id` is one of `sleep`, `recovery`, `movement`, `workout`,
  `calibration`, `typical` or `no_data`.
- `primary_trait.explainable` is true only when every domain named in the
  displayed explanation has a supporting driver:

  | Primary trait | Domains that need a driver |
  |---|---|
  | sleep | sleep: a driver with a value, plus a baseline for below/above |
  | movement | movement: value and baseline |
  | workout | workout: `observed_at` |
  | recovery | exactly the recovery inputs named in the detail. These are drivers with value, baseline and confidence > 0, which is the same test as decision 1. Two-input recovery is therefore explainable. |
  | typical | each domain listed in the detail; for recovery, its named inputs as above |
  | calibration, no_data | none; `explainable` is false because no measured claim is shown |

  Because the mapper builds those names from the same drivers, the table holds
  by construction. The tests still check it.

## 6. Presentation rules

### 6.1 Display eligibility

One helper, `displayable(domain)`, decides whether a domain's state may be
shown anywhere. It is true when that domain's confidence (sleep, recovery,
movement or workout) is ≥ 0.5. Every place that shows a domain claim uses it:

- the headline candidates P1–P8;
- the secondary line, both the workout text and the next-rule text;
- the P10 list of typical domains.

A domain below 0.5 is never named in the headline, detail or secondary line.
Recovery's input list (P2/P6 detail) names the recovery inputs defined in
section 5. The recovery claim itself must still be displayable.

### 6.2 Rule table

Rules are checked in order and the first match is the primary trait.

| Rule | Condition | Icon | Headline | Detail |
|---|---|---|---|---|
| P1 | sleep `below_baseline` | 😴 | Shorter sleep | sleep hours, e.g. `5h 58m` |
| P2 | recovery `strained` | 🪫 | Recovery signals below usual | `Based on sleep, HRV and resting HR` (usable inputs only) |
| P3 | movement `behind_usual` | 🚶 | Less active than usual | `2,900 steps` |
| P4 | workout `just_completed` | 🏋️ | Workout complete | workout label |
| P5 | sleep `above_baseline` | 🛌 | Longer sleep | sleep hours |
| P6 | recovery `favorable` | 🔋 | Recovery signals above usual | usable inputs, as P2 |
| P7 | movement `ahead_of_usual` | 🚶 | More active than usual | steps |
| P8 | workout `recent_workout` | 🏋️ | Recent workout | workout label |
| P9 | calibration `calibrating` and evidence exists: some domain in `calibration.domains` has ≥ 1 usable day, or some driver has a current value | 🙂 | Learning your baseline | `3 / 14 usable days` |
| P10 | at least one displayable domain among sleep, recovery and movement is `typical` | 🙂 | Typical day | only the displayable typical domains, in fixed order, e.g. `Sleep, recovery and movement as usual` |
| P11 | anything else, including calibration with no history and no current values | ⏳ | Waiting for new data | `Open Homeostat to sync Health data` |

**Secondary line** (only displayable domains):
1. If the primary trait isn't a workout, and the workout is displayable and
   `just_completed` or `recent_workout`: `<label> completed recently`, e.g.
   "Strength training completed recently".
2. Otherwise, the headline of the next matching rule among P1–P8 for a
   different domain. The same eligibility applies, since P1–P8 already need it.
3. Otherwise unset.

**Formatting** (deterministic and locale-independent):

| Value | Rule |
|---|---|
| Hours | Rounded to whole minutes, then `{h}h {mm}m`, e.g. `5h 58m`, `7h 05m` |
| Steps | Comma thousands separator, e.g. `2,900 steps` |
| Usable days | `{usable_days} / {required_days} usable days` |
| Domain lists | `A`, `A and B`, `A, B and C` |
| Workout labels | A fixed table: `traditional_strength_training` → "Strength training", `functional_strength_training` → "Strength training", `running` → "Run", `walking` → "Walk", `cycling` → "Ride", `yoga` → "Yoga", `swimming` → "Swim", `hiking` → "Hike". Any other type displays as "Workout", so no unvetted identifier reaches the widget. The original identifier stays in `HealthState.workout.type` and the `last_workout` driver. |

**Wording:**
- Non-judgmental, per `Whole_project.md` sections 3.7 and 28: the text states
  the signal, never judges the person, and makes no medical claims.
- A test rejects these words in any output: bad, poor, unhealthy, fail,
  warning, danger, sick, lazy, alarming, diagnos-.

Expected golden widget output, as authored fixture expectations:

| Golden | Scenario | Primary | Headline | Detail | Secondary |
|---|---|---|---|---|---|
| 1 | calibration_3 | calibration | Learning your baseline | 3 / 14 usable days | — |
| 2 | typical | typical | Typical day | Sleep, recovery and movement as usual | — |
| 3 | short_sleep | sleep | Shorter sleep | 5h 30m | — |
| 4 | low_hrv_only | typical | Typical day | Sleep, recovery and movement as usual | — |
| 5 | high_hrv_only | typical | Typical day | (as 4) | — |
| 6 | adverse_signals | sleep | Shorter sleep | 5h 30m | Recovery signals below usual |
| 7 | favorable_agreement | recovery | Recovery signals above usual | Based on sleep, HRV and resting HR | — |
| 8 | missing_hrv | typical | Typical day | Sleep, recovery and movement as usual | — |
| 9 | insufficient_recovery | typical | Typical day | Sleep and movement as usual | — |
| 10 | workout_45m | workout | Workout complete | Strength training | — |
| 11 | movement_behind | movement | Less active than usual | 2,900 steps | — |
| 12 | multi_source_sleep | typical | Typical day | Sleep, recovery and movement as usual | — |
| 13 | awake_intervals | typical | Typical day | (as 12) | — |
| 14 | deleted_replaced | typical | Typical day | (as 12) | — |

Golden 13 is typical because 410 minutes is 40 below the 450-minute median,
inside the 60-minute threshold. Golden 8 is typical at confidence 2/3 ≥ 0.5.

## 7. Fixture and contract changes

**Fixtures (Step 2 generator; regenerate and verify the manifest):**

1. Add `widget` to the `Assertion.layer` values. Step 2 tests already skip
   layers they don't own.
2. Add state assertions:
   - golden 1: `calibration.status = calibrating`, `sleep.state = calibrating`
   - golden 8: `recovery.confidence = 2/3`
   - goldens 12 and 13: `sleep.state = typical`
   - `calibration_14`: `calibration.status = ready`
3. Add widget assertions (primary trait, headline, detail, secondary) for all
   14 goldens as in section 6, and for:
   - `workout_6h` (P8), `workout_24h` (typical)
   - `calibration_0` (`0 / 14 usable days`). This keeps P9, because its
     current-day measurements are evidence.
   - `in_bed_only` (sleep missing)
4. Add three scenarios:
   - `favorable_without_sleep`: sleep missing, HRV 80, RHR 50 → favorable, 2/3
   - `strained_two_inputs`: sleep missing, HRV 20, RHR 75 → strained, 2/3
   - `no_visible_data`: no events, no history and complete coverage → calibration
     calibrating with 0 days, recovery `insufficient_data`, widget P11
     "Waiting for new data", `explainable` false

   That makes 44 scenarios and 181 corpus files.

**Contracts:**

5. `WorkoutFeatures.source_name`, set together with the other last-workout
   fields. `FEATURES_VERSION` becomes `features@0.2.0`. The Step 3 workout
   calculator fills it from the winning workout's metadata. Document the change
   in the README's versioning section.

## 8. Pipeline, CLI and demonstration

- `app/pipeline.py`: `run_checkpoint(dataset, checkpoint, settings) ->
  PipelineResult` with fields `features_report`, `health_state` and `widget_state`.
  It reuses the Step 3 synthetic adapter.
- Commands:

  ```bash
  uv run python -m app.pipeline run --dataset DIR --checkpoint ID [--config PATH] [--output PATH]
  uv run python -m app.pipeline timeline --dataset ../data/synthetic/demo
  ```

  - `run` writes stable JSON, like the Step 3 CLI.
  - `timeline` prints one line per checkpoint in checkpoint order:
    `2026-09-12 13:00  😴 Shorter sleep · 5h 30m`. It's the human-readable
    demonstration of the whole pipeline.
- Invalid dataset, checkpoint or config gives exit code 2 with `error:` and no traceback.

## 9. Files

```text
backend/app/engine.py         # compute_health_state, recovery, drivers, EngineInputError
backend/app/presentation.py   # map_widget_state, rule table, formatting
backend/app/pipeline.py       # run_checkpoint, timeline
backend/app/pipeline_cli.py   # or app/pipeline/__main__.py if pipeline becomes a package
backend/config/homeostat.yaml # + state section
backend/tests/engine/test_engine.py
backend/tests/engine/test_presentation.py
backend/tests/engine/test_pipeline.py
```

Single modules, not packages: each is expected to stay under ~200 lines.

## 10. Implementation order

1. Contract change 5 and the `state` settings. Update the Step 3 workout
   calculator and tests. All 370 tests must still pass.
2. The engine: calibration, domain copies, severity, recovery, drivers and
   input checks.
3. Fixture changes 1–4. Regenerate the corpus and update the counts.
4. The mapper: rule table, formatting and wording.
5. The pipeline, CLI and timeline.
6. Gates (section 11), then README, `Next_steps.md` and this plan's result section.

## 11. Tests and completion gate

**Engine:**
- Every `state` assertion in all 44 scenarios passes, including all 14 goldens.
- Exhaustive recovery table. Confidence eligibility is tested independently of
  classification. Each of sleep, HRV and RHR takes one of 8 variants:
  - {adverse, typical, favorable-direction} × {confidence 0, confidence > 0};
  - `missing`;
  - `calibrating`.

  That's 8³ = 512 combinations, each checked against these invariants:
  - fewer than 2 usable inputs → `insufficient_data` with confidence 0;
  - `strained` exactly when ≥ 2 usable inputs are adverse;
  - `favorable` exactly when rule 4.3.4 holds; an unusable input of any state
    never changes the result;
  - changing HRV alone, with sleep and RHR typical, never changes recovery;
  - confidence equals the formula.
- Calibration: zero-history domain excluded; partial history holds the summary
  back; the no-participation case.
- Severity: at the threshold, at the full scale, clamped beyond it, unset for
  typical and missing.
- Drivers: every section 4.4 row, calibrating value-only, missing baseline-only,
  and fixed order.
- Rejections: config-hash mismatch, unsupported feature version, mismatched
  `required_days`, and a workout state of `active`.
- Purity: same features and settings give byte-identical states; the engine
  doesn't import I/O modules (checked with an import scan).

**Mapper:**
- Every `widget` assertion passes.
- Every valid G1 state combination, built through the engine: 5 sleep × 5 HRV
  × 5 RHR × 5 movement × 4 workout states (`active` excluded) = 2,500. For each,
  the result:
  - is a valid `WidgetState`;
  - has a non-empty headline;
  - contains none of the banned words;
  - contains no relative or clock time;
  - produces identical bytes when mapped again;
  - has `explainable` matching the section 5 table.
- Eligibility, as a property test: combinations × per-domain confidences in
  {0, 0.49, 0.5, 1}. A domain below 0.5 never appears in the headline,
  secondary line or domain list, and one at 0.5 is allowed.
- Rule-order tests for each adjacent pair (P1 over P2 … P10 over P11).
- P9 evidence: calibrating with history, or with only current values → P9;
  calibrating with neither → P11.
- Formatting: `7h 05m`, rounding at 30 seconds, `1,000` and `999` steps,
  one-, two- and three-item lists, every table workout label, and an unknown
  type → "Workout" with the raw type still in state and driver.

**Pipeline:**
- All 120 demo checkpoints produce a valid features report, HealthState and
  WidgetState.
- The first 14 demo days (2026-08-14 to 08-27, before any domain reaches 14
  usable days) show "Learning your baseline". The exceptions are 19:00
  checkpoints one hour after a covered workout, which show "Workout complete",
  because P4 outranks P9.
- `run` output is byte-identical across input order, fresh processes and
  ambient timezones.
- The timeline is deterministic, with one line per checkpoint.
- The CLI rejects bad inputs.

**Regression:** all 370 existing tests still pass, updated only for the
intentional changes in section 7.

Step 4 is complete when every item above passes and the documentation records
the adopted decisions and results. That also meets the `Next_steps.md` D gate:
all 14 goldens pass, isolated HRV never moves recovery, fewer than 2 inputs
gives `insufficient_data` with confidence 0, calibration and missing-data
widgets are valid, and output is deterministic.

## 12. Result

All gates pass. The full suite has 3,496 tests (3,126 new):

| Suite | Tests |
|---|---|
| Contract | 170 |
| Synthetic | 91 |
| Feature | 116 |
| Engine and mapper | 3,119 |

- **Fixture expectations:** all 137 state and widget expectations pass across
  the 44 scenarios, including every golden case.
- **Test matrices:** the 512-case recovery matrix and all 2,500 valid widget
  combinations pass, as does the display-confidence property test.
- **Demo:** all 120 demo checkpoints run end to end.
- **Determinism:** output is byte-identical across processes and ambient timezones.
- **Corpus:** 181 files.

What the demo timeline shows:
- The first 14 days are learning, except evenings one hour after a covered workout.
- Days 29–35 show short sleep, strained and favorable recovery, and behind and
  ahead movement.
- The demo's low- and high-HRV days coincide with random RHR extremes, so they
  show agreeing signals. Isolated HRV is covered by goldens 4 and 5 and the
  recovery matrix.

## 13. Risks and follow-ups

- **Headline order and wording are product choices** (decision 8). They're
  isolated in one table so they can change without touching the engine or the
  config hash.
- **Severity will look precise** (decision 4). It exists for the future avatar's
  intensity. The widget must not show it as a number.
- **Denied HealthKit permissions look like empty data** (Step 3 decision B). So a
  real user with denied workout access sees "Typical day", not a workout. That
  is accepted by design.
- **Step 3's device checks** (its section 13) still stand before real data is used.
