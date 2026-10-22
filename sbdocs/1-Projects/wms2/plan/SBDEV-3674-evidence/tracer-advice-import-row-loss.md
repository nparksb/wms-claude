---
ticket: SBDEV-3674
lane: tracer
question: AC-1 — why is AdviceRestController.create()'s ADVICE_IMPORT service-log row lost on REGULAR advice imports?
verdict: PREMISE FALSIFIED — there is no row loss on that path
date: 2026-10-07
code_ref: v2/wms2-api origin/develop @ ce454c68fc0faf956640e9caf018765bd3c42083
db_ref: nywh-hydra-prd (tenant hydra / facility nywh), queried 2026-10-07
---

# Trace report — SBDEV-3674 AC-1

## Observation (restated without interpretation)

On Hydra PRD (tenant `nywh`), since go-live 2026-07-12:

- `advice` holds 237 rows: 235 `REGULAR`, 2 `RETURN`. All 237 carry a non-null `externalid`.
- `message` holds exactly 2 rows with `process='ADVICE_IMPORT'` — one `FAILED` (2026-08-05 14:27:04.732Z) and one `RECEIVED` (2026-09-23 18:20:42.384Z).
- `los_sequencenumber.WEBSERVICE_MESSAGE` = 3403; `message` holds 3001 rows. 402 numbers issued without a surviving row.

## Verdict

**The ADVICE_IMPORT row is not being lost. `AdviceRestController.create()` has run exactly twice
in this tenant's history and wrote a row both times — it is 2-for-2.**

The 235 REGULAR advices were never imported. They were created inside the WMS by
`ReceivingService.createAdviceWithPositions`, reached from the web UI's *Create Inbound BOL*
screen. That method calls no `MessageService` method at all, and correctly writes no
`ADVICE_IMPORT` row, because no import occurred.

The ticket's inference — *"all 237 carry a non-null `externalid`, so all 237 arrived over
`PUT /rest/advice/create`"* — is false. `externalid` on `Advice` has **three** writers in
`src/main` (derived by `git grep -n "setExternalid" origin/develop -- src/main`, then filtered to
the five `new Advice()` construction sites; blind spot: a write through a setter reached
reflectively, or via Spring Data REST `PATCH /v3/advice/{id}`, would not appear in that grep):

| Site | What it writes into `externalid` |
|---|---|
| `AdviceRestController.java` — `adviceEntity.setExternalid(adviceDto.getReferenceId());` | OMS-supplied `reference_id` |
| `FileImportController.java` — `advice.setExternalid(adviceDto.getReferenceId());` | spreadsheet `reference_id` |
| `ReceivingService.java` — `advice.setExternalid(String.valueOf(System.currentTimeMillis()));` | **epoch millis** |

### The discriminating measurement

```sql
SELECT type,
       count(*) AS advices,
       count(*) FILTER (WHERE abs(EXTRACT(EPOCH FROM created) - (externalid)::bigint/1000.0) < 5)
         AS matches_created_within_5s,
       min(abs(EXTRACT(EPOCH FROM created) - (externalid)::bigint/1000.0)) AS min_delta_sec,
       max(abs(EXTRACT(EPOCH FROM created) - (externalid)::bigint/1000.0)) AS max_delta_sec
FROM advice WHERE externalid ~ '^[0-9]{13}$' GROUP BY type;
```

→ `REGULAR | 235 | 235 | 0.000949 | 0.027783`

All 235 REGULAR advices have a 13-digit all-numeric `externalid` whose value **equals the row's own
`created` timestamp to within 0.9–28 milliseconds**. That is `System.currentTimeMillis()` captured a
few statements before the INSERT, i.e. `ReceivingService`. It cannot be an OMS-supplied
`reference_id`: a value generated on the OMS side sits behind an HTTP round-trip plus
`validateWarehouse`, the duplicate-`referenceId` read, client/SKU lookups and the position loop
before the advice INSERT — a floor well above 28 ms, and it would have to be met 235 times out of
235. The 2 RETURN advices, by contrast, carry `RETURN83031` / `RETURN83093` — OMS-shaped reference
ids — and are the 2 that have ADVICE_IMPORT rows.

