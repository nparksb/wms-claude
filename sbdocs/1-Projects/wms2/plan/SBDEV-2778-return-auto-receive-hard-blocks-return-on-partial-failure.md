---
title: "SBDEV-2778 (follow-up) — RETURN auto-receive hard-blocks the whole return on a partial failure"
ticket: "SBDEV-2778"
ticket_url: "https://app.clickup.com/t/868kj2bv4"
type: "bugfix"
severity: "high"
priority: "urgent"
status: "STALE BASE — RE-GROUND BEFORE ANY WORK (flagged 2026-08-20). The rev4 note (2026-08-09) rests on two claims that are now FALSE: that ReceivingService.java is byte-identical to its pre-2731 state, and that SBDEV-2732 step 15's diversion gate is unimplemented. Since then 67b015e, 9ed8822, cb562b3 and b950e17 landed the pick-face placement gate directly into ReceivingService (+68/-8), and ReturnAdviceAutoReceiveService took +104/-11 from 478b652 and b950e17. H1 — the primary hypothesis and the whole \"trigger still present\" argument — is plausibly ALREADY FIXED. The core defect (any recoverable receive failure hard-blocking the whole return) may survive, but every line anchor in section 0 and section 5 is stale and the RCA needs redoing. This is the SBDEV-2781 pattern repeating: git fetch and diff per repo BEFORE enumerating sites."
project: ["wms2-api", "oms-laravel-api"]
version: "v2"
requester: "Brent Campbell"
assignee: "Nam Park / David Oppenheim"
created: "2026-08-05"
updated: "2026-08-05"
revision: 3
db_verified: partial
db_verified_note: >
  PARTIAL. Prod Hydra (the environment the incident was reported on) is NOT reachable from the
  authoring session, so the specific trigger of the 2026-08-05 failure is NOT proven — only the
  three code-level defects are, and those are provable without it.

  WHAT WAS PROVEN, on MCP `wms2-hydra-dev2` = `wh01_hydra_v2`, `WAREHOUSE_NAME = 'NYWH'` (the
  warehouse named in the screenshot): every preflight dependency `ReturnAdviceAutoReceiveService`
  resolves before the first save is present and well-formed — `mywms_user 'anonymous'` (1),
  `location 'InboundWorkstation'` (1), `location 'Spawn'` (1), `unitload_type 'Case'` (1),
  `printer type=RETURN processdefault=true` (1 — `CapCity-Label-01`), `boxtype externalid='1'` (1),
  `MAXIMUM_RECEIVING_DURING_INBOUND = 1000` (numeric), `PRINTING_ZPL_CASE_LABEL` present (1012
  chars). `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` is ABSENT on this copy, which under the shipped
  default-ON read means auto-receive is LIVE. `mywms_user 'oms_integration'` is absent (expected —
  V2.2.09 unapplied; the code degrades to the ambient principal by design). All 2720/2720 itemdata
  rows point their `putawaylocation_id` at `location_type 50057 'cases and pallets'`; ZERO point at
  a flowbin.

  WHY H1 IS STRUCTURALLY UNREPRODUCIBLE HERE: `wh01_hydra_v2` has no `flyway_schema_history`, i.e.
  it is a psql-provisioned legacy copy permanently skipped by `StartupFlywayMigrator`, and it is a
  v1→v2 MIGRATED database whose `location_type` ids are the migrated set `1, 50051-50057`.
  SBDEV-2731 — the leading hypothesis — proves its defect on canonical `type_id = 2` (`flowbin`) at
  `putawaylocation_id = 52075`, ids that only exist on a fresh-seeded UAT/prod DB. The flowbin
  destination that H1 requires therefore cannot exist on this copy. `wms2-hydra-v2t` returned zero
  itemdata rows (empty template). Prod Hydra is additionally Flyway-stalled at V2.2.06
  (`42501 must be owner of function stock_history`).

  THE IMPLEMENTER MUST RUN THESE FIRST, AGAINST PROD HYDRA, BEFORE FINALISING THE RCA — see §2
  "Unknown trigger" for the full text: probe **P1** (does `Chenin Blanc 25`'s `putawaylocation_id`
  resolve to a flowbin? — confirms or kills H1), probe **P2** (the state of advice `IBOL000223` and
  whether any `goodsreceipt` rows exist behind it — gates the §7.1 step 0 reconciliation branch),
  and the server-log grep for `RETURN auto-receive PARTIAL FAILURE` and `receiveGoods failed:`
  around 2026-08-05 10:27 UTC, which carries the stack naming the actual throw site.
related:
  - sbdocs/4-Archieves/wms2/plan/SBDEV-2778-return-to-inventory-not-received-bol-not-closed.md
  - sbdocs/4-Archieves/wms2/plan/SBDEV-2236-return-advice-auto-receive-fix.md
  - sbdocs/1-Projects/wms2/plan/SBDEV-2731-alternate-putaway-location-not-honored-receiving.md
  - sbdocs/1-Projects/wms2/plan/SBDEV-2732-configurable-default-putaway-location-hierarchy.md
  - sbdocs/3-Resources/workflows/wms2-receiving-putaway-workflow.md
  - sbdocs/3-Resources/architecture/wms2-state-machine-catalog.md
  - sbdocs/3-Resources/architecture/wms2-oms-integration-map.md
tags:
  - plan
  - wms2
  - returns
  - receiving
  - oms-integration
  - regression
---

# SBDEV-2778 (follow-up) — RETURN auto-receive hard-blocks the whole return on a partial failure

