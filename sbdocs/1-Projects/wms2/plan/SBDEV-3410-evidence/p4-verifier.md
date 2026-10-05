# SBDEV-3410 P4 — plan-conformance verification

**Graded:** commit `0391cfb2` on `feature/SBDEV-3410-p4-stock-record-details-item-name`, worktree
`/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410-p4`, off `origin/develop` @ `3214a9c3`
(`git status --short --branch` → `[ahead 1]`, one commit, no other commits on the branch).

**Question graded:** did P4 build exactly what the plan specifies — no less and no more? Not "is the code
good" (sibling lane).

**Instruments used:** source reading; `git diff origin/develop...HEAD`; the surefire XML already on disk
(read, not re-run); `javap -c` against `spring-data-jpa-3.5.7.jar` on the local `~/.m2`; SQL against
`dev_wh01_om1` (`mcp__wms2-wineco-dev`). **No `mvn` was run** — a sibling lane is live in this tree.
Read-only throughout: no `checkout --`, `restore`, `stash`, `reset`, or edit.

**Overall: PASS on conformance.** Every §5.2 P4 checkbox, both §7.3 rows, every applicable §7.5 row and
both clauses of AC-3's popup half are built, and nothing of substance was built that no plan item asked
for. **Two corrections are required before the PR** — neither is a conformance gap, both are claim- and
floor-discipline defects, and one of them is a false statement in the commit message. They are §A and §B
below.

---

## 1. Plan items, one row each

### §5.2 P4 — the authoritative task list (three checkboxes)

| # | Plan item | Verdict | Proof |
|---|---|---|---|
| 1 | `StockrecordService.getStockRecordDetails` per §3.7 — `ifPresent`, not `orElseThrow` | **VERIFIED** | `src/main/java/net/aim_ai/wms/service/StockrecordService.java:626-631`. The four code lines are token-identical to §3.7's quoted block: same guard pair `s.getClientId() != null && s.getItemdata() != null`, same finder `itemdataRepository.findByClientIdAndItemNr(s.getClientId(), s.getItemdata())`, same `.ifPresent(i -> details.put("itemName", i.getName()))`. No `orElseThrow`. |
| 1a | §3.7's "already exists — no new finder" | **VERIFIED** | `ItemdataRepository.java:28-29` declares `findByClientIdAndItemNr` on `origin/develop`; the diff adds no repository method. `itemdataRepository` was already a constructor-injected field (`StockrecordService.java:31`, `:46`, `:54`) and already `@Mock`-ed (`StockrecordServiceUnitTest.java:41`) — no constructor change, no new mock, exactly as the commit message claims. |
| 2 | Extend `StockrecordServiceUnitTest`: key present when the SKU resolves, key **absent** when it does not | **VERIFIED** | `detailsCarryItemNameWhenSkuResolves` (`:665-684`) and `detailsOmitItemNameWhenSkuDoesNotResolve` (`:686-716`). `@Test` count 33 → 37. Nested `GetStockRecordDetails` ran **7/7, 0 failures, 0 errors** (`target/surefire-reports/…$GetStockRecordDetails.txt`), and all four new methods appear as `<testcase>` elements in the paired XML. |
| 3 | Mutation-check: `ifPresent` → unconditional `details.put("itemName", null)`, absent-key assertion goes red; `doesNotContainKey` distinguishes absent from null, `get() == null` does not | **VERIFIED (design) / PARTIAL (evidence)** | The assertion form is right and *structurally must* kill: `assertThat(details).doesNotContainKey("itemName")` at `:713` fails on a present-but-null key by construction, so the mutant cannot survive it. The kill is one-to-one and attributable, as the plan requires. **What I could not verify without executing:** there is no `target/pit-reports` directory in this worktree, and §7.8 mandates *PIT scoped to the changed class*, not a hand-edit. The mutation appears to have been run by editing the source and re-running — which is not the "hand-rolled harness" §7.8 forbids, but is also not the instrument §7.8 prescribes. Evidence of the run exists only in the commit message. |

⚠ **The commit message misattributes two mutations to the plan.** It says *"one of the three the plan
requires is UNKILLABLE"* and *"§5.2 P4's third mutation is unkillable"*. **§5.2 P4 lists exactly one
mutation** (checkbox 3, the unconditional-put), and **§7.8 carries exactly one P4 row** (`itemName`
absence → `put("itemName", null)` → `detailsOmitItemNameWhenSkuDoesNotResolve`). The `orElseThrow` and
`drop the guard` mutants are the implementer's own additions. **No plan-required kill was skipped.** The
floor's *"mutation-check every new assertion"* is the standard the fourth test misses — see §B.

