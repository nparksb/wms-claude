# SBDEV-3016 — Review Lane B: scope audit (what the mobile-only sweep missed)

**Scope verdict: SCOPE TOO NARROW**

The `controller/mobile/` scoping is defensible as "where this ticket's author was already
looking" but not as "the boundary of the defect." The identical defect shape — a `LOG.debug`/`.info`
label that names a different real handler, method, or endpoint than the one it sits in — exists
outside `controller/mobile/`, confirmed with file:line evidence below. It is not as dense outside
mobile (11–14% of files vs presumably higher in mobile, see below), but it is not absent either, and
one instance sits in the service layer exactly where the ticket's own commit message predicted it
would (a copy-pasted method body).

## Instrument

A Python script (`find_misattributed3.py`, ~230 lines) that:
1. Walks every `.java` file under a given root and, per method, records an "identity set" = the
   Java method name UNION any URL-path segments from its `@GetMapping`/`@PostMapping`/etc.
   annotation (so `PalletizingController.scanUnitLoad`, mapped to `/scanParcel/{input}`, is known
   under both `scanUnitLoad` and `scanParcel` — this matches how someone actually greps logs, by
   the endpoint they hit, not necessarily the Java identifier).
2. Builds one **global** identity→owner(s) registry across the whole tree (methods collide across
   files, which is exactly the mobile defect's shape: `PutawayController.requestLocation` logged
   `"scanPallet"`, a real handler that lives in `PalletizingController` and `TruckLoadingController`,
   not in `PutawayController` at all).
3. For every `LOG.<level>("literal")` inside method M, tokenizes the literal and flags any token
   that is a **registered identity of some OTHER (file, method)** and is **not also an identity of
   M itself** (so `PalletizingController.scanUnitLoad` logging `"scanParcel"` — its own path segment
   — is correctly NOT flagged; that's a convention issue, not a misattribution).
4. A second pass restricts the "other owners" count to ≤2 and token length ≥6, to separate
   distinctive compound identifiers (`createAndSelectPallet`, `getPickableLocations`) from generic
   English/domain words that also happen to be someone's short method name (`export`, `cancel`,
   `location`, `order`, `detail` — all false positives below, verified by reading the citing code).

**Validated against ground truth first.** Run against the pre-fix content of all 8 files this
sweep touched (7 uncommitted + `PickingController`, pulled via `git show HEAD:<path>` and
`git show d5a0d19f~1:<path>`, never touching the live worktree), it recovered 16 of the 21 known
labels automatically and led me by hand to the remaining 5 (three were URL-path self-matches,
correctly excluded by design; one, `TruckLoadingController` logging `"scanDestination"`, turned out
to be copy-pasted from a **service call** — `MobileMoveUnitloadController` calls
`mobileMoveUnitloadService.scanDestination(...)`, not a controller handler at all — evidence that the
carrier crosses the controller/service boundary, consistent with what lane B was asked to check in
service/). Every finding below was independently confirmed by reading the cited source, not taken
from the raw script output — the raw output floated **112** candidates and I discarded 101 of them by
hand as generic-word coincidences (`order`, `update`, `create`, `user`, `location`, `cancel`,
`export`, `tote`, `detail`, `groups`, `types` are all real short method names *somewhere* in a
61-controller codebase, and also all ordinary English/domain nouns used correctly in unrelated log
prose).

## 1. Other controller packages — PRESENT, low density, real

Scanned: 43 root `controller/*.java` (383 `LOG.*` calls) + 9 `controller/rest/*.java` (103 calls) +
1 `controller/actuator/*.java` (0 calls) = 53 files, 486 `LOG` calls.

**11 confirmed misattributed labels in 6 of 43 root controllers (14% of files, ~3% of calls). Zero
in `rest/` and `actuator/`** (the `rest/` hits that the raw script found — `OrderRestController`
"cancel"/"order", `TransactionReportRestController` "detail" — are confirmed false positives: `cancel`
is CycleCountController's real `/cancel` endpoint but the citing text is ordinary English describing
the current method's own action, `detail` is OrderCancellationController's real handler but the
citing text is "Transaction detail report", a domain phrase, not a reference).

