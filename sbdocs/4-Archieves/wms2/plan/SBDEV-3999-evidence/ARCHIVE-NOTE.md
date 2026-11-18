---
title: "SBDEV-3999 archive note"
type: archive-note
status: archived
version: v2
ticket: SBDEV-3999
archived: 2026-11-03
---

# SBDEV-3999: a fixed assignment's container cannot leave its pick face

T2, so there is **no plan document**: the ClickUp ticket description was the spec. This folder holds the design consult and the six code-review reports.

## Outcome
- wms2-api PR #611, merged into develop as `da09d9ed` on 2026-11-03. Dev serves `develop-da09d9ed` (post-merge-verify: all proven).
- Dev-tested on 2026-11-03 against seeded rows. Bulk delete [plain, FLA] was refused with nothing deleted, FLA Move worked, and FLA Delete worked. The restore was byte-identical; the only side effect left was 3 `unitload_record` rows. Results are on the ticket.
- The guard itself (`UnitloadBusinessService.refuseFixedAssignmentBinDeparture`) cannot be reached over HTTP: every live route refuses earlier. It is a backstop, proven by `FixLocationAssignmentServiceIT` on real PostgreSQL.

## Findings and their dispositions
| Finding | Disposition |
|---|---|
| 2 live WineCo FLAs (`11-C09` FLA 23958473, `11-D06` FLA 8071264) point at containers in Nirwana | **Not machine-knowable, owner named:** WineCo support (Scott Dalton, tagged in the ticket's first comment). The repair is to delete and re-create both FLAs. The ticket stays `on dev` until this is done |
| The guard does not cover carrier/cart moves, Spring Data REST `Unitload` writes, or BOL bulk SQL transfers | **Dropped (Nam, 2026-11-03).** The architect's 22-caller census and the six review passes found no current route that can strand an FLA container. 0 FLAs were displaced on the 4 reachable PRD tenants. Re-raise if a census ever finds one |
| `FixLocationAssignmentRepository.findByAssignedlocationIdIn` is misnamed: its native SQL matches `assignedunitload_id` | **Dropped (rename).** It is an exported Spring Data REST search. It now has a call-site comment in `UnitloadService.deleteUnitLoadRecursivePreRun` and is pinned by `FixLocationAssignmentServiceIT.deletePreRun_shouldRefuseFlaContainer_onRealPg` |
| `architect-consult.md` (row 16) calls the mobile putaway assign route a reachable "desired refusal" | **Fixed.** That is wrong: `MobilePutAwayService` refuses `unitLoadNotInPutAwayLane` first. Corrected in the dev-test comment on the ticket; the report above is left as written |
| The FLA census was not run on PRD tenants that were unreachable from the dev machine | **Dropped.** The guard prevents new cases on every tenant; the census only tracks the WineCo repair |

## Cleanup
> Implementation worktree(s) removed 2026-11-03: wms2-api/SBDEV-3999 (branch `fix/SBDEV-3999-fla-bin-departure-guard`, merged as PR #611)
> No verify script existed (T2).
