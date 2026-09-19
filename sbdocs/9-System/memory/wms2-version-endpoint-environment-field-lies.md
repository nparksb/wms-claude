---
name: wms2-version-endpoint-environment-field-lies
description: /api/public/version reported environment=dev on dev, UAT and prd — PLATFORM_ENV is set nowhere and the default was "dev"; fixed by SBDEV-3196 PR #270
metadata:
  type: reference
---

**`GET /api/public/version`'s `environment` field could not identify an environment.** Measured 2026-09-01,
all three returned `"environment":"dev"`:

| env | host | version |
|---|---|---|
| DEV | `wms-api.dev.sbo.li` | `develop-<sha>` |
| UAT | `wms-api.uat.sbo.li` | `0.0.22` |
| PRD | **`wms-api.sbo.li`** | `0.0.21` |

⚠️ **CORRECTED 2026-09-02 — the user-visible half of this was WRONG when first written.** I claimed the
production footer read "… (dev)". It did not. `VersionBadge.vue` renders the environment only inside
`if (this.release && this.release.display)`, and **no environment returns a `platform` block** (the registry
is unconfigured), so the badge falls through to the static `"SiteBoss OWL"` and the environment is **never
rendered anywhere**. The API contract was wrong; the UI symptom I asserted was not happening. I asserted it
without checking the render path against live data — the exact failure this file otherwise warns about.

**Cause:** `PLATFORM_ENV` is set nowhere in the repo, and the default was the literal `dev` — in
`application.properties` *and* the `@Value`. ⚠ Dev was not correct, it was **coincidentally** right, which
is why nobody saw it: the environment a developer checks is the one where the bug is invisible.

**SBDEV-3196 / PR #270 MERGED to `develop` `6736a859` (2026-09-02).** Default is now empty and the field is
emitted as `null`, mirroring `platformRelease` in the same method. Until **AC-6** (set `PLATFORM_ENV` in the UAT + prd Portainer stacks — DevOps) the badge shows
the release with no environment anywhere. That is intended: it makes the missing config visible.

## Host map, worth keeping — one of these is a trap

- **v2 DEV** `wms-api.dev.sbo.li` · **v2 UAT** `wms-api.uat.sbo.li` · **v2 PRD** `wms-api.sbo.li`
- ⚠ **`wms-api.siteboss.net` is NOT v2 prd.** It redirects to `wms-api.wineco.sbo.li`, which 404s on
  `/api/public/version` and returns `{}` from `/actuator/info` — that is **v1** production. Same family as
  [[wineco-is-a-v2-client-prd-mcp-is-wms1-wineco]] and [[wms-v1-vs-v2-dev-api-hostnames]].

`self.version` on this endpoint IS trustworthy. `drift` read `false` everywhere and was never independently
verified — not cleared. See [[wms2-actuator-info-build-time-identifies-the-deploy]] for the other instrument.


⚠ **Expected behaviour after the fix, so it is not reported as a regression:** the badge shows the release
with **no environment suffix** — including on dev, which previously read "(dev)" and looked right only by
coincidence. The parenthetical returns when AC-6 sets `PLATFORM_ENV` in each stack. `main` still carries the
old `dev` default until the next release.


## `drift` is NOT a defect — investigated and withdrawn

I nearly filed a ticket for `drift` being `false` everywhere. It is by design:

- **`PLATFORM_REGISTRY_URL` empty is a documented supported config** — `application.properties`: *"empty
  disables the platform lookup; the endpoint then returns only this API's own version"*.
- **`PLATFORM_RELEASE` is a build-arg, not a Portainer var.** `docker-image-uat.yml:96` and
  `docker-image.yml:66` both stamp it; only the develop workflow omits it, because develop builds carry no
  `owl-v*` release tag. UAT/prd images lacking it predate the stamping.

`drift` false follows from both and clears on the next uat/prd build. **Lesson: I inferred a defect from a
runtime symptom twice in one session without tracing it to source. Check what PRODUCES the value before
calling the value wrong.**

## Details verified 2026-09-02

`docker exec … env` on the dev container: `PLATFORM_ENV=DEV` (uppercase — it will render "(DEV)", not
"(dev)"), and **`PLATFORM_RELEASE=` empty**. `isDrifted()` starts with
`if (platformRelease.isEmpty() || release == null) return false;` so **`drift` is unconditionally false in
dev, UAT and prd** — the release-mismatch feature never fires. `PLATFORM_REGISTRY_URL` also appears unset,
which is why no environment returns a `platform` block. Both halves of the feature are dark. Proposed as a
separate ticket, not filed.

⚠️ **`/actuator/info`'s `build.time` is NOT a restart signal.** It is baked into the jar, so recreating a
container from the same image gives an identical value. It identifies the IMAGE, not the container start. I
used it as a restart signal and was wrong; nothing on these hosts exposes process start time.


## The environment label will NOT appear even once PLATFORM_ENV binds

`VersionBadge.vue` renders the environment only inside `if (this.release && this.release.display)`, and
`this.release = data.platform || null`. With the registry lookup disabled there is no `platform` block, so
the badge shows the static `"SiteBoss OWL"` and the environment never renders. **Setting `PLATFORM_ENV`
alone changes the API response, not the UI.** The label showing up depends on `PLATFORM_REGISTRY_URL` being
configured — a separate product decision.

Uppercase `DEV`/`UAT`/`PRD` is Nam's deliberate convention (2026-09-02) and is safe: the value is
display-only, matched by nothing in either UI or the API.

## Corrections merged: PR #270 `6736a859`, retraction PR #271 `daae54a6`

The false badge claim reached `develop` in four places including a test's `.as(...)` assertion message, and
was retracted in `daae54a6`. ⚠ **SBDEV-3196's ClickUp description still contains the original
overstatement** — the comments correct it, but the description alone reads wrong.
