# 9-System — Scripts

Operational shell scripts that support the documented workflows in this vault. These are ops tooling, not documentation — but they live here so the automation is versioned alongside the workflow definitions it implements.

## Scripts

### `ui-sync.sh`

Cherry-picks v1 UI commits forward to v2 (Lane A of the weekly WMS v1→v2 sync sweep). Used for the two UI pairs whose stacks are identical (Nuxt 2 / Vue 2 / Vuetify 2):

- `v1/wms-web-ui` → `v2/wms2-web-ui`
- `v1/wms-mobile-ui` → `v2/wms2-mobile-ui`

**Usage:**

```bash
./sbdocs/9-System/scripts/ui-sync.sh \
  /Users/np1076/dev/spk/owl/v1/wms-mobile-ui \
  /Users/np1076/dev/spk/owl/v2/wms2-mobile-ui
```

**What it does:**

1. `git fetch v1` inside the v2 repo
2. Checks out v2's `develop-arden`
3. Creates a disposable `sync-YYYY-MM-DD` branch from `develop-arden`
4. Shows pending v1 commits (everything after the `v1-synced-upstream` tag)
5. Runs `git cherry -v` so you can see patch-equivalents already in v2
6. Prompts for confirmation
7. Cherry-picks the range with `-x` (preserves v1 SHA in the message)
8. Fast-forward merges the sync branch back into `develop-arden`
9. Advances the `v1-synced-upstream` tag to v1/develop-arden HEAD

**What it deliberately does NOT do:**

- Push. Always review first.
- Force anything. Any conflict halts the script with recovery instructions.
- Touch the v1 repo state.

**Preconditions (already done on both v2 UI repos):**

- `v1` remote added pointing at the sibling v1 repo
- `v1-synced-upstream` tag set to the last-synced v1 SHA

**Related docs:**

- Sync workflow: `sbdocs/2-Areas/wms-v1-v2-sync/README.md` *(TBD)*
- Sync log: `sbdocs/2-Areas/wms-v1-v2-sync/sync-log.md` *(TBD)*
- Migration plan skill: `owl/.claude/skills/wms-v2-migrate/SKILL.md`

### `verify-*.sh` (plan verification scripts)

Per-plan verification harnesses (`verify-SBDEV-####-*.sh`, `verify-YYMMDD-*-*.sh`). These are generated alongside their plans by the `wms-bugfix-plan`, `wms-feature-plan`, and `wms-v2-migrate` skills, and are owned by the plan they ship with — not stable enough to enumerate here. To find the harness for a plan, match the filename stem (e.g. `verify-SBDEV-2216-*.sh` ↔ `SBDEV-2216-*.md`).

Active scripts include `verify-SBDEV-2222-rest-inbound-no-idempotency-contract.sh` (REST inbound idempotency contract — pairs with `sbdocs/1-Projects/wms2/plan/SBDEV-2222-rest-inbound-no-idempotency-contract.md`).

## Conventions

- All scripts must be idempotent (safe to run twice).
- No automatic pushes or force operations — ever.
- Any destructive step requires explicit user confirmation.
- Scripts must use `set -euo pipefail` and absolute paths.
- Document assumptions and preconditions in a header comment.
