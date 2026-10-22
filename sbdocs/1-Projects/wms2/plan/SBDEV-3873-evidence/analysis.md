---
ticket: SBDEV-3873
kind: analysis (read-only, plan input)
date: 2026-10-22
refs:
  wms2-api: origin/develop bafa2301 (2026-10-22)
  wms2-web-ui: origin/develop 98accaf (2026-10-21)
  wms2-mobile-ui: origin/develop f51dc6c (2026-10-16)
  oms-laravel-api: origin/develop a8f73897 (2026-10-22)
method: git fetch, then `git grep` / `git show` against origin/develop only (never a working checkout)
---

# SBDEV-3873 — analysis: SDR item PATCH on Advice / Cyclecount binds every field

All citations are `origin/develop` at the SHAs above. Line numbers drift, so each one comes with a quoted snippet.

## TL;DR — five findings that change the plan

1. **The Cycle Count comment box is `readonly`, so its PATCH only echoes the stored value back.** In
   `plannedCycleCountDescription.vue` the textarea is declared `readonly`; this has been true since `9991a48` (2025-05-22). The
   `comment` watcher still fires on load, because `setInitialComment()` assigns the stored value, and so it PATCHes back what it
   just read. A user cannot write a cycle-count comment from this screen. That gives a cheaper option for the Cycle Count half:
   **delete the cyclecount `saveComment` and its watcher, and add no new cyclecount endpoint.** This is a decision for Nam
   (§4.3). The agreed shape (a new endpoint) still works, but it builds a write path for a field nobody can type into.
2. **Once PR 2 lands, Advice and Cyclecount have no SDR write verb left.** Collection POST and item PUT/DELETE are already
   withdrawn. PR 2 therefore turns both into fully withdrawn types and must move them from `MUST_STAY_WRITABLE` (8 → 6) to
   `WITHDRAWN` (51 → 53). The cleanest way is to add them to `SDR_WRITE_WITHDRAWN` and delete the two per-type methods. Seven test
   classes pin the current state (§3.4).
3. **`SdrMustStayWritableStateNotPatchableContextTest` will go red for a structural reason, not a behavioural one.** Its
   sensitivity check needs `typesWithState >= 2`. Advice and Cyclecount are the only `MUST_STAY_WRITABLE` types with a `state`
   field (the other 6 were checked by grepping each model), so after PR 2 the count is 0. The test has to be retired or re-scoped.
   It must not be "fixed" by lowering the threshold.
4. **The rollout order is a hard constraint in two places, across repos that are promoted independently.** wms2-api `develop` is
   120 commits ahead of `release` and `main`; wms2-web-ui is 11 ahead. If PR 2 reaches an environment before the web PR does, the
   old UI gets a 405 there. On Cycle Count that 405 shows as an error toast **every time a planned cycle count is opened**,
   because of the echo PATCH on load. The reverse ordering also bites: if the web PR is promoted before PR 1, the new UI gets a
   404 (§8).
5. **The Advice comment column is `varchar(255)`, and the closed-notice textarea has no `maxlength`.** A longer comment fails
   at the DB today (a 500 from SDR). The new endpoint should reject length > 255 with a 4xx. It should not clamp silently, and
   it should not return the legacy 200-with-`errors` shape, because `saveComment` only reports failures that throw (§4.2).

---

## §0 Affected-sites table (enumeration)

### 0.1 Patterns run (all with `git grep -n` at `origin/develop`, index-based, so a `.gitignore` cannot hide a file)

| # | Pattern | Repo / scope | Purpose |
|---|---|---|---|
| P1 | `\$patch\(\|\.patch\(\|['"]patch['"]\|['"]PATCH['"]` | web-ui, whole repo minus `static/` | every PATCH call, including the Nuxt shortcut, the axios instance method and `cy.wms('PATCH',…)` |
| P2 | `-A1 '\$(put\|delete)\(\|\.(put\|delete)\('` then filter `advice\|cyclecount` | web-ui | item PUT and DELETE, path allowed on the next line |
| P3 | `\$(post\|put\|patch\|delete)\(\s*[^'"\` ]` and `\$axios\.(…)\(\s*[^'"\` ]` | web-ui (store, components, pages) | **computed URLs**, where the first argument is not a literal |
| P4 | `-A2 '\$(post\|put\|patch\|delete)\(\s*$'` | web-ui | **multi-line** calls, where the path sits on the next line |
| P5 | `\$axios\(\|axios\.request\|\$axios\.request\|fetch\(` | web-ui | generic request APIs that bypass the verb helpers |
| P6 | `dispatch\(\s*[^'"\` ]`, plus `mapActions` filtered to inboundNotices/cycleCount | web-ui | **dynamic dispatch** of `saveComment` |
| P7 | `['"\`]/(advice\|cyclecount)['/]` | web-ui `cypress/` | Cypress SDR calls |
| P8 | `saveComment\|/advice/\|/cyclecount/\|\$patch` | web-ui `test/` (Jest) | Jest specs that mock these URLs or actions |
| P9 | `\$(patch\|put\|delete)\(\|\.(patch\|put\|delete)\(` (with `-A2`), then case-sensitive `/advice\|/cyclecount\b` | mobile-ui | mobile callers |
| P10 | `v3/(advice\|cyclecount)\|cyclecount` (in `app config routes tests`); `config/wms.php` filtered to `advice\|cycle`; `(Http::\|->)(patch\|withMethod)\(\|'PATCH'` | oms-laravel-api | OMS callers |
| P11 | `cyclecount\|/advice/` | siteboss-frontend `origin/main`, `apps/` | the OMS v2 UI, as a sanity check |

### 0.2 Results

