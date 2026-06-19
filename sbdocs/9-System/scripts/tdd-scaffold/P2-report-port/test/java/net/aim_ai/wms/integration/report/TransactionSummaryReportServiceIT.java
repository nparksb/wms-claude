package net.aim_ai.wms.integration.report;

import static org.assertj.core.api.Assertions.assertThat;

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
import net.aim_ai.wms.repo.projection.TransactionSummaryView;
import net.aim_ai.wms.service.report.TransactionSummaryReportService;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;

/**
 * TDD-GATE FAILING IT — {@code TransactionSummaryReportService} parity vs the {@code V1.2.05}
 * {@code transaction_summary()} PL/pgSQL function (plan §6).
 *
 * <p><b>GATE-CLOSED:</b> runnable only after PR #47 merges {@code V1.2.05} to {@code develop} and
 * the pre-kickoff script exits 0 (see {@link ReportItSupport}, MANIFEST.md). RED until the service
 * SQL is ported; GREEN == plan §5/§6 acceptance.</p>
 */
@DisplayName("P2 — TransactionSummaryReportServiceIT (parity vs V1.2.05 transaction_summary)")
class TransactionSummaryReportServiceIT {

    private static final PostgreSQLContainer<?> DB = ReportItSupport.newContainer();

    private static String jdbcUrl;
    private static String user;
    private static String pass;
    private static DataSource dbSide;
    private static TransactionSummaryReportService service;

    private static final String CLIENT = "PARITY-CLT";
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
        service = new TransactionSummaryReportService(
            ReportItSupport.routingDataSourceForwardingTo(jdbcUrl, user, pass));
    }

    @AfterAll
    static void stop() {
        DB.stop();
    }

    /** §6: Java service output == {@code SELECT * FROM transaction_summary(...)} over a mixed seed. */
    @Test
    @DisplayName("matchesDbFunction_overSeededDataset: Java path equals transaction_summary() row-for-row")
    void matchesDbFunction_overSeededDataset() throws Exception {
        seedMixedActivity();
        seedBoundaryRows();

        List<TransactionSummaryView> javaRows = service.run(CLIENT, START, END);

        try (Connection c = dbSide.getConnection();
             PreparedStatement ps = c.prepareStatement(
                 "SELECT * FROM transaction_summary(?, "
                     + "to_timestamp(?, 'YYYY-MM-DD hh24:mi:ss')::timestamptz, "
                     + "to_timestamp(?, 'YYYY-MM-DD hh24:mi:ss')::timestamptz)")) {
            ps.setString(1, CLIENT);
            ps.setString(2, START);
            ps.setString(3, END);
            try (ResultSet rs = ps.executeQuery()) {
                ReportParityComparator.assertParity(javaRows, rs, summarySchema());
            }
        }
    }

    /** §6: canceled-order accounting — depleted_picked reflects only uncanceled picks. */
    @Test
    @DisplayName("canceledOrderAccounting: depleted_picked reflects only uncanceled picks (state=800 branch)")
    void canceledOrderAccounting() throws Exception {
        seedNormalPickingPlusCanceled(); // normal PICKING + a state=800 canceled customerorder_position

        List<TransactionSummaryView> javaRows = service.run(CLIENT, START, END);

        // Cross-check the Java rollup against the DB function's depleted_picked for the same seed —
        // the canceled branch must net out exactly as the PL/pgSQL accounting does.
        try (Connection c = dbSide.getConnection();
             PreparedStatement ps = c.prepareStatement(
                 "SELECT sku, depleted_picked FROM transaction_summary(?, "
                     + "to_timestamp(?, 'YYYY-MM-DD hh24:mi:ss')::timestamptz, "
                     + "to_timestamp(?, 'YYYY-MM-DD hh24:mi:ss')::timestamptz) ORDER BY wms_product_id")) {
            ps.setString(1, CLIENT);
            ps.setString(2, START);
            ps.setString(3, END);
            try (ResultSet rs = ps.executeQuery()) {
                int i = 0;
                while (rs.next()) {
                    assertThat(i).as("more DB rows than Java rows").isLessThan(javaRows.size());
                    TransactionSummaryView jr = javaRows.get(i++);
                    assertThat(jr.getDepleted_picked().compareTo(rs.getBigDecimal("depleted_picked")))
                        .as("depleted_picked accounting matches DB function for sku=" + jr.getSku())
                        .isZero();
                }
                assertThat(i).as("row count matches DB function").isEqualTo(javaRows.size());
            }
        }
    }

    private static List<ColumnSpec<TransactionSummaryView>> summarySchema() {
        return List.of(
            new ColumnSpec<>("client_name", TransactionSummaryView::getClient_name, "client_name", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("client_number", TransactionSummaryView::getClient_number, "client_number", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("product_name", TransactionSummaryView::getProduct_name, "product_name", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("sku", TransactionSummaryView::getSku, "sku", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("wms_product_id", TransactionSummaryView::getWms_product_id, "wms_product_id", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("vintage", TransactionSummaryView::getVintage, "vintage", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("volume", TransactionSummaryView::getVolume, "volume", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("beginning_inventory", TransactionSummaryView::getBeginning_inventory, "beginning_inventory", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("received", TransactionSummaryView::getReceived, "received", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("returned", TransactionSummaryView::getReturned, "returned", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("putaway", TransactionSummaryView::getPutaway, "putaway", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("adjustments", TransactionSummaryView::getAdjustments, "adjustments", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("damaged", TransactionSummaryView::getDamaged, "damaged", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("depleted_picked", TransactionSummaryView::getDepleted_picked, "depleted_picked", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("depleted_club", TransactionSummaryView::getDepleted_club, "depleted_club", Kind.NUMERIC, NullPolicy.NULLABLE),
            // shipped is CAST(sum(shipped) as int8) (V1.2.05:490) → BigInteger, compared as object.
            new ColumnSpec<>("shipped", TransactionSummaryView::getShipped, "shipped", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("ending_inventory", TransactionSummaryView::getEnding_inventory, "ending_inventory", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("net_change", TransactionSummaryView::getNet_change, "net_change", Kind.NUMERIC, NullPolicy.NULLABLE)
        );
    }

    @SuppressWarnings("unused")
    private void truncateAll() throws Exception {
        try (Connection c = dbSide.getConnection(); Statement s = c.createStatement()) {
            throw new UnsupportedOperationException("TDD gate: seed/truncate not implemented");
        }
    }

    private void seedMixedActivity() throws Exception {
        // Seed receiving/returns/putaway/adjust/damaged/picking/club/ship across the window so the
        // outer GROUP BY aggregates and both UNION branches are exercised.
        throw new UnsupportedOperationException("TDD gate: seedMixedActivity not implemented");
    }

    /**
     * Reviewer-required boundary seeds (plan §7/F7): timezone-boundary timestamp (DST instant within
     * the window so the beginning/ending stock_history($2)/($3) joins compare across the timestamptz
     * edge) and a rounding-boundary numeric for the scale-insensitive aggregate compare.
     */
    private void seedBoundaryRows() throws Exception {
        throw new UnsupportedOperationException("TDD gate: seedBoundaryRows not implemented");
    }

    private void seedNormalPickingPlusCanceled() throws Exception {
        throw new UnsupportedOperationException("TDD gate: seedNormalPickingPlusCanceled not implemented");
    }
}
