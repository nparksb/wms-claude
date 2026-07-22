---
title: "Location import: stale cached LocationRack reference causes optimistic-lock failure"
ticket: ""
ticket_url: ""
type: "bugfix"
priority: "high"
status: "archived"
project: ["wms2"]
version: "v2"
requester: "UAT incident 2026-07-10 (hydr-nywh)"
created: "2026-07-10"
updated: "2026-07-10"
db_verified: true
related:
  - "260424-WMS_OSIV_Disabled_Audit.md"
tags:
  - plan
---

# Location import: stale cached LocationRack reference causes optimistic-lock failure

**Ticket:** none (untracked — rename to `SBDEV-####-location-import-stale-rack-reference-optimistic-lock.md` if a ticket is assigned)
**Project:** wms2 | **Version:** v2/wms2-api | **Type:** bugfix
**Priority:** high (blocks UAT location onboarding for migrated tenants)
**Status:** archived — merged to develop via PR [wms2-api#64](https://github.com/SiteBossInc/wms2-api/pull/64) (merge commit `c3f64ba`, 2026-07-10)

> **Archive note (2026-07-10):** acceptance script retained at `sbdocs/9-System/scripts/verify-260710-location-import-stale-rack-reference-optimistic-lock.sh` as a permanent regression check. Paired v1 plan stub remains ACTIVE at `sbdocs/1-Projects/wms1/plan/260710-location-import-stale-rack-reference-optimistic-lock.md`.
**Date:** 2026-07-10

> **ralplan skipped** per wms-bugfix-plan exception for mechanical one-liner fixes: Fix A is a single added `rackMap.put(...)` line, Fix B is a single cache-key token swap, Fix C is log-string constant swaps. Analysis was performed by an opus executor pass (protocol §1–§8) and independently spot-verified against the working tree at `9b3f438`.
>
> **Post-hoc review log (2026-07-10):** Architect — **APPROVE-WITH-NOTES** (root cause and all three fixes verified at file:line; Fix B proven semantically identical to the DB-fallback path; residual version-inflation and precise dirty-merge mechanism noted). Critic — **APPROVE-WITH-NOTES** (no critical/major findings; test #2 stub condition tightened, §13.1 claim softened, rollback line and v1-pair stub added). All notes are folded into this document.

> **db_verified: true** (2026-07-10, `nywh-hydra-uat` MCP) — §1.1 SQL executed against the hydr-nywh UAT tenant DB. The row-level evidence (id allocation, `version=2`, and `created`/`modified` timestamps aligning with the request log to the millisecond) confirms the stale-cache mechanism; the *driver* of row 1's dirty merge is inferred from the mappings, not measured (§1.1). See §1.1 for results.

---

## 0. Affected sites (enumeration before drafting)

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| A | `controller/FileImportController.java:252-256` | `else { rack.setRackrowId(...); rack = locationRackRepository.save(rack); }` — re-saves a rack fetched/cached in a prior per-row transaction; `rackMap` never refreshed with the version-bumped instance | **yes — primary** | **yes (Fix A)** |
| B | `controller/FileImportController.java:215` | `rackRowMap.get(locationDto.getRackName())` — GET keyed by rack name, but PUTs (:221, :234) are keyed by rack-row name → cache never hits | yes — adjacent cache defect | **yes (Fix B)** |
| C | `controller/FileImportController.java:149` (importLocations) and `:312` (importSkus) | `LOG.info("import inbound bol called with {}", ...)` — copy-pasted from importInboundBols (:401, the only correct use) | no — cosmetic, but it misdirected this incident's triage | **yes (Fix C)** |
| D | `FileImportController.java:177-197` (`areaMap`, `storageLocationTypeMap`) | cached `LocationArea`/`LocationType` across per-row transactions | no — read-only (`.getId()` only), never re-saved, cannot go stale-and-merge | no |
| E | `FileImportController.java` importClients / importSkus / importInboundBols loops | other import loops | no — each saves only newly-constructed entities; none re-saves a fetched existing entity held across rows | no |
| F | v1 `wms-api/controller/FileImportController.java:200` (wrong key) and `:239-243` (un-refreshed re-save) | identical pattern in v1 | yes | **no — paired v1 plan** (see §4) |

Every in-scope row (A, B, C) is covered in §5 Fix Design; excluded rows carry rationale above.

---

## 1. Problem Statement

On UAT (release branch, migrated/hydra-seeded tenant `hydr-nywh`), an admin uploading locations via **Admin → SystemManagement → Import Data** gets the generic UI error *"Error: Request failed due to a network or server issue. Please retry."* and the whole 225-row upload is aborted.

Server log:

```
12:49:38.183 INFO  n.a.w.c.FileImportController - [hydr-nywh][] import inbound bol called with 225
12:49:38.190 DEBUG ... create 0/LocationUploadDto{locationName='1V8L1C1', ..., rackName='V8', rackRowName='1', ...}
12:49:38.321 DEBUG ... create 1/LocationUploadDto{locationName='1V8L1C2', ..., rackName='V8', rackRowName='1', ...}
12:49:38.336 DEBUG ... create 2/LocationUploadDto{locationName='1V8L1C3', ..., rackName='V8', rackRowName='1', ...}
12:49:38.352 WARN  n.a.w.e.RestExceptionHandler - [hydr-nywh][] Optimistic lock conflict: Row was updated or
              deleted by another transaction (or unsaved-value mapping was incorrect): [net.aim_ai.wms.model.LocationRack#3208432]
```

Two triage red herrings, resolved up front:
- **"import inbound bol called with 225"** — the UI hit the **correct** endpoint (`POST /v3/import/locations` → `importLocations`); the INFO message at `FileImportController.java:149` is copy-pasted from `importInboundBols` (Fix C).
- **"another transaction"** — there is no second actor. The conflict is self-inflicted within the single request: a stale detached entity is re-merged by a later loop iteration.

**Reproduction (DB-verified, §1.1):** upload a locations file with **≥3 rows sharing one `rackName`+`rackRowName`**. Row 0 creates the rack (create path — caches the saved instance correctly); row 1's else-branch merge performs an UPDATE (version bump — the merge is dirty on a non-business field, see §1.1), leaving the cached copy stale; row 2 merges the stale copy and throws. If the rack already pre-exists with a differing `rackrow_id`, ≥2 shared rows suffice. Not migration-specific — any tenant reproduces this.

### 1.1 DB verification (db_verified: true — executed 2026-07-10 via `nywh-hydra-uat` MCP)

Queries run against the hydr-nywh tenant DB (routing key `tenant_name=hydr`, `facility_code=nywh`):

```sql
-- H1: confirm the failing rack pre-exists and inspect version + rackrow pointer
SELECT id, name, version, rackrow_id, client_id, entity_lock
FROM   location_rack WHERE id = 3208432 OR name = 'V8';

-- H1: does rack-row '1' pre-exist? (decides which row first dirties the rack)
SELECT id, name, version, client_id FROM location_rack_row WHERE name = '1';

-- H2 (separate latent risk on migrated DBs): sequence vs max(id)
SELECT last_value FROM seqentities;
SELECT greatest((SELECT max(id) FROM location_rack),
                (SELECT max(id) FROM location_rack_row),
                (SELECT max(id) FROM location)) AS max_any;
```

**Results (2026-07-10):**

| Query | Result |
|---|---|
| `location_rack` where `id=3208432 or name='V8'` | one row: `id=3208432, name='V8', version=2, rackrow_id=3208431, client_id=0, entity_lock=0` |
| `location_rack_row` where `name='1'` | one row: `id=3208431, version=1, client_id=0` |
| `created` / `modified` on rack `#3208432` | `created=12:49:38.305271Z`, `modified=12:49:38.330814Z` (gap 25.5 ms) |
| `location` in `('1V8L1C1','1V8L1C2','1V8L1C3')` | `1V8L1C1` = `#3208433`, `1V8L1C2` = `#3208434` (both `rack_id=3208432`); **`1V8L1C3` absent** |
| `seqentities.last_value` | `3,208,434` |
| `max(id)` rack / rackrow / location | `47,285,802` / `3,208,431` / `33,665,942` |
| `min(id)` above the low island | rack `10,280,450`, location `9,115,850`, rackrow none |

**Interpretation — H1 confirmed, with a sharper timeline than the code-only analysis assumed:**

- Rack `#3208432` and rack-row `#3208431` are **low-island ids created by this very upload** (row 0, create path), not hydra-migrated rows. The sequence then allocated `#3208433`/`#3208434` to the row-0 and row-1 locations; the request died before row 2's location got an id. Every id the sequence issued is accounted for.
- Rack `created=.305` falls inside row 0's processing window (log: `create 0` at `.190`, `create 1` at `.321`); `modified=.330` falls inside row 1's window (`create 1` at `.321`, `create 2` at `.336`); the optimistic-lock WARN fired at `.352` during row 2. So: row 0 INSERT (v=1, cached correctly by the create path at :251), **row 1 else-branch merge performed an UPDATE (v=1→2)** leaving the `rackMap` copy stale, **row 2 merged the stale copy and threw**. DB timestamps align with the request log to the millisecond.
- Row 1's merge doing an UPDATE despite no meaningful field change indicates the merge was dirty on a non-business field. Precise mechanism (verified by Architect review against the mappings): `AbstractBaseEntity` declares `LocalDateTime created/modified` under Spring Data auditing (`@CreatedDate`/`@LastModifiedDate`, `AuditingEntityListener`) — not Hibernate `@CreationTimestamp`/`@UpdateTimestamp`. The columns were ALTERed to `timestamptz` by `V1.2.01__utc_standard_tables.sql:222-230` (pre-V1.2.01 tenants still have `timestamp`), with `hibernate.jdbc.time_zone=UTC` and `preferred_instant_jdbc_type=TIMESTAMP_WITH_TIMEZONE` (`application.properties:109-110`). A `LocalDateTime` carrying sub-microsecond precision in the detached instance round-trips against a microsecond-precision column, making the detached re-merge dirty; once any flush triggers, `@LastModifiedDate` resets `modified` and the version bumps (the observed `modified=.330`). This is not codebase-wide because it needs the rare combination this loop has: OSIV off → per-call transactions → a *detached* instance from a prior transaction re-merged without a re-read; ordinary update paths mutate a managed entity inside one session and never round-trip. All `location_rack` string columns are `varchar` (no CHAR padding). None of this changes the fix — Fix A removes the stale reuse regardless of the dirty driver. Cheapest definitive runtime pin if ever needed: `org.hibernate.SQL=DEBUG` + `org.hibernate.orm.jdbc.bind=TRACE` on a repeated-rack upload, confirming the row-1 `UPDATE location_rack` and its bound timestamp values.
- **H2 (seqentities collision) — no near-term risk:** the low island tops out at `3,208,434` and the nearest high-island row starts at `9,115,850` → ~5.9 M free ids of headroom. Faithful-not-broken dual-island state; monitor at future cutovers, no follow-up filed.

---

## 2. Root Cause Analysis

### Bug 1 (Fix A): `rackMap` serves a stale detached `LocationRack` after the else-branch re-save

`FileImportController.importLocations` (`FileImportController.java:147-307`) loops over upload rows with **no `@Transactional`**. OSIV is disabled (`application.properties:54`, `spring.jpa.open-in-view=false`), so **every repository call is its own implicit transaction**: each `findByName(...)`/`save(...)` opens a session, commits, closes — every entity it returns is **detached**. `AbstractBaseEntity` carries `@Version private Integer version`, so optimistic locking is active on `LocationRack`.

The broken block (`FileImportController.java:252-256`):

```java
} else {
    // update rack row id for this rack and save
    rack.setRackrowId(rackRow.getId());
    rack = locationRackRepository.save(rack);   // reassigns the LOCAL variable only
}                                               // rackMap is NEVER refreshed
```

Sequence — **DB-verified against the incident** (§1.1; rows 0-2 share `rackName='V8'`/`rackRowName='1'`; timestamps from the hydr-nywh DB align with the request log to the millisecond):

1. **Row 0** (`.190`–`.321`) — rack `V8` not found → **create path**: rack-row `#3208431` and rack `#3208432` INSERTed (`created=.305`, version 1); the create path correctly caches the saved instance at :251. Location `1V8L1C1` (`#3208433`) inserted.
2. **Row 1** (`.321`–`.336`) — `rackMap.get("V8")` returns the cached instance (v=1). Else branch: `save(rack)` merges — the merge is **dirty on a non-business field** (prime suspect: nanosecond→microsecond truncation on the `created`/`modified` timestamps of the detached instance, §1.1) — so it issues a real `UPDATE` (`modified=.330`, version 1→2). The merged, version-bumped copy is assigned only to the **local** `rack` variable; **`rackMap` still holds the v=1 instance.** Location `1V8L1C2` (`#3208434`) inserted.
3. **Row 2** (`.336`–) — `rackMap.get("V8")` returns the stale v=1 instance (DB is v=2). `save(...)` merges a stale-version detached entity → Hibernate raises `StaleObjectStateException` → Spring wraps it as `ObjectOptimisticLockingFailureException` → `RestExceptionHandler` logs *"Optimistic lock conflict … LocationRack#3208432"* at `.352` and returns the generic 500. Location `1V8L1C3` was never inserted (confirmed absent).
4. The rack save at :255 is **outside** the per-row `try/catch` (only the `Location` save at :283-289 is guarded), so the first stale merge **aborts the entire request** — matching the whole-upload failure the admin saw.

The mechanism is index-independent — the failure is always the first re-merge of the un-refreshed `rackMap` entry after the DB version has advanced — but on this incident the concrete row indices are proven, not inferred.

Contrast with the **create path** (:238-251), which does it right — it caches the instance returned by `save(...)`:

```java
rack = locationRackRepository.save(tmpRack);
rackMap.put(locationDto.getRackName(), rack);   // :251 — create path refreshes the cache
```

### Bug 2 (Fix B): `rackRowMap` GET/PUT key mismatch — the rack-row cache never hits

`FileImportController.java:215`:

```java
LocationRackRow rackRow = rackRowMap.get(locationDto.getRackName());   // GET by RACK name
```

but both PUTs key by **rack-row** name (:221, :234):

```java
rackRowMap.put(locationDto.getRackRowName(), rackRow); // cache it
```

Consequences: (a) the cache never hits → a redundant `locationRackRowRepository.findByName` per row; (b) a latent duplicate-rack-row window if the DB lookup path misses; (c) it contributes the per-row rack-row resolution churn that feeds Bug 1's `setRackrowId` dirtying. `rackRow` itself is only read (`getId()`), never re-saved, so this bug cannot itself throw the optimistic lock.

### Bug 3 (Fix C): copy-paste log message misidentifies the endpoint

`FileImportController.java:149` (`importLocations`) and `:312` (`importSkus`) both log `"import inbound bol called with {}"`, copy-pasted from `importInboundBols` (`:401` — the only correct use). Cosmetic, but it sent this incident's triage toward the BOL import path.

### Rejected hypotheses

| Hypothesis | Verdict |
|---|---|
| Seqentities dual-island id collision on the migrated tenant (unsaved-value / duplicate-key) | **Refuted as the cause of this error** — the exception is a *version conflict on an existing row being merged*, not a `DataIntegrityViolationException`; ids here are `@GeneratedValue(SEQUENCE)`, never pre-set. §1.1 measured the latent risk: ~5.9 M free ids between the low island (`3,208,434`) and the nearest high-island row (`9,115,850`) — faithful-not-broken dual-island state, no follow-up needed; monitor at future cutovers. |
| Genuine concurrent second request | Unlikely — single sequential admin loop; "another transaction" is Hibernate's boilerplate `StaleObjectStateException` text. |
| Broken entity `equals`/`hashCode` corrupting the caches | Rejected — `rackMap`/`rackRowMap` are keyed by `String`, not by entity. (v2 `AbstractBaseEntity.equals` is ID-based and fine.) |

---

## 3. The Regression Chain

Long-standing bug — **not** a release-branch regression. `FileImportController` import logic is identical between the working tree (`9b3f438`), `develop`, and `origin/main`.

| Commit | Date | What it did | Role |
|--------|------|-------------|------|
| `ac3c25c` | 2025-05-21 | "fixed location upload error and cleaned up the code" — introduced the `rackMap`/`rackRowMap` caching | Introduced the caching structure (incl. the Bug-2 key mismatch) |
| `eacce03` | 2025-05-22 | "updated location import logic to get rid of unnecessary error messages" — authored the `else { setRackrowId; save }` block | **Introduced the un-refreshed re-save (Bug 1)** |
| `5442a06` | (SB3.5 upgrade) | removed `getNextId()`, switched ids to `@GeneratedValue SEQUENCE seqentities` | Sets up the *latent* migrated-DB collision risk (out of scope) |

Audit gap worth recording: the archived **`260424-WMS_OSIV_Disabled_Audit.md`** graded `FileImportController` "✅ Safe" on the premise that it only creates **new** entities before `.save()` — it missed the else-branch **re-save of a fetched (detached) existing** rack. Update that audit's entry when this plan ships.

Why it surfaced only now (revised after DB verification — the incident's rack was created *by the same upload*, not pre-existing): the trigger is simply **≥3 rows sharing one `rackName` in a single upload** — row 0 creates, row 1's merge updates (dirty on a non-business field, §1.1), row 2 goes stale. Location bulk-imports are rare events (tenant onboarding), and the dirty-merge driver is plausibly Hibernate-6-specific (entered with the SB3.5 upgrade, `5442a06` era) — which would explain the absence of earlier v2 reports and why v1, with the identical code shape on Hibernate 5, has not surfaced it.

---

## 4. Architecture Overview

```
UI: Admin ▸ SystemManagement ▸ Import Data ▸ Locations
        │  POST /v3/import/locations   (Keycloak: sb_admin)
        ▼
TenantFilter → TenantContext(hydr-nywh) → TenantDynamicRoutingDataSource
        ▼
FileImportController.importLocations(List<LocationUploadDto>)          [:147]
  LOG.info("import inbound bol ...")   ← wrong string (:149, Fix C)
  clientRepository.findByClNr("System")                                 [:151] (own tx)
  rackMap / rackRowMap / areaMap / storageLocationTypeMap = new HashMap [:158-161]
  for each LocationUploadDto   (NO @Transactional, OSIV = false)        [:162]
    ├─ locationRepository.findByName(locationName)                      [:172] (own tx → detached)
    ├─ areaMap / storageLocationTypeMap (read-only caches)              [:177-197]
    ├─ rack = rackMap.get(rackName)                                     [:204] ← serves STALE instance
    │    miss → locationRackRepository.findByName; rackMap.put          [:207-210]
    ├─ rackRow = rackRowMap.get(rackName)   ← WRONG KEY (Fix B)          [:215]
    │    miss → locationRackRowRepository.findByName(rackRowName)       [:217]
    │    null → new LocationRackRow; save; put                          [:226-234] (own tx, INSERT)
    ├─ rack null → new LocationRack; save; rackMap.put                  [:238-251] (own tx, INSERT — cache refreshed ✓)
    │  else     → rack.setRackrowId; save(rack)   ◄── OPTIMISTIC LOCK    [:252-256] (own tx, MERGE)
    │             rackMap NOT refreshed            ◄══ ROOT CAUSE (Fix A)
    └─ errors empty → new Location; save (try/catch)                    [:264-289] (own tx, INSERT)
        ▼
RestExceptionHandler → ObjectOptimisticLockingFailureException → 500 → generic UI error
```

### Key files

| File | Lines | Role |
|------|-------|------|
| `src/main/java/net/aim_ai/wms/controller/FileImportController.java` | 147-307 | endpoint + per-row loop; bugs at :252-256, :215, :149/:312 |
| `src/main/java/net/aim_ai/wms/model/AbstractBaseEntity.java` | — | `@Id @GeneratedValue(SEQUENCE seqentities, allocationSize=1)`, `@Version Integer version`, equals=id |
| `src/main/java/net/aim_ai/wms/model/LocationRack.java` | — | entity; `@Version` inherited |
| `src/main/java/net/aim_ai/wms/model/LocationRackRow.java` | — | entity; `@Version` inherited |
| `src/main/java/net/aim_ai/wms/repo/jpa/LocationRackRepository.java` | — | `findByName`; inherits `tenantTransactionManager` |
| `src/main/resources/application.properties` | 54 | `spring.jpa.open-in-view=false` |
| `src/test/java/net/aim_ai/wms/unit/controller/FileImportControllerUnitTest.java` | 348+ | existing `@Nested class ImportLocations` |

### V1/V2 Applicability

| Aspect | V1 | V2 | Impact |
|--------|----|----|--------|
| Un-refreshed else-branch re-save | `FileImportController.java:239-243` — identical | :252-256 | v1 has the same optimistic-lock bug |
| rackRowMap key mismatch | `:200` GET by `getRackName()` | :215 | identical |
| Copy-paste log string | present in v1 import methods | :149, :312 | identical |

**What needs porting:** all three fixes, mechanically, to `v1/wms-api/.../FileImportController.java`. Create the paired plan `sbdocs/1-Projects/wms1/plan/260710-location-import-stale-rack-reference-optimistic-lock.md` (same base name per convention). This plan is **v2-only**; the v1 pair is a follow-up. Note for the v1 pair: the failure may not reproduce on Hibernate 5 (the row-1 dirty-merge driver appears version/mapping-specific, §1.1), but the stale-cache pattern is latent and the same one-line fixes apply defensively. To settle it empirically rather than assume: add a version-invariance test in the v1 pair — persist an entity, detach, re-save without mutation in a fresh transaction, assert `version` unchanged; if it increments, v1 shares the dirty-merge driver too.

---

## 5. Fix Design

### Fix A (PRIMARY) — refresh `rackMap` with the instance returned by the re-save

`FileImportController.java:252-256`

**Before**
```java
} else {
    // update rack row id for this rack and save
    rack.setRackrowId(rackRow.getId());
    rack = locationRackRepository.save(rack);
}
```

**After**
```java
} else {
    // update rack row id for this rack and save, then refresh the cache with the
    // freshly-persisted (version-bumped) instance: with open-in-view disabled each
    // save() runs in its own transaction and returns a detached copy, so the
    // previously cached reference goes stale after the first re-save and re-merging
    // it on a later row throws ObjectOptimisticLockingFailureException
    rack.setRackrowId(rackRow.getId());
    rack = locationRackRepository.save(rack);
    rackMap.put(locationDto.getRackName(), rack);
}
```

One added line — mirrors what the create path already does at :251. Preserves the endpoint's partial-success semantics (`accepted`/`rejected` maps).

**Residual (accepted, per Architect review):** Fix A stops the crash but not the *needless* UPDATE per shared-rack row — `setRackrowId` at :254 re-sets an unchanged value, yet the merge still flushes dirty (timestamp round-trip, §1.1) and bumps the version, so a rack shared by N rows ends at roughly `version=N`. Harmless (single-threaded admin loop) and recorded here so it isn't mistaken for a new defect later. Optional future tightening, explicitly out of scope: guard the save with `if (!Objects.equals(rack.getRackrowId(), rackRow.getId()))`. Likewise pre-existing and deliberately unchanged: the else-branch re-points `rack.rackrowId` on every row referencing that rack (last-write-wins if one rack's rows span multiple rack-row names) — this plan preserves that semantics, it does not bless it.

**Rejected alternatives:**
- *Wrap the loop in `@Transactional(value = "tenantTransactionManager", ...)`* — a single persistence context would also cure the staleness, but converts the import to all-or-nothing: one bad row would roll back every already-accepted row, a behavioral regression against the endpoint's per-row accept/reject contract.
- *Drop `rackMap` and re-fetch per row* — adds a query per row and doesn't fix the create path's reason for caching; strictly worse than the one-line refresh.
- *Optimistic-lock retry wrapper* — over-engineered; there is no genuine concurrency, only a self-inflicted stale reference.

### Fix B — correct the rack-row cache GET key

`FileImportController.java:215`

**Before**
```java
LocationRackRow rackRow = rackRowMap.get(locationDto.getRackName());
```

**After**
```java
LocationRackRow rackRow = rackRowMap.get(locationDto.getRackRowName());
```

Aligns the GET with both PUTs (:221, :234): the cache actually hits, the redundant per-row `findByName` disappears, and the latent duplicate-rack-row window closes.

### Fix C — correct the copy-paste log messages

`FileImportController.java:149` and `:312`

**Before**
```java
LOG.info("import inbound bol called with {}", adviceList.size());
```

**After** (`:149` in `importLocations` / `:312` in `importSkus` respectively)
```java
LOG.info("import locations called with {}", adviceList.size());
LOG.info("import skus called with {}", adviceList.size());
```

`:401` in `importInboundBols` stays as is. SLF4J parameterized form retained.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/FileImportController.java` | modify | Fix A: add `rackMap.put(...)` after else-branch re-save (:256); Fix B: GET key `getRackName()` → `getRackRowName()` (:215); Fix C: log strings (:149, :312) |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/controller/FileImportControllerUnitTest.java` | modify | New tests in `@Nested class ImportLocations` (§8) |

No schema, config, API-contract, or payload-shape changes.

**Rollback:** single code-only commit — `git revert <sha>` restores prior behavior completely; no data, config, or migration to unwind.

---

## 7. Prerequisites & Implementation Steps

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | ✓ DONE 2026-07-10 — §1.1 SQL executed via `nywh-hydra-uat` MCP; results recorded in §1.1; `db_verified: true` | plan author | H1 confirmed at row level; seqentities headroom ~5.9 M ids (no follow-up) |
| 2 | Feature flags / sysprops | N/A — pure code-logic fix, no toggles | — | |
| 3 | Config / env changes | N/A — no properties touched | — | |
| 4 | Deploy-order dependencies | N/A — self-contained controller fix; no UI or OMS change needed | — | |
| 5 | Data migration | N/A — no data is wrong; the failed upload wrote only the rows it accepted (partial-success by design), admin re-uploads after fix | — | Optionally verify no half-imported junk: `SELECT count(*) FROM location WHERE name LIKE '1V8L1C%'` |
| 6 | External systems | N/A | — | |
| 7 | Access / permissions | N/A — endpoint authority unchanged | — | |
| 8 | Monitoring / alerts | N/A — `RestExceptionHandler` already logs optimistic-lock conflicts at WARN | — | |

### 7.2 Implementation Checklist

- [ ] Run `bash sbdocs/9-System/scripts/verify-260710-location-import-stale-rack-reference-optimistic-lock.sh` — capture the FAIL baseline
- [x] Run §1.1 SQL on hydr-nywh; paste results into §1.1 and set `db_verified: true` — done 2026-07-10 (plan author, `nywh-hydra-uat` MCP)
- [ ] Fix A: add `rackMap.put(locationDto.getRackName(), rack);` after `:255` save (one commit with Fix B+C is fine — single logical change set)
- [ ] Fix B: `:215` key swap
- [ ] Fix C: `:149`, `:312` log strings
- [ ] Add/extend unit tests per §8; confirm the Fix-A test fails when Fix A is reverted (red/green)
- [ ] `mvn test -Dtest=FileImportControllerUnitTest` green; `mvn clean compile` green (SDKMAN PATH export needed on this machine)
- [ ] Re-run verify script → must print `Result: N pass, 0 fail`
- [ ] Update §14 Implementation Status (commit SHA, test results, verify output)
- [x] Paired v1 plan stub filed 2026-07-10 at `sbdocs/1-Projects/wms1/plan/260710-location-import-stale-rack-reference-optimistic-lock.md` (per Critic review — flesh out before v1 implementation)
- [ ] Code review pass (separate lane — do not self-approve)

---

## 8. Testing Plan

**Gate:** v2 Testcontainers IT harness is broken (SBDEV-2217) — do **not** add ITs; the gate is unit tests + `mvn clean compile`. Any IT authored anyway must be `@Disabled("TODO(SBDEV-2217): v2 IT harness")`.

### Unit (extend `FileImportControllerUnitTest`, `@Nested class ImportLocations`)

| Test method | What it asserts |
|---|---|
| `importLocations_multipleRowsSameRack_reSavesLatestInstanceNotStaleCache` | 3 DTOs share `rackName="V8"`/`rackRowName="1"`; `locationRackRepository.findByName("V8")` returns an existing rack; `save(any())` returns a *distinct* instance with incremented version per call. `ArgumentCaptor<LocationRack>` on `save`: from the 2nd rack-save on, the captured instance is the one **returned by the previous save** (cache refreshed), never the originally fetched instance. **Red before Fix A.** |
| `importLocations_reusedStaleRack_doesNotPropagateOptimisticLock` | Stub `save` with a **version-gated** `thenAnswer`: track the "DB version" (increment on each successful save); throw `ObjectOptimisticLockingFailureException` iff the argument's version is below the tracked version — do **NOT** throw on any-save-of-the-fetched-instance, or the test stays red even after Fix A (row 0's first `save` of the fetched instance is legitimate). 3 same-rack rows → request completes, all rows accepted, no exception escapes. Note: harness is standalone MockMvc without controller advice, so pre-fix the exception surfaces from `mockMvc.perform(...)` itself. **Red before Fix A (throws on row 1's stale re-save), green after.** |
| `importLocations_rackRowCacheHitByRackRowName` | 2 rows sharing `rackRowName="1"` → `locationRackRowRepository.findByName("1")` invoked exactly **once** (`verify(..., times(1))`). **Red before Fix B** (currently called per row). |
| existing `ImportLocations` tests (`:351`, `:384`, …) | regression guard — stay green |

Fix C is verified by the acceptance script's grep (behavioral test not warranted for a log string).

### Integration

- None (SBDEV-2217). The touched code has no native SQL/JPQL change; unit coverage + compile gate suffice.

### Regression

- `mvn test -Dtest=FileImportControllerUnitTest` (whole class — covers importSkus/importInboundBols/importClients paths against accidental breakage)
- `mvn clean compile` (per project memory: incremental compile misses drift)
- Note pre-existing develop failures (4/4194 as of 2026-06-11: Bol shipped-date, RestExceptionHandler 404, UtilRest ×2) — not caused by this change; don't chase them.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Re-run the failing upload | UAT hydr-nywh | Admin → SystemManagement → Import Data → upload the original 225-row locations file | 200; rows accepted (duplicates of already-imported rows rejected with "location already exists"), no generic network error | |
| Repeated-rack stress | UAT hydr-nywh | Upload a small file: 5 rows, all same pre-existing `rackName`+`rackRowName` | All 5 accepted; no optimistic-lock WARN in logs | |
| Log message sanity | UAT | Trigger locations + skus imports; grep app log | `import locations called with N` / `import skus called with N`; "import inbound bol" only from the BOL import | |
| SQL sanity after import | UAT DB | `SELECT name, version, rackrow_id FROM location_rack WHERE name='V8'; SELECT count(*) FROM location_rack_row WHERE name='1';` | Single rack row `V8` with consistent pointer; no duplicate rack-rows named `'1'` created by the import | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=FileImportControllerUnitTest` | | |
| `mvn clean compile` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Testcontainers IT for the import loop | SBDEV-2217 — v2 IT harness cannot boot; gate is unit + compile per project policy |

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Cache refresh masks a *different* concurrent writer racing the import | Low — import is an admin action; a real concurrent conflict would still (correctly) surface as an optimistic-lock error on first save | None needed; behavior for genuine races is unchanged |
| Fix B changes lookup behavior where rack-row names collide across racks | The cache now hits by rack-row name — same semantics as the existing DB fallback `findByName(rackRowName)`, so no behavior change vs. the cache-miss path that ran every time before | Unit test `importLocations_rackRowCacheHitByRackRowName`; manual SQL sanity row |
| Log-string change breaks a log-based alert/dashboard | Very low — grep of repo dashboards found none keyed on "import inbound bol" | Mention in release notes |
| Latent seqentities collision on migrated tenants (out of scope) | INSERTs at :233/:250/:284 could hit duplicate-key on a dual-island DB | §1.1 SQL screens it; file follow-up if `last_value < max(id)` |

---

## 10. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1 | In-JVM state | **No** | `rackMap`/`rackRowMap` are method-local per request, not cross-request/replica state; fix only corrects their intra-request coherence |
| 2 | Connection pool math | **No** | Fix B *removes* one query per row; no new pools/connections |
| 3 | Scheduled jobs | N/A | none touched |
| 4 | Long transactions | **No** | per-repository-call implicit transactions unchanged (deliberately — see rejected alternative in §5 Fix A) |
| 5 | Request affinity | **No** | stateless request; nothing assumes a follow-up hits the same JVM |
| 6 | Retry / idempotency | **No** | re-upload after failure already idempotent via the "location already exists" per-row rejection; unchanged |
| 7 | Tenant context | **No** | no async boundaries introduced |
| 8 | Distributed lock correctness | **No** | fix removes a spurious optimistic-lock failure; genuine cross-replica conflicts still fail fast on version, as designed |
| 9 | Cache invalidation | **No** | `LocationRack`/`LocationRackRow` are not in the Caffeine-cached set; `importSkus`' existing `@CacheEvict("itemdata")` untouched |
| 10 | External notifications | N/A | none sent from this path |

No "Yes" rows → no evidence table required.

---

## 11. v2-only constraint checklist

| # | Constraint | Verdict | Note |
|---|---|---|---|
| 1 | OSIV disabled | **Yes — addressed** | The fix exists *because* OSIV is off (§2 Bug 1); no lazy-load paths added |
| 2 | Transaction manager | N/A | no `@Transactional` added (deliberate, §5 Fix A rejected-alternatives); repositories inherit `tenantTransactionManager` |
| 3 | `readOnly=true` | N/A | no read-only service methods added |
| 4 | Caffeine cache invalidation | **Yes — checked** | rack/rack-row entities not `@Cacheable`; `itemdata` evict on importSkus untouched |
| 5 | Jakarta namespace | N/A | no imports added |
| 6 | H2-compatible test SQL | N/A | no SQL in tests; standalone-MockMvc + Mockito unit tests (no DB, no controller advice registered) |
| 7 | `BaseControllerTest` for controller changes | **No — rationale** | endpoint contract (mapping, params, payload) unchanged; behavior fix covered by existing unit-test harness for this controller (`FileImportControllerUnitTest`), consistent with how this class is already tested |
| 8 | Micrometer metrics | N/A | admin import path, not a high-frequency workflow; existing WARN logging suffices |

---

## 12. Open Questions / Resolved Decisions

| # | Question | Resolution |
|---|---|---|
| 1 | Scope: v1, v2, or both? | **v2 now** (the UAT incident); v1 has the identical bugs — paired plan `wms1/plan/260710-...` as immediate follow-up (§4) |
| 2 | Concurrency semantics | No change: genuine concurrent modification still fails fast via optimistic lock; only the self-inflicted intra-request staleness is removed |
| 3 | All-or-nothing vs partial success | Keep the existing per-row accept/reject contract (drove the rejection of the `@Transactional`-wrapper alternative) |
| 4 | Ticket | None assigned; rename file if an SBDEV ticket is created |
| 5 | Pre-draft clarifying questions | Skipped per skill rules — mechanical fixes, scope unambiguous from the incident; decisions above are the defaults taken |
| 6 | Coordination with in-flight work | **SBDEV-2496 (sku normalization) has uncommitted WIP on branch `port/SBDEV-2496-sku-normalization` that modifies `FileImportControllerUnitTest.java`** — the same test class this plan extends (plus an intentional TDD-gate stub `util/SkuCodes.java`). Implement this plan on a branch cut from clean `develop`, or land SBDEV-2496 first; do not build on the WIP tree |

---

## 13. Acceptance & Implementation

### 13.1 Acceptance script (machine-checkable)

`sbdocs/9-System/scripts/verify-260710-location-import-stale-rack-reference-optimistic-lock.sh`

Checks: Fix A positive (cache-put immediately follows the else-branch save; `rackMap.put(getRackName(), rack)` count ≥ 3 — fetch + create + else paths), Fix B positive + negative (new key present, old key gone), Fix C positive + count (correct strings present; "import inbound bol" appears exactly once), presence of the three §8 test methods, plus targeted `mvn test -Dtest=FileImportControllerUnitTest` (skippable with `SKIP_MVN=1`). FAIL baseline captured 2026-07-10 against `9b3f438`: `Result: 0 pass, 10 fail, 1 skip` — all checks proven to detect the defective state. Scope caveat (per Critic review): T1–T3 are **existence-only** checks (method names present in the test class); the red-before-fix evidence for the two Fix-A tests cannot be script-proven and remains the manual gate in the post-implementation checklist below (item 1).

Final acceptance: the script prints **`Result: N pass, 0 fail`** and the implementer pastes that line in the end-of-task report. Run it BEFORE any change (FAIL baseline) and after every pass.

### 13.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Trivial | 3 mechanical fixes, one file + its test class |
| **Pre-draft step** | none (analysis done by opus executor pass) | |
| **Plan-review step** | none — trivial class; verify script is comprehensive | |
| **Implementation shape** | executor (single agent) | |
| **Verification step** | verify-script + verifier | mandatory |
| **Code-review step** | code-reviewer optional; separate-lane review required before merge per repo policy | |
| **Commit step** | git directly (single atomic commit) | |

### Post-implementation gate (inherited from wms-bugfix-plan)

Not complete until: (0) verify script `0 fail` pasted; (1) the three §8 unit tests exist and the two Fix-A tests were seen red before the fix; (2) `mvn test -Dtest=FileImportControllerUnitTest` + `mvn clean compile` green; (3) §14 Implementation Status filled with SHAs and results.

---

## 14. Implementation Status (2026-07-10)

**Implemented** — branch `tdd/260710-location-import-stale-rack` (base `develop@9b3f438`), commit **`69861d5`**, PR **[SiteBossInc/wms2-api#64](https://github.com/SiteBossInc/wms2-api/pull/64)** into `develop` (open, awaiting merge).

| Item | Result |
|---|---|
| Fixes | A (cache refresh after else-branch save), B (`rackRowMap` GET key → `getRackRowName()`), C (log strings in `importLocations` + `importSkus`) — all in `FileImportController.java` |
| Tests added | `FileImportControllerUnitTest$ImportLocations`: `importLocations_multipleRowsSameRack_reSavesLatestInstanceNotStaleCache`, `importLocations_reusedStaleRack_doesNotPropagateOptimisticLock` (version-gated stub), `importLocations_rackRowCacheHitByRackRowName` + helpers |
| TDD gate | Red baseline: `Tests run: 3, Failures: 3, Errors: 0` (all assertion failures) → green after fixes: `3, Failures: 0, Errors: 0` |
| Regression | Whole class `mvn test -Dtest=FileImportControllerUnitTest`: **38 run / 0 failures / 0 errors**; `mvn clean compile`: BUILD SUCCESS (SDKMAN Java 21.0.11-ms, Maven 3.9.15) |
| Verify script | **`Result: 11 pass, 0 fail, 0 skip`** (final; run with `PROJECT_ROOT` at the implementation worktree) |
| Code review | code-reviewer agent: **APPROVE, 0 medium+ findings** (1 low = pre-existing redundant re-save, out of scope per §5 residual; 2 nits, no change required) |
| Deslop pass | Clean — no edits; pre-existing smells recorded (§5 residual, reviewer nit list) |
| verify-docs | No blocking drift. Cosmetic: `wms2-state-machine-catalog.md` cite `FileImportController:465` shifts to `:470` (+5 lines from Fix A) — bump at next cadence touch. Archived OSIV audit annotation still pending (see §3) |
| Deviations | Two latent verify-script bugs fixed during acceptance (BRE `\(` group vs literal in A1's greps; `mvn -q` suppressing `BUILD SUCCESS` in `mvn_test_passes`) — script semantics unchanged, both checks still fail pre-fix |

---

## 15. Completeness checklist (Layer 2)

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ `db_verified: true` — §1.1 executed 2026-07-10 via `nywh-hydra-uat` MCP; row-level evidence (id allocation, version=2, created/modified timestamps) confirms the mechanism against the incident log to the millisecond |
| 1 | All callsites enumerated | ✓ §0 rows A-F; A/B/C fixed in §5, D/E/F excluded with rationale |
| 2 | Adjacent bugs | ✓ §0 rows C (importSkus log), E (other import loops audited — clean), F (v1 mirror); latent seqentities risk flagged §2/§9 |
| 3 | Backward compatibility | ✓ §6 — no API/schema/payload/error-shape change; log-string change noted in §9 risks |
| 4 | Concurrency | ✓ §2 (self-inflicted staleness), §12 Q2 (genuine races still fail fast), §10 rows 6/8 |
| 5 | Multi-tenant | ✓ §4 diagram (TenantContext routing untouched); fix is tenant-agnostic; trigger condition is migrated-tenant data shape (§1) |
| 6 | Error handling | ✓ no new throw paths; existing per-row accept/reject + RestExceptionHandler unchanged |
| 7 | Observability | ✓ Fix C corrects misleading logs; §7.1 row 8 — existing WARN logging adequate |
| 8 | Rollback / migration | ✓ §7.1 rows 1-5 — no migration; partial-success rows from the failed upload handled by duplicate rejection on re-upload |
| 9 | Test coverage | ✓ §8 — 3 named unit tests (2 red-before-fix), regression + manual table, IT gap justified (SBDEV-2217) |
| 10 | Cross-version (v1↔v2) | ✓ §4 — v1 has identical bugs at cited lines; paired same-base-name v1 plan as follow-up |
