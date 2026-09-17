# The two "stranded orders" are Dave's February test data — Fix E should be closed, not run

Measured 2026-09-16, after Nam clarified that **WineCo runs WMS v1 in production today** and moves to
v2 in a few weeks.

## The finding

`customerorder.externalnumber` — the field WMS sends to OMS as `unique_id`, i.e. the OMS-side identity —
settles it:

| WMS id (dev) | number | **externalnumber** | dev state | v1 PRODUCTION state |
|---|---|---|---|---|
| 28848660 | 051483-000001 | **`DaveTest20240205-05_1`** | 200, marked | **700 FINISHED**, not marked |
| 28857575 | 051488-000001 | **`DaveTest20240207-02_1`** | 200, marked | **700 FINISHED**, not marked |
| 585000351 | 024277-000001 | `247463` | 200, not marked | 800 CANCELED, not marked |

The two "stranded" orders are **hand-created test orders**, made on `wms2-wineco-dev` on 2026-02-06 and
2026-02-07 while somebody exercised the cancel flow. Their `created` and `modified` timestamps are
~60 seconds and ~3 minutes apart respectively — the signature of a manual test, not of an order that
lived through a warehouse.

The order *numbers* collide with real WineCo orders because WMS mints `number` sequentially per tenant,
and dev was seeded from a migration snapshot. **The number is not the identity — `externalnumber` is**,
and a flag-shaped or number-shaped census cannot tell the two apart. That is why this went unnoticed
through the whole ticket.

## What that means

**1. No customer has been waiting seven months.** The ticket's framing — *"A customer asked for a cancel
seven months ago and the order is neither cancelled nor cancellable"* — is **false as a business claim**.
In WineCo's live v1 both orders reached `FINISHED(700)` and carry no cancellation flag. They shipped.

**2. These rows are the REPRODUCTION of the defect, not victims of it.** They are exactly what you would
expect to find after someone triggered the deferred-cancel path on dev in February and it stranded — which
is what made the ticket findable in the first place. Their value was diagnostic and it has been fully
realised.

**3. Fix E, if run, is a guaranteed no-op.** WMS would send `unique_id = "DaveTest20240205-05_1"`. Per
`laneN` §6, a lookup miss returns **HTTP 200 with `Status: Error`**, WMS marks the row `SENT`, and nothing
is written on either side. There is no OMS parcel with that id to cancel. **The Q2 blocker therefore does
not apply to Fix E at all** — the decisive fact was knowable from WMS alone, and I should have read
`externalnumber` before commissioning an OMS trace to answer it.

**4. The OMS findings still stand**, and are unaffected: N-F1 (no terminal-state guard), N-F2 (unscoped
inventory credit) and N-F4 (unauthenticated write endpoint) are real defects in `oms-laravel-api`
regardless of whether anyone replays anything. They simply are not *this* ticket's problem, and there is
now no reason for this ticket to touch OMS.

## What WineCo's v2 cutover actually inherits

Checked on `wsl-wineco-uat` (which mirrors v1 production: identical 69-row marked census, identical
oldest/newest timestamps) and on `wms1-wineco` (live v1) directly.

| question | answer |
|---|---|
| Stranded orders (`marked = true AND state <> 800`) coming across? | **ZERO** — on UAT and on live v1 alike |
| Marked-flag rows coming across? | **69**, all at `state = 800` — pure post-cancel residue |
| RAPID_PICKING exposure after cutover? | **Effectively none** — see below |

**RAPID_PICKING is dead data for WineCo.** Their only such section is literally named `test_section`:
29 picking orders, **all at state 700**, newest **2022-03-13** — over four years stale. Every live zone
(`Zone_A`…`Zone_Z`, ~66,000 picking orders) is `TOTES_ON_CART`.

So the rapid-picking residual recorded in §12 does **not** become live exposure at WineCo's cutover. It
stays a rail for a producer that does not exist on any tenant, and it should stay deprioritised rather
than being rushed ahead of the migration.

## Recommendation

1. **Close Fix E as "not required"**, and correct the ticket's customer-impact framing rather than
   silently dropping the AC. The dev rows can be left alone or tidied as dev noise; replaying a cancel
   for them achieves nothing.
2. **Run SBDEV-3332's residue backfill at cutover** so WineCo's v2 does not start life carrying 69
   misleading `markedforcancellation` flags. The runbook already exists
   (`sbdocs/2-Areas/runbooks/sbdev-3332-markedforcancellation-residue-backfill.md`).
3. **Decide the OMS cancel notification before cutover**, and know that the switch is dead: whoever
   configures WineCo on v2 will see `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED = false` and reasonably
   conclude cancellations are not sent. They are. That gate needs wiring or deleting — now more clearly
   worth doing, because a cutover is exactly when someone reads that table and believes it.
4. **Leave the rapid residual parked**, with its exposure re-measured as above.

## The lesson worth carrying

**An order number is not an identity.** Two separate censuses in this ticket — the flag census and the
stranded-shape census — agreed with each other and were both right about the *data*, and both invited a
conclusion about the *business* that was wrong, because neither looked at `externalnumber`. The tell was
one column away the entire time.

Generalised: when a row's significance depends on it representing something in another system, check the
field that carries the cross-system identity before inferring impact. Related:
[[a-zero-scan-needs-a-positive-control]] — same family, different axis: here the scan was correct and the
*interpretation* was unvalidated.
