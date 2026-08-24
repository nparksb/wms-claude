---
title: "SBDEV-3003 Slice 2 — adversarial verify-row discrimination measurement"
ticket: "SBDEV-3003"
type: review
lane: verify-row-discrimination
created: 2026-08-20
tags: [review, wms2, verify-script]
---

# Bottom line

**None of `G1`, `G1b`, `G2`, `G3` can be trusted as written.** All four go green against a
correct implementation, and all four also go green against implementations that are broken in
exactly the ways the plan says matter most.

**9 of the 12 originally-scoped broken shadows scored `39 pass, 0 fail, 3 skip` — byte-identical
to the correct implementation.** That includes `B1` (a `/v3` prefix instead of a one-path
allow-list — the highest-blast-radius mistake available in this slice), `B2` (auto-derive still
applies, the exact defect `G1b` exists to catch), `B4` (counter registered but never
incremented), `B7` (bridge mode still applies), and `B5` (UI suppresses *every* 409 including
`idempotency-key-conflict`).

`G1b` additionally **false-REDs** a fully correct implementation that names its scope boolean
anything other than one of five hard-coded alternates (shadow `C2`).

Replacement rows are proposed and measured below. With them, **all 16 broken shadows are caught
and both correct variants stay fully green.**

---

## 1. Method and shadow validity

All measurement used symlink shadow roots under
`/tmp/claude-1000/-home-nampark-dev-wms-claude/a03caab0-8c81-4fda-a714-b973cdf7d26a/scratchpad/shadows/`.
Builder: `.../scratchpad/mkshadow.sh` — every top-level entry is a symlink into the real
worktree except the mutated file(s) and their ancestor directories.

Mutated files, per shadow: `src/main/java/net/aim_ai/wms/landlord/config/IdempotencyFilter.java`,
`src/main/java/net/aim_ai/wms/service/RestIdempotencyService.java`,
`src/main/java/net/aim_ai/wms/SecurityConfiguration.java` (api) and `store/moveStock.js` (ui).

**Shadow validity check (done before any measurement was trusted):** an unmutated `pristine`
shadow was diffed row-for-row against a run on the real worktrees.

```
real worktrees   Result: 35 pass, 4 fail, 3 skip
pristine shadow  Result: 35 pass, 4 fail, 3 skip
diff of all 42 row lines: IDENTICAL row-for-row
```

No real worktree, and no file under `sbdocs/` other than this report, was modified.

`SKIP_MVN=1` throughout, so `M1`/`M2`/`M3` are `SKIP` in every run and **no shadow was
compile-checked**. The correct implementation is plausible Java (imports, constructor, and the
`SecurityConfiguration` call site were all updated), but it is *not* proven to compile — stated
here rather than papered over. No proposed row depends on compilation.

### The shadows

| Shadow | What it is |
|---|---|
| `pristine` | unmutated worktree — the FAIL baseline |
| **`correct`** | G-a…G-d + E implemented as §4 intends |
| **`C2`** | `correct`, refactored: scope boolean renamed `v3Scope` → `dedupeEnrolled`. **Still fully correct** — a false-red probe |
| `B1` | `uri.startsWith(V3_PREFIX)` where `V3_PREFIX="/v3/"`, instead of the allow-list |
| `B2` | path enrolled, counter added, bridge immunity added — but the auto-derive branch is **untouched** |
| `B3` | comment-only. A `TODO(SBDEV-3003)` naming the allow-list, the prefix trap, bridge mode, the `MeterRegistry` counter and both 409s. **Zero logic change** |
| `B3b` | `B3` with the comment's word order swapped so the counter name precedes `MeterRegistry` |
| `B4` | counter registered, `.increment()` deleted |
| `B4b` | counter incremented on `CLAIMED` instead of `REPLAYED`/`IN_FLIGHT` |
| `B7` | `G-c` reverted: filter calls the 4-arg `tryClaim`, service's `if (bridgeMode)` unconditional |
| `B8` | allow-list holds `"/v3/stockUnit/transferStockToUnitLoad"` — a *different* path |
| `B15` | `DEDUPE_PATH_ALLOWLIST.stream().anyMatch(uri::startsWith)` — B1's blast radius, but the only `/v3` literal is still the exact path |
| `B16` | the intermediate fail-open branch exists but is conditioned on `maxBodyBytes == 0`, so an allow-listed path still auto-derives |
| `B5` | UI: `if (error.response.status === 409) return` — suppresses `idempotency-key-conflict` too |
| `B6` | UI: `const idempotencyKey = crypto.randomUUID()` inside the action — per attempt, not per intent |
| `B10` | UI: nonce is `btoa(...)` — violates the server's `[A-Za-z0-9_\-]{1,64}` regex, so it earns 400 not dedupe |
| `B11` | UI: header sent, per-intent nonce, but **no** 409 discrimination at all |
| `B17` | UI: nonce cleared in a `finally` — every retry gets a fresh nonce |

`B1`, `B15`, `B16` and `B17` were built to defeat the *proposed* rows, not just the current ones.

---

## 2. Measurement matrix — CURRENT rows

Every cell is a real run. `Result:` lines are the script's own output.

