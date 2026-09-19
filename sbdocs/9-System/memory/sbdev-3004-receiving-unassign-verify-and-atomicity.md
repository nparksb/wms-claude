---
name: sbdev-3004-receiving-unassign-verify-and-atomicity
description: SBDEV-3004 (v2) — PR #195 + wms2-web-ui #76, API merges first; four review lanes each found a Medium, two in my own work
metadata:
  type: project
---

`ReceivingService`: `unassignPallet` skipped `verifyPalletOrCartLabel` (its sibling `assignPallet`
does it), and `updatePallet` was not transactional so a failing assign leg left the old pallet
relocated with nothing assigned. **PR wms2-api#195** (6 commits) + **wms2-web-ui#76** (2). **Merge
API first** — the UI change only surfaces an error the API makes possible. No Flyway migration.
Tier T2, no plan document: the ClickUp ticket + triage comments are the plan of record.

**Do not cherry-pick these commits apart onto `main`.** `a524261` adds a throw inside `assignPallet`
that, on the both-non-null path, fires *after* `unassignPallet` has relocated the old pallet — safe
only because `5de192e` made `updatePallet` `@Transactional(rollbackFor=...)`, which `main` lacks.

Load-bearing details:
- `unassignPallet`/`assignPallet` are called from `updatePallet` as **`this.`-self-invocations**, so
  their own `@Transactional` is inert on that path. The boundary belongs on `updatePallet`, which
  the controller reaches through the proxy. `transferUnitLoadToLocation` is `REQUIRED` so it joins.
- `rollbackFor` is mandatory: both exceptions extend `Exception`. See
  [[transactional-tests-blind-to-propagation-and-readonly]] — the pin needed **six** assertions
  (value, propagation, readOnly, rollbackFor, noRollbackFor, noRollbackForClassName); `NOT_SUPPORTED`,
  `readOnly=true` and `noRollbackFor` are each a full silent revert that reads green.
- Verify sits **after** the null check deliberately, so an unresolvable label stays a no-op:
  `/unlinkSelectedPallet` fires from a Vue `destroyed()` hook on every screen exit.
- No explicit pessimistic lock on this path (`ignoreLock=true` skips `findByIdForUpdate`; both
  activity codes are explicitly `PASS_THROUGH`, so `lockOwningPickingorders` never fires). A `40P01`
  here is expected and rolls back, not a new defect.
- `Cart` as a unit-load **type** holds ZERO rows on all six environments; `CART-####` labels name
  **Pallet-type** rows. So requiring Pallet type is correct. 57,113 ASSIGN/UNASSIGN subject rows
  (`fromunitload IS NULL` — the rest are per-case cascade children) are 100% Pallet.

Found along the way: [[wms2-boxed-long-id-comparison-works-under-128]] and
[[java-bare-percent-ns-is-not-positional]]. Still open: atomicity covers only 2 of 4 entry points
(`createPallet` commits before `updatePallet`); `/createAndSelectPallet` has no caller in either UI.
