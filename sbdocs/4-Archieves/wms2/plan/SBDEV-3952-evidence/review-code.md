# SBDEV-3952 — code-review lane (2026-10-31)
head: 62b50d17. Reviewer: oh-my-claudecode:code-reviewer (opus). Saved by the main session.

**Verdict: COMMENT (mergeable). 0 Critical, 0 High, 0 Medium, 4 Low.**

## Checks the reviewer re-ran
- Unit tests 9/9, IT 8/8 and PagedListSortExecutesIT 12/12, all on fresh containers.
- Dev DB: 2,068 rows and 2,068 distinct keys. 4 rows differ: 00-A07 12→0, 00-B01 0→12, 00-B03 0→12, 05-A06 12→0.
- PRD (read-only): 2,149 rows and 2,149 distinct keys. 1 row differs.

## Low findings
| # | Finding | Fixed in |
|---|---|---|
| L1 | The frozen header (and the IT Javadoc) wrongly said empty unit loads multiplied the replen sum. In V2.2.00, `i` is NULL on an empty unit load, so the sum was 0; empty unit loads only merged rows. | follow-up commit: both reworded |
| L2 | PRD drift. 53-C01 shows **12** today, not 0 as measured 2026-10-30, because REPL062920 (21WH, 12) appeared. It still goes to 24. | Header: per-location value dropped, keeps "1 of 2,149 rows". PR, release note and ticket must say 12→24 as of 2026-10-31 |
| L3 | The export test asserted page sizes only. | Now also asserts 2 distinct `stockUnitId`s across the pages |
| L4 | The IT's id-block comment was incomplete (the class uses 39520–39549). | Reworded; ReplenishDetailViewTieBreakPagingIT starts at 39550 |
| opt | No IT guarded the `sltname = 'flowbin'` filter. | Added `nonFlowbinLocationIsNotListed` |

## Also folded into the follow-up commit
- Conformance Low: the `ReportViewListKeyUnitTest` Javadoc opening is reworded.
- Security nit: the header now gives the full path `src/main/resources/db/reassign-tenant-ownership.sh`.
