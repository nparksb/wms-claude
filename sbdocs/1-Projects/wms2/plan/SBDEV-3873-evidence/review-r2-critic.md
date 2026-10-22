# SBDEV-3873 — ralplan round 2, Critic review

- **Subject:** `plan-snapshot-r2.md` (fixed snapshot, not edited), with `review-r1-critic.md`, `review-r1-architect.md`,
  `decisions-2026-10-22.md` (D1–D5, D3 amended), `analysis.md`, `db-verification.md`.
- **Verified against:** wms2-api `origin/develop` `4960631d` (fetched 2026-10-22; moved from the plan's `bafa2301` by
  SBDEV-3102 E4 only — none of `Advice`, `Cyclecount`, `RestConfiguration`, `AdviceController` or `security/` tests changed),
  wms2-web-ui `origin/develop` `98accaf` (unchanged). Spring Data sources read from `~/.m2`: spring-data-rest-webmvc 4.5.7,
  spring-data-jpa 3.5.7. No Maven, no DB access (DB MCPs down this session), nothing written outside this file.
- **Mode:** THOROUGH throughout. No High, no systemic pattern, so no escalation.

## VERDICT: ITERATE

**High 0 · Medium 4 · Low 9**

The round-1 High and the three shared Mediums are genuinely fixed:
- G1 closes the PR-W → PR 1 edge with a live-version proof.
- 422 is consistent everywhere (Fix A2, AC-4, Completeness (6), D3 amended).
- Hand mutants replace PIT.
- Option C is adopted as a stop-gap, and its mechanism is real. I traced it in the SDR 4.5.7 source myself (see below).

The design is approvable. What keeps this at ITERATE is the test spec. Two items on the brief's own checklist fail:
- **"No new vacuous test":** one of the two non-vacuity options the plan offers for re-scoped T4 is vacuous by construction (M1).
- **"Every AC maps to a mutant":** four ACs have none, and one listed mutant is killed by an assertion its AC disclaims
  (M2, M3).

M4 is a round-1 item that §11 marks resolved but is not. All four are text fixes, so round 3 should be a short delta.

---

## Verified (pass)

