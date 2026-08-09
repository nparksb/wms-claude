---
title: "SBDEV-2781 — Expected Return Date shows a bogus time (and previously the wrong day)"
ticket: "SBDEV-2781"
ticket_url: "https://app.clickup.com/t/868kj3kvk"
type: bugfix
priority: normal
status: implemented
project:
  - wms2
version: v2
requester: "Brent Campbell"
created: 2026-08-05
updated: 2026-08-05
db_verified: true
related:
  - "[[260523-UTC-TIMEZONE-MIGRATION]]"
  - "[[SBDEV-2233-nametypeservice-date-format-pattern-fix]]"
  - "[[260610-excel-export-localdatetime-unsupported-type]]"
  - "[[260609-wms2-ui-outbound-datetime-audit]]"
tags:
  - plan
  - wms2
  - receiving
  - timezone
---

# SBDEV-2781 — Expected Return Date shows a bogus time (and previously the wrong day)

**Ticket:** [SBDEV-2781](https://app.clickup.com/t/868kj3kvk)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** normal
**Status:** implemented — PRs open, awaiting review (see §13)
**Date:** 2026-08-05

> ## ⚠ CORRECTION 2026-08-05 — the ticket's entire user-visible complaint is ALREADY FIXED on `origin/develop`
>
> **This plan was drafted against a stale local checkout (`v2/wms2-web-ui` was 11 commits behind
> `origin/develop`). Fix A does not need doing.** Caught at the TDD-gate step, when the freshly-created
> worktree off `origin/develop` already contained the fixed template.
>
> | Fix | Real status on `origin/develop` |
> |---|---|
> | **A** — stray `getTime` line on the notices tables | **ALREADY DONE** — `e6ca85a` *"Show Expected (dayofdelivery) as date-only on inbound notice tables"*, 2026-07-31. Covered **all three** components (`openNotices.vue`, `closedNotices.vue`, **and** `openNoticeReceiptTable.vue`). |
> | **B** — delete the dead `dayofdelivery` slot | **still open** — `e6ca85a` removed the time line but left the (unreachable) slot |
> | **C** — HAL `exported = false` ×3 | **still open** |
> | **D** — outbound BOL `shipped` stray time | **still open** |
>
> `e6ca85a` (UI) and `dfe24f8` (API, §2.3) are from the **same 2026-07-31 session**, and **neither is
> linked to SBDEV-2781** — which is why the ticket still reads as open. Together they close every
> user-visible acceptance criterion in the ticket.
>
> **Honest baseline against `origin/develop`** (shadow root over both per-ticket worktrees):
> `Result: 17 pass, 7 fail, 2 skip` — every Fix A row PASSES at baseline. The earlier
> `15 pass / 11 fail` figure recorded in §9 graded the stale tree and is **void**; it is kept below only
> as the record of how the false baseline arose.
>
> **What is genuinely left is hardening and cleanup, not the reported bug** — Fix C (a real latent defect
> with no user impact today), Fix D (a real cosmetic defect but on the *outbound BOL* screen, not
> returns), and Fix B (dead code). **Scope decided 2026-08-05 (D5): all three ship under SBDEV-2781.**
> Fix A is struck from the deliverables and demoted to guard checks.
>
> **Lesson for the next plan: `git fetch` and diff `develop..origin/develop` in every affected repo
> before enumerating §0.** Reading the working tree is not reading the branch the work will merge into.
> The API repo was only 2 commits behind and its analysis survived; the UI repo was 11 behind and its
> primary finding did not.

> **Process note — ralplan consensus loop deliberately skipped.** `wms-bugfix-plan` permits this for
> mechanical fixes, and every change below qualifies: delete two stray template lines, delete one dead
> template slot, swap one formatter helper, and add `exported = false` to three annotations. There is no
> design space to arbitrate — the root cause is proven, the correct construct already exists in the same
> file family, and the diff has no algorithmic or transactional content. Recorded here per the skill's
> explicit exception clause.

---

## 0. Affected sites (enumeration before drafting)

Method: symbol grep for `dayofdelivery` / `getDayofdelivery` / `setDayofdelivery` across
`v2/wms2-api/src`, both v2 UIs, `v2/omsv2-UI`, both v1 UIs and `v2/oms-laravel-api`; pattern grep for
the same root cause (a SQL `date` column rendered through a time-bearing formatter) across every
`date`-typed column in the tenant schema; and a cross-reference grep of `sbdocs/1-Projects` +
`sbdocs/4-Archieves`.

**All `date`-typed columns in the v2 tenant schema** (`information_schema.columns`, `wms2-wineco-dev`) —
this is the complete universe for this bug class:

| Table | Column | Status |
|---|---|---|
| `advice` | `dayofdelivery` | **this ticket** |
| `advice` | `dayofdeliveryuntil` | this ticket (never displayed in any UI; API-side only) |
| `billoflading` | `shipped` | row 6 below — adjacent, in scope by decision D4 |
| `customerorder` | `pickingdate` | already fixed — SBDEV-2660 (`ViewDtoService:461`, `:555`) |
| `customerorder_old` | `pickingdate` | dead table, no code reads it |

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `wms2-web-ui` `components/receiving/open/openNotices.vue` "Expected" cell | was `{{getTime(item.dayofdelivery)}}` on a 2nd line | **yes** — the ticket's core defect | **no — ALREADY FIXED** by `e6ca85a` (2026-07-31). Now guarded by A1b so a revert is caught. |
| 2 | `wms2-web-ui` `components/receiving/closed/closedNotices.vue` "Expected" cell | same | **yes** | **no — ALREADY FIXED** by `e6ca85a`. Guarded by A2b. |
| 3 | `wms2-web-ui` `components/receiving/open/openNoticeReceiptTable.vue:78-80` | `item.dayofdelivery` slot — `e6ca85a` removed its `getTime` line but left the slot, which is **unreachable**: that table's `headers` array (`:133-188`, re-verified on `origin/develop`) declares `number, clientId, goodsreceiptId, amount, advicepositionId, operatorId, stockunitId, unitloadId, actions` and **no `dayofdelivery`**, so Vuetify never invokes it | yes (residue) | **yes** — Fix B (dead-code deletion, D4) |
| 4 | `wms2-api` `repo/jpa/AdviceRepository.java:47,68,97` | `@RestResource(path=…)` on `getDetailViewByKeyword` / `getOpenNoticesByKeyword` / `getClosedNoticesByKeyword` — HAL-exported native projections returning raw `java.sql.Date` | **yes** — identical mechanism to the bug PR #116 fixed, on a path PR #116 does not cover | **yes** — Fix C (decision D2) |
| 5 | `wms2-web-ui` `components/outbound/bol/outboundBolDetails.vue:57` | `getTimeDate(outboundBol.shipped)` → `$formatDateTime` on the `billoflading.shipped` `date` column | **yes** (stray time only; date is correct — served as entity `LocalDate` from `BillofladingService:179`) | **yes** — Fix D (decision D4) |
| 6 | `wms2-api` `service/ViewDtoService.java:1028,1031` | `toLocalDate(result.getDayofdelivery())` | yes | **no — already fixed** by PR #116 / `dfe24f8` (2026-07-31). Verified present on `origin/develop`. |
| 7 | `wms2-api` `service/AdviceService.java:477-478` | `details.put("dayofdelivery", a.getDayofdelivery())` (notice-detail endpoint) | no — reads the entity's `LocalDate` directly, never a `java.sql.Date` | no — correct as written |
| 8 | `wms2-api` `service/AdviceService.java:537-538` + `FileExportService.java:255-257` | Excel export "Day of Delivery" rows | no — `setCellValue` has a dedicated `LocalDate` branch using `CELL_DATE_FORMAT` (date-only, "never timezone-converted") | no — correct as written |
| 9 | `wms2-api` `controller/rest/AdviceRestController.java:251,259` | `LocalDate.parse(adviceDto.getDayOfDelivery())` (OMS → WMS ingestion) | no — parses an ISO `yyyy-MM-dd` string into `LocalDate`; no timezone math on the write path | no — correct as written |
| 10 | `wms2-api` `service/ReceivingService.java:211-213` | `advice.setDayofdelivery(parsedDeliveryFrom)` (file-import ingestion) | no — `LocalDate` in, `LocalDate` out | no — correct as written |
| 11 | `wms2-web-ui` `openNoticeDescription.vue:34`, `closedNoticeDescription.vue:62` | `getDate(noticeDetails.dayofdelivery)` → `$formatDateShort` | no — **already correct**: date-only helper, no `getTime` sibling | no — this is the reference implementation Fix A copies |
| 12 | `wms2-mobile-ui`, `omsv2-UI`, `v1/wms-web-ui`, `v1/wms-mobile-ui`, `oms-laravel-api` | — | — | no — grep for `dayofdelivery` / `advice/search` / `NoticesByKeyword` returns **zero hits** in all five |

Rows 1–5 are in scope and each maps to a POSITIVE check in
`sbdocs/9-System/scripts/verify-SBDEV-2781-expected-return-date-stray-time-and-tz-shift.sh` (§9).

---

## 1. Problem Statement

**Reporter's wording (SBDEV-2781, Brent Campbell, 2026-07-30):**

> The Expected Return Date shown in WMS V2 is not displaying the correct calendar date. The field also
> displays a time even though the return workflow does not capture or require a specific expected return
> time. […] Recommended display: `Expected Return Date: 07/30/2026` — instead of:
> `Expected Return Date: 07/29/2026 8:00 PM`

Area: Returns / Return Inbound Notices. Evidence attached to the ticket:
`Timezone Bug Inbound Notices.webm`.

The field the reporter calls "Expected Return Date" is the **"Expected"** column of the Inbound Notices
list, bound to `advice.dayofdelivery`. On a RETURN-type advice this is the expected return date.

### 1.1 Two distinct defects behind one symptom

The ticket describes one symptom but it has two independent causes, and **one of them has already been
fixed since the ticket was filed**:

| | Defect | Status |
|---|---|---|
| **(a)** wrong calendar date, shifted back one day, with a real-looking time | API served the `date` column as a midnight-UTC instant | **FIXED** — PR #116 / `dfe24f8`, merged to `develop` 2026-07-31 (one day *after* this ticket was filed). See §2.3. |
| **(b)** a time is displayed for a date-only field | UI renders a second `getTime(...)` line under the date | **OPEN** — this plan. Post-(a) it now reads `12:00:00 am`. |

So the ticket is **not stale** — its headline acceptance criterion ("Time is not displayed when no time is
captured") is still unmet, and the display is still wrong, just differently wrong than the screenshot.

### 1.2 Symptom verification (`db_verified: true`)

**DB — the column is genuinely date-only, so there is no time to display.** Against `wms2-wineco-dev`:

```sql
SELECT column_name, data_type FROM information_schema.columns
 WHERE table_name='advice' AND column_name IN ('dayofdelivery','dayofdeliveryuntil','created','modified');
```
```
created             | timestamp with time zone
dayofdelivery       | date                       <-- date-only, no time component exists
dayofdeliveryuntil  | date
modified            | timestamp with time zone
```

```sql
SELECT a.type, count(*) n, count(a.dayofdelivery) with_dod,
       min(a.dayofdelivery) min_dod, max(a.dayofdelivery) max_dod,
       count(a.dayofdeliveryuntil) with_until
  FROM advice a GROUP BY a.type ORDER BY n DESC;
```
```
REGULAR | 10369 | 9854 | 1999-01-01 | 2026-07-30 | 405
RETURN  |  2216 | 2216 | 2020-03-25 | 2026-07-31 |   0
```

Reads: **every one of the 2,216 RETURN advices carries a `dayofdelivery`**, so the defect is displayed on
100% of return rows, not an edge case. `dayofdeliveryuntil` is never populated for RETURN (0/2216) —
which is why the reporter only ever saw the one field.

**Rendering — reproduced exactly.** Executed against the UI's real `moment-timezone` and a faithful copy
of `plugins/dateFormatter.js`'s `safeParse`:

```
value                          | $formatDateShort | $formatTimeOnly | $formatDate
"2026-07-31T00:00:00.000Z"     | 07/30/26         | 8:00:00 pm      | 07/30/2026   <-- defect (a), pre-PR#116
"2026-07-31"                   | 07/31/26         | 12:00:00 am     | 07/31/2026   <-- defect (b), today
```
in `America/New_York`; the same midnight-UTC instant renders `07/30/26 5:00:00 pm` in
`America/Los_Angeles`.

The first row **is the reporter's screenshot**: a return whose expected date is 07/30 displayed as
`07/29 8:00 PM`. That confirms the diagnosis of defect (a) beyond code reading — and confirms the
warehouse in the recording is on Eastern time (UTC-4), whereas `dfe24f8`'s commit message cites a 5:00pm
Pacific reproduction. Same mechanism, two tenants.

The second row is what a user sees on `develop` **today**: correct day, plus a fabricated `12:00:00 am`.

### 1.3 Reproduction (current state, post-PR #116)

1. Log into WMS v2 web UI as a user on a warehouse in any non-UTC timezone.
2. Navigate to **Receiving → Inbound Notices**, tab **Open** (then repeat on **Closed**).
3. Find any RETURN-type notice — all 2,216 on wineco-dev qualify.
4. Read the **Expected** column: the date is now correct, but a second line reads `12:00:00 am`.
5. Open the notice detail (`/receiving/openNotice/:id`) — the same field shows **no** time there. The
   list and the detail screen disagree, which is itself one of the ticket's acceptance criteria
   ("The value is consistent across open and closed return inbound notices and return detail screens").

---

## 2. Root Cause Analysis

### 2.1 The date-only contract

`advice.dayofdelivery` is a SQL `date`. It is a **calendar date, not an instant** — "the day the return is
expected", with no hour, and therefore nothing to convert between timezones. The UTC-migration doc states
the rule directly (`FileExportService.java:256`): *"Calendar dates (dayofdelivery, shipped) — never
timezone-converted."* Every bug in this ticket is a violation of that contract in one direction or the
other.

The v2 stack has exactly one correct representation for such a field on the wire: a Java `LocalDate`,
which `WebConfigurer.java:96` serializes with `LocalDateSerializer(ofPattern("yyyy-MM-dd"))` → a bare
`"2026-07-31"` with no offset marker and no time.

### 2.2 Bug 1 — the UI renders a time for a field that has none *(in scope)*

`components/receiving/open/openNotices.vue:77-80`:

```vue
<template #[`item.dayofdelivery`]="{ item }">
  <v-card-text class="font-weight-bold pa-0">{{getDate(item.dayofdelivery)}}</v-card-text>
<v-card-text class="pa-0">{{getTime(item.dayofdelivery)}}</v-card-text>   <!-- line 79: the bug -->
</template>
```

with (`:375-383`):

```js
getDate(time) { if (time) { return this.$formatDateShort(time) } },
getTime(time) { if (time) { return this.$formatTimeOnly(time) } },
```

`components/receiving/closed/closedNotices.vue:59-62` + `:268-278` is a byte-for-byte clone of the same
two-line cell.

`$formatTimeOnly` (`plugins/dateFormatter.js:53-56`) is a *timestamp* helper — it exists to render the
clock part of a `timestamptz`. Handing it a date-only value cannot produce information, only noise:
`safeParse("2026-07-31")` takes the "legacy bare format" branch (line 35), which parses the string with
format `'YYYY-MM-DD HH:mm:ss'`; the absent `HH:mm:ss` tokens default to zero, yielding midnight in the
warehouse zone, which formats as `12:00:00 am`. **Measured, not inferred** — see §1.2.

The two-line date-over-time cell is a deliberate and correct pattern *elsewhere* in these same tables —
`closedNotices.vue:64-65` applies it to `item.modified` (the "Closed" column), and `modified` **is** a
`timestamp with time zone`, so its time is real. That adjacency is exactly how the bug survived review:
the cell looks like its neighbour. It is only wrong because `dayofdelivery` is not a timestamp.

The already-correct counter-example lives one directory over: `openNoticeDescription.vue:34` and
`closedNoticeDescription.vue:62` render the same field through `getDate(...)` alone with **no** `getTime`
sibling. Fix A makes the list agree with the detail screens.

### 2.3 The Regression Chain — why the reported *date* shift is already gone

| Commit | Date | Merge | Effect |
|---|---|---|---|
| `df43512` | (pre) | PR #88 (`a095bf64`) | SBDEV-2660 — introduced `ViewDtoService.toLocalDate()` and applied it to `customerorder.pickingdate` (`:461`, `:555`). Fixed the off-by-one pick date; **did not touch `advice`**. |
| `dfe24f8` | 2026-07-31 | PR #116 (`e18f00b`), 2026-07-31 | *"Fix RETURN advice Expected date showing previous day at 5pm"* — applied the existing `toLocalDate()` helper to `dayofdelivery` and `dayofdeliveryuntil` at `ViewDtoService:1028,1031`, plus regression tests in `ViewDtoServiceUnitTest.AdviceViews`. **This is the API half of SBDEV-2781**, authored against the ticket's symptom but never linked to the ticket number. |

Confirmed on `origin/develop`: `git merge-base --is-ancestor dfe24f8 origin/develop` → **yes**.
`git show --stat dfe24f8` → 2 files, 50 insertions: `ViewDtoService.java` (+10) and
`ViewDtoServiceUnitTest.java` (+42). **No UI file was touched** — which is precisely why defect (b)
survives.

The mechanism `dfe24f8` removed, in its own words: the native-query projection
(`AdviceNoticeView.getDayofdelivery()` is typed `Object`) hands back a `java.sql.Date`; because
`UtcDateSerializer` is registered for `Date.class`, Jackson routes every `java.util.Date` **subclass**
through it (`UtcDateSerializer.java:21-26`), emitting `"2026-07-31T00:00:00.000Z"`; a negative-offset
client then rolls that instant back a calendar day.

**Implication for this plan:** do not re-fix `ViewDtoService`. Fix A/B/D are UI-side, and Fix C closes the
one API path `dfe24f8` could not reach.

### 2.4 Bug 2 — the HAL search endpoints still emit midnight-UTC *(in scope)*

`AdviceRepository` is `@RepositoryRestResource(collectionResourceRel="advice", path="advice")`, and three
of its native-projection queries carry `@RestResource`, which exports each as a Spring Data REST search
resource:

```java
@RestResource(path = "getDetailViewByKeyword",  rel = "getDetailViewByKeyword")   // :47
@RestResource(path = "getOpenNoticesByKeyword", rel = "getOpenNoticesByKeyword")  // :68
@RestResource(path = "getClosedNoticesByKeyword", rel = "getClosedNoticesByKeyword") // :97
```

An HTTP call to `/v3/advice/search/getOpenNoticesByKeyword?keyword=…` **bypasses the service layer
entirely** — the projection is serialized straight to JSON, so `getDayofdelivery()` returns a raw
`java.sql.Date` and `UtcDateSerializer` reproduces the exact bug `dfe24f8` fixed. `AdviceDetailView` and
`AdviceNoticeView` both declare these accessors as `Object`, so there is no type-level guard either.

This is a known structural trap in this codebase: **a service-layer fix cannot guard a Spring Data REST
`@RestResource` query, because the HTTP request never enters the service method.** It bit SBDEV-1666 the
same way.

Blast radius, verified: `getDetailViewByKeyword`/`getOpenNoticesByKeyword`/`getClosedNoticesByKeyword`
and the literal string `advice/search` return **zero** hits across `wms2-web-ui`, `wms2-mobile-ui`,
`omsv2-UI`, `v1/wms-web-ui`, `v1/wms-mobile-ui` and `oms-laravel-api/app|config`. The web UI reaches this
data exclusively through the controller `GET /v3/advice/detailView`
(`store/receiving/inboundNotices.js:135` and `:277` → `AdviceController:303` →
`ViewDtoService.getAdviceViewByKeyword`), which is the fixed path.

### 2.5 Bug 3 — dead `dayofdelivery` slot *(in scope, cleanup)*

`components/receiving/open/openNoticeReceiptTable.vue:78-80` defines a `item.dayofdelivery` slot with the
same buggy `getDate` + `getTime` pair, but that component's `headers` array declares
`number`, `clientId`, `goodsreceiptId`, `amount`, `advicepositionId`, `operatorId`, `stockunitId`,
`unitloadId`, `actions` — nine columns, **none of them `dayofdelivery`**. Its `items` come from `store.state.receiving.inboundNotices.goodsReceiptPositions`
(goods-receipt positions, which have no such field). Vuetify only invokes `item.<name>` slots for
declared headers, so this template block never executes. It is copy-paste residue from `openNotices.vue`.

Harmless today, but it is a live trap: anyone adding an "Expected" column to that table would silently
reintroduce Bug 1. Deleting it now is zero-risk and closes the reintroduction path.

### 2.6 Bug 4 — outbound BOL `shipped` renders a stray time *(in scope by decision D4)*

`components/outbound/bol/outboundBolDetails.vue:57`:

```vue
<v-list-item-content class="pa-0">{{ getTimeDate(outboundBol.shipped) }}</v-list-item-content>
```
with `getTimeDate(t) { if (t) { return this.$formatDateTime(t) } }` (`:149-153`).

`billoflading.shipped` is a SQL `date` (§0), and `Billoflading.getShipped()` returns `LocalDate`, which
`BillofladingService.java:179` puts straight into the detail map — so the wire value is a clean
`"2026-07-31"` and **the date is correct**. Only the appended `12:00:00 am` is wrong. Same bug class as
Bug 1, different screen, cosmetic-only. `getTimeDate` is correctly applied to `outboundBol.created` on
the adjacent line 53 (`created` is a `timestamptz`), so — as in §2.2 — only the `shipped` call is wrong.

---

## 3. Architecture Overview

```
 OMS ──POST /v3/rest/advice──► AdviceRestController:251
                                 LocalDate.parse("2026-07-31")            ✔ date-only in
                                        │
                                        ▼
                              advice.dayofdelivery  (SQL `date`)          ✔ date-only at rest
                                        │
        ┌───────────────────────────────┼────────────────────────────────────┐
        │ (1) controller path           │ (2) HAL path                       │ (3) detail path
        ▼                              ▼                                    ▼
 GET /v3/advice/detailView      GET /v3/advice/search/                GET /v3/advice/
 AdviceController:303             getOpenNoticesByKeyword               adviceDetailsById/{id}
        │                              │                                    │
 ViewDtoService:1028            projection serialized DIRECTLY        AdviceService:477
 toLocalDate(...)  ✔ PR#116     java.sql.Date → UtcDateSerializer      entity LocalDate  ✔
        │                        "2026-07-31T00:00:00.000Z"  ✘ Bug 2         │
        ▼                              ▼                                    ▼
   "2026-07-31"                   (no UI consumer)                     "2026-07-31"
        │                                                                   │
        ▼                                                                   ▼
 openNotices.vue:78  getDate  → "07/31/26"      ✔          openNoticeDescription.vue:34
 openNotices.vue:79  getTime  → "12:00:00 am"   ✘ Bug 1      getDate only  → "07/31/26"  ✔
 closedNotices.vue:60/61      → same            ✘ Bug 1    closedNoticeDescription.vue:62 ✔
```

### Key Files

| File | Lines | Role |
|---|---|---|
| `wms2-web-ui/components/receiving/open/openNotices.vue` | 77-80, 193-198, 375-383 | Open Inbound Notices table — "Expected" cell (**Fix A**) |
| `wms2-web-ui/components/receiving/closed/closedNotices.vue` | 59-62, 141-146, 268-278 | Closed Inbound Notices table — "Expected" cell (**Fix A**) |
| `wms2-web-ui/components/receiving/open/openNoticeReceiptTable.vue` | 78-80 | Dead `dayofdelivery` slot (**Fix B**) |
| `wms2-api/repo/jpa/AdviceRepository.java` | 47, 68, 97 | HAL-exported native projections (**Fix C**) |
| `wms2-web-ui/components/outbound/bol/outboundBolDetails.vue` | 57 | Outbound BOL `shipped` (**Fix D**) |
| `wms2-web-ui/plugins/dateFormatter.js` | 23-56 | `safeParse` + `$formatDateShort` / `$formatTimeOnly` — unchanged, the contract Fix A relies on |
| `wms2-api/service/ViewDtoService.java` | 193-198, 1028, 1031 | `toLocalDate()` helper + the already-landed PR #116 fix — **do not modify** |
| `wms2-api/util/json/UtcDateSerializer.java` | 21-26, 42-53 | Why any `java.util.Date` subclass becomes a UTC instant — **do not modify** |
| `wms2-web-ui/components/receiving/open/openNoticeDescription.vue` | 34, 147-151 | Reference implementation (date-only, no `getTime`) |

---

## 4. Fix Design

### ~~Fix A~~ — drop the time line from both Inbound Notices "Expected" cells *(Bug 1, the ticket's core)*

> **✅ ALREADY IMPLEMENTED on `origin/develop` by `e6ca85a` (2026-07-31) — do not re-do this.** That commit
> made exactly the edit specified below, in all three components, and even added the same explanatory
> comment. Retained here as the record of the ticket's core defect and as the rationale for the A1b/A2b/A2d
> **guard** checks, which now pin the fix against a revert. The Jest specs in §7.1/§7.2 are likewise
> **regression guards, not gates** — they pass at baseline by design.

**`components/receiving/open/openNotices.vue:77-80`**

Before:
```vue
<template #[`item.dayofdelivery`]="{ item }">
  <v-card-text class="font-weight-bold pa-0">{{getDate(item.dayofdelivery)}}</v-card-text>
<v-card-text class="pa-0">{{getTime(item.dayofdelivery)}}</v-card-text>
</template>
```
After:
```vue
<template #[`item.dayofdelivery`]="{ item }">
  <!-- SBDEV-2781: advice.dayofdelivery is a SQL `date` (date-only). Rendering a second
       $formatTimeOnly line fabricated a "12:00:00 am" that the workflow never captures.
       Matches openNoticeDescription.vue:34, which has always been date-only. -->
  <v-card-text class="font-weight-bold pa-0">{{getDate(item.dayofdelivery)}}</v-card-text>
</template>
```

**`components/receiving/closed/closedNotices.vue:59-62`** — identical edit to the `dayofdelivery` slot.

Leave the `getTime` **method definitions** in place in both files: `closedNotices.vue` still needs
`getTime` for the "Closed" column (`item.modified`, a genuine `timestamptz`, lines 64-65). In
`openNotices.vue` the method becomes unused after this edit — delete it there so lint stays clean, but do
**not** delete it from `closedNotices.vue`.

`getDate` keeps calling `$formatDateShort` → `07/31/26` (decision **D3**). No change to
`plugins/dateFormatter.js`: `$formatDateShort` on a bare `"2026-07-31"` is already correct in every
timezone (§1.2), because `safeParse`'s legacy branch parses it as warehouse-local midnight and
`.tz(warehouseTz)` is then a no-op on the calendar day.

**Why this fix and not the alternatives:**
- *Not* a new `$formatDateOnly` helper — `$formatDateShort` already is exactly that, and is what the
  detail screens use. Adding a helper would create two names for one behaviour.
- *Not* stripping the time in `safeParse` — `safeParse` is shared by every timestamp in the app; making it
  date-aware would silently drop real times from `timestamptz` fields.
- *Not* changing the API — the API is already correct on this path (§2.3). The wire value carries no time;
  only the renderer invents one.

### Fix B — delete the dead `dayofdelivery` slot *(Bug 3)*

Delete `components/receiving/open/openNoticeReceiptTable.vue:78-80` in full (the whole
`<template v-slot:[`item.dayofdelivery`]>` block). Then delete that file's now-unused `getDate` /
`getTime` methods **only if** no other slot in the file uses them — verify with a grep before removing, as
the file also renders `actions`.

### Fix C — unexport the three HAL search resources *(Bug 2)*

**`repo/jpa/AdviceRepository.java`** — three one-line annotation edits:

Before:
```java
@RestResource(path = "getDetailViewByKeyword", rel = "getDetailViewByKeyword")
```
After:
```java
// SBDEV-2781: not exported. These native projections return java.sql.Date for the `date`
// columns dayofdelivery/dayofdeliveryuntil; served directly over HAL they bypass
// ViewDtoService.toLocalDate() and re-emit the midnight-UTC instant PR #116 fixed.
// No UI or OMS caller consumes them — GET /v3/advice/detailView is the supported path.
@RestResource(path = "getDetailViewByKeyword", rel = "getDetailViewByKeyword", exported = false)
```
Same for `getOpenNoticesByKeyword` (:68) and `getClosedNoticesByKeyword` (:97).

**Why unexport rather than convert the projections:** for the two Notices searches, the projection
exists to feed `ViewDtoService`, which already converts correctly. Retyping `Object getDayofdelivery()`
→ `LocalDate` would work for Hibernate but leaves two supported paths to the same data that must be kept
in sync forever — the condition that produced this bug. Removing the unused path removes the bug class.
Per decision **D2**.

> **Correction (2026-08-05, from the code-review lane).** That rationale is accurate for
> `getOpenNoticesByKeyword` and `getClosedNoticesByKeyword`, but **not** for
> `getDetailViewByKeyword`: `ViewDtoService.getAdviceViewByKeyword` calls only the two Notices methods
> (`:1003`, `:1005`), and the `getDetailViewByKeyword` calls elsewhere in that service are on
> `unitloadRepository` (`:570`), `stockunitRepository` (`:604`) and `messageRepository` (`:1053`) — five
> repositories share the method name. Verified: **`adviceRepository.getDetailViewByKeyword` has no Java
> caller anywhere**, and `AdviceDetailView` is referenced only by `AdviceRepository` itself. So
> unexporting it leaves that method + its ~30-line native query + the `AdviceDetailView` projection with
> **no callers and no HTTP surface — fully dead code**. This does not weaken Fix C (unexporting dead code
> is strictly safer than unexporting live code), but deleting it exceeds this plan's authorised scope, so
> it is recorded as **open decision D6** rather than actioned. The annotation comment in the code names
> the situation so the next maintainer is not misled.

**Additional safety evidence found during review:** these search resources were never in the published
OpenAPI document either — `pom.xml` carries `springdoc-openapi-starter-webmvc-ui` but **not**
`springdoc-openapi-starter-data-rest` — so no documented contract is being withdrawn.

**How the 404 actually arises** (worth knowing, from the Spring Data REST 4.5.7 source):
`RepositoryMethodResourceMapping:76` reads the annotation's `exported()` directly, so `false` wins
regardless of `RepositoryDetectionStrategy` / `exposeMethodsByDefault` config; `RepositoryResourceMappings:113`
then never registers the mapping, and `RepositorySearchController.checkExecutability:301-304` 404s on the
null lookup. Note the 404 comes from the mapping's **absence**, not from an `isExported()` check in the
controller — so if a future SDR version registered unexported mappings, the query would execute and then
NPE into a 500 rather than 404. `GET /v3/advice/search` still returns 200 and simply omits the three rels.

**Contract change — declare it:** this is a *removal* of three public HAL search resources. Verified
unreferenced across all five UIs and the OMS API (§2.4), but an undocumented external caller would get
`404`. Called out in §8 Risks and §6 rollout.

Do **not** add `exported = false` to `findByExternalid`, `findByTransferId`, `findByState`,
`findByKeywordAndState` or `updateAdviceToStateById` — they are outside this ticket and may have callers.

### Fix D — drop the stray time from outbound BOL "shipped" *(Bug 4)*

**`components/outbound/bol/outboundBolDetails.vue:57`**

Before: `{{ getTimeDate(outboundBol.shipped) }}`
After:  `{{ getDate(outboundBol.shipped) }}`

Add a sibling `getDate(d) { if (d) { return this.$formatDate(d) } }` if the file has no date-only helper
(verify first — the file already defines `getTimeDate` at :149). Use `$formatDate` (`MM/DD/YYYY`) here,
not `$formatDateShort`: this is a detail-panel field, and the adjacent `created` row on line 53 renders a
full 4-digit year via `$formatDateTime`. Leave line 53 (`created`, a real `timestamptz`) untouched.

---

## 5. File Change Summary

| File | Change Type | Description |
|---|---|---|
| ~~`openNotices.vue`~~ / ~~`closedNotices.vue`~~ | **none** | Fix A already on `origin/develop` (`e6ca85a`) — **no change in this PR** |
| `wms2-web-ui/components/receiving/open/openNoticeReceiptTable.vue` | modify | Fix B — delete the dead `item.dayofdelivery` slot (78-80) + any then-orphaned helper |
| `wms2-web-ui/components/outbound/bol/outboundBolDetails.vue` | modify | Fix D — `getTimeDate(shipped)` → date-only render |
| `wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/AdviceRepository.java` | modify | Fix C — `exported = false` on 3 `@RestResource` annotations |
| `wms2-web-ui/test/plugins/dateFormatter.spec.js` | **new** | **Regression guard** (passes at baseline): date-only contract, multi-tz + UTC-boundary + DST. Satisfies the ticket's "tests cover multiple timezones / DST" AC, which nothing else covers. |
| `wms2-web-ui/test/components/receiving/inboundNoticesExpectedColumn.spec.js` | **new** | **Regression guard** (passes at baseline): pins `e6ca85a` — Expected cell renders no time, open + closed |
| `wms2-api/src/test/java/net/aim_ai/wms/unit/repo/AdviceRepositoryRestExportUnitTest.java` | **new** | **GATE** — pins `exported = false` on the 3 search resources, and pins that the 4 entity lookups stay exported |
| `wms2-web-ui/test/components/outbound/outboundBolShippedDate.spec.js` | **new** | **GATE** — Shipped Date renders date-only; `created` keeps its time |
| `wms2-web-ui/test/components/receiving/openNoticeReceiptTableDeadSlot.spec.js` | **new** | **GATE** — no `item.dayofdelivery` scoped slot; companion assertion proves the slot was unreachable |

No database migration. No Flyway version. No config, sysprop, or environment change.

---

## 6. Implementation Steps

### 6.1 Prerequisites

| Concern | Applies? | Detail |
|---|---|---|
| DB state | **N/A** | No schema or data change. `advice.dayofdelivery` is already the correct `date` type; the 2,216 existing RETURN rows need no backfill and render correctly the moment the UI stops appending a time. |
| Feature flags / sysprops | **N/A** | Cosmetic display fix; a flag would add more risk than it removes. |
| Config / env | **N/A** | — |
| Deploy order | **Yes** | Two repos, **no ordering constraint**. Fix A/B/D (UI) and Fix C (API) are independent: the UI never calls the endpoints Fix C unexports, and Fix C changes nothing the UI reads. Either PR may merge first. |
| Data migration | **N/A** | — |
| External systems | **Yes (low)** | Fix C removes three HAL search resources. Verified zero callers across all five UIs + `oms-laravel-api`; an undocumented external consumer would receive `404`. |
| Access | **Yes** | Push access to `wms2-web-ui` and `wms2-api`; `origin/develop` fetched fresh for both. |
| Monitoring | **N/A** | No new failure mode. A `404` on an unexported HAL path would surface in existing access logs. |
| Upstream dependency | **Yes** | PR #116 (`dfe24f8`) must be on the deployed branch, else defect (a) masks the verification of (b). Confirmed on `origin/develop` 2026-08-05. |

### 6.2 Steps

Branch (both repos): `bugfix/SBDEV-2781-expected-return-date-date-only`, off freshly-fetched
`origin/develop`.

1. **Baseline.** Run `bash sbdocs/9-System/scripts/verify-SBDEV-2781-expected-return-date-stray-time-and-tz-shift.sh`
   with `PROJECT_ROOT` pointed at a shadow root covering both repos. It must reproduce the recorded
   baseline in §9 — `Result: 15 pass, 11 fail, 0 skip`. **If it does not, stop**: either the tree is not
   clean `origin/develop`, the shadow root is mis-pointed (grading the main checkouts instead of the
   worktrees), or the toolchain is missing. Do not begin implementation against an unexplained baseline.
2. **Write the failing tests first** (`wms-tdd-gate` owns this): the two new Jest specs and the new JUnit
   test in §5. Confirm each fails for the right reason — the Jest component spec must fail on the
   *presence* of `12:00:00 am`, not on a mount error.
3. ~~Fix A~~ — **skip**, already on `origin/develop` (`e6ca85a`). Do not touch `openNotices.vue` or
   `closedNotices.vue`; the only UI files this PR changes are `openNoticeReceiptTable.vue` and
   `outboundBolDetails.vue`.
4. **Fix B** — `openNoticeReceiptTable.vue` dead slot. Atomic commit.
5. **Fix D** — `outboundBolDetails.vue`. Atomic commit.
6. **Fix C** — `AdviceRepository.java` ×3. Atomic commit, separate repo.
7. Run `node_modules/.bin/jest` in `wms2-web-ui` (nvm node; there is no `yarn` on PATH) and
   `mvn clean compile` + `mvn test -Dtest=AdviceRepositoryRestExportUnitTest` in `wms2-api`.
8. Re-run the verify script → require `Result: N pass, 0 fail`.
9. Execute the §7 manual test plan against a non-UTC tenant. **A Los Angeles / Eastern tenant is not
   sufficient on its own for the boundary rows** — see §7's TZ note.
10. Code review; fix every High/Medium. Two PRs into `develop`. Update §9 Implementation Status. Move
    SBDEV-2781 to `pr submitted`.

---

## 7. Testing Plan

### 7.1 Unit — `wms2-web-ui` (Jest + vue-jest, `testEnvironment: jsdom`)

New `test/plugins/dateFormatter.spec.js` — the date-only contract, parameterised over
`America/New_York` (UTC-4/-5), `America/Los_Angeles` (UTC-7/-8), `Asia/Tokyo` (UTC+9, positive offset —
proves the fix is not just "negative-offset safe") and `UTC`:

- `shouldRenderBareDateUnchangedInEveryWarehouseTimezone` — `$formatDateShort('2026-07-31')` → `07/31/26`
  in all four zones. **This is the assertion that makes the ticket's "date does not shift" criterion
  machine-checkable.**
- `shouldNotShiftOnUtcDayBoundary` — `'2026-01-01'` and `'2026-12-31'` hold their calendar day in all four
  zones (ticket AC: "dates near UTC day boundaries").
- `shouldNotShiftAcrossDstTransition` — `'2026-03-08'` (US spring-forward) and `'2026-11-01'`
  (fall-back) hold in `America/New_York` (ticket AC: "daylight-saving transitions").
- `shouldStillConvertRealTimestamps` — **guard against over-fixing**: `$formatDateTime` on
  `'2026-07-31T00:00:00.000Z'` must still yield `07/30/2026 8:00:00 pm` in New York. Fix A must not make
  the helpers date-blind.
- `documentsTheDefect` — asserts `$formatTimeOnly('2026-07-31')` returns `'12:00:00 am'`, pinning *why*
  the helper must not be called on a date-only field.

New `test/components/receiving/inboundNoticesExpectedColumn.spec.js` — shallow-mount `openNotices.vue`
and `closedNotices.vue` with a stubbed store and one RETURN row (`dayofdelivery: '2026-07-31'`), stubbing
`$formatDateShort` / `$formatTimeOnly`:

- `openNoticesExpectedCellRendersDateOnly` — rendered text contains `07/31/26` and **does not match**
  `/\d{1,2}:\d{2}:\d{2}\s*(am|pm)/i`.
- `closedNoticesExpectedCellRendersDateOnly` — same.
- `closedNoticesClosedColumnStillRendersTime` — the `modified` cell **does** still render a time.
  Prevents a careless fix from stripping the legitimate one two lines below.
- `openNoticesDoesNotCallFormatTimeOnly` — assert the `$formatTimeOnly` spy was never invoked with
  `'2026-07-31'`. Catches a fix that hides the time with CSS instead of removing the call.

### 7.2 Unit — `wms2-api` (JUnit 5)

New `src/test/java/net/aim_ai/wms/unit/repo/AdviceRepositoryRestExportUnitTest.java` — reflection over
`AdviceRepository`, no Spring context:

- `shouldNotExportNoticeSearchProjections` — for each of `getDetailViewByKeyword`,
  `getOpenNoticesByKeyword`, `getClosedNoticesByKeyword`, assert the `@RestResource#exported()` is
  `false`.
- `shouldStillExportEntityLookups` — `findByExternalid`, `findByTransferId`, `findByState`,
  `findByKeywordAndState` remain `exported() == true`. Pins the blast radius so a future sweep cannot
  quietly unexport more than this ticket authorised.

Existing `ViewDtoServiceUnitTest.AdviceViews` (added by `dfe24f8`) must keep passing untouched — it is
the regression guard for defect (a) and this plan changes nothing it covers.

### 7.3 Integration

**N/A with rationale.** No repository query, native SQL, DDL, or transaction boundary changes. Fix C
removes an HTTP surface rather than adding one, and v2's Testcontainers lane cannot boot
(`TODO(SBDEV-2217)`), so an IT asserting a `404` would be `@Disabled` on arrival. The reflection test in
§7.2 pins the annotation, and step 4 of §7.4 verifies the `404` by hand.

### 7.4 Manual test plan

**TZ note:** the warehouse timezone comes from `tenant_discovery.timezone`. Rows 1-3 must run on a
**non-UTC** tenant or they prove nothing (on UTC, midnight-UTC and local midnight coincide and the old
bug is invisible). Row 5 needs a **positive-offset** zone; if no such tenant exists, run it as a Jest
case (§7.1) and note the substitution.

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|---|
| 1 | Open Inbound Notices — RETURN row | dev, non-UTC tenant (wineco-dev, ET) | Receiving → Inbound Notices → **Open**; find a RETURN notice | "Expected" shows the correct calendar date and **no time**; matches the date OMS sent | |
| 2 | Closed Inbound Notices — RETURN row | same | tab **Closed** | Same date, no time. "Closed" column **still shows** date **and** time (`modified` is a real timestamp) | |
| 3 | List ↔ detail agreement | same | From row 1, open the notice detail | Detail's Expected date is byte-identical to the list's; neither shows a time | |
| 4 | HAL search unexported | dev | `curl -H "$AUTH" '…/v3/advice/search/getOpenNoticesByKeyword?keyword=x'` | `404`. Then `GET /v3/advice/detailView?...&state=OPEN&page=0&size=10` still `200` with `"dayofdelivery":"YYYY-MM-DD"` | |
| 5 | Positive-offset warehouse | any UTC+ tenant, else Jest | Repeat row 1 | Date unchanged — the fix is offset-agnostic, not negative-offset-specific | |
| 6 | Pre-existing records render | dev | Page through ≥3 pages of Closed notices incl. rows with `dayofdelivery` from 2020-2024 | Every row date-only, none shifted (ticket AC "Existing return records render correctly") | |
| 7 | Excel export unaffected | dev | Open notice → Export Inbound Notice | "Day of Delivery" cell is a date with no time (already correct via `CELL_DATE_FORMAT`; regression guard) | |
| 8 | Outbound BOL shipped (Fix D) | dev | Outbound → BOL → open a shipped BOL's details | "Shipped" shows `MM/DD/YYYY`, no time. "Created" **still shows** date + time | |
| 9 | Goods-receipt table (Fix B) | dev | Open notice → receipts table | Renders unchanged — columns, sorting, actions all intact (proves the deleted slot was dead) | |

### 7.5 Post-implementation gate

Inherited from `wms-bugfix-plan`; all four must hold before sign-off:
verify script `Result: N pass, 0 fail` (first **and** last), a test for every code change, full
`node_modules/.bin/jest` + `mvn clean compile` + `mvn test` green, and §9 filled in with SHAs, test names
and result counts.

**Negative-test the verify script before trusting it.** A grep script can report `0 fail` on a build that
still contains the defect. Replay each pre-fix file (`git stash` a single fix, or `git show HEAD~1:<path>`
into place) and confirm the corresponding check flips to FAIL. A script that stays green against the
unfixed file is worthless — SBDEV-2736 scored 57/0 on a build carrying the very defect it was written to
catch.

---

## 8. Horizontal Scalability Validation (v2 — mandatory)

| # | Concern | Verdict | Notes |
|---|---|---|---|
| 1 | In-JVM state | **N/A** | No cache, `ThreadLocal`, `static`, or `ConcurrentHashMap` added. Fix C removes a request mapping. |
| 2 | Connection pool math | **N/A** | No change to per-request DB connections; the unexported queries were never called. |
| 3 | Scheduled jobs | **N/A** | No `@Scheduled` touched. |
| 4 | Long transactions | **N/A** | No transaction boundary touched. |
| 5 | Request affinity | **N/A** | Both changes are stateless; Vue rendering is client-side. |
| 6 | Retry / idempotency | **N/A** | Read-only display path; no writes. |
| 7 | Tenant context | **N/A** | No `@Async` / `CompletableFuture` / job context. Warehouse timezone is read client-side from Vuex `warehouseTimezone`, per-browser, never shared across replicas. |
| 8 | Distributed lock correctness | **N/A** | No locks. |
| 9 | Cache invalidation | **N/A** | `advice` is not `@Cacheable`; no entity write. |
| 10 | External notifications | **N/A** | No HTTP/message send added or removed on any commit path. |

All-N/A is correct here and considered, not defaulted: the diff is four template/annotation edits with no
runtime state, no I/O, and no transactional content. Fix C strictly *reduces* the exposed surface.

## 8b. v2-only constraint checklist

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | OSIV disabled | **N/A** | No new repository call or lazy-load path. Fix C removes a path that read `Object` scalars from a native projection — no associations. |
| 2 | Transaction manager | **N/A** | No `@Transactional` added or modified. `AdviceRepository`'s existing `@Transactional` on `updateAdviceToStateById` is untouched and correctly inherits `tenantTransactionManager` from `@EnableJpaRepositories`. |
| 3 | `@Transactional(readOnly=true)` | **N/A** | No service method added. |
| 4 | Caffeine cache invalidation | **N/A** | `Advice` is not a cached type; no write path. |
| 5 | Jakarta namespace | **N/A** | No import added; `Advice.java` already imports `jakarta.persistence.*`. Nothing is ported from v1. |
| 6 | H2-compatible test SQL | **N/A** | The new JUnit test is pure reflection over annotations — no SQL, no datasource, no Spring context. |
| 7 | `BaseControllerTest` for controller changes | **N/A** | No controller added or modified. `AdviceController:303` is untouched. Fix C edits repository annotations only. |
| 8 | Micrometer metrics | **N/A** | Not a high-frequency path; no new failure mode worth a counter. A `404` on the unexported paths is visible in access logs. |

---

## 9. Acceptance

Verify script: `sbdocs/9-System/scripts/verify-SBDEV-2781-expected-return-date-stray-time-and-tz-shift.sh`

Run it with a symlink shadow root spanning both repos:

```bash
PROJECT_ROOT=/path/to/shadow-root \
  bash sbdocs/9-System/scripts/verify-SBDEV-2781-expected-return-date-stray-time-and-tz-shift.sh
```

**Required final line:** `Result: 28 pass, 0 fail, 0 skip`.

> Scope after the CORRECTION banner: **9 checks must flip** — B1, C1–C4, D1 (code) and T3, T5, T6
> (the three gate tests). The Fix A rows (A1a–A2e), G1–G3, C5, D2, D3, B2 and T1/T2/T4 are **guards that
> already pass**: they must stay green, they are not deliverables.
>
> ### TDD-gate baseline (2026-08-05, `origin/develop` + gate tests, before any production change)
>
> ```
> Result: 19 pass, 9 fail, 0 skip
> ```
>
> FAILs: `B1`, `C1`, `C2`, `C3`, `C4`, `D1`, `T3`, `T5`, `T6` — the 6 code edits and the 3 gate tests,
> nothing else. Each gate test was confirmed to fail on an **assertion**, not on scaffolding:
> `T3` names all three still-exported search resources; `T5` reports the literal rendered string
> `"Shipped Date 07/31/2026 12:00:00 am"`; `T6` reports `["item.dayofdelivery", "item.actions"]`.
>
> The two **guard** specs were **mutation-tested** to prove they are not decoration: re-adding the
> pre-`e6ca85a` `getTime(item.dayofdelivery)` line to `openNotices.vue` flipped exactly its two
> assertions to FAIL while the `closedNotices` assertions stayed green. Restored afterwards.

### Measured FAIL baseline (captured 2026-08-05, against unmodified `origin/develop`)

```
Result: 15 pass, 11 fail, 0 skip
```

The 11 FAILs are exactly the 11 deliverables of this plan — `A1b`, `A2b` (stray time), `B1` (dead slot),
`C1`–`C4` (HAL export), `D1` (BOL shipped), `T1`–`T3` (the three new test artifacts). The 15 PASSes are
the guards plus the anti-over-fix checks, and include **`T4` — `ViewDtoServiceUnitTest` green**, which
independently confirms PR #116's regression tests for defect (a) are on `develop` and passing.

**This baseline is the script's negative test** (per §7.5): every check this plan is supposed to flip is
red *before* implementation, and nothing that must stay green is red. A check that was already PASSing at
baseline proves nothing about the fix — that is why the A/B/C/D rows were each confirmed FAIL here.

**Two template bugs were found and fixed while capturing this baseline** — both would have produced false
signals, so do not copy the unpatched helpers from `verify-plan-template.sh` into a new script:

1. **`mvn_test_passes` false-FAILs.** The template greps stdout for
   `BUILD SUCCESS|Tests run.*Failures: 0`, but `mvn -q` prints neither. Measured:
   `mvn test -Dtest=ViewDtoServiceUnitTest -q` exits **0** while emitting no matching line, so the
   template helper reported FAIL for a clean suite. Now gated on the **exit code**.
2. **`mvn_test_passes` / `jest_spec_passes` false-GREEN on a missing test.**
   `-DfailIfNoTests=false` and `jest --testPathPattern` with no match both exit 0 — so a test class that
   was never written would have PASSed. Both helpers now require the file to exist first.

Additionally, `file_not_contains` carries a `[ -f "$2" ] || return 1` guard: without it a renamed or
missing file makes every negative assertion fail **open** (grep exits 2, `!` inverts it to success).

**Toolchain:** `mvn` / `java` are not on `PATH` in this environment — they are under SDKMAN. The script
prepends `~/.sdkman/candidates/{java,maven}/current/bin` itself and `skip`s the behavioural rows with an
explicit reason if the toolchain is still missing, rather than reporting a phantom code failure. A run
that reports any `SKIP` is **not** an acceptable sign-off.

Mapping from the §0 in-scope rows to checks:

| §0 row | Fix | Positive check | Negative check |
|---|---|---|---|
| 1 | A *(done)* | **guard** — `openNotices.vue` retains `getDate(item.dayofdelivery)` | **guard** — `getTime(item.dayofdelivery)` absent |
| 2 | A *(done)* | **guard** — `closedNotices.vue` retains `getDate(item.dayofdelivery)` **and** `getTime(item.modified)` | **guard** — `getTime(item.dayofdelivery)` absent |
| 3 | B | — | `openNoticeReceiptTable.vue` has no `item.dayofdelivery` slot |
| 4 | C | all three `@RestResource` carry `exported = false` | no bare `@RestResource(path = "get*NoticesByKeyword", rel = …)` without `exported` |
| 5 | D | `outboundBolDetails.vue` renders `shipped` date-only; still renders `created` with time | `getTimeDate(outboundBol.shipped)` absent |
| — | guard | G1-G3: `ViewDtoService:1028/1031` still call `toLocalDate`; `openNoticeDescription.vue:34` still date-only; `FileExportService` retains its `LocalDate` branch | — |

### Ticket acceptance criteria → coverage

| Ticket AC | Covered by |
|---|---|
| Correct calendar date | Already fixed (PR #116); regression-guarded by G1 + `ViewDtoServiceUnitTest.AdviceViews` + manual 1/6 |
| Treated as date-only | Fix A + `dateFormatter.spec.js` |
| Time not displayed | **already fixed** by `e6ca85a`; pinned by `inboundNoticesExpectedColumn.spec.js` + manual 1/2 |
| No shift from UTC / local conversion | `shouldRenderBareDateUnchangedInEveryWarehouseTimezone` + manual 1/5 |
| Open and closed notices agree | Fix A on both files + manual 2 |
| Detail and BOL detail agree | Manual 3; detail path already correct (§0 row 11) |
| Existing records render correctly | Manual 6 (2020-2024 rows) |
| Tests cover multiple timezones | `dateFormatter.spec.js` — 4 zones incl. one positive offset |
| Tests cover UTC boundaries + DST | `shouldNotShiftOnUtcDayBoundary`, `shouldNotShiftAcrossDstTransition` |
| Reports / exports where applicable | Manual 7; export already correct (§0 row 8), guarded by G3 |

---

## 10. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Fix C `404`s an undocumented external consumer of `/v3/advice/search/*` | Medium — a silent integration break | Grepped all five UIs + `oms-laravel-api` for `advice/search` and all three method names: **zero hits**. Called out as a contract change in the PR description. Reverting is a one-line annotation change per method. |
| Over-fixing: a careless edit strips the *legitimate* time from `closedNotices.vue`'s "Closed" column (`modified`, a real `timestamptz`) two lines below the target | Medium — loses real information | `closedNoticesClosedColumnStillRendersTime` test + verify-script positive check on `getTime(item.modified)` + manual row 2. `getTime` is explicitly retained in that file. |
| Over-fixing: `safeParse` or `$formatTimeOnly` made date-blind, breaking every real timestamp in the app | High | `plugins/dateFormatter.js` is **not** modified by this plan. `shouldStillConvertRealTimestamps` pins `$formatDateTime` on an ISO instant. |
| Verify script false-greens (grep asserts shape, not behaviour) | High — an over-claimed "DONE" | Negative-test every check against the pre-fix file (§7.5). Behavioural coverage lives in the Jest specs, not the greps. `file_not_contains` is guarded against missing files (fails closed). |
| PR #116 not yet on the environment under test, so defect (a) masks (b) | Medium — confusing verification | Prerequisite in §6.1; confirmed `dfe24f8` is an ancestor of `origin/develop` on 2026-08-05. Dev auto-deploys on push. |
| Reporter expected `07/30/2026` but sees `07/31/26` | Low — cosmetic disagreement with ticket text | Decision **D3**: short form is the notices table's convention. Note it in the PR and on the ticket so QA does not fail row 1 on format. |
| Fix B deletes a slot that turns out to be reachable | Low | Verified `headers` has no `dayofdelivery` and `items` are goods-receipt positions. Manual row 9 confirms the table renders unchanged. |
| Two-repo change merged half-way | Low | Independent by construction (§6.1 deploy order) — neither PR depends on the other. |

---

## 11. Open Questions / Resolved Decisions

All resolved with the requester before drafting (2026-08-05). None outstanding — the TDD gate is clear
to proceed.

| # | Question | Decision | Rationale |
|---|---|---|---|
| **D1** | The API half already shipped in PR #116. Scope this plan how? | **UI-only for the display defect; document the API half as already-done.** | Smallest correct diff; PR #116 is on `develop` and its own regression tests already guard defect (a). Re-fixing `ViewDtoService` would be a no-op commit. |
| **D2** | The three HAL-exported `@RestResource` search queries still emit midnight-UTC. Fix, unexport, or defer? | **`exported = false` on all three.** | Zero verified consumers. Removes the bug class rather than maintaining a second correct-serialization path forever. Reconciles with D1: the API change is pure surface *reduction*, not a re-fix — the two answers are consistent, not contradictory. |
| **D3** | Ticket asks for `07/30/2026`; the table uses `$formatDateShort` → `07/31/26`. | **Keep `$formatDateShort`.** | Matches every other column in the notices table. The ticket's example illustrates *date-only*, not a format mandate. Flag on the ticket so QA does not read it as a failure. Fix D's detail panel uses the 4-digit `$formatDate`, matching *its* neighbours. |
| **D5** | After the stale-checkout correction, Fix A needs no work. Ship the residual C/D/B under SBDEV-2781, or close 2781 and re-file? | **Ship C+D+B under SBDEV-2781** (2026-08-05). | Nothing gets dropped and the ledger stays in one place; the ticket becomes "the returns date bug plus the hardening the investigation surfaced". A ClickUp comment (posted 2026-08-05) records that `dfe24f8` + `e6ca85a` already fixed the reported symptom, so QA verifies instead of re-reporting and the next person does not repeat the stale-checkout analysis. |
| **D4** | Include the two adjacent sites? | **Both included** — dead slot (Fix B) and outbound BOL `shipped` (Fix D). | Both are the same root cause and one-line edits. Fix B closes a reintroduction path; Fix D fixes a live cosmetic defect on another screen at near-zero marginal cost. |

---

## 12. Completeness Checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | ✓ §1.2 — two queries against `wms2-wineco-dev`: `information_schema` proves `dayofdelivery` is `date` (not a midnight timestamp), and the type/count aggregate proves all 2,216 RETURN advices carry one (100% blast radius, 0 `dayofdeliveryuntil`). Rendering independently reproduced with the UI's own `moment-timezone`, matching the reporter's screenshot exactly. `db_verified: true`. |
| 1 | **All callsites enumerated** | ✓ §0 — 12 rows; the 5 in-scope rows all appear in §4 Fix Design and §9's check mapping; the 7 excluded rows each carry a rationale. |
| 2 | **Adjacent bugs** | ✓ §0 exhausts the bug class by enumerating **every** `date`-typed column in the tenant schema (5 columns, 5 dispositions). Found `openNoticeReceiptTable` dead slot (§2.5) and `billoflading.shipped` (§2.6), both pulled in scope per D4; `customerorder.pickingdate` already fixed by SBDEV-2660. |
| 3 | **Backward compatibility** | ✓ §4 Fix C + §10 — the only contract change is removal of three HAL search resources, verified unreferenced across five UIs + OMS API. `/advice/detailView` response shape is unchanged (this plan does not touch the API response). No DB, persisted-state, or error-shape change. |
| 4 | **Concurrency** | ✓ §8 rows 4/6/8 — read-only display path, no locks, no writes, no retry semantics. |
| 5 | **Multi-tenant** | ✓ §8 row 7 + §7.4 TZ note — the only tenant-varying input is `tenant_discovery.timezone`, consumed client-side; tests parameterise four zones incl. a positive offset, and the manual plan mandates a non-UTC tenant. |
| 6 | **Error handling** | ✓ No new throw path. Fix C converts three reachable URLs to Spring Data REST's standard `404` — no custom handler needed; documented as intentional in §4 and manual row 4. |
| 7 | **Observability** | ✓ §8 row 10 / §8b row 8 — no new failure mode; a `404` on an unexported path is already visible in access logs. A metric would be noise for a cosmetic display fix. |
| 8 | **Rollback / migration** | ✓ §5 (no Flyway version, no migration), §6.1 (no deploy ordering, no flag). Rollback is `git revert` of either PR independently. |
| 9 | **Test coverage** | ✓ §7 — two new Jest specs (9 named cases incl. two anti-over-fix guards) + one new JUnit reflection test (2 cases), named methods throughout; §7.3 states the integration N/A rationale; §7.4 is a 9-row manual matrix; §7.5 mandates negative-testing the verify script. |
| 10 | **Cross-version (v1↔v2)** | ✓ **N/A — v2-only.** `grep -rn dayofdelivery` across `v1/wms-web-ui` and `v1/wms-mobile-ui` returns zero hits (§0 row 12): v1's receiving UI does not render this field, so there is no v1 counterpart to pair. The UTC migration that created the serialization hazard is v2-only. |

---

## 13. Implementation Status

**MERGED to `develop` 2026-08-05.** ClickUp `on dev`.

| Repo | PR | Merge commit |
|---|---|---|
| wms2-api | [#131](https://github.com/SiteBossInc/wms2-api/pull/131) | `169065c` |
| wms2-web-ui | [#38](https://github.com/SiteBossInc/wms2-web-ui/pull/38) | `743142e` |

**Re-verified on merged `develop`** (not just on the PR branches — the API PR landed on top of the
unrelated #130 merge the same day, so the combination had never been tested): `mvn clean compile` clean,
`mvn test` **4686 run / 2 failures** (both pre-existing, unchanged from baseline), Jest **69/69**, verify
script **`Result: 28 pass, 0 fail, 0 skip`**.

### PRs

| Repo | PR | Branch | Base |
|---|---|---|---|
| wms2-api | [#131](https://github.com/SiteBossInc/wms2-api/pull/131) | `bugfix/SBDEV-2781-expected-return-date-date-only` | `develop` @ `ffeca86` |
| wms2-web-ui | [#38](https://github.com/SiteBossInc/wms2-web-ui/pull/38) | `bugfix/SBDEV-2781-expected-return-date-date-only` | `develop` @ `6ce7878` |

**No merge-order constraint** — the UI never calls the endpoints the API PR unexports, and the API PR changes nothing the UI reads.

### Commits

| SHA | Repo | Fix | Subject |
|---|---|---|---|
| `553bbb1` | wms2-api | **C** | `fix(receiving): stop exporting advice notice searches over HAL [SBDEV-2781]` |
| `4404827` | wms2-web-ui | **D** | `fix(outbound): show BOL Shipped Date without a fabricated time [SBDEV-2781]` |
| `4409f8d` | wms2-web-ui | **B** | `refactor(receiving): drop the unreachable dayofdelivery slot [SBDEV-2781]` |
| `14a7602` | wms2-web-ui | guards | `test(receiving): pin the date-only contract for \`date\` columns [SBDEV-2781]` |

**Fix A: not implemented, by design** — already on `origin/develop` as `e6ca85a` (2026-07-31). See the CORRECTION banner.

### Tests added

| File | Type | Tests |
|---|---|---|
| `unit/repo/AdviceRepositoryRestExportUnitTest.java` | GATE | `noticeSearchProjectionsAreNotExported`, `entityLookupsRemainExported` |
| `test/components/outbound/outboundBolShippedDate.spec.js` | GATE | renders no time; never calls `$formatDateTime` with the date; **Created keeps its time** |
| `test/components/receiving/openNoticeReceiptTableDeadSlot.spec.js` | GATE + guard | no `item.dayofdelivery` slot; headers prove it was unreachable |
| `test/plugins/dateFormatter.spec.js` | guard | 12 tests — 4 timezones, UTC boundaries, both DST transitions, anti-date-blind |
| `test/components/receiving/inboundNoticesExpectedColumn.spec.js` | guard | 4 tests, pins `e6ca85a`; **Closed column keeps its time** |

### Results

| | |
|---|---|
| `mvn clean compile` | clean |
| `mvn test` (wms2-api) | **4686 run, 2 failures, 67 skipped** — both failures pre-existing on `develop` (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`), identical to the pre-change baseline |
| `node_modules/.bin/jest` (wms2-web-ui) | **69 passed, 69 total**. `NuxtLogo.spec.js` suite-load failure is pre-existing on `origin/develop` (missing `components/NuxtLogo.vue`) |
| Verify script | **`Result: 28 pass, 0 fail, 0 skip`** (shadow root over both worktrees; wiring proven by a marker test — shadow moved 19→20 pass while the mono root stayed unchanged) |

Gate baseline before implementation was `19 pass, 9 fail, 0 skip`; all 9 flipped.

### Independent lanes

- **Conformance (`verifier`): PASS**, 0 blockers, high confidence. Re-ran every command itself; mutation-tested `AdviceRepositoryRestExportUnitTest` (reverting `exported = false` on one method flips it red) and `inboundNoticesExpectedColumn.spec.js` (reverting `e6ca85a` flips exactly the 2 open-notices assertions, closed-notices stay green).
- **Code review: APPROVE**, 0 critical / 0 high / 2 medium / 4 low / 8 nit. Independently re-verified both load-bearing claims and found one **stronger** than stated (see D7). Fixed in response: dated the point-in-time verification claim in the code comment; `Arrays.asList` → `List.of`; corrected two factual errors in this plan (§2.5 headers list, §4 Fix C rationale); clarified two spec headers/stubs. Deferred nits are listed in the review output, none behavioural.

### Landmines found during implementation (not predicted by the plan)

1. **The stale-checkout failure itself** — see the CORRECTION banner. `v2/wms2-web-ui` local `develop` was 11 commits behind `origin/develop`, which invalidated the plan's primary deliverable. Now recorded in memory as a per-repo preflight step.
2. **`verify-plan-template.sh` `mvn_test_passes` is broken both ways** — it greps stdout for `BUILD SUCCESS` / `Tests run:` which `mvn -q` never prints (false FAIL on a clean suite, measured), and `-DfailIfNoTests=false` exits 0 for a class that does not exist (false GREEN for a test never written). Both fixed in this plan's script; the shared template still has them.
3. **`getDetailViewByKeyword` on `AdviceRepository` has no Java caller** — five repositories share that method name and the `ViewDtoService` calls are on the other four. See D6.
4. **The HAL 404 comes from the mapping's absence, not an `isExported()` check** in `RepositorySearchController` — so a future SDR version that registered unexported mappings would execute the query and 500 rather than 404.

### Deliberately not done

- **Fix A** — already merged upstream (`e6ca85a`).
- **Deleting the dead `getDetailViewByKeyword` + `AdviceDetailView`** — D6; exceeds this plan's scope. Follow-up filed: [868kmmxcq](https://app.clickup.com/t/868kmmxcq) (low; gated on wms2-api #131 merging first).
- **Manual test plan (§7.4) not executed** — requires a running dev environment and a non-UTC tenant. Both PR bodies carry it for the reviewer. **Manual test 1 (curl → 404) is the only check that proves Spring Data REST honours `exported = false` at runtime**; the unit test asserts the annotation, not the endpoint. Do not sign off without it.
- **Merge and ClickUp `on dev` — DONE** 2026-08-05 (see above).
- **Manual/dev verification — still outstanding.** The §7.4 matrix is on the ticket for QA. Manual test 1 (`curl` → 404) remains the only runtime proof that Spring Data REST honours `exported = false`.
- **Plan archival and worktree removal** — run `archive-plan` when dev verification passes; the per-ticket worktrees remain at `.claude/worktrees/{wms2-api,wms2-web-ui}/SBDEV-2781`.
