
## 2026-10-21 17:51Z: capture failure diagnosed, probe traffic to subtract
- The run after the #550 deploy exited 1 and wrote nothing. A rerun at 17:50Z worked unchanged, so the failure was transient: a version or actuator GET failing during the dev restart, which `set -euo pipefail` turned into an exit before the first append. `capture.sh` now records `(unreachable rc=N)` / `(read failed)` rows instead (tested with an exit-2 stub).
- Dev redeployed again to `develop-fb087689` (#551, contains #550 `cb692ee6`): counters reset a second time.
- Positive control: one `GET /v3/boxtype?size=1` as panderson moved `unruled{Boxtype}` from absent to 1.
- **Subtract from the AC-5 totals for build fb087689:** `unruled{Boxtype}` 1 and `would_deny{none,index}` 2 are Claude's probe calls (`/v3/boxtype` once, the `/v3` index twice), not user traffic.

## Archive note (2026-10-22)
- Archived: the active `1-Projects/wms2/plan/SBDEV-3183-evidence/` was merged into this folder (`4-Archieves/wms2/plan/SBDEV-3183-evidence/`). The ticket is `on dev` with all nine ACs ticked, and there is no plan document; the ticket ran from its ClickUp description.
- Implementation worktrees removed 2026-10-22: wms2-api/SBDEV-3183, -ac2, -ac6, -ac78, -ac8-base, -r15, -rail. Their branches were merged (#527, #529, #531, #546, #550) and deleted locally; the remote branches were left alone.
- Findings dispositions at archive: P3 proposed (proposals register); the go-live prerequisites and the unattributed b445b768 burst are owned by Nam (ticket AC-5); L4 dead caller dropped (warning kept in SdrFunctionRules and the caller sweep); the dev state≥700 transferlane_id question dropped (dev data, out of scope, unconfirmed).
