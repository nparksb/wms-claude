---
ticket: SBDEV-3545
lane: ralplan round 2 — Critic (opus), independent
snapshot: plan-r2-snapshot.md
verdict: APPROVE (with reservations) — no High; 4 Medium, 7 Low; fold in, no round 3
---
Round-1: H1 RESOLVED · M1 PARTIAL · M2 RESOLVED (9→8, 50→51, checked 8→7 correct; key-set pin stays 6) · M3/M4/M5 RESOLVED (uk_6yyotbpw7edc76ejucc4mflf2 at V2.2.00:3644) · M6 RESOLVED — 'anonymous' rejection correct (u.name in a comment, V2.2.21:102); 8 r.name predicates reproduced · L1–L4 RESOLVED.
- M-A Fix D still misses: SdrFunctionGuard.java:38-42; RestConfiguration inline :269-271 "PUT is safe (mergeForPut skips linked associations) and is kept where the UI needs it"; SdrFunctionGuardUnitTest:616-619; PutForCreationWithdrawalContextTest :59-64/:67/:93; AccessChainSdrWriteExposureUnitTest :63-64/:204-207/:235; MustStayWritableCollectionPostWithdrawalContextTest:79; SdrWriteWithdrawalContextTest :26/:29/:64/:170. Grep returns 449 hits — unrepeatable. Second instrument `git grep -n -i -E "userRole" -- src | grep -i -E "put|writ|kept|live"` (~60). §9 row 1 → "regions found by instruments X and Y".
- M-B §5.1 #5 conditional gate is wrong: same-image ship doesn't undo an earlier rename; 3381 §5.1 #9 requires the check before EVERY tenant deploy. Make unconditional; order only narrows the window.
- M-C AC-9 regex misses unaliased subquery `(SELECT id FROM mywms_role WHERE name = 'x')` (idiom at V2.2.18:54, V2.2.09:77), `role.name`/`mywms_role.name`, lowercase `in`. Scan per statement (split `;`, strip `--`), flag statements referencing `\bmywms_(role|group)\b(?!_)` AND `(?i)\bname\s*(=|in)\s*\(?'`; pin per-file counts {18:2, 19:4, 21:1, 34:1}; mutant narrowing the pattern.
- M-D AC-3 ungated row `never()…(any(),any(),any())` matches only 2-element varargs → vacuous; use verifyNoInteractions(accessService); mutant: put @RequiresFunction on the control class.
- L-1 step 3: three literals change (hasSize(50), hasSize(9), isEqualTo(8)).
- L-2 UserGroup PUT control must assert exact 2xx (check returnBodyOnUpdate).
- L-3 AC-1 flush/clear on the TENANT EntityManager (bare @PersistenceContext = landlord).
- L-4 AC-9 regex `\|` is markdown escaping — put regex in a code span outside the table.
- L-5 dropping UserRole from MUST_STAY_WRITABLE drops it from collectionReadsRemainExposed (:228-240) — pin collection GET in AC-1.
- L-6 step 2 omits AC-6b.
- L-7 F-1: mention UserService#isSuperAdmin (:146-148) group-by-name lookup (no callers).
Also: no AC pins response shape {id,name,description,number}; §1 seed "complete set" rests on one grep — critic ran the unaliased form, 0 mywms_role hits; state it.
