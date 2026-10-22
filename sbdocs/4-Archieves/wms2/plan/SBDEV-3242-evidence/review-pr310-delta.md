# SBDEV-3242 — review of the unreviewed delta `ed94713c..HEAD` (PR #310)

- **Scope:** commits `19fa387c` and `6a58aec7` only. 2 files, +148/−21.
- **Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3242`, branch `bugfix/SBDEV-3242-repo-test-rollback-tx-manager`.
- **Reviewed:** 2026-09-07.
- **Verdict: DO NOT MERGE as it stands.** 1 High, 3 Medium, 9 Low. The High is a measured
  false-negative in the new rule — two independent mutations survived, one of them the change the
  rule was written to catch, written the idiomatic way. The two Mediums that matter are this
  ticket's recurring failure mode recurring: a correction written in answer to a review, and not
  itself attacked.
- Full suite re-run and confirmed: **6326 / 0 failures / 0 errors / 26 skipped**, BUILD SUCCESS.

Files under review:

- `src/test/java/net/aim_ai/wms/unit/config/TestClassTransactionManagerArchTest.java`
- `src/test/java/net/aim_ai/wms/common/base/BaseRepositoryIntegrationTestRollbackContractTest.java`

---

## 1. Mutation results

Five mutations, each applied with a uniqueness-checked anchor, verified applied, verified to
**compile** (a compile failure yields no surefire report and reads as "no failures" — the trap that
already produced two false SURVIVEDs on this ticket), then restored with the restore verified by
`git status --porcelain` and, for the pom, by md5 against a pre-mutation backup.

| # | Mutation | Expected | Result |
|---|---|---|---|
| A | Delete the failsafe `<includes>` element entirely (failsafe reverts to its `**/*IT.java` default) | KILLED | **SURVIVED** — 5 run, 0 failures, BUILD SUCCESS |
| A2 | Replace both includes with one `%regex[.*(IT\|IntegrationTest\|E2ETest)\.java]` — same coverage, plus the `*IT` lane | KILLED | **SURVIVED** — 5 run, 0 failures, BUILD SUCCESS |
| B | Add `<include>**/*IT.java</include>` to the failsafe includes | KILLED | KILLED — `allowListJustificationsMustStillHold`, line 309 |
| C | Method-level `@Transactional(propagation = NOT_SUPPORTED)` on `StockunitRepositoryTest#findsByUnitloadId` | KILLED | KILLED — `nonTransactionalPropagationsMustBeDeclared`, line 270 |
| D | Remove class-level `@Disabled` from `MobileReplenishServiceIntegrationTest` (Category-A) | KILLED | KILLED — `allowListJustificationsMustStillHold`, line 322 |
| E | Rename an allow-listed FQCN (simulates a renamed/deleted class) | comprehensible failure | `java.lang.AssertionError` carrying `byName`'s full explanation |

B, C and D re-derive three of the four claimed kills. A and A2 are new, and they are the finding
below — A2 is the one that matters, because unlike A it costs the author nothing.

Post-mutation state: worktree clean, `git status --porcelain` empty, `pom.xml` md5
`bed4a46db550bcf8be8dec6fb961fb6f` = the pre-mutation backup.

---

## 2. Findings

### H1 — HIGH. The pom predicate is blind to the most natural way its fact changes. `TestClassTransactionManagerArchTest.java:301-309`

```java
String pom = readPom();
String failsafeBlock = pom.substring(pom.indexOf("maven-failsafe-plugin"));
assertThat(failsafeBlock.contains("<include>**/*IT.java</include>")).isFalse();
```

The check asks *"is this literal string present?"*. The justification it stands for is *"do the
`*IT` classes run?"*. Those come apart the moment the `<includes>` element is **deleted** rather than
extended: failsafe then falls back to its own defaults — `**/*IT.java`, `**/IT*.java`,
`**/*ITCase.java` — the `*IT` classes run, `BaseIntegrationTest`'s deferral is void, and the rail
stays green.

Measured twice, not argued.

**Mutation A** — remove the `<includes>` element (pom still valid XML). `*IT` classes are now
selected by failsafe's defaults. Rail: 5 run, 0 failures, BUILD SUCCESS.

