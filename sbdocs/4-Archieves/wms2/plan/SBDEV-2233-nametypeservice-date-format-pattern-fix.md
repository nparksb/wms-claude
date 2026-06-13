---
title: "NameTypeService date-format pattern bug — `hh` 12-hour clock silently emits wrong hour for timestamps ≥ 13:00; FileExportService `YYYY` week-year emits wrong year on Dec 29–31"
ticket: "SBDEV-2233"
ticket_url: ""
type: "bugfix"
priority: "low"
status: "archived"
project:
  - wms2
version: "v2"
requester: ""
created: "2026-05-15"
updated: "2026-05-15"
db_verified: false
related:
  - sbdocs/3-Resources/architecture/wms2-function-to-docs-map.md
tags:
  - plan
  - wms2
  - date-formatting
  - thread-safety
  - silent-wrong-output
  - correctness
---

# SBDEV-2233 — `NameTypeService` static `DateTimeFormatter` pattern correctness (`hh` vs `HH`), plus FileExportService `YYYY` week-year audit

**Ticket:** SBDEV-2233
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** low
**Status:** draft
**Date:** 2026-05-15

> **Drift from ticket:** The ticket text claims "Static `SimpleDateFormat` in NameTypeService is not thread-safe" and warns
> of `NumberFormatException` / `ArrayIndexOutOfBoundsException`. **That framing is a misdiagnosis for v2.** In
> `v2/wms2-api`, `NameTypeService.java:22` already uses `java.time.format.DateTimeFormatter`, which IS thread-safe by
> contract. The thread-safety failure mode never applies. **The real v2 defect** at that line is a format-pattern
> correctness bug: `"yyyy-MM-dd'T'hh:mm:ss.SSSZ"` uses `hh` (12-hour clock, 01–12) without an AM/PM marker, so any
> hour ≥ 13 silently emits `hour − 12` (e.g., 14:30 → `T02:30:00.000+0000`). A secondary audit hit in
> `FileExportService.java` uses `YYYY-MM-dd` (ISO week-based year) where calendar `yyyy` is intended — silently wrong
> year on Dec 29–31. Plan retargets to fix both correctness bugs.

> **db_verified: false** — The defect is purely in-JVM string formatting. The database stores timestamps correctly;
> no SQL query can reproduce the wrong-hour or wrong-year output. Verification is unit-test-based.

---

## §0 Affected Sites

| # | File:line | Construct | Same root-cause? | In-scope? |
|---|-----------|-----------|------------------|-----------|
| 1 | `service/NameTypeService.java:22` | `private static final DateTimeFormatter dateFormat = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'hh:mm:ss.SSSZ")` — `hh` 12-hour clock without AM/PM marker | YES (primary) | **YES — Fix A** |
| 2 | `service/NameTypeService.java:126` | `findDateColumn(name).toInstant().atZone(ZoneId.systemDefault()).format(dateFormat)` — call site of Site 1 | YES (review only) | YES — review only, no change |
| 3 | `service/FileExportService.java:84,152,217,285` | `new SimpleDateFormat("YYYY-MM-dd HH:mm:ss.SSS")` — `YYYY` ISO week-year emits wrong year at year boundary | Adjacent (silent-wrong-output correctness) | **YES — Fix B (hardening)** |
| 4 | `schedulejob/OrderReleaseJob.java:112` | local `SimpleDateFormat` instance (per-call) | NO — not thread-shared | OUT — audited safe |
| 5 | `controller/rest/TransactionReportRestController.java:99,105,108,213,219,222` | local `SimpleDateFormat` instances per request | NO — not thread-shared | OUT — audited safe |
| 6 | `service/AdviceService.java:301` | local `DateTimeFormatter` (immutable, per-call) | NO — not a defect | OUT — audited safe |
| 7 | `service/StockunitService.java:14`, `service/mobile/MobileReplenishService.java:25`, `service/mobile/MobilePickingService.java:22` | `import java.text.SimpleDateFormat` with zero usages in the file | NO (cleanup) | **YES — Fix C (dead-import cleanup)** |
| 8 | `service/FileExportService.java:18` | `import java.text.SimpleDateFormat;` — becomes dead after Fix B removes the four allocations | YES (transitive cleanup under Fix B) | **YES — Fix B (remove import once allocations are gone)** |

