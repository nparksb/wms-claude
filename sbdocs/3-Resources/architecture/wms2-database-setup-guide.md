---
title: "WMS v2 — Database Setup Guide (fresh-start vs v1→v2 migration)"
type: architecture
status: active
version: v2
scope: wms2-api
owner: Nam Park
created: 2026-07-12
updated: 2026-07-19
last_verified: 2026-07-19
verified_against: wms2-api@feature/fresh-v2-db-base-refresh-and-provisioning 9ee6cff (SBDEV-2607 PR #79 — provisioning + client-config tools); base reorg on develop 43384c0 (PR #71)
related:
  - "[[wms2-greenfield-db-provisioning]]"
  - "[[wms-database-migration-guide]]"
  - "[[wms2-tenant-routing-datasource-topology]]"
  - "../../2-Areas/wms-utc-timezone-migration/README.md"
  - "../../1-Projects/wms2/plan/260523-UTC-TIMEZONE-MIGRATION.md"
  - "../../1-Projects/wms2/plan/260527-hydra-v1-to-v2-migration-runbook.md"
tags:
  - architecture
  - database
  - migration
  - onboarding
  - flyway
---

# WMS v2 — Database Setup Guide

How to stand up a **WMS v2 tenant database**. There are **two** ways, for two different situations. This guide explains which to use, summarizes each end-to-end, and points at the authoritative scripts/runbooks.

> **Foundational fact (applies to both paths):** the v2 app **does not run Flyway at runtime** — migrations are applied **manually by an operator** (`psql`/`flyway` CLI) against the **tenant** database, then the tenant is registered in the landlord DB. (See the UTC migration plan §0.5.) So "setting up the DB" is always a deliberate provisioning step, never something the running service does on boot.

---

## 1. Which path do I need?

| Situation | Path | Section |
|-----------|------|---------|
| A brand-new client with **no existing WMS data** — greenfield | **A. Fresh-start (Flyway base dump)** | §2 |
| An **existing WMS v1 client** whose live database must be carried onto v2 | **B. v1→v2 migration (onboarding toolkit)** | §3 |

Both paths converge on the **same schema version** — the `V2.1.16` "watermark" — and both continue forward on the same `V2.2.x` deltas afterward (§4). The difference is only how you *reach* that baseline: load a pre-built dump, or transform a live v1 DB in place.

Everything lives under `v2/wms2-api/src/main/resources/db/`, reorganized (PR #71, 2026-07-12) into two clearly-separated lanes:

```
db/
├── migration/                    # ← Path A: fresh-start. Small: base dump + future deltas.
│   ├── V2.2.00__base_v2_schema.sql   # schema+seed dump through the V2.1.16 watermark (UTC); includes los_sequencenumber seed
│   └── V2.2.01+__*.sql               # ALL new post-cutover deltas go here from now on
└── v1-to-v2-onboarding/          # ← Path B: migration toolkit (NOT used to build a fresh DB)
    ├── schema/                       # linear forward history V1.0.*→V2.1.16 (also the IT-harness source)
    ├── rollback/V1.2.99__…           # UTC rollback — MANUAL ONLY, kept out of any Flyway-scanned dir
    └── onboarding-tz-variants/       # per-source-TZ UTC script copies + the psql automation pipeline
        └── scripts/                  # 00-restore … 09-smoke, 99-rollback, _lib.sh, migration.env*
```

---

## 2. Path A — Fresh-start v2 database (Flyway base dump)

**Use for:** a new client with no v1 data. **Owner:** provisioning engineer. **Time:** minutes.

Before the reorg, greenfield had no clean tool (replaying the full v1→v2 linear history including a one-time UTC conversion was the wrong shape — see `[[wms2-greenfield-db-provisioning]]` §2). PR #71 resolved that by exporting a **sanitized, Flyway-runnable base dump** (`V2.2.00__base_v2_schema.sql`) that already captures the entire schema through `V2.1.16` in UTC. Building a fresh DB is now a one-shot load.

### Procedure

> **One-shot tools (SBDEV-2607, PR #79):** `db/provision-fresh-v2-db.sh` does steps 1–2 (create DB +
> reproduce the v2t owner-only privilege model + apply `db/migration/` via flyway or psql + verify);
> `db/configure-client-sysprops.sh` does step 3 (the per-client `los_sysprop` seed). The manual
> equivalents are kept below for reference.

1. **Create an empty tenant database** on the target Postgres.
2. **Apply `db/migration/`** — either method produces the identical schema:

   **A1. Flyway (one command):**
   ```bash
   flyway -url=jdbc:postgresql://<host>:<port>/<db> -user=<u> -password=<p> \
     -locations=filesystem:src/main/resources/db/migration migrate
   ```
   **A2. psql (manual):**
   ```bash
   psql -h <host> -U <u> -d <db> -f src/main/resources/db/migration/V2.2.00__base_v2_schema.sql
   # then apply each V2.2.x delta in version order, e.g.
   psql -h <host> -U <u> -d <db> -f src/main/resources/db/migration/V2.2.01__replenishment_monitor_view_add_section_and_ro_id.sql
   psql -h <host> -U <u> -d <db> -f src/main/resources/db/migration/V2.2.02__lock_report_exclude_shipped.sql
   ```
   > `los_sequencenumber` seed rows are now baked into the `V2.2.00` base dump (folded in when the dump was
   > re-exported from a converted v2 reference DB, 2026-07-17); the former standalone `V2.2.01__los_sequencenumber_init.sql`
   > was removed and the later deltas renumbered down by one.
3. **Seed client-specific config** that is deliberately NOT in the base dump. The base dump seeds the
   per-client `los_sysprop` rows with `CHANGE-ME-FOR-NEW-CLIENT` placeholders; run
   **`db/configure-client-sysprops.sh`** to rewrite them to the client's real values in one transaction
   (`MOBILE_UI_URL`, `MULTIWAREHOUSE_IDENTIFIER`, `WAREHOUSE_NAME`, `OMS_TENANT_ID`, `System Time Zone`,
   `SYSTEM_OMS_NAME`, `SYSTEM_WMS_NAME`, and the `WEBS%` OMS-callback base URL). It verifies no placeholder
   remains. See `[[wms2-greenfield-db-provisioning]]` §5 for the full key→flag table.

   ```bash
   db/configure-client-sysprops.sh --dbname <db> \
     --oms-tenant-id <id> --warehouse <CODE> --timezone <TZ> \
     --mobile-ui-url <mobile_url> --oms-api-base-url <oms_api_base>
   ```
4. **Register the tenant** in the landlord DB (routing key = 2-char tenant + 2-char facility) so `TenantDynamicRoutingDataSource` can reach it — see `[[wms2-tenant-routing-datasource-topology]]`.

### Do NOT

- **Do not replay `db/v1-to-v2-onboarding/schema/`** to build a fresh DB. Those `V1.0.*→V2.1.*` scripts are already baked into the base dump; re-running them collides.
- **Do not include per-client rows in the base dump.** It carries platform-default seed data only; client-specific values are seeded in step 3.

### Maintaining the base dump

When you re-export `V2.2.00` from a converted v2 reference DB, keep it Flyway-runnable: dump with `pg_dump --no-owner --no-privileges`, avoid `COPY … FROM stdin` (use `--inserts` / `--rows-per-insert=100`), and comment out pg_dump-16's `\restrict`/`\unrestrict` meta-commands. **If the reference DB was itself provisioned by Flyway, exclude its bookkeeping table** — `--exclude-table=public.flyway_schema_history` — or the dump re-creates a stale history that collides with a fresh `flyway migrate`. The exact `sed` sanitizer is in `db/migration/README.md`.

---

## 3. Path B — Migrate an existing v1 client to v2 (onboarding toolkit)

**Use for:** an existing WMS **v1** client whose live database must become a v2 database in place. **Owner:** migration engineer + DBA, on a maintenance window. **Time:** hours (dominated by the large-table UTC rewrite). **Authoritative runbook:** the per-client runbooks (`260527-hydra-…`, `260606-wineco-…`, `260628-shipitez-…`) + the master UTC plan `260523-UTC-TIMEZONE-MIGRATION.md`; operational SOP in `2-Areas/wms-utc-timezone-migration/README.md`.

This is not a schema load — it **transforms a live v1 database** into the v2 baseline: it bridges the schema forward (`V2.1.01…V2.1.16`) and performs the **one-time UTC-at-rest conversion** (rewriting timestamp columns to `timestamptz`). It is fully scripted and **client-agnostic** — the only per-client input is `migration.env`.

### 3.1 The one rule that prevents a silent 3-hour data corruption

The UTC conversion is keyed on the **source write-timezone** — the wall-clock the source v1 instance *physically wrote its timestamps in* (its instance-wide `hibernate.jdbc.time_zone`) — **NOT the warehouse's geographic location.**

- A NY *warehouse* that was already running on the wms2 platform wrote **LA** wall-clock (wms2's global `time_zone=America/Los_Angeles`) → it must use the **LA** scripts. Choosing the NY variant would shift every timestamp 3 hours **with no error**.
- Because `hibernate.jdbc.time_zone` is instance-wide, a client running both NY and LA warehouses still wrote **one** zone → **one** variant for the whole conversion (no per-warehouse split).

`CLIENT_HIBERNATE_TZ` in `migration.env` is that source write-TZ and the **only** knob that selects the script variant set. `01-preflight.sh` (PREP-1) is a **hard gate** that refuses to proceed unless the deployed v1 TZ matches it.

### 3.2 Setup

```bash
cd src/main/resources/db/v1-to-v2-onboarding/onboarding-tz-variants/scripts
cp migration.env.example migration.env      # gitignored — DB creds, OMS host, CLIENT_HIBERNATE_TZ
$EDITOR migration.env
```
(Committed per-client envs exist as references: `migration.env.{hydra,wineco,shipitez-la,shipitez-ny}`.)

### 3.3 The pipeline (run in order; phase gates between steps per the runbook)

| Script | Phase | What it does |
|--------|-------|--------------|
| `01-preflight.sh` | A | Read-only checks + baseline row counts → `preflight-report.txt`. **Hard TZ gate.** |
| `02-backup.sh` | A | `pg_dump -Fc` + `pg_restore --list` verify (or verifies a DBA backup if `RUNTIME_BACKUP=false`). |
| `03-gen-scripts.sh` | A | Selects the per-source-TZ `V1.2.01/02/99` variant + OMS-host-substituted `V2.1.02/V2.1.13` into the work dir. |
| `04-schema-bridge.sh` | C | Stuck-order fix (§0.6 Step A) + apply `V2.1.01…V2.1.13` in order. |
| `05-verify-bridge.sh` | C | Bridge verification (tables, syskeys, functions, OMS host). |
| `06-drain.sh` | E | Poll the outbox to 0, snapshot+clear idempotency, confirm 0 `IN_FLIGHT`. |
| `07-utc-migrate.sh` | F | The UTC conversion: `V1.2.01`(std) → `02`(large) → `03`(outbox/new) → `04`(views) → `05`(functions). |
| `08-verify-utc.sh` | F | Schema / row-count / function / view verify + `ANALYZE` + spot-checks. |
| `09-smoke.sh` | H | `SHOW timezone` vs sysprop, `CURRENT_DATE`, format-flag ordering guard. |
| `99-rollback.sh` | F/H | Hard rollback (the selected `V1.2.99` variant). |
| `00-restore.sh` | recovery | `pg_restore -j` from the Phase-A dump (partial-failure recovery; RTO unrehearsed). |

Each 🤖 phase in the runbook maps to exactly one script here.

### 3.4 Recovery notes

- `07-utc-migrate.sh` is **not cleanly re-runnable as a whole** — `V1.2.01`'s canary aborts on already-`timestamptz` data. Individual steps are re-runnable (`V1.2.02` is per-table resumable); recovery = hand-run the remaining step(s), or `00-restore.sh` for a mixed/partial large-table state.
- After conversion, seed any client-specific config and register the tenant in the landlord DB (same as Path A steps 3–4).

### 3.5 Adding a new source timezone (beyond NY/LA)

Don't substitute the TZ at runtime — generate a **committed, reviewed** variant once (`sed America/Los_Angeles → <TZ>` over the `V1.2.01/02/99` scripts; recipe in `onboarding-tz-variants/scripts/README.md`). `03-gen-scripts.sh` picks it up automatically once `CLIENT_HIBERNATE_TZ` is set.

---

## 4. What the two paths share

- **Watermark `V2.1.16`.** `db/v1-to-v2-onboarding/schema/` runs `V1.0.01 → V2.1.16`; `db/migration/V2.2.00` is a dump of exactly that endpoint. A converted v1 client and a fresh v2 DB therefore land at the **identical schema version**.
- **One forward lane afterward.** From the watermark on, *all* new schema changes are `V2.2.x` deltas in **`db/migration/`** (check the highest existing `V2.2.*` first; never edit an applied migration). Both provisioning paths consume the same deltas.
- **No runtime Flyway.** Provisioning is an operator step; the running service never migrates.
- **The IT test harness** (`AppPostgresDBSetupExtension`, outbox ITs, `test/resources/flyway.conf`) builds test schemas from the **full linear history** at `classpath:db/v1-to-v2-onboarding/schema` — *not* from `db/migration/`. So keep that linear history clean and duplicate-free (this is why the rollback and NY variant scripts live outside `schema/`).
- **Tenancy.** Either way, the last step is registering the tenant in the landlord DB so the routing key resolves — see `[[wms2-tenant-routing-datasource-topology]]`.

---

## 5. Related documents

- **Writing migrations safely** (versioning conventions, safe patterns for live tables, rollback) → `[[wms-database-migration-guide]]`.
- **Greenfield provisioning detail** (client-specific seed rows, tenant registration) → `[[wms2-greenfield-db-provisioning]]` (note: its "recommended consolidated baseline" is now *implemented* as `db/migration/V2.2.00`).
- **UTC migration** — master plan `1-Projects/wms2/plan/260523-UTC-TIMEZONE-MIGRATION.md`; per-client runbooks `260527-hydra-…`, `260606-wineco-…`, `260628-shipitez-…`; SOP `2-Areas/wms-utc-timezone-migration/README.md`.
- **In-repo READMEs (authoritative, closest to the scripts):** `db/migration/README.md`, `db/v1-to-v2-onboarding/README.md`, `db/v1-to-v2-onboarding/onboarding-tz-variants/scripts/README.md`.