**Mutation A2, the one that matters** — replace the two literal includes with a single regex that
keeps every existing pattern *and* adds `*IT`:

```xml
<include>%regex[.*(IT|IntegrationTest|E2ETest)\.java]</include>
```

Rail: 5 run, 0 failures, BUILD SUCCESS. This is the realistic bypass. A costs the author their
`*IntegrationTest` coverage, so nobody would write it by accident; A2 costs nothing, is idiomatic
failsafe, wires the lane exactly as SBDEV-3239 intends, and leaves the ratchet green while the
justification it guards is void.

The sharp part: the pom comment sitting eight lines above the assertion states the exact mechanism
the assertion misses — `pom.xml:684`, *"Listing `<includes>` OVERRIDES failsafe's `**/*IT.java`
default"*. The rule reads the file that explains why the check is wrong.

This is also the file's own stated lesson, at `TestClassTransactionManagerArchTest.java:40-41` — *"a
guard fences the mechanism its author aimed at, not the invariant"* — reproduced one level up. The
mechanism aimed at is "someone adds that exact include line" (caught, mutation B, and it is exactly
what `origin/bugfix/SBDEV-3239-integration-lane-runnable` does at its `pom.xml:732` — verified). The
invariant is "failsafe does not select `*IT`". The rule is one literal string away from the first
and unboundedly far from the second: whitespace inside the tag, a regex include, or deletion of the
element all pass.

**Fix (one line, strictly stronger):** pin the includes exactly rather than probing for a substring —

```java
assertThat(failsafeIncludes(pom))
    .isEqualTo(List.of("**/*IntegrationTest.java", "**/*E2ETest.java"));
```

That fails on an addition (B), on a deletion (A), and on the regex form (A2) — because it pins what
the lane *is* rather than probing for one spelling of what it must not contain. Parsing the
`<configuration>` with `DocumentBuilder` also disposes of L2, L3 and L4 below at the same time.

### M1 — MEDIUM. Two javadoc claims cite SBDEV-3242 as the record for facts that are not on the ticket

Read all six comments on SBDEV-3242 (`clickup_get_task_comments`, 2026-09-07). Neither of these is
recorded there:

- `BaseRepositoryIntegrationTestRollbackContractTest.java:36` — *"the nine are listed on
  SBDEV-3242"*. They are not. No comment enumerates the nine workaround classes.
- `TestClassTransactionManagerArchTest.java:83` — *"Recorded on SBDEV-3242 as follow-up rather than
  swept silently."* No comment records the seven deliberately-retained `@BeforeEach` sweeps as a
  follow-up.

The second is load-bearing: "recorded rather than swept silently" is the entire argument for
leaving seven now-dead workarounds in the tree. As written the reader is told the debt is tracked,
and it is not.

(For contrast, the third such reference **is** true: `BaseRepositoryIntegrationTestRollbackContractTest.java:59`,
*"Recorded on SBDEV-3242 rather than fixed here"* for the `MessageRepositoryIntegrationTest`
coverage loss, is covered in detail in the review-lane-1 comment. So the convention is real; two of
the three instances just have no backing yet.)

**Fix:** post the two comments, or reword to "recorded here" and put the enumeration in the javadoc
(the nine already are, in the arch test — the contract test can point at that instead of the ticket).

### M2 — MEDIUM. The replacement causal claim is itself an over-strong single cause. `BaseRepositoryIntegrationTestRollbackContractTest.java:33-38`

The rewrite says the leak went unseen because *"the assertions that COULD have caught it were
defused one by one"* — the nine local workarounds.

`unit/repo/StockunitRepositoryTest` is a counterexample to that too. It has **no** `@BeforeEach`
(verified: 0 occurrences), so it is not one of the nine; it is named `*RepositoryTest`, so it runs in
surefire on every build; and it asserts `hasSize(1)` over a hard-coded, unscoped `unitloadId = 100L`.
Live, undefused, unscoped — and it never fired.

So the paragraph asserts a single cause ("It went unseen **because** …") while its own ⚠ note two
lines later cites the class that refutes it. The missing third cause is fixture uniqueness, which is
already measured and on the ticket in Nam's own words — *"presumably the fixtures are unique
enough."*

