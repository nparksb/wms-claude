---
name: wms2-dev-actuator-metrics-readable-counters-lazy-and-reset
description: "wms2 dev /actuator/metrics is readable via wms-dev-probe api.sh; a 404 on a counter means never incremented, and counters reset on every dev deploy"
metadata:
  node_type: memory
  type: project
  originSessionId: 106c745f-922c-4987-90b6-23ad90878c48
  modified: 2026-10-19T13:35:59.700Z
---

On wms2 dev, `/actuator/metrics/<name>` (and `?tag=k:v` drill-down) is reachable with the
wms-dev-probe `api.sh` token. Measured 2026-10-19 (SBDEV-3183 AC-5).

Two traps when using it as an observation channel:
- **404 is not "endpoint missing".** Micrometer counters register lazily, so a meter that has never
  incremented answers 404. Positive-control with a meter that must exist (`jvm.threads.live`) before
  concluding anything. `wms2.authz.sdr.*` were all 404 at mode OFF for exactly this reason.
- **Counters are JVM-local and reset on every dev deploy**, and dev redeploys on every merge to
  develop (several a day). A multi-day measurement must be captured before each deploy and summed;
  `SBDEV-3183-evidence/ac5-shadow/capture.sh` does this for the SDR guard.

**Why:** nothing scrapes wms2 metrics ([[wms2-metrics-exist-but-nothing-scrapes-them]]), so ad-hoc
actuator reads are the only metric channel, and both traps produce a confident wrong zero.

**How to apply:** for any shadow-mode / counter-based rollout on dev, read via actuator with a
positive control, and snapshot before deploys. Positive control for the SDR guard in SHADOW:
`GET /v3` (root index) always records `would_deny{domainType=none,function=index}`.
