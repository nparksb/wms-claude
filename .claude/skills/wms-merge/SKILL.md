---
name: wms-merge
description: Merge one or more reviewed WMS PRs and carry them to "on dev" — preflight (stacked bases, stale CI, trial-merge conflicts, Flyway collisions), re-grade each PR on the CURRENT develop (full suite on the actual merge), retarget stacked PRs, merge pinned to the graded head, prove the commits/content/CI reached develop and dev runs it, then the bookkeeping (ClickUp on dev + ACs, doc markers, plan status). Use when the user says "merge PR #N", "merge 510 and 513", "merge and deploy", "take SBDEV-#### to dev". Merging is outward-facing — run only on the user's explicit request.
---

# wms-merge

Takes PRs left at "PR submitted" (by `wms-plan-executor`, or an inline T0/T1 fix) to **merged, deployed to
dev, and recorded**. Every step below was done by hand on 2026-10-15 (four PRs, two stacked, three
tickets). Most of the day's real defects surfaced here, after merges that git reported as clean.
There were **five reds**:
- an arch-test key keyed on arity (`/6` → `/7`);
- a bare `never()` added by one PR, in a **different file** from the rail another PR added that forbids it;
- two inventory counts;
- two compile breaks from a signature that one side changed.

Each was caught **only** by the full suite on the actual merge.

**Scope:** from merge to dev only. Not UAT or PRD (devops), not archiving (`archive-plan`), not writing the
fix (`wms-plan-executor`).

**Relation to `wms-triage`:** merging is not a product change, so there's nothing to triage. A **conflict
resolution is** a product change, and the floor applies to it:
- **Item 4:** one independent review.
- **Item 5:** a full suite compared against a known baseline (failures, not totals; rerun the known-flaky
  ITs before investigating).
- **Item 3:** mutation-check any assertion the resolution changes.

Review-fix commits get their own scoped re-review.

## Rules that never bend

1. **Only on the user's explicit request,** naming the PRs. A merge into the repo's development branch **is** a
   dev deploy, and Flyway runs on boot (wms2-api). The development branch is `develop` everywhere except
   `v2/siteboss-frontend`, where it is `main`. Never merge to `release` / `qa` / `prod`, or to `main` in any other
   repo; that is devops.
2. **A PR may merge only on a grade of its current head against the current base.** Once **any** PR
   merges, **every** remaining PR's check graded a stale base, whether or not their files overlap.
   Today's semantic reds were in different files. Re-grade each remaining PR on the new base before merging it.
3. **Merge only through `scripts/merge-one.sh`.** It pins the merge to the graded head
   (`--match-head-commit`), re-reads the base, and refuses if the check graded a different head or the base moved after it.
   "Moved" is judged two ways. If the current base tip is an ancestor of the graded head, the graded tree already
   contains it; a best-effort probe still refuses a recorded force-push of the base after the run started. Otherwise the base's push time
   (GitHub activity API) must predate the run. That API can miss a push entirely: on 2026-10-21 develop's tip
   ccaa4e93 (#549) had no push record and no push run. After merging, it reads the PR's merge commit and
   exits **3** with a WARNING if its first parent is not the graded base tip (the base moved during the merge,
   so re-run the suite on develop) or if it cannot read it. It also exits 3 when `gh pr merge` reported failure but
   the PR reads MERGED: then it is not proven to be this call's merge (someone else may have merged it, even as a
   squash), so check the merge method and parents by hand. Exit 3 means MERGED, not refused.
4. **Never merge red.** Never use `--force` or `--admin`. The PR check is advisory on this plan (no branch
   protection), so the discipline is yours.
5. **Another session's branch:** before pushing to any PR branch, run
   `.claude/scripts/ticket-lease.sh claim <TICKET> "wms-merge"`. Exit 1 means another live session holds it; ask, don't push.
   The lease covers this machine; for cloud sessions also check `ListAgents`. Release with `ticket-lease.sh release <TICKET>`
   once the PR is merged. Never stack on an **unpushed** branch.

## Repo table

