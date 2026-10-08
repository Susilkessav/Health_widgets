# G1 Step 3 — configuration and feature calculations

Status: **Approved with revisions and implemented — 2026-09-23.**

Prepared: 2026-09-23 and revised after review (decisions A-D and changes 1-8
below). Steps 1-3 are complete: **370 tests pass** (169 contract, 88 synthetic,
113 feature). This plan builds on `G1_plan.md` sections 10-15, 29-41, 49-52
and the saved synthetic corpus (41 scenarios, 169 files).

## 0. Review decisions adopted

| # | Decision | Adopted rule |
|---|---|---|
| A | Movement history across zones | Compare by local wall time in each snapshot's own zone; a trip does not reset movement history. The chosen zone is recorded in evidence. |
| B | Production coverage | "Complete" means the query for that window finished after authorization was requested. HealthKit hides denial, so denied access looks like complete-and-empty; this is accepted and documented, not inferred away. |
| C | Daily HRV/RHR reading | One fixed reading per local day: the latest inside that day's primary sleep episode, else the first after it ends, else (no episode) the first of the day. |
| D | Confidence freshness | Once-daily values stay fully fresh through the report day (full 24 h, zero at 48 h); movement stays full for 1 h and decays to zero at 3 h. |

Plan changes from review: (1) a sleep zone different from the report zone is
a diagnostic, not an error; (2) Apple Watch sources share one family group;
(3) movement history requires regular hourly buckets from the adapter, with an
irregular-history fixture; (4) device verification items (section 13);
(5) the hash covers validated settings; (6) early demo days report workout
`missing`; (7) fewer modules; (8) stale counts and wording corrected.

## 1. Outcome and scope

Turn canonical events into validated, reproducible `DailyFeatures` containing
sleep, HRV, resting heart rate, movement and completed-workout context. Load all
calculation settings from validated configuration and retain enough evidence to
explain each selected value, baseline, missing result and confidence value.

Deliver:

- A validated `homeostat.yaml`, resolved configuration and canonical SHA-256 hash.
- A pure calculation entry point with explicit effective time, knowledge time,
  report day/timezone and query coverage.
- Event identity, tombstone, source selection and snapshot-resolution helpers.
- Sleep derivation, per-domain history/readiness, median/MAD calculations,
  HRV/RHR comparisons, step pacing and workout recency/totals.
- A deterministic calculation report containing `DailyFeatures`, resolved
  settings, input identity, diagnostics and derivation evidence.
- A local CLI to calculate a selected synthetic dataset/checkpoint and tests
  executing its applicable feature expectations.

Per-domain classifications already required by `DailyFeatures` are included.
Recovery interpretation, `HealthState`, widget mapping, database persistence,
API endpoints and iOS behavior remain in their existing later steps.

Use the installed Pydantic, PyYAML, pytest and Hypothesis dependencies plus the
standard library. No additional service, database or package is needed.

## 2. Configuration and replay identity

Create `backend/config/homeostat.yaml` and immutable validated settings models.
Resolve omitted settings to documented defaults before hashing. Reject unknown
keys, duplicate YAML keys, invalid types, non-finite values, invalid zones,
reversed thresholds and impossible history/readiness combinations. Use a safe
YAML loader; reject unsupported schema versions and source rules with ambiguous
matching precedence.

Proposed defaults requiring approval with this plan:

| Area | Default policy |
|---|---|
| History | Previous 28 calendar days, excluding report day |
| Readiness | At least 14 valid daily values, independently for each domain |
| Sleep thresholds | Below at delta <= -60 minutes; above at delta >= +60 minutes |
| HRV/RHR thresholds | Below at z < -1; above at z > +1; endpoints typical |
| Robust scale | `max(1.4826 * MAD, scale_floor)` |
| Scale floors | HRV: 1 ms; RHR: 1 bpm |
| Movement thresholds | Behind at ratio < 0.70; ahead at ratio > 1.30; endpoints typical |
| Movement comparison | Same local wall time in any zone (decision A); prior read at most 60 minutes earlier |
| Sleep overnight window | Previous local 18:00 through report-day 12:00 |
| Sleep episode gap | Join sleep/awake stage segments separated by at most 90 minutes |
| Workout recency | Just completed through 2 hours; recent through 12 hours |
| Confidence freshness | Sleep/HRV/RHR: full to 24 h, zero at 48 h; movement: full to 1 h, zero at 3 h (decision D) |

