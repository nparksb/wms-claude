# SBDEV-3952: scoped review of 1830dc2e (2026-10-31)
**Head:** 1830dc2e
**Reviewer:** oh-my-claudecode:code-reviewer (sonnet). Saved by the main session.
**Verdict:** SCOPED: APPROVE.

## Checks
- **Fresh runs:** unit 15, IT 9.
- **V2.2.43:** no non-comment line changed.
- **Claimed fixes:** every one verified against V2.2.00 and the code. Specifically:
  - defect (a) wording
  - PRD value dropped
  - script path exists
  - export assertion
  - `nonFlowbinLocationIsNotListed` guards the flowbin filter
  - `EXEMPT_NON_TRANSACTIONAL` comment accurate (purges before and after)
  - ListKey Javadoc

## Lows
- **Low:** two Javadoc lines over 120 characters. Fixed in 87cf77b2, along with a third line (a SQL string split; the concatenated statement is identical).
  - There is no enforced line-length rule: checkstyle is a dependency only, and the test tree has 1,717 lines over 120 characters.
- **Low:** the assertion checks distinctness, not ordering. Correct as is; no change.

## Mutation check
The reviewer asked about a mutation check for `nonFlowbinLocationIsNotListed`. It was already done as M7 (flowbin filter removed); the test was killed with the message `[rows for the non-flowbin location] Expecting empty`.
