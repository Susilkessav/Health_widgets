G1 — End-to-End Health Data → State Engine → Widget

0. Purpose

G1 proves the core Homeostat pipeline before any real avatar work begins.

The goal is to build a working system where:

Apple Health
    ↓
HealthKit ingestion
    ↓
Canonical health events
    ↓
Backend storage
    ↓
Feature calculations
    ↓
Deterministic health state engine
    ↓
Widget presentation state
    ↓
iOS App Group cache
    ↓
Real Home Screen widget

The avatar is intentionally a dummy placeholder during G1.

Example widget:

┌──────────────────────┐
│         😴           │
│                      │
│ Shorter sleep        │
│ 5h 58m               │
│                      │
│ Strength workout ✓   │
└──────────────────────┘

The real semi-realistic avatar must not be implemented until G1 passes its acceptance criteria.

1. G1 Objective

Build a reliable, deterministic, testable end-to-end health-data system.

A successful G1 must prove that:

Real Apple Health data can be read.

HealthKit data can be normalized correctly.

Duplicate/revised/deleted HealthKit records are handled correctly.

Historical data can establish personal baselines.

Derived health features can be calculated deterministically.

Missing data and insufficient history are represented explicitly.

Semantic health states can be produced without an LLM.

Every state can explain which measurements caused it.

The resulting state can be converted into widget presentation data.

A real WidgetKit widget can display that state.

The same canonical input events can be replayed to reproduce the same state.

2. G1 Non-Goals

Do not implement these during G1:

Real avatar art.

Rive avatar rig.

3D avatar.

Avatar customization.

AI coach.

LangGraph.

MCP.

LLM calls.

Oura.

WHOOP.

Garmin.

Google Health.

Health Connect.

Android.

Food logging.

Meal photos.

Barcode scanning.

Nutrition calculations.

Calendar agent.

Workout planner.

Muscle/body-region mapping.

Full training-load model.

Future-self simulator.

Personal experiments.

Social features.

Avatar room.

Gamification.

Dagster in the realtime path.

dbt in the realtime path.

Kafka.

Redis unless later proven necessary.

Subscription/paywall.

G1 should remain deliberately small.

3. Core Architecture Principle

Health calculations must never directly produce avatar graphics.

Use this separation:

Raw Health Data
      ↓
Canonical Events
      ↓
Feature Calculator
      ↓
HealthState
      ↓
Presentation Mapper
      ↓
WidgetState
      ↓
Widget Renderer

The deterministic engine outputs semantic state.

Example:

{
  "sleep": {
    "state": "below_baseline",
    "severity": 0.62,
    "confidence": 0.96
  }
}

It must not output:

{
  "eyes": "tired"
}

The dummy presentation layer may later map:

sleep = below_baseline
    ↓
😴

The future avatar renderer can map the same state to:

eyelid droop
under-eye shading
slower blink animation

without changing the health engine.

4. Recommended G1 Stack

iOS

Swift
SwiftUI
HealthKit
WidgetKit
App Intents
App Groups
SQLite / GRDB for local sync queue

Backend

Python 3.12+
FastAPI
Pydantic
SQLAlchemy
Alembic
PostgreSQL

Calculations

Pure Python
NumPy if useful
Polars if useful

Do not require dataframe libraries for simple calculations.

Testing

pytest
Hypothesis

Development

Docker Compose
PostgreSQL container
FastAPI container

Not needed yet

Dagster
dbt
Redis
Kafka
LangGraph
Langfuse
MCP

5. High-Level System Design

                         iOS DEVICE

                 ┌────────────────────┐
                 │    Apple Health    │
                 └─────────┬──────────┘
                           │
                           ▼
                 ┌────────────────────┐
                 │ HealthKit Adapter  │
                 │                    │
                 │ Observer Queries   │
                 │ Anchored Queries   │
                 │ Statistics Queries │
                 └─────────┬──────────┘
                           │
                           ▼
                 ┌────────────────────┐
                 │ Raw HK DTOs        │
                 └─────────┬──────────┘
                           │
                           ▼
                 ┌────────────────────┐
                 │ Canonicalizer      │
                 └─────────┬──────────┘
                           │
                           ▼
                 ┌────────────────────┐
                 │ Local Sync Queue   │
                 │ SQLite / GRDB      │
                 └─────────┬──────────┘
                           │
                        HTTPS
                           │
                           ▼

                         BACKEND

                 ┌────────────────────┐
                 │ FastAPI Gateway    │
                 └─────────┬──────────┘
                           │
                           ▼
                 ┌────────────────────┐
                 │ PostgreSQL         │
                 │ canonical events   │
                 └─────────┬──────────┘
                           │
                           ▼
                 ┌────────────────────┐
                 │ Feature Calculator │
                 └─────────┬──────────┘
                           │
                           ▼
                 ┌────────────────────┐
                 │ State Engine       │
                 │ pure/deterministic │
                 └─────────┬──────────┘
                           │
                           ▼
                 ┌────────────────────┐
                 │ Presentation Map   │
                 └─────────┬──────────┘
                           │
                           ▼
                 ┌────────────────────┐
                 │ WidgetState        │
                 └─────────┬──────────┘
                           │
                        HTTPS
                           │
                           ▼

                         iOS DEVICE

                 ┌────────────────────┐
                 │ App Group Cache    │
                 │ widget_state.json  │
                 └─────────┬──────────┘
                           │
                           ▼
                 ┌────────────────────┐
                 │ WidgetKit          │
                 │ Dummy renderer     │
                 └────────────────────┘

