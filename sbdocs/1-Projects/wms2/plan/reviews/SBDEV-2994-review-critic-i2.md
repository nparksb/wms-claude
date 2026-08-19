## VERDICT: **ITERATE**

The revision is a large, genuine improvement. I re-measured the load-bearing evidence independently and it now holds: on `wms2-wineco-dev` the `unitload` lock distribution really is `{0: 22262, 2: 320642, 405: 411862}` — so `ON_HOLD`=0, `QUALITY_FAULT`=0 and the allowlist/denylist reshape are correctly grounded; all 320,642 To-Delete rows really are `-X-` mangled (0 unmangled) and all 411,862 Shipped rows really are unmangled with 395,984 carrying stock, so §5 Fix B's "the entire real exposure is Shipped" is exactly right. `BusinessException.resolveMessage` really does use `String.format`, so `%1$s` is the correct interpolation form, and `BusinessObjectLockState.getCodeText(405)` really does return `"Shipped"`. The pre-mortem is real work, Option 4 is now priced honestly, and the message-key spelling is consistent in **every** location I checked (§5:432-434, §5.4:693, §8.1:769-788, script `K_UL/K_LOC/K_USE`) — M2 and the key unification are cleanly discharged.

It still cannot go to a TDD gate, for one structural reason and four demonstrated ones:

**The verify script can never pass.** Three rows are unsatisfiable by construction. `check_B12_eligibility_sysprop_gate` and `check_B13_nirvana_guard_ungated` are **invoked at script lines 376-377 and never defined anywhere in the file** — bash returns 127, which `run` records as a plain FAIL (the exact landmine already recorded in this vault). `B8`'s `method_slice` end-anchor is `^\s*(public|protected|private)\s`, but `method_slice` compiles with `/s` and **not** `/m`, so `^` matches only at file offset 0 and the slice can never be produced. I ran the script against a hand-built correct implementation: **42 pass, 3 fail** — B8, B12, B13. §8.7's stated final acceptance is `Result: N pass, 0 fail`. That target is unreachable no matter what anyone implements.

And I built seven near-miss wrong shadows. **Four scored identically to the correct implementation (42 pass / 3 fail).**

---

## 1. DISCHARGE AUDIT — M1–M22

