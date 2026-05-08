---
title: "BOL Exception Handling + Closing Logic Cleanup — v2 Port Analysis"
ticket: ""
ticket_url: ""
type: "migration-analysis"
priority: "low"
status: "closed — not needed"
project: ["wms2-api"]
version: "v2"
requester: "sync-sweep"
created: "2026-05-03"
updated: "2026-05-03"
related: []
tags:
  - plan
  - v1-sync
  - bol
  - billoflading
db_verified: false
---

# BOL Exception Handling + Closing Logic Cleanup — v2 Port Analysis

**V1 Source Commit:** `ed2a4b8` — "refactor: update exception handling and clean up BOL closing logic" (Leonardo Castro, 2026-04-14)
**V2 Target:** `wms2-api`
**Status:** CLOSED — not needed in v2

---

## 1. Summary

3 v1 sub-changes analysed. **0 confirmed still needed. 0 NEW v2-only issues.** All three sub-changes are either not applicable (class/method absent in v2) or already superseded by a deliberate v2 architectural decision. No code changes required.

---

## 2. V1 → V2 Applicability Analysis

| V1 Sub-change | Description | V2 Verdict | Rationale |
|---------------|-------------|------------|-----------|
| SC-1 | `BolClosedEventListener`: `catch (IOException e)` → `catch (Exception e)` | **Not needed (not applicable)** | `BolClosedEventListener` does not exist in v2. The Spring event pattern was eliminated. `BillofladingService.closeBOL` (L277–699) sends no OMS notification; the only `omsNotificationService.sendAfterCommit` call (L655) is in the ORDER_BATCH_SHIPPED path, not the closeBOL path. |
| SC-2 | `UnitloadRepository.clearCarrierUnitloadByIds`: column name fix `carrier_unitload_id` → `carrierunitload_id` | **Not needed (not applicable)** | `clearCarrierUnitloadByIds` does not exist in v2's `UnitloadRepository`. The method was never introduced in v2. |
| SC-3 | `BillofladingService.closeBOL`: remove `bolToClose` in-memory list | **Not needed (V2 already correct)** | v2 already made a better design choice: `private final Set<Long> bolToClose = ConcurrentHashMap.newKeySet()` at L150, thread-safe and documented (L147–149 comment explicitly acknowledges the single-JVM limitation and states the real cross-replica safety is provided by `findByIdForUpdate`). No action needed. |

---

## 3. Detailed Evidence

### SC-1 — No BolClosedEventListener in v2

v1 used a Spring `@EventListener` class `BolClosedEventListener` that fired after `BillofladingService.closeBOL` published a `BolClosedEvent`, sending an OMS HTTP POST. The `catch (IOException e)` in that listener only caught HTTP/IO failures; JSON parsing or runtime exceptions propagated and crashed the listener.

v2 eliminated this entire pattern:
- No `BolClosedEventListener.java` exists anywhere in `v2/wms2-api/src/`.
- `BillofladingService.closeBOL` (L277–699) contains no `omsNotificationService` call.
- The only OMS notification call in `BillofladingService` is at L652–659:
  ```java
  try {
      String urlPath = syspropService.getSysvalue(...ORDER_BATCH_SHIPPED_URL_KEY);
      String payload = MAPPER.writeValueAsString(billOfLadingWebServiceDto);
      omsNotificationService.sendAfterCommit(urlPath, payload,
          WmsConstants.MessageProcessType.ORDER_BATCH_SHIPPED);
  } catch (IOException e) {
      LOG.error("Failed to serialize BOL shipped payload for BOL={}: {}", billOfLading.getName(), e.getMessage());
  }
  ```
  This is the ORDER_BATCH_SHIPPED path — a different flow from closeBOL. The `catch (IOException e)` here is correct: `MAPPER.writeValueAsString` only throws `IOException`, so narrowing to `IOException` is appropriate.

v2's `closeBOL` does not send a BOL-closed notification to OMS. If that notification is needed in the future, it would be a new feature — not a port of this v1 fix.

### SC-2 — clearCarrierUnitloadByIds absent in v2

```
grep -rn "clearCarrierUnitload" v2/wms2-api/src/  → (no results)
```

The method was never introduced in v2's `UnitloadRepository`. All references to `carrierunitload_id` in v2's native queries already use the correct column name (confirmed at lines 37, 50, 87–88, 117, 120 of `UnitloadRepository.java`).

### SC-3 — v2 bolToClose: deliberate better design

v1 before fix:
```java
private List<Long> bolToClose = new ArrayList<Long>();  // NOT thread-safe
```

v1 after fix:
```java
// removed entirely — rely only on findByIdForUpdate
```

v2 current (`BillofladingService.java` L147–150):
```java
// Single-JVM fast-fail optimization only — prevents duplicate closeBOL() calls within
// the same replica. Under multi-replica deployment, this set is NOT shared across JVMs.
// The real cross-replica safety is provided by findByIdForUpdate() pessimistic lock in closeBOL().
private final Set<Long> bolToClose = ConcurrentHashMap.newKeySet();
```

v2's implementation is superior to both v1 states:
- Thread-safe (`ConcurrentHashMap.newKeySet()` vs `ArrayList`)
- Atomic check-and-add: `if (!bolToClose.add(bolId))` returns false if already present — no TOCTOU race
- Correctly documented as single-JVM optimization only
- Real correctness guaranteed by `findByIdForUpdate` at L288

The v1 fix removed the guard entirely (correct for single-instance v1). v2 keeps a thread-safe version as a performance optimization for the common case (avoid DB round-trip for duplicate calls within the same replica). This is a conscious, better design decision. No action needed.

---

## 4. Sync Log Action

Mark `ed2a4b8` as `already-done`/`not-applicable` in the next sweep run. This was the last pending commit from the May 2 sweep's `needs-investigation` bucket.

With this analysis complete, both remaining items from the May 2 sweep are resolved:
- `07ae9ab` — already-done (qty sort fix already in v2)
- `ed2a4b8` — not-applicable (event listener eliminated; method absent; bolToClose already correct)

The wms-api sync anchor at `7f06c6f` can be formally advanced in the next sweep once `git cherry` confirms all out-of-order ports are accounted for.

---

## 5. Horizontal Scalability Validation

N/A — no code changes. Analysis only.

---

## 6. Changelog

| Date | Ver | Author | Notes |
|------|-----|--------|-------|
| 2026-05-03 | v1 | Nam Park (migration analysis) | Analysis complete. All 3 sub-changes not applicable or already correct. |
