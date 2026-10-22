---
ticket: SBDEV-3736
lane: critic (independent review)
round: 3
date: 2026-10-15
reviewed: sbdocs/3-Resources/reports/261013-returns-audit-linkage-field-map.md (+ lane-wms.md §4, db-wineco-prd.md)
code: wms2-api origin/develop 371d8a09 (report pins 11468c4a) · oms-laravel-api origin/develop 4981db86 (report pins 1369c109) — git show / git grep only
db: wsl-wineco-prd, read-only, 2026-10-15
---

# SBDEV-3736: critic review, round 3 (the R2 fix edits)

**VERDICT: REVISE (narrow).** All seven R2 fixes landed. Six are fully correct. The headline (no schema change)
and the measured numbers behind the R2 fixes re-verify on PRD today. **I found no false data claim.** What's left
is consistency in the §8 tier text and stale sibling text in the lane file:
- R2-4 introduced a new S3 tier contradiction.
- The T2 condition asks for a WMS-only deliverable that contains a flag needing OMS data.

Mode: THOROUGH throughout. I found no CRITICAL, fewer than 3 MAJOR-equivalent and no systemic pattern, so I did not escalate.

## R2 findings: status

| # | Status | Verification |
|---|---|---|
| R2-1 recordtype filter | **RESOLVED** | lane-wms §4 SQL keys `activitycode = 'RETURN'` with no recordtype filter. I re-ran the exact SQL on PRD: **10,173 position rows, 0 NULL destinations, 0 without a UL**. The picked-row recordtype by year matches §5.3: 2025 is CREATED 2,102 / TRANSFERRED 235, and 2026 is CREATED 177 / TRANSFERRED 932. 2020–2024 are all TRANSFERRED. That gives 2,279 via CREATED, which matches §5.3, §7 row 8 and §11. §6 H1 no longer says "v1-era data agrees". |
| R2-2 dock-finish false claim | **RESOLVED** | The sentence is gone, and §5.8 states the only-`markFinished` rule. Code on current origin/develop matches. `AdviceService:314-315` makes `close()` reject non-REGULAR. `:267` and `:432` are the HUB_AND_SPOKE and TRANSFER accept paths. `ReceivingService` writes only `OPEN` (`:224`, `:257`, `:309`). SDR `POST /v3/advice` state overwrite is withdrawn (`RestConfiguration` `configureAdviceCollectionCreateWriteExposure`). The SBDEV-2236 citation is correct: archived plan `:270` says "Option A … RETURN advice stays in OPEN until mobile operator scans at the dock". PRD: 2,822 RETURN advices, all FINISHED. S8 is added and §9 carries it. |
| R2-3 performance / index | **RESOLVED** | The reference SQL is set-based (`DISTINCT ON`). It ran all-time within the MCP timeout today. The "`created` bound is instant" claim is gone. §8 removes the index as a T3 trigger. |
| R2-4 §5.5 tier wording | **PARTIAL** | §5.5 ("**T2**"), §7 row 8 ("code change (T2)") and §8 now agree on §5.5. However, the §8 T2 bullet now reads `"The §5.5 final-bin change and S3 stay T2"`, while the side-findings table lists **S3 = T1** and round-1 F6 kept S3 at T1. The fix created a new contradiction for S3. See R3-2. |
| R2-5 per-UL key | **RESOLVED** | The SQL joins `ur.label = regexp_replace(u.labelid, '-X-[0-9]+$', '')` and uses `DISTINCT ON (ordernumber, label)`. §5.3 says the same. Adding the label key costs no coverage (10,173/10,173), so the regex matches every relabel on PRD. There are 0 `(ordernumber, label)` groups with more than one row, so `DISTINCT ON` hides no ambiguity. |
| R2-6 NULL disposition | **RESOLVED** | §5.10 uses `r.managed = 0 OR r.disposition IS NULL OR NOT EXISTS (… advises_wms = 1)`. The column names check out against `tenant-baseline.sql`: `returns.managed tinyint(1) NOT NULL DEFAULT 0`, `disposition int NULL`, `return_mgmt_lut.return_mgmt_lut_id`, `advises_wms`. Seed: id 2 "Restock Inventory" has `advises_wms = 1`. |
| R2-7 routing citation | **RESOLVED (differently, and better)** | The author did not cite `:296` as the basis. Instead, decision 6 says the policy default is *on this ticket*: added scope is tiered on its own (`:295`), each item is sub-T3, the ticket is Open, and `:314` says "do not invent other reasons to split". The table and §8 bullets follow that default. I accept this over my own R2-7. SBDEV-3736 was **filed** multi-repo ("[WMS v2 + OMS v2]"), so adding OMS-repo scope is not a multi-repo *addition*, and `:296` does not bite. Splitting is correctly framed as Nam's trade. |

