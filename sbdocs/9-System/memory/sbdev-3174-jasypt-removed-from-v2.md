---
name: sbdev-3174-jasypt-removed-from-v2
description: "SBDEV-3174 — Jasypt removed from wms2-api (PR #249, unmerged); it was INERT under Boot 3 and failed silently. v1 still uses it and works"
metadata: 
  node_type: memory
  type: project
  originSessionId: 518ad76d-0650-4f08-b17a-74478c435d9d
  modified: 2026-08-31T14:23:11.227Z
---

**SBDEV-3174**, PR **SiteBossInc/wms2-api#249**, branch `chore/remove-inert-jasypt-from-v2`,
status `pr submitted` (**not merged** as of 2026-08-31). Answers Nam's question on SBDEV-2848: *do we
want Jasypt in v2?* No.

**Jasypt in v2 was not "unused" — it was structurally incapable of working.**
`jasypt-spring-boot-starter` 2.1.2 registers its auto-configuration **only** via
`META-INF/spring.factories` under `EnableAutoConfiguration`, which **Boot 3 no longer reads for
auto-configuration**; the jar ships no `AutoConfiguration.imports`, and nothing carried
`@EnableEncryptableProperties`. So no `StringEncryptor` bean existed and an `ENC(...)` property would have
been used **literally**, silently. Jars on the classpath + a Dockerfile naming an encryptor = false
confidence. (The starter's second factories key, `BootstrapConfiguration`, *is* still read by Boot 3 — but
Spring Cloud is a BOM import only with all starters commented out, so it was dead too.)

⚠ **v1 (Boot 2.3.7) DOES use Jasypt and it works there** — live `ENC()` values in
`application.properties`. This was a v1 copy-forward, same shape as the `tomcat.version` pin
([[sbdev-2848-tomcat-version-override-direction]]). Don't "fix" v1 by symmetry. v1's config is
`PBEWithMD5AndDES` + `ZeroSaltGenerator` — zero salt ⇒ deterministic ciphertext, a real v1 weakness.

**Where v2's secrets actually are** (so property encryption was never the right tool):
`tenant_auth_configuration.svc_password` / `client_secret` in the **landlord DB**, measured **plaintext**
on dev (3/3), uat (3/3) and prd (1/1); no decrypt call anywhere in `src/main`. `V2.1.00`'s inline comment
claims they are Jasypt-encrypted and is simply **wrong**; corrected by landlord migration `V2.1.01` via
`COMMENT ON COLUMN` (V2.1.00 is applied everywhere, so its text cannot be edited without breaking Flyway
checksums).

⚠ **Still-open credential finding, PROPOSED not filed:** `application.properties:42`
`landlord.datasource.password` is a **committed plaintext literal** — the one value Jasypt would have
covered. T3-shaped (delivery across dev/uat/prd, plus whether the literal is live). Nam has not ruled.

**Two traps this change surfaced, both worth reusing:**
- A classpath pin naming a class that exists in **no** version is not a pin — it catches
  `ClassNotFoundException` and passes while the library is fully present. Mine did
  (`jasyptspringboot.EnableEncryptableProperties`; the real name has `.annotation.`). **Mutation-check per
  pin, not per method** — the method reddened from a *different* pin. Version-robust pins across 2.1.2 and
  4.0.4: `annotation.EnableEncryptableProperties`, `EncryptablePropertyResolver`, `org.jasypt`
  `StandardPBEStringEncryptor`. The starter's auto-config class **moved package** (`jasyptspringboot` →
  `jasyptspringbootstarter`) between 2.x and 4.x, so pin both.
- `db/check-migration-version-collision.sh` **cannot answer a landlord-lane query** — it hard-codes the
  tenant dir. Do NOT "fix" it by scanning both: the lanes have separate `flyway_schema_history` tables and
  independent series (tenant historically V2.1.x → now V2.2.x; landlord V2.1.x), so one namespace reports
  false collisions — measured, it flagged landlord `V2.1.01` against tenant
  `V2.1.01__add_unique_constraint_unitload_labelid.sql` on ~25 branches. Needs per-lane namespacing.
  Sweep `db/landlord-migration` by hand meanwhile.

Also see [[unzip-glob-multiple-jars-is-a-false-green]], found while verifying this.
