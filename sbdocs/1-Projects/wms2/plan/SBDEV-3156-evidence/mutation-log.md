# SBDEV-3156 — mutation log

Every new assertion, the mutant that proves it bites, and whether the kill was **attributable** (the failure
message names the thing broken). A red that arrives as `NoSuchMethodException`, an NPE in setup, or a
diagnostic quoting a *different* symbol is a red, not a kill.

Branch `chore/SBDEV-3156-method-security-enablement-pin`, worktree
`.claude/worktrees/wms2-api/SBDEV-3156`.

| # | mutant | target assertion | result | attributable? |
|---|---|---|---|---|
| M1 | `@jakarta.annotation.security.DenyAll` on a `src/main` **method** | `noDeArmedMethodSecurityAnnotationsInMain` | KILLED | ✔ names `ReplenishmentReconciliationController#reconcileStrandedReservations` **and** `@DenyAll` |
| M2 | `@Secured("ROLE_sb_admin")` at **class** level | same | KILLED | ✔ names the class and `@Secured` |
| M3 | scan root → `net.aim_ai.wms.nonexistent` | `scanIsNotVacuous` | KILLED | ✔ names the vacuity guard and its three upstream causes |
| M4 | `securedEnabled = true` | `securedEnabledStaysOff` | KILLED | ✔ message names `securedEnabled` |
| M5 | `jsr250Enabled = true` | `jsr250EnabledStaysOff` | KILLED | ✔ message names `jsr250Enabled` |
| M6 | `prePostEnabled = false` | `methodSecurityIsEnabledWithPrePostProcessing` (pre-existing) | KILLED | ✔ the pre-existing pin still bites |
| M8 | custom `@ZZTempAdminOnly` composed with `@DenyAll`, **declared inside** `net.aim_ai.wms`, applied to a method | `noDeArmed...` | KILLED — but **at the annotation's DECLARATION**, not the usage site | partial |
| M9 | same, **declared OUTSIDE** `net.aim_ai.wms` (package `zztest`), applied to a `src/main` method | `noDeArmed...` | **SURVIVED** against the first version of the rule | — |
| M9′ | M9 re-run after strengthening the rule to direct-**or**-meta | `noDeArmed...` | KILLED at the **usage site** | ✔ names class#method, `@DenyAll`, and flags it `META-annotated` |
| M10 | `@DenyAll` **INHERITED** from a base class in a package outside `net.aim_ai.wms`, on a `src/main` subclass | `springsOwnLookupFindsNoDeArmedAnnotation` (new second instrument) | KILLED — and **only 1 of 3 tests failed**, confirming the structural rule genuinely misses this shape | ✔ names class#method, `@DenyAll`, and labels it merged/inherited |
| M11 | scan root narrowed to `service`+`repo`+`model`+`controller` — **>400 classes, so the size floor still passes** | `scanIsNotVacuous`'s landmark assertion | KILLED | ✔ names the missing landmark `net.aim_ai.wms.landlord.config.TenantFilter` |
| M12 | `@PostFilter("filterObject != null")` on the §0.C OMS carve-out route `POST /v3/client/create` | `Sbdev3017TrancheGateContextTest` — after adding `@PreFilter`/`@PostFilter` to `METHOD_SECURITY_GATES` | KILLED (it could NOT see this before) | ✔ after a second fix — see below |

## M9 is the finding worth keeping

The first version of the rule used ArchUnit's `isAnnotatedWith(String)`, which matches only a **directly
present** annotation. So a custom annotation composed with `@DenyAll` and applied to a `src/main` method
went **fully green**. M8 masked this: because that annotation was declared *inside* the scanned tree, the
rule still fired — on the declaration — which reads like a pass and is easy to mistake for one. Only moving
the declaration out of the tree (M9) exposed it.

Fix: `carries()` checks `isAnnotatedWith(...) || isMetaAnnotatedWith(...)`, and `via()` labels a meta hit so
the diagnostic says a grep at that site will find nothing. The javadoc's coverage claim was also too strong
and was narrowed to match what the rule actually does.

**The general lesson** — a mutant that dies for the *wrong reason* is more dangerous than one that survives,
because it manufactures confidence. M8's kill was real and its location was wrong, and nothing but planting
M9 would have shown that. Same family as this repo's recorded case of a hand-rolled harness reporting 4/4
KILLED where only one mutant was real, the tell being M2's diagnostic quoting M1's constant.

