# Prototype visual references

Twenty-four PNGs cover small/medium framing, light/dark appearance, neutral, tired/low posture, workout, night calibration and neutral privacy presentation, plus tinted (accented: opacity only) and increased-contrast versions of the tired and workout scenes (2026-10-06). They deliberately include the deepest skin tone and glasses. Generated and visually inspected on macOS 27.2 with the local iOS/macOS 27 SDK.

`AvatarSnapshotTests` compares normalized RGBA pixels with a mean channel error tolerance of 0.002. Ordinary tests do not rewrite references. To update deliberately:

```sh
UPDATE_AVATAR_SNAPSHOTS=1 swift test --filter AvatarSnapshotTests
```

Review the PNGs and contact sheet when updating. OS/font/material changes can require review before updating baselines. These reference the placeholder renderer; they do not substitute for checking the Home Screen widget, tinted mode and increased contrast on a physical iPhone.
