---
ticket: SBDEV-3545
lane: ralplan round 1 — Architect (opus)
snapshot: plan-r1-snapshot.md
base: wms2-api origin/develop 286b5673 (SBDEV-3381 merged since a715a27b)
verdict: ITERATE — 1 High, 4 Medium, 2 Low; design holds
---
# Architect review — round 1

Verified on origin/develop 286b5673: WRITE_VERBS={POST,PUT,PATCH,DELETE} (RestConfiguration:28); item-exposure change leaves item GET, /search/*, /{id}/functions GET intact; POST /v3/userRole/update cannot collide (the /create precedent proves an MVC POST subpath wins; an unmapped /update falls to SDR → 405); class gate + FunctionGuardArchTest GOLDEN_MAP + requiredId (:186) confirmed; handler key must be `updateRole/2` (Map, Principal); UserRoleService tenant-TM pattern at :202/:273; all 7 pins exist; no @Cacheable on role/access types; the only runtime name compare (AccessService:300) compares two id-loaded rows → rename-invariant; gate-holder renaming to a seed name is an accepted residual (createRole already allows any seed name, and saveRoleFunctions grants anything).

Antithesis: the root defect is "grants keyed on a mutable user-chosen string"; Fix A closes the last ungated writer but leaves the pattern unguarded → add a migration-scan rail.
Tension: D4's accepted 405 window vs 3381 now on develop — the constraint is environment promotion order (3545 must reach each env no later than 3381), not merge order.

- **H-1** SBDEV-3381 merged (286b5673 PR #425); V2.2.34 (`AND r.name IN ('outbound-manager','super-admin')`) applied on dev. Flyway applies once per tenant → risk window = first apply per tenant; grant then bound by id. Editing V2.2.34 breaks the checksum, so F-2 "rekey" is impossible — recast as corrective migration / ops check. Rewrite §5.1 #5, §8 row 4, F-2; post-boot grant-identity check on dev; pre-apply check per UAT/PRD tenant; rebase citations to 286b5673.
- **M-1** SdrWriteWithdrawalContextTest:60 claims its WITHDRAWN set is IDENTICAL to RestConfiguration.SDR_WRITE_WITHDRAWN (50; "50 withdrawn + 9 kept = the 59 writable resources"). Moving UserRole to test WITHDRAWN (51) without the array breaks it. Choose (a) keep UserRole per-type only + rewrite parity javadoc "identical except UserRole", or (b) add to array (the :257-260 comment warns that masks the per-type block). Pin table misses SdrMustStayWritableStateNotPatchableContextTest (:55 iterates MUST_STAY_WRITABLE) and CustomerorderTransferLaneSdrWriteContextTest (javadoc :68); MustStayWritableCollectionPostWithdrawalContextTest:192-196 REQUIRED_ITEM_VERBS key-set pin must stay consistent. Grep the claim text ("IDENTICAL", "59 writable").
- **M-2** description is varchar(255) NOT NULL (V2.2.00:1501) but unchecked; a 300-char description → SQLSTATE 22001 → DIVE → false "name already exists". Add description ≤255 → 422; map DIVE to dup-name only on SQLSTATE 23505 (or re-check findByName); AC-6b.
- **M-3** AC-1 405 needs in-test positive controls: GET /v3/userRole/{id} isOk() for same fixture/principal, and PUT /v3/userGroup/{id} not 405.
- **M-4** Add AC-9: unit test scanning db/migration/V*.sql for `\b[rg]\.name\s+IN\s*\(` in grant INSERTs; allow-list V2.2.19/V2.2.21/V2.2.34; ~30 lines; sub-T3.
- **L-1** Pin in Jest that editRole passes `id` (depends on SDR exposeIdsFor UserRole).
- **L-2** Cite AbstractBaseEntity @EntityListeners(AuditingEntityListener) + @LastModifiedDate as the basis for the `modified`-based rename audit.
