# SBDEV-1512 — validation against WineCo UAT (`wsl-wineco-uat`)

**Date:** 2026-09-16
**Why this tenant:** Nam, 2026-09-16 — Hydra is the only v2 PRD client and its dataset is tiny
(**zero** `DAMAGED` stockrecords of any type, i.e. it has never damaged anything, so it can validate
nothing here). WineCo is not on v2 PRD yet, so its UAT is the largest realistic v2 dataset available.

---

## 1. Phase 1's preconditions — all hold

| Probe | Result | Why it matters |
|---|---|---|
| `max(version)` in `flyway_schema_history` where success | **2.2.30** | `V2.2.32` applies cleanly; no collision, nothing stalled |
| failed migrations | **0** | tenant is not stuck mid-ladder |
| rows in `location` named `Damaged` | **1** | F2's validate-time pre-flight resolves; the plan's warning that the name is unindexed and per-tenant does not bite here |
| `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` | **`true`**, modified **2026-09-10** | the auto-receive path Phase 1 extends is **live on this tenant** — this is a real test bed, not a dormant one |
| `INBOUND_UPDATE_STOCK_IMMEDIATELY` | `true` | irrelevant to RETURN (that branch is ungated) but confirms the receive message fires |

## 2. ⭐ The central reframe, confirmed at scale

The ticket turns on `stock_view.damaged` keying on **`entity_lock = 103`**, never on membership of the
`Damaged` location. Measured:

| Instrument | Value |
|---|---|
| `count(*)` stockunits at `entity_lock = 103` | 240 |
| `sum(amount)` at `entity_lock = 103` | **369** |
| `sum(damaged)` from `stock_view` | **369** ✅ exact match |
| stockunits physically in the `Damaged` **location** | **241** ← one MORE |

**The two instruments disagree by one row, and the discrepancy is the defect shape itself:**

```
id=27628802  amount=1  entity_lock=0  unitload=UL333461
created=2025-11-14  additionalcontent='no comment from mobile UI'
```

That unit is **in the Damaged location but not locked**, so `stock_view.damaged` does not count it and
the client's damaged report does not show it. It is a live, already-shipped instance of exactly what
an implementation graded on *location* rather than *lock* would produce — arrived via the mobile UI,
independently of this ticket. It is the strongest available argument for I1 grading
`entity_lock = 103` and `stock_view.damaged` directly, which it now does.

*(Blind spot: this compares two aggregates over the whole tenant at one instant; it identifies the
population difference, not which write path produced that row. The comment string points at the
mobile UI but is not proof of the code path.)*

## 3. Blast radius — what this DB can and cannot measure

**It cannot measure the current loss.** A partially-damaged return reaches the WMS as a *smaller*
`amount_of_bottles` with no record of what was omitted. There is no WMS-side trace to count. Only the
OMS (`qty_damaged`) can quantify it, and no MCP reaches that MySQL.

**What it can measure — and a claim I had to withdraw.** Zero-position RETURN advices are the
signature of a return where every line was dropped:

| Year | RETURN advices | zero-position |
|---|---|---|
| 2020 | 496 | 1 |
| 2021 | 432 | 0 |
| 2022 | 336 | **87** |
| 2023 | 171 | **45** |
| 2024 | 566 | **0** |
| 2025 | 557 | **0** |
| 2026 | 238 | **0** |

**133 of 2796 total (4.8%)** — but **132 of those 133 fall in 2022–2023 and there have been none
since**, across a *higher* volume of returns (566 / 557 / 238). So the honest statement is *"133
historical zero-position returns, concentrated in 2022–2023, none in the last three years"*, **not**
"4.8% of returns currently lose all their stock", which is what the headline ratio suggests and what
I said before checking the distribution. Something changed in late 2023; this data does not say what.

⚠ A zero-position advice is also produced by a line whose product has **no SKU** (skipped with a
warning) or where everything was *missing* rather than damaged. The 133 must not be attributed to
damage without OMS-side confirmation.

## 4. The whole-unit damage defect ([SBDEV-3382](https://app.clickup.com/t/868m61q5j)) at scale

| `activitycode='DAMAGED'` | type | rows | `sum(amount)` |
|---|---|---|---|
| | STOCK_CREATED | 3600 | 5275 |
| | STOCK_REMOVED | 3122 | −5275 |
| | **STOCK_TRANSFERRED** | **9** | **0** ← the full-move signature |

Nine real operator-driven whole-unit damages (2020-12-11 → 2026-07-22, named operators,
`tostoragelocation='Damaged'`), each writing `amount = 0`, contributing **nothing** to
`transaction_detail.damaged`. Confirms the ticket's finding is live and pre-existing here too.

## 5. Commands

Every query via the `wsl-wineco-uat` MCP. ⚠ The first call after idle dropped twice
(`server closed the connection`, then `couldn't get a connection after 30.00 sec`) before a
`SELECT 1` ping succeeded — the known first-query-after-idle behaviour. Retry before concluding the
DB is down.
