---
name: for-update-on-a-missing-row-takes-no-lock
description: "A SELECT ... FOR UPDATE matching zero rows takes NO lock, so a find-or-create helper called after the miss silently defeats a documented lock order — and every uncontended test stays green"
metadata:
  node_type: memory
  type: project
  originSessionId: 0af5cf2e-56f2-433e-be5f-9e9141ac0e40
  modified: 2026-09-18T02:33:59.769Z
---

**`findByLabelidForUpdate(x).orElse(null)` returning empty locks nothing.** There is no row to lock,
and PostgreSQL takes no gap/predicate lock — so the interval between the miss and a subsequent insert
is unserialised. Obvious once stated; it survived my own review, a plan section, and an explicit
javadoc *claiming the opposite* on SBDEV-3398 (2026-09-17, found by an independent code-review lane).

**Why it bites harder than it looks: `UnitloadService.createUnitload(String name, ...)` is a
FIND-OR-CREATE.** It opens with a non-locking `unitloadRepository.findByLabelid(name)` and returns the
existing row if one is there. So the "mint" branch of a locked lookup can hand you **another
session's committed row, unlocked**, and then:

1. hop 1 of the documented lock order (`UL(pallet) → Customerorder → UL(parcel)`) is silently absent
   for the rest of the transaction — on the one path the whole ticket existed to make safe;
2. any `if (weMintedIt) { skip the type check }` shortcut now skips a check on a row we did **not**
   create, so a concurrently created Tote or Case is accepted as a palletising carrier.

**The wrong fix I had written into the plan**, and why it was wrong: *"Do NOT re-lock a row this
transaction just inserted — per SBDEV-3244 a freshly-persisted entity is already at EntityEntry lock
level WRITE."* The SBDEV-3244 half is true but the premise is not: you do not know that you inserted
it.

**The right fix — `findByIdForUpdate(row.getId())` after the create, and type-check
unconditionally.** Correct in both branches, which is what makes it safe rather than merely
defensive:
- we really inserted it → the EntityEntry is already at `LockMode.WRITE` (Hibernate's highest
  internal mode), so this is **not** an upgrade, no version check runs, nothing can throw;
- the helper found someone else's row → it **is** an upgrade, the version is checked, and a
  concurrent modification aborts the transaction. That is the correct outcome: better a rescan prompt
  than writing through a row you never held.

Note the corollary: the desktop path's "Fix E" (`createUnitload` then `findByIdForUpdate(created.getId())`
in `ParcelMonitorViewService`) was right all along, and the plan's deliberate divergence from it was
the defect. When a sibling path already does the belt-and-braces thing, find out why before
diverging.

**Residual, deliberately not retried:** two sessions that both miss and both insert collide at
`uq_unitload_labelid`. Pre-existing (the find-or-create was always unlocked). Close it with an upsert
in the helper if it ever matters — never with a retry loop around the lock.

**How to apply.** Any `...ForUpdate(...)` whose result you treat as optional is a lock you may not
hold. Trace what runs on the empty branch; if anything there can create or return the row, re-take
the lock afterwards. **No uncontended test can see this** — the shape is only wrong under a race, and
a service-level race harness can pass against it too, which is why the static pin matters:
`InOrder` + `never()` on the non-locking finders + `verifyNoMoreInteractions`. Related:
[[findbyidforupdate-throws-at-the-lock-read-not-at-flush]],
[[wms2-requires-new-in-lock-holding-tx-deadlock]].
