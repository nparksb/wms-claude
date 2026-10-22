# SBDEV-3436 — review lane C: the fix commit `083d9b22`

**Scope:** `git show 083d9b22` only. Parent `c85e7949` already reviewed by two lanes; its design is
settled and is not re-litigated here.
**Worktree:** `.claude/worktrees/wms2-api/SBDEV-3436-review-c`, detached at `083d9b22`.
**Date:** 2026-10-06.

## Instruments used, and their blind spots

| Instrument | What it covered | Blind spot |
|---|---|---|
| Read of the full diff + the three touched test files + `ViewDtoService` / both repositories / `AdminController.toFilterId` | every hunk | — |
| Standalone `javac`/`java` port of `hasTopLevelOr` (`$SCRATCH/revc/Probe{,2,3,4}.java`), byte-identical to the committed body | 17 edge cases, 1 deleted-clause mutant, both real constants and all six composed variants | it is a **copy** of the method, not the method. A defect in the copy would mislead; I pasted it, did not retype it. |
| `grep` over `src/main` for every caller of the six variants and of the two service methods | reachability claims in L1 / n-1 | `src/test` callers not enumerated exhaustively |
| **No Maven run.** Four concurrent `plexus-classworlds` processes at start; the lane lead's run (138 tests / 0 failures / 36 reports) is taken as given. | — | nothing here re-measures the suite |

---

## Findings

### [Medium 1] L2 is fixed in one of three places in the same file

`src/test/java/net/aim_ai/wms/integration/repository/HandlingUnitsClientFilterIT.java:42-55`

The commit deletes the stale HAL sentence from inside `nullFilterIntent_reachesTheUnfilteredVariant`
and explains in its place that *"all six methods are `@RestResource(exported = false)`, so neither
`/search/` route exists and no HAL caller can be affected."* The **class javadoc of that same file**
still says the opposite, and still documents the three-valued contract SBDEV-3436 deleted:

```java
 * <p><b>The sentinel contract, and why it is three-valued rather than two.</b> Both queries are
 * {@code @RestResource}-exported Spring Data REST searches, so they are reachable over HAL
 * independently of the controller routes the UI uses. Adding a <i>required</i> filter parameter would
 * silently break those HAL callers: ...
 *   <li>{@code null} — parameter absent (a HAL caller). <b>No filter</b>, byte-for-byte today's
 *       behaviour. This is the back-compatibility guarantee and it is pinned by a test below.</li>
```

Three separate false claims: the methods are not exported (`exported = false` on all six, verified by
reading both repositories and now pinned by this commit's own `noVariantIsExportedOverHal`); the
predicate is no longer three-valued; and "it is pinned by a test below" points at the test this very
commit renamed *because* it no longer pins that. `git show c85e7949 -- <that file>` does not touch this
paragraph, so the staleness came in with the parent — but L2 is the fix that claims to close it, and
the commit message's "Deleted the stale HAL-caller sentence" (singular) is what makes this worth
calling. Same shape as the repo's `fixing-a-false-claim-tends-to-produce-a-new-one` note: it is
sibling copies, and a token grep for `HAL` in the diff is not a sweep of the file.

**Fix:** rewrite the class javadoc's sentinel paragraph to the post-3436 contract (caller resolves the
intent; the query carries plain equalities; no HAL surface exists), or delete it and point at
`StockunitRepository.DETAIL_VIEW_BY_KEYWORD`.

---

### [Medium 2] `hasTopLevelOr` is fed `substring(indexOf(" WHERE "))`, which can start the scan inside parentheses — the guard then goes silently inert

`src/test/java/net/aim_ai/wms/unit/repo/HandlingUnitsDetailViewQueryShapeUnitTest.java:285`

```java
assertThat(hasTopLevelOr(sql.substring(sql.indexOf(" WHERE ")))).as(...)
```

`indexOf` returns the **first** `" WHERE "`. If a future edit puts a filtered sub-select in the FROM
clause — a sub-select is the ordinary way someone would answer "this join is too wide" — that
subquery's `WHERE` is the first one, the scan begins *inside* its parentheses, the subquery's closing
`)` drives `depth` to `-1`, and every subsequent real top-level `OR` is invisible because the test is
`depth == 0`. The positive control (`.contains(" WHERE ")`) still passes, so the assertion stays green
while protecting nothing.

Measured (`Probe3.java`, the committed algorithm verbatim):

```
contains " WHERE "  (positive control) : true
scanned region starts at the SUBQUERY's WHERE:
   WHERE ACTIVE = TRUE) C ON S.CLIENT_ID = C.ID WHERE S.ENTITY_LOCK != 405 OR S.AMOUNT > 0
hasTopLevelOr(scanned)  = false   <-- a REAL top-level OR
hasTopLevelOr(whole)    = true
```

