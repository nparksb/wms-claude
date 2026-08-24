---
title: "SBDEV-3003 Slice 1 — review lane: wms2-api Fix F (javadoc) + the shared verify script"
ticket: "SBDEV-3003"
type: review
lane: api-and-verify-script
version: v2
reviewed_commit: "0efea2b (pre-review d557824, amended away)"
base: "origin/develop 60aef02"
created: 2026-08-20
updated: 2026-08-20
related:
  - ../SBDEV-3003-move-stock-lost-update-inventory-inflation.md
  - ./SBDEV-3003-review-mobile.md
  - ../../../wms1/plan/SBDEV-3003-move-stock-lost-update-inventory-inflation.md
tags: [review, wms2, slice1, verify-script]
---

# Review lane — `wms2-api` Fix F + the shared verify script

> **Provenance.** Consolidated record written 2026-08-20 *after* the lane ran, from plan §9.1, commit
> `0efea2b`'s message, and the corrections the findings put into
> `9-System/scripts/verify-SBDEV-3003-…sh` (each corrected row is annotated in the script itself).
> The verbatim transcript was not persisted. Every measurement is quoted, not re-derived.

**Verdict on the javadoc: correct, and its claims independently checked.**
**Verdict on the verify script: 3 High — it was grading two of this plan's headline claims for the
wrong reason.** All applied.

---

## 1. What was reviewed

| | |
|---|---|
| Commit | **`0efea2b`** — `docs(util): SBDEV-3003 stop OptimisticLockRetry's javadoc teaching the stale-operand shape` |
| Base | `origin/develop` **`60aef02`** |
| Diff | `util/OptimisticLockRetry.java` **+56/−2 — javadoc only, zero behaviour change** |
| Also in scope | `sbdocs/9-System/scripts/verify-SBDEV-3003-move-stock-lost-update-inventory-inflation.sh` (417 lines, spans **four** repos) |

---

## 2. The javadoc — what the lane actually verified

Fix F exists because the class's canonical usage example was `fresh.setAmount(newAmount)` with
`newAmount` computed **outside** the lambda — i.e. the snippet developers copy taught the exact v1
Move Stock defect shape. The lane checked the corrected text rather than trusting it:

| Claim in the new javadoc | How it was checked | Result |
|---|---|---|
| The entities in question carry `@Version` | Read `AbstractBaseEntity:33` | **true** |
| `MobilePalletizingService` is the one correct call site in the repo | Read it — captures only an id, re-reads inside the lambda, re-evaluates its state guard against the fresh instance | **genuinely exemplary** |
| All `@link`/reference targets resolve | Checked | **all resolve** |
| Doc is well-formed | `javadoc -Xdoclint:all` **on this file** — the pom pins `-Xdoclint:none`, so the normal lane checks almost nothing | **4 warnings, all pre-existing "no comment" on the constant and constructors; 0 errors; none from the new text** |
| Compiles | `mvn clean compile` | **BUILD SUCCESS** |

### 3 Medium on the javadoc — all applied

1. **It claimed v2's `StockunitBusinessService` is "pinned by regression tests". It is not.** The only
   concurrency test is `StockunitBusinessServiceConcurrencyIT`, which is **`@Disabled` pending
   SBDEV-2217**, and no enabled v2 test asserts the post-transfer source amount. The text now says so,
   and says that SBS reaches its correctness through a **row lock** (`findByIdForUpdate`, arithmetic on
   the locked instance) — **not** through this utility, which has exactly one call site in all of
   `src/main`.
2. **It left the class's larger landmine unstated while raising the bar past it.**
   `executeWithRetry` manages **no transaction of its own**, so called from inside an open transaction
   the mandated re-fetch buys nothing: `findById` is served from the persistence context and returns
   the same managed instance at the same version, the flush happens at commit *after* this method
   returns, and where the exception does fire the context is invalid and the transaction rollback-only.
   **Each attempt must be its own transaction** — now documented as a precondition.
3. The WRONG counter-example's variable was renamed to **`capturedAmount`** so that verify row F1's
   `file_not_contains 'fresh.setAmount(newAmount)'` is not tripped by the deliberately-wrong example
   itself. (A row that the counter-example fails is a row that punishes documenting the hazard.)

---

## 3. The three High findings — on the script, not the code

**This was the serious result of the review.** All three were independently re-measured before being
accepted, and **two of them mean evidence cited earlier in the plan was worth less than claimed.**

### High-1 — verify row **F2** was a measured FALSE GREEN

| | |
|---|---|
| Was | `(?i)(recomput\|derive)[^\n]*(re-?fetch\|fresh\|locked)` |
| Measured | Deleting the **entire** "necessary but not sufficient" paragraph **and** the whole WRONG counter-example left F2 **green** — an incidental phrase in the remaining example satisfied it |
| Impact | The one row that certifies Fix F was grading the right file **for the wrong reason** |
| Now | Requires captured/pre-computed **+** `absolute` **+** `@Version`. Re-measured **red** on that same gutted file |

### High-2 — regression pin **P3** was vacuous

