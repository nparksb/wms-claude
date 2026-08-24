---
title: "WMSv2: one Move Stock action creates multiple phantom unit loads — no double-submit guard and a new unit load minted per request; the v1 quantity-inflation defect does NOT reproduce here"
ticket: "SBDEV-3003"
ticket_url: "https://app.clickup.com/t/868ku68tw"
type: "bugfix"
priority: "high"
status: "archived"
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-20
updated: 2026-08-20
db_verified: true
related:
  - ../../wms1/plan/SBDEV-3003-move-stock-lost-update-inventory-inflation.md
  - ./SBDEV-3003-slice2-transfer-stock-idempotency.md
  - ./reviews/SBDEV-3003-review-mobile.md
  - ./reviews/SBDEV-3003-review-api-verify.md
  - ../../../3-Resources/workflows/wms2-move-stock-unitload-workflow.md
  - ../../../3-Resources/design/wms2-stockunit-design.md
  - ../../../3-Resources/architecture/wms2-transaction-osiv-boundary-map.md
tags:
  - plan
---

> **ARCHIVED 2026-08-21 — both slices merged and deployed to DEV.**
>
> The `status:` field said "SLICE 1 PR SUBMITTED" right up to archival; that was stale. Actual state:
>
> - **Slice 1 (Fix D + Fix F)** — `wms2-mobile-ui` PR **#39** (merge `682c015`) + `wms2-api` PR **#175**
>   (merge `7c23646`), both merged 2026-08-21.
> - **Slice 2 (Fix E + Fix G)** — its own plan, [[SBDEV-3003-slice2-transfer-stock-idempotency]],
>   merged (`wms2-api` #176 → `cdd85d9`, `wms2-mobile-ui` #40 → `55435bf`), deployed, and its §5 curl
>   matrix **run in full on DEV with every row passing** — including the row proving a deliberate
>   repeat move still executes, and the row proving a failed move is not cached as a success. That
>   plan is archived beside this one; its §6e holds the measured record.
>
> Before merging, Slice 1 + Slice 2 were trial-merged together and both full suites run, since no
> individual PR's CI checks the combined state: api **5238 run / 2 failures** (the two known
> pre-existing develop failures), mobile **188/188**.
>
> **Acceptance script RETIRED to `sbdocs/4-Archieves/scripts/verify-SBDEV-3003-move-stock-lost-update-inventory-inflation.sh`.**
> It graded BOTH plans of this pair plus Slice 2, and all three are now archived, so nothing active
> references it. Final grading, measured against `origin/develop` heads (v1 api `c41a425`, v1 ui
> `5b95591`, v2 api `26fd052`, v2 ui `55435bf`): **49 pass, 0 fail, 3 skip** — the 3 skips are the
> maven rows under `SKIP_MVN=1`.
>
> ⚠ **That number is only meaningful against `origin/develop`, not a local checkout.** Graded against
> the working checkouts it read **5 pass, 44 fail** — because all four were behind origin (v2 api by
> 10 commits, v2 mobile-ui by 13). A wall of credible, honest-looking reds that meant only "stale
> tree". Re-grade in a throwaway `--detach` worktree at `origin/develop`, never in the main checkout.
>
> **Implementation worktrees removed 2026-08-21:** `wms-api/SBDEV-3003`, `wms-mobile-ui/SBDEV-3003`,
> `wms2-api/SBDEV-3003`, `wms2-mobile-ui/SBDEV-3003`, and `.verify-root/SBDEV-3003`. All four branches
> were confirmed merged (PRs #200, #101, #175, #39) and ancestors of `origin/develop` before removal.

# WMSv2: Move Stock mints phantom unit loads on replay (quantity is safe)

**Ticket:** [SBDEV-3003](https://app.clickup.com/t/868ku68tw)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high — phantom containers and operator confusion; **no inventory-integrity loss**
**Status:** Slice 1 (D+F) implemented, self-verified **and independently reviewed** — findings applied, commits amended to `20d697d` (mobile-ui) / `0efea2b` (api). **PRs submitted 2026-08-20:** [wms2-mobile-ui #39](https://github.com/SiteBossInc/wms2-mobile-ui/pull/39) + [wms2-api #175](https://github.com/SiteBossInc/wms2-api/pull/175), both into `develop` and **independent of each other** (no merge order). Awaiting PR review + merge. Lane records: [[reviews/SBDEV-3003-review-mobile]] · [[reviews/SBDEV-3003-review-api-verify]]. Slice 2 (E/G) had its own T2 plan: [[SBDEV-3003-slice2-transfer-stock-idempotency]] — **MERGED + deployed to DEV and ARCHIVED 2026-08-21** (api #176, mobile-ui #40); its §5 curl matrix is only partly run, tracked on the ticket — see also §3.0, §9.1 and §11
**Date:** 2026-08-20

> **Read the v1 plan first.** The reported inventory inflation is a **v1-only** defect
> (`StockunitBusinessService:270`, a stale operand written onto a re-fetched entity). **v2 does not
> reproduce it**: `transferStockToUnitLoad:208-214` re-fetches with `findByIdForUpdate` +
> `entityManager.refresh` and computes from the locked instance at `:373`. What v2 *does* share is
> the **trigger** and the **amplifier** — so on v2 a double-submit produces N phantom unit loads with
> **correct totals**. Nam authorized fixing both versions.

---

## 0. Affected sites (enumeration before drafting)

Class-A signature (`receiver.setX(otherObj.getX().add|subtract(...))`) searched across `src/main`:
**0 hits in v2**, 1 in v1. v2's hardening landed via SBDEV-1710 and SBDEV-2481.

| # | File:line | Construct | Same root cause? | In scope? |
|---|-----------|-----------|------------------|-----------|
| D | `wms2-mobile-ui` — 27 of 28 scan components | `submit()` on both `@keyup.enter.prevent` and `@click`; in-flight flag absent or too narrow; transfer dispatch not awaited | **trigger** | **yes** (Move Stock now; rest phased). `inputAmount.vue` is byte-identical to v1 pre-fix so the v1 hunk applies; `scanDestination.vue` **diverged on `origin/develop` via SBDEV-2994** and must be adapted — see §2 Bug D and §3 Fix D |
| E | `service/StockunitService.java:192` | `unitloadService.createUnitload()` on **every** request in the existing-container pallet branch → replays fragment instead of merging | **amplifier** | **yes** |
| F | `util/OptimisticLockRetry.java:19-28` | javadoc example `fresh.setAmount(newAmount)` with `newAmount` computed **outside** the lambda — teaches the exact v1 defect shape | doc defect | **yes** |
| G | `controller/StockUnitController.java:68` `/transferStock` | the endpoint the mobile UI actually posts to; no idempotency key **because `IdempotencyFilter.shouldNotFilter:99` self-limits to `/rest/**`** | enabling condition | **yes** — enroll the path, do not build storage (§3 Fix G) |
| H | `controller/mobile/MoveStockController.java:96` `scanDestination` | **appears dead for this flow** — `store/moveStock.js:169` posts to `/stockUnit/transferStock`, not here. `MobileMoveStockService.selectDestination:234` duplicates the transfer logic | needs confirmation | **investigate** |
| I | `service/StockunitBusinessService.java:208-214, :373` | `findByIdForUpdate` + `refresh`, arithmetic on the locked instance | no — **already correct**, this is the shape v1 must adopt | no |
| J | `service/StockunitBusinessService.java:432, :466` | `changeAmount` / `changeReservedAmount` both lock + refresh first | no — already correct | no |

---

## 1. Problem Statement

See the v1 plan §1 for the client report (WineCo ST#1116, PNCC24 → TransferLane07, ~21 phantom
96-unit `UL3524xx` records) and the DEV reproduction.

On v2 the same operator action yields:

- **Symptom present:** N duplicate destination unit loads for one Move Stock action.
- **Symptom absent:** quantity inflation. Each replay debits the source correctly under a
  pessimistic lock, so totals stay consistent.

### DB verification (floor item 1)

`wh01_om1_v2` (`wsl-wineco-uat`, 10.0.0.6, Flyway head 2.2.17) — the v2 WineCo DB. PNCC24
(itemdata `23886511`) reconciles **exactly**:

```sql
SELECT (SELECT sum(amount) FROM stockrecord WHERE itemdata='PNCC24'
          AND activitycode='RECEIVING' AND type='STOCK_CREATED')  AS received,  -- 3828
       (SELECT sum(amount) FROM stockrecord WHERE itemdata='PNCC24') AS ledger, -- 3828
       (SELECT sum(amount) FROM stockunit WHERE itemdata_id=23886511) AS onhand;-- 3828
```

3,828 = 3,828 = 3,828 across 66 records and 29 quantity-changing events; every `MANUAL_SPLIT` is a
matched −N/+N pair. **No drift on v2.** `view_warehouse_location_report` also returns one clean row
per location (2568 + 600 + 528 + 86 = 3782 live), so the SKU Location report is not double-counting.

TransferLane07 has been empty since 2026-07-16 and **zero `UL3524%` records exist** in this DB — the
incident was on the v1 DEV database (`wh01_om1` @ 10.0.0.4), not here. Confirmed via `dev_landlord`:
`wineco/wsl → jdbc:postgresql://dev.sbo.li:25060/dev_wh01_om1` is the only active v2 DEV tenant, and
`dev_wh01_om1` has no CWUSTK activity at all.

---

## 2. Root Cause Analysis

### Bug D — no double-submit guard (trigger)

`submit()` is reachable from `@keyup.enter.prevent="submit"` (both the existing-container text field
and the new-container autocomplete) **and** the Submit button's `@click`, and the terminal
`this.$store.dispatch('moveStock/transferStock', data)` is **not awaited**.
`store/moveStock.js:167-183` toasts success per response, so a queue of replays all report success.

**Re-verified against `origin/develop` 2026-08-20 (a stale local `develop` gave the wrong answer
first — it was 8 commits behind).** The two files are in different states:

| File | State on `origin/develop` | Fix D shape |
|---|---|---|
| `components/moveStock/inputAmount.vue` | **byte-identical to v1 pre-fix.** `submit()` awaits `moveStock/selectStockUnit` then advances the wizard to `3_destination`, unguarded — a second CR double-dispatches the selection | v1 hunk applies verbatim |
| `components/moveStock/scanDestination.vue` | **diverged.** SBDEV-2994 (merged, PR #36) rewrote `submit()` as `async` and *did* add a `submitting` flag — but scoped to the `checkContainer` probe only | must be **adapted**, not picked |

The SBDEV-2994 guard does not close this defect, and the way it fails is worth stating precisely:

- it sets `submitting = true` immediately before `await …dispatch('moveStock/checkContainer')` and
  clears it in that `try`'s `finally` — i.e. **the flag is already false again by the time the
  transfer is dispatched**, so a second CR arriving during the transfer is admitted;
- the terminal `dispatch('moveStock/transferStock', data)` is still **not awaited**;
- the `'new'`-mode branch never sets the flag at all;
- the Submit button still carries no `:disabled` / `:loading`.

So the top-of-method `if (this.submitting) return` is real, but it only protects the probe window
SBDEV-2994 itself opened. The transfer — the operation that mints the unit load — is unguarded.

Systemic: **27 of 28** scan components in this repo have no guard.
`components/replenish/process/selectDestination.vue:58` (`:loading="updating"`) is the only fully
guarded one in either mobile UI.

### Bug E — a new unit load per request

`service/StockunitService.java:181-195`, existing-container pallet branch:

```java
unitLoad = unitloadService.createUnitload(palletLocation, resolvedDefaultUnitLoadType.getId(),
        stockUnit.getClientId(), WmsConstants.CODE_MANUAL_SPLIT, sourceUnitLoad.getBoxtypeId());
stockunitBusinessService.transferStockToUnitLoad(stockUnit, unitLoad, amountToTransfer, ...);
unitloadBusinessService.transferUnitLoadToCarrier(unitLoad, pallet, ...);
```

Every request mints a fresh child UL and nests it under the scanned pallet. Two requests → two
containers, each holding the moved amount, both attached to the pallet. Quantity is correct; the
container count is not.

### Bug F — the retry helper documents the vulnerable shape

`util/OptimisticLockRetry.java` javadoc:

```java
Stockunit fresh = stockunitRepository.findById(id).orElseThrow();
fresh.setAmount(newAmount);          // newAmount computed OUTSIDE the lambda
```

`newAmount` is a captured value from a pre-lambda read. Re-fetching inside the lambda while reusing a
stale computed value is exactly the v1 defect — the retry will "succeed" and persist a wrong number.
This is the canonical snippet developers copy, so the doc is a live hazard even though no current
call site follows it.

### Bug G/H — no idempotency, and a probable dead duplicate path

`StockUnitController.transferStock:68` takes a raw `Map<String,Object>` with no idempotency key, so
nothing server-side distinguishes a replay from a second legitimate move. Separately,
`MoveStockController.scanDestination:96` → `MobileMoveStockService.selectDestination:234` implements a
**second, near-duplicate** transfer path (its own flowbin/pallet branches, its own `createUnitload`
calls). The mobile store does not call it. Two divergent implementations of the same operation is how
a fix lands on one and misses the other — confirm reachability before fixing E, and delete or
consolidate if dead.

---

## 3. Fix Design

### 3.0 Sequencing — two slices (decided 2026-08-20)

The v2 remainder does **not** need one PR or one tier. Routing on execution risk:

| Slice | Scope | Tier | Repos | Why separable |
|---|---|---|---|---|
| **1** | Fix D (mobile in-flight guard) + Fix F (javadoc) | **T1** | `wms2-mobile-ui`, `wms2-api` | D is one verbatim v1 hunk (`inputAmount.vue`) plus one small adaptation around SBDEV-2994's partial guard (`scanDestination.vue`, §2 Bug D); F is a comment. Kills the actual operator trigger. |
| **2** | Fix E + Fix G (server-side dedupe) | **T2** | `wms2-api`, `wms2-mobile-ui` | Depends on nothing in Slice 1 and is no longer a new subsystem (§3 Fix G). Blast radius is *filter scope*, not storage. |

Slice 2 is **not urgent on v2**: §1's DB verification reconciles 3,828 three ways, so E/G buys
container hygiene, not inventory correctness. Slice 1 is what stops the operator-visible symptom.

### Fix D — in-flight guard (mirror `replenish/process/selectDestination.vue`)

```js
data() { return { scannedValue: null, locationName: null, submitting: false } },
methods: {
  async submit() {
    if (this.submitting) return
    this.submitting = true
    try   { await this.$store.dispatch('moveStock/transferStock', data) }
    finally { this.submitting = false }
  }
}
```
plus `:disabled="submitting"` and `:loading="submitting"` on the Submit button. The `await` matters:
without it `finally` releases the flag before the request returns.

**`inputAmount.vue` — take the v1 hunk verbatim.** It is byte-identical to v1 pre-fix (diffed against
`b95b5e4^`), so the merged v1 commit **`b95b5e4`** (wms-mobile-ui PR #101) applies directly. Keep v1's
shape — a `submit()` guard wrapper delegating to `doSubmit()` — so the two repos stay diffable.

**`scanDestination.vue` — adapt, do not pick.** SBDEV-2994 already rewrote this method
(§2 Bug D), so the v1 hunk conflicts. Guard **the terminal dispatch**, leaving SBDEV-2994's probe
guard and its top-of-method re-entry check in place:

```js
this.submitting = true
try   { await this.$store.dispatch('moveStock/transferStock', data) }
finally { this.submitting = false }
```

plus `:disabled="submitting"` / `:loading="submitting"` on the Submit button.

**Why not hold the flag across the whole method — CORRECTED 2026-08-20 under review.** The original
claim here was that a method-wide flag would leave the `isDamagedDestination` reason pause stuck and
the move impossible to complete. That is **only true of a method-wide flag whose clear sits on the
happy path**. A method-wide flag wrapped in a method-wide `try/finally` was measured **11/11 green**,
reason pause included: the pause's `return` unwinds through the `finally` and releases the flag. It is
a strict superset of the narrow guard and closes the probe→transfer gap by construction.

The real reason to keep the narrow scope is different and smaller: widening requires **unwinding
SBDEV-2994's own probe `try/finally`**, because leaving that inner `finally` in place under a
method-wide flag drops the flag mid-method — strictly worse than either shape. So widening is a
refactor of 2994's guard, not a one-line change, and it is not worth doing in this slice.

What the narrow shape depends on is that the probe→transfer gap stays **await-free**: there is no
`await`, no `$nextTick` and no timer in it, so no scanner event can interleave. Add an await there and
the guard develops a hole. No assertion can pin that — it is structural, and it is stated in the
component comment.

### Fix E — idempotent replay, fail open (**decided 2026-08-20 — Nam**)

Merge-into-existing-UL is **not** pursued (it would change UL granularity and `CODE_MANUAL_SPLIT`
report counts). The endpoint dedupes and **replays the prior result** rather than rejecting.

Full reasoning in the v1 plan Fix E. In short: return the prior outcome, because the likely trigger
is the client's own retry and rejecting turns a succeeded operation into an operator-visible error;
**fail open** when no nonce is present, because the mobile UI deploys separately from the API and
failing closed would brick every un-upgraded handheld on the API deploy; key on a **per-intent
nonce**, never the value tuple, because operators legitimately repeat identical moves.

**v2-specific storage constraint — ALREADY SATISFIED (revised 2026-08-20).** The dedupe record must
be a table row with a UNIQUE constraint written under `tenantTransactionManager`, never an in-JVM
Caffeine map (§7 row 1). **That store already exists**, shipped by SBDEV-2222:

| Piece | Where | Note |
|---|---|---|
| Table | `rest_idempotency` (`db/v1-to-v2-onboarding/schema/V2.1.10__add_rest_idempotency.sql`) | unique on `idempotency_key` |
| Atomic claim | `RestIdempotencyRepository.insertClaimIfAbsent` | native `INSERT … ON CONFLICT (idempotency_key) DO NOTHING`, `@Transactional("tenantTransactionManager")` — replica-safe by construction |
| Claim / replay / conflict | `RestIdempotencyService.tryClaim` → `CLAIMED` / `REPLAYED` / `IN_FLIGHT` / `CONFLICT`, `getCachedResponse`, `persistResponse` | persists 2xx only; on a handler throw it records 500 so the claim row is deleted and a retry is allowed |
| Purge | `RestIdempotencyCleanupJob` | advisory-locked, all tenants, `RETENTION_DAYS = 7`, cron `app.cron.cleanup-rest-idempotency=0 0 2 * * *` |
| Filter | `landlord/config/IdempotencyFilter`, registered at `SecurityConfiguration.java:160` on the single `SecurityFilterChain`, after `BearerTokenAuthenticationFilter` | gated by `app.idempotency.enforce=true` |

So **no new table, no Flyway migration, no TTL sysprop and no new purge job are in scope.** What is
in scope is enrolling the path (Fix G) and the counter: `RestIdempotencyService` has **no Micrometer
instrumentation today** (grep for `Counter`/`meterRegistry` returns nothing), so the duplicate counter
required by §8 row 8 is the only genuinely new backend code in Slice 2.

### Fix F — correct the javadoc

Show the delta recomputed **from the re-fetched instance** inside the lambda, and add an explicit
warning that capturing a computed absolute value defeats `@Version`. Cite SBDEV-3003.

### Fix G — enroll `/v3/stockUnit/transferStock` in the existing `IdempotencyFilter`

A UI flag cannot stop a token-refresh retry, a scanner that beats the flag, or two devices. The
server-side half is therefore still required — but it is a **scope change to an existing filter**,
not a new mechanism.

The mobile UI posts to `/v3/stockUnit/transferStock` (`nuxt.config.js:67` baseURL ends in `/v3`
+ `store/moveStock.js:169`). `IdempotencyFilter.shouldNotFilter:99` returns `true` for anything not
starting with `/rest/`, so the endpoint is simply outside the filter's reach today.

**G.1 — path allowlist.** Extend `shouldNotFilter` with an explicit allowlist of `/v3` mutation paths,
seeded with `/v3/stockUnit/transferStock` only. Allowlist, never a `/v3/**` prefix: the filter drains
and buffers the request body and wraps the response in `ContentCachingResponseWrapper`, which must not
be applied blindly to every `/v3` endpoint (file/export streams above all).

**G.2 — header-required in the new scope (the trap).** When no `Idempotency-Key` header is present the
filter auto-derives the key as `SHA-256(method + "|" + path + "|" + rawBodyBytes)`
(`IdempotencyFilter.java` step A.1/A.4). That is **the value tuple**, which Q1 explicitly forbids —
operators legitimately repeat an identical move, and with `RETENTION_DAYS = 7` a legitimate repeat
would be silently swallowed as a replay for a **week**, reported to the operator as success with
nothing moved. So for the `/v3` scope: **require an explicit header and fail open when it is absent**
— never fall through to the derived key. Fail-open also keeps un-upgraded handhelds working across the
API-before-UI deploy (§4.1).

**G.3 — per-intent nonce in the UI.** `store/moveStock.js` sends `Idempotency-Key` = one nonce minted
per *operator intent* (on entering the destination/amount step), reused across every retry of that
intent and regenerated for the next move. Keying on the intent, never the value tuple, is what makes a
deliberate repeat move distinguishable from a replay.

**G.4 — the client must not render a dedupe as an error.** `store/moveStock.js:179-182` catches any
non-2xx and toasts *"Error: Request failed due to a network or server issue. Please retry."* — which
would turn a successful-then-deduped move into an operator-visible error that invites another retry,
the exact outcome Q1 rejected. The filter can answer a duplicate three ways: `REPLAYED` → the cached
2xx body verbatim (benign, needs no client change — `ResponseEntity.ok(true)` replays as `true`), but
`IN_FLIGHT` → **409** `idempotency-in-flight` and a body-hash mismatch → **409**
`idempotency-key-conflict`. On a genuine double-submit the second request usually arrives *while the
first is still running*, so **409 in-flight is the common path, not replay** — there is no prior result
to replay yet. The store must treat both 409 codes as benign (suppress the error toast; leave the
success/navigation handling to the first request) rather than as a failure.

**Not in scope:** the pre-existing `app.idempotency.require-auth=false` (a trusted-network setting for
un-authenticated OMS callers). `/v3/**` already requires the `wms_user` authority
(`SecurityConfiguration.java:157`), so the new scope is authenticated regardless. Do not touch that
property here.

---

## 4. File Change Summary

**Slice 1 — D + F (T1):**

| Repo | File | Change | Description |
|---|------|--------|-------------|
| mobile-ui | `components/moveStock/scanDestination.vue` | modify | Fix D — **adapted** around SBDEV-2994's partial guard (§2 Bug D), not picked |
| mobile-ui | `components/moveStock/inputAmount.vue` | modify | Fix D — the v1 `b95b5e4` hunk verbatim |
| mobile-ui | `test/components/move-stock-double-submit.spec.js` | new | AC-3 |
| api | `util/OptimisticLockRetry.java` | modify | Fix F (javadoc only) |

**Slice 2 — E + G (T2):**

| Repo | File | Change | Description |
|---|------|--------|-------------|
| api | `landlord/config/IdempotencyFilter.java` | modify | G.1 path allowlist + G.2 header-required/fail-open in the `/v3` scope |
| api | `service/RestIdempotencyService.java` | modify | Micrometer duplicate counter (§8 row 8) — no metrics exist there today |
| api | `service/StockunitService.java` | *no change expected* | Fix E is delivered **by** G, not by touching the pallet branch — merge-into-existing-UL was rejected (Q1), so `:192`'s `createUnitload` stays as-is and simply stops being reached twice |
| api | `controller/StockUnitController.java` | *no change expected* | dedupe lands in the filter, above the controller; keep the endpoint signature and its `Map<String,Object>` body untouched |
| mobile-ui | `store/moveStock.js` | modify | G.3 per-intent nonce header + G.4 benign-409 handling |
| api | `controller/mobile/MoveStockController.java` | comment only | Bug H — Q2 resolved: dead for this flow. Add a deprecation note; delete under a separate cleanup, **not** here |
| api | `test/.../IdempotencyFilterV3ScopeTest.java` | new | AC-1, AC-2, AC-6, AC-7 |
| mobile-ui | `test/.../moveStock.store.spec.js` | new | AC-8 |

### 4.1 Prerequisites

| Item | Status |
|------|--------|
| DB state | No corrupted v2 data found. Run the v1 plan §6 detection query against all v2 tenants to confirm before closing |
| Feature flags | None. Fix G rides the existing `app.idempotency.enforce=true` (already on in every env). **No dedupe-TTL sysprop is needed** — retention is the existing `RestIdempotencyCleanupJob.RETENTION_DAYS = 7`, which is harmless under a per-intent nonce (a nonce is unique per intent, so a long window costs nothing). This supersedes Q4 |
| Deploy order | Slice 1: independent, either order. Slice 2: API (G.1/G.2) before mobile UI (G.3/G.4) — safe because the new scope fails open without a header |
| Data migration | None — `rest_idempotency` already exists on every tenant via `V2.1.10` |
| Access | `wsl-wineco-uat` + `wms2-wineco-dev` MCPs confirmed working |

---

## 5. Testing Plan

- **AC-1** two identical `/transferStock` posts produce **one** destination UL (Fix E/G)
- **AC-2** replay returns the prior result rather than performing a second transfer (Fix G)
- **AC-3** `scanDestination.vue` ignores `submit()` while in flight and re-enables afterwards (Jest)
- **AC-4** `transferStockToUnitLoad` still derives the source amount from the **locked** instance —
  a **regression pin** on v2's existing correct behaviour, so a future refactor cannot reintroduce
  the v1 bug. Mutation-check by replacing `:373`'s operand with a stale reference; must go red.
- **AC-5** `OptimisticLockRetry` javadoc no longer shows a captured absolute value (grep assertion)
- **AC-6** `/v3/stockUnit/transferStock` **with** an `Idempotency-Key` is in the filter's scope; a
  second post with the same key does not reach the handler (Fix G.1)
- **AC-7** the same endpoint **without** the header falls through undeduped — it must **not** be keyed
  on the derived body hash, so two identical no-header posts both reach the handler (Fix G.2, the
  fail-open + no-value-tuple contract). Mutation-check by removing the header-required branch: this
  row must go red.
- **AC-8** the store suppresses the error toast for a 409 `idempotency-in-flight` /
  `idempotency-key-conflict` and still toasts on a real failure (Fix G.4, Jest)

AC-1…AC-3 and AC-5 belong to Slice 1's and Slice 2's respective PRs; AC-4 and P1–P3 are regression
pins that ride whichever PR lands first.

**Mutation-check every assertion (floor item 3).** AC-4 is the important one: it will pass on today's
code, so without an observed red it is worthless.

### Lane constraints

- v2 IT harness is broken (SBDEV-2217, Testcontainers Postgres cannot boot). **Gate on unit tests +
  `mvn clean compile`**; leave new ITs `@Disabled` with the ticket cited.
- Controller tests must extend `BaseControllerTest`. Remember `standaloneSetup` cannot see the class
  `/v3` prefix, so a mapping test passing does not prove the route resolves — confirm with curl.
- `wms2-mobile-ui` has a Jest suite (nvm node + `node_modules/.bin/jest`; no yarn on PATH).
- `mvn test` mutates the tracked `archunit_store` — revert it. Compare against the 2 known
  pre-existing failures on clean `develop`, not against zero.

### Manual test plan

| Scenario | Env | Steps | Expected |
|---|---|---|---|
| M1 double-tap | v2 DEV (`dev_wh01_om1`) | Move N of a test SKU onto a pallet at a transfer lane; tap Submit twice | one child UL; totals unchanged |
| M2 scanner double-fire | v2 DEV | Same via handheld with trailing CR | as M1 |
| M3 reconciliation | v2 DEV + UAT | v1 plan §6 query before/after | zero drift both times |

---

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Fix E changes UL granularity | Reports counting ULs / `MANUAL_SPLIT` shift | Resolved — Q1 chose dedupe, so `StockunitService:192` is not touched at all |
| In-memory dedupe cache | Ineffective across replicas — a replay hitting replica B passes | Moot: the reused store is `rest_idempotency` + `ON CONFLICT`, replica-safe by construction. **Do not introduce a Caffeine shortcut** |
| **Deriving the key from the body hash** | A legitimate repeat move is silently swallowed for 7 days and reported as success | **G.2 — header-required, fail open.** AC-7 pins it and is mutation-checked; this is the single most dangerous way to get Slice 2 wrong |
| Widening the filter to `/v3/**` instead of an allowlist | The filter buffers bodies and wraps responses — would break export/stream endpoints | G.1 allowlists one exact path |
| 409 rendered as a network error | Operator retries a move that already succeeded | G.4 + AC-8 |
| Deleting `MoveStockController.scanDestination` while still reachable | Breaks an unknown caller | Confirm via access logs / grep of both UIs before deleting; default to leaving it and adding a deprecation note |
| UI-only fix ships without G | Defect persists under axios retry | Deploy order: API first |

---

## 7. Horizontal Scalability Validation

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | **In-JVM state** | **No — resolved by reuse** | Fix G's dedupe store is `rest_idempotency` + `insertClaimIfAbsent`'s `ON CONFLICT (idempotency_key) DO NOTHING`, which is atomic across replicas by construction. This row was the main scalability risk in this plan; enrolling the existing filter retires it. The residual rule is negative: **do not** add a local Caffeine map as a fast path |
| 2 | Connection pool math | No | No new per-request connections |
| 3 | Scheduled jobs | N/A | None added |
| 4 | Long transactions | No | Fix E shortens work if anything; no external I/O inside the tx |
| 5 | Request affinity | **Yes — satisfied** | The nonce is validated against a tenant DB row, not JVM state, so a retry landing on another replica is handled. A replica that loses the claim race gets `IN_FLIGHT` → 409, which G.4 makes benign |
| 6 | Retry / idempotency | **Yes — satisfied** | The point of Fix G. Note `plugins/axios.js:35` retries **only** on 401/403 for token refresh, so the client-side retry exposure is narrower than first assumed — but a post-refresh replay is exactly the case the UI flag cannot catch |
| 7 | Tenant context | No | No `@Async` / `CompletableFuture` added; dedupe key must be tenant-scoped |
| 8 | Distributed lock correctness | No | Reuses the existing `findByIdForUpdate` inside `tenantTransactionManager`; no new locks |
| 9 | Cache invalidation | No | `Stockunit` is not `@Cacheable` |
| 10 | External notifications | No | No new OMS calls; existing stock-change messaging unchanged |

---

## 8. v2-only constraint checklist

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV disabled | N/A — no new lazy-load path; all repo calls stay inside `@Transactional` |
| 2 | `tenantTransactionManager` | **Yes** — any new dedupe write must declare it (`StockunitService:154` is the precedent) |
| 3 | `readOnly=true` on reads | N/A — no new read-only service methods |
| 4 | Caffeine invalidation | N/A — `Stockunit` / `Unitload` are not cached |
| 5 | Jakarta namespace | **Yes** — do not copy `javax.*` imports when porting the v1 fix shape back and forth |
| 6 | H2-compatible test SQL | **N/A now** — no new DDL, `rest_idempotency` already exists. But `insertClaimIfAbsent` is a native `ON CONFLICT` query and is **not H2-portable**, so AC-6/AC-7 must mock `RestIdempotencyService` rather than hit a DB (or land as a `@Disabled` IT citing SBDEV-2217) |
| 7 | `BaseControllerTest` | **Yes** — `StockUnitController` changes require it |
| 8 | Micrometer metrics | **Yes** — `RestIdempotencyService` has **zero** Micrometer instrumentation today, so the duplicate counter is genuinely new code. Tag by outcome (`replayed` / `in_flight` / `conflict`) and by path: it is the only way to see how often this fires in prd, and the only way to tell a real double-submit from a nonce bug |

---

## 9. Acceptance

Shared verify script:
`sbdocs/9-System/scripts/verify-SBDEV-3003-move-stock-lost-update-inventory-inflation.sh`.
Requires `Result: N pass, 0 fail`, AC-1…AC-5 green and each mutation-checked.

**Baseline captured 2026-08-20: `Result: 3 pass, 25 fail, 3 skip`** (31 rows, `SKIP_MVN=1`). See
the v1 plan §9 for the full negative-test evidence, the two `file_contains_ml` bugs the run exposed,
and the rows deleted after the v1 design reversal.

**v2 is unaffected by that reversal** — the reversal was about not *adding* a lock to v1. v2 already
locks, correctly, so P2 keeps its `findByIdForUpdate` assertion while the equivalent v1 rows were
deleted. Fixes D/E/F/G here are unchanged.

v2-specific rows and their measured behaviour:

| Row | Asserts | Baseline | Validated by |
|---|---|---|---|
| ~~E1~~ | ~~pallet branch no longer mints a UL per request~~ | FAIL | **DELETE this row.** Q1 rejected merge-into-existing-UL, so `StockunitService:192` is deliberately unchanged; the row asserts a fix that is no longer the design and can never legitimately go green |
| G1 | `IdempotencyFilter` scope includes `/v3/stockUnit/transferStock` | FAIL | — |
| G1b | the `/v3` scope requires an explicit header and does **not** fall back to the derived key | FAIL | — |
| G2 | duplicate-transfer counter exists (§8 row 8) | FAIL | — |
| G3 | `store/moveStock.js` sends `Idempotency-Key` and suppresses the 409 error toast | FAIL | — |
| F1–F3 | `OptimisticLockRetry` javadoc corrected | FAIL | — |
| D1–D1d | `scanDestination.vue` in-flight guard | FAIL | patched shadow → all green |
| **P1** | source arithmetic uses the **locked** instance | **PASS** | mutation → **red** ✓ |
| **P2** | source fetched `FOR UPDATE` | **PASS** | mutation → stays green (independent axis) ✓ |
| **P3** | no stale-operand subtract anywhere in v2 | **PASS** | mutation → **red** ✓ |

P1–P3 are the regression pins that stop a future refactor from reintroducing the v1 defect into v2.

**CORRECTED 2026-08-20 — the previous claim here was false.** This section used to say the pins
"were mutation-checked by textually reinstating the v1 stale operand at `:373`; P1 and P3 both went
red". Re-measured with a *realistic* reinstatement —
`sourceStockunit.setAmount(callerSnapshot.getAmount().subtract(amount))` — **P1 went red and P3
stayed GREEN**: the old P3 pattern forbade one hard-coded variable name, `staleStockUnit`, which does
not occur at `:373` at all (it is a parameter name in `changeAmount` / `changeReservedAmount`). The
mutation originally run had been shaped to the row rather than to the defect, so the most important
regression pin in this plan would have sat green through a reintroduction of the exact v1 bug.

P3 now reuses A1's name-agnostic shape (any `setAmount` whose operand object differs from its
receiver), routed through the perl helper. Re-measured: **clean on unmutated v2 SBS, red on the
mutant.** P2 legitimately holds under that mutation — it pins the lock, an independent axis.

---

### 9.1 Slice 1 implementation record (2026-08-20)

| Item | Result |
|---|---|
| Branches | `wms2-mobile-ui` `bugfix/SBDEV-3003-move-stock-double-submit` @ **20d697d**; `wms2-api` `bugfix/SBDEV-3003-optimistic-lock-retry-javadoc` @ **0efea2b** — both off freshly-fetched `origin/develop` (`7f83d55` / `60aef02`). *(Pre-review: 931e38e / d557824, amended away — see the "Commits after review" row.)* **PRs submitted 2026-08-20** — mobile-ui **#39**, api **#175**, both into `develop`, independent (no stacking) |
| Fix D shape | `scanDestination.vue` adapted around SBDEV-2994's partial guard; `inputAmount.vue` took the v1 hunk verbatim |
| Fix F | javadoc corrected, counter-example variable named `capturedAmount` so verify row F1's `file_not_contains` on `fresh.setAmount(newAmount)` is not tripped by the WRONG example itself |
| Tests | 12 new Jest cases in `test/components/move-stock-double-submit.spec.js`; **8 measured red / 4 green** against pre-fix components |
| Mutation checks | The 4 pre-fix greens are each labelled `[pin: vacuous pre-fix]` and **measured red** under mutation: never clearing the flag; clearing after the `await` instead of in `finally`; and a method-wide flag whose clear sits only on the happy path |
| Full suite | mobile-ui **168 pass / 11 suites**, against a measured `origin/develop` baseline of **156 pass / 10 suites**, both fully green — delta is exactly the new suite |
| Review | **Two independent lanes** — full records: [[reviews/SBDEV-3003-review-mobile]] · [[reviews/SBDEV-3003-review-api-verify]] (consolidated 2026-08-20; the verbatim transcripts were not persisted at the time). *Mobile:* behaviour correct, no interleaving admits a second dispatch — proven by nine mutants including a control that reverts only the 3003 guard while leaving SBDEV-2994's probe guard intact. 1 Medium + 6 Low/Nit, all documentation/test-quality; F1–F4 applied, F5–F7 accepted. *API + verify script:* javadoc claim verified true (`AbstractBaseEntity:33` really does carry `@Version`), references all resolve, exemplar genuinely exemplary, `javadoc -Xdoclint:all` clean; but **3 High on the script** and 3 Medium on the javadoc — all applied |
| Commits after review | mobile **20d697d**, api **0efea2b** (both amended; the pre-review shas 931e38e / d557824 are superseded) |
| Compile | `mvn clean compile` on wms2-api: **BUILD SUCCESS** |
| Verify | **35 pass, 4 fail, 3 skip** (`SKIP_MVN=1`). The 4 fails are G1/G1b/G2/G3 — all Slice 2 |
| Negative test | Re-run with `V2_API` and `V2_UI` pointed at `origin/develop`: **24 pass, 15 fail**. Every row claimed green for Slice 1 (D1c, D1d, D1e, D4–D4d, F1–F3, T3) was confirmed **red** there |
| Outstanding | **PR review + merge only.** Floor item 4 (independent review, not self-approvable) is satisfied by the review row above, and both lane records are now persisted under `reviews/`. Both branches pushed to origin 2026-08-20 |

**The script's three High findings were the serious result of this review, and all three were
independently re-measured before being accepted.** Two of them mean evidence cited earlier in this
plan was worth less than claimed:

| Row | Was | Measured | Now |
|---|---|---|---|
| **F2** | `(?i)(recomput\|derive)[^\n]*(re-?fetch\|fresh\|locked)` | **FALSE GREEN.** Deleting the *entire* "necessary but not sufficient" paragraph **and** the whole WRONG counter-example left F2 **green** — an incidental phrase in the example satisfied it. The row that certifies Fix F graded the right file for the wrong reason | Requires captured/pre-computed + `absolute` + `@Version`. Re-measured **red** on that same gutted file |
| **P3** | `file_not_contains 'setAmount\(\s*staleStockUnit\.…'` | **VACUOUS** — see §9 above | A1's name-agnostic pattern; **red** on the realistic mutant |
| **G1b** | three prose fragments joined by unbounded lazy gaps | **Graded English, and broke both ways**: one comment turned it green with `shouldNotFilter()` untouched, while a correct implementation writing "fails open" instead of "fail open" went red | Asserts the code shape (auto-derive gated on the `/v3` scope). Still red until Slice 2 — **re-measure it against a deliberately-wrong build before trusting it** |

Also corrected: **G2** was a tree-wide substring grep satisfied by a comment (`// TODO
duplicateTransfer counter`) while asserting nothing about a registered counter — and per §8 row 8
that counter is the only genuinely new backend code in Slice 2, so it had the weakest guard in the
file. **G3**'s unbounded gap over a 7 KB store could not tell "suppresses the toast for a dedupe 409"
from "logs the 409". **D1e/D2e** would have false-redded a correct implementation that wraps the
transfer in `try/catch/finally` — the same shape this very file already uses for the probe. **A2/P1**
passed `\1` backreferences to `grep -E`, a GNU extension that BSD/macOS grep and ugrep reject
outright; harmless as invoked here, but P1 is a regression pin, so a portability red would have read
as "the v1 defect is back". Both routed through the perl helper. The closing reminder named the
deleted `B*`/`E*` families and asserted all `D*` rows must be red pre-fix, which contradicts the
measured vacuity of D1/D1b on v2.

**Five verify rows were wrong and were corrected; each is annotated in the script.** Recording them
because four of the five failed in the direction that hides work rather than the direction that
blocks it:

| Row | Was | Why it was wrong |
|---|---|---|
| D1b | required `if (this.submitting) return` on one line | v2's guard is a braced block (SBDEV-2994), so a real guard read as FAIL. The tempting "fix" was to reformat the component to satisfy a regex |
| **D1d** | `file_contains 'await this.$store.dispatch'` | **False GREEN.** SBDEV-2994's probe await satisfied it, so the row could not tell "the probe is guarded" from "the transfer is guarded" — the whole point of this ticket. Narrowed to name `moveStock/transferStock`, and D1e added to assert the `try`/`finally` wrapping |
| T3 | `find test -iname "scanDestination*"` | A filename assertion, satisfiable by an empty file, and red even against SBDEV-2994's real coverage. Now asserts a spec that imports the component **and** exercises the flag |
| E1 | pallet branch stops minting a UL per request | Asserted the design Q1 **rejected**; could never legitimately go green. **Deleted** |
| G1 | grep `StockUnitController` for `idempotenc` | Points at the wrong file under the revised design — satisfiable only by writing code in the wrong place. Retargeted to `IdempotencyFilter`, and G1b/G3 added |

Rows **D4–D4d / D5–D5d were added**: the script asserted `scanDestination.vue` only, so a
half-applied Fix D — guard on one screen, not the other — would have passed clean.

Two quoting traps hit while writing rows, both of which produce a permanently-red row that is
indistinguishable from unfinished work: a **double-quoted** bash pattern turns `\$store` into `$store`,
which ERE reads as an end-of-line anchor that can never match; and an adjacency regex spanning
`submitting = true` → `try {` fails on v1, where a comment sits between the two lines. Single-quote
every pattern, and tolerate `//` comment lines inside adjacency gaps.

---

## 10. Open Questions

- **Q1 — RESOLVED 2026-08-20 (Nam): dedupe, fail open, replay the prior result.** Keyed on a
  per-intent nonce (Fix E).
- **Q2 — RESOLVED 2026-08-20 by inspection: `/moveStock/scanDestination` is DEAD for this flow.**
  `store/moveStock.js:136` defines the action but **no component dispatches it**;
  `components/moveStock/scanDestination.vue:126` dispatches `moveStock/transferStock` →
  `/stockUnit/transferStock`. Verified by grep across `components/` and `pages/` in both UIs — the
  same holds in v1. Fix E lands on `StockUnitController` only.
  `MobileMoveStockService.selectDestination:234` stays as a near-duplicate transfer implementation:
  add a deprecation note now, delete under a separate cleanup, **not** in this PR.
- **Q3.** Roll Fix D across all 27 unguarded scan components now, or Move Stock only? Recommend
  **Move Stock now**. *(Proceeding on the recommendation — scope choice, not a contract change.)*
- **Q4 — SUPERSEDED 2026-08-20.** Was "TTL 24 h with a scheduled purge". Both already exist and are
  not ours to set: `RestIdempotencyCleanupJob` purges on `app.cron.cleanup-rest-idempotency`
  (02:00 daily, advisory-locked, all tenants) at `RETENTION_DAYS = 7`. Under a per-intent nonce the
  longer window is harmless, so **no new TTL and no sysprop.** The 7-day window is only dangerous
  under a body-derived key — see §3 Fix G.2.

**Blocking questions: none.** Q1, Q2 and Q4 are decided; Q3 proceeds on the stated recommendation
(Move Stock components only this round).

### Retry-lambda audit (contrast with v1)

v2 has exactly **one** `executeWithRetry` call site and it is **correct** —
`MobilePalletizingService.java:265-273` captures only `orderId`, re-fetches `freshOrder` **inside**
the lambda, re-checks the state guard against the fresh instance, and saves that instance. Use it as
the reference for the v1 Fix H.

v1, by contrast, has 10 sites of which **3 pass a `Stockunit` entity through the retry boundary**
(`StockUnitController:97/355/392`) — including the Move Stock path in this ticket. That is v1 plan
rows K1–K3 / Fix H, and it is why the v1 retry mechanism can amplify Bug A instead of surviving it.
**No v2 counterpart is needed.**

---

## 11. Notes / Observations

- **Slice 1 landed 2026-08-20.** See §9.1 for branches, evidence and the five verify-row
  corrections. Not yet reviewed and not yet PR'd.
- **REVISED 2026-08-20 after a v2 code survey — two findings changed the shape of the work.**
  1. **Fix D is mostly a port, but only mostly.** `inputAmount.vue` is byte-identical to v1 pre-fix
     and takes `b95b5e4` verbatim; `scanDestination.vue` diverged on `origin/develop` via SBDEV-2994
     and needs a small adaptation. **The first pass got this wrong by diffing a local `develop` that
     was 8 commits stale**, which is the SBDEV-2781 landmine repeating: `git fetch` and diff
     `develop..origin/develop` **per repo** before claiming any file is unchanged. The stale answer
     was the more attractive one (a free cherry-pick), which is exactly why it needed checking.
  2. **Fix E/G's storage already exists.** SBDEV-2222 shipped `rest_idempotency`,
     `RestIdempotencyService`, an advisory-locked cleanup job and a registered `IdempotencyFilter`;
     the endpoint is out of reach only because `shouldNotFilter` self-limits to `/rest/**`. The
     original §3/§4.1/§7/§8 text specified building all of that from scratch — a new table, a Flyway
     migration, a TTL sysprop, a purge job, and a warning about a Caffeine map that was never going
     to be written. Those sections are corrected above; the work drops from T3 to T2.
  The new hazard introduced by the reuse is the filter's default **body-hash-derived key**, which is
  the value tuple Q1 forbids. G.2 and AC-7 exist solely to hold that line.
- **Reviewed 2026-08-20 — 1 of 4 lanes delivered.** The review reversed the *v1* design (no
  pessimistic lock); **v2's fixes D/E/F/G are unchanged**, because the reversal was about not
  *adding* a lock to v1, not about removing v2's. v2's existing lock at `:208-214` is correct and is
  now pinned by P1–P3. Full review outcome and its gaps: v1 plan §11.
- **v2 is the reference implementation for the v1 fix.** `:208-214` (detach-free
  `findByIdForUpdate` + `entityManager.refresh`) and `:373` (arithmetic on the locked instance) are
  what the v1 plan ports. Keep them in sync; AC-4 pins them.
- **The WMS↔OMS gap (4,550 vs 2,629) is a separate issue** and is *not* explained by v2 code — v2
  reconciles exactly. The status-blind outbox dispatcher is the likelier cause of OMS running low.
  Recorded, not filed; ticket cap is one per fix.
- **The `/rest/**` idempotency scope is a broader gap than this ticket.** Every mobile mutation
  endpoint is outside the filter — Move Stock is the one with a reported incident, not the only one
  exposed. Recorded here, **not filed**: the ticket cap for this fix is one, and a general
  "enroll `/v3` mutations in the idempotency filter" effort needs its own owner and schedule.
- **Ticket metadata is wrong in a way worth fixing.** The title says *WMSv1 Mobile Move Stock*, which
  is right for the inflation and wrong for the duplicate-UL half. Suggest retitling to name both
  versions and correcting the tags, so the v2 work is not invisible on the board.
