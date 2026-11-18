---
name: clickup-clip-frames-via-imageio-ffmpeg
description: "A ticket's ClickUp .webm screen recording is downloadable without auth and can be read frame-by-frame — it often shows the real API error the ticket text omits"
metadata:
  node_type: memory
  type: reference
  originSessionId: 45203244-bd25-423f-b113-a289ac597c64
  modified: 2026-11-08T11:17:18.001Z
---

ClickUp attachment URLs (`t9006034209.p.clickup-attachments.com/...webm`) download with plain `curl -L` (no auth). This Mac has no ffmpeg/brew. To get one, create a scratch venv: `python3 -m venv $SCRATCH/venv && $SCRATCH/venv/bin/pip install imageio-ffmpeg pillow`. Then extract frames with `ffmpeg -i clip.webm -vf "fps=1/3,scale=1280:-1" f_%03d.png`, tile them 2x2 with PIL, and Read the sheets.

**Why:** on SBDEV-2578 the ticket only said "generic network/server error". The reporter's DevTools Response tab in the clip showed the exact Jackson error (`"2021-07-12 14:36:29" could not be parsed at index 10`). That pinned the root cause in minutes, where DB probes had been inconclusive.

**How to apply:** at triage, when a ticket has a clip attachment and the text is vague, decode the clip before forming any hypothesis. Related: [[hub-evidence-discipline]].
