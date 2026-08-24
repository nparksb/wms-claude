All shadows built and scored. Report follows.

---

# BREAK REPORT — `verify-SBDEV-2995-palletising-receiving-accept-nirvana-sentinel.sh`

**Baselines reproduced exactly.** Unfixed `origin/develop` (`e7b3b88`) → `6 pass, 12 fail, 1 skip`. My independently-built correct implementation → `18 pass, 0 fail, 1 skip`.

Shadows live at `/tmp/claude-1000/-home-nampark-dev-wms-claude/009d04f4-ec21-44a5-8ee4-7b54fc0d80bc/scratchpad/m/<name>`; the clean reference is `.../scratchpad/good`, unfixed is `.../scratchpad/base`. Nothing in any repo working tree was touched.

**Headline: 13 FALSE GREENS at `18 pass, 0 fail` and 10 FALSE REDS on behaviourally-correct code.** Of the 10 previously-claimed-fixed escapes, 9 are genuinely dead; 1 (test stubs) still escapes.

---

## Re-test of the 10 known escapes

| Escape | Score | Verdict |
|---|---|---|
| guard in CREATE arm | `14/4` (A1 A2 A3 A4 red) | fixed |
| `!` dropped | `17/1` (A1) | fixed |
| `LOG.warn` not `throw` | `16/2` (A1 A3) | fixed |
| `_CART` not `_PALLET` | `17/1` (A4) | fixed |
| sysprop-gated guard | `17/1` (A5) | fixed |
| empty `assertSourceUnitLoadMovable` | `17/1` (B2) | fixed |
| called twice in `scanDestination`, never in `scanUnitLoad` | `17/1` (B3) | fixed |
| Fix B call in a **same-line** conditional | `17/1` (B4) | fixed |
| Fix B call after `findByUnitloadId` | `17/1` (B4) | fixed |
| **both test files → token stubs** | **`18/0`** | **STILL ESCAPES** (see F12) |

---

## FALSE GREENS — ranked by severity

### F1 — `N1_decoy_helper_above` — bug 100% unfixed, `18 pass, 0 fail` (WORST)
A dead `private Unitload resolveExistingPalletChecked(Optional<Unitload>)` inserted **above** `palletise`, containing a textbook-correct guard, and never called. `palletise`'s else arm reverted to unfixed `develop`.

Every `slice` anchor is a **first-match-in-file** search. `findByIdForUpdate(palletOpt` and `assertPalletNotAssignedToGate(` both now first occur inside the decoy, so `palletise_else_arm` returns the *decoy body*, not `palletise`. A1–A5 all read dead code. `palletise_create_arm` still resolves correctly (its start anchor `if (palletOpt.isEmpty())` sits after the decoy), so P1 stays green too.

This is the rev-1 lesson repeating one level up: rev 1 could not see *which branch*; rev 2 cannot see *which method*.

**Repair:** slice `palletise` first, then the else arm within it — e.g. `palletise_body() { slice 'void palletise\(List<ParcelMonitorDto>' '\n    @Transactional' "$PMV"; }` and have `palletise_else_arm` slice within that string rather than the file. Any anchor pair that can be satisfied by a method other than `palletise` is unsound.

### F2 — `N2_scanDestination_string_decoy` — Fix B 100% unfixed on the 210k path, `18/0`
`assertSourceUnitLoadMovable(sourceUnitLoad)` **removed entirely from `scanDestination`**; one line added at the top of `scanUnitLoad`:
```java
LOG.debug("next step is scanDestination");
```
`check_B3`/`check_B4` slice with the bare literal `scanDestination` (no `public void` prefix), so the slice now starts inside `scanUnitLoad` and runs to the next modifier — i.e. it grades the **tail of `scanUnitLoad`**, which legitimately contains `assertSourceUnitLoadMovable(` at line start followed later by `findByUnitloadId(`. B3 and B4 both green while the sentinel still materialises 210,167 entities.

**Repair:** anchor on the declaration: `slice 'public void scanDestination\(TransferInfoDto' ...`. Same class of bug as F1 — the anchor is a token, not a declaration.

### F3 — `N3_throw_swallowed` — guard inert, `18/0`
The type check is present, correct, in the right arm, before the write — and wrapped in `try { … } catch (BusinessException e) { LOG.warn(…); }`. A1's regex `(?:(?!;).)*?` only forbids a semicolon between `.equals(` and `throw`; it says nothing about what happens to the exception afterwards. A3 sees the `throw` token. Net behaviour is identical to no fix.

