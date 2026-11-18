---
title: "SBDEV-4148 — mywms_user legacy MD5 passwords → KeycloakHasIt, entity invariant, dead login sysprops, redactor Cc/Cf"
ticket: "SBDEV-4148"
ticket_url: "https://app.clickup.com/t/868mw9f0v"
type: "bugfix"
priority: "high"
status: "reviewed"
project: [wms2]
version: "v2"
target_version: "v2"
tier: T3
db_verified: true
requester: "Nam Park"
created: "2026-11-15"
updated: 2026-11-16
branch: "feature/SBDEV-4148-mywms-user-md5-cleanup"
related:
  - "[[SBDEV-4133-sysprop-secret-masking-and-groupname-fence]]"
  - "SBDEV-3079"
  - "SBDEV-3157"
  - "SBDEV-4130"
  - "SBDEV-3181"
  - "[[wms2-sysprop-catalog]]"
  - "[[wms2-keycloak-role-matrix]]"
  - "[[wms2-entity-enumeration-report]]"
tags: [plan, security, credentials, flyway, sdr, keycloak]
---
# SBDEV-4148 — mywms_user legacy MD5 passwords → `KeycloakHasIt`

**Ticket:** [SBDEV-4148](https://app.clickup.com/t/868mw9f0v) · **Tier:** T3 (credential data, Flyway data migration, irreversible) · **Base:** `v2/wms2-api` `origin/develop` @ `042f9a13`
**Scope:** slice 2 of SBDEV-4133 (its AC-4..6 + register P99). One PR (D4).
**Evidence (cited A§x):** `/Users/np1076/dev/spk/owl/.omc/research/SBDEV-4148-analysis.md`; reviews `SBDEV-4148-critic-r1.md` (ITERATE), `SBDEV-4148-architect-r1.md` (APPROVE WITH CHANGES) — dispositions in §12. No credential value (password, hash, secret sysvalue) or username appears here: counts, shapes and dates only. Seed accounts are named by id.

## RALPLAN-DR summary (mode: SHORT — T3, one round)

**Principles**
1. One invariant everywhere: `mywms_user.password` holds exactly `KeycloakHasIt`. Keycloak is the only credential store.
2. Enforce at the entity (every JPA write converges) and clean at the data (migration); each is safe without the other.
3. The migration destroys the only record of who held an MD5 — capture the rotation list before it runs, on every tenant a deployment will migrate (N1).
4. Defense in depth, durably tested: a per-type SDR block with a test that fails if the block alone is removed.
5. Never read or move credential values while proving the change: assert shapes and counts.

**Decision drivers (top 3)**
1. Exposure: unsalted MD5 of real v1 passwords (24 rows on wh01 PRD) was served over SDR to any `wms_user` until SBDEV-3079 and is crackable offline; two seed rows per tenant equal `md5(username)` and the recipe is in git.
2. Irreversibility: Flyway is forward-only, runs on every boot for every active tenant, and the hashes are unrecoverable by design — sequencing against the rotation capture is the main risk, not the code.
3. Smallest diff that holds against future writers: no inbound `User` binding exists today (A§1), so the guard must survive a future route, not fix a live one.

**Viable options — how the invariant is enforced**
| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **A. Migration + entity rule (`@JsonIgnore`, field default, `@PrePersist/@PreUpdate`) + per-type SDR collection block** | Covers every JPA writer, legacy rows converge on any later save; no fixture churn (setter kept, ~22 test callers) | First JPA callback in `src/main` (0 precedents, A§3) — a flushing Testcontainers IT must prove it; a caller's explicit `setPassword` is silently overwritten; raw SQL unguarded | **Chosen** (D2) |
| B. A + DB `CHECK (password = 'KeycloakHasIt')` | Also guards raw SQL | ~17 IT fixture files + demo fixture rewritten; add fails on any tenant not yet migrated | Deferred → P101 (N2) |
| C. Migration only, rely on `UserService` literal | Smallest | A future `new User()` or re-exposed route writes any value; WRITE_ONLY still binds inbound | Rejected |
| D. `@Column(insertable=false, updatable=false)` + `ALTER … SET DEFAULT` (architect antithesis) | No callback to prove; raw inserts omitting the column get the sentinel | Legacy rows never converge on save before V2.2.53 applies on a tenant (§9 R4); adds DDL to an irreversible migration | Rejected (ADR) |
| E. Drop the column | Removes the data class | DDL on every tenant; NOT NULL column used by onboarding, demo, 17 fixtures | Rejected |

## 0. Affected sites

Enumeration: A§7 — `git grep -n -E 'getPassword|setPassword|"password"|mywms_user|KeycloakHasIt|WRITE_ONLY|SensitiveMapRedactor|WMS_LOGIN_SECRET|KEYCLOAK_API_USER'` over `src/main` + `src/test` at `042f9a13`, plus `grep -rn` over `sbdocs/3-Resources`; **re-swept r1** with the meridian variant sentinel literal over the whole tree (`git grep -l <variant> origin/develop` → exactly `demo-datasets/meridian/fixtures.sql` and `verify.sql`). **Blind spot:** ~40 read-only `mywms_user` joins excluded as non-writers; SQL that splits the table name; out-of-repo DevOps SQL.

| # | Site | Construct | In scope | Fix |
|---|---|---|---|---|
| S1 | `model/User.java:40-55,127-133` | `password` WRITE_ONLY, no default; javadoc "POST /v3/user (collection) is still exposed" (stale since `4f2d4c83`) | yes | B, C |
| S2 | `service/UserService.java:145` | `user.setPassword("KeycloakHasIt");` | yes — **delete the line** (default + callback cover it) | B |
| S3 | `service/UserService.java:169-188` | dead `setPassword(User,String)`, commented MD5 recipe, 0 callers | yes — delete | B |
| S4 | `RestConfiguration.java` (`src/main/java/net/aim_ai/wms/`) `configureAccessChainMembershipWriteExposure` `:200`, User blocks `:259-280` | no per-type User collection block; collection withdrawn only by loop (`:562`) | yes | C |
| S5 | `repo/jpa/UserRepository.java:20-23,40-49` | comments "User.java has no @JsonIgnore", "WRITE_ONLY rather than…" | yes — comment only | C |
| S6 | `db/migration/V2.2.00`, `V2.2.09` | MD5 seeds ids 0/1; `'!'` for the V2.2.09 system user | not edited (checksum) — converted by V2.2.53 | A |
| S7 | `db/v1-to-v2-onboarding/schema/V1.0.04` | seeds ids 0/1 as `MD5('<username>')` + both dead keys | **excluded** — manual toolkit, V2.2.52 precedent; onboarded tenant then runs V2.2.53 (R5) | — |
| S8 | `demo-datasets/meridian/fixtures.sql:21,33-35` | variant sentinel (`UPDATE` + 3 demo users) | yes (uniformity) | B |
| S8b | `demo-datasets/meridian/verify.sql:12` | `IF EXISTS (… WHERE password <> '<variant>') THEN RAISE EXCEPTION 'A local warehouse password survived'` — run right after fixtures by `DemoWarehouseDatasets.java:62-63` | yes — **same commit as S8**, predicate → `password IS DISTINCT FROM 'KeycloakHasIt'` | B |
| S9 | `util/SensitiveMapRedactor.java:151-157` `normalize`/`isBooleanFlag` | lowercases + strips `_ - .`; no Cc/Cf/Z strip | yes | D |
| S10 | `util/SyspropSecrets.java:28,41-51` | `CONTROL_CHARS` normalises before `isSensitive` | no code change; inherits D in its fragment branch (only toward more masking); one pin test added (AC-11) | D |
| S11 | `service/WmsConstants.java:1333,1340,1683-1684` | dead-key constants, `SECRET_SYSKEYS` | javadoc only, keep listed | A |
| S12 | `PrinterController:245`, `SdrFunctionRules:370` | comments naming dead keys | append "(rows deleted by V2.2.53)" | A |
| S13 | `UserController:181,327,373,516,794` `LOG.debug(..., SensitiveMapRedactor.redacted(reqMap))` | consumers of D | no change | — |
| S14 | `ManualEntryOverrideRequest`, `TokenController`, `KeycloakService.resetPassword`; `Sbdev3132ContractUnitTest:323-336` | other "password" (override/Keycloak creds) | **excluded** — different root cause | — |
| S15 | `unit/json/UserPasswordSerializationTest` | pins WRITE_ONLY inbound bind | yes — invert one test | B |
| S16 | `unit/config/AccessChainSdrWriteExposureUnitTest:76-119,147,186` | no collection test; harness always runs the loop | yes — add 2 tests | C |
| S17 | `SdrWriteWithdrawalContextTest`, `UserServiceUnitTest:138`, sysprop tests using dead keys, `DemoWarehouseDatasetsUnitTest:58` (file shape only, not contents) | consistent | no change, re-run | — |
| S18 | ~22 test `User.setPassword(...)`, 17 raw-SQL fixture inserts | fixture literals | **excluded** — setter overwritten at flush; raw SQL matters only with P101 | — |
| S19 | sbdocs sysprop catalog `:516,522,526`; keycloak-role-matrix `:788` §7; entity report `:136`; function-to-docs-map `:222`; proposals-register P99 | docs | yes | E |

## 1. Problem and DB evidence

Read-only, 2026-11-15, counts/dates only (A§headline, A§6; dev re-derived by Critic r1 and by `q.sh`):

| Tenant | Rows | `KeycloakHasIt` | MD5-shaped | `'!'` | Flyway head |
|---|---|---|---|---|---|
| `wh01_shipitez` PRD | 37 | 12 | 24 (22 real v1-onboarded users created 2022-07..2023-09 + 2 seeds) | 1 | 2.2.45 |
| `wh01_hydra` PRD | 9 | 6 | 2 (seeds) | 1 | 2.2.45 |
| `wh02_shipitez` PRD | 11 | 8 | 2 (seeds) | 1 | 2.2.45 |
| dev `dev_wh01_om1` | 100 | 14 | 85 | 1 | 2.2.52 |
| WineCo PRD | unmeasured (MCP down) — §5.1 | — | — | — | — |

- Seed ids 0/1: `password = md5(name)` on every measured tenant (exactly 2 each). Method: `count(*) WHERE password = md5(name)`; blind spot: other weak hashes are undetectable without cracking.
- `'!'` row: the V2.2.09 system user (no groups, no location, version 0) — not a write-path leak.
- No v2 code path writes MD5: newest MD5 `created` dev 2024-12-23, wh01 2023-09-14; 0 MD5 rows created after 2025-12-01 (dev, wh01). Every `UserController` route binds `Map<String,Object>` (`git grep '@RequestBody +(@Valid +)?User\b'` = 0).
- SDR served `User.password` to any `wms_user` until SBDEV-3079 (on PRD).
- `WMS_LOGIN_SECRET`, `KEYCLOAK_API_USER`: one Backend/client-0 row each holding a non-secret placeholder on all 4 reachable DBs; 0 readers in `src/main`.
- PRD is at 2.2.45, so V2.2.46..V2.2.53 ship together.

## 2. Root cause

v1 stored local MD5 passwords; v2 moved authentication to Keycloak but never cleaned the column. New rows get the sentinel only by convention — `UserService.java:145` `user.setPassword("KeycloakHasIt");` — not by invariant, and `User.java:53-55` still accepts any inbound value (`@JsonProperty(access = JsonProperty.Access.WRITE_ONLY)`, no default). Every other save carries the loaded value through, so a legacy MD5 stays MD5 (wh01 has MD5 rows modified 2026-09-24). Seeds were never rotated; the dead sysprops are V2.2.00 placeholders never removed.

## 3. Architecture / key files

```
 HTTP (MVC /v3/user/*) ──► UserController ──► UserService.insertUserAndLocation ─┐   new User(), setVersion(0)
                                         └──► applyProfileOrInsert / setDefaultPrinter / saveUserGroups
 PrinterService, OrderMonitorViewService ─────────────────────────────────────────┤   load → mutate → save
 SDR /v3/user (reads only; writes 405) ───────────────────────────────────────────┘
                                   ▼
            UserRepository.save → em.merge/persist → flush ──[NEW @PrePersist/@PreUpdate: password := sentinel]──► mywms_user
 App boot ─► StartupFlywayMigrationRunner ─► StartupFlywayMigrator.migrateAll (every active tenant) ─► V2.2.53 UPDATE/DELETE
 DevOps ───► capture query (before first pod) ─► out-of-band list ─► Keycloak required-action reset
```

| File | Lines | Role |
|---|---|---|
| `model/User.java` | 40-55, 127-133 | entity; `@Version` via `AbstractBaseEntity` (SEQUENCE id, `AuditingEntityListener`), owns `@ManyToMany groups`; no `@DynamicUpdate` |
| `service/UserService.java` | 87, 135, 139-148, 169-188 | only main-code password writer; merge path (`setVersion(0)` → `isNew` false → `em.merge`) |
| `RestConfiguration.java` | 200, 259-280, 562, 567 | per-type User blocks; `SDR_WRITE_WITHDRAWN` loop |
| `landlord/config/StartupFlywayMigrationRunner.java` | 42, 70-74 | `@ConditionalOnProperty(name = "app.flyway.migrate-on-startup", … matchIfMissing = true)`; `startupFlywayMigrator.migrateAll();` on every boot |
| `landlord/service/StartupFlywayMigrator.java` | 18-32, 282-309 | "Runs the Flyway migrations on every startup — landlord first, then every active tenant"; DBs with no history "skipped … naming db/backfill-flyway-history.sh" |
| `landlord/service/FlywaySchemaMetrics.java` | 29, 52 | gauge `wms2.flyway.tenant.stale` |
| `util/SensitiveMapRedactor.java` | 151-170 | log redaction |
| `demo-datasets/meridian/{fixtures,verify}.sql` | 21,33-35 / 12 | demo reset load + post-check |

Readers of the column: none (`git grep 'getPassword\(\)' src/main` → `User.getPassword` itself only, for User; `UserDetailView` has no password getter). Blind spot: SpEL/reflection.

## 4. Fix design

### Fix A — Migration V2.2.53 (AC-1..AC-4)
**Before:** non-sentinel rows 25 (wh01) / 3 / 3 / 86 (dev); both dead keys present. **After:** `V2.2.53__password_keycloak_sentinel_and_delete_dead_login_sysprops.sql`:
```sql
SET LOCAL lock_timeout = '2s';
UPDATE public.mywms_user SET password = 'KeycloakHasIt' WHERE password IS DISTINCT FROM 'KeycloakHasIt';
DELETE FROM public.los_sysprop WHERE syskey IN ('WMS_LOGIN_SECRET', 'KEYCLOAK_API_USER');
```
`lock_timeout` per `db/migration/README.md` ("Keep the migration's `lock_timeout` below the app's (`wms.tenant.lock-timeout-ms`, 3000)") and V2.2.49–51 precedent; a timeout leaves the tenant at 2.2.52 and retries next boot. No `version`/`modified` bump. Predicate converts the `'!'` row and any NULL (N3). Header warnings: (1) Flyway applies this on boot to every active tenant of the deployment — the rotation list must be captured first (§5.1); (2) `db/backfill-flyway-history.sh` must not mark it applied without running it (V2.2.52 trap). Version free (0 open PRs, no `V2.2.5[3-9]` on any `origin/*` ref); re-run `db/check-migration-version-collision.sh` at PR time. Keep both keys in `SECRET_SYSKEYS` + constants; javadoc → "row deleted by V2.2.53; kept listed for backfilled/onboarded DBs"; same note on S12.

### Fix B — Entity invariant (AC-5..AC-8)
**Before:** `@NotNull @JsonProperty(access = WRITE_ONLY) private String password;` **After:**
```java
public static final String KEYCLOAK_HAS_IT = "KeycloakHasIt";
@NotNull @JsonIgnore private String password = KEYCLOAK_HAS_IT;
@PrePersist @PreUpdate void enforceKeycloakSentinel() { this.password = KEYCLOAK_HAS_IT; }
```
(`jakarta.persistence`). Getter kept; setter kept, `@Deprecated`, javadoc: "any value is overwritten with `KEYCLOAK_HAS_IT` at flush; Keycloak holds credentials". Delete `UserService.java:145` (redundant) and dead `setPassword(User,String)`. Rewrite the User javadoc (drop WRITE_ONLY rationale and "trap" paragraph; note this is the codebase's first JPA lifecycle callback and why). S8 + S8b in one commit.
**Callback semantics (precise):** `@PrePersist` fires on `persist` and on `merge` of a transient copy (production path: `setVersion(0)` → `em.merge`), before BeanValidation. `@PreUpdate` fires whenever Hibernate schedules an UPDATE — any dirty scalar **or** a dirty owned collection (`groups`) on this versioned entity, e.g. `saveUserGroups` — and not on load-and-save-unchanged. Hibernate 6 re-runs the dirty check after the callback (no `@DynamicUpdate`, no bytecode enhancement), so the mutation is written. A managed entity whose only change is `setPassword` still emits an UPDATE + version bump (dirty check precedes the callback) — harmless.
**Why `@JsonIgnore`:** `INFER_PROPERTY_MUTATORS` binds a private field with a visible getter, so dropping the setter alone still binds.

### Fix C — Per-type SDR collection block (AC-9)
**Before:** collection POST `/v3/user` is 405 only via `SDR_WRITE_WITHDRAWN` (`:562`, SBDEV-3157). **After:** in `configureAccessChainMembershipWriteExposure`, next to the User item/association blocks: `config.getExposureConfiguration().forDomainType(User.class).withCollectionExposure((md, m) -> m.disable(WRITE_VERBS));` with the same "LOAD-BEARING INDEPENDENTLY of SBDEV-3157's loop" comment. Not added to `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN`. Fix stale prose in User.java and `UserRepository.java:20-23,40-49`. The existing comment at `:259-262` admits the loop masks these blocks; AC-9b closes that for all three User blocks.

### Fix D — `SensitiveMapRedactor.normalize` (AC-10)
**Before:** `key.toLowerCase(Locale.ROOT).replace("_","").replace("-","").replace(".","")`. **After:** `Normalizer.normalize(key, NFKD)` → remove `[\p{Cc}\p{Cf}\p{Z}\p{M}]` (own pattern in the redactor) → lowercase → strip separators. `strip()` dropped as subsumed by `\p{Z}`.
**Decision (r2): NFKD + strip `\p{M}`, not NFKC, and not "old OR new".** NFKC *composes* a base letter with a following combining mark (`token`+U+0303 → `tokeñ`), so a key masked today (marks left separate, `contains` still matches) would be unmasked — demonstrated by the Architect on JDK 21 for `token`/`password`/`apikey` + mark, and for `MY_PASSWORD`+U+0307 on the `SyspropSecrets` path. NFKD still folds fullwidth/compatibility forms but decomposes instead of composing, and stripping `\p{M}` removes the marks, so the result is a superset of today's matches for every key — method: reasoning over the code, the 12 fragments (`:68-70`) are ASCII letters, NFKD leaves ASCII unchanged, and only non-letter code points (Cc/Cf/Z/M) are removed, so any fragment occurrence today survives; blind spot: holds only while every fragment stays ASCII. "OR of old and new normalisation" was rejected as a second code path that hides which rule fired; NFKD + `\p{M}` gets monotonicity in one rule, pinned by the combining-mark tests (AC-10, AC-11).
`isBooleanFlag` shares `normalize`, so its exact match now survives format chars. `SyspropSecrets` keeps `CONTROL_CHARS` (unchanged); its fragment branch calls `isSensitive` (`SyspropSecrets.java:50`), so the HTTP sysvalue mask and the 4133 fence (`SyspropWriteFenceEventHandler.java:61`) inherit the change — only toward **more** masking; the explicit-list branch is unchanged. **Live effect measured (dev, count-only, 2026-11-15):** 17 of 164 `los_sysprop` syskeys contain whitespace, 0 contain non-ASCII, 0 change classification when whitespace is removed. PRD: census added to §5.1 (none expected to flip; a flip would only mask more and make the fence refuse a scope change on that key). **Blind spot (named):** cross-script homoglyphs (e.g. Cyrillic letters) are not folded by NFKD — still logged raw; accepted (debug log, 5 sites).

### Fix E — Docs
`⏳ pending-merge(SBDEV-4148)` markers: sysprop catalog `:516,522,526` (both rows "deleted by V2.2.53"); keycloak-role-matrix `:788` §7 (row deleted; was a placeholder); entity report `:136` (password invariant); function-to-docs-map `:222` → this plan; proposals-register P99 → "taken by SBDEV-4148".

### Fix F — Rotation hand-off (D1; DevOps, no code)
DevOps forces a Keycloak required-action password reset for every name in the captured list (§5.1) that exists in Keycloak, plus seed ids 0/1 if present; names without a Keycloak account (incl. the V2.2.09 system user) are skipped. List out-of-band only. Rotation proceeds from the capture whether or not V2.2.53 has landed on a tenant.

## 5. Implementation steps (one commit each, worktree off fresh `origin/develop`)
1. **Tests first (wms-tdd-gate):** all §8 tests; every "red today" fails by **assertion**, not compile error (tests use the literal `"KeycloakHasIt"` and find callbacks by annotation reflectively). Pins (AC-8, AC-9a, AC-10 whitespace / String-half / combining-mark, AC-11) are mutation-checked instead.
2. **Fix A** + `UserPasswordSentinelMigrationIT`; collision script clean.
3. **Fix B** + serialization inversion + `UserPasswordInvariantIT`; S8 + S8b together.
4. **Fix C + D.**
5. **Fix E**, full suite vs baseline, rails (§8), verify-docs; PR into `develop`.

### 5.1 Prerequisites
| Area | Prerequisite | Owner | Gate |
|---|---|---|---|
| DB state | **WineCo PRD measured** (D3): rows, sentinel, MD5-shaped, `'!'`, Flyway head, and the two dead keys (count, and count where sysvalue differs from the V2.2.00 placeholder — if non-zero that credential needs rotating, since V2.2.53 deletes it). **On WineCo and the 3 measured PRDs** also the syskey census for Fix D, count only: `SELECT count(*) FILTER (WHERE syskey ~ '[[:space:]]') AS ws, count(*) FILTER (WHERE syskey ~ '[^[:ascii:]]') AS non_ascii, count(*) AS total FROM los_sysprop;` (dev: 17 / 0 / 164). If `ws + non_ascii > 0`, run those syskeys through `SyspropSecrets.isSecret` old vs new in a scratch unit harness; expected 0 flips (a flip only masks more) | Nam / DevOps | before PRD promotion |
| Data migration — **capture, per deployment** | Flyway is not per tenant: the first pod of an image containing V2.2.53 runs `migrateAll` over **every active tenant** of its landlord (§3). So for **each PRD deployment/landlord**, capture **all** its active tenants (landlord `tenant_db_configuration` active rows, incl. WineCo if it shares one) **before the first pod of the release starts there** — any boot counts (promotion, restart, hotfix). Query text (read-only; output out-of-band only): `SELECT name, (password = md5(name)) AS default_credential, created::date AS created FROM public.mywms_user WHERE password IS DISTINCT FROM 'KeycloakHasIt' ORDER BY name;` The list may be captured **any time from now**: no code path writes MD5 (§1), so it stays valid until deploy. | DevOps | before first pod |
| Skipped tenants | Tenants the migrator skips (no `flyway_schema_history`, inactive, no `db_url`, opted out, or stuck behind a failed V2.2.46–52) get V2.2.53 later via backfill/runbook or a later boot — capture them before that run too (the per-deployment capture already covers active ones) | DevOps | before that run |
| **Sign-off (enforceable)** | DevOps posts a **count-only** comment on SBDEV-4148 per deployment: "landlord active tenants T = t; per tenant: captured N rows == live non-`KeycloakHasIt` count N" — T must equal the number of per-tenant lines. If the capture is more than a few days old at promotion, re-run the live count and restate it. The release is not promoted to a PRD deployment until that deployment has a complete sign-off | DevOps → Nam | before promotion |
| Pre-deploy probe | **On promotion day** (live data can create a duplicate between probe and boot), per PRD tenant, read-only, the two inner SELECTs of `V2.2.51…sql` as counts: `SELECT count(*) FROM (SELECT transferlane_id FROM customerorder WHERE transferlane_id IS NOT NULL AND state < 700 GROUP BY transferlane_id HAVING count(*) > 1) d;` and `SELECT count(*) FROM (SELECT staginglane_id FROM customerorder_batch WHERE staginglane_id IS NOT NULL AND state < 530 AND type = 'CLUB' GROUP BY staginglane_id HAVING count(*) > 1) d;` — both must be 0, else V2.2.51 RAISEs and V2.2.53 waits behind it. The post-rollout 3-part check catches a miss | DevOps | promotion day |
| External systems | Keycloak reset (Fix F) after capture; independent of deploy | DevOps | after capture |
| Deploy order | Release carries V2.2.46..V2.2.53; UAT (4 tenants + `meridiandemo`) receives it first — UAT is **not** a rotation target (capture optional as backup) | DevOps | release notes list all 8 **and** the release notes / promotion checklist carry `HOLD: V2.2.53 — do not promote to a PRD deployment until SBDEV-4148 has a sign-off for every active tenant on it` |
| Dev | Merging to `develop` auto-deploys dev and converts its 85 MD5 rows; dev is **not** a rotation target (no PRD credential source) | — | — |
| Flags / sysprops / config | none added; two sysprops deleted by migration | — | — |
| Access | read-only DB per PRD tenant | DevOps | — |
| Monitoring | **after the rollout completes** (no old pods — an old pod could re-save a pre-loaded legacy row within one request): per tenant `SELECT success FROM flyway_schema_history WHERE version = '2.2.53'` → true; `wms2.flyway.tenant.stale` = 0; boot log `Flyway startup migration finished: … 0 failure(s)`; capture query → 0 rows; dead-key count → 0 | DevOps | per tenant |

## 6. File change summary
| File | Change |
|---|---|
| `src/main/resources/db/migration/V2.2.53__password_keycloak_sentinel_and_delete_dead_login_sysprops.sql` | new |
| `src/main/java/net/aim_ai/wms/model/User.java` | constant, `@JsonIgnore`, default, callback, javadoc |
| `.../service/UserService.java` | delete `:145` and dead `setPassword` |
| `src/main/java/net/aim_ai/wms/RestConfiguration.java` | per-type collection block |
| `.../repo/jpa/UserRepository.java` | comments |
| `.../util/SensitiveMapRedactor.java` | NFKD + Cc/Cf/Z/M strip |
| `.../service/WmsConstants.java`, `PrinterController.java`, `SdrFunctionRules.java` | javadoc/comments |
| `src/main/resources/demo-datasets/meridian/fixtures.sql`, `verify.sql` | sentinel + predicate (one commit) |
| tests: `integration/schema/UserPasswordSentinelMigrationIT`, `integration/repository/UserPasswordInvariantIT`, `unit/model/UserPasswordInvariantUnitTest` (new); `UserPasswordSerializationTest`, `AccessChainSdrWriteExposureUnitTest`, `SensitiveMapRedactorUnitTest`, `SyspropSecretsUnitTest`, `UserServiceUnitTest` (extend) | |
| sbdocs (5 docs, Fix E) | markers |

## 7. Horizontal scalability and v2 constraints (A§9)
| # | Concern | Verdict |
|---|---|---|
| 1 | In-JVM state | No — static final constant |
| 2 | Connection pool | No — one migration per tenant at boot |
| 3 | Scheduled jobs | N/A |
| 4 | Long transactions | No — callback inside existing flushes; ≤100 rows; `lock_timeout 2s` |
| 5 | Request affinity | N/A |
| 6 | Retry/idempotency | Safe — callback idempotent; migration re-run tested (AC-3) |
| 7 | Tenant context | No — per-tenant Flyway at boot; callback context-free |
| 8 | Distributed lock / `@Version` | No — migration does not bump `version`; rolling-deploy residue self-heals on next dirty save |
| 9 | Cache invalidation | No `@Cacheable`/L2 over User; `sysprops` cache may hold dead keys until TTL/restart, unread |
| 10 | External notifications | N/A |

| # | v2 constraint | Verdict |
|---|---|---|
| 1 | OSIV disabled | N/A — no lazy access added |
| 2 | `tenantTransactionManager` | No change |
| 3 | `readOnly=true` | N/A |
| 4 | Caffeine eviction | N/A (no User cache); sysprop delete is out-of-request |
| 5 | Jakarta | Yes — `jakarta.persistence.PrePersist/PreUpdate` |
| 6 | H2 SQL | Check — `PickingorderBusinessServiceH2Test:198`, `MobileReplenishServiceH2Test:89` now persist the sentinel (harmless) |
| 7 | `BaseControllerTest` | N/A — exposure config only |
| 8 | Micrometer | N/A (existing `wms2.flyway.tenant.stale` used for monitoring) |

## 8. Acceptance criteria
State on develop: **red** (assertion failure today) or **pin** (green today; mutant given).

| AC | State | Test (`Class#method`) | Mutant → red | Message |
|---|---|---|---|---|
| AC-1 | red | `UserPasswordSentinelMigrationIT#migrate_shouldSetEveryPasswordToKeycloakHasIt` — at `2.2.52` assert ids 0/1 MD5-shaped and the `'!'` row present (non-vacuous), insert a `'x'` row | predicate narrowed to `~ '^[0-9a-f]{32}$'` | "row id %d still holds a non-sentinel password (len %d)" |
| AC-2 | red | `…#migrate_shouldTouchNoOtherColumn` — fingerprint every `mywms_user` column except password, incl. `version`, `modified` | add `version = version + 1` | "V2.2.53 changed column %s on row id %d" |
| AC-3 | red | `…#secondApply_shouldBeANoOp` — re-exec classpath script; fingerprint **both** `mywms_user` and `los_sysprop` (precedent `:150` covers only `los_sysprop`) | unpredicated `UPDATE mywms_user SET modified = now()` | "second apply of V2.2.53 changed %s fingerprint" |
| AC-4 | red | `…#migrate_shouldDeleteOnlyTheTwoDeadKeys` — plus workstation override under client 4148; whole-table count −3; `OMS_API_USER` survives | DEFAULT-only delete, or a third key | "expected los_sysprop count %d, got %d" / "OMS_API_USER deleted" |
| AC-5 | red | `UserPasswordInvariantUnitTest#newUser_passwordDefaultsToSentinel` (`new User().getPassword()` equals literal; null today); `#lifecycleCallback_overwritesAnyValue` (find method by `@PrePersist` reflectively, invoke after `setPassword("x")`); `#callback_carriesPrePersistAndPreUpdate` | delete initializer / either annotation | "new User password default is %s", "no @PrePersist method on User", "callback missing @PreUpdate" |
| AC-6 | red | `UserPasswordInvariantIT` — see mechanics below | per test | per test |
| AC-7 | red | `UserPasswordSerializationTest#passwordIsIgnoredOnDeserialization` (replaces `…StillAccepted…`); `#passwordIsNeverSerialized`, `#theRestOfTheUserStillSerializes` stay (pins) | revert to WRITE_ONLY | "inbound password was bound" |
| AC-8 | **pin** | `UserServiceUnitTest` existing assertion on the returned user (`:138`; `userRepository.save` is stubbed with `thenAnswer` at `:121,155`, no captor) kept on the literal. `UserService.create/createOrReuseUser` take no password parameter (`:87,:135`) | after Fix B: change the field initializer, or re-add `user.setPassword("other")` in `insertUserAndLocation` (mock repo → no callback) | existing assertion |
| AC-9a | **pin** | `AccessChainSdrWriteExposureUnitTest#userCollectionIsReadOnly` — `assertNoWrites(aggregate(User.class, COLLECTION), …)` via full config (loop masks it) | remove User from `SDR_WRITE_WITHDRAWN` **and** delete the block | add `.as("/v3/user collection must not accept POST — it can carry a password")` (default `assertNoWrites` text at `:113-119` names the access chain) |
| AC-9b | red | `#userBlocksAreReadOnlyWithoutTheLoop` — fresh `ExposureConfiguration`, mocked `RepositoryRestConfiguration`, reflectively invoke **only** `RestConfiguration#configureAccessChainMembershipWriteExposure` (`:200-293`; it only calls `config.getExposureConfiguration()`, so a lenient mock suffices), assert no writes on User COLLECTION, ITEM, and `groups` association through **new overloads `aggregate(ExposureConfiguration, …)` / `association(ExposureConfiguration, …)`** — the existing helpers (`:86-111`) call `configuredExposure()` (`:76-84`), which runs the full config incl. the loop, and would make this test vacuous | delete the new block with the loop untouched | "User %s writable without the SDR_WRITE_WITHDRAWN loop" |
| AC-10 | mixed | `SensitiveMapRedactorUnitTest` (assert via `redactedToString`): `#formatCharacterInsideKeyIsMasked` (U+200B, U+FEFF) **red**; `#controlCharacterInsideKeyIsMasked` (U+0000, U+0001) **red**; `#unicodeSpaceAndFullwidthKeyIsMasked` (NBSP inside key, fullwidth key) **red**; `#booleanFlagExemptionSurvivesFormatCharacter` — Boolean half **red** (exact match misses U+200B, so masked today), String half **pin**; `#surroundingWhitespaceAndCaseStillMasked` **pin** (`contains` ignores padding); `#combiningMarkAfterFragmentStillMasked` (`token`+U+0303, `password`+U+0307) **pin** (masked today) | remove the Cc/Cf strip → first two red; remove `\p{Z}`/NFKD → third red; String-half pin: exempt all values for the flag key; combining-mark pin: NFKC instead of NFKD, or drop `\p{M}` from the strip | "key %s logged unmasked" / "boolean flag %s wrongly masked" / "combining mark after fragment unmasked key %s" |
| AC-11 | **pin** | `SyspropSecretsUnitTest#isSecret_combiningMarkAfterFragmentStaysSecret` — `MY_PASSWORD`+U+0307 and `API_TOKEN`+U+0303 → `isSecret` true (true today) | NFKC instead of NFKD, or drop `\p{M}` from the redactor strip | "syskey %s lost secret classification" |

**AC-6 mechanics.** `BasePostgresIntegrationTest:61` is class-level `@Transactional("tenantTransactionManager")` and rolls back; IDs are SEQUENCE so INSERT waits for flush. **Never use the injectable `JdbcTemplate` here:** in the Postgres lane it is `PostgresTestSupportConfig.java:98-104`, a separate autocommit `DriverManagerDataSource` — it cannot see the test transaction's flushed rows, and its inserts commit and leak into the shared container (precedent warning `ReturnAdviceAutoReceiveIntegrationTest.java:68`). Instead, **both the legacy-row insert and every read-back go through `entityManager.createNativeQuery(...)`**, which runs on the EntityManager's connection inside the test transaction: it sees flushed rows and is rolled back with the test. Legacy insert: `INSERT INTO mywms_user (id, …, password, client_id, version) VALUES (nextval('seqentities'), …, '<non-sentinel, non-hash>', 0, 0)` with a unique probe name. Every save is `userRepository.saveAndFlush(...)` followed by `entityManager.clear()` before the read-back, so the read hits the DB row, not the L1 cache.
| Method | Setup → assert | Mutant → red, and why the kill is attributable | Message |
|---|---|---|---|
| `save_newUserViaPersist_persistsSentinel` | `new User()` (null version), `setPassword("x")`, `saveAndFlush`, clear → native `SELECT password` = sentinel | remove `@PrePersist`: the INSERT is flushed with `"x"` and the same-tx native read sees `"x"`. Only the persist callback can change the value between `setPassword` and INSERT (no `@PreUpdate` on an INSERT) | "persist path stored a non-sentinel password" |
| `save_newUserViaMergePath_persistsSentinel` | mirrors `insertUserAndLocation`: `setVersion(0)`, **`setPassword("x")`**, `saveAndFlush` (→ `em.merge` of a transient copy), clear → native read **by the id of the entity `saveAndFlush` returns (or by the unique probe name), never the original instance's id, which stays null because `em.merge` persists a copy** = sentinel | remove `@PrePersist`: the merged copy carries `"x"` into the INSERT. Without `setPassword("x")` the field default would mask the mutant, hence the explicit foreign value | "merge path stored a non-sentinel password" |
| `save_dirtyLegacyRow_rewritesSentinel` | native-insert legacy row; clear; `findById`, change firstname, `saveAndFlush`, clear → native read = sentinel **and** version = 1 | remove `@PreUpdate`: an UPDATE is flushed (firstname dirty, version 0→1) but with the loaded legacy password; the read sees the legacy value. The version assertion proves an UPDATE happened, so red is the callback, not a missing flush | "dirty save kept legacy password (row id %d)" |
| `load_andSaveUnchanged_issuesNoUpdate` | native-insert legacy row; clear; `findById`, `saveAndFlush` unchanged, clear → native read: version = 0 **and** password = legacy value | move the normaliser to `@PostLoad`: hydration rewrites the field, the entity is dirty, flush issues an UPDATE (version 1, sentinel) which the same-tx read sees. With the fix, no UPDATE is scheduled, so both stay | "version bumped on unchanged save (legacy row id %d)" |

**tdd-gate checklist:** each AC-6 test is **observed** green with the fix and red under its named mutant — not inferred.

### Testing plan
- **Unit:** AC-5, AC-7..AC-10. **Testcontainers IT:** `UserPasswordSentinelMigrationIT` copies `DeadCupsCredentialAndCycleCountSyspropRemovalMigrationIT` (own `PostgreSQLContainer(AppPostgresDBContainer.IMAGE)`, throwaway DB per test, watermark `2.2.52` → `2.2.53`, existence asserted first); `UserPasswordInvariantIT` (AC-6).
- **Rails / regression:** `*ArchTest`, `TenantCacheKeyUnitTest`, `*Contract*`, `SdrWriteWithdrawalContextTest`, `SyspropSecret*`, `SysvalueMasking*`, `SyspropSecretMaskingIntegrationTest`, `SysvalueMaskingCurrentValueIT`, **`DemoWarehouseDatasetsUnitTest`, `TenantWarehouseProvisioningIntegrationTest`** (demo reset of `meridiandemo` runs fixtures + verify), the two H2 tests in §7.
- **Full suite** vs develop baseline; every new assertion mutation-checked with the named mutant.

### Manual test (dev; the migration's real test is the IT)
Run counts with `/Users/np1076/dev/spk/owl/.claude/skills/wms-dev-probe/scripts/q.sh` (counts only; never select `password`). **Abort rule:** any precondition count ≠ stated → stop and re-triage. Dev counts measured 2026-11-15.
| # | Scenario | Precondition → dev count | Steps | Expected | Cleanup | Pass/Fail |
|---|---|---|---|---|---|---|
| M1 | migration applied | **before merge** (dev auto-deploys on push): total → 100; non-`KeycloakHasIt` → 86; dead keys → 2; Flyway head → 2.2.52 | merge; wait for dev deploy; re-run | 100 / 0 / 0; `flyway_schema_history` 2.2.53 success | none (irreversible by design) | |
| M2 | create path | M1 passed; `count(*) FROM mywms_user WHERE name LIKE 'sbdev4148-probe%'` → 0; `count(*) FROM location WHERE name LIKE 'sbdev4148-probe%'` → 0; take a `wms-dev-probe` `snapshot.sh` of `mywms_user` + `location` | `POST /v3/user/create` one probe user via `wms-dev-probe`; abort if Keycloak create fails | `count(*) … WHERE name LIKE 'sbdev4148-probe%' AND password = 'KeycloakHasIt'` → 1 | `GET /v3/user/delete/{id}` (WMS row + memberships), `POST /v3/user/deleteUserByUsername` (Keycloak). `insertUserAndLocation` also creates a Location named after the user (`:156`) that `deleteUser` (`:348-367`) does not remove: delete it on dev via `q.sh` (`DELETE FROM location WHERE name LIKE 'sbdev4148-probe%'`, expect 1 row, fresh and stock-free), then prove restore with `snapshot.sh` diff; if the delete is refused, record the 1-row residue on the ticket. Recount both → 0 | |
| M3 | SDR collection | total → 100 | `POST /v3/user` minimal body | 405; total still 100 | none | |
| M4 | demo reset | landlord `tenant.is_demo` for `meridiandemo` → 1 (landlord-dev MCP down 2026-11-15; measure at test time, else dev-infeasible) | `POST /landlord/tenants/meridiandemo/warehouses/{wh}/demo-reset` with `confirm` | 200; no "A local warehouse password survived" | reset is itself the restore | |
| M5 | redactor log | — | **dev-infeasible**: DEBUG on `UserController` is not enabled on dev and toggling loggers is out of probe scope; AC-10 covers it | — | — | n/a |

## 9. Risks
| # | Risk | Likelihood / impact | Mitigation |
|---|---|---|---|
| R1 | Migration destroys the rotation list (first pod migrates every tenant on the deployment) | High / high (process) | §5.1 per-deployment capture + count-only sign-off before promotion; header warning; capture valid from now |
| R2 | A skipped/stuck tenant migrates later without a capture | Medium / high | §5.1 skipped-tenants row; stale gauge + `flyway_schema_history` check |
| R3 | Callback not persisted / IT vacuous (first callback) | Low / high | AC-6 mechanics (flush + clear + native read, merge path, named mutants) gates step 3 |
| R4 | `@PreUpdate` churn / version bumps | Low | fires only when an UPDATE is scheduled; post-migration a no-op; AC-6 `load_andSaveUnchanged` |
| R5 | Onboarding `V1.0.04` re-seeds MD5 + dead keys for a future tenant | Low | converted on that tenant's first v2 Flyway run; backfill trap in header; P101 |
| R6 | Raw-SQL writers bypass the entity | Low | P101 (deferred) |
| R7 | Rolling deploy: old pod re-saves a pre-loaded legacy row | Very low (one request) | monitor after rollout completes; next dirty save under new code heals |
| R8 | Demo reset breaks | Removed | S8 + S8b one commit; provisioning IT in rails; M4 |
| R9 | Caches over User | None | no `@Cacheable`/L2 over User |
| R10 | Rollback | — | code rollback safe (`ignoreMigrationPatterns=*:future`, `StartupFlywayMigrator:38-40`; nothing reads the column); migration forward-only, hashes **not restorable by design** |
| R11 | Hashes remain in git/JARs/backups/WAL | Medium | Fix F rotation is the remediation |

## 10. Open questions / Resolved

**Resolved (Nam 2026-11-15) — do not reopen**
- **D1** DevOps forces Keycloak reset for every affected username still in Keycloak + seed ids 0/1; list out-of-band only.
- **D2** Entity rule + User-specific SDR collection block independent of the loop; fix stale javadoc; `userCollectionIsReadOnly`.
- **D3** WineCo PRD measurement is a §5.1 prerequisite before PRD deploy and rotation.
- **D4** One PR.
- **N1** Capture the rotation list before migrating (chosen over an audit table); rotation proceeds from the captured list.
- **N2** DB CHECK deferred → P101. **N3** Predicate `IS DISTINCT FROM 'KeycloakHasIt'`.

**Out of scope:** P98, P100, P101 (proposals register); `V1.0.04` MD5 seeds — residual, covered by migration order (R5). **Open:** none (number of PRD landlords is handled by the per-deployment gate).

## 11. Completeness checklist
| # | Item | Status |
|---|---|---|
| 0 | DB verified | ✓ §1 — dev (re-derived) + 3 PRDs; WineCo → §5.1 |
| 1 | Call sites enumerated | ✓ §0 incl. r1 variant-sentinel re-sweep |
| 2 | Adjacent sites | ✓ dead setter, redundant `:145`, demo `verify.sql`, stale comments |
| 3 | Back-compat | ✓ no live inbound binding; SDR POST already 405; demo reset kept green |
| 4 | Concurrency | ✓ no version bump; `lock_timeout 2s`; rolling-deploy residue R7 |
| 5 | Multi-tenant | ✓ boot migrates all active tenants; per-deployment capture + skipped tenants |
| 6 | Errors | N/A — no new error path |
| 7 | Observability | ✓ `flyway_schema_history`, `wms2.flyway.tenant.stale`, boot log, counts |
| 8 | Migration | ✓ V2.2.53, lock_timeout, idempotent over both tables, collision check, backfill warning |
| 9 | Tests | ✓ §8 — AC-1..AC-11 (AC-9a/9b), each labelled red/pin with mutant; AC-6 kills re-walked under same-tx native queries |
| 10 | Rollback | ✓ R10 |
| 11 | v1 | N/A — v1 reference-only |

**Verify script:** none. Every invariant is a JUnit/Testcontainers assertion; the operational invariants (capture before first pod, sign-off, Keycloak reset) are DevOps steps no repo script can observe — the sign-off comment is their enforcement.

## ADR — SBDEV-4148
- **Decision:** Option A — V2.2.53 converts every non-sentinel password and deletes two dead login sysprops; `User` enforces the sentinel (`@JsonIgnore` + default + `@PrePersist/@PreUpdate`); per-type SDR collection block tested without the loop; redactor NFKD + Cc/Cf/Z/M strip (monotonic — never masks less); DevOps Keycloak reset from a per-deployment capture signed off on the ticket before promotion.
- **Drivers:** offline-crackable MD5 previously exposed; irreversibility under boot-time Flyway across all tenants; smallest guard that survives future writers.
- **Alternatives considered:** B (+ CHECK) → P101; C (migration only) leaves writers open; D (unwritable column + `SET DEFAULT`) loses pre-migration convergence and adds DDL; E (drop column) disproportionate; **in-migration rotation side table** (architect synthesis: capture names into a table atomically before the UPDATE) — rejected per Nam's N1 choice of "capture before migrating" over an audit table (it would persist a "who had a legacy hash" list in tenant DBs and backups); rotation fallback "all pre-cutover users" — over-rotates.
- **Why chosen:** covers every JPA writer and the data, code and migration each safe alone; the one novel mechanism is proven by a flushing IT; the capture risk is reduced to a signed-off checklist item valid from today.
- **Consequences:** first JPA lifecycle callback in `src/main`; explicit `setPassword` silently overwritten; MD5 unrecoverable; raw SQL unguarded until P101; PRD release carries V2.2.46..V2.2.53; R1 relies on a human gate with a ticket sign-off.
- **Follow-ups:** P101 after 4148 is on every PRD tenant; WineCo measurement + per-deployment captures (§5.1); P98/P100 independent.

## 12. Review round 1 disposition
| Finding | Disposition |
|---|---|
| Critic H1 / Architect M1 — `verify.sql:12` missing | Fixed §0 S8b, §4 B, §6, rails §8, M4, R8; variant re-swept (2 files) |
| Critic H2 / Architect M2 — AC-6 vacuous, unreal mutant, merge path | Fixed §8 AC-6 mechanics (saveAndFlush + clear + native read, merge + persist, `@PrePersist`/`@PreUpdate`/`@PostLoad` mutants, base-class rollback addressed) |
| Critic M1 / Architect H1 — gate ≠ boot-time Flyway; unenforced | Fixed §5.1 per-deployment capture, skipped tenants, count-only sign-off, "valid from now"; §3 cites runner/migrator. Side table declined (Nam N1), recorded in ADR |
| Critic M2 — manual table | Fixed §8 manual: counts via `q.sh`, abort rule, cleanup routes, M1 before merge, demo row, M5 dev-infeasible |
| Critic M3 — labels / compile-red | Fixed §5 step 1 + §8 State column; literal-based assertions, annotation reflection; AC-8 pin with mutant; AC-10 halves labelled |
| Architect M3 — block not durably tested | Fixed AC-9b (only `configureAccessChainMembershipWriteExposure`, User collection/item/association) |
| Architect M4 — V2.2.53 behind failing V2.2.49–51 | Fixed §5.1 pre-deploy V2.2.51 probe + post-rollout `flyway_schema_history` + stale gauge; Fix F rotation independent |
| Critic L1 — RestConfiguration path | Fixed §0 S4, §3, §6 |
| Critic L2 — fixtures lines | Fixed `:21,33-35` |
| Critic L3 — AC-9 message | Fixed — explicit `.as(...)` on AC-9a |
| Critic L4 / Architect L6 — redactor blind spots | Fixed §4 D: compatibility folding + `\p{Z}` included (r2: NFKD, not NFKC — see round 2), homoglyphs named as accepted blind spot; SyspropSecrets inheritance stated |
| Critic L5 — §3 flow + key files, §2 File:LINE | Fixed §2, §3 |
| Critic L6 — UAT | Fixed §5.1 Deploy order (not a rotation target; optional backup) |
| Critic L7 — dev conversion on merge | Fixed §5.1 Dev row (not a rotation target) |
| Critic L8 — placeholder quoted / header | Fixed — placeholder no longer quoted; header says "no credential value" |
| Critic gap — first-callback ArchTest | Declined: one callback, documented in User javadoc; an ArchTest for a single precedent adds rule surface without a second instance to guard |
| Architect L1 — lock_timeout | Fixed Fix A |
| Architect L2 — fingerprint both tables | Fixed AC-3 |
| Architect L3 — check after rollout | Fixed §5.1 Monitoring, R7 |
| Architect L4 — delete `:145` | Fixed S2, Fix B, AC-8 mutant |
| Architect L5 — `@PreUpdate` wording | Fixed Fix B callback semantics, R4 |
| Architect L7 — WineCo dead-key check | Fixed §5.1 DB state (count only) |
| Architect antithesis — unwritable column | Declined as Option D (Options table + ADR) |

### Review round 2 disposition
| Finding | Disposition |
|---|---|
| Architect H1 — IT `JdbcTemplate` is a separate autocommit DataSource | Fixed §8 AC-6 mechanics: legacy insert + every read-back via `entityManager.createNativeQuery` in the test tx after `saveAndFlush` + `clear`; each case and mutant re-walked with why the kill is attributable; tdd-gate "observed" checklist |
| Architect M1 — NFKC composes marks, unmasks keys masked today | Fixed §4 Fix D: NFKD + strip `\p{M}` (chosen over "old OR new", justified); pins `#combiningMarkAfterFragmentStillMasked` (AC-10) and `SyspropSecretsUnitTest#isSecret_combiningMarkAfterFragmentStaysSecret` (AC-11), mutant = NFKC / no `\p{M}` |
| Architect L1 — AC-9b helpers run the full config | Fixed AC-9b: `aggregate`/`association` overloads taking an `ExposureConfiguration` |
| Architect L2 — PRD syskey census | Fixed §5.1 DB state: count-only whitespace/non-ASCII census on WineCo + 3 PRDs, flip check if non-zero |
| Architect L3 — V2.2.51 probe point-in-time | Fixed §5.1: run on promotion day |
| Critic L1 — M2 orphan Location | Fixed M2: location precondition, `q.sh` delete of the probe location + `snapshot.sh` diff, residue recorded if refused |
| Critic L2 — merge-path test needs a foreign password | Fixed AC-6 merge row: `setPassword("x")` |
| Critic L3 — promotion hold + active-tenant count | Fixed §5.1 Deploy order (HOLD line in release notes / promotion checklist) and Sign-off (T = active tenants; re-count if capture is stale) |
| Critic L4 — AC-8 wording | Fixed: "existing assertion on the returned user", `thenAnswer` stub, no captor |
| Critic L5 — V2.2.51 query text | Fixed §5.1: both count queries inlined |
| Critic L6 — dev syskey census | Fixed §4 Fix D: dev 17/164 whitespace, 0 non-ASCII, 0 reclassified; PRD → §5.1 |
| Architect r3 L1 — merge-path read-back must use the returned entity's id | Fixed AC-6 merge row: read back by the id `saveAndFlush` returns, or by the probe name |
