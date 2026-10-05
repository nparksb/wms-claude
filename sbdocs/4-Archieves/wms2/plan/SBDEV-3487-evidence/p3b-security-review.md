# Security Review Report: SBDEV-3487 (v2/wms2-api)

**Scope:** `git diff b950c994..HEAD` in `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3487`. The production files are `BillofladingPositionRepository.java`, `BillofladingPositionService.java`, `MobileMoveUnitloadService.java`, `MobileTruckLoadingService.java` and `MobileTruckLoadingWriteService.java`, all under `src/main/java/net/aim_ai/wms/`. I also went through the 8 changed test files.
**Risk Level:** LOW

## Summary
- Critical: 0
- High: 0
- Medium: 0
- Low: 1 (information disclosure on the move-unitload path; a hardening note, and no fix is required)
- Informational: 1 (log line carries a scanned label; it is bounded, and the codebase already does this elsewhere)

## Findings

### L-1. The move-unitload path now shows a CLOSED BOL name to users who hold only the TRANSFER function
**Severity:** LOW
**Category:** A01 / information disclosure
**Location:** `src/main/java/net/aim_ai/wms/service/BillofladingPositionService.java:42-47`, reached from `MobileMoveUnitloadService.java:499` (`/v3/moveUnitload`, class gate `@RequiresFunction(MOBILE_UI_VIEW_TRANSFER)`)
```java
throw new BusinessException("billOfLadingPositionUnxepectedStateFound", palletLabel, closedBolName);
```
**Comparison with the existing checkPallet message:**
- **scanGate (`/v3/truckLoading`, `MOBILE_UI_VIEW_TRUCK_LOADING`):** no worse than before. `/scanPallet` → `checkPallet` (`MobileTruckLoadingService.java:115-117`) already returns the same key with the same two parameters: the pallet label, and the BOL name or `bp.number`. The same function gate covers both endpoints. The new query even uses the same fallback, `coalesce(b.name, bp.number)`. Neither path filters by `client_id`, so any user in the tenant who holds `MOBILE_UI_VIEW_TRUCK_LOADING` could already get any client's closed BOL name through `/scanPallet`. That gap existed before this diff.
- **moveUnitload:** this is new exposure. A user who holds `MOBILE_UI_VIEW_TRANSFER` but not `MOBILE_UI_VIEW_TRUCK_LOADING` now receives the BOL name.

**Exploit scenario:** a TRANSFER-only user scans a shipped pallet (one sitting in Shipped) and a destination location. The move rolls back and the response says `Pallet X already part of BOL Y`. To do this they must already have the real label of an existing unitload that matches the outbound-pallet regex. They also need the move to reach `transferUnitLoadToLocation` before the guard fires.
**Blast radius:** a BOL name, which is an operational identifier and not PII or a credential. The tenant boundary holds, because the query runs on the `X-Tenant-ID`-routed datasource. Nothing is written, since the move rolls back.
**Remediation (optional):** keep it. Operators need the BOL name to act on the error, and the same information is readily available through truck loading. If you want the move path to disclose nothing, use a message without the name there:
```java
// in assertPalletNotShipped, vary the message by site
if (site == ShippedGuardSite.MOVE_UNITLOAD_D0 || site == ShippedGuardSite.MOVE_UNITLOAD_D0_RECHECK) {
    throw new BusinessException("Pallet " + palletLabel + " is already shipped and cannot be moved.");
}
throw new BusinessException("billOfLadingPositionUnxepectedStateFound", palletLabel, closedBolName);
```

### I-1. The WARN line logs the scanned pallet label without neutralizing CR/LF
**Severity:** Informational (below Low)
**Category:** A09 / log injection
**Location:** `BillofladingPositionService.java:45`, `MobileMoveUnitloadService.java:512`, `MobileMoveUnitloadService.java:588`
```java
LOG.warn("SBDEV-3487 shipped-pallet guard [{}]: pallet {} is already shipped on CLOSED BOL {}", site, palletLabel, closedBolName);
```
The log patterns in `logback-spring.xml:9,22` and `application.properties:5` use plain `%msg` with no `%replace` or CRLF encoding. Even so, a forged log line is not reachable in practice:
- **Regex gate:** the label must match the outbound-pallet regex before any of these lines runs. On scanGate that check is `OutboundPalletLabelGuard.requireOutboundPalletLabel` at `MobileTruckLoadingService.java:166`. In both D0 variants it is the `matches` guard around the call. `.` and literal patterns do not match `\n`.
- **Exact DB match:** the WARN fires only when a row has `u.labelid = :label` exactly. The label therefore has to be a real stored labelid, not arbitrary input.
- **Existing precedent:** the codebase already logs raw labels. See `LOG.debug("handle truck off loading for {}", unitLoadLabel)` at `MobileMoveUnitloadService.java:490`, and the sibling WARNs in the same service at lines ~54, 106 and 126.