Totals: **RESOLVED 6 · PARTIAL 1 (R2-4) · OPEN 0**.

## New findings

### R3-1 (Medium). The §8 T2 condition requires a WMS-only deliverable that includes the §5.10 mismatch flag, but that flag cannot be computed WMS-only
- **Location:** §8 T2 bullet: `"T2 if the deliverable is a WMS-only audit query/report (option 1 or 3 below) built on the corrected §7 joins plus a mismatch flag for §5.10"`. It conflicts with decision 3 option (1), `"WMS report, OMS fields blank"`, and with §5.10, which says the flag needs OMS `returns.managed` / `disposition`, an OMS tenant DB that WMS cannot read (`"no lane has OMS DB access"`).
- **Why it matters:** decision 5 calls the flag "the most valuable part of the deliverable". As written, the T2 path promises it in a surface where it cannot exist. Building it into any product surface needs OMS data inside WMS (a new contract) or the OMS screen (option 2), and both are the multi-repo T3 shapes. Nam would pick T2 expecting the flag and not get it.
- **Fix:** say the flag exists at T2 only as an **ad-hoc two-step support query** (option 3): export the WMS parcel_id list, then run the §5.10 OMS query. A WMS report under option 1 cannot carry it. Any built-in flag puts the work at option 2 / T3. Mirror this in decision 5.

### R3-2 (Low). §8 says "S3 stay T2". The side-findings table says S3 is T1
- **Location:** §8 T2 bullet vs side-findings row S3 (`T1`).
- **Evidence:** round-1 F6 kept S3 at T1 and raised only §5.5 to T2. R2-4 concerned §5.5 only. The edit made for it swept S3 into "stay T2", a state S3 was never in.
- **Fix:** write "The §5.5 final-bin change stays T2 (report-contract change, one repo); S3 stays T1 plus the V2.2.25 IT update". Alternatively, raise S3 to T2 in the table, giving the reason that it also changes `transaction_detail()` output. Pick one and make both places agree. The tier changes the floor: T2 adds an architect consult.

### R3-3 (Low). Sibling text in lane-wms.md still asserts the pre-R2 shape, and the "ran this shape" claims refer to older shapes
- **Location and evidence:**
  - `lane-wms.md` §0 item 4: `"The TRANSFERRED row has activitycode RETURN, ordernumber = …"`.
  - §4 table row 8: `"unitload_record row recordtype='TRANSFERRED'"`. This sits in the same §4 that the report cites as "corrected".
  - Under the SQL: `"[F] I ran this shape … against UAT advice 35074049"`. That run used the original label-join shape, two revisions ago.
  - Report §11 row 5 ("Corrected reference join on `IBOL014975` + `IBOL015569`") describes the R1 shape (ordernumber + TRANSFERRED), not the current SQL.
- **Note:** I ran the current SQL today (see the DB checks below) and it is correct, so no number is wrong. What's stale is the *attribution* of the runs.
- **Fix:**
  - Annotate §0 item 4 and §4 row 8 with "TRANSFERRED or, in 2025-26, a second CREATED row (R2-1)".
  - Reword the `[F]` line to say which shape was run where.
  - Add a §11 row: "Current set-based reference SQL (lane-wms §4), PRD all-time, 2026-10-15: 10,173 rows, 0 NULL destination, 0 multi-row (ordernumber, label) groups".

