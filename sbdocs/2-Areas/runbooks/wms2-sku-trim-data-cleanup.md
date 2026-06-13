---
title: "Runbook: SKU Trim Data Cleanup — itemdata item_nr/name whitespace normalization (WMS v2)"
type: runbook
status: active
version: "wms2-api (Java 21, Spring Boot 3.x, PostgreSQL)"
scope: "v2/wms2-api tenant DBs — itemdata.item_nr / itemdata.name trailing-whitespace cleanup (Phase 2 of plan 260610)"
owner: "nam.park@siteboss.net"
created: "2026-06-11"
updated: "2026-06-11"
last_verified: "2026-06-11"
verified_by: "nam.park@siteboss.net"
alert: "Duplicate SKU rows differing only by leading/trailing whitespace (FreeScout #959); padded lookups missing existing items"
severity: "SEV3 (scheduled data-quality operation, not incident response)"
escalation: "WMS on-call engineer → Nam Park (plan owner)"
related:
  - "[[260610-wms2-sku-trim-normalization]]"
tags:
  - runbook
  - wms2
  - sku-sync
  - data-quality
  - data-repair
---

# Runbook: SKU Trim Data Cleanup (WMS v2, per tenant DB)

**Purpose:** Phase 2 of `[[260610-wms2-sku-trim-normalization]]` — clean existing untrimmed
`itemdata.item_nr` / `itemdata.name` values and resolve whitespace-duplicate SKU pairs, per tenant DB.
**Run AFTER (or choreographed with) the Phase 1/1b code deploy — see §3 sequencing.**

---

## 1. When to Use This Runbook

- Rolling out plan 260610 (SKU trim normalization) to a tenant environment (dev → qa → prod).
- OMS reports a SKU "already exists" / "not found" mismatch traced to leading/trailing whitespace.
- A whitespace-duplicate `itemdata` pair is discovered (same trimmed `item_nr`, one padded row).

**Do NOT run the trim UPDATEs (§5) before resolving collision pairs (§4) — the UPDATE would
violate identity uniqueness expectations and can leave two identical `(client_id, item_nr)` rows.**
(There is no DB unique index on `(client_id, item_nr)` today; the trim UPDATE on an unresolved
collision pair would create two *exactly* identical item numbers.)

## 2. Known State (DB-verified 2026-06-10, dev)

| Tenant DB | `item_nr` untrimmed | `name` untrimmed | Collision pairs |
|---|---|---|---|
| wineco-dev2 | 3 / 10,369 | 1,839 | 0 |
| hydra-dev2 | 1 / 2,720 | 174 | 1 — `[BONMFPN23 ]` id 1919451 vs `[BONMFPN23]` id 1927641 (padded row had zero stock/order/advice refs as of 2026-06-10 — re-verify at execution) |

Production counts are **indicative only from dev** — always re-run the census (§4.1) fresh per
environment before any change.

## 3. Sequencing Choreography (authoritative — plan §5 Phase 1b)

Phase 1 (write-boundary + `findByClientIdAndItemNr` trim) and Phase 1b (`loadItemDataSet` set-lookup
trim) ship in the same build. Per tenant:

1. Run the collision census (§4.1) on the tenant.
2. **Zero collision pairs** (e.g., wineco as of 2026-06-10): deploy Phase 1+1b and run the trivial-trim
   UPDATEs (§5) in any order — there is no duplicate pair to mis-resolve.
3. **Collision pairs present** (e.g., hydra `BONMFPN23`): resolve the pair(s) per §4 **before** deploying
   Phase 1+1b to that tenant (or deploy during a maintenance window with order-resolution traffic
   quiesced, run cleanup, then resume). The trimmed set-lookup must never serve order traffic against
   an uncleaned duplicate pair — it would silently resolve to the wrong row instead of failing loudly.

## 4. Collision Resolution (before any UPDATE)

### 4.1 Discovery + collision census

