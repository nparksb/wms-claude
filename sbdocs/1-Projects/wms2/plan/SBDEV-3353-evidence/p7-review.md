head: 718843f6

# Code Review — SBDEV-3353 p7 (two unreviewed artifacts: rail javadoc commit + sbdocs workflow edit)

**Reviewer:** independent pass (code-reviewer agent), separate from the authoring session that wrote both artifacts. Tree: `.claude/worktrees/wms2-api/SBDEV-3353-review`, detached at `718843f6` (PR #416 tip). Confirmed PR #416 is still OPEN, `mergedAt: null`, `headRefOid` == `718843f643d5a38e131c5f04cdc405a7d848cb71` (`gh pr view 416 --repo SiteBossInc/wms2-api`).

## Method

- `git show 718843f6` for the full diff; confirmed every changed line sits inside the `/** ... */` class javadoc block (lines 103–115) — no code, imports, or test bodies touched. Comment-only, as claimed.
- Read the full 897-line `NeverMatcherNullBlindnessArchTest.java` (both `@Test` methods, `stripComments`, `spanEnd`, `skipTextBlock`, `methodArgsOpen`) to check every javadoc sentence against the real implementation, not just the hunk.
- `grep -c '"""'` on the file → `0`. Confirmed the rail's self-scan claim.
- Cross-checked the javadoc's mutation/measurement claims against `sbdocs/1-Projects/wms2/plan/SBDEV-3353-evidence/p6-review.md`'s own mutation table (built from an exact scratch copy of the production lexers) and 575-file tree-scan A/B.
- For the sbdocs edit: read `sbdocs/3-Resources/workflows/wms2-move-stock-unitload-workflow.md` directly (not in git), located both edits by grep (`SourceContainerGuard`, `For a **`Package`** source`).
- Read `src/main/java/net/aim_ai/wms/util/SourceContainerGuard.java` in full (class javadoc + all three public methods + `judge`).
- `git grep -n "SourceContainerGuard\." -- src/main` to enumerate every call site (6 found) and read each one in context (`StockunitService.java:348,812`, `MobileTransferOrderService.java:396`, `MobileMoveUnitloadService.java:670`, `MobilePutAwayService.java:552`, `CancellationReversalService.java:288`).
- Read `UnitloadBusinessService.relocateEmptiedContainer`/`sendToNirvana`/`transferUnitLoadToLocation` and `AdminActionController.recoverStuckPallets`/`UnitloadBusinessService.recoverPalletFromNirvana` for the landmine-#7 claims.
- `git log -p -S "TYPES_THAT_REST_IN_A_STORAGE_LOCATION"` / `git show 6a3d6a05` to confirm the "Package also left …" and "no recovery path" claims are verbatim from the commit's own javadoc rationale, not invented by the doc writer.
- Grepped the whole workflow doc for `Package|parcel|Damaged|transferToDamaged|bulkTransferToDamaged` to check for contradictions elsewhere in the file.

## Findings

### ARTIFACT 1 — commit `718843f6` (rail javadoc rewrite)

#### [LOW] "Two self-test cases pin it, one per lexer" overstates the independence of the stripComments case
**File:** `src/test/java/net/aim_ai/wms/unit/config/NeverMatcherNullBlindnessArchTest.java:111`
**Confidence:** MEDIUM

The new javadoc reads: *"Two self-test cases pin it, one per lexer."* Per `p6-review.md`'s own mutation table (built from an exact copy of the reviewed production code):

| Mutant | case1 (spanEnd-targeting, :366-369) | case2 (stripComments-targeting, :372-375) |
|---|---|---|
| baseline | PASS | PASS |
| A: remove `spanEnd`'s text-block branch | FAIL | FAIL |
| B: remove `stripComments`'s text-block branch | PASS | FAIL |

Case1 *is* a clean, exclusive pin of `spanEnd` (fails under A only, passes under B). Case2 is not an exclusive pin of `stripComments` — it also fails under A, because `methodArgsOpen` calls `spanEnd` on the `.description(...)` span before `stripComments`'s own text-block handling is ever exercised end-to-end for that snippet. So "one per lexer" is true in the weaker sense that each case *targets* a distinct lexer by design (and the file's own inline comments say so: `:369` "must still be scanned", `:375` "(stripComments)"), but it reads as a stronger claim of mutual exclusivity than the mutation evidence supports for case2. This is the same class of over-claim p6 already flagged and withdrew once (its own INFO finding: *"the 'removes only its own case' framing is slightly stronger than what the code actually does"*) — this new sentence reintroduces a milder version of the same imprecision in the class javadoc that supersedes it.
**Fix:** `Two self-test cases exercise it: one (:366) is an exclusive pin of spanEnd's branch; the other (:372) additionally needs stripComments's branch, since methodArgsOpen's call to spanEnd runs first on its .description(...) span.` Or, more simply, drop "one per lexer" and just say "each case targets one lexer's branch" without implying exclusivity.

