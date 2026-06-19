package net.aim_ai.wms.service;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Service;

import javax.sql.DataSource;
import java.sql.Connection;

/**
 * TDD-GATE SKELETON (P3 §3.1.2) — bodies intentionally throw so the IT fails RED.
 *
 * <p>Production default implementation. Renamed from the former {@code AdvisoryLockService}; the
 * GREEN step MUST restore the existing raw-JDBC ThreadLocal-connection-pinning body VERBATIM —
 * {@code landlordDataSource.getConnection()} → {@code SELECT pg_try_advisory_lock(?)} → pin the
 * physical {@link Connection} in {@link #lockedConnection}; {@code unlock} retrieves the pinned
 * connection, runs {@code SELECT pg_advisory_unlock(?)}, closes it, and clears the ThreadLocal.</p>
 *
 * <p>Do NOT "simplify" back to {@code @PersistenceContext}/{@code @Transactional}/EntityManager —
 * that reintroduces the connection-return-to-pool lock leak the current code was written to fix
 * (plan §2.1). The pinning semantic is load-bearing for the outbox dispatch path (plan §2.3).</p>
 */
@Service
@ConditionalOnProperty(name = "wms.job-lock.engine", havingValue = "postgres", matchIfMissing = true)
public class PostgresAdvisoryJobLockService implements JobLockService {

    @SuppressWarnings("unused") // used by the GREEN-step (verbatim) implementation
    private static final Logger LOG = LoggerFactory.getLogger(PostgresAdvisoryJobLockService.class);

    @SuppressWarnings("unused") // used by the GREEN-step (verbatim) implementation
    private final DataSource landlordDataSource;

    /** Holds the raw connection between tryLock() and unlock() on the same thread. */
    @SuppressWarnings("unused") // used by the GREEN-step (verbatim) implementation
    private final ThreadLocal<Connection> lockedConnection = new ThreadLocal<>();

    public PostgresAdvisoryJobLockService(@Qualifier("landlordDataSource") DataSource landlordDataSource) {
        this.landlordDataSource = landlordDataSource;
    }

    @Override
    public boolean tryLock(long lockId) {
        throw new UnsupportedOperationException("TDD gate: not implemented");
    }

    @Override
    public void unlock(long lockId) {
        throw new UnsupportedOperationException("TDD gate: not implemented");
    }
}