These are initial product policies, not clinical thresholds. They must be
named configuration values or versioned policy identifiers rather than hidden
constants inside calculations. The robust-scale floor is in the metric's units
and applies to the denominator, not to the stored MAD.

Hash the validated, fully resolved settings model, never the raw YAML (so YAML
`1` and `1.0` hash identically), using the existing documented rule: sorted
JSON keys, compact separators, UTF-8 and SHA-256, with no trailing newline in
the hashed bytes. Keep source-priority list order because it affects behavior.
Formatting, comments and YAML key order must not affect the hash. Explicit
defaults and omitted defaults must resolve to identical hashes.

The calculation report stores the resolved configuration beside its hash.
Record calculation version, source-policy version, coverage, effective/knowledge
times and a hash of the canonical visible input set. Operational execution time
is not part of deterministic output. Database storage of these reports comes later.

## 3. Calculation interface and contract boundaries

Proposed interface:

```python
calculate_features(observations, context, config) -> CalculationReport
```

- `observations`: canonical events plus their delivery/availability times.
- `context`: explicit report day/timezone, `effective_at`, `known_at`, and
  domain coverage over dated, zoned query windows.
- `config`: already validated, fully resolved calculation settings.
- `CalculationReport`: existing `DailyFeatures` plus configuration and evidence.

No current clock, filesystem lookup, network access or database read occurs
inside the calculator. File loading and serialization belong to the CLI adapter.
Normalize timestamps to UTC for ordering and elapsed durations.

`DailyFeatures` lacks knowledge time, movement timezone, contributing interval
IDs and confidence components. Keep those in a new internal report/evidence
model; preserve the existing feature payload and its validators. The report
records each domain's actual day/zone, selected source group, sample IDs,
baseline days, exclusions and confidence components. Step 4 still consumes
`DailyFeatures` for its state decisions.

The caller supplies the report day/zone even when sleep is absent. A selected
sleep episode must wake on the report day in its own zone (the contract rule).
A zone different from the report zone is a diagnostic, not an error: a sample
without timezone metadata takes the device zone at ingestion, so a night
recorded in Chicago and synced in Los Angeles must still calculate. The
synthetic travel fixture uses Chicago for sleep; movement uses Los Angeles.

Keep feature schema `features@0.1.0` for this first implementation if its shape
and documented field meanings remain intact. Version the new calculation report
and policies separately. If implementation uncovers a required incompatible
contract change, document that change and its migration before making it.

## 4. Input visibility, corrections and source identity

Process in this order:

1. Validate context and coverage. Require `known_at >= effective_at` for the
   supported original-view/corrected-history modes.
2. Keep deliveries available by `known_at`; collapse exact retries by client ID.
3. Compare provider records by `(source, source_record_id, event_type)`, excluding
   client ID from equivalent-content comparison. Normalize UTC timestamps and
   provider metadata ordering before comparison. A reimport must not add weight.
4. Reject a reused client ID with contradictory payloads. Quarantine conflicting
   provider observations with explicit diagnostics; invalidate affected domain/day
   selection so a conflict cannot silently reveal an older or different value.
5. Apply visible tombstones by provider identity, including when the original
   arrives later. A replacement has a distinct provider ID and remains eligible.
6. Select measurements completed by `effective_at`. Point samples must have
   both observed time and original sample end at or before that instant.
7. Resolve step reads per bucket with the existing `resolve_snapshot_bucket`.
   Corrections must be queried and delivered by `known_at`; `as_of` must remain
   at or before the relevant effective cutoff.

A deletion learned after the original effective time applies during a corrected
recalculation when it is visible by `known_at`. Do not incorrectly require its
deletion-observed timestamp to precede `effective_at`. This preserves the
Step 2 delayed-delivery and deletion-before-sample fixtures.

Source grouping is explicit and metric-specific. Configured groups match by
bundle ID or bundle prefix plus optional product-type prefix, first match wins.
Apple Watch samples carry per-device bundle IDs (`com.apple.health.<UUID>`)
and model-specific product types, so the default `apple_watch` family group
keeps baselines across watch replacements (same SDNN method); the exact device
stays in evidence. Unmatched sources form groups by bundle ID and product type
(or an explicit unknown-device value). Source revisions never split groups.
Never implicitly mix HRV methodologies or merge devices by display name.

