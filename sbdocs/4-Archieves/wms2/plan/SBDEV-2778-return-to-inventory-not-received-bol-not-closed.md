---
title: "SBDEV-2778 — Return to Inventory does not fully receive and close the return inbound BOL"
ticket: "SBDEV-2778"
ticket_url: "https://app.clickup.com/t/868kj2bv4"
type: "bug"
priority: "urgent"
status: "archived"
project:
  - wms2-api
version: "v2"
requester: "Brent Campbell"
created: "2026-07-30"
updated: "2026-08-04"
related:
  - SBDEV-2236-return-advice-auto-receive-fix
  - wms2-transaction-osiv-boundary-map
  - wms2-state-machine-catalog
  - wms2-oms-integration-map
  - wms-exception-taxonomy
tags:
  - plan
  - wmsv2
  - returns
db_verified: true
---

# SBDEV-2778 — Return to Inventory does not fully receive and close the return inbound BOL

**Ticket:** [SBDEV-2778](https://app.clickup.com/t/868kj2bv4)
**Project:** wms2-api (WMS only — no OMS change) | **Version:** v2 | **Type:** bug
**Priority:** urgent
**Status:** reviewed — **consensus: BA-approved direction + Critic pass complete (REVISE → 12 findings, all addressed 2026-08-03).**
⚠ **Caveat on that status:** the Critic enumerated an explicit upgrade path and every item on it was addressed, but it did **not** re-review the
revisions. Phases 3a (verifier) and 3b (code-reviewer) are the independent lanes that must catch anything the revisions got wrong.
**Date:** 2026-07-30 · **rewritten 2026-08-03**
**Assignees:** Nam Park, David Oppenheim

> ## 📦 ARCHIVED 2026-08-04 — shipped
>
> Merged to `develop` via PR [wms2-api#123](https://github.com/SiteBossInc/wms2-api/pull/123),
> merge commit `8c8debc`. ClickUp [SBDEV-2778](https://app.clickup.com/t/868kj2bv4) → **on dev**.
> Shipped as Flyway **`V2.2.09`** — not `V2.2.08` as this plan's body says throughout; `V2.2.08`
> was taken by SBDEV-2801 before this branch merged, so every `V2.2.08` reference below should be
> read as `V2.2.09`.
>
> The seeded `los_sysprop.description` is 227 chars, under the varchar(255) limit that would
> otherwise raise `22001` and abort the tenant's whole migration chain — guarded in-repo by
> `SyspropMigrationDescriptionWidthTest`.
>
> ⚠ **This shipped default-ON and takes effect on every tenant regardless of migration state.**
> The flag seeds `'true'` (unlike every other toggle in this chain) *and* the read is
> `!"false".equalsIgnoreCase(...)`, so an absent row also means ON. Rollback is per-tenant
> `sysvalue='false'`, effective within the `sysprops` cache TTL (~2 min Caffeine; immediate under
> the `redis` profile).
>
> Acceptance script retired to
> `sbdocs/4-Archieves/scripts/verify-SBDEV-2778-return-to-inventory-not-received-bol-not-closed.sh`
> Implementation worktree removed 2026-08-04: `wms2-api/SBDEV-2778` (+ `.verify-root/SBDEV-2778`)

> ## ⚠️ THIS PLAN SUPERSEDES SBDEV-2236 — READ FIRST
>
> **BA decision (Brent Campbell, confirmed 2026-08-03): restore the v1 behavior. WMS v2 must
> auto-receive and close a `type=RETURN` advice at creation time, exactly as
> `v1/wms-api` does today.** This **nullifies**
> [SBDEV-2236](../../../4-Archieves/wms2/plan/SBDEV-2236-return-advice-auto-receive-fix.md)
> (merged 2026-05-15, PR [wms2-api#24](https://github.com/SiteBossInc/wms2-api/pull/24), commit
> `7f9c250`), which deliberately deleted that block.
>
> This is a **deliberate reversal of a merged, DB-verified decision**, made by the BA who owns the
> requirement. It is not an accident and must not be "corrected" by a future reviewer citing 2236.
> SBDEV-2236's plan doc and verify script are **retired** by this ticket — see §6.2 step 11 and R6.
>
> **What this plan is NOT:** a `git revert` of `7f9c250`. v1's block contains a defect worse than the
> bug in this ticket (§2 Bug 4: it marks the advice **FINISHED while receiving nothing** when no
> printer resolves) plus three unreachable branches. This plan restores the *behavior* and fixes the
> *implementation* — see §3.
>
> **No blocking open questions remain.** The prior draft's §10-Q0 (resolved by code evidence
> 2026-07-31), §10-Q1 (the 2236 conflict) and §10-Q4 / option F (partial-receive reconciliation) are
> all closed by the BA decision — see §10 "Closed by the BA decision".

---

## 0. Affected sites (enumeration before drafting)

Enumerated by grep over `v2/wms2-api/src` and `v1/wms-api/src`, re-verified 2026-08-03. All line
numbers below were confirmed against the working tree on this date.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|---------------------|
| 1a | `controller/rest/AdviceRestController.java:198` | `adviceEntity = adviceRepository.save(adviceEntity)` — **first insertion point**: `validate()` runs immediately BEFORE this line, because nothing may be persisted before validation completes (see §3's ordering constraint and R9). | YES — THE gap | **YES** |
| 1b | `controller/rest/AdviceRestController.java:272-275` | End of the per-position save loop (`advicepositionRepository.save(position)` at `:272`); control falls through to `messageService.createMessage` at `:277`. **Second insertion point**: `bind()` + `execute()`, after the positions have ids. | YES — THE gap | **YES** |
| 2 | `controller/rest/AdviceRestController.java:151-156` | Comment "RETURN/TRANSFER advice is eventually received via the mobile /receive path" + `client.getEnablereceiving()` guard | Comment becomes wrong | **YES — rewrite comment; keep guard unchanged** |
| 3 | `json/AdviceDto.java:41-42,52-58` | `@JsonProperty("printer_id") private Long printerId` — present but deliberately unread since SBDEV-2236 | Enabler | **YES — read it (D3)** |
| 4 | `controller/rest/AdviceRestController.java:81-106` | Constructor (12 params, verified) | Enabler | **YES — add exactly ONE dep: `ReturnAdviceAutoReceiveService` (12→13). `ReceivingService`, `PrinterRepository` and the sysprop read live inside the new *service*, NOT the controller — that is the point of extracting it. Do not add unused ctor params to make a verify check green.** |
| 5 | `controller/rest/AdviceRestController.java:245-262` | `optionalBoxtype` resolution; `:247` `findByExternalid(getBoxId())`; `:261` `optionalBoxtype.get()` | Reference lookup for `validate()`; the `:261` NPE is a **separate** latent bug | **PARTIAL — `validate()` must use the same `:247` lookup. The `:261` NPE stays OUT (§10-Q10)** |
| 6a | `test/.../unit/controller/rest/AdviceRestControllerUnitTest.java:524` | `shouldCreateReturnAdviceWithoutAutoReceive` (AC1+AC3) | Asserts the absence | **YES — retarget to the kill-switch-OFF case** |
| 6b | `…:567` | `shouldCreateReturnAdviceAndIgnorePrinterId` (AC2, `setPrinterId(42L)`) | Contradicts D3 | **YES — rewrite to assert the printer IS honored** |
| 6c | `…:608` | `shouldCreateReturnAdviceInOpenState` (AC5) | Asserts the absence | **YES — invert (advice ends FINISHED)** |
| 6d | `…:650` | `shouldNotInvokeReceivingServiceForReturnAdvice` (AC1) | Asserts the absence | **YES — invert** |
| 6e | `…:686` | "should never mark advice FINISHED on create when type is RETURN" (AC3) | Asserts the absence | **YES — invert or delete as redundant with 6c** |

> **AC-numbering caution:** the `AC1`/`AC2`/`AC3`/`AC5` labels in rows 6a-6e are **SBDEV-2236's** AC ids, quoted verbatim from the existing `@DisplayName` strings. §3 Fix G and §8 use **SBDEV-2778's** own AC numbering. The two schemes are unrelated — do not try to reconcile them.
| 7 | `test/.../AdviceRestControllerUnitTest.java:58-67` | Comment "Retained post-SBDEV-2236: controller no longer injects these, but the `verify(…, never())` assertions require live mocks" + unwired `@Mock ReceivingService` / `@Mock PrinterRepository` | Stale rationale | **YES — the controller still won't inject them (they go in the service), so the mocks stay unwired; rewrite the comment to say so** |
| 8 | `controller/FileImportController.java:458` | `if (!REGULAR && !RETURN)` → `errors.add(getErrorMessage(...))` (it **accumulates an error row, it does not throw**) — file-import RETURN path is create-only | **No — v1's `FileImportController` does NOT auto-receive either** (`v1:429` is type validation only; zero `receiveGoods` / `PrinterType` hits in the whole file) | **OUT — leaving it create-only IS v1 parity; regression test only** |
| 9 | `controller/rest/AdviceRestController.java:311` `createTransfer`, `:430` `createHubAndSpoke` | Separate advice ingress paths; no RETURN auto-receive in v1 either | No | **OUT** |
| 10 | `controller/ReceivingController.java:267-284` `POST /v3/receiving/receive` → `receivingService.receiveGoods(...)` at `:284` | The operator dock-receive path; must keep working (it is the fallback when the kill switch is OFF) | No | **OUT — regression test only** |
| 11 | `service/ReceivingService.java:302-318` `receiveGoods(...)` (8-arg) | Reused as-is; signature identical to v1 `:308` | No — reused unmodified | **OUT — no edit** |
| 12 | `service/WmsConstants.java:1230,1241,1245` + the two switches (`getErrorCodeText` from `:1247`, `getErrorCodeName` from ~`:1320`) | Error-code table. **`PRINTER_NOT_AVAILABLE` does not exist** (verified — grep returns zero hits); `GENERIC_ERROR = 0`, `DEFAULT_TYPE_NOT_EXIST = 200`, `NOT_ENABLLED_FOR_RECEIVING = 500` | Enabler | **YES — add two codes (§3 Fix E)** |
| 13 | `resources/db/migration/` — head on `develop` is **V2.2.07**, but **`V2.2.08` is already claimed by SBDEV-2801** on `origin/claude/sbdev-2801-report-500-utkj8x` (not yet merged, so invisible from `develop`) ⇒ this ticket takes **V2.2.09** | Flyway chain | Enabler for the kill switch | **YES — add `V2.2.09` (§3 Fix F)** |
| 14 | `exceptions/WebserviceBusinessExceptionClientSide.java:46-51` `getErrorMap()` | Emits only `status` + `description`; `code`/`errorCodeName` are set in the ctor but never serialized ⇒ **no WMS error code has ever reached OMS** | Real defect, but cross-cutting: changes every `/rest` error body | **OUT — own ticket (§10-Q11). Decided 2026-08-03; it is no longer load-bearing here (see R1)** |
| 15 | `oms-laravel-api` (`QaReturnService.php`, `WmsApiService.php`) | Flow 1 `sendReturnRestockAdvice` and Flow 2 `receiveReturnInWms` | Both already PUT to `/rest/advice/create` — see §10-Q0 | **OUT — zero OMS changes. Both flows are fixed by the WMS-side restore alone** |

**Coverage check:** in-scope rows 1a, 1b, 2, 3, 4, 5(partial), 6a-6e, 7, 12, 13 each map to a §3 fix
and a §9 verify-script assertion. Rows 8, 9, 10, 11, 14, 15 are excluded with rationale above.

**The OMS repo drops out entirely.** The prior draft's Fix D (one OMS field) and Fix A
(`qa_confirmed` on the DTO) are **deleted** — see §3.6. Nothing ships from `oms-laravel-api`, so
there is no cross-repo deploy ordering to get wrong.

**Prior plans on this call chain:**

| Plan | Relationship |
|---|---|
| `4-Archieves/wms2/plan/SBDEV-2236-return-advice-auto-receive-fix.md` | **SUPERSEDED by this ticket.** Add a banner to it (§6.2 step 11) |
| `4-Archieves/scripts/verify-SBDEV-2236-return-advice-auto-receive-fix.sh` | **RETIRED.** Its negative assertions encode a contract the BA has reversed — see R6 |
| `4-Archieves/wms2/plan/SBDEV-2215-adviceservice-no-transaction-wrapping.md` | Related — advice-layer transaction wrapping |
| `1-Projects/wms2/plan/SBDEV-2729-system-sku-receiving-null-label-token.md` | **Active** — receiving/label-token path; agree rebase order before merge |

---

## 1. Problem Statement

In the OMS Returns QA workflow, an operator physically inspects a returned parcel, dispositions each
item, and selects **Return to Inventory**. OMS creates the return record and pushes a `type=RETURN`
inbound advice (BOL) into WMS. The advice is created — and then nothing else happens. It sits in
**Open Inbound Notices** forever.

User-visible symptoms (from the ticket):

1. The return inbound BOL remains in Open Inbound Notices instead of moving to Closed/Completed.
2. No inventory is received; on-hand quantity does not update.
3. No Unit Load is created and no Unit Load label prints.
4. Warehouse staff must reopen the inbound notice and manually receive the same inventory a second
   time — re-entering quantities and re-confirming a disposition that Return QA already captured.
5. Risk of receiving returned inventory **twice**.
6. (Separate defect, out of scope — §10-Q2) Expected Date appears one day off.

**These symptoms are SBDEV-2236's *intended* behavior.** That is the whole point of this ticket: the
BA has reviewed the intended behavior against how the warehouse actually works and rejected it.
Symptom 4 — "staff must reopen the notice and manually receive" — *is* the dock scan 2236 mandated,
and the BA's position is that re-counting goods Return QA already counted is waste, not control.

### Reproduction

1. Open the Returns workflow; locate a returned parcel.
2. Complete Return QA; mark one or more items **Return to Inventory**.
3. Complete the return.
4. Open WMS Inbound Notices → the generated return BOL is present and **Open**.

### DB verification (`db_verified: true`)

MCP `wms2-wineco-dev`, run 2026-07-30.

**Q1 — advice state distribution:**

```sql
SELECT type, state, count(*) AS n, min(created) AS oldest, max(created) AS newest
FROM advice GROUP BY type, state ORDER BY type, state;
```

| type | state | n | newest |
|---|---|---|---|
| REGULAR | FINISHED | 10292 | 2026-07-30 14:33:02Z |
| REGULAR | OPEN | 77 | 2026-07-30 14:56:51Z |
| RETURN | FINISHED | 2214 | **2025-04-22 21:21:34Z** |
| RETURN | OPEN | **1** | **2026-07-30 14:53:44Z** |

**Q2 — the repro row:**

```sql
SELECT a.id, a.number, a.externalid, a.type, a.state, a.dayofdelivery, a.created,
       ap.id AS pos_id, ap.state AS pos_state, ap.notifiedamount, ap.notifiedcases,
       ap.boxtype_id, ap.itemdata_id, ap.externalid AS pos_ext
FROM advice a LEFT JOIN adviceposition ap ON ap.advice_id = a.id
WHERE a.type = 'RETURN' AND a.state = 'OPEN';
```

> `advice id=30494322, number=IBOL012604, externalid=RETURN529599, dayofdelivery=2026-07-30,
> state=OPEN` · `adviceposition id=30494323, state=OPEN, notifiedamount=1.00, notifiedcases=1.00,
> boxtype_id=52000, itemdata_id=2915631, externalid=RETURN529599_1`

Note `boxtype_id` **is populated** on the saved position — evidence for §3 B2 (the v1 fallback chain
is unreachable on this path).

**Q3 — nothing was received:**

```sql
SELECT count(*) AS gr_rows FROM goodsreceipt
WHERE advice_id IN (SELECT id FROM advice WHERE type='RETURN' AND state='OPEN');
-- → 0
```

**Q4 — the ticket's "Returns Printer" hypothesis is REFUTED:**

```sql
SELECT id, name, type, processdefault, address FROM printer ORDER BY type, id;
```

A `processdefault = true`, `type = 'RETURN'` printer **does** exist:
`id=30346045, SB1-TestLabel1-return, http://oms.siteboss.net:631/printers/SB1-TestLabel1`.
So this is not SBDEV-2206 / printer misconfiguration.

**Q5 — second tenant, MCP `wms2-hydra-dev2`:** `RETURN/FINISHED` 9 (newest 2026-03-09), no
`RETURN/OPEN` rows.

### Reading the evidence honestly

`RETURN/FINISHED` stopping at 2025-04-22 is **not** evidence of a migration regression. Those 2,214
rows are migrated v1 data (WineCo's v2 cutover was later). The behavior was **removed on purpose** by
SBDEV-2236 on 2026-05-15, and wineco-dev has seen exactly **one** v2-era RETURN advice since — the
repro. Dev volume is far too low to characterise production impact; the code evidence in §2, not the
row counts, establishes the defect.

**The evidence asymmetry is real and should be stated plainly:** SBDEV-2236 was DB-verified over
2,215 rows; SBDEV-2778 has one dev row. What settles it is not row counts on either side but the BA's
call on which behavior the business wants. That call has been made. Row counts do not decide
requirements.

---

## 2. Root Cause Analysis

### Bug 1 — `AdviceRestController.create` has no RETURN completion step

**File:** `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java:272-275`

`create(List<AdviceDto>, Principal)` persists the `Advice` (`state=OPEN`, set before `:198`) and each
`Adviceposition` (`state=OPEN`, saved at `:272`), then falls straight through to the service-log write
at `:277` and returns `204 No Content`:

```java
                    LOG.debug("create {}", position);
                    advicepositionRepository.save(position);   // :272
                }                                             // :273 — end of per-position loop

            }                                                 // :275 — end of per-advice loop

            try {                                             // :277 — service log; nothing RETURN-specific
```

v1 completes the RETURN case here (`v1/wms-api/.../AdviceRestController.java:272-319`) — full verified
text:

```java
                if (adviceEntity.getType() == AdviceType.RETURN) {
                    List<Adviceposition> advicepositionList =
                        advicepositionRepository.findByAdviceId(adviceEntity.getId());
                    for (Adviceposition pos : advicepositionList) {
                        try {
                            Long boxtypeId = pos.getBoxtypeId();
                            if (boxtypeId == null || boxtypeId == 0L) {          // (A) DEAD — see B2
                                /* itemdata.getDefaultboxtypeId() */
                            }
                            if (boxtypeId == null || boxtypeId == 0L) {          // (B) DEAD — see B2
                                /* losSyspropRepository DEFAULT_BOX_TYPE -> boxtypeRepository.findByName */
                            }
                            Optional<Printer> printerOptional =
                                printerRepository.findByTypeAndProcessdefaultTrue(PrinterType.RETURN);
                            if (printerOptional.isPresent()) {                   // v1:307 — SILENT SKIP, no else
                                receivingService.receiveGoods(pos.getId(), null, false,
                                    pos.getNotifiedamount().intValue(),
                                    pos.getNotifiedamount().intValue(), 1, boxtypeId,
                                    printerOptional.get());
                            }
                        } catch (BusinessException | FacadeException e) {
                            throw new WebserviceBusinessExceptionClientSide(WmsConstants.GENERIC_ERROR, e);
                        }
                    }
                    advicepositionRepository.updateAdvicepositionToStateByAdviceId(   // v1:317
                        AdviceState.FINISHED, adviceEntity.getId());
                    adviceRepository.updateAdviceToStateById(                          // v1:318
                        AdviceState.FINISHED, adviceEntity.getId());
                }
```

**This absence in v2 is deliberate, not an oversight.** SBDEV-2236 deleted it (`7f9c250`, "Delete
AdviceRestController.java:286-354 … Remove now-dead fields/constructor params: ReceivingService,
PrinterRepository") on the stated requirement that physical confirmation must precede the WMS stock
increment. Five tests now enforce the absence — `AdviceRestControllerUnitTest.java:524`, `:567`,
`:608`, `:650`, `:686`.

**Why it is nonetheless the defect to fix:** the BA has ruled that Return QA *is* the physical
confirmation, and that the v1 behavior is the required behavior. The gap is therefore exactly the
deleted block, and the fix is to restore it — correctly.

### Bug 2 — `printer_id` is accepted and silently ignored

`AdviceDto.java:41-42` declares `@JsonProperty("printer_id") private Long printerId` with accessors at
`:52-58`. No caller reads it, and `AdviceRestControllerUnitTest.java:567`
`shouldCreateReturnAdviceAndIgnorePrinterId` *asserts* that it is ignored. OMS Flow 2
(`QaReturnService.php:225-242`) resolves `rep_printer_prefs.wms_return_printer_id` and sends it, so
the printer-preference feature OMS shipped for SBDEV-2206 is dead on arrival in v2. Silently
accepting a field you discard is its own defect. Note **v1 ignores it too** — honoring it is an
improvement on v1, not parity (D3).

### Bug 3 — no atomicity across positions, and external I/O inside a tenant transaction

Pre-existing structural hazard that the fix must confront rather than inherit.

- `AdviceRestController` has **no `@Transactional` anywhere** (grep: zero hits). v1's has none either.
- `ReceivingService.receiveGoods` **is** `@Transactional(value = "tenantTransactionManager",
  rollbackFor = {BusinessException.class, FacadeException.class})` at `:302`.
- So each `receiveGoods(...)` call from the non-transactional controller opens **its own** tenant
  transaction per loop iteration ⇒ **no atomicity across positions**. Position N throwing leaves
  positions 1..N−1 **committed as received** while the parent advice stays **OPEN**. This is exactly
  v1's behavior — v1's per-position `catch → GENERIC_ERROR` rethrow skips the state flips at
  `v1:317-318`, so the advice stays OPEN with some positions received.
- `receiveGoods`'s **first statement** is external CUPS HTTP I/O (verified at `:315`):

```java
    @Transactional(value = "tenantTransactionManager", rollbackFor = {...})   // :302
    public void receiveGoods(long advicePositionId, ..., Printer printer) throws ... {
        LOG.debug("start");
        if (!printService.isPrintAvailable(printer.getAddress())) {           // :315 — HTTP, in-tx
            throw new BusinessException("Printer not available. Cannot process receiving.");
        }
```

  A tenant DB connection is held across a CUPS round-trip, **once per advice position**.

Supporting facts: the two bulk state-flip queries (`AdviceRepository.java:28-32`,
`AdvicepositionRepository.java:28-32`) are `@Modifying(clearAutomatically = true)` + bare
`@Transactional` — correct, because `net.aim_ai.wms.repo.jpa` repositories inherit
`tenantTransactionManager` from `@EnableJpaRepositories` (documented exception in
`v2/wms2-api/CLAUDE.md`).

### Bug 4 — v1 marks the advice FINISHED even when it received NOTHING ⚠ do not port

**This is the reason this plan is not a `git revert`.** In v1, `receiveGoods` sits inside
`if (printerOptional.isPresent())` at `v1:307` **with no `else`**, but the two state flips at
`v1:317-318` are **outside** that guard. So on a tenant with no `processdefault` RETURN printer, v1:

1. resolves no printer,
2. silently receives **nothing** — no `goodsreceipt`, no `unitload`, no stock increment,
3. flips the advice **and every position** to `FINISHED` anyway.

The result is a **phantom-closed return**: the BOL disappears from Open Inbound Notices, no operator
is ever prompted, and the inventory is simply lost. That is strictly worse than the open BOL in this
ticket — an open BOL is visible and recoverable; a FINISHED-but-empty one is neither. §3 B1 fixes it
by throwing when no printer resolves (D2), which is also what the ticket's own error-handling section
demands.

**Verify-script obligation:** assert the state flips are unreachable when printer resolution fails
(§9 B-series). A verbatim port would silently reintroduce this.

---

## 3. Fix Design

### Design principles

1. **Restore the v1 behavior, not the v1 code.** `type=RETURN` ⇒ receive and close at create time.
   No per-request assertion field, no protocol change, no OMS change.
2. **One WMS-side kill switch** (`RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED`, **default ON**) so ops can
   disable per tenant without a redeploy. Default ON because the BA wants the function back
   everywhere; the switch exists for rollback, not for opt-in.
3. **Everything auto-receive adds as a rejection reason is checked BEFORE the first row is
   persisted** — printer resolvability, printer reachability, boxtype resolvability. See the ordering
   constraint below; this prevents a permanently-stuck return (R9).
4. **Never flip state without having received.** Bug 4 must not come back.

> ⚠ **The stronger property — "nothing that can reject this advice runs after a save" — is NOT
> delivered, and cannot be without changing the `REGULAR` path.** `adviceRepository.save(...)` commits
> at `:198`, and the pre-existing per-position validation runs *after* it at `:203-251` with **nine**
> throw sites: `reference_id` unset, `client_id` unset, position client not found, `sku` unset,
> duplicate SKU, `amount_of_bottles` null, `amount_of_bottles` negative, itemdata not found,
> `UNIT_LOAD_TYPE_BOX` missing, unknown `box_id`. Each throws with the `Advice` row already committed —
> R9's brick scenario in full — and on a multi-position advice, positions 1..K−1 are committed too
> (`:272`).
> **DECIDED (2026-08-03, D10): option (a) — `validate()` mirrors the position checks for RETURN
> advices.** The earlier draft left this as "(a) recommended / (b) accept the residual" with neither
> implemented in §5, §6.2, §8 or the verify script, which meant an implementer would silently ship (b)
> and two competent implementers would diverge. Option (b) is not acceptable because the **most common
> real failure is an unknown SKU** (`:236`, `itemdataService.findByClientIdAndItemNr` empty) — under (b)
> that commits the `Advice` row, returns 400, burns `externalid`, and every OMS retry then dies on
> `ENTITY_ALREADY_EXITS` forever (R9's brick, unrecoverable without DB surgery).
>
> `resolveRefs` already walks every position for boxtype, so the traversal exists. It additionally
> checks, **per position**: `sku` set and `itemdata` resolvable, `amount_of_bottles` non-null and
> `>= 1` (see below), `box_id` resolvable, and no duplicate SKU within the advice. The save loop's
> later re-checks become redundant-but-harmless. Cost: one duplicated validation block, which is a
> genuine drift risk — call it out in code review and keep the two in the same file order.
>
> **Still not covered, and deliberately so:** `reference_id` / `client_id` unset and the
> position-client lookup. Those throw before `:198` already, or are structural request errors that
> cannot be produced by the OMS path. Scope is "everything reachable from `QaReturnService`", not
> "every throw site in `create()`".
>
> **`amount_of_bottles = 0` is the sharp edge and it is reachable today.** `create()` rejects only
> `< 0` (`:230`: `if (advicePosition.getAmountOfBottles() < 0)`), so **zero is accepted** — but
> `ReceivingService.java:325` is `if (amountBottles < 1) throw new BusinessException(
> "argumentMustBeGreaterZero", ...)`. So a zero-quantity line passes advice creation, passes a
> printer/boxtype-only B0, and then throws *mid-`execute()`* — the R9 brick on input the endpoint's own
> contract accepts. `resolveRefs` must reject `amount < 1` for RETURN advices. (Whether OMS can emit
> zero is §10-Q12; the guard is cheap and the failure is unrecoverable, so do not wait for the answer.)

### The ordering constraint (why validation precedes persistence)

`create()` is **not** `@Transactional`, so `adviceRepository.save(adviceEntity)` at `:198` and each
`advicepositionRepository.save(position)` at `:272` are **already committed** by the time any
post-loop code runs. A validation failure *after* those saves leaves behind:

- an orphan `Advice` in `state=OPEN` holding `externalid = RETURN{parcel_id}`, and
- OMS rolling the whole return back (`QaReturnService.php:330` wraps it in
  `DB::connection('tenant')->transaction(...)`), so OMS forgets the return entirely.

The operator then retries, and the retry hits the duplicate-`externalid` guard at
`AdviceRestController.java:139-142` → `ENTITY_ALREADY_EXITS`. **The return is now unmanageable
without manual DB intervention.** This is not exotic: §6.1 prereq 2 means *every* RETURN advice 400s
on a tenant with no `processdefault` RETURN printer, so a misconfigured tenant would brick every
return it processed. Any design that validates after persisting is wrong regardless of its error
message.

Hence **Fix B0**: for `RETURN` advices with the switch ON, a read-only pre-validation pass runs over
the DTO *before* the advice is saved. The `REGULAR` path is untouched.

### Fix F — the kill switch (`RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED`, default ON)

**New file:** `resources/db/migration/V2.2.09__seed_return_advice_auto_receive_sysprop.sql`
(head is currently **V2.2.07** — verified).

Follow `V2.2.04`'s shape exactly: `nextval('public.seqentities')` for the id (never a literal),
`INSERT … SELECT … WHERE NOT EXISTS` for idempotency, `groupname = 'Operation Options'`,
`workstation = 'DEFAULT'`, `client_id = 0`. **`sysvalue` is `'true'`, not `'false'`.**

> ### ⚠⚠ LANDMINE — the house sysprop read pattern is DEFAULT-OFF and will break this flag
>
> Every existing feature flag is read as
> `Boolean.parseBoolean(syspropService.getSysvalue(KEY))`
> (`BillofladingService.java:762`, `ReplenishOrderJob.java:364`, `ReplenishGeneratorService.java:93`,
> and six more). `Boolean.parseBoolean(null) == false`, so **an absent row yields OFF**. That is
> correct for a default-OFF flag and **catastrophic here**: any tenant whose DB has not run V2.2.09
> would silently keep the bug this ticket exists to fix, and it would look exactly like the bug.
>
> **Read it default-ON instead** — one line, `org.apache.commons.lang3.StringUtils`:
>
> ```java
>     /**
>      * Default ON: only the explicit string "false" disables it. Absent row / null / blank => ON.
>      *
>      * DELIBERATELY NOT Boolean.parseBoolean(getSysvalue(...)) — that is the house pattern for the
>      * nine OTHER feature flags (BillofladingService:762, ReplenishOrderJob:364, …), all of which
>      * are default-OFF. parseBoolean(null) == false, so copying that pattern here would make every
>      * tenant missing Flyway V2.2.09 silently keep the SBDEV-2778 bug. Do not "consistency-fix" this.
>      */
>     public boolean isAutoReceiveEnabled() {
>         String raw = syspropService.getSysvalue(
>             WmsConstants.SYSTEM_PROPERTY_RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED_KEY);
>         return !"false".equalsIgnoreCase(StringUtils.trimToEmpty(raw));
>     }
> ```
>
> **Do NOT use `Boolean.parseBoolean` for this key.** §9 asserts its absence *inside this method body*
> (a file-scoped grep is evadable — see §9-R3), and §8 has dedicated tests for absent / null / blank /
> garbage / `"false"`. A reviewer pattern-matching against the other nine call sites will "fix" this
> into a default-OFF read; the Javadoc above is what stops them.

**Note on caching:** `getSysvalue` is `@Cacheable(..., unless = "#result == null")` (`:288`), so the
**absent-row case is never cached** — the default-ON path does a `los_sysprop` read on every RETURN
advice. Cheap, but it means the "row absent" manual test needs no TTL wait.

Operational notes:

- `SyspropService.getSysvalue` is `@Cacheable("sysprops")` keyed on `facilityCode + ':' + key`
  (`:288`), with a Caffeine TTL of **2 minutes** (`CacheConfig.java:36`). `@CacheEvict` on
  `setSysvalue` (`:53`) and `SystemPropertyController:92` is **JVM-local**, so on multiple replicas a
  flip takes effect on the serving pod immediately and everywhere else within ~2 min. Acceptable for
  a kill switch; state it in the runbook. Same caveat already documented on
  `ApiTimestampFormatResolver:32`.
- The gate read lives in `ReturnAdviceAutoReceiveService.isAutoReceiveEnabled()`, **not** the
  controller, so the default-ON semantics have one home and one unit test.

### Fix B — extract `ReturnAdviceAutoReceiveService`

**New file:** `service/ReturnAdviceAutoReceiveService.java`

Auto-receive does **not** go inline in the controller (that is v1's shape and it is why v1's version
is untestable). It goes in a service so validation can be a single short read-only tenant transaction
and the per-position receives stay in their own short transactions.

```java
@Service
public class ReturnAdviceAutoReceiveService {

    private static final Logger LOG =
        LoggerFactory.getLogger(ReturnAdviceAutoReceiveService.class);

    private final AdviceRepository adviceRepository;
    private final AdvicepositionRepository advicepositionRepository;
    private final ItemdataService itemdataService;
    private final BoxtypeRepository boxtypeRepository;
    private final PrinterRepository printerRepository;
    private final SyspropService syspropService;
    private final PrintService printService;
    private final ReceivingService receivingService;
    private final MeterRegistry meterRegistry;

    /**
     * Self-reference so the @Transactional phase methods below go through the Spring proxy.
     * Field-level @Lazy because constructor injection of self is not possible.
     * PRECEDENT — copy this shape exactly: CustomerorderBatchService.java:110-115, whose phase
     * methods are invoked as self.validateClubLine(...) at :825, self.finalizeClubLine(...) at :856.
     */
    @Lazy
    @Autowired
    private ReturnAdviceAutoReceiveService self;

    /** Default ON — see the LANDMINE box in §3 Fix F. Never Boolean.parseBoolean for this key. */
    public boolean isAutoReceiveEnabled() { /* see Fix F */ }

    /**
     * Phase 0 (Fix B0) — validate EVERYTHING that can reject this advice, BEFORE the caller
     * persists anything. Operates on the DTO, resolves the printer, asserts the printer is
     * REACHABLE, and resolves a boxtype + a receivable amount for every position. Throws => caller
     * has saved no advice row, so no externalid is burned and the operator can simply retry.
     *
     * Called from AdviceRestController BEFORE adviceRepository.save(...) at :198.
     *
     * NOT @Transactional — it sequences a short read-only tenant tx (self.resolveRefs) followed by
     * the CUPS availability probe OUTSIDE that tx. See B2a for why the split is mandatory.
     */
    public ValidatedAutoReceive validate(AdviceDto adviceDto)
            throws WebserviceBusinessExceptionClientSide { /* see B2a */ }

    /**
     * DB reads only. MUST be public and MUST be called as self.resolveRefs(...) — see B2a.
     * A protected/package-private @Transactional method gets NO transaction at all, and a plain
     * this.resolveRefs(...) bypasses the proxy.
     */
    @Transactional(value = "tenantTransactionManager", readOnly = true)
    public ResolvedRefs resolveRefs(AdviceDto adviceDto)
            throws WebserviceBusinessExceptionClientSide { /* see B1, B2 */ }

    /**
     * Phase 1 — bind the validated plan to the ALREADY-PERSISTED adviceposition rows, which the
     * caller passes in (AdviceRestController C-2 collects them from the save loop). Pure in-memory
     * mapping, no DB read, no new failure modes.
     *
     * Throws if the line count does not equal savedPositions.size() — see B3's invariant.
     */
    public AutoReceivePlan bind(ValidatedAutoReceive validated,
                                Advice savedAdvice,
                                List<Adviceposition> savedPositions)
            throws WebserviceBusinessExceptionClientSide { /* ... */ }

    /**
     * Phase 2 — execute. Each receiveGoods opens its own tenant tx (ReceivingService:302).
     * Deliberately NOT @Transactional — see B2b.
     */
    public void execute(AutoReceivePlan plan)
            throws WebserviceBusinessExceptionClientSide { /* see B3 */ }

    /**
     * Phase 3 — the two FINISHED flips, in ONE tenant transaction. Called as self.markFinished(...)
     * so the proxy applies. Separate from execute() because execute() must NOT be transactional
     * (B2b) but the two flips MUST be atomic with each other — see B3's split-flip hazard.
     */
    @Transactional(value = "tenantTransactionManager")
    public void markFinished(Long adviceId) {
        advicepositionRepository.updateAdvicepositionToStateByAdviceId(AdviceState.FINISHED, adviceId);
        adviceRepository.updateAdviceToStateById(AdviceState.FINISHED, adviceId);
    }
}
```

**Records** (nested, all four — an implementer cannot start without these):

| Record | Fields |
|---|---|
| `ResolvedRefs` | `Printer printer`, `List<ResolvedLine> lines` |
| `ResolvedLine` | `String positionExternalId`, `String sku`, `Long boxtypeId`, `int amount` |
| `ValidatedAutoReceive` | `Printer printer`, `List<ResolvedLine> lines` (what `ResolvedRefs.toValidated()` returns once CUPS is confirmed) |
| `AutoReceivePlan` | `Long adviceId`, `String adviceNumber`, `Printer printer`, `List<AutoReceiveLine> lines` |
| `AutoReceiveLine` | `Long advicePositionId`, `String positionExternalId`, `String sku`, `Long boxtypeId`, `int amount` |

`adviceNumber` comes from the `Advice` passed to `bind()`, **not** from the DTO — the number is
generated at `AdviceRestController:194` by `basicService.generateNumber` and never appears on
`AdviceDto`. This is why `bind` takes the entity rather than a bare `adviceId`.

#### B1 — printer resolution (`printer_id` → default → **throw**)

```java
    private Printer resolvePrinter(Long requestedPrinterId)
            throws WebserviceBusinessExceptionClientSide {
        if (requestedPrinterId != null) {
            Printer p = printerRepository.findById(requestedPrinterId)
                .orElseThrow(() -> new WebserviceBusinessExceptionClientSide(
                    WmsConstants.ENTITY_DOES_NOT_EXISTS, null, "printer_id", requestedPrinterId));
            if (!WmsConstants.PrinterType.RETURN.equals(p.getType())) {
                throw new WebserviceBusinessExceptionClientSide(
                    WmsConstants.FIELD_MALFORMED_FORMAT, null, "printer_id", requestedPrinterId);
            }
            return p;
        }
        return printerRepository.findByTypeAndProcessdefaultTrue(WmsConstants.PrinterType.RETURN)
            .orElseThrow(() -> new WebserviceBusinessExceptionClientSide(
                WmsConstants.DEFAULT_TYPE_NOT_EXIST, null, "printer"));
    }
```

Two deliberate divergences from v1, both required:

1. **`printer_id` is honored** (D3). v1 ignores it; OMS Flow 2 has been sending it into a void since
   2026-05-15. An explicitly-supplied `printer_id` that is missing or not of type RETURN **throws**
   rather than falling back — a caller that names a printer has an intent, and silently substituting
   another prints the label where the operator is not standing.
2. **When nothing resolves, throw** (D2). v1 `:307` silently skips and then flips state anyway — §2
   Bug 4. This is the single most important behavioral correction in the plan.

#### B2 — boxtype resolution (v1's fallback chain is DEAD — do not port it)

> **Do NOT port v1's chain. It is unreachable on this path in both versions — verified.** v1
> `AdviceRestController:279-304` walks `pos.getBoxtypeId()` → `itemdata.getDefaultboxtypeId()` →
> sysprop `DEFAULT_BOX_TYPE` via `boxtypeRepository.findByName` → throw. But the save loop at
> **v1:258 / v2:261** unconditionally executes
> `Boxtype boxtype = optionalBoxtype.get(); position.setBoxtypeId(boxtype.getId());`
> so by the time any RETURN block runs, `boxtypeId` is always populated — or the request already
> failed at `:249`. Confirmed empirically: the repro row has `boxtype_id=52000` (§1 Q2). Porting the
> chain would add three branches with no reachable input, plus a `findByName` lookup that disagrees
> with the `findByExternalid` lookup the loop actually uses.

**What `validate()` does:** resolve the boxtype the save loop *will* persist, using the same lookup
the loop uses — `boxtypeRepository.findByExternalid(advicePosition.getBoxId())` (`:247`) — so the two
cannot disagree. Keep a defensive `orElseThrow` on `WmsConstants.DEFAULT_TYPE_NOT_EXIST` (`:1241`),
not a live chain. If the implementer finds a reachable null-boxtype input, that is a finding to
report, not a branch to guess at.

Related prerequisite: OMS hard-codes `'box_id' => 1` (`QaReturnService.php:747`), looked up by
`findByExternalid`, so every tenant needs a `boxtype` row with `externalid = '1'` or `:249` throws
`ENTITY_DOES_NOT_EXISTS` — see §6.1 prereq 3.

> **Latent defect found while writing this plan (out of scope — §10-Q10).**
> `AdviceRestController.java:245-262`: `Optional<Boxtype> optionalBoxtype = null;` is assigned **only**
> inside `if (StringUtils.isNotEmpty(advicePosition.getBoxId()))`, but `:261` calls
> `optionalBoxtype.get()` unconditionally ⇒ **NullPointerException ⇒ HTTP 500** whenever `box_id` is
> omitted. It never fires today only because OMS always sends `box_id`. v1 is identical at `:258`. Not
> caused by this plan and not fixed by it; `validate()` must not depend on that value being safe.

#### B2a — assert the printer is REACHABLE during validation, not mid-loop

`receiveGoods`'s first statement is `if (!printService.isPrintAvailable(printer.getAddress()))`
(`ReceivingService.java:315`), throwing `BusinessException` when CUPS is down. Left alone, that check
runs **N times against the same address** — once per position, each inside its own tenant transaction
— so a CUPS outage fails at *position 1, mid-execute*, which is R1's trigger. Checking it during
validation makes a CUPS outage a clean 400 with zero receives and zero rows persisted.

**The CUPS call must not run inside the read-only tenant transaction** — that would reproduce the
anti-pattern §2 Bug 3 condemns, one level up. So `validate()` is split:

```java
    /** Public entry point — NOT @Transactional. Orders the work so CUPS I/O is outside the tx. */
    public ValidatedAutoReceive validate(AdviceDto dto) throws WebserviceBusinessExceptionClientSide {
        ResolvedRefs refs = self.resolveRefs(dto);                           // read-only tenant tx, short
        if (!printService.isPrintAvailable(refs.printer().getAddress())) {   // OUTSIDE any tx
            meterRegistry.counter("wms2.returns.autoreceive.rejected_printer_unavailable").increment();
            throw new WebserviceBusinessExceptionClientSide(
                WmsConstants.PRINTER_NOT_AVAILABLE, null, refs.printer().getName());
        }
        return refs.toValidated();
    }

    /** Only the DB reads are transactional. MUST be public; MUST be reached via self. */
    @Transactional(value = "tenantTransactionManager", readOnly = true)
    public ResolvedRefs resolveRefs(AdviceDto dto) throws WebserviceBusinessExceptionClientSide {
        /* B1 printer + B2 boxtype/amount per position */
    }
```

> ### ⚠⚠ LANDMINE — `protected @Transactional` gets NO transaction, and it compiles, tests, and
> verifies clean
>
> An earlier revision of this plan declared `resolveRefs` as `protected` and said it "must be invoked
> so the proxy applies (self-injection, **or package-private on a separate bean**)". **Both of those
> are wrong.** Spring's `AnnotationTransactionAttributeSource` sets `publicMethodsOnly = true`, and
> `AbstractFallbackTransactionAttributeSource` returns a **null** transaction attribute for any
> non-public method — so the annotation is discarded before proxying is even considered.
> `StartApplication.java:26` is a bare `@EnableTransactionManagement` with no custom attribute source,
> so there is no override in this codebase.
>
> The failure is invisible: the reads still *succeed* (each repository call opens its own tenant
> transaction via `@EnableJpaRepositories(transactionManagerRef = "tenantTransactionManager")`,
> `TenantDatabaseConfig.java:22-26`), so nothing breaks visibly — it just silently deletes the
> single-short-read-only-transaction property that §7 rows 2, and v2-constraint rows 2 and 3, all
> assert. Compile passes, unit tests pass, and a naive verify grep for the annotation text passes too.
>
> **Therefore:** `resolveRefs` and `markFinished` are **`public`**, and both are invoked as
> `self.resolveRefs(...)` / `self.markFinished(...)` via the `@Lazy` self-reference. Copy
> `CustomerorderBatchService.java:110-115` + `:825`, which already does exactly this for the same
> reason. §9 asserts `public ResolvedRefs resolveRefs`, and asserts that a bare `this.resolveRefs(`
> **fails**.

All positions share one `Printer`, and `receiveGoods` touches it only via `getAddress()` and
`getName()` (`:315`, `:316`, `:319`, and `getAddress()` at `:542` whose result `:547` consumes as a
plain `String`) — no lazy navigation — so hoisting
the check is safe and a detached instance suffices. This does **not** remove the redundant in-loop
check (that would mean editing `ReceivingService`, shared with the mobile dock path — §10-Q6); it
front-runs it. Residual TOCTOU: CUPS can die between `validate()` and position K. Unavoidable without
§10-Q6; explicitly accepted, and it is v1's exposure too.

#### B2b — Why `execute()` is deliberately NOT `@Transactional`

Three independent reasons, the last two stronger than connection-hold:

1. **Connection hold.** An outer tenant transaction would hold one connection across all N CUPS
   round-trips, converting a per-position hold into a whole-request hold.
2. **Notification semantics.** `receiveGoods` calls `messageService.sendStockChangeMessage`
   (`ReceivingService.java:534`) → `stockChangeNotificationService.sendAfterCommit`
   (`MessageService.java:109-111`). An outer transaction would batch all N OMS `STOCK_UPDATE` posts
   onto a single commit, silently changing when OMS learns about each position.
3. **`rollbackFor` poisoning.** `receiveGoods` is
   `rollbackFor = {BusinessException.class, FacadeException.class}` (`:302`). Under an outer
   `REQUIRED` transaction, a *caught* inner failure still marks the outer transaction rollback-only —
   so a catch-and-report would be a lie and the subsequent state flips would themselves fail.
   Wrapping the loop is not merely suboptimal; it is incorrect.

v1 also has no outer transaction here, so this is parity as well as correctness.

#### B3 — execute, then flip state

```java
    public void execute(AutoReceivePlan plan) throws WebserviceBusinessExceptionClientSide {
        int received = 0;
        for (AutoReceiveLine line : plan.lines()) {
            try {
                receivingService.receiveGoods(line.advicePositionId(), null, false,
                    line.amount(), line.amount(), 1, line.boxtypeId(), plan.printer());
                received++;
            // RuntimeException is NOT optional — see the unchecked-escape box below.
            } catch (BusinessException | FacadeException | RuntimeException e) {
                meterRegistry.counter("wms2.returns.autoreceive.partial_failure").increment();
                LOG.error("RETURN auto-receive PARTIAL FAILURE adviceId={} adviceNumber={} "
                        + "failedSku={} failedPositionExternalId={} received={} of={}",
                    plan.adviceId(), plan.adviceNumber(), line.sku(), line.positionExternalId(),
                    received, plan.lines().size(), e);
                throw new WebserviceBusinessExceptionClientSide(
                    WmsConstants.RETURN_AUTO_RECEIVE_PARTIAL, e,
                    plan.adviceNumber(), line.sku(), received, plan.lines().size());
            }
        }
        self.markFinished(plan.adviceId());        // ONE tenant tx for BOTH flips — see below
        meterRegistry.counter("wms2.returns.autoreceive.success").increment();
    }
```

The state flips run **only after every position succeeded** — this is the §2 Bug 4 correction, and it
is the single most important structural difference from v1. v1's improvement here is only partial (it
skips the flips on a *thrown* failure but not on the silent no-printer skip); this version closes both.

Improvement over v1's error reporting: v1 collapses every failure to `GENERIC_ERROR` (code `0`). This
version names the advice, the failing SKU and the received-count. See Fix E.

> ### ⚠ Three hazards in this loop that a straight v1 port gets wrong
>
> **(a) Unchecked exceptions escape and bypass the whole mitigation.** `receiveGoods` throws plenty of
> unchecked exceptions and *deliberately rethrows* them: `ReceivingService.java:503` is
> `catch (RuntimeException | BusinessException | FacadeException e) { LOG.error(...); throw e; }`. The
> concrete one is `:336`
> `Integer.parseInt(syspropService.getSysvalue(SYSTEM_PROPERTY_MAXIMUM_RECEIVING_DURING_INBOUND_KEY))`
> ⇒ **NumberFormatException** when that sysprop is unset (see §6.1 prereq 13). `StaleObjectStateException`
> is another. Catching only the two checked types lets these escape `execute()`, escape the controller's
> single `catch (WebserviceBusinessExceptionClientSide)` at `:294`, and surface as an **HTTP 500** with
> positions 1..K−1 committed, **no counter and no named-SKU log** — Fix E and R1's mitigation both
> silently bypassed. Hence `| RuntimeException` above, and a test that forces one.
>
> **(b) The flips are bulk-by-`adviceId`, so they can over-reach.**
> `AdvicepositionRepository.java:31` is `UPDATE Adviceposition a SET a.state = :state WHERE a.adviceId
> = :adviceId` — it flips **every** position of the advice, not the ones the loop received. If
> `plan.lines()` is ever short of the persisted position count, the loop skips a position and the bulk
> update marks it FINISHED anyway: §2 Bug 4 in a new costume. `bind()` therefore **throws** unless
> `lines.size() == savedPositions.size()`, and `execute()` re-asserts it before calling `markFinished`.
> §8 has `executeThrowsWhenPlanLineCountDoesNotMatchPersistedPositions`.
>
> **(c) Two flips in two transactions is an unrecoverable state.** Both repository methods are
> `@Modifying` + bare `@Transactional` (`AdvicepositionRepository.java:28-29`,
> `AdviceRepository.java:28-29`), so called separately from a non-transactional `execute()` they commit
> **independently**. A crash or timeout between them leaves **positions FINISHED, advice OPEN** — and
> `ReceivingService.java:344` refuses to dock-receive a non-OPEN position
> (`throw new BusinessException("unexpectedStateFound", …)`). The result is a BOL sitting in Open
> Inbound Notices that **no path can ever receive**: strictly worse than the bug this ticket fixes.
> Hence `markFinished` — one `@Transactional` wrapping both flips, reached via `self.`. It holds no
> connection across CUPS, so B2b's argument against wrapping `execute()` does not apply to it.

### Fix C — gate the call in `AdviceRestController`

**File:** `controller/rest/AdviceRestController.java` — **two** insertion points, because validation
must precede persistence.

**C-1 — before the advice is saved.** Insert immediately before `:198`:

```java
                // SBDEV-2778: a RETURN advice is received and closed at create time (restores the
                // v1 behavior that SBDEV-2236 removed). Validate FIRST: create() is not
                // @Transactional, so anything saved below is committed, and a later throw would
                // burn externalid=RETURN{parcel_id} and leave an orphan OPEN advice that blocks
                // every OMS retry on the duplicate guard (:139-142).
                ReturnAdviceAutoReceiveService.ValidatedAutoReceive validated = null;
                boolean autoReceive = AdviceType.RETURN.equals(adviceDto.getType())
                        && returnAdviceAutoReceiveService.isAutoReceiveEnabled();
                if (autoReceive) {
                    validated = returnAdviceAutoReceiveService.validate(adviceDto);
                }

                adviceEntity = adviceRepository.save(adviceEntity);   // :198 unchanged
```

**C-2 — after the positions are saved.** The loop must now **collect** the saved positions, because
`advicepositionRepository.save(position)` at `:272` currently discards its return value and `bind()`
needs the generated ids without issuing its own DB read. Two small changes:

```java
                // declare alongside localClientItemDataIdentifierMap, just after :199
                List<Adviceposition> savedPositions = new ArrayList<>();
                ...
                    LOG.debug("create {}", position);
                    savedPositions.add(advicepositionRepository.save(position));   // :272 — capture
                }   // :273 — end of per-position loop

                if (autoReceive) {
                    returnAdviceAutoReceiveService.execute(
                        returnAdviceAutoReceiveService.bind(validated, adviceEntity, savedPositions));
                }

            }   // :275 — end of per-advice loop
```

`savedPositions` is declared **inside** the per-advice loop so a multi-advice request cannot leak
positions from advice N−1 into advice N's plan — that would trip `bind()`'s count invariant and, worse,
receive the wrong rows. Capturing the `save()` return is a one-token change to the REGULAR path too
(the list is simply unused there), which is why it is preferred over the alternative of having `bind()`
call `advicepositionRepository.findByAdviceId(...)`: that would add a DB read in no transaction, and a
real failure mode, to a method documented as pure mapping.

Notes:

- The gate reads `adviceDto.getType()` in C-1 (the entity's type is not assigned until `:190-196`);
  the `autoReceive` local carries the decision to C-2, so the type check and the sysprop read are
  each evaluated once per advice.
- Constructor (`:81-106`, **12 params, verified**) gains **exactly one** dep,
  `ReturnAdviceAutoReceiveService` (12→13). `ReceivingService`, `PrinterRepository`, `PrintService`
  and the sysprop read all go into the new *service* — see §0 row 4. `SyspropService` is already
  injected (used at `:279` for `getOmsInstanceName`), but the gate must **not** read the flag through
  it directly; the default-ON semantics live in the service.
- **Rewrite** the comment at `:151-156`. It currently says RETURN advice "is eventually received via
  the mobile /receive path" — after this change that is true only when the switch is OFF. Keep the
  `client.getEnablereceiving()` guard itself unchanged.
- `validate()` re-reads boxtype that the position loop reads again at `:247`. That duplicate read is
  accepted: returns carry 1-3 positions, and the alternative (restructuring the shared loop to build
  positions in memory first) would change the `REGULAR` path's shape for no behavioral gain.

### Fix E — error codes (`PRINTER_NOT_AVAILABLE`, `RETURN_AUTO_RECEIVE_PARTIAL`)

**File:** `service/WmsConstants.java`

**`PRINTER_NOT_AVAILABLE` does not exist** — verified, zero grep hits. The prior draft referenced it
as though it did. Both codes must be added to the `:1228-1245` constant block **and given an arm in
BOTH switches**: `getErrorCodeText` (template, switch starts `:1247`) and `getErrorCodeName`
(symbolic string, switch ~`:1320`).

Codes are grouped by domain (0 generic / 100s validation / 200 default-type / 300 club-line /
400 transfers / 500 receiving), so **600** is the next free group:

| Constant | Value | Text template |
|---|---|---|
| `RETURN_AUTO_RECEIVE_PARTIAL` | 600 | e.g. `"return advice %1s partially received: failed on sku %2s after %3s of %4s positions"` |
| `PRINTER_NOT_AVAILABLE` | 601 | e.g. `"printer %1s is not available"` |

> **Do not copy the live bug at `NOT_ENABLLED_FOR_RECEIVING = 500`** (`:1245`), which has a
> `getErrorCodeText` arm (`:1294`) but is **missing from `getErrorCodeName`** — verified, no hit above
> `:1300` — and silently degrades to the generic name. §9 asserts each new code appears in the file
> at least 3× (constant + two switch arms).

### Fix G — retarget the SBDEV-2236 regression tests

Five tests assert the absence of auto-receive. Enumerated and verified:

| Line | Test | Action |
|---|---|---|
| `:524` | `shouldCreateReturnAdviceWithoutAutoReceive` (AC1+AC3) | **Retarget** to the kill-switch-OFF case (§8 AC8). Its assertions stay valid there, so 2236's regression value is preserved rather than discarded |
| `:567` | `shouldCreateReturnAdviceAndIgnorePrinterId` (AC2) | **Rewrite** — the printer IS now honored (§8 AC6) |
| `:608` | `shouldCreateReturnAdviceInOpenState` (AC5) | **Invert** — the advice ends FINISHED (§8 AC2) |
| `:650` | `shouldNotInvokeReceivingServiceForReturnAdvice` (AC1) | **Invert** (§8 AC1) |
| `:686` | "should never mark advice FINISHED on create when type is RETURN" (AC3) | **Delete** — redundant with the inverted `:608` |

Also rewrite the stale comment at `:58-67` ("Retained post-SBDEV-2236: controller no longer injects
these, but the `verify(…, never())` assertions require live mocks"). The controller *still* won't
inject `ReceivingService` / `PrinterRepository` — they live in the new service — so the mocks stay
unwired, but the reason changes and §8's note explains what that implies for where assertions belong.

### 3.6 What was DELETED from the prior draft (2026-08-03 rewrite)

| Prior fix | Status | Why |
|---|---|---|
| **Fix A — `qa_confirmed` on `AdviceDto`** | **DELETED** | The BA wants unconditional v1 behavior. A per-request assertion field only existed to preserve SBDEV-2236's invariant, which is now withdrawn. It was also weak: hard-coded `true` at one call site is informationally identical to `type=RETURN` from that sender |
| **Fix D — `'qa_confirmed' => true` in OMS `QaReturnService.php`** | **DELETED** | Follows from Fix A. **`oms-laravel-api` leaves this plan entirely** — no OMS PR, no cross-repo deploy ordering, and prereq §6.1-6 ("WMS first, OMS second") is retired |
| **§3.5 options B–F** | **COLLAPSED** | The BA chose option B (restore v1 behavior). Option F (restrict to single-position advices) is now **infeasible** — rejecting a multi-position RETURN advice would reject valid traffic that v1 accepts. See R1 |
| **`getErrorMap()` change** | **MOVED OUT** → §10-Q11 | Cross-cutting (every `/rest` error body); its main justification was letting OMS distinguish a partial receive, which is no longer load-bearing now that option F is off the table. Decided 2026-08-03 |
| **§10-Q1, §10-Q4** | **CLOSED** | Superseded by the BA decision — see §10 |

**Net effect on the design:** the WMS-side fix (B0/B1/B2/B2a/B2b/B3/C) is **unchanged in shape**. Only
the trigger changed — from `RETURN && qa_confirmed` to `RETURN && switch-on` — plus the new sysprop
(Fix F), the two new error codes (Fix E), and three more tests to retarget (Fix G).

**Bonus outcome:** OMS **Flow 2** (`receiveReturnInWms`, which sends `printer_id` and has been
silently broken since 2026-05-15 — §10-Q0) is fixed by this plan with no OMS change, because it PUTs
to the same `/rest/advice/create` and D3 now honors its `printer_id`. The prior draft's "Flow 2 needs
its own ticket" follow-up is retired.

### 3.7 Amendment — findings from the independent review lane (PR #123, 2026-08-04)

An independent reviewer (Codex, triggered on `54af623`) raised two P1s against the PR. Both were
verified against the code and both were real; both are fixed. Neither changes the design's shape.

#### F12 — `V2.2.09`'s `description` overflowed `varchar(255)` (blocking)

`los_sysprop.description` is `character varying(255)` (`V2.2.00__base_v2_schema.sql:1376`, confirmed
live on `wsl-wineco-uat`). The seeded description was **268 characters**. Postgres does not truncate —
it raises `22001` — and Flyway wraps each migration in a transaction, so this aborted the **whole
file**: neither the kill-switch row nor the `oms_integration` user would have been seeded, and the
tenant would have been left with a *failed* migration blocking every later `V2.2.x`.

Shortened to **227 chars**, keeping the load-bearing "absent row = ON" note that the config UI shows.

Why nothing caught it: every test that runs migrations against a real Postgres is in the `@Disabled`
Testcontainers lane (SBDEV-2217), and the verify script's migration checks are name-only greps. New
`SyspropMigrationDescriptionWidthTest` parses the migration SQL as text — no DB needed — and checks
every hand-written `los_sysprop` seed against the table's real column widths. It fails closed if the
directory is missing or if it parses fewer seeds than are known to exist. Negative-tested: replaying
the 268-char value produces `description is 268 chars, exceeds varchar(255) by 13`. New verify checks
`F12`/`F13`/`M5`; `F12` was confirmed to FAIL on the pre-fix file.

The base schema dump is excluded from the sweep, and that is a correctness argument rather than a
convenience: its `los_sysprop` rows are a `pg_dump` of a table whose `description` is *already*
`varchar(255)`, so nothing in it can exceed the width it was read out of.

#### F1b — batch partial-receive: R9 raised to the batch level

R9's fix (validate before persist) only makes the **single-advice** case retryable. Across a batch it
does not hold: `create()` is not `@Transactional` and each receive commits in its own tenant tx, so if
advice N fails, advices 1..N-1 have already moved stock and closed their BOLs while the caller gets
**one** 400 for the whole request. OMS retries the same body, hits the duplicate guard at `:139-142`,
and the return is stuck — the exact state R9 exists to prevent, except now with committed inventory
behind it, so it cannot be cleared by deleting an advice row.

The fix rejects the shape: a request carrying a RETURN advice must carry **only** that advice. This is
the honest option, because the endpoint can offer neither batch atomicity (no surrounding transaction)
nor per-advice outcomes (one 204/400 for the list) — per-advice outcomes would be an OMS contract
change, out of scope. **Provably a no-op for every real caller:**

| Evidence | Result |
|---|---|
| `oms-laravel-api` `WmsApiService::createReturnAdvice` | wraps **one** advice dict (`makeWmsRequest`) |
| legacy `qa-api` `build_wms_create_advice_request` | hard-codes `request = [{...}]` |
| `ADVICE_IMPORT` payloads on wineco-uat / wineco-dev / hydra-dev2, 2020-03-26 → 2026-07-31 | **5,226 requests, 100% batch size 1** |

Gated on the kill switch so switching auto-receive OFF restores pre-SBDEV-2778 behavior *exactly*,
batch shapes included — with the switch off no inventory moves, so a mixed batch is no worse than
before this ticket. The size test precedes the sysprop read, so the single-advice path never pays for
it (this also keeps AC12's read-once-per-advice assertion true).

Note this leaves `MAX_RETURN_ADVICES_PER_REQUEST` (F1) firing on its own only when the switch is OFF,
where it still bounds a large batch of unauthenticated inserts. F1 is **not** the atomicity guard;
its javadoc now says so.

4 new controller tests (`T17`–`T20`) covering both rejections plus the two shapes that must stay
accepted (switch-OFF mixed batch, multi-advice REGULAR batch — the latter guards against re-capping
the bulk OMS imports F1 was deliberately scoped away from). New verify checks `C13`/`C14`, both
confirmed to FAIL with the guard neutralised.

#### Re-verified after the amendment

| | |
|---|---|
| `mvn clean test` | **4669 tests, 2 failures** — `OptionalSafetyArchTest` + `MobilePalletizingServiceTest`, both pre-existing on `develop` |
| ArchUnit violations | **8**, unchanged |
| `verify-SBDEV-2778-…sh` | **`110 pass, 0 fail, 0 skip`** with `RUN_MVN=1` (was 101) |

---

## 4. Architecture Overview

```
 OMS (oms-laravel-api)  — UNCHANGED             WMS (wms2-api)
 ─────────────────────                          ──────────────
 Returns QA screen
   operator inspects parcel, dispositions items
        │
        ▼
 QaReturnService::manage()                :331
   ├─ persistReturnItems()
   └─ if ($receiveNow && dispositionAdvisesWms())   :376
          │
          ▼
      sendReturnRestockAdvice()           :584      ← Flow 1 (produced the repro)
        builds $advice{ type:RETURN, reference_id:'RETURN'.parcel_id, positions[] }
          │
      receiveReturnInWms()                :196      ← Flow 2 (sends printer_id; also fixed)
          │
          ▼
      PUT {wms}/rest/advice/create  (unauthenticated, IP-allowlisted)
          │
          └──────────────────────────────────►  IdempotencyFilter
                                                  SHA-256(method|path|body)
                                                        │
                                                        ▼
                                                AdviceRestController.create()   :109
                                                  (NO @Transactional — every save below
                                                   commits immediately)
                                                  ├─ validate warehouse/client   :123-156
                                                  ├─ duplicate guard externalid  :139-142
                                                  │
                                                  ├─ if RETURN && switch ON      ◄── Fix C-1
                                                  │    ▼
                                                  │  ReturnAdviceAutoReceiveService
                                                  │    .isAutoReceiveEnabled()  DEFAULT ON  ◄── Fix F
                                                  │    .validate(dto)                       ◄── Fix B0
                                                  │      ├─ resolveRefs()  @Transactional(tenantTM, readOnly)
                                                  │      │    ├─ resolvePrinter()      B1  (printer_id → default → THROW)
                                                  │      │    └─ boxtype per position  B2  (findByExternalid, same as :247)
                                                  │      └─ isPrintAvailable()  ONCE, OUTSIDE the tx   B2a
                                                  │    └─ throws => NOTHING persisted yet,
                                                  │       externalid not burned (R9)
                                                  │
                                                  ├─ save Advice   state=OPEN         :198
                                                  ├─ save Adviceposition(s) OPEN      :272
                                                  │
                                                  ├─ if RETURN && switch ON      ◄── Fix C-2
                                                  │    ▼
                                                  │  bind(validated, adviceId)  then
                                                  │  execute()   NOT @Transactional (B2b)
                                                  │         ├─ per position:
                                                  │         │   ReceivingService.receiveGoods() :302
                                                  │         │     @Transactional(tenantTransactionManager)
                                                  │         │     ├─ printService.isPrintAvailable() :315
                                                  │         │     │     ⚠ CUPS HTTP *inside* the tx (pre-existing)
                                                  │         │     ├─ create Unitload + Stockunit
                                                  │         │     ├─ create Goodsreceipt(+position)
                                                  │         │     ├─ print CASE label (:498, gated on PRINT_CASE_LABEL :540)
                                                  │         │     └─ sendStockChangeMessage :534 (STOCK_UPDATE → OMS)
                                                  │         └─ ONLY IF ALL SUCCEEDED:            ◄── §2 Bug 4 fix
                                                  │             updateAdvicepositionToStateByAdviceId(FINISHED)
                                                  │             updateAdviceToStateById(FINISHED)
                                                  │
                                                  ├─ messageService.createMessage(ADVICE_IMPORT) :277
                                                  └─ 204 No Content

 Switch OFF, and every file-import RETURN (v1 parity — v1 does not auto-receive file imports either):
   advice stays OPEN → Mobile → POST /v3/receiving/receive → ReceivingController:267-284 → receiveGoods()
```

### Key files

| File | Lines | Role |
|---|---|---|
| `v2/wms2-api/.../controller/rest/AdviceRestController.java` | 109-308 | Advice ingress; `:198` + `:273` insertion points; `:151-156` stale comment; `:81-106` ctor (12 params) |
| `v2/wms2-api/.../json/AdviceDto.java` | 41-58 | `printer_id` — now read (D3) |
| `v2/wms2-api/.../service/ReturnAdviceAutoReceiveService.java` | new | `isAutoReceiveEnabled` + validate (pre-persist) + bind + execute |
| `v2/wms2-api/.../service/ReceivingService.java` | 302-318 | `receiveGoods`; CUPS call inside the tenant tx |
| `v2/wms2-api/.../service/SyspropService.java` | 288-291 | `getSysvalue` — `@Cacheable("sysprops")`, 2-min Caffeine TTL |
| `v2/wms2-api/.../config/CacheConfig.java` | 36 | `sysprops` TTL = `Duration.ofMinutes(2)` |
| `v2/wms2-api/.../repo/jpa/PrinterRepository.java` | 18 | `findByTypeAndProcessdefaultTrue` |
| `v2/wms2-api/.../repo/jpa/AdviceRepository.java` | 28-32 | `updateAdviceToStateById` |
| `v2/wms2-api/.../repo/jpa/AdvicepositionRepository.java` | 28-32 | `updateAdvicepositionToStateByAdviceId` |
| `v2/wms2-api/.../service/WmsConstants.java` | 1230, 1241, 1245, 1247+, ~1320+ | Error-code table + both switches; `PrinterType.RETURN` |
| `v2/wms2-api/resources/db/migration/V2.2.09__…sql` | new | Seed the kill switch, `'true'` |
| `v1/wms-api/.../controller/rest/AdviceRestController.java` | 272-319 | The reference implementation being restored (incl. Bug 4) |

---

## 5. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `service/ReturnAdviceAutoReceiveService.java` | **Add** | `isAutoReceiveEnabled()` (default ON) + `validate()` + `resolveRefs()` + `bind()` + `execute()`, printer/boxtype resolution, partial-failure reporting, Micrometer counters |
| `controller/rest/AdviceRestController.java` | Modify | Gated `validate()` before `:198` (C-1) and `bind()`+`execute()` between `:273-275` (C-2); ctor 12→13; rewrite comment `:151-156` |
| `service/WmsConstants.java` | Modify | Add `RETURN_AUTO_RECEIVE_PARTIAL = 600` and `PRINTER_NOT_AVAILABLE = 601` to the `:1228-1245` block, **plus an arm in BOTH** `getErrorCodeText` (`:1247`+) and `getErrorCodeName` (~`:1320`+). Add `SYSTEM_PROPERTY_RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED_KEY` |
| `resources/db/migration/V2.2.09__seed_return_advice_auto_receive_sysprop.sql` | **Add** | Seed `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED = 'true'`, `groupname='Operation Options'`, `nextval('seqentities')`, `WHERE NOT EXISTS`. Follow `V2.2.04`'s shape |
| `json/AdviceDto.java` | **No change** | `printerId` already exists with accessors; it is now *read*, not redeclared |
| `test/.../unit/controller/rest/AdviceRestControllerUnitTest.java` | Modify | Retarget `:524`; rewrite `:567`; invert `:608` and `:650`; delete `:686`; rewrite the `:58-67` mock comment; add §8 AC1-AC12 |
| `test/.../unit/service/ReturnAdviceAutoReceiveServiceUnitTest.java` | **Add** | Printer, boxtype, CUPS, partial-failure, **and the default-ON sysprop read** |
| `test/.../ReturnAdviceAutoReceiveIntegrationTest.java` | **Add** `@Disabled` | `TODO(SBDEV-2217)` — see §8 Integration |

**No entity/column change.** `qa_confirmed` is gone; the advice/position state values already exist.
The only DB artifact is the sysprop seed row.

**`oms-laravel-api`: zero files.** No OMS PR.

---

## 6. Implementation Steps

### 6.1 Prerequisites

| # | Category | Requirement | Owner |
|---|---|---|---|
| 1 | ~~BLOCKING~~ **RESOLVED** | **§10-Q0** (2026-07-31, code evidence): both OMS flows PUT to the same `/rest/advice/create`, so Flow 2 is a second victim of SBDEV-2236, not an alternative path. **§10-Q1 / §10-Q4** (2026-08-03): closed by the BA decision to restore v1 behavior. **No blocking questions remain.** | — (closed) |
| 2 | DB state | Per target tenant, a `processdefault=true` `type='RETURN'` printer must exist, else every RETURN advice 400s (D2 — and note v1 would *silently phantom-close* instead, §2 Bug 4). Confirmed present on wineco-dev (`id=30346045`). **Verify on all 5 tenants before enabling.** | Implementer |
| 3 | DB state | Per target tenant, a `boxtype` row with `externalid = '1'` must exist — OMS hard-codes `'box_id' => 1` (`QaReturnService.php:747`) and `:247` resolves it via `findByExternalid`, throwing at `:249` otherwise. This gates advice creation itself, before auto-receive. `los_sysprop DEFAULT_BOX_TYPE` is **not** required (§3 B2 — the fallback chain is unreachable) | Implementer |
| 4 | Flyway | `V2.2.09` seeds the kill switch. ⚠ **Pick the version by sweeping ALL remote branches, not `ls db/migration/`.** `develop`'s head is V2.2.07, which makes V2.2.08 *look* free — but SBDEV-2801 already holds it on an unmerged branch, and whichever ticket merges second dies on "Found more than one migration with version 2.2.08". Re-run the sweep immediately before opening the PR, since another ticket may claim V2.2.09 in the meantime:
`for b in $(git branch -r --format='%(refname:short)' \| grep -v HEAD); do git ls-tree -r --name-only "$b" -- src/main/resources/db/migration; done \| grep -oE 'V2\.2\.[0-9]+' \| sort -u -V \| tail -3`. Per the tenant runbook, apply with the required `--env` flag. ⚠ **UAT `wsl-wineco-uat` sits at V2.2.05** — V2.2.06 and V2.2.07 land first there. **Never `flyway repair` on a checksum mismatch** — delete the history row (see the runbook and the `V2.2.05` amendment precedent) | Implementer + Ops |
| 5 | Feature flags | `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED`, **default ON**. Read with default-ON semantics — see the §3 Fix F LANDMINE. A tenant that has not run V2.2.09 still gets ON (absent row ⇒ ON), which is the intended fail-safe direction here | Implementer |
| 6 | Deploy order | **WMS only. No OMS deploy, no ordering constraint.** (The prior draft's mandatory WMS-first rule is retired with Fix D.) | Implementer |
| 7 | Data migration | None in this plan. RETURN advices left OPEN between 2026-05-15 and this deploy are a separate cleanup — §10-Q5. **They are not auto-healed by this fix** (auto-receive runs at create time only) | Ops (follow-up) |
| 8 | External systems | CUPS must be reachable from WMS pods; B2a turns an outage into a clean 400 with nothing persisted, but it *does* block the return until CUPS is back. Switch OFF is the operational escape hatch | Implementer |
| 9 | Monitoring | Add the §7 Micrometer counters before enabling on any production tenant | Implementer |
| 10 | Coordination | `SBDEV-2729` (active) touches the receiving/label path — agree rebase order | Implementer |
| 11 | Doc hygiene | Add a **SUPERSEDED** banner to `4-Archieves/wms2/plan/SBDEV-2236-…md` and retire its verify script (R6) | Implementer |
| 12 | **DB state — REVISED after security review** | Per target tenant, a `mywms_user` named **`oms_integration`** must exist — **seeded by Flyway V2.2.09**. `ReturnAdviceAutoReceiveService` sets the SecurityContext principal to it for the duration of the receive, so `ReceivingService:359` (`userRepository.findByName(SecurityContextUtils.getUserName())`) stamps `goodsreceipt.operator_id` and stock history with a dedicated integration account. **Superseded the original plan of inheriting the `anonymous` fallback** (security F1): `anonymous` is shared with all other unauthenticated activity, so an OMS-originated return could not be distinguished from an attacker-originated one after the fact. `validate()` now rejects pre-persist if the row is missing, so a missing user is a clean retryable 400 rather than a mid-receive brick. | Implementer |
| 13 | **Sysprop state — newly found** | `receiveGoods` reads two sysprops with **no null guard**: `SYSTEM_PROPERTY_MAXIMUM_RECEIVING_DURING_INBOUND_KEY` at `:336` via `Integer.parseInt(...)` ⇒ **NumberFormatException / HTTP 500** if unset, and `SYSTEM_PROPERTY_WAREHOUSE_NAME` at `:429` via `requireConfig`. Both must be set per tenant. This is pre-existing (the dock path hits them too) but auto-receive makes it reachable from an unauthenticated OMS call | Implementer |
| 14 | **Sysprop state — CORRECTED, this was wrong** | `SYSTEM_PROPERTY_PRINT_CASE_LABEL_KEY` must be **`'true'`** per tenant. ⚠ **The original text here claimed that with it `false` "receiving succeeds and the BOL closes but no label prints" — that is FACTUALLY BACKWARDS.** `PrintService:152-155` sets `printerAvailable = false` in the not-printing branch, so `isPrintAvailable` returns **false** and `validate()` rejects. On a tenant with `PRINT_CASE_LABEL` off or absent, **every RETURN advice 400s forever** with no retry that can succeed — and the pre-existing dock path fails the same way at `ReceivingService:315`. Verified `'true'` on wineco-dev, hydra-dev2, wsl-wineco-uat and nywh-shipitez-uat, so this is latent, not live. **Make it a hard per-tenant preflight, not a nice-to-have.** | Implementer |

| 15 | **BLOCKING preflight — run and record per tenant BEFORE enabling** | `validate()` fails closed, so a tenant missing any of these rejects **every** return the moment this deploys. One query: <br>`SELECT (SELECT sysvalue FROM los_sysprop WHERE syskey='PRINT_CASE_LABEL') AS print_case_label, (SELECT sysvalue FROM los_sysprop WHERE syskey='MAXIMUM_RECEIVING_DURING_INBOUND') AS max_recv, (SELECT count(*) FROM printer WHERE type='RETURN' AND processdefault) AS default_return_printer, (SELECT count(*) FROM mywms_user WHERE name='oms_integration') AS operator_user, (SELECT count(*) FROM boxtype WHERE externalid='1') AS boxtype_1;` <br>Required: `'true'`, a numeric value, `1`, `1`, `1`. | Implementer + Ops |
| 16 | **Network allowlist is a load-bearing control** | `/rest/**` is `.permitAll()` (`SecurityConfiguration:126`) and the tenant comes from an unauthenticated header (`TenantFilter:40-41`). **This ticket makes that endpoint mutate inventory**, so the IP allowlist outside the app is now the primary access control, not a convenience. Confirm it before enabling on production, and record who owns it. Hardening tracked separately (SBDEV-2520). | Implementer + SRE |
| 17 | **`advice.externalid`'s UNIQUE index must not be dropped** | `uk_4d13b6sg589c6y88tkm98xl89`. The duplicate-`reference_id` check at `:139-142` is a read-then-write with no lock in a non-transactional method, so that index — not the check — is what prevents a concurrent double-receive. Treat it as a security control. | Implementer |
| 18 | **CUPS credential log audit — do this BEFORE deploying** | `PrintService:108` used to embed the CUPS username and password in an exception message that `:119` logged at ERROR. This PR removes that, but the path was reachable via the authenticated dock route for a long time. **Grep log archives and any aggregator for `password=` originating from `PrintService`/`ReceivingService`; if it appears, rotate `CUPS_SERVER_ADDRESS_PASSWORD` on every tenant.** | Implementer + SRE |

### 6.2 Steps (each atomically committable)

1. **Baseline the verify script** — run
   `bash sbdocs/9-System/scripts/verify-SBDEV-2778-return-to-inventory-not-received-bol-not-closed.sh`.
   **Expect `Result: 4 pass, 92 fail, 4 skip`** — *not* an all-FAIL baseline. C12 (`printer_id` still
   declared), G1 + G3 (the SBDEV-2236 test still present) and G4 (`ReceivingService` untouched) are
   pre-existing invariant guards and are *supposed* to pass before any code is written. Do not "fix"
   them. Paste the line in §11.
2. **`WmsConstants`** — add `SYSTEM_PROPERTY_RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED_KEY`,
   `RETURN_AUTO_RECEIVE_PARTIAL = 600`, `PRINTER_NOT_AVAILABLE = 601`, **each with an arm in BOTH**
   `getErrorCodeText` and `getErrorCodeName`. NOT `messages_en_US.properties` (that file holds
   `state.*` UI labels only). Commit.
3. **Flyway `V2.2.09`** — seed the sysprop `'true'`, following `V2.2.04`'s shape exactly. Commit.
4. **Fix F** — `ReturnAdviceAutoReceiveService.isAutoReceiveEnabled()` with **default-ON** semantics
   and the Javadoc explaining why it does not use `Boolean.parseBoolean`. Unit tests for absent row /
   `null` / `""` / `"true"` / `"TRUE"` / `"false"` / `"FALSE"` / garbage. Commit.
5. **Fix B0 (validate)** — the `@Lazy self` reference; **`public`** `resolveRefs` invoked as
   `self.resolveRefs(...)` (copy `CustomerorderBatchService.java:110-115`); B1 (printer), B2a
   (`isPrintAvailable` once, outside the tx), B2 (boxtype via `findByExternalid`), the D10 mirrored
   position checks incl. **`amount < 1`**, plus **all five** records (`ResolvedRefs`, `ResolvedLine`,
   `ValidatedAutoReceive`, `AutoReceivePlan`, `AutoReceiveLine`). Unit tests for every throw path.
   Commit.
6. **Fix B (bind + execute + markFinished)** — `bind(validated, savedAdvice, savedPositions)` with the
   line-count invariant; `execute()` catching **`| RuntimeException`**; `markFinished()` as a single
   `@Transactional` reached via `self.`; the B2b no-`@Transactional`-on-execute rationale as a comment.
   Unit tests incl. position-2-throws, an unchecked throw, and a line-count mismatch. Commit.
7. **Fix C** — **both** call sites: `validate()` before `:198` (C-1); the `savedPositions` collection
   at `:272` and `bind()`+`execute()` between `:273-275` (C-2); ctor gains exactly one dep; rewrite the
   `:151-156` comment. Commit.
8. **Fix G — retarget the five SBDEV-2236 tests** (`:524` → kill-switch-OFF, `:567` rewrite, `:608`
   invert, `:650` invert, `:686` delete) and rewrite the `:58-67` mock comment. Add §8 AC1-AC12.
   Commit.
9. **Regression** — `POST /v3/receiving/receive` still receives an OPEN RETURN advice when the switch
   is OFF (§8 AC11); `FileImportController` RETURN still create-only (§8 AC10).
10. **Add the `@Disabled` integration test** — `ReturnAdviceAutoReceiveIntegrationTest` with
    `TODO(SBDEV-2217)` (§8 Integration). It appears in §5 and §8; without this step it gets forgotten.
    Commit.
11. **`mvn clean compile`**, then the two test classes in full (**never** `-Dtest='Outer#method'` —
    silently no-ops on `@Nested`), then full `mvn test`. Revert the mutated `archunit_store`.
12. **Doc hygiene** — SUPERSEDED banner on the SBDEV-2236 plan; retire
    `4-Archieves/scripts/verify-SBDEV-2236-…sh` (R6). No code.
13. **Re-run the verify script with `RUN_MVN=1`** — this is **mandatory**, not optional, for the
    acceptance line. Every `T*` check is a name-only grep, so sixteen empty test methods with the right
    names would satisfy `0 fail` without asserting anything; only the `M*` checks actually execute them.
    Require `Result: N pass, 0 fail`. **Negative-test first**: replay the pre-fix files and confirm it
    FAILS. Paste both lines in §11.
14. **Update §11** with SHAs, PR link, test counts, and the verify lines.

---

## 7. Horizontal Scalability Validation

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | In-JVM state | **No** | `ReturnAdviceAutoReceiveService` is stateless; no static/ThreadLocal added |
| 2 | Connection pool math | **Yes** | `resolveRefs` holds one short read-only tenant connection (the CUPS probe runs **outside** it — B2a); then N sequential `receiveGoods` transactions, each holding a connection across a CUPS round-trip (`ReceivingService:315`). Worst case per request ≈ N × CUPS timeout. Returns are typically 1-3 positions (repro = 1). Recompute `replicas × tenants × maxPoolSize` before enabling a high-volume tenant. Identical to v1's profile |
| 3 | Scheduled jobs | **N/A** | No `@Scheduled` added |
| 4 | Long transactions | **Yes** | Pre-existing `ReceivingService:302`+`:315` — external HTTP inside a tenant tx. This plan multiplies occurrences per request but does not create the pattern, and deliberately does **not** wrap the loop in an outer transaction (B2b). **Follow-up:** hoist `isPrintAvailable` out of the tx (§10-Q6) |
| 5 | Request affinity | **No** | Single synchronous request; no session/WebSocket/SSE state |
| 6 | Retry / idempotency | **Yes** | `IdempotencyFilter` caches the 2xx. **Changed from the prior draft:** the request body is now *unchanged* (no `qa_confirmed`), so the SHA-256 key for a given advice is byte-identical to today's — a pre-fix cached 2xx for the same body could short-circuit a post-deploy retry. Confirm the filter's TTL is shorter than the deploy window, or accept that an advice already 204'd pre-fix must be received at the dock (it is in §10-Q5's cleanup set anyway). A retry after a partial failure hits the `externalid` duplicate guard (`:139-142`) → `ENTITY_ALREADY_EXITS`, which OMS treats as a hard failure (`QaReturnService.php:649-658`) — see R1 |
| 7 | Tenant context | **No** | Runs on the request thread inside `TenantFilter` scope; no `@Async`/`CompletableFuture` |
| 8 | Distributed lock correctness | **No** | No new lock. `receiveGoods` keeps its existing locking |
| 9 | Cache invalidation | **Yes — one new dependency** | `Advice`, `Adviceposition` and `Printer` are **not** cached (verified: `grep -rn "Cacheable\|CacheEvict" \| grep -iE "advice\|printer"` → zero hits), so the bulk FINISHED flips need no `@CacheEvict`. **But the kill switch is read through `SyspropService.getSysvalue`, which IS `@Cacheable("sysprops")` (`:288`).** Propagation depends on the active profile, and the plan must not assert one: **under the `redis` profile** (`CacheConfig.java:49-69`, whose own comment says *"production multi-replica deployment. `@CacheEvict` propagates to all instances"*) eviction is **cross-replica and immediate**; **under the default Caffeine manager** (`CacheConfig.java:36`, TTL 2 min) `@CacheEvict` is **JVM-local**, so the serving pod is immediate and other replicas lag ≤2 min. **Confirm which profile each of the five tenants runs — §10-Q14.** Separately: `getSysvalue` is `unless = "#result == null"`, so the **absent-row case is never cached at all** and the default-ON path re-reads `los_sysprop` every request |
| 10 | External notifications | **Yes** | Three: (a) `messageService.createMessage(ADVICE_IMPORT)` (`:277`); (b) the **case** label print inside `receiveGoods` — `sharedService.createCaseLabel` at `:498`, `printService.cupsPrint` at `:547`, **gated on `SYSTEM_PROPERTY_PRINT_CASE_LABEL_KEY` at `:540`** and emitted in `afterCommit`. Intentionally synchronous, and it *is* ticket symptom 3 — but note it is a case label, not a Unit Load label, and it does not print at all when that sysprop is false (§6.1 prereq 14); (c) `messageService.sendStockChangeMessage` (`ReceivingService.java:534`) → `stockChangeNotificationService.sendAfterCommit` (`MessageService.java:109-111`), emitting a `CODE_RECEIVING_RETURN` `STOCK_UPDATE` to OMS after each position's own commit. (c) moves back to advice-create time — **which is v1's timing** and what the BA has asked for. It is why a partial failure is worse than it looks (R1) |

### v2-only constraint checklist

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | OSIV disabled | **Yes** | Controller mini-sessions detach entities. The plan carries IDs and primitives **except** the shared `Printer`, passed as a **detached instance** into `receiveGoods`. Verified safe by reading the method end-to-end: the entity is touched at exactly four points — `getAddress()` `:315`, `getName()` `:316` and `:319`, and `getAddress()` `:542`, which is captured into a local `String printerAddress` that `:547` `printService.cupsPrint(printerAddress, labelData)` consumes. **No association is ever navigated off `Printer`**, so no `LazyInitializationException`. If a future change navigates one, switch to passing `printerId` and re-reading |
| 2 | `tenantTransactionManager` | **Yes** | `resolveRefs` is `@Transactional(value = "tenantTransactionManager", readOnly = true)`; `validate` and `execute` are deliberately unannotated (B2a, B2b). Must be proxy-invoked or the annotation is skipped. A bare `@Transactional` would silently target the `@Primary` landlord TM |
| 3 | `readOnly = true` | **Yes** | `resolveRefs` is read-only; `execute` writes via `receiveGoods` |
| 4 | Caffeine cache invalidation | **Yes** | See scalability row 9 — the sysprop read is cached (2 min). No `@CacheEvict` obligation on advice/printer |
| 5 | Jakarta namespace | **Yes** | No new persistence imports. v1's `SIMPLE_DATE_FORMAT` date parsing is **not** ported (v2 uses `LocalDate.parse`); v1's `javax.*` imports are not copied |
| 6 | H2-compatible test SQL | **N/A** | New tests are Mockito unit tests; no native SQL added. The Flyway seed is Postgres-only (`nextval`) and runs in the tenant chain, not the H2 test lane |
| 7 | `BaseControllerTest` for controller changes | **Yes** | `AdviceRestControllerUnitTest` (extends `BaseServiceUnitTest`) is the existing harness; extend it and follow its `@Nested` structure |
| 8 | Micrometer metrics | **Yes** | Counters `wms2.returns.autoreceive.success`, `.rejected_no_printer`, `.rejected_printer_unavailable`, `.rejected_no_boxtype`, `.partial_failure`, `.skipped_switch_off`, plus a timer around `execute`. Reuse `MeterRegistry`; do not introduce another metrics stack |

---

## 8. Testing Plan

### Unit — `ReturnAdviceAutoReceiveServiceUnitTest` (new)

> **This is where the `receiveGoods`, printer and sysprop assertions belong.**
> `AdviceRestControllerUnitTest` keeps `receivingService` (`:61`) and `printerRepository` (`:67`) as
> **unwired** `@Mock`s — after this change the controller still won't inject them, because they live
> in the new service. So any `receiveGoods`/printer argument assertion made in the *controller* test
> is swallowed by the mocked `ReturnAdviceAutoReceiveService` and proves nothing. Assert those here;
> assert only the *gate and the ordering* in the controller test.

**Kill switch (Fix F) — the highest-risk logic in the plan:**

- `autoReceiveEnabledWhenSyspropRowAbsent` (`getSysvalue` → `null`) ⇒ **true**
- `autoReceiveEnabledWhenSyspropBlank` (`""`, `"   "`) ⇒ **true**
- `autoReceiveEnabledWhenSyspropTrue` / `…CaseInsensitiveTRUE` ⇒ true
- `autoReceiveDisabledWhenSyspropFalse` / `…CaseInsensitiveFALSE` ⇒ **false**
- `autoReceiveEnabledWhenSyspropGarbage` (`"yes"`, `"0"`) ⇒ **true** (only literal `false` disables)

**Printer (B1):**

- `validateResolvesRequestedPrinterWhenValidReturnPrinter`
- `validateThrowsWhenRequestedPrinterIdDoesNotExist`
- `validateThrowsWhenRequestedPrinterIsNotTypeReturn`
- `validateFallsBackToProcessDefaultReturnPrinterWhenNoPrinterIdGiven`
- `validateThrowsWhenNoPrinterIdAndNoProcessDefaultReturnPrinter` — **the §2 Bug 4 guard.** Must also
  assert `updateAdviceToStateById` and `updateAdvicepositionToStateByAdviceId` were **never** called

**Boxtype (B2) / CUPS (B2a):**

- `validateResolvesBoxtypeByPositionBoxIdSameLookupAsSaveLoop`
- `validateThrowsWhenBoxIdUnknown`
- `validateThrowsWhenBoxIdIsEmpty` (stricter than the loop, which NPEs at `:261` — §10-Q10)
- `validateThrowsWhenCupsUnavailable`
- `validateIsPrintAvailableCalledExactlyOnceForMultiPositionAdvice` — B2a's whole point
- `validateReceivesNoGoodsBeforeThrowing` (nothing side-effecting in validate)

**D10 mirrored position checks (the option-(a) decision):**

- `validateThrowsWhenAmountOfBottlesIsZero` — **the R9 brick on contract-legal input**; `create()`
  accepts `0` (`:230` rejects only `< 0`) but `ReceivingService:325` throws on `< 1`
- `validateThrowsWhenSkuUnknown` (itemdata unresolvable — the most common real failure)
- `validateThrowsWhenDuplicateSkuInAdvice`
- `validateThrowsWhenAmountOfBottlesIsNull`

**Execute (B3):**

- `executeReceivesEveryPositionThenMarksAdviceFinished`
- `executeThrowsPartialFailureAndDoesNotMarkFinishedWhenSecondPositionFails`
- `executeErrorIdentifiesFailingSkuAndReceivedCount`
- `executePassesExactV1ArgumentTuple` — `(posId, null, false, notifiedamount, notifiedamount, 1, boxtypeId, printer)`, matching `v1:308`
- **`executeWrapsUncheckedExceptionFromReceiveGoods`** — force a `RuntimeException` (e.g.
  `NumberFormatException`, the real one from `ReceivingService:336`); assert it surfaces as
  `RETURN_AUTO_RECEIVE_PARTIAL`, the `.partial_failure` counter fires, and the advice is **not**
  FINISHED. Without `| RuntimeException` in the catch this test fails and an HTTP 500 escapes
- **`executeThrowsWhenPlanLineCountDoesNotMatchPersistedPositions`** — the bulk-flip over-reach guard
  (B3 hazard (b)): a short `plan.lines()` must throw rather than let `markFinished` flip an unreceived
  position to FINISHED
- **`markFinishedFlipsBothPositionsAndAdviceInOneTransaction`** — asserts both repository calls happen;
  the atomicity itself is structural (the `@Transactional` on `markFinished`) and is pinned by §9

### Unit — `AdviceRestControllerUnitTest` (modify)

| AC | Test | Assertion |
|---|---|---|
| AC1 | `shouldAutoReceiveReturnAdviceOnCreate` (invert `:650`) | `validate` → `bind` → `execute` all called once for a RETURN advice with the switch ON |
| AC2 | `shouldMarkReturnAdviceFinishedOnCreate` (invert `:608`) | `execute` invoked with a plan bound to the saved advice id. (The FINISHED flips themselves are asserted in the *service* test — the controller only delegates) |
| AC3 | **`shouldValidateBeforeSavingAdvice`** | **R9's guard, and the most important new test.** `InOrder` verification: `returnAdviceAutoReceiveService.validate(...)` **strictly before** `adviceRepository.save(any())` |
| AC4 | `shouldNotAutoReceiveRegularAdvice` | REGULAR ⇒ `validate`/`execute` never called, even with the switch ON |
| AC5 | `shouldSkipAutoReceiveForReturnAdviceWhenSwitchOff` | `isAutoReceiveEnabled()` → false ⇒ advice still created (204), `validate`/`bind`/`execute` **never** called |
| AC6 | `shouldPassPrinterIdThroughToValidate` (rewrite `:567`) | `printer_id=42` reaches `validate` on the DTO — the inversion of the old "ignore printer_id" assertion. The resolution logic itself is asserted in the service test |
| AC7 | `shouldReturn400WhenValidateThrows` | stub `validate(...)` to throw ⇒ HTTP 400 **and** `verify(adviceRepository, never()).save(any())`. ⚠ `verify(printerRepository).findById(42L)` is **impossible here** — the controller never touches `printerRepository` (unwired `@Mock`, `:67`) |
| AC8 | **`shouldCreateReturnAdviceWithoutAutoReceive`** (retarget `:524` — **SBDEV-2236's guard, preserved**) | With the switch **OFF**: `receiveGoods` never called, states never FINISHED. ⚠ **Highest false-green risk in the plan:** all assertions are `never()`, so if the retargeted setup stops reaching the RETURN branch at all, the guard passes vacuously. **Mandatory additions:** keep the existing HTTP-204 assertion (`:556`) **and** add a positive `ArgumentCaptor` on the saved `Advice`/`Adviceposition` asserting `state == AdviceState.OPEN`. Compounding the risk: the class is `@MockitoSettings(strictness = Strictness.LENIENT)` (`:34`), so unmatched stubs raise nothing |
| AC9 | `shouldAutoReceiveAllPositionsOfMultiPositionReturnAdvice` | multi-position: `bind` receives every position; `execute` called once with all lines |
| AC10 | `shouldNotAutoReceiveFileImportReturnAdvice` (`FileImportControllerUnitTest`) | v1 parity — file-import RETURN stays create-only |
| AC11 | `shouldStillReceiveOpenReturnAdviceViaDockPath` (`ReceivingControllerUnitTest`) | `POST /v3/receiving/receive` unaffected |
| AC12 | `shouldAutoReceiveWhenSyspropRowIsAbsent` | End-to-end through the controller with `getSysvalue` → `null`: auto-receive **runs**. Guards the default-ON landmine at the integration seam, not just in the service |

> ⚠ **Why AC7 needs a "came from the intended path" assertion.** A pure-negative 400 test passes for
> *any* 400 cause — missing client, malformed date, `enablereceiving=false` — even if execution never
> reaches the auto-receive logic. Pair every negative with a positive: the `never()` on
> `adviceRepository.save` is what makes AC7 meaningful.

### Integration

v2's Testcontainers lane cannot boot (**SBDEV-2217**). Add `ReturnAdviceAutoReceiveIntegrationTest`
`@Disabled` with `TODO(SBDEV-2217)`, asserting end-to-end that a RETURN advice ends FINISHED with
`goodsreceipt` rows, that the switch OFF leaves it OPEN with none, and that V2.2.09 seeded the row.
Gate the merge on unit tests + `mvn clean compile`.

### Regression

- REGULAR advice creation byte-identical.
- `FileImportController` RETURN path untouched and still create-only (AC10).
- Dock receive still works (AC11).
- **No OMS test changes** — `oms-laravel-api` is untouched.

### Harness landmines (do not skip)

- `mvn test` **mutates the tracked `archunit_store`** — `git checkout` it afterwards.
- `-Dtest='Outer#method'` **silently no-ops for `@Nested` tests** (false green).
  `AdviceRestControllerUnitTest` uses `@Nested` — run the whole class.
- Clean-`develop` baseline is **2/4442 failing** (`OptionalSafetyArchTest`,
  `MobilePalletizingServiceTest`). Expected baseline is **not** zero.
- `mvn`/`java` need the SDKMAN PATH export.
- Surefire `-Dtest` overrides the `*IntegrationTest` exclude — do not accidentally run the disabled IT.
- **Negative-test the verify script**: replay the pre-fix files and confirm it **FAILS** before
  trusting any "N pass, 0 fail".

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Sellable return, single SKU | wineco-dev | Return QA → Return to Inventory → complete | BOL closed (FINISHED); UL created; label prints; on-hand +qty | |
| Multi-position return | wineco-dev | Two sellable SKUs on one return | Both received; one BOL, FINISHED | |
| Kill switch OFF | wineco-dev | Set sysprop `'false'`, wait ~2 min (or flip via the config UI to evict), send a RETURN advice | Advice OPEN; no `goodsreceipt`; receivable at the dock (2236 behavior on demand) | |
| Kill switch row absent | wineco-dev | `DELETE FROM los_sysprop WHERE syskey='RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED'`, wait for TTL | Auto-receive **still runs** — proves the default-ON read | |
| No RETURN printer | wineco-dev | Set `processdefault=false` on `id=30346045`, send a RETURN advice | HTTP 400 naming the printer; **no `advice` row created** (R9); **advice NOT FINISHED** (§2 Bug 4) | |
| Invalid `printer_id` | wineco-dev | RETURN advice with `printer_id` of an INBOUND printer | HTTP 400; nothing received; nothing saved | |
| Valid `printer_id` (Flow 2) | wineco-dev | RETURN advice with the RETURN printer's id | Label prints on **that** printer, not the default — proves D3 and un-breaks Flow 2 | |
| CUPS down | wineco-dev | Block the CUPS address, send a RETURN advice | HTTP 400; `isPrintAvailable` called **once**; no advice row | |
| Partial failure | wineco-dev | Two positions; force position 2 to fail | Advice **OPEN**; position 1 received; error names the failing SKU + `1 of 2` | |
| SQL sanity | wineco-dev | `SELECT state FROM advice WHERE externalid='RETURN<parcel>'` + `goodsreceipt` count | `FINISHED`; `goodsreceipt` rows match position count | |

---

## 9. Risks & Mitigations

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | **Partial receive + OMS rollback divergence.** `QaReturnService.php:330` wraps the manage flow in `DB::connection('tenant')->transaction(...)`, so a throw from `sendReturnRestockAdvice` (`:377`) rolls back `managed=true` and the persisted return items. After a partial failure WMS has *really received* positions 1..N−1 ⇒ OMS forgets the return while WMS holds the stock. **Amplifier:** each committed position already fired a `CODE_RECEIVING_RETURN` `STOCK_UPDATE` (`ReceivingService.java:534`), so OMS receives N−1 stock increments for a return it then rolls back. | **High** — silent OMS/WMS inventory divergence | **Partially mitigated; do not treat as closed.** B0/B2a move every *predictable* failure (no printer, wrong-type printer, unresolvable boxtype, CUPS down) ahead of the first receive and ahead of any persistence, removing the likely triggers. **Option F is no longer available** — rejecting a multi-position RETURN advice would reject traffic v1 accepts, so it is off the table (§3.6). **This residual is exactly v1's, which the business has run for years**, so it is accepted as part of "restore v1 behavior" rather than solved here. What this plan adds over v1: the failure is *named* (Fix E: advice + failing SKU + `k of N`) instead of collapsed to `GENERIC_ERROR`, it is *counted* (`.partial_failure`), and the advice is never left FINISHED-but-empty (§2 Bug 4). Full reconciliation needs §10-Q11 (`getErrorMap` carrying the code) **plus** an OMS needs-review state outside the transaction — tracked, not funded here. |
| R2 | **Phantom inventory returns** — the exact defect SBDEV-2236 was filed to fix. A RETURN advice now increments stock before any dock scan, so an advice sent for goods that never arrive creates stock that does not exist | **High** | **Accepted by BA decision, not mitigated by code** — this is the deliberate trade being made, and it must be recorded as such rather than hidden. Compensating controls: the kill switch (Fix F) reverses it per tenant in ~2 min with no redeploy; `.success` counter gives volume visibility; §10-Q5's reconciliation report can spot advices FINISHED with no matching physical receipt. If phantom inventory shows up in production, the switch is the response and this ticket gets reopened. **Gap worth naming:** the switch stops *new* auto-receives; stock already incremented has **no documented reversal path** (§10-Q5 is the *pre*-deploy OPEN-advice cleanup, not a post-deploy unwind). If the BA reverses again, that unwind needs its own ticket |
| R3 | **Default-ON read implemented as `Boolean.parseBoolean`** ⇒ every tenant without the V2.2.09 row silently keeps the bug, looking identical to the pre-fix symptom | **High** | The §3 Fix F LANDMINE box, a Javadoc note on the method, five unit tests (absent/null/blank/garbage/`"false"`), controller-level AC12, and a §9 verify assertion that `Boolean.parseBoolean` does **not** appear near this key. This is the most likely way a reviewer or a future refactor breaks the fix |
| R4 | **v1's Bug 4 gets ported verbatim** — `if (printerOptional.isPresent())` with the state flips outside the guard ⇒ advice FINISHED having received nothing | **High** | D2 (throw, never skip); B3 flips only after all positions succeeded; a dedicated service test asserting the flips are never called on printer-resolution failure; a manual test row. Called out at §2 Bug 4 precisely because a "just restore v1" instruction invites a verbatim copy |
| R5 | CUPS unreachable ⇒ every RETURN advice 400s and every return blocks | Medium | Deliberate: `receiveGoods:315` already fails this way for dock receiving, and v1 has the same exposure. Monitor `.rejected_printer_unavailable`; the kill switch restores dock-receive as the fallback |
| R6 | **`verify-SBDEV-2236-…sh` now asserts a reversed contract** | Low | **RETIRE it** (§6.2 step 11) — stronger than the prior draft's "annotate it". Its negative assertions encode a requirement the BA has withdrawn, so leaving it in place would fail CI and mislead the next reader. Add a SUPERSEDED banner to the 2236 plan doc pointing here. Its regression *value* survives as AC8 (the kill-switch-OFF case) |
| R7 | Sysprop flip does not take effect immediately across replicas | Low | Caffeine `sysprops` TTL is 2 min and eviction is JVM-local (`CacheConfig.java:36`, `SyspropService:53`). Document "allow 2 minutes" in the runbook. Same caveat as `ApiTimestampFormatResolver:32` |
| R8 | `V2.2.09` applied out of order on UAT | Low | `wsl-wineco-uat` is at **V2.2.05**; V2.2.06/07 must land first. Follow the tenant runbook's required `--env` flag and staleness guards. **Never `flyway repair`** on a checksum mismatch — delete the history row |
| R9 | **A validation 400 burns `externalid = RETURN{parcel_id}`**, leaving an orphan OPEN advice so every OMS retry fails the duplicate guard (`:139-142`) ⇒ the return is unmanageable without DB intervention. On a tenant with no `processdefault` RETURN printer this would hit **every** return | **High** | Fix B0 / Fix C-1: all auto-receive validation runs **before** `adviceRepository.save(...)` at `:198`, so a rejection persists **no advice row** and the retry is clean (it does burn one IBOL number — `basicService.generateNumber` at `:194` bumps a DB sequence before the C-1 insertion point — which is harmless). AC3 enforces the ordering with `InOrder`; the "No RETURN printer" manual test asserts no `advice` row was created. Note the residual for the *pre-existing* post-save position validations (§3 principle 3 box) — identical to v1 |
| R10 | `AdviceRestController` ctor grows to 13 params | Low | Accepted; matches existing style. The service extraction keeps it to one new dep instead of four |
| R11 | `IdempotencyFilter` replays a pre-fix cached 204 for a byte-identical body | Low | New in this rewrite — the prior draft's added `qa_confirmed` field changed the SHA-256 key and dodged this. **There is no TTL to hide behind:** cleanup is `app.cron.cleanup-rest-idempotency=0 0 2 * * *` (`application.properties:115`), a **daily 2am cron** (`RestIdempotencyService.STALE_CLAIM_TTL` at `:61` is 60s but that is an unrelated in-flight claim timeout). So a pre-fix cached 204 **will** replay across a same-day deploy, silently skipping auto-receive with no counter and no log. Do not "confirm the TTL" — there isn't one. Mitigation: deploy after 2am cleanup, or accept that same-day pre-fix advices join §10-Q5's cleanup set. Route them there explicitly |
| R12 | **`protected @Transactional` silently yields no transaction** — and compile, tests and the verify script all pass | **High** | The §3 B2a LANDMINE box; `resolveRefs`/`markFinished` are `public` and reached via `@Lazy self` (precedent `CustomerorderBatchService.java:110-115`); §9 asserts `public ResolvedRefs resolveRefs` **and** that a bare `this.resolveRefs(` fails. This was a real defect in the pre-Critic draft of this plan, which had specified `protected` and offered "package-private on a separate bean" as an alternative — both non-public, both broken |
| R13 | **Positions FINISHED while the advice stays OPEN** — a BOL no path can ever receive | **High** | B3 hazard (c): the two flips are separate `@Modifying @Transactional` repository methods, so from a non-transactional `execute()` they commit independently, and `ReceivingService.java:344` then refuses to dock-receive a non-OPEN position. Fixed by `markFinished` wrapping both in one tenant transaction via `self.`. §9 pins the annotation |
| R14 | **Unchecked exception from `receiveGoods` bypasses Fix E entirely** ⇒ HTTP 500, positions committed, no counter, no named-SKU log | **High** | B3 hazard (a): `catch (BusinessException \| FacadeException \| RuntimeException e)`. `ReceivingService:503` explicitly rethrows `RuntimeException`, and `:336` `Integer.parseInt(getSysvalue(...))` produces one whenever `MAXIMUM_RECEIVING_DURING_INBOUND` is unset (§6.1 prereq 13). Test `executeWrapsUncheckedExceptionFromReceiveGoods` |
| R15 | **`amount_of_bottles = 0` bricks the return** — accepted by `create()` (`:230` rejects only `< 0`), rejected by `ReceivingService:325` (`< 1`) | **High** | D10: `resolveRefs` rejects `amount < 1` before anything is persisted. Whether OMS can emit zero is §10-Q12, but the guard ships regardless because the failure is unrecoverable (R9 brick) and the guard is one line |

**Acceptance:** `bash sbdocs/9-System/scripts/verify-SBDEV-2778-return-to-inventory-not-received-bol-not-closed.sh`
must report `Result: N pass, 0 fail`, and that exact line must be pasted into §11 — **after** a
negative test proving the script fails against the pre-fix tree.

---

## 10. Open Questions / Resolved Decisions

### Blocking

**None.** All three prior blockers are closed.

### Closed by the BA decision (2026-08-03, Brent Campbell via Nam Park)

| # | Was | Resolution |
|---|---|---|
| Q1 | **SBDEV-2236 conflict** — needed David Oppenheim to confirm (a) Return QA counts as physical confirmation, (b) `qa_confirmed` is an acceptable basis, (c) the `CODE_RECEIVING_RETURN` timing shift is acceptable | **Moot.** The BA has ruled that the v1 behavior is the required behavior, so WMS does not need a per-advice assertion at all — the advice type is sufficient. (c) resolves as "yes, the notification returns to advice-create time", which is v1's timing. SBDEV-2236 is **superseded**, and this plan says so in its banner rather than quietly reverting it. **David should still be notified** as a courtesy — he requested 2236 and is assigned here — but he is no longer a gate |
| Q4 | **How should a partial receive be reconciled?** (option F recommended) | **Option F is infeasible** now that the trigger is `type=RETURN` alone: rejecting a multi-position RETURN advice would reject traffic v1 accepts. Resolution is **(iii) accept the divergence** — it is v1's own residual — plus name/count the failure (Fix E, `.partial_failure`) and never leave the advice FINISHED-but-empty (§2 Bug 4). Full reconciliation is deferred to §10-Q11 + an OMS needs-review state |
| Q0 | **Is OMS Flow 2 (`receiveReturnInWms`) already the sanctioned path?** | **RESOLVED 2026-07-31 by code evidence — NO.** Flow 2 is live (`QaReturnController.php:327`, OpenAPI `operationId: receiveReturnInWms`) but resolves to the **same** WMS endpoint: Flow 2 → `WmsApiService::createAdvice` → `getWmsEndpoint('advice_create')` = `rest/advice/create` (`config/wms.php:37`, `WmsApiService.php:2053`); Flow 1 → `createReturnAdvice` → hardcoded `/rest/advice/create` (`:2126`). Both land on `AdviceRestController.create()`, which auto-receives nothing post-2236. ⇒ **Flow 2 is a second victim of SBDEV-2236, not an alternative path** — it sends `printer_id` precisely because it expected WMS to receive and print at create time. **This plan fixes Flow 2 for free** (D3 honors `printer_id`), so no separate ticket is needed for it |

### Resolved decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Scope: WMS v2 only.** No OMS change | The BA wants v1 behavior restored; v1 needs no OMS cooperation. Drops a repo, a PR and a deploy-ordering constraint from the prior draft |
| D2 | **No resolvable printer ⇒ throw**, not v1's silent skip (`v1:307`) | v1's skip leaves the advice FINISHED with nothing received (§2 Bug 4) — a phantom-closed return, strictly worse than the reported bug |
| D3 | **Honor `printer_id`**: `printer_id` → default RETURN → throw; an invalid/wrong-type `printer_id` throws rather than falling back | Improvement on v1, which ignores it. Revives the printer preference OMS shipped for SBDEV-2206 and un-breaks Flow 2. A named printer is an intent; substituting another prints where the operator is not standing |
| D4 | **Sysprop kill switch, default ON** (`RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED`, Flyway V2.2.09) | Restores the function everywhere immediately (what the BA asked) while giving ops a per-tenant reversal in ~2 min with no redeploy. With Fix D gone there is otherwise **no** rollback lever short of a WMS redeploy. Default ON — and read default-ON, R3 |
| D5 | **Do not port v1's boxtype fallback chain** | Unreachable in both versions (`v1:258` / `v2:261` always set `boxtypeId`); empirically confirmed by the repro row's `boxtype_id=52000`. It also uses `findByName` where the save loop uses `findByExternalid`, so porting it would let the two disagree |
| D6 | **Extract a service; do not inline v1's block in the controller** | v1's inline version is why it has an untested phantom-close bug. The extraction also lets validation be one short read-only tx and keeps the controller ctor at +1 dep |
| D7 | **`getErrorMap()` moves to its own ticket** (§10-Q11) | Cross-cutting: changes every `/rest` error body and needs its own consumer audit. Its main beneficiary (OMS distinguishing a partial receive) stopped being load-bearing when option F died |
| D8 | **Retire SBDEV-2236's verify script; banner its plan doc** | A merged, DB-verified decision being reversed by the BA should leave a visible trail, not a silently-deleted script or a failing CI check |
| D9 | **DB-verify before drafting** | §1 Q1-Q5; `db_verified: true` |
| D10 | **Option (a): `validate()` mirrors the position checks** for RETURN advices (sku/itemdata, amount `>= 1`, non-null amount, duplicate SKU, box_id) — see §3 principle 3 | Leaving it as "(a) recommended / (b) accept" meant an implementer would silently ship (b), under which an unknown SKU — the most common real failure — commits the advice row, 400s, burns `externalid` and bricks every retry. Cost is one duplicated validation block; flag the drift risk in review |
| D11 | **`resolveRefs` and `markFinished` are `public` and invoked via `@Lazy self`** | A non-public `@Transactional` method gets **no transaction at all** (`publicMethodsOnly = true`), and the failure is invisible to compile, tests and grep. Precedent to copy: `CustomerorderBatchService.java:110-115` + `:825` |
| D12 | **`execute()` catches `RuntimeException` too; the two FINISHED flips move into one `@Transactional markFinished`** | `ReceivingService:503` rethrows unchecked exceptions, which would bypass Fix E and surface as HTTP 500 (R14); and two independently-committing flips can leave positions FINISHED with the advice OPEN, which no path can then receive (R13) |
| D13 | **`getErrorMap()` stays out of scope** even though R1 is now less mitigated than option F would have made it | Cross-cutting change to every `/rest` error body; needs its own consumer audit. §10-Q11 |

### Out of scope — recommended follow-up tickets

| # | Item | Why out | Recommended |
|---|---|---|---|
| Q2 | ~~**Expected Date one day off**~~ | **ALREADY FIXED — no ticket needed.** Landed on `develop` as `dfe24f8` (SBDEV-2660, 2026-07-31, PR #116); found during implementation. **This plan's diagnosis was wrong about the location:** it inferred a `wms2-web-ui` render bug from the fact that the stored `dayofdelivery` is correct. The real cause was **API serialization** — `/advice/detailView` served `dayofdelivery` as the raw `java.sql.Date` from the native-query projection; with the JVM on UTC that materializes as midnight-UTC and `UtcDateSerializer` emits an instant (`2026-07-31T00:00:00.000Z`), which a negative-offset client rolls back a day to 5:00pm. Fixed by converting to `LocalDate` so it serializes as a bare `yyyy-MM-dd`. **Lesson worth keeping: "the stored value is correct" does not imply the bug is in the UI** — a correct value can still be serialized wrongly. | — (closed) |
| Q3 | **Flow 1 / Flow 2 payload divergence** | `sendReturnRestockAdvice` sends `type`/`client_id`/`day_of_delivery`; `receiveReturnInWms` sends `advice_type`/`client_code`/`expected_date` via `buildAdvicePayload:2337`. Two disagreeing contracts on one endpoint is its own defect | New ticket, `oms-laravel-api` |
| Q5 | **Cleanup of RETURN advices left OPEN 2026-05-15 → this deploy** | Operational data task, not code. **Not auto-healed** — auto-receive runs at create time only | Ops ticket; SBDEV-2236 §5.1-5 set the precedent |
| Q6 | **Hoist `isPrintAvailable` out of the tenant transaction** | Pre-existing (`ReceivingService:315`); touches the mobile dock path too, so it needs its own regression scope | Tech-debt ticket |
| Q7 | **Damaged-disposition routing** | OMS sends **only undamaged** qty (`QaReturnService.php:604-615` returns `['status'=>'skipped','reason'=>'no undamaged items']`). Needs a real OMS feature | New ticket, OMS-first |
| Q8 | **Audit-record linking** (return ↔ BOL ↔ UL ↔ receiving user) | Ticket's Transaction/Audit list; needs a data model discussion | New ticket |
| Q9 | ~~**Missing docs**~~ | **BOTH CLAIMS WERE WRONG — closed, no ticket.** The Phase-4 audit disproved them: `wms2-receiving-putaway-workflow.md` **does exist** (`sbdocs/3-Resources/workflows/`, last_verified 2026-05-10), and `wms2-function-to-docs-map.md:188` **does** carry an entry covering `AdviceRestController` / `ReceivingController` / `ReceivingService` under "Receiving / putaway". Instead of filing doc-debt, this ticket UPDATED the two docs the change actually invalidated: the workflow gained **§3.5 RETURN auto-receive at advice-create time** and an annotated lifecycle diagram; the state-machine catalog **§4.8** gained `ReturnAdviceAutoReceiveService.markFinished` as an `Adviceposition` write site. `last_verified` was deliberately **not** bumped on either — only the touched sections were re-verified, and a blanket bump would assert coverage that was not performed. | — (closed) |
| Q10 | **`optionalBoxtype.get()` NPE ⇒ HTTP 500 when `box_id` is omitted** | `AdviceRestController.java:245-262` — assigned only inside the `isNotEmpty(getBoxId())` guard, dereferenced unconditionally at `:261`. Latent only because OMS hard-codes `'box_id' => 1`. v1 identical at `:258`. Same class as the SBDEV-2116 unguarded-`Optional` family | New ticket, **both v1 and v2**; also covers the dead boxtype fallback chain |
| Q12 | **Can OMS emit `amount_of_bottles = 0`?** | §10-Q7 says an all-damaged parcel returns `['status'=>'skipped']`, which suggests no — but `create()`'s contract accepts zero and the resulting brick is unrecoverable, so D10 guards it unconditionally rather than waiting. Worth a one-line answer from OMS anyway | Ask OMS; no code depends on it |
| Q13 | **`goodsreceipt.operator_id` will be user 1 / `anonymous`** for every auto-received return | `/rest/**` is `permitAll()` and OMS sends no JWT, so `ReceivingService:359` resolves the `anonymous` fallback user. That is a real audit-trail change the BA should sign off, and it may want a dedicated `oms_integration` user instead. Overlaps §10-Q8 | Raise with BA; new ticket if a named user is wanted |
| Q14 | **Which Spring profile do the five tenants run — `redis` or default Caffeine?** | Decides whether a kill-switch flip is cross-replica-immediate or lags ≤2 min (§7 row 9, R7), and therefore the runbook wording. Not a code dependency | Confirm before writing the runbook line |
| Q11 | **`getErrorMap()` never emits the error code** | `WebserviceBusinessExceptionClientSide:46-51` emits only `status` + `description`, so `WebserviceError.code` / `.errorCodeName` — populated in the ctor at `:47-49` — never reach any `/rest` consumer. **Proof it already breaks OMS:** `stripos($message, 'ENTITY_ALREADY_EXITS')` at `QaReturnService.php:658` can never match, because code 101's text is `"entity %1s already exists for %2s"` (`WmsConstants.java:1262`) and the literal `ENTITY_ALREADY_EXITS` exists only in `getErrorCodeName` (`:1330`), which is not in the body. That branch is **dead code** and the generic rollback path runs instead. Fixing it changes every `/rest` error body ⇒ needs a consumer audit. **Also fix `NOT_ENABLLED_FOR_RECEIVING = 500`, which is missing from `getErrorCodeName`** | New ticket, `wms2-api`; prerequisite for any real partial-receive reconciliation (R1) |

---

## 11. Implementation Status

**IMPLEMENTED, COMMITTED LOCALLY, NOT YET PUSHED.** Four commits on
`bugfix/SBDEV-2778-restore-return-advice-auto-receive` (worktree
`.claude/worktrees/wms2-api/SBDEV-2778`), rebased onto `origin/develop` `a0846d1`. All three review
lanes have run and every High/Medium finding is fixed; a scoped second pass over the two fix commits
was the last gate. **The PR has not been opened — that is the remaining human checkpoint.**

Blockers cleared earlier: §10-Q0 (2026-07-31, code evidence), §10-Q1 and §10-Q4 (2026-08-03, BA
decision).

### Critic pass, 2026-08-03 — what it changed

The Critic found **one CRITICAL that passed the verify script**, plus four under-specified contracts.
All are now fixed in the plan text; every fix is in the design, not just the prose:

| # | Finding | Resolution |
|---|---|---|
| 1 | **CRITICAL — `protected @Transactional resolveRefs` gets NO transaction.** `publicMethodsOnly = true`, so a non-public method's transaction attribute is null; and the prior draft's suggested alternative ("package-private on a separate bean") is *also* non-public. Invisible to compile, tests, and the old verify B2, which matched `\w+ \w+ resolveRefs` and so **certified the broken shape** | D11: `resolveRefs`/`markFinished` are `public`, reached via `@Lazy self` (precedent `CustomerorderBatchService.java:110-115` + `:825`). Verify B2 now requires `public ResolvedRefs`, B2c-B2e pin the self-reference and fail a bare `this.resolveRefs(` |
| 2 | `bind(validated, adviceId)` could not produce `plan.adviceNumber()` (the number is generated at `:194`, never on the DTO), and "pure mapping" was impossible because `:272` discards `save()`'s return | `bind(validated, savedAdvice, savedPositions)`; C-2 collects the saved positions; all **five** records specified |
| 3 | The FINISHED flip is bulk-by-`adviceId` (`AdvicepositionRepository:31`), so a short `plan.lines()` would flip an unreceived position — Bug 4 in a new costume | `bind()` throws on count mismatch; `execute()` re-asserts; B26/B27 + a named test |
| 4 | `execute()` caught only checked exceptions, but `ReceivingService:503` rethrows `RuntimeException` and `:336` `Integer.parseInt(getSysvalue(...))` produces one ⇒ HTTP 500, positions committed, no counter, no log | R14/D12: `catch (… \| RuntimeException)`; B24/B25 |
| 5 | B0 pre-validated only printer + boxtype — `amount_of_bottles = 0` is **accepted by `create()`** (`:230` rejects only `< 0`) and rejected by `ReceivingService:325` (`< 1`), bricking the return on contract-legal input | R15/D10: option (a) decided; `resolveRefs` mirrors the reachable position checks incl. `amount >= 1`; B29-B32 |
| 6 | Verify **F8 was evadable** by the most likely wrong implementation (a `;` between the tokens defeated `[^;]{0,300}`), and **F10 was tautological** (unparenthesised alternation whose left branch F7 already required) | Both rewritten body-scoped. **And negative-testing then caught a fail-open `check_F9`** — `perl -0777` exits 0 on an unopenable file, so it passed pre-fix; `[ -f ]` guards added |
| 7 | Two flips = two independent commits ⇒ positions FINISHED / advice OPEN, which `ReceivingService:344` then refuses to dock-receive: **a BOL no path can ever receive** | R13/D12: `markFinished` wraps both in one tenant tx via `self.`; B20-B23 |
| 8 | Missing per-tenant prereqs: `mywms_user.name='anonymous'` (`ReceivingService:359`), `MAXIMUM_RECEIVING_DURING_INBOUND` + `WAREHOUSE_NAME`, `PRINT_CASE_LABEL` | §6.1 prereqs 12-14, plus §10-Q13 on the `operator_id = anonymous` audit consequence |
| 9 | Option (a)/(b) left unresolved with neither implemented ⇒ implementers would diverge | D10 decides (a) |
| 10 | Six counters + a timer required by §6.1-9 but only two in the sketches, and `E6` passed on any `meterRegistry` mention | E6-E12 assert each metric name |
| 11 | §6.2's "all-FAIL baseline" was wrong | Corrected to the measured `4 pass, 92 fail, 4 skip`, naming which four and why |
| 12 | Every `T*` check is a name-only grep ⇒ sixteen empty test methods satisfy `0 fail` | `RUN_MVN=1` is now **mandatory** for the §9 acceptance line (§6.2 step 13), with a warning banner when it is off |

**Corrections I did NOT make — the Critic was wrong on two:** `getErrorMap()` is at **:46-51** (it said
:45-50) and `receivingService.receiveGoods` is at **ReceivingController:284** (it said :285). Both
re-verified by grep. Its LOW-severity corrections that *were* right are applied: v1's flips are at
**`v1:317-318`** (not :318-319), `FileImportController:458` calls `errors.add(...)` and **does not
throw**, the label is a **case** label (`:498`, gated on `PRINT_CASE_LABEL` at `:540`), the `Printer`
entity is touched at `:315`/`:316`/`:319`/`:542` (`:547` consumes a plain `String`), and a rejected
advice does burn one IBOL number via `basicService.generateNumber` at `:194`.

**Remaining gate: `wms-tdd-gate`** — previously deferred because §10-Q0 could void Fix A/D. That risk
is gone and the acceptance criteria are now stable. The revisions above were made *after* the Critic
ran; they implement its own stated upgrade conditions verbatim, so a re-run is optional rather than
required — but a reviewer who wants one should ask for it before the gate writes ~25 test methods.

| Item | Value |
|---|---|
| Verify-script baseline (pre-fix) | **`Result: 4 pass, 93 fail, 4 skip`** on untouched `origin/develop`. The 4 are C12/G1/G3/G4 — pre-existing invariant guards, correctly green before any code |
| Verify-script negative test | **Done, and repeated after every script edit.** It earned its keep twice: it caught a fail-open `check_F9` that passed against a tree with no service file, and it re-confirmed B5/B10/B29/B31/C1/G2 still fail on develop after those assertions were relaxed |
| **Verify-script final** | **`Result: 101 pass, 0 fail, 0 skip` with `RUN_MVN=1`** (mandatory — see the note below) |
| wms2-api commits | `9decc75` feat: kill switch + error codes · `6df09a4` fix: restore auto-receive · `3212fb8` fix: conformance-lane findings · `e973f2e` fix: security-review findings · **`54af623` fix: repair a fail-closed regression in the security fixes** |
| Branch / base | `bugfix/SBDEV-2778-restore-return-advice-auto-receive`, rebased onto `origin/develop` **`76054fc`**. ⚠ `develop` moved **twice** mid-implementation — `37bb39e` → `a0846d1` (SBDEV-2797 #121) → `76054fc` (SBDEV-2802 #122) — so the suite was re-run against each new base. Neither upstream change touched these files and neither added a migration |
| wms2-api PR | **[#123](https://github.com/SiteBossInc/wms2-api/pull/123)** into `develop`, opened 2026-08-03, 5 commits |
| ⚠ PR #123 was opened containing a HIGH | It was pushed after three lanes but **before** the scoped re-review returned. That lane found the fail-closed `oms_integration` check, which the UAT preflight then proved was a **live** break (`oms_integration` = 0 rows on `wsl-wineco-uat`, still at Flyway `2.2.05`). Fixed in `54af623` and explained in a [PR comment](https://github.com/SiteBossInc/wms2-api/pull/123#issuecomment-5173589449) so a reviewer who looked early does not review stale code. **Lesson: do not push before every lane has returned, even when the earlier lanes are clean.** |
| oms-laravel-api | **N/A — no OMS change (D1)** |
| Flyway | `V2.2.09__seed_return_advice_auto_receive_sysprop.sql` — **two** statements: the default-ON sysprop and the `oms_integration` operator user. Version chosen by sweeping ALL remote branches, not by listing the directory: **`V2.2.08` is held by SBDEV-2801 on an unmerged branch and is invisible from `develop`** |
| `mvn clean compile` | clean |
| `mvn test` | **4664 tests, 2 failures** — `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses` and `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`, both pre-existing on `develop` and confirmed by identity, not arithmetic. **ArchUnit violations still exactly 8** — no new `Optional.get()` in the service package |
| Tests added / retargeted | `ReturnAdviceAutoReceiveServiceUnitTest` **44** (new) · `AdviceRestControllerUnitTest` **54** (9 new, SBDEV-2236's guard retargeted to switch-OFF with a positive `state == OPEN` captor, 4 inverted tests deleted) · `FileImportControllerUnitTest` **41** (+AC10) · `ReceivingControllerUnitTest` **36** (+AC11) · `ReturnAdviceAutoReceiveIntegrationTest` **8 `@Disabled`** |
| ⚠ `RUN_MVN=1` is MANDATORY | Every `T*` check is a name-only grep, so sixteen empty test methods would satisfy `0 fail`. Only `M1`-`M4` execute them. The helper originally used `mvn -q`, which suppresses **both** grepped strings and made `M1`-`M4` **structurally unpassable** while the classes were green — so the acceptance line could never be produced. It now reads `target/surefire-reports/*.txt` |
| Deliberately-skipped coverage | Testcontainers ITs — `TODO(SBDEV-2217)`. **What this leaves guarded nowhere** is enumerated in the IT's own javadoc: R3's default-ON behavior at the real seam (the controller test can only assert delegation against a mocked service), that `V2.2.09` seeded both rows, the transaction boundaries, and the R9 no-burn property |
| SBDEV-2236 doc hygiene | **Done.** Its plan carries a SUPERSEDED banner and `status: superseded`; its verify script exits early with a pointer (neutralised rather than deleted — `sbdocs/` is not in git, so a deletion is unrecoverable) |
| Docs updated | `wms2-receiving-putaway-workflow.md` new **§3.5** + annotated lifecycle diagram; `wms2-state-machine-catalog.md` **§4.8** write sites. `last_verified` deliberately **NOT** bumped on either — only the touched sections were re-verified, and a blanket bump would assert coverage not performed |
| Review lanes | **3a conformance:** REQUEST_CHANGES → 12 findings, all addressed. **3b code review:** REQUEST CHANGES → 4 Medium + 5 Low + 6 nits. **3b security:** **HIGH** → 3 High + 4 Medium. **Scoped second pass over the fix commits: REQUEST CHANGES → 1 HIGH + 4 Medium, all regressions in the remediation itself.** Four lanes total; every one found something the others missed. |
| Consensus | Planner + Architect (pre-rewrite) · Critic 2026-08-03 (REVISE → 12 findings addressed) · conformance + code + security lanes as above. **Corrected 5 stale claims in my own plan along the way** — see the note below |

### Plan claims that turned out to be wrong

Recorded because the pattern matters more than any single item: several plan assertions were
**inferences stated as facts**, and the review lanes are what caught the consequential ones.

| Claim | Reality |
|---|---|
| Flyway version `V2.2.08` | **Taken** by SBDEV-2801 on an unmerged branch, invisible from `develop`. Now `V2.2.09`; §6.1-4 requires sweeping all remote branches and re-sweeping before the PR |
| §10-Q2 "Expected Date — new ticket, start in `wms2-web-ui`" | **Already fixed** on `develop` (`dfe24f8`, SBDEV-2660) and the location was wrong: an API serialization bug (`java.sql.Date` → midnight-UTC instant via `UtcDateSerializer`), not a UI render bug. "The stored value is correct" does not imply the bug is in the UI |
| §10-Q9 "`wms2-receiving-putaway-workflow.md` does not exist; the function-to-docs map has no entry" | **Both false.** The doc exists; `wms2-function-to-docs-map.md:188` already covers `AdviceRestController`. No doc-debt ticket needed — the two invalidated docs were updated instead |
| §6.1-14 "`PRINT_CASE_LABEL=false` ⇒ receiving succeeds but no label prints" | **Factually backwards.** `PrintService:152-155` returns `printerAvailable = false`, so `validate()` rejects and **every RETURN advice 400s forever**. Now a hard preflight item |
| §9-R11 "confirm the `IdempotencyFilter` TTL is short" | **There is no TTL** — cleanup is a daily 2am cron. The confirmation could only ever have come back "no" |
| §3 B2a "`resolveRefs` … package-private on a separate bean" | **Both suggested shapes were non-public, hence transaction-less.** A `protected`/package-private `@Transactional` method gets NO transaction (`publicMethodsOnly = true`) — invisible to compile, tests and grep, and the draft's own verify check certified the broken shape |

### Cap values — measured, not guessed (2026-08-03)

The F1 caps were proposed by the security lane and confirmed against live data before merge.

| Measurement | wineco-dev | hydra-dev2 | wsl-uat | Cap | Headroom |
|---|---|---|---|---|---|
| `adviceposition.externalid` max length | 16 | 15 | 16 | 64 | 4× |
| Rows over 64 chars | 0 / 42,375 | 0 / 861 | 0 / 52,158 | — | **nothing rejected** |
| `externalid` containing control chars | 0 | — | — | — | **nothing rejected** |
| Max positions per advice | — | 22 | **106** | 500 | 4.7× |
| Max `notifiedamount` | — | 12,348 | 14,784 | 100,000 | 6.8× |

**Dev alone would have been misleading:** hydra-dev2 peaks at 22 positions per advice, wsl-uat at
**106**. The 4.7× headroom is the real figure, not the 22× dev suggests.

**And the preflight found the fail-closed regression was a LIVE break, not a theoretical one:**
`oms_integration` returns **0 rows on wsl-uat**, which is still at Flyway `2.2.05`. The version of
this branch that was pushed to PR #123 would have rejected **every** return on that tenant the moment
it deployed. `anonymous` **is** present (1 row), and `PRINT_CASE_LABEL` **is** `'true'`, so the
degraded path works there.

### Residual risk accepted at merge

1. **Phantom inventory is possible by design** (BA decision, §9-R2). The kill switch is the mitigation, and it is **not instant** — `getSysvalue` is `@Cacheable("sysprops")`, so a flip takes up to the Caffeine TTL (~2 min) and is per-replica unless the `redis` profile is active (§10-Q14).
2. **Partial receive can still diverge from OMS** (§9-R1). Pre-validation removes every predictable trigger, but a mid-loop failure leaves WMS holding stock OMS rolls back. Accepted as v1 parity; option F is unavailable now that the trigger is the advice type alone.
3. **An unauthenticated endpoint now mutates inventory.** The network allowlist is the primary access control (§6.1-16). Caps bound the magnitude; they do not remove the exposure.
4. **No post-deploy unwind path** for stock already auto-received if the BA reverses again — §10-Q5 covers the *pre*-deploy OPEN-advice cleanup only.
