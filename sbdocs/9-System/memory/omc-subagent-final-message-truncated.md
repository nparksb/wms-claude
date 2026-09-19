---
name: omc-subagent-final-message-truncated
description: "OMC subagent (executor/planner/architect/critic) final messages often return as just \"Complete.\"/\"Done.\" — recover the real output from the task transcript JSONL"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c3950b95-bdc0-4447-a83c-7b7cc48f5e8d
---

When spawning oh-my-claudecode agents (executor, planner, architect, critic) via the Agent tool, the tool result frequently contains only a stub ("Complete.", "Done.") instead of the agent's full final message.

**Why:** the agent emits its deliverable mid-conversation, then OMC hook reminders prompt it to keep replying with short acknowledgements; the last (stub) message becomes the tool result.

**How to apply:** recover the real deliverable from the transcript at `/tmp/claude-1000/-home-nampark-dev-wms-claude/<session>/tasks/<agentId>.output` (JSONL). Parse lines where `message.role == "assistant"`, collect `content[].text` blocks, and take the largest text (or the largest containing an expected marker like "VERDICT:"). Glob the session dir — the session id changes across restarts. Asking the agent to "resend" via SendMessage works but burns ~50-100k tokens re-running it; transcript extraction is free.