| # | Status | Evidence |
|---|---|---|
| M1 | **DISCHARGED** (with a caveat) | §0 rows 26-28 present, method line rewritten to "enumerate by SCREEN, not by URL", row 28 correctly calls the store action dead. Caveat → N19: `SBDEV-2996` has no plan file and no README entry; the split is a promise. |
| M2 | **DISCHARGED** | `errors[0].field` everywhere; §8.2 row 1 fixes the label to `"Runtime Error"` and explicitly notes T5 cannot discriminate it. |
| M3 | **DISCHARGED in the plan; NOT in the script** | §5 Fix C's body is a fixed operator string + `id`; `RestExceptionHandler:155` `debug`→`warn` added. But see **N5**: I shipped `String detail = e.getMessage(); errors.add(getErrorMessage("Runtime Error", detail));` and `C3` passed. |
| M4 | **DISCHARGED** | §5 Fix E now carries a 7-row comparison table, names `store/cancellation.js:44-48` as the existing helper, and states the two honest discriminators. |
| M5 | **DISCHARGED** | R3 reopened as High, all three defects named, ON_HOLD dropped from Fix B, §12 Q4 reopened. |
| M6 | **DISCHARGED** | 210,167 corrected to 1, with the `count(*)`-over-`LEFT JOIN` root cause stated. I re-measured; the corrected figures are right. |
| M7 | **DISCHARGED** | §11.5, five scenarios, each with a mechanism, a *provable-today* artifact, and a derived mitigation. This is a real pre-mortem, not a relabelled register. |
| M8 | **PARTIAL** | A3/B3/C1/T2/T3 rewritten; C1, C3, C4, D3, W1/W2, P1 now correctly discriminate (I verified each with a targeted mutation). But A3 still false-greens (**N4**), C3 still false-greens (**N5**), and the eight new B rows false-green on an empty stub (**N3**). |
| M9 | **DISCHARGED** | §0.3 row 29, with the remediation corrected to `@Mock DestinationEligibilityService` + `@InjectMocks` rewiring. §8.3 repeats it. |
| M10 | **DISCHARGED** | §0.3 rows 31-32; §8.4 last row. |
| M11 | **DISCHARGED** | `-q` gone, `mvn_available` guard added, SKIP path confirmed working here (mvn not on PATH → `SKIP M1-M5`). Residual: **N16**. |
| M12 | **PARTIAL — and it created a new contradiction** | The false claim is corrected at §5:427, but the correction was not propagated. See **N9**. |
| M13 | **DISCHARGED** | §5.4:693 argues the divergence from `entityNotFoundForId`/`ForName` explicitly. |
| M14 | **PARTIAL** | `%2$s` is now defined for the lock branch (`getCodeText` — I confirmed it covers all 8 states). It is **still undefined for the Nirvana-location branch**, which is the one *ungated* branch. See **N11**. |
| M15 | **DISCHARGED** | §0.1 row 13 corrected, with the switch at `transferStock.vue:43` and the send at `:104` cited, and "three further sites in `:269-290`". |
| M16 | **DISCHARGED** | §10 row 3 rewritten; §5 Fix B states the visibility argument (method reference cannot bind a private method). |
| M17 | **DISCHARGED in substance** | The rendered copy is now neutral (`Location %1$s was not found.`) so the P4 objection is gone. The *key name* still says "Destination" for a pick-from source — Low, noted as N-minor. |
| M18 | **DISCHARGED** | §0.3 row 25 and §8.2 row 3 both say the bulk test must be **written**. |
| M19 | **DISCHARGED** | §0.1 row 14, Fix A4 decision in §5 Fix C, verify row A4. Residual: A4's row is a bare negation (**N15**). |
| M20 | **DISCHARGED** | §8.1 requires the explicit UTF-8 `InputStreamReader` and `getLocalizedMessage(Locale.ROOT)`; T4 enforces the reader. |
| M21 | **PARTIAL** | §5 Fix E corrected to "12 of 13 mobile / 30+ web / 42+ total". §12 Q3 at line 1077 **still says "~18 store modules across both UIs"** — the same document now contradicts itself. |
| M22 | **DISCHARGED, replaced by a new one** | The `UnitloadType` comment is gone. Script line 40 now says `Result: 4 pass, 38 fail, 1 skip`; the actual measured baseline is **41 fail** (**N17**). |

Baseline reproduced byte-for-byte from a shadow of `origin/develop` (api `d2bedc0`, mobile `8e623b8`, web `d4f71c1`): **`Result: 4 pass, 41 fail, 1 skip`**, greens = A3, P1, P2, P3. Matches §8.7; the script's own header does not.

---

## 2. NEW MUST-FIXES

### N1 — `B12` and `B13` are invoked but never defined — **High, blocking**
Script `:376-377` call `check_B12_eligibility_sysprop_gate` and `check_B13_nirvana_guard_ungated`. `grep -n 'check_B12\|check_B13'` returns **only the two `run` lines**. `bash -n` passes; the failure is a runtime 127 that `run` records as an ordinary FAIL. Consequences:
- The script can never reach `0 fail`, so §8.7's acceptance criterion is unreachable.
- A permanently-red row is indistinguishable from unimplemented work — the implementer will "chase" B12/B13 forever or, worse, learn to ignore reds.
- **The sysprop gate and the ungated-Nirvana invariant have zero working verification.** I built a shadow that *gates* the Nirvana refusal behind the sysprop — i.e. leaves the SBDEV-2995 silent-data-loss path open, the exact thing B13 exists to forbid — and it scored **42 pass / 3 fail, identical to correct**.

### N2 — `B8` is unsatisfiable, and its predicate is wrong even if fixed — **High**
`method_slice 'public boolean canReceiveStock' '^\s*(public|protected|private)\s'` under `perl -0777 ... /s` (no `/m`). Demonstrated: the slice returns empty (exit 0, no output); adding `/m` returns a 757-char body. So B8 is permanently red. Second defect: the body check does `grep -qE 'orElseThrow|\.get\(\)' && return 1`. A correct total predicate that does `if (!loc.isPresent()) return false; ... loc.get().getName()` is banned. B8 rejects idiomatic correct code and accepts nothing.

