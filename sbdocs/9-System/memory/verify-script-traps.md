---
name: verify-script-traps
description: "Every measured way a verify-script row lies — false greens on broken code, false reds on correct code, template/helper defects and their blast radius, and the baseline that makes a score mean something"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 4c682f0d-57d6-482e-918a-0ea6e57af94e
  modified: 2026-08-28T13:10:08.983Z
---

**Bottom line: prefer a JUnit/Jest test to a verify row every single time.** A row is a grep over source
text; a test observes behaviour. Write a row only for a cross-file or cross-repo invariant a test
genuinely cannot see — does this file exist, is this constant named, does this Flyway migration contain
`INSERT INTO x`, does the web repo's constant match the API repo's. Everything behavioural — fail-open vs
fail-closed, which role gets what, ordering, atomicity — belongs in a test, because a *decision* is not
present in the source text, only its spelling (see [§Policy](#5-rows-that-cannot-assert-what-they-claim)).
Per the tier router, T0/T1/T2 get **no verify script at all**; only T3 gets an opt-in ≤15-row one.

> **This file supersedes nine separate memories.** Old `name:` slugs, so a stale `[[old-name]]` link
> elsewhere is still traceable:
> `verify-script-template-perl-helpers-fail-open` ·
> `verify-script-rows-go-stale-when-a-refactor-moves-code` ·
> `verify-script-undefined-check-fn-reads-as-honest-fail` ·
> `verify-script-unbounded-lazy-gap-loses-containment` ·
> `verify-script-over-tempered-gap-and-comment-satisfied-negatives` ·
> `verify-plan-template-mvn-test-passes-always-fails` ·
> `verify-script-project-root-convention-is-split` ·
> `verify-template-helpers-were-broken-and-inherited-by-51-scripts` ·
> `verify-rows-cannot-assert-policy-only-jest-can`
>
> Not merged and deliberately separate despite the name: `verify-spring-bean-changes-clean-compile-and-context-load`
> (Spring DI) and `verify-never-is-vacuous-if-control-flow-cannot-reach-it` (Mockito `verify(never())`).

---

## 1. False GREENs — rows that pass against broken code

> **The headline measurement, and it is not from these nine memories.** On **SBDEV-3003 Slice 2,
> 12 of 16 deliberately-broken implementations scored a FULL GREEN** against the original rows — the
> row layer then needed its own adversarial review lane, and three further row defects were still found
> during implementation. Source: `.claude/skills/wms-triage/SKILL.md:91` (added here 2026-08-28; a merge
> lane correctly refused to assert it because it appears in no memory file, only in the skill). Keep the
> provenance — it is the single strongest argument for §6's two-direction baseline, and for preferring a
> JUnit/Jest test to a row in the first place.

**1.1 `file_not_contains` fails OPEN on a missing file.** The template's own negative helper was
`file_not_contains() { ! grep -qE "$1" "$2"; }`. On a missing file `grep -qE` exits 2 and the leading `!`
flips that non-zero into a **PASS** — *"the forbidden pattern is gone"* when nothing was examined. Every
NEGATIVE assertion therefore greens when the path is wrong or the file doesn't exist yet. Proven
empirically. `file_contains` (positive) is **safe** as written: grep's exit 2 stays non-zero ⇒ FAIL; the
`[ -f ]` guard is harmless but not required there. Minimum fix:
`file_not_contains() { [ -f "$2" ] || return 1; ! grep -qE "$1" "$2"; }`

**1.2 The hand-rolled perl `file_contains_ml` fails OPEN the same way.**

```bash
file_contains_ml() { PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null; }
```

With `-0777 -ne`, if the file can't be opened the implicit loop body **never executes**, so neither
`exit 0` nor `exit 1` runs and perl terminates with status **0** ⇒ PASS. `2>/dev/null` hides the warning.
Any assertion targeting a **new** file — exactly the ones proving a fix was implemented — reports PASS
while the file does not exist. Caught 2026-07-30 on `verify-SBDEV-2778-*.sh`: **4 assertions about
`ReturnAdviceAutoReceiveService.java` passed before a single line was written.**

*Scope correction, verified 2026-07-31 by running the helpers:* `verify-plan-template.sh` does **NOT**
define any `perl` helper. Its full helper set is `run`, `skip`, `file_contains`, `file_contains_n_times`,
`file_not_contains`, `class_has_method`, `mvn_test_passes`. The perl fail-open lives only in individual
scripts that hand-rolled it (e.g. `verify-SBDEV-2778-*.sh`) — do not go looking for it in the template.

**1.3 An unbounded lazy gap `.*?` under `/s` loses containment.** When a row goes red because a *correct*
change moved code (a guard inserted ahead of the matched statement), the instinct is to loosen the
positional part to `.*?`. Under perl's `/s` that gap matches newlines and **has no boundary**, so it spans
past the end of the construct being asserted. The row then passes on a file containing a wrong
implementation *plus* a correct construct somewhere else.

Measured on **SBDEV-2930**, row `A-picking-rb` ("resetState rebuilds from the factory"):

```
resetState\s*\(\s*state\s*\)\s*\{.*?Object\.assign\(\s*state\s*,\s*initialState\(\)\s*\)
```

A PoC with `resetState` hand-listing **2 of 20** fields plus a later
`resetAll(state) { Object.assign(state, initialState()) }` reported **PASS**. The row's own stated
reasoning ("a hand-listed reset fails, because it contains no such `Object.assign`") was true only by
accident of what else happened to be in the file. Fix — tempered greedy, refusing to cross the construct's
closing line:

```
resetState\s*\(\s*state\s*\)\s*\{(?:(?!\n  \},).)*?Object\.assign\(\s*state\s*,\s*initialState\(\)\s*\)
```

`[^}]*` is **not** an alternative: it stops at the first `}`, so it breaks the moment the body contains a
nested block (`if (…) { … }`) — which is what forced the `.*?` in the first place. Validate both
directions: it must match every real site (no false FAIL, including the one whose guard prompted the
loosening) **and** reject the wrong-implementation PoC. See [§2.1](#2-false-reds--rows-that-fail-against-correct-code)
for the mirror-image over-tempered failure.

**1.4 A row can pass on DEAD CODE.** Same SBDEV-2930 session: `M1-release` grepped for
`clearInterval(liveTimer)` inside `resetState` and stayed green after `setTimer` stopped assigning
`liveTimer` — the matched call could never fire. A row asserting a resource is released must **also**
assert the ownership assignment exists.

**1.5 Vacuous negatives.** `file_not_contains 'receivingService.receiveGoods('` on a controller is
meaningless when the fix *moves* that call into a new service — it passes by construction either way.
Prefer ordered/adjacency positives: `file_contains_ordered 'validate\(.*?adviceRepository\.save\('` proves
the *sequence*, not just presence.

**1.6 A single grep satisfied by the wrong site.** On SBDEV-2732, `unitloadTypePermitted` matched the
record's **Ctx accessor**, so the row passed with the facade's `isUnitloadTypePermitted` service call
deleted. When a behaviour is deliberately implemented twice (facade short-circuit + evaluator skip),
assert each half separately.

**1.7 Prefix / substring matches.** Constant names share prefixes constantly here.
`grep -q WEB_UI_VIEW_STOCK_UNIT` is satisfied by `WEB_UI_VIEW_STOCK_UNIT_RECORD`, and JS `toContain('functions')`
is satisfied by `functionsLoaded`. **Boundary every constant name**: `grep -qE "${c}([^A-Za-z0-9_]|$)"`, and in
JS `/(?<![A-Za-z0-9_])functions(?![A-Za-z0-9_])/`.

**1.8 `mvn_test_passes` greens on a test that was never written.** `-DfailIfNoTests=false` exits 0 when the
class doesn't exist — and `jest --testPathPattern` with no match likewise exits 0. So "the new test passes"
greens before the test exists. Require the file first:
`[ -n "$(find <testroot> -name "$1.java" -print -quit)" ] || return 1`

**1.9 `Skipped:` and a zero count both certify nothing.** A class-level `@Disabled` reports
`Tests run: 1, Failures: 0, Errors: 0, Skipped: 1` with exit 0 — green while running nothing. And when
tests live in `@Nested` classes, surefire also emits `Tests run: 0, Failures: 0, Errors: 0` for the *outer*
class, which alone satisfies `Tests run: [0-9]+, …` — so **deleting every nested class still passes**. Both
holes were measured in a first repair attempt that checked only exit code plus the bare `[0-9]+` pattern.
See the working replacement in [§4.2](#4-template--helper-defects-and-their-blast-radius).

**1.10 A perl syntax error is a PASS in `multiline_not_contains`.** The `/`-delimiter break of
[§2.2](#2-false-reds--rows-that-fail-against-correct-code) fails *closed* in the positive helper — but in the
negative helper a non-zero exit reads as "forbidden construct absent", so the same bug is a false green
there.

**1.11 `bash -c '...'` with SINGLE quotes does not receive the outer `$WEB`/`$MIG`.** This breaks rows in
*both* directions at once: a `perl -0777 -ne` row then reads **empty stdin and exits 0 → PASS asserting
nothing**, while a row guarded by `[ -f "$X" ]` sees `[ -f "" ] → FAIL` forever and reads as honest
work-not-done. **`export` every variable the rows use**, and keep a `[ -f … ] || exit 1` in each row anyway.

---

## 2. False REDs — rows that fail against correct code

**2.1 Over-tempered gap (SBDEV-3005).** Matching "this `@Transactional` belongs to *this* method" needs a
tempered gap, but tempering it with `public` can never match — the method declaration itself contains
`public`:

```bash
# permanently RED
'@Transactional\(\s*value\s*=\s*"tenantTransactionManager"(?:(?!\bpublic\b|@Transactional).)*?replaceRoleFunctions'
# works: forbid ';' and '@' instead — spans annotation continuation lines and
# modifiers, cannot leap over another method body or another annotation
'@Transactional\(\s*value\s*=\s*"tenantTransactionManager"(?:(?![;@]).)*?\breplaceRoleFunctions'
```

**2.2 Delimiter break on `/` in the pattern (SBDEV-2632, 2026-08-02).** Interpolating the pattern into
`m/.../` breaks on any slash it contains — `application/json`, `/cycleCount/export` — so perl sees a
terminated match plus a syntax error and the check FAILS against correct code. **Three rows failed this
way.** Always pass the pattern through the environment:
`VERIFY_PAT="$1" perl -0777 -ne 'exit($_ =~ /$ENV{VERIFY_PAT}/s ? 0 : 1)' "$2"`

⚠ **This one recurs because the fix is PER-SCRIPT.** Documented 2026-08-02 from SBDEV-2632 — and
`verify-SBDEV-2643-*.sh` still shipped the unguarded form until **2026-08-12**, where it made two rows
unsatisfiable. **When you touch any verify script, fix both multiline helpers first, before adding rows**,
otherwise every slash-bearing pattern you write is dead on arrival.

**2.3 `.{0,N}?` character windows are sized in CHARACTERS, so comments blow them out.**
`'private void writeExportError.{0,700}?response\.resetBuffer\(\)'` failed because the plan mandated a
6-line explanatory comment before the asserted line, putting it **793** chars from the anchor. Worse, it
NOMATCHed in *both* directions, so the counter-test appeared to prove teeth it didn't have. **Scope by
method, not by character distance:**

```bash
java_method() { [ -f "$1" ] || return 1; awk "/(public|private|protected|static).*[ ]$2\\(/,/^    \\}\$/" "$1"; }
# then: java_method "$F" myMethod | grep -qE '...'
```

Immune to comment length and reformatting.

**2.4 A comment satisfies a negative grep.** A `file_not_contains 'addRoleToFunction\(30L, 200L\)'` row
stayed red because the *explanatory comment* in the fixed test quoted the old literal. When a row asserts a
literal's absence, never repeat that literal in nearby prose — and say so in the comment so the next author
doesn't reintroduce it.

**2.5 Two regex FLAVOURS in one script.** `file_contains` / `file_not_contains` are **ERE** (`grep -qE`);
the `multiline_*` helpers are **perl**. A PCRE construct handed to the ERE helper is matched **literally** —
`(?i)`, lookahead, `\s`, non-greedy `?` — so the row is red against correct code. Hit 2026-08-12 on
SBDEV-2643 `A4-t-empty`: `file_contains '(?i)(blankName|...)'` never matched a conformant test named
`...BlankNameIsIdenticalTo...`. **Check which helper you are calling before using any PCRE syntax**; move
the assertion to `multiline_contains` if you need it.

**2.6 A row punishes defensive code.** `H5` required a bare `this.$kc.ready` and went red against the
**correct** `this.$kc?.ready`. **Accept both spellings of a correct fix.**

**2.7 An inverted row.** `B6` v3 forbade the shape `if (!required) return` — which **passed** the fail-open
implementation and **failed** the correct guard. Getting the polarity wrong is a false red and a false green
in one row.

**2.8 Rows go stale when a refactor moves code.** A row like `file_contains 'getUseforgoodsin' "$VALIDATOR"`
(in a `verify-SBDEV-XXXX.sh`) encodes **where** a predicate lives, not just that it exists. Extract that predicate into a new class and the
row goes red while the code is correct — **six did on SBDEV-2732 step C** (the `PutawayDestinationRules`
extraction out of `PutawayDestinationValidator`).

*Why this one bites harder than an ordinary stale row:* the framing invites dismissal. The refactor was
behaviour-preserving, **129 putaway tests and 50 untouched characterization assertions** were green, so the
reds looked like noise — and were reported as `0 fail`. They appear in *the same run that proves the refactor
worked*, which is exactly when they get rationalised.

- Before a move/extract refactor, grep the ticket's verify script for the symbols being moved. **Repoint
  those rows in the same commit as the move**; they are part of the refactor.
- Prefer a **chain-level** helper over a file pin when a concern legitimately spans several files:
  `chain_contains() { grep -qE "$1" "$FACADE" || grep -qE "$1" "$EVALUATOR"; }`. Verify first that the pattern
  is in exactly ONE of them, or the check is vacuous with respect to the other.
- Pin to a specific file only when both files legitimately contain the symbol and you need to detect its
  removal from one. `getStaginglane` is the SBDEV-2732 example: the facade reads it to decide whether to load
  the area, the evaluator reads it to reject at SKU scope, so only a `$RULES`-pinned row can catch its loss
  from the evaluator.
- **Proximity regexes silently encode "these sit in one block"** — `getStaginglane[\s\S]{0,400}getTransferlane`
  broke because the extraction put them ~100 lines apart *and in the reverse order*. Prefer N independent
  presence checks; the old regex covered only **2 of the 4** lane flags anyway.

**2.9 Asserting dead code.** If a plan faithfully ports a branch that turns out unreachable, the script
demands the implementer add dead branches to go green. Check reachability before asserting.

**2.10 Wrong `PROJECT_ROOT` shape reds every path row** — see [§3.1](#3-rows-that-vanish-or-fail-for-a-non-code-reason).

**2.11 `mvn -q` reds a green suite** — see [§4.2](#4-template--helper-defects-and-their-blast-radius). It fails
in the direction that looks like *your work* is broken, so the natural reaction is to go hunting in the code.

---

## 3. Rows that vanish, or fail for a non-code reason

**3.1 The `PROJECT_ROOT` convention is split 37/7.** `sbdocs/9-System/scripts/verify-*.sh` have **two
incompatible conventions**. Measured 2026-08-20 across the **44** that define one: **37 expect the SUB-REPO
root** (`…/v2/wms2-api`) and **7 expect the MONOREPO root** (`…/wms-claude`, usually computed from
`BASH_SOURCE`). SBDEV-2968 is mono-rooted; SBDEV-3011, 3005, 2995, 2994 and most others are repo-rooted.

Detect it, never assume it:
`grep -m1 -oE 'PROJECT_ROOT="\$\{PROJECT_ROOT:-[^}]*\}"' <script>` — a default containing `/v1/` or `/v2/` is
repo-rooted; a `$(…)` default is mono-rooted.

Pass the wrong shape and *every* path assertion fails, which prints as **a plausible wall of honest-looking
reds rather than as an error**. A probe reported SBDEV-3011 as `3 pass / 51 fail` against a plan whose real
score is `54 pass / 0 fail`, and the output looked entirely credible.
`plan-state.sh <TICKET>` handles both and prints which root is authoritative — see
[[plan-state-probe-beats-reading-plan-status]].

**3.2 Toolchain off PATH records as an ordinary FAIL.** Rows that shell out to `mvn`/`yarn` fail for want of a
binary; bash's **127** records as a normal FAIL. This alone turned SBDEV-3011's `54/0/1` into `49/5/1`.
`mvn`/`java` are not on PATH in this environment (SDKMAN) — so these rows silently `SKIP` or FAIL for a
**tooling** reason. Prepend
`~/.sdkman/candidates/{java,maven}/current/bin` in the script and `skip` with an **explicit reason** if still
absent, so a toolchain gap never masquerades as a code failure. SBDEV-2802's `A6` skipped unnoticed in **all 3
rounds** this way.

**3.3 A wired-but-undefined check function records as a normal FAIL.** `run <id> <desc> <fn>` executes `"$@"`
and records any non-zero exit as FAIL. If a `run` row names a function that **does not exist**, bash returns
127 (`command not found`), stderr is swallowed by `>/dev/null 2>&1`, and the row prints a perfectly ordinary
`FAIL` — **indistinguishable from an honest "this deliverable isn't built yet."** The script can carry a
permanently-red row that no implementation will ever turn green.

It survives every normal check: `bash -n` passes (the name is valid syntax), the run output looks correct, and
negative-testing the *tree* doesn't catch it because the row is red in both the pre-fix and post-fix states.
Only a structural audit of the script itself finds it. It arises most easily when **two lanes edit one script**
(renamed function on one side, old `run` row on the other) — exactly how it appeared on SBDEV-2643 r2.

**3.4 ⚠ WORSE VARIANT: an undefined function in an `if` GUARD deletes rows INVISIBLY** (2026-08-12, SBDEV-2643
r7). The audit in [§6.2](#6-structural-audits-of-the-script-itself) only scans `run`/`blocked`/`skip` rows, so
it misses the guard — and the guard is the more dangerous position:

```bash
if phase_selected 2 || phase_selected 1; then      # phase_selected exists in SBDEV-2732's script, NOT this one
    run A4-ctl  "..."  check_A4_controller_name_param
    ... 6 more rows
fi
```

The guard returns 127, the `if` evaluates **false**, and **all 7 rows vanish from the output entirely**. Not
FAIL — *absent*. The total stayed `23 pass / 63 fail`, so the run looked **unchanged rather than broken**,
which is strictly worse than a permanently-red row: a red row at least announces itself. Prefer no guard at
all when the surrounding blocks are unguarded (copying a conditional idiom between scripts is how this arises).

**3.5 `run` cannot distinguish "assertion false" from "tool failed to execute".** A verify run reported
`48 pass, 1 fail` right after `jest --clearCache`; the failing row(s) were ones that shell out (jest, perl).
Five re-runs gave `49 pass, 0 fail` and the isolated grep was 0/20 failures. **Re-run before believing either
number** — and never treat a single red row as proof of missing work without reproducing it.

---

## 4. Template / helper defects and their blast radius

Two defects sat in `sbdocs/9-System/templates/verify-plan-template.sh` **for weeks** while every generated
script inherited them, and while **eight separate memories** recorded ways verify scripts lie.

**4.1 `file_not_contains` fail-open (mechanics in [§1.1](#1-false-greens--rows-that-pass-against-broken-code)) —
inherited by 51 scripts** (26 active, in two spellings).

**4.2 `mvn_test_passes` is broken BOTH ways — permanently RED here, false-GREEN at
[§1.8](#1-false-greens--rows-that-pass-against-broken-code) — and is inherited by 38 scripts** (10 active, several **inline copies the
helper fix cannot reach**). The shipped helper:

```bash
mvn_test_passes() {
    mvn test -Dtest="$1" -DfailIfNoTests=false -q 2>&1 \
        | grep -qE "BUILD SUCCESS|Tests run.*Failures: 0.*Errors: 0"
}
```

`-q` suppresses INFO, so Maven emits **neither** `BUILD SUCCESS` **nor** any `Tests run:` summary. Measured on
a passing class: **exit code 0, 1223 bytes of output, zero matches** for either pattern. Re-derived
independently **3×** (SBDEV-2802's `A6`; from scratch on SBDEV-2781 2026-08-05, where
`mvn test -Dtest=ViewDtoServiceUnitTest -q` exits 0 while emitting no matching line). **Gate on the exit code,
never on stdout.** Working replacement, with the `Skipped:` and count-floor guards of
[§1.9](#1-false-greens--rows-that-pass-against-broken-code):

```bash
mvn_test_passes() {           # $1 = class, $2 = minimum test count
    local out rc count
    out=$(mvn test -Dtest="$1" -DfailIfNoTests=false -Djacoco.skip=true 2>&1); rc=$?
    [ "$rc" -eq 0 ] || return 1
    count=$(printf '%s' "$out" \
        | grep -oE "Tests run: [0-9]+, Failures: 0, Errors: 0, Skipped: 0" \
        | grep -oE "[0-9]+" | sort -rn | head -1)
    [ -n "$count" ] && [ "$count" -ge "${2:-1}" ]
}
```

**4.3 Both fixed 2026-08-21**, with a mutation-checked guard test installed at
`sbdocs/9-System/templates/test-verify-plan-template-helpers.sh` (**9 assertions**; M1/M2/M3 each red when the
corresponding fix is removed). **All 26 active fail-open copies and 10 broken mvn rows patched.**
*(This supersedes the older note in the perl-helpers memory that said "the shared template still has all of
these bugs — fix it there when convenient"; that was written before the 2026-08-21 sweep. Scripts carrying
hand-rolled inline copies still need the guards added individually.)*

**4.4 The lesson is not about bash.** Memory captured the *lesson* eight times and left the *cause* in place.
Tooling defects — `.claude/**`, `sbdocs/9-System/**` — must be **fixed directly** the first time they are hit.
Writing a memory about a broken tool is not a fix; it just means the next person rediscovers it.

**4.5 Also found in the 2026-08-21 sweep:**
- **12 of 52 active verify scripts had default roots pointing at `/Users/np1076/dev/spk/owl/…`** — a macOS path
  from a laptop Nam no longer uses. Combined with the fail-open helper, their negative rows passed silently.
  All rewritten to `/home/nampark/dev/wms-claude`.
- **Two live hooks in `.claude/settings.json`** carried the same dead path, including one gating `wms-api`
  commits behind `mvn test` — it had been doing nothing. Now `${CLAUDE_PROJECT_DIR:-/home/nampark/dev/wms-claude}`,
  so a future machine change cannot break it.
- A relative file target is **NOT** a defect when the script `cd`s to its root first — all **23** scripts with
  unprefixed targets do. I nearly reported **125 false findings** by skipping that check.
- Real contradictions surfaced once the masking was removed: `260424-oms-notification` (status *implemented*,
  20 fail), `SBDEV-2095` (*implemented*, 5 fail), `260429-replenish-unit-load-stale-cache` (*verified*, 2 fail —
  `setUnitLoadsForItem`/`clearUnitLoadsForItem` exist nowhere in v1). Each needs a triage: partial
  implementation, or rows left stale by a design change. v1 ones are **observations only**.

**4.6 Reference helper set, all guards applied:**

```bash
file_contains()          { [ -f "$2" ] && grep -qE "$1" "$2" 2>/dev/null; }
file_not_contains()      { [ -f "$2" ] && ! grep -qE "$1" "$2" 2>/dev/null; }
file_contains_ml()       { [ -f "$2" ] || return 1; PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null; }
file_not_contains_ml()   { [ -f "$2" ] || return 1; ! PATTERN="$1" perl -0777 -ne 'exit 0 if /$ENV{PATTERN}/m; exit 1' "$2" 2>/dev/null; }
multiline_contains()     { [ -f "$2" ] || return 1; MLC_PAT="$1" perl -0777 -ne 'exit($_ =~ /$ENV{MLC_PAT}/s ? 0 : 1)' "$2"; }
multiline_not_contains() { [ -f "$2" ] || return 1; MLC_PAT="$1" perl -0777 -ne 'exit($_ =~ /$ENV{MLC_PAT}/s ? 1 : 0)' "$2"; }
```

Reference scripts that already carry all the guards:
`sbdocs/9-System/scripts/verify-SBDEV-2781-expected-return-date-stray-time-and-tz-shift.sh`, and
`verify-SBDEV-2643-sku-default-putaway-location-ui.sh` as of **r7 (2026-08-12)** — its header documents traps
[§2.2](#2-false-reds--rows-that-fail-against-correct-code),
[§2.5](#2-false-reds--rows-that-fail-against-correct-code), the vacuous-negative case, and the guard variant of
[§3.4](#3-rows-that-vanish-or-fail-for-a-non-code-reason).

**4.7 Environment leaks into every score.** The script inherits the caller's environment, so `JAVA_HOME` and
`PATH` must reach JDK 21 + maven or the rows fail for a third, unrelated reason — see
[[run-v1-wms-api-testcontainers-its-locally]] for the SDKMAN paths.

**4.8 `archunit_store` churn — two measurements, both kept.** The later note (2026-08-19, SBDEV-3005) says the
maven rows rewrite the tracked `src/test/resources/archunit_store/…` file and the template never restores it, so
a clean-tree check after a full verify run shows spurious modifications; add
`git checkout -- src/test/resources/archunit_store` at the end. The earlier note (SBDEV-2802/2781) measured that a
**targeted** `-Dtest=<Class>` does **not** mutate it (verified clean `git status` afterwards) and that only a full
`mvn test` does. They may both be true for their own row shapes — assume churn is possible and restore the file.

**Whenever this helper family is touched: fix the template under its own ticket, and re-check any past
"N pass, M fail" sign-off where the failures were mvn rows.** Found while signing off
[[sbdev-3005-role-function-composite-key-swap]].

---

## 5. Rows that cannot assert what they claim — policy belongs in Jest/JUnit

On **SBDEV-2967-B (2026-08-21)** I wrote **six** verify rows in one session that read as coverage and asserted
nothing, plus one that failed a *correct* implementation. Every one was a **presence grep standing in for a
behavioural assertion**. Independent review lanes measured all of them.

| Row | What it looked like | What it actually did |
|---|---|---|
| `B6` "unclassified route is DENIED" | grep for the noun `UNGATED_ROUTES` | mobile's **fail-OPEN** guard satisfies it verbatim |
| `B6` v3 | forbade the shape `if (!required) return` | **INVERTED** — passed fail-open, failed the correct guard |
| `H1`/`H2` "functions\* not persisted" | `toContain('functions')` | `'functions'` is a **substring of `functionsLoaded`** → excluding only the two booleans while still persisting the entitlement array passed |
| `H5` "awaits `$kc.ready`" | required bare `this.$kc.ready` | red against the **correct** defensive `this.$kc?.ready` |
| `H12` "migration INSERTs the function row" | `/mywms_function.{0,600}CONST/s` | the **join-table grant** names both strings ~60 chars apart → the exact defect it existed to catch shipped green |
| `H13` "grants the 5 orphans" | `grep -q WEB_UI_VIEW_STOCK_UNIT` | satisfied by the **prefix** inside `WEB_UI_VIEW_STOCK_UNIT_RECORD` |

**Why:** a policy is a *decision* — deny vs allow, which role gets what. Source text does not contain the
decision, only its spelling. Two implementations with opposite behaviour differ by whether a branch returns
`undefined` or a redirect, which no regex over the file can see.

**How to apply:**
1. **Policy → Jest/JUnit, always.** `deniesWhenFunctionsCannotBeLoaded` catches in one behavioural assertion
   what three regex attempts at `B6` could not. Keep verify rows for facts a grep really can settle: does the
   file exist, is the constant named, does the migration contain an `INSERT INTO x`.
2. **A deleted row beats a misleading one.** I deleted `B6` and left a comment naming all three failed attempts
   so nobody re-adds it.
3. **Negative-test with a FAKE artifact, not just a mutation.** Writing a throwaway `V2.2.19__x.sql` that grants
   the rows but omits the function INSERT is what exposed `H12`. A migration row can only be trusted after you
   have seen it red against a plausibly-wrong file.
4. **Boundary every constant name** — see [§1.7](#1-false-greens--rows-that-pass-against-broken-code).
5. **Accept both spellings of a correct fix** (`.x.ready` and `.x?.ready`) or the row punishes defensive code.

---

## 6. How to baseline a script so its result means something

### 6.1 Both directions, always

A negative test alone (replay the pre-fix file, see it FAIL — [[negative-test-verify-scripts-before-trusting-them]])
proves a row *can* be red. It does **not** prove the row can ever be green. Both halves are needed:

- **Red baseline.** Replay the pre-fix tree and confirm the fail count is non-zero, and that the *named* rows are
  the ones that go red.
- **Green simulation.** After the FAIL baseline, simulate the fix in a scratch copy and confirm each multi-line
  row flips GREEN, plus confirm it stays RED for near-miss variants (annotation on a different method, no
  annotation, bare `@Transactional`; the wrong-implementation PoC of
  [§1.3](#1-false-greens--rows-that-pass-against-broken-code)).
- **Validate against the code the plan MANDATES — comments and indentation included.** SBDEV-2632's first pass
  certified **"45 pass, 0 fail, no false-reds"** against a synthetic fixture that had *stripped the comment
  block* — which is exactly what hid the character-window trap of
  [§2.3](#2-false-reds--rows-that-fail-against-correct-code). A stripped-down fixture is not the specified code.
- **Confirm the row COUNT changes when you add rows.** Adding 7 rows to an unimplemented tree must raise the fail
  count by exactly 7. If the totals don't move, the rows aren't running — that arithmetic is the cheapest
  detector for the vanishing-rows class ([§3.4](#3-rows-that-vanish-or-fail-for-a-non-code-reason)).
- **Grade with the right root and the right PATH** before you believe any score
  ([§3.1](#3-rows-that-vanish-or-fail-for-a-non-code-reason), [§3.2](#3-rows-that-vanish-or-fail-for-a-non-code-reason)).

### 6.2 Structural audits of the script itself

```bash
# wired but undefined  (127 => a FAIL nobody can ever fix)
# defined but unwired  (a check that silently never runs)
python3 - script.sh <<'PY'
import re,sys
s=open(sys.argv[1]).read()
defs=set(re.findall(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{',s,re.M))
calls=set(re.findall(r'^\s*(?:run|blocked|skip)\s+\S+\s+"[^"]*"\s+(check_[A-Za-z0-9_]+)',s,re.M))
print("undefined:", sorted(calls-defs))
print("unwired:", sorted(d for d in defs if d.startswith('check_') and d not in calls))
PY
grep -oE '^check_[A-Za-z0-9_]+\(\)' script.sh | sort | uniq -d   # duplicate defs: last one silently wins
grep -oE '^\s*run +[A-Za-z0-9-]+' script.sh | awk '{print $2}' | sort | uniq -d   # duplicate row ids
```

Extend it to cover **guards** ([§3.4](#3-rows-that-vanish-or-fail-for-a-non-code-reason)):

```bash
{ grep -oE '^\s*run [A-Za-z0-9-]+\s+"[^"]*"\s+([a-zA-Z_0-9]+)' script.sh | awk '{print $NF}'
  grep -oE '^\s*(if|elif)\s+[a-z_][a-zA-Z_0-9]*' script.sh | awk '{print $NF}'; } | sort -u > /tmp/c
grep -oE '^[a-z_][a-zA-Z_0-9]*\(\)' script.sh | tr -d '()' | sort -u > /tmp/d
comm -23 /tmp/c /tmp/d | grep -vE '^(then|echo|return|true|false)$'   # must be empty
```

**Cross-check the plan document against the script:** every `` `row-id` `` the plan cites must be a row the
script actually prints. SBDEV-2643 r1 cited **six** ids that had drifted (`A2-neg-resolver` vs the printed
`A2-neg-res`) and one — `B2-cors` — that had **never existed at all**.

---

Related: [[negative-test-verify-scripts-before-trusting-them]] (the baseline discipline this file assumes),
[[plan-state-probe-beats-reading-plan-status]], [[run-v1-wms-api-testcontainers-its-locally]],
[[sbdev-3005-role-function-composite-key-swap]], [[sbdev-2821-tier1-putaway-candidate-surfacing]],
[[sbdev-2930-mobile-page-reset-and-picking-timer-landmine]], [[consolidate-tickets-dont-file-one-per-finding]].
