# SBDEV-3410 P4 — code review

**Commit:** `0391cfb2` · branch `feature/SBDEV-3410-p4-stock-record-details-item-name` off `origin/develop` @ `3214a9c3`
**Worktree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410-p4`
**Diff:** 2 files, +153 / −0 · `StockrecordService.java` (+20), `StockrecordServiceUnitTest.java` (+133)
**Reviewer lane:** read-only. No `mvn` run (a sibling lane is live in this tree); commands to run are given inline.
**Date:** 2026-09-22

---

## Verdict

**The logic is correct and matches §3.7 byte-for-byte.** The four production lines are exactly the code the
plan quotes, `ifPresent` is the right choice, and the plan's one required mutation kill is achieved cleanly.

**Every finding below is a false or mis-cited claim in prose** — the pattern this ticket has produced in each
prior phase. Four of them (M1, M2, M3, L1) assert something about the *current* state of the code or the plan
that is not true as of this commit. One of them (M1) is also a real, user-visible interim defect.

**No High.** The lead's item 4 — the "unkillable mutant" claim — is **independently confirmed correct**
against both dev and prd schemas. No required kill was skipped.

| # | Severity | Finding |
|---|---|---|
| M1 | **Medium** | `'itemName' → 'SKU Name'` does **not** exist in `:field-names`. The test says "already declare"; P6 owns adding it. Between P4 and P6 merging, the popup row is labelled **`ItemName`** |
| M2 | **Medium** | `detailsOmitItemNameWhenSkuIsNull`'s "behaviourally invisible to **any** unit test" is false — `verify(…, never())` discriminates, and that idiom is already used 30 lines above in the same nested class |
| M3 | **Medium** | "§5.2 P4's third mutation" / "one of the three the plan requires" — the plan requires **one** mutation for `itemName`, not three. The other two are the author's own (good) additions, mis-attributed to the plan |
| L1 | Low | Both `lenient()` stubs **are used** now that P4 has landed. Their stated justification describes a state this commit ended. Removing `lenient()` also turns them into an argument pin |
| L2 | Low | Javadoc says "all **36** tests green"; the commit says 37. The class has 37 (`33 → 37`). 36 is wrong |
| L3 | Low | AC-3's second clause ("the row still appears **in the table**") is a P1 / `LEFT JOIN` criterion, quoted here as if it graded the popup |
| L4 | Low | §7.8 mandates **PIT scoped to the class**; the commit reports hand-edited mutants + full surefire. Run PIT and cite its output |
| I1 | Info | `s.getClientId() != null` is re-evaluated three lines after the block that already tests it |
| I2 | Info | "a null clientId would make the lookup ambiguous" is false, and contradicts the test javadoc's verdict on the sibling guard. Both guards are query-avoidance, not correctness |

---

## Item 4 — the "unkillable mutant". VERIFIED CORRECT. No High.

The commit claims that dropping `s.getItemdata() != null` leaves every test green and is behaviourally
invisible, because the finder would be called with a null `itemNr` and match nothing. I verified this
independently rather than taking it on the reasoning given.

**The finder is a derived query, not `@Query`** —
`src/main/java/net/aim_ai/wms/repo/jpa/ItemdataRepository.java:28`:

```java
@RestResource(path = "findByClientIdAndItemNr", rel = "findByClientIdAndItemNr")
Optional<Itemdata> findByClientIdAndItemNr(@Param("clientId") Long clientId, @Param("itemNr") String itemNr);
```

Spring Data JPA's handling of a null bind on a `SIMPLE_PROPERTY` part is the usual source of doubt here —
it may render `item_nr = ?` (never true) or translate to `item_nr IS NULL`. **The verdict does not depend on
which**, because the column is `NOT NULL`:

| Instrument | `dev_wh01_om1` | `wh01_hydra_v2` (PRD) |
|---|---|---|
| `itemdata.item_nr` nullable | **NO** | **NO** |
| rows with `item_nr IS NULL` | 0 (of 8,807) | 0 |
| `UNIQUE (client_id, item_nr)` present | yes — `uk3l3dgof3l6mc1dl7s3lmida65` | yes |
| duplicate `(client_id, item_nr)` pairs | — | 0 |
| duplicate `item_nr` alone | **71** | — |
| `stockrecord.itemdata` nullable | YES | YES |
| `stockrecord.itemdata IS NULL` rows | 0 (of 9,726,805) | 0 |
| `stockrecord.client_id` nullable | NO | NO |

`= NULL` matches nothing; `IS NULL` against a `NOT NULL` column also matches nothing. The unique constraint
is live on both, so the `Optional` return cannot raise `IncorrectResultSizeDataAccessException` on the
duplicate-`item_nr` data either. In the unit lane, an unstubbed `Optional`-returning method yields
`Optional.empty()` under `ReturnsEmptyValues`, not `null`, so there is no NPE. **The claim holds, and the
"71 duplicate keys on dev_wh01_om1" figure in the commit message is accurate.**

Two things the commit does not say that are worth one line in the comment:

- The safety rests on a **schema invariant** (`item_nr NOT NULL`) that nothing in this repo pins. If it ever
  became nullable, dropping the guard would fabricate a name from an unrelated row.
- The guard also avoids a round trip on every null-SKU row. Measured population of those: **0 on dev across
  9.7M rows, 0 on prd**. So the optimisation is real but currently exercises nothing — which slightly
  overstates `detailsOmitItemNameWhenSkuIsNull`'s "reachable data rather than a hypothetical". Nullable by
  schema, yes; observed, zero.

---

## M1 — Medium · `'itemName' → 'SKU Name'` does not exist yet, and the popup will say "ItemName"

`detailsCarryItemNameWhenSkuResolves` asserts with this description:

> *"the popup's field-names **already declare** 'itemName' -> 'SKU Name'; this is the value that labels"*

and the production comment repeats the label:

> *"a null-valued key renders an empty **'SKU Name'**"*

**Neither is true today.** `components/reports/stockUnitRecord.vue` on `origin/develop` passes a 16-entry
`:field-names` map to `<full-details>` and `itemName` is not in it:

```
'activitycode' 'fromunitload' 'tostoragelocation' 'unitloadtype' 'tounitload' 'itemdata'
'amountstock' 'ordernumber' 'entityLock' 'reservedamountstock' 'reservedamountchange'
'tostockunitidentity' 'fromstockunitidentity' 'fromstoragelocation' 'clientName' 'clientNumber'
```

A repo-wide `git grep -n "itemName" origin/develop` across `*.vue` / `*.js` finds no `'itemName': 'SKU Name'`
mapping anywhere, and no branch carries one (`git branch -r | grep -i 3410` → empty).

The plan is consistent with reality, not with the comment — **§5.2 P6** owns it:

> `stockUnitRecord.vue`: … **`'itemName': 'SKU Name'` in `:field-names`** …

And §3.7's own wording is future-facing: *"the `:field-names` entry … **labels it when present**"*.

**The functional consequence.** `components/common/fullDetails.vue` falls back when the key is unmapped:

```html
<span v-if="fieldNames[name]">{{ fieldNames[name] }}</span>
<span v-else>{{ name.charAt(0).toUpperCase() + name.slice(1) }}</span>
```

So from the moment P4 merges to `develop` until P6 merges, the Stock Unit Record popup shows a row labelled
**`ItemName`**. That is a genuine user-visible interim state, not just a doc nit. Per
`wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway`, merging P4 deploys it to dev immediately.

**Fix (all three are cheap):**
1. Change "already declare" → "will declare — §5.2 **P6** adds `'itemName': 'SKU Name'` to
   `stockUnitRecord.vue`'s `:field-names`; until it lands, `fullDetails.vue` falls back to `ItemName`."
2. Same correction in the production comment's "renders an empty 'SKU Name'".
3. Flag the P4-before-P6 window on the ticket, or sequence P6 ahead of / with P4's merge.

## M2 — Medium · "behaviourally invisible to any unit test" is false, and the kill is available

`detailsOmitItemNameWhenSkuIsNull`'s javadoc:

> *"its presence is **behaviourally invisible to any unit test**. Recorded rather than papered over with an
> assertion that cannot discriminate … inventing a kill for it would be worse than reporting it."*

The reasoning behind it is sound for a **state** assertion — the returned map is identical with and without
the guard, so no `assertThat(details)` form can tell them apart. But "any unit test" is a completeness word,
and an **interaction** assertion discriminates exactly:

```java
verify(itemdataRepository, never()).findByClientIdAndItemNr(any(), any());
```

With the guard: zero invocations → green. Without it: one invocation with `(1L, null)` → red, naming the
call. Both parameters are reference types (`Long`, `String`), so the
`mockito-never-any-primitive-unboxing-trap` does not apply here.

**This is not a hypothetical idiom** — it is already in use thirty lines above, in the same nested class, for
the structurally identical sibling guard (`StockrecordServiceUnitTest`,
`shouldReturnStockRecordDetailsWithoutClientWhenClientIdIsNull`):

```java
verify(clientRepository, never()).findById(any());
```

That existing test is the direct precedent the new one should have copied, and its presence makes the
javadoc's claim falsifiable by reading the same screen.

To be precise about what the added line buys: it does **not** convert the mutant into a correctness kill —
per item 4 above, the guard genuinely has no effect on the returned map. It pins the guard's actual
contract, *no round trip when there is nothing to look up*, which is the only thing the guard promises. That
is a legitimate assertion, not an invented one.

**Fix:** add the `verify(…, never())` to `detailsOmitItemNameWhenSkuIsNull`, and rewrite the javadoc's ⚠
paragraph to say the guard is invisible to any **state** assertion on the returned map, killable only by an
interaction assertion, which the test now carries. Amend the commit message's third mutation row accordingly
(it currently reads `SURVIVES`).

## M3 — Medium · "the three mutations the plan requires" — the plan requires one

The commit message says:

> *"MUTATIONS — and **one of the three the plan requires** is UNKILLABLE"*

and the javadoc:

> *"**§5.2 P4's third mutation** is unkillable at this level"*

**§5.2 P4 prescribes one mutation check**, and it is the `put(null)` one:

> - [ ] Mutation-check: swap `ifPresent` for an unconditional `details.put("itemName", null)` and confirm the
>   absent-key assertion goes red …

**§7.8 carries exactly one `itemName` row**, the same mutant, attributed to the same test
(`detailsOmitItemNameWhenSkuDoesNotResolve`). There is no second or third `itemName` mutation anywhere in the
plan — I read §5.2 P4, §7.8 in full, and §7.3's two `StockrecordServiceUnitTest` rows.

The `orElseThrow` and drop-the-guard mutants are the author's own additions, and they are the right instinct
— §7.8's standard is *"every new assertion, with an attributable kill"*, and adding mutants for new
assertions is what that asks for. The problem is purely the attribution: as written, a reader concludes the
plan left a requirement undischarged, when in fact **the plan's single required kill is achieved cleanly and
one-to-one**.

**Fix:** re-word to "the plan requires one mutation (§5.2 P4 / §7.8); this commit adds two more of its own,
and the third of the three survives …". Do not delete the survivor report — reporting it is correct
behaviour, and per M2 it becomes killable anyway.

## L1 — Low · the `lenient()` stubs are no longer necessary, and their comment is now false

Both new empty-Optional stubs carry, verbatim:

> *"lenient: **until P4 lands, the production code never calls this finder**, and STRICT_STUBS would raise
> UnnecessaryStubbing BEFORE the assertion runs …"*

P4 landed in this commit. In both tests `savedStockrecord` carries `clientId = 1L` and
`itemdata = "ITEM-001"`, so the new block calls `findByClientIdAndItemNr(1L, "ITEM-001")` and **the stub is
used**. `BaseUnitTest` is `@ExtendWith(MockitoExtension.class)` with default `STRICT_STUBS`, so the stubs
would pass strict today.

This is the `green-tests-that-prove-nothing` shape: a `lenient()` that is no longer needed is not harmless,
it is a suppressed instrument. Strict stubs here pin that the production code **invokes this finder with
exactly `(1L, "ITEM-001")`** — which catches an argument swap (`findByClientIdAndItemNr(itemdata, clientId)`
would not compile, but a future refactor to a `(String, Long)` finder would) and catches the block being
guarded out entirely. With `lenient()` those mutants fall only to
`detailsCarryItemNameWhenSkuResolves`.

Also note the citation `(Same idiom as this class's existing lenient() at :102.)` — line 102 is
`lenient().when(itemdataRepository.findById(1L))…` inside `setupCommonMocks()`, so the reference resolves
correctly today. It is a bare line number in a file that phases P5/P6 may not touch but future work will;
prefer naming `setupCommonMocks()` over `:102`.

**Fix:** drop `lenient()` from both new stubs, delete the obsolete justification, and replace it with one
line saying the strict stub is what pins the finder's arguments.

## L2 — Low · 36 vs 37

`detailsOmitItemNameWhenSkuIsNull`'s javadoc: *"removing that guard leaves **all 36 tests** green"*.
The commit message: *"**All 37** stay green"*.

Measured: `grep -c '@Test'` → **33** on `origin/develop`, **37** at HEAD. 37 is right; 36 is wrong. A
hand-written count in a mutation report is the kind of number that decides whether anyone re-runs the check —
per `a-zero-scan-needs-a-positive-control`, an off-by-one in the instrument's own output is a reason to
distrust the result. Reconcile to 37 (L4 replaces both with PIT output anyway).

## L3 — Low · AC-3's second clause is a table criterion, quoted as a popup criterion

The production comment:

> *"which is the opposite of AC-3's second clause (**"the row still appears"**)"*

AC-3 in full reads *"…and the row still appears **in the table**"*, and the plan says immediately why: *"that
second clause is what makes the **`LEFT`-not-`INNER`** decision an acceptance criterion rather than an
implementation detail."* §7.8 routes it to `StockrecordViewSchemaIT.unresolvedSkuRowSurvivesWithNullItemName`
— a **P1** concern about the view's join, not a P4 concern about the popup.

The design conclusion ("don't throw") is right and §3.7 states it directly without needing AC-3. The
citation is simply pointed at the wrong clause. Cite §3.7 instead, or re-word to "the same tolerance AC-3
requires of the table".

`detailsStillReturnWhenSkuDoesNotResolve`'s javadoc carries the same misquote
("AC-3, second clause continued: **the row must still appear at all**").

## L4 — Low · §7.8 mandates PIT; the evidence is hand-edited mutants

§7.8 opens with:

> *"Use **PIT scoped to the changed class**, per the pom's own instruction (`parseSurefireConfig MUST stay
> false`; recipe at `sbdocs/9-System/mutation-testing-recipe.md`) — **not a hand-rolled harness, which has
> lied here before**."*

The commit reports three hand-edited mutants against a full surefire run. That is a stronger instrument
*per mutant* than PIT, and it is the right method for the two mutants PIT cannot express. But the plan names
PIT, PIT's report is the citable artifact, and PIT would independently confirm or refute the survivor — which
matters precisely because the survivor is the contested claim.

Commands (not run in this lane — concurrent maven in one worktree produces false reds):

```bash
cd /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410-p4
mvn test-compile
mvn org.pitest:pitest-maven:mutationCoverage \
    -DtargetClasses=net.aim_ai.wms.service.StockrecordService \
    -DtargetTests=net.aim_ai.wms.unit.service.StockrecordServiceUnitTest
```

Expect the `removed call to …ifPresent` / `removed conditional` mutants on the new lines to be **KILLED**
once M2's `verify(…, never())` is added; before it, expect one `SURVIVED` on the `s.getItemdata() != null`
conditional, which is the claim under review.

## I1 — Info · duplicated null check

The new block re-tests `s.getClientId() != null` three lines after the block that already tests it:

```java
if (s.getClientId() != null) {
    Client client = clientRepository.findById(s.getClientId()).orElseThrow(…);
    details.put("clientNumber", client.getClNr());
    details.put("clientName", client.getName());
}
// … 15 lines of comment …
if (s.getClientId() != null && s.getItemdata() != null) {
```

Folding the `itemName` lookup into the existing `if` removes the duplication. The counter-argument is that
the two resolutions are independent concerns and the separate block keeps them so — which is defensible, and
the plan quotes the separate form. **Not a required change**; noted only so the next reader does not "fix"
it in the opposite direction.

Placement relative to the `reservedamount*` puts is irrelevant — `details` is a `HashMap`.

## I2 — Info · "a null clientId would make the lookup ambiguous" is false, and contradicts M2's javadoc

The production comment's closing paragraph:

> *"**Both guards are load-bearing**: the finder keys on the PAIR because item_nr alone is not unique (71
> duplicate keys on dev_wh01_om1), so **a null clientId would make the lookup ambiguous**."*

Three problems:

1. `stockrecord.client_id` is **`NOT NULL`** on both dev and prd (table above), so the null-clientId case is
   unreachable through this path.
2. Even if it were reachable, a null bind on `client_id` produces `client_id = NULL` or `client_id IS NULL`,
   both of which match **zero** rows against a `NOT NULL` column — no rows is not ambiguity. Ambiguity would
   require a single-argument `findByItemNr`, which is not what is called. What makes the lookup unambiguous
   is the **pair-keyed finder** plus `UNIQUE (client_id, item_nr)`, neither of which is the guard.
3. It contradicts the test javadoc in the same commit, which calls the sibling guard "behaviourally
   invisible". Both guards are the same thing: **query avoidance**, not correctness.

The 71-duplicate figure and the pair-keying rationale are correct and worth keeping — they justify the
*finder*. Re-word so they stop being offered as justification for the *guards*:

> Both guards are query-avoidance, not correctness: `client_id` is NOT NULL and `itemdata.item_nr` is NOT
> NULL, so a null on either side matches nothing regardless. What makes the lookup unambiguous is the
> pair-keyed finder over `UNIQUE (client_id, item_nr)` — `item_nr` alone is not unique (71 duplicate keys on
> `dev_wh01_om1`).

---

## Answers to the six questions asked

**1 · Is `ifPresent` right, and is the contrast with the sibling `orElseThrow` defensible?**
Yes, and yes. `stockrecord.itemdata` is a plain `varchar` with no FK — confirmed, no FK constraint on the
column and the P1 view uses `LEFT JOIN` for the same reason — so an unresolvable value is data, not a broken
reference. `orElseThrow` would turn it into an `EntityNotFoundException` and the popup would not open. The
`Client` contrast is defensible because `stockrecord.client_id` **is** a real FK to a NOT NULL column, so a
miss there genuinely is a broken reference.

No caller needs to distinguish absent from empty-string. `getStockRecordDetails` has exactly one consumer,
`GET /v3/stockrecord/stockRecordDetailsById/{id}`, and that endpoint has exactly one consumer,
`store/reports/stockUnit.js:98` feeding `stockUnitRecord.vue`'s `<full-details>`. `fullDetails.vue` does
`v-for="(value, name) in details"`, so absent → no row, `null` → a row with a blank value. The absent/null
distinction the tests grade is therefore real and correctly chosen. (`itemdata.name` is `NOT NULL` in
`V2.2.00`, so an empty product name would need an empty string, which would render identically to a
null-valued key — unavoidable and harmless.)
The `:field-names` half of the answer is M1: the label is not there yet.

**2 · Can any of the four tests pass vacuously?**

| Test | Red before the fix? | Real value |
|---|---|---|
| `detailsCarryItemNameWhenSkuResolves` | **Yes** — `AssertionError` on `containsEntry`. (STRICT_STUBS' `UnnecessaryStubbingException` is suppressed when the test has already failed, so it fails cleanly on the assertion.) The commit's "failed before this commit" is accurate | The gate. Real |
| `detailsOmitItemNameWhenSkuDoesNotResolve` | No — vacuous before | **Real**: carries the plan's one required kill (`put("itemName", null)`), and `doesNotContainKey` is the only form that catches it |
| `detailsStillReturnWhenSkuDoesNotResolve` | No | **Real but largely redundant** — see below |
| `detailsOmitItemNameWhenSkuIsNull` | No | **Currently near-decoration** — see below |

*Does `detailsStillReturnWhenSkuDoesNotResolve` distinguish `ifPresent` from `orElseThrow`?* **Yes, and for
the right reason.** Its stub returns `Optional.empty()`, so under an `orElseThrow` mutant the call throws out
of the service and the test errors. It is not a false positive.

But it is not a *narrow* discriminator: `detailsOmitItemNameWhenSkuDoesNotResolve` uses the same fixture and
the same path, so it errors under that mutant too — and so do the two pre-existing tests, because Mockito
defaults their unstubbed finder to `Optional.empty()`. That is the "FOUR tests error, not one" the commit
reports honestly. Its *unique* contribution over its sibling is the four surviving keys
(`id`/`itemdata`/`clientName`/`operator`). Keep it — the keys are worth pinning — but it is defence in
depth, not the kill, and the commit does not overclaim it.

*`detailsOmitItemNameWhenSkuIsNull`* is the one that is currently decoration. The only thing it pins is "no
NPE on a null SKU", and nothing puts that at risk: with the guard the finder is never reached, and without it
Mockito returns `Optional.empty()` rather than `null`. **M2's `verify(…, never())` is what turns it into a
real test.**

**3 · Are the `lenient()` stubs still needed?** No — see **L1**. Both are used under the landed feature; the
`lenient()` and its justification are both stale, and removing them strengthens the tests.

**4 · The unkillable mutant.** Verified independently and **confirmed correct** — see the section above. No
required kill was skipped, so no High. Two caveats added there (the unpinned schema invariant; the
optimisation's measured population is zero).

**5 · Is the "invisible to any unit test" javadoc true?** **No** — see **M2**. A `verify(…, never())`
discriminates, and the idiom is already in the same nested class thirty lines above. The javadoc is a false
completeness claim and the test should be strengthened.

**6 · Design contradictions and commit overstatement.**
No design contradiction: the production code is §3.7 verbatim, `ifPresent` is what the plan prescribes, and
the `doesNotContainKey` requirement from AC-3 / §7.3 / §7.8 is honoured exactly.
Overstatements, in descending order: **M3** ("the three the plan requires" — it requires one), **M1** ("the
popup's field-names *already* declare" — they do not), **M2** ("invisible to *any* unit test"), **L2** (36 vs
37), **L3** (AC-3's table clause quoted as a popup clause), **I2** ("both guards are load-bearing" / "a null
clientId would make the lookup ambiguous").
The commit's *understatements* are worth crediting: it flags that two tests could not have failed first, that
the `orElseThrow` kill is four-to-one rather than one-to-one, and that a mutant survived. That is the right
disclosure habit; the findings above are about accuracy, not candour.

---

## Required before merge

1. **M1** — correct "already declare" in the test description and the production comment; decide and record
   whether the `ItemName` label window between P4 and P6 is acceptable.
2. **M2** — add `verify(itemdataRepository, never()).findByClientIdAndItemNr(any(), any())` to
   `detailsOmitItemNameWhenSkuIsNull`; rewrite the ⚠ paragraph; update the commit message's mutation table.
3. **M3** — re-attribute the mutation set: one required by §5.2 P4 / §7.8, two added by this commit.
4. **L1** — drop both `lenient()`s and their obsolete justification.
5. **L2** — 36 → 37.
6. **L3** — re-point the AC-3 citation (two javadocs + the production comment).
7. **L4** — run the PIT command above and cite its output in place of the hand-written counts.
8. **I2** — re-word the "both guards are load-bearing" paragraph per the replacement text given.

I1 is optional and deliberately left to the author.

After the edits, the full surefire lane must be re-run and compared against the known baseline — see
`wms2-test-suite-baseline-and-h2-verdict`; do not reuse this commit's 6754/0/0 figure, since M2 and L1
change the test bodies.
