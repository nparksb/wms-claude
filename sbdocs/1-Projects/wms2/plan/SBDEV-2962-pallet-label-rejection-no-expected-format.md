---
title: "SBDEV-2962 — pallet-label rejection gives the operator no recoverable information"
ticket: "SBDEV-2962"
ticket_url: "https://app.clickup.com/t/868krfjcx"
type: bugfix
priority: low-medium
status: implemented
project: [wms2]
version: v2
requester: nam.park@siteboss.net
created: 2026-08-14
updated: 2026-08-14
db_verified: true
review_state: "r3 — implemented; critic APPROVE WITH CHANGES + code-reviewer APPROVE + verifier PASS, all applied"
related:
  - "../../../3-Resources/reports/260814-hydra-uat-three-flow-qa-triage.md"
  - "./SBDEV-2961-order-release-silent-section-exclusion.md"
  - "[[wms2-sysprop-catalog]]"
  - "[[wms-exception-taxonomy]]"
tags:
  - plan
  - bugfix
  - wms2
  - mobile
  - palletizing
  - error-messages
---

# SBDEV-2962 — pallet-label rejection gives the operator no recoverable information

**Ticket:** [SBDEV-2962](https://app.clickup.com/t/868krfjcx)
**Project:** wms2 | **Version:** v2 (`v2/wms2-api` only) | **Type:** bugfix
**Priority:** Low–Medium — no data risk; blocks an operator from self-recovering, and blocked QA once
**Status:** implemented (r3) — PR #160 open, awaiting review
**Date:** 2026-08-14 | **Branch:** `bugfix/SBDEV-2962-expected-label-format-in-error`

> **Review provenance.** r1 authored inline; the `ralplan` consensus loop was not run, on the reasoning that a
> bundle edit plus a second argument at six call sites sits near the skill's mechanical exception. **A `critic`
> lane then ran over r1 and that reasoning did not survive it** — verdict *APPROVE WITH CHANGES*, with two High
> findings that would each have shipped:
>
> 1. **§6.1/§8.1 mandated asserting on `BusinessException.getParameter()`, which does not exist.** Zero hits
>    repo-wide; the field has no getter. The TDD gate would have hit a compile wall on its first `mvn` run.
> 2. **The fix as specified produced a self-contradictory message on every tenant checked.** The accept
>    condition is *two* OR'd regexes and r1 surfaced only one, so the message would have shown an example
>    (`AOUT-000001`) beside a pattern that example does not match. r1 had written the contradiction into its own
>    §6.3 expected value — and the triage report §2.2 had already flagged the exact distinction the plan lost.
>
> Both are fixed in r2 (§3.2, §3.3, §6.1, §8.1), together with six Mediums. Every finding was re-verified
> against the code before being applied, and the critic's own §6.5 correction — that
> `MobileTruckLoadingServiceTest.testCheckPalletWithInvalidPattern` already exists and is already an executing
> gate for C5 — turned into a free Maven gate row rather than just a retraction.
>
> **The lesson, recorded because it recurs:** three separate times in this plan I specced a *new* test class or
> claimed *absent* coverage where the class already existed (`StringConverterUnitTest`,
> `BusinessExceptionUnitTest`, `MobileTruckLoadingServiceTest`). Grep the test tree before writing §6, not
> after. "Small change" was the wrong reason to skip the second lane; the change is small, the *plan* was not
> correct.

---

## 0. Affected sites (enumeration before drafting)

`noValidString` is a **shared** key. Enumerated by grep, not memory.

| # | File:line | What it validates | Patterns in scope at that line | In scope? |
|---|---|---|---|---|
| 1 | `mobile/MobilePalletizingService.java:189` | `scanPallet` — pallet label null/empty | **none yet** (sysprops read later at `:222-223`) | **yes** (C1) |
| 2 | `mobile/MobilePalletizingService.java:227` | `scanPallet` — new pallet, matches neither pattern | `pattern`, `printingPattern` ✅ | **yes** (C2) |
| 3 | `mobile/MobilePalletizingService.java:282` | `scanPalletBulk` — pallet label null/empty | **none yet** (read at `:304-305`) | **yes** (C3) |
| 4 | `mobile/MobilePalletizingService.java:309` | `scanPalletBulk` — new pallet, matches neither | `pattern`, `printingPattern` ✅ | **yes** (C4) |
| 5 | `mobile/MobileTruckLoadingService.java:129` | pallet label vs the same two pallet patterns | `pattern`, `printingPattern` ✅ (`:124-125`) | **yes** (C5) |
| 6 | `mobile/MobileMoveStockService.java:299` | **a destination**, vs `STRING_PATTERN_SEPARATE_STOCK` | `pattern` only ✅ (`:296`) | **yes** (C6) |
| 7 | `resources/messages_en_US.properties:324` | `noValidString=String is not valid: '%1s'` | — | **yes** (A) |
| 8 | `resources/messages.properties` | key **absent** (parent bundle) | — | **no** — §8.2, systemic not local |
| 9 | `util/StringConverter.java:5-17` | `convertFormatToRegex` | — | **yes** (B — new helper alongside); ⚠ existing method has an unrelated latent bug, §8.3 |
| 10 | `service/ReceivingService.java:609` | throws `noValidStringForCartOrInboundPallet` — a **different** key | — | **no** — different key, already names its context |
| 11 | `v1/wms-api` — same 6 sites, same message text | identical defect | — | **no** — v2 only by user decision (§4) |

Every in-scope row maps to a POSITIVE check in §9.1.

---

## 1. Problem Statement

Scanning a pallet label that the tenant's configured patterns do not accept fails with:

```
String is not valid: 'TEST1'
```

The message echoes what the operator typed and **never states what would have been accepted**. On the mobile
palletizing screen there is also no way to obtain a valid label — `scanPallet.vue:43` sends the raw scanned
value with no "next label" affordance — so the operator cannot self-recover and has to ask an engineer to read
the sysprops.

### 1.1 How it surfaced

Ibrar (QA), Hydra UAT, 2026-08-12: *"When I try to palletize the Club Line order, the system displays the
error 'String is not valid.'"* Diagnosing it required a DB query. Triage:
[260814-hydra-uat-three-flow-qa-triage.md](../../../3-Resources/reports/260814-hydra-uat-three-flow-qa-triage.md) §2.

The club order itself was fine (`state = 650 PACKED`, batch at `530`), and **no `Pallet` unit load was created
that day** — the label was simply rejected.

### 1.2 DB verification (`db_verified: true`)

Live read of `los_sysprop` on Hydra UAT (`wh01_hydra_v2`). These four values are what the fix must surface:

| Sysprop | Value | Used by |
|---|---|---|
| `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL` | `AOUT-%1$06d` | rows 2, 4, 5 — and it is **positional** (`%1$06d`), so it formats an example cleanly |
| `STRING_PATTERN_OUTBOUND_PALLET` | `WC_\d{16}\|OUT-\d{6}\|OUT\d{6}` | rows 2, 4, 5 |
| `STRING_PATTERN_SEPARATE_STOCK` | `SU-\d{6}` | row 6 — **a different pattern**, which is why one hard-coded format in the message would be wrong |
| `SEQUENCE_NAME_DEFAULT_OUTBOUND_PALLET_LABEL` | `PALLET_OUTBOUND` | the generator (out of scope, §8.4) |

So an operator on this tenant needed `AOUT-######`, `OUT-######`, `OUT######`, or `WC_<16 digits>` — none of
which the message mentioned.

### 1.3 Reproduction

1. Mobile → Palletizing. Scan a parcel on an order at `state >= PACKED`.
2. For the pallet, enter `TEST1`.
3. `String is not valid: 'TEST1'` — with no indication of what would work.

---

## 2. Root Cause Analysis

### 2.1 The message has no slot for the expected format

`resources/messages_en_US.properties:324`:

```properties
noValidString=String is not valid: '%1s'
```

Resolved by `BusinessException.resolveMessage` (`:65-107`) via
`ResourceBundle.getBundle("messages", Locale.getDefault())` then **`String.format(message, parameter)`**
(`:99`).

Two mechanics matter:

- **`BusinessException(String key, Object... parameter)` (`:49`) is varargs**, so a second argument needs **no
  signature change** anywhere.
- **`%1s` is not a positional specifier.** It is `%s` with minimum width 1. Format specifiers consume
  arguments *sequentially*, so `%1s … %2s` would in fact work — but only by accident, and it reads as
  positional to every future maintainer. The fix uses explicit `%1$s` / `%2$s`, which is also the convention
  the sysprop value itself already uses (`AOUT-%1$06d`).

### 2.2 One key, three different valid formats

The same key is thrown from six places covering **three** distinct pattern sources (§0). Rows 2/4/5 validate
against the two outbound-pallet patterns; row 6 validates a *destination* against
`STRING_PATTERN_SEPARATE_STOCK`. **A single hard-coded "Expected format: AOUT-######" in the bundle would
therefore be wrong for `MobileMoveStockService`** — which is precisely why the format has to travel as an
argument from the call site rather than live in the message text.

### 2.3 A missed call site degrades, it does not crash

Once the message references `%2$s`, a call site still passing one argument raises
`MissingFormatArgumentException`. That is **caught** — `resolveMessage:100` catches `IllegalFormatException`
and falls back to `concatenateKeyAndParameter`, so the operator would see:

```
noValidString, 'TEST1'
```

No 500, but strictly worse than today. **The bundle edit and all six call sites must land in the same
commit**, and §9.1 asserts the count is exactly 6.

---

## 3. Fix Design

### 3.1 Fix A — the message gains an expected-format slot

`resources/messages_en_US.properties:324`:

```diff
-noValidString=String is not valid: '%1s'
+noValidString=String is not valid: '%1$s'. Expected format: %2$s
```

Positional specifiers, deliberately. `%1s`/`%2s` would behave identically today but mislead the next reader
into thinking they are positional; `%1$s`/`%2$s` are unambiguous and cannot be reordered by accident.

> **The width claim is confirmed by production behaviour, not just by a probe.** At the TDD gate, the C1
> empty-label path rendered `String is not valid: ' '` — a single space. That is `%1s` **padding an empty string
> to minimum width 1**, which is only possible if the `1` is a width and not an argument index. `%1$s` would have
> rendered `''`. So the current message is not merely unhelpful for an empty scan, it is actively confusing, and
> Fix A repairs that as a side effect.

### 3.2 Fix B — one helper to describe the expected format

New method on `util/StringConverter.java` (18 lines today, the natural home — it already owns
`convertFormatToRegex`):

```java
private static final int MAX_EXAMPLE_LENGTH = 64;

/**
 * SBDEV-2962 — human-readable "what would have been accepted", for the operator-facing error.
 *
 * <p>Returns a concrete EXAMPLE derived from the printing pattern where one exists (that is what a label
 * printer actually produces, so it is the most actionable thing to show), followed by EVERY accept pattern
 * the caller validated against. Varargs because the count differs by call site: palletizing and truck
 * loading accept a label matching EITHER the string pattern OR the converted printing pattern, while
 * MobileMoveStockService validates a destination against one pattern only.
 *
 * <p>MUST NOT THROW: this runs while building an error message. A bad sysprop must not replace a useful
 * validation error with a stack trace.
 */
public static String describeExpectedFormat(String printingPattern, String... acceptPatterns) {
    String example = null;
    if (printingPattern != null && !printingPattern.isBlank()) {
        try {
            // Locale.ROOT, not the default FORMAT locale: measured on JDK 21, a default of ar-EG renders
            // "AOUT-٠٠٠٠٠١" and fa-IR / bn-IN / th-TH-u-nu-thai / hi-IN-u-nu-deva likewise emit non-ASCII
            // digits. Useless to an operator, and it makes the unit test depend on the runner's locale.
            String rendered = String.format(Locale.ROOT, printingPattern, 1);
            // A large width does not throw, it ALLOCATES: "%1$5000000d" returns 5,000,000 chars. This
            // string reaches an operator message and BusinessException's LOG line, so bound it.
            example = rendered.length() > MAX_EXAMPLE_LENGTH
                    ? rendered.substring(0, MAX_EXAMPLE_LENGTH) + "…"
                    : rendered;
        } catch (RuntimeException e) {          // malformed sysprop — degrade, never propagate
            example = null;
        }
    }
    // LinkedHashSet: preserves caller order, and collapses the common case where the string pattern and
    // the converted printing pattern are identical so the operator is not shown the same regex twice.
    Set<String> accepted = new LinkedHashSet<>();
    if (acceptPatterns != null) {
        for (String p : acceptPatterns) {
            if (p != null && !p.isBlank()) {
                accepted.add(p);
            }
        }
    }
    String patterns = String.join(" or ", accepted);
    if (example != null && !accepted.isEmpty()) {
        return example + " (accepted: " + patterns + ")";
    }
    if (example != null) {
        return example;
    }
    return accepted.isEmpty() ? "(no label pattern configured for this warehouse)" : patterns;
}
```

Adds imports `java.util.Locale`, `java.util.LinkedHashSet`, `java.util.Set`.

On Hydra UAT this yields `AOUT-000001 (accepted: WC_\d{16}|OUT-\d{6}|OUT\d{6} or AOUT-\d{6})` for
palletizing and `SU-\d{6}` for move-stock.

> ⚠ **Both accept patterns, not one — this is a correction, and it is the whole point of the fix.** The
> accept condition at `MobilePalletizingService:226`/`:308` and `MobileTruckLoadingService:128` is
> `!label.matches(pattern) && !label.matches(convertedPrintingPattern)` — the label is accepted if it
> matches **either**. An earlier revision passed only `pattern`, which produced a **self-contradictory
> message**: the example is derived from the *printing* pattern, so on Hydra it would have read
> `AOUT-000001 (pattern: WC_\d{16}|OUT-\d{6}|OUT\d{6})` — an example that does not match the pattern printed
> beside it. Confirmed against live sysprops on hydra-uat and wineco-dev. The triage report §2.2 had already
> flagged exactly this (`AOUT-000119` is valid *via the printing pattern*, not the string pattern) and the
> plan lost it. `convertedPrintingPattern` is **already a local** at `:224`, `:306` and `:126`, computed
> before the throw, so passing it costs nothing and — unlike recomputing it inside the helper — cannot widen
> the §8.3 exposure, because the caller's own call already succeeded by the time we are in the error path.

**Why an example plus the raw patterns, rather than a prose translation of the regex.** Translating
`WC_\d{16}|OUT-\d{6}|OUT\d{6}` into "WC_ followed by 16 digits, or …" needs a regex-to-English converter —
more code than the fix, and wrong the first time a tenant configures a pattern shape it does not handle. The
example is what the operator needs; the raw patterns are what support needs. All are already strings.

### 3.3 Fix C — six call sites supply their own format

All three locals (`pattern`, `printingPattern`, `convertedPrintingPattern`) are already in scope at C2/C4/C5,
computed immediately above the throw.

| # | Site | Change |
|---|---|---|
| C2 | `MobilePalletizingService:227` | `new BusinessException("noValidString", palletLabel, StringConverter.describeExpectedFormat(printingPattern, pattern, convertedPrintingPattern))` |
| C4 | `MobilePalletizingService:309` | same; locals at `:304-306` |
| C5 | `MobileTruckLoadingService:129` | same; locals at `:124-126` |
| C6 | `MobileMoveStockService:299` | `…, dto.getDestination(), StringConverter.describeExpectedFormat(null, pattern))` — **one** accept pattern and no printing pattern: separate-stock destinations are validated against `STRING_PATTERN_SEPARATE_STOCK` alone (`:296-298`) |
| C1 | `MobilePalletizingService:189` | null/empty guard on `scanPallet` — the sysprops are not read here yet. Read **only `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL`** and pass `describeExpectedFormat(printingPattern)` — see the amendment below. **Reachable**: `PalletizingController.scanPallet` takes `@RequestBody PalletisingMobileDto` with no `@Valid`, so a null/blank label really does arrive. Error path only, so the read costs nothing (§7 row 4) |
| C3 | `MobilePalletizingService:282` | same edit as C1, in `scanPalletBulk`. ⚠ **Unreachable defensive code — keep it anyway.** Its only caller is `PalletizingController:93` `@GetMapping("/scanPalletBulk/{input}")` via `@PathVariable`, which can be neither null nor empty (an empty path segment does not match the route). It is updated **solely to preserve the count-of-6 invariant** that §9.1 asserts. Do not "optimise away" the two sysprop reads here — that breaks the count row, which is load-bearing |

**Deliberately unchanged:** `ReceivingService:609` throws `noValidStringForCartOrInboundPallet`, a different
key that already names its context (§0 row 10).

**Step order is not arbitrary, and the asymmetry is provable.** The old message with two arguments renders
fine (`String.format` ignores extra arguments), so **Fix C without Fix A is harmless**; the new message with
one argument degrades (§2.3), so **Fix A without Fix C is not**. That is why §5.2 does helper → call sites →
bundle, and why steps 3–5 are one commit. Do not reorder them.

> ### ⚠ Amendment r3 — C1/C3 pass ONE argument, not three. Found while implementing.
>
> r2 (and the executor brief derived from it) told the implementer to read **both** sysprops at C1/C3 and pass
> `describeExpectedFormat(printingPattern, pattern, convertedPrintingPattern)`. **Implementing that literally
> would have introduced a new HTTP 500.**
>
> `StringConverter.convertFormatToRegex` throws **unchecked** on a malformed printing-pattern sysprop (§8.3),
> and `PalletizingController:77-81` catches only `BusinessException` and `FacadeException`. At **C2/C4/C5** that
> is harmless: `convertedPrintingPattern` is an existing local computed *before* the throw, so by the time the
> error path runs, the call has already succeeded — which is exactly the reasoning §8.3 uses to claim "this plan
> does not widen the exposure." **At C1/C3 there is no pre-existing call on that path.** Adding one would mean a
> malformed sysprop turns an empty-label *business* error into a 500 — falsifying §8.3's own claim.
>
> **Implemented instead:** C1/C3 read only `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL` and call
> `describeExpectedFormat(printingPattern)`, yielding `Expected format: AOUT-000001` — the concrete example with
> no regex beside it. For an empty scan the example is the actionable half; there is nothing to diagnose, so the
> accept regexes add nothing. Fewer sysprop reads, no new throw path, and the C1 gate test
> (`…whenLabelIsEmpty`, asserting the message contains `AOUT-000001`) passes unchanged.
>
> **The acceptance criteria had already encoded this shape**, which is the strongest evidence it is right rather
> than merely convenient: §9.1's `C_both_patterns` expects **3** `convertedPrintingPattern` arguments (C2 + C4 +
> C5), not 5, while `C_pallet_four` expects **4** `describeExpectedFormat` calls in the palletizing service. Both
> passed without modification. The §3.3 prose was wrong; the verify rows were right.