| Repo | Base | PR check (`--check`) | What grades a PR | Deploy proof |
|---|---|---|---|---|
| `v2/wms2-api` | develop | `test` | the PR check (`mvn clean verify -Pci`) | `post-merge-verify.sh --wait-deploy` |
| `v2/wms2-mobile-ui` | develop | `layout` only (`--check layout`) | **also** run `yarn test` locally on the merge | none: verify by hand (`:develop` tag race, memory `wms2-ui-develop-tag-race-deploys-older-code`) |
| `v2/wms2-web-ui` | develop | none | `yarn test` locally on the merge → `merge-one.sh --no-pr-check "<evidence>"` | none: by hand (same race) |
| `v2/oms-laravel-api` | develop | none | `php artisan test` locally on the merge (memory `oms-laravel-api-has-no-runnable-test-env`: if it can't run, say so; review is then the only gate) | none: by hand |
| `v2/siteboss-frontend` | **main** | `Build all applications` (`--check 'Build all applications'`) | Cypress component specs locally | none. Pass `--base main` to every script |

UI repos: merge them **one at a time**, and verify each deploy before the next. Back-to-back merges are
what triggers the `:develop` tag race.

## Phase 1: Preflight (read-only)

```bash
.claude/skills/wms-merge/scripts/merge-preflight.sh [--base main] <repo-dir> <PR> [<PR> ...]
```

**What it reports:**
- **Per PR:** state; base (**STACKED** if not the base branch); mergeability.
- **Each check:** the head SHA it graded, and whether the base moved after it.
- **STALE-OVERLAP:** the base changed files this PR touches.
- **The trial merge:** **CONFLICT** plus the files.
- **Flyway:** a `V` version colliding with develop or with another PR, or lower than develop's max (out of order).
- **Exit 3:** the report is incomplete, e.g. a head that couldn't be fetched. Fix that before acting.

**Then fix the order:**
1. A stacked chain goes base first.
2. Otherwise, the least-risky PR first.

Every PR after the first will be **re-graded** (rule 2). Tell the user the order and everything flagged.

## Phase 2: Per PR, in order

**2a. Grade on the current base.** Every PR after the first needs this, and so does any PR flagged
STALE-OVERLAP or CONFLICT. Work in the branch's worktree (`.claude/worktrees/<repo>/<TICKET>`), or
create one. Never use the main checkout.

```bash
git fetch origin && git merge --no-ff origin/develop    # merge, not rebase: the branch is already pushed
```

- **Resolve conflicts by intent, not by side.** Keep both sides' purpose. Example: 3736 added `orderNumber`
  and 3755 switched the same call to the `ALLOW_ANY` overload, so the merged call needs both.
- **Run the FULL suite on the merge** (the repo table's command). Drop `-o` (offline) if the merge brought in a
  new dependency; an offline resolution failure is not a semantic red.
- **Arch or inventory reds:** set the value to what the test **measures**, after reading the signature. Never
  from arithmetic. Since SBDEV-3789 (#520) the `NeverMatcherNullBlindnessArchTest` drift message ends with the
  exact edit (replace / add / delete), and a `:0` entry passes when the scan finds nothing; `ReplenHoldPolicyCallerArchTest`
  no longer reds when a decided caller only gains a parameter. Neither message is permission to paste without the
  signature check.
- **One independent review** of the resolution commit(s) (`code-reviewer`, writing to a file), told not to run
  Maven in the worktree. Fix every finding, and get a scoped re-review of the fix commits.
- **Push.** The push fires `synchronize`, so the PR check re-runs on the new head. That is how you trigger CI;
  don't close and reopen. Closing fires `closed` webhooks into the ClickUp/Slack integrations.

**2b. Stacked PR whose base just merged.** `deleteBranchOnMerge` is off, so GitHub will **not** retarget it:
`gh pr edit <PR> --base develop`. Retargeting fires `edited`, which the workflow ignores, so do 2a and push.
That one push both re-grades and triggers CI. A PR that **conflicts** gets **no** run at all, and a missing
check is not green.

**2c. Merge, pinned:**

```bash
.claude/skills/wms-merge/scripts/merge-one.sh <repo-dir> <PR> <graded-head-sha> [--check <name>] [--base main]
# no PR CI in this repo (see table):
.claude/skills/wms-merge/scripts/merge-one.sh <repo-dir> <PR> <sha> --no-pr-check "yarn test on merge <sha>: <pass>/<fail>" --graded-base <base-sha>
```

Both SHAs must be at least 12 hex characters. With `--no-pr-check`, `--graded-base <sha>` is also required: the
base your local suite merge was built on, which must still be the base's tip. Exit codes: 0 merged · 1 refused · 2 setup/merge error (nothing merged as far as the script can tell; confirm with `gh pr view` before retrying) · **3 merged with a WARNING** (see rule 3 for what each warning asks of you). For how "the base moved" is judged (ancestor path, force-push probe), see rule 3. It refuses if:
- the PR is not OPEN, or is a draft;
- the base is wrong;
- the head moved;
- the PR is not MERGEABLE (GitHub still computing it reads as UNKNOWN: retry);
- with `--no-pr-check`: the base tip no longer equals `--graded-base`;
- the check failed or graded another head;
- the base moved after the graded run, judged as in rule 3: if the base tip is not an ancestor of the graded head,
  its push time must predate the run (no push record at all also refuses); if it is, a recorded force-push of the
  base after the run start refuses.

**2d. Prove it landed:**

```bash
.claude/skills/wms-merge/scripts/post-merge-verify.sh <repo-dir> <PR> --marker '<path>:<a string only this PR adds>' --wait-deploy
```

- **Exit 0 means all of these are proven:** MERGED into the base; merge commit and head both ancestors of it;
  content present (unless you passed `--no-marker`, which prints a WARN; say why in the report); **every** push run on the merge commit completed with success; and, for wms2-api, dev
  serving a build that **contains** the merge.
- **Exit 3:** runs still in progress, or the set of runs was still growing (repos with two push workflows). Re-run
  with `--wait-run`.
- **Exit 1:** a proof failed. If test passed and build failed, read `gh run view <id> --log-failed`. A Maven
  Central or registry 5xx is transient: `gh run rerun <id> --failed`. Anything else, stop and report.
- **Non-wms2-api repos:** `--wait-deploy` FAILs by design. Verify the deploy by hand and record how.

## Phase 3: Bookkeeping (derived, not remembered)

Per ticket, once **all** of its PRs (in every repo) are merged and deployed:

1. **ClickUp:** move to `on dev` **and** tick or strike its ACs **in the same action**. Strike an AC only by naming
   the ticket that now carries it.
   - **If an AC can be neither ticked nor struck, do not move the ticket to `on dev`.** It's a split waiting to
     happen; follow `wms-triage`'s file-don't-widen rule and tell the user.
   - No AC list: add a short status block naming each fix and its merge SHA.
   - Add a comment with the merge SHAs, every conflict resolution, the suite counts on the merge, the develop
     runs and the deployed version.
2. **Doc markers:**
   ```bash
   .claude/skills/wms-merge/scripts/flip-pending-markers.sh <TICKET> "#<PR> <sha>, <date>" --prs "<repo>:<PR> ..."           # dry run
   .claude/skills/wms-merge/scripts/flip-pending-markers.sh <TICKET> "#<PR> <sha>, <date>" --prs "<repo>:<PR> ..." --apply
   ```
   - `--prs` must list **every** PR of the ticket. The script refuses unless all are MERGED.
   - It flips the standard token and its common variants (U+FE0F, NBSP).
   - It **lists** near-misses and legacy free text. Edit those by hand, touching only this ticket's.
3. **Plan, if one exists:**
   - Set frontmatter `status:` to `on dev — #<PR> <sha>`.
   - Append to §Implementation Status: the merge SHAs, each conflict resolution with its commit, the suite counts
     on the merge, and the deploy.
   - Run `sbdocs/9-System/scripts/plan-state.sh <TICKET>` to confirm.
4. **Hand off:** the plan's manual dev-test scenarios come next (`wms-dev-probe`), then `archive-plan`. Neither is
   part of this skill.

## Exit criteria

For every PR:
- `post-merge-verify.sh` exits 0. For a repo without a probe, the deploy is verified by hand and recorded.
- The ticket is `on dev` with its ACs settled, or held back with the reason given.
- No standard `⏳ pending-merge(<TICKET>)` token remains outside `4-Archieves`, and the listed near-misses were
  handled.
- The plan's status reflects the merge.

Report one line per PR: merged as `<sha>`, conflicts resolved (with files), suite counts on the merge, review
verdict, deploy proof.

## NOT for

- **Writing or fixing the change:** `wms-plan-executor`, or the floor in `wms-triage`.
- **UAT or PRD promotion:** devops.
- **Archiving:** `archive-plan`, after the dev test.
- **Repos that deploy outside GitHub PRs:** GitLab tag deploys in the v1 repos.
