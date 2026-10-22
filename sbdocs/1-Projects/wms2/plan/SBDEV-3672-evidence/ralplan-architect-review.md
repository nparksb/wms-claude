---
ticket: SBDEV-3672
kind: ralplan step 3 — Architect review (deliberate mode)
date: 2026-10-13
plan_snapshot: SBDEV-3672-chunk-bol-shipped-notification.md (draft, after Nam's D4/D5/D7 answers)
verdict: APPROVE WITH CHANGES (iterate once, small)
note: saved by the main session; the architect agent is read-only
---

# SBDEV-3672 — Architect review

Core design sound: per-chunk bound at the producer, independent chunk aggregates, unchanged single row for ≤K, LANE_CLUB. 49/50 citations OK. No High. Five Medium to fold in before the TDD gate.

## Citation spot-check — 50 claims, 49 OK, 1 WRONG

WRONG: §7 Prereq 1 "Flyway at V2.2.38 on every tenant". All four PRD DBs report latest V2.2.37 (installed 2026-10-08); V2.2.38 is on develop, unreleased. Reword: "V2.2.38 applied, or ships in the same release ahead of V2.2.39".
Also: analysis §3 says "Lane DEFAULT" and key `…-C<i>`; superseded by D7 (LANE_CLUB) and D2 (`…-C<i>of<N>`) — annotate the analysis.
OK examples: BOLS:800-806 single enqueue; :391-400 four types; :753 bol_id=getName(); :779-785 empty skip; ODS:71 STALE 15 min; ODS:181/:193 maxAttempts; ODS:299-302 isTerminal; ODS:152-157 no tx in Phase 2; OS:97-98 backoff (86,580 s sum correct); OS:125-135 lane-scoped reclaim; OMR:44 claim statuses, :46-52 gate incl. FAILED_TERMINAL, :80-86 SENT-only purge, :102-115 stuck gauge; ODJ:62/83-86 two lanes; CustomerorderBatchService:889,900,916,1034 only `.lane(` users; BillOfLadingController:237-238 closeOutboundBol gate; LWC:2130-2138, 2181-2188, 2313-2319, 2426-2432, 2523 (callback only SUCCESS parcels; NOOP excluded :2434-2435), 2537-2545; web-ui admin.vue:62, outboundBolDetails.vue:73, outboundBols.js:161, serviceLog.vue:279/305.

## Findings

| ID | Sev | Finding | Failure scenario | Fix |
|---|---|---|---|---|
| M1 | Medium | Requeue audit trail lives in `last_error`; `markRetry`/`markTerminal` overwrite it (OS:101,115). D-ii deletion has no durable record | Requeue annotation gone ~15 s later; merchant asks why a second outbound_bol_close arrived — no record | One Service Log (`message`) row per requeue: process `ORDER_BATCH_SHIPPED_REQUEUE`, operator = principal, answer = {bolId, outboxIds, mode, deletedOriginalId, payloadBytes}, inside the requeue tx; destination must NOT be an OMS URL (SBDEV-3325 would count it as egress) |
| M2 | Medium | D-ii has no row lock, no status-guarded DELETE, no rowcount check | Double click / two replicas both re-chunk 11135 → second hits uk_outbox_message_idempotency_key → 500 | `SELECT … FOR UPDATE`; re-check FAILED_TERMINAL; `DELETE … WHERE id=:id AND status='FAILED_TERMINAL'`, assert rowcount=1; loser → `{requeued:0}`/409, never 500; two-thread IT |
| M3 | Medium | Service Log resend (which the deep link invites) never updates the outbox row → BOL stays FAILED after a successful manual repair (MessageService.resendMessage:162-215 posts directly, links via redeliver_id) | Operator resends, OMS 200, BOL screen still "1 failed"; clicks Requeue → pointless re-POST | Status query: `LEFT JOIN message r ON r.redeliver_id = o.last_message_id AND r.statuscodeanswer ~ '^2'` → "delivered via manual resend"; or hide Resend for linked outbox messages (needs Nam's yes if accepted as gap) |
| M4 | Medium | Mapping `last_message_id` on the entity couples every outbox SELECT/INSERT/UPDATE on a tenant to V2.2.39 having applied; tenant Flyway failures never abort boot | Tenant stalls before V2.2.39 → every pack/close/QA enqueue on that tenant fails `column last_message_id does not exist` | Native-only access (link UPDATE + status query); no entity field |
| M5 | Medium | 24 h retries × CLUB lane shared across all tenants on the deployment (ODJ:136-139), no per-tick fairness | One tenant's OMS hangs: 39-chunk BOL costs ~13 min CLUB lane per retry wave, ~hourly for 24 h; other tenants' club notices lag | Document in R-3 with this arithmetic; name the fallback trigger (dedicated lane or per-type claim cap); alert on tick_duration{lane=CLUB} once scraped |
| L1 | Low | Prereq 1 says V2.2.38 on every tenant; PRD at V2.2.37 | Checklist blocks / hand-fix on PRD | Reword |
| L2 | Low | Link write via entity save bumps @Version + modified_at (feeds reclaim OMR:76 + watchdog ordering) | Reclaim/watchdog inputs shift | Native `UPDATE outbox_message SET last_message_id=:mid WHERE id=:id` |
| L3 | Low | U11 must inject the link failure in the 2xx branch (markSent at ODS:178 is inside the try; catch at :192 would re-mark a SENT row) | Refactor moves link outside guard; SENT row re-POSTed while test stays green | U11 in 2xx branch; verify markRetry/markTerminal never called |
| L4 | Low | D-i/D-ii reuse stored destination_url | 404 URL-misconfig terminal requeued straight back to 404 | D-ii (and D-i for this process type) use current ORDER_BATCH_SHIPPED URL sysprop |
| L5 | Low | V2.2.39 has no lock_timeout | ALTER queues behind a long close tx in rolling boot; enqueues stall | `SET lock_timeout = '5s';` at top |
| L6 | Low | Legacy row shows "0/1"; IN_FLIGHT requeue returns 0 silently; stale analysis text | Operator confusion | Label "1 legacy notification (N parcels)"; message "in flight, nothing to requeue" |
| L7 | Low | Shipped notice on CLUB vs CUSTOMER_ORDER statuses on DEFAULT can invert | Late PACKED after SHIPPED at OMS (impact unverified) | Ask OMS whether a late PACKED/LOADED can regress a SHIPPED parcel |
| L8 | Low | Watchdog red up to ~24 h for one poisoned row on a low-traffic tenant | Hydra watchdog red overnight | Document WATCHDOG_ACK in watchdog README |

Status arithmetic: correct for partially purged chunked BOLs (all N inserted in one tx; surviving rows carry `of<N>`), unchunked single row (N=1; no second BILL_OF_LADING row possible: BOLS:381-386, :1572-1578, :379-380) and transfers. Breaks only if rows leave other than via SENT purge or D-ii: (a) operator DELETE of FAILED_TERMINAL → reads as confirmed; (b) M3.

Flyway (measured PRD 2026-10-13): outbox_message owned by tenant app role on all four PRD DBs; V2.2.30 ALTER on it applied everywhere; sizes 64 kB–8 MB; ADD COLUMN without default is metadata-only.

Watchdog: detection stays correct; a failing 39-chunk BOL writes ~1,170 message rows over 24 h (bounded by retention).

## Principle check

- Bound at producer — upheld. Independent chunks — upheld. Gate on screen function — upheld.
- No change for small/transfer/other types — deliberately bent by D4 (Nam); silently bent by M4 (entity column) until fixed.
- Every failure visible+fixable from BOL screen — partially violated by M3.

## Consensus addendum

- Antithesis: Fixes B+D more than double the change surface (PRD schema change, Phase-2 write, two endpoints, UI, the codebase's only destructive outbox path) for a population of exactly one terminal oversized row (11135). With Fix A bounding POSTs to ~7.6 s and Fix C giving 24 h, terminal BOL notices become rare; D-ii is a one-shot migration shipped as a permanent feature. Cheaper: A + C + one-off replay, defer the UI.
- Tension: operator self-service recovery vs change surface / divergence from the system of record (M3 is that divergence already).
- Synthesis: keep Nam's decisions but shrink blast radius — native-only column (M4); D-ii locked, guarded, audited, narrow (REGULAR/HUB_AND_SPOKE, FAILED_TERMINAL, single row, parcels > K) (M1, M2); status reconciles manual resends (M3); consider retiring D-ii after 11135 is replayed and a release cycle shows no candidates.

## Overall: APPROVE WITH CHANGES

Fold M1–M5 and the Lows into the plan before wms-tdd-gate. No decision Nam made is technically unsound; D-ii and the link column are sound only with the M1/M2/M4 guards.
