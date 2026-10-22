---
name: subagent-background-notification-can-stall
description: "An idle subagent \"waiting for its background mvn suite to notify it\" may never wake; the lead must watch the build itself"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 6b83b798-a844-4039-9485-7c3ea8c657fa
  modified: 2026-10-17T01:22:19.618Z
---

On SBDEV-3672 (2026-10-16), an opus executor started `mvn clean verify` in the background, said "the monitor will notify me", and went idle. The suite finished at 19:12, and the executor was still idle at 20:21. Nothing woke it until the lead sent a message.

**Why:** a background-task completion does not reliably resume an idle subagent. Its "waiting for the notification" reads like progress, but it is a stall.

**How to apply:**
- When an executor goes idle on a long build, the lead watches the build in its own background Bash, using an `until` loop on Maven process exit.
- Use `pgrep -f "[p]lexus-classworlds"`. The bracket stops the pattern from matching its own shell; see [[pgrep-f-wait-loop-matches-itself]].
- Then tally `target/{surefire,failsafe}-reports/*.txt` plus `failsafe-summary.xml`, and message the executor with the result.
- Tell executors up front to read `failsafe-summary.xml` rather than wait for a notification.
- Related: don't let an executor edit source while its own `clean verify` is still compiling. That run then reflects a mixed tree and can't be cited for either head.

See also [[idle-review-subagent-is-not-a-passing-review]].
