---
title: "SBDEV-2729 — System SKU (ICE PACK) cannot be received: null ZPL label token aborts receiveGoods"
ticket: "SBDEV-2729"
ticket_url: "https://app.clickup.com/t/868kgfhcq"
type: "bugfix"
severity: "high"
priority: "urgent"
status: "reviewed"
project: ["wms2-api"]
version: "v2"
requester: "Brent Campbell"
assignee: "Nam Park / David Oppenheim"
created: "2026-07-28"
updated: "2026-07-28"
revision: 8
db_verified: partial
db_verified_note: >
  Verified 2026-07-28 against the HMG tenant DB (MCP `nywh-hydra-uat`, confirmed
  by the requester to be the same database as HMG) plus `wms2-hydra-uat`,
  `wms2-hydra-dev2` and `wms2-hydra-v2t`.

  PROVEN at DB level: (a) the live `PRINTING_ZPL_CASE_LABEL` sysprop contains all
  11 `{token}` placeholders, so every one of the 12 `String.replace(...)` calls in
  `SharedService.createCaseLabel` executes against live data on this tenant;
  (b) exactly four of the twelve replacement sources are backed by NULLABLE
  columns — `itemdata.winetype`, `advice.externalid`, `boxtype.name`, and
  `los_sysprop.sysvalue` — while `itemdata.name`, `itemdata.item_nr`,
  `client.name`, `unitload.labelid`, `location.name` and `mywms_user.name` are all
  NOT NULL; (c) a `System-Client` row exists (`id=0`, `cl_nr='System'`,
  `name='System-Client'`), which is the client-independent ownership model the
  ticket describes; (d) of 2714 existing itemdata rows, 154 carry
  `winetype = ''` and ZERO carry `winetype IS NULL` — i.e. every SKU that
  currently receives successfully has an empty string, not a null.

  NOT PROVEN: the specific null field on the reporter's ICE PACK row. The
  reachable HMG copy is stale (newest `advice.created` = 2026-01-09; the incident
  is 2026-07-27) and contains no system-owned itemdata (`client_id = 0` → 0 rows)
  and no ICE PACK SKU. See §1.4 for the one query the implementer must run
  against the live HMG database before starting.
related:
  - "[[wms2-receiving-putaway-workflow]]"
  - "[[wms2-stockunit-design]]"
  - "[[wms-exception-taxonomy]]"
tags:
  - plan
  - wms2
  - receiving
  - null-safety
  - system-sku
---

# SBDEV-2729 — System SKU (ICE PACK) cannot be received: null ZPL label token aborts receiveGoods

**Ticket:** [SBDEV-2729](https://app.clickup.com/t/868kgfhcq)
**Project:** wms2-api | **Version:** v2 | **Type:** bugfix
**Priority:** urgent (Impact 4/5, Effort 1/5 — ClickUp says Confidence 90%; **this plan
assesses ~55-65% until §7.2 step 0 lands**, see §1.4)
**Status:** draft — not yet reviewed
**Date:** 2026-07-28

> ## ✅ APPROVED — architect and critic, revision 8 (2026-07-28)
>
> Five review rounds. **Both reviewers APPROVE.** The architect verified by building
> its own implementation of this plan into a full repo copy and running everything:
>
> | Measurement | Result |
> |---|---|
> | Whole verify script against a complete implementation | **`62 pass, 0 fail, 3 skip`** (3 skips = the `MAN*` manual rows) |
> | Full `mvn test` against that implementation | **`4538 tests, 2 failures`** — exactly the 2 known `develop` failures (`OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses`, `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`) |
> | The 7 test migrations in §8.1/§8.3 | **complete set** — nothing else in 4538 tests asserts the old contract |
>
> So the plan is **implementable to a clean acceptance line**, verified from an
> implementation written independently of this document.
>
> **Two things this approval explicitly does NOT cover**, in the critic's words:
>
> - *"Approving the plan is not endorsing the diagnosis."* `db_verified: partial`;
>   confidence is ~65-75% on the mechanism and **~50-60% on `itemdata.winetype`
>   specifically**. **§7.2 step 0 is unexecuted.** If the verbatim error string does
>   not name `replacement`, §2 reopens and this approval does not carry.
> - *"Independent of the diagnosis, the plan now fixes a real, measured, live
>   defect"* — the `SharedService:66` `boxtype_id` crash is confirmed on two tenants
>   (NULL on **80.1%** of unit loads; **281** on the reprint path) and does **not**
>   depend on the ICE PACK hypothesis. **That alone justifies PR1.**
>
> Live-HMG access for §1.4's prerequisite query also remains open.
>
> ---
>
> **Revision 2 — architect-reviewed.** Revision 1 was authored directly, without
> the `ralplan` consensus loop. An independent **architect review** was then run
> against the live codebase and four tenant databases, and this revision applies
> its findings. What the review changed:
>
> | Finding | Severity | Effect on this plan |
> |---|---|---|
> | `requireConfig` declared `private` but called cross-class by Fix B | **HIGH** | Guaranteed compile break — now package-private `static` (§5 Fix A) |
> | Fix D would swallow `EntityNotFoundException` on 6 endpoints | **HIGH** | Regression averted — `catch (EntityNotFoundException)` added first in all 6 (§5 Fix D) |
> | `OrderMonitorViewService:247` is a half-guard, not "already guarded" | MEDIUM | New §0.2 row 20, now covered by Fix C |
> | `requireConfig(warehouseName)` fires inside the per-case loop | MEDIUM | Not actually fail-fast — hoisted to `ReceivingService:429` (§5 Fix A) |
> | §12 claimed rollbacks are eliminated | MEDIUM | Corrected: the 2 `requireConfig` sites still roll back, and that is correct (§12) |
> | §1.2 asserted `String.replace` was the only candidate | MEDIUM | `String.contains` emits the identical message; now enumerated and excluded by evidence (§1.2) |
> | 4 verify-script defects (2 false-fail, 1 false-pass, 1 blind spot) | MEDIUM | All fixed in the script; see §9 |
> | Bean-cycle question was malformed | — | `SharedService` is already injected at `StockunitService:64,:94`; hedge and risk row deleted |
> | Counts, `LocalDateTime` vs `ZonedDateTime`, key count, SBDEV-2736 status | LOW | Corrected throughout |
>
> The review **independently reproduced** the §1.4 DB verification (all 15
> nullability claims matched `information_schema` exactly) and confirmed the root
> cause empirically on `openjdk 21.0.11`. It also established that the fail-fast
> blast radius is **zero** — all four reachable tenants have both required
> sysprops present and non-null.
>
> **Revision 3 — critic-reviewed.** The parallel critic review returned
> **APPROVE WITH CHANGES** and is now applied. It found things the architect pass
> did not:
>
> | Finding | Severity | Effect on this plan |
> |---|---|---|
> | `SharedService:66` `boxtypeRepository.findById(unitload.getBoxtypeId())` — `boxtype_id` is nullable and **NULL on 80.1% of live ULs** (10,718/13,381); **281** are on the reprint Path-2 that Fix E already modifies, giving HTTP 500 today | **HIGH** | New §0.1 row **0**; Fix A now guards it. Independently re-verified. Best find of either review — a live crash inside the method being rewritten |
> | The verbatim error string was never collected, though the ticket has a screen recording and asks for the log line | **CRITICAL** | New **blocking step 0** in §7.2. Cheapest decisive evidence, minutes of work |
> | A null `.replace` **receiver** emits a *different* message shape, so the ZPL-template hypothesis is ruled out — and the "ClickUp ate the variable name" story is wrong (the real name is the plain word `replacement`) | **CRITICAL** | §1.1 rewritten: the `""` is **unexplained**; §0.1 row 1 reclassified hardening-only. Verified by JDK-21 probe |
> | Message bundle resolves only under `en_US`; no base `messages.properties` exists | **HIGH** | Fix A now creates the base bundle; key renamed to the `BusinessException.*` convention; §8.1 asserts the resolved sentence |
> | Controller cannot supply BOL ID or SKU, so the logging AC was overclaimed | **HIGH** | Service-level context log added in `receiveGoods`; §9 row corrected |
> | "Null optional collections handled safely" mapped to string fixes | **HIGH** | Reclassified **NOT COVERED** in §9 rather than claimed |
> | `getSysvalue` is `@Cacheable` with no `unless = "#result == null"` → cached null keeps fail-fast firing after a direct-SQL seed | MEDIUM | New §14 risk + `unless` clause in PR1 |
> | D1 was decided per *file*, so one physical label printed three different fallbacks — including two for `{purchase_order}` inside one method | MEDIUM | §10 now pins the fallback **per token**; `{case_type}` `"*"` → `""` |
> | Confidence 90% is an argument from absence (0 NULLs across 11,489 rows on 2 tenants) | MEDIUM | Restated as **~55-65%** until step 0 |
> | A third SKU write path: `ItemdataRepository` is HAL-exposed with no `exported = false` | MEDIUM | Added to §2.3 — the most likely route for a hand-created system SKU |
> | 5 further verify-script defects (`A16`, `S1` bare-variable args, `C3`/`D4` `-ge`, `B7` line-counting, `A20` formatting-spec) | MEDIUM | All fixed |
> | ralplan skip is a real SKILL.md violation, not the "mechanical one-liner" exception | — | Acknowledged. It cost exactly what an adversarial pass catches: the boxtype crash, the uncollected attachment, and a self-contradiction in the plan's own After-code |
> | Scope mis-sequenced for an urgent blocker | — | §7.2 split into **PR1 (urgent)** / **PR2 (hardening)** |
>
> **Revision 4 — architect re-review round 2.** The architect verified revision 3,
> confirmed **all 14** of its own findings closed, independently re-measured the
> critic's boxtype numbers (`13,381 / 10,718 / 80.1% / 281` — all exact), and
> returned **CHANGES NEEDED** on defects revision 3 had *introduced*. Applied here:
>
> | Finding | Severity | Effect |
> |---|---|---|
> | `A7` and `A0b` **mutually unsatisfiable** — the boxtype guard deletes the `boxtype` local that `A7` demanded, so `0 fail` was mathematically unreachable | **CRITICAL** | `A7` now expects `caseTypeName`; Fix A's After block carries **one** form for `{case_type}`, not two |
> | `A4` required the thrown key `missingReceivingConfiguration` while `M1`/`M1b` required the bundle key `BusinessException.MissingReceivingConfiguration` — **both passed while the feature was broken** (`resolveMessage` would miss and print the raw key) | **CRITICAL** | Single key everywhere, in code, bundle, tests and checks |
> | **Four edits I had reported as applied were never written** — an earlier script hit an assertion and aborted *before* its write, silently discarding the message-key block, the key rename, the `{purchase_order}` single-fallback, and the whole service-level log | **CRITICAL** | All four re-applied and the write verified by re-reading the file. Cause of the two CRITICALs above |
> | `M2` forbade wording the plan itself mandated; cited a "§5 Fix A note 1" that did not exist | HIGH | Message reworded to blame the **warehouse**, not the SKU; phantom citation dropped |
> | `M7`'s regex could not span `@Cacheable` because the key SpEL contains `)` — false-failed in **both** attribute orders | HIGH | Fencing removed |
> | Unclosed ```` ```java ```` fence — everything after it rendered as code | HIGH | Closed; fence count now even |
> | Fix B still carried the pre-correction cascade text that Fix E refutes | HIGH | Corrected to one signature (`printLabel:532`) |
> | `D1` **defeated twice more** — a leak wrapped across two lines, and a leak hoisted into a local alias | MEDIUM | Now newline-insensitive and alias-aware; retested against all four shapes |
> | **9 further stale cross-references**, row 0 missing from both coverage lists, `30` vs `31` rows, `43` vs `49` baseline | MEDIUM | All repaired |
> | §6 was three files short (`ReceivingService`, `messages.properties`, `SyspropService`); §2/§4 never mentioned row 0; the `:429` hoist had no check | MEDIUM | All added (`A21`) |
> | Base bundle fixes **1 of 337** keys — §14 read as though the class of problem were solved | MEDIUM | Scope limit stated explicitly |
>
> **The `{case_type}` flip is REVERTED on architect recommendation.** Revision 3
> had changed `getBoxTypeNameFromUnitLoad` from `orElse("*")` to `orElse("")` for
> cross-path consistency. That would alter printed output on **10,718 of 13,381 ULs
> (80.1%)** for every damaged-split and multi-stock label — the widest-blast-radius
> output change in the plan, purely cosmetic, unlisted in §12, untested in §8.4, and
> in a method both reviews certified correct. `SharedService` uses `""`; the helper
> keeps `"*"`. §10 open question 1 records the one accepted difference.
>
> **Satisfiability now proven, not asserted.** The nine previously-contradictory
> checks were run against a single constructed implementation: **9 pass, 0 fail**.
> `D1` was retested on four shapes (wrapped leak, alias leak, correct Fix D, current
> code) and discriminates correctly on all four.
>
> **Revision 5 — critic re-review round 2.** The critic verified revision 3 and
> returned **REJECT** with 12 required items. Revision 4 had already closed 7 of them
> independently (it was written from the architect's parallel round-2 pass); revision 5
> closes the remaining 5 plus the extras:
>
> | Item | Effect |
> |---|---|
> | Old message key survived at 4 more sites than revision 4 fixed | One key end-to-end: §5, §6, §7.1 monitoring, §8.3, §13, and script `A4` |
> | `SyspropService` `unless` was named in prose but was not a fix | Promoted to **§5 Fix F** with before/after, assigned to PR1, asserted by `M7` |
> | Step 0 was bypassable — §7.1 Prerequisites and §8.5's gate never mentioned it | §7.1 has a **BLOCKING** row; §8.5's gate is now **five** conditions with step 0 as (0) |
> | §7.2's numbered steps still described the monolith and omitted 4 PR1 items | Steps re-cut into PR1 (3-12) / PR2 (13-18) / both (19) |
> | **PR1 had no attainable acceptance line** — §7.2 step 12 and §8.5 demanded whole-script `0 fail`, which PR1 cannot reach (`D1`/`D6` scan all six catches; every `B*`/`C*` is PR2) | PR1 gate is now an explicitly **named check subset**; the script header says so too |
> | ACs 1, 4 and 11 overclaimed; AC 12 unmet | AC 1 → "no code change, not tested here"; AC 4 → "**asserted, unverified**" (query 4 evidences a `los_sysprop` row, not an `itemdata` row); AC 11 → resolves now that Fix D carries the log; AC 12 → new `shouldBuildLabelForSystemOwnedSku` test with `clientId = 0` |
> | `B7` still line-counted despite a comment claiming otherwise — one finished builder passed it with the other unguarded | Now asserts two `requireConfig` calls **inside each method body** |
> | 5 reference survivors; §15 rows 2/9 and §14 row 1 stale | All fixed; §14 row 1 now walks back "the residual space is small" |
> | Confidence conflated two questions | Split: **~65-75%** "a null `String.replace` argument in a case-label builder" vs **~50-60%** "specifically `itemdata.winetype`" |
> | Branch SHA wrong for the third revision running | SHA dropped; the instruction kept |
>
> **`{case_type}`: the critic independently reached the same revert conclusion as the
> architect, and added the stronger reason** — the helper feeds *two* builders, and in
> `createCaseLabelMultiStock` `"*"` is consistent with its four sibling aggregate
> markers, so blanking it would make `{case_type}` the only token that blanks instead
> of stars on an aggregate label. The unification was not merely risky, it was wrong
> for one of the two callers. §10 open question 1 records the correct shape if
> uniformity is ever wanted (a fallback *parameter* on the helper).
>
> The critic also re-ran all five JDK-21 probe rows (all accurate), re-verified the
> `.contains` enumeration, and re-confirmed every data value — finding **no corruption
> in the data values themselves** after the earlier repairs. It also confirmed `D1`
> now survives attack, and that the PR split is **dependency-safe**
> (`StockunitService` has its own `createCaseLabel` and never calls `SharedService`'s).
>
> **Revision 6 — critic re-review round 3: APPROVE WITH CHANGES.** The critic verified
> revision 5 **by content rather than by changelog**, confirmed the four previously
> unwritten edits are now genuinely present, and confirmed the disqualifying revision-3
> defects are gone (document renders, `D1` holds under attack, `A7`/`A0b` satisfiable so
> `0 fail` is reachable). Nine mechanical items remained; all are applied here:
>
> | Item | Severity | Fix |
> |---|---|---|
> | **`%1$s` had been written `%1$$s`** — two literal `$`, which is not a valid Java format string. `String.format` throws `UnknownFormatConversionException`, `resolveMessage` catches it as `IllegalFormatException` and falls back to `concatenateKeyAndParameter` → **the operator sees the raw key**, i.e. exactly the H2 bug the rename existed to prevent | **CRITICAL** | Corrected at both sites. A shell-escaping artifact I introduced |
> | §10's `{case_type}` row still mandated the flip that was reverted everywhere else — the decision record contradicted the decision, and told the implementer to change checks that were already right | HIGH | Row rewritten; open question 1 closed as **DECIDED** |
> | Baseline stated `10 pass, 50 fail` while the prose said `49`/`10` and listed **eleven** checks | HIGH | Re-measured and corrected to `11 pass, 51 fail, 3 skip` everywhere |
> | `D1` had a plausible **false-FAIL**: neutralising the `LOG.error` *name* left its *arguments* in the block, so an implementer keeping the harmless `LOG.error("...", e.getMessage(), e)` would go red | MEDIUM | `D1` now asserts only on `errors.add(...)` statements; retested on five shapes incl. that one |
> | §10 claimed "all 13 of its tokens already agree" when 12 agreed and the 13th was the half-guard being fixed | MEDIUM | Corrected, with the reason `C3`'s threshold is `>=12` |
>
> Already closed in r5 and confirmed by the critic: the old message key (only the
> changelog row that *describes* the defect retains it), §2's row-22→23 reference, and
> the PR1/PR2 re-cut steps with PR1's named acceptance subset — the critic had read a
> stale copy on those three.
>
> **A fourth lost-write casualty was found by this round.** The §10 `{case_type}` revert
> was in the same aborted script as the four r4 losses, so it never reached disk while
> the script-side revert did. Every edit pass now ends with the critic's own detection
> grep (`%1\$\$s|missingReceivingConfiguration|row 22)|all 13|10 pass|50 fail`) plus a
> fresh script run, and the pasted `Result:` line is measured, never remembered.
>
> **Revision 7 — architect re-review round 3: CHANGES NEEDED (narrow).** The architect
> did something neither the critic nor I did: it **built its own implementation of this
> plan into a full copy of the repo** — real `pom.xml`, real test sources — and ran the
> **entire** script plus the test suite. Result: **`60 pass, 2 fail, 3 skip`.** All 60
> grep-level checks pass simultaneously against one consistent implementation, so
> satisfiability is now independently established: `A7`/`A0b` no longer conflict,
> `A4`/`M1` agree, `M2` and `M7` are satisfiable, and **the contradiction has not been
> relocated a third time.**
>
> The 2 failures were the blocker, and they are a class of defect no amount of regex
> review would have surfaced:
>
> | Finding | Severity | Fix |
> |---|---|---|
> | **This plan breaks 7 EXISTING tests and §8 never migrated them.** `shouldHandleNullAdviceWithNaForPurchaseOrder` asserts `{purchase_order}` = `"N/A"`, which Fix A's one-fallback-per-token rule makes `""`. And all **six** `ReceivingControllerUnitTest$RuntimeExceptionHandling` tests assert the raw exception message reaches the client — exactly what Fix D removes. So §7.2 step 17 ("expect exactly the 2 known failures") and step 18 (`0 fail`) were unsatisfiable | **BLOCKER** | §8.1 and §8.3 now carry explicit **MIGRATION REQUIRED** entries for all 7; step 17 says "2 known + the 7 migrations"; a full `mvn test` before PR1 is mandated because the script names only 4 test classes |
> | Fix B **still** carried the stale cascade sentence — my N6 fix was in the same aborted script as the r4 losses | HIGH | Replaced; a **fifth** lost-write casualty from that one script |
> | `C4` false-failed the plan's **own** After-sample, because the sample wraps the ternary and `file_contains` is line-based | HIGH | Sample un-wrapped **and** `C4` made newline-tolerant |
> | `D1` missed `e.getLocalizedMessage()` and `e.toString()`, and silently passed an unbalanced block | MEDIUM | Matches all three accessors, flushes at `END` so an unbalanced block fails **loudly**. `getLocalizedMessage()` matters because `ReceivingController` already uses it **5×** — it is house style |
> | `A0b` clause 1 was a formatting spec that false-failed a correctly wrapped boxtype chain | MEDIUM | Dropped; the newline-tolerant clause carries the semantics |
>
> Also fixed: three stale script section comments. `%1$s` and §10's `{case_type}` row had
> already been corrected in r6, which the architect independently confirmed.
>
> **An implementation detail worth knowing before you start:** `A18`/`B3` deliberately
> tolerate the `warehouseName = requireConfig(warehouseName, …)` reassignment idiom, but
> the repo-wide sweep `S2` exempts `warehouse)` and not `warehouseName)`, so that idiom
> trips it in `StockunitService`. Introduce a `warehouse` local in both builders. The
> architect hit this while implementing; §5 Fix B now says so.
>
> The architect's two accepted residuals: `B7`'s line-counting and `S2`'s line-scoped
> allowlist both **under**-detect rather than block correct code, so they are recorded
> rather than fixed. Its process note is also taken — both artifacts moved mid-review
> twice, so freeze them before any further pass.
>
> **Revision 8 — final.** Applied the last four hygiene items, none of which needed a
> further review round: `B7` rebuilt on the architect's pre-validated line-based
> formulation (validated against four trees — correct impl 4/2 PASS, one-call-per-builder
> 2/0 FAIL, builder1-only 2/1 FAIL, unmodified `develop` 0/0 FAIL, closing **both** holes
> found in it); `D7b` moved into PR1's acceptance subset (it had been in neither
> partition, so no gate asserted it); §8.5 condition 3 given the measured "2 known + the
> 7 migrations"; and the Fix E paragraph that read as "the existing tests are fine"
> scoped explicitly to **compilation**, with a pointer to the 7 assertion migrations —
> three review passes misread that paragraph and missed those seven tests.
>
> The critic also **independently re-verified** all 16 nullability claims, the
> regression chain, every line number, and the `9 pass / 38 fail / 3 skip`
> baseline — and confirmed D4's premise by checking that every other `winetype`
> reader writes into a DTO setter, so nothing else breaks on NULL today.

---

## 0. Affected sites (enumeration before drafting)

Produced by enumeration, not memory:

```bash
grep -rn '\.replace("{' src/main/java --include=*.java        # 50 hits, 3 files
                                                              #   SharedService 12 | StockunitService 24 | OrderMonitorViewService 14
