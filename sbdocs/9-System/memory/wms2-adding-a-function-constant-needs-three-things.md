---
name: wms2-adding-a-function-constant-needs-three-things
description: "A new WmsConstants.FunctionEnum constant needs constant + Flyway row + a hand-written initDB grant line; omit the third and every NEWLY PROVISIONED tenant 403s that function forever, silently"
metadata:
  node_type: memory
  type: project
---

**Three things, not two.** Adding a `FunctionEnum` constant requires:

1. the constant in `WmsConstants.FunctionEnum` (`src/main/java/net/aim_ai/wms/service/WmsConstants.java:347`
   — a `public static final class` of Strings, **not** a Java enum);
2. a Flyway `mywms_function` row **plus grant** for already-provisioned tenants;
3. ⚠ **a hand-written line in `UtilRestController.initDB`** for tenants provisioned *later*.

Why (3) is easy to miss and expensive: `AccessService.updateFunctionList()` reflects over
`FunctionEnum` and creates the `mywms_function` **row**, but grants nothing. `initDB` enumerates
super-admin's grants as **77 individually hand-written `addFunctionToRole` lines**, and it builds its
own `super-admin` rather than the base dump's (id 585). So the migration grants one role and `initDB`
creates another without your line — and **every tenant provisioned from then on 403s that function for
everyone, permanently, with no menu change to signal it.**

Precedent that got it right: `WEB_UI_VIEW_PARCEL_PICKING` (SBDEV-2967-B) shipped all three. The repo
treats the divergence as a rule with its own test (`UtilRestControllerSeedUnitTest` C-8d). **Nothing
else in the suite catches the omission** — the only two tests reflecting over `FunctionEnum` check
annotation values and one hard-coded field name.

**The cheapest way to avoid all of this: don't mint a constant.** See
[[wms2-gate-a-route-on-its-screens-existing-function]] — SBDEV-3017 §9.16 Option B, which deletes the
migration and the `initDB` line together. Found on SBDEV-3154, where the plan had only (1) and (2).
