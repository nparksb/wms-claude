---
name: vue-mount-with-value-present-does-not-test-reactivity
description: Mounting a Vue component with the store value already set proves only that a render can read a field, never that it reacts to a later change
metadata:
  type: feedback
---

Measured on SBDEV-3031 (`wms2-web-ui`, 2026-08-29). A dialog was supposed to render a server error
that arrives **while it is already open**. Eight tests passed. Replacing the `computed` with

```js
data() { return { deleteError: this.$store.state.admin.role.deleteError } }
```

also passed **all eight**, while the alert never appeared at all — `role.vue` creates
`<delete-role-pop>` once, with no `:key`, when the tab mounts, at which point the value is `null`,
and `data()` runs once.

**Why:** every test used `shallowMount(..., {mocks: {$store: {state: {...value already set...}}}})`.
A frozen mock with the value already present cannot distinguish reactive from latched. It also isn't
reactive at all, so it could never observe a change.

**How to apply:** when the behaviour under test is "it updates when X changes", the test MUST mount
with the value ABSENT, then change it, then `await wrapper.vm.$nextTick()`. Use a real
`new Vuex.Store(...)` with `createLocalVue().use(Vuex)` — a plain object mock is not reactive.
Assert on a `data-test` attribute, not on the message wording: a negative keyed on wording is
satisfied by an always-visible alert reading something else (also measured green).

Related: [[vue-key-remount-does-not-reset-state-read-from-stale-parent-data]],
[[green-tests-that-prove-nothing]], [[wms2-web-ui-coverage-instrumentation-disarms-render-source-pins]].
