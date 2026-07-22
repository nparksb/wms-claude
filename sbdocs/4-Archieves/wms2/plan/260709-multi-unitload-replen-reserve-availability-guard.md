---
title: "Multi-Unit-Load Replenishment (v2 port) — Reject Already-Reserved Unit Loads Up Front: Availability Guard, Not Gross-Stock Guard"
ticket: ""
ticket_url: ""
type: "bugfix"
priority: "high"
status: archived
status_detail: "v1→v2 port of 1ff0d85. ralplan consensus → tdd-gate → ralph implement → code review APPROVE → PR #69 into develop (open). 2026-07-10."
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-07-10"
updated: "2026-07-15"
db_verified: true
related:
  - "[[260709-multi-unitload-replen-reserve-availability-guard]]"
  - "[[2026-07-10-wms-v1-sync]]"
  - "[[wms2-replenish-workflow]]"
  - "[[wms2-multi-unitload-replenish]]"
  - "[[wms2-stockunit-design]]"
tags:
  - plan
  - wms2
  - replenishment
  - multi-unitload
  - reservation
  - data-integrity
---

# Multi-Unit-Load Replenishment (v2 port) — Reject Already-Reserved Unit Loads Up Front: Availability Guard, Not Gross-Stock Guard

**Ticket:** _(untracked — WineCo tester report)_
**Project:** wms2 | **Version:** v2/wms2-api | **Type:** Bug fix (v1→v2 port of `260709-multi-unitload-replen-reserve-availability-guard`)
**Priority:** High — the gross-vs-available gate and the additive reserve throw both reproduce in v2 verbatim; same WineCo mobile multi-UL replenish flow.
**Status:** Reviewed — ralplan consensus (Planner → Architect **SOUND-WITH-CONDITIONS** (4 folded) → Critic **ITERATE** → revised → Critic **APPROVE**). Pending implementation approval.
**Sweep:** [[2026-07-10-wms-v1-sync]] (multi-UL replenish availability-guard unit).

> **What the tester saw (v1 incident, reproduces in v2).** On mobile multi-unit-load replenishment, selecting **TWO** unit loads (ULs) to fulfill one replenishment request fails with a `FacadeException` `CANNOT_RESERVE_MORE_THAN_AVAILABLE`, rendered **"Cannot reserve more than available (0.0000)"**. The per-UL entry gate `validateUnitLoadEntry` accepts a UL whose stock is already fully reserved by a *different* open replen because it checks **GROSS** (`matching.getAmount()`) not **availability** (`amount − reservedamount`); the additive reserve write downstream then throws. Fix = reject at entry on availability with a clear new message, with a **self-source add-back** so the template order's own current source UL is not wrongly rejected.

> **Scope note (v2 vs v1 — CLEAN single-locus port, with a small credit-arithmetic refinement).** Unlike the SBDEV-2512 unit in the same sweep (which needed a NEW-1 `rollbackFor` fix), this port has **zero NEW v2-only issues in the touched region**. v2's `fulfillMultipleUnitLoads` **already** carries the correct `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` — no annotation change. The **one intentional v1→v2 divergence** is the self-source add-back: v2 (a) reads a **null-safe** reserved value instead of the NPE-prone `getAvailableamount()`, (b) gates the credit on `reservedamount > 0` (fixing a `reserved==0` over-credit), and (c) caps the credit at `min(requestedamount, reservedamount)` as **defense-in-depth**. In every known-reachable self-source state (`reserved ≥ requested`) the credit is **behaviorally identical to v1's plain `requestedamount`**; the `min()` cap only diverges in the atypical `0 < reserved < requested` partial-reservation-leak state (§2, §3, §9). Line numbers verified by direct code read 2026-07-10; re-verify at implementation.

---

## 1. Problem Statement & Root Cause (v2-accurate)

**v1 incident (WineCo tester):** selecting two ULs to satisfy one replenishment request throws at the additive reserve write:

```
FacadeException: CANNOT_RESERVE_MORE_THAN_AVAILABLE
→ rendered: "Cannot reserve more than available (0.0000)"
```

thrown in v2 at `StockunitBusinessService.changeReservedAmount` (`:475`, `:478-479`):

```java
BigDecimal newReservedAmount = oldReservedAmount.add(amount);         // :475 — additive
if (stockUnit.getAmount().compareTo(newReservedAmount) < 0) {         // :478 — amount < oldReserved + qty
    throw new FacadeException("CANNOT_RESERVE_MORE_THAN_AVAILABLE",
        String.valueOf(stockUnit.getAvailableamount()));              // 0.0000 surfaces here
}
```

`Stockunit.getAvailableamount()` (`:54-56`) = `amount.subtract(reservedamount)`. For a fully-reserved UL (`amount=48, reservedamount=48`), `newReserved = 48 + qty > 48` → throw; `(0.0000)` is exactly the available amount.

**Root cause reproduces in v2 verbatim.** `MobileReplenishService.validateUnitLoadEntry` (`:876-900`) resolves the UL (`:878`), finds the matching stock by `itemdataId` (`:887-892`), null-checks it (`MsgSourceStockNotFound`, `:893-894`), then gates on **gross** stock:

```java
// MobileReplenishService.java:896-897 — GROSS, not available
if (matching.getAmount().compareTo(dto.getQty()) < 0) {
    throw new FacadeException("MsgTooMuchRequested");
}
return new MultiUnitLoadInstruction(dto, matching, unitload);         // :899
```

`getAmount()` ignores `reservedamount`, so a pallet already fully reserved by another open replen passes for any `qty ≤ amount`, and the additive reserve path then explodes. The defect is **data-independent** — it reproduces whenever a selected UL's *available* (not gross) stock is below the requested qty.

### DB verification (inherited from v1; no new v2 DB claim)

The v1 plan is `db_verified: true` against `wms1-wineco-dev`: **559 of 602** open replenishments (state 300) reserve their **entire** source pallet (available `0.0000`) — "source already reserved" is the **normal design state**, not corruption. Each open replen holds its own source. This v2 port **inherits that evidence**; no new v2 DB claim is made.

### Nullable `reservedamount` — a v2 correctness hazard the fix must respect

`reservedamount` is a **nullable** column (`V1.0.01__wms_tables.sql:902` — `reservedamount numeric(17,4)`, no `NOT NULL`). Stock that has never passed through `changeReservedAmount` (which assumes non-null) may carry a `NULL` `reservedamount`. `getAvailableamount()` (`:56`) does `amount.subtract(reservedamount)` → **NPE on a NULL row**. The old gross gate touched only `getAmount()` and was immune. The new availability guard therefore **must not** call `getAvailableamount()` unguarded — it computes availability with a null-safe reserved read (§3, condition 2).

### Why the single guard in `validateUnitLoadEntry` is sufficient (v2 confirmed)