6. G1 Health Data

Only ingest the following initially:

Required

Sleep.

Steps.

Workouts.

Resting heart rate.

HRV.

Optional later inside G1 only if trivial:

Active energy.

Do not add additional metrics merely because HealthKit provides them.

7. HealthKit Adapter vs Canonical Model

HealthKit-specific objects must remain isolated inside the iOS adapter layer.

The backend/domain layer should never depend directly on:

HKQuantitySample
HKCategorySample
HKSourceRevision
HKQueryAnchor
HKWorkout
HKDeletedObject

Architecture:

HealthKit Object
      ↓
HealthKit DTO
      ↓
Canonicalizer
      ↓
Homeostat Canonical Event

This makes future providers adapters rather than architecture changes.

8. HealthKit Metadata to Preserve

For each relevant HealthKit sample preserve enough source information to reprocess later.

At minimum:

sample UUID
HealthKit data type
start date
end date
source name
source bundle identifier where available
source revision
device/product type where available
timezone metadata where available
category value
unit
value

Do not discard source/device metadata before normalization.

9. Canonical Event Types

Do not force every health record into one universal timestamp structure.

Use typed canonical events.

9.1 PointMeasurement

For measurements that semantically occur at a point.

Examples:

HRV.

Resting heart rate.

{
  "schema_version": "1.0.0",
  "event_id": "uuid",
  "event_type": "point_measurement",

  "source": "healthkit",
  "source_record_id": "healthkit-uuid",

  "metric": "hrv_sdnn_ms",

  "observed_at": "2026-09-22T06:40:00-05:00",

  "value": 54.2,
  "unit": "ms",

  "metadata": {}
}

Use observed_at.

Do not require start_at/end_at in the canonical point model.

9.2 IntervalEvent

For interval data.

Examples:

Sleep stages.

Sedentary periods later.

{
  "schema_version": "1.0.0",
  "event_id": "uuid",
  "event_type": "interval",

  "source": "healthkit",
  "source_record_id": "healthkit-uuid",

  "kind": "sleep_stage",
  "value": "asleep_core",

  "start_at": "2026-09-21T23:58:00-05:00",
  "end_at": "2026-09-22T00:42:00-05:00",

  "metadata": {
    "timezone": "America/Chicago"
  }
}

9.3 WorkoutEvent

{
  "schema_version": "1.0.0",
  "event_id": "uuid",
  "event_type": "workout",

  "source": "healthkit",
  "source_record_id": "healthkit-uuid",

  "workout_type": "traditional_strength_training",

  "start_at": "2026-09-22T17:52:00-05:00",
  "end_at": "2026-09-22T18:48:00-05:00",

  "duration_minutes": 56,

  "metadata": {}
}

9.4 DailyActivitySnapshot

Do not upload every raw HealthKit step sample.

{
  "schema_version": "1.0.0",
  "event_id": "uuid",
  "event_type": "daily_activity_snapshot",

  "source": "healthkit",

  "day": "2026-09-22",

  "as_of": "2026-09-22T13:20:00-05:00",

  "steps": 4821
}

9.5 DeleteEvent

HealthKit samples are immutable.

Deleted samples arrive through anchored queries as deleted objects.

{
  "schema_version": "1.0.0",
  "event_id": "uuid",
  "event_type": "delete",

  "source": "healthkit",
  "source_record_id": "deleted-healthkit-uuid",

  "deleted_at": "2026-09-22T07:02:00-05:00"
}

There is no custom revision counter.

Canonical HealthKit operations are effectively:

insert/upsert UUID
delete UUID

10. Sleep Ingestion Rules

Sleep needs special handling.

HealthKit may contain overlapping:

inBed
awake
asleepUnspecified
asleepCore
asleepDeep
asleepREM

Do not calculate sleep duration as:

session_end - session_start

That produces incorrect sleep duration.

11. Sleep Duration

Sleep duration must be:

union(
    asleepUnspecified intervals,
    asleepCore intervals,
    asleepDeep intervals,
    asleepREM intervals
)

Then:

sleep_minutes =
sum(duration of merged asleep intervals)

Exclude:

inBed
awake

from actual sleep duration.

12. Sleep Features to Preserve

For each selected primary sleep episode derive:

sleep_day
sleep_start
sleep_end
sleep_span_minutes
asleep_minutes
in_bed_minutes if available
awake_minutes if available
source
timezone
confidence

Later sleep-stage totals may include:

core_minutes
deep_minutes
rem_minutes

They are not required for initial G1 state logic.

13. Sleep Source Resolution

Even Apple-only HealthKit may contain overlapping sleep from:

Apple Watch
iPhone
third-party sleep apps

Do not combine all sources blindly.

Process:

Raw sleep samples
      ↓
Group by candidate night
      ↓
Group by source/device
      ↓
Construct source-specific sleep episode
      ↓
Apply configured source priority
      ↓
Select authoritative source
      ↓
Derive sleep features

Default source priority can begin as:

Apple Watch
    >
iPhone
    >
third-party

but this must be configurable.

Do not present this as an Apple-defined universal hierarchy.

Store:

selected_source
source_policy_version

with derived sleep features.

14. Sleep-Day Assignment