Worst / all 11, file:line:

| # | Site | Logs | Real owner of the label |
|---|---|---|---|
| 1 | `UnitLoadController.java:109` `deleteContainer()` | `"start reprintLabel unitload={}"` | `UnitLoadController.reprintLabel()` (`:69`) — same file |
| 2 | `UnitLoadController.java:144` `bulkDeleteContainer()` | `"start reprintLabel unitload={}"` | same as above — 2nd site |
| 3 | `UnitLoadController.java:178` `deleteContainerRecursive()` | `"start reprintLabel unitload={}"` | same as above — 3rd site |
| 4 | `UnitLoadController.java:237` `childrenUnitloads()` | `"unitloadDetailsById ={}"` | `UnitLoadController.unitloadDetailsById()` (`:231`) — same file |
| 5 | `ReplenishOrderController.java:283` `create()` | `"start getPickableLocations"` | `ReplenishOrderController.getPickableLocations()` (`:246`) — same file |
| 6 | `ReplenishOrderController.java:343` `stockUnitInfoForReplenishment()` | `"replenishorderDetailsById ={}"` | `ReplenishOrderController.replenishorderDetailsById()` (`:337`) — same file |
| 7 | `ReceivingController.java:299` `createPallet()` | `"start createAndSelectPallet scanned text ={}"` | `ReceivingController.createAndSelectPallet()` (`:244`) — same file |
| 8 | `UserController.java:675` `getUserDetails()` | `"getAllRoles start"` | `UserController.getAllRoles()` (`:627`) — same file |
| 9 | `CustomerOrderBatchController.java:71` `batchUpdatePriorityByBatchIds()` | `"start priorityBatchUpdate ={}"` | `CustomerOrderBatchController.priorityBatchUpdate()` (`:45`) — same file |
| 10 | `CustomerOrderController.java:92` `pickingDateBatchUpdate()` | `"start priorityBatchUpdate ={}"` | `CustomerOrderBatchController.priorityBatchUpdate()` — **cross-controller**, same shape as the mobile defect |
| 11 | `CustomerOrderController.java:117` `batchUpdatePriorityByOrderIds()` | `"start priorityBatchUpdate ={}"` | same cross-controller collision — 2nd site |

