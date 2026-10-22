# Adversarial review — `6280d34c` (SBDEV-3183, Customerorder SDR write withdrawal)

Reviewer lane: `rev-co`. Read-only against the reviewed worktree; all builds run in a private
detached worktree at `6280d34c`
(`/tmp/claude-1000/.../scratchpad/rev-co-wt`). Reviewed worktree left untouched
(`git status --porcelain` clean in my tree after every mutation).

Toolchain: `JAVA_HOME=~/.sdkman/candidates/java/current` (OpenJDK 21.0.11), Maven 3.9.15 —
`mvn` is **not** on the default PATH, so a naive verify row here would have recorded 127 as a FAIL.

---

## PRIMARY VERDICT — I could not break the dead-code claim. It holds.

**No live writer to the Spring Data REST path `/v3/customerorder` exists in any of the seven places
I looked.** The commit's core claim survives an adversarial hunt aimed specifically at the
`LockOverviewDtoView` failure shape (URL assembled from a variable).

The strongest positive evidence is not a grep — it is mutation **M1** below, which proves the four
verbs really were open at `452d3ed4` and are really closed now.

### What I searched, and the result

All searches ran against `origin/develop` of each repo (freshly fetched: web-ui `3117acac`,
mobile-ui `c79e81c3`, oms-laravel-api `be0f6a8b`), never a working checkout.

**1. The bare symbol.** One hit repo-wide, its own declaration:

`wms2-web-ui store/common/order.js:13` — `async updateCustomerOrder(context, data) {`, body
`` await this.$axios.$patch(`/customerorder/${data.id}`, data) ``. `store/common/` contains exactly
one file. Zero hits in wms2-mobile-ui.

**2. Every write-verb axios call in both UIs, enumerated rather than pattern-matched.** I listed all
144 non-GET axios call sites in web-ui and all 36 in mobile-ui, then filtered for the ones whose
**first argument is not a literal beginning with `/`** — the exact blind spot that hid
`'/' + resource + '/search/...'` last time. Only two survive that filter, and neither can reach
customerorder:

- `store/admin/labelPrinting.js:256` — `const result = await this.$axios.$post(url, payload)`. `url`
  is a parameter. Its only producers are four literals inside the same file:
  `url: '/labelPrinting/totes/generate'`, `'/labelPrinting/totes/reprint'`,
  `'/labelPrinting/locations/print'`, `'/labelPrinting/unitLoads/reprint'`.
- `store/admin/configuration.js:406` — `await this.$axios.$put(` with the URL on the following line;
  it is the `/putawayConfig/...` family, and the file's own comment at :388 warns
  "⚠ NOT `$patch('/client/{id}')`".

**3. Vuex dispatch, every form.** `mapActions` appears **zero** times in wms2-web-ui — so the whole
`mapActions` class of hidden caller is empty, not merely unmatched. There is exactly one dispatch
whose action name is a variable: `components/admin/parametersAndConfiguration/defaultPutawayLocationField.vue:806`,
`const ok = await this.$store.dispatch(action, payload)`. `action` comes from `writeActionForScope()`
at :760, a closed literal map — `WAREHOUSE`/`MERCHANT`/`SKU` →
`admin/configuration/set*PutawayDestination`, `return BY_SCOPE[this.scope] || null`. It cannot
produce `common/order/updateCustomerOrder`. Every other dispatch in both repos is a string literal,
and no literal anywhere names `common/order`.

**4. `transferlaneId`.** Zero occurrences in wms2-web-ui. In wms2-mobile-ui the transfer-lane flow
exists but goes to MVC, not SDR: `store/transferOrder.js:107` —
`await this.$axios.$post('/transferOrder/processScanTransferLane', data)`.

**5. Cypress.** Every `/customerorder` touch is a read.
`cypress/support/helpers/wmsHelpers.js:1085` — `return cy.wms('GET', '/customerorder/' + customerOrderId);`
(note: a **concatenated** URL, so a literal-only grep would have missed it — it is still a GET);
`cypress/e2e/wms/smoke/phase1-submit.cy.js:82` reads
`'/customerorder/search/findByKeyword?keyword=' + encodeURIComponent(orderLabel)`. A targeted search
for `cy.wms('POST'|'PUT'|'PATCH'|'DELETE', '/customerorder...` returns nothing.

