# G2 — Avatar Presentation System

Created: 2026-09-24

## 0. Purpose

G2 replaces the G1 emoji presentation with a semi-realistic, customizable avatar
whose visible traits are driven by `HealthState`:

```
HealthState ──► AvatarState ──► layered avatar render ──► widget / app
                    ▲
AvatarIdentity ─────┘ (user-controlled, never changed by health data)
```

G2 adds a presentation layer. It must not change feature calculations, the state
engine, `HealthState` or the engine/config versions (Whole_project.md §31, §38).

### In scope

- `AvatarState` contract and a pure `HealthState -> AvatarState` mapper.
- Base character, limited customization (`AvatarIdentity`).
- Visual channels: sleep eyes, posture, motion energy, sweat, recent-activity
  state, time-of-day environment, confidence/uncertainty visuals.
- Effect persistence and decay (Whole_project.md §9).
- Static avatar in the small/medium widget; animated avatar in the app.
- Accessibility descriptions for every visible trait.

### Out of scope (later phases)

| Item | Phase |
|---|---|
| Tap-to-explain on body regions, check-ins, subjective expression, soreness map | G3 |
| Muscle-region mapping from exercises, Live Activity avatar | G4 |
| Day replay scrubbing UI | G6 |
| Room objects, cosmetics as rewards, long-term identity | G9 |
| Full 3D | Only after concept validation |

## 1. Entry conditions

Updated 2026-09-30: the original G1 Steps 1–16 and earlier review fixes are
implemented. Independent widget fetching, the latest gap closures and real-device
acceptance remain open. See [Master implementation plan](Master_implementation_plan.md).

- **Avatar implementation begins after recorded G1 acceptance**, including the
  remaining widget/update and recovery gates. This applies to the T1–T13 work;
  the existence of synthetic fixtures is not a waiver of that entry condition.
- The API, shared widget cache and WidgetKit target already exist. Integrate G2
  with their accepted versions rather than treating them as unimplemented.
- Planning and recording T0 design choices may continue. No avatar assets,
  mapper or renderer have been implemented by the completion planning work.
- After G1 acceptance, source/platform expansion and G2 can be separate tracks
  consuming the same HealthState. G2 need not wait for every future provider.

## 2. Decisions to record first (T0)

Record each decision in this file before its dependent task begins.

| # | Question | Proposed default | Why |
|---|---|---|---|
| D1 | Renderer | **Layered 2.5D images composited in SwiftUI** for both widget and app; evaluate Rive for in-app motion in T10 only | WidgetKit renders static snapshots, so one layered renderer must work there anyway. A second runtime is added only if SwiftUI motion is insufficient. |
| D2 | Where the mapper runs | **Backend, in Python**, next to `presentation.py`; shipped inside `WidgetState` | Keeps one tested source of visual meaning and allows golden tests over the synthetic corpus. |
| D3 | Where decay is evaluated | Backend emits `started_at`, `peak_intensity` and `half_life`; **client evaluates intensity at render time** | Widget timeline entries can show sweat fading without a network call. |
| D4 | Decay formula | `intensity(t) = peak · 0.5^((t − started_at) / half_life)`, clamped to 0 below 0.05 | One formula, trivial to mirror in Swift and cover with a shared fixture. |
| D5 | Where `AvatarIdentity` lives | **On device only** (App Group `UserDefaults`/JSON) | The backend does not need appearance data; it composites nothing. |
| D6 | Art source | To decide: commissioned artist, purchased layered kit, or self-made | Largest schedule risk; see §6. |
| D7 | Low confidence | Scale channel intensity by confidence; below `MIN_DISPLAY_CONFIDENCE` (0.5) the channel is neutral; `calibrating`/`insufficient_data` shows a small uncertainty marker, never a negative trait | Principle 3.5 (show uncertainty) and 3.7 (non-judgmental). |

## 3. Visual channel map

Each channel is driven by exactly one `HealthState` domain. Channels combine
independently (Whole_project.md §7); there is no global mood.

