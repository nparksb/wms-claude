---
title: "Hydra UAT — Triage of Three Failed QA Flows (Pick & Pack, Club Line Palletize, Transfer Offsite)"
type: investigation
status: concluded
project: [wms2]
version: v2
scope: "v2/wms2-api + wms2-mobile-ui + wms2-web-ui — order release, mobile palletizing, transfer-order intake, as configured on Hydra UAT (wh01_hydra_v2)"
requester: nam.park@siteboss.net
reporter: "Ibrar (QA)"
owner: "Nam Park"
tickets_filed: [SBDEV-2961, SBDEV-2962, SBDEV-2963]
created: 2026-08-14
updated: 2026-08-14
last_verified: 2026-08-14
verified_by: "Nam Park — live SQL against Hydra UAT (wh01_hydra_v2, Flyway head 2.2.16) + static read of v2/wms2-api @ docs/wms2-plan-reconcile-2732-corrections. Root cause #1 proven by differential re-run of the production release query; #2 proven by sysprop pattern + absence of any Pallet unit load on the test date; #3 proven by the inbound REST idempotency ledger."
related:
  - "[[wms2-picking-workflow]]"
  - "[[wms2-club-run-workflow]]"
  - "[[wms2-transfer-order-workflow]]"
  - "[[wms2-scheduled-jobs-catalog]]"
  - "[[wms2-sysprop-catalog]]"
  - ./260628-oms-v2-future-picking-date-and-order-release.md
tags:
  - investigation
  - report
  - wms2
  - uat
  - qa
  - order-release
  - palletizing
  - transfer-order
  - configuration
---

# Hydra UAT — Triage of Three Failed QA Flows

**Reported by:** Ibrar (QA), against **Hydra UAT** | **Test date:** 2026-08-12 | **Triaged:** 2026-08-14
**Environment:** tenant `hydra` / facility `NYWH` → DB `wh01_hydra_v2`, Flyway head `2.2.16`

> **This is a point-in-time triage, not a reference.** Two of the three findings are *live UAT data/config
> state* that an operator can change at any moment. Re-verify against the DB before acting on an old copy.

**Reported symptoms, verbatim:**

1. *Pick & Pack Order:* created a Pick & Pack batch, received it under Outbound → Pick & Pack, but the system is not generating the picking orders.
2. *Club Line Order:* palletizing the Club Line order shows the error **"String is not valid."**
3. *Transfer Offsite Order:* created a Transfer Offsite order, but it is not showing in the **Ready** tab.

---

## 0. Overall verdict

| # | Flow | Verdict | Root cause | Owner |
|---|---|---|---|---|
| 1 | Pick & Pack — no picking orders | ✅ **Root cause proven** | Test client has **no Section** assigned → order-release SQL excludes it | UAT config (+ 1 real product bug) |
| 2 | Club Line palletize — "String is not valid" | ✅ **Explained** | Scanned pallet label doesn't match Hydra's configured label patterns | Operator/config (+ 1 real UX bug) |
| 3 | Transfer Offsite — not in Ready tab | ⚠️ **Not a WMS defect (as far as WMS can see)** | No transfer order ever reached WMS; and **no "Ready" tab exists in the WMS UI** | OMS side — needs more input |

**Neither #1 nor #2 requires a code change to unblock QA.** Both are Hydra UAT configuration/data.
Two genuine product defects were found *alongside* them, both about **silent/unhelpful failure** rather than
wrong behaviour — filed separately (§4).

**Ruled out early:** the cron lane is **not** dead. `StockSummaryExportJob` (`INVENTORY_FULL_EXPORT`) ran at
`2026-08-14 00:03 UTC`, and unrelated orders are actively advancing to state 50. All order-release sysprops are
correctly enabled (§1.3). This matters because "cron is off on this environment" is the usual explanation for
"nothing is being released" — see [260628-oms-v2-future-picking-date-and-order-release.md](./260628-oms-v2-future-picking-date-and-order-release.md) — and it is **not** the explanation here.

---

## 1. Finding #1 — Pick & Pack generates no picking orders

### 1.1 Verdict — ✅ root cause proven (UAT config)

The test client **"Alquimista Cellars"** (`client.id = 72050`, `cl_nr = 22ALQ522`) has
**`section_id = NULL`**. The order-release query filters such orders out unconditionally, so
`OrderReleaseJob` never sees them. They sit at `state = 0` (`RAW`) forever, with **no error, no state marker,
and no log line**.

