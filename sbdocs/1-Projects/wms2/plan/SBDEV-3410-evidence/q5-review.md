# SBDEV-3410 Q5 — independent review (contract-change lane)

**Reviewer lane:** q5-review · **Date:** 2026-09-23
**Subject:** withdrawal of `GET /v3/stockrecord/search/findByKeyword` from the SDR surface, plus two prose corrections
**Worktree reviewed:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410-q5` (branch `feature/SBDEV-3410-q5-withdraw-findbykeyword`, 4 files, +62/-7 vs `origin/develop`)
**No maven was run** (per instruction). Everything below is source, git and DB evidence.

## Verdict

**DO NOT MERGE AS WRITTEN.** The mechanism (per-method `exported = false`) is the right one, and the
annotation is correctly applied. But the premise "this search has no consumer" is **false on the branches
production and UAT actually run**, there is a **second live caller on every branch**, and **three of the
javadoc/comment claims this PR adds are wrong** — including the replacement for the false claim it exists
to fix.

| # | Finding | Severity | Status |
|---|---|---|---|
| F1 | `origin/main` + `origin/release` of `wms2-web-ui` still call the withdrawn route from the live report | **Critical** | VERIFIED |
| F2 | Cypress `step6` 6.4 calls it on **all** branches and asserts 200 | **High** | VERIFIED |
| F3 | "returns **405** to everyone" is wrong — method-level withdrawal is **404** | **High** | VERIFIED |
| F4 | "HYDRA IS THE ONLY v2 PRD CLIENT" is false as of 2026-09-18 | **High** | VERIFIED |
| F5 | Replacement `MUST_REMAIN_EXPORTED` justification is itself unmeasured | **Medium** | VERIFIED |
| F6 | Annotation form diverges from all four sibling precedents | **Low** | VERIFIED |

What I could **confirm** of the author's own claims, independently:

- `WMS2_SDR_READ_GUARD_MODE = OFF` on **dev** (`los_sysprop`, modified 2026-09-01) and on **hydra PRD**
  (modified 2026-09-10). So "a rule closes nothing today" is **correct**, and withdrawal rather than an
  `SdrFunctionRules` entry is the right mechanism. **Q2 confirmed.**
- `stockrecord` on dev: **9,726,847 rows** (`count(*)`, `reltuples` 9,726,795). The "9.7 M" figure is right.
- **No in-process Java caller.** No `stockrecordRepository.findByKeyword(` in `src/main` *or* `src/test`.
  Positive control: the same grep shape finds `stockrecordRepository.findByOffsetAndLimit(` at
  `ReportService.java:379`, and `.findByKeyword(` on four *other* repositories — so the pattern works and
  the zero is a true zero.
- The cited SHA `d71ac0fc` resolves: `d71ac0f Merge pull request #136 … SBDEV-3410-p6-shipper-filter-and-sku-name`.
- `findByOffsetAndLimit` (`StockrecordRepository.java:120`) and the collection/item resources are untouched.
  `StockrecordExportWithdrawalContextTest` asserts only `findByOffsetAndLimit` present /
  `findByClientOffsetAndLimit` absent, so it does **not** flip. No other rail changes verdict. **Q4 mechanically clean** (but see F5 for its *semantics*).

---

## F1 — CRITICAL · The production and UAT UIs still call this route

The whole change rests on "P6 moved the Stock Unit Record report onto `stockrecordView`". That is true
**only on `origin/develop`**, which was merged **today**.

```
wms2-web-ui  git branch -r --contains f5d7061   ->  origin/develop     (only)

origin/main:store/reports/stockUnit.js:51
  const results = await this.$axios.$get('/stockrecord/search/findByKeyword' + urlPart)
origin/release:store/reports/stockUnit.js:51
  const results = await this.$axios.$get('/stockrecord/search/findByKeyword' + urlPart)
```

Branch tips: `origin/main` `44f450c` (2026-09-21, prod promo v2.0.144), `origin/release` `b45095d`
(2026-09-20), `origin/develop` `d71ac0f` (2026-09-23).

This is **not** hypothetical ordering paranoia: `oms-laravel-api/docs/releases/owl-v2.0.145/manifest.json`
shows every repo promoted under its **own** tag and its own `branch_promoted` step. `wms2-api` and
`wms2-web-ui` can therefore reach production independently. If Q5 rides an RC to `main` before UI P6 does,
**every search in the production Stock Unit Record report returns 404** (see F3) — a silent, total outage
of that report for Hydra, with no failing test anywhere to catch it.

**Required:** make the promotion order an explicit, written gate on the ticket and in the javadoc —
*wms2-web-ui P6 must be on `release`/`main` before wms2-api Q5 is promoted past `develop`.* Merging Q5 to
`develop` alone is safe (dev UI has P6). Nothing else in this PR states that constraint; the javadoc's
"With that migration deployed" quietly assumes it is already true everywhere, and it is not.

## F2 — HIGH · A second live caller exists, on every branch, and P6 did not migrate it

```
cypress/support/helpers/wmsHelpers.js:292-300   (origin/develop, origin/release, origin/main)
  export function findStockMovementRecords(keyword, opts = {}) { …
    return cy.wms('GET', '/stockrecord/search/findByKeyword', { qs });
  }

cypress/e2e/wms/scenario2/step6-verify-final-inventory.cy.js:16,166
  it('6.4 Stock movement audit trail: RECEIVING + PUTAWAY pair for the received UL', …
    findStockMovementRecords(context.receivedUnitloadLabel, { size: 50 }).then((resp) => {
      …
      expect(resp.status, 'HTTP status').to.equal(200);
```

Failure shape, traced: `cypress/support/api/http.js` sets `failOnStatusCode: opts.failOnStatusCode === true`
— default **false** — so the request itself does not abort; the explicit `expect(resp.status).to.equal(200)`
fails instead, followed by `expect(receiving).to.not.be.null` against an empty `rows`. The spec is a
first-class npm target: `npm run smoke:s2step6`.

This is **exactly** the failure mode documented in the file this PR edits, four paragraphs above the line
it adds:

> `SdrUncalledSurfaceNotExportedContextTest.java:72-79` — *"`CustomerorderBatch` and `Pickingorder` looked
> caller-less to the path grep **and** the axios sweep, and are in fact called from Cypress via
> `cy.wms('GET', …)` … **Confirm every caller-absence verdict by a second method before acting on it.**"*

The javadoc being added says "this method had no HTTP caller"; the unqualified form is false. Either migrate
`findStockMovementRecords` to `stockrecordView` in the same change set, or state the Cypress breakage and
accept it deliberately — but it cannot be left unmentioned while the comment claims zero HTTP callers.

## F3 — HIGH · "405 to everyone" is wrong; it is 404 — and the repo already measured this

`StockrecordRepository.java` (new javadoc):
> *"A withdrawal returns **405 to everyone**, where an `SdrFunctionRules` entry would return 403 — an
> acceptance criterion written for one cannot grade the other."*

`SdrOmittedPrimitiveParamSearchContextTest.java:155-158`, same package, with a MockMvc test behind it:
> *"A **method**-level `exported = false` answers **404**: the search rel is never registered, so
> `/search/{rel}` does not resolve. That is a different shape from a *class*-level withdrawal, which
> answers 405 because the collection resource still exists and only the method is refused. **Asserting the
> wrong one of those two is the easy way to write a rail that passes against a change nobody made.**"

and `withdrawnRouteIs404()` at :169-175 asserts `status().isNotFound()` with a live positive control
(`/v3/pickingorder/search/findByStateAndSectionId` → 200) and guard mode pinned to `OFF`.

Q5 is a **method**-level withdrawal. It returns **404**. The sentence is wrong, and it is wrong in the
specific way its own next clause warns about. Fix to 404, and keep the 403 contrast (that part is right).

**Blast radius answer (Q3), corrected:** a caller gets **404**, not 405 — indistinguishable from a typo'd
URL, which makes it *harder* to diagnose in production, not easier. On the `_links` question the news is
good: because the rel is never registered, `getSearchResourceMappings` never emits it, so
`/v3/stockrecord/search` stops advertising `findByKeyword` entirely. **No stale link is left behind.** The
`search` rel on the collection resource survives, correctly, because `findByOffsetAndLimit` is still
exported.

## F4 — HIGH · "Hydra is the only v2 PRD client" is false, and the text it replaces was right

The `ClientController` correction replaces a cautious true statement with a confident false one. Measured
against `landlord-prd` myself:

```sql
SELECT t.name, c.warehouse, c.active, c.db_url, c.created FROM tenant_db_configuration c
  LEFT JOIN tenant t ON t.id=c.tenant_id;
```

| tenant | warehouse | active | db_url | created |
|---|---|---|---|---|
| hydra | nywh | true | `jdbc:postgresql://100.92.232.69:25060/wh01_hydra_v2` | 2026-06-10 |
| shipitez | c1wh | true | `jdbc:postgresql://100.92.232.69:25060/wh01_shipitez_v2` | **2026-09-18** |
| shipitez | nywh | true | `jdbc:postgresql://100.92.232.69:25060/wh02_shipitez_v2` | **2026-09-18** |

The decisive control: **`landlord-uat` uses a different host** — all four of its rows are
`jdbc:postgresql://uat.sbo.li:25060/…`, created 2026-02-08. So the three prd rows are *not* UAT entries
misread; the shipitez pair sits on the **same production host:port as Hydra**, with dedicated
`wh0{1,2}_shipitez_v2_app` DB users.

Corroborated by a second, independent artifact — `landlord-prd.tenant_auth_configuration`:

| tenant | provider | server_url | realm | created |
|---|---|---|---|---|
| hydra | keycloak | `https://kc2.sbo.li` | hydra | 2026-06-10 |
| **shipitez** | keycloak | `https://kc2.sbo.li` | **shipitez** | **2026-09-18 05:26** |

A production Keycloak realm is provisioned for shipitez. Users can authenticate against v2 prd.

The comment's stated evidence is *"its only configured MCP handles are `c1wh-shipitez-uat` and
`nywh-shipitez-uat`, which are UAT."* **The absence of an MCP handle on a workstation is not evidence about
production.** The P5 text being deleted — "hydra prd is clear, shipitez prd is inferred from UAT" — is the
accurate description, and this PR deletes it in favour of an overclaim. Note the irony the lead flagged: the
comment even says *"(A review lane said hydra was the only v2 prd database and I overrode it with this
query; the lane was right.)"* — the lane was **wrong**, and the overridden query was right.

On the general rule the paragraph adds — *"an `active` row … is ROUTING CONFIGURATION, it says a datasource
is defined, not that the client runs on that stack"* — as a standing caution that is **sound and worth
keeping**. It just cannot carry this conclusion, because here the routing row is corroborated by separate
auth provisioning on the production Keycloak. What I genuinely **could not** measure is whether shipitez prd
carries live *traffic* or user rows (no MCP handle to `wh0{1,2}_shipitez_v2`) — which is precisely the
residual uncertainty the P5 wording expressed.

**Required:** drop the "PRD COVERAGE IS COMPLETE" claim. Restore a partial-coverage caveat, updated with the
2026-09-18 provisioning, or measure the two shipitez prd databases before asserting anything.

## F5 — MEDIUM · The replacement justification for `MUST_REMAIN_EXPORTED` is unmeasured

New javadoc in `StockrecordExportWithdrawalContextTest`:
> *"What keeps `Stockrecord` in `MUST_REMAIN_EXPORTED` is the collection and item resources plus
> `findByOffsetAndLimit`."*

`Stockrecord` sits in that array under the heading **"Live SDR READ caller"**
(`SdrUncalledSurfaceNotExportedContextTest.java:163-165`). Measured:

- `findByOffsetAndLimit` has **zero HTTP callers** across `wms2-web-ui`, `wms2-mobile-ui`,
  `siteboss-frontend` and `oms-laravel-api` on both `origin/develop` and `origin/main`. It is an
  **in-process** query — `ReportService.java:379`. `StockrecordExportQueryContractUnitTest:40` says the
  *route exists*, which is not the same as a caller.
- The only `/stockrecord/**` paths any UI calls are `search/findByKeyword` (this withdrawal),
  `adjustmentAlerts` and `stockRecordDetailsById` — and the latter two are `@RestController` routes, **not**
  SDR resources.

So after Q5, `Stockrecord` has **no live SDR HTTP caller at all**, and the new sentence asserts liveness for
resources nothing was shown to call. The listing must still stay — the pin's Premise 2 requires the type to
remain exported — but write the true reason: *`ReportService` uses `findByOffsetAndLimit` in-process, and
withdrawing the type is out of scope for Q5; its last live SDR HTTP caller was the one this change removes.*
Otherwise the rail's "live caller" semantics silently stop holding for this entry, which is the same drift
that let the original defect through.

## F6 — LOW · Annotation form diverges from every sibling precedent

All four existing per-method withdrawals keep the rel alongside the flag:

```java
ReplenishorderRepository.java:501  @RestResource(path="getOpenViewByKeyword",   rel="getOpenViewByKeyword",   exported = false)
ReplenishorderRepository.java:533  @RestResource(path="getClosedViewByKeyword", rel="getClosedViewByKeyword", exported = false)
BoxtypeRepository.java:29          @RestResource(path="getDetailView",          rel="getDetailView",          exported = false)
```

Q5 replaces `path`/`rel` with a bare `@RestResource(exported = false)` (`StockrecordRepository.java:75`).
Functionally identical — SDR defaults both to the method name — so nothing breaks, and the pin matches on
the **method name**, not the rel, so it is unaffected. But it loses the at-a-glance record of which rel was
withdrawn and makes a revert a two-token edit rather than one. Match the siblings.

---

## Answers to the five questions asked

1. **Is "no caller" true?** **No.** Two counterexamples, both VERIFIED: the Cypress audit-trail helper on
   *every* branch (F2), and `store/reports/stockUnit.js` on `main` and `release` (F1). The in-process Java
   half of the claim *is* true, with a positive control. HAL `_links`-driven traversal from
   `oms-laravel-api` I could not disprove — no literal match for `stockrecord/search` or `findByKeyword` on
   its `develop` or `main`, but that is the one axis no static sweep closes, as the test file itself says.
2. **Withdrawal vs. a rule?** **Withdrawal is right. CONFIRMED independently** — guard mode is `OFF` on both
   dev and Hydra prd, so a rule would close nothing.
3. **Blast radius?** **404**, not 405 (F3). No stale `_links` entry — the rel is never registered, so it
   disappears from `/v3/stockrecord/search` cleanly.
4. **Other exposure / other rails?** Mechanically clean: collection and item resources and
   `findByOffsetAndLimit` untouched, `StockrecordExportWithdrawalContextTest` and the write/gate rails do
   not flip. But the *semantics* of the `MUST_REMAIN_EXPORTED` entry go stale (F5).
5. **The prose?** One of the two corrections is itself false (F4), the `MUST_REMAIN_EXPORTED` rewrite is
   unmeasured (F5), and the PR adds a *new* false claim about the status code (F3). The cited SHA and the
   9.7 M row count check out.

## What I would like measured (no maven run here)

- `SdrUncalledSurfaceNotExportedContextTest` **and** `StockrecordExportWithdrawalContextTest` **and**
  `SdrOmittedPrimitiveParamSearchContextTest` in one lane — the third is the one whose 404-vs-405 semantics
  this change leans on, and it shares the `ResourceMappings` context.
- A MockMvc assertion that `GET /v3/stockrecord/search/findByKeyword` is **404** while
  `…/search/findByOffsetAndLimit` still answers — the withdrawal currently has *no* status-level rail, only
  a mappings-level one, and F3 shows the status shape is exactly where this change's reasoning went wrong.