**6. oms-laravel-api — this is where I expected to break the claim, and it is the strongest
disconfirmation I found for my own hypothesis.** OMS *does* write to WMS over SDR, and
`WmsApiService.php:367` says so out loud: *"the only PATCH targets are Spring Data REST entity
resources (/v3/&lt;rel&gt;/{id})"*. But every WMS call goes through
`makeWmsRequest($fullUrl, …, $method, …)` whose URL comes from `getWmsEndpoint('<literal key>')`
against `config/wms.php`. I resolved **all 35 call sites** back to their endpoint key. The 11
non-GET/POST sites are `sku_create`, `sku_delete`, `order_finished_transfer`, `advice_create`,
`advice_create_transfer`, `advice_hub_and_spoke`, `order_create`, `client_update`,
`facility_update`, plus a hard-coded `$url = $host . '/rest/advice/create'`. The **only** SDR PATCH
in the whole service is line 3281, and its endpoint is `'client_update' => 'v3/client/{id}'`. The
config map contains **no customerorder key at all**; all order traffic is `rest/order/create`,
`rest/order/cancel`, `rest/order/updatePriority`, `rest/order/cancelPositions`,
`rest/order/finishedTransfer`, `rest/order/statusChange`, `rest/order/finishedQA`. The one
variable-key call, `TransactionReportService.php:2395`, is assigned nine lines above it:
`$endpoint = 'transaction_report_detailed';`.

**7. The gitignored `reports/` tree.** Moot today: `git ls-tree -r origin/develop | grep ^reports/`
returns **0 tracked files** in web-ui, and **no `reports/` directory exists on disk** in either UI
checkout. There is nothing there to hide a caller.

### What these methods cannot see — state this alongside the verdict

- **Only tracked files at `origin/develop`.** An uncommitted local branch, a developer's working
  tree, or a feature branch not yet merged could add a writer. I did not sweep all remote branches.
- **Only these four repos.** wms2-web-ui, wms2-mobile-ui, oms-laravel-api, wms2-api. Any external
  consumer — an operator's script, Postman collection, an integration partner, a BI tool with the
  service token — that PATCHes `/v3/customerorder/{id}` is invisible to every method above and
  **will break**. This is the only residual break risk I can identify, and it is unfalsifiable from
  source. A dev/UAT access-log query for non-GET `/v3/customerorder` would close it; I did not have
  a log source to run that against.
- **Env-var override.** Every OMS endpoint is `env('WMS_*_ENDPOINT', '<default>')`. I verified the
  committed defaults; a deployed `.env` could in principle repoint `client_update` (or any key) at
  `v3/customerorder/{id}`. Vanishingly unlikely, and not checkable from the repo.
- **Runtime reflection / string assembly across files.** I resolved every non-literal URL and every
  non-literal dispatch to its producers, but a producer built by concatenating fragments across
  module boundaries would still evade me. Nothing in either UI has that shape today.

---

## Findings

### M-1 (Medium) — `Sbdev3017TrancheGateContextTest` still asserts, as present-tense fact, exactly what this commit falsified

The commit touched three files and left the one place in the codebase that **most loudly documents
the opposite** untouched. `src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java`
around :360–:371 still reads:

> `🔴 RESIDUAL — FOUR OF THESE TEN GATES DO NOT CLOSE THE CAPABILITY.`
> … `Customerorder is SDR-exported and is NOT in RestConfiguration.SDR_WRITE_WITHDRAWN (deliberately`
> `— it has a live UI writer at its SDR path, wms2-web-ui store/common/order.js "$patch(`/customerorder/"),`
> `so PATCH /v3/customerorder/{id} {"transferlaneId":…, "state":…} reproduces the mutation for`
> `any wms_user holding ZERO functions.`

Three claims here are now false: Customerorder *is* in `SDR_WRITE_WITHDRAWN`; the "live UI writer"
is the dead code this commit disproved; and the PATCH no longer reproduces the mutation. The
"four of ten gates" residual is now three.

