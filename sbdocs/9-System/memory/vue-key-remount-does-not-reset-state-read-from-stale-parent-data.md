---
name: vue-key-remount-does-not-reset-state-read-from-stale-parent-data
description: "A :key remount only resets child state if the PARENT's data is also cleared — async reloads leave stale rows the fresh child latches onto"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 5648b9f8-6d4b-4383-bc62-815e0c926d5f
  modified: 2026-08-13T21:03:40.762Z
---

Found on SBDEV-2947 (`v2/wms2-web-ui`), 2026-08-13, after a code review caught a fix that looked
obviously correct and was not.

**The pattern.** A child component derives local state from a prop on mount (`immediate: true` watcher,
or `data()` seeded from props). To stop that state leaking between subjects, add
`:key="${scope}-${subjectId}"` so the child remounts. **This is not sufficient**, and the reasoning that
says it is has every link true:

> the key changes → Vue destroys and recreates the child → its local state restarts at the default →
> the watcher re-decides from the new subject's data

The false step is the last one. In Vue 2 the parent's `subjectId` **user watcher runs before the render
watcher**, and the reload it triggers is **async**. So the child remounts while the parent still holds
the *previous* subject's rows, and the fresh instance decides from stale data. If the child's watcher is
one-way (opens but never closes), the correct data arriving a tick later cannot undo it.

**The fix is two-part** — the key AND clearing the parent's arrays in the same reset method, before the
async load:

```js
resetForSubject() {
  this.allRows = []
  this.eligibleItems = []   // <- without this, the remounted child latches on the old subject's rows
  this.loadEligible()       // async
}
```

Ablation is the only honest check: remove either half and the defect returns.

⚠⚠ **The test written for the key-only attempt could not have caught this**, and that is the reusable
half of the lesson. It asserted `wrapper.findComponent(Child).vm.$vnode.key` under **`shallowMount`** —
where the child is a STUB, so its state is not observable at all. It was green on a branch where the
property was false. **Assert the behaviour with a real `mount()`** (`child.vm.<state>` after driving the
subject change), not the mechanism. A verify-script row grepping the *test's name* inherits the same
blindness — see [[verify-script-traps]] and
[[idle-review-subagent-is-not-a-passing-review]].

**How to apply:** whenever a `:key` is added to reset child state, ask what the parent still holds at
the moment of remount, and ablation-test both halves. Related:
[[sbdev-2947-putaway-picker-tier-vs-eligibility-axis-mismatch]],
[[sbdev-2930-mobile-page-reset-and-picking-timer-landmine]] (the sibling "a `mounted()` reset cannot be
detected by asserting `state.process`" trap — same shape, different mechanism).