### N3 — the entire Fix B production surface passes on an empty stub — **High**
I replaced `DestinationEligibilityService.java` with a class whose `assertCanReceiveStock` has an **empty body** and whose `canReceiveStock` is `return true;`, with the branch names present only in `// TODO:` comments. Result: **42 pass / 3 fail — identical to the correct implementation.** B1, B2, B3, B4, B5, B6, B7, B9, B10, B11 all green. Fix B — the change carrying every High risk in the plan — is entirely unverified. This is the same comment-satisfies-the-grep defect the review already caught on T2/T3; it was repaired for the *test* files and not for the *production* file.

### N4 — `A3` still false-greens on the defect it exists to catch — **High**
The iteration-2 note says the threshold was "off by one" and 33 is correct. But `grep -cE 'EntityNotFoundException'` counts **lines, including comments**, and §5 Fix A's own prescribed comment block contains the literal string `"Raising EntityNotFoundException here escapes the controller's checked-exception catch"`. I built a shadow that (a) includes the plan's prescribed comment and (b) blanket-converts `:157` (`UnitLoadType not found by name: PALLET`, an internal-constant site) to `BusinessException`. Count = 33. Result: **42 pass / 3 fail — identical to correct.** A plan-conformant implementer gets one free wrong conversion. A line-count over a token that appears in prose cannot carry this invariant.

### N5 — `C3` still false-greens on the M3 leak — **High**
`C3` forbids `getErrorMessage\([^)]*e\.getMessage`. I shipped:
```java
String detail = e.getMessage();
errors.add(getErrorMessage("Runtime Error", detail));
```
**42 pass / 3 fail — identical to correct.** The M3/C2 finding (raw `"Location not found with id: 3421"` on a handheld), rated High by two lanes, is still shippable under a green script.

### N6 — §5 Fix B claims propagations into §8.1 and the script that did not happen — **High**
§5:488-490 states: *"§8.1's Shipped/To-Delete tests set the gate ON and a new test asserts they pass through when it is OFF; … verify gains `B12`."* Neither is true. §8.1's thirteen rows never mention the sysprop, and there is **no** gate-OFF pass-through test. `B12` is the undefined function of N1. The gate therefore has a key, a constant name, and a seeding step — but **no tests and no working verify row**.

### N7 — R3's blocking status is unreconciled with the gate — **Medium**
§11 R3: *"Required before implementation: re-run … on at least one production tenant. Owner: unassigned — this is the blocking prerequisite that needs a human."* §5 Fix B and §12 Q6 treat the default-OFF gate as the resolution. These cannot both be operative. As written, the plan says the gate makes it safe to ship *and* that nothing may be implemented until a human runs an unowned production query. Pick one and say which.

### N8 — "shadow mode" is the mitigation for the largest risk and is never designed — **Medium, and this answers brief Q6**
§5:487 and R10 both make the enablement path *"enable per tenant after observing the WARN line in shadow mode."* Nothing in §5, §6, §7 or §8 designs a shadow mode. `assertCanReceiveStock` as specified simply returns early when the gate is off — it emits nothing. There is no would-have-refused log line, no file for it in §6, no test in §8, no verify row.

**So: the sysprop gate is *not* an adequate substitute for R3's missing measurement — it relocates the risk and removes the only route to retiring it.** It genuinely fixes the R10 half (rollback is now a sysprop flip, not a hotfix), which is real value. But with the gate default OFF and no shadow logging, Fix B ships inert, the 411,862-row exposure stays unmeasured forever, and the evidence needed to flip the gate can never be gathered by the system the plan builds. Either design shadow-mode logging (log-and-allow when the gate is off — cheap, and it makes R3 self-clearing per tenant), or keep R3 as a hard human prerequisite and drop the "shadow mode" language.

