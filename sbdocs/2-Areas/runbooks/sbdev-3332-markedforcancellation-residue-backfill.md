---
title: SBDEV-3332 — drain the markedforcancellation residue
status: proposed
created: 2026-09-15
ticket: SBDEV-3332
owner: Nam Park
risk: low
---

# SBDEV-3332 — drain the `markedforcancellation` residue

## Why a runbook and not code

SBDEV-3332 stops the WMS **creating** new orphaned `markedforcancellation` flags (the clear in
`PickingorderBusinessService.cleanUpCancelledOrder`, plus the two `forceCancelOrder` branches). Its
self-heal branch clears a stale flag on any order that re-enters `cleanUpCancelledOrder`.

**No existing residue row can re-enter**, because both entry points refuse first:

- `PickingorderBusinessService.finishPickingOrder` throws `ORDER_ALREADY_FINISHED` at its
  `state >= FINISHED` guard. Every residue row's picking order is at FINISHED or beyond — **137 at
  `700` and 2 at `800`** — and both satisfy `>= 700`.
- `CustomerorderService.cancelOrder` returns at `isAlreadyCancelled` (`state == 800`).

⚠ **Two corrections to an earlier version of this section, both mine, both found in review:**

1. It said *"every flagged-and-cancelled row has its picking order at 700"*. False — 2 of 139 are at
   `800`. The conclusion survives only because the guard is `>= FINISHED`, not because the state is
   uniformly 700.
2. It said the delegator `CustomerorderService.cleanUpCancelledOrder` *"has zero `src/main` callers"*.
   **False** — `CustomerorderService:976` calls it. That claim came from a
   `git grep "\.cleanUpCancelledOrder("` whose leading dot matches only qualified calls and misses
   unqualified same-class ones; both real callers are unqualified. **The correct grep is
   `git grep -n "cleanUpCancelledOrder(" -- src/main`**, which returns 3 call sites plus 2
   declarations. "No third door" is true because of the two guards above, not because anything is
   uncalled.

So the residue needs a data fix, not a deploy.

## The population (measured 2026-09-15, all six reachable v2 tenant DBs)

| tenant DB | flagged | residue (`state = 800`) | live (`state <> 800`) |
|---|---|---|---|
| `wms2-hydra` (**PRD**) | 0 | 0 | 0 |
| `nywh-hydra-uat` | 1 | 1 | 0 |
| `c1wh-shipitez-uat` | 16 | 16 | 0 |
| `nywh-shipitez-uat` | 0 | 0 | 0 |
| `wsl-wineco-uat` | 69 | 69 | 0 |
| `wms2-wineco-dev` | 59 | 53 | **6** |
| **total** | **145** | **139** | **6** |

**Hydra PRD is clean — there is no production action in this runbook.**

## ⚠ The six live rows are NOT residue and must not be touched

`wms2-wineco-dev` holds six orders that are flagged and **not** cancelled. These are live deferred
cancels with no terminal path — the hazard SBDEV-3332's split-out half owns, not something to clear:

| id | number | `co.state` | position states | picking-order states | created |
|---|---|---|---|---|---|
| 28848660 | 051483-000001 | 200 ASSIGNED | 800 | 700 | 2026-02-06 |
| 28857575 | 051488-000001 | 200 ASSIGNED | 800 | 700 | 2026-02-07 |
| 28999241 | 051503-000001 | 500 STARTED | 600 | 600 | 2026-02-23 |
| 29273806 | 051516-000001 | 200 ASSIGNED | 200 | 500 STARTED | 2026-03-26 |
| 29273837 | 051517-000001 | 200 ASSIGNED | 200 | 500 STARTED | 2026-03-26 |
| 29273895 | 051518-000001 | 200 ASSIGNED | 200 | 500 STARTED | 2026-03-26 |

Clearing these would discard a cancellation someone asked for. The `state = 800` predicate below is
what keeps them out — **do not relax it.**

### ⚠ Two of the six are STRANDED, and they are a decision, not a backfill

`28848660` and `28857575` differ from the other four. Their every CO position is already `CANCELED(800)`
and their picking order is at `700`, which closes the normal path in **both** directions:

- `finishPickingOrder` throws `ORDER_ALREADY_FINISHED` (`700 >= 700`), so the deferred-cancel dispatch
  never runs; and
- `cancelOrder` cannot complete them either — `canOrderPositionBeCancelled` returns false at
  `state >= PACKED` (`800 >= 650`), so `orderCanBeCancelled` is false and a second cancel just re-sets
  the flag it already has.

They are flagged, not cancelled, and have no terminal path. Stuck since 2026-02-06/07. This is the
hazard SBDEV-3332's deferred branch documents as theoretical — **it has materialised twice.**

