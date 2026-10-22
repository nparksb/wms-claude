---
title: "SBDEV-3183 fact-check: AC-1 amendment, register row P3, ClickUp ticket"
ticket: "SBDEV-3183"
type: "evidence"
created: "2026-10-18"
---

# Fact-check, 2026-10-18

Ground truth: wms2-api origin/develop `c9cd078d` (fetched). web-ui `add0628`, mobile-ui `f51dc6c`, oms-laravel-api `59039e8c`.
Runtime TSV measured at `4ce87ead`. DB re-checked read-only on dev_wh01_om1 (WineCo dev). PRD DBs: not re-verified.
PR #531 is **OPEN** (not merged) as of this check.

## Verdict

**REQUEST_CHANGES.** Artifact 1 (amendment) and artifact 2 (P3) are substantively correct; 5 small fixes. Artifact 3 (ticket description) is
correct *as of `4ce87ead`* but STALE at `c9cd078d` in title, Current state, §1, §2/AC-2, AC-4 and AC-5. Ticket comments are accurate (corrections are
posted as later comments) but the description was not refreshed after #527/#529. AC-1 tick is justified, with a caveat. AC-2 is correctly unticked.

## 1. Amendment block (ac1-sdr-surface-classification.md)

| Claim | Status | Evidence |
|---|---|---|
| LockOverviewDtoView/AllDtoView back Lock Report via computed URL `'/' + resource + '/search/findByKeyword'` | VERIFIED | web-ui `store/reports/lock.js:64` |
| Two of four caller-detection methods shared a leading-slash pattern; caught by code review on #264 | VERIFIED | `4-Archieves/.../review-code.md` H-1, line 112 "Both embed the leading slash" |
| B.5 = 27 types, not 29 | VERIFIED | #264 diff adds 27 class-level `@RepositoryRestResource(exported=false)` |
| #264 withdrew 27 with class-level exported=false; three join-table rules deleted | VERIFIED | diff removes `UserGroupUserRole`, `UserRoleUserFunction`, `UserUserRole` rules.put |
| Surface 62 -> 35 exported | VERIFIED | TSV: 35 exported collections |
| At 4ce87ead: 71 mapped, 35 exported, 8 ruled, 27 unruled, 147 searches, 8 writable | VERIFIED | TSV: 71 / 35 / 147 / 8 writable (Advice, Boxtype, Client, Cyclecount, Location, Section, Sysprop, UserGroup); ruled = User, UserFunction, UserGroup, UserGroupUser, UserRole, Sysprop, Message, StockrecordView = 8; 35-8 = 27 |
| Sysprop+Message ruled by SBDEV-3222 `3caa8990` | VERIFIED | `git log -1 3caa8990` |
| StockrecordView new (SBDEV-3410 P2); Stockrecord now exported=false | VERIFIED | StockrecordRepository.java:26 |
| Writable set 8, down from 11; Customerorder + LocationType fully write-withdrawn; UserRole read-only (SBDEV-3545) | VERIFIED | RestConfiguration SDR_WRITE_WITHDRAWN lines 488, 522; TSV UserRole not writable; commit 04a411ec |
| Narrowed per resource in PRs #290, #295, #297 | VERIFIED | all three MERGED 2026-09-03 (#299/#300 also touched UserGroup/UserRole, not named; harmless) |
| §D.3 answered "no": dev + all four PRD have no `service-account-*` row; oms_integration holds 0 functions, is V2.2.09 return auto-receive operator | VERIFIED (dev) / NOT RE-VERIFIED (PRD) | dev SQL: only `anonymous` (0 fns) and `oms_integration` (0 fns) match the name patterns |
| SBDEV-3671 made OMS read customerorder `findByExternalIdList`, `findByOrderbatchId`, customerorderBatch `findByBatchid` | VERIFIED | oms config/wms.php:171-173; commit 52ae0ab9 2026-10-07, after the 2026-09-01 lane |
| Customerorder -> must stay open; CustomerorderBatch Cypress-only -> must stay open | VERIFIED | same; matches rail decision |
| Ruled since: Advice, Cyclecount, Location (#529), two Location search overrides | VERIFIED | SdrFunctionRules.java:364,367,373,385,390; 11 rules.put at develop |
| 24 unruled after #529 = 15 + 8 + 1 | VERIFIED | Unruled(27) minus Advice/Cyclecount/Location = 24 (counted from TSV). Must-stay-open 8 = Client, Itemdata, Shipperid, Boxtype, Section, Stockunit, Customerorder, CustomerorderBatch. Gating 15 as listed. Pickingorder Cypress-only. 15+8+1 = 24 |
| "§B.6 is still undecided. Both types remain exported" | STALE/CONTRADICTS next bullet | CustomerorderBatch moved out of B.6 two bullets later; Pickingorder is the only remaining Cypress-only type |
| "Of the 24 types still unruled once #529 merges" | STALE TENSE | #529 merged c9cd078d 2026-10-19 02:17 UTC |
| Frontmatter `amended: ... against origin/develop 4ce87ead` | STALE | block cites #529 / c9cd078d facts |
| Completeness: callers found later | MISSING | block omits (a) mobile `components/picking/pick.vue:253` GET `/client/search/findByClNr` (Client has a 2nd no-function caller), (b) web `components/handlingUnits/stockUnitsTable.vue:701` `itemdata/search/findByClientIdIn` (classification line 231 ties it to Cycle Count createCc.js only). Both verified at origin/develop. Neither changes a bucket |
| "any rule on a type OMS reads would deny OMS with USER_NOT_PROVISIONED" | OVERSTATED (low) | true for service-account and no-token paths; the third auth path (passthrough of the logged-in OMS user's JWT) would hit a provisioned user and deny MISSING_FUNCTION or allow. Ticket comment lists all three paths; amendment does not. UAT DBs not checked (comment says so; amendment omits) |

## 2. Register row P3 (proposals-register.md)

| Claim | Status | Evidence |
|---|---|---|
| Surviving SDR item PATCH on Advice and Cyclecount; `configureAdviceItemVerbWriteExposure` leaves PATCH open | VERIFIED | RestConfiguration.java:682, call at :890; TSV itemVerbs include PATCH |
| Only `state` is @ReadOnlyProperty on both | VERIFIED | Advice.java:31, Cyclecount.java:31, no other occurrence |
| Advice binds clientId, type, allowoverdelivery, externalid | VERIFIED | Advice.java fields 15,20,33,36 |
| "UI sends only `comment`" | IMPRECISE | both `saveComment` actions `$patch('/advice/'+id, data)` with data = `{id, comment}`; body also carries `id` (same row, harmless). Reword "only `comment` (plus the row id)" |
| Dev holders INBOUND_BOL 43/100, CYCLECOUNT 45/100 | VERIFIED | SQL by user: 43 / 45 / 44 (STORAGE_LOCATION) / 46 (BILL_OF_LADING) of 100 |
| Every tenant at OFF | VERIFIED dev / not re-verified PRD | dev los_sysprop = OFF, client_id 0 |
| Source: SBDEV-3183 AC-2 security review S1 | VERIFIED | review-ac2-rules-security.md S1 |
| Source: SBDEV-3775 re-review R-2, widened from "Advice.type writable after receipt" | UNVERIFIABLE | no SBDEV-3775 evidence file in sbdocs holds R-2 |
| Fix costs (~1/2 day, ~2 hr, 30 min probe), tier T3 | UNVERIFIABLE (estimates) | judgement |
| Memory `advertised-capability-is-not-exploitable-capability` exists | VERIFIED | MEMORY.md index |

## 3. ClickUp SBDEV-3183 (status "in development")

### Title: "27 of 35 exported types unruled, 6 of 9 kept-writable resources undecided"
STALE at c9cd078d: 24 of 35 unruled, 3 of 9 undecided (Boxtype, Client, Section; those 3 pending #531's recorded decision).

### Description

| Section / claim | Status | Evidence / correction |
|---|---|---|
| Current state: 71 / 35 / 8 / 27 / 147 / 8 at 4ce87ead | VERIFIED at 4ce87ead; STALE at HEAD | develop: 35 exported, 11 ruled, 24 unruled (ticket comment 90110280367268 says the same) |
| Ruled (8) list | VERIFIED at 4ce87ead; STALE | add Advice, Cyclecount, Location -> 11 |
| Unruled (27) list | VERIFIED at 4ce87ead; STALE | remove Advice, Cyclecount, Location -> 24 |
| "AC-2 is 3 of 9 discharged" | STALE | Advice, Cyclecount, Location ruled by #529: 6 of 9. Boxtype/Client/Section pending #531 (OPEN) |
| "Prep for AC-5 in flight: PR #527" | STALE | #527 merged 944cc789 2026-10-19 01:00 UTC, on dev |
| §1 heading "27 of 35" and groups 17+6+2+2 | STALE | arithmetic was right at 4ce87ead (17+6+2+2=27). Now: needs gating **15** + must stay open **8** + Cypress-only **1** (Pickingorder) + write-caller-no-read **0** = 24 |
| §1 "Needs gating 17" includes Customerorder and Location | STALE | Customerorder -> must stay open; Location ruled |
| §1 "Must stay open, 6" | STALE | 8 (adds Customerorder, CustomerorderBatch). Also Client has a second no-function caller (mobile pick.vue); Itemdata has Handling Units caller |
| §1 "Cypress-only, 2: CustomerorderBatch, Pickingorder" | STALE | CustomerorderBatch -> must stay open (SBDEV-3671 OMS search); only Pickingorder remains |
| §1 "Write caller but no SDR read caller, 2: Advice, Cyclecount" | STALE | both ruled by #529 |
| §2 table, 11 rows, state at 4ce87ead | VERIFIED at 4ce87ead | row verbs match TSV. Table mixes 9 AC-2 resources with UserGroup/UserRole (11 rows); only 8 are writable now (Customerorder, LocationType, UserRole are not). Add a one-line note |
| §2 Advice/Cyclecount/Location rows "unruled" | STALE | ruled INBOUND_BOL / CYCLECOUNT / STORAGE_LOCATION (+2 overrides) |
| "Rules registered 8 ... all on USER_ADMIN_VIEW" (shipped-by-3169 table) | historical, OK if labelled | now 11 rules on several functions; table is headed "what SBDEV-3169 shipped" |
| Landmine: "OMS reads over SDR ... v3/client, itemdata, shipperid, boxtype, itemdata/search/findByClientId, optionally printer" | STALE/INCOMPLETE | omits `client/search/findByClNr` and the 3 SBDEV-3671 paths (customerorder x2, customerorderBatch). OMS has 9 SDR reads + 1 write (config/wms.php:164,171-173,182-188,174) |
| AC-1 text | VERIFIED | doc path exists; amendment exists |
| AC-2 text "3 of 9 ... Open: Advice, Cyclecount, Boxtype, Location, Section, Client" | STALE | 6 of 9; Open: Boxtype, Client, Section (rail #531) |
| AC-3, AC-6..AC-9 | not re-graded | unchanged by this work; AC-6 "partly moot" note still right |
| AC-4 "OMS ... six SDR reads and its one SDR write" | STALE | nine reads (6 + 3 from SBDEV-3671) and one write |
| AC-4 "First, measure whether the OMS principal resolves to any function grant (§D.3, still unmeasured)" | STALE | measured 2026-10-18: no function grant (comment 90110280364278); dev re-verified here |
| AC-5 text | OK | still open; "Prep: PR #527" should say merged |
| Related: "SBDEV-3157 ... 11 kept (now 8)" | VERIFIED | |

### Comments of 2026-10-18 (all 25 read)

| Claim | Status | Evidence |
|---|---|---|
| Reconciliation: 27 unruled, AC-1 proposed tick, AC-2 3 of 9 | VERIFIED at 4ce87ead | |
| "Needs gating: 18 ... double-counted" then corrected to 17+6+2+2 | VERIFIED | arithmetic holds |
| Path "archive/SBDEV-3183-evidence/ac1-..." in first reconciliation comment | WRONG (cosmetic) | real path `sbdocs/4-Archieves/wms2/plan/SBDEV-3183-evidence/` (description has it right) |
| AC-4 comment: needs gating 16 -> corrected to 15 | VERIFIED | 17 - Location - Customerorder = 15 |
| #527 merge 944cc789 head 477b6af0 | VERIFIED | gh |
| #529 merge c9cd078d head fd43e407; 35 / 11 / 24 | VERIFIED | gh + git log + rules.put count |
| #529 comment "AC-2 stands at 6 of 9 once this merges" | VERIFIED | |
| Decision (c): rail commit b12ff678 | PARTIALLY CHECKED | branch head is now merge 31e68459; b12ff678 not independently opened |
| "Once #529 and this rail merge ... AC-2 can be ticked" | CORRECT | #531 is still OPEN so AC-2 correctly unticked |
| pick.vue and stockUnitsTable.vue callers | VERIFIED | see section 1 |
| "no multi-line SDR call on Advice, Cyclecount, Location in either UI" | not re-run | my literal-path sweep also found none; computed-URL residue is called out in SdrFunctionRules comment |
| DB census (5 DBs, counts) | VERIFIED dev (100 users, 54 with any function, oms_integration 0, anonymous 0) / NOT RE-VERIFIED PRD |

### AC-1 ticked: justified?
**Yes, with a caveat.** The deliverable (runtime-derived bucket classification of every exported type) exists and was amended; the remedy it prescribed was executed
(#264) or moved to AC-2/AC-4. Caveat to record on the ticket: the classification's caller sets have now been corrected three times (Lock views 2026-09-01,
Customerorder/CustomerorderBatch via SBDEV-3671, mobile Client + web Itemdata via multi-line sweep). The 15 "needs gating" verdicts still rest on literal-path sweeps
that cannot see computed URLs. Suggest adding one clause to the AC-1 tick: "caller sets corrected 3 times; re-derive before enforcing any of the 15".

### AC-2 "3 of 9" and §2 table at c9cd078d
Accurate at 4ce87ead, **not at c9cd078d**: 6 of 9 (Customerorder, LocationType, Sysprop, Advice, Cyclecount, Location). Remaining Boxtype, Client, Section.

## WRONG / STALE items and exact corrections

1. Amendment bullet "§B.6 ... Both types remain exported": -> "§B.6: only `Pickingorder` is still Cypress-only and undecided; `CustomerorderBatch` moved to must-stay-open (below)."
2. Amendment "once #529 merges" -> "after #529 (merged c9cd078d, 2026-10-19)". Frontmatter `amended:` -> `against origin/develop c9cd078d`.
3. Amendment omits two callers: add "mobile `components/picking/pick.vue` reads GET /client/search/findByClNr (Client has two no-function callers); web `components/handlingUnits/stockUnitsTable.vue` reads itemdata/search/findByClientIdIn (not only Cycle Count)." Also qualify §D.3 bullet: "service-account and no-token paths only; the passthrough-JWT path uses the real user; UAT not checked; PRD not re-verified here."
4. P3: "the UI sends only `comment`" -> "sends `{id, comment}`; nothing else". R-2 provenance unverifiable (no SBDEV-3775 doc holds it).
5. Ticket title -> "[WMS v2] SDR gating remainder: 24 of 35 exported types unruled, 3 of 9 kept-writable resources undecided, and every tenant still at OFF".
6. Description Current state -> 11 ruled (add Advice, Cyclecount, Location) / 24 unruled; "AC-2 is 6 of 9 discharged; Boxtype, Client, Section pending PR #531"; "PR #527 merged 944cc789".
7. Description §1 -> "24 of 35 unruled (c9cd078d): needs gating 15, must stay open 8, Cypress-only 1 (Pickingorder), write-caller-only 0." Replace the four group bullets with the lists in the amendment.
8. Description §2 table: mark Advice, Cyclecount, Location as ruled (#529); note that 8 are writable, and that the table lists 11 rows (9 AC-2 resources + UserGroup + UserRole).
9. AC-2 text -> "6 of 9 discharged (adds Advice, Cyclecount, Location by #529 rules). Open: Boxtype, Client, Section, pending the recorded-decision rail in PR #531 (open)."
10. AC-4 text -> "nine SDR reads and one SDR write"; delete "still unmeasured" and cite the 2026-10-18 measurement (no function grant on dev or any PRD tenant; UAT unchecked).
11. Landmine "OMS reads over SDR": add `v3/client/search/findByClNr`, `v3/customerorder/search/findByExternalIdList`, `v3/customerorder/search/findByOrderbatchId`, `v3/customerorderBatch/search/findByBatchid`.
12. First reconciliation comment path "archive/SBDEV-3183-evidence/..." is wrong; use `4-Archieves/wms2/plan/SBDEV-3183-evidence/`. (Comment; low value to edit.)

## Not re-verified
PRD DB counts and PRD guard mode; UAT DBs; commit b12ff678 content; AC-3 live 405 probe; AC-6..AC-9; fix-cost estimates.