---

## 4. V1/V2 Applicability

**v1 has the identical defect and is explicitly OUT OF SCOPE** — user decision, 2026-08-14, consistent with
SBDEV-2961.

| Site | v1 | v2 |
|---|---|---|
| `noValidString` throwers | `MobilePalletizingService.java:142,185,223,252`, `MobileTruckLoadingService.java:105`, `MobileMoveStockService.java:293` | `:189,227,282,309`, `:129`, `:299` |
| Message text | `messages_en_US.properties:319` — byte-identical | `:324` |

**Recorded consequence:** v1 operators keep the unhelpful message, with nothing tracking it. If that changes,
the counterpart plan reuses this base name under `sbdocs/1-Projects/wms1/plan/`.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| Concern | Required? | Detail |
|---|---|---|
| DB state | **No** | Reads existing sysprops; no new key, no seed, no migration |
| Flyway | **No** | Do not allocate a `V2.2.x` |
| Sysprops | **No** | All four already exist on every tenant (§1.2 verified) |
| Config / env | **No** | — |
| Deploy order | **No** | Single repo, single PR |
| External systems | **No** | Operator-facing text only; no OMS contract |
| Access | Yes | Hydra UAT for the §6.3 manual check |
| Monitoring | **No** | No new failure mode; the message is an existing path |