*(Derivation of "235 of 235": a single grouped SQL aggregate over the whole `advice` table, no
sampling. Blind spot: it only proves the two columns co-vary; a hypothetical OMS that echoed the
WMS insert time back as its own reference id would also satisfy it. No such mechanism exists —
`reference_id` arrives in the request body before the row exists.)*

### Corroboration

1. **`ReceivingService` contains no `createMessage` call.**
   `git grep -n "createMessage\|MessageProcessType" origin/develop -- .../ReceivingService.java` →
   no match. Its only `BasicService` use is
   `advice.setNumber(basicService.generateNumber(EntityPrefixes.ADVICE, "ADVICE"));`.
2. **Its entry point is an operator screen, not OMS.** `AdviceController.java`:
   `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_CREATE_INBOUND_BOL)` /
   `@PostMapping(path= "/create", ...)` → `receivingService.createAdviceWithPositions(...)`,
   returning `"CREATED INBOUND BOL"`. Request body is `{bolNumber, supplier, ..., itemLines}` —
   a hand-keyed BOL, nothing resembling the OMS `AdviceDto` contract.
3. **The sequence burn is not adjacent to the advice imports.** Grouping every gap by the
   `(preceding process, following process)` pair (full-table window function, no sampling):

   | preceding | following | intervals | burned |
   |---|---|---|---|
   | ADVICE_CLOSE | ADVICE_CLOSE | 206 | 221 |
   | ORDER_BATCH_PICKING_STARTED | ORDER_BATCH_PICKING_STARTED | 77 | 80 |
   | ORDER_BATCH_PICKING_RELEASED | ORDER_BATCH_PICKING_STARTED | 29 | 29 |
   | *(18 further pairs)* | | | ≤12 each |

   Those top three account for 330 of the 402 burned numbers. Exactly **one** interval in the whole
   table touches an ADVICE_IMPORT row (`STOCK_UPDATE → ADVICE_IMPORT`, 3 burned, before the
   2026-09-23 RETURN import). The ticket's reading — *"the burn sits exactly where an advice import
   precedes its close"* — mis-locates it: the burns sit **between two consecutive rows of the same
   outbox-dispatched process type**, not at an import/close boundary. On the ADVICE_CLOSE lane the
   surviving numbers run `43, 45, 47, 49, 51, 53, 55, 57, 59 …` — one number burned between each
   successive pair, with inter-row gaps of 60–300 s (the dispatcher's own cadence).
4. **The control works.** The sibling endpoint on the identical pattern — non-`@Transactional`
   controller → `messageService.createMessage` → self-invoked `createServiceLog` → `save` — has
   156 `ORDER_BATCH_IMPORT` `RECEIVED` + 26 `FAILED` rows. So "controller writes its own service-log
   row" is not broken in this deployment. A zero-scan that agreed with the hypothesis would have
   been the trap here; this is the positive control that rules it out.
5. **Both exits of `create()` are accounted for.** The one `FAILED` row is 0.64 s after
   `RETURN83031`'s `advice.created`, the one `RECEIVED` row 0.74 s after `RETURN83093`'s. One
   import was rejected after the advice row had already committed (consistent with
   `create()` not being `@Transactional`), one succeeded. Nothing missing.

### A near-miss discriminator, recorded so nobody re-uses it

`advice.number` is **not** a discriminator. Both paths call
`basicService.generateNumber(WmsConstants.EntityPrefixes.ADVICE, "ADVICE")`, and
`WmsConstants.java` has `public static final String ADVICE = "IBOL";`. The 237 advices run
`IBOL000001`–`IBOL000237` across both origins. `FileImportController` *is* separable this way —
it hard-codes `advice.setNumber("TESTONLY123");` — and zero rows carry that value, which is how
the file-import path is excluded.

## Hypothesis table

| Rank | Hypothesis | Confidence | Evidence strength | Status |
|---|---|---|---|---|
| 1 | **The 235 REGULAR advices never passed through `create()`; they are `ReceivingService` inbound BOLs, and no row is owed.** | **High** | **Strong** — tier 2 primary artifact (235/235 column co-variance at ms resolution) + three independent corroborations + a working positive control | **Accepted** |
| 2 | Row written inside a `TransactionSynchronization.afterCommit()` and silently discarded (ticket hypothesis 2) | Medium | Moderate | **Wrong for AC-1, right for the 402 burn** — see below |
| 3 | An ambient filter/interceptor transaction wraps the handler (ticket hypothesis 1) | Very low | Strong *against* | **Rejected** |
| 4 | The write throws and is swallowed (ticket hypothesis 3) | Very low | Strong *against* | **Rejected** |
| 5 | REGULAR/RETURN diverge in transaction context before the write (ticket hypothesis 4) | Very low | — | **Dissolved** — they diverge in *origin*, not in transaction state |

### Evidence against hypotheses 3 and 4 (recorded because they were the ticket's front-runners)

- **H3 (ambient transaction).** `spring.jpa.open-in-view=false` in
  `src/main/resources/application.properties`, so no `EntityManager` is bound per request.
  `IdempotencyFilter` is an `OncePerRequestFilter` carrying no `@Transactional`; it delegates to
  `RestIdempotencyService`, whose transactions are its own. With no ambient transaction,
  `SimpleJpaRepository.save` (`@Transactional`, REQUIRED) opens and commits its own tenant
  transaction — `TenantDatabaseConfig` fixes the manager via
  `@EnableJpaRepositories(..., transactionManagerRef = "tenantTransactionManager")`, so there is no
  landlord-manager mix-up either. Nothing here can discard the insert.
- **H4 (swallowed throw).** The enclosing `try` catches only `IOException`, and the outer `catch`
  only `WebserviceBusinessExceptionClientSide`. A `RuntimeException` or `BusinessException` out of
  `createServiceLog` would therefore escape `create()` and return 500 to OMS, 235 consecutive times,
  on advices that nonetheless committed. More decisively, `writeServiceLog` in
  `OutboxDispatchService` resolves the *same* two sysprops
  (`syspropService.getWmsInstanceName()` / `getOmsInstanceName()`) and persists 231 ADVICE_CLOSE
  rows through them — so neither sysprop lookup throws in this tenant.
- **H4-variant (serialization).** `WmsObjectMapper.shared().writeValueAsString(adviceList)` throwing
  a `JsonProcessingException` (an `IOException`) would be caught and logged as
  `"Advice import service log failed"`, losing the row with **no** number burned. This was a genuinely
  live candidate until finding #3 showed there is no ADVICE_IMPORT-adjacent burn to explain and
  finding #1 showed there is no import to serialize.

## Rebuttal round

**Best challenge to the leader.** "235 of 235 is suspiciously total. Hydra PRD went live 2026-07-12
and OMS *does* send advices — if no REGULAR advice ever arrived over `/rest/advice/create` in three
months, the import path is dead and that is its own bug."

**Why the leader still stands — and what the challenge legitimately wins.** It does not touch the
causal claim: the 235 rows provably did not come through `create()`, so no row is owed for them. But
the challenge is correct that the *absence* is itself a finding, and it is the strongest thing to
carry forward. Two readings survive and this trace cannot separate them: (a) OMS was never
configured to push inbound advices to this tenant and inbound BOLs are keyed by hand — in which case
AC-1 should be closed as not-a-defect; or (b) OMS does push them and they are failing upstream of
`create()`, in which case 235 hand-keyed BOLs are compensating for a broken integration and that is
a larger problem than the audit row. Note (b) would *not* produce a FAILED ADVICE_IMPORT row: a
request rejected before the handler (auth, `IdempotencyFilter`, a 404 route) never reaches either
`createMessage` call site.

## Convergence / separation notes

Ticket hypothesis 2 (`afterCommit` discard) is **separately true and is the real defect in the
measured data** — it just explains the 402 burned sequence numbers, not the ADVICE_IMPORT rows. The
two must not be merged.

`OmsNotificationService.sendAfterCommit` registers a synchronization whose `afterCommit()` calls
`doSend`, which calls `messageService.createMessage`. Inside `afterCommit`,
`EntityManagerHolder.transactionActive` is still set (`processCommit` runs `triggerAfterCommit()`
before `cleanupAfterCompletion()`), so `SimpleJpaRepository.save` — default REQUIRED — **joins** the
completing transaction and its participant commit is a no-op; the insert is never flushed. The
REQUIRES_NEW sequence allocation one line earlier is on a different bean
(`SequenceTransactionService`), so its proxy does fire, it suspends and commits alone, and the
number is spent. That is the mechanism already confirmed against spring-tx/spring-orm sources in
`sbdocs/1-Projects/wms1/plan/SBDEV-3266-oms-message-rows-lost-in-aftercommit.md` §2.1/§2.3, and
`OmsNotificationService`'s own SBDEV-3267 comment states the premise it rests on: *"Inside an
afterCommit() callback isActualTransactionActive() is still TRUE"*.

Consistency check: the branch is reached only from a genuinely transactional caller. Callers that
reach `sendAfterCommit` with no transaction open take the `else` branch and call `doSend`
synchronously, where `save` opens its own transaction and the row survives. That is why
`ORDER_BATCH_PALLETIZED` (dispatched via `omsNotificationService.sendAfterCommit` in
`ManageOrderService`) has 266 intact rows while `STOCK_UPDATE` has 28.

## Secondary question — ORDER_BATCH_PICKING_STARTED

**Reframed, and I am explicitly less sure of this than of AC-1.** The lead asked what is
structurally different about the PICKING_STARTED *producer*. On this evidence, **nothing is** — the
burned number is not produced by the PICKING_STARTED path at all. It lands *between* two
PICKING_STARTED rows because that is the window in which stock-moving work runs, and the lost row is
a co-temporal `STOCK_UPDATE`.

Supporting chain:

- `MessageService.sendStockChangeMessage` → `stockChangeNotificationService.sendAfterCommit(...)` →
  `omsNotificationService.sendAfterCommit(urlPath, payload, STOCK_UPDATE)` — i.e. every stock-change
  notification goes through the discarding path above.
- Its call sites sit inside `@Transactional(tenantTransactionManager)` service methods, so they take
  the `afterCommit` branch. Confirmed at one: `GoodsReceiptPositionService` has
  `@Transactional(value = "tenantTransactionManager", rollbackFor = {...})` immediately above the
  method that calls `messageService.sendStockChangeMessage(list);`. There are 17 such call sites
  (`git grep -n "sendStockChangeMessage" origin/develop -- src/main`, counting call sites and
  excluding comments and the declaration itself); I verified the enclosing annotation on one of the
  17, not all of them — that is the weakest link in this chain.
- Quantitatively: 233 `goodsreceipt` rows and 221 numbers burned on the ADVICE_CLOSE lane;
  522 `goodsreceiptposition` rows; only 28 `STOCK_UPDATE` rows survive. A ~1:1 burn-per-receipt
  ratio is what the mechanism predicts. This is a numeric coincidence, not proof of identity —
  a burned number carries no timestamp and no process, so it cannot be labelled from SQL alone.
- Why the siblings burn zero: `ORDER_BATCH_PICKING_FINISHED`, `_PALLETIZED` and `_QA_FINISHED` fire
  after the stock movement has finished, so no `sendStockChangeMessage` commit falls between two of
  their rows. `_PICKING_RELEASED` fires before picking starts and burns 9. This is the part of the
  secondary explanation I would most want a runtime check on.

The same reframing applies to `ADVICE_CLOSE`, which is the larger burn lane (221) and which the
ticket does not currently list as affected.

## Critical unknown

**Has `PUT /rest/advice/create` ever been invoked for a REGULAR advice on Hydra PRD?** Everything
downstream of AC-1 turns on it: if no, AC-1 is closed as not-a-defect and SBDEV-3674 should be
re-pointed at the `afterCommit` row discard; if yes, there is a silent inbound-integration failure
upstream of the handler that is strictly more serious than the missing audit row.

## Discriminating probe (single highest value)

Grep the Hydra PRD wms2-api application log for the handler's own entry line, which fires before any
persistence and before either `createMessage` call site, and is therefore the one signal that
separates "never called" from "called and the row was lost":

```
LOG.info("create called with {}", adviceList.size());     # AdviceRestController.create
```

In the same pass collect the two lines that would witness a loss —
`"Advice import service log failed"` (the swallowed `IOException` branch) and any stack trace from
`AdviceRestController` — plus the OMS side: whether `oms-laravel-api`'s `WmsApiService` has a
configured `PUT {host}/rest/advice/create` endpoint for this tenant and what it logs.

- **Zero `"create called with"` lines + no OMS caller configured** → AC-1 is not a defect. Close it,
  correct the ticket's `externalid` inference, and re-point the ticket at the `afterCommit` discard.
- **`"create called with"` lines present with no matching `message` row** → my leading hypothesis is
  wrong; go back to hypotheses 3/4 with the stack traces in hand.
- **Zero lines but OMS *is* configured to call it** → the real bug is inbound requests dying before
  the handler; escalate past AC-1.

Second probe, for the burn and the secondary question, both of which need runtime evidence rather
than SQL: raise `net.aim_ai.wms.service.MessageService` to DEBUG on one tenant and compare
`"end with created message={}"` occurrences against committed `message` rows over the same window.
`createServiceLog` logs that line after `messageRepository.save(m)` returns — and under the
`afterCommit` mechanism it returns *normally* while the insert is discarded, so a DEBUG line with no
row is a direct sighting of the discard. A reproduction is cheap and would be stronger still: call
any `sendStockChangeMessage` site from a `@Transactional` test method against Testcontainers
Postgres and assert on the `message` row count — but that is `mvn`, which this lane was told not to
run.

## Uncertainty notes

- **AC-1 verdict: high confidence.** Resting on a primary artifact with tight provenance, not on
  code reading. The one thing it does not establish is *why* no REGULAR advice arrived over the REST
  path — see the critical unknown.
- **The 402-burn mechanism: medium-high.** The mechanism itself is confirmed (v1 SBDEV-3266 against
  spring-tx sources; `OmsNotificationService`'s own SBDEV-3267 comment states the
  `isActualTransactionActive()` premise). What is inferential is the *identity* of the lost rows:
  SQL cannot label a number that has no row. The 1:1 ratio and the lane clustering are consistent
  with `STOCK_UPDATE`, not proof of it.
- **The secondary question: medium.** The reframing ("the PICKING_STARTED producer is not the
  burner") is well supported by the pair-grouped gap table. The positive identification of
  `STOCK_UPDATE` as the burner is not, and the sibling-lane asymmetry
  (`_PICKING_RELEASED` 9 vs `_PICKING_STARTED` 80) is not fully explained by it.
- **Not checked:** whether other tenants (ShipItEZ, WineCo on v2 PRD) show the same `externalid`
  shape split. If they show real OMS-shaped REGULAR reference ids with missing ADVICE_IMPORT rows,
  AC-1 is alive there even though it is not alive on Hydra. **This is worth one query before the
  ticket is closed** — the three PRD MCP servers (`nywh-shipitez-prd`, `c1wh-shipitez-prd`,
  `wsl-wineco-prd`) all failed to connect in this session, so I could not run it.
