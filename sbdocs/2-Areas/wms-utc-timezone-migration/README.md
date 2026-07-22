---
title: "WMS v1 → v2 UTC Timezone Migration — Operational SOP"
type: runbook
status: active
version: "v2/wms2-api (Java 21, Spring Boot 3.5.9, PostgreSQL 16)"
scope: "Per-client v1→v2 schema bridge + UTC timestamptz migration (any source write-TZ)"
owner: "nam.park@siteboss.net"
created: 2026-06-05
updated: 2026-07-16
last_verified: 2026-06-05
verified_by: "Hydra wh01 dev rehearsal (A→C→F end-to-end on PostgreSQL 16.10)"
related:
  - ../../1-Projects/wms2/plan/260527-hydra-v1-to-v2-migration-runbook.md
  - ../../1-Projects/wms2/plan/260523-UTC-TIMEZONE-MIGRATION.md
tags: [runbook, sop, utc, migration, wms2]
---

# WMS v1 → v2 UTC Timezone Migration — Operational SOP

Canonical, **client-agnostic** procedure for bringing a WMS client's PostgreSQL database from the
legacy v1 layout onto the wms2 schema watermark **and** converting all `timestamp without time zone`
columns to UTC `timestamptz`. One run per **warehouse database** (each warehouse is its own DB with a
single uniform write-TZ).

This SOP is the reusable source of truth. Each actual execution is captured in a **run record** (see
§8). The first run record — and the proof-of-procedure — is Hydra:
[260527-hydra-v1-to-v2-migration-runbook.md](../../1-Projects/wms2/plan/260527-hydra-v1-to-v2-migration-runbook.md).

> **Source of truth for the executable artifacts** is the repo, not this doc:
> `v2/wms2-api/src/main/resources/db/v1-to-v2-onboarding/onboarding-tz-variants/scripts/` (`_lib.sh`,
> `00`–`09`, `99`, `migration.env.example`, `README.md`) plus the SQL in `db/v1-to-v2-onboarding/schema/`,
> `db/v1-to-v2-onboarding/rollback/`, and the per-source-TZ variants in
> `db/v1-to-v2-onboarding/onboarding-tz-variants/`. (Reorganized 2026-07-10 — the toolkit moved out of
> `db/migration/`, which now holds only the greenfield base dump + `V2.2.x` deltas.) This SOP describes the *procedure, decisions,
> gates, and validated facts* — run the scripts from the repo.

---

## 0. What is reusable vs per-client (read first)

The whole design hinges on this split. **Do not fork the scripts or SQL per client** — only `migration.env` changes.