Two more inputs give the same false-negative direction (`Probe.java`):

```
unbalanced extra ) then real OR        want=true  got=false   <<< MISMATCH
unbalanced extra ( then real OR        want=true  got=false   <<< MISMATCH
unterminated literal hides a real OR   want=true  got=false   <<< MISMATCH
```

The unterminated-literal row cannot arise today (the constant is assembled from Java string literals
and all 14 quotes are balanced; `//` comments in the source are not in the SQL), and I confirmed the
doubled-quote escape `'it''s'` is handled correctly by the toggle. The subquery one is the live risk.

This matters more than the others here because L-2's whole premise is that the top-level `OR` is *"the
only mechanism either lane found by which the design could show rows that were not visible before."*

**Fix** — two lines, and both are free today:
1. Scan the whole statement instead of slicing at `" WHERE "`. Measured on the real constants and all
   six composed variants (`Probe4.java`): `fromWHERE=false  whole=false` for every one, so nothing
   currently relies on the slice. (The slice presumably exists to dodge an `OR` in a join `ON` clause;
   there is none, and if one is ever added a fail-loud red is the right outcome.)
2. Fail closed on `depth < 0` — e.g. `if (depth < 0) return true;` — so an unbalanced region reds
   rather than silently stopping detection.

---

### [Low 1] n-2 widened the matrix 4×4 → 6×6 and left three "4×4 / 16" references behind — one of them written in this commit

- `ViewDtoServiceHandlingUnitsRoutingUnitTest.java:79` — `* The full 4x4 matrix: each of {@code null} / {@code -1} / {@code 0} / a real id, on both parameters.`
  Now 6×6, and the value list omits the two values n-2 added. A reader asking "does the matrix cover
  `-2`?" is told no.
- `ViewDtoServiceHandlingUnitsRoutingUnitTest.java:91` — `// with it: the moment expected and actual come from the same code, all 16 rows become a`
  Now 36. This line is **inside the hunk that did the widening**.
- `HandlingUnitsClientFilterIT.java:507` — `// matrix; the branch exercised below is this IT's own private copy of it, so this test cannot`
  preceded by `...ViewDtoServiceHandlingUnitsRoutingUnitTest's 4x4` — **authored fresh in this commit**
  (the M2 comment rewrite), already wrong against n-2 in the same commit.

The commit's own `n3` fixes exactly this failure mode in `CLAUDE.md` ("it now states the rule it
encodes instead of a count that rots on the next addition") and then introduces three instances of it.
Nothing executable depends on the numbers — no assertion counts matrix rows — so this is prose only.

**Fix:** say "every combination of `null` / `-1` / `0` / a real id / `-2` / `Long.MIN_VALUE` on both
parameters" and "all rows", with no arithmetic.

---

### [Low 2] The detector's **prefix** token-boundary clause survives the entire six-case control

`HandlingUnitsDetailViewQueryShapeUnitTest.java:334` (the clause) / `:299-316` (the control)

```java
&& (i == 0 || !Character.isLetterOrDigit(sql.charAt(i - 1)) && sql.charAt(i - 1) != '_')
```

`theTopLevelOrDetectorIsObservedToFire` exercises the **suffix** boundary (`ORDER BY`) but nothing
exercises the prefix one. Deleting the whole clause (`Probe2.java`) leaves all six control cases green:

```
--- prefix-boundary mutant vs the 6 control cases ---
  WHERE a = 1 AND (b = 2 OR c = 3)   want=false got=false survives
  WHERE a = 1 OR b = 2               want=true  got=true  survives
  WHERE a = 1 AND (b = 2) OR c = 3   want=true  got=true  survives
  WHERE name LIKE '%OR%' AND x = 1   want=false got=false survives
  WHERE x = 1 ORDER BY y             want=false got=false survives
  WHERE coalesce(x, 0) = 1 AND y = 2 want=false got=false survives
  => mutant SURVIVES the whole control
```

and both real constants too (no depth-0 token in either contains the substring `OR` — `LOWER`,
`CONCAT`, `ENTITY_LOCK` all miss). The clause itself is **correct**: I measured `XOR`, `_OR` and `1OR`
all correctly not firing. It is simply unpinned, which is the same standard
`theShapeAssertionsRejectKnownMutants` holds itself to three sections above.

The lead's other listed cases I measured and the detector gets right, but which the control also does
not cover: `OR` as the first token, `OR` as the last token, `)or(` with no spaces, `'it''s'`, an `OR`
inside a literal that also contains a paren, nested parens with the `OR` only at depth 2.