Primary overnight sleep belongs to the wake day.

Example:

sleep starts:
2026-09-21 23:41

sleep ends:
2026-09-22 06:03

Therefore:

sleep_day = 2026-09-22

Use the sleep episode's local timezone.

This means:

At:

2026-09-22 07:00

"Today's sleep" means the main sleep that ended that morning.

At:

2026-09-22 23:00

"Today's sleep" still means the main sleep that ended that morning.

15. Primary Sleep vs Naps

Do not merge all asleep intervals during one calendar day into one sleep period.

Classify episodes as:

primary
nap

G1 may use a simple primary-sleep heuristic:

Longest sleep episode overlapping the user's expected overnight period.

Everything else becomes a nap.

Keep this rule versioned and replaceable.

16. HealthKit Source Authorization

HealthKit intentionally does not reveal whether read access for a type was denied.

Therefore Homeostat must never claim:

HRV permission denied

based only on an empty query.

Track Homeostat's own onboarding state instead.

Example:

not_requested
requested
visible_data_seen

Optional:

first_visible_sample_at
last_visible_sample_at

If no samples are visible after requesting access, use language such as:

No HRV data visible yet

not:

HRV permission denied

and not necessarily:

HRV is still syncing

17. Calibration State

Personal baseline classifications must not be shown before enough history exists.

Configuration:

baseline:
  target_days: 28
  minimum_valid_days: 14

Before 14 valid observations:

baseline_status = calibrating

Example widget:

🙂

Learning your baseline

7 / 14 usable days

The system may show raw values:

Sleep: 6h 42m

but must not say:

1h below your usual

until a valid baseline exists.

18. HealthKit Bootstrap

On first successful setup:

Request HealthKit access
       ↓
Fetch approximately 35 days
       ↓
Normalize
       ↓
Sync backend
       ↓
Build baseline

35 days provides enough buffer for a 28-day baseline when some days are missing.

19. Incremental HealthKit Sync

After bootstrap:

HKObserverQuery
      ↓
HealthKit reports changed data
      ↓
HKAnchoredObjectQuery
      ↓
new samples
+
deleted sample UUIDs
      ↓
normalize
      ↓
local queue
      ↓
backend sync

Background delivery is best-effort.

Never design the UX around guaranteed immediate HealthKit background execution.

Always perform catch-up synchronization when the app opens.

20. HKQueryAnchor Storage

HKQueryAnchor is opaque and must not be treated as an integer.

Store it using secure Apple serialization.

AnchorStore maintains anchors independently per HealthKit query/data type.

Conceptually:

sleepAnalysis → anchor A

HRV → anchor B

RHR → anchor C

workouts → anchor D

Steps use statistics queries and therefore have different synchronization behavior.

21. Lost Anchor Recovery

Anchor loss can happen because of:

reinstall
local DB loss
corruption
sync schema changes
restore

If an anchor is missing/invalid:

anchor = nil
       ↓
bounded rebootstrap
       ↓
reconcile recent HealthKit UUIDs
       ↓
rebuild backend state
       ↓
store new anchor

Do not assume rebootstrap means only appending new records.

Previously seen records may have been deleted.

22. Steps

Do not enumerate every raw step sample.

Use:

HKStatisticsQuery

for:

steps today so far

and:

HKStatisticsCollectionQuery

for historical hourly/daily step buckets.

HealthKit statistics handle overlapping Apple data sources more appropriately than naive raw-sample summation.

G1 backend receives:

DailyActivitySnapshot

rather than millions of individual step samples.

23. Resting Heart Rate

Store HealthKit resting-heart-rate samples by UUID.

Apple may replace an earlier estimate with a newer estimate.

This should naturally become:

delete old UUID
+
insert new UUID

No custom revision field is required.

24. HRV

For Apple Health G1:

HRV metric = SDNN

Do not assume Apple's HealthKit HRV value is RMSSD.

Canonical metric:

hrv_sdnn_ms

Do not mix SDNN and RMSSD into the same baseline later.

Future source adapters must preserve metric methodology.

25. Backend Data Model

G1 needs only a small number of tables.

25.1 health_events

create table health_events (
    id uuid primary key,

    user_id uuid not null,

    schema_version text not null,

    source text not null,
    source_record_id text not null,

    event_type text not null,

    observed_at timestamptz,
    start_at timestamptz,
    end_at timestamptz,

    payload jsonb not null,

    received_at timestamptz not null default now(),

    unique (
        user_id,
        source,
        source_record_id,
        event_type
    )
);

Deletion may be modeled as either:

a delete event

or:

a tombstone record

but replay behavior must remain deterministic.

25.2 daily_features

create table daily_features (
    user_id uuid not null,

    day date not null,

    feature text not null,

    value double precision,

    categorical_value text,

    confidence double precision,

    feature_version text not null,

    provenance jsonb not null,

    effective_at timestamptz not null,

    computed_at timestamptz not null default now(),

    primary key (
        user_id,
        day,
        feature,
        feature_version
    )
);

25.3 health_state_history

create table health_state_history (
    id uuid primary key,

    user_id uuid not null,

    effective_at timestamptz not null,

    engine_version text not null,

    trigger_event_id uuid,

    state jsonb not null,

    computed_at timestamptz not null default now()
);

effective_at is deterministic.

computed_at is operational metadata.

Replay comparisons ignore computed_at.

26. Local iOS Sync Queue

