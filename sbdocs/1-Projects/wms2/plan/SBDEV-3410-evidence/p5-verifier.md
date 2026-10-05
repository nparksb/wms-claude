# SBDEV-3410 P5 — conformance verifier lane

**Question graded:** did P5 build exactly what the plan specifies?
**Contract:** §5.2 P5 (four checkboxes) + §3.8 ("Three edits, all in one commit").
**Date:** 2026-09-22
**Source of truth:** worktree `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410-p5`,
branch `feature/SBDEV-3410-p5-allclients-stock-unit-record-function`, HEAD `1aa726d5`, ahead 1 of
`origin/develop`, working tree clean.
**No maven was run in this lane** (a `clean verify` is in flight elsewhere). Everything below is
either code I read, a recorded log I parsed, a `git grep` I ran against `origin/develop`, or a SQL
query I executed myself.

---

## 0. Provenance check on the artifacts I was handed

| Artifact | Check | Result |
|---|---|---|
| `/tmp/p5.diff` vs `git diff origin/develop...HEAD` | byte diff | **IDENTICAL** |
| diff scope | `git show --name-only HEAD` | exactly 2 files, 1 commit, 65 ins / 11 del |
| working tree | `git status --porcelain` | clean — nothing uncommitted hiding the real state |

So the diff I graded is the branch, not a snapshot of a dirty tree.

---

## §5.2 P5 item 1 — annotation + pin row, three constants, same commit — **VERIFIED**

- `ClientController.java:250-252` adds `WEB_UI_VIEW_STOCK_UNIT_RECORD`, `WEB_UI_VIEW_STOCK_UNIT`,
  `WEB_UI_VIEW_CONTAINER` to `@RequiresFunction`. Counted the resulting list in the post-image:
  **14** entries, previously 11. ✓
- `Sbdev3017TrancheGateContextTest.java:687-693` adds the same three to the
  `row("ClientController", "/v3/client/allClients", …)` varargs. Counted: **14**. ✓
- Both constants exist already in `WmsConstants.FunctionEnum` (`:379`, `:380`, `:381`) — P5 adds no
  new constant, so the "a new FunctionEnum constant needs three things" hazard does not apply.
  Corroborated by the DB: all three functions have live holders (below), so the seed rows exist.
- **Same commit:** both files are in `1aa726d5` and nothing else is. ✓

**On the WIP commit.** `1aa726d5`'s message is `wip: p5 for suite run`. I graded the **diff**, as
instructed, and the atomicity property §3.8 actually cares about — that the annotation and its pin
never exist in different states on `develop` — is a property of the merged commit, not of this
branch's scratch history. It holds. **But it is not yet satisfied on disk:** the message must be
rewritten before the PR, and that is a real outstanding action, not a formality — a reviewer reading
`git log` today sees no record that this is a gate widening. Carried to §Outstanding.

## §5.2 P5 item 2 — restate both files' rotting counts as the invariant (§3.8 edit 3) — **VERIFIED, with two Low findings**

Both files were rewritten, not incremented. I checked specifically for a surviving bare count.