```sql
-- Discovery: how dirty is the data?
SELECT count(*) FILTER (WHERE item_nr <> trim(item_nr)) AS itemnr_untrimmed,
       count(*) FILTER (WHERE name    <> trim(name))    AS name_untrimmed,
       count(*)                                          AS total_rows
FROM itemdata;

-- Collision census: padded rows whose trimmed value collides with an existing trimmed row
SELECT a.id  AS padded_id,  a.client_id,
       quote_literal(a.item_nr) AS padded_item_nr,
       b.id  AS trimmed_id, quote_literal(b.item_nr) AS trimmed_item_nr
FROM itemdata a
JOIN itemdata b
  ON  b.client_id = a.client_id
  AND b.item_nr   = trim(a.item_nr)
  AND b.id       <> a.id
WHERE a.item_nr <> trim(a.item_nr);
```

Record both outputs in the execution log (§7).

### 4.2 Reference check per collision pair

For each `padded_id` from §4.1 (replace `:id`):

```sql
SELECT (SELECT count(*) FROM stockunit              WHERE itemdata_id = :id) AS stockunit_rows,
       (SELECT coalesce(sum(amount),0) FROM stockunit WHERE itemdata_id = :id) AS stockunit_amount,
       (SELECT count(*) FROM customerorder_position WHERE itemdata_id = :id) AS order_positions,
       (SELECT count(*) FROM adviceposition         WHERE itemdata_id = :id) AS advice_positions;
```

### 4.3 Resolution

- **Zero references** → delete the padded row:
  ```sql
  BEGIN;
  DELETE FROM itemdata WHERE id = :padded_id AND item_nr <> trim(item_nr);
  -- expect: DELETE 1
  COMMIT;
  ```
  (Confirm at execution whether an inactive/soft-delete flag convention exists and is preferred —
  plan §10 open question; as of 2026-06-11 hard delete is the expected path for zero-ref rows.)
- **References present** → STOP; manual merge decision required (re-point `stockunit`,
  `customerorder_position`, `adviceposition` rows to the trimmed row, then delete the padded row).
  Expected to be rare. Escalate to the plan owner before proceeding.

Known dev pair: hydra-dev2 `BONMFPN23` — padded row id **1919451** deletable (zero refs as of
2026-06-10; **re-verify with §4.2 at execution**).

## 5. Trivial Trim UPDATEs (only after §4 clears collisions)

**Gate (all three before any UPDATE):**
- [ ] Tenant DB backup/snapshot confirmed restorable (rollback path = restore).
- [ ] Fresh collision census (§4.1) run on THIS environment; output recorded.
- [ ] All collision pairs resolved per §4.3.

```sql
BEGIN;

-- capture before-counts
SELECT count(*) FILTER (WHERE item_nr <> trim(item_nr)) AS itemnr_untrimmed_before,
       count(*) FILTER (WHERE name    <> trim(name))    AS name_untrimmed_before
FROM itemdata;

UPDATE itemdata SET item_nr = trim(item_nr) WHERE item_nr <> trim(item_nr);
UPDATE itemdata SET name    = trim(name)    WHERE name    <> trim(name);

-- after-counts: both MUST be 0
SELECT count(*) FILTER (WHERE item_nr <> trim(item_nr)) AS itemnr_untrimmed_after,
       count(*) FILTER (WHERE name    <> trim(name))    AS name_untrimmed_after
FROM itemdata;

COMMIT;  -- or ROLLBACK if after-counts are non-zero / row counts diverge from the census
```

## 6. Acceptance & Post-checks

- Discovery query (§4.1) returns **0 / 0** untrimmed for both columns on the cleaned tenant.
- Collision census returns zero rows.
- Spot-check: padded `/rest/sku/update` re-send (e.g., `"sku": "BONMFPN23 "` on hydra dev) updates
  the existing row — no new `itemdata` row appears.
- Cache note: itemdata cache entries self-heal — every SKU sync write evicts the whole `itemdata`
  cache (`@CacheEvict(allEntries = true)`), and reads have a bounded TTL. No manual cache flush needed.

## 7. Execution Log

| Date | Environment / tenant DB | Operator | Census (item_nr/name untrimmed, pairs) | Pairs resolved | Trim UPDATE rows (item_nr/name) | After-counts | Notes |
|---|---|---|---|---|---|---|---|
| 2026-06-10 | wineco-dev2 (census only) | nam.park | 3 / 1,839 · 0 pairs | n/a | not yet run | — | plan §2.3 baseline |
| 2026-06-10 | hydra-dev2 (census only) | nam.park | 1 / 174 · 1 pair (BONMFPN23) | not yet | not yet run | — | padded id 1919451 zero refs |
