---
name: broader-guard-before-narrower-one-shadows-its-diagnosis
description: Adding a broad guard AHEAD of an existing narrower one silently replaces the narrower diagnosis for its whole subset — and the broad message may recommend exactly what the narrow guard exists to prevent
metadata: 
  node_type: memory
  type: feedback
  originSessionId: ab615abb-946c-473f-b338-0029689c07a2
  modified: 2026-09-17T15:35:36.066Z
---

On SBDEV-2620 a new guard — *"this parcel is on a DIFFERENT pallet"* — was seated immediately before
SBDEV-2507's existing *"this parcel is on a pallet that already SHIPPED"* check in
`ParcelMonitorViewService`. Both throw `BusinessException`, so the first one to fire wins.

"Already shipped" is a strict **subset** of "on a different pallet". Measured: **96 of the 114** Hydra
UAT re-palletizations were off a CLOSED-BOL pallet. So in the large majority of real cases the new
guard fired first, SBDEV-2507's message became unreachable, and the operator was told:

> *"Remove it from that pallet first using Move Unit Load…"*

— i.e. instructed to pull a parcel off an **already-shipped** pallet, which is the precise action
SBDEV-2507 was built to prevent. All tests stayed green: both guards reject, so every
`assertThatThrownBy(...).isInstanceOf(BusinessException.class)` still passed. Only an adversarial
review lane reading the two guards *together* caught it.

**Why:** ordering guards is normally treated as a style question, so nobody checks it. But when guard
B's condition implies guard A's, ordering B first doesn't just change wording — it **deletes A's
control from the operator's view** and can substitute advice that contradicts it.

**How to apply:** when adding a guard beside existing ones on the same object, ask *does my condition
subsume any sibling's?* If yes, the **more specific guard must run first** — the narrower diagnosis is
the more useful one and usually encodes a stronger prohibition. Then check the broad guard's remedy
text is not an action a sibling forbids. Assert the **message**, not just the exception type, or the
shadowing is invisible to tests. Same session, same shape: mobile had never called the sibling at all,
so the broad guard's misleading remedy was the *only* thing an operator ever saw there.

Related: [[a-guard-fences-the-mechanism-you-aimed-at]] (enumerate every producer of the outcome) is the
other half — that one is about guards that are too narrow in *coverage*; this one is about guards that
are too broad in *precedence*. See also [[wms2-businessexception-key-vs-message-traps]].

---

**RECURRED 2026-09-17 on SBDEV-3397, hours after this note was written, in the ticket that cites
SBDEV-2620.** This memory existed and did not prevent it, so the trigger below matters more than the
principle above.

The new guard went into `MobileMoveUnitloadService`, a screen the narrower sibling
(`assertParcelCarrierNotShipped`) had **never been wired into**. So there was no sibling *visible at
the call site* to order against — nothing to notice. The subset relation was identical to 2620's and
the population was worse: **181 of 188 carried parcels on Hydra PRD (96.3%)**, and 469,582 of 469,609
on WineCo UAT (99.99%), sit on a pallet whose BOL is CLOSED. The message said *"Move it to a storage
location first"* — and the location arm has no BOL check, so the operator succeeds and leaves a
CLOSED BOL pointing at a parcel back on a rack. A silent wrong write became a **coached** wrong write.

**The trigger that would have caught it, stated as a check rather than a principle:** when adding a
guard to a screen, do not only look at the guards already *in that method* — grep for every guard
that fires on the **same entity** anywhere in the codebase, and ask whether it applies here too. The
dangerous case is precisely the one where the sibling is ABSENT: an absent sibling cannot be
mis-ordered, it is simply missing, and its diagnosis never existed to be shadowed. "No sibling at
this call site" is evidence the sibling was forgotten, not evidence there is nothing to order.

Also worth keeping: **an adversarial review lane caught this, and a standard code-review lane running
in parallel on the same diff did not.** The code-reviewer returned no Critical or High. Both lanes
found the over-block and the untested branch; only the one told to attack the ordering found the
ordering. At T2+, one of the two lanes should be explicitly pointed at the failure mode that bit the
sibling ticket.

See also [[a-guard-fences-the-mechanism-you-aimed-at]] — SBDEV-3397 also fenced the literal
`"Pallet"` instead of the invariant `unitload_type.unitloadallowed`, letting a Cart reach the same
end state undiagnosed. Two halves of the same ticket, two different ways of aiming at the instance.