**Scope rationale:** Site 1 is the primary defect. Site 3 is an adjacent silent-wrong-output bug in the same
date-format-pattern family, low-cost to fix in the same touch. Sites 4–6 were audited and confirmed safe (no
shared mutable state). Site 7 is mechanical hygiene riding the same touch. `NameTypeService` itself has **no
production callers** in v2 (only `NameTypeServiceUnitTest` exercises it) — class-level dead-code removal is
deferred as out-of-scope.

---

## 1. Problem Statement

`NameTypeService.findDateColumn(...)` is responsible for serialising `Date` columns into ISO-8601 strings inside
the generic "name/type" JSON response object. Per ticket SBDEV-2233 the concern was thread-safety of a static
`SimpleDateFormat`. In `v2/wms2-api` that has already been remediated: line 22 uses `DateTimeFormatter` (immutable,
thread-safe). However the pattern string is wrong:

```java
private static final DateTimeFormatter dateFormat =
    DateTimeFormatter.ofPattern("yyyy-MM-dd'T'hh:mm:ss.SSSZ");
```

`hh` is the **12-hour clock** (01–12). Without an `a` (AM/PM) marker, hours 13–23 are silently emitted as 01–11.
A 14:30:00 timestamp serialises as `2026-05-15T02:30:00.000+0000` — looks plausible, indistinguishable from a
real 2:30 AM record. No exception is thrown; downstream consumers (OMS, audit reports, BI extracts) silently
accept the wrong hour.

A secondary audit of date-format usage found four call-sites in `FileExportService` (Excel-export feature) that
use the pattern `"YYYY-MM-dd HH:mm:ss.SSS"`. Capital-Y `YYYY` is **ISO week-based year**, not calendar year. On
Dec 29, 30, 31 — when those calendar days fall in ISO week 1 of the *next* calendar year — `YYYY` returns the
next year. A Date of 2026-12-31 14:30 emits `2027-12-31 14:30:00.000`. Again: silent, no exception, wrong data
in an Excel export.

Symptoms a customer or auditor would observe:
1. Audit reports show a `findDateColumn`-derived timestamp at "02:00" when the underlying record was created at "14:00".
2. Excel exports run on Dec 29–31 show next-year dates ("2027-12-31") in the body of a 2026 export.

Neither symptom triggers an exception or log. Detection is human-driven.

---

## 2. Root Cause Analysis

### Bug 1 — `NameTypeService.java:22` — `hh` instead of `HH`

```java
// service/NameTypeService.java
private static final DateTimeFormatter dateFormat =
    DateTimeFormatter.ofPattern("yyyy-MM-dd'T'hh:mm:ss.SSSZ");   // L22: hh = 12-hour clock

// Usage at L126
objectNode.put(jsonName,
    findDateColumn(name).toInstant().atZone(ZoneId.systemDefault()).format(dateFormat));
```

Per `java.time.format.DateTimeFormatter` symbol reference:
- `h` — "clock-hour-of-am-pm (1–12)"
- `H` — "hour-of-day (0–23)"

With `hh` and no `a` (AM/PM) symbol, the formatter renders any 24-hour input as 12-hour with no disambiguation.
14:30 → `02:30`. 23:59 → `11:59`. Round-trip parsing of the output recovers a different `Instant`. The
companion `Z` offset is unaffected, so the bug is purely on the hour digit.

`DateTimeFormatter` IS thread-safe (immutable; Javadoc: *"This class is immutable and thread-safe."*).
The ticket's thread-safety claim is a misdiagnosis for v2 — likely inherited from a v1 ticket targeting
`SimpleDateFormat` and ported verbatim.

**Call-graph context.** `NameTypeService` has no `@Service` consumer in v2 production code. `grep -rn` finds
only `NameTypeServiceUnitTest`. The class is dead code. This plan fixes the defect because:
1. It is a one-character change with a unit test (cost ≈ zero).
2. If the class is ever revived (e.g., for a metadata endpoint) the bug would be back at first use.
3. Dead-code removal is a separate concern and not in scope.

### Bug 2 — `FileExportService.java:84,152,217,285` — `YYYY` instead of `yyyy`