### 5.2 Implementation checklist

1. Branch `bugfix/SBDEV-2962-expected-label-format-in-error` off freshly-fetched `origin/develop`.
2. **Run the verify script; record the FAIL baseline** (non-zero expected).
3. Fix B — `StringConverter.describeExpectedFormat`.
4. Fix C — all six call sites, **in one commit with step 5** (§2.3: the bundle edit alone degrades every
   un-updated site).
5. Fix A — the bundle string.
6. `mvn -o clean test-compile`.
7. Unit tests (§6.1), **one class per invocation** — a multi-class `-Dtest` let a green sibling satisfy the
   run-count check for a class that did not exist (§9.1 defect 2): `StringConverterUnitTest`,
   `BusinessExceptionUnitTest`, `MobilePalletizingScanPalletFormatTest`, `MobileMoveStockFormatTest`,
   `MobileTruckLoadingServiceTest`.
8. `mvn -o test` full suite. **Expect exactly 2 pre-existing failures** (`OptionalSafetyArchTest`,
   `MobilePalletizingServiceTest`) — ⚠ note the second is a class this plan touches, so confirm its failing
   **method** is still only `testScanParcelBulkPalletAlreadyAssignedToGate` and that the count has not risen.
   **Revert the mutated tracked `archunit_store`.**