grep -rn "CharSequence" src/main/java --include=*.java        # 2 hits, both unrelated (KeycloakService)
grep -rn "String\.join" src/main/java --include=*.java        # 4 hits, all null-safe
grep -rn "createCaseLabel" src/main/java --include=*.java     # 3 definitions, 6 call sites
grep -rn '\.contains(' src/main/java --include=*.java         # see §1.2 — String.contains(CharSequence)
                                                              # produces the IDENTICAL message; enumerated and excluded
```

`{...}` token substitution is the only place in `wms2-api` that reaches a JDK API
declaring a `CharSequence` parameter and dereferencing it
(`String.replace(CharSequence target, CharSequence replacement)`), which is what
the reported exception text identifies. There are no `CharSequence`-typed
parameters in project code. §1.2 records the one other JDK method that can emit
the byte-identical message and why it is ruled out.

### 0.1 `SharedService.createCaseLabel` — the receiving-path label builder

| # | File:line | Construct | Source nullable in DB? | Same root cause? | In scope? |
|---|-----------|-----------|------------------------|------------------|-----------|
| **0** | `service/SharedService.java:66` | `boxtypeRepository.findById(unitload.getBoxtypeId()).orElseThrow(...)` | **YES — and null on 80.1% of live rows** (10,718 / 13,381 on the HMG copy) | **no — a DIFFERENT live crash**, `InvalidDataAccessApiUsageException` ("The given id must not be null") from `findById(null)`, not an NPE | **YES — must fix in the same PR**, see §5 Fix A |
| 1 | `service/SharedService.java:53` | `syspropService.getSysvalue(PRINTING_ZPL_CASE_LABEL)` → receiver of every `.replace` | **YES** (row may be absent; `sysvalue` nullable) | **no — RULED OUT as the reported bug.** A null *receiver* emits `Cannot invoke "String.replace(java.lang.CharSequence, java.lang.CharSequence)"`, a different message shape than the ticket's (probe, §1.2) | **yes — as hardening only**, not as the fix for this symptom |
| 2 | `service/SharedService.java:68` | `.replace("{warehouse}", warehouseName)` | **YES** (`findSysvalueByClientIdAndSyskey` returns bare `String` → null when no row) | yes | **yes** — required config, fail fast |
| 3 | `service/SharedService.java:69` | `.replace("{product_name}", itemdata.getName())` | no (`itemdata.name` NOT NULL) | yes (mechanism) | **yes** — defensive, uniform helper |
| 4 | `service/SharedService.java:70` | `.replace("{SKU}", itemdata.getItemNr())` | no (`item_nr` NOT NULL) | yes (mechanism) | **yes** — defensive |
| 5 | `service/SharedService.java:71` | `.replace("{shipper}", client.getName())` | no (`client.name` NOT NULL) | yes (mechanism) | **yes** — defensive |
| 6 | `service/SharedService.java:72` | `.replace("{product_type}", itemdata.getWinetype())` | **YES** (`itemdata.winetype` nullable) | yes | **yes — PRIMARY SITE** |
| 7 | `service/SharedService.java:73` | `.replace("{size}", String.valueOf(itemdata.getBottleSize()))` | **YES** (`bottle_size` nullable; `Itemdata.java:33` is `Integer`) | no — cannot throw | no — **but see caveat** |
| 8 | `service/SharedService.java:74` | `.replace("{units}", String.valueOf(...))` | n/a | no — same | no — already null-safe |
| 9 | `service/SharedService.java:75` | `.replace("{u_load}", unitload.getLabelid())` | no (`unitload.labelid` NOT NULL) | yes (mechanism) | **yes** — defensive |
| 10 | `service/SharedService.java:76` | `.replace("{date}", createdDate)` | n/a | no — `createdDate` is computed non-null at :51 | no — see row 25 |
| 11 | `service/SharedService.java:79` | `.replace("{purchase_order}", purchaseOrder)` | **YES** (`advice.externalid` nullable) | yes | **yes** |
| 12 | `service/SharedService.java:80` | `.replace("{user}", operator.getName())` | no (`mywms_user.name` NOT NULL) | yes (mechanism) | **yes** — defensive |
| 13 | `service/SharedService.java:81` | `.replace("{case_type}", boxtype.getName())` | **YES** (`boxtype.name` nullable) | yes | **yes** |

> **Caveat on row 7 (`{size}`).** `String.valueOf(null)` cannot throw, so this is
> correctly out of scope for *this NPE*. But it yields the literal string
> `"null"`, so an ice-pack label would print `SIZE: null` — which violates §10 D1's
> own principle (blank for meaningless optional fields). `bottle_size` is
> `0/2714` null on the tenant checked, and the same
> `SkuBatchCreateUpdateService` path that leaves `winetype` NULL also leaves
> `bottleSize` NULL, so this is a *next ticket*, not this one. Recorded so it is
> a known deferral rather than an oversight.

### 0.2 Sibling label builders (same chain, different entry points)

| # | File:line | Construct | Same root cause? | In scope? |
|---|-----------|-----------|------------------|-----------|
| 14 | `service/StockunitService.java:548` | `syspropService.getSysvalue(PRINTING_ZPL_CASE_LABEL)` → nullable receiver | yes | **yes** |
| 15 | `service/StockunitService.java:553-564` | `createCaseLabel` — 12-call replace chain, same nullable sources as rows 2/6/11/13 | yes | **yes** |
| 16 | `service/StockunitService.java:573` | `getSysvalue(PRINTING_ZPL_CASE_LABEL)` in `createCaseLabelMultiStock` | yes | **yes** |
| 17 | `service/StockunitService.java:575-586` | `createCaseLabelMultiStock` — nullable sources are `{warehouse}` (:575), `{shipper}` (:578), `{u_load}` (:582); the rest are literals | yes | **yes** |
| 18 | `service/StockunitService.java:591-598` | `getBoxTypeNameFromUnitLoad` | no — **already null-safe**: `.map(Boxtype::getName).orElse("*")` returns `"*"` for both a missing boxtype and a null name | no — reference idiom |
| 19 | `service/OrderMonitorViewService.java:262` | `.replace("{lane_id}", automationLane.getName())` — unguarded | yes | **yes** — defensive (`location.name` is NOT NULL, so latent only) |
| 20 | `service/OrderMonitorViewService.java:247` | `.replace("{carrier_code}", shipperID != null ? shipperID.getExternalid() : "N/A")` — guards the **object**, not the **value** | **yes — the exact same half-guard defect as `SharedService:78`** | **yes** — see note below |
| 21 | `service/OrderMonitorViewService.java:242-246, 248-254` | 12 replaces, **every one correctly guarded** on the value with `x != null ? x : "N/A"` | no | no — this is the in-repo idiom the label builders never adopted |

### 0.3 Error-surfacing sites (the "raw Java exception shown to user" AC)

| # | File:line | Construct | Same root cause? | In scope? |
|---|-----------|-----------|------------------|-----------|
| 22 | `controller/ReceivingController.java:257-260` | `catch (RuntimeException e) { ... getErrorMessage("Runtime Error", e.getMessage()) }` on `/receive` — puts the raw NPE text in the HTTP 200 error envelope the UI renders | separate defect (surfacing, not cause) | **yes** — ticket AC requires it |
| 23 | `controller/ReceivingController.java:84-87, 128-131, 164-167, 191-194, 221-224` | identical raw-message leak on `setPallet`, `createAndSelectPallet`, `createPallet`, `unlinkSelectedPallet`, `updatePallet` | yes — same pattern | **yes** — same helper, 5 extra sites |
| 24 | `controller/UnitLoadController.java:70-72` | catches only `FacadeException`; must gain a `BusinessException` catch once `reprintLabel` propagates it (Fix E) | consequential | **yes** |

### 0.4 Enumerated and deliberately EXCLUDED

| # | File:line | Construct | Why excluded |
|---|-----------|-----------|--------------|
| 25 | `service/SharedService.java:51`, `service/StockunitService.java:546,571` | `unitLoad.getCreated().toLocalDate()` — `unitload.created` is a nullable column (`AbstractBaseEntity.java:29` is `LocalDateTime`, DB column is `timestamp with time zone`) | Different exception signature (`Cannot invoke "java.time.LocalDateTime.toLocalDate()"`), and `created` is stamped by the entity lifecycle so it is never null for a UL created moments earlier in the same transaction. Not the reported defect. Note as a follow-up only if it is ever observed. |
| 26 | `service/ReceivingService.java:453-455` | `locationRepository.findById(itemdata.getPutawaylocationId())` | Hypothesised second-layer blocker for system SKUs, **ruled out at DB level**: `itemdata.putawaylocation_id` is `NOT NULL` on the HMG schema, so `findById(null)` cannot occur. |
| 27 | `exceptions/BusinessException.java:59` | `String.join(", ", paramList)` | Ruled out: `paramList` is a `List<String>` populated via `"" + o`, so no element can be null, and the `Iterable` overload of `String.join` is null-tolerant regardless. |
| 28 | `service/mobile/MobileInfoService.java:342`, `service/mobile/MobileTruckLoadingService.java:168,359` | `String.join(", ", s)` | Ruled out: `Iterable` overload, and not on the receiving path. |
| 29 | `service/SkuBatchCreateUpdateService.java:57,72`, `controller/FileImportController.java:375` | `setWinetype(sku.getWineType())` with no null-coalescing — the **upstream enabler** that lets `winetype` persist as NULL | **Out of scope by explicit decision (§10 D4):** code-only label fix. NULL remains a legal value for `itemdata.winetype` and is handled at every read site instead. No Flyway migration. |
| 30 | `v1/wms-api ReceivingService.java:144,148`; `v1/wms-api StockunitService.java:579,583,602,606` | Identical unguarded replace chain in v1 | **Out of scope by explicit decision (§10 D3):** v2-only for this ticket. v1 retains the latent NPE. See §11 for the cross-version note. |

**Coverage check:** in-scope rows **0**, 1–6, 9, 11–17, 19–20, 22–24 are each addressed by a
named fix in §5 and by at least one assertion in
`sbdocs/9-System/scripts/verify-SBDEV-2729-system-sku-receiving-null-label-token.sh`.

---

## 1. Problem Statement

### 1.1 User-visible symptom

An inbound BOL was created on the **HMG** warehouse to receive **1,000** units of
the **ICE PACK** SKU — a *system SKU*, owned by the SiteBoss `System-Client`
rather than by a merchant. When the operator completes the receipt, the receive
fails and the WMS UI renders a raw Java exception:

```
Cannot invoke "java.lang.CharSequence.toString()" because "<name>" is null
```

The ticket reproduces this text twice with the variable name lost — once as
`because "" is null` and once paraphrased as `because quotations is null` (the
reporter describing "the thing in quotations"). It is **not** a field called
`quotations`. The rest of the message is a verbatim Java 21 helpful-NPE.

**The missing name is genuinely unexplained, and that matters.** An earlier draft
of this plan asserted the ClickUp editor had swallowed a `"<...>"` fragment as an
HTML tag. Measurement kills that story for the site this plan blames: a null
*argument* to `String.replace` reports the plain word `replacement` (see the probe
table in §1.2), which no sanitizer would strip. Angle brackets appear only for the
*receiver* case — and §1.2 shows the receiver case emits a **different message
shape** entirely, so it is excluded. Conclusion: the report was transcribed
lossily, the original string was never captured, and **this plan does not have a
positive identification of the failing variable.** §1.4 and §7.1 treat that as the
gap it is. Do not read §2 as confirmed until prerequisite step 0 closes it.

Consequences: no inventory is created, ice packs cannot be put away or picked,
and temperature-controlled fulfilment is blocked.

### 1.2 Why the exception text alone identifies the fix site

Java's helpful NPE names the **static type of the receiver**, not its runtime
type. A null `String` field would produce
`Cannot invoke "java.lang.String.toString()"`. The message says
**`java.lang.CharSequence.toString()`**, so the receiver is declared as
`CharSequence`. `wms2-api` declares no `CharSequence` parameters anywhere
(`grep -rn "CharSequence" src/main/java` → 2 hits, both `CharSequenceReader` in
`KeycloakService`), so the call must be a JDK method taking `CharSequence`. The
only such method reached on the receiving path is:

```java
// java.lang.String (JDK 21)
public String replace(CharSequence target, CharSequence replacement) {
    String trgtStr = target.toString();          // ← target is a literal here
    String replStr = replacement.toString();     // ← THIS throws when the value is null
    ...
}
```

`String.replace(CharSequence, CharSequence)` is **null-hostile** — unlike
`StringBuilder.append`, `String.valueOf`, `String.format("%s", ...)` or
`String.join(delimiter, Iterable)`, none of which throw on a null value. Every
`{token}` substitution in the case-label builders uses exactly this method.

**Verified empirically on `openjdk 21.0.11`** (this machine), not inferred:

| Probe | Message |
|---|---|
| `"{x} x".replace("{x}", null)` | `Cannot invoke "java.lang.CharSequence.toString()" because "replacement" is null` ← **byte-identical to the ticket** |
| `"abc".contains(null)` | `Cannot invoke "java.lang.CharSequence.toString()" because "s" is null` ← **also identical** |
| `"abc".contentEquals(null)` | `Cannot invoke "java.lang.CharSequence.length()"` — different method |
| `"abc".replaceAll("b", null)` | `Cannot invoke "String.length()"` — different type |
| null `LocalDateTime` → `.toLocalDate()` | `Cannot invoke "java.time.LocalDateTime.toLocalDate()"` — different type |

**The one other candidate, enumerated and excluded.** `String.contains(CharSequence s)`
is implemented as `indexOf(s.toString())` and emits the *same* message. It is
therefore not enough to say "`String.replace` is the only such method" — that had
to be checked. The only `.contains(` calls on the receiving path are
`UnitloadBusinessService.java:410` and `:616`, and both receivers are collections
(`Collection.contains(Object)`, which is null-tolerant), not strings. So the
conclusion holds, but by enumeration rather than assertion.

**Free triage step this yields.** The parameter name in the message is
deterministic per call site: `String.replace` always reports `"replacement"`,
`String.contains` always reports `"s"`. The ticket lost the name, but it can be
*recovered* rather than guessed — grep the HMG application logs for:

```
because "replacement" is null
```

A hit confirms `String.replace` and closes the last gap in §1.4 more cheaply and
more decisively than the prerequisite DB query. Do this first.

### 1.3 Reproduction

1. Ensure the tenant has an itemdata row with `winetype IS NULL` (a system SKU
   created without a wine type — see §2.3 for how that happens).
2. Create an inbound BOL / advice for that SKU with a positive quantity.
3. `POST /v3/receiving/receive` with a valid `advicePositionId`, `boxTypeId` and
   `printerId`.
4. The request returns HTTP **200** with
   `{"errors":[{"Runtime Error":"Cannot invoke \"java.lang.CharSequence.toString()\" because ... is null"}]}`
   and the tenant transaction is rolled back — no `Unitload`, `Stockunit`,
   `Stockrecord` or `Goodsreceiptposition` rows are written.

### 1.4 DB verification (Analysis-protocol gate §8) — `db_verified: partial`

Run against the HMG tenant DB (MCP `nywh-hydra-uat`, confirmed by the requester
to be the same database as HMG).

**Query 1 — does the live ZPL template actually exercise all the replace calls?**

```sql
SELECT sysvalue FROM los_sysprop WHERE syskey = 'PRINTING_ZPL_CASE_LABEL';
```

Result (abridged) — all 11 distinct tokens are present, so all 12
`String.replace` calls run against live data on this tenant:

```
^XA^P0N^CI31 ... ^FD{warehouse}^FS ... ^FD{product_name}^FS ... ^FD{SKU}^FS
... ^FD{shipper}^FS ... ^FD{product_type}^FS ... ^FD{size}^FS ... ^FD{units}^FS
... ^FD{u_load}^FS ... ^FD{date}^FS ... ^FD{purchase_order}^FS ... ^FD{user}^FS
... ^FD{case_type}^FS ... ^XZ
```

**Query 2 — which replacement sources can legally be null?**

```sql
SELECT table_name, column_name, is_nullable
FROM information_schema.columns
WHERE (table_name='itemdata'    AND column_name IN ('name','item_nr','winetype','varietal','bottle_size','putawaylocation_id'))
   OR (table_name='client'      AND column_name='name')
   OR (table_name='unitload'    AND column_name IN ('labelid','created'))
   OR (table_name='boxtype'     AND column_name='name')
   OR (table_name='advice'      AND column_name='externalid')
   OR (table_name='mywms_user'  AND column_name='name')
   OR (table_name='location'    AND column_name='name')
   OR (table_name='los_sysprop' AND column_name='sysvalue');
```

| Column | Nullable | Feeds token |
|---|---|---|
| `itemdata.winetype` | **YES** | `{product_type}` ← **primary suspect** |
| `advice.externalid` | **YES** | `{purchase_order}` |
| `boxtype.name` | **YES** | `{case_type}` |
| `los_sysprop.sysvalue` | **YES** | `{warehouse}` + the ZPL template receiver |
| `unitload.created` | YES | (computed date — excluded, row 25) |
| `itemdata.name`, `itemdata.item_nr`, `itemdata.putawaylocation_id`, `client.name`, `unitload.labelid`, `boxtype`→`mywms_user.name`, `location.name` | NO | — |

**Query 3 — do currently-working SKUs differ from the failing one?**

```sql
SELECT count(*) AS total,
       count(*) FILTER (WHERE winetype IS NULL) AS winetype_null,
       count(*) FILTER (WHERE winetype = '')    AS winetype_empty
FROM itemdata;
```

| total | winetype_null | winetype_empty |
|---|---|---|
| 2714 | **0** | **154** |

**Read this carefully — it is weaker than it first looks.** Empty string is
harmless to `String.replace`; NULL is fatal. So *if* the ICE PACK row holds NULL,
the mechanism explains everything. But the counts are an **argument from absence**,
not a positive observation: across two reachable tenants (2,714 rows here + 8,775
on `wms2-wineco-dev` = 11,489 rows) **no NULL `winetype` has ever been observed**,
and on the HMG copy all four "proven-nullable" sources hold zero NULLs
(`winetype` 0, `advice.externalid` 0, `boxtype.name` 0, `los_sysprop.sysvalue` 0).

What the data proves: the **column is nullable**, nothing coalesces it at either
writer, and 154 non-wine SKUs receive fine with `''`. What the data does **not**
prove: that the ICE PACK row actually holds NULL. That is why the ticket's stated 90% confidence is not supportable. Split into the two
questions it conflates:

| Claim | Confidence | Basis |
|---|---|---|
| "a null `String.replace` **argument** in a case-label builder" | **~65-75%** | Mechanism proven in code and schema; the deterministic parameter name `replacement` matches the reported message shape exactly; no competing call site on the receiving path (§1.2) |
| "specifically `itemdata.winetype`" | **~50-60%** | 0 NULLs across 11,489 rows on two tenants, and `boxtype.name` / `advice.externalid` / `los_sysprop.sysvalue` are equally nullable |

Step 0 (§7.2) collapses both to certainty, which is why it is blocking.

**Query 4 — the ownership model the ticket describes exists:**

```sql
SELECT s.client_id, c.cl_nr, c.name, s.syskey, s.sysvalue
FROM los_sysprop s LEFT JOIN client c ON c.id = s.client_id
WHERE s.syskey IN ('WAREHOUSE_NAME','MAXIMUM_RECEIVING_DURING_INBOUND');
```

| client_id | cl_nr | name | syskey | sysvalue |
|---|---|---|---|---|
| 0 | System | System-Client | WAREHOUSE_NAME | NYWH |
| 0 | System | System-Client | MAXIMUM_RECEIVING_DURING_INBOUND | 1000 |

A `System-Client` (`id = 0`) exists. `WAREHOUSE_NAME` **is** seeded for it on
this tenant, so `{warehouse}` is not the null on HMG today — but the lookup that
reads it (`findSysvalueByClientIdAndSyskey`, which returns a bare `String`) has
no null guard, so it remains a live risk on any tenant missing the row.

> **Incidental finding, not the bug:** `MAXIMUM_RECEIVING_DURING_INBOUND = 1000`
> and the ticket's attempted quantity is 1,000. `ReceivingService:339` compares
> `amountCases > max`, so 1000 cases passes (`1000 > 1000` is false) and 1000
> bottles in cases of N passes comfortably. This guard is **not** the blocker,
> but it is one off-by-one away from being a second confusing failure for this
> exact quantity.

**The cheapest decisive evidence has not been collected, and it is sitting in the
ticket.** SBDEV-2729 carries one attachment —
`Ice Pack Receiving Workflow.webm` (7.7 MB, `screen-recording-2026-07-27-08:45`,
[direct link](https://t9006034209.p.clickup-attachments.com/t9006034209/69d5fbe7-8c05-42d5-9433-1c539e32790a/69d5fbe7-8c05-42d5-9433-1c539e32790a.webm)) —
and the ticket body itself says *"The exact property name and full stack trace
should be captured from backend logs."* Neither was done. Watching the clip, or
asking the reporter for the HMG backend log line from 2026-07-27, yields the
verbatim string in minutes and **either confirms or kills** the hypothesis in §2 —
whereas the DB query below depends on live-HMG access this plan flags as an open
dependency. Because the parameter name is deterministic per call site
(`replacement` for `String.replace`, `s` for `String.contains`), a single log line
is decisive. **Do this before the DB query and before any code.** See §7.2 step 0.

**What is NOT proven, and the one query the implementer must run first.**
The reachable HMG copy is stale — newest `advice.created` is 2026-01-09 while the
incident is 2026-07-27 — and it contains **no** system-owned itemdata
(`SELECT count(*) FROM itemdata WHERE client_id = 0` → 0) and no ICE PACK SKU.
`wms2-hydra-dev2` (newest advice 2026-05-26) and `wms2-hydra-v2t` (empty) are
likewise stale. The *mechanism* is proven; the *specific null column on the
reporter's row* is not. Before implementing, run this against the live HMG
database and paste the result into §16:

```sql
SELECT i.id, i.item_nr, i.name, i.client_id, c.cl_nr,
       i.winetype  IS NULL AS winetype_null,
       i.varietal  IS NULL AS varietal_null,
       i.bottle_size,
       i.defultype_id, i.defaultboxtype_id, i.putawaylocation_id,
       b.name IS NULL AS boxtype_name_null,
       (SELECT count(*) FROM los_sysprop s
         WHERE s.syskey = 'WAREHOUSE_NAME' AND s.client_id = 0
           AND s.sysvalue IS NOT NULL) AS warehouse_name_ok
FROM itemdata i
JOIN client c ON c.id = i.client_id
LEFT JOIN boxtype b ON b.id = i.defaultboxtype_id
WHERE i.item_nr ILIKE '%ICE%' OR i.name ILIKE '%ice pack%';
```

Expect exactly one of `winetype_null`, `boxtype_name_null` to be `true`, or
`warehouse_name_ok = 0`. **The fix in §5 covers all of them**, so a surprise here
changes nothing structural — but record which one it was, because it tells us
whether the upstream data hardening deferred in §0.4 row 29 should be re-opened.

---

## 2. Root Cause Analysis

### Bug 1 (PRIMARY) — `String.replace` is null-hostile, and four of its inputs are nullable columns

`v2/wms2-api/src/main/java/net/aim_ai/wms/service/SharedService.java:50-84`:

```java
public byte[] createCaseLabel(Unitload unitload, Stockunit stockunit, Advice advice,
                              Goodsreceipt goodsReceipt, String warehouseName) {

    String createdDate = unitload.getCreated().toLocalDate().format(DATE_FORMATTER);

    String caseLabelZpl = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_PRINTING_ZPL_CASE_LABEL_KEY);
    Itemdata itemdata = itemdataService.getById(stockunit.getItemdataId());
    Client client = clientRepository.findById(itemdata.getClientId()).orElseThrow(...);
    // For ULs created outside receiving (split/move/transfer), goodsReceipt may be null
    User operator;
    if (goodsReceipt != null) { ... } else { ... }
    Boxtype boxtype = boxtypeRepository.findById(unitload.getBoxtypeId()).orElseThrow(...);
    // ↑ §0.1 row 0: boxtype_id is NULLABLE and NULL on 80.1% of live ULs. findById(null)
    //   throws InvalidDataAccessApiUsageException — a SECOND, different live crash in
    //   this same method, reached via UnitloadService.reprintLabel Path 2. See §5 Fix A.

    caseLabelZpl = caseLabelZpl.replace("{warehouse}",     warehouseName);              // :68  nullable
    caseLabelZpl = caseLabelZpl.replace("{product_name}",  itemdata.getName());         // :69
    caseLabelZpl = caseLabelZpl.replace("{SKU}",           itemdata.getItemNr());       // :70
    caseLabelZpl = caseLabelZpl.replace("{shipper}",       client.getName());           // :71
    caseLabelZpl = caseLabelZpl.replace("{product_type}",  itemdata.getWinetype());     // :72  ← NULL for ICE PACK
    caseLabelZpl = caseLabelZpl.replace("{size}",          String.valueOf(itemdata.getBottleSize()));
    caseLabelZpl = caseLabelZpl.replace("{units}",         String.valueOf(stockunit.getAmount().intValue()));
    caseLabelZpl = caseLabelZpl.replace("{u_load}",        unitload.getLabelid());      // :75
    caseLabelZpl = caseLabelZpl.replace("{date}",          createdDate);                // :76
    String purchaseOrder = (advice != null) ? advice.getExternalid() : "N/A";           // :78  nullable even when advice != null
    caseLabelZpl = caseLabelZpl.replace("{purchase_order}", purchaseOrder);             // :79
    caseLabelZpl = caseLabelZpl.replace("{user}",          operator.getName());         // :80
    caseLabelZpl = caseLabelZpl.replace("{case_type}",     boxtype.getName());          // :81  nullable

    return caseLabelZpl.getBytes();
}
```

**Why it fails.** `String.replace(CharSequence target, CharSequence replacement)`
calls `replacement.toString()` on its first line. A null replacement therefore
throws `NullPointerException` before any substitution happens. Four of the
twelve replacement sources are nullable columns on the HMG schema
(`itemdata.winetype`, `advice.externalid`, `boxtype.name`,
`los_sysprop.sysvalue`); a fifth risk is the *receiver* `caseLabelZpl` itself
when the ZPL sysprop row is absent.

For the ICE PACK — a system SKU whose "wine type" is meaningless — `{product_type}`
at **line 72** is the site the reported message points at.

Note the near-miss on line 78: the author already anticipated a null `advice`
and defaulted to `"N/A"`, but not a null `externalid` *within* a non-null advice.
The same half-guard appears on `goodsReceipt`. The nullability was reasoned about
one level up from where it actually bites.

**Why the whole receive dies.** `createCaseLabel` is called from inside the
per-case loop of `ReceivingService.receiveGoods`, line 495:

```java
try {
     outputStream.write(sharedService.createCaseLabel(unitload, stockUnit, advice, goodsreceipt, warehouseName));
} catch (IOException e) {
    throw new FacadeException("adding to byte stream failed: " + e.getMessage());
}
```

The `catch` handles `IOException` only, so the NPE propagates out of a method
annotated
`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`.
An unchecked exception rolls the tenant transaction back **by default**,
discarding the `Unitload`, `Stockunit`, `Stockrecord` and `Goodsreceiptposition`
rows created earlier in the same iteration. Hence "Inventory is not successfully
created".

This also means the **label building is inside the transaction** even though the
label *printing* was deliberately deferred to `afterCommit` (lines 527-542). The
post-commit print decoupling protects against printer outages but not against
bad label *data* — a gap `sbdocs/3-Resources/workflows/wms2-receiving-putaway-workflow.md`
§4.4 does not currently mention (see §8.4 doc-drift note).

### Bug 2 — the raw NPE text is rendered to the warehouse operator

`controller/ReceivingController.java:257-260`:

```java
} catch (RuntimeException e) {
    LOG.error("Unexpected error during receive: {}", e.getMessage(), e);
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));   // ← raw JVM text into the response body
}
```

The endpoint returns **HTTP 200** with the exception's own message inside an
`errors` array, which the web UI renders verbatim. So the JVM's internal
diagnostic — including the elided variable name that made this ticket hard to
triage — becomes the operator-facing error. This is why the reporter could see
the message but not the field name: nothing logs the *business* context
(advice/BOL, SKU, warehouse, user) alongside it. The same pattern repeats on five
sibling endpoints in the same controller (§0.3 row 23).

This is an independent defect from Bug 1. Fixing Bug 1 removes *this*
occurrence; fixing Bug 2 ensures the next unforeseen runtime fault is
triageable instead of being pasted into a ticket with the key detail missing.

### Bug 3 — `findSysvalueByClientIdAndSyskey` returns a bare, unchecked `String`

`repo/jpa/SyspropRepository.java:46-48`:

```java
@RestResource(path = "findSysvalueByClientIdAndSyskey", rel = "findSysvalueByClientIdAndSyskey")
String findSysvalueByClientIdAndSyskey(@Param("clientId") Long clientId, @Param("syskey") String syskey);
```

Unlike its sibling `findBySyskeyAndClientId(...)` which returns
`Optional<Sysprop>`, this projection returns a raw `String` — **null when no row
matches**. Three callers feed the result straight into a label builder without
a check:

- `ReceivingService.java:429` → `warehouseName` → `SharedService:68`
- `UnitloadService.java:235` → `warehouseName` → `SharedService:68` (reprint path)
- `OrderMonitorViewService.java:153,163` → tote-label sequence/pattern

By contrast `StockunitService.java:269` and `:535` use the `Optional` variant
with `orElseThrow`, so a *missing row* is caught there — but a present row with a
NULL `sysvalue` still slips through, because `sysvalue` is a nullable column.
Either way the failure surfaces as a technical exception rather than an
actionable configuration message.

### 2.3 How the ICE PACK ended up with a NULL where 154 sibling SKUs have `''`

Both SKU write paths assign the incoming value with no coalescing:

`service/SkuBatchCreateUpdateService.java:57` (and `:72` on the update branch):

```java
itemData.setWinetype(sku.getWineType());     // no default — a payload without wineType persists NULL
```

`controller/FileImportController.java:375` does the same for CSV upload.

**And there is a third, more likely path for a hand-created system SKU.**
`ItemdataRepository` is annotated
`@RepositoryRestResource(collectionResourceRel = "itemdata", path = "itemdata")`
(`ItemdataRepository.java:18`) with **no `exported = false`**, so a Spring Data REST
`POST`/`PATCH` on `/v3/itemdata` can create an item with `winetype: null` directly —
no service code involved, no coalescing possible. For an ops person creating a
one-off ICE PACK system SKU by hand, that is the most plausible route of the three.
This is the same Spring-Data-REST exposure landmine already recorded for
`@RestResource` query methods elsewhere in this repo.

So a SKU whose source payload omits `wineType` — precisely the case for a
consumable like an ice pack — persists `winetype = NULL`, while SKUs that arrive
with an explicit empty string persist `''`. That is the difference between the
154 rows that receive fine today and the one that does not. Per §10 D4 this plan
does **not** change the write paths: NULL stays a legal value and every read site
is made to tolerate it.

---

## 3. The Regression Chain

The null-safety idiom this bug needs already exists in the codebase — the label
builders were simply missed by the sweep that introduced it.

| Commit | Date | What it did | Effect on this bug |
|---|---|---|---|
| `a685e07b` | initial checkin | `OrderMonitorViewService` tote-label builder ships with **every** token guarded: `x != null ? x : "N/A"` | The safe idiom is present from day one, in a *different* label builder |
| `a685e07b` | initial checkin | `ReceivingService` / `SharedService` case-label builder ships with **no** token guards | The defect is original, not a regression |
| `08010ba6` | — | "replace unsafe `Optional.get()` with `orElseThrow(EntityNotFoundException)`" — touched `SharedService` | Hardened *entity lookups* in this method; left the 12 `replace(...)` calls untouched |
| `a66805c` | — | "fix: Phase 5 complete — **null safety for all remaining 33 service files**" — 10 files, incl. `OrderMonitorViewService` (+27/−17) | **The miss.** `SharedService` and `StockunitService` are absent from this commit's file list, so the null-safety sweep never reached either case-label builder |
| `26f51d15` | — | itemdata application cache | Last touch to `SharedService`; unrelated |

`git show --stat a66805c | grep -E "SharedService|StockunitService"` → no match.
`git log --oneline -- .../SharedService.java` → `a66805c` absent.

So: not a regression, but a **known bug class with an in-repo fix already
applied elsewhere and two files skipped.** That is the strongest argument for
applying the guard uniformly rather than patching only line 72.

**On the ticket's `3-regression-recurrence` tag.** SBDEV-2729 is tagged as a
regression/recurrence, and this section concludes it is not one. Both can be true:
the *defect* is original (present since `a685e07b`, the initial check-in), but the
*bug class* is a recurrence — `a66805c` fixed exactly this pattern in
`OrderMonitorViewService` and skipped these two files. So the tag is right about
the pattern and wrong about the line. Worth saying out loud rather than silently
contradicting the triager.

---

## 4. Architecture Overview

```
POST /v3/receiving/receive
  │
  ├─ ReceivingController.receive():236                    [no @Transactional]
  │    ├─ printerRepository.findById(printerId)
  │    └─ receivingService.receiveGoods(...)
  │         │  @Transactional("tenantTransactionManager",
  │         │                 rollbackFor={BusinessException, FacadeException})
  │         │
  │         ├─ :315  printService.isPrintAvailable(printer.getAddress())
  │         ├─ :337  Integer.parseInt(getSysvalue(MAXIMUM_RECEIVING_DURING_INBOUND))
  │         ├─ :344  advicepositionRepository.findByIdForUpdate()   ← pessimistic lock
  │         ├─ :356  itemdataRepository.findById(...)               ← the ICE PACK row
  │         ├─ :429  syspropRepository.findSysvalueByClientIdAndSyskey(systemClient, WAREHOUSE_NAME)
  │         │            └─ returns bare String → may be null      [Bug 3]
  │         │
  │         └─ while (amountBottles > 0):                          ← per-case loop
  │              ├─ :471 unitloadService.createUnitload(...)        ← row written
  │              ├─ :473 stockunitBusinessService.createStockUnit() ← rows written
  │              ├─ :486 goodsreceiptpositionRepository.save(...)   ← row written
  │              ├─ :489 transferUnitLoadToLocation(...)            ← rows written
  │              └─ :495 sharedService.createCaseLabel(...)
  │                        └─ SharedService:72
  │                             caseLabelZpl.replace("{product_type}", itemdata.getWinetype())
  │                             └─ NULL ⇒ NullPointerException      [Bug 1]  ✗ ALL ROWS ROLLED BACK
  │
  └─ catch (RuntimeException e) → errors.add(..., e.getMessage())   [Bug 2]
       └─ HTTP 200 {"errors":[{"Runtime Error":"Cannot invoke \"java.lang.CharSequence.toString()\" ..."}]}