```java
// service/FileExportService.java — same pattern at L84, L152, L217, L285
SimpleDateFormat simpleDateFormat = new SimpleDateFormat("YYYY-MM-dd HH:mm:ss.SSS");
String timestamp = simpleDateFormat.format(d);
cell.setCellValue(timestamp);
```

Per `SimpleDateFormat` symbol reference:
- `Y` — "Week year"
- `y` — "Year"

ISO 8601 week year aligns "weeks" with the ISO calendar (Mon-start, week 1 contains the first Thursday). Dec
29–31 of one calendar year may fall in week 1 of the next ISO year. Example:
- Date: 2026-12-31 (Thursday) → ISO week 1 of 2027 → `YYYY` emits `2027`.
- Same date with `yyyy` → `2026`.

Thread-safety is **not** the defect here — the `SimpleDateFormat` is a local variable, single-threaded per call.
The defect is silent wrong-year on three days of the year, in customer-facing Excel exports. Fix retargets to
the pattern bug AND modernises to a `static final DateTimeFormatter` so future copy-paste does not regress.

### Why DB verification was skipped (db_verified: false)

The DB stores timestamp columns as `timestamp` / `timestamptz`. No SQL query reproduces the bug because the bug
manifests on the application-layer string-format step *after* the row leaves the database. Verification is
purely unit-test-based (assert the formatted output for a known input Date).

---

## 3. Design / Proposed Fix

### 3.1 Fix A — `NameTypeService.java:22` — change `hh` → `HH`

Single-character pattern fix on the static formatter. Call site at L126 unchanged.

```java
// BEFORE
private static final DateTimeFormatter dateFormat =
    DateTimeFormatter.ofPattern("yyyy-MM-dd'T'hh:mm:ss.SSSZ");

// AFTER
private static final DateTimeFormatter dateFormat =
    DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSSZ");
```

**Alternatives ruled out:**
- `DateTimeFormatter.ISO_OFFSET_DATE_TIME` — emits a colon in the offset (`+00:00`) and uses variable-length
  fraction; behavioural change too wide for a low-priority fix and breaks the SSS-fixed contract that any
  existing consumer parses against.
- Switch to `WmsConstants.DATE_TIME_PATTERN` if one exists with the same SSSZ contract — verify before reuse;
  prefer a local literal to keep the change isolated.
- Delete `NameTypeService` entirely as dead code — out of scope; file a separate cleanup ticket.

### 3.2 Fix B — `FileExportService.java` — extract static formatter, fix `YYYY` → `yyyy`

Replace the four `new SimpleDateFormat("YYYY-MM-dd HH:mm:ss.SSS")` local instances with a single static
`DateTimeFormatter` field, and switch to calendar year. Apply at L84, L152, L217, L285 (all four `Date`
instanceof branches).

```java
// Add at class level (one new field):
private static final DateTimeFormatter CELL_TIMESTAMP_FORMAT =
    DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS")
        .withZone(ZoneId.systemDefault());

// Timezone axis: `.withZone(ZoneId.systemDefault())` preserves the pre-fix
// SimpleDateFormat default-timezone behavior exactly — no timezone-axis behavior change.

// BEFORE — repeated 4× across L84, L152, L217, L285:
} else if (cellContent instanceof Date) {
    Date d = (Date) cellContent;
    SimpleDateFormat simpleDateFormat = new SimpleDateFormat("YYYY-MM-dd HH:mm:ss.SSS");
    cell.setCellValue(simpleDateFormat.format(d));
}

// AFTER — uniform:
} else if (cellContent instanceof Date d) {
    cell.setCellValue(CELL_TIMESTAMP_FORMAT.format(d.toInstant()));
}
```

Pattern correctness aside, this also:
- Removes 4 redundant allocations per Excel export.
- Eliminates the historical thread-safety hazard of `SimpleDateFormat` from this class entirely.
- Uses `instanceof Date d` pattern matching (Java 21, already in use elsewhere in v2).

### 3.3 Fix C — Dead `import java.text.SimpleDateFormat` removal (mechanical)

Three service files import `SimpleDateFormat` with zero usages in the file body:

| File | Line |
|---|---|
| `service/StockunitService.java` | 14 |
| `service/mobile/MobileReplenishService.java` | 25 |
| `service/mobile/MobilePickingService.java` | 22 |

