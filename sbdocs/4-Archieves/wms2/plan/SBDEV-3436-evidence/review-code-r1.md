# SBDEV-3436 — code review, correctness/quality lane (round 1)

- **Commit:** `c85e7949` on `bugfix/SBDEV-3436-handling-units-query-shape`
- **Base:** `b6693a6a`
- **Reviewer worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3436-review-a` (detached at `c85e7949`)
- **Lane:** correctness / logic / test quality. Security and data-scoping are a sibling lane and are not duplicated here.
- **Date:** 2026-10-06

## Verdict

**REQUEST CHANGES** — no High findings; two Mediums, both in the test lane, both one-to-few lines to
fix. The production change itself is correct: I could not break the routing equivalence, and the
`AndItemdata` variant is both reachable and necessary.

`High: 0, Medium: 2, Low: 3, nit: 3`

## What I verified and how

| Claim | Instrument | Result |
|---|---|---|
| The change compiles (main + test) | `git status` clean at `c85e7949`; every changed source mtime ≤ 20:15, `target/classes/...StockunitRepository.class` 20:15 and `target/test-classes/...QueryShapeUnitTest.class` 20:16, with the PIT run at 20:18 on top | **compiles** — no Maven run of my own (a peer's was in flight; `pgrep -f plexus-classworlds` showed 4) |
| Routing equivalence, old SQL vs new Java | hand-enumerated the 4×4 cross-product against the removed `COALESCE` predicate | **equivalent** — see below |
| `AndItemdata` reachable from the wire | `StockUnitController.getDetailView:794` → `toFilterId(clientId)`, `toFilterId(itemdataId)` independently | **reachable**, and behaviourally covered (`HandlingUnitsClientFilterIT:310,486`) |
| Constant-name collision | grep for any type implementing or static-importing both repositories | **none** — `StockunitRepository` and `UnitloadRepository` share no implementor; the shape test holds both only as `.class` literals |
| `{@link}` targets resolve | `FixLocationAssignmentRepository.REFILL_ELIGIBILITY_FROM_WHERE:167`, `StockrecordViewRepository.findByKeyword:128` / `findByKeywordAndClient:150`, `StockrecordViewRepositoryQueryShapeUnitTest` | **all present**, all same-package so no import needed |
| Count-query derivation exercised per variant | enumerated every `PageRequest.of(0, 1)` in the IT | **3 of 6 variants never force a count** — Medium 1 |
| LSP type check | `lsp_diagnostics` | **not available** — jdtls is not installed in this environment; superseded by the compile evidence above |

### Routing equivalence (the lead's item 1) — holds

Old, inside SQL:

```
AND (COALESCE(CAST(:clientId AS BIGINT), -1) = -1 OR c.id = CAST(:clientId AS BIGINT))
```

| `clientId` | old SQL | new `isFiltered` + variant | same? |
|---|---|---|---|
| `null` | `COALESCE(NULL,-1) = -1` → TRUE → no filter | `false` → unfiltered variant, parameter not bound at all | yes |
| `-1` | `COALESCE(-1,-1) = -1` → TRUE → no filter | `false` → unfiltered | yes |
| `0` | `0 ≠ -1` → falls to `c.id = 0` | `true` → `AND c.id = 0` | yes |
| real id | `c.id = :clientId` | `AND c.id = :clientId` | yes |

The two predicates were independent in SQL and the four variants reproduce exactly that cross-product.
`c.id` cannot be NULL (inner join on the PK), so there is no three-valued-logic residue. I could not
construct a `(clientId, itemdataId)` pair that reaches the wrong variant.

`isFiltered` itself is right: `id != -1L` compares against a `long` literal, which forces unboxing, so
this is value comparison and not the reference trap the javadoc warns about.

---

## Medium

### M1 — the derived COUNT query is never issued for 3 of the 6 variants, including both unfiltered headline methods

`src/test/java/net/aim_ai/wms/integration/repository/HandlingUnitsClientFilterIT.java`

The IT's own javadoc states the hazard precisely:

> `// 3, so PageableExecutionUtils short-circuits and NEVER ISSUES the count query -- they would all`
> `// stay green against a count query that was broken or unfiltered`

