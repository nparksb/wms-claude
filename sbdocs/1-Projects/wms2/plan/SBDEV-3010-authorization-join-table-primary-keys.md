---
title: "WMSv2: the Flyway migrations declare no uniqueness on the authorization join tables — every unique index in the running estate was applied out-of-band, under three different naming conventions, and production has none of them"
ticket: "SBDEV-3010"
ticket_url: "https://app.clickup.com/t/868kua912"
type: "bugfix"
priority: "normal"
status: "PR SUBMITTED 2026-08-22 — wms2-api PR #184, commit aa2b257, branch bugfix/SBDEV-3010-authorization-join-table-primary-keys, base develop @ d70204c. ClickUp moved to pr submitted. NOT MERGED, NOT applied to any live tenant. Three independent review passes (6 + 10 + 8 findings, all 24 reproduced and all fixed) — T3 lanes, focused doc. Worktree .claude/worktrees/wms2-api/SBDEV-3010, branch bugfix/SBDEV-3010-authorization-join-table-primary-keys, REBASED onto origin/develop @ d70204c (PR #183 / SBDEV-2967-B landed mid-session and took V2.2.19), 0 behind. Migration V2.2.20 written + PROVEN: 540 assertions pass / 0 fail across 14 tenant shapes + 4 abort/drift scenarios x PG14 + PG16, 26 mutants killed (each verified to fail for the RIGHT reason), green control. 8 tenants measured, zero duplicates. Lane 2 found 3 Medium: an INVALID index treated as protection, the harness not checking its own shape setup (vacuous green), and no per-table exception handling (one drift cost all 5 tables their key). Also caught one fix of mine that was INERT and one that had been silently REVERTED. Suite 5437 run / 2 failures, both the documented pre-existing ones (OptionalSafetyArchTest, MobilePalletizingServiceTest) — Java edits are comment-only, zero executable lines changed. mvn clean compile green. NOT reviewed by an independent lane; NOT committed; NO PR."
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-22
updated: 2026-08-22
db_verified: true
related:
  - SBDEV-3011-delete-role-join-table-cascade.md
  - ../../../3-Resources/architecture/wms2-keycloak-role-matrix.md
  - ../../../2-Areas/runbooks/wms2-apply-pending-tenant-flyway.md
tags:
  - plan
---

# WMSv2: no uniqueness on the authorization join tables in source control

