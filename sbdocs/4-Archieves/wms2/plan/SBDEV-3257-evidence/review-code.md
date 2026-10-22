# SBDEV-3257 — independent code review

**Reviewer lane:** independent review agent (no authoring context in this change)
**Reviewed:** worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3257`,
branch `bugfix/SBDEV-3257-stale-lane-down-comments`, **uncommitted working tree** at
`HEAD == origin/develop == 0dfcefc6`, plus
`/home/nampark/dev/wms-claude/sbdocs/9-System/scripts/stale-lane-claim-scan.py`.
**Date:** 2026-09-08
**Constraints honoured:** no `mvn` run in that worktree, no state-mutating git command in it.
All compile/behaviour claims below are derived from a Java lexer over both file versions and from
reading the harness sources — not from a build.

**Headline:** the change is substantively correct and the non-behavioural claim holds under an
independent instrument. But it introduces **one false causal claim repeated at four sites**
(H-1), it leaves **seven present-tense copies of the same stale claim in `src/main` and
`src/main/resources`** — including the `src/main` twins of two test files this change *did* fix
(H-2) — and the scanner has a **third break that reports a clean bill of health with its control
green** (H-3).

---

## High

### H-1 — FALSE CAUSAL CLAIM (×4): the two `smoke/*ContextLoadTest` classes are on the **H2** lane, which SBDEV-3239 never touched, and which was never down

This is the false statement the review was asked to hunt for. The repo has **two** full-context
`@SpringBootTest` lanes, and the change conflates them:

| base class | annotation | landlord URL source | fixed by 3239? |
|---|---|---|---|
| `BasePostgresIntegrationTest` | `@ActiveProfiles("postgres-integration")` | `@DynamicPropertySource` → Testcontainers | **yes** — this is 3239 |
| `BaseRollbackIntegrationTest` | `@ActiveProfiles("integration")` | `application-integration.properties:9` (H2, present since `aebb4c74`) | **no** |

Evidence:

- `src/test/java/net/aim_ai/wms/common/base/BaseRollbackIntegrationTest.java:29-30` —
  `@SpringBootTest(classes = StartApplication.class)` + `@ActiveProfiles("integration")`.
- `src/test/resources/application-integration.properties:9` —
  `landlord.datasource.jdbc-url=jdbc:h2:mem:wms_integration;...`. **The missing-landlord-URL defect
  SBDEV-3239 fixed cannot have applied to this profile**; the property is supplied.
- `git log -- src/test/java/net/aim_ai/wms/common/base/BaseRollbackIntegrationTest.java` →
  `1b3a2c68`, `aebb4c74`, `87c41640`. **No SBDEV-3239 commit.**
- surefire's only excludes are `**/*IntegrationTest.java` and `**/*E2ETest.java` (pom.xml, surefire
  `<excludes>`), so a class named `…ContextLoadTest` has always been in the surefire lane.
- `git log -- src/test/java/net/aim_ai/wms/smoke/PutawayResolverContextLoadTest.java` → `2295d3d4`,
  `0fc1014e`, both after `aebb4c74`. The class ran from its first commit.

Affected sites:

1. **`src/test/java/net/aim_ai/wms/smoke/PutawayResolverContextLoadTest.java:35-38`**
   > "It once did not: the `{@code @SpringBootTest}` harness it extends could not boot
   > (outbox_message Flyway-profile gap + unconfigured landlord datasource) … **SBDEV-3239 fixed the
   > harness**, so the one thing that can actually prove the seven beans wire is now doing so on
   > every build."

   Both halves are wrong: the harness it extends is `BaseRollbackIntegrationTest`, which never had
   either defect, and SBDEV-3239 did not touch it. The *conclusion* ("this class runs") is right;
   the *reason* is invented. This is strictly worse than the text it replaced, because the old text
   was recognisably a stale marker while the new one is a confident, specific, false attribution.

   Suggested replacement:
   ```
    * <p><b>This class runs, and always has.</b> The TODO that stood here claimed the
    * {@code @SpringBootTest} harness could not boot and that the DI evidence for SBDEV-2732 was
    * therefore only {@code mvn clean compile} plus the unit lane. That was never true of THIS class:
    * it extends {@link BaseRollbackIntegrationTest}, which is {@code @ActiveProfiles("integration")}
    * — the H2 full-context lane, whose landlord URL is supplied by
    * {@code application-integration.properties} — not the Testcontainers lane SBDEV-2217/SBDEV-3239
    * concerned. Surefire has run it since it was written. (SBDEV-3239 separately fixed
    * {@link BasePostgresIntegrationTest}; that fix is unrelated to this class.)
   ```

2. **`PutawayResolverContextLoadTest.java:74-75`** (the `sdrCacheEvictionEventHandler` field javadoc)
   > "It did not run when written; **the lane was restored by SBDEV-3239** and it is armed now."

   Same error, and the first clause is also unsupported — the field's enclosing class was in the
   surefire lane from commit `0fc1014e`. Replace with: *"It has been armed since it was written — see
   the class javadoc; the lane it runs in is the H2 `integration` lane, not the Testcontainers one."*

3. **`src/test/java/net/aim_ai/wms/smoke/ReplenishReassignContextLoadTest.java:26-29`**
   > "this extends the `{@code @SpringBootTest}` harness, which **was blocked when the class was
   > written** (the v2 Testcontainers Postgres lane could not boot). **SBDEV-3239 unblocked it**…"

   Same correction. `ReplenishReassignContextLoadTest:32` extends `BaseRollbackIntegrationTest`.

4. **`src/test/java/net/aim_ai/wms/unit/repo/UserRoleQueryContractUnitTest.java:36-39`**
   > "⚠ **\"No lane executes any repository query\" is FALSE as of SBDEV-3239** — the failsafe lane
   > runs repository tests against a real PostgreSQL, and the `{@code smoke/*ContextLoadTest}`
   > classes boot."

   First clause: true. Second clause: those classes booted before SBDEV-3239 too, so "as of
   SBDEV-3239" is wrong for that half. Note the sentence *this replaced* was also wrong in the same
   way ("every `smoke/*ContextLoadTest` extends the blocked `@SpringBootTest` harness") — so the
   underlying misconception was inherited, not invented, but it has now been re-asserted with a
   date attached. Suggest: drop the second clause, or rewrite as *"and the H2 `smoke/*ContextLoadTest`
   classes — which were never on the blocked lane — already booted."*

**Why this is High:** the ticket's stated purpose is "replace false statements with true ones", and
the failure mode named as worst-case ("a new false statement") has occurred, four times, with a
ticket number attached that makes it look verified.

---

### H-2 — SEVEN MISSED SITES in `src/main` / `src/main/resources`, four of which are the twins of test files this change *did* fix

`git grep -n "SBDEV-2217"` over the whole repo. The scanner cannot see these (it walks
`src/test` only — `stale-lane-claim-scan.py:113`), and the review brief explicitly asked for
`src/main`. All seven are present tense.

The damning pairs — this change fixed the test and left the class it documents:

| `src/main` (left stale) | test twin (fixed by this change) |
|---|---|
| `src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java:46` | `unit/security/FunctionGuardInterceptorUnitTest.java:48` ✅ |
| `src/main/java/net/aim_ai/wms/security/FunctionGuardStartupAssertion.java:32` | `unit/security/FunctionGuardStartupAssertionUnitTest.java:25` ✅ |
| `src/main/java/net/aim_ai/wms/security/FunctionGuardStartupAssertion.java:192` | `unit/security/FunctionGuardStartupAssertionUnitTest.java:246` ✅ |
| `src/main/java/net/aim_ai/wms/security/RequiresFunction.java:29-30` | `common/base/BaseControllerUnitTest.java:83` ✅ |

The repo now **contradicts itself between a class and its own test**, which is worse than
uniformly-stale prose: a reader who checks one gets the opposite answer from the other.

1. **`src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java:46`**
   > "`{@code standaloneSetup}` — the only MockMvc mode available in this repository, **since the
   > `{@code @SpringBootTest}` lane is down (SBDEV-2217)** — installs no method-security advisor"

   Replace the clause with the wording used in the fixed `BaseControllerUnitTest`: *"the only MockMvc
   mode used in this repository (a full-context lane exists as of SBDEV-3239 and could exercise
   method security; no controller test uses one yet)"*.

2. **`src/main/java/net/aim_ai/wms/security/FunctionGuardStartupAssertion.java:32`**
   > "so it is exercisable without a Spring context — **the `{@code @SpringBootTest}` lane is down
   > (SBDEV-2217)**, and a guard whose only proof needs that lane would be unverifiable."

   Its test twin was rewritten to *"so the guard is provable without one — which is what makes it
   verifiable in the fast lane at all."* Apply the same text here.

3. **`FunctionGuardStartupAssertion.java:192`**
   > "`{@code afterSingletonsInstantiated()}` is unreachable without a Spring context
   > **(SBDEV-2217)**"

   The test twin had exactly `(SBDEV-2217)` deleted and nothing else. Do the same: the statement is
   true without the citation.

4. **`src/main/java/net/aim_ai/wms/security/RequiresFunction.java:29-30`**
   > "no controller test in this repository can evaluate `{@code @PreAuthorize}` at all, and the
   > **`{@code @SpringBootTest}` lane is down (SBDEV-2217)**. A `{@code HandlerInterceptor}` reading
   > this annotation *is* exercisable in that lane"

   Note the second sentence's "that lane" resolves to the *down* lane, so removing the first clause
   without care leaves a dangling referent. Suggest: *"…can evaluate `@PreAuthorize` at all. A
   `HandlerInterceptor` reading this annotation **is** exercisable under `standaloneSetup`, which is
   the whole basis of the design."*

5. **`src/main/java/net/aim_ai/wms/util/OptimisticLockRetry.java:82`** — FALSE, verifiably:
   > "There is no automated test pinning it; **the only concurrency IT is `{@code @Disabled}` pending
   > SBDEV-2217**, so the guard is currently the SBDEV-3003 verify script's regression rows, not the
   > suite."

   `src/test/java/net/aim_ai/wms/service/StockunitBusinessServiceConcurrencyIT.java` carries **no
   `@Disabled`** (grep: class decl at :52, `@Test` at :173 and :254) and is in the failsafe
   `<includes>` and not in its `<excludes>`. Also `PickingorderBusinessServiceConcurrencyIT` and
   `UnitloadBusinessServiceConcurrencyIT` exist and are enabled — so "the only concurrency IT" is
   wrong on count as well as on state. Suggest re-deriving what those three now cover and saying
   either "pinned by `StockunitBusinessServiceConcurrencyIT`" or "still unpinned because those ITs
   assert X, not this".

6. **`src/main/resources/db/migration/V2.2.19__seed_web_view_function_grants.sql:54-55`**
   > "Nothing in the test suite can catch that: the verify row checks the statement's shape, and **no
   > test executes SQL (the Testcontainers IT harness is down, SBDEV-2217)**."

   FALSE — `AppPostgresDBSetupExtension:49` migrates `classpath:db/migration`, this file is in that
   chain, and 20 of 22 `BasePostgresIntegrationTest` subclasses run it every build.
   ⚠ **Do not edit this file.** It is an applied Flyway migration; Flyway's checksum covers comments,
   so changing one byte reds `flyway validate` on every environment that has already run V2.2.19 and
   needs a `flyway repair`. Correct handling: leave the file alone and record the correction on the
   ticket / in `sbdocs`, or (if it must be corrected in-repo) do it deliberately as its own change
   with the repair step planned. Flag it in the plan as a knowingly-stale-but-frozen site.

7. **`src/main/resources/db/verify-authorization-join-table-keys.sh:14`**
   > "There is no CI lane that can catch that: **the v2 Testcontainers harness cannot boot
   > (SBDEV-2217)**, `ddl-auto` is `none` in prod and `validate` in unit tests…"

   The first clause is false; the rest still stands and is the load-bearing half (validate ignores
   keys and indexes). Suggest: *"There is still no CI lane that catches this, but not for the reason
   originally given: the Testcontainers harness boots as of SBDEV-3239 — what it cannot see is keys
   and indexes, because `ddl-auto` is `none` in prod and `validate` in unit tests, and *validate
   ignores keys and indexes entirely*."* Note this is a **behaviour-adjacent file** (a shell script);
   a comment edit is still non-executable, but it takes the change out of "test-tree comments only".

---

### H-3 — the scanner's control does not cover its matcher: a neutralised matcher reports `0 across 0 files` and **exit 0**, control green

You asked for a third way to break it that still reports a plausible count. This is worse than
plausible — it reports a **clean bill of health**.

Reproduction (mutant written to scratchpad, original untouched): replace the four detector regexes
with never-matching literals, leaving `CONTROL_FILE` / `CONTROL_PHRASE` / `comment_blocks`
untouched.

```
### against the SBDEV-3257 worktree
positive control: PASSED (block-joining verified against BaseControllerUnitTest.java)
candidate comment blocks: 0 across 0 files
EXIT=0

### against origin/develop (the pre-fix population)
positive control: PASSED (block-joining verified against BaseControllerUnitTest.java)
candidate comment blocks: 0 across 0 files
EXIT=0            # docstring: "0  control passed, no stale claims found"
```

The control proves *comment-block joining*. It proves nothing about `CLAIM_FWD`, `CLAIM_REV`,
`DEAD_TODO` or `ENABLE_WHEN`. A typo in `SUBJECT`/`PREDICATE` — the two strings most likely to be
edited, since the docstring invites extending the phrasing list — silently converts the tool into
"everything is fine", and exit 0 is the code a future CI wrapper would trust.

**The fix pattern already exists in this repo.** `src/test/java/net/aim_ai/wms/unit/config/PostgresTestHarnessPinTest.java:99-108`
carries exactly the missing control:

> `// Control 2: the pattern matches the one literal we know exists.` … *"if it does not, every other
> file scanning clean is an artefact of a broken regex"*

Concrete patch — add a matcher control beside the joining control:

```python
# Control 2: the claim matcher must match a string known to BE a claim. Without this, a typo in
# SUBJECT/PREDICATE turns the tool into "no stale claims found" with Control 1 still green.
MATCHER_CONTROL = ("the @SpringBootTest lane is down (SBDEV-2217)", "TODO(SBDEV-2217): enable once")
...
    if not (CLAIM_FWD.search(MATCHER_CONTROL[0]) or CLAIM_REV.search(MATCHER_CONTROL[0])):
        print("CONTROL FAILED: CLAIM_FWD/CLAIM_REV no longer match a known stale claim. A zero from "
              "this run means the regex is broken, not that the tree is clean.")
        return 2
    if not DEAD_TODO.search(MATCHER_CONTROL[1]):
        print("CONTROL FAILED: DEAD_TODO no longer matches a known dead TODO.")
        return 2
```

---

## Medium

### M-1 — the second break: killing only the `//` collector keeps the control green and loses 8 blocks

`stale-lane-claim-scan.py:73` is the `//`-run collector; line 72 is the `/* */` collector. The
control phrase lives in a **javadoc** block, so it exercises line 72 only. Replacing line 73 with
`spans += []`:

```
### SBDEV-3257 worktree:  8 across 8  ->  7 across 7   (loses MobilePutAwayServiceUnitTest:1893)
### origin/develop:      26 across 21 -> 18 across 18  (loses 8 blocks, control still PASSED)
```

Eight silently-dropped sites on the real population, with a green control and a plausible count —
the same class of failure as the 12-vs-26 grep the docstring is built around. Fix: give the control
a **second** phrase that lives in a `//` run (e.g. the `// NOTE on why these are direct method calls`
block in `UserControllerUnitTest`), and require **both** to match.