`fulfillMultipleUnitLoads` (`:739`) validates **all** ULs in the loop (`:759-768`, `validateUnitLoadEntry` at `:767`) **before any reservation**: FIRST reserve is `applyExplicitSourceToOrder` (`:778`), remaining are `createOrderFromTemplate` (`:786`, `i≥1`). ULs de-duplicated by `resolveUnitloadId` into a `HashSet` (`:763-766`) — a self-source UL yields at most one instruction. A correct availability check in `validateUnitLoadEntry` blocks the bad request before either reserve path runs — **no second guard** in `createOrderFromTemplate` (same conclusion as v1).

### Affected Locations (v2)

| # | File | Line | Role / disposition |
|---|------|------|--------------------|
| 1 | `service/mobile/MobileReplenishService.java` | `:876-900` (`validateUnitLoadEntry`, **private**) | **FIX LOCUS** — replace gross gate (`:896-897`) with null-safe availability gate + self-source add-back capped at `min(requestedamount, reserved)` under `reserved>0`; throw new `MsgUnitLoadStockAlreadyReserved`. Keep the `MsgSourceStockNotFound` null-check (`:893-894`) unchanged. |
| 2 | `service/mobile/MobileReplenishService.java` | `:739` (`fulfillMultipleUnitLoads`) | Orchestrator + **only reachable caller** of `validateUnitLoadEntry`. `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException, FacadeException})` (`:738`) — **already correct, no change**. Validates ALL ULs (`:759-768`) before FIRST reserve (`:778`); dedup HashSet (`:763-766`). Context only. |
| 3 | `service/mobile/MobileReplenishService.java` | `:902-925` (`applyExplicitSourceToOrder`) | FIRST-UL reserve. Releases template's own source reservation (`changeReservedAmount(oldStock, reservedamount.negate(), true, CODE_REPLENISHMENT_FINISHED, …)`, `:907-918`, negates the **entire** `reservedamount` — over-release), re-points source via `template.setStockunitId(...)` (`:922`). Release guarded by `reservedamount > 0` (`:909-910`). Context — no change; drives the self-source add-back + AC-6. |
| 4 | `service/StockunitBusinessService.java` | `:475`, `:478-479` (`changeReservedAmount`) | Additive reserve writer + `CANNOT_RESERVE_MORE_THAN_AVAILABLE` throw. Correct as-is. Context — no change. |
| 5 | `model/Stockunit.java` | `:54-56` (`getAvailableamount()`) | `amount − reservedamount`; **NPE-prone on NULL `reservedamount`**, so the fix uses a null-safe local instead of calling it. Context. |
| 6 | `model/Replenishorder.java` | `:76` (`getRequestedamount()`), `:148` (`getStockunitId()`, `Long`) | Used for the self-source add-back. Context. |
| 7 | `json/mobile/MultiReplenishUnitLoadDto.java` | `:54` (`getQty()` → `BigDecimal`) | Requested qty per UL. Context. |
| 8 | `src/main/resources/messages_en_US.properties` | +1 line (has `MsgTooMuchRequested :207`, `MsgSourceStockNotFound :204`; **missing** the new key) | **EDIT** — add `MsgUnitLoadStockAlreadyReserved`. |
| 9 | `service/mobile/MobileMoveUnitloadService.java` | (exists in v2) | SBDEV-2492 amplifier. Context, **do NOT touch**. |

**Fix locus = row 1 only** (`validateUnitLoadEntry`) + the new message key (row 8). Rows 2-7 are the surrounding reserve path (unchanged); row 9 is the amplifier, left alone.

---

## 2. V1 → V2 Applicability

| V1 element (v1 plan §5/§8) | V2 Verdict | Rationale |
|---|---|---|
| Fix — availability gate + self-source add-back in `validateUnitLoadEntry` | **Needed (adapted)** | Same gross gate at `:896-897`; same additive throw downstream. Credit read/arithmetic refined (see divergence below). |
| New message key `MsgUnitLoadStockAlreadyReserved` | **Needed** | v2 bundle has `MsgTooMuchRequested`/`MsgSourceStockNotFound` but not this key. |
| Single choke point (no guard in `createOrderFromTemplate`) | **Needed (same conclusion)** | v2 also validates ALL ULs (`:759-768`) before first reserve (`:778`); dedup HashSet (`:763-766`). |
| Self-source add-back keyed on `template.getStockunitId().equals(matching.getId())` | **Needed** | Same self-source edge case; `getStockunitId()` is `Long` (`:148`), `getRequestedamount()` (`:76`). |
| v1's `getAvailableamount()` read + plain `requestedamount` credit | **Refined in v2** — see divergence | v2 reads a null-safe reserved value; credit gated on `reserved>0` and capped at `min(requestedamount, reserved)`. |
| v1's `rollbackFor={BusinessException, FacadeException}` on `fulfillMultipleUnitLoads` | **Already present in v2** — NOT a NEW issue | v2's `:738` already carries `value="tenantTransactionManager"` + both `rollbackFor` classes. No annotation edit. |
| AC-1..AC-6 unit tests | **Needed (v2-adapted + extended)** | Port to `MobileReplenishServiceUnitTest` (Mockito 5, inline construction); add AC-7 (NULL reservedamount NPE guard) + AC-8 (`reserved==0` self-source no over-credit) — §6. |

### V2-specific adaptation notes

