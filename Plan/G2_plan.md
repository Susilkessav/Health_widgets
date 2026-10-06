# G2 — Avatar Presentation System

Created: 2026-09-24. Revised: 2026-10-05 against the G1 code at `0828226`
(on-device calculation, Swift engine port, shared widget cache).

Progress checklist and design steps: [G2_tracker.md](G2_tracker.md).

Current code fixes and verification order: [G2_fix_plan_2026_10_05.md](G2_fix_plan_2026_10_05.md).

The follow-up code fixes are implemented; the linked plan records automated results separately from remaining physical acceptance. Final asset requirements: [G2_art_brief.md](G2_art_brief.md).

## 0. Purpose

G2 replaces the G1 emoji presentation with a semi-realistic, customizable avatar
whose visible traits are driven by `HealthState`:

```
HealthKit → LocalStore → Swift engine → HealthState ──► AvatarState ──► WidgetState v0.2
                                                             │               │
                                     AvatarIdentity ─────────┴──► AvatarView (app + widget)
                                     (user-controlled, never changed by health data)
```

G2 adds a presentation layer only. It must not change feature calculations, the
state engine, `HealthState`, the engine version or `settings_sha256`
(Whole_project.md §31, §38).

### In scope

- `AvatarState` contract and a pure `HealthState -> AvatarState` mapper.
- Base character and limited customization (`AvatarIdentity`).
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
| Syncing identity across devices/platforms | Later, with the server |
| Full 3D | Only after concept validation |

## 1. G1 status this plan builds on (2026-10-05)

| G1 part | State | What G2 uses |
|---|---|---|
| Python engine + presentation (`backend/app/engine.py`, `presentation.py`) | Done; reference implementation | Add the reference avatar mapper beside `presentation.py` |
| Swift engine port (`ios/HomeostatCore/Sources/HomeostatCore/Engine/`) | Done; 170 checkpoints match `engine_parity.json` | Add the on-device avatar mapper beside `mapWidgetState` |
| Parity fixture (`backend/tests/engine/test_parity_fixture.py` → `ios/.../Fixtures/engine_parity.json`) | Done; already holds `widget_state` per checkpoint | Avatar goldens come from this fixture; no new golden format |
| On-device calculation (`LocalCalculation.swift`) | Done; result stored as `local_state` and written to the widget cache | Avatar is computed in the same call |
| Shared widget cache (`HomeostatShared/SharedWidgetStore.swift`, `WidgetPolicy.swift`) | Done | Version support, reload rules and timeline dates are extended |
| Widget (`HomeostatWidget.swift`, small/medium) | Done; renders icon + text | The emoji is replaced by `AvatarView` |
| Explanation screen (`ExplanationView.swift`) | Done | Unchanged in G2; body-region tap is G3 |
| Device replay check (`backend/app/device_check.py`, `DeviceReplayTests.swift`) | Added 2026-10-05 | Also compares `avatar_state` |
| **Real-iPhone G1 acceptance** | **Open** | Entry gate below |
| Backend API/server path | Implemented, optional, "later" (On_device_plan.md) | Serves `widget-state@0.2.0` unchanged in shape; nothing new is required |

Account constraints (2026-09-30 decisions): free Personal Team, no TestFlight,
7-day re-signing. G2 needs no paid capability.

## 2. Entry conditions

- **2026-10-05: the user chose to build G2 now with placeholder art**, ahead of
  G1 real-iPhone acceptance. Final avatar and environment art come later (T5).
  G1 acceptance is still required before G2 acceptance (T12).
- Original rule, now waived: avatar implementation (T1 onward) begins after G1
  real-iPhone acceptance is recorded (Master_implementation_plan.md §8).
- T0 (decisions, art brief) and the art work in T5 have no code risk and may
  start now, since art has the longest lead time.
- G2 and source/platform expansion are separate tracks consuming the same
  `HealthState`.

## 3. Decisions (T0)

Record the outcome of each decision in this table before its dependent task begins.