### N9 — Fix A's code shape is specified three different ways — **Medium**
- §5:399-403 normative "after" block: `Optional` + `isEmpty()` + `throw`.
- §5:427 (the M12 correction, two lines later): *"Use the concise `.orElseThrow(() -> new BusinessException(...))` form at **both** sites; the verbose `Optional` + `isEmpty()` shape is unnecessary."*
- §7.2 step 2: *"`Optional` + `isEmpty()` + keyed `BusinessException`."*

M12's factual correction landed; it was not propagated into the code block it invalidates or into the implementation steps. `A1a`/`A1b` are shape-agnostic, so nothing catches it.

### N10 — Fix D's two named acceptance criteria have no verify row — **Medium**
§5 Fix D specifies the exact toast (`Container ${label} is not available to receive stock`) and mandates **fail OPEN** on a probe error, and §8.4 asserts both. I built a shadow with the probe failing **CLOSED** (`return false` in the catch — the precise `stockUnits.js:215-218` bug the plan cites) and the toast reduced to `'Invalid container'`. **42 pass / 3 fail — identical to correct.** D1/D2/D4 are token greps; D3 (correctly) only checks placement. There is no mobile-Jest row and no `MOBILE_TEST` file variable anywhere in the script.

### N11 — `%2$s` is still undefined for the one *ungated* branch — **Medium**
`transferStockDestinationNotUsable=Container %1$s is %2$s and cannot receive stock.` The lock branch is fine (`getCodeText`, verified). The **Nirvana sentinel** has `entity_lock=0`, so the lock branch does not fire and the location branch must supply `%2$s` — and no section says what it is. This compounds with PM-5/R13: `BusinessException(String)` is more specific than `BusinessException(String, Object...)` for a single-String call, so an implementer who omits the second parameter silently gets `key="placeholder"` and every `getKey()` assertion fails at runtime rather than at compile time. Separately, `K3` only greps `%1`; I removed `%2$s` from both bundles and got **42 pass / 3 fail**.

### N12 — §6 omits the artifacts the sysprop step requires — **Medium**
§7.1 warns that `los_sysprop.description` is `varchar(255)` and §7.2 step 4a says "seed the row `false` for every tenant" — that is a Flyway migration. §6's File Change Summary lists **no** `db/migration/V*.sql` and no `SyspropService` wiring. (Otherwise §6 *does* cover every file the script's path variables require — `$ELIG`, `$ADVICE`, `$TEST_ELIG`, `$MOB_STORE`, `$WEB_VUE` are all listed. This is the one gap.)

### N13 — §7.2 step order is self-contradictory — **Medium**
Steps run 1, 2, 3, 4, 5, **4a**, 6a, 6b, 7, 8, 9. Step 4a is printed after step 5 but its own text says it *"Ships **before** step 4's guard so the guard is inert on arrival."*

### N14 — §14 is now stale and misleading — **Medium**
§14 still enumerates C1-C10 as live findings and §14.3 still reads *"Items C1-C4, C9, C10 plus the Critic's M2/M5/M7 are prerequisites for the TDD gate. The gate is held."* Most of those are now addressed in the body. There is no discharge column and no iteration-2 section. A reader (or the TDD gate) cannot tell what is open. The frontmatter `status:` and the §14 verdict also still say "ITERATE — NOT implementation-ready", which is correct today but will be the wrong signal the moment the remaining items land.

### N15 — `A4` is a bare negation defeated by a rename — **Medium**
`file_not_contains 'defaultUnitLoadType\.get\(\)'`. I renamed the local to `defaultUlt`, left the unguarded `.get()` intact, and padded the comment count. **42 pass / 3 fail.** Assert the guard exists, not that one spelling is absent.

### N16 — `mvn_test_passes` greens on a test class with zero tests — **Low/Medium**
`mvn test -Dtest="$1" -DfailIfNoTests=false | grep -qE "BUILD SUCCESS|Tests run:.*Failures: 0.*Errors: 0"` — the alternation means `BUILD SUCCESS` alone suffices, and `-DfailIfNoTests=false` makes an empty or nonexistent class a successful build. `T1`/`T2` require the files to exist; a file with no `@Test` still scores M1/M2 green.

### N17 — script header baseline is wrong — **Low**
Line 40: `Result: 4 pass, 38 fail, 1 skip`. Measured: **41 fail**. §8.7 says 41. Same class of stale-comment drift as M22.

