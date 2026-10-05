# SBDEV-3410 P4 — re-review of the fix commit `9033f28b`

**Subject:** `9033f28b` "code-review-lane fixes — the 'SKU Name' label does not exist yet"
**Parents in scope:** `5ede17ab` (prior fix), `0391cfb2` (original P4), base `3214a9c3`
**Worktree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410-p4` (branch `feature/SBDEV-3410-p4-stock-record-details-item-name`, ahead 3)
**Lane:** adversarial re-review. Read-only on source; every measurement below was run by me, not read off the commit.
**Date:** 2026-09-22

> **Tree hygiene.** Three probes required temporarily editing a tracked file. Each was preceded by a copy to
> the scratchpad and followed by a restore + `git status --short`. Final state: `git status --short` empty,
> `HEAD` = `9033f28b`, branch `...origin/develop [ahead 3]`. No sibling worktree was read or built in.

---

## Findings

| # | Severity | Finding |
|---|---|---|
| **F1** | **Medium** | `stockrecord.client_id is NOT NULL (V2.2.00:620)` — **line 620 is `public.advice`, not `stockrecord`**. The claim is true; the citation points at a different table that happens to have a `client_id bigint NOT NULL` on that exact line, so the citation *appears* to verify. Real line: **2188** |
| **F2** | **Medium** | The new javadoc sentence *"which would ALSO cost AC-3's table clause"* is **false** and contradicts the paragraph directly above it. A P4 `orElseThrow` cannot cost the table clause — the table and the popup are different endpoints. The L3 fix introduced a fresh false claim in the javadoc whose purpose was to remove one |
| **F3** | **Medium** | The `target/pit-reports/mutations.xml` sitting in the worktree at commit time **does not reproduce from the committed code** and **contradicts the commit message's own attribution table**. The message is right about the committed code; the artifact is the lenient-control run, left last. Anyone re-deriving from the artifact (which is what "two instruments" tells them to do) concludes the message lied |
| **F4** | Low | "3 of 3 mutations on P4's lines KILLED, no survivors" is true of *PIT's* denominator, but PIT generates **zero** mutants for P4's lambda body — the `"itemName"` key literal and the `i.getName()` value source are unmutated by every default mutator. The clean 3/3 is partly an instrument blind spot, not only strong tests |
| **F5** | Low | "It buys nothing in MUTATION coverage" is true at the *score* level and false *per test*: measured, dropping `lenient()` turns `detailsOmitItemNameWhenSkuDoesNotResolve` from a killer of **0** L671 mutants into a killer of **both** |
| **F6** | Low | "errors **all three tests in this block**" — the nested class `GetStockRecordDetails` has **7** tests and the P4 sub-block has **4**. Exactly 3 error. The number is right, "this block" is not |
| **F7** | Low | `itemdata.name`'s `NOT NULL` (`V2.2.00:936`) is the **only** thing preventing the exact `details.put("itemName", null)` state this whole design exists to forbid. The comment documents `item_nr`'s `NOT NULL` across six lines and never mentions `name`'s. Nothing pins it |
| **F8** | Low | The promotion gate *"P6 must land before any promotion past dev"* exists **only inside a Java comment in a service method**. Nobody reads `StockrecordService.java:669` at promotion time; the plan's promotion gates live in §5.1 row 4 and §7 step 5 |
| **F9** | Low | "0 untrimmed values on either side of `dev_wh01_om1`" is a **dev-only** measurement, presented one paragraph after a claim that *does* carry its prd counterpart. Measured: prd `wh01_hydra_v2` has **1** untrimmed `itemdata.item_nr` (`'BONMFPN23 '`) |
| **F10** | Info | §7.7's manual row expects *"SKU Name alongside Shipper Name/Shipper Code"*. `details` is a `HashMap` (`StockrecordService.java:587`), so popup row order is hash order — adjacency is not a property the code can provide |
| **F11** | Info | The test javadoc says `0 of 9,726,805`; plan §7.8 line 1677 says `0 of 9,726,795` for the same population. 10 rows apart, unexplained |
| **F12** | Info | ~55 comment lines for 4 code lines, of which **three** ⚠ paragraphs are about what *earlier revisions of the comment* said. The file is accumulating a changelog of its own corrections |

**No High.** Stated explicitly rather than implied: I found nothing at High. The logic is §3.7 verbatim, the
guard is correct, null-handling is sound, there is no thread-safety or transactional surface, and the blast
radius is one endpoint with one consumer.

---

## Verification of the six claims

| Claim | Verdict |
|---|---|
| **1** — §0 row 29 → P6; `origin/develop` has no `itemName`; popup reads "ItemName" | **CONFIRMED** in full, including the literal string. Caveat F8 on where the gate is recorded |
| **2** — AC-3's second clause is a TABLE criterion, not a popup criterion | **CONFIRMED**; no over-correction — AC-3 gives P4 exactly the present/absent pair. But see **F2**: the javadoc then takes it back |
| **3** — `+ "X"` errors three tests; 37/37 on revert; PIT identical with `lenient()` restored | **CONFIRMED**, both halves independently re-measured. The three-lenient-vs-two objection does **not** invalidate it (see below). Caveats F5, F6 |
| **4** — 3 of 3 mutations on P4's lines KILLED, every killer attributable | **CONFIRMED on counts** (reproduced twice). **FALSIFIED as reproducible evidence** — see F3. Denominator blind spot — see F4 |
| **5** — PIT does not subsume the hand-edited `put("itemName", null)` mutant | **CONFIRMED**, and understated: PIT emits *no* mutant anywhere in that lambda |
| **6** — derived query → `IS NULL` binding; `itemdata.item_nr` NOT NULL; no overclaim | **CONFIRMED** — mechanism verified in spring-data-jpa **bytecode**, not from memory. `NOT NULL` verified on prd. No opposite-direction overclaim. But see **F1** for the neighbouring citation |

---

## F1 — Medium. `V2.2.00:620` is `public.advice`, not `public.stockrecord`

`StockrecordService.java:668`:

```java
// The clientId guard is not about ambiguity — stockrecord.client_id is NOT NULL (V2.2.00:620).
```

```console
$ awk -v target=620 'NR<=target && /^CREATE TABLE/{last=NR": "$0} NR==target{print "enclosing:",last; print "line:",$0}' \
    src/main/resources/db/migration/V2.2.00__base_v2_schema.sql
