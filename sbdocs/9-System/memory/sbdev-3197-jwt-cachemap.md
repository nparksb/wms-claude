---
name: sbdev-3197-jwt-cachemap
description: SBDEV-3197 — JwtAccessTokenCustomizer.cacheMap is an unsynchronised unbounded cache on the auth path; one line stops it being a cross-tenant leak
metadata:
  type: project
---

**SBDEV-3197 (filed 2026-09-02, High, T3, not started).**
`JwtAccessTokenCustomizer.cacheMap` is a `PassiveExpiringMap<String, AbstractAuthenticationToken>`
keyed on `preferred_username`, on the `jwtAuthenticationConverter` — i.e. **every authenticated
request from every tenant**.

**It is NOT an authz bypass, and the reason is one line.** `isCacheValid` compares the WHOLE token
string, so tenant A's entry is never served to tenant B. Nothing marks that line as load-bearing;
"optimising" it to a subject/expiry/username check converts this into a cross-tenant authority leak.
Do not close this ticket as "works today" without pinning that comparison with a mutation-checked test.

Real defects: `PassiveExpiringMap` is unsynchronised **and its `get()` mutates** (expiry-on-read);
unbounded (no `maximumSize`); and `DEFAULT_USERNAME = "service-account"` collapses every claim-less
token onto one slot.

**How it hid:** two of [[sbdev-3190-singleton-tenant-state]]'s rail blind spots at once — no
stereotype annotation (singleton only via `SecurityConfiguration`'s `@Bean`) AND a `final` field with
mutable contents.

**The sweep that should have caught it:** `grep -rn "PassiveExpiringMap" src/main` returns TWO hits —
this field, and the comment SBDEV-3190 Slice 2 wrote saying it had replaced one. Sweeping for the OLD
literal after a fix is the repo rule; skipping it cost a whole extra review cycle.
