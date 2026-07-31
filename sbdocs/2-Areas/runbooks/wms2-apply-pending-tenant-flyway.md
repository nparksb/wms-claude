---
title: "Runbook: Apply pending tenant Flyway scripts (DEV / UAT / PRD)"
type: runbook
status: active
version: "wms2-api develop (dev) / release (uat) / main (prd)"
scope: wms2-api v2 / DEV + UAT + PRODUCTION
owner: nam.park@siteboss.net
created: 2026-07-27
updated: 2026-07-30
last_verified: 2026-07-30
verified_by: nam.park@siteboss.net
alert: "Deploy prerequisite — schema behind the environment's branch; 500s on replenishment monitor / lock report; 'column does not exist' after deploy"
severity: SEV3
escalation: "WMS backend owner before any --apply on a tenant that reports NEEDS-BASELINE, and before any --apply against --env prd"
related:
  - "[[wms2-tenant-routing-datasource-topology]]"
  - "[[wms2-landlord-vs-tenant-entity-map]]"
tags:
  - runbook
  - flyway
  - dev
  - uat
  - production
  - multi-tenant
---

# Runbook: Apply pending tenant Flyway scripts (DEV / UAT / PRD)

**Alert:** deploy prerequisite | **Severity:** SEV3 (SEV2 on PRD)
**Scope:** every tenant DB in DEV, UAT or PRODUCTION | **Version:** `develop` · `release` · `main`
**Owner:** nam.park@siteboss.net | **Last verified:** 2026-07-30

> Run this for every `wms2-api` deploy. Each environment tracks its own branch, so the
> migration set in `db/migration/` **on that branch** is the target its tenant DBs must reach.
> DEV runs `develop`, UAT runs `release`, PRODUCTION runs `main`. Pick the environment with
> `--env` — it is required and has no default.
>
> The three environments differ in more than a port (§4.1). Read §5.4 before your first DEV
> run: DEV auto-deploys on push, so the UAT "migrate, then deploy" ordering does not transfer.
> Read **§5.5 before any PRD run** — production adds a second confirmation flag, a
> staleness check that DEV/UAT do not need, and a co-tenancy hazard (live v1 databases on
> the same server) that exists nowhere else.

---

## 1. When to Use This Runbook

- Before deploying a new `wms2-api:rc-*` image to UAT.
- **Before deploying a new `wms2-api:<version>-prod` image to PRODUCTION**, i.e. after a
  promotion merge of `release` into `main` and before rolling the image (§5.5).
- Around a merge to `develop` that carries a new `V2.2.x` — see §5.4 for the ordering, which
  is *not* the same as UAT's or PRD's.
- After a new client DB is onboarded to any environment (it will not be in any hard-coded
  list — this procedure discovers it from the landlord).
- When a tenant reports a 500 whose cause is a missing column/view the entity expects.

**Do NOT use this runbook for:**
- The **landlord** schema. It is not Flyway-managed — see §7.
- The **v1** databases. On the production server they sit right beside the single v2 DB
  (§4.2) and this migration set would corrupt them. They are out of scope entirely.
- A brand-new DB being provisioned from scratch — use `provision-fresh-v2-db.sh` instead.

---

## 2. Severity & Impact

| Aspect | Detail |
|---|---|
| User impact | Missing view/column → HTTP 500 on the affected screen. `ddl-auto=none` in prod profile, so the app **starts fine and fails at request time** — no startup crash to alert you. |
| Blast radius | Per tenant. One stale DB breaks only that warehouse. **On PRD there is exactly one v2 tenant (`wh01_hydra_v2`/`nywh`), so "one tenant" and "all of v2 production" are the same thing** — no partial-fleet cushion. |
| Paging event? | No on DEV/UAT — planned step. **On PRD treat it as SEV2 change-controlled work**: real orders are in flight, and a failed `migrate` leaves the single production v2 DB partially migrated (§8.2). |
| Reversibility | Views are `CREATE OR REPLACE` (reversible). `ALTER TABLE ADD COLUMN` is forward-only. On PRD take a snapshot first (§5.5) — there is no `undo` in Flyway OSS. |

---

## 3. Key Facts (read once)

- **The app does not run Flyway at runtime.** Migrations are an operator step. Nothing
  self-heals on deploy.
- **Two migration sets exist. Only one is in play here:**
  - `db/migration/` — `V2.2.x`, the live set. **This runbook applies these.**
  - `db/v1-to-v2-onboarding/schema/` — `V1.0.01`→`V2.1.17`, historical. **Never replay.**
    Already baked into `V2.2.00__base_v2_schema.sql`.
- **A v1→v2 migrated tenant lands at the `V2.2.00` watermark** and continues on `V2.2.01+`.
- **Tenant credentials live in the landlord** (`tenant_db_configuration.db_password`, plaintext),
  so discovery is fully automatable. Treat that table as a secret store.
- **`db_url` in the landlord is the *application's* view** (`dev.sbo.li:25060` /
  `uat.sbo.li:25060` / `100.92.232.69:25060` on PRD — a Tailscale address, not a public host).
  From a workstation you reach the same server through an SSH tunnel (`localhost:25060` /
  `25062` / `25061`). The host/port must be rewritten — the driver script does this from the
  `--env` profile, overridable via `--tenant-host/--tenant-port`.
- **Each environment tracks its own branch** (`develop` on DEV, `release` on UAT, `main` on
  PRD), so "the migration set" is branch-dependent. A checkout on the wrong branch produces a
  wrong pending list in the dangerous direction — see §4.4 and §8.6.