| Shadow | G1 | G1b | G2 | G3 | raw `Result:` |
|---|---|---|---|---|---|
| `pristine` | FAIL | FAIL | FAIL | FAIL | `35 pass, 4 fail, 3 skip` |
| **`correct`** | PASS | PASS | PASS | PASS | `39 pass, 0 fail, 3 skip` |
| **`C2` (still correct)** | PASS | **FAIL** ❌ | PASS | PASS | `38 pass, 1 fail, 3 skip` |
| `B1` prefix scope | **PASS** ❌ | **PASS** ❌ | **PASS** ❌ | PASS | `39 pass, 0 fail, 3 skip` |
| `B2` auto-derive ungated | **PASS** ❌ | **PASS** ❌ | **PASS** ❌ | PASS | `39 pass, 0 fail, 3 skip` |
| `B3` comment-only | **PASS** ❌ | FAIL | FAIL | PASS | `37 pass, 2 fail, 3 skip` |
| `B3b` comment-only, reordered | **PASS** ❌ | FAIL | **PASS** ❌ | PASS | `38 pass, 1 fail, 3 skip` |
| `B4` counter never incremented | **PASS** ❌ | **PASS** ❌ | **PASS** ❌ | PASS | `39 pass, 0 fail, 3 skip` |
| `B4b` counter on wrong outcome | **PASS** ❌ | **PASS** ❌ | **PASS** ❌ | PASS | `39 pass, 0 fail, 3 skip` |
| `B7` bridge mode still applies | **PASS** ❌ | **PASS** ❌ | **PASS** ❌ | PASS | `39 pass, 0 fail, 3 skip` |
| `B8` wrong path in allow-list | **PASS** ❌ | **PASS** ❌ | **PASS** ❌ | PASS | `39 pass, 0 fail, 3 skip` |
| `B15` prefix-match on full path | **PASS** ❌ | **PASS** ❌ | **PASS** ❌ | PASS | `39 pass, 0 fail, 3 skip` |
| `B16` wrong branch condition | **PASS** ❌ | **PASS** ❌ | **PASS** ❌ | PASS | `39 pass, 0 fail, 3 skip` |
| `B5` UI blanket 409 | PASS | PASS | PASS | **PASS** ❌ | `39 pass, 0 fail, 3 skip` |
| `B6` UI nonce per attempt | PASS | PASS | PASS | **PASS** ❌ | `39 pass, 0 fail, 3 skip` |
| `B10` UI base64 nonce | PASS | PASS | PASS | **PASS** ❌ | `39 pass, 0 fail, 3 skip` |
| `B11` UI no 409 discrimination | PASS | PASS | PASS | FAIL | `38 pass, 1 fail, 3 skip` |
| `B17` UI nonce cleared in finally | PASS | PASS | PASS | **PASS** ❌ | `39 pass, 0 fail, 3 skip` |

❌ = false green (or, for `C2`/G1b, a false red).

### Per-row verdict

**`G1` — FALSE GREEN on `B3`, `B3b`, `B8`. Untrustworthy.**
`file_contains 'v3/stockUnit/transferStock'` is an unanchored substring grep with no
comment exclusion.
- `B3`/`B3b`: a `// TODO(SBDEV-3003)` comment turns it green with `shouldNotFilter()` untouched.
- `B8`: `"/v3/stockUnit/transferStockToUnitLoad"` **contains** the searched substring, so
  enrolling the wrong endpoint reads as success. `transferStockToUnitLoad` is a real symbol in
  `StockunitBusinessService`, so this is a live confusion, not a contrived one.

**`G1b` — FALSE GREEN on `B1`, `B2`, `B4`, `B4b`, `B7`, `B8`, `B15`, `B16`, and FALSE RED on
`C2`. Worse than useless — it is anti-correlated with correctness.**
The pattern is `sha256HexComposite … (?:v3Scope|isV3|V3_DEDUPE|v3Allowlist|v3Path)`. Two
independent failures:
1. It requires only that *one of five hard-coded identifiers* appears somewhere after
   `sha256HexComposite` inside the same method. In `B2` the counter guard `if (v3Scope)` in the
   REPLAYED branch supplies that token while the auto-derive branch is completely ungated. **The
   row's entire stated purpose is to catch exactly `B2`, and it does not.**
2. Rename the boolean and a fully correct implementation goes red (`C2`, `dedupeEnrolled`) —
   which the script's own header warns is "indistinguishable from unfinished work".

**`G2` — FALSE GREEN on `B3b`, `B4`, `B4b`, `B1`, `B2`, `B7`, `B8`, `B15`, `B16`. Untrustworthy.**
The gap `(?:[^\n]|\n)*?` is fully unbounded (equivalent to `.*` under `/s`), so this is just
"name fragment somewhere, `MeterRegistry` somewhere later".
- `B3b` proves **the TODO-comment trap the row was rewritten to close is still open.** `B3` only
  stayed red by accident of word order: its comment said "a `MeterRegistry` … `duplicate_transfer`
  Counter" (registry first). Swapping to "a `duplicate_transfer` Counter registered on the
  injected `MeterRegistry`" — equally natural English — turns it green. A row whose verdict
  depends on the word order of a TODO comment is not an assertion.
- `B4`: `.register(meterRegistry)` with `.increment()` deleted is green. A counter that never
  increments is indistinguishable from one that does.
- `B4b`: incrementing on `CLAIMED` — i.e. counting *successes* as duplicates, inverting the
  metric's meaning — is green.

**`G3` — FALSE GREEN on `B5`, `B6`, `B10`, `B17`. Untrustworthy.**
`(?i)Idempotency-Key … 409` tempered to the action body. Any mention of the header plus any
mention of 409 in the same action satisfies it.
- `B5` is the specific defect §3 names: "a blanket 'suppress 409' is a defect, not the fix". The
  row cannot see it.
- `B6` regenerates the nonce per HTTP attempt — §4's "deduplicates nothing while every test stays
  green" — green.
- `B10` sends a base64 nonce that the filter rejects with `400 invalid-idempotency-key` before
  dedupe is ever reached — green.
- `B17` clears the nonce in a `finally`, so a retry sends a new one — green.
- It only caught `B11`, the one shadow that does nothing at all.

---

## 3. Proposed replacement rows

Twelve rows replace the four. Full runnable harness (with the shared helpers) is at
`.../scratchpad/proposed.sh`. Two new shared helpers are required — they close the
"a comment quoting the literal satisfies the row" class for both positive and negative rows:

