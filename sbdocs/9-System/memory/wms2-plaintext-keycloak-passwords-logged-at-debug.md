---
name: wms2-plaintext-keycloak-passwords-logged-at-debug
description: wms2-api UserController:242/:301 log the raw request body (password included) and application.properties:8 ships logging.level.net.aim_ai=DEBUG, so a clean build logs live Keycloak credentials. Filed 2026-08-24.
metadata:
  type: project
---

Found by the security lane on [[sbdev-3079-sdr-serializes-user-password]] and confirmed by hand on
`origin/develop` @ `f36e267`. Filed as a ticket 2026-08-24 (Nam confirmed) —
https://app.clickup.com/t/868kw8f2z

`UserController:242` (`createUser`) and `:301` (`checkKeycloakUser`) both do
`LOG.debug("create user: {}", reqMap.toString())` where `reqMap` is the **raw request body**; `password` is
read out of it two lines later (`:247`, `:306`). `application.properties:8` sets
`logging.level.net.aim_ai=DEBUG`.

These are **current, valid, plaintext Keycloak credentials** — strictly worse than the legacy unused MD5
hashes SBDEV-3079 closed, which nothing authenticates against.

**Why:** the severity hinges on a config claim that is easy to get wrong in both directions.

**How to apply:** `.gitignore:59` excludes `*.properties` with a four-file allowlist (`:60-63`), so
`application_dev.properties` **is gitignored by design** — wms2-api's `CLAUDE.md:305` referencing it is
correct, NOT stale doc drift. Do not "fix" that doc. The defensible claim is narrower: a **clean checkout or
CI build** contains only `application.properties`, and `Dockerfile:45` has `SPRING_PROFILES_ACTIVE`
commented out, so nothing *in the repo* narrows the level — a deploy-time env var still could. First step on
the ticket is measuring the actual runtime level on prd; at INFO this drops to a latent defect.

Adjacent, intentional, out of scope: `AdminController:176-179` returns a plaintext temp password in a
response body, `KeycloakService:833-901` builds a CSV of them, and `TokenController:87` takes `password` as
a **query parameter** (query strings land in access and proxy logs).