`#10`/`#11` are the ones that match the mobile defect's exact risk profile: grep the logs for
`priorityBatchUpdate` (the ticket's real name in `CustomerOrderBatchController`) and get traffic
from two *different* handlers in *another* controller (`CustomerOrderController`) that never call
it.

## 2. Service layer — PRESENT, rare, exactly the shape predicted

Scanned: `service/` (108 files, 1120 `LOG` calls), `service/mobile/` (10 files), `service/job/` (0
files with hits). Same-file-only check (cross-file service-name collisions are almost entirely noise
— generic CRUD verbs like `save`/`find`/`update` are reused across dozens of unrelated services, so
only intra-class collisions were kept as signal).

**1 confirmed finding, in `KeycloakService.java`:**

```
689: public UserRepresentation createSingleUser(...)
691:     LOG.info("Beginning createSingleUser");    <- correct, own name
...
739: public UserRepresentationWithTempPw createSingleUserWithTempPassword(...)
741:     LOG.info("Beginning createSingleUser");   <- copy-pasted from :691, names the WRONG sibling method
```

5 other same-file candidates were investigated and are false positives (verified by reading the
cited code): `AdvisoryLockService.unlock()` mentioning `tryLock()` is explanatory prose about a
precondition, not a mislabel; `PrintService.submitCupsJob()` logging `"cupsPrint failed"` is the
callee naming its actual caller (`cupsPrint()` calls `submitCupsJob()` per the class's own javadoc);
`PutawayDestinationResolver` and `LocationTypeService` hits are the ordinary English verbs
"resolve"/"create" coinciding with unrelated short method names; `StockunitService`'s two hits on
`printLabel` are the method's own **parameter** name (`Boolean printLabel`), not a reference to the
unrelated private helper `printLabel(boolean, ...)` in the same class.

So: services are a real but rare carrier (1 site found across 1120 log calls), and it is the exact
mechanism the ticket's own commit message predicted (copy-pasted method body, label not updated) —
just one order of magnitude less frequent than in the mobile controllers.

## 3. Prior sweep (`chore/wms2-misattributed-loggers`, SBDEV-3177) — CLAIM CONFIRMED, different defect entirely

Found the commit: `f460125e` ("fix(logging): SBDEV-3177 re-attribute 7 misattributed loggers and pin
the rule"), merged via PR #251 as `c8b3634f` on `2026-08-31`, well before this ticket's `2d56ac4c`.

**What it actually changed** (`git show --stat f460125e`): the **static Logger field declaration**
in 7 classes —

```
PrintService                    -> was LoggerFactory.getLogger(ReceivingService.class)
MessageService                  -> was LoggerFactory.getLogger(ReceivingService.class)
PickingorderUnitloadService     -> was LoggerFactory.getLogger(PickingorderService.class)
ClubLineController               -> was LoggerFactory.getLogger(ClientController.class)
TransfersController             -> was LoggerFactory.getLogger(ClientController.class)
StockCountRestController        -> was LoggerFactory.getLogger(OrderRestController.class)
TransactionReportRestController -> was LoggerFactory.getLogger(OrderRestController.class)
```

plus a new test, `src/test/java/net/aim_ai/wms/unit/config/LoggerAttributionArchTest.java` (166
lines), that reflects over every `static Logger` field in the codebase and asserts
`logger.getName()` equals the declaring class's own name.

**This is a structurally different defect from SBDEV-3016's.** SBDEV-3177 fixed *which logger
instance a class uses* — a **class-level** bug, visible to reflection because a `Logger` field has
an identity (`getName()`) independent of any source text, comment, or formatting. SBDEV-3016 fixes
*what a log message string says* — a **method-level, string-content** bug. The logger field in every
one of the 8 files this sweep touches was already correctly attributed; the defect is entirely inside
string literals passed as call arguments, which carry no reflectable identity at all.

**Files changed by f460125e**: `ClubLineController.java`, `TransfersController.java`,
`StockCountRestController.java`, `TransactionReportRestController.java`, `MessageService.java`,
`PickingorderUnitloadService.java`, `PrintService.java`, plus the new test file. **None of these are
in `controller/mobile/`.** The author's claim — "the merged `chore/wms2-misattributed-loggers` sweep
never touched any of these seven files" — is **confirmed true** by direct diff inspection, not just
absence-of-evidence: zero file overlap between SBDEV-3177's 7 changed production files and this
ticket's 8 (7 uncommitted + `PickingController`).

## 4. Durable guard — NO for a hard-failing gate; YES for a non-blocking audit script

`LoggerAttributionArchTest` (the SBDEV-3177 pin) is possible **because logger identity is binary and
exact**: a field either is or isn't named after its declaring class, with zero ambiguity and (per its
own javadoc) zero false positives across 197 logger declarations.

The SBDEV-3016 defect has no equivalent structural signal. I built and ran exactly the kind of
detector this recommendation needs to evaluate (§1–2 above), and its raw output was **112 candidates
of which 101 (90%) were false positives** — ordinary English/domain words (`order`, `create`,
`update`, `cancel`, `location`, `export`, `detail`, `user`, `tote`, `groups`, `types`) that also
happen to be someone's short, real method name in a 61-controller, ~450-method codebase. Every one of
those false positives required reading the citing source and making a judgment call about whether the
word was used as prose or as a reference — the same judgment call `wms-triage`'s "sibling sweep"
already asks a human/agent to make, not something byte-identity can resolve.

Two additional facts bear on the recommendation:
- **Bytecode is a real option, source-parsing is not the only alternative.** `LOG.debug("literal")`
  string constants sit in the class's constant pool and ASM (already usable in this repo the way
  `LoggerAttributionArchTest` uses raw reflection) visits string constants **per method** naturally —
  no LineNumberTable correlation needed, unlike a source regex that has to reconstruct method
  boundaries from text. So "parsing Java source is fragile" is true of the specific approach tried,
  but overstates the case against automation in general — a bytecode-level detector is buildable and
  would be immune to comment/whitespace drift the way the existing test is.
- **But it would still need the same 90%-noise filter I applied by hand**, because the false-positive
  source isn't parsing fragility, it's semantic: short, real, generic-word method names are
  indistinguishable from ordinary log prose without reading intent. Even my tightened heuristic
  (≤2 total owners, token length ≥6) still let through `unitLoad`/`printLabel`-shaped false positives
  that needed a source read to clear.

**Recommendation: do not add a hard-failing ArchUnit/unit test for this.** Unlike the logger-field
defect, there is no zero-false-positive structural check available, and a test with this precision
profile (roughly 1-in-10 hit rate even after tuning) would either be routinely ignored/suppressed or
would block unrelated PRs on prose disagreements — the opposite of what a pin should do. The prose
convention in `CLAUDE.md` is the right ceiling for this specific defect shape. If tooling is wanted
anyway, build the bytecode-constant-pool version of §1–2's detector as a **non-blocking periodic audit
script** (like `verify-docs` or the sync-sweep tooling) that a human triages, not a gate that fails CI.

## 5. Other copy-paste artifacts in the 7 (+1) touched files — 3 kinds found, not fixed here

**a) A whole dead handler, commented out, carrying 2 dead log lines** —
`PickingController.java:89-121`: `processRapidPickScanPackageType` — the `@PostMapping` annotation,
full method signature, and body are commented out (`//` on every line), including
`LOG.debug("processRapidPickScanPackageType input = {}", reqMap);` (`:91`) and
`LOG.debug("processRapidPickScanPackageType finished");` (`:120`). Dead code the sweep's own label
fix (line 241's `requestPickingOrders` rename sits ~120 lines below it) walked straight past.

**b) Duplicate identical log message at two distinct sites in one method** —
`PutawayController.java:54` and `:61`, inside `requestLocation()`: both the `catch (BusinessException
e)` block and the separate `catch (FacadeException fe)` block call the byte-identical
`LOG.warn("Failed to release unit load back to putaway lane after error", releaseEx);`. The two
exception paths are indistinguishable in the logs — you can tell the release failed but not which of
the two original exception types triggered it.

