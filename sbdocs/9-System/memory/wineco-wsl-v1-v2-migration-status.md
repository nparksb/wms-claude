---
name: wineco-wsl-v1-v2-migration-status
description: "WineCo (wsl, LA-source) v1→v2 UTC migration — MULTI-COPY: dev @10.0.0.4 (tunnel 25060) + uat @10.0.0.6 (tunnel 25062 / wsl-wineco-uat MCP) both now Phase C+F DONE (uat 2026-07-20, 08-verify ALL PASS). Remaining = human G–K (deploy UTC image, scale app back up, Phase J flag, cleanup). 2 Phase-F landmines: app-not-really-scaled-to-0 deadlock; V2.2.x view deltas must be post-F."
metadata: 
  node_type: memory
  type: project
  originSessionId: b1a874d2-faf1-493a-91e4-8d1e02a8f8e5
  modified: 2026-07-21T01:35:24.426Z
---

WineCo warehouse **`wsl`** v1→v2 UTC migration. **DB cutover complete:** A→C→F run for real 2026-06-06
on `wh01_om1_v2` (ownership blocker cleared same day — `postgres` password was obtained; the scoped
`ALTER … OWNER TO wh01_om1` DO-block fixed it). Re-rehearsed clean end-to-end on a fresh reload 2026-06-08.
**Detailed record (source of truth):** `sbdocs/1-Projects/wms2/plan/260606-wineco-v1-to-v2-migration-runbook.md` (§4.7 = the 2026-07-20 uat run).

**⚠️ 2026-07-20 CORRECTION — there are THREE copies of `wh01_om1_v2`, all reporting `10.0.0.6` via `inet_server_addr`:**
- **dev** `@10.0.0.4` — tunnel `localhost:25060` (`-L 25060:dev.sbo.li:25060`). **Migrated** (timestamptz). This is what the earlier A→C→F "real run" (§4.1–4.4) actually hit.
- **uat** `@10.0.0.6` — tunnel `localhost:25062` (`-L 25062:uat.sbo.li:25060`) **and the `wsl-wineco-uat` MCP** (connects as `wh01_om1`, owns the DB). As of 2026-07-20 this copy was **NOT migrated**: large-table cols were `timestamp without time zone`, and bridge tables `rest_idempotency`/`outbox_message`/`customerorder_cancellation_log` were MISSING. Only a few views/sysprops had been hotfixed on top of clean v1.
- dev2 `@10.0.0.16` — the 06-11 hotfix target.
The 2026-06-28 "uat DONE, all core cols timestamptz, role=`wh03_om1`" claims in item 1 below were about a **different copy** (the hydra-cluster `wh01_om1_v2`, which also reports `10.0.0.6`), NOT this `wsl-wineco-uat`/25062 DB. Verify `current_database()` + `stockrecord.created` type per connection — do not assume any copy's state from another.

