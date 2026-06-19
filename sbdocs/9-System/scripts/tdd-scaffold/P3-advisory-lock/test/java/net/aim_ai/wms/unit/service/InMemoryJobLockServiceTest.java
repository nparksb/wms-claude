package net.aim_ai.wms.unit.service;

import net.aim_ai.wms.service.InMemoryJobLockService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * TDD-GATE FAILING TESTS (P3 §6) for {@link InMemoryJobLockService}.
 *
 * <p>RED until P3 is implemented: the skeleton bodies throw
 * {@code UnsupportedOperationException("TDD gate: not implemented")}, so every test below fails
 * at the {@code tryLock}/{@code unlock}/{@code reset} call. GREEN == the in-memory engine behaves
 * per the {@link ConcurrentHashMap#putIfAbsent} contract in §3.1.3, including the no-auto-release
 * regression guard.</p>
 */
@ExtendWith(MockitoExtension.class)
@DisplayName("InMemoryJobLockService — per-JVM mutex contract (P3 §6)")
class InMemoryJobLockServiceTest {

    private static final long LOCK = 100L;

    private InMemoryJobLockService lockService;

    @BeforeEach
    void setUp() {
        lockService = new InMemoryJobLockService();
    }

    @Test
    @DisplayName("tryLock then tryLock returns false when the lock is already held")
    void tryLock_thenTryLock_returnsFalse() {
        assertThat(lockService.tryLock(LOCK))
            .as("first acquisition of a free lock succeeds")
            .isTrue();
        assertThat(lockService.tryLock(LOCK))
            .as("second acquisition of an already-held lock is refused (per-JVM contention)")
            .isFalse();
    }

    @Test
    @DisplayName("unlock then tryLock returns true when the lock has been released")
    void unlock_thenTryLock_returnsTrue() {
        assertThat(lockService.tryLock(LOCK)).isTrue();
        lockService.unlock(LOCK);
        assertThat(lockService.tryLock(LOCK))
            .as("after unlock the lock id is free again")
            .isTrue();
    }

    @Test
    @DisplayName("concurrent tryLocks yield exactly one winner (putIfAbsent thread-safety)")
    void concurrent_tryLocks_exactlyOneWinner() throws InterruptedException {
        int threads = 32;
        ExecutorService pool = Executors.newFixedThreadPool(threads);
        CountDownLatch ready = new CountDownLatch(threads);
        CountDownLatch start = new CountDownLatch(1);
        CountDownLatch done = new CountDownLatch(threads);
        AtomicInteger winners = new AtomicInteger(0);

        try {
            for (int i = 0; i < threads; i++) {
                pool.submit(() -> {
                    ready.countDown();
                    try {
                        start.await();
                        if (lockService.tryLock(LOCK)) {
                            winners.incrementAndGet();
                        }
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    } finally {
                        done.countDown();
                    }
                });
            }
            assertThat(ready.await(5, TimeUnit.SECONDS)).as("all worker threads ready").isTrue();
            start.countDown(); // release all threads to contend simultaneously
            assertThat(done.await(5, TimeUnit.SECONDS)).as("all worker threads finished").isTrue();
        } finally {
            pool.shutdownNow();
        }

        assertThat(winners.get())
            .as("ConcurrentHashMap.putIfAbsent guarantees exactly one acquirer under contention")
            .isEqualTo(1);
    }

    @Test
    @DisplayName("reset frees a leaked lock so a subsequent tryLock succeeds (no auto-release guard)")
    void reset_freesLeakedLock_thenTryLockSucceeds() {
        // Leak: acquire and deliberately never unlock (simulates a thrown assertion before finally).
        assertThat(lockService.tryLock(LOCK)).isTrue();
        assertThat(lockService.tryLock(LOCK))
            .as("the in-memory impl has NO auto-release — the leaked lock is still held")
            .isFalse();

        lockService.reset();

        assertThat(lockService.tryLock(LOCK))
            .as("reset() clears all held locks so the previously-leaked lock id is free (§3.1.3)")
            .isTrue();
    }
}
