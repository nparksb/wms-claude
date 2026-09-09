# SBDEV-3257 — DELTA re-review of the fixes applied to the first review's 18 findings

**Reviewer lane:** second independent lane (no authoring context in either the change or the first review)
**Reviewed:** commit `c526d100` on `bugfix/SBDEV-3257-stale-lane-down-comments` (PR #324), branched off
`origin/develop` @ `0dfcefc6`; worktree
`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3257`; plus
`/home/nampark/dev/wms-claude/sbdocs/9-System/scripts/stale-lane-claim-scan.py`, the ClickUp ticket, the
commit message and the PR body.
**Date:** 2026-09-08
**Constraints honoured:** no `mvn` and no state-mutating git in that worktree. Where a build was needed I
made my own `git worktree add --detach` copy at
`/tmp/claude-1000/.../scratchpad/wt-3257`, ran there, and removed it.

**Headline.** The `src/main` sweep (H-2) and the non-behavioural claim are genuinely and completely
fixed, and I verified the one thing the first reviewer could not: **both `smoke/*ContextLoadTest`
classes are green today** (measured, 2/0F/0E/0S). But the H-1 repair reproduced the *same* failure
mode it was fixing:

- **H-Δ1** — the fix credits **SBDEV-3239** with the existence of a bootable full-context lane at
  **seven** `src/main`/`src/test` sites plus **three** `sbdocs` sites. A full-context `@SpringBootTest`
  + `@AutoConfigureMockMvc` lane has existed since **2026-02-04** and was *proved bootable* on
  **2026-08-24**, thirteen days before SBDEV-3239 slice E. Six controller tests use it. Both halves of
  the new parenthetical are false.
- **H-Δ2** — the replacement text at both smoke sites (and in the PR body) says the landlord URL
  "is supplied by `application-integration.properties`". **Measured: it is not.**
  `BaseRollbackIntegrationTest` supplies it itself via `@TestPropertySource`, which outranks the
  profile file. I proved this by probe.
- **H-Δ3** — a **new** sentence was added to a paragraph whose premise the file's own class
  declaration contradicts: `CustomerorderBatchServiceParallelStreamRegressionIT` does **not** extend
  the H2 base.

Plus a **fifth way to break the scanner** that reports `0 across 0 files` with **exit 0** and all four
controls green, and a demonstration that keying control 2 on `line_spans > 0` is **not** sufficient.

---

## High

### H-Δ1 — NEW FALSE CLAIM ×7 (+3 in `sbdocs`): "a full-context lane exists **as of SBDEV-3239**" and "no controller test uses one yet". This is H-1's exact conflation, re-committed while fixing H-1.

The first review's H-1 was that the change credited SBDEV-3239 with fixing a lane it never touched.
The repair fixed that at the four named sites — and then asserted the same misattribution in seven
*new* hunks, in the softer form "a full-context lane exists as of SBDEV-3239".

Sites (all new text in this commit):

| file:line | exact text |
|---|---|
| `src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java:46-47` | "a full-context lane exists **as of SBDEV-3239** and could exercise method security; **no controller test uses one yet**" |
| `src/main/java/net/aim_ai/wms/security/RequiresFunction.java:31-32` | "(A full-context lane exists **as of SBDEV-3239** and could evaluate `@PreAuthorize`; **no controller test uses one yet**…)" |
| `src/test/java/net/aim_ai/wms/common/base/BaseControllerUnitTest.java:83-84` | "(A full-context lane exists **as of SBDEV-3239** and could exercise it; **no controller test here uses one yet**.)" |
| `src/test/java/net/aim_ai/wms/unit/CustomMethodSecurityExpressionRootUnitTest.java:295-296` | "A `@SpringBootTest` lane that could is **available since SBDEV-3239**, but **no test uses it for this**" |
| `src/test/java/net/aim_ai/wms/unit/controller/UserControllerUnitTest.java:865` | "(**SBDEV-3239 gave the repo a bootable full-context lane**; **no controller test uses it yet**.)" |
| `src/test/java/net/aim_ai/wms/unit/security/MethodSecurityEnablementContractTest.java:291-292` | "a full-context lane that could **exists since SBDEV-3239**" |
| `src/test/java/net/aim_ai/wms/unit/controller/ItemDataControllerUnitTest.java:371-372` | "A full-context assertion **became possible when SBDEV-3239 fixed the container lane**" |

And in long-lived reference material (`sbdocs`, edited in the same session):

- `sbdocs/3-Resources/architecture/wms2-keycloak-role-matrix.md:290` — "SBDEV-3239, but no controller test uses one yet."
- `…:341` — "a `@SpringBootTest` lane that could exists since SBDEV-3239 but no controller test uses one"
- `…:780` — "a `@SpringBootTest` lane that could **has existed since SBDEV-3239 (2026-09-07)**, no controller test uses one" — with a date attached, which is what makes it read as verified.

**Why both halves are false.**

1. *A full-context lane predates SBDEV-3239 by months.* `src/test/java/net/aim_ai/wms/common/base/BaseControllerIntegrationTest.java:20-21`
   is `@AutoConfigureMockMvc` over `BaseIntegrationTest`, which is
   `@SpringBootTest(classes = StartApplication.class)` + `@ActiveProfiles("integration")`
   (`BaseIntegrationTest.java:22-23`). `git log` on that base class → `3d91c4ad`, **2026-02-04**.
   Five `@SpringBootTest` base classes exist in `common/base/`; three are H2 and boot.
2. *It was proved bootable before SBDEV-3239.* `src/test/java/net/aim_ai/wms/smoke/WebContextLaneContextTest.java`
   (commit `b9b138d4`, **2026-08-24**, SBDEV-3017 slice A) extends `BaseControllerIntegrationTest`,
   is named `*ContextTest` so surefire runs it, is not `@Disabled`, and asserts
   `mockMvc` is injected — its own javadoc says it exists precisely to prove "the lane that could not
   start" now starts. SBDEV-3239 slice E is `0984435e`, **2026-09-06**.
3. *Six controller tests already use it, and two assert a real 403 through the full chain.*
   `grep -rl "extends BaseControllerIntegrationTest" src/test` → `WebContextLaneContextTest`,
   `SkuRestControllerIntegrationTest`, `ClientControllerLegacyIntegrationTest`,
   `SdrReadGateEnforcementContextTest`, `CustomerOrderControllerIntegrationTest`,
   `OrderRestControllerIntegrationTest`. **None carries a class-level `@Disabled`.**
   `SdrReadGateEnforcementContextTest:78-85` — *"GET /v3/userGroup/search/findByConnectorFalse → 403
   for a denied caller"*, `.andExpect(status().isForbidden())`.
   `CustomerOrderControllerIntegrationTest:250-261` — *"a denied decision still produces 403"*.
   `src/main/java/net/aim_ai/wms/MethodSecurityConfig.java:49` is
   `@EnableMethodSecurity(prePostEnabled = true)` and is component-scanned into those contexts, so the
   method-security advisor **is present** in that lane.

**The load-bearing claim survives — only the attribution has to go.** I checked whether
"no controller test evaluates `@PreAuthorize`" is still true, and it is: none of `SkuRestController`,
`CustomerorderController`, `ClientController` or `OrderRestController` declares `@PreAuthorize`
(0 occurrences each), and the endpoints those tests drive (`/v3/customerOrder/detailsByOrderId/…`,
`/v3/customerOrder/batchUpdatePriorityByOrderIds`, `/swagger-ui/index.html`) reach no
`@PreAuthorize`-guarded handler. `AdminController` — where the 20 `@PreAuthorize` gates live — is
exercised only by unit-lane and ArchUnit tests.

**Concrete replacement** (use at all seven Java sites, adjusting the subject):

```
 * standaloneSetup installs no method-security advisor, so @PreAuthorize is never evaluated in any
 * controller test here — which is how SBDEV-2863 shipped a broken SpEL expression for nine months.
 * (A full-context MockMvc lane HAS existed since long before this — BaseControllerIntegrationTest,
 * proved bootable by WebContextLaneContextTest at SBDEV-3017 slice A, 2026-08-24 — and six controller
 * tests run on it, two of them asserting a real 403. What none of them does is invoke a
 * @PreAuthorize-guarded handler, so the annotation is still never evaluated. SBDEV-3239 is unrelated:
 * it fixed the Testcontainers PostgreSQL lane, not this one.)
```

For `sbdocs/…/wms2-keycloak-role-matrix.md:290`, `:341`, `:780`: replace "since SBDEV-3239
(2026-09-07)" with "since SBDEV-3017 slice A (2026-08-24), via `BaseControllerIntegrationTest`", and
drop "no controller test uses one" in favour of "no controller test invokes a `@PreAuthorize`-guarded
handler".

**Why this is High.** It is the identical defect class the first review filed as its own H-1, at
almost twice as many sites, now including `src/main` and an architecture doc, and one of them carries a
date that makes it look measured. The disproof is already inside this change: the author's own
corrected `PutawayResolverContextLoadTest` javadoc argues that an H2 full-context lane predates
SBDEV-3239 — and then six other files say it does not.

---

### H-Δ2 — NEW FALSE CLAIM ×3 (2 java + the PR body): the two smoke classes' landlord URL does **not** come from `application-integration.properties`. Measured.

- `src/test/java/net/aim_ai/wms/smoke/PutawayResolverContextLoadTest.java:39-40`
  > "…the **H2** full-context lane, **whose landlord URL is supplied by `application-integration.properties`** — and NOT the Testcontainers lane…"
- `src/test/java/net/aim_ai/wms/smoke/ReplenishReassignContextLoadTest.java:30-31`
  > "…the H2 full-context lane, **whose landlord URL comes from `application-integration.properties`**…"
- PR #324 body: "…**whose landlord URL is supplied at `application-integration.properties:9`**…"

`BaseRollbackIntegrationTest.java:31-49` declares its **own** `@TestPropertySource`, which includes
`landlord.datasource.jdbc-url=jdbc:h2:mem:rollback_landlord;…` and
`spring.datasource.url=jdbc:h2:mem:rollback_tenant;…`. `@TestPropertySource` inlined properties are the
highest-precedence source in a test context — they outrank profile-specific
`application-<profile>.properties`. The profile file's own header
(`src/test/resources/application-integration.properties:1-2`) names only `BaseIntegrationTest` and
`BaseRepositoryIntegrationTest`, not this base class.

**Measured, not reasoned.** In my own detached worktree at `c526d100` I added a throwaway probe
extending `BaseRollbackIntegrationTest` and printed the resolved `Environment` values:

```
PROBE landlord.datasource.jdbc-url = jdbc:h2:mem:rollback_landlord;DB_CLOSE_DELAY=-1;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE
PROBE landlord.datasource.pool-name = LandlordTestPool
PROBE spring.datasource.url        = jdbc:h2:mem:rollback_tenant;DB_CLOSE_DELAY=-1;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE
Tests run: 1, Failures: 0, Errors: 0 — BUILD SUCCESS
```

`pool-name = LandlordTestPool` comes from `application-integration.properties:15`, which proves the
profile file **is** loaded — and that its `jdbc-url` line at `:9` is overridden and never used by these
two classes. The probe was deleted; the worktree was removed.

This claim was suggested by the first review and copied verbatim; it is still the change's claim now.

**Concrete replacement** (both sites):

```
 * It extends {@link net.aim_ai.wms.common.base.BaseRollbackIntegrationTest}, which is
 * {@code @ActiveProfiles("integration")} — an H2 full-context lane whose landlord AND tenant URLs it
 * supplies itself, in its own {@code @TestPropertySource} ({@code jdbc:h2:mem:rollback_landlord} /
 * {@code rollback_tenant}); the {@code integration} profile file is loaded but its landlord URL is
 * overridden. Either way, the missing-landlord-URL defect SBDEV-2217/SBDEV-3239 concerned cannot
 * apply here.
```

And strike `application-integration.properties:9` from the PR body.

---

### H-Δ3 — NEW FALSE CLAIM: `CustomerorderBatchServiceParallelStreamRegressionIT` is **not** on the H2 base, and the fix added a sentence asserting that it is

`src/test/java/net/aim_ai/wms/integration/service/CustomerorderBatchServiceParallelStreamRegressionIT.java:37-44`
(the paragraph this commit edited):

> "**H2 vs. Postgres:** extends `{@link BaseIntegrationTest}` (H2 in PostgreSQL mode) rather than
> `{@code BasePostgresIntegrationTest}`. The determinism contract under test is dialect-independent …
> **so the cheaper H2 base is the right choice here on its own merits.** (The old reason given … stopped
> being true at SBDEV-3239 …) **Cross-dialect correctness against real PostgreSQL is deferred to the
> manual smoke against staging.**"

Line **60** of the same file:

```java
class CustomerorderBatchServiceParallelStreamRegressionIT extends BasePostgresIntegrationTest {
```

`git log -S'extends BasePostgresIntegrationTest'` on that file → `ac0ef2b1`, 2026-09-06,
*"SBDEV-3239 slice F: wire `*IT` into the lane"*. It is on the same base class on `origin/develop`
(`:59`). So:

- "extends `BaseIntegrationTest` (H2 …) rather than `BasePostgresIntegrationTest`" — **false**
  (pre-existing, and the author was editing three lines below it).
- "**so the cheaper H2 base is the right choice here on its own merits**" — **new text**, and false:
  the class is not on the H2 base. This is the change *adding* a justification for a placement the
  file does not have.
- "Cross-dialect correctness … is deferred to the manual smoke against staging" — **false**: it runs
  against a real PostgreSQL container in the failsafe lane on every build.
- The "Override note" below (`:46-49`) says "`{@link BaseIntegrationTest}`'s class-level
  `@Transactional` defaults to the `@Primary` landlord transaction manager … without this override
  fixture saves leak" — but `BasePostgresIntegrationTest.java:64` already declares
  `@Transactional("tenantTransactionManager")`, so the class-level override at `:59` is now redundant
  rather than load-bearing.

**Concrete replacement:**

```
 * <p><b>Postgres, not H2 (changed at SBDEV-3239 slice F, ac0ef2b1).</b> This class extends
 * {@link BasePostgresIntegrationTest} and runs against a real PostgreSQL container in the failsafe
 * lane. The determinism contract under test is dialect-independent — sequential
 * {@code Stream.collect(Collectors.toMap(...))} is a JVM-level guarantee — so the engine is not what
 * the assertion needs; it is simply where the class now lives. An earlier revision of this javadoc
 * said it extended {@code BaseIntegrationTest} "because BasePostgresIntegrationTest could not boot",
 * and that cross-dialect correctness was deferred to a manual staging smoke. Both statements are now
 * wrong: the base class boots (SBDEV-3239) and this class is on it.
 *
 * <p><b>Override note:</b> the class-level {@code @Transactional("tenantTransactionManager")} at :59
 * duplicates what {@link BasePostgresIntegrationTest} already declares (:64). Harmless, but it is no
 * longer the guard against a landlord-manager leak that this note used to describe.
```

---

## Medium

### M-Δ1 — the commit message and PR body both claim the frozen `V2.2.19` site is "recorded on the ticket". It is not.

Commit message: *"`V2.2.19__seed_web_view_function_grants.sql:55` … is DELIBERATELY UNTOUCHED …
**Recorded on the ticket instead.**"*
PR body: *"**Recorded on the ticket as a knowingly-frozen stale site.**"*

`clickup_get_task_comments(SBDEV-3257)` → `{"comments":[],"count":0}`. The task description
(`868m2ujq6`, unchanged since creation — `date_created` == `date_updated` to the second) never mentions
`V2.2.19` or the migration file. There is no plan document for SBDEV-3257 (only
`SBDEV-3257-evidence/`). **So the one knowingly-stale site in the repo is recorded nowhere durable**,
and the decision's reasoning survives only in a commit message.

The decision itself is right (see "verified true" below). Fix: post the comment, or add a
`⚠ knowingly-frozen` line to `src/main/resources/db/migration/README.md` — a file that is *not* an
applied migration and so has no checksum — pointing at `V2.2.19:54-55`. Then the next sweep finds the
record instead of the claim.

### M-Δ2 — a live verify-script row now FAILS as a direct result of this "comment-only" change

`sbdocs/9-System/scripts/verify-SBDEV-2732-configurable-default-putaway-location-hierarchy.sh`:

```
:371   CTXTEST=$TST/smoke/PutawayResolverContextLoadTest.java
:1234  # …it must be @Disabled with the SBDEV-2217 TODO, not silently deleted.
:1235  check_T_ctx_disabled()  { file_contains 'TODO\(SBDEV-2217\)' "$CTXTEST"; }
:2133  run T-ctxdis  "context-load test tagged TODO(SBDEV-2217)"  check_T_ctx_disabled
```

This change **deleted** that TODO. Measured: `grep -c 'TODO(SBDEV-2217)'` on the file → `1` on
`origin/develop`, `0` on the branch. Row `T-ctxdis` therefore goes red, and SBDEV-2732's plan is still
in `1-Projects/wms2/plan/`, so the script is live.

This does not falsify "zero executable change" *in the application* — but it is an executable
consequence outside `src/`, and it is the sort of thing that reads as an unrelated regression to
whoever runs that script next. Fix: repoint the row to assert the *absence* of the marker and the
presence of the new "This class runs" wording, e.g.

```bash
check_T_ctx_live()   { file_not_contains 'TODO\(SBDEV-2217\)' "$CTXTEST" \
                       && file_contains 'This class runs' "$CTXTEST"; }
run T-ctxlive "context-load test is LIVE, not TODO-gated (SBDEV-3257)" check_T_ctx_live
```

Same family, comment-only and non-breaking, but stale and worth the same pass:
`verify-SBDEV-2961-…sh:379` and `:383` (the `skip` row's reason string is *"v2 IT harness broken —
SBDEV-2217"*, while `OrderReleaseSectionQueryIT` is enabled and runs);
`verify-SBDEV-2870-…sh:26` and `:179`; `verify-SBDEV-2995-…sh:220`; `verify-SBDEV-2854-…sh:580`.

### M-Δ3 — three missed sites still attribute a defect to SBDEV-2217 that this change's own new text says is not SBDEV-2217

Present tense, in files this change did not touch, and the scanner cannot see them (the phrasing
"non-runnability" is not in `PREDICATE`):

- `src/test/java/net/aim_ai/wms/integration/StockHistoryClientIsolationIntegrationTest.java:38` —
  "makes this class independent of **SBDEV-2217, whose break is the onboarding chain's
  non-runnability from empty**"
- `src/test/java/net/aim_ai/wms/integration/query/ReplenishMonitorVisibilityIntegrationTest.java:37` —
  "independent of **SBDEV-2217 (the onboarding chain's non-forward-runnability)**"
- `src/test/java/net/aim_ai/wms/integration/schema/ReplenishmentMonitorViewSchemaIT.java:30` —
  "fully independent of **SBDEV-2217 (whose break is the onboarding chain's non-forward-runnability
  from empty, i.e. `V1.2.01` referencing `outbox_message` before it exists)**"

This change wrote the opposite twice: `ClientRepositoryIntegrationTest.java:269-270` —
*"the ticket this cited (SBDEV-2217) is closed and was **about `getNextSequenceNumber()` returning -1,
not Testcontainers**"* — and `BasePostgresIntegrationTest.java:36-38` says the same. So the repo now
answers "what was SBDEV-2217?" two different ways depending on which file you open, which is the exact
symptom AC-2 exists to end. Fix: replace "SBDEV-2217" in those three with the defect itself —
"the onboarding chain's forward reference to `outbox_message` in `V1.2.01`" — and drop the ticket
number, which belongs to an unrelated sequence-number bug.

### M-Δ4 — `sbdocs` L-3 is only 3-of-4 fixed: `wms2-keycloak-role-matrix.md:180` still says the lane is blocked

> `:180` — "This is the **only** gate on the branch that no test can evaluate — `standaloneSetup`
> cannot evaluate `@PreAuthorize` (RC-2) and **SBDEV-2217 blocks the `@SpringBootTest` lane** — so it
> is the entire residual of AC-5: one curl."

Present tense, in `3-Resources/` (the material `verify-docs` audits). `:290`, `:341` and `:780` were
corrected in this pass; `:180` was not. (`:900` is a dated 2026-08-17 changelog row and is correctly
left as history.) Fix `:180` with the same wording — noting it must be the **corrected** wording from
H-Δ1, not the wording currently at `:290`/`:341`/`:780`.

### M-Δ5 — missed site: `OutboxClaimOrderingIT:30` says a class is `@Disabled` that is not

> "This deliberately does NOT boot the Spring multi-tenant context (**`{@code SkuRestControllerIntegrationTest}` is @Disabled for that reason**)"

`SkuRestControllerIntegrationTest` carries **no** `@Disabled` — SBDEV-3240 rebuilt it onto
`BaseIntegrationTest` and it runs in the failsafe lane. Same claim family ("a lane/class cannot run"),
invisible to the scanner because `is @Disabled` is not in `PREDICATE`. This is the concrete instance of
the blind spot the docstring names; the first review found the same shape at
`OrderReleaseSectionQueryIT:203` (fixed) and this one was left. Fix: *"…does NOT boot the Spring
multi-tenant context — a design choice, not a constraint: the subject is pure SQL semantics."*

### M-Δ6 — missed site: `WebContextLaneContextTest:20-21` asserts every surefire-visible subclass is `@Disabled`

> "**Every surefire-visible subclass of those three base classes is `@Disabled`**; the rest are named
> `*IntegrationTest` (failsafe) or `*IT` (neither lane…)"

Both halves are now false: this very class is surefire-visible and enabled, `SdrReadGateEnforcementContextTest`
is surefire-visible and enabled, and `**/*IT.java` **is** in the failsafe `<includes>` (`pom.xml:67`
of the failsafe block) as of SBDEV-3239 slice F. This matters more than most, because it is the file
whose whole argument is "the claim needed a test, because the suite could not show it" — and it is now
the evidence *against* H-Δ1.

### M-Δ7 — scanner: a **fifth** break that reports `0 across 0 files` with **exit 0** and all four controls PASSED

Controls 3/4 assert that `CLAIM_FWD`/`CLAIM_REV` match one literal. They do **not** cover the
`[^.]{0,140}?` distance bound in the same regex — and the control literal
`"the @SpringBootTest lane is down (SBDEV-2217)"` has a **one-character** gap between a `SUBJECT`
alternative (`SpringBootTest`) and a `PREDICATE` alternative (`lane is down`). So the bound can be
tightened to almost nothing and the control still passes.

Measured (mutants written to scratchpad; `stale-lane-claim-scan.py` untouched):

```
### MUTANT: [^.]{0,140}? -> [^.]{0,1}?        (one sed, one anchor, both regexes)
against SBDEV-3257 worktree : controls 1-4: PASSED   candidate comment blocks: 0 across 0 files   EXIT=0
against origin/develop      : controls 1-4: PASSED   candidate comment blocks: 0 across 0 files   EXIT=0
# docstring: "0  all four controls passed, no stale claims found"

### MUTANT: [^.]{0,140}? -> [^.]{0,40}?       (a *plausible* count, not a zero)
against origin/develop      : controls 1-4: PASSED   26 across 21  ->  25 across 20
against SBDEV-3257 worktree : controls 1-4: PASSED    8 across  8  ->   7 across  7
```

This is the H-3 shape unmitigated: a clean bill of health, exit 0, every control green — and `{0,140}`
is exactly the kind of number someone tunes when a match looks over-broad.

Two more, same class, both with controls green:

```
### MUTANT: `if not filename.endswith(".java")` -> `.endswith("UnitTest.java")`
origin/develop: controls PASSED   26 across 21  ->  12 across 11     # 12 is the grep's wrong answer
### MUTANT: `if tags:` -> `if tags and origin == "block":`
origin/develop: controls PASSED   26 across 21  ->  18 across 18     # the exact M-1 loss, control 2 green
```

**Fix — cover the pipeline END TO END, not the pieces.** Every current control tests an input or a
regex; none tests that a *known real site in the tree* reaches the output. Add a fifth:

```python
# CONTROL 5 — END-TO-END. Controls 1-4 test inputs and regexes in isolation; none proves a real site
# in the tree reaches `hits`. A tightened distance bound ({0,140} -> {0,1}) reports "0 across 0 files"
# with exit 0 and controls 1-4 green; so does a narrowed file filter, or a `hits.append` that drops
# `//`-origin spans. This control names one block of each origin that MUST be reported.
E2E_CONTROL = {
    # (relative path fragment, origin) -> must appear in hits
    ("smoke/PutawayResolverContextLoadTest.java", "block"),
    ("unit/service/mobile/MobilePutAwayServiceUnitTest.java", "line"),
}
...
    reported = {(rel, org) for rel, line, tags, flat, org in hits}   # carry origin into hits
    missing = {c for c in E2E_CONTROL if not any(c[0] in r and c[1] == o for r, o in reported)}
    if missing:
        print(f"CONTROL 5 FAILED: known stale-claim blocks were not reported: {sorted(missing)}.\n"
              "A low or zero count from this run is an instrument artefact. Check the distance bound "
              "in CLAIM_FWD/CLAIM_REV, the file filter in scan(), and the hits.append condition.")
        return 2
```

Pick the two anchors from sites that are *deliberately* left as history (both are), so the control does
not go red the moment someone fixes a site. Add them to the negative-test list in the docstring, and
add a fifth sabotage recipe: *"5. distance: `{0,140}` → `{0,1}`"*.

### M-Δ8 — `line_spans > 0` is **not** sufficient for control 2, and control 2 does not enforce joining the way control 1 now does

Two distinct gaps, both demonstrated:

1. **The collector can produce spans that never reach the output.** The `if tags and origin == "block"`
   mutant above keeps `ctl["line_spans"]`, `ctl["line_file_seen"]` and `ctl["line_joined"]` all set —
   they are computed inside the loop, before `tags` is consulted — and loses **8 blocks on the real
   pre-fix population (26 → 18)** with control 2 green. That is precisely the M-1 loss control 2 was
   added to close, surviving control 2.
2. **The collector can be *partially* broken and control 2 stays green.** Drop the `+` from
   `re.finditer(r"(?:^[ \t]*//.*\n?)+", …)`, so each `//` line becomes its own span and no claim can
   span two `//` lines. `CONTROL_LINE_COMMENT_PHRASE = "why these are direct method calls"` sits
   **entirely on one line** of `UserControllerUnitTest`, so control 2 passes. Demonstrated on a
   synthetic tree containing both control files plus one wrapped `//` claim:

```
// Reflection only, because the v2 Testcontainers
// harness cannot boot in this module.

ORIGINAL : controls 1-4: PASSED   1 across 1 files   (java/Wrapped.java:2)
MUTANT 5b: controls 1-4: PASSED   0 across 0 files
```

   On the real pre-fix tree the loss happens to be **0** (no `//` claim straddles a break there), so
   this is latent rather than realised — but it is the asymmetry L-5 fixed for control 1 and did not
   fix for control 2.

**Fix (2):** give control 2 the same flat-and-not-raw treatment control 1 got, keyed on a phrase that
does straddle a break in a `//` run — e.g. in
`src/test/java/net/aim_ai/wms/unit/CustomMethodSecurityExpressionRootUnitTest.java:293-295`,
`"method-security advisor, so @PreAuthorize is never evaluated anywhere in the unit lane"` spans three
`//` lines:

```python
CONTROL_LINE_COMMENT_PHRASE = re.compile(r"never\s+evaluated\s+anywhere\s+in\s+the\s+unit\s+lane", re.I)
...
    if (filename == CONTROL_LINE_COMMENT_FILE and origin == "line"
            and CONTROL_LINE_COMMENT_PHRASE.search(flat)
            and not CONTROL_LINE_COMMENT_PHRASE.search(raw)):
        ctl["line_joined"] = True
```

**Fix (1)** is CONTROL 5 in M-Δ7.

### M-Δ9 — M-3: retitling the `<ul>` header left two statements below it contradicting the new header, and one contradicting `pom.xml`

The header is now correct and the arithmetic reconciles — I checked it: original `ALLOWED`
(`f5f64e4b`) had **8 entries** summing to **11** annotations (1+1+3+2+1+1+1+1); `e1001a21` removed the
two base-class entries and SBDEV-3240 (`f78c7347` + `ca3f384c`) removed "the last six". So "Eleven
annotations remained", "the 8 entries that existed", "The nine method-level ones" and "SBDEV-3240
removed the last six entries" are all mutually consistent. Good.

What the retitle left behind:

1. **`:41-43` vs `:54-55`.** New header: "…and were **not fixed then because they could not be
   *verified* then**". Second bullet, unchanged: "`BaseIntegrationTest` — deferred for ONE specific,
   unmeasurable risk, **not because the fix is unverifiable**." The header states as the reason for all
   eleven what the next bullet explicitly denies for one of them. This contradiction pre-dates the
   change, but the change rewrote the sentence that carries it. Fix the header:
   *"Eleven annotations remained when the rail was written. Each was left for its own reason, stated
   per bullet — not one blanket reason:"*
2. **`:65-68` vs `pom.xml:776`.** The same bullet says `MessageCleanupBatchServiceIT` "is an `*IT`
   class running in **NEITHER Maven lane** (SBDEV-3239 AC-5), so **that reading has never been
   executed and remains unmeasured**." `**/*IT.java` is now in the failsafe `<includes>`, and this
   class is in the failsafe `<excludes>` at `pom.xml:776` — where the *same commit* records a fully
   measured boot failure with the exact exception text, three pieces of corroborating evidence and a
   named cause. So the arch test says "never executed, unmeasured" while the pom says "measured, here
   is the stack". Fix: *"…is excluded from the failsafe lane (`pom.xml`, `MessageCleanupBatchServiceIT`
   — a `@MockitoBean MessageRepository` erases the repository's SDR metadata and `SdrRuleStartupCheck`
   throws at boot). It has now been executed and the failure is understood, but it is a test-side
   defect and the manager-name reading is still untested. Closing this: …"*
3. **`:113-115`** (inside the bullet this change rewrote): "…a SUBCLASS declaring `@ActiveProfiles`
   (`byName` reads the base class only — verified **none of the six current subclasses** does)".
   Measured: **22** subclasses, and I confirmed **none** declares an `@ActiveProfiles` *annotation*
   (the one grep hit is the phrase inside this very javadoc's sibling). So "none" is right and "six" is
   stale by ~4×. Fix: "verified none of its 22 current subclasses does (measured 2026-09-08)".

### M-Δ10 — `pom.xml`'s second block: "and pass in this lane" is an unverified green, and one of the six is not matched by the `<include>` it annotates

`pom.xml:731-737`: "All six exist today, **are enabled, and pass in this lane**: IdempotencyFilterIT,
LockOverviewViewIT, UnitloadBusinessServiceConcurrencyIT, StockunitBusinessServiceConcurrencyIT,
PickingorderBusinessServiceConcurrencyIT and ReplenishmentOrderMaintenanceServiceIntegrationTest."

*Exist* and *enabled*: verified — all six files present, none carries a class-level `@Disabled`
annotation (the one `@Disabled` string in `LockOverviewViewIT` is prose at `:33`), `@Test` counts
5/2/1/2/1/1. *Pass*: **not verified here** — I ran only the two smoke classes, and the failsafe lane
needs Docker. The PR's failsafe figure (353/0F/0E/46S) is consistent with it, but the sentence asserts
a green that this review did not reproduce.

Also: the block sits inside `<includes>` immediately above `<include>**/*IT.java</include>`, and
`ReplenishmentOrderMaintenanceServiceIntegrationTest` is matched by `**/*IntegrationTest.java`, not by
that line. Minor, but the note reads as annotating the include it is attached to.

---

## Low

- **L-Δ1 — `MobilePutAwayServiceUnitTest:1907-1909` now under-states the blocker and disagrees with the
  class it points at.** New text: "see SBDEV-3249, **which is the reason** `MobilePutawayServiceIntegrationTest`
  still cannot run it on H2." That class's own `@Disabled` reason
  (`MobilePutawayServiceIntegrationTest:31-35`) says *"SBDEV-3249 is **necessary but not sufficient** …
  this class **also** needs its fixture rebuilt as direct entity construction"*. Fix: "…see SBDEV-3249
  — one of two reasons `MobilePutawayServiceIntegrationTest` still cannot run it (the other is its
  removed `@Sql` fixture; read its `@Disabled` reason)."
- **L-Δ2 — `CLAUDE.md`'s L-2 replacement is now wrong on both path and status word.** "Those plans are
  the four now marked `status: superseded` under `sbdocs/1-Projects/wms2/plan/`". All four are at
  `sbdocs/4-Archieves/wms2/plan/` with `status: archived` + `superseded_by: SBDEV-3239` +
  `archived: 2026-09-08` (mtime 09:31 today, i.e. after this text was written — so it may have been
  true at the time). It is a four-name, path-and-word enumeration where a rule would not rot. Fix:
  *"Those plans carry `superseded_by: SBDEV-3239` in their frontmatter —
  `grep -rl 'superseded_by: SBDEV-3239' sbdocs/` finds them wherever they have been filed."*
- **L-Δ3 — "the unit lane" is used for two different things in one javadoc.**
  `PutawayResolverContextLoadTest:26` — "None of that is checked by **the unit lane** or by `javac`";
  `:42` (new) — "a `…ContextLoadTest` has been in **the unit lane** since it was written." A reader
  gets "the unit lane cannot prove this" and "this runs in the unit lane" ten lines apart. Say
  "**the surefire lane**" at `:42`.
- **L-Δ4 — AC-3's second half is unmet.** The ticket requires "Legitimate SBDEV-2217 references are
  left alone, **and the PR names them so the distinction is auditable**", listing seven. The PR body
  names none of them. (They *are* left alone — verified: `SequenceTransactionServiceConcurrencyIT`,
  `BasicServiceUnitTest` AC-5/AC-6, `BasePostgresIntegrationTest:36`, `IdempotencyFilterIT:29`,
  `ReturnAdviceAutoReceiveIntegrationTest:224`, `LockOverviewViewIT:33`,
  `ClientRepositoryIntegrationTest:269` all still present and all legitimate.) Add the list to the PR
  body — it is three lines and it is what makes AC-3 auditable.
- **L-Δ5 — baseline figures do not reconcile with the ticket.** AC-5 requires matching
  "6345 / 0F / 0E / 3S and 353 / 0F / 0E / 46S" (ticket, `develop` @ `743b03e0`); the commit message
  and PR say **6347** / 0F / 0E / 3S (`develop` @ `0dfcefc6`). The +2 is explicable — `0dfcefc6`
  merged PR #322 — but nothing in the PR says so, and a reviewer checking AC-5 sees a mismatch. Add
  one clause: "6347, not the ticket's 6345, because `0dfcefc6` merged PR #322 (SBDEV-3195), which
  added two tests."
- **L-Δ6 — `AppPostgresDBContainer:23-24` reads as a paradox.** "(SBDEV-3257: that section is what this
  sentence used to point at before it existed.)" Fix: "(SBDEV-3257 wrote that section; this
  cross-reference was dangling until then.)"
- **L-Δ7 — `TestClassTransactionManagerArchTest:55-56`: "Of its 13 subclasses (10 direct, 3 through the
  abstract `BaseControllerIntegrationTest`)".** Measured: **9 direct + 6 through
  `BaseControllerIntegrationTest` = 15**. Pre-existing and outside the edited hunks, but it is a count
  in a list this change rewrote. Either re-derive or drop the count.
