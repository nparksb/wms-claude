# Review — PR #320 (SBDEV-3242 follow-up: sweep the seven dead cleanup helpers)

- **Worktree**: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3242-sweep`
- **Branch**: `bugfix/SBDEV-3242-sweep-dead-cleanup-helpers` @ `18f5a588`, based on `origin/develop` @ `a158cf30`
- **Diff**: 7 files, +49 / −36, all inside `@BeforeEach setUp()` bodies. No `src/main` change.
- **Reviewer**: independent lane, sole occupant of the worktree. Worktree left byte-clean (`git status --porcelain` empty at exit).
- **Date**: 2026-09-07

## Verdict

**Merge — but not as it stands.** Every deletion in the diff is correct: nothing removed was
load-bearing, no in-test delete was removed by accident, and the enumeration of the workaround
population is right. The problem is not the code, it is the record. This PR's entire product is a
*claim* ("the helpers were dead, therefore the fix took"), and **three of its stated claims are
false and one of the seven classes proves nothing at all**. Fix H1, M2, M3 (comment + commit-message
edits only, no code change) and merge.

## What I verified independently

| Instrument | Result |
|---|---|
| Full failsafe lane on HEAD (`mvn verify -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.test.failure.ignore=true`) | **352 run / 0 failures / 0 errors / 70 skipped** — reproduces the claimed number exactly |
| Targeted failsafe, `-Dit.test='*RepositoryIntegrationTest'` | 135 run / 0 F / 0 E / 28 skipped |
| **Mutation check** — base class reverted to the exact pre-fix `@Transactional` (bare), same targeted run | **135 run / 2 failures / 7 errors / 28 skipped** |
| Restore | `md5 675628d0ea5f39caa7e44939fe042018` before and after; `git status --porcelain` empty |

The mutation is faithful: `git show 34ffd9fa:.../BaseRepositoryIntegrationTest.java:27` is bare
`@Transactional`, which is exactly what I substituted.

### The mutation result is the finding

The commit's evidence is an **aggregate** A/B (352/0/0/70 both sides). That cannot distinguish
"rollback works" from "nothing was checking" — it is the same instrument that missed
`MessageRepositoryIntegrationTest`'s counts silently falling to 0 earlier in this ticket. Breaking
the base class and reading the result **per class** does distinguish them:

| Class | Executed | Red under the pre-fix mutant? | Removal verified? |
|---|---|---|---|
| `SyspropRepositoryIntegrationTest` | 16 | **YES** — 2 F + 2 E | ✅ |
| `ClientRepositoryIntegrationTest` | 13 | **YES** — 2 E | ✅ |
| `LocationRepositoryIntegrationTest` | 15 | **YES** — 1 E | ✅ |
| `PickingorderRepositoryIntegrationTest` | 13 | **YES** — 1 E | ✅ |
| `UserRepositoryIntegrationTest` | 12 | **YES** — 1 E | ✅ |
| `PrinterRepositoryIntegrationTest` | 8 | **NO — fully green** | ❌ vacuous (M1) |
| `ReplenishorderRepositoryIntegrationTest` | **0** | **NO — `@Disabled`, 11/11 skipped** | ❌ never ran (H1) |
| `CyclecountRepositoryIntegrationTest` (swept in the earlier PR) | 18 | **NO — fully green** | ❌ vacuous (M1) |
| `MessageRepositoryIntegrationTest` (untouched) | 12 | NO — fully green | n/a |

Representative reds under the mutant, i.e. proof the five classes really do notice a leak:

```
SyspropRepositoryIntegrationTest$FindByGroupname.shouldFindByGroupname:137
  Expected size: 2 but was: 10
ClientRepositoryIntegrationTest$FindByName.shouldFindByName:105
  » IncorrectResultSizeDataAccess: Query did not return a unique result: 7 results were returned
UserRepositoryIntegrationTest$FindByName.shouldFindByName:102
  » IncorrectResultSizeDataAccess: Query did not return a unique result: 6 results were returned
