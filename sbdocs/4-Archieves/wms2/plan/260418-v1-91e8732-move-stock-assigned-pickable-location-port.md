---
title: "V1 91e8732 Port — Move Stock: Assigned Pickable Location Fix"
ticket: ""
ticket_url: ""
type: migration
priority: Urgent
status: Implemented
project: [wms2-mobile-ui]
version: v2
requester: ""
created: 2026-04-18
updated: 2026-04-18
related:
  - v1/wms-mobile-ui@91e8732eaf7693b83035855a47e1a196255bd8d4
tags:
  - plan
  - migration
  - v2
  - mobile-ui
  - hotfix
---

# V1 91e8732 Port — Move Stock: Assigned Pickable Location Fix

**V1 source:** `wms-mobile-ui` commit `91e8732eaf7693b83035855a47e1a196255bd8d4` (Release 1.26.12, 2026-04-15)
**V2 target:** `wms2-mobile-ui`
**Ported:** 2026-04-18

---

## 1. Summary

Hot fix originally shipped to v1 mobile UI as Release 1.26.12. Both v1 and v2 mobile UIs are on Nuxt 2 / Vue 2 / Vuetify 2, so the v1 diff ports nearly verbatim after verifying current v2 state.

| V1 File | V2 Verdict | Rationale |
|---|---|---|
| `components/moveStock/inputAmount.vue` | **Needed** — applied | V2 matched v1 pre-patch state exactly |
| `components/moveStock/scanDestination.vue` | **Not needed** | V2 already has "Assigned Pickable Location" label |
| `store/moveStock.js` | **Needed** — applied | V2 matched v1 pre-patch state exactly |

---

## 2. Bug Explanation

The `moveStock/selectStockUnit` Vuex action caught backend errors and displayed a toast, but its promise still resolved successfully. The caller in `components/moveStock/inputAmount.vue:submit()` awaited the action without inspecting the outcome and then unconditionally committed `setAmount` and `setProcess('3_destination')` — advancing the wizard even when the backend had rejected the stock unit.

On the destination screen (`scanDestination.vue`), `stock.existingLocation` (the "Assigned Pickable Location" field) was therefore empty because `setStock` had never been committed in the failure branch.

---

## 3. Fix Applied

### 3.1 `store/moveStock.js` — action returns success/failure

- `selectStockUnit` now returns `true` on happy path, `false` on backend-reported errors, and `false` on caught exceptions.
- Removed the internal `context.commit('setProcess', '3_destination')` — step transition is now the caller's responsibility, which matches the rest of the action surface.

### 3.2 `components/moveStock/inputAmount.vue` — caller checks the return value

- `submit()` captures `const success = await this.$store.dispatch('moveStock/selectStockUnit', data);`
- Early-returns with `if (!success) return;` before committing `setAmount` / `setProcess('3_destination')`.

Net effect: the wizard no longer advances past step `2_inputAmount` when the backend rejects the stock unit.

---

## 4. Verification

- v2 `git diff` after port matches v1 commit `91e8732`'s diff byte-for-byte on both files.
- `scanDestination.vue` label fix was already present in v2 (no action taken).
- **Not manually tested** — requires mobile UI dev server and scanner flow; left to QA.

---

## 5. Files NOT Touched

- `components/moveStock/scanDestination.vue` — v2 already contains the `"Assigned Pickable Location: "` label (presumably carried over from an earlier port or independent implementation).

---

## 6. References

- V1 commit: `91e8732eaf7693b83035855a47e1a196255bd8d4`
- V1 release tag: `1.26.12` (2026-04-15)
- Original author: Nam Park
