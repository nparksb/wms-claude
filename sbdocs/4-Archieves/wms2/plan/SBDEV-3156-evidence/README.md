# SBDEV-3156 — evidence

T2 ticket, no plan document (per the tier router: a document at T2 needs Nam's explicit yes). This directory
holds the measurements and the three independent review lanes instead.

| file | what it is |
|---|---|
| `mutation-log.md` | all twelve mutants, each with whether the kill was **attributable** — and the three that changed the code |
| `review-correctness.md` | lane 1 — adversarial correctness. Verdict: correct and behaviour-preserving, no High |
| `review-security.md` | lane 2 — authorization. Verdict: weakens no authorization on any branch in any environment, confirmed by execution + runtime Spring probes |
| `review-conformance.md` | lane 3 — AC conformance and fact-check. Found the AC-6 blocker |
| `review-security-probes/` | lane 2's runnable probe sources |

## The three things worth reading even if the ticket is closed

**1. A zero needs a positive control.** The first bytecode scan reported `@PreAuthorize: 0` — false, there are
13 sites. Cause: `grep` here is **ugrep**, which silently skips binary files without `-a` and exits 1,
indistinguishable from a real no-match. The false zero pointed at the *same conclusion* as the truth, so it
would have shipped as the ticket's central evidence. Only the positive control separated them. Now codified
in `.claude/skills/wms-triage/SKILL.md`.

**2. The same rule extends to "only these".** Lane 3's dissent: the completeness discipline was applied
unevenly. Everything measured *inside* `src/main` was double-instrumented and came back exact. Both claims
that broke were about things *outside* it, where the instrument was single — the dependency-jar enumeration
(two spellings of the same scan legitimately returned different jar sets) and AC-6's provenance.

**3. A path-keyed search cannot prove absence.** AC-6 asked to land an "orphaned" test. It was not orphaned:
it was the version SBDEV-3017 `d29348c` deleted fifteen minutes after adding it, replaced by a stronger
successor at a *renamed* path that has been on `origin/develop` ever since. The provenance check swept every
remote ref for the old **path**, and a path sweep cannot see a rename. Three surrounding checks passed
(it compiled, it was mutation-checked, its subject was live); the one unverified premise decided everything.
Retired to `sbdocs/9-System/orphaned-tests/README.md` as an intake rule.

## Disposition

- **AC-1 … AC-4** met. **AC-5** first half vacuous and struck (zero annotations to migrate, measured not
  assumed); second half met by the named full-suite comparison.
- **AC-6** withdrawn — its premise was false. The surviving residue is a separate commit correcting the
  stale baseline claim in **both** live in-repo copies, one of which is the successor of the file AC-6 asked
  to land.