### M-2 — the docstring's population figure (36) is not what the instrument reports (26)

`stale-lane-claim-scan.py:13-17`:
> "`git grep …` returned **12** hits for a population of **36**"

Run against `origin/develop`, the scanner itself reports **`candidate comment blocks: 26 across 21
files`**. The brief also says "~36 comments across 24 test files", and the diff touches 32 test
files. Three different numbers with no stated unit. The 12-vs-36 comparison is the docstring's
entire argument for "this is not a grep", and it compares a *line* count against something else.

Suggested fix: state the unit and re-derive, e.g. *"returned 12 matching LINES where the scanner
finds 26 comment BLOCKS carrying the claim across 21 files (measured 2026-09-08 on 0dfcefc6); the
raw sentence count is ~36 because several blocks state it twice."* — then verify that last figure or
drop it.

### M-3 — `TestClassTransactionManagerArchTest`: editing this `<ul>` deepened the contradiction rather than resolving it, because `ALLOWED` is **empty**

`ALLOWED` (`:134-152`) is a `LinkedHashMap` whose static initialiser contains **only a comment** —
SBDEV-3240 removed all six entries. Yet the javadoc block you edited still asserts live entries:

| line | text | reality |
|---|---|---|
| `:41` | "**Eleven annotations remain.** They are not fixed here because they cannot be *verified* here:" | zero remain |
| `:102` | "True today — none of the **8 entries** has a nested violation" | zero entries; also contradicts "eleven" |
| `:90` | "The **nine** method-level ones are in the Category-A classes of SBDEV-3240, all `@Disabled`." | zero |
| `:105-107` | "The `BasePostgresIntegrationTest` predicate fences one mechanism… **That entry is justified by** 'cannot boot a Spring context'" | that entry no longer exists |
| `:270` (test body) | "**9 of the 11 currently allow-listed annotations are method-level**" | zero |