- **The landlord role is not the same everywhere.** DEV/UAT use `wms_landlord`; PRD uses
  **`wms2_landlord_app`** against a landlord DB named **`wms2_landlord`**. Both the DB name and
  the role are part of the `--env` profile, because a hard-coded role turns a wrong-environment
  mistake into what looks like a password failure.
- **PRD is PostgreSQL 14**, DEV/UAT are 16. Nothing in the current `V2.2.x` set depends on a
  15+ feature, but a future migration using one would pass UAT and fail on production — check
  the server version before writing anything version-sensitive.

---

## 4. Preconditions

### 4.1 Environment matrix

Everything that differs between the three environments. The script encodes this as `--env`;
the table is here so you can sanity-check what it did.

| | **dev** | **uat** | **prd** |
|---|---|---|---|
| Branch | `develop` | `release` | **`main`** |
| Tunnel port | `25060` | `25062` | **`25061`** |
| Tunnel target | `dev.sbo.li:25060` | `uat.sbo.li:25060` | `100.92.232.69:25060` via `wms.siteboss.net` |
| Landlord DB | **`dev_landlord`** | `landlord` | **`wms2_landlord`** |
| Landlord role | `wms_landlord` | `wms_landlord` | **`wms2_landlord_app`** |
| Tenant host:port (via tunnel) | `localhost:25060` | `localhost:25062` | `localhost:25061` |
| `db_url` as the app sees it | `dev.sbo.li:25060` | `uat.sbo.li:25060` | `100.92.232.69:25060` |
| Postgres server | 16 | 16 | **14** |
| v2 tenants | several (+ inactive scratch) | 4 | **1** (`nywh` → `wh01_hydra_v2`) |
| Image tag | `wms2-api:develop` (mutable) | `wms2-api:rc-<version>` | `wms2-api:<version>-prod` + `:latest` |
| Deploy trigger | **automatic** — Portainer webhooks on push | manual | **manual** — the prod webhook is commented out in `docker-image.yml` |
| Version check | `GET /api/public/version` → `develop-<sha>` | `git tag --points-at HEAD` vs `rc-` tag | `git describe --abbrev=0` (§4.4) |
| Extra `--apply` gate | — | — | **`--confirm-production`** (§5.5) |

> **The landlord DB name differs, and the wrong one does not error.** A stale database
> literally named `landlord` also exists on the DEV server. It holds one abandoned row
> (`develop → wh01_hydra_v2`) whose `db_url` even points at the right host, so a wrong
> `--landlord-db` yields a plausible tenant list rather than a failure. It never received
> L001, which is what the script's preflight probe keys on (§7). Confirmed 2026-07-29:
> `dev_landlord` carries all live JDBC connections; `25060/landlord` carries none.

> **All three tunnels are open at once on a typical workstation**, on adjacent ports, and
> `25061` (production) sits *between* `25060` (dev) and `25062` (uat). A mistyped port is the
> single easiest way to touch production by accident. This is why `--env` has no default and
> why `--apply` on `prd` needs a second flag.

### 4.2 PRD only — live v1 databases share the server

The production Postgres instance hosts the single v2 database alongside **six live v1
databases**. Confirmed 2026-07-30:

| Database | Size | Stack |
|---|---|---|
| `wh01_hydra_v2` | 30 MB | **v2 — the only one in scope** |
| `wh01_om1` | 10 GB | v1 |
| `wh01_shipitez` | 2337 MB | v1 |
| `wh02_hydra` | 1301 MB | v1 |
| `wh01_hydra` | 800 MB | v1 |
| `wh02_shipitez` | 225 MB | v1 |
| `wh01_hmg` | 12 MB | v1 |
| `wms2_landlord` | 8955 kB | v2 landlord (not Flyway-managed, §7) |
| `keycloak`, `keycloak2` | 38/23 MB | auth |

The v1 databases have no `flyway_schema_history` and a different schema entirely. Running this
migration set against one would be a data-loss event, and the `NEEDS-BASELINE` guard would
*not* save you — it only skips them, but a hand-run `flyway migrate` would not.

**The only thing scoping this correctly is landlord discovery**: `tenant_db_configuration`
lists exactly one row. Never bypass that step on PRD by naming a database yourself, and note
that the size column above is the fastest sanity check — the v2 DB is the *small* one.

### 4.3 Shared preconditions

```bash
flyway --version        # Flyway CLI on PATH (verified against 12.11.0)
psql --version
```

Open the tunnel for the target environment. Within one environment the landlord and every
tenant are reachable on the same host:port. The production tunnel is:

```bash
ssh -N -L 25061:100.92.232.69:25060 npark@wms.siteboss.net
```

### 4.4 Per-environment checkout

**UAT** — the release tag must match the image you are about to deploy:

```bash
cd <wms2-api>
git fetch origin release --tags
git checkout release && git pull
git tag --points-at HEAD    # e.g. v0.0.9 → matches image rc-0.0.9
```

UAT images are tagged `wms2-api:rc-<version>`, `<version>` being the semver tag on `release`
HEAD with `v` stripped (`.github/workflows/docker-image-uat.yml`). A mismatch means you are
migrating to the wrong target.

**DEV** — there is no semver tag to match; `wms2-api:develop` is mutable and rebuilt on every
push. The equivalent check is the running SHA:

```bash
cd <wms2-api>
git fetch origin develop && git checkout develop && git pull
curl -s https://<dev-api-host>/api/public/version   # expect develop-<sha> (PublicVersionController)
```

`APP_VERSION=develop-${{ github.sha }}` is baked in at build time
(`.github/workflows/docker-image-develop.yml`), so that value is the deployed commit.

