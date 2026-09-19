---
name: subagents-must-write-deliverable-to-a-file
description: "Review/analysis subagents here routinely go idle without reporting — require a file artifact in the prompt, never accept silence as a pass"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8697cde7-bbc9-40aa-8186-f1423187edab
  modified: 2026-08-21T01:38:57.525Z
---

Nam, 2026-08-20: subagents launched for review/analysis work **repeatedly end idle without producing their
report**. Do not let this keep happening, and never read silence as "found nothing".

**Why:** an idle-with-no-report agent is indistinguishable from one that reviewed cleanly. On SBDEV-2968 four
of five review lanes terminated with no deliverable; the one that did report (after being chased) returned
4 High / 4 Medium / 5 Low, including a defect in the deploy gate itself. Treating the silent four as passes
would have shipped an unreviewed authorization change. A previous instance of this cost a real Medium.

**How to apply — put this in every subagent prompt from the start, not as a follow-up:**

1. **Demand a file artifact, not just a final message.** "Write your report to `<absolute path>`; that is the
   one file you may create." A final message is lost when the agent exits idle; a file survives. For review
   work the path convention is `sbdocs/1-Projects/wms2/plan/reviews/<TICKET>-review-<lane>.md`, which doubles
   as the PR's review evidence.
2. **Make "nothing found" an explicit required output.** "If you found no defects, say so and still give the
   ruled-out list." Silence must never be a valid way to finish.
3. **Require a coverage list** ("what I actively ruled out") so a thin pass is visible as thin.
4. **Make "blocked" a first-class answer** — "blocked on X is a useful answer; silence is not."
5. **Name the 3–5 questions that decide the outcome.** Vague briefs correlate with silent exits.

**When one goes idle anyway:** chase it by name with SendMessage — names still resolve after the agent
terminates and a send resumes it from its transcript. Check `ListAgents` first; if no in-process agents are
listed they have already exited, and the tool-output files under the session `tasks/` dir hold only
intermediate tool logs, not the report — so messaging is the only recovery. See
[[omc-subagent-final-message-truncated]] for the related truncation failure and
[[idle-review-subagent-is-not-a-passing-review]] for the original lesson.
