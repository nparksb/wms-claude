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
import net.aim_ai.wms.repo.projection.TransactionDetailView;
import net.aim_ai.wms.service.report.TransactionDetailReportService;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;

/**
 * TDD-GATE FAILING IT — {@code TransactionDetailReportService} parity vs the {@code V1.2.05}
 * {@code transaction_detail()} PL/pgSQL function (plan §6).
 *
 * <p><b>GATE-CLOSED:</b> runnable only after PR #47 merges {@code V1.2.05} to {@code develop} and
 * the pre-kickoff verify script exits 0 (see {@link ReportItSupport} and MANIFEST.md). Until then
 * the baseline branch lacks the {@code transaction_detail} function and the comparison side errors.
 * Once runnable: RED until the service SQL is ported; GREEN == plan §5/§6 acceptance.</p>
 *
 * <p>The seed helpers below are intentionally left as scaffolding stubs ({@code seed*()} throw) —
 * the implementing engineer fills them against the real tenant schema
 * ({@code item}/{@code stockrecord}/{@code billoflading_position}/{@code customerorder_position})
 * at port time. They MUST include the reviewer-required boundary rows (see
 * {@link #seedBoundaryRows}) so parity is not tested on trivial data only (plan §7/F7).</p>
 */
@DisplayName("P2 — TransactionDetailReportServiceIT (parity vs V1.2.05 transaction_detail)")
class TransactionDetailReportServiceIT {

    private static final PostgreSQLContainer<?> DB = ReportItSupport.newContainer();

    private static String jdbcUrl;
    private static String user;
    private static String pass;
    private static DataSource dbSide;
    private static TransactionDetailReportService service;

    private static final String CLIENT = "PARITY-CLT";
    private static final String SKU_PATTERN = "%";
    private static final String START = "2025-03-01 00:00:00";
    private static final String END = "2025-03-31 23:59:59";

    @BeforeAll
    static void startAndMigrate() {
        DB.start();
        jdbcUrl = DB.getJdbcUrl();
        user = DB.getUsername();
        pass = DB.getPassword();
        // GATE: post-#47 this stages V1.2.05 and creates transaction_detail(...) with timestamptz.
        ReportItSupport.migrate(jdbcUrl, user, pass);
        dbSide = ReportItSupport.plainDataSource(jdbcUrl, user, pass);
        DataSource routing = ReportItSupport.routingDataSourceForwardingTo(jdbcUrl, user, pass);
        service = new TransactionDetailReportService(routing);
    }

    @AfterAll
    static void stop() {
        DB.stop();
    }

    /** §6: Java service output == {@code SELECT * FROM transaction_detail(...)} over a mixed seed. */
    @Test
    @DisplayName("matchesDbFunction_overSeededDataset: Java path equals transaction_detail() row-for-row")
    void matchesDbFunction_overSeededDataset() throws Exception {
        seedMixedActivity();
        seedBoundaryRows();

        List<TransactionDetailView> javaRows = service.run(CLIENT, SKU_PATTERN, START, END);

        try (Connection c = dbSide.getConnection();
             PreparedStatement ps = c.prepareStatement(
                 "SELECT * FROM transaction_detail(?, ?, "
                     + "to_timestamp(?, 'YYYY-MM-DD hh24:mi:ss')::timestamptz, "
                     + "to_timestamp(?, 'YYYY-MM-DD hh24:mi:ss')::timestamptz)")) {
            ps.setString(1, CLIENT);
            ps.setString(2, SKU_PATTERN);
            ps.setString(3, START);
            ps.setString(4, END);
            try (ResultSet rs = ps.executeQuery()) {
                ReportParityComparator.assertParity(javaRows, rs, detailSchema());
            }
        }
    }

    /** §6: V2.1.07 zero-amount PICKING filter — amount=0 excluded, amount=5 included. */
    @Test
    @DisplayName("zeroAmountPickingFiltered: a PICKING stockrecord with amount=0 is excluded, amount=5 included")
    void zeroAmountPickingFiltered() throws Exception {
        seedPickingRow(0); // must be filtered (V1.2.05:318 sr.amount != 0)
        seedPickingRow(5); // must appear

        List<TransactionDetailView> javaRows = service.run(CLIENT, SKU_PATTERN, START, END);

        long pickingRows = javaRows.stream()
            .filter(r -> "Picked".equalsIgnoreCase(r.getTransaction_name()))
            .count();
        assertThat(pickingRows)
            .as("only the amount=5 PICKING row survives the zero-amount filter")
            .isEqualTo(1L);
    }

    /** §6: canceled-order row — customerorder_position state=800, amountpicked<>0 → 'Canceled' row, depleted_picked negative. */
    @Test
    @DisplayName("canceledOrderRowPresent: state=800 picked order yields a 'Canceled' row with negative depleted_picked")
    void canceledOrderRowPresent() throws Exception {
        seedCanceledOrder(); // customerorder_position state=800, amountpicked > 0

        List<TransactionDetailView> javaRows = service.run(CLIENT, SKU_PATTERN, START, END);

        TransactionDetailView canceled = javaRows.stream()
            .filter(r -> "Canceled".equalsIgnoreCase(r.getTransaction_name()))
            .findFirst()
            .orElse(null);
        assertThat(canceled).as("a 'Canceled' row must be present").isNotNull();
        assertThat(canceled.getDepleted_picked())
            .as("canceled-order depleted_picked is negative (depletion reversal)")
            .isNotNull()
            .satisfies(v -> assertThat(v.signum()).isNegative());
    }

