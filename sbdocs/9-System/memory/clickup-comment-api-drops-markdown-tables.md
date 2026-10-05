---
name: clickup-comment-api-drops-markdown-tables
description: "A markdown table in a ClickUp task comment posted via the MCP comes back as the literal text \"undefined\" — use plain lists for numbers that matter"
metadata:
  node_type: memory
  type: reference
  originSessionId: dc9fb8a8-b7c9-4dd6-ab5c-0a9c2454db03
  modified: 2026-09-24T10:19:21.112Z
---

A markdown pipe table inside `clickup_create_task_comment` text is **dropped** on the ClickUp side. The API reads it back as the literal word `undefined`, and the surrounding prose survives, so the comment looks complete at a glance. Measured on SBDEV-3353, 2026-09-24: a per-tenant sizing table that was an acceptance criterion's only record was lost this way. The conformance verifier caught it because it read the comment back through the API.

**How to apply:** put any figures a reviewer or an AC depends on in a plain `-` list or in `key: value` lines, never a table. After posting, read the comment back with `clickup_get_task_comments` and check that the numbers are there before counting the record as made. Headings, bold and bare links survive.

Related: [[consolidate-tickets-dont-file-one-per-finding]]