## Two harness traps hit while doing this

1. **`git checkout --` silently NO-OPS on an untracked file.** Restoring the M3 mutant appeared to succeed
   (`0 lines of diff`) while the broken scan root was still in the tree. Caught by re-reading the file, not
   by the exit code. For a new file, restore from a copy or `sed` the mutation back.
2. **`mvn test` without `clean` leaves orphaned `.class` files in `target/classes`.** After M8's source was
   deleted, `ZZTempAdminOnly.class` remained, and ArchUnit — which scans **compiled output** — kept
   reporting it. The M9 run was contaminated and initially looked like a kill when it was in fact a
   SURVIVAL. Any mutation check on a bytecode-scanning test must use `mvn -o clean test`.


## What the three review lanes changed about this log

The lanes ran against `3594108a`, i.e. before M9′/M10/M11 existed. Two of them independently found the
meta-annotation gap that M9 had already exposed, and the security lane found a **second** bypass I had not:

- **Inherited from a library superclass.** Confirmed by that lane with a live spring-security 6.5.7 probe
  showing Spring *honours* both the meta and the inherited shape when the flags are on and both go silently
  inert when off, while the direct-only detector saw neither. Closed by the second instrument
  (`AnnotatedElementUtils.findMergedAnnotation`, the same lookup
  `Sbdev3017TrancheGateContextTest.hasMethodSecurityGate` already uses), mutation-checked as M10.
- **The size guard proves the scan is BIG, not COMPLETE.** With 650 classes and a floor of 400, a subtree of
  up to 249 could leave the root unnoticed — and `landlord/` is 34 files. Closed by landmark assertions,
  mutation-checked as M11.

Both were Medium, neither was live: no class anywhere on the 304-jar classpath carries one of these
annotations, so neither door is currently walked through. They mattered because the change's own safety
argument is explicitly load-bearing on the ban rule.

## Why the structural rule is kept alongside the reflection one

They are two instruments with different blind spots and both are cheap. The ArchUnit rule loads no classes,
so it cannot be defeated by a class that fails to initialise, and it reports the annotation's own declaration
site. The reflection rule matches Spring's resolution exactly, so it sees composition and inheritance. M10 is
the case where the second catches what the first misses; a class that cannot be loaded at all would be the
reverse. Deleting either one narrows coverage in a way no single test would reveal.


## M12 and a kill whose DIAGNOSTIC was wrong — the subtlest failure in this log

The correctness lane found that `METHOD_SECURITY_GATES` listed five annotations but omitted
`@PreFilter`/`@PostFilter`, which `prePostEnabled = true` leaves **LIVE** —
`PrePostMethodSecurityConfiguration` builds **four** interceptors, not two. So the defence-in-depth argument
applied *harder* to the pair that was missing: a `@PostFilter` on an OMS carve-out route would silently
**empty the response** the integration reads, with no flag flip and no denial for anyone to notice.

Added both, then planted M12. It killed — and **the failure message was still wrong**. It read:

> *"carries a method-security annotation (@PreAuthorize/@PostAuthorize/@Secured/@RolesAllowed/@DenyAll)"*

A stale literal. Someone debugging that red would grep the route for those five, find none, and conclude the
test was broken — while the actual culprit was `@PostFilter`. **The kill was real and the attribution was
misleading**, which is worse than a survival because it sends the reader somewhere else. Fixed to name all
seven and to say explicitly that the culprit may be `@PostFilter`, then M12 re-run to confirm the new text
appears.

**This was the fourth stale literal in one ticket** — the others: the ticket's own `:64-67` citation, the
`@EnableMethodSecurity` javadoc in the sibling test, `"all 20 @PreAuthorize sites"` (really 13), and `"this
list stays five long"` after the list became seven. Every one was found by grepping the **old value** after
changing something, which is the cheapest step in the whole process and the one most often skipped.

**The lesson to keep:** an attributable kill means the message names *the thing you broke*. Verify the text,
not just the colour — a diagnostic that enumerates a closed set goes stale the moment the set changes, and
nothing tests a test's error message.
