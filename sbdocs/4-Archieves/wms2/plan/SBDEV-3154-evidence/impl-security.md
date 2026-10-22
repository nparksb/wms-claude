# SBDEV-3154 — security review of the implementation

> ⚠ **Credential values redacted 2026-09-01.** A review lane pasted the live OMS API password
> here verbatim. The *finding* — that the same OMS Basic-Auth credential is byte-identical on
> wineco-dev and Hydra PRD, and is attached to the outbound call `testCrmConnectivity` fires at a
> sysprop-chosen URL — stands and is the point. The value itself does not belong in a document.
> Re-derive it from the environment if you need it.


- **Lane:** security (read-only, no builds, no maven, no file changes outside this report)
- **Reviewed:** worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3154`,
  branch `bugfix/SBDEV-3154-admin-action-console-gating`, base `origin/develop` `2e757457`
- **Date:** 2026-09-01
- **Diff under review:** 3 files —
  `src/main/java/net/aim_ai/wms/controller/AdminActionController.java` (+5 method-level
  `@RequiresFunction(WEB_UI_VIEW_IMPORT_DATA)`, +1 import),
  `src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java` (+8 pin rows, 123→131),
  `src/test/java/net/aim_ai/wms/unit/controller/AdminActionConsoleGateUnitTest.java` (new, 4 tests)

---

## 0. Enumeration method, and its blind spots

Stated first because several conclusions below are closed-set claims and are only worth what the
method is worth.

**Method.**

1. For each of the five gated handlers, read the body and identified the **terminal collaborator
   call** (`orderReleaseJob.doCalculation`, `replenishJob.doCalculation`,
   `cleanUpOldMessagesJob.doCalculation`, `httpRestService.get(<sysprop>)`,
   `unitloadBusinessService.listRecoverableStuckPallets` / `.recoverPalletFromNirvana`).
2. `grep -rn` that symbol across the whole of `src/main/java`, then read every hit to separate
   HTTP entry points from cron entry points from comments. `SchedulingConfiguration.java` was read
   directly rather than inferred, so cron sites are covered by reading and not by grep alone.
3. For the *effect* rather than the symbol, enumerated Spring Data REST reachability by reading
   `RestConfiguration.java` **in full** (`exposeIdsFor`, `SDR_WRITE_WITHDRAWN`, door ①, the
   access-chain block) plus every `@RestResource(exported = …)` on each repository involved, plus
   `SdrFunctionRules` and `SdrGuardModeProvider`.
4. Read `FunctionGuardInterceptor.preHandle` end to end to confirm the resolution path a method-level
   annotation on a **non-`GUARDED`** class actually takes, and `WebConfig` to confirm the
   `MappedInterceptor` pattern covers the paths.
5. UI callers: `git grep` (index-based, so `wms2-web-ui`'s bare `reports/` gitignore cannot hide a
   caller) in both `v2/wms2-web-ui` and `v2/wms2-mobile-ui`.
6. DB facts: read-only SQL on `wms2-wineco-dev` and `wms2-hydra` (PRD).

**Blind spots, all load-bearing.**

- **No live HTTP request was issued.** Every statement about Spring Data REST reachability below is
  **configured**, read out of `RestConfiguration` and the repository annotations. It is *not*
  measured. Where I say a verb is "published" I mean SDR's exposure configuration does not withdraw
  it; I do not claim the write executes. (`A 400 from an SDR write verb proves nothing` — so I did
  not probe and do not lean on a probe.)
- Cross-repo UI claims come from the **local `v2/wms2-web-ui` and `v2/wms2-mobile-ui` checkouts on
  branch `develop`, not fetched**. They may lag `origin/develop`. The finding they support (F3, that
  the only caller of `listRecoverableStuckPallets` is the System-Management modal) would only get
  *stronger* if a caller were added, so the direction of the risk is known; but the count is not
  authoritative.
- Symbol grep cannot see reflective or proxy-mediated dispatch, nor string-driven scheduling. I
  mitigated the scheduling half by reading `SchedulingConfiguration`; the reflective half is open.
- **Inherited alias routes were read, not executed.** `AdminController` declares 8 handlers under
  `@RequestMapping("/v3")`, so `AdminActionController` also serves them under
  `/v3/adminAction/user/findUsers` etc. All 8 carry `@PreAuthorize(Authority.IS_SB_ADMIN)`. Method
  security is not exercisable in any test lane in this repo (that asymmetry is the stated design
  reason `@RequiresFunction` exists), so this is a code read only.
- I did not re-derive the six-tenant holder census the prior lane established. I independently
  re-derived **Hydra PRD only** (§2, agrees).

---

## 1. Q1 — Does this reduce exposure, or is it cosmetic? Per-route verdict

`AdminActionController` is not in `FunctionGuardInterceptor.GUARDED`, and each of the five carries a
**method-level** annotation, so `preHandle` reaches it at
`RequiresFunction methodLevel = handlerMethod.getMethodAnnotation(...)`
(`FunctionGuardInterceptor.java:214`) before the `!GUARDED.contains(declaring)` fall-through at
`:246-248`. The declaring class of all five is `AdminActionController` itself, so the 43-subclass
alias problem does not apply. `WebConfig:86-87` registers the guard as
`new MappedInterceptor(new String[]{"/**"}, functionGuardInterceptor)`, so the pattern covers
`/v3/adminAction/**`. Concur with the prior lane: the gate genuinely fires. Not disputed.

| Route | Effect | Every other route reaching that effect | Verdict |
|---|---|---|---|
| `POST /v3/adminAction/recoverStuckPallets` | `recoverPalletFromNirvana` — relabel (restore or mint), relocate to EmptyPallets, clear `GOING_TO_DELETE`, write `CONTAINER_RELOCATED_EMPTYPOOL` audit row | **None.** `recoverPalletFromNirvana` has exactly one caller repo-wide (`AdminActionController:297`). Effect components separately: `Unitload` SDR writes withdrawn (`RestConfiguration` `SDR_WRITE_WITHDRAWN`); `MoveUnitloadController` is in `GUARDED` and gated; `UnitLoadController.bulkDeleteContainer` is the *inverse* direction and gated on `WEB_UI_ACTION_DELETE_UNIT_LOAD`; `UnitloadRestController` (`/rest/**`, `permitAll`) declares **one** handler, `GET /rest/unitload/state/{labelId}`, a read. | **REAL.** Sole route to the mutation. Blast radius measured: 7 candidate `Pallet` rows on Nirwana with `entity_lock=2` on wineco-dev; **0 on Hydra PRD** (no `Pallet`-type unit load sits on Nirwana at all there). |
| `GET /v3/adminAction/triggerOrderReplenish` | `orderReleaseJob.doCalculation(false)` + `replenishJob.doCalculation(false)` | `orderReleaseJob.doCalculation` — exactly 2 sites, here and `SchedulingConfiguration:204`. `replenishJob.doCalculation` — exactly 2, here and `:227`. So the warehouse-wide sweep has no second HTTP route. | **REAL for the sweep.** The plan's caveat that per-item replenishment stays unfenced is **accurate** — `triggerReplenishmentMaintenance` → `recalculateForItem` runs as a swallowed side effect of ordinary writes, unreachable by gating this route. |
| `GET /v3/adminAction/triggerArchiveMessages` | `cleanUpOldMessagesJob.doCalculation(false)` → archive + batch-delete `message` (the Service Log) | 2 sites: here and `SchedulingConfiguration:181`. `MessageRepository.archiveMessages` / `.deleteMessages` are `@RestResource(exported = false)` (`:30-42`); `Message` **and** `MessageArchived` are both in `SDR_WRITE_WITHDRAWN`, so `DELETE /v3/message/{id}` is withdrawn. | **REAL for the API surface.** One residual, via the cron and a writable sysprop → **F6**. |
| `GET /v3/adminAction/testCrmConnectivity` | `httpRestService.get(<WEBSERVICE_TEST_CRM_CONNECTIVITY>)` + 1 `message` row | The *class* of effect (outbound HTTP to a sysprop-chosen host, with the OMS Basic-Auth credential attached) has **19+ other producers** on paths needing no function: `OmsNotificationService:108`, `OutboxDispatchService:148`, `AdviceService:263/363/434`, `BillofladingService:704/1417`, `StockSummaryExportJob:308`, `MessageService:123`, `ItemDataController:120`, `PickingorderBusinessService`, `CustomerorderBatchService`, … | **PARTIAL.** Closes the *self-service* variant (one `wms_user` could previously both rewrite the URL and press the button); degrades it to a stored/confused-deputy SSRF. The SSRF class itself is untouched. Correctly caveated; impact understated → **F2**. |
| `GET /v3/adminAction/listRecoverableStuckPallets` | read: triaged stuck-pallet list | `findRecoverableStuckPallets` is `@RestResource(exported = false)` (`UnitloadRepository:281`) so the query has no SDR route — but the **rows** are reachable in two ungated SDR GETs → **F3**. | **COSMETIC for the data; coherent for the screen.** It closes the triage computation, not the existence of the pallets. |

**What is NOT gated on this controller after the change** (3 of 8 handlers; `accessAudit` is
`@PreAuthorize(IS_SB_ADMIN)` and correctly untouched):

- `GET /triggerUpdateStock` — the `/rest/stockcount/triggerStockCount` rationale is **verified**:
  `StockCountRestController` injects `StockSummaryExportJob` and is mapped under `/rest`, which is
  `permitAll()` at `SecurityConfiguration:150-154`. Gating only the `/v3` copy would achieve nothing.
  Correct call.
- `GET /triggerReleaseExpiredPickingOrdersFromUser` — mutating, ungated, **zero UI callers in either
  UI**. Guarded in practice only by two syspropes (`NEW_CRON_JOB_ACTIVATED` **and**
  `PICK_TIME_OUT_SYSTEM_ACTIVATED`, `ReleaseExpiredPickingOrdersFromUserJob:85-86`); measured
  `PICK_TIME_OUT_SYSTEM_ACTIVATED='false'` on Hydra PRD, so it is a no-op there today — and per F2 a
  sysprop write flips that.
- `GET /finishStuckPickingOrder/{number}` — **F1, the most serious finding in this review.**

---

## 2. Q2 — Is the gate forgeable? Is `WEB_UI_VIEW_IMPORT_DATA` self-grantable?

**No path found.** Method: took the exact table set every access decision derives from —
`UserRepository.getAllRoles` (`:77-84`): `mywms_user` → `mywms_group_mywms_user` →
`mywms_group_mywms_role` → `mywms_role_mywms_function` → `mywms_function` — then enumerated every
writer to each of those four join/catalogue tables and every HTTP route to each writer.

- **SDR:** `UserGroupUser`, `UserGroupUserRole`, `UserRoleUserFunction` and `UserFunction` all have
  the four write verbs withdrawn at collection **and** item level (`RestConfiguration` door ① at
  `:64-80` plus `configureAccessChainMembershipWriteExposure`). The three association resources SDR
  actually generates (`User.groups`, `UserGroup.roles`, `UserRole.functions` — the only
  `@ManyToMany @JoinTable` mappings) are withdrawn too. `User` and `UserUserRole` are additionally in
  `SDR_WRITE_WITHDRAWN`. The earlier measured primitive `POST /v3/userGroupUser` and the
  `PATCH /v3/user/{id}` URI-binding escalation are both closed on this base.
- **Java writers:** `UserGroupService`, `UserService`, `UserRoleService`, `AccessService`,
  `UserFunctionService`. Controller reachability: `UserController`, `UserGroupController` and
  `UserRoleController` only — all three carry a **class-level**
  `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` and all three are in `GUARDED`.
  `UserFunctionService` has **no** controller caller at all.
- **The one that would have been Critical:** `UtilRestController:353-354` calls
  `accessService.addFunctionToRole(...)` and lives under `/rest/**` (`permitAll`). Verified on this
  branch that the class is annotated **`@Service`**, not `@RestController` (`:23-24`), so its
  `@RequestMapping` methods do not route. Clean.
- `SystemController` (`/v3/system`, ungated) injects `UserService` but declares only two read
  handlers — see F4 note on one of them.
- **No kill switch exists for MVC `@RequiresFunction`.** Read `FunctionGuardInterceptor` end to end:
  no mode, no property, no sysprop. The only bypasses are `@PublicHandler` (method-level, boot-time
  arity-keyed allow-list, currently 2 sites, both on `UserController`) and absence from `GUARDED`
  with no annotation — neither reachable from a request. The SDR read guard *does* have a
  sysprop-driven mode → **F4**.

**Residual, and it is a grant fact rather than a code defect** (see F5): on Hydra PRD
`WEB_UI_VIEW_USER_MANAGEMENT` is held by `super-admin` (7 users) **and by `ROLE000007` (1 user)`.
That one principal can administer grants without being super-admin, and can therefore grant itself
`WEB_UI_VIEW_IMPORT_DATA`. This is exactly the residual §5 of the plan already states ("Option B
makes the gate exactly as wide as the screen … a grant-administration decision").

**Independent re-derivation of the population claim (Hydra PRD only), via the `getAllRoles` join:**

| function | roles holding it | users reachable |
|---|---|---|
| `WEB_UI_VIEW_IMPORT_DATA` | `super-admin` | 7 |
| `WEB_UI_VIEW_SYSTEM_PROPERTY` | `super-admin` | 7 |
| `WEB_UI_VIEW_USER_MANAGEMENT` | `super-admin`, **`ROLE000007`** | 7 + 1 |
| `WEB_UI_ACTION_DELETE_UNIT_LOAD` | `super-admin` | 7 |
| `WEB_UI_ACTION_DELETE_UNIT_LOAD_RECURSIVE` | `super-admin` | 7 |

`mywms_user` total: **9** on Hydra PRD, **100** on wineco-dev. Agrees with the prior lane's `7` for
Hydra. Not disputed. One framing note in §7 below.

---

## 3. Findings

### F1 — HIGH — `finishStuckPickingOrder`, the highest-impact route on this controller, stays ungated

`GET /v3/adminAction/finishStuckPickingOrder/{number}` (`AdminActionController:184-241`, untouched by
this diff) calls `pickingorderBusinessService.finishPickingOrder` (`PickingorderBusinessService:148`),
which inside one transaction: flips the linked `Customerorder` state to `PICKED`/`PENDING`
(`:249,252`), transfers unfinished totes to the Finished-Picking location, returns unpicked positions
to the pool, and **enqueues a `PICKING_FINISHED` outbox notification to OMS** (`:257-269`, keyed on
`SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_FINISHED_PICKING_URL_KEY`).

Reachability: `SecurityConfiguration:157-161` rule **C** matches `/v3/adminAction/**` with
`hasAnyAuthority(Authority.WMS_USER_ROLE)`. No `@RequiresFunction`, no `@PreAuthorize`, and
`AdminActionController ∉ GUARDED`, so `preHandle` returns `true` at `:246-248`. **Any principal
holding `wms_user` — i.e. every operator, including a mobile picker — can call it.**

Why it is worse than the two other ungated siblings:

- **Zero UI callers in either UI** (`git grep` both checkouts: no hit for `finishStuckPickingOrder`),
  unlike the four routes this ticket gated, which all have live buttons in
  `components/admin/systemManagement/`.
- **No `/rest/**` twin.** The rationale that legitimately spares `triggerUpdateStock` — that gating
  the `/v3` copy is cosmetic while `/rest/stockcount/triggerStockCount` exists under `permitAll` —
  **does not transfer**. `finishPickingOrder` is reachable from no `/rest` controller.
- It notifies an external system, so the damage propagates out of WMS.

Preconditions the handler enforces: order state must be exactly `PICKED` (500) and ≥1
`PickingorderUnitload` must be in `STARTED`. Measured on Hydra PRD: `pickingorder` states are
`500 → 1`, `700 → 38`, `800 → 78`. So the window is narrow **today** and non-empty, and refills
continuously as orders are picked.

**Exploitation scenario.** A warehouse operator's own token (`wms_user`, no functions) issues
`GET /v3/pickingorder?size=1000` — an ungated SDR read; `Pickingorder` is in `SDR_WRITE_WITHDRAWN`,
which withdraws **writes only**, and `SdrFunctionRules` has no rule for it — reads the `number` of
any row at state 500, then `GET /v3/adminAction/finishStuckPickingOrder/<number>`. WMS marks the
customer order picked and tells OMS the order is picked. Recovery is manual state repair plus an OMS
reconciliation.

**Verdict on the implementation:** this is a **scope gap, not a defect in what shipped**. The plan
does record the route (`§6`: "`finishStuckPickingOrder` and
`triggerReleaseExpiredPickingOrdersFromUser` stay ungated (not in SBDEV-3017's §1 slice)") — but
records it as a *slice-boundary fact*, with no statement of what the route does or that it notifies
OMS. A reader of §6 cannot tell that the ungated remainder is more dangerous than four of the five
gated routes. **Recommend:** add the finding to the existing ticket (its own tier is well under T3 —
one method-level annotation, same mechanism, same file), or if it is judged T3, propose it. Do not
ship a §6 that implies the remainder is inert.

### F2 — MEDIUM — the SSRF caveat is right about the write half and understates the payload: the outbound call carries the OMS API credential

`HttpRestService.applyHeaders` (`:86-101`) sets `headers.setBasicAuth(user, pass)` from the
`OMS_API_USER` sysprop and `x-tenant` from `OMS_TENANT_ID` on **every** outbound call — `post`,
`postWithIdempotencyKey` **and `get`**. `testCrmConnectivity` calls `httpRestService.get(urlPath)`
with `urlPath` read from the `WEBSERVICE_TEST_CRM_CONNECTIVITY` sysprop at call time
(`AdminActionController:144,149`). So the request sent to the sysprop-chosen host includes
`Authorization: Basic base64(<OMS_API_USER>)`.

**Measured** (read-only SQL, 2026-09-01):

| sysprop | wineco-dev | hydra PRD |
|---|---|---|
| `OMS_API_USER` | `api_user/<REDACTED — see note>` | `api_user/<REDACTED — see note>` |
| `OMS_TENANT_ID` | `wineco` | `hydra` |
| `WEBSERVICE_TEST_CRM_CONNECTIVITY` | `https://api-oms.dev.sbo.li/services/call/testPsd` | `https://api-oms.sbo.li/services/call/testPsd` |

The credential is **byte-identical across dev and PRD**, so the dev value *is* the PRD credential.

Sysprop writability — **configured, not measured**: `Sysprop` is absent from `SDR_WRITE_WITHDRAWN`
and is explicitly named in that javadoc as one of the eleven domain types kept writable because a UI
writer exists at its SDR path; `SyspropRepository` extends `CrudRepository` under
`@RepositoryRestResource(path = "sysprop")`; `Sysprop` is in `exposeIdsFor`; the only repository
event handler bound to it (`PutawayConfigRepositoryEventHandler`) returns early unless
`isGuardedSyskey`, which matches **only** `DEFAULT_PUTAWAY_LOCATION` (`:525-529`). So
`PATCH /v3/sysprop/{id}` is published and event-unguarded by configuration. I issued no request and
make no claim that it executes.

**What the gate correctly changes, and the caveat does not say:** before this diff one `wms_user`
could both rewrite the URL and press the button — a one-actor exfiltration. After it, the trigger
needs `WEB_UI_VIEW_IMPORT_DATA`, so it degrades to a **stored / confused-deputy SSRF**: plant the URL
and wait for a super-admin to click "Test SiteBossOWL". That is a genuine reduction the plan does not
credit itself with.

**What the caveat is right about, and if anything understates in the other direction:**
`testCrmConnectivity` is the *weakest* sysprop-driven callout in the codebase. Nineteen-plus other
`SYSTEM_PROPERTY_WEBSERVICE_*_URL` keys feed `httpRestService.post/get` from ordinary business flows
and crons that need no function at all. So gating this one route narrows the sysprop-SSRF surface by
essentially nothing — exactly as §7 says.

**Recommendation:** amend §7's bullet to name `HttpRestService.applyHeaders:86-101` and the attached
credential, and to state the confused-deputy degradation. No code change in this ticket.

### F3 — MEDIUM — gating `listRecoverableStuckPallets` closes the triage, not the data

`findRecoverableStuckPallets` carries `@RestResource(exported = false)` (`UnitloadRepository:281`), so
the query itself has no SDR route. Good. But the rows it selects are reachable, ungated, in two GETs:

1. `GET /v3/location/search/findByName?name=Nirwana` — exported (`LocationRepository:23-24`);
2. `GET /v3/unitload/search/findByStoragelocationId?storagelocationId=<id>` — exported
   (`UnitloadRepository:46-47`), returning full `Unitload` entities including `labelid` and
   `entityLock`.

Both are SDR **reads**. `SdrFunctionRules` rules only the eight authorization-graph domain types
(`:176-222`); `Unitload` and `Location` have no rule. And `SdrGuardModeProvider` reads
`WMS2_SDR_READ_GUARD_MODE`, which is **absent on Hydra PRD** (measured) → parses to `OFF`. So the
guard would not gate them even if a rule existed.

Sensitivity of what the gate *does* close: **low**. The emitted fields are `unitloadId, labelid,
originalLabel, typeName, locationName, retireCode, classification, reason, willRelabel`. No PII, no
stock, no customer data; `ordernumber` is read into `Triage` but is not emitted.

**Blocks nothing (Q3 answered).** The only caller in either UI is
`components/admin/systemManagement/recoverStuckPallets.vue:135` →
`store/admin/mgmt/action.js:61-63`, which lives inside the System-Management screen already gated on
the same function (`pages/admin.vue:56`, `util/appMenuList.js:132`). `wms2-mobile-ui` has **zero**
references to `adminAction`. So C34 is coherent — it removes the split state Nam identified, at one
annotation — and it breaks no screen. It should simply not be counted as closing a read.

### F4 — MEDIUM — the SDR read guard's enforcement switch lives in a table the guard does not protect

`SdrGuardModeProvider.SYSKEY = "WMS2_SDR_READ_GUARD_MODE"` is a `los_sysprop` row, and per F2 the
`sysprop` SDR write verbs are published. So whoever can `PATCH /v3/sysprop/{id}` can set the guard to
`OFF`. Costs nothing today — measured, the key is **absent** on Hydra PRD, so the guard is already
`OFF` — but it means SBDEV-3169 Slice 4's `FAIL_CLOSED` will ship with an attacker-writable off
switch, and the provider's own read also **fails OPEN** by design (`:67-73`).

Related, same root: `SystemController.searchSystemByGroupname` (`:53-56`) is an **ungated** handler
(`SystemController` carries no `@RequiresFunction`, is not in `GUARDED`) whose projection selects
`ls.sysvalue` (`SyspropRepository:62`). `GET /v3/system/searchSystemByGroupname/Backend` therefore
returns `OMS_API_USER` in cleartext to any `wms_user`, as does the plain SDR collection read
`GET /v3/sysprop`. Consequence for F2: the credential the SSRF would exfiltrate is **already
readable** by the same population, which lowers F2's marginal severity while raising the priority of
the sysprop surface itself. Neither is caused by this ticket; both belong to the sysprop-surface work,
not here.

### F5 — LOW — the gate is not forgeable; the one residual is a grant decision

Full enumeration and its method in §2. Reported as a finding rather than a clean pass only because of
the `ROLE000007` holder of `WEB_UI_VIEW_USER_MANAGEMENT` on Hydra PRD (1 user), who can grant
themselves `WEB_UI_VIEW_IMPORT_DATA`. That is the residual the plan §5 already names, and it is a
grant-administration decision visible in User Management, not a code change. No action for this
ticket; worth Nam knowing that on PRD the user-administration function is **not** super-admin-only.

### F6 — LOW — Q4: the API route to erasing the Service Log is closed; the cron route is not

Enumeration: `message` is mass-mutated only by `MessageRepository.archiveMessages` /
`.deleteMessages`, both `@RestResource(exported = false)` (`:30-42`); `Message` and `MessageArchived`
are both in `SDR_WRITE_WITHDRAWN`, so `DELETE /v3/message/{id}` and `PATCH` are withdrawn;
`cleanUpOldMessagesJob.doCalculation` has exactly two call sites — `AdminActionController:126` (now
gated) and `SchedulingConfiguration:181` (the cron). **So after this diff there is no HTTP route to
erasing the log that does not require `WEB_UI_VIEW_IMPORT_DATA`.** That part of the change is real.

The residual is the cron, gated on two syspropes. **Measured on both wineco-dev and Hydra PRD:**
`NEW_CRON_JOB_ACTIVATED='true'`, `CLEAN_UP_OLD_MESSAGES_ACTIVATED='false'`,
`CLEAN_UP_OLD_MESSAGES_PERIOD='365'`. Archival is therefore off in both environments today. Per F2, a
`wms_user` who can PATCH a sysprop can set `CLEAN_UP_OLD_MESSAGES_ACTIVATED='true'` and
`CLEAN_UP_OLD_MESSAGES_PERIOD='1'` and let the next cron tick delete 364 days of Service Log —
**without holding `WEB_UI_VIEW_IMPORT_DATA`**. Note `readPeriod` rejects `< 1`
(`CleanUpOldMessageJobService:122-124`), so `0` is refused; `1` is accepted.

The plan's §7 audit-erasure bullet reasons only about *who can press the button* and about minting a
separate constant. It does not mention the cron + sysprop route. Root cause is F2, not this ticket;
recommend one sentence in §7 so the deferral is deferring the right thing.

### F7 — LOW — direction asymmetry: retiring a pallet needs an `ACTION_` function, recovering one needs a `VIEW_` function

`UnitLoadController.bulkDeleteContainer` (`:135-137`) — the route `recoverStuckPallets`'s own javadoc
names as the shape it copies — is gated `WEB_UI_ACTION_DELETE_UNIT_LOAD`. The recovery is now gated
`WEB_UI_VIEW_IMPORT_DATA`. **Measured on Hydra PRD: both held by `super-admin` and only
`super-admin`, 7 users each**, so there is no reachable-set difference today and the choice is sound
under Option B. Recorded because §9.16.2's "`WEB_UI_VIEW_*` names a screen, not read-only-ness"
convention is doing real work here, and a future grant that separates the System-Management screen
from the unit-load actions would let someone recover pallets who cannot retire them.

### F8 — LOW / informational — the enforcement lane is narrower than the reflective pin, as its javadoc says

`AdminActionConsoleGateUnitTest` is well built: `setupMockMvcWithGuard`, `isEqualTo(403)` rather than
`isNotEqualTo(200)`, and — the part that makes it more than a status check — it records the exact
function set handed to `AccessService` and asserts `WEB_UI_VIEW_IMPORT_DATA` specifically, so a gate
wired to the wrong constant fails. The deny-only choice is correctly justified (the field-`@Autowired`
`unitloadBusinessService` would NPE into a 500 on an allow path, and a 500 satisfies "not 403").
`T3` additionally pins single-function ANY-of semantics. No defect.

Scope note only: the claim "the three siblings stay ungated" is carried **solely** by the empty-value
rows in `Sbdev3017TrancheGateContextTest` (`:325-327`), not by any request. The plan measured that
the class-level mutation instead breaks context boot, which is a stronger tripwire than the rows —
but a mutation adding a *method-level* annotation to, say, `finishStuckPickingOrder` is caught by the
pin and not by the enforcement lane. The class javadoc's "Blind spot, stated" paragraph already says
this. Acceptable.

---

## 4. Q5 — Accuracy of the new javadoc and the plan's caveats

**Accurate as written:**

- "The gate genuinely fires for a method-level annotation on a non-`GUARDED` controller" — verified
  against `preHandle` (§1).
- "Never put a class-level `@RequiresFunction` on `AdminActionController`" and the `accessAudit`
  consequence — verified: `accessAudit:347` carries `@PreAuthorize(IS_SB_ADMIN)`, and an
  empty-value pin row asserts the *absence* of method security, so a row there would fail today.
  The comment states this rather than hiding it. Good.
- "`AdminController` is the base class of 43 controllers, so an annotation there registers under all
  of them" — verified; `AdminController` declares 8 mapped handlers under `@RequestMapping("/v3")`,
  all `@PreAuthorize(IS_SB_ADMIN)`.
- `triggerUpdateStock` / `/rest/stockcount/triggerStockCount` — verified, including that `/rest/**`
  is `permitAll()` at `SecurityConfiguration:150-154`.
- `orderReleaseJob.doCalculation` at "exactly two sites — `AdminActionController:108` and
  `SchedulingConfiguration:204`" — verified exactly, both sites and both line numbers.
- "Per-item replenishment is not fenced" — accurate; the mechanism is genuinely out of reach of a
  route gate.
- "0 users lose access", holders == super-admin-reachable set, Hydra PRD = 7 — independently
  re-derived and agrees.

**Understated (→ F2):** the SSRF bullet says the gate closes "*who can press the button*, not *who
can change where WMS calls out*". True, but it omits that the outbound request carries the OMS
Basic-Auth credential (`HttpRestService.applyHeaders`), that the credential is identical on dev and
PRD, and that the change degrades a one-actor exfiltration into a confused-deputy one. "Not measured
exploitable" is the right claim discipline for the SDR write; the *payload* is a code fact and needed
no probe.

**Understated (→ F1):** §6's one-line disposal of `finishStuckPickingOrder` and
`triggerReleaseExpiredPickingOrdersFromUser` states a slice boundary but not an impact. The ungated
remainder includes the only route on this controller that mutates order state and notifies OMS.

**Understated (→ F6):** §7's audit-erasure bullet does not mention the cron + writable-sysprop route
to the same erasure.

**Not overstated anywhere I could find.** The javadoc is unusually careful — it names its own
measurement instrument, states the `accessAudit` gap rather than eliding it, and §8's three recorded
self-corrections are real. One framing nit: **"0 users lose access"** is true of *holders of the
function* but reads as *nobody loses a capability*. On wineco-dev, 37 of 100 `mywms_user` rows hold
`WEB_UI_VIEW_IMPORT_DATA`, so **63 users lose a capability they previously had** — which is the point
of the ticket. Suggest phrasing it as "0 users lose a capability the screen already granted them".

---

## 5. Summary

| # | Sev | Finding | Caused by this diff? |
|---|---|---|---|
| F1 | **HIGH** | `finishStuckPickingOrder` — ungated, `wms_user`-reachable, mutates order state and notifies OMS, no UI caller, no `/rest` twin | No — scope gap; §6 disposes of it without stating impact |
| F2 | MEDIUM | SSRF caveat understates: the callout carries the OMS Basic-Auth credential, identical dev↔PRD | No — pre-existing; caveat wording is the actionable part |
| F3 | MEDIUM | `listRecoverableStuckPallets` gate closes the triage, not the data (2 ungated SDR GETs) | No — but affects how C34 should be scored |
| F4 | MEDIUM | SDR read guard's mode sysprop is writable over the surface it guards; `searchSystemByGroupname` leaks `sysvalue` ungated | No |
| F5 | LOW | Gate not forgeable; residual = `ROLE000007` holds `WEB_UI_VIEW_USER_MANAGEMENT` on PRD | No |
| F6 | LOW | API route to Service-Log erasure closed; cron + writable sysprop route remains | No |
| F7 | LOW | Retire needs `ACTION_`, recover needs `VIEW_`; populations identical today | Introduced, benign |
| F8 | LOW | Enforcement lane narrower than the reflective pin (as its javadoc states) | Introduced, acceptable |

**Nothing in the diff should be changed.** The five annotations are correct, correctly placed
(method-level, right class), correctly valued, and the tests are non-vacuous. The reduction is real
and quantified: on wineco-dev it removes the capability from 63 of 100 `mywms_user` rows, on Hydra
PRD from 2 of 9. Four of the five gates are the sole route to their effect; the fifth
(`listRecoverableStuckPallets`) is substitutable and should be described as coherence rather than
closure. The one thing I would not ship as written is §6's disposal of `finishStuckPickingOrder`.
