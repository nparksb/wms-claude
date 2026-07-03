---
title: "ShipItEZ v1 → v2 UTC Migration — Run Record (wh02/NY + wh01/LA)"
type: plan
status: in-progress
project: [wms2]
version: v2
requester: nam.park@siteboss.net
created: 2026-06-28
updated: 2026-06-28
db_verified: true
related:
  - ../../../2-Areas/wms-utc-timezone-migration/README.md
  - ./260523-UTC-TIMEZONE-MIGRATION.md
  - ./260527-hydra-v1-to-v2-migration-runbook.md
  - ./260606-wineco-v1-to-v2-migration-runbook.md
tags: [plan, wms2, utc, migration, run-record, shipitez]
---

# ShipItEZ v1 → v2 UTC Migration — Run Record (wh02/NY + wh01/LA)

> **This is a per-client run record, not the procedure.** The canonical, client-agnostic procedure —
> phases, gates, scripts, rollback matrix, and validated facts — lives in the SOP:
> [**2-Areas/wms-utc-timezone-migration/README.md**](../../../2-Areas/wms-utc-timezone-migration/README.md).
> This document holds **ShipItEZ's** specifics and (as it progresses) the results of each execution
> against that SOP. As of 2026-06-28 **nothing has been executed** — only a read-only readiness check
> (§3). The NY and LA conversion math is already proven by the Hydra (NY) and WineCo (LA) runs (SOP §5);
> these runs inherit that, they do not re-prove it.

**Client:** ShipItEZ — **two warehouses, two databases, two separate runs**, each its own uniform source
write-TZ. Per the SOP, one run per warehouse DB; this single record tracks both tracks:

| Track | Warehouse | MCP / env | DB | Source write-TZ | SQL variant |
|---|---|---|---|---|---|
| **A** | **NY** | `nywh-shipitez-uat` · `nywh` | `wh02_shipitez_v2` | `America/New_York` *(PREP-1 ✓)* | `_America_New_York` |
| **B** | **LA** | `c1wh-shipitez-uat` · `c1wh` | `wh01_shipitez_v2` | `America/Los_Angeles` *(PREP-1 ✓)* | `db/migration` originals |

> ⚠️ Note the inverted numbering: **NY is `wh02`, LA is `wh01`**. Do not pair facility ↔ DB number by
> intuition — pin each by name. The two DBs are independent; neither holds the other's TZ data.

---

## 1. Client facts

1. **Two source write-TZs, one per DB.** Track A (NY) `System Time Zone` = `America/New_York`; Track B (LA)
   `System Time Zone` = `America/Los_Angeles` (§3). `CLIENT_HIBERNATE_TZ` selects the variant — the **only**
   knob — so the two tracks use the same toolkit with two different `migration.env` files. A wrong TZ
   silently shifts every timestamp (NY ~5 h, LA ~7–8 h) with no error → PREP-1 is the hard gate per track.
   **PREP-1 closed 2026-06-28** against the deployed v1 properties: `hibernate.jdbc.time_zone` =
   `America/New_York` in `application-shipitez_wh2.properties` (NY) and `America/Los_Angeles` in
   `application-shipitez_wh1.properties` (LA) — both env files match (§3). (The `user.timezone=LA` line in
   both is the JVM default, not the write path — ignore it.)
2. **Both DBs are clean pre-bridge v1 snapshots.** Each has 0 timestamptz cols (91 `wtz`), 11 v1 reporting
   views, and **none** of `outbox_message` / `rest_idempotency` / `customerorder_cancellation_log` /
   `flyway_schema_history` / `API_TIMESTAMP_FORMAT`. Correct starting state — bridge + UTC not yet run.
3. **Re-id'd V2.1.08/09 no-op/insert cleanly on both** — syskey ids 140–143 are **free** in both DBs (§3),
   so the bridge inserts the stale-club/pick-path syskeys with no PK collision; no v1-compat branch.
4. **seqentities differs by warehouse** — NY is a clean single island; **LA is a dual/multi-island id space
   that needs verification** (§3.1). This is orthogonal to the UTC conversion (which never touches ids) but
   is a real LA-cutover data-health item.

---

## 2. `migration.env` files (validated 2026-06-28)

