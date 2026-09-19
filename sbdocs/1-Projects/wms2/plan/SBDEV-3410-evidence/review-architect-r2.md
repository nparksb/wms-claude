# SBDEV-3410 — ARCHITECT review, ROUND 2 (ralplan consensus lane)

**Lane:** architect, READ-ONLY. The plan was not edited. No branches, no worktrees, no DDL, no writes.
**Target:** `SBDEV-3410-stock-unit-record-shipper-filter-and-product-name.md`, 1,984 lines (`wc -l`), revised snapshot.
**Round-1 files read:** my own `review-architect.md`; the second lane's `review-critic.md` (read after round 1 closed).
**Code read at:** `v2/wms2-api origin/develop = 29ce240db0c9edb747346e2b6fe42287afcd0b63`, `v2/wms2-web-ui origin/develop = a27703eb32f9f8f4fede697fe82ce13ba6e62a6c`, always via `git show origin/develop:<path>` — never a local checkout.
**DB read:** read-only `EXPLAIN` / catalog queries on `dev_wh01_om1` via the `wms2-wineco-dev` MCP target, 2026-09-18. `SET plan_cache_mode` / `SET enable_seqscan` / `PREPARE` are session-local.

---

## VERDICT: **SOUND-WITH-CHANGES**

The headline fix is **correct, and I verified it against a stronger instrument than the plan used.** All seven
of my round-1 required changes and both recommendations landed. The revision is honest about what it could not
measure and it did not adopt a reviewer's word anywhere I checked.

Three things still block, one of them new and material:

1. **A-R2-1 (HIGH, new)** — the split leaves the store reading `results._embedded.stockrecordView`, and this
   repo has already written down, in source, that `_embedded` is **absent, not empty**, when SDR returns an
   empty collection. The shipper filter makes an empty page a routine state — the plan's own §3.6 records that
   `System-Client` (`id = 0`) owns **0 `stockrecord` rows on hydra PRD** and is in the dropdown. Nothing in the
   plan, at any layer, exercises a zero-row result.
2. **A-R2-2 (MEDIUM, new)** — the **filtered export**'s query plan is unmeasured, and P1's post-index
   re-measurement checklist covers only the read path. I measured the export shape: the generic plan keeps the
   `Index Cond` but adds a `Sort` on a **1,560× row underestimate**, and that estimate is what will decide
   between the composite index and the narrow one once the composite exists.
3. **A-R2-3 (LOW, sibling-copy miss)** — F4 was accepted and applied in three places; the fourth copy, §7.5
   row 5, still says `SDR_WRITE_WITHDRAWN` *"gains it for parity"* — the exact word F4 asked to be removed.

Nothing here argues for changing the design. Nothing here re-opens a resolved item.

---

## 1. Grading the A-1 fix on its merits

### 1.1 It restores index reachability on the read path — verified with the *actual* predicate

My round-1 measurement, and the plan's §3.2 table, both isolate `WHERE sr.client_id = $1`. That is not the
predicate `findByKeywordAndClient` renders: the real one is
`(CONCAT(...) LIKE LOWER(concat('%', :keyword,'%')) or :keyword = '') AND p.clientId = :clientId`, which still
**contains an `OR` arm one of whose disjuncts (`:keyword = ''`) does not reference the table** — structurally
the same hazard, in the same `WHERE`. Neither review had measured the composed form. I did.

Paired control, `dev_wh01_om1`, `plan_cache_mode = force_generic_plan`, count form, same session, keyword arm
present in **all three**:

