# SBDEV-3873 — ralplan round 3 (scoped), Critic review

- **Subject:** `plan-snapshot-r3.md` (fixed snapshot, not edited; byte-identical to the live plan
  `SBDEV-3873-sdr-patch-advice-cyclecount-binds-every-field.md` at review time). Scope: §5 Fix C, §8, §8.1, §5.1, plus the
  touched §5 A1/A2, and the §12 disposition claims.
- **Verified against:** wms2-api `origin/develop` `4960631d` (fetched 2026-10-22; unchanged since round 2). No Maven, no DB,
  nothing written outside this file. Independent of the architect lane.
- **Mode:** THOROUGH. No High, no systemic pattern; no escalation.

## VERDICT: ITERATE

**High 0 · Medium 1 · Low 6**

All four round-2 Mediums are genuinely resolved (audit below). Every AC now has an attributable mutant, and every new
PR 1 / PR-W test is red pre-fix. What holds this at ITERATE is one new vacuous instrument, in a blocking gate: the G1
"revert-on-release" check passes on every tag ever cut (M1). That is a one-token fix. Round 4 can be a text-only check of
M1 plus the Lows; no design re-review is needed.

---

## plan-state.sh (run 2026-10-22)

```
5. Prerequisites still open (parsed from the plan's §5.1 table)
  P1  **Gate G1, before merging PR-W:** PR 1 is served on PRD
  P2  **Gate G2, before merging PR 2 (D4):** PR-W is served on PRD
```
P1 and P2 parse under section 5. Round-2 M4 is resolved.

## Verified (pass)

| Claim | Evidence | Result |
|---|---|---|
| Re-scoped T4 is a real re-scope of an existing test | `SdrMustStayWritableStateNotPatchableContextTest` iterates `MUST_STAY_WRITABLE` with a `typesWithState >= 2` floor. After PR 2 that list holds no type with `state`, so the floor would go red and the subject set empty; the plan's runtime-metadata re-scope plus mandatory synthetic positive control, and its explicit ban on a ">0 scanned" guard, close round-2 M1 | ✓ |
| m13 is killable | After PR 2 `configureAdviceItemVerbWriteExposure` is deleted, so removing `Advice` from `SDR_WRITE_WITHDRAWN` re-exposes PATCH with SDR defaults; stripping `@ReadOnlyProperty` from `Advice.state` (`Advice.java:31-32`) makes it writable; T4 reports it | ✓ |
| m14 is killable | The positive control applies the extracted "exposes PATCH" predicate to a stub that must be reported | ✓ |
| Every AC maps to a mutant | AC-1 m1/m1b · AC-2 m2/m4 · AC-2b m4b · AC-3 m1/m1b · AC-4 m3 · AC-5 m8 · AC-6 m9 · AC-7 m7 · AC-8 m5/m5b/m6/m6b · AC-9 m5/m5b · AC-10 m10 · AC-W1 w1 · AC-W2 w2 · AC-W3 w1 · AC-B1/B2 m11/m12 · AC-B3 m15 · AC-B4 m13/m14 · AC-B5 m16 | ✓ (round-2 M2 resolved) |
| m10 turns AC-10 red | Without the id check, `findById(null)` throws `IllegalArgumentException` (translated to `InvalidDataAccessApiUsageException`); `RestExceptionHandler` has no handler for either (handlers at `:60,:74,:89,:111,:119,:127,:135,:151,:161,:179,:188,:200,:301,:384,:393`), so it is not a 422 | ✓ |
| m3 turns AC-4 red | `advice.comment` is `character varying(255)` (`V2.2.00__base_v2_schema.sql`, `CREATE TABLE public.advice`); H2 `create-drop` also maps it to 255. A 256-char value fails at flush with an unmapped `DataIntegrityViolationException`, not a 422 | ✓ |
| m4 / m4b are now anchored | AC-2 asserts `version == seeded + 1`; AC-2b asserts an unchanged re-POST leaves `version` alone | ✓ (round-2 M3 resolved) |
| m6b discriminates | `getOwner()` is the `Advice` entity for inherited `id/created/modified/version` (`AbstractBaseEntity.java:26-35`), so the reflection cross-check (`getDeclaredFields()`: 18 on Advice, 7 on Cyclecount) fails | ✓ |
| AC-8 cross-check is not permanently red | Neither entity has a `transient`/`@Transient` field or an accessor-only property, so the mapping-context set equals the reflection set | ✓ |
| AC-8/AC-9 red pre-fix for the right reason | Only `state` is fenced today on both classes | ✓ |
| Pins | Tranche `hasSize(231)` at `Sbdev3017TrancheGateContextTest:1112`; `WITHDRAWN` 51 at `SdrWriteWithdrawalContextTest:228`; `MUST_STAY_WRITABLE` 8 at `:336` | ✓ |
| Fix C symbols exist | `RestConfiguration` `SDR_WRITE_WITHDRAWN` `:452`, `configureAdviceCollectionCreateWriteExposure` `:640`, `configureAdviceItemVerbWriteExposure` `:682`, `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN` `:798` | ✓ |
| A2 precedent | `AdviceController` `@RequestMapping("/v3/advice")` `:34`, `setPurchaseOrderNumber` `:143` | ✓ |
| PR-W tests red pre-fix | AC-W1 (`$patch` today), AC-W2 (watcher dispatches), AC-W3 (two patch sites) | ✓ |

