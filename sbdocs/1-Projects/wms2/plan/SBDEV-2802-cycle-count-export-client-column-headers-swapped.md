---
title: "Cycle Count Export — Client Name / Client ID Column Headers Swapped Relative to Their Values"
ticket: "SBDEV-2802"
ticket_url: "https://app.clickup.com/t/868kkfekz"
type: "bug"
priority: "normal"
status: "implemented"
project: ["wms2"]
version: "v2"
requester: "Nam Park (found while implementing SBDEV-2632)"
created: "2026-08-03"
updated: "2026-08-03"
db_verified: false
related:
  - "SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.md"
  - "../../../3-Resources/workflows/wms2-cycle-count-workflow.md"
tags:
  - plan
  - bug
  - cycle-count
  - export
---

# Cycle Count Export — Client Name / Client ID Column Headers Swapped Relative to Their Values

**Ticket:** [SBDEV-2802](https://app.clickup.com/t/868kkfekz)
**Project:** wms2 | **Version:** v2 | **Type:** bug
**Priority:** normal
**Status:** implemented — **MERGED to `develop`** 2026-08-03 (`76054fc`), ClickUp `on dev`. **v2 only**; v1 half still open under this ticket (§6)
**Date:** 2026-08-03

> **Scope note.** This is a deliberately thin plan. The diagnosis was completed in full while
> implementing SBDEV-2632 and is recorded on the ticket — exact files, line numbers, blast radius,
> and the zero-correct-usages grep. No further investigation is needed, so §2 records the finding
> rather than re-deriving it. The v1 sibling is **out of scope** for this pass (see §6).

---

## 1. Problem Statement

Every cycle-count Excel export labels the two client columns backwards. The column headed
**"Client Name"** contains the client *number* (`Client.getClNr()`, e.g. `CLI-001`) and the column
headed **"Client ID"** contains the client *name* (`Client.getName()`, e.g. `WineCo`).

Operator-visible on both sheets (aggregated and detailed) of the two **reachable** export methods —
`exportCycleCounts` and `exportCycleCount`. The six affected header arrays span three methods, but
`exportCycleCount2` is **dead code**: `git grep exportCycleCount2 origin/develop -- src/main` returns
only its own declaration at `:366`, and the sole controller entry point
(`CycleCountController:140`) reaches `exportCycleCounts`, which delegates single selections to
`exportCycleCount` (`CyclecountService:193-195`). So 4 of the 6 arrays are operator-visible and 2 are
latent. Long-standing and pre-existing — **not** introduced by SBDEV-2632.

**Reproduce:** export any cycle count from the web UI Cycle Count screen; open the `.xlsx`. Column A
of the aggregated sheet is headed "Client Name" but holds the client number.

---

## 2. Root Cause

A plain literal-ordering mistake in the header arrays. The `rows.add(new Object[]{...})` calls emit
`getClNr()` before `getName()`, which is a defensible column order; the header arrays declare
`"Client Name"` before `"Client ID"`, which contradicts it. There is no logic involved and no
correct usage anywhere in the repo to model against — grepping the header literal with `getName()`
first returns zero hits.

SBDEV-2632 added the fifth and sixth header arrays (the merged bulk-export path) and **deliberately
reproduced the swap**, with a `NOTE — deliberate bug-parity` comment pointing at this ticket, so
that every export sheet stayed internally consistent rather than shipping a workbook whose new
merged sheet disagreed with the legacy ones.

### Affected Locations

All line numbers against `origin/develop` at **`a0846d1`** (the PR #121 merge; re-verified byte-for-byte
identical to `37bb39e`/PR #119 for both target files — #121 landed mid-authoring and touched neither), file
`v2/wms2-api/src/main/java/net/aim_ai/wms/service/CyclecountService.java`:

| # | Line | Method / sheet | Current header fragment |
|---|------|----------------|-------------------------|
| 1 | `:258-263` | `exportCycleCounts` | the `NOTE — deliberate bug-parity` comment block — **delete** |
| 2 | `:264` | `exportCycleCounts` aggregated | `{"Cycle Count", "Client Name", "Client ID", ...}` |
| 3 | `:283` | `exportCycleCounts` detailed | `{"Cycle Count", "Position", "Date", "Client Name", "Client ID", ...}` |
| 4 | `:338` | `exportCycleCount` aggregated | `{"Client Name", "Client ID", ...}` |
| 5 | `:357` | `exportCycleCount` detailed | `{"Position", "Date", "Client Name", "Client ID", ...}` |
| 6 | `:400` | `exportCycleCount2` aggregated | `{"Client Name", "Client ID", ...}` |
| 7 | `:419` | `exportCycleCount2` detailed | `{"Position", "Date", "Client Name", "Client ID", ...}` |

Blast radius, verified in review rather than assumed:

- **`CyclecountService` is the only production class** using this header pair.
- **`FileExportService` does nothing position-dependent with the header array** — `:102-105` and
  `:195-198` are a plain `headerCell.setCellValue(headerNames[i])` loop under one uniform style, with
  no sorting, dedup, autosize, or freeze panes. Label position is not load-bearing beyond the visible
  text, which is what makes a label-only swap safe.
- **No UI consumer.** `wms2-web-ui/store/internalOps/cycleCount.js:198` posts to `/cycleCount/export`
  with `responseType: 'blob'` and never parses columns. No column map anywhere in either UI.
- **No round-trip importer** — `FileImportService` has no cycle-count handling, so nothing consumes
  these ordinals internally.
- **`ReportService` is unaffected** and correctly out of scope: its `"Client ID"` / `"ClientName"` /
  `"Client Number"` headers (`:224`, `:265`, `:302`, `:337`) sit over the *right* values
  (`row[2]=getClientId()`, `row[3]=getClientName()`). Worth knowing that after this fix `"Client ID"`
  means `clNr` in cycle-count exports but the actual PK in `ReportService` — see §6.
- **One in-repo consumer DOES exist and this plan must update it** — see §3.3. `sbdocs`-side, not
  compiled, which is why a source grep alone missed it.
- **No other test** in either repo asserts these headers (`CyclecountServiceUnitTest`,
  `FileExportServiceUnitTest` have none; v1 has none).

---

## 3. Proposed Fix

### 3.1 Swap the labels, never the values — decided 2026-08-03

Two corrections were possible. **Swap the header labels; leave every `rows.add(...)` untouched.**

| | Swap labels (chosen) | Swap values (rejected) |
|---|---|---|
| Column A content | unchanged — still `getClNr()` | **changes** to `getName()` |
| Header text | changes | unchanged |
| Breaks consumers keyed on | header text | column position |

Swapping the labels keeps the bytes in every physical column exactly where they are today; only the
visible label moves to match. A downstream spreadsheet or macro reading column A has always received
the client number and continues to. Swapping the *values* instead would silently change what lives
in each column while leaving the header text identical — the classic silent-data-shift failure mode,
and undetectable to a consumer that never re-reads the header row.

This does still change operator-visible output, which is why the ticket asks for an ops check before
merge (§5).

**The edit,** applied identically at all six header arrays:

```java
// before
{... "Client Name", "Client ID", ...}
// after
{... "Client ID", "Client Name", ...}
```

Plus delete the now-obsolete `NOTE — deliberate bug-parity` comment at `:258-263`. Leaving it in
place would tell the next reader the swap is intentional after it has been corrected.

**Files changed:** `src/main/java/net/aim_ai/wms/service/CyclecountService.java` (7 hunks).

### 3.2 Replace the verbatim header pin with an alignment assertion

`CycleCountControllerUnitTest$BulkExportWorkbookContent#export_shouldKeepLegacyColumns_whenSingleCycleCountSelected`
(`:1038-1055`) pins both legacy header arrays verbatim and **will fail** on the §3.1 edit. That is
expected, not a regression — the test was written to freeze the columns SBDEV-2632 must not disturb.

Update the two `containsExactly(...)` literals to the corrected order, and rename the test away from
"keeps the legacy columns" (it no longer does) — **renamed to
`export_shouldKeepLegacySheetShape_whenSingleCycleCountSelected`**. The rename is not cosmetic:
its `@DisplayName` said `#3 INVARIANT … expected to pass before AND after implementation` and its
Javadoc claimed `the legacy method is not edited`, both of which this change falsifies. Left as-is,
a future reader seeing it red would conclude the correct repair is to revert the header swap — the
same revert-trap §3.3 exists to disarm, reproduced inside the test file. A5e only greps the
literals, so the verify script cannot catch it. Rewrite the Javadoc to state the surviving
invariant (sheet *shape* and column *order*, not labels) plus an explicit do-not-revert note.

Then add the assertion that would actually have caught this bug, in the same nested class, which
already has both `captureHeaders(sheet)` and `captureRows(sheet)` helpers and a fixture with
distinguishable values (`stubClientAndItem` at `:812-819` sets `clNr="CLI-001"`, `name="WineCo"`).

`captureHeaders` returns `String[]`, which has no `indexOf` — go through `Arrays.asList(...)`:

```java
@Test
@DisplayName("#2802 client columns hold the value their header names, on both sheets")
void export_clientColumnsAlignWithTheirHeaders() throws Exception {
    // per sheet, and for BOTH the single-CC and merged multi-CC paths:
    List<String> h = Arrays.asList(captureHeaders("aggregated"));
    Object[] row  = captureRows("aggregated").get(0);
    assertThat(row[h.indexOf("Client ID")]).isEqualTo("CLI-001");    // the client NUMBER
    assertThat(row[h.indexOf("Client Name")]).isEqualTo("WineCo");   // the client NAME
}
```

This asserts the header↔value *relationship* by header lookup rather than pinning literals at fixed
indices, so it survives future column reshuffles and fails loudly on any re-introduction of the
swap. Cover the merged path too (multi-selection), where the leading `Cycle Count` column shifts
every index by one — a fixed-index assertion would quietly pass there for the wrong reason.

> **The snippet above is a shape sketch, not a body to paste.** A signature with a comment-only body
> satisfies a naive grep for the method name *and* for `indexOf("Client …")` while asserting nothing,
> which is precisely how a vacuous test ships. The verify script therefore counts **occurrences of the
> fixture values** (`"CLI-001"`, `"WineCo"` must each appear ≥2× — the stub plus at least one real
> assertion) and requires ≥2 `indexOf("Client` lookups, one per sheet. Those counts are only
> satisfiable by executable assertions. §5's red-first mandate still applies.

**Coverage limit, stated rather than implied:** behavioral coverage reaches 4 of the 6 header arrays.
`exportCycleCount2`'s two arrays (`:400`, `:419`) are unreachable from any controller entry point
(§1), so no controller test can exercise them; they are gated by verify-script check `A1` alone
(`count_eq 6`, which fails on any partial fix). Deleting `exportCycleCount2` outright would be the
cleaner disposition — deliberately **not** done here to keep this plan thin; see §6.

Note `#1 multi-selection adds a leading Cycle Count column` (`:850`) asserts only
`startsWith("Cycle Count")` and needs no change.

### 3.3 Update SBDEV-2632's still-live verify script

`sbdocs/9-System/scripts/verify-SBDEV-2632-cycle-count-bulk-export-nonnumeric-id-500.sh:235-236`
asserts the **swapped** order as an acceptance criterion:

```bash
check_B_legacy_header()  { ... grep -qE '"Client Name",\s*"Client ID",\s*"SKU ID", ...' }
check_B_legacy_detail()  { ... grep -qE '"Position",\s*"Date",\s*"Client Name"' }
```

SBDEV-2632's plan is `status: implemented` but **not archived**, so both the plan and its script are
still live. After this fix those two checks fail, and the obvious-looking "repair" is to revert this
change — the exact trap this section exists to disarm. Update both patterns to the corrected order.

(The alternative is to run `archive-plan` on SBDEV-2632 first, which retires the script entirely.
Either resolves it; updating the two patterns is the smaller action and keeps 2632's other 60-odd
checks available while its PR is still fresh.)

**Files changed:** `sbdocs/9-System/scripts/verify-SBDEV-2632-...sh` (2 lines, filesystem-only — do
not `git add`, `sbdocs/` is not in any repo).

**Files changed:** `src/test/java/net/aim_ai/wms/unit/controller/CycleCountControllerUnitTest.java`.

---

## 4. Acceptance

Machine-checkable: `verify-SBDEV-2802-cycle-count-export-client-column-headers-swapped.sh`.

**This script is rooted at the repo, not the monorepo** (unlike most in that directory), so pass
`PROJECT_ROOT=$WT` directly — the symlink shadow-root recipe in `wms-plan-executor` is neither needed
nor applicable here, and skipping it removes the "graded the stale main checkout" failure mode
entirely.

| # | Criterion |
|---|-----------|
| A0/A0b | Both target files exist at the expected paths (guards a wrong `PROJECT_ROOT`) |
| A1 | All six header arrays read `"Client ID", "Client Name"` — `count_eq 6`, so a 3-of-6 partial fails |
| A2 | Zero occurrences of `"Client Name", "Client ID"` remain in `CyclecountService.java` |
| A3a-c | The bug-parity comment is gone **entirely** — three distinct phrases pinned, not one |
| A4a-c | No value order changed: inline form still 2×, `row[0]/row[1]` 2×, `row[2]/row[3]` 2× |
| A5a-d | The §3.2 alignment test exists **and asserts** — ≥2 `indexOf("Client`, ≥2 each of the two fixture values |
| A5e | The stale verbatim header pin in the test is updated |
| A8a/A8b | SBDEV-2632's sibling verify script no longer pins the old order (§3.3) |
| A6 | `CycleCountControllerUnitTest` passes, with a non-zero test count (bare class name — see §5) |
| A7 | `mvn clean compile` succeeds |

**Pre-fix baseline: `5 pass, 12 fail, 2 skip`** (the 2 skips are A6/A7 without `mvn` on PATH). The 5
passes are A0, A0b and the three A4 invariants, all of which are *supposed* to hold before and after.
A run that reports fewer than 12 failures on unmodified code means the script has been weakened.

---

## 5. Landmines

- **Ops confirmation is a merge gate, not a code gate.** The header text is operator-visible and has
  shipped this way for years. Downstream spreadsheets or import routines may key off it. Build and
  open the PR, but confirm with whoever consumes these exports before merging.
- **`CycleCountControllerUnitTest` is `@Nested`.** Never `-Dtest='CycleCountControllerUnitTest#method'`
  — it silently runs zero tests and reports a false green. Use the bare class name.
- **`mvn test` mutates the tracked `src/test/resources/archunit_store/...`.** Revert before committing.
- **Two pre-existing failures on clean `develop`** (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`)
  are unrelated to this change — do not chase them.
- **`mvn`/`java` need the SDKMAN PATH export** in a non-login shell.
- **Verify the test fails first.** A5 is cheap to satisfy vacuously. Run the new alignment test
  against unmodified `CyclecountService` and confirm it FAILS on the header order before applying
  §3.1 — a green-on-first-run alignment test is asserting nothing.
- **Never `mvn -q | grep "BUILD SUCCESS"`.** `-q` suppresses INFO, which is where both `BUILD SUCCESS`
  and Surefire's `Tests run:` summary live, so the grep has nothing to match and the check can *never*
  pass. Verified 2026-08-03: `mvn -q validate` emits 0 lines. Either drop `-q` and grep, or keep `-q`
  and use the exit code — never both. This bug was in this plan's own verify script (A6) and survived
  three negative-test rounds because **`mvn` was absent from PATH, so A6 skipped every time**. A SKIP
  is not a PASS; when reporting a `Result:` line, say which checks skipped.
- **`-DfailIfNoTests=false` + a mistyped class name = exit 0 on zero tests.** Require
  `Tests run: [1-9][0-9]*` in the output, not merely a successful exit.
- **When asserting about another verify script, use fixed-string grep.** Those files store patterns, so
  the literal bytes are `"Client Name",\s*"Client ID"` — an ERE search for `\s*` does not match them
  and false-greens. A8 had this bug on its first draft.

---

## 6. Out of Scope

- **v1/wms-api — deferred, but still owned by SBDEV-2802 itself.** `v1/wms-api/.../service/CyclecountService.java`
  carries the identical swap at `:180`, `:201`, `:246`, `:267` (four arrays, and zero cycle-count header
  assertions in its test suite, so no test churn). Deferred by decision on 2026-08-03.
  **Ownership note — do not re-route this to SBDEV-2631.** Review surfaced a contradiction worth
  settling here: SBDEV-2632's plan (`:1305`) claims "SBDEV-2802 … covers both versions", while an
  earlier draft of this §6 handed v1 to SBDEV-2631 — whose actual charter is the v1 mirror of the
  *bulk-export* fix, not the header swap, and which has no plan file on disk. Following that draft
  would have left v1 owned by nobody. **SBDEV-2802's own title says "(v1 + v2)", so 2802 keeps v1.**
  This PR closes only the v2 half; the ticket stays open until v1 lands, and the ClickUp comment must
  say so explicitly rather than reading as a full fix. Until then the two versions disagree on these
  labels.
- **Deleting `exportCycleCount2`.** It is dead in both v1 and v2 (§1), and removing it would drop two
  of the six arrays from the problem entirely. Deliberately not done — it widens a plan whose whole
  premise is thinness, and SBDEV-2632's plan (`:1251`) already floats a dead-code cleanup that is the
  natural home for it.
- Renaming `"Client ID"` to something truer to `clNr` (it is a client *number*, not the PK). Out of
  scope — this pass corrects the mislabeling only. Note this fix cements `"Client ID"` meaning `clNr`
  in cycle-count exports while `ReportService` uses the same words for the actual PK; §5's ops
  confirmation is the natural moment to raise it.
- The wider `Client ID` / `ClientName` header inconsistency in `ReportService` exports.

---

## 7. Review Record

Independent Critic pass 2026-08-03 (opus, adversarial mode) returned **REVISE** and this document is
the revision. Findings and disposition:

| # | Finding | Disposition |
|---|---|---|
| H1 | A6 could never pass — `mvn -q` suppresses the INFO lines the grep targeted; survived 3 negative-test rounds because `mvn` was off PATH so A6 always skipped | **Fixed** — reproduced independently (`mvn -q validate` → 0 lines), rewrote A6 to use exit code + `Tests run: [1-9]`, added the trap to §5, and made `run_mvn` announce that a skip is not coverage |
| H2 | §3.2's snippet was comment-only, so the A5 greps would green on a vacuous test | **Fixed** — §3.2 now flags the snippet as a shape sketch; A5 counts fixture-value occurrences that only real assertions can satisfy |
| M3 | SBDEV-2632's live verify script pins the swapped order and would fail after this fix | **Fixed** — new §3.3, plus checks A8a/A8b. This was a genuine missed consumer; §2's "no other consumer" claim was wrong and is corrected |
| M4 | `exportCycleCount2` is dead code, so "all three export methods" overstated blast radius | **Fixed** — §1 rewritten, §3.2 states the 4-of-6 behavioral coverage limit outright |
| M5 | A3 pinned one line of a six-line comment; partial deletion would green while false text survived | **Fixed** — split into A3a/A3b/A3c across three phrases |
| M6 | v1 ownership contradiction between this plan and SBDEV-2632's | **Fixed** — resolved in §6; 2802 retains v1 |
| L1 | Wrong provenance SHA (`e18f00b` predates #119) | **Fixed** — `37bb39e` in both plan and script |
| L2 | "sixth and seventh header array" off-by-one | **Fixed** — fifth and sixth |
| L3 | `count_eq` counted lines, not occurrences | **Fixed** — `grep -o` |
| L4 | `-DfailIfNoTests=false` false-green on a typo'd class name | **Fixed** — closed by the H1 rewrite |
| L5 | §3.2 snippet would not compile (`String[]` has no `indexOf`) | **Fixed** — `Arrays.asList(...)` |

Confirmed sound by the same pass: the §2 location table (all 7 line numbers exact), the
label-vs-value decision, `FileExportService` doing nothing position-dependent, no UI/importer/OMS/DB
consumer, no other test asserting these headers, and all three A4 count calibrations.

One defect was found *during* the revision and is not in the table above: A8's first draft searched
for `\s*` as a regex against a file that stores those characters literally, so it passed pre-fix.
Caught by re-baselining rather than by review — which is the argument for re-baselining after every
script edit, not only at the end.

**Not verified by anyone, and unverifiable from the repo:** whether any external consumer (operator
spreadsheet, macro, saved report definition) reads these columns by header text rather than by
position. §5's ops-confirmation merge gate is the control for that and should stay hard.

---

## 8. Implementation Status

**State: MERGED to `develop`** — PR [#122](https://github.com/SiteBossInc/wms2-api/pull/122), merge commit `76054fc`, 2026-08-03 21:15 UTC. ClickUp `on dev`. **v2 only.**

| | |
|---|---|
| Repo / branch | `v2/wms2-api` @ `bugfix/SBDEV-2802-cycle-count-export-client-header-labels` |
| Worktree | `.claude/worktrees/wms2-api/SBDEV-2802` |
| Base | `origin/develop` @ `a0846d1` (fetched 2026-08-03) |
| Commits | `e21a16e` fix — label client export columns to match their values<br>`57fbf10` test — assert client columns align with their headers<br>`fe7ec26` test — address review, retire the stale INVARIANT claim |
| Diffstat | 2 files, +89 / -24 |
| Pushed? | Yes — `origin/bugfix/SBDEV-2802-cycle-count-export-client-header-labels` |
| PR | **[#122](https://github.com/SiteBossInc/wms2-api/pull/122)** — **MERGED** into `develop` 2026-08-03, merge commit `76054fc` |
| ClickUp | `on dev` (comments `90110257368249`, `90110257369860`) |
| Post-merge verification | Confirmed on `origin/develop`: all 3 commits are ancestors, **6** corrected arrays, **0** stale pairs, bug-parity comment gone |

### Results

- **Verify script: `Result: 19 pass, 0 fail, 0 skip`** (`PROJECT_ROOT=$WT`). Includes A6 (real
  Surefire run) and A7 (`mvn clean compile`) — not skipped, unlike the authoring-time runs.
- **Targeted: `CycleCountControllerUnitTest` 43 tests, 0 failures.**
- **Full suite: 4613 tests, 2 failures, 67 skipped.** Both failures pre-existing and unrelated,
  identified from the Surefire XML: `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses`
  (ArchUnit drift) and `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`.
  Matches the documented clean-`develop` baseline. No `CycleCount*` failure.
- **TDD gate confirmed red first:** both new tests failed pre-fix with
  `[aggregated sheet: the column headed "Client ID" must hold the client NUMBER] expected: "CLI-001" but was: "WineCo"`
  — the correct reason, not a compile or mock error, with the other 41 tests green.
- **§3.3 sibling script updated** — all five `B-legacy` checks in
  `verify-SBDEV-2632-...sh` pass against the fixed worktree. Its ~11 `D1`/`D2`/`T-ui` failures are
  pre-existing and unrelated: `UI_ROOT` resolves to the `wms2-web-ui` main checkout, which sits on
  `develop` and contains none of SBDEV-2632's unmerged UI work (verified: 0 occurrences of
  `x-export-skipped-cycle-counts`).
- **ArchUnit store** mutated by `mvn test` as always; reverted before staging. Final tree held only
  the two intended source files.

### Review — both lanes PASSED (2026-08-03, second attempt)

The first pair of lanes aborted on Anthropic usage-credit exhaustion, not on findings. Re-run and
both completed against fresh, self-collected evidence.

**Conformance lane (`verifier`): PASS**, high confidence, 0 blockers. Every §2 affected-location row
and every §4 criterion VERIFIED. It re-ran the verify script, the targeted tests, the full suite and
`mvn clean compile` itself rather than trusting the numbers above, and independently confirmed the
attribution of the sibling script's UI-side failures (`wms2-web-ui` on `develop`, 0 hits for
`x-export-skipped-cycle-counts`).

**Code-review lane: 0 critical, 0 high, 1 medium, 1 low — both fixed in `fe7ec26`.**

| # | Sev | Finding | Disposition |
|---|-----|---------|-------------|
| M1 | Medium | `export_shouldKeepLegacyColumns_whenSingleCycleCountSelected` had its literals updated but kept its name, `@DisplayName("#3 INVARIANT …")` and a Javadoc claiming "the legacy method is not edited … passes before AND after" — all three false, and sitting on the revert path §3.3 exists to defend. **§3.2 explicitly required this rename and the implementation missed it.** A5e only greps literals so the script could not catch it | **Fixed** — renamed to `export_shouldKeepLegacySheetShape_…`, `@DisplayName` and Javadoc rewritten to the surviving invariant (sheet shape + column order, not labels) with an explicit do-not-revert note |
| L1 | Low | `captureRows(sheet).get(0)` is safe only because the fixture has exactly one client — structural coupling, though it degrades safely (a second client throws `EntityNotFoundException` rather than passing wrongly) | **Fixed** — assert non-empty before indexing, and document why row 0 is the stubbed client's row |

Verified by review beyond the plan's own checks:

- **Per-method positional alignment**, checked individually rather than assumed uniform: header index N
  describes value index N in all six arrays, including both leading-`"Cycle Count"` arrays where the
  client pair shifts by one. Array lengths match row widths (7/10/6/9/6/9).
- **Label-only minimality proved mechanically**: stripping every `Client Name`/`Client ID` line plus the
  deleted comment from both revisions yields **byte-identical files**.
- **All four assertion sites mutation-proven.** The plan's own red-first run only proved the *aggregated*
  assertions — it fails there first, so the *detailed* ones never executed. Review ran a second targeted
  mutation breaking only the detailed arrays to prove those two independently. Worth copying into future
  TDD gates: a failing test proves only the assertion that actually ran.
- **Mockito double-`verify()` is sound** — `times(1)` counts all matching invocations and this class uses
  neither `verifyNoMoreInteractions` nor `ignoreStubs`, so `captureHeaders` + `captureRows` verifying the
  same invocation both pass legitimately, not by accident.
- **`exportCycleCount2`'s `getExcelFile(…, "detailed", …)` call is not a quirk** — it is signature-mandated:
  that method writes to a `ByteArrayOutputStream` and `exportExcelFile` only accepts an
  `HttpServletResponse`. Pre-existing and correctly left alone.
- **`exportCycleCount2` does have 4 tests** (`CyclecountServiceUnitTest:558-655`) but they pass `any()` for
  `headerNames`, so no further test needed updating.

### Outstanding — required before this can ship

1. **⚠ Ops confirmation was NEVER obtained — merged without it**, on explicit direction, 2026-08-03.
   Recorded rather than quietly dropped, because §5 designated it a merge gate and §3.1's trade-off
   inverts if it turns out wrong. The exposure is bounded and one-directional: column **contents** are
   unchanged, so any consumer reading by column position is unaffected; only a consumer keying on header
   **text** can break. If a downstream report breaks after this reaches an environment, this change is
   the first thing to check, and the mitigation is a one-line revert of the six label pairs. No repo
   evidence could settle the question either way.
2. **v1/wms-api half not started; still owned by this ticket** (§6). **Do not close SBDEV-2802 on #122
   alone.** Note this merge *creates* a v1↔v2 divergence on these two labels that did not exist before
   — the versions now disagree until v1 lands.
3. **Do not archive this plan yet.** `archive-plan` would retire the verify script and remove the
   worktree, but the plan still has open v1 scope. Archive only once v1 ships.
4. Not done by design: verifying on the dev environment, and deploying/tagging beyond `develop`
   (GitLab CI is tag-driven: `dev-*`, `qa-*`, `ua-*`, `v*`).

The worktree remains at `.claude/worktrees/wms2-api/SBDEV-2802` (branch also still on `origin`). Remove
manually if wanted sooner than archive time:
`git -C v2/wms2-api worktree remove .claude/worktrees/wms2-api/SBDEV-2802 && git -C v2/wms2-api worktree prune`

Doc drift audited and closed: no `3-Resources/` architecture or workflow doc pins these column labels
(`wms2-cycle-count-workflow.md` describes "legacy columns" and the leading `Cycle Count` column but never
the client column names). SBDEV-2632's still-active plan got resolution markers at its two forward-looking
claims, including a do-not-revert note on its verify script.

### Landmine found during implementation, not predicted by the plan

`origin/develop` advanced mid-authoring (PR #121 / SBDEV-2797 merged between the first fetch and the
worktree creation), so the plan's line numbers were briefly anchored to a superseded SHA. They were
re-verified byte-for-byte against `a0846d1` before any edit and proved unchanged, but the general
lesson holds: **re-verify line-number anchors at worktree-creation time, not at authoring time**, on
any repo with active concurrent merges. Two `develop` merges landed during this single session.
