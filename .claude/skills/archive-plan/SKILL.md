---
name: archive-plan
description: Move a completed plan file from 1-Projects/wms{1,2}/plan/ to 4-Archieves/wms{1,2}/plan/, flip frontmatter status to archived, and update both folder READMEs (remove from active list, bump archive count). Use when the user says "archive plan X", "this plan is done, archive it", or provides a plan filename with context that it's complete. Destructive (file moves) — always confirm with the user before the `git mv`.
---

# archive-plan

Cleanly complete a plan's lifecycle: move the file, update the frontmatter, patch both MOCs. Manual archival is error-prone (people skip the frontmatter flip or forget one README); this skill does all four steps in the right order.

## What this skill IS and is NOT

- **IS:** a coordinated archival script — file move + frontmatter update + source README edit + target README edit.
- **IS NOT:** a decider. The user decides a plan is complete. This skill takes that decision and executes the plumbing.

## Inputs

- A plan filename (e.g. `Auto_Release_Club_Transfer_Lane_Fix.md`) — skill locates it under `1-Projects/wms{1,2}/plan/`.
- OR an absolute / relative path to the plan file.
- Optional flag: `--dry-run` → print the 4 planned operations, don't execute.

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

### 3. Plan the four operations

Print this list verbatim so the user can confirm:

```
Archival plan for <filename>:
  1. mv sbdocs/1-Projects/wms{1,2}/plan/<filename>
        sbdocs/4-Archieves/wms{1,2}/plan/<filename>
  2. Edit frontmatter in the moved file:
         status: active → archived
         (preserve all other fields; append today's date to the Verification Log if the plan has one)
  3. Remove the plan's row from sbdocs/1-Projects/wms{1,2}/plan/README.md
  4. Bump the archive count in sbdocs/4-Archieves/README.md (~N → ~N+1 for wms{1,2}/plan/)
```

### 4. Require explicit confirmation

In dry-run mode, stop here. Otherwise, prompt: "Proceed with these 4 operations?" and wait for "yes" / "proceed" / explicit confirmation.

### 5. Execute in order

- **5a.** Move the file with plain `mv` — `sbdocs/` is not a git repository under the OWL umbrella. Never use `git mv`.
- **5b.** Edit the moved file's frontmatter — flip `status` and append a row to the Verification Log table if one exists.
- **5c.** Edit the source (active) README — remove the matching `- [<filename>](<filename>)` line (or its equivalent in the inventory table). Preserve the rest of the README.
- **5d.** Edit `4-Archieves/README.md` — increment the `~N` count by 1 for the matching row. Leave the commentary untouched.
- **5e.** Handle the verify script (added 2026-04-25). For every plan the actionable-plan skills emit (`wms-bugfix-plan`, `wms-feature-plan`), there is a paired acceptance script at `sbdocs/9-System/scripts/verify-<plan-id>.sh` where `<plan-id>` is the plan filename without `.md`.
   - **Default: leave the script in place.** Verify scripts are permanent regression-checks; they prove the structural fix is still applied years later. A future contributor changing the touched code can run the script and confirm the contract isn't regressed.
   - In the moved plan's frontmatter (or in a new "Archive note" sub-section), append a one-line cross-reference: `> Acceptance script retained at sbdocs/9-System/scripts/verify-<plan-id>.sh`.
   - **If the user explicitly asks to archive the script too**, move it to `sbdocs/4-Archieves/scripts/verify-<plan-id>.sh` (create the directory if missing) and update the plan's reference accordingly. Default to retain unless asked.
   - If no script exists for this plan (e.g. legacy archive predating the convention), simply skip 5e — do not auto-generate one.

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

## Exit criteria

Done when the 4 operations are applied, re-audit shows 0 drift, and the user confirms visually (or runs `git status` and sees a clean diff).
