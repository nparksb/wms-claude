---
name: wms2-landlord-db-password-committed-live
description: "SBDEV-3175 — wms2-api commits a LIVE landlord DB password in cleartext (application.properties:42, force-tracked); one credential opens dev_landlord + every tenant DB"
metadata: 
  node_type: memory
  type: project
  originSessionId: 518ad76d-0650-4f08-b17a-74478c435d9d
  modified: 2026-08-31T15:45:37.223Z
---

**SBDEV-3175** (Urgent, filed 2026-08-31, `Open`). `v2/wms2-api`
`src/main/resources/application.properties:42` commits `landlord.datasource.password` in **cleartext**,
and `.gitignore:60` **`!application.properties`** force-tracks the file — so it is in GitHub history
(`SiteBossInc/wms2-api`) on every clone.

**Verified live, not theoretical** (read the value from git into `PGPASSWORD`, never printed): it
authenticates today to `dev.sbo.li:25060` as `wms_landlord`. Committed `cc7cb40d` **2025-12-28, single
sha256 across all history → never rotated in ~8 months**. Rotation is the only fix; scrubbing history does
not un-disclose.

⚠ **Blast radius wider than the URL.** The property names db `landlord`, but the same credential also
opens **`dev_landlord`** (the DEPLOYED dev app's landlord — 4 tenant DB passwords + 3 Keycloak secrets,
plaintext) and **`dev_wh01_om1`** (WineCo tenant DB). So it is a foothold into every dev tenant's secrets.

**Bounded, checked so as not to overstate:** `wms_landlord` is NOT superuser (login + read/write, no
createrole/createdb). **Dev only — prd NOT tested**; prd's app role is `wms2_landlord_app` and its config
is gitignored, so this exact value is likely dev-scoped, but the *pattern* (tracked `application.properties`
carrying a live credential) must be audited on uat/prd (AC-3). Companion: `dev.sbo.li:25060` **does not
support TLS** (`sslmode=require` → "server does not support SSL"), so the password also crosses the network
in cleartext.

**Fix shape:** rotate the role password + update deployed config in one window; move the property to
`${LANDLORD_DB_PASSWORD}` (the same file already uses `${REDIS_HOST}` etc., so the precedent exists);
audit uat/prd; decide dev-cluster TLS.

Surfaced from [[sbdev-2848-tomcat-version-override-direction]]; same secret-handling gap as
[[sbdev-3174-jasypt-removed-from-v2]] (no property encryption; tenant creds plaintext in the landlord DB).
Ticket policy: T3 finding, proposed not filed until Nam said "file it".
[[consolidate-tickets-dont-file-one-per-finding]].
