---
title: "WMS v2 — Greenfield Database Provisioning (new-client onboarding)"
type: architecture
status: draft
version: v2
scope: db-provisioning
owner: Nam Park
created: 2026-05-31
updated: 2026-07-19
last_verified: 2026-07-19
verified_by: SBDEV-2607 provisioning + client-config tooling (provision-fresh-v2-db.sh, configure-client-sysprops.sh) — 2026-07-19; migration-dir reorg 2026-07-10; original analysis 2026-05-31
related:
  - ./wms-database-migration-guide.md
  - ./wms2-tenant-routing-datasource-topology.md
  - ../../1-Projects/wms2/plan/260523-UTC-TIMEZONE-MIGRATION.md
  - ../../1-Projects/wms2/plan/260527-hydra-v1-to-v2-migration-runbook.md
  - ../reports/260527-wms-v1-v2-db-migration-script-comparison.md
tags: [architecture, database, onboarding, flyway, provisioning, wms2]
---

# WMS v2 — Greenfield Database Provisioning

How to stand up a **brand-new client's** warehouse database directly on WMS v2, without replaying the v1→v2 history or running the UTC migration. This is the companion to [wms-database-migration-guide.md](./wms-database-migration-guide.md) (which covers *migrating existing* DBs) and to the v1→v2 + UTC plans ([260523](../../1-Projects/wms2/plan/260523-UTC-TIMEZONE-MIGRATION.md), [260527](../../1-Projects/wms2/plan/260527-hydra-v1-to-v2-migration-runbook.md)).

> **Status: IMPLEMENTED (2026-07-10).** The recommendation below has been realized. The migration
> directory was reorganized: `db/migration/` now holds the consolidated base dump
> **`V2.2.00__base_v2_schema.sql`** (the squashed baseline this note called `V2.0.00`, captured at the
> `V2.1.16` watermark) plus future `V2.2.x` deltas; the historical `V1.0.*→V2.1.16` scripts, the UTC
> rollback, and the per-TZ variants moved to **`db/v1-to-v2-onboarding/`** (`schema/`, `rollback/`,
> `onboarding-tz-variants/`). A greenfield client is now provisioned by applying the single base dump.
> Authoritative layout: `v2/wms2-api/src/main/resources/db/migration/README.md` +
> `.../db/v1-to-v2-onboarding/README.md`. The analysis in §§2–9 below is retained for rationale; read
> file/watermark names as `V2.2.00` / `db/v1-to-v2-onboarding/schema/` where older names appear.
>
> **Update (SBDEV-2607, 2026-07-19):** the two operator steps are now scripted.
> `db/provision-fresh-v2-db.sh` creates the DB + privilege model + applies `db/migration/`;
> `db/configure-client-sysprops.sh` performs the per-client `los_sysprop` seed described in §5
> (rewriting the `CHANGE-ME-FOR-NEW-CLIENT` placeholders baked into the base dump). §4/§5 below
> are updated to reference these tools.

---

## 1. The three onboarding scenarios (don't confuse them)

| Scenario | Starting point | Correct path |
|---|---|---|
| **A — Greenfield new client** | empty DB, no data | **This note** — apply one consolidated v2 baseline + a client-config seed. |
| **B — v1 client → v2** | a live v1 client DB with data | The [260527 runbook](../../1-Projects/wms2/plan/260527-hydra-v1-to-v2-migration-runbook.md): §0.6 schema bridge (`V2.1.01–V2.1.13`) then the `V1.2.0x` UTC conversion. |
| **C — existing v2 tenant → UTC** | a live v2 DB on the legacy timestamp model | The [260523 plan](../../1-Projects/wms2/plan/260523-UTC-TIMEZONE-MIGRATION.md) `V1.2.0x` conversion only. |

A greenfield client (A) should **never** go through B or C. It has no data to convert — it should be *born* in the v2 target state.

---

## 2. Why the existing scripts are the wrong tool for greenfield

