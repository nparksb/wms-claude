---
title: "SBDEV-2778 — Return to Inventory does not fully receive and close the return inbound BOL"
ticket: "SBDEV-2778"
ticket_url: "https://app.clickup.com/t/868kj2bv4"
type: "bug"
priority: "urgent"
status: "draft"
project:
  - wms2-api
  - oms-laravel-api
version: "v2"
requester: "Brent Campbell"
created: "2026-07-30"
updated: "2026-07-30"
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
**Project:** wms2-api (+ one field in oms-laravel-api) | **Version:** v2 | **Type:** bug
**Priority:** urgent
**Status:** draft — **consensus status: pending approval**
**Date:** 2026-07-30
**Assignees:** Nam Park, David Oppenheim

> ## ⚠️ THIS PLAN CONFLICTS WITH A MERGED TICKET — READ FIRST
>
> SBDEV-2778 asks to restore behavior that **[SBDEV-2236](../../../4-Archieves/wms2/plan/SBDEV-2236-return-advice-auto-receive-fix.md)
> deliberately deleted** (merged 2026-05-15, PR
> [wms2-api#24](https://github.com/SiteBossInc/wms2-api/pull/24), commit `7f9c250`, requester
> **David Oppenheim** — who is also an assignee on SBDEV-2778).
>
> SBDEV-2236 §3.2 explicitly rejected keeping auto-receive because it *"Conflicts with OMS-team
> requirement (from David Oppenheim) that physical confirmation must precede the WMS stock
> increment."*
>
> This plan does **not** revert SBDEV-2236. It re-introduces auto-receive **gated on an explicit
> per-advice assertion from OMS that Return QA already physically confirmed the goods**, so
> SBDEV-2236's invariant is preserved rather than overturned. An advice without that assertion keeps
> SBDEV-2236's create-only behavior unchanged.
>
> **§10-Q1 is a blocking open question for David Oppenheim.** Do not start implementation until it
> is resolved.

---

## 0. Affected sites (enumeration before drafting)

Enumerated by grep over `v2/wms2-api/src` and `v2/oms-laravel-api/app`, not from memory.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|---------------------|
| 1a | `controller/rest/AdviceRestController.java:198` | `adviceEntity = adviceRepository.save(adviceEntity)` — **first insertion point**: `validate()` must run immediately BEFORE this line, because nothing may be persisted before validation completes (see §3's ordering constraint and R9). | YES — THE gap | **YES** |
| 1b | `controller/rest/AdviceRestController.java:273-275` | End of the per-position save loop; control falls straight through to `messageService.createMessage` at `:277`. **Second insertion point**: `bind()` + `execute()`, after the positions have ids. | YES — THE gap | **YES** |
| 2 | `controller/rest/AdviceRestController.java:151-156` | Comment "RETURN/TRANSFER advice is eventually received via the mobile /receive path" + `client.getEnablereceiving()` guard | Comment becomes stale | **YES — update comment; keep guard unchanged** |
| 3 | `json/AdviceDto.java:41-42,52-58` | `@JsonProperty("printer_id") private Long printerId` — present but deliberately unread since SBDEV-2236 | Enabler | **YES — read it, and add the new `qa_confirmed` field** |
| 4 | `controller/rest/AdviceRestController.java:81-106` | Constructor (12 params, verified) | Enabler | **YES — add exactly ONE dep: `ReturnAdviceAutoReceiveService` (12→13). `ReceivingService` and `PrinterRepository` are injected into the new *service*, NOT the controller — that is the point of extracting it. Do not add unused ctor params to make a verify check green.** |
| 5 | `test/.../unit/controller/rest/AdviceRestControllerUnitTest.java:523-565` | `shouldCreateReturnAdviceWithoutAutoReceive` — asserts `receiveGoods` never called, states never FINISHED | Asserts current (post-2236) behavior | **YES — RETARGET to the unflagged case. Do NOT delete: it is SBDEV-2236's regression guard.** |
| 6 | `test/.../AdviceRestControllerUnitTest.java:566-…` | `shouldCreateReturnAdviceAndIgnorePrinterId` (`setPrinterId(42L)`) | Directly contradicts the new design | **YES — rewrite** |
| 7 | `controller/FileImportController.java:458` | `if (!REGULAR && !RETURN) throw` — file-import RETURN path is create-only | No — a file import carries no QA confirmation, so create-only is correct there | **OUT — leave alone; cite as the consistency proof** |
| 8 | `controller/rest/AdviceRestController.java:311` `createTransfer`, `:430` `createHubAndSpoke` | Separate advice ingress paths; no RETURN auto-receive | No | **OUT** |
| 9 | `controller/ReceivingController.java:267-284` `POST /v3/receiving/receive` → `receivingService.receiveGoods(...)` at `:284` | The legitimate operator receive path; must keep working for unflagged RETURN advices | No | **OUT — regression test only** |
| 10 | `service/ReceivingService.java:302-310` `receiveGoods(...)` (8-arg) | Reused as-is; signature identical to v1 `:308` | No — reused unmodified | **OUT — no edit** |
| 11 | `oms-laravel-api app/Services/Qa/QaReturnService.php:626-635` | Builds the Flow-1 `$advice` array. **This produced the repro row** (`reference_id = 'RETURN'.$parcel_id` = `RETURN529599`, parcel `529599`). Sends **no** `printer_id`. | Enabler — the QA assertion is set here | **YES (OMS — one field)** |
| 12 | `oms-laravel-api app/Services/WmsApiService.php:2116-2141` `createReturnAdvice` | Raw unauthenticated PUT to `/rest/advice/create`; `makeWmsRequest` wraps the dict in `[...]` | Pass-through | **YES — verify the new field survives serialization** |
| 13 | `oms-laravel-api QaReturnService.php:196-286` `receiveReturnInWms` (Flow 2 "Receive + Print") + `WmsApiService.php:2337` `buildAdvicePayload` | A **different payload contract** (`advice_type`/`client_code`/`expected_date`) vs Flow 1's (`type`/`client_id`/`day_of_delivery`). Sends `printer_id`. Did **not** produce the repro. | Divergent contract, not this root cause | **OUT — see §10-Q3; own follow-up ticket** |

**Coverage check:** in-scope rows 1, 2, 3, 4, 5, 6, 11, 12 each map to a §3 fix and a §9 verify-script
assertion. Rows 7, 8, 9, 10, 13 are excluded with rationale above.

**Prior plans on this call chain:**

| Plan | Relationship |
|---|---|
| `4-Archieves/wms2/plan/SBDEV-2236-return-advice-auto-receive-fix.md` | **Direct conflict** — see the banner and §10-Q1 |
| `4-Archieves/wms2/plan/SBDEV-2215-adviceservice-no-transaction-wrapping.md` | Related — advice-layer transaction wrapping |
| `1-Projects/wms2/plan/SBDEV-2729-system-sku-receiving-null-label-token.md` | **Active** — receiving/label-token path; coordinate before merge |
| `4-Archieves/scripts/verify-SBDEV-2236-return-advice-auto-receive-fix.sh` | Its negative assertions will start FAILING once this plan lands — see §9-R6 |

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
6. (Separate defect, out of scope — see §10-Q2) Expected Date appears one day off.

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
So this is not SBDEV-2206 / printer misconfiguration. Doubly refuted: the OMS path that produced the
repro (`sendReturnRestockAdvice`, `QaReturnService.php:626-635`) sends **no `printer_id` at all**.

**Q5 — second tenant, MCP `wms2-hydra-dev2`:** `RETURN/FINISHED` 9 (newest 2026-03-09), no
`RETURN/OPEN` rows.

### Reading the evidence honestly

`RETURN/FINISHED` stopping at 2025-04-22 is **not** evidence of a migration regression. Those 2,214
rows are migrated v1 data (WineCo's v2 cutover was later). The behavior was **removed on purpose** by
SBDEV-2236 on 2026-05-15, and wineco-dev has seen exactly **one** v2-era RETURN advice since — today's
repro. Dev volume is far too low to characterise production impact from these numbers; the code
evidence in §2, not the row counts, is what establishes the defect.

---

## 2. Root Cause Analysis

### Bug 1 — `AdviceRestController.create` has no RETURN completion step (by prior design)

**File:** `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java:273-275`

`create(List<AdviceDto>, Principal)` persists the `Advice` (`state=OPEN`, `:182`) and each
`Adviceposition` (`state=OPEN`, `:265`), then falls straight through to the service-log write at
`:277` and returns `204 No Content` at `:291`:

```java
                    LOG.debug("create {}", position);
                    advicepositionRepository.save(position);
                }        // :273 — end of per-position loop

            }            // :275 — end of per-advice loop

            try {        // :277 — service log; nothing RETURN-specific ever ran
```

v1 completes the RETURN case here. `v1/wms-api/.../AdviceRestController.java:272-319`:

```java
                if (adviceEntity.getType() == AdviceType.RETURN) {
                    List<Adviceposition> advicepositionList =
                        advicepositionRepository.findByAdviceId(adviceEntity.getId());
                    for (Adviceposition pos : advicepositionList) {
                        // boxtype: position → itemdata default → sysprop DEFAULT_BOX_TYPE → throw
                        Optional<Printer> printerOptional =
                            printerRepository.findByTypeAndProcessdefaultTrue(PrinterType.RETURN);
                        if (printerOptional.isPresent()) {          // v1:307 — SILENT SKIP, no else
                            receivingService.receiveGoods(pos.getId(), null, false,
                                pos.getNotifiedamount().intValue(),
                                pos.getNotifiedamount().intValue(), 1, boxtypeId,
                                printerOptional.get());
                        }
                    }
                    advicepositionRepository.updateAdvicepositionToStateByAdviceId(
                        AdviceState.FINISHED, adviceEntity.getId());
                    adviceRepository.updateAdviceToStateById(
                        AdviceState.FINISHED, adviceEntity.getId());
                }
```

**This absence is deliberate, not an oversight.** SBDEV-2236 deleted it because a RETURN *advice* by
itself does not prove goods arrived: *"The act of receiving — which exists to certify that goods are
physically present at the dock — is invoked at advice-creation time, when no goods are guaranteed to
exist anywhere except inside OMS's intent. The advice is born FINISHED."*
(`SBDEV-2236-…md:127-129`). Two tests now enforce the absence
(`AdviceRestControllerUnitTest.java:523`, `:566`).

**Why SBDEV-2778 is nonetheless a real defect.** SBDEV-2236 generalised from *"an advice is not proof
of arrival"* to *"WMS must never auto-receive an advice"*. That is too strong for the OMS Returns-QA
path specifically: OMS only sends this advice **after** a human completed Return QA on the physical
parcel — `QaReturnService.php:376` fires `sendReturnRestockAdvice` only when `$receiveNow` is true
**and** `ReturnMgmtLut::dispositionAdvisesWms($disposition)`. For that path the advice *is* backed by
a physical inspection.

The genuine defect is therefore **an information gap in the protocol, not a missing code block**:
`/rest/advice/create` gives WMS no way to distinguish "OMS intends to send goods" (must not
auto-receive) from "a human already counted these goods" (safe to auto-receive). Lacking that signal,
SBDEV-2236 correctly chose the conservative branch for *all* callers. §3 closes the gap by making the
assertion explicit, which lets both requirements hold simultaneously.

### Bug 2 — `printer_id` is accepted and silently ignored

`AdviceDto.java:41-42` declares `@JsonProperty("printer_id") private Long printerId` with accessors at
`:52-58`. No caller in `AdviceRestController` reads it — and
`AdviceRestControllerUnitTest.java:566` `shouldCreateReturnAdviceAndIgnorePrinterId` *asserts* that it
is ignored. OMS Flow 2 (`QaReturnService.php:225-242`) resolves
`rep_printer_prefs.wms_return_printer_id` and sends it, so the printer-preference feature OMS shipped
for SBDEV-2206 is dead on arrival in v2. Silently accepting a field you discard is its own defect.

### Bug 3 — no atomicity across positions, and external I/O inside a tenant transaction

Pre-existing structural hazard that the fix must confront rather than inherit.

- `AdviceRestController` has **no `@Transactional` anywhere** (grep: zero hits). v1's controller has
  none either.
- `ReceivingService.receiveGoods` **is** `@Transactional(value = "tenantTransactionManager",
  rollbackFor = {BusinessException.class, FacadeException.class})` at `:302`.
- So each `receiveGoods(...)` call from the non-transactional controller opens **its own** tenant
  transaction per loop iteration ⇒ **no atomicity across positions**. Position N throwing leaves
  positions 1..N−1 **committed as received** while the parent advice stays **OPEN**.
  SBDEV-2236 documented exactly this at `:131-137` and mooted it by deleting the loop; re-introducing
  the loop re-introduces the hazard.
- `receiveGoods`'s **first statement** is external CUPS HTTP I/O:

```java
    @Transactional(value = "tenantTransactionManager", rollbackFor = {...})   // :302
    public void receiveGoods(long advicePositionId, ...) throws BusinessException, FacadeException {
        LOG.debug("start");
        if (!printService.isPrintAvailable(printer.getAddress())) {           // :315 — HTTP, in-tx
            throw new BusinessException("Printer not available. Cannot process receiving.");
        }
```

  A tenant DB connection is therefore held across a CUPS round-trip, **once per advice position**.

Supporting facts: the two bulk state-flip queries (`AdviceRepository.java:28-32`,
`AdvicepositionRepository.java:28-32`) are `@Modifying(clearAutomatically = true)` + bare
`@Transactional` — correct, because `net.aim_ai.wms.repo.jpa` repositories inherit
`tenantTransactionManager` from `@EnableJpaRepositories` (documented exception in
`v2/wms2-api/CLAUDE.md`). Both are also `@RestResource`-exposed, i.e. HTTP-reachable state mutation.

---

## 3. Fix Design

### Design principles

1. WMS decides whether to auto-receive from **an explicit assertion carried by the request**, never
   from the advice type alone. Absent the assertion, post-SBDEV-2236 behavior is preserved
   byte-for-byte.
2. **Everything *auto-receive adds* as a rejection reason is checked BEFORE the first row is
   persisted** — printer resolvability, printer reachability, boxtype resolvability. See the ordering
   constraint below; this is not a nicety, it prevents a permanently-stuck return.

   ⚠ **The stronger property — "nothing that can reject this advice runs after a save" — is NOT
   delivered, and cannot be without changing the `REGULAR` path.** `adviceRepository.save(...)` commits
   at `:198`, and the pre-existing per-position validation runs *after* it at `:203-251`, with **eight**
   throw sites: `reference_id` unset (`:203`), `client_id` unset (`:206`), position client not found
   (`:212`), `sku` unset (`:216`), duplicate SKU in the advice (`:222`), `amount_of_bottles`
   null/negative (`:227`, `:230`), itemdata not found (`:236`), `UNIT_LOAD_TYPE_BOX` missing (`:241`),
   unknown `box_id` (`:248`). Each throws with the `Advice` row already committed — R9's brick scenario
   in full — and on a multi-position advice, positions 1..K−1 are committed too (`:272`).
   **Option (a), recommended:** have `validate()` mirror those position checks for flagged advices.
   It already walks every position for boxtype, so the traversal exists; the loop's later re-checks
   become redundant-but-harmless, at the cost of one duplicated validation block (drift risk — note it
   in review). **Option (b):** accept the residual and rely on R9's scoping. Either way the property
   above is what the design delivers today, and **§3.5 option F does not help here** — with N=1 the
   position validations still run after `:198`.

### The ordering constraint (why validation precedes persistence)

`create()` is **not** `@Transactional`, so `adviceRepository.save(adviceEntity)` at `:198` and each
`advicepositionRepository.save(position)` at `:272` are **already committed** by the time any
post-loop code runs. A validation failure *after* those saves therefore leaves behind:

- an orphan `Advice` in `state=OPEN` holding `externalid = RETURN{parcel_id}`, and
- OMS rolling the whole return back (`QaReturnService.php:330` wraps it in
  `DB::connection('tenant')->transaction(...)`), so OMS forgets the return entirely.

The operator then retries, and the retry hits the duplicate-`externalid` guard at
`AdviceRestController.java:139-142` → `ENTITY_ALREADY_EXITS`. **The return is now unmanageable
without manual DB intervention.** This is not an exotic path: §6.1 prereq 2 means *every* flagged
advice 400s on a tenant with no `processdefault` RETURN printer, so a misconfigured tenant would
brick every return it processed. Any design that validates after persisting is therefore wrong,
regardless of how good its error message is.

Hence **Fix B0**: for `RETURN` + `qa_confirmed` only, a read-only pre-validation pass runs over the
DTO *before* the advice is saved. The `REGULAR` path is untouched.

### Fix A — add `qa_confirmed` to the advice contract

**File:** `json/AdviceDto.java` (after `:42`)

```java
    @JsonProperty("printer_id")
    private Long printerId;

    /**
     * Sender's assertion that the goods described by this advice were PHYSICALLY inspected and
     * counted before this call (OMS Returns QA). Only when true may WMS synthesise a goods receipt
     * at advice-creation time. Absent/null/false => advice is created OPEN and awaits a dock scan,
     * preserving the SBDEV-2236 invariant that physical confirmation precedes the stock increment.
     */
    @JsonProperty("qa_confirmed")
    private Boolean qaConfirmed;

    public Boolean getQaConfirmed() { return qaConfirmed; }

    public void setQaConfirmed(Boolean qaConfirmed) { this.qaConfirmed = qaConfirmed; }
```

`Boolean` (not `boolean`) so absent and explicit-`false` are both representable and both mean
"do not auto-receive". An older OMS talking to a newer WMS omits the field ⇒ unchanged behavior. This
is the back-compat guarantee, and it is why no sysprop gate is needed (§3.5).

### Fix B — extract `ReturnAdviceAutoReceiveService`

**New file:** `service/ReturnAdviceAutoReceiveService.java`

Auto-receive does **not** go inline in the controller. It goes in a service so the validation
validation can be a single read-only tenant transaction and the per-position receives stay in their
own short transactions.

```java
@Service
public class ReturnAdviceAutoReceiveService {

    private static final Logger LOG =
        LoggerFactory.getLogger(ReturnAdviceAutoReceiveService.class);

    private final AdviceRepository adviceRepository;
    private final AdvicepositionRepository advicepositionRepository;
    private final ItemdataRepository itemdataRepository;
    private final BoxtypeRepository boxtypeRepository;
    private final PrinterRepository printerRepository;
    private final SyspropRepository syspropRepository;
    private final ReceivingService receivingService;

    public ReturnAdviceAutoReceiveService(AdviceRepository adviceRepository,
                                          AdvicepositionRepository advicepositionRepository,
                                          ItemdataRepository itemdataRepository,
                                          BoxtypeRepository boxtypeRepository,
                                          PrinterRepository printerRepository,
                                          SyspropRepository syspropRepository,
                                          ReceivingService receivingService) { /* assign */ }

    /**
     * Phase 0 (Fix B0) — validate EVERYTHING that can reject this advice, BEFORE the caller
     * persists anything. Operates on the DTO, resolves the printer, asserts the printer is
     * REACHABLE, and resolves a boxtype for every position. Throws => caller has saved nothing,
     * so no externalid is burned and the operator can simply retry.
     *
     * Called from AdviceRestController BEFORE adviceRepository.save(...) at :198.
     *
     * NOT @Transactional — it sequences a short read-only tenant tx (resolveRefs) followed by the
     * CUPS availability probe OUTSIDE that tx. See B2a for why the split is mandatory.
     */
    public ValidatedAutoReceive validate(AdviceDto adviceDto)
            throws WebserviceBusinessExceptionClientSide { /* see B2a */ }

    /** DB reads only. Must be proxied — a plain this.resolveRefs(...) skips the annotation. */
    @Transactional(value = "tenantTransactionManager", readOnly = true)
    protected ResolvedRefs resolveRefs(AdviceDto adviceDto)
            throws WebserviceBusinessExceptionClientSide { /* see B1, B2 */ }

    /**
     * Phase 1 — bind the validated plan to the now-persisted adviceposition rows. Pure mapping
     * (position externalid -> id); no new failure modes.
     */
    public AutoReceivePlan bind(ValidatedAutoReceive validated, Long adviceId) { /* ... */ }

    /**
     * Phase 2 — execute. Each receiveGoods opens its own tenant tx (ReceivingService:302).
     * Deliberately NOT @Transactional — see the three reasons in "Why execute() is not
     * transactional" below.
     */
    public void execute(AutoReceivePlan plan)
            throws WebserviceBusinessExceptionClientSide { /* see B3 */ }
}
```

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

Deliberate divergence from v1: an explicitly-supplied `printer_id` that is missing or not of type
RETURN **throws** rather than falling back to the default. A caller that names a printer has an
intent; silently substituting a different one prints the label somewhere the operator is not standing.
And when nothing resolves, this throws where v1 `:307` silently skipped — v1's silent skip is the
shape that produces an inexplicably-open BOL, which is precisely what the ticket's error-handling
section forbids.

#### B2 — boxtype fallback chain (ported from v1 `:279-304`)

> **Do NOT port v1's chain verbatim — most of it is unreachable on this path.** v1
> `AdviceRestController:279-304` walks `position.boxtypeId` → `itemdata.defaultboxtypeId` → sysprop
> `DEFAULT_BOX_TYPE` → throw. On the REST create path that fallback **cannot execute**, in either
> version: `:262` (v1 `:259`) unconditionally does `position.setBoxtypeId(optionalBoxtype.get().getId())`,
> so by the time any RETURN block runs, `boxtypeId` is always populated — or the request already
> failed. Porting the chain would add three branches with no reachable input.

**What `validate()` actually needs to do:** resolve the boxtype the save loop *will* persist, using the
same lookup the loop uses — `boxtypeRepository.findByExternalid(advicePosition.getBoxId())`
(`:247`) — so the two cannot disagree. Keep the sysprop/itemdata fallback **only** as a defensive
`orElseThrow` on `WmsConstants.DEFAULT_TYPE_NOT_EXIST` (`:1241`), not as a live chain. If the
implementer finds a reachable null-boxtype input, that is a finding to report, not a branch to guess at.

Related prerequisite: OMS hard-codes `'box_id' => 1` (`QaReturnService.php:747`), looked up by
`findByExternalid`, so every tenant needs a `boxtype` row with `externalid = '1'` or `:249` throws
`ENTITY_DOES_NOT_EXISTS` — added to §6.1.

> **Latent defect found while writing this plan (out of scope — §10-Q10).**
> `AdviceRestController.java:245-262`: `Optional<Boxtype> optionalBoxtype = null;` is assigned **only**
> inside `if (StringUtils.isNotEmpty(advicePosition.getBoxId()))`, but `:261` calls
> `optionalBoxtype.get()` unconditionally ⇒ **NullPointerException ⇒ HTTP 500** whenever `box_id` is
> omitted. It never fires today only because OMS always sends `box_id`. v1 has the identical shape at
> `:258`. Not caused by this plan and not fixed by it; `validate()` must not depend on that value being
> safe. Own ticket.

#### B2a — assert the printer is REACHABLE during validation, not mid-loop

`receiveGoods`'s first statement is `if (!printService.isPrintAvailable(printer.getAddress()))`
(`ReceivingService.java:315`), throwing `BusinessException` when CUPS is down. Left alone, that check
runs **N times against the same address** — once per position, each inside its own tenant
transaction — and a CUPS outage therefore fails at *position 1, mid-execute*, which is exactly R1's
trigger. Checking it during validation makes a CUPS outage a clean 400 with zero receives and zero rows
persisted.

**The CUPS call must not run inside the read-only tenant transaction.** Putting it there would reproduce
the very anti-pattern §2 Bug 3 and §10-Q6 condemn, just one level up. So `validate()` is split:

```java
    /** Public entry point — NOT @Transactional. Orders the work so CUPS I/O is outside the tx. */
    public ValidatedAutoReceive validate(AdviceDto dto) throws WebserviceBusinessExceptionClientSide {
        ResolvedRefs refs = resolveRefs(dto);                       // read-only tenant tx, short
        if (!printService.isPrintAvailable(refs.printer().getAddress())) {   // OUTSIDE any tx
            throw new WebserviceBusinessExceptionClientSide(
                WmsConstants.PRINTER_NOT_AVAILABLE, null, refs.printer().getName());
        }
        return refs.toValidated();
    }

    /** Only the DB reads are transactional. */
    @Transactional(value = "tenantTransactionManager", readOnly = true)
    protected ResolvedRefs resolveRefs(AdviceDto dto) throws WebserviceBusinessExceptionClientSide {
        /* B1 printer + B2 boxtype per position */
    }
```

Note `resolveRefs` must be invoked so the proxy applies (self-injection or package-private + a separate
bean); a plain `this.resolveRefs(...)` call bypasses the `@Transactional` proxy entirely. The verify
script asserts the annotation on the **resolve** step, not on `validate`.

All positions share one `Printer`, and `receiveGoods` touches it only via `getAddress()` and
`getName()` (`:315`, `:316`, `:319`, label block ~`:542`, `:547`) — no lazy navigation — so a detached
instance suffices.

All positions share one `Printer`, and `receiveGoods` touches it only via `getAddress()` and
`getName()` (`:315`, `:316`, `:319`, and the label block ~`:542`, `:547`) — no lazy navigation — so
hoisting the check is safe and a detached instance suffices. This does **not** remove the redundant
in-loop check (that would mean editing `ReceivingService`, which the mobile dock path shares —
deferred to §10-Q6); it front-runs it. Residual TOCTOU: CUPS can die between `validate()` and
position K. That window is unavoidable without §10-Q6 and is explicitly accepted.

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
   so `execute()`'s catch-and-report would be a lie and the subsequent state flips would themselves
   fail. Wrapping the loop is not merely suboptimal; it is incorrect.

#### B3 — execute, then flip state

```java
    public void execute(AutoReceivePlan plan) throws WebserviceBusinessExceptionClientSide {
        int received = 0;
        for (AutoReceiveLine line : plan.lines()) {
            try {
                receivingService.receiveGoods(line.advicePositionId(), null, false,
                    line.amount(), line.amount(), 1, line.boxtypeId(), plan.printer());
                received++;
            } catch (BusinessException | FacadeException e) {
                LOG.error("RETURN auto-receive PARTIAL FAILURE adviceId={} adviceNumber={} "
                        + "failedSku={} failedPositionExternalId={} received={} of={}",
                    plan.adviceId(), plan.adviceNumber(), line.sku(), line.positionExternalId(),
                    received, plan.lines().size(), e);
                throw new WebserviceBusinessExceptionClientSide(
                    WmsConstants.RETURN_AUTO_RECEIVE_PARTIAL, e,
                    plan.adviceNumber(), line.sku(), received, plan.lines().size());
            }
        }
        advicepositionRepository.updateAdvicepositionToStateByAdviceId(
            AdviceState.FINISHED, plan.adviceId());
        adviceRepository.updateAdviceToStateById(AdviceState.FINISHED, plan.adviceId());
    }
```

The state flips run **only after every position succeeded**. The advice is never marked FINISHED with
an unreceived position — the failure mode the ticket calls out.

### Fix C — gate the call in `AdviceRestController`

**File:** `controller/rest/AdviceRestController.java` — **two** insertion points, because validation
must precede persistence (see the ordering constraint above).

**C-1 — before the advice is saved.** Insert immediately before `adviceEntity = adviceRepository.save(adviceEntity)`
at `:198`:

```java
                // RETURN advice is received at the dock (POST /v3/receiving/receive) UNLESS the
                // sender asserts Return QA already physically confirmed the goods (SBDEV-2778).
                // Validate FIRST: create() is not @Transactional, so anything saved below is
                // committed, and a later throw would burn externalid=RETURN{parcel_id} and leave
                // an orphan OPEN advice that blocks every retry (:139-142).
                ReturnAdviceAutoReceiveService.ValidatedAutoReceive validated = null;
                boolean autoReceive = AdviceType.RETURN.equals(adviceDto.getType())
                        && Boolean.TRUE.equals(adviceDto.getQaConfirmed());
                if (autoReceive) {
                    validated = returnAdviceAutoReceiveService.validate(adviceDto);
                }

                adviceEntity = adviceRepository.save(adviceEntity);   // :198 unchanged
```

**C-2 — after the positions are saved.** Insert between `:273` and `:275`:

```java
                }   // :273 — end of per-position loop

                if (autoReceive) {
                    returnAdviceAutoReceiveService.execute(
                        returnAdviceAutoReceiveService.bind(validated, adviceEntity.getId()));
                }

            }   // :275 — end of per-advice loop
```

Notes:

- The gate reads `adviceDto.getType()` in C-1 (the entity's type is not assigned until `:190-196`)
  and the `autoReceive` local carries the decision to C-2, so the type check is evaluated once.
- `Boolean.TRUE.equals(...)` is null-safe: absent ⇒ false ⇒ create-only.
- Constructor (`:81-106`, **12 params, verified**) gains **exactly one** dep,
  `ReturnAdviceAutoReceiveService` (12→13). `ReceivingService` and `PrinterRepository` go into the new
  *service*, not the controller — see §0 row 4.
- Update the now-stale comment at `:151-156` to say RETURN advice is received at the dock *unless*
  `qa_confirmed` is set.
- `validate()` re-reads client/itemdata that the position loop reads again at `:210`/`:234`. That
  duplicate read is accepted: returns carry 1-3 positions, and the alternative (restructuring the
  shared loop to build positions in memory first) would change the `REGULAR` path's shape for no
  behavioral gain. Flagged advices only.

### Fix D — OMS sets the assertion (one field)

**File:** `v2/oms-laravel-api/app/Services/Qa/QaReturnService.php:626-635`

```php
         $advice = [
             'client_id' => $client?->client_code ?? '',
             'facility_code' => $facilityCode,
             'day_of_delivery' => app(WarehouseTimeService::class)->todayForFacility($facilityCode),
             'positions' => $positions,
             'delivery_note_number' => $shipmentId,
             'reference_id' => $shipmentId,
             'shipment_id' => $shipmentId,
             'type' => 'RETURN',
+            // Return QA physically inspected and counted these items before this call, so WMS may
+            // receive them immediately instead of waiting for a dock scan (SBDEV-2778). Only ever
+            // true on this path: it is reached solely when $receiveNow && dispositionAdvisesWms().
+            'qa_confirmed' => true,
         ];
```

This path is reached only via `QaReturnService.php:376` (`$receiveNow &&
ReturnMgmtLut::dispositionAdvisesWms($disposition)`), so the assertion is true by construction.
Verify the field survives `WmsApiService::createReturnAdvice` → `makeWmsRequest`
(`WmsApiService.php:2116-2141`), which wraps the dict in `[...]` — it passes the array through
unfiltered, but confirm with the request log.

### 3.5 Why this design and not the alternatives

| Option | Description | Verdict |
|---|---|---|
| **A — QA-gated auto-receive** *(chosen)* | New `qa_confirmed` assertion; auto-receive only when set | Satisfies SBDEV-2778 **and** SBDEV-2236 simultaneously — the only option that does. Back-compat by construction (absent field ⇒ old behavior). Reversible without a WMS redeploy: OMS stops sending the field. Makes the previously-implicit trust boundary explicit and auditable. |
| **B — Straight revert of SBDEV-2236** | Unconditional auto-receive for every RETURN advice | **Rejected.** Re-introduces the phantom-inventory defect 2236 documented over 2,215 rows, contradicts the stated OMS-team requirement, re-breaks the FileImportController/REGULAR symmetry 2236 established, and silently overrides a merged decision by an assignee of this very ticket. |
| **C — Sysprop-gated revert (default OFF)** | Unconditional auto-receive behind a per-tenant flag | **Rejected.** Makes inventory truth a config toggle, and *still* auto-receives file-import and any future RETURN caller once ON — it gates *who is affected*, not *whether confirmation happened*. Default OFF also ships the urgent symptom unfixed. |
| **D — Fix on the OMS side** | OMS calls the existing receive path per position after creating the advice | **Rejected on feasibility.** `POST /v3/receiving/receive` is authenticated (`ReceivingController extends AdminController`, `:31`) and expects pallet/boxtype context OMS does not hold. It also moves warehouse business logic into OMS and multiplies OMS→WMS round-trips per return. Architecturally cleaner in the abstract; materially worse here. |
| **E — New `PENDING_CONFIRMATION` advice state** | 2236 §3.2 Option B: new state + reconcile endpoint | **Rejected** for the same reason 2236 did — new `AdviceState` value + Flyway migration + reconcile endpoint + mobile UI work, ~5× the scope, no behavioral win over A. |
| **F — A, but restrict `qa_confirmed` to SINGLE-position advices** | Reject a flagged advice carrying >1 position with a 400; multi-SKU returns either use dock receiving or OMS splits them one-advice-per-SKU | **OPEN AND BLOCKING — recommended; decide before implementation (see §10-Q4).** With N=1 the partial-failure class in R1 becomes *structurally impossible* rather than reported: there is no "positions 1..N−1 committed" state to diverge. Since R1's mitigation is the weakest part of this plan, eliminating the failure mode beats reporting it. Cost is bounded — returns carry 1-3 positions, the repro carries 1 — but it pushes multi-SKU handling onto OMS and needs that split logic scoped. **Decide together with §10-Q4 — this is NOT a soft flag.** Choosing F flips concrete deliverables: §8 AC9 / verify T9 (`shouldAutoReceiveAllPositionsOfMultiPositionReturnAdvice`) **inverts** to a 400 test; `RETURN_AUTO_RECEIVE_PARTIAL` (§5 `WmsConstants` row, §6.2 step 3, verify E1/E2/B15/B16), §8's `executeThrowsPartialFailure…` / T10, and §3 B3's entire catch block all become **dead**; and the §5 `getErrorMap()` change (§6.2 step 4) loses its justification. ~8 verify assertions plus two shared-code changes hinge on it, so an implementer cannot start and `wms-tdd-gate` would write tests destined for deletion. |

---

## 4. Architecture Overview

```
 OMS (oms-laravel-api)                          WMS (wms2-api)
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
      sendReturnRestockAdvice()           :584
        builds $advice{ type:RETURN,
                        reference_id:'RETURN'.parcel_id,
                        positions[],
                        qa_confirmed:true }   ◄── Fix D
          │
          ▼
      WmsApiService::createReturnAdvice()  :2116
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
                                                  ├─ if RETURN && qa_confirmed   ◄── Fix C-1
                                                  │    ▼
                                                  │  ReturnAdviceAutoReceiveService.validate(dto)
                                                  │    @Transactional(tenantTM, readOnly)   ◄── Fix B0
                                                  │    ├─ resolvePrinter()          B1
                                                  │    ├─ isPrintAvailable()  ONCE  B2a
                                                  │    └─ resolve boxtype per position  B2
                                                  │    └─ throws => NOTHING persisted yet,
                                                  │       externalid not burned (R9)
                                                  │
                                                  ├─ save Advice   state=OPEN    :182,198
                                                  ├─ save Adviceposition(s) OPEN :265,272
                                                  │
                                                  ├─ if RETURN && qa_confirmed   ◄── Fix C-2
                                                  │    ▼
                                                  │  bind(validated, adviceId)  then
                                                  │  execute()   NOT @Transactional (B2b)
                                                  │         ├─ per position:
                                                  │         │   ReceivingService.receiveGoods() :302
                                                  │         │     @Transactional(tenantTransactionManager)
                                                  │         │     ├─ printService.isPrintAvailable() :315
                                                  │         │     │     ⚠ CUPS HTTP *inside* the tx
                                                  │         │     ├─ create Unitload + Stockunit
                                                  │         │     ├─ create Goodsreceipt(+position)
                                                  │         │     └─ print UL label
                                                  │         ├─ updateAdvicepositionToStateByAdviceId(FINISHED)
                                                  │         └─ updateAdviceToStateById(FINISHED)
                                                  │
                                                  ├─ messageService.createMessage(ADVICE_IMPORT) :279
                                                  └─ 204 No Content                              :291

 Unflagged RETURN advice (and every file-import RETURN) stays OPEN and is received at the dock:
   Mobile → POST /v3/receiving/receive → ReceivingController:267-284 → receiveGoods()
```

### Key files

| File | Lines | Role |
|---|---|---|
| `v2/wms2-api/.../controller/rest/AdviceRestController.java` | 109-308 | Advice ingress; `:273-275` insertion point; `:151-156` stale comment; `:81-106` ctor |
| `v2/wms2-api/.../json/AdviceDto.java` | 41-58 | `printer_id`; new `qa_confirmed` |
| `v2/wms2-api/.../service/ReturnAdviceAutoReceiveService.java` | new | validate (pre-persist) + bind + execute |
| `v2/wms2-api/.../service/ReceivingService.java` | 302-315 | `receiveGoods`; CUPS call inside the tenant tx |
| `v2/wms2-api/.../repo/jpa/PrinterRepository.java` | 18 | `findByTypeAndProcessdefaultTrue` |
| `v2/wms2-api/.../repo/jpa/AdviceRepository.java` | 28-32 | `updateAdviceToStateById` |
| `v2/wms2-api/.../repo/jpa/AdvicepositionRepository.java` | 28-32 | `updateAdvicepositionToStateByAdviceId` |
| `v2/wms2-api/.../service/WmsConstants.java` | 565, 1081-1082, 1241 | `PrinterType.RETURN`, boxtype sysprop, `DEFAULT_TYPE_NOT_EXIST` |
| `v2/oms-laravel-api/app/Services/Qa/QaReturnService.php` | 376, 584-644 | Gate + Flow-1 advice payload |
| `v2/oms-laravel-api/app/Services/WmsApiService.php` | 2116-2141 | `createReturnAdvice` |

---

## 5. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `json/AdviceDto.java` | Modify | Add `qaConfirmed` (`Boolean`, `@JsonProperty("qa_confirmed")`) + accessors |
| `service/ReturnAdviceAutoReceiveService.java` | **Add** | `validate()` + `bind()` + `execute()`, printer/boxtype resolution, partial-failure reporting |
| `controller/rest/AdviceRestController.java` | Modify | Gated call at `:273-275`; ctor gains the new service; refresh comment `:151-156` |
| `service/WmsConstants.java` | Modify | Add `RETURN_AUTO_RECEIVE_PARTIAL = 600` in the `:1228-1245` constant block, **plus an arm in BOTH switches**: `getErrorCodeText` (template, switch starts `:1247`) and `getErrorCodeName` (symbolic string, switch ~`:1320`). Codes are grouped by domain (100s validation / 200 default-type / 300 club-line / 400 transfers / 500 receiving) so 600 is the next free group. **Do not copy the live bug at `NOT_ENABLLED_FOR_RECEIVING = 500`, which has a `getErrorCodeText` arm (~`:1294`) but is missing from `getErrorCodeName` and silently degrades to the generic name.** |
| `exceptions/WebserviceBusinessExceptionClientSide.java` | Modify | `getErrorMap()` (`:46-51`) currently emits only `status` + `description`, so **no error code has ever reached OMS**. Add `code` + `errorCodeName`. Audit other `/rest` consumers first — this changes every `/rest` error body. See R1. |
| `test/.../unit/controller/rest/AdviceRestControllerUnitTest.java` | Modify | Retarget `:523` to the unflagged case; rewrite `:566`; add the flagged cases |
| `test/.../unit/service/ReturnAdviceAutoReceiveServiceUnitTest.java` | **Add** | Validation, printer, boxtype, partial-failure coverage |
| `oms-laravel-api app/Services/Qa/QaReturnService.php` | Modify | One line: `'qa_confirmed' => true` |
| `oms-laravel-api tests/Unit/Services/Qa/QaReturnServiceValidationTest.php` | Modify | Assert the payload carries `qa_confirmed => true` |

**No Flyway migration.** No schema change: `qa_confirmed` is a request field, not a column, and the
advice/position state values already exist.

---

## 6. Implementation Steps

### 6.1 Prerequisites

| # | Category | Requirement | Owner |
|---|---|---|---|
| 1a | **BLOCKING — ask first** | **§10-Q0** — is OMS's `receiveReturnInWms` (Flow 2, "Receive + Print") already the sanctioned path? If yes, Fix A and Fix D are the wrong shape and this plan is superseded. Asking Q1 before Q0 answers the wrong question. | OMS + David Oppenheim |
| 1b | **BLOCKING** | **§10-Q1 (a)+(b)+(c)** resolved by David Oppenheim — the SBDEV-2236 conflict, including (c) the `CODE_RECEIVING_RETURN` notification timing shift he signed off the *other* way in 2236. **No code until this is signed off.** | David Oppenheim |
| 1c | **BLOCKING** | **§10-Q4 / §3.5 option F** — partial-receive reconciliation. Not cosmetic: ~8 verify assertions, the `RETURN_AUTO_RECEIVE_PARTIAL` constant and the shared `getErrorMap()` change all flip on this answer, so an implementer cannot start without it and R1 stays only partially mitigated until it lands. | OMS |
| 2 | DB state | Per target tenant, a `processdefault=true` `type='RETURN'` printer must exist, else every flagged advice 400s. Confirmed present on wineco-dev (`id=30346045`). **Verify on every tenant before enabling.** | Implementer |
| 3 | DB state | Per target tenant, a `boxtype` row with `externalid = '1'` must exist — OMS hard-codes `'box_id' => 1` (`QaReturnService.php:747`) and `:247` resolves it via `findByExternalid`, throwing `ENTITY_DOES_NOT_EXISTS` at `:249` otherwise. This gates advice creation itself, flagged or not. `los_sysprop` `DEFAULT_BOX_TYPE` is **not** required — see §3 B2, the fallback chain is unreachable on this path. | Implementer |
| 4 | Config / env | None. No new sysprop (§3.5 option C rejected); no `application.properties` change. | — |
| 5 | Feature flags | None in WMS. The de-facto switch is OMS sending `qa_confirmed` — see §9-R5 for rollout order. **Operational consequence, stated explicitly: WMS has NO kill switch of its own.** If auto-receive misbehaves in production the rollback is *reverting the OMS one-liner* (Fix D) and shipping OMS — so before enabling on any production tenant, record who can ship an OMS hotfix and the expected time-to-revert. If that number is unacceptable, revisit §3.5 option C. | Implementer + OMS on-call |
| 6 | **Deploy order** | **WMS first, OMS second.** A new WMS ignoring an absent field is a no-op; an old WMS receiving `qa_confirmed` silently discards it (Jackson `FAIL_ON_UNKNOWN_PROPERTIES` is disabled) and returns 204 while receiving nothing — indistinguishable from today's bug. Never deploy OMS first. | Implementer |
| 7 | Data migration | None in this plan. RETURN advices left OPEN between 2026-05-15 and this deploy are a separate cleanup — §10-Q5. | Ops (follow-up) |
| 8 | External systems | CUPS must be reachable from WMS pods; `receiveGoods:315` fails the whole advice if not. | Implementer |
| 9 | Monitoring | Add the §7 Micrometer counters before enabling on any production tenant. | Implementer |
| 10 | Coordination | `SBDEV-2729` (active) touches the receiving/label path — rebase order to be agreed. | Implementer |

### 6.2 Steps (each atomically committable)

1. **Baseline the verify script** — run `bash sbdocs/9-System/scripts/verify-SBDEV-2778-return-to-inventory-not-received-bol-not-closed.sh`, capture the all-FAIL baseline, paste it in §11.
2. **Fix A** — `AdviceDto.qaConfirmed` + accessors. Commit.
3. **`WmsConstants`** — `RETURN_AUTO_RECEIVE_PARTIAL = 600` in the `:1228-1245` block **plus an arm in BOTH** `getErrorCodeText` (~`:1247`) and `getErrorCodeName` (~`:1320`). NOT `messages_en_US.properties` — that file holds `state.*` UI labels only. Commit.
4. **`getErrorMap()` carries the code** — `WebserviceBusinessExceptionClientSide:46-51` gains `code` + `errorCodeName`. **Audit every `/rest` consumer first** (this changes all `/rest` error bodies). Hard prerequisite for R1; without it no error code has ever reached OMS. Commit separately so it can be reviewed/reverted on its own.
5. **Fix B0 (validate)** — `ReturnAdviceAutoReceiveService.validate(AdviceDto)` with B1 (printer), B2a (`isPrintAvailable` once), B2 (boxtype via `findByExternalid`), plus the `ValidatedAutoReceive` record. Unit tests for every throw path. Commit.
6. **Fix B (bind + execute)** — `bind()` mapping and `execute()` with the partial-failure contract and the B2b no-`@Transactional` rationale in a comment. Unit tests incl. the position-2-throws case. Commit.
7. **Fix C** — **both** call sites: `validate()` before `:198` (C-1) and `bind()`+`execute()` between `:273-275` (C-2); ctor gains exactly one dep; refresh the `:151-156` comment. Commit.
8. **Retarget the SBDEV-2236 tests** — the unflagged guard (`@DisplayName :523`, method `:524`) keeps its HTTP-204 assertion and gains a positive `state == OPEN` capture; rewrite `:566`; add the flagged cases (§8 AC1-AC10). Commit.
9. **Regression** — confirm `POST /v3/receiving/receive` still receives an unflagged OPEN RETURN advice (§8 AC11).
10. **`mvn clean compile`** then `mvn test -Dtest=AdviceRestControllerUnitTest` and `-Dtest=ReturnAdviceAutoReceiveServiceUnitTest`, then the full `mvn test`. Revert the mutated `archunit_store`.
11. **Fix D (OMS)** — one line + its test. Separate PR in `oms-laravel-api`. **Merges after WMS ships.**
12. **Re-run the verify script** — require `Result: N pass, 0 fail`; paste the line in §11.
13. **Update §11** with SHAs, PR links, test counts, and the verify line.

---

## 7. Horizontal Scalability Validation

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | In-JVM state | **No** | `ReturnAdviceAutoReceiveService` is stateless; no static/ThreadLocal/Caffeine added |
| 2 | Connection pool math | **Yes** | `resolveRefs` holds one short read-only tenant connection (the CUPS probe in `validate` runs **outside** it — B2a); then N sequential `receiveGoods` transactions, each holding a connection across a CUPS round-trip (`ReceivingService:315`). Worst case per request ≈ N × CUPS timeout. Returns are typically 1-3 positions (repro = 1). Recompute `replicas × tenants × maxPoolSize` before enabling a high-volume tenant. |
| 3 | Scheduled jobs | **N/A** | No `@Scheduled` added |
| 4 | Long transactions | **Yes** | Pre-existing `ReceivingService:302`+`:315` — external HTTP inside a tenant tx. This plan multiplies the occurrences per request but does not create the pattern, and deliberately does **not** wrap the loop in an outer transaction, which would hold one connection across *all* N CUPS calls. **Follow-up:** hoist `isPrintAvailable` out of the tx (§10-Q6). |
| 5 | Request affinity | **No** | Single synchronous request; no session/WebSocket/SSE state |
| 6 | Retry / idempotency | **Yes** | `IdempotencyFilter` caches the 2xx; adding `qa_confirmed` changes the body ⇒ changes the SHA-256 key, so no stale-key collision. A retry after a partial failure hits the `externalid` duplicate guard (`:139-143`) → `ENTITY_ALREADY_EXITS`, which OMS treats as a hard failure (`QaReturnService.php:649-658`) — correct, but see §9-R1. |
| 7 | Tenant context | **No** | Runs on the request thread inside `TenantFilter` scope; no `@Async`/`CompletableFuture` |
| 8 | Distributed lock correctness | **No** | No new pessimistic/optimistic lock. `receiveGoods` keeps its existing locking |
| 9 | Cache invalidation | **No** — RESOLVED | `grep -rln "@Cacheable" src/main/java` returns exactly six files (`ApiTimestampFormatResolver`, `OutboxDispatchService`, `ClientService`, `ItemdataService`, `LocationService`, `SyspropService`); `grep -rn "Cacheable\|CacheEvict" \| grep -iE "advice\|printer"` returns **zero hits**. `Advice`, `Adviceposition` and `Printer` are **not** cached, so the bulk FINISHED flips need no `@CacheEvict`. Two caches are read indirectly and both are benign read-only lookups: `ItemdataService` (`@Cacheable` `:47`, `:52`) for the boxtype chain and `SyspropService` (`:95`, `:288`) for `DEFAULT_BOX_TYPE`. |
| 10 | External notifications | **Yes** | Three, not one: (a) `messageService.createMessage(ADVICE_IMPORT)` (`:279`); (b) the UL label print inside `receiveGoods` — intentionally synchronous, it *is* the deliverable; (c) **`messageService.sendStockChangeMessage` at `ReceivingService.java:534` → `stockChangeNotificationService.sendAfterCommit` (`MessageService.java:109-111`), emitting a `CODE_RECEIVING_RETURN` `STOCK_UPDATE` to OMS after each position's own commit.** (c) is why a partial failure is worse than it looks — see R1 — and it moves this notification back to advice-create time for flagged advices, which is the specific item SBDEV-2236 got signed off (§10-Q1c). |

### v2-only constraint checklist

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | OSIV disabled | **Yes** | Controller mini-sessions detach entities. The plan carries IDs and primitives **except** the shared `Printer`, which is passed as a **detached instance** into `receiveGoods`. That is safe here and verified: `receiveGoods` touches it only via `getAddress()` and `getName()` (`:315`, `:316`, `:319`, label block ~`:542`, `:547`) — no lazy navigation, so no `LazyInitializationException`. If a future change navigates an association off `Printer`, switch to passing `printerId` and re-reading |
| 2 | `tenantTransactionManager` | **Yes** | `resolveRefs` is `@Transactional(value = "tenantTransactionManager", readOnly = true)`; `validate` and `execute` are deliberately unannotated (B2a, B2b). Must be proxy-invoked or the annotation is skipped. A bare `@Transactional` would silently target the `@Primary` landlord TM |
| 3 | `readOnly = true` | **Yes** | `resolveRefs` is read-only; `execute` performs writes via `receiveGoods` |
| 4 | Caffeine cache invalidation | **Verify** | See scalability row 9 — blocking before merge |
| 5 | Jakarta namespace | **Yes** | No new persistence imports; nothing copied from v1's `javax.*`. v1's `SIMPLE_DATE_FORMAT` date parsing is **not** ported (v2 uses `LocalDate.parse` at `:164`) |
| 6 | H2-compatible test SQL | **N/A** | New tests are Mockito unit tests; no native SQL added |
| 7 | `BaseControllerTest` for controller changes | **Yes** | `AdviceRestControllerUnitTest` is the existing harness for this controller; extend it and follow its `@Nested` structure |
| 8 | Micrometer metrics | **Yes** | Add counters: `wms2.returns.autoreceive.success`, `.rejected_no_printer`, `.rejected_no_boxtype`, `.partial_failure`, and a timer around `execute`. Reuse `MeterRegistry`; do not introduce another metrics stack |

---

## 8. Testing Plan

### Unit — `ReturnAdviceAutoReceiveServiceUnitTest` (new)

> **This is where the `receiveGoods` and printer assertions belong.** `AdviceRestControllerUnitTest`
> keeps `receivingService` (`:61`) and `printerRepository` (`:67`) as **unwired** `@Mock`s — the comment
> at `:58-59` says they exist only so the post-SBDEV-2236 `verify(..., never())` calls compile. The
> controller will depend on `ReturnAdviceAutoReceiveService`, which the controller test mocks, so any
> `receiveGoods`/printer argument assertion made in the controller test is swallowed by that mock and
> proves nothing. Assert those here; assert only the *gate* in the controller test.

- `validateResolvesRequestedPrinterWhenValidReturnPrinter`
- `validateThrowsWhenRequestedPrinterIdDoesNotExist`
- `validateThrowsWhenRequestedPrinterIsNotTypeReturn`
- `validateFallsBackToProcessDefaultReturnPrinterWhenNoPrinterIdGiven`
- `validateThrowsWhenNoPrinterIdAndNoProcessDefaultReturnPrinter`
- `validateResolvesBoxtypeByPositionBoxIdSameLookupAsSaveLoop`
- `validateThrowsWhenBoxIdIsEmpty` (stricter than the loop, which NPEs at `:261` — see §10-Q10)
- `validateThrowsWhenCupsUnavailable` (B2a)
- `validateReceivesGoodsForNoPositionBeforeThrowing` (nothing side-effecting in validate)
- `validateThrowsWhenBoxIdUnknown`
- `executeReceivesEveryPositionThenMarksAdviceFinished`
- `executeThrowsPartialFailureAndDoesNotMarkFinishedWhenSecondPositionFails`
- `executeErrorIdentifiesFailingSkuAndReceivedCount`

### Unit — `AdviceRestControllerUnitTest` (modify)

| AC | Test | Assertion |
|---|---|---|
| AC1 | `shouldAutoReceiveReturnAdviceWhenQaConfirmed` | `receiveGoods` called once per position with `(posId, null, false, notifiedamount, notifiedamount, 1, boxtypeId, printer)` |
| AC2 | `shouldMarkReturnAdviceFinishedWhenQaConfirmed` | both `updateAdvicepositionToStateByAdviceId(FINISHED, id)` and `updateAdviceToStateById(FINISHED, id)` called |
| AC3 | **`shouldCreateReturnAdviceWithoutAutoReceive`** (retarget; `@DisplayName` `:523`, method `:524`) | no `qa_confirmed` ⇒ `receiveGoods` **never** called, states **never** FINISHED — **SBDEV-2236's regression guard; must keep passing.** ⚠ **Highest false-green risk in the plan:** all three assertions are `never()`, so if the retargeted setup stops reaching the RETURN branch at all, the guard passes vacuously and silently stops guarding. **Mandatory additions:** keep the existing HTTP-204 assertion (`:556`, proves `create()` completed) **and** add a positive `ArgumentCaptor` on the saved `Advice`/`Adviceposition` asserting `state == AdviceState.OPEN` — which is what 2236's own checklist `:309` specified as `shouldCreateReturnAdviceInOpenState`. |
| AC4 | `shouldNotAutoReceiveWhenQaConfirmedIsFalse` | explicit `false` behaves as absent |
| AC5 | `shouldNotAutoReceiveRegularAdviceEvenWhenQaConfirmed` | REGULAR unaffected by the flag |
| AC6 | `shouldUseExplicitPrinterIdWhenQaConfirmed` (rewrite `:566`) | supplied RETURN printer is used |
| AC7 | `shouldReturn400WhenPrinterIdInvalidAndQaConfirmed` | 400; **assert via the mocked service**, not the repos: stub `returnAdviceAutoReceiveService.validate(...)` to throw, then assert HTTP 400 and `verify(adviceRepository, never()).save(any())`. ⚠ `verify(printerRepository).findById(42L)` is **impossible here** — the controller never touches `printerRepository` (it is an unwired `@Mock`, `:67`). The real printer-branch assertion belongs in `ReturnAdviceAutoReceiveServiceUnitTest` |
| AC8 | `shouldReturn400WhenNoReturnPrinterConfiguredAndQaConfirmed` | 400; `receiveGoods` never called; **no `advice` row saved** (`verify(adviceRepository, never()).save(any())`) — this is R9's guard; **plus** assert the failure came from the printer path |
| AC10 | `shouldReturn400WhenCupsUnavailableAndQaConfirmed` | B2a: `isPrintAvailable` false ⇒ 400, `receiveGoods` never called, **no `advice` row saved** |

> ⚠ **Why AC7/AC8/AC10 need the extra "came from the intended path" assertion.** A pure-negative 400
> test passes for *any* 400 cause — a missing client, a malformed date, `enablereceiving=false` — even
> if execution never reaches the printer logic. Compounding it, the test class is
> `@MockitoSettings(strictness = Strictness.LENIENT)` (`AdviceRestControllerUnitTest.java:34`), so
> unused or unmatched stubs raise nothing. Without the positive assertion these three tests are
> decorative.
| AC9 | `shouldAutoReceiveAllPositionsOfMultiPositionReturnAdvice` | mixed multi-position: all received, advice FINISHED once |

### Integration

v2's Testcontainers lane cannot boot (**SBDEV-2217**). Add
`ReturnAdviceAutoReceiveIntegrationTest` `@Disabled` with `TODO(SBDEV-2217)`, asserting end-to-end that
a flagged advice ends FINISHED with `goodsreceipt` rows and an unflagged one stays OPEN with none.
Gate the merge on unit tests + `mvn clean compile` instead.

### Regression

- AC11 `POST /v3/receiving/receive` still receives an unflagged OPEN RETURN advice
  (`ReceivingControllerUnitTest`).
- REGULAR advice creation byte-identical — `verify-SBDEV-2236-…sh` §9-R6 reconciliation.
- `FileImportController` RETURN path untouched and still create-only.
- OMS: `QaReturnServiceValidationTest` asserts the payload carries `qa_confirmed => true`.

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
| Sellable return, single SKU | wineco-dev | Return QA → Return to Inventory → complete | BOL closed; UL created; label prints; on-hand +qty | |
| Multi-position return | wineco-dev | Two sellable SKUs on one return | Both received; one BOL, FINISHED | |
| Unflagged advice (2236 guard) | wineco-dev | `PUT /rest/advice/create` `type=RETURN`, **no** `qa_confirmed` | Advice OPEN; no `goodsreceipt`; receivable at the dock | |
| No RETURN printer | wineco-dev | Set `processdefault=false` on `id=30346045`, send flagged advice | HTTP 400 naming the printer; advice **not** FINISHED; OMS shows an actionable error | |
| Invalid `printer_id` | wineco-dev | Flagged advice with `printer_id` of an INBOUND printer | HTTP 400; nothing received | |
| Partial failure | wineco-dev | Two positions; force position 2 to fail | Advice **OPEN**; position 1 received; error names the failing SKU + `1 of 2`; OMS does **not** silently succeed | |
| Old-WMS / new-OMS guard | wineco-dev | Point OMS at a pre-fix WMS | Confirms §6.1-6: 204 with nothing received ⇒ proves deploy order matters | |
| SQL sanity | wineco-dev | `SELECT state FROM advice WHERE externalid='RETURN<parcel>'` + `goodsreceipt` count | `FINISHED`; `goodsreceipt` rows match position count | |

---

## 9. Risks & Mitigations

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | **Partial receive + OMS rollback divergence.** `QaReturnService.php:330` wraps the whole manage flow in `DB::connection('tenant')->transaction(...)`, so a throw from `sendReturnRestockAdvice` (called `:377`) rolls back `managed=true` and the persisted return items. After a partial failure WMS has *really received* positions 1..N−1 ⇒ OMS forgets the return while WMS holds the stock. **Amplifier:** each committed position has already fired a `CODE_RECEIVING_RETURN` `STOCK_UPDATE` at `ReceivingService.java:534`, so OMS also receives N−1 stock increments for a return it then rolls back. | **High** — silent OMS/WMS inventory divergence | **Partially mitigated; do not treat as closed.** B0/B2a move every *predictable* failure (no printer, wrong-type printer, unresolvable boxtype, CUPS down) ahead of the first receive and ahead of any persistence, which removes the likely triggers. **Two things the earlier draft got wrong and this plan must fix:** (1) the error code does **not** reach OMS today — `getErrorMap()` (`:46-51`) emits only `status` + `description`, so `WebserviceError.code`/`errorCodeName` are never serialized; the §5 `getErrorMap()` change is a **hard prerequisite**, not a nicety. (2) even with the code delivered, OMS cannot "keep the return and flag for review" from inside `DB::transaction(closure)` without a new column/state and hoisting the WMS call out of the closure — that is **not** the "one field" §5 budgets. So the residual risk is genuinely unmitigated for unpredictable mid-loop failures. **Option F (§3.5) removes this class structurally and is the recommended answer.** |
| R2 | Reintroducing phantom inventory if `qa_confirmed` is ever sent without a real inspection | High | The flag is set on exactly one OMS path, reachable only when `$receiveNow && dispositionAdvisesWms()`. Code-review gate: any new sender must be justified in review. Javadoc states the contract. |
| R3 | CUPS unreachable ⇒ every flagged advice 400s and every return blocks | Medium | Deliberate: `receiveGoods:315` already fails this way for dock receiving. Monitor `.rejected_*` counters; unflagged advices still receive at the dock as a manual fallback. |
| R4 | Connection-pool pressure from N CUPS calls in-tx | Medium | Scalability row 2/4; returns are 1-3 positions. Add the `execute` timer before enabling a high-volume tenant; §10-Q6 tracks hoisting the check out of the tx. |
| R5 | Deploying OMS before WMS | Medium | §6.1-6 makes WMS-first mandatory; old WMS silently discards the field (unknown-properties ignored) and looks exactly like today's bug. |
| R6 | `verify-SBDEV-2236-…sh` starts failing | Low | Expected. Its negative assertions encode the pre-2778 contract. Annotate that script with a pointer to this plan; do **not** delete it — retarget it to the unflagged case. |
| R7 | `AdviceRestController` ctor grows to 13 params | Low | Accepted; matches existing style. The `ReturnAdviceAutoReceiveService` extraction keeps only one new dep instead of three. |
| R8 | ~~Caffeine cache serving a stale `Advice`/`Printer`~~ | — | **RETIRED.** Verified: none of `Advice`/`Adviceposition`/`Printer` is `@Cacheable` (zero hits). No `@CacheEvict` obligation. See §7 row 9. |
| R9 | **A validation 400 burns `externalid = RETURN{parcel_id}`**, leaving an orphan OPEN advice that makes every OMS retry fail on the duplicate guard (`:139-142`) ⇒ the return becomes unmanageable without DB intervention. On a tenant with no `processdefault` RETURN printer this would happen to **every** return. | **High** | Fix B0 / Fix C-1: all validation runs **before** `adviceRepository.save(...)` at `:198`, so a rejection persists nothing and the retry is clean. This is the reason the design validates before persisting rather than after — see §3's ordering constraint. Manual test "No RETURN printer" in §8 exercises it, and must additionally assert **no `advice` row was created**. |
| R10 | **`CODE_RECEIVING_RETURN` notification timing moves back to advice-create time** for flagged advices. SBDEV-2236 explicitly obtained David Oppenheim's sign-off for moving it to dock-receive time (2236 checklist `:312`). | Medium | Not a code risk — a **renegotiation**. Raised as §10-Q1c. Do not ship without an answer; it is the concrete, previously-agreed item this plan reverses. |

**Acceptance:** `bash sbdocs/9-System/scripts/verify-SBDEV-2778-return-to-inventory-not-received-bol-not-closed.sh`
must report `Result: N pass, 0 fail`, and that exact line must be pasted into §11.

---

## 10. Open Questions / Resolved Decisions

### Blocking

**Q0 — ASK THIS FIRST. Is Flow 2 (`receiveReturnInWms`) already the sanctioned path? (owner: OMS + David Oppenheim). BLOCKS Q1.**
OMS already has **two** return→WMS flows, and it already distinguishes "advise" from "receive":

| | Flow 1 — `sendReturnRestockAdvice` (`QaReturnService.php:590`) | Flow 2 — `receiveReturnInWms` (`:196-286`) |
|---|---|---|
| Doc comment | "so the returned stock is received back into inventory" | **"Receive a return in WMS (Flow 2: Receive + Print)"** |
| Sends `printer_id` | **No** | **Yes** (`:225-242`, `wms_return_printer_id`) |
| Payload shape | `type` / `client_id` / `day_of_delivery` | `advice_type` / `client_code` / `expected_date` via `buildAdvicePayload` (`WmsApiService.php:2337`) |
| Produced the repro? | **Yes** — `externalid=RETURN529599` | No |

If Flow 2 is the intended path for a QA-confirmed return, then the correct fix is to **route
Return-to-Inventory through the flow that already means "receive now"** — and `qa_confirmed` is the
wrong protocol addition, making Fix A and Fix D void. Flow 2's very existence, and the fact that it
alone carries `printer_id`, is real evidence that someone already designed for this.

**This must be answered before Q1**, because asking whether WMS may trust a `qa_confirmed` flag is
the wrong question if the answer is "use the endpoint that already asserts it." Was Flow 2 abandoned,
unfinished, or is Flow 1 simply wired to the wrong call site?

**Q1 — SBDEV-2236 conflict (owner: David Oppenheim). BLOCKS IMPLEMENTATION.**
SBDEV-2236 (merged 2026-05-15, PR #24, `7f9c250`) deleted RETURN auto-receive on the stated OMS-team
requirement — *yours* — that physical confirmation must precede the WMS stock increment. SBDEV-2778
asks for auto-receive back, arguing Return QA **is** that physical confirmation.
This plan's position: both hold, because WMS now requires an explicit per-advice assertion rather than
inferring from the advice type. **Please confirm (a) Return QA counts as physical confirmation for the
`$receiveNow && dispositionAdvisesWms()` path, and (b) an explicit `qa_confirmed` assertion is an
acceptable basis for WMS to synthesise a goods receipt**, and **(c) that moving the
`CODE_RECEIVING_RETURN` `STOCK_UPDATE` notification back to advice-create time for flagged advices is
acceptable** — you signed off on moving it *to* dock-receive time in SBDEV-2236 (its checklist
`:312`), and this plan reverses that for the flagged path (`ReceivingService.java:534` →
`MessageService.java:109-111`). If any of (a)/(b)/(c) is "no", this plan is void and SBDEV-2778 should
be closed as working-as-intended.

**Honest counter-argument you should weigh (it is stronger than this plan's §3.5 claims).**
`qa_confirmed` is a hard-coded `true` at its single call site, so from WMS's side it is
*informationally identical* to `type=RETURN` from that sender. The trust boundary is not really made
"explicit and auditable" — it is **renamed**, and enforced only by code review (as R2 concedes). A
future caller copies the line and SBDEV-2236's invariant is silently gone. Also note the evidence
asymmetry: SBDEV-2236 was DB-verified over 2,215 rows, whereas SBDEV-2778 has one dev row, and ticket
symptoms 1-5 are literally 2236's *intended* behavior ("staff must reopen the inbound notice and
manually receive" **is** the dock scan 2236 mandated; "risk of receiving twice" was 2236's own
pre-mortem, mitigated with operator training rather than code).

**Q4 — How should a partial receive be reconciled? (owner: OMS). This is a DESIGN question, not a yes/no.**
Prerequisite for R1. Two facts make the earlier framing unanswerable:

1. **No WMS error code has ever reached OMS.** `getErrorMap()` (`:46-51`) emits only `status` and
   `description`; `WebserviceError.code` / `.errorCodeName` are populated in the constructor (`:47-49`)
   but never serialized. OMS can only substring-match the description template
   (`WmsException.php` → `extractValidationMessage` reads `$data['description']`).
   **Proof this is already broken today:** OMS's `stripos($message, 'ENTITY_ALREADY_EXITS')` branch at
   `QaReturnService.php:658` can never match — code 101's text is `"entity %1s already exists for %2s"`
   (`WmsConstants.java:1262`), and the literal `"ENTITY_ALREADY_EXITS"` exists only in
   `getErrorCodeName` (`:1330`), which is not in the body. That branch is **dead code**, and the
   generic path below it produces the rollback instead.
2. **`DB::transaction(closure)` admits only two outcomes.** Not throwing commits `managed=true`
   against a half-received WMS; throwing rolls everything back. "Keep the return and flag for review"
   needs a third branch — a new column/state plus hoisting the WMS call out of the closure.

So please decide between:
**(i)** adopt **Option F** (§3.5) — restrict `qa_confirmed` to single-position advices, making partial
failure structurally impossible and Q4 moot. *Recommended.*
**(ii)** fund the real reconciliation: `getErrorMap()` carries `code`/`errorCodeName` (audit all
`/rest` consumers), **and** OMS gains a needs-review state outside the transaction. This is a
scoped piece of OMS work, not one field.
**(iii)** accept the divergence and add an operational reconciliation report.

### Resolved (2026-07-30, with Nam Park)

| # | Decision | Rationale |
|---|---|---|
| D1 | **Scope: WMS v2 + one OMS field.** Not a broad returns feature. | Keeps the urgent fix reviewable; the wishlist items are separate tickets |
| D2 | **No resolvable printer ⇒ throw**, not v1's silent skip (`v1:307`) | v1's silent skip is exactly what produces an inexplicably-open BOL |
| D3 | **Printer order: `printer_id` → default RETURN → throw**; invalid `printer_id` throws rather than falling back | Honours the OMS printer preference SBDEV-2206 shipped; a named printer is an intent |
| D4 | **No additional sysprop gate** (§3.5 option C rejected) | `qa_confirmed` is already a per-request opt-in that defaults off for every existing caller, so back-compat and reversibility are satisfied at the protocol level. A second default-OFF gate would ship the urgent symptom unfixed. Rollback = OMS stops sending the field; no WMS redeploy |
| D5 | **DB-verify before drafting** | §1 Q1-Q5; `db_verified: true` |
| D6 | **Record the 2236 conflict here rather than silently reverting** | A merged, DB-verified decision by a ticket assignee is not ours to reverse unilaterally |

### Out of scope — recommended follow-up tickets

| # | Item | Why out | Recommended |
|---|---|---|---|
| Q2 | **Expected Date one day off** | Separate defect, different subsystem. Repro row's stored `dayofdelivery=2026-07-30` is **correct**, and both OMS paths already guard the UTC boundary (`QaReturnService.php:630` `todayForFacility()`; `WmsApiService.php:2347-2348`) ⇒ suspect the **UI render**, not the stored value | New ticket, start in `wms2-web-ui` |
| Q3 | **Flow 1 / Flow 2 payload divergence** | `sendReturnRestockAdvice` sends `type`/`client_id`/`day_of_delivery`; `receiveReturnInWms` sends `advice_type`/`client_code`/`expected_date` via `buildAdvicePayload:2337`. Two disagreeing contracts on one endpoint is its own defect | New ticket, `oms-laravel-api` |
| Q5 | **Cleanup of RETURN advices left OPEN 2026-05-15 → this deploy** | Operational data task, not code | Ops ticket; SBDEV-2236 §5.1-5 set the precedent of deferring reconciliation |
| Q6 | **Hoist `isPrintAvailable` out of the tenant transaction** | Pre-existing (`ReceivingService:315`); touches the mobile dock path too, so it needs its own regression scope | Tech-debt ticket |
| Q7 | **Damaged-disposition routing** | OMS sends **only undamaged** qty (`QaReturnService.php:604-615` returns `['status'=>'skipped','reason'=>'no undamaged items']`). Needs a real OMS feature, not a WMS port | New ticket, OMS-first |
| Q8 | **Audit-record linking** (return ↔ BOL ↔ UL ↔ receiving user) | Ticket's Transaction/Audit list; needs a data model discussion | New ticket |
| Q10 | **`optionalBoxtype.get()` NPE ⇒ HTTP 500 when `box_id` is omitted** | `AdviceRestController.java:245-262` — `optionalBoxtype` is assigned only inside the `isNotEmpty(getBoxId())` guard but dereferenced unconditionally at `:261`. Latent only because OMS hard-codes `'box_id' => 1` (`QaReturnService.php:747`). v1 identical at `:258`. Same class as the SBDEV-2116 unguarded-`Optional` family | New ticket, **both v1 and v2**; also covers the dead boxtype fallback chain |
| Q9 | **Missing docs** | `wms2-receiving-putaway-workflow.md` is cited by SBDEV-2236's `related:` but **does not exist**; `wms2-function-to-docs-map.md` has **no entry** for `AdviceRestController` / `receiveGoods` / `ReceivingService` | Doc-debt ticket |

---

## 11. Implementation Status

**Not started** — blocked on **§10-Q0 first** (is OMS Flow 2 already the sanctioned path? if yes, Fix A
and Fix D are the wrong shape and this plan is superseded), then **§10-Q1** (SBDEV-2236 conflict, incl.
Q1c on the `CODE_RECEIVING_RETURN` timing shift). **§10-Q4** must also be decided — the recommendation
is §3.5 option F, which would remove risk R1 structurally and simplify §3 B3.

| Item | Value |
|---|---|
| Verify-script baseline (pre-fix) | _TBD — paste the `Result:` line_ |
| Verify-script final | _TBD — must be `Result: N pass, 0 fail`_ |
| wms2-api commit(s) | _TBD_ |
| wms2-api PR | _TBD_ |
| oms-laravel-api commit(s) | _TBD_ |
| oms-laravel-api PR | _TBD_ |
| `mvn clean compile` | _TBD_ |
| `mvn test` (expect the 2/4442 known baseline) | _TBD_ |
| Tests added | _TBD_ |
| Deliberately-skipped coverage | Testcontainers IT `@Disabled` — TODO(SBDEV-2217) |
| **`wms-tdd-gate`** | **Deliberately DEFERRED (2026-07-30), not forgotten.** The gate writes failing tests from a *reviewed* plan's acceptance criteria, but §10-Q0 can void Fix A and Fix D entirely (if OMS Flow 2 is the sanctioned path there is no `qa_confirmed` field to test), so ~15 test methods would be discarded. **Run `wms-tdd-gate` standalone against this plan once Q0 + Q1 are answered.** If you want partial progress before then, AC3 (the SBDEV-2236 unflagged guard incl. the new `state == OPEN` capture) and AC11 (dock-receive regression) survive any Q0 outcome. |
| Consensus | Planner + Architect passes complete and incorporated (~15 revisions, incl. the validate-before-persist redesign, the `getErrorMap()` prerequisite, the retired boxtype chain, and R9/R10). Critic pass outstanding at time of writing — **re-run the Critic if this plan is picked up after further edits.** |
