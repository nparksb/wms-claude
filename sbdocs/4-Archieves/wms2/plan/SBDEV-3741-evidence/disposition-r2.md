| Finding | Disposition | Where |
|---|---|---|
| Arch M1 (bare 403, no header/reason/metric) | Fixed: `FunctionAccessDeniedException` + static `AuthzDenialWriter` extracted from `deny()` + `MobileEndpointExceptionHandler` handler (WARN + metric). Static, so the ≥10 interceptor test constructors are unchanged; no-arg advice constructor kept for its 7 test sites. AC-8d, mutants M-m/M-n | §3.2.1, A30–A32, §7.1 |
| Arch M2 (`@Transactional` "or") | Fixed: identical annotation on both overloads; controller calls the 4-arg form; reflection pin using annotation `equals`; mutant M-p | §3.2, AC-21, §7.5 row 2 |
| Arch M3 (stale Vuex destination) | Fixed: component-local `data()`, passed as an argument through `completeSelectedPositions` → `completeReversal`; `customerorderId` watch; Jest AC-20 | §3.5, §7.2 |
| Arch M4 (hibernate-validate claim; deploy coupling) | Fixed: §6 schema row rewritten (unmigrated tenant breaks cancellation); §8 step 2 per-tenant `flyway_schema_history` gate; ALTER first in V2.2.38; A22 marked coupled | §3.3, §6, §8 |
| Arch M5 (`LocationTypeRepository` missing) | Fixed: dependency of `RtsDestinationValidator`; null-safe `FLOWBIN.equals(sltname)`; missing type refused | §3.2 step 6 |
| Arch L1 (`isStaginglane`) | Fixed: `!Boolean.TRUE.equals(loc.getStaginglane())`; null refused; `RDVUT.nullStaginglane_refused` | §3.2 step 4, AC-6 |
| Arch L2 (existing tests edited) | Fixed: constructor-only edits listed (CRSUT:128, ParcelSourceRefusalUnitTest:609; +1 argument) | A34 |
| Arch L3 (no mapper class) | Fixed: `toDetailDto` ~:873 named | A21, §3.4 |
| Arch L4 (F3 wording) | Fixed: "applies after destination validation passes" | §3.2 F3 |
| Arch L5 (M7 table names) | Fixed: `mywms_function` / `mywms_role_mywms_function` / `mywms_role` | §7.3 M7 |
| Arch L6 (handhelds keep functions) | Fixed: "reload the handhelds" added; the typed 403 is what they see in the window | §8 rollback |
| Critic H1 (422 makes rows waivable, loop continues) | Fixed: `RequestRefusedException` → 422 with root ProblemDetail `type`; mobile `isRequestRefusal` breaks the loop, records no waivable or refusals, shows the message under the scan field; plain 422 unchanged. Jest AC-19/19b/19c, JUnit AC-8e, mutants M-o plus 3 Jest mutants | §3.2.2, §3.5, §7 |
| Critic H1 sub (lane locked mid-loop) | Fixed and pinned as request-level: the validator re-runs per request, so request k gets the typed refusal (AC-7c, AC-19c, M4). Residual in-request race accepted and documented; translating the downstream message rejected (§9) | §3.2.2 |
| Critic M1 (whole-container arm for Case) | Fixed: B4/F7 corrected; AC-2c IT; M1c manual; §7.4 row 8 states lock order unchanged from today's route; analysis §B4.3 marked superseded | §2, §3.2 F7, §7 |
| Critic OQ1 (does the picked Case UL trip SourceLockGuard?) | Resolved: **No** on WineCo PRD (DB-6, 2026-10-12): both PutAwayLane Cases have SU/UL/location lock 0, 1 SU, amount = picked, no FLA. Code: the guard refuses only non-zero locks and the SU is cleared and flushed first. Scope corrected to 13 rows: the third Case (pos 35841889) is refused because amount_picked 2 > available 1, whatever the destination | §1, §2 B4, §10 Open |
| Critic M2 (H2 vs PG) | Fixed: CRDIT `extends BaseRollbackIntegrationTest` (H2), like its siblings; asserts by id; the migration IT stays standalone PG Testcontainers like `CancellationWaiveMigrationIT`; §7.1 and §7.5 made consistent | §7.1, §7.5 row 7 |
| Critic M3 (missing mutants, vacuous `never()`, AC-6) | Fixed: fixture rule (finder stubbed with a movable row); exact message or `getKey()`; mutants M-i…M-l; AC-6 reworded (no save, no stamp, no transfer; IT row still pending) | §7.1 |
| Critic M4 (M-g/M-h attribution) | Fixed: M-g → AC-2 only (plus a CRSUT captor); M-h redefined as "write source name when dest is null", killed by an AC-1 `never()` assertion | §7.1 |
| Critic M5 (403 mismatch; no denial log) | Fixed with Arch M1; body and toast stated in M3; WARN line plus metric | §3.2.1, §5.1 row 8, M3 |
| Critic M6 (unmigrated tenant breaks cancellation) | Fixed with Arch M4 | §6, §8 step 2 |
| Critic L1 | Fixed (= Arch L1) | §3.2 |
| Critic L2 (17 args) | Fixed via the collaborator: 14 args, not 17; rationale and the SourceLockGuard-javadoc objection addressed | §3.2 |
| Critic L3 (SQL role names) | Fixed: SQL uses `'outbound-manager','super-admin'`; `role_*` named as Java identifiers | §3.3 |
| Critic L4 (dispatch path) | Fixed: full path spelled out; no new mutation | §3.5 |
| Critic L5 (completeness words) | Fixed: "Every invariant… observable" replaced by a method plus named manual exceptions; F9's "nothing writes Location" given a method and a blind spot | §7.1 verify-script para, §3.2 F9 |
| Critic L6 (AC-8b exact stub, varargs) | Fixed: `checkAnyAccess(eq("alice"), eq(FN))`, one matcher per varargs element, STRICT_STUBS | AC-8b |
| Critic L7 (functions persisted; refreshMenus) | Partly rejected: `home.functions` is **not** persisted (`stripAuthzState` in `persistedState.client.js`, re-asserted empty on boot), and `refreshMenus` resets workflow modules without re-fetching functions. Correct remedy is an app reload (merged with Arch L6) | §8 rollback |
| Critic L8 (G2 rationale thin) | Fixed: reworded to "binds any caller supplying an operator-chosen destination"; the 3733 system path bypasses it by design | §9 |
| Critic OQ2 (DTO null serialisation) | Resolved: `WebConfigurer` sets `Include.NON_NULL` globally, so the key is omitted when null and default detail JSON is unchanged; pinned by `…_nullOmitted` | §3.4, AC-15 |
| Task item: status / updated / review history | Done: `pending approval`, `2026-10-12`, review-history line | frontmatter, §10 |
| Task item: D1–D5 unchanged | Done: verbatim in substance | §10 |
