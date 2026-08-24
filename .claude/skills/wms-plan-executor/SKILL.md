---
name: wms-plan-executor
description: Execute a reviewed WMS plan end-to-end — create a per-ticket git worktree off freshly-fetched origin/develop, ralph-loop the implementation until the TDD-gate tests and verify script pass, confirm plan conformance in a separate verifier lane, run code review and fix every High/Medium finding, audit doc drift, commit, open a PR into develop, update the plan document, and move the ClickUp ticket to "pr submitted". Use when the user says "implement plan X", "execute the plan", "ship SBDEV-####", or hands back a plan this session just authored. Stops at PR — does NOT merge, deploy, or archive the plan. BEFORE this skill: run `wms-triage` for the tier verdict — it decides how much of this skill runs, and often ends the task instead.
---

# WMS Plan Executor

## Tier scaling — how many lanes actually run

Read the tier from the plan (or run the `wms-triage` skill, which owns the router, if the plan predates it). The phases below are the **T3** shape; scale them:

| Phase | T0/T1 | T2 | T3 |
|---|---|---|---|
| Worktree | yes — always. A feature branch in the main checkout is NOT an acceptable substitute (it leaves the shared checkout off its branch); the T0/T1 saving is skipping ralph, not skipping isolation | yes | yes |
| Phase 1 implement | inline, no ralph | inline or ralph | ralph |
| Phase 3a conformance (`verifier`) | no | no | **yes** |
| Phase 3b `code-reviewer` | **yes** | **yes** | **yes** |
| Phase 3b `security-reviewer` | only if it touches authz / SQL construction / secrets | same | same |
| Second review pass after fixes | only if a fix changed an assertion | **yes if a fix changed an assertion** | yes |
| Phase 4 doc drift | one grep | one grep | `verify-docs` |

**Never scaled:** the floor — DB query, failing test first, **mutation-check every new assertion**, one independent review, full suite vs baseline. And never self-approve, at any tier.

⚠ **Instruct every review lane not to run `git checkout --`, `git restore`, or `git stash`.** On SBDEV-3011 a reviewer probing a mutant used `git checkout --` and clobbered uncommitted work in two files. Tell them to copy to `/tmp` and restore from there — and **commit before the review lanes run**, so the tree cannot be lost.

⚠ **A review lane that reports "idle" with no findings is not a passing review.** Recover its report from the transcript before treating silence as approval.


Takes a **reviewed** plan and drives it to an open PR. This is the only skill in the WMS set that writes production code.

## Trigger

```
/wms-plan-executor <plan-file | plan-id | SBDEV-#### | "the plan we just wrote">
```

Resolution order for the argument:

1. Absolute or repo-relative path → use as-is.
2. Bare filename or plan-id (`SBDEV-2777-stock-history-client-id-blind-mis-aggregation`) → glob `sbdocs/1-Projects/wms{1,2}/plan/`, then `sbdocs/4-Archieves/wms{1,2}/plan/`.
3. Bare `SBDEV-####` → glob `sbdocs/1-Projects/wms{1,2}/plan/SBDEV-####-*.md`.
4. No argument, or "the plan you just worked on" → the plan authored earlier in this session. **Re-read it from disk** rather than working from the drafting conversation — the file is the contract.

Ambiguous or multiple matches → list them and ask. Never guess which plan to implement.

---

## Phase 0 — Preflight (ALL gates must pass before any production edit)

