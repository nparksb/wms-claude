---
name: deploy-only-to-develop-release-and-main-are-devops
description: "Nam 2026-08-26 — development merges go to `develop` ONLY; promotion to `release` (QA) and `main` (production) is the dev-ops team's decision and requires approval"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 19177cfb-9b69-43ea-af9b-c8dd5be41a8e
  modified: 2026-08-26T18:53:16.784Z
---

**During development I merge to `develop` only.** Promotion `develop → release` (QA) and
`release → main` (production) is **entirely the dev-ops team's call and requires approval**. Never
propose, plan, or perform either promotion as though it were an engineering step.

**Why:** those two branches are gated deployment environments with an approval process that sits
outside the repo. A branch operation that looks routine in git is a QA or production release here —
`main` pushes trigger the production image build (`.github/workflows/docker-image.yml`,
`on: push: branches: [main]`).

**How to apply:**
- Merge work to `develop`. Stop there. Report the merge and let dev-ops sequence the rest.
- When a plan says a fix "must reach prd" (e.g. SBDEV-3017's `FunctionGuardInterceptor` prerequisite),
  that is a **statement about release sequencing owned by dev-ops**, not an instruction to merge
  branches. Do not translate it into one — I did on 2026-08-26 and proposed merging `develop` into
  `main`, which was wrong on both the mechanism and the authority.
- The real topology is **`develop → release → main`**, not develop → main. `release` carries its own
  version tags (`v0.0.NN`) and release PRs; `main` typically lags it by several versions.
  Check `origin/release` before reasoning about what is or isn't on production.
- `CLAUDE.md`'s "tag-driven deployments … `v*` for production" is **stale for wms2-api**: the
  workflow keys on the branch push and only reads tags for image versioning.
- Before claiming a class is missing from a branch, `git ls-tree -r --name-only <branch> | grep <Class>`
  to get its real path. A wrong path reports ABSENT on every branch and proves nothing — see
  [[verify-script-traps]].

Related: [[wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway]],
[[wms2-gating-programme-is-live-on-prd]].