**Fix:** add three rows — `" WHERE a XOR b"` → false, `" WHERE a _OR b"` → false, `" WHERE (a=1)or(b=2)"` → true.

---

### [Low 3] L-2 pins the shared constant but not the six composed `@Query` texts

`HandlingUnitsDetailViewQueryShapeUnitTest.java:278-294`

`theSharedConstantIsSafeToAppendTo` reads `DETAIL_VIEW_BY_KEYWORD` and never touches a variant. The
defect it describes is realised in the composition, and the tail is what a future author edits:

```java
@Query(value = DETAIL_VIEW_BY_KEYWORD + " AND c.id = :clientId OR c.id = :fallbackId", nativeQuery = true)
```

leaves the constant clean, so this test passes. `eachVariantCarriesExactlyItsOwnConjuncts` catches a
straight `AND` → `OR` flip of a *known* conjunct (it requires `contains("AND C.ID = :CLIENTID")`), but
an **added** top-level disjunct passes it, passes `everyVariantIsTheUnfilteredOnePlusAConjunct`
(`startsWith` is satisfied), and passes `noVariantCarriesAParameterOnlyDisjunct` (it is not
parameter-only — it references `c.id`).

Measured (`Probe4.java`): running the detector over each composed variant returns `false` for all six
today, so folding this into `everyVariant(...)` is free and breaks nothing.

**Fix:** add `everyVariant((sig, sql) -> assertThat(hasTopLevelOr(sql...)).isFalse())`, keeping the
constant-level assertion as the narrower diagnostic.

---

### [Low 4] L3 asserts a runtime behaviour in four javadocs, in the same commit that removed the only probe that could have observed it

`StockunitRepository.java:518-525, 542-545, 554-558` and `UnitloadRepository.java:287-293`

```java
 * <p>⚠ {@code clientId} must be non-null and not the {@code -1} sentinel. A null bind evaluates to
 * {@code c.id = NULL}, which is never true, so this returns an EMPTY page rather than an unfiltered
 * one -- and raises nothing.
```

The *SQL* half is unarguable. The **"raises nothing"** half is a claim about a null bind in a **native**
query under pgjdbc, and the same file's own history is the reason to want evidence: the class javadoc
of `HandlingUnitsClientFilterIT` cites `MessageRepository.getDetailViewByKeyword` failing with
`operator does not exist: timestamp with time zone >= integer` on exactly that. My reading is that it
is correct here — the context is `bigint = $1`, which PostgreSQL infers unambiguously, unlike the
`timestamp >= $1` case — but that is reasoning, not measurement, and M2 in this same commit states
plainly that after the rename **"NO NULL IS BOUND ANYWHERE"** in the IT. So the commit removes the
instrument and adds the claim in one move.