**A review lane recommended widening the predicate to `state = 800 OR picking order >= 700` so these
two are drained as well. Declining that, deliberately.** Clearing the flag on an order that is *not*
cancelled does not heal it — it silently throws away a cancellation the customer asked for, and leaves
an order that OMS believes is cancelled sitting open in WMS with no record of why. The flag is the only
remaining evidence that a cancel was requested.

The right repair is to *complete* these two cancels (take the order to `CANCELED(800)` and notify OMS),
not to erase the request. That is a data-repair decision with an OMS-visible side effect, so it belongs
to Nam and to the split-out terminal-path ticket — **not to this runbook.** Left flagged on purpose.

## Procedure — per tenant DB

**1. Re-measure before touching anything.** The counts above are a point-in-time reading; the fix
stops new rows appearing but does not stop them appearing on a DB running the old image.

```sql
SELECT state, count(*) FROM customerorder WHERE markedforcancellation IS TRUE GROUP BY state ORDER BY state;
```

Expect one row at `state = 800` plus, on `wms2-wineco-dev` only, the six live rows above. **If any
row appears at a state not listed in the table above, stop** and re-read the live-rows section —
a new shape means a producer this ticket did not close.

**2. Record the ids you are about to change** (so the change is reversible):

```sql
SELECT id, number, state FROM customerorder
WHERE markedforcancellation IS TRUE AND state = 800 ORDER BY id;
```

**3. Apply, one DB at a time.**

⚠ **Use `psql`, not the MCP tools, for this step.** The `execute_sql` MCP tools are call-scoped — each
call is its own session — so a `BEGIN` in one call and a `COMMIT` in the next do not share a
transaction, and the `UPDATE` would autocommit with no chance to inspect it. If you only have MCP
access, run the single-statement `RETURNING` form and accept that it commits immediately (it is
reversible; see Rollback).

```sql
BEGIN;

-- RETURNING, so the captured id list is produced by the SAME statement that changes the rows.
-- Steps 2 and 3 as separate statements could disagree if anything wrote in between, which would
-- make the rollback list silently incomplete.
UPDATE customerorder SET markedforcancellation = false
WHERE markedforcancellation IS TRUE AND state = 800
RETURNING id, number;

-- Compare the returned count against step 1's 800-bucket.
--   matches  -> COMMIT;
--   differs  -> ROLLBACK;   <-- and re-run step 1 before trying again
COMMIT;
```

**4. Verify.**

```sql
SELECT count(*) AS should_be_zero FROM customerorder
WHERE markedforcancellation IS TRUE AND state = 800;
```

## Rollback

Re-set the flag on the ids captured in step 2. The flag is inert on a `state = 800` order — nothing
reads it except `finishPickingOrder`, which cannot reach these rows — so a botched run is recoverable
and has no operational effect either way.

## Order of operations

Deploy SBDEV-3332 **before** running this, or a DB still running the old image can mint new residue
between the backfill and the deploy. Deploying first is safe on its own; this backfill is cosmetic
until then.

⚠ **"Deployed" is per-environment, not a single event.** Five of the six DBs are UAT or dev and sit on
deploy trains separate from `develop`. Gate each DB on its own environment's build before backfilling
that DB — check `/api/public/version` for the running SHA rather than assuming the merge reached it
(see the `wms2-deployed-image-differs-from-branch-head` and `wms2-ui-develop-tag-race` precedents).

## Blast radius

⚠ An earlier version of this section said the flag has *"exactly one live reader in `src/main`"*.
**False.** `git grep -n "getMarkedforcancellation()" -- src/main` returns **four** reads:

| reader | reaches a `state = 800` order? |
|---|---|
| `PickingorderBusinessService.finishPickingOrder` — the deferred-cancel dispatch | no — throws `ORDER_ALREADY_FINISHED` first |
| `PickingorderBusinessService` — the tote-transfer skip in the same method | no — same guard |
| `CustomerorderService.getCustomerOrderDetails` — `details.put("markedforcancellation", …)` | **YES — no state filter at all** |
| `PickingorderBusinessService.cleanUpCancelledOrder` — the new heal guard | no — unreachable, see above |

Plus Spring Data REST: `CustomerorderRepository` is `@RepositoryRestResource`, so
`GET /v3/customerorder/{id}` serialises the field too.

**This makes the backfill *more* clearly worthwhile, not less.** No control-flow depends on the flag
for these rows, so clearing it cannot change warehouse behaviour — but it *is* being reported to
humans and to any API consumer of the order-detail payload, on orders that are already cancelled.
That false "a cancel is pending" signal is exactly what the backfill removes.