**PRD** — use a throwaway worktree named `main`, and confirm it is at *current* `origin/main`:

```bash
cd <wms2-api>
git fetch origin main --tags
git worktree add -B main /tmp/wms2-api-main origin/main    # clean, correctly-named
git -C /tmp/wms2-api-main describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0
```

> **On `main` the semver tag is almost never *on* HEAD.** `main` is reached by a promotion
> merge from `release`, so the tag sits on the merged-in commit and `git tag --points-at HEAD`
> (the UAT check) returns nothing. The prod build workflow resolves the version with
> `git describe --tags --abbrev=0` for exactly this reason, so that is the check to mirror —
> the script does, and prints `(reachable, not on HEAD)` to make the distinction visible.
> An empty `git tag --points-at HEAD` on `main` is normal and is **not** evidence of a problem.

`docker-image.yml` also resolves an `owl-v*` platform tag. As of 2026-07-30 no `owl-v*` tag is
reachable from `origin/main`, so prod images carry an empty `PLATFORM_RELEASE` and the workflow
emits a `::warning::`. That is a release-tagging gap, not a migration concern — it does not
affect this procedure, but do not read the absence as a failed build.

> **`--apply` refuses to run from a branch other than the environment's.** A `develop`
> checkout pointed at `--env uat` reports every develop-only migration as "pending" for UAT —
> `--status` will show it, and `--apply` would push it in ahead of the release. Override only
> deliberately, with `--allow-branch-mismatch` (the §5.4 pre-merge flow needs it).
>
> **On PRD the branch check is necessary but not sufficient**, so the script adds a staleness
> check. Being *on* `main` does not prove being on the *current* `main`: a checkout behind
> `origin/main` is on the right branch with a migration set that is too **short**, so
> `--status` reports "all current" and the gap is invisible. The script warns when the checkout
> is behind its upstream and **refuses `--apply` to production outright** in that case (§8.8).

---

## 5. Standard Path — discover, report, apply

The driver script lives at
[`9-System/scripts/apply-pending-tenant-flyway.sh`](../../9-System/scripts/apply-pending-tenant-flyway.sh).

### 5.1 Report first (read-only, always safe)

```bash
export PGPASSWORD_LANDLORD='<wms_landlord password>'

sbdocs/9-System/scripts/apply-pending-tenant-flyway.sh \
  --env dev \
  --repo /path/to/wms2-api \
  --status
```

`--env dev|uat|prd` is **required and has no default**. All three environments answer on
`localhost` and differ only by port — with production's `25061` sitting between dev's `25060`
and uat's `25062` — so a forgotten flag would silently target the wrong fleet; the script
refuses rather than guess. `--env` sets the landlord host/port/DB **and role**, the tenant port
override, and the expected branch (§4.1) — individual `--landlord-*` / `--tenant-*` flags still
override it.

Running from inside the environment? Add `--no-tenant-override` to use `db_url` verbatim.

**Exit codes:** `0` all current · `2` pending exist · `3` a tenant needs baselining · `1` error.

Per tenant it prints one of:

| State | Meaning | Action |
|---|---|---|
| `at X — no pending migrations` | current | none |
| `at X — N pending [list]` | behind | §5.2 |
| `no flyway_schema_history — NEEDS-BASELINE` | never stamped | §6 (**do not** `--apply`) |
| `validate FAILED (checksum drift)` | an applied script was edited | §8.1 |
| `N failed row(s)` | prior migrate died mid-run | §8.2 |

### 5.2 Apply

```bash
sbdocs/9-System/scripts/apply-pending-tenant-flyway.sh \
  --env dev \
  --repo /path/to/wms2-api \
  --apply
```

`--apply` only touches tenants that **already have** a history table. Tenants needing a baseline
are always skipped — that is a deliberate human decision (§6).

Scope to one tenant while investigating:

```bash
... --warehouse nywh --status
```

By default rows with `active = false` are skipped. Include them with `--include-inactive` —
worth doing periodically so a deactivated client is not stale when it is switched back on.
On DEV expect several inactive scratch DBs to report NEEDS-BASELINE (exit `3`); that is the
normal steady state there, not a finding.

### 5.3 Verify

Re-run `--status`. Expect `all tenants at <highest>` and exit `0`.

A green history row only proves Flyway *ran*. For a seed migration, confirm the row itself:

```sql
SELECT syskey, sysvalue FROM los_sysprop WHERE syskey = '<KEY_SEEDED_BY_THE_MIGRATION>';
```

### 5.4 DEV ordering — there is no pre-deploy window

UAT is "migrate, then deploy": you control when the image rolls. **DEV is not.** A push to
`develop` builds `wms2-api:develop` and fires two Portainer webhooks (api + cron) with no human
step in between, so by the time a merge is visible the new image is already rolling. Treating
this runbook as a pre-deploy gate on DEV means it always runs late.

Use this ordering instead:

1. **Before merging**, from the *feature branch* checkout, run `--env dev --status`. This shows
   what the merge will make pending.
2. **Apply from the feature branch, before the merge**, when the pending migrations are
   additive — new views, new nullable columns, seed rows. Old code ignores a column it does not
   know about, so an additive migration is backward-compatible with the image currently running,
   and applying early closes the window entirely. The branch check fires here; that is the case
   `--allow-branch-mismatch` exists for:

   ```bash
   sbdocs/9-System/scripts/apply-pending-tenant-flyway.sh \
     --env dev --repo /path/to/wms2-api --apply --allow-branch-mismatch
   ```

3. **Merge**, let the webhook redeploy, confirm `GET /api/public/version` reports the merge SHA,
   then re-run `--status` to confirm `all tenants at <highest>`.