| predicate (bind params) | generic plan |
|---|---|
| `(kwCONCAT LIKE … or $2='') AND p.client_id = $1` — **the plan's shape** | `Aggregate → Index Scan using index_stockrecord_client_id`, **`Index Cond: (client_id = $1)`**, keyword arm demoted to `Filter:` |
| `(kw…) AND (p.client_id = $1 OR $1 IS NULL OR $1 = -1)` — the withdrawn 3-arm form | `Finalize Aggregate → Gather → Parallel Seq Scan`, `Filter: (((client_id = $1) OR ($1 IS NULL) OR ($1 = '-1'::integer)) AND …)` |
| `(kw…) AND (COALESCE(CAST($1 AS BIGINT), -1) = -1 OR p.client_id = CAST($1 AS BIGINT))` — the sibling's form | `Parallel Seq Scan`, `Filter: ((COALESCE($1, '-1'::bigint) = '-1'::integer) OR (client_id = $1)) AND …)` |

**The `OR` on `:keyword` does not contaminate the conjunction.** A top-level `AND` lets the planner take the
indexable conjunct as an index qual and push the rest to `Filter`. So the fix holds against the objection the
plan never raised against itself. **§3.2's table should carry the composed form, not the isolated conjunct** —
as written, a later reader can correctly object that the measurement is of a predicate the code does not issue.

### 1.2 It holds on the export path too

The export is a different shape — native SQL, `ORDER BY created DESC OFFSET/LIMIT` rather than a count. I
measured the plan's proposed `findByClientOffsetAndLimit` under `force_generic_plan`:

```
Limit
  ->  Gather Merge  (Workers Planned: 1)
        ->  Sort  (Sort Key: created DESC)
              ->  Parallel Index Scan using index_stockrecord_client_id on stockrecord p
                    Index Cond: (client_id = $2)
                    Filter: ((concat(...) ~~ lower(concat('%', $1, '%'))) OR ($1 = ''::text))
```

`Index Cond` survives. **Both paths are fixed.** See A-R2-2 for what that plan still leaves open.

### 1.3 No `OR` arm survives where it matters — with the one exception the plan already names

Deriving method: read every predicate the plan specifies (§3.4's two JPQL methods, §3.6's two native methods)
and classified each disjunct by whether it references the table. Result: the only surviving parameter-only
disjunct anywhere is `or :keyword = ''`, which is (a) carried over unchanged from the existing
`findByOffsetAndLimit` on `origin/develop` — I read it: `… LIKE LOWER(concat('%', :keyword,'%')) or :keyword = '')` —
and (b) explicitly demoted to "a bonus not a guarantee" in §3.4 and §10.3 item 2. It cannot cost an index
because a leading-wildcard `LIKE` was never an index qual. **Blind spot:** I graded the four predicates the
plan *writes down*; a fifth predicate introduced during implementation is outside any review's reach, which is
exactly what `filteredSearchKeepsAnIndexCondition` exists to catch.

### 1.4 The new IT's control is sound — verified, and it is not vacuous in either direction

§7.2 flags `filteredSearchKeepsAnIndexCondition` as possibly vacuous on a small fixture and proposes
`SET enable_seqscan = off` as the control. I tested whether that control defeats the **mutant** as well as the
fixture — i.e. whether forcing off seqscan would let the `OR` form fake a pass. It does not:

```
SET enable_seqscan = off;  -- OR form, force_generic_plan
Aggregate  (cost=10000670212.57..…)
  ->  Seq Scan on stockrecord p  (cost=10000000000.00..…)
        Filter: (((client_id = $1) OR ($1 IS NULL) OR ($1 = '-1'::integer)) AND …)
```

`enable_seqscan = off` is a cost penalty (`1e10`), not a prohibition, and the `OR` form has **no** index path
at all — the keyword arm references five unindexed columns, so no index-only path exists either, at any table
size. So with the control on: correct form → `Index Scan` + `Index Cond`; mutant → `Seq Scan` with the penalty
cost. The assertion discriminates, and the P2 mutation row's kill is attributable. **This upgrades §7.2's
hedge from "flagged" to "verified"; record it so nobody removes the control as unproven.**

### 1.5 The sibling-convention finding is TRUE — it is a real defect in shipped code

