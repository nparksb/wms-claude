---
name: omc-cli-lacks-ralph-verify
description: "Installed omc CLI 4.14.6 has no `ralph` subcommand, but the ralph skill (plugin 5.7.1) hard-requires `omc ralph verify` — ralph cannot start"
metadata:
  node_type: memory
  type: project
  originSessionId: aefd6ebc-347a-42e3-978c-8dcf5a2e52fc
  modified: 2026-10-13T21:12:36.573Z
---

On 2026-10-13 (SBDEV-3755 Fix 1), `wms-plan-executor` Phase 1 invoked the ralph skill, whose
NON-NEGOTIABLE precondition is `omc ralph verify --write-baseline --session <id>`. The globally
installed CLI (`~/.nvm/.../bin/omc`, version 4.14.6) has no `ralph` subcommand at all; the loaded
ralph skill comes from the oh-my-claudecode plugin cache 5.7.1. The skill says STOP if the command
is unavailable, so ralph cannot run until the CLI is updated (`omc update`, a global npm change —
ask Nam first).

**Why:** the skill and CLI versions drifted; the skill forbids a hand-rolled fallback.

**How to apply:** at T3 Phase 1, check `omc --version` before invoking ralph. If it is still 4.x,
ask Nam: he chose (2026-10-13) "opus executor, no ralph" — one executor running the plan's stories
in order with the same contract (gate tests are the DoD, no weakening, stop on design problems,
commit per story, no push), with the floor (PIT, full -Pci suite vs baseline, verifier + review
lanes) still run by the main session. See [[wms-fix-effort-tiers-and-the-floor]].
