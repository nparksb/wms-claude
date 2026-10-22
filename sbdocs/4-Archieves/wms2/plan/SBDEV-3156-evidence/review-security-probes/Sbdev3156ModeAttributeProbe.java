package net.aim_ai.wms.reviewprobe;

import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AdviceMode;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;

/** REVIEW-ONLY probe: is mode()/proxyTargetClass() able to de-arm the LIVE @PreAuthorize mechanism silently? */
class Sbdev3156ModeAttributeProbe {

    public static class Target {
        @PreAuthorize("hasRole('sb_admin')")
        public String staffOnly() { return "ran"; }
    }

    @Configuration
    @EnableMethodSecurity(prePostEnabled = true, securedEnabled = false, jsr250Enabled = false)
    static class AsShipped { @Bean Target t() { return new Target(); } }

    @Configuration
    @EnableMethodSecurity(prePostEnabled = true, securedEnabled = false, jsr250Enabled = false,
            mode = AdviceMode.ASPECTJ)
    static class AspectJMode { @Bean Target t() { return new Target(); } }

    @Configuration
    @EnableMethodSecurity(prePostEnabled = true, securedEnabled = false, jsr250Enabled = false,
            proxyTargetClass = true)
    static class ProxyTargetClass { @Bean Target t() { return new Target(); } }

    @Test
    void modeAttribute() {
        System.out.println("### MODE as-shipped      -> " + probe(AsShipped.class));
        System.out.println("### MODE ASPECTJ         -> " + probe(AspectJMode.class));
        System.out.println("### MODE proxyTargetClass-> " + probe(ProxyTargetClass.class));
        SecurityContextHolder.clearContext();
    }

    private static String probe(Class<?> cfg) {
        try (AnnotationConfigApplicationContext ctx = new AnnotationConfigApplicationContext(cfg)) {
            SecurityContextHolder.getContext().setAuthentication(
                    new UsernamePasswordAuthenticationToken("no-authority", "n/a", List.of()));
            try { return "ALLOWED(" + ctx.getBean(Target.class).staffOnly() + ")  <-- @PreAuthorize INERT"; }
            catch (Exception e) { return "DENIED(" + e.getClass().getSimpleName() + ")  <-- gate live"; }
        } catch (Exception boot) {
            return "CONTEXT FAILED TO START: " + boot.getClass().getSimpleName() + ": " + boot.getMessage();
        }
    }
}