- **L-Δ8 — `BasePostgresIntegrationTest:58` says "21 subclasses"; measured 22.** Pre-existing,
  untouched, and the arch test's new bullet cites this javadoc as its authority — so the two now
  inherit the same drift.
- **L-Δ9 — L-4 (broken wikilink `[[wms2-it-harness-broken-sbdev-2217]]`) not fixed.** Still at
  `1-Projects/wms2/plan/SBDEV-2736-…:792` and `SBDEV-2643-…:208` (the latter inside `related:`
  frontmatter, so `broken-links` will keep reporting it). Both are plan documents = dated history, so
  leaving them is defensible; the `related:` entry is the one worth deleting, since frontmatter reads
  as current.
- **L-Δ10 — the ClickUp ticket is still `Open`** with PR #324 raised. Per the standing convention it
  should be `pr submitted`.

---

## (a) Status of the first review's 18 findings

| ID | verdict | note |
|---|---|---|
| **H-1** | **fixed, then regressed** | The false causal attribution is gone at all four sites, and I verified more than the first reviewer could: both classes are **green today** (2/0F/0E/0S, measured). But the replacement text introduced **H-Δ2** (landlord URL) at two of the four, and the *same* SBDEV-3239 conflation reappears at seven other sites — **H-Δ1**. Net: the four sites are better, the repo is not. |
| **H-2** | **fixed** | All six `src/main` + `src/main/resources` non-migration sites corrected; `git grep SBDEV-2217 -- src/main` now returns only `V2.2.19`. Item 5 (`OptimisticLockRetry`) fixed **and its replacement verified true** — see below. Item 7 (the shell script) fixed. Item 6 (`V2.2.19`) correctly frozen; the *record* of it is missing (**M-Δ1**). |
| **H-3** | **fixed, incomplete** | Controls 3/4 added at `:110-111`/`:179-187`, exit 2 on sabotage. But they cover the alternation literals only, not the distance bound in the same regex — **M-Δ7** reproduces `0 across 0, exit 0` with all four green. |
| **M-1** | **fixed, incomplete** | Control 2 added and keyed on span origin, as suggested. Two residual gaps — **M-Δ8**. |
| **M-2** | **fixed** | Docstring `:13-23` now states all three units (9 lines / 26 blocks / 21 files / ~36 sentences) and dates them. I reproduced **26 across 21** on `origin/develop` and **8 across 8** on the branch — the figures are right. |
| **M-3** | **partly fixed** | Header and arithmetic now correct and internally consistent (8 entries / 11 annotations / last six by SBDEV-3240 — all verified against `git log`). Three statements below the retitled header still contradict it or a sibling — **M-Δ9**. |
| **M-4** | **fixed** | The new text names `allowListJustificationsMustStillHold`, and `BasePostgresIntegrationTest:57-59` records that same rule firing. The rule exists (`:307`) and the chronology holds: the justification predicate was added at `19fa387c` (2026-09-07), *after* SBDEV-3239's `0984435e`, which is why the in-body comment at `:311-322` can say the ratchet stayed green through that change without contradicting it. |
| **M-5** | **fixed** | "**18** classes … (Measured 2026-09-08 …, excluding `PostgresTestHarnessPinTest`)". Verified: 19 files match, 18 excluding the pin test; **none of the 18 calls `withReuse`**. |
| **M-6** | **fixed** | `OrderReleaseSectionQueryIT:200-205` re-tensed correctly and keeps the advice. |
| **M-7** | **fixed, carries H-Δ1** | `MethodSecurityEnablementContractTest:291-292` re-tensed; the replacement clause is one of the seven H-Δ1 sites. |
| **M-8** | **fixed on facts** | Both `pom.xml` blocks now agree; `b3262008` ("restore the 6 deleted stubs") and `691f7c6f` ("write 3 of the 6 stubs for real") verified by `git show`; all six exist and are enabled. "Pass" unverified here — **M-Δ10**. |
| **L-1** | **fixed** | `import org.junit.jupiter.api.Disabled;` removed from `OrderReleaseSectionQueryIT`, and I confirmed independently that the identifier appears nowhere in the file (only prose) — the import really was unused. |
| **L-2** | **partly fixed** | The `~20s of a ~225s suite` figure is now dated ("on 2026-09-06") with a re-measure instruction ✓. The count was replaced by four names, which are now wrong on path and status word — **L-Δ2**. |
| **L-3** | **partly fixed** | 3 of the 4 present-tense sites in `wms2-keycloak-role-matrix.md` corrected (`:290`, `:341`, `:780`); `:180` missed — **M-Δ4**. `:900` correctly left as a dated row. And the three corrections carry **H-Δ1**. |
| **L-4** | **not fixed** | **L-Δ9**. Defensible for the prose site, less so for the `related:` frontmatter entry. |
| **L-5** | **fixed** | `:144` — `if CONTROL_PHRASE.search(flat) and not CONTROL_PHRASE.search(raw)`, exactly as suggested, with `comment_blocks` now yielding raw text. The line-wrap is enforced, not intended. |
| **L-6** | **confirmed, still clean** | I re-scanned all 36 changed `.java` files' javadoc blocks with `{@code}`/`{@link}` contents stripped. Every `<s>`, `<b>`, `<i>`, `<em>`, `<ul>`, `<li>`, `<pre>` pair balances, including the new `<s>…</s>`. Only pre-existing generic-type false positives (`<T>` in `OptimisticLockRetry`, `<String>` in `UserControllerUnitTest:848`). No malformed `{@…}` inline tag anywhere in the change. |
| **L-7** | **fixed** | The author adopted the suggested short form verbatim — `"Tracked: SBDEV-3258. (SBDEV-3239 above is the shipped harness fix, not the blocker.)"` — at all three sites, and the sentence a reader sees first is still the actual blocker. |