```

So the sweep's core thesis holds for **5 of 7**, and holds by direct positive control rather than by
absence — which answers ATTACK #2 as well: `Sysprop`'s `hasSize(2)` at `:137` and `:169` are genuine
cross-test leak detectors. A row written by one test method is provably gone by the next, because
when I removed the rollback those same assertions immediately saw 10 rows instead of 2.

---

## Findings

### H1 — `ReplenishorderRepositoryIntegrationTest` is `@Disabled`; its removal is verified by nothing (High)

`src/test/java/net/aim_ai/wms/integration/repository/ReplenishorderRepositoryIntegrationTest.java:31`

```java
@Disabled("Requires complex entity setup with Itemdata and Location - use TestContainers for full tests")
class ReplenishorderRepositoryIntegrationTest extends BaseRepositoryIntegrationTest {
```

Measured on both my runs: `run=11 fail=0 err=0 skip=11` → **0 tests executed**. The `setUp()` body
never runs; the deleted block never ran either, before or after. The identical A/B for this class is
not merely weak evidence, it is *no* evidence — the byte-identical totals are guaranteed by the
`@Disabled`, not by the fix.

The comment now planted in that file (`:50-56`) reads *"The base class now names the manager that
owns the writes, the rollback is real, and the block is dead weight … removing them is a check that
the fix took, not tidying."* For this class none of that was checked. This is the one finding I
would block on, because it puts an unearned assertion into the file permanently, and it is exactly
the failure mode the rest of this ticket has spent its budget eliminating.

**Fix**: keep the deletion (harmless), but the comment in this one file must say the class is
`@Disabled`, so the removal is unverified and rides on the mechanism argument alone. One extra
sentence.

### M1 — `Printer` (and `Cyclecount`) pass vacuously; the sweep's "check" does not reach them (Medium)

`PrinterRepositoryIntegrationTest` executes 8 tests and stays **100% green with the rollback
deliberately broken**. Its assertions cannot see a leak, by construction:

- `:112` `hasSizeGreaterThanOrEqualTo(2)` after `findByType("LABEL")` — monotone in leaked rows.
- `:121`, `:151`, `:192` `isEmpty()` — over `"NONEXISTENT_TYPE"` or `@Disabled` nested classes.
- `:217` `hasSize(3)` — this is the **page size**, `PageRequest.of(0, 3)`. It returns 3 for any row
  count ≥ 3, so it is leak-*insensitive* by definition. (The task brief flagged this one as an
  exact-count assertion to check; it is not one.)
- `:64/:89/:233` — `findById` on a just-saved id.

Four of its twelve tests are `@Disabled` on top of that. Same result for
`CyclecountRepositoryIntegrationTest`, removed under the same rationale in the earlier PR: 18 tests
execute, 0 go red under the mutant.

Nothing is *wrong* here — the deletions are still correct, because the mechanism argument covers
them. But the sentence "removing them is a check that the fix took" is only true for 5 of the 7. If
the goal is a class-by-class check rather than a suite-level one, `Printer` needs one leak-sensitive
assertion (e.g. scope `shouldFindByType` to `TEST-PRINTER-*` and assert `hasSize(2)`), or the claim
needs to be scoped down. I lean toward scoping the claim: adding assertions is new work for a
cleanup PR.

### M2 — "delete deliberately as part of what they assert" is false for both cited sites (Medium)

The commit message states:

> Deletes that live INSIDE tests are untouched -- only the setUp cleanup blocks went.
> LocationRepositoryIntegrationTest:187 and ClientRepositoryIntegrationTest:206 delete
> deliberately as part of what they assert.

Both halves of the second sentence are wrong. (Line numbers are also off by ~1 and ~4 against the
merged tree; the sites are `:186-188` and `:209-210`.)

**`LocationRepositoryIntegrationTest:185-188`** — its own comment says what it is:

```java
// Clean up any gates from previous tests
allGates.stream()
    .filter(g -> g.getName().startsWith("TEST-"))
    .forEach(locationRepository::delete);
```

"from previous tests" is the leak-era artefact verbatim. And it is provably not load-bearing: the
only assertion in that test is `:194` `assertThat(gates).noneMatch(l -> l.getName().equals("TEST-LOC-001"))`,
while `:180-181` saves `TEST-LOC-001` with `setGate(false)` — so it can never appear in
`findByGateTrue()` whether the delete runs or not. Deleting the delete changes nothing the test
asserts.

**`ClientRepositoryIntegrationTest:209-210`**:

```java
    // Cleanup
    clientRepository.findByClNr("AAA-001").ifPresent(clientRepository::delete);
}
```

It is the last statement in the method, **after** the final assertion at `:205-206`. A statement
that executes after every assertion cannot be part of what the test asserts. It is labelled
`// Cleanup` by the author.

The *decision* to scope the sweep to `setUp` blocks is defensible. The *reason* recorded for it is
false, and it will mislead the next person who greps for leftovers.

### M3 — the reason for leaving `BillofladingServiceFinishTransferIT` is wrong, and its own comment is now stale (Medium-Low)

ATTACK #5 asked whether "redundant but harmless" is true. **It is true.**