```bash
# Strip comment lines (// , * , /*) BEFORE matching, so a comment can neither satisfy a
# negative row nor stand in for the code a positive row requires.
code_contains()     { [ -f "$2" ] || return 1; grep -vE '^[[:space:]]*(//|\*|/\*)' "$2" | grep -qiE "$1"; }
code_not_contains() { [ -f "$2" ] || return 1; ! { grep -vE '^[[:space:]]*(//|\*|/\*)' "$2" | grep -qiE "$1"; }; }
```

Also add `V2_RIS="$V2_API/src/main/java/net/aim_ai/wms/service/RestIdempotencyService.java"`
to the paths block.

Every row below is a **named shell function or a documented helper call**, not an inline
`bash -c` with nested perl quoting. That is deliberate: the first draft of `G2a` and `G4` were
written as inline `bash -c` and both false-REDDED the correct shadow purely from quoting
(`grep -E` does not honour an inline `(?i)`, and `\$_` inside a double-quoted nested perl was
mangled). A row that is red for a quoting reason is the "exit 127 reads as an honest FAIL" trap
in a different coat.

### Scope

```bash
# G1 — the exact path is a COMPLETE string literal on a CODE line. Both halves are load-bearing:
# the closing quote (or "/v3/stockUnit/transferStockToUnitLoad", a real sibling symbol, satisfies
# the row — measured on shadow B8) and the ^[^/*]* comment exclusion (or a TODO satisfies it —
# measured on B3/B3b).
run G1 "v2 IdempotencyFilter: the exact /v3 transfer path is enrolled on a code line" \
    file_contains '^[^/*]*"/v3/stockUnit/transferStock"' "$V2_IDEMP"

# G1c (NEW — plan §6 "scope is an allow-list, not a /v3 prefix") ------------------------------
# Three conjuncts, all over comment-stripped source:
#   1. every /v3 string literal in code IS the exact allow-listed path (catches B1's "/v3/"
#      constant and B8's wrong path);
#   2. no prefix/regex test whose argument names v3;
#   3. every startsWith in this file targets a "/rest literal — the only legitimate prefix test
#      here. This is what catches B15 (anyMatch(uri::startsWith) over the full-path allow-list),
#      which has B1's blast radius while keeping the exact path as its only /v3 literal.
# Conjunct 3 is an intentional tripwire: adding any new non-/rest prefix test will red this row
# and force a decision rather than silently widening scope.
# NOTE: this is a GUARD row — it passes on the pristine tree (there are no /v3 literals yet). It
# is only meaningful paired with G1, which is the progress row. Do not read a green G1c alone as
# "the allow-list is right".
g1c_allowlist_not_prefix() {
  local f=$1 code
  [ -f "$f" ] || return 1
  code=$(grep -vE '^[[:space:]]*(//|\*|/\*)' "$f")
  printf '%s\n' "$code" | grep -oE '"/v3[^"]*"' \
    | grep -vxF '"/v3/stockUnit/transferStock"' | grep -q . && return 1
  printf '%s\n' "$code" | grep -qiE '(startsWith|regionMatches|indexOf|matches)\([^)]*v3' && return 1
  printf '%s\n' "$code" | grep -oE 'startsWith.{0,7}' \
    | grep -v '^startsWith("/rest' | grep -q . && return 1
  return 0
}
run G1c "v2 IdempotencyFilter: scope is a one-path allow-list, NOT a /v3 prefix" \
    g1c_allowlist_not_prefix "$V2_IDEMP"
```

### Key policy

