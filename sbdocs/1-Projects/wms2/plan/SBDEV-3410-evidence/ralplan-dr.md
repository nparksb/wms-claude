# SBDEV-3410 — RALPLAN-DR (decision record)

Moved out of the plan document in round 3 (nothing in §5.2 points at it; it is a consensus-process
artefact, not an implementation instruction). The plan cites it as
`SBDEV-3410-evidence/ralplan-dr.md`. Content is verbatim from the round-2 plan, except that Principle 5
gains the round-3 entry.

---

### Principle 3 — Decide at the level of the invariant, not the instance

Three places in this plan fix a **rule** rather than a symptom, because the instance-level fix is what rots:

- **§3.8** — the `allClients` gate is not "add one more constant"; it is *"every screen carrying a shipper
  dropdown contributes its view function to `allClients`."* The eleven-entry list and the "13 dispatchers /
  six reports / ten screens" comments in both `ClientController` and `Sbdev3017TrancheGateContextTest` are
  prose enumerations that were already drifting before this ticket, and the plan restates them as the rule
  instead of incrementing three numbers. ⚠ **Round 2 — in round 1 this principle was asserted here and then
  applied to the instance only.** The same sweep that finds Stock Unit Record finds Handling Units, which
  violates the rule **today**; P5 now takes the list from eleven to **fourteen**. A principle stated in the
  document and not applied in the document is worse than no principle, because it reads as coverage.
- **§3.6** — the `client.id = 0` fix is not "fold this one binding"; it is *"every absence check on
  `clientId`/`filter` on this path is `== null`, never truthiness"*, applied by sweeping all ten sites in
  both repos and giving each a verdict, including the three that are out of scope (§10.4).
- **§3.3 rule 4 / §7.2 `everyUiSortKeyResolves`** — the nine sortable columns are asserted by reflection over
  one source-of-truth list, not by nine hand-written cases.
- **§7.5 row 4** — "annotate these six fields" is stated as a *derivation* plus the IT that proves it, because
  a list of six names in a plan document cannot catch the seventh field someone adds next quarter.

### Principle 4 — A guard fences the mechanism you aimed at

The performance guard here is the composite index, and it fences exactly one mechanism: the `client_id`-filtered
`ORDER BY created DESC` first page. It does **not** fence the other producer of a slow page — an
`ORDER BY item_name` sort — which is why Q4's `sortable: false` is recorded explicitly as **policy with no
technical enforcement**: SDR passes `&sort=` straight to JPA, so a hand-typed URL reaches the unguarded
mechanism. Enumerating both producers is what stops the plan from claiming a guarantee it does not have.

### Principle 5 — A zero needs a positive control

Four zeros carry this design, and each has one: 0 multiplied rows (control: the poisoned join predicate still
returns 9,726,795); 0 unresolvable SKUs (same control); 0 users blocked by the `allClients` gate (control: the
same query with a non-existent function returns 45, and a count of holders of a fake function returns 0); 0
`@Formula` occurrences in `src/main/java` (control: the same sweep for `@Column` hits 65 model files). Two of
those zeros — unresolvable SKUs and blocked users — **agree with the comfortable conclusion**, which is exactly
when a broken instrument is hardest to notice, and both are the reason §7.2's fixtures must *construct* the
rows that real data does not contain.

⚠ **Round 2 — a fifth zero was in the document, uncontrolled, and false.** *"`0` is not among them"* (§3.6, on
`client.id`) was stated **with** its deriving query and **without** a control, and it is wrong: `min(id)` is
`0`, `System-Client`, present on 5 of 5 reachable databases including prd. It also agreed with the comfortable
conclusion — that no code change was needed — which is the exact condition this principle names. The lesson is
not "add a control to that query"; it is that **the principle was applied to the zeros the author was already
worried about, and the dangerous zeros are the other ones.** The controls now in the document for the round-2
measurements: no negative client id (control `id > 0` → 158); `hypopg` unavailable (control: 61 available
extensions); `stockrecord_view` absent per tenant (control: `stock_view` → 1 from the same query).

### Principle 6 — a measurement belongs to the plan mode it was taken in