| Claim | Evidence | Result |
|---|---|---|
| The stop-gap mechanism: SDR merge-PATCH drops a non-writable field | `DomainObjectReader.doMerge` (4.5.7 `:253-256`): `if (!mappedProperties.isWritableField(fieldName)) { i.remove(); continue; }`. `MappedProperties.isWritableField` (`:247-258`) returns `property.isWritable()`. `JpaPersistentPropertyImpl.isWritable()` (`:167-169`) is `updateable && super.isWritable()`, and the super honours `@ReadOnlyProperty`. A field with no persistent property is also dropped, because `anySetterFound` is false (Advice has no `@JsonAnySetter`) | ✓ |
| No bypass on the same verb | JSON-Patch (`application/json-patch+json`) goes through `JsonPatchHandler.applyPatch` → `JacksonBindContext.getWritableProperty` (`:68-73`) → the same `isWritableField`. Collection POST and item PUT/DELETE are already withdrawn (r1). Neither entity has an association | ✓ |
| Hibernate ignores the annotation | `Advice.state` and `Cyclecount.state` already carry it and are set by the services. `git grep isWritable` in `src/main` returns 0 hits, so nothing else in the app consults writability | ✓ |
| AC-8 floors (≥10 / ≥5) are reachable | `Advice` declares 18 fields (`Advice.java:12-42`); `Cyclecount` declares 7 (`:11-35`). `id/created/modified/version` are on `AbstractBaseEntity`, so "declared" correctly excludes them | ✓ |
| AC-8 and AC-9 are red pre-fix for the right reason | Today only `state` is fenced, so 16 Advice fields besides `comment` are writable. AC-8 fails on a set mismatch, and AC-9 fails because `externalid`/`name` land (reproduced on dev, `db-verification.md` §1) | ✓ |
| T5 survives PR 1 | `AdviceStateReadOnlyContextTest.commentRemainsWritable` (`:79-85`) asserts only `comment.isWritable()`, which D5 keeps. No other test asserts a writable Advice/Cyclecount property: `git grep 'isWritable()' src/test` hits only T5 and T4 | ✓ |
| No existing test PATCHes non-comment fields on these types | `git grep 'patch('` in `src/test` returns nothing for advice/cyclecount | ✓ |
| Tranche pin 231 → 232, `WITHDRAWN` 51 → 53, `MUST_STAY` 8 → 6 | `Sbdev3017TrancheGateContextTest:1112` `hasSize(231)`; `SdrWriteWithdrawalContextTest:228` `hasSize(51)`, `:336` `hasSize(8)` at `4960631d` | ✓ |
| 422 / 404 / 409 mappings | `RestExceptionHandler:50,60-64` (422), `:200-210` (404, the same-package `exceptions.EntityNotFoundException`), `:384-390` (409); `@Order(0)`, unscoped | ✓ |
| AC-7's subjects exist | `AdviceService` holds `outboxService` (`:89`), `omsNotificationService` (`:83`), `messageService` (`:63`) and `httpRestService` (`:81`) | ✓ |
| G2's absence check is unambiguous | `git grep 'cyclecount/'` over store/components/pages/plugins finds exactly one literal, `cycleCount.js:261` (the PATCH). `nuxt.config.js:7` `ssr: false` (an SPA bundle) | ✓ |
| AC-W2 and AC-W1 are red pre-fix | `plannedCycleCountDescription.vue` watcher dispatches `saveComment` after a 700 ms `setTimeout`, and the plan now requires `$nextTick` first. `inboundNotices.js:410` `$patch` | ✓ |
| Closed-notice echo only fires when a comment exists | `closedNoticeDescription.vue:250-253`: `comment = noticeDetails.comment`, and null → null does not trigger the watcher, so null-comment notices send nothing | ✓ |
| D5 is safe | It changes no UI behaviour (the old cycle-count echo binds nothing; the old advice save still binds `comment`), and nothing in `src/main` depends on SDR binding these fields | ✓ (not unsafe) |

---

## Medium

### M1 — Re-scoped T4: the "or" option is vacuous by construction after PR 2, and m11 is the wrong mutant
**Location:** §5 Fix C, T4 bullet: `"It needs a positive control that seeds the check with a synthetic subject, or it asserts
the scanned-set size is greater than 0 over all exported types."` §8.1 m11: `"re-scoped T4 with an empty subject set"`.

**Evidence:** after PR 2, the exported types that still expose a write verb are the 6 remaining `MUST_STAY_WRITABLE` types
(Section, Boxtype, Client, Location, Sysprop, UserGroup). `UserFunction` and `UserGroupUser` are the only other exported
names outside `WITHDRAWN`. I grepped all 8 model classes for a `state` field and got 0 hits in each. So the set the
re-scoped T4 actually checks ("exported ∧ has `state` ∧ exposes PATCH") is **empty in PR 2's world**.

**Failure scenario:**
1. The executor takes option 2 (`scannedExportedTypes.size() > 0`). It is green with ~60 types.
2. The predicate `exposesPatch(md)` is written wrong: `ResourceType.COLLECTION` instead of `ITEM`, or it always returns
   false. The test still passes.
3. Later someone re-opens PATCH on a stateful type. T4 stays green.

That is exactly what Principle 4 and risk row 5 forbid. m11 (an empty subject set) is killed by option 2, so the mutation
table would record T4 as proven when its detector is not.

**Fix:**
- Delete option 2. Mandate a positive control that exercises the **predicate**, not the scan. Either:
  - (a) run the detector on a known positive: a stub `ResourceMetadata` whose item methods include PATCH, over a type with
    a writable `state`. It must report an offender.
  - (b) assert the detector's "exposes PATCH" classification on a real type known to keep PATCH (e.g. `Section` → true)
    and one known withdrawn (`Advice` → false), and also assert that "exported types with a `state` property" ≥ 2.
- Add **m11b:** "the `exposesPatch` predicate returns false". It must turn AC-B4 red.

