---
name: fixing-a-false-claim-tends-to-produce-a-new-one
description: "Correcting stale prose reliably introduces a NEW false claim, and by the later rounds the failure becomes sibling copies left behind — including in PR body and inline comments; every fix pass needs its own review, and a token grep over prose is not a sweep for a claim"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: bb937c20-4fcb-4d33-b6f5-9442c8be9915
  modified: 2026-09-08T14:11:51.494Z
---

**A pass that removes false claims reliably adds new ones, and they are worse than what they
replaced.** Measured twice on SBDEV-3257 (2026-09-08), a doc-only ticket whose entire purpose was
deleting stale claims.

- **Round 1:** correcting 36 "the SBDEV-2217 lane is down" comments, I wrote *"SBDEV-3239 fixed the
  harness"* for two `smoke/*ContextLoadTest` classes. They extend `BaseRollbackIntegrationTest`
  (`@ActiveProfiles("integration")`, H2) — a lane SBDEV-3239 never touched.
- **Round 2:** fixing *that*, I wrote *"a full-context lane exists as of SBDEV-3239"* at **10 sites**.
  Also false: `BaseControllerIntegrationTest` predates it by months.

**Why the new claim is worse:** the old text was recognisably a stale marker; the replacement is
confident, specific, and carries a ticket number that makes it read as verified. A reader has no
signal to distrust it.

**How to apply:**
- **The fix pass needs its own independent review.** Round 2 existed only because Nam asked "did you
  review the changes and fixes?" — the first lane had reviewed the *pre-fix* branch. Never let a
  review of X stand as a review of the fixes to X.
- **State the mechanism you verified, not the ticket you assume.** Every replacement asserting "X
  fixed this" needs `git log` on the file plus the annotation/property that actually supplies the
  behaviour.
- **Prefer deleting a false clause to replacing it.** Where a second, still-true reason exists
  (`standaloneSetup` installs no method-security advisor), keep that and delete the rest — adding a
  new causal story is where the error enters.
- **Do not copy a reviewer's wording as fact.** H-Δ2 was me lifting "the landlord URL comes from
  `application-integration.properties`" out of the first review; it comes from the base class's own
  `@TestPropertySource`. Related: [[subagents-must-write-deliverable-to-a-file]].
- **Read the `extends` clause, not the javadoc.** H-Δ3: I added "the cheaper H2 base is the right
  choice" to a class that extends `BasePostgresIntegrationTest`.

Related: [[prose-enumerations-rot-state-the-rule]],
[[retitling-a-section-leaves-the-rule-asserted-below-it]], [[a-zero-scan-needs-a-positive-control]].

**THIRD occurrence, SBDEV-3262 (2026-09-08) — and the first where the corrections chained.** A count
went "five" → corrected to "six" (right at that moment) → the next commit reverted the site that MADE
it six, so "six" was wrong again, and the tree ended up holding BOTH figures live in different files.
Three values in three commits. Other prose the fix pass falsified: a javadoc bullet that asserted the
corrected behaviour and then, two lines later, the behaviour it replaced (a bad splice seam); a
"tripwire" claim retracted test-side while the production-side copy — the one a maintainer actually
reads — was left standing; a metric-segment correction that named the wrong config class.

**The counting fix that finally worked: delete the number.** State the RULE and paste the derivation
command instead. A population moves with the code; the rule does not. Reach for this the FIRST time a
count is wrong, not the third.

**Also learned here: a false claim survives review when the CONCLUSION it supports is still true.** Two
statements ("the fix is at the site", "the row is at PICKED") survived two full review passes because
the thing they justified held either way — the row was at FINISHED, which the same predicate excludes
*a fortiori*. Reviewers check whether the argument works, not whether each premise is accurate. So
premises that are load-bearing for nothing get no scrutiny at all, and rot silently.

**Process consequence, measured 3 for 3:** a fix pass responding to review findings has introduced new
defects EVERY time on this repo. Budget a review lane for the fix pass itself, and say plainly when
that pass is the one that has not been reviewed.

**FOURTH and FIFTH occurrences, SBDEV-3244 (2026-09-10) — and the new lesson is about which passes
get reviewed.** Both new false claims were **comment-only**, and both survived three lanes
(conformance, code review, security) that were looking at behaviour. A **delta review scoped to the
fix commit** caught them, which is the only reason they did not ship:

- I asserted *"`getAvailableReplenishmentSources` excludes the order's current source"* to justify a
  lock-ordering conclusion. It does not — no `su.id <>` predicate, and the Java pipeline only sorts.
  Worse than a wrong sentence: it **replaced a sound argument** (the area-comparator contradiction,
  which covered the cross-*order* ABBA case) with a claim about current-vs-target inside one call,
  leaving the case that actually needed work covered by nothing.
- I inverted floor/ceiling in the same paragraph that correctly explained the direction — traceable
  to the review report using both words, and the fix pass copying the wrong one.

**The rule this adds: budget the delta review by DIFF SHAPE, not by risk.** A comment-only or
test-only fix pass feels safe and is exactly where these land, because behaviour-focused lanes have
nothing to fail on. Ask the delta lane specifically *"did the correction introduce a fresh error?"*
and name the passages it corrected.

**Two more mechanisms worth naming.** (a) *Do not restate a reviewer's argument in your own words* —
paraphrasing is where the premise mutated; restore the original wording verbatim when it was right.
(b) *An unmeasured claim reads exactly like a measured one.* I wrote "the true baseline had those 4
errors" from inference; the honest fix was not to measure it but to notice a sibling ticket
(SBDEV-3285) had independently fixed the same 4 — corroboration beats self-measurement. Label derived
claims as derived, in the text, every time.

**SIXTH occurrence, SBDEV-3244 again (2026-09-10) — reviewing the FIX of the fix, and the failure was
not new claims this time but SIBLING COPIES.** Of 7 Medium in the tail lane, **four** were the same
shape: a claim corrected in one place and left standing in another. §11.1 and §5.4 of a design doc
were fixed; a **third** copy survived in the §0 summary bullet, and it survived the reviewer's own
instrument too — a `git grep "entityManager.refresh\|REQUIRES_NEW"` cannot see a bullet that
paraphrases the mechanism in prose without either token. The same round: "the sole thing that can drop
the current source" fixed in Java, left standing in the PR inline comment; the `ignoreStubs`
one-versus-one framing fixed in Java, left standing in the PR comment; "first statement" tightened in
Java, left in both docs.

**Rules this adds:**
- **PR text is a copy.** An inline review comment and a PR body are artifacts a maintainer reads
  years later; the sibling sweep must include them, and `gh api .../pulls/342/comments` is the only
  way to see them.
- **A token grep over prose is not a sweep for a CLAIM.** Grep the *mechanism words* the claim could
  be spelled with, then read the summary/overview sections by hand — that is where a paraphrase with
  none of your tokens hides.
- **When a proof keeps failing review, delete the proof.** Three successive versions of one
  lock-ordering argument were each wrong. What shipped states VERIFIED vs NOT ESTABLISHED and names
  the accepted bounded outcome. That ended the cycle; a fourth attempt at the argument would not have.
