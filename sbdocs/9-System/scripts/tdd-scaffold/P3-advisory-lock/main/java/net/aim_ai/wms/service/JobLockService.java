package net.aim_ai.wms.service;

/**
 * Engine-agnostic distributed job lock abstraction (P3 — replace pg_advisory_lock for test portability).
 *
 * <p>Extracted from the former concrete {@code AdvisoryLockService} so scheduled-job tests can run on
 * H2 (in-memory engine) while production keeps the PostgreSQL session-level advisory-lock semantics
 * verbatim. See plan §3.1.1.</p>
 *
 * <p>Implementations:</p>
 * <ul>
 *   <li>{@link PostgresAdvisoryJobLockService} — production default; raw-JDBC {@code pg_try_advisory_lock}
 *       with a ThreadLocal-pinned physical connection (the pinning MUST be preserved, plan §2.1).</li>
 *   <li>{@link InMemoryJobLockService} — test-only per-JVM mutex; NO auto-release on crash (plan §3.1.3).</li>
 * </ul>
 */
public interface JobLockService {

    /**
     * Try to acquire the lock identified by {@code lockId} (non-blocking).
     *
     * @param lockId unique lock identifier (use constants from {@link JobLockId})
     * @return {@code true} if acquired, {@code false} if already held by another session
     */
    boolean tryLock(long lockId);

    /**
     * Release the lock acquired by {@link #tryLock} on this thread.
     *
     * @param lockId the lock identifier to release
     */
    void unlock(long lockId);

    /**
     * Stable lock IDs for each scheduled job. These must never change — they identify the lock
     * across replicas. Carried verbatim from the former {@code AdvisoryLockService.JobLockId}
     * (all 8 constants, same names, same {@code long} values). Plan §3.1.1.
     */
    final class JobLockId {
        public static final long ORDER_RELEASE = 100001L;
        public static final long REPLENISH_ORDER = 100002L;
        public static final long CLEAN_UP_MESSAGES = 100003L;
        public static final long STOCK_SUMMARY_EXPORT = 100004L;
        public static final long RELEASE_EXPIRED_PICKING = 100005L;
        public static final long STALE_CLUB_BATCH_CLEANUP = 100006L;
        public static final long CLEANUP_REST_IDEMPOTENCY = 100007L;
        public static final long OUTBOX_DISPATCHER = 100008L; // SBDEV-2221

        private JobLockId() {}
    }
}
