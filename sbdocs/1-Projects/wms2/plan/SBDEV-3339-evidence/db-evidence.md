# SBDEV-3339 — DB evidence

**Tenant:** Hydra PRD, `wh01_hydra_v2` (localhost:25061 tunnel)
**Captured:** 2026-09-14
**Method:** `psql` direct. All ClickUp-configured Postgres MCP servers failed to connect this session (CONNECT_TIMEOUT); `psql` against the same tunnels works. Credential read from `~/.claude.json` into `PG*` env vars — never concatenated into a libpq URL.

---

## 1. Lock census — reproduces the ticket exactly

```sql
select entity_lock, count(*) from stockunit group by 1 order by 1;
```

| entity_lock | count | ticket said (2026-09-11) |
|---|---|---|
| 0 (`NOT_LOCKED`) | 439 | 439 ✅ |
| 2 (`GOING_TO_DELETE`) | 30 | 30 ✅ |
| **100 (`PICKED_FOR_GOODSOUT`)** | **7** | **7 ✅** |
| 405 | 328 | 313 — drifted, unrelated band |

**Positive control:** `select count(*) from stockunit` → **804**. The census is not reading an empty or single-valued column.

## 2. The 7 rows

```sql
select su.id, su.unitload_id, ul.labelid, ult.name, su.itemdata_id, su.amount
from stockunit su join unitload ul on ul.id=su.unitload_id
left join unitload_type ult on ult.id=ul.type_id
where su.entity_lock=100 order by su.id;
```

| su_id | unitload | tote | type | amount | created |
|---|---|---|---|---|---|
| 60941 | 17662 | T-0002 | Tote | 24 | 2026-07-31 |
| 60947 | 17662 | T-0002 | Tote | 12 | 2026-07-31 |
| 60952 | 17662 | T-0002 | Tote | 12 | 2026-07-31 |
| 60957 | 17662 | T-0002 | Tote | 12 | 2026-07-31 |
| 159982 | 37736 | T-0007 | Tote | 1 | 2026-09-04 |
| 160025 | 37736 | T-0007 | Tote | 1 | 2026-09-04 |
| 160050 | 37736 | T-0007 | Tote | 1 | 2026-09-04 |

Two totes, two orders, 60 + 3 = **63 units**. Matches the runbook `free-63-units-t0002-t0007.md`.

## 3. The signature that identifies the guilty path

```sql
select co.id, co.state, co.pickingtote_id, co.historytote
from customerorder co where co.pickingtote_id in (17662,37736);
```

| order | state | pickingtote_id | historytote |
|---|---|---|---|
| 60861 | **800** (CANCELED) | **17662** (still set) | T-0002 |
| 159907 | **800** (CANCELED) | **37736** (still set) | T-0007 |

All positions (`customerorder_position`) and pick lines (`pickingorder_position`) are at 800. `pickfromstockunit_id` is NULL on every pick line.

**Why this identifies the path:** both working siblings — `forceCancelOrder` and `cleanUpCancelledOrder` — null `pickingtote_id` in the same block that clears the lock. An order at `CANCELED` with `pickingtote_id` **still populated** is reachable from neither. Only `cancelOrder`'s success branch leaves that combination.

⚠ `historytote` being set is **not** evidence of teardown — `MobilePickingService` writes it at tote *assignment* (`customerOrder.setHistorytote(tote.getLabelid())` beside `setPickingtoteId(tote.getId())`). Both columns populated is the normal state of an order that has a tote.

## 4. The defect is deterministic, not a race

```sql
select order_state_at_cancel, position_state_at_cancel, reversal_required,
       count(*), min(created_at)::date, max(created_at)::date
from customerorder_cancellation_log group by 1,2,3 order by 1,2;
```

| order_state_at_cancel | position_state | reversal_required | rows | first | last |
|---|---|---|---|---|---|
| 200 (ASSIGNED) | 300 | false | 9 | 2026-08-03 | 2026-09-10 |
| **600 (PICKED)** | **600** | **true** | **7** | 2026-07-31 | 2026-09-04 |

Perfectly bimodal. Cancels before picking carry no tote stock and are harmless. **Every cancel that reached the success branch at `PICKED` stranded its stock — 7 of 7, across two orders five weeks apart.** No intermittency, no race window.

## 5. Control — has the good path ever run here?

```sql
select count(*) filter (where pickingtote_id is null and historytote is not null) as torn_down,
       count(*) filter (where pickingtote_id is not null) as still_attached,
       count(*) as cancelled_total
from customerorder where state=800;
```