**2026-07-20 uat `@10.0.0.6` work done (this session):** privilege fix run as `postgres` (`GRANT USAGE, CREATE ON SCHEMA public TO wh01_om1` + reassigned 2 `postgres`-owned tables → `wh01_om1` now owns DB + all objects, USAGE/CREATE on public). `01-preflight` ALL HARD GATES PASS (fresh baseline ≈28.3 M large-table rows). `04-schema-bridge` applied V2.1.01→**15** clean; **V2.1.16 aborted** `cannot drop columns from view` (hotfix view already had `ro_id` appended) → resolved by atomic `DROP VIEW` + `db/migration/V2.2.01` (supersedes V2.1.16) + `V2.2.02`. `05-verify-bridge` ALL PASS. **Phase E/F DONE on uat `@10.0.0.6` 2026-07-20** — `06-drain`→`07`→`08-verify-utc` ALL PASS, row counts == baseline (stockrecord 7,359,847 / unitload_record 6,322,285 / inventory_record 13,710,775 / pickingorder_position 923,296), conversion math correct (advice 12:36 LA → 19:36+00). Post-F re-applied V2.2.01 (replen section_name+ro_id) + V2.2.02 (lock views). Backup `wineco_pre_utc_20260720_2018.dump` (1.3 GB); `EXTERNAL_BACKUP_DUMP` re-pointed to it. **Remaining = human phases G–K** (deploy UTC image + scale app back up — it's still at 0 — smoke/go-no-go, frontends, Phase J flag, drop `rest_idempotency_predrain`).

**Two Phase-F LANDMINES hit + fixed (both worth remembering):**
1. **"App scaled to 0" wasn't** — wms2-api at `10.0.0.2` kept a live JDBC pool; a Hibernate `unitload` SELECT deadlocked V1.2.01's ALTER. Killing sessions is futile (pool refills in ~3 s); must stop the app PROCESS. Gate the retry on a **sustained** zero-session `pg_stat_activity` read (~45 s), not a post-kill blip. V1.2.01 is transactional → rolled back clean.
2. **`V2.2.x` VIEW deltas must be applied AFTER Phase F, not in Phase C.** Applying V2.2.02 in Phase C created `lock_overview_all_view`, which is outside V1.2.01's frozen 11-view drop-list → `cannot alter type … depends on column "created"`. Fix: `DROP VIEW lock_overview_all_view CASCADE` before F, re-apply V2.2.01/02 after F. (Correct order: bridge → F → V2.2.x views. Non-view V2.2.x are fine in Phase C.)

**Connections (non-obvious):** app role `wh01_om1` (pw `wh01Om1@sb`); tunnel port varies by session
(Jun-6 used `25062`, Jun-8 `25060` — verify against `migration.env` before running anything).
MCPs: `wms2-wineco-dev2` → `wh01_om1_v2` (the converted DB); `wms2-wineco-dev` → `dev_wh01_om1`.
First MCP query after idle drops — retry once ([[wms-mcp-first-query-after-idle-drops]]).

**Post-cutover defects found & fixed (both were stale view bodies in `V1.2.04`):**
1. 2026-06-08 — `order_detail_monitor_view` lost `sku_id` (SBDEV-1637); patched scripts + hotfixed live DBs.
2. 2026-06-11 — `replenishment_monitor_view` reverted to the area-name list (SBDEV-2384); fixed via
   wms2-api `143fa65` (new `V2.1.16`, bridge watermark now V2.1.01–V2.1.16, pushed). Hotfix applied to
   `wh01_om1_v2` (dev2 copy) + `dev_wh01_om1`; **uat copy @10.0.0.6 still pending** (unreachable via MCP).

**Remaining for WineCo:**
1. ~~Apply `V2.1.16` to `wh01_om1_v2` on uat @10.0.0.6.~~ **DONE — verified 2026-06-28** via `wms2-wineco-uat`/`wsl-wineco-uat` MCPs (both = same DB @10.0.0.6): `replenishment_monitor_view` is now flag-based (`useforreplenish = true`, no `'Storage and Picking'` name list); `order_detail_monitor_view.sku_id` present; all core cols `timestamptz` (only `customerorder.pickingdate` is `date`, by design); `rest_idempotency_predrain` still present (Phase K cleanup pending). **Role/privilege issue found + RESOLVED 2026-06-28:** the UAT app role on @10.0.0.6 is `wh03_om1` (Hydra's role, also now the DB owner), but all 71 public objects were owned by `wh01_om1` so `wh03_om1` had ZERO table privileges (`permission denied for table customerorder`). Ownership reassignment to wh03 was abandoned (needs a real `-U postgres` superuser session — neither wh01 nor wh03 is a member of the other; `postgres` IS rolsuper but the operator's psql kept connecting as a non-super role, so the object ALTERs silently rolled back while only `ALTER DATABASE OWNER` stuck). **Fix that worked: owner-issued GRANTs run via the `wms2-wineco-uat` MCP (connects as wh01_om1, owns everything — no superuser needed):** GRANT SELECT/INSERT/UPDATE/DELETE on all tables+views, USAGE/SELECT/UPDATE on sequences, EXECUTE on functions, + `ALTER DEFAULT PRIVILEGES FOR ROLE wh01_om1`. Verified 57/57 tables, 11/11 views, 3/3 seqs. ⚠️ Default-priv grant is scoped to objects created BY wh01_om1 — future V2.1.x psql migrations must be applied as wh01_om1 or re-run the GRANT block. Object-ownership script kept at `/home/nampark/data/migration/tmp/wineco-utc-migration/fix-ownership-uat-wh03.sql` (requires genuine `-U postgres`). `flyway_schema_history` absent is expected (wms2-api is psql-only, no runtime Flyway).
2. App-path session-TZ check once wms2 reconnects (`SHOW timezone` = `America/Los_Angeles` via app conn —
   the raw-psql `UTC` reading is a known artifact, not a defect).
3. **Phase J flag:** SOP says flip `API_TIMESTAMP_FORMAT` → `ISO8601_UTC` only after both frontends ship
   the dual-format parser. ⚠️ 2026-06-11 audit found the dev2 copy ALREADY flipped to `ISO8601_UTC`
   (seeded+flipped after 06-06, by whom/why unrecorded) — confirm intentional or revert to `LEGACY`.
4. Human phases D/G–K (deploys, scale-up, cleanup incl. dropping `rest_idempotency_predrain`).

**Rollback assets:** `99-rollback.sh` (LA V1.2.99 variant, now flag-based per SBDEV-2384) or
`00-restore.sh`; recovery dump resolves via `EXTERNAL_BACKUP_DUMP` (`wh01_om1.dump`, Jun-8) per the
`fe65e97` resolver. RTO reference: forward `07` ≈ 5 min on ~26–28 M large-table rows (~0.3–0.4 s/100k rows).
