---
title: "WMSv2 slice B tranche 1: gate the ungated state-changing MVC surface — 218 handlers are open, 84 of them mutate"
ticket: "SBDEV-3017"
ticket_url: "https://app.clickup.com/t/868kufdy1"
type: "feature"
priority: "high"
status: "🏁 SBDEV-3017 SCOPE CLOSED 2026-08-28 — ⚠️ §9.30: this plan's OMS enumeration (8 paths) was read from a checkout 838 commits STALE; the real number is 10 and OMS DOES write over SDR. The no-OMS-endpoint-was-gated conclusion still holds (both misses are SDR). — **READ §9.29 FIRST**. ClickUp status stays **`on dev`**, NOT `Closed`: the ladder here tracks deployment (on dev → on qa → ready for deployment → on prod) and tranche 1 has only reached dev. No scope remains in the ticket; it now just rides the promotion ladder. Class A (SDR) was never implemented and is now **SBDEV-3157**, carrying this ticket's unmet Class A AC verbatim; MVC reads widened into SBDEV-3142 (16 → 106); also spun out 3154/3155/3156. Surface moved 291→355 gated / 122→58 ungated. ✅ TRANCHE 1 MERGED TO DEVELOP 2026-08-28 — api `1f5f8697` (PR #232, commit `81989036`) then web-ui `e629517` (PR #95, `a10aca0`), API-first per §8.14.3, both landings verified with `merge-base --is-ancestor`. AC-1 closed **as originally written** (Nam 2026-08-28, option (a)); the 10 state-changing GETs are SBDEV-3155. 🟢 was: TRANCHE 1 PR SUBMITTED — **READ §9.25 FIRST**: 71 of 75 rows gated, **PR #232 MERGED** `1f5f8697` (api, `81989036`) + **web-ui PR #95** (`a10aca0`), merge API first. Suite 5693/0/67; 11 mutants killed; THREE review rounds, 1 High/10 Med/12 Low ALL FIXED (§9.26-§9.27 — each round found my previous fix fenced ONE gate mechanism and missed its siblings; there are six, seven with the SecurityFilterChain). C30–C33 split to SBDEV-3154. ⚠️ AC-1 closes only as ORIGINALLY written — 10 state-changing GETs (`runClubLine`, `runTransfer`, …) are in no total and the AC-4 tool cannot see them. Everything before §9.25 is revision history. 🔴 DRAFT — 📍 **READ §9 FIRST for what is done and what remains** (added 2026-08-26); everything below is narrative revision history, not state. ✅ **R8 SHIPPED (§9.19/§9.20)** — PR #219 merged `e7a37f4e` (api) then #88 merged `aa8ad6bc` (web-ui), in the §8.14.3 order, each after an independent review lane that BLOCKED it and whose findings were fixed. 4 controller handlers now on functions, 3 service restrictions LIFTED, so the sb_admin denominator drops 20 -> 17 and the move/stay framing is retired (13 stay / 4 on functions / 3 relocated). Prior state: 0 of 7 moved (split revised to 9 move / 11 stay on 2026-08-27, §9.15 — fourth revision; re-derive from source, never edit the label alone). Done on develop: slice A (#187), slice C (#189), §8.12.1 UserFunction SDR write withdrawal (#209). R1 grant check DONE (51/51, §9.6) and R2 lane-table re-read DONE (§9.7) — 6 findings between them, all decisions for R8. R4 DONE (§9.8, PR #210) and R3 DONE (§9.9). All four blocking analysis items closed (R1 §9.6, R2 §9.7, R3 §9.9, R4 §9.8/PR #210). R5 DECIDED §9.10 (ANY-of, FOUR members) and R6 DECIDED §9.11 (2 dead endpoints -> deletion, needs Nam's yes). R6 SHIPPED (PR #211, merge 38861ad7, TWO review lanes). §9.14/§9.15 SHIPPED (PR #214, merge 23cdc6ad, THREE lanes — the first BLOCKED it): all six of Nam's 2026-08-27 decisions are implemented, the split is 9 move / 11 stay, and the tripwire pins ELEVEN carve-outs verified as a SET against the stay-list. R8 (implementation, T3) is next. Its putaway gating is DECIDED (§9.16, Option B — screen VIEW functions, ZERO new constants, F4 superseded). SCOPE DECIDED (§9.17): R8 = the 7 putaway sites ONLY (§9.18: AdminController moves NOTHING); §1's ~97 rows are a separate slice. Consequence — **zero new constants, NO V2.2.22 migration, and the tier drops T3 -> T2**. One question remains open (§9.17.2): whether AdminController:107/:133 follow decisions 1-2 onto sb_admin, which it did — §9.18, split 7 move / 13 stay — 44 of 62 SDR repositories have live write verbs and only the 7 access-chain types are withdrawn. R7 FILED as SBDEV-3124 (§9.13) and is OUT of this ticket. R1-R7 all closed; R8 is the only remaining work and its SCOPE is an open decision (§9.13.1), not a default. — **§8.16 ADDED 2026-08-26: TWO OF THE 17 SITES CANNOT BE FUNCTION-GATED BY ANNOTATION AT ALL.** `PutawayConfigService:257` (`validateOnly`) and `:287` (`requireWarehouseConfigWriteAuthority`) are invoked from `@HandleBefore*` SDR event handlers, and `FunctionGuardInterceptor` resolves `@RequiresFunction` from the MVC handler's declaring class — which for an SDR write is `RepositoryEntityController`, never the service (its own javadoc, `:41` and `:87-92`). An annotation swap there **compiles, keeps SBDEV-3103's 8 mutants green (they assert the handler CALLS the method, and `:287`'s body is empty), and silently reverts SBDEV-3103's security fix** — `PATCH /v3/sysprop/{id} {"workstation":"WS1"}` works again for any `wms_user`. No lane in this repo can see it. Second reason not to move them: a function grant is self-grantable while `UserFunctionRepository`'s SDR write is open, whereas `sb_admin` arrives as a bare client role in `resource_access[om1-api]` that no `wms_user` can write — so the swap trades an unforgeable gate for a forgeable one. ✅ **DECIDED 2026-08-26 (Nam): option (a) — CARVE THEM OUT.** `PutawayConfigService:257` and `:287` stay on `@PreAuthorize(IS_SB_ADMIN)`, joining the other three, so the split was **15 move / 5 stay**. An earlier revision of this status recorded (b); Nam reversed it after a written comparison — *"I changed my mind after hearing your peer's explanation. I will go (a)."* (b)'s spec is retained as CONDITIONAL in §8.16.5a and must not be implemented from. The reason (b) lost is in §8.16.6: a function grant is self-grantable while `UserFunctionRepository`'s SDR write is open, whereas `sb_admin` arrives as a bare client role no `wms_user` can write — so (b) would have traded an unforgeable gate for a forgeable one and re-opened SBDEV-3103's bypass. 🚫 **RETIRED — option (b), do NOT implement. Retained only in §8.16.5a as CONDITIONAL.** (b) would have gated `:257`/`:287` programmatically via `accessService.doesUserHaveAccess(WEB_UI_ACTION_SET_PUTAWAY_DESTINATION_DEFAULTS)` in the method body and kept the split at 17/3. It was rejected: it trades an unforgeable gate for a forgeable one while `UserFunctionRepository`'s SDR write is open, and it needs SBDEV-3103's tests rewritten to assert the CHECK rather than the CALL because `:287`'s body stops being empty. **The split is now **9 move / 11 stay** (§9.14, 2026-08-27) — it passed through 17/3 and 15/5.** An earlier revision of this status field left (b)'s "Split stays 17/3" asserted OUTSIDE its strikethrough, contradicting the 15/5 decision recorded earlier in this same field. — **§8.13 SUPERSEDED SAME DAY 2026-08-26 by §8.15 — Nam's clarified decision: Keycloak carries COARSE access only (every user gets `wms_user`, nothing more) and ALL fine-grained authz lives in WMS V2's group→role→function model, with WMS admins in the `super-admin` group. So no business endpoint may gate on `wms_admin` OR `sb_admin`: §8.13's disjunction is RETIRED and §8.11's function-gate design is REINSTATED. This also RESOLVES §8.14's blocking B1 in the reviewers' favour — the axis mismatch B1 identified is exactly what the clarified decision removes. Measured on `dev_wh01_om1`: `super-admin` group = 38 users, its role holds 79 of 82 functions, and `wms_admin` is NEITHER a mywms_role NOR a mywms_group (0/0) — a cross-axis migration, never a rename. Audit: `3-Resources/reports/260826-wms-admin-to-super-admin-authz-axis-audit.md`. §8.13 retained below for its SURFACE census and the review trail ONLY — DO NOT IMPLEMENT ITS MECHANISM.** Prior §8.13 note: putaway config moves to a `wms_admin` OR `sb_admin` disjunction, NOT to a function — Nam's decision, superseding §8.11's mechanism (its surface census survives) and §8.12's F4 split (moot). Reason it is not the function gate: `FunctionGuardInterceptor` is ABSENT from `origin/main` (develop +112), so `@RequiresFunction` would be inert and replacing `@PreAuthorize` un-gates 4 prd endpoints; and function grants stay self-grantable per §8.12.1. OR not swap, because `wms_admin`-only would REGRESS staff, who hold `sb_admin` and are the only current users. Also supersedes the in-code prohibition at `Authority.java:53-61` and falsifies role-matrix §1.1 line 94 — both must change in the same PR (§8.13.5). §8.13.4's precondition is now ANSWERED (2026-08-26) and was WRONG: the mapper emits FULL PATHS (`/wms_admin`), which match nothing — every gate passes because Keycloak also emits each group as a BARE client role on `om1-api`, and that is what `hasAuthority()` matches. **Do NOT "fix" the mapper to emit bare names.** The probe is a password grant + JWT decode, not `curl /actuator/env` (which is not an exposed endpoint and 404s after passing the authority check). T3. **§8.14 — REVIEWED 2026-08-26 in 3 lanes (evidence/security/design): 9 High, 7 Medium, 4 Low; 6 corrections applied in place. TWO BLOCKING. B1: the widening CANNOT DELIVER ITS OWN GOAL alone — the web UI gates the screen on FUNCTIONS (`require-function.js`, `WEB_UI_VIEW_ITEM_DATA` / `_SYSTEM_PROPERTY` / `_CLIENT`), and `wms_admin` confers ZERO functions, so a wms_admin outside super-admin/inventory-manager is redirected BEFORE any request reaches the widened @PreAuthorize; role-matrix §1.1 also names `super-admin` (a tenant-DB UserRole), a DIFFERENT AXIS, and under OR-semantics a wrong population guess is SILENT — all 9 ACs pass while the target user stays locked out. Needs a Keycloak group enumeration + owner confirmation before any code. B2: the surface is NOT staff-only today — a plain `wms_user` can silently remove the tier-3 default, unaudited, by RENAMING the guarded syskey over SDR (`PATCH /v3/sysprop/{id}`), because both hooks branch on the merged incoming entity; pre-existing, needs its own ticket. Also: NO test lane in this repo evaluates @PreAuthorize, so AC-1..AC-4/AC-7 as written are unachievable (§8.14.4), and @PreAuthorize 403s miss `X-Authz-Denied` so they hit the silent-no-op/logout path — merge API BEFORE web-ui. One review finding was itself FALSE (§8.14.6, a working-tree grep 29 commits stale). DO NOT IMPLEMENT.** REVISED three times (§8 2026-08-24, §8.11 + §8.12 2026-08-25), still DO NOT IMPLEMENT. Reviewed by 3 lanes 2026-08-24: 8 High / 13 Medium; §8 supersedes the sections it names and resolves the Highs on paper. **Now RE-SEQUENCED: §8.9 recommends Class A (SDR) leads slice B, not this MVC tranche** — measured, every tranche-1 entity keeps a live un-withdrawn SDR write verb, so ~19 of ~92 rows gate nothing real, and the live escalation path found in that same surface is now SBDEV-3077 / wms2-api PR #191. Corrections in §8: the tote-printing OUTAGE (§8.2, named-role intersection = super-admin alone); §2.2's GUARDED ban was right for the WRONG reason and @PublicHandler (SBDEV-3063, merged d83b72a) makes membership the correct END state for tranche 3 (§8.3); §2.3 broke the sb_admin tool and gated accessAudit, its own rollout instrument (§8.4); AC-2/T-3 replaced by the screen-reachability invariant AC-2′ (§8.5); the census missed ClubLineController / TransfersController / setPutAwayLocation and AC-1 rewritten to the boundary (§8.6); every count corrected (§8.7); the closeBolPop headline example is FALSE and acceptHubAndSpokeBol has one mapping so a third of T-4 passed vacuously (§8.8). §8.10 lists 6 items still blocking implementation, chief among them re-running the grant check on the ~56 rows that never had it. SOUND throughout: state-change-over-verb scoping (conclusion), all 6 deletions, the Flyway two-separate-INSERTs rule, the mechanism claims, the OMS exclusion SET, T3, V2.2.22. Reviews: scratchpad/review-planB1-{design,evidence,security}.md. **WIDENED 2026-08-25 (§8.11)** — the putaway-destination write surface (4 endpoints + 5 service writers) joins this tranche by Nam's decision, moving off `sb_admin` onto a new `WEB_UI_ACTION_SET_PUTAWAY_DESTINATION` granted to super-admin + inventory-manager. Three things came with it: §8.6's row for `setPutAwayLocation` is CORRECTED (it is NOT ungated — `@PreAuthorize(IS_SB_ADMIN)` at ItemDataController:105); row 31's self-grant objection has largely EXPIRED (all five access-chain join repos now `exported = false`, `saveUserGroups` gated, SDR inside the guard) but leaves `UserFunctionRepository` SDR-exported by default, which is a rename-shaped hole and a PREREQUISITE; and a MERGE-ORDER CONSTRAINT — `FunctionGuardInterceptor` is absent from `main`, so dropping `@PreAuthorize` before it reaches prd un-gates 4 production endpoints. **§8.12 — §8.11 WAS THEN REVIEWED (it had been posted to ClickUp with NO review lane) and 4 High found, 2 of them false claims already published: the "five join repos are `exported = false`" bullet was a method-level grep read as class-level (the conclusion survives via `RestConfiguration` ExposureConfiguration, but narrower — `PUT /v3/userGroup/{id}` and `POST /v3/userGroup` stay live), and "SDR is now inside the gate" is the OPPOSITE of `FunctionGuardInterceptor:87-92` ("it is reachable, and still open"). Both corrected in place. F3: the surface omitted the `PutawayConfigRepositoryEventHandler` SDR channel (`/v3/itemData`, `/v3/client`, `/v3/sysprop`), which CANNOT take `@RequiresFunction`. F4: ONE function is a privilege EXPANSION — tiers 2/3 sit behind super-admin-only view gates while inventory-manager would reach 11 users; SPLIT into `_SKU` and `_DEFAULTS`. F5: §8.6's table is wrong on TWO of seven rows. `UserFunctionRepository`'s open SDR write is a SLICE-WIDE blocker defeating every function gate, not a putaway prerequisite."
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-24
updated: 2026-08-28
db_verified: true
db_verified_rationale: "mywms_function eight-column shape and its PK/UNIQUE constraints verified against information_schema and pg_constraint on wms2-wineco-dev 2026-08-24 (§2.4). Function grant populations queried per constant (§1.3)."
related:
  - SBDEV-2967-C-web-action-gating.md
  - SBDEV-2967-B-web-view-gating.md
  - SBDEV-2968-mobile-ui-function-gating-enforcement.md
  - 260520-rest-security-permitall-hardening.md
tags:
  - plan
  - security
  - authorization
  - spring-security
---

# SBDEV-3017 slice B tranche 1 — the ungated state-changing MVC surface

**Ticket:** [SBDEV-3017](https://app.clickup.com/t/868kufdy1)
**Project:** wms2 | **Version:** v2 | **Type:** feature
**Priority:** high
**Status:** DRAFT
**Date:** 2026-08-24

---

## 0. The surface, and the three decisions that bound this tranche

Measured server-side on `develop@5b704e5` by reflecting over the source, **not** by grepping the UIs. Every
prior inventory on this ticket was client-side derived and every one was wrong in at least one direction.

| | count |
|---|---|
| SDR: exported repositories | 62 |
| SDR: exported `@RestResource` searches | 307 (+52 already `exported = false`) |
| MVC: total mapped handlers | 318 |
| MVC: **ungated** | **218** — 96 by verb-write, 122 by verb-read |
| MVC: ungated on a controller in `FunctionGuardInterceptor.GUARDED` | **0** — the fail-closed set has no gaps |

**525 endpoints** need a decision across the whole of slice B. This tranche takes ~84 of them.

### 0.A The three decisions (Nam, 2026-08-24)

1. **Key the rule per CLASS, not per endpoint** — 46 controllers + 62 repositories = 108 rules rather than 525,
   with explicit per-endpoint carve-outs where a class is genuinely mixed. **This supersedes the ticket's own
   AC** ("a decision recorded per endpoint, not one blanket rule"). Justification: the 81 existing
   `WEB_UI_*`/`MOBILE_UI_*` constants are already named per screen/subsystem, which maps to classes
   (`WEB_UI_VIEW_CLIENT` ↔ `ClientController`). A 525-row artefact would be the SBDEV-3011 failure mode
   (1142-line plan for <100 lines of logic) at 5× scale.
2. **Scope by STATE CHANGE, not by HTTP verb.** See §0.B — verb misclassifies ~23 of ~94 endpoints in both
   directions.
3. **Delete genuinely-dead endpoints rather than gating them** — revised down to 6 after cross-repo
   verification (§0.E).

### 0.B Why the scope is state-change and not verb

Verb is wrong in **both** directions:

- **Under-includes ~13 mutating GETs.** `GET /v3/advice/closeInboundBol/{id}`,
  `GET /v3/advice/acceptHubAndSpokeBol/{id}/{locationId}`, `GET /v3/billOfLading/closeOutboundBol/{id}`,
  `GET /v3/receiving/unlinkSelectedPallet/{palletName}`, `GET /v3/replenishOrder/cancelReplenishOrder/{id}`,
  plus seven more in the master-data controllers. These call `adviceService.closeInboundBol`,
  `billofladingService.finishTransfer` and friends — they mutate.
- **Over-includes 10 `/export*` POSTs that are reads.** They return files. Confirmed on all ten.

🔴 **The decisive case.** `closeBolPop.vue` picks GET-single vs POST-multi on `selectedItems.length` — one
button, two verbs. The same holds for `closeInboundBol` and `acceptHubAndSpokeBol`. Gating only the POST gives
the operator "select one row → works, select two → 403": not a partial fix but an *incoherent* one, and exactly
the `bulkTransferStock` shape that SBDEV-3017-C (PR #189) just closed. A verb-scoped tranche would rebuild the
gap it was created to remove — `bulkTransferStock` survived precisely because SBDEV-2968 gated `transferStock`
and the bulk twin fell between tranches under a deliberately-deferred R3c risk row.

Secondary: verb is not a reliable attribute here. `LocationController`'s four writes are **verb-inverted**
against their only callers (`@PostMapping("/create")` vs the UI's `$put`, etc.), so all four should be **405
today**. If verb decides scope, a later commit fixing those 405s silently converts four ungated paths into live
ungated writes.

**Boundary for this tranche:** every ungated endpoint whose handler mutates state, determined by reading the
handler body. ≈ 81 verb-writes − 10 export-reads + 13 mutating GETs ≈ **84**, across 23 controllers.

### 0.C 🔴 OMS is a first-class caller of `/v3/**`

Every earlier inventory on this ticket, including the first drafts of this one, assumed `/v3` meant "a UI calls
it". **False.** `v2/oms-laravel-api/app/Services/WmsFacilitySyncService.php`, reached by
`POST /api/facilities/{code}/wms-sync` → `SyncFacilityToWmsJob`, writes to WMS:

| OMS method | WMS endpoint | controller |
|---|---|---|
| `createClientAtFacility` (`:789`) | `POST /v3/client/create` | `ClientController` |
| `createBoxType` (`:834`) | `POST /v3/boxType/create` | `BoxTypeController` |
| `createShipperId` (`:1187`) | `POST /v3/shipperId/create` | `ShipperIdController` |

`WmsApiService.php:54-56` forwards the **end user's** Bearer token (`$request->header('Authorization')`), so a
function check on these evaluates against an *OMS* user who may hold no WMS function and may have no
`mywms_user` row at all → `USER_NOT_PROVISIONED` → **403**, and facility catalog sync fails.

It fails obscurely too: `WmsFacilitySyncService:1331` records that *"several WMS v3 create controllers (boxType,
client) catch their own errors and return HTTP 200 with a `{ errors: [...] }` body and NO status field"*, so OMS
already carries bespoke envelope-sniffing for that path. A 403 is a third shape again.

**Decision:** gate `ClientController` and `BoxTypeController` **per endpoint**, excluding `/create` on each.
Exclude `ShipperIdController` from this tranche entirely — both its writes are OMS-only, so nothing UI-facing
remains to gate; it belongs with `260520-rest-security-permitall-hardening`, which already owns "endpoints OMS
calls" and is blocked on OMS sending its own JWT.

### 0.D Two search blindspots that produced false findings

Both were caught by cross-checking lanes, not by the original sweep. Any remaining "dead" verdict on this
ticket is provisional until re-verified.

1. 🔴 **`v2/wms2-web-ui/.gitignore:106` is a bare `reports/`.** Gitignore matches that at any depth, so
   `store/reports/` (10 files), `components/reports/` (14) and `pages/reports/` (10) — all tracked and shipped
   — are skipped by every ignore-aware tool: ripgrep, ugrep, Claude Code's `Grep`, **and the `grep` shell
   function in this environment**, which wraps `ugrep -G --ignore-files`. Measured:
   `grep -rn "exportFlowbin" .` → nothing; `command grep -rn "exportFlowbin" .` → `store/reports/flowbin.js:87`.
   This produced "9 of 11 `ReportController` endpoints are dead" (all 11 are live) and a recommendation to
   **delete** `POST /v3/billOfLading/palletize`, which is live from `store/reports/outboundParcel.js:129`.
   **Use `command grep` for every caller inventory in that repo**, and exclude `coverage/lcov-report/`, which
   holds HTML copies of every component.
2. **Name-only greps manufacture the opposite error.** `setPallet` and `setSection` match Vuex *mutations* with
   the same identifier. Search the endpoint **path**, not the method name.

### 0.E The deletions — 6, revised down from 8

Verified across `wms2-web-ui`, `wms2-mobile-ui`, `oms-laravel-api` and v1, with GNU grep, on both the path and a
distinctive identifier. v1 hits are irrelevant: `v1/wms-api` is a separate deployment with its own controllers.

| endpoint | evidence |
|---|---|
| `POST /v3/receiving/setPallet` | 0 callers anywhere |
| `POST /v3/receiving/createAndSelectPallet` | 0; superseded by `createPallet` + the picker in `searchPallet.vue` |
| `POST /v3/replenishOrder/changeSourceStockUnit` | 0; the "change source" dialog posts to `/replenishOrder/updateStockUnit` |
| `POST /v3/billOfLading/setDestinationFacility` | 0; the UI sets destination at create time |
| `GET /v3/billOfLading/closeIntraCompanyTransfer/{id}` | 0; also a controller/feature mismatch — it calls `billofladingService.finishTransfer` |
| `POST /v3/client/setSection` | 0; the live path is SDR `PATCH /client/{id}` (`store/admin/shippers.js:57`) |

**Withdrawn from deletion:**

- `POST /v3/shipperId/create` — **OMS calls it** (§0.C). No screen uses it; the caller is another system.
- `POST /v3/advice/fixHubAndSpokePalletIssues` — no caller found, but hub-and-spoke is an OMS-driven flow
  (`createHubAndSpokeAdvice`), so an out-of-band support tool is plausible. **Gate, do not delete.**
- `POST /v3/billOfLading/palletize` — was reported dead; live from `store/reports/outboundParcel.js:129`
  (Outbound Parcel Report). Gate on `WEB_UI_VIEW_PARCEL_MONITOR`, **not** `MOBILE_UI_VIEW_PALLETIZING`.

### 0.F The constant map already exists — read it, do not derive it

`wms2-web-ui@origin/develop` carries `util/appMenuList.js` with **30 per-leaf `fn:` entries**, plus
`EXTRA_ROUTES` and `UNGATED_ROUTES`, pinned by `test/util/appMenuList.spec.js#everyPageOnDiskIsClassified`, and
a route guard `middleware/require-function.js` wired at `nuxt.config.js:57`.

⚠️ **Two mapping lanes reported "no function gating at all, no `middleware/` directory". That is false for
develop** — they read a local checkout 12 commits behind with no `middleware/` on disk. Consequences:

- The failure mode for a wrong constant is **not** an enabled button that 403s; the route guard fails closed and
  redirects to `/not-authorized`, so the whole **screen** becomes unreachable.
- Constants for this tranche must be taken from `appMenuList.js`. Diverging yields a screen that renders while
  its write button 403s, or the reverse.
- The two ANY-of cases are already declared there, e.g. Handling Units (row 11) is
  `['WEB_UI_VIEW_STOCK_UNIT', 'WEB_UI_VIEW_CONTAINER']`.
- `middleware/require-function.js`'s own header says *"SBDEV-3017 owns the server half and is not scheduled"*
  and repeats the "~14 of ~32 API roots are Spring Data REST and structurally unreachable" claim that slice A
  **disproved**. Correct that comment in this tranche.

`WEB_UI_VIEW_PARCEL_PICKING` **is** on the API develop and **is** seeded by `V2.2.19`, so `/exportParcelPicking`
needs no sequencing. (An earlier note here said it was absent; that was a `git ls-tree` missing `-r`.)

### 0.G The semantically-obvious constant is sometimes the wrong one

`POST /v3/goodsReceiptPosition/adjust` reads like a perfect match for `WEB_UI_ACTION_ADJUST_AMOUNT`. **It is
not.** Live grants for that constant are `inventory-manager` + `super-admin` (+2 numeric) and exclude
`receiving` and `CS-REP` — precisely the roles holding that screen. Gating on it 403s the receiving role on a
button it uses today. `WEB_UI_VIEW_GOODS_RECEIPT_POSITION` is granted to `CS-REP`, `receiving`, `super-admin`.

**Every row must be checked against live grants, not against the constant's name.**

### 0.H Structural landmines

- 🔴 **Never annotate `AdminController`.** It declares 9 mappings of its own (`/v3/user/**` ×7,
  `/v3/admin/importUsersFromCsvText`, `/v3/groups/findGroup`) **and is the base class of 43 controllers**, so its
  methods register under all 43 prefixes. A class-level annotation there gates 43 controllers at once.
- **`DashboardController extends ReportController`**, so ~15 `/v3/report/*` handlers have live
  `/v3/dashboard/*` aliases. Not a gate split — the interceptor resolves
  `handlerMethod.getMethod().getDeclaringClass()` — but any table, test or verify row pinning only
  `/v3/report/...` is incomplete. Per this repo's rule, only a curl proves a mapping.
- **`ReplenishOrderController` is the only both-UI controller in the tranche**; a class-level gate there breaks
  mobile Replenish. `CustomerOrderController` serves **three different screens** from one class. Both take
  per-endpoint treatment. Conversely `FixLocationAssignmentController` is web-only — SBDEV-2968 moved the mobile
  *read* off it and none of its six writes is mobile-driven.
- **SDR co-exists with every row.** For `client` edit, `sysprop` edit/delete and `section` delete the web UI's
  **live** write path is already the SDR route, so gating the MVC controller closes nothing on those paths.
  Those belong to tranche 2/3. Do not describe this tranche as closing those capabilities.

### 0.I Evidence base

Three parallel mapping lanes, each enumerating callers with untruncated greps and tracing store action →
component → route → menu entry. Their full tables are reproduced in §1 verbatim, attributed, because they carry
the per-row file:line evidence this plan's design rests on.

---

## 1. The mapping tables (lane output, verbatim)


### 1.1 Exports, printing and dashboard

> Lane output, unedited. Attribution matters: these carry the file:line caller evidence.


Repo state: `v2/wms2-api` @ `origin/develop`; UI callers from `v2/wms2-web-ui` @ `develop` (99e2359) and
`v2/wms2-mobile-ui`. All greps run with `command grep -rn` (real GNU grep) — see LANDMINE 1, which invalidated
a first pass of this whole table.

---

#### READ THIS FIRST — three findings that change the decision

##### LANDMINE 1 — an ignore-aware grep reports ZERO callers for all ten `/report/export*` endpoints. It is wrong.

`wms2-web-ui/.gitignore` contains a bare `reports/` line (added for `cypress/reports`). Gitignore semantics
match that against **any directory named `reports` at any depth**, so it swallows:

- `wms2-web-ui/store/reports/` (10 files)
- `wms2-web-ui/components/reports/` (14 files)
- `wms2-web-ui/pages/reports/` (10 files)

All 34 files are **tracked in git and shipped** (`git ls-files store/reports components/reports pages/reports`
lists them; git itself honours the index over the pattern). But every ignore-aware search tool skips them —
ripgrep, ugrep, Claude Code's `Grep` tool, and the `grep` **shell function** in this environment, which is a
wrapper around `ugrep -G --ignore-files ...`. Measured:

```
$ grep -rn "exportFlowbin" .            # ugrep wrapper  -> rc=1, no output
$ command grep -rn "exportFlowbin" .    # GNU grep       -> store/reports/flowbin.js:87
```

My first sweep therefore concluded "9 of 11 ReportController endpoints are dead surface". **That was false.**
Every one has a live app caller. Use `command grep` for any caller inventory in this repo, and treat a
"0 callers" result on a `reports/`-adjacent path as unproven until re-run with GNU grep.

##### LANDMINE 2 — `DashboardController extends ReportController`, so every `/v3/report/*` handler has a `/v3/dashboard/*` alias

`DashboardController.java:25`. Spring registers inherited handler methods under the subclass's class-level
`@RequestMapping`, so `/v3/dashboard/exportInventory`, `/v3/dashboard/reprintLabels`,
`/v3/dashboard/parcelMonitorView`, … are live URLs (~15 aliases).

This is **not** a gate-split hazard: `FunctionGuardInterceptor` resolves on
`handlerMethod.getMethod().getDeclaringClass()` (`FunctionGuardInterceptor.java:120`), which is
`ReportController` for the aliased copies, so one annotation covers both prefixes. But any verify row, test, or
plan table that pins only `/v3/report/...` is **incomplete**, and per this repo's own rule only a curl proves a
mapping — confirm the aliases with curl rather than asserting them.

##### FINDING 3 — the constant map for these screens ALREADY EXISTS on a sibling branch, and my recommendations match it

`bugfix/SBDEV-2967-B-web-view-gating` rewrote `wms2-web-ui/util/appMenuList.js` into "the single source of truth
for which screen needs which function" — one `MENU` list where every leaf carries `fn`, plus `EXTRA_ROUTES` and
`UNGATED_ROUTES`, pinned by `test/util/appMenuList.spec.js#everyPageOnDiskIsClassified`, and enforced by a new
`middleware/require-function.js`. Rows 21–29 are exactly the Reports screens in this tranche.

**Every VIEW constant below is taken from that file, not inferred.** Diverging from it would produce a screen
that renders but whose export button 403s (or the reverse).

Consequences:

- **`WEB_UI_VIEW_PARCEL_PICKING` does not exist on develop.** Slice B adds it
  (`WmsConstants.java:419` on that branch) and seeds it in `V2.2.19__seed_web_view_function_grants.sql`. That
  makes the develop count 81 → 82. `/exportParcelPicking` and `/report/reprintLabels` have **no develop
  constant**; tranche 1 either lands after slice B or carries the constant itself.
- Slice B records two refusals for that row worth honouring: do **not** reuse `WEB_UI_VIEW_PARCEL_MONITOR`
  ("would make two distinct screens share one gate") and do **not** use `WEB_UI_VIEW_ORDER_DETAIL_MONITOR`
  ("does back this row end-to-end, but is a badly-named constant we are replacing").
- **Label Printing and Printer Setup share one gate by decision**: slice B's Admin row 30 comment reads
  `'WEB_UI_VIEW_PRINTER', // Label Printing AND Printer Setup — one shared gate by decision`. That resolves what
  looked like a NO-FIT for `LabelPrintingController` (SBDEV-2861 postdates the 2023 constant seed).
- **No collision with slices B or C.** Neither branch annotates `ReportController`, `DashboardController`,
  `LabelPrintingController`, nor `UnitLoadController.reprintLabel`. Slice C annotates only
  `UnitLoadController.deleteContainer` / `.bulkDeleteContainer` (`:90`, `:121`) and the `StockUnitController`
  adjust/lock actions. All 17 endpoints here are genuinely unclaimed.

---

#### The table

`store/…` rows are the axios call site; the `←` chain is the dispatch path to the component and page. Cypress /
Jest hits are labelled **(test)** and are not app callers.

| # | Endpoint (POST) | Every caller — untruncated GNU grep, both UI repos | Screen | Recommended constant | Confidence | Rationale |
|---|---|---|---|---|---|---|
| 1 | `/v3/report/exportInventory` | `wms2-web-ui/store/reports/inventory.js:94` ← `components/reports/popups/exportReport.vue:147` ← `components/reports/inventoryReport.vue:338` (`reportType='Inventory'`) ← `pages/reports/inventory-report.vue:6`. **0 mobile callers.** | Reports → Inventory Report (`/reports/inventory-report`) | `WEB_UI_VIEW_INVENTORY_RECORD` | **certain** | Slice B MENU row 21. Export reads `StockView` via `stockViewRepository.findByClientOffsetAndLimit` (`ReportService.java:79`); the screen reads `/stockView/search/findByKeyword` (`store/reports/inventory.js:69`) — same view. Nothing else in either UI claims this constant (`inventoryRecord` has zero UI callers). |
| 2 | `/v3/report/exportLock` | `store/reports/lock.js:93` ← `exportReport.vue:149` ← `components/reports/lockReport.vue:367` ← `pages/reports/lock-report.vue:6` | Reports → Lock Report | `WEB_UI_VIEW_STOCK_UNIT_LOCK_OVERVIEW` | **certain** | Slice B MENU row 22. Export reads `lockOverviewDtoView` / `lockOverviewAllDtoView` (`ReportService.java:127-129`), exactly the two resources the screen reads (`store/reports/lock.js:57,64`), incl. the SBDEV-2474 `includeShipped` toggle. |
| 3 | `/v3/report/exportReceiving` | **Two callers.** `store/reports/receiving.js:86` ← `exportReport.vue:151` ← `components/reports/receivingReport.vue:356` ← `pages/reports/receiving-report.vue:6`. **And** `store/reports/data.js:48` ← `exportReport.vue:165` ← `components/reports/dataReport.vue:212` ← `pages/reports/data-report.vue:6` | Reports → Receiving Report; **plus** Reports → Data Report | `WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW` | **certain** | Slice B MENU row 23. Both callers read `receivingDtoView` (`ReportService.java:171`; stores `:61` / `:26`) — one function, no ANY-of needed. Data Report is already menu-unreachable on develop (commented out in all five personas, `util/appMenuList.js:187,350,436,540`) and slice B **deletes** `pages/reports/data-report.vue` + `components/reports/dataReport.vue`, orphaning `store/reports/data.js`. |
| 4 | `/v3/report/exportSkuLocation` | `store/reports/skuLocation.js:86` ← `exportReport.vue:153` ← `components/reports/skuLocationReport.vue:314` ← `pages/reports/sku-location-report.vue:6` | Reports → SKU Location Report | `WEB_UI_VIEW_LOCATION_OVERVIEW` | **certain** | Slice B MENU row 24. Export reads `ViewWarehouseLocationReport` (`ReportService.java:205`); screen reads `/viewWarehouseLocationReport/search/findByKeyword` (`store:61`). |
| 5 | `/v3/report/exportFlowbin` | `store/reports/flowbin.js:87` ← `exportReport.vue:155` ← `components/reports/flowbinReport.vue:336` ← `pages/reports/flowbin-report.vue:6` | Reports → Flowbin Report | `WEB_UI_VIEW_FLOWBIN_MONITOR` | **certain** | Slice B MENU row 25. Export reads `FlowbinMonitorView` (`ReportService.java:243`); screen reads `/report/flowbinMonitorView` → same repo (`ViewDtoService.java:1298`). |
| 6 | `/v3/report/exportParcelPicking` | `store/reports/parcelPicking.js:90` ← `exportReport.vue:157` ← `components/reports/parcelPickingReport.vue:411` ← `pages/reports/parcel-picking-report.vue:6` | Reports → Parcel Picking Report | `WEB_UI_VIEW_PARCEL_PICKING` — **NOT on develop** (slice B adds it) | **certain, but blocked** | Slice B MENU row 26, the one leaf of thirty with no pre-existing constant. Export reads `OrderDetailMonitorView` (`ReportService.java:284`); screen reads `/report/parcelPickingView` → `orderDetailMonitorViewRepository` (`ViewDtoService.java:1332`). Sequence after slice B, or carry the constant + a grant. Do **not** substitute `PARCEL_MONITOR` or `ORDER_DETAIL_MONITOR` (both explicitly refused by slice B). |
| 7 | `/v3/report/exportOutboundParcel` | `store/reports/outboundParcel.js:103` ← `exportReport.vue:159` ← `components/reports/outboundParcelReport.vue:388` ← `pages/reports/outbound-parcel-report.vue:6` | Reports → Outbound Parcel Report | `WEB_UI_VIEW_PARCEL_MONITOR` | **certain** | Slice B MENU row 27. Export reads `ParcelMonitorView` (`ReportService.java:319`); screen reads `/report/parcelMonitorView` → same repo (`ViewDtoService.java:1376`). |
| 8 | `/v3/report/exportStockUnitRecord` | `store/reports/stockUnit.js:73` ← `exportReport.vue:161` ← `components/reports/stockUnitRecord.vue:285` ← `pages/reports/stock-unit-record.vue:6`. Also linked from `components/layout_components/NotificationNav.vue:74` (navigation to the screen, not a call). | Reports → Stock Unit Record | `WEB_UI_VIEW_STOCK_UNIT_RECORD` | **certain** | Slice B MENU row 28. Export reads `Stockrecord` (`ReportService.java:352`); screen reads `/stockrecord/search/findByKeyword` (`store:51`). |
| 9 | `/v3/report/exportContainerRecord` | `store/reports/container.js:71` ← `exportReport.vue:163` ← `components/reports/containerRecord.vue:273` ← `pages/reports/container-record.vue:6` | Reports → Container Record | `WEB_UI_VIEW_UNIT_LOAD_RECORD` | **certain** | Slice B MENU row 29. Export reads `UnitloadRecord` (`ReportService.java:398`); screen reads `/unitloadRecord/search/findByKeyword` (`store:49`). **Not** `WEB_UI_VIEW_CONTAINER` — that one gates Handling Units (slice B row 11). |
| 10 | `/v3/report/reprintLabels` | `store/reports/parcelPicking.js:128` ← `components/reports/popups/reprintToteLabel.vue:70` ← mounted **only** on `components/reports/parcelPickingReport.vue:157,189,196` ← `pages/reports/parcel-picking-report.vue:6`. Printer list from `store/reports/parcelPicking.js:116`. | Reports → Parcel Picking Report (reprint-tote-label popup) | `WEB_UI_ACTION_PRINT_TOTE_LABELS` | **probable** | This is a genuine **write** (`orderMonitorDtoService.reprintToteLabels`, `ReportController.java:317`), not an export, and the existing action constant names the operation exactly. Caveat: it is not the screen gate, so a role holding `WEB_UI_VIEW_PARCEL_PICKING` without the action constant gets an enabled button that 403s. If the tranche will not write the extra grant, gate on `WEB_UI_VIEW_PARCEL_PICKING` instead and lose the action distinction. |
| 11 | `/v3/report/exportStorageLocations` | `store/masterData/storageLocation.js:94` ← `components/masterData/location/storageLocations/storageLocation.vue:314` ← `pages/masterData/locationData/storage-locations.vue` | Master Data → Location Data → Storage Locations | `WEB_UI_VIEW_STORAGE_LOCATION` | **certain** | Slice B MENU row 12. Reads `locationRepository.exportStorageLocations()` (`ReportService.java:430`) — the same location table the screen lists. Note this handler ignores its request body entirely (offset/limit/filter/keyword are commented out, `ReportController.java:405-408`) and returns every storage location. |
| 12 | `/v3/dashboard/printToteLabels` | `store/dashboard/pickpackMonitor.js:144` ← `components/homepage/pickPackMonitor/printerPop.vue:93` ← opened from `components/homepage/pickPackMonitor/tables/zoneViewTable.vue:379-381` and `tables/shipperBrandTable.vue:378-380` ← `pages/dashboard/index.vue:12,18` | Dashboard → Pick & Pack monitor (zone view / shipper-brand tables) | `WEB_UI_ACTION_PRINT_TOTE_LABELS` | **certain** | The only web ACTION constant about printing, and its name is this endpoint. Declared on `DashboardController` only (no `/v3/report` alias for this one). Screen gate `WEB_UI_VIEW_ORDER_MONITOR` (slice B MENU row 1) is the fallback if the team prefers screen-level. Grant note below. |
| 13 | `/v3/labelPrinting/totes/generate` | `store/admin/labelPrinting.js:274` (via the shared `print` action, `:256`) ← `components/admin/labelPrinting/toteLabels.vue:372` ← `components/admin/labelPrinting/labelPrintingMain.vue` ← `pages/admin.vue:26,47` (tab "Label Printing"). **(test)** `test/store/admin/labelPrinting.spec.js:37,58,80` | Admin → Label Printing tab → Tote Labels pane | `WEB_UI_VIEW_PRINTER` | **certain** | Slice B Admin row 30 assigns `WEB_UI_VIEW_PRINTER` to "Label Printing AND Printer Setup — one shared gate by decision". Mints new tote identity rows, so a stricter deployment could split out `WEB_UI_ACTION_GENERATE_TOTE_LABELS`; not recommended for tranche 1. |
| 14 | `/v3/labelPrinting/totes/reprint` | `store/admin/labelPrinting.js:282` ← `components/admin/labelPrinting/toteLabels.vue:390`. **(test)** `test/components/admin/labelPrinting/toteLabels.spec.js:86` | Admin → Label Printing → Tote Labels | `WEB_UI_VIEW_PRINTER` | **certain** | Same tab, same gate. Note it does the same job as row 10 from a different screen — deliberately a different constant, because the audiences differ (Admin tab vs Parcel Picking Report). |
| 15 | `/v3/labelPrinting/locations/print` | `store/admin/labelPrinting.js:290` ← `components/admin/labelPrinting/locationLabels.vue:391`. **(test)** `test/store/admin/labelPrinting.spec.js:93`, `test/components/admin/labelPrinting/locationLabels.spec.js:136` | Admin → Label Printing → Location Labels | `WEB_UI_VIEW_PRINTER` | **certain** | Same tab. |
| 16 | `/v3/labelPrinting/unitLoads/reprint` | `store/admin/labelPrinting.js:298` ← `components/admin/labelPrinting/unitLoadLabels.vue:165` | Admin → Label Printing → Unit Load Labels | `WEB_UI_VIEW_PRINTER` | **certain** | Same tab. Same operation as row 17 from a different screen; keeping them on different constants is intentional — see row 17's alternative. |
| 17 | `/v3/unitLoad/reprintLabel` | `store/handlingUnits/container.js:142` ← `components/handlingUnits/popups/reprentLabel.vue:64`, which is mounted on **three** screens: (a) `components/handlingUnits/containerTable.vue:67,87,321,324` ← `pages/handlingUnits/handling-units.vue:29`; (b) `components/processes/clubRuns/tabTables/inventoryOnLaneTable.vue:67,74,81,182` ← `clubRunDetails.vue:77,83` ← `pages/processes/club-fulfillment.vue:17`; (c) `components/processes/transferPicking/tabTables/inventoryOnLane.vue:67,74,81,183` ← `transferPickingDetails.vue:68,72` ← `pages/processes/transfer-fulfillment.vue:17` | Handling Units → Containers; Processes → Club Fulfillment (Inventory-on-Lane tab); Processes → Transfer Fulfillment (Inventory-on-Lane tab) | **ANY-of** `{WEB_UI_VIEW_CONTAINER, WEB_UI_VIEW_CLUB_LINE, WEB_UI_VIEW_TRANSFER_ORDER}` | **probable** | Three screens, three slice-B functions: Handling Units row 11 is itself ANY-of `[STOCK_UNIT, CONTAINER]` and slice B's own comment says the `container.js` half is the one reading `/unitLoad`, so `CONTAINER` is the right half; `EXTRA_ROUTES['/processes/club-fulfillment'] = WEB_UI_VIEW_CLUB_LINE` and `['/processes/transfer-fulfillment'] = WEB_UI_VIEW_TRANSFER_ORDER`. A single constant would 403 the button on two of the three screens. **Alternative (cleaner, needs a new constant):** `WEB_UI_ACTION_REPRINT_UNIT_LOAD_LABEL` — convention-compliant (`WEB_UI_ACTION_<VERB>_<NOUN>`), one gate for one cross-screen privileged action, and it would also cover row 16. Costs a constant + grants to the union of the three audiences. **Must be METHOD-level:** `UnitLoadController` extends `AdminController`, carries ~10 handlers serving both UIs, and slice C already gates only two of its methods; a class-level annotation would fail-closed the whole controller. |

##### Endpoints with zero app callers

**None.** All 17 have at least one live web-UI caller. The "dead surface" reading is purely an artefact of
LANDMINE 1 — do not act on it.

##### Mobile axis

**Zero mobile callers for all 17 endpoints.** Untruncated GNU grep over `wms2-mobile-ui` for
`/report/`, `labelPrinting`, `reprint`, `printTote`, `unitLoad/`, and each endpoint's leaf name returns only
`util/replenishUnitLoads.js:18` and `tests/e2e/replenish.spec.ts` (45/89/162/289/344/493), all of which hit the
SDR query `/unitLoad/search/findByItemForReplenish` — a different endpoint, and one this mechanism cannot gate
anyway (SDR bypasses the interceptor). **No ANY-of set in this tranche needs a `MOBILE_UI_*` member.**

---

#### Your `/export*`-is-a-read hypothesis: CONFIRMED, all ten

Every `/export*` handler is a `POST` whose only effect is streaming a file, and in every case it reads the
**same repository/view the screen it lives on reads** — the evidence pairs are in the Rationale column
(`ReportService.java` line vs `store/reports/*.js` line). So gating each on its screen's VIEW function is
correct and is not under-gating: a caller who may see the screen may already see the same rows through the
screen's own SDR/GET path. No `/export*` endpoint in this tranche writes anything.

Two endpoints in the list are **not** exports and should not be reasoned about this way:
`/v3/report/reprintLabels` (row 10) and `/v3/dashboard/printToteLabels` (row 12) send jobs to a physical
printer, and `/v3/labelPrinting/totes/generate` (row 13) additionally mints new tote identities.

---

#### Grant-migration warnings for whoever implements this

1. **On develop the web UI has no function gating at all.** There is no `wms2-web-ui/middleware/` directory;
   `util/appMenuList.js` is keyed by five hardcoded persona strings and `layouts/default.vue:259` reads only
   `menuList["super-admin"]` — slice B's own header records that the other four keys "were a fossil of a filter
   that was designed and never wired". So **every** constant in this table creates a brand-new access
   requirement. Without a matching grant row the button stays enabled and 403s.
2. **The 403 is invisible to the operator until slice A lands.** Each store's catch block shows the same
   generic toast — `store/reports/*.js`, `store/masterData/storageLocation.js:97`,
   `store/handlingUnits/container.js:152`, `store/dashboard/pickpackMonitor.js:157`: *"Error: Request failed due
   to a network or server issue. Please retry."* `store/admin/labelPrinting.js` is the only one that surfaces a
   server detail (`detailOf(error)`). `bugfix/SBDEV-2967-A-axios-403-denial-not-logout` is the branch that fixes
   this.
3. **Slice B's `V2.2.19__seed_web_view_function_grants.sql` already seeds the VIEW grants** for rows 1–9, 11
   and the Admin tabs. Tranche 1 needs its own `V2.2.x` only for `WEB_UI_ACTION_PRINT_TOTE_LABELS` (rows 10, 12)
   and any new constant it introduces (row 17's alternative). Run
   `wms2-api .../check-migration-version-collision.sh` immediately before merge — a point-in-time sweep cannot
   see a branch pushed later.
4. **`WEB_UI_ACTION_PRINT_TOTE_LABELS` is enforced nowhere today and effectively ungranted.** It is seeded as
   `mywms_function` id 565 (`V2.2.00__base_v2_schema.sql:2804`) and its only code reference is
   `UtilRestController.java:413`, a class annotated **`@Service`** (line 23), not `@RestController` — so that
   grant helper never routes and never runs. Treat the function as held by nobody and grant it explicitly.
5. **Which roles reach which screen, on develop** (from the five persona menus, for sizing the grant set —
   superseded by slice B's single menu, but it is the only role→screen evidence that exists):

   | screen | super-admin | inventory-manager | outbound-manager | outbound-manager,receiving | receiving |
   |---|---|---|---|---|---|
   | Inventory Report | Y | Y | Y | Y | Y |
   | Lock Report | Y | Y | – | – | – |
   | Receiving Report | Y | Y | – | Y | Y |
   | SKU Location Report | Y | Y | Y | Y | Y |
   | Flowbin Report | Y | Y | Y | Y | Y |
   | Parcel Picking Report | Y | Y | Y | Y | – |
   | Outbound Parcel Report | Y | Y | Y | Y | – |
   | Stock Unit Record | Y | Y | Y | Y | Y |
   | Container Record | Y | Y | Y | Y | Y |
   | Data Report | – | – | – | – | – |
   | Storage Locations | Y | Y | – | – | – |
   | Handling Units | Y | Y | Y | Y | Y |
   | Dashboard | Y | Y | Y | Y | Y |
   | Admin (→ Label Printing) | Y | – | – | – | – |

6. **`GUARDED` membership.** `LabelPrintingController` is not a base class, has no subclass, and all 10 of its
   handlers serve one tab — so a class-level `@RequiresFunction(WEB_UI_VIEW_PRINTER)` is safe there, and adding
   the class to `FunctionGuardInterceptor.GUARDED` would additionally buy anti-drift (a future unannotated
   handler denies instead of opening). Do **not** add `ReportController`, `DashboardController`, or
   `UnitLoadController` — `ReportController` is aliased under two prefixes and has ungated GET views,
   `UnitLoadController` is shared and slice C deliberately gates only two of its methods.
7. **Never key a test or verify row on a handler method name here.** `DashboardController.printToteLabels` logs
   itself as `reprintToteLabels` (`:73`, `:103`), `store/dashboard/pickpackMonitor.js:145` logs
   `'reprintLabels returned'` while POSTing `/dashboard/printToteLabels`, and `UnitLoadController`'s
   `deleteContainer` / `bulkDeleteContainer` both log `"start reprintLabel"` (`:93`, `:123`). Key on
   `(declaring class, path)`.

### 1.2 Inbound and orders

> Lane output, unedited. Attribution matters: these carry the file:line caller evidence.


Repo: `/home/nampark/dev/wms-claude/v2/wms2-api` @ `origin/develop` = `808819d` (read-only, nothing modified)
UI repos: `/home/nampark/dev/wms-claude/v2/wms2-web-ui`, `/home/nampark/dev/wms-claude/v2/wms2-mobile-ui`
Date: 2026-08-24. Caller greps are **untruncated** (no `head`, no `-m`), `node_modules/` and `dist/` excluded.

---

#### 0. Method — and the four things that changed the answers

**0.1 Ungated confirmed.** `grep -c "@RequiresFunction"` over `src/main` = 27 occurrences, none of them in
any of the 8 controllers below. All 8 extend `AdminController`, which carries **no** class-level
`@RequiresFunction` (verified `controller/AdminController.java:27-30` — only `@Tag`/`@RestController`/
`@RequestMapping("/v3")`). None of the 8 is in `FunctionGuardInterceptor.GUARDED`
(`security/FunctionGuardInterceptor.java:80-96` — 13 classes, all mobile + `UserRole`/`UserGroup`).
So every row below is genuinely ungated today.

**0.2 Grants were read out of the DB, not guessed.** Caller location tells you which *screen* a call sits
on; it does not tell you which *function* the operator holds. I resolved that from live grant data on
`wms2-wineco-dev` (`mywms_function` ⋈ `mywms_role_mywms_function.functionlist_id` ⋈ `mywms_role`; the
join's function side is `functionlist_id` — verified empirically, not assumed, given SBDEV-3005's key
reversal). That query changed **two** recommendations that "looked right" from the code alone (§1.4 and
§7.1). Grant table is §9.

**0.3 A `head`-free grep found 9 dead write endpoints out of 41.** Listed in §8. Dead surface changes the
decision: a wrong constant on a zero-caller endpoint cannot 403 anybody, so those rows are cheap.

**0.4 Verbs are not a reliable scope filter here.** Six endpoints in this tranche **mutate state behind
`GET`** (`advice/closeInboundBol/{id}`, `advice/acceptHubAndSpokeBol/...`,
`billOfLading/closeOutboundBol/{id}`, `billOfLading/closeIntraCompanyTransfer/{id}`,
`receiving/unlinkSelectedPallet/{name}`, `replenishOrder/cancelReplenishOrder/{id}`), and three
read-only endpoints are served over `POST` (`cycleCount/{itemData,location,position}View`). I enumerated
by *what the handler does*, not by the HTTP verb — a POST/PUT/PATCH/DELETE-only sweep would have missed
six privileged writes including two BOL closes and a replenish cancel.

---

#### 1. AdviceController — `/v3/advice` (`controller/AdviceController.java`)

Web-UI only. Zero mobile callers (§6). Screen family: **Receiving → Inbound Notices**
(`util/appMenuList.js:14` → `/receiving/inbound-notices?tab=open`).

| # | Endpoint | App callers (file:line) | Test callers | Screen | Recommended constant | Confidence | Rationale |
|---|---|---|---|---|---|---|---|
| 1.1 | `POST /v3/advice/create` | `wms2-web-ui/store/receiving/createPo.js:94` ← `components/receiving/open/create/createPurchaseOrder.vue:92` ← `components/receiving/open/openNotices.vue:136` ← `pages/receiving/inbound-notices.vue:24` | `cypress/support/helpers/wmsHelpers.js:360`; `cypress/e2e/wms/inbound-receiving/inbound-receiving.cy.js:275,299,301,767,775,789,797,811,819,833,841,855,863` | Inbound Notices (open tab) → **Create Purchase Order** dialog | `WEB_UI_VIEW_CREATE_INBOUND_BOL` | **certain** | The constant is literally named for this dialog, and the grant data agrees: `CS-REP` holds `WEB_UI_VIEW_INBOUND_BOL` but **not** `WEB_UI_VIEW_CREATE_INBOUND_BOL` — the create/view split already exists in the data, so using the create constant preserves it. |
| 1.2 | `POST /v3/advice/update` | `store/receiving/createPo.js:107` ← `components/receiving/open/popups/addMissingSku.vue:237` ← `components/receiving/open/openNoticeTable.vue:157` ← `pages/receiving/openNotice/_id.vue:19` | none | Open Notice **detail** → *Add Missing SKU* dialog | `WEB_UI_VIEW_INBOUND_BOL_ITEM_LINES` | probable | Despite living in the `createPo` store module it is dispatched from the *detail* screen, and what it mutates is the notice's item lines. Alt `WEB_UI_VIEW_INBOUND_BOL` is behaviourally equivalent for every **named** role (both = CS-REP + receiving + super-admin); they differ only in which numeric `ROLE000xxx` rows are attached. |
| 1.3 | `POST /v3/advice/setPurchaseOrderNumber` | `store/receiving/inboundNotices.js:146` ← `components/receiving/open/popups/changePoNumber.vue:51` ← `components/receiving/open/openNotices.vue:134` ← `pages/receiving/inbound-notices.vue` | none | Inbound Notices (open tab) → *Change PO #* dialog | `WEB_UI_VIEW_INBOUND_BOL` | **certain** | Renames a PO from the notices list; the list screen's own constant. |
| 1.4 | `POST /v3/advice/closeInboundBol` (multi-id) | `store/receiving/inboundNotices.js:163` ← `components/receiving/open/popups/closeOpenNoticePop.vue:86` ← `components/receiving/open/openNotices.vue:135` **and** `components/receiving/open/openNoticeDescription.vue:108` ← `pages/receiving/openNotice/_id.vue:18` | `wmsHelpers.js:379`; `inbound-receiving.cy.js:537-539,943-946` | Inbound Notices list **and** Open Notice detail | `WEB_UI_VIEW_INBOUND_BOL` | **certain** | Two screens, one constant — both are Inbound-BOL screens, so no ANY-of set is needed. |
| 1.5 | `GET /v3/advice/closeInboundBol/{id}` ⚠ write-via-GET | **NONE** | none | — | `WEB_UI_VIEW_INBOUND_BOL` | **certain** (dead) | Single-id twin of 1.4; the UI only ever calls the multi-id POST. Zero callers ⇒ free to gate. |
| 1.6 | `GET /v3/advice/acceptHubAndSpokeBol/{id}/{locationId}` ⚠ write-via-GET | `store/receiving/inboundNotices.js:212` ← `components/receiving/open/popups/closeOpenNoticePop.vue:81` ← `openNotices.vue:135` / `openNoticeDescription.vue:108` | none | Same dialog as 1.4 (hub-and-spoke branch) | `WEB_UI_VIEW_INBOUND_BOL` | **certain** | Same button, same dialog, same screen as 1.4. Must get the **same** constant or the dialog 403s on one branch only. |
| 1.7 | `POST /v3/advice/fixHubAndSpokePalletIssues` | **NONE** | none | — | `WEB_UI_VIEW_INBOUND_BOL` | probable (dead) | Zero callers in either UI (grep `fixHubAndSpokePalletIssues` = 0 hits outside the API). Takes `{id, oldPalletName, newPalletName}` and calls `adviceService.fixHubAndSpokePalletIssues` — reads as a support/repair tool. See §8 note: consider `WEB_UI_VIEW_INBOUND_BOL` now, `SPECIAL_DEVELOPER` if you want it locked to staff. |
| 1.8 | `POST /v3/advice/exportInboundNotice` (export, not a mutation) | `store/receiving/inboundNotices.js:234` ← `components/receiving/open/popups/exportInboundNoticePop.vue:56` ← `components/receiving/open/openNoticeDescription.vue:109` (**open** detail) **and** `components/receiving/closed/closedNoticeDescription.vue:205` (**closed** detail) | none | Open **and** Closed Notice detail | `WEB_UI_VIEW_INBOUND_BOL` | **certain** | Overlaps the `t1-exports-printing` lane — flag for de-dup, do not gate twice with different constants. |

---

#### 2. BillOfLadingController — `/v3/billOfLading`

Web-UI only. Screen family: **Outbound → Outbound BOL** (`util/appMenuList.js:54` → `/outbound/outbound-bol`).

| # | Endpoint | App callers | Test callers | Screen | Recommended constant | Confidence | Rationale |
|---|---|---|---|---|---|---|---|
| 2.1 | `POST /v3/billOfLading/create` | `store/outbound/outboundBols.js:216` ← `components/outbound/bol/create/createBol.vue:210` ← `components/outbound/bol/openOutboundBol.vue:134` ← `pages/outbound/outbound-bol/index.vue:23` | `wmsHelpers.js:82`; `transfer-offsite.cy.js:346,356`; `club-line-order.cy.js:647-648`; `step5-bol-create.cy.js:88,105`; `pick-pack-order.cy.js:457,472-473,1147-1148,1164-1165,1191-1192,1208-1209,1225-1226` | Outbound BOL (open tab) → **Create BOL** dialog | `WEB_UI_VIEW_BILL_OF_LADING` | **certain** | No `WEB_UI_VIEW_CREATE_BILL_OF_LADING` exists (the create/view split exists for *inbound* only), so the screen constant is the correct and only fit. |
| 2.2 | `POST /v3/billOfLading/setTrackingDeviceID` | `store/outbound/outboundBols.js:234` ← `components/outbound/bol/popups/gpsTrackerPop.vue:66` ← `openOutboundBol.vue:135` | none | Outbound BOL (open) → *Assign Tracker ID* dialog | `WEB_UI_VIEW_BILL_OF_LADING` | **certain** | Same screen. |
| 2.3 | `POST /v3/billOfLading/setDestinationFacility` | **NONE** | none | — | `WEB_UI_VIEW_BILL_OF_LADING` | probable (dead) | Grepped `setDestinationFacility`, `DestinationFacility`, `facilityCode` shapes — zero UI hits. Sets a BOL's destination warehouse; the UI does this at create time instead. |
| 2.4 | `GET /v3/billOfLading/closeOutboundBol/{id}` ⚠ write-via-GET | `store/outbound/outboundBols.js:253` ← `components/outbound/bol/popups/closeBolPop.vue:80` ← `components/outbound/bol/outboundBolDetails.vue:111` (`pages/outbound/outbound-bol/{open,closed}/_id.vue:20`) **and** `openOutboundBol.vue:132` | none | Outbound BOL list **and** BOL detail → *Close BOL* dialog (single-selection branch) | `WEB_UI_VIEW_BILL_OF_LADING` | **certain** | Same dialog as 2.5 — the popup picks GET-single vs POST-multi on `selectedItems.length`. Both must carry the same constant. |
| 2.5 | `POST /v3/billOfLading/closeOutboundBols` (multi) | `store/outbound/outboundBols.js:271` ← `components/outbound/bol/popups/closeBolPop.vue:84` ← same two parents as 2.4 | `wmsHelpers.js:99`; `club-line-order.cy.js:717-721`; `step7-bol-close.cy.js:72-77`; `transfer-offsite.cy.js:473-481`; `pick-pack-order.cy.js:1538-1549,1632-1635,1648-1651,1664-1667` | Same as 2.4 | `WEB_UI_VIEW_BILL_OF_LADING` | **certain** | See 2.4. |
| 2.6 | `POST /v3/billOfLading/exportOutboundBol` (export) | `store/outbound/outboundBols.js:316` ← `components/outbound/bol/popups/exportBolPop.vue:72` ← `openOutboundBol.vue:133`, `outboundBolDetails.vue:112`, `components/outbound/bol/closedOutboundBol.vue:117` | none | Outbound BOL open **+ closed** tabs and detail | `WEB_UI_VIEW_BILL_OF_LADING` | **certain** | Overlaps `t1-exports-printing` — de-dup. |
| 2.7 | `GET /v3/billOfLading/closeIntraCompanyTransfer/{transferId}` ⚠ write-via-GET | **NONE** | none | — | `WEB_UI_VIEW_TRANSFER_ORDER` | probable (dead) | Zero hits for `closeIntraCompanyTransfer` / `IntraCompany` / `intraCompany` in either UI. Calls `billofladingService.finishTransfer(transferId)` — semantically a *transfer* completion, not a BOL screen action, so if it is ever revived it belongs to the Transfer screen. Flagged as a controller/feature mismatch, not just dead. |
| 2.8 | `POST /v3/billOfLading/palletize` | **NONE** | none | — | `MOBILE_UI_VIEW_PALLETIZING` | NO-FIT-ish (dead) | **Superseded, not merely unused.** Both UIs palletize through `POST /v3/palletizing/scanPallet` on the mobile `PalletizingController` (`wms2-mobile-ui/store/palletizing.js:71`; `wmsHelpers.js:344`; `pick-pack-order.cy.js:18`) — which is already gated (`PalletizingController` ∈ `GUARDED`). Gating this twin `WEB_UI_*` would be wrong; recommend **deleting the endpoint** in a follow-up rather than gating it. If it must be gated in this tranche, `MOBILE_UI_VIEW_PALLETIZING` matches what the surviving path enforces. |

---

#### 3. ReceivingController — `/v3/receiving`

Web-UI only. Screen: **Receiving → Inbound Notices → Open Notice → Receive**
(`pages/receiving/openNotice/receive.vue`).

| # | Endpoint | App callers | Test callers | Screen | Recommended constant | Confidence | Rationale |
|---|---|---|---|---|---|---|---|
| 3.1 | `POST /v3/receiving/setPallet` | **NONE** | none | — | `WEB_UI_VIEW_RECEIVING` | **certain** (dead) | Enumerated every `receiving/<segment>` string used by either UI: only `createPallet`, `updatePallet`, `unlinkSelectedPallet`, `receive`, `getPalletsForReceiving`, `getRequireReceivingToContainer`, `getPutawayDestination`. `setPallet` is not among them — the `setPallet(s)` grep hits are Vuex **mutations** (`wms2-web-ui/store/receiving/receive.js:14,38`; `wms2-mobile-ui/store/putaway.js:12,63`), not this endpoint. This is exactly the false positive a name-based grep produces. |
| 3.2 | `POST /v3/receiving/createAndSelectPallet` | **NONE** | none | — | `WEB_UI_VIEW_RECEIVING` | **certain** (dead) | Same enumeration; zero hits for `createAndSelectPallet`. Superseded by 3.3 + the picker in `searchPallet.vue`. |
| 3.3 | `POST /v3/receiving/createPallet` | `store/receiving/receive.js:47` ← `components/receiving/open/receive/createPallet.vue:71` ← `components/receiving/open/receive/receivingForm.vue:288` ← `pages/receiving/openNotice/receive.vue:26` | none | Receive screen → *Create Pallet* | `WEB_UI_VIEW_RECEIVING` | **certain** | `WEB_UI_VIEW_RECEIVING` is granted to exactly `receiving` + `super-admin` — the narrowest fit and the operator set that actually uses this screen. |
| 3.4 | `GET /v3/receiving/unlinkSelectedPallet/{palletName}` ⚠ write-via-GET | `components/receiving/open/receive/receivingForm.vue:528` (direct `$axios.$get`, no store action) | none | Receive screen | `WEB_UI_VIEW_RECEIVING` | **certain** | Same screen. Note the direct-axios call: a store-action-only grep would have missed it. |
| 3.5 | `POST /v3/receiving/updatePallet` | `store/receiving/receive.js:64` ← `components/receiving/open/receive/receivingForm.vue:493` | `wmsHelpers.js:450`; `inbound-receiving.cy.js:459,462` | Receive screen | `WEB_UI_VIEW_RECEIVING` | **certain** | Same screen. |
| 3.6 | `POST /v3/receiving/receive` | `store/receiving/receive.js:79` ← `components/receiving/open/receive/receivingForm.vue:577` | `wmsHelpers.js:463`; `inbound-receiving.cy.js:474,486,877-885,899-907,921-929,1036` | Receive screen — the commit | `WEB_UI_VIEW_RECEIVING` | **certain** | The single highest-value write in the tranche (creates stock). Screen constant is the correct grain. |

---

#### 4. GoodsReceiptPositionController — `/v3/goodsReceiptPosition`

Web-UI only. Screen: **Open Notice detail** (goods-receipt rows table).

| # | Endpoint | App callers | Test callers | Screen | Recommended constant | Confidence | Rationale |
|---|---|---|---|---|---|---|---|
| 4.1 | `POST /v3/goodsReceiptPosition/adjust` | `store/receiving/inboundNotices.js:364` ← `components/receiving/open/popups/adjustAmountOpenNoticeReceipt.vue:78,80` ← `components/receiving/open/openNoticeTable.vue:156` **and** `components/receiving/open/openNoticeReceiptTable.vue:103` ← `pages/receiving/openNotice/_id.vue:19` | none | Open Notice detail → *Adjust Amount* dialog | `WEB_UI_VIEW_GOODS_RECEIPT_POSITION` | **certain** | ⚠ **Do NOT use `WEB_UI_ACTION_ADJUST_AMOUNT`** even though it reads like a perfect semantic match. Live grants: `WEB_UI_ACTION_ADJUST_AMOUNT` = `inventory-manager`, `super-admin`, +2 numeric — it does **not** include `receiving` or `CS-REP`, which are precisely the roles that hold this screen. Gating on it 403s the receiving role on a button it uses today. `WEB_UI_VIEW_GOODS_RECEIPT_POSITION` = `CS-REP`, `receiving`, `super-admin` +3 numeric. This is the one row where the semantically-obvious constant is the wrong one. |
| 4.2 | `POST /v3/goodsReceiptPosition/delete` | `store/receiving/inboundNotices.js:347` ← `components/receiving/open/popups/deleteOpenNoticeReceipt.vue:67` ← `openNoticeTable.vue:155` **and** `openNoticeReceiptTable.vue:102` | none | Same dialog family | `WEB_UI_VIEW_GOODS_RECEIPT_POSITION` | **certain** | Same screen, same dialog set. |

---

#### 5. ReplenishOrderController — `/v3/replenishOrder` — ⚠ **THE ONLY BOTH-UI CONTROLLER IN THIS TRANCHE**

Screen: **Internal Ops → Replenishment** (`util/appMenuList.js:28`) **plus** the mobile Replenish page.

**Read §5.0 before assigning anything on this controller.**

##### 5.0 A class-level gate on this controller breaks mobile Replenish — with measured grant evidence

`wms2-mobile-ui/pages/replenish.vue:147` issues a **live** `GET /v3/replenishOrder/detailView?state=OPEN…`
(inside `fetchAllReplen()`; the commented-out duplicate is at :192, the one at :147 is not commented).
So `ReplenishOrderController` serves both UIs.

Grants make the consequence concrete, not hypothetical:

- `WEB_UI_VIEW_REPLENISHMENT_ORDER` → `receiving`, `super-admin` (2 roles)
- `MOBILE_UI_VIEW_REPLENISHMENT` → `ROLE000039`, `receiving`, `super-admin` (3 roles)

`ROLE000039` holds the mobile function and **not** the web one. A class-level
`@RequiresFunction(WEB_UI_VIEW_REPLENISHMENT_ORDER)` therefore 403s the mobile Replenish list for every
`ROLE000039` operator, and the mobile UI surfaces that as a generic failure toast.

**Requirements:** (a) annotate **per method**, never at class level, on this controller;
(b) `GET /v3/replenishOrder/detailView` — read-only, outside this tranche's write scope but inside the
blast radius of any class-level annotation — needs the ANY-of set
`{WEB_UI_VIEW_REPLENISHMENT_ORDER, MOBILE_UI_VIEW_REPLENISHMENT}`; (c) do **not** add
`ReplenishOrderController` to `GUARDED` in this tranche — it is a shared controller, and fail-closed
membership would deny `detailView` the moment anyone adds an unannotated handler.
`GET /v3/replenishOrder/{stockUnitInfoForReplenishment,replenishorderDetailsById,getPickableLocations,
loadOrderByDestination}` are web-only reads and need no set.

| # | Endpoint | App callers | Test callers | Screen | Recommended constant | Confidence | Rationale |
|---|---|---|---|---|---|---|---|
| 5.1 | `POST /v3/replenishOrder/update` | `store/internalOps/replenishments.js:233` (`updateReplenishmentOrder`) ← `components/internalOps/replenishment/open/editRepleishmentRequest.vue:168` — **but that component's import and tag are both commented out** (`openRequest.vue:155,191`), so it never mounts | none | none reachable | `WEB_UI_VIEW_REPLENISHMENT_ORDER` | probable (**effectively dead**) | Only dispatcher is an unmounted component. Treated as dead surface: gating it cannot break a UI. |
| 5.2 | `POST /v3/replenishOrder/updateStockUnit` | `store/internalOps/replenishments.js:249` (`updateSourceStockUnit`) **and** `:249` reached via `updateStockUnit` path ← `components/internalOps/replenishment/open/updateStockUnitPop.vue:67` ← `components/internalOps/replenishment/open/openRequest.vue:192` ← `pages/internalOps/replenishment.vue:24` | none | Replenishment (open tab) → *Update Stock Unit* dialog | `WEB_UI_VIEW_REPLENISHMENT_ORDER` | **certain** | Web-only screen. Note two store actions (`updateStockUnit`, `updateSourceStockUnit`) POST to this same path — the "change source" dialog reuses it, which is why 5.4 is dead. |
| 5.3 | `POST /v3/replenishOrder/updatePriority` | `store/internalOps/replenishments.js:265` ← `components/internalOps/replenishment/open/updatePriorityPop.vue:80` ← `openRequest.vue` | none | Replenishment (open) → *Update Priority* | `WEB_UI_VIEW_REPLENISHMENT_ORDER` | **certain** | Web-only screen. |
| 5.4 | `POST /v3/replenishOrder/changeSourceStockUnit` | **NONE** | none | — | `WEB_UI_VIEW_REPLENISHMENT_ORDER` | **certain** (dead) | Zero hits for `changeSourceStockUnit` in either UI. The "change source stock unit" dialog posts to `/replenishOrder/updateStockUnit` instead (`replenishments.js:249`) — verified by reading the action body, not inferred from the name. |
| 5.5 | `GET /v3/replenishOrder/cancelReplenishOrder/{id}` ⚠ write-via-GET | `store/internalOps/replenishments.js:180` ← `components/internalOps/replenishment/open/cancelRequestPop.vue:72` ← `openRequest.vue:189` | `wmsHelpers.js:769`; `replenishment.cy.js:167,308,676,1062` | Replenishment (open) → *Cancel Request* | `WEB_UI_VIEW_REPLENISHMENT_ORDER` | **certain** | Web-only screen. |
| 5.6 | `POST /v3/replenishOrder/create` | `store/internalOps/replenishments.js:282` ← `components/internalOps/replenishment/open/createReplenishmentRequest.vue:163` ← `openRequest.vue:190` | `wmsHelpers.js:980`; `replenishment.cy.js:343,364-365,587-588,603-614,626-633,646-662` | Replenishment (open) → *Create Replenishment Request* (supervisor) | `WEB_UI_VIEW_REPLENISHMENT_ORDER` | **certain** | Supervisor create is web-only. The mobile *request* path is `MobileReplenishController` and already carries `MOBILE_UI_VIEW_REPLENISH_REQUEST` (SBDEV-2968 C1) — do not conflate. |

---

#### 6. CustomerOrderController — `/v3/customerOrder` — ⚠ **THREE DIFFERENT SCREENS, ONE CONTROLLER**

No class-level annotation is possible here either: its handlers are dispatched from Pick&Pack, Club, and
Transfer, whose function grants are all different.

| # | Endpoint | App callers | Test callers | Screen | Recommended constant | Confidence | Rationale |
|---|---|---|---|---|---|---|---|
| 6.1 | `POST /v3/customerOrder/setPickingDate` | `store/outbound/transfer.js:181` (`saveShipDate`) ← `components/outbound/transfer/transferDetails.vue:153` ← `pages/outbound/transfer/{open,closed}/_id.vue:20` | none | **Outbound → Transfer** detail → Ship Date field. **NOT Pick&Pack.** | `WEB_UI_VIEW_TRANSFER_ORDER` | **certain** | The name says "picking date" and the controller says "customerOrder", but the *only* caller is the Transfer detail screen. Grants confirm the distinction matters: `WEB_UI_VIEW_TRANSFER_ORDER` = `inventory-manager`, `outbound-manager`, `super-admin`; `WEB_UI_VIEW_ORDER` = `CS-REP`, `outbound-manager`, `super-admin`. Gating on `WEB_UI_VIEW_ORDER` would 403 `inventory-manager` on a field it uses; gating on `WEB_UI_VIEW_TRANSFER_ORDER` is correct and also (correctly) excludes `CS-REP`. **This is the exact trap the tranche brief warned about — the endpoint name points at the wrong screen.** |
| 6.2 | `POST /v3/customerOrder/pickingDateBatchUpdate` | `store/outbound/pickPack.js:221` (`updatePickingDates`) ← `components/outbound/pickPack/pop/updatePickingDatePop.vue:97`, `components/outbound/pickPack/parcelDetails.vue:187`, `components/outbound/pickPack/openParcels.vue:23,358,361` ← `pages/outbound/pick-pack/index.vue:23` + `pages/outbound/pick-pack/{open,closed}/_id.vue:20`. (`components/outbound/club/openClub.vue:43` also names `updatePickingDates` but that button is **commented out**.) | none | **Outbound → Pick Pack** list + parcel detail | `WEB_UI_VIEW_ORDER` | probable | No constant is named for Pick&Pack; the screen's own reads are `GET /v3/customerOrder/{openPickPack,closedPickPack}` (`pickPack.js:139,167`), so the order-level constant is the right grain. `WEB_UI_VIEW_ORDER` = `CS-REP`, `outbound-manager`, `super-admin` — a plausible Pick&Pack operator set. Confirm with Nam that `CS-REP` should be able to move picking dates in bulk. |
| 6.3 | `POST /v3/customerOrder/batchUpdatePriorityByOrderIds` | `store/outbound/pickPack.js:251` (`updatePriorities`) ← `components/outbound/pickPack/pop/updatePriorityPop.vue:84`, `components/outbound/pickPack/parcelDetails.vue:176` | none | Pick Pack list + parcel detail | `WEB_UI_VIEW_ORDER` | probable | Same screen as 6.2; must match 6.2 or the two buttons on one toolbar behave differently. |

**Also flagged (read-only, so outside this tranche, but inside the blast radius of a class-level annotation):**
`GET /v3/customerOrder/detailsByOrderId/{id}` is called from **both** Pick&Pack (`pickPack.js:183`) and
Club (`store/outbound/club.js:219`) — it needs the ANY-of set
`{WEB_UI_VIEW_ORDER, WEB_UI_VIEW_CLUB_LINE}` whenever it is gated. `WEB_UI_VIEW_CLUB_LINE` carries two
numeric roles (`ROLE000057`, `ROLE000102`) that `WEB_UI_VIEW_ORDER` does not.

---

#### 7. CustomerOrderBatchController — `/v3/customerOrderBatch`

| # | Endpoint | App callers | Test callers | Screen | Recommended constant | Confidence | Rationale |
|---|---|---|---|---|---|---|---|
| 7.1 | `POST /v3/customerOrderBatch/batchUpdatePriority` | **NONE** | none | — | `WEB_UI_VIEW_ORDER_BATCH` | **certain** (dead) | Untruncated grep of `batchUpdatePriority` returns only `batchUpdatePriorityByOrderIds` (6.3) and `batchUpdatePriorityByBatchIds` (7.2). The bare form has no caller — a prefix grep would have wrongly scored it as live. |
| 7.2 | `POST /v3/customerOrderBatch/batchUpdatePriorityByBatchIds` | `store/outbound/club.js:329` (`updatePriorities`) ← `components/outbound/club/pop/updatePriorityPop.vue:83`, `components/outbound/club/batchDetails.vue:163`, `components/outbound/club/openClub.vue:46` ← `pages/outbound/club/index.vue:23` + `pages/outbound/club/{open,closed}/_id.vue:20` | none | **Outbound → Club** list + batch detail | `WEB_UI_VIEW_CLUB_LINE` | probable | Called only from the Club screens. `WEB_UI_VIEW_CLUB_LINE` = `CS-REP`, `outbound-manager`, `super-admin`, `ROLE000057`, `ROLE000102`; `WEB_UI_VIEW_ORDER_BATCH` = only `CS-REP`, `outbound-manager`, `super-admin` — so the "obvious" `ORDER_BATCH` choice would 403 two roles that hold the Club screen. If you would rather not couple a batch endpoint to a Club function, use the ANY-of set `{WEB_UI_VIEW_CLUB_LINE, WEB_UI_VIEW_ORDER_BATCH}`. |

---

#### 8. CycleCountController — `/v3/cycleCount` — **web-only; the brief's both-UI hypothesis is FALSE**

The brief flagged this as a likely ANY-of case. It is not. Mobile cycle count talks exclusively to
`/v3/cycleCountLos/*` (`wms2-mobile-ui/store/cycleCount.js:67,78,90,102,121,156,190,209,237,250` — ten
calls, all `cycleCountLos`), served by `CycleCountLosController`, which is already in `GUARDED` and
already gated with `MOBILE_UI_VIEW_CYCLE_COUNT`. An untruncated grep of the whole mobile repo for
`'/cycleCount/` returns **zero** hits. So **no ANY-of set is needed** — single web constant throughout.

Grants corroborate the separation and show why an ANY-of set would be actively harmful:
`MOBILE_UI_VIEW_CYCLE_COUNT` includes `inventory-worker`, `WEB_UI_VIEW_CYCLECOUNT` does not. Adding the
mobile constant to an ANY-of set here would hand every `inventory-worker` the ability to **create and
cancel** cycle counts from the web API.

| # | Endpoint | App callers | Test callers | Screen | Recommended constant | Confidence | Rationale |
|---|---|---|---|---|---|---|---|
| 8.1 | `POST /v3/cycleCount/create` | `store/internalOps/createCc.js:66` ← `components/internalOps/cycleCount/planned/create/createCycleCount.vue:127` ← `components/internalOps/cycleCount/planned/plannedCycleCount.vue:150` ← `pages/internalOps/cycle-count.vue:24` | `wmsHelpers.js:853`; `cycle-count.cy.js:218,233-234,789` | Internal Ops → Cycle Count (planned tab) → **Create** | `WEB_UI_VIEW_CYCLECOUNT` | **certain** | Web-only; screen constant. |
| 8.2 | `POST /v3/cycleCount/cancel` | `store/internalOps/cycleCount.js:200` ← `components/internalOps/cycleCount/planned/cancelCycleCountPop.vue:72` ← `plannedCycleCount.vue:149` | none | Cycle Count (planned) → *Cancel* | `WEB_UI_VIEW_CYCLECOUNT` | **certain** | Same screen. |
| 8.3 | `POST /v3/cycleCount/export` (export) | `store/internalOps/cycleCount.js:222` ← `components/internalOps/cycleCount/exportCyclePop.vue:72` | `test/components/internalOps/cycleCount/exportCyclePop.spec.js:36` (Jest, test) | Cycle Count | `WEB_UI_VIEW_CYCLECOUNT` | **certain** | Overlaps `t1-exports-printing` — de-dup. |
| 8.4 | `POST /v3/cycleCount/itemDataView` (read via POST) | `store/internalOps/cycleCount.js:165` | `wmsHelpers.js:865`; `cycle-count.cy.js:340,348-349,891,902,916-919` | Cycle Count detail | `WEB_UI_VIEW_CYCLECOUNT` | **certain** | Read-only despite the POST verb; include so a future class-level annotation cannot silently diverge. |
| 8.5 | `POST /v3/cycleCount/locationView` (read via POST) | `store/internalOps/cycleCount.js:177` | `wmsHelpers.js:872`; `cycle-count.cy.js:361,369-370,382` | Cycle Count detail | `WEB_UI_VIEW_CYCLECOUNT` | **certain** | As 8.4. |
| 8.6 | `POST /v3/cycleCount/positionView` (read via POST) | `store/internalOps/cycleCount.js:189` | none | Cycle Count detail (positions) | `WEB_UI_VIEW_CYCLECOUNT` | **certain** | `WEB_UI_VIEW_CYCLECOUNT_POSITION` also exists and is the tighter semantic fit, but it is a **superset** of `WEB_UI_VIEW_CYCLECOUNT`'s roles here (adds `ROLE000060`), so it would not deny anyone — use it if you want per-view grain; otherwise keep the screen constant for consistency with 8.4/8.5. |

---

#### 9. Findings that change the plan

##### 9.A ✅ No machine-to-machine endpoint in this tranche — the `permitAll()` hazard does not bite here
OMS talks to WMS through a **separate** controller tree under `/rest/**`, which is `permitAll()`
(`SecurityConfiguration.java:148-153`). The inbound/order integration endpoints live there, not on any of
my 8 controllers: `AdviceRestController` (`/rest/advice/create`, `/createTransfer`, `/createHubAndSpoke`,
`/reopen`), `OrderRestController` (`/rest/order/create`, `/updatePriority`, `/cancelPositions`,
`/finishedQA`, `/finishedTransfer`), `SkuRestController`, `StockCountRestController`. Every `/v3/**`
endpoint above is reached only from an authenticated UI. **All 41 rows are safe to function-gate** —
none of them will strand an unauthenticated OMS caller.

##### 9.B 🔴 HIGH — gating these MVC writes leaves an ungateable Spring Data REST twin, and the UI already uses it
`RestConfiguration.java:24,32` sets the SDR base path to **`/v3`** — the same prefix as these
controllers. Repositories exported there include `AdviceRepository` (`path = "advice"`),
`CyclecountRepository` (`path = "cyclecount"`), `BillofladingRepository` (`path = "billoflading"`), plus
`Customerorder*`, `Goodsreceiptposition`, `Replenishorder`. SDR is served by
`RepositoryRestHandlerMapping`, which never consults `WebMvcConfigurer#addInterceptors`, so
`@RequiresFunction` **cannot reach it** (stated in `RequiresFunction` javadoc; this is SBDEV-3017's own
general case). The web UI is already using those paths for real writes:

- `wms2-web-ui/store/receiving/inboundNotices.js:187` — `DELETE /v3/advice/{id}` (**deletes an inbound notice**)
- `wms2-web-ui/store/receiving/inboundNotices.js:380` — `PATCH /v3/advice/{id}` (save comment)
- `wms2-web-ui/store/internalOps/cycleCount.js:250` — `PATCH /v3/cyclecount/{id}` (save comment)

So closing `POST /v3/advice/closeInboundBol` while `DELETE /v3/advice/{id}` stays wide open buys very
little for Advice. Recommendation: pair each Advice/CycleCount gate in this tranche with an
`exported = false` decision on the corresponding SDR write verbs (the `AdviceRepository` javadoc shows
the precedent — SBDEV-2781 closed `getDetailViewByKeyword` by removal), or state explicitly in the plan
that the SDR path is out of scope so nobody reads tranche 1 as "Advice writes are now gated."

##### 9.C 🟠 Two controllers cannot take a class-level annotation
`ReplenishOrderController` (§5.0 — mobile `detailView`, with `ROLE000039` proving the denial is real) and
`CustomerOrderController` (§6 — three screens with three different grant sets). Method-level only, and
neither should join `GUARDED` in this tranche.

##### 9.D 🟡 9 of 41 endpoints are dead surface
`advice/closeInboundBol/{id}` (GET), `advice/fixHubAndSpokePalletIssues`,
`billOfLading/setDestinationFacility`, `billOfLading/closeIntraCompanyTransfer/{id}`,
`billOfLading/palletize`, `receiving/setPallet`, `receiving/createAndSelectPallet`,
`replenishOrder/changeSourceStockUnit`, `customerOrderBatch/batchUpdatePriority` — plus
`replenishOrder/update`, whose only dispatcher is a commented-out component (10 if you count it).
Gating them is free (no UI can 403) but so is deleting them; `billOfLading/palletize` in particular is a
**superseded** twin of the already-gated `/v3/palletizing/scanPallet` and should be deleted, not gated.

##### 9.E 🟡 Six privileged writes hide behind `GET`
Listed in §0.4. Any verb-based sweep of this surface under-counts by six, including two BOL closes and a
replenish cancel. Keep them in the plan's §0 table keyed on `(declaring class, path)`.

##### 9.F 🟡 Three export endpoints overlap the `t1-exports-printing` lane
`advice/exportInboundNotice`, `billOfLading/exportOutboundBol`, `cycleCount/export`. De-dup before the
plan lands, and make sure both lanes pick the **same** constant for each.

##### 9.G Live grant data used above (`wms2-wineco-dev`, 2026-08-24)

| Function | Roles |
|---|---|
| `WEB_UI_VIEW_CREATE_INBOUND_BOL` | receiving, super-admin, ROLE000059, ROLE000104, ROLE000124 |
| `WEB_UI_VIEW_INBOUND_BOL` | CS-REP, receiving, super-admin, ROLE000069, ROLE000112, ROLE000133 |
| `WEB_UI_VIEW_INBOUND_BOL_ITEM_LINES` | CS-REP, receiving, super-admin, ROLE000070, ROLE000114, ROLE000134 |
| `WEB_UI_VIEW_RECEIVING` | receiving, super-admin |
| `WEB_UI_VIEW_GOODS_RECEIPT_POSITION` | CS-REP, receiving, super-admin, ROLE000066, ROLE000110, ROLE000130 |
| `WEB_UI_ACTION_ADJUST_AMOUNT` | inventory-manager, super-admin, ROLE000043, ROLE000092 |
| `WEB_UI_VIEW_BILL_OF_LADING` | CS-REP, outbound-manager, super-admin, ROLE000053 |
| `WEB_UI_VIEW_REPLENISHMENT_ORDER` | receiving, super-admin |
| `MOBILE_UI_VIEW_REPLENISHMENT` | receiving, super-admin, **ROLE000039** |
| `WEB_UI_VIEW_ORDER` | CS-REP, outbound-manager, super-admin |
| `WEB_UI_VIEW_ORDER_BATCH` | CS-REP, outbound-manager, super-admin |
| `WEB_UI_VIEW_TRANSFER_ORDER` | inventory-manager, outbound-manager, super-admin |
| `WEB_UI_VIEW_CLUB_LINE` | CS-REP, outbound-manager, super-admin, ROLE000057, ROLE000102 |
| `WEB_UI_VIEW_CYCLECOUNT` | inventory-manager, super-admin, ROLE000077, ROLE000105, ROLE000125 |
| `MOBILE_UI_VIEW_CYCLE_COUNT` | inventory-manager, **inventory-worker**, super-admin, ROLE000034 |
| `WEB_UI_VIEW_CYCLECOUNT_POSITION` | inventory-manager, super-admin, ROLE000060, ROLE000078, ROLE000106, ROLE000126 |

One tenant (`wineco-dev`). Grants differ per tenant DB — re-check UAT/prd before merge, because a
constant that denies nobody on dev can deny an operator elsewhere.

##### 9.H No new constant is needed
All 41 endpoints map onto the existing 81. The only near-miss is `billOfLading/palletize` (§2.8), and the
right answer there is deletion, not a new constant.

##### 9.I Caller enumeration is trustworthy
`wms2-web-ui` builds exactly **one** axios URL from a variable
(`store/admin/labelPrinting.js:256`, unrelated to this tranche); every other call site is a literal or a
template literal with a literal prefix. So the string greps above are effectively complete, not merely
best-effort. `wms2-web-ui` has **no** `middleware/` directory and `util/appMenuList.js` keys the menu on
Keycloak role, not on `FunctionEnum` — confirming a wrong constant produces an enabled button that 403s,
not a hidden one.

### 1.3 Master data and admin

> Lane output, unedited. Attribution matters: these carry the file:line caller evidence.


Repo: `/home/nampark/dev/wms-claude/v2/wms2-api` @ `origin/develop` = `808819d`
UI repos: `/home/nampark/dev/wms-claude/v2/wms2-web-ui`, `/home/nampark/dev/wms-claude/v2/wms2-mobile-ui`
Produced 2026-08-24. All greps untruncated (no `head`, no `-m`), `node_modules/ dist/ .nuxt/` excluded.

---

#### 0. Facts established before the table (each one changes a row)

**0.1 — All 11 classes are fully ungated.** `grep -n "RequiresFunction"` over all 11 controller files **plus their
shared base class `AdminController`** returns **NONE**. No method-level and no class-level annotation anywhere.
None of the 11 is in `FunctionGuardInterceptor.GUARDED` (`security/FunctionGuardInterceptor.java:80-96`, 13
classes, all mobile + `UserRoleController`/`UserGroupController`).

**0.2 — The mobile UI calls NONE of these 11 controllers.** An untruncated grep for
`$?(get|post|put|patch|delete)('/(client|printer|location|systemProperty|import|boxType|adminAction|section|shipperId|fixedAssignment|admin)` over `wms2-mobile-ui`
returns exactly two hits, both SDR **reads** of a different resource:
`wms2-mobile-ui/store/picking.js:186` (`GET /section/search/findByName`) and `:388` (`GET /section`).
**⇒ No ANY-of set is needed anywhere in tranche 1.** In particular `FixLocationAssignmentController`, which the
brief flagged as a likely both-UIs case, is **web-only**: SBDEV-2968 moved a mobile *read* off
`FixLocationAssignmentRepository#findByAssignedlocationId` onto `ReplenishController#fixedLocationUpperBound`
(`repo/jpa/FixLocationAssignmentRepository.java:22-36`); none of the six **writes** is mobile-driven.

**0.3 — `wms2-web-ui` has no function gating at all.** No `middleware/` directory exists, and
`layouts/default.vue:302` is `links() { return menuList["super-admin"]; }` — every user gets the full
super-admin menu. A wrong constant therefore produces an **enabled button that 403s** with the generic
`'Error: Request failed due to a network or server issue. Please retry.'` toast (that literal string is the
catch-block in every store module below). Constants are chosen by **the screen the caller sits on**.

**0.4 — SDR bypass co-exists with every row here.** All nine entities are `@RepositoryRestResource`-exported:
`fixLocationAssignment`, `client`, `location`, `printer`, `sysprop`, `boxtype`, `section`, `shipperid`
(+`locationtype`). `RepositoryRestHandlerMapping` does not consult `WebMvcConfigurer#addInterceptors`, so
`@RequiresFunction` **structurally cannot** gate them (`security/RequiresFunction.java:38`). Three rows below
are not merely bypassable in theory — **the web UI's live write path is already the SDR route**:
- client edit → `$patch('/client/{id}')` (`store/admin/shippers.js:57`, from `components/admin/shippers/editShipper.vue:206`)
- sysprop edit/delete → `$put('/sysprop/{id}')` / `$delete('/sysprop/{id}')` (`store/admin/configuration.js:105,157,202`; `store/admin/management.js:240`)
- section delete → `delete('/section/{id}')` (`store/masterData/section.js:73`)
Gating the controller closes nothing on those paths. Flagged per-row.

**0.5 — `AdminController` declares 9 mappings of its own** (`/v3/user/**` ×7, `/v3/admin/importUsersFromCsvText`,
`/v3/groups/findGroup` — `controller/AdminController.java:80,108,121,134,143,155,176,215,225`) and is the base
class of 43 controllers, so those register under all 43 prefixes. The interceptor resolves from the **declaring**
class, so a class-level annotation on any of my 10 subclasses correctly does **not** touch them — and
conversely, **never** put `@RequiresFunction` on `AdminController` itself; it would gate 43 controllers at once.

**0.6 — `WEB_UI_VIEW_CASE_TYPE`, `WEB_UI_VIEW_SYSTEM_PROPERTY`, `WEB_UI_VIEW_IMPORT_DATA` etc. are metadata only
today.** 81 constants confirmed in `service/WmsConstants.java:352-441` (`grep -c` over that range = 81).

**0.7 — ⚠ `LocationController`'s four writes are verb-inverted against their only callers.** The controller
declares `@PostMapping("/create")` (:58), `@PutMapping("/update")` (:77), `@PostMapping("/createLocationType")`
(:96), `@PutMapping("/updateLocationType")` (:115). The web UI calls, respectively, `$put`, `$post`, `$put`,
`$post`. No other handler in `src/main` serves those four paths (grep over all `.java`). Spring's
`RequestMappingHandlerMapping` raises `HttpRequestMethodNotSupportedException` on a path-match/method-miss, so
all four UI writes should be **405 today**, before any gate. Confirm with a curl before sizing the fix — but
the practical consequence for this ticket is that gating these four changes nothing observable, and whoever
fixes the verbs must land the gate at the same time.

---

#### 1. The mapping table

Verb/path as declared. `L` = line in the controller. Callers are the complete untruncated set; `(TEST)` marks
cypress/jest, which are **not** app callers.

| # | Endpoint (verb + path) | L | Every caller (file:line) | Screen / page / menu | Recommended constant | Confidence | Rationale |
|---|---|---|---|---|---|---|---|
| **FixLocationAssignmentController** — `/v3/fixedAssignment`, 6 writes | | | | | | | |
| 1 | `POST /v3/fixedAssignment/update` | 54 | **NONE** | — | `WEB_UI_VIEW_FIXED_ASSIGNMENT` | certain | **DEAD SURFACE.** Its body is a strict superset of rows 3–6 (`changeActive` + `adjust{Lower,Middle,Upper}Bound` switched on which key the map carries); the UI uses the four narrow endpoints instead. Gate it with the screen constant, and file a follow-up to delete it. |
| 2 | `POST /v3/fixedAssignment/move` | 86 | `wms2-web-ui/store/masterData/fixedLocation.js:94` | `components/masterData/location/fixedLocations/moveFixedLocation.vue:60` → `fixedLocation.vue:345` → `pages/masterData/locationData/fixed-locations.vue` → menu **Master Data › Location Data › Fixed Locations** (`util/appMenuList.js:94-95`) | `WEB_UI_VIEW_FIXED_ASSIGNMENT` | certain | Only caller is the Fixed Locations screen; constant names that screen exactly. |
| 3 | `DELETE /v3/fixedAssignment/delete/{id}` | 112 | `store/masterData/fixedLocation.js:67` | `components/masterData/location/fixedLocations/fixedLocation.vue:328` → same page as row 2 | `WEB_UI_VIEW_FIXED_ASSIGNMENT` | certain | Same screen. |
| 4 | `POST /v3/fixedAssignment/setUpperBound` | 141 | `store/masterData/fixedLocation.js:125` | `components/masterData/location/fixedLocations/updateBound.vue:62` → `fixedLocation.vue:361` → same page | `WEB_UI_VIEW_FIXED_ASSIGNMENT` | certain | Same screen. |
| 5 | `POST /v3/fixedAssignment/setMiddleBound` | 164 | `store/masterData/fixedLocation.js:142` | `updateBound.vue:64` → same page | `WEB_UI_VIEW_FIXED_ASSIGNMENT` | certain | Same screen. |
| 6 | `POST /v3/fixedAssignment/setLowerBound` | 187 | `store/masterData/fixedLocation.js:159` | `updateBound.vue:66` → same page | `WEB_UI_VIEW_FIXED_ASSIGNMENT` | certain | Same screen. |
| **ClientController** — `/v3/client`, 4 writes | | | | | | | |
| 7 | `POST /v3/client/create` | 83 | `store/admin/shippers.js:33` · (TEST) `cypress/e2e/wms/admin/admin.cy.js:374,389`, `cypress/support/helpers/wmsHelpers.js:1186` | `components/admin/shippers/addShipper.vue:104` → `pages/admin.vue:21` tab **Shippers** (tab index 2) | `WEB_UI_VIEW_CLIENT` | certain | The Shippers tab is the client screen; `WEB_UI_VIEW_CLIENT` is unclaimed and names it. (`WEB_UI_VIEW_USER_MANAGEMENT` is already taken by the neighbouring tab.) |
| 8 | `POST /v3/client/setSection` | 125 | **NONE** | — | `WEB_UI_VIEW_CLIENT` | certain | **DEAD SURFACE.** `editShipper.vue:206` writes the whole client via SDR `$patch('/client/{id}')` (`store/admin/shippers.js:57`) instead. ⚠ §0.4: gating this leaves the *live* edit path open. |
| 9 | `POST /v3/client/setPrinter` | 137 | **NONE** | — | `WEB_UI_VIEW_CLIENT` | certain | **DEAD SURFACE**, same reason as row 8. |
| 10 | `POST /v3/client/toggleReceiving` | 150 | **NONE** | — | `WEB_UI_VIEW_CLIENT` | certain | **DEAD SURFACE**, same reason. (`ClientRepository:45` also exports `toggleEnableReceivingById` over SDR — same bypass.) |
| **FileImportController** — `/v3/import`, 4 writes | | | | | | | |
| 11 | `POST /v3/import/clients` | 98 | `store/admin/mgmt/import.js:40` · `store/admin/management.js:93` **(dead store — zero component consumers)** · (TEST) `wmsHelpers.js:1146` (dynamic `/import/`+kind), `admin.cy.js:860` | `components/admin/systemManagement/uploads/clientUpload.vue:91` → `systemManagementMain.vue:29` sub-tab **Import Data** → `pages/admin.vue` tab **System Management** (index 0) | `WEB_UI_VIEW_IMPORT_DATA` | certain | **Confirmed as the brief asked.** The sub-tab is literally named "Import Data"; every caller is inside `components/admin/systemManagement/uploads/`. **Not OMS-driven** — OMS writes through `/rest/**` (`AdviceRestController`, `SkuRestController`), which `SecurityConfiguration:151` `permitAll`s and which is a different surface entirely; `/v3/import/**` has no `/rest` twin. |
| 12 | `POST /v3/import/locations` | 147 | `store/admin/mgmt/import.js:59` · (TEST) as above | `uploads/locationUpload.vue:96` → same sub-tab | `WEB_UI_VIEW_IMPORT_DATA` | certain | Same screen. |
| 13 | `POST /v3/import/skus` | 315 | `store/admin/mgmt/import.js:97` · (TEST) as above | `uploads/skuUpload.vue:92` → same sub-tab | `WEB_UI_VIEW_IMPORT_DATA` | certain | Same screen. |
| 14 | `POST /v3/import/inbound-bols` | 411 | `store/admin/mgmt/import.js:78` · (TEST) as above | `uploads/inboundBolUpload.vue:92` → same sub-tab | `WEB_UI_VIEW_IMPORT_DATA` | certain | Same screen. Note it creates Advices, but through the Import Data screen — not the Create Inbound BOL screen, so **not** `WEB_UI_VIEW_CREATE_INBOUND_BOL`. |
| **LocationController** — `/v3/location`, 4 writes (⚠ all four verb-inverted, §0.7) | | | | | | | |
| 15 | `POST /v3/location/create` | 58 | `store/masterData/storageLocation.js:118` — **calls `$put`** | `components/masterData/location/storageLocations/storageLocation.vue` → `pages/masterData/locationData/storage-locations.vue` → menu **Master Data › Location Data › Storage Locations** (`appMenuList.js:86-87`) | `WEB_UI_VIEW_STORAGE_LOCATION` | certain | Screen constant, exact name match. |
| 16 | `PUT /v3/location/update` | 77 | `store/masterData/storageLocation.js:137` — **calls `$post`** | same as row 15 | `WEB_UI_VIEW_STORAGE_LOCATION` | certain | Same screen. |
| 17 | `POST /v3/location/createLocationType` | 96 | `store/masterData/locationType.js:63` — **calls `$put`** | `components/masterData/location/locationTypes/locationType.vue` → `pages/masterData/locationData/location-types.vue` → menu **Master Data › Location Data › Location Types** (`appMenuList.js:90-91`) | `WEB_UI_VIEW_STORAGE_LOCATION_TYPE` | certain | **Different screen from rows 15–16 inside the same controller ⇒ this controller must be gated with METHOD-level annotations, not one class-level default.** |
| 18 | `PUT /v3/location/updateLocationType` | 115 | `store/masterData/locationType.js:82` — **calls `$post`** | same as row 17 | `WEB_UI_VIEW_STORAGE_LOCATION_TYPE` | certain | Same screen as row 17. |
| **PrinterController** — `/v3/printer`, 3 writes | | | | | | | |
| 19 | `POST /v3/printer/create` | 77 | `store/admin/printer.js:55` · (TEST) `admin.cy.js:727,739`, `wmsHelpers.js:1256` | `components/admin/printerSetup/editPrinter.vue:159` → `printerSetup.vue` → `pages/admin.vue:30` tab **Printer Setup** (index 5) | `WEB_UI_VIEW_PRINTER` | certain | Screen constant, exact name match. |
| 20 | `PUT /v3/printer/update` | 108 | `store/admin/printer.js:36` | `components/admin/printerSetup/editPrinter.vue:155` → same tab | `WEB_UI_VIEW_PRINTER` | certain | Same screen. Only verb-correct write in this tranche's `PUT` set. |
| 21 | `POST /v3/printer/testPrinter` | 200 | `store/admin/printer.js:103` · (TEST) `admin.cy.js:748,751`, `wmsHelpers.js:1259` | `components/admin/printerSetup/testPrinterPop.vue:41` → same tab | `WEB_UI_VIEW_PRINTER` | certain | Same screen. Sends a real print job — a discrete action, but it never leaves the Printer Setup tab, so no separate `WEB_UI_ACTION_*` is warranted. |
| **SystemPropertyController** — `/v3/systemProperty`, 3 writes (⚠ high-impact) | | | | | | | |
| 22 | `POST /v3/systemProperty/create` | 67 | `store/admin/configuration.js:129` · (TEST) `wmsHelpers.js:1163`, `admin.cy.js:233,253`, `test/store/admin/configurationPutaway.spec.js:56`, `test/components/admin/paramAndConfigPutawayBranch.spec.js:198` | `components/admin/parametersAndConfiguration/addParamAndConfig.vue:157`, reached from **all four** sub-tabs of `pages/admin.vue` tab **Parameters & Configuration** (index 1): `patternsLabels/patterns.vue:194`, `operationOptions/operationOptions.vue:245`, `systemSettings/systemSettings.vue:73`, `systemProperty.vue:162` (`parametersMain.vue:56-60`) | `WEB_UI_VIEW_SYSTEM_PROPERTY` | certain | One dialog shared by every sysprop sub-tab; `WEB_UI_VIEW_SYSTEM_PROPERTY` is the one constant covering that whole tab. |
| 23 | `POST /v3/systemProperty/updateValue` | 114 | **NONE** | — | `WEB_UI_VIEW_SYSTEM_PROPERTY` | certain | **DEAD SURFACE.** The UI edits values through SDR `$put('/sysprop/{id}')` (`store/admin/configuration.js:105,202`; `store/admin/management.js:240`). |
| 24 | `POST /v3/systemProperty/updateClient` | 145 | **NONE** | — | `WEB_UI_VIEW_SYSTEM_PROPERTY` | certain | **DEAD SURFACE**, same reason. |
| **BoxTypeController** — `/v3/boxType`, 2 writes | | | | | | | |
| 25 | `POST /v3/boxType/assignAutomationLane` | 46 | **NONE** | — | `WEB_UI_VIEW_CASE_TYPE` | probable | **DEAD SURFACE.** Writes `Boxtype.automationlaneId` (`model/Boxtype.java:24-25`); no UI exposes it. Constant per row 26. |
| 26 | `POST /v3/boxType/create` | 62 | `store/masterData/packaging.js:101` | `components/masterData/material/packaging/editPackagingDialog.vue:139` → `packaging.vue` → `pages/masterData/materialData/packaging.vue` → menu **Master Data › Material Data › Packaging** (`appMenuList.js:124-125`) | `WEB_UI_VIEW_CASE_TYPE` | **probable** | The screen is titled "Packaging" but labels its rows `item-type="'Box Type'"` (`packaging.vue:117`). `WEB_UI_VIEW_CASE_TYPE` is the **only unclaimed material-data constant** and the Packaging/Box Type screen is the **only uncovered material-data screen** — the two neighbours are already spoken for (`WEB_UI_VIEW_ITEM_UNIT` → *SKU Units*, `WEB_UI_VIEW_UNIT_LOAD_TYPE` → *Unit Load Types*). Not `certain` only because nothing in code or DB states the CASE_TYPE↔boxtype equation; **worth one `los_function` / role-grant query to confirm before landing.** |
| **ShipperIdController** — `/v3/shipperId`, 2 writes (+1 mutating GET) | | | | | | | |
| 27 | `POST /v3/shipperId/create` | 53 | **NONE** | — | **NO-FIT-NEEDS-NEW-CONSTANT** → `WEB_UI_VIEW_SHIPPER_ID` | NO-FIT | **Brief's suspicion confirmed.** Carrier master data (`name, externalId, carrier, expedited`, `Shipperid`), and **no v2 UI has a shipper-ID management screen** — an untruncated case-insensitive `shipperid` grep over both UIs' `store/ components/ pages/` finds only reads and display fields: `store/reports/inventory.js:129` (`GET /shipperid` — SDR, Inventory Report shipper filter), `components/outbound/{pickPack/parcelDetails,club/orderDetails/orderDetails,transfer/transferDetails}.vue` (`orderDetails.shipperidName`). Zero writes. No existing constant names carriers/shipper IDs. **Recommendation: delete or un-map the three write endpoints rather than gate them** — if it must be gated, `WEB_UI_VIEW_SHIPPER_ID` follows the `WEB_UI_VIEW_<NOUN>` screen convention and reserves the name for the screen that would own it. |
| 28 | `POST /v3/shipperId/update` | 73 | **NONE** | — | same as row 27 | NO-FIT | Same. |
| **SectionController** — `/v3/section`, 1 write | | | | | | | |
| 29 | `POST /v3/section/create` | 49 | `store/masterData/section.js:85` | `components/masterData/location/sections/createSectionDialog.vue:73` → `section.vue` → `pages/masterData/locationData/sections.vue` → menu **Master Data › Location Data › Sections** (`appMenuList.js:102-103`) | `WEB_UI_VIEW_SECTION` | certain | Screen constant, exact name match. ⚠ §0.4: the same screen **deletes** sections via SDR `delete('/section/{id}')` (`store/masterData/section.js:73`), which no gate can reach. |
| **AdminActionController** — `/v3/adminAction`, 1 write (⚠ operator tool) | | | | | | | |
| 30 | `POST /v3/adminAction/recoverStuckPallets` | 256 | `store/admin/mgmt/action.js:72` | `components/admin/systemManagement/recoverStuckPallets.vue:148` → `actions.vue:40,47,85` → `systemManagementMain.vue:26` sub-tab **Actions** → `pages/admin.vue` tab **System Management** (index 0) | **NO-FIT-NEEDS-NEW-CONSTANT** → screen: `WEB_UI_VIEW_SYSTEM_MANAGEMENT`; action: `WEB_UI_ACTION_RECOVER_STUCK_PALLETS` | NO-FIT | **Brief's suspicion confirmed.** No constant covers the System Management tab or its Actions sub-tab. This is not a view — it moves unitloads back to EmptyPallets, clears the To-Delete lock and rewrites labels (SBDEV-2001 backfill; javadoc at `:250-254` says "Admin-only"), i.e. an inventory mutation from an operator console. **Recommend the pair:** `WEB_UI_VIEW_SYSTEM_MANAGEMENT` as the class-level default for the tab, `WEB_UI_ACTION_RECOVER_STUCK_PALLETS` method-level here — the second follows `WEB_UI_ACTION_<VERB>_<NOUN>` and matches the existing `WEB_UI_ACTION_DELETE_UNIT_LOAD` precedent for privileged unitload writes. Do **not** reuse `WEB_UI_VIEW_DB_QUERIES` (that is the Service Log / DB-query screen, tab index 6). |
| **ReplenishmentReconciliationController** — `/v3/admin`, 1 write (⚠ operator tool) | | | | | | | |
| 31 | `POST /v3/admin/reconcile-stranded-reservations` | 38 | **NONE** (neither UI, no cypress) | — | **none — leave `@PreAuthorize(Authority.IS_SB_ADMIN)` as the sole gate** | certain | Already gated, and gated *harder* than any function: `:37` carries `@PreAuthorize(IS_SB_ADMIN)`. It is a support/curl tool with zero UI surface. `sb_admin` arrives via the Keycloak **groups** claim and is staff-only, whereas §0.4/known-issue "function gates are self-grantable via the ungated user/SDR write surface" means adding a function here would let a `wms_user` grant themselves what `sb_admin` currently withholds — i.e. a function would **weaken** it. Recommend: no `@RequiresFunction`; add it to `GUARDED` only if a function is ever added. Same reasoning applies to `AdminActionController#accessAudit` (`:341`), already `IS_SB_ADMIN`. |

**Count: 31 ungated POST/PUT/PATCH/DELETE handlers** across the 11 controllers (matches the brief's ~6/4/4/4/3/3/2/2/1/1/1 = 31).

---

#### 2. Endpoints with ZERO app callers (dead write surface) — 10 of 31

Rows 1, 8, 9, 10, 23, 24, 25, 27, 28, 31. Rows 8–10 and 23–24 are dead *because the UI writes the same data
through the SDR route instead* (§0.4) — that is the more important half of the finding. Row 31 is dead-by-design
(operator curl tool, already `sb_admin`).

Also dead, in the same controllers, though **out of scope** because the verb is GET:
`GET /v3/adminAction/triggerReleaseExpiredPickingOrdersFromUser` (:127) and
`GET /v3/adminAction/finishStuckPickingOrder/{number}` (:180) have zero callers in either UI;
`GET /v3/adminAction/triggerUpdateStock` (:113) has a store action (`store/admin/mgmt/action.js:25`) but
`admin.cy.js:150` records HAR evidence (2026-07-08) that no button reaches it.
`store/admin/management.js` as a whole has **zero component consumers** — its `/import/clients` call at `:93` is
dead store code duplicating `store/admin/mgmt/import.js:40`.

---

#### 3. Mutating GET handlers in these same controllers — out of scope by verb, in scope by risk

The brief scopes tranche 1 to POST/PUT/PATCH/DELETE. These seven change state behind a `GET` and would be left
open by a verb-scoped fix. Each already has a live UI caller, so a gate must be chosen for them too:

| Endpoint | L | Callers | Screen | Constant it should carry |
|---|---|---|---|---|
| `GET /v3/fixedAssignment/toggleActiveStatus/{id}` | 135 | `store/masterData/fixedLocation.js:111` → `fixedLocation.vue:354` | Fixed Locations | `WEB_UI_VIEW_FIXED_ASSIGNMENT` |
| `GET /v3/printer/delete/{printerId}` | 142 | `store/admin/printer.js:74` → `printerSetup/deletePrinterPop.vue:47` | Printer Setup | `WEB_UI_VIEW_PRINTER` |
| `GET /v3/printer/setDefault/{printerId}` | 171 | `store/admin/printer.js:86` → `printerSetup/printerSetup.vue:223` **and** `admin/shippers/shipperList.vue:180` | Printer Setup **+ Shippers** | ⇒ **the only ANY-of candidate in tranche 1**: `{WEB_UI_VIEW_PRINTER, WEB_UI_VIEW_CLIENT}`. ⚠ note `shipperList.vue:180` passes `{ id: shipper.id }` while the store reads `data.printerId` → the URL is `/printer/setDefault/undefined`; that caller is broken today, so a `WEB_UI_VIEW_PRINTER`-only gate would look fine in QA and 403 the Shippers path once the arg bug is fixed. |
| `GET /v3/printer/printLabel/{labelKey}` | 230 | `store/admin/configuration.js:224` → `parametersAndConfiguration/patternsLabels/printLabelPop.vue:43` | Parameters & Configuration › Patterns and Labels | `WEB_UI_VIEW_SYSTEM_PROPERTY` (the sysprop tab it is dispatched from), **not** `WEB_UI_VIEW_PRINTER` — the caller is not on the printer screen |
| `GET /v3/shipperId/delete/{shipId}` | 93 | **NONE** | — | dead; see row 27 |
| `GET /v3/adminAction/triggerOrderReplenish` | 105 | `store/admin/mgmt/action.js:15` → `systemManagement/actionConfirmation.vue:65` | System Management › Actions | `WEB_UI_VIEW_SYSTEM_MANAGEMENT` (new) |
| `GET /v3/adminAction/triggerArchiveMessages` | 120 | `store/admin/mgmt/action.js:35` → `actionConfirmation.vue:71` | System Management › Actions | `WEB_UI_VIEW_SYSTEM_MANAGEMENT` (new) |
| `GET /v3/adminAction/testCrmConnectivity` | 134 | `store/admin/mgmt/action.js:45` → `actionConfirmation.vue:76` | System Management › Actions | `WEB_UI_VIEW_SYSTEM_MANAGEMENT` (new) |

---

#### 4. The three high-scrutiny cases, answered

**4.1 `SystemPropertyController` — does a function add anything over `SecurityConfiguration:157-159`?**
`SecurityConfiguration:156-159` restricts `/v3/adminAction/**`, `/v3/sysprop/**`, `/v3/systemProperty/**`,
`/v3/printer/**`, `/userDetailsById/**`, `/userGroup/**`, `/user/**` to `hasAnyAuthority(Authority.WMS_USER_ROLE)`.
That is **not a coarser gate — it is the same gate as everything else**: line 152 gives all of `/v3/**` the
identical `hasAnyAuthority(WMS_USER_ROLE)`. So the "Admin-Only WMS Endpoints" block C is, today, **completely
redundant with block D** and confers no extra restriction on sysprop writes whatsoever. Every warehouse operator
holding `wms_user` can reconfigure `los_sysprop` globally.
**⇒ Yes, a function adds a real restriction here — it is currently the *only* thing that would.** Two caveats
that decide how much it buys: (a) the live edit/delete path is SDR `PUT`/`DELETE /v3/sysprop/{id}` (§0.4), so
gating `SystemPropertyController` alone closes only the create path — the sysprop **row 22 gate is worth landing
but is not the sysprop fix**; and (b) function gates are self-grantable while the user/role write surface stays
open, so this is defence-in-depth, not containment. Recommend landing `WEB_UI_VIEW_SYSTEM_PROPERTY` on all three
methods **and** raising the `/v3/sysprop/**` SDR write surface as its own slice.

**4.2 `AdminActionController` + `ReplenishmentReconciliationController` — operator tools needing a new admin
constant?** Split verdict. `ReplenishmentReconciliationController` needs **nothing**: it already carries
`@PreAuthorize(IS_SB_ADMIN)`, has no UI, and a function would be weaker than what it has (row 31).
`AdminActionController` **does** need a new constant: its four live buttons and the stuck-pallet recovery dialog
all sit on **Admin › System Management › Actions**, a screen with no constant in the 81. Proposed:
`WEB_UI_VIEW_SYSTEM_MANAGEMENT` (class-level default for the tab) + `WEB_UI_ACTION_RECOVER_STUCK_PALLETS`
(method-level on row 30, since it mutates inventory). Both follow the stated conventions.

**4.3 `FileImportController` — is `WEB_UI_VIEW_IMPORT_DATA` right, and is import OMS-driven?** Right, and no.
All four callers live in `components/admin/systemManagement/uploads/` behind the sub-tab literally named
"Import Data" (`systemManagementMain.vue:29`); the constant name is an exact match. Import is **not** OMS-driven:
OMS's inbound surface is `/rest/**` (`AdviceRestController`, `SkuRestController`, `OrderRestController`, …),
which `SecurityConfiguration:151` `permitAll`s and which `IdempotencyFilter` protects; there is no `/rest` twin
of `/v3/import/*` and no non-UI caller anywhere. Gating it cannot break an OMS integration.

---

#### 5. Landmines for whoever implements this

1. **`LocationController` cannot take a single class-level default** — rows 15–16 belong to *Storage Locations*
   and rows 17–18 to *Location Types*, two different menu entries with two different constants (§0.7 also means
   all four are 405 today; fix verbs and gate together, or the gate is untestable through the UI).
2. **`PrinterController#setDefault` is the one ANY-of** in this tranche (§3) — and its second caller is currently
   broken, so the need is invisible in manual QA.
3. **Do not annotate `AdminController`** (§0.5) — 43 controllers inherit from it.
4. **Adding a class to `GUARDED` is what makes a *future* unannotated handler fail closed** — the class-level
   `@RequiresFunction` alone does not (`FunctionGuardStartupAssertion.java:73-103`). Every controller gated here
   should also join `GUARDED`, except any shared/base class.
5. **`setupMockMvc`-style tests install no interceptor**, so a gate test written that way is vacuous; only
   `StandaloneMockMvcBuilder#addInterceptors` exercises the guard (`FunctionGuardInterceptor.java:46`).
6. **Two new constants and one reserved name** are needed: `WEB_UI_VIEW_SYSTEM_MANAGEMENT`,
   `WEB_UI_ACTION_RECOVER_STUCK_PALLETS`, and (only if `ShipperIdController` is kept) `WEB_UI_VIEW_SHIPPER_ID`.
   Each needs a Flyway `los_function` seed + role grants, and `los_sysprop.description` is `varchar(255)` —
   an over-long seed aborts the whole migration file.
7. **One open question worth a DB query before landing:** confirm `WEB_UI_VIEW_CASE_TYPE` ↔ the Packaging /
   Box Type screen (row 26) against `los_function` / existing role grants. Everything else in the table is
   `certain`.

---

## 2. Fix design

### 2.1 Mechanism — already in place, nothing new to build

Slice A (PR #187, `5b704e5`) made the enforcement point work: `WebConfig#functionGuardMappedInterceptor`
registers `FunctionGuardInterceptor` as a `@Bean MappedInterceptor`, which every `AbstractHandlerMapping`
initialised in an ApplicationContext collects via `detectMappedInterceptors`. This tranche adds **annotations
only** — no interceptor change, no new mechanism.

Resolution is on `handlerMethod.getMethod().getDeclaringClass()`, and a **method-level annotation wins over the
class-level one**. That is what makes per-class-with-carve-outs expressible: annotate the class for the common
case, annotate the exceptional methods individually.

### 2.2 Placement rules

| shape | placement |
|---|---|
| every handler on the class shares one function | class-level `@RequiresFunction` |
| class is mixed (`ReportController`, `CustomerOrderController`) | method-level on each, **no** class-level |
| both UIs call it (`ReplenishOrderController`) | method-level ANY-of; a class-level gate breaks mobile |
| OMS calls one endpoint (`Client`, `BoxType`) | method-level on the non-OMS endpoints only; leave `/create` ungated with a comment naming §0.C |
| shared base class (`AdminController`) | **never** — see §0.H |

⚠️ **Do not add any of these 23 controllers to `FunctionGuardInterceptor.GUARDED`.** Membership makes an
*unannotated* handler on that class fail closed, which would 403 every ungated **read** on the same class —
122 of them across the tranche's controllers. The fail-closed set is for classes whose entire surface is gated.
`StockUnitController`/`UnitLoadController` are the precedent: gated by method, deliberately outside `GUARDED`.

### 2.3 New constants — two, plus one deferred

| constant | for | placement |
|---|---|---|
| `WEB_UI_VIEW_SYSTEM_MANAGEMENT` | the Admin › System Management tab, class-level default on `AdminActionController` and `ReplenishmentReconciliationController` | new |
| `WEB_UI_ACTION_RECOVER_STUCK_PALLETS` | `POST /v3/adminAction/recoverStuckPallets` — mutates inventory (moves unitloads to EmptyPallets, clears the To-Delete lock, rewrites labels) from an operator console | new, method-level |
| ~~`WEB_UI_VIEW_SHIPPER_ID`~~ | deferred — `ShipperIdController` is excluded from this tranche (§0.C) | not added |

Everything else maps to an existing constant, taken from `appMenuList.js` (§0.F).

### 2.4 The Flyway migration — `V2.2.22`

**Version.** Swept across **all remote branches**, not a local `ls`: highest anywhere is `V2.2.21`. Per this
repo's own rule, re-run the collision check immediately **before merge**, not now — a correct point-in-time
sweep has already missed a branch pushed later on this codebase.

**Declaring the Java constant is not enough.** `AccessService.updateFunctionList()` reflects over
`WmsConstants.FunctionEnum` and creates missing `mywms_function` rows, but its only callers live in
`UtilRestController`, which is annotated `@Service`, **not** `@RestController` — its `@RequestMapping` methods
do not route at all, so `initDB` never runs on a provisioned tenant. Every new constant needs an explicit
`INSERT`.

**Shape**, verified against `information_schema` on `wms2-wineco-dev` 2026-08-24. Eight columns; `number`,
`version`, `function`, `client_id` are **NOT NULL with no default** (as is `id`). An INSERT naming only
`(id, name)` raises 23502, which aborts the entire file and freezes that tenant's Flyway chain — silently,
because tenant migration failures never abort boot. All varchar columns are 255, so constant names cannot
truncate.

🔴 **A hazard `V2.2.19` did not face.** It added **one** constant using
`COALESCE((SELECT MAX(id) FROM mywms_function), 0) + 1`. This file adds **two**, so it must be **two separate
`INSERT … SELECT` statements**, each recomputing `MAX(id)` and each with its own `WHERE NOT EXISTS` guard on
`function` (the UNIQUE column — guarding `name` would be correct only by accident). A single multi-row insert
hands every row the same id. On `wms2-wineco-dev` that raises 23505 (`mywms_function_pkey` on `id`,
`uk_hxqe1tp0v5sk4le8ij6wmtrq1` on `function`, both verified via `pg_constraint`), but this fleet has measured
constraint-shape drift — the authorization join tables carried three different shapes and production had
neither a PK nor a unique index — so on a tenant missing the PK it would **insert silently**.

**Grants.** `INSERT … WHERE NOT EXISTS` keyed by role **name**, never `ON CONFLICT` (three constraint shapes in
the fleet; column inference raises 42P10 where none exists). A missing role is skipped silently by design, so
**a clean run is not proof the grants landed** — run the per-tenant verification query at the foot of the file.
Grant target for both new constants: `super-admin` only. `recoverStuckPallets` is documented "Admin-only" and
no non-super-admin persona has an operator console today.

### 2.5 The six deletions

Separate commit from the gates, same PR. Each deletion removes the handler and any now-unreferenced service
method reachable only from it. `closeIntraCompanyTransfer` additionally frees
`billofladingService.finishTransfer` **only if** no other caller exists — check before removing.

### 2.6 Out of scope, stated so this tranche is not mistaken for more than it is

- The 307 SDR searches and 62 exported repositories (tranche 3, and the ticket's Class A).
- The 122 ungated MVC **reads** (tranche 3).
- `/rest/**` — `permitAll()` in `SecurityConfiguration:150-154`, so **unauthenticated**, not merely ungated. 15
  writes. Owned by `260520-rest-security-permitall-hardening`, blocked on OMS sending a Keycloak JWT.
- `ShipperIdController`, `/v3/client/create`, `/v3/boxType/create` — OMS-called (§0.C).
- `LocationController`'s verb inversion — a real bug (four 405s) but a bug, not authorization. Gate the four as
  they stand and pin the gate so a later verb fix cannot land an ungated write (§4, T-6).

---

## 3. Prerequisites

| # | prerequisite | state |
|---|---|---|
| 3.1 | slice A — the `MappedInterceptor` enforcement point | ✅ MERGED `5b704e5` (PR #187) |
| 3.2 | slice C — `bulkTransferStock` gate; establishes the single/bulk equality convention and AC-4d | ✅ MERGED `e44e972` (PR #189) |
| 3.3 | `appMenuList.js` as the constant source of truth + the route guard | ✅ on `wms2-web-ui@origin/develop` |
| 3.4 | `WEB_UI_VIEW_PARCEL_PICKING` exists and is seeded | ✅ API develop + `V2.2.19` |
| 3.5 | Confirm the `/v3/dashboard/*` aliases with curl (§0.H) | ⬜ open — only a curl proves a mapping here |
| 3.6 | Confirm `LocationController`'s four 405s with curl (§0.B) | ⬜ open |

---

## 4. Test plan

The floor applies at every tier and is not negotiable: one DB query per claim, a failing test first that fails
for the right reason, **every new assertion mutation-checked**, one independent review lane that did not author
the change, and the full suite compared to the known baseline (2 failures — `OptionalSafetyArchTest`,
`MobilePalletizingServiceTest`) **by name**.

| # | test | must fail before, pass after |
|---|---|---|
| T-1 | for each gated endpoint, a caller holding none of its functions gets **403**, and `AccessService` is **verified consulted** — asserted *before* the status, since "403" is meaningless if the gate never ran | yes |
| T-2 | a caller holding the function is **not** 403'd (the don't-over-gate rail) | passes throughout |
| T-3 | every constant used equals the one `appMenuList.js` declares for that screen — read from the file, not duplicated | yes, on divergence |
| T-4 | the GET and POST members of each shared dialog (`closeInboundBol`, `closeOutboundBol`, `acceptHubAndSpokeBol`) carry the **same** function set — the §0.B invariant, and the AC-4d analogue | yes |
| T-5 | no controller in this tranche joins `GUARDED`, and `AdminController` carries no annotation (§0.H) | yes |
| T-6 | `LocationController`'s four handlers carry their gate **regardless of verb** — asserted on the method, not the mapping, so a later verb fix cannot land an ungated write | passes; guards the future |
| T-7 | the two new constants appear in `WmsConstants.FunctionEnum` **and** the migration inserts both, as two separate statements (§2.4) | yes |
| T-8 | `mvn test` full suite == baseline by name | — |

⚠️ Gate tests must use `setupMockMvcWithGuard`, never `setupMockMvc`: `standaloneSetup` installs no interceptor,
so a gate test written without `.addInterceptors(...)` is vacuous by construction. And set a
`SecurityContextHolder` Authentication — without one, `currentUsername()` is null, `anyString()` does not match
null, the stub never applies, and the guard NPEs on a null `AccessDecision`, which a broad catch will record as
a non-403. That defect shipped in a first draft on slice C and reported the production bug while measuring its
own broken harness.

---

## 5. Risks

| # | risk | mitigation |
|---|---|---|
| R1 | a wrong constant makes a **screen** unreachable (the route guard fails closed), not just a button 403 | constants read from `appMenuList.js`; T-3 |
| R2 | gating an OMS-called `/v3` endpoint breaks facility sync | §0.C exclusions; T-1 covers only non-OMS endpoints |
| R3 | a "dead" verdict is wrong and a deletion breaks a live screen | two already were (§0.D); all six re-verified cross-repo with GNU grep; deletions in a separate commit for a clean revert |
| R4 | the semantically-obvious constant excludes the role holding the screen | §0.G; every row checked against live grants |
| R5 | tenant Flyway failure is silent — it never aborts boot | check `flyway_schema_history` on **every** tenant post-deploy, not just the one tested |
| R6 | merging to `develop` is a dev deploy **and** runs Flyway | land the collision check immediately pre-merge; no CI on PRs here, so the merge is the test |
| R7 | this tranche gates the audited route, not the capability — SDR still reaches the same data | stated in §0.H and §2.6; do not close SBDEV-3017 on this tranche |

---

## 6. Acceptance criteria

- **AC-1** Every state-changing ungated MVC endpoint in the §1 tables either carries a function, is deleted
  (§0.E), or is explicitly excluded with the reason named in-code.
- **AC-2** No endpoint carries a constant that diverges from `appMenuList.js` (T-3).
- **AC-3** Each shared GET/POST dialog pair carries one identical function set (T-4).
- **AC-4** The two new constants exist in `FunctionEnum` **and** in `V2.2.22`, as two separate INSERTs, and the
  grant verification query has been run per tenant.
- **AC-5** No controller joined `GUARDED`; `AdminController` unannotated.
- **AC-6** Full suite == baseline by name; every new assertion mutation-checked.
- **AC-7** `middleware/require-function.js`'s "structurally unreachable" comment corrected (§0.F).
- **AC-8** Six deletions landed in their own commit, and no service method left orphaned.

---

## 7. Provenance

- Census: reflective over `develop@5b704e5`. Three parallel mapping lanes (§1), each cross-checked against the
  others — which is how both false-dead findings in §0.D were caught.
- DB: `wms2-wineco-dev` 2026-08-24 — `mywms_function` shape via `information_schema`, constraints via
  `pg_constraint`, grant populations per constant.
- Decisions §0.A taken by Nam 2026-08-24 after the census; the per-class choice supersedes the ticket's AC and
  the reason is recorded there.
- ⚠️ Not yet done: no review lane has read this plan, and no implementation exists.

---

## 8. REVISION 1 — 2026-08-24, after three review lanes (8 High / 13 Medium)

This section **supersedes** the sections it names. It is appended rather than edited in place so the corrections
are auditable: on this ticket five design decisions have already been revised, and a reader needs to see which
claim replaced which.

### 8.1 The sixth error: §0.G was a rule I did not apply

§0.G says *"every row must be checked against live grants, not against the constant's name."* It was applied to
**41 of ~97 rows**. Running it on the rest breaks three, one of them an outage. The missing evidence,
`wms2-wineco-dev` 2026-08-24 — note the distinction between **named** roles (real personas) and numeric
`ROLE0000xx` rows, which is where §0.G's own flagship example turned out to be half wrong (F9):

| function | roles | named roles |
|---|---|---|
| `WEB_UI_ACTION_PRINT_TOTE_LABELS` | 3 | **`super-admin` only** |
| `WEB_UI_VIEW_PARCEL_PICKING` | 8 | inventory-manager, outbound-manager, super-admin |
| `WEB_UI_VIEW_ORDER_MONITOR` | 3 | CS-REP, outbound-manager, super-admin |
| `WEB_UI_VIEW_PRINTER` | 3 | **`super-admin` only** |
| `WEB_UI_VIEW_CLIENT` | 3 | **`super-admin` only** |
| `WEB_UI_VIEW_IMPORT_DATA` | 4 | **`super-admin` only** |
| `WEB_UI_VIEW_SYSTEM_PROPERTY` | 1 | super-admin |
| `WEB_UI_VIEW_INBOUND_BOL` / `_GOODS_RECEIPT_POSITION` | 6 | CS-REP, receiving, super-admin |
| `WEB_UI_VIEW_RECEIVING` / `_REPLENISHMENT_ORDER` | 2 | receiving, super-admin |
| `WEB_UI_VIEW_ORDER` / `_ORDER_BATCH` | 3 | CS-REP, outbound-manager, super-admin |
| `WEB_UI_VIEW_BILL_OF_LADING` | 4 | CS-REP, outbound-manager, super-admin |
| `WEB_UI_VIEW_CLUB_LINE` | 5 | CS-REP, outbound-manager, super-admin |
| `WEB_UI_VIEW_TRANSFER_ORDER` | 3 | inventory-manager, outbound-manager, super-admin |
| `WEB_UI_VIEW_CONTAINER` | 6 | CS-REP, inventory-manager, super-admin |
| `WEB_UI_VIEW_STOCK_UNIT` / `_CYCLECOUNT` / `_FIXED_ASSIGNMENT` / `_INVENTORY_RECORD` / `_CASE_TYPE` / `_SECTION` / `_STORAGE_LOCATION` | 2–5 | inventory-manager, super-admin |
| `WEB_UI_VIEW_PARCEL_MONITOR` / `_FLOWBIN_MONITOR` | 4–5 | CS-REP, inventory-manager, outbound-manager, super-admin |

### 8.2 🔴 Rows 10 and 12 are an OUTAGE as written — corrected

`POST /v3/report/reprintLabels` and `POST /v3/dashboard/printToteLabels` were assigned
`WEB_UI_ACTION_PRINT_TOTE_LABELS`. **Named-role intersection with the screens that reach them is
`super-admin` alone.** On merge — a dev deploy — an `outbound-manager` printing tote labels from the Pick&Pack
monitor gets a 403 rendered by `store/dashboard/pickpackMonitor.js` as *"Error: Request failed due to a network
or server issue. Please retry."* That is how tote labels are printed on the floor.

**Corrected:** gate both on the **screen** constants — `WEB_UI_VIEW_PARCEL_PICKING` (row 10) and
`WEB_UI_VIEW_ORDER_MONITOR` (row 12) — and drop the action distinction. Row 10's own lane caveat already
offered this. The alternative (grant `PRINT_TOTE_LABELS` to the 5+ reaching roles in `V2.2.22`) is rejected:
it widens a constant that gates nothing today in order to preserve a distinction nobody has asked for.

⚠️ §1.1's grant-warning 4 — *"treat the function as held by nobody"* — is **false** and must not be relied on.

### 8.3 §2.2's ban on `GUARDED` membership was right for the wrong reason — and `@PublicHandler` changes the end state

§2.2 said membership would *"403 every ungated read on the same class — 122 of them."* **That is not the
mechanism.** `FunctionGuardStartupAssertion` (`SmartInitializingSingleton#afterSingletonsInstantiated`) walks
every deployed handler and **throws `IllegalStateException`** if a handler on a `GUARDED` class resolves no
annotation. So:

- class-level annotation + `GUARDED` → no violation; `findAnnotation` resolves for every handler, reads included
- **method-level-only + `GUARDED` → the application does not start**

With no CI on PRs and the `@SpringBootTest` lane down, **the merge to `develop` is the boot**. An implementer
following §1.2's reproduced landmine 4 (*"every controller gated here should also join GUARDED"*) or §1.1's
warning 6 takes wms2-api dev down, after the Flyway run the same merge triggers. **Strike both**, or annotate
them with this correction.

**FOLD-IN — `@PublicHandler` landed on develop 2026-08-24** (SBDEV-3063, PR #190, `d83b72a`), and it changes the
target state. It marks a handler deliberately reachable without a grant: method-level only, mandatory
`reason()`, mutually exclusive with `@RequiresFunction` (both → `CONFLICTING_ANNOTATIONS`, denied), resolved
*before* any `@RequiresFunction` lookup, pinned by an arity-keyed allow-list and its own `wms2.authz.public`
counter. `GUARDED` is now **fourteen** controllers — `UserController` joined using exactly this hatch.

So the correct end state is **the opposite of §2.2's blanket ban**: these classes *should* join `GUARDED`, with
`@RequiresFunction` on the gated handlers and `@PublicHandler` on whatever stays deliberately open. That makes
them fail closed, which is the entire point of the set.

**But not in this tranche.** Joining now means every one of the ~122 reads on these classes needs an annotation
immediately — and `@PublicHandler`'s `reason()` is reviewed security text, so marking a read "public" that
tranche 3 will then gate is churn plus a misleading committed justification. **Revised rule: stay out of
`GUARDED` for tranche 1 (for this reason, not §2.2's), and join as part of tranche 3 when the reads are
decided.** Record it as an explicit AC of tranche 3 so it is not lost.

⚠️ Note also what `@PublicHandler`'s own javadoc says about this ticket: *"Does not generalise to Spring Data
REST… SBDEV-3017 needs a path/domain-type allow-list, not this marker."* That is the Class A design constraint,
stated by the mechanism's author.

### 8.4 §2.3 breaks the `sb_admin` support tool and gates its own rollout instrument — corrected

§2.3 made `WEB_UI_VIEW_SYSTEM_MANAGEMENT` a **class-level default** on `AdminActionController` *and*
`ReplenishmentReconciliationController`, contradicting §1.3 row 31, which says in bold to leave
`@PreAuthorize(Authority.IS_SB_ADMIN)` as the sole gate.

The interceptor runs in `preHandle`, i.e. **before** method security, and `AccessService.checkAnyAccess` returns
`USER_NOT_PROVISIONED` for any Keycloak identity with no `mywms_user` row — which is exactly what `sb_admin`
is (a staff identity arriving via the groups claim). A class-level default also lands on
`AdminActionController#accessAudit`, the endpoint whose javadoc says it exists because *"who loses access when
this ships?"* was previously unanswerable.

**Corrected:** exclude `ReplenishmentReconciliationController` entirely. On `AdminActionController` put the
constant **method-level** on the live trigger GETs plus `recoverStuckPallets`, and **explicitly not** on
`accessAudit` or `listRecoverableStuckPallets`.

### 8.5 AC-2 / T-3 replaced — it could never go green

AC-2/T-3 required every constant to match `appMenuList.js`. **≥7 of the plan's own rows diverge, and most are
correct** (create/view splits, action constants, sub-tabs the menu does not model). A check that cannot go green
against correct code is worse than none — row-hygiene rule 5.

**Replaced by the invariant that actually protects operators:**

> **AC-2′ / T-3′ — for every gated endpoint, every role that can reach the dispatching screen must hold at
> least one function in that endpoint's set.** Evaluated against per-tenant grant data.

That catches §8.2 and the two Medium grant findings. AC-2 as written catches none of them and fires on four
rows that are right.

### 8.6 The census missed whole controllers — boundary vs AC-1

§0.B's boundary is *"every ungated endpoint whose handler mutates state"*; AC-1 narrows to *"in the §1 tables"*.
The gap is real. Absent from the plan entirely, all ungated, all mutating, verified by reading the handler:

| endpoint | note |
|---|---|
| `GET /v3/clubLine/runClubLine/{orderBatchId}` | `customerorderBatchService.runClubLine` — runs a whole batch |
| `GET /v3/clubLine/{assignStagingLane,unlinkStagingLane,activateBatch}/…` | ×3 |
| `GET /v3/transfers/runTransfer/{orderId}` | `billofladingService.transferOrder` — runs a whole transfer |
| `GET /v3/transfers/{assign,reassign,unlink}TransferLane/…`, `/activateTransferOrder/…` | ×4 |
| `GET /v3/itemData/setPutAwayLocation/{itemdataid}/{locationid}` | `putawayConfigService.setSkuDestination` |
| `GET /v3/pickingOrderPosition/fixPickingPosition/{id}` | |
| `UserAdministrationController` (2 writes), `TokenController` (1) | verb-writes the plan never names |

**AC-1 is rewritten to the boundary, not the tables:** *every ungated state-changing MVC endpoint on
`develop`, enumerated at implementation time and reconciled against §1.* `ItemDataController` is 0-write/8-read
by verb, so a verb-scoped **or** table-scoped sweep misses `setPutAwayLocation` twice over.

### 8.7 Counts corrected, and one internal contradiction

| §0 claim | corrected |
|---|---|
| 307 exported searches | **304** |
| +52 already `exported = false` | **57** |
| 318 MVC handlers | **361** all buckets / **340** on `/v3` |
| 218 ungated | **250** / **229** on `/v3` |
| 96 verb-writes | **99** on `/v3` — and §0.B calls the same figure **81** |
| 122 reads | **130** on `/v3` |
| 525 total | **536** |
| ~13 mutating GETs | **~24** (the plan's own list has 12) |
| 10 `/export*` reads | **13** |
| ~84 in tranche | **≈92–97** with corrected inputs |

None changes a decision; all of them change whether the next reader trusts the document.

### 8.8 §0.B's headline example is false — the conclusion survives, the argument does not

`closeBolPop.vue` does **not** select GET-single vs POST-multi on `selectedItems.length`. It selects on a
**`mode` prop, hard-coded per parent**. The re-scope conclusion still holds — the two verbs reach one capability
and must carry one function set, or one parent's path 403s while the other works — but the mechanism is
"different parents mount the same dialog in different modes", not "one button branches on selection count".

Worse: **`acceptHubAndSpokeBol` has exactly one mapping** (a GET). T-4 and AC-3 name a GET/POST pair that does
not exist, so that third of T-4 **passes vacuously**. Restrict T-4 to `closeInboundBol` and `closeOutboundBol`,
whose pairs are real.

### 8.9 Residual reachability is ~19, not 3 — and it reorders the tranches

§0.H admits three cases where the UI's live write path is already SDR. Measured: **every tranche-1 entity keeps
a live, un-withdrawn SDR write verb** — ~19 rows where the gate closes nothing real. `RestConfiguration`
withdraws write verbs for exactly two domain types (four after PR #191), and `SdrWriteExposureUnitTest`'s
`unrelatedDomainTypeIsUntouched` asserts POST *stays* available for everything else: read-only-by-default is
deliberately **not** the posture.

**Consequence for sequencing.** §0.A.2 chose writes-first on the reasoning that writes are the real risk. That
reasoning does not survive: for the master-data half this tranche is largely theatre while SDR reaches the same
rows. Meanwhile the review found a **live escalation path** in exactly that SDR surface — now
[SBDEV-3077](https://app.clickup.com/t/868kw6fmx), fixed in wms2-api PR #191 (four `forDomainType`
withdrawals on the access-decision chain).

**Recommendation: Class A (SDR) leads slice B, not the MVC tranche.** PR #191 is its first piece. This document
stays the MVC tranche's plan and should be re-sequenced behind it, not implemented next.

### 8.10 What remains open in this plan

Not yet done, and each blocks implementation:

1. Re-run the §8.1 grant check across **all** rows (41 of ~97 done) and apply AC-2′.
2. Reconcile §1's tables against the §8.6 boundary — the missing controllers need mapping rows.
3. Decide `POST /v3/unitLoad/reprintLabel`: lane-proposed ANY-of `{CONTAINER, CLUB_LINE, TRANSFER_ORDER}`
   versus a new `WEB_UI_ACTION_REPRINT_UNIT_LOAD_LABEL`. Note `WEB_UI_VIEW_CONTAINER` has 6 roles while the
   Handling Units menu leaf is ANY-of `[STOCK_UNIT, CONTAINER]` — so the ANY-of needs the §8.1 check too.
4. `ShipperIdController`'s **third** mutating handler, `GET /v3/shipperId/delete/{id}`: the §0.C blanket
   exclusion orphans it permanently.
5. `/rest/**` reaches three of this tranche's capabilities **unauthenticated** — including `advice/create`.
   Cross-reference `260520-rest-security-permitall-hardening` per endpoint rather than as a blanket exclusion.
6. Three of §1's lane tables reason from *"the web UI has no function gating"*, which §0.F declares false. The
   rows were **chosen** under that model, so the mapping needs re-reading against the live route guard.

### 8.11 WIDENED 2026-08-25 — the putaway-destination write surface joins this tranche

Added while triaging **SBDEV-2956 / SBDEV-2960** (children of SBDEV-2643). Decision by Nam: move the
Default Putaway Location writes off `sb_admin` onto a new `WEB_UI_ACTION_*` function. Widening this
plan rather than filing a ticket — §8.6 already names one of these endpoints, so it is the same fix
visit.

#### 8.11.1 🔴 CORRECTION to §8.6 — `setPutAwayLocation` is NOT ungated

§8.6's table lists `GET /v3/itemData/setPutAwayLocation/{itemdataid}/{locationid}` among endpoints that
are *"all ungated, all mutating, verified by reading the handler."* **It carries
`@PreAuthorize(Authority.IS_SB_ADMIN)` at `ItemDataController.java:105`**, immediately above the
mapping at `:106`, and has since SBDEV-2732 §3.5 rerouted it through `PutawayConfigService`. The row's
*"mutating"* and *"census missed it"* halves stand; the *"ungated"* half is wrong and must not be used
to justify a gate-from-nothing change. Everything else in that table was not re-checked this pass.

#### 8.11.2 The surface, measured on `origin/develop` (wms2-api `353a348`)

| endpoint | gate today | line |
|---|---|---|
| `PUT /v3/putawayConfig/sku/{itemdataId}` | `@PreAuthorize(IS_SB_ADMIN)` | `PutawayConfigController:182-183` |
| `PUT /v3/putawayConfig/merchant/{clientId}` | `@PreAuthorize(IS_SB_ADMIN)` | `:214-215` |
| `PUT /v3/putawayConfig/warehouse` | `@PreAuthorize(IS_SB_ADMIN)` | `:232-233` |
| `GET /v3/itemData/setPutAwayLocation/{itemdataid}/{locationid}` | `@PreAuthorize(IS_SB_ADMIN)` | `ItemDataController:105` |
| service layer: `setSkuDestination` / `setMerchantDestination` / `setWarehouseDestination` / `validateOnly` | `@PreAuthorize(IS_SB_ADMIN)` ×5 | `PutawayConfigService:96,128,165,257,287` |
| `GET /v3/putawayConfig/eligibleLocations`, `GET /v3/putawayConfig/preview`, `GET /v3/itemData/{id}/effectivePutawayDestination` | **ungated, deliberately** — reads; SBDEV-2643 AC1 requires read-only users to see the configured value | `:124`, `:144`, `ItemDataController:235` |

So this is a **gate MOVE, not a gate ADD** — the opposite shape from the rest of tranche 1. Nothing here
is currently reachable by a non-staff user.

#### 8.11.3 Why move it at all

`sb_admin` is the SiteBoss super-admin on the Keycloak `groups` claim — staff only. SBDEV-2643's own
Permissions section specifies *"users with appropriate warehouse inventory or configuration
permissions,"* a different axis. Net effect today: no customer user can configure a putaway destination
at any tier, and the feature built to replace direct DB edits still needs SiteBoss for every change
(measured on `dev_wh01_om1`: 3 typed writes in `putaway_config_audit`, all one operator; 8,803 of 8,805
SKUs unconfigured). This also matches §1.1's target state — `sb_admin` as identity only, never enforced.

#### 8.11.4 Row 31's objection, re-measured — it has largely expired

Row 31 argues a function gate would be **weaker** than `sb_admin`, because function gates are
self-grantable through the ungated user/SDR write surface. Re-measured on `origin/develop` 2026-08-25:

- 🔴 **CORRECTED 2026-08-25.** The first draft of this bullet claimed those five repositories are
  **`exported = false`**. THEY ARE NOT — all five carry a plain `@RepositoryRestResource(...)` with no
  `exported` attribute; what is `exported = false` in each file is a handful of individual `@Query`
  methods. The error was a per-file `grep -oE "exported *= *(false|true)"` whose **method-level** hits
  were read as class-level. `UserRoleRepository.java:28` warns against exactly this mistake.
  The conclusion survives by a DIFFERENT and NARROWER mechanism: write verbs on hops 1–3 are withdrawn
  by per-domain-type `ExposureConfiguration` in `RestConfiguration.java:64-215`. Narrower because
  (`:196-215`) `UserGroup` item disables only `PATCH`+`DELETE` — `PUT /v3/userGroup/{id}` stays live and
  the collection `POST` is not withdrawn at all; same for `UserRole`. That file's own javadoc
  (`:174-177`): *"Do not read this as closing every route to a function grant."*
- `UserController.saveUserGroups` is gated (SBDEV-2870); its javadoc states that without it *"every
  function-based gate in the application is bypassable in ONE request."*
- 🔴 **CORRECTED 2026-08-25.** The first draft claimed *"SDR is now inside the gate via
  `WebConfig#functionGuardMappedInterceptor`."* That is the OPPOSITE of what the code says.
  `FunctionGuardInterceptor.java:87-92`, verbatim: *"Reaching an SDR request is not the same as gating
  it. An SDR handler's declaring class is `RepositorySearchController` or `RepositoryEntityController`
  … absent from `GUARDED` — so such a request falls through allowed, exactly as before. … Do not read a
  green suite as evidence that SDR is gated: it is reachable, and still open."* The interceptor REACHES
  SDR; it does not GATE it. `GUARDED` (`:112-144`) is 15 named MVC controller classes, no SDR class.
  Consequence: `functionGuardMappedInterceptor` gives **zero** protection to `UserFunctionRepository`.

**Residual, and it is a prerequisite of this widening:** `UserFunctionRepository`
(`repo/jpa/UserFunctionRepository.java`) is the only access-chain repository with **no `exported` flag,
so it is SDR-exported by default**. It is the function *catalogue*. Gates resolve by NAME, so renaming a
function the caller already holds to the new action's name impersonates it. Close it (`exported = false`,
or GUARDED membership) in the same change, or the new gate has a rename-shaped hole that `sb_admin`
does not.

Row 31's conclusion for `reconcile-stranded-reservations` and `accessAudit` is untouched — those are
curl-only staff tools with no UI, and the reasoning there still holds.

#### 8.11.5 🔴 MERGE-ORDER CONSTRAINT — removing `@PreAuthorize` early un-gates prd

`@RequiresFunction` is enforced by `FunctionGuardInterceptor`, which **does not exist on `main`**. If
this change reaches prd ahead of the interceptor, the annotation is **inert** and these four endpoints
go from `sb_admin`-gated to completely ungated in production — a regression, not a hardening.

**Rule: the `@PreAuthorize(IS_SB_ADMIN)` lines come off only in the release that carries
`FunctionGuardInterceptor` to prd.** Until then both annotations stay, and the function gate is the
develop/UAT-active one. A test must pin this — a negative asserting `@PreAuthorize` is still present
is the only thing standing between a tidy-up commit and an ungated production endpoint.

#### 8.11.6 The function and its grants

One constant, `WEB_UI_ACTION_SET_PUTAWAY_DESTINATION`, covering all four endpoints. Matches how the
existing eight `WEB_UI_ACTION_*` constants split by action rather than by scope.

⚠ **OPEN QUESTION for Nam:** tiers 2/3 (merchant, warehouse) change the default for every SKU under a
shipper or the whole facility, while tier 1 changes one SKU. One function treats those as the same
permission. Split into `_SKU` and `_DEFAULTS` if that is wrong — decide before the seed lands, because
splitting after the grant rows ship is a second migration.

Seed shape, from the eight existing rows on `dev_wh01_om1`: `name = number = function = <constant>`.

Grants — the only roles that can reach the SKU Data screen at all (hold `WEB_UI_VIEW_ITEM_DATA`),
measured on `dev_wh01_om1` 2026-08-25:

| role | functions held | grant |
|---|---|---|
| `super-admin` | 79 | **yes** — explicitly requested |
| `inventory-manager` | 34 | **yes** — holds `WEB_UI_VIEW_ITEM_DATA` and already carries action gates |
| `CS-REP` (28), `outbound-manager` (26), `receiving` (16), `outbound-worker` (7), `inventory-worker` (5), `outbound-forklift` (3) | — | no — none hold `WEB_UI_VIEW_ITEM_DATA` |
| ~130 auto-generated `ROLE0000NN` | 1–2 each | no — per-user artifacts, not real roles |

⚠ `ROLE000117` and `ROLE000136` DO hold `WEB_UI_VIEW_ITEM_DATA` as their single function. They look like
per-user artifacts, but that is an inference from the naming, **not verified** — check before excluding.

Per §2.4's rule the function row and the grant rows are **two separate idempotent INSERTs**. The
per-tenant grant check (§8.1) has NOT been run for this row on any tenant but `dev_wh01_om1`.

#### 8.11.7 What this adds to the open list

- Close `UserFunctionRepository`'s SDR export (§8.11.4) — a prerequisite, not a nice-to-have.
- Decide the one-function-vs-two question (§8.11.6) before the seed.
- Re-run the §8.1 grant check for the new constant on hydra + both shipitez tenants.
- Pin the merge-order constraint (§8.11.5) with a negative test.

### 8.12 REVIEW OF §8.11 — 2026-08-25, adversarial lane. 4 High; §8.11 amended above

§8.11 was written and posted to ClickUp WITHOUT a review lane. One was then run against it and found
four High issues, two of them false claims already published. F1 and F2 are corrected in place in
§8.11.4 above; F3–F5 are recorded here because they change the plan, not just its wording.

**What the review VERIFIED as correct** (no change): every line number and gate annotation in §8.11.2;
the three "ungated, deliberately" reads; the 3-typed-writes / 8,803-of-8,805 figures; `FunctionGuardInterceptor`
absent from `origin/main` (0 hits, develop 112 ahead) and the "completely ungated" consequence
(`/v3/**` → `hasAnyAuthority("wms_user")`, `SecurityConfiguration:178` on both branches); every grant
count in §8.11.6; and §8.11.1's correction of §8.6.

#### F3 — the scoped surface is incomplete, and the missing half CANNOT take `@RequiresFunction`

§8.11.2 scoped this as "4 endpoints + 5 service writers". The five service `@PreAuthorize`s are not a
restatement of the four endpoints — they gate a **separate HTTP channel** the table never named.
`PutawayConfigRepositoryEventHandler` (`@RepositoryEventHandler`, `:53`) calls
`putawayConfigService.validateOnly(...)` at `:87, :102, :128, :276` and
`requireWarehouseConfigWriteAuthority()` at `:160`, from `@HandleBeforeCreate/Save/Delete` on
`Itemdata`, `Client` and `Sysprop`. None of those three domain types has a write withdrawal in
`RestConfiguration` (they appear only in `exposeIdsFor`, `:224-227`), so these are live:

- `POST /v3/itemData`, `PUT|PATCH /v3/itemData/{id}` — tier 1
- `POST /v3/client`, `PUT|PATCH /v3/client/{id}` — tier 2 (`store/admin/shippers.js:47` PATCHes here)
- `POST /v3/sysprop`, `PUT|PATCH|DELETE /v3/sysprop/{id}` — tier 3

Per F2 these are SDR handlers, so **`@RequiresFunction` cannot gate them.** They keep `@PreAuthorize`
or get exposure withdrawal. Any plan that swaps the annotation on the four MVC endpoints and calls the
surface closed leaves this channel wide open — the SBDEV-1666 landmine class, where the ROUTE is gated
and the CAPABILITY is not.

#### F4 — ONE FUNCTION IS WRONG. Split it. (This closes §8.11.6's open question.)

`WEB_UI_VIEW_ITEM_DATA` is the right criterion for tier 1 ONLY. Tiers 2 and 3 sit behind different
screens with strictly narrower grants (measured on `dev_wh01_om1` 2026-08-25):

| tier | screen | view function | named roles holding it |
|---|---|---|---|
| 1 — SKU | SKU Data | `WEB_UI_VIEW_ITEM_DATA` | super-admin, **inventory-manager** |
| 2 — merchant | Shippers | `WEB_UI_VIEW_CLIENT` | **super-admin only** |
| 3 — warehouse | System Property | `WEB_UI_VIEW_SYSTEM_PROPERTY` | **super-admin only** |

One function granted to `inventory-manager` hands **11 users** (reached via 2 groups) the ability to
`PUT /v3/putawayConfig/merchant/{clientId}` and `/warehouse` — changing the default for every SKU under
a shipper or the whole facility — on screens they cannot open, behind view gates they do not hold. A
**privilege EXPANSION** from a change whose purpose is to stop over-gating.

§8.11.6's justification for one function (*"the existing eight split by action, not scope"*) is
contradicted by that same set: `WEB_UI_ACTION_DELETE_UNIT_LOAD` vs `..._RECURSIVE` is one action split
on **blast radius**.

**Decision: two functions.** `WEB_UI_ACTION_SET_PUTAWAY_DESTINATION_SKU` (super-admin +
inventory-manager) and `WEB_UI_ACTION_SET_PUTAWAY_DESTINATION_DEFAULTS` (super-admin), each granted to
the roles already holding the corresponding VIEW function. §8.11.6's one-function shape is superseded.

**§8.11.6's ⚠ on `ROLE000117` / `ROLE000136` is WITHDRAWN** — measured, each attaches to 1 group and
reaches **0 users**, so excluding them costs nobody anything.

#### F5 — §8.6's table is wrong on TWO of seven rows

§8.11.1 corrected one and declined to check the rest. Spot-checking three more:

- `ClubLineController` (`:83, :109, :133, :160`), `TransfersController` (`:98, :124, :147, :175, :239`),
  `PickingOrderPositionController:45` — **ungated, confirmed.** Those rows stand.
- `UserAdministrationController (2 writes)` — **WRONG.** Both call `denyUnlessUserManagementAllowed()`
  as their first statement (`:131`, `:153`), throwing unless the caller holds
  `WEB_UI_VIEW_USER_MANAGEMENT` (`:120-125`). Shipped by SBDEV-2870 — the same ticket §8.11.4 cites two
  paragraphs later for `saveUserGroups`. Internally inconsistent within the amendment.
- `TokenController (1)` — `/v3/token` (`:86`) is a `permitAll` Keycloak password-grant proxy by design
  (`SecurityConfiguration:151`). A verb-shaped false positive of the kind §0.B exists to prevent.

**The whole §8.6 table needs re-verification before AC-1's boundary sweep consumes it.**

#### 8.12.1 `UserFunctionRepository` is not a putaway prerequisite — it is a slice-wide one

§8.11.4 framed it as a hole the new gate has that `sb_admin` does not. Understated:

- `UserFunctionRepository.java:13` is a plainly-exported `CrudRepository`; `UserFunction` appears in
  `RestConfiguration` only in `exposeIdsFor` (`:228`) — no withdrawal. `POST /v3/userFunction` and
  `PUT|PATCH|DELETE /v3/userFunction/{id}` are live SDR writes for any `wms_user`.
- `AccessService:83,111,142` resolves via `UserRepository.getAllRoles`, whose native query selects
  `f.name` (`UserRepository.java:77-84`) — so renaming a held function impersonates ANY function by name.
- That defeats **every function gate in the codebase**, including SBDEV-2870's and all ~92 this ticket
  adds. It belongs in §8.10's blocking list, not in a putaway subsection.
- Rename is not the only verb: `DELETE` removes catalogue rows, `POST` creates arbitrary ones.
- Per F2, **GUARDED membership cannot fix it.** `exported = false` on the interface is the right fix,
  after confirming the UI reads the catalogue through `UserRoleController` rather than SDR.

#### 8.12.2 Process note

§8.11 was authored and published in one pass with no independent lane. Two of its three evidentiary
legs were false, and both were the kind a single grep produces and a second reader catches immediately.
The floor's "one independent review, never self-approve" is not a formality for plan amendments that
touch authorization — this one reached a ticket before anyone checked it.

---

### 8.13 ~~WIDENED AGAIN 2026-08-26 — putaway config moves to `wms_admin` OR `sb_admin`~~ 🔴 SUPERSEDED

> **SUPERSEDED 2026-08-26 by §8.15, hours after it was written.** The owner clarified the axis: Keycloak is coarse-only (`wms_user` = may reach the app) and **all** fine-grained authorization lives in WMS V2's `group → role → function` model, with WMS admins in the **`super-admin`** group. A `wms_admin` OR `sb_admin` disjunction is therefore the wrong mechanism by construction, and §8.11's function gate is reinstated. **What survives from this section: the 9-site SURFACE CENSUS in §8.13.3** (the sites still need to move, just onto a function) and the §8.13.5 doc list. **What does not: the expression, §8.13.2's OR argument, and every AC in §8.13.7.** Read §8.15 first.

**Decision: Nam Park, 2026-08-26.** WMS admins must be able to open and use the Default Putaway
Location modal. This **supersedes §8.11's design** for this surface — the destination is no longer
`WEB_UI_ACTION_SET_PUTAWAY_DESTINATION_{SKU,DEFAULTS}` but a widened `@PreAuthorize`. §8.11's *surface
census* (4 endpoints + 5 service writers) survives unchanged and is re-verified below; only its
*mechanism* is replaced. §8.12's F4 (the `_SKU`/`_DEFAULTS` split) is **moot** under this design.

It also supersedes a prohibition written into the code. `Authority.java:53-61`:

> **There is intentionally no `IS_WMS_ADMIN` SpEL expression beside this.** … Do not reintroduce it
> speculatively — per the target state in `wms2-keycloak-role-matrix.md` §1.1, `wms_admin` gates
> `/actuator/**` and nothing else; business authorization belongs on `FunctionEnum` functions.

That prohibition was correct for SBDEV-2870's surface and is **not** correct for this one. 2870's
endpoint was a client-migration CSV import whose caller is SiteBoss staff, so `wms_admin` would have
403'd the only people it existed for (role matrix line 166). Putaway config is the opposite: its
caller is a customer warehouse admin. Per §1.1's own target state — *"Customer WMS users are only ever
assigned `wms_user` and/or `wms_admin`"* — `wms_admin` **is** the customer-admin authority, and
`sb_admin`-only is precisely why no customer can use this feature today.

#### 8.13.1 Why not the function gate, given §8.11 already chose it

Two measured blockers, both on `origin/main`, verified 2026-08-26:

| Blocker | Evidence | Consequence for a function gate |
|---|---|---|
| `FunctionGuardInterceptor` is **absent from `main`** | `git ls-tree origin/main` — no match; `origin/main...origin/develop` = **39 / 112**, i.e. develop is 112 ahead *and* main is 39 ahead — the branches have diverged, this is not a fast-forward | `@RequiresFunction` is **inert** in production. Replacing `@PreAuthorize` before the interceptor ships un-gates all 4 endpoints on prd |
| Function gates are **self-grantable** | `UserFunctionRepository` SDR write still open (§8.12.1, a slice-wide blocker) | A function is **weaker** than `sb_admin`, which arrives via the `groups` claim and cannot be self-granted. Moving putaway onto a function today is a net *loss* of protection |

`@PreAuthorize` has neither problem: it is enforced by Spring Security, which is on `main` today. So
the widening ships safely now and the function migration remains available later, once §8.12.1 closes
and the interceptor reaches prd. **This is a sequencing decision, not a reversal of the function
programme.**

#### 8.13.2 The expression — OR, never a replacement

Use a **disjunction**, not a swap:

```java
public static final String IS_WMS_ADMIN_OR_SB_ADMIN =
        "hasAuthority('" + WMS_ADMIN_ROLE + "') or hasAuthority('" + SB_ADMIN_ROLE + "')";
```

Three reasons the OR is load-bearing, not a nicety:

1. **A swap is a regression for staff.** `sb_admin` holders are the *only* people who can write putaway
   config today. Customer admins hold `wms_admin`; staff do **not** (role matrix line 188 — staff carry
   `sb_admin` via the `groups` claim). `wms_admin`-only therefore takes the feature *away* from every
   current user while granting it to new ones.
2. **A pure widening cannot 403 anyone who works today**, which defuses the worst failure mode on
   record. The role matrix (line 306) documents why the earlier `wms_admin` attempt was rejected: a
   wrong population guess does not merely disable a control — `403 → axios retry ×3 → $kc.logout()`
   logs the user out. Under OR-semantics a wrong guess about `wms_admin` degrades to "still
   staff-only", i.e. today's behaviour, with no logout path.
3. **The mechanism was already designed for this case.** The role matrix's *"Unused escape hatch,
   recorded so it is not rediscovered"* box names `getExpAppAdminGroupOrSbAdminGroup(appAdminRole,
   sbAdminRole)`, notes it renders `hasAuthority('X') or hasAuthority('Y')`, is called nowhere, and
   cites **"e.g. the SBDEV-2732 putaway-destination config"** as the case it exists for. This section
   is that case arriving.

⚠ **The helper cannot be used directly in the annotation** — `@PreAuthorize` takes a compile-time
constant and the helper is a runtime method returning `String`. Declare the new constant **after
`WMS_ADMIN_ROLE` at `Authority.java:68`** — *not* beside `IS_SB_ADMIN` at `:44`, the natural-looking
spot, which **will not compile**: `:31-33` records the rule that a simple-name forward reference in a
field initializer is a compile error. Delete the helper only if this leaves it with zero callers (it
already has zero; a separate cleanup, not this ticket's).

#### 8.13.3 The surface — 9 annotation sites + 1 UI resolver

Re-verified on `origin/develop` 2026-08-26. Every site moves from `Authority.IS_SB_ADMIN` to
`Authority.IS_WMS_ADMIN_OR_SB_ADMIN`.

| # | Site | What it gates |
|---|---|---|
| 1 | `PutawayConfigController:183` | `PUT /v3/putawayConfig/sku/{itemdataId}` — tier 1 |
| 2 | `PutawayConfigController:215` | `PUT /v3/putawayConfig/merchant/{clientId}` — tier 2 |
| 3 | `PutawayConfigController:233` | `PUT /v3/putawayConfig/warehouse` — tier 3 |
| 4 | `ItemDataController:105` | `setPutAwayLocation` (§8.11.1's correction — it is NOT ungated). ⚠ It is a **`@GetMapping`** (`:106`), not a PUT — a test suite issuing PUT to "all four write endpoints" gets 405 here and may misread it as a passing 403 |
| 5 | `PutawayConfigService:96` | typed writer |
| 6 | `PutawayConfigService:128` | typed writer |
| 7 | `PutawayConfigService:165` | typed writer |
| 8 | `PutawayConfigService:257` | `validateOnly` — the HAL channel's authz + validation boundary |
| 9 | `PutawayConfigService:287` | `requireWarehouseConfigWriteAuthority()` — the HAL DELETE boundary |
| UI | `wms2-web-ui/util/keycloakRoles.js:70` | `resolveSbAdmin(kc)` → must resolve the disjunction |

**Site 9 is contained — confirmed, not assumed.** Its inline comment reads *"deleting the method
removes the only sb_admin gate on `DELETE /v3/sysprop/{id}`"*, which reads as though the gate covers
sysprop deletion generally. It does not: `PutawayConfigRepositoryEventHandler:151-154` early-returns
unless `isGuardedSyskey(incoming)`, so only the `DEFAULT_PUTAWAY_LOCATION` row reaches it. Widening
site 9 does **not** widen general sysprop deletion. *(Worth correcting that comment's wording in the
same PR — it invites exactly the wrong conclusion.)*

**Sites NOT in scope.** The other **11** `IS_SB_ADMIN` sites stay as they are: `AdminController`
(×9, lines 79/107/120/133/142/154/175/236/246), `AdminActionController:341` (`/accessAudit`), and
`ReplenishmentReconciliationController:37`. Row 31's reasoning stands for those — staff tools with no
customer surface. ⚠ **Corrected 2026-08-26 (evidence lane H1):** an earlier draft of this paragraph
also listed `UserAdministrationController`, `UserGroupController` and `UserRoleController`. None of
the three carries an `IS_SB_ADMIN` annotation — the grep matched javadoc *quoting* the annotation
while discussing `AdminController`. `UserAdministrationController:56` gates by a plain method call;
`UserGroupController:46` and `UserRoleController:39` are `@RequiresFunction`. This is the **third**
time this plan has mis-scoped `UserAdministrationController` (§8.6 → §8.12 F5 → here); the pattern is
a class-name grep read as an annotation census.

**UI note.** `resolveSbAdmin` has exactly two non-test callers —
`defaultPutawayLocationField.vue:421` and `skuData.vue:386` — and both are this feature. So the UI
change is contained, but the function must be **renamed** (`resolveSbAdmin` → `resolvePutawayConfigWriter`
or similar): leaving a function named `resolveSbAdmin` that returns true for `wms_admin` is the
comment-contradicts-code failure this section is otherwise trying to avoid. `keycloakRoles.js`'s
`extractWmsRoles` already flattens `groups` + every client's `resource_access`, so the disjunction is
a one-line `.has()` change — the mirror of `extractRoles` stays correct.

#### 8.13.4 🔴 The one precondition no repo read can settle

`JwtAccessTokenCustomizer.extractRoles` harvests `groups` entries **verbatim** — it does not strip
group paths. So the Keycloak group-membership mapper must emit the **bare** name `wms_admin`, not the
full path `/wms/wh/wms_admin`. The role matrix flags this (line 174) and notes `/actuator/**` already
depends on it, so it is *probably* true — but it is a per-realm Keycloak setting, not a repo fact, and
**the entire gate rests on it**.

✅ **ANSWERED 2026-08-26 — probe run, and the premise above is wrong in an instructive way.** The
mapper emits **full paths** (`/wms_admin`, `/sb_admin`), which match nothing; every gate passes because
Keycloak *also* emits each group as a **bare client role on `om1-api`**, and that is what
`hasAuthority()` matches. So `/actuator/**` is fine, all 20 `IS_SB_ADMIN` gates are fine, and **the
bare-group-name precondition this section was built on is not the mechanism.** Do not "fix" the mapper.
Full probe and the two decoded tokens are in the role matrix at §2.1's precondition box.

~~Verify before merging: one `curl /actuator/metrics` with a real `wms_admin` token on dev.~~ Superseded
by the password-grant probe, which needs no browser and reads the claims directly.

⚠ **Do NOT use `/actuator/env`** (security lane H3). `application.properties:88` exposes only
`health,info,metrics,hikaricp,prometheus,tenantpool`, so `env` returns **404** after passing the
authority check — the probe is accidentally still discriminating (403 = authority absent, 404 =
present, because `AuthorizationFilter` runs before dispatch) but nobody should have to know that, and
a tester reading 404 as failure will go hunting a Keycloak misconfiguration that does not exist.
`/actuator/health/**` and `/actuator/info` are `permitAll` (`SecurityConfiguration:119`) and prove
nothing. Mitigant worth recording: `server.port` and `management.server.port` are both 8088
(`:76-77`), so actuator shares the app's `SecurityFilterChain` — there is no separate-management-port
hole. Env-specific overrides are gitignored; grep the deployed config before merge.

Under OR-semantics a failure here is not an outage — it degrades to today's staff-only behaviour — but
it would make the whole change a silent no-op, which is worse than a red test.

#### 8.13.5 Docs that MUST change in the same PR

Ship these together or the tree carries assertions that forbid its own code — the
retitling-leaves-the-rule-asserted failure mode:

1. **`Authority.java:53-61`** — the "intentionally no `IS_WMS_ADMIN`" javadoc. Rewrite; do not delete.
   Record that 2870's reasoning was surface-specific and that this surface's caller is a customer admin.
2. **`wms2-keycloak-role-matrix.md` §1.1 line 94** — the table row asserting `wms_admin` is
   *"`/actuator/**` **only** — never business functions"*. That becomes false on merge.
3. **Same doc, C-1 and the "Unused escape hatch" box** — C-1's reasoning survives (actuator is per-JVM
   and cannot reach a tenant DB); the escape-hatch box should record that it was used, and by whom.
4. **§8.11 and §8.11.6 of this plan** — mark the function-gate design superseded for this surface,
   deferred not abandoned.

#### 8.13.6 Tier, and what the floor requires here

**T3** — authorization *and* multi-repo (`wms2-api` + `wms2-web-ui`). Not negotiable by size: the diff
is ~12 lines and the tier is still T3, because the failure mode is silent over-permission.

Floor items, none skippable:
- **DB/live verification:** the `curl /actuator/env` probe in §8.13.4, plus the live 403→200 transition
  on `PUT /v3/putawayConfig/sku/{itemdataId}` with a `wms_admin` token. A green unit test proves the
  SpEL parses, **not** that a real token carries the authority.
- **Failing test first,** per site. `@PreAuthorize` gates are exactly the kind that pass vacuously —
  see the `setupMockMvc`-installs-no-interceptor trap. Assert the **403**, and assert it disappears.
- **Mutation-check every assertion:** revert one site to `IS_SB_ADMIN` and confirm that test alone goes
  red. Nine sites means nine mutants; a suite that stays green under any one of them is not testing the gate.
- **Independent review ×4** (conformance · code · security · re-review). This is an authz widening
  published to a plan that has already had two amendments reach ClickUp with false evidentiary legs
  (§8.12.2). Do not self-approve.
- **Full suite vs baseline** — api: the 2 known reds (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`,
  SBDEV-3089); web-ui: 627/627 post-SBDEV-2956, same 2 always-red suites.

#### 8.13.7 Acceptance criteria

- [ ] AC-1 A `wms_admin` (not `sb_admin`) token gets **200** on all four write endpoints
- [ ] AC-2 An `sb_admin` token still gets 200 on all four — **no regression for staff**
- [ ] AC-3 A `wms_user` holding neither still gets **403** on all four
- [ ] AC-4 The HAL channel (sites 8, 9) enforces the same disjunction — verified through SDR, not only the typed route
- [ ] AC-5 `DELETE /v3/sysprop/{id}` for a **non**-guarded key is unaffected (site 9 containment)
- [ ] AC-6 The modal's picker and Save are **enabled** for `wms_admin` in the browser, and **both** entry pencils are enabled — `skuData.vue:123` (the SKU-Data table row, the *primary* way in) and `effectivePutawayRow.vue:117` (the details overlay). Both are `:disabled="!isSbAdmin"`/`!canEdit` and `editPutaway` has no permission guard of its own (`skuData.vue:478-482`), so `:disabled` is the whole gate. ⚠ **AC-6 cannot pass on the API change alone — see §8.14 B1.**
- [ ] AC-7 Nine mutation reverts, nine distinct red tests
- [ ] AC-8 The four docs in §8.13.5 are updated in the same PR
- [ ] AC-9 `/actuator/**` still admits `wms_admin` and still refuses `wms_user` — the shared-authority regression check

#### 8.13.8 Open questions

1. **Is `wms_admin` the right population, or is it too broad?** Nobody has enumerated its members from
   the repo — that is the same unverifiable-population objection that sank the 2870 attempt (line 306).
   The OR design means a wrong answer fails safe, but a *too-broad* `wms_admin` grants putaway-config
   writes to everyone who can also read actuator. **Needs a Keycloak group listing, not a code read.**
2. **Do tiers 2 and 3 belong in the same grant as tier 1?** §8.12's F4 raised this against the function
   design and it survives here: merchant and warehouse defaults are facility-wide blast radius, while
   the SKU tier is one item. The disjunction treats all three identically. If that is wrong, sites 2
   and 3 stay on `IS_SB_ADMIN` and only sites 1, 4-9 widen.
3. **Does the mobile UI reach any of these?** Not checked this pass.

---

### 8.14 REVIEW OF §8.13 — 2026-08-26, three lanes. 2 BLOCKING; §8.13 amended above

Lanes: evidence, security (adversarial), design. **9 High · 7 Medium · 4 Low.** Six corrections
applied in place above and marked. Reviews:
`scratchpad/review-813-{evidence,security,design}.md`. Deliberately **not** posted to ClickUp before
this ran — §8.12.2's lesson.

#### 8.14.1 🔴 B1 — BLOCKING. The widening cannot deliver its own goal on its own

Both the security and design lanes reached this independently, from different directions. It is the
finding that decides whether §8.13 is the right mechanism at all.

**`@PreAuthorize` is not what stops a WMS admin from opening the modal.** The web UI's route guard is
keyed on **functions**, not Keycloak authorities:

- `wms2-web-ui/middleware/require-function.js:32-80` — a live, fail-closed route guard, deciding from
  `store.state.functions`, populated by `store/index.js:175-220` from `getAllRoles/<preferred_username>`
  — the `user → group → role → function` chain.
- `util/appMenuList.js:98` gates `/masterData/materialData/sku-data` on `WEB_UI_VIEW_ITEM_DATA`.
- `pages/admin.vue:55-63` + `visibleTabs` gate **Parameters & Configuration** on
  `WEB_UI_VIEW_SYSTEM_PROPERTY` (tier 3's host) and **Shippers** on `WEB_UI_VIEW_CLIENT` (tier 2).

`wms_admin` is a Keycloak group authority. It confers **zero** functions. So:

> **Input:** a customer warehouse admin holding `wms_user` + `wms_admin`, whose WMS role is not
> `super-admin` / `inventory-manager`. **Outcome:** `require-function.js:79-80` redirects to
> `/not-authorized?fn=WEB_UI_VIEW_ITEM_DATA`, or the Admin tab is never rendered — **before any request
> reaches the widened `@PreAuthorize`.** The 12-line diff is invisible to them.

§8.13 called §8.12's F4 "moot". Its *conclusion* is; its **measurement** is not — F4 measured that
`WEB_UI_VIEW_SYSTEM_PROPERTY` and `WEB_UI_VIEW_CLIENT` are held by **super-admin only** on
`dev_wh01_om1`, and `WEB_UI_VIEW_ITEM_DATA` by super-admin + inventory-manager. **That is the data that
decides whether AC-6 can pass, and discarding F4 discarded it.**

Compounding, from the design lane: role matrix §1.1's business rule is verbatim *"configuring default
putaway locations is a **WMS application admin (`super-admin`)** responsibility"* — and `super-admin` is
a **`UserRole` row in the tenant DB** reached through the function chain, **not** the Keycloak group
`wms_admin`. §8.13 silently substitutes one axis for the other, which is the objection the role matrix
records as its reusable lesson (§2.1 📌): *"When a new guard lands on a different axis from the one that
already grants access, prefer moving the guard onto the existing axis over verifying that the two
populations coincide."* That sentence describes this change.

**And under OR-semantics the failure is silent.** §8.13.2's reason 2 — a pure widening cannot 403
anyone — is exactly what makes a wrong population guess dangerous: it yields *today's behaviour with a
green suite*. All nine ACs can pass against a synthetic `wms_admin` token while the customer admin who
asked for this stays locked out. Nothing in §8.13 would detect that.

**Resolution required before any code — a 15-minute probe, not an open question:**
1. Enumerate `/wms/wh/wms_admin` membership on WineCo dev + Hydra UAT via the Keycloak admin API. Put
   the count in this plan.
2. Cross-reference against the holders of `WEB_UI_VIEW_ITEM_DATA` / `WEB_UI_VIEW_SYSTEM_PROPERTY` /
   `WEB_UI_VIEW_CLIENT` in the tenant DB.
3. Then one question to the owner: *"you said `super-admin`; the Keycloak group `wms_admin` holds N
   users on dev — are those the same people?"*

If they are not the same people, **§8.13 is the wrong mechanism** and §8.11's function gate is right,
merge-order and all — or the two must ship together (widening + the VIEW-function grants, which is F4
re-entering by the back door). §8.13's AC-6 must not ship as a blanket claim either way; re-scope it to
*"a `wms_admin` who already holds the corresponding VIEW function"* and state that everyone else needs a
role change.

#### 8.14.2 🔴 B2 — BLOCKING for the census, not for the design: the surface is NOT staff-only today

> ✅ **FILED 2026-08-26 as [SBDEV-3103](https://app.clickup.com/t/868kx255v)** — *"any wms_user can silently clear the warehouse-wide Default Putaway Location, unaudited, by renaming the guarded syskey over SDR"*. Independent of this migration and should not wait for it; note the same bypass would defeat a **function** gate exactly as it defeats `@PreAuthorize` today.

§8.11.2's headline — *"Nothing here is currently reachable by a non-staff user"* — is **false**, and
§8.13 re-asserted that census as "re-verified". A plain `wms_user` can silently remove the tier-3
putaway default, ungated and unaudited, by **renaming the guarded syskey**:

Both Sysprop hooks branch on the **merged incoming** entity —
`PutawayConfigRepositoryEventHandler:131-137` (save) and `:151-155` (delete) both
`if (!isGuardedSyskey(incoming)) return;`, and `isGuardedSyskey:333-336` compares
`incoming.getSyskey()` to `SYSTEM_PROPERTY_DEFAULT_PUTAWAY_LOCATION_KEY`. `PutawayConfigService:232-235`
confirms the merge already happened: *"SDR has already merged the payload into a DETACHED instance by
the time the handler fires, so the in-memory field holds the NEW value."*

Reachability: `SyspropRepository:15` is `@RepositoryRestResource(path="sysprop")`; `RestConfiguration`
uses `ANNOTATED` detection (`:239`) and withdraws **no** verb for `Sysprop` (it appears only in
`exposeIdsFor`, `:227`); `Sysprop.syskey` is a plain bindable `String` with no `exported = false`; and
`SecurityConfiguration:157-160` grants `/v3/sysprop/**` to **`wms_user`** despite the block's
"Admin-Only" label.

> **Input:** `PATCH /v3/sysprop/30604812 {"syskey":"DEFAULT_PUTAWAY_LOCATION_OLD"}` as a plain
> `wms_user`. **Outcome:** `isGuardedSyskey(incoming)` false → early return → no authorization check, no
> validation, **no audit row**. The row saves and the tier-3 default is gone.

Measured, to avoid over-claiming: the duplicate-row variant is **blocked at the DB** —
`dev_wh01_om1` carries `CREATE UNIQUE INDEX uk8tcoe23qui9q3ancbhx662iqb ON los_sysprop (client_id,
syskey, workstation)`. Only rename-away works. Live row today: `id=30604812, sysvalue='' (unconfigured),
client_id=0, workstation=DEFAULT`.

**Pre-existing — not caused by this change**, and AC-4/AC-5 both test the *guarded* key so neither can
catch it. Shape of the fix is one line: `isGuardedSyskey(previousState) || isGuardedSyskey(incoming)`,
or withdraw `PATCH`/`PUT` on `Sysprop` items (stronger, wider blast radius, needs its own reachability
sweep). **Ticket filed 2026-08-26: SBDEV-3103.** And stop describing this surface as staff-only —
§8.11.2's *"Nothing here is currently reachable by a non-staff user"* must be corrected wherever it is
restated.

⚠ **Do not "fix" it by annotating the handler method.** `PutawayConfigService:285-296` records why the
annotation sits on the `@Service`: SDR may capture the raw handler target rather than the security
proxy, leaving a handler-side annotation **inert and silently never firing**.

#### 8.14.3 The denial path is worse than §8.13.2 claimed — and it forces a merge order

`plugins/axios.js:39-66` — the clean 403 path (toast, no retry, no logout) fires **only** when the
response carries `X-Authz-Denied`, and `Authority.java:90` states that header is *"Emitted by
`FunctionGuardInterceptor` and nowhere else."* A `@PreAuthorize` denial carries no such header, so it
falls through to `:68-95`: >5s from token expiry → `updateToken(5)` resolves false → **silent no-op, no
toast**; near expiry → retry ×3 → `$kc.logout()`; refresh throws → immediate logout.

So §8.13.2's reason 2 is **half right**: a pure widening 403s nobody who works today, but choosing
`@PreAuthorize` over `@RequiresFunction` keeps this surface permanently on the *un-mitigated* denial
path for everyone it still denies — and the likely outcome is the **silent no-op**, not the logout the
section named. Correct that wording; either emit an equivalent header on these denials or record the
gap.

> **Input:** the web-ui PR merges to `develop` before the API PR (two repos, two deploys — and merging
> to wms2 `develop` *is* a dev deploy). **Outcome:** `canEdit` true for a `wms_admin`, pencil and Save
> enabled, Save → 403 with no `X-Authz-Denied` → silent no-op or forced logout.

**New rule: merge API first, then web-ui.** SBDEV-3004 set the precedent (api #195 before web-ui #76).
§8.13 had a merge-order rule for `main` vs the interceptor and none for api vs ui.

#### 8.14.4 The test plan in §8.13.6 is not implementable as written

**No test lane in this repo evaluates `@PreAuthorize`** — a structural absence asserted in both
`src/main` and `src/test`: `UserAdministrationController:56-60` (*"no controller test in this repo
evaluates `@PreAuthorize`"*), `BaseControllerUnitTest:82`, `FunctionGuardArchTest:778` and `:214`.
`standaloneSetup` installs no method-security advisor, and the `@SpringBootTest` web lane is still
blocked. Sites 5-9 are service methods that never produce an HTTP status at all. **Consequence:
AC-1/AC-2/AC-3/AC-4 are live-probe-only; no JUnit test can produce the 403 or its disappearance, and
nothing goes red from the nine reverts either.** So AC-7 as written is unachievable and §8.13.6's
"assert the 403, and assert it disappears" is not implementable.

Replace with a named mechanism per site:
- **9 reflection assertions** on `Method.getAnnotation(PreAuthorize.class).value()` equalling
  `Authority.IS_WMS_ADMIN_OR_SB_ADMIN` — each a **named** assertion, never a `for`-each over a list
  that can be empty (the vacuous-reflection-test trap).
- **1 SpEL truth-table test** in `CustomMethodSecurityExpressionRootUnitTest` via its existing
  production-faithful `evaluate(...)` harness (`:433-459`) — the only such harness in the repo.
- **The live probes** for the real 403→200, explicitly labelled as the only evidence for AC-1-AC-4.

Also: **AC-9 has no test anywhere.** `TenantPoolEndpointSecurityTest:66-71` is `@Disabled` ("actuator
security slice deferred"), so the `/actuator/**` authority rule is live-curl-only too.

#### 8.14.5 Smaller corrections not yet applied above

1. **The effective population is `wms_user ∧ (wms_admin ∨ sb_admin)`**, never stated. `SecurityConfiguration:178`
   requires `wms_user` on `/v3/**`, so a test token carrying only `wms_admin` is refused at the *route*,
   indistinguishable from the method gate not widening — and the tempting fix is relaxing the route
   matcher. **Specify every AC token with its full authority set.**
2. **A third UI surface**: `components/admin/shippers/editShipper.vue:83` embeds
   `<default-putaway-location-field>` for tier 2. §8.13.3's two-caller census of `resolveSbAdmin` is
   technically right (the shared component is the caller) but reads as if one screen is affected.
3. **The UI change is not "a one-line `.has()`"**: a new `WMS_ADMIN_ROLE` export, the disjunction, the
   rename, 2 call sites, and **3 spec files** — `keycloakRoles.spec.js`, `skuData.spec.js` (`:130`,
   `:221`, and `:223` which matches the identifier by **source-text regex**),
   `defaultPutawayLocationField.spec.js:1063`.
4. **Widening `isSbAdmin` falsifies a stated invariant** in `skuData.vue:300-302`: *"THE TICKET ID IS
   ONLY EVER SHOWN TO STAFF … it lives in the `isSbAdmin === true` branch."* No leak today (B2 deleted
   the ID; `editTooltip:314` is generic) but the comment becomes false, and `:309`'s *"This setting is
   managed by SiteBoss support"* would then show only to `wms_user`. Add both to §8.13.5.
5. **§8.13.5 misses the role matrix's strongest contradicted line** — `:188-190`: *"every
   `IS_SB_ADMIN`-gated endpoint is SiteBoss-staff-only by design, not by oversight. **Treat 'a WMS admin
   sees this control disabled' as intended, not a bug.**"* That is an imperative instruction to future
   readers to reject exactly this change. It outranks line 94.
6. **The role matrix's own gate count is wrong**: it says *"18 active gates"* and lists 8
   `AdminController` methods; actual is 9 (`importUsersFromCsvText:237` missing) plus
   `AdminActionController:341` → **20**. Fix in the same PR, or the next reader re-derives the error.
7. **Preserve `Authority.java:62-66`** when rewriting `:53-60` — it already carries the bare-group-name
   warning §8.13.4 depends on.
8. **Two adjacent-but-closed paths**, recorded so they are not "discovered" as holes:
   `SystemPropertyController:61-65` (`rejectGuardedPutawayKey` — a **third** HTTP channel, closed by
   hard refusal for all callers, absent from §8.11's census) and `ItemdataService:73` (ungated wrapper,
   **zero** callers, delegates to site 5).

#### 8.14.6 One review finding was itself false — recorded, because the failure mode is the point

The design lane reported as **High** that `effectivePutawayRow.vue` *"does not exist anywhere in
wms2-web-ui on `develop`"*, citing `find` and a full-tree `command grep` returning zero, and concluded
AC-6's citation was fabricated.

**It is wrong.** The file exists at
`components/masterData/material/skuData/effectivePutawayRow.vue` on `origin/develop`, and `:117`
carries `:disabled="!canEdit"` exactly as cited. The lane graded the **working tree**, which was 29
commits behind `origin/develop` and therefore predates SBDEV-2956's merge (`685546d`, 2026-08-26) that
added the file. The evidence lane, reading `origin/develop`, cited the same file correctly.

Recorded because this is the *fourth* distinct instance in this plan's history of a grep at the wrong
scope producing a confident, false, High-severity claim (§8.12's two false legs; §8.14.1's
`UserAdministrationController` mis-scoping; this). **The lesson is not "check the tree" — it is that a
review lane's negative existence claim needs the same scope discipline as the plan's positive ones.**
The other half of that same finding — `editShipper.vue:83` and `skuData.vue:123` — was correct and is
carried into §8.14.5 and AC-6.

---

### 8.15 THE AXIS DECISION 2026-08-26 — §8.13 retired, §8.11 reinstated, B1 resolved

**Decision, Nam Park, 2026-08-26** (supersedes §8.13 the same day):

> From a Keycloak point of view all the users will have `wms_user` group to have access to WMS v2. It's
> WMS V2 that controls fine-grained access control through groups, roles, functions. All the users who
> have admin access in WMS 2 will be assigned to the `super-admin` group and whoever is in this group
> will have access to those functions.

**Consequences, stated as rules:**

1. **Keycloak is COARSE ONLY.** `wms_user` means "may reach the app". It is not a permission.
2. **No business endpoint may gate on `wms_admin` or `sb_admin`.** Business authorization belongs on
   `FunctionEnum` functions. `@PreAuthorize(Authority.IS_SB_ADMIN)` on a business write is the
   anti-pattern being retired — it is why no customer user can configure putaway destinations today.
3. **`super-admin` is the admin population**, and it is a `mywms_role`/`mywms_group` in the **tenant
   DB**, reached by `user → group → role → function`. Not a Keycloak group.
4. **§8.13's disjunction is retired. §8.11's function gate is reinstated** — including §8.12's F4
   `_SKU` / `_DEFAULTS` split, which is live again now that the mechanism is a function.

#### 8.15.1 This RESOLVES B1 — it does not work around it

§8.14.1 found that the widening could not deliver its own goal because the web UI gates screens on
**functions** (`require-function.js:32-80`, `WEB_UI_VIEW_ITEM_DATA` / `_SYSTEM_PROPERTY` / `_CLIENT`)
while `wms_admin` confers **zero** functions — an axis mismatch, silent under OR-semantics. The
clarified decision removes the mismatch by putting the gate on the same axis that grants the screen,
which is exactly the remedy the role matrix's own reusable lesson (§2.1 📌) prescribes.

**And B1's missing datum is now measured** — `dev_wh01_om1`, 2026-08-26:

| Fact | Value |
|---|---|
| `super-admin` **group** members | **38 users** |
| `super-admin` **role** → functions | **79 of 82** |
| Other groups mapping to the `super-admin` role | 5 (`GROUP000102/175/013/038/109`) |
| `wms_admin` as a `mywms_role` | **0** |
| `wms_admin` as a `mywms_group` | **0** |
| Functions `super-admin` lacks | 3, all deliberate — `MOBILE_UI_NEVER_TIME_OUT`, `MOBILE_UI_VIEW_LPN_ASSOCIATION`, `SPECIAL_DEVELOPER` |

So the Keycloak-group-membership probe §8.14.1 demanded is **moot**: `wms_admin` is not a WMS role or
group at all, and the population that holds the VIEW functions *is* `super-admin`, 38 users. A function
granted to `super-admin` reaches exactly the people intended.

#### 8.15.2 What the audit found about `wms_admin` itself — it grants almost nothing

Full audit: `3-Resources/reports/260826-wms-admin-to-super-admin-authz-axis-audit.md`.

**`wms_admin` has exactly ONE enforcing site in wms2-api:** `SecurityConfiguration:147`, the
`/actuator/**` matcher. All 12 other API occurrences are javadoc, a dead test property
(`src/test/resources/application.properties:93`, bound by nothing), or inert fixtures. **Zero**
`@PreAuthorize` / `hasAuthority` / `@RequiresFunction` site references it.

**The gate that actually blocks WMS admins is `sb_admin` — 20 `@PreAuthorize(IS_SB_ADMIN)` sites**,
which is this plan's real migration surface: `AdminController` ×9 (`:79,107,120,133,142,154,175,237,247`),
`PutawayConfigService` ×5, `PutawayConfigController` ×3, `ItemDataController:105`,
`AdminActionController:341`, `ReplenishmentReconciliationController:37`.

✅ **DECIDED (Nam, 2026-08-27): NINE of the 20 STAY on `sb_admin`.** Three by the first decision, plus
`PutawayConfigService:257`/`:287` by §8.16.5's option (a), plus **all four `AdminController` identity
WRITES** by the 2026-08-27 decision (§9.14). So the migration surface for this tranche is
~~**17 sites**~~ → ~~**15 sites**~~ → ~~**11 sites**~~ → ✅ **9 sites** (§9.15, 2026-08-27). §8.16.5
(2026-08-26, option **(a)**) carved `PutawayConfigService:258`/`:288` out onto `sb_admin` — `@RequiresFunction`
is inert on them and (b) was rejected as a net regression (§8.16.6) — and §9.15 then carved out all five
`AdminController` WRITES plus `findUsers:79` and `findGroupByName:247`.

🚫 **THE SPLIT TABLE THAT LIVED HERE IS REMOVED. The single source of truth is §9.18.1.**

The split has been revised **five** times — 17/3 → 15/5 → 11/9 → 9/11 → **7 move / 13 stay** — and in this
one block its enumeration drifted from its label **twice**:

- `PutawayConfigService ×5` under a *"15 move"* label (8+3+5+1 = 17, the pre-§8.16 figure);
- and on 2026-08-27, a partial find-replace left *"9 stay, 11 move"* directly above *"The 9 that move"*, over
  a table whose `AdminController` row still listed the two sites §9.15 had just carved out.

A **third** copy in `wms2-keycloak-role-matrix.md` (*"The 17 that do move"* over 18 rows, listing the two
carved-out SDR sites as movers) was deleted for the same reason on 2026-08-27.

**The pattern is the duplication itself, not the edits.** Every revision updated one copy and left another,
and each surviving copy read as authoritative. So this one is gone rather than corrected: **§9.18.1 carries
the derivation, and `MethodSecurityEnablementContractTest` enforces the stay-half in code** — 13 pins,
diffed against the stay-set as a *set*. Re-derive from source (the query is in §9.15.1); never edit a label
alone.

**WHY each stay-set member stays.** ⚠ This table is the *rationale* reference only — **the count and the
membership live in §9.18.1**, and the code enforces them (`MethodSecurityEnablementContractTest`, 13 pins
diffed as a set). Do not read a row count here as the split; that is what broke three times.

| # | Stays on `sb_admin` | Endpoint | Why |
|---|---|---|---|
| 1 | `AdminController:237` `importUserWithCsv` | `GET /v3/admin/importUsersFromCsvText` | Creates loginable Keycloak identities; `:197-201` records the caller is SiteBoss staff running a client migration, and an interim `wms_admin` version *"would have returned 403 to the only people the endpoint was retained for"* |
| 2 | `AdminController:120` `deleteUserByUsername` | `/user/deleteUserByUsername` | **Identity WRITE — §9.14** |
| 3 | `AdminController:142` `ssoCreateUser` | `/user/createUser` | **Identity WRITE — §9.14** |
| 4 | `AdminController:154` `ssoUpdateUser` | `/user/updateUser` | **Identity WRITE — §9.14** |
| 5 | `AdminController:175` `resetUserPassword` | `/user/resetPassword` | **Identity WRITE — §9.14** |
| 6 | `ReplenishmentReconciliationController:37` | `POST /v3/reconcile-stranded-reservations` | SBDEV-2610 operator repair tool, idempotent, no UI caller |
| 7 | `AdminController:79` `findUsers` | `/user/findUsers` | **§9.15 decision 1** — `usersResource.list(0, 1000)`, the whole Keycloak realm. ⚠ its `sb_admin` branch is DEAD in production and the live `else` branch NPEs on a nullable `getEmail()`; staying narrows who reaches that, it does not fix it |
| 8 | `AdminController:247` `findGroupByName` | `/groups/findGroup` | **§9.15 decision 2** — exposes Keycloak **group** topology, the axis the carve-out rationale depends on being unreachable |
| 9 | `AdminController:107` `findUserByUsername` | `/user/findUserByUsername` | **§9.18** — arbitrary-username existence oracle, no caller in either UI (SBDEV-3071 class) |
| 10 | `AdminController:133` `findUserGroupsByUsername` | `/user/findUserGroupsByUsername` | **§9.18** — returns WHICH GROUPS a named user belongs to: reconnaissance on the privilege model these carve-outs protect, and a *more targeted* oracle than `findUsers`' bulk dump |
| 11 | `AdminActionController:341` `accessAudit` | `GET /v3/adminAction/accessAudit` | The **rollout instrument for this migration** — a function gate here gates the tool measuring the rollout (§8.4) |
| 12 | `PutawayConfigService:258` `validateOnly` | SDR `@HandleBefore*` channel | `@RequiresFunction` is **inert** here (§8.16) |
| 13 | `PutawayConfigService:288` `requireWarehouseConfigWriteAuthority` | SDR `@HandleBefore*` channel | same; the annotation **is** the behaviour |

**The reason common to the staff-only tools among these eleven, and the one that would survive even if the per-site arguments did not:**
a function is **weaker than `sb_admin`**, so moving staff-only tools onto one reduces their protection.
⚠ **The mechanism originally cited here is STALE:** *"while `UserFunctionRepository`'s SDR write stays open
a function is self-grantable"* stopped describing a live route when PR #209 withdrew those verbs. The real
mechanism is stronger — `UserController.saveUserGroups:536` takes **any** `userId` with no self-scope, so
`WEB_UI_VIEW_USER_MANAGEMENT` is the **root of the function lattice**: any holder can grant themselves
every other function in one request. `sb_admin`, by contrast, is unreachable from WMS *structurally* — the
only joinable groups are `/wms_user` and `/warehouse/<facility>`, matched by exact path equality. Row 31's
original conclusion survives on better evidence than it was given.

#### 8.15.3 ✅ ANSWERED 2026-08-26 — `/actuator/**` STAYS on `wms_admin`

The one `wms_admin` site is the one that **cannot** move to a tenant-DB role, and this is mechanical,
not a preference:

`TenantFilter:40-49` derives the tenant **only** from the `X-Tenant-ID` + `facility_code` headers.
Prometheus scrapers, k8s probes and CI send neither, so `TenantContext` is `null` and
`TenantDynamicRoutingDataSource:49-54` routes to the **landlord** DB — where `mywms_user` /
`mywms_function` do not exist. A function check there is PostgreSQL `42P01` → **HTTP 500, not 403**.
Header-less monitoring breaks loudly and misleadingly. Nor can it drop to `permitAll`: it exposes
metrics, pool and tenant-topology data. Role matrix C-1 records the same conclusion.

✅ **DECIDED (Nam, 2026-08-26): actuator stays on `wms_admin`.** The axis decision is therefore scoped
to **business access**, and it *confirms* role matrix §1.1's target state rather than changing it: the
*"`/actuator/**` only — never business functions"* phrasing stays **true**, and `wms_admin` survives as
an **ops/infra-only authority with exactly one consumer**, `SecurityConfiguration:147`. Docs updated
accordingly — role matrix §1.1 row, C-1, the §1.1 bullet, §2.1's escape hatch, the path table, the
gate count, the §10 log and the frontmatter; plus `SBDEV-2968`'s copied row, `SBDEV-2732`'s
escape-hatch note, the plan template's row-7 example, `1-Projects/wms2/plan/README.md`, and the
fabricated sample in `wms2-project-analysis.md`.

Same constraint, same answer, for every other surface that cannot resolve a tenant: `/api/public/**`
(explicitly skipped by `TenantFilter:34-38` — it *resolves* the tenant, so it cannot presuppose one),
`/error` (context already cleared by the `finally` at `:53-55`), `/rest/**` (OMS sends no Keycloak JWT
at all), and `IdempotencyFilter`, which runs before `AuthorizationFilter` and must therefore check an
**authority**, never a tenant-DB function.

#### 8.15.4 Dead code to delete alongside

| Item | Why |
|---|---|
| `"ADMIN"` in `SecurityConfiguration:147` | Traced to `09eb2f06` — *"Simplified - you may need custom authority mapping"*, a Spring Boot 2→3 placeholder its own author flagged. Unreachable: authorities come only from `resource_access.*.roles` + `groups` verbatim, and no Keycloak role or group named `ADMIN` exists. `@WithMockUser(roles={"ADMIN"})` prefixes to `ROLE_ADMIN` and would not match either |
| `Authority.getExpAppAdminGroupOrSbAdminGroup` | **Zero** consumers in `src/main` and `src/test`. This is the helper §8.13 was going to use; under this decision it should be **deleted**, not called. Same for `getExpAppUserGroupOrAppAdminGroup` and `NO_ASSIGN_USER_ROLE` |
| `security.oauth2.app.admin.group=wms_admin` (`src/test/resources/application.properties:93`) | Bound by nothing — no `@ConfigurationProperties(prefix="security.oauth2")` exists; `KeycloakService.getAdminGroupPath()` is gone |
| `appAdminGroup` in **both UIs** — `wms2-web-ui/nuxt.config.js:199`, `wms2-mobile-ui/nuxt.config.js:134`, both defaulting to `/wms/wh/wms_admin` | ⚠ **Found 2026-08-26; the earlier audit was API-only and missed these.** Neither UI has a runtime consumer — the only other hit is `skuData.spec.js:226` `expect(s).not.toContain('appAdminGroup')`, a test **pinning its removal** (SBDEV-2643 r5 and earlier used it, then moved off). Delete both, plus the env-var note at `wms2-web-ui/CLAUDE.md:70`. The `CYPRESS_WMS_ADMIN_*` hits in `admin.cy.js` are test-run toggles, unrelated |
| **Rule C**, `SecurityConfiguration:157-160` | Requires `wms_user` — **identical** to rule D at `:151` — and all but three of its patterns already fall under `/v3/**`; the three un-prefixed ones match no controller. Changes no outcome anywhere, yet its comment reads **"Admin-Only WMS Endpoints"**, which is false and which readers trust |
| `Authority.getExpForRole(String)` | **Zero** consumers in `src/main` (the only mention is a javadoc reference in `PutawayConfigService:38`); used solely by `CustomMethodSecurityExpressionRootUnitTest:463,469` | Test-only helper. Delete it **with** those two test cases, or keep both — do not leave a security helper alive for tests alone. Lower priority than the rest: unlike `getExpAppAdminGroupOrSbAdminGroup` it is not a loaded gun, since nothing has ever proposed calling it |
| `ClientControllerLegacyIntegrationTest:146` | A commented-out `//.with(user("functional_test_user")…roles("wms_admin")` inside an already-inactive block | Dead commented code carrying a `wms_admin` reference that a future grep will surface as a live gate. Delete the line |

⚠ **One item that looks deletable and is NOT.** `TenantPoolEndpointSecurityTest:66-73` is `@Disabled` with
an **empty body** and a reason string saying *"The `/actuator/**` ADMIN/wms_admin (403 vs 200) assertion is
added at implementation time"* — which never happened. So **no test anywhere asserts the actuator authority
rule**, which is exactly why a regression there would be silent. Now that `/actuator/**` is a settled,
permanent carve-out (§1), that test should be **implemented, not deleted** — it is the only tripwire the one
remaining `wms_admin` gate could ever have. Same for `UserControllerUnitTest:808,815`: its
`Arrays.asList("wms_user", "wms_admin", "picking_user")` fixture is semantically wrong (that query returns
`mywms_function.name` rows, not Keycloak groups) but authorization-inert — **fix the fixture, do not delete
the test**.

#### 8.15.5 Doc drift the audit found — two claims already false in code

`AdminController:183` (*"gated on wms_admin 2026-08-16"*) and `UserAdministrationController:76`
(*"stays on `wms_admin` in `AdminController`"*) both describe `importUsersFromCsvText` as `wms_admin`-gated.
The annotation on it is `@PreAuthorize(Authority.IS_SB_ADMIN)` (`:236`). Predates this decision; fix regardless.

#### 8.15.6 Still binding from §8.14 — none of it is dissolved by this decision

1. **`UserFunctionRepository`'s open SDR write is a slice-wide blocker.** Function gates are
   self-grantable until it closes, so a function is *weaker* than `sb_admin`. This decision makes
   closing it a **prerequisite**, not a parallel task.
2. **`FunctionGuardInterceptor` is absent from `origin/main`** (diverged 39/112) — `@RequiresFunction`
   is inert in prd. Merge order load-bearing; do not drop `@PreAuthorize` before the interceptor ships.
3. **No test lane evaluates `@PreAuthorize`** — and the same is true of gate tests written with
   `setupMockMvc`, which installs no interceptor. Live probes plus named reflection assertions.
4. **B2 stands** — the syskey-rename hole (§8.14.2) is untouched by this decision and is now tracked as
   **SBDEV-3103**. It is not a prerequisite for this migration, but it is not dissolved by it either:
   the bypass defeats a function gate the same way it defeats `@PreAuthorize`.
5. **Merge API before web-ui.** `resolveSbAdmin` and its two callers gate on the Keycloak axis and must
   move in step; a `@PreAuthorize` 403 carries no `X-Authz-Denied` and hits axios's silent-no-op path.

---

### 8.16 🔴 BLOCKER FOR TWO OF THE 17 — `@RequiresFunction` cannot enforce a service method reached from an SDR hook

**Found 2026-08-26 reviewing SBDEV-3103's fix. This tranche would silently undo that fix.**

§8.15.2 originally listed `PutawayConfigService` ×5 — `:96, :128, :165, :257, :287` — among the then-17 sites moving from
`@PreAuthorize(Authority.IS_SB_ADMIN)` onto a `FunctionEnum` function. **Two of those five cannot be
function-gated by annotation at all:**

| Site | What it is | Why the annotation cannot reach it |
|---|---|---|
| `PutawayConfigService:257` `validateOnly` | the HAL/SDR channel's authz + validation boundary | invoked from `PutawayConfigRepositoryEventHandler`'s `@HandleBefore*` hooks, not from an MVC handler |
| `PutawayConfigService:287` `requireWarehouseConfigWriteAuthority` | the HAL/SDR DELETE + identity-move boundary (SBDEV-3103) | same — and its **body is empty**: the annotation *is* the behaviour (`:289-290`) |

`FunctionGuardInterceptor` resolves `@RequiresFunction` from
`handlerMethod.getMethod().getDeclaringClass()`. Its own javadoc states the consequence:

- `:41` — *"Enforces `@RequiresFunction` on Spring MVC **handler methods**."*
- `:87-92` — *"⚠ **Reaching an SDR request is not the same as gating it.** An SDR handler's declaring class
  is `RepositorySearchController` or `RepositoryEntityController` — SDR's own generic controllers … it is
  reachable, and still open."*

For an SDR write the declaring class is SDR's generic controller — **never** `PutawayConfigService`. So an
annotation on either method is inert.

#### 8.16.1 Why this is dangerous rather than merely wrong

The swap **compiles, passes, and reverts a security fix in silence**:

1. `@PreAuthorize(IS_SB_ADMIN)` → `@RequiresFunction(...)` on `:287`. Compiles.
2. SBDEV-3103's 8 mutants still all pass — they assert the *handler calls the method*, which it still
   does. The method body is empty, so there is nothing else to observe.
3. Nothing enforces it. `PATCH /v3/sysprop/{id} {"workstation":"WS1"}` as a plain `wms_user` succeeds —
   **the exact bypass SBDEV-3103 closed**, unauthorized, unvalidated, unaudited.
4. No test sees it. No lane in this repo evaluates `@PreAuthorize`, and none evaluates
   `@RequiresFunction` at the service layer either.

#### 8.16.2 A second, independent reason not to move these two

A function grant is **self-grantable** while `UserFunctionRepository`'s SDR write stays open (§8.12.1 —
a slice-wide blocker). `sb_admin` is not: measured 2026-08-26, it reaches the authority set as a **bare
client role** in `resource_access[om1-api]` (see the token probe in §8.15.3's companion memory), which
nothing a `wms_user` can write produces. So moving *these* gates onto functions converts an unforgeable
gate into a forgeable one — precisely the argument that kept `AdminController:237`,
`ReplenishmentReconciliationController:37` and `AdminActionController:341` on `sb_admin` (§8.15.2).

#### 8.16.3 The two ways to satisfy it — Nam's call, and it changes the count

The **constraint** is mechanical and not negotiable; the **resolution** is a decision:

- **(a) Add `:257` and `:287` to the stay-on-`sb_admin` carve-out.** Cheapest, and consistent with the
  three already carved out for the same self-grant reason. Made the split **15 move / 5 stay**; now **9 move / 11 stay** after §9.14.
- **(b) Gate them programmatically** — `accessService.doesUserHaveAccess(...)` inside the method body,
  not by annotation. Keeps them on the function axis, but `:287` stops being an empty method and
  SBDEV-3103's tests must be extended to assert the *check* rather than the *call*. Should still be
  sequenced after the self-grant hole closes, or (b) is strictly weaker than today.

⚠ **Whichever is chosen, `@RequiresFunction` on these two is never correct.** If a future revision of
this plan lists them among the annotation migrations again, that revision is wrong.

✅ **RESOLVED 2026-08-26 by §8.16.5's option (a): the split became 15 move / 5 stay** (and is now **9 move / 11 stay**, §9.14), and all three places that
assert it have been updated (§8.15.2 here, `wms2-keycloak-role-matrix.md` §1.2, and
`3-Resources/reports/260826-wms-admin-to-super-admin-authz-axis-audit.md` §4). The figure passed through
17 → provisional → 15 in one day; if a fourth site ever asserts it, update all four together.

#### 8.16.4 Recommendation for the SBDEV-3103 PR

That PR should carry a line naming this, so whoever implements this tranche meets it before touching
`PutawayConfigService`. Also worth adding to `:289-290`'s "the annotation IS the behaviour" comment:
*"…and therefore cannot be migrated to an interceptor-enforced annotation"* — otherwise the empty body
reads as safe to re-home.

#### 8.16.5 ✅ DECIDED 2026-08-26 (Nam): option (a) — CARVE THEM OUT

**`PutawayConfigService:257` and `:287` stay on `@PreAuthorize(Authority.IS_SB_ADMIN)`.** They join
`AdminController:237`, `ReplenishmentReconciliationController:37` and `AdminActionController:341` in the
stay-on-`sb_admin` set, so the tranche's split became **15 move / 5 stay** (now **9 move / 11 stay**, §9.14).

⚠ **Decision history, recorded because this section briefly said the opposite.** An earlier revision of
§8.16.5 recorded option (b) — programmatic gating — on a first instruction. Nam then asked for both
options written up with a recommendation, was advised (a), and confirmed (a) directly: *"I changed my
mind after hearing your peer's explanation. I will go (a)."* (a) supersedes. The three reasons on
record:

1. **Security direction.** This surface exists as a ticket *because* a gate was bypassable. (b) trades
   an unforgeable gate for a forgeable one — see §8.16.6 — to buy per-role granularity nobody has asked
   for on tier-3 putaway config. That is the identical argument that already carved out the other three.
2. **Prerequisite chain.** (b) needs the self-grant hole closed, then `FunctionGuardInterceptor` on
   `main`, and the whole authz programme is still develop-only. (a) needs nothing.
3. **Cost asymmetry.** (a) costs a number in a plan. (b) costs a test-suite rewrite plus a regression
   window — and both fall on the side with the worse security properties.

---

#### 8.16.5a The (b) shape, retained as CONDITIONAL — not the plan of record

Kept only so that a future revisit does not re-derive it, and because it is the *only* correct shape for
(b) if the carve-out is ever reversed. **Do not implement from this section.**

`PutawayConfigService:257` (`validateOnly`) and `:287` (`requireWarehouseConfigWriteAuthority`) **stay on
the function axis** and are **not** carved out onto `sb_admin`. So the tranche's split stays **17 move /
3 stay**, and the "provisional" markers added at the three count sites can be resolved back to 17.

If (b) were ever chosen, "programmatically" has exactly one correct shape:

| Aspect | Decision | Why |
|---|---|---|
| **Check** | `accessService.doesUserHaveAccess(WmsConstants.FunctionEnum.WEB_UI_ACTION_SET_PUTAWAY_DESTINATION_DEFAULTS)` in the **method body** | `AccessService:82` returns `boolean`. `checkAnyAccess` (`:134`) returns an `AccessDecision` and is the richer form if the denial needs a reason for the audit trail |
| **Which function** | the **`_DEFAULTS`** half of §8.12 F4's split, not `_SKU` | both sites are the WAREHOUSE/HAL tier-3 boundary; `_SKU` is tier 1 |
| **On denial** | `throw new org.springframework.security.access.AccessDeniedException(...)` | see below — this is the only choice that preserves today's behaviour exactly |
| **Annotation** | remove `@PreAuthorize(IS_SB_ADMIN)`; add **no** `@RequiresFunction` | §8.16: on these two it is inert, and leaving it there would read as a gate |

**Why `AccessDeniedException` and nothing else — and why this is behaviour-preserving rather than
hopeful.** Two constraints intersect:

1. **It must be unchecked.** A `@HandleBefore*` method cannot declare a checked exception, and one
   thrown from there surfaces as a **500** rather than the intended status — the documented reason
   `PutawayConfigValidationException` is unchecked (`PutawayConfigService:251-256`).
2. **It cannot reuse the interceptor's denial path.** `FunctionGuardInterceptor` denies by writing the
   response directly — `response.setStatus(HttpStatus.FORBIDDEN.value())` at `:274` and `return false` —
   which is available to a `preHandle`, not to a service method. A service must throw.

`AccessDeniedException` satisfies both, and critically it is **exactly what `@PreAuthorize` throws
today** from this same method, inside this same SDR call stack, producing the 403 that SBDEV-3103 relies
on. So the swap changes *who* is asked, not *what happens* — the exception, the filter that catches it
(`ExceptionTranslationFilter`, above the dispatch), and the status are all unchanged. That is the
strongest property this migration can have on a security boundary, and it is verifiable from existing
behaviour rather than by argument.

#### 8.16.6 🔴 Why (b) was rejected — and what still binds if it is ever revisited

**REASON 1 / PREREQ 1 — (b) is strictly weaker than today until the self-grant hole closes. This is the
decisive argument for the carve-out, not merely a sequencing note.** A function
grant is self-grantable while `UserFunctionRepository`'s SDR write is open (§8.12.1). `sb_admin` is not:
measured 2026-08-26, it reaches the authority set as a **bare client role** in
`resource_access[om1-api]`, which nothing a `wms_user` can write produces. Until that hole closes, any
`wms_user` could self-grant `WEB_UI_ACTION_SET_PUTAWAY_DESTINATION_DEFAULTS` and perform the tier-3
identity move — **re-opening SBDEV-3103's bypass through a different door.** This is not a
nice-to-have ordering preference; shipping (b) before it is a net regression.

**PREREQ 2 — the tenant context must be present, which it is here but is not universal.**
`doesUserHaveAccess` resolves through the tenant DB (`user → group → role → function`). SDR writes are
`/v3/**` requests carrying `X-Tenant-ID` + `facility_code`, so `TenantContext` is set and the read
works. ⚠ This is the specific reason the same technique **cannot** be used for `/actuator/**` and the
other tenant-less surfaces (§8.15.3): there the read would hit the landlord DB and yield `42P01` → 500.
Do not generalise (b) to those.

**COUPLING — SBDEV-3103's tests assert the wrong thing under (b).** `:287`'s body is currently *empty*:
the annotation **is** the behaviour (`:289-290`), so 3103's suite legitimately asserts that the handler
**calls** the method. Under (b) the body gains a real check, and "the handler called it" stops implying
"the caller was authorized" — a mutant that guts the check body would keep all of 3103's mutants green.
So (b) must land with 3103's assertions **rewritten to assert the check**, not the call: stub
`accessService` to deny and assert the write is refused. Flagged to the SBDEV-3103 author 2026-08-26.

**Net sequence, if (b) is ever revisited:** close the `UserFunctionRepository` SDR write → land the
interceptor on `main` → then (b), together with the 3103 test rewrite, in one change. Under the (a)
decision none of that is needed, and `:257`/`:287` simply keep the gate they have.

---

## 9. CONSOLIDATED WORK BREAKDOWN — 2026-08-26

**Why this section exists.** The state of this ticket was spread across eight revision sections
(§8 … §8.16), each amending the last, three of them superseded. Answering *"what is left?"* required
reading all of them in order and knowing which had been retired. This section is the single answer.
It supersedes nothing — it indexes. Where it disagrees with a §8.x section, §8.x is the detail and
this table is the status.

Tiers use this repo's router (`wms-triage`), which runs **T0–T3**; there is no T4.

### 9.1 DONE — on `origin/develop`, verified

| Work | Evidence |
|---|---|
| **Slice A** — SDR gate enforcement point (`MappedInterceptor` bean, no `addInterceptors` override) | PR #187, merge `5b704e54` |
| **Slice C** — `bulkTransferStock` gate bypass closed | PR #189, merge `e44e9721` |
| **§8.12.1 — `UserFunctionRepository` SDR write withdrawn.** The slice-wide blocker: while open, a function grant was forgeable by renaming a held function, defeating *every* gate this plan adds and every gate SBDEV-2870 already shipped | PR #209, merge `790206b7` |

**§8.12.1's fix is not what §8.12.1 specified,** and the difference matters. It proposed
`exported = false` *"after confirming the UI reads the catalogue through `UserRoleController` rather
than SDR."* **That precondition is false** — `store/admin/function.js:25`,
`store/admin/management.js:139,156` and `store/admin/role.js:58` all read it over SDR, so
`exported = false` would have broken the Roles and Management screens. Shipped instead: withdraw only
the WRITE verbs via `ExposureConfiguration`, the pattern already applied to six sibling types. GET
survives. Measured on dev as a plain `wms_user`: `PATCH /v3/userFunction/{id}` **200 → 405**,
`POST /v3/userFunction` **→ 405**, `GET` still **200**, `userRoleUserFunction` control unchanged.

### 9.2 NOT STARTED — the core deliverable

`plan-state.sh SBDEV-3017` reports **no implementation worktree**. All 20 `@PreAuthorize(IS_SB_ADMIN)`
sites are still on `develop` exactly where §8.15.2 found them. **Zero of the 15 have moved.**

### 9.3 Remaining work, tiered

| # | Task | Tier | Blocking | Note |
|---|---|---|---|---|
| **R1** | **Finish the §8.1 grant check** — ~56 of ~97 rows never had it; apply AC-2′ | **T2** | 🔴 yes | The chief blocker (§8.10 item 1). Analysis against live tenant data. Escalates to **T3** if it breaks a row the way §8.2's did |
| **R2** | Re-read the three §1 lane tables reasoning from *"the web UI has no function gating"* — **false** per §0.F | **T2** | 🔴 yes | Those rows were *chosen* under a wrong model, so the constants may be wrong, not merely unverified. Per §0.F a wrong constant makes the whole **screen** unreachable, not a button 403 |
| **R3** | Reconcile §1's tables against the §8.6 boundary — `ClubLineController`, `TransfersController`, `setPutAwayLocation` need mapping rows | **T2** | 🔴 yes | §8.10 item 2 |
| **R4** | Decide the test strategy for AC-1…AC-4 / AC-7 — **no lane in this repo evaluates `@PreAuthorize`**, so they are unachievable as written (§8.14.4) | **T2** | 🔴 yes | Without it those ACs cannot be closed honestly, only asserted |
| **R5** | Decide `POST /v3/unitLoad/reprintLabel`: ANY-of `{CONTAINER, CLUB_LINE, TRANSFER_ORDER}` vs a new `WEB_UI_ACTION_REPRINT_UNIT_LOAD_LABEL` | **T1** | no | §8.10 item 3. The ANY-of needs R1 first |
| **R6** | `ShipperIdController`'s third mutating handler `GET /v3/shipperId/delete/{id}` — §0.C's blanket exclusion orphans it permanently | **T1** | no | §8.10 item 4 |
| **R7** | **`/rest/**` reaches three of this tranche's capabilities UNAUTHENTICATED**, `advice/create` among them | **T3** | no — **file separately** | §8.10 item 5. A different exposure from function gating; it should not ride in on this tranche. Cross-reference `260520-rest-security-permitall-hardening` per endpoint |
| **R8** | **The implementation** — 9 sites move / 11 stay (§9.14), 2 new constants, Flyway `V2.2.22`, the 6 deletions | **T3** | after R1–R4 | Authorization + a migration + multi-repo. Do not start before R1–R4 close |

### 9.4 NOT this ticket's work — recorded so it is not mistaken for a blocker

- **§8.11.5 release sequencing.** `FunctionGuardInterceptor` must reach prd before any `@PreAuthorize`
  is dropped. **This is dev-ops', not engineering.** Nam 2026-08-26: development merges go to
  `develop` only; promotion to `release` (QA) and `main` (production) is dev-ops' decision and
  requires approval. The topology is **`develop → release → main`** — and the interceptor
  (`security/FunctionGuardInterceptor.java`) is **already on `release`** at `v0.0.21`, absent only from
  `main`. This plan states the dependency; it does not schedule it.
- **The aggregate-`PATCH` membership residual.** `PATCH` on `User`/`UserGroup`/`UserRole` carrying an
  association array still rewrites membership inline, because `store/admin/role.js:85` and
  `group.js:65` need those `$put`s. SBDEV-2984 / SBDEV-3013 territory; needs the UI's write path
  changed first.
- **SBDEV-3116** — the Keycloak group→client-role mapping is load-bearing for `/actuator/**` and the
  5 carved-out `sb_admin` gates, and cannot be asserted from this repo at all.

### 9.5 Production risk for the gates that ALREADY exist — distinct from R1

The two were conflated in a ClickUp comment on 2026-08-26. Recorded because the conflation runs in the
optimistic direction:

- **R1** asks: *will the ~92 gates this plan ADDS reach their intended users?* — **41 of ~97 rows, open.**
- **This** asks: *will the 20 gates already on `develop` break production when promoted?* — **closed, clean.**

From the prd landlord, production has exactly **one** active v2 tenant: `hydra` / `nywh` →
`wh01_hydra_v2`, at Flyway `V2.2.21`. All **20** functions referenced by a `@RequiresFunction` on
develop are present in its catalogue, and all **7 human users hold all 79 functions** (`admin`,
`bcampbell`, `davido`, `jgero`, `panderson`, `thomasjr`, `tomh`). The only accounts holding nothing are
service accounts — `anonymous` and `oms_integration`, both with zero group memberships. So enforcement
is a **no-op for every human production user**.

⚠ `oms_integration` holding zero functions is the mechanism §8's *"STOP before tranche 1"* flagged.
Harmless for the 20 gates that exist (mobile controllers + web unit-load actions; OMS integrates over
`/rest/**`, a `permitAll` path) and a real break the moment this tranche gates a `/v3/**` endpoint OMS
calls. **R8 must resolve it before shipping** — grants for that account, or an explicit exclusion.

⚠ A prior revision claimed prd `wh01_om1` was "WineCo production, outside Flyway, missing 3
functions." **Retracted — that is a WMS v1 database**, and the function diff behind the claim compared
a v1 schema to a v2 one. WineCo has **no v2 production tenant**. Derive the tenant set from
`tenant` ⋈ `tenant_db_configuration` in the landlord, never from DB names in a connection list.

### 9.6 R1 EXECUTED — 2026-08-26. The grant check is complete; 2 findings, and one of my own conclusions was wrong

Ran §0.G across **all 51 distinct functions** referenced by §1's ~97 rows (§8.1 had covered 14), on the
reference tenant `dev_wh01_om1`. Real personas only — numeric `ROLE0000xx` and the Cypress/test roles
(`cy-test-role-*`, `ew`, `ww`, `testr`, `test group`, `test role2`, `ibrarist`) excluded, per §8.1's
named-vs-numeric distinction and F9.

**Result: 37 of 51 reach more than one real persona. 8 are super-admin-only. 6 do not exist at all.**

#### 9.6.1 🔴 FINDING 1 — six functions in §1 exist NOWHERE, and §2.3 plans to create only two

Absent from the `mywms_function` catalogue, from `WmsConstants.FunctionEnum`, **and** from
`wms2-web-ui util/appMenuList.js` — i.e. they are names this plan invented, not constants read out of
the map §0.F says to read rather than derive:

| function | accounted for? |
|---|---|
| `WEB_UI_VIEW_SYSTEM_MANAGEMENT` | ✅ §2.3 creates it |
| `WEB_UI_ACTION_RECOVER_STUCK_PALLETS` | ✅ §2.3 creates it |
| `WEB_UI_VIEW_SHIPPER_ID` | ✅ §2.3 defers it (`ShipperIdController` excluded by §0.C) — but §1 still cites it, so those rows are stale |
| `WEB_UI_ACTION_REPRINT_UNIT_LOAD_LABEL` | ⚠ R5's *undecided* proposal. If R5 picks it, §2.3 and §2.4 must grow |
| **`WEB_UI_ACTION_GENERATE_TOTE_LABELS`** | 🔴 **unaccounted** |
| **`WEB_UI_VIEW_CREATE_BILL_OF_LADING`** | 🔴 **unaccounted** |

A `@RequiresFunction` naming a non-existent function **denies everyone, super-admin included** — no role
can hold a row that is not there. No live bug today (nothing references them yet), so this is a plan
defect, caught before implementation. **This is R2's failure mode showing up in R1's data:** those rows
were authored by deriving a plausible constant name instead of taking it from `appMenuList.js`.

⚠ **Knock-on to §2.4, which is keyed to the count.** §2.4's hazard note reads *"This file adds **two**, so
it must be **two separate** `INSERT … SELECT` statements"* — each recomputing `MAX(id)` with its own
`WHERE NOT EXISTS` on `function`. If the real count becomes 4 (or 5 with R5), `V2.2.22` needs **that many**
separate INSERTs. A single multi-row insert hands every row the same id, which on a tenant missing the PK
**inserts silently**. Update the count and the statement count together, or the migration is wrong in
exactly the way §2.4 warns about.

#### 9.6.2 AC-2′ on the 8 super-admin-only functions — 5 fine by construction, 2 fine by design, 1 open

Five are themselves the **menu-leaf gate** for the screen they protect, so anyone who can reach the screen
holds the function and AC-2′ is satisfied trivially: `WEB_UI_VIEW_CLIENT` (Shippers),
`WEB_UI_VIEW_IMPORT_DATA` (System Management), `WEB_UI_VIEW_PRINTER` (Label Printing + Printer Setup),
`WEB_UI_VIEW_SYSTEM_PROPERTY` (Parameters & Configuration), `WEB_UI_VIEW_USER_MANAGEMENT` (User Management).

Three are **action gates on a screen whose view gate is a different function** — the §8.2 shape:

- **`WEB_UI_ACTION_DELETE_UNIT_LOAD` — resolved, and NOT a defect.** I initially recorded this as an
  already-shipped AC-2′ violation and that was **wrong**. The Handling Units screen is ANY-of
  `[WEB_UI_VIEW_STOCK_UNIT, WEB_UI_VIEW_CONTAINER]`, reachable by `CS-REP`, `inventory-manager`,
  `super-admin`, while the action is super-admin-only — but **SBDEV-2967-C anticipated exactly this** and
  disables the control for non-holders (`components/handlingUnits/containerTable.vue:245-251`, quoting risk
  C-R1: *"every non-super-admin … would otherwise see an enabled Delete that 403s"*). **This establishes
  the pattern AC-2′ should be read through:** a narrow action grant is legitimate provided the UI disables
  the control. AC-2′ is not "widen every grant to the screen's population."
- **`WEB_UI_ACTION_PRINT_TOTE_LABELS`** — §8.2's flagship outage, already corrected there. One UI
  reference (`pages/admin.vue`); re-confirm it follows the disable pattern when R8 lands.
- 🔴 **`WEB_UI_VIEW_ORDER_DETAIL_MONITOR` — OPEN.** Super-admin-only, **zero** UI references, and not a
  menu leaf. So there is no disable pattern protecting it and no screen gate aligning with it. R8 must
  either align it with the Order Monitor screen's gate (`WEB_UI_VIEW_ORDER_MONITOR` — CS-REP,
  outbound-manager, super-admin) or establish why super-admin-only is correct here.

#### 9.6.3 R1 status

**R1 is DONE for the reference tenant.** 51 of 51 checked, up from 41 of ~97 rows. Outstanding from it:
two unaccounted constants (9.6.1), one open AC-2′ row (9.6.2), and the §2.4 count knock-on. None of these
require new investigation — they are decisions for R8, and they are now enumerated rather than latent.

⚠ **Scope of this evidence.** One tenant, `dev_wh01_om1`. Grants are per-tenant data, so a tenant with
different personas can violate AC-2′ where this one does not. The check is repeatable — the query is in
this section's provenance — but do not read "R1 done" as "AC-2′ holds everywhere."

### 9.7 R2 EXECUTED — 2026-08-26. §1's constants compared against the map, not re-derived. 4 findings

§8.10 item 6 says three §1 lane tables reason from *"the web UI has no function gating"*, which §0.F
declares false. R2 tests the consequence: were the constants **read** from `util/appMenuList.js`, or
derived? Method — diff §1's 51 constants against the 34 the map declares, then for every §1 constant that
is a **sub-resource view gate**, compare its real-persona set against the persona set of the menu leaf
whose screen dispatches it. A child narrower than its parent is §0.F's failure mode: the screen renders
for a persona the endpoint then refuses.

**29 of 51 agree with the map.** Of the 22 that do not, most are legitimate:

- **6 `WEB_UI_ACTION_*`** — action gates. `appMenuList` declares *menu-leaf view* gates only, so absence is
  correct by construction, not a defect.
- **4 `MOBILE_UI_*`** — the mobile UI's map is `wms2-mobile-ui store/home.js`, a different file. Out of
  scope for a web-map comparison.
- **12 `WEB_UI_VIEW_*`** — the real question, resolved below.

#### 9.7.1 🔴 Four pairs where the endpoint gate is NARROWER than the screen that reaches it

Real personas only, `dev_wh01_om1`:

| screen (menu leaf) | endpoint gate | verdict |
|---|---|---|
| Inbound Notices — `WEB_UI_VIEW_INBOUND_BOL` | `WEB_UI_VIEW_CREATE_INBOUND_BOL` | 🔴 **CS-REP** reaches the screen, lacks the function |
| Inbound Notices — `WEB_UI_VIEW_INBOUND_BOL` | `WEB_UI_VIEW_RECEIVING` | 🔴 **CS-REP** reaches the screen, lacks the function |
| Dashboard — `WEB_UI_VIEW_ORDER_MONITOR` | `WEB_UI_VIEW_ORDER_DETAIL_MONITOR` | 🔴 **CS-REP, outbound-manager** reach the screen, lack the function |
| Outbound BOL — `WEB_UI_VIEW_BILL_OF_LADING` | `WEB_UI_VIEW_CREATE_BILL_OF_LADING` | 🔴 **absent from the catalogue entirely** (§9.6.1) |

Five pairs are clean — `GOODS_RECEIPT_POSITION`, `INBOUND_BOL_ITEM_LINES`, `CYCLECOUNT_POSITION`, `ORDER`,
`ORDER_BATCH` are each **⊇** their parent.

The Dashboard row **confirms §9.6.2's open item with named personas**: `WEB_UI_VIEW_ORDER_DETAIL_MONITOR`
is super-admin-only while the Dashboard is reachable by CS-REP and outbound-manager. Unlike
`WEB_UI_ACTION_DELETE_UNIT_LOAD`, it has **zero UI references**, so no disable-the-control pattern protects
it. R8 must either align it with `WEB_UI_VIEW_ORDER_MONITOR` or record why super-admin-only is right.

⚠ **The parent↔child pairings above are MY inference, not read from evidence.** Deriving instead of
reading is the exact error §0.F names and the one that produced §9.6.1's two invented constants — so I am
flagging my own method rather than presenting these as settled. §1 already carries the store action →
component → route → menu-entry chain per row; **R8 must confirm each pairing against that chain** before
acting. The four findings are hypotheses with measured persona sets, not verdicts.

#### 9.7.2 ⚠ The map itself has two derived entries — §0.F's rule needs this caveat

§0.F says *"the constant map already exists — read it, do not derive it."* Sound, with an exception it does
not state: **`appMenuList.js` marks 2 of its own entries `⚠ semantics-derived`** —

- `:39` Dashboard → `WEB_UI_VIEW_ORDER_MONITOR`
- `:59` Pick Pack → `WEB_UI_VIEW_PICKING_ORDER`

Both are load-bearing here. The Dashboard entry is the **parent** in the third finding above, so that
row's persona comparison rests on a derived premise; and `WEB_UI_VIEW_PICKING_ORDER` is the parent for the
two clean `ORDER` / `ORDER_BATCH` rows. Reading the map is still right — but for these two leaves the map
is an assumption, and both need a UI confirmation (which route guard actually fires) rather than a citation.

#### 9.7.3 R2 status

**Analysis complete; the decisions belong to R8.** Outputs: 4 narrower/absent pairs to resolve, 1 of them
overlapping §9.6.2, plus the two derived map entries to confirm. What R2 has *not* done — and what would
need a UI-side pass — is verify the pairings against §1's caller chains (9.7.1) and confirm the two derived
leaves (9.7.2). Neither is blocking further analysis, but both must close before R8 writes an annotation.

### 9.8 R4 EXECUTED — 2026-08-26. PR #210, merge `71e30679`

**Two corrections to R4's own framing first.** §9.3 described R4 as "the test strategy for AC-1…AC-4 / AC-7."
Those AC numbers are **§8.13.6's**, and §8.13 was **retired by §8.15** — the R4 entry inherited a stale
reference. The live criteria are §6's AC-1…AC-8. And the premise *"no lane can test `@PreAuthorize`"* is too
strong: it is testable in **two** halves, and a third leg was missing entirely.

| what | mechanism | state |
|---|---|---|
| the SpEL expression's **meaning** | `CustomMethodSecurityExpressionRootUnitTest`'s production-faithful `evaluate(...)` harness (29 tests) | already existed |
| **which expression** sits on which method | named reflection on `Method.getAnnotation(PreAuthorize.class).value()` | added by PR #210 |
| the mechanism is **switched on at all** | `@EnableMethodSecurity` + the handler `@Bean` | **was pinned by NOTHING** |
| `@RequiresFunction` end-to-end | `BaseControllerUnitTest`'s interceptor-installed MockMvc mode | already existed |

#### 9.8.1 🔴 The finding: one deletion silently voided every `@PreAuthorize` gate

No test referenced `MethodSecurityConfig` or `@EnableMethodSecurity`. Deleting the annotation, deleting the
class, or flipping `prePostEnabled` to `false` makes **all 20 `@PreAuthorize(IS_SB_ADMIN)` sites inert at
once** — including the five §8.16.5 keeps on `sb_admin` *because a function gate is weaker there* — and the
suite stays green, because `standaloneSetup` installs no method-security advisor
(`FunctionGuardArchTest:777-779` states this and bans the combination).

`CustomMethodSecurityExpressionRootUnitTest` cannot cover it: it constructs
`new CustomMethodSecurityExpressionHandler()` **directly**, so it proves the SpEL means the right thing and
not that Spring runs it. **Same shape as PR #206's dead bean** — a test pinning a class rather than its
wiring, beside a `@Bean` never consulted. Twice in the security config in one day.

Also adds the tripwire **§8.16.4 asked for**: named assertions that the 5 carve-outs still carry
`@PreAuthorize(IS_SB_ADMIN)`. 7 mutants, all killed by the correctly-named assertion. Full suite 5645/0/67.

⚠ **One attempted mutant was a compile error, not a mutant** — `Authority.IS_WMS_USER` does not exist
(`IS_SB_ADMIN` is the only `IS_` constant). It produced no test result at all, and only the missing
`Tests run:` line distinguished it from a kill. Redone with a literal expression.

---

### 9.9 R3 EXECUTED — 2026-08-26. The census re-derived, and it took four attempts to get right

§8.6 rewrote AC-1 to the **boundary** — *every ungated state-changing MVC endpoint on `develop`, enumerated
at implementation time* — rather than to §1's tables. R3 runs that enumeration against `develop @ 71e30679`.

#### 9.9.1 §8.6's named gaps, re-checked. Nine are still ungated; one has since been gated

| endpoint | 2026-08-24 | now |
|---|---|---|
| `ClubLineController` — `runClubLine`, `assignStagingLane`, `unlinkStagingLane`, `activateBatch` | ungated | 🔴 **still ungated** (×4) |
| `TransfersController` — `runTransfer`, `assignTransferLane`, `reassignTransferLane`, `unlinkTransferLane`, `activateTransferOrder` | ungated | 🔴 **still ungated** (×5) |
| `PickingOrderPositionController.fixPickingPosition` | ungated | 🔴 **still ungated** |
| `ItemDataController.setPutAwayLocation` | "ungated" | ✅ `@PreAuthorize` at `:106` — consistent with §8.11.1's correction |
| `UserAdministrationController` ×2 writes | "ungated" | ✅ **guarded programmatically** — `denyUnlessUserManagementAllowed()` at `:132`, deliberately outside the `try` |

So §8.6's substance holds: the ClubLine/Transfers/fixPickingPosition gaps are real and untouched. Two of its
rows were already stale.

#### 9.9.2 The current census — and the four ways my own sweep was wrong before it was right

**MVC only, `/rest/**` excluded** (a `permitAll` surface — R7's territory — and `UtilRestController` is
`@Service`, so its 7 mappings do not route at all):

| | |
|---|---|
| state-changing by verb, annotation-gated | **61** |
| state-changing, guarded **programmatically** | **2** |
| 🔴 **state-changing, neither** | **93**, across 27 controllers |

Each correction below silently changed the number, and any one of them alone would have produced a
confident wrong answer. **This is the strongest available argument for §8.6's decision to make AC-1 an
implementation-time enumeration rather than a table:**

1. **`@RequestMapping(value=…, method = RequestMethod.POST)`** is a mutating handler that a `@PostMapping`
   grep does not see. `UserAdministrationController` and `TokenController` use only this form.
2. **A javadoc quoting `{@code // @PreAuthorize(...)}` within 12 lines of a handler read as a real gate** —
   3 false "gated" results. This is the comment-quoting trap
   `ControllerRequestMappingConventionUnitTest` documents and strips for; the census must strip comments too.
3. **Programmatic guards are invisible to an annotation grep.** `denyUnlessUserManagementAllowed()`,
   `doesUserHaveAccess(...)`, `checkAnyAccess(...)` are real gates with no annotation. Counting only
   annotations reports guarded endpoints as naked.
4. **Verb is not the boundary.** A name-based mutating-GET heuristic surfaced 41 candidates of which many are
   reads (`listPrinters`, `getPrinterTypes`, `unitloadDetailsById`) — so the GET half needs a handler read,
   not a pattern. §8.6 already said this about `setPutAwayLocation`; it generalises.

**Consequence for R8: the 93 figure is a floor for the by-verb half only.** The mutating-GET half is not
mechanically enumerable and needs per-handler reading — which is what §8.6 meant and what R3 cannot finish
by script. Any future census must detect **two mapping styles × three gate mechanisms**, with comments
stripped, or it will be wrong in whichever direction its bug points.

#### 9.9.3 R3 status

Reconciliation done; the enumeration is **partially mechanical by construction**. Delivered: §8.6's rows
re-verified (9 still open, 2 stale), the by-verb census at 93, and the four census-method requirements above.
Not delivered, and not scriptable: the mutating-GET half. R8 must read those handlers.

### 9.10 R5 DECIDED — 2026-08-26. ANY-of, but with FOUR members, not three

§8.10 item 3 asked: gate `POST /v3/unitLoad/reprintLabel` on ANY-of
`{CONTAINER, CLUB_LINE, TRANSFER_ORDER}`, or mint `WEB_UI_ACTION_REPRINT_UNIT_LOAD_LABEL`?

**The premise checked out, and the member list was one short.** The endpoint has exactly one store caller
(`store/handlingUnits/container.js:206`) but **three dispatching screens**, because all three embed the same
popup — `~/components/handlingUnits/popups/reprentLabel.vue` (filename typo is real):

| screen | component | screen gate |
|---|---|---|
| Handling Units | `handlingUnits/popups/reprentLabel.vue` | ANY-of `[WEB_UI_VIEW_STOCK_UNIT, WEB_UI_VIEW_CONTAINER]` |
| Club Runs | `processes/clubRuns/tabTables/inventoryOnLaneTable.vue:67,74` | `WEB_UI_VIEW_CLUB_LINE` |
| Transfer Picking | `processes/transferPicking/tabTables/inventoryOnLane.vue:67,74` | `WEB_UI_VIEW_TRANSFER_ORDER` |

⚠ `POST /report/reprintLabels` (**plural**, `ReportController`) is a **different endpoint** on the Parcel
Picking screen. Do not conflate them — `store/reports/parcelPicking.js:128`.

Persona sets, re-measured on `dev_wh01_om1` (not taken from §8.1's two-day-old table):

| function | personas |
|---|---|
| `WEB_UI_VIEW_CONTAINER` | CS-REP, inventory-manager, super-admin |
| `WEB_UI_VIEW_STOCK_UNIT` | inventory-manager, super-admin |
| `WEB_UI_VIEW_CLUB_LINE` | CS-REP, outbound-manager, super-admin |
| `WEB_UI_VIEW_TRANSFER_ORDER` | inventory-manager, outbound-manager, super-admin |

Union of screen-reachers = **CS-REP, inventory-manager, outbound-manager, super-admin**. The 3-member ANY-of
satisfies all four **today**.

✅ **DECISION: ANY-of `{STOCK_UNIT, CONTAINER, CLUB_LINE, TRANSFER_ORDER}` — four members.** Reasons:

1. **`STOCK_UNIT` was omitted and belongs.** It is half of the Handling Units ANY-of, so a role holding
   `STOCK_UNIT` alone reaches the screen and fails the reprint. No such role exists today (STOCK_UNIT ⊆
   {inventory-manager, super-admin}, both of which hold CONTAINER), so it is **latent, not live** — but the
   3-member list is correct only by accident of the current grants.
2. **No new constant.** R1 (§9.6.1) found §2.4's INSERT-count hazard is keyed to the number of new constants;
   a new action constant grows it again for no functional gain.
3. **No new grant decision, so no §8.2 outage risk.** A freshly-minted `WEB_UI_ACTION_*` has to be granted to
   four personas or it locks them out — and §8.1 measured `WEB_UI_ACTION_PRINT_TOTE_LABELS` landing at
   super-admin-only, which is exactly that outage.

⚠ **The cost, and the mitigation.** The popup is a **shared component**, which is how this became three
screens; a fourth host silently needs a fifth ANY-of member and nothing would catch the drift. **Mitigation:
a Jest test pinning the set of components that import `reprentLabel.vue`**, so adding a host goes red until
the gate is revisited. That is a genuine cross-file invariant, the case where a test earns its place.

---

### 9.11 R6 DECIDED — 2026-08-26. §0.C's exclusion is one endpoint wide; the other two are DEAD, not orphaned

§8.10 item 4 named `GET /v3/shipperId/delete/{id}` as permanently orphaned by §0.C's blanket exclusion. It
undercounted: **`POST /update` has the same shape and was never named.**

`ShipperIdController` has three mutating handlers, and §0.C's justification covers exactly one:

| endpoint | caller | verdict |
|---|---|---|
| `POST /v3/shipperId/create` | **OMS** — `WmsApiService::createShipperId:3319` → `getWmsEndpoint('shipperid_create')` | ✅ stays ungated, §0.C. A function check here evaluates against an OMS user with no `mywms_user` row → 403 → facility sync fails |
| `POST /v3/shipperId/update` | **none** — zero refs in wms2-web-ui, wms2-mobile-ui, oms-laravel-api | 🔴 dead |
| `GET /v3/shipperId/delete/{shipId}` | **none** — same | 🔴 dead |

**OMS has no `updateShipperId` or `deleteShipperId`.** It creates only.

✅ **DECISION: propose both for §0.E DELETION rather than gating**, taking §2.5's six deletions to eight.
Gating them would mint `WEB_UI_VIEW_SHIPPER_ID` — which R1 found exists in neither the catalogue,
`FunctionEnum`, nor `appMenuList.js` — to protect two endpoints nothing calls. §2.3's decision to defer that
constant is therefore **correct**, and R1's "unaccounted absence" for it resolves as intended-to-defer.

⚠ **This needs Nam's confirmation before R8 acts on it, and the conservative fallback is gating.** "Zero
callers in three repos" is not "zero callers" — a Postman collection, a support runbook or a manual
operator step would not appear in any of them. Deleting an endpoint is materially harder to walk back than
gating one. If confirmation is not available, gate both on `WEB_UI_VIEW_CLIENT` (the Shippers screen's
existing gate) and leave the deletion to a later pass.

⚠ **Method note, because it nearly produced the opposite answer.** My first search for OMS callers grepped
the literal `shipperId/` and returned **nothing**, which would have made `/create` look dead too and
contradicted §0.C. OMS builds the path from a **config key** (`getWmsEndpoint('shipperid_create')`), so no
literal path appears in the source. **A route grep must search the endpoint-registry key as well as the
literal path** — the third wrong-shape grep on this ticket in one day (§9.6.1's derived constants and
§9.9.2's annotation census being the others).

### 9.12 R8 PREREQUISITE — the SDR-twin sweep. Surfaced by R6's two review lanes, 2026-08-27

**Why this exists.** R6 gated two MVC endpoints and its comments said the writes were protected. A review
lane found `ShipperidRepository` SDR-exported with write verbs never withdrawn, so an equivalent route to the
same table stayed open — measured live, `PATCH /v3/shipperid/{id} {}` → **HTTP 200** as a plain `wms_user`.
**I had closed exactly that pattern on `UserFunction` in PR #209 hours earlier and did not apply it to my own
next change.** R8 annotates 11 sites; without this sweep it ships up to 11 comments claiming protection it
does not deliver.

#### 9.12.1 The estate-wide numbers, measured on `develop @ 38861ad7`

| | |
|---|---|
| `@RepositoryRestResource` repositories (class-level annotation, not a method-level grep) | **62** |
| domain types carrying a `forDomainType(...)` write withdrawal in `RestConfiguration` | **7** — `User`, `UserFunction`, `UserGroup`, `UserGroupUser`, `UserGroupUserRole`, `UserRole`, `UserRoleUserFunction` |
| 🔴 exported **+** write-capable **+** not withdrawn | **44** |

Every withdrawal in the codebase is on the access-decision chain. **No business entity has one.**

#### 9.12.2 The migrating sites' own entities — and why the answer is NOT "44 holes to plug"

| entity | SDR resource | write-capable & unwithdrawn? | but is the putaway semantics guarded on the SDR path? |
|---|---|---|---|
| `Sysprop` | `/v3/sysprop` | 🔴 yes | ✅ **yes** — `PutawayConfigRepositoryEventHandler` `onBeforeCreate/Save/Delete(Sysprop)` call `validateOnly` / `requireWarehouseConfigWriteAuthority`, both `@PreAuthorize(IS_SB_ADMIN)`. Hardened by SBDEV-3103 |
| `Itemdata` | `/v3/itemdata` | 🔴 yes | ✅ yes — `onBeforeCreate/Save(Itemdata)` → `validateOnly(SKU, …)` |
| `Client` | `/v3/client` | 🔴 yes | ✅ yes — `onBeforeCreate/Save(Client)` → `validateOnly(MERCHANT, …)` |
| Keycloak user admin (`AdminController` ×8) | — | n/a | no JPA entity, so no SDR twin |

**So the tranche's own three entities are already covered on the SDR path — by the EVENT HANDLER, not by
`FunctionGuardInterceptor`.** That distinction is the whole of §8.16 and it now has a second consequence
worth stating plainly:

⚠ **The event-handler guard is `@PreAuthorize`-based, and §8.16 already established that
`@RequiresFunction` is inert there.** So R8 must not "improve" the SDR path by annotating the handler or the
service methods it calls — §8.16.5's carve-out of `PutawayConfigService:257`/`:287` is precisely what keeps
this guard working. The R4 tripwire (PR #210,
`MethodSecurityEnablementContractTest`) now pins those two annotations, so an accidental migration goes red.

⚠ **The `Sysprop` row also depends on `@EnableMethodSecurity`**, which nothing pinned until PR #210. Losing
it would silently disarm the SDR putaway guard as well as the 20 MVC gates — the two findings compound.

#### 9.12.3 What R8 must therefore do, per site

For each of the 15, answer three questions **before** writing an annotation, and record the answer in-code:

1. **Does the written entity have an SDR-exported repository with live write verbs?** (44 of 62 do.)
2. **If yes, is the semantics I am gating also guarded on the SDR path** — by a `@HandleBefore*` event
   handler, an `ExposureConfiguration` withdrawal, or `exported = false`? For the putaway three the answer is
   yes; for a site whose entity has no handler it is **no**, and the MVC gate then protects one of two routes.
3. **If no, say so in the comment.** "This narrows the MVC route, not the table" — do not let a comment imply
   the data is protected.

⚠ **Two method traps, both of which produced a wrong answer for me on this ticket:**
- `exported = false` **matches at METHOD level too**, which inverts the verdict for a class that is exported
  while one query is not. Read the **class-level** annotation, then `RestConfiguration`.
- A withdrawal is `forDomainType`-scoped, so grepping the entity name is not enough — `Shipperid` appears in
  `RestConfiguration` at `exposeIdsFor`, which withdraws **nothing** and reads like coverage.

#### 9.12.4 Scope note

This sweep covers the **11 migrating sites**. The tranche's wider ~92 rows touch many of the other 41 live
surfaces (`Advice`, `Billoflading`, `Customerorder`, `Cyclecount`, `FixLocationAssignment`, …), and **none of
those has an event handler**. Whether that is in scope for R8 or a separate slice is an open decision — but it
should be decided deliberately, not discovered after annotating. It is the same question §8.9 already
answered once ("~19 of ~92 rows gate nothing real") and the number should be re-derived with this method.

### 9.13 R7 FILED — SBDEV-3124, 2026-08-27. §8.10 item 5 is now tracked and OUT of this ticket

**SBDEV-3124** — *"`/rest/**` is permitAll — 15 write endpoints across 6 controllers are reachable
UNAUTHENTICATED, with the target tenant chosen by a client header."* Urgent.

Filed separately rather than folded in, per §8.10 item 5's own instruction that it needs a **per-endpoint**
cross-reference against `260520-rest-security-permitall-hardening` rather than a blanket decision.

Measured with no `Authorization` header:

```
OPTIONS /rest/advice/create   -> HTTP 200
OPTIONS /v3/shipperid         -> HTTP 401     <- control: /v3 DOES require auth
```

`AbstractRestController` carries no auth of any kind — no `@PreAuthorize`, no `@RequiresFunction`, no API
key, no shared secret, no `Principal` check — and `TenantFilter:40-49` takes the tenant from two
client-supplied headers, so an anonymous caller also picks the target database. 15 routable write endpoints
(`UtilRestController`'s 7 do not route: it is `@Service`).

**Why this outranks R8 on risk, recorded because it bears on sequencing.** R8 changes *which authenticated
role* may act, and on the only v2 production tenant all 7 human users hold all 79 functions, so its
enforcement is a measured no-op there (§9.5) — R8 is alignment with the axis decision, not risk reduction.
SBDEV-3124 is an unauthenticated write surface. `/rest/**` also requires **no** authority at all, where SDR
(§9.12) at least requires `wms_user`.

⚠ **The sequencing trap, carried onto the new ticket:** OMS's `WMS_AUTH_TYPE` defaults to **`none`**
(`oms-laravel-api config/wms.php:209`), so enforcing authentication at the WMS end before configuring the
caller breaks facility sync, advice creation and SKU sync **silently** — the same failure mode that justifies
§0.C's `/create` exemption. Configure the caller first.

**Two honest limits on the evidence, stated on the ticket:** no anonymous **write** was executed (a POST to
`/rest/advice/create` creates real data on a shared dev DB), so the finding is reachability plus absent
authentication, not a completed exploit; and it was measured on **dev**, whose network exposure may differ
from production.

#### 9.13.1 R8 sequencing is now an OPEN DECISION, not a default

With R1–R7 closed, R8 is the only remaining work — but §8.9 already re-sequenced this ticket
(*"Class A (SDR) leads slice B, not this MVC tranche"*) and §9.12 quantified why: 44 of 62 SDR repositories
carry live write verbs and **no business entity has a withdrawal**. So the question R8 must answer before any
code is written is **what R8 is**:

- **(a)** the 11 MVC sites only — cheapest, aligns the axis, leaves the SDR twins as recorded residuals;
- **(b)** an SDR slice first, then the MVC tranche — what §8.9 recommends, and what §9.12's numbers support;
- **(c)** both, scoped together — largest, and the one most likely to blow the tier.

Not a decision to make by starting to type. It changes what R8's four review lanes are even reviewing.

### 9.14 DECISION 2026-08-27 (Nam) — all four `AdminController` identity WRITES stay on `sb_admin`. Split is now 9 move / 11 stay

**Decision:** *"keep all four identity writes on sb_admin."*

| # | Site | Endpoint |
|---|---|---|
| 1 | `AdminController:120` `deleteUserByUsername` | `/user/deleteUserByUsername` |
| 2 | `AdminController:142` `ssoCreateUser` | `/user/createUser` |
| 3 | `AdminController:154` `ssoUpdateUser` | `/user/updateUser` |
| 4 | `AdminController:175` `resetUserPassword` | `/user/resetPassword` |

They join `importUserWithCsv:237`, so **`AdminController` keeps all five of its WRITES and moves only its
four READS** (`findUsers:79`, `findUserByUsername:107`, `findUserGroupsByUsername:133`,
`findGroupByName:247`).

**Split: 9 move / 11 stay.** 4 + 3 (`PutawayConfigController`) + 3 (`PutawayConfigService:96/:128/:165`) +
1 (`ItemDataController:105`) = **11**. Stay: 5 (`AdminController`) + 2 (`PutawayConfigService:258/:288`) +
`AdminActionController:341` + `ReplenishmentReconciliationController:37` = **9**. 11 + 9 = 20. ✓

#### 9.14.1 What raised it — the carve-out reason had been applied inconsistently

`:237` was carved out because it *"creates loginable Keycloak identities"* and SiteBoss staff are its only
intended callers. But `ssoCreateUser` **creates** identities, `deleteUserByUsername` **deletes** them, and
`resetUserPassword` **resets credentials** — and all three sat in the moving set. Either the carve-out reason
was really about the CSV bulk-migration path specifically, or those three belonged with it. Nam resolved it
the second way.

**The measured argument, and it is the substance of the decision.** Migrating them would have moved Keycloak
identity administration from an **unforgeable** gate to a **forgeable** one, and widened the population:

| | today | after migration |
|---|---|---|
| required | `sb_admin` — a bare Keycloak client role in `resource_access[om1-api]`, which **no `wms_user` can write** | `WEB_UI_VIEW_USER_MANAGEMENT` — a `mywms_function` row reached through group→role→function |
| holders on `dev_wh01_om1` | staff only (Keycloak-side) | **38 users** via `super-admin`, including customer users |
| holders on prd (`hydra/nywh`) | staff only | 7 — i.e. every human user |

On prd the change is a no-op either way (all 7 humans hold all 79 functions, §9.5). **On any tenant with
real personas it is a privilege expansion for identity administration** — the axis decision applied
literally, which is exactly the case worth deciding explicitly rather than by default.

⚠ Note the precedent this decision **declines to follow**: `UserAdministrationController`, migrated by
SBDEV-2870, gates its four `/v3/user/*` endpoints on `WEB_UI_VIEW_USER_MANAGEMENT` **programmatically**
(`:120`, `doesUserHaveAccess`), having chosen the function over the Keycloak group on the grounds that the
function's population was verifiable while the group's was not. That reasoning is sound and the outcome here
is different — so **the two controllers now guard comparable capabilities on different axes.** That
inconsistency is deliberate and should be recorded on SBDEV-2870 rather than silently tolerated; the
alternative is to re-carve those four too, which is a separate decision nobody has asked for.

#### 9.14.2 🔴 `ItemDataController:105` is now the riskiest of the 11, and it is BLOCKED

`setPutAwayLocation` would move onto `WEB_UI_VIEW_ITEM_DATA`, measured at **44 users on `dev_wh01_om1` via
`inventory-manager` + `super-admin`** — the widest population of any target function, and wider than the
38 that the identity writes were just protected from. §8.12's **F4** already ordered a split into
`_SKU` and `_DEFAULTS` for exactly this reason (tiers 2/3 sit behind super-admin-only view gates while
`inventory-manager` reaches 11 users). **That split is unresolved.** R8 must not annotate `:105` until it is,
or the tranche protects identity administration and simultaneously widens putaway-destination control.

#### 9.14.3 The R4 tripwire must grow from 5 to 9

`MethodSecurityEnablementContractTest` (PR #210) pins the 5 carve-outs by named reflective assertion, so an
accidental migration goes red. There are now 9. **The four new ones need the same pin** — and they need it
more than the original five, because an identity write that silently loses its gate is the highest-severity
outcome on this ticket. Adding them is part of this decision, not a follow-up.

#### 9.14.4 REVIEWED 2026-08-27 — one BLOCKING finding, and my premise was wrong for 3 of the 4

One independent lane on PR #214. **Blocked on H2.** Everything mechanical held — all 8 mutants killed by
the intended assertion, `methodNamed()`'s `hasSize(1)` fails loudly under a decoy overload, both
population figures re-derived exactly (38 on dev, 7 on prd), and all §9.14 arithmetic confirmed against
the 20 real annotation sites. Report: `scratchpad/review-214.md`.

**🔴 H2 — the tripwire set was wrong in TWO places, and the cardinality hid it.** §9.14.3 reasoned *"it
pins the 5, there are now 9, add the 4."* That **counted** instead of **enumerating against the 9-row table
in §8.14.1 — which I wrote in the same commit.** Both sets have 9 members; their symmetric difference is 2:

| | plan's 9 that stay | test's 9 pins |
|---|---|---|
| `importUserWithCsv:237` | ✅ carve-out **#1** | ❌ **pinned nowhere** |
| `findUsers:79` | ❌ listed in the **11 that MOVE** | ✅ pinned |

Measured both ways: stripping `importUserWithCsv`'s annotation left the suite **11 tests / 0 failures**;
stripping `findUsers`' reddened it. So **the highest-blast-radius identity write on the controller** —
`keycloakService.ssoUserCreateCsv`, which bulk-creates loginable identities from a CSV blob — was the one
carve-out with no tripwire at all. Now pinned, and the pin is mutation-verified.

**⚠ `findUsers:79` is an OPEN DECISION, deliberately left in the fail-safe direction.** The pin contradicts
the plan and I have NOT resolved it by editing whichever side was convenient. Per the review's M5, moving it
is not a plain read:

- `keycloakService.findUsers()` is `usersResource.list(0, 1000)` — the **whole Keycloak realm directory**,
  staff included. Moving it hands realm-wide account enumeration to the 38. SBDEV-3071 class.
- Its `sb_admin` privilege branch is **dead in production**: it reads
  `jwt.getClaimAsStringList("authorities")` and **nothing in `src/main` ever writes that claim**, so the
  `else` branch always runs and `returnsAllUsersForSbAdmin` validates behaviour production cannot exhibit.
- That `else` branch has a **live NPE** — `!user.getEmail().contains("siteboss")` on a nullable field — and
  its substring test is wrong both ways (`bob@siteboss-fanclub.com` hidden; staff on another domain leaked).
- `findGroupByName:247` similarly exposes Keycloak **group** topology — the axis this whole decision relies
  on being outside the 38's reach.

~~**If the ruling is STAY, the split becomes 12 move / 8 stay** (or 11/9 → 13/7 if `findGroupByName` joins).~~
🔴 **BOTH FIGURES WRONG — see §9.15.1.** Moving a site INTO the stay-set SUBTRACTS from the move count. Both
rulings were STAY, and the split is **9 move / 11 stay**.
**If MOVE, the pin must be deleted and the NPE fixed first.** Either way R8 cannot annotate those two blind.

**🔴 H1 — what the pins actually buy, corrected in-code.** I claimed migrating would widen the population
*"from staff-only to 38"*. **False for 3 of the 4.** `UserController` is class-level
`@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` (`:83`) and already reaches the same `KeycloakService`
calls at that function — `POST /v3/user/create` → `createSingleUser` (`:367`, and the caller **picks the
password**, so *stronger* than `ssoCreateUser`'s temp one) and `POST /v3/user/update` →
`updateUserPassword` (`:440`, arbitrary password on any account). So the pins keep **identity DELETION**
staff-only and decline a **fourth** function-gated route; they do not keep create/update/reset staff-only.

**That reframes §9.14.1's closing note.** I called the SBDEV-2870 divergence "two controllers guarding
comparable capabilities on different axes." It is worse: **the same capability through two gates, where the
weaker gate already wins.** Closing the `AdminController` route protects nothing while
`POST /v3/user/create` is open at 38. That belongs on SBDEV-2870 as a finding, not a footnote here.

**🟠 M1 — my forgeability mechanism was STALE, and the real one is stronger.** *"A function is
self-grantable while `UserFunctionRepository`'s SDR write stays open"* — asserted in §8.16.6, the status
field, `wms2-keycloak-role-matrix.md:126` and the audit report — **no longer describes a live route: PR #209
withdrew those verbs.** What keeps a function forgeable is the **controller** half:
`UserController.saveUserGroups` (`:536`) accepts **any** `userId` with no self-scope, so
**`WEB_UI_VIEW_USER_MANAGEMENT` is the root of the function lattice** — any holder can grant themselves or
anyone every other function in one request. Gating on it ≡ gating on *"can already grant themselves
anything."* Sharper than "forgeable", and now the version recorded in-code.

**Also fixed:** the audit report's *"The 15 that move"* label over an enumeration summing to 11 (M2 — the
same label-vs-enumeration drift, one document over, and **my grep list did not contain that string**);
`PutawayConfigService:296`'s *"split 15/5"*, the only stale count in `src/main` (M3); *"the five carve-outs"*
surviving 3× in the test file including a **live failure message** (M4); §8.16.5a's unconditional
instruction to resolve counts back to the retired 17/3 (L3); and `AdminController:236`/`:246` line pins
across three documents, measured as **`:237`/`:247`** (L4).

**🟡 L2 — nothing pinned the constant's VALUE, and my first mutation run of it lied.** All 9 pins compare
against `Authority.IS_SB_ADMIN`, and the only pre-existing drift check derives *both* sides from
`SB_ADMIN_ROLE`, so they move together: editing it to `"wms_user"` would leave every pin green while all 20
gates widened. Added a literal assertion. ⚠ **On an incremental build that mutant showed 6 failures; on a
`clean` build it shows exactly 1 — the new literal.** The extra 5 were partial-recompilation artifacts
(`Authority` recompiled, `AdminController`'s inlined annotation values not), i.e. a false signal in the
**optimistic** direction. Mutation runs that touch a compile-time constant must be `mvn clean`.

---

### 9.15 SIX DECISIONS (Nam, 2026-08-27). Split is now **9 move / 11 stay**. R8 is unblocked

| # | Question | Decision |
|---|---|---|
| 1 | `AdminController.findUsers:79` | ✅ **STAY** on `sb_admin` |
| 2 | `AdminController.findGroupByName:247` | ✅ **STAY** on `sb_admin` |
| 3 | the SBDEV-2870 residue | ✅ **(a)** leave it; record on SBDEV-2870 |
| 4 | `ItemDataController:105` | ✅ **move onto `WEB_UI_VIEW_ITEM_DATA`** |
| 5 | R8's scope | ✅ **(a)** the MVC sites only |
| 6 | the six §2.5 deletions | ✅ **gate them**, do not delete |

#### 9.15.1 🔴 CORRECTION — I gave the wrong arithmetic when presenting decisions 1 and 2

I told Nam that keeping `findUsers` on `sb_admin` would make the split **12 move / 8 stay**, and that
keeping both would make it **13 move / 7 stay**. **Both are wrong, and wrong in the same direction:** moving
a site *into* the stay-set **subtracts** from the move count. The review report said 12/8 as well and I
propagated it without checking — the same failure as the `store/admin/shippers.js:29,49` citation, which
was also a number taken from a reviewer rather than measured.

Re-derived from source (`@PreAuthorize(Authority.IS_SB_ADMIN)`, exact-line match, 20 sites):

| | | |
|---|---|---|
| **MOVE = 9** | `AdminController` ×2 | `:107` `findUserByUsername`, `:133` `findUserGroupsByUsername` |
| | `PutawayConfigController` ×3 | `:183`, `:215`, `:233` |
| | `PutawayConfigService` ×3 | `:97`, `:129`, `:166` |
| | `ItemDataController` ×1 | `:105` `setPutAwayLocation` |
| **STAY = 11** | `AdminController` ×7 | the 5 WRITES (`:120`, `:142`, `:154`, `:175`, `:237`) + `:79` + `:247` |
| | `PutawayConfigService` ×2 | `:258`, `:288` |
| | `AdminActionController` ×1 | `:341` |
| | `ReplenishmentReconciliationController` ×1 | `:37` |

9 + 11 = 20 ✓ — **the fourth revision of this count** (17/3 → 15/5 → 11/9 → 9/11).

⚠ **Line-number drift also corrected in the same pass:** `PutawayConfigService`'s movers are **`:97`, `:129`, `:166`** — every prior revision of this plan said
`:96`, `:128`, `:165`. ⚠ An earlier attempt at this very sentence was self-nullifying: the find-replace that
fixed the values corrected the "before" half too, so the warning read `:97…` said `:97…`. And
`PutawayConfigController`'s three are `:183`, `:215`, `:233`, never previously enumerated at all.

#### 9.15.2 The tripwire now matches the stay-set MEMBER FOR MEMBER, not by count

H2 blocked PR #214 because §9.14.3 counted (5 → 9) instead of enumerating, and the two sets differed by two
members while sharing a cardinality. The check is now explicit: the 11 `assertCarriesSbAdmin` call sites are
diffed against the 11-row stay-set as **sets**, and they match with no missing and no extra. `findUsers`'
pin loses its PROVISIONAL marker (decision 1 confirms it) and `findGroupByName` gains one (decision 2).

⚠ **`findUsers` carries a live defect that decision 1 does not fix, only defers.** Its `sb_admin` privilege
branch is dead in production — nothing in `src/main` writes the `authorities` claim it reads — so the
`else` branch always runs, and that branch NPEs on a nullable `getEmail()`. Keeping the site on `sb_admin`
narrows who can reach the NPE; it does not remove it. **Not this ticket's scope; needs its own ticket.**

#### 9.15.3 Decision 3 — what §9.14 actually buys, stated plainly

Leaving the SBDEV-2870 residue means the identity carve-out buys **(a)** Keycloak identity **deletion**
staying staff-only and **(b)** declining to add a *fourth* function-gated route. It does **not** keep
create / update / password-set staff-only: `UserController` is class-level
`@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` and already reaches the same `KeycloakService` calls at
**38 users on dev**, with `POST /v3/user/create` letting the caller pick the password — *stronger* than
`ssoCreateUser`'s temporary one.

**So the same capability is reachable through two gates and the weaker one already wins.** That is a finding
for SBDEV-2870, not a footnote here, and it must be recorded there rather than left in this plan.

#### 9.15.4 Decision 4 — `:105` proceeds; §8.12's F4 is NOT thereby closed

`ItemDataController:105` moves onto `WEB_UI_VIEW_ITEM_DATA`, accepting its measured **44 users** (38
`super-admin` ∪ 11 `inventory-manager`) — wider than the 38 the identity writes were just protected from.
That is Nam's call and it unblocks `:105`.

⚠ **F4 is a different question and remains open.** F4 (§8.12) is about splitting the **new**
`WEB_UI_ACTION_SET_PUTAWAY_DESTINATION` constant into `_SKU` / `_DEFAULTS`, because tiers 2/3 sit behind
super-admin-only view gates while `inventory-manager` would reach 11 users. That governs
`PutawayConfigController` ×3 and `PutawayConfigService` ×3 — **6 of the 9 movers** — and decision 4 says
nothing about it. R8 still needs it resolved before annotating those six.

#### 9.15.5 Decisions 5 and 6

**(5)** R8 = the **9 MVC sites** only. The SDR surface is documented (§9.12) and separately tracked
(SBDEV-3124); 44 live write surfaces is its own ticket, not a rider on this tranche.

**(6)** The six §2.5 deletions are **gated, not deleted** — the same standard R6 established: "no caller in
three repos" is not proof of no caller, and gating is reversible where deletion is not. ⚠ This changes §2.5
from a deletion list to a gating list, so each of the six needs a function chosen and an AC-2′ check, work
§2.5 did not previously carry. It also means AC-8 (*"six deletions landed in their own commit"*) is now
**unachievable as written** and must be rewritten.

---

### 9.16 DECISION 2026-08-27 (Nam) — Option **B**: the six putaway sites gate on their SCREEN's existing VIEW function. **Zero new constants.** F4 superseded

**Decision:** each of the six putaway sites takes the function that already gates the screen it is reached
from. No `WEB_UI_ACTION_SET_PUTAWAY_DESTINATION*` constant is created.

| Tier | Controller | Service | Screen | Gate |
|---|---|---|---|---|
| 1 · SKU | `PutawayConfigController.setSku:183` | `setSkuDestination:106` | SKU Data | `WEB_UI_VIEW_ITEM_DATA` |
| 2 · merchant | `setMerchant:215` | `setMerchantDestination:138` | Shippers | `WEB_UI_VIEW_CLIENT` |
| 3 · warehouse | `setWarehouse:233` | `setWarehouseDestination:173` | System Property | `WEB_UI_VIEW_SYSTEM_PROPERTY` |

#### 9.16.1 This DELIVERS F4's goal rather than overriding it — measured

F4 (§8.12) ordered a two-constant split because **one** function granted to `inventory-manager` would hand
11 users the ability to change the default for an entire shipper or the whole facility, on screens they
cannot open. Option B reaches the same separation without minting anything. Re-measured on
`dev_wh01_om1` 2026-08-27:

| Gate | users | named roles |
|---|---|---|
| `WEB_UI_VIEW_ITEM_DATA` (tier 1) | **44** | inventory-manager, super-admin |
| `WEB_UI_VIEW_CLIENT` (tier 2) | **38** | super-admin only |
| `WEB_UI_VIEW_SYSTEM_PROPERTY` (tier 3) | **38** | super-admin only |

`inventory-manager` gets tier 1 and **nothing else** — precisely F4's intent. **AC-2′ holds trivially at all
three tiers**, because each gate *is* its screen's gate: anyone who can reach the screen already holds it.

#### 9.16.2 Why this is the consistent choice, not a shortcut

Two prior decisions already set it: **§9.15 decision 4** sent `ItemDataController:105` onto the existing
`WEB_UI_VIEW_ITEM_DATA` rather than a new ACTION constant, and **R6** gated `ShipperIdController` on
`WEB_UI_VIEW_CLIENT` for the same reason. Option B is that rule applied to the remaining six.

⚠ **The idiom note, checked rather than assumed:** using a `WEB_UI_VIEW_*` constant to gate a *write* looks
like a convention break, but review lane 2 verified on R6 that `WEB_UI_VIEW_*` constants name **screens**,
not entities and not read-only-ness (`appMenuList.js:134` is `'WEB_UI_VIEW_CLIENT', // Shippers`, asserted by
the UI's own `test/pages/admin.spec.js:56`). So this is within the convention.

#### 9.16.3 🔴 §2.3 and §2.4 must be rewritten — they describe a file matching NEITHER option

**F4's decision was never propagated into §2.3 or §2.4.** §2.3 still lists exactly two new constants
(`WEB_UI_VIEW_SYSTEM_MANAGEMENT`, `WEB_UI_ACTION_RECOVER_STUCK_PALLETS`) and neither of F4's; §2.4's hazard
note is keyed to *"this file adds **two**, so it must be **two separate** `INSERT … SELECT` statements."*

Under Option B the count **stays two** — which is the one outcome that leaves §2.4's carefully-written
hazard note correct as it stands. Under Option A it would have become **four**, and a single multi-row
insert gives every row the same id, which on a tenant missing the PK **inserts silently** (§2.4's own
warning). Removing that risk entirely is the strongest practical argument for B.

⚠ **Still owed:** R1 (§9.6.1) found **two further unaccounted constants** — `WEB_UI_ACTION_GENERATE_TOTE_LABELS`
and `WEB_UI_VIEW_CREATE_BILL_OF_LADING` — referenced by §1 rows and existing in neither the catalogue,
`FunctionEnum`, nor `appMenuList.js`. They are **not** among R8's 9 movers, so Option B does not resolve them.
If those §1 rows are in R8's scope, the constant count rises after all and §2.4 must grow to match.

#### 9.16.4 🔴 An unresolved SCOPE ambiguity, surfaced now rather than discovered mid-implementation

§9.3 describes R8 as *"the implementation — 9 sites move / 11 stay, 2 new constants, Flyway `V2.2.22`, the
six deletions."* But **§1's ~97 rows are a different set from the 20 `IS_SB_ADMIN` sites**, and the plan uses
"the tranche" for both:

- **the 20** — migrating gates that **already exist** off `sb_admin` onto functions (9 move, 11 stay);
- **§1's ~97 rows** — adding gates to endpoints that are **currently ungated** (§0.B's boundary: *"every
  ungated endpoint whose handler mutates state"*), which is also where R3's 93-ungated-writes figure lives.

§9.15 decision 5 chose **(a) MVC only** over **(b) SDR first** — that resolved MVC-vs-SDR, **not** 9-vs-97.
So R8 is either a ~9-site change or a ~106-site change, and nothing on record says which. **This needs
answering before R8 opens a branch**, because it decides whether `V2.2.22` carries 2 constants or 4+, whether
R1's two unaccounted constants are in scope, and whether the tier is still T3 or something larger.

---

### 9.17 SCOPE DECIDED 2026-08-27 (Nam) — R8 is the **9 sites only**. No new constants, **no `V2.2.22`**, and the tier drops

**Decision:** R8 = the 9 `IS_SB_ADMIN` sites that move. §1's ~97 rows — adding gates to endpoints that are
currently **ungated** — are **OUT of scope** and need their own slice.

#### 9.17.1 The consequence nobody had traced: `V2.2.22` disappears

§2.3 planned **two** new constants. With R8 scoped to the 9, **both fall out**:

| §2.3 constant | Why it is no longer needed |
|---|---|
| `WEB_UI_VIEW_SYSTEM_MANAGEMENT` | it existed for class-level defaults on `AdminActionController` and `ReplenishmentReconciliationController` — **both are now in the STAY set** (`:341`, `:37`) |
| `WEB_UI_ACTION_RECOVER_STUCK_PALLETS` | it gates `POST /v3/adminAction/recoverStuckPallets` at `AdminActionController:256`, which is **not one of the 20 `IS_SB_ADMIN` sites at all** — it is an ungated endpoint from §1's rows, i.e. the set just excluded |

And §9.16's Option B mints nothing. So **R8 creates zero new constants.**

**Nor does it need grants.** All four target functions are already held by the intended roles, measured on
`dev_wh01_om1` 2026-08-27: `WEB_UI_VIEW_ITEM_DATA` 44, `WEB_UI_VIEW_CLIENT` 38,
`WEB_UI_VIEW_SYSTEM_PROPERTY` 38, `WEB_UI_VIEW_USER_MANAGEMENT` 38.

**⇒ `V2.2.22` is not needed at all.** §2.4 — its version sweep, its two-separate-INSERTs rule, its 23502 and
23505 hazards, the `MAX(id)` recomputation, the constraint-shape drift warning — is **moot for R8**. It
should be struck for this slice and preserved for whichever slice takes §1's rows, where R1's two
unaccounted constants (`WEB_UI_ACTION_GENERATE_TOTE_LABELS`, `WEB_UI_VIEW_CREATE_BILL_OF_LADING`) also live.

**⇒ The tier drops.** R8 was T3 on three grounds: authorization, **a Flyway migration**, and multi-repo. The
migration is gone; the UI side is one Jest pin (§9.10). What remains is **9 annotation swaps across 4 files,
onto existing functions whose populations are measured, with AC-2′ trivially satisfied at each.** That is
**T2** — 2 review lanes, the gate, no verify script. Re-tier it before starting; T3's four lanes and
open-ended budget are no longer proportionate.

#### 9.17.2 🔴 One question the scope decision exposes, and it is the same one decisions 1–2 answered

The 9 split **7 putaway + 2 `AdminController` reads**:

| | Sites | Status |
|---|---|---|
| putaway | `PutawayConfigController` ×3, `PutawayConfigService` ×3, `ItemDataController:105` | ✅ decided, §9.16 Option B |
| `AdminController` | `:107` `findUserByUsername`, `:133` `findUserGroupsByUsername` | 🔴 **open** |

Both are `GET /v3/user/find*`, and **neither has a caller in `wms2-web-ui` or `wms2-mobile-ui`.** They are
**existence oracles for an arbitrary username** — the SBDEV-3071 class.

**The consistency problem:** §9.15 decisions 1 and 2 kept `findUsers` and `findGroupByName` on `sb_admin`
*because they are Keycloak directory reads that leak account and group information to the 38*. That
reasoning applies to these two at least as strongly — and arguably harder to `:133`, which returns **which
groups a named user belongs to**, i.e. reconnaissance on the exact privilege model the carve-out exists to
protect. It is a narrower, more targeted oracle than `findUsers`' bulk dump.

- **If they STAY**, the split becomes **7 move / 13 stay**, `AdminController` moves **nothing**, and R8 is
  purely the putaway change — 7 sites, one controller family, still T2 and simpler again.
- **If they MOVE**, they take `WEB_UI_VIEW_USER_MANAGEMENT` (38 users), which is the function the sibling
  `UserAdministrationController` already uses — consistent with SBDEV-2870, and consistent with §9.15
  decision 3's choice to leave that axis alone.

Either is defensible. **Not decidable by me:** it is the same trade-off Nam already ruled on twice, and I do
not know whether those rulings were about *those two endpoints specifically* or about *Keycloak directory
reads as a class*. If the latter, these two follow automatically.

---

### 9.18 DECISION 2026-08-27 — `AdminController:107`/`:133` STAY. Split is **7 move / 13 stay**. R8 is now purely the putaway change

**Decision:** §9.17.2's open question resolved as **STAY**, treating §9.15 decisions 1–2 as a ruling about
**Keycloak directory reads as a class**, not about two specific endpoints.

⚠ **Process note, because it matters more than the outcome.** §9.17.2 said *"either is defensible — not
decidable by me"* and made **no recommendation**. Nam then said "go as you recommended." Rather than invent
a recommendation and attribute it to the earlier section, it is recorded here as one made *now*, with its
reasoning, and flagged as reversible in two lines if the intent was MOVE.

**The three reasons:**

1. **Consistency.** Decisions 1–2 kept `findUsers:79` and `findGroupByName:247` on `sb_admin` because they
   leak Keycloak account and group information to the 38. `:107` and `:133` are the same kind of read.
2. **`:133` is the sharpest of the four.** It returns **which groups a named user belongs to** —
   reconnaissance on the exact privilege model these carve-outs exist to protect, and a *more targeted*
   oracle than `findUsers`' bulk directory dump. If `findUsers` stays, this cannot move.
3. **Reversibility.** STAY keeps the stronger gate, so a wrong call here costs nothing but a later widening;
   MOVE would have to be walked back after exposure.

Neither has a caller in `wms2-web-ui` or `wms2-mobile-ui` (measured), so STAY breaks nothing.

#### 9.18.1 The split, re-derived from source — **7 move / 13 stay**

| | Class | Lines |
|---|---|---|
| **MOVE = 7** | `PutawayConfigController` ×3 | `:183`, `:215`, `:233` |
| | `PutawayConfigService` ×3 | `:97`, `:129`, `:166` |
| | `ItemDataController` ×1 | `:105` |
| **STAY = 13** | `AdminController` **×9 — all of them** | `:79`, `:107`, `:120`, `:133`, `:142`, `:154`, `:175`, `:237`, `:247` |
| | `PutawayConfigService` ×2 | `:258`, `:288` |
| | `AdminActionController` ×1 | `:341` |
| | `ReplenishmentReconciliationController` ×1 | `:37` |

7 + 13 = 20 ✓. **Fifth revision** (17/3 → 15/5 → 11/9 → 9/11 → 7/13). **`AdminController` now moves nothing
at all**, which is the cleanest statement of where this landed: every Keycloak-facing endpoint stays on
`sb_admin`, and the tranche is exactly the putaway-destination write surface.

#### 9.18.2 What R8 now is

**7 annotation swaps in 3 files**, all onto existing functions with measured populations (§9.16 Option B):

| Site | New gate |
|---|---|
| `PutawayConfigController.setSku:183` + `PutawayConfigService.setSkuDestination:106` | `WEB_UI_VIEW_ITEM_DATA` |
| `.setMerchant:215` + `.setMerchantDestination:138` | `WEB_UI_VIEW_CLIENT` |
| `.setWarehouse:233` + `.setWarehouseDestination:173` | `WEB_UI_VIEW_SYSTEM_PROPERTY` |
| `ItemDataController.setPutAwayLocation:105` | `WEB_UI_VIEW_ITEM_DATA` |

**No new constants. No `V2.2.22`. No grants.** (§9.17.1.) Plus one Jest pin in `wms2-web-ui` for §9.10's
shared-popup host set. **Tier: T2** — 2 review lanes, run the gate, no verify script.

⚠ **Carried, unchanged:** every mover still needs its SDR twin checked before annotation (§9.12) — and for
these seven the answer is already known and favourable: `Sysprop`, `Itemdata` and `Client` all have live SDR
write surfaces, but all three are guarded on that path by `PutawayConfigRepositoryEventHandler`, whose hooks
call the two `@PreAuthorize` service methods §8.16 carved out. **That is why `:258`/`:288` must not move**,
and the R4 tripwire now pins them.

⚠ **Also carried:** the six §2.5 "deletions" are **gates** now (§9.15 decision 6), each needing a function
and an AC-2′ check, and **AC-8 is unachievable as written**. Those six are NOT among the 7 — they belong to
§1's rows, which §9.17 put out of scope. **§2.5 and AC-8 therefore move to the §1 slice too.**

---

### 9.19 R8 IMPLEMENTED 2026-08-27 — PRs #219 (api) and #88 (web-ui). The denominator changes: **20 sites → 17**

| Half | PR | Commit | Suite |
|---|---|---|---|
| API — 4 gates + 3 restrictions lifted | wms2-api **#219** | `169d7071` | 5673 / 0 / 67 (clean) |
| UI — reprint host-set pin | wms2-web-ui **#88** | `b218de7` | 751 / 0, baseline 749 |

⚠ **Merge order is mandated (§8.14.3): API before UI.** A `@PreAuthorize` 403 carries no
`X-Authz-Denied`, so it lands on the UI's silent-no-op/logout path. #219 is independent of #217 — no file
overlap.

#### 9.19.1 🔴 The move/stay ratio stops being the right frame

Every prior revision counted **20** `@PreAuthorize(Authority.IS_SB_ADMIN)` sites and split them move/stay.
R8 **lifted** three rather than moving them, so those three are no longer `sb_admin` sites at all:

| | before R8 | after R8 |
|---|---|---|
| total `IS_SB_ADMIN` sites | 20 | **17** |
| on functions (the tranche's goal) | 0 | **4** — the controller handlers |
| restriction lifted entirely | — | **3** — `PutawayConfigService` `:97`/`:129`/`:166` |
| remaining on `sb_admin` | 20 | **13** |

13 + 4 = 17, and 17 + 3 lifted = the original 20 ✓. **The "N move / M stay" phrasing is retired** — it could
not express "lifted", which is why the count churned five times. State it as: **13 stay on `sb_admin`, 4 on
functions, 3 gates relocated to the controller layer.**

#### 9.19.2 The finding that reshaped R8, and it generalises §8.16

**`@RequiresFunction` can never gate a service method.** `FunctionGuardInterceptor` is a
`HandlerInterceptor`: it returns early unless the target is a `HandlerMethod` (`:162`) and reads the
annotation from `getMethod().getDeclaringClass()` (`:166`). There is **no AOP aspect** — verified by grep for
`@Aspect`/`@Around`/`Pointcut` — and **no `@RequiresFunction` exists anywhere outside `controller/`**.

§8.16 found this for `:258`/`:288` and attributed it to *"invoked from SDR event handlers."* That framing was
too narrow: the cause is simply that **a service method is not a handler**, which is true of all five
`PutawayConfigService` sites. Had R8 swapped `:97`/`:129`/`:166` as every prior revision planned, it would
have **silently removed three gates** — compiling, suite-green, and undetectable by any existing lane.

**Three ways out were considered.** (i) annotate anyway — **removes the gate**, rejected. (ii) programmatic
`accessService.doesUserHaveAccess(...)` in the bodies — works, but imperative and invisible to any annotation
census, which this ticket has been burned by repeatedly. (iii) **add a `hasFunction(...)` member to
`CustomMethodSecurityExpressionRoot`** so `@PreAuthorize("hasFunction('X')")` becomes available — declarative,
works at every layer *including* the SDR path, and testable through the existing production-faithful
`evaluate(...)` harness in `CustomMethodSecurityExpressionRootUnitTest`.

**(iii) is not built, and is the recommended shape if the remaining `sb_admin` sites are ever migrated** —
it would dissolve §8.16's carve-out reason entirely rather than working around it. Recorded here because the
option only became visible once the interceptor's limit was understood, and R8 did not need it: **lifting**
was available because the caller set is closed.

#### 9.19.3 Why lifting was safe, and what pins it

The only live callers of the three setters are the four handlers R8 gates. `ItemdataService.setPutAwayLocation:73`
— the single service-to-service caller — has **zero callers of its own** in `src/` or `test/`, so that path is
dead code. `PutawayConfigActionGuardUnitTest#onlyTheFourGatedHandlersReachTheSetters` pins the caller set from
source, so a fifth caller goes red instead of arriving ungated.

**The mutant that matters:** restoring `@PreAuthorize(IS_SB_ADMIN)` on `setSkuDestination` leaves **every
controller gate test passing** while silently re-blocking `inventory-manager`. Only `R8-6` sees it. That is
the failure mode this whole ticket keeps producing — a gate that looks present and isn't, or absent and isn't.

#### 9.19.4 ⚠ A verification failure worth more than the change

The entire UI verification — the pin, all three mutants, the full suite — was first run against the
`wms2-web-ui` **main checkout, 21 commits behind `origin/develop`**. It showed 2 failing tests in
`actionControlsDisabled.spec.js`, and I was one step from reporting a regression in SBDEV-2967-C's
`:disabled` pins. That would have been fabricated, and it would have undermined the argument that
`WEB_UI_ACTION_DELETE_UNIT_LOAD` is acceptable as super-admin-only *because the UI disables the control*.

What caught it was a mismatch: `git status` clean, `git diff origin/develop` showing 20 changed files. The
stale tree did not even contain the already-merged PR #83.

Re-run on a detached worktree at `origin/develop`: baseline **2 always-red suites / 749 passed / 0 failing
tests**, and **751 / 0** with the new spec. **"Never grade a local checkout" is already written down on this
ticket and I did it anyway** — which is why it is now in the commit message and the PR body, where the next
person meets it rather than having to remember it.

#### 9.19.5 What remains on SBDEV-3017 after R8

- **#219 and #88 need two review lanes** (T2) and are unmerged.
- **§2.3, §2.4 and §2.5 are stale for this slice** — no new constants, no `V2.2.22`, and the six "deletions"
  are gates now and belong to the §1 slice (§9.17). **AC-8 is unachievable as written.**
- **§1's ~97 ungated-endpoint rows are a separate slice** (§9.17), carrying R1's two unaccounted constants.
- **`findUsers`' live NPE** (dead `sb_admin` branch; `else` branch derefs a nullable `getEmail()`) needs its
  own ticket — §9.15 decision 1 narrowed who reaches it, and did not fix it.

---

### 9.20 R8 SHIPPED 2026-08-27 — both lanes blocked it first. The finding that mattered

| PR | Merge | Lane verdict |
|---|---|---|
| wms2-api **#219** | `e7a37f4e` | BLOCKS — 3 High, all fixed |
| wms2-web-ui **#88** | `aa8ad6bc` | DO NOT MERGE AS-IS — 2 High, all fixed |

Merged API-before-UI per §8.14.3. Both merged trees byte-identical to the tested commits.

#### 9.20.1 🔴 F1 — the change was NAKED ON `main`, and it violated a constraint this plan states

`@RequiresFunction` has **no reader on `origin/main`**: no `FunctionGuardInterceptor` class, no
`MappedInterceptor` bean, `develop` +158. Those four handlers are gated on production today by
`@PreAuthorize(IS_SB_ADMIN)` in **two** layers. R8 as first written deleted one and made the other inert
there — so a release carrying it without the whole authz programme would have exposed
`PUT /v3/putawayConfig/warehouse`, the **facility-wide** default, to any authenticated `wms_user`, silently.

**That is §8.11.5, quoted repeatedly during this work including in the PR body, and then contradicted by the
same PR.** Writing a constraint down did not stop it being violated; the review lane did.

**Fix:** `PutawayConfigService` now takes `AccessService`, and each setter carries a per-tier
`doesUserHaveAccess(...)` check throwing `AccessDeniedException`. Function-aware (Nam's intent holds),
enforced regardless of interceptor presence, fails closed on an empty role list. Also closes F7 — neither
controller is in `GUARDED`, so a future unannotated write handler there had no backstop at all.

#### 9.20.2 Two pins that did not hold, and how they failed

- **F2** — `R8-8`, the *stated justification* for removing the gate, asserted **filenames** and matched the
  literal `"putawayConfigService.setSkuDestination("`. A new ungated caller **inside** an already-listed file,
  and one reaching the service through a **differently-named field**, both survived at 8/8. Replaced with a
  type-resolved ArchUnit call-site rule; both mutants now die on it.
- **F3** — deleting the fourth handler's annotation **survived all 5673 tests**, because `ItemDataController`
  is not in `GUARDED` so `preHandle` falls through *allowed*, leaving a mutating GET open. `R8-5` covered only
  the three `PutMapping`s and the helper's `GetMapping` branch was written and never called.

#### 9.20.3 Three method traps found while fixing, all worth carrying forward

1. **A compile error is not a mutant — the fifth on this ticket.** My first F2 mutant omitted
   `throws BusinessException`, produced **no test output at all**, and would have been logged as a kill by
   anyone matching on "no failure line".
2. **An ArchUnit rule reads `target/classes`, so a stale `.class` invents a caller.** The new rule's first run
   failed on a review mutant whose `.java` was deleted while the orphaned `.class` survived an incremental
   build. This is the mirror of the recompile hazard already recorded here: there a stale class **hid** a
   mutant, here it **fabricated** a violation. Run it after `mvn clean` before believing a violation.
3. **Reflection reads `value()` and `path()` as separate members.** `pathsOf` checked only `value()`, but the
   legacy handler is written `@GetMapping(path = …)`, so the lookup found **zero** handlers. The
   `hasSize(1)` guard turned that into a loud failure instead of a vacuous pass — which is the entire reason
   that guard exists.

#### 9.20.4 What the PRs record rather than fix — read before touching this area

- **This is a set REPLACEMENT, not a widening.** `AccessService.checkAnyAccess` has **no `sb_admin`
  short-circuit**, so an `sb_admin` outside `super-admin`/`inventory-manager` now gets 403 where they
  previously succeeded. No live principal is affected by measurement, but the first *"I'm sb_admin and I get
  403"* report has its answer in-code.
- **"super-admin only" is not staff-only.** On prd `wh01_hydra_v2` three of the seven `super-admin` users are
  `@huersch.com` **customer** accounts, who now reach the shipper-wide and facility-wide defaults. Accepted
  consequence of the 2026-08-26 axis decision, not an oversight.
- **Tiers 2/3 trade an unforgeable gate for a self-grantable one** via `UserController.saveUserGroups`, which
  takes any `userId` with no self-scope. Not exploitable by any live principal — 0 rows hold
  `WEB_UI_VIEW_USER_MANAGEMENT` without `super-admin` on either DB. The clean answer is §9.19.2's
  `hasFunction(...)` SpEL, still unbuilt.
- ~~**`ItemDataController.setPutAwayLocation` should probably be DELETED**~~ → **DONE, see §9.21.** Nam said
  "delete setPutAwayLocation" on 2026-08-27. F3's residual is closed outright.
- ⚠ **The review fixes themselves (`586a5a1e`, `d29348c`) had no independent reader.** F1's fix in particular
  is substantive new code in a security path.

---

### 9.21 F3 residual CLOSED BY DELETION 2026-08-27 — the legacy SKU write path is gone

Nam's instruction was two words: *"delete setPutAwayLocation"*. Two methods went, not one.

| Deleted | Why it was deletable | Why it was a hazard |
|---|---|---|
| `ItemDataController.setPutAwayLocation` — `GET /v3/itemData/setPutAwayLocation/{itemdataid}/{locationid}` | zero callers in **six** consumers (see the sweep below) | a **mutating GET** on a controller absent from `FunctionGuardInterceptor.GUARDED`, so it fell through `ALLOWED`. Review F3 measured that deleting its `@RequiresFunction` survived **all 5673 tests** |
| `ItemdataService.setPutAwayLocation(Itemdata, Location)` | zero callers in `src/main` **or** `src/test` | delegated into `PutawayConfigService.setSkuDestination`, and `@RequiresFunction` **cannot gate a service method** — an ungatable route into a gated write |

#### 9.21.1 The caller sweep — R6's precedent applied, and it earned its keep

R6 established that *"no caller in three repos"* is not proof, so the sweep ran across **all six** consumers
plus the OMS endpoint-registry form that hid `ShipperIdController`'s caller earlier on this ticket:

| Consumer | Occurrences |
|---|---|
| `wms2-web-ui` | **1** — `test/store/masterData/skuData.spec.js:45`, a **negative** assertion (`not.toContain`) |
| `wms2-mobile-ui`, `v1/wms-web-ui`, `v1/wms-mobile-ui`, `omsv2-UI`, `oms-laravel-api`, `v1/oms` | **0** |
| OMS endpoint-registry / config keys (the `getWmsEndpoint('...')` indirection) | **0** |

**The sweep still missed something, and it is worth recording why.** It grepped for *call sites*. A
`grep` after the deletion turned up `IdempotencyFilter:413`, a **javadoc** naming
`ItemdataService.setPutAwayLocation` as the handler whose targeted `@Caching` justified the filter's
conservative `clear()`. Both halves of that sentence were false *before* this change: `/rest/sku/**` is served
by `SkuRestController`, whose handlers at `:67`/`:180` carry `@CacheEvict(allEntries = true)` — the very thing
the javadoc claimed had been replaced by targeted eviction. Corrected in place. **Prose references are a
distinct grep axis from call sites; a caller sweep does not find them.**

#### 9.21.2 Two dead dependencies fell out

With the methods gone, **both** classes injected `PutawayConfigService` and never used it —
`ItemDataController` (14 ctor args → 13) and `ItemdataService`. Removed, along with `ItemdataService`'s now-unused
`Caching` import and an orphaned `/** SBDEV-2732 §3.5 — the ONE validated, audited writer. */` javadoc that had
documented the deleted field and would otherwise have re-attached itself, silently, to the constructor.

#### 9.21.3 The pin got STRONGER, not weaker

R8-5 pinned the handler's `@RequiresFunction` by reflection. That pin is now meaningless, so it was **replaced**,
not dropped, by **R8-9 `theDeletedLegacySkuPathHasNotReturned`**:

- asserts **no** declared method on `ItemDataController` maps any path containing `setPutAwayLocation`, across
  **every verb** (a new `allMappedPathsOf` helper — `pathsOf` covers only GET/PUT because the gate lookups know
  their verb; a reintroduction as a `POST` or a `@RequestMapping(method=…)` must fail too), and
- asserts `ItemdataService` declares no `setPutAwayLocation`.

This is strictly stronger than the annotation pin: **a reintroduced mutating GET fails it whether or not
somebody remembers the annotation.** R8-8's call-site list narrows 5 → 3 (the three `PutawayConfigController`
handlers); it staying green is itself evidence the two callers really are gone.

**Mutation-checked, both halves independently** — and the mutant was deliberately made *unfaithful* to the
original to prove the pin is not shape-matching: reintroduced as a **`@PostMapping` under the method name
`mutantReintroducedUnderAnotherName`**. It died. The service half died separately, at a **different line**
(`:239` vs `:248`), so neither assertion is riding on the other. Both mutants were verified present in-file
before the run and absent after.

#### 9.21.4 A count pin fired, and that was the system working

The full suite went **1 red** on `TenantCacheKeyUnitTest#everyCacheAnnotationUsesTheTenantAwareHelper`:
*"Expected size: 23 but was: 21"*. The deleted `ItemdataService.setPutAwayLocation` carried a
`@Caching(evict = {…})` holding **two** keyed `@CacheEvict`s, so the tenant-aware-key census legitimately
dropped by two. Pin lowered 23 → 21 **with the deletion named in its javadoc**, and the javadoc now says
explicitly: *only ever lower this number alongside a named deletion.* A silent decrement is the exact
regression the pin exists to catch, and this one arrived attributable within seconds of the run — which is why
the full-suite-against-baseline step in the floor is not optional even for a deletion that "obviously" only
removes code.

#### 9.21.5 Three verify rows would have gone permanently red — inverted, and the inversion itself was wrong first

`grep`ping `sbdocs/` found the deletion referenced in 12 files. Two were **verify scripts asserting the
endpoint EXISTS**, i.e. three rows that would now be permanently red — and per the row-hygiene rule a
permanently-red row is *worse than no row*, being indistinguishable from unfinished work. Fixed directly, no
ticket (tooling defects don't get one):

| Script | Row | Was | Now |
|---|---|---|---|
| `verify-SBDEV-2643-…` | `X-legacy` | `file_contains 'GetMapping(path="/setPutAwayLocation/'` — the endpoint *stays*, on 2732 §10.4 Q5's reasoning | `code_not_contains 'setPutAwayLocation'` — it must not come **back** |
| `verify-SBDEV-2732-…` | `IDS-deleg` | `file_contains 'putawayConfigService\.'` on `ItemdataService` | `file_not_contains` — no putaway write there at all |
| `verify-SBDEV-2732-…` | `IDCTL-deleg` | `file_contains '(itemdataService\.setPutAwayLocation|putawayConfigService\.)'` | `file_not_contains` — same |

Inverted rather than deleted because the load-bearing direction flipped: 2732's real invariant survives in a
*stronger* form (exactly one validated writer). The **authority is the JUnit/ArchUnit pin**; these rows are the
cheap cross-file echo.

**Two things went wrong on the way, both caught by negative-testing the rows — which is the only reason they
are trustworthy:**

1. **My test harness lied.** I drove the three rows through a `bash` loop splitting fields with `IFS='|'` — and
   one row's regex *is* an alternation containing `|`. It was split mid-pattern, so the file argument became a
   pattern fragment, the `[ -f ] || return 1` guard fired, and the row reported FAIL in **both** directions.
   It read as "row correctly detects the change" and actually meant "row never ran." Same family as the four
   wrong-shape greps earlier on this ticket: **the harness is as likely to be wrong as the thing it measures.**
2. **A tombstone comment defeated a negative row.** `X-legacy` went red against *correct* code, because the
   deletion left a comment naming the path it forbids. A good deletion always leaves such prose, so **every
   negative row on a deleted symbol needs comment-stripping.** Added `code_not_contains` to the 2643 script
   (fails closed on a missing file, like its sibling) with that reasoning recorded at the helper.

All six checks now behave: **red against the pre-deletion file, green against the post-deletion file.**

#### 9.21.6 A doc had been wrong since SBDEV-2732, in the same way as the code

`wms2-caching-strategy.md` §4 credited `ItemDataController.setPutAwayLocation` with
`@CacheEvict(allEntries = true)` — which **2732 had already removed**. So the identical false claim sat in
*three* places (that row, its §-note, and `IdempotencyFilter:413`), all descended from one stale reading, and
none of them was found by any test. Rows retired, note rewritten, log entry added.

**A pre-existing gap got re-rated while in there.** §7 lists *"`SkuRestController.delete` does not evict
`itemdata`"* at **Low**. It is deterministic, not incidental: the handler's own loop calls the `@Cacheable`
`itemdataService.findByClientIdAndItemNr` at `SkuRestController:323` to find each row *immediately before*
deleting it — so the delete **warms** the cache with the entity it removes, guaranteeing a stale entry for the
5-minute TTL rather than merely leaving one if previously read. Re-rated **Low→Medium** in the doc.
**Not fixed** — out of scope here, and whether it becomes its own ticket is Nam's call.

#### 9.21.7 Counts and PRs

- Full clean suite **5672 / 0 failures / 67 skipped, BUILD SUCCESS** (baseline 5673/0/67: −2 deleted tests, +1 new).
- Guard test **8 → 9**; targeted run **89/89**.
- **wms2-api PR #220** · **wms2-web-ui PR #89**. Both target `develop` only.
- The web-ui negative assertion is **kept and re-justified** (comment-only, proven so by diff). It is now
  stronger: rebuilding that URL would 404 — a broken screen found in QA — whereas the Jest test fails in CI.
  The two repos deploy independently, so **neither pin implies the other**.
- **Reviewed by two independent lanes — see §9.22.** Both found the same High, from opposite directions.

---

### 9.22 Review of the deletion — the deletion was right and the pin was wrong

Two lanes ran in parallel: one on the code and tests, one re-deriving the caller sweep and testing the
verify rows. **Both independently measured the same High**, which no amount of re-reading my own diff would
have found.

#### 9.22.1 HIGH — deleting the instance left the CLASS of defect untested

Reintroducing the hazard under a **different path spelling**, doing a raw save instead of calling the
validated writer:

```java
@GetMapping(path = "/updatePutawayDest/{itemdataid}/{locationid}")   // outside GUARDED => ungated
itemData.setPutawaylocationId(locationId);                          // no validation, no audit
return ResponseEntity.ok(itemdataRepository.save(itemData));
```

**Survived the entire suite: 5672 / 0 / 67 — byte-identical to a clean run.** Zero signal.

Why every existing pin missed it:

| Pin | Why it was blind |
|---|---|
| R8-8 (call sites) | resolves callers **of** `PutawayConfigService.set*Destination`; a raw save calls none, so the offender list is unchanged and it stays green |
| R8-9 (deletion pin) | matches the **string** `setPutAwayLocation`; different spelling |
| the two deleted `ItemDataControllerUnitTest` tests | they *were* the pin (SBDEV-2732 §3.5) and I deleted them |

**The lesson, and it generalises past this ticket:** I replaced a *behavioural* pin with a *nominal* one.
R8-9 asserts a name is absent; the deleted tests asserted a behaviour. I treated "stronger against the
mutant I imagined" as "stronger", and the mutant I imagined was a rename — the one shape a name-match does
catch. **A deletion PR must ask what the deleted tests were pinning, not only whether the deleted code is
gone.**

**Fix — R8-10 `onlyTheValidatedWriterMayWriteThePutawayField`**: an ArchUnit rule on the **field** rather
than the callee — only `PutawayConfigService` may call `Itemdata.setPutawaylocationId`. Exactly one caller
exists in `src/main` (`PutawayConfigService:154`), so it is greenable with no refactoring, and it survives
refactors where mock-interaction assertions die with their fixture. Mutant re-run: **KILLED**.

⚠ **Its javadoc records what it cannot see.** `ItemdataRepository` carries a class-level
`@RepositoryRestResource` (`:18`), and `Itemdata` appears in `RestConfiguration` only inside `exposeIdsFor`
(`:267`) — which withdraws nothing — and in **no** `disable(WRITE_VERBS)` block. So
`PATCH /v3/itemdata/{id}` with a `putawaylocationId` body reaches the field without calling any Java
writer. **Pre-existing and wider than this PR**; recorded, not fixed. A green R8-10 means *"no Java code
bypasses the validated writer"*, never *"the field is protected"*.

#### 9.22.2 MEDIUM — R8-9 was blind to inherited methods, on a base class of 43

`getDeclaredMethods()` does not see inherited members, and `ItemDataController` extends `AdminController`
— **the base class of 43 controllers, which declares 10 mappings of its own**, so inherited mappings are an
established pattern here. Declaring the **exact deleted path** on `AdminController` restored
`GET /v3/itemData/setPutAwayLocation/{itemdataid}/{locationid}` *on 43 controllers at once* and left R8-9
**green at 9/9**. Fixed by unioning with `getMethods()` — the same union, for the same reason, that
`TenantCacheKeyUnitTest.allMethodsOf` already carried. Mutant re-run: **KILLED**.

#### 9.22.3 Lows — all fixed in this pass

| # | Finding |
|---|---|
| Item 4 | **two** orphaned javadocs from the deleted field/mock — one stacked with no blank line, so *"the ONE validated, audited writer"* read as documentation for a read-only 2643 facade. I had fixed only the third copy, in `ItemdataService` |
| 6a | three `PutawayConfigService` comments named `onlyTheFourGatedHandlersReachTheSetters` — **a method that does not exist**, in the load-bearing "pinned by X" note. A maintainer greps the named pin and finds nothing |
| 6b | "four gated handlers" in a `@DisplayName`, the method name and two messages, above an assertion listing **three** |
| Item 5 | the rewritten `IdempotencyFilter` javadoc enumerated only `create`/`update` then claimed the `clear()` was "not a widening" — **false for `delete`**, which carries no `@CacheEvict`. Now names all three; matches two, exceeds one |
| M1 | `check_IDCTL_raw_save_gone` pinned the **exact two-line text** of the old body, local variable name `newItemData` included. Mutant C's shape has no such local and passed. Generalised to the real hazard |
| L4 | rows `IDS-deleg`/`IDCTL-deleg` still said *"delegates"* while asserting non-delegation → `*-nowrite` |
| L5 | those two rows used `file_not_contains`, which does not strip comments, and **passed only by casing luck** — the tombstone says `PutawayConfigService.` (capital P) against a lowercase pattern. Lowercase that letter and the row reds on correct code |
| L6 | `code_not_contains` / `file_not_contains` **false-GREEN on an unreadable file**: `[ -f ]` passes, `grep` exits 2, `!` inverts the no-match into a PASS. Repo-wide pattern → fixed in the **template** with a mutation-checked guard case |
| L7 | the service half had **no** verify row anywhere, only the JUnit pin, while my commit message presented both halves as pinned in both places. Row added and registered |

**Not a finding.** A lane reported three further `PutAwayLocation` occurrences outside `wms2-api` as
evidence the sweep was overstated. All three are `defaultPutAwayLocationName`, an unrelated field; **zero**
contain `setPutAwayLocation`. Two more (L2, L3) were already fixed on unmerged branches the lane could not
see. Recorded so the count is not double-remediated later.

#### 9.22.4 The lanes raced the same worktree — and it produced the best evidence

Lane B detected an **uncommitted 10-line addition** appear in the shared worktree at 15:34 and vanish at
15:37: Lane A's mutant C. Lane B never wrote there, established provenance from `git diff` + `stat`, and —
because its fixture snapshot was taken mid-window — tested all three verify rows **against the mutant**,
independently confirming Lane A's High. **Two lanes on one worktree is a real hazard** (a prior session had
two lanes race and fabricate a result); it happened to pay off here, and next time it will not. Give
concurrent review lanes separate worktrees.

#### 9.22.5 Tooling fixed directly, per policy

`verify-plan-template.sh` gains a first-class `code_not_contains` and an `[ -r ]` guard on both negative
helpers, with the reasoning at the helper. `test-verify-plan-template-helpers.sh` gains **6 cases** —
comment-only line ignored, javadoc continuation ignored, symbol on a code line still caught, and
fail-closed on missing **and** unreadable files. **Mutation-checked**: dropping the `[ -r ]` guard reds
exactly the unreadable case (14 pass / 1 fail), so the guard test is not vacuous. Now **15 pass / 0 fail**.

#### 9.22.6 Final state

- Full clean suite **5673 / 0 failures / 67 skipped, BUILD SUCCESS** — back to the develop baseline count
  (−2 deleted, +1 R8-9, +1 R8-10). Guard test **8 → 10**.
- All four modified/new verify rows re-tested: **red pre-deletion, green post-deletion**, and the
  generalised raw-save row **reds on mutant C's shape** while staying green on both correct states.
- **wms2-api PR #220** (`c6409a16` + `f98d665e`) · **wms2-web-ui PR #89**. `develop` only.
- **The review fixes were then attacked by a third lane — see §9.23. R8-10 did not hold.**

---

### 9.23 Merge log — the two open R8-adjacent PRs landed 2026-08-27

Both were `MERGEABLE`/`CLEAN` against `develop` and were merged in ascending PR order. Neither carried a
Flyway migration, so the `check-migration-version-collision.sh` pre-merge sweep was not applicable.

| PR | Scope | Merge commit |
|---|---|---|
| **#217** | §9.18 — carve out the last 2 Keycloak directory reads; `AdminController` moves **nothing**, split **7 move / 13 stay** | **`93806b3d`** |
| **#220** | Delete the legacy `setPutAwayLocation` write path (closes review **F3**) | **`fadc79b9`** |

§9.22.6 recorded #220 as `c6409a16` + `f98d665e` **on the branch**; `fadc79b9` is its merge commit. Both
figures are correct — cite the merge commit when asking "is it on develop".

⚠ **What this does NOT close.** R1–R8 are all closed and R8 shipped at its §9.17-narrowed scope (the 7
putaway sites only). **§1's ~97 rows remain a separate, unstarted slice**, and that slice is the bulk of
the SBDEV-3017 ticket. Do not read "R8 shipped" as "SBDEV-3017 done".

⚠ R7 is **out of this plan** — filed as **SBDEV-3124** (`/rest/**` is `permitAll`, 15 unauthenticated
write endpoints). Verified still live on `develop @ f5b498b8`: `SecurityConfiguration.java:150-154`.
It is blocked on the OMS side — `oms-laravel-api config/wms.php:209` still reads
`env('WMS_AUTH_TYPE', 'none')`, so enforcing at the WMS end first breaks facility sync, advice creation
and SKU sync **silently**. See `260520-rest-security-permitall-hardening.md` (`status: blocked`).

---

### 9.24 Third lane, scoped to R8-10 alone — it did not hold

Nam authorised one narrow lane: *"attack R8-10 only; assume the rest is fine."* It found **six escapes,
five of which survived all 5673 tests**, plus a **false positive**. R8-10 was my fix for §9.22.1's High, so
this is the second time on this ticket that my remedy for a measured hole was itself holed.

#### 9.24.1 What R8-10 actually pinned, versus what I claimed

As written it saw only: *`invokevirtual`-shaped calls, named exactly `setPutawaylocationId`, from a
**non-constructor** method body, through a reference **statically typed** `Itemdata`.* Every clause was a hole.

| Escape | Root cause | Fix |
|---|---|---|
| alias setter `setPutawayLocationId` (one capital L) writing `this.putawaylocationId` | **I watched the setter, not the column** | second assertion over `getFieldAccesses()` + `AccessType.SET` |
| `itemData::setPutawaylocationId` | `invokedynamic`; the setter is only in the constant pool | union `getMethodReferencesFromSelf()` |
| write from a **constructor** | `getMethods()` excludes constructors | `getCodeUnits()` |
| write from a **static initializer** | same | `getCodeUnits()` |
| write through a **subtype**-typed receiver | `getTargetOwner()` is the *static receiver type* | `isAssignableTo(Itemdata.class)` |
| `@RequestBody Itemdata` (Jackson, reflection) | no static call site exists at all | **R8-11**, a companion rule |
| `@Modifying` native `UPDATE` | a query string is opaque to bytecode | **R8-12**, a companion rule |

**The method-reference escape is the one that matters most in practice.** `x::setFoo` is ordinary Java, not
an attack shape — it is the escape most likely to arrive by accident in a routine refactor.

**And the javadoc line was false.** I wrote *"read it as: no Java code bypasses the validated writer"* in the
very paragraph where I congratulated myself on recording the rule's limits honestly. I named one limit (SDR)
and missed six. The honest reading is now stated instead: *no code unit in `net.aim_ai.wms` calls, references
or field-writes this column except the validated writer* — with Jackson binding and `@Modifying`/native SQL
named as the two routes **no call-site rule can see**, each carrying its own companion assertion rather than
a claim.

#### 9.24.2 The false positive mattered more than any single escape

Moving the **legitimate, behaviour-identical** call into an anonymous inner class turned R8-10 red with the
diagnostic `["#run"]` — empty simple name, no package, nothing to grep. That is the *correct code reds the
rule → the rule gets deleted* failure mode, and a deleted rule pins nothing at all.

**My first fix for it was wrong.** I normalised the origin label to the enclosing top-level class, which
fixed the *message* and not the *failure*: the label became `PutawayConfigService#run`, and the assertion
still pinned `#setSkuDestination`. Measured red again. **A better diagnostic is not a fix.**

The actual fix splits granularity by what each assertion is for:

- **calls → CLASS granularity.** Any lambda, inner class or helper inside `PutawayConfigService` is accepted;
  a write from any other class fails. The offending code units are carried into the failure *message*, so a
  red still says where to look.
- **field writes → METHOD granularity, kept deliberately.** There the precision *is* the point: the alias
  setter lives inside `Itemdata`, so a class-level check would wave the measured escape through.

⚠ **What the class-granularity concession costs, stated plainly in the javadoc too:** a **new method on
`PutawayConfigService` itself** could write the field without validating. Accepted, because it is far
narrower than the false positive it removes, and §9.19's R8-8 independently pins which handlers may reach
that service.

#### 9.24.3 Verification — all 8 mutants replayed, and each fix shown individually load-bearing

Every mutant applied to a clean tree, recompiled via `mvn -o clean test`, its presence verified in-file
before the run and its absence after:

| Mutant | Result | Killed at | Which assertion |
|---|---|---|---|
| M4a constructor · M4b static init · M6b subtype · M7 method reference | KILL | `:377` | the call assertion |
| M2 alias setter + direct field write | KILL | `:398` | the field-write assertion |
| M3 `@RequestBody Itemdata` | KILL | `:431` | **R8-11** |
| M5 `@Modifying` native UPDATE | KILL | `:454` | **R8-12** |
| M6a legit call in anonymous inner class | **GREEN** | — | false positive resolved |

**The distinct kill sites are the evidence that matters** — each escape dies at the assertion designed for
it, not incidentally at one catch-all, so all four fixes plus both companions are individually load-bearing.

#### 9.24.4 Two harness faults of my own, both caught

1. **I asserted an API existed from a grep that never showed it.** `getFieldAccessesFromSelf()` is on
   `JavaClass`; on `JavaCodeUnit` it is `getFieldAccesses()`. The compiler caught it, but it was an
   assumption presented as a check — the same shape as the four wrong-shape greps earlier on this ticket.
2. **My M4a mutant was inadmissible and nearly counted as a result.** Adding `Itemdata(Long)` to the
   `@Entity` removed the implicit no-arg constructor that JPA and every `new Itemdata()` depend on, so it
   did not compile — and **a compile error produces no test output, which reads exactly like a kill.** The
   harness classified it `COMPILE-ERROR(inadmissible)` instead of counting it, which is the only reason it
   did not become another measured lie. **Every mutation harness here needs that classification**, not just
   a pass/fail.

#### 9.24.5 Process finding: give concurrent lanes separate worktrees

§9.22.4 recorded two lanes racing one worktree and getting lucky. This lane was told to `cp -a` into a
private copy and do all compile-and-run work there. No interference, and its results are reproducible.
**Make that the default for every review lane that compiles anything.**

#### 9.24.6 Score

Guard test **10 → 12** (R8-11, R8-12). **Three lanes, three real findings, every one a defect I would have
shipped** — six for six across this ticket's lanes, and twice now the thing they broke was my own fix for
their previous finding.

#### 9.24.7 ⚠ THE HARDENING WAS ORPHANED BY A MERGE — read this before citing any commit here

**PR #220 was merged at 2026-08-27 20:23:04Z (merge `fadc79b9`) by someone other than the author of §9.24,
capturing branch tip `f98d665e`.** The hardening commit `70f79584` was pushed to that same branch
**afterwards**. A merged PR's branch is a dead end, so it never reached `develop`:

| Commit | On `develop`? |
|---|---|
| `c6409a16` delete the legacy path | **yes** |
| `f98d665e` first round of review fixes (R8-10 **with all six escapes**) | **yes** |
| `70f79584` harden R8-10 | **NO — orphaned** |

So **`develop` carried R8-10 in its defeated form**: zero `getCodeUnits` / `getMethodReferencesFromSelf` /
`R8-11` / `R8-12` markers present, verified by `git show origin/develop:…`. Re-cut onto fresh `develop`
(`c0d759a6`) as `e93be137` → **PR #223**, **MERGED 2026-08-27, merge commit `03da8115`** (Nam's
instruction). Landing verified the way #220's failure taught: `git merge-base --is-ancestor e93be137
origin/develop` passes, and `git show origin/develop:…PutawayConfigActionGuardUnitTest.java` now carries **9**
hardening markers (`getCodeUnits` / `getMethodReferencesFromSelf` / `R8-11` / `R8-12`) where it carried **0**,
at **12** `@Test`. So the defeated R8-10 was on `develop` for roughly 40 minutes and is now replaced.

This is [[stacked-v2-pr-merge-order-orphan-trap]] in a new shape: not a wrong merge *order*, but **pushing
to a branch after its PR merged.** The lesson is narrow and mechanical: **after any push, verify
`git merge-base --is-ancestor <commit> origin/develop`** — a successful `git push` is not evidence the work
is on `develop`, and `gh pr view` showing `MERGED` says nothing about commits pushed after that timestamp.

**Also: §9.23 was written concurrently by another session while §9.24 was in flight**, producing two
sections numbered 9.23. Mine renumbered to 9.24. Its content is accurate and independently verified here —
`93806b3d` (#217) and `fadc79b9` (#220) both exist and both PRs report `MERGED`. Treat this plan as
concurrently edited: **re-read before appending.**

---

### 9.25 TRANCHE 1 IMPLEMENTED 2026-08-28 — 71 of the 75 rows gated; C30–C33 split to SBDEV-3154

**PR #232** (wms2-api) — commit **`01028a37`** on `bugfix/SBDEV-3017-B1-mvc-write-surface-gating`, off
`origin/develop@8c676d34`. **PR wms2-web-ui #95** — commit **`a10aca0`** for AC-7. Merge **API first**
(§8.14.3). Both open, neither merged; promotion past `develop` is dev-ops'.
(`f3d51631`/`65e4bbb` were the pre-review commits, amended after the review lane's 11 findings.) Full suite **5691 / 0 failures / 0 errors / 67 skipped**,
tree clean.

**Scope decision (Nam, 2026-08-28):** ship the 71 rows that annotate onto existing constants; split the
four `AdminActionController` operator-console routes (C30–C33) out as **SBDEV-3154**, because they alone
need two new `FunctionEnum` constants and `V2.2.22`. This keeps the PR migration-free — so the merge is not
a Flyway run on every tenant — and drops the tier T3 → T2. It follows the precedent §9.16 and §9.17 set.

#### 9.25.1 Five plan claims that did not survive measurement

| claim | source | verdict |
|---|---|---|
| B1 / B15–B20 fail AC-2′ (CS-REP reaches the screen, lacks the function) | §9.7.1 | ❌ **retracted.** Measured by USER population: 1 excluded user each, and it is `Z-mariaortiz(archived)` |
| `WEB_UI_ACTION_PRINT_TOTE_LABELS` is "super-admin-only", an outage | §8.2 | ⚠️ **conclusion right, reason wrong.** 38 users, not super-admin-only — but a *different* 38 from the screens' 46/47, so it 403s **7 live users**. A1/A2 take the screen constants |
| Two more new constants owed (`_GENERATE_TOTE_LABELS`, `_CREATE_BILL_OF_LADING`) | §9.6.1 | ❌ **not needed.** §1 records both as explicitly *rejected* alternatives; §9.6.1 read a rejected alternative as a recommendation. The count stays at two |
| Six endpoints to be DELETED | §2.5 | ❌ **superseded** by §9.15 dec 6 — all six still exist and are gated here. **AC-8 is unachievable as written** |
| `/v3/report/exportParcelPicking` blocked on a missing constant | §1.1 r6 | ❌ **stale.** `WEB_UI_VIEW_PARCEL_PICKING` exists, 8 roles, landed in `V2.2.19` |

Exactly **5** of the plan's constants are genuinely absent from both `WmsConstants.FunctionEnum` and
`mywms_function` on `dev_wh01_om1` — code and DB agree.

#### 9.25.2 🔑 The transferable rule: role COUNT is not the AC-2′ unit, USER population is

Three role-name verdicts were checked against user populations. **Two were wrong, in opposite directions** —
so the failure mode is not "role names overstate" or "understate", it is that the role axis is simply
uninformative:

| claim | verdict on measurement |
|---|---|
| `WEB_UI_VIEW_CLIENT` / `_PRINTER` gate screens with no named holder (**this session's own**) | ❌ 38 users each |
| B1/B15–B20 break CS-REP (§9.7.1) | ❌ 1 archived user |
| `PRINT_TOTE_LABELS` causes an outage (§8.2) | ✅ 7 live users |

`WEB_UI_VIEW_SYSTEM_PROPERTY` has **1 role and 38 users** — the narrowest-looking constant in the catalogue
is among the widest. Every AC-2′ check must join `mywms_function` → `mywms_role_mywms_function` →
`mywms_role` → `mywms_group_mywms_role` → `mywms_group` → `mywms_group_mywms_user` → `mywms_user`. Stopping
at `mywms_role.name` is unreliable in both directions. Evidence: `SBDEV-3017-db-evidence.md` in the worktree.

This also **closes R2's §9.7.3 blocker** (*"both must close before R8 writes an annotation"*), which R8's
narrowed scope left open and which landed on this slice.

#### 9.25.3 Two structural findings the path-keyed tables hide

1. **`DashboardController extends ReportController`.** The dual `/v3/report` + `/v3/dashboard` mapping is
   **inheritance**, not a two-valued `@RequestMapping`. One method-level annotation covers both paths — §1's
   path-keyed rows overstate that work. It also means a class-level annotation on `ReportController` would
   silently gate every `/v3/dashboard` read; §2.2's method-level rule for it is right.
2. 🔴 **`SurfaceInventoryContextTest` over-reports gating.** Its `requiresFunction` resolves the class-level
   fallback on `hm.getBeanType()`; `FunctionGuardInterceptor:166` resolves on
   `getMethod().getDeclaringClass()`. They disagree for any handler inherited from `AdminController` into a
   subclass carrying a class-level annotation — this slice creates three. The tool reports those inherited
   handlers as gated; the interceptor does not gate them. **The interceptor is the authority**; the
   inventory's gated/ungated tallies are an upper bound on coverage. The new pin uses the interceptor's axis.

#### 9.25.4 The anti-drift rule blocked the first run — correctly

`FunctionGuardArchTest#noSharedControllerCarriesRequiresFunction` failed on **8** handlers
(`DashboardController#printToteLabels`, all six `ReplenishOrderController` writes, `UnitLoadController#reprintLabel`)
because their **classes** are shared with the mobile UI. Each **method** was then verified individually
against `wms2-mobile-ui@origin/develop` with `git grep` over every tracked file: **zero** mobile callers,
with positive controls in the same run (`$axios` 34 files, `replenish` 29, `store/` 12) so the zero is
absence and not a broken search. Mobile replenishment reaches `/replenish`, `/replenish/clientList` and
`/replenish/requestAmount` on `MobileReplenishController` — a different surface, already gated. All 8
registered in `REVIEWED_SHARED_METHOD_GATES` + `REVIEWED_SHARED_GATE_FUNCTIONS` with that enumeration,
rather than the rule being loosened.

#### 9.25.5 ⚠️ The mutation harness destroyed work before it produced a result — read this before writing one

The first harness restored each mutant with `git checkout -- <file>`. **The work was uncommitted**, so
"restore" reverted to `origin/develop` and silently deleted **17 annotations** across `AdviceController` (7),
`ReceivingController` (6), `SystemPropertyController` (3) and `UnitLoadController` (1). Every mutant after
the first then ran against that broken tree. **All four reported KILLED and only the first was real.**

It was caught because M2's diagnostic quoted **M1's** constant — the verdicts were copies of each other.
A per-mutant verdict that does not name the mutant's own symbol is the tell.

Re-run after committing: **5 of 5 KILLED**, each with its own correct diagnostic, each restore verified
clean, and the final tree byte-identical to `f3d51631`:

| mutant | killed by |
|---|---|
| M1 drop a METHOD gate | `expected [WEB_UI_VIEW_CREATE_INBOUND_BOL] but was [UNGATED]` |
| M2 drop a CLASS gate | `SystemPropertyController /v3/systemProperty/create … [UNGATED]` |
| M3 narrow the A7 ANY-of 4 → 3 | the four-member set assertion |
| M4 rename a route | `ROUTE NOT DEPLOYED (renamed or deleted?)` |
| M5 swap a constant (B21 → `ACTION_ADJUST_AMOUNT`) | `expected [WEB_UI_VIEW_GOODS_RECEIPT_POSITION] but was [WEB_UI_ACTION_ADJUST_AMOUNT]` |

**M5 is the one that matters** — it kills the §0.G trap directly: the semantically-obvious constant that
would 403 the `receiving` and `CS-REP` roles holding that screen.

Two rules, both mechanical: **the restore target must be a commit, never the working tree**; and
**a mutation verdict must be attributed by the mutant's own diagnostic**, or a stale tree reads as a kill.
Adds to [[mutation-harness-traps]], which had already recorded 9 measured lies from hand-rolled harnesses.

#### 9.25.6 What this slice does NOT close

- **C30–C33** — SBDEV-3154. `recoverStuckPallets` and the three `trigger*`/`testCrmConnectivity` GETs stay
  ungated until it ships. No UI caller and no menu entry, so the reach is API replay.
- **The capability, as distinct from the route.** Every gated entity keeps its live SDR write verbs
  (§9.12); each annotation's comment says so explicitly. **Do not close SBDEV-3017 on this slice.**
- **The 122 ungated MVC reads** and the **16 POST-as-query report reads** (SBDEV-3142).
- **`/rest/**`** — SBDEV-3124, blocked on the OMS side.
- **The 10 boundary rows X1–X10** (§9.9.1). AC-1 as §8.6 rewrote it wants 85, not 75; this ships 71 + 4
  split = 75, i.e. AC-1 **as originally written**. `runClubLine` and `runTransfer` still run a whole
  batch from a bare GET. State which reading of AC-1 the ticket closes against.

#### 9.25.7 REVIEW LANE 2026-08-28 — 1 High, 4 Medium, 6 Low. All fixed; commit amended to `01028a37`

One adversarial lane, its own copy, DB access to five tenants. It **confirmed the 71 gates themselves**:
every constant/screen pairing re-traced endpoint → store/component → `appMenuList.js` → DB, no gate that
403s a legitimate user, class-level placement safe on all four classes, no OMS-called endpoint gated, and
the §8.2 and AC-2′ measurements reproduced exactly. The defects were in the **rails and the claims**.

| # | finding | fix |
|---|---|---|
| **H1** | 🔴 **The §0.C OMS carve-out had ZERO test coverage.** The lane added a class-level gate to `ClientController` + `BoxTypeController` — the shape of a future "tidy up the duplicate method annotations" refactor — breaking both OMS writes, and **every rail stayed green (28/28)**. The pin was a pure allow-list; `SurfaceInventoryContextTest` only asserts `total > 200`; the shared-controller ArchUnit rule keys on a hard-coded list of four classes that excludes all three carve-outs | 3 rows added asserting the carve-out is **UNGATED** (expected set `""`). Mutation M6 reproduces the exact mutant → now **KILLED**: `"BoxTypeController /v3/boxType/create"="expected [] but was [WEB_UI_VIEW_CASE_TYPE]"` |
| **M1** | AC-4's "122 ungated mutating" cannot see 10 state-changing GETs (`runClubLine`, `runTransfer`, 6 lane ops, `activateTransferOrder`, `fixPickingPosition`) — the tool calls a GET mutating only on `/delete\|/remove\|/cancel\|/reset\|/create`, so they classify as *reads* **by construction** | Disclosed in the commit message and db-evidence §10. **AC-1 explicitly NOT ticked** — this closes it as originally written, not as §8.6 rewrote it |
| **M2** | B21's shipped comment justified its constant on the role-name axis the same commit calls unreliable — and measured, `ACTION_ADJUST_AMOUNT` is the **wider** constant (44 users vs 43), so §0.G's "the semantically obvious constant is the wrong one" is unsupported | Comment rewritten to the caller-based reason (`INBOUND_BOL → GOODS_RECEIPT_POSITION` denies nobody). Constant unchanged — it was the right choice for a different reason |
| **M3** | **`MobileReplenishController` does not exist** (only `MobileReplenishService`). Two comments + §1.2 r5.6 named it; the class is `controller/mobile/ReplenishController`, gated class-level with `MOBILE_UI_VIEW_REPLENISHMENT` — not the `_REPLENISH_REQUEST` the comment claimed, which covers only `/clientList` and `/requestAmount` | Both comments corrected with the real class, line numbers and constant |
| **M4** | The worklist's stated baseline "5673 / 0 / 67" is off by 17 | Corrected to **5690** (parent `8c676d34`), commit **5691**, delta exactly +1 = the new test |
| **L1** | db-evidence §7 dismissed the two `⚠ semantics-derived` map entries as "not the constant for any of the 75 rows" — **invalid**, since AC-2′ compares the *screen's* constant to the *endpoint's*, so it matters precisely when they differ | Both measured (Pick Pack→`ORDER` = 0 denied; Dashboard→`PARCEL_PICKING` = 1 archived). Safe — but the argument is the reusable error |
| **L2** | The pin's rationale for `/v3/dashboard/reprintLabels` was backwards ("gating only /v3/report would close nothing" — method-level makes that inexpressible, and it is `/v3/report` that has the live caller) | Rewritten |
| **L3** | Asymmetric read coverage: `FixLocationAssignment`'s 2 class-swept reads were pinned, `LabelPrinting`'s **8** were not — so downgrading that class annotation to method-level left the pin green while un-gating all 8 | 8 rows added. Mutation M7 → **KILLED**, naming `defaultPrinterTypes` |
| **L4** | `test/util/reprentLabelHostSet.spec.js` opens "THE GATE THIS FENCES IS DECIDED, NOT IMPLEMENTED … currently UNGATED" — false the moment this merges | Corrected in the web-ui branch |
| **L5** | 14 files added an explicit `WmsConstants` import beside an existing wildcard of the same package | Removed |
| **L6** | The shared worktree was left with a stale INDEX (21 files staged at pre-change content) | Repaired with `git reset`; **cause found and it is a general trap — see below** |

##### 9.25.8 🔑 `cp -a` of a git WORKTREE does not isolate git state

L6's cause was **my own instruction**. I told the lane to isolate itself with
`cp -a <worktree> <scratch>`. In a worktree, `.git` is a **file**, not a directory:

```
gitdir: /home/nampark/dev/wms-claude/v2/wms2-api/.git/worktrees/SBDEV-3017-B1
```

`cp -a` copies that pointer verbatim, so the copy shares the **original's index, HEAD and reflog**. The
lane's `git checkout <parent> -- src/` wrote into *my* index. Only file contents are isolated; all git
state is shared.

**The tell:** `git status` showing `MM` on every file while `git diff HEAD` is **empty** — the index is out
of sync with both HEAD and the worktree. `git reset` repairs it losslessly, but check `git diff HEAD` is
empty first.

**Isolate a lane with `git worktree add --detach <path> <ref>` or `git clone`** — never `cp -a`, unless the
copy's `.git` is deleted or the lane is forbidden every writing git command. This is
[[review-lanes-must-not-share-a-worktree]] in a second shape.

---

### 9.26 SECOND REVIEW ROUND 2026-08-28 — two lanes, converging on one residual. Head is `bd953877`

After §9.25.7's 11 fixes the commit was amended to `01028a37` — and **nobody had reviewed the fixes**. Two
lanes were run on that delta: the original lane auditing closure of its own findings, and a fresh adversarial
lane on `git diff f3d51631 01028a37`. Combined: **1 High, 7 Medium, 10 Low across both rounds, all fixed.**

#### 9.26.1 🔑 Both lanes independently found the SAME residual — in my fix for the first round's High

The three §0.C carve-out rows read only `@RequiresFunction`. Measured twice, independently:

```
@PreAuthorize("hasRole('sb_admin')") on ClientController#importClients   →   5691 tests, 0 failures, BUILD SUCCESS
```

An OMS principal holds no `ROLE_sb_admin`, so this breaks facility sync **exactly as thoroughly** as the
annotation shape the rows *did* catch. It is the **more** likely shape: `@EnableMethodSecurity(prePostEnabled
= true)` is live (`MethodSecurityConfig:9`), `ClientController extends AdminController`, and `AdminController`
already carries `@PreAuthorize(IS_SB_ADMIN)` on 8+ handlers — and §8.4 explicitly *prefers* `@PreAuthorize`
for admin surfaces.

**This is the third time on this ticket that a remedy for a measured hole was itself holed** (§9.24 was the
second). The pattern is now stable enough to name: *a fix aimed at one mechanism fences one mechanism.* Ask
"how many ways can this outcome be produced?" before calling a guard complete. Here the answer was three:

| mechanism | caught by | diagnostic |
|---|---|---|
| `@RequiresFunction` | the carve-out rows | named route |
| `@PreAuthorize` | the carve-out rows, **only after this fix** | named route |
| `FunctionGuardInterceptor.GUARDED` membership | `FunctionGuardStartupAssertion:74` | context-load stack trace |

`GUARDED` needs no row — it fail-closes *unannotated* handlers, so the context refuses to boot and the pin
cannot even load. Recorded in-code so the next reader does not re-derive it as a hole.

#### 9.26.2 Two false claims introduced WHILE FIXING false claims

- **§9.25.7's M3 fix corrected the class name and carried half the old error forward.** It said
  `/clientList (:91)`; `:91` is `/requestLocation/{input}`, and `/clientList` is at `:155` carrying **no**
  method annotation. It also cited `:77` as documenting a bare `/v3/replenish` — `:77-79` is a remark on
  `/fixedLocationUpperBound`, and **there is no bare `/v3/replenish` mapping at all**; every handler on that
  class declares a path. Verified independently before correcting.
- **§0.G's retracted role-name claim survived verbatim in a SECOND copy** — the pin test — so for one
  revision the two comments asserted opposite things. The amended commit message said *"its comment now says
  so"*, singular; the second lane called that "the one commit-message claim I checked and found only
  half-true." **Grep the CLAIM, never the file you happened to edit** — [[retitling-a-section-leaves-the-rule-asserted-below-it]]
  in a new shape.

#### 9.26.3 Rails hardened

- `ROUTE NOT DEPLOYED` no longer truncates mid-sentence on a carve-out row (its template appended an empty
  expected set).
- `hasSize(85)` moved to **its own `@Test`**. It sat after `assertThat(wrong).isEmpty()`, which throws first —
  so the size check was unreachable in precisely the run where someone might have deleted a row to silence the
  drift.
- The mutant enumeration in the commit message is now accurate at **nine**, all killed.

#### 9.26.4 What the lanes confirmed, and what it bounds

Neither lane found a defect in the **71 gates**. The fix delta touches only comments, imports and test code —
every `@RequiresFunction` value, placement and target is byte-identical to the commit the first lane
validated, so its endpoint-by-endpoint validation still stands. The first lane also re-measured the AC-2′
pairs across **five tenants** (dev, PRD hydra, three UAT): no live operator is 403'd anywhere.

Final: **5692 / 0 failures / 0 errors / 67 skipped** (baseline 5690 + the 2 pin tests). Head **`bd953877`**,
PR #232 OPEN. **AC-1 still not closed** — the ten state-changing GETs of §9.25.6 remain open.

#### 9.26.5 Process note: I clobbered my own test run

I started a `mvn -o clean test` and then ran further `mvn` commands in the **same worktree** while it was in
flight. Its log ends mid-run with no `BUILD` line. Nothing was reported from it, but a partial log is exactly
the shape that gets read as a result. **One `mvn` at a time per worktree** — the same shared-mutable-state
rule as [[review-lanes-must-not-share-a-worktree]], applied to myself rather than to a lane.

---

### 9.27 THIRD REVIEW ROUND 2026-08-28 — the fix was incomplete in the SAME way, twice more. Head `81989036`

Round 2's fix for the `@PreAuthorize` residual was itself re-reviewed, and the lane found **two further
uncovered mechanisms**. Both measured, both now killed. Suite **5693 / 0 / 0 / 67**.

#### 9.27.1 The `@PreAuthorize` fix covered one of FIVE method-security annotations

`MethodSecurityConfig:9` is `@EnableMethodSecurity(prePostEnabled = true, securedEnabled = true,
jsr250Enabled = true)` — **all three families are enabled**. My fix read `PreAuthorize.class` only.

**Measured:** `@Secured("ROLE_sb_admin")`, `@RolesAllowed("sb_admin")` and `@DenyAll` applied to the three
carve-out routes **simultaneously** → full suite **GREEN at 5692**. `@DenyAll` denies *everyone* — the most
total gate the framework offers, on all three OMS writes at once, unnoticed.

⚠ And `securedEnabled` / `jsr250Enabled` are **not pinned**: `MethodSecurityEnablementContractTest:64-67`
pins only `prePostEnabled`. Both families are live today with nothing asserting they stay that way.

All five (`@PreAuthorize`, `@PostAuthorize`, `@Secured`, `@RolesAllowed`, `@DenyAll`) are now checked.

#### 9.27.2 The `SecurityFilterChain` is a SIXTH axis, invisible to every Spring-context test in this repo

`SecurityConfiguration:157-160`, block C, is a plain prefix list. Adding `"/v3/client/**"` is a one-token
edit of a shape already present six times over. **Measured:** adding all three carve-out prefixes and
tightening the authority → all three OMS writes 403 in production, full suite **GREEN at 5692**.

Two structural reasons nothing could see it, both worth keeping:

1. **The bean is never built in the test lane.** `SecurityConfiguration` is
   `@ConditionalOnProperty(prefix = "rest.security", value = "enabled", havingValue = "true")` (`:43`) and
   `src/test/resources/application-integration.properties:49` sets `rest.security.enabled=false`. Every
   Spring-context test here runs under the `integration` profile, so the filter chain does not exist to
   assert against.
2. **The one test that reads the file is a comment-citation checker.**
   `SecurityConfigurationLinePinContractTest` pins line numbers to substrings so prose citing a line still
   points at what it claims. An *in-place* edit to the existing matcher list shifts no lines and sails
   through; only an *inserted* line reds it, and then incidentally, as a line-shift rather than an
   authorization judgement.

New `Sbdev3017OmsCarveOutSourceContractTest` covers it — the documented exception where a source assertion
is legitimate because no runtime test can reach the invariant. It is deliberately narrow: it flags only
matchers that **single out** a carve-out path, using an ordinary-`/v3`-traffic control path to separate the
broad `/v3/**` baseline (`:178`) from a targeted rule, and it fails loudly if that discriminator stops
holding or if its parser stops finding matchers at all (a vacuous green would be worse than no test).

#### 9.27.3 🔑 My "three gate mechanisms exist" comment was itself a false closed-set claim

Written to close a false claim, it asserted a **complete enumeration** — and that confident count is exactly
what made §9.27.1 and §9.27.2 invisible. There are at least six mechanisms on this route, seven counting the
filter chain. Same defect family as the claim it replaced.

**The rule, now stated in the code rather than the count:** say what is covered *here*, what is covered
*elsewhere and by which rail*, and what is **not** covered — never assert a total. A closed-set claim is a
load-bearing assertion and needs the same evidence as any other.

#### 9.27.4 Three rounds, one shape

| round | what the lane found | my fix |
|---|---|---|
| 1 | the OMS carve-out had **no** test coverage | 3 rows reading `@RequiresFunction` |
| 2 | those rows miss `@PreAuthorize` | added `@PreAuthorize` |
| 3 | that misses `@Secured`/JSR-250 **and** the `SecurityFilterChain` | all five annotations + a source contract test |

**Three consecutive rounds each found that my previous fix fenced one mechanism and missed its siblings.**
The 71 gates were confirmed correct in every round; it was the rails that took three passes. See
[[a-guard-fences-the-mechanism-you-aimed-at]].

Totals across all rounds: **1 High, 10 Medium, 12 Low — all fixed. Eleven mutants, all killed.**
**AC-1 still not closed** — the ten state-changing GETs of §9.25.6 remain open.

---

### 9.28 MERGED TO DEVELOP 2026-08-28 — and the four decisions Nam took to close the slice

| repo | PR | merge commit | verified |
|---|---|---|---|
| `wms2-api` | **#232** (`81989036`) | **`1f5f8697`** | `merge-base --is-ancestor` ✅ |
| `wms2-web-ui` | **#95** (`a10aca0`) | **`e629517`** | `merge-base --is-ancestor` ✅ |

API merged first (§8.14.3). Neither PR carried a Flyway migration, so the collision sweep was not applicable
— confirmed by diffing `db/migration` against `origin/develop` before merging, rather than assumed. Merging to
`develop` is a dev deploy; promotion to `release`/`main` is dev-ops'.

#### Nam's decisions, 2026-08-28

1. **AC-1 closes as ORIGINALLY written** (option (a)) — "the §1 tables", 75 rows = 71 here + 4 in SBDEV-3154.
   §8.6's rewritten wording (85 rows, *"every ungated state-changing MVC endpoint on develop"*) is **not**
   satisfied and is not claimed to be. The ten state-changing GETs are **SBDEV-3155**.
2. **Merge both PRs.** Done, verified above.
3. **File the method-security enablement ticket** — **SBDEV-3156**.
4. Dashboard AC-2′ — details requested; see §9.28.2, which changes the answer.

#### 9.28.1 Tickets spun out of this tranche

| ticket | what |
|---|---|
| **SBDEV-3154** | the 4 `AdminActionController` operator-console routes — need 2 new constants + `V2.2.22` |
| **SBDEV-3155** | the 10 state-changing GETs, **and** the fact that `SurfaceInventoryContextTest` cannot see them by construction, so repeating the audit will never surface them |
| **SBDEV-3156** | `@EnableMethodSecurity` has `securedEnabled` + `jsr250Enabled` ON with only `prePostEnabled` pinned |

#### 9.28.2 🔴 The Dashboard AC-2′ "failure" is NOT a live break — `WEB_UI_VIEW_ORDER_DETAIL_MONITOR` gates NOTHING

§9.7.1 flagged it, and §9.25.2 and the db-evidence doc both carried it forward as *"one genuine AC-2′ failure,
5 live users"*. **Re-checked on `origin/develop` before handing it to Nam, and that framing is wrong.**

The population is real: `WEB_UI_VIEW_ORDER_MONITOR` 46 users, `WEB_UI_VIEW_ORDER_DETAIL_MONITOR` 41, so 6 hold
the Dashboard and not the detail function — `Z-mariaortiz(archived)`, `daniilandriyenko`, `estellavasquez`,
`josiemarks`, `jovanyaguilera`, `markchilcote` (5 live). Its roles are `super-admin` + five numeric.

**But nothing consults it.** Measured across both repos:

- `src/main` — **zero `@RequiresFunction`** uses it. Its only occurrences are the constant declaration
  (`WmsConstants:422`), a comment (`:409`), seed rows in `V2.2.00`/`V2.2.19`, and one
  `accessService.addFunctionToRole` call in **`UtilRestController:408`** — which is annotated `@Service`,
  **not** `@RestController`, so its `@RequestMapping` methods do not route and that path never executes.
- `wms2-web-ui` — two hits, neither a gate: a name in `test/support/webFunctionConstants.js`, and a **comment**
  in `appMenuList.js:116` explaining why the Parcel Picking Report deliberately did **not** reuse it.

⇒ **Nobody is 403'd today, because no gate consults this function.** It is a *latent* trap, not a live defect:
the day someone gates a Dashboard detail view on it, 5 live users break. That is worth a note on whichever
ticket eventually gates that screen — it is **not** an incident, and it should not have been carried three
sections as one.

**The correction generalises.** §9.7.1's "denied population" arithmetic answers *"who would be denied IF this
function were enforced"*. It says nothing about whether it **is** enforced. Both questions matter and they are
different; conflating them is [[advertised-capability-is-not-exploitable-capability]] pointed at a gate rather
than at an endpoint. **Check enforcement before reporting a population as a break.**

---

### 9.29 SBDEV-3017 SCOPE CLOSED 2026-08-28 — Class A split to SBDEV-3157, and the accounting

⚠️ **Scope closed, ticket NOT set to `Closed`.** The ClickUp status ladder in this workspace tracks
deployment — `on dev` → `on qa` → `ready for deployment` → `on prod` → `Closed`. Tranche 1 is on
**dev** only, so the ticket stays at `on dev` and rides the ladder; setting `Closed` now would drop
it out of promotion tracking before it reaches production. Nothing is left to *build* on it.

**Delivered by this ticket:** slice A's enforcement point (PR #187), slice C (#189), the `UserFunction` SDR
write withdrawal (#209), R1–R8, and tranche 1's 71 MVC gates (#232 + web-ui #95). Measured effect on the
deployed surface: **gated mutating 291 → 355, ungated mutating 122 → 58.**

Slice A's most durable output was not a gate but a **retraction**: it disproved this ticket's own premise
that SDR is "structurally ungatable". It is *reachable*; only `WebMvcConfigurer#addInterceptors` fails to
reach it. Six `src/main` javadocs and the web-ui route guard carried the wrong claim and were corrected.

#### 9.29.1 🔴 The founding complaint is STILL TRUE — and that is why Class A gets its own ticket

*"A user denied the SKU Data menu item still gets data from `curl /v3/itemdata`."* Measured on
`origin/develop` @ `1f5f8697`:

| | |
|---|---|
| exported `@RepositoryRestResource` repositories | **62** |
| `@RestResource` searches | **375** |
| class-level `exported = false` | **0** |
| domain types with write verbs withdrawn | **7** — all authorization-chain (SBDEV-3012/3013/3079) |
| ⇒ repositories retaining live SDR writes | **55 of 62** |
| `@RequiresFunction` under `repo/` | **0** (the one grep hit is a comment saying it does not reach) |
| test proving 403 on a denied `/search/…` | **none** |

That last row **is this ticket's own Class A acceptance criterion**, unmet. It is carried into **SBDEV-3157**
verbatim as its AC-2 rather than being quietly dropped in the close. **No business entity has ever been gated
on the SDR axis** — the 7 withdrawals exist to stop privilege escalation, not to gate data.

#### 9.29.2 Where the scope went

| ticket | scope |
|---|---|
| **SBDEV-3157** (High) | **Class A — SDR.** The unfinished half |
| **SBDEV-3142** (High) | the **16** report/monitor POST-as-query reads — enumerated and ready |
| **SBDEV-3158** (High) | the other **~90** ungated `/v3` MVC reads (106 total) |
| **SBDEV-3155** (High) | the 10 state-changing GETs + the tool's structural blindness to them |
| **SBDEV-3154** | the 4 `AdminActionController` routes needing 2 constants + `V2.2.22` |
| **SBDEV-3156** | `@EnableMethodSecurity` — `securedEnabled`/`jsr250Enabled` on, only `prePostEnabled` pinned |
| SBDEV-3124 · 3144 · 3116 · 3119 | `/rest/**` · token credentials in the query string · Keycloak mapping · the one real production defect (merged `be3411ca`) |

The 58 remaining ungated *mutating* handlers reconcile exactly against that list: 16 on `/rest/**`, the
AdminAction routes, SBDEV-3142's POST-as-query reads, and the 3 OMS carve-outs that are deliberately open.
**Nothing is unaccounted for.**

⚠️ Both the 58 and the 106 are **lower bounds** — `SurfaceInventoryContextTest` over-reports gating wherever a
class-level annotation meets an inherited `AdminController` handler, and its GET heuristic misses SBDEV-3155's
ten. Recorded on both child tickets.

#### 9.29.3 What this ticket cost, and the one thing worth carrying forward

Three tranches, four review lanes across three rounds, seven children. The single most transferable lesson is
**§9.27.3**: three consecutive review rounds each found that my fix fenced *one* gate mechanism and missed its
siblings — `@RequiresFunction`, then `@PreAuthorize`, then `@Secured`/JSR-250 and the `SecurityFilterChain`.
The gates themselves were confirmed correct in every round; it was the rails that took three passes.

**Before calling any guard complete, enumerate every way the OUTCOME can be produced — not every way the
defect you just saw was spelled — and never assert a closed set in a comment.** A confident count is a
load-bearing claim and needs the same evidence as any other. See
[[a-guard-fences-the-mechanism-you-aimed-at]].


#### 9.29.4 ⚠️ CORRECTION — the SBDEV-3142 widening was retracted the same day

I widened SBDEV-3142 from 16 to 106 ungated reads, and then **Nam revised the ticket policy** and my own
widening failed it. `search-then-widen` now requires **both** gates:

| gate | SBDEV-3142 | |
|---|---|---|
| sibling earlier than `on dev` | `Open` | ✅ passes |
| **the ADDED scope tiers under T3** | ~90 endpoints of authorization work, multi-file | ❌ **fails** |

Retracted; the remainder is **SBDEV-3158**. The measurement was sound — only the filing decision was wrong.

**Tier the ADDITION on its own**, never the combined ticket and never the host's existing tier. A T3 addition
is a second project wearing the first one's number, and it silently re-tiers the host: someone picking up an
enumerated 16-endpoint job would have inherited an open-ended one with nobody deciding that.

A second reason the split is right **regardless of the policy**, and the one that should have caught it
without a rule: SBDEV-3142's 16 carry a complete enumeration, per-endpoint dataset analysis and a live-probe
AC. The ~90 carry none of that. Folding them together hides **finished analysis behind unstarted analysis** —
which is the same failure this plan's own §9 exists to undo.

Policy text: `.claude/skills/wms-triage/SKILL.md` → *Ticket policy*. Summary pointer in `CLAUDE.md` updated to
match; memory [[consolidate-tickets-dont-file-one-per-finding]] carries the two gates.

---

### 9.30 🔴 §9.28's OMS enumeration was derived from a STALE checkout — corrected 2026-08-28

While working SBDEV-3157 a review lane caught me grepping `v2/oms-laravel-api`'s **working checkout**
instead of `origin/develop`. That checkout is **838 commits behind** (`76217f75`, an ancestor of
`7f7b3719`). The same stale tree produced this plan's OMS verification.

| | this plan said | `origin/develop` |
|---|---|---|
| OMS `/v3` paths | **8** — 3 creates, 4 SDR reads, 1 SDR search | **10** |
| missed | — | `v3/client/search/findByClNr` and **`v3/client/{id}`** |

`v3/client/{id}` is the consequential one: `config/wms.php:104` maps `client_update` to it and
`WmsApiService.php:3281` calls it with **`PATCH`**, its own comment saying *"a Spring Data REST entity
resource takes one JSON object."* **OMS writes over SDR.**

**The conclusion survives, and was verified rather than assumed.** Both missed paths are SDR, served by
`RepositoryEntityController` / `RepositorySearchController`. Tranche 1 annotated **MVC controller methods
only**, and `ClientController` declares no `{id}` mapping and no `/search/` mapping. **No gate this tranche
added intercepts either path.** What is retracted is the *enumeration offered as evidence* — §0.C's
carve-out should be read as "the three controller creates", not as a complete picture of OMS's `/v3` usage.

#### 9.30.1 The rule, and why it slipped

**Derive cross-repo claims from `origin/develop` after a fetch, never from a working checkout.** Every
sub-repo here lags: `wms2-api` 9, `wms2-web-ui` 19, `wms2-mobile-ui` 26, `v1/wms-api` 8,
`oms-laravel-api` **838**.

`wms-triage`'s probe question 1 already says *"do not trust a local checkout"*. I applied it to `wms2-api`
and `wms2-web-ui` — both fetched, both read at `origin/develop` — and skipped it for the third repo **in
the same session**. Consistency across repos is the part that failed, not knowledge of the rule.

**The tell:** a line-number disagreement between two readings of one file (`:86` vs `:104`). If two people
cite different lines for one symbol, one of them is on a different commit — check the ref before arguing.

**Second-order, and the worse half:** I used the stale reading to **reject a correct review finding**, with
a five-row evidence table in which every row was true of the stale tree and false of the real one. A
rejection needs *more* provenance discipline than a claim, because it stops someone else from looking.
That is now twice in this ticket family — the `@PreAuthorize` residual (§9.27.1) was the first.
See [[derive-cross-repo-claims-from-origin-develop]].
