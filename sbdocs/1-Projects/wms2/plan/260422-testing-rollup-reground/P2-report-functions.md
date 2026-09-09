# P2 re-grounding — `260420-v2-port-plpgsql-functions-to-java.md`

**Re-grounded:** 2026-09-06 · **Baseline:** `origin/develop` @ `d4a6ab8a7da61e6b6918d3662bb7dc6ab8357733` (fetched at start)
**Prior re-grounding:** 2026-06-22 · **Method:** every claim from `git grep|show|ls-tree origin/<ref>`; working tree never read.

## VERDICT (§7 first)

**OBSOLETE AS WRITTEN — the plan's entire SQL baseline no longer exists on `develop`.** The
migration history was rebaselined on 2026-07-17 (`cf82ad72`) into a single squashed dump
`V2.2.00__base_v2_schema.sql`; **no `V1.*` or `V2.1.*` file remains on `origin/develop`**
(`git ls-tree -r --name-only origin/develop -- src/main/resources/db/migration | grep -E 'V1\.|V2\.1\.'` → empty).
Every `V1.2.05:NNN` line reference in §2.2, §2.2.1, §2.3, §3.1, §3.2.x, §3.5, §3.6 and §8 is dead,
as is the whole PR-#47 dependency apparatus (re-grounding note guards 1–2, §5 Phase A's
`verify-…-prekickoff.sh` gate C2–C6). `V1.2.05` survives only on 9 abandoned remote branches
(`feature/utc-timezone`, `port/SBDEV-2481-*`, …).

**The intent is still valid** — the three functions still exist, still gate H2, still have zero Java
alternative — but the plan needs a re-baseline pass, not a kickoff. **Three bug fixes landed in the
functions since June**, so the port target moved and the risk went up.

**Sequencing:** SBDEV-2777 is **already shipped on `develop`** (2026-07-31). The question inverts:
P2 must now be sequenced **after** 2777/2801/2890 and must **reproduce all three**. See §4.

---

## 1. Where the three functions live now, and what changed since 2026-06-22

`git grep -nE "FUNCTION (public\.)?(stock_history|transaction_detail|transaction_summary)" origin/develop -- src/main/resources/db/migration`

| Function | **Authoritative definition on `origin/develop`** | Signature | Changed since 2026-06-22? |
|---|---|---|---|
| `stock_history` | **`V2.2.07__fix_stock_history_client_id_aggregation.sql:29`** (body `31–82`, `USING $1;` @ `:82`, 84 lines) | `(as_of_date timestamptz)` → 8-col TABLE | **YES** — SBDEV-2777, merged 2026-07-30 `ee923378` |
| `transaction_detail` | **`V2.2.12__fix_transaction_detail_ul_picks.sql:68`** (body `70–424`, `USING $1,$2,$3,$4;` @ `:424`, `$_$;` @ `:426`) | `(varchar, varchar, timestamptz, timestamptz)` → 24-col TABLE | **YES ×2** — SBDEV-2801 `V2.2.08` (2026-08-03 `532b5b13`), then SBDEV-2890 `V2.2.12` (2026-08-10 `bb173640`) |
| `transaction_summary` | **`V2.2.00__base_v2_schema.sql:460`** (body `462–590`, `USING $1,$2,$3;` @ `:590`, `$_$;` @ `:592`) | `(varchar, timestamptz, timestamptz)` → 18-col TABLE | **NO redefinition** — but its *numbers* moved, because it calls `stock_history()` and inherits V2.2.07 |

Only two migration files mention `transaction_summary` at all (`V2.2.00`, and `V2.2.07` in a comment)
— confirmed by `git grep -ln transaction_summary origin/develop -- src/main/resources/db/migration`.

**Is the plan's `V1.2.05` timestamptz baseline still latest? No, on all three counts.** The
`timestamptz` *signatures* did survive the rebaseline (they are what `V2.2.00` dumped), so §2.3's
`timestamptz` fidelity flag and §3.2.2 Option A still apply verbatim. The *bodies* did not.

### The three body deltas the port must now carry

1. **`V2.2.07` / SBDEV-2777 — `stock_history` client_id (5 lines, all inside the `''`-doubled EXECUTE string).**
   Per the migration header (`V2.2.07:18-22`): `+ sr.client_id AS client_id` (:50), `+ OR (STOCK_REMOVED AND STOCK_ALTERED)` (:54),
   `+ OR (MANUAL_REMOVAL AND STOCK_ALTERED)` (:64), `~ GROUP BY sr.itemdata, sr.client_id` (:69),
   `+ AND received_recordset.client_id = sv.client_id` (:71).
   Sanity check: `grep -c "GROUP BY sr.itemdata, sr.client_id"` → **V2.2.00: 0, V2.2.07: 2**.