#### Everything else in the diff checks out
- **"Both `stripComments` and `spanEnd` skip a Java text block whole via `skipTextBlock`"** — confirmed: `spanEnd:813-814` and `stripComments:833-836` both dispatch to `skipTextBlock` on `c == '"' && s.startsWith(TEXT_BLOCK, i)`.
- **"the file still contains no raw three-quote sequence"** — `grep -c '"""'` → `0`. The rail's self-scan claim (also pinned by p6's Check 3) holds.
- **Comment-only diff** — confirmed; all 12 changed lines (`+7/-5`) sit strictly between `/**` and `*/` in the class javadoc, no code/test lines touched.
- **"measured over all 575 test files, the scan is identical with and without the fix"** — matches p6's `TreeScan.java` A/B exactly: `aware=false scanned=575 neverSpans=1222 offenders=0 unbalanced=0` / `aware=true` identical.

### ARTIFACT 2 — sbdocs edit, `wms2-move-stock-unitload-workflow.md` (not in git)

#### [HIGH] "Fail-closed on unknown" inverts the guard's own documented security posture
**File:** `sbdocs/3-Resources/workflows/wms2-move-stock-unitload-workflow.md:317`
**Confidence:** HIGH

The doc states: *"**Fail-closed on unknown:** an unresolvable unit load or type row means the source is **not** treated as a parcel, and a WARN is logged."* — i.e. an unknown state lets the stock move **proceed unguarded**. That is fail-**open** behavior (default-allow), not fail-**closed** (default-deny). The guard's own class javadoc says exactly this, using the opposite and correct label: `src/main/java/net/aim_ai/wms/util/SourceContainerGuard.java:40` — *"**Fail-open: an unknown answers "not a parcel".**"* — and every early-return branch (`:100-104`, `:106-109`, `:131-134`, `:136-139`, `:122-124`) logs a WARN and returns without throwing, letting the caller's move proceed. The doc's *mechanism* description is accurate; only the label is backwards, and it is exactly the label a reader would skim first. This matters because it inverts the risk read: a reviewer relying on "fail-closed" would conclude an unresolvable row is safely refused, when the code in fact lets it through.
**Fix:** Change `**Fail-closed on unknown:**` → `**Fail-open on unknown:**`. Rest of the sentence is correct as written.

#### [MEDIUM] "There are two entry points" undercounts SourceContainerGuard's public surface — three exist, and the doc's own next line calls the third one
**File:** `sbdocs/3-Resources/workflows/wms2-move-stock-unitload-workflow.md:311`
**Confidence:** HIGH

The doc reads: *"There are two entry points: `assertStockNotInParcel(Stockunit, …)` for the stock-unit sites and `assertNotParcel(Unitload, …)` for the mobile Move Unit Load and putaway sites…"* `SourceContainerGuard.java` declares **three** public static methods: `assertStockNotInParcel(Stockunit, …)` (:82), `assertUnitloadNotParcel(Long unitloadId, Long stockunitId, …)` (:97), and `assertNotParcel(Unitload, …)` (:120). The very next table row's first call site — *"top of `StockunitService.transferStock`"* — is backed by `assertUnitloadNotParcel`, not `assertStockNotInParcel`:

```
StockunitService.java:348:  SourceContainerGuard.assertUnitloadNotParcel(sourceUnitloadId, stockUnit.getId(), unitloadRepository, unitloadTypeRepository);
```

(`sourceUnitloadId` is a `Long` re-read from a JPQL scalar select, not a `Stockunit` — confirmed by the surrounding comment block at `StockunitService.java:326-347`, which explains this is deliberately *not* an entity read so `transferStockToUnitLoad`'s later `findByIdForUpdate` isn't turned into a lock upgrade.) So the "two entry points" framing both undercounts the API and misattributes the doc's own first table row.
**Fix:**
```
There are three entry points: `assertStockNotInParcel(Stockunit, …)` for stock-unit sites that already
hold a `Stockunit`, `assertUnitloadNotParcel(Long unitloadId, Long stockunitId, …)` for
`StockunitService.transferStock`'s in-transaction scalar re-read of the source unit load id (not the
entity — see the guard's own javadoc on why), and `assertNotParcel(Unitload, …)` for the mobile Move
Unit Load and putaway sites, which already hold the unit load:
```

#### Everything else in the sbdocs edit checks out (grounded, not invented)

- **6 call sites, exactly** — `git grep -n "SourceContainerGuard\." -- src/main` returns exactly 6 (excluding the class's own `LOG` declaration), and each maps 1:1 to the doc's table row: `CancellationReversalService.java:288` → RTS pre-validate; `StockunitService.java:348` → top of `transferStock`; `StockunitService.java:812` → inside `setLockDamaged` (comment at `:795` explicitly names `/transferToDamaged`, `/bulkTransferToDamaged`); `MobileTransferOrderService.java:396`; `MobileMoveUnitloadService.java:670`; `MobilePutAwayService.java:552`.
- **Key name + format arg** — `WmsConstants.MSG_TRANSFER_SOURCE_IS_PARCEL = "transferStockSourceIsParcel"` (`WmsConstants.java:1399`); `messages.properties:37` / `messages_en_US.properties:367`: `transferStockSourceIsParcel=Container %1$s is a parcel (Package)...`; code passes `label == null || label.isBlank() ? String.valueOf(unitloadId) : label` (`SourceContainerGuard.java:143-144`). Doc's `%1$s = parcel label (id if blank)` is exact.
- **"Deliberately not guarded" list** — the whole-parcel-relocation ticket `868m9914u`, `handleTruckOffLoading` (Nam's decision), and `adjustAmount` (count correction, not a move) are quoted almost verbatim from `UnitloadService.java:712-714`'s own javadoc.
- **"Package also left `TYPES_THAT_REST_IN_A_STORAGE_LOCATION` in the same change"** — confirmed via `git show 6a3d6a05`: that commit's diff to `UnitloadService.java` removes `Package` from the set and rewrites the surrounding javadoc to explain why (superseding the SBDEV-3340 rationale that had kept it in).
- **Landmine #7 additions** — `relocateEmptiedContainer`'s `default:` branch calls `sendToNirvana` (`UnitloadBusinessService.java:660`), which rewrites the label to `unitload.getLabelid() + "-X-" + unitload.getId()` (`:590`) and, via `transferUnitLoadToLocation`, nulls the carrier link when one exists (`unitload.setCarrierunitloadId(null)` at `:333`). "No recovery path" is confirmed: `AdminActionController.recoverStuckPallets` → `UnitloadBusinessService.recoverPalletFromNirvana`, which throws `BusinessException("... is not a Pallet")` for any non-Pallet type (`:912-914`) — a retired `Package` can never satisfy that guard.
- **"Branch not yet merged"** — confirmed: `gh pr view 416` reports `state: OPEN`, `mergedAt: null`, `headRefOid` == `718843f6...` (this review's HEAD).
- **No contradictions elsewhere in the doc** — grepped the whole file for `Package|parcel|Damaged|transferToDamaged|bulkTransferToDamaged`; the only other hits are the pre-existing Damaged-permission rows (`:294`, `:326`, `:416`), which describe a different, orthogonal guard (`WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`) and don't overlap in scope with the new `SourceContainerGuard` material. No stale claim anywhere else in the doc describes Move Stock/Move Unit Load moving stock out of a `Package` without this guard.

## Positive observations

- Both artifacts are unusually well-grounded for prose: nearly every factual claim in the sbdocs edit traces to a verbatim comment or javadoc sentence already sitting in the reviewed commit range (`868m9914u`, `handleTruckOffLoading`, `TYPES_THAT_REST_IN_A_STORAGE_LOCATION`, the `<label>-X-<id>` mangle, "is not a Pallet") rather than being paraphrased or inferred — this made the adversarial check straightforward and turned up only labeling/counting defects, not invented facts.
- The javadoc rewrite (Artifact 1) correctly closes the exact staleness gap p6 flagged as LOW, and the "measured over all 575 test files" claim is a precise restatement of p6's own controlled A/B, not a new unverified number.
- The `SourceContainerGuard` design note in the doc ("Deliberately not guarded" list) captures a real, easy-to-miss scope boundary (whole-parcel relocation vs. drain-based moves) that would otherwise require reading three separate files' javadocs to reconstruct.

## Recommendation

**REQUEST CHANGES** — one HIGH-confidence HIGH-severity defect (Artifact 2's fail-open/fail-closed inversion is a security-relevant mislabeling, not a nitpick) plus one HIGH-confidence MEDIUM defect (undercounted/misattributed entry points) in the sbdocs edit. Artifact 1 (the javadoc commit) is COMMENT-only: one LOW/MEDIUM-confidence precision nit, otherwise clean and comment-only as claimed. Fix both sbdocs findings before treating that edit as ground truth for future callers of `SourceContainerGuard`.

## Re-check (ac2ebbbd)

Re-checked all three p7 findings against the fixes in commit `ac2ebbbd` (`.claude/worktrees/wms2-api/SBDEV-3353-review`, detached at `ac2ebbbd5f9f16ed026b611f3666ac969e00fbc5`) and the corresponding sbdocs edit (still not in git).

### [HIGH] "Fail-closed" → "Fail-open on unknown" — **CLOSED**

`wms2-move-stock-unitload-workflow.md:322` now reads: *"**Fail-open on unknown**, deliberately: an unresolvable unit load or type row means the source is **not** treated as a parcel, so the move **proceeds** and a WARN is logged."* Label now matches `SourceContainerGuard.java:40`'s own `"Fail-open: an unknown answers 'not a parcel'."` exactly, and the mechanism sentence is unchanged (still correct).

New data note added in the same sentence: *"No row reaches this today: the columns are NOT NULL and there are 0 orphans on all 6 tenants (2026-09-24)."* Live-checked via the available tenant DB MCP connections (`wms2-hydra`, `wms2-wineco-dev`, `nywh-hydra-uat`, `nywh-shipitez-uat`, `wsl-wineco-uat`, `c1wh-shipitez-uat` — 6 reachable tenant DBs) with:
```sql
SELECT count(*) FILTER (WHERE type_id IS NULL) AS null_type,
       count(*) FILTER (WHERE labelid IS NULL) AS null_label,
       count(*) FILTER (WHERE type_id IS NOT NULL
                         AND NOT EXISTS (SELECT 1 FROM unitload_type ut WHERE ut.id = u.type_id)) AS orphan_type
FROM unitload u;
```
All six returned `{null_type: 0, null_label: 0, orphan_type: 0}`. Consistent with the claim. Caveat: I did not independently confirm these 6 connections are the exact same 6 tenants the doc's "2026-09-24" measurement covered (tenant↔connection mapping is not 1:1 obvious from the MCP names alone), so this is a corroborating spot-check, not a re-derivation of the original measurement. Not a blocker.

### [MEDIUM] "Two entry points" → "three entry points" — **CLOSED**

`wms2-move-stock-unitload-workflow.md:311-315` now lists all three: `assertUnitloadNotParcel(Long unitloadId, …)` → `StockunitService.transferStock`; `assertStockNotInParcel(Stockunit, …)` → `setLockDamaged`, RTS `completeReversal`, mobile `transferStock`; `assertNotParcel(Unitload, …)` → mobile Move Unit Load and putaway. This now matches the 6 call sites exactly (re-confirmed via `git grep -n "SourceContainerGuard\." -- src/main` at `ac2ebbbd`, unchanged from the prior check): `StockunitService.java:348`→`assertUnitloadNotParcel`, `StockunitService.java:812`+`MobileTransferOrderService.java:396`+`CancellationReversalService.java:288`→`assertStockNotInParcel`, `MobileMoveUnitloadService.java:670`+`MobilePutAwayService.java:552`→`assertNotParcel`.

New claim checked line-by-line against `SourceContainerGuard.java` at `ac2ebbbd` (unchanged from the reviewed version): *"All three read the unit load's label and type id as scalars (`UnitloadRepository.findParcelGuardViewById`) or from the caller's entity. None loads a `Unitload` entity itself."*
- `assertUnitloadNotParcel` (:97) and `assertStockNotInParcel` (:82, which delegates to it) both call `unitloadRepository.findParcelGuardViewById(unitloadId)` (:105) — confirmed genuinely scalar: `UnitloadRepository.java:42-44` is `@Query("SELECT u.id AS id, u.labelid AS labelid, u.typeId AS typeId FROM Unitload u WHERE u.id = :id")` returning `Optional<UnitloadParcelGuardView>`, an interface projection (`UnitloadParcelGuardView.java`), whose own javadoc states it exists precisely "so the guard never puts a `Unitload` entity into the persistence context." Not the entity.
- `assertNotParcel` (:120) takes a `Unitload sourceUnitload` parameter and reads `.getId()`/`.getTypeId()`/`.getLabelid()` directly off it (:126) — it issues no repository call of its own for the unit load. This is "from the caller's entity": the object was already loaded (or held) by `MobileMoveUnitloadService`/`MobilePutAwayService` before the guard runs. Matches the class's own "What it reads" javadoc: *"The two `assertNotParcel` callers... instead hand over a unit load they have already loaded themselves, so the guard adds no read of its own there."*

"None loads a `Unitload` entity itself" holds for all three. **CLOSED.**

### [LOW] "one per lexer" imprecision — **CLOSED**

`git show ac2ebbbd` — comment-only diff (`+3/-1`), confirmed every changed line sits inside the class javadoc block (lines 108-113), no code/test lines touched. New text: *"Two self-test cases pin it. Removing `spanEnd`'s branch reds both, and removing `stripComments`'s reds only the trailing-comment case, so removing either branch reds at least one case."* This matches `p6-review.md`'s mutation table exactly: mutant A (remove `spanEnd`'s branch) → case1 FAIL, case2 FAIL ("reds both"); mutant B (remove `stripComments`'s branch) → case1 PASS, case2 FAIL ("reds only the trailing-comment case" — case2 is literally the "text block followed by a trailing comment" case at `:372-375`). The new sentence states the measured result exactly, with no independence claim left to overstate. `grep -c '"""'` on the file at `ac2ebbbd` → `0`, unchanged. **CLOSED.**

### Net verdict

All three p7 findings are CLOSED at `ac2ebbbd`. No new defects found in the fixes themselves. Recommendation upgraded to **APPROVE** for both artifacts as they now stand.