### 1.2 The excluding predicate

`v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/CustomerorderPositionRepository.java:70-90`
(`streamOrderReleaseInfo`, the query behind `OrderReleaseJob.releaseOrders()`):

```sql
 FROM customerorder_position cop
 LEFT JOIN customerorder co        ON cop.order_id = co.id
 LEFT JOIN itemdata i              ON cop.itemdata_id = i.id
 LEFT JOIN customerorder_batch cob ON co.orderbatch_id = cob.id
 LEFT JOIN client                  ON cob.client_id = client.id
 LEFT JOIN section sec             ON client.section_id = sec.id
 WHERE co.state < :state
   AND co.pickingdate <= CAST(:pickingDate AS date)
   AND cob.type = :orderBatchType
   AND sec.id is not null              -- ← line 88: the excluding predicate
```

Note the join is on **`cob.client_id`** (the *batch's* client), not `co.client_id`.
The same predicate exists on the non-streaming sibling `getOrderReleaseInfo` at line 62.

### 1.3 Every other predicate passes

| Predicate | Required | Ibrar's orders | Pass? |
|---|---|---|---|
| `co.state < 200` (`ASSIGNED`) | < 200 | `0` (`RAW`) | ✅ |
| `co.pickingdate <= today` | ≤ 2026-08-14 | `2026-08-12`, `2026-08-11` | ✅ |
| `cob.type = 'PICK_PACK'` | `PICK_PACK` | `PICK_PACK` | ✅ |
| `sec.id is not null` | non-null | **NULL** | ❌ |

Job gating (`OrderReleaseJob:97-102`) also passes — both sysprops are on, and the schedule is every minute:

| Sysprop | Value on Hydra UAT |
|---|---|
| `NEW_CRON_JOB_ACTIVATED` | `true` |
| `ORDER_TIMER_ACTIVATED` | `true` |
| `ORDER_TIMER_HOUR` / `ORDER_TIMER_MINUTE` | `*` / `*` → cron `0 * * * * *` |
| `CRON_JOB_SHOW_LOG` | `false` ← why nothing was logged |

### 1.4 Differential proof

The production query was re-run against `wh01_hydra_v2` twice — identical except for line 88:

| Query | Ibrar's rows (`001833-000001`, `001834-000001`) returned? |
|---|---|
| Production query **as-is** | **No** — 0 of his rows (only 4 unrelated `state = 50` rows) |
| Same query, **only** `AND sec.id is not null` removed | **Yes** — both rows, `client_name = 'Alquimista Cellars'`, `section_id = NULL` |

This isolates the section predicate as the sole cause.

### 1.5 Corroborating data

```
customerorder_batch (Hydra UAT, most recent)
 id       batchid              type       state  client_id  client            section_id
 3298832  CLUB-20260812-003    CLUB        530   72050      Alquimista Cellars   NULL
 3298828  BATCH-20260812-002   PICK_PACK     0   72050      Alquimista Cellars   NULL   ← stuck
 3298823  BATCH-20260812-001   PICK_PACK     0   72050      Alquimista Cellars   NULL   ← stuck
 3274089  BATCH-20260803-002   PICK_PACK   500   53400      VinoShipper-Zerolink 59250  ← worked
 3274075  BATCH-20260803-001   PICK_PACK   500   53400      VinoShipper-Zerolink 59250  ← worked
```

- **Every** previously-working PICK_PACK batch belongs to client 53400, which **has** a section (`ZoneA`).
- Ibrar's orders are `state = 0`; the batches are `state = 0`. Nothing has touched them.
- No `pickingorder` row has been created since **2026-08-03**, i.e. since the last section-having client's batch.
- The CLUB batch for the *same* section-less client reached `state = 530` — because the **club run is
  operator-driven, not released by `OrderReleaseJob`**. This is why only Pick & Pack was affected.

### 1.6 Blast radius on Hydra UAT

| Metric | Count |
|---|---|
| Clients in `wh01_hydra_v2` | 138 |
| …with a section | **20** |
| …with `section_id = NULL` | **118** |

Sections available: `ZoneA` (id 59250, used by 18 clients), `TestSection` (id 50800, used by 2).

**Any client picked at random for a Pick & Pack test has an ~86% chance of failing this way.**

Breaking the 118 down by how *live* they are — this is not 118 dead rows:

| Of the 118 section-less clients | Count |
|---|---|
| have ever had an order batch | 4 |
| had a batch in the last 180 days | 1 (Alquimista Cellars — the QA failure) |
| **have SKUs loaded** | **110** |

So 110 are onboarded, SKU-bearing clients that will stall silently the moment OMS sends them a Pick & Pack
order. Backfill tracked as [SBDEV-2963](https://app.clickup.com/t/868krfv18).

### 1.7 Recommended action

**To unblock QA (no code change):** assign a section to client 72050 — `ZoneA` (59250) is what all 18 working
clients use. The stuck batches should then be released within a minute by the existing cron. Alternatively,
re-test with client 53400 (`ZEROLINK`).

No restart or cache flush is needed: the release query is native SQL joining `client` directly and never reads
the cache, so the change lands on the next cron tick. (The separate `clients` Caffeine cache,
`CacheConfig.java:37`, only affects `ClientService` lookups and has a 5-minute TTL.) Via the UI the path is
Admin → **Shippers** → edit → **Section** (`editShipper.vue:38` → `PATCH /client/{id}`).

**Fleet-wide backfill:** [SBDEV-2963](https://app.clickup.com/t/868krfv18) — needs a human decision on which
section each client belongs to (a warehouse-layout call, not derivable from the data) and on scope.

**Product defect (filed, see §4.1):** the misconfiguration is *doubly* silent —
- the SQL filters the order out, so `releaseOrder()` is never reached; and
- `WmsConstants.State.CLIENT_HAS_NO_SECTION = 45` exists but **no code path ever writes it**. Verified: the
  constant is only ever *read* (`ReleaseOrderJobService:246`, `:581` as a "healing" condition, plus
  `getCodeText`). Nothing sets it.
- Even the unreachable fallback would only raise
  `BusinessException("Section not configured for order=…")` (`ReleaseOrderJobService:604`), which
  `OrderReleaseJob:292-295` swallows behind a `basicService.showLog()` gate — and `CRON_JOB_SHOW_LOG=false`
  on UAT.

Net: an operator gets **no** signal of any kind. This is the actual bug worth fixing.

---

## 2. Finding #2 — Club Line palletize: "String is not valid"

### 2.1 Verdict — ✅ explained (label vs. configured pattern); not a code defect

The message is the resolved `noValidString` bundle key:

`v2/wms2-api/src/main/resources/messages_en_US.properties:324`
```properties
noValidString=String is not valid: '%1s'
```

Thrown from `MobilePalletizingService` when the scanned **pallet** label does not already exist as a
unit load **and** matches neither configured pattern:

| Site | Condition |
|---|---|
| `MobilePalletizingService:189` (`scanPallet`) | pallet label null/empty |
| `MobilePalletizingService:227` (`scanPallet`) | new pallet, matches neither pattern ← **most likely** |
| `MobilePalletizingService:282` (`scanPalletBulk`) | pallet label null/empty |
| `MobilePalletizingService:309` (`scanPalletBulk`) | new pallet, matches neither pattern ← **most likely** |

### 2.2 What Hydra UAT actually accepts for a *new* pallet

Two sysprops are OR'd (`MobilePalletizingService:222-228`):

| Sysprop | Value on Hydra UAT | Effective regex |
|---|---|---|
| `STRING_PATTERN_OUTBOUND_PALLET` | `WC_\d{16}\|OUT-\d{6}\|OUT\d{6}` | as-is |
| `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL` | `AOUT-%1$06d` | `AOUT-\d{6}` via `StringConverter.convertFormatToRegex` |

Accepted label forms — and **nothing else**:

```
AOUT-######      (6 digits)   ← the format actually in use on this environment
OUT-######       (6 digits)
OUT######        (6 digits)
WC_################  (16 digits)
```

`String.matches()` anchors the whole string, so e.g. `PALLET1`, `TEST-1`, `UL003054` are all rejected.

**Escaping was explicitly checked and is fine.** A doubled backslash in that sysprop would make *every* label
fail — a plausible competing hypothesis. It is not the case: `length(sysvalue) = 28`, consistent with single
backslashes (`WC_`3 + `\d{16}`6 + `|`1 + `OUT-`4 + `\d{6}`5 + `|`1 + `OUT`3 + `\d{6}`5 = 28).

> ⚠️ Postgres-vs-Java testing trap: `'AOUT-000119' ~ ('^'||sysvalue||'$')` returns **true** in Postgres,
> because `^`/`$` bind only to the first/last alternative of an unparenthesised alternation, so it matched the
> middle branch `OUT-\d{6}` unanchored. Java's `String.matches` is fully anchored and returns **false** for
> that pattern. `AOUT-000119` is nonetheless valid — via the *printing* pattern, not this one. Do not use
> Postgres `~` to reason about these sysprops.

### 2.3 Evidence the label was rejected

- **No `Pallet`-type unit load was created on 2026-08-12.** Highest outbound pallet is `AOUT-000118`.
  Next valid label: **`AOUT-000119`**.
- The club order was in exactly the right state to palletize — so nothing upstream was broken:

| Entity | Value |
|---|---|
| `customerorder_batch` 3298832 | `state = 530` (`ORDER_BATCH_CLUB_RUN_FINISHED`) |
| `customerorder` 3298833 (`001835-000001`) | `state = 650` (`PACKED`) |
| parcel unit load `XG1786551601511` | created `16:32:26 UTC`, location `Packaging` |

`scanPallet` requires `order.state >= PACKED` and `< FINISHED` (`:174-184`) — satisfied.

### 2.4 The mobile screen does not generate the label

`wms2-mobile-ui/components/palletizing/scanPallet.vue:43` sends the raw scanned value:

```js
this.$store.dispatch('palletizing/scanPallet', { parcelLabel: this.scannedParcel, palletLabel: this.ScannedValue.trim() })
```

There is no "next label" fetch and no auto-generate. **A valid pre-printed label must be scanned.**

Contrast — the **web** palletize popup *does* auto-generate:
`wms2-web-ui/components/reports/popups/palletizeOutboundParcel.vue:13` renders a field labelled
*"Leave blank to create new pallet"* and posts to `/billOfLading/palletize`. That endpoint cannot produce this
error (`noValidString` is thrown only from the four mobile services), which independently confirms the failure
came from the **mobile palletizing screen**, not the web flow.

### 2.5 Recommended action

**To unblock QA:** scan `AOUT-000119` (or any `AOUT-######` / `OUT-######` / `OUT######` / `WC_<16 digits>`),
or use the web Outbound-Parcel palletize popup and leave the field blank to auto-generate.

**Product defect (filed, see §4.2):** the error echoes the rejected string but never states the expected
format, and the mobile screen offers no way to obtain a valid label. An operator cannot self-recover.

---

## 3. Finding #3 — Transfer Offsite not in the "Ready" tab

### 3.1 Verdict — ⚠️ no transfer order ever reached WMS; and WMS has no "Ready" tab

Two independent facts, both verified:

**(a) There is no `TRANSFER_OFFSITE` batch after 2025-11-07.**

```
customerorder_batch grouped by type,state
 TRANSFER_OFFSITE       state 700 (FINISHED)   n=9   latest 2025-11-07
 TRANSFER_INTRACOMPANY  state 700 (FINISHED)   n=1   latest 2025-11-25
```

Nothing was created on 2026-08-12.

**(b) OMS made exactly three inbound calls that day — none of them a transfer.**

Transfer orders arrive on the same endpoint as all other batches
(`OrderRestController`, `PUT /rest/order/create`; `TRANSFER_OFFSITE` handled at `:174-190`).
The inbound `rest_idempotency` ledger for 2026-08-12:

| Time (UTC) | Method | Path | Status | → resulting batch |
|---|---|---|---|---|
| 15:59:12 | PUT | `/rest/order/create` | 204 | `BATCH-20260812-001` (PICK_PACK) |
| 16:11:46 | PUT | `/rest/order/create` | 204 | `BATCH-20260812-002` (PICK_PACK) |
| 16:21:48 | PUT | `/rest/order/create` | 204 | `CLUB-20260812-003` (CLUB) |

**There is no fourth call.**

### 3.2 There is no "Ready" tab in the WMS UI

A full sweep of both WMS UIs (`wms2-web-ui`, `wms2-mobile-ui`) finds no "Ready" tab or label anywhere.
The transfer-related views are:

| Page | Tabs / heading | Backing call |
|---|---|---|
| Outbound → Transfer (`/outbound/transfer`) | **"Open Transfers"**, **"Closed Transfers"** | `/transfers/search/*` |
| Processes → Transfer Picking (`/processes/transfer-picking`) | heading **"Active Transfer Orders"** | `/transfers/activeTransfer` |
| Mobile Transfer Process (`/transfer-order`) | no tabs | `/mobile/transferOrder/*` |

"Ready" is an **OMS** concept — `omsv2-UI` carries it as an order-status *category*
(`src/i18n/locales/en.json`, `OrderStatusesPage`: `New Order` / `Validated` / `Ready`).

Hydra UAT's WMS is wired to an OMS that serves the legacy surface
(`WEBSERVICE_ACCEPT_TRANSFER = https://api-oms.uat.sbo.li/services/call/closeTransfer`); `oms-laravel-api`
does define those routes (`routes/legacy-services.php:36,65,83`), so OMS v2 is a plausible counterpart.

### 3.3 Important caveat — absence of a ledger row is not proof OMS stayed silent

`IdempotencyFilter` **persists only 2xx responses; 4xx/5xx are dropped**
(documented at `IdempotencyFilter.java:56`). So a transfer that OMS *did* send but WMS *rejected* would leave
no `rest_idempotency` row either. Two live possibilities remain:

1. OMS never sent the transfer to WMS (OMS-side workflow never advanced it), **or**
2. OMS sent it and WMS returned a 4xx.

WMS-side validations that would reject a transfer create (`OrderRestController:141-190`):

| Rejection | Constant |
|---|---|
| `batch_id` missing | `FIELD_NOT_SET` |
| `batch_id` already exists | `ENTITY_ALREADY_EXITS` |
| `priority` missing / outside 1–5 | `FIELD_NOT_SET` / `FIELD_MALFORMED_FORMAT` |
| more than one order in a transfer batch | `TRANSFERS_ONLY_ONE_ORDER_ALLOWED_PER_BATCH` |
| `transfer_id` missing | `FIELD_NOT_SET` |
| `transfer_id` reused while previous is non-terminal | `NOT_UNIQUE_VALUE` |

The duplicate-`transfer_id` guard only fires when the prior batch is neither `FINISHED` nor `CANCELED`. All 10
existing transfer batches are `state = 700`, so **a reused `transfer_id` would not have been rejected** — that
particular explanation is ruled out.

The WMS `message` table was also checked: it holds only **outbound** WMS→OMS traffic
(`INVENTORY_FULL_EXPORT`), so it cannot confirm or deny an inbound reject.

### 3.4 What is needed to close this

Cannot be resolved from the WMS side alone. Required:

1. **Where** the "Ready" tab is — which application and exact page (almost certainly OMS).
2. The **transfer / order number** and `transfer_id` used.
3. The **OMS application log** for the outbound call to WMS at ~2026-08-12 — did it fire, and what did WMS
   answer? If WMS 4xx'd, the response body names the offending field.

> No OMS database MCP is configured in this workspace, so the OMS side could not be inspected directly.

---

## 4. Defects filed

### 4.1 SBDEV-2961 — Silent exclusion of orders whose client has no Section

**Severity:** Medium (data-dependent; causes an indefinite silent stall) | **Ticket:** [SBDEV-2961](https://app.clickup.com/t/868krfj4n)

An order whose batch client has `section_id = NULL` is dropped by `streamOrderReleaseInfo`'s
`AND sec.id is not null` and never released. There is **no** operator-visible signal:

- `State.CLIENT_HAS_NO_SECTION = 45` is defined and read, but **never written by any code path**.
- The order remains at `RAW` indefinitely — indistinguishable from "just arrived".
- The fallback `BusinessException` at `ReleaseOrderJobService:604` is unreachable via cron, and would be
  swallowed by `OrderReleaseJob:292-295` behind a `showLog` gate that is `false` on UAT/prod.

Suggested direction: either stamp the order `CLIENT_HAS_NO_SECTION (45)` so it surfaces in the UI, or emit an
unconditional `WARN` + job metric counting section-less orders skipped per tenant. Prefer *both*. Consider a
client-save-time validation or an admin warning badge, since 118/138 UAT clients are in this state.

### 4.2 SBDEV-2962 — Pallet-label rejection gives the operator no recoverable information

**Severity:** Low–Medium (UX / QA-blocking) | **Ticket:** [SBDEV-2962](https://app.clickup.com/t/868krfjcx)

`noValidString` renders as `String is not valid: '<what you scanned>'` — it never states the expected format.
On the mobile palletizing screen there is additionally no way to obtain or generate a valid label
(`scanPallet.vue:43` sends the raw scan), whereas the web popup auto-generates. An operator who scans the
wrong label cannot self-recover.

> **Status 2026-08-14 — the message half is FIXED, the generation half is NOT.** The rendered message is now
> `String is not valid: 'TEST1'. Expected format: AOUT-000001 (accepted: WC_\d{16}|OUT-\d{6}|OUT\d{6}|AOUT-\d{6})`
> at all six throw sites, each supplying its own tenant-correct format. So the sentence above ("never states
> the expected format") describes the pre-fix build only. **Still open:** the mobile screen offers no way to
> obtain a valid label — a follow-up ticket, not yet filed.
>
> Two things this section got right that turned out to matter: the note that Postgres `~` reports false
> positives on these sysprops where Java's anchored `String.matches` does not, and that `AOUT-000119` is valid
> *via the printing pattern* rather than `STRING_PATTERN_OUTBOUND_PALLET`. The second one is the exact
> distinction the plan later lost and a review lane had to recover — the accept condition is **two** OR'd
> regexes, and surfacing only one produced a message whose example matched nothing it listed.
> Plan: `sbdocs/1-Projects/wms2/plan/SBDEV-2962-pallet-label-rejection-no-expected-format.md`.

Suggested direction: include the expected pattern(s) in the message, and/or offer the next generated label on
the mobile screen the way the web popup does.

---

## 5. Method & reproducibility

| | |
|---|---|
| **Code read** | `v2/wms2-api` @ branch `docs/wms2-plan-reconcile-2732-corrections`; `wms2-web-ui`, `wms2-mobile-ui`, `omsv2-UI`, `oms-laravel-api` working copies |
| **Live DB** | `wh01_hydra_v2` (Hydra UAT), Flyway head `2.2.16`, read-only SQL via MCP |
| **Not inspected** | OMS databases and OMS application logs (no MCP configured); legacy `v1/oms` is not cloned in this workspace |
| **No writes** | Nothing was changed on UAT. All findings are observational. |

Key queries, for re-verification:

```sql
-- #1 the differential proof (run both; the only difference is the last line)
SELECT co.number, co.state, client.name, client.section_id
FROM customerorder_position cop
LEFT JOIN customerorder co        ON cop.order_id = co.id
LEFT JOIN customerorder_batch cob ON co.orderbatch_id = cob.id
LEFT JOIN client                  ON cob.client_id = client.id
LEFT JOIN section sec             ON client.section_id = sec.id
WHERE co.state < 200 AND co.pickingdate <= CURRENT_DATE AND cob.type = 'PICK_PACK'
  AND sec.id IS NOT NULL;   -- ← remove this line for the second run

-- #1 blast radius
SELECT count(*) total, count(section_id) with_section FROM client;

-- #2 accepted pallet-label patterns
SELECT syskey, length(sysvalue), sysvalue FROM los_sysprop
WHERE syskey IN ('STRING_PATTERN_OUTBOUND_PALLET','PRINTING_PATTERN_OUTBOUND_PALLET_LABEL');

-- #3 inbound OMS calls on the test date (2xx only — see §3.3)
SELECT request_method, request_path, response_status, created_at
FROM rest_idempotency ORDER BY created_at DESC LIMIT 30;

-- #3 transfer batches ever created
SELECT type, state, count(*), max(created) FROM customerorder_batch
WHERE type LIKE 'TRANSFER%' GROUP BY type, state;
```

## 6. Retest recipe for QA

1. **Pick & Pack** — assign section `ZoneA` to *Alquimista Cellars* (or re-test with `ZEROLINK`), then wait
   ≤ 1 minute; picking orders should appear. Existing stuck batches `BATCH-20260812-001/002` should self-heal.
2. **Club palletize** — on the mobile palletizing screen, scan pallet label **`AOUT-000119`**.
3. **Transfer Offsite** — capture the transfer number and the OMS-side log of the call to WMS, and confirm
   which application's "Ready" tab is meant. WMS shows transfers under Outbound → Transfer ("Open Transfers")
   and Processes → Transfer Picking ("Active Transfer Orders").
