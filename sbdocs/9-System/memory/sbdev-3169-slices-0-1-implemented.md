---
name: sbdev-3169-slices-0-1-implemented
description: SBDEV-3169 Slices 0+1 + all 19 review findings MERGED on dev; gate at OFF; V2.2.23 seeds the mode row; don't pass SHADOW yet
metadata:
  type: project
---

SBDEV-3169 (SDR read gating, v2) — Slices 0+1 **MERGED to develop 2026-09-01**: wms2-api PR #255 →
`3b0d0ca6`, wms2-web-ui PR #104 → `3117aca`. ClickUp `on dev`. Merged develop verified green on the
merge commit: 5937 tests, 0 failures.

**Review debt CLOSED 2026-09-01**: the four lanes re-ran against the merge commit and returned 2 High,
9 Medium, 8 Low + 4 wrong published claims. All fixed and merged as **PR #257 → `2e757457`** (5970
tests, 0 failures; PIT 105/106 over all SEVEN `Sdr*` classes).

🔴 **The two Highs are the durable lesson, because both were self-inflicted by reasoning that read as
sound:**
- **"It ships at OFF so nothing changes" was FALSE.** `getSysvalue` is
  `@Cacheable(unless = "#result == null")` and the row did not exist, so the miss was NEVER cached —
  one `los_sysprop` query per SDR request against a 5-connection pool. `SyspropService:258` already
  documented that trap. Fixed by `V2.2.23` seeding the row. See
  [[concurrent-maven-one-worktree-false-reds]] for the sibling lesson about trusting a green number.
- **The gate could not protect its own kill switch.** `Sysprop` must stay writable and was unruled, so
  any `wms_user` could `POST /v3/sysprop` at a lower `client_id` — `ORDER BY client_id LIMIT 1` makes
  it SHADOW the operator's row, and `parse()` takes any garbage as OFF. Fenced at both routes plus
  seeded at `client_id = 0`. The key is now SQL-only by design.

⚠ **Two shipped "fixes" were comments that were FALSE**: the case-insensitive path fallback (its cited
evidence `/v3/shipperId` is an MVC controller, not SDR) and `BOOTSTRAP_READS` (consulted by nothing).
Deleting each closed two findings. In this file, treat a comment asserting a measurement as unverified.

⚠ **Still do not advance a tenant past `SHADOW`** — the rule set was narrowed post-merge (see below)
and no tenant has been through a shadow cycle.

- Prerequisite: wms2-api PR #254 → `8aba7de1` fixed a red `develop` caused by SBDEV-2573 encoding a
  set size in two test NAMES — caught by the ArchUnit rule this same ticket added in PR #241. That
  rule catches only ~half the notation space (DisplayName pattern needs a digit, method pattern needs
  a number-word and is case-sensitive; 34 existing DisplayNames invisible; `allSixSubOps_usePagedQuery`
  escapes both). Recorded as a comment on SBDEV-3169.
- **Ships at `OFF`**: the sysprop `WMS2_SDR_READ_GUARD_MODE` row does not exist and an absent or
  unparseable value parses to OFF. Enabling is 2 deliberate SQL steps per tenant (SHADOW →
  ENFORCE_RULED). No Flyway. Consequence: with no row the key is invisible on the sysprop admin
  screen, so the first enable is a DB statement, not a UI action.
- **AC-2 is finally MET** — the criterion SBDEV-3017 set for Class A and never met.
  `SdrReadGateEnforcementContextTest` proves a real MockMvc dispatch through WebConfig's
  `MappedInterceptor` *bean* → SDR's `RepositoryRestHandlerMapping` → `preHandle` → 403. Use
  `BaseControllerIntegrationTest` + `*ContextTest`; that lane boots (see `WebContextLaneContextTest`).
- 🔴 **4 of the 7 SDR dispatch classes are PACKAGE-PRIVATE** in spring-data-rest-webmvc 4.5.7 —
  `RepositoryEntityController`, `RepositorySearchController`, `RepositoryPropertyReferenceController`,
  `RepositorySchemaController`. Only `RepositoryController`, `ProfileController`,
  `alps.AlpsController` are public. So an explicit class list is a **compile error**, not merely
  fragile; detect by package and load them in tests via `Class.forName`.
- 🔴 **The guard is verb-agnostic.** Named `SdrFunctionGuard` (was `SdrReadGuard`): a rule covers the
  type's reads AND every write verb SDR still publishes. `UserGroup`/`UserRole` are 2 of the
  kept-writable 11, so this also closes their SDR writes. Scope beyond "Slice 1 gates reads" — flagged,
  never adjudicated.
- 🔴 **RULES NARROWED post-merge to `{WEB_UI_VIEW_USER_MANAGEMENT}` alone** (Nam, 2026-09-01). The
  4-way union's justification was INVERTED: `WEB_UI_VIEW_ROLE`/`_GROUP`/`_FUNCTION` appear in **zero
  files across both UIs**; the only live gate is `pages/admin.vue:59` on `WEB_UI_VIEW_USER_MANAGEMENT`,
  and Groups/Roles/Functions are ungated **tabs inside** that one component. Six roles holding a strict
  subset already exist, each bound to an empty group.
- Slices 2–4 still blocked on the 62-row rule table review (31 of 62 rows PROPOSED).

See [[sbdev-3142]], [[wms2-sdr-is-gatable-via-mappedinterceptor-bean]],
[[wms2-gating-programme-is-live-on-prd]], [[idle-review-subagent-is-not-a-passing-review]].
