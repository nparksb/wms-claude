---
ticket: SBDEV-3545
lane: ralplan round 1 — Critic (opus), independent of Architect
snapshot: plan-r1-snapshot.md
verdict: ITERATE — 1 High, 6 Medium, 4 Low
---
# Critic review — round 1

- **H1** Base moved to 286b5673 (PR #425 SBDEV-3381, V2.2.34 `AND r.name IN ('outbound-manager','super-admin')`). Plan still says V2.2.34 pending; window model wrong — each tenant is exposed until V2.2.34 runs THERE, then latent until the next name-keyed seed. Rebase (the 28 incoming files don't touch the role surface); rewrite §1/§5.1#5/§8: promote 3545 no later than 3381, else 3381 §5.1 #9 is a hard pre/post gate per UAT/PRD promotion.
- **M1** Fix D sweep grep misses `{@code PUT} is safe and is deliberately kept` (RestConfiguration:175) and :178-180, :297-298, :335-341, :418-423 ("the TEN resources with a live UI writer … userRole"), UserRoleRepository:44, UserRoleController:27 "all four handlers", UserAdminFunctionGateUnitTest:54. ≥6 RestConfiguration regions. List by line; markup-tolerant grep; positive control = hits :175.
- **M2** MustStayWritableCollectionPostWithdrawalContextTest asserts `checked … isEqualTo(8)` → 7; SdrMustStayWritableStateNotPatchableContextTest loops the set ("among the ten" stale); RestConfiguration MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN name/contents; step 3 "seven exposure pins" is really 5 + gate + Jest.
- **M3** DIVE catch mislabels 22001 (description varchar(255) unchecked) as duplicate; validate description ≤255; map only 23505 / uk_6yyotbpw7edc76ejucc4mflf2; controller AC per cause + widened-catch mutant.
- **M4** State ordering: validation + findByName before any setter (AUTO flush would hit the index first).
- **M5** AC-4 mutant impossible with service signature (Long,String,String) → controller verify(service).updateRole(7L,"n","d") + verifyNoMoreInteractions, and service asserts number/connector/additionalcontent/entityLock unchanged. AC-6 needs service-unit rows (unknown id, blank). AC-5 own-name ambiguity → own name + new description persists.
- **M6** Rename audit omits `anonymous` (V2.2.21 keys on it); derive the name list from `r.name` over db/migration; blind spot: rename-then-revert.
- **L1** AC-1 re-read vacuous under test-level @Transactional → flush+clear, re-read via JPA, prove sensitivity on pre-fix code.
- **L2** Cite D3 (not test convenience) for rejecting @PutMapping("/{id}").
- **L3** §9 row 8 rollback: revert both, UI first.
- **L4** trimming; `updateRole/2` needs Principal; define the AC-3 ungated row; UNIQUE index sampled on 6 tenants not 8.
Passed: surefire excludes **/*IntegrationTest.java (pom:588); H2 create-drop builds NO unique index (AC-5 context row → skip, record); AC-8 harness landlord @Primary catches bare @Transactional; no /{id} controller mapping; web-ui b32a134 unchanged, role.js:118 only $put.