```

### Key files

| File | Lines | Role |
|---|---|---|
| `controller/ReceivingController.java` | 236-268 | `/receive` entry point; leaks raw runtime messages (Bug 2) |
| `service/ReceivingService.java` | 302-543 | `receiveGoods` — the tenant transaction; label built in-loop at :495 |
| `service/ReceivingService.java` | 429 | unchecked `warehouseName` lookup (Bug 3) |
| `service/SharedService.java` | 50-84 | `createCaseLabel` — 12 unguarded `String.replace` calls (Bug 1) |
| `service/SharedService.java` | 66 | `findById(unitload.getBoxtypeId())` — **second live crash**, `boxtype_id` NULL on 80.1% of ULs (§0.1 row 0) |
| `service/ReceivingService.java` | 429 | where the hoisted `warehouseName` `requireConfig` check belongs (§5 Fix A) |
| `service/StockunitService.java` | 544-589 | two sibling label builders with the same chain |
| `service/StockunitService.java` | 591-598 | `getBoxTypeNameFromUnitLoad` — **the correct pattern already** |
| `service/OrderMonitorViewService.java` | 242-254 | tote label — **the correct pattern already**; line 262 is the one gap |
| `service/UnitloadService.java` | 216-256 | `reprintLabel` → second caller of `createCaseLabel` |
| `repo/jpa/SyspropRepository.java` | 46-48 | null-returning `String` projection (Bug 3) |
| `resources/messages_en_US.properties` | 311-316 | 337 existing message keys; **one** to add |

---

## 5. Fix Design

Guiding decisions (§10): optional descriptive tokens degrade to **blank**;
genuinely-required configuration **fails fast with an actionable message**;
**v2 only**; **no data migration**.

### Fix A — null-safe token substitution + fail-fast config check in `SharedService.createCaseLabel`

Two distinct classes of input, handled differently.

**Before** (`service/SharedService.java:50-84`, abridged):

```java
public byte[] createCaseLabel(Unitload unitload, Stockunit stockunit, Advice advice,
                              Goodsreceipt goodsReceipt, String warehouseName) {
    ...
    String caseLabelZpl = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_PRINTING_ZPL_CASE_LABEL_KEY);
    ...
    caseLabelZpl = caseLabelZpl.replace("{warehouse}", warehouseName);
    caseLabelZpl = caseLabelZpl.replace("{product_name}", itemdata.getName());
    caseLabelZpl = caseLabelZpl.replace("{SKU}", itemdata.getItemNr());
    caseLabelZpl = caseLabelZpl.replace("{shipper}", client.getName());
    caseLabelZpl = caseLabelZpl.replace("{product_type}", itemdata.getWinetype());
    ...
    caseLabelZpl = caseLabelZpl.replace("{purchase_order}", purchaseOrder);
    caseLabelZpl = caseLabelZpl.replace("{user}", operator.getName());
    caseLabelZpl = caseLabelZpl.replace("{case_type}", boxtype.getName());

    return caseLabelZpl.getBytes();
}
```

**After:**

```java
public byte[] createCaseLabel(Unitload unitload, Stockunit stockunit, Advice advice,
                              Goodsreceipt goodsReceipt, String warehouseName)
        throws BusinessException {
    ...
    // Required tenant configuration — a missing template or warehouse name is an
    // administrator problem, not something to paper over on a printed label.
    String caseLabelZpl = requireConfig(
            syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_PRINTING_ZPL_CASE_LABEL_KEY),
            WmsConstants.SYSTEM_PROPERTY_PRINTING_ZPL_CASE_LABEL_KEY);
    String warehouse = requireConfig(warehouseName, WmsConstants.SYSTEM_PROPERTY_WAREHOUSE_NAME_KEY);
    ...
    // Optional descriptive fields — a system SKU legitimately has no wine type,
    // purchase order or box-type name. Substitute blank; never abort the receive.
    caseLabelZpl = caseLabelZpl.replace("{warehouse}",      warehouse);
    caseLabelZpl = caseLabelZpl.replace("{product_name}",   nullToEmpty(itemdata.getName()));
    caseLabelZpl = caseLabelZpl.replace("{SKU}",            nullToEmpty(itemdata.getItemNr()));
    caseLabelZpl = caseLabelZpl.replace("{shipper}",        nullToEmpty(client.getName()));
    caseLabelZpl = caseLabelZpl.replace("{product_type}",   nullToEmpty(itemdata.getWinetype()));
    caseLabelZpl = caseLabelZpl.replace("{size}",           String.valueOf(itemdata.getBottleSize()));
    caseLabelZpl = caseLabelZpl.replace("{units}",          String.valueOf(stockunit.getAmount().intValue()));
    caseLabelZpl = caseLabelZpl.replace("{u_load}",         nullToEmpty(unitload.getLabelid()));
    caseLabelZpl = caseLabelZpl.replace("{date}",           createdDate);
    // ONE fallback per token. An earlier draft kept "N/A" for a null advice and ALSO
    // wrapped it in nullToEmpty(), so {purchase_order} printed "N/A" when advice was
    // null but "" when advice existed with a null externalid — two fallbacks for one
    // token in one method. Collapse to a single blank.
    String purchaseOrder = (advice != null) ? advice.getExternalid() : null;
    caseLabelZpl = caseLabelZpl.replace("{purchase_order}", nullToEmpty(purchaseOrder));
    caseLabelZpl = caseLabelZpl.replace("{user}",           nullToEmpty(operator.getName()));
    caseLabelZpl = caseLabelZpl.replace("{case_type}",      caseTypeName);   // see boxtype guard below

    return caseLabelZpl.getBytes();
}
```

New helpers — both **`static` and package-private** in `SharedService`, called
statically from `StockunitService` (both classes are in `net.aim_ai.wms.service`).

No bean wiring is involved and there is no cycle to worry about: `SharedService`
is **already** a constructor dependency of `StockunitService`
(`StockunitService.java:64` field, `:94` constructor parameter). Since the helpers
are `static`, not even that injection is needed. Do **not** duplicate them as
private statics in both classes.

```java
/** Optional label field: null becomes blank so String.replace cannot throw. */
static String nullToEmpty(String value) {
    return value == null ? "" : value;
}

