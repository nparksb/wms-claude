---
name: wms2-web-ui-layout-resets-section-list-state
description: "wms2-web-ui's layouts/default.vue clears a section's list search+pagination when you navigate OUT of that top-level section — a \"revisit keeps state\" test must leave within the section or reload"
metadata:
  node_type: memory
  type: reference
  originSessionId: 378cf975-3e59-4df4-8f36-95ca7c256f44
  modified: 2026-10-30T11:52:19.359Z
---

`layouts/default.vue` (route watcher, `fromMainRoute !== toMainRoute` switch) resets the persisted list state of
the section you are leaving: e.g. leaving `/receiving/*` commits `resetInboundOpen/Closed` and
`resetPaginationOpen/Closed` and removes `wms-receiving-*-notices` from localStorage; `internalOps`, `dashboard`
etc. have their own cases.

So a browser test of "the list keeps its saved search/page when I come back" FAILS if it leaves to `/` — the
state is gone before the list remounts, which reads like a regression. Measured 2026-10-30 on SBDEV-3949's dev
test: S2 failed with store `{search:'', page:1}` until the exit route stayed inside the section
(`/receiving/closedNotice/<id>`) or used a full reload (vuex-persistedstate restores it).

Recipe and login: [[wms2-web-ui-headless-browser-recipe]], [[wms2-dev-ui-test-credential-panderson]].