### N18 — §12 Q3 still says "~18" — **Low**
Contradicts §5 Fix E's corrected "12 of 13 mobile / 30+ web / 42+". M21 half-applied.

### N19 — the split tickets are unverified — **Low**
`SBDEV-2995` and `SBDEV-2996` are cited as the destination for the Nirvana data-loss path and the second endpoint, and SBDEV-2995 is the stated reason the Nirvana refusal is ungated. Neither has a plan file in `1-Projects/wms2/plan/` nor a README entry. Confirm they exist in ClickUp before treating M1's discharge as complete.

### N20 — the default-OFF gate makes the web toast reword a small regression — **Low**
W1/W2 are ungated, so on delivery the desktop says "Container is not available to receive stock" for a container that simply *does not exist* — strictly less precise than today's "Container does not exist", for zero gain until someone flips the sysprop. It also voids §7.1's deploy-order argument at the default setting (with the gate off the probe rejects nothing extra, so API-first manufactures no untruth). The web-first order is still right for the eventual enable; the *rationale* as stated no longer applies to the shipped default.

### N21 — one constant name exists only in the script — **Low**
`K4` requires `MSG_TRANSFER_DESTINATION_NOT_USABLE`. The plan names `MSG_TRANSFER_DESTINATION_UNITLOAD_NOT_FOUND` and `..._LOCATION_NOT_FOUND` in code blocks and says "3 message-key constants" in §6, but never spells the third.

---

## 3. TESTABLE ACCEPTANCE CRITERIA — could a gate write failing tests from §8?

**Mostly yes** — a big improvement. §8.1's thirteen rows, §8.2's seven, §8.4's five are concrete, name their assertion, and now correctly say which existing tests must be *written* vs *kept green*. `entityNotFoundStillMapsTo404_onTheUnnettedPath` is a genuinely good compensating control for D1.

**Still under-specified, in order of how much a gate would have to invent:**
1. `%2$s` for the Nirvana branch (N11) — the gate cannot write `existingContainer_nirvanaDestination_throwsBusinessException`'s parameter assertion.
2. The gate-OFF pass-through test §5 promises and §8.1 omits (N6). What *is* the behaviour with the gate off — `canReceiveStock` returns true for a Shipped UL? For a To-Delete UL? Unstated.
3. `assertCanReceiveStock`'s behaviour when `storagelocationId` is null. §5 pins the *predicate* as total; the *throwing* form's null contract is never stated.
4. Fix A's code shape (N9) — three answers.
5. `checkContainer`'s return contract in the mobile store: §5 says "returns a boolean" and "fail open", §8.4 tests `ok === false`; whether a probe error returns `true`, `undefined`, or throws is not pinned.
6. The sysprop's read path: `SyspropService` method name, default when the row is absent, per-client vs global (`findBySyskeyAndClientId` is the shape used elsewhere in this very method).

---

## 4. VERIFY SCRIPT — full audit

**Working and genuinely discriminating** (each confirmed by a targeted mutation): `C1`, `C2`, `C4`, `D3`, `W1`, `W2`, `P1`, `P2`, `P3`, `K1`, `K2`, `K4`, `A1a`, `A1b`, `A2a`, `A2b`. The `file_contains_within` env-passing fix is correct — I confirmed `@PostMapping`/`@ExceptionHandler` patterns now traverse. `method_slice` is a good idea and works everywhere except B8's `^` anchor.

**Permanently red regardless of implementation:** `B8`, `B12`, `B13`.

**Demonstrated false-GREEN on a near-miss wrong implementation:**

| Mutation | Row that should catch it | Score |
|---|---|---|
| `DestinationEligibilityService` is an empty stub, branches in `// TODO` comments | B1-B7, B9-B11 | 42 pass |
| Nirvana refusal moved *behind* the sysprop gate (SBDEV-2995 stays open) | B13 | 42 pass |
| `:157` blanket-converted + the plan's own prescribed comment | A3 | 42 pass |
| `e.getMessage()` routed through a local variable | C3 | 42 pass |
| unguarded `.get()` kept, local renamed | A4 | 42 pass |
| mobile probe fails **CLOSED** + wrong toast copy | (none exists) | 42 pass |
| `%2$s` dropped from `…NotUsable` in both bundles | K3 | 42 pass |