Most of this is pre-existing drift from SBDEV-3240 — but this change edited the **first bullet of
that very list**, converting it to `<s>…</s> <b>RESOLVED:</b>`, which leaves a list whose header says
"eleven remain" and whose first item says "resolved" and whose remaining items describe entries that
are gone. That is the `pom.xml`-contradicts-itself shape the brief asked about, in a second file.

Either fix the whole block in this pass (recommended — it is prose-only and in scope) or leave the
bullet alone and note the drift on SBDEV-3258. Do not do half.

Also verified TRUE within the new text: `BasePostgresIntegrationTest` does declare
`@Transactional("tenantTransactionManager")` (`:64`) and `@ActiveProfiles("postgres-integration")`
(`:47`), so "carries no violation" is correct.

### M-4 — new sentence contradicts `BasePostgresIntegrationTest`'s javadoc on whether the rail fired

New text, `TestClassTransactionManagerArchTest.java:47-49`:
> "Kept as history because this entry is the worked example of the ratchet's blind spot documented
> below: **nothing fired** when the justification became FALSE."

`src/test/java/net/aim_ai/wms/common/base/BasePostgresIntegrationTest.java:59-60`:
> "SBDEV-3239 gave it `@ActiveProfiles` and it now has 21 subclasses, which is what made this due:
> **the rail's `allowListJustificationsMustStillHold` fired on exactly that change.**"

