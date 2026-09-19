---
name: wms2-rest-surface-internal-only-jwt-deferred
description: /rest/** is internal-only WMS↔OMS and never internet-exposed; JWT protection is the decided mechanism but deferred by Nam (2026-08-27)
metadata: 
  node_type: memory
  type: project
  originSessionId: d6ec18aa-275e-4a06-b788-8c4e6c32da53
  modified: 2026-08-27T21:26:27.063Z
---

**Nam, 2026-08-27, on SBDEV-3124:** all WMS `/rest/**` services are **internal-only between WMS and
OMS and are never exposed to the internet**. Mechanism for eventually protecting them is decided —
**Keycloak JWT, "as other services"** — but the work is **deferred**; Nam will drive it with the OMS
team later. SBDEV-3124 set to **high / blocked** (was urgent / Open).

**REAFFIRMED 2026-09-02** (on SBDEV-3198 AC13, unprompted): *"As for `/rest/stockcount/triggerStockCount`
leave it as is. All the services under `/rest/**` are the services called by OMS directly through
internal channel. We will gate them after set up a plan with OMS team."* So the gating is blocked on an
**OMS-team plan**, not on WMS work — do not propose the WMS half of it as ready-to-ship, and do not
carve individual `/rest` routes out of the deferral because a `/v3` sibling is being gated.

**Consequence for gating tickets — this is the reusable part.** A `/v3` route whose capability also has
a `/rest` twin cannot be closed by gating the `/v3` copy: that is **cosmetic**, and saying so is not an
argument for leaving the `/v3` copy open, only for not claiming the capability is closed. Worked example,
`stockSummaryExportJob`, verified 2026-09-02: `GET /v3/adminAction/triggerUpdateStock` (needs `wms_user`)
and `GET /rest/stockcount/triggerStockCount` (`permitAll`) reach the same job, and **OMS calls the `/rest`
one** (`WmsApiService.php:2554`, `config/wms.php:79` → `rest/stockcount/triggerStockCount`). SBDEV-3154
left the `/v3` copy ungated on exactly this reasoning.

**Why:** the missing auth is real but it is **defence-in-depth, not a live exposure**. Without the
topology fact, `/rest/**` reads as the widest attack surface in the codebase and gets escalated to the
top of the queue — which is exactly what I did before asking. Do not re-escalate it on code evidence
alone; the deciding fact is not in the repo.

**How to apply:** treat `/rest/**` findings as non-urgent hardening. Never ship the WMS half first —
`/rest/**` → `authenticated()` (`SecurityConfiguration:150-154`) plus
`app.idempotency.require-auth=true` (`application.properties:167`) must land in one release, *after*
OMS sends tokens, or facility sync / advice creation / SKU sync break silently.

Code facts that survive the deferral (all measured on `origin/develop`, 2026-08-27):

- A 401 gate already exists and is switched off: `IdempotencyFilter:196-203` defaults
  `require-auth` to **true**; `application.properties:167` sets it **false**. Flipping it does *not*
  cover `/rest/stockcount/**`, which `shouldNotFilter` skips.
- **OMS hard-skips auth for `#/rest/#i`** in `WmsApiService::applyAuthentication` before reading any
  config, and has **no Keycloak client-credentials flow**; its `token` type applies a *static* bearer,
  which `MultiTenantJwtDecoder` rejects. So "set `WMS_AUTH_TYPE=token`" is not the fix.
- Real surface is **8 routing classes / 16 non-GET / ~13 mutating / 3 unauthenticated GET reads** — the
  ticket's "15 writes across 6 controllers" is wrong in both directions. `UtilRestController` is
  `@Service` and does not route (see [[wms2-utilrestcontroller-is-service-not-restcontroller]]).
- `IdempotencyFilter:161` skips `/rest/transactionreport/`, which **matches nothing** — the mapping is
  `/rest/report`. Read-only report POSTs are idempotency-enrolled against intent. Separate T1, not
  covered by the security deferral.
- Probing `/rest/**` on dev from a developer workstation returns application-layer responses, so the
  internal-only guarantee is a **prd** statement; dev is reachable from a dev machine.

⚠ `OPTIONS`/`Allow` is not evidence of reachability here — use method-mismatch (405) and unmapped-path
(404) probes, with a `GET /v3/...` 401 control. See
[[advertised-capability-is-not-exploitable-capability]] and [[sdr-write-verb-probes-400-proves-nothing]].

Related: [[wms2-gating-programme-is-live-on-prd]],
[[deploy-only-to-develop-release-and-main-are-devops]].