/**
 * Required tenant configuration. Missing config is an administrator problem and
 * must surface as an actionable BusinessException, not a JVM NullPointerException.
 *
 * MUST be package-private (not private): Fix B calls it from StockunitService,
 * which is in the same package. Declaring it `private` is a guaranteed compile break.
 */
static String requireConfig(String value, String syskey) throws BusinessException {
    if (value == null || value.isBlank()) {
        throw new BusinessException("BusinessException.MissingReceivingConfiguration", syskey);
    }
    return value;
}
```

New message key — added to **both** bundles, with the **same** key the code throws:

```properties
# src/main/resources/messages_en_US.properties  AND  src/main/resources/messages.properties (NEW FILE)
BusinessException.MissingReceivingConfiguration=Receiving is not configured for this warehouse (%1$s). Please contact an administrator.
```

**Three deliberate choices, each correcting an earlier draft of this plan:**

1. **The message names the WAREHOUSE, not the SKU.** An earlier draft read "The
   selected SKU is missing required receiving configuration" — but the config that
   can be missing (`WAREHOUSE_NAME`, `PRINTING_ZPL_CASE_LABEL`) is
   **tenant/warehouse-scoped**, seeded against `client_id = 0`. Blaming the SKU
   would send the administrator to the item record hunting for a field that does not
   exist there. Verify check `M2` enforces this by *rejecting* any wording that
   blames a SKU.

2. **`src/main/resources/messages.properties` must be created.** Today only
   `messages_en_US.properties` exists, and `BusinessException.resolveMessage`
   (`BusinessException.java:79`) calls
   `ResourceBundle.getBundle("messages", Locale.getDefault())`. With no base bundle,
   resolution succeeds **only** when the JVM default locale is exactly `en_US`; under
   `en`, `en_GB` or `de_DE` it throws `MissingResourceException` and falls back to
   `concatenateKeyAndParameter`, so the operator would see the raw
   `BusinessException.MissingReceivingConfiguration, 'WAREHOUSE_NAME'` — violating the very
   AC ("raw Java exceptions are not displayed to users") that Fix D exists to
   satisfy.

   **Scope of that fix, stated honestly:** this plan adds the base bundle and puts
   **one** key in it. The other 337 keys still degrade to raw keys under a
   non-`en_US` locale. That is a pre-existing, repo-wide defect and is deliberately
   *not* fixed here — the alternative (copy all 337 and make `messages_en_US` an
   override) is a bigger change than an urgent receiving fix should carry. Recorded
   as a follow-up in §14 so the §14 row is not read as "the class of problem is
   solved".

3. **Key naming follows the `BusinessException.*` convention** already used by
   `INVALID_SYSPROP_VALUE = "BusinessException.InvalidSyspropValue"`
   (`BusinessException.java:22`), and `%1$s` is the bundle's dominant positional
   form (110 uses vs 22 bare `%1s`). `resolveMessage` passes the syskey through
   `String.format(message, parameter)`, so both forms work at runtime; the check
   `M3` accepts either.

**Also guard the boxtype lookup at line 66 — a separate live crash in the same method.**
`unitload.boxtype_id` is nullable, and `findById(null)` throws
`InvalidDataAccessApiUsageException`, which is neither an NPE nor an
`EntityNotFoundException`:

```java
// Before — SharedService.java:66. Throws when boxtype_id IS NULL.
Boxtype boxtype = boxtypeRepository.findById(unitload.getBoxtypeId())
        .orElseThrow(() -> new EntityNotFoundException("BoxType", unitload.getBoxtypeId()));
...
caseLabelZpl = caseLabelZpl.replace("{case_type}", boxtype.getName());   // ← and this NPEs on a null name