One says the rail fired, the other that nothing did. The arch test's own in-body comment
(`:301-315`) is narrower — it says *the ratchet* (`theAllowListMustShrinkNotLinger`) did not fire —
which is compatible with `allowListJustificationsMustStillHold` firing. The new sentence generalises
that to "nothing fired", which is what creates the conflict. Suggest naming the rule:
*"…the ratchet's blind spot documented below: `theAllowListMustShrinkNotLinger` does not fire when a
justification becomes false — only `allowListJustificationsMustStillHold` does, and it is what
caught this."*

### M-5 — `CLAUDE.md`: "~10 classes that build their own `PostgreSQLContainer`" is off by ~2×

`CLAUDE.md` (new section):
> "The **~10 classes** that build their own `PostgreSQLContainer` never call `withReuse`, so the flag
> reaches only the shared container."

Measured: `grep -rn "new PostgreSQLContainer" src/test` → **19 call sites in 19 files**, of which 18
are real constructions (the 19th, `PostgresTestHarnessPinTest.java:133`, is the phrase inside an
assertion message). And the repo's own `PostgresTestHarnessPinTest.java:26` says *"Before this ticket,
**20 classes** each named their own image"*. So CLAUDE.md now understates a figure another file in
the same change's blast radius states correctly.

Suggested replacement: *"The **18** classes that build their own `PostgreSQLContainer` (measured
2026-09-08: `grep -rn "new PostgreSQLContainer" src/test`) never call `withReuse`, so the flag
reaches only the shared `AppPostgresDBContainer`."*

