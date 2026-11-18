# SBDEV-3952 — ralplan round 2 (2026-10-30)
Plan revision 2. Both lanes are independent. Saved by the main session.

## Critic: **VERDICT: APPROVE**
- Every round-1 finding is closed: H1, H2, M1–M4, L1–L4, and architect F1–F6.
- All 8 IT methods were walked by hand against the old SQL (V2.2.00:1124-1156) and the new SQL. Each is red, green or a guard as stated.
  - Test 8 on the old view: (Z, ul1, NULL) and (Z, ul2, NULL) merge, because `ul.id` is not in the GROUP BY.
- The key is unique by construction. `location.name` is UNIQUE NOT NULL, `f` is UNIQUE per location, `stockunit.unitload_id` is NOT NULL (V2.2.00:1095), and no later migration alters these.
- Column 12 stays `numeric(-1)`. Columns 15 and 16 are bigint.
- Low findings, all applied to the plan 2026-10-30:
  - L-a: reword test 1's mutation.
  - L-b: test 8's mutation becomes `NULL::bigint`, which can be attributed to the key.
  - L-c: test 3 asserts the value before the row count.
  - Tighten AC4's wording.

## Architect: **CHANGES → resolved**
- Verified on dev with a temp view (since dropped):
  - Columns 1–14 match the live view's types and typmods.
  - `EXCEPT ALL` diff: 2,068 = 2,068 rows. Exactly the 4 (b) locations differ.
  - Full-key duplicates: 0 on flowbins. Positive control without the flowbin filter: name 343 duplicates, (name, ul) 307,090 duplicates, full key 0.
- F1–F6 closed.
- N1 (Medium), applied: `00-B01` is not empty. It stocks `22AZCHBTL` and its replen is for `23AZPGBTL`. The plan §1 text and manual rows were split.
- N2 (Low), applied: "no JIT" is proven on dev only (cost 85k). The PRD estimate is about 100k, right at the threshold, and is added to the follow-up.
