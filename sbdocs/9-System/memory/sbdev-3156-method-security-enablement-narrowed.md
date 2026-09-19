---
name: sbdev-3156-method-security-enablement-narrowed
description: SBDEV-3156 narrowed @EnableMethodSecurity to prePost only and banned the four de-armed annotations; PR #269, develop-only until the next release
metadata:
  type: project
---

**MERGED to `develop` 2026-09-01: PR #269 → `d57b466d` (api), PR #107 → `9ff2e83e` (web-ui).** `MethodSecurityConfig` went from
`@EnableMethodSecurity(prePostEnabled = true, securedEnabled = true, jsr250Enabled = true)` to
`securedEnabled = false, jsr250Enabled = false`, all three attributes pinned, and `@Secured` /
`@RolesAllowed` / `@DenyAll` / `@PermitAll` banned from `src/main`.

Usage of those four was **zero**, measured by two agreeing instruments plus a 304-jar classpath scan. So
this changed no runtime behaviour — it removed four Spring Security processor beans and cut the
denial-mechanism count from five annotations to four live ones.

⚠ **`prePostEnabled = true` arms FOUR annotations, not two.** `PrePostMethodSecurityConfiguration` builds
`preFilter`, `preAuthorize`, `postAuthorize` and `postFilter`. `@PreFilter`/`@PostFilter` were missing from
`Sbdev3017TrancheGateContextTest.METHOD_SECURITY_GATES` until this ticket's review; a `@PostFilter` on an
OMS §0.C carve-out route would silently **empty the response** rather than deny it — no flag flip, no
denial, nothing to notice. The list is now seven long.

**The ban is only safe because of the two flag pins, and vice versa** — turning the flags off without the
ban means a future `@RolesAllowed("sb_admin")` is INERT while reading exactly like a gate. Three files are a
unit: `MethodSecurityConfig`, `MethodSecurityEnablementContractTest`,
`MethodSecurityAnnotationSurfaceArchTest`. Don't change one alone.

**The ban needs TWO detectors.** ArchUnit's `isAnnotatedWith` is direct-only — a meta-annotation declared
outside `net.aim_ai.wms`, and an annotation inherited from a superclass outside it, both escape it while
Spring honours them. The second instrument uses `AnnotatedElementUtils.findMergedAnnotation`. Also: a size
floor is not a coverage guard (650 classes with a floor of 400 lets a 249-class subtree vanish, and
`landlord/` is 34), so it asserts landmarks too.

⚠ **No pipeline runs any of this.** GitLab, the `Dockerfile` and all three GitHub workflows build with
`-DskipTests`; the develop→dev workflow has no test step. These tests fail only on a local `mvn test` — so
"fails the build" is false. See [[wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway]].

**Still `securedEnabled = true` on `origin/main`**, so this reaches prd at the next release. The gating
programme itself is already there — [[wms2-gating-programme-is-live-on-prd]].

Related: [[a-zero-scan-needs-a-positive-control]], [[grep-is-ugrep-skips-binary-without-dash-a]],
[[absence-of-a-path-is-not-absence-of-the-guarantee]], [[sbdev-3017-tranche1-mvc-gating]].


**Rebased twice mid-review** — `origin/develop` moved under it twice (SBDEV-3183, then SBDEV-3186). Suite on
the final merged state: 6018/0/0/67. Worth remembering the check that got this right: to ask whether new
develop commits touch your files, diff from the **merge-base**, not `branch..develop` — the latter includes
reverting your own changes and reads as a false overlap. I made that mistake twice in one session.