9. Re-run verify → `Result: N pass, 0 fail`.
10. Fill §6.4 and §9.2.

Steps 3–5 are one atomic commit.

---

## 6. Test Plan

### 6.1 Unit tests

**Extended — `StringConverterUnitTest`.** ⚠ Corrected during drafting: this class **already exists**
(`src/test/java/net/aim_ai/wms/unit/util/StringConverterUnitTest.java`, 4 tests in a `@Nested class
ConvertFormatToRegex`). Add a **sibling `@Nested class DescribeExpectedFormat`** rather than a new file, to
match the established shape.

⚠ **`-Dtest='StringConverterUnitTest#someMethod'` silently runs ZERO tests on a `@Nested` class and reports
success.** Always target the class. §9.1's Maven row does.

| Test | Asserts |
|---|---|
| `describeExpectedFormat_shouldReturnExampleAndBothPatterns_whenAllGiven` | `("AOUT-%1$06d", "WC_\\d{16}", "AOUT-\\d{6}")` → `AOUT-000001 (accepted: WC_\d{16} or AOUT-\d{6})`. **The H2 regression guard** — the one test that would catch dropping the second accept pattern again |
| `describeExpectedFormat_shouldNotRepeatIdenticalPatterns` | `("AOUT-%1$06d", "AOUT-\\d{6}", "AOUT-\\d{6}")` → the regex appears **once** (the `LinkedHashSet` collapse) |
| `describeExpectedFormat_shouldReturnPatternOnly_whenNoPrintingPattern` | `(null, "SU-\\d{6}")` → `SU-\d{6}` — the MoveStock shape |
| `describeExpectedFormat_shouldNotThrow_whenPrintingPatternIsMalformed` | `("AOUT-%1$q", "SU-\\d{6}")` → falls back to the pattern, **no exception**. Load-bearing: the helper runs inside an error path |
| `describeExpectedFormat_shouldBoundTheExample_whenWidthIsHuge` | `("%1$5000000d", "SU-\\d{6}")` → result ≤ ~80 chars. A large width does **not** throw, so `catch (RuntimeException)` cannot catch it |
| `describeExpectedFormat_shouldRenderAsciiDigits_regardlessOfDefaultLocale` | wrap in `Locale.setDefault(Locale.forLanguageTag("ar-EG"))` / restore in a `finally` → still `AOUT-000001`. Fails without `Locale.ROOT` |
| `describeExpectedFormat_shouldDegradeGracefully_whenBothMissing` | `(null, (String[]) null)` and `(null)` → the "(no label pattern configured…)" fallback, not `null` and not an NPE |

**New — `MobilePalletizingScanPalletFormatTest`** (a **new sibling class**, deliberately not the existing
`MobilePalletizingServiceTest`): that class carries one pre-existing failing method
(`testScanParcelBulkPalletAlreadyAssignedToGate`), so it can never report `Failures: 0` and therefore cannot
back a Maven gate row. A new class can. Mirror the existing class's `@ExtendWith(MockitoExtension.class)` +
`@InjectMocks` setup.

| Test | Asserts |
|---|---|
| `scanPallet_shouldIncludeExpectedFormat_whenLabelMatchesNoPattern` | C2. The thrown `BusinessException` has `getKey()` = `"noValidString"` and `getLocalizedMessage(Locale.US)` containing both the bad label and the example |
| `scanPallet_shouldNameBothAcceptPatterns_whenLabelMatchesNeither` | C2/H2. The rendered message contains **both** stubbed regexes |
| `scanPallet_shouldIncludeExpectedFormat_whenLabelIsEmpty` | C1 — the reachable null/empty path also supplies the format |

**Extended — `MobileMoveStockServiceTest`.** ⚠ **Corrected at the TDD gate — the fourth "already exists" in
this plan.** r2 specced a *new* `MobileMoveStockFormatTest`; the class already exists, already has
`selectDestination` coverage, and — unlike `MobilePalletizingServiceTest` — is **green on `develop`**, so it can
back a Maven gate row directly. Extending it is strictly better than a new class.

C6 is the site whose pattern divergence justifies the entire per-call-site design, and it had **no** automated
coverage — only manual row 3. Added `selectDestination_shouldNameItsOwnPattern_whenDestinationMatchesNothing`:
stub `STRING_PATTERN_SEPARATE_STOCK` = `SU-\d{6}`, `locationRepository.findByName(dest)` empty (so
`storageLocation` stays null and the flowbin branches are skipped), `unitloadRepository.findByLabelid(dest)`
empty, then assert the rendered message contains `SU-\d{6}` and **`doesNotContain("AOUT")` / `doesNotContain("OUT-")`** —
the negative half is what actually proves the shared key did not inherit a pallet format.

