---
name: wms2-admincontroller-is-a-base-class-for-43-controllers
description: "wms2-api AdminController is extended by 43 controllers, so each of its endpoints is registered under all 43 class-level prefixes — every controller endpoint inventory built by grepping mappings is understated"
metadata: 
  node_type: memory
  type: project
  originSessionId: d594027c-8456-4059-886b-9bb9c11c997b
  modified: 2026-08-17T19:20:19.149Z
---

`v2/wms2-api` `AdminController` is not just a controller — **43 other controllers extend it**, and every one declares its own class-level `@RequestMapping`. That is what stops Spring failing on ambiguous mappings, and it means each of `AdminController`'s mapped methods is **re-registered under all 43 prefixes**:

```
/v3/user/isWarehouseUser            <- the only one the UI calls
/v3/picking/user/isWarehouseUser    <- PickingController   @RequestMapping("/v3/picking")
/v3/report/user/existsInKeycloak    <- ReportController    @RequestMapping("/v3/report")
                                       ... x43
```

Discovered 2026-08-17 during SBDEV-2870: four "ungated endpoints" were actually reachable on **176 paths**. Fixed by extracting them into `UserAdministrationController`, which removed 172 registrations.

**Why:** a grep for `@RequestMapping`/`@GetMapping` counts *declarations*, not *registrations*. Any endpoint inventory built that way undercounts every `AdminController`-inherited mapping. The counts in [[sbdev-2967-and-2968-endpoint-inventories-understated]] territory (SBDEV-2967 §0.B, SBDEV-2968's 66-endpoint figure) are wrong for this reason.

**How to apply:**
- Verifying all 43 prefixes are **distinct** is the falsification test — if two shared one, inherited registration would ambiguous-map and the app could not boot. They are distinct, which is consistent with (not proof of) per-subclass registration.
- A method-level guard IS inherited too, so gating designs stay correct; only the counts are wrong.
- SBDEV-2968 makes a reflection-built golden map a blocking prerequisite — it must enumerate **inherited** mappings (`getMethods()`, not `getDeclaredMethods()`) or it silently misses them.
- Adding a constructor arg to `AdminController` ripples through all 43 subclasses and their tests. Prefer extracting endpoints into a new leaf controller.

Related: [[wms2-controller-mappings-must-carry-v3-standalonesetup-cannot-see-it]], [[wms2-only-one-of-80-functions-is-enforced]]
