---
name: it-reproduces-a-bug-prd-did-not-have
description: "An IT that fails on every build cannot date a PRD regression — SBDEV-3854's no-tx delete failed in the IT back to v2.0.137 while PRD did 64 such deletes until 2026-09-11"
metadata:
  node_type: memory
  type: project
  originSessionId: bab8ca87-645d-4689-bdfb-9abd09c9da00
  modified: 2026-10-21T19:27:23.579Z
---

SBDEV-3854 (2026-10-21): container delete with stock 500'd on WineCo PRD from 2026-09-11 15:33 UTC
(64 MANUAL_REMOVAL stock rows in the month before, 0 after). `DeleteContainerWithStockIT` (no
surrounding tx) failed with `TransactionRequiredException` / "No transactional EntityManager" on
**every** build it could run — develop, 1d5c8bef (v2.0.141), 8e9cfb96^, and 55cf8952 (v2.0.137, with
the Sept-7 harness transplanted because the old one can't migrate). Every PRD image since 2026-07-09
carries the same lock code (7316ddb5). So the IT reproduces a failure PRD did NOT have before
~09-11: some runtime factor outside the code (stack env, a JPA/OSIV override, an older image than the
build list suggests) was removed by the deploy around then. Unresolved; needs devops deploy history
or PRD logs.

**Why:** a code bisect with an IT can only find code changes. When the IT is red on the last build
PRD demonstrably ran fine, stop bisecting code — the answer is in the runtime, not the diff.

**How to apply:** before bisecting a "when did PRD break" question, run the IT on the last build
known good on PRD (positive control). If it is red there too, switch to deploy/env evidence.
Also: prod deploys are MANUAL (Portainer webhook commented out in the prod workflow), so GitHub
build times are not deploy times. Fix is landed regardless (wms2-api #552 c9e8f9a1).
Related: [[is-ancestor-does-not-prove-a-fix-shipped]], [[wms2-deployed-image-differs-from-branch-head]].
