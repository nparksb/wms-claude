# SBDEV-3016 Review Lane A — Mangled handler rename in PickingController

Worktree: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3016`
Branch: `chore/SBDEV-3016-mangled-handler-name` (based on `origin/develop` @ `92ca2e38`)
File under review: `src/main/java/net/aim_ai/wms/controller/mobile/PickingController.java`

## Verdict: APPROVE

## Diff reviewed

```
git -C <worktree> diff origin/develop -- src/main/java/net/aim_ai/wms/controller/mobile/PickingController.java
```

```diff
@@ -237,8 +237,8 @@ public class PickingController extends AdminController {
     @GetMapping(path= "/pickingOrders/{input}", produces = "application/json")
-    public ResponseEntity<Object> requpickingOrdersestLocation(@PathVariable("input") String input, @AuthenticationPrincipal Principal principal) {
-        LOG.debug("scanPallet input = {}", input);
+    public ResponseEntity<Object> requestPickingOrders(@PathVariable("input") String input, @AuthenticationPrincipal Principal principal) {
+        LOG.debug("pickingOrders input = {}", input);
```

Confirmed 2-line diff, no other hunks in the file, no other files touched.

## Findings

None at High or Medium severity.

**Low — log label doesn't echo the new method name (line 241).** File: `PickingController.java:241`.
Sibling handlers in this same controller consistently name their debug label after the method itself: `processRapidPickScanPackage input = {}` (line 65), `resetPickingOrder input = {}` (line 208), `releasePickingOrder id = {}` (line 255), `pickingOrderPositionsInfo id = {}` (line 285). The new label is `"pickingOrders input = {}"`, which echoes the URL segment (`/pickingOrders/{input}`) rather than the method name `requestPickingOrders`. This is a defensible choice — the label is at least *accurate* now (the old `"scanPallet"` label was flatly wrong, copy-pasted from an unrelated handler) — but it's a minor stylistic inconsistency with the file's own convention. Non-blocking; would only take one more word to fix (`"requestPickingOrders input = {}"`). Recommend leaving as-is or fixing trivially in the same commit — either is fine for a T0 change; not worth blocking on.

## a–e checklist

**a) Zero residual references to `requpickingOrdersestLocation` under src/ (main+test) and src/test/resources.**
PASS. `grep -rn "requpickingOrdersestLocation" src/` → no matches (exit 1). Repo-wide grep (excluding `.git/`) finds it only in two documentation files that are *describing* this exact fix historically: `CLAUDE.md:282` ("...tracked as SBDEV-3016 Fix 2") and `docs/plan/completed/PICKING_PERFORMANCE_PLAN.md:100` (a symbol-mapping table entry). Both are expected, descriptive, out of scope for this diff — not residual code references. `src/test/resources/archunit_store/` (the only test-resources hit for the search terms "archunit") contains an unrelated cached rule about `Optional.get()` (SBDEV-2116); grepped its binary/text content directly for both old and new names — no match.

**b) `requestPickingOrders` does not collide with another symbol, in particular another mobile-controller handler.**
PASS. `grep -rn "requestPickingOrders" --include="*.java" src/` returns exactly one hit: the declaration itself at `PickingController.java:240`. Checked the full mobile controller package listing (11 controllers: CycleCountLosController, LookupController, MoveStockController, MoveUnitloadController, OrderCancellationController, PalletizingController, **PickingController**, PutawayController, ReplenishController, TransferOrderController, TruckLoadingController) — no other file defines a method of this name. No collision.

**c) Nothing keys on the method NAME rather than (declaring class, path).**
PASS, checked hard as instructed.
- `FunctionGuardInterceptor.java` (SBDEV-3017/2968 gating machinery) resolves authorization via `handlerMethod.getMethodAnnotation(RequiresFunction.class)` / `.getMethodAnnotation(PublicHandler.class)` and a class-level fallback keyed on `handlerMethod.getMethod().getDeclaringClass()` — i.e., annotation lookup by reflection on the `Method`/`Class` objects, not by name string. `handlerMethod.getMethod().getName()` appears only in log messages and a Micrometer metric tag (lines ~223, 234, 249) — cosmetic, not a lookup key.
- `PickingController` carries its `@RequiresFunction(WmsConstants.FunctionEnum.MOBILE_UI_VIEW_PICKING)` at the **class level** (line 33), not per-method — so gating for this route is entirely unaffected by the method's identifier.
- ArchUnit: only stored rule in `archunit_store/stored.rules` is the unrelated `Optional.get()` ban (SBDEV-2116); no rule text or cached violation set references this method by name.
- `PickingControllerUnitTest.java` (the only test file referencing this endpoint) drives it via `mockMvc.perform(get("/v3/picking/pickingOrders/SECTION-A"))` — path-based, not method-name-based (lines 263, 277). `@DisplayName("pickingOrders")` at line 248 is a human-readable label, not a lookup key.
- No `-Dtest=`, SpEL, `@PreAuthorize` SpEL expression, or reflective `getMethod("requpickingOrdersestLocation")`/`getMethod("requestPickingOrders")` call exists anywhere in the repo (grepped `.java/.xml/.yml/.yaml/.properties/.json`). One incidental substring match on `require*` (`PutawayConfigService.getMethod("requireWarehouseConfigWriteAuthority")` in `MethodSecurityEnablementContractTest.java:134`) is an unrelated method on an unrelated class — coincidental token overlap only.

**d) URL mapping unchanged; wms2-mobile-ui calls the PATH, not the method name.**
PASS. `@GetMapping(path="/pickingOrders/{input}", ...)` is untouched by the diff (only the two body lines changed). Confirmed in `v2/wms2-mobile-ui/store/picking.js:402`: `await this.$axios.$get(\`/picking/pickingOrders/${data.value}\`)` — the client calls the URL, never references any Java method name. No client contract moves.

**e) Log-line change (line 241) — correctness and safety.**
PASS, with the Low style note above. `LOG.debug("pickingOrders input = {}", input)`: one `{}` placeholder, one vararg (`input`) — no format-arg mismatch (the old line had the same 1:1 shape). `input` is a section/query string path variable, not a credential or otherwise sensitive field — no PII/label leak, consistent with how sibling handlers in this file log their own `input`/`inData`/`id` path variables at DEBUG. The new label is strictly more correct than the old `"scanPallet"` (which was copy-pasted from a different handler and actively misleading in log searches/greps). Only nit is that it doesn't echo the new method name exactly (see Low finding).

## Scope recommendation (log-line change, item 2)

**Keep it in the same commit.** The log line was not just cosmetically wrong — `"scanPallet input = {}"` under a `requestPickingOrders` (nee `requpickingOrdersestLocation`) method is a misattributed logger that would mislead anyone grepping logs for `scanPallet` (a real, different handler in this codebase) while debugging picking-order requests, or grepping for picking-order activity and missing it because it's labeled as something else. Fixing the identifier while leaving the log statement mislabeled would leave the more operationally relevant half of the mangling in place. This is still a 1-method, 2-line, no-behavior-change diff — well within T0 scope. Splitting it into two commits/PRs for a T0 chore would add process overhead disproportionate to the change.
