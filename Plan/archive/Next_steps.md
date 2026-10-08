# Next steps

Updated: 2026-10-08. The order and rationale live in
[Master_implementation_plan.md §5](../Plan.md#5-ordered-work);
formulas and review findings in
[Calculation_and_product_review_2026_10_06.md](../specs/Calculation_and_product_review_2026_10_06.md).
This file is the short working checklist. The earlier G1 review notes (sections
A–G, 2026-09-30) are in git history and [Implementation_2026_09_30.md](Implementation_2026_09_30.md).

## Product design now — D0

- [x] Add the data-based feature catalog, app/widget surfaces and reactive rules
      to [App_widget_design_plan.md](../Product.md).
- [x] Revise the product sequence across the master plan and tracker (D-D).
- [x] Create and smoke-check both interactive design directions — evidence in
      the design plan §9. No native implementation or device gate closed.
- [ ] Replay the last 30–60 days: headline/quiet/calibrating counts (design plan §1).
- [ ] Review the first interactive Companion and Focus designs: Today, Trends,
      Journal, explanation, energy check-in and matching widget glances.
- [x] Create and browser-check GitHub-style activity calendar and ring studies;
      define missing/zero/rest, periods and history retention in design plan §10.
- [ ] Review and refine the studies; visual direction remains open.
- [ ] Specify P1 presentation/action contracts, trend retention and failure states
      before native implementation. Design progress does not close device gates.

## Foundation work — step 0 (code)

- [x] `StepProbe`: "no data" instead of 0 when statistics are nil; retain the
      `HKHealthStore`; stop the query at the 5 s deadline; log extension footprint.
- [x] Compare full HealthState and WidgetState (and revision/effective), not the headline.
- [ ] Snapshot from the run's own `LocalInputs`; log event count and oldest event date.
- [ ] `swift test`, app/widget simulator build, commit the M1/M2 probe work.

## Next — device session A (iPhone)

- [ ] A1 app running, unlocked · A2 locked then unlocked (M1)
- [ ] A3 force-quit, unlocked (M2 gate) · A4 force-quit, locked
- [ ] A5 lldb background task · A6 2 h outage, dims after 90 min · A7 lost-anchor demo
- [ ] Record a dated evidence table in Step_14_16_plan.md §12

## Decisions

- [x] **D-A** Per-domain cutoffs in the engine (Python first, both languages). Decided 2026-10-06.
- [x] **D-B** G1 closes on paths 1–2; force-quit updates are M3's exit. Decided 2026-10-06.
- [x] **D-C** Historical workout-first sequence (2026-10-06); superseded by D-D.
- [x] **D-D** Design now; daily app/widget loop first after G1/G2, then workout
      logging/planning and later personalization. Revised 2026-10-08.

## Then

- If A3 passed: M3 prerequisites (per-domain cutoffs, `HomeostatEngine` split, generation
  ordering, snapshot v1), then M3.
- G1 close: 24–48 h normal use, all rows evidenced.
- G2: T5 final art (any time), T11 device checks during the 24–48 h period, T12.
- After G1 and G2: P1 Today, Your day widget, explanations, energy check-in,
  first-two-weeks states. P1b after a week of use: focused widgets, trends,
  calendar, Journal shell and data controls. Rings deferred to P3.
- P2: workout logging (GRDB session/set schema, resumable session), richer
  history/reviews, then planning and Live Activity. P3/P4 follow the design plan.
