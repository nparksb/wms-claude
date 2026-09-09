package net.aim_ai.wms.reviewprobe;

import static org.assertj.core.api.Assertions.assertThat;

import com.example.composed.AdminOnly;
import com.example.composed.DeniedBase;
import com.tngtech.archunit.core.domain.JavaClass;
import com.tngtech.archunit.core.domain.JavaClasses;
import com.tngtech.archunit.core.domain.JavaMethod;
import com.tngtech.archunit.core.importer.ClassFileImporter;
import jakarta.annotation.security.RolesAllowed;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;

/** REVIEW-ONLY probe: does the ban's detector see meta-annotated and inherited cases? */
class Sbdev3156BanDetectorGapProbe {

    /** direct — this is what the ban catches */
    static class DirectCarrier {
        @RolesAllowed("sb_admin")
        public String x() { return "ran"; }
    }

    /** meta-annotated via an annotation declared OUTSIDE the scan root */
    static class MetaCarrier {
        @AdminOnly
        public String x() { return "ran"; }
    }

    /** inherits @DenyAll from a superclass OUTSIDE the scan root */
    static class InheritingCarrier extends DeniedBase { }

    private static final Set<String> BANNED = Set.of(
            "org.springframework.security.access.annotation.Secured",
            "jakarta.annotation.security.RolesAllowed",
            "jakarta.annotation.security.DenyAll",
            "jakarta.annotation.security.PermitAll");

    /** exactly the ban rule's detector, verbatim in shape */
    private static List<String> banRuleViolations(JavaClasses classes, String nameFilter) {
        List<String> v = new ArrayList<>();
        for (JavaClass t : classes) {
            if (!t.getName().contains(nameFilter)) continue;
            for (String b : BANNED) {
                if (t.isAnnotatedWith(b)) v.add(t.getName() + " (class)");
            }
            for (JavaMethod m : t.getMethods()) {
                for (String b : BANNED) {
                    if (m.isAnnotatedWith(b)) v.add(t.getName() + "#" + m.getName());
                }
            }
        }
        return v;
    }

    @Test
    void detectorSemantics() {
        // scan root deliberately excludes com.example.composed, mimicking "src/main only, net.aim_ai.wms root"
        JavaClasses scanned = new ClassFileImporter().importPackages("net.aim_ai.wms.reviewprobe");
        System.out.println("### BAN-DETECTOR direct   -> " + banRuleViolations(scanned, "DirectCarrier"));
        System.out.println("### BAN-DETECTOR meta     -> " + banRuleViolations(scanned, "MetaCarrier"));
        System.out.println("### BAN-DETECTOR inherit  -> " + banRuleViolations(scanned, "InheritingCarrier"));
        assertThat(banRuleViolations(scanned, "DirectCarrier")).isNotEmpty();
    }

    @Configuration
    @EnableMethodSecurity(prePostEnabled = true, securedEnabled = true, jsr250Enabled = true)
    static class AllThreeOn {
        @Bean MetaCarrier meta() { return new MetaCarrier(); }
        @Bean InheritingCarrier inheriting() { return new InheritingCarrier(); }
    }

    @Configuration
    @EnableMethodSecurity(prePostEnabled = true, securedEnabled = false, jsr250Enabled = false)
    static class PrePostOnly {
        @Bean MetaCarrier meta() { return new MetaCarrier(); }
        @Bean InheritingCarrier inheriting() { return new InheritingCarrier(); }
    }

    @Test
    void doesSpringHonourMetaAndInherited() {
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken("oms", "n/a", List.of()));
        try (AnnotationConfigApplicationContext ctx = new AnnotationConfigApplicationContext(AllThreeOn.class)) {
            System.out.println("### SPRING(on)  meta-@RolesAllowed  -> " + call(() -> ctx.getBean(MetaCarrier.class).x()));
            System.out.println("### SPRING(on)  inherited-@DenyAll   -> " + call(() -> ctx.getBean(InheritingCarrier.class).inheritedDenied()));
        }
        try (AnnotationConfigApplicationContext ctx = new AnnotationConfigApplicationContext(PrePostOnly.class)) {
            System.out.println("### SPRING(off) meta-@RolesAllowed  -> " + call(() -> ctx.getBean(MetaCarrier.class).x()));
            System.out.println("### SPRING(off) inherited-@DenyAll   -> " + call(() -> ctx.getBean(InheritingCarrier.class).inheritedDenied()));
        }
        SecurityContextHolder.clearContext();
    }

    private static String call(java.util.concurrent.Callable<String> c) {
        try { return "ALLOWED(" + c.call() + ")"; }
        catch (Exception e) { return "DENIED(" + e.getClass().getSimpleName() + ")"; }
    }
}
