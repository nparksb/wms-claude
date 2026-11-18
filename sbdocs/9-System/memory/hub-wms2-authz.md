---
name: hub-wms2-authz
description: wms2 authorization facts: function gates, Keycloak role/group claims, gate-test rules, SDR gating. Hub: one line per member memory
metadata:
  type: reference
---

Hub for **wms2 authz / function gating / Keycloak roles**. Moved out of MEMORY.md on 2026-10-28 to keep the index under its load limit; each line links the member memory (newest last).

- [sb_admin comes via the Keycloak GROUPS claim](sb-admin-is-siteboss-super-admin-via-groups-claim.md) — staff-only; hasResourceRole never sees it
- [wms2 AdminController: base class of 43](wms2-admincontroller-is-a-base-class-for-43-controllers.md) — every mapping-grep endpoint inventory is low
- [STALE: wms2 gates self-grantable](wms2-function-gates-are-self-grantable-via-ungated-usercontroller.md) — CORRECTED 2026-10-01: User/UserRoleController now class-gated VIEW_USER_MANAGEMENT + GUARDED
- [SBDEV-3005 role↔function key reversed (v2)](sbdev-3005-role-function-composite-key-swap.md) — merged to develop, NOT to main → still broken on PRD
- [wms2 gate anti-drift covers only GUARDED](wms2-function-gate-anti-drift-only-covers-guarded-classes.md) — `setupMockMvc` installs no interceptor →
- [SDR IS gatable — via a MappedInterceptor bean](wms2-sdr-is-gatable-via-mappedinterceptor-bean.md) — 6 src/main javadocs say "structurally cannot"
- [detectMappedInterceptors finds an already-created singleton](spring-detectmappedinterceptors-matches-already-created-singleton.md) — widening the declared type makes gating ORDER-dependent
- [STALE: access-chain hops writable over SDR](wms2-access-chain-hops-1-2-writable-over-sdr.md) — CORRECTED 2026-10-01: hops 1, 2, 4 write-disabled in RestConfiguration
- [Direct user→role assignment is unused in v2](wms2-direct-user-role-assignment-is-unused.md) — only user→group→role→function confers anything
- [wms_admin confers ZERO functions](wms2-wms-admin-confers-zero-functions.md) — widening @PreAuthorize can't unlock
- [Keycloak group `/sb_admin` IS the WMS `sb_admin` role](wms2-keycloak-groups-claim-emits-full-paths.md) — read `resource_access`, NOT `groups`; bare
- [A new FunctionEnum constant needs THREE things](wms2-adding-a-function-constant-needs-three-things.md) — omit the `initDB` grant line and every
- [Gate tests need UNGATED rows + full varargs](gate-tests-need-ungated-rows-and-full-varargs.md) — a gated-rows-only pin can't see a class-level
- [wms2 gating programme IS live on prd](wms2-gating-programme-is-live-on-prd.md) — present at v0.0.21 (the running build); the old "develop-only, not on prd" memory was deleted and is wrong
- [Spring Security 6 ignores a custom expression-root override](spring-security-6-ignores-custom-expression-root-override.md) — Supplier path, private root factory; SBDEV-2863 began 2025-09-20
- [Ungated wms2 handler? check tranche map first](wms2-ungated-handler-check-tranche-map-first.md) — SBDEV-3243
- [All v2 users are System; SDR read guard OFF](wms2-estate-all-users-system-sdr-guard-off.md) — 2026-10-30: 0 non-System users on DEV + 8 UAT/PRD DBs; guard OFF on UAT/PRD; client-scoping fixes are pre-emptive, onboarding-gated
