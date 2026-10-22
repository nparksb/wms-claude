---
name: sbdev-3325-oms-egress-watchdog
description: "SBDEV-3325 built a scheduled GitHub Actions SQL watchdog as the consumer for the unscraped wms2.oms.*_failed counters; infra prerequisites are Joe's"
metadata:
  node_type: memory
  type: project
  originSessionId: 1622ae45-d0bb-48e8-bd54-3543480f2f93
  modified: 2026-10-07T00:14:08.823Z
---

Nam 2026-10-06: "nothing scrapes it, build the pipeline check". So the consumer for SBDEV-3314's
`wms2.oms.*_failed` counters is NOT Prometheus — it is `scripts/oms-egress-watchdog/` in wms2-api
(SQL per tenant DB + `run.sh` + `.github/workflows/oms-egress-watchdog.yml`); a red scheduled run is
the alert. See [[wms2-metrics-exist-but-nothing-scrapes-them]].

Facts that shaped it (all measured that day):
- PRD Postgres is reachable only via SSH to `wms.siteboss.net` forwarding a `100.x` (Tailscale-range)
  address; GitHub-hosted runners need a bastion key → infra (Joe). `schedule:` fires only from `main`,
  and Nam only merges to `develop` ([[deploy-only-to-develop-release-and-main-are-devops]]).
- wms2-api has NO outbound alert channel (no mail/Slack/webhook sender), logs CONSOLE-only.
- Outbound `message` rows = destination not NULL and not `'N/A'` — NOT `^https?://`: a missing URL
  sysprop writes `URL_NOT_CONFIGURED`. Transport failures from the outbox dispatcher are
  `statuscodeanswer='EX'`; legacy `doSend` writes `503`.
- 90-day replay on all 4 PRD tenants: the ONLY finding was the 3314 incident; would have fired
  2026-07-15 (misrouted) / 07-17 (failing) vs 57 days unseen.
- The local PRD MCP entries for shipitez c1wh/nywh and wineco wsl all pointed at `wh01_hydra_v2`
  (hence "permission denied for table message"); fixed in `~/.claude.json` (backup `.bak-3325`).

Related: [[wms2-prd-public-schema-create-granted-to-public]], [[wms2-hydra-prd-notifies-uat-oms]].

**Status 2026-10-07:** PR #467 MERGED to develop `ce454c68`, ON DEV (verified via /api/public/version); watchdog itself inert until Joe does infra + main promotion. Was: PR #467 → develop (`pr submitted`), also fixes export/STOCK_UPDATE writing no
row on ResourceAccessException. Filed SBDEV-3672 (8 SHIPPED 503s never redelivered — the `EX`
timeouts WERE redelivered by the outbox; I first mis-claimed them as lost: `EX` = outbox attempt,
`503` = legacy doSend, so the code tells you the path) and SBDEV-3673 (PUBLIC CREATE).
**2026-10-07 follow-up:** dev test of #467 found every resend wrote 2 `message` rows (createServiceLog
preset `version`, so save() MERGED and it returned the id-less original). Fixed by PR #470 → develop
`fc046edc`, ON DEV; retested as panderson: 3 calls → 3 rows, both resends linked. Same pattern may
null `picktounitload_id` in OrderMonitorViewService.printToteLabels — FILED SBDEV-3677 (T2): PRD 0 lasting damage (picking relinks); `customerordernumber` does NOT distinguish dashboard vs mobile path.
**2026-10-07 SBDEV-3677:** PR #471 MERGED `8fab618e`, ON DEV (verified /api/public/version). CORRECTION: the Dashboard printToteLabels path has NEVER run on v2 PRD (no `PICKING_TOTE_DEFAULT` row on any of 4 tenants; 0 totes with the configured label) — latent, no repair; the earlier "transient match" was mobile picking.