// After — mirror the already-correct idiom at StockunitService.java:591-598.
String caseTypeName = unitload.getBoxtypeId() == null
        ? ""
        : boxtypeRepository.findById(unitload.getBoxtypeId()).map(Boxtype::getName).orElse("");
...
caseLabelZpl = caseLabelZpl.replace("{case_type}", caseTypeName);
```

**One error path is deliberately given up here.** Replacing `orElseThrow` with
`.map(Boxtype::getName).orElse("")` means a *dangling FK* — `boxtype_id` set but the
`boxtype` row missing — now yields a blank `{case_type}` instead of an
operator-visible `EntityNotFoundException`. That is the right trade (a dangling FK
should not block a receive, and it mirrors `getBoxTypeNameFromUnitLoad`), but it is
a real loss and is recorded rather than dropped silently.

**Why this is not optional.** Measured on the HMG copy:

| Metric | Value |
|---|---|
| Unit loads total | 13,381 |
| `boxtype_id IS NULL` | **10,718 (80.1%)** |
| …of those: `entity_lock = 0`, stock-bearing, **no** `goodsreceiptposition` | **281** |

That last row is precisely `UnitloadService.reprintLabel` **Path 2** (`:254`) — the
path Fix E already modifies. `UnitLoadController:70-72` catches only
`FacadeException`, so those 281 unit loads produce an HTTP 500 with a raw stack
trace **today**. The receive path itself is safe (`boxTypeId` arrives on the
request and is resolved at `ReceivingService.java:351`), which is why this presents
as a different symptom and is not the reported bug.

This is the same `findById(null)` bug class §0.4 row 26 explicitly hunted and
correctly ruled out for `putawaylocation_id` (NOT NULL) — the lens was right, it
was simply never pointed at the nullable column ten lines above the fix. Shipping
Fix A without this would mean the PR rewrites the crashing method, adds a manual
test for the crashing path, and leaves the crash in place.

**Hoist the `warehouseName` check to the caller — the in-method one is too late.**
`createCaseLabel` is invoked at `ReceivingService.java:495`, i.e. **inside** the
per-case loop, after the first `Unitload`, `Stockunit`, `Stockrecord` and
`Goodsreceiptposition` rows and the stock move have already been written. But
`warehouseName` is fetched **before** the loop, at `ReceivingService.java:429`. So a
check that lives only inside `createCaseLabel` writes N rows and *then* rolls back
— which is not "fail fast" in any useful sense. Add the guard at the fetch site:

```java
// ReceivingService.java:429 — validate before entering the per-case loop
String warehouseName = SharedService.requireConfig(
        syspropRepository.findSysvalueByClientIdAndSyskey(
                clientService.getSystemClient().getId(),
                WmsConstants.SYSTEM_PROPERTY_WAREHOUSE_NAME_KEY),
        WmsConstants.SYSTEM_PROPERTY_WAREHOUSE_NAME_KEY);
```

Keep the in-method `requireConfig` as defence-in-depth for the other two callers
(`UnitloadService.reprintLabel`, and `StockunitService` via Fix B).

**Why this and not the alternatives.**

- *Guard only line 72.* Rejected. Three other proven-nullable columns feed the
  same chain (`advice.externalid`, `boxtype.name`, `sysvalue`), so a
  single-line patch leaves three live NPEs behind — exactly the failure mode
  `a66805c` already produced once by sweeping 10 files and missing these two.
- *`Objects.toString(x, "")` inline.* Equivalent behaviour and no new helper,
  but 12 call sites × a nested call reads worse than a named `nullToEmpty`, and
  a named helper is greppable for the verify script.
- *Switch to `String.format` / `StringSubstitutor`.* `%s` is null-tolerant, but
  rewriting a ZPL template that contains `%` control sequences and is
  tenant-editable via sysprop is a far larger blast radius than a null guard.
  Rejected as disproportionate.
- *Reuse `"N/A"` everywhere (the `OrderMonitorViewService` idiom).* Rejected per
  §10 D1: printing `N/A` under a `PRODUCT TYPE` heading on a physical ice-pack
  case label is misleading noise; blank leaves the heading with no value.
- *Degrade the warehouse name too.* Rejected per §10 D2: a case label with no
  warehouse identity is a traceability defect, and a missing `WAREHOUSE_NAME`
  sysprop is a real misconfiguration an operator should escalate.

### Fix B — same treatment for both `StockunitService` label builders

`service/StockunitService.java:544-567` (`createCaseLabel`) and `:569-589`
(`createCaseLabelMultiStock`): apply `requireConfig` to the ZPL template and
`warehouseName`, and `nullToEmpty` to `itemData.getName()`, `getItemNr()`,
`client.getName()`, `getWinetype()`, `unitLoad.getLabelid()` and `clientName`.

Leave `getBoxTypeNameFromUnitLoad` (`:591-598`) **unchanged** — it is already
correct, and its `"*"` return value is the established marker for
"unknown/aggregate" in this file. Do not homogenise it to blank.

Both methods gain `throws BusinessException`. **See Fix E's cascade table for the
authoritative list** — an earlier draft of this paragraph claimed
`StockunitService:274, 287, 536` "must propagate", which is wrong: `:274`/`:287` are
inside `transferStock` (`:150`), which already declares
`throws BusinessException, FacadeException`, and `:536` is inside `printLabel`
(`:532`), whose sole caller `setLockDamaged` (`:360`) already declares it. The net
change in this file is **one** signature — `printLabel` at `:532`.

**Introduce a `warehouse` local in both builders** rather than reassigning
`warehouseName` in place. Checks `A18`/`B3` tolerate either idiom, but the repo-wide
sweep `S2` exempts `warehouse)` and *not* `warehouseName)`, so the reassignment form
trips it. This surfaced when the architect implemented the plan end-to-end; recorded
so the next implementer doesn't rediscover it.

Confirm with `mvn clean compile`.

### Fix C — guard `{lane_id}` in `OrderMonitorViewService`

`service/OrderMonitorViewService.java:262` is the single unguarded token in an
otherwise fully-guarded builder:

```java
// Before
s = s.replace("{lane_id}", automationLane.getName());
// After
s = s.replace("{lane_id}", automationLane.getName() != null ? automationLane.getName() : "N/A");
```

**And the half-guard at line 247**, which the first draft of this plan wrongly
filed as "already guarded":

```java
// Before — guards the OBJECT, not the VALUE
s = s.replace("{carrier_code}", shipperID != null ? shipperID.getExternalid() : "N/A");
// After — KEEP THIS ON ONE LINE: check C4 is line-based and cannot match a wrapped ternary.
s = s.replace("{carrier_code}", shipperID != null && shipperID.getExternalid() != null ? shipperID.getExternalid() : "N/A");
```

This is the *identical* defect this plan names at `SharedService.java:78` — the
nullability was reasoned about one level up from where it bites.
`shipperid.externalid` is `NOT NULL`, so like `{lane_id}` it is latent-only.

Use `"N/A"` for both, **not** blank — this file's other 12 tokens all use `"N/A"`
and internal consistency within one builder matters more than cross-file
uniformity. Both are in scope because leaving an unguarded (or half-guarded) token
in a builder everyone believes is "fully guarded" is precisely how `a66805c`
skipped these files in the first place.

### Fix D — stop leaking raw runtime messages; log the business context instead

`controller/ReceivingController.java`. For the `/receive` endpoint (:257-260):

```java
// Before
} catch (RuntimeException e) {
    LOG.error("Unexpected error during receive: {}", e.getMessage(), e);
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));
}

