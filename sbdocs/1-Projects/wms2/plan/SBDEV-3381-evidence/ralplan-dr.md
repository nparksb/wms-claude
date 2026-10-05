
**Mode:** SHORT (T3, one ralplan round plus revisions; no `--deliberate` signal)

**Principles**
1. Never fabricate an inventory movement. A waive closes the record, not the stock.
2. Never release a lock you can't prove you own. This holds **everywhere**:
   - waive releases PICKED_FOR_GOODSOUT only when `toteState == ON`, not recovered, and under the ownership rule, including (i′);
   - complete's residue restore never re-imposes 100 on a waived row's share;
   - UNKNOWN and PARCEL fail closed.
3. Keep one meaning of "pending" (`reversal_completed_at IS NULL`) so existing readers stay correct without edits.
4. Authz must be visible to the annotation-based gate rails. No hidden in-code checks.
5. A refused operation commits nothing: pre-validate everything, then write.

**Top-3 Decision Drivers**
1. The live c1wh PRD order and an alert the operator cannot satisfy.
2. Inventory integrity. Case (ii) stock has no operator unlock path today.
3. Blast radius on existing consumers: the finders, index, `scanTote`, mobile `stillPending`, complete's notify and restore behaviour.

**Viable Options**
- **Option 1 (chosen): stamp `reversal_completed_at` + discriminator columns; method-level action function; a shared enqueue method (complete level-triggered, waive edge-triggered by its early return, whole-order permanent suppression after a `stockReturned=false` waive); a fail-closed four-state `toteState` (ON/PARCEL/OFF/UNKNOWN) for any lock release or `stockReturned=true` attestation; complete's residue restore made waive-aware from a pre-loop `waivedShare`.**
  - Pros:
    - zero change to the "pending" readers;
    - waive↔complete exclusion from the existing FOR UPDATE finder;
    - complete keeps its manual re-send path;
    - case (ii) is actually unstranded;
    - parcel stock can't be attested as returned.
  - Cons:
    - "completed" no longer implies "moved";
    - it touches complete's restore logic;
    - two by-design arch-pin reds;
    - one extra unit-load view read per SU;
    - suppression is permanent per order;
    - a recovered-SU row is stranded permanently (0 live).
- **Option 1′ (Architect antithesis): close records only, never write a stock unit.** It accepts (i), (i′), (iii-a) and amount-0 SUs, and refuses anything with stock on the tote.
  - Pros:
    - fixes c1wh completely;
    - no lock-release code at all;
    - no change to complete's restore.
  - Cons:
    - case (ii) stays stranded with no operator path until some later ticket, which contradicts Driver 2;
    - item 2 makes (ii) the main waive input.
- **Option 2: leave `reversal_completed_at` null and treat `reversal_waived` as a separate closed state.**
  - Pros:
    - "completed" keeps meaning "moved";
    - complete's notify path is untouched.
  - Cons:
    - 3 JPQL predicates, `scanTote`, a new partial index and mobile `stillPending` must change;
    - every future pending query must remember the predicate;
    - it needs a new mutual-exclusion story.
- **Option 3: force-close through `completeReversal` (a flag, same gate).**
  - Pros: the smallest surface.
  - Cons:
    - hands the override to every VIEW holder, including outbound-worker;
    - conflates moving stock with closing a record.

**Invalidation rationale**
- **Option 1′ is rejected under Driver 2.** The mis-release risk that motivates it is removed in Option 1 by the fail-closed `toteState`, the recovered-SU guard and the waive-aware restore.
- **Option 2 is rejected under settled Q2 and Driver 3.**
- **Option 3 is rejected under settled Q5 and Principle 1.** It also cannot express `stockReturned` without Option 1's columns.
- **Notes-marker (B) and in-service AND (F) are invalid** under D-b and Principle 4.