| # | Question | Proposed default | Why |
|---|---|---|---|
| D1 | Renderer | **Layered 2.5D images composited in SwiftUI** for widget and app; evaluate Rive for in-app motion in T9 only. Prototype: shapes drawn in a Canvas (§4b) | WidgetKit renders static snapshots, so a layered renderer is required anyway. |
| D2 | Where the mapper runs | **On the phone (Swift)**, with a **Python reference** checked by `engine_parity.json` | Matches the G1 rule: Python stays the reference, Swift must match the parity fixture. All 170 checkpoints become avatar goldens for free. |
| D3 | Where decay is evaluated | The mapper emits `started_at`, `peak` and `half_life_minutes`; **the Swift renderer evaluates intensity at the render time** | Widget timeline entries can fade sweat with no recalculation. Decay is display math, so it needs no Python twin. |
| D4 | Decay formula | `intensity(t) = peak · 0.5^((t − started_at) / half_life)`, 0 below 0.05 | One formula, one Swift unit test. |
| D5 | Where `AvatarIdentity` lives | **App Group JSON file next to the widget cache**, separate from `WidgetCache` | Identity is not health data, never goes to the server, and must survive recalculation and scope resets. |
| D6 | Art source | **Decided 2026-10-05: keep the code-drawn placeholder (`AvatarPainter`) for now**; final art replaces it later via §4b | Unblocks device acceptance of the prototype; art can change without touching the contract, widget or tests. |
| D7 | Low confidence | Below `minDisplayConfidence` (0.5) a channel is neutral. Only the eyes and effect peaks scale with confidence; posture, motion and activity are categorical (exact rules in §4). `calibrating`/`missing`/`insufficient_data` show the uncertainty marker, never a negative trait | Principles 3.5 (show uncertainty) and 3.7 (non-judgmental). Reuses the existing presentation threshold. |
| D9 | Framing | **Full body**, drawn once; each surface crops it: small widget = waist up, medium widget and app = full body. **Decided 2026-10-05.** | Supports posture, workout context, G4 body regions and in-app motion; the small-widget crop keeps the eyes readable. |
| D10 | How the body changes | **Decided 2026-10-05: situational poses**, derived at render time from what the avatar already shows (no contract field), highest priority first: workout just finished (sweat) → catching breath, hands on hips; glow > 0.4 → stretching, one arm up; more active → walking; less active → still; otherwise standing. Posture (upright/neutral/low) still raises or lowers the head and shoulders in every pose. A redacted avatar always stands. `AvatarPose` in `AvatarView.swift` | One body that does what the day suggests reads more naturally than three static stances; poses come from existing channels, so parity and the redaction rule hold. |
| D8 | Where tuning values live | **Constants in the mapper code** (as `presentation.py` does), not `homeostat.yaml` | Any `homeostat.yaml` change alters `settings_sha256` and the replay identity of `HealthState`. |

## 4. Visual channel map

Each channel is driven by exactly one `HealthState` domain. Channels combine
independently (Whole_project.md §7); there is no global mood.

| Channel | Source | Values | Decay |
|---|---|---|---|
| `eyes` (eyelid droop, under-eye shade, blink rate) | `sleep.state`, `sleep.severity` | neutral, rested, tired(intensity) | Held until the next calculation |
| `posture` (whole-body pose, D10) | `recovery.state` | upright, neutral, low | Held |
| `motion_energy` (idle speed, stance) | `movement.state` | low, typical, high | Held |
| `sweat` | `workout.state = active/just_completed` | intensity | Half-life 20 min; gone in 86 min, inside the 2 h window |
| `recent_activity` (glow/outfit context by workout type) | `workout.state`, `workout.type` | none, cardio, strength, mobility | Half-life 160 min; gone in 11.5 h, inside the 12 h window |
| `environment` (lighting) | local time at render (not stored; see §4a) | morning, day, evening, night | None |
| `uncertainty_marker` | calibration + per-domain confidence | none, calibrating, low_confidence | None |

### Exact mapping rules (implemented 2026-10-05)

"Shown" means the domain's state matches and its confidence is ≥ 0.5 (inclusive,
the same `MIN_DISPLAY_CONFIDENCE` as the widget text). Anything not shown is the
neutral value. Tests: `tests/engine/test_presentation.py` (Python) and parity on
all 170 checkpoints (Swift).

