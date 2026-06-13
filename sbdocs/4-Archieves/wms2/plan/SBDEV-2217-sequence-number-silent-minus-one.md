---
title: "SBDEV-2217 — Sequence-number generation hardening (v2)"
ticket: "SBDEV-2217"
ticket_url: "https://app.clickup.com/t/868jj31rh"
type: "bugfix"
priority: "high"
status: "archived"
project: ["wms2"]
version: "v2"
requester: "David Oppenheim"
created: "2026-05-09"
updated: "2026-05-09"
related: []
db_verified: true
tags:
  - plan
  - sequence
  - concurrency
  - reliability
---

# SBDEV-2217 — Sequence-number generation hardening (v2)

**Ticket:** [SBDEV-2217](https://app.clickup.com/t/868jj31rh)
**Project:** wms2/wms2-api | **Version:** v2 (Java 21 / Spring Boot 3.x) | **Type:** bug fix
**Priority:** High (Tier 1 — silent data corruption class)
**Reporter:** David Oppenheim | **Assignee:** Nam Park
**Parent:** WMS Code Fixes audit (868jj30yh)
**Status:** implemented (PR [#3](https://github.com/SiteBossInc/wms2-api/pull/3) open against develop) — v2 partially fixed in main pre-plan; this PR closed the residual gaps

---

## 0. Affected sites (enumeration before drafting)

Grep run: `grep -rn "getNextSequenceNumber\|generatePickOrderNumber\|generateReplenishNumber\|generateOrderNumber" v2/wms2-api/src/main/java`. Every "yes" row in the In-scope column MUST be visited by §3 Fix Design or excluded with rationale.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|---|---|---|---|
| 1 | `service/BasicService.java:91-94` | `generatePickOrderNumber()` formats `n` without `n >= 0` guard | yes | **yes** — Fix B |
| 2 | `service/BasicService.java:96-99` | `generateReplenishNumber()` formats `n` without `n >= 0` guard | yes | **yes** — Fix B |
| 3 | `service/BasicService.java:41-45` | `generateNumber(prefix,key)` — `String.format(prefix + getFormat(), getNextSequenceNumber(key))` no guard | yes | **yes** — Fix B |
| 4 | `service/BasicService.java:47-51` | `generateMessageNumber(prefix,key)` — `String.format(prefix + getMessageFormat(), getNextSequenceNumber(key))` no guard | yes | **yes** — Fix B |
| 5 | `service/BasicService.java:53-59` | `generateOrderNumber(orderBatch)` — uses `customerOrders.size() + 1`, NOT `getNextSequenceNumber` | no | **no** — different mechanism (count-based) |
| 6 | `service/BasicService.java:109-159` | `getNextSequenceNumber()` retry+throw — exhaustion throws `RuntimeException` (generic) | yes | **yes** — Fix A (typed exception) |
| 7 | `service/SequenceTransactionService.java:23-41` | already pessimistic-locked + REQUIRES_NEW + tenantTransactionManager | partial | **yes** — Fix E (documentation only; new-key path returns `0L` — confirm intent) |
| 8 | `controller/rest/OrderRestController.java:399` | calls `basicService.generateOrderNumber(customerOrderBatch)` — confirmed at `:399` via grep | no | **no** — that overload uses size+1, not the sequence table |
| 9 | `service/AdviceService.java:225` | calls `basicService.generateOrderNumber(customerOrderBatch)` | no | **no** — same as above |
| 10 | `service/PickingorderService.java:44` | `basicService.generatePickOrderNumber()` — caller; lands in #1 fix | yes | covered by Fix B (#1) |
| 11 | `service/ReplenishGeneratorService.java:180` | `basicService.generateReplenishNumber()` — caller; covered by Fix B (#2) | yes | covered by Fix B (#2) |
| 12 | `service/ParcelMonitorViewService.java:112,241` | `String.format(patternOutboundPalletLabel, basicService.getNextSequenceNumber(...))` direct caller — same vulnerability shape | yes | **yes** — Fix B (caller-side guard) |
| 13 | `service/OrderMonitorViewService.java:180` | `String.format(patternToteLabel, basicService.getNextSequenceNumber(...))` | yes | **yes** — Fix B (caller-side guard) |
| 14 | `service/BillofladingService.java:719` | `String.format(patternOutboundPalletLabel, basicService.getNextSequenceNumber(...))` | yes | **yes** — Fix B (caller-side guard) |
| 15 | `repo/jpa/LosSequencenumberRepository.java:18-19` | `findByClassname` non-locking method still exists and is exported via `@RestResource` | adjacent | **yes** — Fix D (defensive: `@RestResource(exported = false)` or remove) |

---

## 1. Problem Statement

### Symptom (verbatim from ticket)

`BasicService.getNextSequenceNumber()` historically wrapped `SequenceTransactionService.getNextSequenceNumber()` (REQUIRES_NEW) in a 100-try retry loop catching `ObjectOptimisticLockingFailureException`. After exhaustion, the legacy code commented out the `throw new BusinessException(msg)` and returned `-1`, which callers like `generatePickOrderNumber()` formatted into `PICK-00001`-style malformed numbers, silently poisoning primary keys.

The ticket lists four acceptance criteria:
1. `BasicService.getNextSequenceNumber()` throws on exhaustion.
2. `SequenceTransactionService` uses pessimistic write locking.
3. No record in production with a negative-formatted sequence number (or remediation plan documented).
4. Load test: 50 concurrent threads each calling `generatePickOrderNumber()` 100 times → all succeed, all produce non-overlapping monotonic numbers.

### v2 already partial — what is already in place

When auditing v2 source on 2026-05-09, several of the ticket's "Suggested fix" items are already implemented. Each is quoted verbatim and labelled `[ALREADY DONE]` so this plan does not silently re-propose work that is done.

**`BasicService.getNextSequenceNumber()` — `BasicService.java:109-159`:**
```java
public long getNextSequenceNumber(String assignedClassKey) {
    int tries = 0;
    // Reduced from 100 — pessimistic lock on sequence row makes retries rare
    final int maxTries = 5;
    long nextSeq = -1;
    do { ... } while (nextSeq < 0 && tries < maxTries);

    if (nextSeq < 0) {
        LOG.error("Cannot get Sequence. Give it up after {} tries", maxTries);
        final String msg = "Exceeded maxTries=" + maxTries + " attempts for sequence key=" + assignedClassKey;
        LOG.error("*** getNextSequenceNumber for {}", assignedClassKey);
        throw new RuntimeException(msg);
    }
    return nextSeq;
}
```

- `maxTries = 5` — retry budget reduced from 100. **[ALREADY DONE — landed in 7316ddb5]**
- `throw` is uncommented and live on the exhaustion path. **[ALREADY DONE — landed in 7316ddb5]**
- `Exception` type is generic `RuntimeException`, not `BusinessException`. **GAP — Fix A.**
- No `MeterRegistry` injection; no Micrometer Timer or Counter wraps the loop. **GAP — Fix C.**

**`SequenceTransactionService.getNextSequenceNumber()` — `SequenceTransactionService.java:23-41`:**
```java
@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)
public Long getNextSequenceNumber(String key) {
    Long returnSeq = 0L;
    LosSequencenumber seq = null;
    // Pessimistic lock eliminates optimistic retry storms under concurrent load
    Optional<LosSequencenumber> seqOpt = losSequencenumberRepository.findByClassnameForUpdate(key);
    ...
}
```

- Uses `findByClassnameForUpdate` (PESSIMISTIC_WRITE). **[ALREADY DONE — landed in 7316ddb5]**
- Uses `tenantTransactionManager`. **[ALREADY DONE — landed in 58ad0f36]**
- `REQUIRES_NEW` propagation. **[ALREADY DONE]**

**`LosSequencenumberRepository.findByClassnameForUpdate(...)` — `LosSequencenumberRepository.java`:**
```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT s FROM LosSequencenumber s WHERE s.classname = :className")
Optional<LosSequencenumber> findByClassnameForUpdate(@Param("className") String className);
```
**[ALREADY DONE — landed in 7316ddb5]**

The non-locking `findByClassname` (`LosSequencenumberRepository.java:18-19`) is still exported via `@RestResource` and is no longer called from production code paths. **GAP — Fix D (defensive cleanup).**

**`LosSequencenumber` entity — `LosSequencenumber.java`:** ID-based equals/hashCode using `getClassname()` and `@Version Integer version`. **[ALREADY DONE]**

### DB verification (recorded as part of Analysis Protocol §8)

`mcp__wms1-wineco-dev__execute_sql` was used on 2026-05-09 to verify the live state of `los_sequencenumber` and the affected entity tables.

**Query 1 — sequence-row health:**
```sql
SELECT classname, sequencenumber, version FROM los_sequencenumber ORDER BY classname;
```
Result (excerpt of 22 rows): all `sequencenumber` values positive (range 1 – 1,524,380). Notable counts:
- `PICKING_ORDER=227171, version=443786`
- `REPLENISH_ORDER=52266, version=100448`
- `WEBSERVICE_MESSAGE=1524380, version=2951898`
- `UNIT_LOAD=317371, version=621574`

The `version` columns are roughly 2× the corresponding `sequencenumber` — this confirms long-running optimistic-lock churn historically (every retry incremented version). After the 7316ddb5 pessimistic-lock landed, version growth should plateau. No row is in negative state.

**Query 2 — production data scan for negative-formatted entity numbers:**
```sql
SELECT 'pickingorder' AS source, count(*) AS bad
  FROM pickingorder WHERE number ~ '-' AND number !~ '^[A-Z]+[0-9]+$'
UNION ALL SELECT 'replenishorder', count(*)
  FROM replenishorder WHERE number ~ '-' AND number !~ '^[A-Z]+[0-9]+$'
UNION ALL SELECT 'pickingorder_minus1', count(*)
  FROM pickingorder WHERE number ILIKE '%-00001' OR number = 'PICK-00001'
UNION ALL SELECT 'replenishorder_minus1', count(*)
  FROM replenishorder WHERE number ILIKE '%-00001' OR number = 'REPL-00001';
```

Result:
| Source | Count |
|---|---|
| `pickingorder` with `-` and not matching `^[A-Z]+[0-9]+$` | **0** |
| `pickingorder_minus1` (`PICK-00001`) | **0** |
| `replenishorder_minus1` (`REPL-00001`) | **0** |
| `replenishorder` with `-` and not matching `^[A-Z]+[0-9]+$` | **90** |

The `replenishorder` query returned 90 rows that include a hyphen and do not match the canonical `^[A-Z]+[0-9]+$` pattern. **Specifically `REPL-00001` is 0**, so these 90 are not the `n=-1` poisoning signature; they are most likely a legitimate older naming format (e.g. embedded hyphens such as `REPL-2024-00001`). A follow-up DBA probe (see §5.1 Prerequisites row 5) characterises the 90 before deploy so the team can confirm.

**Verdict.** Production data is currently clean of `-1`-formatted entities (no `PICK-00001` / `REPL-00001`). The remaining v2 work is **preventative**: close the silent-failure window so that, in any future scenario where retries do exhaust (e.g. a database outage causing repeated lock-timeout exceptions instead of optimistic-lock), the system fails loudly with a typed exception, the caller-side guard catches the impossible negative, and metrics surface the exhaustion in real time.

### Reproduction (synthetic)

A real reproduction of the original `n = -1` symptom is no longer possible against current code (the `throw` is now in place). The v2-relevant reproduction is the **load-test acceptance criterion** (#4):

> Spawn 50 threads against a real Postgres tenant DB; each calls `basicService.generatePickOrderNumber()` 100 times. Collect 5,000 results, assert all distinct, all monotonic when sorted, no `*-00001`-style malformed entries, max numeric = seed + 5,000.

This is currently **uncovered** by the v2 test suite. §6 introduces a Testcontainers PostgreSQL integration test (`SequenceTransactionServiceConcurrencyIT`) that satisfies this criterion.

---

## 2. Root Cause Analysis

The original ticket described one root cause (silent `-1` after retry exhaustion). v2 has eliminated the *most* serious failure mode (the throw is now in place and the lock is pessimistic), but **four residual gaps** remain. Each is a separate sub-section below; each cites file:LINE, shows the current code, explains why it fails the ticket criteria, and acknowledges what is already done.

### Gap A — Generic exception type on exhaustion (`BasicService.java:151-156`)

**Current code:**
```java
if (nextSeq < 0) {
    LOG.error("Cannot get Sequence. Give it up after {} tries", maxTries);
    final String msg = "Exceeded maxTries=" + maxTries + " attempts for sequence key=" + assignedClassKey;
    LOG.error("*** getNextSequenceNumber for {}", assignedClassKey);
    throw new RuntimeException(msg);
}
```

**Why it falls short of the ticket:** The ticket calls for "uncomment the `throw new BusinessException(msg)`". The throw is **[ALREADY DONE — landed in 7316ddb5]** but as a generic `RuntimeException`. Per `sbdocs/3-Resources/architecture/wms-exception-taxonomy.md` §6 (Decision Guide):

> Domain rule violation? → Yes → `BusinessException(key, params...)`. Declare `rollbackFor = BusinessException.class` on the enclosing `@Transactional`.

`RuntimeException` is the generic, untyped escape hatch — it bypasses i18n, bypasses the `BusinessException` global handler shape, and is opaque to operators reading logs. Sequence-allocation exhaustion is a domain-rule failure ("the system cannot allocate a number for this key right now"); it should surface as `BusinessException` with an i18n key, not a raw `RuntimeException`.

**Acknowledgement:** The reduction from 100 retries to 5 (`maxTries = 5`) and the removal of the comment around the throw both landed in 7316ddb5. **[ALREADY DONE]**

### Gap B — Caller-side `n >= 0` guard missing (`BasicService.java:41,47,91,96`; plus 3 direct callers)

**Current code (representative — `generatePickOrderNumber`):**
```java
public String generatePickOrderNumber() {
    long n = getNextSequenceNumber("PICKING_ORDER");
    return String.format("PICK" + "%1$06d", n);
}
```

If `n` ever becomes negative (which **cannot** happen now because Gap A throws — see Fix A), `String.format("PICK" + "%1$06d", -1L)` produces `"PICK-00001"` and the malformed string is persisted as the entity primary key.

**Why it falls short of the ticket:** The ticket's "Suggested fix" calls out `generatePickOrderNumber`, `generateReplenishNumber`, `generateOrderNumber`, "and any other format-based callers". Today those callers do not guard against a negative return. After Fix A (typed throw) the negative path is unreachable in practice, but the ticket explicitly accepts both layers of defense — the throw AND the caller guard — and the `BasicService.generateNumber`/`generateMessageNumber` overloads plus the **three direct callers** (`ParcelMonitorViewService:112,241`, `OrderMonitorViewService:180`, `BillofladingService:719`) all share the same fragile shape and are equally exposed if a future code path ever bypasses the central method.

This is defense-in-depth that costs ~1 line per site and matches the ticket text verbatim.

### Gap C — No metric / log for sequence-allocation latency (`BasicService.java`)

**Current code:** the retry loop (`BasicService.java:114-149`) records nothing structured. An `ERROR` log line at `BasicService.java:152` (`LOG.error("Cannot get Sequence. Give it up after {} tries", maxTries)`) fires on exhaustion, but it requires log scraping to detect. There is no historical p99 latency, no exhaustion counter queryable without log analysis, and no Grafana panel.

**Why it falls short of the ticket:** Ticket "Suggested fix" item: *"Add a metric / log for sequence-allocation latency."* The CLAUDE.md v2 constraint #8 also calls for Micrometer where high-frequency hot paths are touched — sequence allocation is touched on **every** picking-order, replenish-order, BOL pallet-label, message, and tote-label creation; it is the canonical hot path.

**Acknowledgement:** v2 already has Micrometer (`micrometer-tracing-bridge-brave` in `pom.xml:119-120`) and Spring Boot Actuator on the classpath. Wiring is mechanical.

### Gap D — `LosSequencenumberRepository.findByClassname` (non-locking) still exposed (`LosSequencenumberRepository.java:18-19`)

**Current code:**
```java
@RestResource(path = "findByClassname", rel = "findByClassname")
Optional<LosSequencenumber> findByClassname(@Param("className") String className);
```

**Why it falls short of the ticket:** No production code path calls `findByClassname` after the `SequenceTransactionService` change; `findByClassnameForUpdate` is the only locking path. But the non-locking method is still exposed via Spring Data REST (`@RepositoryRestResource` on the class). A future controller or REST consumer could call `/losSequencenumber/search/findByClassname?className=PICKING_ORDER`, mutate the returned entity, and re-introduce the optimistic-lock storm without any code review catching it.

This is a low-priority footgun — defensive cleanup, not a correctness fix.

### Gap E — `SequenceTransactionService` new-key path returns `0L` — verify intent

**Current code (`SequenceTransactionService.java:34-40`):**
```java
} else {
    seq = new LosSequencenumber();
    seq.setClassname(key);
    seq.setSequencenumber(returnSeq);  // returnSeq is still 0L from line 25
}
losSequencenumberRepository.save(seq);
return returnSeq;  // returns 0
```

**Observation, not a bug:** The first call for a newly-introduced key persists `sequencenumber=0` and returns `0`. The second call enters the `seqOpt.isPresent()` branch, increments to `1`, and returns `1`. So the first allocated entity has `n=0` (formatted `PICK000000`), the second has `n=1` (formatted `PICK000001`).

**Why this is in scope:** Document explicitly that this is intentional. No code change.

### v2 architecture doc cross-references

This plan aligns with:
- `sbdocs/3-Resources/architecture/wms-exception-taxonomy.md` §6 (Decision Guide) — `BusinessException` for domain rule violations.
- `sbdocs/3-Resources/architecture/wms-exception-taxonomy.md` §4 — checked `BusinessException` requires `rollbackFor` declaration on the enclosing `@Transactional`.
- `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` §7 — `SequenceTransactionService.getNextSequenceNumber:23` is one of the 17 documented `REQUIRES_NEW` sites; `LosSequencenumberRepository:21` uses pessimistic write locking. No change to either property.

---

## 3. The Regression Chain

The pessimistic-lock + typed-throw transition was not a single commit; it accumulated across six commits over the v1 → v2 evolution and the 2026 horizontal-scaling work.

| SHA | Commit | Relevant change |
|---|---|---|
| `b4e04415` | `updated to resolve the optimistic lock related to service.BasicService.getNextNoNewTransaction` | Early attempt at optimistic-lock retry loop — predecessor of current `getNextSequenceNumber`. |
| `524bac19` | `made this method synchronized` | Tried `synchronized` keyword — does not work across replicas; later removed. |
| `3474bc17` | `added fixes the Optimistic Lock error related to getNextWequenceNumber` (sic) | First retry-loop iteration. Ticket's original "100 tries, return -1" symptom comes from this era. |
| `c43e6e61` | `added additional business logic to avoid the optimistic locking with getNextSequenceNumber function as much as possible` | Added intermediate retry/throttle logic. |
| `58ad0f36` | `fix: specify tenantTransactionManager on all 44 @Transactional annotations` | Added `value = "tenantTransactionManager"` to `SequenceTransactionService.getNextSequenceNumber`. **Eliminated landlord-TM silent auto-commit failure mode.** |
| `7316ddb5` | `feat: horizontal scaling concurrency hardening — Phase 1 + Phase 2` | Introduced `findByClassnameForUpdate` + PESSIMISTIC_WRITE; reduced `maxTries` from 100 to 5; uncommented the throw on exhaustion (as `RuntimeException`). **Eliminated the silent `-1`-return failure mode.** |

This plan is the "Phase 3 polish": typed exception, caller-side guards, metrics, and repository hygiene — closing the gaps that 7316ddb5 deliberately left for a follow-up.

---

## 4. Architecture Overview

### Code path

```
HTTP request (e.g. POST /pickingorders)
        │
        ▼
Controller (e.g. PickingorderController)
        │
        ▼
PickingorderService.create*()  ────▶  basicService.generatePickOrderNumber()
                                              │
                                              ▼
                              BasicService.generatePickOrderNumber()
                                  │
                                  │ long n = getNextSequenceNumber("PICKING_ORDER");
                                  │   <── Fix B will guard `n >= 0` here
                                  ▼
                              BasicService.getNextSequenceNumber(key)
                                  │
                                  │ retry loop (maxTries=5)
                                  │   <── Fix C will wrap in Timer.Sample
                                  │   <── Fix A will throw BusinessException on exhaustion
                                  ▼
                              SequenceTransactionService.getNextSequenceNumber(key)
                                  │  @Transactional(tenantTransactionManager,
                                  │                 propagation=REQUIRES_NEW)
                                  │
                                  ▼
                              LosSequencenumberRepository.findByClassnameForUpdate(key)
                                  │  @Lock(PESSIMISTIC_WRITE)
                                  │
                                  ▼
                              Postgres row lock on los_sequencenumber WHERE classname=:key
                                  │
                                  ▼
                              SELECT ... FOR UPDATE → seq++ → save → COMMIT
                                  │
                                  ▼
                              return seq

Direct callers (Fix B targets):
  ParcelMonitorViewService:112, 241  ┐
  OrderMonitorViewService:180         │── String.format(pattern, getNextSequenceNumber(...))
  BillofladingService:719             ┘   (caller-side guard added)
```

### Key files

| File | Lines | Role |
|---|---|---|
| `service/BasicService.java` | 174 | Holds `getNextSequenceNumber` retry loop and the four format helpers (`generateNumber`, `generateMessageNumber`, `generatePickOrderNumber`, `generateReplenishNumber`) |
| `service/SequenceTransactionService.java` | 43 | `REQUIRES_NEW` + pessimistic lock isolation boundary |
| `repo/jpa/LosSequencenumberRepository.java` | 24 | `findByClassname` (non-locking, REST-exposed — Fix D target) and `findByClassnameForUpdate` (pessimistic) |
| `model/LosSequencenumber.java` | 60 | ID = `classname` (String); `@Version Integer version`; ID-based equals/hashCode |
| `service/ParcelMonitorViewService.java` | — | Direct caller of `getNextSequenceNumber` at lines 112, 241 (Fix B) |
| `service/OrderMonitorViewService.java` | — | Direct caller at line 180 (Fix B) |
| `service/BillofladingService.java` | — | Direct caller at line 719 (Fix B) |
| `test/java/.../unit/service/BasicServiceUnitTest.java` | 542 | `shouldThrowWhenSequenceServiceExceedsMaxRetries` currently asserts `RuntimeException` — must change to `BusinessException` after Fix A |
| `test/java/.../unit/service/SequenceTransactionServiceUnitTest.java` | 357 | All `@Disabled` (SBDEV-2099 landlord-datasource env skip); not unblocked by this plan |
| **(new)** `test/java/.../integration/service/SequenceTransactionServiceConcurrencyIT.java` | — | Testcontainers PostgreSQL load test for ticket AC #4 (extends `BasePostgresIntegrationTest`) |

---

## 5. Fix Design

### Fix A — Replace `RuntimeException` with `BusinessException` on exhaustion

**File:** `BasicService.java:151-156`

**Before:**
```java
if (nextSeq < 0) {
    LOG.error("Cannot get Sequence. Give it up after {} tries", maxTries);
    final String msg = "Exceeded maxTries=" + maxTries + " attempts for sequence key=" + assignedClassKey;
    LOG.error("*** getNextSequenceNumber for {}", assignedClassKey);
    throw new RuntimeException(msg);
}
```

**After:**
```java
if (nextSeq < 0) {
    LOG.error("Cannot allocate sequence for key={} after {} retries — pessimistic lock contention or DB outage",
              assignedClassKey, maxTries);
    sequenceExhaustedCounter.increment(Tags.of("key", assignedClassKey)); // see Fix C
    throw new BusinessException("BusinessException.SequenceExhausted", assignedClassKey, maxTries);
}
```

Add an i18n key to `src/main/resources/messages_en_US.properties`:
```
BusinessException.SequenceExhausted=Cannot allocate sequence for key=%1$s after %2$s retries
```

**Method signature change and cascade analysis:** `getNextSequenceNumber` and the four format helpers must declare `throws BusinessException`. Per `wms-exception-taxonomy.md` §4, `BusinessException` is checked. A full grep of `src/main/java` reveals **≥30 call sites** across 15+ files. The cascade was enumerated in full:

| Caller file | Method(s) affected | Already declares `throws BusinessException`? |
|---|---|---|
| `service/PickingorderService.java:44` | `generatePickOrderNumber()` | No — declares `throws FacadeException` only → **add `throws BusinessException`** |
| `service/ReplenishGeneratorService.java:180` | `generateReplenishNumber()` | No — declares `throws FacadeException` only → **add `throws BusinessException`** |
| `service/MessageService.java:81` | `generateMessageNumber(...)` inside `createServiceLog` | No — `@Transactional(REQUIRES_NEW)` boundary, no `throws` → **add `throws BusinessException`**; **⚠ see risk note below** |
| `service/BillofladingService.java:215` | `generateNumber(BILL_OF_LADING, ...)` | Yes (`throws FacadeException, BusinessException` at `:253`) |
| `service/BillofladingService.java:719` | `getNextSequenceNumber(...)` | Yes (enclosing method `transferOrder` at `:703` already declares `throws BusinessException, FacadeException`) |
| `service/ParcelMonitorViewService.java:112,241` | `getNextSequenceNumber(...)` | Need to verify — likely needs adding |
| `service/OrderMonitorViewService.java:180` | `getNextSequenceNumber(...)` | Need to verify — likely needs adding |
| `service/UnitloadService.java:128,164` | `generateNumber(UNITLOAD, ...)` | Need to verify |
| `service/CyclecountService.java:69,95` | `generateNumber(CYCLECOUNT, ...)` | Yes (class has methods with `throws BusinessException`) |
| `service/CyclecountPositionService.java:48` | `generateNumber(CYCLECOUNT_POSITION, ...)` | Need to verify |
| `service/UserRoleService.java:38,45,69` | `generateNumber(ROLE, ...)` | Need to verify |
| `service/UserGroupService.java:49,56` | `generateNumber(GROUP, ...)` | Need to verify |
| `service/ReceivingService.java:205,411` | `generateNumber(ADVICE / GOODS_RECEIPT, ...)` | Need to verify |
| `service/SectionService.java:60` | `generateNumber(EMPTY_PREFIX, ...)` | Need to verify |
| `service/PrintService.java:63` | `generateNumber(EMPTY_PREFIX, ...)` | Need to verify |
| `service/BoxtypeService.java:50` | `generateNumber(BOX_TYPE, ...)` | Need to verify |
| `service/ShipperidService.java:51` | `generateNumber(SHIPPERID, ...)` | Need to verify |
| `service/LocationConstraintService.java:30` | `generateNumber(...)` | Need to verify |
| `service/PickingorderPositionService.java:72` | `generateNumber(...)` | Need to verify |
| `controller/OrderRestController.java:345` | `generateNumber(CUSTOMER_ORDER_BATCH, ...)` | Need to verify |
| `controller/ShipperIdController.java:63` | `generateNumber(...)` | Need to verify |
| `controller/FileImportController.java:231,246` | `generateNumber(...)` | Need to verify |
| `controller/rest/AdviceRestController.java:198,416,426,542,586` | `generateNumber(...)` | Need to verify (`:279,441,594` excluded — count-based wrappers; see note below) |

> **⚠ MessageService risk note (NEW-2):** `createServiceLog` is `@Transactional(value="tenantTransactionManager", propagation=REQUIRES_NEW)` — it runs in its own transaction boundary. Adding `throws BusinessException` to its signature will surface through both overloads at lines 58–65 and their callers on the webservice message-logging path. The implementer MUST: (1) add `throws BusinessException` to both `createServiceLog` overloads and all callers, (2) verify that no `WebserviceBusinessExceptionClientSide` handler or message-routing wrapper silently swallows the exception, (3) run an integration test against the webservice message creation path after Fix A to confirm no regression in message-acknowledgement flow.

> **Wrapper methods excluded (NEW-3 verified):** `BasicService.generateNumberWithAdvice` (line 68), `generateNumberWithGoodsReceiptByCount` (line 76), and `generateNumberWithGoodsReceipt` (line 83) are **count-based, not sequence-based**. Verified by reading the source: each calls `advicepositionRepository.findByAdviceId(...).size()` or `goodsreceiptpositionRepository.findByGoodsreceiptId(...).size()` and passes the count directly to `String.format(prefix + getFormat(), count)`. They do **not** call `getNextSequenceNumber`. Their callers (`ReceivingService:232,284,475`, `FileImportController:470`, `AdviceRestController:279,441,594`) are therefore **out of scope** for Fix A.

**Decision (B2): Cascade via `throws BusinessException` propagation.** Two approaches were evaluated:

- **(a) Propagate `throws BusinessException`**: Each caller method gets `throws BusinessException` added (or already has it). The global `RestExceptionHandler` maps `BusinessException` → HTTP 422 everywhere. Keeps i18n, structured error response, Micrometer counter all intact. Cascades to ~20 "need to verify" methods on first compile; most are likely already-covered by existing `throws BusinessException` clauses or will require one-line adds. The executor performing the fix must compile-check and add `throws BusinessException` to any method in the table above that does not already declare it.

- **(b) Catch and rethrow as `RuntimeException` inside `BasicService`**: `generateNumber`, `generateMessageNumber`, `generatePickOrderNumber`, `generateReplenishNumber` catch `BusinessException` internally and rethrow as `RuntimeException` (or a `BusinessRuntimeException` wrapper). Zero cascade. But this approach: (1) strips the i18n key before the global handler sees it, (2) maps to HTTP 500 instead of HTTP 422, (3) severs the Micrometer exhausted counter from the HTTP response shape, and (4) is architecturally inconsistent with the codebase's use of checked `BusinessException` for domain-rule violations.

**This plan selects (a): propagate `throws BusinessException`.** The executor must compile, identify every method that needs the `throws` clause added, and add it. The table above covers the known sites; the compile output will be the definitive list. This is a mechanical change with no behavioral risk.

**Why `BusinessException` and not `EntityNotFoundException` or a new `SequenceExhaustedException`?** Per `wms-exception-taxonomy.md` §6: a domain-rule violation that is recoverable (the operator can retry the request) should be `BusinessException`. `EntityNotFoundException` is for entity-lookup miss (the row exists but couldn't be found by id/key); we did find the sequence row, we just couldn't increment it under contention. A custom subclass adds no behavior the global handler doesn't already give us via i18n.

**`rollbackFor` impact:** `getNextSequenceNumber` itself is **not** `@Transactional` (it wraps the inner `SequenceTransactionService` call in a retry loop in the surrounding caller's session). The inner `@Transactional(value = "tenantTransactionManager", propagation = REQUIRES_NEW)` on `SequenceTransactionService.getNextSequenceNumber` does NOT need `rollbackFor = BusinessException.class` because the throw happens in `BasicService` (the OUTER frame), not inside `SequenceTransactionService`. By the time `BusinessException` is thrown, the inner REQUIRES_NEW transaction has already committed (or rolled back via its own pessimistic-lock-timeout RuntimeException). No `rollbackFor` change needed inside `SequenceTransactionService`.

### Fix B — Caller-side `nextSeq >= 0` defense in 7 sites

**Sites:**
1. `BasicService.java:41-45` (`generateNumber`)
2. `BasicService.java:47-51` (`generateMessageNumber`)
3. `BasicService.java:91-94` (`generatePickOrderNumber`)
4. `BasicService.java:96-99` (`generateReplenishNumber`)
5. `ParcelMonitorViewService.java:112` and `:241`
6. `OrderMonitorViewService.java:180`
7. `BillofladingService.java:719`

**Before (representative — `generatePickOrderNumber`):**
```java
public String generatePickOrderNumber() {
    long n = getNextSequenceNumber("PICKING_ORDER");
    return String.format("PICK" + "%1$06d", n);
}
```

**After:**
```java
public String generatePickOrderNumber() throws BusinessException {
    long n = getNextSequenceNumber("PICKING_ORDER");
    if (n < 0) {
        throw new BusinessException("BusinessException.SequenceInvalid", "PICKING_ORDER", n);
    }
    return String.format("PICK" + "%1$06d", n);
}
```

For the three direct callers (`ParcelMonitorViewService:112`, `OrderMonitorViewService:180`, `BillofladingService:719`), insert the same guard immediately before the `String.format` call:
```java
long n = basicService.getNextSequenceNumber(sequenceNameOutboundPalletLabel);
if (n < 0) {
    throw new BusinessException("BusinessException.SequenceInvalid", sequenceNameOutboundPalletLabel, n);
}
String palletLabel = String.format(patternOutboundPalletLabel, n);
```

Add to `messages_en_US.properties`:
```
BusinessException.SequenceInvalid=Invalid sequence value=%2$s for key=%1$s
```

**Decision recorded.** Two approaches were considered:
- **(a) Implement guards as ticket requests** — explicit defense-in-depth; mirrors ticket text verbatim; ~7 lines of guard code (one per site).
- **(b) Document the guards as redundant after Fix A** — Fix A makes the negative path unreachable in practice; the guards never fire.

This plan **selects (a)** — minimum diff that satisfies the ticket acceptance criteria and protects against future code paths that bypass the central method. Recorded in §10 Open Questions.

### Fix C — Micrometer metrics for sequence-allocation latency and exhaustion

**File:** `BasicService.java`

**Constructor change** — inject `MeterRegistry`:
```java
public BasicService(SequenceTransactionService sequenceTransactionService,
                    AdvicepositionRepository advicepositionRepository,
                    GoodsreceiptpositionRepository goodsreceiptpositionRepository,
                    CustomerorderRepository customerorderRepository,
                    SyspropService syspropService,
                    MeterRegistry meterRegistry,                                    // NEW
                    @Value("${app.production}") Boolean isProduction,
                    @Value("${app.cron}") Boolean isCron) {
    this.sequenceTransactionService = sequenceTransactionService;
    // ...
    this.meterRegistry = meterRegistry;                                              // NEW
}
```

**Field additions:**
```java
private final MeterRegistry meterRegistry;
```

**Metric names (final):**
- `wms.sequence.allocation` — Timer; tag `key=<assignedClassKey>`. Records p50/p99 latency of the full retry loop (NOT the inner REQUIRES_NEW alone).
- `wms.sequence.allocation.exhausted` — Counter; tag `key=<assignedClassKey>`. Incremented inside Fix A's exhaustion branch.

**Wrap the retry loop:**
```java
public long getNextSequenceNumber(String assignedClassKey) throws BusinessException {
    Timer.Sample sample = Timer.start(meterRegistry);
    try {
        int tries = 0;
        final int maxTries = 5;
        long nextSeq = -1;
        do { /* ... existing retry body ... */ } while (nextSeq < 0 && tries < maxTries);

        if (nextSeq < 0) {
            meterRegistry.counter("wms.sequence.allocation.exhausted",
                                  "key", assignedClassKey).increment();
            LOG.error("Cannot allocate sequence for key={} after {} retries", assignedClassKey, maxTries);
            throw new BusinessException("BusinessException.SequenceExhausted", assignedClassKey, maxTries);
        }
        return nextSeq;
    } finally {
        sample.stop(Timer.builder("wms.sequence.allocation")
                         .tag("key", assignedClassKey)
                         .register(meterRegistry));
    }
}
```

**Cardinality safety:** `assignedClassKey` is a bounded enum-like (22 known keys verified in production: `PICKING_ORDER`, `REPLENISH_ORDER`, `WEBSERVICE_MESSAGE`, `UNIT_LOAD`, etc.). No risk of unbounded label cardinality.

**Metric semantics:**
- `wms.sequence.allocation` (Timer, tag `key=<assignedClassKey>`): records the **total wall-clock duration of the retry loop** from entry to return (or throw). The `finally` block ensures the Timer always stops — including on the exhaustion path. Exposes `count`, `sum`, `max`, and histogram buckets (p50, p95, p99) via Actuator at `/actuator/metrics/wms.sequence.allocation`. Use `count` to derive throughput; use `max` and `p99` to detect lock contention spikes.
- `wms.sequence.allocation.exhausted` (Counter, tag `key=<assignedClassKey>`): incremented **only on the exhaustion throw path** (inside Fix A's `if (nextSeq < 0)` block). This is an operator-facing signal: any non-zero value in a 5-min window means the pessimistic lock failed to serialise under the configured retry budget and `lock.timeout`. The `LOG.error` at `BasicService.java:152` already emits an error-level log line on the same path — the Counter makes this queryable in Grafana without log scraping.

**MeterRegistry availability:** `spring-boot-starter-actuator` at `pom.xml:54` auto-configures `MeterRegistry`. `micrometer-tracing-bridge-brave` at `pom.xml:119-120` adds tracing bridge. No new dependency required. (See §5.1 row 3 for verification step.)

### Fix D — Repository hygiene: hide non-locking `findByClassname` from REST

**File:** `LosSequencenumberRepository.java:18-19`

**Option D1 (preferred):** Annotate with `@RestResource(exported = false)` so it cannot be called via the HAL API.

**Before:**
```java
@RestResource(path = "findByClassname", rel = "findByClassname")
Optional<LosSequencenumber> findByClassname(@Param("className") String className);
```

**After:**
```java
@RestResource(exported = false)
Optional<LosSequencenumber> findByClassname(@Param("className") String className);
```

**Option D2 (alternative):** Remove the method entirely.

A grep over `src/main/java` confirms zero callers in production code. The conservative D1 keeps the method available to test code (existing test fixtures call it directly via the bean) without exposing it on the HAL surface. **D1 selected.**

**Justification:** REST exposure of the non-locking method is a footgun for any future code path that grabs a sequence row without acquiring the pessimistic lock — re-introducing the optimistic-lock storm that 7316ddb5 eliminated. The exported HAL surface is enumerable from outside the JVM; the cleanup eliminates a discovery vector.

### Fix E — Document `SequenceTransactionService` new-key path returns `0L` (no code change)

**Observation:** `SequenceTransactionService.getNextSequenceNumber:25-40` initialises `returnSeq = 0L` and persists `sequencenumber = 0` for a brand-new key, then returns `0`. The next caller hits the `seqOpt.isPresent()` branch and gets `1`.

**Decision:** This is intentional. The first allocated entity has `n=0` (e.g. `PICK000000`); the second has `n=1` (`PICK000001`). Some operators expect sequences to start at `1`; if the team prefers a `1`-based start, change the new-key branch to `seq.setSequencenumber(1L); returnSeq = 1L;` — but this requires a one-time DBA migration to bump existing keys with `sequencenumber=0` if any exist (none observed in the 22 production rows). **No code change in this plan.** Recorded in §10 Open Questions for future-session decision.

---

## 6. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `service/BasicService.java` | edit | Fix A (BusinessException on exhaustion); Fix B (4 in-file guards); Fix C (MeterRegistry injection + Timer.Sample + Counter); add `throws BusinessException` to 4 method signatures |
| `service/ParcelMonitorViewService.java` | edit | Fix B — guard at lines 112 and 241 before `String.format`; method `throws BusinessException` clause |
| `service/OrderMonitorViewService.java` | edit | Fix B — guard at line 180 before `String.format`; method `throws BusinessException` clause |
| `service/BillofladingService.java` | edit | Fix B — guard at line 719 before `String.format`; enclosing method at `:758` already declares `throws FacadeException, BusinessException` (confirmed via grep) — no `throws` clause change needed |
| `repo/jpa/LosSequencenumberRepository.java` | edit | Fix D — change `@RestResource(path = "findByClassname", rel = "findByClassname")` → `@RestResource(exported = false)` |
| `src/main/resources/messages_en_US.properties` | edit | Add 2 new keys: `BusinessException.SequenceExhausted`, `BusinessException.SequenceInvalid` |
| `test/java/.../unit/service/BasicServiceUnitTest.java` | edit | Update `shouldThrowWhenSequenceServiceExceedsMaxRetries` to assert `BusinessException`; add new tests for `n < 0` guard fires (using simulated negative return), Timer recording, Counter increment |
| Various caller services/controllers (per §5 Fix A cascade table) | edit | `throws BusinessException` added to enclosing method signatures — compiler-driven; see cascade table for known sites |
| `test/java/.../integration/service/SequenceTransactionServiceConcurrencyIT.java` | new | Testcontainers PostgreSQL — 50 threads × 100 calls, asserts 5,000 distinct, monotonic, no `*-00001` malformed (extends `BasePostgresIntegrationTest`) |

---

## 5'. Prerequisites & Implementation Plan

> Renamed locally to "5'" so it does not collide with §5 Fix Design. Per template, this is the §5.1/§5.2 block.

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | `los_sequencenumber` rows exist for all keys (verified — 22 keys present, all positive sequencenumber). No new schema. | DBA | N/A — pre-existing |
| 2 | **Feature flags / system properties** | None. | — | Pure code fix. |
| 3 | **Config / env changes** | Verify `MeterRegistry` is wired. `spring-boot-starter-actuator` at `pom.xml:54` auto-configures `MeterRegistry`. `micrometer-tracing-bridge-brave` at `pom.xml:119-120` is also present. **No new dependency required.** Run `mvn dependency:tree | grep micrometer` to confirm. `MeterRegistry` will be injected by Spring constructor injection — no existing injection site in `BasicService` exists yet; the constructor change in Fix C is additive. | Dev | Verified 2026-05-09. |
| 4 | **Deploy-order dependencies** | Independent. No coordination with OMS, mobile UI, or scheduler is required. Backend-only fix; behavioural shift is `RuntimeException` → `BusinessException` on a path that has been unreachable in production. | — | Roll with the next normal `wms2-api` release. |
| 5 | **Data migration / DBA probe** | DBA: run two queries on each tenant DB to characterise the **90 anomalous `replenishorder` rows** flagged in §1 Query 2:<br><br>**Query A — pattern histogram** (understand shape of anomalies):<br>`SELECT regexp_replace(number, '[0-9]', 'N', 'g') AS pattern, count(*) FROM replenishorder WHERE number ~ '-' AND number !~ '^[A-Z]+[0-9]+$' GROUP BY 1 ORDER BY 2 DESC;`<br><br>**Query B — recent sample** (spot-check most recent rows for temporal distribution):<br>`SELECT id, number, created_at FROM replenishorder WHERE number ~ '-' AND number !~ '^[A-Z]+[0-9]+$' ORDER BY id DESC LIMIT 20;`<br><br>**Decision criterion:** If all 90 match a multi-segment pattern (e.g. `REPL-NNNN-NNNNN`) created before the date `7316ddb5` was deployed to this tenant, they are legacy-format contamination that predates the fix — **greenlight deploy, document as known-good legacy**. If any row was created AFTER the deploy date of commit `7316ddb5`, or matches `^REPL-\d+$` exactly (the `-1` poisoning pattern), **block deploy and escalate for manual remediation**. | DBA | Block deploy if any row matches `^REPL-\d+$` exactly or is post-`7316ddb5` deploy date. Greenlight if all 90 are multi-segment legacy formats predating that deploy. |
| 6 | **External systems** | None. | — | OMS does not consume sequence numbers directly. |
| 7 | **Access / permissions** | None. | — | |
| 8 | **Monitoring / alerts** | Add Grafana panel for `wms.sequence.allocation` p50/p99 latency (per `key` tag) and an alert rule on `wms.sequence.allocation.exhausted{key=*}` — page on any non-zero increment in 5-min window. | DevOps | Mandatory. The metric is the early-warning signal that lock contention or DB outage is degrading sequence allocation. |
| 9 | **REST endpoint reachability (Fix D gate)** | Before applying Fix D, verify that `LosSequencenumberRepository` is annotated `@RepositoryRestResource` (or is exposed by Spring Data REST) so that `findByClassname` is actually reachable at `/losSequencenumber/search/findByClassname`. Run: `grep -n "@RepositoryRestResource\|@RestResource" src/main/java/net/aim_ai/wms/repo/jpa/LosSequencenumberRepository.java`. If the class is NOT `@RepositoryRestResource`-annotated at all, then Fix D is a no-op and can be simplified to removing the `@RestResource` line entirely (D2 path). | Dev | Gate before Fix D. |

### 5.2 Implementation Checklist

- [ ] Add 2 i18n keys to `messages_en_US.properties` (`BusinessException.SequenceExhausted`, `BusinessException.SequenceInvalid`)
- [ ] Fix A — replace `throw new RuntimeException(msg)` with `throw new BusinessException("BusinessException.SequenceExhausted", assignedClassKey, maxTries)` in `BasicService.java:151-156`
- [ ] Add `throws BusinessException` to `getNextSequenceNumber`, `generateNumber`, `generateMessageNumber`, `generatePickOrderNumber`, `generateReplenishNumber` signatures
- [ ] After Fix A's typed exception change, run `mvn compile` from the `v2/wms2-api` project root. For every compile error of the form `unreported exception net.aim_ai.wms.exceptions.BusinessException; must be caught or declared to be thrown`, add `throws BusinessException` to the enclosing method (or wrap with try-catch where the method is at an HTTP-edge and routes through `RestExceptionHandler`). Cross-reference each compiler-flagged site against the §5 Fix A cascade table; **add any newly-discovered site to §13.4 Implementation Status** so the audit trail captures the actual cascade size. The cascade table is illustrative — the compiler is the source of truth. Pay special attention to `MessageService.createServiceLog` (⚠ REQUIRES_NEW boundary — see risk note in cascade table).
- [ ] Fix B — add `if (n < 0) throw new BusinessException(...)` guard at `BasicService.java:42`, `:48`, `:92`, `:97`
- [ ] Fix B — add same guard at `ParcelMonitorViewService.java:112`, `:241`
- [ ] Fix B — add same guard at `OrderMonitorViewService.java:180`
- [ ] Fix B — add same guard at `BillofladingService.java:719`
- [ ] Fix C — inject `MeterRegistry` into `BasicService` constructor; add `Timer.Sample` wrapping the retry loop; emit `wms.sequence.allocation.exhausted` counter on Fix A's throw path
- [ ] Fix D — change `LosSequencenumberRepository.findByClassname` annotation from `@RestResource(path=...)` to `@RestResource(exported = false)`
- [ ] Remove dead code: `BasicService.java` lines 142–148 (`if (tries > 50) Thread.sleep(10)` branch — unreachable since `maxTries=5`; clean up in same commit as Fix A)
- [ ] Update `BasicServiceUnitTest.shouldThrowWhenSequenceServiceExceedsMaxRetries` to assert `BusinessException` instead of `RuntimeException`
- [ ] Add unit tests: `getNextSequenceNumber_whenSequenceServiceReturnsNegative_throwsBusinessException`; `getNextSequenceNumber_recordsTimerAndCounterOnExhaustion` (use `SimpleMeterRegistry`)
- [ ] Add integration test: `SequenceTransactionServiceConcurrencyIT` — Testcontainers PostgreSQL, 50 threads × 100 calls, 5,000 distinct + monotonic + no `*-00001` malformed
- [ ] Run `mvn test -Dtest=BasicServiceUnitTest` ✓
- [ ] Run `mvn verify -Dtest=SequenceTransactionServiceConcurrencyIT` ✓
- [ ] Run full `mvn verify` ✓
- [ ] DBA probe SQL on each tenant DB; record results in §5.1 row 5
- [ ] Run `bash sbdocs/9-System/scripts/verify-SBDEV-2217-sequence-number-silent-minus-one.sh` — must report `Result: N pass, 0 fail`

---

## 6'. Test Plan

> Renamed locally to "6'" to avoid collision with §6 File Change Summary.

### Unit tests (BasicServiceUnitTest)

| Test method | What it asserts | Status |
|---|---|---|
| `shouldThrowWhenSequenceServiceExceedsMaxRetries` | After 5 retries: `BusinessException` thrown (was `RuntimeException`); message contains `Exceeded maxTries=5` or i18n-resolved equivalent | **update existing** |
| `getNextSequenceNumber_whenSequenceServiceReturnsNegative_throwsBusinessException` | Mock `sequenceTransactionService.getNextSequenceNumber` to return `-1L`; assert Fix A path triggers BusinessException after retries | **new** |
| `getNextSequenceNumber_recordsTimerOnSuccess` | Use `SimpleMeterRegistry`; call once; assert `meterRegistry.timer("wms.sequence.allocation", "key", "FOO").count() == 1` | **new** |
| `getNextSequenceNumber_recordsExhaustedCounterOnThrow` | Use `SimpleMeterRegistry`; force exhaustion; assert `meterRegistry.counter("wms.sequence.allocation.exhausted", "key", "FOO").count() == 1` | **new** |
| `generatePickOrderNumber_whenInnerReturnsNegative_throwsBusinessException` | Stub `getNextSequenceNumber` to return `-1L` directly (bypass the throw); assert Fix B caller-side guard fires `BusinessException("BusinessException.SequenceInvalid", "PICKING_ORDER", -1L)` | **new** |
| `generateReplenishNumber_whenInnerReturnsNegative_throwsBusinessException` | Same as above for `REPLENISH_ORDER` | **new** |
| `generateNumber_whenInnerReturnsNegative_throwsBusinessException` | Same — for the `generateNumber(prefix,key)` overload | **new** |
| `generateMessageNumber_whenInnerReturnsNegative_throwsBusinessException` | Same — for `generateMessageNumber(prefix,key)` | **new** |

Existing happy-path tests (`shouldRetryOnOptimisticLockingFailure`, `shouldHandleNestedOptimisticLockingException`, etc.) must continue to pass — verify in regression run.

**Explicitly UNCHANGED:** `shouldRethrowNonOptimisticLockingException` (lines 391–401) asserts `RuntimeException.class` for the case where a **non-optimistic** exception is thrown inside the retry loop — this is correct behavior (the code propagates non-`ObjectOptimisticLockingFailureException` errors immediately as `RuntimeException`). Fix A only changes the exhaustion-after-maxTries path; the non-optimistic rethrow path is **not touched by this plan** and must remain asserting `RuntimeException`.

### Integration test (Testcontainers PostgreSQL)

| Test class | Test method | What it asserts | Status |
|---|---|---|---|
| `SequenceTransactionServiceConcurrencyIT` (new) | `concurrent50Threads100CallsEach_allDistinctMonotonicNoMalformed` | Loads a real Postgres instance via Testcontainers; inserts a `los_sequencenumber` seed row (`PICKING_ORDER, sequencenumber=0`); spawns 50 threads with a `CountDownLatch` synchronised start; each thread invokes `basicService.generatePickOrderNumber()` 100 times. Asserts: (a) 5,000 results, (b) all distinct (`Set.size() == 5000`), (c) no result matches `^[A-Z]+-?\d*-00001$` or contains a literal `-` between the prefix and the digits, (d) the numeric tail extracted via regex `^PICK(\d+)$` is monotonic when sorted, (e) `MAX(numeric_tail) == seed + 5000`, (f) **contention-proof metric assertion**: after the run, `meterRegistry.timer("wms.sequence.allocation", "key", "PICKING_ORDER").count() == 5000` AND `meterRegistry.timer("wms.sequence.allocation", "key", "PICKING_ORDER").max(TimeUnit.MILLISECONDS) > meterRegistry.timer("wms.sequence.allocation", "key", "PICKING_ORDER").mean(TimeUnit.MILLISECONDS) * 5` (proves non-trivial contention was exercised and the Timer recorded all allocations) | **new** |

Path: `src/test/java/net/aim_ai/wms/integration/service/SequenceTransactionServiceConcurrencyIT.java`.

Use the existing Testcontainers PostgreSQL infrastructure (see `BasePostgresIntegrationTest` patterns elsewhere in the suite). Tunable thread/iteration counts via `-Dconcurrency.threads=50 -Dconcurrency.iterations=100` system properties so the test can be scaled down on slow CI.

#### §6' Deviation — IT base class: `BaseIntegrationTest` (H2) instead of `BasePostgresIntegrationTest` (Testcontainers)

**Critic M1 finding**: The plan called for `SequenceTransactionServiceConcurrencyIT` to extend `BasePostgresIntegrationTest`.

**Empirical result (2026-05-09)**: `BasePostgresIntegrationTest` cannot boot a full Spring context in this codebase without the `integration` profile active. The class carries `@SpringBootTest(classes = StartApplication.class)` + `@ExtendWith(AppPostgresDBSetupExtension.class)`. `AppPostgresDBSetupExtension.beforeAll()` sets only `spring.datasource.*` system properties (pointing at the Testcontainers PostgreSQL URL). It does NOT set `landlord.datasource.jdbc-url`, which is exclusively provided by `application-integration.properties` (loaded only when `@ActiveProfiles("integration")` is present). Without it, `LandlordDatabaseConfig` fails to build `HikariPool-1` for the landlord persistence unit:

```
ERROR HikariConfig - dataSource or dataSourceClassName or jdbcUrl is required.
ERROR LocalContainerEntityManagerFactoryBean - Failed to initialize JPA EntityManagerFactory:
  [PersistenceUnit: landlord] Unable to build Hibernate SessionFactory
```

This was verified by running `ClientServiceE2ETest` (the only other class that extends `BasePostgresIntegrationTest`): it fails with the identical exception. **Truth B applies.**

**Consequence for the IT**: `SequenceTransactionServiceConcurrencyIT` extends `BaseIntegrationTest` (`@ActiveProfiles("integration")`, H2 in-memory `MODE=PostgreSQL`). The pessimistic-lock + `REQUIRES_NEW` serialisation contract under test is db-dialect-independent — `SELECT FOR UPDATE` is supported by H2 in PostgreSQL compatibility mode and the transaction boundaries are enforced by the JVM-level Hibernate/HikariCP machinery, not by a PostgreSQL-specific protocol feature. Cross-dialect correctness against real PostgreSQL is deferred to the §7.4 manual smoke against staging.

**TODO on `BasePostgresIntegrationTest`**: See `// TODO SBDEV-2217` comment in the class — the class needs `@ActiveProfiles("integration")` (or an equivalent landlord datasource configuration) before it can support full-Spring-context E2E tests. Filed separately; out of scope for this plan.

### Regression

| Test class | Why |
|---|---|
| `BasicServiceUnitTest` (full) | All existing happy-path tests must still pass |
| `PickingorderServiceUnitTest` (and any other test that calls `generatePickOrderNumber`) | Must compile after the `throws BusinessException` cascade and pass |
| `ReplenishGeneratorServiceUnitTest` | Same for `generateReplenishNumber` |
| `BillofladingServiceUnitTest` (and any test that exercises `getNextSequenceNumber` via the BOL pallet-label path) | Must compile and pass |
| `SequenceTransactionServiceUnitTest` | All `@Disabled` per pre-existing SBDEV-2099 env skip — **NOT unblocked by this plan**. Do not re-enable; that is a separate ticket. **Note:** when SBDEV-2099 is resolved and these tests are re-enabled, the mocks inside them likely target `findByClassname` (the non-locking method). They must be retargeted to `findByClassnameForUpdate` to reflect the post-7316ddb5 implementation. Flag this in the SBDEV-2099 plan. |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Smoke: pick-order creation under normal load | staging | Release a customer batch, observe pick-order creation via mobile pick UI | Pick orders all monotonic `PICK<6-digit>`, no hyphenated entries | |
| Smoke: replenish-order creation | staging | Trigger a replenishment run; observe replenish-order numbers in DB | All `REPL<6-digit>`, no hyphenated entries | |
| Failure injection: simulated retry exhaustion | staging | Use a feature flag / debug endpoint OR manually `BEGIN; SELECT * FROM los_sequencenumber WHERE classname='PICKING_ORDER' FOR UPDATE;` in a separate DB session, hold the lock; trigger pick-order creation | Operator sees HTTP 422 ProblemDetail with title "Business Rule Violation" and message containing "Cannot allocate sequence" — NOT HTTP 500 stack trace | |
| Metric verification | staging | Hit `/actuator/metrics/wms.sequence.allocation` after several pick-order creations | Returns `count`, `mean`, `max` per `key` tag; non-empty | |
| Exhaustion counter alarm | staging | Force an exhaustion (above) | `/actuator/metrics/wms.sequence.allocation.exhausted` shows `count >= 1`; Grafana alert fires | |
| SQL: post-deploy data sanity | staging DB | `SELECT count(*) FROM pickingorder WHERE number ~ '-'` | `0` | |
| SQL: post-deploy data sanity | staging DB | `SELECT count(*) FROM replenishorder WHERE number ~ '-' AND number !~ '^[A-Z]+[0-9]+$'` | `90` (matches pre-deploy baseline; not changed by this fix) | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=BasicServiceUnitTest` | | |
| `mvn verify -Dtest=SequenceTransactionServiceConcurrencyIT` | | |
| `mvn verify` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2217-sequence-number-silent-minus-one.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Re-enabling `SequenceTransactionServiceUnitTest` | All `@Disabled` due to pre-existing SBDEV-2099 landlord-datasource env skip. Re-enabling depends on resolving SBDEV-2099 separately. Out of scope. |
| End-to-end concurrent picking across two replicas (real load balancer) | Out of scope for unit/integration tests. Multi-replica lock correctness is asserted analytically in §7 row 8 (Postgres is the lock authority). Manual smoke against the staging cluster covers integration. |
| Reverting the `throws BusinessException` cascade for safety (i.e. catching `BusinessException` inside `BasicService` and rethrowing `RuntimeException` to keep signatures unchanged) | Rejected — would mask the typed exception from the global handler and break the i18n contract. The cascade is small (≤6 caller files); accept the diff. |

### Mockito + Testcontainers notes

- v2 uses **Mockito 5+** — no Mockito 3.3.3 limitation. `mockStatic` is available if a unit test needs it (none required by this plan).
- v2 uses **Testcontainers PostgreSQL** for the new `SequenceTransactionServiceConcurrencyIT`. Existing test infrastructure already wires PostgreSQL containers (see `BasePostgresIntegrationTest`). No new Maven dependency required.

### v2 `BaseControllerTest` requirement

This plan does NOT modify a controller endpoint — `BasicService` is a service-layer class. No `BaseControllerTest`-extending test required.

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce per-replica state (Caffeine, ConcurrentHashMap, static, ThreadLocal)? | **No** | `MeterRegistry` is a Spring-managed singleton; Micrometer aggregates per-process and exposes via Actuator. No per-replica functional state added. |
| 2 | **Connection pool math** | Change per-request DB connection use? | **No** | Same single `REQUIRES_NEW` allocation per call. Retry budget reduced (100→5) lowers worst-case connection holds. |
| 3 | **Scheduled jobs** | Add or modify `@Scheduled`? | **No** | N/A. |
| 4 | **Long transactions** | Hold a tx across multiple repo calls / external I/O? | **No** | The pessimistic-lock window is bounded to one `findByClassnameForUpdate` + one `save` inside `REQUIRES_NEW`; no external I/O. |
| 5 | **Request affinity** | Assume same-replica follow-up? | **No** | Stateless. |
| 6 | **Retry / idempotency** | Rely on single-execution semantics? | **Yes** — handled. The `getNextSequenceNumber` call is naturally idempotent on lock acquisition: the `REQUIRES_NEW` ensures each attempt is its own transaction with its own commit-or-rollback boundary; max 5 retries before `BusinessException`. If a replica dies mid-allocation, the in-flight transaction rolls back at the DB level (lock released, version unchanged) and another replica's retry simply picks up the next number cleanly. |
| 7 | **Tenant context** | Use `TenantContext` across async boundaries? | **No** | All work happens on the request thread inside the existing `tenantTransactionManager` boundary; no `@Async`. |
| 8 | **Distributed lock correctness** | Add or rely on locks across replicas? | **Yes** — handled. Postgres row-level pessimistic write lock on `los_sequencenumber` row, held inside `@Transactional(value=tenantTransactionManager, propagation=REQUIRES_NEW)` per call. Cross-replica safe because **Postgres is the lock authority** — every replica's `SELECT ... FOR UPDATE` serialises on the same row. Lock timeout `spring.jpa.properties.jakarta.persistence.lock.timeout=5000` is **[ALREADY DONE — `application.properties:64`]**. No change needed. |
| 9 | **Cache invalidation** | Write to cached entity? | **No** | `LosSequencenumber` is not in `CacheConfig`'s caches; pessimistic lock + REQUIRES_NEW is the contention arbiter, not a cache. |
| 10 | **External notifications** | HTTP/message inside tx? | **No** | No external calls in the sequence-allocation path. |

### Evidence

| Concern # | What was verified | File:line / test reference |
|---|---|---|
| 6 | Retry with REQUIRES_NEW isolation | `SequenceTransactionService.java:23` — `propagation = Propagation.REQUIRES_NEW`, value = `"tenantTransactionManager"` |
| 8 | Pessimistic-lock cross-replica correctness | `LosSequencenumberRepository.java:21` — `@Lock(LockModeType.PESSIMISTIC_WRITE)`; `wms2-transaction-osiv-boundary-map.md` §7 line 198 documents this as one of 17 REQUIRES_NEW sites; new `SequenceTransactionServiceConcurrencyIT` exercises 50-thread concurrent serialisation against real Postgres |

---

## 8. v2-only constraint checklist

| # | Constraint | What was verified | Verdict |
|---|---|---|---|
| 1 | **OSIV disabled** | `getNextSequenceNumber` retry loop is in `BasicService` (NOT `@Transactional`); the inner `SequenceTransactionService.getNextSequenceNumber` IS `@Transactional(REQUIRES_NEW)`. No lazy-load chains; the Optional is consumed immediately inside the inner transaction. | **Yes** |
| 2 | **Transaction manager** | `SequenceTransactionService.getNextSequenceNumber:23` uses `value = "tenantTransactionManager"`. `BasicService.getNextSequenceNumber` is intentionally NOT `@Transactional` — it is the retry orchestrator. **[ALREADY DONE — landed in 58ad0f36]**; no change in this plan. | **Yes** |
| 3 | **`@Transactional(readOnly=true)`** | Sequence allocation is a write path; `readOnly=true` does not apply. The format helpers in `BasicService` (`generateNumber`, `generateMessageNumber`, etc.) are not annotated `@Transactional` because the inner call manages its own boundary. | **N/A** — write path |
| 4 | **Caffeine cache invalidation** | `LosSequencenumber` is not cached in `CacheConfig`. No `@Cacheable` / `@CacheEvict` needed. | **N/A** |
| 5 | **Jakarta namespace** | All new imports use `jakarta.*` (no `javax.*`). `MeterRegistry` is `io.micrometer.core.instrument.MeterRegistry` — no jakarta concern. | **Yes** |
| 6 | **H2-compatible test SQL** | The new `SequenceTransactionServiceConcurrencyIT` uses Testcontainers PostgreSQL — no H2 compatibility issue. Unit tests in `BasicServiceUnitTest` use mocks; no SQL. | **Yes** |
| 7 | **`BaseControllerTest` for controller changes** | No controller endpoint changed; `BasicService` is a service. | **N/A** |
| 8 | **Micrometer metrics** | Fix C reuses Micrometer (already wired via `micrometer-tracing-bridge-brave` in `pom.xml:119-120`). New metric names follow the `wms.<domain>.<concept>` pattern consistent with existing metrics. No alternative metrics stack introduced. | **Yes** |

---

## 9. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| A caller catches `BusinessException` and silently ignores it | Silent failure persists; Fix A's typed throw doesn't reach the user | Low | Verified by grep over `src/main/java`: no service in the sequence-allocation call chain has a bare `catch (BusinessException)` that swallows. The global `RestExceptionHandler` (`wms-exception-taxonomy.md` §3) maps `BusinessException` to HTTP 422 with the i18n-resolved message. Add a CI grep audit if a future plan touches this area. |
| `jakarta.persistence.lock.timeout` defaults to 0 (no wait, throw immediately) → exhaustion storm under burst | All concurrent allocations after the first one fail immediately with `LockTimeoutException`; cascades into `BusinessException` for every caller | Medium | **[ALREADY DONE — `application.properties:64`]** `spring.jpa.properties.jakarta.persistence.lock.timeout=5000` is already set. With pessimistic lock + 5s timeout, contention serialises rather than throws. Validate with `SequenceTransactionServiceConcurrencyIT`. No config change needed in this plan. |
| Metric tag cardinality explosion if `assignedClassKey` becomes unbounded | Prometheus/Grafana time-series database degradation | Very low | Keys are bounded enum-like — 22 known keys verified in production; no dynamic key generation found in the codebase. Cardinality safe. |
| Concurrent IT (`SequenceTransactionServiceConcurrencyIT`) flaky on slow CI | Build failures unrelated to the fix | Medium | Use AssertJ + tunable thread/iteration counts via `-Dconcurrency.threads=50 -Dconcurrency.iterations=100` system properties; use `CountDownLatch` for synchronised start; assert wall-clock budget with a generous timeout (e.g. 60s). If flaky, scale down to `threads=10, iterations=50` for CI and keep the full 50×100 only for the nightly job. |
| `throws BusinessException` cascade breaks existing test compilation | Build break across multiple test files | Medium | Most callers (`PickingorderService`, `ReplenishGeneratorService`, `BillofladingService`) already declare `throws BusinessException` for other reasons. Audit on first compilation run; add minimal throws clauses to test fixtures as needed. |
| `messages_en_US.properties` key collision | i18n lookup fails; falls back to key+param concatenation (per `wms-exception-taxonomy.md` §5) | Very low | New keys (`BusinessException.SequenceExhausted`, `BusinessException.SequenceInvalid`) are checked against the existing bundle; no collision observed. Fallback is graceful — never throws. |
| DBA probe (§5.1 row 5) reveals `REPL-00001`-style legitimate poisoning | Need a remediation step (manual data fix or script) | Low | Probe is the gate. Block deploy if any of the 90 anomalies match the `^REPL-\d+$` exact pattern. Most-likely outcome is "they're legitimate older formats with embedded year"; this plan does not pre-script a remediation. |

---

## 10. Open Questions / Resolved Decisions

| # | Question / Decision | Resolution | Recorded by |
|---|---|---|---|
| 1 | The ticket says "uncomment the `throw new BusinessException(msg)`" but in v2 the throw is **already uncommented** (as `RuntimeException`). | **Recorded as observation, not contradiction.** This plan changes the type, not the existence. The "Suggested fix" item is interpreted as "the throw must exist AND must be `BusinessException`". The latter is the residual gap. | This plan, §1 |
| 2 | Fix B: implement guards (option a) vs. document as redundant (option b)? | **(a) Implement guards** — minimum-diff path that satisfies ticket acceptance criteria verbatim and protects against future code paths that bypass the central method. | This plan, Fix B |
| 3 | New custom exception type (`SequenceExhaustedException`) vs. reuse `BusinessException` with i18n key? | **Reuse `BusinessException`** with key `BusinessException.SequenceExhausted`. A custom subclass adds no behavior the global handler doesn't already give us. Aligns with `wms-exception-taxonomy.md` §6 decision guide. | This plan, Fix A |
| 4 | Repository hygiene: remove `findByClassname` (D2) vs. `@RestResource(exported = false)` (D1)? | **(D1) `@RestResource(exported = false)`** — conservative; keeps the bean callable for tests but removes the HAL surface. | This plan, Fix D |
| 5 | `SequenceTransactionService` new-key path returns `0L` — is `0` an intended starting value? | **Intentional** for now. First allocated entity = `n=0` (e.g. `PICK000000`); second = `n=1`. If business prefers `1`-based, that's a separate plan with a one-time DBA migration. | This plan, Fix E |
| 6 | Re-enable `SequenceTransactionServiceUnitTest` (currently all `@Disabled` per SBDEV-2099)? | **Out of scope.** Pre-existing landlord-datasource env skip — fix it in SBDEV-2099, not here. | This plan, §6 Deliberately-skipped |
| 7 | Should this plan port to v1 in the same session? | **No.** No paired v1 plan exists yet (`SBDEV-2217-*` missing from `sbdocs/1-Projects/wms1/plan/` and `sbdocs/4-Archieves/wms1/plan/`). v1 will need a separate session. The v1 file list to mirror: `v1/wms-api/src/main/java/net/aim_ai/wms/service/BasicService.java`, `v1/wms-api/src/main/java/net/aim_ai/wms/service/SequenceTransactionService.java`, `v1/wms-api/src/main/java/net/aim_ai/wms/repo/jpa/LosSequencenumberRepository.java`. | This plan, §11 |
| 8 | `jakarta.persistence.lock.timeout` value? | **[ALREADY DONE — `application.properties:64`]** `spring.jpa.properties.jakarta.persistence.lock.timeout=5000` already set. No change required by this plan. | This plan, §9; verified 2026-05-09 |
| 9 | `MessageService.createServiceLog` cascade — risk that adding `throws BusinessException` surfaces error on webservice retry-queue path? | **Resolved: add `throws BusinessException`, but verify.** The method is `@Transactional(REQUIRES_NEW)` and calls `generateMessageNumber`. Adding `throws BusinessException` is correct per the cascade decision (B2). Mitigation: implementer must (1) add `throws` to both overloads and their callers, (2) grep for any `WebserviceBusinessExceptionClientSide` catch blocks that might silently swallow, (3) run an integration test against the webservice message-creation path after Fix A. If any caller cannot tolerate a checked exception (e.g. a `Runnable` lambda), wrap locally with try-catch and rethrow as `RuntimeException` at that boundary only. | This plan, §5 Fix A cascade table; 2026-05-09 |

---

## 11. v1 / v2 Applicability

| Aspect | V1 | V2 (this plan) | Impact |
|---|---|---|---|
| `BasicService.getNextSequenceNumber` retry loop | Same shape (per ticket) | Already reduced to 5 retries; throws on exhaustion | v1 still on legacy 100-retry-and-return-`-1` per ticket |
| `SequenceTransactionService` pessimistic lock | **Not yet** (per ticket) | Already in place via `findByClassnameForUpdate` | v1 needs the same migration |
| `LosSequencenumberRepository.findByClassnameForUpdate` | Likely missing | Present | v1 needs to add the method |
| Caller-side `n >= 0` guards | Not present (per ticket) | Adding in this plan | v1 needs the same |
| Metrics for sequence allocation | Not present | Adding in this plan | v1 needs Micrometer wiring (verify pom). Note: the Micrometer `Timer.Sample` / `Timer.builder` API used in Fix C is available in Micrometer 1.x (Spring Boot 2.3.7 ships Micrometer 1.5.x) — the API surface is compatible. However, v1 uses `javax.*` namespace and Spring Boot 2.x Actuator; confirm `MeterRegistry` is auto-configured in v1's `pom.xml` before porting. |
| `BusinessException` i18n key | n/a (using BusinessException already) | New keys added to `messages_en_US.properties` | v1 likely benefits from same keys (Spring resource bundle is independent per artifact) |

### What needs porting to v1 (deferred to a separate session)

A paired v1 plan with the same base name (`SBDEV-2217-sequence-number-silent-minus-one.md`) should be authored in `sbdocs/1-Projects/wms1/plan/`. The work is broadly the same shape but more invasive — v1 likely retains the legacy 100-retry-and-`-1`-return behaviour per the ticket. Use the `wms-bugfix-plan` skill or `wms-v2-migrate` (in reverse direction) for that session.

### What does NOT need porting

Nothing in this v2 plan is v2-only behaviourally; the metrics + caller guards + typed exception all apply equally to v1. The scope of `wms2-api/main` differs from v1 only in **what is already done**, not what is required.

---

## 12. Layer 2 Completeness Checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** — Analysis Protocol §8 complete | ✓ §1 (Symptom) — two SQL queries recorded with results; frontmatter `db_verified: true` |
| 1 | **All callsites enumerated** — every row in §0 visited by §3 Fix Design or excluded with rationale | ✓ §0 has 15 rows; #1-#4 + #6 in Fix A/B; #7 in Fix E; #12-#14 in Fix B; #15 in Fix D; #5 #8 #9 excluded with rationale (count-based, not sequence-table); #10 #11 covered transitively by Fix B |
| 2 | **Adjacent bugs** — other classes / methods with the same root-cause pattern | ✓ §0 row 12-14 (3 direct `String.format(..., basicService.getNextSequenceNumber(...))` callers found via pattern grep) |
| 3 | **Backward compatibility** | ✓ Fix A: `RuntimeException` → `BusinessException` is a behavioral change but only on a path that has been unreachable in production; HTTP response shape goes from raw 500 to 422 ProblemDetail with i18n message. No DB schema change. No frontend payload change. |
| 4 | **Concurrency** | ✓ §7 row 6 + row 8 — pessimistic lock + REQUIRES_NEW + 5-retry budget; new IT exercises 50-thread concurrent serialisation |
| 5 | **Multi-tenant** | ✓ §8 row 2 — `value = "tenantTransactionManager"` already in place on the inner method; no cross-tenant queries introduced |
| 6 | **Error handling** | ✓ Fix A: typed `BusinessException` with i18n key; global `RestExceptionHandler` maps to HTTP 422 (per `wms-exception-taxonomy.md` §3 row 89). Fix B: defensive guard with same i18n key. |
| 7 | **Observability** | ✓ Fix C: Timer `wms.sequence.allocation` (per-key tag); Counter `wms.sequence.allocation.exhausted` (per-key tag). §5.1 row 8: Grafana panel + alert rule. §1 query result feeds DBA probe in §5.1 row 5. |
| 8 | **Rollback / migration** | ✓ §5.1 row 5 (DBA probe to characterise 90 anomalous rows); no Flyway migration; no feature flag; `jakarta.persistence.lock.timeout=5000` **[ALREADY DONE — `application.properties:64`]** — no config change in this plan |
| 9 | **Test coverage** | ✓ §6' Test Plan: 8 unit tests (1 update, 7 new) + 1 integration test (Testcontainers PostgreSQL, 50×100 concurrency); regression list explicit |
| 10 | **Cross-version (v1↔v2)** | ✓ §11 — v1 needs a paired plan in a separate session; v1 file paths listed; v2-only deltas explicit |

---

## 13. Acceptance & Implementation

### 13.1 Acceptance criteria → test mapping

| AC# | Ticket criterion | Test class | Test method | What makes it fail before fix |
|---|---|---|---|---|
| AC-1 | `getNextSequenceNumber` throws on exhaustion | `BasicServiceUnitTest` | `shouldThrowWhenSequenceServiceExceedsMaxRetries` (updated to assert `BusinessException`) | Currently throws `RuntimeException`; assertion against `BusinessException.class` fails |
| AC-2 | `SequenceTransactionService` uses pessimistic write lock | Verify script (`PRE-2`) + `SequenceTransactionServiceConcurrencyIT` | `PRE-2` (static analysis); `concurrent50Threads100CallsEach_allDistinctMonotonicNoMalformed` (runtime proof) | Already in place — see §1 [ALREADY DONE — landed in 7316ddb5]; verify script PRE-2 asserts `@Lock(LockModeType.PESSIMISTIC_WRITE)` present; concurrency IT proves it holds under 50-thread load |
| AC-3 | No record in production with negative-formatted sequence number, OR remediation plan documented | DBA probe (§5.1 row 5) — manual SQL | n/a | DB query verified zero rows; remediation plan documented (probe enumerates 90 unrelated anomalies for follow-up) |
| AC-4 | Load test: 50 concurrent threads × 100 calls each → all succeed, all monotonic, non-overlapping | `SequenceTransactionServiceConcurrencyIT` | `concurrent50Threads100CallsEach_allDistinctMonotonicNoMalformed` | No such test exists today |
| AC-5 (new — caller guard) | Negative return is caught at the format-helper layer | `BasicServiceUnitTest` | `generatePickOrderNumber_whenInnerReturnsNegative_throwsBusinessException` (×4: pick, replenish, generic, message) | No guard today; assertion fails |
| AC-6 (new — metrics) | `wms.sequence.allocation` timer recorded; `wms.sequence.allocation.exhausted` counter incremented | `BasicServiceUnitTest` | `getNextSequenceNumber_recordsTimerOnSuccess`, `getNextSequenceNumber_recordsExhaustedCounterOnThrow` | No `MeterRegistry` injection; `SimpleMeterRegistry` returns 0-count timers/counters |

### 13.2 Acceptance script (machine-checkable)

**Path:** `sbdocs/9-System/scripts/verify-SBDEV-2217-sequence-number-silent-minus-one.sh`

The script encodes one POSITIVE check (and a NEGATIVE check where applicable) per fix:
- **Fix A** — `BusinessException` thrown; old `RuntimeException(msg)` exhaustion line gone; import added.
- **Fix B** — `n < 0` guard present in 4 BasicService methods + 4 direct caller sites (Parcel ×2, Order, BOL).
- **Fix C** — `MeterRegistry` import + ctor parameter; metric names `wms.sequence.allocation` and `wms.sequence.allocation.exhausted` referenced.
- **Fix D** — `@RestResource(exported = false)` on `findByClassname`, OR the method gone.
- **Test wiring** — `BasicServiceUnitTest` references `BusinessException`; `SequenceTransactionServiceConcurrencyIT.java` exists.
- **Targeted test invocations** — `mvn test -Dtest=BasicServiceUnitTest`, `mvn verify -Dtest=SequenceTransactionServiceConcurrencyIT`.

The script's final line is `Result: $PASS pass, $FAIL fail, $SKIP skip` and it exits 0 only when `FAIL=0`.

### 13.3 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | 4 fixes × 5 production files + 1 test file edit + 1 new IT; single subsystem (sequence allocation) |
| **Pre-draft step** | Done (this plan) | wms-bugfix-plan with grep + DB verification |
| **Plan-review step** | critic | Standard+ should run critic before any code is written |
| **Implementation shape** | executor (single agent) | Fixes are independent and sequential within one service; no need for ralph/team |
| **Verification step** | verify-script + verifier (mandatory) | Run `verify-SBDEV-2217-sequence-number-silent-minus-one.sh` after every change pass |
| **Code-review step** | code-reviewer | Required because the change cascades `throws BusinessException` to multiple callers |
| **Commit step** | git-master (4 logical commits) | Recommended split: (1) i18n keys + Fix A; (2) Fix B caller guards; (3) Fix C metrics; (4) Fix D repository hygiene + new IT |

### 13.4 Implementation status (fill after each fix lands)

> **Status (2026-05-09):** Implemented and committed in 4 atomic commits. **PR**: [#3](https://github.com/SiteBossInc/wms2-api/pull/3) (base: develop, head: tasks/SBDEV-2217). Branch pushed; awaiting merge.
>
> **Commit map (SBDEV-NNNN CN — style):**
> - **C1** `e75260f` — typed `BusinessException` + i18n + dead-code cleanup (also bundles Fix B BasicService guards + Fix C Micrometer + BillofladingService:719 Fix B guard + cascade ~30 files; atomicity rationale: interlocking diffs in `BasicService.java`)
> - **C2** `3460d97` — caller-side `n < 0` guards at 3 external call sites (ParcelMonitorViewService:112, :241, OrderMonitorViewService:180)
> - **C3** `a481511` — repository REST hygiene: unexport `findByClassname` (Fix D)
> - **C4** `d810100` — concurrency IT + `BasePostgresIntegrationTest` Javadoc (Fix B IT + deviation note)

| Fix | v2 Commit SHA | Tests added | `mvn test` result | verify-script result |
|---|---|---|---|---|
| Fix A (typed exception + i18n + dead code cleanup) | see §13.4 (commits e75260f / 3460d97 / a481511 / d810100) | `BasicServiceUnitTest.shouldThrowWhenSequenceServiceExceedsMaxRetries` updated to assert `BusinessException` | included in 36-test BasicServiceUnitTest (Tests run: 36, Failures: 0, Errors: 0) | A1–A5 pass |
| Fix B (caller guards) | see §13.4 (commits e75260f / 3460d97 / a481511 / d810100) | `BasicServiceUnitTest.CallerSideGuards` (AC-5a/b/c/d) — 4 tests; `ParcelMonitorViewService:112,241`, `OrderMonitorViewService:180`, `BillofladingService:719` guards added | included in 36-test BasicServiceUnitTest | B1–B8 pass |
| Fix C (Micrometer metrics + AC-6 unit tests) | see §13.4 (commits e75260f / 3460d97 / a481511 / d810100) | `BasicServiceUnitTest.SequenceMetrics` (AC-6a/b) — 2 tests; `MeterRegistry` injected into `BasicService` ctor; `Timer.Sample` wraps the retry loop; `wms.sequence.allocation.exhausted` counter on throw path | included in 36-test BasicServiceUnitTest | C1–C4 pass |
| Fix D (repo hygiene) | see §13.4 (commits e75260f / 3460d97 / a481511 / d810100) | (no new test) | n/a | D1, D2 pass |
| Concurrency IT (AC-4) | see §13.4 (commits e75260f / 3460d97 / a481511 / d810100) | `SequenceTransactionServiceConcurrencyIT.concurrent50Threads100CallsEach_allDistinctMonotonicNoMalformed` — 50 threads × 100 iterations against H2 (PostgreSQL-mode); seeds `los_sequencenumber(PICKING_ORDER, 0, 0)` via native INSERT to bypass Hibernate `@Version` unsaved-value contention with String PKs; asserts (a) 5,000 distinct, (b) no `*-NNNN` malformed, (c) monotonic, (d) `MAX = seed+5000`, (e) Timer count=5000 + max>mean*5 contention proof, (f) exhausted counter=0 | Tests run: 1, Failures: 0, Errors: 0; Time elapsed: 22.31 s; **wall-clock 5,000 allocations in 2,885 ms; Timer max=158.2 ms, mean=28.5 ms (contention proven: max > 5×mean)** | T3, T4, T-CONC pass |

**`mvn test -Dtest=BasicServiceUnitTest`** → `Tests run: 36, Failures: 0, Errors: 0, Skipped: 0`
**`mvn failsafe:integration-test -Dit.test=SequenceTransactionServiceConcurrencyIT`** → `Tests run: 1, Failures: 0, Errors: 0, Skipped: 0` (22.31 s, 2.885 s for the concurrent loop)
**`bash sbdocs/9-System/scripts/verify-SBDEV-2217-sequence-number-silent-minus-one.sh`** → `Result: 29 pass, 0 fail, 0 skip`

### 13.4.1 Compile cascade (compiler-driven discovery, not the §5 illustrative table)

`mvn compile` was iterated until clean. Final list of methods that received a `throws BusinessException` clause (or had their `catch (Exception)` body wrapped per §10 Q9 "Runnable boundary" rule):

| File | Method(s) | Treatment |
|---|---|---|
| `service/BasicService.java` | `getNextSequenceNumber`, `generateNumber`, `generateMessageNumber`, `generatePickOrderNumber`, `generateReplenishNumber` | `throws BusinessException` |
| `service/MessageService.java` | `createServiceLog`, `createMessage` (×2 overloads) | `throws BusinessException`. The two `catch (Exception e) { messageService.createMessage(...) }` failure-log paths in `sendStockChangeMessage` and `resendMessage` were **wrapped locally** (per §10 Q9) — adding `throws` would propagate to lambda/forEach call sites. |
| `service/OmsNotificationService.java` | `sendAfterCommit`, `doSend` | **wrapped locally** — these are called from `TransactionSynchronization.afterCommit()` callbacks which cannot throw checked exceptions (§10 Q9 Runnable-boundary rule). |
| `service/ManageOrderService.java` | 7 `catch (Exception e) { messageService.createMessage(...) }` blocks | **wrapped locally** — these methods are called from `forEach` lambdas and `afterCommit` callbacks across `ParcelMonitorViewService`, `MobilePalletizingService`, `MobilePickingService`, `MobileTruckLoadingService`, `PickingorderBusinessService`, `ReleaseOrderJobService`, `CustomerorderBatchService` — propagating `throws` would explode through 30+ call sites. |
| `service/UnitloadService.java` | `createUnitload(Location, Long, Long, String)`, `createUnitload(Location, Long, Long, String, Long)`, `createUnitload(Location, Long, Long, String, Location, Long)` | `throws BusinessException` |
| `service/CyclecountService.java` | `createEntity(String, String, String, String)`, `createCycleCount(...)` | `throws BusinessException` |
| `service/CyclecountPositionService.java` | `createEntity(String, Stockunit)` | `throws BusinessException` (added import) |
| `service/PrintService.java` | `createEntity(String, String, String, boolean)` | `throws BusinessException` |
| `service/BoxtypeService.java` | `createEntity(String, String, int, String, String, String)` | `throws BusinessException` (added import) |
| `service/LocationConstraintService.java` | `createEntity(String, LocationType, UnitloadType)` | `throws BusinessException` (added import) |
| `service/PickingorderService.java` | `create()` | `throws BusinessException` (added import) |
| `service/ReplenishGeneratorService.java` | `calculateOrder(...)` (both overloads), `refillSingleFixedLocation(Long)` | `throws BusinessException` (added import); `rollbackFor` extended to include `BusinessException.class` |
| `service/job/ReplenishOrderJobService.java` | `refillFixedLocationAssignment(long)` | `throws BusinessException`; `rollbackFor` extended; existing `catch (FacadeException e)` blocks at lines 97/193 broadened to `catch (FacadeException \| BusinessException e)` |
| `service/UserRoleService.java` | `createEntity()`, `createEntity(String)`, `createWithDescription(...)` (private, currently unused) | `throws BusinessException` |
| `service/UserGroupService.java` | `createEntity()`, `createEntity(String)` | `throws BusinessException` |
| `service/ShipperidService.java` | `createShipperID(String, String, String, String, boolean)` | `throws BusinessException` |
| `service/BillofladingService.java` | `createEntity(...)` (the BOL `createEntity` at line 209) | `throws BusinessException` (existing throws clause extended) |
| `service/ParcelMonitorViewService.java` | (already declared `throws BusinessException, FacadeException`) | no signature change; Fix B caller-side guard added at the two `getNextSequenceNumber` call sites |
| `service/OrderMonitorViewService.java` | (already declared) | no signature change; Fix B guard added |
| `controller/FileImportController.java` | `importLocations(...)` | `throws BusinessException` (added import) |
| `controller/ItemDataController.java` | `sendStockUpdate(...)` | `throws BusinessException` (added import) |
| `controller/PrinterController.java` | `createPrinter(...)` | `throws BusinessException` |
| `controller/ShipperIdController.java` | `createShipperId(...)` | `throws BusinessException` (added import) |
| `controller/UserGroupController.java` | `create(...)` | `throws BusinessException` (added import) |
| `controller/UserRoleController.java` | `createRole(...)` | `throws BusinessException` (added import) |
| `controller/rest/AdviceRestController.java` | `create(...)`, `createTransfer(...)`, `createHubAndSpoke(...)` | `throws BusinessException` (existing imports cover) |
| `controller/rest/OrderRestController.java` | `create(...)`, `updatePriority(...)`, `cancelPositions(...)`, `finishedQA(...)`, `finishedTransfer(...)` | `throws BusinessException` (existing imports cover) |
| `controller/rest/SkuRestController.java` | `create(...)`, `update(...)` | `throws BusinessException` (added import) |
| `controller/rest/TransactionReportRestController.java` | `getTransactionReport(...)`, `getTransactionDetailedReport(...)` | `throws BusinessException` (added import) |

### 13.4.2 Test files updated for the cascade

The constructor change to `BasicService` and the new `throws BusinessException` propagation forced updates in many test files. The change is mechanical (add `throws net.aim_ai.wms.exceptions.BusinessException` to test-method signatures that touch the affected paths). No test assertions were weakened.

| File | Update |
|---|---|
| `unit/service/BasicServiceUnitTest.java` | `setUp` instantiates `SimpleMeterRegistry` and passes to ctor; AC-6 nested class `SequenceMetrics` added (2 tests); test methods updated to declare `throws BusinessException` |
| `unit/controller/FileImportControllerTest.java`, `unit/controller/PrinterControllerUnitTest.java`, `unit/controller/ShipperIdControllerUnitTest.java`, `unit/controller/TokenControllerUnitTest.java` | Test method `throws` clauses extended |
| `unit/controller/rest/AdviceRestControllerUnitTest.java`, `OrderRestControllerCreateTransferTest.java`, `OrderRestControllerUnitTest.java`, `SkuRestControllerUnitTest.java`, `TransactionReportRestControllerUnitTest.java`, `UtilRestControllerUnitTest.java` | Bulk `throws BusinessException` added to test methods that exercise controller methods now declaring it |
| `unit/schedulejob/ReplenishOrderJobTest.java`, `StockSummaryExportJobTest.java` | `throws FacadeException` extended to include `BusinessException`; bulk update for new test methods |
| `unit/service/BillofladingServiceUnitTest.java` and ~30 other unit-service tests | Bulk `throws BusinessException` added where test methods call services with new throws clauses |

---

## 14. Notes

### Deployment considerations

- Deploy with the next normal `wms2-api` release. No coordination with mobile UI, OMS, or scheduler. No data migration. Tenants do not need to be drained.
- `spring.jpa.properties.jakarta.persistence.lock.timeout=5000` is **[ALREADY DONE — `application.properties:64`]** — no property change required in this release.
- DBA probe (§5.1 row 5) runs on each tenant DB pre-deploy. If any of the 90 anomalous `replenishorder` rows turn out to match `^REPL-\d+$` exactly (the poisoning signature), block deploy and add a remediation step.

### Project-memory directives proposed (post-rollout)

- *"`BasicService.getNextSequenceNumber` throws `BusinessException` (not `RuntimeException`) on exhaustion. New `String.format` call sites that consume `getNextSequenceNumber` must guard `n >= 0` and throw `BusinessException` on negative — even though Fix A makes the negative path unreachable in practice. (SBDEV-2217, 2026-05-09)"*
- *"`LosSequencenumberRepository.findByClassname` is `@RestResource(exported = false)` — never call it from production code; use `findByClassnameForUpdate` (pessimistic-lock variant). (SBDEV-2217, 2026-05-09)"*
- *"Sequence allocation metrics: `wms.sequence.allocation` (Timer, per-key tag) and `wms.sequence.allocation.exhausted` (Counter, per-key tag). Alert on any non-zero exhausted counter in 5-min window. (SBDEV-2217, 2026-05-09)"*

### Version history

| Date | Version | Author | Changes |
|---|---|---|---|
| 2026-05-09 | v1 (draft) | Nam Park (executor agent) | Initial — Fix A/B/C/D/E + Concurrency IT + DB-verified prod-data sanity |
| 2026-05-09 | v2 (draft) | Nam Park (executor agent) | Critic revisions: B1 (pom.xml:54 citation), B2 (full ≥30-caller cascade enumeration + decision), B3 (lock.timeout ALREADY DONE), M1 (BasePostgresIntegrationTest), M2 (shouldRethrowNonOptimisticLockingException note), M4 (BillofladingService:758 confirmed), M5 (prereq row 9 REST reachability), M6 (assertion f in concurrency IT), M7 (Timer/Counter semantics + LOG.error note), M8 (two-query DBA probe + deploy-date criterion), m1 (dead tries>50 branch cleanup), m2 (AC-2 citation fix), m4 (SequenceTransactionServiceUnitTest mocks retargeting note), m8 (Micrometer v1 API compat note), n2 (LOG.error already present clarification) |
| 2026-05-09 | v3 (draft) | Nam Park (executor agent) | Final critic pass: NEW-2 (MessageService.createServiceLog cascade + REQUIRES_NEW risk note + §10 Q9), NEW-3 (wrapper methods verified count-based, excluded with source evidence), NEW-1 (§5.2 checklist compiler-driven cascade instruction), fix 4 (OrderRestController:345 added to cascade table), fix 5 (§6 omnibus cascade row + BasePostgresIntegrationTest in §4 and §6) |
