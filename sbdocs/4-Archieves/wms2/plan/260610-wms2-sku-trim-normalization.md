---
title: "WMS2 SKU Trim Normalization — stop trailing-space duplicate SKUs (FreeScout #959)"
ticket: ""
ticket_url: ""
type: "bugfix-feature"
priority: "medium"
status: "archived"
pr: "https://github.com/SiteBossInc/wms2-api/pull/44"
commit: "d1a224d7795f9e6de62e28a1116d3ad43248a573"
project: ["wms2-api"]
version: "v2"
requester: "Nam Park"
assignee: "Nam Park"
created: "2026-06-10"
updated: "2026-07-15"
db_verified: true
db_verified_note: >
  Verified on both dev tenant DBs 2026-06-10 (queries + results in §2.3).
  wineco-dev2: 10,369 itemdata rows — 3 untrimmed item_nr (no post-trim collisions),
  1,839 untrimmed name. hydra-dev2: 2,720 rows — 1 untrimmed item_nr which COLLIDES
  with an existing trimmed row (BONMFPN23 pair, ids 1919451/1927641 — a live #959
  duplicate; both rows currently have zero stock/order/advice references), 174
  untrimmed name.
related:
  - "[[SBDEV-2235-sku-rest-partial-batch-atomicity]]"
tags:
  - plan
  - wms2
  - sku-sync
  - data-quality
---

# WMS2 SKU Trim Normalization — stop trailing-space duplicate SKUs