This is the same failure mode as the claim being corrected, one iteration on, inside the paragraph
that ends *"Treat any all/none/every in this file as needing two instruments before you repeat it."*

**Fix:** *"It went unseen for two reasons: nine classes defused their own assertions locally, and the
handful that remained unscoped — `StockunitRepositoryTest:36` among them — happened to use fixture
values no other test wrote."*

### M3 — MEDIUM. `BasePostgresIntegrationTest`'s predicate fences one mechanism, not the justification. `TestClassTransactionManagerArchTest.java:284-293`

Justification: the class *cannot boot a Spring context*. Predicate: the class *has no
`@ActiveProfiles`*. Boot-ability can be restored without touching that annotation:

- `@TestPropertySource` / `@SpringBootTest(properties = …)` / `@DynamicPropertySource`;
- a **subclass** declaring `@ActiveProfiles` — `byName(...)` reads the base class only. (Verified
  none of the six current subclasses does. The subclass would boot and inherit the bare
  `@Transactional`; the rule would stay green.);
- changing `AppPostgresDBSetupExtension` to set `landlord.datasource.jdbc-url` — which is the
  alternative fix named **in the guarded class's own TODO** (`BasePostgresIntegrationTest.java:31-32`,
  *"or add a dedicated landlord-datasource config for the Testcontainers context"*).

The commonest path is caught (mutation D's sibling; the 3239 branch's `@ActiveProfiles("postgres-integration")`
would fire it — verified present on that branch), so this is a proxy that works today, not a broken
check. But the file documents four other blind spots meticulously at lines 91-109 and does not
document this one.

**Fix:** either widen the predicate (also assert the extension does not set the landlord URL), or add
a fifth bullet to the "what this rail cannot see" list naming the three bypasses. The second is
cheap and matches the file's existing standard.

### L1 — LOW. Unused import. `TestClassTransactionManagerArchTest.java:25`

`import java.util.stream.Collectors;` — the M1 rewrite replaced the only use
(`.collect(Collectors.toCollection(TreeSet::new))`) with an explicit loop. One occurrence in the
file, and it is the import. Harmless to the build; this file is a rail others will copy.

### L2 — LOW. `failsafeBlock` is not the failsafe block. `TestClassTransactionManagerArchTest.java:302`

`pom.substring(pom.indexOf("maven-failsafe-plugin"))` runs to **EOF** — today that span also covers
the jacoco plugin, `<dependencyManagement>` and `</project>`. Any future
`<include>**/*IT.java</include>` anywhere below `pom.xml:677` (a profile, a second surefire
execution) is a false RED attributed to failsafe. Bound the substring at the matching `</plugin>`.

### L3 — LOW. `indexOf` returning −1 crashes without a diagnostic. `TestClassTransactionManagerArchTest.java:302`

If the failsafe plugin is ever removed — plausible if the `*IT` lane is folded into surefire —
`substring(-1)` throws `StringIndexOutOfBoundsException`: a bare stack trace, in a file where every
other failure carries a paragraph of explanation. `readPom()` already models the right thing for the
missing-file case; do the same here.

### L4 — LOW. The comment false-positive is one edit away, in both directions. `TestClassTransactionManagerArchTest.java:303`

`contains` is a plain substring search over raw text; XML comments are not stripped.

Checked as asked, and the answer is **no, it does not defeat the check right now**: the tagged form
`<include>**/*IT.java</include>` occurs **0 times** in `pom.xml`, because the SBDEV-3091 comment
writes the pattern untagged and backticked (`pom.xml:683,684,687`).

It is one edit from doing so, and that comment's opening line is literally *"READ BEFORE ADDING
`**/*IT.java` HERE"* — a future editor spelling out the XML they must not add turns the rail red for
no reason. Symmetrically, a commented-out `<!-- <include>**/*IT.java</include> -->` **inside** the
includes block would fire while nothing actually runs. An XML parse removes both.

### L5 — LOW. `EXEMPT_NON_TRANSACTIONAL`'s javadoc is stale after M1. `TestClassTransactionManagerArchTest.java:142`

