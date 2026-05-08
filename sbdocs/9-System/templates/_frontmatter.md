---
# Shared frontmatter fragment for sbdocs documents.
# Copy the block below into any document; adjust per-doc fields as noted.
# This file is a reference — do NOT treat it as a standalone doc.
#
# Required fields for every doc:
#   title            — plain-language title
#   type             — one of: plan | architecture | design | workflow |
#                      investigation | adr | runbook | data-dictionary
#   status           — draft | active | superseded | archived
#   version          — v1 | v2 | both   (WMS project version the doc describes)
#   scope            — component or subsystem name (e.g. picking, replenishment)
#   owner            — current maintainer
#   created          — YYYY-MM-DD
#   updated          — YYYY-MM-DD
#   last_verified    — YYYY-MM-DD (date doc was checked against code/reality)
#   verified_by      — how it was verified (code read, integration run, user validation)
#   related          — [] array of relative paths to related docs/plans/ADRs
#   tags             — [type-tag, scope-tag, version-tag]
#
# Optional fields (per doc type):
#   ticket, ticket_url, priority, project, requester   — plans
#   adr_number, deciders, supersedes, superseded_by    — ADRs
#   alert, severity, escalation, post_mortem_url       — runbooks
#   database, schema, table                            — data dictionary
---