**Repair:** add a row asserting no `catch` between the locked re-fetch and the gate assertion: `! palletise_else_arm | grep -qE '\bcatch\s*\('`.

### F4 — `G9_fixA_value_flag_gate` — guard inert on every tenant, `18/0`
```java
@Value("${wms.palletise.type-guard:false}")
private boolean palletTypeGuardEnabled;
...
if (palletTypeGuardEnabled && !pallet.getTypeId().equals(palletType.getId())) {
```
A5 bans only `getSysvalue|parseBoolean`. A Spring `@Value` flag defaulting to `false` is exactly the "deliberately no feature flag" violation §6.1 forbids, and defaults OFF.

**Repair:** A5 should assert the *shape* of the condition, not blacklist two tokens — require the `if` condition between `!` and `.equals(` to contain no `&&`/`||`: `palletise_else_arm | grep -qE 'if\s*\(\s*!\s*[A-Za-z_]+\.getTypeId\(\)'` (a leading `if (` immediately followed by the negation).

### F5 — `G7_fixB_multiline_conditional` / `R11` — Fix B gated OFF, `18/0`
```java
if (Boolean.parseBoolean(syspropService.getSysvalue("wms.move.nirvana.guard"))) {
    assertSourceUnitLoadMovable(sourceUnitLoad);
}
```
The script's own comment at line 129-132 claims the line-start anchor "rejects `if (Boolean.parseBoolean(...)) assertSourceUnitLoadMovable(...)`". It rejects only the **same-line** form. Break the line — house style anyway — and `^[[:space:]]*assertSourceUnitLoadMovable\(` matches the indented call inside the block. `R11_scanDestination_first_stmt_in_block` (`if (sourceUnitLoad != null) { … }`) is the same hole with an innocuous condition.

