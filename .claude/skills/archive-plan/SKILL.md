---
name: archive-plan
description: Move a completed plan file from 1-Projects/wms{1,2}/plan/ to 4-Archieves/wms{1,2}/plan/, flip frontmatter status to archived, update both folder READMEs (remove from active list, bump archive count), retire the paired verify script, and remove the per-ticket implementation worktree(s) left behind by wms-tdd-gate / wms-plan-executor. Use when the user says "archive plan X", "this plan is done, archive it", or provides a plan filename with context that it's complete. Destructive (file moves + worktree removal) — always confirm with the user first.
---

# archive-plan

Cleanly complete a plan's lifecycle: move the file, update the frontmatter, patch both MOCs. Manual archival is error-prone (people skip the frontmatter flip or forget one README); this skill does all the steps in the right order.

## What this skill IS and is NOT

- **IS:** a coordinated archival script — file move + frontmatter update + source README edit + target README edit + verify-script retirement + implementation-worktree cleanup.
- **IS NOT:** a decider. The user decides a plan is complete. This skill takes that decision and executes the plumbing.

## Inputs

- A plan filename (e.g. `Auto_Release_Club_Transfer_Lane_Fix.md`) — skill locates it under `1-Projects/wms{1,2}/plan/`.
- OR an absolute / relative path to the plan file.
- Optional flags:
  - `--dry-run` → print the planned operations, don't execute.
  - `--keep-script` → leave the paired verify script active in `9-System/scripts/` (see 5e).
  - `--keep-worktree` → leave the implementation worktree(s) in place (see 5f).

If the user says "archive plan X" ambiguously, check both `1-Projects/wms1/plan/` and `1-Projects/wms2/plan/` and confirm which.

## Workflow

Execute in this order. **Do not skip the confirmation step (4).**

### 1. Resolve source

- Determine the source path (active-plans folder).
- Determine version from the path: `1-Projects/wms1/plan/` → `v1`; `1-Projects/wms2/plan/` → `v2`.
- Destination: `4-Archieves/wms{1|2}/plan/<same-filename>`.
- Fail fast if the source doesn't exist or the destination already does.

### 2. Read plan frontmatter

Read the first ~20 lines. Extract:
- `status:` (expected `active` or `draft`)
- `type:` (should be `plan`)
- `version:` (should match resolved version from step 1)

Flag if:
- `status` is already `archived` — probably already done; confirm with user.
- `version` mismatches the folder (v1 plan in wms2 folder or vice versa) — stop and surface.

### 3. Plan the operations

Print this list verbatim so the user can confirm (the script line applies only when step 5e finds a script whose base has no active sibling plan):

```
Archival plan for <filename>:
  1. mv sbdocs/1-Projects/wms{1,2}/plan/<filename>
        sbdocs/4-Archieves/wms{1,2}/plan/<filename>
  2. Edit frontmatter in the moved file:
         status: active → archived
         (preserve all other fields; append today's date to the Verification Log if the plan has one)
  3. Remove the plan's row from sbdocs/1-Projects/wms{1,2}/plan/README.md
  4. Bump the archive count in sbdocs/4-Archieves/README.md (~N → ~N+1 for wms{1,2}/plan/)
  5. (if a paired verify script exists — see 5e) mv sbdocs/9-System/scripts/verify-<plan-id>.sh
        sbdocs/4-Archieves/scripts/verify-<plan-id>.sh, then refresh 4-Archieves/scripts/README.md
  6. (if an implementation worktree exists — see 5f) remove
        .claude/worktrees/<repo-dir-name>/<TICKET>   [one line per repo]
        .claude/worktrees/.verify-root/<TICKET>
        + delete the merged local branch <branch>, then `git worktree prune`
```

### 3b. Findings disposition gate (added 2026-08-21)

**A plan is not archivable while it still contains findings with nowhere to go.** This is the whole
reason archival is dangerous: the moment the plan leaves `1-Projects/`, anything recorded only inside
it stops being read. That is how a real defect can sit undiscovered for months while the ticket that
would have surfaced it was never opened.