The set can now hold method entries — mutation C put
`net.aim_ai.wms.unit.repo.StockunitRepositoryTest#findsByUnitloadId` into `actual` — but the javadoc
still says *"**Classes** whose `@Transactional` declares a propagation that runs
NON-transactionally"*. Someone adding a method-level exemption will guess the wrong key format and
get a confusing set-equality diff. One line: say entries are `FQCN` or `FQCN#method`.

(Answering the review brief's Q4 directly: the set-equality failure **is** readable. AssertJ printed
both sets in full, and with one element the delta is obvious. `containsExactlyInAnyOrderElementsOf`
would give a true diff and would scale better, but this is not a defect at the current size.)

### L6 — LOW. The `..` fallback in `readPom()` can only ever read a *different* pom. `TestClassTransactionManagerArchTest.java:328`

This is a single-module build (`<packaging>jar</packaging>`, no `<modules>`) and `../pom.xml` does
not exist. Surefire's working directory defaults to `${basedir}`, so `Path.of("pom.xml")` is correct
for every Maven invocation and for the IntelliJ default (module dir). The fallback is therefore dead
today, and in any future aggregator layout it would silently read the **parent** pom — which either
has no failsafe plugin (L3's crash) or configures failsafe differently, giving a false green. Drop
it, or assert the file actually contains `maven-failsafe-plugin` after reading.

### L7 — LOW. Botched rewrap. `TestClassTransactionManagerArchTest.java:65`

`…do not repeat it as the latter. Closing this: fix the base class, re-run failsafe, then check that`
— roughly 150 columns against the file's ~100-column convention. The M4 edit was inserted without
re-wrapping the tail.

### L8 — LOW. Both new citations point at the predicate, not the assertion the sentence names. `BaseRepositoryIntegrationTestRollbackContractTest.java:42-45`

Both claims are **substantively true**; the line numbers are off:

| Cited | Says | Actually |
|---|---|---|
| `StockunitRepositoryTest:26,33` | "asserts `hasSize(1)`" | `:26` sets `unitloadId(100L)`, `:33` queries it. The `hasSize(1)` is at **`:36`**. |
| `SyspropRepositoryIntegrationTest:134,166` | "assert exact counts" | `:134`/`:166` are the query lines. The `hasSize(2)` assertions are at **`:136`** and **`:168`**. |

Consistent convention (both cite where the unscoped literal predicate appears), just not what the
verb in the sentence claims. Cite `:36` and `:136,168`, or reword to "the unscoped predicate at …".

### L9 — LOW. The rule's remedial advice is stale in the exact scenario it fires. `TestClassTransactionManagerArchTest.java:307-308`

The failure message says *"Failsafe now includes `**/*IT.java`, so they DO run … check
`MessageCleanupBatchServiceIT` by hand"*. On the branch the comment names,
`origin/bugfix/SBDEV-3239-integration-lane-runnable`, the include is added **and**
`MessageCleanupBatchServiceIT` is explicitly excluded (that branch's `pom.xml:765`). So when the rule
fires against the change it was written for, it directs the reader to hand-check a class that change
has excluded.

---

## 3. What checks out

Verified, not taken on trust:

- **Allow-list coverage is complete (brief Q3): 8 entries, 8 checked.** `BasePostgresIntegrationTest`
  (via `@ActiveProfiles`), `BaseIntegrationTest` (via the pom), six Category-A classes (via
  `@Disabled`). Counts reconcile: `ALLOWED` sums to **11** = 2 class-level + 9 method-level, and all
  nine method-level annotations are in the six Category-A classes — grepped each
  (`MobileTransferOrderServiceIntegrationTest:45` is a commented-out annotation, so its live count of
  1 is right). The M1 comment's *"9 of the 11 currently allow-listed annotations are method-level"*
  is exact.
- **`byName()`'s failure mode is right (brief Q2).** Mutation E surfaced as a plain
  `java.lang.AssertionError` carrying the full explanation. The `.as(...)` description is skipped
  because the throw happens during argument evaluation — which is the better outcome here, since
  `byName`'s own message is the more useful one. Throwing aborts at the first missing entry, so two
  simultaneous renames cost two round trips (minor); and `theAllowListMustShrinkNotLinger`
  independently catches the same condition, so nothing is lost either way.
- **"from 6 subclasses that could not boot to 16 that do" is exact.** 6 classes `extends
  BasePostgresIntegrationTest` on HEAD; 16 on `origin/bugfix/SBDEV-3239-integration-lane-runnable`.
  Both counted.
- **"At least nine" is right, and correctly hedged (brief Q5).** Seven `@BeforeEach` literal-name
  sweeps — `Sysprop`, `Location`, `Client`, `User`, `Pickingorder`, `Printer`, `Replenishorder`
  `RepositoryIntegrationTest` — each read, each genuinely deleting its own fixture rows by literal
  name or prefix, and **all seven do subclass `BaseRepositoryIntegrationTest`** as the javadoc
  claims. Plus `BillofladingServiceFinishTransferIT`'s own qualified override, plus
  `CyclecountRepositoryIntegrationTest`'s `CC-TEST*` sweep, now deleted and replaced with an
  explanatory comment at `:39-43`.
- **The M4 `MessageCleanupBatchServiceIT` restatement is accurate.** Read the source: it captures
  `TransactionSynchronizationManager.getCurrentTransactionName()` and asserts
  `contains("MessageCleanupBatchService")`, `contains("deleteOnce")`, and `!= outerTxName`.
  Transaction names derive from the proxied method and the test method, not from the manager, so all
  three hold under any qualifier — the "risk looks like nil" reading is correct. And restating the
  deferral as *unmeasured* rather than *known to break* is the honest framing, since the class runs
  in neither lane.
- **The M1 fix closes the hole rather than moving it.** `nonTransactionalPropagationsMustBeDeclared`
  now mirrors `currentViolations()`'s class+method shape exactly, and mutation C confirms a
  method-level `NOT_SUPPORTED` is caught. `getMethods()` returns declared methods only, matching
  `currentViolations()` and the file's stated dependence on ArchUnit not resolving inherited
  annotations.
- **No regression in the four previously-reviewed rules.** The diff touches only
  `nonTransactionalPropagationsMustBeDeclared`, adds `allowListJustificationsMustStillHold` +
  `readPom()` + `byName()`, and edits javadoc. `nonVacuityGuard`,
  `noNewBareTransactionalInTests`, `theAllowListMustShrinkNotLinger`, `isBare` and
  `currentViolations` are byte-identical.
- **The two new "what this rail cannot see" bullets (`:101-109`) are true.** The allow-list is keyed
  on `JavaClass.getName()`, which is the binary name, so a `@Nested` violation would need
  `Outer$Inner`; and the per-class counts do depend on `isAnnotatedWith` not following inheritance.

---

## 4. Suite

`mvn clean test` on the delta as it stands, worktree verified clean first — `clean` deliberately,
because stale `target/test-classes` after six mutations is exactly how a suite number lies.

```
[WARNING] Tests run: 6326, Failures: 0, Errors: 0, Skipped: 26
[INFO] BUILD SUCCESS
```

Matches the claimed 6326 / 0 / 26 exactly, and reconciles with the pre-delta baseline recorded on
the ticket (6325 run on the merged tree) plus the one test this delta adds,
`allowListJustificationsMustStillHold`. `BaseRepositoryIntegrationTestRollbackContractTest` ran 3/3
green.

---

## 5. Verdict

**Do not merge as it stands.** The gap is small and mechanical:

1. **H1** — replace the substring probe with an exact pin of the failsafe `<includes>` list (or an
   XML parse, which also closes L2, L3 and L4). Re-run mutations A and A2 and confirm both are
   killed; B must stay killed.
2. **M1** — post the two SBDEV-3242 comments, or reword the two claims to point at the javadoc that
   actually holds the enumeration.
3. **M2** — complete the causal sentence; `StockunitRepositoryTest` is a live counterexample to the
   replacement claim as well as to the one it replaced.
4. **M3** — one bullet in the existing blind-spot list.
5. **L1–L9** — all one-liners; worth taking in the same pass.

The delta does close H1 and M1 in substance, and three of its four claimed kills re-derive cleanly.
What holds it back is that two of the three non-Low findings are this ticket's signature failure
mode recurring: a correction written in answer to a review and not itself attacked. H1's pom half
does not do what it says for the general case, and M1/M2 are new claims asserted without the
verification the corrected claims lacked.

Nothing here is a production risk — the entire delta is test infrastructure.
