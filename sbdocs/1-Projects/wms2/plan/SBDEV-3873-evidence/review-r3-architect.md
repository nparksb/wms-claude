# SBDEV-3873 — ralplan round 3 (scoped) — Architect review

- **Subject:** `plan-snapshot-r3.md` (frozen, not edited). Scope: §5 Fix A1/A2/C, §5.1 (P1/P2), §8 ACs, §8.1 mutants, and
  whether the round-2 edits introduced new defects.
- **Code base:** wms2-api `origin/develop` = `4960631d` (fetched 2026-10-22, unchanged since round 2), tag `v0.0.42` (PRD);
  wms2-web-ui `origin/develop` = `98accaf`. spring-data-rest-webmvc 4.5.7 sources from `~/.m2`.
- No Maven, no DB access, nothing written except this file.

## VERDICT: APPROVE — with M1 and L1 folded in before the gate text is copied into the PR 1 body

Counts: **High 0 · Medium 1 · Low 6**.

Every round-2 Medium (mine and the critic's) is genuinely resolved. The one new Medium was introduced by the round-3 edit to
G1: its "fix shipped" grep is now satisfied by today's PRD tag. It is a one-line text fix, and it gates PR-W, not PR 1, so
PR 1 can go to the TDD gate now. No round 4 is needed.

---

## 1. Round-2 dispositions: verified against the text

| Round-2 finding | Resolved? | Evidence in r3 |
|---|---|---|
| Arch M1 / Critic M1: T4 "scanned > 0" escape hatch, m11 incoherent | **Yes** | §5 Fix C: the positive control is mandatory and the scan-count guard is explicitly rejected (":183"). m13 (un-withdraw Advice **and** strip `state`) is the real regression: after PR 2 deletes `configureAdviceItemVerbWriteExposure`, un-withdrawing Advice exposes PATCH, so T4 sees a writable `state` → red. m14 (predicate always false) is killed by the stub positive case. Residual: L4 |
| Critic M2: AC-5, AC-6, AC-B3, AC-B5, missing id have no mutant | **Yes** | m8→AC-5, m9→AC-6, m10→AC-10 (new), m15→AC-B3, m16→AC-B5. m10 is attributable: with no id, `findById(null)` throws `IllegalArgumentException`, translated to `InvalidDataAccessApiUsageException`, which `RestExceptionHandler` does not map (`:60-393` handlers list), so the response is not 422 |
| Critic M3 / Arch L3: m4 unanchored; no-op re-save unpinned | **Yes, given the harness (L2)** | AC-2 now asserts `version == seeded + 1`; AC-2b pins the no-op; m4→AC-2, m4b→AC-2b |
| Critic M4: gates invisible to `plan-state.sh` | **Yes** | I ran `plan-state.sh`'s own parse (`9-System/scripts/plan-state.sh:270-278`) over the snapshot: **P1 OPEN, P2 OPEN**, P3–P7 closed (no `YES`). Section numbering: §3 present; `### 5.1` kept under §7 by design (the parser keys on the row shape, not the heading) |
| Arch L1: G1 tag mapping, `build.time` | **Yes, but regressed** | Tag mapping and `build.time` present. The grep was widened from `AdviceController.java` to `src/main` and is now vacuous (**M1**) |
| Arch L2 / Critic L3: G2 pattern, hosts, positive control, stale tabs | **Yes, with a transcription trap** | Present/absent strings, hosts, `c6e59b2.js` control, stale-tab acceptance all in P2. The regex as stored in the raw `.md` matches nothing (**L1**) |
| Arch L4: missing `comment` key clears | **Yes** | §5 A2 "One behaviour change"; AC-5 includes `{id}` |
| Arch L5: AC-8 declaring class + reflection cross-check | **Yes** | §5 A1 and AC-8; m6b. Verified: Advice declares **18** non-static fields (`Advice.java:12-42`; my round-2 "19" was a miscount, the critic's 18 is right), Cyclecount 7, no `@Transient`, so the cross-check is exact. Under m6b the scan picks up `id/created/modified/version` (22 ≠ 18) → red |
| Arch L6: m1b, m5b, m12, JSON-Patch | **Yes** | All four present. JSON-Patch status unstated (**L3**) |
| Arch L7: §3, `id` in residual | **Yes** | §3 added; `id` in the A1 residual list (Risk row 7 still omits it; cosmetic) |
| Critic L1: AC-9 user and mode | **Yes** | AC-9 holder of INBOUND_BOL **and** CYCLECOUNT, mode explicit |
| Critic L2: AC-2 fixture | **Yes** | RETURN advice seeded. Body keys (`externalid`, `clientId`, `type`, `allowoverdelivery`, `state`) match the entity property names, so m2 is detectable |
| Critic L4: AC-7 placement | **Yes** | Real-service unit test; `OutboxService.enqueue` exists (`OutboxService.java:42`), so m7 is concrete |
| Critic L8: JSON-Patch case | **Yes** | AC-9 third bullet |
| Critic L5, L6, L7 (M1b snapshot, M2 second mount), L9 | **No** — §12 says "All are taken" but these four are neither applied nor dispositioned | **L5** |
| Arch N1 / Critic L7 actor log | **Yes** | §11 "Declined" with a reason |

Checks of r3 claims that underpin the mutants:
- **m1 is attributable.** `AdviceController` is not in `FunctionGuardInterceptor.GUARDED` (`FunctionGuardInterceptor.java:118-167`)
  and has no class-level `@RequiresFunction` (`AdviceController.java:32-35`). Removing the method annotation therefore opens the
  handler (403 cases → 200), rather than failing closed, which would have left the 403 cases green.
- **`FAIL_ON_UNKNOWN_PROPERTIES=false`** on the primary mapper: `WebConfigurer.java:78,108,121`. Confirmed.
- **Stop-gap safety** was re-checked in round 2 (§1 there) and nothing in the touched files moved.

## 2. Findings

### Medium

**M1. G1's "fix shipped" grep is satisfied by today's PRD tag, so it proves nothing.** (New in r3.)
- P1 now reads `git grep setComment v<version> -- src/main`. `setComment` is already the entity, DTO and service setter name
  across `src/main`: 20 hits on `origin/develop` (`Advice.java:152`, `Cyclecount.java:89`, `AdviceDto.java:120`,
  `AdviceRestController.java:279`, …).
- Run against the tag PRD serves today: `git grep -c setComment v0.0.42 -- src/main` → hits in `AdviceRestController.java`,
  `TransactionReportRestController.java`, `AdviceDto.java`, … So the check passes **before PR 1 exists**.
- That leaves `merge-base --is-ancestor` as the only working instrument, which is exactly what memory *is-ancestor ≠ fix
  shipped* (revert-on-release) says is insufficient. G1 is the gate that prevents the round-1 High (405 toast on every
  closed-notice open), so it needs both instruments to work.
- Round 2's L1 had this right (it scoped the grep to `AdviceController.java`); the r3 edit broadened it.
- **Fix:** `git grep -q 'path = "/setComment"' "v$V" -- src/main/java/net/aim_ai/wms/controller/AdviceController.java`
  (or grep the class name `AdviceCommentRequest`, which does not exist today). Add the positive control: the same command on
  `v0.0.42` must return non-zero. Verified: `git grep -c '"/setComment"' v0.0.42 -- src/main` → 0 files.

### Low

- **L1. G2's absence regex, as stored in the raw markdown, matches nothing, including its own positive control.**
  - The table cell holds `\$patch\("/(advice\|cyclecount)/"`; the `\|` is a markdown table escape. Agents read the raw `.md`.
  - Tested: `grep -cE '\$patch\("/(advice\|cyclecount)/"'` on `t.$axios.$patch("/advice/".concat(e.id),e)` → **0**, and the
    same for cyclecount. The rendered form `(advice|cyclecount)` → 1.
  - The stated positive control (`c6e59b2.js` must match) would catch it if run, which is why this is Low. Fix: move the
    command into a fenced block below the table, or write it pipe-free as two greps (`'\$patch\("/advice/"'`,
    `'\$patch\("/cyclecount/"'`).
- **L2. AC-2's harness is self-contradictory, and m4/m4b are killable only under one reading.**
  - AC-2 says "A Testcontainers IT (extending `BaseRollbackIntegrationTest`…)", and the checklist v2-constraint (6) says "the
    ITs use Testcontainers". `BaseRollbackIntegrationTest` is **H2** (`BaseRollbackIntegrationTest.java`, `@TestPropertySource`
    `jdbc:h2:mem:…`) and is deliberately **not** `@Transactional`, so the service transaction really commits.
  - That is the property AC-2 (`version == seeded + 1`) and AC-2b need. The Testcontainers base,
    `BasePostgresIntegrationTest`, is class-level `@Transactional("tenantTransactionManager")` (`:47`). Under it nothing
    flushes before the reload, so AC-2 is red post-fix for the wrong reason and m4b survives AC-2b.
  - **Fix:** drop "Testcontainers" from AC-2 and checklist (6); name `BaseRollbackIntegrationTest` (H2, commits); require
    seed and cleanup by id (memory *Repo tests COMMIT*). AC-3 and AC-9 use the same base, as `AdviceStateReadOnlyContextTest`
    and T4 already do (`:59`, `:42`).
- **L3. AC-9's JSON-Patch case: say the expected status.** `JsonPointerMapping.verify` rejects a non-writable final segment with
  `PatchException` (`JsonPointerMapping.java:124-128`), and `PersistentEntityResourceHandlerMethodArgumentResolver.readPatch`
  rewraps it as `HttpMessageNotReadableException` (`:202-216`), i.e. a **4xx (400)**, not the 2xx-no-op of the merge-PATCH
  bullets above it. The AC as written ("leaves the field unchanged") is correct and red pre-fix. Add "returns 4xx" so the
  executor does not copy the preceding bullets' 2xx.
- **L4. T4: one stale reference and one dropped instrument.**
  - Risk row 5 still cites "AC-B4 and **m11**". m11 is now "un-withdraw Advice", which leaves T4 green (`state` stays
    annotated). It should cite m13 and m14.
  - My round-2 M1 fix had a fourth bullet, a permanent floor "exported types with a `state` property ≥ 2", computed
    independently of PATCH exposure. r3 did not carry it, and §12 does not mention it. The stub control proves the
    predicates; m13 proves the real enumeration **once**. Nothing permanent guards a later change to the enumeration
    source (for example, iterating the wrong mapping set yields an empty scan and T4 stays green). Add the floor; Advice
    and Cyclecount stay exported after PR 2, so it holds.
- **L5. §12 says "All are taken", but four critic round-2 Lows are neither applied nor dispositioned.**
  - Critic L5: AC-5 still does not say whether `""` stores `""` or NULL. The executor's assertion differs (`isEmpty()` vs
    `isNull()`), so the TDD gate can go red for the wrong reason.
  - Critic L6: §8.1 still says "Each kill must name the mutant in its failure message". A test cannot know which mutant is
    applied. Use: the `.as(...)` names the broken invariant, and the PR body records mutant → test → message.
  - Critic L7: M1b PATCHes 87150 with no `snapshot.sh` wrap. M2 tests one of the two `closedNoticeDescription` mounts
    (`closedNoticeDetails.vue` dialog and `pages/receiving/closedNotice/_id.vue`).
  - Critic L9: M1's "FINISHED 12,530, of which 6,443" and Risk row 1's "about 6,443" are the all-states figure from
    `db-verification.md` §2 (12,626 / 6,443). The FINISHED split is not in the evidence file.
  - Apply them, or list them in §12 as declined.
