---
name: refresh-moc
description: Audit every folder-level README (MOC) in sbdocs/ against the actual filesystem and report drift — doc lists, archive counts, inventory rows. Use when the user says "refresh MOC", "audit READMEs", "check MOC drift", or after landing a batch of new docs. Produces a drift report; does NOT auto-edit the READMEs unless the user asks.
---

# refresh-moc

Audit every folder-level README in `sbdocs/` against the current filesystem. Reports which MOCs are out of sync and what specifically drifted. Does NOT modify files unless the user explicitly asks — the default is report-only.

## What this skill IS and is NOT

- **IS:** a drift auditor for folder-level READMEs. Lists each README's claims, diffs against filesystem, reports.
- **IS NOT:** an auto-rewriter. A MOC is a curated document with commentary; fixing drift still requires a human to decide which new docs deserve first-class rows vs just Dataview-only appearance.

## Inputs

- No arguments: audit ALL READMEs in `sbdocs/`.
- Single path argument: audit one folder's README (e.g. `refresh-moc sbdocs/3-Resources/workflows`).

## Workflow

### 1. Enumerate folder-level READMEs

```
fd -t f -g 'README.md' sbdocs/
```

Expected set today:

- `sbdocs/INDEX.md` (top-level, not named README but functions as one)
- `sbdocs/1-Projects/wms1/plan/README.md`
- `sbdocs/1-Projects/wms2/plan/README.md`
- `sbdocs/2-Areas/wms-v1-v2-sync/README.md`
- `sbdocs/3-Resources/architecture/README.md`
- `sbdocs/3-Resources/data-dictionary/README.md`
- `sbdocs/3-Resources/design/README.md`
- `sbdocs/3-Resources/workflows/README.md`
- `sbdocs/4-Archieves/README.md`

### 2. Per README, compare

For each README:

1. **Parse doc-mention lines** — regex `\[[^\]]+\]\([^)]+\.md\)` inside lists / tables / cells. Collect basenames.
2. **Parse count claims** — regex like `\| ~?\d+ \|` or `(\d+ docs?)` in inline prose.
3. **Enumerate filesystem** of the README's folder (or sub-folders for `4-Archieves/README.md`):
   ```
   ls <folder>/*.md | grep -v README
   ```
4. **Diff:**
   - Docs listed but missing from filesystem → report as "phantom link"
   - Docs in filesystem but not in README → report as "new doc, add row"
   - Count claims differ from filesystem count (within ±1 tolerance for "~N" values) → report as "count drift"

### 3. Check INDEX.md separately

`sbdocs/INDEX.md` is a vault-wide MOC. Verify its "Reference material" section (§1) lists:
- All top-level `3-Resources/*` subfolders
- Counts per subfolder that align with the subfolder README's claim

### 4. Produce report

Markdown format, structured:

```
# MOC Drift Audit — <YYYY-MM-DD>

## Summary
- READMEs audited: N
- READMEs in sync: M
- READMEs with drift: K

## Drift details

### <folder-path>/README.md
- STATUS: drifted
- Docs listed: 14 | Docs in folder: 14 — in sync
- Count claim "~62" | actual 64 — update count

### <folder-path>/README.md
- STATUS: drifted
- MISSING from README (add these):
  - wms2-new-workflow.md
- PHANTOM in README (remove these):
  - wms2-deprecated-thing.md

## Recommended edits (if user asks)

Open these READMEs and update:
1. sbdocs/3-Resources/workflows/README.md — add 2 new docs
2. sbdocs/4-Archieves/README.md — bump wms2 count to 64
```

### 5. Do NOT modify unless asked

If the user only said "refresh MOC" → stop here, report only.

If the user explicitly says "fix them" / "apply updates" / "go ahead" → then open each drifted README, apply the minimal edit (add row, fix count). Never restructure the README; never re-order sections. Only update the inventory table / count cell.

## Heuristics

- **Archived plans moved from `1-Projects/` to `4-Archieves/`** — both plan READMEs drift simultaneously. Flag as one coordinated fix.
- **A new workflow doc** — typically touches `sbdocs/3-Resources/workflows/README.md` AND the Dataview queries in `INDEX.md` (no edit needed there; Dataview auto-refreshes).
- **Counts for archives** — use approximate `~N` tolerance (±1 is noise); only flag if drift is ≥2 or crosses a round-number threshold.
- **Data-dictionary + architecture MOCs** tend to add rows one-at-a-time when a new doc lands. Easy to miss.

## What NOT to do

- Do not restructure any README. Conservative edits only.
- Do not add commentary / prose on behalf of a new doc. Link it, let the user describe it later.
- Do not auto-delete "phantom" README rows — a phantom may be a doc that was recently renamed; the human needs to decide whether to re-link or remove.
- Do not rewrite Dataview query blocks — they're self-refreshing.

## Exit criteria

Done when the drift report has been printed (and, if the user asked for a fix, the minimal edits have been applied + re-audit shows 0 drift).