```bash
# G1b (REPLACES the identifier-guessing version) ---------------------------------------------
# Asserts the code SHAPE, naming no implementation identifier: between the header lookup and the
# auto-derive there must be an INTERMEDIATE branch that either fails open (chain.doFilter, G-b(i))
# or rejects (SC_BAD_REQUEST, G-b(ii)) — the alternation means the row does not pre-judge which of
# §4's two options is chosen. Requiring `key = sha256HexComposite(` as the FINAL else also pins
# that auto-derive stays reachable for /rest/**, so the row cannot be satisfied by deleting it.
# Indentation floors ([ ]{8,}) exclude javadoc lines, which start "     * ".
run G1b "v2 IdempotencyFilter: an intermediate scope branch skips auto-derive (auto-derive kept for /rest)" \
    file_contains_ml 'getHeader\(IDEMPOTENCY_HEADER\)(?:[^\n]|\n(?!    \}))*?\n[ ]{8,}\} else if \((?:[^\n]|\n(?!    \}))*?(?:chain\.doFilter\(|SC_BAD_REQUEST)(?:[^\n]|\n(?!    \}))*?\n[ ]{8,}key = sha256HexComposite\(' "$V2_IDEMP"

# G1d (NEW) — and that branch tests the SAME boolean that was computed from the request path.
# BACKREFERENCE, so it is name-agnostic: C2's rename to dedupeEnrolled still passes. Without this
# row, G1b's shape is satisfied by an else-if on any unrelated condition while an allow-listed
# path keeps auto-deriving — measured on shadow B16.
run G1d "v2 IdempotencyFilter: the intermediate branch tests the path-derived scope flag" \
    file_contains_ml 'final boolean (\w+) = \w+\((?:[^\n]|\n(?!    \}))*?\n[ ]{8,}\} else if \(\1\)' "$V2_IDEMP"
```

### Counter

```bash
# G2 (REPLACES the unbounded-gap version) — registered AND incremented in ONE chain, starting on
# a code line at >= 4-space indent. Catches B4 (register with no .increment()) and both
# comment-only shadows.
run G2 "v2 IdempotencyFilter: the counter is registered AND incremented in one chain" \
    file_contains_ml '\n[ ]{4,}(?:Counter\.builder\(|\w*[Rr]egistry\.counter\()(?:[^\n]|\n(?!    \}))*?\.increment\(\)' "$V2_IDEMP"

# G2a — and it is the DUPLICATE-TRANSFER counter, named on a code line. code_contains strips
# comments, which is the whole difference from the current row: measured on B3b, a TODO comment
# naming "a duplicate_transfer Counter registered on the injected MeterRegistry" satisfies the
# current G2 outright.
run G2a "v2 IdempotencyFilter: the counter name identifies duplicate transfers (code, not a TODO)" \
    code_contains '(duplicate[_.]?transfer|transfer[_.]duplicate|idempotency[_.]duplicate)' "$V2_IDEMP"

# G2b — it fires on the RIGHT outcomes. Two tight containments, each tempered on a 12-space `}`
# so the match cannot leave its branch: the counter call must sit between `ClaimResult.REPLAYED) {`
# and getCachedResponse(, and between `ClaimResult.IN_FLIGHT) {` and the in-flight error literal.
# Catches B4b (incremented on CLAIMED — which inverts the metric's meaning), which an
# order-only regex over the whole method cannot see.
g2b_counter_on_dedupe_outcomes() {
  local f=$1
  [ -f "$f" ] || return 1
  file_contains_ml 'ClaimResult\.REPLAYED\)\s*\{(?:[^\n]|\n(?![ ]{12}\}))*?(?:\.increment\(\)|count\w*\()(?:[^\n]|\n(?![ ]{12}\}))*?getCachedResponse\(' "$f" || return 1
  file_contains_ml 'ClaimResult\.IN_FLIGHT\)\s*\{(?:[^\n]|\n(?![ ]{12}\}))*?(?:\.increment\(\)|count\w*\()(?:[^\n]|\n(?![ ]{12}\}))*?idempotency-in-flight' "$f" || return 1
  return 0
}
run G2b "v2 IdempotencyFilter: the counter fires inside BOTH the REPLAYED and IN_FLIGHT branches" \
    g2b_counter_on_dedupe_outcomes "$V2_IDEMP"
```

### Bridge-mode immunity

```bash
# G4 (NEW — plan §2 / §6 bridge-mode immunity) -----------------------------------------------
# Both halves are required, because either alone is inert: the filter must pass a per-request
# suppression argument to tryClaim (a 5th arg after bodyHash), AND the service's bridge branch
# must be conjoined with it. Asserting the property `bridge-mode=false` would be a config claim,
# not a code guarantee (§2). The `[^;]*?` gap keeps the match inside one statement while still
# tolerating the nested parens of request.getMethod() / request.getRequestURI().
g4_bridge_mode_immunity() {
  local f=$1 s=$2
  [ -f "$f" ] && [ -f "$s" ] || return 1
  file_contains_ml 'tryClaim\([^;]*?bodyHash,\s*[!\w]' "$f" || return 1
  file_contains '^[^/*]*if \(bridgeMode[ )]*&&' "$s" || return 1
  return 0
}
run G4 "v2: the allow-listed path is immune to bridge mode (filter arg + service conjunct)" \
    g4_bridge_mode_immunity "$V2_IDEMP" "$V2_RIS"
```

### Client (`wms2-mobile-ui store/moveStock.js`)

```bash
# G3 (REPLACES the "header mentioned + 409 mentioned" version) — the header is actually SENT on
# the transferStock POST: the $post for that path, a headers object, and the header name, all
# inside the one action body (tempered on `\n  },`).
run G3 "v2 store/moveStock.js: the Idempotency-Key header is sent on the transferStock POST" \
    file_contains_ml '\$post\(.\/stockUnit\/transferStock.(?:[^\n]|\n(?!  \},))*?headers(?:[^\n]|\n(?!  \},))*?.Idempotency-Key.' "$V2_STORE"

# G3b — the two 409s are discriminated on the response BODY, and there is NO status-only 409
# branch. §3: "Discriminate on error.response?.data?.error, NOT on the status code — a blanket
# 'suppress 409' is a defect, not the fix." The third conjunct is what encodes that: it FORBIDS
# `status === 409`. Catches B5 (blanket suppress) and B11 (no discrimination at all).
g3b_two_409s_discriminated() {
  local f=$1
  [ -f "$f" ] || return 1
  code_contains 'idempotency-in-flight'    "$f" || return 1
  code_contains 'idempotency-key-conflict' "$f" || return 1
  code_not_contains 'status *={2,3} *409'  "$f" || return 1
  return 0
}
run G3b "v2 store/moveStock.js: both dedupe 409s discriminated by body, no status-only branch" \
    g3b_two_409s_discriminated "$V2_STORE"

# G3c — the nonce is per INTENT, not per attempt. Four conjuncts:
#   1. module-scope state (`let x = null`) — not a local, not Vuex state (the whole Vuex root is
#      persisted to localStorage['vuex-mobile'], so a persisted nonce would replay a later
#      deliberate move for the server's 7-day retention window);
#   2. cleared in the initialize mutation, so the NEXT intent gets a fresh nonce;
#   3. NOT minted inside the transferStock action (catches B6);
#   4. NOT dropped in a finally, which hands every retry a fresh nonce (catches B17).
g3c_nonce_per_intent() {
  local f=$1
  [ -f "$f" ] || return 1
  file_contains '^let [A-Za-z_][A-Za-z0-9_]* = null' "$f" || return 1
  file_contains_ml 'initialize\(state\)\s*\{(?:[^\n]|\n(?!  \},))*?\w+ = null' "$f" || return 1
  file_not_contains_ml 'async transferStock\(context, data\)\s*\{(?:[^\n]|\n(?!  \},))*?=\s*(?:crypto\.randomUUID|uuidv4|uuid|nanoid)\(' "$f" || return 1
  file_not_contains_ml 'async transferStock\(context, data\)\s*\{(?:[^\n]|\n(?!  \},))*?finally\s*\{(?:[^\n]|\n(?!  \},))*?= null' "$f" || return 1
  return 0
}
run G3c "v2 store/moveStock.js: the nonce is per-intent module state, not per HTTP attempt" \
    g3c_nonce_per_intent "$V2_STORE"

# G3d — the nonce charset satisfies the server's [A-Za-z0-9_\-]{1,64} key regex
# (IdempotencyFilter:69). A base64 nonce earns 400 invalid-idempotency-key BEFORE dedupe runs, so
# the feature is silently absent while every UI test passes. GUARD row: passes on the pristine
# tree, meaningful only paired with G3/G3c.
run G3d "v2 store/moveStock.js: the nonce is not base64 (server key regex)" \
    code_not_contains "btoa\(|toString\('base64'\)" "$V2_STORE"
```