Two per-track env files exist (gitignored, alongside `migration.env.hydra` / `migration.env.wineco`); copy
the relevant one to `migration.env` before each run:
- **NY:** `db/onboarding-tz-variants/scripts/migration.env.shipitez-ny`
- **LA:** `db/onboarding-tz-variants/scripts/migration.env.shipitez-la`

Validated field-by-field against the live DBs, the deployed v1 properties, and the onboarding doc
(`docs/dev-docs/spk/spk/migration/onboarding-shipitez.txt`):

| Field | Track A — NY | Track B — LA | Verified against |
|---|---|---|---|
| `TENANT_DB_NAME` | `wh02_shipitez_v2` | `wh01_shipitez_v2` | `current_database()` ✓ |
| `TENANT_DB_USER` | `wh05_om1` | `wh04_om1` | MCP role + onboarding doc ✓ (DB owner = `postgres` → see ownership note) |
| `CLIENT_HIBERNATE_TZ` | `America/New_York` | `America/Los_Angeles` | deployed `hibernate.jdbc.time_zone` ✓ (PREP-1 closed) |
| `TENANT_DISCOVERY_TZ` | `America/New_York` | `America/Los_Angeles` | warehouse location (NY / Santa Rosa CA) ✓ |
| `CLIENT_FACILITY_CODE` | `nywh` | `c1wh` | onboarding doc (NYWH / C1WH) ✓ |
| `TENANT_DISCOVERY_KEY` | `nywh-shipitez` | `c1wh-shipitez` | ✓ |
| `OMS_BASE_HOST` | `api-oms.uat.sbo.li` | `api-oms.uat.sbo.li` | onboarding doc WEBS* rewrite ✓ |
| `TENANT_DB_PORT` / landlord | `25062` / `landlord` | `25062` / `landlord` | (verify tunnel local port matches before run) |

> The earlier `migration.env.shipitez-ny` had copy-paste errors (pointed at `wh01`, LA TZ, `shiptiez`
> typos) — **corrected 2026-06-28**; both files now pass every check.