**Ticket:** [SBDEV-3010](https://app.clickup.com/t/868kua912)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** normal (nothing is broken today — see §1.4)
**Status:** PR submitted 2026-08-22 — [wms2-api PR #184](https://github.com/SiteBossInc/wms2-api/pull/184), commit `aa2b257`. Not merged; not applied to any live tenant. Three independent review passes complete (24 findings, all reproduced and fixed)
**Date:** 2026-08-22

**Base:** `origin/develop` @ `d70204c` — the merge of [wms2-api PR #183](https://github.com/SiteBossInc/wms2-api/pull/183) (SBDEV-2967-B). Worktree `.claude/worktrees/wms2-api/SBDEV-3010`, branch `bugfix/SBDEV-3010-authorization-join-table-primary-keys`, 0 behind.

> ⚠ **The base moved during this session.** Branched at `8dbe8b1` (PR #182 / SBDEV-3012), then PR #183 merged and **took `V2.2.19`** — the exact version the ticket said was free. Rebased onto `d70204c`; no overlap with #183; `V2.2.20` re-confirmed free by the repo's own collision checker. This is the third time this ticket's version note has gone stale, and the second time inside 24 hours.

> **Tier: T3**, deciding factor = *Flyway migration on authorization tables*. The router (now `.claude/skills/wms-triage/SKILL.md`; it lived in `wms-bugfix-plan/SKILL.md` when this plan was written) routes migrations to T3 on execution risk regardless of the `normal` ClickUp priority. Artifacts held to a focused doc rather than the full shape, because the change is one SQL file and the risk is concentrated in exactly two places: the idempotency predicate, and the per-tenant divergence it has to absorb.

---

## §0 — What this plan changes relative to the ticket

The ticket has been re-scoped twice and was wrong both times. It is now largely right, but four things measured 2026-08-22 differ from what it says. **Read this section before the ticket body.**

| # | Ticket says | Measured 2026-08-22 | Consequence |
|---|---|---|---|
| 1 | "next free is `V2.2.19`" | `V2.2.19` was taken by the then-unmerged `SBDEV-2967-B` branch, and **merged to `origin/develop` as PR #183 during this session**. Highest on `origin/develop` is now `V2.2.19` | **Use `V2.2.20`.** Re-sweep again immediately before the PR — this note has now gone stale three times, twice inside 24 hours. Use `db/check-migration-version-collision.sh` (fixed in §9.4; it was reporting every version free) |
| 2 | Finding 2: indexing `mywms_user_mywms_role` is "a clear win independent of uniqueness" | The table holds **0 rows on all five tenants** including PRD. A seq scan over an empty table is free. The repo's own `db/audit-access-invariants.sql:264-271` already records it as 0 rows on all six DBs | **There is no performance win.** The composite PK indexes `user_id` as its leading column, which fully satisfies Finding 2. No second index — see §3.4 |
| 3 | Finding 4 implies two provenances (Flyway vs hand-applied) | **Three.** And the divergence is finer than the ticket's table: hydra-uat holds a *plain unique index* on the two group tables but a *real PRIMARY KEY* on `mywms_role_mywms_function` and `shippingmethod_shipperid` | The migration needs **three** branches — create, promote, skip — not two. §3.2 |
| 4 | Scope item 4: decide what `message_archived` should key on | `message_archived` **must be excluded.** It can already hold duplicate `id`s today, silently | Adding a PK there would permanently break the archive job on an affected tenant. §5.1 |

One further correction to my own first pass: the onboarding schema `db/v1-to-v2-onboarding/schema/V1.0.01__wms_tables.sql` declares **no** uniqueness on these join tables either (its only commented-out `ALTER` on `mywms_user_mywms_role` is an `OWNER TO jboss` leftover, not a constraint). So the `_pkey` constraints on the two wineco tenants did **not** come from the onboarding script — their provenance is unidentified, and `_pkey` is simply the name PostgreSQL auto-assigns to an unnamed `ADD PRIMARY KEY`.

---

## §1 — Measured ground truth

### 1.1 Estate index/constraint state (2026-08-22, all five reachable tenants)

`indisunique` / `indisprimary` read from `pg_index`, not from constraint names.

| Table | hydra **PRD** | hydra-uat | wineco-dev | wsl-wineco-uat | shipitez-nywh-uat |
|---|---|---|---|---|---|
| `mywms_group_mywms_role` | none | `_uindex` UNIQUE, **not PK** | `_pkey` **PK** | `_pkey` **PK** | none |
| `mywms_group_mywms_user` | none | `_uindex` UNIQUE, **not PK** | `_pkey` **PK** | `_pkey` **PK** | none |
| `mywms_role_mywms_function` | none (1 non-unique idx) | `_pk` **PK** | `_pkey` **PK** | `_pkey` **PK** | none |
| `mywms_user_mywms_role` | **no index at all** | none | none | none | none |
| `shippingmethod_shipperid` | none | `_pk` **PK** | `_pkey` **PK** | `_pkey` **PK** | none |
| `message_archived` | none | none | none | none | none |

PRD confirmed to have **zero** primary keys across all six tables. The ticket's headline — *production is the least protected tenant in the estate* — is correct.

### 1.2 Three naming conventions, three provenances

- `mywms_group_mywms_role_grouplist_id_index` — matches `V2.2.00__base_v2_schema.sql:4510` verbatim. **Flyway-provisioned.** PRD, shipitez-nywh.
- `index_mywms_group_mywms_role_grouplist_id` (prefixed) + `_pkey` — matches neither the base schema nor the onboarding script. **Unidentified provenance.** wineco-dev, wsl-wineco-uat.
- `..._uindex` / `..._pk` — **hand-applied.** hydra-uat.

**Nothing may key off a constraint or index name.** hydra-uat's existing primary keys are named `_pk`; a migration that probed for `_pkey` would have concluded "absent" and created a duplicate.

### 1.3 Postgres version split

**PRD is PG 14.23. Every other tenant is PG 16.10.** All syntax below is PG11+ (`indnkeyatts`) or PG9.1+ (`ADD PRIMARY KEY USING INDEX`), so both majors are covered — but this split is worth carrying forward, since it is the first time it has been written down in a plan.

### 1.4 Nothing is broken today

- **Zero duplicate key groups** on all six tables × all five tenants. The `ALTER` is safe to apply as of 2026-08-22.
- All key columns are already `NOT NULL` on every tenant (0 nullable columns measured), so `ADD PRIMARY KEY` needs no table rewrite and no `NOT NULL` backfill scan.
- Row counts are tiny — largest is `mywms_role_mywms_function` at 148 rows (hydra-uat). Lock duration is not a consideration.

---

## §2 — Why the Java layer needs no change

This was the open question that gated the design; it is now closed.

**`@EmbeddedId` already declares these column pairs as the entity identity.** A composite PK on the same columns is precisely the shape the mapping describes, so adding it cannot require a mapping change — it makes the database agree with what Hibernate already believes. Only a *surrogate* key would force entity rework, and that is explicitly not the chosen design.

Hibernate never inspects these constraints in any profile:

| Profile | `ddl-auto` | Effect |
|---|---|---|
| prod / dev | `none` (`application.properties:70`) | never inspects the schema |
| unit tests | `validate` (`src/test/resources/application.properties:42`) | validate covers tables, columns and types **only** — not PKs, unique constraints or indexes |
| integration | `create-drop` (`application-integration.properties:27`) | Hibernate **generates** the DDL from the entities; `@EmbeddedId` emits `PRIMARY KEY`, so the IT schema has had these PKs all along |

That last row reframes the change: the integration-test schema already has composite PKs on these tables. Only the Flyway-provisioned production schema lacks them. **This migration makes production match the entity model rather than diverge from it.**

The `@ManyToMany @JoinTable` half is indifferent — three of the five tables are mapped twice, once as an explicit `@Entity` with `@EmbeddedId` (`UserGroupUserRole`, `UserGroupUser`, `UserRoleUserFunction`) and once as a join table (`UserGroup.roles`, `User.groups`, `UserRole.functions`, all `FetchType.EAGER`). Hibernate requires no key on a join table.

**Corollary: `UNIQUE` would have been functionally sufficient.** PK was chosen for replica identity and convergence with the entity model, not because UNIQUE was inadequate. Recorded so a future reader does not re-derive it.

---

## §3 — The change

One file: `src/main/resources/db/migration/V2.2.20__authorization_join_table_primary_keys.sql`.

### 3.1 Tables in scope (5)

| Table | Key columns |
|---|---|
| `mywms_group_mywms_role` | `(grouplist_id, rolelist_id)` |
| `mywms_group_mywms_user` | `(grouplist_id, userlist_id)` |
| `mywms_role_mywms_function` | `(rolelist_id, functionlist_id)` |
| `mywms_user_mywms_role` | `(user_id, roles_id)` ← note: **not** the `*list_id` convention of the other three |
| `shippingmethod_shipperid` | `(shipperidset_id, shippingmethodset_id)` |

`mywms_user_mywms_role`'s column names are Hibernate defaults, which is plausibly *why* it alone never received a hand-made index.

### 3.2 Three branches, selected by column set

For each table, detect whether a **unique index whose key columns are exactly the pair** already exists — order-insensitive, excluding partial (`indpred`) and expression (`indexprs`) indexes, keyed on `pg_attribute.attname`, never on the index name:

| Detected | Action |
|---|---|
| unique index that **is** the PK | skip, `RAISE NOTICE` |
| unique index that is **not** the PK | `ALTER TABLE … ADD CONSTRAINT <tbl>_pkey PRIMARY KEY USING INDEX <existing>` — adopts the index in place, no rebuild, renames it to the constraint name |
| nothing | `ALTER TABLE … ADD CONSTRAINT <tbl>_pkey PRIMARY KEY (cols)` |

All three branches are exercised by **hydra-uat alone** (§1.1), which makes it the highest-value verification target.

### 3.3 Duplicate pre-flight that fails loudly

Before each `ALTER`, count duplicate key groups and `RAISE EXCEPTION` with the table, the count, the columns and a pointer to the dedupe runbook. The chain still stops — that is unavoidable and correct — but the operator gets an actionable message instead of a bare `could not create unique index`. This is the ticket's scope item 3, moved *into* the migration so it cannot be forgotten.

### 3.4 No second index on `mywms_user_mywms_role`

The composite PK indexes `user_id` as its leading column. A separate index on the trailing `roles_id` would have no measurable benefit on a table that is empty on all five tenants, and would be one more object to keep. **Finding 2 is satisfied by the PK.** If the direct user→role path is ever activated (see §6), add the trailing index then.

---

## §4 — Why adding uniqueness is safe against every write path

Adding uniqueness where there was none can convert a today-silent duplicate into a hard `23505`. Checked all six writers the ticket names:

1. **`UserFunctionService.addRoleToFunction`**, 2. **`UserRoleService.addGroupToRole`**, 3. **`UserGroupService.addUserToGroup`** — guard-then-insert. They gain a `23505` **only** in the genuine concurrent race. That is the intended behaviour change, not a regression.
4. **`UserGroupService.replaceGroupRoles`**, 5. **`UserService.replaceUserGroups`** — already a **set difference**, added by SBDEV-3012 precisely so no retained row is re-inserted. `UserService.java:200-205` states the reason in as many words: *"Hibernate's `ActionQueue` emits inserts BEFORE deletes within a flush and `CrudRepository` offers no `flush()` to sequence around it, so clear-then-reinsert re-inserts every retained membership while its row still exists."* Nothing to trip.
6. **Non-Hibernate writers** — the base dump's raw `INSERT`s run before the PK exists (V2.2.00 precedes V2.2.20); SDR endpoints go through the same entity mapping.

**No wholesale collection reassignment exists.** Zero calls to `setGroups` / `setRoles` / `setFunctions` on our entities anywhere in `src/main/java` — the `KeycloakService` hits are on Keycloak's own `UserRepresentation`, an unrelated class. So Hibernate never triggers its delete-all-then-recreate path on these EAGER `@ManyToMany` collections.

---

## §5 — Explicitly out of scope

### 5.1 `message_archived` — excluded, and this is a finding

`MessageRepository.archiveMessages` is an **unbounded** `INSERT INTO message_archived SELECT * FROM message WHERE created < :refDate`, while `deleteMessages` is **batched** in a loop. Two paths exit that loop leaving rows archived-but-not-deleted:

- `CleanUpOldMessageJobService:99-101` — on `InterruptedException` the loop `return`s after `archiveOnce` already copied everything.
- `CleanUpOldMessagesJob:90` — a `deleteOnce` failure is caught and logged per tenant; the job moves to the next tenant.

Either path means the **next** run re-archives the same rows. `message_archived` can therefore already hold duplicate `id`s, silently. A PK on `message_archived.id` would convert that into a **permanently failing archive job** on any affected tenant. It is also a different subsystem with a different owner.

Measured 0 rows on all five tenants today, so nothing has fired yet — which also means the hazard is established from the code paths, not from data.

Per the ticket policy this is **not** a new ticket. It is recorded here and belongs to the message-cleanup code path if anyone visits it.

### 5.2 The `mywms_user_mywms_role` dead-grant path

`RestConfiguration:40` exposes `UserUserRole` over a full `CrudRepository`, so `/v3/userUserRole` is **writable**, while the runtime gate `UserRepository.getAllRoles` walks **only** the group path. A role granted directly there is silently ineffective. Already documented at `db/audit-access-invariants.sql:264-271`, and it belongs to the SBDEV-3013 SDR write-exposure neighbourhood. **No new ticket.** This plan hardens the table's key; it does not change its reachability.

### 5.3 Retiring the redundant non-unique composite indexes

`V2.2.00` creates non-unique composite indexes on the two group tables (`..._grouplist_id_rolelist_id_index`). Once a PK covers the same columns they are redundant. Dropping them is a separate, purely-cosmetic change with its own risk of hitting a tenant where the name differs; **not** in this migration.

---

## §6 — Acceptance criteria (for the TDD gate)

Numbered so tests can cite them. A1–A6 are provable against a scratch Postgres; A7–A8 are code-level.

| # | Criterion |
|---|---|
| **A1** | On a tenant with **no** unique index on the pair, V2.2.20 creates a PRIMARY KEY on exactly those columns |
| **A2** | On a tenant with a **plain unique index** on the pair (not a PK), V2.2.20 promotes it to a PRIMARY KEY **without creating a second index** — index count on the table must not increase |
| **A3** | On a tenant that **already has a PK** on the pair — **under a name other than `_pkey`**, i.e. hydra-uat's `_pk` — V2.2.20 is a no-op and creates nothing |
| **A4** | Re-running V2.2.20 against an already-migrated database is a no-op (idempotent), on all three starting states |
| **A5** | On a tenant holding a duplicate key pair, V2.2.20 **fails** with a message naming the table, the duplicate count and the columns — not a bare `could not create unique index` |
| **A6** | After V2.2.20, a second insert of an existing pair raises `23505` on all five tables |
| **A7** | `V2.2.20` is the highest migration version in `db/migration/` and does not collide with any version on any remote branch |
| **A8** | The SBDEV-3012 javadoc claim *"has NO unique index on any Flyway-provisioned tenant"* is updated, in `UserGroupService.replaceGroupRoles` and `UserService.replaceUserGroups` — this migration makes it false |
| **A9** | A stray index already holding the target name does **not** abort the migration; a free name is chosen and warned about, and all five tables still get a key (added in review — §9.7) |
| **A10** | A table protected by a UNIQUE **constraint** is skipped with a `NOTICE`, keeps its uniqueness, gains no second index, and a re-run is still a no-op (§9.8) |

**A2 and A3 are the two that matter.** A name-keyed implementation passes A1 and fails both, and it fails them *silently* by leaving a duplicate index behind rather than by erroring.

### Mutation checks (the floor — required, not optional)

Every assertion above must be shown to fail when what it protects is broken:

| Mutant | Must red |
|---|---|
| M1 | replace column-set detection with `indexname LIKE '%_pkey'` → **A2, A3** |
| M2 | drop the `ADD PRIMARY KEY USING INDEX` branch, always create → **A2** (second index appears) |
| M3 | remove the duplicate pre-flight → **A5** (bare Postgres error, no table name) |
| M4 | drop `indpred IS NULL` / `indexprs IS NULL` → detection matches a partial unique index and skips a table that needs the PK |
| M5 | make the column comparison order-sensitive → **A2** on a reverse-column-order tenant (a duplicate index appears). This is the SBDEV-3005 defect class on these very tables |
| M6 | remove the free-index-name search → the whole `DO` block aborts on a stray `<tbl>_pkey`, so **every** table loses its key (§9.7) |
| M7 | remove the UNIQUE-constraint skip branch → that branch is load-bearing, not decorative (§9.8) |

---

## §7 — Rollout

1. **Re-sweep every remote branch for the next free version** immediately before the PR. `ls db/migration/` cannot see unmerged branches — that is exactly how the ticket's own version note went stale twice.
2. **Pre-flight duplicate counts per tenant per table** on dev, UAT **and prd** before the image lands. Zero as of 2026-08-22, but the window between now and deploy is not zero. The migration's own guard (§3.3) is a backstop, not a substitute — a tenant that fails freezes its whole chain, and **tenant migration failures never abort boot**, so nothing surfaces it.
3. Runtime Flyway is **default-ON in every environment** (see `sbdocs/` note on SBDEV-2801), so this applies on the next boot to landlord + every active tenant DB. Legacy psql-provisioned DBs are skipped.
4. Verify post-deploy with the §1.1 query per tenant: every one of the five tables should report `indisprimary = true`.

## §8 — Risks

| Risk | Severity | Mitigation |
|---|---|---|
| A duplicate appears between now and deploy → that tenant's chain freezes silently | Medium | §3.3 names the table and count; §7.2 re-checks at deploy time |
| `ADD PRIMARY KEY USING INDEX` takes ACCESS EXCLUSIVE briefly | Low | largest table is 148 rows |
| PRD is PG 14 while the tested majors skew 16 | Low | verified on both 14 and 16 (§6 harness) |
| A tenant is missing one of the five tables entirely | Low | migration `RAISE WARNING`s and skips rather than bricking the chain |
| SBDEV-2967-B merges first and takes another version | Low | §7.1 re-sweep |


---

## §9 — Results (2026-08-22)

### 9.1 Verification — the migration is proven, not asserted

There is **no CI lane that can catch this migration's central defect**: the v2 Testcontainers harness cannot boot (SBDEV-2217), and `ddl-auto` is `none` in prod / `validate` in unit tests — and *validate ignores keys and indexes entirely*. So a scratch-Postgres harness was built instead, and committed as `src/main/resources/db/verify-authorization-join-table-keys.sh` so it outlives this plan.

**342 assertions pass, 0 fail**, on PostgreSQL **14** (matches hydra PRD @ 14.23) and **16**, across **nine** starting shapes plus two abort scenarios — the three real ones from §1.1 plus six adversarial:

| Shape | Models | Exercises |
|---|---|---|
| `flyway` | hydra PRD, shipitez-nywh | create |
| `handapplied` | hydra-uat | **promote + skip + create in one tenant** |
| `wineco` | wineco-dev, wsl-wineco-uat | skip + create |
| `partial-expr` | *hypothetical* | a partial and an expression unique index must **not** count as protection |
| `reversed-cols` | *hypothetical* | a reverse-column-order unique index must be promoted, not duplicated |
| `uq-constraint` | *hypothetical* | a UNIQUE **constraint** is left as-is (documented residual, §9.7) |
| `name-collision` | *hypothetical* | a stray index already holding the target name must not abort the migration (§9.7) |
| `fk-referenced` | *hypothetical* | an FK's `conindid` must not be mistaken for a UNIQUE constraint (§10, finding 3) |
| `pkey-named-plain-idx` | *hypothetical* | a plain unique index already called `<tbl>_pkey` is adopted in place, not renamed (§10, finding 2) |
| *abort:* duplicates | — | must abort naming the table + ticket, not a bare Postgres error |
| *abort:* NULL drift | — | must abort naming the table + ticket (§10, finding 4) |

### 9.2 Mutation results — every assertion earns its green

| Mutant | Outcome |
|---|---|
| M1 name-keyed detection (`indexname LIKE '%_pkey'`) | **killed**, 36 fail |
| M2 always create, never promote | **killed**, 20 fail |
| M3 duplicate pre-flight removed | **killed**, 2 fail |
| M4 accept partial/expression indexes as protection | **killed**, 2 fail |
| M5 order-sensitive column comparison | **killed**, 8 fail |
| M6 free-name search neutered | **killed**, 2 fail |
| M7 UNIQUE-constraint skip branch removed | **killed**, 2 fail |
| M8 name search moved back above the skip decisions | **killed**, 6 fail |
| M9 `contype IN ('p','u')` filter removed | **killed**, 2 fail |
| M10 NULL pre-flight removed | **killed**, 2 fail |
| M11 `v_idx_name` exclusion removed | **killed**, 2 fail |
| control (unmodified) | **green**, 342/0 |

Two harness defects were found and fixed *before* trusting any row: the column-set probe compared `array_agg(ORDER BY attname)` against **declaration** order, false-negativing 2 of the 5 tables; and A6 was **vacuous** in two shapes because it only probed a table that already had a unique index there.

### 9.3 Build

- `mvn clean compile` — green.
- `mvn test` — **5437 run, 2 failures**, both the documented pre-existing ones on clean `develop` (`OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses`, `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`). The Java edits are **comment-only — zero executable lines changed** (verified by diffing out every comment line), so neither failure can be attributable to this change.
- `src/test/resources/archunit_store/` was mutated by the test run and **reverted**, per the known landmine.

### 9.4 A tooling defect found and fixed directly

`src/main/resources/db/check-migration-version-collision.sh` — the repo's own guard against exactly this ticket's version problem — **failed open**. `git ls-tree -- <pathspec>` resolves relative to the **current directory**, but `MIG_DIR` is repo-root-relative, so running the script from its own directory matched nothing and reported `RESULT: clear` for every version. Measured: it answered **"FREE: V2.2.19"** while V2.2.19 was already merged on `origin/develop`.

Fixed directly (per the monorepo `CLAUDE.md` rule that tooling defects are fixed, not filed): anchor to `git rev-parse --show-toplevel`, plus a fail-closed guard that refuses to report "clear" when zero versions are found, since that is impossible in this repo.

**The first version of that guard was itself broken** — `${#ARR[@]}` on a declared-but-never-assigned associative array trips `set -u`, and with no `set -e` the script carried on and still printed "clear". Caught by mutation-testing the fix rather than by reading it. Now `${ARR[*]:-}`; both mutants (remove the `cd`, break `MIG_DIR`) fail closed with exit 2, and the control returns exit 1 for a taken version and 0 for a free one.

### 9.5 Ordering dependency checked

`V2.2.19` (which landed mid-session) seeds into `mywms_role_mywms_function` — one of the five tables — and now runs **immediately before** V2.2.20. All **five** of its `INSERT`s are `NOT EXISTS`-guarded, so it cannot manufacture the duplicates that would make V2.2.20 fail.

### 9.6 What is NOT done

- **No independent review lane has seen this.** Per the standing rule never to self-approve, that gate is open.
- **Nothing is committed and there is no PR.**
- **Not applied to any live tenant.** §7's pre-flight duplicate re-check must run against dev, UAT and prd immediately before the image lands — the zero-duplicate measurement is from 2026-08-22 and the window to deploy is not zero.
- `A8` is satisfied for the four Java sites, but `V2.2.18`'s header comment repeats the same false claim and was **deliberately left alone**: editing an applied migration changes its Flyway checksum and would fail `validate` on every tenant that already ran it.


### 9.7 A defect found in review, in my own migration

Reviewing the diff before commit surfaced a real bug I had introduced. **Index names are unique per *schema*, not per table.** Step (1) correctly declines to treat a *non-unique* index as protection — but if such an index happens to be named `<tbl>_pkey`, step (5b) then tries to create a constraint of exactly that name and Postgres refuses:

```
ERROR:  relation "mywms_group_mywms_role_pkey" already exists
```

Because the whole file is **one `DO` block**, that is not a partial failure: **zero of the five tables got a key**, measured. The tenant's entire Flyway chain would freeze on a purely cosmetic name clash, with an error mentioning neither the ticket nor a remedy — the exact failure mode §3.3 exists to prevent, reintroduced through a different door.

Not reachable on today's estate (no tenant has such a stray index — every index name was enumerated), but the consequence is severe and the cause is cheap to remove. **Fixed** by searching for the first free name, preferring `<tbl>_pkey`, and `RAISE WARNING` when it has to settle for something else — functional convergence (a PK exists, uniqueness enforced) matters more than the name matching. Verified: all 5 PKs created, duplicate insert rejected, clear warning emitted. Pinned as harness shape `name-collision` and mutation-checked as **M6**.

The lesson generalises: **a single `DO` block makes every per-table failure an all-or-nothing failure.** That is the right transactional shape for a migration, but it means any avoidable error must be designed out rather than left to chance, because the blast radius is the whole tenant chain rather than one table.

### 9.8 Documented residual divergence

A table protected by a **UNIQUE constraint** (as opposed to a PK or a plain unique index) is deliberately **left alone** — converting it would mean dropping and re-adding a constraint on a path no live tenant exercises, and the protection this ticket exists to add is already present. No tenant in the estate is in that state today. Behaviour is pinned by harness shape `uq-constraint` and mutation-checked as **M7**: the migration skips with a `NOTICE`, uniqueness keeps holding, no second index appears, and a re-run is still a no-op.


---

## §10 — Independent review (2026-08-22)

A `code-review` lane ran at `high` against the worktree diff. It reproduced the verification independently (236/0 at the time) and confirmed the writer-safety analysis and the live-estate duplicate census on four DBs of its own. It returned **six findings — one Medium, five Low. All six were reproduced and all six are fixed.** Every one was a real defect; none was rejected.

| # | Finding | Verdict | Disposition |
|---|---|---|---|
| **1** | **Medium — the verify script could false-green.** `docker run`'s exit status was unchecked, so a `port is already allocated` bind failure left the script grading whatever Postgres already owned 55414/55416. Reproduced: orphan containers under *different* names (which line 61's `docker rm -f` cannot reap) → the script printed **`172 pass, 0 fail` and exited 0**. Worse, `PGV` is read from whichever server answers, so an orphan pg16 on 55414 prints "PostgreSQL 16" twice and the advertised **PG14 coverage — the one that matches hydra PRD — silently evaporates behind a green exit** | **Confirmed** | `docker run … \|\| exit 2`; **assert the answering server's major matches the port** (55414→14, 55416→16) and abort if not; `fresh_db` no longer swallows a failed `CREATE DATABASE`. Pinned by squatting the port: exit 2, explicit FATAL, and **no `pass,` line at all** |
| **2** | Low — the free-name search ran *before* the step (2)/(3) skip decisions and counted the very object it was about to skip, so on the **wineco** shape (where `<tbl>_pkey` *is* the real PK) it emitted a WARNING immediately contradicted by the next line's "unchanged" NOTICE. Self-contradicting operator output on the two live wineco DBs that need no action; it would also needlessly rename a plain unique index legitimately called `<tbl>_pkey` to `_pkey_1` | **Confirmed** — reproduced verbatim, 4 spurious warnings | Name search moved **below** step (3), and `v_idx_name` excluded from the `EXISTS` probe (that name belongs to the object being promoted, not to "something else"). Two new shapes + **A11 message-stream assertions** |
| **3** | Low — `EXISTS (… WHERE pc.conindid = ix.indexrelid)` treats *any* constraint as a UNIQUE constraint, but **`pg_constraint.conindid` is populated for FOREIGN KEY too**. Anything that ever FKs to one of these join tables would flip `v_by_constr`, and step (3) would silently leave the table with **no PK** while announcing it "is protected by UNIQUE constraint-backed index" | **Confirmed** — verified on PG16 that a FK onto the pair yields `contype='f'` with `conindid<>0` | Tightened to `pc.contype IN ('p','u')`; new `fk-referenced` shape, mutant **M9** |
| **4** | Low — the duplicate pre-flight is **NULL-blind**: `GROUP BY` collapses all-NULL rows into one group, so a *single* NULL row passes and `ADD CONSTRAINT` then dies with a bare `column "x" contains null values` — the exact outcome the file's own rule #3 forbids | **Confirmed** | Added a NULL pre-flight raising an actionable SBDEV-3010 message; new NULL abort scenario, mutant **M10** |
| **5** | Low — the writer-safety list cited **inner** service methods, not the `AccessService` entry points (`addFunctionToRole:198`, `addRoleToGroup:268`), so it was un-re-verifiable by grep — a direct violation of this repo's own *never key an assertion on a method name* rule. It also **omitted the Spring Data REST write surface**, which for `shippingmethod_shipperid` is the **only** writer | **Confirmed** — every Java caller of `ShippingmethodShipperidRepository` is a read (`ShipperidService:75`, `MobilePalletizingService:224,407`, `ShipperIdController:100`) | List rewritten to cite `(class, line)` pairs with the entry points, and now states *why* SDR is safe: `save()` on a non-null `@EmbeddedId` makes `isNew()` false, so it routes through `em.merge()`, which SELECTs first |
| **6** | Low — the census said "five tenants" but the estate has **eight** reachable, and `c1wh-shipitez-uat` is a **fourth naming shape** (`_pk`-named *real* PKs on 4 of 5) | **Confirmed** — I re-measured all three myself: `c1wh-shipitez-uat`, `nywh-hydra-uat`, `hydra-v2t`, **0 duplicates on all 5 tables on all 3** | §1.1 and the migration header now say **eight tenants, zero duplicates**. `c1wh` adds no new code path (skip×4 + create×1) but is the concrete reason the probe must accept `_pk` as a legitimate PK, not only `_pkey` |

### 10.0 An eighth fix: the review's Medium was not fully closed by my first patch

Chasing finding 1 further turned up a hole my own fix had left. I had put the new PG-major assertion in a loop hardcoded to `for p in 55414 55416`, while `PORTS` is a documented override read *after* that loop. So a run with `PORTS` pointing anywhere else provisioned and asserted the two default ports, then ran every assertion against a **completely unverified** port — reinstating exactly the "grading the wrong database" hole the assertion exists to close, just through the override rather than through an orphan container.

I had also half-expected a crash here (`want` unbound under `set -u` for a port absent from the `case`) and was **wrong** — the hardcoded loop meant `want` was always set. The real defect was the opposite of the one I guessed: not a crash, a silent coverage gap.

Fixed by reading `PORTS` *before* the loop and iterating the same list the harness body uses, with an unknown port producing an explicit `WARNING` that the header's PG-major coverage claim does not apply to it — rather than crashing, or silently implying coverage it does not have. Verified: `PORTS=55499` warns and runs (171 assertions, one major), the default path is unchanged at 342/0.

### 10.1 What the review teaches about my own verification

Finding 1 is the one that matters, and it is not really about `docker run`. **My "only executable check on the migration's central claim" could print a green verdict while testing the wrong database on the wrong Postgres major.** I had already added a readiness gate for the *container-down* case after hitting it myself — but that gate passes happily when the port is answered by the *wrong* server, which is precisely the orphan scenario my own scratchpad runs created. A readiness check is not a correctness check.

Finding 2 is the counterpart lesson on the assertion side: the `wineco` shape was green while the migration emitted self-contradicting output, because **every assertion looked at the resulting schema and none looked at what the operator would read.** Structural assertions cannot see a bad message.

Both are the same failure class as §9.7 — I reported "0 fail, all mutants killed" three separate times, and each round a genuine defect was still there. The count of green assertions is not evidence about the things no assertion covers.

### 10.2 Also confirmed clean by the review

The review explicitly ruled out, with reasons: the `indkey::smallint[]` cast and `k.ord <= indnkeyatts` filter; `SELECT INTO` NULL semantics on no match; the `ORDER BY indisprimary DESC LIMIT 1` preference; `USING INDEX` not rebuilding the index; Hibernate's collection remove-before-recreate ordering (so a wholesale SDR collection PUT will not `23505`); landlord isolation in `StartupFlywayMigrator`; shell `sort` vs Postgres `name` collation in the probes; and the `${#ARR[@]}` / `set -u` rationale in §9.4, independently confirmed on bash 5.2.21.

It also noted an ordering fact worth carrying into rollout. I measured the head on all eight tenants myself:

| Tenant | Flyway head | Pending before V2.2.20 |
|---|---|---|
| **hydra PRD** | **2.2.16** | **V2.2.17, .18, .19 — then .20** |
| hydra-uat | 2.2.17 | .18, .19 |
| nywh-hydra-uat | 2.2.17 | .18, .19 |
| c1wh-shipitez-uat | 2.2.17 | .18, .19 |
| nywh-shipitez-uat | 2.2.17 | .18, .19 |
| wsl-wineco-uat | 2.2.17 | .18, .19 |
| wineco-dev | **2.2.19** | none — next boot applies .20 directly |
| hydra-v2t | **2.2.01** | **eighteen** migrations |

**V2.2.20 is last in a queue on seven of eight tenants**, so it is not the first thing that can go wrong — any earlier pending migration failing stalls the chain *before* V2.2.20 is reached, and a stalled chain is silent. Two consequences for §7: this migration's success on `wineco-dev` (the only tenant where it applies immediately) proves nothing about the others; and `hydra-v2t`, eighteen migrations behind, is the tenant most likely to fail on something entirely unrelated and be misread as this change breaking.


---

## §11 — Second independent review (2026-08-22), over the fixes

A second lane was pointed *only* at the seven fixes from §10, with instructions to break them rather than re-review the design. It re-established the baseline itself (342/0), wrote its own mutants, and left the worktree byte-identical.

**Verdict on the fixes: all seven correct, and every one load-bearing** — it killed six independent mutants and each died on precisely the assertion its fix had added. It then found **ten further findings (3 Medium, 7 Low)**. All ten reproduced; all ten now fixed.

### 11.1 The three Medium findings

| # | Finding | Fix |
|---|---|---|
| **F1** | **An INVALID unique index is treated as protection.** Step (1) filtered `indisunique`/`indpred`/`indexprs` but not **`indisvalid`**. The residue of a failed `CREATE UNIQUE INDEX CONCURRENTLY` is `indisunique=true, indisvalid=false`; it enforces nothing, and `ADD CONSTRAINT … USING INDEX` rejects it outright — costing **all five tables** their key. Realistic precisely because hand-applying an index to a live table is when you reach for `CONCURRENTLY`, and hydra-uat's `_uindex` objects *were* hand-applied | `AND ix.indisvalid AND ix.indisready`. Shape `invalid-index`, mutant **MF1** |
| **F2** | **The harness did not check its own state setup**, so a shape whose SQL failed silently degraded to a weaker one and its assertions passed **vacuously**. Demonstrated by breaking `state_partial` — the shape whose entire purpose is proving a partial index is not mistaken for protection — and getting a **full green board with no mention anywhere** that the shape was never built. Same defect class as `fresh_db`, one level up | `q()` now uses `ON_ERROR_STOP` **and records failure in a global**; `run_state` aborts the shape. See 11.3 — my first attempt at this fix did nothing |
| **F3** | **No per-table exception handling.** The file states rule #3 ("must not fail with a bare Postgres error") and enforces it for the two *anticipated* modes only. Every other drift still escaped as a bare error and, this being one `DO` block, cost all five tables their key. The clearest transcript: three tables were successfully keyed and **all three were rolled back**. Step (0) already takes the opposite stance for an absent table — F1/F4/F5 were the same trade-off resolved the other way by omission | Per-table `BEGIN … EXCEPTION`: `WHEN OTHERS` → `RAISE WARNING` naming the table; the two deliberate aborts tagged **SQLSTATE `SB310`** and re-raised. Scenario `run_renamed_column`, mutant **MF3** |

### 11.2 The seven Low findings

- **F4** — the free-name probe read `pg_class` only, not `pg_constraint`; a CHECK/FK named `<tbl>_pkey` is invisible to it. Added the `pg_constraint` half. Shape `constraint-name-clash`, mutant **MF4**.
- **F5** — a renamed key column produced a bare `column … does not exist`. Subsumed by F3's handler; pinned by `run_renamed_column`, which asserts the other four tables still get their key.
- **F6** — **no deterministic tie-break.** With both a UNIQUE constraint and a plain unique index over the same pair, both candidates are non-PK, the order was unspecified, and the same logical schema converged **two different ways** (no PK vs PK). Non-convergence, in a migration whose central claim is convergence. Now prefers a real PK, then a *plain* index (promote → a PK exists), then name. Shapes `uqconstr+idx` and `uqconstr+idx-rev` assert an identical outcome for both creation orders; mutant **MF6**.
- **F7** — the self-contradiction assertion grepped the **whole** message stream, so a correct warning about table A plus a correct "unchanged" notice about table B tripped it: a **false RED on a correct migration**. Now keyed per table. Shape `crosstable-msgs`, mutant **MF7** (the whole-stream version reds on it; the per-table version passes).
- **F8** — three abort-path assertions were **satisfied by the bare error they exist to forbid**: psql's `CONTEXT:` line echoes the `EXECUTE`d SQL (table name included) and Postgres' own error says "contains null values". Now match the ticket-prefixed message. Mutant **MF8c** (same `RAISE` arity, ticket prefix stripped) reds 5 rows.
- **F9** — **my `fresh_db` fix from §10 was not actually present.** It had been silently clobbered when I regenerated the committed script from the scratchpad harness body, which lacked it. Re-applied; the committed script is now the single source of truth and mutants run against it via `MIGRATION=`.
- **F10** — off-by-one in the suffix-cap wording (`_pkey` plus **19**, not 20, numbered suffixes).

### 11.3 Two fixes of mine that did not work, and how that was caught

Both were caught by *testing the fix*, not by reading it:

- **F2's first version did nothing.** I captured `setup=$("$state" 2>&1)` and grepped for `ERROR` — but every `state_*` function pipes `q`'s output to `/dev/null` internally, so the variable was always empty. With the fix "applied", a deliberately broken shape still produced **264 pass, 0 fail**, identical to the run with the fix reverted. Reworked to record failure in a global that no redirect can swallow.
- **Four of my mutants were bad mutants.** `MF4`, `MF6` and `MF8c` initially died of *syntax errors* (unbalanced parens, a dangling `ORDER BY` comma, a `RAISE` arity mismatch) rather than of the defect. A mutant that kills for the wrong reason proves nothing, so each was rewritten surgically and re-confirmed to fail on the intended assertion. This is the same trap as a red row that is red for an unrelated reason.

### 11.4 Final verification state

**528 assertions pass, 0 fail** — 14 shapes plus 3 abort/drift scenarios, on PG14 (matches hydra PRD @ 14.23) and PG16.

Shapes: `flyway`, `handapplied`, `wineco`, `partial-expr`, `reversed-cols`, `uq-constraint`, `name-collision`, `fk-referenced`, `pkey-named-plain-idx`, `crosstable-msgs`, `invalid-index`, `constraint-name-clash`, `uqconstr+idx`, `uqconstr+idx-rev`. Scenarios: duplicate abort, NULL abort, renamed-column drift.

Mutants killed, each verified to fail *for the right reason*: **M1–M11** (§9/§10) plus **MF1, MF3, MF4, MF6, MF7, MF8c** and the F2 broken-setup pair — **19 total**.

The review also independently confirmed clean: exclusion constraints cannot leak past F3's filter (their index is not `indisunique`); `format()` injection surface (all `%I`/`quote_ident`); identifier-length truncation (longest generated name is 38 chars); `local rc=$?` capture at four sites; `set --` scoping; `PRIMARY KEY USING INDEX` on an FK-referenced index; and that no live tenant has a `contype='f'` pointing at a plain unique index on these tables — so **F3's fix guards a hypothetical, correctly**.

### 11.5 What the two review rounds jointly say about my verification

Round 1 found six defects after I reported "0 fail, all mutants killed". Round 2 found ten more after I reported the same thing again, including **one fix of mine that was inert** and **one that had been silently reverted**. The consistent shape: green assertion counts describe the assertions that exist, and every round the gap was somewhere no assertion looked — the message stream, the shape setup, the validity of an index, the order of two catalog rows.

Nothing here was found by reading the file. Each one needed either a mutant or a constructed schema.


---

## §12 — Third pass: verifying the fixes to the second review's findings (2026-08-22)

The same lane was asked to do one narrow thing — **verify my fixes to its own ten findings** — because two of my previous-round fixes had turned out to be inert or silently reverted. It re-established the baseline itself (528/0), validated every mutant before counting it (each had to produce `rc=0` and exactly the same 107 primary keys on a neutral shape, so none was a syntax or arity death), and left the worktree byte-identical.

**Verdict: nine of the ten fixes verified correct. F3 introduced one High regression** — precisely the thing it was asked to hunt for.

### 12.1 N1 (High) — my F3 handler converted a failure into a *silent success*

`WHEN OTHERS` downgraded everything except `SB310` to a warning, so on a **privilege** failure all five tables failed, the block completed, psql exited **0**, and **Flyway recorded V2.2.20 as successfully applied**. The migration would then never re-run: the tenant keeps zero of these constraints, permanently and invisibly.

Reproduced with tables owned by one role and the migration run by a DML-only role — five warnings, `PSQL EXIT CODE = 0`, **0 primary keys created**.

**Nothing in the repo would have caught it.** `check-tenant-migration-drift.sh` keys on `flyway_schema_history.success`, which is now `true`; and `audit-access-invariants.sql` referenced all five tables **only in data joins** — it had zero key or constraint assertions.

And the trigger is not hypothetical: this is object-ownership drift, which is why `db/reassign-tenant-ownership.sh` exists, and repo history records prd hydra/nywh frozen by exactly that. **Pre-F3 that condition produced a loud, blocking failure; post-F3 a green migration that did nothing.** A frozen chain is at least visible to `plan-state.sh`; a false success is not.

**Fixed** with the recommended end-of-loop tally: each per-table failure is still diagnosed by name in a `RAISE WARNING` (F3's genuine benefit — one run reports *every* affected table instead of only the first), then after `END LOOP` a `RAISE EXCEPTION` reports the count and the `table(SQLSTATE)` list and stops the chain. Strictly better than both the pre-F3 and post-F3 behaviour.

New scenario **`run_ownership_failure`** reproduces it end to end — creates a low-privilege role, runs the migration as it, and asserts the migration fails, surfaces `42501`, points at `reassign-tenant-ownership.sh`, and commits nothing. Mutant **MN1** (tally removed) reds both it and the drift scenario with *"would record success and never retry"*, and is surgical (`rc=0`, 5 PKs on a neutral shape).

**`run_renamed_column`'s contract changed as a result** — drift must now abort rather than continue, after naming the affected table and tallying. Its assertions were rewritten accordingly.

### 12.2 The other seven findings

| # | Finding | Fix |
|---|---|---|
| **N2** | The warning claimed *"the other tables were still processed"* when none were, and its likely-causes list omitted **privileges** — the actual cause — pointing the operator at three wrong things | Text rewritten; `42501` and the ownership script named first |
| **N5** | The migration cited `audit-access-invariants.sql` as the safety net for step (0)'s skip. That file has **zero key assertions**, so it could not report the gap — the sentence that made warn-and-continue look safe was false | Claim corrected, **and the gap closed**: added `SET 10` to that audit file — PK-present per table (keyed on the *column set*, never the name), duplicate pairs, and INVALID indexes. Verified live: it correctly reports all five `has_pk=false` on hydra PRD |
| **N3** | `Q_FAILED` was checked once, leaving `seed_rows` and the three `run_*` scenarios unguarded (all fail closed, so a labelling defect rather than a false-green) | Check added after `seed_rows` |
| **N4** | The F1 comment block was attached to the wrong shape, leaving the F7 shape undocumented | Both corrected |
| **N6** | The closing note claimed the PK indexes `user_id` as its leading column — true only on the create-fresh path; a promote keeps the adopted index's own order | Claim qualified for both paths |
| **N7** | The suffix-cap `RAISE EXCEPTION` was silently downgraded to a warning by `WHEN OTHERS`, while the source still said `RAISE EXCEPTION` | Now tallied and aborts via N1's fix; the discrepancy is gone |
| **N8** | *(informational)* F3 shifted the kill row of three earlier mutants — after the handler, a missing pre-flight no longer aborts, so the kill moves to *"migration SUCCEEDED despite…"*. Coverage intact | Confirmed; re-verified all earlier mutants still kill |

### 12.3 What it verified positively

- **F3's `SB310` re-raise genuinely preserves the hard abort**, proved three ways: dropping only the re-raise arm reds both abort scenarios; an abort on the *last* table still rolls back the first four (`PKs = 0`); and a `WHEN OTHERS` warning on table 1 plus an abort on table 5 still aborts.
- **F2's reworked global-flag guard cannot be defeated** on the shape path — verified against a failure in `base_tables`, a failure on a shape's *second* statement, and confirmed no `state_*` pipes `q` into a subshell that would lose the global.
- **F6's direction is right.** Asked to argue for skipping instead, it declined and gave reasons: skipping leaves the tenant diverged from the entity model the file itself invokes as justification, and makes `pk_covering = 1` un-assertable as a uniform invariant. The leftover constraint is harmless and the two indexes even cover different leading columns.
- **F1 skips nothing it should have used** — `valid ∧ ¬ready` is not a state a finished index occupies, and `REPLICA IDENTITY USING INDEX` survives the promote because it tracks the index OID.
- **No shape or scenario added in rounds 2–3 is vacuous**; each is the *sole* killer of at least one mutant.

### 12.4 A process note worth keeping

The lane disclosed a mistake of its own: it first ran two harness batches **concurrently**, and since both use the same container names and ports they reaped each other's containers, producing a wall of credible-looking "connection refused" reds. It re-ran everything serially with a contamination check. The harness header now warns that it is not safe to run concurrently with itself — the third instance in this ticket of infrastructure failure masquerading as a verification result.

### 12.5 Final state

**540 assertions pass, 0 fail** — 14 shapes plus 4 abort/drift scenarios (duplicate, NULL, renamed-column, ownership), on PG14 and PG16. **26 mutants killed**, each validated as surgical before being counted.


---

## §13 — PR submitted (2026-08-22)

- **Commit** `aa2b257` on `bugfix/SBDEV-3010-authorization-join-table-primary-keys`, base `develop` @ `d70204c`.
- **[wms2-api PR #184](https://github.com/SiteBossInc/wms2-api/pull/184)** into `develop`.
- ClickUp SBDEV-3010 → **`pr submitted`**, with a comment recording the four corrections to the ticket, the two answers worth keeping (no Java change needed; nothing may key off a constraint name), the two tooling defects fixed directly, and the rollout gates.
- 8 files, **+1036 / −24**. The migration is 363 lines, the verify script 548; the Java diff is 62 lines across four files and is **comment-only**.

### 13.1 Explicitly NOT done

- **Not merged.** Stops at PR, per the executor contract.
- **Not applied to any live tenant.** No tenant has run V2.2.20.
- **No manual QA.** There is nothing user-visible to click — the change is a DDL constraint. The behavioural claim (a concurrent double-insert now raises `23505`) is proven only against scratch Postgres, never against a live tenant, because doing so would mean deliberately racing writes on an authorization table.
- **Plan not archived** — that waits on merge and deploy.

### 13.2 The three gates before merge

1. **Re-sweep the version** with `db/check-migration-version-collision.sh V2.2.20` from the repo root. `V2.2.20` was free at push time, but `V2.2.19` was taken out from under this branch by PR #183 *during* implementation — this is not a theoretical risk.
2. **Re-run the duplicate pre-flight** per tenant per table on dev, UAT and prd (`SET 10` of `audit-access-invariants.sql` now does this). Zero as of 2026-08-22; the window to deploy is not zero.
3. **Understand the queue position.** V2.2.20 is last in line on seven of eight tenants (hydra PRD at `2.2.16`, five UAT tenants at `2.2.17`, `hydra-v2t` at `2.2.01`). An unrelated earlier migration failing stalls the chain before V2.2.20 is reached, silently. `wineco-dev` at `2.2.19` is the only tenant where it applies immediately, so a green result there is weak evidence about the rest.
