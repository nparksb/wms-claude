package com.example.composed;

import jakarta.annotation.security.RolesAllowed;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/** Simulates a COMPOSED annotation arriving from a third-party jar (outside net.aim_ai.wms). */
@Target({ElementType.METHOD, ElementType.TYPE})
@Retention(RetentionPolicy.RUNTIME)
@RolesAllowed("sb_admin")
public @interface AdminOnly {
}
