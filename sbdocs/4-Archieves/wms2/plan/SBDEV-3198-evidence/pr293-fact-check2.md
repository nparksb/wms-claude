---
name: pr293-fact-check2
description: Round-2 independent fact-check of PR #293 (SBDEV-3198 step 5, part 2/4 — ReleaseExpiredPickingOrdersFromUserJob D' conversion), re-verifying round 1's two corrections plus every other checkable claim
metadata:
  lane: fact-check-round2
  status: reviewed
  base: c360b380ee234ff78a7c4d2f4a91445ed001bf60 (merge-base with origin/develop)
  head: 022088076d889f2237a5f2ae1de9eb603699d0bb (round-1 review fix commit, current PR head)
  submission: 64fb9223387cbfb3e81cd18f7570eb7621efb761 (round-1's original submission, before the fix commit)
  worktree: /home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3198-293-review2-fact
---

# PR #293 fact-check — round 2

Adversarial re-derivation of every checkable, specific, quantitative claim in the CURRENT PR #293
description (`gh pr view 293 --repo SiteBossInc/wms2-api`), including round 1's two prior
corrections (a file-count claim and a NeverMatcher census claim). Independent of code-correctness
review (a separate lane). Every number below was reproduced with an independent instrument, not
read off the PR text or off round 1's report.

Toolchain: `export SDKMAN_DIR="$HOME/.sdkman"; source "$SDKMAN_DIR/bin/sdkman-init.sh"`; Java
21.0.11, Maven 3.9.15 (sdkman current). All commands run from the worktree root above, on the
detached-HEAD commit `02208807` (the current PR head).

## Verdict table

| # | Claim | Verdict | Detail |
|---|---|---|---|
| 1 | Full suite: 6264/0/0/67 | **PASS** | Independently summed all 1681 surefire report files, see §1 |
| 2 | "8 test files touched" (round-1's corrected figure) | **PASS** | Confirmed 8 via `git diff` merge-base→HEAD; the round-1 fix pass itself touched a subset of 3 of those 8 (not 5 — see note in §2) | 
| 3 | NeverMatcher census "154→163 across 39 classes, +9" (round-1's corrected figure) | **PASS** | Extracted `PRIMITIVE_MATCHER_INVENTORY` at merge-base and HEAD by hand: 39 entries / sum 154 at base, 39 entries / sum 163 at HEAD, delta +9 across exactly 2 classes, see §3 |
| 4 | H-1 fix: activation check now exists in `runForCurrentTenant()`, matching `runFor()`'s two sysprop keys | **PASS** | Read both methods verbatim, both check the identical two keys, see §4 |
| 5 | M-2 fix: `Pickingorder extends AbstractBaseEntity`, which declares `@Version` | **PASS** | Quoted exact lines from both files, see §5 |
| 6 | "Full suite after fixes 6264/0/0/67, +2 over the submission baseline (6262)" | **PASS with a correction to the framing** | The PR text itself never states "6262" or "+2" — it states "+12 over the 6252 baseline (post PR #291 merge)", which I independently reproduced (6252 at merge-base). Separately, I confirmed exactly 2 new test methods were added between the submission (`64fb9223`) and the fix (`02208807`): `refusesWhenNotActivated` (H-1) and `malformedRowCostsOnlyItselfButWithholdsFleetGauge` (M-1) — see §6 |
| 7 | Round 1's own two corrections are self-consistent in the current PR text, no stale leftovers | **PASS** | Every occurrence of "9 test files" and "156→163"/"+7" in the current body is explicitly framed as the OLD, corrected-away value, see §7 |

**7 of 7 PASS.** One item (#6) needed a framing correction: the specific numbers "6262" / "+2" named
in this round's task brief do not appear anywhere in the actual PR body — the PR itself claims
"+12 over 6252", which checks out. The substance behind #6 (that review round 1 added exactly 2 new
tests) is independently confirmed regardless.

---

## §1 — Full suite: 6264/0/0/67

```
cd .../SBDEV-3198-293-review2-fact
export SDKMAN_DIR="$HOME/.sdkman"; source "$SDKMAN_DIR/bin/sdkman-init.sh"
mvn -o clean test
```

Maven's own summary: `Tests run: 6264, Failures: 0, Errors: 0, Skipped: 67`, `BUILD SUCCESS`.

Independently summed every `target/surefire-reports/*.txt` (not trusting Maven's own aggregate
line) with a small Python script parsing each file's `Tests run: N, Failures: N, Errors: N,
Skipped: N` header line:

```
files: 1681
Tests run: 6264 Failures: 0 Errors: 0 Skipped: 67
```

Matches exactly. **PASS.**

## §2 — "8 test files touched"

```
MB=$(git merge-base origin/develop 02208807)   # c360b380
git diff --name-only $MB 02208807 -- src/test
```

Returns exactly 8 files:
```
src/test/java/net/aim_ai/wms/schedulejob/SchedulingConfigurationUnitTest.java
src/test/java/net/aim_ai/wms/unit/config/NeverMatcherNullBlindnessArchTest.java
src/test/java/net/aim_ai/wms/unit/controller/AdminActionControllerUnitTest.java
src/test/java/net/aim_ai/wms/unit/schedulejob/AdminTriggerTenantScopeUnitTest.java
src/test/java/net/aim_ai/wms/unit/schedulejob/ReleaseExpiredPickingOrdersFromUserJobMetricsUnitTest.java
src/test/java/net/aim_ai/wms/unit/schedulejob/ReleaseExpiredPickingOrdersFromUserJobTest.java
src/test/java/net/aim_ai/wms/unit/schedulejob/ReleaseExpiredPickingOrdersFromUserJobUnitTest.java
src/test/java/net/aim_ai/wms/unit/schedulejob/WholeRunSuccessGaugeUnitTest.java
```

This matches the PR body's "Test surgery" section's named list (line 51) exactly, both in count
and in filenames. **PASS.**

Separately diffed the round-1 fix pass itself (`64fb9223` → `02208807`):
```
git diff --name-only 64fb9223 02208807 -- src/test
```
returns only **3** files: `AdminTriggerTenantScopeUnitTest.java`,
`ReleaseExpiredPickingOrdersFromUserJobMetricsUnitTest.java`,
`ReleaseExpiredPickingOrdersFromUserJobTest.java` — not 5, as this round's task brief guessed.
Reconciliation: diffing merge-base → submission (`64fb9223`) alone shows the **same 8 files**
already touched in the original submission; the round-1 fix pass added no new test files, it only
further modified 3 of the 8 that already existed. This is not a PR-text discrepancy — the PR body
never claims a "5 files in the fix pass" figure, only the cumulative "8 test files touched", which
holds.

## §3 — NeverMatcher census "154→163 across 39 classes, +9"

Extracted the `PRIMITIVE_MATCHER_INVENTORY` `List.of(...)` block from
`NeverMatcherNullBlindnessArchTest.java` at both commits, bounded from the `List.of(` opening line
to its closing `);` (my first attempt over-captured past the closing paren into unrelated string
literals elsewhere in the file, giving a spurious 47-entry/154-sum "match" — corrected by locating
the actual closing `);`):

- **Merge-base** (`c360b380`): 39 entries, sum = **154**
- **HEAD** (`02208807`): 39 entries, sum = **163**

Per-class diff between the two lists (`diff` on sorted `Class:count` lines) shows exactly 2 classes
changed:
```
AdminTriggerTenantScopeUnitTest:2  →  AdminTriggerTenantScopeUnitTest:4   (+2)
ReleaseExpiredPickingOrdersFromUserJobTest:2  →  ReleaseExpiredPickingOrdersFromUserJobTest:9  (+7)
```
2 + 7 = 9. **154 → 163 across 39 classes, +9 — confirmed exactly. PASS.**

## §4 — H-1 fix: activation check present and matches `runFor()`'s two keys

`runFor()` (scheduled path), lines 195-196:
```java
if (!Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY))
    || !Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_PICK_TIME_OUT_SYSTEM_ACTIVATED_KEY))) {
```

`runForCurrentTenant()` (manual path), lines 294-295 — identical two keys:
```java
if (!Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY))
    || !Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_PICK_TIME_OUT_SYSTEM_ACTIVATED_KEY))) {
```

Both check `SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY` AND
`SYSTEM_PROPERTY_PICK_TIME_OUT_SYSTEM_ACTIVATED_KEY`, same OR-of-negations shape, same short-circuit
order. The method's own javadoc (lines 233-241, 249, 255-257) states the H-1 history and return
contract accurately. **PASS.**

## §5 — M-2 fix: `Pickingorder extends AbstractBaseEntity`, `@Version`

```
$ grep -n "class Pickingorder" src/main/java/net/aim_ai/wms/model/Pickingorder.java
10:public class Pickingorder extends AbstractBaseEntity {

$ grep -n "@Version\|private.*version" src/main/java/net/aim_ai/wms/model/AbstractBaseEntity.java
34:    @Version
35:    private Integer version;
```

Exact match to the claim. **PASS.**

## §6 — "6264/0/0/67, +2 over the submission baseline (6262)"

**Framing correction:** grepped the actual current PR body for "6262" and "+2" — neither string
appears anywhere. The PR's own "Verification" section (line 55) states: *"Full suite:
**6264/0/0/67** (0 failures, 0 errors), +12 over the 6252 baseline (post PR #291 merge)."* This
round's task brief appears to have paraphrased/misremembered the specific numbers; the actual PR
claim is 6252→6264 (+12), not 6262→6264 (+2).

Independently verified the actual PR claim by checking out the merge-base commit in this worktree
and running the full suite there:
```
git checkout $(git merge-base origin/develop 02208807) --quiet   # c360b380
mvn -o clean test
# Tests run: 6252, Failures: 0, Errors: 0, Skipped: 67
git checkout 02208807 --quiet   # restored, working tree clean before and after
```
6252 (merge-base) → 6264 (HEAD) = **+12**, exactly matching the PR body. **PASS** on the actual PR
claim.

Separately, the substance behind this round's framing (that round-1's review-fix pass itself added
tests) is also independently confirmed: diffing test method signatures between the submission
(`64fb9223`) and the fix (`02208807`) across the 3 test files that pass touched:
```
git diff 64fb9223 02208807 -- <3 test files> | grep -E "^\+.*void "
+        void malformedRowCostsOnlyItselfButWithholdsFleetGauge() {
+        void refusesWhenNotActivated() {
```
Exactly 2 new test methods, no removals — `refusesWhenNotActivated` (H-1's fix, §4) and
`malformedRowCostsOnlyItselfButWithholdsFleetGauge` (M-1's fix). This matches the PR body's L-3/H-1
narrative (line 36, 38) naming these exact two additions.

## §7 — Round 1's corrections are self-consistent, no stale leftovers

```
grep -n "9 test files\|156\|+7\b" pr293-body.md
```
Both hits are explicitly framed as the OLD, now-corrected value:
- Line 45: *"this PR description claimed **'9 test files touched'** (actual: 8 ... ) — corrected."*
- Line 41 (L-3 finding): *"census math was wrong (**156→163, +7** stated; actual 154→163, +9 ...) — Fixed"*
- Line 51 (Test surgery): *"census: **154→163 across 39 classes**, +9 — corrected from an earlier miscount of 156/+7 in this description"*

No bare, uncorrected "9 test files" or "156→163"/"+7" claim exists anywhere else in the body. Every
final-value statement (the "**8**" in line 51, the "154→163 ... +9" in line 51, the H-1/M-2/M-1
narrative) is internally consistent with what I independently reproduced in §1-§6. **PASS.**