HealthKit data should enter a durable local queue before upload.

Example:

pending
sending
accepted
duplicate
retry
dead_letter

Store:

client_event_id
canonical event
attempt count
last attempt
next attempt
status
server error code

Network failure must not lose HealthKit events.

27. Sync API

Endpoint:

POST /v1/health/sync

Request:

{
  "events": [
    {}
  ]
}

Do not return only aggregate counters.

Return one result per client event.

Example:

{
  "results": [
    {
      "client_event_id": "a",
      "status": "accepted",
      "retryable": false
    },
    {
      "client_event_id": "b",
      "status": "duplicate",
      "retryable": false
    },
    {
      "client_event_id": "c",
      "status": "rejected",
      "code": "INVALID_UNIT",
      "retryable": false
    }
  ],

  "affected_days": [
    "2026-09-22"
  ],

  "widget_state": {}
}

28. Sync Retry Rules

Accepted

Remove from local queue.

Duplicate

Remove from queue.

Duplicate means backend already has equivalent logical data.

Permanent validation error

Example:

INVALID_UNIT
INVALID_EVENT_SCHEMA
UNKNOWN_METRIC

Set:

dead_letter

Do not retry indefinitely.

Temporary error

Example:

database unavailable
service unavailable
timeout

Retry with backoff.

Transport failure

If the client receives no server response:

keep entire batch pending

because backend ingestion is idempotent.

29. Feature Calculation Layer

Feature calculation answers:

What are the derived numbers?

It must remain separate from semantic state interpretation.

CanonicalEvents
      ↓
calculate_features()
      ↓
DailyFeatures

Examples:

sleep_hours
sleep_baseline_hours
sleep_delta_hours

hrv_value
hrv_baseline
hrv_robust_z

rhr_value
rhr_baseline
rhr_robust_z

steps_today
expected_steps_now
movement_ratio

last_workout_end
hours_since_workout

30. Baseline Calculation

For baseline metric x:

median_28 =
median(previous 28 valid daily values)

Then:

MAD =
median(
    abs(x - median_28)
)

Robust z-score:

robust_z =
(x - median_28)
/
(1.4826 × MAD)

Handle near-zero MAD safely.

Example:

if MAD < epsilon:
    robust_z = fallback logic

The fallback must be deterministic and unit tested.

31. Baselines Must Be Source-Aware

Do not mix measurements from incompatible source methodologies into one baseline.

Example:

Apple HRV SDNN

must not later be silently mixed with:

Oura RMSSD

Baseline key should conceptually include:

metric
source/methodology

32. Sleep Features

For wake day D:

sleep_hours
sleep_span_hours
in_bed_hours
awake_minutes
sleep_start
sleep_end

sleep_baseline_hours
sleep_delta_hours
sleep_ratio

baseline_status
confidence
source

Initial state thresholds can remain deliberately simple.

After calibration:

delta <= -60 min
→ below_baseline

-60 min < delta < +60 min
→ typical

delta >= +60 min
→ above_baseline

These are Homeostat product thresholds, not medical thresholds.

Keep them in configuration.

33. HRV Features

Input:

hrv_sdnn_ms

Calculate:

baseline median
MAD
robust z

Initial classification:

z < -1.0
→ below_usual

-1.0 <= z <= +1.0
→ typical

z > +1.0
→ above_usual

Do not diagnose anything from this classification.

34. Resting HR Features

Calculate:

rhr_bpm
baseline_rhr
rhr_robust_z

Initial classification:

z > +1.0
→ above_usual

-1.0 <= z <= +1.0
→ typical

z < -1.0
→ below_usual

Use wording such as:

above your usual range

not:

bad heart rate

35. Movement Features

After sufficient history, calculate the user's expected cumulative steps around the current time.

Example:

Monday 1 PM historical median:
5,200 steps

Today at 1 PM:
3,700

Then:

movement_ratio =
steps_so_far /
expected_steps_now

Initial classification:

ratio < 0.70
→ behind_usual

0.70 <= ratio <= 1.30
→ typical

ratio > 1.30
→ ahead_of_usual

Before a movement baseline exists:

state = calibrating

36. Workout Features

Keep G1 simple.

Calculate:

last_workout_type
last_workout_start
last_workout_end
hours_since_workout
workout_minutes_today
workout_minutes_last_7d

Initial state:

active
just_completed
recent_workout
none_recent

Possible rule:

currently active
→ active

ended <= 2h ago
→ just_completed

ended <= 12h ago
→ recent_workout

otherwise
→ none_recent

Put thresholds in configuration.

Do not implement muscle mapping yet.

37. Recovery Context

Do not expose a precise numerical recovery score in G1.

Use semantic state.

Inputs:

sleep
HRV
RHR

First require:

at least 2 usable inputs

otherwise:

recovery.state = insufficient_data

38. Recovery Rule V0

Adverse indicators:

sleep == below_baseline

HRV == below_usual

RHR == above_usual

If at least two adverse indicators exist:

recovery = strained

Strong favorable state:

HRV == above_usual
AND
RHR == below_usual
AND
sleep != below_baseline

Then:

recovery = favorable

Otherwise:

recovery = typical

Important isolated cases:

HRV below
sleep typical
RHR typical

→ typical

and:

HRV above
sleep typical
RHR typical

→ typical

A single unusual HRV reading must not move recovery in either direction.

