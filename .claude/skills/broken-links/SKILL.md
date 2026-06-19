---
name: broken-links
description: Scan every markdown doc in sbdocs/ for broken cross-references — unresolvable entries in `related:` frontmatter, broken inline `[text](relative-path)` links, and missing target files. Use when the user says "check broken links", "find broken cross-references", "audit link integrity", or after renaming / moving docs. Report-only; does NOT auto-fix.
---

# broken-links

Audit every doc in `sbdocs/` for dead cross-references. Runs two passes: one against `related:` frontmatter entries, one against inline markdown `[...](path)` links. Produces a grouped report of broken targets with source line numbers.

## What this skill IS and is NOT

- **IS:** a cross-reference integrity checker for markdown docs.
- **IS NOT:** an auto-fixer. A broken link may mean the target was renamed (fix the link) or intentionally removed (fix the link or remove it); this skill doesn't guess which.

## Inputs

- No arguments: scan all of `sbdocs/`.
- Path argument: scan only a subtree (e.g. `broken-links sbdocs/3-Resources/`).
- `--frontmatter-only` or `--inline-only`: limit to one pass.

## Workflow

### 0. Preflight — confirm `fd` is on PATH (MANDATORY, do not skip)

This skill enumerates files with `fd`. On Debian/Ubuntu/Pop!_OS the binary is often
installed under the name **`fdfind`** (the `fd-find` package renames it), so a bare `fd`
can be "command not found" even though `fd` *is* installed. If that happens, every `fd`
invocation returns **no output**, which this skill would otherwise misread as "every
target NOT FOUND" — a false all-broken report (this exact failure has happened).

Run this gate first and **abort with a clear message if it fails** — never proceed with a
missing/empty `fd`:

```bash
if ! command -v fd >/dev/null 2>&1; then
  if command -v fdfind >/dev/null 2>&1; then
    echo "fd missing but fdfind present. Fix once: ln -sf \"$(command -v fdfind)\" \"\$HOME/.local/bin/fd\""
  else
    echo "fd not installed. Either install it, or run this skill with 'find' instead (see fallback below)."
  fi
  # STOP. Do not run the audit until fd resolves, or use the find-based fallback.
fi
```

**`find` fallback** (always available; use it instead of `fd` if the gate fails and you
don't want to install/symlink — `sbdocs/` is not in git, so there is no `.gitignore`
behavior to preserve):

```bash
find sbdocs/ -type f -name '*.md'                       # enumerate (step 1)
find sbdocs/ -type f -name '<missing-basename>.md'      # fuzzy-suggest probe (Heuristics)
```

### 1. Enumerate all markdown files

```
fd -e md . sbdocs/
```

### 2. Pass 1 — Frontmatter `related:` entries

For each file:

1. Parse YAML frontmatter (everything between first `---` and the matching `---`).
2. Extract `related:` list.
3. For each entry (typically a relative path like `../architecture/wms2-transaction-osiv-boundary-map.md`):
   - Resolve relative to the source file's directory.
   - Check if the target exists.
   - If not, record as broken.

### 3. Pass 2 — Inline markdown links

For each file:

1. Regex scan: `\[([^\]]+)\]\(([^)]+)\.md[^)]*\)` (link to a `.md` file; ignores external URLs).
2. Also match fragment links: `\[([^\]]+)\]\(([^)]+\.md)#([^)]+)\)` — record fragment separately.
3. Resolve the path relative to the source file.
4. Check:
   - Target file exists → OK (we don't validate fragments — Obsidian / markdown renderers handle them leniently).
   - Target file doesn't exist → broken.

### 4. Special-case the symptom-index format

`sbdocs/_symptom-index.md` uses a slightly different link pattern: `📕 [<doc-name> §N](path)`. The regex in step 3 still matches because it's a standard markdown link; the "§N" is just the link text. Nothing special needed.

### 5. Report

Group broken entries by **source file** so the operator can open one file at a time:

```
# Broken-Links Audit — <YYYY-MM-DD>

## Summary
- Files scanned: N
- Total links/related entries checked: M
- Broken: K

## By source file

### sbdocs/3-Resources/workflows/wms2-picking-workflow.md
Frontmatter related: 
  - line 13: ../../4-Archieves/wms2/plan/260401-foo-bar.md  ← NOT FOUND

Inline:
  - line 87: [state-machine §5.1](../architecture/wms2-state-machine.md)  ← NOT FOUND (expected wms2-state-machine-catalog.md?)

### sbdocs/_symptom-index.md
Inline:
  - line 42: [receiving-putaway §10](3-Resources/workflows/wms2-receiving-putaway-workflow.md)  ← OK

## Suggested action

For each broken link, either:
  - Fix the path (target was renamed / moved)
  - Remove the link (target was deleted intentionally)
  - Restore the target (you didn't mean to delete it)
```

### 6. Do NOT modify files

This skill is strictly report-only. If the user asks for auto-fix, tell them:

- For a rename where every caller needs updating, use `grep -rl 'old-name.md' sbdocs/ | xargs sed -i ...` (pattern; they run it themselves).
- For one-off fixes, they should open each source file and edit.

## Heuristics

- **Fuzzy suggestion** — when a link resolves to a non-existent `.md`, grep for nearby filenames (e.g. `fd <missing-basename> sbdocs/`). If there's a single reasonable match, suggest it as "did you mean …?".
- **Cross-repo paths** — links like `../../v2/wms2-api/CLAUDE.md` are valid but require resolution against the repo root. Include these in the audit; many docs point at code-adjacent CLAUDE.md files.
- **`.claude/skills/<name>/SKILL.md` references** — sometimes a doc points at a skill; resolve these too (relative from sbdocs or absolute).
- **URL-style links** (`https://...`) — skip entirely. Not this skill's job.

## Performance

A full sbdocs scan at current size (~80 docs) takes ~1–2 s. Don't parallelize prematurely; single-pass is fine.

## What NOT to do

- Do not check HTTP links or external URLs (different concern — use a link-checker like `lychee` if needed).
- Do not modify any file.
- Do not attempt to auto-rename links based on fuzzy matches. Suggest, don't rewrite.
- Do not check fragment identifiers (`#section-name`) — markdown renderers are lenient and section IDs drift.

## Exit criteria

Done when the broken-links report is printed. If result is "0 broken," report success concisely — no need for a long "all good" section.