Every count-forcing call in the file — i.e. every `PageRequest.of(0, 1)` — now targets a **filtered**
variant:

- `getDetailViewByKeywordAndClient` (stockunit) ×4 — lines 326, 372, 420 and one more
- `getDetailViewByKeywordAndClient` (unitload) ×3 — lines 335, 397, 442
- `getDetailViewByKeywordAndClientAndItemdata` (stockunit) ×1 — line 342

Never count-forced by any test:

- `StockunitRepository.getDetailViewByKeyword` — **the 6,102 ms → 632 ms default page load**
- `UnitloadRepository.getDetailViewByKeyword` — **the 777 ms → 192 ms default page load**
- `StockunitRepository.getDetailViewByKeywordAndItemdata` — brand-new, wire-reachable

The probe helpers do reach all six for *content*, but at `PageRequest.of(0, 50)` against ~3 rows, so
`PageableExecutionUtils` short-circuits and no count statement is ever planned.

**Why this is a regression in coverage, not just a thin spot.** Before the change there was **one**
`@Query` text, and `countQuery_appliesTheSameFilters` forced its count. Now there are **six** texts,
each getting its own independently-derived count query at first use, and only three are validated.
The two that are not are exactly the ones production runs on every default grid load, where the page
is 25 of 1.6M rows and the count always fires.

**Fix** — three lines in `countQuery_appliesTheSameFilters`, e.g.

```java
assertThat(stockunitRepository.getDetailViewByKeyword(KEYWORD_ALL, false, PageRequest.of(0, 1))
    .getTotalElements()).as("the unfiltered variant's derived count must see all three").isEqualTo(3);
assertThat(unitloadRepository.getDetailViewByKeyword(KEYWORD_ALL, false, PageRequest.of(0, 1))
    .getTotalElements()).isEqualTo(3);
assertThat(stockunitRepository.getDetailViewByKeywordAndItemdata(KEYWORD_ALL, ITEM_A1, false, PageRequest.of(0, 1))
    .getTotalElements()).isEqualTo(1);
```

### M2 — `nullFilters_behaveAsNoFilter` no longer binds a null, but still claims it proves the null bind plans

`src/test/java/net/aim_ai/wms/integration/repository/HandlingUnitsClientFilterIT.java`, the test's
own comment:

> `// A null bind in a NATIVE query is also where PostgreSQL type inference bites (the`
> `// MessageRepository CAST defect). Reaching this assertion at all proves the statement planned.`

That is no longer true of this test. `stockUnits(KEYWORD_ALL, null, null)` is resolved by the probe
helper's `isFiltered` **in Java**, and dispatches to `getDetailViewByKeyword(keyword, false, p)` —
a query that has no `:clientId` or `:itemdataId` parameter at all. No null is bound anywhere, so
nothing about PostgreSQL type inference is exercised. The same applies to
`stockUnits(KEYWORD_ALL, null, ITEM_A1)`, which dispatches to `getDetailViewByKeywordAndItemdata`
with a non-null SKU.

Consequence: the test now executes **exactly the same SQL** as `allShippersSentinel_doesNotFilter`
(lines 286–290) and `skuFilter_appliesIndependentlyOfShipper` (line 310). Its only remaining unique
content is that the IT's *own private copy* of `isFiltered` handles `null` — which is the helper
testing itself, not the system. The surviving genuine coverage of null-routing is
`ViewDtoServiceHandlingUnitsRoutingUnitTest`'s matrix, which is correct and sufficient.

This matters here beyond tidiness: a green test carrying a claim it no longer supports is the shape
that gets cited later as evidence.

**Fix** — keep the assertions (they are a fine behavioural check of the unfiltered variant) but
rewrite the comment to say what is now true: that null-routing is owned by
`ViewDtoServiceHandlingUnitsRoutingUnitTest`, that this test now only proves the unfiltered and
SKU-only variants return the right rows, and that **no null is bound any more** so the
`MessageRepository` CAST concern no longer applies to these queries. Consider renaming it to match
(`nullFilterIntent_reachesTheUnfilteredVariant`) so the name does not promise a null bind either.

