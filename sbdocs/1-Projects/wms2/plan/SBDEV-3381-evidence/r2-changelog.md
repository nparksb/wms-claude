1. Three-state `toteState` ON/OFF/UNKNOWN (N1) replaces both the id comparison and the label-only rule. Rows (i′), (ii), (ii′), (ii″), (iii-b) and (iii-d) are rewritten against it, and (i′) clears only when ON (N6). `waiveLockRetained` = lock 100 && amount > 0 && state ≠ OFF → §3.2 "toteState" and "Stock-effect table"; §3.4; §2 "Log columns that are NOT what they look like".
2. No lock clear on an SU recovered in this call (N4) → §3.2 steps 4–5, the (i′)/(ii) rows; pinned in T3.
3. Ownership rule declines when any contributing `amountPicked` is null (F10) → §3.2 "Ownership rule"; T3.
4. Complete's residue restore is waive-aware (restore only if residue > Σ waived share, or when any contributing amount is null). The line is struck from "What does NOT change" (F2) → §3.3.2; §6; §0 row 2a; T22.
5. Complete stays level-triggered with only suppression added; waive is edge-triggered by its early return. T19 is inverted, and the "edge trigger in both" wording is removed (F3, Nam) → §1 "Found while reading; kept by decision"; §3.3.1; §6; §7.5 #6; §10; ADR; RALPLAN-DR Option 1.
6. Tests:
   - distinct-id fixture rule plus the id-comparison and label-only mutants on T3, T5 and T21b;
   - T5b added;
   - T22 added;
   - T4 non-null `picktostockunitId`;
   - T18 moved to H2 `BaseRollbackIntegrationTest` (LockClear fixtures), asserting by fixture `aggregate_id`, with no CHECK in that lane;
   - T18b rollback of the recovery save added;
   - T17 asserts the role-name set, with the swap mutant;
   - T21 split into T21a/T21b;
   - T8 gets the reason cap.

   → §7.1 fixture rules and table; §7.2.
7. `WEB_UI_ACTION_*` precedent cited (`WmsConstants:426-433`) (F6) → §3.5 item 1.
8. Mobile: `waivePosition` checks `reversalWaived`, and the existing `completeReversal` `applied` adds `&& !p.reversalWaived`, with Jest pins and mutants (F11) → §3.8.
9. SET 9 runs before the dev merge and before PRD promotion (expect the new users), then after (expect 0). O2 is reviewed at the PRD pre-run (F5) → §3.5 item 5; §5.1 #7; §5.2; §8 steps 1, 4, 5; M7.
10. Stockrecord evidence query (4 MANUAL_SPLIT removals + 4 matching bin creations, measured) and the sysprop PRD-host check are gating pre-steps, replacing "allowed because case (i)" (N5). The item-2 mechanism is recorded → §8 step 5a–5b; §1 "How the case arose"; §5.1 #2.
11. Fixture recipes for M1 (order-level cancel + Move Stock) and M3 (per-position cancel). M6 asserts the role-name set (N8, N3) → §7.4.
12. Option 1′ added with its rejection rationale (N7) → §9 row 1′; RALPLAN-DR.
13. §0 #34 deleted, with the reason (generator with no assertion; covered by T11/T12) (N10) → §0 footnote.
14. Nam's F4 (whole order, permanent) and F3 (complete level-triggered) are recorded as Resolved. O4 is added for the unverified OMS open-reversal alerting → §10; §5.1 #6.