| Asset | Reuse | Notes |
|---|---|---|
| Toolkit scripts `00`–`09`, `99`, `_lib.sh` | ♻️ **As-is** | Never edited per client. `_lib.sh` derives the repo root from its own location. |
| `db/v1-to-v2-onboarding/schema/` V1.2.01–05 + `db/v1-to-v2-onboarding/rollback/` V1.2.99 (LA originals) | ♻️ **As-is** | Selected automatically for an `America/Los_Angeles`-source client. |
| `db/v1-to-v2-onboarding/onboarding-tz-variants/V1.2.0x_<TZ>` (e.g. `_America_New_York`) | ♻️ **As-is** | Selected automatically by `CLIENT_HIBERNATE_TZ`. **The NY variant is validated** (§5) — reuse it for every NY-source client, no regeneration. |
| V2.1.x bridge scripts | ♻️ **As-is** | Applied directly to a v1 DB; no v1-compat branch (§5). |
| `migration.env` | ✍️ **New per client** | The single per-client artifact. Copy `migration.env.example`, fill it. |
| **Run record** (this client's results) | ✍️ **New per client** | A thin plan in `1-Projects/wms2/plan/`, archived when done. |

**A new *source TZ* (other than NY/LA) is a one-time committed variant**, authored per
`db/v1-to-v2-onboarding/onboarding-tz-variants/README.md` — still not a per-client artifact.

---

## 1. Per-client config — `migration.env` (the only thing you edit)

Copy `migration.env.example` → `migration.env` (gitignored; holds DB creds) and fill:

| Field | Per-client? | Meaning |
|---|---|---|
| `CLIENT_HIBERNATE_TZ` | ✍️ | **Source write-TZ** — how the v1 instance physically wrote timestamps (its `hibernate.jdbc.time_zone`), **not** the warehouse location. **The only knob that selects the SQL variant.** |
| `TENANT_DISCOVERY_TZ` | ✍️ | Frontend display TZ (landlord `tenant_discovery.timezone`). |
| `CLIENT_NAME`, `TENANT_NAME`, `CLIENT_FACILITY_CODE`, `TENANT_DISCOVERY_KEY` | ✍️ | Identity. |
| `OMS_BASE_HOST` | ✍️ | Real OMS host; substituted into V2.1.02 / V2.1.13 placeholder URLs. |
| `TENANT_DB_*`, `LANDLORD_DB_*` | ✍️ | Tenant DB = where all migrations run; landlord = master config (PREP-9 only). |
| `WORK_DIR`, `BACKUP_DIR`, `V1_DEPLOYED_PROPERTIES` | ✍️ | Paths; `V1_DEPLOYED_PROPERTIES` points at *that client's* deployed v1 config for the PREP-1 hard gate. |

> **For an LA-source client:** set `CLIENT_HIBERNATE_TZ` + `TENANT_DISCOVERY_TZ` to `America/Los_Angeles`,
> update creds + OMS host, leave everything else. `03-gen-scripts.sh` selects the `db/v1-to-v2-onboarding/schema` LA originals.

---

## 2. Toolkit — script → phase → owner

| Script | Phase | Owner | What it does | Re-runnable? |
|---|---|---|---|---|
| `01-preflight.sh` | A | 🤖 | PREP-1,2,3,4,6,10,11 read-only checks + baseline row-counts | yes |
| `02-backup.sh` | A | 🤖 | `pg_dump -Fc` + `pg_restore --list` verify | yes (needs `$WORK_DIR/backup_stamp`) |
| `03-gen-scripts.sh` | A | 🤖 | Select per-source-TZ V1.2.01/02/99 variant + OMS-substituted V2.1.02/13 | yes |
| `04-schema-bridge.sh` | C | 🤖 | Step A stuck-order fix + V2.1.01…V2.1.16 in order | yes (idempotent) |
| `05-verify-bridge.sh` | C | 🤖 | Bridge verification (tables, syskeys incl. `API_TIMESTAMP_FORMAT`, function, index) | yes |
| `06-drain.sh` | E | 🤖 | Outbox→0, snapshot+clear `rest_idempotency` | yes |
| `07-utc-migrate.sh` | F | 🤖 | V1.2.01→05 (01 standard → 02 large → 03 outbox → **04 views** → **05 functions**) | **partial\*** |
| `08-verify-utc.sh` | F | 🤖 | timestamptz/views/fn-sig/row-count verify + ANALYZE + spot-checks | yes |
| `09-smoke.sh` | H | 🤖 | `SHOW timezone`, `CURRENT_DATE`, sample read | yes |
| `00-restore.sh` | F/H | 🤖 | `pg_restore` from the Phase-A dump (the deterministic rewind) | yes |
| `99-rollback.sh` | F/H | 🤖 | Hard rollback via reverse `timestamptz→timestamp` (`V1.2.99`) | yes |

\* `07` is **not** cleanly re-runnable *as a whole* — `V1.2.01`'s canary **aborts** on already-converted
data. But each step is individually re-runnable (V1.2.02 is per-table guarded/resumable; 03/04/05 are
`CREATE OR REPLACE` / `DROP…CREATE`). Partial-failure recovery = hand-run the remaining step(s), or
`00-restore.sh` for a mixed large-table state.

---

## 3. Phase flow, gates & ownership

| Badge | Owner | Means |
|---|---|---|
| 🤖 **AI** | Claude + DB/repo access | Fully automatable; runs the script, reports pass/fail. |
| 👤 **HUMAN** | Operator / infra | Needs a privilege I can't hold: orchestration, maintenance toggle, CI/CD, go/no-go. |
| 🤝 **JOINT** | AI prepares → human approves | I run the read-only check; a human pulls the privileged trigger. |

```
PHASE A  🤖  Pre-flight + backup + assemble client scripts        (read-only, no downtime)
   │  ── GATE A→B: AI posts pre-flight report; human reviews ──
PHASE B  👤  Human prerequisites & sign-offs (PREP-9..14)          (no downtime)
   │  ── GATE B→C: all PREP sign-offs green ──
PHASE C  🤖  §0.6 schema bridge V2.1.01–V2.1.16                    (no downtime)
   │        + apply db/migration/V2.2.x deltas → fresh-v2 parity (§4 Phase C)
   │  ── GATE C→D: 05-verify-bridge ALL PASS ──
PHASE D  👤  Deploy 1 — stabilize wms2-api code (global, behavior-preserving)
   │  ── GATE D→E: schedule maintenance window ──
╔═══ MAINTENANCE WINDOW OPENS ═══════════════════════════════════════════╗
PHASE E  👤  Maintenance mode + quiesce writes + scale app to 0    (🤖 assists w/ 06-drain)
   │  ── GATE E→F: writes quiesced, instances at 0 ──
PHASE F  🤖  UTC data migration V1.2.01–05 + 08-verify             (longest DB step)
   │  ── GATE F→G: 08-verify ALL PASS (else 99-rollback / 00-restore) ──
PHASE G  👤  Deploy 2 app image (UTC config) + scale back up
   │  ── GATE G→H: app healthy ──
PHASE H  🤝  09-smoke (🤖) + go/no-go (👤)
   │  ── GATE H: GO → continue · NO-GO → soft rollback / 00-restore ──
╚═══ MAINTENANCE WINDOW CLOSES (on GO) ══════════════════════════════════╝
PHASE I  👤  Deploy 3 — frontends (web + mobile)
PHASE J  🤝  API format flag flip (after ≥1 stable operational day)
PHASE K  🤝  Post-migration cleanup (subsequent sprints)
```

---

## 4. Per-phase notes (the load-bearing facts)

**Phase A — pre-flight, backup, script-gen (🤖).** `01-preflight.sh` enforces three **hard gates**:
- **PREP-1 (the footgun):** the client's *deployed* v1 `hibernate.jdbc.time_zone` must equal
  `CLIENT_HIBERNATE_TZ`. A wrong TZ silently shifts every timestamp with **no error**. The script also
  prints a recent stored row through `AT TIME ZONE` so a human can sanity-check the wall-clock reading.
- **PREP-3:** ids 140–143 must be free *or* hold the expected stale-club/pick-path syskeys (else V2.1.08/09
  PK-collide). The script reports the live layout — do not assume.
- **PREP-6:** free disk on the **DB host** ≥ DB size (the V1.2.02 rewrite needs ~2× per large table).
  ⚠️ See the tunnel caveat in §7.

`01-preflight` also captures **baseline row-counts** (Phase F compares against these). `02-backup.sh`
needs a stamp first: `echo <stamp> > $WORK_DIR/backup_stamp`. `03-gen-scripts.sh` *selects* the committed
per-source-TZ variant — it never `sed`s the TZ literal at runtime (a reviewed, committed variant beats an
unreviewed runtime substitution against production).

**Phase C — schema bridge (🤖).** Applies V2.1.01→V2.1.16 **directly against the v1 DB, in order** — no
v1-compat branch, no separate OMS-onboarding step (§5). The only non-Flyway per-client work is Step A
(idempotent stuck-order fix) and the OMS-host substitution baked into the V2.1.02 + V2.1.13 CLIENT copies.
`V2.1.15` seeds `API_TIMESTAMP_FORMAT` = `LEGACY` (the Phase-J flag's default); `05-verify-bridge.sh`
asserts the row exists, so a run can no longer silently land without it (the WineCo 2026-06-06 run
predated `V2.1.15` and shipped without it — see that run record's §4.5).
`V2.1.16` (SBDEV-2384 port, added 2026-06-11) re-creates `replenishment_monitor_view` with the flag-based
replenishable bucket (`useforreplenish = TRUE`, not the area-name list); `V1.2.04`/`V1.2.99` carry the same
predicate so Phase F and rollback can't resurrect the name list. Runs that converted **before** V2.1.16
(WineCo 2026-06-06; hydra dev rehearsals) need it applied standalone — it is safe on a converted DB
(patched 2026-06-11: hydra-dev2, wineco `wh01_om1_v2` dev2 copy, `dev_wh01_om1`; wineco uat @10.0.0.6
still pending — see that run record's §4.6).

**Post-bridge: reaching fresh-v2 parity (`V2.2.x`) — REQUIRED to make a migrated DB current.** The
schema bridge deliberately stops at the **`V2.1.16` watermark** — exactly what the greenfield base dump
`db/migration/V2.2.00__base_v2_schema.sql` captures. It does **not** apply the fresh-v2 deltas that have
landed since, so a freshly-bridged tenant sits at `V2.2.00`-equivalent, **not current**. To bring it to
parity with a greenfield v2 DB, apply the `db/migration/V2.2.x` deltas **in order** after the bridge —
as of 2026-07-17: `V2.2.01` (`replenishment_monitor_view` section/ro_id, SBDEV-2384), `V2.2.02`
(`lock_report_exclude_shipped`, SBDEV-2474 — **PR #77, not yet on `develop`**). (The former
`V2.2.01__los_sequencenumber_init` seed is now folded into the `V2.2.00` base dump, and the two deltas
above were renumbered down by one when the dump was re-exported on 2026-07-17.) **Re-check the highest
`V2.2.*` in `db/migration/` at run time — the list grows.** Apply
them as SQL against the tenant DB; the running wms2-api does **not** invoke Flyway. Each is
`CREATE OR REPLACE VIEW` / index / seed and safe (idempotent) on a converted DB.

> **Why the fix lives in `db/migration/`, not the onboarding `schema/` lineage.** `db/v1-to-v2-onboarding/schema/`
> is **frozen at the `V2.1.16` watermark by design** (it must equal what `V2.2.00` captures). Post-watermark
> changes belong in `db/migration/V2.2.x` and reach migrated tenants via *this* post-bridge step — the same
> deltas a greenfield DB gets. **Exception (test-only):** the IT harness scans *only* `schema/` via
> `src/test/resources/flyway.conf` and never applies `db/migration/V2.2.x`, so a change may be **mirrored**
> into `schema/` purely for test visibility — e.g. `V2.1.17__lock_report_exclude_shipped.sql` is a
> byte-identical copy of `V2.2.02` (`lock_report_exclude_shipped`). That mirror is a **test-harness shim, not an onboarding requirement**,
> and does not change this operator step (a migrated tenant still gets the fix from `V2.2.02`). If the harness
> is ever pointed at `db/migration` too, the `V2.1.x` mirrors can be dropped to restore the frozen watermark.

**Phase E — quiesce (👤 + 🤖).** `06-drain.sh` polls the outbox to 0 and **fails closed** on undelivered
rows (override only with a conscious `DRAIN_ACCEPT_PENDING=1`). It snapshots `rest_idempotency` →
`rest_idempotency_predrain` before clearing, so a soft rollback can recover the ledger. No app instance
may run on the converted DB with old config → scale to 0 (👤).

**Phase F — UTC conversion (🤖). Ordering is load-bearing:** `V1.2.01` drops all 11 reporting views and
converts standard tables; `V1.2.02` rewrites the large tables (non-transactional, the longest step);
`V1.2.03` outbox/rest_idempotency; **`V1.2.04` recreates the 11 views**; **`V1.2.05` recreates functions
LAST** (because `stock_history` RETURNS `stock_view.%TYPE`, so the view must exist first). `08-verify-utc.sh`
gates the deploy: all large-table cols `timestamptz`, all 11 views present, fn signatures `timestamptz`,
outbox index, and **row counts == baseline**. On FAIL → `99-rollback.sh` (clean schema) or `00-restore.sh`
(partial/mixed state) before any app start.

**Phases B / D / G / I — human.** Landlord `tenant_discovery.timezone` (PREP-9), PgBouncer `pool_mode=session`
(PREP-11), OMS ISO-8601 compatibility (PREP-12), rollback RTO rehearsal (PREP-13), go/no-go owner (PREP-14);
the Deploy-1 stabilize image, Deploy-2 UTC image + scale-up, Deploy-3 frontends. These need privileges I
can't hold.

**Phase H — smoke + go/no-go (🤝).** `09-smoke.sh` asserts the per-tenant session TZ comes from
`connectionInitSql` (compared against the `System Time Zone` sysprop, **not** `CLIENT_HIBERNATE_TZ`), and
that the `API_TIMESTAMP_FORMAT` flag is still `LEGACY` — V2.1.15 seeds it `LEGACY`; it must **not** be
`ISO8601_UTC` before Phase J (ordering guard, so the old frontend never receives an unparseable wire format).

**Phase J — flag flip (🤝).** Only after both frontends are confirmed on the new build ≥1 operational day.
Uses a guarded `UPDATE` of the row seeded by V2.1.15 (no `ON CONFLICT` — `los_sysprop`'s only unique is
the composite `client_id,syskey,workstation`). The backend reader **exists** (Phase 2.9):
`ApiTimestampFormatResolver` reads the sysprop per request and the `Utc*Serializer`s emit `ISO8601_UTC`
(trailing `Z`) when it is set — the prior "reader missing" gap is closed.

**Phase K — cleanup.** TimezoneService cache → Caffeine TTL, startup TZ-fallback validator, drop the
`rest_idempotency_predrain` snapshot, `TRUNCATE flyway_schema_history` (if present), landlord
`TenantDbConfiguration` pre-migration rows.

---

## 5. Validated facts (de-risk every future run)

- **NY conversion math is validated on real NY-written data** (Hydra wh01 dev rehearsal, 2026-06-05,
  PostgreSQL 16.10): a row stored `06:40:27` naive-NY converted to `11:40:27+00` UTC (+5h EST) and reads
  back through `AT TIME ZONE 'America/New_York'` as `06:40:27` — original wall-clock preserved, row counts
  unchanged. **This means the `_America_New_York` variant is proven for all NY-source clients.** Also
  logic-validated end-to-end on PostgreSQL 16 (forward chain, view drop/recreate, fn re-signature,
  forward→rollback round-trip).
- **The schema bridge needs no v1-compat workarounds** (validated on `wms1-wineco-dev`, 2026-05-30): the
  re-id'd V2.1.08/09 (ids 140–143, composite `ON CONFLICT … DO NOTHING`) cleanly no-op (or insert into free
  ids) on a real v1 DB; V2.1.02 lands at free ids 144/145. The former `db/migration/v1-onboarding/` scripts
  were deleted.
- **`customerorder_cancellation_log` is created UTC-ready** (V2.1.12) — no V1.2.x conversion for it.
- **pg client must be ≥ server major version** for `pg_dump`/`pg_restore` (a v14 client cannot dump a v16
  server). Match or exceed the server (16) on the box that runs the toolkit.
- **Two-DB reference (wineco):** `wms1-wineco-dev` = genuine pre-migration v1 entry-state; `wms2-wineco-dev`
  = post-bridge / pre-Phase-F target-state and a ready V1.2.x rehearsal target.

What's **still per-client / not yet generalized:** production-volume RTO (§7), the Phase-J backend reader,
and any client whose source write-TZ is neither NY nor LA (needs a one-time committed variant).

---

## 6. Rollback — choose by failure type, not preference

| Failure type | Use | Why |
|---|---|---|
| Schema converted cleanly, behavior wrong | **Soft rollback** (revert app config + `SET timezone` bridge) | Fast, no rewrite; fits any remaining window. |
| Schema clean but data verified wrong | **`99-rollback.sh`** (reverse `ALTER`) | Only if measured RTO fits the remaining window — it's a *second* full rewrite. |
| **Partial V1.2.02 failure** (mixed `timestamptz`/`wtz`) | **`00-restore.sh`** (`pg_restore` from Phase-A dump) | Deterministic RTO; a reverse `ALTER` over a half-migrated table is undefined. |

`V1.2.99` is a complete single-file revert (PART 0 drop views → 1/2 revert tables → 3 outbox → 4 recreate
views → 5 restore functions). The `_CLIENT.sql` copy is the committed variant selected by `03-gen-scripts.sh`.

> **Phase-A dump source — `RUNTIME_BACKUP` / `EXTERNAL_BACKUP_DUMP` (migration.env).** `02-backup.sh`
> normally produces the dump the table above restores from. Set `RUNTIME_BACKUP=false` to **skip** the
> in-pipeline `pg_dump` when it is too slow on a large DB (e.g. WineCo ~9.5 GB) **and** a DBA has already
> taken a pre-migration backup. Both `00-restore.sh` and `02-backup.sh` resolve the recovery dump through
> `resolve_backup_dump` (in `_lib.sh`), in order:
>
> 1. **`EXTERNAL_BACKUP_DUMP`** — absolute path to the DBA's `pg_dump -Fc` under **any** filename, used
>    verbatim. Setting it is an explicit operator assertion that the dump matches the DB about to be
>    migrated, so it is **trusted, not stale-gated** — this is the simplest way to make `00-restore.sh`
>    work regardless of `RUNTIME_BACKUP`. Prefer this when the DBA's dump keeps its own name (e.g.
>    `wh01_om1.dump`).
> 2. **`<stamp>` / `$WORK_DIR/backup_stamp`** → the canonical `$BACKUP_DIR/<client>_pre_utc_<stamp>.dump`.
> 3. **newest `<client>_pre_utc_*.dump`** by mtime (lingering-file fallback).
>
> Resolutions 2–3 are **stale-gated**: if the dump predates the last `01-preflight` baseline
> (`baseline_rowcounts.csv`), `00-restore.sh` refuses unless `ACCEPT_STALE_BACKUP=1` — this is the guard
> against the wineco footgun (a Jun-5 dump left behind after a Jun-8 reload). Every path still runs the
> `pg_restore --list` readability check and the post-restore `timestamp without time zone` shape check.
> If nothing resolves, recovery falls back to the DBA's own restore procedure and the `00-restore.sh` row
> above does not apply. **Phase F still requires a real recovery point.**

---

## 7. Reuse for a NEW client

**The mechanics:** copy `migration.env.example` → `migration.env`, fill the per-client fields (§1), point it
at the client's tenant + landlord DBs, then run the same toolkit. **Nothing else changes** for an NY- or
LA-source client. (`03-gen-scripts.sh` selects the variant by `CLIENT_HIBERNATE_TZ`.)

**Must re-verify / re-measure every client — never inherit another client's answers:**

| Item | Why it's per-client |
|---|---|
| **PREP-1 deployed TZ** | A client you *assume* is NY may have been written LA. The `01-preflight` data cross-check is the real proof — non-negotiable. |
| **PREP-3 syskey layout** | Differs by lifecycle stage (Hydra had 140–143 free; wineco occupied). Let `01-preflight` report it. |
| **B3 RTO** | Forward `V1.2.02` time scales with table volume. Re-measure per client on a same-sized restore; window budget = `total − forward_time`. **Data points:** Hydra ~11 s (767 MB *dev* DB — lower bound only); **wineco `V1.2.02` = 2 m 41 s** on a 9.5 GB DB / ~25.9 M large-table rows (stockrecord 6.97 M + unitload_record 5.64 M + inventory_record 12.43 M + pickingorder_position 0.88 M), **full forward `07` ≈ 5 m 13 s** (V1.2.01 2 m 27 s + V1.2.02 2 m 41 s + V1.2.03/04/05 ≈ 5 s), 2026-06-06. Rule of thumb so far: ≈ 0.3–0.4 s per 100 k large-table rows. |
| **PREP-6 disk** | Per the client's DB host. ⚠️ **Tunnel caveat:** when the DB is reached via a `localhost` SSH tunnel, `01-preflight` measures the *local* box's disk, not the DB host's (the remote-blind guard only trips for a non-`localhost` host). Set `DBHOST_FREE_BYTES` or re-check disk **on the DB host** before a production Phase F. |
| **OMS host, landlord `tenant_discovery.timezone`** | Per client. |

**Operational caveats (apply to any tunneled run):**
- The toolkit (`migration.env`/psql) and the project's `wms2-<client>` MCP can share the **same SSH tunnel
  and DB**, but they're separate configs. Use psql/the toolkit for the migration (the MCP `execute_sql`
  can't do `pg_dump`/`-f`/`\copy`); keep the MCP for ad-hoc validation. **Don't run MCP queries during the
  Phase-F rewrite** (lock contention).
- Verify the tunnel's **local port** matches `TENANT_DB_PORT` in `migration.env` before starting.

---

## 8. Run records

Each execution gets a thin run record in `1-Projects/wms2/plan/` (archived to `4-Archieves/` when done),
holding that client's `migration.env` values (non-secret), pre-flight findings, measured RTO, gate results,
and anomalies.

| Client | Source TZ | Run record | Status |
|---|---|---|---|
| Hydra (wh01) | America/New_York | [260527-hydra-v1-to-v2-migration-runbook.md](../../1-Projects/wms2/plan/260527-hydra-v1-to-v2-migration-runbook.md) | A→C→F **rehearsed on dev** (2026-06-05); G–K pending |
| WineCo (wh01_om1, `wsl`) | America/Los_Angeles | [260606-wineco-v1-to-v2-migration-runbook.md](../../1-Projects/wms2/plan/260606-wineco-v1-to-v2-migration-runbook.md) | A→C→F **done for real** (2026-06-06, ownership blocker cleared); D/G–K human phases + Phase J pending |
