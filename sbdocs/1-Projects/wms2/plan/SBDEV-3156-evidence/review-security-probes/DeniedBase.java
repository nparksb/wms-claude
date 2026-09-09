package com.example.composed;

import jakarta.annotation.security.DenyAll;

/** Simulates a third-party SUPERCLASS carrying @DenyAll, outside the ban's scan root. */
public class DeniedBase {
    @DenyAll
    public String inheritedDenied() { return "ran"; }
}
