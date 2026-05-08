---
name: verify-docs
description: Audit sbdocs/ for drift against the code. Given a PR diff, a list of changed files, or no input at all, report which architecture / data-dictionary / workflow docs in sbdocs/3-Resources/ reference the changed code and whether their last_verified date is stale. Use when the user says "verify docs", "check doc drift", "what docs need updating", "audit sbdocs", or after landing a non-trivial change to v2/wms2-api or v1/wms-api. Produces a review report — does NOT rewrite docs.
---

# verify-docs

Audit the `sbdocs/` vault for documentation drift against the code. Produces a review report showing which docs reference recently-changed files and which are past their re-verify cadence. Does not rewrite any docs — the user decides what to update.

## What this skill IS and is NOT

- **IS:** a drift audit. Given a diff or a list of changed files, enumerates implicated docs + their staleness, and prints actionable sections.
- **IS NOT:** an automatic documentation updater. The user reads the report and updates docs manually (or asks Claude to do it).

## Inputs

One of:

- **PR diff**: user provides a branch name, commit range, or `git diff` output.
- **Explicit file list**: `verify-docs src/main/java/net/aim_ai/wms/service/CustomerorderService.java`.
- **Empty input**: audit ALL docs against current staleness thresholds (no file-change filter).

If the user says "verify docs" with no arguments, default to the empty-input audit.

## Workflow

### 1. Gather scope

Based on the input form:

**PR diff:**
```
git -C <repo> diff --name-only <base>..HEAD
```
Collect the absolute paths.

**Explicit files:**
Use the files as given.

**Empty input:**
Skip to step 3.

### 2. Map changed files → docs

For each changed file:

1. Extract the filename and relative path fragments (e.g., `CustomerorderService.java`, `service/CustomerorderService`, `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderService.java`).
2. Grep `sbdocs/3-Resources/` for any doc that mentions one of these fragments:
   ```
   rg -l "<filename or fragment>" sbdocs/3-Resources/
   ```
3. Record every hit as (changed_file → [doc1, doc2, ...]).

Hot files that already have strong doc coverage (if these change, flag loudly):

- `WmsConstants.java` → state-machine catalog, sysprop catalog, role matrix, club-run/BOL workflows
- `CustomerorderService.java`, `CustomerorderBatchService.java` → state-machine, cancel workflow, club-run workflow
- `PickingorderBusinessService.java`, `MobilePickingService.java` → picking workflow, state-machine §5.5
- `BillofladingService.java` → BOL workflow, state-machine
- `ReceivingService.java`, `MobilePutAwayService.java`, `AdviceService.java` → receiving-putaway workflow
- `TenantContext.java`, `TenantFilter.java`, `TenantDynamicRoutingDataSource.java`, `TenantConfigLoader.java`, `TenantPoolEvictor.java` → tenant-routing, end-to-end request journey
- `SchedulingConfiguration.java`, `AdvisoryLockService.java`, `schedulejob/*.java` → scheduled-jobs catalog
- `Authority.java`, `AdminController.java` → keycloak-role-matrix
- `SyspropService.java` → sysprop catalog
- `application.properties` → tenant-routing, sysprop catalog
- `pom.xml` → v1-vs-v2-delta (stack section)

### 3. Check staleness

For every doc in `sbdocs/3-Resources/` (architecture/, data-dictionary/, workflows/):

1. Parse the frontmatter `last_verified:` date.
2. Compute days since that date (use today: `date +%F`).
3. Classify:
   - Green: ≤60 days
   - Yellow: 61–90 days
   - Red: >90 days

### 4. Read each implicated doc's "Re-verify" cadence

From the "Verification Log" section or similar — typically `**Re-verify every N days.** Next due: YYYY-MM-DD.`

If "next due" is in the past, mark overdue regardless of the default red/yellow thresholds.

### 5. Produce the report

Structured sections, ALL tables use absolute paths:

```markdown
# Doc Drift Audit — <today's date>

## Summary
- Changed files analyzed: N
- Docs implicated by changes: M
- Docs overdue for re-verification: K
- Docs in yellow zone: J

## Section 1 — Implicated by this change

| Changed file | Docs to review | Last verified | Status |
|---|---|---|---|
| path/to/CustomerorderService.java | state-machine-catalog.md §5.1 | 2026-04-19 | green |
| path/to/CustomerorderService.java | cancel-cascade-workflow.md §3 | 2026-04-19 | green |

## Section 2 — Overdue regardless of this change

| Doc | Last verified | Days since | Next due |
|---|---|---|---|

## Section 3 — No doc coverage

| Changed file | Recommendation |
|---|---|
| path/to/NewService.java | No doc references this file. Consider documenting or link from existing architecture doc. |

## Section 4 — Recommended actions (ranked)

1. Open <doc>, confirm §N still matches code, bump last_verified to today.
2. ...
```

### 6. Do NOT modify docs

Report only. If the user wants to update a doc, they ask a follow-up ("update the state-machine doc §5.1 with today's last_verified and confirm §5 cascade still matches code").

## Heuristics

- **A changed config value** (e.g., `spring.jpa.open-in-view`) should almost certainly require a docs update — flag these with priority.
- **A changed constant** in `WmsConstants.java` is high-signal — state-machine catalog, sysprop catalog, and role matrix should all be checked.
- **A new `@Transactional` site** → transaction-osiv-boundary-map §7 (REQUIRES_NEW inventory) may need re-count.
- **A new `@Scheduled` method** → scheduled-jobs catalog §1 overview (two infra jobs claim) becomes stale immediately.
- **A new entity class** in `v2/wms2-api/src/main/java/net/aim_ai/wms/model/` → landlord-vs-tenant-entity-map counts change.
- **Changes in both `v1/wms-api` AND `v2/wms2-api`** → delta doc probably needs review; flag with extra priority.

## Output constraints

- Keep the report under 300 lines. Use absolute paths.
- If the user input was empty (full audit), cap reported docs to top 20 by staleness.
- Do NOT print "docs look fine" as a wall of green rows — summary line is enough.
- Do NOT read the full content of each doc; only frontmatter + the single section implicated.

## What NOT to do

- Do not rewrite any doc.
- Do not invent file:line references — if a doc's §N cannot be found, say "doc references code path but exact section unclear; operator should review top-down".
- Do not suggest creating new docs unless Section 3 (no doc coverage) has entries — in that case, recommend by name only, don't author.
- Do not run this skill in a loop. One audit per invocation.

## Exit criteria

Done when the structured report has been printed. The skill does not fix anything.
