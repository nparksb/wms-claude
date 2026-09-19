---
name: absence-of-a-path-is-not-absence-of-the-guarantee
description: A path- or name-keyed search cannot prove a thing is missing, because it can have been renamed — verify the guarantee, not the file
metadata:
  type: feedback
---

**A search keyed on a PATH or a NAME cannot establish that something is absent**, because the thing can
have been renamed. Verify the **guarantee**, not the file.

**Why:** measured on SBDEV-3156 (2026-09-01). A test was declared "orphaned — committed on no branch,
checked every remote ref" and slated to be landed. The check had swept every ref for the path
`test/components/handlingUnits/popups/reprintLabelHostSet.spec.js`. That was literally true and completely
wrong: SBDEV-3017 `d29348c` had **deleted** that file fifteen minutes after adding it and replaced it with a
**stronger** successor at `test/util/reprentLabelHostSet.spec.js` (different directory, and `reprent` not
`reprint`). The successor had been on `origin/develop` ever since.

The resurrected version was measurably weaker: it missed the no-import auto-registration mutant entirely,
stated the ANY-of arithmetic as one member per screen, left a function unfenced, and re-asserted a
distinctness check that had been removed for going red on a correct config.

**What made the wrong conclusion convincing:** three surrounding checks were done and all three passed — it
compiled, it was mutation-checked with an attributable kill, and its subject was live on `origin/develop`.
The single unverified premise ("its only guard did not ship") was the one that decided everything.

**How to apply:**
1. `git log --all --follow -- <path>` — follows renames; a ref sweep does not.
2. Search for the **invariant** the thing asserts — the symbol, endpoint, or component it pins — not its
   filename.
3. Check whether a commit **deleted** it and read that commit's message. A deletion shortly after an
   addition is a withdrawal, and the message usually says why.

Same family as [[a-zero-scan-needs-a-positive-control]]: an enumeration offered as closed needs a control
and must state what it matched. Codified in `.claude/skills/wms-triage/SKILL.md` under Claim discipline, and
in `sbdocs/9-System/orphaned-tests/README.md` as an intake rule.
