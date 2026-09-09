package net.aim_ai.wms.reviewprobe;

import com.example.composed.AdminOnly;
import com.example.composed.DeniedBase;
import jakarta.annotation.security.DenyAll;
import jakarta.annotation.security.PermitAll;
import jakarta.annotation.security.RolesAllowed;
import java.lang.annotation.Annotation;
import java.lang.reflect.Method;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.core.annotation.AnnotatedElementUtils;
import org.springframework.security.access.annotation.Secured;

/** REVIEW-ONLY probe: would Spring's own AnnotatedElementUtils detector close the two gaps? */
class Sbdev3156StrongerDetectorProbe {

    static class MetaCarrier {
        @AdminOnly
        public String x() { return "ran"; }
    }

    static class InheritingCarrier extends DeniedBase { }

    private static final List<Class<? extends Annotation>> BANNED =
            List.of(Secured.class, RolesAllowed.class, DenyAll.class, PermitAll.class);

    private static String detect(Class<?> c) {
        StringBuilder sb = new StringBuilder();
        for (Class<? extends Annotation> a : BANNED) {
            if (AnnotatedElementUtils.findMergedAnnotation(c, a) != null) sb.append("class:").append(a.getSimpleName()).append(" ");
            for (Method m : c.getMethods()) {
                if (m.getDeclaringClass() == Object.class) continue;
                if (AnnotatedElementUtils.findMergedAnnotation(m, a) != null) {
                    sb.append(m.getName()).append(":").append(a.getSimpleName()).append(" ");
                }
            }
        }
        return sb.length() == 0 ? "NOTHING FOUND" : sb.toString().trim();
    }

    @Test
    void strongerDetector() {
        System.out.println("### STRONG-DETECTOR meta     -> " + detect(MetaCarrier.class));
        System.out.println("### STRONG-DETECTOR inherit  -> " + detect(InheritingCarrier.class));
        for (Class<? extends Annotation> a : BANNED) {
            System.out.println("### @Target of " + a.getName() + " = "
                    + java.util.Arrays.toString(a.getAnnotation(java.lang.annotation.Target.class).value())
                    + "  @Inherited=" + (a.getAnnotation(java.lang.annotation.Inherited.class) != null));
        }
    }
}