    /** §6: exactly one BEGINNING and one ENDING inventory row per SKU. */
    @Test
    @DisplayName("beginningAndEndingRowsPresent: exactly one BEGINNING and one ENDING row per SKU")
    void beginningAndEndingRowsPresent() throws Exception {
        seedSingleSkuActivity();

        List<TransactionDetailView> javaRows = service.run(CLIENT, SKU_PATTERN, START, END);

        long beginning = javaRows.stream()
            .filter(r -> "BEGINNING".equalsIgnoreCase(r.getTransaction_name())).count();
        long ending = javaRows.stream()
            .filter(r -> "ENDING".equalsIgnoreCase(r.getTransaction_name())).count();
        assertThat(beginning).as("exactly one BEGINNING row").isEqualTo(1L);
        assertThat(ending).as("exactly one ENDING row").isEqualTo(1L);
    }

    // --- Column schema for the parity comparator (plan §5 a/c/d per-column policy) -----------

    private static List<ColumnSpec<TransactionDetailView>> detailSchema() {
        return List.of(
            new ColumnSpec<>("client_name", TransactionDetailView::getClient_name, "client_name", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("client_number", TransactionDetailView::getClient_number, "client_number", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("sku", TransactionDetailView::getSku, "sku", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("item_name", TransactionDetailView::getItem_name, "item_name", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("vintage", TransactionDetailView::getVintage, "vintage", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("volume", TransactionDetailView::getVolume, "volume", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("location_name", TransactionDetailView::getLocation_name, "location_name", Kind.OBJECT, NullPolicy.NULLABLE),
            // transaction_date is date_trunc('second',...) in the function (plan §5 d, V1.2.05:123).
            new ColumnSpec<>("transaction_date", TransactionDetailView::getTransaction_date, "transaction_date", Kind.TIMESTAMP_SECOND, NullPolicy.NULLABLE),
            new ColumnSpec<>("transaction_name", TransactionDetailView::getTransaction_name, "transaction_name", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("transaction_number", TransactionDetailView::getTransaction_number, "transaction_number", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("order_number", TransactionDetailView::getOrder_number, "order_number", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("package_number", TransactionDetailView::getPackage_number, "package_number", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("total", TransactionDetailView::getTotal, "total", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("received", TransactionDetailView::getReceived, "received", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("returned", TransactionDetailView::getReturned, "returned", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("adjustments", TransactionDetailView::getAdjustments, "adjustments", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("transfer", TransactionDetailView::getTransfer, "transfer", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("damaged", TransactionDetailView::getDamaged, "damaged", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("depleted_picked", TransactionDetailView::getDepleted_picked, "depleted_picked", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("depleted_club", TransactionDetailView::getDepleted_club, "depleted_club", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("shipped", TransactionDetailView::getShipped, "shipped", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("net_change", TransactionDetailView::getNet_change, "net_change", Kind.NUMERIC, NullPolicy.NULLABLE),
            new ColumnSpec<>("username", TransactionDetailView::getUsername, "username", Kind.OBJECT, NullPolicy.NULLABLE),
            new ColumnSpec<>("user_comment", TransactionDetailView::getUser_comment, "user_comment", Kind.OBJECT, NullPolicy.NULLABLE)
        );
    }

    // --- Seed stubs (implement at port time against the real tenant schema) ------------------

    private void truncateAll() throws Exception {
        try (Connection c = dbSide.getConnection(); Statement s = c.createStatement()) {
            // Implementing engineer: TRUNCATE the tables the report reads, RESTART IDENTITY.
            // e.g. s.execute("TRUNCATE stockrecord, billoflading_position, customerorder_position,
            //                 stockunit, item RESTART IDENTITY CASCADE");
            throw new UnsupportedOperationException("TDD gate: seed/truncate not implemented");
        }
    }

    private void seedMixedActivity() throws Exception {
        // Seed receiving/returns/picking/club/adjust/ship rows across the date window so all 6
        // UNION branches + BEGINNING/ENDING are exercised. MUST be deterministically ordered.
        throw new UnsupportedOperationException("TDD gate: seedMixedActivity not implemented");
    }

    /**
     * Reviewer-required boundary seeds (plan §7/F7 fidelity risk): parity must not be tested only
     * on trivial data. Seed BOTH:
     *   (1) a timezone-boundary timestamp — a movement at e.g. 2025-03-09 02:30:00 (US DST
     *       spring-forward instant) so the to_timestamp(...)::timestamptz parse + date_trunc on
     *       both the Java path and the DB function are compared across a DST edge;
     *   (2) a rounding-boundary numeric — an amount like 0.005 / 1.005 (numeric half-up scale edge)
     *       so the scale-insensitive BigDecimal compare (rule a) is exercised on a non-integer.
     */
    private void seedBoundaryRows() throws Exception {
        throw new UnsupportedOperationException("TDD gate: seedBoundaryRows not implemented");
    }

    private void seedPickingRow(int amount) throws Exception {
        throw new UnsupportedOperationException("TDD gate: seedPickingRow not implemented");
    }

    private void seedCanceledOrder() throws Exception {
        throw new UnsupportedOperationException("TDD gate: seedCanceledOrder not implemented");
    }

    private void seedSingleSkuActivity() throws Exception {
        throw new UnsupportedOperationException("TDD gate: seedSingleSkuActivity not implemented");
    }
}