---

## (b) What I verified true, and what I could not check

### Verified true (with the instrument)

| claim | how |
|---|---|
| **Both `smoke/*ContextLoadTest` classes are GREEN, today, on this commit** | Own detached worktree at `c526d100`; `mvn -o -Dtest='PutawayResolverContextLoadTest,ReplenishReassignContextLoadTest' test` → `Tests run: 2, Failures: 0, Errors: 0, Skipped: 0`, **BUILD SUCCESS**. This is the thing the first review could prove only as "wired". |
| …and they have been **in the surefire lane** since written | Surefire declares no `<includes>` (Maven defaults match `*Test`), and its `<excludes>` have been exactly `**/*IntegrationTest.java` + `**/*E2ETest.java` since `617411ee`, **2026-02-04** — before `0fc1014e` (2026-08-09) and `232a84c2` (2026-07-20). Both classes extended `BaseRollbackIntegrationTest` from their first commit (`git show`). |
| **The non-behavioural claim holds on the FINAL tree** | Independent Java lexer (tracks `"`, `'`, text blocks, escapes) over all **36** changed `.java` files, comparing the comment-stripped code-token stream and the ordered literal list against `origin/develop`. **31 of 36 identical on both.** The five deltas are *exactly* the three stated: `+` in an `@Disabled` reason in `ClientRepositoryIntegrationTest` (58→59 literals), `FixLocationAssignmentServiceIT` (13→14) and `TransferLaneLeakOnCancelIT` (10→11); one shortened `.as(...)` in `UserControllerUnitTest` (390→390); one removed `import Disabled` in `OrderReleaseSectionQueryIT`. No import, signature, annotation attribute other than `@Disabled` text, control-flow statement or assertion subject changed. |
| the removed `Disabled` import was genuinely unused | `Disabled` appears in `OrderReleaseSectionQueryIT` only inside prose; no annotation. |
| the shell-script edit cannot affect execution | `verify-authorization-join-table-keys.sh:14-16` — the change is entirely inside `#` comment lines; the lexer-equivalent check is trivial here and the diff confirms it. |
| **the `V2.2.19` freeze decision is correct** | `application.properties:166` `app.flyway.migrate-on-startup=true`; `StartupFlywayMigrator:39` records `validateOnMigrate` on with the default hard stop; `db/migration/README.md:18` — *"`flyway validate` then fails on every boot"*; `README.md:25` names `validateOnMigrate=true`; and the runbook §8.1 (`wms2-apply-pending-tenant-flyway.md:607-626`) says explicitly that `flyway repair` is **the wrong tool for a content change**. A one-byte comment edit would red `validate` on every boot in every environment that has run V2.2.19, with no clean remedy. **Leaving it is right.** |
| `OptimisticLockRetry`'s replacement text is true | `StockunitBusinessServiceConcurrencyIT` is matched by the failsafe `<include>**/*IT.java</include>` and is not among the three `<excludes>`; it carries no `@Disabled`; its **AC-1** (`:166-245`) drives a concurrent `FOR UPDATE` lock flip on the destination location and asserts a `BusinessException` containing "Destination location", with the interleaving-independence argument stated in the javadoc — the pin is real, though the assertion is on the *refusal*, not directly on the lock mode. And "which that path still does not use" is true: in `src/main`, `OptimisticLockRetry` is injected **only** into `MobilePalletizingService` (`:50`, `:67`). |
| the `pom.xml` first-block commit facts | `git show b3262008` — *"restore the 6 deleted stubs; write LockOverviewViewIT for real"*; `git show 691f7c6f` — *"write 3 of the 6 stubs for real — 8 tests, all mutation-checked"*; deletion was `ac0ef2b1`, all on the SBDEV-3239 branch, i.e. one PR. |
| the six named classes exist and are enabled | files found; class-level `@Disabled` annotation count **0** for all six; `@Test` counts 5/2/1/2/1/1. |
| **all six `src/main` H-2 sites are fixed** | `git grep -n SBDEV-2217 -- src/main` → one hit, `V2.2.19:55`, the deliberately frozen one. |
| the scanner's own reported figures | reproduced: `26 across 21` on `origin/develop`, `8 across 8` on the branch, exit 1, all four controls PASSED. |
| the 8 remaining scanner candidates' classification | read all 8. Six are correct past-tense history: `IdempotencyFilterIT:29`, `OnHandQueryContractUnitTest:16`, `UserGroupQueryContractUnitTest:20`, `UserRoleQueryContractUnitTest:26`, `UserRoleServiceTransactionBoundaryTest:44`, `MobilePutAwayServiceUnitTest:1893` (with **L-Δ1**). The two smoke sites are **not** merely history — they carry **H-Δ2**. |
| no `BasePostgresIntegrationTest` subclass declares `@ActiveProfiles` | scanned all 22; zero annotation hits (the one grep match is javadoc prose). So the arch test's "none … does" is right; its "six" is not (**M-Δ9.3**). |
| javadoc HTML and inline tags in the new hunks | see L-6 row above. |