---

## 4. Measurement matrix — PROPOSED rows

Every cell is a real run of `proposed.sh` against that shadow pair.

| Shadow | G1 | G1c | G1b | G1d | G2 | G2a | G2b | G4 | G3 | G3b | G3c | G3d |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `pristine` | FAIL | pass* | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | FAIL | pass* |
| **`correct`** | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| **`C2` renamed, still correct** | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| `B1` prefix scope | **FAIL** | **FAIL** | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| `B2` auto-derive ungated | PASS | PASS | **FAIL** | **FAIL** | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| `B3` comment-only | **FAIL** | pass* | **FAIL** | **FAIL** | **FAIL** | **FAIL** | **FAIL** | **FAIL** | PASS | PASS | PASS | PASS |
| `B3b` comment-only reordered | **FAIL** | pass* | **FAIL** | **FAIL** | **FAIL** | **FAIL** | **FAIL** | **FAIL** | PASS | PASS | PASS | PASS |
| `B4` counter never incremented | PASS | PASS | PASS | PASS | **FAIL** | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| `B4b` counter wrong outcome | PASS | PASS | PASS | PASS | PASS | PASS | **FAIL** | PASS | PASS | PASS | PASS | PASS |
| `B7` bridge mode still applies | PASS | PASS | PASS | PASS | PASS | PASS | PASS | **FAIL** | PASS | PASS | PASS | PASS |
| `B8` wrong path enrolled | **FAIL** | **FAIL** | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| `B15` prefix-match on full path | PASS | **FAIL** | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| `B16` wrong branch condition | PASS | PASS | PASS | **FAIL** | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| `B5` UI blanket 409 | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | **FAIL** | PASS | PASS |
| `B6` UI nonce per attempt | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | **FAIL** | PASS |
| `B10` UI base64 nonce | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | **FAIL** |
| `B11` UI no discrimination | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | **FAIL** | PASS | PASS |
| `B17` UI nonce cleared in finally | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | **FAIL** | PASS |

`pass*` = a GUARD row that legitimately passes on the pristine tree. `G1c` and `G3d` are
negative/guard rows and must not be counted as progress; they are documented as such in the row
comments above.

**Result: 16/16 broken shadows caught. 0 false greens. 0 false reds — both `correct` and the
renamed `C2` are fully green.** Ten of the twelve rows are red on the pristine tree, satisfying
the script's all-red-baseline discipline.

---

## 5. Residual blind spots — what grep still cannot see

Stated plainly rather than implied. These are **not** row defects; they are the boundary of the
technique, and the plan's §5 already names the coverage that closes them.

1. **`G1d` proves the intermediate branch tests a boolean produced by *some* single-argument
   call — not that the call consults the allow-list.** `final boolean v3Scope = alwaysFalse(uri)`
   passes. Closed only by §5 test 1 (`shouldNotFilter` directly: allow-listed path in, a
   *different* `/v3` POST out) and §5 test 2 (key policy).
2. **No row proves the filter is on the chain for a non-`/rest` path.** `standaloneSetup` MockMvc
   does not build the filter chain (§5), and the v2 Testcontainers lane cannot boot (SBDEV-2217).
   **Only curl matrix rows 6 and 7 cover this**, and they are the rows that catch the
   catastrophic designs. Treat the matrix as required evidence, not optional.
3. **`G2`/`G2b` prove the increment is written, not that it fires.** §5 test 4 (assert the
   registry, not a string in the source) is the only thing that does.
4. **`G3c` proves the nonce is module state, not that an axios retry reuses it.** Worth noting:
   `wms2-mobile-ui/plugins/axios.js:23-35` retries only on 401/403 for Keycloak token refresh and
   replays the original request config, so a header set in the action *is* preserved across that
   retry automatically. The live risk is therefore a second **dispatch** of the action, not the
   axios-retry path — which `G3c` conjuncts 3 and 4 do cover. §5 test 5 should still pin it.
5. **Nothing was compile-checked** (`SKIP_MVN=1`). `M2` must be run for real before any of this
   is trusted end to end.

---

## 6. Trust verdict

| Row | As written | Verdict |
|---|---|---|
| `G1` | substring grep, no comment exclusion | **Do not trust.** False-greens `B3`, `B3b`, `B8`. Replace. |
| `G1b` | five hard-coded identifiers after `sha256HexComposite` | **Do not trust — actively misleading.** False-greens the one defect it exists to catch (`B2`) plus 7 others, and false-reds a correct rename (`C2`). Replace. |
| `G2` | unbounded gap, no comment exclusion | **Do not trust.** The TODO-comment trap it was rewritten to close is still open (`B3b`); also green on `B4` and `B4b`. Replace. |
| `G3` | header mentioned + 409 mentioned | **Do not trust.** False-greens `B5`, `B6`, `B10`, `B17` — every UI near-miss except doing nothing. Replace. |