**`ClientController.java:204-230`** — states the rule first ("Every screen that renders a shipper
dropdown contributes its own view function to this ANY-of set… Derive the set from the dispatchers;
do not maintain a count"), then gives the counts under an explicit `DERIVED-AT-A-DATE and WILL rot`
banner with the re-derivation command, the date and the source SHA, then records that the old "13"
was already wrong and why. That is edit 3 as written.

**`Sbdev3017TrancheGateContextTest.java:662-686`** — same treatment, defers the reasoning to the
annotation, and names both dead numbers ("All 13 dispatchers", "six reports") so a reader who
remembers them knows they were retired deliberately.

**I verified the numbers rather than accepting them.** In `v2/wms2-web-ui`, at the exact SHA the
comment names:

```
$ git rev-parse --short origin/develop         → 9254bf5        (matches the comment)
$ git grep -l "admin/client/getClients" origin/develop -- '*.vue' '*.js' | wc -l   → 15
$ git grep -c "admin/client/getClients" origin/develop -- '*.vue' '*.js' | sum     → 26
```

And the enumeration is exact, file by file — the 15 files are Cycle Count ×3
(`closedCycleCount`, `plannedCycleCount`, `createCycleCount`), Replenishment ×2
(`closedReplenishmentRequests`, `openRequest`), `createPurchaseOrder` ×1, seven reports
(`flowbinReport`, `inventoryReport`, `lockReport`, `outboundParcelReport`, `parcelPickingReport`,
`receivingReport`, `skuLocationReport`), and the two Handling Units grids (`containerTable`,
`stockUnitsTable`). 3+2+1+7+2 = 15. **SEVEN reports, not six** — confirmed. None of the 15 is the
admin Shippers screen, so "the Shippers tab never reads this route" holds too.

**L1 (Low) — the stated derivation command produces 15, not 26.** The comment says
`git grep -l …` and then asserts "15 files, **26 dispatch sites**". `-l` cannot yield 26; that needs
`-c` and a sum. A reader following the instruction reproduces one of the two numbers and is left
guessing at the other — a small instance of the exact failure the comment is correcting.

**L2 (Low) — the rule is stated but the derivation *of the function set* is not.** "Derive the set
from the dispatchers" plus a grep gives you 15 **filenames**. It does not tell you how to get from
a filename to a `WEB_UI_VIEW_*` constant. §3.8's own derivation does: *map each dispatcher to its
`appMenuList.js` `fn`, then subtract the existing set* — and §3.8 also records the blind spot that
makes this safe to rely on only conditionally (`fn` is the menu-visibility function, and a screen
reachable without a menu entry never appears). Neither the mapping step nor the blind spot made it
into either comment. The rule is asserted; the procedure for applying it is not. §5.2 item 2 asks
only that the counts be restated as the invariant, which was done — so this is a Low, not a gap
against the checkbox.

## §5.2 P5 item 3 — mutation-check ×3, full varargs, ≥1 ungated row — **VERIFIED**

I parsed all three logs rather than trusting the summary. Every one is a genuine kill, and every one
kills for the right reason — I matched **whole tokens** in the printed sets, which is the specific
trap the new comment warns about (`WEB_UI_VIEW_STOCK_UNIT` is a prefix of the other two names).

| Mutant (constant removed from the annotation) | Result | `expected` side | `but was` side |
|---|---|---|---|
| `WEB_UI_VIEW_STOCK_UNIT_RECORD` | RED, `Tests run: 5, Failures: 1`, **1 of 227 routes wrong** | 14 incl. the token | 13, token absent, list ends at `…STOCK_UNIT_LOCK_OVERVIEW` |
| `WEB_UI_VIEW_STOCK_UNIT` | RED, `5 / 1`, **1 of 227** | 14 incl. the token | 13, bare `…+WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW+WEB_UI_VIEW_STOCK_UNIT_RECORD` — the bare token is the one gone |
| `WEB_UI_VIEW_CONTAINER` | RED, `5 / 1`, **1 of 227** | 14 incl. the token | 13, `WEB_UI_VIEW_CLIENT+WEB_UI_VIEW_CYCLECOUNT+…` — `CONTAINER` gone from position 2 |

Each mutant's `but was` set carries the *other thirteen* correctly. That is three independent
confirmations that the un-mutated base really is the 14-constant list — worth more than the green
run on its own, because a broken base would have shown up as ≥2 wrong routes.

**Green baseline:** `/tmp/p5-green.log` → `Tests run: 5, Failures: 0, Errors: 0` for
`Sbdev3017TrancheGateContextTest`, and `BUILD SUCCESS`. The `hasSize(227)` pin is intact —
`EXPECTED.size()` reads 227 in every failure message, and widening an existing row adds no key.

**Full varargs — VERIFIED.** The row lists all fourteen literally; nothing is computed, spread or
inherited.

**At least one ungated row — VERIFIED, and I checked the mechanism, not just the count.** Four rows
carry zero varargs:

```
:314  row("ClientController",    "/v3/client/create");
:315  row("BoxTypeController",   "/v3/boxType/create");
:316  row("ShipperIdController", "/v3/shipperId/create");
:383  row("AdminActionController", "/v3/adminAction/triggerUpdateStock");
```

`row(…)` with no varargs stores `""` (`String.join("+", new TreeSet<>(Set.of()))`), and the
assertion has a dedicated `got.isEmpty() → "UNGATED"` branch, so an ungated row that acquires a gate
fails loudly. The protection is targeted correctly: **`:314` is on `ClientController` itself**, and
`resolve()` (`:858-865`) falls back to `m.getDeclaringClass()` when the method has no annotation. I
confirmed `/v3/client/create` is declared **in `ClientController` at `:91`**, not inherited from
`AdminController` — so `getDeclaringClass()` *is* `ClientController`, and a class-level
`@RequiresFunction` added there would flip `:314` from `""` to that set and red the pin. Had that
handler been inherited, the row would have been decorative; it is not. §3.8's stated hazard is
genuinely closed.

*Note, not a finding:* no mutant actually exercised the class-level scenario. §5.2 item 3 asks for
the three constant-removal mutants plus the structural property, and that is what was delivered; the
class-level case is guarded by construction, which I verified by reading `resolve()` and the
declaration site rather than by running it.

## §5.2 P5 item 4 — blast radius re-run with positive control, all three functions, date recorded — **VERIFIED**

I did not take the numbers on trust. I re-ran the traversal myself against
`dev_wh01_om1` (`select current_database()` returned `dev_wh01_om1`), user → group → role →
function via `mywms_group_mywms_user` → `mywms_group_mywms_role` → `mywms_role_mywms_function` →
`mywms_function`:

| function | holders | hold **none** of the previous eleven | control: bogus allow-list |
|---|---|---|---|
| `WEB_UI_VIEW_STOCK_UNIT_RECORD` | **45** | **0** | 45 |
| `WEB_UI_VIEW_STOCK_UNIT` | **44** | **0** | 44 |
| `WEB_UI_VIEW_CONTAINER` | **45** | **0** | 45 |
| `WEB_UI_VIEW_NOT_A_REAL_FUNCTION` (control) | **0** | 0 | 0 |

**45 / 44 / 45 and 0 / 0 / 0 — an exact match to what the annotation claims.** Both positive
controls behave as controls must: swapping the eleven for a non-existent function returns the *full*
holder count (so the zero is a measurement, not a dead query), and a non-existent target function
returns zero holders (so the query can produce a zero at all).

I also re-measured the one claim carried forward from the old comment, since it sits inside the
rewritten block: **`WEB_UI_VIEW_CLIENT` is held by exactly `ROLE000007 (super-admin)`, `ROLE000056`
and `ROLE000101`** — confirmed — and `inventory-manager` (ROLE000001), `outbound-manager`
(ROLE000004), `receiving` (ROLE000006) and `CS-REP` (ROLE000019) all have `has_client = false`, so
"a CLIENT-only gate 403s" those four is true as stated.

**Date recorded:** yes, in the annotation — `SBDEV-3410 P5 (2026-09-22) …
re-measured that day on dev_wh01_om1 … with two positive controls`, plus the Q6 one-tenant caveat.

**L3 (Low) — one sentence in the rewritten block has no date.** *"Measured on dev_wh01_om1, CLIENT
is held only by ROLE000056, ROLE000101 and super-admin…"* is present tense with no
derived-at-a-date marker, sitting two lines above a block that models the correct practice. Role→function
grants change (§3.8 says so itself); this is the same class of rot as the dispatcher counts, just
about roles instead. It happens to be **true today** — I verified it — which is precisely why it
will be believed after it stops being true. One `(2026-09-22)` fixes it.

---

## §3.8 "Three edits, all in one commit" — **VERIFIED**

| Edit | Status |
|---|---|
| 1 — three constants onto `@RequiresFunction`, eleven → fourteen | ✓ |
| 2 — same three onto the `row(…)` varargs | ✓ |
| 3 — prose in **both** files restated as the rule, count derived-at-a-date | ✓ (L1/L2/L3 above) |
| all in one commit | ✓ in the diff; commit **message** still `wip:` |

The §3.8 correction about the pin being **bidirectional** is faithfully reproduced in the test
comment, and I confirmed it against the code: `row()` (`:66-68`) and `resolve()` (`:858-865`) both
normalise through `String.join("+", new TreeSet<>(…))`, compared with `equals` — exact set equality
in both directions, so neither side can drift alone. The comment's claim matches the mechanism.

---

## What I went looking for and what I found

**A sibling sweep, since the whole point of P5 is prose about this gate rotting in more than one
place.** I swept `src` for `allClients`, `getClients`, `13 dispatcher` and `six report`, and swept
`sbdocs` for `allClients`.

**M1 (Medium) — a third file still describes this gate the old way, and it was not touched.**

`src/test/java/net/aim_ai/wms/integration/controller/ClientControllerLegacyIntegrationTest.java:120-121`:

> `// FunctionGuardInterceptor … gates ClientController's detailView/allClients/detailViewById behind WEB_UI_VIEW_CLIENT.`

After P5, `allClients` is **not** behind `WEB_UI_VIEW_CLIENT` — it is behind an ANY-of fourteen of
which `WEB_UI_VIEW_CLIENT` is one member. The test itself still passes (its fixture grants
`WEB_UI_VIEW_CLIENT`, which satisfies the ANY-of), so nothing goes red and nothing in the suite will
ever tell you. That is what makes it worth raising rather than ignoring: it is the *same defect
class* P5 exists to fix — a hand-written statement of this gate, in a third file, now wrong — and
§3.8 notes that `WEB_UI_VIEW_CLIENT` alone has zero callers on a matching screen, so someone
eventually removing it from the set is a live possibility. That person breaks `getClientsTest` and
reads a comment pointing them at the wrong cause. **Fix: one clause — `detailView/detailViewById`
behind `WEB_UI_VIEW_CLIENT`, `allClients` behind an ANY-of set that includes it.** Cheap now,
misleading later.

**Informational — `sbdocs/1-Projects/wms2/plan/SBDEV-3158-remaining-mvc-read-gating.md`** records
`allClients`'s "resulting 11-way ANY-of shipped as-is" (`:1085`) and an inventory row (`:304`).
Those are dated historical decision records on another ticket, not live assertions, and §5.2 P5 does
not ask for them. Flagging only so the post-merge `verify-docs` pass is not surprised.

**Checks that came back clean:**
- No other `src` file references `/v3/client/allClients` as a gate.
- `FunctionGuardArchTest`'s AC-4c keyed ANY-of map (`:705`, `:904`) does **not** key
  `ClientController#allClients`, so no second pin needed updating. Its `hasSize(productionGuardedSet().size())`
  (`:971`) counts guarded *methods*, which widening an existing annotation's varargs cannot change.
- `Set.of(functions)` in `row()` throws on duplicates — the 14 are distinct, and the green run proves it.

---

## Outstanding — not conformance failures, but not done either

1. **The commit message.** `wip: p5 for suite run` must become a real message before the PR.
2. **Full-suite evidence is not in this lane.** `/tmp/p5-green.log` ran **one test class**
   (`[INFO] Running net.aim_ai.wms.security.Sbdev3017TrancheGateContextTest`, 5 tests). The floor's
   "full suite against the known baseline" is discharged by the `clean verify` in flight elsewhere,
   not by anything I saw. **Do not read this report as full-suite evidence.**
3. **Stale red in `target/`.** `target/surefire-reports/` in this worktree is timestamped 22:43 —
   the last *mutation* run (`WEB_UI_VIEW_CONTAINER`, RED). Anyone opening those XML/txt files reads
   a failure for code that is not on the branch. Harmless if you know; a trap if you don't.
   `mvn clean` before any run whose report anyone will read.
4. **Plan document not yet updated.** All four §5.2 P5 checkboxes are still `[ ]`, the status line at
   `:30` still says *"P5–P6 not started"*, and there is no §9E-equivalent P5 record. Expected at this
   stage (pre-PR), listed so it is not forgotten.

---

## Verdict

| Item | Verdict |
|---|---|
| §5.2 P5 #1 — annotation + pin, three constants, same commit | **VERIFIED** |
| §5.2 P5 #2 — restate both files' counts as the invariant | **VERIFIED** (L1, L2, L3) |
| §5.2 P5 #3 — mutation-check ×3, full varargs, ungated row | **VERIFIED** |
| §5.2 P5 #4 — blast radius re-run, controls, all three, dated | **VERIFIED** |
| §3.8 — three edits, one commit | **VERIFIED** |

# OVERALL: PASS

P5 built what §5.2 P5 and §3.8 specify. Every measurement I was asked to check reproduced exactly —
15 files / 26 sites / 7 reports at SHA `9254bf5`, holders 45 / 44 / 45, blocked 0 / 0 / 0, both
positive controls live — and the two rewritten comments do not overclaim: every factual assertion in
them that I could measure, I measured, and all of them held.

**PASS is conditional on nothing.** The four Outstanding items are process, and M1/L1/L2/L3 are
improvements to prose, not defects in the change. **I would fix M1 in this commit** — it is a
one-clause edit, it is the same defect class the commit exists to eliminate, and leaving a third
stale description of this gate behind while fixing two of them is the outcome §3.8 is arguing
against.

**I did not run maven.** Full-suite conformance is not graded here.