Before step 4, scan the plan for unresolved findings — sections named *residual*, *still owed*,
*not fixed*, *recorded not fixed*, *deferred*, *open question*, *landmine*, or any unchecked `- [ ]`
acceptance box — and for each one require **exactly one** of these dispositions, stated in the plan:

| Disposition | What it means |
|---|---|
| **Fixed** | in this plan's PRs; name the commit |
| **On a ticket** | give the ticket id. Per the ticket policy in `wms-triage`, prefer widening a ticket that shares the code path over filing a sibling |
| **Dropped** | with a one-line reason. A deliberate drop is a fine outcome; a silent one is not |
| **Not machine-knowable, owner named** | manual QA, a per-environment check, a decision — name who holds it |

**Do not accept "recorded in the plan" as a disposition.** That is the failure mode this gate exists
to stop. If the finding matters after archival, it needs a ticket or a named owner; if it does not, it
needs an explicit drop.

Print the list and its dispositions as part of step 3's operation summary, so the user approves the
archival and the findings' fate in one decision. If any finding has no disposition, **stop and ask** —
do not archive and do not guess.

### 4. Require explicit confirmation

In dry-run mode, stop here. Otherwise, prompt: "Proceed with these operations?" and wait for "yes" / "proceed" / explicit confirmation.

### 5. Execute in order

- **5a.** Move the file with plain `mv` — `sbdocs/` is not a git repository under the OWL umbrella. Never use `git mv`.
- **5b.** Edit the moved file's frontmatter — flip `status` and append a row to the Verification Log table if one exists.
- **5c.** Edit the source (active) README — remove the matching `- [<filename>](<filename>)` line (or its equivalent in the inventory table). Preserve the rest of the README.
- **5d.** Edit `4-Archieves/README.md` — increment the `~N` count by 1 for the matching row. Leave the commentary untouched.
- **5e.** Handle the verify script (default flipped 2026-07-24). For every plan the actionable-plan skills emit (`wms-bugfix-plan`, `wms-feature-plan`, `wms-v2-migrate`), there is a paired acceptance script at `sbdocs/9-System/scripts/verify-<plan-id>.sh` where `<plan-id>` is the plan filename without `.md` (some plans also have suffixed siblings — `-v2`, `-web`, `-mobile`, `-followup`, `-prekickoff`).
   - **Default: retire the script alongside the plan.** Move it to `sbdocs/4-Archieves/scripts/verify-<plan-id>.sh` (create the dir if missing). Rationale: these harnesses are *pre-merge acceptance gates*, not living CI — durable regression protection belongs in each repo's JUnit suite. Keeping the active pool (`9-System/scripts/`) signal-rich matters more than the rarely-realized "future contributor greps for the script" case (there is no code→script index).
   - **Guardrail — map each script to a version, not just a base (refined 2026-07-25).** v1/v2 plan pairs share a base name and usually have *two* scripts distinguished by suffix (`verify-<base>.sh` / `verify-<base>-v2.sh`, or `-v1`/`-v2`). Each script pins its target repo in its `PROJECT_ROOT` line (`.../v1/wms-api` vs `.../v2/wms2-api`) — `grep -n PROJECT_ROOT` to read it. Retire only the script(s) whose target repo matches the plan being archived; **keep any script pointing at a repo whose sibling plan is still active in `1-Projects/`.** Example: archiving the v2 plan of a pair retires `...-v2.sh` (targets `v2/wms2-api`) but leaves the base/`-v1` script (targets `v1/wms-api`) because the v1 plan is still active. If a script's `PROJECT_ROOT` is ambiguous or a single script covers both repos, fall back to the conservative rule: keep it until every plan sharing the base is archived.
   - After moving, append/refresh the row in `sbdocs/4-Archieves/scripts/README.md` (the script→plan index table) and add a one-line pointer to the moved plan's Archive-note/frontmatter: `> Acceptance script retired to sbdocs/4-Archieves/scripts/verify-<plan-id>.sh`.
   - **Opt-out (`--keep-script`):** if the user wants the script to stay an active regression check, leave it in `9-System/scripts/` and instead add `> Acceptance script retained at sbdocs/9-System/scripts/verify-<plan-id>.sh` to the plan.
   - If no script exists for this plan (e.g. legacy archive predating the convention), simply skip 5e — do not auto-generate one.

