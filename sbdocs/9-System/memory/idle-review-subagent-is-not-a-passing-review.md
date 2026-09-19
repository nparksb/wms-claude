---
name: idle-review-subagent-is-not-a-passing-review
description: A review subagent that goes idle without a report looks identical to one that found nothing — never treat idle as clean; re-spawn and demand the findings via SendMessage
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 1b9cf4f0-8bcb-4ecb-ad1f-d775f9530fa7
  modified: 2026-08-12T17:34:38.775Z
---

A spawned review lane (`code-reviewer`, `verifier`, …) can go **idle with no deliverable**: the completion notification arrives, the final message never does, and `ListAgents` shows nothing. That state is **indistinguishable from "reviewed, nothing found"**, and the default reading — "it finished, so we're good" — is wrong.

Observed 2026-08-12 on SBDEV-2643 A4: the code-review lane took **three** attempts. #1 went idle with no report; #2 and #3 died on `You've hit your session limit · resets 1pm`. Only the fourth produced findings — and it found a **Medium with a live behavioural edge** (a new repository query silently published over HAL, bypassing its service-layer guard) plus two false claims in javadoc I had written. Treating the first idle as a pass would have shipped all three.

Symptom to watch for: repeated `{"type":"idle_notification","idleReason":"available"}` messages with no content, or a `<task-notification>` whose output file contains only the agent's own Bash output.

**Why:** the whole point of an independent lane is that the implementing context cannot approve its own work. An empty review silently converts the process into self-approval while still *looking* like it cleared the gate — the failure is invisible precisely where verification was supposed to be strongest.

**How to apply:**
- A review lane counts as run only when **findings are in hand** — severity-rated, or an explicit "no findings at this severity". Silence is not a verdict.
- On an idle-with-no-report, `SendMessage` the agent by name and demand the report; ask for it **in numbered parts** if a single long message is not landing (that is what finally worked).
- If it still yields nothing, **re-spawn under a new name** with "put the COMPLETE report in your final message — it is the deliverable" and, for long reports, "send it to `main` via SendMessage in parts".
- `idleReason: "failed"` with a session/rate limit is a *hard* block, not a soft one — say so to the user and wait, rather than substituting your own review. Committing locally while waiting is fine; pushing or opening a PR is not.
- Do not self-review to fill the gap. Report the gap and let the user choose. See [[feedback_plan_status_after_implementation]] and [[omc-subagent-final-message-truncated]] (the related recovery trick — checking `tasks/<agentId>.output` for a lost deliverable — did **not** work here, because no transcript was written at all).

RECURRED at scale 2026-08-20: four of five SBDEV-2968 review lanes exited idle with no report. The mitigation — demand a file artifact up front — is in [[subagents-must-write-deliverable-to-a-file]].