### M2 — Four ACs have no mutant, and the round-1 M2 list was only partly carried over
**Location:** §8.1. The brief requires every AC to map to a mutant, and the floor requires every new assertion to be
mutation-checked.

**Evidence:**
- The m1–m11 targets are AC-1, AC-2, AC-3, AC-4, AC-7, AC-8, AC-9, AC-W1, AC-W2, AC-W3, AC-B1, AC-B2 and AC-B4.
- **AC-5, AC-6, AC-B3 and AC-B5 have no mutant.**
- Round-1 critic M2 named two of these explicitly: `"AC-5: replace null with "" coercion; AC-6:
  findById(...).orElse(new Advice())"`. Round-1 also asked for `"swap it to a different function"` for AC-3. All three
  were dropped, while §11 records `"Both M2 … §8.1 hand mutants"` as taken.
- Fix A2's `"A missing id returns 422"` has neither an AC nor a mutant.

**Failure scenario:**
- An implementation that `return`s early on `null` (so null no longer clears) or `.orElse(null)`s into an NPE → 500
  passes review with AC-5 and AC-6 never shown to bite. Both are behaviours §5 calls "carried over".
- The floor is recorded as met when it is not. That is the exact r1 M2 failure, narrowed.

**Fix:** add the following.
- **m12:** `if (comment == null) return;` → AC-5 red.
- **m13:** `orElseThrow(IllegalStateException::new)` → AC-6 red (500 ≠ 404).
- **m14:** `@RequiresFunction(WEB_UI_VIEW_INBOUND_BOL_ITEM_LINES)` → AC-1 red.
- **AC-10:** `{comment:"x"}` with no `id` → 422, with **m15** (drop the null-id check) → red (NPE → 500).
- AC-B3 and AC-B5 are re-runs of existing pins (T3 and AC-3). Say so in the table instead of leaving them blank.

### M3 — m4's kill rests on an assertion AC-2 disclaims, and the no-op-save claim the plan says "matters" has no AC
**Location:**
- AC-2: `"version and modified may move"`;
- §8.1 m4: `"AC-2 (version unchanged), plus an assertion that version increments"`;
- §5 Fix A2: `"An unchanged value produces no UPDATE (dirty checking). That matters because the closed-notice page re-saves
  on every open."`;
- Checklist: `"Idempotent: a replay re-sets the same value with no UPDATE"`;
- Completeness (4): `"Concurrency ✓ (409)"`.

**Evidence:**
- "May move" asserts nothing, so under m4 (a `@Modifying` JPQL UPDATE, which neither checks nor bumps `@Version`) AC-2 is
  **green**.
- The "assertion that version increments" exists only in the mutation table, not in any AC the TDD gate writes from.
- The idempotency property is the one a regression would hurt. After PR-W, every open of a closed notice that has a
  comment POSTs `setComment`: 6,443 of 12,626 advices on dev carry one, and `closedNoticeDescription.vue:234-243` is the
  echo. No AC pins "unchanged value → `version` unchanged".

**Failure scenario:** the implementation copies the DTO onto a fresh `new Advice()` with the id and saves it (a detached
merge). Alternatively it stamps `modified` by hand, or uses a `@Modifying` UPDATE for "efficiency".
- AC-2 to AC-9 all stay green.
- In production, every page view bumps `version`. A concurrent `closeInboundBol` or `acceptHubAndSpokeBol` that loaded the
  advice before the view then 409s.
- With m4 specifically, the claimed 409 protection silently disappears.

**Fix:**
- AC-2: assert `version == seeded + 1` (and `modified` > seeded), instead of "may move".
- Add **AC-5b:** POST the seeded comment unchanged → `version` and `modified` equal to the seeded values, and (if the IT
  can) no UPDATE statement. Map it to **m16**, "the service stamps `setModified(now())`" (or `saveAndFlush` on a detached
  copy).
- Optionally add **AC-11:** a stale-version concurrent update yields 409. Or drop "Concurrency ✓" to "409 by the global
  handler, not pinned".

### M4 — G1/G2 are invisible to `plan-state.sh`; round-1 L9 is marked resolved in §11 but is not
**Location:** §7 "5.1 Prerequisites" table rows `"Gate G1 …"` and `"Gate G2 …"`; §11 Lows: `"… section numbering"`.