- **5f. Clean up the implementation worktree(s) (added 2026-08-03).** `wms-tdd-gate` / `wms-plan-executor` implement in per-ticket worktrees at `.claude/worktrees/<repo-dir-name>/<TICKET>` and deliberately leave them in place after the PR so review feedback can be applied without re-creating them (`wms-plan-executor` Phase 7). Archival is the point where that lease expires — the plan is done, the PR is merged, the tree is dead weight holding a stale branch checkout. Retire them here.

   **Discover, don't assume.** The plan may have no worktree at all (docs-only plans, investigation-derived plans, plans implemented before the worktree convention). Enumerate rather than deriving paths:

   ```bash
   MONO=/home/nampark/dev/wms-claude
   TICKET=SBDEV-####                       # bare ticket id, or the plan-id date-slug for untracked plans
   for REPO in v1/wms-api v1/wms-web-ui v1/wms-mobile-ui v2/wms2-api v2/wms2-web-ui v2/wms2-mobile-ui; do
     [ -d "$MONO/$REPO/.git" ] || [ -f "$MONO/$REPO/.git" ] || continue
     git -C "$MONO/$REPO" worktree list | grep -F "/$TICKET" && echo "  ^ in $REPO"
   done
   ls -d "$MONO/.claude/worktrees/.verify-root/$TICKET" 2>/dev/null
   ```

   **If nothing matches, skip 5f entirely and say so** — "no worktree for this plan" is a normal outcome, not a problem to solve. Never create one, and never remove a worktree whose directory name doesn't match this plan's ticket.

   **Pre-removal gates — all four, per worktree.** Removal deletes a working tree and its branch ref; anything in it that was never pushed is gone for good. Push state is the entire safety net, so prove it before deleting.
   1. **Merged.** Confirm the branch actually landed: `gh pr list --head "$BRANCH" --state all --json number,state,mergedAt` from inside the repo. Prefer this over `git merge-base --is-ancestor "$BRANCH" origin/develop` — that ancestor check reports "not merged" for a **squash-merged** PR even though it landed, which is the normal merge style here. If the PR is still open or was closed unmerged → **stop, do not remove**, and report it: archiving a plan whose PR never merged is itself worth surfacing to the user.
   2. **Nothing uncommitted.** `git -C "$WT" status --porcelain` must be empty. If it isn't, show the user the file list and ask before proceeding — never pass `--force` on your own initiative. (Expect a stray mutated ArchUnit store from a `mvn test` run; still ask.)
   3. **Nothing unpushed.** Compare against `origin/<branch>` **explicitly** — do **not** use `@{u}`:

      ```bash
      B=$(git -C "$WT" rev-parse --abbrev-ref HEAD)
      git -C "$WT" ls-remote --heads origin "$B"        # empty output ⇒ never pushed ⇒ stop
      git -C "$WT" log --oneline "origin/$B..$B"        # must be empty
      ```

      `git worktree add -b <branch> ... origin/develop` sets the new branch's upstream to **`origin/develop`**, not `origin/<branch>` (verified 2026-08-03: `branch.<b>.merge = refs/heads/develop`). So `log @{u}..` lists the branch's own legitimate commits and reads as "unpushed" even for a fully-pushed branch — it fails open in the noisy direction on every worktree. Unpushed commits, or no remote head at all → stop and ask; a worktree with commits that exist nowhere else is the one thing removal can permanently destroy.
   4. **Repo matches the plan's version.** Same guardrail as 5e: v1/v2 plan pairs share a base name and can have sibling worktrees in *different* repos. Retire only the worktree(s) whose repo matches the plan being archived (`v1/...` for a v1 plan, `v2/...` for a v2 plan); **keep any worktree in a repo whose sibling plan is still active in `1-Projects/`.** A multi-repo plan of one version (API + web-ui, e.g. `SBDEV-2731`) has sibling worktrees that all belong to that plan — remove them all together.

   **Execute, once every gate passes:**

   ```bash
   git -C "$MONO/$REPO" worktree remove "$MONO/.claude/worktrees/$(basename "$REPO")/$TICKET"
   git -C "$MONO/$REPO" branch -d "$BRANCH"    # -d, not -D; it refuses if the branch isn't merged
   git -C "$MONO/$REPO" worktree prune
   ```

   - Use `branch -d` and let it refuse. If it refuses on a **squash-merged** branch (git can't see the squash as a merge), that is the one case `-D` is correct — but only after gate 1 proved `mergedAt` is set. Leave the remote branch alone; GitHub's own merge settings own that.
   - Remove the shadow verify root too: `rm -rf "$MONO/.claude/worktrees/.verify-root/$TICKET"`. It contains only symlinks and a mirrored dir skeleton, so it needs no gates — but scope the `rm -rf` to the `$TICKET` subdirectory, never to `.verify-root/` itself.
   - Repeat the whole block per repo for multi-repo plans.
   - Note the cleanup in the archived plan's Archive-note, one line: `> Implementation worktree(s) removed <YYYY-MM-DD>: <repo>/<TICKET>` — so a later reader knows the tree's absence is intentional and not a lost checkout.

   **Opt-out (`--keep-worktree`):** if the user still has review feedback in flight, leave every worktree in place and record `> Implementation worktree retained at .claude/worktrees/<repo>/<TICKET>` in the plan instead.

### 6. Re-audit

Run the equivalent of `/refresh-moc` scoped to the two affected README folders. Verify 0 drift. Report back.

### 7. Do NOT commit

The archival plumbing is atomic at the filesystem level but the user may want to batch multiple archivals into one commit. Leave staging to the user.

## Variants

- **"Archive all completed plans"** (user provides no filename) — refuse. Plans don't have a mechanically-detectable "complete" flag; always archive one at a time.
- **"Undo archival"** — not this skill's job. User can do `git mv` back + re-run frontmatter edit manually.

## Heuristics

- **Naming collision** — if the target path already has a file with the same name (rare but possible for generic names like `CONCURRENCY_FIX_PLAN.md`), stop and prompt: the user probably wants to rename the incoming file before archiving.
- **v2 plan that ports a v1 plan** — check `related:` for a v1 reference. If the v1 plan is still `active`, flag that too: often you want to archive both together.
- **Plan with no frontmatter** — don't auto-generate one. Report that the plan is under-structured and ask the user how to proceed.

## What NOT to do

- Do not move plans silently.
- Do not edit the moved file's body content (only frontmatter + Verification Log).
- Do not update any other MOC (e.g., architecture README) — archival affects only the two plan READMEs.
- Do not `git commit`. Staging stays with the user.
- Do not archive a plan that still has open tasks or `status: draft` without warning.
- Do not `worktree remove --force`, `branch -D`, or `rm -rf` a worktree directory on your own judgment — every one of those discards work git cannot recover. Ask.
- Do not touch the **main** sub-repo checkouts (`v1/wms-api`, `v2/wms2-api`, `v2/wms2-web-ui`, …). They are usually sitting on someone's in-progress branch; 5f removes *worktrees*, never a main checkout's branch or state.
- Do not remove a worktree whose PR is still open — surface it instead.

## Exit criteria

Done when the operations are applied (including any verify-script retirement from 5e and worktree cleanup from 5f), re-audit shows 0 drift, and the user confirms visually (or runs `git status` and sees a clean diff). If 5f ran, `git -C <repo> worktree list` no longer shows the ticket and the main checkout is untouched on its original branch.
