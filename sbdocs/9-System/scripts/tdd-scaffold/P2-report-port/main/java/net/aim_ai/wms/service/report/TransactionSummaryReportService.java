package net.aim_ai.wms.service.report;

import java.util.List;
import javax.sql.DataSource;
import net.aim_ai.wms.repo.projection.TransactionSummaryView;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;

/**
 * TDD-GATE SKELETON — P2 plan 260420-v2-port-plpgsql-functions-to-java.md §3.2.3.
 *
 * <p>Ports the {@code transaction_summary()} PL/pgSQL function body
 * ({@code V1.2.05:480-604}; byte-identical to the latest pre-UTC {@code V1.1.04} body, plan §2.2.1)
 * into Java parameterized native SQL. The 3 positional {@code USING $1,$2,$3} params
 * ({@code V1.2.05:606}) map to {@code :clientCode}, {@code :startDate}, {@code :endDate}.
 * <strong>Note the inline {@code stock_history} here uses {@code $2}/{@code $3}</strong>
 * ({@code LEFT JOIN stock_history($2)}/{@code ($3)} at {@code V1.2.05:558,560}), NOT {@code $3}/
 * {@code $4} as in {@code transaction_detail}. Preserve the outer {@code GROUP BY} and
 * {@code order by wms_product_id} ({@code V1.2.05:604}); the single ANSI cast
 * {@code CAST(sum(shipped) as int8)} ({@code V1.2.05:490}) is H2-portable as-is.</p>
 *
 * <p>Tenant routing (plan §3.0): builds its {@link NamedParameterJdbcTemplate} over the
 * {@code tenantDynamicRoutingDataSource} bean, NOT the {@code @Primary}/landlord datasource.</p>
 *
 * <p>Option A (plan §3.2.2 / §3.3): the signature keeps {@code String} date params; the
 * {@code to_timestamp(...)::timestamptz} parse stays inside the ported SQL.</p>
 *
 * <p>Skeleton body throws so the parity ITs fail RED until the real SQL is ported. Do NOT port
 * real SQL here as part of the TDD gate.</p>
 */
@Service
public class TransactionSummaryReportService {

    /** Built over the tenant routing datasource (plan §3.0). */
    private final NamedParameterJdbcTemplate jdbc;

    public TransactionSummaryReportService(
            @Qualifier("tenantDynamicRoutingDataSource") DataSource routingDataSource) {
        this.jdbc = new NamedParameterJdbcTemplate(routingDataSource);
    }

    /**
     * Run the {@code transaction_summary} per-SKU rollup report (plan §3.2.3 signature, Option A).
     *
     * @param clientCode client number — maps to {@code $1}
     * @param startDate  raw start date string — maps to {@code $2}
     * @param endDate    raw end date string — maps to {@code $3}
     * @return one {@link TransactionSummaryView} row per SKU
     */
    public List<TransactionSummaryView> run(String clientCode, String startDate, String endDate) {
        throw new UnsupportedOperationException("TDD gate: not implemented");
    }
}
