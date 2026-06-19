# P2 Report-Port — TDD Gate Scaffold (MANIFEST)

Pre-implementation TDD-gate scaffold for **plan P2**:
`sbdocs/1-Projects/wms2/plan/260420-v2-port-plpgsql-functions-to-java.md`

Target: `v2/wms2-api` (Java 21, Spring Boot 3.5.x, JUnit 5, Mockito 5, AssertJ,
Testcontainers-PostgreSQL, `NamedParameterJdbcTemplate`, Jakarta namespace).

These files are **copy-ready**: the directory mirrors the `v2/wms2-api/src` layout
(`main/java/...`, `test/java/...`). Nothing here is under `src/`; nothing was built.

---

## ⚠️ GATE-CLOSED dependency — authored now, runnable later

The parity ITs compare each Java report service's output against the **`V1.2.05`
`timestamptz` DB report functions** (`stock_history`, `transaction_detail`,
`transaction_summary`). `V1.2.05__utc_update_functions.sql` ships via **PR #47**
(`feature/utc-timezone`) and is **NOT on `develop` yet**.

The pre-kickoff gate script
`sbdocs/9-System/scripts/verify-260420-v2-port-plpgsql-functions-to-java-prekickoff.sh`
currently reports **GATE CLOSED** (its `C2-GATE` check fails until #47 merges — that
is the gate working as designed).

Consequence: the ITs in this scaffold are **authored-but-unrunnable** today. The
shared harness (`ReportItSupport.migrate(...)`) stages the top-level production
`V*.sql` migrations into a Testcontainers PostgreSQL instance; until #47 merges, that
folder does **not** contain `V1.2.05`, the three report functions do not exist, and
the `SELECT * FROM transaction_detail(...)` (etc.) comparison side errors before any
RED/GREEN signal is meaningful.

### Activation steps (do in order)

1. **PR #47 merged → run the pre-kickoff verify script; it MUST exit 0.**
   ```bash
   PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
     bash sbdocs/9-System/scripts/verify-260420-v2-port-plpgsql-functions-to-java-prekickoff.sh
   ```
   Exit 0 = `V1.2.05` is on `develop` with `timestamptz` signatures, the §2.2.1
   byte-diff provenance vs `V2.1.07`/`V1.1.04`/`V1.0.03` still holds, and the
   `ClientRepository` `::timestamptz` casts + free migration numbers are confirmed.
   If `C2-GATE` fails → #47 has not merged → **do not start Phase A.** If a `C4`
   provenance check fails → `V1.2.05` changed in review → **re-confirm the line refs
   / function signatures below before trusting the ITs** (see "Re-confirm" note).
