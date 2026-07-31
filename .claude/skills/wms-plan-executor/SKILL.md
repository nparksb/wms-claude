---
name: wms-plan-executor
description: Execute a reviewed WMS plan end-to-end — ralph-loop the implementation until the TDD-gate tests and verify script pass, confirm plan conformance in a separate verifier lane, run code review and fix every High/Medium finding, audit doc drift, commit, open a PR into develop, update the plan document, and move the ClickUp ticket to "pr submitted". Use when the user says "implement plan X", "execute the plan", "ship SBDEV-####", or hands back a plan this session just authored. Stops at PR — does NOT merge, deploy, or archive the plan.
---

# WMS Plan Executor

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
| 3 | Verify script exists | `sbdocs/9-System/scripts/verify-<plan-id>.sh` | Author it per the plan skill's Verification-script section, then continue |
| 4 | TDD-gate tests exist | grep the plan's named test classes in `v{1\|2}/wms-api/src/test/` | Run `wms-tdd-gate` first — it is the completion contract for Phase 1 |
| 5 | Target repo + branch | see below | Stop if the tree is dirty |
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

### Branch

Take the branch from the plan (§5 Implementation Steps / §5 Phased Implementation Plan / §8 Rollout). Phased plan → the branch for the phase being implemented. Derive `feature/<plan-id>` if the plan names none.

```bash
cd v{1|2}/wms-api
git status --short && git branch --show-current
git fetch origin && git checkout -b feature/SBDEV-####-kebab origin/develop   # if absent
```

- Base is `origin/develop` unless the plan says otherwise.
- **Stacked branch:** if this plan builds on another unmerged branch, base off that branch, set the PR base to it in Phase 6, and state the merge order explicitly. Stacked PRs must merge base-first into `develop`; verify with `git merge-base --is-ancestor` before advancing anything.
- Never implement on `develop` or `main`.

### Toolchain

```bash
export PATH="$HOME/.sdkman/candidates/maven/current/bin:$HOME/.sdkman/candidates/java/current/bin:$PATH"
mvn -v    # confirm; v1/wms-api needs Java 8, v2/wms2-api needs Java 21
```

### Baselines — capture BEFORE the first edit

1. **Verify script:** `bash sbdocs/9-System/scripts/verify-<plan-id>.sh` → record the `Result:` line. Expect failures. **`0 fail` here means the script asserts nothing** — tighten it to call-site regexes before continuing, or the final green proves nothing.
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
| Story acceptance criteria | The TDD-gate test method(s) for that fix, by exact `Class#method` name, **plus** the verify-script rows for that fix |
| Story order | §5 Implementation Steps order (respect stated prereqs) |
| Definition of done | Targeted tests green + `verify-<plan-id>.sh` reports `Result: N pass, 0 fail` |

Task text to hand ralph must state:

> Implement `<plan path>`. The failing tests in `<test classes>` are the contract — make them pass. Do not weaken, skip, `@Disabled`, or delete any test to reach green. Do not change the plan's design; if a fix cannot work as designed, stop and report rather than improvising. Completion requires `bash sbdocs/9-System/scripts/verify-<plan-id>.sh` reporting `Result: N pass, 0 fail`.

**Hard constraints to carry into the loop:**