| # | Gate | How | On failure |
|---|---|---|---|
| 1 | Plan exists and is **reviewed** | frontmatter `status:` — see the vocabulary below | Stop. Route to `wms-bugfix-plan` / `wms-feature-plan` for ralplan sign-off first |
| 2 | §10 Open Questions all resolved | read §10 | Stop and ask. Implementing an open contract wastes the work |
| 3 | Verify script — **only if the plan has one** | `sbdocs/9-System/scripts/verify-<plan-id>.sh` | **No script is the normal, correct state below T3.** Do NOT author one to satisfy this gate; note its absence and continue. Only re-author if the plan's §9 names a script that is missing |
| 4 | Dedicated worktree off fresh `origin/develop` | see below — **do this before gate 5**, it defines where every later path resolves | Stop — never implement in the main checkout |
| 5 | TDD-gate tests exist | grep the plan's named test classes in `$WT/src/test/` | Run `wms-tdd-gate` first — it is the completion contract for Phase 1. If it already ran, its tests are in this same worktree; if they are missing, you are in the wrong tree — recheck `git worktree list` before concluding they were never written |
| 6 | Toolchain on PATH | `mvn -v` | export SDKMAN paths (below) |

### Plan-status vocabulary

`status:` is not normalized across the vault (quoted and unquoted, mixed case, ~16 distinct values in use). Strip quotes, lowercase, then classify:

| Value | Verdict |
|---|---|
| `reviewed`, `approved`, `ready`, `verified` | **Proceed.** |
| `in-progress`, `active`, `implemented-pending-review` | **Proceed, but resume rather than restart** — read §10/§11 Implementation Status first and diff the plan against the branch to find what already landed. Re-running Phase 1 blindly can duplicate edits. |
| `changes-requested` | **Stop.** Address the requested changes in the plan first. |
| `draft`, `planning` | **Stop** — the most common value in the vault, and usually accurate. Route back for ralplan sign-off. |
| `implemented`, `archived` | **Stop and ask.** Already shipped; the user probably means a follow-up phase or a different plan. |
| Anything else, or `status:` absent | **Ask.** Do not infer readiness from the plan looking thorough. |

A plan authored in this session by `wms-bugfix-plan` / `wms-feature-plan` has already cleared ralplan Critic sign-off — proceed regardless of the literal string, but say which plan and status you are acting on.

### Worktree — every execution gets its own, no exceptions

Implementation **never** happens in the main checkout (`v1/wms-api`, `v2/wms2-api`, `v2/wms2-web-ui`, …). Each run creates a dedicated `git worktree` off freshly-fetched `origin/develop`, named by the ticket. The main checkout stays on whatever branch the user left it on, clean and usable, while this skill runs.

**Layout** — one worktree per repo per ticket, under the monorepo root:

```
/home/nampark/dev/wms-claude/.claude/worktrees/<repo-dir-name>/<TICKET>
```

`<repo-dir-name>` is the sub-repo's directory name (`wms2-api`, `wms-api`, `wms2-web-ui`, …) so a multi-repo plan gets sibling worktrees. `<TICKET>` is the bare ticket id (`SBDEV-2778`); for an untracked plan with no ticket, use the plan-id's date-slug (`260424-runclubline-transaction-boundary-hardening`). `.claude/worktrees/` is already in the umbrella `.gitignore` — do not add it to `.claudecodeignore`, that would hide the very files being edited.

**Branch name** stays independent of the directory name: take it from the plan (§5 Implementation Steps / §5 Phased Implementation Plan / §8 Rollout). Phased plan → the branch for the phase being implemented. If the plan names none, derive one matching what the target repo actually uses — observed prefixes are `feature/`, `bugfix/`, `fix/`, and `task/`; pick by change type and fall back to `feature/<plan-id>`.

**Create it:**

```bash
MONO=/home/nampark/dev/wms-claude
REPO=v2/wms2-api                                     # the target sub-repo, relative to $MONO
TICKET=SBDEV-####
BRANCH=bugfix/SBDEV-####-kebab                       # from the plan
WT="$MONO/.claude/worktrees/$(basename "$REPO")/$TICKET"

git -C "$MONO/$REPO" fetch origin                    # MUST be fresh — the base is origin/develop as of now
git -C "$MONO/$REPO" worktree list                   # reuse an existing worktree for this ticket, don't duplicate
git -C "$MONO/$REPO" worktree add -b "$BRANCH" "$WT" origin/develop
cd "$WT" && git status --short && git branch --show-current && git log --oneline -1
```

