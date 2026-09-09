# SBDEV-3156 — review lane 3 of 3: AC conformance and fact-check

**Lane scope.** AC-by-AC conformance, quantitative/completeness fact-check, stale-claim sweep, tier
judgement. NOT code correctness (lane 1) and NOT authorization semantics (lane 2).

**Basis of measurement.**
- `v2/wms2-api` @ `3594108a` in a private detached worktree at `/tmp/claude-1000/review-3156-conformance`
  (parent = `452d3ed4` = `origin/develop` at fix time). Built and run with sdkman JDK, `mvn -o`.
- `v2/wms2-web-ui` @ `ca04ce2` in `/tmp/claude-1000/review-3156-webui`, plus a second worktree at
  `origin/develop` (`3117aca`) for the baseline. `node_modules` symlinked from the main checkout and
  **deleted before any git operation**; both worktrees verified clean (`git status --porcelain` empty).
- `sbdocs/` read in place.

---

## 1. Verdict up front

The wms2-api half (AC-1 … AC-5) is **sound and well over-delivered**. Every number in it that I
re-derived came back exact. Three mutants re-run, all attributable.

The wms2-web-ui half (**AC-6**) is **NOT met, and should not merge as written.** The "orphaned test"
is not orphaned. It is byte-identical to a test that was **committed on 2026-08-27 at `b218de7` and
deliberately deleted 15 minutes later at `d29348c`** ("review F1-F7 — *the pin missed the hazard it
exists for*"), which replaced it with the superior `test/util/reprentLabelHostSet.spec.js` — **live on
`origin/develop` today**. Landing `ca04ce2` resurrects the superseded version alongside its own
successor. I proved the regression by mutation: a Nuxt auto-import host leaves the newly-landed spec
**GREEN** and reds the existing one. Detail in §5.

---

## 2. AC conformance table

| AC | Verdict | Evidence |
|---|---|---|
| **AC-1** — inventory of every `@Secured`/`@RolesAllowed`/`@DenyAll`/`@PostAuthorize` in `src/main`, derived by reflection or grep over the deployed surface, not assumed | **MET** (CONFIRMED — independently re-derived) | It *was* derived, twice, and my re-derivation agrees exactly. `git grep -nE "@(Secured\|RolesAllowed\|DenyAll\|PermitAll\|PostAuthorize)" 452d3ed4 -- 'src/main/**/*.java'` → **exit 1, zero hits**. `find target/classes -name '*.class' \| wc -l` → **650**, matching the claim to the unit. Positive control reproduced: 13 source files mention `@PreAuthorize`, exactly **4** carry a real annotation (`AdminActionController` 1, `AdminController` 9, `ReplenishmentReconciliationController` 1, `PutawayConfigService` 2 = 13 sites), and the other **9** are javadoc/comment-only — I classified all 13 by hand. One gap the ACs did not ask for and the fix closed anyway: the third-party jar scan (§4 has its errata). |
| **AC-2** — a decision recorded for (a) or (b), justified by the count | **MET** (CONFIRMED) | Direction (b) recorded in the ticket triage comment, the commit message, `MethodSecurityConfig`'s new class comment (:18-24) and `MethodSecurityEnablementContractTest`:78-99, each time with the zero-count as the justification. The decision is traceable from four places without reading the ticket. |
| **AC-3** — "all enablement flags that remain `true` are pinned … each with the reason it is on" | **MET, as deliberate over-delivery — and the over-delivery is the right call, not a misreading** | Literally, AC-3 constrains only the flags that remain `true`: that is `prePostEnabled` alone, and it was already pinned at `:65-68` before this ticket. So the literal AC-3 was satisfiable with **zero new code**. The implementation instead pins all three, with a reason on each (`securedEnabledStaysOff` :107-122, `jsr250EnabledStaysOff` :124-138). Call it what it is: the AC as written is **too weak to close the ticket's own thesis** — the ticket's stated fear is "someone tidies up `MethodSecurityConfig`", and a pin on only-the-true-flags cannot see the *reverse* edit (a flag going `false`→`true`, silently re-arming three annotations the ban rule forbids). Pinning the `false` values is the invariant-over-instance form. **Not** a misreading: `:71` labels it explicitly as reading AC-3 as "pin every attribute, with its reason". Conformance verdict: MET; the extra two pins are the part that actually earns the ticket. |
| **AC-4** — the pin is mutation-checked; flip a flag to `false`, confirm the test reds; a pin never observed failing is not evidence | **MET** (CONFIRMED — I re-ran 3 of the 6 mutants myself, all attributable) | Baseline first: `mvn -o test -Dtest='MethodSecurityEnablementContractTest,MethodSecurityAnnotationSurfaceArchTest'` → **20 tests, 0 failures, BUILD SUCCESS**. Then: **M4** `securedEnabled=false→true` → exactly **1 failure**, `securedEnabledStaysOff:121`, message opens *"securedEnabled is back ON"* + `Expecting value to be false but was true`; other 17 green. **M1** `@jakarta.annotation.security.DenyAll` planted on `ReplenishmentReconciliationController#reconcileStrandedReservations` **fully qualified** → 1 failure naming `net.aim_ai.wms.controller.ReplenishmentReconciliationController#reconcileStrandedReservations carries @DenyAll`; this simultaneously proves the bytecode-over-grep design claim, since a source grep for `@DenyAll` at line start would miss that form. **M3** scan root → `net.aim_ai.wmsZZ` → the vacuity guard fires alone at `:97` naming itself; the ban test stayed green, which is precisely the false-green the guard exists for. Every kill is an **AssertionFailedError with a named subject** — no `NoSuchMethodException`, no setup NPE. Tree restored to clean after each. |
| **AC-5** — if (b): every migrated annotation has a test showing the new gate denies whom the old one denied | **VACUOUS — and the strike is legitimate, not a dodge** | AC-5 is conditioned on migration ("*every migrated annotation*"). The migration set is empty because the usage count is zero, and that zero is the measured premise of AC-2, not an assumption. Two independent instruments plus a positive control put it at zero, and I reproduced both. A vacuous AC is a dodge only when the emptiness is asserted rather than measured, or when the AC could be *made* non-vacuous by widening scope — neither holds: there is no annotation to migrate, so there is no "whom the old one denied" to preserve. Marking it struck rather than ticked is the honest disposition. **However:** the second half of AC-5 — "*the full suite is compared against a freshly measured baseline by name*" — is **not** conditioned on migration in any reading I find natural, and I see **no full-suite figure anywhere** in the commit message, the ticket, or the code comments. That half is **NOT MET**. See finding F3. |
| **AC-6** — land `reprintLabelHostSet.spec.js` with the stale always-red claim removed | **NOT MET** | Three sub-parts. (i) *Matches the sbdocs file except for the corrected header* — **MET**, `diff -u` shows one hunk, the header only. (ii) *It passes* — **MET, CONFIRMED**: `PASS test/components/handlingUnits/popups/reprintLabelHostSet.spec.js`, and the full suite at `ca04ce2` is **76 suites / 1117 tests / 1117 passed**. (iii) *The stale claim really was corrected rather than reworded* — **MET for this file, CONFIRMED**: the replacement names a re-measured figure, keeps the original observation, and identifies the real cause (`zpl-renderer-js@^4.0.0` at `package.json:76`, absent from `node_modules` — I verified the absence and the two load failures, both under `test/components/admin/labelPrinting/`). **But the AC as a whole fails on premise:** the file is a resurrected, deliberately-deleted predecessor of a test already on `origin/develop`, it is provably weaker, and it re-asserts two claims its own successor records as measured errors. §5. |

---

## 3. Fact-check table — quantitative and completeness claims

Method: every number re-derived from the tree, not read from a second document. Sentences containing
*every / only / all / no / exactly / none* attacked first.

| # | Claim (and where) | Verdict | How verified |
|---|---|---|---|
| 1 | "**650** compiled class files" (commit msg; `MethodSecurityConfig`:20; contract test :89) | **CONFIRMED exact** | `mvn -o clean test-compile` then `find target/classes -name '*.class' \| wc -l` → `650`. |
| 2 | "**304** dependency jars" (commit msg; `MethodSecurityConfig`:21; contract test :93) | **CONFIRMED exact** | `mvn -o dependency:build-classpath`, split on `:`, count `*.jar` → `304`; `sort -u` also `304`, so no double-count inflating it. |
| 3 | "**38** `@PreAuthorize` occurrences" | **CONFIRMED exact** | `git grep -o "@PreAuthorize" 452d3ed4 -- 'src/main/**/*.java' \| wc -l` → `38`. (At `3594108a` it is 40; the fix's own javadoc adds 2. The 38 is correctly the pre-fix figure.) |
| 4 | "**4** carrier classes" | **CONFIRMED exact** | Hand-classified all 13 mentioning files. Carriers: `AdminController`, `AdminActionController`, `ReplenishmentReconciliationController`, `PutawayConfigService` — exactly the four named. |
| 5 | "**13** source files" / "**9** mention it only in javadoc" | **CONFIRMED exact** | `git grep -l` at parent → 13 files, listed. 13 − 4 = 9, and I confirmed each of the 9 has no line-initial `@PreAuthorize`. |
| 6 | "annotation-descriptor scan … **jakarta.\* and javax.\*** spellings: **0** for the same five" | **CONFIRMED** | Reproduced over `target/classes` and cross-checked with `git grep`; both spellings zero. The `BANNED` set in the arch test carries both, and `Secured` correctly appears once (it has no `javax` twin). |
| 7 | "A third scan over all 304 dependency jars found the descriptors **only** in spring-security-core's **four PROCESSOR classes** and resteasy-core's `RoleBasedSecurityFeature`" | **⚠ FALSE as stated — both the "only" and the "four". Conclusion survives; enumeration does not.** | I scanned all 304 jars for the 7 descriptors (Python `zipfile`, every `.class` entry, 0 unreadable jars). Descriptors appear in **4 jars, not 2**: `spring-security-core-6.5.7` (**8** classes, not four: `Jsr250MethodSecurityMetadataSource`, `Jsr250SecurityConfig`, `Secured` itself, `SecuredAnnotationSecurityMetadataSource` + its `$SecuredAnnotationMetadataExtractor`, `AuthorizationManagerBeforeMethodInterceptor`, `Jsr250AuthorizationManager$Jsr250AuthorizationManagerRegistry`, `SecuredAuthorizationManager`); `resteasy-core-6.2.9.Final` (`RoleBasedSecurityFeature` ✓); **`spring-security-config-6.5.7`** (`GlobalMethodSecurityConfiguration`, `GlobalMethodSecurityBeanDefinitionParser`) — omitted entirely; **`jakarta.annotation-api-2.1.1`** (the annotation definitions) — omitted entirely. **The material conclusion is still right:** I `javap -v`'d all six candidate classes and **none CARRIES** any of the four — every occurrence is a constant-pool *reference*, and both spring-security-config classes are `@Deprecated`/`@Bean`-only. So *"No bean in the deployed context CARRIES one"* stands **CONFIRMED**. Fix the sentence, keep the finding. Textbook repo pattern: the plain counts (650, 304, 38, 4, 13, 9) all survived; the one sentence with **only** broke. |
| 8 | "**1117** tests / **76** suites in wms2-web-ui", attributed *"Re-measured 2026-09-01 on `origin/develop`"* | **⚠ NUMBERS CONFIRMED, ATTRIBUTION WRONG** | At `ca04ce2`: `76 suites / 1117 tests / 1117 passed / 2 suites failed to run` — exact. At **`origin/develop` (`3117aca`)**, measured separately: **75 suites / 1115 tests**. The figure quoted as "on origin/develop" is the with-the-new-file figure; the new spec contributes 1 suite and 2 tests. Minor, but it is the same class of misattributed measurement this ticket exists to police, sitting inside the sentence that corrects a misattributed measurement. |
| 9 | "2 suites fail to **LOAD** because `zpl-renderer-js@^4.0.0` is declared in package.json but missing from the local node_modules" | **CONFIRMED, cause and all** | `package.json:76` declares `"zpl-renderer-js": "^4.0.0"`; `node_modules/zpl-renderer-js` does not exist; both failures are `Cannot find module 'zpl-renderer-js/dist/index.external.esm.js'`, in `test/components/admin/labelPrinting/`. Genuine correction, not a rewording. |
| 10 | "**5692/0**" (quoted historical figure from SBDEV-3017) | **CONFIRMED as an accurate quote** | The ticket description quotes the review lane as `5692 / 0 failures / 0 errors / 67 skipped`; `SBDEV-3017-B1…md:3919-3921` records "full suite **GREEN at 5692**" for that same mutant set (the round's own clean suite being 5693). The commit reproduces 5692/0 verbatim in four places. Checked as a quote, per instruction — not as a currently-true number. |
| 11 | "**three** OMS-called production routes" | **CONFIRMED exact** | `Sbdev3017TrancheGateContextTest:277-279` — `row("ClientController","/v3/client/create")`, `row("BoxTypeController","/v3/boxType/create")`, `row("ShipperIdController","/v3/shipperId/create")`. Three, and the names match. |
| 12 | Both new tests actually run in the default lane | **CONFIRMED** | `pom.xml` surefire 3.2.5 declares **no `<includes>`** and excludes only `**/*IntegrationTest.java` / `**/*E2ETest.java`. Both classes end in `Test` → default includes catch them. Worth stating because this repo has 28 `*IT` classes that run in neither lane. |
| 13 | Contract test :26 — "all **20** `@PreAuthorize(IS_SB_ADMIN)` sites become inert" | **PRE-EXISTING and inconsistent with the tree** (not introduced here) | Actual line-initial `@PreAuthorize` sites in `src/main`: **13**, and the same javadoc's "thirteen" is right. The `MethodSecurityEnablementContractTest` diff is **+69/−0** (`git diff --stat`), so this commit did not touch or inherit responsibility for the sentence. Flagging it because the file's own thesis is that counts must be enumerated; `PutawayConfigService:363` suggests "20" is a stale decision-set size ("split 9 move / 11 stay"). Out of scope for this ticket; worth a one-word fix if the file is opened again. |

### Cross-reference resolution

| Reference | Resolves? | Note |
|---|---|---|
| `FunctionGuardArchTest:355-357` (**new**, cited in `MethodSecurityAnnotationSurfaceArchTest`:33 for the fully-qualified-annotation escape) | **NO — off by ~114 lines** | The file is at `src/test/java/net/aim_ai/wms/unit/**config**/FunctionGuardArchTest.java` (1030 lines). `:350-360` is replenishment-path narrative. The real text is **`:469-471`**: *"Resolved by REFLECTION, never by a source-text grep: a fully-qualified `@net.aim_ai.wms.security.RequiresFunction` SURVIVED a grep-based version of this rule (measured 2026-08-22)"*. The **claim is true**; only the citation is wrong. |
| `FunctionGuardArchTest:395` (**new**, cited at `MethodSecurityAnnotationSurfaceArchTest`:47 for non-vacuity-guard placement) | **NO — off by ~86 lines** | `:390-400` is `bulkTransferStock` gating rationale. The real guard is **`:481`**: `assertThat(scanned).as("an empty scan makes the assertion below vacuous").isNotEmpty();`. Claim true, citation wrong. |
| `PublicHandlerContractArchTest` (**new**, cited for the landlord-subpackage escape) | **YES** | `src/test/java/net/aim_ai/wms/unit/security/PublicHandlerContractArchTest.java`, class javadoc **`:42`** names `net/aim_ai/wms/landlord/controller/` as escaping "every rail in silence"; `:285-286` is the live assertion. Exactly as described. |
| `FunctionGuardStartupAssertion:74` (pre-existing, in the 3017 test) | **YES, exact** | `:74` is the `throw new IllegalStateException(` for unannotated handlers on guarded controllers. |
| `Sbdev3017OmsCarveOutSourceContractTest` | **YES** | `src/test/java/net/aim_ai/wms/security/Sbdev3017OmsCarveOutSourceContractTest.java`, `CARVE_OUT_PATHS` at `:58`. |
| `MethodSecurityAnnotationSurfaceArchTest` named from other files | **YES — from three, not two** | `Sbdev3017TrancheGateContextTest:477`, `MethodSecurityEnablementContractTest:103/:115/:134`, and `MethodSecurityConfig:31` (src/main). All spellings correct. |
| `SBDEV-3157` | **YES** | Real, shipped: `SdrSurfaceInventoryContextTest`, `SdrWriteWithdrawalContextTest`, `SdrUncalledSurfaceNotExportedContextTest`. |
| `SBDEV-2870` | **YES** | Real: `UserControllerUnitTest:702/:846`, `UserAdministrationControllerUnitTest:41`, and the `MethodSecurityEnablementContractTest:234` residue note. |
| `FunctionGuardArchTest:777-779` (pre-existing, contract test :30) | **NO — real text at `:848-850`** | Untouched by this commit; noted for the record. |

**Pattern.** Of 3 line-number citations introduced by this commit, **2 are wrong** — and the commit
message boasts *"the ticket's own citation … has drifted; the pin is at :65-68. Correcting citations is
free."* The corrected citation is right; the two new ones are not. Both point into a 1030-line file in a
package (`unit.config`) different from where a reader would look. All the *symbolic* references resolve;
only the numeric ones drift, which is the argument for citing `Class#member` over `File:line`.

---

## 4. Findings

**F1 — BLOCKER (AC-6).** `ca04ce2` resurrects a deliberately-deleted test and duplicates a live one.
See §5 for the full derivation and the mutation proof. Recommend: **drop `ca04ce2`**.

**F2 — MEDIUM (fact).** The dependency-jar enumeration in the commit message, `MethodSecurityConfig`:21-23
and `MethodSecurityEnablementContractTest`:93-96 is wrong on *"only"* and on *"four"*. Fact-check row 7.
Minimal fix, same wording everywhere:
> A scan of all 304 dependency jars finds the descriptors in four jars — `jakarta.annotation-api` (the
> definitions), `spring-security-core` (8 classes: the JSR-250/`@Secured` metadata sources and
> authorization managers these flags switch on), `spring-security-config` (2 deprecated legacy config
> classes) and `resteasy-core` (`RoleBasedSecurityFeature`, a JAX-RS feature that READS `@RolesAllowed`,
> arriving transitively via `keycloak-admin-client`). `javap` confirms **none of them CARRIES** one: every
> occurrence is a constant-pool reference. No bean in the deployed context carries one.

**F3 — MEDIUM (AC-5, second half).** "*the full suite is compared against a freshly measured baseline by
name*" is unaddressed: no wms2-api suite figure appears anywhere in the deliverable. Given the change
touches `src/main` and adds a whole-tree ArchUnit import, a named full-suite comparison is cheap and is
the floor's fifth item. I did not run the full wms2-api suite in this lane (see §8), so I cannot supply
it. Recommend a `mvn -o clean test` count against the known-green develop baseline before merge.

**F4 — LOW (citations).** `FunctionGuardArchTest:355-357` → `:469-471`; `FunctionGuardArchTest:395` →
`:481`. Recommend replacing both with symbol-anchored forms
(`FunctionGuardArchTest`'s reflection-not-grep comment / its `scanned` non-vacuity guard) so they cannot
drift again — which is the lesson the same javadoc is trying to teach.

**F5 — LOW (attribution).** `ca04ce2`'s header and commit message attribute `76 suites / 1117 tests` to
`origin/develop`; `origin/develop` is `75 / 1115`. If any part of AC-6 survives, say "with this spec
present" or quote 75/1115.

**F6 — LOW, pre-existing.** Contract test `:26` says "20 `@PreAuthorize(IS_SB_ADMIN)` sites"; the tree
has 13. Not introduced here (+69/−0). Fix opportunistically.

---

## 5. AC-6 in detail — the orphan is a resurrection, and it is the weaker version

**The history, from `git log --all` in `v2/wms2-web-ui`:**

| commit | when | what |
|---|---|---|
| `b218de7` | 2026-08-27 12:53 | **adds** `test/components/handlingUnits/popups/reprintLabelHostSet.spec.js`, +77 |
| `d29348c` | 2026-08-27 13:08 | *"review F1-F7 — the pin missed the hazard it exists for"*: **deletes** that file (−77) and **adds** `test/util/reprentLabelHostSet.spec.js` (+116) |
| `a10aca0` | later | corrects two false claims in the survivor's header |
| `3117aca` | = `origin/develop` today | survivor present; `git cat-file -e origin/develop:test/util/reprentLabelHostSet.spec.js` succeeds |
| `ca04ce2` | 2026-09-01 | **re-adds the deleted `b218de7` file**, so both now exist |

`diff` of the sbdocs orphan against `git show b218de7:…` → **IDENTICAL**. The "orphaned, committed on no
branch" file is bit-for-bit the version that was committed and then withdrawn fifteen minutes later,
by a commit whose subject line is that the pin *missed the hazard it exists for*.

**Why the check missed it.** The triage keyed on the **path**
(`test/components/handlingUnits/popups/reprintLabelHostSet.spec.js`) across every remote ref. The
successor lives at a different path under a different spelling
(`test/util/repr**e**ntLabelHostSet.spec.js` — the `reprent` typo carried into the test name). A path
sweep cannot see a rename. This is the same failure the file's own header warns about — *match the
component, not the import; a name is not the thing* — applied to itself.

**The regression, mutation-proved (CONFIRMED, both specs run together).** `nuxt.config.js` sets
`components: true`, so the popup is globally auto-registered as `HandlingUnitsPopupsReprentLabel`; a
fourth host can mount it with **no import at all**. I planted exactly that:

```vue
<!-- components/handlingUnits/ZZMutantAutoImportHost.vue -->
<template><div><handling-units-popups-reprent-label /></div></template>
```

```
PASS test/components/handlingUnits/popups/reprintLabelHostSet.spec.js      <- the NEWLY LANDED spec
FAIL test/util/reprentLabelHostSet.spec.js                                 <- the one already on develop
  ● the host set has not changed
    +   "components/handlingUnits/ZZMutantAutoImportHost.vue"
```

The new spec matches `new RegExp('\\breprentLabel\\b')` — case-sensitive camelCase. The survivor matches
`/reprent[-_]?label/i`. The survivor's header records this exact mutant at `:29-35`: *"measured: the
first version of this spec stayed green against exactly that mutant."* The newly-landed file **is** that
first version, and it is still green against it. Mutant removed; tree clean.

**Three further regressions in the resurrected version**, each one something `d29348c`/`a10aca0`
deliberately fixed:

1. **"One member per screen" is wrong arithmetic.** New spec `:44` — *"the ANY-of member each one
   requires"*, one string per host, three members total. Survivor `:11-18` — *"The gate is ANY-of four
   members over THREE screens — one screen contributes two, so 'one member per screen' is wrong
   arithmetic"*: `containerTable.vue` contributes **both** `WEB_UI_VIEW_CONTAINER` **and**
   `WEB_UI_VIEW_STOCK_UNIT`, because `pages/handlingUnits/handling-units.vue` mounts `ContainerTable`
   and `StockUnitsTable` on one page whose menu leaf is itself ANY-of those two.
2. **`WEB_UI_VIEW_STOCK_UNIT` is unfenced.** The new spec's table never names it, so nothing there
   notices it being deleted from the annotation as apparent dead weight. The survivor's third `it()`
   exists for precisely that member and says so at `:107-111`.
3. **It re-asserts a distinctness check that was removed for going red on a correct config.** New spec
   `:84` — `expect(new Set(members).size).toBe(members.length)`. Survivor `:109-111`: *"An earlier
   version asserted member DISTINCTNESS instead, which ANY-of semantics do not require and which went
   red on a CORRECT config — a legitimate fourth Handling-Units screen reusing `WEB_UI_VIEW_CONTAINER`."*
   That is a latent false-red planted into a repo that already measured and removed it.

Also: the survivor lacks nothing the new file has, and adds a "the popup still exists at the path the
scan assumes" test (`:90-95`) that the new file does not have — so moving or deleting the popup is
invisible to the newly-landed spec while every import dangles.

**Independent re-derivation of the host set (CONFIRMED, as asked).** `grep -rln reprentLabel components
pages` minus the popup itself → exactly the three files in `EXPECTED_HOSTS`. Import spellings confirmed:
`containerTable.vue:137` relative (`'./popups/reprentLabel.vue'`), `inventoryOnLane.vue:74` and
`inventoryOnLaneTable.vue:74` absolute (`'~/components/handlingUnits/…'`) — so the "grep for the
full-path form finds 2 of 3" trap is real. Two other files match the different string `reprintLabel`
(`components/reports/parcelPickingReport.vue`, `components/reports/popups/reprintToteLabel.vue`); I
checked both and they dispatch `reports/parcelPicking/reprintLabels`, a different endpoint. The only
caller of `POST /unitLoad/reprintLabel` is `store/handlingUnits/container.js:206`. **Host set = 3, as
claimed.**

**Recommendation.** Drop `ca04ce2` entirely and close AC-6 as *already shipped, under a different name,
by SBDEV-3017 `d29348c`*. Then delete `sbdocs/9-System/orphaned-tests/reprintLabelHostSet.spec.js` and
its README row, and record in the README that the intake check must key on the **invariant**, not the
path — `git log --all --follow` and a content search, not a path search across refs. If instead some
part of AC-6 is wanted, the only defensible residue is F5 plus fixing the survivor's stale header (§6,
must-fix M1) — the new file should not land.

---

## 6. Stale-claim sweep — must-fix vs leave-alone

`grep -rn "securedEnabled\|jsr250Enabled"` over `v2/wms2-api/src`, both wms2 UI repos and `sbdocs/`, plus
`"three families"`, `"all three annotation"`, `MethodSecurityConfig:9` and `always-red`.

### `v2/wms2-api/src` — CLEAN (CONFIRMED)

Only two hits outside the three changed files, both in `Sbdev3017TrancheGateContextTest` (`:475`, `:493`)
and both correctly re-framed as history (*"used to read"*, *"which was true when written and is no longer"*,
*"back when all three families WERE live"*). The `METHOD_SECURITY_GATES` list of five is retained with an
explicit defence-in-depth rationale. **This part of the sibling sweep is genuinely complete, and the three
corrections are real corrections rather than rewordings** — each one states the old text, marks it
superseded, and gives the new fact. (Nit: `MethodSecurityEnablementContractTest:134` says the arch test
"bans all three annotations"; the rule bans four. Correct **in context** — that message is inside
`jsr250EnabledStaysOff`, and JSR-250 contributes exactly three. No change needed.)

### ⚠ The sweep missed two LIVE copies of the very claim AC-6 corrects

Both on `origin/develop` and both still present at `ca04ce2`:

- `v2/wms2-web-ui/test/util/reprentLabelHostSet.spec.js:43` — *"`develop` already carries 2 always-red
  suites with 0 failing tests, so a third would be invisible."*
- `v2/wms2-web-ui/test/util/appMenuList.spec.js:7` — the same sentence, in caps.

The commit corrected the sbdocs copy of this claim while leaving both in-repo copies untouched — the same
literal, in the same repo, one of them in the successor of the very file being landed. **M1/M2 below.**

### Must-fix — a future reader would act on these

| # | File / line | Why it must change | Minimal edit |
|---|---|---|---|
| **M1** | `wms2-web-ui/test/util/reprentLabelHostSet.spec.js:41-46` | This is the **live** host-set pin on `origin/develop`. Its stated justification for the `fs` walk is a measurement that is false: I measured `origin/develop` at 75 suites / 1115 tests / **0 failing tests**, with 2 suites failing to *load* from a missing `zpl-renderer-js`. A future reader trusting it will believe develop is red and may "fix" the walk. Highest-priority of all sweep items, and it is inside AC-6's own subject matter. | Replace the sentence *"`develop` already carries 2 always-red suites with 0 failing tests, so a third would be invisible."* with: *"A suite that fails to LOAD reports under 'Test Suites' while 'Tests' stays green, so it is easy to skim past — the asymmetry justifies the walk whether or not any suite is currently red. (Re-measured 2026-09-01 on `origin/develop`: 75 suites, 1115 tests, 1115 passed, 0 failing tests; 2 suites fail to load because `zpl-renderer-js@^4.0.0` is declared in `package.json` but absent from the local `node_modules` — environmental, cleared by `yarn install`.)"* One hunk. |
| **M2** | `wms2-web-ui/test/util/appMenuList.spec.js:7` | Same false literal, same repo, and this is the spec the other two both cite as precedent, so the claim propagates. | Same replacement sentence, trimmed to the first clause plus the dated parenthetical. |
| **M3** | `sbdocs/1-Projects/wms2/plan/SBDEV-3155-evidence/harness.md:478-497` | §C.4 is *"Every mechanism by which a gate can arrive, **with enablement status**"* — a lookup table written as forward guidance (§C.3 literally says *"this is the class whose shape to copy"*), and its "Two caveats … **that a plan should carry**" is an instruction to future planners. Rows 6/7/8 say **YES** for `@Secured` / `@RolesAllowed` / `@DenyAll`+`@PermitAll`; all three are now **NO**, and the caveat about the flags being unpinned is now the opposite of true. A planner enumerating denial mechanisms off this table would over-count by three and re-file this ticket. | Insert one line under the §C.4 heading — *"⚠ Superseded 2026-09-01 by SBDEV-3156 (`3594108a`): rows 6-8 are now **NO** (`securedEnabled=false`, `jsr250Enabled=false`), all three attributes are pinned by `MethodSecurityEnablementContractTest`, and the four annotations are banned from `src/main` by `MethodSecurityAnnotationSurfaceArchTest`. The two caveats below are closed. Rows 1-5 and 9-10 stand."* Do not rewrite the table; the basis-commit header makes the rows legitimate as-of evidence. |
| **M4** | `sbdocs/1-Projects/wms2/plan/SBDEV-3169-evidence/3169-lane-functions.md:186` (finding 6) | SBDEV-3169 is **active** (Slices 0+1 merged, later slices open), so this evidence doc is live input to unfinished work. The finding's actionable half — *"those are live mechanisms an SDR rule source could be defeated by if someone adds one later"* — is now false in both halves: they are inert **and** an ArchUnit rule blocks adding one. A 3169 implementer could waste a slice defending against them. | Append one clause: *"— **closed 2026-09-01 by SBDEV-3156 (`3594108a`)**: both flags are now `false` and pinned, and `MethodSecurityAnnotationSurfaceArchTest` bans all four annotations from `src/main`, so an SDR rule source can no longer be defeated this way."* |

### Leave alone — legitimate point-in-time records

| File / line | Why |
|---|---|
| `sbdocs/…/SBDEV-3169-evidence/3169-lane-functions.md:17` (mechanisms table cell) | Same doc as M4, but this cell is descriptive of the derivation commit, and the doc's header pins it: *"Derived from `origin/develop @ 79320399` … on 2026-08-29. Nothing was checked out."* A reader is told the basis. Fold it into the M4 edit if the file is open; not independently must-fix. |
| `sbdocs/…/SBDEV-3017-B1-mvc-write-surface-gating.md:3917-3924` (§9.27.1) | Sits under a dated heading — *"THIRD REVIEW ROUND 2026-08-28 … Head `81989036`"* — and is the narrative of the measurement that **created** this ticket. The sentence at `:3924` (*"Both families are live today with nothing asserting they stay that way"*) is SBDEV-3156's origin statement; editing it erases the provenance. **Leave.** Optional courtesy: one line *"Closed by SBDEV-3156 (`3594108a`) 2026-09-01."* |
| `sbdocs/…/SBDEV-3017-B1…md:4007` and `:4082` | Spun-out-ticket tables. They describe what SBDEV-3156 **was filed about**, which is still an accurate description of the ticket. **Leave.** |
| The eight other `always-red` hits in `sbdocs/` (2967-A/B/C, 2961, 3017-B1:1645/:3220, 2967-presplit, verify-SBDEV-2967-B script) | All are baseline captures inside dated plan/verify artefacts, recording what was observed at the time. They are not consulted for the current state of develop. **Leave.** The one exception in spirit is `sbdocs/9-System/scripts/verify-SBDEV-2967-B-web-view-gating.sh:453`, which *prints* the stale baseline to an operator — but per the tier rules that script belongs to an archived ticket and is due for retirement, and it is out of this ticket's scope. Noted, not filed. |
| `sbdocs/9-System/orphaned-tests/README.md` | Superseded wholesale by F1 — its row asserts *"committed on no branch"* and *"its only UI-side guard did not [ship]"*, both **false** (`b218de7`, and the guard is `test/util/reprentLabelHostSet.spec.js` on develop). Not a "stale claim to word better": the file should go with the orphan. See §5. |

**Sweep completeness statement.** I found **no** copy of "securedEnabled/jsr250Enabled are ON / are
unpinned / all three families are enabled" outside the seven sbdocs locations above and the correctly
re-framed `Sbdev3017TrancheGateContextTest` history. `wms2-mobile-ui` has no hits. The lead's list of
three files was accurate; I add **M1 and M2 (in-repo, wms2-web-ui)** as the two the sweep missed, and
those are the two a reader is most likely to act on.

---

## 7. Tier judgement

**T2 was defensible. I would have made the same call, and none of the three escalation triggers fired
on the wms2-api half.** Reasoning, against the router's actual axis (execution risk):

- *"Authorization" as a T3 trigger.* The lead's reading is right: the trigger is for changes that alter
  **who can do what**. Two instruments, both of which I reproduced, put the affected surface at **zero
  routes** — no annotation loses effect because no annotation exists. The runtime behaviour of the
  deployed application is **provably unchanged**: the only delta is that four Spring Security processor
  beans are no longer created. That is a build-configuration change wearing an authorization costume.
- *Trigger 1 — a measurement contradicts the ticket.* Did not fire. It **confirmed** the ticket, and the
  triage comment pre-committed to escalating if the classpath scan came back non-zero. It came back zero
  and I re-verified that (fact-check rows 6-7): the enumeration is sloppy, but not one class **carries**
  the annotation, so the zero that decides the tier holds.
- *Trigger 2 — an unanticipated persistence surface.* Did not fire. No repository, projection, migration
  or DB object touched. The floor's DB item has no axis here, and substituting the two-instrument
  inventory plus the AC-4 mutation check was the right substitution, stated openly rather than skipped.
- *Trigger 3 — a review finding disputes the design.* **Fired, but only on the AC-6 half, and it does
  not raise the wms2-api tier.** F1 is not a design dispute about the flags; it is a scope item that was
  mis-premised. Its own tier is what the lead assessed — T0/T1, one test file, one repo — and the correct
  T0/T1 response is to drop it, not to escalate the parent. If anything F1 argues the opposite: bolting an
  unrelated single-file scope item onto a T2 ticket is what let a 15-minute path-only provenance check
  stand in for a proper one. **The process finding is "don't attach cross-repo scope to a tier chosen for
  a different change", not "this was T3".**

One dissent worth recording: the **completeness** discipline was applied unevenly. Everything measured
inside this repo was measured twice with a positive control and came back exact; the two claims that
broke (jar enumeration, AC-6 provenance) are both about things **outside** `src/main` — where the
instrument was single and had no control. That is a T2-appropriate lesson, not a T3 verdict: *a scan
whose expected answer is "only these" needs the same positive control as a scan whose expected answer is
zero.* The triage comment already discovered that rule for the ugrep binary-file trap; it just was not
carried across to the jar scan or the ref sweep.

---

## 8. What I did NOT check

- **The full wms2-api suite.** I ran only the two target classes (20 tests, green) plus three mutants.
  No full-suite figure from me, so **F3 stands open** — I cannot say whether the new whole-tree ArchUnit
  import perturbs anything else, and neither can the commit.
- **Runtime behaviour.** No context boot, no live 401/403 probe, no dev-environment call. The claim
  "zero routes affected" is verified statically (no carrier exists) and I did **not** confirm it against
  a running application.
- **Whether the four surviving `@PreAuthorize` carriers' expressions are correct**, or anything about
  `SecurityConfiguration.authorizeHttpRequests` — the sixth axis both files correctly disclaim. Lane 2's
  ground.
- **`wms2-mobile-ui`** beyond a negative grep for the enablement flags and the always-red literal.
- **PIT / a real mutation harness.** My three mutants were hand-planted source edits, per repo
  guidance for a pin of this shape; I did not run PIT.
- **The remaining three of the six claimed mutants** (M2 `@Secured` class-level, M5 `jsr250Enabled=true`,
  M6 `prePostEnabled=false`). M4 and M1 are the structurally identical siblings of M5 and M2 and both
  killed attributably, and M6 is the pre-existing pin; I judged three re-runs sufficient and say so
  rather than implying six.
- **Lane 1's and lane 2's subject matter** — code correctness and authorization semantics. Nothing here
  should be read as clearing either.