39. Confidence

Every feature receives a confidence value.

Initial components may include:

freshness
data completeness
baseline maturity
source quality

Keep confidence logic deterministic.

40. Composite Recovery Confidence

For G1:

Determine usable inputs.

If fewer than two usable inputs:

recovery_confidence = 0
recovery_state = insufficient_data

Otherwise:

base_confidence =
min(confidence of usable inputs)

Coverage:

coverage =
usable_input_count / total_expected_inputs

For recovery:

total_expected_inputs = 3

Then:

recovery_confidence =
base_confidence × coverage

Example:

sleep confidence = 0.95

HRV confidence = 0.92

RHR confidence = 0.98

All three available:

min = 0.92
coverage = 1.0

recovery confidence = 0.92

Only sleep + HRV:

min = 0.92
coverage = 2 / 3

recovery confidence ≈ 0.61

This is intentionally conservative.

41. DailyFeatures Contract

Example:

{
  "version": "features@0.1.0",

  "day": "2026-09-22",

  "sleep": {
    "hours": 5.97,
    "baseline_hours": 7.27,
    "delta_hours": -1.30,
    "state": "below_baseline",
    "baseline_status": "ready",
    "confidence": 0.97,
    "source": "apple_watch"
  },

  "hrv": {
    "metric": "hrv_sdnn_ms",
    "value": 54.2,
    "robust_z": -0.82,
    "state": "typical",
    "confidence": 0.92
  },

  "rhr": {
    "value_bpm": 58,
    "robust_z": 0.31,
    "state": "typical",
    "confidence": 0.95
  },

  "movement": {
    "steps": 4821,
    "expected_steps_now": 6300,
    "ratio": 0.765,
    "state": "typical",
    "confidence": 0.91
  },

  "workout": {
    "state": "recent_workout",
    "type": "traditional_strength_training",
    "hours_since": 1.3,
    "confidence": 1.0
  }
}

42. State Engine

The state engine receives features only.

Interface:

health_state = compute_health_state(
    features=features,
    config=config
)

The function must not:

Read the database.

Call HTTP.

Call HealthKit.

Call an LLM.

Know anything about WidgetKit.

Know anything about the avatar renderer.

It should be deterministic.

43. HealthState Contract

Example:

{
  "version": "health-state@0.1.0",

  "effective_at": "2026-09-22T13:20:00-05:00",

  "calibration": {
    "status": "ready"
  },

  "sleep": {
    "state": "below_baseline",
    "severity": 0.62,
    "confidence": 0.97
  },

  "recovery": {
    "state": "typical",
    "confidence": 0.92
  },

  "movement": {
    "state": "typical",
    "confidence": 0.91
  },

  "workout": {
    "state": "recent_workout",
    "type": "strength",
    "confidence": 1.0
  },

  "drivers": [
    {
      "id": "sleep_duration",
      "value": 5.97,
      "baseline": 7.27,
      "difference": -1.30,
      "source": "apple_watch",
      "confidence": 0.97
    }
  ]
}

No avatar-specific fields belong here.

44. Provenance

Every state must be explainable.

A state driver should contain enough information to answer:

What changed?

What was the value?

What is the baseline?

What is the difference?

Which source produced it?

How confident are we?

When was it observed?

Example:

{
  "id": "sleep_duration",
  "value": 5.97,
  "baseline": 7.27,
  "difference": -1.30,
  "unit": "hours",
  "source": "apple_watch",
  "observed_at": "2026-09-22T06:03:00-05:00",
  "confidence": 0.97
}

45. Dummy Presentation Mapper

This is the only G1 component allowed to convert health semantics into visual semantics.

Input:

HealthState

Output:

WidgetState

Example mapping:

sleep below_baseline
→ 😴
→ "Shorter sleep"

workout just_completed
→ 🏋️
→ "Workout complete"

movement ahead_of_usual
→ 🚶
→ "More active than usual"

calibrating
→ 🙂
→ "Learning your baseline"

Do not spend time making this visually sophisticated.

46. WidgetState Contract

Example:

{
  "version": "widget-state@0.1.0",

  "effective_at": "2026-09-22T13:20:00-05:00",

  "presentation": {
    "icon": "😴",

    "headline": "Shorter sleep",

    "detail": "5h 58m",

    "secondary": "Strength workout completed recently"
  },

  "primary_trait": {
    "id": "sleep",
    "explainable": true
  },

  "freshness": {
    "last_updated_at": "2026-09-22T13:20:00-05:00"
  }
}

The WidgetKit target consumes only WidgetState.

It must not contain health calculation logic.

47. iOS Widget Data Flow

The widget should not make backend requests during rendering.

Flow:

Main app receives WidgetState
       ↓
writes widget_state.json
       ↓
App Group shared container
       ↓
WidgetCenter.reloadTimelines(...)
       ↓
Widget extension
       ↓
reads cached WidgetState
       ↓
renders

48. Offline Behavior

If:

HealthKit works
backend unavailable

then:

canonical events
→ remain in local queue

The widget continues showing the last valid state.

Show freshness:

Updated 2h ago

Do not erase the widget merely because the API is temporarily unavailable.

49. Configuration

Initial engine settings belong in configuration.

Example:

baseline:
  days: 28
  minimum_valid_days: 14

sleep:
  below_baseline_minutes: 60
  above_baseline_minutes: 60

