---
name: sbdev-2781-expected-return-date-date-only
description: "SBDEV-2781 Expected Return Date — ENTIRE complaint already fixed on origin/develop by two unlinked 2026-07-31 commits; plan was drafted against a checkout 11 commits stale"
metadata: 
  node_type: memory
  type: project
  originSessionId: f56e499d-ad64-4840-a17d-84d6f2f74d4e
  modified: 2026-08-05T14:47:13.353Z
---

**SBDEV-2781** (WMS v2, Returns / Inbound Notices) — "Expected Return Date wrong date + unnecessary
time". Plan drafted 2026-08-05:
`sbdocs/1-Projects/wms2/plan/SBDEV-2781-expected-return-date-stray-time-and-tz-shift.md`.

**The ticket is FULLY obsolete — its entire user-visible complaint is already fixed on `origin/develop`.**
Two unlinked commits from one 2026-07-31 session (the day AFTER the ticket was filed) close every AC:

- `dfe24f8` (wms2-api PR **#116**) — `ViewDtoService.toLocalDate()` on `dayofdelivery`/`dayofdeliveryuntil`
  at `:1028/:1031` → fixed the **date shift**.
- `e6ca85a` (wms2-web-ui) *"Show Expected (dayofdelivery) as date-only on inbound notice tables"* → dropped
  the stray `getTime` line from **all three** components (`openNotices.vue`, `closedNotices.vue`,
  `openNoticeReceiptTable.vue`) → fixed the **stray time**.

**Do not re-fix either.** Grep `origin/develop`, not the working tree, before concluding anything is open.

**PROCESS LANDMINE that cost this whole plan its primary deliverable:** `v2/wms2-web-ui`'s local `develop`
was **11 commits behind `origin/develop`**, so the §0 enumeration graded a stale tree and "Fix A" was
written for work already merged. Caught only at the TDD-gate step, when the fresh worktree off
`origin/develop` already contained the fixed template. **`git fetch` + `git log develop..origin/develop`
in EVERY affected repo before enumerating affected sites** — per-repo, because staleness varies (wms2-api
was 2 behind and its analysis survived; the UI was 11 behind and its headline finding did not). Same
discipline as [[flyway-version-pick-sweep-all-remote-branches]]: the local view is not the branch you
merge into.

Measured with the UI's own `moment-timezone` + `plugins/dateFormatter.js` `safeParse`:

| wire value | `$formatDateShort` | `$formatTimeOnly` |
|---|---|---|
| `"2026-07-31T00:00:00.000Z"` | `07/30/26` | `8:00:00 pm` ← the reporter's screenshot (ET) |
| `"2026-07-31"` | `07/31/26` | `12:00:00 am` ← today |

The same instant renders `5:00:00 pm` in LA — which is `dfe24f8`'s commit message, so **the two reports
are one bug on two tenants**. `advice.dayofdelivery` is a SQL `date`; all **2,216** RETURN advices carry
one (100% blast radius) while `dayofdeliveryuntil` is **0/2,216**, which is why only one field was ever
reported.

**LANDMINE — a service-layer fix cannot guard a Spring Data REST `@RestResource` query.** Three native
projections on `AdviceRepository` (`getDetailViewByKeyword` :47, `getOpenNoticesByKeyword` :68,
`getClosedNoticesByKeyword` :97) are HAL-exported under `@RepositoryRestResource(path="advice")`, so
`/v3/advice/search/*` serializes the raw `java.sql.Date` and re-emits the midnight-UTC instant #116
fixed. Their accessors are typed `Object`, so there is no type-level guard either. Same trap as
[[sbdev-1666-lane-replenish-source-exclusion-v2]]. **Zero consumers** verified across wms2-web-ui,
wms2-mobile-ui, omsv2-UI, both v1 UIs and `oms-laravel-api` → decision was `exported = false`, not a
second serialization path. The web UI reaches this data only via the controller
`GET /v3/advice/detailView` (`store/receiving/inboundNotices.js:135`/`:277`).

**Already correct — check before "fixing":** the notice-detail endpoint (`AdviceService:477` reads the
entity's `LocalDate`), both ingestion paths (`AdviceRestController:251` `LocalDate.parse`,
`ReceivingService:211`), and the Excel export (`FileExportService:255` has a dedicated `LocalDate` branch).
Guarded G1–G3 in the verify script.

**Enumerate by column type, not by symbol.** Grepping every `date`-typed column in the tenant schema (only
5 exist) surfaced two adjacent sites the symbol grep missed: `openNoticeReceiptTable.vue:78-80` has a
`dayofdelivery` slot that is **dead** (its `headers` array has no such column, so Vuetify never invokes
it — a live reintroduction trap), and `outboundBolDetails.vue:57` shows a stray time on
`billoflading.shipped`. `customerorder.pickingdate` was already fixed by SBDEV-2660.

**Anti-over-fix:** `closedNotices.vue:64-65` renders date+time for `item.modified`, which **is** a
`timestamptz` — that time is legitimate and must survive. Same for `outboundBol.created` at
`outboundBolDetails.vue:53`. Both pinned by verify checks and tests. This adjacency is why the bug passed
review: the broken cell looks exactly like its correct neighbour.

**MERGED 2026-08-05** — wms2-api PR #131 (merge `169065c`) + wms2-web-ui PR #38 (merge `743142e`) into
`develop`; ClickUp `on dev`. Re-verified on merged develop, not just the PR branches. Verify **28 pass / 0 fail / 0 skip**;
API 4686 tests / 2 pre-existing failures; Jest 69/69. Both review lanes APPROVE (0 critical, 0 high).
Follow-up filed for dead code: [868kmmxcq](https://app.clickup.com/t/868kmmxcq) — `adviceRepository.getDetailViewByKeyword`
has NO Java caller (six repos share that method name; `ViewDtoService`'s three calls are on unitload/stockunit/message),
so it + `AdviceDetailView` are dead once unexported. `exported = false` verified against SDR 4.5.7 source:
`RepositoryMethodResourceMapping:76` reads the flag directly, so it wins regardless of config; the 404 comes
from the mapping's ABSENCE, not an isExported() check.

Earlier verify baseline against `origin/develop`: **17 pass / 7 fail / 2 skip** (an earlier 15/11 graded the stale tree — void). Only Fix C (HAL unexport), Fix D (outbound BOL `shipped`) and Fix B (the dead slot `e6ca85a` left) remain, and none is the reported bug. See
[[verify-script-traps]] for the two template helper bugs found while capturing
it.

## Index-hook detail

Condensed status/landmine notes that previously lived in the `MEMORY.md` index line:

ENTIRE ticket already fixed on origin/develop by 2 unlinked 2026-07-31 commits (`dfe24f8` API date + `e6ca85a` UI stray time, all 3 components); PROCESS LANDMINE: local wms2-web-ui `develop` was 11 commits stale so the plan's primary fix was already merged — `git fetch` + diff `develop..origin/develop` PER REPO before enumerating §0; MERGED 2026-08-05 (api #131 `169065c`, ui #38 `743142e`, ClickUp `on dev`) — HAL unexport + outbound-BOL `shipped` + dead-slot removal; `item.modified`/`created` times are LEGITIMATE — don't strip them