| Channel | Source | Values | Decay |
|---|---|---|---|
| `eyes` (eyelid droop, under-eye shade, blink rate) | `sleep.state`, `sleep.severity` | neutral, rested, tired(intensity) | Held until next sleep evaluation |
| `posture` | `recovery.state` | upright, neutral, low | Held until next evaluation |
| `motion_energy` (idle speed, stance) | `movement.state` | low, typical, high | Held until next evaluation |
| `sweat` | `workout.state = active/just_completed` | intensity | Fast: half-life ~20 min |
| `recent_activity` (warm-up glow / outfit context by workout type) | `workout.state`, `workout.type` | none, cardio, strength, mobility | Slow: half-life ~6 h |
| `environment` (lighting) | local time at `effective_at` | morning, day, evening, night | None; derived from time |
| `uncertainty_marker` | calibration + per-domain confidence | none, calibrating, low_confidence | None |

Values and half-lives above are starting points; they live in
`backend/config/homeostat.yaml` under a new `avatar:` section so that tuning
never changes the engine version or config hash of `HealthState`.

## 4. Tasks

Tasks are grouped into three tracks that can run in parallel:
**B** = backend, **A** = art, **I** = iOS.

---

### T0 — Decisions and art brief (all tracks)

- Resolve D1-D7 above and record the outcome in this file.
- Write a one-page art brief: style references, widget-size readability,
  neutral non-judgmental expressions, required layers (§T5).

**Done when:** every decision has a recorded answer and the art brief exists.

---

### T1 — `AvatarState` contract (B)

- Add `backend/app/contracts/avatar_state.py` with `AvatarState`
  (`version = "avatar-state@0.1.0"`), one frozen model per channel in §3, and
  an `Effect` model (`channel`, `peak_intensity`, `started_at`, `half_life`,
  `confidence`, `source_driver_id`) for decaying channels.
- Every channel references the `Driver.id` it came from, so G3 tap-to-explain
  can resolve provenance without new plumbing.
- Reuse existing `_types.py` (`Confidence`, `FiniteFloat`, `Frozen`).
- Export JSON Schema to `packages/contracts/avatar_state.schema.json` for Swift.

**Tests:** contract validation (ranges, timezone-aware datetimes, unknown
fields rejected, schema export stable).
**Done when:** contract tests pass and the schema file is committed.

---

### T2 — `HealthState -> AvatarState` mapper (B)

- Add `backend/app/avatar.py` with a pure `map_avatar_state(state, settings)`.
- Implement the §3 table and the D7 confidence rules.
- Add the `avatar:` config section with validation in `config.py`.

**Tests:**
- Golden `AvatarState` expectations for all 44 synthetic scenarios, added to each
  scenario's `expectations.json` (or a sibling `avatar_expectations.json`).
- Property checks: calibrating/missing/insufficient_data never produce a
  negative trait; each channel changes only when its source domain changes;
  identical inputs give byte-identical output.

**Done when:** all goldens pass and `HealthState` tests are untouched.

---

### T3 — Effect decay (B + I)

- Implement D4 in Python (`app/avatar.py`) and in Swift (T6 package).
- Commit a shared fixture `packages/contracts/fixtures/decay.json` of
  `(effect, t, expected_intensity)` rows; both languages test against it.

**Done when:** Python and Swift pass the same fixture, including the cut-off
and a DST-crossing case.

---

### T4 — `WidgetState` v0.2 carries the avatar (B)

- Bump to `widget-state@0.2.0`; add `avatar: AvatarState`. Keep `presentation`
  text/icon as the fallback and for accessibility.
- Extend `python -m app.pipeline timeline` to print the avatar channels.
- When G1 Step 7 exists, the state endpoint returns the new payload.

**Tests:** existing widget goldens still pass; new payload validates; version
bump is covered.
**Done when:** the synthetic demo timeline shows avatar channels per checkpoint.

---

### T5 — Base character and layer spec (A)

- Produce the neutral base character at widget and app resolutions.
- Define the layer stack and naming, e.g.
  `background/<env>`, `body/<preset>`, `outfit/<id>`, `head/<skin>`,
  `eyes/<state>_<level>`, `undereye/<level>`, `hair/<style>_<color>`,
  `glasses/<id>`, `sweat/<level>`, `glow/<activity>`, `marker/<kind>`.
- Intensity-driven traits use 3 discrete levels (low/mid/high) to keep the asset
  count bounded; the renderer picks the nearest level.
- Deliver as a single asset catalog shared by the app and widget targets.

**Done when:** every §3 channel value and every T8 identity option has an asset,
and a contact sheet shows all combinations for the small widget size.

---

### T6 — Swift models and shared package (I)