> ⚠ `selectDestination` needs `dto.setAmount("<numeric>")`: `new BigDecimal(Integer.parseInt(dto.getAmount()))`
> runs *before* the pattern check, so a null amount throws `NumberFormatException` and the test never reaches
> the assertion.

**Extended — `MobileTruckLoadingServiceTest`.** ⚠ Corrected during drafting: `testCheckPalletWithInvalidPattern`
(`:299-311`) **already exists**, already stubs both sysprops, and already asserts
`hasMessageContaining("String is not valid")`. Two consequences:

1. It is **already an executing gate for C5** — that substring survives Fix A only if Fix C is applied at
   that site, because a one-argument construction degrades to `noValidString, 'INVALID123'`. §9.1 gets a
   Maven row for this class (it has no pre-existing failures).
2. Extend it by one line to also assert the expected-format text, rather than adding a class.

### 6.2 Message-rendering test

**Extended — `BusinessExceptionUnitTest`** ⚠ (corrected: this class **already exists** at
`src/test/java/net/aim_ai/wms/unit/exceptions/BusinessExceptionUnitTest.java`; an earlier revision specced a
new `BusinessExceptionMessageUnitTest` beside it). Add:

- `new BusinessException("noValidString", "TEST1", "AOUT-000001")` → **`getLocalizedMessage(Locale.US)`**
  contains both `'TEST1'` and `AOUT-000001`. This is the only test that catches a bundle edit that renders
  the specifiers wrongly, or a `%2$s` left in with no argument wired.
- The §2.3 degradation: constructing with **one** argument must fall back to `noValidString, 'TEST1'` rather
  than throwing — proving the guard at `resolveMessage:100` still holds.

⚠ **Use `getLocalizedMessage(Locale.US)`, not `getMessage()`, for the positive case.** `getMessage():125`
delegates to `resolveMessage(null, …)` → `Locale.getDefault()`. On a JVM whose default is not `en_US`,
`ResourceBundle.getBundle("messages", locale)` resolves the **14-key parent** `messages.properties`,
`noValidString` misses, and the assertion fails **on correct code** (§8.2). `getMessage()` is fine for the
degradation case, which asserts the fallback text.

### 6.3 Manual test plan (MANDATORY)

| # | Scenario | Env | Steps | Expected | P/F |
|---|---|---|---|---|---|
| 1 | Palletizing, bad label | Hydra UAT | Mobile → Palletizing, scan a `PACKED` order's parcel, enter `TEST1` | `String is not valid: 'TEST1'. Expected format: AOUT-000001 (accepted: WC_\d{16}\|OUT-\d{6}\|OUT\d{6} or AOUT-\d{6})`. ⚠ **Check the example against the patterns shown** — `AOUT-000001` must match one of them. An earlier revision expected `(pattern: WC_\d{6}…)`, which was both a typo for `\d{16}` and, worse, an example that matched nothing listed (§3.2) | |
| 2 | Palletizing, empty label | Hydra UAT | same, submit an empty pallet field | Same expected-format text (C1) | |
| 3 | **Move stock shows its OWN format** | Hydra UAT | Mobile → Move Stock, enter a destination matching nothing | Expected format shows `SU-\d{6}`, **not** the pallet pattern. This is the row that proves the shared key did not get one hard-coded format | |
| 4 | Truck loading | Hydra UAT | Mobile → Truck Loading, bad pallet label | pallet expected-format text (C5) | |
| 5 | Happy path unaffected | Hydra UAT | Palletize with `AOUT-000119` | Succeeds; no behaviour change | |

### 6.4 Test execution (fill in after running)

| Command | Result |
|---|---|
| verify (pre) | _pending — expect non-zero_ |
| `mvn -o clean test-compile` | _pending_ |
| `mvn -o test -Dtest=StringConverterUnitTest` | _pending_ |
| `mvn -o test -Dtest=BusinessExceptionUnitTest` | _pending_ |
| `mvn -o test -Dtest=MobilePalletizingScanPalletFormatTest` | _pending_ |
| `mvn -o test -Dtest=MobileMoveStockFormatTest` | _pending_ |
| `mvn -o test -Dtest=MobileTruckLoadingServiceTest` | _pending_ |
| `mvn -o test` (full) | _pending — expect 2 pre-existing; confirm the `MobilePalletizingServiceTest` method set is unchanged_ |
| verify (post) | _pending — require `Result: N pass, 0 fail`_ |

### 6.5 Deliberately-skipped coverage

| Gap | Rationale |
|---|---|
| No mobile-UI test | No UI change in this plan (§8.4) |
| v1 | Out of scope (§4) |
| C3 (`scanPalletBulk` null/empty) has no test | The path is **unreachable** through its only caller (§3.3) — a test would have to call the service method directly to exercise code no request can reach. The count row in §9.1 is what keeps the edit honest |
| `MobilePalletizingServiceTest` is not a gate row | One pre-existing failing method, so the class can never report `Failures: 0`. The new assertions live in `MobilePalletizingScanPalletFormatTest` instead, precisely so a Maven row *can* gate them |

⚠ **Removed from this table during drafting:** "No test for `MobileTruckLoadingService` /
`MobileMoveStockService` call sites — covered by the verify script's per-site rows plus manual 3 and 4." Both
halves were wrong. `MobileTruckLoadingServiceTest.testCheckPalletWithInvalidPattern` already existed and is
already an executing gate for C5; and C6 — the site whose divergence justifies the whole design — was left
resting on one manual row, the weakest possible coverage for the plan's load-bearing claim. Both are now
tested (§6.1).

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Note |
|---|---|---|---|
| 1 | New in-JVM state | **No** | `describeExpectedFormat` is a pure static function |
| 2 | Connection pool math | **No** | C1/C3 add **one** `syspropService` read each, **on an error path only**; `SyspropService.getSysvalue(String)` is `@Cacheable`. ⚠ r2 said "two reads" — corrected per amendment r3 (found by the conformance lane, which spotted this row still disagreeing with the code). Note `unless = "#result == null"` means a *missing* key is never cached, so a rejected scan on an unconfigured tenant costs one round trip per scan — negligible on an error path |
| 3 | Scheduled jobs | **N/A** | — |
| 4 | Long transactions | **No** | Error path; no transaction held |
| 5 | Request affinity | **No** | Stateless request/response |
| 6 | Retry / idempotency | **No** | The change is text; a retried scan behaves as before |
| 7 | Tenant context | **Yes** | The format is derived from **per-tenant** sysprops, read inside the request's tenant context. Correct by construction: a hard-coded message could not have been tenant-correct, which is the point of Fix C |
| 8 | Distributed locks | **N/A** | — |
| 9 | Cache invalidation | **No** | Reads only; `SyspropService`'s cache already governs freshness |
| 10 | External notifications | **N/A** | — |