### §3.7 — the design

| Design clause | Verdict | Proof |
|---|---|---|
| Resolution added "alongside the existing client resolution" | **VERIFIED** | Inserted at `:626`, immediately after the `if (s.getClientId() != null)` block closes at `:613`. `details` is a `HashMap` (`:587`), so insertion point carries no ordering semantics and `fullDetails.vue` renders by `:field-names` keys — placement is free. |
| `ifPresent` (not `orElseThrow`) is deliberate: an unresolved SKU leaves the key **absent**, does not explode the popup | **VERIFIED** | `:630`. Pinned by two tests: `detailsOmitItemNameWhenSkuDoesNotResolve` (absent) and `detailsStillReturnWhenSkuDoesNotResolve` (does not throw). |
| `'itemName': 'SKU Name'` in `:field-names` | **OUT OF SCOPE** | wms2-web-ui, P6. |

### §7.3 — the two `StockrecordServiceUnitTest` rows

| Row | Verdict | Proof |
|---|---|---|
| `detailsCarryItemNameWhenSkuResolves` — `itemName` present | **VERIFIED** | `:675-683` stubs `findByClientIdAndItemNr(1L, "ITEM-001")` → `Optional.of(itemdata)` and asserts `containsEntry("itemName", "Alpha Widget")`. Stub matches the fixture exactly: `savedStockrecord.setClientId(1L)` (`:560`), `setItemdata("ITEM-001")` (`:575`). |
| `detailsOmitItemNameWhenSkuDoesNotResolve` — `doesNotContainKey("itemName")`, absent ≠ null | **VERIFIED** | `:711-716`. Uses `doesNotContainKey`, **not** `get() == null` — the exact form the plan names, and the reason is restated in the javadoc. |

### §7.5 — applicable constraint rows

| # | Constraint | Verdict | Proof |
|---|---|---|---|
| 2 | OSIV off | **VERIFIED / N/A** | No lazy association touched. `Itemdata` is fetched by a finder returning a materialised entity; only `getName()` is read. |
| 3 | No `@Transactional` added; bare `@Transactional` means landlord in `service` | **VERIFIED** | The diff adds no annotation of any kind to `StockrecordService`. `getStockRecordDetails` keeps whatever demarcation it had on `develop`. |
| 6 | Caffeine — "No new cache" | **VERIFIED, with a note** | No cache added. ⚠ **Note, not a gap:** a cached wrapper for this exact lookup already exists — `ItemdataService.findByClientIdAndItemNr` (`ItemdataService.java:51-55`), `@Cacheable(value = "itemdata", …)`, tenant-keyed, 3000 entries / 5 min (`CacheConfig.java:39`). §3.7 prescribes the **repository**, so P4 conforms; the divergence is the plan's, not the implementer's. See §C. |
| 1, 4, 5, 7, 8 | Jakarta namespace · naming strategy · SDR registration · Micrometer · Flyway | **N/A to P4** | No entity, no repository declaration, no SDR surface, no metric, no SQL, no migration in the diff. |

### AC-3 — popup half only (the table-column half is P6, wms2-web-ui)

