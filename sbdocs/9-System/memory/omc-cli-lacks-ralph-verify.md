---
name: omc-cli-lacks-ralph-verify
description: "Old 4.x global omc copies shadowed the plugin CLI (no ralph); removed 2026-10-24 and replaced by ~/.local/bin/omc shim → plugin CLI, so ralph now works"
metadata:
  node_type: memory
  type: project
  originSessionId: aefd6ebc-347a-42e3-978c-8dcf5a2e52fc
  modified: 2026-10-24T13:41:08.709Z
---

**Corrected 2026-10-24.** The 2026-10-13 version of this memory said "ralph cannot start because the installed CLI lacks `ralph`". The real cause is that a **stale `omc` shadows the plugin's CLI on PATH**.

On 2026-10-24, Nam is on plugin **5.7.11**: `~/.claude/plugins/installed_plugins.json` points at `cache/omc/oh-my-claudecode/5.7.11`. That plugin's own CLI has ralph: `node ~/.claude/plugins/cache/omc/oh-my-claudecode/5.7.11/bridge/cli.cjs ralph --help` works and reports 5.7.11. But `which -a omc` resolves to three old global installs of `oh-my-claude-sisyphus`, and none of them has `ralph`:

- `~/.bun/bin/omc`: 4.7.10. This one is **first on PATH**.
- `~/.nvm/.../v22.16.0/bin/omc`: 4.14.6.
- `/usr/local/bin/omc`: 4.13.5.

A session started before a plugin update also loads skill text from the older cache dir. This session showed 5.7.4.

**Why:** the ralph skill hard-requires `omc ralph verify`. Bare `omc` hits the bun 4.7.10 copy, so ralph looks unavailable even though the plugin supports it.

**2026-10-24, later:** at Nam's request, all three old global copies were REMOVED (bun, nvm npm, /usr/local npm). Then a shim was added at `~/.local/bin/omc` (first on PATH). It reads `installPath` from `installed_plugins.json` on every call and execs `bin/oh-my-claudecode.js`. Verified: `omc --version` reports 5.7.11 and `omc ralph --help` works. **Ralph is usable from now on**, in sessions started after this point; an older session may still hold the 5.7.4 skill text.

**How to apply:**
- At T3 Phase 1, run `omc --version`. If it is 4.x, either call the plugin CLI by its full path or ask Nam to fix PATH. Fixing PATH means removing or upgrading the global copies, which is a global install change, so ask first.
- The fallback Nam approved on 2026-10-13 still stands: an opus executor with the same contract, with the floor and review lanes run by the main session. See [[wms-fix-effort-tiers-and-the-floor]].