hrv:
  lower_z: -1.0
  upper_z: 1.0

rhr:
  lower_z: -1.0
  upper_z: 1.0

movement:
  behind_ratio: 0.70
  ahead_ratio: 1.30

workout:
  just_completed_hours: 2
  recent_hours: 12

engine:
  version: "0.1.0"

Do not bury thresholds inside business-logic functions.

50. Versioning Policy

Version independently:

canonical event schema
feature calculations
state engine
widget state contract

Event schema version

Bump when:

Event field meaning changes.

Required structure changes.

New incompatible event semantics are introduced.

Example:

event-schema@1.0.0

Feature version

Bump when the calculation of a derived feature changes.

Examples:

baseline window:
28 days → 42 days

movement expectation algorithm changed

sleep source selection algorithm changed

Example:

features@0.2.0

Engine version

Bump when semantic interpretation changes.

Examples:

sleep threshold:
60 min → 45 min

recovery rule tree changes

confidence combination changes

Example:

state-engine@0.2.0

WidgetState version

Bump when the API contract consumed by the widget changes.

Example:

widget-state@1.0.0

Presentation-only changes

Changing:

😴 → another icon

without changing semantic state does not bump the health engine version.

51. Recalculation

If historical health data changes:

changed health event
      ↓
determine affected day
      ↓
recalculate affected features
      ↓
recalculate dependent baseline window
      ↓
recalculate HealthState
      ↓
emit WidgetState if relevant

For G1 it is acceptable to recalculate:

changed_day → today

within approximately the last 35 days.

Optimize later.

52. Deterministic Replay

A critical G1 requirement:

empty derived tables
      ↓
replay canonical events
      ↓
calculate features
      ↓
calculate states

Run twice with:

same canonical events
same configuration
same feature version
same engine version

Result:

identical deterministic state payloads

Ignore operational metadata such as:

computed_at

during equality checks.

53. Golden Test Days

Create synthetic scenarios before connecting real HealthKit data.

Golden Day 1 — Calibration

History:

3 valid nights

Expected:

baseline_status = calibrating

no below/above baseline claims

Widget:

Learning your baseline
3 / 14 usable days

Golden Day 2 — Typical

sleep typical
HRV typical
RHR typical
steps typical
no recent workout

Expected:

sleep = typical
recovery = typical
movement = typical

Golden Day 3 — Short sleep only

sleep = below_baseline
HRV = typical
RHR = typical

Expected:

sleep = below_baseline
recovery = typical

Golden Day 4 — Low HRV only

sleep = typical
HRV = below_usual
RHR = typical

Expected:

recovery = typical

This explicitly verifies the symmetric recovery decision.

Golden Day 5 — High HRV only

sleep = typical
HRV = above_usual
RHR = typical

Expected:

recovery = typical

Golden Day 6 — Multiple adverse signals

sleep = below_baseline
HRV = below_usual
RHR = above_usual

Expected:

recovery = strained

Golden Day 7 — Favorable agreement

sleep != below_baseline
HRV = above_usual
RHR = below_usual

Expected:

recovery = favorable

Golden Day 8 — Missing HRV

sleep available
RHR available
HRV missing

Expected:

recovery computed from 2 usable inputs if allowed
confidence reduced by coverage

Golden Day 9 — Insufficient recovery data

Only:

sleep available

Expected:

recovery = insufficient_data
confidence = 0

Golden Day 10 — Recent workout

workout ended 45m ago

Expected:

workout = just_completed

Golden Day 11 — Movement behind usual

expected steps at 1 PM = 5,200
actual = 2,900

Expected:

movement = behind_usual

Golden Day 12 — Multi-source sleep

Input:

Apple Watch sleep
iPhone sleep
third-party sleep

with overlapping intervals.

Expected:

one authoritative source selected
no double counting

Golden Day 13 — Sleep awake interval

Input:

in bed = 8h

asleep intervals = 6h50

awake intervals = 40m

Expected:

sleep_hours = 6h50

not:

8h

Golden Day 14 — HealthKit deletion

Input:

sample A added

sample A deleted

sample B added

Expected:

derived state reflects B only

54. Tests

Canonicalization

Test:

Point measurements.

Interval events.

Workouts.

Activity snapshots.

Deletions.

Time zones.

Multiple sources.

Sleep

Test:

Sleep stages.

Awake gaps.

In-bed exclusion.

Overlapping asleep intervals.

Source priority.

Wake-day assignment.

Naps.

DST/timezone transitions.

Baselines

Test:

0 days.

13 days.

14 days.

28 days.

Missing days.

MAD = 0.

Outliers.

State engine

Test every golden scenario.

Confidence

Test:

3/3 inputs.

2/3 inputs.

1/3 inputs.

stale input.

calibrating input.

Idempotency

Send identical event:

1 time
10 times

Final logical state must be identical.

Deletions

Delete previously ingested UUID and verify recalculation.

Replay

Rebuild from canonical events and compare state payloads.

Widget contract

Validate every emitted widget payload against schema.

55. Debug Screen

Build a temporary developer screen inside the iOS app.

Example:

HEALTHKIT
────────────────

Sleep            data visible ✓
Steps            data visible ✓
RHR              data visible ✓
HRV              no data visible
Workouts         data visible ✓


SYNC
────────────────

Last HealthKit check
4:14 PM

Queue
0 pending

API
Connected


BASELINE
────────────────