**Recovery point (decision 2026-06-28): backups are remote on the DB host (DBA-managed).** Both env files
set `RUNTIME_BACKUP=false` with a local `EXTERNAL_BACKUP_DUMP` path that **does not exist on this box**
(`…/shipitez/backups/{wh02_shipitez.dump, wh01_om1.dump}`). Consequence per SOP §6: `00-restore.sh` cannot
resolve a local dump, so the deterministic in-toolkit rewind is **unavailable** as configured — recovery
falls to the **DBA's host backup/procedure**. Before Phase F, pick one:
> 1. **scp the host dump local** to the `EXTERNAL_BACKUP_DUMP` path (and fix the LA name — it still reads
>    `wh01_om1.dump`, which collides with WineCo's dump) so `00-restore.sh` works deterministically; **or**
> 2. **set `RUNTIME_BACKUP=true`** — `02-backup.sh` takes + verifies its own local `pg_dump -Fc` at Phase A
>    (DBs are small: NY 201 MB, LA 1.87 GB), making `00-restore.sh` self-contained; **or**
> 3. accept **DBA-procedure recovery** and treat `00-restore.sh` as N/A (still requires a confirmed,
>    tested recovery point before Phase F — SOP §6).

> **Ownership (re-checked 2026-06-28 — NOT the WineCo blocker):** every `public` object on both DBs is
> **already owned by the app role** (NY 50 tables/11 views/1 seq/3 fns = `wh05_om1`; LA = `wh04_om1`, 4 fns),
> and both app roles already have `CREATE` on `public` (`has_schema_privilege` = YES). The bridge is **not**
> blocked. The only object still on `postgres` is the **database** itself; aligning that to the app role is
> hygiene, run as `postgres` via `data/migration/shipitez/change-db-owner.sql` (verify with
> `verify-owner.sql`). Also confirm the tunnel local port matches `TENANT_DB_PORT=25062`; landlord
> coordinates for PREP-9.

---

## 3. Readiness check (live, read-only MCP, 2026-06-28)

> Pre-flight **readiness probe via MCP `execute_sql`** (read-only), not a run of `01-preflight.sh`. The real
> Phase A must still run `01-preflight.sh` per track (it also does the **deployed-properties** PREP-1
> cross-check, **DB-host disk** PREP-6, and writes `baseline_rowcounts.csv`).

| Check | Track A — NY (`wh02_shipitez_v2`) | Track B — LA (`wh01_shipitez_v2`) |
|---|---|---|
| **PREP-1** deployed TZ (HARD GATE) | ✅ **confirmed NY** — `application-shipitez_wh2.properties` `hibernate.jdbc.time_zone=America/New_York` | ✅ **confirmed LA** — `application-shipitez_wh1.properties` `hibernate.jdbc.time_zone=America/Los_Angeles` |
| **PREP-2** `System Time Zone` sysprop | ✅ `America/New_York` | ✅ `America/Los_Angeles` |
| **PREP-3** syskey ids 140–143 | ✅ free (0 rows) | ✅ free (0 rows) |
| **PREP-4** order backlog | ✅ no early-state backlog | ✅ no wraparound/constraint issues; toolkit `04` Step A is authoritative |
| **PREP-6** disk ≥ DB size (HARD GATE) | ⏳ verify on host (DB 201 MB — trivial) | ⏳ verify on host (DB 1,872 MB — still small) |
| **PREP-10** flyway history | absent (benign) | absent (benign) |
| **Migration state** | pre-bridge v1 (0 tz / 91 wtz, no bridge tables/syskey) | pre-bridge v1 (0 tz / 91 wtz, no bridge tables/syskey) |
| **Views** | 11 v1 reporting views | 11 v1 reporting views |
| **DB health** | vacuum OK · constraints OK | vacuum OK · constraints OK |
| **seqentities** | ✅ `last_value` 852,676 > max id 760,277 — clean single island | ⚠️ `last_value` **5,381,225** ≪ max stockrecord id **119,945,117** — multi-island (see §3.1) |
| **Baseline row-counts** (Phase F compares) | stockrecord 28,196 · unitload_record 9,952 · inventory_record 756,769 · pickingorder_position 2,515 | stockrecord 1,319,296 · unitload_record 740,375 · inventory_record 3,001,706 · pickingorder_position 220,843 |
| **DB size** | 201 MB | 1,872 MB |

**Verdict (both tracks): UTC-migration DB-side gates GREEN; PREP-1 CLOSED.** Nothing blocks the timezone
conversion on either DB. Remaining per track: the recovery-point decision (§2), the ownership pre-fix
(owner = `postgres`), the human PREP-9..14 sign-offs, and — **LA only** — the seqentities review in §3.1
(likely inherited Hydra seed data, not a UTC blocker).

### 3.1 LA (Track B) seqentities multi-island finding

`seqentities.last_value` = **5,381,225**, but `stockrecord` ids span far higher. Distribution of
`stockrecord` (count 1,319,296):

| Band | Rows |
|---|---|
| id ≤ 5,381,225 (at/below the sequence high-water) | 444,450 |
| 5,381,225 < id < 100,000,000 | **739,603** |
| id ≥ 100,000,000 (min 100,000,750) | 135,243 |
| id in 5,381,226 … 5,400,000 (immediately above the sequence) | **0** |

So **874,846 stockrecord rows already sit above the sequence high-water**, yet the ~19k slots *immediately*
above it are free. Read per [[wms2-seqentities-dual-island-id-space]]: the immediate next allocations are
safe, but if `seqentities` feeds `stockrecord.id`, the counter will eventually march into the occupied
5.38M–120M territory and collide. **This is a pre-existing v1 data condition, independent of the UTC
migration** (which never touches ids). Before the LA cutover: confirm which entities draw from `seqentities`
and whether `last_value` should be advanced past the high foreign block (or whether stockrecord ids are
externally assigned and never collide). Do **not** treat it as a UTC-migration blocker; do log it as an
LA-cutover go/no-go item.

> **Likely origin (onboarding doc).** `docs/dev-docs/spk/spk/migration/onboarding-shipitez.txt` seeds the
> LA UAT DB via `pg_dump … -d wh02_hydra | psql … -d wh01_shipitez` — i.e. **`wh01_shipitez_v2` (LA UAT) was
> loaded from Hydra's `wh02_hydra`**, so this id distribution is almost certainly **inherited Hydra test
> data**, not a genuine ShipItEZ-LA condition. A production LA cutover would run against real ShipItEZ data
> with its own (probably cleaner) id space — re-check seqentities on the real prod DB, don't carry this
> UAT finding forward.

---

## 4. Execution

### 4.1 Track B (LA, `wh01_shipitez_v2`) — Phases A–C done 2026-06-28 (UAT)

| Step | Result |
|---|---|
| A `01-preflight` | ✅ ALL PASS — PREP-1 deployed==config `America/Los_Angeles` (data x-check advice `10:23:32` LA → `17:23:32+00` UTC, +7h PDT), PREP-2 LA, PREP-3 ids 140–143 free, PREP-4 0 stuck, PREP-6 1.96 GB vs 373 GB free, landlord OK, flyway absent; baseline stockrecord 1,319,296 · unitload_record 740,375 · inventory_record 3,001,706 · pickingorder_position 220,843 |
| A `02-backup` | ✅ `RUNTIME_BACKUP` flipped `false→true` (no remote dump staged locally); `shipitez_pre_utc_20260628_1900.dump` (256 MB), `pg_restore --list` verified. Rewind = `./00-restore.sh 20260628_1900`. (Created `backups/` dir + `backup_stamp` first — toolkit needs both.) |
| A `03-gen-scripts` | ✅ LA originals selected (V1.2.01/02/99 `db/migration`+`db/rollback`); OMS host → `api-oms.uat.sbo.li` in V2.1.02 (ids 144/145) + V2.1.13 reversal |
| C `04-schema-bridge` | ✅ V2.1.01→**V2.1.16** applied in order (~35 s incl. Step A 0 stuck); no ownership errors (objects already `wh04_om1`-owned, has CREATE on public) |
| C `05-verify-bridge` | ✅ **ALL 10 PASS** — 3 tables, 6 syskeys, `API_TIMESTAMP_FORMAT` seeded, cancellation fn + timestamptz, 0 stuck, valid V2.1.14 index, `transaction_detail` fix, `replenishment_monitor_view` flag-based (V2.1.16), reversal URL = `api-oms.uat.sbo.li` |
| E `06-drain` | ✅ outbox 0 immediately; `rest_idempotency` empty → `rest_idempotency_predrain` snapshot (app confirmed quiesced by operator) |
| F `07-utc-migrate` | ⚠️→✅ V1.2.01–04 committed (tables + 11 views → timestamptz); **V1.2.05 aborted** on the client-custom function `stock_history2` (see deviation below), rolled back atomically. Recovered: dropped `stock_history2` (0 dependents), re-ran V1.2.05 → 3 standard fns recreated `timestamptz`, sanity PASS, COMMIT |
| F `08-verify-utc` | ✅ **ALL PASS** — large tables timestamptz, fn signatures timestamptz, 11 views, `sku_id`/`order_loaded_to_truck`/`on_replenishable_location`, flag-based view, outbox index, **row counts == baseline**, ANALYZE; spot-check advice `10:23:32` LA → `17:23:32+00` UTC reads back LA = original wall-clock |

> **⚠️ Deviation / toolkit gap — `stock_history2` (logged 2026-06-28).** `V1.2.05` recreates a **hard-coded
> list of 3 standard functions** (`stock_history`, `transaction_detail`, `transaction_summary`) and then a
> **global** `DO`-block that aborts if *any* `public` function parameter is still `timestamp without time
> zone`. This LA UAT DB carried a 4th, client-custom SQL function **`stock_history2`** (a `stock_history`
> variant; almost certainly inherited from the `wh02_hydra` seed) whose `as_of_date timestamp` param the
> hard-coded list never converts → Phase F aborts. **Resolved here by dropping `stock_history2`** (verified
> 0 view/function dependents; operator confirmed it droppable). **For the real LA production cutover:** the
> prod DB may also carry custom functions — before Phase F, enumerate `public` functions and either extend
> `V1.2.05` (convert dynamically / add a client addendum) or drop/convert the extras. NY (Track A) has only
> the 3 standard functions, so it is unaffected. **Toolkit improvement candidate:** `01-preflight` should
> flag non-standard `public` functions, or `V1.2.05` should convert all of them rather than a fixed list.

**Track B (LA) Phases A–F COMPLETE (UAT), 2026-06-28.** DB fully UTC-converted + bridged to V2.1.16,
row-count-verified. Rewind point: `./00-restore.sh 20260628_1900`. **Remaining (human):** Phase G deploy-2
UTC image + scale up · Phase H `09-smoke` (needs app connected to exercise per-tenant `connectionInitSql`
session-TZ; raw psql shows `UTC` — the WineCo §4.4 expected artifact) + go/no-go · Phase I frontends ·
Phase J flag flip `API_TIMESTAMP_FORMAT`→`ISO8601_UTC` (≥1 stable day) · Phase K cleanup (drop
`rest_idempotency_predrain`).

### 4.2 Track A (NY, `wh02_shipitez_v2`) — Phases A–F done 2026-06-28 (UAT)

Ran with an **isolated WORK_DIR** (`shipitez-nywh-utc-migration`) so the shared `CLIENT_NAME=shipitez`
state didn't clobber LA's; `RUNTIME_BACKUP` flipped `true`; fresh stamp `20260628_1917` (distinct from LA's
`1900` so dumps don't collide in the shared `BACKUP_DIR`).

| Step | Result |
|---|---|
| A `01-preflight` | ✅ ALL PASS — PREP-1 deployed==config `America/New_York` (x-check advice `11:02:49` NY → `16:02:49+00` UTC, +5h EST), PREP-2 NY, PREP-3 ids 140–143 free, PREP-4 0 stuck, PREP-6 210 MB vs 373 GB, landlord OK; baseline stockrecord 28,196 · unitload_record 9,952 · inventory_record 756,769 · pickingorder_position 2,515 |
| A `02-backup` | ✅ `shipitez_pre_utc_20260628_1917.dump` (39 MB), `pg_restore --list` verified. Rewind = `./00-restore.sh 20260628_1917`. LA's `…_1900.dump` left intact alongside |
| A `03-gen-scripts` | ✅ **`_America_New_York`** variants (V1.2.01/02/99); OMS → `api-oms.uat.sbo.li` (ids 144/145 + reversal) |
| C `04`/`05` | ✅ V2.1.01→V2.1.16 (~3 s); `05-verify-bridge` **ALL 10 PASS**, reversal URL = `api-oms.uat.sbo.li` |
| pre-F function check | ✅ exactly the **3 standard functions** (no `stock_history2` / custom fns) → no V1.2.05 surprise |
| E `06-drain` | ✅ outbox 0; `rest_idempotency` empty → `rest_idempotency_predrain` snapshot (app quiesced by operator) |
| F `07-utc-migrate` | ✅ V1.2.01–05 clean (~13 s); V1.2.05 committed first try |
| F `08-verify-utc` | ✅ **ALL PASS** — timestamptz tables/fns, 11 views, flag-based view, outbox index, **row counts == baseline**, ANALYZE; advice `11:02:49` NY → `16:02:49+00` UTC reads back NY = original |
| independent MCP x-check | ✅ 100 timestamptz cols (only 2 naive = empty `rest_idempotency_predrain`, dropped Phase K), 11 views, 3 fns, `API_TIMESTAMP_FORMAT=LEGACY`, row counts == baseline, `stockrecord.modified` timestamptz |

**Track A (NY) Phases A–F COMPLETE (UAT), 2026-06-28.** Rewind: `./00-restore.sh 20260628_1917`. Remaining
human phases G–K identical to Track B.

---

## 4.3 Planned phase flow (per SOP §3)

Same flow for both tracks (NY uses `_America_New_York` variants; LA uses the `db/migration` originals):

| Phase | Owner | Step |
|---|---|---|
| A | 🤖 | `01-preflight` (PREP-1 vs deployed props + PREP-6 on host + baseline) → `02-backup` → `03-gen-scripts` (correct TZ variant; OMS → host) |
| B | 👤 | PREP-9 landlord `tenant_discovery.timezone` (NY: `America/New_York`, LA: `America/Los_Angeles`) · PREP-11 PgBouncer `pool_mode=session` · PREP-12 OMS ISO-8601 · PREP-13 rollback RTO · PREP-14 go/no-go owner |
| C | 🤖 | `04-schema-bridge` V2.1.01→**V2.1.16** → `05-verify-bridge` (expect ALL 10 PASS) |
| D | 👤 | Deploy 1 — stabilize wms2-api image (behavior-preserving) |
| E | 👤+🤖 | maintenance mode + quiesce writes + scale app to 0 (`06-drain`) |
| F | 🤖 | `07-utc-migrate` V1.2.01→05 → `08-verify-utc` (timestamptz / 11 views / fn sigs / row counts == baseline) |
| G | 👤 | Deploy 2 — UTC app image + scale up |
| H | 🤝 | `09-smoke` (session TZ via `connectionInitSql` == `System Time Zone`; `API_TIMESTAMP_FORMAT` still `LEGACY`) + go/no-go |
| I | 👤 | Deploy 3 — web + mobile frontends |
| J | 🤝 | flip `API_TIMESTAMP_FORMAT` → `ISO8601_UTC` (≥1 stable operational day after frontends are on the new build) |
| K | 🤝 | cleanup — drop `rest_idempotency_predrain`, `TRUNCATE flyway_schema_history` (absent here), landlord pre-migration rows |

**Forward RTO estimates (Phase F, SOP §7 rule of thumb ≈ 0.3–0.4 s / 100k large-table rows — UAT, not a
production budget):**
- **Track A — NY:** ~797k large-table rows → `V1.2.02` ≈ **2–3 s**, full `07` a few seconds.
- **Track B — LA:** ~5.28M large-table rows (stockrecord 1.32M + unitload_record 740k + inventory_record
  3.00M + pickingorder_position 221k) → `V1.2.02` ≈ **16–21 s**, full `07` ~half a minute.
- **Re-measure on a production-sized restore** before each production cutover (B3); window budget = `total − forward_time`.

---

## 5. Open items for ShipItEZ

- ✅ **PREP-1 (hard gate) — CLOSED 2026-06-28** for both tracks against the deployed v1 properties
  (`hibernate.jdbc.time_zone` = NY `America/New_York`, LA `America/Los_Angeles`); both env files match.
  `01-preflight` will re-assert it at Phase A.
- ✅ **Env files — DONE.** `migration.env.shipitez-ny` / `-la` exist, gitignored, validated field-by-field
  (§2). The stale WineCo copy is superseded.
- **Recovery point (§2): backups are remote (DBA/host).** `00-restore.sh` is unavailable as configured —
  before Phase F, either scp the host dump local (and fix the LA `wh01_om1.dump` name collision) **or** set
  `RUNTIME_BACKUP=true`, **or** accept DBA-procedure recovery with a tested point. **Action required.**
- **Ownership — NOT a blocker (re-checked 2026-06-28):** all `public` objects already owned by the app
  roles + both have `CREATE` on `public`. Only the **database** object is `postgres`-owned; optional
  alignment script at `data/migration/shipitez/change-db-owner.sql` (run as `postgres`).
- **LA seqentities review (§3.1):** likely inherited Hydra UAT seed data — re-check on the real prod DB;
  not a UTC blocker.
- **PREP-9 landlord `tenant_discovery.timezone`** per warehouse (NY / LA). OMS host already `api-oms.uat.sbo.li`.
- **PREP-6 on each DB host:** the MCP probe can't see host disk — measure on the real host (both DBs are
  small, but measure).
- **B3 production RTO:** re-measure `V1.2.02` per track on a production-sized restore.
- **Sequencing the two runs:** they are independent DBs — run serially (NY then LA, or vice-versa) to keep
  one maintenance window and one go/no-go in focus at a time; nothing forces them to be simultaneous.
- **Human phases B / D / G / I / J / K** per track.

---

## 6. Artifacts

- Readiness probe: live MCP `nywh-shipitez-uat` + `c1wh-shipitez-uat` (read-only `execute_sql`),
  2026-06-28 — captured in §3 / §3.1.
- To be produced at Phase A (per track): `$WORK_DIR/{migration.log, preflight-report.txt,
  baseline_rowcounts.csv}`, backup under `$BACKUP_DIR/`.
- Toolkit + SQL (source of truth): `v2/wms2-api/src/main/resources/db/onboarding-tz-variants/scripts/`
  (`_lib.sh`, `00`–`09`, `99`, `migration.env.example`) + `db/migration/` + `db/rollback/` +
  `db/onboarding-tz-variants/` NY variants.
