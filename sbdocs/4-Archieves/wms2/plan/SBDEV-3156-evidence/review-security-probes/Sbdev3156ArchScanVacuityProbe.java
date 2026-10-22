package net.aim_ai.wms.reviewprobe;

import com.tngtech.archunit.core.domain.JavaClasses;
import com.tngtech.archunit.core.importer.ClassFileImporter;
import com.tngtech.archunit.core.importer.ImportOption;
import org.junit.jupiter.api.Test;

/** REVIEW-ONLY probe: how big is the scanned set, and does DO_NOT_INCLUDE_TESTS actually bite? */
class Sbdev3156ArchScanVacuityProbe {

    @Test
    void measure() {
        JavaClasses noTests = new ClassFileImporter()
                .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)
                .importPackages("net.aim_ai.wms");
        JavaClasses withTests = new ClassFileImporter().importPackages("net.aim_ai.wms");
        System.out.println("### ARCHSCAN main-only size = " + noTests.size());
        System.out.println("### ARCHSCAN main+tests size = " + withTests.size());
        System.out.println("### ARCHSCAN tests-only size = " + (withTests.size() - noTests.size()));

        boolean sawProbeFixture = false;
        for (var c : noTests) {
            if (c.getName().contains("reviewprobe")) { sawProbeFixture = true; System.out.println("### LEAK: " + c.getName()); }
        }
        System.out.println("### main-only scan leaked a test class? " + sawProbeFixture);

        // what does a WRONG root return? (the M3 mutant shape)
        JavaClasses wrongRoot = new ClassFileImporter()
                .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)
                .importPackages("net.aim_ai.wms.controller");
        System.out.println("### wrong-root (controller subtree only) size = " + wrongRoot.size());
        JavaClasses typoRoot = new ClassFileImporter()
                .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)
                .importPackages("net.aim_ai.wmss");
        System.out.println("### typo-root size = " + typoRoot.size());
    }
}
