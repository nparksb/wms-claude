---
name: wms2-gating-programme-is-live-on-prd
description: The wms2 FunctionGuardInterceptor gating programme IS on production as of v0.0.21 — the old "develop-only, not on prd" memory is deleted and wrong
metadata:
  type: project
---

**The `FunctionGuardInterceptor` / `@RequiresFunction` gating programme is LIVE ON PRODUCTION.** Verified
2026-09-01:

- `FunctionGuardInterceptor.java` is present at tag **`v0.0.21`** — the build `/api/public/version` reported
  running on prd — and at `v0.0.22`.
- `origin/main` is `55cf8952` *"Release SiteBoss OWL v2.0.137 to production — wms2-api v0.0.22"*, merged
  2026-09-01 16:27:54. `develop` is 22 ahead.

**This supersedes and contradicts a deleted memory** that asserted the whole authorization programme was
develop-only and absent from `main`/prd. That was true when written and stopped being true at the v2.0.137
release. Reasoning from it produces the wrong severity in both directions: a gating gap on `develop` is now
a *production* concern once released, not a hypothetical.

**Do not confuse three different things** — this is what made the old claim survive so long:
- what is on `origin/develop` (22 commits ahead),
- what is on `origin/main` (v0.0.22),
- what is actually RUNNING on prd (`/api/public/version`; see
  [[wms2-deployed-image-differs-from-branch-head]] — main drifts BOTH ways vs the image within a day).

⚠ Still true and separate: `MethodSecurityConfig` on `origin/main` and at both released tags still reads
`securedEnabled = true, jsr250Enabled = true`. SBDEV-3156 narrowed that on `develop` only, so it reaches prd
at the next release. Related: [[sbdev-3156-method-security-enablement-narrowed]].

A note that still holds: the v1 stack has no function-gating mechanism at all, so a `wms1-*` database is
outside this entirely — see [[wineco-is-a-v2-client-prd-mcp-is-wms1-wineco]].
