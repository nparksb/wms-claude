---
name: sbdev-3030-admin-error-body-and-guard-mutation-trap
description: SBDEV-3030 SHIPPED in 3 slices — the legacy-200 release trap, the 401/403 gap, and two ways a green test count lies
metadata: 
  node_type: memory
  type: project
  originSessionId: 4afc322a-0e0b-493a-9bfe-45f0ae03aea9
  modified: 2026-08-28T18:02:33.925Z
---

**SBDEV-3030 SHIPPED 2026-08-28 in three slices, all merged to `develop`** (`cdaf9b0`):
PR #96 `c45f883` (roles/users delete + `util/apiError.js` 401/403), PR #97 `76a410c` (37 admin write
actions + printer delete contract), PR #98 `cdaf9b0` (~39 read actions + 5 more defects). Final:
73 suites / 1119 tests. **Zero `console.log(error)` and zero hardcoded generic literals remain under
`store/admin/`.** ~170 literals outside `store/admin/` were never in scope; two `handlingUnits/popups/*`
dialogs share the close defect and are unfiled.

**FIVE instances of one dialog defect** were found, not one: `deleteRolePop`, `deleteUserPop`,
`deletePrinterPop`, `bulkEditUsers`, `testPrinterPop`. Instances 3-5 were missed by the first sweep
because it grepped for `$emit('close')` — `deletePrinterPop` emits `clearDeletePrinter` and
`testPrinterPop` calls `this.close()`. **An event-name grep is always narrower than it looks.**

Six things worth keeping:

**1. `deleteUser` must keep its legacy `200 {errors:[…]}` guard — it is dead only on `develop`.**
Pre-SBDEV-3012 the endpoint answered a *refused* delete with **HTTP 200** carrying an `errors`
array, and axios does not reject on a 200. None of the SBDEV-3012 API commits is in a release, so
every environment fed from `main` still serves that contract — see
[[wms2-gating-programme-is-live-on-prd]]. PR #96 makes the store's return value
the authoritative "the user is gone" signal that the dialog closes on, so **without the guard the
hardened UI reports a green "User deleted" and closes, against the very API it was written to
defend against.** `updateUser`/`saveUser`/`bulkEditUsers` in the same file already guarded this.
`deleteRole` needs no mirror guard: the pre-SBDEV-3011 role endpoint 500'd rather than returning 200.
**Do not delete this as dead code.**

**2. `apiErrorReason` was blind to 401/403 — now fixed in `util/apiError.js`.**
`FunctionGuardInterceptor` emits `{type,title,status,reason,requiredFunction}`, which carries **none**
of the four keys `apiErrorReason` reads (`parameterErrors`, `error`, `detail`, `message`), so a
permission denial rendered as "network or server issue. Please retry." Spring Boot's fallback
`/error` body is `{"status":403,"error":"Forbidden"}`, which *does* match shape 1 and would have
relayed the bare reason phrase — so the 401/403 branch deliberately ignores `reason`. A caller's own
`fallback` still wins; the pre-existing `apiError.spec.js` caught that regression when the first
attempt hardcoded the message over it.

**3. GENERAL TRAP — a guard clause inside a `try` cannot be mutation-tested by deleting it.**
Removing `if (!this.itemToDelete) return` looked like it should red a test. It did not: the
subsequent `this.itemToDelete.id` throws **inside the try**, the `catch` swallows it, the `finally`
still runs, so every observable assertion (no dispatch, no `$emit`, spinner hidden) held either way.
The test was **vacuous and would have shipped proving nothing.** Only *"the spinner was never
shown"* distinguishes "guarded" from "threw and was absorbed". Same shape defeats mutating an early
`return` when a `finally` is present. When a mutant survives in `try`-wrapped code, first ask whether
it is *equivalent* rather than assuming a test gap. See [[green-tests-that-prove-nothing]],
[[mutation-harness-traps]].

**4. GENERAL TRAP — a green Jest test COUNT hides dead suites.** A blanket literal→constant sweep
turned `labelPrinting.js`'s own `const GENERIC_ERROR = '...'` into `const GENERIC_ERROR = GENERIC_ERROR`.
Two suites died at load and **205 tests vanished**, while the summary read `Tests: 840 passed, 840 total`
— fully green. Always compare the test COUNT against the previous run, and check `Test Suites:` too;
`numFailedTestSuites` in `--json` is the reliable signal.

**5. GENERAL TRAP — module-load coverage is invisible until it bites.** Three admin stores
(`client.js`, `function.js`, `mgmt/overview.js`) were loaded by **no test at all**, and they were exactly
the three where a sweep added a new module-level import. The syntax error above was caught only because
it happened to land in a file two suites require. A structural test that `readFileSync`s a file proves
nothing about whether it *parses* — only a `require` does. Before any programmatic sweep, check which
touched files are actually loaded by a test.

**6. In a `.vue`, `logApiFailure` labels name the DISPATCHED store action, not the enclosing method**
(`logApiFailure('deleteRole dispatch rejected')` inside `deleteItem()`). A label-vs-method check reds
correct code there. Also: a store-shaped action regex (`name(context…`) matches **nothing** in a
component, because methods take no `context` — so a check written that way is inert, not protective.

Also: a hand-rolled JS mutation harness must verify restore by **content hash**, not
`git diff --quiet` — against a working tree with legitimate uncommitted changes the git check reports
"dirty" for every file and tells you nothing. And anchor mutants by **line number** when the target
text appears in several actions; `replace(old, new, 1)` silently hits the wrong one.

Related: [[sbdev-3012-user-group-write-atomicity]], [[sbdev-3011-delete-role-join-table-cascade]],
[[wms2-web-ui-coverage-instrumentation-disarms-render-source-pins]],
[[address-low-review-findings-too]]