- `BaseIntegrationTest:32` → `@Transactional("tenantTransactionManager")`
- `BillofladingServiceFinishTransferIT:56` → `@org.springframework.transaction.annotation.Transactional("tenantTransactionManager")`

Same annotation type, same `value`, every other attribute defaulted — `propagation=REQUIRED`,
`readOnly=false`, `isolation=DEFAULT`, `timeout=-1`. `@Transactional` is `@Inherited` and Spring's
`TransactionalTestExecutionListener` takes the most-local merged declaration, so the subclass
declaration shadows an *identical* parent one. Nothing changes: not the manager, not propagation,
not readOnly.

But that is precisely why the commit's stated reason is wrong:

> removing it would change which manager that class uses rather than just deleting dead code.

It would not. Removing it inherits the identical qualifier from the now-fixed base and the class
uses the same manager. Leaving it is fine; the justification is not.

Separately, the class's own comment at `:52-55` is now **stale in the same way the seven swept
blocks were**:

```java
// Override BaseIntegrationTest's bare @Transactional which defaults to the
// @Primary landlordTransactionManager — repos in net.aim_ai.wms.repo.jpa use
// tenantTransactionManager, so without this override, fixture saves leak across
// tests (the landlord rollback has nothing to roll back).
```

`BaseIntegrationTest` has not been bare since `e1001a21`. This comment asserts a false fact about a
sibling file in the same repo. It is invisible to the `TestClassTransactionManagerArchTest` rail,
which only forbids *bare* `@Transactional` and has nothing to say about a redundant identical
override. Given this PR exists to retire exactly this genus of stale local note, leaving it is
inconsistent — one line, same pass.

### L1 — the pasted comment misdescribes what it replaced, in 4 of 7 files (Low)

All seven comments say the removed block deleted *"this class's own fixture rows by literal name."*