- Editing a TDD-gate test is allowed **only** to fix genuinely broken scaffolding (a mock that can't compile). Changing an assertion to match the implementation inverts the gate — if an assertion looks wrong, stop and ask.
- `sbdocs/` is not a git repo. Plan edits are filesystem-only; never `git add` them, never `git mv`.
- Never commit `.env`, `auth.json`, `config.php`, `local.php`, `*_dev.properties`, or plaintext values behind Jasypt `ENC(...)`.
- Respect the plan's version constraints — v2 `@Transactional(value = "tenantTransactionManager", rollbackFor = {...})`, jakarta namespace, constructor injection, SLF4J parameterized logging; v1 no `mockStatic()`, entity comparison by ID.

Abort the loop and report if: the plan's design is provably wrong, a fix needs a DB migration against a live tenant that the plan didn't sanction, or ralph stalls on the same story twice with no new information.

---

## Phase 2 — Test and verify

```bash
mvn test -Dtest=<TouchedClass>          # fast feedback, per touched class
mvn test                                 # full unit suite
bash sbdocs/9-System/scripts/verify-<plan-id>.sh
```

**Landmines — each one has produced a false green in this repo:**

| Trap | Consequence | Guard |
|---|---|---|
| `-Dtest='Outer#method'` on a `@Nested` test | Silently runs **zero** tests and reports success | Target the class, and confirm the run count matches the number of tests you expect |
| `mvn test` mutates the tracked ArchUnit store | An unrelated file lands in your commit | `git status` after every suite run; `git checkout --` the store before staging |
| v2 Testcontainers IT harness is broken (SBDEV-2217) | ITs can't boot; absence of failure reads as pass | Gate on unit tests **plus** `mvn clean compile`; leave ITs `@Disabled` with a `TODO(SBDEV-2217)` |
| Spring bean / DI changes | Unit tests and incremental compile both miss wiring drift | `mvn clean compile` + run the context-load test (`OmsNotificationConfigContextLoadTest`) |
| Surefire `-Dtest` overrides the `*IntegrationTest` exclude | An IT runs where you expected units only | Check which classes actually ran in the Surefire output |

Exit criteria for this phase: targeted tests green, full-suite failures identical to the Phase 0 baseline (no new red), and the verify script reporting `Result: N pass, 0 fail`. Anything else → back to Phase 1.

---

## Phase 3 — Independent lanes (never self-approve)

Two passes by someone other than the author, in this order. **3a gates 3b:** reviewing code that only implements half the plan generates findings you have to re-review after filling the gaps.

### 3a. Conformance — did we build what the plan says? (`verifier`)

Delegate to `oh-my-claudecode:verifier` — this is the systematic guard against the failure mode the verify script exists for: an executor once claimed 14 OMS-decoupling sites complete having done 3. The verify script catches that only if its regexes are tight; the verifier catches it by construction.

Pass it, explicitly:

- the plan path, its **§0 Affected Sites table** (every in-scope row), and **§8 Acceptance criteria**
- `git diff origin/develop...HEAD`
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

Run them in parallel; both get: `git diff origin/develop...HEAD`, the plan path, and the instruction to check plan-conformance (does the code do what §3 designed?) alongside correctness.

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

1. Detect the repo's own convention first: `git log --oneline -20` in the target repo. Match it; do not impose Conventional Commits on a repo that doesn't use them.
2. Include the ticket id in the subject.
3. One commit per plan phase / fix when the plan is phased — atomic and revertable. Squash only if the plan says to.
4. Before staging: `git status` and confirm nothing unintended (ArchUnit store, IDE files, `.env`, generated Swagger) is included.
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
Diffstat:      <N files, +X/-Y>
Commits:       <sha> <subject>   (one line each)
Tests:         <N> targeted pass | full suite <N> pass, <M> fail (baseline <M>)
Verify script: Result: N pass, 0 fail
Conformance:   verifier PASS — <N>/<N> §8 criteria VERIFIED, <N>/<N> §0 rows covered
Code review:   <H> high / <M> medium fixed, <L> low deferred
Docs:          <updated | none needed | N flagged>
PR title:      <title>
ClickUp:       SBDEV-#### → "pr submitted"
```

Wait for go. Skip the wait only if the user invoked the skill with `--auto` or already said to run unattended. Push and PR creation are outward-facing and effectively irreversible in a shared repo — one gate, not three.

On approval:

```bash
git push -u origin feature/SBDEV-####-kebab
gh pr create --base develop --head feature/SBDEV-####-kebab \
  --title "<SBDEV-####> <what changed>" --body-file <body>
```

PR body must carry: what changed and why (2–4 sentences), plan path, ClickUp link, per-fix summary mapped to §3, test results, the verify-script `Result:` line, the **conformance table** (each §8 criterion → VERIFIED, plus anything deliberately deferred with its rationale), code-review outcome (fixed / deferred), doc updates, the plan's §8 **manual test plan** for the reviewer to execute, and any deploy prerequisite (Flyway version, sysprop row, deploy order). For a stacked PR, state the required merge order in the first line. Footer:

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

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
- **Deploying / tagging** — GitLab CI tag-driven (`dev-*`, `qa-*`, `ua-*`, `v*`); GitHub Actions for `oms-laravel-api` / `omsv2-UI`.
- **Applying Flyway migrations to any tenant DB** — the app does not run Flyway at runtime. A merged migration is applied to **no** database until an operator runs it; use the `wms2-apply-pending-tenant-flyway` runbook. If this plan added a migration, say outright that every tenant is still unpatched.

---

## Multi-repo plans

API + UI changes live in separate git repos, so they get separate branches, commits, and PRs. Note the required merge order in both PR bodies (API first when the UI consumes a new contract). One ClickUp ticket covers both — comment both PR URLs on it.

v1 + v2 paired plans: implement one version per run. Do not straddle both repos in a single execution.

## Stop and ask, don't improvise

- Plan design turns out wrong → report, don't redesign.
- Tests can only pass by weakening them → report; that is a plan defect.
- Change needs data migration or a sysprop row the plan didn't sanction → stop.
- Working tree has someone else's uncommitted work → stop; never stash it.
- Full suite has new failures you cannot attribute → stop before opening a PR.