**c) Entry logs with no matching completion log, where sibling methods in the same class have one**
— found in 3 of the 7 touched files, 9 methods total, all simple single-branch GET handlers (no
try/catch, 2-3 lines of body) sitting next to POST/error-branching siblings that do log both ends:
  - `CycleCountLosController.java:184,191,198` — `orderList()`, `locationList()`, `unitLoadList()`
  - `ReplenishController.java:158,165,172,180` — `reservedOrder()`, `clientList()`, `orderList()`,
    `loadOrderById()`
  - `TruckLoadingController.java:50,64` — `orderList()`, `truckLoadingInfo()`

Not proposing a fix for any of (a)–(c) here — flagging per the review remit only.

## Summary quantification

| Area | Files scanned | LOG calls scanned | Genuine misattribution sites | Files with ≥1 |
|---|---|---|---|---|
| `controller/` (root) | 43 | 383 | 11 | 6 |
| `controller/rest/` | 9 | 103 | 0 | 0 |
| `controller/actuator/` | 1 | 0 | 0 | 0 |
| `service/` + `service/mobile/` + `service/job/` | 118 | 1120 | 1 | 1 |
| `controller/mobile/` (this ticket, pre-fix, for reference) | 11 | ~130 | 21 (19 uncommitted + 2 in `PickingController`) | 8 |

Mobile was ~2x denser by file-hit-rate (8/11 = 73%) than the rest of the controller tree (6/43 = 14%)
and roughly 15x denser than the service layer (1/118 = 0.8%) — consistent with mobile being a genuinely
worse hotspot, but the other packages are not clean.
