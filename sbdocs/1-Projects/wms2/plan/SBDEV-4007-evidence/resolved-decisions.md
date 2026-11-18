# SBDEV-4007 — pre-draft resolved decisions (Nam, 2026-11-04)

| # | Question | Decision |
|---|---|---|
| D1 | Phasing | **Phased.** P1 API: queue table, claim/lease worker, per-order progress, submit + status endpoints, old sync GET kept working. P2 web-ui submit-and-poll. P3 outbox kick on workflow finish. Each phase separately reviewable/revertable. |
| D2 | Old `GET /v3/clubLine/runClubLine/{batch}` | **Keep, delegate.** Stays for back-compat (mobile UI, cypress) but enqueues the run and waits (bounded) for completion — one execution path. |
| D3 | Worker dies mid-run | **Auto-resume.** Lease expiry → another replica claims and continues from the next unprocessed order. |
| D4 | Ingress-timeout measurement (§5.1) + per-tenant chunking enablement (§2) | **Prerequisites only** — §5.1 operator prerequisites with owners; no code. |

Triage facts (2026-11-04): dev `los_sysprop.WMS_CLUBLINE_OMS_CHUNK_SIZE` = `100` (modified 2026-11-03 23:13 UTC), no club run since; wsl-wineco-prd = `1`; prd largest CLUB batches last 45 d: 328/275/256/121/118 orders, all state 700.