This is the claim the brief asked me to settle independently, because if false the plan's justification for
diverging from the sibling collapses.

The predicate exists verbatim at `origin/develop`, `src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java`:

> `"AND (COALESCE(CAST(:clientId AS BIGINT), -1) = -1 OR c.id = CAST(:clientId AS BIGINT)) "`
> `"AND (COALESCE(CAST(:itemdataId AS BIGINT), -1) = -1 OR i.id = CAST(:itemdataId AS BIGINT))"`

and I measured that exact shape against `stockrecord` under `force_generic_plan` (§1.1 row 3): `Parallel Seq
Scan`, no index condition. **The mechanism is not table-specific** — a disjunct that does not reference the
table can be true for any row, so no index condition is derivable, whatever the table.

Two refinements the plan should carry, because they make the §10.4 item 3 proposal decidable rather than
speculative:

- The sibling filters on **`c.id`** (the joined `client` PK), not `s.client_id`. With a **plain** equality
  Postgres's equivalence-class machinery can propagate `c.id = $1` through `s.client_id = c.id` into an index
  qual on `stockunit`; with the `COALESCE`/`OR` form it cannot form the equivalence class at all. So the
  sibling loses **two** things, not one: the index qual *and* the selectivity propagation that §3.4's own Q1
  table measures as an 18× underestimate on this very table.
- It carries **two** such predicates (`clientId` and `itemdataId`), so the loss compounds.

**Verdict: §10.4 item 3 is correctly graded "probably, but measure on `stockunit` first."** It is a genuine
production defect and the plan is right not to fold it into this ticket. It is also right that the join may
dominate — I did not measure `stockunit`, and neither did the plan.

---

## 2. Round-1 items — resolution check

Verified by reading the cited section, not the revision log's claim about it. Resolved items are listed once
and not re-argued.

| Round-1 item | Landed? | Where I checked |
|---|---|---|
| **S1 / F1** split the predicate | **YES** — and graded above | §3.4's two methods; §3.6's two native methods; §5.2 P2 and P3 checklists |
| **S2 / F2** assert `UNIQUE (client_id, item_nr)` in `V2.2.33` | **YES**, on the **column set** as required, with `constraintIsAsserted` + a mutation row + prereq 8 | §7.2, §7.8, §5.1 row 8, §5.2 P1 |
| **F3** a drifted view has no runtime detector | **YES** | §5.1 row 8 states `ddl-auto=none` ⇒ *"a **drifted** view has no runtime detector at all"* |
| **F4** `SDR_WRITE_WITHDRAWN` is required, not parity | **PARTIAL — see A-R2-3** | fixed at §0.1 row 6, §3.5 (line 791), §4 (line 1244); **missed at §7.5 row 5** |
| **F5** prd-alias blind spot | **YES, and better than I asked** | §3.2's ⚠ block; §5.1 row 1; §10.3 item 8; §7.7's last DDL row tells the operator not to use an alias |
| **F6** per-environment index cost | **YES** | §3.2's five-database table with the `÷2,884` column and the two unreachable ShipItEZ prd rows |
| **F7** SDR count in the cost model | **YES** | §3.2's count paragraph (0.6–1.7 s, two lanes); §7.7's timing row replaced with *"~1–2 s … dominated by the count"* and a concrete fail bar (3 s) |
| **F8** (recommended) "preserves that asymmetry exactly" | **TAKEN** | §6's *What Does NOT Change* now states the payload widening explicitly |
| **F10** (recommended) `@Id`'s condition | **TAKEN** | §3.3 rule 1 |
| **S3 / F9** phase boundaries + revert order | **YES** | §5.1 row 4 (P6-before-P2 = blank report, 404); §8 step 5 gates on `/api/public/version`; §8 rollback states **P6 reverts first** |