> **Additive only.** A migration that drops or narrows something — dropped column, tightened
> constraint, rewritten view the old code still reads — breaks the running image the moment it
> lands. Those must follow the merge, and DEV will be briefly broken between the two. Decide
> which kind you have *before* step 2; if unsure, apply after the merge and accept the window.

### 5.5 PRD path — production

Production is the UAT shape (migrate, then deploy — the prod Portainer webhook is commented
out, so nothing rolls without a human) plus three differences that matter.

**1. The target is `main`, not `release`.** `main` is reached by a *promotion merge* from
`release`, so it lags. A migration that is live on UAT is **not** pending for production until
that promotion happens. Check before assuming there is work to do:

```bash
cd <wms2-api>
git fetch origin main release --tags
git ls-tree --name-only origin/main -- src/main/resources/db/migration/   # prod's true target
git log --oneline origin/main..origin/release                             # not yet promoted
```

If `V2.2.x` appears only in the second command's range, production is **already current** and
this runbook is a no-op. Do not reach for `--allow-branch-mismatch` to "catch prod up" — that
applies a migration ahead of the code that needs it (see the callout below).

**2. `--apply` needs `--confirm-production`.** Read-only `--status` does not:

```bash
export PGPASSWORD_LANDLORD='<wms2_landlord_app password>'   # §10, from the MCP config

# always start here — read-only, safe
sbdocs/9-System/scripts/apply-pending-tenant-flyway.sh \
  --env prd --repo /tmp/wms2-api-main --status

# only after the checklist below
sbdocs/9-System/scripts/apply-pending-tenant-flyway.sh \
  --env prd --repo /tmp/wms2-api-main --apply --confirm-production
```

The flag exists because the branch guard alone is weaker on `main` than on `release`: a stale
`main` checkout is on the *right branch* at the *wrong commit*, and that under-reports the
pending set rather than over-reporting it (§8.8). The second flag forces the operator to have
actually looked. The script also refuses `--apply` to production outright when the checkout is
behind `origin/main`.

**Before passing `--confirm-production`:**

- [ ] `git fetch origin main` run, and the preflight shows no "BEHIND origin/main" warning
- [ ] preflight branch line reads `branch 'main'` with the expected `v<version>` tag
- [ ] `--status` pending list is exactly what this release is supposed to carry
- [ ] every pending migration is additive, **or** a deploy window is agreed with the business
- [ ] a snapshot/backup of `wh01_hydra_v2` exists and you know how to restore it
- [ ] the deploy of `wms2-api:<version>-prod` is ready to follow immediately

**3. One tenant means no cushion.** `nywh` → `wh01_hydra_v2` is the entire v2 production
fleet, so a failed `migrate` is a full v2 outage rather than one warehouse degrading (§2). And
six **live v1 databases** share the server — never name a database by hand here (§4.2).

> ⚠️ **Do not pull a migration forward into production ahead of its release.** The additive
> reasoning that makes §5.4's pre-merge apply safe on DEV does *not* justify it on PRD. A
> sysprop seed is harmless to the running image, but production then holds a version the
> promoted `main` has not yet blessed, and any later amendment to that same `V2.2.x` — which is
> exactly what happened to `V2.2.05` (§8.1) — lands on production as simultaneous checksum and
> description drift, on the one database with no fleet cushion. Let the promotion merge carry
> it, and land amendments as a **new** `V2.2.x`, never as an edit.

---

## 6. Baseline Path — a tenant with no `flyway_schema_history`

A DB that got its schema via the psql onboarding pipeline has the right schema but no history
table, so Flyway sees an empty database and would try to replay `V2.2.00` (the full base dump)
onto a populated schema.

> **Why this is not automated.** `V2.2.03` is a bare `ALTER TABLE ... ADD COLUMN` with **no
> `IF NOT EXISTS`**. Stamp too low and `migrate` re-runs it and fails; stamp too high and a
> migration that was never applied is silently marked done. `V2.2.01`, `V2.2.02` (`CREATE OR
> REPLACE VIEW`) and `V2.2.04`/`V2.2.05` (`INSERT ... WHERE NOT EXISTS`) are idempotent —
> `V2.2.03` is the one that makes a wrong guess expensive. Determine the watermark by
> inspection, per DB.

### 6.1 Probe the true watermark

Run against the tenant. Each row answers "is this migration's effect already present?"

```sql
SELECT 'V2.2.01', (count(*) FILTER (WHERE attname='section_name')>0
              AND count(*) FILTER (WHERE attname='ro_id')>0)::text
  FROM pg_attribute
 WHERE attrelid='public.replenishment_monitor_view'::regclass AND attnum>0 AND NOT attisdropped
UNION ALL
SELECT 'V2.2.02', (EXISTS(SELECT 1 FROM pg_views WHERE viewname='lock_overview_all_view')
              AND pg_get_viewdef('public.lock_overview_dto_view'::regclass,true) LIKE '%405%')::text
UNION ALL
SELECT 'V2.2.03', (count(*)=4)::text FROM information_schema.columns
 WHERE table_name='replenishorder' AND column_name LIKE 'moved\_%'
UNION ALL
SELECT 'V2.2.04', (count(*)=2)::text FROM los_sysprop
 WHERE syskey IN ('TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED',
                  'REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED')
UNION ALL
SELECT 'V2.2.05', (count(*)=1)::text FROM los_sysprop
 WHERE syskey = 'OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED'
UNION ALL
SELECT 'V2.2.06', (count(*)=1)::text FROM los_sysprop
 WHERE syskey = 'OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED'
UNION ALL
-- V2.2.07 (SBDEV-2777) seeds no sysprop — it replaces a function body, so unlike every
-- probe above this one inspects the body itself. BOTH clauses are required: Fix A and
-- Fix B ship in one migration but are independent edits, and a partial body is not 2.2.07.
SELECT 'V2.2.07', (pg_get_functiondef(oid) LIKE '%GROUP BY sr.itemdata, sr.client_id%'
              AND pg_get_functiondef(oid) LIKE '%MANUAL_REMOVAL'''' AND sr.type = ''''STOCK_ALTERED%')::text
  FROM pg_proc WHERE proname='stock_history' AND pronamespace='public'::regnamespace;
```

