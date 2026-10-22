---
name: sbdev-3012-user-group-write-atomicity
description: "SBDEV-3012 (v2) PR #182 — four user/group multi-write endpoints made atomic; /user/delete silently stripped 12 of 19 users' memberships then returned HTTP 200 \"DELETED\"; deleteGroup CASCADES (refusing would make 0 of 29 groups deletable)"
metadata: 
  node_type: memory
  type: project
  originSessionId: 74e9ade3-54f9-40c9-b7fd-5f0d8ec80cce
  modified: 2026-08-21T21:00:48.866Z
---

**UPDATE 2026-08-26 — THREE more PRs merged; ticket status is now MISLEADING.** wms2-web-ui
[#84](https://github.com/SiteBossInc/wms2-web-ui/pull/84) `35a77a7`,
[#85](https://github.com/SiteBossInc/wms2-web-ui/pull/85) `c3f8e6e` (the SBDEV-2967 pin),
[#86](https://github.com/SiteBossInc/wms2-web-ui/pull/86) `e3cd2e1`. **develop baseline is now
738 tests / 0 failed / 2 red suites** (the labelPrinting pair, 0 failing tests).

⚠️ **The ticket has been `on qa` since 2026-08-22 for release v2.0.133, and NONE of these three PRs is
in a release.** A QA pass against v2.0.133 would legitimately sign off while missing the group-delete
button, the lockout warning, the 404 behaviour and the token fix. Flagged to Nam; status not flipped.

What #86 added beyond the reachability fix:
- **A 404 is "goal met", not an error** — info toast in the UI's own words, dialog closes.
  `adminWriteError` gained `gone`. The principle worth reusing: **quote the server when it knows
  something the UI does not; author locally when it does not.** A 422 carries a reason the UI cannot
  compute; a 404 carries nothing it lacks. The API had already taken this position —
  `UserGroupService.deleteGroup`'s concurrent-delete branch: *"The caller's goal is met either way, so
  this is not an error."*
- **Admin-lockout warning.** Measured on dev: only ONE grid-visible group grants
  `WEB_UI_VIEW_USER_MANAGEMENT` — `super-admin` (51856) via role `super-admin` (51806) — and **all 38
  of the 99 users who hold it get it that way**; the other 6 holders' groups are all `connector = true`
  (invisible in the grid). Resolving it costs one GET per role because `UserFunction` IS an exported
  SDR repo, so `UserRole.functions` is a link, not inline.
- **`console.log(error)` PRINTS THE BEARER TOKEN** (`error.config.headers`, set by
  `plugins/axios.js`). New `logApiFailure()` logs label + status only. 17 sites converted in the two
  admin stores. ⚠️ **287 occurrences across 58 files remain repo-wide** — unfiled, Nam's call.

**UPDATE 2026-08-26 — the group-delete half is now REACHABLE.** wms2-web-ui
[PR #84](https://github.com/SiteBossInc/wms2-web-ui/pull/84). The dead dispatch below was the reason the
group half could never be QA'd; correcting it arms the cascade, so the confirm dialog now loads and states
the blast radius and DISABLES Delete while the counts are in flight. Measured: the grid filters to
`connector = false` (13 groups on dev) and the largest is `super-admin` — 2 role grants, **38 members**.
**Ticket status is `on qa` but its QA note is not usable**: it ticks "Delete a group — removes cleanly",
which that screen could not produce, and its Critical UX check section is still unfilled template
brackets. **RELEASE GATE: on `develop` the delete IS gated (class-level
`@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)`), on `main` it is gated by NOTHING** — do not ship the UI
half to a build whose API lacks the gate. Still unfixed by choice: warning when the group grants the
function gating that very screen (38 of 99 dev users hold it, **all via `super-admin`**, so deleting that
group locks every admin out of user management with no UI route back), and `console.log(error)` printing the
bearer token in this module's OTHER actions. See
[[wms2-web-ui-coverage-instrumentation-disarms-render-source-pins]] for the test trap hit on the way.

**SBDEV-3012 (v2) — `on dev` 2026-08-21. MERGED: wms2-api [#182](https://github.com/SiteBossInc/wms2-api/pull/182)
as `8dbe8b1`, then wms2-web-ui [#71](https://github.com/SiteBossInc/wms2-web-ui/pull/71) as `0c96131`
(API first — the UI reads error bodies the API introduces).** Four endpoints → two transactional
service methods each on `UserGroupService` / `UserService`, mirroring SBDEV-3005 and SBDEV-3011.

**VERIFIED LIVE on DEV (`dev_wh01_om1`), which is the one thing no automated lane here can do.**
`GET /v3/user/delete/177301` — a user with warehouse history and 7 memberships, the exact input that
pre-fix returned HTTP 200 `"DELETED"` while destroying all 7 — now returns **422** with
`{"error":"User 177301 cannot be deleted because they are still referenced by other records…"}` and
**user_exists=1, memberships=7, identical group_ids**. The rollback held. Three more probes:
unknown id → **404** ProblemDetail (was 200+errors); non-array `groups` → **422** `parameterErrors`
(was a bare 500); unknown child id → **422 "Unknown groupId(s)"** (was a bare 500).

**Token recipe for these probes** (the trap cost me a 401): the tenant's Keycloak is NOT the one in
`config/keycloak.json.*`. Read `tenant_auth_configuration` on the **landlord** — for wineco dev it is
`https://kc2.dev.sbo.li` realm **`wineco`** client `om1-api` (confidential, secret in that table), NOT
`kc.dev.sbo.li` realm `spk`. A token from the wrong realm gives
`401 "no matching key(s) found"`, which reads as a Keycloak misconfiguration. Headers:
`X-Tenant-ID: wineco`, `facility_code: wsl` (only that tenant row is `active`).

**The real bug was the HTTP contract, not the transaction.** `GET /v3/user/delete/{userId}` caught
`DataAccessException` and returned `ResponseEntity.ok(errorMap)` — a **200 with an `errors` array**.
`store/admin/user.js:110` try/catches the axios promise, which never rejects on a 200, so the UI said
"User deleted" while the user still existed **and their memberships were already gone**. Measured on
hydra-uat: **15 of 19** users are blocked by one of the **9 operational `operator_id` FKs** (note
`pickingorder_position` uses `pickedbyoperator_id`), and **12 of them held memberships → 26 rows
silently destroyed per attempt**. Only 4 users were actually deletable. Now 422 naming the reason.

**`deleteGroup` CASCADES — a deliberate divergence from SBDEV-3011's refuse-don't-cascade.** A role is
shared and its holders are third parties; a group's members are not — losing the group *is* what
deleting it means. And the refusal design was measured **unusable**: all 29 groups have roles, 15 have
members, so `groups_deletable_if_we_refuse = 0`, i.e. exactly the outcome that left SBDEV-3011's
operator-visible impact at nil. `mywms_group_mywms_role` + `mywms_group_mywms_user` are the **only** two
FKs on `mywms_group`, so the cascade is complete.

**THE COUNTER-INTUITIVE LANDMINE: adding the transaction is what CREATES the re-insert hazard.**
Un-transacted, clear-then-reinsert worked because each `SimpleJpaRepository` call committed on its own.
Under one transaction Hibernate's `ActionQueue` emits **inserts before deletes** and `CrudRepository`
gives no `flush()` to sequence around it, so every *retained* row is re-inserted while it still exists —
on the dominant path, since editing a set normally keeps most members. The set difference is therefore
part of the fix; atomicity alone would have made a rare bug permanent. See
[[hibernate-delete-then-reinsert-same-key-needs-set-difference]].

**CORRECTED 2026-08-21 by review — I claimed these tables carry a UNIQUE composite index and that was
FALSE on production.** `V2.2.00__base_v2_schema.sql:4520,4541` create the composite
`mywms_group_mywms_{role,user}` indexes as **plain `CREATE INDEX`**, and neither table has a PK or
unique constraint. Measured: **hydra PRD and shipitez nywh UAT have NO unique index at all**; the
`..._uindex` objects on hydra UAT / DEV2 / wineco DEV were created out-of-band, so **no
Flyway-provisioned tenant has uniqueness**. (Contrast `mywms_role_mywms_function`, which DOES carry a
PK — which is why SBDEV-3005/3011's tables behave differently.) I had measured hydra-uat only and
generalised — the same one-environment error as [[wineco-dev-db-is-dev-wh01-om1-not-the-migration-env-target]].

Two consequences: the re-insert **does not raise 23505 where it matters — it silently creates duplicate
rows**, which makes the set difference *more* necessary, not less; and **these methods are not safe
against concurrent callers** — two simultaneous adds of the same id both see it absent under READ
COMMITTED and both insert, and the transaction does not serialize them. Fixing that needs a unique index
plus a de-duplicating migration; deliberately out of scope and unfiled. Consistent with
[[wms2-join-table-uniqueness-is-out-of-band]]: never assert an index exists from one tenant.

Also: bulk JPQL only, never `deleteById` — `UserGroup.roles` and `User.groups` are `@ManyToMany(EAGER)`
**second mappings over the tables being emptied** (the SBDEV-3011 `CollectionRemoveAction` hazard).

**Reviewed by four independent lanes (transaction / authz / contract / test-adequacy), all SHIP WITH
FIXES; PR #182 is `51d8c09` → `060d4ed` → `0a3589f` → `9cadd6c`.** Highest-value finding: **a stray
BULK clear at the top of either `replace*` method was invisible to all 5407 tests** — one line wipes
every grant and re-adds only the difference, i.e. exactly the data loss the ticket exists to prevent,
and the most likely future edit now that a comment says clear-then-reinsert won't fail loudly. The
minimality tests asserted only the ENTITY-level delete/save; the bulk methods are a different signature
on the same mock. **Nine of the ten findings were "a test that could not fail", not a code defect** —
including `@RestResource(exported = true)` on all five new bulk deletes surviving, which would publish
ungated bulk-DELETE routes over the tables every access decision reads.

**Process note worth more than the fix:** SBDEV-2984's controller-level "writes nothing" gate
assertions went **VACUOUS** the moment the writes moved into the service — `verify(repo,
never()).delete(...)` passes whether the gate fires or not, because the controller no longer touches
that repository. Retargeted onto the service mocks and re-proved with two regression mutants. Any
extract-to-service refactor silently guts the caller's absence-assertions.
See [[mutation-harness-traps]] and
[[mutation-harness-traps]] (the first mutation run on this ticket was fabricated).

Still open, all with existing owners — **no new tickets**: SBDEV-3021 (soft delete / the missing
`mywms_user_mywms_role` cascade), SBDEV-3030 (admin stores discard every error body, so the new 422
text never reaches an operator), SBDEV-3013 (the SDR association surface). Both delete endpoints
remain **GETs**. The group-delete half is STILL unverified and can only ever be checked by API call:
`deleteGroupPop.vue:38` dispatches `admin/userGroup/deleteGroup` but the module is `admin/group`, so
group deletion is dead in the web UI — one word to fix, deliberately NOT fixed because it would
ACTIVATE a destructive cascade that has never run from the UI. Related: [[sbdev-3011-delete-role-join-table-cascade]],
[[sbdev-3005-role-function-composite-key-swap]],
[[sbdev-2984-usercontroller-gated-but-sdr-user-still-writable]]
