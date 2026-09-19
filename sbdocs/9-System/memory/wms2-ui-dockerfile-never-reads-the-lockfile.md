---
name: wms2-ui-dockerfile-never-reads-the-lockfile
description: "Both v2 UI Dockerfiles resolved deps fresh per build — `COPY package*.json` doesn't glob yarn.lock, so every tracked lockfile pinned nothing that shipped"
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

**When adding a dependency to a v2 UI, check which repo you are in** — web-ui still has
no lockfile, so only an exact version in `package.json` pins anything there. Related:
[[wms2-ui-develop-tag-race-deploys-older-code]], [[wms2-ui-openobserve-rum-rollout]].