2. **`V2.2.08` / SBDEV-2801 — six NULL→0 coalesces in `transaction_detail`** (`V2.2.08:26-31`: shipped, net_change, received, returned, and both BEGINNING/ENDING `total`s). These exist *because* the Java mapper in `TransactionReportRestController` unboxes with `.longValue()`; a port that regresses them re-creates a 500.
3. **`V2.2.12` / SBDEV-2890 — the PICKING arm.** Exactly one line replaced by two:
   ```
   -  (sr.activitycode = ''PICKING'' AND (sr.type = ''STOCK_CREATED'' OR sr.type = ''STOCK_TRANSFERRED'') and sr.amount != 0) OR
   +  (sr.activitycode = ''PICKING'' AND ((sr.type = ''STOCK_CREATED''     AND coalesce(sr.amount, 0) != 0)
   +                                   OR (sr.type = ''STOCK_TRANSFERRED'' AND coalesce(sr.amountstock, 0) != 0))) OR
   ```
   (`diff V2.2.08[36..] V2.2.12[68..]` → one hunk, `207c207,208`.) Note this **supersedes the plan's
   §2.2.1 "V2.1.07 zero-amount filter" provenance claim** — the filter the plan says to preserve is
   the very defect SBDEV-2890 fixed.

> §2.2.1's byte-identity table and its "no migration after V2.1.07 touches these functions" claim are
> both **falsified**. Delete the section rather than re-date it.

---

## 2. Flyway head and the true next-free number

- Head on `origin/develop`, `origin/main`, and `origin/release` — all three identical: **`V2.2.23__seed_sdr_read_guard_mode_sysprop.sql`**.
- **All-remote-branch sweep** (66 branches, `git ls-remote --heads` → `git ls-tree` each): highest version claimed anywhere is **`V2.2.23`**. No branch carries `V2.2.24`+.
- Confirmed by the repo's own tool, run from a temp copy of `origin/develop:src/main/resources/db/check-migration-version-collision.sh`:
  `Highest claimed anywhere: V2.2.23` … `RESULT: clear`.

