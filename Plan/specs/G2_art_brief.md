# G2 avatar art brief

The implemented character is a code-drawn prototype. Use this brief for replacement artwork; it does not mark T5 or final visual acceptance complete.

## Character and readability

Friendly, restrained 2.5D character with a neutral or small smiling mouth. Show the recorded cause without suggesting depression, illness, moral failure, body-size change or how the person feels. Avoid exaggerated exhaustion or red warning expressions. Head and eyes must remain recognizable in a 158-point small widget; glasses must not hide eyelids. The avatar needs adequate contrast on every environment and skin choice.

Use one transparent 1024×2048 full-body source canvas and a common origin. Draw for both full-body medium/app framing and a waist-up small-widget crop. Keep the text area outside the environment. Place confidence markers at the upper left, away from the sun/moon at the upper right.

## Identity and layers

Match the existing identity options: five skin tones, three hair styles, five hair colors, three outfits, two body silhouettes and optional glasses. Health never selects or changes those options. Changing counts later requires an explicit identity compatibility decision.

Provide body/outfit layers for five situational poses: standing, still, walking, catching breath and stretching. Each has a documented head/shoulder anchor; upright/neutral/low recovery posture adjusts those anchors independently. Export three outfits for each of the five poses. Keep head, eyes/eyelids, hair, glasses, under-eye shading, sweat, activity glow and environment layers separate.

The eye states are neutral, brighter and tired-looking, with tired intensity from 0–1. Export or define interpolation anchors for low/mid/high intensity. Body-size appearance must stay the user's selected silhouette in every pose. Provide cardio/strength/mobility glows without implying calorie burn or muscle growth.

## Motion, lighting and privacy

Use the shared static composition in widgets; app breathing/blinking is optional and stops under Reduce Motion. Sweat and glow use existing render-time decay. The pose follows sweat first, then glow above 0.4, then movement. Do not encode a separate mood or redefine health thresholds in artwork.

Provide morning/day/evening/night environments and gentle lighting washes. Preserve eye and silhouette readability at night. Privacy rendering retains identity and lighting but uses a neutral standing character without health traits, workout effects or confidence markers.

## Delivery and review

Export transparent @2x/@3x PNGs or vector PDFs with stable names and shared anchors, then replace the painter behind the existing `AvatarView` interface. Confirm asset license/ownership before distribution. Review small/medium/app sizes, every identity choice, glasses, low/bright eyes, all poses, light/dark/tinted modes, increased contrast and larger text. Update the reference snapshots only after reviewing the replacement assets, and measure widget memory and app frame timing on a physical iPhone.

Current prototype evidence: `G2_fixed_avatar_preview.png`, `G2_fixed_app_preview.png`, and the PNG references under `ios/HomeostatCore/Tests/HomeostatSharedTests/Fixtures/Avatar`. Final art source and physical review remain open.