| | |
|---|---|
| Was | `file_not_contains 'setAmount\(\s*staleStockUnit\.…'` |
| Measured | It forbade **one hard-coded variable name**, `staleStockUnit`, which does not occur at `StockunitBusinessService:373` at all — it is a parameter name in `changeAmount`/`changeReservedAmount`. Under a **realistic** reinstatement of the v1 defect (`sourceStockunit.setAmount(callerSnapshot.getAmount().subtract(amount))`) **P1 went red and P3 stayed GREEN** |
| Impact | The plan's most important regression pin — the one whose job is to stop a future refactor reintroducing the v1 lost update into v2 — **would have sat green through exactly that.** The mutation originally run had been shaped to the row rather than to the defect |
| Now | Reuses A1's name-agnostic shape (any `setAmount` whose operand object differs from its receiver), routed through the perl helper. Clean on unmutated SBS, **red on the mutant** |

`P2` legitimately holds under that mutation — it pins the lock, an independent axis. That is not a
gap.

### High-3 — row **G1b** graded English, and broke in both directions

| | |
|---|---|
| Was | Three prose fragments joined by unbounded lazy gaps |
| Measured | **Both failure directions.** One comment turned it **green** with `shouldNotFilter()` untouched; a correct implementation writing "fails open" instead of "fail open" went **red** |
| Now | Asserts the **code shape** (auto-derive gated on the `/v3` scope) |
| ⚠ | Still red until Slice 2. **Re-measure it against a deliberately-wrong build before trusting it** — it has no green measurement yet |

---

## 4. Also corrected in the same pass

| Row | Defect |
|---|---|
| **G2** | A tree-wide substring grep satisfied by a comment (`// TODO duplicateTransfer counter`) while asserting nothing about a **registered** counter. Per plan §8 row 8 that counter is the **only genuinely new backend code in Slice 2**, so the weakest guard in the file sat on the highest-risk row |
| **G3** | An unbounded gap over a 7 KB store could not tell "suppresses the toast for a dedupe 409" from "logs the 409" |
| **D1e / D2e** | Would have **false-redded a correct implementation** that wraps the transfer in `try/catch/finally` — the same shape `scanDestination.vue` already uses for its probe |
| **A2 / P1** | Passed `\1` backreferences to `grep -E` — a GNU extension that BSD/macOS grep and ugrep reject outright. Harmless as invoked here, but **P1 is a regression pin**, so a portability red would have read as *"the v1 defect is back."* Both routed through the perl helper |
| Closing reminder | Named the deleted `B*`/`E*` families and asserted **all** `D*` rows must be red pre-fix — contradicting the measured vacuity of D1/D1b on v2, where SBDEV-2994 already satisfies them |

### Earlier row corrections carried in the same script

Five rows had already been found wrong before this lane; **four of the five failed in the direction
that hides work rather than the direction that blocks it** (plan §9.1): `D1b` (single-line guard
regex vs. 2994's braced block), **`D1d` (false green — 2994's probe `await` satisfied it)**, `T3`
(filename assertion satisfiable by an empty file), `E1` (asserted a design Q1 **rejected** — deleted),
`G1` (pointed at the wrong file — retargeted to `IdempotencyFilter`). Rows `D4–D4d`/`D5–D5d` were
added because the script asserted `scanDestination.vue` **only**, so a half-applied Fix D — guard on
one screen, not the other — would have passed clean.

---

## 5. Measured state at review close

| | |
|---|---|
| Verify (Slice 1 worktrees, `SKIP_MVN=1`) | **35 pass, 4 fail, 3 skip** — the 4 fails are `G1`/`G1b`/`G2`/`G3`, all **Slice 2** |
| Negative test | Re-run with `V2_API`/`V2_UI` pointed at `origin/develop`: **24 pass, 15 fail**. Every row claimed green for Slice 1 (`D1c`, `D1d`, `D1e`, `D4–D4d`, `F1–F3`, `T3`) confirmed **red** there |
| Compile | `mvn clean compile`: **BUILD SUCCESS** |

---

## 6. Carry-forward for Slice 2

1. **`G1b` has never been measured green.** Re-measure it against a deliberately-wrong build before
   relying on it.
2. **`G2` guards the only genuinely new backend code in Slice 2.** It was the weakest row in the file
   until this pass; treat it as the row most worth re-mutating.
3. **Two quoting traps** were hit writing rows, both producing a permanently-red row indistinguishable
   from unfinished work: a **double-quoted** bash pattern turns `\$store` into `$store`, which ERE
   reads as an end-of-line anchor that can never match; and an adjacency regex spanning
   `submitting = true` → `try {` fails on **v1**, where a comment sits between the two lines.
   Single-quote every pattern; tolerate `//` comment lines inside adjacency gaps.
4. **Script header drift** (corrected 2026-08-20): it advertised v1 as "Fixes A[+C],D,**E**,H" and v2
   as "Fixes D,**E**,F,G" while **no `E*` row exists in the file** — v1's Fix E is deferred, v2's `E1`
   was deleted when Q1 rejected merge-into-existing-UL. Read literally it claimed the dedupe fix was
   graded.
