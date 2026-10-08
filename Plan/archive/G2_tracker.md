# G2 tracker — Avatar Presentation System

Progress checklist for [G2_plan.md](../specs/G2_plan.md), which holds the full spec.
Tick boxes as work lands and add a line to the log at the bottom.

Follow-up fixes and acceptance evidence: [G2_fix_plan_2026_10_05.md](G2_fix_plan_2026_10_05.md). Code fixes are implemented; physical acceptance boxes below have not been advanced.

**Status:** Built with placeholder art (2026-10-05) · **Gate:** waived for build; G1 acceptance still needed before T12
**Can start now:** Design (D-phase), T0, T5

---

## Gate

- [ ] G1 real-iPhone acceptance recorded in Step_14_16_plan.md §12 (build gate waived 2026-10-05; still needed for T12). G1 closes on paths 1–2, not widget self-refresh (D-B, 2026-10-06)

---

## D — Design (can start now)

All design work lives in one Figma file. Every layer shares one canvas size and
origin so layers line up without code offsets.

### D1. Concept
- [ ] Mood board: 5–10 references (polished game/cartoon, not photoreal)
- [x] Choose framing: **full body**, cropped waist-up in the small widget (D9)
- [x] Write the art brief (T0): [G2_art_brief.md](../specs/G2_art_brief.md); replacement assets still pending

### D2. Avatar layers (placeholder first, final art later)
Canvas: 1024×2048 (full body), transparent, shared origin. Names must match the plan (T5).

- [ ] `body/<pose>` for each `AvatarPose` (catching breath, stretching, walking, still, standing; D10), with a head anchor per pose; posture shifts the head and shoulders
- [ ] `head/<skin>` ×5 skin tones (match current identity)
- [ ] `hair/<style>` ×3 (color = tint in code)
- [ ] `outfit/<id>_<pose>` ×3 outfits × 5 situational poses
- [ ] `glasses/<id>` ×1
- [ ] `eyes/rested`, `eyes/neutral`, `eyes/tired_low|mid|high`
- [ ] `undereye/low|high`
- [ ] `sweat/low|high`
- [ ] `glow/cardio|strength|mobility`
- [ ] `marker/calibrating|low_confidence`
- [ ] Avatar built as a Figma component with variants

### D3. Environment
Draw the avatar once in neutral light; code adds a color wash per time of day.

- [ ] `background/morning|day|evening|night` (gradient + 1–2 soft shapes)
- [ ] 4 wash colors picked (one per time of day)
- [ ] Environment sits behind the avatar only; text area stays plain
- [ ] Rule recorded: environment follows time, text colour follows light/dark mode

### D4. Widget layouts
Start from Apple's iOS design kit for Figma (widget frames and safe margins).

- [ ] Small (~158×158 pt): waist-up crop in the top ~60%, headline ≤2 lines
- [ ] Medium (~338×158 pt): full body left, headline/detail/freshness right
- [ ] App: full body with room for motion
- [ ] Tinted-mode version (simplified/high-contrast avatar still readable)

### D5. Scenario grid (becomes the T6 snapshot spec)

| Scenario | Light | Dark | Tinted |
|---|---|---|---|
| Normal day, morning | [ ] | [ ] | [ ] |
| Short sleep, morning | [ ] | [ ] | [ ] |
| Just worked out, evening | [ ] | [ ] | [ ] |
| Calibrating | [ ] | [ ] | [ ] |
| Stale ("Open Homeostat to update") | [ ] | [ ] | [ ] |

- [ ] Checked at 100% on a real iPhone (Figma Mirror or exported image)
- [ ] Tired eyes readable at widget size

### D6. Export
- [ ] Each layer exported as transparent PNG @2x/@3x or vector PDF
- [ ] Imported into the `HomeostatAvatar` asset catalog (T6)

---

## Decisions (T0) — record outcome in G2_plan.md §3

- [x] D1 Renderer: layered SwiftUI; code-drawn prototype, replacement art pending
- [x] D2 Mapper: Swift on device, Python reference + parity
- [x] D3 Decay evaluated in Swift at render time
- [x] D4 Decay formula (half-life, 0.05 cut-off)
- [x] D5 Identity stored as App Group JSON, device only
- [x] D6 Art source: code-drawn placeholder for now; final art later (decided 2026-10-05)
- [x] D7 Low-confidence rule (neutral below 0.5, uncertainty marker)
- [x] D8 Tuning constants in code, not `homeostat.yaml`
- [x] D9 Framing: full body, cropped per surface
- [x] D10 Situational poses: catching breath, stretching, walking, still, standing (decided 2026-10-05)

---

## Build tasks