---

## 8. Notes

### 8.1 Landmine — `BusinessException` exposes only three accessors, and `getParameter()` is not one

⚠ **Corrected during drafting.** An earlier revision of this section and of §6.1 instructed the implementer to
assert on `getParameter()`. **That method does not exist** — a repo-wide grep for `getParameter()` in `src/`
returns zero hits. The field is `private Object[] parameter` (`BusinessException.java:40`) with no getter. The
complete accessor set is:

| Accessor | Line | Renders via |
|---|---|---|
| `getMessage()` | `:125` | `resolveMessage(null, …)` → **`Locale.getDefault()`** |
| `getLocalizedMessage(Locale)` | `:129` | the locale you pass |
| `getKey()` | `:145` | — |

So the parameters are observable **only** through a rendered message. Assert `getKey()` for structure and
`getLocalizedMessage(Locale.US)` for content. Do **not** add a `getParameter()` getter to production code to
satisfy a test — that widens the diff for no operator benefit, and `getLocalizedMessage(Locale.US)` already
proves what matters (the argument reached the message).

Two separate traps live here; keep them distinct:

1. `hasMessageContaining("noValidString")` **fails on a correct implementation**, because the rendered text is
   the human sentence, not the key. (Verify row `T_no_key_in_msg` guards this.)
2. `getMessage()` is **locale-dependent** and will miss on a non-`en_US` JVM — see §6.2 and §8.2.

### 8.2 The parent-bundle gap is systemic — noted, not fixed here

`resolveMessage` loads `ResourceBundle.getBundle("messages", Locale.getDefault())`. `noValidString` exists
only in `messages_en_US.properties`; `messages.properties` (the parent) does **not** have it. On a JVM whose
default locale is not `en_US`, the key misses and the operator already sees `noValidString, 'TEST1'` today.

**Measured: `messages.properties` holds 14 keys; `messages_en_US.properties` holds 350 — 325 keys exist only
in the child.** So this is a systemic bundle-layout issue, not a property of this key, and adding one of 325
here would be arbitrary without fixing the class. Every environment evidently runs an `en_US` default locale
or far more than this ticket would be broken. **Recommend a separate ticket** to either populate the parent or
rename the child to `messages.properties`; do not widen this plan.

### 8.3 Adjacent latent defect in the file being touched — recorded, not fixed

`StringConverter.convertFormatToRegex` (`:5-17`) does `format.split("-")` then indexes `split[1]` and
`substring(digitLen - 3, digitLen - 1)`. A malformed `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL` throws
**unchecked**, on the palletize path. The escape route is confirmed: `PalletizingController:77-81` catches only
`BusinessException` and `FacadeException`, so a `RuntimeException` becomes **HTTP 500** rather than a business
error. Measured shapes:

| Sysprop value | Throws |
|---|---|
| `AOUT%1$06d` (no `-`) | `ArrayIndexOutOfBoundsException` |
| `A-` (too short) | `ArrayIndexOutOfBoundsException` |
| `AOUT-%1$6d` | **`NumberFormatException`** — `parseInt("$6")`; missing from an earlier revision of this list |
| short digit segment | `StringIndexOutOfBoundsException` |

Not triggered on any current tenant (all reachable tenants use the `X-%1$06d` shape), so it is latent.

Out of scope per the message-only decision. **This plan does not widen the exposure**: `describeExpectedFormat`
never calls `convertFormatToRegex`, and the H2 fix passes the caller's *already-computed*
`convertedPrintingPattern` rather than recomputing it — so by the time the helper runs, that call has already
succeeded. But **the new helper must not repeat the mistake** — hence its `try/catch (RuntimeException)`.
Worth its own ticket.

⚠ Note for whoever takes that ticket: hardening `convertFormatToRegex` with its own
`catch (RuntimeException)` would turn verify row `B_guarded` green **without** the new helper being guarded, if
that row were file-scoped. §9.1 scopes it to the helper body for exactly this reason.

### 8.4 Resolved decisions

| # | Question | Decision | Rationale |
|---|---|---|---|
| 1 | How should the message carry the format, given one shared key and three patterns? | **Per-call-site argument**, one key, `%1$s`/`%2$s` | User, 2026-08-14. A hard-coded format would be wrong for `MobileMoveStockService` (§2.2) |
| 2 | Also give mobile a way to obtain a valid label? | **No — message only; generation is a follow-up ticket** | User, 2026-08-14. The generator already exists (`BillofladingService:774-779` — `SEQUENCE_NAME_DEFAULT_OUTBOUND_PALLET_LABEL` + `getNextSequenceNumber` + `String.format`), so exposing it later is cheap. **A follow-up ticket must be filed** — the ticket's own complaint is "cannot self-recover", which this plan only partly addresses |
| 3 | Scope: v1 too? | **v2 only, v1 explicitly out of scope** | User, 2026-08-14. §4 records v1 stays affected and untracked |
| 4 | Positional or width specifiers in the bundle? | **Positional `%1$s`/`%2$s`** | Plan decision. `%1s`/`%2s` work by sequential consumption but read as positional — a trap. Matches `AOUT-%1$06d`'s own convention |
| 5 | Show a prose translation of the regex? | **No — example + raw pattern** | Plan decision (§3.2). A regex-to-English converter is more code than the fix and wrong on the first unanticipated pattern shape |

### 8.5 v2-only constraint checklist

| # | Constraint | Verdict | Where |
|---|---|---|---|
| 1 | OSIV disabled | **N/A** | No entity or lazy association touched |
| 2 | `tenantTransactionManager` | **N/A** | No `@Transactional` added; error path only |
| 3 | `readOnly = true` | **N/A** | No new service read method |
| 4 | Caffeine invalidation | **N/A** | Reads cached sysprops; writes nothing |
| 5 | Jakarta namespace | **N/A** | No new imports |
| 6 | H2-compatible test SQL | **N/A** | No SQL; all new tests are pure-unit |
| 7 | `BaseControllerTest` | **N/A** | No controller change |
| 8 | Micrometer | **No** | No new failure mode to measure; the throw already existed |

