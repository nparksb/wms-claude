# SBDEV-3952 — conformance lane (2026-10-31)
head: 62b50d17. Reviewer: oh-my-claudecode:verifier (opus). Saved by the main session.

**Verdict: PASS, high confidence, 0 blockers.**

## Fresh evidence
- Targeted run with `TESTCONTAINERS_REUSE_ENABLE=false`: IT 8/8, unit 9/9.
- Flyway built an empty DB from 2.2.00 up to 2.2.43.
- `mvn clean compile` exits 0.

## Coverage
- §0 rows 1–11: VERIFIED.
- AC1–AC6: VERIFIED.
- The V2.2.43 SQL body is token-identical to plan §3.
- The diff is 6 files and matches the File Change Summary.

## Low finding
`ReportViewListKeyUnitTest` Javadoc still opens with "so the key is the whole row". That is loose for Flowbin and is fixed in the next commit.

## Not re-run by this lane
- That the gate commit was red.
- That M1–M6 were killed.
Both need edits, which this lane forbids. The executor's logs are in the scratchpad `mut/`.