// After
} catch (RuntimeException e) {
    LOG.error("Unexpected error during receive: advicePositionId={} carrierUnitloadId={} amountBottles={} "
            + "amountBottlesPerCase={} amountCases={} boxTypeId={} printerId={} user={} facility={} payload={}",
            advicePositionId, carrierUnitloadId, amountBottles, amountBottlesPerCase, amountCases,
            boxTypeId, printerId, SecurityContextUtils.getUserName(),
            TenantContext.getCurrentTenant() != null ? TenantContext.getCurrentTenant().getFacilityCode() : null,
            reqMap, e);
    errors.add(getErrorMessage("Runtime Error",
            "Receiving failed due to an unexpected internal error. Please contact support."));
}
```

Apply the same substitution — context-rich `LOG.error` in, generic message out —
to the five sibling `catch (RuntimeException e)` blocks at :84-87, :128-131,
:164-167, :191-194 and :221-224, using each endpoint's own parameters.

**Critical: add an `EntityNotFoundException` catch FIRST, in all six blocks.**
`EntityNotFoundException extends RuntimeException` (`exceptions/EntityNotFoundException.java:7`),
and it is thrown ~12 times on the `/receive` path with genuinely useful operator
text — `ReceivingController.java:251` yields "Printer not found with id: 5", and
`SharedService.java:56,60,64,66` name the missing Client / User / BoxType. Today
`catch (RuntimeException)` surfaces those messages. Replacing that catch wholesale
with a generic sentence would **regress six endpoints** from an actionable message
to "an unexpected internal error". So:

```java
} catch (EntityNotFoundException e) {
    // Actionable, already operator-readable — keep surfacing it.
    errors.add(getErrorMessage("Runtime Error", e.getMessage()));
} catch (RuntimeException e) {
    LOG.error("Unexpected error during receive: ...", ..., e);
    errors.add(getErrorMessage("Runtime Error",
            "Receiving failed due to an unexpected internal error. Please contact support."));
}
```

Leave the `catch (BusinessException e)` / `catch (FacadeException e)` blocks
**untouched**: those messages are already resolved through the message bundle and
are intended for operators. That is what makes Fix A's `BusinessException` reach
the user as the actionable sentence the ticket asks for.

**The ticket asks for BOL ID and SKU in the log, and the controller cannot supply
them.** SBDEV-2729's Error Handling section requires the failure log to carry
*Inbound BOL ID, SKU, warehouse, user, request payload, exception, timestamp*.
`ReceivingController` holds only an `advicePositionId` — it never resolves the
advice or the itemdata, so the controller catch **cannot** satisfy this AC. Add a
second, richer log inside the service where both are already in scope:

```java
// ReceivingService.receiveGoods — WRAP THE `while` LOOP ONLY (:459-499).
// Do NOT extend the try past the loop: the TransactionSynchronization print-hook
// registration at :532 must stay outside it, or a rethrow could skip or duplicate it.
try {
    while (amountBottles > 0) {
        ...   // unchanged loop body, including the existing catch (IOException) at :494-498
    }
} catch (RuntimeException | BusinessException | FacadeException e) {
    LOG.error("receiveGoods failed: adviceId={} adviceNumber={} deliveryNoteNumber={} "
            + "advicePositionId={} sku={} itemdataId={} clientId={} amountBottles={} user={}",
            advice.getId(), advice.getNumber(), advice.getDeliverynotenumber(),
            adviceposition.getId(), itemdata.getItemNr(), itemdata.getId(),
            client.getId(), originalAmountBottles, SecurityContextUtils.getUserName(), e);
    throw e;   // rethrow UNCHANGED — rollback semantics must not shift
}
```

**Why each part is the way it is** (all five locals verified in scope before the
loop: `originalAmountBottles`:323, `adviceposition`:344, `itemdata`:356,
`advice`:362, `client`:369):

- **`advice.getDeliverynotenumber()` is the inbound BOL number** —
  `ReceivingService.java:209` sets it from `bolNumber`.
- **`BusinessException` and `FacadeException` are caught too, not just
  `RuntimeException`.** Catching only the unchecked case would leave Fix A's own
  `requireConfig` failure — the single failure this AC most wants logged with
  context — with no context log at all.
- **`throw e` re-propagates the identical exception object**, so Spring sees the
  original type: unchecked → rollback by default; `BusinessException` /
  `FacadeException` → rollback via the existing `rollbackFor`. Semantics are
  unchanged, which is the point.
- **No interaction with the existing `catch (IOException)` at :494-498** — that sits
  *inside* the loop and converts to a checked `FacadeException`, which this wrapper
  then logs and rethrows.

The controller-level log remains the outer net for failures before the service is
entered (e.g. the `printerRepository.findById` at `:251`).

`TenantContext.getCurrentTenant().getFacilityCode()` is confirmed to exist and is
used exactly this way in `SyspropService.java:53,95,288,303` cache keys, so no
hedge is needed. The advice/SKU/quantity context is the part that was actually
missing from this ticket.

### Fix F — `getSysvalue` must not cache a null

`service/SyspropService.java:288-291` is `@Cacheable("sysprops")` with no `unless`
clause, so a missing or NULL sysprop is cached **as null** per tenant+key. Fix A's
fail-fast then keeps firing after an administrator seeds the row **by direct SQL**,
until cache eviction or a restart — making a correct fix look broken. A UI edit is
already safe (`setSysvalue` / `createSystemProperty` carry `@CacheEvict`).

```java
// Before
@Cacheable(value = "sysprops", key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':' + #key")
public String getSysvalue(String key) { ... }

// After
@Cacheable(value = "sysprops", unless = "#result == null",
           key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':' + #key")
public String getSysvalue(String key) { ... }
```

Asserted by verify check `M7`. Belongs in **PR1** — without it, the §8.4 rows that
null a sysprop and restore it afterwards cannot be re-run without a restart.

### Fix E — checked-exception propagation

`createCaseLabel` becoming `throws BusinessException` requires:

The complete set is **5 signatures + 1 catch** — the first draft of this table
mis-scoped the `StockunitService` row:

| # | Site | File:line | Change |
|---|---|---|---|
| 1 | `SharedService.createCaseLabel` | `SharedService.java:50` | add `throws BusinessException` |
| 2 | `StockunitService.createCaseLabel` | `StockunitService.java:544` | add `throws BusinessException` |
| 3 | `StockunitService.createCaseLabelMultiStock` | `StockunitService.java:569` | add `throws BusinessException` |
| 4 | `StockunitService.printLabel` (**private**) | `StockunitService.java:532` | currently `throws FacadeException` → add `BusinessException` |
| 5 | `UnitloadService.reprintLabel` | `UnitloadService.java:216` | currently `throws FacadeException` → add `BusinessException` |
| 6 | `UnitLoadController.reprintLabel` | `UnitLoadController.java:70-72` | add `catch (BusinessException e) { errors.add(getErrorMessage("Runtime Error", e.getMessage())); }` before the existing `FacadeException` catch |

**Corrections to the first draft.** The old row "`StockunitService.java:274, 287,
536` → propagate" was wrong on two counts: `:274` and `:287` sit inside
`transferStock` (`:150`), which **already** declares
`throws BusinessException, FacadeException`, so they need no change; and `:536` is
inside `printLabel`, whose sole caller `setLockDamaged` (`:360`) already declares
it. Net effect in that class is one signature (`printLabel`), not three sites.
`receiveGoods` (`:302`) already declares both, and the `catch (IOException)` at
`ReceivingService.java:494-498` is unaffected.

**Two operator-hostile bare throws are left in place, deliberately.**
`UnitloadService.reprintLabel:218` and `:228` throw raw `RuntimeException`
("Cannot reprint label for unitload=X. UL is not active (entityLock=2)"), and
`UnitLoadController` catches only `FacadeException` → HTTP 500 with a stack trace.
Fix D's philosophy applies, and Fix E touches this very method. Left out to keep
PR1 tight; folded into PR2 only if the reviewer wants it, otherwise its own ticket.

`UnitloadService.reprintLabel` has exactly one caller — `UnitLoadController:70`.
The `:91`/`:121`/`:154` grep hits are copy-pasted `LOG.debug` strings inside
*delete* endpoints, not calls. Neither service implements an interface, and adding
`throws` to a public method on a CGLIB-proxied bean is fine, so there are no
override or proxy constraints.

**The test cascade is already clear — for COMPILATION only.** This paragraph is about
signatures, not assertions. **Seven existing tests assert the old behaviour and must be
migrated — see §8.1 and §8.3.** Three review passes read this paragraph as "the existing
tests are fine" and missed those seven; do not repeat that. On compilation alone, every
existing test that calls or stubs `createCaseLabel` *already* declares
`throws BusinessException`:
`SharedServiceUnitTest.java:147,208,255`; `StockunitServiceUnitTest.java:118` plus
all four `createCaseLabel*` methods; `UnitloadServiceUnitTest.java:718,739,763,776,789,808,829`;
`ReceivingServiceUnitTest.java:549`. So no test signature churn is expected —
`mvn clean compile` remains the authority.

---

## 6. File Change Summary

| File | Change type | Description |
|---|---|---|
| `service/SharedService.java` | modify | Add `nullToEmpty` + `requireConfig` helpers; guard 8 optional tokens; **guard the `boxtype_id` lookup at `:66` (§0.1 row 0)**; fail fast on ZPL template + warehouse name; `throws BusinessException` |
| `service/StockunitService.java` | modify | Same treatment for `createCaseLabel` (:544) and `createCaseLabelMultiStock` (:569); propagate `throws BusinessException` |
| `service/OrderMonitorViewService.java` | modify | Guard `{lane_id}` at `:262` **and the `{carrier_code}` half-guard at `:247`** with the file-local `"N/A"` idiom |
| `service/UnitloadService.java` | modify | `reprintLabel` gains `throws BusinessException` |
| `controller/ReceivingController.java` | modify | 6 `catch (RuntimeException)` blocks: context-rich log, generic user message |
| `controller/UnitLoadController.java` | modify | Add `catch (BusinessException e)` to `reprintLabel` |
| `service/ReceivingService.java` | modify | Hoist the `warehouseName` `requireConfig` check to `:429` (before the per-case loop); wrap the `while` loop with the business-context `LOG.error` + rethrow (§5 Fix D) |
| `resources/messages_en_US.properties` | modify | Add the `BusinessException.MissingReceivingConfiguration` key |
| `resources/messages.properties` | **add** | New base bundle so `ResourceBundle.getBundle("messages", …)` resolves under any locale, not only `en_US` |
| `service/SyspropService.java` | modify | Add `unless = "#result == null"` to `getSysvalue`'s `@Cacheable` so a cached null cannot outlive an admin's sysprop fix |
| `test/.../unit/service/SharedServiceUnitTest.java` | modify | Extend the existing `@Nested CreateCaseLabel` class with null-token cases |
| `test/.../unit/service/StockunitServiceUnitTest.java` | modify | Null-token cases for both builders |
| `test/.../unit/controller/ReceivingControllerUnitTest.java` | modify | Assert the raw exception text is not echoed |
| `sbdocs/9-System/scripts/verify-SBDEV-2729-system-sku-receiving-null-label-token.sh` | add | Machine-checkable acceptance |

**No Flyway migration. No schema change. No sysprop addition. No API contract change.**

---

## 7. Implementation Steps

### 7.1 Prerequisites

| Category | Required? | Detail |
|---|---|---|
| **Verbatim error string (step 0)** | **YES — BLOCKING** | Obtain the exact NPE text from the ticket's `Ice Pack Receiving Workflow.webm` attachment and/or the HMG backend log for 2026-07-27 ~08:45, and record it in §16 **before any code**. The parameter name identifies the call site uniquely (`replacement` ⇒ `String.replace`, this plan's hypothesis). If it does not name `replacement`, **stop and re-open §2**. This is the cheapest decisive evidence and it outranks the DB row below. |
| DB state | **Yes** | Run the §1.4 "one query the implementer must run first" against the **live HMG** database and paste the result into §16. It confirms which nullable column is actually populated as NULL on the reporter's row. |
| Feature flags | N/A | Pure null-safety hardening; a toggle would leave the NPE reachable, which is the thing being removed. |
| System properties | **Read-only dependency** | `PRINTING_ZPL_CASE_LABEL` and `WAREHOUSE_NAME` (client_id 0) must exist per tenant — after Fix A their absence becomes an actionable `BusinessException` instead of an NPE. Confirm both are seeded on HMG before deploy (query 4, §1.4, shows they are on the copy checked). |
| Config / env | N/A | None. |
| Deploy order | **API only** | No UI change required. The web UI already renders whatever is in `errors[]`; it will simply show the new sentence. |
| Data migration | N/A | Explicitly excluded (§10 D4). NULL remains legal. |
| External systems | N/A | No OMS contract change; the stock-change message at `ReceivingService:523` is unaffected. |
| Access | **Yes** | Live HMG DB read access for the prerequisite query (the reachable UAT copy is stale). |
| Monitoring | **Yes** | After deploy, grep application logs for `BusinessException.MissingReceivingConfiguration` and for `Unexpected error during receive:` — the latter now carries advice/SKU/warehouse/user context. |
| **Branch hygiene** | **Yes** | As of 2026-07-28 the `wms2-api` working tree sits on the **`feature/SBDEV-2736-oms-response-classifier`** branch, which is **not** yet on `develop` and is **actively moving** — this plan has quoted three different HEAD SHAs across three revisions, so no SHA is recorded here on purpose. Check `git log --oneline -1` yourself. **Branch this work off `develop`, not off that branch**, and do not sweep that file into an SBDEV-2729 commit. No file overlap exists between the two tickets. |
| **Orphan `goodsreceipt` headers from failed retries** | **Yes — check before deploy** | `receiveGoods` creates the `Goodsreceipt` **header** on first receive (`:405-414`) before the per-case loop that throws, so the rollback should remove it — but the plan asserts clean rollback without proving it, and the operator retried this receive an unknown number of times. Run on HMG before and after deploy: `SELECT g.id, g.number, g.advice_id, g.created FROM goodsreceipt g WHERE NOT EXISTS (SELECT 1 FROM goodsreceiptposition p WHERE p.goodsreceipt_id = g.id) ORDER BY g.created DESC LIMIT 50;` A pre-existing orphan set would mean rollback is *not* clean and needs its own ticket. |
| **Flyway version** | **N/A — but note** | This plan adds no migration. If §10 D4 is ever re-opened, the next free version is **V2.2.06** — `V2.2.05` is already claimed by the in-flight SBDEV-2736 branch above (not yet on `develop`). |

### 7.2 Ordered steps — split into two PRs

Critic review judged the 5-fix bundle "defensible but mis-sequenced for an urgent
blocker". Both halves are already independently committable, so ship them
separately and get the operator unblocked on PR1:

**PR1 — urgent, unblocks HMG receiving.** Prerequisite step 0 · Fix A (incl. the
§0.1 row 0 boxtype guard and the hoisted `warehouseName` check) · Fix E ·
the message key + new base `messages.properties` · `getSysvalue`
`unless = "#result == null"` · Fix D **for `/receive` only** (with its
`EntityNotFoundException` catch and the service-level context log).

**PR2 — hardening, no operator waiting on it.** Fix B (both `StockunitService`
builders) · Fix C (`{lane_id}` and `{carrier_code}` — both latent-only, since
`location.name` and `shipperid.externalid` are NOT NULL) · Fix D for the five
sibling endpoints.

Nothing in §9 is dropped by the split.

**PR1 acceptance subset — the gate for PR1 is `0 fail` among exactly these:**

```
A0 A0b A1 A2 A2b A3 A4 A5 A6 A9 A10 A11 A12 A13 A14 A15 A16 A17 A18 A19 A20 A21
A7 A8            (the {case_type} pair — caseTypeName comes from the row-0 guard)
E1 E2            (checked-exception propagation)
M1 M1b M2 M3     (message key, base bundle, wording, placeholder)
M7               (getSysvalue must not cache null — Fix F)
D2 D3 D7 D7b     (generic message, business-context log, service-level log + its unchanged rethrow)
T1 T2 T3 T4      (touched test classes still pass)
```

**Deliberately EXCLUDED from PR1's gate** — these cannot pass until PR2:
`B1`–`B12` (both `StockunitService` builders), `C1`–`C5` (`{lane_id}` +
`{carrier_code}`), `D1`/`D4`/`D5`/`D6` (all six controller catches; PR1 converts only
`/receive`), `S1`/`S2` (repo-wide sweeps that still see PR2's raw sites).

**PR2's gate is the whole script: `Result: N pass, 0 fail`.** When pasting a result
line into §16, state which PR's subset it refers to — a raw `0 fail` claim on PR1 is
either wrong or means PR2 was silently included.

Each step below is independently committable.

0. **Get the verbatim error string — BLOCKING, minutes of work.** Watch the
   ticket's attached `Ice Pack Receiving Workflow.webm` and/or pull the HMG backend
   log line for 2026-07-27 ~08:45. Record the full message and stack frame in §16.
   The parameter name identifies the call site uniquely: `replacement` ⇒
   `String.replace` (this plan's hypothesis, §2 Bug 1); `s` ⇒ `String.contains`
   (§1.2, no occurrence on the receiving path — would mean the analysis is wrong);
   `Cannot invoke "String.replace(...)"` ⇒ a null *receiver*, i.e. a missing ZPL
   sysprop (§0.1 row 1, currently classified hardening-only). **If the string does
   not name `replacement`, stop and re-open §2 before writing code.**

1. **Baseline the verify script** (already captured 2026-07-28 on `develop`-equivalent code):

   ```
   Result: 11 pass, 51 fail, 3 skip
   ```

   (Revision 1: `9 pass, 38 fail, 3 skip`. Revision 2 added `A2b`/`B10`/`B11`/`C4`/`C5`/`D6`
   and fixed 4 defective checks. Revision 3 added `A0`/`A0b` (boxtype crash), `B12`,
   `M1b` (base bundle), `S2` (bare-variable sweep), `M7` (cached null) and fixed 6 more —
   including `D1` **twice**: `-A4` was too narrow, and the awk block-matcher that replaced
   it exited on its own first line because `} catch (...) {` nets zero braces. Both
   versions false-passed. The current one is adversarially tested against a half-done
   Fix D and correctly reports the leak.)

   The 51 failures are the work. The 11 passes are deliberate **regression guards**, not
   completed work — `B8`/`B9` assert `getBoxTypeNameFromUnitLoad` keeps returning `"*"`,
   `C3` asserts the pre-existing `OrderMonitorViewService` guards survive, `B12` asserts
   the `"*"` markers that mean "multiple differing values" survive, `D4`/`D5` assert the
   controller keeps its 6 catch blocks and keeps echoing `BusinessException` messages,
   `T1`–`T4` assert the four touched test classes pass today, and `A2b` passes vacuously
   today (nothing named `requireConfig` exists yet) but becomes a real compile-break
   guard the moment Fix A lands. If any of the other ten flips to FAIL during
   implementation, something was broken that should not have been.

   **`T1`–`T4` are flaky while another branch is being edited.** During revision-3
   authoring `T1` flipped FAIL then PASS with no change to its own code, because a
   concurrent session was modifying SBDEV-2736 files in the same working tree. Re-run
   a `T*` failure standalone before believing it.

   **Two known soft spots in the script**, recorded rather than papered over: `C3` and
   `D4` use `-ge`, so neither can detect a simultaneous one-removed / one-added edit;
   and `D3` is satisfied by the `LOG.error` format *string* alone, not by the argument
   list actually being passed. Both are acceptable for a grep harness — the §8.3
   controller tests are what actually prove behaviour.
2. **Run the prerequisite DB query** (§1.4) against live HMG; paste into §16.
#### PR1 — urgent (unblocks HMG receiving)

3. **Message bundle, both files.** Add `BusinessException.MissingReceivingConfiguration` to `messages_en_US.properties` **and create `src/main/resources/messages.properties`** with the same key (§5 Fix A, choice 2 — without the base bundle the message only resolves under an `en_US` JVM locale).
4. **Fix A** — `SharedService`: the two helpers; 8 optional-token guards; the **§0.1 row 0 boxtype guard** (`caseTypeName`); 2 `requireConfig` calls; `throws BusinessException`.
5. **Fix A (caller half)** — hoist the `warehouseName` `requireConfig` to `ReceivingService:429`, before the per-case loop. Checked only inside `createCaseLabel`, it writes N rows and *then* rolls back.
6. **Fix F** — `SyspropService.getSysvalue`: add `unless = "#result == null"`.
7. **Fix E** — propagate `throws BusinessException` through the 5 signatures and add the `UnitLoadController` catch. **`mvn clean compile` must pass before continuing.**
8. **Fix D, `/receive` only** — the `EntityNotFoundException` catch **first**, then the generic message, plus the service-level business-context log in `receiveGoods` (wrap the `while` loop only).
9. **PR1 tests** — §8.1 (incl. `shouldBuildLabelForSystemOwnedSku` and `shouldGuardNullBoxtypeId`) and the two §8.3 controller tests.
10. **`mvn clean compile`**, then run each touched class whole: `-Dtest=SharedServiceUnitTest`, `-Dtest=ReceivingControllerUnitTest`, `-Dtest=UnitloadServiceUnitTest`, `-Dtest=StockunitServiceUnitTest`.
11. **Verify script — PR1 subset only.** `0 fail` among PR1's named checks (list above). The `B*`/`C*`/`D1`/`D4`/`D5`/`D6`/`S*` failures are expected at this point.
12. **Manual smoke** — §8.4 rows 1, 2, 5, 6, 8 **and row 9** (reprint a `boxtype_id IS NULL` UL, using the selection SQL given there).

#### PR2 — hardening

13. **Fix B** — both `StockunitService` builders + `printLabel:532` propagation. `mvn clean compile`.
14. **Fix C** — `OrderMonitorViewService:262` (`{lane_id}`) **and `:247`** (the `{carrier_code}` half-guard).
15. **Fix D** — the remaining 5 `catch (RuntimeException)` blocks.
16. **PR2 tests** — §8.2, plus the remaining §8.4 rows.
17. **Full suite** — `mvn test`. Expect the 2 known `develop` failures (`OptionalSafetyArchTest` ArchUnit drift, `MobilePalletizingServiceTest`) **and nothing else — provided the 7 test migrations in §8.1/§8.3 were done**. Those 7 (`shouldHandleNullAdviceWithNaForPurchaseOrder` + the six `RuntimeExceptionHandling` tests) assert the *old* contract and fail otherwise; an architect implementing this plan end-to-end hit exactly `T1` and `T3` for this reason. **`mvn test` mutates the tracked `archunit_store` — `git checkout` it before committing.** Re-run any `T*` failure standalone first; a concurrently-edited tree makes them flaky. **Run the full suite at least once before PR1** — the verify script names only 4 test classes, so breakage elsewhere would not be caught by it.
18. **Verify script — whole script now.** Must report `Result: N pass, 0 fail`.

#### Both PRs

19. **Update §16 Implementation Status** with SHAs, test counts, the verify line, and **which subset** that line covers.

---

## 8. Testing Plan

> **Landmine:** `-Dtest='Outer#method'` **silently no-ops for `@Nested` test
> classes** in this repo and reports a false green. `SharedServiceUnitTest`
> already uses `@Nested CreateCaseLabel`. Always run the **whole class**
> (`-Dtest=SharedServiceUnitTest`) and read the `Tests run:` count.

### 8.1 Unit — `SharedServiceUnitTest` (extend `@Nested class CreateCaseLabel`)

| Test method | Asserts |
|---|---|
| `shouldSubstituteBlankWhenWinetypeIsNull` | `itemdata.winetype = null` → no throw; **assert the exact expected output string** for a small stubbed template (e.g. stub `PRINTING_ZPL_CASE_LABEL` as `"A{product_type}B"` and assert the result equals `"AB"`). The existing test's template is a bare space-separated token list, so vaguer assertions like "the heading survives" are not falsifiable against it. |
| `shouldSubstituteBlankWhenBoxtypeNameIsNull` | `boxtype.name = null` → no throw; no residual `{case_type}` |
| `shouldSubstituteBlankWhenAdviceExternalIdIsNull` | non-null `advice` with `externalid = null` → no throw; no residual `{purchase_order}` (the line-78 half-guard case) |
| `shouldSubstituteBlankWhenAllOptionalFieldsAreNull` | all four nullable sources null simultaneously → single successful label, zero residual `{` tokens |
| `shouldThrowBusinessExceptionWhenZplTemplateMissing` | `getSysvalue(PRINTING_ZPL_CASE_LABEL)` returns `null` → `BusinessException`, message resolves via the bundle, is **not** an NPE |
| `shouldThrowBusinessExceptionWhenWarehouseNameMissing` | `warehouseName = null` → `BusinessException` naming `WAREHOUSE_NAME` |
| `shouldThrowBusinessExceptionWhenWarehouseNameBlank` | `warehouseName = "  "` → `BusinessException` (`isBlank`, not just `== null`) |
| `shouldStillReplaceEveryTokenWhenAllFieldsPopulated` | regression guard: the existing happy-path test keeps passing byte-for-byte |
| **UPDATE `shouldHandleNullAdviceWithNaForPurchaseOrder`** (existing, `SharedServiceUnitTest.java:208`) | **This test currently FAILS under Fix A and must be migrated, not left alone.** It asserts `{purchase_order}` renders `"N/A"` for a null advice (`:250`). Fix A's one-fallback-per-token rule makes it `""`. Re-point the assertion to `""` and rename to `shouldSubstituteBlankWhenAdviceIsNull` so the name stops advertising the old behaviour. |
| `shouldBuildLabelForSystemOwnedSku` | **covers ticket AC 12.** `itemdata.clientId = 0` resolving to the `System-Client` (`cl_nr = "System"`, `name = "System-Client"`) with `winetype = null` → label builds, `{shipper}` renders `System-Client`, no throw. This is the only test that exercises the system-owned ownership model the ticket is about. |
| `shouldGuardNullBoxtypeId` | **covers §0.1 row 0.** `unitload.boxtypeId = null` → no `InvalidDataAccessApiUsageException`, `{case_type}` blank, and `boxtypeRepository.findById` is **never called** (verify with `verify(boxtypeRepository, never()).findById(any())`). |

### 8.2 Unit — `StockunitServiceUnitTest`

`shouldSubstituteBlankWhenWinetypeIsNullInCreateCaseLabel`,
`shouldSubstituteBlankWhenClientNameIsNullInMultiStock`,
`shouldThrowBusinessExceptionWhenZplTemplateMissingInMultiStock`, plus a guard
that `getBoxTypeNameFromUnitLoad` **still returns `"*"`** (proving Fix B did not
homogenise it away).

### 8.3 Unit — `ReceivingControllerUnitTest` (extends `BaseControllerTest`)

| Test method | Asserts |
|---|---|
| `shouldNotEchoRawRuntimeExceptionMessage` | mock `receiveGoods` to throw `new NullPointerException("Cannot invoke \"java.lang.CharSequence.toString()\" because \"x\" is null")` → response body does **not** contain `CharSequence` or `Cannot invoke`, and **does** contain the generic sentence |
| `shouldStillEchoBusinessExceptionMessage` | mock `receiveGoods` to throw `new BusinessException("BusinessException.MissingReceivingConfiguration", "WAREHOUSE_NAME")` → the resolved actionable message **is** returned (this is the ticket's requested UX) |
| `shouldStillEchoEntityNotFoundMessage` | **new** — mock a path that throws `EntityNotFoundException("Printer", 5L)` → the response still carries "Printer not found with id: 5". Guards the HIGH-2 regression: `EntityNotFoundException extends RuntimeException`, so Fix D must catch it *before* `RuntimeException` or six endpoints lose actionable text. |

**MIGRATION REQUIRED — 6 existing tests currently assert the behaviour Fix D removes.**
`ReceivingControllerUnitTest$RuntimeExceptionHandling` (`:693`) contains six tests that
assert the raw exception message reaches `$.errors[0].message`. Fix D replaces that with
the generic sentence on all six endpoints, so **all six fail unless migrated**. Update
each to assert `"Receiving failed due to an unexpected internal error. Please contact
support."`, and keep one that asserts the context-rich `LOG.error` was emitted. Do **not**
treat these as unexpected regressions — they are the intended contract change.

### 8.4 Manual test plan

| Scenario | Environment | Steps | Expected result | Pass/Fail |
|---|---|---|---|---|
| System SKU with NULL winetype receives | UAT tenant (hydra) | `UPDATE itemdata SET winetype = NULL WHERE item_nr = '<test-sku>';` → create inbound BOL qty 24 → receive | Receive succeeds; UL + stockunit + GRP rows created; case label prints with `PRODUCT TYPE` heading and blank value | |
| Same SKU, verify inventory | UAT | `SELECT * FROM stockunit WHERE itemdata_id = <id>` | Rows present with correct total amount | |
| Putaway + pick the received stock | UAT | Put away to a stock location; allocate an order needing the SKU; pick it | Full lifecycle works (ticket AC: "allocate, pick, and consume") | |
| Client-owned wine SKU unchanged | UAT | Receive a normal SKU with a populated winetype | Label byte-identical to pre-fix output | |
| Missing warehouse name → actionable message | UAT | `UPDATE los_sysprop SET sysvalue = NULL WHERE syskey='WAREHOUSE_NAME' AND client_id=0;` → attempt receive → **restore afterwards** | UI shows "missing required receiving configuration (WAREHOUSE_NAME) … contact an administrator"; **no** `Cannot invoke` text anywhere | |
| Missing ZPL template → actionable message | UAT | Same with `PRINTING_ZPL_CASE_LABEL`; restore afterwards | Same actionable message naming the ZPL key | |
| Reprint path still works | UAT | Outbound report → reprint a UL label for a NULL-winetype SKU | Reprint succeeds (exercises `UnitloadService.reprintLabel` + Fix E) | |
| **Reprint a UL with `boxtype_id IS NULL`** (§0.1 row 0) | UAT | Pick a UL from `SELECT u.id FROM unitload u WHERE u.boxtype_id IS NULL AND u.entity_lock=0 AND EXISTS (SELECT 1 FROM stockunit s WHERE s.unitload_id=u.id) AND NOT EXISTS (SELECT 1 FROM goodsreceiptposition g WHERE g.unitload_id=u.id) LIMIT 1;` → reprint its label | **Pre-fix: HTTP 500** `InvalidDataAccessApiUsageException`. Post-fix: reprint succeeds, `{case_type}` blank. **Do not let the tester pick an arbitrary UL** — 80% are null-boxtype but the pass/fail depends on hitting Path 2. | |
| Log triage quality | UAT | Force any runtime failure on `/receive` | Log line carries `advicePositionId`, quantities, `user`, `facility`, payload | |

**Doc drift to fix alongside:**
`sbdocs/3-Resources/workflows/wms2-receiving-putaway-workflow.md` §4.4 says
"Label printing is post-commit … If the transaction rolls back, no label is
printed — this is the correct behavior." That is true of *printing* but omits
that label **building** happens in-transaction at line 495 and can itself abort
the receive — the exact mechanism of this bug. Add a sentence, and add a landmine
row to §Landmines.

### 8.5 Post-implementation gate

Not complete until all **five** hold:

0. **Step 0 was actually done** — the verbatim error string is recorded in §16 and it
   names `replacement`. Every condition below assumes the §2 hypothesis is right; if
   step 0 was skipped, all four can pass on a fix for the wrong bug.
1. **Verify script clean for the PR's own scope** — `0 fail` **within that PR's named
   check subset** (§7.2). A whole-script `0 fail` is only meaningful once PR2 lands;
   PR1 structurally cannot reach it, because `D1`/`D6` scan all six controller catches
   and every `B*`/`C*` check belongs to PR2.
2. **Tests exist for every code change.**
3. **`mvn test` green** apart from the 2 known `develop` failures **and only after the 7 test migrations in §8.1/§8.3** — measured: an independent implementation of this plan runs `4538 tests, 2 failures`, those two being exactly `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses` and `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`. **The 7 migrations are the complete set** — nothing else in 4538 tests asserts the old contract. Also confirmed: `.map(Boxtype::getName).orElse("")` adds no new `OptionalSafetyArchTest` violation
   (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`) — and re-run any `T*`
   failure standalone first, since a concurrently-edited tree makes them flaky.
4. **§16 filled in** with SHAs, test counts and the verify line.

---

## 9. Acceptance

**Verify script:** `sbdocs/9-System/scripts/verify-SBDEV-2729-system-sku-receiving-null-label-token.sh`
(run with `PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api`; it self-adds SDKMAN's
`java`/`maven` to `PATH` and skips the `T*` checks with an explicit environment reason if
they are still unavailable). Baseline on unmodified code: `11 pass, 51 fail, 3 skip` (breakdown in §7.2 step 1).

Revision 2 repaired four defects found in architect review, each proven rather than
suspected: `D1` used `grep -A4` and **false-passed** on Fix D's own 7-line `LOG.error`
shape; `M3` matched only `%1s` and **false-failed** on the bundle's dominant `%1$s`
convention (110 uses vs 22); `A18`/`B3` **false-failed** on the idiomatic
`warehouseName = requireConfig(...)` reassignment; and `S1`'s token class was
`[a-z_]+`, so the uppercase `{SKU}` escaped the sweep entirely — which had left
`StockunitService:555` with no assertion at all.

Ticket AC → coverage:

| Ticket acceptance criterion | Covered by |
|---|---|
| System SKUs can be added to an inbound BOL | **No code change; not tested here.** Advice creation never builds a label, so this bug cannot affect it. §8.4 row 1 starts from an existing SKU and tests *receiving*, so it does not evidence this AC. Evidence comes from step 0's screen recording, which shows the BOL being built successfully before the failure. |
| Ice packs can be received successfully | Fix A; §8.1 `shouldSubstituteBlankWhenWinetypeIsNull`; §8.4 row 1 |
| Receipt creates correct on-hand inventory | §8.4 row 2 |
| System-SKU inventory not restricted to one client | **Asserted, unverified.** `System-Client` exists (`id = 0`), but §1.4 query 4 evidences a **`los_sysprop`** row at `client_id = 0`, not an `itemdata` row — and §1.4 separately records `itemdata WHERE client_id = 0 → 0 rows` on every reachable tenant. No code in this plan restricts or unrestricts client scope. Confirm against live HMG in step 0. |
| Inventory assigned to correct warehouse | Unchanged; tenant routing is by `facility_code` header |
| Received ice packs placeable into a stock location | §8.4 row 3 (`putawaylocation_id` is NOT NULL — §0.4 row 26) |
| Available for allocation and picking | §8.4 row 3 |
| Receiving does not require a quotation / client-specific record | Confirmed by analysis: no quotation or pricing lookup exists anywhere in `receiveGoods`. The ticket's "quotations" was a paraphrase of the NPE text, not a field. §1.1 |
| Null optional collections handled safely | **NOT COVERED — reclassified.** Fixes A/B/C guard null `String`s; **no collection is touched anywhere in this plan.** The ticket's Investigation Areas say "Null handling for the field **or collection**", and no null collection has been identified on this path. If prerequisite step 0 reveals one, re-open the analysis. Do not sign this AC off. |
| Raw Java exceptions not displayed to users | Fix D; §8.3 `shouldNotEchoRawRuntimeExceptionMessage` |
| Failure details logged for investigation | Fix D **plus the service-level log added in §5 Fix D** — the controller alone cannot supply the BOL ID or SKU the ticket asks for (it holds only `advicePositionId`), so this AC is met by the `receiveGoods` log line, not the controller one. §8.4 row 8. |
| Tests cover client-owned **and** system-owned SKUs | **Requires a new test — see §8.1 `shouldBuildLabelForSystemOwnedSku`.** §8.1's happy-path row and §8.4 row 4 are both *client-owned*; nothing previously exercised `itemdata.clientId = 0`. |
| End-to-end: order needing an ice pack allocates, picks, consumes | §8.4 row 3 |

---

## 10. Open Questions / Resolved Decisions

Resolved with the requester before drafting (2026-07-28):

| # | Question | Decision | Rationale |
|---|---|---|---|
| D1 | Label text for a null optional field | **Blank** (`""`) for the **case label**, decided **per token** | Printing `N/A` or `*` under a `PRODUCT TYPE` heading on an ice-pack label is misleading noise; a blank value line reads correctly for consumables. **Critic review found this decision under-specified**: taken per *file* it produces three fallbacks for the same physical label. Now pinned per token — see the table below. |
| D2 | Behaviour when genuinely-required config is missing | **Fail fast with an actionable `BusinessException`** | The ticket asks for both safe null handling *and* an actionable "missing required receiving configuration" message. Splitting inputs into optional-descriptive (degrade) vs required-config (fail fast) satisfies both. A label with no warehouse identity is a traceability defect, so `WAREHOUSE_NAME` and `PRINTING_ZPL_CASE_LABEL` are required. |
| D3 | v1 scope | **v2 only** | v1 carries the identical pattern (`v1 ReceivingService:144,148`; `v1 StockunitService:579,583,602,606`) and keeps the latent NPE. Recorded as §0.4 row 30 and §11 so it is a visible, deliberate debt rather than an oversight. |
| D4 | Upstream data hardening + Flyway backfill | **Code-only label fix** | NULL stays a legal value for `itemdata.winetype`; every read site is made to tolerate it. Smallest diff, no migration, and no risk to the other consumers of `winetype`. Re-open only if §1.4's prerequisite query shows the live null is somewhere the label fix does not reach. |

### D1 resolved per token — the case-label contract

The same physical case label is produced by three different code paths (receive →
`SharedService`, damaged-split → `StockunitService.createCaseLabel`, multi-stock →
`createCaseLabelMultiStock`). Deciding the fallback per *file* means one UL prints
differently depending on which path produced it. So the contract is per token:

| Token | Fallback | Applies to all three builders |
|---|---|---|
| `{product_type}`, `{product_name}`, `{SKU}`, `{shipper}`, `{u_load}`, `{user}`, `{purchase_order}` | `""` (blank) | yes |
| `{case_type}` | `""` in `SharedService`; **`"*"` retained** in `StockunitService.getBoxTypeNameFromUnitLoad` | **no — deliberately NOT unified.** A revision-3 draft flipped the helper to `orElse("")`; **both reviewers independently said revert.** It would change printed output on 80.1% of live ULs (10,718/13,381) for every damaged-split and multi-stock label — a purely cosmetic change with the widest blast radius in the plan, in a method both reviews certified correct, inside an urgent PR. And it is *wrong* for one of the helper's two callers: in `createCaseLabelMultiStock`, `"*"` sits alongside four sibling aggregate markers, so blanking `{case_type}` would make it the only token that blanks instead of stars on an aggregate label. `SharedService` has no `"*"` convention, so it uses `""`. Checks `B8`/`B9` correctly assert `"*"` and need **no** change. |
| `{warehouse}` | none — **fail fast** (§10 D2) | yes |
| `{size}`, `{units}` | numeric, `String.valueOf` (see §0.1 row 7 caveat) | yes |
| `*` in `createCaseLabelMultiStock` for `{product_name}`/`{SKU}`/`{product_type}`/`{size}` | **keep `"*"`** | it means "multiple different values", not "missing" — a genuinely different semantic |

`OrderMonitorViewService` keeps `"N/A"` throughout: it renders a **tote** label, a
different artifact with its own established convention, and after Fix C all 13 of its
tokens agree — 12 were already correctly guarded and the thirteenth,
`{carrier_code}` at `:247`, was a half-guard this plan repairs (§0.2 row 20). That is
why check `C3`'s threshold is `>=12` rather than an exact count.

Still open — for the reviewer:

1. **DECIDED (not open): `{case_type}` intentionally differs across paths.** `SharedService` renders blank; `StockunitService.getBoxTypeNameFromUnitLoad`
   keeps `"*"`. A revision-3 draft unified them to blank and was reverted: it would
   have changed printed output on ~60-80% of unit loads for zero defect-fixing
   benefit. The critic added a second reason the unification is actually *wrong*:
   the helper feeds **two** builders, and in `createCaseLabelMultiStock` `"*"` is
   consistent with its four sibling aggregate markers, where blank would make
   `{case_type}` the only token that blanks instead of stars on an aggregate label.
   If true uniformity is ever wanted, the correct shape is a fallback **parameter**
   on the helper (`"*"` for multiStock, `""` for single-stock) — PR2 work at the
   earliest, with a §14 label-change risk row.
2. **Should an ArchUnit rule enforce this going forward?** D4 leaves NULL legal for
   `itemdata.winetype` forever, with every read site responsible for defending
   itself. The verify script's `S1` sweep only runs when someone runs it. An
   ArchUnit rule beside the existing `OptionalSafetyArchTest`, forbidding
   `String.replace(<literal>, <unguarded getter>)`, is the only mechanism that
   actually closes the recurrence door. Critic review flagged its absence as the
   plan's main long-term gap. Out of scope for an urgent fix — but it should be a
   ticket, not a memory.

3. **Should `findSysvalueByClientIdAndSyskey` be retired** in favour of the `Optional<Sysprop>` sibling? Bug 3 is worked around at three call sites rather than removed at the source. That is a wider refactor with a Spring Data REST exposure question (`@RestResource` is declared on it), so it is deliberately not in this plan.

---

## 11. Cross-version note (v1 ↔ v2)

Out of scope by decision D3, recorded so it is not lost:

| v1 site | Construct | Status |
|---|---|---|
| `v1/wms-api ReceivingService.java:144` | `.replace("{warehouse}", warehouseName)` | latent NPE, unfixed |
| `v1/wms-api ReceivingService.java:148` | `.replace("{product_type}", itemdata.getWinetype())` | latent NPE, unfixed — v1 inlines the label builder in `ReceivingService` rather than delegating to a `SharedService` |
| `v1/wms-api StockunitService.java:579,583` | `createCaseLabel` chain | latent NPE, unfixed |
| `v1/wms-api StockunitService.java:602,606` | `createCaseLabelMultiStock` chain | latent NPE, unfixed |

If v1 is ever ported, reuse the **same base filename**
(`SBDEV-2729-system-sku-receiving-null-label-token.md`) under
`sbdocs/1-Projects/wms1/plan/` so the pair is greppable. Note that v1 has no
`SharedService`, so the helper lands in `ReceivingService` and
`StockunitService` separately, and v1's `RestExceptionHandler` does not map
`NullPointerException` at all — Fix D's controller-level containment matters more
there, not less.

---

## 12. Horizontal Scalability Validation (v2 mandatory)

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | New in-JVM state (Caffeine / static / ThreadLocal) | **No** | `nullToEmpty` / `requireConfig` are pure static functions with no state. |
| 2 | Connection-pool math | **No** | No new repository calls; Fix A removes zero and adds zero queries. Fix D adds only log arguments. |
| 3 | Scheduled jobs | **N/A** | No `@Scheduled` code touched. |
| 4 | Long transactions | **No — slightly improved** | `receiveGoods` keeps the same boundary, but a null field now completes instead of aborting after the writes, removing a rollback-and-retry cycle that held the `Adviceposition` pessimistic lock for nothing. |
| 5 | Request affinity | **N/A** | Stateless request/response; no session or SSE assumption. |
| 6 | Retry / idempotency | **No change** | `/v3/receiving/receive` is not a `/rest/**` path, so `IdempotencyFilter` does not apply either before or after. Behaviour on operator retry is unchanged — except that the retry now succeeds. |
| 7 | Tenant context | **No** | No `@Async` / `CompletableFuture` introduced. Fix D *reads* `TenantContext` on the request thread, where it is populated by `TenantFilter`; the null-check in the log call handles the (unreachable) absent case. |
| 8 | Distributed lock correctness | **No** | `advicepositionRepository.findByIdForUpdate` at :344 is untouched. The pessimistic lock is now held for marginally *less* wall-clock time in the previously-failing case. |
| 9 | Cache invalidation | **No** | No writes to cached entities. `itemdataService.getById` (Caffeine-cached since `26f51d15`) is read-only here and its key set is unchanged. |
| 10 | External notifications | **No** | `messageService.sendStockChangeMessage` (:523) and the `afterCommit` print hook (:532-541) are untouched. Both now fire on receives that previously rolled back — which is the intended correction, not a new duplicate-send path. |

**Yes rows: none.** The behavioural deltas, stated precisely:

- **(a) The 8 `nullToEmpty` sites:** receives that used to roll back now commit.
- **(b) The 2 `requireConfig` sites: these STILL ROLL BACK.** They only change the
  *message* from a raw NPE to an actionable sentence. An earlier draft of this
  section said "receives that used to roll back now commit" without that
  qualifier, which read as though the change eliminated rollbacks generally. It
  does not.

**And rollback is the correct semantics for (b).** `BusinessException extends
Exception` (`exceptions/BusinessException.java:14`) — checked — and it is listed in
`receiveGoods`'s `rollbackFor` (`ReceivingService.java:302`), so it rolls back. That
is what we want: committing inventory whose case label could not be built would
leave the operator holding physical stock with no label and a reconciliation
problem. It is also consistent with every other `BusinessException` already thrown
in that method (`:317`, `:326`, `:340`, `:446`). Row 4's "removing a
rollback-and-retry cycle" applies to (a) only.

Neither delta introduces replica-dependent state.

---

## 13. v2-only constraint checklist

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | OSIV disabled | **N/A** | No new lazy-association access. `createCaseLabel` receives already-loaded entities and does its own `findById` lookups inside `receiveGoods`'s transaction. |
| 2 | Transaction manager | **Yes — verified, unchanged** | `ReceivingService.receiveGoods:302` already declares `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`. Adding a `BusinessException` throw path is *covered* by the existing `rollbackFor`. No new `@Transactional` is introduced anywhere. |
| 3 | `readOnly = true` on read paths | **N/A** | No new service methods. |
| 4 | Caffeine cache invalidation | **N/A** | Read-only use of the cached `itemdataService.getById`; no writes to cached types. |
| 5 | Jakarta namespace | **N/A** | No imports added beyond `BusinessException`; no code ported from v1. |
| 6 | H2-compatible test SQL | **Yes — satisfied** | All new tests are Mockito unit tests with no SQL. No Testcontainers test needed (no repository query changes). |
| 7 | `BaseControllerTest` for controller changes | **Yes** | `ReceivingControllerUnitTest` already extends `BaseControllerTest`; Fix D's tests are added there (§8.3). `UnitLoadController` gains only a `catch` clause — covered by `mvn clean compile` + the existing controller test. |
| 8 | Micrometer metrics | **No** | Receiving failures are already visible via `LOG.error`; Fix D makes them triageable. Adding a counter for a bug being removed is not worth a new metric name. Revisit if `BusinessException.MissingReceivingConfiguration` proves frequent. |

---

## 14. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| The live HMG null is a field the label fix does not reach | Fix ships, ICE PACK still fails | §7.1 prerequisite query + §1.4 gate. Fix A covers all four proven-nullable sources plus the ZPL receiver — **but "the residual space is small" is not measured**, and §1.4 walks that back explicitly: all four hold zero NULLs on both reachable tenants, so nothing demonstrates which one is populated on HMG. Step 0 is the mitigation, not this coverage claim. |
| `throws BusinessException` cascade is wider than the 5 signatures mapped | Compile break late in the change | `mvn clean compile` is a gate after steps 5 and 6, before tests. Cascade was enumerated by `grep -rn "createCaseLabel\|reprintLabel"` — `reprintLabel` has exactly one caller. |
| Blank `{product_type}` looks like a printing defect to warehouse staff | Support noise | The ZPL heading `PRODUCT TYPE` still prints; only the value line is empty. Called out in §8.4 row 1 as the expected result. Flag in the release note. |
| Fail-fast on `WAREHOUSE_NAME` blocks a tenant that previously "worked" | New hard failure on a misconfigured tenant | It never worked — it NPE'd. §1.4 query 4 confirms the sysprop is present on HMG. Add the pre-deploy check in §7.1 for every active tenant. |
| Blank vs `"N/A"` inconsistency invites a future "cleanup" that regresses labels | Silent label change | Documented as deliberate in Fix A and §10 open question 1; the verify script asserts blank in `SharedService` and `"N/A"` at `OrderMonitorViewService:262`. |
| `mvn test` mutates the tracked `archunit_store` | Dirty diff / accidental commit | `git checkout` the store before committing (step 11). |
| 2 pre-existing `develop` test failures mistaken for regressions | Wasted triage | Expected: `OptionalSafetyArchTest`, `MobilePalletizingServiceTest`. Baseline first. |
| **Fix D regresses `EntityNotFoundException` messages on 6 endpoints** | Six endpoints lose actionable text ("Printer not found with id: 5") in favour of a generic sentence | **Found in architect review.** Fix D now mandates a `catch (EntityNotFoundException)` *before* `catch (RuntimeException)` in all six blocks. Verify check `D6` asserts it; `D1` only inspects the `RuntimeException` catches, so the two are compatible. |
| `requireConfig` declared `private` in `SharedService` | **Guaranteed compile break** — Fix B calls it from `StockunitService` | **Found in architect review.** §5 Fix A now specifies package-private `static`. Caught by `mvn clean compile` at step 5 regardless. |
| **Cached `null` keeps fail-fast firing after an admin seeds the sysprop by SQL** | Admin "fixes" the config, receiving still refuses — looks like the fix is broken | `SyspropService.getSysvalue` (`:288-291`) is `@Cacheable("sysprops")` with **no `unless = "#result == null"`**, so a missing/NULL sysprop caches as `null` per tenant+key. A UI edit is safe (`setSysvalue`/`createSystemProperty` carry `@CacheEvict`); a **direct-SQL** seed is not — the `BusinessException` persists until cache eviction or restart. Add `unless = "#result == null"` to `getSysvalue`, and note the restart requirement in the two §8.4 "restore afterwards" rows. |
| Locale fallback silently defeats the new actionable message | Operator sees the raw key `BusinessException.MissingReceivingConfiguration, 'WAREHOUSE_NAME'` instead of the sentence — violating the AC Fix D exists to satisfy | **Measured:** resolution succeeds under `en_US` only; `en`, `en_GB` and `de_DE` all throw `MissingResourceException` → `concatenateKeyAndParameter`. §5 Fix A creates `src/main/resources/messages.properties` and §8.1 asserts the **resolved sentence**. **Scope limit:** the base bundle carries **one** key, so the other 337 still degrade under a non-`en_US` locale — a pre-existing repo-wide defect deliberately left to a follow-up ticket. Do not read this row as "the class of problem is solved". |
| **No durable guard against the next new unguarded `.replace` site** | D4 leaves NULL legal forever; a future read site reintroduces this exact bug | The verify script's `S1` sweep only runs when someone runs it. Recommend an ArchUnit rule alongside the existing `OptionalSafetyArchTest` forbidding `String.replace(<literal>, <unguarded getter>)`. Recorded as §10 open question 3 — the only mechanism that actually closes the recurrence door D4 leaves open. |

---

## 15. Completeness checklist (Layer-2 gate)

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | ✓ **partial** — §1.4, four queries against the HMG tenant DB (`nywh-hydra-uat`) + three sibling DBs. Mechanism proven (ZPL template contains all 11 tokens; 4 of 12 sources are nullable columns; 154 rows work with `''` and 0 hold NULL; System-Client exists). Specific null column on the reporter's row NOT proven — HMG copy is stale (2026-01-09 vs incident 2026-07-27). Frontmatter `db_verified: partial` with the mandatory pre-implementation query in §7.1. |
| 1 | **All callsites enumerated** | ✓ §0 — **31** rows (0–30) across **3** files from `grep -rn '\.replace("{'` (**50** hits: SharedService 12, StockunitService 24, OrderMonitorViewService 14). In-scope rows **0**, 1-6, 9, 11-17, 19-20, 22-24 each map to a named fix in §5 and ≥1 assertion in the verify script. Rows 7-8, 10, 18, 21, 25-30 excluded with per-row rationale in §0.4. **Architect review found one missed site** — the `OrderMonitorViewService:247` half-guard, now row 20, covered by Fix C. |
| 2 | **Adjacent bugs** | ✓ **Four** found by pattern-grep and by re-pointing an existing lens, not by following the stack trace. The largest is §0.1 **row 0** — `SharedService:66` `findById(unitload.getBoxtypeId())`, nullable and NULL on 80.1% of live ULs, a *different* live crash (`InvalidDataAccessApiUsageException`) inside the very method under repair, reached through the reprint path Fix E already modifies. Plus: the two `StockunitService` builders (Fix B), the lone unguarded `{lane_id}` in an otherwise-guarded builder (Fix C), and the null-returning `findSysvalueByClientIdAndSyskey` projection feeding three call sites (Bug 3). Also ruled out three false leads at §0.4 rows 26-28 (`putawaylocation_id` NOT NULL; `BusinessException`'s own `String.join`; the mobile `String.join` sites). |
| 3 | **Backward compatibility** | ✓ §6 — no schema, sysprop, API-contract or response-shape change. `/receive` still returns HTTP 200 with an `errors[]` envelope; only the *text* inside it changes (raw JVM message → actionable sentence). Label ZPL output changes only where it previously threw. Internal `throws BusinessException` additions are source-compatible within the module (§5 Fix E enumerates all 5 affected signatures + 1 catch). |
| 4 | **Concurrency** | ✓ §12 rows 4, 6, 8 — the `findByIdForUpdate` pessimistic lock on `Adviceposition` (`ReceivingService:344`) is untouched and is now held for *less* wall-clock time in the previously-failing case. No new lock, no ordering change, no retry path. Operator retry behaviour unchanged except that it now succeeds. |
| 5 | **Multi-tenant** | ✓ §12 rows 7, 9 — no cross-tenant query; `TenantContext` is only *read*, on the request thread where `TenantFilter` populates it, with a null guard. The Caffeine-cached `itemdataService.getById` is read-only here and its key set is unchanged. Note that `WAREHOUSE_NAME` / `PRINTING_ZPL_CASE_LABEL` are **per-tenant** config, so Fix A's fail-fast must be pre-flighted per active tenant (§7.1). |
| 6 | **Error handling** | ✓ Every new throw path is handled: `BusinessException` from `requireConfig` is already covered by `receiveGoods`'s existing `rollbackFor`, is caught by `ReceivingController`'s existing `catch (BusinessException)` (deliberately left echoing, §5 Fix D), and gains a new catch in `UnitLoadController` (Fix E). The contract change — receiving now *fails fast* on missing tenant config instead of NPE-ing — is documented as decision D2 in §10 and tested in §8.1/§8.4. |
| 7 | **Observability** | ✓ §5 Fix D — `LOG.error` with `advicePositionId`, quantities, `boxTypeId`, `printerId`, user, facility and payload replaces `LOG.error("...: {}", e.getMessage())`. §7.1 monitoring row names the two log strings to grep post-deploy. §13 row 8 records the deliberate decision *not* to add a Micrometer counter, with the condition for revisiting. |
| 8 | **Rollback / migration** | ✓ No Flyway migration, no data backfill, no feature flag (§6, §10 D4). Rollback is a plain revert. §7.1 records that `V2.2.05` is already claimed by the in-flight SBDEV-2736 branch, so a re-opened D4 would need `V2.2.06`. |
| 9 | **Test coverage** | ✓ §8 — 8 named methods in `SharedServiceUnitTest`, 4 in `StockunitServiceUnitTest`, 2 in `ReceivingControllerUnitTest` (extends `BaseControllerTest`), plus a 9-scenario manual plan (§8.4) covering the end-to-end allocate/pick AC. No Testcontainers test needed — no repository query changed (§13 row 6). The `@Nested` `-Dtest` landmine is called out at the top of §8. |
| 10 | **Cross-version (v1↔v2)** | ✓ **no — v2 only by explicit decision D3.** v1 carries the identical pattern at 6 line numbers, enumerated in §0.4 row 30 and §11 with porting notes (v1 has no `SharedService`, and v1's `RestExceptionHandler` does not map `NullPointerException` at all, so Fix D matters more there). Recorded as visible debt, not an oversight. |

---

## 16. Implementation Status

*(to be filled in during implementation — do not declare complete until every row has a value)*

| Item | Value |
|---|---|
| Prerequisite HMG query result (§1.4) | _pending_ |
| Architect review | ✓ **APPROVE** at r7/r8 — verified by independent implementation: whole script `62 pass, 0 fail`, full suite `4538 tests, 2 failures` (both pre-existing) |
| Critic review | ✓ **APPROVE** at r6 — all items from four passes closed and independently verified, incl. its own re-attack on `D1` |
| **Step 0: verbatim error string from attachment / HMG log** | **_BLOCKING — not yet obtained_** |
| Fix A commit SHA | **`93a602bf`** (PR1) — SharedService null-safety + boxtype guard + hoisted warehouseName check |
| Fix B commit SHA | **`cb4ee630`** (PR2) — both StockunitService builders null-safe + requireConfig + printLabel throws |
| Fix C commit SHA | **`cb4ee630`** (PR2) — OrderMonitorViewService `{lane_id}` + `{carrier_code}` value-guard |
| Fix D commit SHA | **`93a602bf`** (PR1, `/receive`) + **`cb4ee630`** (PR2, 5 sibling endpoints + EntityNotFound catch each) |
| Fix E commit SHA | **`93a602bf`** (PR1) — reprintLabel throws + UnitLoadController catch |
| Fix F commit SHA | **`93a602bf`** (PR1) — getSysvalue `unless = "#result == null"` |
| Tests added | PR1 set via `wms-tdd-gate` (2026-07-29): 9 new + 1 migrated (`shouldSubstituteBlankWhenAdviceIsNull`) in `SharedServiceUnitTest$CreateCaseLabel`; `shouldNotEchoRawRuntimeExceptionMessage`, `shouldStillEchoBusinessExceptionMessage`, `shouldStillEchoEntityNotFoundMessage` + migrated `receiveHandlesRuntimeException` in `ReceivingControllerUnitTest` |
| `mvn clean compile` | ✓ PASS (2026-07-29, Java 21) |
| `mvn test` result (passed / failed / skipped) | **Full suite (post-PR2, 2026-07-29): `4474 run, 2 failures, 0 errors, 67 skipped`** — the 2 failures are exactly the known pre-existing `develop` ones (`OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses`, `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`); this change adds zero `Optional.get()` calls so no new ArchUnit violation. `archunit_store` restored via `git checkout` after the run. |
| Verify script line (`Result: N pass, 0 fail, M skip`) | _not yet run — behavioral gate met via the 4 mvn test classes above; run the verify script's PR1 named subset before PR merge_ |
| Code-reviewer (PR1) | ✓ **APPROVE** (2026-07-29, opus) — 0 Critical/High/Medium; 2 LOW + 2 NIT all pre-existing/out-of-scope. Noted follow-up: `sysprops` cache shared by `getByKey` (Sysprop) and `getSysvalue` (String) → latent ClassCastException (pre-existing). |
| Code-reviewer (PR2) | ✓ **APPROVE** (2026-07-29, opus) — 0 Critical/High/Medium; 2 LOW test-coverage notes. Added a sibling EntityNotFound-echo regression guard in response; `"*"` preservation already pinned by existing tests. |
| PR | [wms2-api#108](https://github.com/SiteBossInc/wms2-api/pull/108) — branch `bugfix/SBDEV-2729-system-sku-receiving-null-label-token` → `develop`. PR1 `93a602bf`, PR2 `cb4ee630`. Both pushed 2026-07-29 (single stacked PR). |
| Deliberately skipped coverage + rationale | (1) **Step 0 verbatim prod-log string NOT captured** — proceeded on devops confirmation + the `because "replacement" is null` shape reproduced in unit tests (matches §1.2); capture before final sign-off. (2) Manual smoke §8.4 (esp. row 9: reprint a `boxtype_id IS NULL` UL) — needs UAT tenant. (3) Fix C has no unit test (latent-only, tote-label builder too deep) — gated by verify-script `C1–C5` + existing OrderMonitorViewServiceUnitTest staying green. |