- Create a local Swift package `ios/HomeostatKit` used by both targets, holding
  `WidgetState`, `AvatarState`, `AvatarIdentity`, and the decay function.
- Decode the committed JSON fixtures from T1/T4 in unit tests.

**Done when:** app and widget targets both build against the package and every
backend fixture decodes.

---

### T7 — Layered avatar renderer (I)

- `AvatarView(identity:, state:, at: Date)` composes T5 layers in a `ZStack`,
  evaluating decaying effects at `at`.
- No animation in this view; it is the widget-safe renderer.
- Accessibility: one combined VoiceOver label built from active channels
  (e.g. "Avatar looks a little tired; recent strength workout").

**Tests:** snapshot tests for a fixed set of synthetic payloads × 2 identities
at small, medium and app sizes, light and dark.
**Done when:** snapshots are reviewed and committed.

---

### T8 — Identity customization (I)

- Minimal editor: skin tone, hair style, hair color, glasses, outfit, body
  preset.
- Persist `AvatarIdentity` as JSON in the App Group container (D5); reload
  widget timelines on save.
- First-launch default identity so the widget never renders empty.

**Done when:** a changed identity appears in the app and the widget, and health
data never modifies it (test: mapper has no identity input).

---

### T9 — Widget integration (I) — *blocked on G1 Steps 14-16*

- Replace the emoji entry with `AvatarView` in small and medium families.
- Timeline: add entries at decay checkpoints (e.g. +20 min, +1 h, +6 h) so sweat
  and activity glow fade without a network refresh.
- Keep G1 behavior for stale, calibrating and missing-data payloads; show the
  uncertainty marker instead of an empty avatar.

**Done when:** a cached payload renders offline, decay entries advance, and the
text headline still fits beside the avatar.

---

### T10 — In-app motion (I)

- Idle breathing and blinking via `TimelineView`/SwiftUI animation; blink rate
  and idle speed from `eyes` and `motion_energy`.
- Respect Reduce Motion (static pose).
- Spike Rive only if SwiftUI motion is visibly insufficient; record the result
  against D1.

**Done when:** the app avatar animates, and Reduce Motion disables it.

---

### T11 — Demo mode (I + B)

- In-app scenario picker bundling the synthetic demo and selected scenarios'
  `WidgetState` payloads, with a time scrubber over checkpoints.
- Lets a tester see the avatar change without sharing health data
  (Whole_project.md §35).

**Done when:** normal day, short sleep, heavy workout and missing HRV are
visibly distinct and correctly labelled.

---

### T12 — Wellbeing and accessibility review (all)

- Review every asset against principles 3.5 and 3.7: no shaming visuals,
  uncertainty always visible, no body-shape change from data.
- VoiceOver, Dynamic Type for accompanying text, contrast of markers.

**Done when:** a written checklist is completed and issues are fixed.

---

### T13 — G2 acceptance

- All backend goldens and Swift snapshot/fixture tests pass.
- Replay: identical `HealthState` + avatar config gives identical `AvatarState`.
- On a real iPhone: a HealthKit change flows to the widget avatar; sweat decays
  over entries; identity edits appear; offline shows the last valid avatar.

## 5. Dependency order

```
T0 ─┬─► T1 ─► T2 ─► T4 ───────────────┐
    │        └─► T3 (py) ┐            │
    │                    ├─► T6 ─► T7 ─┼─► T9* ─► T13
    ├─► T5 ──────────────┼──────► T7   │
    │                    └─► T3 (swift)│
    │                     T6 ─► T8 ────┤
    │                     T7 ─► T10    │
    │                     T4 + T7 ─► T11
    └──────────────────────────► T12 ──┘
* T9 blocked on G1 Steps 14-16
```

Suggested first slice (unblocked, one vertical path): **T0 → T1 → T2 → T4**,
with **T5** started in parallel since art has the longest lead time.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Art quality/cost stalls everything | Start T5 first; build T7 against placeholder layers with the final naming so art can drop in. |
| Asset explosion from identity × state combinations | Layers, not pre-rendered combinations; 3 intensity levels; limited identity options in G2. |
| Widget memory/size limits with many PNG layers | Measure in T7 snapshots at widget size; use vector PDFs or downscaled assets for the widget. |
| Avatar reads as judgment ("you look bad") | D7 rules, T12 review, subtle intensities by default. |
| G1 widget pipeline slips | T9 is the only blocked task; everything else proceeds on synthetic data. |