- Base is `origin/develop` **after a fetch** — a stale local `develop` is the whole reason this gate exists. Confirm with `git merge-base --is-ancestor origin/develop HEAD`.
- **Reuse, don't recreate.** `wms-tdd-gate` creates this same worktree when it runs first on the chained path; if `worktree list` already shows `<repo>/<TICKET>`, work in it. Its uncommitted TDD-gate tests are expected, not a dirty-tree failure. Any *other* uncommitted content in it → stop and ask.
- If the branch already exists (remote or local), attach instead of creating: `git worktree add "$WT" "$BRANCH"`, then verify it is up to date with `origin/develop` and say whether it already carries commits.
- **Stacked branch:** if this plan builds on another unmerged branch, base the worktree off that branch instead (`git worktree add -b "$BRANCH" "$WT" origin/<base-branch>`), set the PR base to it in Phase 6, and state the merge order explicitly. Stacked PRs must merge base-first into `develop`; verify with `git merge-base --is-ancestor` before advancing anything.
- Never implement on `develop` or `main`, and never `git checkout` inside the main checkout to do this work.

**Everything after this point runs inside `$WT`.** Concretely:

| Path | Where it resolves |
|---|---|
| Java/Vue source, tests, `pom.xml`, Flyway migrations | `$WT/...` — **never** `v2/wms2-api/...` |
| `mvn` / `yarn` invocations | `cd "$WT"` first; `mvn -f "$WT/pom.xml"` if you must stay put |
| `git diff origin/develop...HEAD`, commit, push | `git -C "$WT" ...` |
| Plan doc, verify script, `sbdocs/` anything | monorepo root — **unchanged**, `sbdocs/` is not part of any sub-repo worktree |

State the absolute worktree path in your first Phase 0 message and use it in every subsequent path. The failure mode this guards against is grep/Explore returning a hit in the main checkout and the edit landing on the stale develop copy — a diff that then shows nothing.

**Fresh-worktree gaps to expect** (a worktree copies tracked files only):

- Git-ignored local config does **not** come along — notably `v2/wms2-api/src/main/resources/db/v1-to-v2-onboarding/onboarding-tz-variants/scripts/migration.env*` and any `.env`. Copy what the plan actually needs; never commit them.
- `node_modules/` is absent in UI worktrees → `yarn install` (or the nvm-node `npm install`) before running Jest.
- `target/` is absent → the first `mvn test` is a cold build. Budget for it; `~/.m2` is shared so nothing re-downloads.
- The tracked ArchUnit store is a **fresh copy** here, so `mvn test` mutating it (see Phase 2) dirties the worktree, not the main checkout — still revert it before staging.

### Toolchain

```bash
export PATH="$HOME/.sdkman/candidates/maven/current/bin:$HOME/.sdkman/candidates/java/current/bin:$PATH"
mvn -v    # confirm; v1/wms-api needs Java 8, v2/wms2-api needs Java 21
```

### Baselines — capture BEFORE the first edit

Run these **in the worktree** (`cd "$WT"`).

**Verify scripts need a shadow root — this is not optional.** Every script defaults `PROJECT_ROOT=/home/nampark/dev/wms-claude` and asserts against paths like `v2/wms2-api/src/...`, so run as-is it grades the **main checkout** and is blind to everything you just wrote. Build a symlink tree that mirrors the monorepo but points the worktree'd repo at `$WT`, and pass it as `PROJECT_ROOT`:

```bash
MONO=/home/nampark/dev/wms-claude
VROOT="$MONO/.claude/worktrees/.verify-root/$TICKET"
rm -rf "$VROOT"; mkdir -p "$VROOT/v1" "$VROOT/v2"
for p in "$MONO"/v1/*/ "$MONO"/v2/*/; do
  ln -sfn "${p%/}" "$VROOT/$(basename "$(dirname "${p%/}")")/$(basename "${p%/}")"
done
ln -sfn "$MONO/sbdocs" "$VROOT/sbdocs"
ln -sfn "$WT" "$VROOT/$REPO"        # override each repo that has a worktree; repeat for multi-repo plans

PROJECT_ROOT="$VROOT" bash "$MONO/sbdocs/9-System/scripts/verify-<plan-id>.sh"
```

