package net.aim_ai.wms.service;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * TDD-GATE FAILING IT (P3 §6) for {@link PostgresAdvisoryJobLockService} — the only integration test.
 *
 * <p>Self-contained Testcontainers PostgreSQL (mirrors {@code OutboxClaimOrderingIT}): starts a real
 * Postgres container and drives the production lock service against it. No Flyway / multi-tenant
 * context is required — advisory locks need no schema.</p>
 *
 * <p>RED until P3 is implemented: the skeleton {@code tryLock}/{@code unlock} bodies throw
 * {@code UnsupportedOperationException("TDD gate: not implemented")}. GREEN == the verbatim
 * raw-JDBC ThreadLocal-connection-pinning body of §3.1.2 reproduces real {@code pg_try_advisory_lock}
 * semantics, including session-level cross-connection contention and connection pinning.</p>
 */
@DisplayName("PostgresAdvisoryJobLockServiceIT — real pg_advisory_lock semantics (P3 §6)")
class PostgresAdvisoryJobLockServiceIT {

    private static final long LOCK = 999001L;

    @SuppressWarnings("resource")
    private static final PostgreSQLContainer<?> DB =
        new PostgreSQLContainer<>("postgres:12")
            .withDatabaseName("wms_test")
            .withUsername("test")
            .withPassword("test");

    @BeforeAll
    static void startDb() {
        DB.start();
    }

    @AfterAll
    static void stopDb() {
        DB.stop();
    }

    /**
     * A single-connection DataSource: every {@link #getConnection()} returns the SAME physical
     * connection. This lets the test prove the ThreadLocal-pinning semantic — unlock() must release
     * the lock on the very connection tryLock() pinned, not a fresh one. (A real pool would round-trip
     * connections; the production guarantee under test is "same physical connection across the pair".)
     */
    private static final class SingleConnectionDataSource implements DataSource {
        private final Connection connection;

        SingleConnectionDataSource(Connection connection) {
            this.connection = connection;
        }

        @Override public Connection getConnection() {
            // Wrap so close() inside the service does not actually close the shared connection.
            return (Connection) java.lang.reflect.Proxy.newProxyInstance(
                Connection.class.getClassLoader(),
                new Class<?>[]{Connection.class},
                new NonClosingConnection(connection));
        }

        @Override public Connection getConnection(String username, String password) {
            return getConnection();
        }

        // --- unused DataSource surface ---
        @Override public java.io.PrintWriter getLogWriter() { return null; }
        @Override public void setLogWriter(java.io.PrintWriter out) { }
        @Override public void setLoginTimeout(int seconds) { }
        @Override public int getLoginTimeout() { return 0; }
        @Override public java.util.logging.Logger getParentLogger() { return null; }
        @Override public <T> T unwrap(Class<T> iface) { return null; }
        @Override public boolean isWrapperFor(Class<?> iface) { return false; }
    }

    private static DataSource newConnectionDataSource() throws SQLException {
        Connection c = java.sql.DriverManager.getConnection(
            DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        return new SingleConnectionDataSource(c);
    }

    @Test
    @DisplayName("tryLock on the same session acquires the lock exactly once")
    void tryLock_sameSession_acquiresOnce() throws SQLException {
        PostgresAdvisoryJobLockService svc =
            new PostgresAdvisoryJobLockService(newConnectionDataSource());

        assertThat(svc.tryLock(LOCK))
            .as("first acquisition of a free advisory lock succeeds")
            .isTrue();

        // Verify server-side the advisory lock is actually held.
        try (Connection probe = java.sql.DriverManager.getConnection(
                DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
             PreparedStatement ps = probe.prepareStatement(
                "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory'")) {
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                assertThat(rs.getInt(1))
                    .as("pg_locks shows the held advisory lock")
                    .isGreaterThanOrEqualTo(1);
            }
        }
        svc.unlock(LOCK);
    }

    @Test
    @DisplayName("tryLock from a different connection contends and returns false while held")
    void tryLock_differentConnection_contends() throws SQLException {
        PostgresAdvisoryJobLockService holder =
            new PostgresAdvisoryJobLockService(newConnectionDataSource());
        PostgresAdvisoryJobLockService contender =
            new PostgresAdvisoryJobLockService(newConnectionDataSource());

        assertThat(holder.tryLock(LOCK))
            .as("holder acquires the session-level advisory lock")
            .isTrue();
        assertThat(contender.tryLock(LOCK))
            .as("a second physical connection cannot acquire the same advisory lock (real PG contention)")
            .isFalse();

        holder.unlock(LOCK);
        assertThat(contender.tryLock(LOCK))
            .as("once the holder releases, the contender can acquire")
            .isTrue();
        contender.unlock(LOCK);
    }

    @Test
    @DisplayName("tryLock pins the connection so unlock releases on the same physical connection")
    void tryLock_pinsConnection_unlockReleasesSameConnection() throws SQLException {
        PostgresAdvisoryJobLockService svc =
            new PostgresAdvisoryJobLockService(newConnectionDataSource());

        assertThat(svc.tryLock(LOCK)).isTrue();
        svc.unlock(LOCK); // must run pg_advisory_unlock on the SAME pinned connection (§2.1)

        // If unlock released the lock on the pinned connection, the lock is now fully free
        // and re-acquirable from a fresh connection — proving no leak.
        PostgresAdvisoryJobLockService reAcquirer =
            new PostgresAdvisoryJobLockService(newConnectionDataSource());
        assertThat(reAcquirer.tryLock(LOCK))
            .as("unlock released the session lock on the pinned connection — no leak, re-acquirable (§2.1)")
            .isTrue();
        reAcquirer.unlock(LOCK);
    }

    /**
     * Connection wrapper whose {@code close()} is a no-op, so the production service's
     * {@code conn.close()} returns the connection to "the pool" (here: keeps it alive) instead of
     * tearing down the shared physical connection mid-test.
     */
    private static final class NonClosingConnection implements java.lang.reflect.InvocationHandler {
        // Placeholder — see factory below; kept as a nested type to satisfy the reference above.
        private NonClosingConnection(Connection delegate) { this.delegate = delegate; }
        private final Connection delegate;

        @Override public Object invoke(Object proxy, java.lang.reflect.Method method, Object[] args)
                throws Throwable {
            if ("close".equals(method.getName())) {
                return null; // no-op: keep the shared physical connection alive
            }
            return method.invoke(delegate, args);
        }
    }
}