Configure source priority using metadata selectors. Include the existing
synthetic watch, phone and sleep-app selectors for the saved corpus. Unknown
groups follow configured groups and have stable lexical tie ordering. Actual
HealthKit selectors will be verified with real-device metadata during integration.

Prefer an eligible current source group, then use only compatible history for
that domain. If current data is absent, choose the highest-priority historical
group with usable records in the window, preserving a ready baseline if present.
A newly selected source without sufficient compatible history is calibrating.

## 5. Sleep calculation

1. Group eligible records by source/device and original timezone.
2. Build episodes from asleep and awake stages using the configured gap.
   In-bed records describe episodes but cannot create asleep time or bridge
   separate sleep episodes.
3. Union all asleep-stage intervals to remove overlaps. Exclude in-bed and awake
   categories from the asleep union. If selected-source awake intervals overlap
   asleep records, subtract that overlap and record a contradiction diagnostic;
   contradictory time must not be counted as sleep.
4. Associate overlapping in-bed records and preserve their union duration.
   Assign them to one episode by greatest overlap, then stable episode ordering,
   so a long in-bed record cannot be counted twice across naps and primary sleep.
5. For each source, consider completed episodes whose wake day is the requested
   day and which overlap the overnight window. Choose greatest asleep duration;
   ties use latest end, then stable source/record identity.
6. Choose the authoritative source using configured priority among those with
   positive actual sleep. In-bed-only sources cannot override real sleep.
7. Preserve other episodes as naps in report evidence. Exclude their durations
   from the primary-sleep baseline and `sleep.hours`.

`sleep_start`/`sleep_end` bound the first/last retained asleep time;
`span_hours` is their UTC elapsed span, including internal awake gaps.
`hours` counts the resulting asleep union. `in_bed_hours` is the associated
in-bed union; `awake_minutes` counts the awake union inside the episode span.
An absent category is `None`, not invented zero. Sleep with no positive asleep
duration has no current episode. Date assignment uses the episode's original zone.

Use all required intervals across midnight; never select a night solely by
each stage's end-date. Exercise spring/fall DST and reversed wall-clock fold
intervals. If a configured local overnight boundary falls in a DST gap, skip
boundaries use zoneinfo's fold=0 mapping: a nonexistent boundary maps to the
transition instant and an ambiguous one to its first occurrence.

## 6. Baselines and HRV/RHR

- Use one valid value per domain per historical local day in `[D-28, D)`.
  Missing/conflicting days are excluded; do not expand the window or fill zeros.
- Sleep history uses source-compatible selected primary episodes.
- HRV/RHR use one fixed reading per local day in the selected group
  (decision C): the latest inside that day's primary sleep episode, else the
  first after it ends on the same day, else the first of the day. The value
  therefore does not drift between morning and evening checks, and history
  uses the same rule. Equal times use stable provider-ID ordering.
- A single selected reading preserves the existing single-record point
  provenance contract; it does not invent a source-record ID for an average.
- Compute ordinary median and raw median absolute deviation. Do not trim the
  authored outlier. Report baseline and MAD only once the domain is ready.
- Compute robust z using the configured scale floor. Cover exactly zero and
  near-zero MAD, both signs, and finite output.
- Preserve the current raw value while calibrating; leave comparison/baseline
  fields unset. A ready domain with no current measurement is `missing` and
  retains its baseline. Never carry yesterday's HRV/RHR into today's reading.

Movement positions are local wall-clock minutes within each snapshot's own
day (the closing boundary is 1440), so no local cutoff instants are built.

## 7. Movement pacing and travel

Select the latest eligible current snapshot bucket. For travel, select the zone
of the greatest eligible `as_of`; equal instants prefer the explicit report
zone, then lexical zone name. Record the chosen zone/day in evidence. Do not sum
counts from different zones. A previous day's closing-boundary snapshot is
history, not a current-day reading of zero. Explicit preceding-day evaluations
at their closing boundary retain that preceding day.

Resolve the chosen bucket using its latest visible query. If that query has
contradictory totals, expose a movement conflict and no current steps; do not
fall back to an older bucket. Keep a valid historical baseline when available.

Compare history at the selected current snapshot's local time, so a delayed
13:00 read is compared against 13:00 history even if evaluation happens at 14:00.
When no current snapshot exists, use the requested evaluation time/zone to derive
a baseline. A selected conflicted bucket still supplies its time/zone for that
baseline. Historical buckets may be in any zone (decision A); their local wall
time must be at or before the target and no more than 60 minutes earlier.
Resolve corrections before using a bucket; a conflicting latest eligible bucket
invalidates that day.