Prove the wiring before you trust a single run: append a marker matching one currently-failing assertion to a file **in the worktree**, then run both roots — the shadow root's pass count must move and the plain monorepo root's must not. (Verified 2026-08-01 on `verify-SBDEV-2731`: mono `8 pass, 33 fail` unchanged, shadow `9 pass, 32 fail`.) Remove the marker afterwards. Always state which root each reported `Result:` line came from; a `Result:` from the wrong root is worse than no result.

1. **Verify script:** → record the `Result:` line. Expect failures. **`0 fail` here means the script asserts nothing** — tighten it to call-site regexes before continuing, or the final green proves nothing.
2. **Targeted tests:** run the TDD-gate test classes → record which fail and why.
3. **Pre-existing suite failures:** `mvn test` on the untouched branch, or trust the known baseline (2 of ~4442 fail on clean v2 `develop` as of 2026-07-28 — `OptionalSafetyArchTest` ArchUnit drift and `MobilePalletizingServiceTest`). Without this you will later blame your own change for someone else's red test.

### ClickUp — mark work started

**Ensure** status `in development` via `mcp__clickup__clickup_update_task`, and comment the branch name. The plan skills already set this when the plan was authored, so on the normal path this is a no-op confirmation — read the current status first and only write if it differs.

- Already at `in development` → nothing to do; comment the branch.
- Still at `Open` / `pending` / `ready for sprint` (plan authored in an older session, or ticket filed by hand) → move it forward.
- Already at `comitted local` / `pr submitted` / `on dev` or beyond → **stop and ask.** Someone has already shipped against this ticket; you are about to duplicate or clobber their work.
- No ticket (`ticket: ""`) → say so and continue.

---

## Phase 1 — Implement via ralph

Invoke `Skill("oh-my-claudecode:ralph", "<task>")`. Ralph is PRD-driven and its scaffold criteria are generic, so **build the PRD from the plan** — this mapping is the whole point:

| ralph PRD field | Source in the plan |
|---|---|
| One story per item | §3 Fix Design sub-sections (Fix A, Fix B…) or §5 phases — never one mega-story |
| Story acceptance criteria | The TDD-gate test method(s) for that fix, by exact `Class#method` name — plus the verify-script rows for that fix **if the plan has a script** (T3 opt-in only; most plans have none) |
| Story order | §5 Implementation Steps order (respect stated prereqs) |
| Definition of done | Targeted tests green, and full suite matching the Phase 0 baseline. Add `verify-<plan-id>.sh` reporting `Result: N pass, 0 fail` **only if the plan ships a script** |

Task text to hand ralph must state:

> Implement `<plan path>`. **All source edits and all `mvn`/`yarn` runs happen in the worktree `<absolute $WT>` — never in `<main checkout path>`, which is a stale copy on another branch.** The failing tests in `<test classes>` are the contract — make them pass. Do not weaken, skip, `@Disabled`, or delete any test to reach green. Do not change the plan's design; if a fix cannot work as designed, stop and report rather than improvising. Completion requires `bash sbdocs/9-System/scripts/verify-<plan-id>.sh` reporting `Result: N pass, 0 fail`.

**Hard constraints to carry into the loop:**