Verified TRUE in the same section: only `AppPostgresDBContainer:49` calls `withReuse(true)`;
`AppPostgresDBContainer.IMAGE = "postgres:14-alpine"` (`:31`) is the only image literal in the code
of the test tree; `PostgresTestHarnessPinTest.onlyOnePlaceNamesAPostgresImage()` does fail the build
on a second one (with two exemptions, `AppPostgresDBContainer.java` and the pin test itself, and
comments stripped by `codeOnly()` — worth a parenthetical, since "anywhere in the test tree" is
slightly stronger than what the pin enforces).

### M-6 — missed site inside a file this change edited: `OrderReleaseSectionQueryIT:203`

> "every IT in this **family is `{@code @Disabled}`**, so **none of their seeding SQL has ever
> executed**, and copying it propagates the same omissions"

Now false — 20 of 22 `BasePostgresIntegrationTest` subclasses are enabled and in the failsafe lane
(only `TransferLaneLeakOnCancelIT` and `FixLocationAssignmentServiceIT` remain `@Disabled`). The
*advice* is still good, so keep it and re-tense: *"That list was taken from `information_schema` on a
live v2 database rather than from the neighbouring ITs, whose seeding SQL had never executed when
this was written (e.g. `ClientRepositoryIntegrationTest` seeds `itemdata` without `scale` or
`handlingunit_id`). Copying an IT's seed still propagates its omissions — check against
`information_schema`, not against a sibling."*

The scanner cannot see this: `is @Disabled` is not in `PREDICATE`. It is a concrete instance of the
blind spot the docstring names, and it sits **7 lines below a hunk this change edited**.

### M-7 — missed site inside another file this change edited: `MethodSecurityEnablementContractTest:291`

Line 291 (a `//` run, inside the file whose javadoc at `:51` this change softened):
> "**No lane in this repo evaluates `@PreAuthorize`**, so a reflective pin is the only available
> control."

The change's own new text elsewhere concedes the opposite —
`CustomMethodSecurityExpressionRootUnitTest:295`: *"A `@SpringBootTest` lane that could is available
since SBDEV-3239, but no test uses it for this"*. So this file now contradicts a sibling and,
arguably, itself. Suggest: *"No lane in this repo evaluates `@PreAuthorize` **today** — a
full-context lane that could exists since SBDEV-3239, but nothing uses it for this — so a reflective
pin is the only control actually in place."*

### M-8 — `pom.xml` still contains the sibling of the claim this change corrected

You corrected the `IdempotencyFilterIT` note in the **first** comment block (pom.xml ~:696-703) and
verified it well. The **second** block, inside `<includes>` (pom.xml ~:747-749), still says:

> "**Five further classes were deleted outright**: every one of their `@Test` bodies was a
> `fail("TODO…")` placeholder, so they asserted nothing and never had."