Recommendation: replace all four with the twelve measured rows in §3, and record in the plan
that `G1c` and `G3d` are guard rows exempt from the all-red baseline (joining `P1`–`P3`).

---

## 7. Audit appendix — every raw `Result:` line, and the shadow-validity check

### 7.1 Shadow construction

Builder: `.../scratchpad/mkshadow.sh <srcRoot> <dstRoot> <relpath-to-make-real>...`
Every top-level entry of `srcRoot` is symlinked into `dstRoot`; only the named relative paths are
real copies, and only their ancestor directories are real directories (their other children stay
symlinks). Mutant shadows were built **from the `correct` shadow** rather than from the worktree,
so each one differs from `correct` by exactly one deliberate defect — the diffs are one to five
hunks each and were printed and eyeballed at build time. `B3`/`B3b` are the exceptions: they are
built from the pristine worktree, because "comment-only" means *no logic change at all*.

Runner: `.../scratchpad/vrun.sh <V2_API> <V2_UI>` — pins `V1_API`/`V1_UI` to the real v1
worktrees and passes `SKIP_MVN=1`, so only the v2 roots vary between runs.

Proposed-row harness: `.../scratchpad/proposed.sh <V2_API> <V2_UI>` — standalone, carries its own
copy of the script's helper library plus the two new `code_contains` / `code_not_contains`
helpers. The real verify script was never edited (`md5 a0083a5990f6d1846304fc14d2b1a6e1`,
417 lines, unchanged at start and end of this lane).

### 7.2 Mandatory shadow-validity check — PASSED for all 18 shadows

For every run, the **38 rows other than `G1`/`G1b`/`G2`/`G3`** were diffed against the
real-worktree run. **Zero drift in all 18 shadows** — no shadow was malformed, and no
measurement in this report is void on that ground.

```
  OK    pristine                         38 unrelated rows match baseline
  OK    correct                          38 unrelated rows match baseline
  OK    C2-renamed-correct               38 unrelated rows match baseline
  OK    B1-prefix-scope                  38 unrelated rows match baseline
  OK    B2-autoderive-ungated            38 unrelated rows match baseline
  OK    B3-comment-only                  38 unrelated rows match baseline
  OK    B3b-comment-only-reordered       38 unrelated rows match baseline
  OK    B4-counter-no-incr               38 unrelated rows match baseline
  OK    B4b-counter-wrong-out            38 unrelated rows match baseline
  OK    B7-bridge-applies                38 unrelated rows match baseline
  OK    B8-wrong-path                    38 unrelated rows match baseline
  OK    B15-prefix-on-fullpath           38 unrelated rows match baseline
  OK    B16-wrong-branch-cond            38 unrelated rows match baseline
  OK    B5-ui-blanket-409                38 unrelated rows match baseline
  OK    B6-ui-nonce-per-att              38 unrelated rows match baseline
  OK    B10-ui-base64-nonce              38 unrelated rows match baseline
  OK    B11-ui-no-409-disc               38 unrelated rows match baseline
  OK    B17-ui-nonce-cleared-finally     38 unrelated rows match baseline
ALL SHADOWS VALID: zero unrelated-row drift across all runs
```

### 7.3 Raw `Result:` lines, verbatim

Every run of the **real, unmodified** verify script. `39 pass, 0 fail, 3 skip` is a full green —
i.e. a verdict indistinguishable from the correct implementation.

```
real worktrees (control)         Result: 35 pass, 4 fail, 3 skip
pristine  (shadow control)       Result: 35 pass, 4 fail, 3 skip
correct                          Result: 39 pass, 0 fail, 3 skip
C2-renamed-correct               Result: 38 pass, 1 fail, 3 skip   <- FALSE RED (G1b)
B1-prefix-scope                  Result: 39 pass, 0 fail, 3 skip   <- full green, BROKEN
B2-autoderive-ungated            Result: 39 pass, 0 fail, 3 skip   <- full green, BROKEN
B3-comment-only                  Result: 37 pass, 2 fail, 3 skip
B3b-comment-only-reordered       Result: 38 pass, 1 fail, 3 skip
B4-counter-no-incr               Result: 39 pass, 0 fail, 3 skip   <- full green, BROKEN
B4b-counter-wrong-out            Result: 39 pass, 0 fail, 3 skip   <- full green, BROKEN
B7-bridge-applies                Result: 39 pass, 0 fail, 3 skip   <- full green, BROKEN
B8-wrong-path                    Result: 39 pass, 0 fail, 3 skip   <- full green, BROKEN
B15-prefix-on-fullpath           Result: 39 pass, 0 fail, 3 skip   <- full green, BROKEN
B16-wrong-branch-cond            Result: 39 pass, 0 fail, 3 skip   <- full green, BROKEN
B5-ui-blanket-409                Result: 39 pass, 0 fail, 3 skip   <- full green, BROKEN
B6-ui-nonce-per-att              Result: 39 pass, 0 fail, 3 skip   <- full green, BROKEN
B10-ui-base64-nonce              Result: 39 pass, 0 fail, 3 skip   <- full green, BROKEN
B11-ui-no-409-disc               Result: 38 pass, 1 fail, 3 skip
B17-ui-nonce-cleared-finally     Result: 39 pass, 0 fail, 3 skip   <- full green, BROKEN
```

**12 of the 16 broken shadows produce `39 pass, 0 fail, 3 skip` — a full green.** The other four
lose one or two rows and would still read as "nearly done".

The proposed rows do not run inside the verify script, so they have no `Result:` line of their
own; their per-row verdicts are the §4 matrix, produced by `proposed.sh` and reproducible with
the same shadow roots.

### 7.4 Counting conventions used in the sentinel

- **`shadows`** = distinct shadow *configurations* measured = 18 (2 controls + 2 correct variants
  + 14 broken). That is 20 shadow root directories, since api-side and ui-side roots pair up.