- **L6. Step text vs the ACs.**
  - Step 1 says "write the failing tests (AC-1 to AC-9)". AC-10 (and, by range, AC-2b) is outside that range. Say "AC-1 to
    AC-10, including AC-2b".
  - Step 3 says "flip the pins first (red)". AC-B3, AC-B4 and AC-B5 are regression pins that are green before PR 2 (T4's
    real subjects still have `state` fenced). Only AC-B1 and AC-B2 can go red first. State that, so the TDD gate does not
    stall demanding red from them. Their sensitivity is carried by m13–m16.

## 3. New-defect sweep (scope items)

| Check | Result |
|---|---|
| Every PR 1 AC can go red first | Yes. The endpoint does not exist (AC-1 to AC-7, AC-10, AC-2b); AC-8 and AC-9 are red because 16 Advice fields and 6 Cyclecount fields are writable today |
| Every mutant killable and attributable | Yes, except m4b under the wrong harness (L2). m1 attributable (not GUARDED); m10 → non-422; m13 needs PR 2's deletion of the item-verb method, which Fix C does |
| Gate steps executable | P1: is-ancestor yes; grep **no** (M1). P2: yes once the regex is de-escaped (L1); PRD bundles served unauthenticated (round 2 probe) |
| `plan-state.sh` sees the gates | Yes: P1 and P2 parse as OPEN |