---

## Low

### L1 — `isFiltered`'s javadoc misstates `toFilterId`'s contract

`src/main/java/net/aim_ai/wms/service/ViewDtoService.java`:

> `* <p>{@code AdminController.toFilterId} normalises the wire to {@code null} (parameter absent) or`
> `* {@code -1} (the UI's "All" sentinel); both mean do-not-filter.`

`AdminController.toFilterId` **never returns null**:

```java
protected static Long toFilterId(String raw) {
    if (raw == null || raw.isBlank()) {
        return -1L;
    }
    ...
    } catch (NumberFormatException e) {
        return -1L;
    }
}
```

Absent, blank *and* non-numeric all become `-1L`. So from the only two HTTP entry points
(`StockUnitController:794`, `UnitLoadController:248`) the `id != null` arm of `isFiltered` is
unreachable. The guard should **stay** — it is cheap and protects in-process callers — but the stated
reason is wrong, and a reader who trusts it will believe `toFilterId` can hand back null.

**Fix** — replace with something like: "`toFilterId` normalises absent / blank / non-numeric to `-1`;
the explicit null check additionally covers direct in-process callers, which do not go through it."

### L2 — the HAL-route claim in `nullFilters_behaveAsNoFilter` is stale

Same file:

> `// Spring Data REST binds an omitted search parameter as null. If null were treated as a value`
> `// to match, every HAL caller of /v3/stockunit/search/getDetailViewByKeyword and`
> `// /v3/unitload/search/getDetailViewByKeyword would silently start receiving zero rows.`

Every one of the six methods carries `@RestResource(..., exported = false)`, at method level, so
neither `/search/` route exists. This predates the commit (`exported = false` is present at
`b6693a6a`), but the author rewrote the surrounding probes and the stale line is now load-bearing for
M2's rationale. Grep of `v2/wms2-web-ui` finds no caller of either path.

**Fix** — delete the HAL sentence, or restate it as history ("these were exported until …").

### L3 — the filtered variants silently return zero rows on a null id, with nothing saying they must not

`src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java`,
`src/main/java/net/aim_ai/wms/repo/jpa/UnitloadRepository.java`

`@Query(value = DETAIL_VIEW_BY_KEYWORD + " AND c.id = :clientId", nativeQuery = true)` with a null
bind evaluates to `c.id = NULL` → never true → an empty page and no error. Before the split this was
impossible: the three-valued form read null as "no filter". The four filtered variants are public
methods on a Spring Data interface with no `@NonNull`, no nullability javadoc, and no runtime check;
the only thing standing between a future caller and a silently-empty grid is remembering to branch
first. `getDetailViewByKeywordAndItemdata` is the most exposed, since it is the one nothing in the UI
calls.

**Fix** — one javadoc line per filtered variant: "`clientId` must be non-null and non-sentinel —
callers route through `ViewDtoService.isFiltered`; a null bind yields an empty page, not an
unfiltered one." (A `@NonNull` on the parameter would be stronger but needs `@NonNullApi` on the
package to be enforced, which is a larger change than this ticket.)

---

## nit

### N1 — `stockUnitMatrix` re-derives `expected` with a textual copy of the production predicate

`src/test/java/net/aim_ai/wms/unit/service/ViewDtoServiceHandlingUnitsRoutingUnitTest.java:81-82`:

```java
boolean byClient = c != null && c != -1L;
boolean bySku = s != null && s != -1L;
```

This is a *copy*, so it is independent today and genuinely kills the truthiness mutant — the test is
sound as written. The risk is a later "DRY this up" pass pointing it at `ViewDtoService` (or at a
shared helper) and turning the whole matrix into a tautology, which is precisely the failure this
repo has recorded before. Either hardcode the 16 expected `Variant` values in the `Arguments`, or add
one line: "⚠ this must stay a hand-written copy — never call production's `isFiltered` here."

### N2 — `includeToDeleteIsForwardedNotRouted` omits the `unitloadRepository` no-more-interactions guard