Why this is Medium and not Low: this is a **security residual note** in the very test that pins the
SBDEV-3017 gates. It names `store/common/order.js` as the reason to keep Customerorder writable.
A future engineer removing this commit's withdrawal would find this file agreeing with them, in the
same repo, in prose that reads as measured fact. That is the re-open path the new test's javadoc
says it exists to prevent — and it is left standing three files away. Fix: update that comment
block to say the Customerorder half is closed by SBDEV-3183 and point at
`CustomerorderTransferLaneSdrWriteContextTest`.

### M-2 (Medium) — `SdrWriteWithdrawalContextTest`'s javadoc now says the exact opposite of its own assertions, including the literal string "47/11, not 48/10"

The commit changed both assertions (`hasSize(47)`→`48`, `hasSize(11)`→`10`) but not one word of the
class javadoc above them. `src/test/java/net/aim_ai/wms/security/SdrWriteWithdrawalContextTest.java`:

- :26 — "`{@link #WITHDRAWN} — 47 resources that must expose NO write verb.`" (now 48)
- :29 — "`{@link #MUST_STAY_WRITABLE} — 11 resources that must KEEP their writes.`" (now 10)
- :31 — "`a blanket withdrawal would … break eleven screens`"
- :34 — "`47/11, not 48/10.`" — now precisely inverted; it **is** 48/10
- :39–:40 — "`47 of the 58 writable exported resources have no writer at all … The remaining 11 do`"
- :43 — "`Why RestConfiguration.SDR_WRITE_WITHDRAWN holds 48 and this set holds 47`" (now 49 and 48)
- :45 — "`the totals reconcile as 47 new + 11 kept = the 58 writable resources`"

This is the same defect the file itself warns about 130 lines lower, at :158–:160: *"The count lives
here, not in @DisplayName. A literal in the name cannot be checked by anything and drifts silently:
this file shipped saying '48'/'10' after the Section correction moved the split to 47/11, and the
javadoc fix missed both @DisplayNames."* The commit repeated that exact mistake in the opposite
direction. Seven stale numbers in one javadoc is past the threshold where a reader starts trusting
the prose over the assertion.

### M-3 (Medium) — `SdrUncalledSurfaceNotExportedContextTest` still classifies Customerorder as a live SDR **writer**