- **`rows_measured`** = 4 current + 12 proposed = 16.
- **`false_greens` = 14.** Counted per (row × shadow) cell, and **scoped to the row's own axis** —
  a row is only charged with a false green when the shadow is broken in the thing that row grades.
  `G1` scope axis: `B1`, `B3`, `B3b`, `B8`, `B15` = 5. `G1b` key-policy axis: `B2`, `B16` = 2.
  `G2` counter axis: `B3b`, `B4`, `B4b` = 3. `G3` client axis: `B5`, `B6`, `B10`, `B17` = 4.
  (The looser count — any green cell on any broken shadow — is 34, but it over-charges rows for
  defects outside their remit, so 14 is the number to act on.)
- **`false_reds` = 1**: `G1b` on `C2`, a fully correct implementation whose scope boolean is named
  `dedupeEnrolled` instead of one of the row's five hard-coded alternates.
- The proposed rows contribute **0** to both counts: 0 false greens and 0 false reds across all
  18 shadows.

### 7.5 NOT CHECKED

Explicitly out of scope or not done, so nothing here is implied by a green line above:

1. **Compilation.** Every run used `SKIP_MVN=1`; `M1`/`M2`/`M3` are `SKIP` in all 19 runs. No
   shadow was compiled. `mvn clean compile` on the real implementation is still required.
2. **Runtime behaviour of any kind.** No filter chain was booted, no request was issued, no
   counter was read from a registry, no DB was touched. The plan's §5 curl matrix (especially
   rows 4, 6, 7) remains the only evidence for filter-chain enrolment and key policy end to end.
3. **The unit tests in §5.** Their absence is not asserted by any row here, current or proposed;
   no `T`-family row covers Slice 2. If the four §5 automated tests matter, they need their own
   rows — that gap is unaddressed by this lane and is a live hole, since the residual blind spots
   in §5 of this report are all delegated to exactly those tests.
4. **Jest.** No `wms2-mobile-ui` spec was written or run for the nonce/409 behaviour, and the
   `correct-ui` shadow adds none. `wms2-web-ui`-style pre-existing suite failures were not a
   factor because no Jest run happened at all.
5. **`SecurityConfiguration` / DI.** The `MeterRegistry` constructor parameter was added to the
   correct shadow's call site for coherence, but **no row grades it**, and no Spring context was
   loaded. A missing `MeterRegistry` bean would be a startup failure that this entire report is
   blind to.
6. **v1 rows.** Untouched by design (v2-only lane); `A*`, `C1`, `D2*`, `D5*`, `H*`, `T1`, `T2`
   were only ever used as the unrelated-row drift control.

<!-- LANE COMPLETE: shadows=18 rows_measured=16 false_greens=14 false_reds=1 -->

---

# ADDENDUM (not the lane's work) — `G5` / `G6` for the architect lane's two Highs

Added 2026-08-20 by the orchestrator, **after** the lane completed. Attributed separately so the
lane's sentinel above still describes exactly what the lane measured.

The lane's twelve rows covered G-a…G-d and the client. They did **not** cover the two High findings
from the architect lane — G-e (never cache a 2xx carrying an `errors` body) and G-f (require auth in
code, not via `app.idempotency.require-auth`). Those are the two findings that separate a fix from a
regression, so leaving them to the unit tests alone was not acceptable.

Six new shadows were built on top of the lane's `correct-api`, using its own `mkshadow.sh`:

| Shadow | Defect |
|---|---|
| `correct2` | G-e + G-f correctly implemented (scope flag hoisted above the auth gate) |
| `Be1` | comment-only TODO naming both fixes, zero logic |
| `Be2` | detects the `errors` body, only `LOG.warn`s it |
| `Be3` | `errors` check present but **not scoped** — would change `/rest/**` behaviour too |
| `Bf1` | auth gate left as `if (requireAuth)` |
| `Bf2` | gate widened by an **unrelated** condition, `if (requireAuth \|\| enforce)` |

Measured inside the **real** verify script (`SKIP_MVN=1`, `V2_UI=correct-ui` throughout):

```
pristine-api    Result: 40 pass,  9 fail, 3 skip    G5=FAIL G6=FAIL
correct-api     Result: 47 pass,  2 fail, 3 skip    G5=FAIL G6=FAIL
correct2-api    Result: 49 pass,  0 fail, 3 skip    G5=PASS G6=PASS   <- full green
C2-api          Result: 47 pass,  2 fail, 3 skip    G5=FAIL G6=FAIL
Be1-api         Result: 47 pass,  2 fail, 3 skip    G5=FAIL G6=FAIL
Be2-api         Result: 48 pass,  1 fail, 3 skip    G5=FAIL G6=PASS
Be3-api         Result: 48 pass,  1 fail, 3 skip    G5=FAIL G6=PASS
Bf1-api         Result: 48 pass,  1 fail, 3 skip    G5=PASS G6=FAIL
Bf2-api         Result: 48 pass,  1 fail, 3 skip    G5=PASS G6=FAIL
```

**Axis separation is exact:** `G5` reds on all three G-e mutants and stays green on both G-f mutants;
`G6` the mirror image. Both backreference the scope declaration, so a rename stays green while a gate
widened by an unrelated condition still reds — the property the old `G1b` lacked.

**Two defects in these rows were caught by measurement, not by reading them.** Both would have
produced a permanently-red row indistinguishable from unfinished work:

1. **`(?i:errors)` is required.** The operand is normally a constant (`CARRIES_ERRORS`), so a
   case-sensitive `errors` false-REDDED the correct implementation.
2. **`\\?"errors` is required.** Inside a Java string the key is written `\"errors\"`, so a bare
   `'"errors"'` pattern cannot match — quote, `errors`, **backslash**, quote. Measured at 0 hits.

