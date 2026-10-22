---
name: set-config-in-lateral-does-not-parameterize-current-setting
description: "A per-row set_config() in a LATERAL does NOT reach a query that reads current_setting() — STABLE, read once; a sweep harness returned a clean false zero"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 1622ae45-d0bb-48e8-bd54-3543480f2f93
  modified: 2026-10-07T00:13:55.308Z
---

To replay a `current_setting('x.as_of')`-parameterized query at many instants in ONE statement, a
`generate_series(...) CROSS JOIN LATERAL (SELECT set_config('x.as_of', h::text, true)) CROSS JOIN
LATERAL (<query>)` harness does **not** work: `current_setting` is STABLE, so Postgres may read it once
per statement, and every instant evaluates the same value. Measured SBDEV-3325 (2026-10-06): the
90-day sweep returned **0 findings on every tenant**, including the instant a single-shot replay had
just flagged — a clean false zero.

**Why:** a broken instrument and a true zero look identical ([[a-zero-scan-needs-a-positive-control]]);
the positive control (one instant known to flag) is what exposed it.

**How to apply:** bind the instant into the query TEXT in the harness (replace the
`nullif(current_setting(...),'')::timestamptz` anchor with the series column, asserting the anchor
occurs exactly once), and always run a one-instant positive control through the same harness first.
The same session's next harness edit broke the f-string interval and the control caught that too.
