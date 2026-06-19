package net.aim_ai.wms.service;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Service;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

/**
 * TDD-GATE SKELETON (P3 §3.1.3) — bodies intentionally throw so the behavioural tests fail RED.
 *
 * <p>Test/H2-only per-JVM mutex. Adequate for tests where one JVM runs both the job and the
 * assertion. NOT a distributed lock — never deploy to production (guarded by the
 * {@code @ConditionalOnProperty} below + the startup allowlist check in
 * {@code ScheduledJobConfig#jobLockEngineCheck}).</p>
 *
 * <p><b>Implementation note for the GREEN step (do NOT implement now):</b> the real body backs
 * {@code heldLocks} with {@link ConcurrentHashMap#putIfAbsent} semantics — {@code tryLock} returns
 * {@code heldLocks.putIfAbsent(lockId, Boolean.TRUE) == null}; {@code unlock} does
 * {@code heldLocks.remove(lockId)}; {@code reset} does {@code heldLocks.clear()}. This impl has
 * NO auto-release-on-crash — a leaked lock persists for the JVM lifetime, hence {@code reset()}.</p>
 */
@Service
@ConditionalOnProperty(name = "wms.job-lock.engine", havingValue = "in-memory")
public class InMemoryJobLockService implements JobLockService {

    @SuppressWarnings("unused") // populated by the GREEN-step implementation
    private final ConcurrentMap<Long, Boolean> heldLocks = new ConcurrentHashMap<>();

    @Override
    public boolean tryLock(long lockId) {
        throw new UnsupportedOperationException("TDD gate: not implemented");
    }

    @Override
    public void unlock(long lockId) {
        throw new UnsupportedOperationException("TDD gate: not implemented");
    }

    /**
     * TEST-ONLY. Clears all held locks. The in-memory impl has NO auto-release — a lock leaked by
     * one test (no unlock in finally, or a thrown assertion before unlock) stays held and silently
     * breaks the next test that needs that lock id. Wire into the integration test base / a
     * {@code @BeforeEach} so each test starts clean. Plan §3.1.3.
     */
    public void reset() {
        throw new UnsupportedOperationException("TDD gate: not implemented");
    }
}
