---
kind: review
lane: security
ticket: SBDEV-3672
head: fb89bd31
ui_head: af44fcc
date: 2026-10-16
verdict: no blocking finding; 1 Medium (ops, plan-side), 5 Low
---

# SBDEV-3672 security review: wms2-api fb89bd31 + wms2-web-ui af44fcc

**Scope:** `git diff origin/develop...fb89bd31` in `.claude/worktrees/wms2-api/SBDEV-3672-review-sec` (BillOfLadingController, BolOmsNotificationService, OutboxMessageRepository, BillofladingPositionRepository, MessageService, OutboxService, OutboxDispatchService, V2.2.40). UI: `serviceLog.vue`, `outboundBolDetails.vue`, `store/*` in `.claude/worktrees/wms2-web-ui/SBDEV-3672` (af44fcc). Plan §5 B/D, D5, P-5, §9.
**Risk level:** LOW. Nothing is remotely exploitable beyond what the gate already grants. The one Medium finding is in the plan's deploy gate, not in the code.

Evidence instruments: code read at the worktree head, `git log -S` history, and read-only SQL on 4 PRD tenant DBs (c1wh-shipitez, nywh-shipitez, nywh-hydra, wsl-wineco). No PRD row content was copied out beyond shapes and counts.

## Summary
- Critical: 0 · High: 0 · Medium: 1 · Low: 5 · Verified-clean: listed in §3

## 1. Medium

### M1. The post-deploy schema gate checks the wrong migration version
**Category:** A05 Security Misconfiguration / migration operations
**Location:** plan `SBDEV-3672-chunk-bol-shipped-notification.md:267` (Step 6), also `:84 :129 :155 :158 :236 :250 :251 :263 :428` (13 mentions of `2.2.39`). Code: `src/main/resources/db/migration/V2.2.40__bol_shipped_chunk_size_and_outbox_message_link.sql`.
**Issue:** The migration was renumbered to **V2.2.40** because develop already has `V2.2.39__delete_retired_lane_exclusion_sysprop.sql`. The plan's deploy gate still runs `SELECT version, success FROM flyway_schema_history WHERE version='2.2.39'`. That query reports `success=t` for the **unrelated** sysprop deletion, so a tenant on which V2.2.40 failed (ownership drift, or the 5 s `lock_timeout`) passes the gate. By design (P-5) dispatch keeps working on that tenant, so nothing else alerts. The result is silent: the status endpoint 500s on that tenant, `last_message_id` is never written, and the seed is missing (the fallback to 40 masks it).
**Fix:** Change every `2.2.39` reference in the plan to `2.2.40`. Better, gate on the artifact instead of the version number, so a future renumber cannot break the gate the same way:
```sql
SELECT (SELECT success FROM flyway_schema_history WHERE script LIKE 'V2.2.40__bol_shipped_chunk_size%') AS ok,
       EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema='public' AND table_name='outbox_message' AND column_name='last_message_id') AS col,
       EXISTS (SELECT 1 FROM los_sysprop WHERE syskey='WMS_BOL_SHIPPED_OMS_CHUNK_SIZE' AND workstation='DEFAULT') AS seed;
```

## 2. Low

### L1. The BOL row selection does not filter on `process_type`, but the requeue rewrites `destination_url` to the SHIPPED endpoint
**Category:** A04 Insecure Design (defense in depth)
**Location:** `OutboxMessageRepository.java` `findBolNotificationRows` WHERE clause (diff lines `o.aggregate_type = 'BILL_OF_LADING' AND o.aggregate_id = :bolId`); `requeueBolTerminal` (`WHERE id IN (:ids) AND status='FAILED_TERMINAL'`).
**Scenario:** The rows are selected by aggregate type and id alone. If any future producer enqueues a `BILL_OF_LADING` aggregate with another process type, for example a BOL-loaded or BOL-cancelled event, a requeue would point that payload at `WEBSERVICE_ORDER_BATCH_SHIPPED` with OMS basic auth (`HttpRestService.applyHeaders:149-163`). That would send the wrong event to OMS's finishedShipping endpoint. **Not exploitable today.** `git log -S'aggregateType("BILL_OF_LADING")'` shows one producer ever (6076743b, ORDER_BATCH_SHIPPED), and the count of `aggregate_type='BILL_OF_LADING' AND process_type<>'ORDER_BATCH_SHIPPED'` is 0 on all 4 PRD DBs.
**Fix:**
```java
// BAD
 WHERE (o.aggregate_type = 'BILL_OF_LADING' AND o.aggregate_id = :bolId)
    OR (o.aggregate_type = 'BILL_OF_LADING_CHUNK' AND o.aggregate_id BETWEEN ...)
// GOOD
 WHERE o.process_type = 'ORDER_BATCH_SHIPPED'
   AND ((o.aggregate_type = 'BILL_OF_LADING' AND o.aggregate_id = :bolId)
     OR (o.aggregate_type = 'BILL_OF_LADING_CHUNK' AND o.aggregate_id BETWEEN :bolId * 100000 AND :bolId * 100000 + 99999))
```
Add `AND process_type = 'ORDER_BATCH_SHIPPED'` to the `requeueBolTerminal` UPDATE as well, so the write fences itself and does not rely on the caller's read.