> **Why `V2.2.07`'s probe is function-body shaped, and why that is safe here.** Every other row
> above is a `los_sysprop` existence check; this migration seeds no sysprop. A body probe is
> only dangerous when combined with a *mirrored* copy of the same function in the onboarding
> chain: the mirror would make the probe read `true` while the live body was still stale, the
> operator would backfill `--up-to 2.2.07`, and `backfill-flyway-history.sh:18` inserts SUCCESS
> rows **without executing the scripts** — marked applied, body never fixed, silently.
> SBDEV-2777 deliberately ships **no onboarding mirror**, so the probe is honest: on a tenant
> whose Phase F re-ran `V1.2.05` and reverted the body, it correctly reads `false`, the
> watermark drops to `2.2.06`, and the subsequent `flyway migrate` re-applies the fix.
> **If anyone ever adds a `V2.1.x` mirror of `stock_history`, this probe must be removed.**

Also confirm the DB really is a converted v2 tenant (expect `flag-based YES`):

```sql
SELECT CASE WHEN pg_get_viewdef('public.replenishment_monitor_view'::regclass,true)
              LIKE '%useforreplenish%' THEN 'flag-based YES' ELSE 'NO — investigate' END;
```

**Watermark = the highest version whose probe is `true`, with no `false` below it.**
All `false` → watermark is `2.2.00`. A gap (e.g. `2.2.01 false`, `2.2.03 true`) is not a
clean watermark — stop and escalate.

> **Add a probe row whenever a new `V2.2.x` lands.** This table is the one part of the procedure
> that does not update itself.

### 6.2 Stamp, then migrate

```bash
PGPASSWORD_OWNER='<tenant password>' \
  <wms2-api>/src/main/resources/db/backfill-flyway-history.sh \
    --host localhost --port <25060 dev | 25062 uat | 25061 prd> \
    --dbname <tenant_db> --owner <tenant_user> \
    --up-to <watermark> --dry-run        # inspect first
```

Drop `--dry-run` to apply. Then re-run §5.1 — the tenant now reports as `pending` and §5.2 finishes it.

Notes:
- The script **refuses** if a history table already exists (use `--drop-existing` only to rebuild
  a known-bad one).
- Stamping `2.2.00` asserts the base-dump content is present without having literally run that
  file. That is the intended use for onboarded tenants.
- **Ignore the script's `--validate` verdict when anything is still pending.** It reports
  `[FATAL] checksums/scripts do not line up`, but Flyway's real message is
  `Detected resolved migration not applied to database` — a *pending* state, not drift.
  Confirm checksums separately:
  ```bash
  flyway -url=... -user=... -password=... \
    -locations=filesystem:<repo>/src/main/resources/db/migration \
    -ignoreMigrationPatterns='*:pending' validate
  ```

---

## 7. Landlord Scripts — NOT covered by this runbook

`db/landlord/L00x__*.sql` is **not Flyway-managed** and the landlord persistence unit runs
`ddl-auto=none`. Nothing applies these automatically — not the app, not §5.

They are a **deploy gate**: `L001__add_active_flag.sql` (SBDEV-2727) adds `active NOT NULL
DEFAULT true` to `tenant_discovery` and `tenant_db_configuration`. Deploying a JAR that reads
`active` against a landlord without the column loads an **empty tenant config cache and rejects
every tenant** — fail-silent-open, no crash to alert on.

**The §5 script now checks this for you.** Its preflight probes the landlord for the L001
columns and refuses to continue if either is missing, so the gate is enforced on every run
rather than remembered. The manual query below is still the way to check a landlord you are
not about to run the script against:

```sql
SELECT table_name, column_name, is_nullable, column_default
  FROM information_schema.columns
 WHERE table_name IN ('tenant_discovery','tenant_db_configuration') AND column_name='active';
```

Two rows, `NOT NULL`, default `true` → satisfied. Apply manually if absent:

```bash
# dev
psql -h localhost -p 25060 -U wms_landlord      -d dev_landlord \
  -v ON_ERROR_STOP=1 -f <wms2-api>/src/main/resources/db/landlord/L001__add_active_flag.sql
# uat
psql -h localhost -p 25062 -U wms_landlord      -d landlord \
  -v ON_ERROR_STOP=1 -f <wms2-api>/src/main/resources/db/landlord/L001__add_active_flag.sql
# prd
psql -h localhost -p 25061 -U wms2_landlord_app -d wms2_landlord \
  -v ON_ERROR_STOP=1 -f <wms2-api>/src/main/resources/db/landlord/L001__add_active_flag.sql
```

**PRD already has L001** — verified 2026-07-30: both `tenant_discovery.active` and
`tenant_db_configuration.active` are present, `NOT NULL`, default `true`. No action needed.

Idempotent (`ADD COLUMN IF NOT EXISTS`), backfills existing rows to active, safe to run early.

