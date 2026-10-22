---
name: sbdev-3017-tranche1-mvc-gating
description: SBDEV-3017 tranche 1 gated 71 of 75 MVC routes (commit f3d51631); C30-C33 split to SBDEV-3154; two structural traps in the surface tooling
metadata:
  type: project
---

Implemented 2026-08-28. **Head `81989036`** (PR #232; was `f3d51631` -> `01028a37` -> `ad551d18` through two review rounds) on `bugfix/SBDEV-3017-B1-mvc-write-surface-gating`
(wms2-api) + **`65e4bbb`** on `bugfix/SBDEV-3017-B1-ac7-require-function-comment` (wms2-web-ui).
Suite **5693 / 0 / 67**. THREE review rounds, 1 High / 10 Med / 12 Low, all fixed — both lanes independently found the same residual in my fix for the first High: the OMS carve-out rows read only `@RequiresFunction`, so a `@PreAuthorize` gate left the whole suite green. See [[a-guard-fences-the-mechanism-you-aimed-at]]. Plan §9.25 has the full record.

**71 of 75 rows.** The four `AdminActionController` operator-console routes (C30–C33) split to
**SBDEV-3154** by Nam's decision — they alone need 2 new `FunctionEnum` constants + `V2.2.22`, and
excluding them keeps the PR migration-free (so the merge is not a Flyway run on every tenant) and
drops the tier T3 → T2.

**Two structural traps in the tooling, both still live:**

1. **`DashboardController extends ReportController`.** The dual `/v3/report` + `/v3/dashboard` mapping
   is INHERITANCE, not a two-valued `@RequestMapping`. One method-level annotation covers both paths —
   any path-keyed table double-counts that work, and a class-level annotation on `ReportController`
   would silently gate every `/v3/dashboard` read.
2. 🔴 **`SurfaceInventoryContextTest` OVER-REPORTS gating.** It resolves the class-level fallback on
   `hm.getBeanType()`; `FunctionGuardInterceptor:166` resolves on `getMethod().getDeclaringClass()`.
   They disagree for any handler inherited from `AdminController` into a subclass carrying a
   class-level annotation. **The interceptor is the authority** — the tool's gated/ungated tallies are
   an upper bound on coverage. `Sbdev3017TrancheGateContextTest` (new, 74 rows) uses the correct axis.

**A class-level `@RequiresFunction` on an `AdminController` subclass does NOT reach the inherited
`AdminController` handlers** — that is the same `getDeclaringClass()` fact, and it is why class-level
placement is safe on the four classes that got it. It is NOT the same as `GUARDED` membership, which
fail-closes every *unannotated* handler (~122 ungated reads).

**`FunctionGuardArchTest#noSharedControllerCarriesRequiresFunction` fires on the CLASS being shared**,
not the method. 8 handlers tripped it; each was verified to have zero `wms2-mobile-ui` callers (with
positive controls) and registered in `REVIEWED_SHARED_METHOD_GATES` — never loosen the rule.

**Does NOT close SBDEV-3017:** every gated entity keeps live SDR write verbs; the 122 ungated MVC
reads, the 16 POST-as-query report reads ([[sbdev-3142]] territory) and `/rest/**` (SBDEV-3124) all
remain. AC-1 as §8.6 rewrote it wants 85 rows, not 75 — the 10 boundary rows X1–X10 are in neither
total, and `runClubLine`/`runTransfer` still run a whole batch from a bare GET.

Related: [[ac2-role-count-is-not-the-unit-user-population-is]], [[mutation-harness-traps]],
[[wms2-function-gate-anti-drift-only-covers-guarded-classes]],
[[wms2-13-action-gates-are-self-grantable-and-sdr-bypassable]],
[[wms2-gating-programme-is-live-on-prd]].