**Source:** closed [PR #14](https://github.com/SiteBossInc/wms2-api/pull/14) (FreeScout #959) — diagnosis credited; implementation superseded by SBDEV-2235 and re-planned here on the current architecture.
**Scope split (binding):** this plan covers ONLY the trim normalization + data cleanup (WMS-only). The closed PR's other half — `item_id` 1:1 OMS↔WMS contract + removing upsert-on-update — requires a coordinated OMS+WMS ticket pair and is explicitly OUT of scope (§10).
**Authoring note:** drafted directly from completed inline analysis (DB-verified, sites enumerated by grep); Architect + Critic consensus review run before saving, per ralplan discipline.

> **Archived 2026-07-15 — code merged to `develop`.** Phase 1 + Phase 1b trims are on `origin/develop` via wms2-api [PR #44](https://github.com/SiteBossInc/wms2-api/pull/44) (squash-merged 2026-06-12; the write/lookup trim and the `loadItemDataSet` skuSet trim at `ItemdataService.java:56`/`:86` are both present on develop). The only remaining work is the **Phase 2 operational per-tenant data cleanup**, which is NOT code and is tracked by the runbook [wms2-sku-trim-data-cleanup](../../../2-Areas/runbooks/wms2-sku-trim-data-cleanup.md) (hydra `BONMFPN23` duplicate pair + Phase 1b deploy sequencing). Archiving the code plan does not orphan that follow-up.

---

## §0 Affected Sites

| # | File:line | Construct | In scope? | Phase |
|---|---|---|---|---|
| 1 | `service/SkuBatchCreateUpdateService.java:49-50` | `setItemNr(sku.getSku())` / `setName(sku.getSkuName())` on create; update branch mutates same fields | **yes** — consumes normalized DTO (no change here; normalization upstream) | 1 |
| 2 | `controller/rest/SkuRestController.java` create/update/delete validation phases | reads `sku.getSku()`/`getSkuName()` for null-checks + `findByClientIdAndItemNr` lookups | **yes** — normalize DTO at entry of all three endpoints | 1 |
| 3 | `service/ItemdataService.java:53-54` | `findByClientIdAndItemNr(clientId, itemNr)` — single choke point for all item-number lookups | **yes** — trim the `itemNr` argument before delegating | 1 |
| 4 | `controller/FileImportController.java:344,361-362` | sku file import: lookup + `setItemNr`/`setName` | **yes** — trim `skuDto.getSkuNumber()`/`getSkuName()` at entry | 1 |
| 5 | All `ItemdataService.findByClientIdAndItemNr` callers — **16 sites / 9 files** (independently grep-verified 2026-06-10 after Architect AND Critic each miscounted once): `SkuRestController:117,231,325`, `FileImportController:344,419`, `ItemDataController:191`, `StockCountRestController:81`, `ReplenishorderService:86`, `TransactionReportRestController:207`, `AdviceRestController:234,377`, `MobileReplenishService:375,592,701`, `ReceivingService:224,276` | inbound item-number lookups | **covered transitively** by site 3 (choke point) — no per-caller change | — |
| 6 | **Second lookup boundary (Architect finding):** `ItemdataRepository.findByClientNumberAndSkuSet:42` (exact `item_nr IN (:skuSet)`) via `ItemdataService.loadItemDataSet:80` (exact `.equals` at :88, throws `BusinessException` at :94) | order-resolution SKU set lookup | **yes — Phase 1b**: trim `skuSet` elements in `loadItemDataSet`; deploys only AFTER the tenant's Phase 2 cleanup (§5 sequencing rationale) | 1b |
| 6b | `OrderRestController:389` | calls `findByClientNumberAndSkuSet` directly, bypassing the service | **carve-out, documented**: residual raw caller; routing it through `loadItemDataSet` is a separate refactor — orders carry the same spacing OMS sent at SKU sync, so post-cleanup risk is negligible | — |
| 7 | tenant DBs: `itemdata.item_nr`, `itemdata.name` | existing untrimmed rows (incl. one live duplicate pair on hydra) | **yes** — Phase 2 cleanup runbook | 2 |
| 8 | `repo/jpa/ItemdataRepository.java:27-28` | derived query (exact match) | no — unchanged; tolerance achieved via trimmed inputs + cleaned data |
| 9 | Closed PR #14's `item_id` / no-upsert changes | OMS↔WMS contract change | **no — deferred** (§10): one-sided merge is dead-or-breaking; needs OMS ticket |

## §1 Problem Statement

OMS and WMS disagree on SKU identity when values differ only by leading/trailing whitespace (FreeScout #959). WMS's sync path matches SKUs with an exact `findByClientIdAndItemNr` lookup and upserts on miss (`SkuBatchCreateUpdateService.upsertAll` — `if (existing == null) → new Itemdata`), so a padded variant of an existing SKU silently creates a duplicate `itemdata` row. **DB-verified live:** hydra-dev2 has the duplicate pair `[BONMFPN23 ]`/`[BONMFPN23]` (ids 1919451/1927641); name fields are dirty at scale (wineco 1,839 / hydra 174 untrimmed). The REST idempotency layer (SBDEV-2222) does not mitigate — it hashes the raw body, so whitespace variants are distinct requests. Nothing in the codebase trims these fields on any write or lookup path (grep-verified).

## §2 Current Architecture

### 2.1 Write paths (2)
- **OMS sync:** `SkuRestController.create/update` → two-phase (SBDEV-2235): validation loop resolves lookups, then `SkuBatchCreateUpdateService.upsertAll(...)` (`@Transactional(tenantTransactionManager)`, atomic batch) writes `item_nr`/`name` verbatim from the DTO (`:49-50`).
- **File import:** `FileImportController.importSkus:344` exact lookup → `:361-362` writes verbatim.

### 2.2 Lookup choke point
`ItemdataService.findByClientIdAndItemNr` (`:52-55`) delegates to the derived exact-match query; **16 call sites across 9 files** (§0 row 5, independently grep-verified) including receiving advices, mobile replenish, and stock-count reconciliation — all inherit whitespace sensitivity from it. A **second** exact-match boundary exists: `findByClientNumberAndSkuSet` via `loadItemDataSet` (§0 row 6).

### 2.3 Data shape (DB-verified 2026-06-10, dev)
```sql
SELECT count(*) FILTER (WHERE item_nr <> trim(item_nr)) AS itemnr_untrimmed,
       count(*) FILTER (WHERE name    <> trim(name))    AS name_untrimmed
FROM itemdata;
-- wineco-dev2: 3 / 1839 of 10369 · hydra-dev2: 1 / 174 of 2720
```
Collision probe (per-client join of untrimmed → trimmed): wineco 0 collisions; hydra 1 pair (`BONMFPN23`, both rows zero stock/order/advice references on dev — production counts must be re-checked at rollout).

## §3 Design

**Principle: normalize once at each boundary, not at every consumer.** Leading/trailing whitespace only; interior whitespace untouched.

### 3.1 Write-boundary normalization (Phase 1)
Add a private normalizer in `SkuRestController` applied to each DTO at the top of `create`, `update`, and `delete` validation loops (before null/empty checks, so a `" "` SKU correctly fails FIELD_NOT_SET):
```java
private static void normalize(SkuDto sku) {
    if (sku.getSku() != null) sku.setSku(sku.getSku().trim());
    if (sku.getSkuName() != null) sku.setSkuName(sku.getSkuName().trim());
}
```
Separately (different DTO type — do NOT reuse the `SkuDto` helper): in `FileImportController.importSkus`, trim `SkuUploadDto.getSkuNumber()`/`getSkuName()` at loop entry (`:344` lookup and `:361-362`/`:369` direct `itemdataRepository.save` both consume them; this path never goes through `upsertAll`). `ItemDataController` needs NO edit: its save path (`setPutAwayLocation:91`) never writes `item_nr`/`name` from input, and its read lookup (`itemdataDetailsByNumberAndClientNumber:191`) is covered transitively by the §3.2 choke-point trim. `upsertAll` itself stays unchanged — it consumes already-normalized DTOs (single normalization point per request, no double-trim concerns).

### 3.2 Lookup choke-point trim (Phase 1)
`ItemdataService.findByClientIdAndItemNr:53` trims its `itemNr` argument (null-safe) before delegating. All `findByClientIdAndItemNr` callers (~16 sites) gain tolerant matching with one change; the `loadItemDataSet` set-lookup boundary is handled separately in §3.2b. The repository derived query is untouched.

### 3.2b Second lookup boundary — `loadItemDataSet` (Phase 1b, sequenced AFTER Phase 2)
`ItemdataService.loadItemDataSet:80` + `findByClientNumberAndSkuSet` is an exact-match `IN`-set lookup on `item_nr` (order resolution). Trim the `skuSet` elements (and the `.equals` comparison input at `:88`). **Sequencing constraint (Architect):** on a tenant with an uncleaned duplicate pair, a trimmed set-lookup could silently resolve to the WRONG row — it trades "fails loudly with BusinessException" for "succeeds against possibly-wrong row." Therefore Phase 1b deploys only after that tenant's Phase 2 cleanup. `OrderRestController:389` calls the repository directly and is a documented carve-out (§0 row 6b).

### 3.3 Data cleanup (Phase 2 — runbook, per tenant DB)
1. **Discovery:** the §2.3 count + collision queries; record output.
2. **Collision pairs** (e.g., hydra `BONMFPN23`): run the reference query (stockunit count/sum, customerorder_position, adviceposition per id). If the padded row has zero references → delete it (or set inactive if a soft-delete flag exists — confirm at runbook execution). If referenced → manual merge decision (re-point references), expected rare.
3. **Trivial trims:** `UPDATE itemdata SET item_nr = trim(item_nr) WHERE item_nr <> trim(item_nr);` and same for `name` — only AFTER step 2 clears collisions. Wrap in a transaction; capture before/after counts.
4. Order matters: see the §5 Phase 1b choreography — that ordering is authoritative. Running Phase 1 alone against dirty data makes padded *stored* rows unreachable by trimmed lookups (the pre-existing failure mode, not a new one — cleanup closes it); Phase 1b additionally must not precede collision resolution on affected tenants.

**No new sysprops, no schema change, no Flyway migration** (cleanup is operational SQL via the runbook, consistent with how tenant data fixes are handled; itemdata has no unique index on (client_id, item_nr) today — adding one is listed in §9 as deliberate future hardening, out of scope).

## §4 File Change Summary

| File | Change |
|---|---|
| `controller/rest/SkuRestController.java` | add `normalize(SkuDto)`; call at entry of create/update/delete loops |
| `service/ItemdataService.java` | trim `itemNr` arg in `findByClientIdAndItemNr` (null-safe) |
| `controller/FileImportController.java` | trim `SkuUploadDto` skuNumber/skuName at importSkus entry (distinct DTO — own trim calls, no shared helper) |
| `service/ItemdataService.java` (Phase 1b) | trim `skuSet` elements + `.equals` input in `loadItemDataSet` |
| `unit/controller/rest/SkuRestControllerUnitTest.java` | new tests: padded create matches existing (no duplicate), padded update matches, blank-after-trim fails FIELD_NOT_SET |
| `unit/service/ItemdataServiceUnitTest.java` (or create) | trimmed lookup delegation test |
| `sbdocs/2-Areas/...` runbook (new) | Phase 2 cleanup procedure with the §2.3/§3.3 queries |

## §5 Phased Implementation Plan

### 5.1 Prerequisites
| # | Prerequisite | Status |
|---|---|---|
| 1 | DB state | Phase 2 only: per-tenant backup (or snapshot) before cleanup UPDATEs; collision report run first |
| 2 | Feature flags / sysprops | N/A — unconditional normalization |
| 3 | Deploy order | per the §5 Phase 1b choreography (authoritative): collision census → resolve pairs (if any) → deploy Phase 1+1b → trivial-trim UPDATEs; zero-collision tenants may deploy and clean in any order |
| 4 | External systems | none — OMS unchanged; optional OMS-side trim is a separate nice-to-have ticket |
| 5 | Access | tenant DB write access for the runbook operator |

### Phase 1 — code normalization (LOW risk, ~0.5 day)
Branch `feature/260610-sku-trim-normalization` → changes per §3.1/§3.2 + unit tests. Testing: `mvn test -Dtest=SkuRestControllerUnitTest,ItemdataServiceUnitTest` + `SkuRestControllerIntegrationTest` (Testcontainers) + full `mvn verify` before merge.

### Phase 1b — `loadItemDataSet` trim (LOW risk code, sequencing-gated)
One-line trims in `loadItemDataSet` (`skuSet` elements + the `:88` `.equals` input), shipped in the same PR as Phase 1. **Explicit per-tenant choreography (resolves the §3.2b hazard — one ordering, no executor inference):**
1. Run the §3.3 collision census on the tenant.
2. **Zero collision pairs** (e.g., wineco as of 2026-06-10): deploy Phase 1+1b and run the trivial-trim UPDATEs in any order — there is no duplicate pair to mis-resolve; 1b is immediately safe.
3. **Collision pairs present** (e.g., hydra `BONMFPN23`): resolve the pair(s) per §3.3 step 2 **before** deploying Phase 1+1b to that tenant (or deploy during a maintenance window with order-resolution traffic quiesced, run cleanup, then resume). The trimmed set-lookup must never serve order traffic against an uncleaned duplicate pair.
§0 row 6, §3.2b, §3.3 step 4, and §5.1 prereq 3 all defer to THIS ordering.

### Phase 2 — data cleanup (MEDIUM risk, runbook, per tenant)
**Gate before any UPDATE:** (a) tenant DB backup/snapshot confirmed restorable, (b) production collision census run fresh (§2.3 dev counts are indicative only), (c) collision pairs resolved per §3.3 step 2. Rollback = restore from the snapshot. Then execute §3.3 on each tenant DB (dev → qa → prod), recording outputs in the runbook's execution log. Hydra dev pair: padded row id 1919451 deletable (zero refs as of 2026-06-10 — re-verify at execution).

## §6 Backward Compatibility

| Aspect | Before | After | Impact |
|---|---|---|---|
| `/rest/sku/*` accepted payloads | padded SKU creates/updates a *distinct* item | padded SKU resolves to the trimmed item | intended fix; no contract shape change |
| Response codes/bodies | 204 + status map | unchanged | none (PR #14's 204→200 change NOT adopted) |
| Upsert-on-update | yes | **unchanged** (still upserts) | the no-upsert breaking change is deferred to the OMS-coordinated ticket |
| SKUs with *interior* spaces | matched exactly | matched exactly | unaffected |
| Error shape | 422/400 per SBDEV-2235 | unchanged | none |

**What does NOT change:** repository queries, `upsertAll` atomicity, idempotency behavior, OMS payload schema, response contracts, ItemData cache keys (`facilityCode:clientId:itemNr` — now consistently trimmed). Cache-staleness mechanism (corrected per Architect review): SKU sync writes carry `@CacheEvict(value="itemdata", allEntries=true)` (`SkuRestController:71,:183`) so every sync flushes the whole cache — no stale-key window from writes; the only transient skew is a read cached under an untrimmed key between Phase-1 deploy and Phase-2 cleanup, self-healing on the next sync's full evict.

## §7 Testing Strategy

Unit (named in §4): padded-create-no-duplicate, padded-update-matches, padded-delete-matches, blank-after-trim → FIELD_NOT_SET, lookup-arg-trim, **loadItemDataSet-padded-set-resolves** (padded SKU in the set matches the trimmed row; no spurious `BusinessException` — Phase 1b). Integration: existing `SkuRestControllerIntegrationTest` + one padded-payload case. **Manual test plan:**

| Scenario | Environment | Steps | Expected |
|---|---|---|---|
| Padded re-send from OMS | dev tenant | Send `/rest/sku/update` with `"sku": "BONMFPN23 "` after cleanup | updates existing row; no new itemdata row |
| Receiving with padded advice SKU | dev tenant | advice line with trailing-space SKU | resolves item; no EntityNotFound |
| Cleanup runbook dry-run | hydra-dev2 | run discovery + collision + reference queries | outputs match §2.3 (re-verified at execution) |

### §7b Horizontal Scalability Validation (10 rows)
All N/A-or-OK: no in-JVM state, no pool/tx/lock/job/cache/notification changes — pure input normalization + per-tenant data fix. Only note: itemdata Caffeine/Redis cache keys become consistently trimmed; cross-replica staleness window bounded by the existing 5-min TTL (no action).

### §7c v2 Constraint Checklist
OSIV: no new lazy loads (OK). Tenant TM: no `@Transactional` added/changed (OK). readOnly: untouched (OK). Cache invalidation: `@CacheEvict(allEntries=true)` on sync writes flushes everything; per-key `@CacheEvict`/`@Cacheable` keys align once inputs and rows are trimmed (OK). Micrometer: no new flow (N/A). Jakarta: no new imports (OK). H2 test SQL: none added (OK). BaseControllerTest: SkuRestControllerUnitTest follows existing harness (OK).

## §8 Rollout
Phase 1: branch → PR → develop (standard). Phase 2: runbook execution dev → qa → prod per tenant, immediately after each environment receives Phase 1.

## §9 Alternatives Considered
1. **Trim at every lookup caller** — rejected: 7+ scattered sites, guaranteed future misses; choke point is strictly better.
2. **DB trigger / generated column** — rejected: hides normalization from the application, complicates H2 tests and migrations.
3. **Unique index on `(client_id, trim(item_nr))`** — deferred hardening (would have prevented #959 outright); requires the cleanup to land first and a migration-window plan; candidate follow-up after Phase 2 proves data clean.
4. **Resurrect PR #14 wholesale** — rejected: structurally conflicted with SBDEV-2235, one-sided OMS contract, NPE on null box_id (see PR close-out comment).

## §10 Open Questions / Deferred
- **`item_id` 1:1 contract + no-upsert-on-update** (PR #14's second half): deferred until an OMS-side ticket exists; each half alone is dead code or breaking. Owner: Nam to raise the OMS ticket.
- **OMS-side trim at source**: nice-to-have defense-in-depth; separate small OMS ticket.
- **Production collision census**: §2.3 queries must be re-run per production tenant at Phase 2 execution; dev counts are indicative only.
- **Soft-delete vs hard-delete** for zero-reference duplicate rows: confirm whether `itemdata` has an inactive flag convention at runbook execution.

## Consensus Record (ralplan, 2026-06-10)
| Pass | Verdict |
|---|---|
| Planner | drafted inline from DB-verified analysis (deviation noted in header) |
| Architect | **SOUND-WITH-AMENDMENTS** — verified DTO-instance-sharing, FIELD_NOT_SET ordering, delete path, no-harm trim; found the `findByClientNumberAndSkuSet` second boundary, corrected caller count to ~16/9 files, fixed cache-staleness mechanism, identified the Phase-1b sequencing trap, cleared `ItemDataController` as a non-site. All amendments applied. |
| Critic | Round 1 **ITERATE**: caught the `ItemDataController:191` read lookup both planner and Architect missed, the Phase-1b sequencing contradiction, the missing Phase-1b test/acceptance gate, and the missing Phase-2 backup/census gate. All four changes applied (census independently re-verified: 16 sites / 9 files). Round 2 **APPROVE** (re-verified in file). |

## Acceptance
Verify script: `sbdocs/9-System/scripts/verify-260610-wms2-sku-trim-normalization.sh` (authored with this plan; baseline all-FAIL expected pre-implementation) — positive checks: normalize method exists + called in 3 endpoints, ItemdataService trims the `findByClientIdAndItemNr` arg, `loadItemDataSet` trims `skuSet`/`.equals` input (Phase 1b), FileImportController `SkuUploadDto` trim present; negative: no trim added inside `upsertAll` (single normalization point), no edit in `ItemDataController` (its `:191` lookup is covered transitively); `mvn test` rows for the named suites. Phase 2 acceptance: discovery query returns 0 untrimmed for both columns on each cleaned tenant.

### Baseline verify output (2026-06-10, pre-implementation)

```
verify-260610-wms2-sku-trim-normalization — acceptance checks
  PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api

Phase 1 — normalization
  FAIL  P1-norm       normalize(SkuDto) helper exists in SkuRestController
  FAIL  P1-norm3      normalize() called in create/update/delete loops (>=3)
  FAIL  P1-lookup     findByClientIdAndItemNr trims its itemNr argument
  FAIL  P1-fileimp    importSkus trims SkuUploadDto skuNumber/skuName

Phase 1b — set-lookup boundary (sequencing-gated per plan §5)
  FAIL  P1b-set       loadItemDataSet trims skuSet/.equals input

Negative checks
  PASS  N-upsert      no trim inside upsertAll (single normalization point)
  PASS  N-itemctrl    no edit in ItemDataController (:191 covered transitively)

  SKIP  MVN           targeted suites pass  (set RUN_MVN=1 to execute)

Result: 2 pass, 5 fail, 1 skip
```

### Post-implementation verify output (2026-06-11, commit d1a224d, PR #44)

```
Result: 7 pass, 0 fail, 1 skip   (all Phase 1/1b + negative checks PASS)
```

Test evidence: targeted suites `SkuRestControllerUnitTest` + `ItemdataServiceUnitTest` +
`SkuRestControllerAtomicityIntegrationTest` = **60/60 green**. Full `mvn test`: 4194 run /
4 failures — all 4 reproduced on clean develop with the diff stashed (pre-existing:
`BillofladingUnitTest` date-sensitive shipped-null assert, `RestExceptionHandlerUnitTest`,
`UtilRestControllerUnitTest` ×2); zero regressions from this change. Reviewer: 0 CRITICAL /
0 HIGH (set-collapse test suggestion applied); Architect verification: APPROVED.
Phase 2 acceptance (per-tenant 0-untrimmed discovery) tracked in the runbook
`[[wms2-sku-trim-data-cleanup]]` execution log — not yet executed on any tenant.