### R3-4 (Low). The §5.10 divergence query is not scoped to the oms-laravel-api cohort
- **Location:** §5.10 query `r.parcel_id IN (<parcel ids from WMS RETURN advices>)`, versus §5.7's own limit: "does **not** cover (i) the 2,689 historic advices sent by the v1 OMS / qa-api path".
- **Why it matters:** for v1-era advices, `managed = 0` or a NULL / non-`advises_wms` disposition does not signal the §5.10 non-atomicity. The v1 sender never ran `updateReturnManagement`, and `advises_wms` was only bootstrapped in 2026-07 (`2026_07_24_100000_add_advises_wms_to_return_mgmt_lut.php`). If the input is every WMS RETURN advice, a historic population may show up as "divergent" and inflate the count that decision 5 hinges on.
- **Confidence:** MEDIUM. I have no OMS DB access to measure how v1-era returns look in the v2 OMS `returns` table.
- **Fix:** feed the query only parcel_ids from advices created after the tenant's OMS v2 / WMS v2 cutover (WineCo: `advice.created > 2026-09-26`, 22 advices). Alternatively report the two cohorts separately.

### R3-5 (Low). Stale bookkeeping lines
- §10: `review-critic.md (independent review, 12 findings)`. There are now 19 findings over two rounds, plus this round 3 file.
- §4 and §11: "every finding is applied" / "all applied in this version". R2-7 was *answered* by a different, better reading rather than applied as written. "Applied or answered" is accurate.
- Code SHAs: origin/develop has moved (wms2-api 371d8a09, oms-laravel-api 4981db86).
  - The report pins its SHAs, so the citations are valid as pinned.
  - `QaReturnService` lines shifted: `:383` is now ~`:387`, and `:738-739` is now ~`:760`.
  - `ReceivingService` changed for SBDEV-3615 (a carrier parked at PutAwayLane / EmptyPallets is brought back on receive). This touches only the latent carrier path.
  - SBDEV-3742 adds `wms_warning_code` ("received_in_wms … also true of a warned or aborted auto-receive"). This *reinforces* S8: an aborted auto-receive is a real way to reach a partially received, permanently OPEN RETURN advice.
  - None of this changes a verdict. A one-line re-pin note is optional.

## DB checks this round (wsl-wineco-prd, 2026-10-15)
- Current lane-wms §4 SQL, verbatim joins, all-time: position rows 10,173, NULL destination 0, no UL 0. In the 180-day window (now 624 rows), NULL destination 0.
- Picked-row recordtype by advice year:
  - 2020: TRANSFERRED 1,520
  - 2021: TRANSFERRED 1,703
  - 2022: TRANSFERRED 1,040
  - 2023: TRANSFERRED 364
  - 2024: TRANSFERRED 2,100
  - 2025: CREATED 2,102 / TRANSFERRED 235
  - 2026: CREATED 177 / TRANSFERRED 932
- `unitload_record` `(ordernumber, label)` groups with more than one row (`IBOL%`, RETURN): 0, so there are 0 multi-location groups.
- RETURN advice states: 2,822 FINISHED, 0 OPEN (2020-03-26 → 2026-10-13).

## Open questions (unscored)
- S8 tier: "T1" assumes a one-file fix, for example auto-finish when the last position is fully received. If the fix instead lets `close()` accept RETURN, that changes a guard someone added on purpose and a UI-visible action, which could be T2. Name the intended fix shape.
- Dock receipts also never flip *positions* to FINISHED (`ReceivingService` writes only OPEN). §5.8's "derive completion from positions (Σ GRP amount ≥ notified)" already handles this. It is worth saying explicitly that `adviceposition.state` is equally unusable.

## Counts
- R2 findings: **RESOLVED 6 · PARTIAL 1 (R2-4) · OPEN 0**
- New: **High 0 · Medium 1 (R3-1) · Low 4 (R3-2 … R3-5)**
- Headline (no schema change) and conditional tier: stand. The numbers behind the R2 fixes re-verify exactly.
