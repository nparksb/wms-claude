# Q2, WMS half — what Fix E would actually send, and what does or does not gate it

Measured 2026-09-16. This is the sending side only; the receiving side is `laneN-oms-cancel-contract.md`.

## 1. The two orders emit nothing today — confirmed, not assumed

```sql
SELECT id, aggregate_id, process_type, status, idempotency_key
  FROM outbox_message
 WHERE aggregate_id IN (28848660, 28857575, 585000351)
    OR idempotency_key IN ('CO-CANCELLED-28848660','CO-CANCELLED-28857575','CO-CANCELLED-585000351');
-- [] (wms2-wineco-dev)
```

Zero rows. Consistent with the deferred branch, which sets the flag and returns. **Two consequences:**
the premise of Q2 is confirmed (today: nothing; after the replay: one message), and **no stale
idempotency key exists that would silently swallow the replay** — `CANCELLED_IDEMPOTENCY_KEY_PREFIX +
customerOrder.getId()` is unique per CO and unused for all three.

And the orders are still stranded, unchanged after the AC-5 deploy — exactly as predicted, since their
picking orders are at 700 and `finishPickingOrder` throws `ORDER_ALREADY_FINISHED` before any gate:

| CO | number | co.state | positions | PO | flag |
|---|---|---|---|---|---|
| 28848660 | 051483-000001 | 200 | 800 | 700 | `true` |
| 28857575 | 051488-000001 | 200 | 800 | 700 | `true` |
| 585000351 | 024277-000001 | 200 | 800 | 700 | `false` (the control — works today) |

## 2. What the message is

`CustomerorderService.cancelOrder` builds an `OrderBatchDto` — `facilityCode` (from
`MULTIWAREHOUSE_IDENTIFIER`, `WSL` on dev), `batchId`, and one `OrderDto` per order carrying
`uniqueId = customerorder.externalnumber` plus its positions — and enqueues it to the outbox against
`WEBSERVICE_ORDER_BATCH_CANCELLED`.

| tenant | `WEBSERVICE_ORDER_BATCH_CANCELLED` |
|---|---|
| wms2-wineco-dev | `https://api-oms.dev.sbo.li/services/call/cancelPosition` |
| wsl-wineco-uat | `https://api-oms.uat.sbo.li/services/call/cancelPosition` |
| **wms2-hydra (PRD)** | `https://api-oms.sbo.li/services/call/cancelPosition` |

Each environment points at its own OMS. **No repeat of the Hydra-PRD-notifies-UAT-OMS defect** — that
one was three *other* sysprops, fixed 2026-09-11, and this one was clean when checked.

## 3. ⚠ THE FINDING — there is NO kill switch, and two sysprops say otherwise

`los_sysprop` on **every tenant checked** carries `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED = 'false'`
(dev, WineCo UAT, **Hydra PRD**). Anyone planning this repair who reads the sysprop table concludes the
notification is switched off and the replay is therefore safe by default.

**It is not read anywhere.** Derived by `git grep` over `origin/develop`, which returns exactly three
hits for the constant:

- `WmsConstants:1123` — the key declaration
- `WmsConstants:1125` — the default value, `"false"`
- `UtilRestController:177` — **commented out** (`//        syspropService.createSystemProperty(...)`)

`cancelOrder` enqueues unconditionally. **`WEBSERVICE_BEHAVIOUR` is inert in exactly the same way** —
its declared values are `send / discard / keep`, so an operator could set it to `discard` believing that
suppresses sends, and its only non-declaration reference is also a commented-out line in
`UtilRestController`. Two controls, both dead.

**Positive control for the instrument** (a zero-scan needs one): the same grep finds the sibling gates
`WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE_ACTIVATED` and `..._UPDATE_PRIORITY_ACTIVATED` at **real
call sites** in `PickingDateChangeNotificationService` and `PriorityChangeNotificationService`. So the
pattern exists and is wired elsewhere; the instrument is not silently returning zero.

**And it is inert in production, measured rather than inferred.** Hydra PRD's `outbox_message` holds
**3 `ORDER_BATCH_CANCELLED_FROM_WMS` rows, all `SENT`**, timestamped 2026-09-10 — while that tenant's
gate reads `false` and its URL points at production OMS. Cancellations are being delivered to prod OMS
today with the switch advertising them as off. *(SENT means a 2xx was received; per this repo's own
rule, never read SENT as proof the receiver acted on it.)*

Blind spot of this method, stated: `git grep` sees source only. It cannot see a gate applied in
configuration, in a proxy, or by the OMS refusing the route — but none of those would make the sysprop a
working control either, and the 3 SENT prd rows settle the question empirically.

## 4. What this means for Fix E

**Good news, and it is the substantive part of the answer.** The worry behind Q2 was that the repair
makes these orders emit something they never have. True — but the *something* is *not exotic*: it is the
ordinary `ORDER_BATCH_CANCELLED_FROM_WMS` message that production OMS already receives and accepts
routinely (3 in one day last week, all 2xx). A replayed cancel is a well-trodden message arriving late,
not a novel one.

So the residual risk is **not** "can OMS handle this message" — demonstrably yes — but narrows to
**"can OMS handle a SEVEN-MONTH-OLD one for these specific orders"**: whether its state machine, any
age/period check, or a customer-visible side effect makes a stale cancellation different from a fresh
one. That is `laneN`'s question.

**The operational consequence is immediate regardless:** do not plan Fix E on the assumption that the
`_ACTIVATED = false` sysprop will hold the message back. It will not. Whatever is decided about OMS, the
replay sends.

## 5. Proposed, not filed — the inert gate is its own defect

Two sysprops present on all six tenants, including production, that read as controls and are wired to
nothing. `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` is the dangerous one: it is *false* everywhere, so
every reader is misled in the direction of believing a live integration is off.

Either wire them or delete them — a dead switch is worse than no switch, because it is indistinguishable
from a working one until someone relies on it. Sub-T3 in isolation, but it touches the OMS notification
path on prod → **proposed, not filed**, per the ticket policy. Related:
[[wms2-metrics-exist-but-nothing-scrapes-them]] (a metric is not a working control) and
[[advertised-capability-is-not-exploitable-capability]] — same family, third instance.
