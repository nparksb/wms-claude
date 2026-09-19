---
name: sbdev-3194-registry-credential-in-25-workflows
description: One plaintext container-registry push credential is committed in 25 workflow files across 7 repos, in git history since 2024-12-20 — SBDEV-3194
metadata:
  type: project
---

**SBDEV-3194 (filed 2026-09-01, High, Open).** The GitHub Actions workflows log in to
`hub.impactathleticsny.com` as user `impact` with a **literal password**, not `${{ secrets.* }}`.

**It is ONE credential in 25 files across 7 repos** — verified by SHA-256 hashing each value and comparing
without printing it; all 25 hash identically:

| repo | files |
|---|---|
| `v2/wms2-api` | 3 |
| `v2/wms2-web-ui` | 3 |
| `v2/wms2-mobile-ui` | 4 |
| `v2/oms-laravel-api` | 3 |
| `v1/wms-api` | 4 |
| `v1/wms-web-ui` | 4 |
| `v1/wms-mobile-ui` | 4 |

Clean, do not "fix": `v2/omsv2-UI` (8 workflows, zero literals), `wms2-web-ui/docker-uat-image.yml`,
`wms2-mobile-ui/playwright.yml`. So it is 25 of 33 workflow files — **enumerate, don't count**.

- **Write credential** — `docker/login-action` then `build-push-action` with `push: true`, and dev deploys are
  branch-push-driven via a Portainer webhook, so a pushed tag is a path into a running environment.
- In history since **2024-12-20**; on `main`, `develop` AND `release`.
- ⚠ **All seven repos are PRIVATE** (`gh repo view --json isPrivate`). Not a public leak — do not describe
  it as one.
- **Rotation is mandatory**: moving to a secret stops future commits but leaves 8 months of history
  readable in 7 repos. Rotating makes the historical value worthless; history rewriting is not proposed.
- **Not verified**: what the `impact` account can actually do. "It can push" is inferred from the
  workflow's own `push: true`, not from an authenticated probe — do not test someone's live credential
  casually. If it is pull-only this drops to Medium. That is AC-1.

Sweep recipe (never prints the secret):
```bash
for f in */*/.github/workflows/*.yml; do
  p=$(grep -E '^\s*password:' "$f" | grep -v 'secrets\.' | head -1 | sed -E 's/^\s*password:\s*//')
  [ -n "$p" ] && echo "$f -> $(printf '%s' "$p" | sha256sum | cut -c1-12)"
done
```

Same family as [[wms2-landlord-db-password-committed-live]] (SBDEV-3175) and
[[wms2-oms-api-credential-identical-dev-and-prd]] (SBDEV-3181): committed, shared, never rotated.
Surfaced by a review lane on [[sbdev-3156-method-security-enablement-narrowed]] and correctly kept off that
ticket.