A third landed in the scratch diagnostic rather than a row: it reported `Be1` as *having* the auth fix,
because `Be1`'s TODO comment contains the literal `(requireAuth || v3Scope)`. The comment-satisfies-the-check
trap appeared in the very first tool written to look for it — which is the argument for
`code_contains_ml` being the default rather than an option. A new helper was added to the script for it.

**New live baseline: `37 pass, 12 fail, 3 skip`** against the real worktrees — 14 Slice 2 rows, being
12 red progress rows plus the `G1c`/`G3d` guards. The 35 Slice 1 rows are unaffected. Script is now
600 lines, `md5 fbfa8ea2f53482bf4e133e3e8d83ca08`, `bash -n` clean.

<!-- ADDENDUM COMPLETE: shadows=6 rows_added=2 false_greens=0 false_reds=0 self_inflicted_bugs_caught=3 -->

---

# ADDENDUM 2 — `mvn clean compile` broke the "correct" shadow

Added 2026-08-20 by the orchestrator. This is the single most important measurement in this file,
because it invalidates a green result recorded above.

## The `correct` implementation does not compile

```
correct2-api $ mvn clean compile
[ERROR] SecurityConfiguration.java:[161,146] cannot find symbol
  symbol:   variable meterRegistry
  location: class net.aim_ai.wms.SecurityConfiguration
BUILD FAILURE
```

`IdempotencyFilter` gained a `MeterRegistry` constructor parameter and the call site in
`SecurityConfiguration:161` passes `meterRegistry` — which is never injected there. The filter is
`new`-ed in `SecurityConfiguration.filterChain` and is **not a Spring bean**, so the registry has to
be threaded through the security config by hand.

**The row layer scored that same tree `49 pass, 0 fail, 3 skip`.** Fourteen adversarially-hardened
rows, 18 shadows of prior measurement, and a full green on code the compiler rejects. This is §7.5
item 5 (*"a missing MeterRegistry bean would be a startup failure that this entire report is blind
to"*) landing in practice, and it is stronger than the wording there: it is not a runtime startup
failure, it does not build at all.

**Conclusion: `mvn clean compile` is a floor item, not a closing formality.** Greps grade what was
written; only the compiler grades what builds. No number of row-discrimination passes substitutes.

## This is empirical proof of architect finding L1

L1 argued the counter belongs in `RestIdempotencyService` rather than the filter, because the filter
is not a bean and threading a registry drags `SecurityConfiguration` into a metrics change. That was
a design opinion. It is now a measurement:

| Shadow | Counter in | `mvn clean compile` |
|---|---|---|
| `correct2` | `IdempotencyFilter` | **BUILD FAILURE** |
| `correct3` | `RestIdempotencyService`, `SecurityConfiguration` **untouched** | **BUILD SUCCESS** |

## Second finding: `G2`/`G2a`/`G2b` graded the wrong file

All three asserted against `IdempotencyFilter`, while the plan's §4 G-d says the counter belongs in
`RestIdempotencyService`. **Implementing the plan as written would have redded all three** — the
"satisfiable only by writing code in the wrong place" defect that the original `G1` had on this same
ticket, reappearing in a row that had already survived one adversarial pass. The lane's `correct`
shadow hid it by putting the counter in the filter, i.e. by implementing the row rather than the plan.

Retargeted to `$V2_RIS`. `G2b` was rewritten for the service's `tryClaim` return paths, and it gained
a third **negative** conjunct forbidding a counting call before `return ClaimResult.CLAIMED` — which
is what catches an increment on the success path (inverting the metric).

## Re-measured on a coherent `correct3` family

```
correct3        Result: 49 pass, 0 fail, 3 skip    + mvn clean compile: BUILD SUCCESS
B4p             Result: 48 pass, 1 fail, 3 skip    red: G2     (registered, never incremented)
B4bp            Result: 48 pass, 1 fail, 3 skip    red: G2b    (increments on CLAIMED)
Be1p            Result: 47 pass, 2 fail, 3 skip    red: G5 G6  (comment-only TODOs)
Be2p            Result: 48 pass, 1 fail, 3 skip    red: G5     (detects, only logs)
Be3p            Result: 48 pass, 1 fail, 3 skip    red: G5     (errors check unscoped)
Bf1p            Result: 48 pass, 1 fail, 3 skip    red: G6     (gate left as requireAuth)
Bf2p            Result: 48 pass, 1 fail, 3 skip    red: G6     (gate widened by || enforce)
```

Scope / key / bridge / client axes re-confirmed on the original shadows — `B1`,`B8` → `G1`+`G1c`;
`B2` → `G1b`+`G1d`; `B15` → `G1c`; `B16` → `G1d`; `B7` → `G4`; `B5` → `G3b`; `B6`,`B17` → `G3c`;
`B10` → `G3d`. Those shadows now also red the counter rows, an expected artifact of the relocation
(their counter still sits in the filter); it is recorded rather than smoothed over.

## Operational note

The shadows' `target/` was a symlink chain resolving to the **real worktree's** `target/`, so
`mvn clean` in a shadow would have deleted the build output of the branch under PR review. Replaced
with a real directory in every compiled shadow before running maven. Anyone reusing `mkshadow.sh`
for a build must do the same — a shadow root is only safe for *reading* until its `target` is broken.

Toolchain, since neither is on PATH and bash's 127 records as an ordinary FAIL:
`JAVA_HOME=~/.sdkman/candidates/java/21.0.11-ms`, maven `~/.sdkman/candidates/maven/current/bin`.

Script now `md5 dba8826855c8cf2ea2859615a03bc110`, `bash -n` clean.

<!-- ADDENDUM 2 COMPLETE: compile_runs=2 build_failures=1 rows_retargeted=3 invalidated_green_results=1 -->