Sleep
19 / 28 usable days

Status
Ready


TODAY
────────────────

Sleep
5h 58m

Baseline
7h 16m

Delta
-1h18m

Sleep state
below_baseline


HRV
────────────────

Value
54 ms SDNN

State
typical


RECOVERY
────────────────

State
typical

Confidence
0.61


WIDGET
────────────────

😴
Shorter sleep
5h 58m

This screen is development-only but should be built early.

56. Logging

Use structured operational logs.

Safe fields:

sync_id
number_of_events
event types
affected days
calculation duration
engine version
feature version
state changed true/false
queue size
API result

Avoid normal production logs containing:

exact HRV
exact resting HR
exact sleep
raw HealthKit payload

57. Authentication During G1

Do not make auth a blocking task.

Initial development may use:

single development user

or:

development API key

All backend tables must still contain:

user_id

Before external beta, replace with proper authentication.

58. Build Order

Agents should implement G1 in this order.

Step 1 — Contracts

Create:

CanonicalEvent

PointMeasurement

IntervalEvent

WorkoutEvent

DailyActivitySnapshot

DeleteEvent

DailyFeatures

HealthState

WidgetState

Add JSON/Pydantic validation.

Done when

Synthetic contracts validate in unit tests.

Step 2 — Synthetic Dataset

Generate at least:

40 days

of deterministic synthetic data.

Include:

Typical days.

Short sleep.

Missing HRV.

Low HRV.

High RHR.

Recent workouts.

Step variance.

Sleep gaps.

Multi-source sleep.

Deleted/replaced samples.

Use a fixed random seed.

Done when

Dataset can be reproduced identically.

Step 3 — Feature Calculations

Implement:

sleep derivation

sleep source resolver

wake-day assignment

baseline calculations

HRV context

RHR context

movement pacing

recent workout context

confidence

Done when

Feature golden tests pass.

Step 4 — State Engine

Implement:

compute_health_state(features, config)

Done when

All semantic golden days pass.

Step 5 — Dummy Presentation Mapper

Implement:

HealthState
→ WidgetState

using simple icons/text.

Done when

Every golden state generates a valid widget payload.

Step 6 — PostgreSQL

Implement:

health_events
daily_features
health_state_history

plus migrations.

Done when

Synthetic events can be stored and replayed.

Step 7 — FastAPI

Implement:

POST /v1/health/sync

GET /v1/state/current

GET /v1/state/{day}

GET /v1/debug/features/{day}

Debug endpoint is development only.

Done when

Posting synthetic data returns correct WidgetState.

Step 8 — Replay CLI

Example:

homeostat replay \
  --user dev \
  --from 2026-08-01 \
  --to 2026-09-22

Done when

Replaying twice produces identical deterministic states.

Step 9 — Minimal iOS App

Implement:

SwiftUI shell.

HealthKit capability.

Authorization request.

Onboarding permission-request ledger.

Debug screen.

Done when

App can query HealthKit and show visible data.

Step 10 — HealthKit Bootstrap

Fetch approximately 35 historical days.

Implement:

Sleep.

HRV.

RHR.

Workouts.

Step statistics.

Done when

Real HealthKit data appears in the debug screen.

Step 11 — Incremental Sync

Implement:

Observer Queries

Anchored Queries

AnchorStore

deletions

rebootstrap path

Done when

New/replaced/deleted HealthKit records correctly update backend data.

Step 12 — Local Sync Queue

Implement durable SQLite/GRDB queue.

Done when

Turning network access off does not lose health events.

Step 13 — Backend Sync

Connect queue to:

POST /v1/health/sync

Implement per-event acknowledgements.

Done when

Accepted events are removed and permanent errors are not retried.

Step 14 — App Group Cache

Persist latest:

WidgetState

to shared container.

Done when

Main app and widget extension can read identical state.

Step 15 — Dummy Widget

Implement:

Small widget.

Medium widget.

Cached state.

Freshness.

Calibration state.

Missing-data state.

Done when

Real Home Screen widget reflects real HealthKit-derived state.

Step 16 — Background / Catch-up

Implement:

Observer-based update attempts.

Widget timeline reload.

App-open catch-up.

Retry behavior.

Done when

System remains correct even if background delivery is delayed.

59. Recommended Repository Structure