### L2. `lastError` exposes the internal OMS URL and raw OMS response bodies to BOL viewers
**Category:** A01/A09 information exposure
**Location:** `BolOmsNotificationService.status` → `StringUtils.abbreviate(row.getLastError(), 300)`. Sources: `OutboxDispatchService.dispatchOne` writes `"HTTP " + code + ": " + <OMS body>` and the exception `e.getMessage()`, via `OutboxService.markRetry:101` and `markTerminal:115`.
**Evidence:** On c1wh-shipitez PRD, all 6 non-null `last_error` values have the shape `I/O error on POST request for "<full OMS URL>": Read timed out`. Across 3 PRD DBs, 0 values carry a URL with userinfo and 0 carry credential words. The OMS credential travels as a Basic-Auth header and is never in the URL or the message, so **no credential leaks today**. The `HTTP <code>: <body>` branch relays OMS's raw body. If OMS ever runs with `APP_DEBUG=true`, that body is a Laravel exception with file paths and a trace, truncated to 300 characters. The new endpoint widens the audience from Service Log viewers to every `WEB_UI_VIEW_BILL_OF_LADING` holder.
**Fix:** Return a classified reason, not the raw text. At minimum, scrub URLs:
```java
// GOOD
private static final Pattern URL = Pattern.compile("https?://[^\"\\s]+");
String safe = URL.matcher(StringUtils.defaultString(row.getLastError())).replaceAll("<OMS endpoint>");
StringUtils.abbreviate(safe, LAST_ERROR_MAX_CHARS)
```
The full text stays one click away in the Service Log through `lastMessageId`, which has its own gate.

### L3. Requeue has no cooldown on rows OMS rejected outright (400/404/422)
**Category:** A04 Insecure Design (abuse/amplification)
**Location:** `BolOmsNotificationService.requeue`; `OutboxDispatchService.isTerminal` (400/404/422 go terminal on the first attempt).
**Scenario:** A row OMS rejects with 400 is terminal after one POST. A user with `WEB_UI_VIEW_BILL_OF_LADING` can requeue it again at once, and every click triggers one more POST of up to 60 parcels to OMS. That traffic is bounded by the user's click rate and by the dispatcher tick, and each requeue is audited (user, ids), so it is a nuisance rather than a DoS. The payload and idempotency key never change, and the URL is the current sysprop, so the user cannot choose what is sent or where.
**Fix (optional):** In the UI, warn when the last code was a 4xx ("OMS rejected this payload; a requeue resends the same payload"). Or refuse a second requeue of the same row within N minutes, using the audit row's timestamp. Accepting this as-is is reasonable.

### L4 (design). A VIEW function gates a state-changing POST
**Category:** A01 Broken Access Control (design)
**Finding:** The plan's precedent (D5 / Fix D-5) is **accurate**. `closeOutboundBol` (`BillOfLadingController.java:244-246`, a state-changing **GET**) and `closeOutboundBols` (`:275-277`, POST) are both gated on `WEB_UI_VIEW_BILL_OF_LADING`. Requeue is strictly weaker than close. Close is what produced the notification, and requeue only lets a holder retry an unchanged payload that close already sent. I agree with D5. The underlying weakness is that the function catalogue has no action-level function for BOL. That is pre-existing and not this ticket's to fix. Requeue would be the natural first user of a `WEB_UI_ACTION_BILL_OF_LADING` if one is ever split out.

