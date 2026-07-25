---
title: "SBDEV-2384 — Replenishment Monitor View: restore section_name + ro_id columns (v2 pick/pack classification parity fix)"
ticket: "SBDEV-2384"
ticket_url: "https://app.clickup.com/t/SBDEV-2384"
type: "bugfix"
priority: "medium"
status: "archived"
project: [wms2]
version: "v2"
requester: "nam.park@siteboss.net"
created: "2026-07-13"
updated: "2026-07-17"
related:
  - "sbdocs/4-Archieves/wms1/plan/SBDEV-2384-replenishment-monitor-pickpack-classification-fix.md"
tags:
  - plan
---

# SBDEV-2384 — Replenishment Monitor View: restore `section_name` + `ro_id` columns (v2 pick/pack classification parity fix)

> **Archived 2026-07-14.** Implemented and merged — PR [#74](https://github.com/SiteBossInc/wms2-api/pull/74) → `develop` (merge commit `3466d8a`). v2 acceptance: `ReplenishmentMonitorViewSchemaIT` (merged with the fix). The shared SBDEV-2384 acceptance script is retained at `sbdocs/9-System/scripts/verify-SBDEV-2384-replenishment-monitor-pickpack-classification-fix.sh`.

> **⚠️ Migration renumbered (2026-07-17).** After this fix merged, the `V2.2.00` base dump was re-exported to fold in the `los_sequencenumber` seed; the standalone `V2.2.01__los_sequencenumber_init.sql` was removed and every later `db/migration` delta shifted **down by one**. **This fix now lives at `V2.2.01__replenishment_monitor_view_add_section_and_ro_id.sql`** (implemented as `V2.2.02`). The **Design / ADR / locator** sections below have been updated to this current numbering. The **§6 Test Plan and §8.1 recorded red→green evidence are deliberately left as-run** — they cite the as-implemented chain (`V2.2.00` + `V2.2.01` los_sequencenumber + `V2.2.02` fix), which is the run that actually executed; read those version tokens through this mapping. See `db/migration/README.md` and `wms2-database-setup-guide.md`.

**Ticket:** [SBDEV-2384](https://app.clickup.com/t/SBDEV-2384)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix (schema parity)
**Priority:** medium
**Status:** implemented
**Date:** 2026-07-13

---

## 0. Consensus summary (RALPLAN-DR)

**Mode:** SHORT (single-subsystem DDL parity fix; no cross-service blast radius). Deliberate-mode pre-mortem is folded into §8.3 as a courtesy, not because the risk tier demands it.

**Principles (decision invariants):**
1. **v1↔v2 physical-schema parity is a repo invariant.** The weekly v1→v2 sync-sweep assumes each ported v1 migration has a v2 twin. A v1 column that has no v2 equivalent permanently breaks that invariant.
2. **The entity is the contract.** `ReplenishmentMonitorView` deliberately declares `sectionName`/`roId`; under `ddl-auto=validate` the physical view must satisfy that contract, or every `@SpringBootTest` is a false-red.
3. **Greenfield and onboarding must converge.** Per `db/migration/README.md` and `db/v1-to-v2-onboarding/README.md`, both a fresh v2 DB and an onboarded v1 DB reach the `V2.1.16` watermark and then **both** apply all `V2.2.x` deltas from `db/migration/` — so a single `db/migration/V2.2.01` delta reaches every tenant. No separate onboarding-chain delta is needed (this superseded the plan's original two-file design; see §8.4 ADR).
4. **Fail-first, boot-independent acceptance.** The primary gate must go red before the fix and green after, without depending on the SBDEV-2217-broken `@SpringBootTest` boot. **Resolved:** the onboarding `schema/` chain itself trips SBDEV-2217 (the `outbox_message`/landlord boot dependency runs deeper in that chain than assumed), so the primary gate builds from `db/migration` (base dump `V2.2.00` + `V2.2.02`) instead — a clean snapshot with no `V1.2.01` outbox forward-reference, fully SBDEV-2217-independent.
5. **Idempotent, re-runnable DDL.** `CREATE OR REPLACE VIEW` only; no drop-and-recreate that could race a re-exported base dump.

**Decision drivers (top 3):**
1. **Parity / sync-sweep integrity** — `ro_id` is the direct port of v1 `V1.26.30`; omitting it diverges v2 forever. (decisive for `ro_id`)
2. **Entity/DDL consistency under `validate`** — `section_name` is v2-only; the entity's `@Column(name="section_name")` makes the physical column mandatory the moment `ddl-auto=validate` runs. (decisive for `section_name`)
3. **Latent correctness** — the unused HAL `findAll` surface throws HTTP 500 under `validate` today; real only if `findAll` is ever wired. (secondary, supports both)

**Viable options (see §3.4 / ADR §8.4 for full pros/cons):**
- **Option A — Add the two DDL columns (CHOSEN).** Physical view gains `section_name` + `ro_id`; entity unchanged.
- **Option B — Drop/`@Transient` both entity fields.** Zero DDL, zero drift guard, zero re-export follow-up. Genuinely lower-risk on runtime grounds; **rejected only** on Principle 1 (parity) and Principle 2 (entity-author intent), not on correctness.

Both options are viable and neither is runtime-wrong. The tie is broken by parity + author-intent, not by a bug.

---

## 1. Problem Statement

`v2/wms2-api` entity `ReplenishmentMonitorView` (`src/main/java/net/aim_ai/wms/model/ReplenishmentMonitorView.java`) declares two persistent fields that the physical database view **does not expose**:

- `sectionName` → `@Column(name = "section_name")` (line 17-18)
- `roId` → **unannotated** field `private Long roId;` (line 45), which Hibernate resolves to physical column `ro_id` via the default `CamelCaseToUnderscoresNamingStrategy`.

The effective physical view has **17 columns and neither `section_name` nor `ro_id`**:
- Onboarding chain head: `src/main/resources/db/v1-to-v2-onboarding/schema/V2.1.16__replenishment_monitor_view_flag_based_classification.sql` (17-column `CREATE OR REPLACE VIEW`, lines 20-171).
- Greenfield base dump: `src/main/resources/db/migration/V2.2.00__base_v2_schema.sql` line 1997 (`CREATE VIEW public.replenishment_monitor_view AS …`) — same 17-column shape, no `section_name`/`ro_id`.

**Symptoms:**
1. **`ddl-auto=validate` boot failure (latent-but-real).** Under Hibernate schema validation (the Testcontainers `@SpringBootTest` profile), context load fails with `SchemaManagementException: missing column [section_name] / [ro_id] in table [replenishment_monitor_view]`. This is the same class of failure the v1 twin `V1.26.30` fixed.
2. **HTTP 500 on the HAL `findAll` surface (latent).** `@RepositoryRestResource(... path = "replenishmentMonitorView")` auto-exposes a default `findAll` projecting the full entity. Any GET that materializes `sectionName`/`roId` would 500 in prod. **This surface is confirmed unused** — no `wms2-web-ui` or `wms2-mobile-ui` reference to the `replenishmentMonitorView` collection resource — so the prod-500 is **latent**, not active.

The **live** consumer is the native projection `getReplenishViewSummary()` (`ReplenishmentMonitorViewRepository` lines 14-115 → `ViewDtoService:1208`), which reconstructs the query inline with its **own** `sec.name AS section_name` (repo line 42, via `LEFT JOIN section sec ON c.section_id = sec.id`, line 57) and `ro.id AS ro_id` (line 105). It is a **superset** of the physical view (also selects `sku_type`, `ro_destination_name`, `on_*_location_names`, `fix_assignment_upperbound`). It works today and is **not** affected by this bug.

**In one line:** the physical entity-view is a stale, unused **subset**; the fix realigns it with the entity contract and with v1.

---

## 2. Root Cause Analysis

Two independent omissions, one shared cure:

- **`ro_id` — v1 parity gap.** v1 shipped `ro_id` on this view in `v1/wms-api/.../db/migration/V1.26.30__replenishment_monitor_view_add_ro_id.sql` (appends `t4.ro_id AS ro_id` as the trailing 18th column). That port never reached v2. The onboarding `schema/` chain stops at `V2.1.16` (the port of v1 `V1.26.29` flag-based classification) and never picked up `V1.26.30`.
- **`section_name` — v2-only omission.** `section_name` is **not** a v1 concept on this view (v1 `V1.26.29`/`V1.26.30` have no `section_name`). It is a v2-only column the entity author added deliberately (matching the live `getReplenishViewSummary()` projection, which joins `section`). The v2 physical view was rewritten by `V2.1.16` (flag-based bucket) from a lineage that never carried `section_name` into the entity-view.

Net: the entity was written to the richer `getReplenishViewSummary()` shape, but the **physical** `replenishment_monitor_view` was only ever maintained at the leaner 17-column shape.

### Affected Locations

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | `v2/wms2-api/src/main/java/net/aim_ai/wms/model/ReplenishmentMonitorView.java` | 17-18 | `@Column(name="section_name")` — physical column absent |
| 2 | `v2/wms2-api/src/main/java/net/aim_ai/wms/model/ReplenishmentMonitorView.java` | 45 | unannotated `roId` → resolves to `ro_id` — physical column absent |
| 3 | `v2/wms2-api/src/main/resources/db/v1-to-v2-onboarding/schema/V2.1.16__replenishment_monitor_view_flag_based_classification.sql` | 20-171 | onboarding-chain view head (17 cols) — **unaffected, no edit and no onboarding-side follow-on migration**; the onboarding path converges to `db/migration` `V2.2.x` deltas after this watermark (see §3), so `V2.2.01` alone reaches onboarded tenants too |
| 4 | `v2/wms2-api/src/main/resources/db/migration/V2.2.00__base_v2_schema.sql` | 1997-2014 | greenfield base-dump view (17 cols) — fixed by a **new** `V2.2.01` delta, NOT an edit to the dump |
| 5 | `v1/wms-api/src/main/resources/db/migration/V1.26.30__replenishment_monitor_view_add_ro_id.sql` | 21-175 | v1 reference for the `ro_id` append |
| 6 | `v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/ReplenishmentMonitorViewRepository.java` | 42, 57, 105, 113 | live superset projection already emitting `section_name`/`ro_id` — the parity target |

**Never modify an already-applied migration** (`V2.1.16`, `V2.2.00`). Both fixes are **new forward migrations**.

---

## 3. Design / Proposed Fix

**Decision (locked, implemented):** Option A — add the two DDL columns, via a **single STANDALONE `db/migration/V2.2.01` delta**. Entity unchanged.

### 3.1 One migration file, no onboarding-side twin

**Corrected design (superseding the plan's original two-file draft):** per `db/migration/README.md` and `db/v1-to-v2-onboarding/README.md`, both provisioning paths — a brand-new v2 DB and an onboarded v1→v2 DB — converge at the `V2.1.16` watermark and then **both** continue by applying every `V2.2.x` delta from `db/migration/`. A separate onboarding-chain migration (the plan's original `V2.1.17`) is therefore unnecessary: it would only ever have served the (SBDEV-2217-broken) onboarding-chain test harness, never a production path.

| Path | File | Applies over | Reaches |
|------|------|--------------|---------|
| **`db/migration`** | `src/main/resources/db/migration/V2.2.01__replenishment_monitor_view_add_section_and_ro_id.sql` | base dump `V2.2.00` (which now bundles the `los_sequencenumber` seed) | **every** tenant — fresh-v2 DBs directly, and onboarded v1→v2 DBs once they continue past `V2.1.16` into `V2.2.x` |

`V2.2.01` is the next free `db/migration` slot (the former `V2.2.01__los_sequencenumber_init` seed has been folded into the `V2.2.00` base dump, so this fix took its freed slot number). The original M2 "drift guard" between two files (§6, prior draft) is now **obsolete** — with one file there is nothing to keep in sync.

### 3.2 REQ-1 — exact view body rewrite (NOT a pure trailing append)

The base is the **`V2.1.16` flag-based definition** (17 cols). Producing the target 19-column view requires **inner plumbing** for `section_name`, not just outer output columns. Spell this out so the executor cannot get it wrong:

**`section_name` (v2-only, needs a new join):**
- In the **`t1` sub-select**: add `LEFT JOIN section sec ON c.section_id = sec.id` after the `INNER JOIN client c …` line.
- Add `sec.name AS section_name` to the **t1 SELECT list**.
- Add `sec.name` to the **t1 `GROUP BY`** (t1 is a grouped aggregate; every non-aggregated select item must be grouped).
- Add `t1.section_name` to the **OUTER SELECT** list (append at end) **and** to the **OUTER `GROUP BY`**.

**`ro_id` (v1 parity port, mirror of v1 `V1.26.30`):**
- In the **`t4` sub-select**: add `ro.id AS ro_id` to the SELECT list (t4 is not grouped — no GROUP-BY change inside t4).
- Add `t4.ro_id AS ro_id` to the **OUTER SELECT** list (append at end).
- Add `t4.ro_id` to the **OUTER `GROUP BY`** (`ro.number` is effectively unique per `replenishorder`, so grouping granularity is unchanged).

**Only the OUTER OUTPUT COLUMN LIST is a trailing append** — that is precisely what satisfies PostgreSQL `CREATE OR REPLACE VIEW`'s "you may add columns only at the end" rule (the existing 17 columns keep the same name/order/type in both chains).

> **Warning — do not shortcut this.** Appending `t1.section_name` / `t4.ro_id` to the outer SELECT **without** the inner plumbing (the `section` join, the `sec.name`/`ro.id` sub-select items, and the inner GROUP-BY entries) throws at view-create time:
> - `ERROR: column "section_name" does not exist` (missing sub-select item), or
> - `ERROR: column "sec.name" must appear in the GROUP BY clause or be used in an aggregate function` (missing inner GROUP BY).

**Final outer output order:** the 17 existing columns unchanged, then `section_name`, then `ro_id` (order of the two appended columns is immaterial — Hibernate validates by resolved **name**, not ordinal; see §3.3). Keep the two appended columns **last** to preserve `CREATE OR REPLACE` legality. **As implemented**, `V2.2.01` appends `section_name` as the 18th column and `ro_id` as the 19th.

### 3.3 Naming-strategy note (S2 — corrected rationale)

Hibernate validates the entity against the physical view **by resolved column NAME, not by ordinal position.** The entity lists `sectionName` second and `roId` mid-list, but that ordering is irrelevant:
- `sectionName` → `section_name` via explicit `@Column(name="section_name")`.
- `roId` and `bottlesNeeded` are **unannotated** and resolve via the default `CamelCaseToUnderscoresNamingStrategy` → `ro_id` / `bottles_needed`. There is **no `PhysicalNamingStrategy` override** in `application*.properties`, so the default applies.

Therefore appending both columns at the **end** of the view output list satisfies validation while keeping `CREATE OR REPLACE` legal. (This corrects the earlier "entity uses `@Column(name=…)` so column order doesn't matter" wording — the real reason is name-based resolution, and `roId` is not even `@Column`-annotated.)

### 3.4 Idempotency + re-export interaction (S1)

- Author `V2.2.01` as `CREATE OR REPLACE VIEW` (idempotent, re-runnable).
- **Today, `V2.2.01` is a real delta** — the base dump `V2.2.00` (line 1997) is at the pre-`section_name`/pre-`ro_id` watermark, so the columns are genuinely absent on a fresh DB until `V2.2.01` runs. (The 2026-07-17 base re-export did **not** advance past this watermark — the reference DB predated the fix — so the fix remains a real delta, just renumbered.)
- **When the base dump is next re-exported past this watermark**, `V2.2.00` will already contain the two columns, making `V2.2.01` a **redundant no-op** — and that is safe: `CREATE OR REPLACE VIEW` re-emitting the identical definition has **no double-apply hazard** (no error, no schema change). No need to delete `V2.2.01` at re-export time; leave it as a harmless idempotent re-assertion (or drop it in the same sanitize pass, per `db/migration/README.md`).

### 3.5 What is explicitly NOT changed

- **No entity change.** `ReplenishmentMonitorView.java` is already correct; touching it (e.g. the rejected "`@Transient section_name` only" hybrid) would contradict author intent that these be real columns. **Rejected.**
- **No change to `getReplenishViewSummary()`** — it already emits both columns and is the live consumer.
- **No timestamp columns** in this view, so it is Phase-F (UTC) neutral — safe on naive-timestamp and `timestamptz` DBs alike.

---

## 4. V1/V2 Applicability

| Aspect | V1 | V2 | Impact |
|--------|----|----|--------|
| `ro_id` column | Present since `V1.26.30` | **Missing** | Port to v2 — decisive parity driver |
| `section_name` column | **Not present** on this v1 view | Entity declares it; physical view missing | v2-only add; no v1 counterpart |
| Flag-based classification (`V1.26.29`) | Present | Present (`V2.1.16`) | Already synced — not in scope |
| Live projection `getReplenishViewSummary()` | n/a (v2 shape) | Already emits both cols | Parity target, no change |

### What Needs Porting
1. v1 `V1.26.30` `ro_id` append → v2, via the single `db/migration/V2.2.01` delta (reaches both fresh and onboarded tenants — see §3.1). Mirrors the v1 t4/outer plumbing exactly.

### What Does NOT Need Porting
- `section_name` — v2-only; there is nothing in v1 to port. It is added on v2 to satisfy the v2 entity + match the v2 live projection.
- Flag-based bucket predicate — already ported in `V2.1.16`.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** (schema version, Flyway baseline) | Onboarding chain at `V2.1.16`; greenfield base dump `V2.2.00` present (now bundles the `los_sequencenumber` seed) | dev | Single new migration is the next free `db/migration` slot (`V2.2.01`); no onboarding-side migration needed (see §3.1) |
| 2 | **Feature flags / system properties** | N/A | — | No sysprop toggles; pure DDL |
| 3 | **Config / env changes** | N/A | — | No `application*.properties` change; running app does not invoke Flyway |
| 4 | **Deploy-order dependencies** | N/A | — | No OMS / other-service coupling |
| 5 | **Data migration / backfill** | N/A | — | View recompute only; no row backfill |
| 6 | **External systems** | N/A | — | No OMS / printer / Keycloak touch |
| 7 | **Access / permissions** | N/A | — | No new role or endpoint authority |
| 8 | **Monitoring / alerts** | N/A | — | No new metric |

### 5.2 Implementation Checklist — DONE

- [x] Write the primary fail-first acceptance test **first** (`ReplenishmentMonitorViewSchemaIT`), confirm it goes RED for the right reason (columns absent) — see §6.
- [x] Author `db/migration/V2.2.01__replenishment_monitor_view_add_section_and_ro_id.sql` (§3.2 body; `CREATE OR REPLACE VIEW`). No onboarding-side file authored — not needed (§3.1).
- [x] Confirm the primary test flips to GREEN (both columns present, selectable without error).
- [ ] Add/adjust the secondary `@SpringBootTest` IT as `@Disabled` with `TODO(SBDEV-2217)` — still pending; secondary criterion only (§6).
- [ ] Code review.
- [ ] Commit + PR (not yet done — see §8.1).

---

## 6. Test Plan

### M1 (PRIMARY acceptance gate) — bare Testcontainers, built from `db/migration` — GREEN

**This is the primary red→green gate, and it is now the ONLY gate (M2 below is obsolete).** The full `@SpringBootTest` boot under `ddl-auto=validate` **cannot** be the primary gate: SBDEV-2217 (broken `outbox_message` Flyway profile + landlord datasource boot) keeps it red regardless of this fix.

**Corrected harness (superseding the plan's original draft):** the test does **not** build from the onboarding `schema/` chain. During implementation, running the onboarding chain under Testcontainers **did trip SBDEV-2217** — resolving the §8.5 open question the hard way. The primary gate instead builds from `db/migration` (the same path a brand-new v2 DB is provisioned by): `V2.2.00` base dump + `V2.2.01` + `V2.2.02`. The base dump is a clean snapshot at the `V2.1.16` watermark with **no `V1.2.01` outbox forward-reference**, so this path is fully SBDEV-2217-independent. SBDEV-2217 no longer blocks this plan's primary gate.

**Implemented class:** `src/test/java/net/aim_ai/wms/integration/schema/ReplenishmentMonitorViewSchemaIT.java` — bare `PostgreSQLContainer<>("postgres:12")`, `Flyway.configure().locations("classpath:db/migration").load().migrate()`, plain `DriverManager` JDBC assertions. Not `@SpringBootTest`.

Three test methods (all implemented and GREEN):
- `replenishmentMonitorView_shouldExposeRoId_afterFreshStartMigrate` — `information_schema.columns` has `ro_id`.
- `replenishmentMonitorView_shouldExposeSectionName_afterFreshStartMigrate` — `information_schema.columns` has `section_name`.
- `replenishmentMonitorView_shouldSelectSectionNameAndRoId_withoutError` — `SELECT section_name, ro_id FROM replenishment_monitor_view LIMIT 1` runs without a grammar error (mirrors the SQL Spring Data REST `findAll` would emit).

**Red→green evidence:** before `V2.2.02` existed, Flyway applied only `V2.2.00`+`V2.2.01` and all 3 assertions FAILED (`Expecting value to be true but was false`; `column section_name does not exist`). After adding `V2.2.02`: `Successfully applied 3 migrations ... now at version v2.2.02`, then `Tests run: 3, Failures: 0, Errors: 0, Skipped: 0, BUILD SUCCESS`.

**Run command:** `mvn clean test -Dtest=ReplenishmentMonitorViewSchemaIT -Djacoco.skip=true -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true`.

> **Caveat — must run with `mvn clean`.** A stale `target/classes/db/migration/` directory (left over from before the `db/` reorg, 33 leftover onboarding SQLs) can pollute the classpath and make Flyway replay the old chain, which dies at `V1.2.01` referencing `outbox_message` before it exists. This is a **local-dev hazard only** — CI and production deploys use clean checkouts, so it doesn't affect them — but always run this test after `mvn clean`, not an incremental `mvn test`.

### M2 (drift guard) — OBSOLETE

The plan's original M2 (`pg_get_viewdef` equality between an onboarding-chain build and a greenfield build) is **obsolete**: with a single `db/migration/V2.2.02` file reaching every tenant (§3.1), there is no second file to drift out of sync with. No drift-guard test was written.

### Secondary (still SBDEV-2217-blocked) — `@SpringBootTest` boot + `findAll`

`ReplenishmentMonitorViewRepositoryIT` (context-boot-under-`validate` + `findAll()` population) remains a **secondary**, non-blocking criterion — not yet added, and would need `@Disabled` with `TODO(SBDEV-2217)` until the outbox/landlord boot is fixed. It is no longer the harness for the primary gate (see M1 above).

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Columns present (M1, primary) | Flyway `db/migration` (`V2.2.00`+`V2.2.01`+`V2.2.02`); `information_schema.columns` query | `section_name` AND `ro_id` both present — **GREEN** |
| Fail-first (M1) | Same, Flyway stopped at `V2.2.01` (before `V2.2.02`) | Missing both cols → test RED (confirmed during implementation) |
| Selectable without error (M1) | `SELECT section_name, ro_id FROM replenishment_monitor_view LIMIT 1` | Runs without a grammar error — **GREEN** |
| `CREATE OR REPLACE` re-run (idempotency) | Apply `V2.2.02` twice | Second apply is a no-op, no error |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `ReplenishmentMonitorViewSchemaIT` (new, bare TC, built from `db/migration`) | `replenishmentMonitorView_shouldExposeRoId_afterFreshStartMigrate` | `ro_id` column present — GREEN |
| `ReplenishmentMonitorViewSchemaIT` | `replenishmentMonitorView_shouldExposeSectionName_afterFreshStartMigrate` | `section_name` column present — GREEN |
| `ReplenishmentMonitorViewSchemaIT` | `replenishmentMonitorView_shouldSelectSectionNameAndRoId_withoutError` | both columns selectable, mirrors `findAll` — GREEN |
| `ReplenishmentMonitorViewRepositoryIT` (secondary, not yet added) | boot-under-validate + `findAll` | would need `@Disabled` `TODO(SBDEV-2217)` |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| SQL sanity — columns exist | staging DB (onboarded tenant) | `psql`: `\d+ replenishment_monitor_view` (or `information_schema.columns`) | `section_name`, `ro_id` listed | |
| SQL sanity — view returns rows | staging DB | `psql`: `SELECT section_name, ro_id FROM replenishment_monitor_view LIMIT 5;` | non-empty on a tenant with due replen; no grammar error | |
| Live projection unaffected | staging | GET the `getReplenishViewSummary` REST resource | unchanged payload (already had both cols) | |

### Test execution

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn clean test -Dtest=ReplenishmentMonitorViewSchemaIT -Djacoco.skip=true -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true` | BUILD SUCCESS | 3 / 0 / 0 |
| `mvn clean compile` | not separately recorded — covered by the `mvn clean test` run above | — |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| `@SpringBootTest` boot-under-validate as primary gate | SBDEV-2217 keeps it false-red regardless of fix; would be a secondary, not-yet-added criterion |
| Onboarding-chain drift guard (M2) | Obsolete — single-file design (§3.1) means there is nothing to keep in sync |
| `view == getReplenishViewSummary()` equality | Native projection is an intentional superset (extra `sku_type`, `ro_destination_name`, `on_*_location_names`, `fix_assignment_upperbound`) |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

Pure DDL view redefinition; no Java runtime behavior added. All rows **N/A** with rationale.

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1 | In-JVM state | N/A | No new Java state; DDL only |
| 2 | Connection pool math | N/A | No new per-request DB connection usage |
| 3 | Scheduled jobs | N/A | No `@Scheduled` added/modified |
| 4 | Long transactions | N/A | No transaction added; view is read-only |
| 5 | Request affinity | N/A | Stateless read view |
| 6 | Retry / idempotency | N/A | `CREATE OR REPLACE VIEW` is idempotent; no runtime write path |
| 7 | Tenant context | N/A | View lives in each tenant DB; no async/ThreadLocal touched |
| 8 | Distributed lock correctness | N/A | No lock introduced |
| 9 | Cache invalidation | N/A | View not `@Cacheable`; entity not cached on a write path |
| 10 | External notifications | N/A | No OMS/printer/message emission |

### Evidence
No "Yes" rows — none required.

---

## 8. Notes

### 8.1 Implementation status — DONE (committed, PR open)
- [x] `db/migration/V2.2.01__replenishment_monitor_view_add_section_and_ro_id.sql` authored — `v2/wms2-api/src/main/resources/db/migration/V2.2.01__replenishment_monitor_view_add_section_and_ro_id.sql` (authored as `V2.2.02`; renumbered 2026-07-17). `CREATE OR REPLACE VIEW` re-emitting the `V2.2.00` base view with `section_name` (via `LEFT JOIN public.section sec ON sec.id = c.section_id` in the t1 sub-select → `sec.name AS section_name`, added to t1 SELECT + t1 GROUP BY + outer SELECT + outer GROUP BY) and `ro_id` (`ro.id AS ro_id` in the t4 sub-select → outer SELECT + outer GROUP BY), appended as the trailing 18th/19th columns. No onboarding-side file authored (§3.1 — not needed).
- [x] Test authored — `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/schema/ReplenishmentMonitorViewSchemaIT.java`: bare Testcontainers + `Flyway.migrate(classpath:db/migration)` + raw JDBC, 3 methods (`replenishmentMonitorView_shouldExposeRoId_afterFreshStartMigrate`, `replenishmentMonitorView_shouldExposeSectionName_afterFreshStartMigrate`, `replenishmentMonitorView_shouldSelectSectionNameAndRoId_withoutError`).
- [x] Red→green proven: before `V2.2.02`, migration applied only 2.2.00+2.2.01 and all 3 assertions FAILED (`Expecting value to be true but was false`; `column section_name does not exist`). After `V2.2.02`: `Successfully applied 3 migrations ... now at version v2.2.02`, `Tests run: 3, Failures: 0, Errors: 0, Skipped: 0, BUILD SUCCESS`.
- [x] Command run: `mvn clean test -Dtest=ReplenishmentMonitorViewSchemaIT -Djacoco.skip=true -Dmaven.javadoc.skip=true -Dcheckstyle.skip=true` (must use `mvn clean` — see §6 caveat on stale `target/classes/db/migration/`).
- [ ] Code review — pending.
- [x] Commit — `ac1e061` on branch `task/SBDEV-2384-v2-replen-monitor-view-columns`. PR [#74 → develop](https://github.com/SiteBossInc/wms2-api/pull/74).
- [ ] Base-dump re-export follow-up filed (see §8.6) — pending.

### 8.2 Related plans
- v1 twin `V1.26.30` (already shipped) — the `ro_id` port source.
- Shares the SBDEV-2384 lineage with `V2.1.16` / v1 `V1.26.29` (flag-based classification, already synced).

### 8.3 Pre-mortem (courtesy — 3 failure scenarios)
1. **Outer-only append (missing inner plumbing)** → view-create error (`column does not exist` / `must appear in GROUP BY`). *Guard:* §3.2 REQ-1 spells out every inner change; M1 test catches it (migration fails → chain won't build → RED). Not encountered in the implemented `V2.2.01`.
2. **`CREATE OR REPLACE` illegal-shape rejection** (columns not appended at end, or an existing column's type/name changed) → `ERROR: cannot change name of view column`. *Guard:* keep the 17-column prefix byte-identical; append only. Not applicable now that there is only one file (no chain-equality guard needed).
3. **M1 test trips SBDEV-2217** — **this happened.** Building the primary gate from the onboarding `schema/` chain under Testcontainers tripped SBDEV-2217 during implementation, which is exactly why the gate was moved to build from `db/migration` instead (§6). Resolved, not merely guarded against.

### 8.4 ADR — Add `section_name` + `ro_id` DDL columns (Option A)

**Decision (implemented):** Add both columns to the physical `replenishment_monitor_view` via a **single standalone `db/migration/V2.2.01__replenishment_monitor_view_add_section_and_ro_id.sql`** (authored as `V2.2.02`), `CREATE OR REPLACE VIEW`. Entity unchanged. No onboarding-side migration.

**Drivers:**
1. **v1↔v2 parity (decisive for `ro_id`).** `ro_id` is the direct port of v1 `V1.26.30`. Omitting it permanently diverges the v2 physical view from v1 and violates the sync-sweep invariant that every ported v1 migration has a v2 twin.
2. **Entity/DDL consistency under `validate` (decisive for `section_name`).** `section_name` is v2-only, so v1 fidelity does not cover it; the sole reason to add the DDL column is that the entity deliberately declares `@Column(name="section_name")` and `ddl-auto=validate` fails on it otherwise. Keeping the entity a real-column contract (not `@Transient`) matches author intent and the live projection.
3. **Latent correctness (secondary).** The unused HAL `findAll` surface 500s under `validate`; adding the columns closes that latent gap and makes the entity fully materializable.

**Alternatives considered:**
- **Option B — drop or `@Transient` both entity fields.** *Genuinely lower-risk:* zero DDL, zero base-dump re-export follow-up, no `CREATE OR REPLACE` legality concern. It is **not runtime-wrong** — the live consumer is `getReplenishViewSummary()`, which is unaffected. **Rejected only** because (a) it abandons v1 parity for `ro_id` (the physical views diverge forever, breaking the sync-sweep invariant), and (b) it overrides the entity author's explicit intent that these be real columns. The rejection is on parity/consistency grounds, **not** correctness.
- **Hybrid — `@Transient section_name` + real `ro_id` column.** Rejected: mixes contracts, still diverges `section_name` from the live projection's physical expectation, and contradicts author intent.
- **Two-file design — standalone greenfield `V2.2.01` + a matching onboarding `db/v1-to-v2-onboarding/schema/V2.1.17`, kept in sync by an M2 drift-guard test.** This was the plan's **original** design and was **REJECTED** once implementation confirmed (per `db/migration/README.md` and `db/v1-to-v2-onboarding/README.md`) that both provisioning paths — brand-new v2 DB and onboarded v1→v2 DB — converge at the `V2.1.16` watermark and then **both** continue applying `V2.2.x` deltas from `db/migration/`. A `V2.1.17` onboarding file would only ever have served the onboarding-chain test harness (itself SBDEV-2217-broken, §8.3), never a real production path — so it added a drift-guard test and a permanent two-file sync burden for no provisioning benefit. One `V2.2.01` file suffices.
- **Fold greenfield fix into `V2.2.00` base dump.** Rejected by user decision — keep `V2.2.01` standalone; the base dump is regenerated wholesale and hand-edits are lost on re-export.

**Why chosen:** Parity + entity-contract consistency are repo invariants (Principles 1-2); Option B trades those away for a marginal risk reduction on a fix that is already low-risk. Once the single-file convergence was confirmed (Principle 3, revised), the two-file design's extra drift-guard machinery had no offsetting benefit, so it was dropped in favor of the single `V2.2.01` file.

**Consequences:**
- Physical view grows from 17 → 19 columns; the entity now fully validates and the HAL surface is materializable.
- No greenfield/onboarding drift surface — a single file reaches every tenant, so there is nothing to keep in sync.
- Adds a **base-dump re-export follow-up** (§8.6) — `V2.2.01` becomes a harmless idempotent no-op once folded into a future `V2.2.00`.

**Follow-ups:**
- §8.6 base-dump re-export watermark note.
- Add `ReplenishmentMonitorViewRepositoryIT` (secondary, `@Disabled` `TODO(SBDEV-2217)`) when convenient; re-enable once SBDEV-2217 is fixed.
- Code review + commit (not yet done).

### 8.5 Open questions
- **Direct-SQL / BI / reporting consumers** of `replenishment_monitor_view` **outside the app** (dashboards, ad-hoc SQL, ETL). If any exist, they strengthen the parity argument for real columns over `@Transient`. Frontend (`wms2-web-ui`/`wms2-mobile-ui`) and backend-Java `findAll` consumers are already checked — **none** for the HAL `findAll` surface. Still open.
- ~~**SBDEV-2217 clearance for M1:** confirm the onboarding-chain Testcontainers `@Test` runs clean without tripping the broken `outbox_message`/landlord boot.~~ **RESOLVED:** it did **not** run clean — the onboarding chain trips SBDEV-2217 under Testcontainers. This is precisely why the primary gate (§6, M1) was moved to build from `db/migration` (base dump + the fix delta) instead, which has no `outbox_message` forward-reference and is fully SBDEV-2217-independent.

### 8.6 Base-dump re-export watermark
When `V2.2.00__base_v2_schema.sql` is next re-exported from a converted DB past this fix, it will already contain `section_name`/`ro_id`. At that point `V2.2.01` is a redundant **no-op** (idempotent `CREATE OR REPLACE` — no double-apply hazard). Per `db/migration/README.md`, either leave `V2.2.01` as a harmless re-assertion or drop it during the same sanitize pass. (The 2026-07-17 re-export folded in `los_sequencenumber` only, **not** this fix, so `V2.2.01` is still a live delta.)

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

The M1 Testcontainers IT **is** the machine-checkable gate (M2 is obsolete, §6). A supplementary `sbdocs/9-System/scripts/verify-SBDEV-2384.sh` should assert, at minimum:
- **POSITIVE:** `V2.2.01` file exists at `v2/wms2-api/src/main/resources/db/migration/V2.2.01__replenishment_monitor_view_add_section_and_ro_id.sql`; contains `CREATE OR REPLACE VIEW`; contains `AS section_name` and `ro.id AS ro_id`.
- **POSITIVE:** `LEFT JOIN public.section sec ON sec.id = c.section_id` present (the `section_name` inner plumbing).
- **NEGATIVE:** neither `V2.1.16` nor `V2.2.00` was edited (git-diff clean on those paths); no `db/v1-to-v2-onboarding/schema/V2.1.17` file was added.
- **BEHAVIOR:** `mvn clean test -Dtest=ReplenishmentMonitorViewSchemaIT` passes (3/3, see §6).

A "DONE" claim with any FAIL line is not accepted.

### 9.2 Recommended OMC composition

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | 1 migration file + 1 IT, single subsystem, DDL-only |
| **Pre-draft step** | analyst+planner (+ consensus critic/architect — done) | high-parity-risk DDL; consensus already run |
| **Plan-review step** | critic | completed (this revision incorporates its MUST-FIX set) |
| **Implementation shape** | executor (via `wms-tdd-gate` first) | write M1 fail-first test, confirm RED, then author the migration — **done** |
| **Verification step** | verify-SBDEV-2384.sh + verifier | mandatory; test run GREEN (§6), script not yet run |
| **Code-review step** | code-reviewer | DDL shape correctness (CREATE OR REPLACE legality) — pending |
| **Commit step** | git-master | `ac1e061`, PR [#74 → develop](https://github.com/SiteBossInc/wms2-api/pull/74) |

**Handoff:** run `wms-tdd-gate` on this plan's M1 acceptance criteria first (write the failing `ReplenishmentMonitorViewSchemaIT`, confirm RED for the right reason, pause for approval) — **done, GREEN** — then code review and commit.
