---
name: sbdev3253-sampler-rerun-on-mac
description: "SBDEV-3253 DECIDED 2026-11-10: AC-5 (a) no code change — 0 lock waits on PRD business day; do NOT re-sample; remaining = cron-replica app metrics + log_lock_waits (infra)"
metadata:
  node_type: memory
  type: project
  originSessionId: 38a60c81-6e05-48ff-983f-11c30777d289
  modified: 2026-10-31T01:54:37.674Z
---

SBDEV-3253 (lock contention / statement_timeout measurement) — the original 2026-10-09→10-13 sampler output lives only on the Linux box (`.omc/` is machine-local, not synced). Nam had no access to it on 2026-10-31, so the sampler was rebuilt and relaunched on the Mac.

- Code + data: `owl/.omc/research/SBDEV-3253/` — `sampler.py`, `run.sh` (uv + psycopg, no psql on the Mac), output in `run/<server>.jsonl`, positive control in `control-2026-10-31/` (passed: W+A rows with Lock/advisory and the correct blocker pid).
- Runs until 2026-11-03T08:00Z under `caffeinate -i` (idle sleep only — lid close still suspends it; check for gaps between U ticks before trusting coverage).
- Next step: analyse AC-2/AC-3/AC-4(DB side) → AC-5 decision comment on the ticket. If the Linux-box data becomes reachable, merge both windows.
- `pg_stat_activity` is cluster-wide: all 4 PRD tenant DBs share one PG server, so unfiltered JDBC counts (~40) include landlord + keycloak — always filter `datname = current_database()`.

- **2026-11-09 update:** the 10-31 run died silently at 11-01 19:42Z (no END/ERR row) and covered only Sat–Sun → all zeros, does NOT satisfy AC-2. Interim posted on 3253 + 3193. Rerun: `run-2026-11-09/`, 2026-11-08 22:56Z → 2026-11-10 08:00Z (covers Monday 11-09). Analyser: `analyse.py <run-dir>` next to sampler.py. Next: AC-5 decision comment, then 3193 item 1 (runbook).
- Check the window's weekday before trusting zeros — a weekend window is not a business day.

- **2026-11-10 DECIDED, AC-5 (a).** Business-day run `run-2026-11-09/`: 0 ungranted locks on 3 DBs over ET morning + PT morning; only >30 s statement = wineco CleanUpOldMessagesJob DELETE, 205 s, IO-bound, unblocked. Gaps: 7.3 h DB-unreachable outage 11-09 19:12Z→11-10 02:28Z (ERR rows, not sleep); wh02_shipitez thread crashed 04:51Z (sampler has a thread-crash bug — fix before any reuse). Next instrument is `log_lock_waits=on` (infra), not another run. Side proposal on 3253: index message(created).

**Why:** a rerun burns 3 days of wall clock; knowing where each window's data lives avoids a third run.
**How to apply:** on resuming SBDEV-3253, check `run/` first, and ask about the Linux-box copy before re-sampling. Related: [[wms2-no-pipeline-runs-tests]], [[use-wineco-prd-for-data-validation]].