One substantiation worth adding, because F4's re-label now carries weight: `ReadOnlyPagingAndSortingRepository`
is 27 lines, `extends PagingAndSortingRepository<T, ID>, CrudRepository<T, ID>`, and suppresses only
`save` and `saveAll`. Its **own javadoc is wrong** — *"Overrides methods to disable save update and delete
operations"* — while no delete verb is overridden. That misleading javadoc is the reason a later reviewer would
trim the withdrawal as cosmetic, and it is the strongest single citation for F4. Worth quoting in §3.5.

---

## 3. NEW defects introduced or left open by the revision

### A-R2-1 — An empty page breaks the grid, and the filter makes empty pages routine · **HIGH** · §3.9, §7.2, §7.4, §7.7

**The repo states the mechanism in its own source.** `v2/wms2-web-ui`, `store/admin/group.js` at
`origin/develop`, SBDEV-3012's javadoc:

> *"`_embedded` is ABSENT, not empty, when Spring Data REST returns an empty collection."*

and its helper acts on it: `const embedded = payload && payload._embedded; if (!embedded) { return [] }`.

**The plan's store snippet does not.** §3.9 specifies, verbatim:

```js
context.commit('setReportItems', { reportItems: results._embedded.stockrecordView, totalItems: results.page.totalElements })
```

On a zero-row page that is a `TypeError` on `undefined`, caught by the existing `try/catch` in
`store/reports/stockUnit.js`, whose only handler is
`this.$toast.error('Error: Request failed due to a network or server issue. Please retry.')`. Because
`setReportItems` never commits, **the grid keeps showing the previous shipper's rows and the previous
`totalItems`** while the toolbar shows the newly selected shipper. Silent wrong data plus a toast that
misattributes it to the network — the same failure shape §3.6 correctly refuses to ship for the export.

**Why this ticket owns it rather than inheriting it.** The mechanism is pre-existing (today's
`results._embedded.stockrecord` has it), but today it is reachable only via a no-match keyword. This ticket
makes an empty page a **first-class product state**, and the plan's own §3.6 supplies the deterministic case:
`client.id = 0` / `System-Client` is in the unfiltered `allClients` dropdown on **5 of 5** reachable databases
and owns **0 `stockrecord` rows on hydra PRD**. Selecting it on prd is a guaranteed empty page. The same holds
for any newly-onboarded shipper and for every filter+keyword combination that matches nothing.

**Nothing in the plan can see it.** Deriving method — read all four test surfaces for a zero-row case:
`StockrecordViewRepositoryFilterIT`'s five cases all assert non-empty row sets (and are repository-level, so
they never see HAL at all); `StockrecordViewHalContextTest.idIsInTheHalBody` uses an **unfiltered**
`size=1`; §7.4's Jest spec asserts the emitted request, not the response handling; §7.7's manual System-Client
row is run on **dev**, where that client owns 16 rows — so the one environment the manual plan uses is the one
where the defect cannot reproduce. Blind spot: I did not execute the app, so I have not observed the toast; the
`_embedded`-absent premise is the repo's own documented finding plus the plan's own row counts.

**Required:** P6 reads rows through an absence-tolerant accessor (the `rowsOf(payload, rel)` shape in
`store/admin/group.js` is the repo's own precedent — it is a local `const` there, not exported, so P6 writes
the same three lines); add one `StockrecordViewRepositoryFilterIT` case for *"a client with zero rows returns
an empty page whose `totalElements` is 0"*; add one Jest case for a zero-row response; and add a manual row
selecting a shipper with no records. Cost: about six lines and three assertions.

### A-R2-2 — The filtered export's plan is unmeasured, and P1's re-measurement does not cover it · **MEDIUM** · §3.2, §5.2 P1

§3.2's post-index re-measurement task reads *"re-measure the **filtered first page**"* — the read path only.
The export is a new query shape on a path that pulls thousands of rows, and it is nowhere EXPLAINed in the
plan. Measured (§1.2), under `force_generic_plan` and **without** the composite index, it plans as