**Evidence:**
- `sbdocs/9-System/scripts/plan-state.sh:272-277` parses only rows matching `^\| *\*{0,2}P[0-9]+` and reports a row as
  open only if it contains `YES`.
- The §5.1 rows are `| **Gate G1 (before merging PR-W)** | …` with no `P<n>` id and no `YES`, so the probe prints
  `"none parsed (either all closed, or the plan does not use the §5.1 table shape)"`.
- CLAUDE.md makes `plan-state.sh` the authoritative state instrument ("Do not read state out of a plan's `status:`").
- Round 1 (critic L9, architect L7) asked to confirm `plan-state.sh` still parses §5.1. The plan also still has no §3, and
  `### 5.1` still sits under `## 7`. §11 lists "section numbering" as taken.

**Failure scenario:** a later session (or the `wms-plan-executor` on PR-W) runs `plan-state.sh SBDEV-3873`, sees no open
prerequisites, and merges PR-W before G1 is proven. That recreates the round-1 H1 outage, a 405 toast on every
closed-notice open with a comment, through the very tool the repo trusts over prose.

**Fix:**
- Rename the rows to `| **P1** Gate G1 … | … | **YES** |` and `| **P2** Gate G2 … | … | **YES** |`. Close them by
  striking through, as the parser expects.
- Run `plan-state.sh SBDEV-3873` once and paste the section-5 output into the plan. Then either fix the numbering or
  remove it from §11.

---

## Low

- **L1 — AC-9 repeats the round-1 L6 defect that was fixed for AC-B2.**
  - AC-9 says `"as an INBOUND_BOL holder … PATCH /v3/cyclecount/{id} {"name":"EVIL"} returns 2xx"`.
  - The SDR rule for Cyclecount is `CYCLECOUNT_VIEW` = `WEB_UI_VIEW_CYCLECOUNT` (`SdrFunctionRules.java:180-181, :437`).
  - Under any enforcing guard mode, an INBOUND_BOL-only user gets 403. Pre-fix the test is then red for the wrong reason,
    and post-fix it never goes green.
  - Fix: pin the user to hold INBOUND_BOL **and** CYCLECOUNT, and set the guard mode explicitly (OFF), as AC-B2 now does.
    Name the harness (`BaseRollbackIntegrationTest` + webAppContext MockMvc) and reload after `em.clear()`.
- **L2 — AC-2's `type:"REGULAR"` is vacuous against a default fixture.**
  - `Advice.type` defaults to `REGULAR` (`Advice.java:33`), and so does a seeded row unless the test says otherwise.
  - The `type` comparison then passes even under m2.
  - Fix: seed a `RETURN` or `TRANSFER` advice, and make `clientId:<other>` a real second client. Memory: *Test can pass for
    wrong reason — vary the fixture*.
- **L3 — G1's instrument needs one more sentence to be executable.**
  - `/api/public/version` returns `self.version` from `APP_VERSION`, which `docker-image.yml:28-30` computes as
    `git describe --tags --abbrev=0`: the nearest reachable tag, not a SHA. "At that SHA" means the tag `v<self.version>`.
    That is conservative in the right direction (the image is at or after the tag).
  - Spell out: `git merge-base --is-ancestor <PR1 merge> v<ver> && git grep -q 'setComment' v<ver> --
    src/main/java/net/aim_ai/wms/controller/AdviceController.java`.
  - List the PRD api and web hosts by name. "Each PRD host" is not a list.
  - For G2: fetch `index.html`, then each `_nuxt/*.js` it references, then `grep -l '/advice/setComment'` (present) and
    `grep -c '/cyclecount/'` (= 0, valid because that literal is unique to the PATCH line).
- **L4 — AC-7 is vacuous if it lands in the planned `AdviceControllerUnitTest @Nested SetComment`.**
  - That class mocks `AdviceService`, so `verifyNoInteractions(outboxService)` is trivially true.
  - Fix: run AC-7 against the real `AdviceService` (with collaborators mocked, or `@MockitoSpyBean` in the IT), covering
    `outboxService`, `omsNotificationService`, `messageService` and `httpRestService`.