| Channel | Rule | Intensity |
|---|---|---|
| `eyes` | `tired` if sleep `below_baseline` shown; `rested` if `above_baseline` shown; else `neutral` | `severity × sleep.confidence` (severity = min(\|Δ minutes\| / full-severity minutes, 1)); 0 when neutral |
| `posture` | `low` if recovery `strained` shown; `upright` if `favorable` shown; else `neutral` | None (categorical) |
| `motion` | `low` if movement `behind_usual` shown; `high` if `ahead_of_usual` shown; else `typical` | None |
| `activity` | Workout shown and `active`/`just_completed`/`recent_workout`: group of a known type (strength, cardio, mobility); unknown type → `none` | None |
| `sweat` | Workout shown and `active`/`just_completed`, with a last-workout time | peak = workout confidence; starts at workout end; half-life 20 min |
| `glow` | Same as activity, and activity ≠ `none` | peak = workout confidence; half-life 160 min |
| `uncertainty` | `calibrating` while calibration isn't ready; else `low_confidence` if sleep, recovery or movement is below 0.5 or `missing`; else `none` | None |
| Effects | Drawn while `peak · 0.5^(elapsed / half-life)` ≥ 0.05. Zero before the start time, except up to 5 minutes early counts as started (clock differences; decided 2026-10-05) | — |
| Evidence | Driver ids exactly for channels that differ from neutral | — |
| `missing_inputs` | Sleep, HRV, resting HR, movement with no reading today, in that order. Named in VoiceOver and the explanation screen, never drawn; the marker rule above is unchanged (decided 2026-10-05) | — |
| Privacy | When iOS redacts private content (Lock Screen, StandBy), the widget draws `AvatarState()` (identity and lighting only) and the headline "Homeostat" (decided 2026-10-05) | — |

Recovery confidence is the lowest input confidence × inputs used / 3, so three
inputs at 0.5 show; two at 0.75 also show (0.5).

Workout types map to activity groups using the same known-label list as
`WORKOUT_LABELS` / `workoutLabel`. An unknown type becomes `none`, so an
unvetted provider string never selects art.

Every channel that differs from neutral lists the `Driver.id`s behind it
(`AvatarState.evidence`, see §4a), so G3 tap-to-explain can resolve provenance
with no new plumbing.

## 4a. Implementation record (2026-10-05)

Built with placeholder art: T1–T4 and T6–T10. T0 decisions and the art brief are complete. Open: T5 replacement artwork, T11 review and T12 device acceptance. Follow-up fixes and current checks are recorded in G2_fix_plan_2026_10_05.md.

| Area | Where |
|---|---|
| Contract | `backend/app/contracts/avatar_state.py`; `widget-state@0.2.0` adds `avatar` |
| Reference mapper | `map_avatar_state` in `backend/app/presentation.py` (`presentation@0.2.0`) |
| On-device mapper | `mapAvatarState` in `HomeostatCore/Engine/StateEngine.swift` |
| Swift models, fading, lighting, identity store | `HomeostatShared/AvatarState.swift` |
| Placeholder renderer + VoiceOver text | `HomeostatShared/AvatarView.swift` |
| Widget | `HomeostatWidget.swift`: waist-up avatar (small), full body (medium) |
| App | `Views/AvatarViews.swift`: live avatar, editor, demo; `DebugView` avatar section |

Changes from the plan above, decided while building:

- **Lighting is not in `AvatarState`.** The renderer derives it from the time it
  draws, like fading, so widget timeline entries change it without a
  recalculation and no timezone is needed in the contract. The widget timeline
  adds entries at 05:00, 11:00, 17:00 and 21:00 local time, and at each fading
  half-life step until midnight.
- **The mapper lives in `presentation.py`** next to `map_widget_state`, not a new
  `app/avatar.py` (that module would import `presentation.py` circularly).
- **No `HomeostatAvatar` target or asset catalog yet.** The placeholder is drawn
  with SwiftUI shapes inside `HomeostatShared`, which both targets already link,
  so no Xcode project change was needed. Final art replaces `AvatarPainter`.
- **Missing data also shows the uncertainty marker** (not only low confidence),
  as D7 intends.
- **Demo mode uses scenario presets** with time-of-day and minutes-since-workout
  sliders, instead of bundling the parity fixture.
- Glow requires a known activity type. An unknown workout type still sweats but
  gets no activity glow.

Verification: backend 3,563 passed (the 163 database tests need PostgreSQL,
which was not running); Swift 104 passed, including avatar parity on all 170
checkpoints; app and widget simulator build succeeded; the app was run in an
iOS 27 simulator (on-device result → avatar, editor, demo). Not yet seen: the
widget on a Home Screen. (Corrected: the simulator build does have the App
Group; the identity file and widget cache are written there, so the widget can
be checked in the simulator by adding it to the Home Screen.)