- `Parallel Index Scan using index_stockrecord_client_id`, `Index Cond: (client_id = $2)` — good, the fix works —
- **plus a `Sort (Sort Key: created DESC)`**, estimated `rows=559` against an actual of up to **873,021** for
  ARW: a ~1,560× underestimate, because a generic plan cannot use the literal.

`index_stockrecord_client_created` would remove that sort entirely. Whether the planner *chooses* it is decided
by the same 559-row estimate that is wrong by three orders of magnitude — a 559-row sort looks nearly free, so
the narrow index plus a sort may keep winning. **The open question is index *selection*, not index
*reachability*,** and §3.2's justification (*"a plain equality on a leading index column is an indexable
operator clause … so the `Index Cond` survives promotion"*) answers only reachability.

**Required:** extend P1's re-measurement bullet to record **both** shapes post-index — the read path's first
page and the export's `ORDER BY created DESC OFFSET/LIMIT` — and state explicitly that the export's acceptance
is "the `Sort` node is gone", not just "an `Index Cond` is present". This is one line in a checklist, not a
design change.

### A-R2-3 — F4's re-label missed its fourth copy · **LOW** · §7.5 row 5

§7.5 row 5 still reads *"`SDR_WRITE_WITHDRAWN` gains it for parity"*. §7.5 is the checklist an implementer
reads at test-writing time, which is exactly when the item would be trimmed. One word. Flagged as its own
finding only because this is the documented sibling-copy pattern: a claim fixed in three of four homes reads as
fixed.

### A-R2-4 — The two keyword predicates are duplicated verbatim with nothing pinning them equal · **MEDIUM** · §3.4, §7.2

The split copies the 5-column `CONCAT(...) LIKE ... or :keyword = ''` string into both `findByKeyword` and
`findByKeywordAndClient`. That is a **new** maintenance hazard created by the fix, and §3.10 already names the
change that will trip it: *"Widen the keyword search to `item_name` / `cl_name` … Needs its own design."*
Whoever does that will edit one method. The result is a grid whose searched column set depends on whether a
shipper is selected — shipper-dependent, silent, and invisible to every test in §7.2, because no test compares
the two methods against each other.

**Required:** one `StockrecordViewRepositoryFilterIT` case asserting keyword equivalence across the split — on
a fixture with exactly one client, `findByKeyword(k, …)` and `findByKeywordAndClient(k, thatClient, …)` return
the same ids, for a keyword that matches on a column other than the first. Asserted **by id** (these repository
tests commit). Cheaper alternative if preferred: extract the `CONCAT` clause to a single `String` constant and
concatenate it into both `@Query` values, so there is one copy. Either is acceptable; the current plan has
neither.

### A-R2-5 — §0.1 row 21 says "no edit needed" about a file that will not compile · **LOW** · §0.1 row 21, Revision log

Row 21's verdict column reads **"YES (no edit needed under the round-2 split)"**. §4 lists the same file as
**Modify**, and §7.3 extends it. The claim is true of the *stubs* and false of the *file*: all four tests'
act lines are `reportService.exportStockUnitRecord(mockResponse, 0, 100, "")` — four arguments — and §0.1 row 9,
§4 and the P3 checklist all have `ReportService.exportStockUnitRecord` gain `Long clientId`. `ReportControllerUnitTest`'s
existing `verify(reportService).exportStockUnitRecord(any(HttpServletResponse.class), eq(0), eq(100), eq("STOCK789"))`
is a fifth four-argument call site. Those are **compile** errors.

The same over-reach appears in the revision log: *"an in-place signature change would have been a compile break,
not a test failure"* — true of the repository method, but the **service** signature change is an in-place
signature change and it *is* a compile break, in the same four tests. Harmless in practice (it announces itself
in seconds) and it does not weaken the split, whose real justification is C-2's silently-emptied SDR route.
**Required:** correct row 21's verdict to name the stubs rather than the file, and drop the compile-break
sentence from the revision log's framing.