- **L5 — AC-5 does not say what value `""` stores** (`""` or `NULL`). Today's SDR PATCH stores `""`. State "`""` stores
  `""`, `null` stores NULL" (carry-over), or normalise, and assert that.
- **L6 — `"Each kill must name the mutant in its failure message"` is not literally achievable.** A test cannot know which
  mutant is applied. Say instead: the assertion's `.as(...)` message names the property or invariant that broke, and the
  PR body records mutant → failing test → message.
- **L7 — Manual plan gaps.**
  - M1b PATCHes 87150 without a snapshot or restore. If the stop-gap failed, it writes `externalid=X` on dev. Add the
    `snapshot.sh` wrap that M1 has.
  - M2 still exercises only one of the two mounts of `closedNoticeDescription` (round-1 L4: `pages/receiving/closedNotice/_id.vue`
    and the `closedNotices.vue` dialog).
  - Round-1 "What's missing" asked for an actor log line; §11 neither adopts nor rejects it.
- **L8 — AC-9 covers merge-PATCH only.** JSON-Patch reaches the same `isWritableField` (verified), so AC-8 covers it at the
  metadata level. A one-line `application/json-patch+json` `replace /externalid` case in AC-9 would pin the second binding
  path through the stack for free.
- **L9 — Two count sets are still not in the evidence file.** M1 `FINISHED 12,530 / 6,443` and M3 `CREATED 99 / 55` now
  carry their queries inline, but `db-verification.md` holds neither result. 6,443 there is the **all-states** figure
  (§2), so "FINISHED … of which 6,443" is still mislabelled unless the FINISHED subset happens to equal it. I could not
  re-run them (DB MCPs down). Record the outputs or relabel.

---

## Round-1 disposition audit

| Round-1 finding | Claimed | Actually |
|---|---|---|
| Critic H1 (PR-W before PR 1) | G1 | **Resolved.** The gate, instrument and risk row are corrected (405, echo-on-open). Instrument detail in L3; state tracking in M4 |
| M1 (400 vs 422) | 422 | **Resolved.** Consistent in Fix A2, AC-4, Completeness (6) and D3 amended |
| M2 (PIT) | hand mutants | **Partly.** AC-5, AC-6 and swap-function mutants dropped (M2); m4 unanchored (M3) |
| M3 (option C) | adopted (D5) | **Resolved.** Mechanism verified in source; the invariant test is sound |
| Critic M4 (gate instruments) | G1/G2 | **Resolved in substance**; L3 for exactness |
| L1 AC-W2 `$nextTick` | taken | Resolved |
| L2 / architect L3 (T4) | re-scoped | **Partly.** The option-2 escape hatch is vacuous (M1) |
| L3 (409) | stated | Stated, but not pinned (M3) |
| L4 (echo named) | taken | Named in S1 and risk row 1. Second mount still untested (L7) |
| L5 (AC-W3 scope, CI) | widened | Resolved (`pages/`, `plugins/` have 0 patch sites today) |
| L6 (AC-B2) | taken | Resolved for AC-B2. **Regressed into AC-9** (L1) |
| L7 (AC-2 columns) | taken | Over-corrected to "may move" (M3) |
| L8 (rollback order) | taken | Resolved |
| L9 (numbers, numbering, plan-state) | taken | **Not resolved** (M4, L9) |
| Architect L1 (AC-5b idempotency) | — | Not adopted, while the plan asserts the property (M3) |
| Architect L5 (release terms) | taken | Resolved (gate notes row) |
| Architect L6 (`NON_NULL`) | taken | Resolved (AC-5 asserts the DB) |
| Architect L7 (`String.length()`) | taken | Resolved |

## What's missing
- A predicate-level positive control for re-scoped T4 (M1).
- Mutants for AC-5 and AC-6, plus a missing-id AC (M2).
- An idempotency AC and a version-increment AC (M3).
- Gate rows the state probe can see (M4).
- A PRD host list for G1/G2 (L3).
- An actor log decision (L7).