Review fixes, 2026-10-05 (G2_review_2026_10_05.md items 1, 3 and 16): cached
avatars are checked against the contract (versions, ranges, effect rules,
half-life 1 minute–1 week, now enforced in Python too) and an invalid one falls
back to `.unknown` while the text still shows; the widget timeline skips unusable
effects, so it can't loop forever; an appearance change shows only after it is
saved, with an on-screen note if saving fails. Swift 108 tests and backend
3,565 tests pass.

Decisions, 2026-10-05 (review items 4–6):

- **Old results.** Same day, over 90 minutes old: keep the traits, dimmed.
  Earlier day: neutral eyes, posture and movement; workout effects keep fading
  by the clock (`AvatarState.withoutDailyTraits`, `WidgetPolicy.avatar`; app
  and widget both use it).
- **Effects end inside their workout window.** Sweat (20 min half-life) is gone
  before 2 h and glow (160 min, was 360) before 12 h, so a cached avatar and a
  fresh calculation always agree. A Python test checks both against the settings.
- **Evidence.** `AvatarState.evidence` lists driver ids for each channel that
  differs from neutral: eyes `sleep_duration`, posture the recovery inputs that
  counted, motion `steps_so_far`, workout `last_workout`. Both languages require
  evidence exactly for non-neutral channels; parity covers it.

Swift 109 tests and backend 3,575 tests pass.

Demo and widget, 2026-10-05 (review items 7 and 17):

- **Demo mode uses real engine output.** `backend/tests/engine/test_demo_states.py`
  runs 15 synthetic checkpoints through the pipeline and writes
  `ios/Homeostat/Homeostat/Demo/demo_states.json` (regenerate with
  `UPDATE_WIRE_FIXTURES=1`). The demo shows each result's avatar and widget
  text, with an "hours later" slider for fading, lighting and the earlier-day
  rule. The hand-made states remain as a "Playground" for art review.
- **Reduce Motion no longer freezes time.** The still avatar redraws once a
  minute, so lighting and fading continue.
- **Widget seen on the simulator Home Screen** (medium): avatar, identity,
  marker and text from the shared App Group. The small widget is not yet seen.
- Found: the uncertainty marker overlaps the sun/moon in the top-right corner
  (art fix), and "Missing HRV" shows no marker because recovery still has sleep
  and resting HR (review item 10, open).

Swift 110 tests and backend 3,576 tests pass.

## 4b. Prototype renderer and the final-art path

The prototype (`AvatarPainter` in `HomeostatShared/AvatarView.swift`) draws
every layer with SwiftUI shapes in a `Canvas`. The planned final renderer
composites image layers (D1, T5). Only the painter changes:

1. Art arrives as the T5 layer set (names as in T5), one image per layer value,
   on the shared 100 × 200 avatar canvas, with a head anchor per pose (D10).
2. Add an asset catalog to the package (a `HomeostatAvatar` target, or resources
   in `HomeostatShared`), then replace `AvatarPainter.drawFigure`/`drawFace`/
   `drawHair` with image draws in the same order. Keep `drawEnvironment` or swap
   it for the background images.
3. `AvatarView`'s inputs (identity, avatar, time, zone, framing, breath, blink),
   `AvatarFraming`, the lighting wash, the marker overlay and the VoiceOver text
   stay the same, so the widget, app and tests are unchanged.
4. Re-render the contact sheet and widget snapshots, and measure widget memory
   with the real images.

## 4c. Replay across presentation versions

`presentation@0.2.0` (G2) changes the stored `widget_state`. Backend replay
(`app/replay.py`) compares a stored run only when its feature, engine and
presentation versions all equal the running code's; an older run is reported
`not_reproducible` with the recorded versions, never rebuilt with newer
presentation code. HealthState replay identity is unaffected, since G2 changes
no feature or engine version and no `settings_sha256`. On the phone, old caches
still render: `widget-state@0.1.x` has no avatar and draws the neutral
`.unknown` avatar, and an invalid or newer avatar does the same.

## 4d. T11 review of the placeholder art (2026-10-06)

Reviewed against principles 3.5 (show uncertainty) and 3.7 (non-judgmental), on
the contact sheets and the 24 snapshot references. "Device" items need the T12
iPhone run; nothing here marks T11 accepted.