## 4. Consensus addendum

- **Antithesis (steelman):** the plan now has 22 hand mutants for under 100 lines of production logic. Every one is a
  manual apply-run-revert cycle on context tests that take seconds each. The cost of the mutation floor may push the
  executor into batching mutants, which destroys attributability, the property §8.1 exists for.
- **Response:** most mutants share one or two context classes (AC-3/AC-9 harness, AC-8 metadata test), so one context boot
  per mutant is about 20 boots. That is bounded. The real risk is not cost but harness choice (L2), which decides whether
  three of them can be killed at all.
- **Tradeoff tension:** gate rigour against gate operability. Each strengthening of G1 and G2 (tag mapping, `build.time`,
  multi-host bundle scan) adds steps that someone outside this session (devops) runs by hand. M1 and L1 show the
  instrument decaying on the very edit that refined it. A short script in the PR body is more reliable than prose.
- **Synthesis:** keep the gates as written (with M1 and L1 fixed), and paste them into the PR bodies as one copy-paste
  shell block each, with the positive control as the first line, so a vacuous instrument fails loudly.

## References
- `v2/wms2-api` `origin/develop` `4960631d` and tag `v0.0.42`: `git grep setComment` (20 hits in `src/main`; hits at the tag);
  `git grep '"/setComment"' v0.0.42 -- src/main` (0)