---

## Medium

### M1 — G1's "revert-on-release" grep is vacuous: `setComment` already exists in `src/main` on every tag
**Location:** §5.1 P1: `` `git grep setComment v<version> -- src/main` (memory *is-ancestor ≠ fix shipped*) ``.

**Evidence:**
- `git grep -c setComment origin/develop -- src/main` hits **18 files** today: `model/Advice.java` (the entity setter),
  `model/Cyclecount.java`, `service/AdviceService.java`, `controller/rest/AdviceRestController.java`, `json/AdviceDto.java`,
  `MobileCycleCountService.java` (4), and others.
- At the latest tag `v0.0.42`, which predates PR 1, the same grep also hits. The instrument is true for every release
  ever cut, with or without PR 1.
- Round 2 asked for this to be narrowed: critic L3 gave `` git grep -q 'setComment' v<ver> --
  src/main/java/net/aim_ai/wms/controller/AdviceController.java ``, and architect `review-r2-architect.md:170-171` gave the
  same. The plan widened it to `src/main`, and §12 records G1/G2 detail (L) as taken.

**Why this matters:** `merge-base --is-ancestor` proves ancestry. It does not prove the code survived the release, which
is the whole reason the memory and this second instrument exist. As written, a revert-on-release of PR 1 passes G1. PR-W
then merges, and every open of a closed notice with a comment (the echo, S1) gets a 405 toast on PRD. That is the
round-1 H1 outage, reached through a gate that reports green.

**Fix:** grep for the route, not the setter name, in the one file that serves it, e.g.
`` git grep -qE 'path *= *"/setComment"' "v<version>" -- src/main/java/net/aim_ai/wms/controller/AdviceController.java ``.
Then record the positive control: it matches at the PR 1 merge commit and fails at `v0.0.42`.

**Realist check:** kept at Medium. **Partly mitigated by** `is-ancestor` covering the common mis-order, and by the
failure being loud (toasts) with no data loss. It is not Low, because this is a blocking gate whose second instrument
proves nothing, and the plan marks the round-2 fix for it as taken.

---

## Low

- **L1 — The IT harness is named inconsistently, and v2 checklist (6) is false.**
  - AC-2 says `"A Testcontainers IT (extending BaseRollbackIntegrationTest …)"`. But `BaseRollbackIntegrationTest` is
    **H2** (`ddl-auto=create-drop`, `flyway.enabled=false`, `jdbc:h2:mem:`). It is not transactional (it commits), and it
    has no MockMvc. The Testcontainers base is `BasePostgresIntegrationTest`. Checklist (6) `"H2: the ITs use
    Testcontainers"` is therefore untrue. Part of this came from my round-2 L1 wording.
  - The only existing real-filter-chain lane, `BaseControllerIntegrationTest` (`@AutoConfigureMockMvc`), extends
    `BaseIntegrationTest`, which is `@Transactional("tenantTransactionManager")`. If the executor picks that lane, AC-2's
    `version == seeded + 1` stays false until the test calls `flush()` and then `clear()`, because the service joins the
    test transaction.
  - Nothing in this feature is PG-specific: `varchar(255)` and `@Version` behave the same on H2. So the risk is a stall,
    not a false green.
  - Fix: name one base. The simplest is `BaseRollbackIntegrationTest` plus `@AutoConfigureMockMvc` (it commits, so assert
    by id). Alternatively, say "flush and clear before reload" if a transactional base is used. Correct checklist (6).
- **L2 — §12 says `"All are taken"`. Four round-2 Lows are not.**
  - **r2 L5:** AC-5 still does not say whether `""` is stored as `""` or NULL.
  - **r2 L6:** §8.1 still says `"Each kill must name the mutant in its failure message"`, which a test cannot do.
  - **r2 L7:** M1b still PATCHes 87150 without the `snapshot.sh` wrap. M2 still exercises one of the two
    `closedNoticeDescription` mounts. The actor log decision *is* recorded in §11.
  - **r2 L9:** M1's `"FINISHED 12,530, of which 6,443"`: 6,443 is the all-states figure in `db-verification.md` §2.
  - Fix: apply them, or list them in §12 as declined.
- **L3 — A stale mutant reference in §9.** Risk row `"Re-scoped T4 goes vacuous | AC-B4 and m11"` is wrong: m11 is now
  "remove `Advice.class` from `SDR_WRITE_WITHDRAWN`". The T4 mutants are m13 and m14.