## Ambiguity risks
- `"or it asserts the scanned-set size is greater than 0"` → A: predicate positive control / B: scan-count floor. B is
  vacuous here (M1).
- `"version and modified may move"` (AC-2) vs `"an assertion that version increments"` (m4) → the executor writes one or
  the other. Under A, m4 survives (M3).
- `""` "clears the comment" → A: stores `""` / B: stores NULL. The AC-5 assertion differs (L5).
- `"each PRD api host"` → A: the one shared PRD api / B: one per client stack. The number of probes differs (L3).

## Multi-perspective notes
- **Executor:**
  - AC-9 will stall under any enforcing test mode (L1).
  - T4 re-scope offers an easy wrong choice (M1).
  - Everything else is buildable from the text. The handler, DTO, exception types and harness base classes all exist where
    the plan says.
- **Stakeholder:**
  - The stop-gap closes `clientId`/`type`/`externalid`/`transferId`/`allowoverdelivery` at the first api deploy, which
    serves Driver 1.
  - The residual `created` is honestly stated and closed in PR 2.
- **Skeptic:**
  - The strongest remaining attack is not the design but proof decay: tests that look like they guard and don't (M1, L2,
    L4), and gates that disappear from the state tool (M4).
  - The design argument itself now holds. C is a fair stop-gap, the A withdrawal removes the drift risk, and Principle 5
    reconciles the filter with Principle 1.
- **Security:**
  - The new route is strictly narrower than the PATCH it replaces: an always-on function gate, a typed DTO and
    `FAIL_ON_UNKNOWN_PROPERTIES=false`.
  - After PR 1, SDR comment PATCH is still open to any `wms_user` at OFF until PR 2. That is a low-value field and is
    accepted.

## Verdict justification
ITERATE. There is no High, the design is correct, and every round-1 High and shared Medium is substantively fixed. It is
not APPROVE, because the brief's explicit gates fail on concrete evidence:
- A vacuous non-vacuity option for T4 (M1).
- ACs with no mutant, and a mutant killed only by an assertion the AC disclaims (M2, M3).
- A §11 "resolved" item that still leaves the cross-repo gates invisible to the authoritative state probe, recreating
  the round-1 H1 path (M4).

Each fix is a line or two of plan text. Round 3 can be a delta review of §5 Fix C, §8, §8.1 and §5.1 only.

Realist check:
- M4 kept at Medium rather than Low. The fix is trivial, but the failure it enables is the round-1 High outage, and its
  trigger (a session trusting `plan-state.sh`) is the documented workflow.
- M3 kept at Medium. **Mitigated by** dirty checking being Hibernate's default, so the regression needs a specific wrong
  implementation. The plan, though, calls the property load-bearing and leaves it unpinned.
- M1 is not High. It affects PR 2 only, which is two promotions away, and a reviewer might catch it at that point.

## Open questions (unscored)
- PRD guard mode is still sourced from the SBDEV-3183 record (§10). I could not re-query it this session either.
- Do the PRD web hosts serve `_nuxt/*.js` without Keycloak? If not, G2's curl needs a session cookie. Confirm before PR 2.
- AOP aspects on repository `save` and DB triggers on `advice` remain unchecked (analysis blind spots). They are low risk
  for the "no OMS side effect" claim.

---
*Ralplan summary row:*
- **Principle/Option Consistency: Pass.** C is adopted explicitly as a stop-gap under the new Principle 5, Principle 1 is
  met at PR 2, and G1/G2 enforce Principle 3 in both directions.
- **Alternatives Depth: Pass.** C is re-evaluated on current facts, and B and D are fairly rejected.
- **Risk/Verification Rigor: Fail (narrowly).** M1 (vacuous option), M2 (unmapped ACs), M3 (m4 unanchored, idempotency
  unpinned), M4 (gates invisible to the state probe).
- **Deliberate Additions: Pass.** The pre-mortem and §9 cover both ordering edges and rollback. The test plan spans unit,
  context, IT, Jest and manual. Observability is still "the existing request log" (L7).
