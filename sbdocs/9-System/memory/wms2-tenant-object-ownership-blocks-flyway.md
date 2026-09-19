---
name: wms2-tenant-object-ownership-blocks-flyway
description: "CREATE OR REPLACE FUNCTION needs ownership, so out-of-band hotfixes owned by doadmin freeze a tenant's whole Flyway chain — silently, because tenant failures never abort boot"
metadata: 
  node_type: memory
  type: project
  originSessionId: f56e499d-ad64-4840-a17d-84d6f2f74d4e
  modified: 2026-08-05T16:15:27.556Z
---

**The tenant-side twin of the landlord `must be owner` problem.** Postgres requires you to **own** a
function to `CREATE OR REPLACE` it. On prd tenant `wh01_hydra_v2`, `public.stock_history` is owned by a
privileged role (`doadmin`/superuser — an out-of-band SBDEV-2777 hotfix), **not** the tenant app role
Flyway connects as. So `V2.2.07__fix_stock_history_client_id_aggregation.sql` fails with:

```
SQL State : 42501 — ERROR: must be owner of function stock_history
Flyway tenant hydra/nywh: migration failed — this tenant's schema may be stale [.../wh01_hydra_v2]
```

**Why it rots silently:** Flyway stops at the first failing migration, so the tenant froze at `V2.2.06`
and re-fails every deploy — but **tenant migration failures never abort boot by design**, so the app
comes up healthy and only an ERROR line in the deploy log marks it. `V2.2.08` (`CREATE OR REPLACE
FUNCTION transaction_detail`) is the same latent landmine, as is any future `CREATE OR REPLACE` on an
object a superuser touched by hand.

**This explains the open item in [[sbdev-2777-stock-history-client-id-blind]]** — V2.2.07 merged but was
"applied to NO database". For hydra prd the cause is ownership drift, not just the absence of a runbook run.

**Fix is NOT a migration edit.** V2.2.07 already applied on dev/UAT, so editing it breaks `flyway
validate` there (checksum mismatch), and a new forward `V2.2.x` cannot run while Flyway is blocked *at*
V2.2.07. The only correct fix is to normalize ownership so the **unchanged** migration applies next boot.

**Tool:** `src/main/resources/db/reassign-tenant-ownership.sh` (added by wms2-api PR #130, merged
2026-08-05 as `b5b7090`). Run once as a privileged role that is a **MEMBER** of the app role; it hands
every `public` object not already owned by the app role (tables, views, matviews, sequences, functions,
procedures, aggregates) to the app role in one transaction, skipping serial/identity sequences (they
follow their table) and extension-owned objects. Idempotent, has `--dry-run`, preflights that the admin
can actually reassign.

```bash
# --owner is the tenant's db_user_name from the landlord tenant_db_configuration row:
#   SELECT db_user_name FROM tenant_db_configuration WHERE db_url LIKE '%wh01_hydra_v2%';
PGPASSWORD_ADMIN=*** src/main/resources/db/reassign-tenant-ownership.sh \
    --host 100.92.232.69 --port 25060 --dbname wh01_hydra_v2 --admin doadmin --owner <db_user_name>
```

**MERGING PR #130 DID NOT FIX PRD.** It only ships the tool. Until an operator runs it against
`wh01_hydra_v2`, that tenant stays at V2.2.06 and V2.2.07/08/09 keep failing every deploy. As of
2026-08-05 no ClickUp ticket tracks that operator action (searched three ways) — the work is recorded
only in the PR body.

Same PR also removed a dead `@EventListener(ApplicationReadyEvent.class)` from `AdminController`: it is a
base class with **44 transitive subclasses**, and Spring registers an inherited listener once per bean,
so one `ApplicationReadyEvent` fired it 45× with a no-op body. `TokenController` has its own copy but is
standalone (nothing extends it), so it fires once and was left alone — and it does **not** extend
`AdminController`, so removing the parent method is compile-safe.

Related: [[flyway-runbook-covers-dev-and-uat-via-env-flag]],
[[sbdev-2801-runtime-flyway-default-on]] (the app runs Flyway on every boot, which is what makes this
re-fail continuously), [[hmg-is-hydra-nywh-warehouse]].

## Index-hook detail

Condensed status/landmine notes that previously lived in the `MEMORY.md` index line:

`CREATE OR REPLACE FUNCTION` needs ownership, so a doadmin-owned hotfix froze prd hydra/nywh at V2.2.06 with `42501 must be owner of function stock_history`; SILENT because tenant migration failures never abort boot; explains why SBDEV-2777's V2.2.07 reached no DB; fix is `db/reassign-tenant-ownership.sh` (PR #130, merged b5b7090) — **merging it did NOT fix prd, an operator must still run it**, and no ticket tracks that