enclosing: 603: CREATE TABLE public.advice (
line:     client_id bigint NOT NULL,

$ grep -n "^CREATE TABLE public.stockrecord" -A 40 src/main/resources/db/migration/V2.2.00__base_v2_schema.sql \
    | grep -n "client_id\|itemdata\|CREATE TABLE"
1:2166:CREATE TABLE public.stockrecord (
14:2179-    itemdata character varying(255),
23:2188-    client_id bigint NOT NULL,
```

The **assertion is true** — `stockrecord.client_id` *is* `NOT NULL`, at line **2188**. What is wrong is the
pointer, and this is the worst shape a wrong citation can take: line 620 is `advice.client_id bigint NOT NULL`,
so a reviewer who follows the citation reads a line that says exactly what the comment promised and marks the
claim verified. It confirms without being evidence.

This is the same failure class the lane exists for, one level down: not a false claim, a **false-but-confirming
citation**. It is also the only unverified-by-construction citation left in the block — `V2.2.00:937` checks
out (`enclosing: 927: CREATE TABLE public.itemdata`, line 937 = `item_nr character varying(255) NOT NULL`).

**Fix** — one token:

```java
// The clientId guard is not about ambiguity — stockrecord.client_id is NOT NULL (V2.2.00:2188).
```

---

## F2 — Medium. The L3 fix planted a new false claim in the same javadoc

`StockrecordServiceUnitTest.java`, `detailsStillReturnWhenSkuDoesNotResolve`'s javadoc, as committed:

```java
 * <p>⚠ <b>Not an AC-3 citation.</b> … AC-3's second clause is "the row still appears <b>in the
 * table</b>" … it grades <b>P1's view</b>. AC-3 gives P4 only the present/absent pair …
 …
 * product name into a popup that will not open — which would ALSO cost AC-3's table clause,
 * but by a different route and in a different phase's code.
```

The grammatical subject of *"which would ALSO cost"* is P4's `EntityNotFoundException`. That is false, and it
negates the paragraph five lines above it in the same javadoc.

The table and the popup are **different calls**:

```console
$ git -C v2/wms2-web-ui show origin/develop:components/reports/stockUnitRecord.vue | grep -n "details ="
321:      this.details = await this.$store.dispatch('reports/stockUnit/getStockUnitDetail', {id: item.id})

$ git -C v2/wms2-web-ui show origin/develop:store/reports/stockUnit.js | sed -n '96,99p'
  getStockUnitDetail(context, data) {
      return this.$axios.$get(`/stockrecord/stockRecordDetailsById/${data.id}`)
```

`getStockUnitDetail` fires from the **eye-icon click handler**, against
`StockRecordController.stockRecordDetailsById` — the only caller of `getStockRecordDetails` in `src/main`
(`grep -rn "getStockRecordDetails" src/main --include="*.java"` → controller:40 + the definition). The table's
rows come from `/api/stockrecordView`, which P2 creates (plan §5.1 row 4). A 500 from the details endpoint
leaves the already-rendered table row untouched. P4 **cannot** cost AC-3's table clause by any route.

There is a charitable reading — "an intolerance of unresolved SKUs would also cost the table clause, but that
would be P1's `INNER JOIN`" — and that reading is true. As written it is not what the sentence says, and the
sentence is the one the commit added to stop a mis-citation.

**Fix** — delete the clause, or make the subject explicit:

```java
 * product name into a popup that will not open. (The table clause is costed by a different
 * mechanism entirely — an INNER JOIN in P1's view — not by anything this method can do: the
 * table and the popup are separate endpoints, and a 500 here leaves the rendered row alone.)
```

---

## F3 — Medium. The PIT artifact on disk grades a different code state than the commit message cites

The commit's L4 block presents an attribution table as its evidence. The `mutations.xml` in the worktree —
timestamped `07:38`, three minutes before the `07:41` commit — says something else.

```console
AUTHOR on-disk (target/pit-reports/mutations.xml, 07:38)   total=209 {KILLED:127, NO_COVERAGE:29, SURVIVED:53}
     L671 KILLED NegateConditionalsMutator   killer=['detailsCarryItemNameWhenSkuResolves']
     L671 KILLED NegateConditionalsMutator   killer=['detailsOmitItemNameWhenSkuIsNull']
     L673 KILLED VoidMethodCallMutator       killer=['detailsCarryItemNameWhenSkuResolves']

MINE, STRICT run #1 (committed code)                       total=209 {KILLED:127, NO_COVERAGE:29, SURVIVED:53}
     L671 KILLED NegateConditionalsMutator   killer=['detailsOmitItemNameWhenSkuDoesNotResolve']
     L671 KILLED NegateConditionalsMutator   killer=['detailsOmitItemNameWhenSkuDoesNotResolve']
     L673 KILLED VoidMethodCallMutator       killer=['detailsCarryItemNameWhenSkuResolves']

MINE, STRICT run #2 (committed code)                       identical to run #1 on L671/L673

MINE, LENIENT control (all three stubs lenient, RECOMPILED) total=209 {KILLED:127, NO_COVERAGE:29, SURVIVED:53}
     L671 KILLED NegateConditionalsMutator   killer=['detailsCarryItemNameWhenSkuResolves']
     L671 KILLED NegateConditionalsMutator   killer=['detailsCarryItemNameWhenSkuResolves']
     L673 KILLED VoidMethodCallMutator       killer=['detailsCarryItemNameWhenSkuResolves']
```

Two independent runs of the committed code both attribute both L671 mutants to
`detailsOmitItemNameWhenSkuDoesNotResolve`. **The commit message's table is correct for the committed code.**
The on-disk artifact names neither of those killers, and names one (`detailsOmitItemNameWhenSkuIsNull`) I never
reproduced under strict — it carries the lenient control's signature, not the committed code's. PIT overwrites
`mutations.xml`, and the lenient re-run was evidently the last one executed.

Why this is Medium and not Info: §7.8's whole point is *"not a hand-rolled harness, which has lied here
before"* — the discipline is to keep the instrument's own output. The output that was kept grades the control,
not the subject. The next person who does the right thing (re-derive from the artifact) finds it contradicting
the commit message and has no way to tell which is stale without re-running PIT twice, as I did.

Two caveats I will not overstate:

- PIT reports **one** killing test per mutant, chosen by execution order, and that order is not stable. My two
  strict runs disagreed on the killer of the *unrelated* L678 mutant
  (`shouldReturnCompleteStockRecordDetailsWithClient` vs `shouldIncludeTimestampFieldsInDetails`). So "every
  killer attributable" overstates what the instrument reports — PIT names *a* killer, not *the* killer set.
- Because of that, I cannot *prove* the artifact came from the lenient build; I can prove it does not reproduce
  from the committed code in two attempts, and that its signature matches the lenient control's exactly.

**Fix** — either re-run PIT on the committed tree as the final action so the retained artifact matches the
message, or add one line to the message: *"`target/pit-reports/mutations.xml` currently holds the lenient
control run, not this table's run."*

> **Instrument trap worth recording separately.** My first lenient run was invalid and looked fine:
> `mvn org.pitest:pitest-maven:mutationCoverage` invoked as a bare goal **does not run `test-compile`**, so PIT
> silently mutated against the previously-built `target/test-classes` — the strict ones. It completed in 22s
> instead of 55s, reported `Generated 209 mutations Killed 127`, `BUILD SUCCESS`, and produced a result
> identical to the strict run, which is exactly what "identical verdicts" is supposed to look like. The pom's
> own comment (`pom.xml:544`) and §7.8 both prescribe `mvn test-compile` first, for this reason. Re-running
> with the recompile is what produced the real lenient signature above.

---

## F4 — Low. PIT emits no mutants at all for P4's lambda, so "3 of 3, no survivors" has a blind spot

The P4 code is four lines (`StockrecordService.java:671-674`). PIT's complete output for them:

```
L671 KILLED NegateConditionalsMutator   (x2 — one per conjunct)
L673 KILLED VoidMethodCallMutator       removed call to java/util/Optional::ifPresent
```

Nothing for the lambda body `i -> details.put("itemName", i.getName())`. It is compiled to its own synthetic
method, and my scan over `mutatedMethod` catches those — `lambda$getStockRecordDetails$27` and `$28` (the two
pre-existing `orElseThrow` suppliers) both appear, as `NO_COVERAGE`. P4's lambda appears **not at all**,
because the defaults have nothing to mutate in it: `Map.put` and `Itemdata.getName` are both non-void (so
`VoidMethodCall` does not apply), `NonVoidMethodCall` is not in DEFAULTS, and the lambda returns void (so no
return mutator applies).

Consequence: PIT provides **no** evidence that the key literal `"itemName"` or the value source `i.getName()`
is pinned. Both *are* pinned — by `containsEntry("itemName", "Alpha Widget")` in
`detailsCarryItemNameWhenSkuResolves` — but by an assertion, not by a surviving-mutant argument. "3 of 3, no
survivors" reads as complete mutation coverage of the phase and is really complete coverage of the three
mutants this instrument can see here.

**Fix** — one sentence in the commit/comment: *"3 of 3 is PIT's denominator, not the code's: the defaults
generate no mutant anywhere in the `ifPresent` lambda, so the key literal and `i.getName()` are graded by
`containsEntry` alone."*

---

## F5 — Low. Strictness *does* buy mutation coverage, just not score

From F3's table, comparing the same two mutants across the strict and recompiled-lenient builds:

| | kills L671 mutant A | kills L671 mutant B |
|---|---|---|
| `detailsOmitItemNameWhenSkuDoesNotResolve` **lenient** | no | no |
| `detailsOmitItemNameWhenSkuDoesNotResolve` **strict** (committed) | **yes** | **yes** |

Mechanism: negating either conjunct skips the block, the strict stub then goes unused, and `STRICT_STUBS`
raises `UnnecessaryStubbing` — a kill the lenient build cannot produce. The score is unchanged (127/209 both
ways) only because `detailsCarryItemNameWhenSkuResolves` kills them anyway.

So the comment's *"It buys nothing in MUTATION coverage"* is right about the number and wrong about the
mechanism — and the sentence that follows it, *"Drop `lenient()` for the stale justification and the argument
pin, not for the mutants"*, remains the correct conclusion. Worth fixing because it is the kind of sentence the
next phase will quote.

**Fix:** *"It buys nothing in mutation SCORE — the three mutants are killed either way. It does add a
redundant killer: under strict, this test kills both L671 mutants via `UnnecessaryStubbing`, and under lenient
it kills neither."*

---

## F6 — Low. "all three tests in this block"

Measured. Copy → `s.getItemdata() + "X"` → `mvn test -Dtest=StockrecordServiceUnitTest` → restore
(`git status --short` empty afterwards):

```
TEST-…StockrecordServiceUnitTest$GetStockRecordDetails.xml: tests=7 fail=0 err=3
    ✗ detailsStillReturnWhenSkuDoesNotResolve       PotentialStubbingProblem
    ✗ detailsCarryItemNameWhenSkuResolves           PotentialStubbingProblem
    ✗ detailsOmitItemNameWhenSkuDoesNotResolve      PotentialStubbingProblem
```

**Three, with `PotentialStubbingProblem`, exactly as claimed.** And the revert baseline, from the surefire XML
rather than console scrape — 10 nested classes summed:

```
TOTAL tests=37 failures=0 errors=0 skipped=0
```

**37/37 confirmed.** The only defect is the noun: the block (`GetStockRecordDetails`) holds **7** tests, the
P4 sub-block **4**. The 4th, `detailsOmitItemNameWhenSkuIsNull`, is untouched by the mutant because its
`itemdata` is null and the guard short-circuits before the call.

**Fix:** *"errors all three of this block's four P4 tests that stub the finder (`…SkuIsNull` short-circuits
before the call)"*.

### On the "three lenients, not two" objection

Raised as a possible invalidation of claim 3. It is not one, and it cuts the other way. `lenient()` only
*removes* strict-stub failure modes; it never changes a return value. Leniency can therefore only **subtract**
kill vectors, never add them. A lenient build that still kills all three mutants is a *stronger* result than a
two-stub comparison would have been. F5 is the measurement of exactly how much it subtracted.

---

## F7 — Low. The comment never names the constraint that actually forbids the forbidden state

The design's core rule is *the key must be ABSENT, never null*. The comment defends it for six lines and
documents `itemdata.item_nr`'s `NOT NULL` in detail. It never mentions that the only thing stopping
`details.put("itemName", null)` — the precise state §5.2 P4's required mutant exists to detect — is
`itemdata.name`'s `NOT NULL`:

```console
$ sed -n '927,937p' src/main/resources/db/migration/V2.2.00__base_v2_schema.sql
CREATE TABLE public.itemdata (
…
    name character varying(255) NOT NULL,
    item_nr character varying(255) NOT NULL,
```

`Itemdata.java:20` is a bare `private String name;` — no `@Column(nullable = false)` — so Hibernate does not
enforce it either; the DB is the sole guarantor. A null `name` row would make `ifPresent` put a null value and
produce the empty-labelled row the design forbids, with every test still green. PRD corroborates the
constraint is honoured (`count(*) FILTER (WHERE name IS NULL)` → **0** of 2,813 on `wh01_hydra_v2`) but nothing
in this repo pins it.

This is the same argument the comment already makes about `item_nr`, applied to the field that carries the
actual risk — and it is stronger here, because `item_nr`'s constraint only affects *which rows match* while
`name`'s affects *whether the invariant holds*.

**Fix** — one line beside the ABSENT-not-null paragraph:

```java
// …and the value can never BE null: itemdata.name is NOT NULL (V2.2.00:936, 0 null/blank of 2,813 on
// prd wh01_hydra_v2). The entity declares a bare String with no @Column(nullable=false), so that
// constraint is the sole guarantor of the ABSENT-not-null invariant — nothing in this repo pins it.
```

---

## F8 — Low. A promotion gate that lives only in a service-method comment is not a gate

`StockrecordService.java:669`: *"so P6 must land before any promotion past dev."*

The substance is right and consistent with the plan — §5.1 row 4 gives deploy order
`P1 → P2 → (P3, P4, P5 in any order) → P6`, and §7 step 5 gates P6 on `/api/public/version` reporting a SHA
containing P2, so "P6 last, before promotion" is already implied. Two problems with where it is written:

1. Nobody reads line 669 of a 680-line service at promotion time. The plan's §7 step table is where promotion
   decisions are actually made, and it does not carry this row.
2. As phrased it reads as a constraint **P4 introduces**, which makes it sound like a P4 blocker. It is a
   property of shipping *any* of P3/P4/P5 ahead of P6, and it is cosmetic.

**Fix:** keep the comment (it is useful *in situ*), and add the row to the plan's §7 step table / the ClickUp
ticket: *"P4 merged without P6 labels the popup row `ItemName`. Cosmetic; gate promotion past dev on P6."*

---

## F9 — Low. The trim measurement is dev-only, sitting next to a claim that carries its prd counterpart

`StockrecordService.java:646`: *"Measured before switching: 0 untrimmed values on either side of
`dev_wh01_om1`, so this buys consistency rather than fixing a live defect."*

Eight lines later the `NOT NULL` claim is stated for **both** `dev_wh01_om1` and prd `wh01_hydra_v2`. The trim
claim is stated for dev only. Measured on prd:

```sql
-- wh01_hydra_v2
itemdata_rows=2813  itemnr_null=0  itemnr_untrimmed=1
stockrecord_rows=3533  sr_itemdata_null=0  sr_itemdata_untrimmed=0  sr_clientid_null=0
```

```sql
-- the one row
item_nr='BONMFPN23 '  client_id=72053  stockrecord rows matching btrim(item_nr) for that client = 0
```

**Net effect is nil** — `stockrecord.itemdata` is 100% trimmed on prd, so that SKU never resolves with or
without the service's trim, and `ifPresent` no-ops. The claim's *conclusion* ("consistency, not a live defect")
survives on prd. What does not survive is the framing: the trim boundary is not symmetric, only the argument is
trimmed, so a padded **stored** `item_nr` is permanently unresolvable through this path. Worth one clause,
because the comment's whole justification for routing through the service is the trim.

`dev_wh01_om1` could not be re-measured — the `wms2-wineco-dev` MCP failed three consecutive connection
attempts (`couldn't get a connection after 30.00 sec`, after an initial `server closed the connection
unexpectedly`); prd answered on the second try. The dev figures in the comment are therefore **unverified by
this lane**, not disputed. The prior code-review lane independently reported dev `item_nr IS NULL` = 0 of 8,807.

**Fix:** *"0 untrimmed values on either side of `dev_wh01_om1`; prd `wh01_hydra_v2` has 1 untrimmed
`itemdata.item_nr` and 0 untrimmed `stockrecord.itemdata`, so it resolves to nothing either way. Note the trim
is one-sided — only the argument is trimmed, never the stored column."*

---

## F10 / F11 / F12 — Info

**F10.** `Map<String, Object> details = new HashMap<>()` (`:587`). `fullDetails.vue` renders
`v-for="(value, name) in details"`, so row order follows JSON key order, which follows `HashMap` order. §7.7's
manual row — *"shows 'SKU Name' alongside 'Shipper Name'/'Shipper Code'"* — implies an adjacency the code
cannot deliver. Pre-existing (all 22–24 keys already render in hash order), not a P4 regression, but a manual
tester can legitimately fail that row for a non-defect. Read "alongside" as "present"; or say so in §7.7.

**F11.** `detailsOmitItemNameWhenSkuIsNull`'s javadoc: *"0 of 9,726,805 rows on `dev_wh01_om1`"*. Plan §7.8
line 1677, same population: *"0 of 9,726,795"*. Ten apart, no timestamp on either. Both support their
conclusion; the numbers should agree or carry an as-of date. (Inherited from `5ede17ab`, not introduced here.)

**F12.** `StockrecordService.java:616-670` is **55 comment lines for 4 code lines**, and three of the six ⚠
paragraphs describe what *earlier revisions of this comment* asserted. That history belongs in the commit log,
which already has it. Once F1/F2 land, consider collapsing the self-referential paragraphs — a future reader
needs the mechanism and the citations, not the audit trail of how they were arrived at.

---

## Ordinary-defect pass (nothing found above Info)

Checked and clean, stated so it is not mistaken for un-reviewed:

- **§3.7 conformance.** The four lines are the plan's snippet verbatim, modulo the approved
  `ItemdataService`-for-`ItemdataRepository` deviation (Nam, 2026-09-22). That deviation is sound: `grep -rn
  "findByClientIdAndItemNr" src/main` shows **every** other caller already on the service and
  `ItemdataService:55` as the sole repository caller — the commit's "P4 would have been the ONLY one bypassing
  it" is confirmed.
- **The `IS NULL` mechanism.** Verified in bytecode, not from memory. `ItemdataRepository:28` carries no
  `@Query`, so it is derived. `spring-data-jpa-3.5.7`,
  `ParameterMetadataProvider$ParameterMetadata.<init>` offsets 9–50 decompile to
  `this.type = (value == null && (SIMPLE_PROPERTY.equals(part.getType()) || NEGATING_SIMPLE_PROPERTY.equals(part.getType()))) ? Type.IS_NULL : part.getType()`,
  `isIsNullParameter()` returns `type == IS_NULL`, and `JpaQueryCreator$PredicateBuilder` offset 401 emits
  `Expression.isNull()`. A null `SIMPLE_PROPERTY` binding **does** become `IS NULL`. The comment is right, and
  it is not overclaiming in the opposite direction: it says "matches zero rows **today** only because
  `itemdata.item_nr` is NOT NULL", which is the correct conditional form.
- **Null-handling.** `ItemdataService:55` guards the trim (`itemNr == null ? null : itemNr.trim()`), so the
  service path cannot NPE on a null SKU even without the call-site guard. `i.getName()` — see F7.
- **Thread-safety / transactions.** No shared mutable state introduced; `details` is method-local; no
  `@Transactional` surface, no SQL, no migration, no SDR export, no authz change.
- **Blast radius.** `getStockRecordDetails` has exactly one caller
  (`StockRecordController:40` → `GET /stockrecord/stockRecordDetailsById/{id}`) and exactly one consumer
  (`wms2-web-ui:store/reports/stockUnit.js:98`). `wms2-mobile-ui` has **zero** references on `origin/develop`
  — verified with a positive control (the same grep returns 1 hit in `wms2-web-ui`), per the
  a-zero-scan-needs-a-positive-control rule. The added key is additive and `fullDetails.vue` renders whatever
  arrives, so no consumer breaks.
- **Claim 1's mechanism, end to end.** `origin/develop:components/reports/stockUnitRecord.vue:89-106` is a
  **16-entry** `:field-names` map (counted: `activitycode … clientNumber`) with no `itemName`;
  `:exclude-fields="['id','version']"` does not exclude it; `fullDetails.vue`'s only other label path is
  `{{ name.charAt(0).toUpperCase() + name.slice(1) }}`, which renders **`ItemName`** literally. There is no
  i18n layer, no global field-name registry, and no third branch. §0 row 29 assigns the entry to **P6**
  ("YES — add"), and plan §5.1 row 4 / §7 step 5 gate P6 on P2 being **deployed** (`/api/public/version`), not
  merely merged. Every element of the claim holds.
- **Claim 2, re-derived from §1.** AC-3's four clauses partition as: headers+`sortable:false` → **P6**;
  map contains `itemName` when the SKU resolves → **P4**; key ABSENT when it does not → **P4**; row still
  appears in the table → **P1** (the plan itself says that clause *"is what makes the `LEFT`-not-`INNER`
  decision an acceptance criterion"*). P4 gets the present/absent pair and nothing more. The correction is
  right and is not an over-correction — then F2 undoes it three paragraphs later.
- **The §5.2 P4 required hand mutation** (`ifPresent` → unconditional `put("itemName", null)`) was executed
  and reported in `0391cfb2` — *"→ `detailsOmitItemNameWhenSkuDoesNotResolve`. One test. Clean."* It is not
  re-reported here, and `9033f28b` is correct that PIT does not subsume it. Requirement discharged.
- **The prior lane's characterisation** is accurate: `p4-code-review.md` does return 3 Medium / 4 Low / 2 Info
  with no High, M2/M3 were genuinely fixed in `5ede17ab`, and L2 (36 vs 37) was overtaken by that rewrite.

---

## Verdict

**Approve with fixes.** The implementation is correct, minimal, plan-conformant and well-tested; claims 1, 2,
3, 5 and 6 all survive adversarial re-derivation, several against independent instruments. This commit is a
genuine improvement on `0391cfb2` — the "ItemName" catch (M1) is a real user-visible finding the author chased
down in another repo and recorded honestly, and the `lenient()` reasoning is the first thing in this phase that
was measured before being asserted.

The three Mediums are all in prose, and they cluster in the same place the ticket's prior four phases did:

- **F1** is a citation that points at the wrong table and *confirms anyway* — the most expensive kind, because
  the next reviewer verifies it and moves on.
- **F2** is the pattern named in the brief, caught in the act: the sentence fixing a mis-citation contains a
  fresh false claim that contradicts its own paragraph.
- **F3** is not a false claim at all — the message is right — but the retained evidence contradicts it, which
  under this repo's two-instruments discipline is the same cost.

F4 and F5 are the honest-measurement-with-the-wrong-scope class: both conclusions hold, both mechanisms are
described slightly wrong, and both sentences are the kind later phases quote.

Fixes for **all twelve** are specified inline with exact replacement text; nine are one line or less and none
touches the four lines of production logic. No further review round is needed on the logic — only on the prose,
and only for F1, F2 and F3.
