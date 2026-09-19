---
name: sbdev-3154-admin-action-console-gating
description: "SBDEV-3154 gated 6 AdminActionController routes on the EXISTING WEB_UI_VIEW_IMPORT_DATA — MERGED on dev ad681319; zero constants, no migration, T3->T2; finishStuckPickingOrder was a HIGH ungated OMS-notifying route"
metadata:
  node_type: memory
  type: project
---

**SBDEV-3154 — MERGED `on dev` 2026-09-01, merge commit `ad681319`, PR #259.** Verified on
`origin/develop` after the merge: 6 annotations on the intended methods, no class-level annotation,
`AdminActionController` still out of `GUARDED`, `accessAudit` untouched, pin at 131. Six `AdminActionController` routes gated on the **existing**
`WmsConstants.FunctionEnum.WEB_UI_VIEW_IMPORT_DATA`: `recoverStuckPallets`, `triggerOrderReplenish`,
`triggerArchiveMessages`, `testCrmConnectivity`, `listRecoverableStuckPallets`,
`finishStuckPickingOrder`. **Zero new constants, no Flyway migration**, T2 — the ticket's own title
asked for two constants and `V2.2.22`, and needed neither. See
[[wms2-gate-a-route-on-its-screens-existing-function]].

**The find worth remembering: `GET /v3/adminAction/finishStuckPickingOrder/{number}` was ungated and
callable by ANY `wms_user`.** It flips the linked `Customerorder` to `PICKED`/`PENDING`, transfers
totes, returns positions to the pool, and **enqueues a `PICKING_FINISHED` outbox notification to
OMS** — the damage leaves WMS. It had **no `/rest/**` twin** and **zero UI callers**, which is why it
was more dangerous than four of the five routes the ticket did name, and why the cosmetic-gating
argument that legitimately spares `triggerUpdateStock` (`/rest/stockcount/triggerStockCount` under
`permitAll()`) does not transfer. Exploit needed only `GET /v3/pickingorder?size=1000`, an ungated
SDR read, to find a `number` at state 500.

**Still open on that controller, deliberately:** `triggerUpdateStock` (cosmetic to gate while the
`/rest` twin exists), `triggerReleaseExpiredPickingOrdersFromUser` (not in SBDEV-3017 §1).
`accessAudit` keeps `@PreAuthorize(IS_SB_ADMIN)`. **Never annotate `AdminController`** — base class
of **43** controllers.

**Not closed, do not over-read the PR:** `testCrmConnectivity` is not SSRF-closed (URL is a sysprop
and `HttpRestService.applyHeaders` attaches the **OMS Basic-Auth credential**, so a rewritten URL
exfiltrates it); `listRecoverableStuckPallets` closes the triage, not the data (rows readable via two
ungated SDR GETs); per-item replenishment stays unfenced via `triggerReplenishmentMaintenance`.

**Deployment note.** No migration, so the merge deployed code only. On `dev_wh01_om1` the gate
narrows the reachable population from **100 `mywms_user` rows to 37**; on the other five tenants the
holders already equal the `super-admin` population, so 0 users lose access anywhere. ⚠ **THIS TICKET is not on prd** — `ad681319` is not an
ancestor of `origin/main` (checked 2026-09-01). But do not generalise that to the programme: the earlier
claim here, "the whole authz programme remains develop-only", is **false as of the v2.0.137 release**.
`FunctionGuardInterceptor` ships at tag `v0.0.21`, the build running on prd, and `origin/main` carries
**161** `@RequiresFunction` sites against develop's 177 — so most gating IS in production and only the
recent tickets are not. See [[wms2-gating-programme-is-live-on-prd]].