| # | Site | Verb + path | Payload | Live? | Impact by step |
|---|---|---|---|---|---|
| S1 | `wms2-web-ui store/receiving/inboundNotices.js:408-416` `saveComment` — `const result = await this.$axios.$patch(\`/advice/${data.id}\`, data)` | item PATCH `/v3/advice/{id}` | `data` = `{ id, comment }` (S1a) | **Live.** Dispatched from S1a | Step 2 re-points it. After step 3 the old UI gets 405 |
| S1a | `components/receiving/closed/closedNoticeDescription.vue:242` — `this.$store.dispatch('receiving/inboundNotices/saveComment', { id: this.noticeDetails.id, comment: this.comment })` | — | literal `{id, comment}` | Live: textarea `v-model="comment"`, **not** readonly, no `maxlength` (`:97-102`) | page `/receiving/closedNotice/:id`, gated `WEB_UI_VIEW_INBOUND_BOL` (`util/appMenuList.js:169`) |
| S2 | `store/internalOps/cycleCount.js:259-266` `saveComment` — `const result = await this.$axios.$patch(\`/cyclecount/${data.id}\`, data)` | item PATCH `/v3/cyclecount/{id}` | `data` = `{ id, comment }` (S2a) | **Live, but an echo only** — see S2a | same as S1. After step 3 the old UI toasts on every page open |
| S2a | `components/internalOps/cycleCount/planned/plannedCycleCountDescription.vue:92` — `this.$store.dispatch('internalOps/cycleCount/saveComment', {id: this.cycleCountItem.id, comment: this.comment})` | — | literal `{id, comment}` | textarea is `readonly` (`readonly` in the `<v-textarea … maxlength="250" … readonly>` block, `:49-58`) | page `/internalOps/cycleCount/planned/:id`, gated `WEB_UI_VIEW_CYCLECOUNT` (`util/appMenuList.js:158`) |
| S3 | `cypress/support/helpers/wmsHelpers.js:400-402` `patchAdvice` — `return cy.wms('PATCH', '/advice/' + adviceId, { body: Object.assign({ id: adviceId }, body) });` | item PATCH | `{id, …body}` | **Dead.** Imported in `cypress/e2e/wms/inbound-receiving/inbound-receiving.cy.js:60` and never called (the only `patchAdvice` hits are the import and the declaration) | the helper should be deleted in step 2 or step 3 |
| S4 | `cypress/support/helpers/wmsHelpers.js:861-863` `patchCycleCount` — `return cy.wms('PATCH', '/cyclecount/' + cycleCountId, { body: { id: cycleCountId } });` | item PATCH | `{id}` | **Live in e2e:** `cycle-count.cy.js:312-318` test `'P1.5 PATCH /cyclecount/{id} (activate) + verify Location # > 0'` asserts `expect(patchResp.status).to.equal(200)` | **breaks at step 3** (405). The "activate" premise is false: a `{id}` PATCH changes nothing. Drop the PATCH and keep the detail GET |
| S5 | `store/receiving/inboundNotices.js:197` — `await this.$axios.$delete(\`/advice/${data.deleteOpenInboundNotices[i].id}\`)` | item DELETE | — | **Dead.** Both triggers are inside HTML comments (`openNotices.vue:31,:100`, established by SBDEV-3183 review H-1); already 405 today | none |
| — | mobile-ui (P9) | — | — | **zero** advice/cyclecount write sites. Positive control: the same pattern matched `store/replenish.js:301 $put(\`/replenish/order/${data.id}\`…)` (4 write-verb sites in total) | none |
| — | oms-laravel-api (P10) | — | — | **zero** `/v3/advice` or `/v3/cyclecount` use. All six advice endpoint keys in `config/wms.php` are `/rest/advice/*` (e.g. `:98 'advice_create' => env('WMS_ADVICE_CREATE_ENDPOINT', 'rest/advice/create')`). Positive control: `:176 'client_update' => env('WMS_CLIENT_UPDATE_ENDPOINT', 'v3/client/{id}')` matched | none (env-override caveat in §8) |
| — | siteboss-frontend (P11) | — | — | zero hits | none |
| — | Jest (P8) | — | — | **zero** specs mention `saveComment`, `/advice/{id}` or `/cyclecount/{id}`. Positive control: the same pattern hit `test/store/admin/shippersPutaway.spec.js` (`$patch('/client/{id}')`) and `test/store/editSaveResult.spec.js` | the step-2 web PR needs new Jest coverage; nothing existing breaks |

**Computed, multi-line and dynamic checks (P3–P6).** Three non-literal first arguments exist:
- `store/admin/labelPrinting.js:256 $post(url, …)`, where the callers pass `url: '/labelPrinting/…'` (`:273-297`).
- `store/processes/clubRuns.js:181 $post(url, …)`, where the callers pass `'/clubLine/…'` (`:414-422`).
- `components/outbound/bol/outboundBolDetails.vue:304 this.$delete(this.requeueingIds, id)`, which is Vue's reactive delete, not HTTP.

One multi-line call exists, `store/admin/configuration.js:409 $put(` → `/putawayConfig/merchant/…`. Generic requests: only
`plugins/tenant-auth-fetch.js:81 fetch(url…)`, the pre-login auth bootstrap. Dynamic dispatch: only
`defaultPutawayLocationField.vue:806 dispatch(action, payload)`, a closed map of putaway-config actions. No `mapActions` pulls
from either module. **None of them resolve to advice or cyclecount.**

**Completeness claim ("these are all the callers").**
- **Method:** the eleven patterns above, run on four repos plus the OMS v2 UI, with each match read individually.
- **Blind spots:**
  - a URL built from string fragments with no `/advice` or `/cyclecount` literal (P3 found none that reach them);
  - deployment-level env overrides of the OMS endpoint keys;
  - out-of-repo clients such as Postman collections, scripts or any non-UI integrator;
  - browser extensions or a user hand-crafting requests, which is the threat itself.
- **Second instrument:** SBDEV-3183 `review-ac2-rules-code.md` reached the same two live callers with different tooling (a route
  trace to `appMenuList`).

### 0.3 Other SDR writes on these two types (`RestConfiguration`)

| Verb | Advice | Cyclecount | Mechanism |
|---|---|---|---|
| collection POST | withdrawn | withdrawn | Advice: `configureAdviceCollectionCreateWriteExposure` (`:640-644`). Cyclecount: `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN` (`:798-801`) via `configureMustStayWritableCollectionCreateWriteExposure` (`:803`) |
| item PUT | withdrawn | withdrawn | Advice `:682-686`; Cyclecount `:877-880` |
| item DELETE | withdrawn | withdrawn | same lines |
| **item PATCH** | **open** | **open** | the subject of this ticket |
| association | n/a | n/a | neither type has a `@ManyToMany`. The `configureUnwrittenResourceWriteExposure` comment says SDR generates only 3 association resources repo-wide |
| PUT-for-creation | covered by item-PUT withdrawal | same | — |

---

## §1 DB facts already gathered (from `db-verification.md`, not re-run)

- Live probe as panderson: PATCHing `externalid` on advice 87150 and `name` on cyclecount 742350 both landed (and were restored).
  The outbox and message tables were unchanged, so **the SDR PATCH path has no OMS side effect**, which matches §5.3.
- 12,626 advice rows, of which 6,443 have a comment (last comment-row `modified` 2025-03-28). 178 cyclecount rows, of which 113
  have a comment (last 2026-10-19, which was the SBDEV-3183 dev test).