**Adapter requirement (Steps 10-11):** historical movement must come from
regular hourly cumulative buckets backfilled with `HKStatisticsCollectionQuery`
(G1 section 22). On-demand reads at irregular times leave most days without a
comparable bucket; the `steps_irregular_history` fixture shows 8 usable days
out of 28 in that case.

Use the median of comparable historical totals, with 14-day readiness. No
interpolation, weekday grouping or final-day-total scaling in this version.
Do not assume cumulative snapshots are monotonic after correction. If expected
steps are zero, leave ratio unset and report typical when current steps exist,
matching the existing contract. Distinguish absent steps from a real zero.

## 8. Completed workouts and coverage

Only eligible completed workouts contribute. Select the most recent accepted
workout and calculate its UTC age. Use the exact inclusive 2-hour/12-hour
boundaries. G1 never emits `active`.

Calculate totals over report-day midnight through evaluation, and over the
current plus previous six local calendar days through evaluation. For a workout
crossing a boundary, allocate its recorded active duration proportionally to
UTC wall-time overlap; this is an explicit approximation because pause locations
are unavailable. Cap the input active duration at wall span only within the
existing one-minute contract tolerance and record that normalization.

Avoid duplicate workout time: collapse provider duplicates first; partition
overlapping workouts into disjoint time segments and use the highest-priority
source in each segment, then latest end and stable provider ID for ties. Apply
each winning workout's active-duration fraction to its segment. The last-workout
record must contribute a positive accepted segment. Preserve exclusions in evidence.

Coverage must explicitly establish query completeness for both total windows
and the recent-workout window. If it cannot, emit `missing` with unset totals
and zero confidence, as required by the current all-or-none workout contract.
With complete coverage and no records, emit `none_recent` and real zero totals.
Retain an older last workout when known; do not invent one from incomplete history.
The first six demo days therefore report `missing`: their 7-day window starts
before the corpus's declared coverage.

Introduce a production-independent coverage model in calculation context. The
synthetic adapter translates declared coverage windows; it never infers coverage
from an empty event list. Extend fixture metadata only where necessary to declare
zoned coverage for travel. A domain/window without a declaration is unknown.

## 9. Deterministic confidence

Proposed initial formula for sleep/HRV/RHR/movement:

```text
maturity = min(usable_days / required_days, 1)
freshness = 1 until full_hours, then linear to 0 at zero_hours (decision D)
coverage = 1 if the current domain query window is explicitly complete, else 0
source_quality = configured group weight, default 1
confidence = maturity * freshness * coverage * source_quality
```

Age uses the current primary sleep end, point observed time or movement `as_of`.
Missing or unresolved current values have confidence zero. Because current
sleep/HRV/RHR values always belong to the report day, they stay fully fresh
through that day, so normal evening checks don't show low confidence. Reaching
zero freshness never deletes an otherwise valid same-day measurement. Source weights are configurable values in `[0,1]`;
default equal weights avoid unsupported assumptions about measurement quality.

Workout confidence is 1 for complete required query coverage and a resolved
result, otherwise 0. It does not decay simply because a known workout is old:
`none_recent` can be a fully supported observation.

Store each factor and its evidence. These scores express deterministic data
support, not probability of health or clinical validity. Composite recovery
confidence (`min usable confidence * usable_count / 3`) belongs to Step 4.

## 10. Files and implementation sequence

Implemented with fewer modules than first proposed (change 7):

```text
backend/config/homeostat.yaml
backend/app/config.py         # settings models, safe YAML loader, hash
backend/app/features/
  __init__.py, __main__.py    # package, CLI
  models.py                   # context, coverage, observations, report
  selection.py                # visibility, identity, conflicts, tombstones, source groups
  sleep.py, points.py, movement.py, workouts.py
  calculate.py                # confidence and DailyFeatures assembly
  synthetic.py                # fixture adapter; calculator does not import it
backend/tests/features/
  test_config.py, test_selection.py, test_domains.py, test_pipeline.py
```

Implement in this order:

1. Configuration validation/hash, context, coverage and report models.
2. Visibility, corrections, tombstones and source grouping.
3. Time helpers, sleep episodes and source selection.
4. History/readiness, HRV and RHR.
5. Step pacing, travel and snapshot conflicts.
6. Workout totals/coverage and confidence factors.
7. Assemble `DailyFeatures`, integrate fixture expectations, expose CLI and
   document usage/progress.