**Ticket:** [SBDEV-2778](https://app.clickup.com/t/868kj2bv4) — reopened 2026-08-05 by Brent Campbell
**Project:** `wms2-api` + `oms-laravel-api` (two repos) | **Version:** v2 | **Type:** bugfix
**Severity:** high | **Priority:** urgent
**Status:** draft rev2 — architect review applied; pending consensus review
**Date:** 2026-08-05

> ## 🔴 REVISION 2 — architect review applied 2026-08-05
>
> An independent architect lane reviewed rev1. **Five findings were independently re-verified against
> source by the author and all five are CONFIRMED.** The plan changed materially:
>
> | Finding | Verified at | Effect on the plan |
> |---|---|---|
> | `ReceivingService` **never** writes `AdviceState.FINISHED` — its only `setState` calls are `:207`, `:240`, `:292`, all **OPEN**. Every FINISHED write is `ReturnAdviceAutoReceiveService.markFinished:593-594` or `AdviceService` | grep, whole `src/main/java` | rev1's "DB backstop" for the resume path **does not exist**. A position stays OPEN after a successful receive, so `ReceivingService:347-349` can never fire because of a prior receive |
> | `ReceivingService:372` is `if (!advice.getAllowoverdelivery())` and `AdviceRestController:271` sets it `true` unconditionally | source | the **last** structural double-receive stop is disabled on this path |
> | `RestIdempotencyService` persists **only 2xx**; non-2xx deletes the claim row (`:182-195`) | source | a 200 warning would be **cached and replayed**, so a resubmit never re-executes |
> | `BusinessException(String)` sets `key = "placeholder"` (`:42-47`); `UnitloadBusinessService:191` and `ReceivingService:315` both use it. There is **no key accessor at all** | source | rev1's key-switching classifier would emit `UNKNOWN` for every case it was written for |
> | `getErrorMap():46-51` emits only `status` + `description`; the token `ENTITY_ALREADY_EXITS` lives only in `getErrorCodeName` (`:1355`), which is never serialised | source | OMS's `stripos($message, 'ENTITY_ALREADY_EXITS')` at `QaReturnService:659` **never matches** — that branch is dead code |
>
> **What changed:** the resume fix is **CUT** (→ §5.6, deferred to its own ticket); the reason-code
> classifier is **re-grounded** on a post-failure state probe instead of the exception key; the OMS
> reconcile-message fix is **dropped** (dead code); §2 Bug B, §4 and §5.2 are corrected.
>
> **Remaining fixes: F1, F2, F3, F4.** (rev1's F5 is now F4; rev1's F4 and F6 are gone.)

> ## 🔴 REVISION 3 — critic review applied 2026-08-05
>
> Six blocking items. **B1, B2, B5 and N1 were independently re-verified against source/schema by the
> author before acting; all confirmed.** One item is **disputed with evidence** — see B6.
>
> | # | Item | Resolution |
> |---|---|---|
> | B1 | verify `F2e`/`F2f` were file-wide; `HttpStatus.NO_CONTENT.value()` occurs **3×** (`:427` in scope, `:546`/`:704` out of scope), so `F2f` could only go green by damaging two unrelated endpoints | Both windowed on the `ADVICE_IMPORT,\s*\n\s*"N/A",` anchor |
> | B2 | §7.1 step 0a's 5-column INSERT raises **`23502`** — `version`, `hidden`, `workstation`, `client_id` are NOT NULL with no defaults (`V2.2.00:1369-1383`) | Replaced with V2.2.09's exact column list; added a look-first SELECT and an UPDATE branch (a second row makes the unscoped `findSysvalueBySyskey` ambiguous); `groupname 'Operation Options'`; target DB named |
> | B3 | plan rendered `description` in the controller, verify `F3i` required it in the service, and the record had no field for it | Rendered in the **service** (`AutoReceiveOutcome.partial(...)`); record gains `String description`; controller must not name the constant |
> | B4 | seven stale cross-references from the F-renumber | All fixed; the "seven scope guards" claim now enumerates `S4b` and `S6` |
> | B5 | `destinationPermitsCaseUnitLoad(dest)` was called but never defined | Specified from `UnitloadBusinessService:179-192` — `LocationConstraintRepository.findByStoragelocationtypeId`, matched on `getUnitloadtypeId()`, and **empty/null list = PERMITTED**. New **T6b** is the inversion guard |
> | B6 | §4's banner contradicted its diagram | Reworded — **but not as proposed; see below** |
>
> **B6 — disputed, and corrected differently.** The review proposed that `isFailureResponse` "is
> reached only on the array `createReturnAdvice` synthesises at `:2155`". Re-verified against
> `WmsApiService.php:2134-2163`: the `catch (\Throwable)` block **returns directly** at `:2162` and
> never falls through to the `isFailureResponse` call at `:2141`, so the synthesised array is never
> passed to it. `QaReturnService:646` re-tests `'failure'` with its own string comparison instead. The
> accurate statement — now in §4 — is that `isFailureResponse` is evaluated **only on the 2xx path**,
> which is precisely the path F2 introduces. rev2's wording was imprecise; the proposed replacement
> was wrong in the other direction.
>
> Non-blocking items N1-N9 applied, including: `itemdataService.findById` does not exist (the probe
> now goes through `ItemdataRepository` so a missing row yields `PUTAWAY_LOCATION_MISSING` rather than
> being swallowed as `UNKNOWN`); §0 row 14 downgraded to "partially visited"; `file_contains_exactly_n`
> switched from `grep -cE` (counts **lines**) to `grep -oE | wc -l`.

> ## ⚠ READ FIRST — this plan must NOT undo the plan that caused the regression
>
> The regression comes from
> [SBDEV-2778 (original)](../../../4-Archieves/wms2/plan/SBDEV-2778-return-to-inventory-not-received-bol-not-closed.md),
> merged as PR [wms2-api#123](https://github.com/SiteBossInc/wms2-api/pull/123). That plan made three
> deliberate choices that this plan **preserves intact**:
>
> 1. **Phantom-FINISHED prevention** (its §2 Bug 4). `markFinished` runs only after **every** position
>    succeeded. A soft-fail must leave the advice `OPEN`, never `FINISHED`.
> 2. **The `bind()` count + externalid-order guard.** The FINISHED flip is bulk `WHERE adviceId = ?`.
> 3. **F4 security sanitisation.** `/rest/advice/create` is `permitAll()` with the tenant chosen from
>    an unauthenticated header. D3's reason codes are an **allow-listed enum**, not a relaxation.
>
> This plan changes **what happens on failure**, not what happens on success.

---

## 0. Affected sites (enumeration before drafting)

Line numbers confirmed against the working tree 2026-08-05 (re-confirmed at rev2).

| # | File:line | Construct | Same root cause? | In scope? |
|---|---|---|---|---|
| 1 | `wms2-api ReturnAdviceAutoReceiveService.java:565-574` | catch → increments counter, logs, **throws** `RETURN_AUTO_RECEIVE_PARTIAL`; the cause never crosses the boundary | yes (A + C) | **YES** — F1, F3 |
| 2 | `wms2-api ReturnAdviceAutoReceiveService.java:579` `self.markFinished(...)` | reached only after every position succeeded | yes (A) | **YES** — F1 **must keep it strictly conditional** |
| 3 | `wms2-api AdviceRestController.java:411-415` | `execute(bind(...))` after the position saves have committed; the throw escapes `create()` | yes (A) | **YES** — F1, F2 |
| 4 | `wms2-api AdviceRestController.java:419-430` | ADVICE_IMPORT audit row — hard-codes `MessageStatus.RECEIVED` + `HttpStatus.NO_CONTENT` | yes (C) | **YES** — F2 must not log a warned request as a clean 204 |
| 5 | `wms2-api WmsConstants.java:1313-1315` | `RETURN_AUTO_RECEIVE_PARTIAL` template — `(advice, sku, received, total)`, **no reason slot** | yes (C) | **YES** — F3 |
| 6 | `wms2-api WmsConstants.java:1319-1321` | `RETURN_AUTO_RECEIVE_ABORTED` — already carries a `%2s` reason slot | reference | **no** — the pattern F3 copies |
| 7 | `oms-laravel-api QaReturnService.php:674` | `throw new \RuntimeException('WMS failed to receive the returned inventory: ' . $message)` — aborts the OMS return transaction | yes (A) | **YES** — F4 |
| 8 | `wms2-api AdviceRestController.java:223-227` | duplicate-`reference_id` guard → `ENTITY_ALREADY_EXITS` | yes (B) | **NO — cut at rev2.** With F1+F2 nothing resubmits. Resume deferred → §5.6 |
| 9 | `oms-laravel-api QaReturnService.php:659-672` | `stripos($message, 'ENTITY_ALREADY_EXITS')` reconcile branch | Bug B | **NO — DEAD CODE.** The token is never serialised (§2 Bug B). Recorded as a finding, not fixed here |
| 10 | `oms-laravel-api WmsApiService.php:898-901` `isFailureResponse` | `$response['status'] === 'failure'` | yes (A) | **PARTIAL** — unchanged. Evaluated **only on the 2xx path** (`:2141`); today's failure path returns from `catch` at `:2162` without reaching it (§4). So it sits on exactly the path F2 introduces — pinned by `F4e`/T26, but steps 2+4 of `processWmsResponse` are the real mechanism (§5.2) |
| 11 | `oms-laravel-api WmsApiService.php:453-501` `processWmsResponse` | 204 short-circuit at `:460`; `!$response->successful()` throw at `:455`; `status ?? 'success'` at `:497` | yes (A) | **YES (analysis, no edit)** — this is what actually makes F2 safe; primary test target |
| 12 | `oms-laravel-api QaReturnService.php:196` `receiveReturnInWms` | OMS Flow 2 — also PUTs to `/rest/advice/create` | shares the endpoint | **NO** — it inherits F1/F2 with no change. Its own error handling is a separate transaction and is out of scope; noted so a reviewer does not think it was missed |
| 13 | `wms2-api ReceivingService.java:492` `transferUnitLoadToLocation(...)` | whole-UL transfer against a flowbin pick face | H1 trigger | **NO — owned by [SBDEV-2731](SBDEV-2731-alternate-putaway-location-not-honored-receiving.md) / [SBDEV-2732](SBDEV-2732-configurable-default-putaway-location-hierarchy.md)** — §5.5 |
| 14 | `wms2-api ReceivingService.java:359, 384, 399, 429, 452, 455` | lookups not covered by the preflight | H3 | **PARTIALLY VISITED** — no edit. F3's probe covers `:429` + `:384` + `:452` (`CONFIG_MISSING`) and `:455` (`PUTAWAY_LOCATION_MISSING`). It does **NOT** cover `:359` `userRepository.findByName` or `:399` `unitload_type` by id — those degrade to `UNKNOWN` + a correlation id. Stated rather than overclaimed |
| 15 | `wms2-api ReceivingService.java:372-379` | over-delivery guard, `if (!advice.getAllowoverdelivery())` | **no** — unreachable: `AdviceRestController:271` sets it `true` unconditionally | **NO** — but see the ⚠ below: this is why §5.6 exists |
| 16 | `wms2-api SharedService.java:76-77` `requireConfig` | H3 | **PARTIAL** — no edit; reason code only |

> ### ⚠ Row 15 is not a neutral exclusion
>
> `allowoverdelivery = true` disables the **only** DB-level guard that would stop the same advice
> position being received twice, and (per the rev2 finding above) a received position is left `OPEN`,
> so the `:347-349` state guard cannot substitute for it. Together those two facts are why the resume
> fix is deferred rather than shipped — see §5.6. Do not read row 15 as "harmless, unreachable".

**Coverage check.** In-scope rows 1-5, 7, 11 each map to a §5 fix or analysis, a §7.2 step, and an
assertion in
`sbdocs/9-System/scripts/verify-SBDEV-2778-return-auto-receive-hard-blocks-return-on-partial-failure.sh`
(see §9). Rows 8, 9, 12, 13, 15 are excluded with rationale; rows 6, 14, 16 are reference or
partially-probe-visited without edit.

**Prior plans on this call chain:**

| Plan | Relationship |
|---|---|
| `4-Archieves/…/SBDEV-2778-return-to-inventory-not-received-bol-not-closed.md` | **The regression source.** Amended, not reverted. Forward-pointer banner: §7 step 11 |
| `4-Archieves/…/SBDEV-2236-return-advice-auto-receive-fix.md` | Superseded by the original 2778. Untouched |
| `1-Projects/…/SBDEV-2731-…` / `SBDEV-2732-…` | **Active, unimplemented.** Own `ReceivingService:492` — §5.5 |
| `1-Projects/…/SBDEV-2729-…` | Merged (`72a58d6d`, ancestor of `v0.0.13`) — RULED OUT as this trigger |

---

## 1. Problem Statement

An operator in the OMS **Returns QA** screen on **Prod Hydra**, warehouse **NYWH**, client
**Zerolink**, brand Cape Venture, processed parcel `CA1783965882593` (order `96834195268:3890`),
item **`Chenin Blanc 25`**, **QTY RETURNED 12**, Return Inventory Process = `Restock Inventory`.
The screen showed a red banner and the return did not complete.

**Banner text, verbatim** (ClickUp attachment `Screenshot 2026-08-05 at 10.27.15.png`):

> WMS failed to receive the returned inventory: WMS validation error: return advice 'IBOL000223'
> partially received: failed on sku 'Chenin Blanc 25' after 0 of 1 positions

**Brent's reopen comment, verbatim:**

> Kicking back to open - Still unable to process a return in the WMS. … I did not previously receive
> this error, so this is likely a regression. Note: this was on Prod Hydra.

Three things are wrong, and only one is the unknown prod trigger:

1. **The return is blocked.** A *recoverable* WMS-side receive failure prevents OMS from recording the
   return at all. The parcel is on the dock and the system will not accept it.
2. **It stays blocked on retry.** `received = 0 of 1` means nothing was received — but the advice and
   its position **are** committed. Every retry of the same parcel now fails on the duplicate guard and
   surfaces the same style of red banner. That is *"Still unable to process a return."*
3. **Nobody can tell why.** The artifact names the SKU and the position count and nothing else. The
   real exception exists only in the WMS server log.

### Reproduction

1. Prod Hydra / NYWH; a SKU whose auto-receive fails inside `receiveGoods` (trigger = §2's open
   question; H1 is a flowbin `putawaylocation_id`).
2. OMS Returns QA → **Restock Inventory** → Receive now.
3. Banner as above; the return is not created in OMS; advice `IBOL000223` **is** created in WMS and
   sits `OPEN` in Open Inbound Notices.
4. Retry the same parcel → duplicate guard → red banner again (see §2 Bug B for the exact text).

### What is NOT in dispute

Auto-receiving a `type=RETURN` advice at create time is the required behavior and stays. This ticket
is about the failure path only.

---

## 2. Root Cause Analysis

Three defects, each provable from code alone and independent of the unknown prod trigger. **A** turns
a WMS hiccup into a blocked return, **B** keeps it blocked on retry, **C** makes it undiagnosable.

### Bug A — a recoverable receive failure hard-blocks the whole return (PRIMARY)

`create()` is explicitly **not** `@Transactional` (comment at `AdviceRestController:285-290`).

| Step | Line | Effect |
|---|---|---|
| 1 | `:303` | `returnAdviceAutoReceiveService.validate(adviceDto)` — preflight, **before** any write. Correct, and it stays |
| 2 | `:307` | `adviceRepository.save(adviceEntity)` — **commits**; burns `externalid = 'RETURN{parcel_id}'` |
| 3 | `:408` | `savedPositions.add(advicepositionRepository.save(position))` — **commits** |
| 4 | `:413` | `execute(bind(...))` — **throws** |

The throw originates at `ReturnAdviceAutoReceiveService.java:565-574`:

```java
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
```

It escapes to the controller's handler at `:435-448` → `ResponseEntity.badRequest().body(e.getErrorMap())`.

**Why this is wrong.** The advice and positions are committed and `OPEN`; `markFinished` (`:579`)
correctly never runs. WMS's own state is *fine and recoverable* — the BOL is visible in Open Inbound
Notices and the dock path can still receive it. The only thing the 400 accomplishes is destroying the
OMS side. `QaReturnService.php:674` throws inside the transaction opened at `:330`
(`updateReturnManagement`), so **OMS rolls the entire return back and keeps no record**, while WMS
keeps a committed advice.

The failure mode inverts the intent: an *open, recoverable* WMS advice is presented to the operator as
a *hard rejection of the physical return*.

### Bug B — the retry fails too, via the generic error (route corrected at rev2)

**File:** `AdviceRestController.java:223-227`

```java
                Optional<Advice> adviceOpt = adviceRepository.findByExternalid(adviceDto.getReferenceId());

                if (adviceOpt.isPresent()) {
                    throw new WebserviceBusinessExceptionClientSide(WmsConstants.ENTITY_ALREADY_EXITS, null, "advice", adviceDto.getReferenceId());
                }
```

This guard is correct and load-bearing (backed by the UNIQUE index `uk_4d13b6sg589c6y88tkm98xl89`).
The problem is that after Bug A there is nothing else the retry can be.

> ### ⚠ CORRECTED AT REV2 — the retry does **not** reach OMS's reconcile branch
>
> rev1 claimed the retry lands on `QaReturnService.php:659-672` ("contact support to reconcile").
> **That branch is dead code.** Verified:
>
> - `WebserviceBusinessExceptionClientSide.getErrorMap():46-51` puts exactly two keys in the body:
>   `status` and `description`. `code` and `errorCodeName` are set on the error object in the
>   constructor and **never serialised**.
> - `description` comes from `getErrorCodeText(ENTITY_ALREADY_EXITS, …)` = `WmsConstants:1278`
>   `"entity %1s already exists for %2s"` → renders `entity advice already exists for RETURN…`.
> - The literal token `ENTITY_ALREADY_EXITS` exists only in `getErrorCodeName` (`WmsConstants:1355`),
>   which nothing on this path calls.
>
> So `stripos($message, 'ENTITY_ALREADY_EXITS')` at `:659` **never matches**, and the retry falls
> through to the generic throw at `:674`:
> `'WMS failed to receive the returned inventory: ' . $message`.
>
> **Bug B's effect is unchanged — the retry is still blocked and the return is still lost.** Only the
> route was wrong. This matters for two reasons: the operator sees the *generic* banner rather than
> the reconcile guidance (so "contact support" is never actually suggested), and any fix aimed at
> `:659-672` would edit unreachable code. rev1's F6 did exactly that and is dropped.
>
> **Recorded as a finding, not fixed here:** OMS carries a branch that can never fire, and WMS has
> never delivered an error *code* to OMS. Both belong to the `getErrorMap()` ticket (§10-Q4).

### Bug C — the underlying cause is discarded from every artifact anyone can see

**File:** `WmsConstants.java:1313-1315`

```java
            case RETURN_AUTO_RECEIVE_PARTIAL:
                description = "return advice '%1s' partially received: failed on sku '%2s' after %3s of %4s positions";
                break;
```

Four parameters, no reason. The real exception **is** captured as the `cause` and logged twice —
`ReturnAdviceAutoReceiveService:567` and `ReceivingService:503` (the latter with `adviceId /
adviceNumber / advicePositionId / sku / itemdataId / clientId / amountBottles / user` plus the stack)
— but `getErrorMap()` emits only `status` + `description`, so **the cause reaches the WMS server log
and nowhere else.**

Contrast the sibling added by the same PR, `WmsConstants.java:1319-1321`:

```java
            case RETURN_AUTO_RECEIVE_ABORTED:
                description = "return advice '%1s' aborted before receiving anything: %2s";
                break;
```

`ABORTED` carries a reason slot. `PARTIAL` — the one that actually fires — does not. That asymmetry is
why the prod failure cannot be root-caused from the reported artifact, and it misses the ticket's own
Error-Handling AC.

### ⚠ The residual after this fix — say it out loud

**This plan makes the failure survivable, not invisible, and it does not make the receive succeed.**
After F1-F4, a `receiveGoods` failure leaves the advice `OPEN` with zero `goodsreceipt` rows, exactly
as the *original* SBDEV-2778 symptom describes. That symptom becomes the **steady-state failure
outcome** of this system, deliberately:

- The return **is** recorded in OMS and the operator is unblocked. That is the whole point.
- The stock is **not** in WMS until someone receives the BOL at the dock.
- The only durable signal that this happened is the counter
  `wms2.returns.autoreceive.partial_failure` plus one WMS `ERROR` line and one OMS `warning` line.

Consequences that must be accepted explicitly by whoever approves this plan:

1. **The Grafana panel is a release gate, not a checklist item** (§7.1 prereq 9, §7.2 step 12). Without
   it, a systemic failure — every return on a tenant failing the same way — is invisible until someone
   notices the dock backlog.
2. **During the old-OMS deploy window the warning is silent** (§5.2 row 1). The return completes, OMS
   logs `received_in_wms => true`, and no operator-visible artifact exists at all.
3. **The underlying trigger still needs fixing.** This plan stops the bleeding; SBDEV-2731/2732 (if P1
   confirms H1) is what makes the receive actually succeed.

This must appear verbatim in the ClickUp update so Brent is not told the return problem is "fixed"
when what is fixed is that it no longer blocks him.

### Unknown trigger — ranked hypotheses

The auto-receive preflight (`resolveRefs`, via `validate` at `:197`) already pre-validates, **before
the first save**: printer exists / is type `RETURN` / CUPS reachable; `MAXIMUM_RECEIVING_DURING_INBOUND`
numeric; `unitload_type 'Case'`; boxtype by `externalid`; client by `clNr`; itemdata by (client, SKU);
`putawaylocation_id` NON-NULL; amount in `[1, 100000]`; positions ≤ 500. So the failure is at a
`receiveGoods` site the preflight does **not** cover.

**H1 (PRIMARY) — SBDEV-2731 flowbin putaway rejection.** `ReceivingService.java:492` calls
`unitloadBusinessService.transferUnitLoadToLocation(...)`, which throws at
`UnitloadBusinessService.java:235` when the putaway target is a flowbin pick face.

> [!important] **✅ RE-CHECKED AGAINST MERGED CODE 2026-08-09 — H1 SURVIVES, and is now PROVEN rather
> than INFERRED.** Two of this ticket's three named dependencies merged since rev3 was written
> (SBDEV-2731 on 2026-08-07, SBDEV-2821 on 2026-08-09). Verified on `origin/develop` = `fd90487`:
>
> 1. **`ReceivingService.java` is byte-identical to its pre-SBDEV-2731 state** (`git diff 68274b0
>    origin/develop -- ReceivingService.java` is **empty**). Neither 2731 nor 2821 nor 2863 touched
>    receiving. **Every line number this hypothesis and H3 depend on is therefore still exact** —
>    `:454-457`, `:492`, the `try` at `:461-510`, the rethrow at `:503`, and all seven H3 anchors.
> 2. **SBDEV-2731 changed the message, not the rejection.** Its diff to `UnitloadBusinessService`
>    replaces one raw concatenated `throw` with `throw new BusinessException(
>    "unitloadTypeNotPermittedOnLocation", …)`. The guard `if (!foundPermittingConstraint)` is
>    untouched — no `if`/`return`/control-flow change anywhere in the diff. **The rejection fires
>    identically.**
> 3. **SBDEV-2821 does not help either**, by its own design: it adopted route-at-putaway and its
>    acceptance criteria state *"Receiving behaviour is unchanged."* Confirmed by (1).
> 4. **The tier-1 direct-placement path is live and unguarded on `develop` today.** At `:454-457`,
>    when `carrier == null`, `putAwayLocation` is resolved unconditionally from
>    `itemdata.getPutawaylocationId()`; `:492` transfers the unit load there. **No diversion gate
>    exists** — that is SBDEV-2732 step 15, which is unimplemented.
>
> **Net: the trigger H1 names is still present in merged code.** What changed is only the operator-facing
> string it produces. *(Rev3 read `:191` — the pre-2731 line — and argued from "2731 is unimplemented".
> Both are superseded; the conclusion is unchanged and the evidence is now stronger.)*
>
> ⚠ **Consequence beyond this ticket:** with 2821 merged and on `dev`, **receiving `ICE PACK` into the
> `ICE PACK` flowbin still fails** — 2821 made the destination reachable *at putaway*, not *at receipt*.
> The originally reported SBDEV-2731 symptom closes only when SBDEV-2732 step 15 ships.

*For:* **the mechanism is confirmed live in merged code** (box above); same requester; same
tenant and warehouse (2731's `db_verified_note` establishes NYWH == HMG == Hydra); `db_verified: true`
against prod-shaped data; the call site is inside the exact `try` (`:461-510`) whose catch at `:503`
rethrows at `:509` and becomes `RETURN_AUTO_RECEIVE_PARTIAL`. *(All anchors in this paragraph and in
H3 re-verified against `origin/develop` 2026-08-09 — every one exact, because `ReceivingService` is
unchanged. `:503` was cited as "the rethrow"; it is the `catch`, with `throw e;` at `:509`.)*
*Against / unproven:* the **trigger** is still not proven for the 2026-08-05 incident — only the
mechanism is. Not reproducible on any reachable DB. **Probe P1 still settles it, and is now much
narrower:** per 2731's `db_verified_note`, `ICE PACK` (itemdata `52072` → location `52075`) is the
**only** SKU on prod with a non-`PutAwayLane` destination — 0 on UAT and both dev tenants. So H1
requires that the 2026-08-05 return advice contained `ICE PACK`, which is a single-row question.

**H2 — SBDEV-2732 putaway destination hierarchy.** `status: **draft**` *(corrected 2026-08-09 — rev3
said `reviewed`)*, unimplemented; same call site, adjacent cause. **It is also the only ticket that
removes H1's trigger** — see §5.5.

**H3 — a lookup inside `receiveGoods` the preflight does not cover:** `:359`
`userRepository.findByName(...)`, `:384` `Location 'InboundWorkstation'`, `:399` `unitload_type` by id,
`:429` `requireConfig(WAREHOUSE_NAME)`, `:452` `Location 'Spawn'`, `:455`
`locationRepository.findById(putawaylocation_id)` (the preflight proves the id is non-null, **not**
that the row exists), `SharedService:76` `requireConfig(PRINTING_ZPL_CASE_LABEL)`.

#### RULED OUT (with evidence)

| Hypothesis | Ruled out by |
|---|---|
| **Over-delivery** (`ReceivingService:372-379`) | `AdviceRestController:271` sets `setAllowoverdelivery(true)` unconditionally ⇒ the branch is unreachable. (⚠ and that is itself a problem — §0 row 15) |
| **`createCaseLabel` null token (SBDEV-2729)** | Fix `72a58d6d` **is** an ancestor of `v0.0.13` |
| **Missing `oms_integration` user** | `ReturnAdviceAutoReceiveService:522` degrades to the ambient principal by design; `anonymous` exists on the Hydra DB |
| **Preflight config gaps** | All present and well-formed on `wh01_hydra_v2` — frontmatter `db_verified_note` |
| **Kill switch misconfiguration** | The row is absent, which under default-ON means auto-receive is enabled — consistent with the symptom, not a cause |

#### Probes the implementer MUST run before finalising the RCA

```sql
-- P1: does Chenin Blanc 25's putaway target explain H1?
--     (confirm the exact SKU string from the OMS payload first — the banner may have trimmed it)
SELECT i.item_nr, i.putawaylocation_id, l.name AS loc, l.type_id, lt.sltname
FROM itemdata i
JOIN client c ON c.id = i.client_id
LEFT JOIN location l ON l.id = i.putawaylocation_id
LEFT JOIN location_type lt ON lt.id = l.type_id
WHERE i.item_nr = 'Chenin Blanc 25';
```

```sql
-- P2: the poisoned advice from the incident — gates the §7.1 step 0 reconciliation branch
SELECT a.id, a.number, a.externalid, a.state, a.type, a.created,
       (SELECT count(*) FROM goodsreceipt g WHERE g.advice_id = a.id) AS gr_rows
FROM advice a WHERE a.number = 'IBOL000223' OR a.externalid LIKE 'RETURN%';
```

Plus the WMS server-log grep around **2026-08-05 10:27 UTC** for `RETURN auto-receive PARTIAL FAILURE`
and `receiveGoods failed:` — the second carries the stack that decides H1 vs H2 vs H3.

> **The fix does not wait on the answer.** Bugs A, B and C are wrong regardless of which hypothesis is
> right. The probes decide which reason code the diagnostic emits and whether SBDEV-2731 needs
> expediting.

---

## 3. The Regression Chain

| Step | Artifact | Evidence |
|---|---|---|
| 1 | Message template introduced | `WmsConstants.java:1314` `RETURN_AUTO_RECEIVE_PARTIAL` — added by PR #123, zero prior occurrences |
| 2 | Only throw site | `ReturnAdviceAutoReceiveService.java:571` (catch at `:565`) — the class is new in PR #123 |
| 3 | PR merged to `develop` | [wms2-api#123](https://github.com/SiteBossInc/wms2-api/pull/123), merge commit **`8c8debc3`**, 2026-08-04 |
| 4 | Reached the release tag | `git merge-base --is-ancestor 8c8debc3 v0.0.13` → **true** |
| 5 | Deployed to production | **`5a849f21`** / **`555f9427`** — *"Release SiteBoss OWL v2.0.123 to production - wms2-api v0.0.13"* |
| 6 | Failure reported | **2026-08-05** — the **same day** as the production release |
| 7 | No intervening change | No commit touched `ReturnAdviceAutoReceiveService.java` between the merge and the report |

⇒ **Direct regression from PR #123 reaching production.** Brent's *"I did not previously receive this
error"* is correct: before PR #123, WMS created the advice, left it `OPEN`, returned 204, and OMS
completed the return — the *original* SBDEV-2778 symptom, annoying but never blocking. PR #123 traded a
visible-but-recoverable outcome for a hard block. That trade is the bug.

---

## 4. Architecture Overview

> ⚠ **Corrected at rev3 — and this correction differs from the one the review asked for.**
>
> rev2 said "the current path never reaches `isFailureResponse`". That was imprecise. The review
> proposed instead that `isFailureResponse` "is reached only on the array `createReturnAdvice`
> synthesises at `:2155`". **That is also wrong** — re-verified against `WmsApiService.php:2134-2163`:
> the `catch (\Throwable)` block **returns directly** at `:2162`
> (`return ['status' => 'failure', 'message' => $e->getMessage()];`). It does not fall through to the
> `isFailureResponse` call at `:2141`, so the synthesised array is never passed to it.
>
> **The accurate statement, and the one that matters for F2:**
>
> - **Failure path (today).** `makeWmsRequest:373-375` throws `WmsException` on 4xx before returning
>   (and `processWmsResponse:455-457` would throw on non-2xx anyway, before its status key is ever
>   inspected). Control jumps straight to `catch (\Throwable)` at `:2155`, which returns the
>   synthesised failure array at `:2162`. **`isFailureResponse` is never evaluated.** The
>   `'failure'` verdict is then re-tested by `QaReturnService:646`'s own
>   `($result['status'] ?? '') === 'failure'` string check — not by `isFailureResponse`.
> - **2xx path (including F2's new warning).** No throw, so `:2141` **is** evaluated.
>
> So `isFailureResponse` is reached on **exactly** the path F2 introduces. That makes the F4e pin
> meaningful rather than theatrical — but it is still step 5 of 5, and steps 2 and 4 of
> `processWmsResponse` are what actually decide the outcome (§5.2).

```
 OMS (oms-laravel-api)                              WMS (wms2-api)
 ─────────────────────                              ──────────────
 Returns QA screen  → disposition + Receive now
        │
        ▼
 QaReturnService::updateReturnManagement()    :330
   DB::connection('tenant')->transaction( ────────────────────────────┐  ← OMS tx opens here
     ├─ persistReturnItems()                                          │
     └─ if ($receiveNow && dispositionAdvisesWms())            :376   │
            └─ sendReturnRestockAdvice()                       :377   │
                  └─ WmsApiService::createReturnAdvice()      :2116   │
                        makeWmsRequest(PUT, unauthenticated)   :2137  │
                              │  PUT /rest/advice/create              │
                              ▼                                       │
                        AdviceRestController.create()          :139   │
                          ├─ duplicate reference_id guard      :223 ──┼─► ENTITY_ALREADY_EXITS
                          ├─ autoReceive gate                  :298   │      (Bug B — generic route)
                          ├─ validate(dto)  ← preflight, no writes :303
                          ├─ adviceRepository.save()  ✔ COMMITS  :307 │
                          ├─ advicepositionRepository.save() ✔   :408 │
                          └─ execute(bind(...))                 :413  │
                                └─ executeInternal()            :538  │
                                     └─ receivingService.receiveGoods()  :302
                                          ├─ CUPS probe                :315
                                          ├─ lock adviceposition       :344   (leaves it OPEN!)
                                          ├─ over-delivery guard — DISABLED   :372
                                          ├─ transferUnitLoadToLocation :492  ← H1 throws here
                                          └─ catch → LOG.error → rethrow :503
                                  catch → LOG.error → THROW PARTIAL    :571
                          catch → ResponseEntity.badRequest()   :448   │
                              │  HTTP 400 {status: failure, description}
                              ▼
                  makeWmsRequest: 4xx → throw WmsException      :373  │  ← the 400 dies HERE,
                  (processWmsResponse:455 would also throw)            │    not at isFailureResponse
            catch (\Throwable) → ['status'=>'failure', …]      :2155  │
            isFailureResponse(...) → true                       :898  │
            throw \RuntimeException('WMS failed to receive…')    :674 ─┘  ← OMS tx ROLLS BACK
```

**The asymmetry in one line:** WMS commits and OMS rolls back, on the same failure.

### Key files

| File | Role |
|---|---|
| `wms2-api …/controller/rest/AdviceRestController.java` | duplicate guard (`:223`), autoReceive gate (`:298`), commit points (`:307`, `:408`), execute (`:413`), audit row (`:419-430`), error handler (`:435-448`) |
| `wms2-api …/service/ReturnAdviceAutoReceiveService.java` | `isAutoReceiveEnabled` (`:174`), `validate`/`resolveRefs` (`:196`), `bind` (`:431`), `execute`/`executeInternal` (`:491`/`:538`), the failing catch (`:565`), `markFinished` (`:591`) |
| `wms2-api …/service/ReceivingService.java` | `receiveGoods` (`:302`) — **not edited**. Sets only `OPEN` (`:207`, `:240`, `:292`); over-delivery guard disabled (`:372`); rethrow site (`:503`) |
| `wms2-api …/service/WmsConstants.java` | `RETURN_AUTO_RECEIVE_PARTIAL = 600` (`:1257`), templates (`:1313`, `:1319`), names (`:1387`); `getErrorCodeText` swallows `IllegalFormatException` at `:1329-1332` |
| `wms2-api …/exceptions/WebserviceBusinessExceptionClientSide.java` | `getErrorMap()` (`:46-51`) — only `status` + `description`; the reason the cause and the code never cross |
| `wms2-api …/exceptions/BusinessException.java` | `BusinessException(String)` sets `key = "placeholder"` (`:42-47`); **no key accessor exists**; `placeholder=%1s` renders the raw message |
| `wms2-api …/service/RestIdempotencyService.java` | `persistResponse` (`:182-195`) — **2xx only**; non-2xx deletes the claim row |
| `oms-laravel-api …/Qa/QaReturnService.php` | `updateReturnManagement` tx (`:330`), WMS branch (`:376`), `sendReturnRestockAdvice` (`:590`), dead reconcile branch (`:659-672`), generic throw (`:674`) |
| `oms-laravel-api …/WmsApiService.php` | `createReturnAdvice` (`:2116`), `makeWmsRequest` (`:289`, 4xx throw `:373`), `processWmsResponse` (`:453`), `isFailureResponse` (`:898`) |

> ### ⚠ LANDMINE — **204 discards the body**
>
> `processWmsResponse:460-467` short-circuits on HTTP 204 and returns a synthetic success array; the
> body is never parsed. `/rest/advice/create` currently returns
> `ResponseEntity.status(HttpStatus.NO_CONTENT).body(Collections.singletonMap("status", "success"))`,
> so **OMS has never seen a byte of that body.** A warning returned on 204 is invisible. Hence F2's
> 200. See §5.2.

---

## 5. Fix Design

### Design principles

1. **A physical return must never be blocked by a recoverable WMS-side condition.**
2. **Preserve every guarantee PR #123 added.** Additive on the failure path.
3. **Ship only what is structurally sound today.** Anything that needs a guarantee the code does not
   currently provide goes to §5.6, not into this PR.
4. **The endpoint stays sanitised.** Everything new that crosses the boundary is an allow-listed enum
   value or an opaque UUID.

### 5.1 Fixes

---

#### F1 — soft-fail: `execute` reports the outcome instead of throwing (D2, wms2-api)

**File:** `service/ReturnAdviceAutoReceiveService.java:538-583`

**Before** (the catch at `:565-574`) — see §2 Bug A for the verbatim block.

**After:**

```java
            } catch (BusinessException | FacadeException | RuntimeException e) {
                meterRegistry.counter("wms2.returns.autoreceive.partial_failure").increment();
                String correlationId = UUID.randomUUID().toString();
                FailureReason reason = diagnose(line, plan.printer());   // F3 — state probe, not `e`
                // The ONLY place the real cause exists. `e` last so SLF4J logs the stack;
                // correlationId is the join key from the OMS banner to this line.
                LOG.error("RETURN auto-receive PARTIAL FAILURE correlationId={} adviceId={} "
                        + "adviceNumber={} failedSku={} failedPositionExternalId={} received={} "
                        + "of={} reason={}",
                    correlationId, plan.adviceId(), plan.adviceNumber(), line.sku(),
                    line.positionExternalId(), received, plan.lines().size(), reason, e);
                // SOFT FAIL (D2). Deliberately NOT a throw:
                //  - the advice and its positions are committed and OPEN, so WMS state is already
                //    correct and recoverable via the dock path;
                //  - throwing rolls the OMS return transaction back
                //    (QaReturnService::updateReturnManagement:330 / :674).
                // markFinished is NOT reached — the advice stays OPEN. That is the point.
                return AutoReceiveOutcome.partial(plan.adviceNumber(), line.sku(), received,
                    plan.lines().size(), reason, correlationId);
            }
        }

        // Only after EVERY position succeeded — unchanged, and it MUST stay unchanged.
        self.markFinished(plan.adviceId());
        meterRegistry.counter("wms2.returns.autoreceive.success").increment();
        LOG.info("RETURN auto-receive COMPLETE adviceId={} adviceNumber={} positions={}",
            plan.adviceId(), plan.adviceNumber(), plan.lines().size());
        return AutoReceiveOutcome.success();
```

`execute` / `executeAsIntegrationUser` / `executeInternal` change return type `void` →
`AutoReceiveOutcome`. The empty-plan branch at `:546-551` returns
`AutoReceiveOutcome.skipped(SKIPPED_NO_POSITIONS)`, keeping its counter and WARN.

```java
    /** Outcome of one advice's auto-receive. `partial` never means "advice FINISHED". */
    public record AutoReceiveOutcome(Status status, String adviceNumber, String failedSku,
                                     int received, int total, FailureReason reason,
                                     String correlationId, String description) {
        public enum Status { SUCCESS, PARTIAL, SKIPPED }
        public boolean isWarning() { return status != Status.SUCCESS; }
    }
```

`description` is rendered **in the service**, inside `AutoReceiveOutcome.partial(...)`, by the single
`WmsConstants.getErrorCodeText(...)` call described in F3. Deciding this here matters: the controller
must never name `WmsConstants.RETURN_AUTO_RECEIVE_PARTIAL`, so verify `F3i` can scope both its
single-reference count and its six-argument check to this one file.

```java
        public static AutoReceiveOutcome partial(String adviceNumber, String sku, int received,
                                                 int total, FailureReason reason,
                                                 String correlationId) {
            return new AutoReceiveOutcome(Status.PARTIAL, adviceNumber, sku, received, total,
                reason, correlationId,
                // THE ONLY consumer of the RETURN_AUTO_RECEIVE_PARTIAL template — six args, and the
                // arity is load-bearing. See F3's arity trap.
                WmsConstants.getErrorCodeText(WmsConstants.RETURN_AUTO_RECEIVE_PARTIAL,
                    adviceNumber, sku, received, total, reason, correlationId));
        }
```

**Why this and not the alternative.** The alternative — keep throwing, have OMS swallow it — leaves
WMS's contract stating "this request failed" while the caller is told to ignore it, so any second
consumer (the legacy `qa-api` sender still exists) inherits the block, and 400 cannot distinguish "the
return was recorded, receiving is pending" from "the request was malformed".

`bind()` and its guards are untouched. `markFinished` stays
`@Transactional(value = "tenantTransactionManager")` reached via `self`. `execute()` stays
non-transactional (the original §3 B2b reasons are unaffected by a return-type change).

---

#### F2 — `create()` returns 200-with-warning, and the audit row says so (D2, wms2-api)

**Files:** `controller/rest/AdviceRestController.java:411-415`, `:419-430`, `:433`

**Before:**

```java
                if (autoReceive) {
                    returnAdviceAutoReceiveService.execute(returnAdviceAutoReceiveService
                            .bind(validatedAutoReceive, adviceEntity, savedPositions));
                }
                …
                messageService.createMessage(…, WmsConstants.MessageStatus.RECEIVED,
                    Integer.toString(HttpStatus.NO_CONTENT.value()), null);
                …
            return ResponseEntity.status(HttpStatus.NO_CONTENT).body(Collections.singletonMap("status", "success"));
```

**After:**

```java
                if (autoReceive) {
                    ReturnAdviceAutoReceiveService.AutoReceiveOutcome outcome =
                        returnAdviceAutoReceiveService.execute(returnAdviceAutoReceiveService
                                .bind(validatedAutoReceive, adviceEntity, savedPositions));
                    if (outcome.isWarning()) {
                        // At most one RETURN advice per request (the single-advice guard at
                        // :195-203), so one slot is sufficient and cannot be overwritten.
                        autoReceiveWarning = outcome;
                    }
                }
                …
                // The ADVICE_IMPORT audit row is the only durable per-request record. Logging a
                // warned request as a clean RECEIVED/204 would make a partially-failed import
                // indistinguishable from a clean one in service_log — the exact blindness §2 Bug C
                // is about. The `answer` column carries the allow-listed reason + correlation id.
                messageService.createMessage(…, WmsConstants.MessageStatus.RECEIVED,
                    Integer.toString(autoReceiveWarning != null
                        ? HttpStatus.OK.value() : HttpStatus.NO_CONTENT.value()),
                    autoReceiveWarning != null ? warningAudit(autoReceiveWarning) : null);
                …
            if (autoReceiveWarning != null) {
                // 200, NOT 204. processWmsResponse:460-467 short-circuits on 204 and never parses
                // the body, so a warning on 204 is invisible to OMS. Full success stays 204 —
                // unchanged for every existing caller and every REGULAR import.
                return ResponseEntity.ok(warningBody(autoReceiveWarning));
            }
            return ResponseEntity.status(HttpStatus.NO_CONTENT).body(Collections.singletonMap("status", "success"));
```

`MessageStatus` has no `WARNING` constant and this plan does not add one — `RECEIVED` remains correct
(the advice *was* received/accepted); the 200 status code plus the `answer` payload carry the
distinction.

Response body (`warningBody`), deliberately minimal:

```json
{
  "status": "success",
  "warning": {
    "code": "RETURN_AUTO_RECEIVE_PARTIAL",
    "reason": "PUTAWAY_LOCATION_REJECTED",
    "correlation_id": "8f2c1e4a-…",
    "advice": "IBOL000223",
    "sku": "Chenin Blanc 25",
    "received": 0,
    "total": 1,
    "description": "return advice 'IBOL000223' partially received: failed on sku 'Chenin Blanc 25' after 0 of 1 positions (reason: PUTAWAY_LOCATION_REJECTED, ref: 8f2c1e4a-…)"
  }
}
```

`status: "success"` is load-bearing — §5.2. `advice` and `sku` are retained deliberately: both already
cross this boundary in the shipped message, the SKU is caller-supplied, and the ticket's AC requires
identifying the failing SKU. Nothing else is added.

`description` is **not** built here — `warningBody(...)` copies it straight off
`AutoReceiveOutcome.description()`, which the **service** rendered via the single
`WmsConstants.getErrorCodeText(RETURN_AUTO_RECEIVE_PARTIAL, …)` call (F1's `partial(...)` factory).
**The controller must not reference `WmsConstants.RETURN_AUTO_RECEIVE_PARTIAL` at all** — that keeps
the constant, the template and its six-argument arity in one file, which is what lets verify `F3i`
scope both of its checks to `ReturnAdviceAutoReceiveService.java`.

Keeping the template alive matters: F1 stops constructing
`WebserviceBusinessExceptionClientSide(RETURN_AUTO_RECEIVE_PARTIAL, …)`, so without this one call the
template would be dead code and §0 row 5 / §2 Bug C would go unaddressed. Rendering it WMS-side also
keeps the operator-facing sentence continuous with the banner text operators already know. Every field
in it is caller-supplied, an allow-listed enum, or a UUID. OMS prefers `description` when present and
falls back to its own `sprintf` (F4).

> ### ⚠ Consequence of the 200 — idempotency now caches the warning
>
> `RestIdempotencyService.persistResponse:182-195` persists **only 2xx** and deletes the claim row on
> non-2xx. Today's soft-fail is a 400, so a byte-identical retry re-executes. After F2 the warning is a
> **200 and is therefore cached**: a byte-identical resubmit inside the retention window is replayed
> by `IdempotencyFilter` and never reaches the handler.
>
> **With F1+F2 alone this is harmless and arguably correct** — OMS records the return on the first
> call and has no reason to resubmit (`createReturnAdvice` has exactly one caller,
> `QaReturnService:644`, invoked once per operator submit). It is called out because it is the third
> blocker on the deferred resume work (§5.6): a resume path would be unreachable for its own primary
> use case. Do not "fix" the idempotency behavior as part of this ticket.

**Why this and not the alternative.**
- *Warning in a header on the existing 204.* `processWmsResponse` reads only status and body; dropped
  at `:460`. Dead on arrival.
- *Switch every success to 200.* Touches the REGULAR bulk-import path for no gain.
- *A separate status endpoint OMS polls.* A new unauthenticated endpoint plus polling inside an open
  OMS transaction.

---

#### F3 — allow-listed reason code + correlation id, grounded on a state probe (D3, wms2-api)

**Files:** `service/ReturnAdviceAutoReceiveService.java`, `service/WmsConstants.java:1313-1315`

> ### ⚠⚠ REV2 — do NOT classify by the exception. Both obvious routes are traps.
>
> **Route 1 — switch on the message key — is useless.** `BusinessException(String message)`
> (`BusinessException.java:42-47`) sets `key = "placeholder"` and stuffs the whole message into
> `parameter[0]`. `UnitloadBusinessService:191` (the H1 throw) and `ReceivingService:315` (printer)
> both use that single-String constructor, so their key is `"placeholder"`, not anything semantic.
> There is also **no key accessor on `BusinessException` at all** — rev1's classifier could not even
> have compiled without adding one. Adding a public accessor to serve a switch that returns
> `"placeholder"` for every case of interest is not worth doing, so this plan **does not add one**.
>
> **Route 2 — read `getMessage()` — is a security leak.** `placeholder=%1s`, so `getMessage()` for the
> H1 throw renders, verbatim:
> `unitloadtypeId=52 not allowed on location=<REAL LANE NAME> with location type=2`.
> Matching on that string — or letting any substring of it reach the response — puts a real location
> name on an unauthenticated endpoint and reverses PR #123's F4. **An implementer who discovers Route
> 1 is useless will reach for Route 2. That is the predicted failure of this fix; §8 T12/T16 and verify
> `F3f`/`F3g`/`F3g2` exist to catch it.**

**The design: diagnose by re-reading state, not by reading the exception.** After the catch, run a
bounded read-only probe over the same references the receive used, in the order the receive would have
consumed them, and return the first condition that is actually wrong:

```java
    /**
     * Post-failure diagnosis. Derives the reason from OBSERVED STATE, never from the exception —
     * see the two traps in plan §5.1 F3. Read-only, bounded, and wrapped so a diagnostic failure can
     * never turn a soft-fail into a hard one: any throw in here degrades to UNKNOWN.
     *
     * The correlation id in the caller's log line is what carries the real cause to an operator.
     * This method only has to be right often enough to route the ticket.
     */
    FailureReason diagnose(AutoReceiveLine line, Printer printer) {
        try {
            // 1. printer reachability — cheapest signal, and it is the one condition that can have
            //    changed since validate()'s probe (TOCTOU is real here).
            if (!printService.isPrintAvailable(printer.getAddress())) {
                return FailureReason.PRINTER_UNREACHABLE;
            }
            // 2. putaway destination — H1/H2 live here.
            // NOTE: itemdataService has NO findById. The accessors are getById(Long) (:48) and
            // findByClientIdAndItemNr(Long, String) (:53). getById THROWS on a missing row, which
            // would land in the catch below and report UNKNOWN instead of the correct
            // PUTAWAY_LOCATION_MISSING — so go through the repository, which returns an Optional.
            Itemdata item = itemdataRepository.findById(line.itemdataId()).orElse(null);
            if (item == null || item.getPutawaylocationId() == null) {
                return FailureReason.PUTAWAY_LOCATION_MISSING;
            }
            Location dest = locationRepository.findById(item.getPutawaylocationId()).orElse(null);
            if (dest == null) {
                return FailureReason.PUTAWAY_LOCATION_MISSING;
            }
            // Re-evaluates exactly what UnitloadBusinessService:179-192 evaluates. A destination
            // that permits no Case unit load is H1 exactly. `caseUnitloadTypeId` is the resolved
            // unitload_type 'Case' id that resolveRefs already looked up — NEVER a literal, because
            // the id differs between fresh-seeded and v1-migrated tenants.
            if (!destinationPermitsUnitloadType(dest, caseUnitloadTypeId)) {
                return FailureReason.PUTAWAY_LOCATION_REJECTED;
            }
            // 3. config the receive dereferences but the preflight does not cover.
            if (StringUtils.isBlank(syspropService.getSysvalue(
                    WmsConstants.SYSTEM_PROPERTY_PRINTING_ZPL_CASE_LABEL_KEY))) {
                return FailureReason.ZPL_TEMPLATE_MISSING;
            }
            if (StringUtils.isBlank(syspropService.getSysvalue(
                    WmsConstants.SYSTEM_PROPERTY_WAREHOUSE_NAME_KEY))
                    || locationRepository.findByName(INBOUND_WORKSTATION).isEmpty()
                    || locationRepository.findByName(SPAWN).isEmpty()) {
                return FailureReason.CONFIG_MISSING;
            }
            return FailureReason.UNKNOWN;
        } catch (RuntimeException probeFailure) {
            LOG.warn("RETURN auto-receive diagnosis failed; reporting UNKNOWN", probeFailure);
            return FailureReason.UNKNOWN;
        }
    }
```

`AutoReceiveLine` gains `Long itemdataId` (already resolved in `resolveRefs`, currently discarded) so
the probe needs no extra lookup by SKU. `Itemdata`, `Location` and the constraint rows are read
through repositories the service either already has or gains by constructor injection
(`ItemdataRepository`, `LocationRepository`, `LocationConstraintRepository`).

> ### ⚠⚠ `destinationPermitsUnitloadType` — get the empty-list case backwards and you invert H1
>
> This is the predicate behind the plan's **primary** reason code, so it is specified rather than
> left to the implementer. It mirrors `UnitloadBusinessService.java:179-192` exactly:
>
> ```java
>     /**
>      * True if `dest` permits `unitloadTypeId`. Mirrors UnitloadBusinessService:179-192.
>      *
>      * ⚠ AN EMPTY OR NULL CONSTRAINT LIST MEANS **PERMITTED**, NOT REJECTED. The real check is
>      * wrapped in `if (list != null && !list.isEmpty())` — an unconstrained destination is never
>      * rejected there. Reading "no constraint row => not allowed" inverts the logic and would
>      * classify EVERY ordinary destination as PUTAWAY_LOCATION_REJECTED, which is both wrong and
>      * the most plausible-looking mistake available here.
>      */
>     private boolean destinationPermitsUnitloadType(Location dest, Long unitloadTypeId) {
>         List<LocationConstraint> constraints =
>             locationConstraintRepository.findByStoragelocationtypeId(dest.getTypeId());
>         if (constraints == null || constraints.isEmpty()) {
>             return true;                                   // unconstrained => permitted
>         }
>         return constraints.stream()
>             .anyMatch(c -> c.getUnitloadtypeId().equals(unitloadTypeId));
>     }
> ```
>
> Verified against source: the repository method is
> `LocationConstraintRepository.findByStoragelocationtypeId(Long)`, keyed on the **location type id**
> (not the location id), and the match is `LocationConstraint.getUnitloadtypeId()` against the unit
> load's type id. T6 asserts the rejected case and **T6b asserts the unconstrained case returns
> `UNKNOWN`, not `PUTAWAY_LOCATION_REJECTED`** — that second test is the one that catches the
> inversion.

```java
    /**
     * SBDEV-2778 follow-up D3 — the ONLY failure vocabulary that may cross the /rest boundary.
     *
     * /rest/advice/create is permitAll() (SecurityConfiguration:126) with the tenant chosen from an
     * unauthenticated header (TenantFilter:40-41). PR #123's F4 deliberately sanitised these
     * messages. Adding a value is a security-relevant change: it must name a CLASS of condition and
     * must not encode any printer name, location name, entity id, sysprop key, SQL, or exception
     * text. When in doubt the answer is UNKNOWN plus the correlation id — the operator has the log.
     */
    public enum FailureReason {
        PUTAWAY_LOCATION_REJECTED,
        PUTAWAY_LOCATION_MISSING,
        PRINTER_UNREACHABLE,
        ZPL_TEMPLATE_MISSING,
        CONFIG_MISSING,
        SKIPPED_NO_POSITIONS,
        UNKNOWN
    }
```

`STOCK_STATE_CONFLICT` is **removed** from rev1's list: it existed only to describe a concurrent-resume
collision, and resume is deferred.

`WmsConstants.java:1313-1315` gains the reason slot, copying the `ABORTED` pattern:

```java
            case RETURN_AUTO_RECEIVE_PARTIAL:
                description = "return advice '%1s' partially received: failed on sku '%2s' after %3s of %4s positions (reason: %5s, ref: %6s)";
                break;
```

> **Arity trap.** After F1 the *only* consumer of this template is F2's
> `WmsConstants.getErrorCodeText(WmsConstants.RETURN_AUTO_RECEIVE_PARTIAL, adviceNumber, sku,
> received, total, reason, correlationId)` — exactly **one** site, exactly **six** args.
> `getErrorCodeText:1329-1332` catches `IllegalFormatException` (which `MissingFormatArgumentException`
> extends) and silently returns the **raw template**, so a site left at four args ships the literal
> string `… (reason: %5s, ref: %6s)` to the operator with **no test failing and no exception thrown**.
> Verify `F3d` (template has both slots), `F3i` (exactly one construction site, six args) and T19 (the
> rendered description contains no literal `%`) cover it from three directions.

**Why this and not the alternative.** Classifying on the exception is the cheap option and it is
either useless (Route 1) or a leak (Route 2). The probe costs a handful of indexed reads on a path
that has already failed — a return carries 1-3 positions and the failure is rare by construction — and
it is the only approach that yields the right answer for H1, H2, the printer and both config classes.

---

#### F4 — OMS surfaces the warning without blocking the return (D2, oms-laravel-api)

**File:** `app/Services/Qa/QaReturnService.php:644-677`

**Before / After** — the `failure` branch (including the dead `ENTITY_ALREADY_EXITS` block) is left
**exactly as it is**; the new branch is added after it:

```php
        $result = $this->wmsService->createReturnAdvice($facilityCode, $advice);

        if (($result['status'] ?? '') === 'failure') {
            … unchanged, including the dead reconcile branch (§2 Bug B) and the generic throw at :674
        }

        // SBDEV-2778 follow-up — WMS accepted the advice but could not finish receiving it. The
        // return IS recorded and the inbound BOL is OPEN in WMS for a dock receive, so this must NOT
        // abort the updateReturnManagement() transaction (:330). Surface it as a warning and let the
        // return complete.
        $warning = $result['response']['data']['warning'] ?? null;
        if (is_array($warning)) {
            Log::warning('WMS accepted the return advice but did not finish receiving it', [
                'parcel_id'      => $return->parcel_id,
                'facility'       => $facilityCode,
                'reference_id'   => $shipmentId,
                'wms_advice'     => $warning['advice'] ?? null,
                'wms_reason'     => $warning['reason'] ?? null,
                'correlation_id' => $warning['correlation_id'] ?? null,
                'received'       => $warning['received'] ?? null,
                'total'          => $warning['total'] ?? null,
            ]);

            return $result + [
                'status'  => 'warning',
                'warning' => $warning,
                'message' => sprintf(
                    'The return was recorded, but WMS could not finish receiving %s (%s). '
                    . 'The inbound notice %s is open in WMS for a manual dock receive. '
                    . 'Reference %s if you contact support.',
                    $warning['sku'] ?? 'the returned item',
                    $warning['reason'] ?? 'UNKNOWN',
                    $warning['advice'] ?? $shipmentId,
                    $warning['correlation_id'] ?? 'n/a'
                ),
            ];
        }

        return $result;
```

`processWmsResponse` maps unknown top-level keys into `data` (`$responseData['data'] ?? $responseData`
at `:499`), so the warning arrives at `$result['response']['data']['warning']`.

`updateReturnManagement()` at `:376-388` must stop claiming the stock was received:

```php
                'received_in_wms' => $wmsResult !== null
                    && !in_array($wmsResult['status'] ?? '', ['skipped', 'warning'], true),
```

The UI surface (a non-blocking toast rather than the red banner) rides on `formatReturnResponse`'s
payload; the component change is §7.2 step 10 — functionally the return already completes without it.

**Why this and not the alternative.** Auto-retry from OMS is rejected: every reason in F3's enum is a
configuration condition a retry cannot fix, so it burns time and produces the same outcome with more
noise. Retry is a human decision.

---

### 5.2 The REST contract change and the deploy window

⚠ **Corrected at rev2.** rev1 said `isFailureResponse` is what makes the 200 safe. It is not — that
check is never reached on today's failure path (§4). The actual chain for a **200 with a JSON body**
is:

1. `makeWmsRequest:373-375` — status is 200, so the 4xx throw does not fire.
2. `processWmsResponse:455` — `$response->successful()` is **true**, so `WmsException` is not thrown.
3. `:460` — not 204, so the short-circuit is skipped and the body **is** parsed.
4. `:497-501` — `'status' => $responseData['status'] ?? 'success'` ⇒ `'success'`; `'data' =>
   $responseData['data'] ?? $responseData` ⇒ the warning object.
5. `isFailureResponse:898-901` ⇒ **false**. (Correct, but it is step 5 of 5, not the mechanism.)

Steps 2 and 4 are the load-bearing ones, so **the primary pin is an `Http::fake` test on
`processWmsResponse`**, not a unit test on `isFailureResponse`.

| Combination | What happens | Verdict |
|---|---|---|
| **New WMS + old OMS** (the deploy window) | Steps 1-5 above; `createReturnAdvice` returns `['status'=>'success', …]`; `sendReturnRestockAdvice` returns it unexamined. The return completes and the warning is dropped on the floor | **Safe but SILENT.** The operator sees a normal success, OMS logs `received_in_wms => true`, and no artifact records that the stock is not in WMS. Acceptable only because the window is short and WMS's own log + counter still fire — but it is a real blind spot, not a clean no-op |
| **Old WMS + new OMS** | 204 as today; `$result['response']['data']['warning']` absent ⇒ `is_array` false ⇒ today's behavior exactly | **Safe** |
| **New WMS + new OMS** | Warning surfaced, return completes | Target state |

**Deploy order: `wms2-api` first, `oms-laravel-api` second** — old OMS is already unblocked against new
WMS, so there is no window in which the fix is half-applied and harmful. **Keep the window short** and
watch the WMS counter during it, because row 1 is silent on the OMS side.

`isFailureResponse` is **not modified**; a test pins that it returns `false` for the warning shape.

**Not breaking for the REGULAR path:** full success still returns 204 with the same body, and no
REGULAR advice can produce a warning (the gate at `:298` requires `AdviceType.RETURN`).

### 5.3 Flyway — no migration needed

`develop`'s head is **V2.2.09** (`V2.2.09__seed_return_advice_auto_receive_sysprop.sql` — the
kill-switch row). **No fix in this plan needs a migration**: F1-F3 are Java-only, F4 is PHP-only, and
the only DB write is the one-off operational INSERT in §7.1 step 0.

If review adds a fix that does need one: sweep **all remote branches** for the next free `V2.2.x` at PR
time. Versions are append-only; this exact trap cost SBDEV-2778 a renumber from V2.2.08 to V2.2.09.

### 5.4 What this plan deliberately does NOT change

| Thing | Why it stays |
|---|---|
| `markFinished` conditionality | Original §2 Bug 4 — losing it loses inventory silently |
| `bind()`'s count + externalid-order guards | Same hazard at position granularity |
| `execute()` non-transactional | Original §3 B2b — connection hold across CUPS, notification batching, `rollbackFor` poisoning |
| `getErrorMap()` emitting only `status` + `description` | Cross-cutting; §10-Q4 |
| `BusinessException` (no key accessor added) | F3 abandoned key-switching, so there is no consumer — §5.1 F3 |
| `ReceivingService` (any line) | §5.5 |
| `RestIdempotencyService` 2xx-only caching | §5.1 F2 landmine — relevant to §5.6, not to this PR |
| The duplicate-`externalid` UNIQUE index + `DataIntegrityViolationException` catch | Load-bearing race guard (original F9) |
| The single-RETURN-advice-per-request guard (`:195-203`) | Original F1b; F2 relies on "at most one warning per request" |
| `QaReturnService.php:659-672` (dead reconcile branch) | Editing unreachable code is churn — §2 Bug B, §10-Q4 |
| The `permitAll()` posture of `/rest/advice/create` | Out of scope; it is *why* D3 is allow-listed |

### 5.5 Coordination with SBDEV-2731 / SBDEV-2732

> ### ⚠ CORRECTED 2026-08-05 — rev1/rev2 mis-stated both tickets' state and scope
>
> Earlier revisions said "both are `status: reviewed`, unimplemented, and both own
> `ReceivingService.java:492`". **All three claims were wrong.** Verified against git and the plan
> files:
>
> | | Real state | Real scope |
> |---|---|---|
> | **SBDEV-2731** | ~~IMPLEMENTED — one commit `b5b35ab`, **not pushed**, no PR, therefore not in `v0.0.13`~~ → **MERGED 2026-08-07**, PR #133, merge `6bc709a` *(updated 2026-08-09)* | **Message-only.** Does **not** touch `ReceivingService`. Replaces the raw concatenated throw — at `UnitloadBusinessService:191` **before** its own fix, now at **`:235`** — with the keyed `unitloadTypeNotPermittedOnLocation`. Its own commit message: *"The constraint-gate logic is unchanged - message only. The rejection itself is correct."* **Confirmed 2026-08-09 by diff: no control-flow change.** |
> | **SBDEV-2821** | **MERGED 2026-08-09**, PR #135, merge `fd90487`, ClickUp `on dev` — *added 2026-08-09; this ticket did not exist when rev3 was written* | **Putaway-only, by design.** Adopted route-at-putaway; its AC states *"Receiving behaviour is unchanged"*, which the empty `ReceivingService` diff confirms. **Does not stop H1 either.** |
> | **SBDEV-2732** | `status: draft` (pending approval; no source file touched) — **unchanged** | Owns the **behaviour** fix — `ReceivingService:454-457` and `:491-495`, named in its §0 rows 1-2 as the *"SBDEV-2731 root cause"*. Its **step 15** adds the diversion gate that is the only thing removing H1's trigger |
>
> **Consequence — now VERIFIED against merged code rather than predicted: neither SBDEV-2731 nor
> SBDEV-2821 stops H1 firing.** The flowbin rejection is by design and survives both. Only
> **SBDEV-2732** removes the trigger, and it is still the least mature of the three.

**This plan does not touch `ReceivingService` at all.**

| Scenario | Effect |
|---|---|
| ~~**SBDEV-2731 lands first**~~ **← THIS IS NOW THE ACTUAL WORLD (merged 2026-08-07); it is no longer a scenario** | H1 keeps firing — 2731 is message-only, **confirmed by diff, not predicted**. What changed is the **classifier basis**: the throw (now `:235`, was `:191`) carries the real key `unitloadTypeNotPermittedOnLocation`, so F3 could switch on `getMessageKey()` instead of the state probe. **F3 is not broken either way** — the probe is key-independent by construction, which is exactly why it was chosen (rev2, Critic B5). Treat the key as a possible simplification, not a required rework. **The no-leak tests stay mandatory:** the new throw still passes `destinationLocation.getName()` as a parameter, so `getMessage()` still renders the location name |
| **SBDEV-2732 lands first** | H1 stops firing; `PUTAWAY_LOCATION_REJECTED` becomes rare. Rebase needed and scope guard **S1 must be re-anchored** — 2732 reworks `ReceivingService:491-495`, the exact lines S1 asserts are untouched. The §8.6 manual row then needs a different trigger (`ZPL_TEMPLATE_MISSING`, by unsetting `PRINTING_ZPL_CASE_LABEL` on a scratch tenant) |
| **This plan lands first** | A failing receive stops blocking returns and starts naming its reason — removes the *urgency* of 2731/2732, not their correctness. No shared file with either |
| **All in flight** | No merge conflict with 2731 (disjoint files). Conflict with 2732 is possible only if S1's anchor lines move |

**Do not "fix H1 while you are in there."** If P1 confirms H1, the escalation target is **SBDEV-2732**
(the behaviour fix), not 2731 and not 2821 — both are merged and neither touches the trigger.
~~Also flag that **2731's commit is unpushed** — 2732 consumes its key name as a hard prerequisite, so
an unpushed 2731 blocks 2732.~~ **RESOLVED 2026-08-09: 2731 merged (PR #133, `6bc709a`), so 2732's
prerequisite on the key name is satisfied.** The changes have different blast radii
(this one cannot move stock; 2732 changes which primitive moves it) and must be revertable
independently.

**Corroboration for H1 from 2732's own evidence** (its §1, `db_verified: true`): on `wh01_hydra_v2t`,
`unitload_type 4 = Case`, `location_type 2 = flowbin`, and `location_constraint` for flowbin has
exactly one row, permitting only `unitloadtype_id = 1 (PickLocation)`. So a `Case` unit load into a
flowbin **is** rejected structurally. ⚠ But 2731/2732's incident SKU is **Ice Pack**, which 2732 says
"exists only on NYWH UAT/prod" — whereas this ticket's SKU is `Chenin Blanc 25`, an ordinary wine.
H1 therefore requires that *Chenin Blanc 25 also* resolves to a flowbin putaway target. **That is
exactly what probe P1 answers, and it is unproven until someone runs it.**

### 5.6 DEFERRED — resumable retry needs its own ticket

rev1 shipped an exact-match resume branch at `AdviceRestController:223-227`. **Cut at rev2.** Three
independent blockers, each verified against source:

| # | Blocker | Evidence |
|---|---|---|
| 1 | **There is no DB backstop against double-receive.** rev1 claimed `ReceivingService:344`'s `findByIdForUpdate` plus the `:347-349` non-`OPEN` refusal would serialise two concurrent resumes. It would not: `ReceivingService` **never writes FINISHED** — its only `setState` calls are `:207`, `:240`, `:292`, all `OPEN`. Every FINISHED write is `markFinished:593-594` (after ALL positions) or `AdviceService`. A received position is still `OPEN`, so the guard cannot fire because of a prior receive, and both racers receive | grep over `src/main/java` |
| 2 | **The over-delivery guard is disabled on this path.** `ReceivingService:372` is `if (!advice.getAllowoverdelivery())` and `AdviceRestController:271` sets it `true` unconditionally, so the one remaining structural stop against receiving a position twice is switched off | source |
| 3 | **`IdempotencyFilter` would make resume unreachable.** `RestIdempotencyService.persistResponse:182-195` persists only 2xx. F2's warning is a 200 ⇒ cached ⇒ a byte-identical resubmit is replayed and never reaches the handler — i.e. resume could not serve its own primary use case | source |

**And with F1+F2 it is not needed.** `createReturnAdvice` has exactly one caller
(`QaReturnService:644`), invoked once per operator submit inside `updateReturnManagement`. Once the
warning path lets that transaction commit, OMS **records the return and reports success**, so there is
nothing to resubmit — the duplicate guard stops being reachable in the normal flow. Bug B's blocking
effect is resolved by removing the *cause* of the retry, not by making the retry work.

**A follow-up ticket should decide**, in this order: whether a received `Adviceposition` should move to
a non-`OPEN` state at all (a state-machine question that reaches well beyond returns); whether
`allowoverdelivery = true` on this path is intentional; and only then whether resume is worth building.
Do not implement resume before questions 1 and 2 are answered — without them it has no safety net.

---

## 6. File Change Summary

| # | Repo | File | Change | Fix |
|---|---|---|---|---|
| 1 | wms2-api | `service/ReturnAdviceAutoReceiveService.java` | `execute`/`executeAsIntegrationUser`/`executeInternal` return `AutoReceiveOutcome`; catch at `:565` soft-fails; new `AutoReceiveOutcome` record | F1 |
| 2 | wms2-api | `service/ReturnAdviceAutoReceiveService.java` | New `FailureReason` enum + `diagnose(AutoReceiveLine, Printer)` state probe; correlation id; `AutoReceiveLine` gains `itemdataId`; inject `ItemdataRepository`, `LocationRepository`, `LocationConstraintRepository` (the probe calls `findByStoragelocationtypeId`) | F3 |
| 3 | wms2-api | `controller/rest/AdviceRestController.java` | `:411-415` capture the outcome; `:433` 200-with-warning; `:419-430` audit row logs 200 + reason in `answer` | F2 |
| 4 | wms2-api | `service/WmsConstants.java` | `:1314` template gains `%5s` reason + `%6s` ref | F3 |
| 5 | wms2-api | `test/.../unit/service/ReturnAdviceAutoReceiveServiceUnitTest.java` | Soft-fail, no-`markFinished` regression, probe cases, no-leak assertions | §8 |
| 6 | wms2-api | `test/.../unit/controller/rest/AdviceRestControllerUnitTest.java` | 200-with-warning shape, sanitisation, audit row, 204-on-success regression | §8 |
| 7 | oms-laravel-api | `app/Services/Qa/QaReturnService.php` | Warning branch after the failure block; `received_in_wms` tightened. **The failure block, including the dead reconcile branch, is untouched** | F4 |
| 8 | oms-laravel-api | `tests/…/WmsApiServiceTest.php` | `Http::fake` pin on `processWmsResponse` (primary); `isFailureResponse` pin (secondary) | F4 |
| 9 | oms-laravel-api | `tests/…/QaReturnServiceTest.php` | Return completes on warning; still throws on genuine 4xx | F4 |
| 10 | sbdocs | `3-Resources/workflows/wms2-receiving-putaway-workflow.md` §3.5 | Document the soft-fail outcome + the residual (§2). **Must contain the literal marker `SBDEV-2778 follow-up`** — §3.5 already documents the *original* ticket, so verify `N5b` keys on the follow-up marker to avoid false-greening | §7.2 step 11 |
| 11 | sbdocs | `3-Resources/architecture/wms2-state-machine-catalog.md` §4.8 | Advice stays `OPEN` on partial auto-receive; note that a received position also stays `OPEN` (the §5.6 blocker 1 finding). **Must contain `SBDEV-2778 follow-up`** — verify `N5c` | §7.2 step 11 |
| 12 | sbdocs | `4-Archieves/…/SBDEV-2778-return-to-inventory-not-received-bol-not-closed.md` | Forward-pointer banner naming this plan's filename — verify `N5d` | §7.2 step 11 |

**No Flyway migration. No schema change. No new repository query method. No new endpoint. No change to
`ReceivingService`, `BusinessException`, `RestIdempotencyService` or `getErrorMap()`.**

---

## 7. Implementation Steps

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 0 | **PROD MITIGATION — ships BEFORE any code** | step 0 below | Ops + Nam | **Blocking.** Brent's parcel is stuck now |
| 1 | **Probes run** | P1, P2 and the log grep (§2), against **prod Hydra** | Implementer | Decides the RCA and the step-0 branch |
| 2 | **Database state** | No change. Flyway head `V2.2.09`; prod Hydra stalled at V2.2.06 and **not this plan's to fix** | — | §5.3, Q3 |
| 3 | **Feature flags** | `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` — used by step 0, unchanged by the code | Ops | Absent row = ON |
| 4 | **Config / env** | None | — | |
| 5 | **Deploy order** | `wms2-api` **first**, `oms-laravel-api` second, window kept short | Release | §5.2 |
| 6 | **Data migration** | None versioned; step 0 is a one-off operator action | Ops | |
| 7 | **External systems** | None | — | |
| 8 | **Access / permissions** | Prod Hydra read access + prod log access | Nam | Blocks prereq 1 only |
| 9 | **Monitoring — RELEASE GATE** | Grafana panel + alert on `wms2.returns.autoreceive.partial_failure`, **live before the WMS deploy**, not after | Nam | ⚠ Not a checkbox. Per §2's residual this counter is the **only** signal that stock is sitting unreceived. Shipping F1 without it converts a loud failure into a silent one |

#### Step 0 — immediate production mitigation (D1), before any code

**0a. Disable auto-receive on prod Hydra.**

**Target:** tenant DB **`wh01_hydra_v2`** (warehouse `nywh`, tenant `hydra`). Reachable via the prd
landlord `wms2_landlord` @ tunnel port **25061**. Named explicitly so nobody has to look it up
mid-incident. This is a **tenant** DB write, not a landlord one.

> ⚠ **Corrected at rev3 — rev2's INSERT would have failed with `23502` on the first command an
> operator runs under incident pressure.** `los_sysprop` (`V2.2.00__base_v2_schema.sql:1369-1383`)
> declares `version`, `hidden`, `workstation` and `client_id` **NOT NULL with no defaults**, and
> rev2's five-column `(id, syskey, sysvalue, client_id, groupname)` INSERT omits three of them. The
> form below is V2.2.09's own column list, so it is known-good.

**Step 1 — look before you write.** A row may already exist: the config UI's
`SyspropService.setSysvalue:305-317` creates one on first save.

```sql
SELECT id, sysvalue, client_id, workstation, groupname
FROM public.los_sysprop
WHERE syskey = 'RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED';
```

**Step 2a — if that returns ZERO rows, INSERT** (V2.2.09's exact shape, idempotent):

```sql
INSERT INTO public.los_sysprop
    (id, version, entity_lock, hidden, syskey, sysvalue,
     workstation, client_id, groupname, description, created, modified)
SELECT
    nextval('public.seqentities'), 0, 0, false,
    'RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED', 'false',
    'DEFAULT', 0, 'Operation Options',
    'SBDEV-2778 incident mitigation 2026-08-05: auto-receive disabled; returns complete and the inbound BOL is received at the dock.',
    now(), now()
WHERE NOT EXISTS (
    SELECT 1 FROM public.los_sysprop
    WHERE syskey = 'RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED'
);
```

**Step 2b — if step 1 returned a row, UPDATE it. Do NOT insert a second one:**

```sql
UPDATE public.los_sysprop
   SET sysvalue = 'false', modified = now()
 WHERE syskey = 'RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED';
```

Why this branch is not optional: `SyspropService.getSysvalue:290` reads through an **unscoped**
`findSysvalueBySyskey` — it does not filter by `client_id` or `workstation` — so two rows for the same
key make the lookup ambiguous and the effective value non-deterministic. One row, `client_id = 0`,
`workstation = 'DEFAULT'`, matching `MAXIMUM_RECEIVING_DURING_INBOUND` and `WAREHOUSE_NAME` on this
tenant.

`groupname` is **`'Operation Options'`**, not `'Backend'` — that is where V2.2.09 seeds it, and a
different group puts the switch in a different section of the config UI from where anyone will look
for it.

- **Cache TTL:** `@Cacheable("sysprops")` keyed on `facilityCode + ':' + key`, Caffeine TTL **2 min**
  (`CacheConfig.java:36`), eviction JVM-local ⇒ effective on every replica within ~2 minutes. No
  restart, no redeploy.
- **Effect:** reverts to pre-PR-#123 behavior — the return completes, the advice is created `OPEN`,
  staff receive at the dock.
- **Verify it took:** re-run step 1 (expect exactly one row, `sysvalue = 'false'`), then submit a test
  return and confirm no red banner.
- **Revert after this plan ships:** `UPDATE public.los_sysprop SET sysvalue = 'true', modified = now()
  WHERE syskey = 'RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED';` — per tenant, **after** the WMS deploy.
  Record both flips in the ticket.
- **Note:** when prod Hydra's Flyway stall is eventually cleared (Q5), V2.2.09 will run and its
  `WHERE NOT EXISTS` will **skip** the row you created — so your `'false'` survives the migration.
  That is correct and intended, but it means re-enabling is always a deliberate manual act.

**0b. Reconcile `IBOL000223`. Run probe P2 first. Branch on the result. Never blind-delete.**

| P2 result | Action |
|---|---|
| `gr_rows = 0`, `state = 'OPEN'`, all positions `OPEN` | Nothing received. **(preferred)** leave the advice and have the warehouse receive it at the dock via `POST /v3/receiving/receive`; OMS's return record is then created by a fresh QA submit *after* 0a takes effect. **(fallback, only if OMS must resubmit the same `reference_id`)** delete the `adviceposition` rows then the `advice` row, in that order, in one transaction, after capturing the full rows to the ticket |
| `gr_rows > 0` | **STOP.** Stock was partially received; the `goodsreceipt` / `goodsreceiptposition` / `unitload` / `stockunit` graph hangs off it. Count the physical stock with the warehouse, decide the true received quantity, adjust via the normal receipt-correction path, then close the advice through the UI |
| `state != 'OPEN'` | Already completed by some path. Re-run P2 and re-triage — the retry failure is a different problem |

Capture pre-change rows into ClickUp, act in one transaction, re-run P2 afterwards.

**0c. Confirm with Brent** that the return processes end-to-end after 0a + 0b before starting code.

### 7.2 Ordered steps

| # | Step | Repo | Verify |
|---|---|---|---|
| 1 | Run probes P1/P2 + the log grep; record verbatim in §2; flip `db_verified` to `true` if P1 resolves the trigger | — | Results in the plan |
| 2 | Step 0a + 0b + 0c | prod DB | Brent confirms |
| 3 | Add `FailureReason`; add `itemdataId` to `AutoReceiveLine`; implement `diagnose(...)` with its degrade-to-UNKNOWN wrapper; inject the repositories it needs | wms2-api | `F3a`, `F3b`, `F3c`, `F3f`, `F3g`, `F3g2`, `F3h` |
| 4 | Add `AutoReceiveOutcome`; change the three `execute*` signatures; soft-fail the catch; render `description` via the single 6-arg `getErrorCodeText`; generate + log the correlation id | wms2-api | `F1a`–`F1d`, `F3e`, `F1ra`–`F1rc` |
| 5 | Extend `WmsConstants:1314`; update the single construction site to six args | wms2-api | `F3d`, `F3i` |
| 6 | Wire the outcome in `AdviceRestController:411-415`; 200-with-warning at `:433` | wms2-api | `F2a`–`F2d` |
| 7 | Audit row at `:419-430` logs 200 + reason/correlation id in `answer` | wms2-api | `F2e`, `F2f` |
| 8 | OMS: warning branch in `sendReturnRestockAdvice`; tighten `received_in_wms`. Leave the failure block untouched | oms-laravel-api | `F4a`–`F4d` |
| 9 | OMS: `Http::fake` pin on `processWmsResponse` + `isFailureResponse` pin, in `tests/Unit/Services/WmsApiServiceTest.php` | oms-laravel-api | `F4e`, `N5a` |
| 10 | OMS UI: non-blocking toast for the warning payload | oms-laravel-api | manual §8.6 |
| 11 | Docs: workflow §3.5, state-machine §4.8 (incl. the "received position stays OPEN" finding), archived-plan forward-pointer. Each must carry the literal `SBDEV-2778 follow-up` marker | sbdocs | `N5b`, `N5c`, `N5d`, `verify-docs` |
| 12 | **Grafana panel + alert live** | monitoring | prereq 9 — **gate on this before deploying** |
| 13 | Deploy WMS, then OMS; re-enable the kill switch on prod Hydra once healthy | prod | Ticket note |
| 14 | File the §5.6 follow-up ticket (position state machine, `allowoverdelivery`, then resume) | ClickUp | Link from this plan |

### 7.3 Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict |
|---|---|---|
| 1 | **In-JVM state** | **No.** `AutoReceiveOutcome`, the reason and the correlation id are per-request locals. The `sysprops` Caffeine cache is unchanged |
| 2 | **Connection pool math** | **Marginal, bounded.** F3's probe adds a handful of indexed reads **only on the already-failed path** (rare by construction; 1-3 positions per return). No change on the success path |
| 3 | **Scheduled jobs** | **N/A** — no `@Scheduled` added or modified |
| 4 | **Long transactions** | **No.** `execute()` stays non-transactional; each `receiveGoods` keeps its own short tenant tx; `markFinished` unchanged. The soft-fail **shortens** the failure path. F3's probe runs outside any transaction of ours, in the repositories' own short ones |
| 5 | **Request affinity** | **No.** No cross-request state. (rev1's resume relied on DB-only state; cut anyway) |
| 6 | **Retry / idempotency** | **Yes — changed, and it must be understood.** See Evidence E1 |
| 7 | **Tenant context** | **No.** Request thread inside `TenantContext`; no `@Async`. `executeAsIntegrationUser`'s `SecurityContextHolder` swap is unchanged and still restores in `finally` — note F3's probe runs **inside** that scope, so its reads are attributed to `oms_integration`, which is correct |
| 8 | **Distributed lock correctness** | **No new lock.** ⚠ And per §5.6 blocker 1, the existing `ReceivingService:344` lock does **not** provide cross-request double-receive protection on this path — recorded so nobody re-derives rev1's false claim |
| 9 | **Cache invalidation** | **No.** `Advice`, `Adviceposition`, `Location`, `Itemdata` are not `@Cacheable` on these paths; the only cache read is `sysprops`, unchanged |
| 10 | **External notifications** | **No change.** A soft-failed position sends nothing, which is correct — nothing was received |

#### Evidence

**E1 — retry / idempotency (row 6).** F2 turns the failure response from 400 into 200, and
`RestIdempotencyService.persistResponse:182-195` persists only 2xx. So the failure response is now
**cached**: a byte-identical resubmit within retention is replayed by `IdempotencyFilter` rather than
re-executed. With F1+F2 this is benign — OMS commits the return on the first call and does not
resubmit (`createReturnAdvice` has one caller, once per operator submit). It is load-bearing for the
deferred work (§5.6 blocker 3). **No change is made to the idempotency layer in this plan.**

**E2 — no new lock (row 8).** rev1 asserted a DB backstop that does not exist; see §5.6 blocker 1 for
the verification. This plan neither adds nor relies on a lock: the soft-fail path only reads.

### 7.4 v2-only constraint checklist

| # | Constraint | Verdict |
|---|---|---|
| 1 | **OSIV disabled** | **Addressed** — all probe reads are explicit repository calls returning fully-populated entities (no-JPA-association codebase); no lazy navigation outside a transaction |
| 2 | **Transaction manager** | **Addressed** — no new `@Transactional`. `markFinished` keeps `@Transactional(value = "tenantTransactionManager")` via `self`; `execute()` stays non-transactional; `resolveRefs` keeps `@Transactional(value = "tenantTransactionManager", readOnly = true)`, still **public**, still via `self` (a non-public `@Transactional` gets no transaction and fails invisibly) |
| 3 | **`readOnly = true`** | **N/A** — `diagnose` is not annotated; its reads run in the repositories' own transactions. Annotating it via `this.` rather than `self.` would silently do nothing |
| 4 | **Caffeine invalidation** | **N/A** — no cached entity is written |
| 5 | **Jakarta namespace** | **Addressed** — new imports are `java.util.UUID` plus existing repositories |
| 6 | **H2-compatible test SQL** | **Addressed** — all new WMS tests are Mockito unit tests, no SQL. The Testcontainers lane is broken (SBDEV-2217); see §8.7 |
| 7 | **`BaseControllerTest`** | **Addressed** — `AdviceRestControllerUnitTest` covers the new response and audit row; `create()`'s mapping and signature are unchanged |
| 8 | **Micrometer metrics** | **Addressed** — no new metric. `wms2.returns.autoreceive.partial_failure` already fires on exactly this path and is now **load-bearing**, hence prereq 9 is a release gate. Success counter and `execute` timer unchanged |

---

## 8. Testing Plan

### 8.1 Unit — `ReturnAdviceAutoReceiveServiceUnitTest`

| id | Test | Asserts |
|---|---|---|
| T1 | `executeReturnsPartialOutcomeInsteadOfThrowingWhenFirstPositionFails` | No exception escapes; `PARTIAL`, `received == 0`, `total == 1` |
| T2 | `executeDoesNotCallMarkFinishedWhenAnyPositionFails` | **Regression guard on the original §2 Bug 4** — `verify(self, never()).markFinished(any())` |
| T3 | `executeStillCallsMarkFinishedWhenEveryPositionSucceeds` | Happy path unchanged; `SUCCESS`; success counter |
| T4 | `executeIncrementsPartialFailureCounterOnSoftFail` | counter == 1 |
| T5 | `executeReturnsSkippedForEmptyPlan` | `SKIPPED_NO_POSITIONS`; no `markFinished` |
| T6 | `diagnoseReturnsPutawayLocationRejectedWhenDestinationPermitsNoCaseUnitLoad` | H1 shape, built from real `LocationConstraint` rows keyed on `storagelocationtypeId` |
| T6b | `diagnoseDoesNotReportRejectedWhenDestinationHasNoConstraintRows` | **The inversion guard.** An empty/null constraint list means PERMITTED (`UnitloadBusinessService:181`). If this returns `PUTAWAY_LOCATION_REJECTED`, every ordinary destination is misdiagnosed — assert `UNKNOWN` |
| T7 | `diagnoseReturnsPutawayLocationMissingWhenLocationRowAbsent` | H3 `:455` shape |
| T8 | `diagnoseReturnsPrinterUnreachableWhenCupsProbeFails` | TOCTOU after `validate()` |
| T9 | `diagnoseReturnsConfigMissingForUnsetWarehouseNameAndZplTemplateMissingForUnsetZpl` | Two config classes |
| T10 | `diagnoseReturnsUnknownWhenNothingIsObservablyWrong` | Fail-safe default |
| T11 | `diagnoseReturnsUnknownWhenTheProbeItselfThrows` | A diagnostic must never harden a soft-fail |
| T12 | `outcomeCarriesNoInternalIdentifiers` | Serialise the outcome; assert no printer name, **no destination location name**, no numeric entity id, no sysprop key, and **no substring of the causing exception's `getMessage()`** — built from the real `UnitloadBusinessService:191` exception whose message contains the lane name |

### 8.2 Unit — `AdviceRestControllerUnitTest`

| id | Test | Asserts |
|---|---|---|
| T13 | `createReturns200WithWarningWhenAutoReceivePartiallyFails` | 200; `status == "success"`; `warning.code` / `.reason` / `.correlation_id` present |
| T14 | `createStillReturns204OnFullSuccess` | Regression guard on REGULAR + happy RETURN |
| T15 | `createStillReturns400OnPreflightRejection` | Unknown SKU rejected by `validate()` is still a hard 400 with **no** advice row saved |
| T16 | `warningBodyContainsNoInternalIdentifiers` | Same allow-list assertion as T12, at the HTTP boundary |
| T17 | `auditRowRecords200AndReasonWhenWarned` | `service_log` row: status code `200`, `answer` carries reason + correlation id |
| T18 | `auditRowStillRecords204AndNullAnswerOnCleanSuccess` | Regression |
| T19 | `partialMessageIsFormattedWithAllSixArguments` | The arity trap — the rendered description contains **no** literal `%5s` / `%6s` |

### 8.3 Regression

T20-T22 live in `AdviceRestControllerUnitTest` / `ReturnAdviceAutoReceiveServiceUnitTest` /
`SyspropMigrationDescriptionWidthTest` respectively; T23 is a whole-build check, not a test class.

| id | Test class | Test | Asserts |
|---|---|---|---|
| T20 | `ReturnAdviceAutoReceiveServiceUnitTest` | Kill switch `= 'false'` bypasses auto-receive; absent row still means ON | Unchanged from PR #123 |
| T21 | `AdviceRestControllerUnitTest` | Single-RETURN-advice-per-request guard still rejects a mixed batch | Original F1b |
| T22 | `SyspropMigrationDescriptionWidthTest` | still passes untouched | No migration added |
| T23 | *(build)* | `mvn clean compile` + full `mvn test` | Expect **2 pre-existing failures** on clean `develop` (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`). **`mvn test` mutates the tracked `archunit_store` — revert it before committing** |

### 8.4 OMS — PHPUnit

T24-T26 belong in `tests/Unit/Services/WmsApiServiceTest.php`; T27-T30 in
`tests/Unit/Services/Qa/QaReturnServiceTest.php` (match the repo's existing test-dir layout when
creating them).

| id | Test class | Test | Asserts |
|---|---|---|---|
| T24 | `WmsApiServiceTest` | **`processWmsResponse` via `Http::fake` returns `status=success` and `data.warning` for a 200 JSON body** | **PRIMARY pin** — §5.2 steps 2 and 4 |
| T25 | `WmsApiServiceTest` | `processWmsResponse` still short-circuits a 204 and drops the body | Pins the landmine that forced the 200 |
| T26 | `WmsApiServiceTest` | `isFailureResponse` returns **false** for the warning shape | Secondary pin |
| T27 | `QaReturnServiceTest` | `sendReturnRestockAdvice` returns `status => 'warning'` and does **not** throw | The unblocking property |
| T28 | `QaReturnServiceTest` | `updateReturnManagement()` completes and persists the return when WMS warns | End-to-end within OMS |
| T29 | `QaReturnServiceTest` | `sendReturnRestockAdvice` still throws on a genuine 400 (unknown SKU) | F4 did not over-broaden |
| T30 | `QaReturnServiceTest` | `received_in_wms` is `false` in the log line on a warning | The tightened expression |

### 8.5 Not tested, deliberately

`QaReturnService.php:659-672` gets no test: the branch is unreachable (§2 Bug B) and this plan does not
touch it. A test would encode dead behavior as a contract.

### 8.6 Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Happy path unchanged | staging (wineco-dev / hydra-dev2) | Returns QA → Restock Inventory → Receive now, SKU with a valid `PutAwayLane` destination | Return completes; **204**; advice + positions `FINISHED`; `goodsreceipt` rows; UL label prints | |
| Soft-fail unblocks the return | staging | Force a failure — unset `PRINTING_ZPL_CASE_LABEL` on a scratch tenant (⇒ `ZPL_TEMPLATE_MISSING`) | **Return created in OMS.** Non-blocking warning names SKU + reason + correlation id. Advice `OPEN`, positions `OPEN`, **zero** `goodsreceipt` rows | |
| No phantom close | staging | `SELECT state FROM advice/adviceposition` for that advice | Both `OPEN`. **Never `FINISHED`** | |
| Correlation id joins to the log | staging | Grep the WMS log for the id from the warning | Exactly one `RETURN auto-receive PARTIAL FAILURE correlationId=<id>` with the full stack | |
| Reason is right, and leaks nothing | staging | Inspect the HTTP body and the OMS banner | `reason: ZPL_TEMPLATE_MISSING`; **no location name, printer name, id, sysprop key or exception text anywhere in either** | |
| Audit row records the warning | staging DB | `SELECT status, state_code, answer FROM service_log WHERE process='ADVICE_IMPORT' ORDER BY id DESC LIMIT 1;` | `state_code = 200`, `answer` carries reason + correlation id | |
| Dock receive still works | staging | Receive the `OPEN` advice via the mobile/dock path | Stock lands; BOL closes; no double-receive | |
| Kill switch OFF | staging | `sysvalue='false'`, wait ~2 min, submit a return | Advice `OPEN`, **204**, no warning, no auto-receive | |
| Old-OMS / new-WMS window | staging | Un-updated OMS against new WMS; force a soft-fail | Return completes; **no error banner — and no warning either.** Confirm the WMS counter still increments (this is the silent case, §5.2 row 1) | |
| Genuine 4xx still blocks | staging | Return for a SKU that does not exist for the client | Hard failure, red banner, **no advice row created** | |
| SQL sanity | staging DB | `SELECT a.number, a.state, count(g.id) FROM advice a LEFT JOIN goodsreceipt g ON g.advice_id = a.id WHERE a.type='RETURN' GROUP BY 1,2;` | No row with `state='FINISHED'` and `count = 0` | |

### 8.7 Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped |
|---|---|---|
| `mvn test -Dtest=ReturnAdviceAutoReceiveServiceUnitTest` | | |
| `mvn test -Dtest=AdviceRestControllerUnitTest` | | |
| `mvn clean compile` | | |
| `mvn test` (full) | | |
| `php artisan test --filter=QaReturnServiceTest` | | |
| `php artisan test --filter=WmsApiServiceTest` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2778-return-auto-receive-hard-blocks-return-on-partial-failure.sh` | | |

### 8.8 Deliberately-skipped coverage

| What | Why |
|---|---|
| Testcontainers IT of the full soft-fail path | The v2 IT harness cannot boot (SBDEV-2217) |
| A test reproducing H1 specifically | Requires a flowbin `putawaylocation_id`, which exists on no reachable tenant. `ZPL_TEMPLATE_MISSING` substitutes |
| Concurrency tests | rev1's resume is cut; nothing in F1-F4 introduces a concurrent write |
| OMS UI toast component test | The blocking behavior is fixed in the service layer; covered manually |

---

## 9. Risks & Mitigations

| # | Risk | Sev | Mitigation |
|---|---|---|---|
| 1 | **The failure becomes silent.** Soft-fail means a systemic problem (every return on a tenant failing) shows up only as a dock backlog. **This is the plan's central trade and its biggest risk.** | **Critical** | §7.1 prereq 9 is a **release gate**: the Grafana panel + alert on `wms2.returns.autoreceive.partial_failure` must be live *before* the WMS deploy. §2's residual section states the trade explicitly and must be copied into the ClickUp update. Manual rows 2, 4, 6 and 9 verify each signal independently |
| 2 | **F3's implementer falls into the `getMessage()` trap** and ships a real location name to an unauthenticated endpoint | **Critical** | §5.1 F3's double-trap box states it before the code; T12/T16 assert no substring of the real exception message appears in the payload, built from the actual `UnitloadBusinessService:191` exception; verify `F3f`/`F3g`/`F3g2` |
| 3 | **Step 0b deletes rows with receipts behind them** | **Critical (operational)** | P2 mandatory before any write; `gr_rows > 0` is an explicit STOP; pre-change rows captured; the preferred branch deletes nothing |
| 4 | **The 200 breaks an unknown consumer** | Medium | The 200 fires only for `type=RETURN` + auto-receive + partial failure — a shape that does not exist today. `status: "success"` keeps every consumer's success check correct. §5.2 walks the actual parsing chain; the legacy `qa-api` sender is covered by the same argument |
| 5 | **The deploy window is silent on the OMS side** | Medium | §5.2 row 1 labelled "Safe but SILENT"; deploy order + "keep the window short"; the WMS counter still fires and is watched (risk 1's gate); manual row 9 exercises it |
| 6 | **F3's probe misdiagnoses** (state changed between failure and probe, or the cause is not observable) | Medium | It degrades to `UNKNOWN` + a correlation id, which is no worse than today; T10/T11. The reason routes the ticket, the log carries the truth |
| 7 | **The real prod trigger is none of H1/H2/H3** | Medium | The plan is trigger-agnostic; probes are prereq 1; `UNKNOWN` is safe |
| 8 | **The kill switch is never re-enabled** | Medium | Step 13 is explicit; the `skipped_switch_off` counter makes the OFF state visible |
| 9 | **A reviewer "consistency-fixes" `isAutoReceiveEnabled` to `Boolean.parseBoolean`** | Medium | Untouched here; guarded by its Javadoc and verify `S3` |
| 10 | **Someone re-adds resume without §5.6's questions answered** | Medium | §5.6 states all three blockers with their verification, and §7.2 step 14 files the follow-up ticket so the analysis is not lost |
| 11 | **SBDEV-2731/2732 conflict** | Low | Disjoint file sets — §5.5 |

**Acceptance gate:**
`sbdocs/9-System/scripts/verify-SBDEV-2778-return-auto-receive-hard-blocks-return-on-partial-failure.sh`
must report `0 fail`. Every fix has at least one POSITIVE and one NEGATIVE assertion, plus scope guards
— **seven** of them, all enumerated: `S1` `ReceivingService` untouched, `S2` no new Flyway
migration, `S3` kill switch still default-ON, `S4` no resume branch was added, **`S4b` the duplicate
guard is still unconditional**, `S5` the dead OMS reconcile branch was not edited, and **`S6` the
idempotency layer was not touched**.

Run it with `PROJECT_ROOT` pointed at the monorepo root, or at a symlink shadow root whose `v2/`
children are the per-ticket worktrees (recipe in `wms-plan-executor`) — otherwise it grades the main
checkouts. `WMS_ROOT` / `OMS_ROOT` override each repo; `RUN_MVN=1` adds the targeted JUnit classes.

**Negative-tested against the pre-fix tree on 2026-08-05** — the script is not trusted on a green
number alone:

```
Result: 18 pass, 22 fail, 2 skip     (PROJECT_ROOT = the unmodified working tree)
```

**Expected split when the work is complete:**

```
Result: 40 pass, 0 fail, 2 skip      (RUN_MVN=0)
Result: 42 pass, 0 fail, 0 skip      (RUN_MVN=1)
```

Stating the target number matters: a run reporting `35 pass, 0 fail` is **not** done — it means five
checks silently stopped executing (a renamed function, a `run` line dropped during a rebase). Compare
the pass **count**, not just the fail count. If the check set legitimately changes, update both
numbers here in the same commit.

Every one of the 22 failures is a fix, test or doc update that has not been written yet. Every one of
the 18 passes is a
guarantee that must survive: `markFinished` conditionality, `execute()` non-transactional, 204 on
success, the two Route-1/Route-2 security guards, `isFailureResponse` unchanged, the 204
short-circuit intact, and the seven scope guards. That split is the evidence the assertions are
non-vacuous in both directions.

**Mutation-tested, not just observed.** The two guards whose false-greening would be most damaging
were verified to actually flip on a shadow copy of the repo:

| Guard | Mutation injected | Result |
|---|---|---|
| `F3f` (no `getMessage()` — the Route 2 leak) | added a method returning `e.getMessage()` | PASS → **FAIL** ✔ |
| `S4` (resume stayed cut) | added an `evaluateResume()` method | PASS → **FAIL** ✔ |
| `F2e` + `F2f` (audit row) — **rev3, two-way** | (a) changed `NO_CONTENT`→`OK` on **only** the two out-of-scope endpoints `:546`/`:704` | stayed **FAIL** ✔ — collateral damage cannot buy a green |
| `F2e` + `F2f` | (b) applied the correct conditional to **only** the in-scope `ADVICE_IMPORT` block | FAIL → **PASS** ✔ |

Test (b) is the half people skip. A negative assertion that can never pass is as useless as one that
always does; `F2e`/`F2f` are now proven to distinguish the right change from the wrong one, which is
exactly what the file-wide version of these two checks could not do.

Re-run and record the split in §12 after each implementation pass.

**Every perl-based helper carries `[ -f "$2" ] || return 1`**, and patterns reach perl through the
environment rather than being interpolated into the program text. Both were proven by experiment:

- Without the file guard, `perl -0777 -ne '…' missing.java` **exits 0**, so every multi-line assertion
  about a missing file would false-green. Demonstrated: unguarded → `exit=0`, guarded → `exit=1`.
- With the pattern interpolated into the program text, a mis-escaped `\[` produces
  `Unmatched [ in regex` and perl exits **255**, which a *negative* assertion reads as "no match" —
  passing for the wrong reason. This bit one check during authoring. **Corollary: never put a literal
  `$` in a pattern** — perl reads it as an anchor. Match a PHP variable as `.response`.

---

## 10. Open Questions / Resolved Decisions

### Resolved

**D1 — Immediate prod mitigation ships FIRST. RESOLVED (user, 2026-08-05).** §7.1 step 0. *Rationale:*
Brent cannot process returns now; the flag is a two-minute DB write with no deploy, reverting to a
behavior that shipped for months. The reconciliation is branch-on-probe because a blind delete would
orphan a receipt graph.

**D2 — Soft-fail. RESOLVED (user, 2026-08-05); scope narrowed at rev2.** The advice stays `OPEN`, WMS
returns 200-with-warning, OMS creates the return. **The "resumable retry" half of D2 is deferred** —
see D7.

**D3 — Allow-listed reason code + correlation id. RESOLVED (user, 2026-08-05); grounding changed at
rev2.** A bounded enum plus a UUID. *Rationale:* `/rest/advice/create` is `permitAll()` with the tenant
from an unauthenticated header, and PR #123's F4 sanitised these messages deliberately. **At rev2 the
derivation moved from the exception key to a post-failure state probe**, because the key is
`"placeholder"` for every case of interest and reading the message is a leak (§5.1 F3).

**D4 — Do not touch `ReceivingService:492`. RESOLVED.** Owned by SBDEV-2731/2732 — §5.5.

**D5 — No Flyway migration. RESOLVED.** §5.3.

**D6 — Deploy `wms2-api` before `oms-laravel-api`. RESOLVED.** §5.2 — with the caveat that row 1 is
silent, so keep the window short.

**D7 — Resumable retry is DEFERRED to its own ticket. RESOLVED at rev2 (architect review).** Three
verified blockers (no DB backstop, `allowoverdelivery = true`, idempotency replay) and, decisively, it
is **not needed**: with F1+F2 the single caller commits the return and never resubmits. §5.6. *Options
considered and their fate:* exact-match resume (rev1's choice) — **withdrawn**, its safety argument was
false; idempotent success on any duplicate — **rejected**, quantities may differ; delete-and-recreate —
**rejected**, destructive on an unauthenticated endpoint; **do nothing, because F1+F2 removes the
retry** — **chosen**.

**D8 — Do not edit `QaReturnService.php:659-672`. RESOLVED at rev2.** The branch is unreachable
(§2 Bug B). Editing it is churn; making it reachable requires the `getErrorMap()` change, which is
cross-cutting and belongs to Q4.

### Still open

| # | Question | Owner | Blocking? |
|---|---|---|---|
| Q1 | What actually threw on prod on 2026-08-05 — H1, H2 or H3? | Implementer (P1/P2 + log grep) | **No** for the fix; **yes** for closing the RCA and for expediting SBDEV-2731 |
| Q2 | Should a received `Adviceposition` move off `OPEN`? Today nothing does it outside `markFinished`/`AdviceService`, which is why §5.6 blocker 1 exists | Architecture | No here; **prerequisite for any future resume work** |
| Q3 | Is `allowoverdelivery = true` on the RETURN create path intentional? | Brent / Nam | No here; §5.6 blocker 2 |
| Q4 | Should `getErrorMap()` emit the error `code`? It would let OMS branch structurally and would make the dead reconcile branch reachable | — | No — cross-cutting; original plan's §10-Q11 |
| Q5 | Is prod Hydra's Flyway stall (V2.2.06) tracked anywhere? `db/reassign-tenant-ownership.sh` is merged but an operator must run it | Ops | No — but it is why step 0a needs an INSERT |
| Q6 | Should the OMS warning auto-raise a support ticket, or is the Grafana alert enough? | Brent / Nam | No |

---

## 11. Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | ⚠ `db_verified: partial` — every preflight dependency proven present on `wh01_hydra_v2`; prod Hydra unreachable so the **trigger** is unproven and H1 is structurally unreproducible on the migrated dev copy. Probes P1/P2 + a log grep are prereq 1. The three defects fixed here are proven from code alone |
| 1 | **All callsites enumerated** | ✓ §0, 16 rows across two repos, re-confirmed at rev2. In-scope rows map to a §5 fix, a §7 step and a §9 assertion; exclusions carry rationale, including row 15's ⚠ (the exclusion that turned out to matter) |
| 2 | **Adjacent bugs** | ✓ Found and routed, not absorbed: `getErrorMap()` never emits the code and OMS's reconcile branch is therefore dead (Q4); a received `Adviceposition` never leaves `OPEN` (Q2); `allowoverdelivery=true` disables the over-delivery guard (Q3); `optionalBoxtype.get()` NPE→500 (original §10-Q10); prod Hydra's Flyway stall (Q5) |
| 3 | **Backward compatibility** | ✓ §5.2 walks the **actual** parsing chain (corrected at rev2 — `isFailureResponse` is not the mechanism); both mixed-version combinations analysed, row 1 labelled silent; 204-on-success unchanged; REGULAR path cannot reach the new branch; deploy order stated |
| 4 | **Concurrency** | ✓ §7.3 E1/E2. No new lock, no new concurrent write. rev1's false "DB backstop" claim is retracted in §5.6 blocker 1 with the grep that disproves it, so it cannot be re-derived. Idempotency behavior change documented in E1 |
| 5 | **Multi-tenant** | ✓ All reads tenant-scoped; F3's probe runs inside the `oms_integration` security scope and the request's `TenantContext`; the kill-switch read is unchanged |
| 6 | **Error handling** | ✓ Soft-fail replaces one throw and adds none; the probe's default is `UNKNOWN` and it degrades to `UNKNOWN` if it throws (T11); genuine 4xx still hard-fails (T15, T29); the arity trap is asserted (T19) |
| 7 | **Observability** | ✓ Correlation id joins the OMS banner to the WMS stack; the audit row records 200 + reason; `partial_failure` is load-bearing and gated on a Grafana panel **before** deploy; the residual is stated in §2 and required in the ticket update |
| 8 | **Rollback / migration** | ✓ No Flyway change, no schema change. Rollback = the kill switch (~2 min TTL) plus reverting two PRs; the WMS PR is safe to revert alone (§5.2) |
| 9 | **Test coverage** | ✓ §8.1 T1-T12, §8.2 T13-T19, §8.3 T20-T23, §8.4 T24-T30, manual §8.6 (11 rows incl. the silent-window row), not-tested declared §8.5, skipped §8.8 |
| 10 | **Cross-version (v1↔v2)** | ✓ **v2-only.** v1 never had this failure mode: `v1/wms-api AdviceRestController:272-319` collapses every auto-receive failure to `GENERIC_ERROR`, and v1's OMS caller is the legacy `qa-api`, not `QaReturnService`. Nothing to port |

---

## 12. Implementation Status

*To be completed during implementation. Must record: probe P1/P2 results and the log-grep finding (and
flip `db_verified` accordingly); the step-0 mitigation timestamp and the `IBOL000223` reconciliation
branch taken; the Grafana panel link and the timestamp it went live (release gate); commit SHAs per fix
in both repos; test class + method names added; `mvn clean compile` / `mvn test` / `php artisan test`
counts; the literal `Result: N pass, 0 fail, N skip` line from the verify script; PR links for both
repos and the merge order actually used; the kill-switch re-enable timestamp; the follow-up ticket id
filed per §7.2 step 14; and any deliberately skipped coverage with rationale.*
