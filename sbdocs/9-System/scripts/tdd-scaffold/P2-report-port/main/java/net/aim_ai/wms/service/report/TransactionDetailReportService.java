package net.aim_ai.wms.service.report;

import java.util.List;
import javax.sql.DataSource;
import net.aim_ai.wms.repo.projection.TransactionDetailView;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;

/**
 * TDD-GATE SKELETON — P2 plan 260420-v2-port-plpgsql-functions-to-java.md §3.2.2.
 *
 * <p>Ports the {@code transaction_detail()} PL/pgSQL function body
 * ({@code V1.2.05:116-465}; byte-identical to the latest pre-UTC {@code V2.1.07} body, carrying the
 * zero-amount PICKING filter {@code sr.amount != 0} at {@code V1.2.05:318}, plan §2.2.1) into Java
 * parameterized native SQL. The 4 positional {@code USING $1,$2,$3,$4} params ({@code V1.2.05:467})
 * map to {@code :clientCode}, {@code :sku}, {@code :startDate}, {@code :endDate}. The inline
 * {@code stock_history($3)}/{@code ($4)} calls ({@code V1.2.05:392,458}) become the inlined
 * stock_history body with the start/end param substituted (inline ONLY — the in-memory-merge
 * alternative is rejected, plan §3.1 DECISION). Preserve {@code ORDER BY client_name, sku,
 * transaction_date} and the {@code UNION} (dedup, NOT {@code UNION ALL}) joins between the 6
 * branches.</p>
 *
 * <p>Tenant routing (plan §3.0): builds its {@link NamedParameterJdbcTemplate} over the
 * {@code tenantDynamicRoutingDataSource} bean, NOT the {@code @Primary}/landlord datasource.</p>
 *
 * <p>Option A (plan §3.2.2 / §3.3): the signature keeps {@code String} date params; the
 * {@code to_timestamp(:startDate, 'YYYY-MM-DD hh24:mi:ss')::timestamptz} parse stays inside the
 * ported SQL — zero TZ-locus change vs the post-UTC production path.</p>
 *
 * <p>Skeleton body throws so the parity ITs fail RED until the real SQL is ported. Do NOT port
 * real SQL here as part of the TDD gate.</p>
 */
@Service
public class TransactionDetailReportService {

    /** Built over the tenant routing datasource (plan §3.0). */
    private final NamedParameterJdbcTemplate jdbc;

    public TransactionDetailReportService(
            @Qualifier("tenantDynamicRoutingDataSource") DataSource routingDataSource) {
        this.jdbc = new NamedParameterJdbcTemplate(routingDataSource);
    }

    /**
     * Run the {@code transaction_detail} timeline report (plan §3.2.2 signature, Option A).
     *
     * @param clientCode client number — maps to {@code $1}
     * @param sku        SKU pattern — maps to {@code $2} (used as {@code i.item_nr LIKE $2})
     * @param startDate  raw start date string — maps to {@code $3}
     * @param endDate    raw end date string — maps to {@code $4}
     * @return one {@link TransactionDetailView} row per movement + BEGINNING + ENDING rows
     */
    public List<TransactionDetailView> run(String clientCode, String sku, String startDate, String endDate) {
        throw new UnsupportedOperationException("TDD gate: not implemented");
    }
}