**Never flip `active` in only one table** — partial flips split-brain: discovery-only ⇒ new logins
404 while existing sessions keep routing; db-config-only ⇒ API blocked but the login page still
resolves. Flip both in one transaction (see the script's header for the exact statements).

> **Landlord DB names.** PRD: **`wms2_landlord`**, reached as **`wms2_landlord_app`** — a
> different DB name *and* a different role from the other two, so a copy-pasted DEV/UAT command
> fails on the role before it fails on the database.
> UAT: **`landlord`** (there is no `landlord_uat`). DEV: **`dev_landlord`**
> — *not* `landlord`, despite `application.properties:40` still saying
> `jdbc:postgresql://dev.sbo.li:25060/landlord`. That property is stale; the deployed container
> connects to `dev_landlord` (verified via `pg_stat_activity`, 2026-07-29). A DB named `landlord`
> does exist on the DEV server and is abandoned — see the §4.1 callout. Because the preflight
> above is exactly what distinguishes them, running the script *is* the check.

---

## 8. Failure Modes

### 8.1 `validate FAILED — checksum drift` / `description drift`

An already-applied migration changed. **Do not migrate.** The script names which of the two shapes it is,
because they have different causes even though the remedy is the same:

| Script says | Flyway message | Cause |
|---|---|---|
| `checksum drift` | `checksum mismatch` | the file **content** changed |
| `description drift (file renamed)` | `description mismatch` | the **filename** after the `__` changed; content may be byte-identical |

The correct fix is normally to restore the file to the committed version — **never edit an applied
migration; add the next `V2.2.x` instead.**

> ⚠️ **`flyway repair` is the wrong tool for a content change**, even though Flyway's own error suggests it.
> `repair` realigns the recorded checksum **without re-executing the migration**, so any statement you added
> silently never runs while the history claims the version is complete. It is only appropriate when the DB
> genuinely already reflects the edited file (e.g. a pure rename, or a comment-only change).
>
> ```bash
> flyway -url=... -user=... -password=... -locations=filesystem:<migration_dir> repair
> ```
>
> When you *do* need the new statements to run, drop the history row and re-migrate instead:
>
> ```sql
> DELETE FROM flyway_schema_history WHERE version = '<version>';
> ```
>
> **Only safe if every statement in that migration is idempotent** (`CREATE OR REPLACE`,
> `ADD COLUMN IF NOT EXISTS`, `INSERT … WHERE NOT EXISTS`). Read the script before doing this — `V2.2.03` is
> a bare `ADD COLUMN` and would fail on replay. Verify afterwards that the migration's *effect* is present,
> not merely that the history row came back.
>
> Worked example: `V2.2.05` was amended and renamed on 2026-07-30 while `dev_wh01_om1` was the only DB
> holding it — see [`260730-wms2-sysprop-current-value-census`](../../3-Resources/reports/260730-wms2-sysprop-current-value-census.md) §8.

The driver script refuses to migrate a tenant in either state and exits non-zero.

### 8.2 `N failed row(s) in flyway_schema_history`

A previous `migrate` died mid-run; that tenant is **partially migrated**. Inspect, fix the
underlying cause, then `flyway repair` to clear the failed row, then re-run §5.2.

```sql
SELECT installed_rank, version, script, success, installed_on
  FROM flyway_schema_history WHERE NOT success;
```

### 8.3 `migrate` fails partway across the fleet

Migrations are per-tenant and independent — already-migrated tenants are unaffected. Fix the
failing tenant and re-run; the script skips tenants already current.

### 8.4 Seed migration fails on a duplicate key

Seed migrations allocate IDs from `nextval('seqentities')`, which all entities share. On migrated
DBs the sequence can lag behind live IDs. Check before escalating:

```sql
SELECT (SELECT last_value FROM public.seqentities) AS seq,
       (SELECT max(id) FROM los_sysprop)           AS max_sysprop_id;
```

`seq > max_sysprop_id` → allocating into free space, not the cause. If the sequence is *below*
the max, it is marching through occupied ID space — escalate; do not blindly bump it.

### 8.5 Timestamps in `flyway_schema_history` look out of order

Cosmetic. Backfilled rows are stamped with DB-side `now()` (UTC); rows written by the Flyway CLI
use JVM-local time. Flyway orders by `installed_rank`, so `validate` is unaffected. Do not read
`installed_on` as a timeline on a DB that was ever backfilled.

### 8.6 `--status` reports pending migrations you did not expect

Almost always a checkout on the wrong branch: a `develop` checkout run against `--env uat`
reports every develop-only `V2.2.x` as pending for UAT. Check the preflight line — the script
warns when the branch does not match the environment, and refuses `--apply` outright (§4.4).
Fix the checkout rather than the flag.

### 8.7 `refusing to continue against a pre-L001 landlord`

Either the landlord genuinely has not had `L001__add_active_flag.sql` applied (§7 — apply it,
it is idempotent), **or** `--landlord-db` is pointing at the wrong database. On DEV the usual
cause is the second: the stale `25060/landlord` instead of `25060/dev_landlord` (§4.1). Confirm
with the `information_schema` query in §7 against both before applying anything.

On PRD a *password* failure here usually means the role, not the password: production's landlord
role is `wms2_landlord_app`, not `wms_landlord` (§4.1).

### 8.8 `checkout is BEHIND origin/<branch>` — or a suspiciously *short* pending list

The opposite of §8.6, and the more dangerous direction because the symptom is silence. A
checkout behind its upstream passes the branch check — it is on the right branch — but the
migration set on disk is missing the newest scripts, so `--status` happily reports
`all tenants at <highest>` while the fleet is genuinely behind the release being deployed.

The script warns on this and, on `--env prd --apply`, refuses outright. Fix it with
`git fetch` + `git pull` (or rebuild the worktree from `origin/main`), never by overriding.

> **Read "all current" together with the preflight's `migration set: N scripts, highest = X`
> line.** That is the only place the pending computation's *input* is visible. If `highest` is
> lower than the migration you know shipped, the green summary is meaningless — the script can
> only report on scripts it can see. This is also the check that distinguishes "production has
> nothing pending" from "production's target branch has not been promoted yet" (§5.5).

---

## 9. Post-Run Checklist

- [ ] Correct `--env` for the environment you meant
- [ ] Preflight showed no branch-mismatch warning (or the mismatch was deliberate, §5.4)
- [ ] Preflight showed no `BEHIND origin/<branch>` warning (§8.8)
- [ ] Preflight `migration set: N scripts, highest = X` matches the release you expect (§8.8)
- [ ] Preflight showed `landlord L001 'active' column present on both tables`
- [ ] `--status` reports `all tenants at <highest>`, exit `0`
- [ ] Seed migrations: the seeded row itself verified, not just the history entry (§5.3)
- [ ] **DEV** — `GET /api/public/version` reports the expected `develop-<sha>`
- [ ] **UAT** — release tag matches the image tag being deployed
- [ ] **PRD** — the full §5.5 pre-`--confirm-production` checklist was worked, not skimmed
- [ ] **PRD** — tenant count discovered is exactly `1`; if it is not, stop (§4.2)
- [ ] **PRD** — `wms2-api:<version>-prod` deployed after the migration, and verified
- [ ] Any new client DB discovered this run is recorded in the deploy notes
- [ ] If a new `V2.2.x` shipped, the §6.1 probe table has a row for it
- [ ] Bump `last_verified` in this file's frontmatter

---

## 10. Verification Notes

**2026-07-30 — PRD extension; production found already current, nothing applied.** Added the
`prd` profile, the profile-driven landlord role, the staleness check, and the
`--confirm-production` gate. Exercised read-only end to end against production.

Production state, verified directly:

- **`nywh` → `wh01_hydra_v2` is at `2.2.04`**, which is the **highest migration on `main`**
  (HEAD `d91cacf`, `git describe` → `v0.0.9`, "SiteBoss OWL v2.0.119"). `flyway validate`
  succeeded on all 5 migrations — no checksum drift, no failed rows. So **zero pending
  migrations, and nothing was applied.** Exit `0`.
- **`V2.2.05` is not production's concern yet.** It lives on `release` (`bab652c`, `v0.0.10` /
  OWL v2.0.120) and on `develop`, neither of which is merged into `main`. Its sysprop row
  `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` is correctly absent from production; the two
  `V2.2.04` rows are present with `sysvalue = false`, `groupname 'Operation Options'`.
  It reaches production with the v0.0.10 promotion merge, not before (§5.5).
