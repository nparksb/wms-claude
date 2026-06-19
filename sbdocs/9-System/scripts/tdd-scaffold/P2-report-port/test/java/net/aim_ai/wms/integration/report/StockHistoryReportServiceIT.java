package net.aim_ai.wms.integration.report;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.List;
import javax.sql.DataSource;
import net.aim_ai.wms.common.report.ReportParityComparator;
import net.aim_ai.wms.common.report.ReportParityComparator.ColumnSpec;
import net.aim_ai.wms.common.report.ReportParityComparator.Kind;
import net.aim_ai.wms.common.report.ReportParityComparator.NullPolicy;
import net.aim_ai.wms.repo.projection.StockHistoryView;
import net.aim_ai.wms.service.report.StockHistoryReportService;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;

/**
 * TDD-GATE FAILING IT — {@code StockHistoryReportService} parity vs the {@code V1.2.05}
 * {@code stock_history()} PL/pgSQL function (plan §6).
 *
 * <p><b>APPROACH NOTE (plan §3.2.1 / §8 open-Q1 RESOLVED).</b> {@code stock_history} is
 * INTERNAL-ONLY — it has no production caller and gets no public REST endpoint; its SQL lives only
 * as the inlined fragment inside {@code transaction_detail}/{@code transaction_summary}. The plan
 * keeps {@code StockHistoryReportService} purely as an optional fragment-holder. This IT therefore
 * tests the fragment via the service's package-level {@code run(...)} <b>test hook</b> (NOT a public
 * REST surface) — exactly the "thin test hook" the plan implies — comparing it to
 * {@code SELECT * FROM stock_history(:d)}. This is also the §5 Phase A H2-portability spike target.</p>
 *
 * <p><b>GATE-CLOSED:</b> runnable only after PR #47 merges {@code V1.2.05} to {@code develop} and
 * the pre-kickoff script exits 0 (see {@link ReportItSupport}, MANIFEST.md). RED until the service
 * SQL is ported.</p>
 */
@DisplayName("P2 — StockHistoryReportServiceIT (parity vs V1.2.05 stock_history)")
class StockHistoryReportServiceIT {

    private static final PostgreSQLContainer<?> DB = ReportItSupport.newContainer();

    private static String jdbcUrl;
    private static String user;
    private static String pass;
    private static DataSource dbSide;
    private static StockHistoryReportService service;

    private static final String AS_OF = "2025-03-01 00:00:00";

    @BeforeAll
    static void startAndMigrate() {
        DB.start();
        jdbcUrl = DB.getJdbcUrl();
        user = DB.getUsername();
        pass = DB.getPassword();
        ReportItSupport.migrate(jdbcUrl, user, pass); // GATE: stages V1.2.05 post-#47
        dbSide = ReportItSupport.plainDataSource(jdbcUrl, user, pass);
        service = new StockHistoryReportService(
            ReportItSupport.routingDataSourceForwardingTo(jdbcUrl, user, pass));
    }

    @AfterAll
    static void stop() {
        DB.stop();
    }

    /** §6: Java fragment output == {@code SELECT * FROM stock_history(:d)} over a mixed seed. */
    @Test
    @DisplayName("matchesDbFunction_overSeededDataset: Java path equals stock_history() row-for-row")
    void matchesDbFunction_overSeededDataset() throws Exception {
        seedMixedActivity();
        seedBoundaryRows();

        List<StockHistoryView> javaRows = service.run(AS_OF);

        try (Connection c = dbSide.getConnection();
             PreparedStatement ps = c.prepareStatement(
                 "SELECT * FROM stock_history("
                     + "to_timestamp(?, 'YYYY-MM-DD hh24:mi:ss')::timestamptz)")) {
            ps.setString(1, AS_OF);
            try (ResultSet rs = ps.executeQuery()) {
                ReportParityComparator.assertParity(javaRows, rs, stockHistorySchema());
            }
        }
    }

    private static List<ColumnSpec<StockHistoryView>> stockHistorySchema() {
        // stock_history columns coalesce the activity aggregates to 0 (plan §2.2) — COALESCED policy.
        return List.of(
            new ColumnSpec<>("item_id", StockHistoryView::getItem_id, "item_id", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("item_nr", StockHistoryView::getItem_nr, "item_nr", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("total_stock_today", StockHistoryView::getTotal_stock_today, "total_stock_today", Kind.NUMERIC, NullPolicy.COALESCED),
            new ColumnSpec<>("received", StockHistoryView::getReceived, "received", Kind.NUMERIC, NullPolicy.COALESCED),
            new ColumnSpec<>("returned", StockHistoryView::getReturned, "returned", Kind.NUMERIC, NullPolicy.COALESCED),
            new ColumnSpec<>("shipped", StockHistoryView::getShipped, "shipped", Kind.OBJECT, NullPolicy.COALESCED),
            new ColumnSpec<>("adjustments", StockHistoryView::getAdjustments, "adjustments", Kind.NUMERIC, NullPolicy.COALESCED),
            new ColumnSpec<>("historical_stock", StockHistoryView::getHistorical_stock, "historical_stock", Kind.NUMERIC, NullPolicy.COALESCED)
        );
    }

    @SuppressWarnings("unused")
    private void truncateAll() throws Exception {
        try (Connection c = dbSide.getConnection(); Statement s = c.createStatement()) {
            throw new UnsupportedOperationException("TDD gate: seed/truncate not implemented");
        }
    }

    private void seedMixedActivity() throws Exception {
        // Seed stockrecord (received/returned/adjusted) + billoflading_position (shipped CLOSED)
        // rows with sr.created > as_of so all aggregate sub-SELECTs are exercised.
        throw new UnsupportedOperationException("TDD gate: seedMixedActivity not implemented");
    }

    /**
     * Reviewer-required boundary seeds (plan §7/F7): a timezone-boundary timestamp (a DST
     * spring-forward instant near the as-of cutoff so {@code sr.created > $1} is compared across the
     * timestamptz edge) and a rounding-boundary numeric (e.g. amount 0.005) for the scale-insensitive
     * BigDecimal compare.
     */
    private void seedBoundaryRows() throws Exception {
        throw new UnsupportedOperationException("TDD gate: seedBoundaryRows not implemented");
    }
}
