---
title: "WMSv2: the Web UI has no authorization layer — index of the 3-slice split"
ticket: "SBDEV-2967"
ticket_url: "https://app.clickup.com/t/868krr3rq"
type: "bugfix"
priority: "high"
status: "SPLIT 2026-08-21 into slices A / B / C. As of 2026-08-22: A and B both MERGED + DEPLOYED to dev; C not started plus a hand-off to SBDEV-3013. This file is now an INDEX — it carries no implementation detail. Run sbdocs/9-System/scripts/plan-state.sh against each slice, not against this file."
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-16
updated: 2026-08-22
db_verified: true
related:
  - SBDEV-2967-A-axios-403-denial-not-logout.md
  - SBDEV-2967-B-web-view-gating.md
  - SBDEV-2967-C-web-action-gating.md
  - ../../../4-Archieves/wms2/plan/SBDEV-3013-role-function-write-surface-gating.md
  - SBDEV-2968-mobile-ui-function-gating-enforcement.md
  - ../../../3-Resources/architecture/wms2-keycloak-role-matrix.md
tags:
  - plan
  - security
  - authorization
  - index
---

# SBDEV-2967 — index

**Ticket:** [SBDEV-2967](https://app.clickup.com/t/868krr3rq) · ClickUp status `in development`
**This document is an index.** All evidence, design and acceptance criteria live in the slice documents.

---

## Why this was split (2026-08-21)

The pre-split document was 735 lines covering two repos, three deploy steps and four independent workstreams.
Line count was not the problem. Two structural ones were:

1. **One gate blocked four workstreams, and only two needed it.** Brent's §3.6 grant sign-off sat on the
   critical path of the whole document — including the axios fix (one file, no data dependency) and the
   self-escalation gate, which uses a function that is already correctly held and needs no migration at all.
2. **View gating and action gating have opposite failure modes and a deploy-order constraint between them**
   (UI before API gates) that a single plan and a single PR cannot honour. A hidden menu item is loud and
   revertible; a 403 on a visible button is silent — and until the axios fix lands it logs the operator out.

A third finding forced the issue: the pre-split §3.5 carried a heading *"REVERSED at architect review — the
gates go on the CONTROLLER"* and, four paragraphs below it, the instruction *"at the entry of the service
method… **Not** `@RequiresFunction`."* The test plan, a risk row and **8 of the verify script's 50 rows**
encoded the superseded half — including one row that would **fail a correct implementation**. That is
resolved in slice C §2.1.

---

## The slices

| Slice | Scope | Repos | Blocked on | Tier | Doc |
|---|---|---|---|---|---|
| **A** | An authorization 403 logs the operator out — `plugins/axios.js` | web-ui, 1 file | ✅ **MERGED + DEPLOYED + e2e VERIFIED** ([#70](https://github.com/SiteBossInc/wms2-web-ui/pull/70), `46dd072`) | T2 | [SBDEV-2967-A](SBDEV-2967-A-axios-403-denial-not-logout.md) |
| **B** | View gating: menu filter, route guard, `WEB_UI_LOG_IN`, admin tabs, VIEW grants | web-ui + api | ✅ **MERGED + DEPLOYED to dev 2026-08-22** — api [#183](https://github.com/SiteBossInc/wms2-api/pull/183) `d70204c` merged FIRST, then web-ui [#72](https://github.com/SiteBossInc/wms2-web-ui/pull/72) `d07ed87`. V2.2.19 applied `success=true` on `dev_wh01_om1`; grants 305→330, functions 81→82. P13 ✅ discharged. 🔴 **P9 open for UAT/PRD only** — `60aef02` is on `origin/develop` (so provably in the dev image) and on `origin/release` `41cbe77` (v2.0.130), but NOT on `origin/main` `cf430ff` (v2.0.128) | T3 | [SBDEV-2967-B](SBDEV-2967-B-web-view-gating.md) |
| **C** | Action gating: 13 endpoints + ACTION grants + disabled controls | api + web-ui | ✅ **UNBLOCKED + plan REVIEWED/CORRECTED 2026-08-22** against `d70204c` (§0.G — surface re-confirmed, 5 findings, **AC C-6 struck as unachievable**, migration is now **V2.2.20**). P4 discharged for WineCo dev, **open for Hydra UAT + prd**; P5/P7 implementation-time. Implementation NOT started | T3 | [SBDEV-2967-C](SBDEV-2967-C-web-action-gating.md) |
| **→ 3013** | The self-escalation hole — moved out of this ticket | api | ✅ door ② **MERGED + DEPLOYED + VERIFIED** ([#179](https://github.com/SiteBossInc/wms2-api/pull/179), `808819d`); ✅ door ① **MERGED 2026-08-21** ([#181](https://github.com/SiteBossInc/wms2-api/pull/181), `ae5ec98` — *withdraw the SDR write verbs on the role-function join table*), deploy/e2e not yet confirmed | T2/T3 | [SBDEV-3013](../../../4-Archieves/wms2/plan/SBDEV-3013-role-function-write-surface-gating.md) |

### What moved to SBDEV-3013, and why

The pre-split "Scope addition requested 2026-08-19" section proposed gating
`POST /v3/userRole/saveRoleFunctions` and `POST /v3/userGroup/saveGroupRoles`. That is **one of three doors
on a single privilege-escalation path**; SBDEV-3013 already owned the other two (the Spring Data REST
surfaces), and its own text designated 2967 as the owner of this half. Splitting one escalation across two
owners means it is closed in two passes and exploitable in between — so **3013 was widened to own all three
doors** and the controller half moved there.

It also freed the work from a sign-off it never needed: the gate uses `WEB_UI_VIEW_USER_MANAGEMENT`, which is
already held by `super-admin` only. **No grant migration, no Brent decision.**

Re-enumerating during the move **corrected the endpoint count from 2 to 6** — both controllers are entirely
ungated, and gating only the two named endpoints would have left the escalation intact via step 1
(`POST /v3/userRole/create`).

~~**While SBDEV-3013 is open, every gate SBDEV-2968 shipped and every gate this ticket will ship is bypassable
in three requests.** It is unblocked and it should go first.~~ ✅ **Both doors are now merged** — ② as
`808819d` and ① as `ae5ec98` — so the escalation path is closed in code. Deployment of door ① is not yet
confirmed, so treat the bypass as closed on `develop` and open in whatever is currently running.

---

## Recommended order

```
SBDEV-3013 door ②   ─┐  unblocked today; closes the escalation that defeats everything else
SBDEV-2967-A        ─┤  unblocked today; one file; hard prerequisite for C
                     │
     ── Brent signs off the VIEW and ACTION grant tables (P2) ──
                     │
SBDEV-2967-B        ─┤  grants migration → web-ui image
SBDEV-2967-C        ─┘  grants migration → web-ui controls → api gates   (needs A deployed)
                     │
SBDEV-3013 door ①   ─┘  published-API change, own review
```

**A and 3013-② are parallel and need nothing from anyone.** B and C both wait on P2 and are independent of
each other.

---

## What is NOT in any slice

| Concern | Owner |
|---|---|
| Server-side **view** gating for the web UI — ~14 of ~32 API roots are SDR-only and structurally unreachable by `FunctionGuardInterceptor` | **[SBDEV-3017](https://app.clickup.com/t/868kufdy1)** |
| The delete constants written into the audit trail as the `comment` argument (478 rows on WineCo dev) | **[SBDEV-2979](https://app.clickup.com/t/868kt336b)** |
| Non-atomic delete-then-insert in `saveRoleFunctions` / `saveGroupRoles` | **[SBDEV-3012](https://app.clickup.com/t/868kua93r)** |
| The 7 `WEB_UI_VIEW_*` constants with no page — retire or leave | unfiled; slice B §7.3 |
| `deleteContainerRecursive` and two user-admin deletes being `GET` | unfiled; recorded in slice C §0.C and 3013 §0.1 |
| `PRINT_TOTE_LABELS` — 4 write endpoints across 3 controllers, no existing consumer | deferred as **tranche C2**, slice C §0.F |

---

## State

Do not read state out of this file or the slices' `status:` prose. Run:

```
sbdocs/9-System/scripts/plan-state.sh SBDEV-2967
```

As of the split, nothing was implemented. **Superseded 2026-08-22:** slice A shipped 2026-08-21 (`46dd072`) and slice B
shipped 2026-08-22 (api `d70204c`, web-ui `d07ed87`), both deployed to WineCo dev. Slice C remains unstarted.

⚠️ `plan-state.sh SBDEV-2967` under-reports this ticket: it grades only the FIRST of the 5 candidate docs, and it reports
"no worktree" because the worktrees are named `SBDEV-2967-B`, not `SBDEV-2967`. Run it against each slice document.

**P1 is cleared.** SBDEV-2968 merged 2026-08-21 (PR #178, merge `5506117`) and is deployed to dev. Verified
on `develop`: `security/RequiresFunction.java`, `security/FunctionGuardInterceptor.java`,
`security/FunctionGuardStartupAssertion.java`, `FunctionGuardArchTest`, `AccessService.checkAnyAccess` /
`doesUserHaveAnyAccess`, `Authority.AUTHZ_DENIED_HEADER` (`:99`) with CORS exposure
(`SecurityConfiguration:193-194`). Flyway head is **V2.2.18**.

The pre-split document is preserved verbatim at
`sbdocs/4-Archieves/wms2/plan/SBDEV-2967-presplit-2026-08-21.md`.