`src/test/java/net/aim_ai/wms/security/SdrUncalledSurfaceNotExportedContextTest.java:187` opens a
section `// ── Live SDR WRITE caller (the original eleven) ──` and :192 lists
`net.aim_ai.wms.model.Customerorder.class` inside it. The test's own assertion message at :328 reads
"`These eleven resources each have a live Spring Data REST writer in wms2-web-ui, wms2-mobile-ui or
oms-laravel-api.`"

The test still **passes** — correctly, because Customerorder must stay exported and the test only
checks export. But its classification is now wrong, and this is the second file (after M-1) that a
future reader would cite as evidence that Customerorder has a live writer. Customerorder belongs in
the READ-caller half of that array now, with the section comment corrected to ten.

Positive note on this file: it is not merely stale — mutation M2 showed it is the **redundant rail**
that also catches an accidental un-export (see §3).

### L-1 (Low) — commit-message and javadoc method 1 overstates its own reach slightly

The javadoc says method 1 was "`bare symbol updateCustomerOrder over ALL tracked files`". Accurate
as written, but "all tracked files" is at `origin/develop` only. Worth one clause naming that bound,
since the six-way list reads as exhaustive and the two limitations that actually matter (external
non-UI clients; unmerged branches) are not among the six. The javadoc is otherwise the most
carefully-hedged one in this file set.

### L-2 (Low) — `SdrCacheEvictionEventHandler`'s javadoc reference is unaffected but the pattern is worth noting

`src/main/java/net/aim_ai/wms/config/SdrCacheEvictionEventHandler.java:90` cites
`RestConfiguration.SDR_WRITE_WITHDRAWN` as the reason `PATCH /v3/itemdata/{id}` answers 405. That
claim is about Itemdata and is untouched. No change needed — recorded only because I checked it as
part of §1 below and it is the one cross-reference to the edited array outside the tests.

---

## Secondary questions

### 1. Does the withdrawal break anything other than a direct SDR write? **No.**

- **SDR event handlers.** Two exist: `PutawayConfigRepositoryEventHandler` and
  `SdrCacheEvictionEventHandler` (the recent one). I read every handler method in the latter — it
  covers exactly four types, `Client`, `Location`, `Sysprop`, `Itemdata`
  (`SdrCacheEvictionEventHandler.java:134–188`). **Customerorder has no SDR event handler**, so
  there is no handler left dangling and no cache left un-evicted.
- **Projections.** `grep -rn "@Projection" src/main/java` returns exactly one line, and it is a
  comment in `UserRepository` saying no `User` projection exists. **No projection on Customerorder.**
- **`@RestResource` associations pointing at Customerorder.** None. `RestConfiguration.java:445–453`
  documents that SDR generates exactly three association resources repo-wide (`User.groups`,
  `UserGroup.roles`, `UserRole.functions` — the only `@ManyToMany @JoinTable` mappings); everything
  else uses manual FK columns, so `isAssociation()` is false. Customerorder owns none. The
  `withAssociationExposure(...)` line in the loop is inert for this type, as its own comment says.
- **POST-to-collection creation.** Nothing creates a Customerorder over SDR. Order creation is
  `rest/order/create` (`config/wms.php:39`) → `CustomerorderService`. Confirmed above.
- **Search resources are untouched.** The loop disables verbs on `COLLECTION` and `ITEM` exposure
  only; `getSearchResourceMappings` is a separate axis. All 20-odd `@RestResource` finders on
  `CustomerorderRepository` (`findByKeyword`, `findByNumber`, `getOrderViewsByBatchId`, …) keep
  working. `SdrUncalledSurfaceNotExportedContextTest:261` even measures it: *"Customerorder reports
  21, Billoflading (withdrawn) reports 0"* — and that test is green at this commit.
- **One thing the withdrawal does NOT close, worth recording (not a defect in this commit).**
  `CustomerorderRepository` carries three `@Modifying` bulk-update queries — `updateStateByIds` :160,
  `markClientHasNoSection` :188, `releaseDueFutureTransferOrders` :210 — none annotated
  `@RestResource(exported = false)`. Write-verb withdrawal does not touch search resources, so if SDR
  publishes any of these as a search resource it would be a mutating GET, which is SBDEV-3155's axis,
  not this one. I did not confirm whether SDR actually publishes `@Modifying` void/int methods
  (Spring Data REST normally skips them), so this is a **pointer for a follow-up probe, not a
  finding**. It does not affect this commit's correctness either way.

### 2. Are the reads genuinely untouched? **Yes — verified by running, and by two mutations.**

`WRITE_VERBS` is `{POST, PUT, PATCH, DELETE}` (`RestConfiguration.java`, definition immediately above
the array) and the loop calls only `httpMethods.disable(WRITE_VERBS)`. GET is never named.

Verified at runtime, not read: `CustomerorderTransferLaneSdrWriteContextTest#customerorderReadsRemainAvailable`
passes at `6280d34c`, asserting `hasMappingFor`, `isExported()`, and that ITEM still contains
`HttpMethod.GET`. The three read paths the commit claims are the real ones:
`store/masterData/customerOrder.js:29,46` (`$get('/customerorder' + urlPart)` and
`$get('/customerorder/search/findByKeyword' + urlPart)`), `store/processes/transferPicking.js:143`
(`` $get(`/customerorder/${data.orderId}`) ``), `components/outbound/bol/outboundBolDetailsTable.vue:200`
(`` $get(`/customerorder/${item.id}`) `` — a **fourth** reader the commit does not mention, also a
GET, also fine), and the Cypress collection read at `smoke/phase1-submit.cy.js:82`.

### 3. Is the new test non-vacuous, and does it duplicate `SdrWriteWithdrawalContextTest`? **Non-vacuous. The duplication argument is HALF right — I do not fully accept it.**

**Non-vacuity — both halves mutation-checked in my own worktree, both red for the right reason:**

- **M1** — deleted `net.aim_ai.wms.model.Customerorder.class` from `SDR_WRITE_WITHDRAWN`:
  `customerorderExposesNoSdrWriteVerb` FAILED with
  `Expecting empty but was: ["collection:POST", "item:DELETE", "item:PUT", "item:PATCH"]`.
  This independently confirms the exploit premise: those four verbs really were open before this
  commit, including `item:PATCH`.