**Fix:** either soften to what SQL alone guarantees ("`c.id = NULL` is never true, so at best an empty
page — this path is not exercised by any test"), or add one line to the IT binding `null` straight into
`getDetailViewByKeywordAndClient` and asserting an empty page. The second also gives L3 a mutation
target.

---

### [nit 1] `noVariantIsExportedOverHal` reimplements the loop with the weaker vacuity guard

`HandlingUnitsDetailViewQueryShapeUnitTest.java:253-272`

Answering the lead's question directly: **the `isNotEmpty()` guard is in the right place** — it sits
per repository, before the `forEach`, so an empty family reds rather than passing vacuously. But every
other iterating test goes through `everyVariant(...)`, which additionally asserts `checked == 6`. This
one accepts 1 + 1. It cannot use `everyVariant` as written (that callback hands over the SQL text, not
the `Method`), which is why it was open-coded — but the guard could match: add
`assertThat(variants).hasSize(repository == UnitloadRepository.class ? 2 : 4)`, or widen
`VariantAssertion` to carry the `Method`.

### [nit 2] Two blind spots are not in the blind-spot javadoc

`HandlingUnitsDetailViewQueryShapeUnitTest.java:318-322` lists only "nested `SELECT` at depth 0" and
"balanced-paren text is opaque". Measured and missing: a **double-quoted identifier** fires a false
positive (`" WHERE \"OR\" = 1 AND b = 2"` → `true`), and an unterminated single quote or an unbalanced
paren produces a false **negative** (Medium 2). The first direction is harmless (fails loud); the
second is the one worth writing down. A javadoc that says "blind spots, stated" should state them.

### [nit 3] Precedence in the boundary conditions is correct but reads as ambiguous

`HandlingUnitsDetailViewQueryShapeUnitTest.java:334, 336-337`

```java
&& (i == 0 || !Character.isLetterOrDigit(sql.charAt(i - 1)) && sql.charAt(i - 1) != '_')
```

Java binds `&&` tighter than `||`, so this is `i == 0 || (!isLetterOrDigit(prev) && prev != '_')`,
which is the intent — verified by probe, not assumed. In a hand-rolled scanner that a future reader
will have to re-derive, the inner parentheses are worth the two characters.

### [nit 4] The new sections are numbered `5.` and `6.`, and the pre-existing `5.` was left in place

`HandlingUnitsDetailViewQueryShapeUnitTest.java:250` `// ---- 5. the export state of the new names`,
`:275` `// ---- 6. the shared constant must be safe to APPEND to`, `:357`
`// ---- 5. the legitimate OR arm must survive`.

The file now reads 1, 2, 3, 4, 5, 6, 5. Precisely the defect `n3` fixes in `CLAUDE.md` in this same
commit. Renumber the tail to `7.`.

---

## Verified correct — checked, no finding

- **M1, the three added count asserts.** Expected values **3 / 3 / 1 are right** against `seed()`
  (`:121-150`): three stock units `SU_A1/A2/B1` and three unit loads `UL-SBDEV1628-A1/A2/B1`, all
  `entity_lock = 0`, all matching `KEYWORD_ALL = "SBDEV1628"` through their labels; `ITEM_A1` is held
  by `SU_A1` alone. No `goodsreceiptposition` is seeded, so the container query's `LEFT JOIN g` cannot
  fan a row out and inflate the count.
- **`PageRequest.of(0, 1)` does force the derived count** for all three. `PageableExecutionUtils`
  short-circuits only when `pageSize > content.size()` or the content is empty; here `1 > 1` is false
  and each returns one row. And the three cannot pass vacuously: an empty content list would
  short-circuit to `totalElements = 0`, which fails every one of the three asserts.
- **All six variants are now count-forced** — the three pre-existing (`AndClient` on both
  repositories, `AndClientAndItemdata`) plus these three. M1's reasoning that every other probe uses
  `PageRequest.of(0, 50)` against ~3 rows and so never plans a count is accurate.
- **L-1 cannot pass vacuously** (see nit 1 for the one way it is weaker than its siblings).
- **n-2's `expected` derivation is still correct.** The hand copy `c != null && c != -1L` matches
  production `ViewDtoService.isFiltered` exactly (`:624`), and `-2L` / `Long.MIN_VALUE` take the
  filtered path as the comment claims. Nothing in the `switch` or the stubbing assumed four values —
  both switches are keyed on the four-constant `Variant` enum, not on the matrix dimension.
  `eq(Long.MIN_VALUE)` is safe: Mockito's `Equals` matcher uses `.equals()`, so the `Long`-cache trap
  does not apply.
- **L1 is accurate and complete.** `AdminController.toFilterId:99-108` returns `-1L` for `null`, for
  `isBlank()`, and for a `NumberFormatException`; `StockUnitController:794` and `UnitLoadController:248`
  both call it unconditionally on a `String` `@RequestParam`. A `grep` of `src/main` shows those two are
  the only non-test callers of either service method, and `ViewDtoService` is the only `src/main`
  caller of the six repository variants — so "the `null` arm is unreachable from HTTP" holds for the
  whole reachable graph, not just the two named entry points.
- **M2's rename neither over- nor under-claims.** `nullFilterIntent_reachesTheUnfilteredVariant` is
  what the body does: the probe helper resolves the intent in Java (`isFiltered` at `:233`) and
  dispatches, so "intent" rather than "a NULL filter" is the honest word, and the comment's admission
  that the IT carries its own copy of the branch and cannot catch a mis-routing caller is correct.
- **n2** (`verifyNoMoreInteractions(unitloadRepository)` in `includeToDeleteIsForwardedNotRouted`) and
  **n1** (the tautology guard on the hand-written predicate) are both right, and n1 names the real
  failure mode.
- **n3's `CLAUDE.md` renumbering is correct** (1, 2, 3, 4) and the header now states the rule instead
  of a count.

## What I did not do

No Maven run: four `plexus-classworlds` processes were live at lane start, and this repo's
`concurrent-maven-one-worktree-false-reds` note makes a red from that worthless. The lead's targeted
run (138 / 0, 36 reports) and both mutation kills are taken as given, per the task. Every measurement
above comes from a standalone `javac`/`java` port of the committed `hasTopLevelOr` body, which is a
copy and not the method itself.

---

**High: 0, Medium: 2, Low: 4, nit: 4**
