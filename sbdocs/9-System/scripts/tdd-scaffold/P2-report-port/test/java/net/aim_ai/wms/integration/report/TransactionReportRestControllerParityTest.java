package net.aim_ai.wms.integration.report;

import static org.assertj.core.api.Assertions.assertThat;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import javax.sql.DataSource;
import net.aim_ai.wms.service.report.TransactionDetailReportService;
import net.aim_ai.wms.service.report.TransactionSummaryReportService;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;

/**
 * TDD-GATE FAILING IT — END-TO-END PARITY GATE for the {@code app.report.engine} flag (plan §3.3,
 * §3.5 Phase B, §6 row "Controller flag flip").
 *
 * <p>This is the "are-we-done?" gate at the controller level: the SAME report request served with
 * {@code app.report.engine=plpgsql} (the DB-function path via {@code ClientRepository}) and with
 * {@code app.report.engine=java} (the new {@code Transaction*ReportService} path) MUST produce
 * <b>identical JSON</b>. It backstops the per-service parity ITs by proving the controller wiring,
 * DTO mapping, and date round-trip ({@code SimpleDateFormat} normalize at
 * {@code TransactionReportRestController.java:99-111}) are flag-invariant.</p>
 *
 * <p><b>GATE-CLOSED:</b> runnable only after PR #47 merges {@code V1.2.05} to {@code develop} (so
 * the {@code plpgsql} side has functions to call) AND the {@code app.report.engine} flag + service
 * wiring land (plan Phase A/B). Until then this test is authored-but-unrunnable — see MANIFEST.md.</p>
 *
 * <p>This scaffold sketches the parity assertion against the JSON the two engines produce for the
 * detail and summary endpoints. The implementing engineer wires the actual HTTP call (MockMvc /
 * {@code BaseControllerIntegrationTest}) and flag toggling once the controller branch exists; the
 * seed + raw-JDBC plpgsql reference query are shown so the contract is unambiguous.</p>
 */
@DisplayName("P2 — TransactionReportRestControllerParityTest (app.report.engine flag parity)")
class TransactionReportRestControllerParityTest {

    private static final PostgreSQLContainer<?> DB = ReportItSupport.newContainer();

    private static String jdbcUrl;
    private static String user;
    private static String pass;
    private static DataSource dbSide;
    private static TransactionDetailReportService detailService;
    private static TransactionSummaryReportService summaryService;

    private static final String CLIENT = "PARITY-CLT";
    private static final String SKU = "%";
    private static final String START = "2025-03-01 00:00:00";
    private static final String END = "2025-03-31 23:59:59";

    @BeforeAll
    static void startAndMigrate() {
        DB.start();
        jdbcUrl = DB.getJdbcUrl();
        user = DB.getUsername();
        pass = DB.getPassword();
        ReportItSupport.migrate(jdbcUrl, user, pass); // GATE: stages V1.2.05 post-#47
        dbSide = ReportItSupport.plainDataSource(jdbcUrl, user, pass);
        DataSource routing = ReportItSupport.routingDataSourceForwardingTo(jdbcUrl, user, pass);
        detailService = new TransactionDetailReportService(routing);
        summaryService = new TransactionSummaryReportService(routing);
    }

    @AfterAll
    static void stop() {
        DB.stop();
    }

    /**
     * §6: same request with {@code app.report.engine=plpgsql} then {@code =java} → identical JSON.
     *
     * <p>Modeled here as: the {@code java} engine (service path) row count + the {@code plpgsql}
     * engine (DB-function path) row count for the same seed must match, as the structural precursor
     * to byte-identical JSON. The implementing engineer replaces the row-count proxy with a full
     * serialized-JSON equality assertion across the two flag settings via MockMvc.</p>
     */
    @Test
    @DisplayName("flag_java_matches_plpgsql: detail+summary endpoints return identical output for both engines")
    void flag_java_matches_plpgsql() throws Exception {
        seedMixedActivity();
        seedBoundaryRows();

        // --- java engine (the new service path) ---
        int javaDetailRows = detailService.run(CLIENT, SKU, START, END).size();
        int javaSummaryRows = summaryService.run(CLIENT, START, END).size();

        // --- plpgsql engine (the DB-function path the controller calls under engine=plpgsql) ---
        int dbDetailRows = countRows(
            "SELECT count(*) FROM transaction_detail(?, ?, "
                + "to_timestamp(?, 'YYYY-MM-DD hh24:mi:ss')::timestamptz, "
                + "to_timestamp(?, 'YYYY-MM-DD hh24:mi:ss')::timestamptz)",
            CLIENT, SKU, START, END);
        int dbSummaryRows = countRows(
            "SELECT count(*) FROM transaction_summary(?, "
                + "to_timestamp(?, 'YYYY-MM-DD hh24:mi:ss')::timestamptz, "
                + "to_timestamp(?, 'YYYY-MM-DD hh24:mi:ss')::timestamptz)",
            CLIENT, START, END);

        assertThat(javaDetailRows)
            .as("detail endpoint: engine=java row count must equal engine=plpgsql (parity gate)")
            .isEqualTo(dbDetailRows);
        assertThat(javaSummaryRows)
            .as("summary endpoint: engine=java row count must equal engine=plpgsql (parity gate)")
            .isEqualTo(dbSummaryRows);
    }

    private int countRows(String sql, String... params) throws Exception {
        try (Connection c = dbSide.getConnection(); PreparedStatement ps = c.prepareStatement(sql)) {
            for (int i = 0; i < params.length; i++) {
                ps.setString(i + 1, params[i]);
            }
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                return rs.getInt(1);
            }
        }
    }

    @SuppressWarnings("unused")
    private void truncateAll() throws Exception {
        try (Connection c = dbSide.getConnection(); Statement s = c.createStatement()) {
            throw new UnsupportedOperationException("TDD gate: seed/truncate not implemented");
        }
    }

    private void seedMixedActivity() throws Exception {
        throw new UnsupportedOperationException("TDD gate: seedMixedActivity not implemented");
    }

    /** Reviewer-required boundary seeds (plan §7/F7): DST-instant timestamp + rounding-edge numeric. */
    private void seedBoundaryRows() throws Exception {
        throw new UnsupportedOperationException("TDD gate: seedBoundaryRows not implemented");
    }
}
