---
name: wms2-gate-a-route-on-its-screens-existing-function
description: "SBDEV-3017 §9.16 Option B (Nam): a route gates on the function that already gates the screen it is dispatched from — ZERO new constants, no migration, T3 drops to T2. WEB_UI_VIEW_* names a SCREEN, not read-only-ness"
metadata:
  node_type: memory
  type: feedback
---

**The standing rule for gating an MVC route** (SBDEV-3017 **§9.16**, Nam 2026-08-27, reaffirmed on
SBDEV-3154 2026-09-01): *"each site takes the function that already gates the screen it is reached
from. No new constant is created."* §9.17.1 traced the consequence — the Flyway migration disappears
and **the tier drops T3 → T2**.

**`WEB_UI_VIEW_*` names a SCREEN, not read-only-ness.** Using one to gate a *write* or a mutating GET
is **within** the convention — §9.16.2 says so explicitly, verified by a review lane, and
`appMenuList.js` proves it (`'WEB_UI_VIEW_CLIENT', // Shippers`). Precedents: §9.15 decision 4 sent
`ItemDataController:105` onto `WEB_UI_VIEW_ITEM_DATA`; R6 gated `ShipperIdController` on
`WEB_UI_VIEW_CLIENT`. ⚠ **Do not "correct" this to an ACTION_ constant** — I raised exactly that
objection on SBDEV-3154, put it to Nam as a question, and it was already settled the other way. Read
the parent plan's decision log before proposing a naming change.

**Why it is usually free:** on SBDEV-3154 the screen function `WEB_UI_VIEW_IMPORT_DATA` was held by
*exactly* the population a new constant granted to `super-admin` would have reached — 37/35/7/15/23/9,
difference **0 on all six tenants including PRD**. So the migration would have changed the reachable
set by nobody. **Measure that before minting**: `mywms_function` → `mywms_role_mywms_function` →
`mywms_group_mywms_role` → `mywms_group_mywms_user`, counted by USER population (direct
`mywms_user_mywms_role` confers nothing in v2).

**Second-order win:** the gate becomes exactly the screen's gate, so AC-2′ holds trivially and no
button can 403 for someone who can see the tab. Vue consoles here do **no** per-button function check
(`components/admin/systemManagement/actions.vue`), so a *different* function is what creates
visible-but-403 buttons. Related: [[wms2-adding-a-function-constant-needs-three-things]].