| Check | Result |
|---|---|
| No shaming or illness cues: tired = heavier lids and a flat (never sad) mouth; low posture = lower, narrower shoulders and a slight tilt | Pass (inspection) |
| Body silhouette never changes with health data; only the chosen slim/broad body | Pass (code: health has no input to body width) |
| Uncertainty visible: hourglass while calibrating, question mark for low confidence or missing data; marker top-left, clear of the sun/moon | Pass (snapshots) |
| Missing inputs explained in words, not drawn (decision 10) | Pass (tests) |
| Privacy: redacted widget is a neutral standing figure, no effects or marker | Pass (tests, snapshots) |
| VoiceOver text names what is drawn and the recorded cause; no feeling words | Pass (tests: banned-word check) |
| Swatches: 44 pt targets, spoken names | Pass (code); Device: confirm with VoiceOver |
| Eyes readable for every skin tone, with and without glasses | Pass (snapshots, deepest skin + glasses) |
| Night contrast | Pass (lighter night wash; night snapshots) |
| Dark mode: dimmed backdrop | Pass (snapshots); Device: Home Screen |
| Tinted Home Screen: one-colour figure, eyes/glasses/mouth as cutouts, glow as a dashed outline, marker symbol without a disc | Pass (simulated sheet, snapshots); Device: real tinted and clear Home Screens |
| Increased contrast: outlines, eye whites, thicker glasses, solid marker, no wash | Pass (snapshots); Device: Settings → Accessibility → Display |
| Reduce Motion: still pose, lighting and fading continue (minute clock) | Pass (code); Device |
| Dynamic Type for the widget/app text | Device |
| Poses: catching breath, stretching, walking, still (hands together in front), standing; posture visible in each | Pass (contact sheet) |

## 5. Tasks

Tracks: **P** = Python reference, **S** = Swift core (`HomeostatCore`/`HomeostatShared`),
**A** = art, **U** = iOS UI (app + widget).

---

### T0 — Decisions and art brief (all) — *can start now*

- Resolve D1–D10 and record the outcomes in §3. All decided as of 2026-10-05
  (D6 placeholder art for now; D10 situational poses).
- One-page art brief: style references, readability at small-widget size,
  neutral non-judgmental expressions, the layer list from T5.

**Done when:** every decision is recorded and the brief exists.

---

### T1 — `AvatarState` contract, Python (P)

- `backend/app/contracts/avatar_state.py`: `AvatarState`
  (`version = "avatar-state@0.1.0"`), one frozen model per §4 channel, and
  `Effect` (`kind`, `peak`, `started_at`, `half_life_minutes`) for decaying channels.
  Per-channel driver IDs live in `AvatarState.evidence`.
- Reuse `_types.py` (`Frozen`, `Confidence`, `FiniteFloat`, `NonEmptyStr`).
- `WidgetState` → `widget-state@0.2.0` with `avatar: AvatarState`. Keep
  `presentation` as the text line, the fallback and the VoiceOver source.

**Tests:** extend `tests/contracts/test_contracts.py` (ranges, aware datetimes,
unknown fields rejected, version).

---

### T2 — Reference mapper, Python (P)

- `backend/app/presentation.py`: pure `map_avatar_state(state: HealthState) -> AvatarState`
  implementing §4 and D7. Constants at the top of the file (D8).
- Call it from `map_widget_state` so `run_checkpoint` and the API emit v0.2.
- Regenerate `engine_parity.json` and `widget_states.jsonl`
  (`UPDATE_WIRE_FIXTURES=1`); `avatar_state` now sits inside every
  checkpoint's `widget_state`.

**Tests:** targeted cases in `tests/engine/test_presentation.py`:
calibrating/missing/insufficient_data never yield a negative trait; each
channel changes only with its source domain; unknown workout type → `none`.
Existing `HealthState` goldens are unchanged.
**Done when:** backend suite passes with regenerated fixtures and
`settings_sha256` is unchanged.

---

### T3 — On-device mapper and decay, Swift (S)

- `HomeostatShared/AvatarState.swift`: Codable `AvatarState` and `Effect`,
  plus `Effect.intensity(at:)` (D4). It lives in HomeostatShared because the
  widget extension needs it and must not link GRDB.
- Add `avatar` to `WidgetState` in `HomeostatShared/WidgetState.swift`; accept
  `widget-state@0.2.0` in `SharedWidgetStore.supported(_:)`; keep 0.1.0
  readable so an existing cache still renders until the next calculation.
- `HomeostatCore/Engine/`: `mapAvatarState(_:)`, called from `mapWidgetState`.
  `LocalCalculation` needs no change beyond that.