`OutboundPalletLabelGuard:72-73` does say "The label is left out: it is user input". That rule applies to its *rejection* log, which fires before any validation. It does not apply here.
**Remediation:** none needed for this change. If you want a system-wide fix, do it once in logback rather than at each call site:
```xml
<pattern>... %replace(%msg){'[\r\n]', '_'}%n</pattern>
```

## Category-by-category (no finding unless noted)

| Category | Verdict | Evidence |
|---|---|---|
| **A03 SQL injection** | No finding | `findClosedBolNameBySourceUnitLoadLabel` (`BillofladingPositionRepository.java:110-114`) is a static native string bound with `@Param("unitLoadLabelId")`. The `'CLOSED'` literal is a constant, not input. The 4 delete predicates add `AND (bp.state IS NULL OR bp.state <> 'CLOSED')` as constant JPQL concatenated at compile time. Their only parameters are `:bolPositionId` and `:carrierIds`, both bound. The test diff has no SQL concatenated with variables (checked by grep). |
| **A01 Authz ordering** | No finding | `TruckLoadingController` has class-level `@RequiresFunction(MOBILE_UI_VIEW_TRUCK_LOADING)` (`TruckLoadingController.java:31`). `MoveUnitloadController` has class-level `@RequiresFunction(MOBILE_UI_VIEW_TRANSFER)` (line 28). The function gate is a handler interceptor, so it runs before the controller method and before the new facade call at `MobileTruckLoadingService.java:170` and both D0 backstops. The new call sits after `requireOutboundPalletLabel` and before `truckLoadingWriteService.scanGate`, so no lock is taken for a rejected pallet. |
| **A01 SDR exposure** | No finding | The repository is `@RepositoryRestResource(..., exported = false)` at class level (line 20). The new finder is also `@RestResource(exported = false)`. Changing `deleteBolPositionById` from `void` to `int` therefore adds no HTTP surface. The class-level `exported=false` already withdraws the method-level `path=` delete resources, and this diff does not change that. |
| **Info disclosure** | L-1 | See above. Tenant isolation is intact because the query goes through the tenant-routed datasource. No client_id scoping exists, but that is pre-existing and matches `checkPallet`. |
| **Error-shape / XSS** | No finding | The message goes into `{"errors":[{...}]}` via `getErrorMessage("Runtime Error", e.getMessage())` as JSON with HTTP 200. That is the existing shape for the same key. The label is regex-constrained and the BOL name is server data. |
| **A09 Log injection** | Informational (I-1) | See above. |
| **DoS via new query** | No finding | Verified on Hydra PRD (`wms2-hydra`): `index_billoflading_position_source_id` btree on `billoflading_position(source_id)`, and `uq_unitload_labelid` plus `uk_s2uj...` unique on `unitload(labelid)`. Both are also in `db/migration/V2.2.00__base_v2_schema.sql:3772,3820,4002`. `billoflading.id` is the PK. The plan is a unique-index lookup, then a source_id index scan, then a PK join, with `LIMIT 1`. It runs at most 3 times per request (facade, D0, and the 0-row recheck), all behind a function gate. |
| **Delete predicate integrity (A04)** | No finding (positive) | The `IS NULL` arm keeps null-state purging working. The predicate stops a CLOSED shipping record from being deleted even when a lock wait gets past the read-time check, which improves integrity. |
| **Secrets in fixtures** | No finding | Grepped the `+` lines of the test diff for `password\|secret\|token\|api_key\|jdbc:\|bearer\|credential`: 0 hits. |
| **A06 Dependencies** | No finding / N/A | The diff does not touch `pom.xml`, so no dependency audit applies. I ran no Maven, per the lane constraints. |
| **A02 / A05 / A07 / A08 / A10** | N/A | No crypto, config, auth-flow, pipeline or outbound-URL changes in the diff. |

## Security Checklist
- [x] No hardcoded secrets (production and test diff)
- [x] Inputs validated: the label passes the outbound regex before any new code uses it
- [x] Injection prevention verified: bound parameters only
- [x] Authentication/authorization verified: class-level `@RequiresFunction` runs before the new facade call; the SDR surface is unchanged (`exported=false`)
- [x] Dependencies: none changed
- [x] Query indexed on PRD (Hydra)

**Verdict:** no blocker. L-1 is optional hardening. The client_id-blind BOL-name disclosure across clients within one tenant already exists through `/scanPallet` (`checkPallet`), and this diff does not create or worsen it on the truck-loading path.