### Two nits, not findings

- §3.9 adopts the sibling's rule 2 as *"Append from state, **for both branches**"* and then shows code that
  appends `&clientId=` only on the filtered branch. The code is right; the rule statement reads as if the
  unfiltered route should carry it too. Harmless either way (SDR ignores an undeclared query param), but the
  two sentences disagree.
- §3.2's plan-mode table should use the **composed** predicate (§1.1), not the isolated `client_id = $1`
  conjunct, so the table grades the query the code issues.

---

## 4. Re-grading the round-1 tensions

**T1 — "stay on SDR" vs "the index is the feature": RESOLVED.** The split removes the plan-mode bet entirely,
and I verified it on the composed predicate on both paths (§1.1, §1.2). The resolution is stronger than I asked
for, because the revision went and measured the sibling convention rather than merely diverging from it (§1.5)
— which converts "a reviewer preferred this" into "the convention is measurably wrong here, and here is the
follow-up ticket for the convention". That is the right shape.

**T2 — the unique-index dependency: MITIGATED, not resolved, and the residual should be stated.** The `DO $$`
assertion converts a silent correctness cliff into a loud failure **at migration time**. It does nothing about
a constraint dropped *after* `V2.2.33` has run, and prereq 8's `pg_constraint` check is a one-time post-deploy
action, not a standing detector. That residual is inherent — as I said in round 1, a self-defending view
(`DISTINCT ON`, `LATERAL … LIMIT 1`) is exactly what would destroy the join elimination, so the plan is right
to take the elimination. **Recommended, not blocking:** one sentence in the `V2.2.33` header saying the
assertion is a migration-time gate and the invariant is undetected thereafter, so a future reader knows the
guarantee's expiry.

**T3 — P2/P6 as a cross-repo pair: RESOLVED in text, exactly as S3 asked.** Prereq 4 carries the missing
P6-before-P2 row, §8 step 5 gates on `/api/public/version`, and the rollback states P6-first. I have no
remaining objection. Note that A-R2-1 is a separate failure of the *same* shape — a silently-wrong screen
rather than an error — and the plan's instinct for that shape is otherwise excellent.

---

## 5. Is a 1,985-line plan still implementable from?

**Yes, but only because §5.2 is a good spine — and it is now carrying about 150 lines of dead weight I would
cut.** Section sizes (`awk` over `^## ` headings):

| section | lines |
|---|---|
| §3 Design | **936** |
| §7 Testing | 217 |
| §2 Current Architecture | 115 |
| RALPLAN-DR | 111 |
| §10 Open Questions | 108 |
| §0 Affected Sites | 93 |
| §5 Phases | 91 |
| §9 Alternatives | 70 |
| Revision log | 56 |

The implementable core is §5.2's six checklists (91 lines), each item pointing at a §3 subsection. An
implementer who works from §5.2 and reads only the §3 subsections it names will build the right thing. That is
the test the plan passes.

What I would cut, concretely:

1. **The inline round-2 narration — the single biggest readability tax.** `grep -c` finds **64** occurrences of
   "round 2 / round-2". At least eight are multi-paragraph "what the previous draft said, and why it was wrong"
   passages inside §3 — §3.4's opening ⚠, §3.2's *"what plan mode that 0.455 ms belongs to"*, §3.6's
   `ClassCastException` correction, §7.5 row 4's `StockView` field recount, §7.8's *"Four rows were repaired"*.
   That is review history, and it belongs in the Revision log, which already summarises every one of them.
   Keeping both forces the implementer to separate "what to build" from "what an earlier draft said". **~120–150
   lines, and it is the cut that most improves the plan.** Keep the *corrected content*; delete the narration of
   the correction.
2. **RALPLAN-DR (111 lines).** Consensus-process artefact — principles 3–6, the top-3 drivers, the viable
   options. Nothing in §5.2 points at it. Move it to `SBDEV-3410-evidence/`.
