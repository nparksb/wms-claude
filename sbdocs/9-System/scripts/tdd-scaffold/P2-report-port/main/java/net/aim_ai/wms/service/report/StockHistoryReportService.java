package net.aim_ai.wms.service.report;

import java.util.List;
import javax.sql.DataSource;
import net.aim_ai.wms.repo.projection.StockHistoryView;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;

/**
 * TDD-GATE SKELETON — P2 plan 260420-v2-port-plpgsql-functions-to-java.md §3.2.1.
 *
 * <p>INTERNAL ONLY — no public REST endpoint (plan §3.2.1, §8 open-Q1 RESOLVED). The
 * {@code stock_history} SQL is needed only as the inlined sub-SELECT inside
 * {@code transaction_detail}/{@code transaction_summary}. This service, if created at all, is
 * optional internal organization to hold the shared {@code SQL_STOCK_HISTORY} fragment — it is
 * NOT a public surface. {@code StockViewRepository.stockHistoryAfterAsOfDate} is deleted at port
 * time (plan §3.4).</p>
 *
 * <p>Tenant routing (plan §3.0 — most important correctness point): this service MUST execute
 * against the tenant routing datasource, NOT the {@code @Primary}/landlord datasource. It builds
 * its {@link NamedParameterJdbcTemplate} over the {@code tenantDynamicRoutingDataSource} bean — the
 * same {@code DataSource} that {@code tenantEntityManagerFactory} is built on at
 * {@code TenantDatabaseConfig.java:54-72}. A naive autowire of the unqualified/{@code @Primary}
 * bean would silently query the wrong (landlord) database.</p>
 *
 * <p>Date param is bound as a {@code String} consistent with Option A (plan §3.2.2) so the inlined
 * {@code to_timestamp(...)} parse matches the {@code transaction_*} services.</p>
 *
 * <p>This skeleton is intentionally NOT implemented: the body throws so the parity ITs fail RED
 * until the real {@code V1.2.05:59-101} SQL (every {@code ''} un-doubled, {@code $1 -> :asOfDate})
 * is ported. Do NOT port real SQL here as part of the TDD gate.</p>
 */
@Service
public class StockHistoryReportService {

    /** Built over the tenant routing datasource (plan §3.0). */
    private final NamedParameterJdbcTemplate jdbc;

    public StockHistoryReportService(
            @Qualifier("tenantDynamicRoutingDataSource") DataSource routingDataSource) {
        this.jdbc = new NamedParameterJdbcTemplate(routingDataSource);
    }

    /**
     * Run the {@code stock_history} report for a single as-of date.
     *
     * @param asOfDate raw date string (Option A, plan §3.2.2) parsed by {@code to_timestamp(...)}
     *                 inside the ported SQL — same locus as the post-UTC production path
     * @return one {@link StockHistoryView} row per SKU with activity (plan §2.2)
     */
    public List<StockHistoryView> run(String asOfDate) {
        throw new UnsupportedOperationException("TDD gate: not implemented");
    }
}