- **L4 — Step 1 scopes the TDD gate as `"AC-1 to AC-9"`.**
  - AC-10 sits outside that range textually, although it is listed between AC-7 and AC-8.
  - A literal gate run skips the missing-id test, and m10 is then never red-first.
  - Fix: "AC-1 to AC-10 and AC-2b", and renumber §8 into order.
- **L5 — AC-3 pins neither the guard mode nor how functions are resolved.**
  - The established lane mocks `AccessService` with `any()` matchers (`SdrReadGateEnforcementContextTest`). With such a
    stub, the CYCLECOUNT-only case cannot tell the gate functions apart, so m1b is killed only by AC-1's pin, not by
    AC-3 as §8.1 claims.
  - Fix:
    - Stub per required function, or seed real user, role and function rows.
    - Set the mode to OFF, so that only `@RequiresFunction` can produce the 403.
    - Assert the body's `requiredFunction == "WEB_UI_VIEW_INBOUND_BOL"`.
- **L6 — AC-8's derivation lost the architect's null guard.** The plan has `p.getField().getDeclaringClass()`. Round-2
  architect L5 specified `p.getField() != null && …`.
  - This is harmless today: there are no accessor-only properties (verified above).
  - A future one would make AC-8 throw an NPE instead of failing with a message.
  - Fix: keep the guard, and count field-less properties as an offender.

---

## Round-2 disposition audit

| Round-2 finding | §12 claim | Actually |
|---|---|---|
| M1 T4 vacuity | positive control mandatory, m13/m14 | **Resolved** |
| M2 unmapped ACs | m8, m9, m10, m15, m16, AC-10 | **Resolved**. All ACs are mapped. Step 1 omits AC-10 (L4) |
| M3 m4 unanchored, idempotency unpinned | AC-2 `version + 1`, AC-2b | **Resolved**. Harness flush caveat in L1 |
| M4 gates invisible to `plan-state.sh` | P1/P2 shape | **Resolved** (probe output above) |
| L1 AC-9 user and mode | pinned | Resolved (the user is pinned; the mode is "explicit" but not named, which is acceptable) |
| L2 AC-2 fixture | RETURN seeded | Resolved |
| L3 G1/G2 exactness | taken | **Not resolved**: the grep was widened into vacuity (M1) |
| L4 AC-7 placement | real-service unit test | Resolved |
| L5 `""` stored value | — | Not addressed (L2) |
| L6 mutant naming | — | Not addressed (L2) |
| L7 manual gaps | §11 declines the log | Partly. M1b and the second mount are open (L2) |
| L8 JSON-Patch | AC-9 | Resolved |
| L9 counts | — | Not addressed (L2) |

## What's missing
- A G1 presence instrument that is false on a pre-PR-1 tag (M1).
- One named IT base with its transaction semantics (L1).
- AC-3's function-resolution and mode setup (L5).

## Ambiguity risks
- `"Testcontainers IT (extending BaseRollbackIntegrationTest)"` → A: H2 rollback base / B: `BasePostgresIntegrationTest`.
  Under a transactional base without flush and clear, AC-2 is red after the fix (L1).
- `"with the guard mode set explicitly"` (AC-9, AC-B2) → any mode. This is acceptable because the user holds both
  functions, but AC-3 has no mode at all (L5).

## Multi-perspective notes
- **Executor:**
  - Everything is buildable once L1 picks a base.
  - The T4 re-scope is now unambiguous and safe.
- **Stakeholder:** the design is unchanged and sound. The stop-gap closes the dangerous fields at the first api deploy.
- **Skeptic:** the remaining attack is the same as round 2's, proof decay. This time it sits in the gate rather than the
  tests (M1).

## Verdict justification
ITERATE.

- The four round-2 Mediums are fixed and verified in source.
- The brief asked that nothing new be vacuous. G1's second instrument is vacuous, and §12 says the round-2 fix for it was
  taken.
- The fix is one line. Round 4 should check only M1 and L1–L6 as text, with no design or test-architecture re-review.

Realist check: M1 is kept at Medium, as reasoned above. No downgrades were needed elsewhere.

## Open questions (unscored)
- PRD guard mode is still sourced from the SBDEV-3183 record (§10). It was not re-queried here either (the DB MCPs are
  down).
- G2 names the hosts (wsl-wineco, nywh-hydra) but not their URLs. The architect has already fetched them, so recording
  the URLs in P2 would help a later session.
- Pre-fix, a POST to `/v3/advice/setComment` routes to the SDR item resource with id `setComment`. AC-3's 403 sub-cases
  could therefore be red or green pre-fix depending on mode. They are not mutant-critical, because m1 still kills them
  post-fix.

---
*Ralplan summary row:*
- **Principle/Option Consistency: Pass.** Unchanged since round 2.
- **Alternatives Depth: Pass.**
- **Risk/Verification Rigor: Fail (narrowly).** The tests are now sound. The G1 gate instrument is vacuous (M1).
- **Deliberate Additions: Pass.** The pre-mortem, the expanded test plan (unit, context, IT, Jest, manual) and the hand
  mutants are complete.