- The Advice rows span 122 clients and 3 types (REGULAR, RETURN, TRANSFER).

The SQL for the remaining figures is in §6.

---

## §2 What `saveComment` actually sends

Both dispatch sites build the body inline, so it is **exactly `{id, comment}`, never a whole row**:
- Advice: `closedNoticeDescription.vue:242` → `{ id: this.noticeDetails.id, comment: this.comment }`
- Cyclecount: `plannedCycleCountDescription.vue:92` → `{id: this.cycleCountItem.id, comment: this.comment}`

`saveComment` forwards `data` unchanged as the PATCH body. The response is only `console.log`ged, and errors go to a generic
toast: `this.$toast.error('Error: Request failed due to a network or server issue. Please retry.')`.

**The trigger behaviour matters for the rollout.** It is the same in both components:

    comment(newVal) {
      if (!newVal || newVal.trim() === '') { this.timeout = null }
      clearTimeout(this.timeout)
      this.timeout = setTimeout(() => { … dispatch('…/saveComment', { id, comment: this.comment }) }, 700)
    }

- `setInitialComment()` runs on `mounted` and whenever the details object changes. When the loaded comment differs from the
  previous `comment` value (initially `null`), it fires the watcher, so **every page open with a non-null comment sends one
  write**.
- An empty string also dispatches, because the `this.timeout = null` branch does not return. Clearing the box therefore writes
  `""`.
- Both details objects come from MVC reads, not SDR: `/advice/adviceDetailsById/{id}` (`inboundNotices.js:304`) and
  `/cycleCount/cycleCountDetailsById/{id}` (`cycleCount.js:310`). Each includes `comment`: `AdviceService:499
  details.put("comment", a.getComment())` and `CyclecountService:438 details.put("comment", c.getComment())`.
- Cycle Count: the box is `readonly` (since `9991a48`, "Fixed cycle count create and detail screen form UI inconsistency"), so
  the only values ever sent are echoes of the stored value. An unchanged value means no dirty field, so Hibernate issues no
  UPDATE and `@LastModifiedDate` does not move. That fits `cyclecount`'s newest comment-row `modified` being the 2026-10-19 SBDEV-3183 test,
  not UI traffic.
- `closedCycleCountDescription.vue` also has a `readonly` comment box, and it has **no** `comment` watcher and no dispatch.

---

## §3 RestConfiguration today, and every test that pins the PATCH

### 3.1 Advice (`RestConfiguration.java:682-686`)

    private void configureAdviceItemVerbWriteExposure(RepositoryRestConfiguration config) {
        config.getExposureConfiguration()
            .forDomainType(Advice.class)
            .withItemExposure((metadata, httpMethods) -> httpMethods.disable(HttpMethod.PUT, HttpMethod.DELETE));
    }

Its javadoc: *"Item PATCH is the ONLY item verb left open, and it is genuinely live. {@code saveComment}
({@code store/receiving/inboundNotices.js:378}, {@code {id, comment}} only …)"*. The cited line `:378` is stale: the
declaration is at `:408` and the `$patch` at `:410`. Collection POST is withdrawn at `:640-644` by
`.withCollectionExposure((metadata, httpMethods) -> httpMethods.disable(WRITE_VERBS))`.

### 3.2 Cyclecount (`RestConfiguration.java:877-880`, inside `configureMustStayWritableItemVerbWriteExposure` `:857`)

    config.getExposureConfiguration()
        .forDomainType(Cyclecount.class)
        .withItemExposure((metadata, httpMethods) -> httpMethods.disable(HttpMethod.PUT, HttpMethod.DELETE));