New in round 2, because it is the finding that changed the design. §3.2's `0.455 ms` and §3.4's original
three-valued predicate were both correct and mutually contradictory: the figure was taken with a **literal**,
the predicate is executed with a **bind parameter**, and pgjdbc reaches a generic plan on its own after five
executions. A number carried across that boundary is not a slower number, it is a **different plan** — here,
the difference between an `Index Cond` and a `Parallel Seq Scan` over 9.7 M rows, i.e. between the feature
working and the 276 MB index being dead weight. The repo had already written this lesson down once, in
`FixLocationAssignmentRepository`, and this plan cited that file for a different reason while walking into the
same trap. **Every performance figure in this document now names its plan mode.**

### Top 3 decision drivers

1. **SDR cannot render collections of interface projections** (SBDEV-3417, `b20eb9f1`). This is what forces a
   real relation, and therefore a Flyway migration, and therefore T3. Everything else follows from it.
2. **The filter is a performance regression without its index, and the predicate decides whether the index is
   reachable at all.** 300–900× slower first page without the index, measured — and measured again under a
   generic plan (1,936 ms, same `Rows Removed by Filter: 7,564,825`), so it is not a custom-plan artefact. The
   index is not an optimisation attached to the feature; it is part of the feature — and a three-valued `OR`
   predicate makes it unreachable, which is why §3.4 ships two methods rather than one.
3. **Join elimination is load-bearing and fragile.** `LEFT` + `UNIQUE (client_id, item_nr)` + touching no
   joined column in `WHERE` is what keeps the unfiltered default at today's cost. Three separate plausible
   "improvements" — `INNER JOIN`, a wider keyword `CONCAT`, a sortable SKU Name — each break it, and each
   breaks it silently, in a direction no test against real data would catch.

### Viable options

**Option A — `stockrecord_view` + `@Entity StockrecordView`, endpoint stays on SDR. (CHOSEN)**
*Pros, bounded:* keeps the UI's SDR paging/sorting contract byte-identical; mirrors an existing, working
precedent (`stock_view`/`StockView`); the default unfiltered page is measurably unchanged (+1% to +5%, inside
noise); the export stays a base-table query so the 15-column contract cannot drift by accident.
*Cons, bounded:* a Flyway migration (irreversible per tenant once applied, with a schema-level ownership risk
and a one-time write stall — ~6 s on dev, milliseconds on the one reachable prd tenant, unmeasured on two);
**two** externally-visible SDR routes rather than one, both inheriting the existing *unruled* authorization
posture and both widening the payload an unruled reader sees (§3.5); six entity fields whose correctness
depends on explicit `@Column` annotations — covered repo-wide by `EntityColumnNameResolutionArchTest`, with
the new schema IT closing the "validator stops at the first mismatch" gap; and a row-count guarantee that
rests on an external constraint the migration now asserts rather than assumes.

**Option B — hand-written MVC endpoint returning a DTO page.**
*Pros, bounded:* no migration; `toFilterId` usable on the read path; the endpoint is function-gatable, closing
the SDR-unruled asymmetry as a side effect.
*Cons, bounded:* abandons SDR paging/sorting, so `_embedded` / `page.totalElements` / `&sort=` handling is
re-implemented by hand — a larger UI diff than everything else in this ticket combined; diverges from the six
sibling reports; adds a gated endpoint needing two new gate-pin rows and a `FunctionEnum` decision.
**Not invalidated — genuinely viable, and rejected on cost and consistency, not on impossibility.** It is the
right option if the SDR authorization gap is ever taken up as its own ticket.

**Option C — `@Formula` on `Stockrecord`. INVALIDATED.**
The product-name half would work, but the shipper-filter half gets *worse*: a correlated subquery per row is
unindexable as a sort key and never produces the `client_id` predicate that turns 2,865 ms into 0.455 ms. Zero
precedent in `src/main/java` (positive-controlled). Invalidated on measurement, not taste.

**Option D — interface projection. INVALIDATED, with a commit behind it.**
SBDEV-3417 (`b20eb9f1`, on `develop`) proved SDR cannot render a collection of interface projections, and
`Page` is not exempt (`Page extends Slice extends Streamable extends Iterable`). It returns 200 on an empty
result and 500 on any matching row — passing every test written against an empty fixture. This is the option
that would have been chosen by default, and the reason the invalidation is recorded here rather than left
implicit.