### 8.6 Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | ✓ §1.2 — all four sysprops read live from `wh01_hydra_v2`; `db_verified: true` |
| 1 | All callsites enumerated | ✓ §0 — 11 rows; all 6 throwers + the bundle + the helper in scope |
| 2 | Adjacent bugs | ✓ §8.2 (parent-bundle gap, 325 keys), §8.3 (`convertFormatToRegex` unchecked throws), §0 row 10 (different key, excluded) |
| 3 | Backward compatibility | ✓ Operator-facing text only. No API, schema, or payload change. The `BusinessException` **key stays the same**, so any client matching on `getKey()` is unaffected; only the rendered sentence changes |
| 4 | Concurrency | ✓ §7 rows 4, 6 — pure function on an error path, nothing shared |
| 5 | Multi-tenant | ✓ §7 row 7 — the format is per-tenant by construction, which is the reason for the argument |
| 6 | Error handling | ✓ §2.3 — a missed site degrades via the existing `IllegalFormatException` guard rather than throwing; §6.2 pins that. The helper cannot throw (§3.2) |
| 7 | Observability | ✓ No new failure mode. `BusinessException:60` already logs `key=… params=…`, and the second parameter now appears there too — a small diagnostic gain |
| 8 | Rollback / migration | ✓ §5.1 — no Flyway, no sysprop, no data. Revert is a plain code revert |
| 9 | Test coverage | ✓ §6.1 (4 + 2 unit), §6.2 (rendering + degradation), §6.3 (5 manual), §6.5 (gaps named) |
| 10 | Cross-version | ✓ §4 — **no**: v1 out of scope by explicit user decision |

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2962-pallet-label-rejection-no-expected-format.sh`

Run **before** any change (expect non-zero) and **after** (require `Result: N pass, 0 fail`).

| Check | Kind | Asserts |
|---|---|---|
| `A_message_has_format_slot` | positive | bundle line carries `%2\$s` |
| `A_message_positional` | positive | uses `%1\$s`, not bare `%1s` |
| `A_old_message_gone` | negative | the old `'%1s'`-only form is gone |
| `B_helper_exists` | positive | `describeExpectedFormat` on `StringConverter` |
| `B_helper_guarded` | positive | a `catch (RuntimeException` inside it — it must not throw on an error path |
| `C_all_six_sites` | **count** | exactly **6** `noValidString` throws, and **6** of them pass a second argument. The count is the point: five updated sites plus one missed one is worse than today (§2.3) |
| `C1`–`C6` | positive | each named file contains `describeExpectedFormat` |
| `C6_movestock_own_pattern` | positive | `MobileMoveStockService` passes `null` as the printing pattern — proving it did not inherit the pallet format |
| `T_*` | positive | the three test classes exist and name the malformed-pattern and one-argument-degradation cases |
| `M_*` | maven | `-o`; require `BUILD SUCCESS` **and** `Tests run: [1-9]…Failures: 0, Errors: 0, Skipped: 0` |

**Helper hardening carried over from SBDEV-2961** (each of these was a real false green there): guard
`file_not_contains` with `[ -f "$2" ] || return 1`; strip comment lines before counting, or a Javadoc
mentioning the symbol satisfies the row; use `-o` on every `mvn` call, because concurrent runs sharing
`~/.m2` turn all Maven rows red at once and that looks like a defect; never `-q`, which suppresses both
`BUILD SUCCESS` and `Tests run:`.

**Baseline, measured on unfixed `develop` (2026-08-14) — `Result: 9 pass, 30 fail, 1 skip`, exit 1**, run in
full **without** `SKIP_MVN`, and re-confirmed from a stripped `env -i` shell so the toolchain resolution is
proven rather than inherited. All nine greens are must-not-regress guards, not completed work:

| Green at baseline | Why it is a guard, not progress |
|---|---|
| `C_six_throws` | the 6 throw sites still exist — the count is the invariant |
| `T_conv_exists`, `T_msg_exists` | **both test classes already existed** (§6.1, §6.2) |
| `T_no_getparameter`, `T_no_key_in_msg` | negative rows: nothing wrong is present *yet* |
| `M_test_compile`, `M_unit_conv`, `M_unit_msg` | the tree compiles and those classes are green today |
| `M_unit_truck` | `MobileTruckLoadingServiceTest` is green today. **Becomes a discriminator after Fix A**: its existing `hasMessageContaining("String is not valid")` breaks unless Fix C is applied at C5 |

The discriminating Maven rows are `M_unit_pallet` and `M_unit_move` — both name classes that do not exist yet.

**Four defects in this script, every one found by RUNNING it rather than reading it.** Two were false greens,
two were false reds; the false reds matter because an un-greenable row invites someone to delete it.

| # | Found | Direction | Fix |
|---|---|---|---|
| 1 | `T_conv_exists` went green at baseline, contradicting the plan's claim that `StringConverter` had no test. **It has one** — 4 tests in a `@Nested ConvertFormatToRegex`. The plan text was wrong, not the script | false green | §6.1 corrected; row relabelled a guard |
| 2 | **`M_unit` passed on the unfixed build.** Naming two classes in one row let the pre-existing 4 green tests satisfy `Tests run: [1-9]… Failures: 0` while the other class **did not exist at all**. Same family as SBDEV-2961's `M_guard_test`, but filled in by a *sibling* rather than by an absent class | false green | **One class per Maven row** |
| 3 | **All six Maven rows red at once.** `mvn` is not on this box's default PATH (SDKMAN), so each row exited **127** and `run` logged it as an ordinary FAIL — un-greenable, and indistinguishable from a broken build. Mirror image of the SBDEV-2643 lesson where an *undefined check function* scored 127 as an honest-looking FAIL. It also invalidated the previously-recorded `5 pass, 15 fail` baseline, which had silently inherited an exported PATH | false red | The script now prepends the SDKMAN candidates itself, and if `mvn` is still unresolvable it **SKIPs the rows with a loud reason** instead of failing them |
| 4 | `B_guarded` was file-scoped, so a `catch (RuntimeException)` added to `convertFormatToRegex` per §8.3 would green it with the new helper **unguarded**; and `C_six_described` was a symbol census that a call never reaching the exception's argument list would satisfy | both potential false greens | New `method_body_contains` (brace-matched single-method extraction) and `stmt_matches_exactly_across` (tempered `[^;]*` gap). Both **positive/negative tested on synthetic fixtures** before use, and both **fail closed** on a missing file |

⚠ **Residual limit, stated rather than papered over.** The `T_*` rows are name/string greps: an empty test
method with the right name satisfies them. `T_conv_*`, `T_msg_*`, `T_pallet_*` and `T_move_*` are each backed
by an *executing* Maven row, so an empty test still cannot hide a wrong implementation — but the TDD gate, not
this script, is what proves each test fails before it passes.

### 9.2 Implementation status

**IMPLEMENTED 2026-08-14 — PR [#160](https://github.com/SiteBossInc/wms2-api/pull/160), awaiting review.**

| | |
|---|---|
| Commit | `7f4952a` — 10 files, +681/−8, one atomic commit (the A/C ordering asymmetry forbids splitting) |
| Branch | `bugfix/SBDEV-2962-expected-label-format-in-error` off `origin/develop` `02dc7ca` |
| Worktree | `.claude/worktrees/wms2-api/SBDEV-2962` (kept for review feedback; `archive-plan` removes it) |
| `mvn -o clean test-compile` | BUILD SUCCESS |
| Full `mvn -o test` | **5040 run, Failures: 2, Errors: 0, Skipped: 67** — both pre-existing, method set unchanged |
| `verify-SBDEV-2962-…sh` | **`Result: 41 pass, 0 fail, 1 skip`** (baseline `20 pass, 19 fail, 1 skip`) |
| Conformance lane | `verifier` **PASS**, 8/8 VERIFIED; its one PARTIAL retracted by the lane itself |
| Code review lane | `code-reviewer` **APPROVE** after 2 passes; 1 Medium + 6 Low/nit fixed |

**Tests — 62 across 5 classes** (only one class is new; four already existed, see §6.1):

| Class | Count | Added |
|---|---|---|
| `StringConverterUnitTest` | 15 | 11 in a new `@Nested DescribeExpectedFormat` |
| `BusinessExceptionUnitTest` | 10 | 2 in a new `@Nested NoValidStringMessage` |
| `MobilePalletizingScanPalletFormatTest` | 3 | **new class** — deliberately not `MobilePalletizingServiceTest`, which has a pre-existing failing method and so can never back a `Failures: 0` gate row |
| `MobileMoveStockServiceTest` | 10 | 1 — C6, the site whose divergence justifies the whole design |
| `MobileTruckLoadingServiceTest` | 24 | 1 — C5 |

#### What the implementation changed about the plan

1. **Amendment r3 (§3.3, §7 row 2)** — C1/C3 pass the example alone, not three arguments. The literal §3.3
   instruction would have introduced a new HTTP 500. The verify rows had already encoded the safe shape.
2. **§6.1 corrected four times.** Every test class the plan called "new" except one already existed. The
   lesson is mechanical: **grep the test tree before writing §6.**

#### Landmines found during implementation, none predicted by the plan

| Landmine | Consequence |
|---|---|
| **No assertion detected a swapped argument pair.** Every one was an unordered `contains()`, and `String is not valid: '<format>'. Expected format: TEST1` satisfies `contains(label)` *and* `contains(format)` — as does the structural `C_six_wired` row | A genuinely broken call site would have shipped green. Closed with ordered assertions at C1/C2/C5/C6 + an exact `isEqualTo` on the bundle, then **ablation-proven** by swapping one site's arguments and watching the class go red |
| **An oversized format width raises `OutOfMemoryError`** — an `Error`, so `catch (RuntimeException)` never held, and the Javadoc's "MUST NOT THROW" was false | Fixed with a pre-screen on the *pattern*: truncating cannot help when producing the value is what fails. ⚠ The flag run `[-#+ 0,(]*` is load-bearing — a review lane measured that the pre-flag regex closed only **1 of 7** shapes; `%1$,2147483647d` and 5 siblings still OOM'd |
| **A `...` truncation marker is itself valid regex** (three any-char atoms) | A character-truncated accept list still *compiles* and still looks paste-able while matching labels the WMS rejects — silently wrong beats loudly broken. Replaced with `joinBounded`, which drops whole alternatives and marks them `(+N more)` |
| **A negative verify row was broken by my own Javadoc** mentioning the forbidden symbol (`getParameter()`) | Mirror of the SBDEV-2961 lesson where a comment *satisfied* a positive row. Added `code_not_contains` |
| **Two verify rows went stale from a behaviour-preserving refactor** — `B_bounds_example` asserted `MAX_EXAMPLE_LENGTH` inside `describeExpectedFormat`, then the bounding moved into `truncate()` | Red rows in the run that *proved* the code worked — the documented SBDEV-2732 trap. Rewritten chain-level (constant → helper delegates → delegate bounds → delegate calls `substring`), and both lanes confirmed the rewrite is **tighter**, not loosened to un-break it |
| **`mvn` is not on the default PATH** (SDKMAN), so every Maven row exited 127 and was logged as an ordinary FAIL | An un-greenable row invites deletion. The script now resolves the toolchain itself and **SKIPs loudly** if it can't |
| **Concurrent Maven in one worktree produces convincing phantom failures** — a spurious `452 errors`, a compile error in an untouched file, and 140 lines of unrelated outbox errors | All three were my own `clean` racing a review lane's suite. The tell is `<<< ERROR!` rather than `<<< FAILURE!` in classes absent from `git status`. Re-run serially before believing any of it |

#### Deliberately skipped coverage

- **C3** (`scanPalletBulk` null/empty) has no test — unreachable through its only caller (`@PathVariable`). Updated anyway to preserve the count-of-6 invariant.
- **C4** has no format test (pre-existing §6.5 gap); `MobilePalletizingServiceTest` cannot gate it.
- **No test exercises the string an operator actually sees**, because production renders via `getMessage()` → `Locale.getDefault()` while the tests pin `getLocalizedMessage(Locale.US)`. Forced by the §8.2 parent-bundle gap; asserting `getMessage()` would fail on a *correct* implementation on a non-`en_US` JVM.

#### Follow-ups this plan does not cover — all three now filed 2026-08-14

| Ticket | Scope | Priority |
|---|---|---|
| [SBDEV-2964](https://app.clickup.com/t/868krm8kd) | **Mobile label generation** — the other half of this ticket's complaint. The generator already exists at `BillofladingService:774-779`, so it is an exposure problem. ⚠ Carries a warning that the C1 guard must not simply be deleted if the blank-field route is taken: §9.1 asserts the throw count is exactly 6 | low |
| [SBDEV-2965](https://app.clickup.com/t/868krm8nn) | **`convertFormatToRegex` unchecked throws → HTTP 500** (§8.3), with the four measured throw shapes and the controller's catch-list as evidence. ⚠ Warns against the naive `catch → return ""` fix, which would make `matches("")` false for every label and reject *all* pallet labels silently | low |
| [SBDEV-2966](https://app.clickup.com/t/868krm8q7) | **The 325-key parent-bundle gap** (§8.2). Raised to `normal`, not `low`: it means 325 of 350 operator messages already degrade on a non-`en_US` JVM, and it is why no test here can assert the string production actually renders | normal |

**Still not tracked:** v1 carries the identical defect (same six sites, same message text) and is explicitly out
of scope by decision, so the live v1 fleet stays exposed with nothing filed against it.