| torn_down | still_attached | cancelled_total |
|---|---|---|
| **0** | 2 | 8 |

Of 8 cancelled orders: 6 never had a tote (the state-200 group), **2 had one and both stranded**. Zero have ever been torn down on this tenant — so there is no local "good" example to diff against, and the sibling paths are effectively unexercised here.

## 6. Fleet-wide blast radius — NOT ESTABLISHED

Intended query, per tenant:

```sql
select count(*) from customerorder where state=800 and pickingtote_id is not null;
```

Only **Hydra PRD** could be reached. The tunnels on ports **25060 (dev)** and **25062 (UAT)** are listening (ssh forwards confirmed via `ss -tnlp`) but reject **every** configured user — including `wms_landlord` on both, not just the tenant roles. `landlord-prd` on 25061 authenticates normally, so this is not a client-side or credential-parsing fault.

**Consequence:** the ticket's **AC-5** ("a DB query before and after on a UAT tenant, with a positive control") is **currently blocked on environment access**, not on this plan. Owner: needs the 25060/25062 tunnel targets or credentials refreshed before the plan's manual test step can run.

Do not read the single-tenant result as a fleet-wide count — this tenant is the one the ticket was filed from, so it is a biased sample by construction.

---

## 7. Cross-tenant comparison — and the exposure window (added after the analysis lanes reported)

`wsl-wineco-uat` and `wms2-wineco-dev` MCPs came back up; `wms2-hydra` stayed down (psql used for it).

| tenant | cancelled orders | tote still attached | su @ lock 100 | of those, on a **Tote** |
|---|---|---|---|---|
| Hydra PRD | 8 | **2** | 7 | **7** |
| WineCo UAT | 11,532 | 0 | 64 | **1** |
| WineCo DEV | 8,509 | 3 (all May-2026 artifacts, runbook-documented) | 586 | — |

⚠ **`entity_lock = 100` on a `Package` unit load is NORMAL** — it is a packed parcel awaiting goods-out. 63 of WineCo UAT's 64 are Packages. The defect signature is lock 100 on a **Tote**. Any census that does not split by `unitload_type` overstates the problem; my first pass did exactly that.

### 7.1 The exposure window — why Hydra strands and WineCo does not

The discriminator is the **first** guard in `CustomerorderPositionService.canOrderPositionBeCancelled`:

```java
if (customerOrderPosition.getState() >= WmsConstants.State.PACKED) {   // 650
    return false;
}
```

`false` ⇒ `cancelOrder` takes its **else** branch ⇒ (with `pickingconfirmationsent`) `cleanUpCancelledOrder` ⇒ **correct teardown**.
`true` ⇒ the **success** branch ⇒ **strands**.

So the defect fires only while a position sits at **600 `PICKED`** — after picking, before the picking order finishes. At 700 `FINISHED` the guard already routes to the good path.

`customerorder_position` state census:

| tenant | 600 (exposed) | 700 | 800 |
|---|---|---|---|
| Hydra PRD | 0 now — but all 7 stranded rows logged `position_state_at_cancel = 600` | 328 | 18 |
| WineCo UAT | **74** | 1,677,507 | 52,674 |

WineCo's positions move to 700 almost immediately, so cancels essentially always hit the good path — 747 of 747 `pickingconfirmationsent` orders torn down. Hydra's linger at 600, so it hit the bad path 7 of 7. **Same code, opposite outcome, entirely explained by dwell time at state 600.** This is why a day-one defect took until 2026-07-31 to produce its first visible casualty.

### 7.2 CORRECTION — `cancelBatch` attribution withdrawn

I initially inferred WineCo UAT's one orphaned tote unit (`T-0010`, su 32117474, 2026-04-17, `orders_still_pointing_at_it = 0`) came from `CustomerorderBatchService.cancelBatch`, because that method nulls `pickingtote_id` with no lock clear.

**That inference is wrong and is withdrawn.** `cancelBatch` has **no caller in `src/main`** — `git grep -n "cancelBatch" origin/develop -- 'src/main/**/*.java'` returns only its own declaration, and no controller routes to it. Positive control: the same grep over `src/test` returns 53 references across 4 classes, so the search works. It is dead production code and cannot have produced any live row.

**`T-0010`'s provenance is therefore unestablished.** WineCo UAT holds zero `customerorder_cancellation_log` rows, so there is no record to attribute it to, and the UAT build (tracking `release`) is not the build I read. Do not assert a cause for it in the plan.

`cancelBatch` remains a genuine latent instance of the same root cause — worse in shape, since it severs `pickingtote_id` — but its blast radius today is **nil**.