- `Client` ✔ (`findByClNr` / `findByName` on the fixture's literals) and `Location` ✔.
- `Pickingorder` — by **number**, not name. Cosmetic.
- `Sysprop` — by `syskey` ×3 **and by `groupname("TEST_GROUP")`**, which is not a row name.
- **`Printer` ✘ — materially wrong.** The removed block was
  `printerRepository.findByType(TEST_PRINTER_TYPE).forEach(printerRepository::delete)`, i.e. delete
  **every printer of type `LABEL`**, regardless of who created it, plus every `RECEIPT` printer whose
  number starts with `TEST-`. Its blast radius extended well past "this class's own fixture rows,"
  which is worth knowing if anyone ever wonders why an unrelated seeded printer used to vanish.
- **`Replenishorder` ✘** — `findByStateLessThan(FINISHED)` filtered by a `REP-TEST` prefix. By state
  and prefix, not by name.

### L2 — orphaned header comment left behind in 2 of 7 files (Low)

`ClientRepositoryIntegrationTest:41` and `PickingorderRepositoryIntegrationTest:39` still carry the
old `// Clean up existing test data` line immediately above the new SBDEV-3242 paragraph. It now
labels nothing. `User`, `Location`, `Printer`, `Replenishorder` and `Sysprop` all removed theirs, so
this is an inconsistency within the same commit, not a convention.

### L3 — "one of nine such local workarounds" overstates in seven files (Low)

I enumerated the population independently rather than taking nine on trust, with a helper-aware scan
of every `@BeforeEach` / `@BeforeAll` body in all of `src/test` at the pre-fix base `34ffd9fa`
(inline deletes *and* calls into methods that delete — the shape that would otherwise miss
`Cyclecount`, whose delete lived in a `cleanupTestData()` helper).

**The count reconciles**: 26 classes have a `@BeforeEach` cleanup at the base. Eight of them are
`BaseRepositoryIntegrationTest` subclasses — the 7 swept here plus `Cyclecount` (removed in
`d427cedc`). The other 18 are all correctly excluded, and I checked why for each:

- 11 are `BasePostgresIntegrationTest` subclasses declaring `@Transactional(propagation = NOT_SUPPORTED)`
  (`MoveCronConcurrencyIT`, `IdempotencyFilterIT`, `StockunitBusinessServiceConcurrencyIT`, the
  `wipe()` ITs, …) — they commit by design, so their cleanup is load-bearing.
- 5 `Outbox*IT` classes `TRUNCATE outbox_message` for the same reason.
- 4 (`AdviceOutboxIntegrationTest`, both `Customerorder*OutboxIntegrationTest`,
  `SkuRestControllerAtomicityIntegrationTest`) extend `BaseRollbackIntegrationTest`, which
  **deliberately declares no class-level `@Transactional`** so service boundaries are real. Their
  `deleteAll()` is required.

So: **no class outside the seven was left broken, and none was left holding a workaround that the fix
made dead.** ATTACK #4 passes.

The one caveat: the ninth, `BillofladingServiceFinishTransferIT`, is not "such a workaround" at all —
it is an annotation override, a different shape that deletes no rows. The commit message explains
this correctly; the seven *in-file comments* just say "one of nine such local workarounds," which
reads as nine cleanup blocks. Say eight, or say "nine classes worked around this, seven of them by
deleting rows."

### L4 — two dead cleanup blocks survive, by the PR's own logic (Low)

Following from M2: `LocationRepositoryIntegrationTest:185-188` and
`ClientRepositoryIntegrationTest:209-210` are the same dead weight as the seven that went, just
sited inside a test body instead of `setUp`. `Location`'s even says "from previous tests." The sweep
is therefore incomplete against its own stated purpose ("a cleanup helper still needed after the fix
would mean the fix is incomplete for that class"). Both are harmless; either delete them in this
pass or record them as knowingly-left leftovers rather than as deliberate assertions.

### N1 — the same 7-line paragraph is pasted 7 times (Nit)

49 lines of near-identical comment replace 20 lines of code; net +13. Eight copies of the mechanism
explanation now exist (7 here + `Cyclecount`), and any correction has to land in all eight.
`BaseIntegrationTest:26-30` already established the better pattern in this very ticket — *"the
qualifier is load-bearing — see BaseRepositoryIntegrationTest for the full mechanism"* — a two-line
pointer to the single authoritative javadoc. Worth adopting for consistency; not worth blocking on.

### O1 — observation, not a finding: the aggregate A/B is a weak instrument, and there is a live example

`MessageRepositoryIntegrationTest` is untouched by this PR, so this is out of scope, but it
corroborates why the per-class mutation matters. `DeleteMessages` (`:257-298`) asserts
`assertThat(deleted).isGreaterThanOrEqualTo(0)` and `assertThat(firstBatch).isLessThanOrEqualTo(2)` —
both satisfied by **0**. The class is fully green under the pre-fix mutant. It is a candidate for a
follow-up on the existing ticket, not for this PR.

---

## Answers to the five attack items

1. **Is "identical failsafe totals" adequate evidence?** No. It is consistent with both "rollback
   works" and "nothing was checking," and the difference is real here: it is genuine evidence for 5
   classes, vacuous for 2 (`Printer`, `Replenishorder`). The named exact-count assertions do still
   assert what they did — no assertion was touched, the diff is `setUp`-only — and
   `Sysprop:137/:169` would absolutely notice a leaked row (proved: they saw 10 instead of 2 under
   the mutant). But `Printer:217`'s `hasSize(3)` is a page-size cap, not an exact count, and
   `Printer` has no leak-sensitive assertion at all.
2. **Direct proof of rollback?** Yes, by positive control rather than by absence — see the mutation
   table. For `Sysprop`, `Client`, `Location`, `Pickingorder` and `User`, a row written in one test
   method is demonstrably absent in the next.
3. **Was the scoping right?** The *mechanics* were: I diffed every delete call in the package
   between `34ffd9fa` and HEAD — exactly the setUp blocks went, no in-test delete was removed by
   accident, and no import was orphaned. The *rationale* was not: neither surviving in-test delete is
   part of what its test asserts (M2), and both are themselves dead (L4).
4. **Is "nine" right?** Yes, and I confirmed it independently rather than on trust — see L3 for the
   full 26-class enumeration and the reason each of the other 18 is correctly excluded. No class
   outside the seven is broken by this change. The only quibble is that the ninth is a different
   shape (L3).
5. **Is leaving `BillofladingServiceFinishTransferIT` correct?** Yes, and "redundant but harmless" is
   true — identical manager, propagation, readOnly. The *reason given* for leaving it is false, and
   its own comment is now stale (M3).

## Required before merge

1. **H1** — amend the `Replenishorder` comment to say the class is `@Disabled` and the removal is
   therefore unverified.
2. **M2** — correct the commit message: those two in-test deletes are leftovers, not assertions.
3. **M3** — correct the commit message's reason for leaving BOL-IT, and refresh that class's stale
   `:52-55` comment.

## Recommended, not blocking

4. **M1** — scope the "this is a check" claim to the 5 classes it holds for, or add one
   leak-sensitive assertion to `Printer`.
5. **L1/L2/L3/L4/N1** — comment accuracy, the two orphaned `// Clean up existing test data` lines,
   the "nine such" wording, the two surviving dead in-test blocks, and the 7× duplication.

No code change is required by any finding. Every deletion in the diff is correct.
