package net.aim_ai.wms.unit.config;

import com.tngtech.archunit.core.domain.JavaClass;
import com.tngtech.archunit.core.domain.JavaClasses;
import com.tngtech.archunit.core.domain.JavaMethod;
import com.tngtech.archunit.core.importer.ClassFileImporter;
import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.core.importer.Location;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Tags;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * SBDEV-3255 — a JUnit {@code @Tag} must be wired to something that reads it.
 *
 * <h2>The defect this closes</h2>
 *
 * This repository carried {@code @Tag} annotations for months while the POM configured neither
 * {@code <groups>} nor {@code <excludedGroups>} on surefire or failsafe. <b>Not one of them did
 * anything.</b> They read as deliberate test-selection policy and were decoration.
 *
 * <p>The cost was not cosmetic. {@code BillofladingServiceFinishTransferPerformanceIT} carried
 * {@code @Tag("performance")} — the author saying "filter this out" — and, because nothing read
 * tags, <b>also</b> an {@code @Disabled} to actually keep a long-running load test out of the
 * suite. An {@code @Disabled} is indistinguishable from a parked defect, so a deliberate
 * on-demand-only test was wearing the marker this repository spent two tickets (SBDEV-3239,
 * SBDEV-3241) cleaning off genuinely broken ones.
 *
 * <h2>Why this rule and not a one-time cleanup</h2>
 *
 * Wiring the groups once fixes the four sites that existed. It does not stop the fifth. And the
 * fifth is cheap to add: {@code @Tag("slow")} on a new class reads exactly like working policy,
 * compiles, and silently selects nothing.
 *
 * <p>⚠ The population is <b>not</b> stable, and this is measured rather than assumed: the ticket
 * counted four {@code @Tag} sites at {@code cf3486d8} and there were <b>five</b> at
 * {@code c4d920eb} four days later — a third {@code @Tag("postgres")} arrived in
 * {@code 5f7d044a}. A census in prose rots; this rule re-derives it on every build.
 *
 * <h2>What "wired" means here — and what it deliberately does not prove</h2>
 *
 * A group is <b>wired</b> when its name appears in a {@code <groups>} or {@code <excludedGroups>}
 * element in {@code pom.xml} (resolving a {@code ${property}} indirection through
 * {@code <properties>}), or in a {@code -Dgroups=} / {@code -D…excludedGroups=} flag in a
 * workflow under {@code .github/workflows}. Both locations count because they are both real:
 * {@code performance} is excluded in the POM (everywhere, including developer machines), while a
 * class that must still run locally but not in CI is excluded in the workflow only.
 *
 * <p><b>This rule cannot prove Maven honours the configuration.</b> That is a separate
 * measurement and it is the one that fails silently in the dangerous direction — a misspelled
 * {@code excludedGroups} leaves the load test running in CI while every build stays green.
 * SBDEV-3255 AC-3 discharges it by running the lane and diffing the executed class list, with a
 * positive control proving the same command does run a neighbouring class. Do not read a green
 * here as evidence the exclusion works.
 *
 * <h2>Instrument, and its blind spots</h2>
 *
 * Bytecode, not a source scan — {@code @Tag} is {@code RUNTIME}-retained, so ArchUnit resolves it
 * by type at whatever level it was declared. That matters concretely: one of the five sites is on
 * a {@code @Nested} inner class, which a line-window source scan attributes to the enclosing
 * class, and this tree has roughly 1400 {@code @Nested} sites for that to recur in. Both
 * {@code @Tag} and its {@code @Repeatable} container {@code @Tags} are read, at class and method
 * level, directly and meta-annotated.
 *
 * <p>Stated blind spots, rather than left for a reader to discover:
 * <ul>
 *   <li>The POM/workflow side is a <b>text scan</b>. It answers "does this name appear in a
 *       filtering position", not "does Maven apply it" — see above.</li>
 *   <li>A tag value computed at runtime (JUnit permits a {@code TagFilter} or a dynamic
 *       container's tags) is invisible. There are none today; that is a fact about now.</li>
 *   <li>It says nothing about whether a wired group is the <i>right</i> policy — only that the
 *       annotation is connected to a mechanism.</li>
 * </ul>
 */
@DisplayName("SBDEV-3255 — every JUnit @Tag is wired to a groups/excludedGroups filter")
class JUnitTagWiringArchTest {

    private static final Path POM = Path.of("pom.xml");
    private static final Path WORKFLOWS = Path.of(".github", "workflows");

    /** {@code <groups>x</groups>} and {@code <excludedGroups>x</excludedGroups>} in the POM. */
    private static final Pattern POM_GROUPS =
        Pattern.compile("<(?:excludedGroups|groups)>([^<]*)</(?:excludedGroups|groups)>");

    /** {@code <properties><foo>bar</foo></properties>} entries, for resolving {@code ${foo}}. */
    private static final Pattern POM_PROPERTY =
        Pattern.compile("<([A-Za-z0-9._-]+)>([^<>$]*)</\\1>");

    /** {@code -Dgroups=a,b}, {@code -DexcludedGroups=a}, {@code -Dfailsafe.excludedGroups=a}. */
    private static final Pattern CLI_GROUPS =
        Pattern.compile("-D(?:[A-Za-z0-9._-]+\\.)?(?:excludedGroups|groups)=([^\\s'\"]*)");

    private static JavaClasses testClasses;

    @BeforeAll
    static void importTestClasses() {
        ImportOption onlyTestClasses = (Location location) -> location.contains("/test-classes/");
        testClasses = new ClassFileImporter()
            .withImportOption(onlyTestClasses)
            .importPackages("net.aim_ai.wms");
    }

    @Test
    @DisplayName("no @Tag names a group that neither the POM nor a workflow filters on")
    void everyTagIsWired() throws IOException {
        Set<String> used = tagsInUse();
        Set<String> wired = wiredGroups();

        // Positive control. A rule whose expected answer is "empty" is indistinguishable from a
        // broken instrument, and the broken instrument agrees with whatever you were hoping. If
        // the importer or the annotation reader silently returns nothing, this fails FIRST and
        // says so, instead of reporting a clean pass over zero classes.
        assertThat(testClasses)
            .as("positive control: the importer must actually see the test tree")
            .hasSizeGreaterThan(1000);
        assertThat(used)
            .as("positive control: this repository is known to use @Tag; an empty result means "
                + "the annotation reader is broken, not that the tags are gone")
            .isNotEmpty();

        Set<String> unwired = new TreeSet<>(used);
        unwired.removeAll(wired);

        assertThat(unwired)
            .as("@Tag(%s) selects nothing: no <groups>/<excludedGroups> in pom.xml and no "
                + "-Dgroups/-DexcludedGroups in .github/workflows names it. Either wire it or "
                + "delete it - an annotation that looks like test-selection policy and is inert "
                + "is worse than no annotation. Tags in use: %s; wired: %s",
                unwired, new TreeSet<>(used), new TreeSet<>(wired))
            .isEmpty();
    }

    /** Every distinct {@code @Tag} value declared anywhere in the compiled test tree. */
    private static Set<String> tagsInUse() {
        Set<String> tags = new HashSet<>();
        for (JavaClass type : testClasses) {
            collect(tags, type.tryGetAnnotationOfType(Tag.class).orElse(null),
                          type.tryGetAnnotationOfType(Tags.class).orElse(null));
            for (JavaMethod method : type.getMethods()) {
                collect(tags, method.tryGetAnnotationOfType(Tag.class).orElse(null),
                              method.tryGetAnnotationOfType(Tags.class).orElse(null));
            }
        }
        return tags;
    }

    private static void collect(Set<String> into, Tag single, Tags repeated) {
        if (single != null) {
            into.add(single.value());
        }
        if (repeated != null) {
            Stream.of(repeated.value()).map(Tag::value).forEach(into::add);
        }
    }

    /** Group names the build actually filters on, from the POM and the workflows. */
    private static Set<String> wiredGroups() throws IOException {
        Set<String> wired = new HashSet<>();

        String pom = Files.readString(POM);
        Map<String, String> properties = new HashMap<>();
        Matcher property = POM_PROPERTY.matcher(pom);
        while (property.find()) {
            properties.put(property.group(1), property.group(2).trim());
        }
        Matcher groups = POM_GROUPS.matcher(pom);
        while (groups.find()) {
            addAll(wired, resolve(groups.group(1).trim(), properties));
        }

        if (Files.isDirectory(WORKFLOWS)) {
            List<Path> files;
            try (Stream<Path> walk = Files.walk(WORKFLOWS)) {
                files = walk.filter(Files::isRegularFile).collect(Collectors.toList());
            }
            for (Path file : files) {
                Matcher cli = CLI_GROUPS.matcher(Files.readString(file));
                while (cli.find()) {
                    addAll(wired, cli.group(1).trim());
                }
            }
        }
        return wired;
    }

    /** {@code ${failsafe.excludedGroups}} -> the property's value; anything else is a literal. */
    private static String resolve(String raw, Map<String, String> properties) {
        if (raw.startsWith("${") && raw.endsWith("}")) {
            return properties.getOrDefault(raw.substring(2, raw.length() - 1), "");
        }
        return raw;
    }

    /** JUnit group expressions are comma-separated; blanks mean "filter on nothing". */
    private static void addAll(Set<String> into, String expression) {
        Stream.of(expression.split(","))
            .map(String::trim)
            .filter(s -> !s.isEmpty())
            .forEach(into::add);
    }
}
