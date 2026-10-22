---
title: SBDEV-3183 final fix round - verification of 5134ae58, amendment/P3, ticket
date: 2026-10-18
lane: verifier (read-only; no Maven, no edits)
verdict: APPROVE with 3 Low residuals (none blocking)
---

# Final fix round verification

Ground truth: origin/develop `c9cd078d` (fetched; boot-time counts re-derived from `SdrFunctionRules.java`).
Branch `test/SBDEV-3183-rail` tip `5134ae58`. Nothing compiled or run; red/green claims are by reading only.

## 1. Code, commit 5134ae58

| Item | Status | Evidence |
|---|---|---|
| N1 (inherited CrudRepository method match) | FIXED | `.filter(m -> m.getDeclaringClass() == repository)` added at `SdrFunctionRulesUnitTest.java:~232`. |
| N2 (merged annotation + default-exposure comment) | FIXED | `isExported` uses `AnnotatedElementUtils.findMergedAnnotation`; javadoc says the default mirrors this repo's config. |
| N3 (zero-match message) | FIXED (message) / kill claim UNPROVEN | Message now names the repository and says non-exported/inherited/bridge ignored. The commit's "killed: exported=false on findByGateTrue fails with that message" was not re-run (no Maven allowed). By reading it holds: filter drops the method, `hasSize(1)` fails with size 0. |
| M1 reflow | FIXED | Rail javadoc OMS bullet re-wrapped, no orphan line. Over-120 lines in the two files are only pre-existing `@DisplayName` lines. |
| M2 "v3/* calls" | FIXED | "For its `v3/*` calls OMS authenticates by...". |
| M3 date the Printer override | FIXED | "was not measured as of 2026-10-18". |
| Wording: USER_NOT_PROVISIONED | FIXED | Now "for those" (service-account and no-token), passthrough user "depends on that user's own WMS grants", "UAT not checked". |

Specific questions:
- `getDeclaringClass() == repository` safe for the real targets: YES. `LocationRepository` is `net.aim_ai.wms.repo.jpa.LocationRepository extends CrudRepository<Location, Long>`. `findByGateTrue()` (:98-99) and `getAllCrossDockingLanes()` (:176-178) are declared directly in it, with `@RestResource(path=<own name>)`, default exported, zero parameters. `Class.getMethods()` reports the declaring class as the interface itself, so both survive. Caveat: the check is `==` on the Class, so it would fail for a method that a future sub-interface inherits; `OVERRIDE_REPOSITORIES` maps the repository directly, so not applicable today.
- `AnnotatedElementUtils.findMergedAnnotation`: EXISTS in `org.springframework.core.annotation` (spring-core). Confirmed `org/springframework/core/annotation/AnnotatedElementUtils.class` in `spring-core-6.2.15.jar` (Boot 3.5.9 line); signature `(AnnotatedElement, Class<A>)` returns `A`, a `Method` is an `AnnotatedElement`. Compile-wise fine. Not compiled.
- New false claim: none found. 

New issue (Low, L1): `searchPathOf` (:269-272) still reads `@RestResource.path` with direct `method.getAnnotation`, while `isExported` now uses the merged lookup. Inconsistent within one test; harmless for current methods. Fix: use `findMergedAnnotation` there too.
Residual (Low, L2): static interface methods declared on the repository would still pass the filter; none exist on `LocationRepository`.

## 2. Docs

`4-Archieves/wms2/plan/SBDEV-3183-evidence/ac1-sdr-surface-classification.md`:

| Fact-check item | Status |
|---|---|
| B.6 "both remain exported" contradiction | FIXED (CustomerorderBatch moved out, only Pickingorder Cypress-only) |
| "once #529 merges" tense | FIXED ("#529 merged as c9cd078d") |
| frontmatter `amended:` | FIXED (`4ce87ead, then c9cd078d`) |
| two missed callers (pick.vue, stockUnitsTable.vue) | FIXED |
| D.3 overstated USER_NOT_PROVISIONED | FIXED (service-account/no-token only; passthrough JWT; UAT unchecked) |
| 15 + 8 + 1 = 24 and the list | FIXED, counts match |

Residual (Low): D.3 says dev "and all four PRD" have no service-account row; PRD was not re-verified by the fact-check or by me.

`2-Areas/proposals-register.md` row P3:

| Item | Status |
|---|---|
| "sends only comment" imprecise | FIXED ("sends `{id, comment}`") |
| R-2 provenance unverifiable (no SBDEV-3775 doc holds it) | NOT FIXED - still cites "SBDEV-3775 re-review R-2" with no evidence file (Low). |

## 3. ClickUp SBDEV-3183 (read via get_task, include description)

| Fact-check item | Status | Evidence |
|---|---|---|
| 5 title | FIXED | "24 of 35 exported types unruled, 3 of 9 kept-writable ... pending ... (PR #531), every tenant still at OFF" |
| 6 Current state 11 ruled / 24 unruled / AC-2 6 of 9 / #527 merged | FIXED | Ruled list = 5+2+1+3 = 11; unruled list counts 24; #527 `944cc789` "merged" |
| 7 section 1 groups | FIXED | 15 / 8 / 1; lists match amendment; I counted each list |
| 8 section 2 table | FIXED | Advice/Cyclecount/Location marked ruled; 9 rows; UserGroup/UserRole note |
| 9 AC-2 text | FIXED | 6 of 9, pending Boxtype/Client/Section, #531 |
| 10 AC-4 text | FIXED | nine reads + one write; measured 2026-10-18; no "unmeasured" |
| 11 OMS landmine paths | FIXED | 9 reads + PATCH listed incl. findByClNr and the three SBDEV-3671 paths |
| 12 comment path | not editable via description; comments untouched (cosmetic) |
| AC-1 caveat (caller sets corrected 3 times; re-derive before enforcing the 15) | NOT ADDED (optional suggestion) |

New issue (Low, T1): description section 1 still states unqualified "A rule would deny these callers with `USER_NOT_PROVISIONED` once a tenant enforces". This is the same overstatement already fixed in the amendment and javadoc (passthrough-JWT users get their own grants). Ticket text should say "service-account and no-token callers".
Also: ticket does not mention the Itemdata Handling Units caller (fact-check only asked it for the amendment; Low).

Spot-check against `origin/develop:SdrFunctionRules.java` (c9cd078d): 11 `rules.put(` entries (lines 236-373); 2 `overrides.put` (Location findByGateTrue :385, getAllCrossDockingLanes :390). 35 exported / 24 unruled follow from the fact-check's TSV (35 at 4ce87ead, minus 3 newly ruled types plus 0 new exports); I did not run the runtime inventory. Groups 15/8/1 recounted from the ticket lists: 15, 8, 1 = 24. All consistent.

## Verdict

**APPROVE.** Every item from N1-N3, M1-M3, the wording point, the amendment and P3 (except R-2 provenance), and the ticket stale items is fixed. Residuals, all Low and none blocking: L1 `searchPathOf` not using merged lookup; ticket section 1 unqualified USER_NOT_PROVISIONED; P3 R-2 provenance unverifiable. Not run: Maven build/tests, mutation kill for N3, PRD DB counts.