**True next free = `V2.2.24`.** (Plan §3.5's `V2.1.17`/`V2.1.18` are two whole version families stale.)

Two things the plan does not know about:
- **Out-of-order migration is ON by default** — `app.flyway.out-of-order:true`, `StartupFlywayMigrationRunner.java:60`. Note the prefix: `spring.flyway.out-of-order` does nothing (Boot's autoconfig is excluded). A straggler applies rather than aborting, logged WARN.
- **`V2.2.01/02/03` are collision-scarred** — three numbers each have two distinct filenames across branches (`V2.2.01__los_sequencenumber_init.sql` vs `…replenishment_monitor_view…`, etc.); the script flags them `stale`. Reserved-number etiquette is documented at `src/main/resources/db/migration/README.md:242-253`.

---

## 3. Java side — nothing has been built

- **No `service/report` package on ANY remote branch.** `git ls-tree -r --name-only origin/develop -- src/main/java/net/aim_ai/wms/service/report` → **0 lines**. *Positive control, same pathspec form:* `…/service` → **118 lines**. Loop over all 66 remote branches → no hit. The only `*Report*Service*` files are the unrelated `service/ReportService.java` and `service/WarehouseStockReportService.java`.
- **`TransactionReportRestController` still calls the DB functions through `ClientRepository`, unchanged:**
  - `TransactionReportRestController.java:140` → `clientRepository.getTransactionSummary(...)`
  - `TransactionReportRestController.java:287` → `clientRepository.getTransactionDetail(...)`
  - Endpoints at `:93` `/getTransactionReport`, `:201` `/getTransactionDetailedReport`; `@RequestMapping("/rest/report")` @ `:42`. (File is 358 lines; plan's `:75-175` / `:177-322` ranges drifted ~18 lines.)
- **`ClientRepository.java:44-61`** — both native queries intact, still `to_timestamp(:x,'YYYY-MM-DD hh24:mi:ss')\:\:timestamptz` (`:49-50`, `:59-60`). Plan's "`:49-56` / `:58-66`" is off by ~5 lines but structurally correct; §3.2.2 Option A holds.
- **`StockViewRepository.java:61-63`** `stockHistoryAfterAsOfDate` — still present, still `Date` param (plan §3.4 delete target, still valid).
- **`StockrecordRepository.java:21-40`** — both "dead" duplicates still present, still `Date`-typed and **not** wrapped in `to_timestamp`, so they were never equivalent to the `ClientRepository` pair. Both are exported over SDR (`@RepositoryRestResource` @ `:18`, no `exported=false` on either method) — so "zero callers" from a Java grep does **not** mean unreachable; re-verify against the SDR surface before deleting.
- **No feature flag.** `git grep -iE "report\.(impl|engine)|REPORT_ENGINE|reportEngine" origin/develop -- src` → zero hits. §3.5 Phase B's `app.report.engine` is unbuilt.

---

## 4. SBDEV-2777 — the highest-value answer

**SHIPPED on `origin/develop`.** `V2.2.07__fix_stock_history_client_id_aggregation.sql`, merge
`ee923378` (2026-07-30); the plan doc's own §"Implementation" records PR #112 merged 2026-07-31
(`7d9aee6`) and ClickUp moved to **`on dev`**. Its frontmatter still says `status: reviewed` and
`updated: 2026-07-30` — stale, do not read state from it.

**It does not conflict with P2. It adds scope, invalidates one of P2's design decisions, and creates
two hard test constraints.**

**(a) The Java port must reproduce a corrected, client_id-aware aggregation — yes, explicitly.**
Both Fix A (per-client grouping/join) and Fix B (two previously-uncounted `(activitycode,type)`
pairs) are in the one migration; the 2777 plan's D1-R2 records the deliberate bundling. Blast radius
recorded there: **2,894 SKUs / −194,757 `adjustments` on the largest tenant for Fix B alone, ~54× Fix A.**
A port that copies a pre-2777 body silently re-mis-attributes across every client sharing a SKU.
**The 2777 plan anticipated exactly this** — its §10 row **D5** is an *open* decision reading: *"The
Java port plan `260420-v2-port-plpgsql-functions-to-java` (`status: reviewed`, unimplemented) must
carry the `client_id` predicate when it lands, or it will reintroduce this bug. Add a note to that
plan now, or handle at port time?"* — owner: requester, **unresolved**. This re-grounding closes it:
handle at port time, and the note is now on record here.

**(b) It weakens P2's §3.1 "inline the sub-SELECT" DECISION.** V2.2.07's header states the fix
propagates to the siblings *because* `transaction_detail`/`transaction_summary` "resolve
`stock_history` at execution time through dynamic SQL" — one body, three consumers. Inlining in Java
**duplicates that body into two more places**, so any future `stock_history` correction must be made
three times or it drifts. The plan rejected the alternative (in-memory join) for parity reasons and
that reasoning still holds, but the third option it never considered — one shared
`SQL_STOCK_HISTORY` constant referenced by both services (its own §8 open-Q3) — is now the *only*
acceptable form, and should be promoted from "decide during Phase A" to a decision.

**(c) Two recurrence gates now pin the PL/pgSQL bodies as deployed, which Phase D would break.**
Both read `pg_get_functiondef` from a migrated Testcontainers DB, not from a `.sql` file:
- `StockHistoryClientIsolationIntegrationTest.java:474-489` — asserts the resolved body still contains
  `GROUP BY sr.itemdata, sr.client_id` and `received_recordset.client_id = sv.client_id`.
  Plus two propagation tests: `:494` (`transaction_summary.beginning_inventory` per client) and
  `:535` (`transaction_detail` BEGINNING row per client).
- `TransactionDetailAllowListStructuralIntegrationTest.java:88-91,180` — SBDEV-2890 AC-9 structural
  guard; asserts every value-CASE `(activitycode,type)` pair is admitted by the WHERE allow-list, with
  one documented `ACCEPTED_EXCLUSIONS` entry (`STOCK_REMOVED/STOCK_ALTERED`, `:63`). Adding an
  exclusion **requires a plan reference** by its own contract.

  Phase D (`DROP FUNCTION`) makes all of these fail at `assertThat(rs.next()).isTrue()`. So does
  `StartupFlywayMigratorIntegrationTest.java:137,145` (`select count(*) from pg_proc where proname='transaction_detail'`).
  **Phase D must port these four guards to the Java path, not delete them** — the plan has no such step.

**(d) A cheap win P2 should adopt:** 2777 proved the port's own hardest problem is tractable. Its
body was sourced from `pg_get_functiondef()` on a live DB (V2.2.07:15) rather than transcribed —
the same technique gives P2 the authoritative, already-un-doubled SQL for all three functions and
removes most of §2.3's `''`-un-doubling hazard. Recommend making that the Phase A method.

**Sequencing verdict: SBDEV-2777 is DONE and sits BEFORE P2 Phase A by fact, not by choice.**
So do 2801 and 2890. P2 Phase A's baseline is `V2.2.07` + `V2.2.12` + `V2.2.00`'s `transaction_summary`.
Anything that redefines a report function while P2 is in flight forks the port; P2 should own a
freeze or a re-diff step against `pg_get_functiondef` immediately before the parity run.

---

## 5. Tests that depend on these functions today

`git grep -nE "stock_history|transaction_detail|transaction_summary" origin/develop -- src/test/java`

| Test class | Depends on | Note |
|---|---|---|
| `StockHistoryClientIsolationIntegrationTest` | all 3 | SBDEV-2777 gate; direct calls @ `:286,:303,:446,:518,:552`; recurrence gate `:474`; propagation `:494,:535` |
| `TransactionDetailNullAmountIntegrationTest` | `transaction_detail` | SBDEV-2801 gate; call @ `:207` |
| `TransactionDetailUlPickIntegrationTest` | `transaction_detail`, `transaction_summary` | SBDEV-2890 gate; `:219`, `:413` |
| `TransactionDetailAllowListStructuralIntegrationTest` | `transaction_detail` | AC-9 structural guard; `:88,:180` |
| `StartupFlywayMigratorIntegrationTest` | `transaction_detail` | existence assertions `:137,:145` |
| `ClientRepositoryIntegrationTest` | `transaction_detail` | see below |
| `TransactionReportRestControllerUnitTest` | — | comments only (`:450,:947`); mapper-level, no DB |

**`ClientRepositoryIntegrationTest` — the @Disabled moved.** It is at **line 259**, on the
`@Nested class GetTransactionDetailSmokeTest` (`:260`), **not** line 285. Plan §2.5/§2.6 row 8
("line 285", "284-312") are stale; the file is 362 lines. The reason string still blames
SBDEV-2217 landlord-datasource / HikariConfig wiring — which the plan §1 argues is stale and the
real blocker is the PL/pgSQL dependency. **That argument is now doubtful**: the four ITs above run
the same functions against Testcontainers and are *not* disabled, so the function dependency is
demonstrably not what blocks this class. Re-diagnose before citing it as P2's payoff.

**Lane note:** all of these are `*IntegrationTest` and therefore DO run in failsafe
(`pom.xml:708-711` includes `**/*IntegrationTest.java`). They are not part of the 28 orphaned
`*IT.java` classes (`pom.xml:683-707`).

---

## 6. Has Phase A started? No.

`git log origin/develop --oneline --since=2026-06-01 -- src/main/resources/db/migration <controller> <ClientRepository>`
returns ~40 commits, **none** touching the report Java path. The only report-adjacent work is the
three PL/pgSQL bug fixes: `ee923378` (2026-07-30 SBDEV-2777), `532b5b13` (2026-08-03 SBDEV-2801),
`bb173640` (2026-08-10 SBDEV-2890) — plus the `cf82ad72` (2026-07-17) base-dump rebaseline and
`9cc49350` "support out-of-order migrations, and prevent the collisions". Combined with §3's
zero-result-plus-positive-control scan for `service/report`: **Phase A has not started.**

---

## 7. What a re-baseline pass must change

| Plan section | Action |
|---|---|
| Re-grounding note (2026-06-17 block, both guards) | **DELETE.** PR #47 / `V1.2.05` is moot; the branch is abandoned and its file is off `develop`. |
| §1 table, §2.2, §2.2.1, §2.3, §2.6 rows 0–3 | **REWRITE** onto `V2.2.07` / `V2.2.12` / `V2.2.00`. §2.2.1's byte-identity table is falsified — delete it. |
| §2.6 rows 4,6,7,8 | Line refs drifted: ClientRepo `44-61`, controller `93`/`201` (358 lines), test `@Disabled` @ **259**. |
| §3.1 inline decision | Re-decide as **one shared `SQL_STOCK_HISTORY` constant** (§8 Q3), per §4(b). |
| §3.2.2 Option A | Still valid — signatures are still `timestamptz`, `ClientRepository:49-50,59-60` still casts. |
| §3.4 dead-method deletions | `StockrecordRepository` duplicates are SDR-exported; grep-based "zero callers" is insufficient. |
| §3.5 / §5 Phase D / §8 rollback | `V2.1.17`/`V2.1.18` → **`V2.2.24`** (next free, verified). Restore bodies come from `V2.2.07`+`V2.2.12`+`V2.2.00`, not `V1.2.05`. |
| §5 Phase A first checkbox | The prekickoff verify script's C2–C6 all test dead facts — **retire it**. |
| §5 Phase A, new | Source SQL via `pg_get_functiondef()` (2777's method) rather than hand-un-doubling. |
| §5 Phase D, new | Port the **four** recurrence/existence guards (§4c) to the Java path before dropping anything. |
| §6 test plan, new rows | Parity must cover SBDEV-2777 (per-client attribution + both Fix-B pairs), SBDEV-2801 (no NULL in 6 columns), SBDEV-2890 (full-move UL picks present). |
| §8 open-Q1 | Still correct in conclusion (no prod caller) but its `V1.0.03:389,423` refs are dead. |
| SBDEV-2777 plan §10 **D5** | **CLOSED by this document** — "handle at port time", recorded above. |
