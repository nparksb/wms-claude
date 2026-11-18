# SBDEV-3952 — Architect review, ralplan round 1 (2026-10-30)
Reviewer: oh-my-claudecode:architect (opus), independent lane. Saved by the main session because subagent writes are blocked.

**Verdict:** approve with 1 High, 2 Medium, 3 Low.

## Verified OK
- **CREATE OR REPLACE is legal.** Live types from dev `pg_attribute`: row_id bigint, five varchar(255), six numeric(-1), text, boolean. `round`/`sum` over numeric(17,4) give numeric(-1). `stock_unit_id` is bigint.
- **Dropping the old ORDER BY and GROUP BY is allowed.** REPLACE swaps the whole rewrite rule. 0 dependent views.
- **No caller relies on the view-level ORDER BY.** The list endpoint uses PagedListSort with LIST_KEY; the export has an explicit ORDER BY.
- **`ddl-auto=validate` runs in the test profile only** (main is `none`). A nullable Long that is not the id is fine.
- **`row_id` @Id is safe.** Each page or export chunk is its own persistence context (OSIV off, one repository call per request), so there is no dedupe.
- **The Page count query is derived** (no countQuery) and unaffected.
- **The subquery uses the index.** Dev EXPLAIN shows `Index Scan using idx_replenishorder_state_destination`, Index Cond `(state < 600) AND (destination_id = loc.id)`. That is a range on the leading column. Latency is dominated by seq scans of stockunit/unitload.
- **V2.2.43 is free.** It is unclaimed on every remote ref.
- **The only external consumer** is wms2-web-ui `store/reports/flowbin.js:62`. 0 hits in mobile-ui and oms.

## Findings
- **F1 (High): uniqueness depends on today's data, not the structure.** k empty unitloads on one flowbin give k identical `(location_name, NULL)` rows. The old GROUP BY merged them; the new view emits duplicates, so LIST_KEY and the export order are not total (the SBDEV-3947/3951 bug). Dev: empty_ul_on_flowbin=1 (05-C09), any_loc_2plus_ul=343, ul_2plus_su=307,090, flowbins_2plus_ul=0. **Fix:** append `ul.id AS unitload_id` as ordinal 16. Key `(location_name, unitload_id, stock_unit_id)`. Add an IT with two empty ULs on one flowbin. Alternative: nested `(ul JOIN su)`, about +40% latency.
- **F2 (Medium):** test 2's seed shape (one UL or two?) is unpinned. Test 7 is non-deterministic. Add a deterministic `count(*) = count(DISTINCT key)` assertion.
- **F3 (Medium):** the per-flowbin value repeats on each SU/UL row, empty-UL rows included. Excel totals are not additive. Put this in Risks and the release note.
- **F4 (Low):** §3.2 wording. The latency gain comes from removing GROUP BY, not from the index.
- **F5 (Low):** the rollback text must list the exact grants to restore (PRD: `wms2_landlord_app=arwd`).
- **F6 (Low):** in the §0/§4 web UI references, cite `store/reports/flowbin.js:62` and `components/reports/flowbinReport.vue`. `item-key="key"` is client-side, so duplicate rows would not crash the UI.

## Consensus addendum
- **Antithesis:** removing the GROUP BY changes the view's grain in a way nobody sees. A pre-aggregated derived table, `LEFT JOIN (SELECT destination_id, sum(round(requestedamount)) s FROM replenishorder WHERE state<600 GROUP BY 1) rr ON rr.destination_id = loc.id`, is fan-out-proof, can be hash-joined, and has no correlated subquery.
- **Tension:** the view's grain (per SU/UL) and the column's grain (per flowbin) now differ by design. A total order and additive totals pull against each other.
- **Synthesis:** keep A's no-GROUP-BY shape; either the subquery or the derived table is fine. Make the grain explicit with `unitload_id`, and document that totals are not additive.