2. **Branch off `develop`** (`feature/...` per the repo's branching pattern).
3. **Copy skeletons + tests into `src`** (preserving package paths):
   - `main/java/net/aim_ai/wms/service/report/*.java`
     → `v2/wms2-api/src/main/java/net/aim_ai/wms/service/report/`
   - `test/java/net/aim_ai/wms/common/report/ReportParityComparator.java`
     → `v2/wms2-api/src/test/java/net/aim_ai/wms/common/report/`
   - `test/java/net/aim_ai/wms/integration/report/*.java`
     → `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/report/`
4. **Run the gate** (Testcontainers needs a running Docker daemon):
   ```bash
   cd v2/wms2-api && mvn verify -Dtest='*ReportServiceIT'
   mvn test -Dtest=TransactionReportRestControllerParityTest
   ```
   - **RED** (services throw `UnsupportedOperationException`; seed stubs throw) until the
     real `V1.2.05` SQL is ported into each service and the `seed*()` stubs are filled.
   - **GREEN** == plan §5 (parity-comparator contract) + §6 (test matrix) acceptance.

> **Re-confirm before trusting the ITs:** the `V1.2.05` line refs and function
> signatures embedded in the service/IT Javadoc (`stock_history` body `V1.2.05:59-101`;
> `transaction_detail` body `116-465`, zero-amount filter `:318`, `USING` `:467`;
> `transaction_summary` body `480-604`, `USING` `:606`) reflect the 2026-06-17 pre-merge
> tip. Re-derive them via the pre-kickoff script against the **merged** `V1.2.05` before
> the parity ITs are trusted — if #47 was altered in review, re-baseline per plan §2.2.1.

---

## Files created

| Path (under this scaffold dir) | Kind | Compiles? | Status |
|---|---|---|---|
| `main/java/.../service/report/StockHistoryReportService.java` | `@Service` skeleton | yes | body throws → RED |
| `main/java/.../service/report/TransactionDetailReportService.java` | `@Service` skeleton | yes | body throws → RED |
| `main/java/.../service/report/TransactionSummaryReportService.java` | `@Service` skeleton | yes | body throws → RED |
| `test/java/.../common/report/ReportParityComparator.java` | parity comparator util (§5) | yes | reusable across the 3 ITs |
| `test/java/.../integration/report/ReportItSupport.java` | Testcontainers + Flyway harness | yes | stages `V*.sql` incl. `V1.2.05` post-#47 |
| `test/java/.../integration/report/TransactionDetailReportServiceIT.java` | failing IT | yes | gate-closed → RED |
| `test/java/.../integration/report/StockHistoryReportServiceIT.java` | failing IT | yes | gate-closed → RED |
| `test/java/.../integration/report/TransactionSummaryReportServiceIT.java` | failing IT | yes | gate-closed → RED |
| `test/java/.../integration/report/TransactionReportRestControllerParityTest.java` | failing IT (e2e flag parity) | yes | gate-closed → RED |
| `MANIFEST.md` | this file | — | — |

**Projection interfaces are REUSED, not created** — `StockHistoryView`,
`TransactionDetailView`, `TransactionSummaryView` already exist at
`v2/wms2-api/src/main/java/net/aim_ai/wms/repo/projection/` (grep-confirmed). The
scaffold imports them; it does NOT skeleton them.

**Constraints honored:** nothing was written under `v2/wms2-api/src/`; `mvn` was not
run. This is a pre-implementation scaffold only.

---

## Test → criterion table (plan §6)

| Test class | `@Test` method | Plan §6 criterion it encodes |
|---|---|---|
| `TransactionDetailReportServiceIT` | `matchesDbFunction_overSeededDataset` | "Transaction detail Java vs DB function" — the "are we done?" gate |
| `TransactionDetailReportServiceIT` | `zeroAmountPickingFiltered` | "Transaction detail zero-amount PICKING filter" (V2.1.07 / `V1.2.05:318`) |
| `TransactionDetailReportServiceIT` | `canceledOrderRowPresent` | "Transaction detail canceled-order row" (state=800, `depleted_picked` negative) |
| `TransactionDetailReportServiceIT` | `beginningAndEndingRowsPresent` | "Transaction detail BEGINNING/ENDING rows" (one each per SKU) |
| `StockHistoryReportServiceIT` | `matchesDbFunction_overSeededDataset` | "Stock history matches DB function (regression)" — via the internal fragment test hook (§3.2.1) |
| `TransactionSummaryReportServiceIT` | `matchesDbFunction_overSeededDataset` | "Transaction summary Java vs DB function" |
| `TransactionSummaryReportServiceIT` | `canceledOrderAccounting` | "Transaction summary canceled-order accounting" |
| `TransactionReportRestControllerParityTest` | `flag_java_matches_plpgsql` | "Controller flag flip" — identical JSON for `engine=plpgsql` vs `=java` |
| all three `*IT` | `seedBoundaryRows()` invoked from the `matches*`/flag tests | §7/F7 fidelity risk — DST timezone-boundary timestamp + rounding-boundary numeric |

### Parity-comparator contract (plan §5) — encoded in `ReportParityComparator`

| §5 sub-rule | Where encoded |
|---|---|
| (a) BigDecimal scale-INSENSITIVE via `compareTo()==0`, never `.equals()` | `Kind.NUMERIC` branch in `assertColumn` |
| (b) rows compared in order, both sides share a deterministic total `ORDER BY` | row-count assert + index-aligned compare, no re-sort; assumption documented in class Javadoc |
| (c) null-vs-zero per column | `NullPolicy.COALESCED` (never null both sides) / `NullPolicy.NULLABLE` (null must match) |
| (d) timestamp compared at `date_trunc` precision | `Kind.TIMESTAMP_SECOND` (`transaction_date`) / `Kind.TIMESTAMP_DAY` (`modified`-derived) |

---

## Notes on key design choices

- **Tenant datasource (plan §3.0, the most important correctness point):** every service
  injects `@Qualifier("tenantDynamicRoutingDataSource") DataSource` and builds its own
  `NamedParameterJdbcTemplate` over it — NOT the `@Primary`/landlord bean. The IT harness
  (`ReportItSupport.routingDataSourceForwardingTo`) supplies a Mockito mock of that bean
  whose connections forward to the Testcontainers PostgreSQL instance, mirroring
  `TestDatabaseConfig:25-45` but on real PG so `timestamptz` fidelity is exercised
  (the H2 lane structurally cannot vet it — plan §2.3 / §3.0 fidelity caveat).
- **`stock_history` is internal-only (plan §3.2.1 / §8 Q1):** no public REST endpoint;
  `StockHistoryReportServiceIT` tests the inlined fragment via the service's `run(...)`
  **test hook**, comparing to `SELECT * FROM stock_history(:d)` — the "thin test hook"
  approach the plan implies.
- **Option A date handling (plan §3.2.2):** service signatures take raw `String` date
  params; the `to_timestamp(...)::timestamptz` parse stays inside the (to-be-ported) SQL,
  so there is zero TZ-locus change vs the post-UTC production path. The IT reference
  queries use the same `to_timestamp(...)::timestamptz` form as `ClientRepository:54-55,64-65`.
- **Seed helpers are deliberate stubs:** `seedMixedActivity()`, `seedBoundaryRows()`, etc.
  throw `UnsupportedOperationException` so the gate stays RED until the implementing
  engineer fills them against the real tenant schema. The boundary seeds (DST instant +
  rounding-edge numeric) are mandatory per the reviewers (plan §7/F7) — they are wired
  into the parity/flag tests, not optional.
