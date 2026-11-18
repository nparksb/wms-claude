# SBDEV-4007 P1 — Phase 3b security review (transcribed by lead; lane cannot write files)

Reviewed: `git diff 68a20d76..311e93e9`, worktree `.claude/worktrees/wms2-api/SBDEV-4007`. Lane: oh-my-claudecode:security-reviewer, 2026-11-04.

**Verdict: no blocking findings; overall risk LOW.** 1 Medium, 6 Low.

Checks:
- **SQL:** all 11 native statements bind every value as `:param`, including `make_interval(secs => :leaseSecs)`. No concatenation, no dynamic ORDER BY.
- **Authz:** POST `/clubRunJobs/{id}`, GET `/clubRunJobs/{jobId}` and GET `/byBatch/{id}` carry `@RequiresFunction(WEB_UI_VIEW_CLUB_LINE)`, the same as `runClubLine`. `/v3/**` also requires `wms_user`.
- **Tenant isolation holds:**
  - Each tenant DB has its own table and its own ids.
  - The kick runs afterCommit on the request thread.
  - `TenantAwareTaskDecorator` carries the tenant onto the worker thread.
  - The poller sets the tenant, then submits; claimTask re-sets it; both clear in `finally`.
- **DoS bounded:** the partial unique index plus ON CONFLICT allows one live job per batch. The executor has queue 0 and a discard handler.
- **Migration:** no GRANT and no OWNER (the V2.2.42 precedent). Idempotent. No secrets.
- **Not issues:**
  - CSRF: the API is stateless bearer-token.
  - The DTO hides `requested_by` and `lease_owner`.
  - The repo is not SDR-exported.
  - The routes do not collide.

| # | Sev | Site | Issue | Fix |
|---|---|---|---|---|
| 1 | MEDIUM | `ClubRunJobWorker` `abandon(lease, e.toString(), …)`; `"failJob failed (" + e + ")…"`; `RUNTIME_FAILURE_PREFIX + e.getMessage()` | Raw exception text (SQL, constraint and column names, FQCNs) goes into `last_error`. The status DTO, `/byBatch` and the legacy GET `errors[]` return it to clients, even while the job is RUNNING after an abandon | Keep the full text for operators. Clients see only Business/Facade messages; everything else becomes "Club run failed (job N); see server log" |
| 2 | LOW | `ClubLineController` async branch `catch (RuntimeException e) … "Club line processing failed: " + e.getMessage()` | New leak: a raw RuntimeException message in a 200 body, where it used to be a generic 500 from RestExceptionHandler | Fixed message plus job id; the exception is already logged |
| 3 | LOW | `ClubRunJobService.awaitTerminal`, 500 ms poll for up to 45 s | Each legacy GET holds a Tomcat thread and makes about 3 queries per tick | Optional cap on waiters (semaphore, then QUEUED), or compute `processed` only on the final read |
| 4 | LOW | `ClubRunJobService.submit`: `findByOrderbatchId` before `insertIfNoLive` | Repeated POSTs load every order before finding the live job | Check `findLiveByOrderbatchId` first and return early |
| 5 | LOW/Info | GET `/clubRunJobs/{jobId}` takes a sequential Long | Job ids can be enumerated within a tenant. No privilege gain, but it amplifies #1 | Accept, or scope the read by batch |
| 6 | LOW | `app.clubline.job.workers=2` per JVM, shared by all tenants | One tenant's backlog can starve the others; their jobs sit QUEUED | Per-tenant cap, or document it and size the pool |
| 7 | LOW | Poller every 4 s, every replica, every active tenant | Constant claim UPDATEs keep every tenant pool warm, so TenantPoolEvictor never evicts | Cheap existence check, or per-tenant backoff after an empty claim |

Lane's fix order: #1 and #2 together (one sanitizer). #3–#7 backlog or accept with a note. Per Nam's rule, Lows get fixed too; lead decides per row in the fix pass.