A fresh DB built from the repo replays **all 23 migration scripts** in order — the shared baseline `V1.0.01–V1.1.05` (10) plus the v2-specific `V2.1.01–V2.1.13` (13). That sequence **runs cleanly** on an empty DB (the `V2.1.08/09` sysprop ids 140-143 and `V2.1.02`'s 144/145 are all free on a fresh baseline, so no PK conflicts). But it is the wrong tool for two reasons.

### 2.1 It produces the *pre-UTC legacy* state, not the v2 target

Verified at HEAD: `V1.0.01__wms_tables.sql` creates **88 `timestamp without time zone` columns and 0 `timestamptz`**. The v2 *target* state (per [260523](../../1-Projects/wms2/plan/260523-UTC-TIMEZONE-MIGRATION.md)) is `timestamptz` + UTC. So a greenfield client built from today's scripts gets **legacy timezone-naive columns** and would *still need the `V1.2.0x` conversion* to reach the target.

> ⚠️ This contradicts the 260523 plan's claim that *"new clients onboarding directly to wms2 require no migration — a fresh database … writes UTC from the first row."* That is only **half-true**: a UTC-configured app writes UTC *values*, but into columns that carry **no timezone**. You do not get the explicit-timezone target (`timestamptz`) unless the schema is built that way from the start. This note is what makes that claim actually true.

### 2.2 It is archaeological churn

Replaying history re-does work that the final state subsumes:

- **The order/dashboard view is built then replaced twice** — `V1.0.02__wms_views.sql` → `V1.1.01__wms_views.sql` → `V2.1.03__update_dashboard_summary_view.sql`.
- **`transaction_detail` is created then re-overridden** — `V1.0.03__wms_functions.sql` → `V2.1.07__update_transaction_detail_pick_amount_filter.sql`.
- **Sysprops land at hardcoded *historical* ids** (`V2.1.02` @144/145, `V2.1.08` @140/141/142, `V2.1.09` @143) chosen to align with the v1 baseline for *migration* no-op safety — irrelevant for greenfield.
- You inherit **`V1.0.04`'s v1-era seed clients/users** that a new client may not want.
- Then, to reach the target state, `V1.2.0x` **rewrites every one of those tables again**. On an empty DB the rewrites are cheap, but it is still "build it wrong, then fix it."

None of this is *broken* — it is **slow to reason about, easy to get subtly wrong, and produces the wrong end state**.

---

## 3. Recommended approach — a consolidated v2 greenfield baseline

**Ship one squashed schema snapshot that is already in the v2 target state, and stop replaying history for new clients.**

1. After the UTC work lands (§7), migrate **one reference DB** through the full sequence so it sits at the true v2 end state — `timestamptz` columns, all constraints/indexes/functions, and the platform-default sysprops.
2. `pg_dump --schema-only` that reference DB and check it in as a single **`V2.0.00__greenfield_baseline.sql`** (schema + platform-default sysprops, **minus** client-specifics).
3. A new client = **one apply** of that baseline + a small client-config seed (see §5).
4. **Keep the incremental `V2.1.x` + `V1.2.0x` scripts** for existing DBs only (scenarios B and C). Greenfield ≠ migration.

The new client is born correct: timezone-explicit schema, no v1 seed cruft, no conversion pass, no historical id juggling.

### Why this is safe *here* specifically

`flyway-core` is `<scope>test</scope>` in `v2/wms2-api/pom.xml` — **Flyway never runs in production**, and there is no `flyway_schema_history` on production tenant DBs (all migration is manual `psql`). Therefore:

- There is **no checksum or baseline-version constraint** preventing a squashed baseline. Shipping `V2.0.00` cannot break any existing DB, because nothing replays migrations against existing DBs.
- You are free to keep the historical scripts in the repo (they document provenance and still serve scenarios B/C) while routing greenfield onboarding to the squashed baseline.

---

## 4. Procedure (once prerequisites in §7 are met)

```bash
# 1. On a clean reference DB, apply baseline + V2.1.x + V1.2.0x to reach the v2 target state.
#    (One-time, by the engineer who owns the baseline — not per client.)

# 2. Snapshot schema + platform-default data, excluding client-specific rows.
pg_dump --schema-only --no-owner --no-privileges \
  -h <ref_host> -U <user> -d <reference_v2_db> \
  > V2.0.00__greenfield_baseline.sql
# (Append the platform-default los_sysprop / mywms_function / mywms_role seed rows that are
#  client-independent; EXCLUDE per-client values — see §5.)

# 3. Per new client: create the DB and apply the baseline.
#    Realized tool (SBDEV-2607): db/provision-fresh-v2-db.sh does create + privileges + apply + verify.
db/provision-fresh-v2-db.sh --host <host> --port <port> --dbname <new_client_db> --owner <app_role>

# 4. Seed client-specific config (see §5), then register the tenant in the landlord DB.
#    Realized tool (SBDEV-2607): db/configure-client-sysprops.sh rewrites the los_sysprop placeholders.
db/configure-client-sysprops.sh --dbname <new_client_db> \
  --oms-tenant-id <id> --warehouse <CODE> --timezone <TZ> \
  --mobile-ui-url <mobile_url> --oms-api-base-url <oms_api_base>
```

> Verify the baseline produces the target state: `SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND data_type='timestamp without time zone';` must be **0** (all converted to `timestamp with time zone`).

### Lighter alternative — template DB

If new clients share a database server, maintain a **golden empty v2 DB** and clone it per client:

```sql
CREATE DATABASE <new_client_db> TEMPLATE golden_v2_template;
```

Fastest provisioning, but requires keeping the golden DB current with every schema change and only works same-server. The `pg_dump` baseline is portable across servers; the template is not.

---

## 5. Client-specific values to seed (NOT in the baseline)

The baseline carries only client-independent defaults — in the `V2.2.00` base dump the client-specific
`los_sysprop` rows ship with `CHANGE-ME-FOR-NEW-CLIENT` placeholders. **`db/configure-client-sysprops.sh`**
(SBDEV-2607) rewrites them in one transaction and verifies no placeholder remains. The keys it sets:

| `los_sysprop` key | Source flag | Notes |
|---|---|---|
| `MOBILE_UI_URL` | `--mobile-ui-url` | Full mobile UI URL, e.g. `https://nywh-hydra.wms.dev.sbo.li/mobile`. |
| `MULTIWAREHOUSE_IDENTIFIER` | `--warehouse` | e.g. `NYWH`. |
| `WAREHOUSE_NAME` | derived = `--warehouse` (overridable) | e.g. `NYWH`. |
| `OMS_TENANT_ID` | `--oms-tenant-id` | e.g. `hydra`. |
| `System Time Zone` | `--timezone` | IANA zone; drives per-tenant business-date logic + `connectionInitSql` session TZ. e.g. `America/New_York`. |
| `SYSTEM_OMS_NAME` | derived = `OMS-<UPPER(tenant)>` (overridable) | e.g. `OMS-HYDRA`. |
| `SYSTEM_WMS_NAME` | derived = `WMS-<warehouse>` (overridable) | e.g. `WMS-NYWH`. |
| `WEBS%` (all `WEBSERVICE_*` callback URLs) | `--oms-api-base-url` | Replaces the `CHANGE-ME-FOR-NEW-CLIENT/` prefix with the client's real OMS API base, e.g. `https://api-oms.dev.sbo.li/`. Idempotent. |

Still done separately (not by the script):

| Value | Where | Notes |
|---|---|---|
| Tenant / facility identity | tenant DB seed | Client code, facility codes, warehouse config. |
| `tenant_db_configuration` + `tenant_discovery` | **landlord DB** | Routing entry + `tenant_discovery.timezone` (read by the frontend via `GET /api/public/authConfig`). See [wms2-tenant-routing-datasource-topology.md](./wms2-tenant-routing-datasource-topology.md). |

Greenfield clients write UTC from the first row (UTC-configured app + `timestamptz` columns), so the `System Time Zone` sysprop is used only for **display/business-date** purposes, never for write-path conversion.

---

## 6. Alternatives considered (and rejected)

- **Edit the shipped baseline `V1.0.01` to emit `timestamptz`.** Rejected: it would diverge the v1/v2 shared baseline (still byte-identical through `V1.1.05`, per the [script-comparison report](../reports/260527-wms-v1-v2-db-migration-script-comparison.md)) and rewrite history other docs reference. The squashed `V2.0.00` adds a new artifact instead of mutating a shared one.
- **Just replay all 23 scripts + `V1.2.0x` for greenfield.** Rejected per §2 — wrong end state without `V1.2.0x`, archaeological churn with it.

---

## 7. Sequencing — prerequisite

This baseline can only be generated **after** the UTC migration ships, because the snapshot must be taken from a DB that is *already in the target state*. As of 2026-05-31 the prerequisites do **not** exist (verified):

1. ~~`V1.2.01–V1.2.04` + `V1.2.99` UTC SQL authored and committed~~ — **DONE.** The `V1.2.0x` UTC scripts landed and now live in `db/v1-to-v2-onboarding/schema/` (rollback in `db/v1-to-v2-onboarding/rollback/`).
2. Phase-1/Phase-2 app code merged (`TimezoneService`, `resolveWarehouseTz`/`connectionInitSql`, UTC `application.properties`).
3. A reference DB migrated through baseline → `V2.1.x` → `V1.2.0x` to snapshot.

Generating the baseline before these land would just re-snapshot the legacy `timestamp without time zone` state — defeating the purpose.

---

## 8. How to use this doc

| You are… | Do this |
|---|---|
| Onboarding a **brand-new** client | Use §3/§4 once §7 prerequisites are met; otherwise replay the 23 scripts and run `V1.2.0x` on the empty DB as an interim path. |
| Onboarding an **existing v1** client | Ignore this doc — use the [260527 runbook](../../1-Projects/wms2/plan/260527-hydra-v1-to-v2-migration-runbook.md). |
| Converting an **existing v2** tenant to UTC | Use the [260523 plan](../../1-Projects/wms2/plan/260523-UTC-TIMEZONE-MIGRATION.md). |
| Maintaining the baseline | Regenerate `V2.0.00` whenever the schema changes; keep the incremental `V2.1.x`/`V1.2.0x` scripts for scenarios B/C. |

## 9. Open decisions

- **Who owns regenerating `V2.0.00`** when schema changes, and how is drift between the baseline and the incremental scripts detected? (Proposal: a CI check that builds a fresh DB both ways and diffs the schema.)
- **`pg_dump` baseline vs template DB** as the canonical mechanism — decide per the deployment topology (cross-server portability vs same-server speed).
