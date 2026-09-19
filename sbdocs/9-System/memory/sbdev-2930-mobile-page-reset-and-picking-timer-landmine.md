---
name: sbdev-2930-mobile-page-reset-and-picking-timer-landmine
description: "SBDEV-2930 wms2-mobile-ui per-page Vuex reset — MERGED but archive-gated on manual QA; LANDMINE picking.timer is a live setInterval handle in the persisted blob, so clearInterval(state.timer) can kill Keycloak's token refresh"
metadata: 
  node_type: memory
  type: project
  originSessionId: 8f9352cc-3247-48eb-8ea6-f37d68a1fbd3
  modified: 2026-08-12T15:35:36.428Z
---

**SBDEV-2930** (`v2/wms2-mobile-ui`): shared handhelds resumed the previous operator's in-flight job, because
the whole Vuex root state persists to `localStorage['vuex-mobile']` and workflow pages render off the
rehydrated `process` marker. Fixed by a factory-rebuilt `resetState` on all 11 workflow modules + a
`created()` call on all 11 pages. **MERGED 2026-08-12** — PR #32, merge `98eae72`, ClickUp `on dev`.

**⚠ NOT ARCHIVED, deliberately.** Plan §15 carries an archive checklist blocked on two §8.4 manual rows (M1
shift-handover, M10 rapid-pick timer). Reason: this defect has **no telemetry surface**, so manual QA is the
only compensating control, and M10 is the sole runtime check on the Medium below. The verify script and the
`.claude/worktrees/wms2-mobile-ui/SBDEV-2930` worktree are held live for that reason. Don't let
`archive-plan` close it out until those are ticked or explicitly waived in writing.

## LANDMINE 1 — `store/picking.js` `timer` is a live `setInterval` handle, and it is PERSISTED

`setTimeOut` does `context.commit('setTimer', setInterval(...))`, so `state.timer` is an interval id, not
data — and the reducer excludes only 3 root keys, so it rides the blob to localStorage.

**`clearInterval(state.timer)` is therefore dangerous, not a safe cleanup.** Each page load gets a fresh
`Window` with its own timer-id counter restarting at 1, so a rehydrated handle is a small integer naming
whatever timer took that slot in the NEW load. `plugins/keycloak.client.js:320` creates the token-refresh
interval during boot and so holds one of the lowest ids — clearing a rehydrated handle can **silently stop
token refresh and log an operator out mid-shift**. Correct pattern: track the handle created in *this* page
load in a module-scoped `let liveTimer` **outside Vuex** (so it can never be persisted) and clear only that.

**Second-order trap:** nulling `timer` without clearing is also wrong. There is no `beforeDestroy` anywhere
under `components/picking/`, and `scanSource.vue`'s `if (!this.timer)` guard was accidentally self-healing —
a truthy stale handle stopped a second interval starting. Null it and re-entry runs TWO intervals, `count`
decrements 2×/sec, the `count < 0` watcher fires early and calls `passScan()` — **auto-passing a pick
position**. Derived from the call graph, never reproduced live; M10 is the only real check.

## LANDMINE 2 — a `mounted()` reset does not work in Vue 2, and `state.process` cannot detect that

Children are created, mounted and painted **before** the parent's `mounted()`. So a `mounted()` reset sets
`process` correctly *and* still renders the stale sub-screen, and the child's own hooks fire against the
previous operator's data (`components/picking/pick.vue` `mounted()` commits two mutations advancing their
position). Any test asserting only `store.state.<mod>.process` **passes on all five pre-fix `mounted()`
pages** — it reports them fixed. Assert on the rendered component (`findComponent(...).exists()`).

## Other traps found

- **Four** `.vue` files use optional chaining **inside their `<template>`**, which `vue-jest@3.0.7` cannot
  compile; importing them kills the whole suite. `jest.mock` them. A scan bounded with
  `awk '/<template>/,/<\/template>/'` finds only three — it stops at the first closing tag, and
  `pages/replenish.vue` opens with nested `<template v-if>`. Bound on the LAST `</template>`.
- `pages/replenish-request.vue` shares the `replenish` module with `replenish.vue` (two entry screens, one
  module) and carries a stray `rapidPalletScan` computed reading `state.palletizing` — a test store
  registering only `replenish` throws before any assertion.
- v1 counterpart is **SBDEV-2932**, and worse: `createPersistedState()` with no key and no reducer, i.e. the
  default `vuex` key from [[sbdev-2726-shared-vuex-blob-facility-code]].

Related: [[verify-script-traps]],
[[negative-test-verify-scripts-before-trusting-them]], [[run-wms2-mobile-ui-jest-tests]],
[[feedback_plan_status_after_implementation]]