- Landlord L001 present on both tables. Exactly **one** tenant row discovered, `active = true`.
- The history shows the §8.5 timestamp artifact — `2.2.00` stamped in UTC by the backfill,
  `2.2.01`–`2.2.04` in JVM-local EDT by the CLI — confirming production was onboarded via the
  psql pipeline, baselined at `2.2.00`, then migrated forward. Expected, not a finding.

Negative tests — the green above is a *true* green, not a silent zero:

- **Pending detection does fire on prd.** Re-running `--status` from a `release` worktree
  (which has `V2.2.05`) reported `1 pending [2.2.05]`, exit `2`. Against `main` it reports none.
  The difference is the migration set on disk, exactly as designed.
- `--env prd --apply` **without** `--confirm-production` → refused, exit `1`, before connecting.
- `--env prd --apply --confirm-production` from a non-`main` branch → refused by the branch
  guard, exit `1`. Both gates hold independently.
- `--env prod` (a plausible typo for `prd`) and a missing `--env` both exit `1` before doing
  anything.
- `--env dev` / `--env uat` behaviour unchanged by the profile-driven landlord role.

> **Two things about production that are not true of DEV/UAT.**
>
> 1. **Six live v1 databases share the production server** with the single v2 DB (§4.2). The v2
>    database is by far the *smallest* (30 MB against `wh01_om1`'s 10 GB). Landlord discovery is
>    the only thing keeping them out of scope.
> 2. **Production is PostgreSQL 14**, DEV and UAT are 16. Nothing in `V2.2.x` depends on a 15+
>    feature today, but a migration that did would pass UAT and fail here.

**2026-07-30 — UAT run, `2.2.04` → `2.2.05` on all four tenants.** Executed against
`release` @ `bab652c` (tag `v0.0.10`), landlord `localhost:25062/landlord`. All four active
tenants (`wh01_shipitez_v2`, `wh01_hydra_v2`, `wh02_shipitez_v2`, `wh01_om1_v2`) reported
exactly one pending migration and reached `2.2.05`; re-run with `--include-inactive`
confirmed `all tenants at 2.2.05`, exit `0`, and that UAT has **no** inactive tenant rows —
so the active-only default loses nothing here (unlike DEV, §5.2). The seeded
`OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED = false / groupname 'Operation Options'` row was
confirmed by direct query on each tenant, not just the history entry.

> **Two procedural notes from this run.**
>
> 1. **Run UAT from a throwaway worktree, not the primary checkout.** The working `wms2-api`
>    clone sits on `develop` and routinely carries uncommitted work — here, an amended
>    `V2.2.05`. `git worktree add -B release <tmp> origin/release` gives a clean, correctly-named
>    branch that satisfies the §4.4 branch check without stashing anything. Remove it and the
>    temp branch afterwards. Switching the primary checkout instead risks dragging local
>    migration edits into a UAT run.
> 2. **`PGPASSWORD_LANDLORD` comes from the MCP config**, not the environment or `~/.pgpass`.
>    The `wms_landlord` password is embedded (URL-encoded) in the `postgresql://` connection
>    string under `mcpServers` in `~/.claude.json`. The two landlord servers are:
>
>    | MCP server | Environment | Connection |
>    |---|---|---|
>    | `landlord-uat` | **UAT** | `localhost:25062/landlord` as `wms_landlord` |
>    | `landlord-dev` | **DEV** | `localhost:25060/dev_landlord` as `wms_landlord` |
>    | `landlord-prd` | **PRODUCTION** | `localhost:25061/wms2_landlord` as `wms2_landlord_app` |
>
>    ⚠️ **`landlord-dev` was renamed onto the opposite environment on 2026-07-30.** Both servers
>    were relabelled that day: the UAT entry had been called `landlord-dev` (misleading — it
>    always pointed at UAT) and became `landlord-uat`; the DEV entry was `wms1-landlord-dev` and
>    took over the freed `landlord-dev` name. So **`landlord-dev` means UAT in anything written
>    before 2026-07-30 and DEV in anything after.** When following an older doc, transcript, or
>    plan, resolve the name by its connection string — port `25062`/`landlord` is UAT,
>    `25060`/`dev_landlord` is DEV — not by the label.

> ⚠️ **Open drift hazard for the next UAT run.** As of this run, `develop` carries an
> **amended and renamed** `V2.2.05` (`__seed_outbox_sysprop_toggles.sql`, adding a second seed
> for `OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED`). UAT now holds the *release* version
> (`__seed_outbox_reject_on_error_sysprop.sql`, one row). When that amendment reaches
> `release`, all four UAT tenants will fail `validate` on **both** §8.1 shapes at once —
> checksum *and* description drift — and the second sysprop will be silently missing. Landing
> the extra seed as a new `V2.2.06` instead of amending `V2.2.05` avoids this entirely; see
> §8.1 and the `260730-wms2-sysprop-current-value-census` §8 worked example.

**2026-07-29 — DEV extension.** `--env` profiles, the L001 landlord preflight, and the
`--apply` branch-mismatch refusal added and exercised end to end:

- `--env dev --apply` took `wsl/dev_wh01_om1` from `2.2.04` → `2.2.05`; the seeded
  `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED = false` row and the history entry were both
  confirmed by direct query afterwards.
- Three inactive DEV scratch DBs (`wh02_hydra`, `wh01_hydra`, `wh01_hydra_v2`) reported
  NEEDS-BASELINE and were skipped, as designed.
- Negative tests — both **refused**, neither reached the database it was pointed at:
  `--env dev --landlord-db landlord` (the stale DEV landlord) hit the L001 guard;
  `--env uat --apply` from a `develop` checkout hit the branch guard, which would otherwise
  have pushed `V2.2.05` into all four UAT tenants ahead of the release.
- Missing and bogus `--env` both exit `1` before doing anything.
- `--env uat --status` still behaves as it did before the change (4 tenants discovered,
  L001 present).

**2026-07-27 — original UAT verification.** Verified against UAT (4 tenants: `wh01_hydra_v2`,
`wh01_om1_v2`, `wh01_shipitez_v2`, `wh02_shipitez_v2`, all reaching `2.2.04`) and against a
disposable Postgres 16 fixture that exercised every branch: pending→applied (DDL confirmed
landed), already-current, no-history→skipped, inactive-excluded, and checksum-drift→refused.

Known limits:
- The §6.1 probe table is **manual** — it needs a new row per future `V2.2.x`.
- `--apply` deliberately cannot baseline. That is a design choice (§6), not a gap.
- Script assumes one Postgres reachable host:port per environment (true today: DEV tenants all
  share `dev.sbo.li:25060`, UAT `uat.sbo.li:25060`, PRD `100.92.232.69:25060`). Split hosts
  would need per-tenant overrides.
- The L001 preflight distinguishes DEV's live landlord from the stale one *only because* the
  stale one predates L001. If `25060/landlord` ever acquires the column, that signal is lost —
  the better fix is to drop that abandoned DB.
- **`--apply` against `--env prd` has not yet been exercised on a real pending migration** —
  production had nothing pending on 2026-07-30. The apply path itself is the same code that ran
  on DEV and UAT, and both prd gates were negative-tested, but the first real production apply
  should be treated as first-run and watched. Record it here.
- The staleness check needs `origin/<branch>` present locally; it warns and degrades to the
  plain branch check if you never fetched. It compares against the *local* remote-tracking ref,
  so `git fetch` is still the operator's job.
- No `owl-v*` tag is reachable from `origin/main` (2026-07-30), so prod images cannot report
  their OWL platform release. Release-tagging gap, outside this runbook — but it means the image
  version alone does not tell you which OWL release production is running (§4.4).

---

## 11. Related

- [`apply-pending-tenant-flyway.sh`](../../9-System/scripts/apply-pending-tenant-flyway.sh) — driver
- `<wms2-api>/src/main/resources/db/migration/README.md` — migration-set rules, base-dump refresh
- `<wms2-api>/src/main/resources/db/v1-to-v2-onboarding/README.md` — onboarding watermark
- `<wms2-api>/src/main/resources/db/backfill-flyway-history.sh` — baseline tool
- [[wms2-tenant-routing-datasource-topology]] — how the landlord drives tenant routing