### L5. UI: the `facility` query param is reflected unvalidated into a toast (content spoofing, not XSS)
**Category:** A03 Injection (UI)
**Location:** wms2-web-ui `components/admin/serviceLog/serviceLog.vue` `openDeepLinkedMessage` (`this.$toast.error(\`... belongs to warehouse ${facility}; ...\`)`).
**Finding:** **No XSS.** `plugins/toast.js` wraps every `this.$toast.*` call with `escapeHtml`, and vue-toasted's `innerHTML` sink is covered. A crafted `/admin?messageId=1&facility=<any text>` link can still put arbitrary attacker text into a red error toast, which is a phishing aid. A repeated `facility=a&facility=b` arrives as an array and also takes the mismatch branch.
**Fix:**
```js
// GOOD
const FACILITY = /^[A-Za-z0-9_-]{1,10}$/   // facility_code is varchar(10)
if (facility !== undefined && (typeof facility !== 'string' || !FACILITY.test(facility))) return
```

### Nit. The `~ '^2'` match is looser than the watchdog's success rule
`OutboxMessageRepository.findBolNotificationRows`, `r.statuscodeanswer ~ '^2'`. The watchdog (`egress-failures.sql:86`) uses `'^2\d\d$'`. Today the only writers produce 3-digit codes or `EX`, so the two agree. Align to `'^2\d\d$'` so one definition of "confirmed" holds across both instruments. This is not exploitable: `resendConfirmed` needs a row whose `redeliver_id` equals the linked message, which only `MessageService.resendMessage` writes, and only with OMS's real response code.

## 3. Verified clean (focus items)

- **SQL construction:** every new native query uses named binds, with no concatenation (`linkServiceLog`, `findBolNotificationRows`, `requeueBolTerminal`, `existsTopLevelPallet`).
- **`IN (:ids)`:** the ids come from the server's own read, never from request input.
- **`bolId*100000` arithmetic:**
  - SQL: `:bolId` is a `Long`, so the multiplication is bigint × int → bigint.
  - Java: `getId() * 100_000L` is long arithmetic (`BillofladingService:507`), and there is a span guard at `:472`.
  - Overflow would need an id above about 9.2e13. PostgreSQL raises 22003 rather than wrapping.
  - `findById`/`existsById` run first, so absurd or negative path ids 404 before the range query runs.
  - The largest PRD BOL id is 711,361 (nywh-shipitez), which gives 7.1e10.
- **Audit JSON:** built with Jackson `writeValueAsString` over a `LinkedHashMap`, with no string building. `user` comes from `SecurityContextUtils`, not from the request.
- **Audit row resend:** the sender `wms:requeue` is never equal to the WMS instance name, so `MessageService.resendMessage:177-178` refuses it. Its `redeliver_id` is null, so it can never satisfy `resendConfirmed`.
- **Watchdog blinding:**
  - The `'N/A'` destination is the watchdog's documented exclusion (`egress-failures.sql:31-35`). If the audit row were counted, its non-2xx code would read as a failure, not a success, so it cannot mask a streak either way.
  - Requeued rows dispatch and write their own message rows with the real destination.
  - The `stalled` check reads PENDING/IN_FLIGHT/FAILED_RETRY. A requeue moves a row into that set; it does not hide one.
- **Authz:**
  - Both handlers carry `@RequiresFunction(WEB_UI_VIEW_BILL_OF_LADING)`.
  - The class mapping `/v3/billOfLading` (`BillOfLadingController:42`) overrides `AdminController`'s `/v3`, and there is no `/v3/dashboard` twin.
  - Both routes are pinned in `Sbdev3017TrancheGateContextTest` (pin size 229 → 231).
  - `FunctionGuardInterceptor:275-276` checks the caller's username against the routed tenant DB.
  - CSRF is disabled with bearer-only auth (`SecurityConfiguration:131`), so cross-site POST is not applicable.
- **IDOR:**
  - `bolId` is local to one tenant DB, and a caller can only reach a DB through `X-Tenant-ID`.
  - The JWT issuer is bound to the tenant by `MultiTenantJwtDecoder`, so a cross-tenant id cannot be read or requeued.
  - Switching facility inside a tenant is a designed capability, and the function check re-runs against that facility's DB.
- **Requeue payload and URL:**
  - The payload and idempotency key never change.
  - `destination_url` becomes the current sysprop, which gets the same OMS basic auth as a fresh close. That adds no capability: anyone who can edit that sysprop already redirects the next BOL close.
  - A blank sysprop raises a BusinessException with rollback.