### Could not check, and why

- **That the full surefire and failsafe lanes match the pre-change baseline exactly** (6347/0F/0E/3S,
  353/0F/0E/46S). I ran only the two smoke classes plus a throwaway probe, in my own worktree. The
  failsafe lane needs Docker and several minutes; the lexer result makes a *compile* regression
  structurally impossible, but "identical counts" is the author's measurement, not mine. The one place
  this matters is `pom.xml`'s "and pass in this lane" (**M-Δ10**).
- **Whether the six restored `*IT` classes individually pass.** Same reason.
- **Whether `V2.2.19` has actually been applied in every environment.** I did not query any tenant
  `flyway_schema_history`. It does not change the verdict — the freeze is correct whether or not it has
  run everywhere, because `validate` runs on every boot.
- **Whether `wms2-keycloak-role-matrix.md`'s `:290`/`:341`/`:780` edits are inside this PR.** They are
  not: `sbdocs/` is not in the `wms2-api` repo, so those three corrections (and **M-Δ4**) ship outside
  PR #324 and nothing gates them.
- **The `~20s of a ~225s suite (~9%)` figure in `CLAUDE.md`.** Not re-measured. It is now dated, which
  is the right treatment.
- **Whether any `sbdocs` plan/review artefact under `1-Projects/`, `2-Areas/` or `4-Archieves/` still
  carries a present-tense claim.** I swept `3-Resources/`, `2-Areas/`, `9-System/` and `INDEX.md`
  exhaustively for both the ticket number and the claim phrasings, and I read every `9-System/scripts/`
  hit. I did **not** read the ~50 plan/review files under `1-Projects/` and `4-Archieves/`; those are
  dated artefacts and out of AC-2's scope.