Same false claim, same PR, same file. `git show --stat b3262008` ("SBDEV-3239: restore the 6 deleted
stubs") restored **six** classes, and all six exist today with real tests:

| class | `@Test` count | `@Disabled`? |
|---|---|---|
| `IdempotencyFilterIT` | 5 | no |
| `LockOverviewViewIT` | 2 | no |
| `UnitloadBusinessServiceConcurrencyIT` | 1 | no |
| `StockunitBusinessServiceConcurrencyIT` | 2 | no |
| `PickingorderBusinessServiceConcurrencyIT` | 1 | no |
| `ReplenishmentOrderMaintenanceServiceIntegrationTest` | 1 | no |

Since the whole point of the first correction is "do not reconcile the `*IT` inventory against the
old claim", leaving the old claim 45 lines lower in the same file defeats it. Suggested replacement:
*"An earlier revision of this note said five further classes were deleted outright. See the
correction above: `b3262008` restored all six stubs and `691f7c6f` wrote three of them for real; all
six exist, are enabled, and pass in this lane."*

---

## Low

### L-1 — unused import left behind in a file this change edited (pre-existing, but in scope)

`src/test/java/net/aim_ai/wms/integration/OrderReleaseSectionQueryIT.java:9` —
`import org.junit.jupiter.api.Disabled;` with **no** `@Disabled` usage anywhere in the file (only
prose mentions at `:39` and `:203`). Introduced by `cbbeb5de` ("SBDEV-3239 slice E (2/2): un-disable
the 14"), which removed the annotation and left the import. Harmless to javac, but this change is
the one rewriting that exact javadoc. Delete line 9.

### L-2 — `CLAUDE.md`: "the four H2-migration plans" is unverifiable as written

> "…the reason **the four H2-migration plans** were rejected rather than scheduled (SBDEV-3239)."

The candidate set in `sbdocs/1-Projects/wms2/plan/` is
`260420-v2-integration-tests-h2-migration-report.md`, `260422-v2-testing-migration-rollup.md`, and
`260422-testing-rollup-reground/{P1-h2,P2-report-functions,P3-advisory-lock}.md` — five files, of
which it is not obvious which four are "H2-migration plans". Either name them or write "the
H2-migration plans" without the count.

Also in that paragraph: "**20s of a ~225s suite (~9%)** — measured". The 9% figure matches the
recorded baseline; the ~225s does not reconcile with today's measurement in the brief (surefire +
failsafe on `0dfcefc6`). Consider dating it: *"measured 2026-09-0X: ~20s of a ~225s suite"*.

### L-3 — `sbdocs/3-Resources/` reference docs carry the same false claim in present tense

The brief asked whether `sbdocs/` carries it. 50 markdown files mention `SBDEV-2217`. Almost all are
plans and review artefacts, i.e. legitimate dated history — but **two sites are in long-lived
reference material**, which is what `verify-docs` audits and what a future reader treats as current:

- `sbdocs/3-Resources/architecture/wms2-keycloak-role-matrix.md:289` — "The `@SpringBootTest` lane
  that would is down (SBDEV-2217)."
- `sbdocs/3-Resources/architecture/wms2-keycloak-role-matrix.md:779` — "…no controller test
  evaluates `@PreAuthorize` at all, and the `@SpringBootTest` lane is down (SBDEV-2217)."

Recommend fixing these two in this pass (same wording as H-2 item 1) and leaving the plan/review
files as history. Everything under `sbdocs/1-Projects/wms2/plan/` and `sbdocs/2-Areas/` reads as
dated record and should be left alone.

### L-4 — broken wikilink whose *name* asserts the false claim

`sbdocs/1-Projects/wms2/plan/SBDEV-2736-outbox-dispatcher-status-blind-rejection.md:792` —
`[[wms2-it-harness-broken-sbdev-2217]]`. No such note exists (`find sbdocs -iname
"*it-harness-broken*"` → nothing). Pre-existing; worth noting because the link text alone propagates
the claim to anyone skimming.

### L-5 — the scanner's control phrase is line-wrap-fragile

`CONTROL_PHRASE = exercised\s+in\s+this\s+repository` in `BaseControllerUnitTest.java`. The comment
explains it was chosen because it spans a line break — but nothing *enforces* that. This change
already rewrapped the surrounding javadoc; one more rewrap that puts the phrase on a single line
leaves the control passing while it stops proving joining, silently. Cheap hardening: assert it
matches the **flattened** text and does **not** match the raw text.

```python
if CONTROL_PHRASE.search(flat) and not CONTROL_PHRASE.search(txt_raw):
    control_flattened_ok = True   # genuinely spans a break
```
(requires `comment_blocks` to also yield the raw block text).

### L-6 — javadoc HTML: balanced; no build risk

Checked all 32 changed `.java` files, javadoc blocks only, `{@code}`/`{@link}` contents excluded:
**every** `<s>`, `<b>`, `<i>`, `<em>`, `<ul>`, `<li>`, `<p>` pair in the changed hunks is balanced,
including the new `<s>…</s>` in `TestClassTransactionManagerArchTest:44-49`. Two pre-existing
oddities outside the hunks (`<h2>`-shaped text in `AdviceStateReadOnlyContextTest:13` and
`DefaultServletWriteDisabledTest:25`; `<String>` read as a tag in `UserControllerUnitTest:848`) are
harmless. `<s>` is in JDK 21 doclint's allowed tag set anyway, and **doclint is off** —
`pom.xml:585` sets `<additionalJOption>-Xdoclint:none</additionalJOption>`, and the javadoc plugin
does not process `src/test`. No javadoc warning is reachable from this change.

### L-7 — tone note on two `@Disabled` reason strings

The appended `"TRACKED ON SBDEV-3258 (live) — SBDEV-3239 named above is the harness fix and is
shipped."` is good, but it now appears verbatim in three places and each `@Disabled` reason is
getting long enough that IDEs and surefire XML truncate it in the skip column. Consider shortening
to `"Tracked: SBDEV-3258. (SBDEV-3239 above is the shipped harness fix, not the blocker.)"` — same
information, and the sentence a reader sees first stays the actual blocker.

---

## Claims I VERIFIED TRUE

| claim | evidence |
|---|---|
| `BasePostgresIntegrationTest` now boots | `@ActiveProfiles("postgres-integration")` at `:47`, `@DynamicPropertySource datasources()` binding both `spring.datasource.url` and `landlord.datasource.jdbc-url` at `:78-88` |
| …and declares `@Transactional("tenantTransactionManager")` | `BasePostgresIntegrationTest.java:64` |
| `OrderReleaseSectionQueryIT` is not `@Disabled` and runs | no `@Disabled` annotation (only prose); in failsafe `<includes>` via `**/*IT.java`; not in `<excludes>` |
| …and **was** committed `@Disabled` (your new sentence) | `git show 4f578ac7:…OrderReleaseSectionQueryIT.java:52` → `@Disabled("Pre-existing IT-lane block: BasePostgresIntegrationTest cannot boot (SBDEV-2217 landlord …")`; removed by `cbbeb5de` |
| `IdempotencyFilterIT` exists, is not `@Disabled`, has 5 `@Test` | `src/test/java/net/aim_ai/wms/integration/service/IdempotencyFilterIT.java`, `@Test` at :99 :132 :160 :179 :215; extends `BasePostgresIntegrationTest` at :54 |
| `b3262008` restored six stubs; `691f7c6f` wrote three for real | `git show --stat` on both — 6 files / 645 insertions, then 2 files rewritten |
| failsafe `<includes>` covers `**/*IT.java` | pom.xml `<includes>`: `**/*IntegrationTest.java`, `**/*E2ETest.java`, `**/*IT.java`; three named `<excludes>` |
| several ITs apply the full `db/migration` chain | `AppPostgresDBSetupExtension:49` `MIGRATION_LOCATION = "classpath:db/migration"`, used at `:76`; 22 `BasePostgresIntegrationTest` subclasses, 20 enabled |
| the harness previously migrated the onboarding chain and aborted at `V1.2.01` | `AppPostgresDBSetupExtension:17-19` records it; `PostgresTestHarnessPinTest.setupExtensionMigratesProductionLocation()` now pins it |
| `PostgresTestHarnessPinTest` fails the build on a second image name | `onlyOnePlaceNamesAPostgresImage()` asserts `offenders.isEmpty()`, with a non-vacuity control in `imagePinScanIsNotVacuous()` |
| `withReuse(true)` is declared only on the shared container | sole call site `AppPostgresDBContainer.java:49` |
| **zero executable change** | see below |
| the scanner's two negative tests you already ran | reproduced: sabotaged joining regex → `CONTROL FAILED … Comment-block joining is broken`, exit 2; wrong repo root → `FAIL: … is not a directory`, exit 2 |
| the 8 remaining scanner candidates are legitimate past-tense history | read all 8 — `IdempotencyFilterIT:29`, `PutawayResolverContextLoadTest:19`, `ReplenishReassignContextLoadTest:12`, `OnHandQueryContractUnitTest:16`, `UserGroupQueryContractUnitTest:20`, `UserRoleQueryContractUnitTest:26`, `UserRoleServiceTransactionBoundaryTest:44`, `MobilePutAwayServiceUnitTest:1893`. Classification is correct **as far as tense goes** — but two of them (the smoke pair) are wrong on *cause*, see H-1 |

### The non-behavioural claim — verified with an independent instrument

⚠ My first attempt used a regex comment-stripper and reported "no string changed" for
`UserControllerUnitTest.java`. **That was a false negative**: a positive control (does the known
changed phrase survive stripping?) showed the regex had swallowed real code. Recording it because it
is the same class of instrument failure this ticket is about. The result below comes from a real Java
lexer that tracks string, char and text-block literals and escapes.

Per-file over all 32 changed `.java` files, comparing (a) the code-token stream with comments and
literals removed, and (b) the ordered list of string/char literals:

- **29 of 32 files: code stream identical, literal list identical.** Comment-only.
- **3 files: the only code-token delta is one extra `+` string-concatenation operator** inside an
  `@Disabled(...)` reason — `ClientRepositoryIntegrationTest` (58→59 literals),
  `FixLocationAssignmentServiceIT` (13→14), `TransferLaneLeakOnCancelIT` (10→11).
- **1 file: one literal shortened** — `UserControllerUnitTest`,
  `"too, but no test proves that (SBDEV-2217)"` → `"too, but no test proves that"`, inside an
  AssertJ `.as(...)`.

No import, signature, annotation attribute other than the `@Disabled` reason text, control-flow
statement or assertion *subject* changed anywhere. `pom.xml`'s delta is entirely inside an XML
comment; `CLAUDE.md` is markdown. **The claim holds.**

Can the `.as()` / `@Disabled` string edits change an outcome or break tooling?

- **`.as(...)`** is AssertJ's failure *description*. It is evaluated eagerly but affects only the
  message on failure. That assertion (`UserControllerUnitTest:1089-1093`) is `.isEmpty()` on a
  collection — unchanged. No behavioural effect. The one theoretical risk with `.as()` is a `%s`
  format placeholder with no matching vararg; there is none here (plain concatenation, no `%`).
- **`@Disabled` reason** is metadata only; JUnit records it as the skip reason. No selector, tag or
  `@EnabledIf` reads it.
- **Tooling that parses these strings:** the surefire/failsafe XML `<skipped message="…">` and the
  ClickUp/verify-row greps. I found no in-repo consumer — `git grep` for the old reason substrings
  turns up no script or test asserting on them, and `CommentOnlyTestBodyArchTest` /
  `TestClassTransactionManagerArchTest` read annotations *presence*, not reason text. Two caveats:
  (1) reason strings now exceed ~330 chars, which some CI report renderers truncate — cosmetic;
  (2) the three `@Disabled` reasons are what the `plan-state.sh` / verify-row workflow reads by eye,
  so the appended "TRACKED ON SBDEV-3258" is a net improvement there.
- Line-count reconciliation, for the record: `git diff --numstat` gives **+179 / −109** overall;
  `src/test` alone is **+144 / −108 = 252 changed lines**, of which **11** are the annotation-string
  lines (4 removed + 7 added across the four sites — this matches your "11" exactly) leaving **241**
  comment/javadoc lines, not 236. Immaterial, but restate it as 241, and say that the claim covers
  `src/test` only (`CLAUDE.md` + `pom.xml` add 36 more non-executable lines).

---

## Could not check, and why

- **That the suite is actually green with these edits.** I was instructed not to run `mvn` in that
  worktree, and I did not. I did not build a throwaway worktree either, because the lexer result
  above makes a compile regression structurally impossible (identical code tokens; one added `+`
  between adjacent string literals in three annotation arguments). If you want belt-and-braces,
  `mvn -q clean test-compile` in a fresh `git worktree add --detach` copy is sufficient — the full
  suite adds nothing here.
- **Whether the two `smoke/*ContextLoadTest` classes were *green* (as opposed to merely wired)
  before SBDEV-3239.** I proved the harness was wired (profile supplies the landlord URL; surefire
  includes the class; no 3239 commit on the base class) but not that the class passed on every
  historical commit. That does not weaken H-1: the claim under review is about the *harness*, and
  the harness demonstrably was not the thing SBDEV-3239 fixed.
- **The "~20s of a ~225s suite (~9%)" measurement** in `CLAUDE.md`. Not re-measured (would need a
  build). The 9% is consistent with the recorded H2-verdict baseline; the 225s absolute is the part
  I would date rather than assert.
- **Whether `V2.2.19` has actually been applied in every environment** (which determines how bad a
  comment edit there would be). I did not query the tenant `flyway_schema_history` tables. Treat the
  file as frozen unless you check.
- **The sbdocs population beyond the two `3-Resources` hits.** I triaged 50 files by path and
  present-tense phrasing rather than reading each; the plan/review files under `1-Projects` and
  `2-Areas` are dated artefacts and I classified them as history without reading all of them.