| Clause | Verdict | Proof |
|---|---|---|
| "`getStockRecordDetails` returns a map containing `itemName` when the SKU string resolves" | **VERIFIED** | `detailsCarryItemNameWhenSkuResolves`, green in the on-disk surefire XML. |
| "When it does not resolve, the key is ABSENT from the map (`doesNotContainKey`, not `get() == null`)" | **VERIFIED** | `detailsOmitItemNameWhenSkuDoesNotResolve`, the prescribed assertion form verbatim. |
| "and the row still appears" — popup analogue | **VERIFIED** | `detailsStillReturnWhenSkuDoesNotResolve` asserts the call returns and carries `id`, `itemdata`, `clientName`, `operator`. (The *table*-row clause is P1's `LEFT JOIN`, already merged.) |

### Evidence claims — independently re-derived by reading, not re-run

| Claim in the commit | Verdict |
|---|---|
| Full surefire **6754 run / 0 failures / 0 errors / BUILD SUCCESS** | **CONFIRMED.** Aggregating `<testsuite>` attributes over all 1743 `target/surefire-reports/TEST-*.xml`: **tests 6754, failures 0, errors 0, skipped 1.** (The commit does not mention the 1 skipped; immaterial.) |
| Targeted `StockrecordServiceUnitTest` **37/37** | **CONFIRMED.** `@Test` count is 37; the nested `GetStockRecordDetails` report is 7/7. |
| The reports grade the committed source | **CONFIRMED.** `StockrecordService.java` mtime 06:31:49, test file 06:32:18, surefire XML 06:41:13, commit 06:43:49 — the run sits between the last edit and the commit. |
| `orElseThrow` mutant errors **four** tests, not one | **CONFIRMED by inspection**, and the commit's count is exactly right: the two new tests that stub an empty Optional plus the two pre-existing tests that leave the finder unstubbed (`shouldReturnCompleteStockRecordDetailsWithClient`, `shouldIncludeTimestampFieldsInDetails`). The other two of the seven are immune — `shouldReturnStockRecordDetailsWithoutClientWhenClientIdIsNull` (null `clientId`) and `detailsOmitItemNameWhenSkuIsNull` (null `itemdata`) both short-circuit the guard. The commit is right to say the kill is not one-to-one and right not to claim it is. |
| Three mutations run | **NOT VERIFIABLE without executing.** No PIT report on disk; §7.8 prescribes PIT. |

---

## A. The "UNKILLABLE" claim is wrong — on the mechanism, and on the conclusion

The commit and the `detailsOmitItemNameWhenSkuIsNull` javadoc both assert that dropping
`s.getItemdata() != null` is unkillable because *"the finder is called with a null `itemNr`, matches
nothing, and `ifPresent` no-ops"*, making the guard *"a query-avoidance optimisation"* whose presence is
*"behaviourally invisible to any unit test"*. **Three separate things are wrong.**

**A1 — it is a derived query, and a null binding becomes `IS NULL`, not "matches nothing".**
`ItemdataRepository.java:28-29` carries `@RestResource` and **no `@Query`** — so it is a property-derived
query, built by `PartTreeJpaQuery`. In the exact version on this classpath (`spring-boot-starter-parent`
3.5.9 → `spring-data-jpa-3.5.7`, jar present at `~/.m2/repository/org/springframework/data/spring-data-jpa/3.5.7/`),
verified at bytecode level with `javap -c`:

- `ParameterMetadataProvider$ParameterMetadata.<init>` branches on the bound value being null and, for
  `Part$Type.SIMPLE_PROPERTY` / `NEGATING_SIMPLE_PROPERTY`, sets the metadata type to
  **`Part$Type.IS_NULL`** (constant loads at offsets 14 / 27 / 40 of the constructor).
- `JpaQueryCreator$PredicateBuilder.build()` calls `ParameterMetadata.isIsNullParameter()` (offset 794)
  and, for `SIMPLE_PROPERTY`, emits `jakarta.persistence.criteria.Expression.isNull()` (offset 812).

So the SQL is **`WHERE client_id = ? AND item_nr IS NULL`**. That is a predicate that *matches rows whose
`item_nr` is NULL* — it is not the no-op the commit describes. If such a row existed for that client, the
guardless code would put **another product's name** into a null-SKU stockrecord's popup.

**A2 — the conclusion survives only on an uncited constraint in a different table.**
`itemdata.item_nr` is **NOT NULL** — `db/migration/V2.2.00__base_v2_schema.sql:937` (`item_nr character
varying(255) NOT NULL`, inside `CREATE TABLE public.itemdata` at `:927`), confirmed live on
`dev_wh01_om1` (`information_schema.columns` → `is_nullable = 'NO'`). So `IS NULL` matches zero rows
*today*, and the observable outcome really is identical. But that is an accident of a constraint on
another table which the commit never cites and no test pins. The guard is therefore **not** "a
query-avoidance optimisation"; it is defence against an `IS NULL` match that is currently neutralised
elsewhere. Characterising it as a pure optimisation invites the next reader to delete it.

**A3 — the mutant is killable, in one line.** "Behaviourally invisible" conflates *return-value*
observability with observability. A guard whose purpose is *don't issue the query* is killed at the
interaction level, which is what Mockito is for:

```java
verify(itemdataRepository, never()).findByClientIdAndItemNr(any(), any());
```

With the guard: zero invocations → green. Without it: one invocation with `(1L, null)` → red, and the
message names the unwanted invocation, so the kill is attributable. This needs **no new import**
(`import static org.mockito.Mockito.*` at `:28`, `any` at `:26`) and is thoroughly idiomatic —
`never()` already appears **7 times in this very class** and in 160 test files repo-wide. The
primitive-unboxing `any()` trap the repo has a standing note about does **not** apply: both parameters
are declared as reference types (`Long`, `String`), so nothing unboxes.

A second, state-level kill also exists — stub `findByClientIdAndItemNr(1L, null)` to return an
`Itemdata`, modelling the `IS NULL` match A1 describes, then assert `doesNotContainKey("itemName")` —
but the `never()` form is the honest one, because it asserts the thing the guard actually does.

**Why it survived:** with the finder unstubbed for `(1L, null)`, Mockito's `ReturnsEmptyValues` returns
`Optional.empty()`, so `ifPresent` no-ops and the map is identical. The survival is an artefact of the
stubbing, not a property of the guard — and it is the same Mockito default the commit correctly invokes
to explain the four-test `orElseThrow` blast radius.

**Verdict on A:** the reasoning is incorrect, and the mutant is killable. **No plan-required kill was
skipped** (§5.2 P4 and §7.8 each name one mutation, and it was killed cleanly). What was skipped is the
floor's *mutation-check every new assertion* for the fourth test. **Required before the PR:** add the
`never()` line, and correct both the commit message and the javadoc — leaving a false "unkillable"
finding in the history is the more expensive half, because it is exactly the kind of claim a later
reader will cite rather than re-derive.

---

## B. `detailsOmitItemNameWhenSkuIsNull` — adding it was right; leaving it as written is not

**As written it is a green test that proves nothing.** Both of its assertions are vacuous against every
mutant in the class:

- `doesNotContainKey("itemName")` (`:768`) passes **with** the guard, **without** the guard (A3: the
  unstubbed mock returns `Optional.empty()`), and with the **entire P4 block deleted**. An assertion that
  holds when the feature does not exist grades nothing.
- `containsEntry("id", 100L)` / `containsEntry("clientName", "Test Client")` (`:772`) duplicate
  `detailsStillReturnWhenSkuDoesNotResolve` and add no kill.
- The javadoc's stated purpose — *"pins the null-safety of the whole path — that a null SKU produces an
  absent key rather than an NPE"* — pins a hazard that does not exist. `Optional.ifPresent` on an empty
  Optional cannot NPE, and with the guard in place the null never reaches the finder at all.
- The javadoc's premise is also over-claimed: *"`stockrecord.itemdata` is nullable in `db/migration`, so
  this is reachable data rather than a hypothetical."* The **nullability** is true
  (`V2.2.00__base_v2_schema.sql` → `itemdata character varying(255)`, no `NOT NULL`; `information_schema`
  on `dev_wh01_om1` → `is_nullable = 'YES'`). **"Reachable data rather than a hypothetical" is not
  supported:** **0 of 9,726,805** `stockrecord` rows on `dev_wh01_om1` have a NULL `itemdata` (measured
  2026-09-22; one tenant, one instant). Schema-nullable ≠ observed. The plan models the honest form two
  sections away, in §7.8's LEFT-vs-INNER row: *"on real data that set is empty (0 of 9,726,795), so the
  fixture must construct it."*

**Was it honest?** Partly, and that is worth crediting: the javadoc says outright that it does not protect
the guard and refuses to invent a kill. Under the repo's own standard — *reporting an unkillable mutant
beats faking a kill* — that instinct is correct. It is only the premise it rests on that is false, and a
disclosed vacuous test is still a vacuous test.

**Should the guard have been removed instead?** **No — on two independent grounds.** (1) It would deviate
from §3.7, which quotes the two-guard form verbatim, and from §5.2 P4 checkbox 1, which says *"per §3.7"*.
(2) Per A1/A2 the guard is genuinely defensive: without it, the predicate is `item_nr IS NULL`, and the
only thing standing between that and a fabricated product name is a `NOT NULL` on a different table.
Removing it trades a real defence for the removal of a test problem that one line fixes.

**Verdict on B:** keep the test, keep the guard, add
`verify(itemdataRepository, never()).findByClientIdAndItemNr(any(), any());`, and rewrite the javadoc —
its "does NOT protect the guard" paragraph becomes false the moment that line lands, and its
"reachable data" sentence should carry the measured 0-of-9,726,805 the way §7.8 does.

---

## C. Code in the commit that no plan item asked for

Only two items, and neither is scope creep of substance. The diff is **2 files, +153, −0** — no
production file outside `StockrecordService`, no new class, no config, no SQL.

| Item | Judgement |
|---|---|
| `detailsStillReturnWhenSkuDoesNotResolve` — a third test, beyond the plan's two | **Justified, keep.** It kills the `orElseThrow` mistake, which is the specific error §3.7 spends a paragraph warning against, and the floor requires a kill per new assertion. Not plan-mandated, but squarely inside the floor. |
| `detailsOmitItemNameWhenSkuIsNull` — a fourth test | **Keep, but fix per §B.** Currently carries no kill. |
| 16 lines of comment for 4 lines of code | **Not a finding.** Consistent with the density of the surrounding P1–P3 work on this ticket. ⚠ One factual line to fix while §A is being corrected: *"a null clientId would make the lookup ambiguous"* — `stockrecord.client_id` is `NOT NULL` (`V2.2.00__base_v2_schema.sql`, confirmed on `dev_wh01_om1`), so that guard is inherited from the pre-existing client block rather than load-bearing here. |
| A "36 tests" figure in the `detailsOmitItemNameWhenSkuIsNull` javadoc | **Minor, fix in passing.** The class holds **37**; the commit message says 37 in one place and the javadoc says 36. |

**One latent note, plan-level not implementer-level (§7.5 row 6):** §3.7 routes the lookup through the
**repository**, bypassing `ItemdataService.findByClientIdAndItemNr` (`ItemdataService.java:51-55`), which
is `@Cacheable` *and* **trims** its argument (`itemNr == null ? null : itemNr.trim()`, `:55`).
`Itemdata.setItemNr` trims on write (`Itemdata.java:105`), so stored `item_nr` is always trimmed, while
`stockrecord.itemdata` is a free-form string that is not. A whitespace-padded `stockrecord.itemdata` would
therefore resolve through the service path and **fail** to resolve through the repository path — a silently
missing SKU Name. **Currently zero impact:** 0 untrimmed values on either side on `dev_wh01_om1`
(`itemdata <> btrim(itemdata)` → 0 of 9,726,805; `item_nr <> btrim(item_nr)` → 0 of 8,807; measured
2026-09-22, one tenant, one instant). Recording it because it is invisible from the diff and the plan chose
the uncached, untrimmed path deliberately. No action required for P4.

---

## D. What I could not verify without executing

Stated explicitly, per the constraint on this lane:

1. **That the three mutations were actually run.** No `target/pit-reports` exists; §7.8 prescribes PIT
   scoped to `StockrecordService`. I verified the *unconditional-put* kill is structurally sound by
   inspecting the assertion form, and I verified the *guard* mutant's survival is real by deriving the
   Mockito default that causes it — but the runs themselves are attested only by the commit message.
2. **That `detailsCarryItemNameWhenSkuResolves` failed first.** The commit says it "failed before this
   commit", which is structurally certain (the key cannot exist without the production block), but there
   is no red-run artefact on disk.
3. **The failsafe lane.** Not run here. The commit's reasoning that it has nothing to say about this phase
   (no SQL, no migration, no SDR surface, no authz, no `@Transactional`) is consistent with the diff I
   read, and I found nothing contradicting it.
4. **Anything requiring a compile.** The `never()` line proposed in §A3 is argued from the existing
   imports and 160 sibling usages, not from a compile.

---

## Verdict

**PASS on conformance.** All three §5.2 P4 checkboxes, both §7.3 rows, every applicable §7.5 row and both
clauses of AC-3's popup half are built. The production change is token-identical to §3.7's quoted code.
Nothing of substance was built that no plan item asked for, and the one plan-required mutation was killed
by the prescribed test with the prescribed assertion form.

**Two corrections required before the PR** (neither is a conformance gap):

- **§A — the false "UNKILLABLE" finding.** The mechanism is wrong (a derived query binds a null
  `SIMPLE_PROPERTY` to `IS NULL`, not to "matches nothing"), the conclusion holds only because
  `itemdata.item_nr` is `NOT NULL`, and the mutant is killable with one `verify(…, never())` line. Correct
  the commit message and the javadoc; do **not** remove the guard.
- **§B — `detailsOmitItemNameWhenSkuIsNull` currently grades nothing.** Add the `never()` assertion,
  rewrite the javadoc, and replace "reachable data rather than a hypothetical" with the measured
  0-of-9,726,805.

Minor, fix in passing: the "36 tests" figure, and the "a null clientId would make the lookup ambiguous"
comment (`stockrecord.client_id` is `NOT NULL`).

Not owed by P4, flagged for the executor: the plan document has no `§9D — Implementation status — P4`
section, where P1/P2/P3 each have one.