**Tests:** `EngineParityTests` now compares `avatar_state` for all 170
checkpoints; one decay unit test (peak, half-life, cutoff, before `started_at`);
`SharedWidgetTests` decodes 0.1.0 and 0.2.0 caches.
**Done when:** parity passes and an old cache still reads.

---

### T4 — Device check covers the avatar (P)

- No code change: `app.device_check` already compares the whole `health_state`
  and `widget_state` per checkpoint, so `avatar_state` is covered once T2/T3 land.

**Done when:** a phone database copy compares clean, including avatar fields.

---

### T5 — Base character and layer spec (A) — *can start now*

- Neutral full-body base character (D9) on a 1024×2048 canvas.
- Layer stack and naming (`<pose>` = one of the `AvatarPose` cases, D10): `background/<env>`, `body/<pose>`,
  `outfit/<id>_<pose>`, `head/<skin>`, `eyes/<state>_<level>`, `undereye/<level>`,
  `hair/<style>_<color>`, `glasses/<id>`, `sweat/<level>`, `glow/<activity>`,
  `marker/<kind>`.
- Intensity traits use 3 discrete levels; the renderer picks the nearest.
- Each pose records a head anchor (x, y, tilt) so the head stack (head, eyes,
  under-eye, hair, glasses, sweat) is drawn once and placed per pose.
- Each surface records a crop rectangle: small widget = waist up, medium and
  app = full body.
- Placeholder layers with final names first, so T6 is not blocked on final art.

**Done when:** every §4 value and every T7 identity option has an asset and a
contact sheet at small-widget size has been reviewed.

---

### T6 — `AvatarView` renderer (S + U)

- New target `HomeostatAvatar` in `ios/HomeostatCore/Package.swift`
  (SwiftUI + asset catalog resource), depending on `HomeostatShared`; linked
  by the app and the widget extension.
- `AvatarView(identity:, avatar:, at: Date, framing:)` composes layers in a
  `ZStack`, places the head stack at the pose's anchor, applies the surface
  crop (`.waistUp` / `.fullBody`) and evaluates effects at `at`. No animation
  here (widget-safe).
- One combined accessibility label from active channels
  (e.g. "Avatar looks a little tired; recent strength workout").

**Tests:** snapshot or image-hash tests for a few parity checkpoints ×
2 identities × small/medium/app sizes, light and dark.
**Done when:** snapshots are reviewed and committed, and the widget extension
stays under its memory limit in Instruments.

---

### T7 — Identity customization (U + S)

- `AvatarIdentity` (Codable) in HomeostatShared; read/write a JSON file in the
  App Group container with an atomic write (same pattern as the widget cache).
- Minimal editor in the app: skin tone, hair style, hair color, glasses,
  outfit, body preset. Default identity on first launch; reload widget
  timelines on save.

**Done when:** an edit shows in the app and widget, and the mapper's signature
takes no identity, so health data cannot change it.

---

### T8 — Widget integration (U)

- Replace `presentation.icon` with `AvatarView` in small and medium; keep the
  headline/detail/freshness lines.
- `WidgetPolicy.timelineDates`: add entries at decay points (+20 min, +1 h,
  +6 h after `started_at`) so sweat and glow fade without a recalculation.
- `SharedWidgetStore.meaningful`: a changed avatar counts as meaningful.
- Stale, calibrating and missing-data states show the neutral avatar plus the
  uncertainty marker, never an empty frame.

**Done when:** a cached result renders offline, decay entries advance, and the
existing `SharedWidgetTests` policy cases still pass.

---

### T9 — In-app motion (U)

- Idle breathing and blinking via `TimelineView`; blink rate and idle speed
  from `eyes` and `motion_energy`. Reduce Motion → static pose.
- Spike Rive only if SwiftUI motion is visibly insufficient; record it under D1.

**Done when:** the app avatar animates and Reduce Motion stops it.

---

### T10 — Demo mode (U)

- Debug-screen scenario picker that bundles a trimmed copy of the parity
  fixture's `widget_state` entries and scrubs checkpoints. No new data
  generation is needed.

**Done when:** normal day, short sleep, heavy workout and missing HRV are
visibly distinct and correctly labelled.

---

### T11 — Wellbeing and accessibility review (all)

- Review every asset against principles 3.5 and 3.7: no shaming visuals,
  uncertainty always visible, no body-shape change from data.
