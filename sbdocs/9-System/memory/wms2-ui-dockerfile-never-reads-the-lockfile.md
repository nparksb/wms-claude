---
name: wms2-ui-dockerfile-never-reads-the-lockfile
description: "RESOLVED (mobile ce42662; web-ui SBDEV-4079, 2026-11-09): both v2 UI images now build from a tracked yarn.lock with --frozen-lockfile. History: COPY package*.json never globbed yarn.lock"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 9d095c90-6260-4686-be95-6cc8629e0c55
  modified: 2026-09-02T19:56:59.493Z
---

Both v2 UI Dockerfiles (`wms2-web-ui`, `wms2-mobile-ui`) had:

```
COPY package*.json ./
RUN  yarn install
COPY . .
```

**`package*.json` does not glob `yarn.lock`**, and `COPY . .` lands *after* the install —
so the lockfile never reached dependency resolution and the image resolved every `^range`
fresh at build time. GitLab CI and the GitHub workflows only build the image; there is no
separate `npm ci` anywhere, so this was the **only** resolution path that reaches
production.

Consequences, both of which held until 2026-09-02:
- **mobile-ui**: yarn.lock is tracked (and was regenerated as a yarn 1.22.22 fixed point
  in `99d539e` precisely to be a stable pin) — but the image ignored it entirely.
- **web-ui**: `yarn.lock` is *gitignored* (`.gitignore:9`) and only `package-lock.json` is
  tracked, which `yarn install` never reads. There is no lockfile pin available at all.

Fixes applied on the RUM branches: mobile got `COPY package.json yarn.lock ./` +
`yarn install --frozen-lockfile` (verified: `yarn 1.22.22 install --frozen-lockfile`
exits 0 against the tracked lockfile); web-ui got exact `0.4.1` pins in `package.json`
for the new deps, since it has no lockfile to copy.

**RESOLVED for both repos.** mobile-ui `ce42662` (2026-08-27); **web-ui SBDEV-4079, #207
`7a53f5c6` (2026-11-09)**: yarn.lock tracked (fresh resolve, not `yarn import` — the old
package-lock.json was stale vs what shipped by ~199 packages), package-lock.json deleted and
gitignored, Dockerfile + CI `test` job use `--frozen-lockfile`. Dev test proved the served bundle
carries the yarn.lock versions (keycloak-js 26.2.5 tokens present). **Now: a dependency change
in either v2 UI must commit the regenerated yarn.lock, or the build fails.** Related:
[[wms2-ui-develop-tag-race-deploys-older-code]], [[wms2-ui-openobserve-rum-rollout]].

**Addendum 2026-10-30 (SBDEV-3949, PR #188).** Seen again as a *registry race*: the develop build
(run 40914357549) failed at `yarn install` with `Couldn't find any versions for "@babel/parser" that
matches "^7.29.12"`. That version was published 16:43:44Z, the build resolved at 16:43:48Z, and a sibling
Babel package released at the same moment already depended on it. Diagnose with the registry's `time`
map (`curl -s https://registry.npmjs.org/<pkg>`), then `gh run rerun <id> --failed`; the rerun passed.
