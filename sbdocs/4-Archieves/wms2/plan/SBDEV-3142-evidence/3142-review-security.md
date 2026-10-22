# SBDEV-3142 — security review lane (r3-security)

**Reviewed:** `sbdocs/1-Projects/wms2/plan/SBDEV-3142-report-read-gating.md` (draft, 2026-08-31)
**Base:** `wms2-api` `origin/develop` @ `d434a3e5`; `wms2-web-ui` @ `9e70a73b`; `wms2-mobile-ui` @ `c79e81c3`
**Method:** read-only. `git show origin/develop:<path>` / `git grep … origin/develop`. No `mvn`, no worktree mutation.
**Date:** 2026-08-31

---

## 0. Verdict

**The fix is correct, worth landing, and closes the exposure of ZERO datasets on its own.**

Every one of the 19 handlers has at least one other route that returns substantially the same rows to
the same authenticated `wms_user` after this fix ships. For the 13 `ReportController` rows the other
route is not merely "similar data" — it is **the identical repository query method, exported over
Spring Data REST**, reachable at a URL derived mechanically from the method name. For the 6
`ClubLine`/`Transfers` rows it is a mix of an SDR twin and **an ungated sibling GET read on the very
controller being gated**.

So the plan's §1.1 severity framing — *"a user denied the corresponding screen can still obtain the
full data by calling the endpoint directly"* — remains **true after the fix**, with `endpoint`
rebound from `/v3/report/exportInventory` to `/v3/stockView/search/findByClientOffsetAndLimit`.

This is the estate's own `a-guard-fences-the-mechanism-you-aimed-at` failure, and the plan is
**half-inoculated against it**: §3.6 says plainly that SDR is SBDEV-3169's and that neither ticket
closes the founding complaint alone. What it does not do is (a) carry that into the severity claim or
an AC, (b) say the same thing about the **MVC** siblings on the two controllers it is editing, or
(c) name **SBDEV-3158**, which owns those siblings. A reader finishing §3.6 concludes SDR is the only
other door. It is not.

**This is not an argument against shipping.** The annotations are cheap, correct, the audited-route
precedent already exists on the same class (`reprintLabels`), and a gate on the audited route is what
gives the deny metric and `X-Authz-Denied` header something to say. It is an argument against the
ticket being allowed to read as "the report data is now protected", and for one small in-scope
widening (H2).

**Not implementation-ready**, and for one reason this lane adds to the plan's own list: the AC set
contains no acceptance criterion that survives contact with the doors below. Recommended: add an AC
that names the residual routes and their owning tickets, so the closure claim cannot be made from
this ticket alone.

**Corrections to the review brief's own premises** — both in the plan's favour:

1. **Self-grant is closed on `develop`.** The brief asked whether a denied user can grant themselves
   `WEB_UI_VIEW_INVENTORY_RECORD`, citing `/v3/userGroupUser` retaining write verbs. On
   `origin/develop` all four hops of the access chain have their SDR write verbs withdrawn, and the
   three MVC admin controllers are gated on `WEB_UI_VIEW_USER_MANAGEMENT`. See I2 — including what
   still needs a live probe, and the fact that none of it exists on `main`.
2. **Denial-path leakage is Info, not a finding.** See I1.

---

## 1. Per-endpoint "other open doors" table

