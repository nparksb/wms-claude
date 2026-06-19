package net.aim_ai.wms.config;

import net.aim_ai.wms.service.JobLockService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationRunner;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;

import java.util.Set;

/**
 * TDD-GATE SKELETON (P3 §3.2) — the {@code jobLockEngineCheck} body intentionally throws so the
 * guard test fails RED.
 *
 * <p>Fail-loud startup check: if the in-memory job-lock engine is active under a profile that is
 * NOT in the positive allowlist, the {@link ApplicationRunner} must throw
 * {@link IllegalStateException} (context fails to boot). Membership is checked by EXACT profile
 * name via {@link Environment#getActiveProfiles()} — NOT a substring scan, NOT a non-existent
 * {@code h2}/{@code test} profile (plan §3.2).</p>
 *
 * <p><b>GREEN-step body (do NOT implement now):</b>
 * <pre>
 *   Set&lt;String&gt; allowedInMemoryProfiles = Set.of("integration", "integration-pg");
 *   return args -&gt; {
 *       if ("in-memory".equals(engine)) {
 *           boolean permitted = Arrays.stream(environment.getActiveProfiles())
 *                   .anyMatch(allowedInMemoryProfiles::contains);
 *           if (!permitted) {
 *               throw new IllegalStateException("wms.job-lock.engine=in-memory is only valid under "
 *                   + "the test profiles " + allowedInMemoryProfiles + " (active: "
 *                   + Arrays.toString(environment.getActiveProfiles())
 *                   + "). In production, locks MUST be postgres-backed.");
 *           }
 *       }
 *       LOG.info("Job lock engine: {} (impl: {})", engine, jobLockService.getClass().getSimpleName());
 *   };
 * </pre>
 */
@Configuration
public class ScheduledJobConfig {

    @SuppressWarnings("unused") // used by the GREEN-step implementation
    private static final Logger LOG = LoggerFactory.getLogger(ScheduledJobConfig.class);

    /** Exact profile names permitted to use the in-memory engine. Membership, not substring. */
    @SuppressWarnings("unused") // used by the GREEN-step implementation
    static final Set<String> ALLOWED_IN_MEMORY_PROFILES = Set.of("integration", "integration-pg");

    @Bean
    public ApplicationRunner jobLockEngineCheck(
            @Value("${wms.job-lock.engine:postgres}") String engine,
            Environment environment,
            JobLockService jobLockService) {
        throw new UnsupportedOperationException("TDD gate: not implemented");
    }
}