| Task | Track | Needs | Done |
|---|---|---|---|
| T0 Decisions + art brief | all | — | [x] |
| T1 `AvatarState` contract + `widget-state@0.2.0` (Python) | P | Gate | [x] |
| T2 Reference mapper + regenerate parity fixtures | P | T1 | [x] |
| T3 Swift mapper, decay, 0.1/0.2 cache support | S | T2 | [x] |
| T4 `device_check` covers avatar (no code; verify on a phone database) | P | T2, T3 | [x] |
| T5 Base character + layer spec | A | T0 | [ ] |
| T6 `AvatarView` (placeholder shapes in HomeostatShared) + render tests | S+U | T3 | [x] |
| T7 Identity editor + App Group storage | U+S | T3 | [x] |
| T8 Widget integration + decay/lighting timeline entries (check on a Home Screen) | U | T6, T7 | [x] |
| T9 In-app motion + Reduce Motion | U | T6 | [x] |
| T10 Demo mode (real engine results + playground) | U | T6 | [x] |
| T11 Wellbeing + accessibility review | all | T8 | [ ] |
| T12 G2 acceptance on iPhone | all | all | [ ] |

### Acceptance (T12)
- [ ] Backend suite, Swift suite and parity pass
- [ ] `settings_sha256` unchanged
- [ ] `device_check` on a phone database copy matches, including `avatar_state`
- [ ] HealthKit change reaches the widget avatar without opening the app
- [ ] Sweat fades across widget timeline entries
- [ ] Identity edits show in app and widget
- [ ] Offline shows the last valid avatar
- [ ] G1 0.1.0 cache upgrades cleanly

---

## Open questions


## Log

| Date | Change |
|---|---|
| 2026-10-05 | Tracker created; G2 plan revised for on-device calculation |
| 2026-10-05 | Framing decided: full body, waist-up crop in small widget (D9); 3 poses proposed (D10) |
| 2026-10-05 | Built T1–T3, T6–T10 with placeholder art; see G2_plan.md §4a. Next: final art (D-phase, T5), widget check on a Home Screen, T11, T12 |
| 2026-10-05 | Review fixes: cached-avatar validation, timeline guard, save-before-show for identity (G2_plan.md §4a) |
| 2026-10-05 | Decided: old results split by age, effects fade inside their workout window (glow half-life 160 min), evidence driver ids per channel (G2_plan.md §4a) |
| 2026-10-05 | Demo uses real engine results; Reduce Motion keeps a minute clock; medium widget seen on simulator Home Screen. Open: small widget, marker/sun overlap, review item 10 |
| 2026-10-05 | Review follow-ups: exact rules + threshold tests, VoiceOver wording and 44 pt named swatches, identity file versioning, CI workflow, renderer migration path, replay policy, dependency diagram, repeatable T12 checklist (G2_plan.md §4, §4b, §4c, T12, §6) |
| 2026-10-05 | Decided and built: missing inputs named not drawn (item 10); effects zero before start with 5 min grace (11); neutral avatar and "Homeostat" headline when redacted (18) |
| 2026-10-05 | D6: placeholder art for now. D10: situational poses (AvatarPose), posture still shifts head and shoulders |
| 2026-10-05 | Pre-commit verification: backend 3,760 passed with PostgreSQL (server_wire.json regenerated for the avatar); Swift 114 passed; signed Debug build on iPhone 16 Pro Max (Personal Team), App Group in app and widget, HealthKit in app; T4: phone database (1,674 events, 46 checkpoints) stored result = Python, Swift = Python on all 46, avatar included |

| 2026-10-05 | Follow-up code fixes: local-only refresh/lifecycle, rollover, registered/scoped widget links, cache preservation, exact effect/pose transitions, replay backup/empty handling, immutable settings, stream limits and fail-closed SDK selection. Verification: 3,769 Python tests including PostgreSQL; 122 Swift checks; simulator DB 286 events / 41 checkpoints matches Python; app/widget build passed. Twenty visual references and art brief added. T11/T12 remain open. |
| 2026-10-06 | Verified the 2026-10-05 follow-up fixes (backend 3,769 with PostgreSQL; Swift 122; build). Added display modes (tinted: one-colour figure with see-through features and a dashed glow; increased contrast: outlines, eye whites, solid marker; dark: dimmed backdrop), clearer posture, 'still' as hands together, 24 reviewed snapshot references, T11 review of the placeholder (G2_plan.md §4d). Swift 123 passed; installed on iPhone 16 Pro Max. Untracked UserInterfaceState.xcuserstate. Open: T12 device checks, G1 acceptance, final art |
| 2026-10-06 | Performance: phone reported 420.50 ms local calculation (Debug). Profiled on the phone's database (1,674 events): ~95% was loading, not the engine — Instant.parse compiled a regex per call (0.058 ms × ~5 timestamps × 1,674 events) and JSONDecoder→JSONValue took 96 ms. Replaced both with exact fast paths (20,000-timestamp and whole-corpus + phone-body equality tests). Mac on phone data: Debug ~500→112 ms, Release ~470→66 ms. Phone replay still identical (46 checkpoints). Installed; on-phone value to re-read |
| 2026-10-06 | On iPhone 16 Pro Max (Debug build): local calculation 420.50 ms → 125.82 ms after the parsing fixes. Runs off the main thread; the 100 ms budget applies to Release builds (Mac Release on the same data: 66 ms) |