**Repair:** the anchor must pin the *nesting depth*, not the line start. Cheapest sound version: require the call at exactly the method's statement indent — `grep -qE '^        assertSourceUnitLoadMovable\('` (8 spaces) — and separately ban `getSysvalue|parseBoolean` on the 3 lines preceding it.

### F6 — `G8_helper_body_inert` — Fix B inert, `18/0`
```java
private void assertSourceUnitLoadMovable(Unitload unitLoad) throws BusinessException {
    Unitload unitLoad_nirvana = unitloadService.getNirvana();
    LOG.debug("source={} nirvana={}", unitLoad, unitLoad_nirvana);
}
```
B2 was written to kill the empty stub, and greps only for `getNirvana(|STORAGE_LOCATION_NIRVANA`. A body that *mentions* Nirvana without comparing or throwing passes. This is the empty-stub escape wearing a hat.

**Repair:** B2 must require the predicate **and** the throw: `grep -qzE 'getNirvana\(\)(?s).*equals\((?s).*throw new BusinessException'` — or, more robustly, three separate greps (`getNirvana`, `.equals(`, `throw new BusinessException`) all within the sliced body.

### F7 — `N5_compare_cart_resolve_pallet` — inverted semantics, `18/0`
Resolve `UNIT_LOAD_TYPE_PALLET` (satisfying A4), then compare against a second lookup:
```java
UnitloadType cartType = unitloadTypeRepository.findByName(WmsConstants.UNIT_LOAD_TYPE_CART)...;
if (!pallet.getTypeId().equals(cartType.getId())) { throw new BusinessException("Not a pallet: " …); }
```
Result: rejects every real pallet, accepts every cart — strictly worse than no fix. A4 checks that the *constant is mentioned*; it never checks the constant is the one being compared. This resurrects the "CART instead of PALLET" escape by leaving the PALLET lookup as decoration.

**Repair:** A4 must bind the resolved variable to the comparison. Assert a single chain: `findByName\(WmsConstants\.UNIT_LOAD_TYPE_PALLET\)[^;]*?\s(\w+)\s*=` and then that same identifier inside `.equals(`. Or, much simpler and sufficient: ban `UNIT_LOAD_TYPE_(?!PALLET)` in the else arm.

### F8 — `N4_hardcoded_5L` — tenant-specific, breaks everywhere else, `18/0`
`if (!pallet.getTypeId().equals(5L))` with the `findByName(...UNIT_LOAD_TYPE_PALLET)` line left in place and unused. Green on all five A rows. Per `wms2-seqentities-dual-island-id-space` and the migrated-vs-fresh-seeded id divergence noted in the HMG memory, a hardcoded `location_type`/`unitload_type` id is precisely the failure mode this codebase has already been bitten by.

**Repair:** same as F7 — bind the `.equals(` argument to the identifier assigned from `findByName(...PALLET)`.

### F9 — `G10_mobile_guards_warn_only` — parity pin defeated, `18/0`
Both of `MobilePalletizingService`'s existing `throw new BusinessException("Not a pallet: …")` (lines 257, 350) replaced with `LOG.warn(...)`. P4 is `grep -c 'getTypeId\(\)[^\n]*equals' >= 2` — a **token count**, blind to what the branch body does. The pin that exists specifically to protect already-correct mobile behaviour cannot see it being deleted.

**Repair:** count the enforcement, not the condition: `[ "$(code_only "$MPS" | grep -cE 'throw new BusinessException\("Not a pallet')" -ge 2 ]`.

### F10 — `G11_carrier_guard_relocated` — carrier guard deleted, `18/0`
Removed the `if (pallet.getCarrierunitloadId() != null) throw …` block from `palletise`'s else arm; re-introduced the bare token inside `palletiseAndTruckLoad` as `if (pallet != null && pallet.getCarrierunitloadId() != null) { LOG.debug("x"); }`. P2 is `code_contains` — **file-wide**, and this file contains two near-verbatim palletise implementations (`palletise` :103, `palletiseAndTruckLoad` :235). Every file-wide `code_contains` row on `$PMV` is therefore satisfiable by the sibling method.

**Repair:** P2 and P3 must run against `palletise_else_arm`, not the file. (Note P3 is partly self-protecting — deleting `assertPalletNotAssignedToGate` destroys the else-arm end anchor and reds A1–A5 — but P2 has no such backstop.)

### F11 — `V1` husk — P4/P5 vacuously green
`MobilePalletizingService.java` replaced with a 5-line class containing two `x.getTypeId().equals(y)` lines and nothing else. P4 green (count ≥ 2), P5 green (`! grep` over a file with no real content is vacuously true). The file-missing case *is* handled; the file-gutted case is not. This is the "bare negation over an absent construct is VACUOUSLY TRUE" lesson in the script's own header, applied to a surviving-but-emptied file.

**Repair:** P5 should require the positive anchor it is negating around — e.g. first assert `code_contains 'class MobilePalletizingService'` and that the two `throw` sites from F9's repair exist, then apply the negation.

### F12 — `M10` / `G12` — test rows are token-only, `18/0`
`M10_test_stubs` (the known escape) still scores `18/0` at `RUN_MVN=0`. `G12_compiling_token_stub_tests` is the sharper version: both test files replaced with **compiling, assertion-free** JUnit classes whose only content is `InOrder unused = null; VerificationMode m = never();` plus a string literal `"never()).findByUnitloadId"`. T1–T4 all green, and unlike `M10` this variant would also survive `mvn test` (it compiles and passes), so the M rows are not a backstop either.

Compounding this: **`RUN_MVN=1` degrades silently.** `mvn` is not on PATH in this environment (consistent with `run-v1-wms-api-testcontainers-its-locally` — maven is SDKMAN-only), so the default `RUN_MVN=1` path prints `SKIP M1-M2 (mvn not on PATH)` and the script **exits 0**. The comment "Final acceptance requires RUN_MVN=1" is documentation, not enforcement — a reviewer who runs the script the default way on a box without maven gets `18 pass, 0 fail` and an exit code of 0 with zero code executed.

**Repair:** (a) T2/T3/T4 must assert a `verify(` call site with a real argument, not a bare token — e.g. `verify\(\s*unitloadBusinessService\s*,\s*never\(\)\s*\)\s*\.\s*transferUnitLoadToCarrier`; (b) add a `@Test`-count floor per file; (c) make `mvn not on PATH` a **FAIL**, not a SKIP, whenever `RUN_MVN=1` was explicitly requested.

---

## FALSE REDS — correct code the script rejects

| # | Shadow | Rows red | Score | Why it fires |
|---|---|---|---|---|
| R3 | guard extracted to `private void assertIsPallet(Unitload)`, called from the else arm | A1 A2 A3 A4 | `14/4` | The script's *own Fix B* mandates exactly this extract-a-guard-method idiom, then punishes it on Fix A. Worst false red — 4 rows, and the shape is what a reviewer would ask for. |
| R7 | `Optional`-friendly restructure: resolve type first, `!palletType.getId().equals(pallet.getTypeId())` | A1 A2 A4 | `15/3` | A4 slices from `findByIdForUpdate(palletOpt`; hoisting the `findByName` one line above the re-fetch puts it outside the arm window. Reordering two independent reads should not be a failure. |
| R6 | guard appended at the **end** of the else arm, after `assertPalletNotAssignedToGate` | A1 A3 A4 | `15/3` | Still before every write, still correct. The else-arm slice *ends* at the gate assertion, so the natural "append to the block" placement is invisible. |
| R1 | `!java.util.Objects.equals(pallet.getTypeId(), palletType.getId())` | A1 A2 | `16/2` | The null-safe idiom. `getTypeId()` can be null on a malformed row, and `Objects.equals` is the correct defence — the script forces the NPE-prone form. |
| R2 | operands reversed: `!palletType.getId().equals(pallet.getTypeId())` | A1 A2 | `16/2` | Constant-first is the NPE-safe convention. A1 hard-requires `X.getTypeId().equals(`; A2's `getTypeId\(\)[^\n]*equals` additionally requires `getTypeId()` to precede `equals` **on the same line**. |
| R4 | line break inside the `if`: `!pallet.getTypeId()\n .equals(palletType.getId())` | A2 | `17/1` | A1 passes (`/s` + `\s*`), A2 fails — `order_within` is `grep -nE`, strictly line-based. Byte-identical semantics, one row red purely on formatting. |
| R5 | `if (palletOpt.isPresent()) { existing } else { create }` | P1 | `17/1` | Behaviourally identical and arguably clearer. `palletise_create_arm`'s start anchor `if (palletOpt.isEmpty())` vanishes → empty slice → P1 red. |
| R8 | `this.assertSourceUnitLoadMovable(sourceUnitLoad);` | B4 | `17/1` | `^[[:space:]]*assertSourceUnitLoadMovable\(` cannot see a `this.` qualifier. Some house styles require it. |
| R9 | `assertSourceUnitLoadMovable` declared as the **last** method of the class | B2 | `17/1` | B2's end anchor `\n\s*(?:public\|private\|protected)\s` never matches after the last method → empty slice → red. Same defect class the header records for `\z`, just at the other end. |
| R10 | `verify(stockunitRepository, never())\n .findByUnitloadId(anyLong());` | T4 | `17/1` | T4 requires `never())` and `.findByUnitloadId` to be adjacent. Mockito's own docs break that line. |

Common repairs: run all ordering/adjacency checks on comment-stripped, **newline-collapsed** text (`tr -d '\n'` or perl `/s` with a tempered gap) rather than `grep -n` line numbers; make every method-slice end anchor tolerate end-of-class (`(?:\n\s*(?:public|private|protected)\s|\n\}\s*\z)`); allow an optional `this\.` prefix; and for A1, accept the disjunction of the three legal comparison shapes (`!x.getTypeId().equals(`, `!const.getId().equals(`, `!Objects.equals(`) or, better, drop the syntactic pin entirely and let a maven row that actually runs the test carry the semantics.

---

## Helper-level defects (root causes)

1. **`slice` is first-match-in-file.** Any anchor that a sibling method, a dead helper, a string literal, or a decoy can also satisfy silently relocates the entire graded window. `ParcelMonitorViewService` contains two near-duplicate palletise implementations, so this is not hypothetical. Drives F1, F10.
2. **`slice` end anchors do not tolerate end-of-class.** Drives R9.
3. **Bare-token anchors (`scanDestination`) instead of declarations.** Drives F2.
4. **`order_within` is line-based** (`grep -nE`, `-lt` on line numbers). Any correct construct that wraps across lines fails; any incorrect construct that fits on one line where the tokens happen to be ordered passes. Drives R4, R2, R10.
5. **`^[[:space:]]*` is not a nesting-depth check.** Drives F5.
6. **File-wide `code_contains` on a file with duplicated logic.** Drives F10.
7. **Counting tokens instead of enforcement.** P4 counts conditions, not throws. Drives F9.
8. **Vacuous negations over a gutted (not missing) file.** P5. Drives F11.
9. **`mvn not on PATH` is a SKIP with exit 0 even when `RUN_MVN=1` was requested.** Drives F12 and makes the "final acceptance" gate unenforceable.

## Bottom line

The script reliably separates the *unfixed tree* from *the exact fix its author wrote*, and it has genuinely closed 9 of the 10 earlier escapes. But it does not separate "correct" from "incorrect": 13 distinct wrong-or-inert implementations score a clean `18 pass, 0 fail`, including one (F7) that is strictly worse than shipping nothing and two (F1, F2) where the targeted defect is 100% unfixed. In the other direction, 10 idiomatic correct implementations are rejected — several of them the shapes a code reviewer would actively request. I would not treat a green from this script as evidence the fix is present.