- VoiceOver, Dynamic Type for the text lines, contrast of markers.

**Done when:** a written checklist is complete and issues are fixed.

---

### T12 — G2 acceptance (all)

G2 has two finish lines: **prototype complete** (placeholder art, every check
below except the final-art items) and **G2 accepted** (final art, T11 done, and
G1 iPhone acceptance recorded first). Record each result with the date, build
(git commit), device and iOS version in the tracker log.

**1. Automated (CI, or locally):**

```bash
cd backend && uv run pytest -q          # needs `docker compose up -d db`
cd ios/HomeostatCore && swift test       # includes parity on 170 checkpoints
cd ios/Homeostat && xcodebuild -project Homeostat.xcodeproj -scheme Homeostat \
  -destination 'generic/platform=iOS Simulator' build
```

Pass: zero failures; `settings_sha256` and HealthState fixtures unchanged from G1
(regenerating `engine_parity.json` changes only `widget_state`).

**2. Phone database replay (T4):** copy the app's `homeostat-*.sqlite` from the
phone (Xcode → Devices → download container), then:

```bash
cd backend && uv run python -m app.device_check STORE.sqlite --out python.json
cd ios/HomeostatCore && HOMEOSTAT_DEVICE_DB=STORE.sqlite HOMEOSTAT_DEVICE_CHECKPOINTS=python.json \
  HOMEOSTAT_DEVICE_OUT=swift.json swift test --filter DeviceReplayTests
cd backend && uv run python -m app.device_check STORE.sqlite --out python.json --swift swift.json
```

Pass: every checkpoint identical, including `widget_state.avatar`.

**3. On the iPhone (signed build, Personal Team):**

- [ ] App Group works on the device: an appearance edit appears in the widget.
- [ ] A HealthKit change reaches the widget avatar without opening the app,
      within iOS's refresh limits.
- [ ] Sweat fades across widget entries after a workout; glow is gone by 12 h.
- [ ] An earlier day's result shows neutral traits; same-day old results dim.
- [ ] Offline (airplane mode): the last valid avatar and text stay.
- [ ] A G1 `0.1.0` cache upgrades: neutral avatar until the next calculation.
- [ ] Small and medium widgets readable at actual size, light and dark.
- [ ] VoiceOver reads the avatar description, then the text, in that order.
- [ ] Reduce Motion: still avatar, lighting still changes over the day.
- [ ] Observe for 24–48 hours alongside the G1 window.

**4. Budgets (proposed, not yet measured; adjust after the first device run):**
widget extension peak memory under 25 MB (iOS stops widgets near 30 MB; measure
in Instruments with final art); app avatar animation under 10% CPU on the device while visible;
an on-device calculation including the avatar under 100 ms.

## 6. Dependency order

```
                ┌─► T3 (Swift mapper) ─┬─► T6 (renderer) ─┬─► T8 (widget) ─┐
T1 ─► T2 ───────┤                      │                  ├─► T9 (motion)  │
(contract) (Py) └──────────────────────┼─► T4 (needs T2+T3)└─► T10 (demo)  │
                                       └─► T7 (identity) ───► T8           ├─► Prototype complete
T0 (decisions) ─► T5 (final art) ─► T6 painter swap (§4b) ─► T11 ─────────┤
G1 iPhone acceptance ──────────────────────────────────────────────────────┴─► T12 G2 accepted
```

Status 2026-10-05: T0 decisions/brief, T1–T4 and T6–T10 are complete for the prototype. Existing T4 phone-database evidence is in the tracker. T5 final artwork, T11 review and T12 device acceptance remain open.

## 7. Risks

| Risk | Mitigation |
|---|---|
| Art quality/cost stalls everything | Start T5 now; build T6 on placeholder layers with final names. |
| Asset count from identity × state combinations | Layers, not pre-rendered combinations; 3 intensity levels; limited identity options. |
| Widget extension memory limit with many layers | Measure in T6; downscaled or vector assets for widget sizes. |
| Swift and Python mappers drift | Parity fixture covers every checkpoint; CI runs both suites. |
| Cache version bump breaks a live widget | T3 keeps 0.1.0 readable; T12 checks the upgrade on device. |
| Avatar reads as judgment | D7, T11 review, subtle default intensities. |
| G1 acceptance slips | Only T0 and T5 proceed; no avatar code is built on an unaccepted pipeline. |
