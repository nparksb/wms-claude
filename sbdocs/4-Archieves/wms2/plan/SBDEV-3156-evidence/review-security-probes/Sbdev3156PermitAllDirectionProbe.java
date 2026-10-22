package net.aim_ai.wms.reviewprobe;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.assertThatCode;

import jakarta.annotation.security.DenyAll;
import jakarta.annotation.security.PermitAll;
import jakarta.annotation.security.RolesAllowed;
import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.access.annotation.Secured;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

/**
 * REVIEW-ONLY probe (lane-security, SBDEV-3156). Not part of the change under review.
 * Measures the ACTUAL runtime direction of flipping securedEnabled/jsr250Enabled to false, on the
 * real spring-security 6.5.7 on this project's classpath.
 */
class Sbdev3156PermitAllDirectionProbe {

    public static class Target {
        @PermitAll
        public String permitAll() { return "permitAll-ran"; }

        @RolesAllowed("sb_admin")
        public String rolesAllowed() { return "rolesAllowed-ran"; }

        @DenyAll
        public String denyAll() { return "denyAll-ran"; }

        @Secured("ROLE_sb_admin")
        public String secured() { return "secured-ran"; }

        @PreAuthorize("hasRole('sb_admin')")
        public String preAuthorize() { return "preAuthorize-ran"; }

        // class-level @PreAuthorize interaction: method carries a PERMIT
        public String unannotated() { return "unannotated-ran"; }
    }

    @PreAuthorize("hasRole('sb_admin')")
    public static class ClassGatedTarget {
        /** the interesting case: a PERMIT sitting under a class-level DENY */
        @PermitAll
        public String permitAllUnderClassPreAuthorize() { return "ran"; }
    }

    @Configuration
    @EnableMethodSecurity(prePostEnabled = true, securedEnabled = true, jsr250Enabled = true)
    static class AllThreeOn {
        @Bean Target target() { return new Target(); }
        @Bean ClassGatedTarget classGated() { return new ClassGatedTarget(); }
    }

    @Configuration
    @EnableMethodSecurity(prePostEnabled = true, securedEnabled = false, jsr250Enabled = false)
    static class PrePostOnly {
        @Bean Target target() { return new Target(); }
        @Bean ClassGatedTarget classGated() { return new ClassGatedTarget(); }
    }

    @AfterEach
    void clear() { SecurityContextHolder.clearContext(); }

    /** the OMS integration principal shape: authenticated, ZERO authorities. */
    private void asNoAuthorityPrincipal() {
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken("oms-integration", "n/a", List.of()));
    }

    private void asSbAdmin() {
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken("staff", "n/a",
                        List.of(new SimpleGrantedAuthority("ROLE_sb_admin"))));
    }

    @Test
    @DisplayName("BEFORE (all three on): @RolesAllowed/@DenyAll/@Secured DENY a no-authority principal; @PermitAll and unannotated PASS")
    void beforeState() {
        try (AnnotationConfigApplicationContext ctx = new AnnotationConfigApplicationContext(AllThreeOn.class)) {
            Target t = ctx.getBean(Target.class);
            asNoAuthorityPrincipal();
            assertThatThrownBy(t::rolesAllowed).hasMessageContaining("Access Denied");
            assertThatThrownBy(t::denyAll).hasMessageContaining("Access Denied");
            assertThatThrownBy(t::secured).hasMessageContaining("Access Denied");
            assertThatThrownBy(t::preAuthorize).hasMessageContaining("Access Denied");
            assertThat(t.permitAll()).isEqualTo("permitAll-ran");
            assertThat(t.unannotated()).isEqualTo("unannotated-ran");
        }
    }

    @Test
    @DisplayName("AFTER (prePost only): @RolesAllowed/@DenyAll/@Secured are INERT (call succeeds); @PreAuthorize still denies")
    void afterState() {
        try (AnnotationConfigApplicationContext ctx = new AnnotationConfigApplicationContext(PrePostOnly.class)) {
            Target t = ctx.getBean(Target.class);
            asNoAuthorityPrincipal();
            assertThat(t.rolesAllowed()).isEqualTo("rolesAllowed-ran");
            assertThat(t.denyAll()).isEqualTo("denyAll-ran");
            assertThat(t.secured()).isEqualTo("secured-ran");
            assertThatThrownBy(t::preAuthorize).hasMessageContaining("Access Denied");
            assertThat(t.permitAll()).isEqualTo("permitAll-ran");
            assertThat(t.unannotated()).isEqualTo("unannotated-ran");
        }
    }

    @Test
    @DisplayName("DIRECTION: de-arming @PermitAll cannot make anything MORE restrictive — same verdict before and after")
    void permitAllDirection() {
        // BEFORE: does @PermitAll on a method override a class-level @PreAuthorize?
        String before;
        try (AnnotationConfigApplicationContext ctx = new AnnotationConfigApplicationContext(AllThreeOn.class)) {
            ClassGatedTarget t = ctx.getBean(ClassGatedTarget.class);
            asNoAuthorityPrincipal();
            try { t.permitAllUnderClassPreAuthorize(); before = "ALLOWED"; }
            catch (Exception e) { before = "DENIED:" + e.getClass().getSimpleName(); }
        }
        SecurityContextHolder.clearContext();
        String after;
        try (AnnotationConfigApplicationContext ctx = new AnnotationConfigApplicationContext(PrePostOnly.class)) {
            ClassGatedTarget t = ctx.getBean(ClassGatedTarget.class);
            asNoAuthorityPrincipal();
            try { t.permitAllUnderClassPreAuthorize(); after = "ALLOWED"; }
            catch (Exception e) { after = "DENIED:" + e.getClass().getSimpleName(); }
        }
        System.out.println("### @PermitAll under class @PreAuthorize: BEFORE=" + before + "  AFTER=" + after);
        assertThat(after).as("de-arming a PERMIT must not tighten anything").isEqualTo(before);
    }

    @Test
    @DisplayName("sb_admin holder is unaffected in both states")
    void sbAdminUnaffected() {
        try (AnnotationConfigApplicationContext ctx = new AnnotationConfigApplicationContext(PrePostOnly.class)) {
            Target t = ctx.getBean(Target.class);
            asSbAdmin();
            assertThatCode(t::preAuthorize).doesNotThrowAnyException();
        }
    }
}
