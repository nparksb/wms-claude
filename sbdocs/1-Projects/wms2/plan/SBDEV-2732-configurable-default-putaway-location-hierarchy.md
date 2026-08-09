---
title: "SBDEV-2732 — Configurable System & Merchant Default Putaway Location Hierarchy (v2)"
ticket: "SBDEV-2732"
ticket_url: "https://app.clickup.com/t/868kgfzt9"
type: feature
priority: high
status: draft
project: [wms2]
version: v2
db_verified: true
depends_on:
  # Pinned 2026-08-06. Re-verify every claim about these tickets if a sha moves — this plan
  # previously asserted four things about SBDEV-2731 that were true of its PLAN and false of its CODE.
  - {ticket: SBDEV-2731, sha: 6bc709a}    # MERGED 2026-08-07 — PR #133 api @ 6bc709a, #39 ui @ 4ce39a1.
                                          # Prerequisite 0 SATISFIED. Claims about it re-verified same day.
  - {ticket: SBDEV-2854, sha: 68274b0}    # MERGED 2026-08-07 (PR #132). Its V2.2.10 is on develop, but
                                          # must still be APPLIED per tenant BEFORE this plan's V2.2.11.
  - {ticket: SBDEV-2821, sha: UNMERGED}   # ADDED 2026-08-08 (Q15 -> (A)). NEW dependency, and it REVERSES
                                          # the order §8.4 previously stated. Under Q12 -> (iv-b) step 15
                                          # diverts pick-face destinations to the putaway lane; 2821 is
                                          # what makes them OFFERABLE at putaway. Ship 2821 first, then
                                          # extend its candidate surfacing to all four tiers (step 17a).
db_verified_tenants:
  fresh_seed: [wh01_hydra_v2t]
  migrated:   [wh01_hydra_v2, wsl-wineco-uat, wms2-hydra]   # a fresh-seed-only sample cannot exhibit
                                                            # migrated-tenant hazards — see §3.4c P2.7(c)
requester: "David Oppenheim"
created: 2026-07-31
updated: 2026-08-08
related:
  - SBDEV-1938
  - SBDEV-2642
  - SBDEV-2643
  - SBDEV-2731
  - SBDEV-2217
  - SBDEV-2037
  - SBDEV-2102
  - SBDEV-2232
tags:
  - plan
---

# SBDEV-2732 — Configurable System & Merchant Default Putaway Location Hierarchy (v2)

**Ticket:** [SBDEV-2732](https://app.clickup.com/t/868kgfzt9)
**Project:** wms2 | **Version:** v2 | **Type:** feature
**Priority:** high
**Status:** draft (pending approval — no source file under `v2/wms2-api/` or `v2/wms2-web-ui/` has been touched)
**Date:** 2026-07-31 · **Updated:** 2026-08-08 · **Design changelog:** §12
**Ships AFTER [SBDEV-2821](https://app.clickup.com/t/868km8j9z)** — order reversed 2026-08-08 by Q15 → (A); see §8.4

> ## 🔔 REVISION 2026-08-04 — SBDEV-2796 / Q5 ANSWERED: option (c). READ BEFORE ANY OTHER SECTION.
>
> The B/A answered [SBDEV-2796](https://app.clickup.com/t/868kk4rmv) (= SBDEV-2731 Q5 = this plan's §10.4
> **Q10**) with **(c): "It is valid and bounds are advisory for receiving."** Not the carried-over
> recommendation (d). Direct placement into a pick face is legitimate, `FixLocationAssignment.upperbound`
> is **not** enforced at receive time, and the over-bound state is accepted and documented.
>
> **(c) is the answer that maximises this plan's scope** — so on 2026-08-04 the author elected to **DEFER
> the tier-1 path** rather than absorb it. See the four decisions below.
>
> ---
>
> ### DECISIONS TAKEN 2026-08-04 (author) — these define the implementable scope
>
> **D15 — tier-1 direct placement is DEFERRED to a follow-up ticket.** ⚠ **RESTATED 2026-08-08: it is not merely deferred, it is CANCELLED.** SBDEV-2821 adopted **option (iii) — route at putaway**, so tier-1 pick-face destinations are *never* directly placed by anyone. The guarantee D15 wanted still holds; what changes is the enforcement point, which moves from refusing the configuration to a runtime rule in receiving (see the conflict box under §3.4c P2.7(c)). Original text follows. This plan ships the resolver (all
> four tiers' *resolution*), the merchant/warehouse config surface, the display endpoint, write-time
> validation, the audit table and the backfill — plus direct placement **for tiers 2/3 only**. Placing a
> receipt onto a **pick face** via a tier-1 SKU override is out of scope here.
>
> *What the deferral removes from this plan, all of it previously blocking:* 2731's **Fix B** (flowbin
> classification + resident-UL resolution), **C2b**, **Q1**, **Q4**, **F1**, **F4**, **F5**, and **Q11**
> (replenishment against a permanently over-bound bin — still needs a B/A answer). **All of it now owned by
> [SBDEV-2821](https://app.clickup.com/t/868km8j9z)** (filed 2026-08-04). **Q1/Q4 here mean
> *2731's* Q1/Q4, not this plan's own §10.4 Q1/Q4, which remain open and in scope.** None of those
> can arise without pick-face placement: no repointing ⇒ no C2b; no over-bound bin ⇒ no Q11.
> **Consequence: this plan no longer waits on anything unowned.**
>
> [!done] **Flyway version RENUMBERED to `V2.2.11` (2026-08-06) — `V2.2.10` went to SBDEV-2854**
> **SBDEV-2854** occupies `V2.2.10__seed_replenish_allow_non_flowbin_destinations_sysprop.sql` on branch
> `bugfix/SBDEV-2854-replenish-non-flowbin-destination`, shipped in **PR #132 — open and pushed**. It
> originally took `V2.2.11` and left `V2.2.10` reserved for this plan, but that gap is **unsafe**: there
> is no `outOfOrder(true)` and no `validateOnMigrate(false)` anywhere, and `StartupFlywayMigrator` catches
> `FlywayException`, logs and **continues** — so a tenant that applied the higher number before this
> plan's lower one landed would boot normally and silently stop receiving that and every later migration
> until someone read the log or ran `flyway repair`. SBDEV-2854 is an urgent client fix and deploys
> first, so it took the contiguous number; its own §5.1 **H3** records the consequence directly —
> *"SBDEV-2732 must now take a later version"*.
> **This plan now takes `V2.2.11`, renumbered throughout on 2026-08-06.** Flyway head on `origin/develop`
> is still `V2.2.09`; `V2.2.10` is held by an open PR and is therefore invisible to
> `ls src/main/resources/db/migration/` on `develop`. **Re-sweep every remote branch for the next free
> version immediately before the PR** — that sweep is what caught this collision, and D16 below still
> mandates it.
>
> **D16 — one migration, `V2.2.11`.** §2.9 originally reserved *two* versions and wrote both as `V2.2.08`;
> §5.2 had already removed that split. Resolved as **one** file,
> `V2.2.11__putaway_destination_hierarchy.sql`. Renumbered **twice**: `V2.2.08` → `V2.2.10` on
> 2026-08-04 because `V2.2.08` (SBDEV-2801) and `V2.2.09` (SBDEV-2778) both merged that day, then
> `V2.2.10` → `V2.2.11` on 2026-08-06 when SBDEV-2854 took `V2.2.10` (banner above). **Re-sweep every remote branch for the
> next free version immediately before the PR** — unmerged branches hold invisible versions, which is
> exactly how this collision happened.
>
> **D17 — the §6 receipt-correction guard STAYS, and correction is documented as unavailable for
> directly-placed receipts.** Not relaxed. Relaxing it is only safe once C2b is fixed, and C2b is now
> deferred with the tier-1 path — so the guard is the option that cannot nirvana a location. Note this
> decision is required **even with tier 1 deferred**, because D13 rule (d) lets tiers 2/3 target staging
> lanes whose areas are not `useforgoodsin`.
>
> **D18 — the plan goes through a review lane before approval.** Status stays `draft`. The 2026-08-04
> revisions changed validator predicate semantics (P2.5, P2.7(c)) and have had no independent pass; the
> previous Critic pass returned 12 findings including a CRITICAL one. Review → address → approve →
> `wms-tdd-gate` → implement.
>
> ---
>
> **Lifted by (c).** The tier-1 direct-placement *block* is gone — but under **D15** the tier-1 path is
> deferred anyway, so this matters only to the follow-up ticket. (The block was written as "blocks Phase
> 1b"; that split was removed in §5.2 and direct placement sits in **Phase 1-API**.)
>
> **Still corrected here, because it is a live defect either way:** **P2.5** and **P2.7(c)** rejected
> pick-face / fix-assigned destinations *"absolutely at all three scopes"* while §3.4c exempted tier 1 from
> only (a), (b) and (d) — **not (c)**. A flowbin *is* a pick face, so the ICE PACK configuration could not
> have been saved at **any** scope, which made (c) unimplementable and made this plan's own predicted
> "silent ~12× over-bound bin" unreachable. Both are revised below (P2.5 scope-dependent; tier 1 exempt
> from P2.7(c)) so the follow-up ticket inherits a validator that admits the configuration (c) authorises.
>
> **Hard prerequisite, unchanged and NOT yet met:** **D12** requires SBDEV-2731 PR1 merged to `develop`
> first. As of 2026-08-04 that work is committed in both repos but **never pushed and has no PR**, and this
> plan's resolver consumes the neutral message key `unitloadTypeNotPermittedOnLocation` that PR1
> introduces — so merging this plan first would reference a message that does not exist. Order is fixed:
> 2731 API → 2731 UI → this plan. Do **not** branch this plan off the 2731 branch (stacked-PR orphan trap).

**Parent:** SBDEV-1938 "WMSv2 — Receive to Different Location Other then Putaway" (Open)
**Absorbs:** SBDEV-2731 (per D8/D9 — its slice is **Phase 1**, separately mergeable). **Unblocks:** SBDEV-2643.
**db_verified:** true — evidence from `wh01_hydra_v2` (v1→v2 migrated copy) and `wh01_hydra_v2t` (fresh-seeded copy), MCPs `wms2-hydra-dev2` / `wms2-hydra-v2t`.

> **Phases — SUPERSEDED, see §5.2 and §8.1.** This paragraph described the old **four-merge** `1a`/`1b` split; §5.2 collapsed it to **two merges — Phase 1-API then Phase 2-UI** — and D16 collapsed the two migrations into one `V2.2.11`. **Both of its gating claims are also false:** `V2.2.11` *does* add a column an entity maps (`client.defaultputawaylocation_id`), and `ddl-auto` is **`none`**, not `validate` (`application.properties:70`; `:69` has `validate` commented out) — so nothing validates the schema at startup and there is no "exempt from the operator gate" half. Read **§8.1** for the real merge order and gate. *(Kept only so a reader who remembers the 1a/1b vocabulary knows where it went; every `1a`/`1b` label still surviving in §0 and §4 is stale — treat every API row as Phase 1-API.)*
>
> **Read §5.2 O1–O5 before starting any phase.** Three things whose phase is counter-intuitive: the audit *writer* (O1 — the table ships in 1a so the backfill pre-image has somewhere to land, but the entity, service and audit rows are 1b), `onClient` in the event handler (O2 — 1b; written in 1a it will not compile), and stop-seeding the lane id (O3 — 1a, and it must travel in the **same commit** as `V2.2.11`).

---

## 0. Affected Sites

Enumerated against disk on 2026-07-31 (not from memory). Every **in-scope** row is visited by a §3 sub-section or a §5 phase step; every **out-of-scope** row carries a one-line rationale. **Phase** column per D9: `1a` = API + `V2.2.11`, `1b` = API + `V2.2.11`, `2` = web UI.

### 0.1 API — `v2/wms2-api/src/main/java/net/aim_ai/wms/`

| # | File:line | Construct | Verdict | Phase | §3 / rationale |
|---|---|---|---|---|---|
| 1 | `service/ReceivingService.java:454-457` | `carrier == null ? findById(itemdata.getPutawaylocationId()) : null` | **in — replace** | 1a | §3.7 |
| 2 | `service/ReceivingService.java:491-495` | placement fork; carrier branch never consults the destination (**SBDEV-2731 root cause**) | **in — rework** | 1a | §3.7 |
| 3 | `service/ReceivingService.java:601-612` | name-equality check against `PutAwayLane` for inbound-pallet assign | **in — audit, must not break when destination ≠ lane** | 1a | §3.7.3 |
| 4 | `service/ReceivingService.java:634-637` | unassign inbound pallet → `findByName(PutAwayLane)` | **in — audit, unchanged** | 1a | §3.7.3 |
| 5 | `service/mobile/MobilePutAwayService.java:113-117` | `if (!locationArea.getUseforgoodsin() && !storageLocation.equals(Clearing)) throw BusinessException("unitloadNotInInboundArea")` — the **first** guard in the method | **in — audit; THIS is the exception a storage-area direct placement actually hits** | 1b | §3.7.4, §6 |
| 5a | `service/mobile/MobilePutAwayService.java:121-128` | requires the UL to be on `PutAwayLane`, else `unitLoadNotInPutAwayLane` — runs **after** row 5, so a unit load sitting in a storage area never reaches it | **in — audit, unchanged; NOT the exception a direct placement produces** | 1b | §3.7.4 |
| 6 | `service/mobile/MobilePutAwayService.java:190-206` | `storePalletBackOnPutawayLane` (SBDEV-2102 fix) | **in — audit, must not regress** | 1b | §3.7.4 |
| 7 | `service/mobile/MobileMoveUnitloadService.java:362-366` | creates inbound pallet at putaway lane by name | **in — audit, unchanged** | 1b | §3.7.4 |
| 8 | `controller/rest/SkuRestController.java:85-88, 144-146` | create path seeds `putawaylocation_id` = PutAwayLane id | **in — stop seeding; same commit as `V2.2.11`** | **1a** | §3.2, **O3** |
| 9 | `controller/rest/SkuRestController.java:198-201, 257-259` | update path, same | **in — stop seeding; same commit as `V2.2.11`** | **1a** | §3.2, **O3** |
| 10 | `service/SkuBatchCreateUpdateService.java:36, 53` | `itemData.setPutawaylocationId(defaultPutawayLocationId)` | **in — parameter removed; same commit as `V2.2.11`** | **1a** | §3.2, **O3** |
| 11 | `controller/FileImportController.java:355-359, 383` | CSV import seeds the lane id; `:355` guard is the SBDEV-2037 fix | **in — stop seeding, keep an equivalent guard; same commit as `V2.2.11`** | **1a** | §3.2, **O3** |
| 12 | `model/Itemdata.java:49-51` | `@NotNull @Column(name="putawaylocation_id") private Long putawaylocationId` | **in — drop `@NotNull`; same commit as `V2.2.11`** | 1a | §3.2 |
| 13 | `service/ItemdataService.java:62-76` | `setPutAwayLocation` — dead (0 production callers) but has the **correct** targeted 2-key `@CacheEvict` | **in — promote to the single validated writer** | 1a | §3.5 |
| 13a | `service/ItemdataService.java:47-50` | `getById` is **`@Cacheable`**, and `ItemDataController:89-90` mutates the returned instance **in place** | **in — writers MUST use `itemdataRepository.findById`, never this** | 1a | §3.5 |
| 14 | `controller/ItemDataController.java:80-95` | `@CacheEvict(allEntries=true)` + `@GetMapping` that mutates + **raw save, zero validation**, and **no `@PreAuthorize` today** | **in — route through §3.5, fix the evict; adding authz is a back-compat change** | 1a | §3.5, §3.12, §6 |
| 15 | `service/UnitloadBusinessService.java:180-193` | constraint allow-list + raw-ID `BusinessException` at `:191` — **also serves 21 non-receiving call sites** | **in — extract predicate; `:191` gets the NEUTRAL key `unitloadTypeNotPermittedOnLocation`, the putaway-specific key is thrown by the resolver** | 1a | §3.4b, §3.6.1 |
| 16 | `repo/jpa/LocationConstraintRepository.java:16-17` | only `findByStoragelocationtypeId` | **in — reused as-is, no new method** | 1a | §3.4b (rationale below) |
| 17 | `service/LocationConstraintService.java:27-39` | only `createEntity` | **in — home of the new predicate** | 1a | §3.4b |
| 18 | `model/Client.java:10-22` | tenant-PU entity carrying per-facility config | **in — new nullable FK field** | 1b | §3.3 |
| 19 | `repo/jpa/SyspropRepository.java:35-36` | `findBySyskeyAndClientIdAndWorkstation` → `Optional<Sysprop>`, uniquely keyed on the real constraint `(client_id, syskey, workstation)` | **in — THE tier-3 read path** | 1a | §3.4a |
| 19a | `repo/jpa/SyspropRepository.java:46-48` | `findSysvalueByClientIdAndSyskey` — **no `workstation` predicate**; `order by client_id` is a no-op when `client_id` is fixed ⇒ arbitrary row | **in — deliberately NOT used; landmine A6** | 1a | §3.4a |
| 20 | `service/SyspropService.java:164-234` | `getStringDefault` 4-tier cascade, **INSERTs on total miss at `:234`** | **in — deliberately NOT used** | 1a | §3.4a, §9 A4 |
| 21 | `controller/rest/AdviceRestController.java:572` `createHubAndSpoke` | `:684` `position.setItemdataId(null)`, `:685` sets `unitloadtypeId` | **in — null-SKU contract, reachable from the DISPLAY endpoint only** | 1a | §3.1.4 |
| 21a | `service/ReceivingService.java:356-357` | `itemdataRepository.findById(adviceposition.getItemdataId())` — `findById(null)` raises `InvalidDataAccessApiUsageException` **96 lines before** the resolver | **out — pre-existing hub-and-spoke *receive* gap, NOT fixed here** | — | §10 Q4 |
| 22 | `controller/rest/AdviceRestController.java:139` `create` (REGULAR/RETURN) | `:396` sets `unitloadtypeId` | **in — optional early-validate hook** | 1b | §3.9 |
| 23 | `controller/rest/AdviceRestController.java:453` `createTransfer` | `:527` sets `unitloadtypeId` | **in — same** | 1b | §3.9 |
| 24 | `controller/FileImportController.java:489` | `position.setUnitloadtypeId(...)` (inbound-BOL import) | **in — same** | 1b | §3.9 |
| 25 | `service/AdviceService.java:145` `acceptHubAndSpokeAdvice` | materialises `Unitload` **without** `receiveGoods` | **out** — no `Itemdata`, no receipt destination decision; auto-accept plumbing. §10 Q4. |
| 26 | `controller/ReceivingController.java:285-300` | catch ladder; `:298-300` swallows `RuntimeException` into "contact support" | **in — resolver failures must be `BusinessException`** | 1a | §3.6.2 |
| 26a | `controller/**` (whole tree) | **ZERO `@Transactional`** — the only 3 matches are comments, two of which state the controller has no transaction | **in — a `MANDATORY` call from a controller throws `IllegalTransactionStateException`, a bare `RuntimeException`** | 1a | §3.1.5, §3.8 |
| 27 | `controller/ReceivingController.java:314` | hard-coded `{"PutAwayLane","InboundWorkstation","EmptyPallets"}` raw literals | **in — replace literals with constants** | 1a | §3.7.3 |
| 28 | `model/ReceivingDtoView.java:47, 173` | `defaultputawaylocationname` — already projected by `receiving_dto_view` (`V2.2.00__base_v2_schema.sql:4663, 4676`) | **in — read-only reuse, view NOT changed** | 1a | §3.8 (D9) |
| 29 | `model/ReceivedDtoView.java` | sibling projection for `/reports/receiving-report` | **out** — historical report of what was received; the *destination actually used* is already in `UnitloadRecord`. No new column. |
| 29a | `service/GoodsReceiptPositionService.java:151-152` | goods-in **area guard** immediately before `deletePosition`, reached from `delete` (`:98`) and `adjust` (`:124`); `deletePosition` then calls `sendStockUnitToNirvana` (`:165`) and, when nothing remains, `sendToNirvana` (`:171`) | **in — N-22.** Cannot fire today because receiving's destination is always the goods-in lane; **direct placement makes it throw**, so `delete`/`adjust` break for exactly the receipts this feature redirects, and the guard is the only thing between a correction and nirvana-ing a UL on a live storage face | 1 | §6, M21 |
| 29b | `controller/GoodsReceiptPositionController.java` | exposes `delete` and `adjust` | **in — N-22**, same cause | 1 | §6, M21 |
| 30 | `config/CacheConfig.java:31-69` | `sysprops` 2 min, `clients` 5 min, `locations` 5 min, `itemdata` 5 min **× two profiles** | **in — eviction + freshness contract, no file change** | 1a/1b | §3.10 |
| 31 | `RestConfiguration.java:34-48, 55-60` | `RepositoryDetectionStrategies.ANNOTATED`; only bean-validation validators ⇒ **`POST`, `PATCH` and `DELETE`** `/v3/{itemdata,client,sysprop}` write unvalidated | **in — the D7 write hole; `POST` matters as much as `PATCH`** | 1a (+`onClient` 1b) | §3.9 (O2) |
| 31a | `controller/SystemPropertyController.java:47-90` `POST /v3/systemProperty/create` | direct `syspropRepository.save()` at `:77` — **Spring Data REST publishes no event**, so the §3.9 handler never fires and the D7 guard is bypassed entirely | **in — must reject `syskey == DEFAULT_PUTAWAY_LOCATION`** | 1a | §3.9.1 |
| 31b | `controller/SystemPropertyController.java:93-120` `POST /v3/systemProperty/updateValue` | direct `syspropRepository.save()` at `:107`, reached via `findBySyskey(key).get(0)` — the client-blind shape of landmine A3, on a write | **in — must reject `syskey == DEFAULT_PUTAWAY_LOCATION`** | 1a | §3.9.1 |
| 31c | `DELETE /v3/sysprop/{id}` (SDR-exported, called by `store/admin/configuration.js:125-147`, axios at `:127`) | live "delete" button on the Operation Options dialog; the plan defines no delete handler, so the row can be removed unvalidated and unaudited | **in — accepted and audited, see D12** | 1a | §3.9.1 |
| 32 | `service/WmsConstants.java:771` | `STORAGE_LOCATION_PUTAWAY_LANE = "PutAwayLane"` | **in — stays, becomes the tier-4 fallback only** | 1a | §3.4b |
| 32a | `service/WmsConstants.java:731, 1163` | `UNIT_LOAD_TYPE_BOX = "Case"`; `SystemProperty.WORKSTATION_DEFAULT = "DEFAULT"` (nested class `SystemProperty`) | **in — reused, not changed** | 1a | §3.4a, §3.4c |
| 33 | `service/mobile/MobilePutAwayService.java:212-283` `calculatePutAwayList` | classification via `LocationType.sltname`; area predicate | **in — audit only, no change** | 1b | §3.7.4 |
| 34 | `repo/jpa/LocationRepository.java:104-120` `getStorageLocationsForPutAwayItemData` / `...ForStockUnitItemData` | native predicate `location_area.useforstorage='true'` — **can never return `PutAwayLane`** (L-PRE.10) | **out as a selector** — must NOT back the Phase-2 picker or the validator. §3.4c. |
| 34a | `repo/jpa/LocationRepository.java:21-22` | `findByName` → `Optional<Location>`, **no `client_id` filter**; `location.name` has **no unique constraint** (`V2.2.00…sql:959-979`, `name varchar(255) NOT NULL`) | **in — defines what tier 4 resolves; the backfill predicate MUST match it exactly** | 1a | §5.1 |
| 34b | `repo/jpa/LocationRepository.java:52` `findByIdForUpdate` | taken at `UnitloadBusinessService.java:150` + `entityManager.refresh` **before** the Unitload write at `:293-294` — Location→UL, **inverting** the SBDEV-2232 SU→UL→Location order | **in — accepted risk with a named detector; blast radius grows from "an inbound lane" to "any live storage/pick location"** | 1b | §7.6 #8, §8.2 |
| 35 | `controller/rest/UtilRestController.java:760` | provisioning/util lane lookup | **out** — provisioning tooling, no receipt path. |
| 36 | `service/ReportService.java:182` | `view.getDefaultputawaylocationname()` | **out** — read-only reporting column, unchanged semantics. |
| 38 | `repo/jpa/LocationRepository.java:37-47` `getAvailableStagingLanes` | **`@RestResource`-exported** JPQL: `WHERE l.staginglane = true AND NOT EXISTS (CustomerorderBatch ob WHERE ob.staginglaneId = l.id AND ob.id != :batchId AND ob.state < :state)` — **verified `origin/develop` 2026-08-04: there is NO stock or unit-load predicate.** A staging lane holding received inventory is still offered to the next club batch. | **in — audit, unchanged; see §6 N-23** | 1-API | §6 N-23 |
| 39 | `service/CustomerorderBatchService.java:895, 911` + `controller/ClubLineController.java:307` | consume row 38 and assign the chosen lane to a batch; `BillofladingService:732/:829` and `CustomerorderBatchService:382/:402/:713` clear it; truck loading ships what sits on the lane | **in — audit, unchanged; the consumer that makes a club-lane destination unsafe** | 1-API | §6 N-23 |
| 40 | `repo/jpa/StockunitRepository.java:198, 216` | `AND loc.staginglane IS NOT TRUE AND loc.transferlane IS NOT TRUE` — **unconditional, no sysprop gate** (verified 2026-08-04); sysprop-gated siblings at `StockunitRepository:180/:233`, `ItemdataRepository:78/:119/:154`, `UnitloadRepository:148`, `FixLocationAssignmentRepository:64/:91` (SBDEV-1666) | **in — audit, unchanged; defines what a lane destination costs** | 1-API | §6 N-23 |
| 37 | `service/BoxtypeService.java:87` | `details.put("putawayLocation", ...)` | **out** — display detail map for box types, unrelated to precedence. |

### 0.1b NEW constructs this plan introduces (so §0 stays a complete inventory)

| # | New construct | Why it must exist | Phase | § |
|---|---|---|---|---|
| N1 | `service/PutawayDestinationResolver.java` | the one shared 4-tier resolver; `Propagation.MANDATORY` | 1a | §3.1 |
| N2 | `service/PutawayDestinationQueryService.java` | `readOnly = true` tenant-tx facade so **non-transactional controllers can reach the resolver at all** | 1a | §3.1.5, §3.8 |
| N3 | `LocationConstraintService.isUnitloadTypePermitted` | predicate P1, single source of truth incl. the empty-list fail-open | 1a | §3.4b |
| N4 | `service/PutawayDestinationValidator.java` | predicate P2 per scope + the D11 incompatible-SKU count | 1a | §3.4c |
| N5 | `service/PutawayConfigService.java` | validated + audited writers, cache eviction, `validateOnly` / `auditAndEvict` for the event handler, and **the authorization boundary** (§3.12) | 1a (SKU + sysprop) / 1b (merchant) | §3.5 |
| N6 | `service/PutawayResolutionMetrics.java` | 4 counters; the only detector for pre-mortems P2 and P3 | 1a | §3.13 |
| N7 | `config/PutawayConfigRepositoryEventHandler.java` | **⚠ PHASE COLUMN STALE — see §5.2 O2.** The `1a`/`1b` split was removed; there is only **Phase 1-API**, so `onItemdata`, `onSysprop` **and** `onClient` all ship together in the single API commit alongside `client.defaultputawaylocation_id`. The old "written in 1a it will not compile" hazard no longer exists. | closes the SDR write hole for `PATCH`/`POST`/`DELETE` on the three exported repositories — all three handlers ship together in the single API commit *(superseded 1a/1b wording removed 2026-08-06: a tail-read or grep was landing on it and getting the opposite instruction)* | 1-API | §3.9 (**O2**) |
| N7a | `PutawayConfigValidationException extends RuntimeException` + an `@ExceptionHandler` in `RestExceptionHandler` | the handler must throw **unchecked** or SDR wraps it and the client gets a 500 instead of 422 | 1a | §3.9.3 |
| N8 | `GET /receiving/getPutawayDestination/{advicePositionId}` | the entire 2731 display contract + `compatible` | 1a | §3.8 |
| N9 | `GET /client/{id}/effectivePutawayDestination` | the merchant screen's **Inherited** value — §3.11.3 is unrenderable without it | 1b | §3.8 |
| N10 | `GET /putawayConfig/preview?scope=…&locationId=…` | D11's incompatible-SKU count — the config-health signal D3 asked for and D6 dropped | 1a | §3.4c, §3.5a |
| N11 | `model/PutawayConfigAudit.java` + repository + `service/PutawayConfigAuditService.java` | **⚠ PHASE COLUMN STALE — see §5.2 O1.** With one API phase the table, entity, repository, service **and** audit rows all ship together, so **AC15 IS claimed by this plan** — the "1a validates + WARN-logs and does not claim AC15" interim state is gone. Do not implement the WARN-log stub. | the audit AC. The **table**, entity, repository, service and audit rows all ship together in the single API commit, so **AC15 IS claimed by this plan** *(superseded 1a/1b wording removed 2026-08-06 — it contradicted the correction in the preceding cell)* | 1-API | §3.14 (**O1**) |
| N12 | `db/migration/V2.2.11__putaway_destination_hierarchy.sql` | **one** migration (decided 2026-08-04): preflight guard, `DROP NOT NULL`, `putaway_config_audit` table, reversible pre-image, scoped backfill, `client.defaultputawaylocation_id` + guarded FK, `DEFAULT_PUTAWAY_LOCATION` sysprop seeded `''` | 1-API | §5.1 |
| N14 | `controller/PutawayConfigController.java` + `PutawayConfigPreview` | the typed write surface; the only place D11's count-and-confirm can live | 1a (`preview`, `setSku`, `setWarehouse`) / 1b (`setMerchant`) | §3.5a |

### 0.2 Web UI — `v2/wms2-web-ui/` (Phase 2)

| # | File:line | Construct | Verdict | § |
|---|---|---|---|---|
| 38 | `components/receiving/open/receive/receivingForm.vue:9-13` | "Inbound Putaway Staging" value is the **hardcoded string "Put Away Lane"**; `putawayStaging: null` at `:206` never read/written | **in — SBDEV-2731 display half** | §3.11.1 |
| 39 | `components/admin/parametersAndConfiguration/editParamAndConfig.vue:23-30` (+ `addParamAndConfig.vue:22`) | generic sysprop dialog, `groupName` branches only | **in — add a `syskey` branch with a tiered location picker** | §3.11.2 |
| 40 | `components/admin/shippers/editShipper.vue:14-80` | merchant form; no putaway field, no inherited-vs-configured concept | **in — new three-state field** | §3.11.3 |
| 41 | `store/admin/configuration.js:73-93` (`PUT /sysprop/{id}`), `:95-123` (`POST /systemProperty/create`, axios at `:99`), `:125-147` (`DELETE /sysprop/{id}`, axios at `:127`), `:254-264` | the generic dialog's three write actions plus the groupname read | **in — the `DEFAULT_PUTAWAY_LOCATION` branch writes through `PUT /putawayConfig/warehouse`, NOT through any of these three** | §3.11.2 |
| 42 | `store/admin/shippers.js` (`:47` `PATCH /client/{id}`) | `GET /client/detailView`, `POST /client/create`, `PATCH /client/{id}` | **in — read the new field via `detailView`; write it through `PUT /putawayConfig/merchant/{clientId}`** | §3.11.3 |
| 43 | `plugins/persistedState.client.js:22-25` | persists the **entire** `admin` module (incl. `admin.configuration.operationOptions`) to `localStorage['vuex-web']` | **in — add exclusion** | §3.11.4 |
| 44 | `layouts/default.vue:264-268, 284-286`; `store/index.js:92-117`; `nuxt.config.js:167` | `adminMenu` never referenced; `'super-admin'` returned unconditionally; `APP_ADMIN_GROUP` read nowhere | **in — bounded decision, not a framework** | §3.12 |
| 45 | `components/masterData/skuData.vue:107-131, 142` | create/edit block commented out; `putawayLocation` already displayed read-only | **out of THIS plan** — that is SBDEV-2643's SKU edit form. §10 Q3 records that 2643 is materially bigger than "add a field". |
| 46 | `components/putaway/storePallet.vue:14-23` (mobile UI) | free-text scan, no expected destination shown | **out** — `wms2-mobile-ui` is a third phase, not in D4. Follow-up ticket, §8.4. |

---

## 1. Problem Statement

Receiving in v2 can send inbound stock to exactly **one** destination per SKU, and that destination is not really configurable.

**What the operator sees.** Receiving a case of a SKU whose putaway location was pointed at an incompatible location fails with:

```
unitloadtypeId=4 not allowed on location=Ice Pack with location type=2
```

thrown at `service/UnitloadBusinessService.java:191`. It leaks raw database ids, names no remedy, and arrives *after* the first unit load has already been created inside `receiveGoods`' single transaction — so the whole receipt rolls back with a message no warehouse user can act on. (Reproduced structurally on `wh01_hydra_v2t`: `unitload_type 4 = Case`, `location_type 2 = flowbin`, and `location_constraint` for `flowbin` has exactly one row permitting `unitloadtype_id=1 (PickLocation)`. `Ice Pack` itself exists only on NYWH UAT/prod.)

**What is missing.** There is no warehouse-level default and no merchant-level default. The ticket asks for a four-tier precedence — SKU → merchant → warehouse → standard putaway lane — configurable from the UI, validated, permission-gated, and audited.

**Why "just set the SKU field" is not an answer.** Three independent facts, all verified:

1. The SKU field is `NOT NULL` in DDL (`V2.2.00__base_v2_schema.sql:951`) and `@NotNull` on the entity (`model/Itemdata.java:49`), and **all four** write paths unconditionally seed it with the `PutAwayLane` id (§0.1 rows 8–11). On `wh01_hydra_v2`, **2,720 of 2,720 rows (100 %)** point at the single location `PutAwayLane` (id 50155). There is no "unset" state, so there is nothing for a lower tier to inherit *into*.
2. There is **no validated write path**. `controller/ItemDataController.java:88-90` is a raw `save()` with zero validation, reached by a `@GetMapping` that mutates state; `service/ItemdataService.setPutAwayLocation` (`:68-76`) has **zero production callers** and would not have validated anyway (it loads the old location only for a log line). And `PATCH /v3/itemdata/{id}` bypasses both — `RestConfiguration.java:47` uses `RepositoryDetectionStrategies.ANNOTATED` and `:55-60` registers only bean-validation validators. This is almost certainly how the invalid Ice Pack configuration was created.
3. The destination is **structurally ignored on the carrier path**. `ReceivingService.java:454-457` reads `itemdata.getPutawaylocationId()` **only when `carrier == null`**; on a carrier receipt `putAwayLocation` is hard-`null` and the unit load goes onto the carrier. That is a branch, not a data problem.

**Two corrections to the ticket's framing**, for the record:

- **SBDEV-2642 ("V1 Fix: Ability to Set Default PutAway other then PutAway") shipped no code.** Zero commits across all five repos, `assignees: []`, `attachments_count: 0`, closed 2026-07-25 — 1,247 s (≈21 min) **before** SBDEV-2732 was created. It was closed as superseded, not delivered. v1 `ReceivingService.java:521-523` is the same single-tier lookup and is strictly *worse* than v2 (bare `NoSuchElementException` vs message-keyed `BusinessException`). **There is no v1 prior art to port; jakarta-vs-javax is moot.** This is greenfield in both stacks.
- **"Receiving does not display or honor the SKU destination" (SBDEV-2731) is not an accurate code diagnosis.** The API *does* read it (`ReceivingService.java:455`) and `receiving_dto_view` *does* project `defaultputawaylocationname` (`V2.2.00__base_v2_schema.sql:4663` → `model/ReceivingDtoView.java:47, 173`). The real defects are (a) the unvalidated write path above, (b) a UI that never renders the existing column — `receivingForm.vue:9-13` hardcodes the literal string "Put Away Lane" — and (c) the carrier branch at `ReceivingService.java:454-457`.

---

## 2. Current Architecture

### 2.1 The resolution call path (the "is" state)

```java
// ReceivingService.java:451-457 — hoisted ABOVE the per-case loop at :462. Preserve that.
Location spawnLocation = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_SPAWN)
    .orElseThrow(() -> new BusinessException("entityNotFoundForName", ...));
Location putAwayLocation = (carrier == null)
    ? locationRepository.findById(itemdata.getPutawaylocationId())
        .orElseThrow(() -> new BusinessException("entityNotFoundForId", Location.class.getSimpleName(), itemdata.getPutawaylocationId()))
    : null;

// ReceivingService.java:491-495 — per created unit load
if (carrier == null) {
    unitloadBusinessService.transferUnitLoadToLocation(unitload, putAwayLocation, false, codeReceiving, adviceposition.getNumber(), null);
} else {
    unitloadBusinessService.transferUnitLoadToCarrier(unitload, carrier, codeReceiving, adviceposition.getNumber(), null);
}
```

Two properties to preserve: resolution is hoisted out of the loop, and `receiveGoods` is **one** tenant transaction (`:302`) so a bad destination fails on the first case and everything rolls back.

**Finding that materially de-risks D2.** On the non-carrier path, `transferUnitLoadToLocation` **already** places the unit load directly into the SKU's configured location. D2's "direct placement, bypass manual putaway" therefore requires **no new placement mechanism** — the only change is *which* `Location` the code hands to the existing call. And v2 has **no putaway-task entity**: `MobilePutAwayService.calculatePutAwayList` (`:212-283`) derives suggestions on the fly from unit loads sitting on the putaway lane. A directly-placed unit load simply never appears in that list, so *"no orphan putaway task remains open"* is satisfied with nothing to suppress. (Resolves open question 6 from the analysis bundle.)

### 2.2 Validation (the only compatibility gate today)

```java
// UnitloadBusinessService.java:180-193, inside transferUnitLoadToLocation (declared :125)
List<LocationConstraint> locationConstraintList =
    locationConstraintRepository.findByStoragelocationtypeId(destinationLocation.getTypeId());
if (locationConstraintList != null && !locationConstraintList.isEmpty()) {     // <-- FAIL-OPEN on empty
    boolean foundPermittingConstraint = false;
    for (LocationConstraint locationConstraint : locationConstraintList) {
        if (locationConstraint.getUnitloadtypeId().equals(unitload.getTypeId())) { foundPermittingConstraint = true; break; }
    }
    if (!foundPermittingConstraint) {
        throw new BusinessException("unitloadtypeId=" + unitload.getTypeId()
            + " not allowed on location=" + destinationLocation.getName()
            + " with location type=" + destinationLocation.getTypeId());   // :191 — the only raw-concat throw here
    }
}
```

**`location_constraint` is a pure allow-list, but an EMPTY list for a location type permits everything.** Live allow-list on `wh01_hydra_v2t` (8 rows): flowbin→PickLocation; overstock box→Case; overstock pallet→Case, Pallet; totes→Tote; packages→Package; cases and pallets→Case, Pallet. Location types **0 `System`** and **1 `NoRestriction`** have zero rows ⇒ unrestricted. A validator written as "missing row = disallowed" would reject configurations that work correctly today. This fail-open branch is **mandatory** to replicate (D6).

Three predicates run *before* the constraint check inside the same method and must be mirrored by write-time validation but **not** duplicated at receive time (they already run): destination lock check `:156-158` (`entityLock != NOT_LOCKED` → `FacadeException("STORAGELOCATION_LOCKED")`, skipped on `ignoreLock=true`), and `FixLocationAssignment` `:161-177` (carrier ban → `CARRIER_NOT_ON_FIXLOC`; SKU mismatch → `WRONG_ITEMDATA_FIXASSIGNMENT`).

Sibling throws at `:157, :167, :174` all use message keys via `exceptionMessageService.getMessage(...)`. `:191` is the **only** raw-concatenated one in the method — which is exactly why it leaks ids.

### 2.3 There is no "active" flag on `location` — DB evidence

```
location          : id, additionalcontent, created, entity_lock, modified, version, xpos, ypos, zpos,
                    name, client_id, area_id, rack_id, type_id,
                    staginglane, transferlane, automationlane, crossdockinglane, gate
location_area     : useforgoodsin, useforgoodsout, useforpicking, useforreplenish,
                    useforstorage, usefortransfer, usefordeepstorage   (all boolean NOT NULL)
location_constraint: id, name, number, storagelocationtype_id, unitloadtype_id
```

The ticket's requirement "*Be active*" has **no column to test**. §3.4c redefines validity as a concrete predicate over what exists. Closest proxy for "active": `entity_lock == BusinessObjectLockState.NOT_LOCKED (0)`; full enum at `WmsConstants.java:1188-1195` (`NOT_LOCKED=0, GOING_TO_DELETE=2, PICKED_FOR_GOODSOUT=100, QUALITY_FAULT=103, ON_HOLD=104, NOT_FOUND=403, TRANSFER=404, SHIPPED=405`). There is also no `shippinglane` flag — "shipping" is `gate == true` and/or `staginglane == true`.

### 2.4 Facility scoping is already solved — DB evidence

The tenant schema (52 tables) contains **no `warehouse` and no `facility` table**, and `location` has **no facility discriminator column**. Sysprop `Contact Line = 'NY East - Warehouse'` confirms one DB = one physical warehouse, matching the documented `tenant_name` + `facility_code` → 4-char routing key → per-facility DB topology.

**One database per facility.** The ticket's "prefer warehouse-specific configuration rather than a single tenant-wide location ID" is satisfied *automatically*: a tenant-wide row **is** warehouse-scoped because the database is the facility boundary. Likewise "one value per merchant per warehouse" is satisfied by one row per `client` per tenant DB. **No facility dimension, no composite key, no join table.** This deletes a large slice of the ticket's presumed data-model work.

### 2.5 Sysprop storage — DB evidence and four landmines

`los_sysprop` columns: `id, additionalcontent, created, entity_lock, modified, version, description, groupname, hidden, syskey, sysvalue, workstation NOT NULL, client_id NOT NULL`. Unique constraint **`UNIQUE (client_id, syskey, workstation)`** = `uk8tcoe23qui9q3ancbhx662iqb` (`V2.2.00__base_v2_schema.sql:3600-3603`), PK `(id)` at `:3400-3404`, FK on `client_id` at `:5334-5337`.

On `wh01_hydra_v2t`, **all 131 rows are `client_id = 0` / `workstation = 'DEFAULT'` across all 9 groupnames** — the per-client sysprop tier has **never been used in production**. No `PUTAWAY`-named key exists yet.

| # | Landmine | Evidence | Consequence for this design |
|---|---|---|---|
| A1 | `SyspropService.getStringDefault` **INSERTs** a row on a total cascade miss | `SyspropService.java:234` `createSystemProperty(getSystemClient(), WORKSTATION_DEFAULT, key, defaultValue, ...)` | Resolver may not be `readOnly`; "clear the override" cannot be a DELETE of the system row. **§3.4a avoids this method entirely.** |
| A2 | Blank vs null | tier hits return `sysprop.getSysvalue().trim()`; the UI writes `sysvalue=''` when a field is cleared | Blank-after-trim **must** mean "not configured". Same class as the JPQL `IS NULL`/`= ''` trap in `CLAUDE.md` §Query Patterns. |
| A3 | `getSysvalue(key)` is **client-blind** | `SyspropRepository.java:29-31` — `... where syskey = :syskey and workstation='DEFAULT' order by client_id LIMIT 1`; the comment at `:28` literally says *"legacy code incorrectly assumes one result"* | Consumed by `SyspropService.java:288-291`, the workhorse accessor. If merchant-scoped rows ever exist for a key it collapses them to the lowest `client_id`. **Never read a client-scoped key through it.** |
| A4 | the `sysprops` Caffeine cache key **omits `clientId`** | key = `facilityCode + ':' + #key` at `SyspropService.java:53, 95, 288, 303`; cache at `CacheConfig.java:36` (200 entries / 2 min) | Caching any client-scoped key through those methods serves one merchant's value to every merchant. |
| A5 | `setSysvalue` cannot write a merchant row | `SyspropService.java:303-320`; `:306` hard-codes `clientService.getSystemClient().getId()` + `DEFAULT` | A merchant-scoped sysprop **writer does not exist**. |

A3 + A4 + A5 + "never used in production" are four independent reasons the **merchant** tier must not be a sysprop row. See §3.3 and §9 A1.

### 2.6 Audit — nothing to extend

Schema search for `%audit%`, `%history%`, `revinfo`, `%changelog%` returned **zero tables**. `grep "Audited|Envers|RevisionEntity"` → zero hits, no dependency. Spring Data auditing gives **timestamps only** (`model/AbstractBaseEntity.java:16-17, 29-33`) — there is **no `@CreatedBy`/`@LastModifiedBy` and no `AuditorAware` bean**, so the framework does not capture *who*. `Stockrecord` / `UnitloadRecord` / `InventoryRecord` are stock-movement history, not config history.

The **only** entity-audit precedent is hand-rolled and domain-specific: `model/CustomerorderCancellationLog.java` + `service/CancellationLogService.java` (`@Transactional(value="tenantTransactionManager", propagation = Propagation.MANDATORY)`, `IDENTITY` id, explicit `tenantName`/`facilityCode` columns, `createdBy = SecurityContextUtils.getUserName()`). **Imitate that.** Do not introduce Envers for this ticket.

### 2.7 Cache topology in scope

`config/CacheConfig.java` defines four caches **twice** — Caffeine at `:31-42` (`@Profile("!redis")`) and Redis at `:49-69` (`@Profile("redis")`). **Both must stay in sync.**

| Cache | TTL | Key expression | Relevance |
|---|---|---|---|
| `sysprops` | 2 min | `facilityCode + ':' + #key` (**no clientId**) | tier 3 — read path deliberately uncached (§3.4a) |
| `clients` | 5 min | `facilityCode + ':' + #clientNumber` (`ClientService.java:53`) and `facilityCode + ':SYSTEM'` (`:100`) | **tier 2 lands here** — needs eviction |
| `locations` | 5 min | — | destination lookups |
| `itemdata` | 5 min | `facilityCode + ':id:' + #id` (`ItemdataService.java:47`) and `facilityCode + ':' + #clientId + ':' + #itemNr` (`:52`) | tier 1 — correct 2-key evict already written at `:59-67` |

**A 2–5 min TTL means a config change is not immediately visible.** §7.3 must not validate through a stale cache. Mitigating fact: `receiveGoods` loads its `Client` via `clientRepository.findById(adviceposition.getClientId())` (`ReceivingService.java:369-370`) — **uncached** — so the *receiving* path never reads a stale tier-2 value. Only the admin screens can.

### 2.8 Transaction & observability constraints

- `transferUnitLoadToLocation` is `Propagation.REQUIRED` and its sibling carries the explicit contract at `UnitloadBusinessService.java:214-215`: *"joins the caller's transaction. Caller must hold all row-level locks before invoking this method (SBDEV-2232 §3.0). Do NOT call from a non-transactional context."* ⇒ **the resolver must never open `REQUIRES_NEW`** — that produces a Postgres deadlock the detector cannot see (parent idle-in-transaction, hangs forever).
- `transferUnitLoadToLocation` / `transferUnitLoadToCarrier` have **33 call sites** (24 + 9) across picking, palletizing, truck loading, transfer orders, on-hold, nirvana and the empty-pool. **The resolver is wired at the receiving call-sites only, never inside `transferUnitLoadToLocation`.**
- **OSIV risk is LOW**: `Itemdata`, `Location`, `Client`, `LocationConstraint`, `LocationType`, `LocationArea`, `UnitloadType`, `Sysprop` all use manual `Long` FK ids with no JPA associations. `Location.equals` (`:163-168`) is id-based; `AbstractBaseEntity.hashCode()` (`:76-79`) deliberately returns `getClass().hashCode()`.
- **Micrometer: there is no counter or timer anywhere on the receiving path.** Zero hits for `MeterRegistry|Counter|Timer` in `ReceivingService`, `UnitloadBusinessService`, `ReceivingController`. `schedulejob/JobMetrics.java` is cron-only. Instrumentation is **net-new** (§3.13).
- `IdempotencyFilter` guards `/rest/**` only — `/v3/receiving/receive` and `/v3/itemData/*` are **outside** it.
- **`ddl-auto` is `none`** (`application.properties:70`; `:69` has `validate` commented out) — so entity/DDL drift does **not** fail startup. Every entity field added in §3 must still land in the same commit as its DDL, but the enforcement is **runtime, not startup**: a mapped column with no DB column fails `42703` on every SELECT that touches it, per request, with healthy probes. `validate` is the **test** profile only.

### 2.9 Flyway / repo state

Migration head on `origin/develop` is **`V2.2.09__seed_return_advice_auto_receive_sysprop.sql`** ⇒ **next free version is `V2.2.11`** — one migration (D16, 2026-08-04). **`V2.2.08`** was taken by SBDEV-2801 and **`V2.2.09`** by SBDEV-2778, both merged that day; `V2.2.11` was verified free across `origin/develop` **and every remote branch**. **Re-verify with a full remote-branch sweep immediately before the PR** — unmerged branches hold invisible versions, which is exactly how the original `V2.2.08` reservation collided. Three hard facts:

1. **The running app DOES invoke Flyway, on every boot — this reverses the plan's original premise.** `app.flyway.migrate-on-startup=true` (`application.properties:133`) + `landlord/config/StartupFlywayMigrationRunner.java` (an `ApplicationRunner`, default-ON via `matchIfMissing = true`) migrate the landlord and then **every active tenant DB** before readiness (SBDEV-2801, merged 2026-08-04; see `v2/wms2-api/CLAUDE.md` §Database). **But a tenant DB with no `flyway_schema_history` is SKIPPED, not auto-baselined** — and the Hydra DEV copy is exactly such a DB (§8.1). So on that tenant merging changes nothing and the migration silently never applies until it is repaired once with `db/backfill-flyway-history.sh`.
2. **`ddl-auto` is `none`, not `validate`** — `application.properties:70`; `:69` has `validate` commented out, and the value flows into both EMFs (`LandlordDatabaseConfig.java:32-50`, `TenantDatabaseConfig.java:32-63`). `validate` is the **test** profile only. **Consequence: a missing column does NOT prevent startup.** The app boots clean and then fails `42703 column ... does not exist` on every Hibernate SELECT that touches the mapped column — per-request, with green liveness/readiness probes. See §8.1's detector.
3. **The IT harness scans `classpath:db/v1-to-v2-onboarding/schema`, not `db/migration/`** (`v2/wms2-api/CLAUDE.md:141`) ⇒ `V2.2.11` is **invisible** to integration tests. No IT can prove the DDL.

Branch off **`develop`** explicitly. *(The local checkout has sat on unrelated ticket branches; do not assume it is on `develop`, and do not branch off another ticket's branch — stacked-PR orphan trap.)*

---

## 3. Design

Four tiers, one resolver, one validator, one audit writer, one metrics holder. Everything below is additive except §3.2 (the nullability change) and §3.6 (the message replacement).

```
                                  PutawayDestinationResolver.resolve(itemdata, client, unitloadtypeId)
                                                   │
  Tier 1  SKU        itemdata.putawaylocation_id  NOT NULL ──► SKU_OVERRIDE
                        │ NULL  (new — V2.2.11 drops NOT NULL)
  Tier 2  Merchant   client.defaultputawaylocation_id  NOT NULL ──► MERCHANT_OVERRIDE
                        │ NULL  (new column — V2.2.11)
  Tier 3  Warehouse  los_sysprop(client_id = <system>, syskey='DEFAULT_PUTAWAY_LOCATION')  non-blank ──► WAREHOUSE_DEFAULT
                        │ absent / blank-after-trim
  Tier 4  Fallback   location WHERE name = WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE ──► STANDARD_PUTAWAY_LANE
```

### 3.1 `PutawayDestinationResolver` — the one shared service

**Rationale.** The ticket's central AC is *"precedence is defined in ONE shared backend service"*. Every consumer (receiving, the config-write validators, the receiving-display endpoint, Phase 2's inherited-vs-configured display) calls the same method, so the four-tier semantics — including the sentinel subtleties — exist in exactly one place and are unit-testable in isolation.

**New file:** `src/main/java/net/aim_ai/wms/service/PutawayDestinationResolver.java`

```java
@Service
public class PutawayDestinationResolver {

    public enum Source { SKU_OVERRIDE, MERCHANT_OVERRIDE, WAREHOUSE_DEFAULT, STANDARD_PUTAWAY_LANE }

    /** Immutable resolution outcome. {@code configuredFor} is the human label of the tier that won
     *  (SKU number / merchant cl_nr / "warehouse" / "standard lane") for operator-facing messages. */
    public record Resolution(Location location, Source source, String configuredFor) {}

    /**
     * Resolves the effective putaway destination for one receipt line. Pure resolution + P1
     * classification: it NEVER throws on incompatibility — see {@link Resolution#compatible()}.
     *
     * <p>MANDATORY propagation, deliberately: (a) it structurally forbids a new transaction, which is
     * what makes the {@code REQUIRES_NEW}-inside-a-lock-holding-tx deadlock (SBDEV-2232 §3.0,
     * {@code UnitloadBusinessService.java:214-215}) unreachable by construction; (b) it joins the
     * caller's read-write transaction so the {@code readOnly} question does not arise; (c) it makes an
     * accidental non-transactional call fail loudly instead of silently auto-committing.
     *
     * <p><b>MANDATORY means a controller cannot call this directly</b> — there is ZERO
     * {@code @Transactional} anywhere under {@code controller/}. Read callers go through
     * {@link PutawayDestinationQueryService} (§3.8). See §3.1.5.
     *
     * @param itemdata       MAY BE NULL — {@code AdviceRestController.java:684} sets
     *                       {@code position.setItemdataId(null)} on the hub-and-spoke path. Reachable
     *                       from the display endpoint; see §3.1.4.
     * @param client         never null; the merchant owning the receipt line.
     * @param unitloadtypeId the unit-load type that will be created, from
     *                       {@code adviceposition.getUnitloadtypeId()}. MAY BE NULL ⇒ {@code compatible}
     *                       is reported as {@code true} (unknowable, so do not claim a conflict).
     */
    @Transactional(value = "tenantTransactionManager", propagation = Propagation.MANDATORY)
    public Resolution resolve(Itemdata itemdata, Client client, Long unitloadtypeId)
            throws BusinessException { ... }

    /** Throws iff {@code !r.compatible()}. Split out so the CALLER decides whether a mismatch is
     *  fatal — receiving calls it only when {@code carrier == null} (§3.7.2, D10); the display
     *  endpoint never calls it. */
    public void requireCompatible(Resolution r) throws BusinessException { ... }
}
```

**`Resolution` carries `compatible` rather than throwing.** The resolver is hoisted and runs for *both* receiving branches (which is what fixes 2731), but on the carrier path the resolved destination is **never applied**, so an incompatibility there is not an error. Making the throw a separate, caller-invoked step is what lets one resolution serve a fatal path and a non-fatal path without a flag argument.

```java
public record Resolution(Location location, Source source, String configuredFor,
                         boolean compatible, String incompatibilityReason) {}
```

#### 3.1.1 Tier evaluation order and the exact "configured" test

| Tier | Test | Notes |
|---|---|---|
| 1 SKU | `itemdata != null && itemdata.getPutawaylocationId() != null` | honest only after §3.2 + the §5.1 backfill |
| 2 Merchant | `client.getDefaultputawaylocationId() != null` | §3.3 |
| 3 Warehouse | raw sysvalue non-null **and** `!raw.trim().isEmpty()` **and** parses as a `Long` | §3.4a; landmine A2 |
| 4 Fallback | always | `locationRepository.findByName(WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE)` |

A tier that is *configured* but whose location id does not resolve to a `location` row is a **hard failure**, not a fall-through (D6). A tier that is *not configured* falls through silently. These are different states and must not be conflated.

#### 3.1.2 What the resolver validates at receive time — and what it deliberately does not

The resolver applies **only** predicate **P1 (compatibility)** — §3.4b — to the winning tier. It does **not** apply the broader suitability predicate **P2** (§3.4c) at receive time.

**Rationale, and this is load-bearing:** applying P2 at receive time would make the resolver *stricter* than `transferUnitLoadToLocation` and would break receipts that work today. Specifically, `PutAwayLane` on `wh01_hydra_v2t` sits in area `Inbound` with `useforstorage = false` — a suitability predicate that required `useforstorage` would reject tier 4 itself. P2 is a *"is this a sane thing to configure"* question and belongs at config-write time only. P1 is byte-for-byte the semantics already enforced at `UnitloadBusinessService.java:180-193`, so hoisting it earlier changes *when* and *how* the failure is reported, never *whether*.

The lock check (`:156-158`) and `FixLocationAssignment` checks (`:161-177`) are also **not** duplicated at receive time — `transferUnitLoadToLocation` still runs them a few lines later. Duplicating them would double the queries for no behavioural gain.

#### 3.1.3 Failure semantics

`requireCompatible(...)` — **called by receiving only when `carrier == null`** (§3.7.2), never by the display endpoint:

```java
throw new BusinessException("putawayDestinationNotPermitted",
        resolution.configuredFor(),                 // %1$s  "SKU 12345" | "merchant WINE01" | "warehouse default"
        resolution.location().getName(),            // %2$s  "Ice Pack"
        unitloadTypeName,                           // %3$s  "Case"
        locationTypeName,                           // %4$s  "flowbin"
        WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE); // %5$s  remedy anchor
```

**`putawayDestinationNotPermitted` is thrown HERE, in the resolver, and NOWHERE ELSE.** In particular it is **not** thrown at `UnitloadBusinessService.java:191`: that throw site also serves picking, palletizing, truck loading, transfers, on-hold and nirvana — 21 call sites with no configured putaway destination, for whom the remedy clause ("clear the configured destination") is actively misleading. `:191` gets the neutral key `unitloadTypeNotPermittedOnLocation` instead (§3.6.1). The putaway-specific key belongs where the putaway context exists, and keeping it out of `:191` is also what removes any need to pipe `unitloadRepository.findLabelidById` / `unitloadTypeRepository.findNameById` lookups into that method.

It **must** be a `BusinessException` (never a bare `RuntimeException`): `ReceivingController.java:283-300` catches `BusinessException` and surfaces `e.getMessage()`, but `:298-300` swallows `RuntimeException` into *"Receiving failed due to an unexpected internal error. Please contact support."* — which would defeat the ticket's error-handling AC outright. **`IllegalTransactionStateException` is exactly that forbidden class** — see §3.1.5.

**A dangling configured id is still a hard failure** (D6), distinct from an incompatibility: a tier that is *configured* but whose location id resolves to no `location` row throws immediately from `resolve(...)` on **both** branches, because that is config rot with no valid destination at all, not a workflow mismatch. A tier that is *not configured* falls through silently. Three states, three behaviours — do not collapse them.

#### 3.1.4 The null-SKU path (§0.1 row 21) — a DISPLAY-endpoint contract, not a receive-path one

`AdviceRestController.java:684` sets `position.setItemdataId(null)` on `createHubAndSpoke` while `:685` still sets a `unitloadtypeId`. Contract: **`itemdata == null` skips tier 1 and starts at tier 2**, with `configuredFor` degrading to the merchant / warehouse label. `PutawayDestinationResolverUnitTest.nullItemdataSkipsTierOne` asserts `resolve(null, client, typeId)` returns a non-null `Resolution` and never touches `itemdataRepository`.

**Scope of the contract: the display endpoint only.** A hub-and-spoke position cannot reach the resolver during a *receipt*. `receiveGoods` calls `itemdataRepository.findById(adviceposition.getItemdataId())` at `:356-357`, **96 lines before** the resolver at `:451`; `findById(null)` raises `InvalidDataAccessApiUsageException`, and `createStockUnit` (`:476`) needs a non-null `itemdata` regardless. The receipt therefore fails earlier, for a **pre-existing** reason this plan does not fix (§0.1 row 21a, §10 Q4).

The contract is nevertheless required, because **`GET /receiving/getPutawayDestination` resolves per advice position and genuinely can be handed one with a null `itemdataId`** — that is where a naive resolver 500s. Manual row **M12 is stated against the endpoint, not against a receipt**; stated against a receipt it could never pass.

#### 3.1.5 Reaching a `MANDATORY` resolver from a non-transactional controller

`Propagation.MANDATORY` on `resolve(...)` is the structural anti-`REQUIRES_NEW` device and stays. Its consequence is that **no controller may call it**: there is **zero `@Transactional` anywhere under `controller/`** — the only three matches in the whole tree are comments, two of which explicitly state the controller has no transaction. A `MANDATORY` call from there raises `IllegalTransactionStateException: No existing transaction found for transaction marked with propagation 'mandatory'`, a bare `RuntimeException`, on **every single call**. OSIV does not help: even when enabled it opens an `EntityManager`, never a transaction — and it is disabled (`application.properties:55` `spring.jpa.open-in-view=false`). Since §3.8's endpoint declares only `throws BusinessException`, `RestExceptionHandler` would map it to a 500 — and under D9 that endpoint is the *sole* data source for the entire 2731 display feature, in **Phase 1**.

**Every read caller therefore goes through a read-only tenant-tx facade:**

```java
@Service
public class PutawayDestinationQueryService {
    @Transactional(value = "tenantTransactionManager", readOnly = true)
    public Resolution describeForAdvicePosition(Long advicePositionId) throws BusinessException { … }

    @Transactional(value = "tenantTransactionManager", readOnly = true)
    public Resolution describeForClient(Long clientId) throws BusinessException { … }   // §3.11.3, N9
}
```

`readOnly = true` is safe **precisely because** §3.4a never touches `getStringDefault` — there is no auto-INSERT to accommodate (landmine A1). That decision is what makes this facade possible; had tier 3 gone through `getStringDefault`, no read-only facade could exist.

**No mocked unit test can prove this wiring.** A Mockito mock has no propagation semantics, so §7.1's `getPutawayDestinationShape` passes against a controller that calls the resolver directly. Proving it needs a real Spring context (blocked by SBDEV-2217) or a code-shape assertion — hence verify rows `check_N2_readonly_facade` (the facade exists and is annotated `readOnly = true`) and `check_N2_controller_delegates_not_resolves` (§3.8), plus manual row **M20**.

### 3.2 Tier 1 — make the SKU column nullable (D5)

**Rationale.** `NULL` is the only honest representation of "inherit". The alternatives were both rejected in §9 (A2, A3). This is the plan's single non-additive change and its primary compatibility risk.

**DDL** — `V2.2.11`, statement 2 (statement 1 is the preflight guard; full ordered script in §5.1):

```sql
ALTER TABLE public.itemdata ALTER COLUMN putawaylocation_id DROP NOT NULL;
```

Forward-only, cannot fail on existing data. The FK to `location(id)` (`V2.2.00...sql:5686-5690`) and the index `itemdata_putawaylocation_id_index` (`:4468-4471`) are unaffected — a nullable FK column is still enforced when non-null, and the index still serves the lookup.

**Entity** — remove the `@NotNull` above `putawaylocationId` at `model/Itemdata.java:49`. Keep the `@Column`. (`@NotNull` is what Spring Data REST's bean-validation validators enforce at `RestConfiguration.java:55-60`; leaving it would keep HAL writes of `null` rejected while typed writes succeeded — an inconsistency worse than either state.)

**Stop seeding — 4 sites, all in Phase 1, all in the same commit as `V2.2.11` (O3):**

| Site | Change |
|---|---|
| `SkuRestController.java:85-88` (create) | delete the `defaultPutawayLocationId` lookup |
| `SkuRestController.java:144-146` (create → `upsertAll`) | drop the argument |
| `SkuRestController.java:198-201` (update) | delete the lookup |
| `SkuRestController.java:257-259` (update → `upsertAll`) | drop the argument |
| `SkuBatchCreateUpdateService.java:36` | remove the `Long defaultPutawayLocationId` parameter |
| `SkuBatchCreateUpdateService.java:53` | delete `itemData.setPutawaylocationId(defaultPutawayLocationId)` — new SKUs are created with `NULL` = inherit |
| `FileImportController.java:383` | delete `itemData.setPutawaylocationId(location.get().getId())` |
| `FileImportController.java:355-359` | **keep an equivalent guard.** The SBDEV-2037 comment stays true in spirit — a missing `PutAwayLane` still breaks tier 4. Convert it from "the import needs the lane" to "the tenant needs the lane": keep the `findByName` presence check and the `errors.add(...)`, drop only the `.get().getId()` use. |

**Read-site null guards — 2 sites:**

- `ReceivingService.java:455` — subsumed entirely by §3.7; the ternary disappears.
- `ItemdataService.java:71` — `locationRepository.findById(itemData.getPutawaylocationId())` currently NPEs on `null`. Rewritten in §3.5.

**Test fixtures that assert the field is required — update deliberately, never by loosening an assertion** (≈10 sites): `common/fixtures/TestDataFactory.java:694`, `unit/model/EntityUnitTest.java:345, 370`, `unit/repo/ItemdataRepositoryTest.java:32`, `unit/service/ItemdataServiceUnitTest.java:592`, `MobileReplenishServiceH2Test:141`, `PickingorderBusinessServiceH2Test:279`, `ReplenishOrderControllerH2Test:148`, plus the two `@Disabled` ITs `ReplenishorderRepositoryIntegrationTest:66` and `CustomerorderBatchServiceParallelStreamRegressionIT:187`.

### 3.3 Tier 2 — merchant column on `client`

**Rationale.** `client` is a tenant-PU entity (`model/Client.java:10-22`) already carrying per-facility operational config (`enablereceiving`, `printerreceiving_id`, `section_id`). Because one facility == one tenant DB (§2.4), a column on `client` satisfies *"one value per merchant per warehouse"* **structurally, for free** — no composite key, no facility column, no join table. A typed FK gives referential integrity a `sysprop.sysvalue text` cannot, and it sidesteps landmines A3, A4 and A5 entirely. The repository is already REST-exposed (`ClientRepository.java:18-19`), and `/client/detailView` already feeds the Phase-2 merchant screen.

**DDL** — `V2.2.11`, statement 1 (Phase 1; the FK gets the re-apply guard shown in §5.1):

```sql
ALTER TABLE public.client
    ADD COLUMN IF NOT EXISTS defaultputawaylocation_id bigint NULL;
ALTER TABLE public.client
    ADD CONSTRAINT fk_client_defaultputawaylocation
        FOREIGN KEY (defaultputawaylocation_id) REFERENCES public.location(id);
```

Named FK constraint (not auto-generated) so it is greppable and droppable. No index — `client` is a tiny table and the column is read by primary-key lookup of the client, never filtered on.

**Entity** — `model/Client.java`, beside `printerreceivingId`:

```java
@Column(name = "defaultputawaylocation_id")
private Long defaultputawaylocationId;    // NULL = inherit from the warehouse default
```

with getter/setter. **No `@NotNull`.**

**Deploy-order coupling:** this field and the DDL must be deployed together, and the DDL must be applied *first*. See §5.1 row 1 and pre-mortem P1 — on an un-migrated database the application **starts normally and then fails `42703` on every `client` read**. (It does *not* refuse to boot: `ddl-auto` is `none`, not `validate`.)

**Cache eviction** — the `clients` cache has two key shapes (`ClientService.java:53` and `:100`). The merchant writer (§3.5) carries:

```java
@Caching(evict = {
    @CacheEvict(value = "clients",
        key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':' + #client.clNr"),
    @CacheEvict(value = "clients",
        key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':SYSTEM'")
})
```

The `:SYSTEM` eviction is unconditional and cheap — SpEL cannot cheaply ask "is this the system client", and evicting one extra key from a 100-entry cache costs nothing.

### 3.4 Tier 3, tier 4, and the two predicates

#### 3.4a Tier 3 — system-client sysprop, read through the non-auto-creating path

**Rationale.** groupname **`Operation Options`** is rendered generically by the existing Admin screen via `GET /sysprop/search/findByGroupname` (`SyspropRepository.java:22-23` → `SyspropService.getSystemByGroupname:256-286`), so the ticket's requested *Admin → Parameters → Configuration → Operational Options* path lands with **zero new UI plumbing**. 29 keys already live there on `wh01_hydra_v2t` (`INBOUND_UPDATE_STOCK_IMMEDIATELY`, `REQUIRE_RECEIVING_TO_CONTAINER`, `PICK_PATH_DIRECTION`, …).

**New constant** — `service/WmsConstants.java`, beside `SYSTEM_PROPERTY_PICK_PATH_DIRECTION_KEY` at `:1136`:

```java
public static final String SYSTEM_PROPERTY_DEFAULT_PUTAWAY_LOCATION_KEY = "DEFAULT_PUTAWAY_LOCATION";
```

**Read path — this resolves landmine A1.** The resolver reads:

```java
String raw = syspropRepository
        .findBySyskeyAndClientIdAndWorkstation(
                WmsConstants.SYSTEM_PROPERTY_DEFAULT_PUTAWAY_LOCATION_KEY,
                clientService.getSystemClient().getId(),
                WmsConstants.SystemProperty.WORKSTATION_DEFAULT)
        .map(Sysprop::getSysvalue)
        .orElse(null);      // absent row == not configured — see "the seed is a convenience" below
```

**`getSystemClient()` may return `null` — guard it.** `ClientService.java:101-109` returns `null` when no `cl_nr = 'System'` row exists (its own javadoc says so). Tier 3 must resolve it through an explicit `BusinessException`, never dereference it: an NPE there is a bare `RuntimeException`, the class §3.6.2 forbids, and `ReceivingController:298-300` would swallow it into "contact support".

```java
Client systemClient = Optional.ofNullable(clientService.getSystemClient())
        .orElseThrow(() -> new BusinessException("entityNotFoundForName", Client.class.getSimpleName(), "System"));
```

Note that `getSystemClient()` **is** `@Cacheable(value = "clients", key = … + ':SYSTEM')` (`ClientService.java:100`), so tier 3's *system-client lookup* is cached even though its *sysprop value read* is not. That is harmless — the system client's identity does not change — and a cache read inside a `readOnly` transaction is fine. §7.6 row 9 records it so the "receiving reads the tier values uncached" claim is not over-stated.

**LANDMINE A6 — `findSysvalueByClientIdAndSyskey` must never be used for this key.** `SyspropRepository.java:46-48`'s SQL is `select sysvalue from los_sysprop where client_id = :clientId and syskey = :syskey order by client_id LIMIT 1` — **it has no `workstation` predicate**, while the unique constraint is `(client_id, syskey, workstation)` (`uk8tcoe23qui9q3ancbhx662iqb`). The repository's own comment above it ("*this is unique constraint guaranteed to return one result*") is **wrong for this method**, and `order by client_id` is a no-op when `client_id` is already fixed — so with more than one workstation row for the key, **the value returned is arbitrary**.

That is reachable, not theoretical: `getSystemByGroupname` (`SyspropRepository.java:53-71`) filters on `groupname` **only** — no `client_id`, no `workstation` — so the generic Admin dialog lists and `PUT`s whatever rows exist, and `createSystemProperty` accepts an arbitrary workstation (`SyspropService.java:55, 61-75`). `ReceivingService.java:429-431` is a correct precedent for `WAREHOUSE_NAME`, but a **bad** precedent for a **UI-writable** key.

`findBySyskeyAndClientIdAndWorkstation` (`SyspropRepository.java:35-36`) is genuinely unique on the constraint, returns `Optional<Sysprop>`, is a derived query (no `@Query`), and is **not** `@Cacheable`. Reading tier 3 through it, and only through it, gives four properties the design depends on:

- `SyspropService.getStringDefault` is **never called** ⇒ no auto-INSERT (A1), so the resolver has no write path and no 23505 replica race on `uk8tcoe23qui9q3ancbhx662iqb`. This is also what lets §3.1.5's facade be `readOnly = true`.
- `SyspropService.getSysvalue` is **never called** ⇒ no client-blind `order by client_id LIMIT 1` collapse (A3) and no clientId-less cache key (A4).
- Neither method is `@Cacheable`, so tier 3 is still read uncached and the §3.10 freshness contract is unchanged.
- "Clear the warehouse default" is still an **UPDATE to `''`**, not a DELETE, and blanking is still stable because nothing auto-recreates the row.

Additionally, the event handler (§3.9) **rejects a write to this syskey on any workstation other than `DEFAULT`**, so the ambiguous state cannot be created through the UI in the first place. Unit test `workstationScopedRowIsIgnored`; verify row `check_R_tier3_workstation_qualified` plus a negative asserting `findSysvalueByClientIdAndSyskey` appears nowhere in the resolver.

**Value format: the numeric `location.id`.** Rationale: tier 2 stores an id, so both configurable tiers agree and the Phase-2 picker writes one shape; ids survive a location rename; **`location.name` has no unique constraint** (`V2.2.00__base_v2_schema.sql:959-979` — `name varchar(255) NOT NULL`, nothing more), the same fact that drives §5.1's backfill preflight guard. Cost: the value is not human-legible in the raw sysprop table — mitigated by writing the location name into the sysprop `description` on every write (§3.5) and by the Phase-2 picker (§3.11.2).

**Seed** — `V2.2.11`, final statement, modelled exactly on `V2.2.04` (draw `id` from `nextval('public.seqentities')`, never a literal; `INSERT ... WHERE NOT EXISTS` for idempotency):

```sql
INSERT INTO public.los_sysprop
    (id, version, entity_lock, hidden, syskey, sysvalue, workstation, client_id, groupname, description, created, modified)
SELECT nextval('public.seqentities'), 0, 0, false,
       'DEFAULT_PUTAWAY_LOCATION', '',            -- '' = not configured (landmine A2)
       'DEFAULT', 0, 'Operation Options',
       'SBDEV-2732: warehouse-level default putaway destination, stored as a location.id. Blank = not configured; receiving then falls through to the standard PutAwayLane. Set via Admin > Parameters > Configuration > Operation Options.',
       now(), now()
WHERE NOT EXISTS (
    SELECT 1 FROM public.los_sysprop
    WHERE syskey = 'DEFAULT_PUTAWAY_LOCATION' AND client_id = 0 AND workstation = 'DEFAULT');
```

Seeded **blank**, so no tenant's behaviour changes when the migration is applied. **This is the single most load-bearing line in the whole migration** — the entire §6 back-compat argument rests on it, and a migration that seeded a real location id would pass every other check while silently changing behaviour on all five tenants. Verify row `check_M_sysprop_seed_blank` asserts the literal `''` **in the INSERT's SELECT list**, not merely that the key name appears somewhere in the file.

**The seed is a convenience, not a dependency.** An absent row yields `Optional.empty()` ⇒ `null` ⇒ not-configured, which is exactly the same behaviour as a blank value. Seeding explicitly only makes the key **visible in the generic admin dialog** before the first write. That is why the seed can sit in `V2.2.11` while tier 3 itself is live from Phase 1: `PUT /putawayConfig/warehouse` (§3.5a) creates the row on first write if the seed has not run.

#### 3.4b Predicate P1 (compatibility) — extract, do not reinvent

**New method on `service/LocationConstraintService.java`:**

```java
/**
 * SBDEV-2732 — single source of truth for "may a unit load of this type sit on a location of this type".
 *
 * <p>An EMPTY constraint list for the location type permits EVERY unit-load type. That fail-open branch
 * is not a bug and must not be "fixed": location types {@code System} and {@code NoRestriction} carry
 * zero {@code location_constraint} rows on live tenants and are legitimately unrestricted. A predicate
 * written as "missing row = disallowed" would reject configurations that work correctly today.
 *
 * <p>Deliberately uses the existing {@code findByStoragelocationtypeId} + in-memory scan rather than a
 * new {@code existsBy...} query: the list fetch reproduces {@code UnitloadBusinessService.java:180-193}
 * byte-for-byte, which is the whole point, whereas an {@code exists} formulation needs two round-trips
 * to express the same fail-open rule and invites drift.
 */
public boolean isUnitloadTypePermitted(Long storagelocationtypeId, Long unitloadtypeId) {
    List<LocationConstraint> constraints =
        locationConstraintRepository.findByStoragelocationtypeId(storagelocationtypeId);
    if (constraints == null || constraints.isEmpty()) {
        return true;                                       // fail-open — see javadoc
    }
    for (LocationConstraint c : constraints) {
        if (c.getUnitloadtypeId().equals(unitloadtypeId)) {   // correct Long.equals
            return true;
        }
    }
    return false;
}
```

`UnitloadBusinessService.java:180-193` is then rewritten to call it (§3.6), so the rule exists once. **No new repository method** — §0.1 row 16 stays as-is.

> [!warning] **⚠ P1 MUST NOT BE APPLIED TO A PICK-FACE DESTINATION — at write time OR at receive time. Added 2026-08-08.**
>
> §5.2 step 7 has the validator apply **P1 + P2**. P1 is `isUnitloadTypePermitted(destinationType, unitloadType)`
> and it asks *"can a unit load of the SKU's default type sit here?"* **For a pick face that is the wrong
> question, and it answers "no".**
>
> Measured on HMG PRD: flowbin (`type_id = 2`) has **exactly one** `location_constraint` row, permitting
> `unitloadtype_id = 1` (`PickLocation`); `ICE PACK`'s `defultype_id` is **4** (`Case`). **So P1 is FALSE and
> rejects the `ICE PACK` configuration — even after P2.5 and P2.7(c) are dropped.** Relaxing those two does
> not make the config writable; P1 still refuses it.
>
> **Why the question is wrong.** Under (iv-b) no Case unit load ever sits on the pick face. Receiving diverts
> to the lane; putaway merges the stock into the flowbin's **resident `PickLocation` unit load**
> (`storeBoxOnLocation:479-487`) and retires the Case UL en route. P1 is testing a unit load that will never
> be there.
>
> **Rule: skip P1 when the destination is a pick face** (same predicate as the gate —
> `area.useforpicking == TRUE || sltname == 'flowbin'`), at **both** enforcement points:
> - **config-write time** (the validator, §5.2 step 7) — or `ICE PACK` cannot be configured, and
>   **SBDEV-2643's picker cannot offer any of the 511 `useforpicking` locations**;
> - **receive time** (`requireCompatible`, §3.7.1) — the gate must run **first** and retarget to the lane, so
>   P1 is evaluated against `PutAwayLane` (`type_id = 7`, `cases and pallets`, which permits Case and Pallet
>   and therefore passes). Otherwise every pick-face-configured SKU's receipt hard-fails on a destination it
>   was never going to be placed at.
>
> **`Club08` passes P1 only by accident** — `cases and pallets` has **zero** `location_constraint` rows, so
> P1 fails *open*. Do not mistake that for the rule working.

#### 3.4c Predicate P2 (suitability) — config-write time only

The ticket's "*Be active*" has no column (§2.3). P2 is the concrete replacement, evaluated **only** when a configuration is written:

| # | Check | Source |
|---|---|---|
| P2.1 | the `location` row resolves by id | `locationRepository.findById` |
| P2.2 | `entityLock == BusinessObjectLockState.NOT_LOCKED` | closest proxy for "active"; `WmsConstants.java:1188-1195` |
| P2.3 | none of `staginglane / transferlane / automationlane / crossdockinglane / gate` is `TRUE` | `model/Location.java:33-41` |
| P2.4 | its `location_area` has `useforgoodsin == TRUE` **OR** `useforstorage == TRUE` | **OR, not AND, and not `useforstorage` alone** — `PutAwayLane` on `wh01_hydra_v2t` sits in area `Inbound` with `useforstorage=false, useforgoodsin=true`. This is also why the Phase-2 picker must **not** be built on `LocationRepository.getStorageLocationsForPutAwayItemData` (`:104-111`), whose native predicate is `location_area.useforstorage='true'` and which therefore **can never return `PutAwayLane`** (§0.1 row 34). |
| P2.5 | no `FixLocationAssignment` on the destination | **⚠ DROPPED 2026-08-08 (Q12 → iv-b) — this is NO LONGER a write-time reject at any scope. Do not implement it; the historical rationale is retained below because it explains why the runtime gate in step 15 must ship in the same change.** ~~Absolute reject at all three scopes~~ — `fixLocationAssignmentRepository.findByAssignedlocationId(destId).isPresent()` ⇒ reject. Structurally safe to treat as a single-row test: `fix_location_assignment` carries `UNIQUE (assignedlocation_id)` **and** `UNIQUE (itemdata_id)` (`V2.2.00__base_v2_schema.sql:3760-3763`, `:3712-3715`), so a location has at most one assignment and a SKU at most one pick face — the `Optional`-returning finder can never raise `IncorrectResultSizeDataAccessException`. **⚠ This is DELIBERATELY STRICTER THAN THE RUNTIME CHECK, and that is the whole mechanism enforcing D15.** At runtime `UnitloadBusinessService.java:170-175` rejects only on *SKU mismatch* (`WRONG_ITEMDATA_FIXASSIGNMENT`), so pointing a SKU at *its own* pick face is legal there — and SBDEV-2796's answer (c) says it is a legitimate operation. This plan nonetheless refuses to **write** that configuration, because tier-1 pick-face placement is deferred (D15) and `ReceivingService.java:454-457 → :491` already places tier-1 destinations unconditionally: there is no runtime gate to stop it, so **refusing the config is the only thing that keeps the deferred path unreachable.** **⚠ REVISED 2026-08-08.** This previously read *"SBDEV-2821 must relax this to the mismatch-only form as part of shipping tier-1 placement, not before"* — which assumed 2821 would ship direct placement. **Under 2821's adopted option (iii) it will not.** Neither live override carries an FLA, so **P2.5's relaxation is not required by (iii) at all**; the predicate that actually blocks those configs is P2.7(c) clause 1. Relaxing P2.5 to the mismatch-only form remains *optional and harmless* (it mirrors the runtime rule at `UnitloadBusinessService.java:170-175`), but it is **not** what unblocks anything. See the conflict box under P2.7(c). *(A 2026-08-04 revision briefly made P2.5 mismatch-only; reverted the same day — it permitted the config while the placement path stayed ungated, which put a second unit load on a location whose `assignedunitload_id` is `UNIQUE`. See §12.)* Do **not** add a carrier clause here: `:162-167`'s `CARRIER_NOT_ON_FIXLOC` fires when the *moved unit load has child unit loads*, not on the receipt's `carrier` parameter — it has no write-time inputs and is unreachable from `receiveGoods`, whose UL is freshly created at `ReceivingService.java:474`. |
| P2.6 | **P1** holds for every unit-load type the scope can produce | see below |

#### P2.7 — tiers 2 and 3 destination rules (D13) — ⚠ RE-FRAMED 2026-08-08 (Q12 → iv-b)

> **D13 was a CONFIGURATION rule because direct placement was ungated. Under (iv-b) it becomes a PLACEMENT
> rule, and the enforcement point moves from write-time to run-time.**
>
> - **What may be CONFIGURED** — widened. Any tier may name any location putaway can legitimately receive
>   into, **pick faces included**. Rule **(c)'s absolute pick-face / fix-assignment reject is DROPPED at all
>   three scopes**; it was the mechanism gating a placement path that is now gated directly.
> - **What may be PLACED AT RECEIPT** — unchanged in spirit, and now explicit: staging, goods-in and
>   cross-dock destinations are placed directly (rules (a), (b), (d) below). **Pick faces are not** — step 15's
>   `useforpicking` gate diverts them to the lane for putaway to route.
> - **P2.1–P2.4 and P2.6 are untouched** and still reject locked, shipping, transfer and gate locations. Those
>   are wrong destinations for putaway as much as for receiving.
>
> The rules below are otherwise retained, including the measured justification in the CORRECTION note.

**Merchant- and warehouse-scope destinations must satisfy ALL of:**

| | Rule for tiers 2/3 | Why |
|---|---|---|
| a | `staginglane` **or** `crossdockinglane` **may be TRUE** — these are *permitted*, not banned | They **are** the use case. The ticket's named tier-2 scenarios are "Club assembly lane" and "Cross-dock or fast-turn staging area". |
| b | `transferlane`, `automationlane`, `gate` must be FALSE | Not receipt destinations; `gate` is truck loading. |
| c | **not** a pick face (`locationAreaRepository.findById(dest.getAreaId())` → `Boolean.TRUE.equals(area.getUseforpicking())` ⇒ **reject**) and **not** fix-assigned (`fixLocationAssignmentRepository.findByAssignedlocationId(dest).isEmpty()`) | **⚠ DROPPED 2026-08-08 (Q12 → iv-b) — NOT to be implemented as a write-time reject; see the box below. Historical text follows.** ~~Absolute at all three scopes~~ — tier 1 included, and this was load-bearing for D15: together with P2.5 it is what makes "direct placement for tiers 2/3 only" true *by construction* rather than by a runtime gate that does not exist. Note the two clauses are not redundant — a pick face need not carry an assignment. **⚠ SUPERSEDED 2026-08-08 by SBDEV-2821's option (iii) — see the box below.** The old hand-off read *"SBDEV-2821 relaxes this for tier 1 only, alongside P2.5"*, which assumed 2821 would ship tier-1 direct placement. It will not. |

> [!done] **✅ Q12 ANSWERED 2026-08-08 — option (iv-b), SPLIT: configure anywhere; place everywhere EXCEPT pick faces.**
>
> **Configuration (write-time) — relaxed, with ONE narrow exception.** Any tier may name any location putaway
> can legitimately receive into, **pick faces included** — except that **tiers 2/3 may not target a
> `flowbin`-type location** (P2.7 rule **e**), because putaway auto-creates a `FixLocationAssignment` binding
> it to the first SKU and multi-SKU scopes then break. **Tier 1 is exempt, and club lanes are unaffected**
> (they are `cases and pallets`, not `flowbin`). P2.1–P2.4 and P2.6 still reject locked, shipping, transfer and gate
> locations — wrong destinations for putaway too. **P2.7(c)'s absolute pick-face / fix-assignment reject is
> dropped at all three scopes.**
>
> **Placement (run-time), when `carrier == null` — split on one predicate:**
>
> | Resolved destination | Receiving does | Then |
> |---|---|---|
> | **pick face** — `area.useforpicking == TRUE` **OR** `location_type.sltname == 'flowbin'` | **does NOT place** — receipt goes to the standard putaway lane | destination consumed at **putaway** (SBDEV-2821) |
> | anything else — staging, goods-in, cross-dock | **places directly**, as today | no putaway step |
>
> **Why split rather than uniform.** Cross-dock and staging lanes genuinely want the stock placed immediately —
> that is the ticket's "fast-turn" intent — and they carry none of the pick-face risk. Uniform (iv-a) would
> have silently dropped that. The split costs one predicate at one call site.
>
> **The club use case ships — but NOT on this plan alone.** Club lanes are pick faces (`useforpicking = true`,
> verified on `wsl-wineco-uat`), so a merchant default of `CLUB-A` is configurable and receiving diverts it to
> the lane. **No stock lands on a live 27-SKU pick face at receipt, and C2b stays unreachable.**
> 
> ⚠ **But two other things must ship before it works end to end, and neither is in this plan's original scope:**
> 1. **`MobilePutAwayService` must handle `cases and pallets`.** Its switch covers only `flowbin`, `overstock
>    box` and `overstock pallet` (`WmsConstants:736-738`); `cases and pallets` is a fourth constant (`:741`)
>    and falls to `default:`, which **throws** for club locations. **Owned by SBDEV-2821 §3.2a** as of
>    2026-08-08. Until it ships, a club destination saves, diverts, and then **throws at putaway**.
> 2. **Putaway must offer the destination for tiers 2/3** — SBDEV-2821 surfaces it for tier 1 only.
>    **Step 17a of this plan**, and it depends on 2821 merging first.
> 
> Earlier revisions of this box asserted the club case *"ships, safely"* on this plan alone. **That was
> false** — it assumed `storeBoxOnLocation` already handled the type, which it does not.
>
> *Provenance: (iv-b) chosen by the ticket owner (Nam Park) 2026-08-08, following SBDEV-2821's option (iii).
> Put to @David Oppenheim and @Brent Campbell on the ticket the same day; **no reply recorded yet.** If either
> objects, Q12 reopens — options (i)–(iii) and (iv-a) are preserved in §10.4.*
>
> **⚠ THE RELAXATION AND THE GATE ARE ONE CHANGE.** P2.5/P2.7(c) were absolute for exactly one stated reason —
> *"`ReceivingService.java:454-457 → :491` places tier-1 destinations unconditionally… refusing the config is
> the only thing that keeps the deferred path unreachable."* Under (iv-b) the runtime gate replaces that
> mechanism, so **the gate must land in the same change as the relaxation.** A 2026-08-04 revision relaxed the
> predicates while the placement path stayed ungated and was reverted the same day (§12) — the failure mode is
> identical, and it is SBDEV-2731's reported bug. `pickFaceDestinationIsNotPlacedAtReceipt` (step 15) is the
> test that keeps them coupled.

> **"Not a pick face" is `location_area.useforpicking`. Added 2026-08-06 — until then this clause had NO
> implementable predicate anywhere in this plan, while §7.1 mandated a test (`skuWriteRejectsPickFaceDestination`)
> that could not be written.** Only the fix-assignment clause was concrete, so in practice P2.7(c) enforced
> half of what it claims and D15's by-construction guarantee rested on that half.
>
> `useforpicking` is this codebase's existing answer to "is this a pick face", not a new invention:
> `MobilePickingService.java:1193`, `StockunitRepository.java:119,134,149,248`,
> `ReplenishmentMonitorViewRepository.java:73`, and — decisively — **SBDEV-2854** adopts exactly this axis
> for the mirror-image question on the replenishment side (`isPickingArea`, destination `useforpicking` ::
> source `useforreplenish`). Using the same column keeps the two features from answering "can this location
> take stock" differently.
>
> **SBDEV-2854 also proves the gap was populated, not theoretical.** Its `db_verified` data records **70
> wineco club locations** in area *"Storage and Picking"* with `useforpicking = true` and **zero**
> `FixLocationAssignment` rows — FLA-free pick faces at scale on a client tenant. `Club01` (id 225748) clears
> P2.3 (no lane flags), P2.5 (no FLA) and P2.7(c)-as-previously-implementable. Since **direct placement ships
> for tiers 2/3 in this plan**, a warehouse- or merchant-scope default pointed at a club location would have
> put receipts straight onto a live pick face — a route none of the SBDEV-2821 hand-off warnings cover,
> because those are all written about *tier 1* and about *relaxing* P2.5/P2.7(c). Nothing is relaxed here;
> the predicate simply never existed.
>
> **MEASURED 2026-08-06 — the hazard is LIVE, including on production.** `Storage and Picking` carries
> `useforstorage = TRUE` **and** `useforpicking = TRUE`, so club locations clear P2.4. Verified SELECT-only:
>
> | Tenant | `useforstorage` | Locations in picking areas | **FLA-free (the exposed set)** |
> |---|---|---|---|
> | `wsl-wineco-uat` | TRUE (area 51553) | 2,219 | **726** |
> | `wms2-wineco-dev` | TRUE (area 51553) | same area config | same shape |
> | **`wms2-hydra` (HMG/NYWH PRD)** | **TRUE** | 191 | **58** |
> | `wms2-hydra-v2t` (fresh-seeded) | — no picking area is also storage/goods-in | 0 | **0** |
>
> `Club01`–`Club08` (ids 225748+) each read: area 51553, all five lane flags FALSE, `entity_lock = 0`,
> **`fla_rows = 0`** — so they pass P2.2, P2.3, P2.4, P2.5 and P2.7(c)-as-previously-implementable, every one.
>
> **The exposed set is 726 locations on wineco UAT and 58 on HMG production — not the ~70 clubs inferred from
> SBDEV-2854's plan.** Any of them was a legal tier-2/3 default under the old predicate set, and tiers 2/3
> ship direct placement.
>
> **Why this was missed, and the lesson for every future P2 measurement:** §3.4c's P2.7 "CORRECTION" was
> measured on `wh01_hydra_v2t` — the fresh-seeded copy, and per the last row **the one tenant that
> structurally cannot exhibit this**. A predicate validated only against fresh-seed data is validated
> against the case that cannot fail. **Re-run every P2 measurement against a migrated tenant (`wineco`,
> `hydra` PRD) as well as `v2t`.** Reproduce with:
> ```sql
> SELECT a.name, a.useforgoodsin, a.useforstorage, a.useforpicking, count(*) AS locations,
>        count(*) FILTER (WHERE f.id IS NULL) AS fla_free
> FROM location l JOIN location_area a ON a.id = l.area_id
> LEFT JOIN fix_location_assignment f ON f.assignedlocation_id = l.id
> WHERE a.useforpicking = true GROUP BY 1,2,3,4 ORDER BY 1;
> ```
| d | P2.4's area test is **relaxed for tiers 2/3**: a staging or cross-dock lane qualifies **regardless** of its area's `useforgoodsin`/`useforstorage` flags | Measured necessity, not preference — see the correction immediately below. |
| **e** | **tiers 2/3 may NOT target a `flowbin`-type location** (`location_type.sltname == 'flowbin'` ⇒ reject). **Tier 1 is exempt.** | **ADDED 2026-08-08.** Not a placement rule — a *multi-SKU* rule, and the only restriction (iv-b) reinstates. See the box below. |

> [!warning] **Why rule (e) exists — FLA auto-creation binds a location to ONE SKU, permanently.**
>
> (iv-b) widened configuration at every scope, which re-opened a hazard that P2.5's absolute reject had been
> closing **as a side effect**. It is not a placement problem — the runtime gate handles that — so removing
> the gate's justification did not remove this.
>
> **The mechanism.** A tier-2/3 default resolves to an FLA-free flowbin. Receiving diverts it to the lane
> (step 15). At putaway, `MobilePutAwayService.storeBoxOnLocation:479-482` **auto-creates** a
> `FixLocationAssignment` binding that location to **whichever SKU is put away first**. The table carries
> `UNIQUE (assignedlocation_id)` **and** `UNIQUE (itemdata_id)`
> (`V2.2.00__base_v2_schema.sql:3760-3763`, `:3712-3715`). **Every subsequent SKU under that default then
> fails** — at `verifyScannedLocation:430-444` or `UnitloadBusinessService:180-183`.
>
> **Blast radius is the whole scope, not one SKU.** A merchant default applies to every SKU that merchant
> receives; the first one silently claims the bin and the rest break. A warehouse default is worse.
>
> **Measured exposure** (SELECT-only, 2026-08-08), FLA-free flowbins reachable as a tier-2/3 destination:
>
> | Tenant | flowbin (FLA-free) | `cases and pallets` (FLA-free) |
> |---|---|---|
> | `wms2-hydra` (HMG PRD) | **46** | 0 — none exist |
> | `wsl-wineco-uat` | **656** | 70 (the club lanes) |
>
> **Why tier 1 is exempt, and why this costs the club use case nothing.** A *SKU-scope* default binding its
> own location to itself is precisely the intent — that is what a dedicated `ICE PACK` bin **is**, and it is
> the runtime rule already (`UnitloadBusinessService.java:170-175` rejects only on SKU *mismatch*). And the
> club lanes are **`cases and pallets`, not `flowbin`** — `storeBoxOnLocation` never reaches the FLA branch
> for them, so they are unaffected by rule (e). **The 656 hazardous locations are excluded; the 70 clubs are
> not.** Rule (e) closes the hazard without touching the use case Q12 was asked about.
>
> **Do not implement this as "reject pick faces at tiers 2/3."** That would re-ban the clubs and undo Q12.
> The predicate is the **location type**, not the area flag: `sltname == 'flowbin'`.

**CORRECTION — the first version of P2.7 was self-defeating, and the data proves it.** It said "restricted
to staging / goods-in area types" while P2.3 rejected any location with `staginglane = TRUE` and P2.4
required the *area* to be `useforgoodsin OR useforstorage`. Measured on `wh01_hydra_v2t` (all 35 locations
joined to their areas): all **6** staging lanes sit in areas that are **neither** goods-in nor storage, so
they failed P2.4 *and* were banned outright by P2.3; the only P2.4-passing locations were the **3**
goods-in ones — the Inbound area, which contains `PutAwayLane` itself. **Under the three predicates
together a merchant or warehouse default could be set to essentially nothing except the tier-4 lane it
would have fallen through to anyway.** That is tension T1 recurring one predicate later: the gate that
makes pre-mortem P3 survivable is again the one that makes the tier settable only to what you already had,
and it banned precisely the two scenarios the ticket names. Rules (a) and (d) above are the fix.

**Recompute the admissible set per tenant before implementing** — as §3.4c already does for D11. If it is
still ≈1 on a real tenant, D13 needs rethinking rather than documenting. *(Caveat: `wh01_hydra_v2t` is a
35-location fresh-seeded copy and is not PRD-representative; the contradiction was between three
predicates over two columns, not an artifact of that data.)*

Tier 1 (SKU) is **exempt** from (a), (b) and (d).

> **⚠ SUPERSEDED 2026-08-08 (Q12 → iv-b).** This paragraph read *"exempt from (a), (b) and (d) — **but NOT
> from (c)**, deliberately. Rule (c) is the D15 enforcement point: tier 1 … may not target a pick face or a
> fix-assigned location while tier-1 placement is deferred."* **Rule (c) is now dropped at ALL scopes, tier 1
> included** — see the canonical P2.5 row in this section's table. Tier-1 placement is not "deferred" any
> more; under (iv-b) **no** tier is directly placed at a pick face, so the write-time reject that stood in
> for a runtime gate is gone and the gate itself does the work (§5.2 step 15).
>
> *(Historical note retained: a 2026-08-04 revision briefly added (c) to this exemption list and was reverted
> the same day — because at that time the placement path really was ungated. It is gated now. See §12.)*

**Why.** SBDEV-2731's Architect review found (F3) that `FixLocationAssignment` carries
`lowerbound`/`middlebound`/`upperbound` (`model/FixLocationAssignment.java:19,22,25`), seeded **36 / 60 /
84 on PRD**, and that `transferStockToUnitLoad` has **no capacity gate anywhere**. So a 1,000-unit receipt
directed at that pick face loads it to roughly **12x its configured ceiling**, after which replenishment
logic keyed on those bounds sees a permanently over-bound bin. Its verdict: *"receive 1,000 ice packs
directly into a pick face may be the wrong operation regardless of which primitive is used."*
D2 direct placement does exactly that, and this plan had **no capacity concept at all**.

Restricting tiers 2/3 to staging / goods-in areas is where the ticket's club and fast-turn use cases
actually live — so no business capability is lost. It also **subsumes the H1 lock mitigation**: keeping
receiving off live pick faces is the same outcome the tiered picker was reaching for, so implement it
once, here, and have §3.11.2's picker simply reflect it for merchant/warehouse scope.

> **D13's justification changed on 2026-08-04 — keep the rule, drop the reason.** D13 was originally
> justified as *"sidesteps F3 without inventing a capacity subsystem."* SBDEV-2796's answer (c) makes
> bounds advisory at receive time, so **there is no longer an F3 to sidestep** and that argument no longer
> supports anything. D13 should stand on its two surviving grounds — it is where the named use cases live,
> and it subsumes the H1 lock mitigation — **not** on capacity. Anyone revisiting D13 must not resurrect
> the F3 rationale.

> **RESOLVED 2026-08-04 — capacity is deliberately NOT handled, by product decision.**
> Tier 1 is exempt because a SKU-level override is the operator's explicit per-SKU choice. **The reported
> ICE PACK failure is precisely that case** — 1,000 units into a flowbin pick face via a tier-1 override.
>
> [SBDEV-2796](https://app.clickup.com/t/868kk4rmv) answered the F3 / Q5 product question with
> **(c): the pick face is a valid destination and the bounds are advisory for receiving.** So:
>
> - **No capacity gate is built.** `FixLocationAssignment.lowerbound`/`middlebound`/`upperbound` are
>   **not** consulted before `transferStockToUnitLoad`. A 1,000-unit receipt into an 84-capacity bin
>   **succeeds**, and the resulting ~12× over-bound bin is an **accepted state**, not a defect.
> - **The tier-1 block is lifted.** Direct placement may ship for tier-1 destinations. *(The block was
>   written as "blocks Phase 1b"; that split no longer exists — §5.2 — and direct placement is in
>   Phase 1-API.)*
> - **(c) obliges this plan to document the accepted state**, which is what this block now does, and to
>   surface it: the over-bound outcome must be visible in the §3.13 metrics/log so an over-bound bin is
>   *observable* even though it is permitted. Silence was never part of the decision.
>
> ⚠ **What (c) did NOT answer, and what therefore still gates the tier-1 path.** Two SBDEV-2796
> acceptance criteria survive its own answer:
>
> 1. **Replenishment behaviour against a permanently over-bound bin is still undefined.** Replenishment
>    keys off the very bounds (c) just made advisory for receiving — `recalculateForItem` maintains orders
>    from them. (c) makes over-bound bins reachable *and* permanent, so the "or make them unreachable"
>    escape is gone. **Nobody owns this.** Referred back to the B/A — §8.4.
> 2. **C2b** — the destructive `Goodsreceiptposition` repointing — is neither resolved nor ruled out by
>    (c). It is now **live and blocking** for the surviving Fix B work. See §5.2 D14 IMPORT LIMIT and §6.
>
> **DEFERRED under D15 (2026-08-04).** Rather than absorb (1) and (2), the author deferred the whole
> tier-1 pick-face path to a follow-up ticket — **[SBDEV-2821](https://app.clickup.com/t/868km8j9z)**. **This
> plan therefore ships direct placement for tiers 2/3 only**, and neither (1) nor (2) gates it — no pick-face placement means no over-bound bin and no
> repointing. Both travel to the follow-up, along with C2b, Q1, Q4, F1, F4 and F5. The P2.5 / P2.7(c)
> corrections below still land here, so the follow-up inherits a validator that admits the configuration
> (c) authorises.

**P2.6 is what moves the failure out of the receipt and into the config dialog.** `adviceposition.unitloadtypeId` is derived from `itemdata.getDefultypeId()` (`ReceivingService.java:227 → :236`, `:279 → :288`), so the incompatible pair *(SKU's default unit-load type, configured destination's location type)* is fully determinable **before any receipt exists**. It does not make the failure class unreachable — D11 deliberately lets an admin accept a partially-incompatible destination — but it does guarantee nobody meets it for the first time mid-receipt.

**Per-scope rule (D11):**

- **SKU scope** — one pair: `P1(destination.typeId, itemdata.defultypeId)`. Exact, and an
  **absolute reject**. Blast radius is one SKU, so there is nothing to trade off.
- **Merchant scope** — evaluate against `SELECT DISTINCT defultype_id FROM itemdata WHERE client_id = ?`.
  Return the **count of incompatible SKUs** and one example. **Reject outright only at 100 %
  incompatibility**; otherwise accept on **explicit admin confirmation**
  (`PUT …?confirmIncompatibleSkus=<n>` must match the count the **writer** recomputes at write time — not
  merely the count the preview returned — so a stale confirmation cannot slip through. §3.5a).
- **Warehouse scope** — same, against `SELECT DISTINCT defultype_id FROM itemdata`.

**Why count-and-confirm rather than an absolute reject.** The live allow-list is narrow —
`flowbin→PickLocation` only, `overstock box→Case` only, `totes→Tote` only, `packages→Package` only — so on
a tenant with a normal Case/Pallet/Tote/Package mix the only location types compatible with *every* SKU
are the fail-open ones (`System`, `NoRestriction`) and `cases and pallets`. **On `wh01_hydra_v2t` that is
exactly `PutAwayLane`'s own type (7).** An absolute reject would therefore make the warehouse tier
settable only to something type-equivalent to the lane you already had — turning "ships inert"
(pre-mortem P2) from a rollout risk into a *structural certainty*. Count-and-confirm keeps the write-time
gate loud without making the feature unusable.

**Admissible-set size.** On `wh01_hydra_v2t`,
`location_type` has 8 rows; the types compatible with all of `{Case, Pallet, Tote, Package}` are
`{System, NoRestriction, cases and pallets}` = **3 of 8**, and only one of those three is a location an
operator would plausibly choose. Under D11 the admissible set becomes *every* location type, ranked by
incompatible-SKU count, with 100 %-incompatible ones still refused. **Implementation note:** compute this
per tenant at validation time — do not hard-code 3/8, which is one tenant's arithmetic.

**Scope limit on the relaxation.** D11 relaxes the **unit-load-type compatibility** predicate only. A
**locked** destination (`entityLock != NOT_LOCKED`) remains an **absolute reject at all three scopes**,
validated at write time for merchant and warehouse as well as SKU.

> **⚠ CORRECTED 2026-08-08 (Q12 → iv-b).** This paragraph also listed a **fix-assigned** destination as an
> absolute reject, on the reasoning that it "can never work for any SKU". **That is no longer true and is no
> longer the design.** P2.5 is **dropped** — see its canonical row in the §3.4c table, which is the single
> authoritative statement of its status. A fix-assigned destination is a legal configuration at every scope;
> what is refused is the *placement*, by the runtime gate (§5.2 step 15). **Do not restate P2.5's status
> anywhere else in this document — reference the §3.4c row.** Restating it is how it came to be asserted
> three different ways by two editors working the same file on 2026-08-08. **Lanes are NOT in that list — P2.3 is not absolute.** P2.7 rules (a) and (d) deliberately
*permit* `staginglane` and `crossdockinglane` for tiers 2/3 (they are the ticket's named club-assembly and
cross-dock use cases) while (b) still bans `transferlane`, `automationlane` and `gate`. So the correct
statement is: **locked and fix-assigned are absolute at all three scopes; lane handling is per-tier.**
*(Corrected 2026-08-04 — the old "a lane can never work" wording predated P2.7(a)/(d) and contradicted them.)* Without that, a merchant or warehouse default on
a locked or fix-assigned location passes validation and then hard-fails *every* receipt in scope with
`STORAGELOCATION_LOCKED` / `WRONG_ITEMDATA_FIXASSIGNMENT` — messages that never mention putaway
configuration.

**The incompatible-SKU count is also the config-health signal** that D3 asked for and D6's switch to
hard-fail dropped. It is surfaced by the preview endpoint (N10) and rendered by §3.11.2 and §3.11.3.

### 3.5 Config-write services — the validated, audited writers

**Rationale.** The ticket's "changes are recorded in an audit log" and "precedence in ONE shared service" ACs both require that *every* write funnels through one place. Three typed writers, one per tier, all in a new `service/PutawayConfigService.java`:

```java
@Service
public class PutawayConfigService {

    public enum Scope { SKU, MERCHANT, WAREHOUSE }

    @PreAuthorize(Authority.IS_SB_ADMIN)                      // §3.12 — the authorization boundary
    @Transactional(value = "tenantTransactionManager",
                   rollbackFor = {BusinessException.class, FacadeException.class})
    // N-4: takes the LOADED ENTITY, not an id. The reused key expressions are
    // `…+':id:'+#itemData.id` and `…+':'+#itemData.clientId+':'+#itemData.itemNr`
    // (ItemdataService.java:62-67) — SpEL binds them to a parameter *named* `itemData` of type
    // Itemdata. With the old `(Long itemdataId, …)` signature neither expression can resolve and
    // every SKU write throws SpelEvaluationException at runtime. Load via
    // `itemdataRepository.findById` (never `itemdataService.getById`, which is @Cacheable — L1).
    @Caching(evict = { /* the two itemdata keys from ItemdataService.java:62-67, verbatim */ })
    public Itemdata setSkuDestination(Itemdata itemData, Long locationIdOrNull) throws BusinessException;

    @PreAuthorize(Authority.IS_SB_ADMIN)
    @Transactional(value = "tenantTransactionManager",
                   rollbackFor = {BusinessException.class, FacadeException.class})
    // N-4: same defect, worse — §3.3's key is `…+':'+#client.clNr`, so a `(Long clientId, …)`
    // signature makes `#client` unresolvable and EVERY merchant write throws.
    @Caching(evict = { /* the two clients keys from §3.3, verbatim */ })
    public Client setMerchantDestination(Client client, Long locationIdOrNull) throws BusinessException;

    @PreAuthorize(Authority.IS_SB_ADMIN)
    @Transactional(value = "tenantTransactionManager",
                   rollbackFor = {BusinessException.class, FacadeException.class})
    @CacheEvict(value = "sysprops",
        key = "T(net.aim_ai.wms.landlord.config.TenantContext).getCurrentTenant()?.getFacilityCode() + ':' + T(net.aim_ai.wms.service.WmsConstants).SYSTEM_PROPERTY_DEFAULT_PUTAWAY_LOCATION_KEY")
    public Sysprop setWarehouseDestination(Long locationIdOrNull) throws BusinessException;
}
```

Each method: (1) read the **previous** value, (2) run **P2** for its scope when `locationIdOrNull != null`, (3) write, (4) call `PutawayConfigAuditService.record(...)`, (5) `metrics.configChanged(scope, channel)`. `locationIdOrNull == null` clears the override — no validation needed, still audited. The warehouse writer writes `sysvalue = ''` for a clear (never a DELETE), creates the row if the `V2.2.11` seed has not run yet, and refreshes `description` with the resolved location name.

**Three further members exist for the event handler (§3.9), on the same bean:** `readCommittedDestination`, `validateOnly` and `auditAndEvict`. `validateOnly` also carries `@PreAuthorize(Authority.IS_SB_ADMIN)` — it is the authorization boundary for the HAL channel (§3.12).

**Existing-code cleanup carried here (§0.1 rows 13, 14):**

- `service/ItemdataService.setPutAwayLocation` (`:68-76`) is **promoted, not deleted** — it already carries the correct targeted 2-key `@CacheEvict` at `:62-67` that `ItemDataController.java:80` gets wrong. It is rewritten to delegate to `PutawayConfigService.setSkuDestination` and its `locationRepository.findById(itemData.getPutawaylocationId())` at `:71` gains a null guard (the previous value is now legitimately `NULL`).
- `controller/ItemDataController.java:80` — `@CacheEvict(value="itemdata", allEntries = true)` **flushes every tenant's entries**. Replaced by delegation to `ItemdataService.setPutAwayLocation`, so the correct 2-key eviction applies. The `@GetMapping`-that-mutates smell at `:81` is **left as-is** — the web UI calls it, and changing the verb is a breaking API change outside this ticket's scope (§10 Q5).

### 3.5a `PutawayConfigController` — the typed write surface

**Why this exists.** It is the **only** caller of the three writers above, and the UI writes every tier
through it (§3.11.2, §3.11.3). Without it those writers would be dead code — the exact smell §1 condemns
in `ItemdataService.setPutAwayLocation` — their `@CacheEvict` would never fire, and the only live write
path would be the silently-registered event handler.

**It is also where D11's count-and-confirm lives, and it can live nowhere else.** Spring Data REST's
`RepositoryEntityController` **ignores unknown query parameters**, and a `@HandleBefore*` handler receives
only the entity — it cannot see `?confirmIncompatibleSkus=<n>` without injecting `HttpServletRequest` into
the handler bean, which would also break the keep-it-CGLIB constraint in §3.9.4.

```java
@RestController
@RequestMapping("/putawayConfig")
public class PutawayConfigController {

    // ---- PREVIEW (N10). Read-only. Drives D11's count-and-confirm AND the picker's health signal.
    // Not admin-gated: it reveals no more than the location list the picker already shows.
    @GetMapping("/preview")
    @Transactional(value = "tenantTransactionManager", readOnly = true)   // §3.1.5 facade rule
    public PutawayConfigPreview preview(@RequestParam PutawayScope scope,
                                        @RequestParam(required = false) Long subjectId,
                                        @RequestParam Long locationId) throws BusinessException;
    // { locationId, locationName, compatible, incompatibleSkuCount, totalSkuCount,
    //   exampleIncompatibleSku, blockingReason }   // blockingReason: LOCKED | FIX_ASSIGNED | LANE | null

    // ---- WRITES. All three admin-gated, all three delegate to PutawayConfigService.
    @PutMapping("/sku/{itemdataId}")
    @PreAuthorize(Authority.IS_SB_ADMIN)
    public void setSku(@PathVariable Long itemdataId,
                       @RequestParam(required = false) Long locationId)    // omitted ⇒ clear
            throws BusinessException;

    @PutMapping("/merchant/{clientId}")
    @PreAuthorize(Authority.IS_SB_ADMIN)
    public void setMerchant(@PathVariable Long clientId,
                            @RequestParam(required = false) Long locationId,
                            @RequestParam(required = false) Integer confirmIncompatibleSkus)
            throws BusinessException;

    @PutMapping("/warehouse")
    @PreAuthorize(Authority.IS_SB_ADMIN)
    public void setWarehouse(@RequestParam(required = false) Long locationId,
                             @RequestParam(required = false) Integer confirmIncompatibleSkus)
            throws BusinessException;
}
```

**Callers load the entity, then pass it (N-4).** `PutawayConfigController` takes `@PathVariable Long
itemdataId` / `clientId`, but `PutawayConfigService.setSkuDestination` / `setMerchantDestination` take the
**loaded entity** so their reused `@CacheEvict` SpEL (`#itemData.id`, `#client.clNr`) can bind. The
controller therefore loads via `itemdataRepository.findById` / `clientRepository.findById` — **never**
`itemdataService.getById`, which is `@Cacheable` and would hand back a cached instance the writer then
mutates in place before eviction fires. Do not "simplify" the writers back to id parameters: that is a
runtime `SpelEvaluationException` on every write, not a style preference.

**The confirmation contract (D11).** For MERCHANT and WAREHOUSE scope the writer recomputes the
incompatible-SKU count itself and compares it to `confirmIncompatibleSkus`:

| Situation | Result |
|---|---|
| count == 0 | write proceeds; `confirmIncompatibleSkus` ignored |
| count > 0, param absent | **409** + the count + one example SKU — "re-issue with `confirmIncompatibleSkus=<n>`" |
| count > 0, param == recomputed count | write proceeds; the count is recorded on the audit row |
| count > 0, param ≠ recomputed count | **409** — the SKU set changed between preview and write; **stale confirmations must never slip through** |
| count == total (100 % incompatible) | **422**, unconditionally — no confirmation can override it |
| destination locked | **422**, unconditionally — absolute at all three scopes (P2.1, §3.4c) |
| destination **fix-assigned**, or a **pick face** | **accepted — no longer a write-time reject.** ⚠ CHANGED 2026-08-08 (Q12 → iv-b): P2.5 and P2.7(c) are relaxed at all three scopes; the configuration is legal and the **placement** is what is refused, by step 15's `useforpicking` gate (§3.4c) |
| destination is a `transferlane` / `automationlane` / `gate` | **422**, unconditionally (P2.7(b)) |
| destination is a `staginglane` / `crossdockinglane` | **422 at SKU scope** (P2.3); **permitted at merchant/warehouse scope** (P2.7(a)+(d)) — per-tier, not absolute |

Recomputing rather than trusting the preview is the point: the two calls are separated by however long the
admin spent reading the dialog, and SKUs can be created in between.

**HAL is not closed off, and must not be.** The `@RepositoryEventHandler` (§3.9) still guards
`PATCH /v3/itemdata/{id}` and friends, whether the write comes from a script, an integration or a stale
client — that is what makes the "ONE shared service" and audit ACs true. HAL writes simply cannot carry a
confirmation, so they get the strict rule; see §3.9.8.

**`setWarehouse` is the only write path for `DEFAULT_PUTAWAY_LOCATION`.** The two direct-save methods on
`SystemPropertyController`'s two direct-save endpoints are closed against this syskey, and the SDR delete is accepted but audited — §3.9.1.

**Phase placement.** `setSku`, `setWarehouse` and `preview` are **Phase 1** (no schema dependency: tier 3
is a sysprop row, and a missing row already reads as "not configured", §3.4a). `setMerchant` is
**Phase 1** — `client.defaultputawaylocation_id` does not exist until `V2.2.11` (ordering hazard O2).

### 3.6 The actionable message (D6) and the error envelope

#### 3.6.1 Two message keys, thrown from two different places

The raw-concatenated throw at `UnitloadBusinessService.java:191` serves **24 call sites**, only one of
which is receiving. Replacing it with a putaway-specific message would put a misleading remedy
("clear the configured putaway destination") in front of pickers, palletizers, truck loaders and transfer
operators. So the failure is reported by **two** keys:

| Key | Thrown from | Audience |
|---|---|---|
| `unitloadTypeNotPermittedOnLocation` | `UnitloadBusinessService.java:191` — the shared, context-free backstop for all 24 call sites | anyone moving a unit load anywhere |
| `putawayDestinationNotPermitted` | `PutawayDestinationResolver.requireCompatible(...)` — §3.1.3, and **nowhere else** | a receiving operator whose *configured* destination is wrong |

**`UnitloadBusinessService.java:180-193` becomes:**

```java
if (!locationConstraintService.isUnitloadTypePermitted(destinationLocation.getTypeId(), unitload.getTypeId())) {
    throw new BusinessException("unitloadTypeNotPermittedOnLocation",
            unitloadTypeRepository.findNameById(unitload.getTypeId()),             // %1$s
            destinationLocation.getName(),                                          // %2$s
            locationTypeRepository.findById(destinationLocation.getTypeId())        // %3$s
                    .map(LocationType::getSltname)
                    .orElse(String.valueOf(destinationLocation.getTypeId())));
}
```

> ⚠ **Corrected 2026-08-02 (architect + critic review of SBDEV-2731).** This block previously called
> `locationTypeRepository.findNameById(...)`, **which does not exist** — `repo/jpa/LocationTypeRepository.java`
> declares only `findBySltname` plus `CrudRepository`. The `findById(...).map(LocationType::getSltname)`
> form above is the one that compiles, and it is what SBDEV-2731 PR1 will actually write at `:191`.
> Note `unitloadTypeRepository.findNameById` **does** exist (`UnitloadTypeRepository.java:19`) — but it is a
> JPQL scalar projection and returns **null** for a missing id, so `%1$s` needs a non-id fallback rather
> than being passed straight through.

Three lookups, all name-only. **Do not** pipe `unitloadRepository.findLabelidById` or a remedy anchor into
this site: the neutral key has no remedy clause precisely because there is no configured destination in
the general case, and adding a fourth lookup here would cost a query on every one of the 24 call sites'
transfers.

**Keys in `src/main/resources/messages_en_US.properties`** (printf style, matching
`STORAGELOCATION_LOCKED=The location %1$s is locked. ( Lock code = %2$s ).` at `:287`):

```properties
# SHIPPED BY SBDEV-2731 PR1 (#133) — this plan CONSUMES it, does not author it.
unitloadTypeNotPermittedOnLocation=Unit load type %1$s is not permitted on location %2$s (location type %3$s).

# THIS PLAN'S key.
putawayDestinationNotPermitted=Cannot put away %1$s to location %2$s: a %3$s unit load is not permitted on a %4$s location. Change the configured putaway destination, or clear it so receiving falls back to %5$s.
```

> **⚠ The neutral key's TEXT changed on 2026-08-06 and this plan quoted the superseded version.** It read
> `A %1$s unit load is not permitted on location %2$s (location type %3$s).` — reworded by 2731's code
> review (finding #4, commit `89de3f0`) because it rendered *"A unknown unit load"* on the fallback path
> and *"A Inbound Pallet unit load"* for vowel-initial types. Corrected here 2026-08-06 against the
> as-shipped bundle (`messages_en_US.properties:342` on the #133 head).
>
> **The KEY NAME did not change**, so §5.1 prerequisite 0 and §3.6.1's two-key split are unaffected —
> only the rendered text moved. Any test or verify pattern asserting the *wording* must use the string
> above. This plan's `T-msg2` matches on `not permitted on location`, which is present in both, so it is
> unaffected either way.

Neither leaks a raw id. The putaway-specific key additionally names the **tier that was configured**
(`%1$s` = `Resolution.configuredFor()` — "SKU 12345" / "merchant WINE01" / "warehouse default") and the
**remedy anchor** (`%5$s` = `WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE`), which is exactly the context
the shared site does not have.

**`unit/service/UnitloadBusinessServiceUnitTest.java:193, 208` pins the current raw-ID text
(`.hasMessageContaining("not allowed on location")`) and WILL break by design. Update it to assert the
rendered `unitloadTypeNotPermittedOnLocation` content — never loosen the assertion to make it pass.** A
verify row asserts `putawayDestinationNotPermitted` appears in `PutawayDestinationResolver.java` and
**not** in `UnitloadBusinessService.java`.

#### 3.6.2 Error envelope

`ReceivingController.java:283-300`: `BusinessException` → `errors.add(getErrorMessage("Runtime Error", e.getMessage()))` (operator sees the text); `RuntimeException` → generic "contact support". **Every resolver and validator failure is a `BusinessException`.** A `ReceivingControllerUnitTest` case asserts a resolver rejection surfaces the message text, not the generic string.

> **`receiveGoods` has TWO callers, and only one is an operator. Added 2026-08-06 — this plan previously modelled only the first.**
>
> | Caller | Consumer | Error surface |
> |---|---|---|
> | `controller/ReceivingController.java:284` | a human at the receiving screen | the catch ladder above; 200-with-`errors` |
> | `service/ReturnAdviceAutoReceiveService.java:556` | **OMS — a machine** | its own catch at `ReturnAdviceAutoReceiveService:555-560` |
>
> The second path is return-advice auto-receive, shipped by **SBDEV-2778**, which this plan otherwise
> mentions only in connection with it taking Flyway `V2.2.09`.
>
> **Transactionally it is safe and needs no change** — state that plainly so nobody re-opens it:
> `executeInternal` is private and not `@Transactional`, but `receiveGoods` itself carries
> `@Transactional(value="tenantTransactionManager", rollbackFor={…})` at `ReceivingService.java:302`, so the
> `MANDATORY` resolver joins that transaction exactly as on the controller path. §7.7a row 1 covers it by
> construction. There is no C1-class defect here.
>
> **What is NOT covered is the error surface, and three of this plan's design commitments assume a human:**
> - §3.6's whole message design is *"name a remedy, not just the failure"* — `MSG-actionable` demands five
>   format args including a remedy clause. A machine cannot act on a remedy string.
> - **D10's "surface-and-warn, never block"** has no operator to warn on this path.
> - §8.2's blast radius and pre-mortem **P3** (the 200-with-`errors` detector trap) are both written for the
>   operator path only.
>
> **Required before Phase 1-API closes:** decide whether a resolver rejection on the auto-receive path should
> (a) fail the line and report to OMS, or (b) fall back to tier 4 and warn — and add the matching
> `ReturnAdviceAutoReceiveService` test. This is an unmodelled *production* entry point into the exact method
> §3.7 rewires; the risk is low but it is not zero, and it is cheap to close now.

### 3.7 Receiving wiring (D2)

> **Scope note (D15, 2026-08-04) — ⚠ SUPERSEDED 2026-08-08 by Q12 → (iv-b). Read the replacement first.**
>
> **Replacement:** everything in this section still applies to whatever destination the resolver returns, and
> there is still **no per-*tier* branch here** — but there is now exactly **one per-*destination* branch**:
> step 15's `useforpicking` gate. A pick-face destination is **not** placed here at any tier; it is diverted
> to the standard putaway lane and consumed at putaway (SBDEV-2821). Everything else is placed as this
> section describes. **This is not the duplicated receive-time check P2.6 warns against** — P2.6 forbids
> re-running the *config-write* predicate at receive time. This gate tests something write-time validation
> deliberately no longer tests, because (iv-b) permits the configuration.
>
> ~~"Direct placement for tiers 2/3 only" is enforced entirely at **config-write time** (P2.5 / P2.7(c),
> §3.4c), because `ReceivingService.java:454-457 → :491` already places tier-1 destinations unconditionally
> and adding a second gate here would duplicate the check at receive time — the anti-pattern P2.6 exists to
> avoid. Consequence to keep in mind while implementing: this section is *why* those two predicates must stay
> absolute until [SBDEV-2821](https://app.clickup.com/t/868km8j9z) ships.~~ **The enforcement point moved
> from write-time to run-time; the predicates are relaxed here, in this plan, in the same change as the
> gate.**

#### 3.7.1 Replace the ternary

`ReceivingService.java:451-459` becomes:

```java
Location spawnLocation = locationRepository.findByName(WmsConstants.STORAGE_LOCATION_SPAWN)
    .orElseThrow(() -> new BusinessException("entityNotFoundForName", Location.class.getSimpleName(), WmsConstants.STORAGE_LOCATION_SPAWN));

// SBDEV-2732 — resolved for BOTH branches (the old code resolved only when carrier == null,
// which is SBDEV-2731's root cause). Hoisted above the per-case loop at :462 deliberately:
// one resolution per receipt, and a bad destination fails before any unit load is created.
PutawayDestinationResolver.Resolution putaway =
    putawayDestinationResolver.resolve(itemdata, client, unitloadType.getId());
// `compatible` tag added so the carrier-path "surfaced but not applied" case is observable WITHOUT
// polluting wms2.putaway.resolution.rejected, which alerts on >0 as pre-mortem P3's indicator.
putawayResolutionMetrics.resolved(putaway.source(), carrier != null, putaway.compatible());

// SBDEV-2732 — THE ONLY call site of requireCompatible on the receiving path.
// Guarded by carrier == null because on the carrier path the resolved destination is never
// applied (§3.7.2), so a config error irrelevant to this receipt must not abort it (D10).
// Placed HERE, beside the hoisted resolve and ABOVE the per-case loop at :462 — NOT inside the
// fork — so a bad destination still fails before any unit load is created (§2.1's preserved
// property). Calling it inside the loop would fail on case 2..n after case 1 already existed.
if (carrier == null) {
    putawayDestinationResolver.requireCompatible(putaway);   // throws BusinessException naming tier + remedy
} else if (!putaway.compatible()) {
    LOG.warn("SBDEV-2732 carrier receipt: resolved destination {} (source={}) is not permitted for "
             + "unit-load type {}; destination surfaced but not applied. advicePosition={}",
             putaway.location().getName(), putaway.source(), unitloadType.getId(),
             adviceposition.getNumber());
    // No separate counter: the single resolved(...) call above already tags compatible=false,
    // so this case is queryable as resolution{carrier="true",compatible="false"}.
}
```

**This is the one place a `carrier == null` guard is correct.** Do not confuse it with the *resolution*
above, which must stay unguarded — a carrier-guarded `resolve(...)` is precisely SBDEV-2731's root cause.
Verify enforces both directions: `check_W_resolve_not_carrier_guarded` (resolution NOT inside the guard)
and `check_W_requirecompatible_carrier_guarded` (the hard-fail IS inside it).

The `Location`-not-found `BusinessException` currently thrown by the ternary at `:456` moves inside the resolver, where it can name which *tier* held the dangling id.

**Tests for this wiring** are listed in §7.1 under `ReceivingServiceUnitTest`:
`nonCarrierPathStillFailsOnIncompatibleDestination`, `carrierPathDoesNotFailOnIncompatibleDestination`,
`resolveIsCalledForBothBranches`, `resolverInvokedOnceAboveLoop`.

#### 3.7.2 The placement fork — and the honest limit of D2 on the carrier path

```java
if (carrier == null) {
    unitloadBusinessService.transferUnitLoadToLocation(unitload, putaway.location(), false,
            codeReceiving, adviceposition.getNumber(), null);
} else {
    unitloadBusinessService.transferUnitLoadToCarrier(unitload, carrier,
            codeReceiving, adviceposition.getNumber(), null);
}
```

The fork's *shape* is unchanged. Only `putaway.location()` replaces `putAwayLocation`.

**Decision, and it is a deliberate scope boundary.** On the **non-carrier** path, D2's direct placement is already the existing mechanism (§2.1) — the only change is the destination. On the **carrier** path, the unit load goes onto the carrier as today, and the resolved destination is **surfaced, not applied**:

> A carrier pallet is a physical pallet the operator is building at their workstation. Directing individual cases to distinct locations while they sit on one shared pallet is physically incoherent — and the pallet may hold SKUs from several merchants with different resolved destinations. Forcing the resolved destination here would either split the pallet or silently pick one SKU's destination for all of them.

So "honor" is discharged on the carrier path as: (a) the destination is resolved and returned by the display endpoint (§3.8) so the operator sees it before scanning; (b) a `WARN` is logged and `putawayResolutionMetrics.resolved(source, carrier=true)` records it when a **non-tier-4** destination is resolved for a carrier receipt; (c) the pallet's later putaway is where the destination applies, and `MobilePutAwayService.calculatePutAwayList` already suggests locations there. This satisfies SBDEV-2731's "should not silently ignore" (it is neither silent nor ignored) without inventing pallet-splitting. §9 A5 records the rejected alternative; §10 Q1 flags it for business confirmation.

#### 3.7.3 Inbound-pallet name checks (§0.1 rows 3, 4, 27)

`ReceivingService.java:601-612` compares a location name against `PutAwayLane` to decide inbound-pallet assignment, and `:634-637` moves the pallet back to the lane on unassign. Both are about **where the inbound pallet lives**, not where received stock goes, and both stay correct when a receipt's destination is not the lane. **Audited, unchanged.** `ReceivingController.java:314`'s raw literal set `{"PutAwayLane","InboundWorkstation","EmptyPallets"}` is replaced with `WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE`, `STORAGE_LOCATION_INBOUND_NAME` and the empty-pallets constant — a mechanical de-duplication so a future lane rename cannot silently break pallet listing.

#### 3.7.4 Mobile putaway (§0.1 rows 5, 5a, 6, 7, 33)

No code change. Four behavioural notes for §6:

- **The exception a direct placement actually produces is `unitloadNotInInboundArea`, not `unitLoadNotInPutAwayLane`.** `MobilePutAwayService.java:113-117` runs **first**: `if (!locationArea.getUseforgoodsin() && !storageLocation.equals(Clearing)) throw new BusinessException("unitloadNotInInboundArea")`. A unit load placed directly into a storage or pick area sits in an area with `useforgoodsin = false`, so it trips that guard and **never reaches** the lane check at `:119-126`. Any operator note, manual row or training material that names `unitLoadNotInPutAwayLane` for this scenario is wrong.
- `MobilePutAwayService.java:121-128` (`unitLoadNotInPutAwayLane`) still fires for a unit load that *is* in an inbound-flagged area but not on the lane itself — e.g. one moved to `InboundWorkstation`. Unchanged, and unaffected by this plan.
- **Correction path for a misplaced unit load.** Neither guard offers a remedy in the putaway screen, so an operator who scans a directly-placed unit load must move it with `MobileMoveUnitloadService` (mobile "Move Unit Load") or the web **Transfer Stock** screen (`transferStock.vue`). Naming that path is the answer to the long-open recoverability question: the unit load is not stuck, it is simply already at its destination and the putaway screen has nothing to do with it. Manual row **M13a** exercises the move; **M13** asserts the correct exception text.
- `MobilePutAwayService.java:190-206` `storePalletBackOnPutawayLane` is the **SBDEV-2102 fix**; its "pallet must be on the current user's location" guard must survive untouched. The verify script asserts it.

### 3.8 Receiving display — and a scope reduction against D8

**Finding.** `receiving_dto_view` already projects `defaultputawaylocationname` (`V2.2.00__base_v2_schema.sql:4663`, joined at `:4676` via `LEFT JOIN location loc ON loc.id = i.putawaylocation_id`), surfaced at `model/ReceivingDtoView.java:47, 173`, and `ReceivingDtoView` is already in `exposeIdsFor` (`RestConfiguration.java:42`).

**Therefore the view needs no change.** D8 assigned `receiving_dto_view` / `ReceivingDtoView` ownership to this plan on the premise that a view change was needed and only one plan could own it. The evidence says otherwise, and adding an *effective* destination to a SQL view would be actively worse: the four-tier precedence plus P1 compatibility is not expressible in the view's SQL, and a projected view column couples the view and the `ReceivingDtoView` entity into every future change (weaker than the original `ddl-auto=validate` claim — `ddl-auto` is `none` — but the coupling is real: any view change must land with the entity or reads break at runtime). D8's **substance** is honored unchanged — this plan owns the receiving-display contract and SBDEV-2731 must not be worked independently — while its **mechanism** shrinks to zero DDL. Net: one less migration statement, one less `ddl-auto` coupling.

**New endpoint** instead — and it **MUST NOT** call the resolver directly. `resolve(...)` is
`Propagation.MANDATORY` and controllers are not transactional; the facade and its rationale are in
**§3.1.5**. The controller delegates to that facade and maps the returned `Resolution` to the JSON
envelope:

```java
// controller/ReceivingController.java — delegates only, opens no transaction of its own
@GetMapping(path = "/getPutawayDestination/{advicePositionId}", produces = "application/json")
public Map<String, Object> getPutawayDestination(@PathVariable Long advicePositionId)
        throws BusinessException {
    // §3.1.5 facade supplies the tenant transaction the MANDATORY resolver requires
    return toEnvelope(putawayDestinationQueryService.describeForAdvicePosition(advicePositionId));
}
// envelope: { locationId, locationName, source, sourceLabel, configuredFor, compatible, warning }
```

The facade returns the domain `Resolution`, **not** the JSON map, so that `describeForClient(Long)`
(§3.1.5) can back `GET /client/{id}/effectivePutawayDestination` (N9, the merchant screen's inherited
value) without duplicating precedence logic. Each controller owns its own envelope mapping; neither
re-derives the tiers.

**One additional NEGATIVE verify check beyond §3.1.5's `check_N2_readonly_facade`:**
`check_N2_controller_delegates_not_resolves` — assert `putawayDestinationResolver` **never** appears in
`ReceivingController.java`. Without it, an implementer can satisfy every positive check by creating the
facade *and still* calling the resolver directly from the controller — which reintroduces the
`IllegalTransactionStateException` in §3.1.5 while the script stays green.

`source` is the enum name (`SKU_OVERRIDE` | `MERCHANT_OVERRIDE` | `WAREHOUSE_DEFAULT` | `STANDARD_PUTAWAY_LANE`) so Vue never re-derives the precedence; `sourceLabel` is the display string ("SKU override", "Merchant default", "Warehouse default", "Standard putaway lane"); `compatible` reports **P1** without throwing, so the form can warn *before* the operator commits a receipt; `warning` carries the rendered `putawayDestinationNotPermitted` text when `compatible == false`.

Resolved **per advice position**, not per list row — the open-receiving list can be hundreds of rows and N resolver calls there would be 1–4 queries each. Needs a `BaseControllerTest` subclass and a `SecurityConfiguration` review (it is a read under the existing `/receiving/**` rules).

### 3.9 Closing the Spring Data REST write hole (D7, extended to `Sysprop`)

**Rationale.** While `PATCH /v3/itemdata/{id}`, `PATCH /v3/client/{id}` and `PATCH /v3/sysprop/{id}` write unvalidated (`RestConfiguration.java:47` + `:55-60` register only bean-validation validators), the ACs "precedence lives in ONE shared service" and "changes are recorded in an audit log" are **literally unachievable** — and this is the most likely way the invalid Ice Pack configuration was created.

**Extension beyond D7's letter:** D7 names `Itemdata` and `Client`. `Sysprop` is added, because the **warehouse** tier is the highest-blast-radius tier (a bad value hard-fails receiving for *every* merchant) and `PUT /sysprop/{id}` is precisely what the existing generic admin dialog calls (`store/admin/configuration.js:73-93`). Guarding two of three holes would leave the worst one open. D7's own rationale already cites `PATCH /v3/sysprop/{id}` as unguarded.

**The handler guards SDR-shaped writes ONLY.** `@RepositoryEventHandler` methods fire only on events that
Spring Data REST's own `RepositoryEntityController` publishes. Any code that calls
`repository.save()` directly — from a controller, a service or a scheduled job — bypasses it completely,
silently, with no compile-time or startup signal. There are **17 direct `save()` calls on the three
guarded entities** across the codebase; this plan routes **one** of them (`ItemDataController.java:88-90`)
through `PutawayConfigService` and explicitly closes **three more** in §3.9.1. The remaining thirteen do
not touch a putaway destination field today; if one ever does, the handler will not see it. That is a
property of the mechanism, not a defect to be fixed here — state it so nobody later assumes the handler
is a universal invariant.

#### 3.9.1 Three write paths the handler does not cover

| Path | Why the handler misses it | Required change |
|---|---|---|
| `POST /v3/systemProperty/create` (`SystemPropertyController.java:47-90`, save at `:77`) | direct `syspropRepository.save()`, no SDR event | **Reject** `syskey == DEFAULT_PUTAWAY_LOCATION` with the standard 422 + a message pointing at `PUT /putawayConfig/warehouse`. |
| `POST /v3/systemProperty/updateValue` (`:93-120`, save at `:107`) | direct save, and it selects its target with `findBySyskey(key).get(0)` — the client-blind shape of landmine A3, on a write | **Reject** the same syskey, same message. (The client-blind selection is left alone; it is a pre-existing defect on other keys and out of scope.) |
| `DELETE /v3/sysprop/{id}` (SDR-exported; live button, `store/admin/configuration.js:125-147`, axios at `:127`) | the plan defines no delete handler, so the row could be removed unvalidated and unaudited | **D12 — accept the delete, audit it.** See below. |

**D12 — the decision on delete.** Deleting the `DEFAULT_PUTAWAY_LOCATION` row is **accepted**, not
refused. An absent row and a blank row are the same state to the resolver (§3.4a), so a delete can only
ever move tier 3 to "not configured" — the safe direction, and one the operator can already reach by
clearing the value. Refusing it would mean throwing from a handler and giving the operator an error on a
button that works for every other row, for no safety gain.

Two obligations come with accepting it:

1. **Audit it.** A `@HandleAfterDelete` on `Sysprop` — returning immediately unless
   `syskey == DEFAULT_PUTAWAY_LOCATION` — calls `PutawayConfigService.auditAndEvict(WAREHOUSE, …)` with
   `new_location_id = NULL`, so AC15 still holds. The **previous** value comes from a
   `@HandleBeforeDelete` that reads it and parks it on the same request-scoped carrier the save path uses
   (§3.9.6); that `Before` method performs no validation and never throws.
2. **Keep the key settable after it is gone.** Because `POST /v3/systemProperty/create` now rejects this
   syskey, an operator who deletes the row must not be locked out of re-creating it. §3.11.2 therefore
   renders the `DEFAULT_PUTAWAY_LOCATION` control **unconditionally** in Operation Options — driven by
   `PutawayConfigController`, not by the presence of a row in the `findByGroupname` list — and
   `setWarehouseDestination` **creates the row if it is absent**. Without this pairing, D12 is a trap:
   one click and the warehouse tier becomes unreachable from the UI until an operator runs SQL.

Every other syskey deletes exactly as it does today.

**Message parity.** All three rejections use the same rendered text as the HAL and typed channels, so an
operator meets one message for one mistake regardless of which screen produced it (§3.6.1).

Verify rows: `check_N1_syspropctl_create_guard`, `check_N1_syspropctl_updatevalue_guard`,
`check_N1_sysprop_delete_handler`. Manual rows **M9b** and **M9c**.

#### 3.9.2 Handler shape — create and save are separate methods

**New file:** `src/main/java/net/aim_ai/wms/config/PutawayConfigRepositoryEventHandler.java`

**`@HandleBeforeCreate` and `@HandleBeforeSave` MUST NOT share a method.** On a create the entity id is
`null`, so a shared method that reads the previous value by `incoming.getId()` binds `null` into
`where id = ?1`; with `getSingleResult()` that raises `NoResultException`, a `RuntimeException` that
breaks **every** HAL `POST` of `Itemdata`, `Client` and `Sysprop` — all three are exported
(`ItemdataRepository:18`, `ClientRepository:18`, `SyspropRepository:15`), so the blast radius is unrelated
master-data creation. On the create path there is genuinely no previous value: skip the read.

```java
@Component                      // NOT interface-implementing — see §3.9.4
@RepositoryEventHandler
public class PutawayConfigRepositoryEventHandler {

    // ---- CREATE: there is genuinely no previous value. Never read one. ----
    @HandleBeforeCreate
    public void onItemdataCreate(Itemdata incoming) {          // unchecked throws only — §3.9.3
        putawayConfigService.validateOnly(SKU, incoming, null);
    }

    // ---- SAVE: read the committed previous value, then validate the DELTA ----
    @HandleBeforeSave
    public void onItemdataSave(Itemdata incoming) {
        Long previous = putawayConfigService.readCommittedDestination(SKU, incoming.getId());
        if (Objects.equals(previous, incoming.getPutawaylocationId())) return;   // not a putaway write
        putawayConfigService.validateOnly(SKU, incoming, previous);
        pendingPreviousValue.put(SKU, incoming.getId(), previous);
    }

    // ---- AFTER: audit + evict, once the entity write has committed ----
    @HandleAfterCreate
    public void onItemdataCreated(Itemdata saved) {
        putawayConfigService.auditAndEvict(SKU, saved, null);   // previous_location_id = NULL, correctly
    }

    @HandleAfterSave
    public void onItemdataSaved(Itemdata saved) {
        putawayConfigService.auditAndEvict(SKU, saved, pendingPreviousValue.take(SKU, saved.getId()));
    }

    // Client: same four-method shape. Phase 1 only — Client.defaultputawaylocationId does not exist
    // until V2.2.11 (ordering hazard O2), so writing onClient* in Phase 1 will not compile.

    // Sysprop: same shape, plus @HandleBeforeDelete (reads the previous value, never throws) and
    // @HandleAfterDelete (audits the clear) per D12 / §3.9.1. Every method returns immediately unless
    // syskey == DEFAULT_PUTAWAY_LOCATION. Also reject a non-DEFAULT workstation row for that syskey
    // (landmine A6) — otherwise the generic admin dialog can create a row tier 3 never reads.
}
```

On the **create** path `previous_location_id = NULL` is the *correct* audit value — there genuinely is no
previous value, and this is the only case in which the `previous_value_unavailable` column is relevant
(§3.14; on the save path the read always succeeds, see §3.9.5).

```java
// service/PutawayConfigService.java — the committed-value read, save path only.
// ONE QUERY PER SCOPE. A single query parameterised only by id would make a HAL PATCH /v3/client/{id}
// read the ITEMDATA row whose id happened to equal the client id and audit it as that merchant's
// previous value — silent wrong data, no exception.
@Transactional(value = "tenantTransactionManager", readOnly = true)
public Long readCommittedDestination(PutawayScope scope, Long subjectId) {
    if (subjectId == null) return null;                      // create path: nothing to read
    final String sql = switch (scope) {
        case SKU       -> "select putawaylocation_id        from itemdata where id = ?1";
        case MERCHANT  -> "select defaultputawaylocation_id from client   where id = ?1";
        // WAREHOUSE is a sysprop row, not an FK: sysvalue is text and may be '' (landmine A2).
        // Blank-after-trim means "not configured", so it must read back as NULL here, not as 0.
        case WAREHOUSE -> "select nullif(trim(sysvalue), '')::bigint from los_sysprop where id = ?1";
    };
    Query q = entityManager.createNativeQuery(sql);
    q.setParameter(1, subjectId);
    List<?> rows = q.getResultList();                        // getResultList, ONCE — never getSingleResult
    if (rows.isEmpty() || rows.get(0) == null) return null;
    return ((Number) rows.get(0)).longValue();
}
```

#### 3.9.3 Validate the DELTA, never the state

Every `@HandleBefore*` method **returns immediately when the putaway destination field is unchanged**:

```java
Long previous = putawayConfigService.readCommittedDestination(scope, incoming.getId());
if (Objects.equals(previous, incomingDestination)) return;   // not a putaway write — do not validate
putawayConfigService.validateOnly(scope, incoming, previous);
```

**Why this is load-bearing.** Validating the *state* rather than the *delta* would make **every** HAL
`PATCH /v3/itemdata/{id}` — changing *any* field — re-run P2 against the SKU's **existing** destination,
and likewise for `PATCH /v3/client/{id}`. That turns config rot into an **edit lock**: the NYWH `Itemdata`
row pointing at `Ice Pack` — the row this entire ticket exists because of — would become un-PATCHable for
*any* field, and a location that later acquires `entity_lock != 0` would brick HAL edits for every SKU and
merchant pointing at it. That is a straight regression against master-data maintenance that works today.

It is reachable, not theoretical: `store/admin/shippers.js:47` PATCHes `/client/${id}`, and
`ClientController` declares **no** `PATCH` mapping — so the live shipper screen lands on Spring Data REST
and goes through this handler on every save.

Verify row `check_H_delta_not_state` and unit test `unrelatedFieldEditIsNotValidated`.

#### 3.9.4 Registration — silent when it fails, and easy to break

A `@Component` carrying `@RepositoryEventHandler` is auto-registered by Spring Data REST's
`AnnotatedHandlerBeanPostProcessor` — no `RestConfiguration` change. **Registration is silent when it
fails**, which is why §7.4 requires a controller test that PATCHes an invalid value through HAL and
asserts a 422; no code-shape grep can prove the handler is wired.

**Keep the handler bean interface-free.** Spring Data REST resolves handler methods off the *user* class,
so a CGLIB proxy is fine — but if the handler implements an interface it becomes a JDK dynamic proxy and
**registration fails silently**, which is pre-mortem P3's exact failure mode. Do not let it implement an
interface.

**Do not put `@PreAuthorize` on the handler methods.** Spring Data REST registers the handler bean through
its own `AnnotatedHandlerBeanPostProcessor`, while Spring Security's method-security advisor is applied by
a different bean post-processor; depending on BPP ordering SDR can capture the **raw target** rather than
the security proxy, in which case the annotation is inert and the guard silently never fires. The
authorization check therefore lives on `PutawayConfigService` — an ordinary `@Service`, reliably proxied,
invoked from outside the bean by the handler (§3.12). `AccessDeniedException` is unchecked, so it
propagates out of the handler cleanly and Spring Security maps it to **403** before any validation runs.
Manual row **M16a**: a non-`sb_admin` `PATCH /v3/sysprop/{id}` must return 403, not 422 and not 200.

#### 3.9.5 Why the previous value needs its own query, and why no flush mode is involved

Spring Data REST's PATCH/PUT loads the entity, merges the payload, then fires `BeforeSaveEvent`, so the
in-memory field already holds the **new** value; the committed one must come from a separate query, which
is what `readCommittedDestination` is for.

**No `FlushModeType` manipulation is needed or wanted.** With OSIV off (`application.properties:55`) the
instance SDR merged into is **detached** — there is no persistence context to auto-flush, so
`setFlushMode(FlushModeType.COMMIT)` would change nothing. The native query returns the committed value
because the entity is detached, not because a flush was suppressed. Write the query; do not add a flush
mode, and do not document one.

Because the read always succeeds on the save path, the `previous_value_unavailable` column (§3.14) is only
ever `true` in one situation: nothing. It exists as a defensive marker and, on the **create** path,
`previous_location_id = NULL` with `previous_value_unavailable = false` is the correct record — there was
no previous value to be unavailable.

#### 3.9.6 Transaction shape — Before validates, After audits and evicts

`@HandleBeforeSave` / `@HandleBeforeCreate` fire from `RepositoryEntityController` **before**
`repository.save()`, outside any transaction; with `spring.jpa.open-in-view=false` there is not even an
open persistence context. `PutawayConfigAuditService` is `Propagation.MANDATORY` (§3.14, copied from
`CancellationLogService.java:33`), so it **cannot be called from a `Before` handler** — that raises
`IllegalTransactionStateException` and HAL PATCH returns 500. `MANDATORY` stays correct for the *typed*
writers, where it guarantees the audit row commits with the change or not at all.

**A single `@Transactional validateAndAudit(...)` called from the `Before` phase is NOT the answer and must
not be implemented.** It would open and **commit its own transaction before** SDR calls `repository.save()`,
which runs in its own transaction (`SimpleJpaRepository`). Two transactions: if the save then fails —
optimistic lock, FK violation, anything — the audit row survives a change that never happened, which is
what §3.14 calls "worse than none". It would satisfy AC15 with false records.

**The shape is split across the two phases:**

```java
// PutawayConfigRepositoryEventHandler — validation only, and it must throw UNCHECKED (§3.9.7)
@HandleBeforeSave                       // separate from @HandleBeforeCreate (§3.9.2)
public void onItemdataSave(Itemdata incoming) {
    Long previous = putawayConfigService.readCommittedDestination(SKU, incoming.getId()); // null on create
    if (Objects.equals(previous, incoming.getPutawaylocationId())) return;                 // §3.9.3
    putawayConfigService.validateOnly(SKU, incoming, previous);   // throws unchecked on reject
    pendingPreviousValue.set(previous);                           // request-scoped carrier, see below
}

// Audit AFTER the entity write has committed, so the row can never outlive a failed save
@HandleAfterSave @HandleAfterCreate
public void onItemdataAfter(Itemdata saved) {
    putawayConfigService.auditAndEvict(SKU, saved, pendingPreviousValue.getAndClear());
}
```

```java
// service/PutawayConfigService.java
@Transactional(value = "tenantTransactionManager", readOnly = true)
public Long readCommittedDestination(PutawayScope scope, Long entityId) { ... }   // null-safe on create

@PreAuthorize(Authority.IS_SB_ADMIN)                                              // §3.12
public void validateOnly(PutawayScope scope, Object incoming, Long previous) { ... } // no tx, no write

@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
public void auditAndEvict(PutawayScope scope, Object saved, Long previousLocationId) { ... }
```

Three properties this buys:
1. **The audit row cannot outlive a failed write** — it is written after SDR's save has committed, so
   §3.14's rationale holds on the HAL channel as well as the typed one.
2. **The previous value has somewhere to live** — the `Before` phase reads it and hands it to the `After`
   phase explicitly, rather than being orphaned by a signature that has no parameter for it.
3. **Eviction lands after the write**, not before — no window in which a concurrent read repopulates a
   stale entry that then lives out the full 5-minute TTL.

The handler **validates and audits only — it must never write the entity**; SDR saves it immediately
afterwards, so a write here means a double save.

**Open sub-decision for the implementer:** the request-scoped carrier between the two phases. A
`@RequestScope` bean is the clean option; a `ThreadLocal` is not, because the tenant-context precedent in
this codebase shows how easily those leak across async boundaries. Whichever is chosen, it must be
cleared unconditionally — a leaked previous value on a pooled thread would attribute one tenant's prior
location to another's audit row.

#### 3.9.7 Exception type — `PutawayConfigValidationException`, unchecked, 422

`BusinessException extends Exception` (`exceptions/BusinessException.java:14`) — it is **checked**. Spring
Data REST invokes `@HandleBefore*` through `AnnotatedEventHandlerInvoker` → `ReflectionUtils.invokeMethod`,
which rethrows only `RuntimeException`/`Error` and wraps a checked cause in
`UndeclaredThrowableException`. A `BusinessException` thrown from a handler therefore never reaches
`RestExceptionHandler`'s 422 mapping (`:118-124`) and the client gets a generic **500** — which would
leave the plan's highest-blast-radius guard with no usable proof at all, since M9 is what proves the
handler is registered.

**The handler throws a new unchecked `PutawayConfigValidationException extends RuntimeException`, with an
`@ExceptionHandler` in `RestExceptionHandler` returning 422 and the rendered message.** Chosen over SDR's
`RepositoryConstraintViolationException` because (a) it lands on **422**, the same status
`RestExceptionHandler:118-124` already returns for `BusinessException`, so the HAL and typed channels give
operators the same status and the same message for the same mistake; (b) `RepositoryConstraintViolationException`
is built around a Spring `Errors`/field-binding payload, and this rejection is not a field-binding failure
— it is a cross-entity rule about `location_constraint`, so the shoehorned payload would read worse to the
operator and to whoever writes the UI banner; and (c) it keeps the actionable-message rendering in one
place rather than splitting it across two exception shapes. **`BusinessException` stays on the typed path**
— the service layer is unchanged; only the handler boundary differs.

Follow-through: `RestExceptionHandler` gains the mapping; the handler methods declare **no** `throws`
clause, and a verify row asserts `throws BusinessException` is absent from the handler file; §3.6.1's
message keys render identically on both channels; and **M9's expected result is "all three HAL writes
return 422 with the actionable message"** — not "4xx", which is loose enough to be satisfied by the
500-via-`UndeclaredThrowableException` failure this decision exists to prevent. A 500 there is a
documented hard stop for pre-mortem P3.

#### 3.9.8 Channel tagging

The handler passes `channel = "hal"` to the audit writer and the metrics counter; the typed writers pass `channel = "typed"`; `V2.2.11`'s backfill pre-image rows carry `channel = "migration"` (§5.1). A non-zero `hal` count after Phase 2 ships is the signal that a client is still bypassing the intended UI.

**HAL writes cannot carry a confirmation.** D11's count-and-confirm requires a query parameter that SDR discards (§3.5a), so the handler applies the **strict** rule on the HAL channel: any incompatibility ⇒ reject. An admin who needs to accept a partially-incompatible destination must use `PutawayConfigController`. The rejection message must say so explicitly, or the HAL 422 looks like a bug.

### 3.10 Cache coherence

| Write | Cache | Keys evicted | Where |
|---|---|---|---|
| SKU destination | `itemdata` | `facilityCode+':id:'+#itemData.id` **and** `facilityCode+':'+#itemData.clientId+':'+#itemData.itemNr` | reuses `ItemdataService.java:62-67` verbatim; the comment at `:59-61` states the rule that the two `@Cacheable` and two `@CacheEvict` key expressions must stay in sync |
| Merchant destination | `clients` | `facilityCode+':'+clNr` **and** `facilityCode+':SYSTEM'` | §3.3 |
| Warehouse destination | `sysprops` | `facilityCode+':'+DEFAULT_PUTAWAY_LOCATION` | §3.5 — defensive only; the resolver's read path is uncached |
| any of the above via HAL | same as above | same | the event handler cannot carry `@CacheEvict` for another bean's keys ⇒ it **delegates to `PutawayConfigService`**, which does. This is the second reason the handler exists rather than just validating inline. |

**Both cache profiles.** `CacheConfig.java` declares the four caches twice (`:31-42` Caffeine, `:49-69` Redis). No new cache is added, so **no `CacheConfig` change is required** — a fact worth stating explicitly, because "add a cache" is the reflex here and it would have to be done twice. `unit/config/CacheConfigTest.java` already guards the pairing.

**Freshness contract.** Receiving never reads a stale **tier value**: `receiveGoods` loads `Client` via `clientRepository.findById` (`ReceivingService.java:369-370`, uncached), `Itemdata` via `itemdataRepository.findById` (`:357`, uncached), and tier 3's `sysvalue` through the uncached derived query `findBySyskeyAndClientIdAndWorkstation` (`SyspropRepository.java:35-36`, not `@Cacheable`). The receiving path is **not** entirely cache-free: tier 3 dereferences `clientService.getSystemClient()`, which **is** `@Cacheable(value = "clients", key = … + ':SYSTEM')` (`ClientService.java:100`). That is harmless — the system client's identity does not change — and a cache read inside a read-only transaction is fine. The **admin screens** can show a value up to 5 min stale after another replica's write under the Caffeine profile. §7.3 rows encode "re-read after the write in the same session" rather than "wait out the TTL".

### 3.11 Phase 2 — web UI (`v2/wms2-web-ui`)

#### 3.11.1 Receiving form — the SBDEV-2731 display half

`components/receiving/open/receive/receivingForm.vue:9-13` hardcodes the value `"Put Away Lane"`; the `putawayStaging: null` data property at `:206` is never read or written, and the receive payload (`:325-335`) carries no destination field. Replace the static label's value with `putawayStaging`, populated from `GET /receiving/getPutawayDestination/{advicePositionId}` (§3.8), rendered as `locationName` plus a subdued `sourceLabel` chip, and a warning banner when `compatible === false`. The receive payload is **unchanged** — the destination is server-derived, never client-supplied.

> **⚠ SBDEV-2731 PR1 (#39) already rewrote this component, and two of its properties are load-bearing. Do not regress them — added 2026-08-06 after 2731's plan was reconciled to as-shipped code.**
> The as-shipped form carries a **tri-state** computed (`receivingForm.vue:296`):
> ```js
> isPutawayDestinationApplied() {
>   if (this.noContainer === true) return true
>   if (this.requireReceiveToContainer === true || this.parentContainer) return false
>   return null                       // undetermined — render NO qualifier
> }
> ```
> Its purpose is to stop the screen asserting a destination-truth the submit path has not established — `validate():470` rejects `!parentContainer && !noContainer`, so before the operator chooses, *no* claim is honest. Two things must survive this plan's edits:
> 1. **The template tests `=== false`, never `!`** (`receivingForm.vue:24`). `!null` is `true`, so a falsy test silently restores the exact bug 2731 fixed — on first paint, for every tenant with `REQUIRE_RECEIVING_TO_CONTAINER = false`, i.e. precisely the population that configures alternate putaway locations. `isPutawayOverride` likewise ANDs on `=== true`.
> 2. **The `requireReceiveToContainer` clause.** Drop it and the container-mandating tenant falls through to `null` and says nothing.
>
> 2731 pins these with verify check `A10` and tests `T24`/`T25`. **This plan adds `sourceLabel` to the same block, so this plan can break them** — Phase 2 step 19 must keep the tri-state intact, and `U-tristate` (§11.1) asserts the `=== false` comparison survives. Treat it as a preservation check, not a new feature.

#### 3.11.2 Warehouse default — Operation Options

`editParamAndConfig.vue:23-30` and `addParamAndConfig.vue:22` branch on `groupName`. Add a `syskey === 'DEFAULT_PUTAWAY_LOCATION'` branch rendering a location picker instead of a free-text field.

**Render the control unconditionally.** The Operation Options screen must offer the putaway-destination control **whether or not a `DEFAULT_PUTAWAY_LOCATION` row exists** in the `findByGroupname` list — driven by the typed endpoints, not by list membership. Two independent reasons: the `V2.2.11` seed may not have run yet on a given tenant, and D12 lets an operator delete the row. Since `POST /v3/systemProperty/create` rejects this syskey (§3.9.1), a list-driven control would leave the warehouse tier unreachable from the UI in both cases. `setWarehouseDestination` creates the row on first write (§3.5).

**Write path: `PUT /putawayConfig/warehouse` (§3.5a), never `PUT /sysprop/{id}` and never `POST /systemProperty/create`.** The generic dialog's three existing write actions (`store/admin/configuration.js:73-93`, `:95-123`, `:125-147`) stay in place for every *other* syskey; the `DEFAULT_PUTAWAY_LOCATION` branch must dispatch to a new action that calls the typed endpoint, because that endpoint is the only path carrying validation, audit, cache eviction and D11's confirmation. Two of the three existing actions bypass the event handler entirely (§3.9.1), so reusing them would silently ship an unvalidated warehouse tier — the highest-blast-radius tier in the plan.

**Render the config-health signal.** Before enabling the Save button, call `GET /putawayConfig/preview?scope=WAREHOUSE&locationId=<id>` and show `incompatibleSkuCount` / `totalSkuCount` plus `exampleIncompatibleSku`. A non-zero count drives D11's confirm dialog, which re-issues the write with `confirmIncompatibleSkus=<n>`; a non-null `blockingReason` (`LOCKED` | `FIX_ASSIGNED` | `LANE`) disables Save outright.

**Picker shape — tiered, not flat.** No searchable location selector exists anywhere in the app: every existing picker is a client-side filter over a preloaded Vuex list (`moveFixedLocation.vue:13`, `transferStock.vue:36, 72-73`), and `/location/detailView` (`store/masterData/storageLocation.js:53`) returns the full facility list with no search parameter. Build `components/common/LocationPicker.vue` on the two-tier pattern from `createBol.vue:109-121` (inline `v-autocomplete`) + `:125` ("Lookup" button opening a search dialog, cf. `searchPallet.vue`), sourced from `/location/detailView` and filtered client-side on P2.3/P2.4.

**The picker must not be sourced from `/location/getStorageLocationsForPutAwayItemData`** — its `useforstorage='true'` predicate can never return `PutAwayLane` (§3.4c / §0.1 row 34).

**Two tiers of candidate, and the second one carries a warning:**

| Tier | Contents | Presentation |
|---|---|---|
| default | locations whose `location_area.useforgoodsin = true` | shown immediately in the autocomplete |
| advanced | locations whose `location_area.useforstorage = true` | behind an explicit **"Show storage locations"** toggle, which reveals the lock-contention warning below |

**The picker's filter must be exactly P2.4** (`useforgoodsin OR useforstorage`), split across the two tiers. Offering anything P2.4 rejects produces a 422 the operator cannot act on. In particular a **pick-only** area — `useforpicking` with neither `useforgoodsin` nor `useforstorage` — is **not** offered, because P2.4 rejects it; whether it should be admissible at all is **Q9**.

The advanced tier exists because the ticket legitimately wants a storage destination, and is gated because pointing a tier-2/3 default at a **live storage location** moves a `FOR UPDATE` lock onto a row that replenishment and transfer also lock, in the opposite order — see §7.6 row 8. The warning text must say that receiving will hold a lock on the chosen location for the duration of a whole multi-case receipt, and that a location in active use may cause receipts to fail with a deadlock. The same tiering and the same warning apply to the merchant picker (§3.11.3) and to the SKU picker whenever SBDEV-2643 builds one.

Whether a preloaded list scales depends on location count per facility — §10 Q2.

#### 3.11.3 Merchant default — shipper screen

`components/admin/shippers/editShipper.vue:14-80` gains one field bound to `defaultputawaylocationId`, read from `/client/detailView` and **written through `PUT /putawayConfig/merchant/{clientId}`** (§3.5a) — not through `PATCH /client/{id}` (`store/admin/shippers.js:47`), which is the HAL path and cannot carry D11's confirmation.

Because `NULL` means inherit, the field renders as a three-state control: **Configured** (`<location>`), **Inherited** (`<effective location>` shown greyed with its source), and a **Clear** action writing `null`. There is no configured-vs-inherited precedent anywhere in the app. The **Inherited** value comes from `GET /client/{id}/effectivePutawayDestination` (N9), whose `source` + `sourceLabel` fields (§3.8) are what make it displayable without re-deriving precedence in Vue; without that endpoint this control cannot be rendered at all.

The picker is the same tiered `LocationPicker.vue` as §3.11.2, including the advanced-tier lock warning, and the same `GET /putawayConfig/preview?scope=MERCHANT&subjectId=<clientId>&locationId=<id>` call driving `incompatibleSkuCount` and the confirm dialog.

#### 3.11.4 persistedState

`plugins/persistedState.client.js:22-25` persists the **entire** `admin` Vuex module — including `admin.configuration.operationOptions` — to `localStorage['vuex-web']`, excluding only `warehouseTimezone`, `selectedWarehouse`, `warehouses`. This is the exact failure class as the stale-timezone bug: a rehydrated prior value overwrites the fetched one. Add the putaway config keys to the reducer exclusion list. (A cross-tenant leak here would show one tenant's location id in another tenant's admin screen.)

### 3.12 Permissions — bounded decision (AC item 7)

**There is no frontend role gating in this app.** `layouts/default.vue:284-286` returns the `'super-admin'` menu unconditionally for every authenticated user; `adminMenu` (`:264-268`) is never referenced; `APP_ADMIN_GROUP` (`nuxt.config.js:167`) is read nowhere. `store/index.js:92-101` `getUserRoles` and `:103-117` `getAffiliatedGroupsByUsername` already fetch roles, and nothing gates on them.

**Decision:** the security boundary is the **backend**, and it is enforced **in `PutawayConfigService`, not on the event-handler methods**.

- `@PreAuthorize(Authority.IS_SB_ADMIN)` on `PutawayConfigController`'s three write endpoints (the pattern used throughout `controller/AdminController.java:93, 121, 134, 147, 156`).
- `@PreAuthorize(Authority.IS_SB_ADMIN)` on `PutawayConfigService.setSkuDestination`, `setMerchantDestination`, `setWarehouseDestination` **and `validateOnly`**. `validateOnly` is the method the event handler calls, so this is what makes the HAL channel admin-only.
- **Nothing on the handler methods.** Spring Data REST registers handler beans via its own `AnnotatedHandlerBeanPostProcessor`; Spring Security's method-security advisor comes from a different post-processor, and depending on ordering SDR may capture the raw target rather than the security proxy — in which case an annotation on a handler method is **inert and silently never fires**. `PutawayConfigService` is an ordinary `@Service`, reliably proxied, and the handler invokes it from outside the bean, so the check cannot be bypassed by proxy-capture. §3.9.4.
- `AccessDeniedException` is unchecked, so it propagates out of the handler and Spring Security maps it to **403** — ahead of any 422 from validation.

Phase 2 additionally *hides* the fields using the already-fetched `affiliatedGroups` — a convenience, not a control.

**Proof.** Manual row **M16** (typed endpoints ⇒ 403) and **M16a** (`PATCH /v3/sysprop/{id}` as a non-`sb_admin` ⇒ 403, not 422 and not 200). A verify row asserts `@PreAuthorize` appears in `PutawayConfigService.java` and **not** in `PutawayConfigRepositoryEventHandler.java`.

**Explicitly out of scope:** introducing a general web-UI role-gating framework. That is a cross-cutting change touching every screen and belongs in its own ticket (§8.4). Stating this is what keeps the AC from being *implicitly* unmet: the AC is met by backend enforcement, and the frontend gap is named rather than papered over.

### 3.13 Observability — net-new

There is no `MeterRegistry`, `Counter` or `Timer` anywhere on the receiving path (§2.8). **New file** `src/main/java/net/aim_ai/wms/service/PutawayResolutionMetrics.java`, modelled on `schedulejob/JobMetrics.java` (a final class holding an injected `MeterRegistry`, one method per event):

| Metric | Type | Tags | Answers |
|---|---|---|---|
| `wms2.putaway.resolution` | counter | `source` (4 values), `carrier` (true/false), **`compatible` (true/false)**, `tenant` | **Is the feature actually in use?** The tier-2/3 counts staying at zero is pre-mortem P2's leading indicator. The `compatible` tag makes the carrier-path "destination surfaced but not applied" case queryable as `resolution{carrier="true",compatible="false"}` **without** polluting `resolution.rejected`, which alerts on `>0`. |
| `wms2.putaway.resolution.rejected` | counter | `scope`, `reason`, `tenant` | receive-time backstop firings — pre-mortem P3's leading indicator |
| `wms2.putaway.config.rejected` | counter | `scope`, `reason`, `channel` (typed/hal), `tenant` | write-time validation working |
| `wms2.putaway.config.changed` | counter | `scope`, `channel`, `tenant` | who is still bypassing the UI (`channel="hal"` > 0) |

Cardinality is bounded: `source` 4 × `carrier` 2 × **`compatible` 2** × `tenant` 5 = **80** series for the busiest metric. `tenant` matches `JobMetrics`' existing convention.

### 3.14 Audit table (D7 / ticket AC)

**New table** in `V2.2.11` (Phase 1 — the backfill pre-image needs somewhere to land, §5.1), modelled on `customerorder_cancellation_log`. The **entity, repository and audit service are Phase 1** (O1); Phase 1 creates the table and writes only the migration pre-image rows. Note that `CustomerorderCancellationLog` uses `GenerationType.IDENTITY` and does **not** extend `AbstractBaseEntity` — so this table gets its own `bigserial` and never touches `seqentities`, which sidesteps the dual-island id-space landmine on migrated tenants.

```sql
CREATE TABLE IF NOT EXISTS public.putaway_config_audit (
    id                         bigserial PRIMARY KEY,
    version                    integer      NOT NULL DEFAULT 0,
    tenant_name                varchar(50)  NOT NULL,
    facility_code              varchar(10)  NOT NULL,
    scope                      varchar(16)  NOT NULL,     -- SKU | MERCHANT | WAREHOUSE
    subject_id                 bigint       NULL,         -- itemdata.id | client.id | NULL
    subject_label              varchar(255) NOT NULL,     -- SKU number | client cl_nr | 'WAREHOUSE'
    previous_location_id       bigint       NULL,
    previous_location_name     varchar(255) NULL,
    previous_value_unavailable boolean      NOT NULL DEFAULT false,
    new_location_id            bigint       NULL,         -- NULL = override cleared
    new_location_name          varchar(255) NULL,
    channel                    varchar(16)  NOT NULL,     -- typed | hal | migration
    changed_by                 varchar(255) NULL,
    changed_at                 timestamptz  NOT NULL
);
CREATE INDEX IF NOT EXISTS putaway_config_audit_scope_subject_idx
    ON public.putaway_config_audit (scope, subject_id, changed_at DESC);
```

Location **names** are denormalised alongside the ids so the log stays readable after a location is renamed or deleted. No FK to `location` — an audit row must survive its subject.

**New service** `service/PutawayConfigAuditService.java`, `@Transactional(value = "tenantTransactionManager", propagation = Propagation.MANDATORY)` exactly like `CancellationLogService.recordCancellation`. `changedBy` from `SecurityContextUtils.getUserName()` (already used at `ReceivingService.java:359, :508`); `tenantName`/`facilityCode` from `TenantContext.getCurrentTenant()`. `MANDATORY` guarantees the audit row commits with the config change or not at all — an audit that can survive a rolled-back change is worse than none.

**No new REST endpoint for reading the log in Phase 1.** The table is queryable by support via SQL; a UI for it is a follow-up (§8.4). The AC says "recorded", not "displayed".

---

## 4. File Change Summary

### Phase 1 — `v2/wms2-api` (**1a** unless the row says 1b)

| File | Add/Modify/Delete | Phase | Description |
|---|---|---|---|
| `src/main/resources/db/migration/V2.2.11__putaway_destination_hierarchy.sql` | **Add** | 1-API | **one** migration, statement order load-bearing (§5.1): preflight guard; `itemdata.putawaylocation_id DROP NOT NULL`; `putaway_config_audit` table + index; backfill pre-image; scoped NULL backfill; `client.defaultputawaylocation_id` + guarded named FK; `DEFAULT_PUTAWAY_LOCATION` sysprop seeded `''` |
| `service/PutawayDestinationResolver.java` | **Add** | 1a | §3.1 — the one shared 4-tier resolver, `Propagation.MANDATORY` |
| `service/PutawayDestinationQueryService.java` | **Add** | 1a | §3.1.5 — `readOnly = true` tenant-tx facade; the only way a controller reaches the resolver |
| `service/PutawayConfigService.java` | **Add** | 1a (merchant writer 1b) | §3.5 — validated + audited writers, `validateOnly` / `auditAndEvict` / `readCommittedDestination`, cache eviction, `@PreAuthorize` boundary |
| `service/PutawayDestinationValidator.java` | **Add** | 1a (MERCHANT scope 1b) | §3.4c — predicate P2 per scope + the D11 incompatible-SKU count |
| `service/PutawayConfigAuditService.java` | **Add** | 1b | §3.14 — `MANDATORY` audit writer |
| `service/PutawayResolutionMetrics.java` | **Add** | 1a | §3.13 — 4 Micrometer counters |
| `model/PutawayConfigAudit.java` | **Add** | 1b | §3.14 entity, `IDENTITY` id, no `AbstractBaseEntity` |
| `repo/jpa/PutawayConfigAuditRepository.java` | **Add** | 1b | plain `CrudRepository`, **not** `@RepositoryRestResource` |
| `config/PutawayConfigRepositoryEventHandler.java` | **Add** | 1a (`onClient*` 1b — O2) | §3.9 — HAL write guard for `Itemdata`, `Sysprop`, `Client`, incl. the `@HandleBeforeDelete` / `@HandleAfterDelete` pair (D12) |
| `exceptions/PutawayConfigValidationException.java` | **Add** | 1a | §3.9.7 — unchecked; the handler cannot throw `BusinessException` |
| `controller/PutawayConfigController.java` + `PutawayConfigPreview` | **Add** | 1a (`setMerchant` 1b) | §3.5a — the typed write surface and D11's count-and-confirm |
| `controller/RestExceptionHandler.java` | Modify | 1a | `@ExceptionHandler` for `PutawayConfigValidationException` ⇒ 422 with the rendered message (§3.9.7) |
| `controller/SystemPropertyController.java` | Modify | 1a | `:77` and `:107` reject `syskey == DEFAULT_PUTAWAY_LOCATION` (§3.9.1) |
| `model/Itemdata.java` | Modify | 1a | remove `@NotNull` at `:49` — same commit as `V2.2.11` |
| `model/Client.java` | Modify | 1b | add `defaultputawaylocationId` + accessors — same commit as `V2.2.11` |
| `service/WmsConstants.java` | Modify | 1a | add `SYSTEM_PROPERTY_DEFAULT_PUTAWAY_LOCATION_KEY` |
| `service/LocationConstraintService.java` | Modify | 1a | add `isUnitloadTypePermitted` (§3.4b) |
| `service/UnitloadBusinessService.java` | Modify | 1a | `:180-193` delegates to the predicate; `:191` raw-concat throw → the **neutral** `unitloadTypeNotPermittedOnLocation` (§3.6.1) |
| `service/ReceivingService.java` | Modify | 1a | `:451-459` resolver call replaces the ternary; `:492` uses `putaway.location()` |
| `service/ItemdataService.java` | Modify | 1a | `setPutAwayLocation` delegates to `PutawayConfigService`; null guard at `:71` |
| `controller/ItemDataController.java` | Modify | 1a | `:80` `allEntries=true` → delegation; `:88-90` raw save → service call |
| `controller/ReceivingController.java` | Modify | 1a | add `getPutawayDestination` delegating to the §3.1.5 facade; `:314` literals → constants |
| `controller/ClientController.java` | Modify | 1b | add `GET /client/{id}/effectivePutawayDestination` (N9), delegating to the facade |
| `controller/rest/SkuRestController.java` | Modify | 1a | drop the lane lookup + argument at `:85-88, 144-146, 198-201, 257-259` — same commit as `V2.2.11` |
| `service/SkuBatchCreateUpdateService.java` | Modify | 1a | drop the `defaultPutawayLocationId` parameter (`:36`) and the setter (`:53`) |
| `controller/FileImportController.java` | Modify | 1a | drop the setter at `:383`; keep an equivalent lane-presence guard at `:355-359` |
| `src/main/resources/messages_en_US.properties` | Modify | 1a | add **both** `unitloadTypeNotPermittedOnLocation` and `putawayDestinationNotPermitted` (§3.6.1) |
| `src/test/.../unit/service/PutawayDestinationResolverUnitTest.java` | **Add** | 1a (tier-2 cases 1b) | §7.1 |
| `src/test/.../unit/service/PutawayConfigServiceUnitTest.java` | **Add** | 1a | §7.1 |
| `src/test/.../unit/config/PutawayConfigRepositoryEventHandlerUnitTest.java` | **Add** | 1a | §7.1 |
| `src/test/.../unit/controller/PutawayConfigControllerUnitTest.java` | **Add** | 1a | §7.1 — the D11 confirmation contract (409/422 split) |
| `src/test/.../smoke/PutawayResolverContextLoadTest.java` | **Add** | 1a | §7.2 — DI-wiring gate, `@Disabled` TODO(SBDEV-2217) |
| `src/test/.../unit/service/UnitloadBusinessServiceUnitTest.java` | Modify | 1a | `:193, 208` — new neutral message, deliberately |
| `src/test/.../unit/service/ReceivingServiceUnitTest.java` | Modify | 1a | resolver interaction + carrier path |
| `src/test/.../unit/service/LocationConstraintServiceUnitTest.java` | Modify | 1a | fail-open + allow/deny matrix |
| `src/test/.../unit/service/ItemdataServiceUnitTest.java` | Modify | 1a | `:418, 455, 482, 592` — nullable previous value |
| `src/test/.../unit/controller/ItemDataControllerUnitTest.java` | Modify | 1a | `:111, 120, 128, 138, 153` — the live write path is now validated |
| `src/test/.../unit/controller/ReceivingControllerUnitTest.java` | Modify | 1a | new endpoint + `BusinessException` envelope |
| `src/test/.../unit/controller/SystemPropertyControllerUnitTest.java` | Modify | 1a | `create` / `updateValue` reject the guarded syskey (§3.9.1) |
| `src/test/.../unit/controller/rest/SkuRestControllerUnitTest.java` | Modify | 1a | no seeded lane id |
| `src/test/.../unit/controller/FileImportControllerUnitTest.java` | Modify | 1a | no seeded lane id, guard retained |
| `src/test/.../unit/model/EntityUnitTest.java` | Modify | 1a | `:345, 370` — field no longer required |
| `src/test/.../unit/repo/ItemdataRepositoryTest.java` | Modify | 1a | `:32` |
| `src/test/.../common/fixtures/TestDataFactory.java` | Modify | 1a | `:694` |
| 3 H2 tests + 2 `@Disabled` ITs | Modify | 1a | listed in §3.2 |

### Phase 2 — `v2/wms2-web-ui` (**1a-UI** = receiving form only; everything else is **1b-UI**)

| File | Add/Modify/Delete | Phase | Description |
|---|---|---|---|
| `components/receiving/open/receive/receivingForm.vue` | Modify | 1a-UI | `:9-13` hardcoded label → effective destination + source chip + incompatibility banner; wire `putawayStaging` (`:206`) |
| `store/receiving/*.js` | Modify | 1a-UI | fetch `getPutawayDestination` |
| `plugins/persistedState.client.js` | Modify | 1a-UI | `:22-25` exclusion list |
| `components/common/LocationPicker.vue` | **Add** | 1b-UI | tiered autocomplete + lookup dialog, `createBol.vue:109-125` pattern; advanced tier carries the lock warning (§3.11.2) |
| `components/admin/parametersAndConfiguration/editParamAndConfig.vue` | Modify | 1b-UI | `syskey` branch → tiered picker, writing `PUT /putawayConfig/warehouse` |
| `components/admin/parametersAndConfiguration/addParamAndConfig.vue` | Modify | 1b-UI | same |
| `store/admin/configuration.js` | Modify | 1b-UI | new action calling `PUT /putawayConfig/warehouse` + `GET /putawayConfig/preview`; the three existing sysprop write actions stay for other syskeys |
| `components/admin/shippers/editShipper.vue` | Modify | 1b-UI | three-state merchant default field, `PUT /putawayConfig/merchant/{clientId}` |
| `store/admin/shippers.js` | Modify | 1b-UI | read `defaultputawaylocationId` from `detailView`; new action for the typed write + `effectivePutawayDestination` |
| `test/.../receivingForm.spec.js`, `LocationPicker.spec.js`, `editShipper.spec.js` | **Add** | 1a-UI / 1b-UI | §7.1 — first tests in these areas |

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| **0** | **External dependency — SBDEV-2731 PR1 merged to `develop`** (D12) | This plan assumes `receivingForm.vue` already binds `putawayStaging`, and that `UnitloadBusinessService:191` already throws the **neutral** `unitloadTypeNotPermittedOnLocation`. Both are 2731 PR1's deliverables, not this plan's. | 2731 | **New constraint: this plan can no longer merge independently.** If 2731 PR1 is abandoned or reworked, §3.6.1 and the display contract must be re-scoped back into this plan. |
| 1 | **Database state** | **Repair the Hydra DEV copy first** — it has no `flyway_schema_history`, so `StartupFlywayMigrator` **skips** it and `V2.2.11` would never apply: run `db/backfill-flyway-history.sh --up-to <its true watermark>` once against that DB. **Then confirm `V2.2.10` (SBDEV-2854) is already applied to THAT tenant — PR #132 merged 2026-08-07 (`68274b0`), so it is on `develop`, but **merged is not applied**; see §8.1 merge 0b. Applying `V2.2.11` to a tenant that has not yet received `V2.2.10` wedges that tenant against 2854 permanently** (`outOfOrder=false` skips the lower version, `validateOnMigrate=true` then fails every boot, and `StartupFlywayMigrator` swallows it). Then `V2.2.11` applied to **every** DEV tenant **BEFORE the Phase 1-API PR merges** (§8.1 — the single gated merge); then UAT before UAT deploy; then prod before prod deploy. Flyway head on `origin/develop` reads **`V2.2.09`** at start. | operator + author | **HARD BLOCKER on the Phase 1-API merge.** `V2.2.11` **does** add a column an entity maps (`client.defaultputawaylocation_id`), so the whole migration is gated — there is no gate-free half. DEV **auto-deploys on push**, and because `ddl-auto` is **`none`** the app **starts fine** and then throws `42703` on every `client` SELECT — silently, with green probes. On tenants that *do* have Flyway history the runtime migrator (SBDEV-2801) applies `V2.2.11` at boot and self-heals; the history-less DEV copy is the one that does not. Follow the `sbdocs/2-Areas/` Flyway tenant runbook with `--env dev`. See §8.1 and pre-mortem **P1**. |
| 2 | **Feature flags / system properties** | `DEFAULT_PUTAWAY_LOCATION` seeded by `V2.2.11` with `sysvalue = ''`. **No behaviour toggle.** | migration | D2 declined a sysprop gate; back-compat rests on "no config ⇒ no behaviour change", proven in §6. Blank = not configured (landmine A2). The seed is a convenience, not a dependency (§3.4a). |
| 3 | **Config / env changes** | None. No new property, no new cache, no Jasypt secret, no Keycloak client. | — | `CacheConfig` deliberately unchanged (§3.10) — the four caches already exist in both profiles. |
| 4 | **Deploy-order dependencies** | Each API phase merges and deploys **before** its UI phase. 1a-UI depends on `GET /receiving/getPutawayDestination`; 1b-UI depends on `PutawayConfigController`, `GET /client/{id}/effectivePutawayDestination` and `client.defaultputawaylocationId` in `/client/detailView`. No OMS dependency. | author | SBDEV-2731 and SBDEV-2643 must **not** be worked independently while this is open (D8, §8.1). |
| 5 | **Data migration** | **Scoped backfill inside `V2.2.11`, ordered after the `DROP NOT NULL` and after the pre-image INSERT** — see below. | migration | Without it the feature ships **inert** for all 2,720 existing SKUs (pre-mortem **P2**). |
| 6 | **External systems** | None. No OMS notification, no printer change, no Keycloak realm change. Receipt labels (`sharedService.createCaseLabel`) are unchanged. | — | |
| 7 | **Access / permissions** | `@PreAuthorize(Authority.IS_SB_ADMIN)` on `PutawayConfigController`'s three write endpoints **and** on `PutawayConfigService`'s three writers plus `validateOnly` — **not** on the event-handler methods. No new Keycloak role, no new group. | author | §3.12. An annotation on a handler method may be inert (§3.9.4), which is why the service is the boundary. Frontend gating is convenience only; the framework is out of scope. |
| 8 | **Monitoring / alerts** | Three items: (a) a Grafana panel for `wms2.putaway.resolution` split by `source`; (b) an alert on `wms2.putaway.resolution.rejected > 0`; (c) **a deadlock detector** — alert on `40P01` / `DeadlockLoserDataAccessException` on `/receiving/receive`. | author + ops | §3.13. The tier-2/3 series staying at zero is pre-mortem **P2**'s only detector. (c) is the named detector for §7.6 row 8's lock-order inversion, and it **must be log/exception-based**: `/receiving/receive` returns 200-with-`errors`, never a 5xx, so an HTTP-status alert misses it entirely. |

#### The D5 backfill — scoped, reversible, and order-sensitive

**The backfill runs, and it is scoped — not blanket.** `location.name` has **no unique constraint**
(`V2.2.00__base_v2_schema.sql:959-979` — `name varchar(255) NOT NULL`, nothing more), so nothing in the
schema prevents two rows named `PutAwayLane`; every statement below is written so that an ambiguous or
absent lane fails **loudly and first** rather than half-applying.

```sql
-- ============ V2.2.11, STATEMENT 1: preflight guard — MUST be first, before any DDL ============
-- Tier 4 resolves the fallback by NAME with no client filter (LocationRepository.java:21-22,
-- Optional<Location>), so it throws IncorrectResultSizeDataAccessException at runtime if the name is
-- ambiguous. Fail the migration here, BEFORE the DROP NOT NULL, rather than leaving a half-applied
-- schema the app then fails 42703 against on every read (ddl-auto=none; pre-mortem P1).
DO $$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM public.location WHERE name = 'PutAwayLane';
    IF n <> 1 THEN
        RAISE EXCEPTION
          'SBDEV-2732: tier-4 fallback ambiguous or absent (% rows named PutAwayLane). '
          'Resolve before migrating: tier 4 uses findByName with no client filter.', n;
    END IF;
END $$;

-- ============ V2.2.11, STATEMENT 2: widen the column ============
ALTER TABLE public.itemdata ALTER COLUMN putawaylocation_id DROP NOT NULL;

-- ============ V2.2.11, STATEMENT 3: create putaway_config_audit + index ============
-- Placed ahead of the backfill so statement 4's pre-image has somewhere to land. Full DDL in §3.14 —
-- reference it, do not duplicate it here.

-- ============ V2.2.11, STATEMENT 4: pre-image — MUST run BEFORE the backfill ============
-- Records what the backfill is about to discard, so "we destroyed intent" becomes "we recorded it and can
-- replay it": the §7.3 rollback drill is then a single UPDATE ... FROM putaway_config_audit.
--
-- ORDER IS LOAD-BEARING. The pre-image reads exactly the rows the backfill is about to null. If the
-- UPDATE runs first, putawaylocation_id is already NULL, the join to location matches nothing, and this
-- INSERT silently records ZERO rows — a reversibility record that is empty while appearing to succeed.
--
-- Column list matches §3.14 exactly: subject_id (NOT entity_id), and the three NOT NULL columns
-- subject_label / tenant_name / facility_code are all supplied. `channel = 'migration'` is the third
-- legal value alongside typed|hal — any CHECK constraint must admit it.
INSERT INTO public.putaway_config_audit
       (tenant_name, facility_code, scope, subject_id, subject_label,
        previous_location_id, previous_location_name,
        new_location_id, new_location_name,
        channel, changed_by, changed_at)
SELECT current_database(),           -- one DB per facility, so this is provenance, not a discriminator
       'MIGRATION',                  -- facility_code is NOT NULL; no facility identity exists in-DB
       'SKU',
       i.id,
       COALESCE(i.item_nr, i.name, i.id::text),   -- subject_label is NOT NULL
       l.id,
       l.name,
       NULL,                         -- new_location_id: the override is being cleared
       NULL,
       'migration',
       'V2.2.11',
       now()
  FROM public.itemdata i
  JOIN public.location l ON l.id = i.putawaylocation_id
 WHERE l.name = 'PutAwayLane'
   AND NOT EXISTS (SELECT 1 FROM public.putaway_config_audit
                    WHERE channel = 'migration' AND scope = 'SKU');   -- idempotent on re-apply

-- ============ V2.2.11, STATEMENT 5: scoped backfill — AFTER the pre-image ============
-- IN (SELECT ...) not = (SELECT ...): IN cannot abort on 0 or N rows. And NO client_id filter, so the
-- set nulled is *definitionally* what tier 4 resolves — the two can never disagree.
UPDATE public.itemdata i
   SET putawaylocation_id = NULL
 WHERE i.putawaylocation_id IN (
        SELECT l.id FROM public.location l WHERE l.name = 'PutAwayLane');
```

**Verify the pre-image actually captured something** — a silently-empty reversibility record looks
identical to success:

```sql
-- run immediately after V2.2.11; both counts must be equal and non-zero on a tenant with SKUs
SELECT (SELECT count(*) FROM putaway_config_audit WHERE channel='migration' AND scope='SKU') AS captured,
       (SELECT count(*) FROM itemdata WHERE putawaylocation_id IS NULL)                       AS nulled;
```

**Rollback drill** (§7.3 M19) is one statement, which is the whole point of the pre-image:

```sql
UPDATE public.itemdata i
   SET putawaylocation_id = a.previous_location_id
  FROM public.putaway_config_audit a
 WHERE a.channel = 'migration' AND a.scope = 'SKU' AND a.subject_id = i.id
   AND i.putawaylocation_id IS NULL;
```

**No `client_id` filter on the backfill predicate — deliberately.** Tier 4 resolves by name with no client
filter (`LocationRepository.java:21-22`), so any extra predicate here could diverge from it in both
directions: with a `client_id = 0` filter, a tenant whose lane had `client_id <> 0` would have nothing
nulled while tier 4 resolved fine (a silent pre-mortem-P2 on that tenant), and with two lanes the
migration would pick one while `findByName` threw at runtime. Matching tier 4 exactly, plus statement 1's
uniqueness guarantee, is what makes the two agree by construction. (On `wh01_hydra_v2` the lane does have
`client_id = 0`, so this removes a latent divergence, not a live one.)

**Statement order is load-bearing** — **one** migration, `V2.2.11`, in this order: preflight guard →
`DROP NOT NULL` → **create `putaway_config_audit`** → pre-image INSERT → backfill UPDATE → `client`
column + guarded FK → sysprop seed. §5.2 Phase 1 Step 3 restates it at the point of use.
*(Reworded 2026-08-06: this read as two migrations sharing one version number — residue of D16's
two-migrations→one collapse that a blanket version replace preserved.)*

**Idempotency.** `flyway migrate` never re-runs an applied version, so "migrate twice" is a vacuous gate —
use `psql -f` applied twice to a scratch DB instead. For that to be clean, the FK in `V2.2.11` needs a
guard, since Postgres has no `ADD CONSTRAINT IF NOT EXISTS`:

```sql
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_client_defaultputawaylocation') THEN
        ALTER TABLE public.client
          ADD CONSTRAINT fk_client_defaultputawaylocation
          FOREIGN KEY (defaultputawaylocation_id) REFERENCES public.location(id);
    END IF;
END $$;
```

The pre-image INSERT is also not naturally idempotent — a second apply would duplicate rows. Guard it with
`WHERE NOT EXISTS (SELECT 1 FROM putaway_config_audit WHERE channel = 'migration' AND scope = 'SKU')`.

**The argument for it.** Without *some* backfill, all 2,720 existing SKUs keep pointing at `PutAwayLane`, tier 1 wins every receipt, and tiers 2–3 are unreachable for every existing SKU — the feature ships inert (pre-mortem P2). A **blanket** `SET putawaylocation_id = NULL` would be wrong: it would discard genuine overrides, and genuine overrides demonstrably exist (the `Ice Pack` configuration on NYWH that produced the ticket's error).

**Is a genuine override distinguishable from a seeded default on existing data?** For rows equal to the lane id, no — and that is exactly why nulling *only those rows* is safe:

1. Every one of the four write paths seeds the lane id **unconditionally** (§0.1 rows 8–11); the SKU screen is read-only (`skuData.vue:107-131` create/edit commented out); so a row equal to the lane id is a seeded default with probability ≈ 1.
2. Rows **not** equal to the lane id are genuine overrides by construction — no code path ever writes a non-lane value except a deliberate human action. The predicate leaves every one of them untouched. `Ice Pack` survives.
3. The only semantic loss is a SKU *deliberately* pinned to `PutAwayLane`, which becomes "inherit". At the instant the migration runs this is **behaviour-preserving by construction**: `client.defaultputawaylocation_id` does not exist yet (it arrives in `V2.2.11`, created `NULL`) and no `DEFAULT_PUTAWAY_LOCATION` row exists or is non-blank, so no tier-2/3 value can exist, so "inherit" resolves through to tier 4 = `PutAwayLane` — the identical destination.
4. After the migration, "pinned to the lane" *is* expressible: select `PutAwayLane` explicitly in the SKU UI and the row gets a non-NULL tier-1 value that outranks tiers 2–3.

So the backfill is lossless on genuine overrides, behaviour-preserving at apply time, and it is the only thing that makes tiers 2–3 reachable. The DB evidence (100 % of rows equal the lane id on `wh01_hydra_v2`) is the *argument for* the scoped predicate, not a licence for a blanket one.

**Verification** (§7.3 SQL row): before → `SELECT count(*) FROM itemdata WHERE putawaylocation_id IS NULL` = 0; after → equals the pre-migration count of rows at the lane id; and `SELECT count(*) FROM itemdata WHERE putawaylocation_id IS NOT NULL` equals the pre-migration count of non-lane rows, **unchanged**.

### 5.2 Phased Implementation — TWO phases, plus one external prerequisite (D9 / D12)

**The ordering hazards O1–O5 are written into the steps, not merely referenced**, because a hazard in a
footnote gets read after it bites.

> ## ⚠ SCOPE CHANGE — D12 / D14 (2026-08-02). READ BEFORE THE TABLE BELOW.
>
> A plan for **SBDEV-2731** exists and is further along than this one:
> `sbdocs/1-Projects/wms2/plan/SBDEV-2731-alternate-putaway-location-not-honored-receiving.md`
> — 1,372 lines, `db_verified` against **four** environments including PRD, Architect-reviewed
> **SOUND WITH RESERVATIONS**, **PR1 ready**.
>
> **Q7 is CLOSED: it builds no competing resolver.** Zero occurrences of resolver / tier / precedence /
> merchant. This plan remains sole owner of the precedence contract.
>
> **But 2731 PR1 already delivers what this plan called Phase 1**, and better: the `receivingForm.vue`
> destination binding, the `UnitloadBusinessService:191` neutral message, four message keys across
> **both** properties files (this plan missed `messages.properties` entirely), and the matching tests.
>
> **D12 — Phase 1 is DELETED from this plan.** It is 2731 PR1's work. This plan becomes
> **Phase 1-API** + **Phase 2-UI**, and gains a hard prerequisite: *2731 PR1 merged to `develop`*.
> §3.6.1 no longer specifies `:191` — this plan only *consumes* the neutral key and throws
> `putawayDestinationNotPermitted` from the resolver.
>
> **D14 — this plan takes OWNERSHIP of `ReceivingService` destination resolution** (was 2731 PR2), so
> there is exactly one owner. **2731 closes on PR1.**
>
> **D14 IMPORT LIMIT — deliberate, and the reason this plan stays implementable.** 2731 PR2 is not
> merely "blocked"; it carries a **four-item gate that must be closed in writing before any coding**
> (2731 §7.2): **Q5** — *which determines whether its Fix B exists at all; under options (a) or (d) most
> PR2 steps are deleted rather than executed*; **C2b** — BLOCKING, the `Goodsreceiptposition` repointing
> is destructive as designed (`GoodsReceiptPositionService.delete:159-167`) and a test currently asserts
> the defective state as correct; **Q1**; **Q4**. Three further findings (F1 layering, F4 `Replenishorder`
> lock order, F5 Inbound-row lock re-scoping) must also close if Q5 keeps Fix B.
> **Therefore this plan imports the OWNERSHIP, not the gated work.** Flowbin classification and
> resident-UL resolution are recorded in §10 as **gated scope, explicitly outside Phase 1**, pending
> Q5/C2b/Q1/Q4. Importing them literally would re-block an otherwise-implementable plan on four external
> decisions. **Whoever answers Q5 must then decide where the surviving Fix B work lands — here, by
> construction, since 2731 will be closed.**
>
> **UPDATE 2026-08-04 — Q5 is answered (c), so the import limit partially collapses.** (c) is neither (a)
> nor (d), so by this block's own terms **Fix B exists and most of PR2's steps are executed, not deleted** —
> and "where the surviving work lands" is answered by construction: **here.** Consequences:
>
> - **Flowbin classification and resident-UL resolution move from *gated scope* into scope.** They can no
>   longer sit in §10 as "explicitly outside Phase 1"; direct placement into a pick face is exactly what
>   (c) authorises, and it is what those two pieces implement.
> - **F1 (layering), F4 (`Replenishorder` lock order) and F5 (Inbound-row lock re-scoping) must now close** —
>   this block already made them conditional on "if Q5 keeps Fix B", and Q5 kept it.
> - **C2b is now the binding gate, not Q5.** It is BLOCKING as written, unresolved by (c), and it carries a
>   consequence this plan's own §6 version missed: per SBDEV-2796, repointing
>   `Goodsreceiptposition.stockunitId`/`unitloadId` at the flowbin's resident rows makes
>   `GoodsReceiptPositionService.delete:159-167` `sendStockUnitToNirvana` **the entire flowbin balance** for
>   a one-case correction — and a test currently asserts the defective state as correct.
> - **Q1 and Q4 remain open** and still gate the Fix B import.
>
> So the gate went from four items to **three (C2b, Q1, Q4)** plus **three findings (F1, F4, F5)** that were
> previously conditional and became mandatory. **Net: (c) enlarged this plan.**
>
> **RESOLVED by D15 (2026-08-04): the enlargement is declined.** The tier-1 pick-face path is deferred to a
> follow-up ticket, so **Fix B is NOT imported after all** — flowbin classification and resident-UL
> resolution stay out of scope, and C2b, Q1, Q4, F1, F4 and F5 travel with them. The import limit this
> block argued for therefore **holds**, on a different basis than originally stated: not "Q5 is unanswered"
> but "the answer was taken and the resulting scope was deliberately deferred." The phase table below
> describes the correct scope again, with one change: **direct placement is tiers 2/3 only.**
>
> **What neither plan fixed while F3 was open — now superseded.** The reported ICE PACK failure is 1,000
> units into a flowbin pick face via a **tier-1 (SKU-level)** override, and **D13 exempts tier 1**. PR1
> makes the error actionable and shows the true destination — real value — but **it is not "receiving
> works", and 2731 must not be closed in a way that implies the reported failure is fixed.** *(2026-08-04:
> F3 is now answered (c) — the receipt is permitted to succeed and over-fill the bin. The reported failure
> becomes fixable once the C2b/Q1/Q4 gate closes and Fix B lands here.)*

| Phase | Repo | Ships | Flyway? | Closes |
|---|---|---|---|---|
| *(external)* | — | **SBDEV-2731 PR1** — receiving-screen destination binding, `UnitloadBusinessService:191` neutral message, 4 keys in **both** properties files, tests. **Hard prerequisite for this plan.** | no | **SBDEV-2731** |
| **1-API** | `wms2-api` | Resolver (all 4 tiers) + `Resolution`/`Source` (frozen contract) · validator P1+P2 with D11 count-and-confirm and D13's non-pick-face restriction · `PutawayConfigService` (3 writers) · `PutawayConfigController` (preview + 3 writes) · HAL event-handler guard + the direct-`save()` guards (N1) · `PutawayDestinationQueryService` + display endpoint · resolver wired into `ReceivingService` (**D14: this plan owns that surface**) · audit table + writer · direct placement · **`V2.2.11`** (preflight → `DROP NOT NULL` → audit table → pre-image → backfill → `client` column + guarded FK → sysprop seed) + stop-seeding in the same commit | **YES** | — |
| **2-UI** | `wms2-web-ui` | Admin Operation Options field · merchant field (configured / inherited / cleared) · location picker restricted per D13 · config-health surfacing | no | **SBDEV-2732** |

#### Why the boundary is "is the tier REACHABLE?" — retained, because it still governs ONE rule

An earlier revision split this into 1a/1b on "does it need Flyway?". That was wrong, and the reasoning is
worth keeping even though the split is gone: **tier reachability is governed by the backfill.** While
`itemdata.putawaylocation_id` is `NOT NULL` and all four sites seed it, 2,720/2,720 rows point at
`PutAwayLane`, tier 1 wins 100 % of receipts, and tiers 2–4 are unreachable no matter what else ships.

> **O3 — THE ONE ORDERING RULE THAT SURVIVES.** `V2.2.11` and **stop-seeding must land in the SAME
> COMMIT**. Ship the code first and `POST /rest/sku` plus the CSV import fail with `23502`; ship the
> constraint change first and every new SKU silently re-acquires a tier-1 value, reintroducing the
> inertness the backfill just cleared, one row at a time.
>
> **O1** — the audit table ships in this phase, so AC15 is met here (no deferral).
> **O2** — the event handler covers `Itemdata`, `Client` **and** `Sysprop`; `Client` is no longer a
> later-phase problem because there is no later API phase.
> **O4** — gate on `PHASE=1` 0-fail, never whole-plan 0-fail.

#### Phase 1-API — `v2/wms2-api`, carries `V2.2.11`. Branch `feature/SBDEV-2732-putaway-destination-hierarchy`

**Prerequisite: SBDEV-2731 PR1 merged** (§5.1 row 0) — this phase assumes `receivingForm.vue` already
binds `putawayStaging` and that `:191` already throws the neutral `unitloadTypeNotPermittedOnLocation`.

| Step | Work | Gate |
|---|---|---|
| 1 | `git checkout develop && git pull`, then branch. **The tree is currently on `bugfix/SBDEV-2777-…` — do not build on it, and do not let the TDD gate write onto it.** | `git branch --show-current` |
| 2 | **TDD gate.** Write the failing §7.1 tests for the resolver, P1, the confirmation contract, the delta rule and the display endpoint. Confirm each fails *for the right reason*. **Pause for approval.** | red for the right reason |
| 3 | **`V2.2.11` AND stop-seeding, in ONE commit (O3).** Migration in the §5.1 order: preflight guard → `DROP NOT NULL` → create `putaway_config_audit` + index → pre-image INSERT → backfill UPDATE → `client.defaultputawaylocation_id` + guarded FK → `DEFAULT_PUTAWAY_LOCATION` seeded `''`. Stop seeding at all four sites; update the ≈10 fixtures deliberately. | `psql -f` twice on a scratch DB, second run clean; full `mvn test` |
| 4 | `WmsConstants` key; `PutawayDestinationResolver` + `Resolution` + the `Source` enum; the `getSystemClient()` null guard (§3.4a). **`Propagation.MANDATORY`; never `REQUIRES_NEW`.** Freeze the `Source`/`Resolution` contract here — the UI consumes it. | unit tests + `mvn clean compile` |
| 5 | `LocationConstraintService.isUnitloadTypePermitted` (P1). **Must replicate the empty-constraint-list fail-open at `UnitloadBusinessService.java:182`** or it rejects configurations that work today. | `emptyConstraintListPermitsEverything` |
| 6 | **Consume** the neutral key 2731 PR1 added at `:191`; throw `putawayDestinationNotPermitted` from the **resolver** only (§3.6.1). **Do not re-specify `:191` — that is 2731 PR1's line.** | resolver message test |
| 7 | `PutawayDestinationValidator` — P1 + P2 for **all three scopes**, including P2.7 (D13), the **locked** absolute (P2.1), P2.7's per-tier lane rules and D11's count-and-confirm. **⚠ REVISED 2026-08-08 (Q12 → iv-b): do NOT implement a fix-assigned or pick-face reject.** P2.5 and P2.7(c) are relaxed at all three scopes — the configuration is legal, and the placement is gated at run time by step 15. **But implement P2.7 rule (e):** reject a `flowbin`-type destination at **merchant and warehouse scope only** — putaway's FLA auto-creation would bind it to one SKU. Predicate is `location_type.sltname`, **not** the area flag; using `useforpicking` here re-bans the club lanes and undoes Q12. **The relaxation and that gate must land in the same change** (§3.4c). | unit tests — **must include `skuWritePermitsPickFaceDestination` and `merchantWritePermitsStagingLane`. The old `skuWriteRejectsFixAssignedLocation` / `skuWriteRejectsPickFaceDestination` / `merchantWriteRejectsFixAssignedLocation` are DELETED — they assert the superseded design and would fail a correct implementation** |
| 8 | `PutawayResolutionMetrics` (4 counters; the `compatible` tag). | unit tests |
| 9 | `PutawayConfigService`: `setSkuDestination`, `setMerchantDestination`, `setWarehouseDestination`, `readCommittedDestination` (**one query per scope**), `validateOnly`, `auditAndEvict`; authorization enforced **here**, not on the handler (N5). Rewire `ItemdataService.setPutAwayLocation` and `ItemDataController:80-95`. | unit tests |
| 10 | `PutawayConfigController` — `preview` + all three writes and the 409/422 confirmation contract (§3.5a). | `BaseControllerTest` |
| 11 | **§3.9.1 direct-save guards:** `SystemPropertyController:77` and `:107` reject the guarded syskey; the delete-path decision implemented. | HAL + direct-save tests |
| 12 | `PutawayConfigRepositoryEventHandler` — `Itemdata`, `Client` **and** `Sysprop` (O2); separate create/save methods (§3.9.2); validate the **delta**, not the state; unchecked `PutawayConfigValidationException`. | HAL PATCH ⇒ **422** |
| 13 | `PutawayConfigAudit` entity + repository + `PutawayConfigAuditService` (`MANDATORY`). | `mvn clean compile` |
| 14 | `Client.defaultputawaylocationId` + accessors. **Same commit as `V2.2.11`** — otherwise every `client` read fails `42703` on any tenant the migration has not reached (`ddl-auto=none`, so it is a runtime failure, not a startup one). | context loads + a `client` read against a migrated tenant |
| 15 | Wire the resolver into `ReceivingService.java:451-459`. `requireCompatible` inside `if (carrier == null)` **above the loop** (§3.7.1); constants at `ReceivingController:314`. **Add the (iv-b) placement gate here:** if the resolved destination's area has `useforpicking = true` **OR its `location_type.sltname` is `flowbin`**, **do not place there** — fall back to the standard putaway lane (tier 4) and leave the destination for putaway. **The OR is deliberate, not belt-and-braces:** the reported failure is a location-*type* property (a flowbin's `location_constraint` permits only `PickLocation`), while `useforpicking` is an *area* property, and nothing in the schema ties them. Today every flowbin on both measured tenants happens to sit in a picking area — **that is data, not structure.** `sltname` is already read by P2.7 rule (e), so the second disjunct is free. Otherwise place as step 17 specifies. **This plan owns this surface (D14).** | `ReceivingServiceUnitTest` — **must include `pickFaceDestinationIsNotPlacedAtReceipt` and `stagingLaneDestinationIsPlacedAtReceipt`** |
| 16 | `PutawayDestinationQueryService` (`readOnly = true`) + `GET /receiving/getPutawayDestination/{advicePositionId}` + `GET /client/{id}/effectivePutawayDestination` — **the controller must not call the resolver** (C1). | controller tests |
| 17 | Direct placement + traceability (`UnitloadRecord` names the final destination) — **for NON-pick-face destinations only (Q12 → iv-b).** Pick-face destinations never reach this step; step 15's gate diverts them to the lane. **The gate in step 15 is what makes that true — it is no longer enforced by refusing the configuration, because (iv-b) permits pick-face configs at every scope.** **If you relax P2.5/P2.7(c) without step 15's gate in the same change, SBDEV-2731's reported failure returns.** | `ReceivingServiceUnitTest` |
| 17a | **Putaway consumes the resolved destination for tiers 2/3 — SCOPE ADDED 2026-08-08.** Step 15 diverts a pick-face destination to the lane; something must then offer it at putaway or the divert is a dead end. SBDEV-2821 builds that surfacing for **tier 1 only** (Q15 → (A)), reading `itemdata.putawaylocation_id` directly. **This plan extends it to the merchant and warehouse tiers** by having the putaway candidate query consume the four-tier `Resolution` instead of the raw column. **Prerequisite: SBDEV-2821 merged** — it owns `MobilePutAwayService`, including the `cases and pallets` fix (2821 §3.2a) without which club destinations throw. **Do not build this before 2821**, or two code paths will read destinations differently — the exact seam Q15 was about. | `MobilePutAwayServiceUnitTest` — a merchant-tier pick-face destination is offered as a putaway candidate |
| **17a** | **NEW 2026-08-08 (Q15 → (A)) — extend putaway's candidate surfacing to all four tiers.** SBDEV-2821 ships the repository method that adds a SKU's configured destination to the putaway candidate list, but reads **tier 1** (`itemdata.putawaylocation_id`) only. Step 15 diverts pick-face destinations at **every** tier, so merchant- and warehouse-scope defaults must be surfaced too: pass `Resolution.locationId()` from `PutawayDestinationResolver` into that method instead of the raw `itemdata` column. **Do not build a second surfacing path, and do not widen the `@RestResource`-exported `getStorageLocationsForPutAwayItemData`** (SBDEV-2821 §3.2). **This step is why `depends_on` now names SBDEV-2821** — if that ticket has not merged, this step has nothing to extend and step 15's gate strands the destination. | `MobilePutAwayService` unit test: a **merchant**-scope pick-face default appears in the candidate list for a SKU with **no stock anywhere** |
| 18 | `PutawayResolverContextLoadTest` (`@Disabled TODO(SBDEV-2217)`); `mvn clean compile`; full `mvn test`; **revert the mutated `archunit_store`**. | **`PHASE=1` verify run: 0 fail** |

#### Phase 2-UI — `v2/wms2-web-ui`. Closes SBDEV-2732

| Step | Work |
|---|---|
| 19 | `LocationPicker.vue` — **tiered** autocomplete + lookup dialog over `/location/detailView`: for merchant/warehouse scope offer only P2.7-eligible areas (D13); **never** `getStorageLocationsForPutAwayItemData`. |
| 20 | `editParamAndConfig.vue` / `addParamAndConfig.vue` `syskey` branch → `PUT /putawayConfig/warehouse` (**not** `PUT /sysprop/{id}`, **not** `POST /systemProperty/create` — N1). |
| 21 | `editShipper.vue` three-state merchant field (configured / inherited / cleared) → `PUT /putawayConfig/merchant/{clientId}`, inherited value from `effectivePutawayDestination`, `incompatibleSkuCount` driving D11's confirm dialog. |
| 22 | Config-health surfacing for invalid existing configurations; `persistedState.client.js:22-25` exclusion; Jest specs. |
---

## 6. Backward Compatibility

> ### ⚠ N-22 — DIRECT PLACEMENT BREAKS GOODS-RECEIPT CORRECTION (verified in code)
>
> `GoodsReceiptPositionService.java:151-152` guards receipt correction with an area check immediately
> before `deletePosition`:
> ```java
> if (!area.getUseforgoodsin()) {
>     throw new BusinessException("UnitLoad not in area for goods in anymore. found location=" + location);
> }
> ```
> It is reached from **both** `delete` (`:98`) and `adjust` (`:124`). **Today it can never fire**, because
> receiving's destination is always the inbound `PutAwayLane`, whose area is goods-in — structurally the
> same "harmless only because the destination is always the lane" assumption as H1.
>
> **After D2 direct placement into a tier-1 destination** (D13 exempts tier 1, so any storage or pick
> location) the position's unit load is no longer in a goods-in area, so **`delete` and `adjust` on that
> goods-receipt position throw.** Receipt correction becomes impossible for exactly the receipts this
> feature redirects, and it fails silently until an operator tries to fix a mis-receipt.
>
> The guard is also load-bearing in a second way: `deletePosition` proceeds to
> `sendStockUnitToNirvana(…, STOCK_REMOVED, …)` (`:165`) and, when no stock units or children remain,
> `sendToNirvana(unitLoad)` (`:171`). So it is the only thing standing between a correction and
> nirvana-ing a unit load that now sits on a live storage face.
>
> **This is C2b's lesson applied to this plan:** `Goodsreceiptposition.unitloadId` / `.stockunitId` are
> read by a consumer that **no changed symbol mentions**, which is why four review passes over §0 never
> surfaced it. If N-21's rule (d) lets tiers 2/3 target staging lanes whose areas are not goods-in, this
> breaks for those tiers too — not only tier 1.
>
> **Required before implementation:** add `GoodsReceiptPositionService` and
> `GoodsReceiptPositionController` to §0; decide explicitly whether the guard is relaxed for
> directly-placed receipts or whether correction is documented as unavailable for them; add a §7.3 manual
> row (receive to a non-lane destination, then `delete` and `adjust` that position). Note the guard throws
> a raw-concatenated `BusinessException` — the same family as `:191`, and newly reachable.
>
> **2026-08-04 — this is no longer conditional, and it is worse than described.** SBDEV-2796 answered (c):
> tier-1 direct placement into a pick face is authorised, so the "after D2 direct placement" premise above
> is now **certain**, not hypothetical. Two additions:
>
> - **The failure mode above is the *benign* one.** It assumes the position still points at its own newly
>   created rows, so the guard merely throws. But 2731's **C2b** — now live, see §5.2 — repoints
>   `Goodsreceiptposition.stockunitId`/`unitloadId` at the flowbin's **resident** pick-face rows. If the guard
>   is then *relaxed* (one of the two options this block asks us to choose between), `delete` proceeds to
>   `sendStockUnitToNirvana` (`:165`) and `sendToNirvana(unitLoad)` (`:171`) against **the whole flowbin
>   balance** — nirvana-ing every unit in the bin to correct one case. **So "relax the guard" is only safe if
>   C2b is fixed first.** The two decisions are coupled and must be taken together, not in either order.
> - A test currently **asserts the defective repointing as correct** (2731 review, C2b), so it will have to be
>   changed, not merely extended — and changing a passing test to make room for a fix needs an explicit
>   reviewer note or it looks like the fix broke it.
>
> ### ⚠ N-23 — A TIER-2/3 STAGING-LANE DESTINATION HANDS RECEIVED STOCK TO THE CLUB BATCH SUBSYSTEM (verified in code, 2026-08-04)

> D13 rule (a) *permits* `staginglane` and `crossdockinglane` for tiers 2/3, and the ticket's own named
> tier-2 scenario is **"Club assembly lane"**. Nothing in §0 or §3 asked what else owns those lanes. Two
> consequences, both verified against `origin/develop`:
>
> **1. Club lanes are allocated without any regard for resident stock — this can ship or nirvana a receipt.**
> `LocationRepository.getAvailableStagingLanes` (`:37-47`) is:
> ```
> WHERE l.staginglane = true
>   AND NOT EXISTS (SELECT ob FROM CustomerorderBatch ob
>                   WHERE ob.staginglaneId = l.id AND ob.id != :batchId AND ob.state < :state)
> ```
> **There is no stock or unit-load predicate at all.** A lane holding received inventory is "available".
> Path: `ClubLineController:307` → `CustomerorderBatchService:895` → `:911` assigns it; `BillofladingService:732/:829`
> and `CustomerorderBatchService:382/:402/:713` clear it; truck loading ships what sits on the lane.
>
> Scenario: merchant default = the club assembly lane → a receipt lands there → a club batch is later assigned
> to the same lane → **the received stock is shipped with the batch or cleared off the lane.** Blast radius is
> inventory loss, and D17 has already documented receipt correction as unavailable for exactly these receipts,
> so there is no clean unwind. Note the query is **`@RestResource`-exported**, so the frontend can call it
> directly — a service-layer guard would not cover it (same class of trap as SBDEV-1666).
>
> **2. Stock on a staging or transfer lane is structurally invisible to replenishment sourcing.**
> `StockunitRepository:198` and `:216` carry `AND loc.staginglane IS NOT TRUE AND loc.transferlane IS NOT TRUE`
> **unconditionally — no sysprop gate** (the SBDEV-1666 display corrections). So a tier-2/3 lane destination
> creates inventory replenishment can never source. That is probably *correct* for cross-dock and fast-turn —
> the stock is meant to leave, not to feed pick faces — and probably *wrong* for anything else. The plan never
> asked, so it is recorded here rather than assumed either way.
>
> **Required before implementation:** answer §10.4 **Q12** (below). If club lanes are excluded, P2.7 rule (a)
> must name `crossdockinglane` plus *non-club* staging lanes rather than `staginglane` wholesale — and
> "non-club" needs a definition, because `Location` has no such flag; the only available signal is whether the
> lane is ever referenced by a `CustomerorderBatch`, which is historical, not declarative. If club lanes are
> allowed, this plan owes a §7.3 manual row (receive onto a staging lane, then assemble a club batch on it) and
> an explicit operator warning.

> **DECIDED — D17 (2026-08-04): keep the guard.** Receipt correction is **documented as unavailable for
> directly-placed receipts**; the guard is not relaxed. Relaxing it is only safe once C2b is fixed, and C2b
> is deferred with the tier-1 path (D15), so keeping the guard is the only option that cannot nirvana a
> location. **This decision is required even under D15**, because D13 rule (d) lets tiers 2/3 target
> staging lanes whose areas are not `useforgoodsin` — so a tier-2/3 direct placement reaches the same
> guard. Implementation obligations that remain: add `GoodsReceiptPositionService` /
> `GoodsReceiptPositionController` to §0, add the §7.3 manual row (receive to a non-lane destination, then
> `delete` and `adjust`), and make the thrown message actionable — it is a raw-concatenated
> `BusinessException` today, the same family as `:191`, and newly reachable.


| Change | Compatible? | Why / mitigation |
|---|---|---|
| `itemdata.putawaylocation_id` DROP NOT NULL | **Yes, with a hard deploy order** | Widening a constraint never breaks existing rows. But the *code* change (stop seeding) requires the DDL first: on an un-migrated DB, `POST /rest/sku` and the CSV import fail with `23502 null value in column "putawaylocation_id"`. They travel in one commit (O3) and `V2.2.11` must be applied promptly after the Phase 1-API merge. |
| Scoped NULL backfill | **Yes — behaviour-preserving at apply time** | Only rows equal to the `PutAwayLane` id are nulled; no tier-2/3 value can exist yet, so they resolve through to tier 4 = the same location. Non-lane overrides untouched. §5.1. |
| `@NotNull` removed from `Itemdata` | **Yes** | Removing bean validation only widens what is accepted. HAL and typed writes now agree. |
| `client.defaultputawaylocation_id` added (`V2.2.11`) | **Yes, with a hard deploy order** | Nullable additive column; every existing row reads `NULL` = inherit. `ddl-auto` is `none`, so the entity field without the column does **not** prevent startup — it fails `42703` per request instead, which is harder to notice. This is what gates the merge. §5.1 row 1, §8.1. |
| `putaway_config_audit` and `client.defaultputawaylocation_id` both created in `V2.2.11` | **Yes** | One migration (D16), one gated merge — **there is no gate-free half any more**. A table no entity maps is harmless in either direction; the *column* is what gates. |
| `DEFAULT_PUTAWAY_LOCATION` seeded `''` | **Yes** | Blank = not configured ⇒ tier 3 never wins until someone sets it. An absent row behaves identically, so a tenant that has not yet had `V2.2.11` applied is also unaffected. |
| `SystemPropertyController` rejects one syskey; `DELETE` on it is audited (D12) | **Yes** | Every other syskey behaves exactly as today. The delete still succeeds and still removes the row; it merely writes an audit row as well, and the Operation Options control stays available so the tier can be re-set. §3.9.1, §3.11.2. |
| Resolver at the receiving call-sites | **Yes** | With no tier-2/3 config and post-backfill NULL tier-1, `resolve` returns `STANDARD_PUTAWAY_LANE` — the same `Location` the old ternary produced for 100 % of `wh01_hydra_v2`'s SKUs. |
| P1 hoisted before the loop | **Yes, strictly better** | Same predicate, same fail-open branch, evaluated earlier. A receipt that succeeded before still succeeds; one that failed still fails, now before any unit load exists and with a message naming the remedy. |
| `UnitloadBusinessService.java:191` message replaced with the **neutral** key | **Behaviour yes, text no** | Any consumer string-matching `"not allowed on location"` breaks. Known consumers: `UnitloadBusinessServiceUnitTest:193, 208` (updated). Grep found no production string-match. The 21 non-receiving call sites get a message with no putaway remedy clause, which is the point (§3.6.1). |
| `ItemDataController` `allEntries=true` → 2-key evict | **Yes, strictly better** | Narrower eviction. Worst case a stale entry survives up to 5 min in a cache that was previously being flushed wholesale for every tenant. |
| `ReceivingController:314` literals → constants | **Yes** | Same three values, resolved from the constants they should always have used. |
| New endpoint + new table + new counters | **Yes** | Purely additive. |
| Direct placement to a non-lane destination | **Yes, but visible** | Not a new mechanism (§2.1). Consequence: scanning a directly-placed unit load in mobile putaway throws the pre-existing **`unitloadNotInInboundArea`** from `MobilePutAwayService.java:113-117` — **not** `unitLoadNotInPutAwayLane`, which is at `:119-126` and is never reached for a unit load sitting in a storage or pick area. Pre-existing guard, newly reachable. Correction path is mobile "Move Unit Load" (`MobileMoveUnitloadService`) or the web Transfer Stock screen. Manual rows **M13**/**M13a** + operator note. §3.7.4. |

### What Does NOT Change

- `transferUnitLoadToLocation` / `transferUnitLoadToCarrier` **signatures and internals**, apart from `:180-193`'s delegation and `:191`'s message. **None of the other 21 call sites** (picking, palletizing, truck loading, transfer orders, on-hold, nirvana, empty-pool) is touched, and the resolver is never called from inside them.
- `receiving_dto_view` and `ReceivingDtoView` — **no DDL, no entity change** (§3.8).
- `ReceivedDtoView` and `/reports/receiving-report`.
- `receiveGoods`' transaction shape: still one `@Transactional(value="tenantTransactionManager", …)` at `:302`; resolution still hoisted above the loop; a bad destination still rolls the whole receipt back.
- `config/CacheConfig.java` — no new cache, so no change in either profile.
- Label printing (`sharedService.createCaseLabel`), the `WAREHOUSE_NAME` read at `:429-431`, `INBOUND_UPDATE_STOCK_IMMEDIATELY` (`:518`), and the over-delivery pessimistic lock at `:344-345`.
- `MobilePutAwayService` — no code change at all, including both guards at `:113-117` and `:119-126`, `calculatePutAwayList` (`:212-283`), and `storePalletBackOnPutawayLane` (`:190-206`) with its SBDEV-2102 "pallet must be on the current user's location" guard.
- `FileImportController.java:355-359`'s SBDEV-2037 lane-presence guard (kept, repurposed).
- Any OMS notification, outbox message, printer configuration, or Keycloak artefact.
- Mobile UI (`wms2-mobile-ui`) — not in D4's phasing.

---

## 7. Testing Strategy

**Known lane constraints — do not rediscover:**

- v2 Testcontainers ITs **cannot boot** (SBDEV-2217). Gate on unit + H2 tests and `mvn clean compile`; leave ITs `@Disabled` with `TODO(SBDEV-2217)`.
- **2 of 4442 tests already fail on clean `develop`** (`OptionalSafetyArchTest` ArchUnit drift, `MobilePalletizingServiceTest`). Do not attribute them to this change; do not "fix" them here.
- `mvn test` **MUTATES the tracked `archunit_store`** — `git checkout` it before committing.
- `-Dtest='Outer#method'` **silently no-ops for `@Nested` tests** (false green). Most of these suites use `@Nested` ⇒ run whole classes.
- A new `@Service` bean needs `mvn clean compile` **plus a context-load test** — unit tests and incremental compile both miss DI wiring drift.
- **`V2.2.11` is invisible to the IT harness** (it scans `db/v1-to-v2-onboarding/schema`, not `db/migration/`) ⇒ no automated test can prove the DDL. It is proven by the §7.3 SQL rows and the scratch-DB double-apply only.
- `mvn`/`java` need the SDKMAN PATH export.

### 7.1 Unit lane

| Test class | Test | Asserts |
|---|---|---|
| `PutawayDestinationResolverUnitTest` (**new**) | `tier1WinsWhenSkuConfigured` | non-null `putawaylocationId` ⇒ `SKU_OVERRIDE`, and neither `client` nor sysprop is read |
| | `tier2WinsWhenSkuNull` | tier 1 NULL, `client.defaultputawaylocationId` set ⇒ `MERCHANT_OVERRIDE` |
| | `tier3WinsWhenSkuAndMerchantNull` | ⇒ `WAREHOUSE_DEFAULT` from the sysprop id |
| | `tier4WhenNothingConfigured` | ⇒ `STANDARD_PUTAWAY_LANE` by name |
| | **`blankSysvalueFallsThrough`** | `''`, `'   '` ⇒ tier 4, **not** a parse failure (landmine A2) |
| | **`nullItemdataSkipsTierOne`** | `resolve(null, client, typeId)` returns non-null; `itemdataRepository` never touched (§3.1.4 / `AdviceRestController:684`) |
| | **`neverCallsGetStringDefault`** | `verify(syspropService, never()).getStringDefault(any(), any(), any(), any())` — landmine A1 as an executable assertion |
| | **`neverCallsGetSysvalue`** | landmines A3 + A4 as an executable assertion |
| | **`workstationScopedRowIsIgnored`** | a `DEFAULT_PUTAWAY_LOCATION` row on a non-`DEFAULT` workstation is not read (landmine A6) |
| | **`missingSystemClientRaisesBusinessException`** | `getSystemClient()` returning `null` ⇒ `BusinessException`, never an NPE (§3.4a) |
| | `configuredTierWithDanglingIdHardFails` | configured id with no `location` row ⇒ `BusinessException` naming the tier, **not** a fall-through (D6) |
| | `resolveNeverThrowsOnIncompatibility` | P1 false ⇒ `Resolution.compatible() == false`, and `resolve` returns normally (§3.1) |
| | `requireCompatibleThrowsPutawayKey` | `requireCompatible` on an incompatible `Resolution` ⇒ `putawayDestinationNotPermitted`, naming tier, destination, reason, remedy |
| | `requireCompatibleAlsoThrowsForTier4` | the lane itself incompatible ⇒ same exception (parity with today) |
| `LocationConstraintServiceUnitTest` | **`emptyConstraintListPermitsEverything`** | the fail-open branch — the single most dangerous thing to get wrong (D6) |
| | `matrixAllowDeny` | flowbin→PickLocation only; cases-and-pallets→Case+Pallet; `NoRestriction`→everything |
| `PutawayConfigServiceUnitTest` (**new**) | `skuWriteValidatesAndAudits` | P2 runs; one audit row with previous+new; both `itemdata` keys evicted |
| | `skuWriteRejectsIncompatibleDestination` | SKU scope is an absolute reject (§3.4c) |
| | `merchantWriteRequiresConfirmationWhenSomeSkusIncompatible` | count > 0 with no `confirmIncompatibleSkus` ⇒ reject; message names the count + one example SKU |
| | `merchantWriteRejectsOnlyAtTotalIncompatibility` | count == total ⇒ reject unconditionally, no confirmation accepted |
| | ~~`merchantWriteRejectsFixAssignedLocation`~~ | ⚠ **DELETED 2026-08-08 (Q12 → iv-b).** P2.5's write-time reject is dropped at all three scopes. Its verify check `T-merchfix` was removed from the script the same day. |
| | **`merchantWriteRejectsFlowbinDestination`** | **ADDED 2026-08-08 — P2.7 rule (e).** Merchant scope rejects a `flowbin`-type destination; putaway's FLA auto-creation would bind it to the first SKU and break every other SKU under that merchant. Verify: `V-noflowbin23` |
| | **`skuWritePermitsFlowbinDestination`** | **ADDED 2026-08-08** — tier 1 is exempt from rule (e); a SKU binding its own pick face is the intent. **Both tests are needed**: the reject alone would pass an implementation that bans flowbins everywhere. Verify: `V-flowbin1ok` |
| | **`merchantWritePermitsCasesAndPalletsDestination`** | **ADDED 2026-08-08** — guards the club use case. Rule (e) keys on `sltname == 'flowbin'`, so `cases and pallets` must still pass at merchant scope. This test fails if someone implements rule (e) with `useforpicking`. |
| | ~~`skuWriteRejectsFixAssignedLocation`~~ | ⚠ **DELETED 2026-08-08 (Q12 → iv-b).** It asserted the D15 enforcement point (P2.5, absolute at SKU scope), which no longer exists — under (iv-b) the config is legal and the *placement* is refused. Its verify checks `T-skufix` / `V-fixloc` were removed. **This test would fail a correct implementation.** |
| | ~~`skuWriteRejectsPickFaceDestination`~~ → **`pickFaceDestinationIsNotPlacedAtReceipt`** | ⚠ **REPLACED 2026-08-08 (Q12 → iv-b), and it moves out of `PutawayConfigServiceUnitTest` into `ReceivingServiceUnitTest`** (step 15). A pick face is now a **legal configuration at every scope**; what is refused is placing a receipt there. Pair it with `stagingLaneDestinationIsPlacedAtReceipt` — together they pin both halves of the split. Verify check `V-fixabs` removed. |
| | `skuWritePermitsPickFaceDestination` (**new**) | The positive half of the relaxation: an FLA-free pick face is **accepted** at SKU scope. **Fixture must be an FLA-free pick face** (the real shape: wineco's club locations — `useforpicking` true, zero FLA rows). Without this, nothing pins that the reject was actually dropped. |
| | `merchantWritePermitsStagingLane` | P2.7(a): `staginglane` / `crossdockinglane` are **permitted** at merchant/warehouse scope — guards against re-introducing the "a lane can never work" over-reject. Verify: `T-stagingok` |
| | `warehouseWriteRejectsLockedLocation` | absolute reject at warehouse scope |
| | `readCommittedDestinationUsesPerScopeQuery` | one case per scope; a MERCHANT read must **not** touch `itemdata` (§3.9.2) |
| | `clearWritesNullAndAudits` | `null` ⇒ no validation, still audited, `new_location_id IS NULL` |
| | **`warehouseClearWritesEmptyStringNotDelete`** | `sysvalue=''`, row still present |
| `PutawayConfigControllerUnitTest` (**new**) | `confirmationAbsentWithNonZeroCountReturns409` | the 409 branch of §3.5a's contract |
| | `confirmationCountMismatchIsRejected` | a stale count ⇒ 409, never a write |
| | `totalIncompatibilityReturns422` | and `blockingReason` ⇒ 422 |
| | `countRecomputedNotTrustedFromPreview` | the writer recomputes; the preview value is never authoritative |
| `PutawayConfigRepositoryEventHandlerUnitTest` (**new**) | `halItemdataWriteValidates` / `halClientWriteValidates` / `halSyspropWriteValidatesOnlyOurKey` | validation fires; other sysprops pass through untouched |
| | **`unrelatedFieldEditIsNotValidated`** | destination unchanged ⇒ the handler returns before validating (§3.9.3) — the edit-lock regression guard |
| | **`createPathNeverReadsPreviousValue`** | `@HandleBeforeCreate` does not call `readCommittedDestination` (§3.9.2) |
| | **`handlerThrowsUncheckedNotBusinessException`** | the rejection is a `PutawayConfigValidationException` (§3.9.7) |
| | **`syspropDeleteIsAudited`** | deleting the guarded syskey still deletes, and writes one audit row with `new_location_id IS NULL`; deleting any other syskey writes none (D12) |
| `SystemPropertyControllerUnitTest` | `createRejectsGuardedSyskey` / `updateValueRejectsGuardedSyskey` | §3.9.1; every other syskey still writes |
| `UnitloadBusinessServiceUnitTest` | `:193, 208` **rewritten** | rendered `unitloadTypeNotPermittedOnLocation`; **assertion tightened, never loosened**. A companion case asserts `putawayDestinationNotPermitted` is **not** produced here |
| `ReceivingServiceUnitTest` | `resolverInvokedOnceAboveLoop` | one `resolve` call for an N-case receipt |
| | `resolveIsCalledForBothBranches` | resolver called even when `carrier != null` — the 2731 regression guard |
| | `nonCarrierPathStillFailsOnIncompatibleDestination` | `carrier == null` + incompatible ⇒ `BusinessException`, and **no `Unitload` was created** |
| | `carrierPathDoesNotFailOnIncompatibleDestination` | `carrier != null` + incompatible ⇒ receipt completes, WARN logged, and the single `resolved(...)` counter carries `compatible="false"`; there is **no** separate counter |
| | `carrierPathPlacesOnCarrierAndWarns` | UL goes to the carrier; WARN + metric on a non-tier-4 source |
| | `resolverFailurePropagatesAsBusinessException` | never a bare `RuntimeException` (§3.6.2) |
| `ReceivingControllerUnitTest` | `getPutawayDestinationShape` | all 7 fields; `source` is the enum name |
| | `businessExceptionSurfacesMessage` | not the generic "contact support" string |
| `ItemDataControllerUnitTest` | `:111-153` extended | the live write path validates + audits; no `allEntries` eviction |
| `SkuRestControllerUnitTest`, `FileImportControllerUnitTest` | extended | created SKUs have `putawaylocationId == null`; the lane-presence guard still reports a missing lane |
| `EntityUnitTest`, `ItemdataRepositoryTest`, `TestDataFactory`, 3 H2 tests | updated | field no longer required |

### 7.2 Integration / context-load lane

| Test | State | Note |
|---|---|---|
| `PutawayResolverContextLoadTest` (**new**, `smoke/`) | `@Disabled` `TODO(SBDEV-2217)` | Autowires `PutawayDestinationResolver`, `PutawayDestinationQueryService`, `PutawayConfigService`, `PutawayDestinationValidator`, `PutawayResolutionMetrics`, `PutawayConfigRepositoryEventHandler`, `PutawayConfigController` (plus `PutawayConfigAuditService` from 1b) and asserts non-null. **Seven new beans is exactly the DI-drift risk unit tests cannot see.** Modelled on `smoke/ReplenishReassignContextLoadTest.java`. Run with `RUN_MVN=1` once the harness is restored. |
| `SkuRestControllerAtomicityIntegrationTest` | stays `@Disabled` | would otherwise prove the no-seed change end to end |
| `ReplenishorderRepositoryIntegrationTest:66`, `CustomerorderBatchServiceParallelStreamRegressionIT:187` | fixtures updated, stay `@Disabled` | |
| **`V2.2.11` themselves** | **no automated coverage** | harness scans a different directory (§2.9). Covered by §7.3 SQL rows plus the scratch-DB double-apply in Steps 3 and 20 only. **State this in both PR bodies.** |

### 7.3 Manual Test Plan (mandatory)

Every row assumes: **the migration its phase carries has been applied to the tenant first** — `V2.2.11` (§5.1 row 1). Cache note: after any config write, re-read **in the same browser session** — a 5-min Caffeine TTL means another replica may serve a stale value, so **do not** validate a config change by loading the screen on a different replica.

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|---|
| M1 | No config ⇒ no behaviour change | DEV `wh01_hydra_v2t` | Apply `V2.2.11` (one migration; the old "+ one more for the 1b run" reflected the superseded two-phase split). Receive a case of any SKU, no carrier. | Unit load lands on `PutAwayLane` exactly as before; `wms2.putaway.resolution{source="STANDARD_PUTAWAY_LANE"}` +1 | |
| M2 | Backfill correctness and pre-image capture | DEV DB | `SELECT count(*) FROM itemdata WHERE putawaylocation_id IS NULL` and `... IS NOT NULL` before/after; then the `captured` / `nulled` query in §5.1 | NULL count == pre-migration lane-id count; NOT NULL count unchanged; `captured == nulled` and both **non-zero** | |
| M3 | Warehouse default honored | DEV | Admin → Parameters → Configuration → Operation Options → set `DEFAULT_PUTAWAY_LOCATION` to a compatible storage location. Receive, no carrier. | Stock lands at that location; `source="WAREHOUSE_DEFAULT"` | |
| M4 | Merchant beats warehouse | DEV | Set a different compatible location on one merchant (Admin → Shippers). Receive for that merchant, then for another. | Merchant's location for the first; warehouse default for the second; sources `MERCHANT_OVERRIDE` / `WAREHOUSE_DEFAULT` | |
| M5 | SKU beats merchant | DEV | Set a third compatible location on one SKU. Receive it. | SKU's location; `source="SKU_OVERRIDE"` | |
| M6 | Clear cascades upward | DEV | Clear the SKU override → receive; clear the merchant → receive; blank the sysprop → receive. | Destination walks merchant → warehouse → `PutAwayLane`; the sysprop **row still exists** with `sysvalue=''` | |
| M7 | **Write-time rejection (the whole point of D6)** | DEV | Try to set a SKU whose `defultype_id` is `Case` to a `flowbin` location. | Rejected at save with a message naming SKU, destination, reason and remedy. **Nothing persisted**; `wms2.putaway.config.rejected` +1 | |
| M8 | **Merchant-scope count-and-confirm (D11)** | DEV | (a) Set a merchant default incompatible with *some* of its SKUs, no confirmation. (b) Re-issue with `confirmIncompatibleSkus=<n>` where `<n>` is the returned count. (c) Re-issue with a deliberately wrong `<n>`. (d) Set one incompatible with **all** of them. (e) Set a **locked** location. | (a) **409** naming the count and one example SKU; nothing persisted. (b) **write succeeds**, count recorded on the audit row. (c) **409** — stale confirmations never slip through. (d) **422**, no confirmation accepted. (e) **422** with `blockingReason=LOCKED`. `wms2.putaway.config.rejected` increments on each rejection | |
| M9 | **HAL bypass is closed** | DEV | `curl -X PATCH /v3/itemdata/{id} -d '{"putawaylocationId": <incompatible>}'`; repeat for `/v3/client/{id}` and `/v3/sysprop/{id}`. | All three **422** with the actionable message — **not** 4xx-in-general and **not** 500: a 500 means the handler threw a checked exception (§3.9.7). `wms2.putaway.config.rejected{channel="hal"}` +3. **A 2xx here means the event handler is not registered — hard stop.** | |
| M9a | **HAL edit of an unrelated field still works** | DEV | On the SKU whose destination is *already* invalid, `PATCH /v3/itemdata/{id}` changing only `description`; repeat on a client via the live shipper screen. | **2xx.** Validating the state rather than the delta would turn config rot into an edit lock (§3.9.3) | |
| M9b | **Direct-save bypass is closed** | DEV | `POST /v3/systemProperty/create` and `POST /v3/systemProperty/updateValue` with `key=DEFAULT_PUTAWAY_LOCATION`; then the same two calls with any other key. | The guarded key is **rejected** with a message pointing at `PUT /putawayConfig/warehouse`; every other key writes exactly as today. **A success on the guarded key means N1 was not fixed — these endpoints publish no SDR event, so the handler cannot see them** (§3.9.1) | |
| M9c | **Delete is accepted, audited, and not a trap (D12)** | DEV | Press the delete button on the `DEFAULT_PUTAWAY_LOCATION` row in Operation Options. Then, **without any SQL**, set a warehouse default again from the same screen. | The row is deleted and the operation reports success; one `putaway_config_audit` row records the clear with `new_location_id IS NULL`; receiving falls through to tier 4. The Operation Options screen **still offers the control** and setting it **re-creates the row**. Deleting any other sysprop behaves exactly as today | |
| M10 | **Receive-time backstop** | DEV DB + UI | Configure a valid destination, then `UPDATE location SET type_id = <incompatible> WHERE id = ...` behind the app's back. Receive. | Receipt **hard-fails** with the actionable message (not silently rerouted); whole receipt rolled back, no `goodsreceiptposition` rows; `wms2.putaway.resolution.rejected` +1 | |
| M11 | Carrier receipt | DEV | With a merchant default set, receive **onto a carrier pallet**. | Unit load on the carrier (unchanged); receiving form **displays** the configured destination + source; WARN logged; `resolution{carrier="true"}` +1 | |
| M12 | Hub-and-spoke null SKU | DEV | Receive against a `createHubAndSpoke` advice position (`itemdataId IS NULL`). | No 500. Resolution starts at tier 2 | |
| M13 | Mobile putaway not broken, and the message is the expected one | DEV mobile | After a direct placement to a **storage-area** location, scan that unit load in mobile putaway. | Pre-existing **`unitloadNotInInboundArea`** message from `MobilePutAwayService.java:113-117` (expected, not a crash) — **not** `unitLoadNotInPutAwayLane`, which is unreachable for a storage-area unit load. A unit load actually on the lane still puts away normally, and `storePalletBackOnPutawayLane` still enforces its user-location guard | |
| M13a | **Recovery path for a misplaced unit load** | DEV mobile + web | Take the unit load from M13 and move it with mobile "Move Unit Load" (`MobileMoveUnitloadService`); repeat with the web **Transfer Stock** screen. | Both move it successfully. This is the documented remedy an operator is given when putaway refuses a directly-placed unit load — the unit load is not stuck (§3.7.4) | |
| M13b | **Multi-case receipt into a location under concurrent replenish/transfer** | DEV | Point the warehouse tier at a live **storage** location (the advanced tier of the picker). Start a multi-case receipt into it while a replenishment or transfer task is working the same location. | Either both complete, or the receipt fails with a rollback and a `40P01` / `DeadlockLoserDataAccessException` appears in the log. **Record which.** This is the only manual probe for §7.6 row 8's lock-order inversion; note that `/receiving/receive` returns 200-with-`errors`, so watch the log, not the HTTP status | |
| M14 | Inventory history names the real destination | DEV DB | After M3, `SELECT * FROM unitload_record WHERE unitload_id = ... ORDER BY id` | Destination location is the configured one, not `PutAwayLane` | |
| M15 | Audit trail | DEV DB | After M5 + M6 + M9, `SELECT * FROM putaway_config_audit ORDER BY changed_at` | One row per change; correct `scope`, `subject_label`, previous/new (id **and** name), `changed_by` = the Keycloak user, `channel` `typed`/`hal` | |
| M16 | Permissions — typed endpoints | DEV | Repeat M5 as a non-`sb_admin` user, via UI **and** via curl against `PUT /putawayConfig/sku/{id}`. | 403 from the API; the field is hidden/disabled in the UI | |
| M16a | **Permissions — HAL channel** | DEV | As a non-`sb_admin` user: `curl -X PATCH /v3/sysprop/{id}` changing `DEFAULT_PUTAWAY_LOCATION`; repeat on `/v3/itemdata/{id}`. | **403**, not 422 and not 200. A 200 means the authorization check is inert — which is exactly what happens if `@PreAuthorize` is placed on the event-handler methods instead of on `PutawayConfigService` (§3.9.4, §3.12). **Hard stop.** | |
| M17 | Receiving form shows source | DEV | Open the receive form for a SKU with a merchant default. | Value is the effective location (**not** the literal "Put Away Lane") plus a "Merchant default" chip | |
| M18 | persistedState isolation | DEV | Set a value on tenant A, switch to tenant B in the same browser, open the config screen. | Tenant B shows **its own** value — no bleed from `localStorage['vuex-web']` | |
| M19 | Rollback drill | DEV | On a copy: run the §5.1 one-statement replay (`UPDATE itemdata … FROM putaway_config_audit WHERE channel='migration'`), blank the sysprop, `UPDATE client SET defaultputawaylocation_id = NULL`, redeploy the previous app version. | Receiving works exactly as pre-change; every SKU is back on its recorded pre-migration destination; the `client` column and audit table are harmlessly orphaned (§8.3) | |
| M20 | **The display endpoint is reachable at all** | DEV | `curl GET /receiving/getPutawayDestination/{advicePositionId}` against a real advice position. | **200** with the 7-field envelope. A 500 with `IllegalTransactionStateException: No existing transaction found … 'mandatory'` means the controller calls the resolver directly instead of the §3.1.5 facade — no mocked unit test can catch this. **Hard stop for Phase 1.** | |
| M21 | **Receipt correction after direct placement (N-22)** | DEV | Receive a SKU whose tier-1 destination is a **non-lane** location, then `delete` **and** `adjust` that goods-receipt position | Per the §6 decision: either both succeed, or both fail with an actionable message that names the destination and says correction is unavailable for directly-placed receipts. **A raw `"UnitLoad not in area for goods in anymore"` is a FAIL** — that is the unhandled path. | |

### 7.4 e2e lane

M3 → M5 → M6 → M17 executed in one browser session against DEV constitute the e2e path: configure at three tiers through the real UI, receive through the real receiving screen, observe the effective destination in the form and the stock in the resulting location. Automated e2e is **not** added — there is no e2e harness for wms2-web-ui and building one is out of scope.

### 7.5 Observability lane

| Check | How |
|---|---|
| all four counters registered | `GET /actuator/metrics/wms2.putaway.resolution` etc. after one receipt |
| tag cardinality bounded | `source` ≤ 4, `carrier` ≤ 2, **`compatible` ≤ 2**, `scope` ≤ 3, `channel` ≤ 3 (`typed`/`hal`/`migration`), `tenant` ≤ 5 ⇒ **≤ 80 series** on `wms2.putaway.resolution` |
| **tier-2/3 adoption is observable** | after Phase 2, `wms2.putaway.resolution{source="MERCHANT_OVERRIDE"}` + `{source="WAREHOUSE_DEFAULT"}` > 0. **This is pre-mortem P2's only detector** and the §8.1 gate for closing 2731/2643. |
| backstop is quiet | `wms2.putaway.resolution.rejected` == 0 in steady state; alert on > 0 |
| bypass is visible | `wms2.putaway.config.changed{channel="hal"}` should trend to 0 after Phase 2 |

### 7.6 Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | introduce state that exists in only one replica? | **No — BY DESIGN, re-verify post-implementation** | No new cache, no `ConcurrentHashMap`, no static. The four existing caches are reused; `CacheConfig` is untouched. `PutawayResolutionMetrics` holds only counters (`MeterRegistry` is per-replica by design and aggregated by the scraper). **One caveat:** §3.9.6's previous-value carrier between the `Before` and `After` handler phases is request-scoped state; it must be a `@RequestScope` bean or a `ThreadLocal` cleared unconditionally, and it is per-request, not per-replica. |
| 2 | **Connection pool math** | change per-request DB connection usage? | **No — BY DESIGN, re-verify post-implementation** | The resolver adds at most 4 short queries **inside the caller's existing transaction** — same connection, no new pool, no new tenant. Net query delta on the receiving path is ≈ +2 (it also *removes* the old `findById`). |
| 3 | **Scheduled jobs** | add or modify a `@Scheduled` job? | **N/A** | No job is added or touched. |
| 4 | **Long transactions** | hold a transaction across more repository calls or external I/O? | **Yes, marginally — BY DESIGN, re-verify post-implementation** | +≈4 index-backed lookups inside `receiveGoods`' existing transaction, all before the per-case loop. No HTTP, no printer call, no broker. Expected added duration < 5 ms vs HikariCP `connectionTimeout` — immaterial. Config writers are single-entity transactions. (The *lock hold* duration is the separate concern in row 8.) |
| 5 | **Request affinity** | assume a follow-up request lands on the same replica? | **No — BY DESIGN, re-verify post-implementation** | `getPutawayDestination` is stateless and re-resolves from the DB. |
| 6 | **Retry / idempotency** | rely on single-execution semantics? | **No — BY DESIGN, re-verify post-implementation** | Config writes are idempotent last-writer-wins on a single column, protected by the entity `@Version`. `/v3/receiving/receive` is outside `IdempotencyFilter` (which guards `/rest/**`) — unchanged by this plan, not made worse. The audit table may gain a duplicate row if a client retries a config write; duplicate audit rows are harmless and, in fact, the correct record of two requests. |
| 7 | **Tenant context** | use `TenantContext` across an async boundary? | **No — BY DESIGN, re-verify post-implementation** | Everything runs on the request thread. `PutawayConfigAuditService` reads `TenantContext.getCurrentTenant()` synchronously. No `@Async`, no `CompletableFuture`. |
| 8 | **Distributed lock correctness** | add or rely on cross-replica locking? | **YES — accepted risk with named mitigations** | The resolver itself takes no lock and cannot open `REQUIRES_NEW` (`MANDATORY`). It does not follow that no transaction exists: §3.1.5's read facade opens a `readOnly = true` tenant transaction and §3.9.6's `auditAndEvict` opens a read-write one; `MANDATORY` means the resolver *joins* a transaction. **The real exposure is a lock-order inversion that this change makes newly reachable.** `transferUnitLoadToLocation` takes `findByIdForUpdate` on the **destination** Location at `:150` *before* touching Unitload/Stockunit at `:293-294` — Location→UL, **inverting the SBDEV-2232 canonical SU→UL→Location order**. That is harmless today only because receiving's destination is *always* the inbound `PutAwayLane`, a row only receiving and mobile putaway touch. Once tiers 1–3 can point at a live storage or pick location, a receipt holds `FOR UPDATE` on that row for the **whole multi-case receipt**, including across per-case `createCaseLabel` rendering (`ReceivingService.java:491-498`, both inside the loop), while picking, replenishment and transfer lock in SU→UL→Location order. There is **no deadlock-retry infrastructure** in this codebase (SBDEV-1762: "up-front lane-Location lock is an anti-pattern (cross-caller 40P01)"). **Four requirements, all specified elsewhere in this plan:** (i) the deferred "stock-move deadlock-retry hardening" ticket is a prerequisite before any tenant points tier 2 or tier 3 at a live storage location — and an absolute prerequisite before Q9 widens P2.4 to admit pick locations; (ii) the location picker is **tiered** — `useforgoodsin` by default, `useforstorage` behind an explicit "advanced" toggle carrying this lock warning (§3.11.2, Step 26); (iii) manual row **M13b** exercises a multi-case receipt into a location concurrently being picked or replenished; (iv) the **40P01 / `DeadlockLoserDataAccessException` detector** on `/receiving/receive` is budgeted as §5.1 row 8 item (c) — it must be log/exception-based, because that endpoint returns **200-with-`errors`**, never a 5xx, so an HTTP-status alert misses it entirely (the same trap as pre-mortem P3). |
| 9 | **Cache invalidation** | write to a cached entity? | **Yes — three of them; BY DESIGN, re-verify post-implementation** | `itemdata` (2 keys, reusing the correct expressions at `ItemdataService.java:62-67`), `clients` (2 keys, §3.3), `sysprops` (1 key, defensive). Under the **Redis** profile eviction propagates across replicas; under **Caffeine** it does not, so another replica can serve a stale config for up to its TTL. **Accepted**, because (a) the *receiving* path reads all three tiers uncached (§3.10), so no receipt is ever misrouted by a stale cache, and (b) the exposure is admin-screen display only. §7.3's cache note encodes it. HAL writes reach the same evictions because the event handler delegates to `PutawayConfigService`. |
| 10 | **External notifications** | send HTTP/message to an external system inside a transaction? | **No — BY DESIGN, re-verify post-implementation** | No OMS notification, no outbox message, no printer call. Label printing at `ReceivingService.java:498` is unchanged and already outside the failure path. |

#### Evidence (for the "Yes" rows)

| Concern # | What was done / verified | Reference |
|---|---|---|
| 4 | resolution hoisted above the per-case loop, so the added queries are O(1) per receipt, not O(cases) | §3.7.1; loop at `ReceivingService.java:462` |
| 9 | eviction key expressions copied verbatim from the existing correct implementation, not re-derived | `ItemdataService.java:59-67`; `ClientService.java:53, 100` |
| 9 | receiving path is uncached on the three **tier value** reads, but **not** entirely cache-free | `ReceivingService.java:357` (`itemdataRepository.findById`), `:369-370` (`clientRepository.findById`), `SyspropRepository.java:35-36` (`findBySyskeyAndClientIdAndWorkstation`, a derived query, not `@Cacheable`). Tier 3 additionally dereferences `clientService.getSystemClient()`, which **is** `@Cacheable(value="clients", key=…+':SYSTEM')` (`ClientService.java:100`) — harmless, since the system client's identity does not change, and safe under `readOnly` (a cache read inside a read-only tx is fine). `ClientService.java:101-109` returns `null` when no `cl_nr='System'` row exists, so tier 3 `orElseThrow`s a `BusinessException` rather than dereferencing it (§3.4a): an NPE there would be a bare `RuntimeException`, the class §3.6.2 forbids, and `ReceivingController:298-300` would swallow it into "contact support". |
| 9 | `CacheConfig` needs no change ⇒ the two-profile sync trap is avoided entirely | `CacheConfig.java:31-42, 49-69`; guarded by `unit/config/CacheConfigTest.java` |
| 8 | `Propagation.MANDATORY` chosen specifically to make `REQUIRES_NEW` unrepresentable | §3.1; `UnitloadBusinessService.java:214-215` |

### 7.7 v2-only constraint checklist (8 rows, explicit verdict each)

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | Every new tenant service method carries `@Transactional(value = "tenantTransactionManager", …)` — a **bare** `@Transactional` silently binds to the `@Primary` landlord TM | **BY DESIGN — re-verify post-implementation** | resolver `MANDATORY` + tenant TM; query facade `readOnly = true` + tenant TM; writers `rollbackFor = {BusinessException, FacadeException}` + tenant TM; audit `MANDATORY` + tenant TM. `unit/config/TransactionManagerArchTest.java` enforces it; verify-script rows P1-TX-* assert the literal string per file. |
| 2 | The resolver must **not** be `readOnly = true` (landmine A1) and must **not** open `REQUIRES_NEW` | **BY DESIGN — re-verify post-implementation** | `Propagation.MANDATORY` with no `readOnly`. A1 is moot anyway — `getStringDefault` is never called (§3.4a), asserted by `neverCallsGetStringDefault`. `MANDATORY` is kept deliberately, but it constrains **who may call** `resolve(...)`: the non-transactional display endpoint goes through the §3.1.5 read facade, and the non-transactional SDR event handler never calls the resolver or a `MANDATORY` audit writer from its `Before` phase (§3.9.6). Every call-site must be confirmed transactional — §7.7a. |
| 3 | OSIV is disabled ⇒ load entities inside the transaction or return ids/DTOs | **BY DESIGN — re-verify post-implementation** | All eight entities involved use manual `Long` FK ids with **no JPA associations**; `Resolution` holds a fully-loaded `Location` obtained inside the caller's transaction. |
| 4 | Cache evictions cover every write path, in **both** profiles | **BY DESIGN — re-verify post-implementation** | §3.10; no new cache ⇒ nothing to duplicate. HAL writes delegate to `PutawayConfigService` so they share the evictions. |
| 5 | Jakarta namespace only (`jakarta.*`) | **BY DESIGN — re-verify post-implementation** | Nothing is ported from v1 (SBDEV-2642 shipped no code). New entity mirrors `CustomerorderCancellationLog`'s `jakarta.persistence.*` imports. |
| 6 | H2-safe SQL in anything a non-Testcontainers test exercises | **BY DESIGN — re-verify post-implementation** | No new `@Query`. The only native SQL is `readCommittedDestination`'s three per-scope statements; the SKU and MERCHANT forms are H2-compatible, and the WAREHOUSE form's `nullif(trim(sysvalue),'')::bigint` is **Postgres-specific** — if any H2 test exercises it, use `CAST(... AS BIGINT)` instead. `V2.2.11` is Postgres-only but runs in no test (§7.2). |
| 7 | New/changed endpoints need a `BaseControllerTest` subclass | **BY DESIGN — re-verify post-implementation** | `getPutawayDestination` covered in `ReceivingControllerUnitTest`; `PutawayConfigController` in `PutawayConfigControllerUnitTest`; `SystemPropertyController`'s guards in `SystemPropertyControllerUnitTest`; the HAL PATCH guard needs its own controller test (M9 is its manual twin). |
| 8 | Entity/DDL drift ⇒ entity and DDL land together | **BY DESIGN — re-verify post-implementation**, with the §5.1 row-1 blocker | `Client.defaultputawaylocationId` and `PutawayConfigAudit` both land in the single Phase 1-API commit alongside `V2.2.11`. **`ddl-auto` is `none`, so drift does not fail startup — it fails `42703` per request.** `develop` merge ⇒ DEV auto-deploy; the runtime migrator applies `V2.2.11` at boot on tenants that have Flyway history, but **skips the history-less Hydra DEV copy**, which is why §5.1 row 1 requires repairing that copy and pre-applying. Still the single most likely way this plan ships broken (pre-mortem P1). |

> **Verdict semantics.** Every verdict in §7.6 and §7.7 describes *design intent about code that does not
> exist yet*, which is why none of them reads PASS. **The verify script and the post-implementation gate
> hold the real PASS/FAIL; these two tables hold intent only.**

### 7.7a Resolver call-site transaction audit (MANDATORY before Phase 1 merges)

`resolve(...)` is `Propagation.MANDATORY`, so **every** call-site must already be inside a tenant
transaction or it throws `IllegalTransactionStateException` at runtime — a failure no grep check and no
mocked unit test can detect. Enumerate and confirm each:

| # | Call-site | Transaction present? | Evidence / required change |
|---|---|---|---|
| 1 | `ReceivingService.receiveGoods` (§3.7.1, resolution hoisted above the per-case loop) | **Yes — pre-existing** | `@Transactional(value = "tenantTransactionManager", …)` at `ReceivingService.java:302`. No change needed. |
| 2 | `ReceivingController.getPutawayDestination` (§3.8) | **Only via the facade** | There is **zero** `@Transactional` in `ReceivingController.java` and none anywhere under `controller/`. The controller therefore delegates to `PutawayDestinationQueryService.describeForAdvicePosition`, annotated `@Transactional(value = "tenantTransactionManager", readOnly = true)` (§3.1.5). This is **Phase 1 Step 14**; manual row M20 is the proof. |
| 3 | `PutawayConfigRepositoryEventHandler` (§3.9) | **Never calls the resolver, and never a `MANDATORY` writer from `Before`** | `@HandleBeforeSave`/`@HandleBeforeCreate` fire from `RepositoryEntityController` *before* `repository.save()`, outside any transaction; OSIV is off (`application.properties:55`) so there is not even a persistence context. The `Before` phase calls only `readCommittedDestination` (`readOnly = true`, opens its own) and `validateOnly` (no transaction, no write); the audit lands in the `After` phase via `auditAndEvict`, which opens its own read-write tenant transaction **after** SDR's save has committed (§3.9.6). |
| 4 | Typed config-write endpoints (§3.5, §3.5a) | **Yes — by construction** | Each writer is annotated `@Transactional(value = "tenantTransactionManager", rollbackFor = {…})`. `PutawayConfigController.preview` carries `readOnly = true` for the same reason as row 2. |
| 5 | `GET /client/{id}/effectivePutawayDestination` (N9, §3.11.3, Phase 1) | **Must reuse the §3.1.5 facade** | It goes through `PutawayDestinationQueryService.describeForClient` for the same reason as row 2 — do not let it call the resolver from a controller. |

**Adequacy note.** `readOnly = true` on rows 2 and 5 is safe **only** because §3.4a reads tier 3 via
`SyspropRepository` and never calls `SyspropService.getStringDefault`, which INSERTs on a total cascade
miss (`SyspropService.java:234`, landmine A1). `neverCallsGetStringDefault` is the assertion that keeps
that invariant true; if it is ever deleted, rows 2 and 5 become write-in-readOnly-transaction bugs.

### 7.8 Deliberately-skipped coverage

| What | Why |
|---|---|
| Automated test for `V2.2.11` | The IT harness scans `db/v1-to-v2-onboarding/schema`, not `db/migration/` (§2.9). Covered by M2 + the scratch-DB double-apply in Steps 3 and 20. |
| Automated e2e | No e2e harness exists for `wms2-web-ui`; building one is out of scope. Covered by §7.4's manual path. |
| `AdviceService.acceptHubAndSpokeAdvice` (§0.1 row 25) | No `Itemdata`, no receipt destination decision. §10 Q4. |
| Mobile UI (`storePallet.vue`) | Not in D4's phasing. §8.4. |
| A UI for reading `putaway_config_audit` | The AC says "recorded", not "displayed". §8.4. |
| Concurrency test on config writes | Single-column last-writer-wins under `@Version`; no invariant spans two rows. |

---

## 8. Rollout

### 8.1 Merge order — TWO merges plus an external prerequisite; the DEV-apply gate binds to merge 1

**One migration, one gated merge.** Earlier revisions split this into two migrations across four
merges so an ungated slice could ship first. D12 removed that: the ungated slice is now **SBDEV-2731 PR1**,
which is not this plan's merge at all. What remains is a single `V2.2.11` that adds
`client.defaultputawaylocation_id` — a column `Client` maps — so **merge 1's operator gate is absolute.**

**Q7 is CLOSED (D12).** The earlier blocker here read "confirm nobody is mid-flight on an overlapping
resolver". The SBDEV-2731 plan now exists and was inspected: it contains **zero** occurrences of resolver,
tier, precedence or merchant, and builds no competing resolution. This plan remains sole owner of the
precedence contract, and **Q7 no longer blocks the TDD gate.**

| # | Merge | Operator gate | Verify on DEV after |
|---|---|---|---|
| **0** | ~~**SBDEV-2731 PR1** → `develop`~~ **MERGED 2026-08-07** — api `6bc709a`, ui `4ce39a1`. Prerequisite 0 satisfied. *(external prerequisite, D12)* | none | 2731's own verify script; **then close SBDEV-2731 on PR1 — and say explicitly in the ticket that the reported 1,000-unit ICE PACK receipt is NOT yet fixed** (it is a tier-1 override into a pick face). *(2026-08-04: F3 itself is answered — SBDEV-2796 chose (c), so that receipt is now **permitted** to succeed and over-fill the bin. What still gates it is no longer the product question but **C2b, Q1, Q4** and the new **Q11**, and the Fix B work those gate now lands in this plan — §5.2, §10.4.)* |
| **0b** | ~~**SBDEV-2854 (PR #132) → `develop`**~~ **MERGED 2026-08-07** (`68274b0`). **STILL OPEN: `V2.2.10` applied to every tenant this plan's `V2.2.11` will reach** *(external prerequisite, added 2026-08-06)* | `V2.2.10` | **Ordering is load-bearing and runs the other way from what you would guess.** 2854 renumbered *down* from `V2.2.11` to `V2.2.10` to keep the sequence contiguous, so this plan moved to `V2.2.11`. If `V2.2.11` is applied **first**, `V2.2.10` arrives out-of-order: `outOfOrder=false` skips it and `validateOnMigrate=true` then throws *"Detected resolved migration not applied to database: 2.2.10"* on every subsequent boot — caught by `StartupFlywayMigrator.java:150`, logged, and **swallowed**, so the tenant silently stops receiving that and every later migration. This is the exact failure the renumber was performed to avoid, with the roles reversed. Verify with `SELECT version FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 3;` before applying `V2.2.11` anywhere. |
| **1** | **1-API** → `develop` (DEV auto-deploys) | **`V2.2.11` applied to every DEV tenant FIRST** (operator, Flyway runbook `--env dev`). Absolute: the merge adds `Client.defaultputawaylocationId`. `ddl-auto` is **`none`**, so the context starts anyway and instead throws **`42703`** on every `client` read — DEV looks healthy while receiving and the client screens error per request (pre-mortem P1). **Repair the history-less Hydra DEV copy with `db/backfill-flyway-history.sh` first**, or the boot-time migrator skips it and `V2.2.11` never applies there. The Hydra dev copy has **no `flyway_schema_history`**, so verify via `information_schema.columns` + a `los_sysprop` query, never Flyway history. Per-tenant precheck first: `SELECT count(*) FROM location WHERE name='PutAwayLane';` must be exactly 1 (verified on `wh01_hydra_v2` and `wh01_hydra_v2t`; **the other three v2 tenants are unverified**). | `PHASE=1` verify 0-fail; M1, M2 (backfill counts **and** `captured == nulled`); M9 (all three HAL PATCHes ⇒ **422**); M10; M12 |
| **2** | **2-UI** → `develop` | none | M3, M5–M7, M11, M13, M13a, M13b, M14, M16, M17, M18 — **then close SBDEV-2732** |

**Why the Phase 1-API gate is absolute.** DEV auto-deploys on push. The app *does* run Flyway at boot
(SBDEV-2801) — but it **skips a tenant DB with no `flyway_schema_history`**, and the Hydra DEV copy is one,
so there `V2.2.11` never applies. And because `ddl-auto` is **`none`**, the app does not refuse to start:
it boots green and fails `42703 column client.defaultputawaylocation_id does not exist` on every read.
So merging Phase 1-API before the operator has migrated **takes DEV down** — the ordinary merge workflow is
itself the failure path (pre-mortem P1). Verification there is unusual: the Hydra dev copy has **no
`flyway_schema_history` table**, so "check Flyway history" is invalid — confirm via
`information_schema.columns` and a `los_sysprop` query instead.

**Per-tenant precondition, and it binds the single Phase 1-API merge.** The preflight guard lives in `V2.2.11`
and aborts unless exactly one location is named `PutAwayLane`. Verified = 1 on `wh01_hydra_v2` and
`wh01_hydra_v2t`; **the other three v2 tenants are unverified.** Run
`SELECT count(*) FROM location WHERE name='PutAwayLane';` on each before scheduling `V2.2.11` — a zero is
tolerated by today's code (`FileImportController:355-359` exists precisely because a tenant can lack the
lane) but will abort this migration.

**After both merges**

1. **Close SBDEV-2731** as delivered — its display half is 1a-UI, its honor half is §3.7. It must not be
   worked independently (D8/D9).
2. **Unblock SBDEV-2643.** Its backend already exists and is now validated and audited. But §10 Q3: it is
   materially bigger than "add a field" — `skuData.vue:107-131` has its create/edit block commented out,
   so it needs a SKU edit form built from scratch. Estimate accordingly.
3. **Do not declare the feature delivered on green tests.** Gate on adoption:
   `wms2.putaway.resolution{source="MERCHANT_OVERRIDE"|"WAREHOUSE_DEFAULT"} > 0` (§7.5). This is the only
   detector for pre-mortem P2 — the plan's most likely failure, in which everything ships, every test is
   green, and no operator ever sets a tier-2/3 value.

**UAT** — apply `V2.2.11` **first** (UAT `wsl` trails; confirm its Flyway head), then
deploy, then M1/M3/M4/M5. **Production** — apply both **first** to the single v2 prod tenant, then deploy.
Ship with all three tiers unconfigured and enable per merchant on request, so the blast radius at cutover
is zero by construction.

### 8.2 Blast radius per tier

| Tier | Blast radius of a bad value | Gate |
|---|---|---|
| SKU | one SKU | write validation + receive backstop |
| Merchant | all SKUs of one merchant | write validation across the merchant's DISTINCT `defultype_id` set |
| **Warehouse** | **every receipt for every merchant** | write validation across the tenant's DISTINCT `defultype_id` set, with an explicit count-and-confirm above zero and an unconditional 422 at 100 % (D11); seeded blank; `sb_admin` only, enforced in `PutawayConfigService`; event handler covers `PATCH /v3/sysprop/{id}` and `DELETE /v3/sysprop/{id}`; `SystemPropertyController`'s two direct-save endpoints reject the syskey (§3.9.1). Pre-mortem **P3**. |

### 8.3 Rollback

Code: revert the PRs for the phases being rolled back. Data: `V2.2.11` is **forward-only** and needs no down-migration to make the previous app version work — see M19. Restoring `NOT NULL` requires the §5.1 one-statement replay from `putaway_config_audit` first (falling back to `UPDATE itemdata SET putawaylocation_id = <laneId> WHERE putawaylocation_id IS NULL` if the pre-image is missing); the `client` column and the audit table can be left in place harmlessly (the reverted app never reads them, and with `ddl-auto=none` nothing inspects the schema at startup — extra columns and tables are inert). **Do not drop `client.defaultputawaylocation_id` or `putaway_config_audit` on a rollback** — a re-roll-forward would then need a second migration version, and dropping the audit table destroys the only record of what the backfill discarded.

### 8.4 Explicit follow-ups (not in this plan)

- **[SBDEV-2821](https://app.clickup.com/t/868km8j9z) — tier-1 direct placement onto a pick face. OWNS everything D15 defers.** Filed 2026-08-04 so the deferred bundle has an owner: 2731 **Fix B** (flowbin classification + resident-UL resolution), **C2b**, 2731's **Q1**/**Q4**, **F1**, **F4**, **F5**, **Q11**, the coupled receipt-correction-guard decision, and the over-bound observability obligation. **It also owns the relaxation of P2.5 and P2.7(c)** — and carries the warning that relaxing either without the placement work in the same change re-enables the broken path, because `ReceivingService.java:454-457 → :491` places tier-1 destinations with no gate. **SBDEV-2821 is what delivers the reported ICE PACK receipt**, which neither 2731 PR1 nor this plan does. **Q11 was answered on 2026-08-06 — "bounds are advisory for replenishment", the same as for receiving.** ~~Strict order unchanged: 2731 PR1 → this plan → SBDEV-2821.~~ **⚠ THE ORDER IS REVERSED — see Q15 below. It is now `2731 PR1 → SBDEV-2821 → this plan`.**

  > **⚠ THIS BULLET IS SUPERSEDED — SBDEV-2821 adopted option (iii) on 2026-08-08.** It no longer builds direct
  > placement, so **Fix B, C2b, F1, F4, F5, the receipt-correction-guard decision and the three `Flowbin*`
  > message keys are all OUT OF SCOPE THERE** — none of them is being built by anyone. 2821 instead routes at
  > putaway: the container receives, and the SKU's configured location is consumed by `MobilePutAwayService`,
  > whose `storeBoxOnLocation:471-489` already performs flowbin classification, FLA auto-creation and
  > resident-UL merging. **C2b becomes unreachable** rather than deferred, because `Goodsreceiptposition` is
  > never repointed. 2731's **Q1** is closed (label prints; no code) and **Q4** is closed (option (iii)).
  >
  > **UPDATED AGAIN 2026-08-08 (Q12 → iv-b).** This plan permits pick-face destinations at every scope and
  > **diverts them at receipt** (step 15's `useforpicking` gate) rather than placing them. What 2821 needs from
  > here is that the configuration be writable — delivered by relaxing P2.5/P2.7(c) **in the same change as the
  > gate**. Non-pick-face destinations are still placed at receipt by step 17 and never reach putaway.
  >
  > **✅ Q15 — the tier seam — RESOLVED 2026-08-08 as (A). THIS PLAN NOW SHIPS *AFTER* SBDEV-2821.**
  >
  > Under (iv-b) putaway must consume **pick-face destinations for all four tiers**, but SBDEV-2821's plan is
  > written for **tier 1 only** (it reads `itemdata.putawaylocation_id` directly). The two candidate splits
  > were:
  >
  > - **(A) 2821 ships tier 1 only, independently** — it needs nothing from this plan and is gated only on M1,
  >   so it **delivers the reported ICE PACK fix immediately**. This plan then extends putaway to consume the
  >   full four-tier `Resolution`.
  > - **(B) 2821 waits for this plan's resolver** and consumes all four tiers in one change. Cleaner seam, one
  >   implementation — but it puts the reported production bug behind this entire plan.
  >
  > **(A) chosen by the ticket owner (Nam Park), 2026-08-08.** Schedule-only and reversible; nothing in either
  > design changes if it is revisited.
  >
  > **⚠ WHAT THIS COSTS THIS PLAN — a new dependency and a new step.** The bullet above used to end *"Strict
  > order unchanged: 2731 PR1 → this plan → SBDEV-2821"*, written when 2821 was the follow-up that *consumed*
  > this plan's output. **Under (iv-b) the arrow reverses.** Step 15's gate diverts a pick-face destination to
  > the standard putaway lane — and putaway can only offer that destination once SBDEV-2821 §3.2 ships,
  > because `getStorageLocationsForPutAwayItemData` (`LocationRepository:104-111`) returns only locations
  > where the SKU **already has stock**. Consequences, all recorded:
  >
  > - `depends_on:` gains **SBDEV-2821** (frontmatter).
  > - **§5.2 gains step 17a** — extend 2821's candidate surfacing from `itemdata.putawaylocation_id` to the
  >   full four-tier `Resolution`. Without it, merchant- and warehouse-scope pick-face defaults are diverted
  >   by step 15 and then never offered.
  > - **Degraded, not broken, if the order is violated:** the operator can still *manually scan* the
  >   destination (`MobilePutAwayService.verifyScannedLocation:403-447` accepts it), so shipping this plan
  >   first makes the destination undiscoverable rather than unreachable — a UX regression against the
  >   ticket's intent, not data loss.
  >
  > See `SBDEV-2821-tier1-direct-placement-onto-pick-face.md` §0 and §3.2.

  > **⚠ ORPHANED ARTIFACT found 2026-08-06 — three message keys with no owner.** SBDEV-2731's plan
  > (revision 4, §5) records these as *"RELOCATED to SBDEV-2732 (D14) — do NOT add in PR1"*:
  > ```properties
  > BusinessException.FlowbinAssignedToOtherSku=Pick location "%1$s" is already assigned to SKU %2$s, so SKU %3$s cannot be received into it. Choose a different Default Putaway Location.
  > BusinessException.SkuAlreadyAssignedToFlowbin=SKU %1$s is already assigned to pick location "%2$s" and cannot also be received into "%3$s". Clear the existing assignment first.
  > BusinessException.FlowbinOccupiedWithoutAssignment=Pick location "%1$s" already holds stock but has no SKU assignment, so SKU %2$s cannot be received into it. Ask an administrator to reconcile the location.
  > ```
  > **They are thrown only by Fix B — and D14 (2026-08-02) sent them here, but D15 (2026-08-04) then sent
  > Fix B onward to SBDEV-2821.** The keys did not follow. A grep of `sbdocs/1-Projects/wms2/plan/` finds
  > them **only** in the 2731 document: this plan does not carry them, SBDEV-2821 does not mention them,
  > and 2731 is explicitly not adding them. **They belong to SBDEV-2821, with Fix B.** Add them to that
  > ticket rather than to this plan's bundle — an unreachable operator-facing string invites a reviewer to
  > wire it up prematurely, which is precisely why 2731 declined to ship them.
  >
  > **This is the third artifact orphaned by the same mechanism** — F3/Q5 (became SBDEV-2796), the D15
  > bundle (became SBDEV-2821), and now these keys. Each time, scope moved between tickets and something
  > attached to it did not. **When D-decisions relocate scope, enumerate what travels with it:** code,
  > tests, message keys, verify checks, and open questions.
- **[SBDEV-2796](https://app.clickup.com/t/868kk4rmv) — pick-face capacity (F3 / Q5). ANSWERED 2026-08-04: option (c), "valid, and bounds are advisory for receiving."** No capacity gate is built; a 1,000-unit receipt into an 84-capacity bin succeeds and the over-bound bin is an accepted, documented state. **The tier-1 direct-placement block is lifted** — but under **D15** that path is deferred anyway, so Fix B, flowbin classification and resident-UL resolution stay OUT of this plan. The three items below travel to the follow-up: **Three items remain open and two of them are that ticket's own unmet ACs:**
  - **Replenishment behaviour against a permanently over-bound bin — ANSWERED 2026-08-06 ("advisory for replenishment"); owned by [SBDEV-2821](https://app.clickup.com/t/868km8j9z).** SBDEV-2796 AC: *"Replenishment behaviour against an over-bound bin is defined, or over-bound bins are made unreachable"*; (c) deleted the second branch. **Referred back to the B/A.** Tracked here as **§10.4 Q11**.
  - **C2b** — the destructive `Goodsreceiptposition` repointing. SBDEV-2796 AC: *"C2b is resolved or explicitly ruled out of scope by the chosen option"*; (c) does neither. Now the binding gate on Fix B (§5.2, §6).
  - **The capacity-check AC is VOIDED by its own answer** — *"if direct placement survives the decision, a capacity check exists before the transfer"* is unsatisfiable under (c), which declines the check by design. It should be struck from SBDEV-2796 rather than left failing.
- `wms2-mobile-ui` `storePallet.vue:14-23` — show the expected destination on the mobile putaway scan.
- General web-UI role gating (`layouts/default.vue:284-286`, `adminMenu`, `APP_ADMIN_GROUP`) — §3.12.
- A read UI for `putaway_config_audit`.
- `ItemDataController.java:81` — `@GetMapping` that mutates state; changing the verb is a breaking API change.
- Advice-create early validation (§0.1 rows 22–24), if not taken up in Phase 1.
- `AdviceService.acceptHubAndSpokeAdvice` placement review (§0.1 row 25).
- "Stock-move deadlock-retry hardening" (the deferred SBDEV-1762 follow-up) — **a prerequisite before any tenant points a merchant or warehouse default at a live pick location**. §7.6 row 8.
- `SystemPropertyController.updateValue`'s client-blind `findBySyskey(key).get(0)` (`:100-105`) — landmine A3's shape on a write path, affecting every other syskey. Out of scope here; this plan only closes the one key.

---

## 9. Alternatives Considered

**A1 — Merchant tier as a client-scoped `los_sysprop` row (`client_id = <merchant>`).**
Attractive because `SyspropService.getStringDefault` (`:164`) *already* implements a 4-tier cascade — tier 2 "client, ignore workstation" (`:193-205`) and tier 4 "system client, DEFAULT workstation" (`:223-232`) map exactly onto the ticket's merchant and warehouse tiers, needing **no new DDL at all**. There is even an abandoned breadcrumb: `ReceivingService.java:422` is a commented-out reference to that very method.
**Rejected on four independent landmines.** (i) `getStringDefault` **INSERTs** on a total miss (`:234`), so the resolver could write, and clearing the system row is self-undoing. (ii) `getSysvalue` — the accessor most callers reach for — is **client-blind** (`SyspropRepository.java:29-31`, `order by client_id LIMIT 1`, comment: *"legacy code incorrectly assumes one result"*), so any future caller collapses all merchants to the lowest `client_id`. (iii) the `sysprops` cache key **omits `clientId`** (`SyspropService.java:53, 95, 288, 303`), so caching a client-scoped key serves one merchant's value to every merchant. (iv) `setSysvalue` **cannot write a merchant row** at all (`:306` hard-codes the system client), so a writer would have to be built anyway. Add that the per-client tier has **never** been used in production (131/131 rows `client_id=0` on `wh01_hydra_v2t`) and it would be the first real use, on the receiving hot path. A typed nullable FK on `client` (§3.3) costs one additive column and gives referential integrity a `sysvalue text` cannot.

**A2 — Keep `NOT NULL` and use a value sentinel: "has an override" ⇔ `putawaylocationId != laneId`.**
Zero DDL, zero migration, no deploy-order coupling — genuinely the cheapest option, and it was the analysis lane's first reading.
**Rejected.** It makes an *explicit* SKU choice of `PutAwayLane` indistinguishable from "unset", so the ticket's "clear each override independently" AC is unachievable at tier 1. It re-entrenches the hard-coded `"PutAwayLane"` name (`WmsConstants.java:771`) as load-bearing *semantics* rather than a mere fallback, which is precisely what the ticket asks to remove. And it silently changes meaning if a tenant ever renames or duplicates the lane. NULL costs one forward-only `ALTER` that cannot fail on existing data.

**A3 — A third column `itemdata.putawaylocation_source` as an explicit discriminator.**
Most explicit of the three; no sentinel ambiguity and no `NOT NULL` change.
**Rejected** on write-path churn: every one of the four seeding sites plus both read sites plus the ≈10 fixtures would have to maintain *two* fields in agreement, and any path that updates one and not the other produces a state the resolver cannot interpret. NULL carries the same information in one field that already exists.

**A4 — Reuse `SyspropService.getStringDefault` for the warehouse tier only.**
Would give tier 3 for free and matches the abandoned breadcrumb at `ReceivingService.java:422`.
**Rejected** solely because of the `:234` auto-INSERT: the resolver would acquire a write path on the receiving hot path, could not be reasoned about as a read, and two replicas racing on a cold key would collide on `uk8tcoe23qui9q3ancbhx662iqb` (`V2.2.00...sql:3600-3603`). `SyspropRepository.findBySyskeyAndClientIdAndWorkstation` (`:35-36`) reads the same row with no write and no cache. **Do not substitute `findSysvalueByClientIdAndSyskey` (`:46-48`) — that is landmine A6** (no `workstation` predicate against a `(client_id, syskey, workstation)` unique constraint ⇒ arbitrary row). `ReceivingService.java:429-431` is a valid precedent for the *shape* of a direct repository read, but it reads `WAREHOUSE_NAME`, which is not UI-writable, so it is **not** a precedent for skipping the workstation predicate.

**A5 — Force the resolved destination on the carrier path (move the carrier, or split it).**
The most literal reading of SBDEV-2731's "honor".
**Rejected as physically incoherent.** A carrier pallet is one physical object; its cases may belong to several merchants with different resolved destinations, so "the" destination is undefined. Moving the whole carrier would relocate other merchants' stock; splitting it at receive time invents a workflow nobody asked for. §3.7.2 discharges "honor" as surface-plus-suggest on the carrier path, which is neither silent nor ignoring. Recorded in §10 Q1 for business confirmation.

**A6 — `exported = false` on the HAL write methods instead of a `RepositoryEventHandler`.**
Structurally airtight: no unvalidated write path can exist if the endpoint does not exist.
**Rejected for `Client` and `Sysprop` on evidence:** the web UI *depends* on those endpoints — `store/admin/shippers.js:47` uses `PATCH /client/{id}` and `store/admin/configuration.js:73-93` uses `PUT /sysprop/{id}`. Disabling them breaks shipped features. It would be viable for `Itemdata` alone (the SKU screen is read-only), but guarding one of three holes while validating the other two through a handler is worse than one uniform mechanism. Adopted D7's handler for all three, extended to `Sysprop` (§3.9). Note that `exported = false` would not have helped with §3.9.1's direct-save endpoints either — those are hand-written controllers, not SDR routes.

**A7 — Extend `receiving_dto_view` with the effective destination and source.**
D8's presumed mechanism; would let the open-receiving *list* show the destination with no extra calls.
**Rejected on evidence** (§3.8): the view already projects `defaultputawaylocationname`, so nothing is missing for tier 1; four-tier precedence plus P1 compatibility is not expressible in that SQL; and a projected view column couples view and entity into every future change (the mechanism is runtime read failure, not `ddl-auto=validate` — `ddl-auto` is `none`). A per-position endpoint keeps the precedence in the one shared service, which is the ticket's own AC.

---

## 10. Open Questions / Resolved Decisions

### 10.1 Recorded decisions (D1–D12 — decided, not re-opened)

| # | Decision | Where it lands |
|---|---|---|
| D1 | **2732 owns the shared resolver.** All four tiers, config storage, validation and admin UI live here; 2643 and 2731 become thin consumers. | §3.1, §8.1 |
| D2 | **Direct placement, bypass manual putaway.** No sysprop gate; back-compat rests on "no config ⇒ no behaviour change". | §3.7, §6. **Refined by evidence:** on the non-carrier path this is the *existing* mechanism, and v2 has no putaway-task entity to suppress (§2.1). |
| D3 | *(superseded by D6)* fall back down the chain and warn loudly | — |
| D4 | **Phase 1 API, Phase 2 web UI**; TDD gate on Phase 1, re-run at Phase 2 start. | §5.2 |
| D5 | **DROP NOT NULL + stop seeding** at the 4 sites; NULL = inherit. | §3.2. **Backfill resolved** in §5.1. |
| D6 | **Validate at config-write time (primary) + hard-fail at receive time (backstop).** Never silently reroute. The empty-constraint-list fail-open branch is mandatory. The raw-ID message at `:191` is replaced. | §3.4b, §3.4c, §3.6 |
| D7 | **One `@RepositoryEventHandler`** routing HAL writes through the same validator + audit writer. | §3.9. **Extended to `Sysprop`** — see 10.3 A1. |
| D8 | **One plan; 2732 owns the receiving-display contract; 2731 closes as a subset.** | §8.1. **Mechanism reduced:** no `receiving_dto_view` change is needed (§3.8) — see 10.3 A2. |
| D9 | **SUPERSEDED 2026-08-04 — two merges, one migration.** Originally four phases (1a-API / 1a-UI / 1b-API / 1b-UI) split on tier reachability, with the migration split in two and only the second carrying the operator gate. §5.2 collapsed the API phases into **Phase 1-API**, and D16 collapsed the migration into a single **`V2.2.11`** — which adds a mapped column, so **the one migration carries the gate**. Current shape: **Phase 1-API → Phase 2-UI**. Residual `1a`/`1b` labels in §0 and §4 are stale. | §5.2, §8.1, D16 |
| D10 | **A carrier receipt is never aborted by a putaway-config error.** The resolver runs on both branches, but `requireCompatible` is called only when `carrier == null`; on the carrier path an incompatibility is a WARN plus a `compatible="false"` metric tag, because the resolved destination is never applied there. | §3.7.1, §3.7.2 |
| D11 | **Count-and-confirm at merchant and warehouse scope, not an absolute reject.** Above zero incompatible SKUs the write returns 409 with the count; the caller re-issues with `confirmIncompatibleSkus=<n>`, which the writer **recomputes** and compares. 100 % incompatible, locked, fix-assigned and lane destinations are unconditional 422s. SKU scope stays an absolute reject. | §3.4c, §3.5a |
| D12 | **`DELETE` of the `DEFAULT_PUTAWAY_LOCATION` sysprop is accepted, not refused** — an absent row and a blank row are the same state to the resolver, so the delete can only move tier 3 in the safe direction. It is **audited** (`@HandleBeforeDelete` reads the previous value, `@HandleAfterDelete` records the clear), and §3.11.2 renders the control unconditionally so a delete cannot lock the tier out of the UI. | §3.9.1, §3.11.2 |

### 10.2 Adopted assumptions (routine calls, no genuine fork)

| Assumption | Adopted because |
|---|---|
| Merchant tier = `client.defaultputawaylocation_id bigint NULL REFERENCES location(id)` | one facility == one tenant DB, so "one value per merchant per warehouse" is satisfied structurally; typed FK > `sysvalue text`; avoids landmines A1/A3/A4/A5. §9 A1. |
| Warehouse tier = system-client sysprop `DEFAULT_PUTAWAY_LOCATION`, groupname `Operation Options`, seeded `''` | the Admin screen already renders that group generically via `GET /sysprop/search/findByGroupname` ⇒ the ticket's requested Admin path with zero new UI plumbing. Precedent `ReceivingService.java:428-431`. |
| Audit = a new narrow table, no Envers | Envers absent; Spring Data auditing captures timestamps only; the sole precedent is `CustomerorderCancellationLog` + `CancellationLogService`. §2.6. |
| Facility scoping needs no new dimension | no `warehouse`/`facility` table, no discriminator column on `location`; one DB per facility. §2.4. |
| Warehouse-tier value format = numeric `location.id` | agrees with tier 2's FK; survives renames; picker writes the id. Legibility restored via the sysprop `description` + the Phase-2 picker. |
| `WmsConstants.STORAGE_LOCATION_PUTAWAY_LANE` stays | it becomes the **tier-4 fallback constant** only; it stops being written as a seeded tier-1 value. |
| The resolver is wired at the receiving call-sites, never inside `transferUnitLoadToLocation` | that method has **24 call sites** across picking, palletizing, truck loading, transfers, on-hold and nirvana. §2.8. |

### 10.3 Deviations from the brief, with rationale (raise at review)

| # | Deviation | Rationale |
|---|---|---|
| A1 | **D7 extended to `Sysprop`**, not just `Itemdata` + `Client`. | The warehouse tier has the largest blast radius (§8.2) and `PUT /sysprop/{id}` is exactly what the existing generic admin dialog calls (`store/admin/configuration.js:73-93`). Guarding two of three holes leaves the worst one open. D7's own rationale already names `PATCH /v3/sysprop/{id}`. |
| A2 | **No `receiving_dto_view` / `ReceivingDtoView` change**, contrary to D8's presumed mechanism. | The view already projects `defaultputawaylocationname` (`V2.2.00...sql:4663, 4676` → `ReceivingDtoView.java:47, 173`). Precedence + compatibility are not expressible in that SQL, and a projected view column would couple the two forever (runtime read failure, not `ddl-auto=validate` — `ddl-auto` is `none`). D8's *substance* (2732 owns the display contract; 2731 not worked independently) is fully honored. §3.8, §9 A7. |
| A3 | **Receive-time validation is P1 only**, not the full suitability predicate. | Applying P2 at receive time would be *stricter* than `transferUnitLoadToLocation` and would reject receipts that work today — `PutAwayLane` itself sits in an area with `useforstorage = false`. §3.1.2. |
| A4 | **New `LocationConstraintService` method uses the existing list query**, not a new `existsBy...`. | Reproducing `UnitloadBusinessService.java:180-193` byte-for-byte is the point; an `exists` formulation needs two round-trips to express the same fail-open rule and invites drift. §3.4b. Excludes analysis-bundle site 29. |
| A5 | **Carrier path surfaces rather than forces** the resolved destination. | §9 A5. Flagged for business confirmation in Q1. |

### 10.4 Open questions

| # | Question | Blocking? | Recommendation |
|---|---|---|---|
| Q1 | On a **carrier** receipt with a non-tier-4 destination configured, should WMS surface-and-warn (this plan, D10) or hard-block the carrier receipt? | **No** — surface-and-warn is strictly less disruptive and can be tightened later. | Confirm with David Oppenheim during Phase 1 review. A hard block is a one-line change in §3.7.1 (drop the `carrier == null` guard around `requireCompatible`) if the business wants it. |
| Q2 | Location count per facility — does a preloaded, client-side-filtered picker scale, or is a server-search endpoint needed? | **No** — Phase 2-UI only. | `SELECT count(*) FROM location` per tenant before Step 26. If any tenant exceeds ~2,000, add a search parameter to `/location/detailView`. |
| Q3 | SBDEV-2643 scope: `skuData.vue:107-131` has its create/edit block **commented out**, so 2643 needs a SKU edit form built from scratch, not "add a field". | **No** — different ticket. | Re-estimate 2643 after Phase 1 lands; its backend is already done and now validated. |
| Q4 | Does `AdviceService.acceptHubAndSpokeAdvice` (`:145`) need the resolver? It materialises `Unitload` + `CustomerorderBatch` + `Customerorder` **without** going through `receiveGoods`. | **No** — excluded in §0.1 row 25. | Review after Phase 1 with a real hub-and-spoke advice on DEV. |
| Q5 | `ItemDataController.java:81` is a `@GetMapping` that mutates state. | **No** | Left as-is — the web UI calls it and changing the verb is a breaking API change. §8.4. |
| ~~Q7~~ | ~~**SBDEV-2731 is `in development` with no plan doc on disk.**~~ **CLOSED 2026-08-02 by D12/D14.** The 2731 plan exists and was inspected; ownership of `ReceivingService` destination resolution is now formally this plan's, and 2731 closes on its PR1 (display + neutral message). | **No longer blocking.** | See §10.2 D12/D14 and `SBDEV-2731-…md` §6. Superseded — do not re-investigate. |
| **Q10** | **Pick-face capacity (F3 / SBDEV-2731 Q5).** Should receiving deposit a full receipt into a pick face whose `upperbound` is 84? Nothing checks `FixLocationAssignment` bounds before `transferStockToUnitLoad`. D13 exempts tier 1, which is exactly the reported ICE PACK case (1,000 units). | **ANSWERED 2026-08-04 — no longer blocking, and the path it gated is DEFERRED (D15).** | **[SBDEV-2796](https://app.clickup.com/t/868kk4rmv): the B/A chose (c) — "valid, and bounds are advisory for receiving."** Not the recommendation (d). No capacity gate is built; the over-bound bin is an accepted, documented state; the tier-1 direct-placement block is lifted. **But (c) did not close two of that ticket's own ACs:** replenishment behaviour against a permanently over-bound bin is still undefined and awaiting a B/A answer (**new Q11**, owned by [SBDEV-2821](https://app.clickup.com/t/868km8j9z)), and **C2b** is neither resolved nor ruled out — it is now the binding gate on the surviving Fix B work (§5.2, §6). See the revision banner at the top and the §3.4c D13 note. |
| **Q12** | **May a tier-2/3 default target a *club* assembly lane?** D13 rule (a) permits `staginglane` wholesale and the ticket names "Club assembly lane" as a tier-2 scenario — but `getAvailableStagingLanes` (`LocationRepository:37-47`) allocates lanes to club batches **with no stock predicate**, so a receipt sitting on that lane can be shipped or cleared with the next batch (§6 **N-23**, verified 2026-08-04). Separately, lane stock is unconditionally invisible to replenishment sourcing (`StockunitRepository:198/:216`). | **YES — blocks the P2.7(a) wording and the Phase 2 location picker.** Does not block the resolver, tiers 1/4, or a cross-dock-only reading of rule (a). | **OPEN — needs the B/A, and RE-FRAMED 2026-08-06 by measurement: this question was asked about the wrong predicate.** Q12 assumes club lanes are reached through rule (a) (`staginglane` permitted wholesale). **On the real data they are not.** Verified SELECT-only on `wsl-wineco-uat`: `Club01`–`Club08` (ids 225748+) have **`staginglane = FALSE`** and every other lane flag FALSE; they sit in area 51553 *Storage and Picking* with **`useforpicking = TRUE`**, and `Club01` holds **114 unit loads / 27 distinct SKUs / 973 bottles**. They are **live multi-SKU pick faces**, not staging lanes. **Consequence: the ticket's named tier-2 use case — "Club assembly lane", "sending fast-turn club inventory directly to a designated club lane" — is, on this data, a request to point a merchant default at a PICK FACE. That is exactly what P2.7(c) forbids at all three scopes, and exactly what D15 defers to SBDEV-2821 for tier 1.** So the previously-proposed "safe answer" (narrow rule (a) to `crossdockinglane` + non-club staging) does not address wineco's clubs at all — they never passed through rule (a) — and with P2.7(c) now implementable they are blocked by rule (c) instead. **The real question is therefore: does this plan ship the club use case at all?** Three coherent answers: **(i)** no — P2.7(c) stands, the ticket's club scenario is out of scope for tiers 2/3 and belongs with SBDEV-2821's pick-face work; **(ii)** yes for clubs specifically — which needs the same resident-UL/Fix B machinery D15 deferred, i.e. it pulls SBDEV-2821 back into this plan; **(iii)** yes, but only onto *empty* club lanes (`Club08` is empty today), which needs a stock predicate that `getAvailableStagingLanes` does not have. **✅ ANSWERED 2026-08-08 — option (iv-b), split.** A fourth option emerged from SBDEV-2821's decision. **Configuration is widened at every tier — a pick face, club lane included, is a legal destination. Placement is split:** a **pick-face** destination is *not* placed at receipt (the receipt goes to the standard lane and putaway routes it, where `MobilePutAwayService.storeBoxOnLocation:471-489` already handles pick faces correctly); **every other** destination — staging, goods-in, cross-dock — is still placed directly at receipt, preserving the ticket's fast-turn intent that uniform (iv-a) would have dropped. **The club use case ships, no stock lands on a live pick face at receipt, and C2b stays unreachable.** Consequences: §5.2 **step 15 gains the `useforpicking` gate**; **step 17 survives, restricted to non-pick-face destinations**; P2.5 / P2.7(c) relaxed at all scopes; D13 re-framed from a configuration rule to a placement rule. §7.1's two conflicting tests resolve as: `merchantWritePermitsStagingLane` **passes**, `skuWriteRejectsPickFaceDestination` is **replaced** by `pickFaceDestinationIsNotPlacedAtReceipt` — the config is legal, the *placement* is what is refused. *Provenance: chosen by the ticket owner; put to the B/A on the ticket 2026-08-08, no reply recorded yet. If either objects, Q12 reopens — (i)–(iii) and (iv-a) remain on the table.* |
| **Q11** | **Replenishment against a permanently over-bound bin.** SBDEV-2796's answer (c) makes bounds advisory *for receiving* and makes over-bound bins reachable **and permanent** — but replenishment keys off those same bounds (`recalculateForItem` maintains orders from them). What should replenishment do when on-hand is ~12× `upperbound`? | **NO for this plan — DEFERRED with the tier-1 path (D15).** It is SBDEV-2796 AC *"Replenishment behaviour against an over-bound bin is defined, or over-bound bins are made unreachable"*, and (c) removed the second branch. **Why it cannot arise here — and note the reason is P2.5/P2.7(c), NOT the absence of placement code:** `ReceivingService.java:454-457 → :491` already places tier-1 destinations unconditionally, so nothing at receive time would stop an over-bound bin. What stops it is that **the configuration cannot be written** — P2.5 and P2.7(c) reject a pick-face or fix-assigned tier-1 destination at write time. If either predicate is ever relaxed without also answering this question, over-bound bins become reachable immediately. **⚠ BOTH PREDICATES WERE RELAXED 2026-08-08 (Q12 → iv-b) — the precondition held: the question was answered first, on 2026-08-06 ("advisory for replenishment"), so relaxing them is safe in the order it actually happened. Note also that under (iv-b) receiving no longer places onto a pick face at any tier, so the over-bound bin can now only be created by putaway, where `storeBoxOnLocation:471-489` merges into the resident UL — which is exactly what the "Caveat that travels to SBDEV-2821" requires.** ~~Blocks the tier-1 follow-up, not this plan.~~ | **ANSWERED 2026-08-06: "advisory for replenishment" too. Owned by [SBDEV-2821](https://app.clickup.com/t/868km8j9z).** Verified against the code, this costs **nothing to implement** — the bounds are never asserted as invariants, only used as comparison predicates: `FixLocationAssignmentRepository.getRefillFixedLocations:45` / `getRefillFixedLocationIds:72` gate on `stockunit.amount < fla.lowerbound`, so at 1,000 vs 36 **no replenishment order is ever created**; `ReplenishorderRepository.getIdsToCancelReplenishOrders:149` / `...Page:156-162` select `stockUnit.amount >= fixAssignment.upperbound`, so any open order is **cancelled** on the next sweep; `recalculateForItem` (`ReplenishmentOrderMaintenanceService.java:112`) iterates only `PROCESSABLE` orders and is a no-op for the SKU. **Caveat that travels to SBDEV-2821:** both cancel queries join `fixAssignment.assignedunitload_id = stockUnit.unitload_id` and so read the **resident** unit load only — if direct placement creates a *second* UL on the location, refill keeps firing and cancel never does, and the system replenishes a bin already holding 1,000 units. "Advisory" is correct **only if Fix B's resident-UL resolution is correct**. |
| Q8 | Has the history-less Hydra DEV copy been repaired, and `V2.2.11` applied to **every** DEV tenant, before the Phase 1-API merge? | **YES — blocks the Phase 1-API merge**, not the work, and not the Phase 2-UI merge. | §5.1 row 1, §8.1. DEV auto-deploys on push; the runtime migrator self-heals tenants that have Flyway history but **skips** those that do not, and `ddl-auto=none` means the failure is a per-request `42703`, not a failed boot. Pre-mortem P1. |
| Q9 | Should P2.4 admit a **pick-only** area (`useforpicking` with neither `useforgoodsin` nor `useforstorage`)? As written it does not, so a pick location can never be configured as a putaway destination and the picker does not offer one. | **No** — the narrow reading ships safely and can be widened later. | Keep P2.4 as written for Phase 1. Confirm with David Oppenheim whether receiving-direct-to-pick is a wanted workflow; if it is, widening P2.4 is a one-clause change **but §7.6 row 8's deadlock-retry prerequisite becomes hard**, because picking locks the same rows in the opposite order far more often than replenishment does. |

### 10.5 Closed questions (answered by the analysis lanes — do not re-investigate)

| Question | Answer |
|---|---|
| Is there v1 prior art to port from SBDEV-2642? | **No.** Zero commits in all five repos, no assignees, no attachments, closed 2026-07-25 ≈21 min *before* 2732 was created ⇒ superseded, not delivered. v1 `ReceivingService.java:521-523` is the same single-tier lookup and strictly worse. Jakarta-vs-javax is moot. |
| Unique index on `los_sysprop(client_id, syskey, workstation)`? | **Yes** — `uk8tcoe23qui9q3ancbhx662iqb`, `V2.2.00...sql:3600-3603`. |
| Can a sysprop row carry facility scope? | It does not need to — one DB per facility. §2.4. |
| Does the receiving screen's "source of setting" need a new API field? | **Yes**, derived server-side. The sentinel/precedence logic is far too subtle to re-implement in Vue. §3.8. |
| What constitutes a "putaway task" in v2, and what gets suppressed? | **Nothing.** There is no task entity; `MobilePutAwayService.calculatePutAwayList` (`:212-283`) derives suggestions on the fly from unit loads on the lane, so a directly-placed unit load simply never appears. §2.1. |
| Where does the invalid Ice Pack config come from? | `ItemDataController.java:88-90` raw `save()` with zero validation, and/or `PATCH /v3/itemdata/{id}`. `ItemdataService.setPutAwayLocation` has zero production callers and would not have validated anyway. §1. |
| (Q6) Does the `@HandleBeforeSave` previous-value read need `FlushModeType.COMMIT`? | **No.** With OSIV off the merged entity is **detached**, so there is no persistence context to auto-flush and the flush mode changes nothing. The plain native query returns the committed value. Do not set a flush mode and do not document one. §3.9.5. |

### 10.6 Pre-mortem — three ways this ships and still fails

**P1 — It ships and the application will not start (or SKU creation 23502s).**
`V2.2.11` is merged but not applied on some tenant. Because `ddl-auto` is **`none`**, the context starts normally — then every Hibernate read of `client` fails **`42703 column ... does not exist`**, per request, while liveness and readiness stay green. Or the stop-seeding code reaches a tenant where `V2.2.11` has not run and a new SKU insert hits `NOT NULL` on `putawaylocation_id`. **DEV auto-deploys on push, and although the app now runs Flyway at boot (SBDEV-2801) it SKIPS any tenant DB without `flyway_schema_history` — the Hydra DEV copy is exactly that** — so the ordinary merge workflow *is* still the failure path. **The original detector in this plan ("the app will not start") never fires; it was written against `ddl-auto=validate`, which this codebase does not use.** Detect instead with a per-tenant `information_schema.columns` check (§8.1) plus an alert on `42703` in the logs.
*Leading indicator:* startup `SchemaManagementException` naming `client.defaultputawaylocation_id`, or `POST /rest/sku` / CSV import returning `null value in column "putawaylocation_id" violates not-null constraint`.
*Mitigation:* §5.1 row 1 is a **hard blocker on merge 1, not on the work** — apply `V2.2.11` to every DEV tenant first, verified by reading `flyway_schema_history` (note: the Hydra dev copy has **no** `flyway_schema_history`; verify there by querying `los_sysprop` for the new key and `information_schema.columns` for the new column). §8.1 orders it explicitly. For the `23502` half, O3 keeps stop-seeding and `V2.2.11` in one commit and §8.1 merge 1 requires the operator to apply `V2.2.11` promptly after that merge. M1 + M2 are the first post-deploy checks.

**P2 — It ships completely and does nothing.**
Every tier-1 value still points at `PutAwayLane` (backfill skipped, or run blanket-and-reverted), or Phase 2 never lands so no operator can set a tier-2/3 value, or the sysprop stays `''` forever. Receiving behaves exactly as before, the code is all present, every test is green, and the two urgent siblings get closed against a feature nobody is using. **This is the most likely failure**, because every automated signal is green in this state.
*Leading indicator:* `wms2.putaway.resolution{source="STANDARD_PUTAWAY_LANE"}` ≈ 100 % of receipts two weeks after Phase 2, with `MERCHANT_OVERRIDE` + `WAREHOUSE_DEFAULT` still at **zero**. Corroborate in SQL: `SELECT count(*) FROM itemdata WHERE putawaylocation_id IS NULL` == 0, `SELECT count(*) FROM client WHERE defaultputawaylocation_id IS NOT NULL` == 0, `SELECT sysvalue FROM los_sysprop WHERE syskey='DEFAULT_PUTAWAY_LOCATION'` == `''`.
*Mitigation:* the scoped backfill ships **inside** `V2.2.11`, in Phase 1, so it cannot be forgotten separately and tiers 1/3/4 are genuinely live at the first merge; §3.13's `source` tag exists specifically to make inertness visible (there is no other way to see it); §8.1's third post-merge gate makes non-zero tier-2/3 usage a **condition for closing 2731 and 2643**, so the tickets cannot be closed against an inert feature.

**P3 — A single warehouse-tier write halts receiving for every merchant.**
An operator sets `DEFAULT_PUTAWAY_LOCATION` to a location incompatible with a common unit-load type, and write validation does not stop it — because the `@RepositoryEventHandler` was never actually registered (a `@Component` + `@RepositoryEventHandler` that Spring Data REST fails to pick up is **silent**; nothing logs, nothing throws), or because the write arrived on a path the handler cannot see: `POST /v3/systemProperty/create`, `POST /v3/systemProperty/updateValue`, or a `DELETE` (§3.9.1). Then §3.1.3's hard-fail backstop fires on **every** receipt for **every** merchant, and D6's "never silently reroute" turns a config typo into a warehouse-wide stoppage.
*Leading indicator:* `wms2.putaway.resolution.rejected{scope="WAREHOUSE"}` spikes from zero; simultaneously `/receiving/receive` starts returning 200-with-`errors` at a high rate (it never returns a 5xx, so an HTTP-status alert would miss it entirely).
*Mitigation, five layers:* (1) seeded `''`, so no tenant is exposed until someone writes; (2) **`PUT /putawayConfig/warehouse` is the only write path** — the two `SystemPropertyController` direct-save endpoints reject this syskey (§3.9.1), which closes the bypasses the handler structurally cannot see, and `DELETE` can only move the tier to "not configured" (D12); (3) the handler covers `PATCH /v3/sysprop/{id}` (deviation A1) and is proven wired by manual test **M9** — a 2xx there is a documented hard stop, and a **500** means the handler threw a checked exception (§3.9.7), because no code-shape grep can prove event-handler registration; (4) write-time P2.6 counts the tenant's incompatible SKUs and demands an explicit `confirmIncompatibleSkus` above zero, refuses outright at 100 %, and refuses a locked, fix-assigned or lane destination unconditionally (D11) — so a warehouse default that breaks *any* SKU cannot land silently; (5) `@PreAuthorize(Authority.IS_SB_ADMIN)` on `PutawayConfigService` narrows who can do it at all (§3.12), with **M16a** proving the HAL channel is gated too.
*Kill path:* a **one-statement UPDATE to `''`**, which restores tier-4 behaviour for every merchant immediately. Blanking is stable because tier 3 reads through `SyspropRepository.findBySyskeyAndClientIdAndWorkstation` and never through `getStringDefault`, so nothing auto-recreates the value (landmine A1). Prefer the UPDATE over a DELETE: both stop the bleeding, but the UPDATE keeps the row — and therefore the audit subject and the admin-dialog entry — in place.

---

## 11. Acceptance & Implementation

### 11.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2732-configurable-default-putaway-location-hierarchy.sh`

```bash
PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api \
  bash sbdocs/9-System/scripts/verify-SBDEV-2732-configurable-default-putaway-location-hierarchy.sh
```

Checks are grouped by phase so the output reads in rollout order. One POSITIVE check per §3 sub-section; a NEGATIVE check wherever new code replaces old — including all four seeding sites and the raw-concat throw at `UnitloadBusinessService.java:191`. `mvn_test_passes` rows cover the touched test classes (whole classes, never `Outer#method` — that silently no-ops on `@Nested`).

**Two template defects are fixed in this script, and both matter here:**

1. `PROJECT_ROOT` defaults to `/home/nampark/dev/wms-claude/v2/wms2-api` (the template ships a stale macOS path).
2. **`file_not_contains` FAILS OPEN on a missing file** — `grep` exits 2, and the leading `!` flips that to PASS. Every helper that can be handed a path gets `[ -f "$2" ] || return 1`, including the `perl -0777 -ne` multi-line helper: `perl` **exits 0 when it cannot open the file**, so every multi-line assertion about a not-yet-created file would false-green. Nine of this plan's new files are asserted with multi-line patterns, so without this fix roughly a third of the script would pass on an empty tree.

**A "N pass, 0 fail" result is meaningless until it has been replayed against the pre-change tree and observed to FAIL there.** SBDEV-2736 scored 57 pass / 0 fail on the very build that contained the defect the ticket was written to catch. Before accepting any implementation report:

```bash
git stash && bash sbdocs/9-System/scripts/verify-SBDEV-2732-....sh ; git stash pop
```

The negative-control run **must** show a large number of FAIL lines. If it shows 0 fail, the script is broken, not the implementation.

**Negative control, current baseline against the unmodified tree — now recorded PER PHASE (O4).** The
script takes `PHASE=1|2` (**not** `1a|1b` — those were never valid, and an unknown value now exits 2
rather than filtering every check and reporting a silent all-green); a whole-plan run can never reach
0 fail while later phases are unbuilt, so **each phase gates on its own subset**:

**Baseline re-measured 2026-08-07, POST-2731-MERGE** — api `6bc709a`, ui `4ce39a1`. This supersedes the
pre-merge record; it expires again when this plan's own Phase 1-API work starts landing.

| Run | Result | Evaluated / filtered |
|---|---|---|
| `PHASE=all` (default) | `15 pass, 168 fail, 1 skip` | 184 / 0 |
| `PHASE=1` | `12 pass, 162 fail, 1 skip` | 175 / 9 |
| `PHASE=2` | `10 pass, 7 fail, 1 skip` | 18 / 166 |

**Re-recorded again 2026-08-08 after the Q12 → (iv-b) script fixes.** Four checks were **removed** and eight
**added** (net +4 fail). The removed four asserted the *superseded* design and would have failed a correct
implementation: `V-fixloc` / `V-fixabs` demanded P2.5's absolute reject exist, and `T-skufix` / `T-merchfix`
demanded SKU- and merchant-scope writes *reject* a fix-assigned location. **Under (iv-b) all four assert the
opposite of the intent.** A gate encoding the old design is worse than no gate — it blocks the change it is
meant to guard. The pass count is unchanged at **15**, which is the signal that nothing went vacuous.

**Arithmetic self-check:** 175 + 18 = 193 = 184 + 9. **The overlap constant is now 9, not 11** — the 8
`phase all` preservation checks plus the **1** remaining SKIP. It was 11 when three checks were skipped;
`U-neg1` and `U-bind` were un-skipped on the merge (SBDEV-2731 owned them and now ships them), leaving
only the pre-existing `mvn` skip.

**What the merge flipped, and why each is right:**

| Check | Before | After | Why |
|---|---|---|---|
| `UBS-key`, `UBS-neg1`, `UBS-neg2`, `T-msg2` | FAIL | **PASS** | 2731 shipped the neutral key and removed the raw concatenations |
| `T-msg1` | FAIL | **PASS** | needed a second fix — see below |
| `U-neg1`, `U-bind` | SKIP | **PASS** | un-skipped; 2731 owned them and has now merged |
| `U-tristate` | FAIL | **PASS** | 2731's tri-state is present and this plan has not yet touched that block |
| `UBS-neg4`, `W-neg4` | FAIL | **FAIL** | correct — conjoined, and the resolver does not exist yet |

**`T-msg1` needed fixing twice, and the second reason is worth recording.** Scoping it to assertion
syntax (`hasMessageContaining(`) was not enough: 2731's merged test explains the removal in a comment
that **quotes the assertion verbatim** at `UnitloadBusinessServiceUnitTest.java:207` —
`// which pinned \`.hasMessageContaining("not allowed on location")\` — the raw,`. The check now strips
comment lines before matching. **A negative check must exclude the prose that describes what it forbids**,
or documentation of a fix reads as the defect. **The overlap constant is 9** — the 8
`phase all` preservation checks *plus the single remaining SKIP*, because `skip()` never calls `phase_selected()` and
so is never filtered. The previous derivation attributed the whole overlap to preservation checks and
silently dropped the skips. There are **3** SKIPs, and only **2** belong to SBDEV-2731 PR1 (`U-neg1`,
`U-bind`) — `U-source` was converted from skip to run on 2026-08-02 — plus the pre-existing `mvn` skip.

**Why 7 and not the previously recorded 8.** Three separate corrections landed on 2026-08-06 and they
move in opposite directions, so the net is not obvious:
- `UBS-neg4` and `W-neg4` were **vacuous** (bare `file_not_contains` for symbols that exist in zero
  files) and are now **conjoined**, so both correctly FAIL pre-implementation: **−2** from the old count
  of 9. §11.1 had already prescribed the conjoined form for `UBS-neg4`; the script shipped only half of it.
- The count had drifted 8 → 9 → (projected) 13 as prerequisites moved. After the conjoin it is the count
  of **real preservation checks** and stops drifting with every prerequisite merge. That stability is the
  point of the fix, not the number itself.
- All three phases now read the same 7, which is the strongest form of the invariant.
- **`U-tristate` (added 2026-08-06) fails today and should.** It asserts SBDEV-2731's tri-state comparison
  survives this plan's edits to the same template block, and the symbol does not exist on `develop` until
  #39 merges. It is a *post-prerequisite* preservation check: expect it to flip to PASS on the merge, and
  to stay PASS through Phase 2. If it is red *after* #39 lands, Phase 2 broke it.
pinned to every phase** (counted 3× instead of 1× ⇒ +16). That is why the preservation checks stay green in every phase
(the per-phase pass counts differ — 15 / 12 / 10 — because non-preservation checks bucket differently) — those checks must stay green *throughout* implementation, not merely at the end. If this
arithmetic stops holding, a phase marker was lost or a check crossed a section boundary.
**The ralph exit condition is `PHASE=<phase>` 0-fail, never whole-plan 0-fail.**

**Buckets are not purely sectional.** Section granularity alone is wrong in *both* directions, and **23**
checks carry a per-check phase override. Two shapes of error to watch for when assigning a new check:
- **under-covering** — e.g. `E-const`, the `WmsConstants` key **Phase 1 Step 4 ships**, belongs to the 1a
  bucket even though the constant is described in a §3.4a subsection a section-based split reads as 1b;
- **over-demanding** — `C-writers` (asserts *three* writers; 1a ships two), `C-evictcl` (the merchant
  cache) and `C-audit` (audit *rows*, deferred to 1b by O1) must **not** sit in the 1a bucket, or
  `PHASE=1` 0-fail becomes **unreachable** — precisely the failure O4 exists to prevent.

The sectional assignments are a first cut. Walk §5.2's step tables before treating any `PHASE=<phase>`
0-fail as a merge gate.

**The 7 pre-implementation passes are all deliberate preservation checks** and must stay green
*throughout* implementation, not merely at the end: `E-col` (the `@Column` survives the `@NotNull`
removal), `E-lane` (the tier-4 constant survives), `UBS-lock` (the SBDEV-2232 caller-holds-locks contract
comment survives), `S3-pos1`/`S3-pos2` (the SBDEV-2037 lane-presence guard survives), `W-onetx`
(`receiveGoods` stays one tenant transaction), `W-2102` (the SBDEV-2102 fix survives).

`W-neg4` is **no longer among them** — it asserted that the resolver is never wired into the
24-call-site `transferUnitLoadToLocation`, but as a bare negative against a symbol that exists nowhere
it was vacuous. Conjoined 2026-08-06, it now fails pre-implementation and passes only once
`putawayDestinationResolver.resolve(` is present in `ReceivingService` **and** absent from
`UnitloadBusinessService` — which is the property actually worth asserting.

**The pass-count tripwire.** Every check about code that does not exist yet must **fail closed** on the
unmodified tree, so the pre-implementation pass count must stay at exactly **15** (post-2731-merge; it was 7
before that merge). **If a pre-implementation run reports materially more than 15 passes, a check has gone
vacuous — find it before trusting the script.** Re-derive this from a measured run after every prerequisite
merge rather than trusting this paragraph; it has moved four times (8 → 9 → 7 → 15) and every move was real.
This number has moved three times (8 → 9 → 7) and each move was a real defect, not drift: re-derive it
from a measured run after every prerequisite merge rather than trusting this paragraph.
Three vacuity traps are already known and fixed; a new check must be checked against all three:

| Check | Why it was vacuous | Fix |
|---|---|---|
| `E-clientnull` | asserted the merchant field is not `@NotNull`, but the field does not exist in today's `Client.java`, so the pattern trivially failed to match | require the field to **exist** first |
| `U-bind` | asserted `putawayStaging` appears in the receiving form, but a dead `putawayStaging: null` property **already exists** at `receivingForm.vue:206` | require ≥ 2 occurrences |
| `W-nocgrd` | asserted the resolver call is *not* wrapped in `if (carrier == null)` — SBDEV-2731's literal root cause and the single most important behavioural guarantee here — but `putawayDestinationResolver.resolve(` does not exist yet, so "not guarded" was trivially true | **conjoin**: the symbol must be *present* before the negative is evaluated |

`W-nocgrd` surfaced only because the pass count moved from 8 to 9 — **the tripwire caught it, not review.**
`W-neg4` remains inherently vacuous pre-implementation (it asserts a not-yet-existing symbol is absent);
that is unavoidable for a "never wire X into Y" check and is why it is counted among the 8.

**Checks this revision adds that the script does not yet carry** — `check_N1_syspropctl_create_guard`,
`check_N1_syspropctl_updatevalue_guard`, `check_N1_sysprop_delete_handler`, an assertion that
`@PreAuthorize` appears in `PutawayConfigService.java` and **not** in
`PutawayConfigRepositoryEventHandler.java`, and an assertion that `putawayDestinationNotPermitted` appears
in `PutawayDestinationResolver.java` and **not** in `UnitloadBusinessService.java`.
**STATUS 2026-08-06: all of these are now IN the script**, and the last one is the conjoined `UBS-neg4`
(the script had previously shipped only its "not in UBS" half, which is what made the check vacuous).
The baseline table above has been re-recorded from measured runs; the pre-implementation pass count is
**7**, not 8. Re-run the negative control and re-record again after SBDEV-2731 PR1 merges.

### 11.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | **Large** | ~14 new files, ~18 modified, two Flyway migrations one of which carries a data backfill, two repos, cross-subsystem (receiving + SKU master data + admin config + Spring Data REST), and a hard deploy-order coupling on merge 1 |
| **Pre-draft step** | done — `analyst` + 3 analysis lanes + `planner` (ralplan, deliberate mode) | this document |
| **Plan-review step** | done — `architect` + `critic` | see §12 |
| **Implementation shape** | **`ralph`**, exit condition = `PHASE=<phase>` 0 fail from the verify script, **never whole-plan 0 fail** (O4) | 29 steps across four phases with ordering constraints (O1–O5) that a single `executor` pass will not respect |
| **Verification step** | verify script **+ `verifier`** (mandatory) | plus the §11.1 negative control, per phase |
| **Code-review step** | **`code-reviewer`**, fix every High/Medium | seven new beans, one Spring Data REST event handler, one new exception mapping |
| **Commit step** | **`git-master`** | Phase 1 is at least five logical commits, and the **first one is atomic by requirement**: `V2.2.11` + stop-seeding + fixtures together (O3). Then resolver + predicate + message keys, config service + controller + direct-save guards, event handler, receiving wiring + display endpoint |

---

## 12. Design Changelog

Substantive design changes since the initial draft, in the order they were settled. Everything above this
section states the **current** design directly; this is the only place the superseded alternatives are
recorded.

- **2026-08-08 (later) — Q15 answered (A); THE SHIP ORDER REVERSED; the (iv-b) residue swept.** Q12 → (iv-b)
  landed earlier the same day but left five passages asserting the design it replaced. All corrected:
  - **Order is now `2731 PR1 → SBDEV-2821 → this plan`,** not the reverse. (iv-b)'s step-15 gate diverts
    pick-face destinations to the putaway lane, and only SBDEV-2821 makes them offerable there —
    `getStorageLocationsForPutAwayItemData` (`LocationRepository:104-111`) returns only locations where the
    SKU already has stock. `depends_on` gains SBDEV-2821; **§5.2 gains step 17a** (extend that surfacing from
    tier 1 to the full four-tier `Resolution`). Violating the order is degraded-not-broken — the operator can
    still scan the destination manually. §8.4.
  - **P2.5 and P2.7(c) lead-ins** still read *"Absolute reject at all three scopes"* above their own
    supersession notes. Marked DROPPED at the top of each cell, where an implementer reads first.
  - **§3.7's D15 scope note** still said the two predicates *"must stay absolute until SBDEV-2821 ships"* and
    that a receive-time gate would duplicate P2.6. Replaced: the gate tests what write-time validation
    deliberately no longer tests, so P2.6 does not apply to it.
  - **§3.5a's contract table** still returned 422 for a fix-assigned destination. Split: locked still 422;
    fix-assigned and pick-face are accepted.
  - **§7.1 and §5.2 step 7** still mandated `skuWriteRejectsFixAssignedLocation`,
    `skuWriteRejectsPickFaceDestination` and `merchantWriteRejectsFixAssignedLocation` — **tests that would
    fail a correct implementation.** Deleted, matching the four verify checks removed from the script
    (`V-fixloc`, `V-fixabs`, `T-skufix`, `T-merchfix`), and `skuWritePermitsPickFaceDestination` added so the
    relaxation is pinned positively rather than merely unpinned.
  - **§10.4 Q11's safety argument** rested on the configuration being unwritable. It is writable now — but
    the precondition it named ("if either predicate is relaxed *without answering this question*") was met:
    Q11 was answered 2026-08-06, two days before the relaxation.
  - **Lesson, and it is the same one as the orphaned message keys:** a decision recorded in one box does not
    propagate itself. When a rule moves from write-time to run-time, grep every passage that cites the old
    predicate — including the test tables and the verify script, which are the two places a stale rule turns
    into a red build that looks like honest work.

- **2026-08-06 (later) — reconciled against SBDEV-2731 revision 4.** 2731's plan was itself reconciled to
  its as-shipped code that day, which resolved the divergence flagged in the entry below. Three concrete
  impacts on this plan, all now fixed:
  - **The neutral message TEXT changed** (2731 review finding #4, commit `89de3f0`) and §3.6.1 quoted the
    superseded string. As-shipped is `Unit load type %1$s is not permitted on location %2$s (location type
    %3$s).` **The key NAME is unchanged**, so prerequisite 0 and the two-key split are unaffected.
  - **Three `Flowbin*` message keys are ORPHANED.** D14 relocated them here with Fix B; D15 then sent Fix B
    on to SBDEV-2821 and the keys did not follow. They exist only in 2731's document. Recorded in §8.4 as
    belonging to SBDEV-2821. **Third artifact orphaned by the same mechanism** (after F3/Q5 → SBDEV-2796 and
    the D15 bundle → SBDEV-2821): when a D-decision moves scope, enumerate what travels with it.
  - **2731 ships a tri-state `isPutawayDestinationApplied`** whose template comparison must stay `=== false`
    (`!null` is `true`, so a falsy rewrite restores the bug on first paint for exactly the tenants that
    configure alternate destinations). This plan edits the same template block, so it can break it —
    §3.11.1 now carries the requirement and `U-tristate` pins it.
  - 2731 independently confirms the **24 call sites** figure and the **second `receiveGoods` entry point**,
    both already corrected here.

- **2026-08-06 — second review pass (architect + critic), after the delta since 2026-08-04.** Four things had
  landed since the last review: Q11 answered, the Flyway renumber, SBDEV-2854 shipping adjacent
  destination-gating changes, and SBDEV-2731 PR1 reaching PR. Findings folded in:
  - **P2.7(c) clause 1 had no implementable predicate** — "not a pick face" was named but never defined,
    while §7.1 mandated a test for it. Now `location_area.useforpicking`, matching SBDEV-2854's
    `isPickingArea`. SBDEV-2854's data proved the gap was populated (70 FLA-free wineco club pick faces),
    which made a **tier-2/3** default onto a live pick face reachable — a route D15's warnings never
    covered, since those are all about tier 1 and about *relaxing* the predicates. **Measured 2026-08-06 and
    CONFIRMED LIVE, including on production:** `Storage and Picking` is `useforstorage = TRUE`, so the exposed
    set is **726** FLA-free pick faces on `wsl-wineco-uat` and **58** on `wms2-hydra` (HMG PRD) — an order of
    magnitude beyond the ~70 clubs inferred from SBDEV-2854's plan. **The measurement that missed it was taken
    on `wh01_hydra_v2t`, the one tenant that structurally cannot exhibit it** (no picking area there is also
    storage or goods-in). Re-run every P2 measurement against a migrated tenant, not only fresh-seed.
  - **Merge order 0b added.** The renumber to `V2.2.11` only protects tenants if SBDEV-2854's `V2.2.10`
    merges and applies **first**; the reverse order reproduces the exact silent-wedge the renumber avoids.
    Neither §5.1 row 1 nor the §8.1 table carried that constraint.
  - **"35 callers" was wrong in 11 places.** Measured: `transferUnitLoadToLocation` **24** call sites
    (**21** non-receiving, 3 from `ReceivingService`), `transferUnitLoadToCarrier` **9**, combined **33**.
    SBDEV-2731's own code review caught the same error independently. The §3.6.1 two-key argument survives
    unchanged at 24 — only the figure was wrong.
  - **`receiveGoods` has a second production caller** — `ReturnAdviceAutoReceiveService:556` (SBDEV-2778),
    whose consumer is OMS, a machine. Transactionally safe; the *error surface* is unmodelled (§3.6.2).
  - **Verify-script integrity.** `UBS-neg4` and `W-neg4` were vacuous bare negatives against symbols that
    exist nowhere and are now conjoined; `T-msg1` and `U-neg1` asserted things **contradicted by what
    SBDEV-2731 actually ships** (a retained label constant, a removed assertion surviving in a comment);
    `PHASE=1a` — which §11.1 told implementers to run — filtered every check and exited **0**. Baseline
    re-measured at **7 pass** across all three phases, and stable now that the vacuous checks fail closed.
  - **Meta-finding worth carrying forward:** several of this plan's assertions about what SBDEV-2731
    delivers were written against 2731's *plan*, and 2731's implementation diverged during its own code
    review. Every remaining "SBDEV-2731 PR1 owns this" claim — in §11.1 and in the script's skip reasons —
    needs one pass against the merged commits, not against the ticket.

- **2026-08-04 — D15/D16/D17/D18 (author decisions after the (c) answer).** **D15:** tier-1 pick-face
  placement **deferred** to a follow-up; this plan ships direct placement for tiers 2/3 only, which sends
  Fix B, C2b, Q1, Q4, F1, F4, F5 and Q11 out of scope and leaves the plan waiting on nothing unowned.
  Superseded: the post-(c) reading that this plan must absorb Fix B. **D16:** **one** migration,
  `V2.2.11__putaway_destination_hierarchy.sql` — supersedes §2.9's two reserved versions (both written as
  `V2.2.08`) and the `V2.2.08` number itself, taken by SBDEV-2801 on 2026-08-04. **D17:** the §6
  receipt-correction guard **stays**; correction is documented unavailable for directly-placed receipts —
  supersedes "decide whether to relax it", and required even under D15 because D13 rule (d) puts tiers 2/3
  on non-goods-in staging lanes. **D18:** review lane before approval; status stays `draft`.
- **2026-08-04 — SBDEV-2796 / Q5 answered (c), "bounds are advisory for receiving".** The single largest
  scope change since the draft. Superseded: the assumption that F3 would be answered restrictively (options
  (a) or (d)), which is what let this plan park 2731's Fix B, flowbin classification and resident-UL
  resolution as *gated scope* and justify D13 as "sidesteps F3". Under (c) none of that holds — Fix B
  survives and lands here, F1/F4/F5 become mandatory, C2b becomes the binding gate, and D13 keeps its rule
  but loses its stated reason. **P2.5 / P2.7(c) were briefly relaxed and then
  reverted the same day.** The relaxation (SKU scope rejecting only on FLA *mismatch*, tier 1 exempt from
  P2.7(c)) was correct about the runtime semantics but unsound in combination with D15: it permitted the
  tier-1 pick-face *configuration* while the *placement* path stayed ungated —
  `ReceivingService.java:454-457 → :491` already places tier-1 destinations unconditionally — which would put
  a second unit load on a location whose `assignedunitload_id` is `UNIQUE`. Both predicates are therefore
  **absolute at all three scopes**, and that is now the documented mechanism enforcing D15; the follow-up
  ticket relaxes them to the mismatch-only form when it ships tier-1 placement. Two of
  SBDEV-2796's own ACs did not survive its answer: the capacity-check AC is **voided**, and the
  replenishment-against-an-over-bound-bin AC is now **compulsory and open** (new **Q11**, owned by SBDEV-2821 from 2026-08-04). Full
  consequence list in the revision banner at the top of this document.

- **`putawayDestinationNotPermitted` moved out of `UnitloadBusinessService:191` and split into two keys** — that throw site serves 24 call sites, 21 of which have no configured putaway destination and for whom a "clear the configured destination" remedy is misleading (§3.6.1).
- **`Resolution` carries `compatible` instead of the resolver throwing** — the resolver must run on the carrier branch to fix 2731, but the destination is never applied there, so the throw became a separate caller-invoked `requireCompatible` (§3.1, D10).
- **A `readOnly = true` query facade was added between controllers and the `MANDATORY` resolver** — there is zero `@Transactional` under `controller/`, so a direct call would have thrown `IllegalTransactionStateException` on every request to the 2731 display endpoint (§3.1.5).
- **Tier 3 reads `findBySyskeyAndClientIdAndWorkstation`, not `findSysvalueByClientIdAndSyskey`** — the latter has no `workstation` predicate against a `(client_id, syskey, workstation)` unique constraint, so it returns an arbitrary row (landmine A6, §3.4a).
- **Merchant and warehouse writes became count-and-confirm rather than an absolute reject** — an absolute reject would have made the warehouse tier settable only to something type-equivalent to the lane it replaces, turning "ships inert" into a structural certainty (D11, §3.4c).
- **The event handler splits create from save, and validates the delta rather than the state** — a shared method would have broken every HAL `POST` of the three exported entities, and state validation would have turned existing config rot into an edit lock on unrelated fields (§3.9.2, §3.9.3).
- **The handler validates in `Before` and audits in `After`, and throws an unchecked `PutawayConfigValidationException`** — a single `@Transactional validateAndAudit` in `Before` would commit an audit row before SDR's save, letting the record outlive a failed write; and a checked `BusinessException` is swallowed into a 500 by SDR's reflective invoker (§3.9.6, §3.9.7).
- **`FlushModeType.COMMIT` was dropped from the previous-value read** — with OSIV off the merged entity is detached, so there is nothing to flush and the flush mode changes nothing (§3.9.5, closed Q6).
- **The backfill preflight guard, statement ordering and dropped `client_id` filter** — a scalar subquery aborts mid-migration on a duplicate lane name, the pre-image must precede the backfill or it silently records zero rows, and any client filter could diverge from tier 4's `findByName` (§5.1).
- **The migration split into `V2.2.11` (Phase 1) and `V2.2.11` (Phase 1)** — the phase boundary is tier *reachability*, not "does it need Flyway": leaving the `DROP NOT NULL` and backfill in 1b would have shipped a one-tier resolver that passed `PHASE=1` 0-fail. Only **b** adds a column an entity maps, so only **b** carries the operator-before-merge gate (D9, §5.2, §8.1).
- **`PutawayConfigController` added as the typed write surface** — without it the three writers had no callers, and D11's confirmation parameter has nowhere to live, since Spring Data REST discards unknown query parameters (§3.5a).
- **`SystemPropertyController`'s two direct-save endpoints were closed and the sysprop `DELETE` was brought under audit** — `@RepositoryEventHandler` fires only on Spring Data REST's own events, so a direct `repository.save()` bypasses the D7 guard entirely; delete is accepted because absent == not configured, paired with an unconditional Operation Options control so it cannot lock the tier out of the UI (§3.9.1, D12).
- **Authorization moved from the event-handler methods onto `PutawayConfigService`** — Spring Data REST may capture the raw handler target rather than the security proxy, in which case `@PreAuthorize` on a handler method is silently inert (§3.12, §3.9.4).
- **The mobile-putaway back-compat note now names `unitloadNotInInboundArea`** — `MobilePutAwayService:113-117` runs before the lane check, so a directly-placed unit load never reaches `unitLoadNotInPutAwayLane`; the recovery path (mobile Move Unit Load / web Transfer Stock) is named alongside it (§3.7.4, §6, M13/M13a).
- **The location picker became tiered, with a lock warning on the advanced tier** — pointing a default at a live storage or pick location moves a `FOR UPDATE` onto a row picking and replenishment lock in the opposite order, in a codebase with no deadlock-retry infrastructure (§3.11.2, §7.6 row 8).

---

## 13. Notes

- **Reference workflow doc:** `sbdocs/3-Resources/workflows/wms2-receiving-putaway-workflow.md` §4.2 / §5.2 / §5.3. There is **no** receiving/putaway *design* doc in `sbdocs/3-Resources/design/` — consider writing one after this ships, since this plan introduces the first shared destination-resolution service.
- **Doc drift to fix after implementation:** the workflow doc's putaway section will need the four-tier precedence; `sbdocs/3-Resources/architecture/wms2-function-to-docs-map.md` needs rows for `PutawayDestinationResolver` and `PutawayConfigService`. Run `/verify-docs` against the Phase-1 diff.
- **Migrated-copy id landmine:** on `wh01_hydra_v2` (v1→v2 migrated) `PutAwayLane` is `id=50155, type_id=50057, area_id=50104`; on `wh01_hydra_v2t` (fresh-seeded) it is `id=8, type_id=7`. **No test fixture or migration may assume low ids**, and the ticket's quoted ids (`unitloadtypeId=4`, `location type=2`) resolve on the **fresh** copy only.
- Neither Hydra copy contains an `Ice Pack` location — it exists only on NYWH UAT/prod, so M7/M10 must construct an equivalent incompatible pair (e.g. `Case` → a `flowbin` location) rather than looking for that name.
- **Status:** `draft` = pending approval. No source file under `v2/wms2-api/` or `v2/wms2-web-ui/` has been modified. Design review (`architect` + `critic`) is complete and folded in; §12 records what changed.