Derivation, stated so its blind spots are visible: for each handler I read the controller body on
`origin/develop`, followed it to the service method, and read the repository method it calls. I then
read that repository's class-level `@RepositoryRestResource` and the method-level `@RestResource`, and
checked `RestConfiguration` for a verb withdrawal on the entity.
`RepositoryDetectionStrategies.ANNOTATED` (`RestConfiguration:418`) + `setBasePath("/v3")` (`:400`)
means every `@RepositoryRestResource`-annotated repository is exported under `/v3`.
`SecurityConfiguration:178` gates `/v3/**` on the `wms_user` authority alone, and SDR handlers resolve
their declaring class to `RepositorySearchController`/`RepositoryEntityController` — absent from
`GUARDED`, carrying no annotation — so `FunctionGuardInterceptor.preHandle` branch 4 **allows** them
(the interceptor's own javadoc: *"such a request falls through allowed, exactly as before"*).

**Blind spots of this derivation, inline:** (i) it is source-derived, not runtime-derived — I could
not run `SdrSurfaceInventoryContextTest`, so the exact registered search paths are inferred from
`@RestResource(path=…)` rather than observed; (ii) I did not send a single HTTP request, so every
"open" below is an *exposure* claim, not a measured 200 — see §6 for the two probes that settle it;
(iii) "substantially the same data" is my judgement per row and I have graded it, rather than
flattening everything to "equivalent".

Equivalence grades: **identical** = the same repository query method, same parameters ·
**equivalent** = a different query over the same view/table returning the same columns ·
**reconstructible** = the rows can be reassembled from 2–3 exported reads, more work, same outcome.

| # | endpoint gated by 3142 | other route open to the same `wms_user` after the fix | grade | owner |
|---|---|---|---|---|
| 1 | `POST /v3/report/exportInventory` | `GET /v3/stockView/search/findByClientOffsetAndLimit?keyword=&filter=&offset=&limit=` — `ReportService:79` calls exactly this method; `@RestResource(path="findByClientOffsetAndLimit")` | **identical** | SBDEV-3169 |
| 2 | `POST /v3/report/exportLock` | `GET /v3/lockOverviewAllDtoView/search/findByClientOffsetAndLimit` and `/v3/lockOverviewDtoView/search/…` (`ReportService:128-129`). Both repos also keep the **collection** GET — `findAll` is not un-exported — so `GET /v3/lockOverviewAllDtoView?size=100000` is a second door | **identical** | SBDEV-3169 |
| 3 | `POST /v3/report/exportReceiving` | `GET /v3/receivingDtoView/search/findByClientOffsetAndLimit` (`:171`) + collection GET | **identical** | SBDEV-3169 |
| 4 | `POST /v3/report/exportSkuLocation` | `GET /v3/viewWarehouseLocationReport/search/findByClientOffsetAndLimit` (`:205`; note the Java method is `findByClientNameOffsetAndLimit` but the exported **path** is `findByClientOffsetAndLimit`) + collection GET | **identical** | SBDEV-3169 |
| 5 | `POST /v3/report/exportFlowbin` | `GET /v3/flowbinMonitorView/search/findByClientOffsetAndLimit` (`:243`) + collection GET | **identical** | SBDEV-3169 |
| 6 | `POST /v3/report/exportParcelPicking` | `GET /v3/orderDetailMonitorView/search/findByClientOffsetAndLimit` (`:284`) + collection GET | **identical** | SBDEV-3169 |
| 7 | `POST /v3/report/exportOutboundParcel` | `GET /v3/parcelMonitorView/search/findByClientOffsetAndLimit` (`:319`) + collection GET | **identical** | SBDEV-3169 |
| 8 | `POST /v3/report/exportStockUnitRecord` | `GET /v3/stockrecord/search/findByOffsetAndLimit` (`:352`) + collection GET | **identical** | SBDEV-3169 |
| 9 | `POST /v3/report/exportContainerRecord` | `GET /v3/unitloadRecord/search/findByOffsetAndLimit` (`:398`) + collection GET | **identical** | SBDEV-3169 |
| 10 | `POST /v3/report/exportStorageLocations` | `GET /v3/location/search/exportStorageLocations` — `LocationRepository:316` exports it by that name, **zero parameters, whole-table native query**. The sharpest single row in the table: no ids to guess, no paging to walk | **identical** | SBDEV-3169 |
| 11 | `GET /v3/report/flowbinMonitorView` | `GET /v3/flowbinMonitorView/search/findByKeywordAndClientName?keyword=&clientNumber=&page=&size=` — `ViewDtoService:1298` calls exactly this | **identical** | SBDEV-3169 |
| 12 | `GET /v3/report/parcelPickingView` | `GET /v3/orderDetailMonitorView/search/findByKeyword?keyword=&clientNumber=&page=&size=` (`ViewDtoService:1332`) | **identical** | SBDEV-3169 |
| 13 | `GET /v3/report/parcelMonitorView` | `GET /v3/parcelMonitorView/search/findByKeyword` / `…/findByKeywordAndParcelPalletized` / `…Unpalletized` — all three branches of `ViewDtoService:1373-1381` are separately exported | **identical** | SBDEV-3169 |
| 14 | `POST /v3/clubLine/skus` | `CustomerorderPosition` + `Customerorder` SDR reads for the batch's orders yield SKU + qty; the club-run **list** screens stay open (see H1b) | reconstructible | SBDEV-3169 / SBDEV-3158 |
| 15 | `POST /v3/clubLine/unitLoads` | `Unitload` / `Stockunit` SDR reads are exported; ungated `GET /v3/clubLine/orderBatch/{id}` and `GET /v3/clubLine/availableStagingLanes` give the batch/lane half | reconstructible | SBDEV-3169 / SBDEV-3158 |
| 16 | `POST /v3/clubLine/parcels` | `GET /v3/customerorder/search/findByOrderbatchId?orderbatchId=N` — exported (`CustomerorderRepository:42`); `ViewDtoService.getOrderDetailView` projects the same orders | **equivalent** | SBDEV-3169 |
| 17 | `POST /v3/transfers/unitLoads` | as row 15, plus **`GET /v3/transfers/skus?orderBatchId=N`** stays open — see **H2** | reconstructible | SBDEV-3158 |
| 18 | `POST /v3/transfers/parcels` | `GET /v3/customerorder/search/findByOrderbatchId` — identical projection to row 16 (the two handler bodies are byte-identical in effect, as §3.5 notes) | **equivalent** | SBDEV-3169 |
| 19 | `POST /v3/transfers/availableTransferLanes` | `GET /v3/location/search/getAvailableTransferLanes?customerOrderId=N&state=700` — `LocationRepository:95` exports **the exact query** `TransferOrderService:84` runs. The only difference is that the caller supplies a `customerOrderId` instead of a batch id, and `findByOrderbatchId` (row 16's door) hands that over | **identical** | SBDEV-3169 |

**Score: 19 of 19 rows have another door. 13 of 19 are `identical`.** Zero rows are closed by this
ticket alone.

### `/rest/**` — considered and excluded

Confirmed I looked and confirmed it stays out. `SecurityConfiguration:150-154` `permitAll`s it; it is
ruled internal-only WMS↔OMS with JWT deferred (2026-08-27) and **must not be re-escalated**. Two
things worth recording rather than escalating: `TransactionReportRestController` and
`StockCountRestController` serve report-shaped reads on that surface, and `UtilRestController` — the
one class that calls `accessService.addFunctionToUser` / `addFunctionToRole` — is annotated
**`@Service`, not `@RestController`** (`:23`), so its `@RequestMapping` methods do not route at all.
That is the standing `wms2-utilrestcontroller-is-service-not-restcontroller` fact, re-verified on
`d434a3e5`; it is also why `/rest/**` is not a self-grant route.

---

## 2. Findings

### H1 — High · the closure claim, not the code

**H1a.** The severity statement in §1.1 and the implied outcome of the whole plan do not survive the
table above. Nothing in the code is wrong; the **claim** is. A reader of the ticket after merge would
believe the 10 dataset exports are no longer obtainable without entitlement, and they are — by a URL
whose shape is derivable from the repository source, with no ids to guess.

*In scope for SBDEV-3142* — the fix is not, the honest framing is.

Recommended, concretely:
- §1.1 gains one sentence: *"After this fix each of the 19 remains obtainable via an equivalent
  ungated route (SDR for 13 of them, with the identical query method); SBDEV-3142 gates the audited
  route only, and the dataset is closed only when SBDEV-3169 and SBDEV-3158 land."*
- One new AC: *"the residual routes per endpoint are enumerated in the plan with their owning ticket,
  and the ticket's close note states that no dataset is closed by this ticket alone."*
- The existing precedent for exactly this wording is in the code already —
  `ReportController:307`: *"Gates the AUDITED MVC ROUTE only; the underlying data keeps its SDR
  surface."* The plan should say what its own codebase already says.

**H1b.** The plan does **not** name SBDEV-3158, and that is the specific omission that makes §3.6
misleading. §3.6 tells the reader SDR is elsewhere and lists the six proposed `/v3` reads on *other*
controllers in §7.1 — so the reader reasonably infers the three controllers in scope are finished.
They are not. Still ungated on the two controllers being edited, all reads, all authenticated-`wms_user`:

| controller | still-open read after 3142 | what it returns |
|---|---|---|
| `ClubLineController` | `GET /orderBatch/{orderBatchId}` | club batch detail |
| | `GET /openClubRun`, `/closedClubRun`, `/activeClubRun`, `/inactiveClubRun` | the club-run lists — the primary data of the club screens |
| | `GET /availableStagingLanes?orderBatchId=` | staging lanes |
| `TransfersController` | **`GET /skus?orderBatchId=`** | `List<ClubLineSkuDto>` — see H2 |
| | `GET /openTransfer`, `/allOpenTransfer`, `/activeTransfer`, `/closedTransfer`, `/inactiveTransfer` | the transfer lists |
| | `GET /transferOrder/{customerOrderId}`, `/transferOrderByOrderBatchId/{orderBatchId}` | transfer order detail |

Owner: **SBDEV-3158** (the other ~90 ungated `/v3` MVC reads; see `SBDEV-3017-B1` §9.29.2 — 3142's
widening from 16 to 106 was retracted the same day and the remainder became 3158). §3.6 should name
it in the same breath as 3169.

Separately and **not** 3142's: the 9 state-changing GETs on these two controllers (`runClubLine`,
`assignStagingLane`, `unlinkStagingLane`, `activateBatch`, `runTransfer`, `assignTransferLane`,
`reassignTransferLane`, `unlinkTransferLane`, `activateTransferOrder`) are ungated **writes**, owned by
**SBDEV-3155**. Mentioned only so a reader of this file does not think a read-gating pass covered them.

### H2 — High · `TransfersController.getSkuView` is left open by the scope filter, and it is one annotation

The plan's enumeration filter is `($5=="…ReportController") || ($2=="POST" && $5 ~ /ClubLine|Transfers/)`.
`TransfersController.getSkuView` is a **`RequestMethod.GET`** (`:332-336`), so it is filtered out —
while its POST siblings on the same class (`getTransferLineUnitLoads`, `getParcelView`,
`getAvailableTransferLanes`) are all gated `WEB_UI_VIEW_TRANSFER_ORDER`. Its `ClubLineController`
counterpart, `getSkuView` → `POST /clubLine/skus`, **is** in scope as row 14.

The result after the fix: the club SKU overview is gated and the transfer SKU overview — the same DTO
type, `List<ClubLineSkuDto>`, the same screen family — is not. The verb is the only reason.

**There is no over-gating risk in fixing it, and I checked before recommending it.** Its only two
callers are `store/outbound/transfer.js:225` and `store/processes/transferPicking.js:183`, serving
`/outbound/transfer` and `/processes/transfer-picking`, and `util/appMenuList.js:61,70` gates **both**
on `WEB_UI_VIEW_TRANSFER_ORDER` — the same function the plan already assigns to rows 17–19. One
`@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_TRANSFER_ORDER)`, no new constant, no new
population.

*In scope for SBDEV-3142.* Its own tier is T0/T1 (one annotation, one file, obvious from the symptom,
reversible), the host ticket is `Open`, so the estate's ticket policy puts it on the existing ticket
rather than proposing a new one. Making the plan's count 20/33 rather than 19/32 is cheaper than
explaining the asymmetry later. If Nam prefers the boundary stay exactly where the ticket drew it,
then it must be **named** in §3.6 as 3158's, not left to the awk filter.

### M1 — Medium · over-gating: every denied read fires a second, contradictory toast telling the operator to retry

The interceptor's denial UX is well built and I verified the good half independently:
`wms2-web-ui/plugins/axios.js:113-121` reads `X-Authz-Denied`, refuses to retry, and toasts
*"You do not have permission for this action (FUNCTION). Ask an administrator if you need access."*
Reading the **header** rather than the body is what makes this work for the exports, which are
`responseType: 'blob'` — the JSON problem body arrives as a `Blob` and `error.response.data.reason`
is not readable without an explicit `blob.text()`. The header path sidesteps that. Good design, and
`SecurityConfiguration:220-221` does expose the header for CORS.

The problem is what happens next. Each report store wraps its call in `try/catch` and the catch fires
its own toast:

```
store/reports/inventory.js:111-113
} catch(error) {
    console.log(error)
    this.$toast.error('Error: Request failed due to a network or server issue. Please retry.')
}
```

So a denied operator gets both messages, one of which is false and instructs them to retry a request
that can never succeed. `git grep -c "network or server issue"` on `origin/develop` finds that string
in **17** stores that own these calls, including all 10 report stores plus `outbound/club.js` (11
occurrences), `outbound/transfer.js` (9) and `internalOps/cycleCount.js` (9).

This is security-relevant in the direction the brief asked about: a control whose denial message says
*"server issue, please retry"* is a control operators escalate around, and it converts a clean 403
into a suspected outage. It is also **caused by this ticket** — before the fix these endpoints never
403 anyone.

*In scope for SBDEV-3142*, in the `wms2-web-ui` PR the plan already schedules for §3.4's dead-action
deletion. Minimum viable fix: in the catch, skip the generic toast when
`error.response?.status === 403 && readAuthzDeniedHeader(error.response)` — the helper already exists
in `plugins/axios.js`. Sub-T3, host ticket `Open`.

### M2 — Medium · 5 of the 19 are exercised by the Cypress suite, and the test plan has no row for it

The plan's §6 instrument table lists three instruments and none of them is Cypress. Measured with
`git grep -l` per path against `cypress/` on `wms2-web-ui@origin/develop`:

| endpoint | spec files touching it |
|---|---|
| `GET /report/parcelMonitorView` | **10** |
| `GET /report/parcelPickingView` | 4 |
| `POST /clubLine/skus` | 2 |
| `POST /clubLine/unitLoads` | 2 |
| `POST /transfers/availableTransferLanes` | 2 |

They are called as direct API assertions (`cy.wms('GET', '/report/parcelMonitorView', …)`,
`wmsHelpers.js:15,26,589`) across the pick-pack, club-line, palletize, BOL-create and truckload
journeys — i.e. these two `*View` GETs are load-bearing **verification** steps for flows that have
nothing to do with the reports menu. The Cypress identity comes from
`cypress/support/plugins/auth-task.js:51-52` (`env.KC_USERNAME` / `KC_PASSWORD`), which I cannot
resolve from the repo. If that identity does not hold `WEB_UI_VIEW_PARCEL_MONITOR`,
`WEB_UI_VIEW_PARCEL_PICKING`, `WEB_UI_VIEW_CLUB_LINE` and `WEB_UI_VIEW_TRANSFER_ORDER`, a large part
of the E2E suite reds after merge and the cause will look like a flow regression rather than a gate.

Note this is a **suite** risk, not a live-user risk: in the app itself each of the three `*View` GETs
has exactly one caller, in its own report store (`store/reports/{flowbin,outboundParcel,parcelPicking}.js`),
verified with `git grep` over `store components pages util plugins`. So the plan's implicit assumption
that rows 11–13 are report-screen-only is **correct for the app** and **wrong for Cypress**.

*In scope for SBDEV-3142.* Add a row to §5.2: before merge, resolve `KC_USERNAME` and confirm it holds
those four functions — the plan's own §1.3 query (`UserRepository.getAllRoles`) is the instrument, and
if it is `panderson` (80 functions) the answer is yes and this costs one query.

### M3 — Medium · the production blast radius rests on a single 9-user tenant, and there is no rollback note

§1.4's five-DB survey is genuinely better than the two-DB default the SBDEV-3031 lesson warns about,
and the presence check (all 12 constants in all 5) rules out the worst outcome. But of those five,
**one is production** — hydra PRD, 9 users, 7 holders. The other four are DEV and UAT, and rows 3–5
are presence-only, which the plan states honestly.

Two gaps follow:
- WineCo is a v2 client with its own production database (`wineco-is-a-v2-client-prd-mcp-is-wms1-wineco`),
  and it is not in the survey. A holder count on hydra's 9 users cannot stand in for a tenant with
  ~94 users in UAT. Recommended: run the §1.3 holder query per function on **every** v2 production
  tenant before the release note is written, not before the merge — merging to `develop` only deploys
  dev.
- There is no rollback or staging note. This is a 200→403 change on 19 handlers over 32 paths, landing
  in one deploy, with an immediate dev blast radius of ~53–57 of 99 users. The estate has shipped
  risky behaviour changes behind a sysprop before (SBDEV-1762, default OFF). I am **not** recommending
  a flag here — a flag on an authz gate is itself an attack surface and adds a `los_sysprop` key that
  a `wms_user` may be able to reach. I am recommending the cheaper thing: state in §5.2 that rollback
  is "revert the 19 annotations, single commit, no migration, no data change", so the on-call answer
  exists in writing.

*Release-note / rollout scope for SBDEV-3142.* The per-tenant survey is a prerequisite for the
release, not for the PR.

### L1 — Low · `USER_NOT_PROVISIONED` logs at ERROR per request, and this ticket multiplies the surface 19×

`FunctionGuardInterceptor.logDenial` routes `USER_NOT_PROVISIONED` to `LOG.error` with username and
tenant, by deliberate design (`AccessDecision.Reason` javadoc: *"a provisioning defect, not a
permissions question"*, SBDEV-3063). Correct as a diagnosability choice. The side effect is that any
holder of a valid tenant JWT with no `mywms_user` row can emit one ERROR line per request, and 3142
adds 32 new paths that reach that branch. Pre-existing, tiny, and I would not gate the ticket on it —
but if hydra PRD's 2 newly-denied users turn out to be `NO_FUNCTIONS` rather than `MISSING_FUNCTION`,
the WARN volume is worth a glance in the first hour after deploy.

*Not in scope for SBDEV-3142.* Belongs to the SBDEV-3063 lineage if anyone wants rate-limiting.

### L2 — Low · a caveat on my own H1 evidence for row 2

`LockOverviewAllDtoViewRepository.findByClientOffsetAndLimit` and its `LockOverviewDtoView` twin
declare their parameters **without `@Param`** (`:48`, `:47`). SDR binds search parameters by `@Param`
or, failing that, by reflective parameter names, which requires `-parameters` at compile time.
`pom.xml` declares `maven-compiler-plugin` 3.13.0 with no `<parameters>` element, but the parent is
`spring-boot-starter-parent` 3.5.9, whose pluginManagement sets `<parameters>true</parameters>` and
merges into the local configuration — so the names should be available and the search bindable. I have
**not** verified this at runtime. If it turned out unbindable, row 2's `identical` grade would drop to
the **collection** GET on the same two repositories, which is exported unconditionally and returns
more data, not less. Either way row 2 has a door; only the URL changes.

### I1 — Info · the denial body and header leak nothing an authenticated caller cannot already read

The brief asked specifically about function-name enumeration and a user-existence oracle. Read
`AccessDecision`, `AccessService.checkAnyAccess` and `FunctionGuardInterceptor.deny`:

- **Function-name enumeration.** `requiredFunction` (body + `X-Authz-Denied`) names the function. It
  leaks nothing: the entire catalogue is already an ordinary authenticated read. `RestConfiguration`
  withdraws only the **write** verbs from `UserFunction` and its javadoc says GET *"IS KEPT, and must
  be"* because three admin stores read it; and `UserController` carries a `@PublicHandler` bootstrap
  read of the function list reachable by a user holding **zero** functions. A caller who wants the 82
  names asks for them.
- **User-existence oracle.** `checkAnyAccess` is only ever called with `currentUsername()` — the
  interceptor's own `SecurityContextHolder` read. The three reason codes therefore describe the
  **caller's own** provisioning state (no row / row with no functions / row missing this function),
  never a third party's. There is no oracle here. (`SBDEV-3071`'s arbitrary-username reads are
  `UserController` endpoints, a different surface, already shipped.)
- One shape worth knowing rather than fixing: `CONFLICTING_ANNOTATIONS` and the guarded-but-unannotated
  branch both deny with `requiredFunction == null`, so no header is set and only `reason` distinguishes
  them. That is a deployment-defect signal reaching a client, and it is the intended design.

**Verdict: Info. No change requested.**

### I2 — Info (a premise correction) · self-grant appears CLOSED on `develop`; this fix is not cosmetic

The brief's premise — a denied user grants themselves the function, making the gate cosmetic — does
not hold on `d434a3e5`. Derived by reading `RestConfiguration` end to end plus the three admin
controllers' class-level annotations:

| route to a grant | state on `origin/develop` |
|---|---|
| SDR hop 1 — `/v3/userGroupUser` | POST/PUT/PATCH/DELETE withdrawn (`configureAccessChainMembershipWriteExposure`, collection + item) |
| SDR hop 2 — `/v3/userGroupUserRole` | same, withdrawn |
| SDR hop 3 — `/v3/userRoleUserFunction`, `/v3/userRole/{id}/functions` | withdrawn (`configureRoleFunctionWriteExposure`) |
| SDR hop 4 — `/v3/userFunction` (the rename-impersonation route) | withdrawn, collection + item |
| SDR `/v3/user/{id}`, `/v3/user/{id}/groups`, `/v3/userGroup/{id}/roles` | withdrawn |
| `UserController` (`/v3/user/**`) | class-level `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` + in `GUARDED` |
| `UserGroupController`, `UserRoleController` | class-level `@RequiresFunction(WEB_UI_VIEW_USER_MANAGEMENT)` + in `GUARDED` |
| `UserAdministrationController` | explicit `requireUserManagement()` first statement; Keycloak groups only, no WMS function writes |
| `/rest/**` | `UtilRestController` is `@Service` — does not route |

So a user holding no `WEB_UI_VIEW_USER_MANAGEMENT` has no route I can find to a function grant, and
**SBDEV-3142's gate is therefore load-bearing rather than decorative.**

Three honest limits on that conclusion:
1. **Code-derived, not probed.** Every prior claim in this area that was later corrected was corrected
   by a live probe, and `advertised-capability-is-not-exploitable` cuts both ways: absence of an
   advertised verb is strong evidence but the estate's own precedent is that `OPTIONS`/annotation
   reading has been wrong before. The `probe-wms2-report-read-gating-dev.sh` run (P1) is the natural
   place to add three control rows — see §6.
2. **Collection `POST /v3/userGroup` and `POST /v3/userRole` are still open**, and item `PUT` is kept
   on both by design (`mergeForPut` drops linked associations). Creating an empty group or role confers
   nothing while hops 1–3 are shut, so this is not an escalation today — but it is the pair to re-check
   if any of those withdrawals is ever relaxed.
3. **None of this exists on `main`.** `FunctionGuardInterceptor` is absent from `origin/main`, and so
   is every withdrawal above. The plan's §4 says this for the interceptor; it is equally true of the
   self-grant closure. On production today, both the gap and the self-grant hole are open.

If a live probe *does* find a residual grant route, the owner is the SBDEV-3013 → SBDEV-3157 lineage,
not this ticket.

### I3 — Info · the plan's three structural claims are correct, verified independently

I re-derived these from source rather than accepting them, because two of them are the difference
between this fix and a mobile outage:

- **§3.2 — method-level only.** `DashboardController:26` is the **sole** subclass of `ReportController`
  (`git grep "extends ReportController"` on `src/main` + `src/test`: one hit). It **declares**
  `orderMonitorViewSummary` (`:48`) and `replenishMonitorViewSummary` (`:116`), so their
  `getMethod().getDeclaringClass()` is `DashboardController`, and a method-level annotation on a
  `ReportController`-declared method cannot reach them. The mobile-outage risk is real for the
  class-level shortcut and nil for the design as written. `preHandle`'s
  `AnnotationUtils.findAnnotation(declaring, …)` does walk superclasses, exactly as §3.2 says.
- **§3.2's inverse (class-level on `DashboardController` is silently inert)** is also right, and the
  reason is visible in the two keys: the inventory's `getBeanType()` would see the subclass annotation
  while the interceptor's `getDeclaringClass()` would not.
- **§3.3 / AC-4 — one annotation covers both prefixes.** Structural, and correct.
- **`GUARDED` membership.** 14 classes exactly: 11 mobile + `UserRoleController` + `UserGroupController`
  + `UserController`. None of the three controllers in scope. Branch 4 allows. ✅
- **`ReportController` = 14 declared handlers, 13 ungated.** Counted from source: 10 `export*` POSTs,
  `reprintLabels` (gated `WEB_UI_VIEW_PARCEL_PICKING`), 3 `*View` GETs. The plan's correction to
  SBDEV-3169 §2.7 (15/14 → 14/13) is right.
- **`AdminController` interaction.** 43 classes extend it; all its own handlers carry
  `@PreAuthorize(Authority.IS_SB_ADMIN)` and none carries `@RequiresFunction`, so a method-level
  annotation on a subclass-declared method changes nothing for them. The brief's question 5 about the
  four prefixes resolves clean.
- **The function↔screen table (§3.1).** All 13 report rows and both club/transfer functions match
  `util/appMenuList.js` exactly (`:39,60,61,69,70,87,109-121`, and `:167,168,172-181` for the
  fulfillment sub-routes). No mis-assignment found.
- **Mobile.** `git grep` over `store components pages plugins util middleware` on
  `wms2-mobile-ui@origin/develop` for all 19 paths: **0 hits**. The mobile lane's conclusion holds.

One forward-looking note on §3.2 that the plan does not make and should: `getMethodAnnotation`
resolves with `SearchStrategy.TYPE_HIERARCHY`, so if anyone later **overrides** one of the 19 in
`DashboardController`, the override *inherits* the `@RequiresFunction`. That direction is safe — the
gate follows the method — but it means the T4 mobile-safety pin only protects the two currently
declared summaries, not any future override.

---

## 3. Answers to the five questions, compactly

1. **Every producer of the same rows** — §1. 19 of 19 endpoints keep another door; 13 are the identical
   exported query method. Gating MVC alone leaves an equivalent open door on **every** endpoint. Other
   MVC controllers: `ItemDataController` is the notable adjacent one — `GET /v3/itemData/detailView`
   and `GET /v3/itemData/detailViewByKeyword` (the method is literally named `getExportData`) are
   ungated bulk item-master reads, a *different* dataset from `StockView` and owned by SBDEV-3158.
   `StockRecordController` and `UnitloadRecordController` expose only per-id detail reads — weak
   equivalence, not a bulk door. `SystemController` serves sysprop group reads — unrelated data.
2. **Bypass / self-grant** — I2. Appears **closed on `develop`**, which makes this fix worthwhile
   rather than cosmetic; open on `main`/prd along with everything else. Needs a live probe to be
   asserted, and the SBDEV-3013 → 3157 lineage owns it if a route survives.
3. **Denial-path leakage** — I1. Info. The function catalogue is already an authenticated read, and
   the reason codes describe only the caller's own provisioning.
4. **Over-gating** — M1 (a false "retry" toast on every denial, 17 stores), M2 (Cypress), M3 (one
   production tenant, no rollback note). The blast-radius *measurement* is good; the *handling* of the
   newly-denied users is thin.
5. **Unintended exposure changes** — none found. §3.2's mobile claim and the `AdminController`
   question both verified independently (I3). The one thing the fix changes that the plan does not
   discuss is the **client-side** behaviour of newly-403ing calls, which is M1.

---

## 4. Severity summary

| # | severity | finding | in scope for 3142? |
|---|---|---|---|
| H1a | High | the closure claim does not survive the residual routes; needs a sentence in §1.1 and an AC | ✅ yes (framing) |
| H1b | High | §3.6 names SBDEV-3169 but not **SBDEV-3158**; 13 ungated sibling reads remain on the two controllers being edited | ✅ yes (§3.6 + a table) |
| H2 | High | `TransfersController.getSkuView` (GET) excluded by the POST-only filter while its 3 POST siblings are gated; one annotation, same function, no over-gating risk | ✅ yes (T0/T1 addition) |
| M1 | Medium | denied reads fire a second toast saying "network or server issue. Please retry." — 17 stores | ✅ yes (the web-ui PR) |
| M2 | Medium | 5 of 19 exercised by Cypress across up to 10 specs; no Cypress instrument; `KC_USERNAME` entitlement unresolved | ✅ yes (§5.2 row) |
| M3 | Medium | PRD blast radius from one 9-user tenant; WineCo prd unsurveyed; no rollback note | ✅ yes (release note) |
| L1 | Low | `USER_NOT_PROVISIONED` at ERROR per request, surface ×19 | ❌ SBDEV-3063 lineage |
| L2 | Low | caveat on my own row-2 evidence (`@Param`-less search methods) | — |
| I1 | Info | denial body/header leaks nothing new | — |
| I2 | Info | **premise correction** — self-grant closed on develop; fix is load-bearing | ❌ SBDEV-3013/3157 if reopened |
| I3 | Info | §3.2 / §3.3 / `GUARDED` / 14-13 / function table / mobile all verified | — |

Nothing here blocks the design. H1 and H2 should land before the ticket is called done; M1 rides the
web-UI PR the plan already has.

---

## 5. What I did not check

Stated so the next lane does not assume coverage:

- **No HTTP request was sent.** Every "open" in §1 is derived from source. The plan's P1 probe is
  still unrun and is still the right instrument.
- **No `mvn`.** I did not run `SurfaceInventoryContextTest` or `SdrSurfaceInventoryContextTest`, so
  the SDR search paths in §1 are inferred from `@RestResource(path=…)`, not observed in a registered
  handler map. A path override I misread would change a URL, not a verdict.
- **No DB query.** §1.4's holder counts and §1.3's account table are taken as given; I did not
  re-derive them. M3's recommendation is precisely that someone extend them.
- **`ReportService`'s ten methods** were read only as far as the repository call they make. I did not
  audit them for writes — the plan's §7.1 records the same limit for the six proposed endpoints, and
  SBDEV-2485's `printable` flag is the estate's precedent for an export path that writes.
- **Grade judgements in §1 are mine.** "reconstructible" for rows 14, 15, 17 is a judgement about
  effort, not a measurement; someone could reasonably grade them lower. Rows 1–13, 16, 18, 19 are
  mechanical and I would defend those.

---

## 6. Two probe additions worth making while P1 runs

Both are cheap, both settle a claim in this file that is currently source-derived, and both fit the
existing script's shape. Neither is an exploit recipe: the first reads data the caller is already
being handed by the MVC route it is being compared against, and the second is a body-free control.

1. **One SDR control row per gated endpoint, section G.** As `estellavasquez` (holds `CLUB_LINE` +
   `TRANSFER_ORDER`, not `INVENTORY_RECORD` — the plan's differential account): after the fix,
   `POST /v3/report/exportInventory` must be **403**, and the paired
   `GET /v3/stockView/search/findByClientOffsetAndLimit` will be **200**. That single pair converts
   H1 from an argument into a measurement, and it is the row that makes the ticket's close note
   defensible. It is also the row SBDEV-3169 will want as its own baseline.
2. **Three self-grant control rows, section H.** As a plain `wms_user` with no
   `WEB_UI_VIEW_USER_MANAGEMENT`: `OPTIONS /v3/userGroupUser`, `OPTIONS /v3/userFunction/{id}`, and a
   **body-free** `DELETE /v3/userGroupUser/{nonexistent-id}`. Expect `Allow` without the write verbs
   and a **405**, not a 404. Per `sdr-write-verb-probes-400-proves-nothing`, a 400 would settle
   nothing — the body is rejected before the exposure check — which is why the DELETE is body-free.
   A 405 confirms I2 live; a 404 means the request reached the repository and I2 is wrong.