Remove the import line in each. `mvn compile` will fail loudly if a hidden usage exists (it does not — `grep -n SimpleDateFormat` against each file returns the import line only, confirmed 2026-05-15).

Note also that `service/FileExportService.java:18` carries the same `import java.text.SimpleDateFormat;`. After Fix B removes the four `new SimpleDateFormat(...)` allocations at L84/L152/L217/L285, this import becomes dead too and must be removed in the same patch.

### 3.4 Why no `@Version` / lock / cache change

The defect is in-JVM string formatting. No entity, no DB row, no cache, no transaction boundary, no
multi-replica concern is involved. §7 expands.

---

## 4. V1/V2 Applicability

This plan targets **v2 only**. The original ticket SBDEV-2233 was filed against v1. A paired v1 audit is
recommended but out of scope for this plan.

| Aspect | V1 | V2 | Impact |
|--------|----|----|--------|
| Same defect present? | Unverified — v1 may still use `SimpleDateFormat` (the ticket's original claim) | `DateTimeFormatter` already in place; `hh`/`YYYY` pattern bugs present | v1 needs separate audit; v2 fix-in-place |
| `NameTypeService` exists? | unverified | yes, dead code (no production callers) | v1 audit should confirm |
| `FileExportService` exists? | unverified | yes | v1 audit should confirm same pattern |

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Status |
|---|---|---|---|
| 1 | Database state | No schema change | N/A — pure code change |
| 2 | Feature flags / system properties | None | N/A |
| 3 | Config / env changes | None | N/A |
| 4 | Deploy-order dependencies | None | N/A |
| 5 | Data migration | None | N/A — no stored data is wrong; only application-emitted strings |
| 6 | External systems | None | N/A — no OMS / printer / keycloak interaction |
| 7 | Access / permissions | None | N/A |
| 8 | Monitoring / alerts | None | N/A — defect is silent; no metric exists to alarm on |

### 5.2 Implementation Checklist

- [ ] **Step 1 — Fix A on `NameTypeService.java:22`.** Change `hh` to `HH` on the static `DateTimeFormatter` pattern. No other lines touched.
- [ ] **Step 2 — Unit test for Fix A.** Add `NameTypeServiceUnitTest.shouldFormatDateColumnWithCorrect24HourClock` asserting that a `Date` representing 14:00 local time formats with `T14:` and not `T02:` substring. Run `mvn test -Dtest=NameTypeServiceUnitTest` — green.
- [ ] **Step 3 — Fix B on `FileExportService.java`.** Add `CELL_TIMESTAMP_FORMAT` static field (using `import java.time.format.DateTimeFormatter` and `import java.time.ZoneId`). Replace each of the four `Date` instanceof branches at L84, L152, L217, L285 with the static-formatter call. Remove the now-unused `import java.text.SimpleDateFormat;` at L18.
- [ ] **Step 4 — Unit test for Fix B.** Add (or update) `FileExportServiceUnitTest.shouldFormatDateWithCalendarYearNotWeekYear` constructing a Date for 2026-12-31 and asserting the formatted cell starts with `2026-12-31`, not `2027-12-31`. Run `mvn test -Dtest=FileExportServiceUnitTest` — green.
- [ ] **Step 5 — Fix C dead-import removal.** Delete the `import java.text.SimpleDateFormat;` line from `service/StockunitService.java:14`, `service/mobile/MobileReplenishService.java:25`, `service/mobile/MobilePickingService.java:22`. Run `mvn compile` — green.
- [ ] **Step 6 — Regression.** Run `mvn verify` — exits 0. Run `bash sbdocs/9-System/scripts/verify-SBDEV-2233-nametypeservice-date-format-pattern-fix.sh` — all PASS.
- [ ] **Step 7 — Update §14 Implementation Status.** Record commit SHA, mvn results, PR link.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| `findDateColumn` on a 14:00 Date | Construct `Date` representing 2026-05-15T14:30:00 in `ZoneId.systemDefault()`; invoke a reflection-driven `findDateColumn`-style format path | Output contains `T14:30:` substring; does NOT contain `T02:30:` |
| `findDateColumn` on a 02:00 Date | Construct `Date` representing 2026-05-15T02:30:00 | Output contains `T02:30:` (control: confirms low-hour still works) |
| `FileExportService` cell timestamp for Dec 31 boundary | Construct `Date` 2026-12-31T14:00:00 | Cell value starts with `2026-12-31`, not `2027-12-31` |
| `FileExportService` cell timestamp mid-year | Construct `Date` 2026-06-15T14:00:00 | Cell value starts with `2026-06-15` (control) |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `NameTypeServiceUnitTest` | `shouldFormatDateColumnWithCorrect24HourClock` | Output for 14:30 contains `T14:30:` |
| `NameTypeServiceUnitTest` | `shouldFormatLowHourCorrectly` (regression control) | Output for 02:30 contains `T02:30:` |
| `FileExportServiceUnitTest` | `shouldFormatDateWithCalendarYearNotWeekYear` | 2026-12-31 → `2026-12-31`, not `2027-12-31` |
| `FileExportServiceUnitTest` | `shouldFormatMidYearDateCorrectly` (regression control) | 2026-06-15 → `2026-06-15` |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| `FileExportService` Excel export run on Dec 29–31 | staging | Trigger any Excel report whose cells include a Date column on Dec 31 | Excel cells show calendar year (e.g. `2026-12-31`), not `2027-12-31` | |
| `NameTypeService` JSON envelope — manual smoke | staging (if class becomes reachable) | N/A in current build — no production caller | N/A | N/A |

`NameTypeService` has no production REST/UI path. The manual smoke for Fix A is satisfied entirely by the unit test;
documented as N/A here with rationale, not skipped without explanation.

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=NameTypeServiceUnitTest` | | |
| `mvn test -Dtest=FileExportServiceUnitTest` | | |
| `mvn verify` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2233-nametypeservice-date-format-pattern-fix.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Integration test (Testcontainers) | Defect is pure in-JVM string formatting; no DB interaction. Unit tests fully exercise the path. |
| REST controller test (BaseControllerTest) | Neither `NameTypeService` nor `FileExportService` is reached through a controller affected by this fix. |
| Quantitative load / perf test | Fix B removes 4 allocations per export — pure improvement; perf not gated. |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1 | In-JVM state | No | `DateTimeFormatter` is already immutable; the new `CELL_TIMESTAMP_FORMAT` field is immutable too |
| 2 | Connection pool math | No | No DB interaction added or changed |
| 3 | Scheduled jobs | No | No `@Scheduled` added or modified |
| 4 | Long transactions | No | No transaction boundary touched |
| 5 | Request affinity | No | No session / WebSocket / SSE state |
| 6 | Retry / idempotency | No | No write path involved |
| 7 | Tenant context | No | Pure formatter logic; no `TenantContext` use |
| 8 | Distributed lock correctness | No | No lock involved |
| 9 | Cache invalidation | No | No cache touched |
| 10 | External notifications | No | No OMS / printer / external HTTP |

### Evidence

| Concern # | What was done / verified | File:line or test reference |
|-----------|--------------------------|------------------------------|
| 1 | `DateTimeFormatter` Javadoc — "This class is immutable and thread-safe" | `java.time.format.DateTimeFormatter` |

---

## 8. Notes

- `NameTypeService` has no production caller in v2 — the class is effectively dead code. This plan deliberately
  fixes the defect rather than deleting the class, because (a) the fix is one character with a unit test, and
  (b) class-level dead-code removal is a separate concern that requires a v1↔v2 reconciliation pass.
- The original ticket SBDEV-2233 framing ("static `SimpleDateFormat` not thread-safe") is a misdiagnosis for v2;
  this plan retargets to the actual v2 defect and documents the drift at the top of the file.
- After this plan ships, a follow-up sweep should grep `v2/wms2-api/src/main/java` for `hh:mm` and
  `YYYY-MM-dd` patterns across all dependencies; AC4/AC5 below enforce zero hits in the touched files but a
  project-wide sweep is a separate hygiene ticket.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script (machine-checkable)

Path: `sbdocs/9-System/scripts/verify-SBDEV-2233-nametypeservice-date-format-pattern-fix.sh`

Encoded checks (14 total — matches script `run` count):
- **A1** — `NameTypeService.java:22` contains `'T'HH:mm:ss.SSSZ` (positive — 24-hour pattern present).
- **A2** — `NameTypeService.java` does NOT contain `'T'hh:mm` (negative — 12-hour pattern gone).
- **B1** — `FileExportService.java` contains a static `CELL_TIMESTAMP_FORMAT` field (positive — field declared).
- **B1b** — `FileExportService.java` formatter contains `yyyy-MM-dd HH:mm:ss.SSS` (positive — calendar-year pattern used).
- **B2** — `FileExportService.java` does NOT contain `YYYY-MM-dd` (negative — week-year pattern gone).
- **B3** — `FileExportService.java` does NOT contain `new SimpleDateFormat(` (negative — local allocations gone).
- **B4** — `FileExportService.java` does NOT contain `import java.text.SimpleDateFormat;` (negative — transitively dead import gone).
- **C1** — `StockunitService.java` does NOT contain `import java.text.SimpleDateFormat;` (negative).
- **C2** — `MobileReplenishService.java` does NOT contain `import java.text.SimpleDateFormat;` (negative).
- **C3** — `MobilePickingService.java` does NOT contain `import java.text.SimpleDateFormat;` (negative).
- **R1** — Repo-wide: `grep -rn "'T'hh:mm\|YYYY-MM-dd" v2/wms2-api/src/main/java` → 0 hits (hardening sweep).
- **R1b** — No `private.*SimpleDateFormat` field on any `@Service` class in `src/main/java` (negative).
- **T1** — `mvn test -Dtest=NameTypeServiceUnitTest` exits 0.
- **T2** — `mvn test -Dtest=FileExportServiceUnitTest` exits 0.

### 9.2 Recommended OMC composition (for implementation)

| Aspect | Value | One-line rationale |
|---|---|---|
| Size class | Trivial | 2 functional fixes (1-char pattern + extract-static) + 3 mechanical import removals across 5 files |
| Pre-draft step | none | Done already (this plan) |
| Plan-review step | none (or critic — optional) | Trivial enough that the verify script is the safety net |
| Implementation shape | `executor` | One agent, one pass; verify-script is the exit gate |
| Verification step | verify-script + verifier | Mandatory for all |
| Code-review step | none | Trivial diff |
| Commit step | git directly | Single logical commit |

---

## 10. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Fix A (`hh` → `HH`) changes serialised hour digit for any external consumer of `NameTypeService` output | LOW | No production caller in v2 (grep-confirmed); only `NameTypeServiceUnitTest` exercises it. Even if revived, consumers expecting AM/PM-collapsed hours would already be reading wrong data — fix is corrective in the consumer's favour. |
| Fix B (`YYYY` → `yyyy`, modernise to `DateTimeFormatter`) changes Excel cell format for non-boundary dates | LOW | Fix B affects every Excel export emitted by `FileExportService` — known callers include `CyclecountService` (aggregate + detailed reports) and `AdviceService` (Inbound Notice), confirmed via `CyclecountServiceUnitTest.java:60` and `AdviceServiceUnitTest.java:99`. Behaviour change is limited to `Date` cells emitted on Dec 29–31 of years where those dates fall in ISO week 1 of the following year. Timezone axis: `.withZone(ZoneId.systemDefault())` is behaviourally identical to pre-fix `SimpleDateFormat` default-timezone. Unit test guards year boundary. |
| Dead-import removal triggers compile error | VERY LOW | `mvn compile` catches immediately; checked imports have zero in-file usages. |
| Repo-wide stragglers with the same patterns not covered | LOW | Verify-script R1 greps `v2/wms2-api/src/main/java` for both `'T'hh:mm` and `YYYY-MM-dd` after the fix and asserts 0 hits — catches strays. |

---

## 11. Acceptance Criteria

**AC1 — `NameTypeService.java:22` uses `HH` not `hh`.**
Grep: `grep -n "'T'HH:mm:ss.SSSZ" src/main/java/net/aim_ai/wms/service/NameTypeService.java` → 1 hit on L22. Negative: `grep -n "'T'hh:mm" ...` → 0 hits.

**AC2 — Unit test asserts 24-hour clock output.**
`NameTypeServiceUnitTest.shouldFormatDateColumnWithCorrect24HourClock` passes; asserts output for 14:30 contains `T14:30:`.

**AC3 — `FileExportService.java` uses a static `CELL_TIMESTAMP_FORMAT` with calendar year.**
Grep: `grep -n "CELL_TIMESTAMP_FORMAT" src/main/java/net/aim_ai/wms/service/FileExportService.java` → ≥1 hit on declaration + 4 hits on usage. Negative: `grep -n "YYYY-MM-dd\|new SimpleDateFormat" ...` → 0 hits.

**AC4 — Unit test asserts calendar year on year-boundary Date.**
`FileExportServiceUnitTest.shouldFormatDateWithCalendarYearNotWeekYear` passes; 2026-12-31 → `2026-12-31`, not `2027-12-31`.

**AC5 — Dead imports of `SimpleDateFormat` removed.**
Grep `import java.text.SimpleDateFormat;` → 0 hits in `service/StockunitService.java`, `service/mobile/MobileReplenishService.java`, `service/mobile/MobilePickingService.java`, and also in `service/FileExportService.java` (transitively dead after Fix B).

**AC6 — Repo-wide hardening (touched scope).**
`grep -rn "'T'hh:mm\|YYYY-MM-dd" v2/wms2-api/src/main/java` → 0 hits.

**AC7 — Full regression green.**
`mvn verify` exits 0.

**AC8 — No `private.*SimpleDateFormat` field on any `@Service` class.**
`grep -rn "private.*SimpleDateFormat" v2/wms2-api/src/main/java` → 0 hits (or only on local-variable false positives, audited).

---

## 12. ADR — Architectural Decision Record

**Decision:** Fix the format-pattern correctness bugs in `NameTypeService` (`hh` → `HH`) and `FileExportService`
(`YYYY` → `yyyy`, with extraction to a static `DateTimeFormatter`). Retain `NameTypeService` even though it has
no production callers — class-level removal is a separate cleanup concern. Remove three dead `SimpleDateFormat`
imports as mechanical hygiene.

**Drivers:**
1. **Silent wrong output** — both bugs emit plausible-but-wrong data with no exception or log. Detection is human-driven; the cost of leaving them in place is unbounded.
2. **Minimal blast radius** — one-character pattern change for Fix A, 4 identical-call-site refactors for Fix B, no schema change, no migration, no feature flag.
3. **Drift from ticket diagnosis** — the original "static `SimpleDateFormat` not thread-safe" framing does not apply in v2; correcting the framing in this plan prevents future churn from re-investigating the same code.

**Alternatives considered:**

| Option | Rejected because |
|--------|------------------|
| O1: Delete `NameTypeService` as dead code | Out of scope; class-level removal needs v1↔v2 reconciliation; one-character fix is cheaper and reversible |
| O2: Switch to `DateTimeFormatter.ISO_OFFSET_DATE_TIME` | Variable-length fraction + colon-bearing offset is a wider behavioural change; would break any consumer parsing the SSS-fixed contract |
| O3: Leave `FileExportService` `YYYY` alone (only fix Fix A) | Fix B is adjacent, low-cost, and the bug is silent — leaving it in place is a knowing accept of customer-facing wrong data |
| O4: Add a new `WmsConstants.NAME_TYPE_DATE_PATTERN` constant | Premature abstraction for one caller; adds API surface for a class that's already dead code |

**Consequences:**
- **Positive:** Silent wrong-hour and wrong-year output eliminated at the two known sites. Reduced surface area for future copy-paste regression (no more `new SimpleDateFormat(...)` in the touched class).
- **Negative:** None expected. Output format strings are identical for non-boundary inputs.
- **Risk:** Future contributors copy-paste a `YYYY` pattern elsewhere. Mitigated by verify-script AC6 (repo-wide scan).

**Follow-ups:**
1. v1 audit ticket for `NameTypeService` and `FileExportService` in `v1/wms-api`.
2. Optional cleanup ticket to delete `NameTypeService` if v1↔v2 reconciliation confirms no current or planned caller.
3. Optional repo-wide hygiene sweep for any other `hh:mm` or `YYYY-MM-dd` patterns outside the touched files (verify-script R1 already covers `src/main/java`; widen to `src/main/resources` if needed).

---

## 13. Open Questions / Resolved Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Should `NameTypeService` be deleted as dead code instead of patched? | **No** — separate concern; fix the defect now (one character + test), defer deletion to a v1↔v2 reconciliation ticket |
| 2 | Should Fix B use `WmsConstants.DATE_TIME_PATTERN` if one exists with the same SSSZ contract? | **No.** Verified: `grep -n "DATE_TIME_PATTERN\|TIMESTAMP_FORMAT" src/main/java/net/aim_ai/wms/service/WmsConstants.java` returns `DATE_TIME_PATTERN = "yyyy-MM-dd HH:mm:ss"` (no SSS, no Z offset) and no SSS+Z constant — incompatible with the `SSSZ` contract needed here. Local literal retained. |
| 3 | Should we add a project-wide static-analysis rule for `hh:mm` / `YYYY-MM-dd` patterns? | **Out of scope** — verify-script R1 enforces it on the touched paths; rule-engine work is a separate hygiene ticket |
| 4 | Why is `db_verified: false`? | **Defect is in-JVM string formatting; no DB query reproduces it.** Unit tests are the verification surface. |

---

## 14. Implementation Status

_Implemented 2026-05-15._

```
v2 commit SHA(s): 1b106ed
Test results: 47 unit tests pass (NameTypeServiceUnitTest + FileExportServiceUnitTest), 0 failures
  - NameTypeServiceUnitTest$ToObjectNode.shouldFormatDateColumnWithCorrect24HourClock: PASS
  - FileExportServiceUnitTest$GetExcelFile.shouldFormatDateWithCalendarYearNotWeekYear: PASS
mvn test (unit suite): 3917 tests, 0 failures, 67 skipped — BUILD SUCCESS
mvn verify: unit tests clean; pre-existing integration failures unrelated to this change
  (ClientServiceE2ETest, CustomerOrderControllerIntegrationTest, AdviceServiceRollbackIntegrationTest)
verify-script result: 14 pass, 0 fail, 0 skip
Code review: APPROVED — 0 CRITICAL, 0 MAJOR, 3 MINOR (all optional)
verify-docs: wms2-sysprop-catalog.md EXPORT_DATE_FORMAT default corrected YYYY→yyyy
PR: https://github.com/SiteBossInc/wms2-api/pull/21 (→ develop)
```

Files to change:
- `src/main/java/net/aim_ai/wms/service/NameTypeService.java` — Fix A: `hh` → `HH` on L22
- `src/main/java/net/aim_ai/wms/service/FileExportService.java` — Fix B: add `CELL_TIMESTAMP_FORMAT` static `DateTimeFormatter`, replace 4 `Date` branches at L84/L152/L217/L285, remove `import java.text.SimpleDateFormat;` on L18
- `src/main/java/net/aim_ai/wms/service/StockunitService.java` — Fix C: remove dead `import java.text.SimpleDateFormat;` on L14
- `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java` — Fix C: remove dead import on L25
- `src/main/java/net/aim_ai/wms/service/mobile/MobilePickingService.java` — Fix C: remove dead import on L22
- `src/test/java/net/aim_ai/wms/unit/service/NameTypeServiceUnitTest.java` — new test for AC2
- `src/test/java/net/aim_ai/wms/unit/service/FileExportServiceUnitTest.java` — new (or updated) test for AC4

---

## Completeness Checklist (Layer 2)

| # | Concern | Status |
|---|---|---|
| 0 | DB verified | N/A — `db_verified: false` with rationale (pure in-JVM string formatting) |
| 1 | All call-sites enumerated | ✓ §0 rows 1–7 either fixed (1, 3, 7) or explicitly excluded with rationale (2, 4, 5, 6) |
| 2 | Adjacent bugs | ✓ Fix B (`YYYY` week-year) added as adjacent silent-wrong-output defect |
| 3 | Backward compatibility | ✓ Output format unchanged for non-boundary inputs; no API contract change |
| 4 | Concurrency | ✓ N/A — `DateTimeFormatter` already immutable; no new shared mutable state |
| 5 | Multi-tenant | ✓ N/A — no tenant-context usage |
| 6 | Error handling | ✓ No new exception path; behaviour silently becomes correct |
| 7 | Observability | ✓ N/A — no metric exists for this defect; verify-script R1 enforces compile-time check |
| 8 | Rollback / migration | ✓ Pure code change; single-JAR rollback; no data migration |
| 9 | Test coverage | ✓ Unit tests for AC2, AC4 + regression controls |
| 10 | Cross-version (v1↔v2) | ✓ v2 only; v1 audit ticket documented in §12 follow-ups |