Proposed CLI from `backend/`:

```bash
uv run python -m app.features calculate \
  --dataset ../data/synthetic/scenarios/typical \
  --checkpoint evaluation --config config/homeostat.yaml \
  --output /tmp/homeostat-typical-features.json
```

The CLI requires a named checkpoint, validates the chosen dataset, and writes
the report with stable serialization. Support demo checkpoint IDs as well as
scenario IDs. Preserve the canonical fixture inputs. Any necessary fixture
correction must be explained, regenerated through its generator, and verified
against its manifest; never edit generated JSON alone to make a test pass.

## 11. Tests and completion gate

- Preserve all 257 existing tests (Steps 1-2 after the pre-Step-3 fixes).
- Configuration: defaults/hash equivalence; thresholds; YAML duplicate/unknown
  keys; non-finite values; source-rule conflicts; saved settings match the hash.
- Input selection: fresh/corrected checkpoints, retries/reimports, conflicting
  identities, permutations, tombstones arriving before or after original records,
  and absence of future information.
- Sleep: all relevant golden fixtures, same-source union, cross-source choice,
  awake/asleep contradictions, in-bed-only input, naps, stage boundaries before
  midnight, DST, partial visible histories and deterministic episode ties.
- Baselines/points: 0/3/13/14 days, exactly 28 calendar days, missing days/current
  values, incompatible source switches, cutoff selection, median/MAD outlier and
  zero/near-zero scale, and exact threshold endpoints.
- Movement: authored 5200/2900 example; comparable-time eligibility; sparse
  history; zero expectation; corrections in both directions; conflict and newer
  resolution; historical conflicts; travel, midnight and DST cutoffs.
- Workouts: 45 minutes, 6/24 hours, exact recency boundaries, known-empty versus
  unknown coverage, cross-midnight/paused/overlapping workouts and 23/25-hour days.
- Confidence: formula factors, bounds, monotonic age/maturity behavior, absent
  values and explicit coverage. Do not assert invented clinical accuracy.
- End-to-end: validate produced `DailyFeatures` and report references; same
  inputs/config/versions yield identical bytes across processes and input order.
  Reimports/retries preserve calculated feature values; changed knowledge may
  change corrected results. Input/evidence identity may reflect the added delivery.
- Run applicable `features` and `resolution` expectations in all 41 scenarios,
  including the strengthened golden-14 checks (`hrv.value`, `hrv.source_record_id`,
  `hrv.state`), zero/near-zero MAD (`hrv.mad`, `hrv.robust_z`) and the
  irregular movement history (`movement.usable_days`).
  Explicitly map fixture aliases such as `sleep.selected_source` and
  `movement.timezone` to report evidence. The `recovery_usable_inputs` feature
  assertion is a test-side count of ready measured sleep/HRV/RHR inputs; it does
  not introduce a recovery decision function. Keep `state` assertions labeled
  deferred until Step 4, even where feature states currently share their names.
- Calculate all 120 default demo checkpoints without a crash or invalid result;
  preserve missing/calibrating states where supported by available data.

Step 3 is complete when these gates pass, the CLI produces reviewable feature
reports, and documentation records the adopted policies and test results.

## 12. Result

All gates pass: 370 tests (113 new). Every applicable fixture expectation in
the 41 scenarios passes; all 120 demo checkpoints produce contract-valid
features, with every sleep, HRV, RHR, movement and workout state represented;
results are byte-identical across input order, processes and ambient timezones.

```bash
cd backend
uv run python -m app.features calculate \
  --dataset ../data/synthetic/scenarios/typical --checkpoint evaluation
```

## 13. Device verification before relying on real data

- Apple Watch HRV/RHR bundle IDs and product types match the `apple_watch` group.
- Resting-HR sample start/end spans: a sample counts only after its original
  end, so a long span would hide today's value until evening.
- HRV reading times relative to sleep, for the daily reading rule.
- Hourly step buckets backfill correctly across DST and travel.

## 14. Approval and next milestone

Approval covers the scope and proposed defaults above, including latest-reading
point selection, source-compatible baselines, movement time tolerance,
awake-overlap handling, workout allocation and confidence formula.

After approval, implement Step 3 in the stated order. The next milestone after
completion is Step 4: the pure recovery/state engine, executing the remaining
semantic golden assertions against these validated features.