- `v2/wms2-api/src/main/java/net/aim_ai/wms/model/Advice.java:10-42`: 18 declared fields, `state` `@ReadOnlyProperty`
- `v2/wms2-api/src/main/java/net/aim_ai/wms/model/Cyclecount.java:9-35`: 7 declared fields
- `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/AdviceController.java:32-35, 142-144`: no class-level gate; precedent handler
- `v2/wms2-api/src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java:118-167`: `GUARDED` excludes AdviceController
- `v2/wms2-api/src/main/java/net/aim_ai/wms/exceptions/RestExceptionHandler.java:60-393`: no handler for `InvalidDataAccessApiUsageException`
- `v2/wms2-api/src/main/java/net/aim_ai/wms/WebConfigurer.java:78, 108, 121`: `FAIL_ON_UNKNOWN_PROPERTIES=false`
- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/OutboxService.java:42`: `enqueue`
- `v2/wms2-api/src/test/java/net/aim_ai/wms/common/base/BaseRollbackIntegrationTest.java`: H2, no `@Transactional`
- `v2/wms2-api/src/test/java/net/aim_ai/wms/common/base/BasePostgresIntegrationTest.java:47`: `@Transactional("tenantTransactionManager")`
- `v2/wms2-api/src/test/java/net/aim_ai/wms/security/AdviceStateReadOnlyContextTest.java:59`, `SdrMustStayWritableStateNotPatchableContextTest.java:42`: both extend `BaseRollbackIntegrationTest`
- spring-data-rest-webmvc 4.5.7: `json/patch/JsonPointerMapping.java:105-128`; `config/PersistentEntityResourceHandlerMethodArgumentResolver.java:202-216`
- `sbdocs/9-System/scripts/plan-state.sh:268-279`: §5.1 row parser (P1/P2 OPEN on the snapshot)
- `v2/wms2-web-ui` `98accaf`: `closedNoticeDescription` mounted in `components/receiving/closed/closedNoticeDetails.vue` and `pages/receiving/closedNotice/_id.vue`
