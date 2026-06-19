package net.aim_ai.wms.unit.config;

import net.aim_ai.wms.config.ScheduledJobConfig;
import net.aim_ai.wms.service.JobLockService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.boot.ApplicationRunner;
import org.springframework.mock.env.MockEnvironment;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;

/**
 * TDD-GATE FAILING TESTS (P3 §6) for the fail-loud startup guard
 * {@link ScheduledJobConfig#jobLockEngineCheck}.
 *
 * <p>RED until P3 is implemented: {@code jobLockEngineCheck(...)} throws
 * {@code UnsupportedOperationException("TDD gate: not implemented")} when invoked, so both tests
 * fail at the bean-factory call. GREEN == the positive allowlist guard in §3.2 throws
 * {@link IllegalStateException} for in-memory under a non-allowlisted profile and boots cleanly
 * under {@code integration}.</p>
 */
@ExtendWith(MockitoExtension.class)
@DisplayName("ScheduledJobConfig.jobLockEngineCheck — fail-loud in-memory guard (P3 §6)")
class JobLockEngineCheckTest {

    private ScheduledJobConfig config;
    private JobLockService jobLockService;

    @BeforeEach
    void setUp() {
        config = new ScheduledJobConfig();
        jobLockService = mock(JobLockService.class);
    }

    @Test
    @DisplayName("inMemory engine outside an allowlisted profile throws IllegalStateException")
    void inMemory_outsideAllowlistedProfile_throws() {
        MockEnvironment env = new MockEnvironment();
        env.setActiveProfiles("prod"); // NOT in {integration, integration-pg}

        ApplicationRunner runner = config.jobLockEngineCheck("in-memory", env, jobLockService);

        assertThatThrownBy(() -> runner.run(null))
            .as("in-memory under a non-allowlisted profile must fail loud at startup (§3.2)")
            .isInstanceOf(IllegalStateException.class)
            .hasMessageContaining("in-memory");
    }

    @Test
    @DisplayName("inMemory engine under the integration profile boots without throwing")
    void inMemory_underIntegrationProfile_boots() throws Exception {
        MockEnvironment env = new MockEnvironment();
        env.setActiveProfiles("integration"); // allowlisted test profile

        ApplicationRunner runner = config.jobLockEngineCheck("in-memory", env, jobLockService);

        // Must NOT throw — proves the guard does not false-positive on the real test profile (§3.2).
        runner.run(null);
    }
}