Same file, line 170: it calls `verifyNoMoreInteractions(stockunitRepository)` only, where both sibling
tests call it on both mocks. Harmless today; inconsistent, and the missing one is the cheap guard.

### N3 — the new CLAUDE.md entry `1b.` is not a list item in Markdown

`CLAUDE.md`, inside the numbered "Test-lane traps" list:

```
1b. **Surefire's multi-class separator is a COMMA, not `+`.**
```

CommonMark does not recognise `1b.` as an ordered-list marker, and with no blank line before it the
line becomes a lazy continuation of item 1's paragraph — so items 1 and 1b render run together rather
than as two traps. The content is valuable and correct (I take the measurement as given). Renumber to
`2.` and bump the rest, or make it a nested bullet under item 1.

---

## Positive observations

- **The query-shape test fails closed, and I could not find a way round it.** `theVariantFamilyIsExactlyTheExpectedShapes` pins both signature sets with `containsExactlyInAnyOrder` keyed on name **plus parameter types**; `everyVariant` asserts `isNotEmpty()` per repository *and* `checked == 6` at the end; `queryTextOf` carries a per-read `FROM <table> <alias>` anchor. A gutted interface, an emptied `@Query`, a renamed alias and a dropped `.toUpperCase` each red loudly rather than passing vacuously. That is the specific failure this repo has been bitten by, and it is closed here.
- **`theShapeAssertionsRejectKnownMutants` is a real mutation check, not a tautology.** I checked both directions: deleting `.doesNotContain(" OR :")` lets mutants 3–5 survive and reds the test; deleting `.doesNotContain("COALESCE(CAST(:")` lets mutants 1, 2 and 6 survive and reds it. Both assertions are independently pinned, and the positive control at the end distinguishes "rejects the defect" from "rejects everything" — which is the failure mode that would otherwise red the suite against correct code.
- **`theIncludeToDeleteArmSurvives` is the right shape of guard.** Protecting a *correct* parameter-only disjunct from the cleanup pass that the sibling test invites is the kind of thing that normally only gets written after someone deletes it.
- **The routing test's `0L` rows are the load-bearing ones** and they are there on both grids. `SYSTEM_CLIENT = 0L` routing to a *filtered* variant is what kills the truthiness mutant, and the matrix includes it on both parameters.
- **The unkillable boxed-comparison mutant is declared rather than implied.** Stating a blind spot in the test's own javadoc, instead of letting a green suite imply coverage, is the correct trade — I agree with it as made.
- **The `ViewDtoServiceUnitTest` migration preserved intent exactly.** All 15 migrated call sites passed `-1L` before and after, so every one of them exercised the no-filter path before the change and the unfiltered variant after it. No test silently moved from a sentinel path to a different path. I checked each one in the diff.
- **Removing the `CAST(... AS BIGINT)` wrappers is safe and worth noting.** They existed to stop PostgreSQL inferring a parameter type from a null bind; with the parameter now guaranteed non-null and sitting opposite `c.id`/`i.id`, inference comes from the column and the `MessageRepository` defect shape cannot recur.
- **`DETAIL_VIEW_BY_KEYWORD` as a shared compile-time constant is the right call,** and the javadoc's reason (it is what makes "every variant is the unfiltered query plus a conjunct" true by construction, which `everyVariantIsTheUnfilteredOnePlusAConjunct` then checks with `startsWith`) is the strongest argument in the diff.

## On the three items flagged "known and accepted"

- **Boxed-comparison mutant unkillable** — agreed, and `id != -1L` is the correct spelling regardless (the `long` literal forces unboxing). Declaring it beats claiming it.
- **PIT survivor at `ViewDtoService:596`** — pre-existing, outside the diff. Not re-raised.
- **`HandlingUnitsClientFilterIT` mirroring the production branch** — the trade is right. An IT that reached the repository through `ViewDtoService` would be testing two things at once and would not be able to pin per-variant row sets. M2 is not a disagreement with that trade; it is that one test's *comment* was not updated to match the trade that was made.

