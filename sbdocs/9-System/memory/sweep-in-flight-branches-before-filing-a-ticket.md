---
name: sweep-in-flight-branches-before-filing-a-ticket
description: "Before filing a \"proposed\" WMS ticket from a review finding, sweep remote branches + open tickets for the same site — a review lane reading origin/develop cannot see in-flight fixes"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 33a9076d-fffb-489e-b774-2ede5ebb0137
  modified: 2026-10-02T00:50:40.636Z
---

On 2026-10-02 I filed SBDEV-3632 (web/job cancel releases requested, not held share) from an Architect review finding. Within the hour it turned out to be a duplicate of SBDEV-3621: already `pr submitted`, branch pushed that day, fixing the same line plus three more sites. Nam had me close 3632.

**Why:** review lanes are told to read `origin/develop`, so every in-flight fix looks like an open defect to them. A finding being "real on develop" is not the same as "unowned".

**How to apply:** before filing (or proposing) a ticket for a code site, run both:
- `for b in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin); do git diff origin/develop...$b -- <file> | grep -q '<literal>' && echo $b; done` (after `git fetch`)
- a ClickUp search for the method/class name in open + `pr submitted` tickets.

Also run `ListAgents`, since a busy peer session may own the branch. Related: [[consolidate-tickets-dont-file-one-per-finding]], [[derive-cross-repo-claims-from-origin-develop]], [[check-peer-sessions-before-resuming-a-ticket]].
