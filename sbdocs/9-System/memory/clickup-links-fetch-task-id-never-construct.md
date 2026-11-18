---
name: clickup-links-fetch-task-id-never-construct
description: Never write a ClickUp task URL from a guessed ID; get the internal ID with clickup_get_task first
metadata:
  type: feedback
---

ClickUp task URLs use the internal ID (`https://app.clickup.com/t/868m3z08h`), not the custom ID (`SBDEV-3310`), and the internal ID can't be derived. On 2026-11-07 I wrote a made-up `868m5wbwb` link for SBDEV-3310 into the SBDEV-4007 description. I caught it and corrected it in a second update.

**Why:** a confident wrong link in a ticket goes to the wrong task, or nowhere, and every teammate who reads it is affected.
**How to apply:** before writing `[SBDEV-####](https://app.clickup.com/t/…)` into a ticket, plan or reply, call `clickup_get_task` with the custom ID and copy its `url`. Or link by custom ID only, without a URL. Known so far: 3310 = `868m3z08h`, 4002 = `868mrcfmg`, 4007 = `868mrmhn7`. Related: [[clickup-comment-api-drops-markdown-tables]].