- **M2** — closed it the wrong way, `@RepositoryRestResource(..., exported = false)` on
  `CustomerorderRepository`: `customerorderReadsRemainAvailable` FAILED with
  `"Customerorder must stay EXPORTED..."`.

Both matched the commit message's claimed mutation results exactly. Baseline at `6280d34c`: 7/7
green across the three SDR context tests; and `Sdr*Test,Customerorder*Test,Sbdev3017*Test` (roughly
190 tests across 30 classes) all green, so nothing elsewhere depended on Customerorder being
writable.

**The duplication argument, assessed honestly:**

The commit argues the new test is not redundant because `SdrWriteWithdrawalContextTest` asserts only
*list membership*, and both its lists are edited by the same hand, so a "reclassification" moving the
name between them stays green while re-opening the exploit.

- **On the write half, the argument is correct and I verified the mechanism.** Moving `"Customerorder"`
  from `WITHDRAWN` back to `MUST_STAY_WRITABLE` in that test, plus removing the class from
  `SDR_WRITE_WITHDRAWN`, requires also flipping `hasSize(48)`→`47` and `hasSize(10)`→`11` — all four
  edits in two files, all plausible-looking as a deliberate reclassification, and nothing would
  contradict them. `customerorderExposesNoSdrWriteVerb` is keyed on the runtime verb set, so it reds
  regardless of how the lists are arranged. That is real, non-duplicated value, and M1 demonstrates it.
- **On the read half, the argument is weaker than stated, and M2 proved it.** The javadoc frames
  `customerorderReadsRemainAvailable` as "the over-gating rail for this one type." But under M2,
  **three** tests went red, not one: the new test, *and*
  `SdrUncalledSurfaceNotExportedContextTest#resourcesWithLiveCallersRemainExported`
  (`Expecting empty but was: ["Customerorder (mapping exists but exported=false)"]`), *and*
  `#withdrawnDomainTypesAreNotExported`. The read half is genuinely redundant with an existing rail,
  and that rail is a named-type list too — so it carries the same "same hand" exposure the argument
  uses to justify the new test. The read half is cheap and harmless, and it does document the four
  read paths in one place, but it is not the unguarded gap the javadoc implies.

**Net: keep the test.** The write half earns its place on its own. I would soften the read half's
javadoc claim to name `SdrUncalledSurfaceNotExportedContextTest` as the pre-existing rail rather
than implying there was none.

### 4. Is "TEN" right, and does anything still say ELEVEN? **TEN is right. Three files still say eleven.**

The corrected `RestConfiguration.java` javadoc lists `advice, boxtype, client, cyclecount, location,
locationType, section, sysprop, userGroup, userRole` — exactly 10, and exactly matching the 10
entries of `MUST_STAY_WRITABLE` after the edit. The count and the enumeration agree, and the runtime
assertion `hasSize(10)` passes. **This part of the commit is correct.**

Still saying eleven: `SdrWriteWithdrawalContextTest` (M-2, seven places), `SdrUncalledSurfaceNotExportedContextTest`
(M-3, :187 and :328), and `Sbdev3017TrancheGateContextTest` (M-1, which does not say "eleven" but
asserts the underlying falsehood). `SdrFunctionGuardUnitTest.java:615` also says "UserGroup and
UserRole are two of the eleven resources whose SDR writes SBDEV-3157's withdrawal…" — stale by one,
but the sentence's actual claim about UserGroup/UserRole remains true, so I rate it below Low and
would fix it only while touching that file.

---

## Recommendation

**Do not revert.** The dead-code claim survived a hunt aimed squarely at the failure shape that
broke the previous structurally-identical claim, and mutation M1 independently confirms the exploit
was real and is now closed at guard mode OFF. Choosing write-withdrawal over an `SdrFunctionRules`
rule is right for the stated reason: a rule enforces nothing at `OFF`, which the boot log in my run
confirms is where this sits — `SdrRuleStartupCheck` logged
`"35 exported domain type(s), 5 ruled, 30 unruled … Unruled: [… Customerorder …]"`.

Before merge, fix M-1, M-2 and M-3. They are all stale prose, none breaks a test — which is exactly
why they will not be caught later. M-1 is the one that matters: it is a security note that actively
argues for undoing this commit.