- **jakarta namespace** — already in place; no import churn in the touched region.
- **`@Transactional` already correct** — `fulfillMultipleUnitLoads:738` has `value="tenantTransactionManager"` + `rollbackFor`. **No annotation change** (unlike SBDEV-2512's Phase 0).
- **Zero new constructor dependencies** — the guard uses only instance getters on `matching`, `template`, `dto`.
- **Entity comparison** — `AbstractBaseEntity.equals` is ID-based in v2, but keep explicit `template.getStockunitId().equals(matching.getId())` (both `Long`) for null-safety/clarity (CLAUDE.md).
- **BigDecimal** — `getAmount()`, `getReservedamount()`, `getRequestedamount()`, `getQty()` are `BigDecimal`; use `compareTo`/`min`, never `==`.
- **No `mockStatic`** — Mockito 5 available, but the gate uses only instance methods; no static mocking needed.

### DIVERGENCE (intentional — condition 4, corrected framing per Critic m4)

The v2 self-source add-back **diverges** from v1. Stated honestly, the divergence is **two required refinements plus one cheap defense-in-depth cap**:

1. **Null-guard the nullable `reservedamount` (required, condition 2).** v2 computes availability as `amount − (reservedamount==null?0:reservedamount)` instead of calling `getAvailableamount()` (NPE-prone on a NULL row, §1). This is a straight correctness fix; v1's `getAvailableamount()` read would NPE in v2.
2. **`reserved > 0` guard on the credit (fixes the `reserved==0` over-credit).** For a `reserved==0` self-source, v1's plain `requestedamount` credit yields `effective = (amount − 0) + requested = amount + requested`, which **accepts** `qty > amount` and then throws downstream (degraded message + safe rollback). The `reserved > 0` guard — which also **mirrors** the release guard at `:909-910` — skips the credit for `reserved==0`, so `effective = amount`, no over-credit. **AC-8** pins this.
3. **`min(requestedamount, reserved)` cap — defense-in-depth, otherwise inert.** The cap diverges from plain `requestedamount` **only** in the atypical `0 < reserved < requested` (partial-reservation-leak) state, where it prevents a false-accept. In every known-reachable self-source state `reserved ≥ requested`, so `min(requestedamount, reserved) == requestedamount` and the cap is behaviorally **inert**.

**CRUCIAL correction (Critic m4):** the `min()` cap is **not** what makes the co-reserved case safe — **v1's plain `requestedamount` already safely rejects it.** When a self-source stock is co-reserved by the template *and another order* (`reserved > requested`, e.g. `reserved=60, requested=40`), v1 credits only `requested=40` (not the entire `reserved`), so it already rejects a `qty` in `(effective, amount]` — the safe direction. It was the **Architect's literal plain-`reservedamount`** suggestion (credit the entire `reservedamount`) that would have **broken** this safe-reject (crediting 60 → accept the request that "succeeds" only by riding `applyExplicitSourceToOrder`'s over-release and silently destroying the other order's reservation). So `min()` is best read as **"`requestedamount`, capped at `reserved`"** — identical to v1's credit wherever `reserved ≥ requested` (all known-reachable states), differing only to prevent a false-accept in the unproven partial-leak state.

> **Sweep note (do NOT "correct"):** the v1↔v2 pair **no longer shares identical guard arithmetic** (null-safe read + `reserved>0` guard + `min` cap). A future v1→v2 sync sweep must **not** rewrite the v2 form back to v1's plain `getAvailableamount()`/`requestedamount`. Recorded as a one-line entry in [[2026-07-10-wms-v1-sync]] (§11 docs-to-update).

### NEW v2-only issues

**NONE in the touched region.** Two v2-only **observations** are documented (no action):
- **(a) `applyExplicitSourceToOrder` release guard `reservedamount > 0` (`:909-910`).** v1 negates unconditionally; v2 guards with `reservedamount > 0`. Equivalent for the self-source case (a template holding its own source has `reservedamount ≥ requestedamount > 0`, so it still releases). The v2 guard is deliberately **mirrored** in the add-back's `reserved > 0` condition so guard and release agree. The release still negates the **entire** `reservedamount` (over-release, `:913`) — same as v1; out of scope here (§9 follow-up).
- **(b) `entityManager.refresh(inst.stock)` (`:793`).** Optimistic-lock resync after `createOrderFromTemplate`'s `REQUIRES_NEW` reserve. Context only; not on the guard's path.

**SBDEV-2492 amplifier** — `MobileMoveUnitloadService` exists in v2; moving a reserved UL no longer cancels its open replen, enlarging the reserved-yet-selectable pool. **Context only — do NOT touch.**

---

## 3. Design (changes by file)

### File 1 — `service/mobile/MobileReplenishService.java` (`validateUnitLoadEntry`, `:876-900`)

Replace the gross gate. Keep the `MsgSourceStockNotFound` null-check (`:893-894`) unchanged above it.

**Before (`:893-899`):**
```java
if (matching == null) {
    throw new FacadeException("MsgSourceStockNotFound");
}
if (matching.getAmount().compareTo(dto.getQty()) < 0) {              // GROSS — bug
    throw new FacadeException("MsgTooMuchRequested");
}
return new MultiUnitLoadInstruction(dto, matching, unitload);
```

**After:**
```java
if (matching == null) {
    throw new FacadeException("MsgSourceStockNotFound");
}
// Validate AVAILABILITY (amount − reservedamount), not gross amount. A UL whose stock is already
// reserved by another open replenishment must be rejected here so the operator picks a different UL,
// instead of exploding downstream in changeReservedAmount with CANNOT_RESERVE_MORE_THAN_AVAILABLE (0.0000).
// NOTE: reservedamount is a NULLABLE column — do NOT call getAvailableamount() unguarded (NPE on a NULL row).
BigDecimal reserved = matching.getReservedamount() == null
        ? BigDecimal.ZERO : matching.getReservedamount();
BigDecimal effectiveAvailable = matching.getAmount().subtract(reserved);   // null-safe availability
// Self-source exception: if this UL's stock IS the template order's own current source, its reservation
// WILL be released by applyExplicitSourceToOrder before we reserve — so credit back the template's own
// share. Credit = requestedamount, capped at `reserved` (min): the reserved>0 guard mirrors the release
// guard at :909-910 and prevents a reserved==0 over-credit; the min() cap is inert where reserved>=requested
// (all known-reachable states) and only prevents a false-accept in the atypical 0<reserved<requested leak.
if (template.getStockunitId() != null
        && template.getStockunitId().equals(matching.getId())
        && template.getRequestedamount() != null
        && reserved.compareTo(BigDecimal.ZERO) > 0) {
    effectiveAvailable = effectiveAvailable.add(template.getRequestedamount().min(reserved));
}
if (effectiveAvailable.compareTo(dto.getQty()) < 0) {
    throw new FacadeException("MsgUnitLoadStockAlreadyReserved", String.valueOf(effectiveAvailable));
}
return new MultiUnitLoadInstruction(dto, matching, unitload);
```

**Credit-term worked cases (honest — most rows equal v1's plain `requestedamount`).**

| Case | amount / reserved / requested | v2 credit `min(req,res)` | v1 credit (plain req) | v2 effective | qty | Result | Diverges from v1? |
|---|---|---|---|---|---|---|---|
| Full self-source (AC-4) | 12 / 12 / 12 | 12 | 12 | 12 | 12 | **PASS** | No (`min==req`) |
| Co-reserved short (AC-5) | 12 / 12 / 5 | 5 | 5 | 5 | 12 | **REJECT** (SAFE) | No — **v1 already safe-rejects** (credits 5, not 12) |
| `reserved==0` self-source (AC-8) | 12 / 0 / 8 | credit **skipped** (`reserved>0` guard) | 8 (over-credit, no guard) | 12 | 15 | **REJECT** | **Yes — via the `reserved>0` guard, NOT `min()`** |
| Co-reserved big | 100 / 60 / 40 | `min(40,60)=40` | 40 | 80 | 90 | **REJECT** (SAFE) | No — **v1 already gives 40** (`min==req`) |
| Partial-leak (min's ONLY effect) | 12 / 3 / 5 | `min(5,3)=3` | 5 (false-accept → 14≥13) | 12 | 13 | **REJECT** | **Yes — the `min()` cap**; reachable only if `0<reserved<requested` |

So the Architect's ceiling-matching goal is met in every safe case, while the credit refuses to ride `applyExplicitSourceToOrder`'s over-release; the Architect's literal plain-`reservedamount` (credit 60 in the co-reserved-big row) would have wrongly **accepted** it.

### File 2 — `src/main/resources/messages_en_US.properties`
```properties
MsgUnitLoadStockAlreadyReserved=Unit load stock is already reserved (%1$s available). Choose a different unit load.
```

### Later-position self-source — why no `createOrderFromTemplate` guard is needed (M-1, unchanged)

The runtime survival of a self-source UL scanned in a **later** position (`i≥1`) is **not** the add-back's doing. `applyExplicitSourceToOrder` (`:778`) is always invoked with `order = template` and releases `order.getStockunitId()`'s **entire** reservation (`:907-918`) — the template's *old* source. Since "self-source" means the selected UL's stock **is** `template.getStockunitId()`, that stock's `reservedamount` is zeroed at `:778` regardless of scan position; only then does `createOrderFromTemplate` (`:786`) re-reserve it. The non-first self-source path survives because of the unconditional old-source release at `:778`, **not** the credit.

> **Load-bearing dependency (M-1):** relies on `applyExplicitSourceToOrder` releasing `order.getStockunitId()` (not `first.stock`). If a future refactor narrowed that release to only the first UL's stock, a later-position self-source would throw again. **AC-6** pins this.

> **Load-bearing ordering (Critic minor):** self-source detection at validation time is correct **only because the validate-all loop (`:759-768`) runs BEFORE `applyExplicitSourceToOrder` mutates `template.setStockunitId(...)` at `:922`.** If validation ever moved after the first reserve, the self-source key would compare `template.getStockunitId()` against the *re-pointed* source and mis-classify. Keep validation strictly before the first reserve.

### Resulting behavior matrix

| UL selected | Before (today) | After |
|---|---|---|
| Stock available ≥ qty (free UL) | passes → reserves OK | **unchanged** — passes |
| Stock reserved by **another** open replen (available < qty, gross ≥ qty) | passes gate → `CANNOT_RESERVE_MORE_THAN_AVAILABLE (0.0000)` downstream | **rejected at entry** with `MsgUnitLoadStockAlreadyReserved (<avail>)` |
| Stock IS the **template's own** source, `reserved>0` (held by this template) | passes (gross) then reserves OK after self-release | **still passes** — credits `min(requestedamount, reserved)` (AC-4/AC-6) |
| Self-source with `reserved==0`, `qty > amount` | passes gross then throws | **rejected** — `reserved>0` guard skips credit, no over-credit (AC-8) |
| `reservedamount` is NULL (never reserved) | passes gross | **passes** — null-safe reserved read, no NPE (AC-7) |
| Gross stock < qty (genuinely too little total) | rejected `MsgTooMuchRequested` | rejected `MsgUnitLoadStockAlreadyReserved` (availability ≤ gross; message key changes) |

**Exception mapping (confirm, no caller change):** `FacadeException` → **HTTP 422** via `RestExceptionHandler` (not 500). The mobile UI already renders `FacadeException` messages from this endpoint (same path as `MsgTooMuchRequested`/`MsgSourceStockNotFound`), so no UI change is required.

---

## 4. Prerequisites (§5.1)

| # | Prerequisite | Applies? | Detail |
|---|---|---|---|
| 1 | **Database state** (schema / Flyway) | **N/A** | No schema/DDL/Flyway change. `stockunit.amount`/`reservedamount` already exist (the fix null-guards the already-nullable `reservedamount`). |
| 2 | **Feature flags / system properties** | **N/A** | No sysprop toggle. Pure correctness fix; old behavior is a defect, not a configurable mode. |
| 3 | **Config / env changes** | **N/A** | None. |
| 4 | **Deploy-order dependencies** | **N/A** | Single wms2-api JAR. New message key is server-rendered; UI already surfaces `FacadeException` messages from this endpoint. |
| 5 | **Data migration** | **N/A** | Data-independent code logic; no data mutated. |
| 6 | **External systems** | **N/A** | None. |
| 7 | **Access / permissions** | **N/A** | No endpoint/authority change. |
| 8 | **Monitoring / alerts** | Optional | Optionally watch for a rise in `MsgUnitLoadStockAlreadyReserved` rejections replacing the pre-fix `CANNOT_RESERVE_MORE_THAN_AVAILABLE` failures. No new metric required. |

**Summary:** pure code-logic fix + one message key; no DB/Flyway/sysprop/deploy-order/data-migration dependency.

---

## 5. Implementation Priority & Checklist

**Branch:** `port/260709-multiul-replen-availability` off `develop`, **non-stacked**. Open PRs #66 (sku-normalization), #67 (palletize-guard), #68 (partitionallowed-guard) touch disjoint files — **none** touches `MobileReplenishService` or `messages_en_US.properties` (implementer to verify at branch time).

- [ ] **S1** — add `MsgUnitLoadStockAlreadyReserved` to `messages_en_US.properties`. `mvn clean compile`. Commit.
- [ ] **S2** — edit `validateUnitLoadEntry` (`:893-899`): keep `MsgSourceStockNotFound`; replace the gross check with the **null-safe** availability gate + self-source add-back (`requestedamount` capped at `reserved`, under `reserved>0`); throw the new key. Compile. Commit.
- [ ] **S3** — add AC-1..AC-8 unit tests (§6) to `MobileReplenishServiceUnitTest` (inline entity construction, no helper factories; assertion style + mock arrangement per §6). `mvn test -Dtest=MobileReplenishServiceUnitTest`.
- [ ] **S4 — post-mvn sanity confirmation (NOT an expected-breakage step; corrected per Critic M2).** The new gate lives in the **private** `validateUnitLoadEntry`, reachable **only** via `fulfillMultipleUnitLoads` (`:767`). The **only** `fulfillMultipleUnitLoads` tests are at `:477-528` (null/empty/duplicate guards that throw **before** validation). The tests at `~:1240-1859` are the `checkSource` (`~:1240-1439`) and `finishReplenishmentOrder` (`~:1440-1859`) nested classes — **single-order** methods that never call `validateUnitLoadEntry`. **Therefore NO existing unit test drives the guarded reserve path, and NO re-seed is required** — the "reserved-by-another tests now reject" breakage does **not** exist. After `mvn`, simply confirm the existing suite is green (sanity), no edits expected.
  - **DO-NOT-TOUCH fence (executor / tdd-gate):** the `checkSource` / `finishReplenishmentOrder` nests — **especially the tests around `:1673-1729`** that assert "release only the order's `requestedamount`, not the stock's total `reservedamount`" (e.g. verifying a `-10`, not `-50`, release). These are **deliberate regression pins for a PRIOR fix**; do **not** edit them. Note they exercise `finishReplenishmentOrder` — a **different** method from multi-UL `applyExplicitSourceToOrder`, so they do **not** contradict the m-2 over-release premise (`applyExplicitSourceToOrder:913` still negates the entire `reservedamount`; the two release paths differ).
- [ ] **S5** — author `verify-260709-multi-unitload-replen-reserve-availability-guard-v2.sh` (§10). Compile.
- [ ] `bash sbdocs/9-System/scripts/verify-260709-multi-unitload-replen-reserve-availability-guard-v2.sh` → `Result: N pass, 0 fail`.
- [ ] Code review.

---

## 6. Testing Plan / Acceptance Criteria (wms-tdd-gate consumable)

**Test class:** `src/test/java/net/aim_ai/wms/unit/service/mobile/MobileReplenishServiceUnitTest.java` — extends `BaseServiceUnitTest`, `@InjectMocks mobileReplenishService`, injected mocks incl. `unitloadRepository`, `stockunitRepository`, `replenishorderRepository`, `replenishGeneratorService`, `stockunitBusinessService`, `locationRepository`, `itemdataRepository`, `entityManager`.

**Construction convention (mirror the suite — do NOT introduce helper factories).** Existing tests build `Stockunit`/`Replenishorder` **inline** (`stock.setReservedamount(...)`, `when(...).thenReturn(List.of(stock))`). **Template setup (m-4):** AC-4/AC-5/AC-6/AC-8 MUST call `template.setStockunitId(...)` **and** `template.setRequestedamount(...)` — a null-source template skips the add-back branch.

### Assertion style (Critic M1 — critical for red-first correctness)

`FacadeException(String key, Object parameter)` sets `getMessage()` to `"<key>:<parameter>"` (e.g. `"MsgUnitLoadStockAlreadyReserved:12"`); **there is no `getKey()` accessor.** Therefore every **throwing** AC (AC-1 / AC-3 / AC-5 / AC-8) MUST assert:

```java
assertThatThrownBy(() -> mobileReplenishService.fulfillMultipleUnitLoads(request, ...))
    .isInstanceOf(FacadeException.class)
    .hasMessageContaining("MsgUnitLoadStockAlreadyReserved");
```

- **NEVER** `.hasMessage("MsgUnitLoadStockAlreadyReserved")` — the `":<effectiveAvailable>"` suffix makes an exact-match fail even after the correct fix.
- **NEVER** a bare `.isInstanceOf(FacadeException.class)` — today's gross gate throws `MsgTooMuchRequested`, **also** a `FacadeException`, so a loose assertion is **green pre-fix** and destroys red-first (this is exactly the AC-8 trap). The `hasMessageContaining` on the **new** key is what makes AC-1/3/5/8 red today (message is the wrong/other key) → green after the fix.

### Required mock arrangement (Critic m3)

Every AC drives the **public** `fulfillMultipleUnitLoads` (the target `validateUnitLoadEntry` is private). A red-stage test that reaches past validation proceeds into `applyExplicitSourceToOrder` → `locationRepository.findById(...).orElseThrow()` (`:925`) and `finishReplenishmentOrderWithoutRefill`, which throw `EntityNotFoundException` **without stubs** (still red, but for an *incidental* reason → the true green is unreachable). Arrange the prologue so each AC reaches a clean verdict:

- **All ACs (pre-validation prologue):** `replenishorderRepository.findById(orderId)` → `template`; the destination-resolution deps used by `assignDestinationForMultiUnitLoads`; `unitloadRepository.findById(ulId)` → the UL; `stockunitRepository.findByUnitloadId(ulId)` → `[matching]`.
- **Self-source ACs (AC-4/AC-5/AC-6/AC-8):** additionally `stockunitRepository.findById(template.getStockunitId())` → the source stock; `locationRepository.findById(...)` for the source/destination location.
- **Accept-path ACs (AC-2/AC-4/AC-6/AC-7):** additionally stub the reserve collaborators — `stockunitBusinessService.changeReservedAmount(...)`, `replenishGeneratorService.createOrderFromTemplate(...)`, the `buildMobileDto` / `finishReplenishmentOrderWithoutRefill` collaborators, and `entityManager.refresh(...)` — so the accept path completes without an incidental `EntityNotFoundException`.
- **Rejection ACs (AC-1/AC-3/AC-5/AC-8, single-UL):** validation throws **before** the first reserve, so **only the pre-validation stubs are needed** — no reserve stubs. Assert `verify(stockunitBusinessService, never()).changeReservedAmount(...)` **AND** `verify(replenishGeneratorService, never()).createOrderFromTemplate(...)` (m-3).

### Acceptance criteria

| AC | Statement | Gate type |
|----|-----------|-----------|
| **AC-1** | Reserved-by-another: matching `amount=48, reserved=48` (avail 0), `qty=12`, `template.stockunitId ≠ matching.id` → `hasMessageContaining("MsgUnitLoadStockAlreadyReserved")`; `never()` on **both** reserve paths (m-3) | **red→green** |
| **AC-2** | Free stock: `amount=48, reserved=0` (avail 48), `qty=12` → no throw, instruction built. **GREEN pre-fix** | **pinning** |
| **AC-3** | Partially reserved below qty: `amount=48, reserved=40` (avail 8), `qty=12` → `hasMessageContaining("MsgUnitLoadStockAlreadyReserved")`; same `never()` on both reserve paths (m-3) | **red→green** |
| **AC-4** | Self-source, first/sole UL: `amount=12, reserved=12`, `template.stockunitId = matching.id`, `requestedamount=12`, `qty=12` → **NO throw** (`min(12,12)=12`; effective `0+12=12 ≥ 12`). Discriminates against a naive availability-only mis-fix (would reject) | **validation-acceptance (must NOT fail first)** |
| **AC-5** | Co-reserved short self-source: `amount=12, reserved=12`, `template.stockunitId = matching.id`, `requestedamount=5`, `qty=12` → `hasMessageContaining("MsgUnitLoadStockAlreadyReserved")` (`min(5,12)=5`; effective `0+5=5 < 12` — refuses to over-credit; **same result as v1's plain `requestedamount`**) | **red→green** |
| **AC-6** | **Later-position self-source (M-1 regression pin — PRIMARY unit form).** TWO-UL request; UL#1 free `amount=24, reserved=0, qty=12`; UL#2 = template's own source `amount=12, reserved=12` (avail 0), `template.stockunitId = UL#2 stock id`, `requestedamount=12`, `qty=12`. Seed `stockunitRepository.findById(order.getStockunitId())` → the source stock with `reserved>0`. **Assert:** (a) `validateUnitLoadEntry` **ACCEPTS** UL#2 via the add-back (no `MsgUnitLoadStockAlreadyReserved` for UL#2); **AND** (b) `verify(stockunitBusinessService).changeReservedAmount(eq(<templateSource>), <negate>, ...)` — pins that **a release occurred against `order.getStockunitId()`**, i.e. the `:778` release fires regardless of scan position. **Do NOT over-read (b):** it pins the *release target*, **NOT the release amount** — with `reserved==requested==12` the negate is `-12` under either entire-`reserved` or `requested` semantics, so the AC cannot distinguish them (the m-2 over-release is explicitly out of scope). **Do NOT assert end-to-end reserve success** — `replenishGeneratorService` is a mock and `entityManager.refresh` is stubbed, so the position-2 reserve never runs (asserting it would be vacuous). True end-to-end runtime reserve deferred to the IT. | **validation-acceptance + release-target pin (must NOT fail first)** |
| **AC-7** | **NULL `reservedamount` (condition 2, NPE guard).** Free stock, `reservedamount` left **null**, `amount=48`, `qty=12`, non-self-source → **no NPE, no throw** (null-safe reserved read → effective `48 ≥ 12`; instruction built). Pins that the gate does not call `getAvailableamount()` unguarded | **validation-acceptance (must NOT fail first)** |
| **AC-8** | **`reserved==0` self-source no over-credit (condition 1 item-(b); the `reserved>0` guard, not `min()`).** `amount=12, reserved=0`, `template.stockunitId = matching.id`, `requestedamount=8`, `qty=15` → `hasMessageContaining("MsgUnitLoadStockAlreadyReserved")` (the `reserved>0` guard skips the credit → effective `12 < 15`). Discriminates against v1's plain-`requestedamount` mis-credit (which would accept `12+8=20 ≥ 15`). Assertion MUST key on the new message (bare `isInstanceOf` is green pre-fix — the M1 trap) | **red→green** |

> **wms-tdd-gate framing.** Fail-first (red→green): **AC-1, AC-3, AC-5, AC-8**. Must-NOT-fail-first (pinning / validation-acceptance): **AC-2, AC-4, AC-6, AC-7**.

> **No AC pins the `min()` cap itself (Critic m4).** `min()` diverges from `requestedamount` only in the `0 < reserved < requested` partial-leak state, whose reachability is unproven (§9 Open Question). Adding an AC to force that state would test an unproven scenario; `min()` stays as cheap, strictly-safe defense-in-depth.

### Integration (Testcontainers)

Any new `@SpringBootTest`/Testcontainers IT is **blocked / gated `@Disabled`** by the v2 IT-harness gap (**SBDEV-2217**). The **true end-to-end runtime reserve** for AC-6's later-position self-source is deferred to an IT tagged `@Disabled // TODO(SBDEV-2217)`. Acceptance meanwhile = `mvn clean compile` + the 8 unit tests + manual smoke.

### Manual test plan

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|---|
| M1 | **Reserved UL rejected** | staging | Multi-UL replenish; select a UL fully reserved by another open replen (available 0) | Rejected at entry: "Unit load stock is already reserved (0.0000 available). Choose a different unit load." — **no** `CANNOT_RESERVE_MORE_THAN_AVAILABLE` | |
| M2 | **Two free ULs succeed** | staging | Select two ULs both with available ≥ qty | Both fulfilled; two picks created; no error | |
| M3 | **Self-source reuse** | staging | Select the UL that is the template order's own current source | Succeeds (self-source add-back) — one clean pick | |
| M4 | **Mixed: one free, one reserved** | staging | Select one free UL + one reserved UL | Whole request rejected on the reserved UL (all validated before any reserve); **no** partial reservation left behind | |
| M5 | **SQL sanity after M1** | staging DB | `SELECT reservedamount FROM stockunit WHERE id = <selected UL stock>;` before/after M1 | unchanged (rejection wrote nothing) | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped |
|---------|--------|------------------------|
| `mvn clean compile` | | |
| `mvn test -Dtest=MobileReplenishServiceUnitTest` | | |
| `bash sbdocs/9-System/scripts/verify-260709-multi-unitload-replen-reserve-availability-guard-v2.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| AC-6 true end-to-end runtime reserve of the position-2 self-source | `replenishGeneratorService` mock + stubbed `entityManager.refresh` → the reserve never executes in a unit test; AC-6 pins guard-acceptance + the `:778` release *target*, and the runtime reserve defers to an IT under SBDEV-2217. |
| `min()` cap behavioral pin (`0 < reserved < requested`) | Reachability unproven (§9 Open Question); `min()` is inert where `reserved ≥ requested`. Testing an unproven state would add noise. |
| `applyExplicitSourceToOrder` over-release of the entire `reservedamount` (`:913`) | Pre-existing v2 behavior, out of scope; the `requestedamount`-capped credit already refuses to ride it (the safe direction, same as v1). §9 follow-up. |

---

## 7. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Guard rejects ULs that previously "worked" | Certain | Low | **Intended** — they always failed (`CANNOT_RESERVE_MORE_THAN_AVAILABLE`); the fix fails cleanly and actionably at entry. |
| **NPE on NULL `reservedamount`** (condition 2) | Med (nullable column, never-reserved stock) | High | Do **not** call `getAvailableamount()` unguarded; compute `amount − (reservedamount==null?0:reservedamount)`. **Pinned by AC-7.** Verify-script asserts the null-guard is present. |
| **Self-source false reject** | Low | Med | Add-back credits `requestedamount` (capped at `reserved`) under `reserved>0`; pinned by **AC-4** (first/sole) and **AC-6** (later position). Compare by ID (CLAUDE.md). |
| **`reserved==0` self-source over-credit** (wrongly accepts) | Low | Med | The `reserved>0` guard skips the credit for `reserved==0`; **pinned by AC-8**. |
| Co-reserved self-source silently leaks another order's reservation (m-2) | Low | Med | The `requestedamount`-capped credit rejects `qty > effectiveAvailable` (safe direction) — **same as v1**; the `min()` cap adds nothing here (`min==req` when `reserved≥requested`). Pre-existing over-release (`:913`) out of scope; §9 follow-up. |
| Wrong tdd-gate assertion style (loose `isInstanceOf` / exact `hasMessage`) | Med (easy mistake) | High (destroys red-first) | §6 **Assertion style** note mandates `hasMessageContaining("MsgUnitLoadStockAlreadyReserved")`; verify-script greps the throwing-AC assertions for it. |
| Incidental `EntityNotFoundException` masks the true verdict (accept-path ACs) | Med | Med | §6 **Required mock arrangement** enumerates the prologue + reserve-collaborator stubs each accept-path AC needs. |
| NPE on nullable `getStockunitId()` / `getRequestedamount()` | Low | Low | Null-guarded (`!= null` before `.equals`/`.min`); a template with no source skips the add-back. |
| New message key not rendered by UI | Low | Low | Mobile UI already renders `FacadeException` messages from this endpoint; key added to the same bundle as `MsgTooMuchRequested`. |
| Existing multi-UL tests break under the gate | **N/A (corrected, Critic M2)** | — | **No existing unit test drives `validateUnitLoadEntry`** (only the `:477-528` pre-validation guards call `fulfillMultipleUnitLoads`; the `~:1240-1859` nests are single-order `checkSource`/`finishReplenishmentOrder`). S4 is a post-`mvn` sanity confirmation, not an expected-breakage; the `:1673-1729` regression pins are fenced do-not-touch. |
| Verify grep false-fail on message-key drift | Low | Low | Verify greps a stable substring (`MsgUnitLoadStockAlreadyReserved`) of both the throw and the properties line. |

---

## 8. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Rationale / mitigation |
|---|---|---|---|
| 1 | In-JVM state | **No** | Guard reads `matching`/`template` getters in-memory; no new static/`ConcurrentHashMap`/`ThreadLocal`/Caffeine state. |
| 2 | Connection pool math | **No** | Read-only availability check inside the caller's existing tx/connection; no new pool, no held-longer connection. |
| 3 | Scheduled jobs | **N/A** | No `@Scheduled`; synchronous mobile endpoint path. |
| 4 | Long transactions | **No** | Bounded in-memory comparison; **shortens** work by rejecting before the reserve writes. No external I/O added. |
| 5 | Request affinity | **N/A** | Single request/response; no session/SSE/WebSocket affinity. |
| 6 | Retry / idempotency | **No (safe)** | On rejection nothing is written (validate-all-before-reserve); a retry re-evaluates live stock. `rollbackFor` on `:738` already unwinds partial work on throw. |
| 7 | Tenant context | **No** | Existing tenant-scoped request thread inside `tenantTransactionManager`; no new async boundary. |
| 8 | Distributed lock correctness | **No (unchanged)** | Existing pessimistic/optimistic locking on the reserve path (`changeReservedAmount`, `entityManager.refresh :793`) unchanged; the guard adds no lock. |
| 9 | Cache invalidation | **N/A** | Reads no cached entity; availability computed over freshly-loaded stock. |
| 10 | External notifications | **No** | Guard only throws a `FacadeException`; no OMS/printer/message call added inside the tx. |

### Evidence (Yes rows)
| Concern # | Verified | Reference |
|-----------|----------|-----------|
| — | No "Yes" rows | Guard is a read-only in-memory availability comparison inside the existing tenant tx; locking on the reserve path unchanged. |

---

## 9. ADR (consensus record)

- **Decision:** Port the v1 availability-guard as a **single-locus edit** to v2's private `validateUnitLoadEntry` (`:876-900`): replace the gross gate (`:896-897`) with a **null-safe** availability gate (`amount − (reservedamount==null?0:reservedamount)`, NOT `getAvailableamount()`) plus a self-source add-back crediting **`requestedamount` capped at `reserved`, under `reserved>0`**, throwing a new `FacadeException("MsgUnitLoadStockAlreadyReserved", <effectiveAvailable>)`; add the message key. **No `@Transactional` change** (v2's `:738` already carries `value="tenantTransactionManager"` + `rollbackFor`). Zero new constructor deps.
- **Drivers:** (1) same root cause + gross-vs-available gap reproduces in v2 verbatim; (2) validate-all-before-reserve (`:759-768` before `:778`) + dedup HashSet (`:763-766`) → one guard covers both reserve paths; (3) v2 already has `rollbackFor` → clean port, zero NEW issues (contrast SBDEV-2512's NEW-1); (4) v2's nullable `reservedamount` + the `reserved==0` over-credit force two real credit-read refinements.
- **Alternatives considered:**
  - *Cross-order release / re-point* — **rejected** (silently invalidates another operator's in-flight order; unsafe).
  - *Fix downstream in `changeReservedAmount`* — **rejected** (already correct; moving rejection earlier gives an actionable message and keeps the invariant guard as a failsafe).
  - *Reuse `MsgTooMuchRequested`* — **rejected** ("So much amount is not available" does not tell the operator the UL is *reserved*; dedicated key is clearer; fallback only if adding one is undesirable).
  - *Second guard in `createOrderFromTemplate`* — **rejected** (redundant; single choke point sufficient; keeps the diff minimal).
  - *v1's `getAvailableamount()` read + plain `requestedamount` credit, ported verbatim* — **rejected for v2** on two counts: (a) `getAvailableamount()` NPEs on the nullable `reservedamount`; (b) plain `requestedamount` over-credits a `reserved==0` self-source → accepts `qty>amount` then throws downstream. **Note:** v1's plain `requestedamount` was **already correct** for the co-reserved (`reserved>requested`) case — it credits only `requested`, not the entire `reserved`.
  - *Architect's literal plain-`reservedamount` (entire reservation) credit* — **rejected**: it matches the `changeReservedAmount:478` ceiling, but that ceiling reflects `applyExplicitSourceToOrder`'s **over-release** of the entire `reservedamount` (`:913`); crediting the full `reservedamount` would make the guard **ACCEPT** a co-reserved self-source request that "succeeds" only by silently destroying another order's reservation — regressing the safe-reject v1 already had.
- **Why chosen (credit term = `requestedamount` capped at `reserved`, under `reserved>0`):** equals v1's credit in every known-reachable state (`reserved ≥ requested` → `min == requested`); the `reserved>0` guard fixes the `reserved==0` over-credit (AC-8) and mirrors the release guard at `:909-910`; the `min()` cap is cheap defense-in-depth that additionally prevents a false-accept in the atypical `0<reserved<requested` partial-leak state and is otherwise inert. The refinement satisfies the Architect's ceiling-matching goal for safe cases while **refusing** the over-release the ceiling reflects.
- **Consequences:** one method edit + one message key + AC-1..AC-8 + a post-`mvn` sanity confirmation (S4 — no re-seed, no expected breakage). No API/DTO/schema/sysprop change; new message key is additive. **One intentional v1↔v2 divergence** (null-safe read + `reserved>0` guard + `min` cap) recorded so a future sweep does not "correct" it back to v1's `getAvailableamount()`/plain `requestedamount`. Two documented v2 nuances (`reservedamount>0` release guard `:909-910`; `entityManager.refresh :793`).
- **Open Question (Critic m4):** is `0 < reserved < requested` reachable for a self-source template (a partial reservation leak)? If provably **unreachable**, the `min()` cap is pure inert defense-in-depth and could be simplified to plain `requestedamount`; if **reachable**, `min()` prevents a false-accept. Left as `min()` (cheap, strictly-safe) pending that determination. (Critic addendum: also covers the `reserved > requested` self-source-with-foreign-share sliver — false-*reject* there is the safe direction, inside the settled `min()` design.)
- **Consensus:** Architect **SOUND-WITH-CONDITIONS** (4 conditions: (1) credit-term synthesis; (2) null-guard + AC-7 + verify check; (3) AC-6 lighter unit form as plan-of-record; (4) divergence documented). **The credit term is recorded as an ACCEPTED, REASONED OVERRIDE of the Architect's literal plain-`reservedamount` suggestion** — the ceiling-matching goal is met for safe cases while refusing the over-release the ceiling reflects. Critic **ITERATE → revised → APPROVE** (M1 assertion style + verify grep; M2 S4 rewrite + do-not-touch fence + risk-row reclass; m3 per-AC mock arrangement; m4 honest `min()`-is-inert framing + no forced AC + Open Question; AC-6 release-*target* clarification; load-bearing ordering note) — all folded and confirmed.
- **Follow-ups:** scope `applyExplicitSourceToOrder`'s release (`:913`) to the template's own `requestedamount` share rather than the entire `reservedamount` (pre-existing over-release; separate investigation); resolve the `min()` Open Question; re-enable the AC-6 runtime-reserve IT when SBDEV-2217 lifts.

---

## 10. Acceptance Script

`sbdocs/9-System/scripts/verify-260709-multi-unitload-replen-reserve-availability-guard-v2.sh` (authored with this plan; baseline all-FAIL). Adapts the v1 script (same-named without `-v2`) — read it as the pattern. `PROJECT_ROOT` defaults to `/home/nampark/dev/wms-claude/v2/wms2-api`. All greps into `validateUnitLoadEntry` are **method-scoped** (span from the `validateUnitLoadEntry` signature to its closing brace via `awk`/`grep -Pzo`), since the same tokens appear legitimately elsewhere (gross `getAmount().compareTo` near `:325` and `:516`, and in `applyExplicitSourceToOrder`):

- **G1a (positive):** availability computed via a **null-safe** reserved read — `getReservedamount()` null-check (or `reservedOrZero`) **and** `getAmount().subtract(` — inside `validateUnitLoadEntry`.
- **G-null (positive, condition 2):** a `reservedamount` NULL-guard (`getReservedamount() == null`, ternary, or helper) is present in `validateUnitLoadEntry` — i.e. `getAvailableamount()` is **not** called unguarded there.
- **G1neg (negative, method-scoped):** the OLD gross check `getAmount().compareTo(dto.getQty())` is **GONE from `validateUnitLoadEntry`**.
- **G2a (positive):** self-source compares `template.getStockunitId()...equals(...getId())` inside `validateUnitLoadEntry`.
- **G2b (positive, condition 1):** the credit caps at `reserved` — `.add(...getRequestedamount()...min(...))` (the `min` term) is present.
- **G2c (positive, condition 1):** the `reserved > 0` guard (`compareTo(BigDecimal.ZERO) > 0` or equivalent) gates the add-back.
- **G3a/G3b:** `MsgUnitLoadStockAlreadyReserved` present in both the throw (`MobileReplenishService.java`) **and** `messages_en_US.properties` (`^MsgUnitLoadStockAlreadyReserved=`).
- **G-assert (positive, condition M1):** in `MobileReplenishServiceUnitTest`, the throwing-AC assertions grep for `hasMessageContaining` (or equivalent message-substring assertion) on `MsgUnitLoadStockAlreadyReserved` — i.e. the ACs key on the **new message**, not just the exception type (guards against the loose-`isInstanceOf` red-first trap).
- **Behavioral gate:** `mvn test -Dtest=MobileReplenishServiceUnitTest` incl. **AC-4**, **AC-6**, **AC-7**, **AC-8**. Gate = `mvn clean compile` + this targeted test.
- **sdkman lesson (from unit 3):** the script sources `"$HOME/.sdkman/bin/sdkman-init.sh"` under `set -u`; wrap that source in `set +u` … `set -u` to avoid an unbound-variable abort inside sdkman-init.
- Acceptance = `Result: N pass, 0 fail`.

### Recommended OMC composition (for implementation)

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | Single fix locus + a message key + 8 tests + a post-mvn sanity check; single subsystem. |
| **Pre-draft step** | none | Root cause traced + DB-verified in v1; v2 loci directly verified. |
| **Plan-review step** | critic | Standard+ — this ralplan loop's Architect + Critic. |
| **Implementation shape** | executor (TDD-gated via `wms-tdd-gate`) | One coherent change; verify script is the exit gate. |
| **Verification step** | verify-script + verifier | Mandatory. |
| **Code-review step** | code-reviewer | Touches a reservation gate — one review pass. |
| **Commit step** | git directly | Single logical change (message + fix + tests). |

---

## 11. Implementation Status

**Implemented 2026-07-10.** v1→v2 port of `1ff0d85` (260709 multi-UL replenish availability guard).

- **Branch / commits / PR:** `port/260709-multiul-replen-availability` @ `7ecc204` (production + message key) + `b8cd2fa` (tests) → **PR [#69](https://github.com/SiteBossInc/wms2-api/pull/69)** into `develop` (**open, pending merge**; non-stacked, disjoint from open PRs #66/#67/#68).
- **Code changes (v2/wms2-api):**
  - `service/mobile/MobileReplenishService.java` — `validateUnitLoadEntry`: replaced the GROSS gate with a **null-safe** availability gate (`amount − (reservedamount==null?0:reservedamount)`, not `getAvailableamount()`) + self-source add-back crediting `requestedamount` capped at `reserved` under `reserved > 0`; throws `FacadeException("MsgUnitLoadStockAlreadyReserved", <effectiveAvailable>)`. `MsgSourceStockNotFound` null-check unchanged. **No** `@Transactional` change; **no** second guard in `createOrderFromTemplate`.
  - `messages_en_US.properties` — added `MsgUnitLoadStockAlreadyReserved=Unit load stock is already reserved (%1$s available). Choose a different unit load.`
- **Tests:** `MobileReplenishServiceUnitTest` — new `PartitionAvailabilityGuard` suite (8: AC-1/AC-3/AC-5/AC-8 red→green with `hasMessageContaining("MsgUnitLoadStockAlreadyReserved")`; AC-2/AC-4/AC-6/AC-7 validation-acceptance). Accept-path collaborators in the shared prologue helpers marked `lenient()` (unreached on the reject path). No existing test modified; the `checkSource`/`finishReplenishmentOrder` regression pins fenced do-not-touch (**no re-seed needed** — confirmed). **`Tests run: 89, Failures: 0, Errors: 0`** (`mvn test -Dtest=MobileReplenishServiceUnitTest`, SDKMAN). `mvn clean compile` SUCCESS.
- **Verify script:** `bash sbdocs/9-System/scripts/verify-260709-multi-unitload-replen-reserve-availability-guard-v2.sh` → **`Result: 10 pass, 0 fail, 0 skip`** (G1a/Gnull/G1neg/G2a/G2b/G2c/G3a/G3b/Gassert + the mvn behavioral gate). One impl adjustment: the 4 red ACs errored with `UnnecessaryStubbingException` (post-fix they short-circuit at `validateUnitLoadEntry` before the finish/reserve/source-release stubs) → those conditionally-reached shared-helper stubs marked `lenient()`.
- **Review lane:** Planner → Architect SOUND-WITH-CONDITIONS (4 folded, incl. a reasoned override of the Architect's literal plain-`reservedamount` credit rec) → Critic ITERATE (M1/M2/m3/m4) → revised → Critic APPROVE → `wms-tdd-gate` (8 tests, 4 red-right baseline) → ralph → `code-reviewer` **APPROVE** (0 HIGH / 0 MEDIUM; 2 LOW pre-existing `dto.getQty()`/`amount` null assumptions, not regressions).
- **Integration tests:** none added; existing lane remains `@Disabled TODO(SBDEV-2217)`; AC-6 true end-to-end runtime reserve deferred there.
- **Docs updated (sbdocs, not in git):** `workflows/wms2-multi-unitload-replenish.md` (Behavior Guarantees availability-guard note + v1/v2 divergence, `last_verified` 2026-07-10); `2-Areas/wms-v1-v2-sync/sweeps/2026-07-10-wms-v1-sync.md` (unit-4 record + intentional-divergence callout).
