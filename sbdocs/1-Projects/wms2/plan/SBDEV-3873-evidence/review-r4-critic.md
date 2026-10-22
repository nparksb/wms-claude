# SBDEV-3873 — ralplan round 4 (text-only), Critic review

- **Subject:** `plan-snapshot-r4.md` (fixed, not edited). Scope: whether critic r3 M1 + L1–L6 and architect r3 M1 + L1–L6
  are resolved in the text, and whether the edits introduced a new contradiction. `db-verification.md` §3 read.
- **Verified against:** wms2-api `origin/develop` `4960631d`, tag `v0.0.42`; wms2-web-ui `origin/develop`. No Maven, no DB.
- **Mode:** THOROUGH. No High or Medium found; no escalation.

## VERDICT: APPROVE

**High 0 · Medium 0 · Low 3** (all fold into PR bodies / the PR 2 TDD gate; none blocks PR 1).

## G1 control (run 2026-10-22)
`git -C v2/wms2-api grep -n 'path = "/setComment"' v0.0.42 -- src/main/java/net/aim_ai/wms/controller/AdviceController.java`
→ no output, exit 1. The instrument is false on the pre-PR-1 tag, so the r3 vacuity is gone.

## Resolution audit

| Finding | Status | Evidence in r4 |
|---|---|---|
| Critic M1 / Arch M1 — G1 grep vacuous | **Resolved** (residual: L-A) | §5.1 P1: route grep scoped to `AdviceController.java`, `v0.0.42` negative control recorded, bare-`setComment` warning added |
| Critic L1 / Arch L2 — IT base | **Resolved** | AC-2 names H2 non-transactional `BaseRollbackIntegrationTest`, cleanup by id, explicitly not `BasePostgresIntegrationTest`; checklist (6) corrected |
| Critic L2 / Arch L5 — r2 Lows missed | **Resolved** | AC-5 pins `""`→`""`, null/missing→NULL; §8.1 attribution via `.as(...)` + PR body; M1b wrapped in `snapshot.sh`; M2 covers both mounts; 12,530/6,443 backed by `db-verification.md` §3 (all commented advices FINISHED) |
| Critic L3 / Arch L4a — stale m11 in §9 | **Resolved** | Risk row cites m13, m14 |
| Arch L4b — T4 "≥2 state types" floor | **Declined, on a false premise** (L-B) | §13 |
| Critic L4 / Arch L6a — Step 1 range | **Resolved** | "AC-1 to AC-10, including AC-2b" |
| Arch L6b — PR 2 first-red set | **Resolved** | Step 3: only AC-B1/B2 red first; B3–B5 green, guarded by m13–m16 |
| Critic L5 — AC-3 stub and mode | **Resolved in substance** | per-function stub, so the CYCLECOUNT-only case kills m1b. Mode not named and no `requiredFunction` body assertion; acceptable because AdviceController is not `GUARDED` and P4 states `@RequiresFunction` enforces in every mode |
| Critic L6 — AC-8 null guard | **Partly** (L-C) | `p.getField() != null &&` restored; field-less properties not counted as offenders |
| Arch L1 — G2 regex `\|` escape | **Resolved** | fenced block, pipe-free; `\$patch\("/advice/` matches `t.$axios.$patch("/advice/".concat(...))` |
| Arch L3 — JSON-Patch status | **Resolved and correct** | AC-9 expects 400. Verified: no unscoped advice maps `HttpMessageNotReadableException` (`RestExceptionHandler` @Order(0) has no such handler; `RestEndpointFallbackExceptionHandler` is scoped to `controller.rest`), so SDR's own handler answers 400 |

## Low

- **L-A — G1's grep is whitespace-exact against a file whose precedent has no space, and the positive control is missing.**
  Every mapping in `AdviceController.java` is written `path= "/…"` (`:72,:106,:143,:174,…`); only `:344` uses `path = `.
  P1 greps the literal `path = "/setComment"`. A2 does prescribe `path = `, so a conforming executor matches, but one who
  copies the `setPurchaseOrderNumber` precedent (`:143`) produces a release on which G1 is permanently red. That fails
  closed (no outage), but a gate that reds on a correct release invites a bypass. My r3 fix also asked for the positive
  control "matches at the PR 1 merge commit"; only the negative control was recorded.
  **Fix (PR 1 body):** `git grep -nE 'path *= *"/setComment"' …`, and record both controls: match at the PR 1 merge
  commit, no match at `v0.0.42`.
- **L-B — §13 declines the T4 floor on a false premise.** §13: *"after PR 2 the real count is 0"*. That is the count of
  SDR-*writable* types with `state` (T4's subject set). The architect's floor was *exported* types with a `state`
  property, computed independently of PATCH exposure: `Advice` and `Cyclecount` both keep `state` (`Advice.java:31`,
  `Cyclecount.java:31`) and stay exported (AC-B3 asserts it), so it is 2 after PR 2. The synthetic control proves the
  predicates, not the enumeration source, so the gap the architect named (a wrong mapping set → empty scan → green)
  stays open. **Fix (PR 2 gate):** reinstate the floor, or correct the rationale and accept the gap explicitly.
- **L-C — AC-8 excludes field-less properties instead of flagging them.** With `p.getField() != null` as a filter, an
  accessor-only writable property is dropped from the declared set, and it is absent from `getDeclaredFields()` too, so
  the cross-check cannot see it. None exist today. **Fix:** count any writable property with `getField() == null` as an
  offender.

## New-contradiction sweep
- §5 A2 "`null` and `""` clear the comment" vs AC-5 "`""` stores `""`": consistent if "clear" means empty. AC-5 is the
  authority. Cosmetic.
- §5.1 P2 says "Run the two commands below the table". There are three, one presence and two absence. Cosmetic.
- AC-10 still sits between AC-7 and AC-8 in §8. Step 1 now names it, so it is cosmetic.
- No other contradiction: §0, §4, §5, §6, §8 and §8.1 agree on the handler, the base, the mutants and the gates.

## Verdict justification
APPROVE. Both round-3 Mediums are fixed: the G1 instrument is now false on `v0.0.42` (verified). Every round-3 Low is applied
or dispositioned. The three residual Lows are all fail-closed or future-only, and each folds into a PR body or the PR 2 TDD
gate. No Realist downgrades were needed.

## Open questions (unscored)
- PRD guard mode is still not re-queried (§10). The DB MCPs remain down.

---
*Ralplan summary row:* Principle/Option Consistency **Pass** · Alternatives Depth **Pass** · Risk/Verification Rigor
**Pass** (G1 is now non-vacuous; L-A hardens it) · Deliberate Additions **Pass**.