**Correctly caught:** catch removed from `transferStock` (C1/C2/C3 → 39 pass); advice log line deleted (C4 → 41 pass); probe hoisted out of the `existing` block (D3 → 41 pass); web toast unreworded (W1/W2 → 40 pass).

**Residual weakness, not demonstrated but structural:** `T3`, `T4`, `T6`, `T7`, `T8`, `B8b`, `D1`, `D2`, `B11` are single-token `file_contains` calls that a comment satisfies. `T8` in particular is the entire mechanism making R1 falsifiable and is satisfied by the string `ListAppender` appearing anywhere in a 1000-line test file.

The §8.7 write-up's "lesson" — that only a family of near-miss wrong shadows proves the absence of false-greens — is the right lesson, correctly stated. It was applied to six mutations and then stopped one family short: nothing tested an *absent or stubbed* implementation of the new file, and nothing tested the two rows that do not exist.

---

## 5. PRE-MORTEM ADEQUACY — **adequate for DELIBERATE mode**

Five scenarios, each with a mechanism, a today-provable artifact, and a derived risk row. PM-1 is the standout: it identifies that Fix B's probe would re-create this ticket's own bug on the desktop, and cites `StockUnitControllerUnitTest:1030-1044` as the proof available *right now*. PM-3 and PM-4 are real interaction failures a per-row register cannot produce.

Two gaps worth adding rather than blockers: (a) no scenario where the sysprop gate is never enabled and Fix B is dead code for a year — which is the most likely outcome given N8; (b) no scenario where SBDEV-2995/2996 are never filed and the split scope is simply lost.

---

## 6. WHAT WOULD MAKE THIS APPROVABLE

1. **Define `check_B12` and `check_B13`; fix `B8`'s `^` anchor (`/sm`) and drop the `.get()` blanket forbid.** Then re-baseline and re-state §8.7's numbers. (N1, N2)
2. **Re-run the six existing wrong shadows plus these four**: empty-stub eligibility service, gated-Nirvana, `e.getMessage()`-via-local, mobile probe fail-closed. Every one currently scores as correct. (N3, N5, N10, and B13)
3. **Replace `A3`'s line count** with something a comment cannot inflate — e.g. `grep -c 'new EntityNotFoundException('` on a code-only slice, or per-site pins on the four internal literals. (N4)
4. **Make the sysprop real end-to-end**: the gate-OFF pass-through test §5 already claims exists, a `db/migration` row in §6, and either a designed shadow-mode WARN or the removal of the phrase. (N6, N8, N12)
5. **Reconcile R3**: is the production measurement a hard prerequisite, or does the gate discharge it? Assign an owner either way. (N7)
6. **Resolve the Fix A shape** in §5's code block and §7.2 step 2; reorder step 4a. (N9, N13)
7. **Specify `%2$s` for the Nirvana branch** and extend `K3` to check it. (N11)
8. **Fix §8.6 M4/M5** to state the sysprop must be enabled, or mark them gate-dependent — as written they cannot pass on a default deployment.
9. **Rewrite §14 with a discharge column**, and correct the two residual stale numbers (script header `38`, §12 Q3 `~18`). (N14, N17, N18)
10. **Confirm SBDEV-2995 and SBDEV-2996 exist.** The Nirvana refusal is ungated *because* 2995 exists; if it does not, that argument is circular. (N19)

Files referenced (absolute):
- `/home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-2994-move-stock-unknown-destination-container-generic-error.md`
- `/home/nampark/dev/wms-claude/sbdocs/9-System/scripts/verify-SBDEV-2994-move-stock-unknown-destination-container-generic-error.sh`
- Shadow trees used for the mutation testing: `/tmp/claude-1000/-home-nampark-dev-wms-claude/009d04f4-ec21-44a5-8ee4-7b54fc0d80bc/scratchpad/{sh0,ok,wA3,wA4,wB,wC,wC1,wC4,wD,wD3,wK3,wNirv,wW}`