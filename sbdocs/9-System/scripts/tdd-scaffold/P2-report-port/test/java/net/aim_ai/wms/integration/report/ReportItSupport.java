package net.aim_ai.wms.integration.report;

import java.io.IOException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import javax.sql.DataSource;
import org.flywaydb.core.Flyway;
import org.mockito.Mockito;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

/**
 * TDD-GATE TEST SUPPORT — shared Testcontainers + Flyway harness for the three report parity ITs
 * (plan 260420-v2-port-plpgsql-functions-to-java.md §5 Phase A / §6).
 *
 * <p><b>GATE-CLOSED dependency.</b> The parity ITs compare the Java services' output to the
 * {@code V1.2.05} {@code timestamptz} report functions ({@code stock_history},
 * {@code transaction_detail}, {@code transaction_summary}). {@code V1.2.05__utc_update_functions.sql}
 * ships via PR #47 ({@code feature/utc-timezone}) and is NOT on {@code develop} yet. Flyway here
 * migrates the top-level {@code V*.sql} scripts from {@code src/main/resources/db/migration}; until
 * #47 merges that folder will NOT contain {@code V1.2.05}, the three functions won't exist, and the
 * {@code SELECT * FROM transaction_detail(...)} comparison side will fail. The pre-kickoff verify
 * script {@code verify-260420-...-prekickoff.sh} must exit 0 (PR #47 merged, {@code timestamptz}
 * signatures present, §2.2.1 provenance re-confirmed) before these ITs are trusted. See MANIFEST.md
 * §"GATE-CLOSED dependency".</p>
 *
 * <p>Tenant routing (plan §3.0): {@link #routingDataSourceForwardingTo} returns a mock
 * {@code tenantDynamicRoutingDataSource} whose {@code getConnection()} forwards to the
 * Testcontainers PostgreSQL instance — the same shape as {@code TestDatabaseConfig:25-45}, but on
 * real PostgreSQL so {@code timestamptz} fidelity is exercised (the H2 lane structurally cannot vet
 * it — plan §2.3 / §3.0 fidelity caveat). The services build their {@code NamedParameterJdbcTemplate}
 * over this bean, so they route to the same DB the comparison query runs against.</p>
 */
final class ReportItSupport {

    private ReportItSupport() {
    }

    /** Postgres 12, matching the rest of the suite ({@code AppPostgresDBContainer}). */
    @SuppressWarnings("resource")
    static PostgreSQLContainer<?> newContainer() {
        return new PostgreSQLContainer<>("postgres:12")
            .withDatabaseName("wms_test")
            .withUsername("test")
            .withPassword("test");
    }

    /**
     * Migrate ONLY the top-level production {@code V*.sql} scripts into the container, mirroring
     * production's non-recursive scan (same approach as {@code OutboxItFlyway.migrateTopLevel}).
     * Post-#47 this includes {@code V1.2.05__utc_update_functions.sql}, which (re)creates the three
     * report functions with {@code timestamptz} signatures.
     */
    static void migrate(String jdbcUrl, String user, String pass) {
        try {
            Path source = Path.of("src/main/resources/db/migration");
            Path staged = Files.createTempDirectory("p2-report-flyway-");
            staged.toFile().deleteOnExit();
            try (DirectoryStream<Path> stream = Files.newDirectoryStream(source, "*.sql")) {
                for (Path sql : stream) {
                    if (Files.isRegularFile(sql)) {
                        Files.copy(sql, staged.resolve(sql.getFileName()),
                            StandardCopyOption.REPLACE_EXISTING);
                    }
                }
            }
            // Some production scripts (e.g. V2.1.14 CREATE INDEX CONCURRENTLY) cannot run inside a
            // transaction under the programmatic flyway-core API — same harness knob OutboxItFlyway
            // documents.
            Flyway.configure()
                .dataSource(jdbcUrl, user, pass)
                .locations("filesystem:" + staged.toAbsolutePath())
                .executeInTransaction(false)
                .load()
                .migrate();
        } catch (IOException e) {
            throw new RuntimeException("Failed to stage report-IT Flyway migrations", e);
        }
    }

    /** A plain pooled-less DataSource pointing directly at the container (used by the DB query side). */
    static DataSource plainDataSource(String jdbcUrl, String user, String pass) {
        DriverManagerDataSource ds = new DriverManagerDataSource(jdbcUrl, user, pass);
        ds.setDriverClassName("org.postgresql.Driver");
        return ds;
    }

    /**
     * Mock {@code tenantDynamicRoutingDataSource} whose connections forward to the container —
     * mirrors {@code TestDatabaseConfig} so the services' {@code @Qualifier} wiring (plan §3.0)
     * resolves identically. Routing-key resolution is NOT exercised here (mock), but on the real PG
     * lane SQL + {@code timestamptz} fidelity IS (plan §3.0 fidelity caveat).
     */
    static DataSource routingDataSourceForwardingTo(String jdbcUrl, String user, String pass) {
        DataSource mock = Mockito.mock(DataSource.class);
        try {
            Mockito.when(mock.getConnection()).thenAnswer(inv -> open(jdbcUrl, user, pass));
            Mockito.when(mock.getConnection(Mockito.anyString(), Mockito.anyString()))
                .thenAnswer(inv -> open(jdbcUrl, user, pass));
        } catch (SQLException e) {
            throw new RuntimeException(e);
        }
        return mock;
    }

    private static Connection open(String jdbcUrl, String user, String pass) throws SQLException {
        return DriverManager.getConnection(jdbcUrl, user, pass);
    }
}