The javadoc table says *"Cyclecount item PUT, DELETE withdrawn — PATCH survives (plannedCycleCountDescription.vue's saveComment,
{id, comment} only)"*. Cyclecount's collection POST is in `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN = { Section.class,
Boxtype.class, Client.class, Location.class, Sysprop.class, Cyclecount.class, UserGroup.class, UserRole.class }` (`:798`).

### 3.3 The two mechanisms

- **`SDR_WRITE_WITHDRAWN`** (`:452`) is applied by `configureUnwrittenResourceWriteExposure` (`:567`). For each listed type it
  disables `WRITE_VERBS = {POST, PUT, PATCH, DELETE}` on the collection, item and association axes. **This is the natural home
  for Advice and Cyclecount in PR 2.**
  - Recommended PR 2 diff: add `Advice.class` and `Cyclecount.class` to `SDR_WRITE_WITHDRAWN`.
  - Delete `configureAdviceCollectionCreateWriteExposure` and `configureAdviceItemVerbWriteExposure`, and their two calls at
    `:889-890`.
  - Remove `Cyclecount.class` from `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN`, and remove its block from
    `configureMustStayWritableItemVerbWriteExposure`.
  - Reads are untouched: both types stay exported, and `exposeIdsFor` is unchanged.
- **`MUST_STAY_WRITABLE`** is a **test-side** set, `SdrWriteWithdrawalContextTest.MUST_STAY_WRITABLE` = Section, Advice, Boxtype,
  Client, Cyclecount, Location, Sysprop, UserGroup (8). Two other tests derive from it.
- **`SdrFunctionRules`** (`security/SdrFunctionRules.java:430-435`):
  `rules.put(net.aim_ai.wms.model.Advice.class, INBOUND_BOL_VIEW);` and
  `rules.put(net.aim_ai.wms.model.Cyclecount.class, CYCLECOUNT_VIEW);`. Their comments say *"Only live SDR caller: PATCH
  /advice/{id} (saveComment)"*. After PR 2 these rules gate **reads only**. Keep them; reads of these types stay
  `WEB_UI_*`-scoped once a tenant enforces. Rewrite the comment.

### 3.4 Tests that pin Advice/Cyclecount PATCH as surviving (all need a PR-2 change)

**Method.** `git grep -l` over `src/test` for `MUST_STAY_WRITABLE|configureAdviceItemVerbWriteExposure|AdviceStateReadOnly|SdrWriteWithdrawal|MustStayWritable|WriteExposure`,
then for `Advice|Cyclecount`, plus a grep for `/v3/(advice|cyclecount)` and `patch(`. Each hit was read.

**Blind spot.** A test that pins the behaviour only by an HTTP status, without naming the type, would be missed. None was found
by the `patch("/v3/` grep.

| # | Test (src/test/java/net/aim_ai/wms/…) | Current assertion | PR-2 change |
|---|---|---|---|
| T1 | `security/AdviceCollectionPostWithdrawalContextTest` `itemPatchRemainsExposed` | `assertThat(…getMethodsFor(ResourceType.ITEM)).as("wms2-web-ui's saveComment PATCHes /v3/advice/{id} …").contains(HttpMethod.PATCH)` | flip to `doesNotContain(HttpMethod.PATCH)`, or fold into one "no item/collection write verb" test. Rename the class `@DisplayName` (*"…PATCH intact"*). Keep `collectionReadsRemainExposed` |
| T2 | `security/MustStayWritableCollectionPostWithdrawalContextTest` | `REQUIRED_ITEM_VERBS = Map.of(… "Cyclecount", Set.of(HttpMethod.PATCH), …)`; `collectionPostIsWithdrawnEverywhere` asserts `checked … .isEqualTo(7)`; `COVERED_ELSEWHERE = Set.of("Advice")`; `unrequiredItemVerbsAreWithdrawn` pins `REQUIRED_ITEM_VERBS.keySet()` == `MUST_STAY_WRITABLE − ITEM_VERBS_AUDITED_ELSEWHERE − COVERED_ELSEWHERE` | remove the `Cyclecount` row. `checked` 7 → **6** (Cyclecount leaves, Advice is already excluded). `COVERED_ELSEWHERE` becomes empty or is deleted, because Advice is no longer in `MUST_STAY_WRITABLE`. Fix the javadoc |
| T3 | `security/SdrWriteWithdrawalContextTest` | `MUST_STAY_WRITABLE` has 8 names including `"Advice"` and `"Cyclecount"`; `resourcesWithLiveWritersRemainWritable` → `assertThat(MUST_STAY_WRITABLE).hasSize(8)`; `withdrawnResourcesExposeNoWriteVerb` → `assertThat(WITHDRAWN).hasSize(51)` | move both names into `WITHDRAWN`: **51 → 53**, `MUST_STAY_WRITABLE` **8 → 6**. Update the "51/8" javadoc arithmetic (a fifth reclassification, since the javadoc already narrates four). `WITHDRAWN = SDR_WRITE_WITHDRAWN + UserRole` still holds if both go into `SDR_WRITE_WITHDRAWN` |
| T4 | `security/SdrMustStayWritableStateNotPatchableContextTest` | sensitivity check `assertThat(typesWithState).isGreaterThanOrEqualTo(2)` (*"Advice and Cyclecount are the two known today"*) | **goes red: 0.** No remaining `MUST_STAY_WRITABLE` type has a `state` field (grepped `private … state` in Section, Boxtype, Client, Location, Sysprop and UserGroup: 0 each). Retire the class, or re-scope it to "every `@Version` entity with a `state` field that is still SDR-writable", which today is none. **Do not lower the threshold to 0.** That makes it vacuous, which the test's own comment forbids |
| T5 | `security/AdviceStateReadOnlyContextTest` | AC-1 `state.isWritable()` false; AC-2 `commentRemainsWritable` asserts `comment.isWritable()` true (*"the field the real saveComment caller writes"*) | still green, since the metadata is unchanged, but the AC-2 rationale becomes false. Re-word it or delete AC-2. Keep `@ReadOnlyProperty` and AC-1 as defence in depth |
| T6 | `unit/security/SdrFunctionRulesUnitTest` `adviceRequiresViewInboundBol` / `cyclecountRequiresViewCyclecount` | `.contains(Set.of(WEB_UI_VIEW_INBOUND_BOL))` with `.as("Advice's only SDR caller is PATCH /advice/{id} (saveComment …)")` | assertion unchanged (the rules stay); messages and `sbdev3183Ac2DomainTypes()` javadoc go stale |
| T7 | `security/SdrUncalledSurfaceNotExportedContextTest` | `MUST_REMAIN_EXPORTED` contains `Advice.class`, `Cyclecount.class` under *"Live SDR WRITE caller"*; javadoc §"Cyclecount is NOT here" cites the `$patch` | still green (both stay exported). Re-label them under a "reads / exported-but-write-withdrawn" heading, the same as `Customerorder` |
| T8 | `security/SdrMutatingSearchNotExportedContextTest` | javadoc only (`:64` `PATCH /v3/advice/{id} {"state":…}`) | prose only |

Not affected (checked, 0 Advice/Cyclecount references): `SdrWriteExposureUnitTest`, `AccessChainSdrWriteExposureUnitTest`,
`SdrSurfaceInventoryContextTest` (asserts only `resources > 20`), and `SdrReadGateEnforcementContextTest`.

Main-code prose that goes stale in PR 2 (comments only):
- `Advice.java:23-30` and `Cyclecount.java` (*"Advice stays on SBDEV-3157's must-remain-writable list, so PATCH … is still
  open"*);
- `AdviceController:139-141`, `:169-171` and `CycleCountController:95-96` (*"the entity KEEPS its SDR write surface"*);
- the `SDR_WRITE_WITHDRAWN` javadoc list *"NOT in this list, deliberately: … advice, … cyclecount"* (around `:430`);
- `SdrFunctionRules:419-421`, which says the Cypress suite PATCHes `/advice` and `/cyclecount`.

---

## §4 Where the new endpoints go

### 4.1 Existing controllers

| Controller | Class mapping | Class-level `@RequiresFunction` | In `FunctionGuardInterceptor.GUARDED`? | Write-handler precedent |
|---|---|---|---|---|
| `controller/AdviceController.java` (404 lines, `extends AdminController`, constructor-injected `AdviceService`, `AdviceRepository`, …) | `@RequestMapping("/v3/advice")` | **none** (method-level only) | no | `setPurchaseOrderNumber` `:139-170`: `@RequiresFunction(WEB_UI_VIEW_INBOUND_BOL)`, `@PostMapping(path= "/setPurchaseOrderNumber", consumes = "application/json", …)`, body `{ id, purchaseOrderNumber }` |
| `controller/CycleCountController.java` (355 lines) | `@RequestMapping("/v3/cycleCount")` (**capital C**, distinct from SDR `/v3/cyclecount`) | none | no | `create` `:76`, `cancel` `:97-99`, `@RequiresFunction(WEB_UI_VIEW_CYCLECOUNT)` |
| `controller/mobile/CycleCountLosController.java` | `/v3/cycleCountLos` | **class-level** `MOBILE_UI_VIEW_CYCLE_COUNT` | yes | **wrong home**: mobile function, and mobile never edits header comments |

**Recommended shape:** `POST /v3/advice/setComment` and `POST /v3/cycleCount/setComment`, body `{id, comment}`.
- It matches the controllers' `set…`/body-id convention (`setPurchaseOrderNumber`).
- The UI already sends exactly `{id, comment}`, so the web change is a verb and URL swap.
- It avoids `/{id}/comment`, which overlaps SDR's `/{repository}/{id}/{property}` association route template. MVC wins on the
  existing `/v3/advice/closeInboundBol/{id}`, but `setComment` removes the question entirely.

A REST-ier `/{id}/comment` is fine too if Nam prefers it. If so, pin it with a test through the real `DispatcherServlet` (§9
AC-A4). `standaloneSetup` cannot see handler-mapping order or the `/v3` prefix (memory:
*Controllers need /v3 prefix; standaloneSetup blind*).

### 4.2 Service methods (neither exists today)

- **No comment setter exists in either service.** `AdviceService`'s only `comment` uses are reads (`:337`, `:499`, `:541`,
  `:548`). `CyclecountService` sets `comment` only in `createEntity` (`:96`). `CyclecountService` has **no** `@Transactional` at
  all.
- New methods: `AdviceService.setComment(Long id, String comment)` and `CyclecountService.setComment(Long id, String comment)`.
  - Annotate with `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class,
    FacadeException.class})` (CLAUDE.md rule).
  - Load with `findById(id).orElseThrow(() -> new EntityNotFoundException("Advice", id))`, `setComment`, then `save`.
- **Write only `comment`.** That is the point of the ticket. Do not bind a map onto the entity.
- **Entity save, not a `@Modifying` UPDATE.** The entity path bumps `@Version` and `modified`. A JPQL UPDATE would not bump
  `@Version`, so a concurrent service save of a stale Advice (no `@DynamicUpdate`, so all columns are written) would silently
  revert the comment rather than fail on the optimistic lock.
- **Length.**
  - `advice.comment` is `character varying(255)` (`V2.2.00__base_v2_schema.sql:621`). `Advice.comment` has no `@Column`
    length. Reject `comment.length() > 255` with a 4xx (`ApiInvalidParameterException`, the SBDEV-3545 `UserRoleController:266`
    precedent) **before** the save.
  - `cyclecount.comment` is `text` (`:898`), so there is no DB cap. The UI uses `maxlength="250"`. A server cap is optional.
  - `AuditCommentUtil.clamp` exists (`util/AuditCommentUtil.java:61`), but clamping silently truncates user text. Prefer
    rejecting, and that is Nam's call.
- **State.** The SDR PATCH allowed comment writes in any state, and the UI edits only on the closed page. Do not add a state
  restriction; that would be a behaviour change outside this ticket.
- **Id parsing.** `setPurchaseOrderNumber` does `((Integer) reqMap.get("id")).longValue()`, which throws a
  ClassCastException for a JSON id above 2^31−1. Use `((Number) …).longValue()`, or a typed DTO.
- **Response.** Use a real 4xx/404 on error, not the legacy `ResponseEntity.ok(errorMap)`. `saveComment`'s try/catch only
  toasts on a thrown axios error, so a 200 with `errors` would be a **silent** failure.

### 4.3 Decision for Nam: the Cycle Count half

The textarea is `readonly` (§2), so there is no user-initiated cyclecount comment write today.

| Option | Description |
|---|---|
| **A** (agreed shape) | Add `POST /v3/cycleCount/setComment`. The web UI keeps the echo-on-load behaviour, now through an MVC write |
| **B** (smaller, no new surface) | The web PR deletes the cyclecount `saveComment` action and the `comment` watcher in `plannedCycleCountDescription.vue` (the box is display-only). No new wms2-api endpoint. PR 2 withdraws PATCH as planned |

B removes a write-on-read and leaves one endpoint fewer to gate and test. The cost is that if product later makes the box
editable, they add the endpoint then. Recommendation: **B**, unless Nam knows the box is meant to become editable.

### 4.4 Gate-test registration for a new gated route

- **`security/Sbdev3017TrancheGateContextTest`** is the golden map keyed on (declaring class, path).
  - It already holds `row("AdviceController","/v3/advice/setPurchaseOrderNumber", "WEB_UI_VIEW_INBOUND_BOL")` and
    `row("CycleCountController","/v3/cycleCount/cancel","WEB_UI_VIEW_CYCLECOUNT")`.
  - Add `row("AdviceController","/v3/advice/setComment","WEB_UI_VIEW_INBOUND_BOL")`, and, under option A,
    `row("CycleCountController","/v3/cycleCount/setComment","WEB_UI_VIEW_CYCLECOUNT")`.
  - Bump `thePinHasNotBeenQuietlyShrunk` `assertThat(EXPECTED).hasSize(231)` to **232 or 233**, with the arithmetic comment.
  - ⚠ Nothing forces a new route into this map. Its drift test checks only that the listed rows are true, so adding the row is
    discipline, and the review lane must check it.
- **UNGATED rows / class-level tripwire.** Neither controller is in `GUARDED`, and both are method-annotated, so a class-level
  `@RequiresFunction` mutation would resolve the same function for these rows and stay green. Existing rows already span
  several functions on `AdviceController` (`WEB_UI_VIEW_CREATE_INBOUND_BOL`, `…_INBOUND_BOL_ITEM_LINES`, `…_INBOUND_BOL`), so a
  class-level default would red other rows there.
  - `CycleCountController`'s rows are **all** `WEB_UI_VIEW_CYCLECOUNT`. A class-level annotation would be invisible to the
    pin.
  - That is a pre-existing gap and the new route does not widen it. Note it, and do not fix it here (scope).
- **`unit/config/FunctionGuardArchTest`** covers only `GUARDED` controllers and the golden class→function map (`GOLDEN_MAP` lists
  `CycleCountLosController` among others). It is **not** touched unless the route lands on a GUARDED class. Do not put it on
  `CycleCountLosController`.
- **Controller unit tests:** `unit/controller/AdviceControllerUnitTest` has an `@Nested` class per route (`SetPurchaseOrderNumber`
  `:199-222`, via `setupMockMvc`). `unit/controller/CycleCountControllerUnitTest` exists too. Memory: `setupMockMvc` has **no**
  interceptor, so 403 behaviour must be proven in a context test. The
  `FunctionGateEnforcementPointContextTest` pattern, or the tranche pin plus one webAppContext MockMvc 403/200 pair, will do.
- Memory "gate tests need UNGATED rows + full varargs": the row must name the full function set. Here it is a single function.

---

## §5 Entity facts

### 5.1 `model/Advice.java` (`@Entity public class Advice extends AbstractBaseEntity`)

The fields: `name`, `@NotNull number`, `allowoverdelivery`, `allowshortdelivery`, `dayofdelivery`, `dayofdeliveryuntil`,
`deliverynotenumber`, `externalid`, `shippedfrom`, `shippedto`, **`@ReadOnlyProperty state`**, `type`,
`@NotNull @Column(name = "client_id") clientId`, `comment`, `supplier`, `@Column(name = "transfer_id") transferId`,
`purchaseordernumber`, `note`.

Every field except `state` and the inherited `id`/`created`/`modified`/`version` is PATCH-bindable today. Impact examples:
- **Cross-client moves.** `clientId` can move an advice to another of the 122 clients.
- **Retyping.** `type` can turn a RETURN or TRANSFER into REGULAR.
- **Receiving tolerances.** `allowoverdelivery` enables over-receipt.
- **Transfer lookups.** `transferId` and `externalid` key transfer lookups: `AdviceRestController:639
  adviceRepository.findByTransferId(...)`, `:771`, and `:819 candidate.getExternalid().equals(parcel.getShippersId())`.

### 5.2 `model/Cyclecount.java`

`@NotNull number`, `name`, `@NotNull clientId`, `@NotNull type`, `@NotNull subtype`, **`@ReadOnlyProperty @NotNull state`**,
`@Column(columnDefinition = "text") comment`.

### 5.3 Columns, versioning, caches, side effects

- **`AbstractBaseEntity`.** `@MappedSuperclass @EntityListeners(AuditingEntityListener.class)`; `@Id @GeneratedValue(SEQUENCE)
  Long id`; `@CreatedDate created`; `@LastModifiedDate modified`; `@Version Integer version` (boxed). Equality is id-based
  (memory).
- **Columns.** `advice.comment character varying(255)` (`V2.2.00:621`); `cyclecount.comment text` (`:898`). No later `ALTER`
  touches either column; the only advice/cyclecount ALTERs are the onboarding UTC timestamp changes.
- **Caches.** There is **no** `@Cacheable`, `@CacheEvict` or `@CachePut` on Advice or Cyclecount. The grep matched only a
  comment at `AdviceRestController:197` and a memo note at `CyclecountService:292`.
- **SDR event handlers.** `PutawayConfigRepositoryEventHandler` is the only `@RepositoryEventHandler`, and it handles
  `Itemdata`, `Client` and `Sysprop` only.
- **JPA and Hibernate listeners.** No `@PreUpdate` or `@PostUpdate` exists anywhere in `src/main/java`. No Hibernate
  `PostUpdateEventListener`, `Integrator` or `@TransactionalEventListener` exists either.
- **OMS side effects.** An Advice or Cyclecount save does **not** reach OMS. OMS notification is driven explicitly from service
  state transitions such as close or finish, not from entity persistence. The dev probe confirmed it: outbox 20 → 20, message
  unchanged.
  - The new `setComment` must keep it that way: call no `AdviceService` state method and no `OmsNotificationService`.
  - **Method:** a grep for listener and handler annotations across `src/main/java`.
  - **Blind spot:** a DB trigger (none known; not checked in this pass).

---

## §6 DB verification SQL (not run here; run on `dev_wh01_om1`)

    -- 6.1 comment population (re-run of db-verification §2, plus length risk)
    select 'advice' t,
           count(*)                                              as total,
           count(*) filter (where comment is not null)            as comment_not_null,
           count(*) filter (where coalesce(comment,'') <> '')     as comment_nonblank,
           max(length(comment))                                   as max_len,
           count(*) filter (where length(comment) > 250)          as len_gt_250,
           count(*) filter (where state = 'FINISHED' and coalesce(comment,'') <> '') as closed_with_comment
    from advice
    union all
    select 'cyclecount', count(*),
           count(*) filter (where comment is not null),
           count(*) filter (where coalesce(comment,'') <> ''),
           max(length(comment)),
           count(*) filter (where length(comment) > 250),
           null
    from cyclecount;
    -- (Check the advice "closed" state literal against WmsConstants.AdviceState before reading closed_with_comment.)

    -- 6.2 distinct users holding each function (group chain; direct user->role is unused in v2, per memory)
    select f.name                         as function_name,
           count(distinct gu.userlist_id) as users_holding
    from mywms_function f
    join mywms_role_mywms_function rf on rf.functionlist_id = f.id
    join mywms_group_mywms_role    gr on gr.rolelist_id     = rf.rolelist_id
    join mywms_group_mywms_user    gu on gu.grouplist_id    = gr.grouplist_id
    where f.name in ('WEB_UI_VIEW_INBOUND_BOL', 'WEB_UI_VIEW_CYCLECOUNT')
    group by f.name
    union all
    select 'ANY_FUNCTION (denominator)', count(distinct gu.userlist_id)
    from mywms_group_mywms_user gu
    join mywms_group_mywms_role    gr on gr.grouplist_id = gu.grouplist_id
    join mywms_role_mywms_function rf on rf.rolelist_id  = gr.rolelist_id
    union all
    select 'ALL_USERS', count(*) from mywms_user;

    -- 6.3 (optional) is the readonly Cycle Count box really never edited? rows whose modified moved after creation
    select count(*) filter (where modified > created + interval '1 minute') as cc_modified_after_create,
           count(*) as total
    from cyclecount;

Expected, from the 2026-10-22 census: INBOUND_BOL 42 and CYCLECOUNT 44 of 53 function holders. 6.2 re-derives those figures by
counting **users**, not roles (memory AC-2′). If `mywms_user_mywms_role` exists, add a union over it to confirm it contributes 0.

---

## §7 Prior art

- **SBDEV-3157** withdrew the write verbs on 48 types with no writers (later 51). It kept Advice and Cyclecount writable
  because `saveComment` PATCHes them (`RestConfiguration` `SDR_WRITE_WITHDRAWN` javadoc: *"NOT in this list, deliberately: …
  advice, … cyclecount"*).
- **SBDEV-3215**:
  - added `@ReadOnlyProperty` on `Advice.state` and, after review H-1, on `Cyclecount.state`;
  - withdrew `POST /v3/advice`, because collection create bypasses `@ReadOnlyProperty` via `em.merge` when `version` is
    present;
  - review `4-Archieves/wms2/plan/SBDEV-3215-evidence/review-code.md:52` confirmed that the only PATCH caller is
    `saveComment {id, comment}`, that `patchAdvice` is imported but never called, and that mobile has zero `$patch`.
- **SBDEV-3183 AC-2:**
  - **Collection POST on the remaining types.** It withdrew collection POST on the remaining `MUST_STAY_WRITABLE` types,
    Cyclecount included.
  - **Item verbs.** It withdrew item PUT/DELETE on Advice (review H-1: the `deleteOpenInboundNotices` triggers are commented
    out) and on Cyclecount. It kept PATCH for `saveComment`.
  - **Function rules.** It added the `SdrFunctionRules` rules Advice → `WEB_UI_VIEW_INBOUND_BOL` and Cyclecount →
    `WEB_UI_VIEW_CYCLECOUNT`. These enforce nothing while tenants are at OFF.
- **The direct origin of this ticket** is `4-Archieves/wms2/plan/SBDEV-3183-evidence/review-ac2-rules-security.md` finding
  **S1 (MEDIUM)**. It says *"every other field binds: clientId, type, allowoverdelivery, …"* and recommends a follow-up: *"Move
  saveComment to a field-scoped MVC endpoint (for example `POST /v3/advice/{id}/comment` with
  `@RequiresFunction(WEB_UI_VIEW_INBOUND_BOL)`) and withdraw the SDR item PATCH. Alternatively add a `@HandleBeforeSave` that
  refuses changes to anything but comment/note. Do the same for Cyclecount."*
  - **Do not take the `@HandleBeforeSave` alternative.** It fences only the PATCH path and is verb-blind. Withdrawal plus a
    typed endpoint is the stronger design, and it matches the SBDEV-3545 `UserRole` precedent (an SDR write moved to the gated
    `POST /v3/userRole/update`, then withdrawn).
- `review-docs-and-ticket-2026-10-18.md:52`: the claim "UI sends only comment" is imprecise, because the body also carries `id`.
- **Workflow docs.**
  - `wms2-receiving-putaway-workflow.md` has **no** mention of comments or PATCH (grep `comment|saveComment|PATCH`: 0).
  - `wms2-cycle-count-workflow.md:46` lists `comment` among the `Cyclecount` fields, and `:63` shows the create body. The doc
    has nothing about editing a header comment.
  - Both are unaffected, except that a "Cycle count header comment is set at create only (UI box is read-only)" line would be
    accurate to add if option B is chosen.

---

## §8 Risks in the three-step rollout

1. **Two hard ordering constraints across independently promoted repos.** Merges here go to `develop` only, and devops promotes
   `release` and `main`.
   - Constraint 1: PR 1 must be live wherever the web PR is live. Otherwise `POST …/setComment` gets a 404 and the user sees
     the generic toast.
   - Constraint 2: the web PR must be live wherever PR 2 is live. Otherwise the old UI gets a 405. On Advice that is a toast
     after each typing pause on closed notices. On Cycle Count it is a toast **on every planned cycle-count open that has a
     comment** (the echo-on-load).
   - Current lag: wms2-api `develop` is **120** commits ahead of `release`/`main`, wms2-web-ui **11**. Both `release` and `main`
     still carry today's PATCH exposure and today's UI.
   - The API's 120-commit backlog makes it plausible that **PR 1 and PR 2 reach `release` in the same promotion batch**,
     before the web PR has.
   - Mitigations:
     - (a) hold PR 2 on a separate ticket or branch, merged to `develop` only after the web PR is on `main`;
     - (b) tell devops explicitly, in the PR body and on ClickUp, that PR 2 must not be promoted ahead of the web PR;
     - (c) consider shipping PR 2 a full release cycle later.
   - Note also memory *":develop tag race, both v2 repos — older code deploys"*. Even on dev, confirm the web image includes
     the change, via `actuator/info` or the bundle, before merging PR 2.
2. **Cypress.**
   - `cycle-count.cy.js` P1.5 asserts a PATCH status of 200, so it goes red at step 3.
   - `patchAdvice` is dead (imported only).
   - The web PR (step 2) should remove the P1.5 PATCH, keeping its detail-GET assertion, and delete both helpers.
   - Cypress does not run in CI here: the workflows run docker build plus a Portainer webhook, and no `cypress` step was
     found. So nothing gates on it, but the manual e2e run will red.
   - `SdrFunctionRules:419` also documents the Cypress user needing INBOUND_BOL and CYCLECOUNT for those PATCHes. That
     sentence goes stale.
3. **Mobile UI.** No exposure: zero callers (§0.2, with positive control). Mobile cycle-count writes go through
   `/v3/cycleCountLos/*`, which is untouched.
4. **OMS.** No `/v3/advice` or `/v3/cyclecount` use. The residual risk is an env override of an advice endpoint key, which
   `RestConfiguration`'s javadoc already notes as unverifiable from the repo. All defaults point to `/rest/advice/*`.
5. **The new endpoint must not widen anything.**
   - It needs the same function the screen already requires (no user who reaches the screen is denied).
   - It must write only `comment`, and it must enforce the 255 cap before the DB does.
   - Under SHADOW or OFF the SDR guard does not see MVC routes. `@RequiresFunction` is always enforcing, so **the new route
     is stricter than today's PATCH from day one**.
   - A user without INBOUND_BOL who somehow sat on the closed-notice page (they could not, because the route guard blocks
     them) would lose comment save. That is the intended effect.
6. **Optimistic-lock collisions.**
   - An entity load-modify-save takes the `@Version` check. If a comment save races `closeInboundBol` or another service write
     on the same advice, it gets `ObjectOptimisticLockingFailureException`.
   - The SDR PATCH has the same window, so this is not a regression. Map it to a 409 rather than a 500 if the existing
     handler does not already.
7. **Test fallout in PR 2 (§3.4).** Seven classes change. T4 is the trap, because it reds for a structural reason and invites a
   vacuous "fix".
8. **Behaviour preserved, quirk carried forward.** An empty comment (`""`) is sent and saved today (§2). The new endpoint should
   accept `""` and `null` (clearing), or the Advice "clear the box" path breaks.

---

## §9 Candidate acceptance criteria (failing-first)

### wms2-api PR 1 (endpoints; SDR PATCH kept)

- **AC-A1 (gate pin).** `Sbdev3017TrancheGateContextTest.EXPECTED` contains `AdviceController /v3/advice/setComment →
  WEB_UI_VIEW_INBOUND_BOL`, and `everyTrancheRouteCarriesItsIntendedFunctions` is green. Red before the route exists, because
  the drift test fails on a row naming a nonexistent route. Size pin 231 → 232. (Option A adds
  `CycleCountController /v3/cycleCount/setComment → WEB_UI_VIEW_CYCLECOUNT`, 233.)
- **AC-A2 (only comment is written).** A context or IT test seeds an Advice with known `externalid`, `clientId`, `type`,
  `allowoverdelivery` and `state`, then POSTs `{id, comment:"x", externalid:"EVIL", clientId:<other>, type:"REGULAR",
  allowoverdelivery:true, state:"FINISHED"}`. The reloaded row has `comment == "x"` and **every other column unchanged**.
  - Mutation check: bind the body map onto the entity, which must turn it red.
  - Assert by id (memory: repo tests commit).
- **AC-A3 (function enforced).** Through the real filter chain (webAppContext MockMvc or the
  `FunctionGateEnforcementPointContextTest` harness), a user holding nothing gets **403**, and a user holding
  `WEB_UI_VIEW_INBOUND_BOL` gets **2xx** and the row changes. Mutation check: remove the `@RequiresFunction`, which must turn
  the 403 case red.
- **AC-A4 (routing).** `POST /v3/advice/setComment` resolves to `AdviceController`'s handler, not SDR: assert on the
  `HandlerMethod` bean type from `RequestMappingHandlerMapping` for that request. (This is required if the `/{id}/comment`
  shape is chosen instead.)
- **AC-A5 (length).** A 256-char comment returns 4xx (400) and the row is unchanged. A 255-char comment returns 2xx. Mutation
  check: remove the check, which must turn it red (DataIntegrityViolation / 500).
- **AC-A6 (clearing).** `{id, comment:""}` and `{id, comment:null}` both succeed and persist `""` or `null`.
- **AC-A7 (not found).** An unknown id returns 404 (`EntityNotFoundException`), not a 200 with an `errors` map.
- **AC-A8 (no OMS side effect).** After a successful comment save, the `outbox_message` count is unchanged, or (unit) mocks show
  `verifyNoInteractions(omsNotificationService / outboxService)`. Mock style memory: no `any()` on primitives inside `never()`.
- **AC-A9 (transaction manager).** The new service method's `@Transactional` names `tenantTransactionManager`. The existing
  `TestClassTransactionManagerArchTest` / tenant-TM arch rules cover it; confirm the rule includes the service package.

### wms2-web-ui PR (Jest)

- **AC-W1.** `store/receiving/inboundNotices.js` `saveComment({}, {id: 7, comment: 'c'})` calls `$axios.$post('/advice/setComment',
  {id: 7, comment: 'c'})` and **never** `$patch`. This is red today, because today it calls `$patch('/advice/7', …)`.
- **AC-W2 (option A).** `store/internalOps/cycleCount.js` `saveComment` → `$post('/cycleCount/setComment', {id, comment})`, never
  `$patch`. **(Option B instead:)** the cycleCount module exports no `saveComment`, and mounting `plannedCycleCountDescription.vue`
  with a details object carrying a comment dispatches **nothing** after timers advance (`jest.advanceTimersByTime(700)`). Red
  today, because the watcher dispatches on load.
- **AC-W3 (repo-wide invariant, not an instance).** A Jest source scan over `store/**/*.js` finds no `$patch(` or `.patch(` whose
  path starts with `/advice/` or `/cyclecount/`. It must cover template-literal and `'+'` forms, and it is mutation-checked by
  reinserting the old line.
- **AC-W4 (Cypress hygiene; not CI-gated, checked by review).** `wmsHelpers.js` exports no `patchAdvice` or `patchCycleCount`,
  and `cycle-count.cy.js` P1.5 issues no PATCH.

### wms2-api PR 2 (withdrawal)

- **AC-B1.** `ResourceMappings.getMetadataFor(Advice.class)` and `(Cyclecount.class)` expose **no** write verb on the collection
  or item axes (T1 flipped). Both are in `SdrWriteWithdrawalContextTest.WITHDRAWN` (size 53), and `MUST_STAY_WRITABLE` has size
  6 and contains neither.
- **AC-B2 (live, through the stack).** A context MockMvc `PATCH /v3/advice/{id}` and `PATCH /v3/cyclecount/{id}` returns **405**.
  Mutation check: re-enable PATCH, which must turn it red.
- **AC-B3 (reads survive).** `GET /v3/advice/{id}` and `GET /v3/cyclecount/{id}` are still exported (collection GET is present).
  `SdrUncalledSurfaceNotExportedContextTest` stays green. Through the stack they return 200 at OFF.
- **AC-B4 (T4 resolution, explicit).** `SdrMustStayWritableStateNotPatchableContextTest` is either deleted, with the reason
  recorded in the commit, or re-scoped so that it still finds at least one subject. It must not pass vacuously.
- **AC-B5 (MVC path unaffected).** AC-A3's 2xx case still passes after the withdrawal, so the comment save works with SDR PATCH
  gone.
- **Manual (dev, post-merge).** As panderson, `PATCH /v3/advice/87150 {"externalid":…}` → **405**, and the UI comment save on
  `/receiving/closedNotice/:id` persists. Snapshot and restore as in `db-verification.md`.

---

## Claim register (completeness words)

| Claim | Method | Blind spots |
|---|---|---|
| "only two live callers (S1, S2)" | P1–P11 grep on origin/develop of 4 repos plus siteboss main; each hit read; dynamic dispatch and computed URLs resolved by hand | non-literal URL fragments; out-of-repo clients; env overrides |
| "zero mobile / OMS callers" | P9/P10 with positive controls (`/replenish/order` PUT; `v3/client/{id}`) | as above |
| "no Jest spec mocks these" | P8 over `test/` with positive control | specs outside `test/` (none by convention) |
| "every test that pins PATCH" (§3.4) | name and mechanism grep, then an `Advice\|Cyclecount` grep over the hits, then a read | a test asserting a PATCH status without naming the type or path |
| "no other MUST_STAY_WRITABLE type has `state`" | grep `private <T> state` in the 6 model files | an inherited `state` (none: `AbstractBaseEntity` has none) |
| "no cache / listener / OMS hook on save" | grep for `@Cacheable/@CacheEvict/@CachePut`, `@RepositoryEventHandler`, `@Pre/PostUpdate`, Hibernate listener types, plus the dev outbox/message counts | DB triggers (not checked); AOP aspects matching repository `save` (not checked; a follow-up grep of `@Aspect` is cheap) |
| "Cycle Count box never user-editable" | `readonly` attribute at origin/develop, plus `git log -S readonly` (`9991a48`) | an earlier deployed UI build without `readonly` (UAT/prod web `main` should be checked: same file at `origin/main`) |