homeostat/
│
├── plan_G1.md
│
├── homeostat.yaml
│
├── docker-compose.yml
│
├── README.md
│
├── backend/
│   │
│   ├── app/
│   │   ├── main.py
│   │   │
│   │   ├── api/
│   │   │   ├── sync.py
│   │   │   ├── state.py
│   │   │   └── debug.py
│   │   │
│   │   ├── contracts/
│   │   │   ├── canonical_events.py
│   │   │   ├── features.py
│   │   │   ├── health_state.py
│   │   │   └── widget_state.py
│   │   │
│   │   ├── ingestion/
│   │   │   ├── service.py
│   │   │   └── idempotency.py
│   │   │
│   │   ├── features/
│   │   │   ├── baselines.py
│   │   │   ├── sleep.py
│   │   │   ├── hrv.py
│   │   │   ├── rhr.py
│   │   │   ├── movement.py
│   │   │   └── workouts.py
│   │   │
│   │   ├── engine/
│   │   │   ├── compute.py
│   │   │   ├── recovery.py
│   │   │   ├── confidence.py
│   │   │   └── version.py
│   │   │
│   │   ├── presentation/
│   │   │   └── dummy_mapper.py
│   │   │
│   │   └── db/
│   │       ├── models.py
│   │       └── repository.py
│   │
│   └── tests/
│       ├── golden/
│       ├── features/
│       ├── engine/
│       └── replay/
│
├── ios/
│   │
│   ├── Homeostat/
│   │   │
│   │   ├── Health/
│   │   │   ├── HealthKitManager.swift
│   │   │   ├── AuthorizationLedger.swift
│   │   │   ├── HealthSyncCoordinator.swift
│   │   │   ├── HealthNormalizer.swift
│   │   │   ├── SleepResolver.swift
│   │   │   └── AnchorStore.swift
│   │   │
│   │   ├── Networking/
│   │   │   ├── APIClient.swift
│   │   │   └── SyncService.swift
│   │   │
│   │   ├── Storage/
│   │   │   ├── SyncQueue.swift
│   │   │   └── SharedWidgetStore.swift
│   │   │
│   │   ├── Debug/
│   │   │   └── HealthDebugView.swift
│   │   │
│   │   └── Models/
│   │
│   └── HomeostatWidget/
│       ├── HomeostatWidget.swift
│       ├── TimelineProvider.swift
│       └── DummyStateView.swift
│
├── data/
│   └── synthetic/
│
└── docs/
    ├── contracts.md
    ├── state-engine.md
    └── healthkit-sync.md

60. G1 Acceptance Criteria

Do not start the real avatar until all required criteria pass.

HealthKit

HealthKit authorization flow works.

App tracks types requested separately from data visible.

35-day bootstrap works.

Sleep stage intervals are read correctly.

Sleep duration sums asleep intervals only.

Sleep source resolver prevents double counting.

Primary overnight sleep belongs to wake day.

Naps remain separate.

Steps use statistics queries.

HRV is explicitly treated as SDNN.

Resting HR is imported correctly.

Workouts are imported correctly.

Anchored incremental sync works.

Anchors persist correctly.

Lost-anchor rebootstrap works.

Deleted HealthKit objects are handled.

Replaced samples produce correct final state.

Backend

Sync endpoint is idempotent.

Per-event acknowledgement works.

Permanent errors are distinguishable from retryable errors.

Canonical events retain provenance.

Historical recalculation works.

PostgreSQL migrations are reproducible.

Features

Calibration state works.

28-day baseline works.

Minimum 14 valid days rule works.

Sleep classification works.

HRV classification works.

RHR classification works.

Movement pacing works.

Recent workout state works.

Missing data lowers confidence.

Composite confidence follows documented rule.

State engine

Pure deterministic function.

No DB access inside engine.

No network access inside engine.

No UI logic inside engine.

No avatar-specific logic inside engine.

No AI dependency.

Recovery symmetry golden tests pass.

All golden days pass.

Replay

Same canonical input + config + versions produces identical state.

Deletions replay correctly.

Multi-source sleep replay correctly.

Operational timestamps do not affect deterministic equality.

iOS queue

Events survive network failure.

Accepted events leave queue.

Duplicates leave queue.

Permanent invalid events enter dead-letter/debug state.

Retryable events retry with backoff.

Widget

Real Home Screen widget exists.

Widget reads cached WidgetState.

Widget does not query HealthKit directly.

Widget does not run health calculations.

Calibration widget exists.

Missing-data state exists.

Freshness is visible when stale.

Widget continues working during temporary backend outage.

Meaningful state changes trigger timeline reload when practical.

61. Definition of G1 Complete

G1 is complete when this exact demo works:

1. User installs Homeostat.

2. User grants requested HealthKit access.

3. App imports approximately 35 historical days.

4. Sleep resolver selects an authoritative sleep source.

5. Asleep intervals produce correct sleep duration.

6. Backend builds personal baselines.

7. HRV, RHR, sleep, movement and recent-workout
   features are calculated.

8. Deterministic HealthState is created.

9. Dummy presentation mapper creates WidgetState.

10. Main app writes WidgetState into App Group storage.

11. Actual iOS Home Screen widget displays it.

12. Tapping/opening the app shows the exact values and
    provenance behind the state.

13. A new HealthKit event later arrives.

14. Incremental sync updates the relevant features.

15. State changes if appropriate.

16. Widget refreshes when practical.

17. Replaying the complete canonical event history produces
    the same deterministic states.

Example final G1 widget:

┌─────────────────────────┐
│          😴             │
│                         │
│ Shorter sleep           │
│ 5h 58m                  │
│                         │
│ Strength workout ✓      │
│                         │
│ Updated 4:12 PM         │
└─────────────────────────┘

At this point the health-data platform is considered stable enough for the avatar project.

62. After G1

Only after G1 passes should development move into:

HealthState
      ↓
Avatar Presentation Engine
      ↓
semi-realistic avatar

The avatar team should need only:

HealthState
WidgetState
state provenance
effect severity
confidence

It should not need to understand:

HealthKit
HKQueryAnchor
sleep source resolution
PostgreSQL
HRV formulas
baseline calculations
sync retries

That separation is intentional.

63. Final G1 Engineering Rule

HealthKit tells us what was recorded. Feature calculations tell us what the numbers are. The state engine tells us what those numbers mean inside Homeostat. The presentation mapper decides how to communicate that state. The widget only renders the result.

Do not collapse those layers.