3. **§2 Current Architecture (115 lines).** Re-derivable from the code in minutes and largely restated inside
   §3 where it is load-bearing. Halve it; keep §2.1 (why there is no controller) and §2.4 (the `StockView`
   precedent), which §3 genuinely depends on.

That is ~330 lines out, leaving ~1,650 with **no measurement and no instruction removed**. I would not cut §7,
§10.3 or §0 — §10.3's blind-spot register and §0's affected-site table are what make the rest checkable.

---

## 6. What still blocks

1. **A-R2-1 (HIGH)** — absence-tolerant `_embedded` read in P6, plus a zero-row case at the IT, Jest and manual
   layers. The dev manual test cannot reproduce it; hydra prd deterministically can.
2. **A-R2-2 (MEDIUM)** — P1's post-index re-measurement must cover the **export** shape, with "the `Sort` node
   is gone" as its acceptance, not just "an `Index Cond` is present".
3. **A-R2-4 (MEDIUM)** — pin the two keyword predicates equal (one IT case), or extract the `CONCAT` clause to
   one constant.
4. **A-R2-3 (LOW)** — §7.5 row 5: "for parity" → "required" (one word; F4's fourth copy).
5. **A-R2-5 (LOW)** — §0.1 row 21's verdict, and the revision log's compile-break sentence.

Recommended, not blocking: §3.2's plan-mode table should use the composed predicate (§1.1); record §1.4's
verification so the `enable_seqscan = off` control is not removed as unproven; one sentence in the `V2.2.33`
header on the T2 residual; the §3.9 "both branches" wording.

---

## 7. Method and blind spots for every completeness word above

- **"Both paths are fixed" / "no `OR` arm survives"** — derived by reading the four predicates the plan writes
  down (§3.4 ×2, §3.6 ×2) and classifying each disjunct by whether it references the table, then measuring the
  two composed forms under `force_generic_plan` with paired controls. Blind spot: `force_generic_plan` proves
  the plan *shape* under a generic plan; it does not prove the app reaches one (`plan_cache_mode` is `auto`).
  And a predicate written during implementation is outside any review's reach.
- **"All seven required changes landed"** — checked one at a time by reading the cited section of the plan, not
  by trusting the revision log's row. Blind spot: I verified presence and correctness of the text, not that
  every downstream artefact it implies was updated — A-R2-3 is precisely the case where it was not, found by a
  `grep -n "parity"` sweep rather than by reading.
- **"5 of 5 reachable databases" / hydra prd row counts** — these are the plan's figures, which I verified in
  round 1 and did not re-verify here. The prd-alias collapse (three aliases → `wh01_hydra_v2`) is my own round-1
  measurement, now correctly carried in §3.2 and §10.3.
- **"Nothing in the plan exercises a zero-row result"** — enumerated all four test surfaces (§7.2's twelve IT
  rows, §7.3's nine unit rows, §7.4's Jest spec, §7.7's seventeen manual rows) and checked each for an
  empty-result assertion. Positive control: the same sweep finds the System-Client case in three of the four
  surfaces, so the instrument does find filter-value cases when they exist. Blind spot: I did not run the app,
  so the toast behaviour is derived from `store/reports/stockUnit.js`'s `catch` plus SBDEV-3012's documented
  `_embedded`-absent finding, not observed.
- **"64 round-2 mentions", section line counts** — `grep -c` and an `awk` pass over `^## ` headings on the
  1,984-line file. Exact for those patterns; a correction narrated without the words "round 2" is not counted,
  so 64 is a floor.
- **`ReadOnlyPagingAndSortingRepository` suppresses only `save`/`saveAll`** — read the whole 27-line file at
  `origin/develop`. No blind spot at that size.
- **Timings/estimates** — single runs on a shared box; row *estimates* and plan *shapes* are what I rely on,
  and both are structural. Absolute milliseconds will not port to another tenant.