- **Migration V2.2.40:**
  - The table owner equals the Flyway installer on all 4 PRD DBs (`wh0x_*_v2_app`), so no ownership drift is visible today. `los_sysprop` was checked on nywh-shipitez.
  - The column and the seed are absent on all 4 (expected pre-deploy).
  - `ADD COLUMN IF NOT EXISTS` is nullable with no default or FK, so it is metadata-only. `SET LOCAL lock_timeout='5s'` bounds the ACCESS EXCLUSIVE wait. The `WHERE NOT EXISTS` seed is idempotent.
  - A failure stays local to one tenant by design (the column is native-only). See M1 for why the gate would currently miss it.
- **UI:**
  - `lastError` is rendered with mustache, which escapes it. No `v-html` was added.
  - The deep-link href is the fixed path `'/admin?' + URLSearchParams`, so there is no open redirect.
  - `messageId` is checked with `^\d+$`.
  - `history.replaceState` stays same-origin and keeps the existing `history.state`.
  - `messageDetailsById` keeps its own server-side gate.

## Security checklist
- [x] No hardcoded secrets. The diff scan found test fixtures only (`withPassword("test")`, `"n/a"`).
- [x] Inputs validated. Path ids are Long and 404 on unknown; UI `messageId` is numeric-only. `facility` is unvalidated (L5).
- [x] Injection prevention verified: all native SQL is bound, and Jackson builds the audit JSON.
- [x] Authentication and authorization verified: gate pinned, VIEW-for-POST precedent confirmed (L4).
- [x] Dependencies: no `pom.xml` or `package.json` change in either diff, so no new dependency audit was run.
- [ ] Deploy gate: fix M1 before the PRD deploy.

## Scoped re-check (head 63b0a89)

**Scope:** `git diff af44fcc..63b0a89` in the wms2-web-ui worktree. It touches 2 files: `components/admin/serviceLog/serviceLog.vue` (+15/-3) and `test/components/admin/serviceLogDeepLink.spec.js`. Fixer notes: `impl-webui-executor.md` § "Security lane L5 fix". The check was read-only.

**Verdict: L5 is CLOSED.** No new finding. One nit is noted below and needs no action.

1. **Fix is correct.**
   - A present `facility` must pass two tests before anything else happens. It must be known: equal to `selectedWarehouse`, or included in `state.warehouses`. It must also match `^[A-Za-z0-9_-]{1,10}$`.
   - On failure the method returns, and nothing renders the value.
   - A repeated param arrives as an array, which matches neither `===` nor `Array.prototype.includes` against string members, so it is rejected.
   - Dropping my suggested `typeof` clause is sound for that reason.

2. **The pattern matches the real codes.**
   - Landlord `tenant_db_configuration.warehouse` holds `c1wh`, `nywh` (×2) and `wsl` on PRD (all active) and on UAT (all active). It holds the same four on dev (`dev_landlord`, only `wsl` active).
   - Every value matches the pattern (`ok = t`, lengths 3–4).
   - The store does not hold landlord values. `state.warehouses` is the Keycloak `warehouse` claim, trimmed and possibly upper-cased, e.g. `WSL` (`pages/index.vue:150-153`). `selectedWarehouse` is one element of that list, normalised to the token's casing (`pages/index.vue:176-180`, `store/index.js:321-331`).
   - The pattern is case-insensitive by character class, so `WSL`, `C1WH` and `NYWH` all pass.
   - No code anywhere comes near the 10-character bound.

3. **The legitimate "own facility, not the selected one" case is not broken.**
   - That code is in `state.warehouses`, so it is known, and it is well-formed.
   - It reaches the `facility !== selected` branch, which keeps the "belongs to warehouse X; switch warehouse" toast.
   - Only unknown or malformed values void the link silently.
   - Nit (no action): membership is case-sensitive. A link made in one browser carries that browser's `selectedWarehouse`, which comes from the same Keycloak claim casing, so a mismatch would need two users whose claims differ only in case. In that case the link is voided, which fails safe.
   - Behaviour change: `?messageId=N&facility=` (empty) is now voided, where af44fcc opened it. The BOL screen never generates an empty `facility`, since `outboundBolDetails.vue` adds it only when `selectedWarehouse` is set, so no real link is affected.

4. **No user-controlled text is echoed.**
   - The deep-link path has 3 toasts. `serviceLog.vue:315` interpolates `messageId` (checked with `^\d+$`) and `facility` (validated, and one of the user's own codes). `serviceLog.vue:321` interpolates `messageId` only.
   - `store/admin/serviceLogs.js:105` interpolates `data.id`, which is `Number(messageId)`, or uses the generic text.
   - `plugins/toast.js` escaping is still in front of all three.
   - `history.replaceState` strips both params before any branch runs, so a voided link does not persist in the address bar.