- Editing a TDD-gate test is allowed **only** to fix genuinely broken scaffolding (a mock that can't compile). Changing an assertion to match the implementation inverts the gate — if an assertion looks wrong, stop and ask.
- `sbdocs/` is not a git repo. Plan edits are filesystem-only; never `git add` them, never `git mv`.
- Never commit `.env`, `auth.json`, `config.php`, `local.php`, `*_dev.properties`, or plaintext values behind Jasypt `ENC(...)`.
- Respect the plan's version constraints — v2 `@Transactional(value = "tenantTransactionManager", rollbackFor = {...})`, jakarta namespace, constructor injection, SLF4J parameterized logging; v1 no `mockStatic()`, entity comparison by ID.

Abort the loop and report if: the plan's design is provably wrong, a fix needs a DB migration against a live tenant that the plan didn't sanction, or ralph stalls on the same story twice with no new information.

---

## Phase 2 — Test and verify

```bash
cd "$WT"                                 # everything below runs in the worktree
mvn test -Dtest=<TouchedClass>          # fast feedback, per touched class
mvn test                                 # full unit suite
bash /home/nampark/dev/wms-claude/sbdocs/9-System/scripts/verify-<plan-id>.sh
```

**Landmines — each one has produced a false green in this repo:**

| Trap | Consequence | Guard |
|---|---|---|
| `-Dtest='Outer#method'` on a `@Nested` test | Silently runs **zero** tests and reports success | Target the class, and confirm the run count matches the number of tests you expect |
| `mvn test` mutates the tracked ArchUnit store | An unrelated file lands in your commit | `git status` after every suite run; `git checkout --` the store before staging |
| v2 Testcontainers IT harness is broken (SBDEV-2217) | ITs can't boot; absence of failure reads as pass | Gate on unit tests **plus** `mvn clean compile`; leave ITs `@Disabled` with a `TODO(SBDEV-2217)` |
| Spring bean / DI changes | Unit tests and incremental compile both miss wiring drift | `mvn clean compile` + run the context-load test (`OmsNotificationConfigContextLoadTest`) |
| Surefire `-Dtest` overrides the `*IntegrationTest` exclude | An IT runs where you expected units only | Check which classes actually ran in the Surefire output |

Exit criteria for this phase: targeted tests green, full-suite failures identical to the Phase 0 baseline (no new red), and — **if the plan has a verify script at all** (T2 and below no longer produce one) — that script reporting `Result: N pass, 0 fail`, graded against the WORKTREE and never a main checkout. Anything else → back to Phase 1.

---

## Phase 3 — Independent lanes (never self-approve)

Two passes by someone other than the author, in this order. **3a gates 3b:** reviewing code that only implements half the plan generates findings you have to re-review after filling the gaps.

### 3a. Conformance — did we build what the plan says? (`verifier`)

Delegate to `oh-my-claudecode:verifier` — this is the systematic guard against the failure mode the verify script exists for: an executor once claimed 14 OMS-decoupling sites complete having done 3. The verify script catches that only if its regexes are tight; the verifier catches it by construction.

Pass it, explicitly:

- the plan path, its **§0 Affected Sites table** (every in-scope row), and **§8 Acceptance criteria**
- the absolute worktree path, with the explicit warning that `<main checkout path>` holds a stale copy of the same files and must not be read as evidence
- `git -C "$WT" diff origin/develop...HEAD`
- the fresh test output and the `verify-<plan-id>.sh` `Result:` line from Phase 2
- the instruction to **re-run the commands itself** rather than trusting those pasted results

Require its native output shape — per criterion `VERIFIED` / `PARTIAL` / `MISSING` with evidence, plus an overall `PASS` / `FAIL` / `INCOMPLETE`:

| Verdict | Action |
|---|---|
| `PASS`, every §0 in-scope row and §8 criterion `VERIFIED` | Proceed to 3b |
| Any `MISSING` | Back to **Phase 1** — a plan row was never implemented. This is the expensive gap; find it here, not in review |
| Any `PARTIAL` | Close the gap, or downgrade it to a deliberate deferral recorded in the plan's §10 and the PR body. Never leave a `PARTIAL` silent |
| `FAIL` / `INCOMPLETE` on evidence grounds (no fresh output, build unproven) | Produce the evidence and re-run 3a |

Notes:
- The verifier has **no Write/Edit** — it reports, the executor fixes. Do not ask it to patch.
- It defaults to sonnet. Override to `opus` for a large plan (≥8 in-scope rows) or one touching auth / SQL / tenant routing.
- For these Java repos the "build succeeds with fresh output" criterion means `mvn clean compile` — not an incremental compile, which misses DI and signature drift.
- A criterion the plan marked `N/A` or deferred is not a gap; give the verifier the plan's own rationale so it doesn't report a false `MISSING`.

### 3b. Code review — is the code any good?

The implementing context cannot approve its own work. Delegate with the diff, the plan, and the plan's §0 table:

- `oh-my-claudecode:code-reviewer` — always.
- `oh-my-claudecode:security-reviewer` — additionally when the diff touches auth, Keycloak, SQL construction, file upload, or anything reading a secret.

Run them in parallel; both get: `git -C "$WT" diff origin/develop...HEAD`, the worktree path (plus the same stale-main-checkout warning), the plan path, and the instruction to check plan-conformance (does the code do what §3 designed?) alongside correctness.

**Fix policy:**

| Severity | Action |
|---|---|
| High | Fix. Non-negotiable. |
| Medium | Fix. Non-negotiable. |
| Low / nit | Record in the final report and the PR body. Fix only if it is a one-liner in code you already touched. |
| Finding that disputes the plan's **design** | Do NOT redesign silently. Stop, present the finding and the plan's rationale, and let the user decide. |

After fixes: re-run Phase 2 in full, then a **second review pass scoped to the fixes only**. Loop until a pass yields no new High/Medium. If the same finding survives two fix attempts, stop and escalate — repeated failure means the plan or the finding is wrong, not the code.

**Re-run 3a as well** when a review fix changed behavior covered by a §8 criterion — scoped to the affected criteria, not the whole plan. A fix that satisfies the reviewer while breaking conformance is the one thing this two-lane structure exists to catch, and only the verifier lane will see it.

---

## Phase 4 — Documentation drift

```
Skill("verify-docs", "<changed file list, or origin/develop..HEAD>")
```

`verify-docs` is report-only, so act on its output:

- **Doc the diff actually invalidated** (a documented signature, flow, sysprop default, or state transition that this change altered) → update it now. Shipping a change that silently falsifies an architecture doc is part of the change, not follow-up work. Bump `last_verified` / `verified_by`.
- **Doc merely stale by date** with content the diff didn't touch → list it in the final report. Don't bulk-touch dates you didn't actually verify.
- New landmine or non-obvious behavior worth durable capture → note it for the user rather than inventing a doc.

---

## Phase 5 — Commit

All git commands here run against the worktree — `git -C "$WT" ...`, or `cd "$WT"` once and stay there.

1. Detect the repo's own convention first: `git -C "$WT" log --oneline -20`. Match it; do not impose Conventional Commits on a repo that doesn't use them.
2. Include the ticket id in the subject.
3. One commit per plan phase / fix when the plan is phased — atomic and revertable. Squash only if the plan says to.
4. Before staging: `git -C "$WT" status` and confirm nothing unintended (ArchUnit store, IDE files, `.env`, a copied `migration.env`, generated Swagger, a stray `node_modules`) is included.
5. End the commit message with:
   ```
   Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
   ```

---

## Phase 6 — Checkpoint, then push + PR

**One human checkpoint for the whole outward-facing batch.** Print before doing anything remote:

```
## Ready to push — <plan-id>
Repo/branch:   <repo>@<branch>  →  PR base: develop
Worktree:      <absolute $WT>  (base: origin/develop @ <sha>, fetched <when>)
Diffstat:      <N files, +X/-Y>
Commits:       <sha> <subject>   (one line each)
Tests:         <N> targeted pass | full suite <N> pass, <M> fail (baseline <M>)
Verify script: Result: N pass, 0 fail
Conformance:   verifier PASS — <N>/<N> §8 criteria VERIFIED, <N>/<N> §0 rows covered
Code review:   <H> high / <M> medium fixed, <L> low deferred
Docs:          <updated | none needed | N flagged>
PR title:      <title>
Inline notes:  <N> review comments to post on the PR (Phase 6a) — deferred Lows, non-obvious
               design decisions, load-bearing ordering. 0 is a valid answer.
ClickUp:       SBDEV-#### → "pr submitted"
```

Wait for go. Skip the wait only if the user invoked the skill with `--auto` or already said to run unattended. Push and PR creation are outward-facing and effectively irreversible in a shared repo — one gate, not three.

On approval:

```bash
cd "$WT"
git push -u origin "$BRANCH"
gh pr create --base develop --head "$BRANCH" \
  --title "<SBDEV-####> <what changed>" --body-file <body>
```

`gh` resolves the repo from the worktree's remote, so run it inside `$WT` — from the monorepo root it would target `nparksb/wms-claude`.

PR body must carry: what changed and why (2–4 sentences), plan path, ClickUp link, per-fix summary mapped to §3, test results, the verify-script `Result:` line, the **conformance table** (each §8 criterion → VERIFIED, plus anything deliberately deferred with its rationale), code-review outcome (fixed / deferred), doc updates, the plan's §8 **manual test plan** for the reviewer to execute, and any deploy prerequisite (Flyway version, sysprop row, deploy order). For a stacked PR, state the required merge order in the first line. Footer:

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

### 6a. Publish the surviving review reasoning ONTO the PR — inline, not in the body

**The reason this step exists.** Phase 3's lanes generate their findings into files under the session
scratchpad. Those files are invisible to whoever merges: the analysis behind a decision — why
`ON CONFLICT` is wrong on three different tenant shapes, why a fail-open branch was not inherited from
the sibling app, which finding was deliberately deferred and on whose authority — is either
re-derived by the human reviewer or, more likely, not. Reviewing before the PR is the right call (it
keeps fixes in the same commit and hands the reviewer a clean diff), but it forfeits the one thing
post-PR review is genuinely better at: **durable, line-anchored reasoning the team can see.** This
step buys that back for one extra command.

A wall of prose at the top of the PR body does not substitute. It is the least-read part of a PR, and
it cannot point at a line.

**What to post, as inline comments anchored to the lines they concern:**

| Post | Why inline |
|---|---|
| Every **deferred Low / nit** from Phase 3b | Otherwise it is invisible and gets re-found by the next reader, or silently never fixed |
| Each **non-obvious design decision** where the obvious alternative is wrong | The `ON CONFLICT` / `NOT EXISTS` class: a future "simplification" reintroduces the bug unless the reasoning sits on the line |
| Each **deliberate deviation** from the plan, with the plan's own rationale | A reviewer who spots a deviation with no note assumes a mistake and asks — costing a round trip |
| Any assertion that is **green today as a regression pin, not a gate** | Reads as redundant coverage otherwise, and gets deleted in a later cleanup |
| **Load-bearing ordering** (memo assigned before `.then(clear)`, migration step 1 before step 2) | These look arbitrary and are the first thing a tidy-up breaks |
| Anything a lane **measured** rather than reasoned about | Cite the measurement; it is the difference between an opinion and a finding |

**What NOT to post:** anything already fixed (the diff is the record), restatements of what the code
plainly does, or a High/Medium finding — those had to be fixed, not annotated. Do not narrate.

```bash
cd "$WT"
# Prefer the repo's own review tooling where it exists — it anchors comments to the diff:
#   Skill("code-review", "<pr-number> --comment")
# Otherwise post directly, one comment per line that needs it:
gh pr review <pr-number> --comment --body "<summary of what the inline notes cover>"
gh api repos/{owner}/{repo}/pulls/<pr-number>/comments   -f body="<the reasoning>" -f commit_id="<sha>" -f path="<file>" -F line=<n> -f side=RIGHT
```

⚠️ **Cap it.** Ten inline comments a reviewer reads beats forty they skim. If a lane produced more
than that, the excess belongs in the plan document (Phase 7), not on the PR — the plan is the durable
home for analysis, the PR is for what changes this reviewer's decision.

⚠️ **Comments on a PR are outward-facing.** They land under the user's name and notify reviewers, so
they are covered by the same Phase 6 checkpoint as the push — do not post them before the user has
said go. State how many you intend to post in the checkpoint block.

---

## Phase 7 — Update the plan document

Never declare done with the plan doc still saying `draft` — this has been a repeat miss.

- frontmatter: `status:` → `implemented`, bump `updated:`.
- §10/§11 Implementation Status: **real** commit SHAs (never placeholders), test classes + method names added, `mvn test` / `mvn verify` counts, the final `Result: N pass, 0 fail` line, PR URL, and any deliberately-skipped coverage with a one-sentence rationale.
- Record any landmine found during implementation that the plan didn't predict.

---

## Phase 8 — Update ClickUp

1. Status → **`pr submitted`** (`mcp__clickup__clickup_update_task`). The ladder on Fulfillment Development Backlog is `in development` → `comitted local` → `pr submitted` → `on dev` → `on qa` → `ready for deployment` → `on prod` → `Closed`. Use `comitted local` only if you committed but deliberately did not open a PR.
2. **`on dev` is not this skill's to set** — it belongs to whoever merges the PR.
3. Comment (`mcp__clickup__clickup_create_comment`) with: PR URL, commit SHAs, test + verify results, the verifier's conformance verdict (`N/N` criteria VERIFIED, plus any deferral), High/Medium findings fixed, docs touched, deploy prerequisites, and what a reviewer should exercise manually. Link the plan path so the evidence trail is one hop away.

---

## Final report — and what is explicitly NOT done

State plainly: PR URL, commits, test numbers, verify line, review outcome, docs, ClickUp status, and every deferred item.

Not done by this skill, by design — say so every time:

- **Merging the PR** — human review gate.
- **Setting ClickUp to `on dev`** — follows the merge.
- **Archiving the plan** — run `archive-plan` after the merge lands.
- **Removing the worktree** — it stays at `<absolute $WT>` so review feedback can be applied without re-creating it. **`archive-plan` step 5f owns the cleanup**, gated on the PR being merged, so it happens when the plan is archived — not here. Still print the path in the final report, along with the manual command if the user wants it gone sooner: `git -C <repo> worktree remove <$WT>` (add `--force` only if you accept losing uncommitted files there), then `git -C <repo> worktree prune`.
- **Deploying / tagging** — GitLab CI tag-driven (`dev-*`, `qa-*`, `ua-*`, `v*`); GitHub Actions for `oms-laravel-api` / `omsv2-UI`.
- **Applying Flyway migrations to any tenant DB** — the app does not run Flyway at runtime. A merged migration is applied to **no** database until an operator runs it; use the `wms2-apply-pending-tenant-flyway` runbook. If this plan added a migration, say outright that every tenant is still unpatched.

---

## Multi-repo plans

API + UI changes live in separate git repos, so they get separate worktrees, branches, commits, and PRs — `.claude/worktrees/wms2-api/SBDEV-####` and `.claude/worktrees/wms2-web-ui/SBDEV-####` as siblings, each off its own repo's `origin/develop`. Note the required merge order in both PR bodies (API first when the UI consumes a new contract). One ClickUp ticket covers both — comment both PR URLs on it.

v1 + v2 paired plans: implement one version per run. Do not straddle both repos in a single execution.

## Stop and ask, don't improvise

- Plan design turns out wrong → report, don't redesign.
- Tests can only pass by weakening them → report; that is a plan defect.
- Change needs data migration or a sysprop row the plan didn't sanction → stop.
- Main checkout has someone else's uncommitted work → leave it alone entirely; the worktree makes this a non-event, so never stash, never `git checkout` there. If an *existing* worktree for this ticket holds uncommitted work that isn't the TDD-gate tests → stop and ask.
- The plan's branch already exists on `origin` with commits you didn't make → stop; someone else is mid-flight on this ticket.
- Full suite has new failures you cannot attribute → stop before opening a PR.
