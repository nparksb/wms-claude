# Independent security review — PR #297 (SBDEV-3183, Advice item PUT residual)

- **Repo / PR**: `SiteBossInc/wms2-api` #297 — `bugfix/SBDEV-3183-advice-item-put` → `develop`
- **Head reviewed**: `f92a0798` ("SBDEV-3183: close Advice item PUT residual")
- **Worktree**: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3183-advice-put`
- **Reviewer**: independent lane, no prior context on the change; every PR claim re-derived
- **Date**: 2026-09-03
- **Diff size**: +70 / −4, two files (`RestConfiguration.java`, `AdviceCollectionPostWithdrawalContextTest.java`)

## Verdict

**NEEDS CHANGES.**

The change the PR actually makes — withdrawing item `PUT` on `Advice` — is **correct, correctly
tested, and non-vacuous in both directions**. I verified the zero-caller claim independently across
all three consuming repos at `origin/develop`, and mutation-checked the new assertions both ways.
Nothing in the diff is unsafe to ship.

The problem is the PR's **"bonus finding"**: it asserts that item `DELETE` on `Advice` is "genuinely
live" and therefore "stays open by decision, not by omission." **That claim is false.** The button
the claim rests on is commented out in `wms2-web-ui` and has been since the repo's initial commit.
`DELETE /v3/advice/{id}` has zero live callers in either UI or OMS — the same status as the PUT this
PR closes, and the same status as the two dead verbs on `Cyclecount`, `Advice`'s structural twin,
which this very sweep already closed.

That makes the PR **strictly worse than the state it replaced** on that axis: it overwrites an
honest "pre-existing, unaudited residual" flag with a confident, wrong "audited and live" one, and
then pins the wrong rationale into a permanent test assertion message. The next person to read
either will correctly conclude the question is settled and stop looking. The residual stays open
with its warning label removed.

Fix H-1 and L-1 below and this is a ship. H-1 is a documentation/claim correction plus a scope
decision for Nam; it does not require reworking the PUT closure.

## Findings

### H-1 (High) — "item DELETE is genuinely live" is false; the residual loses its warning label

**Claim under review**, `src/main/java/net/aim_ai/wms/RestConfiguration.java:515-518`:

> `DELETE /v3/advice/{id}` was exposed too and flagged here, at the time, as an unaudited residual —
> it has since been checked (`configureAdviceItemVerbWriteExposure`) and is genuinely live
> (`deleteOpenInboundNotices`), so it stays open by decision, not by omission.

and `RestConfiguration.java:553-558`:

> DELETE — checked here for the first time rather than assumed […] — is `deleteOpenInboundNotices`
> (`store/receiving/inboundNotices.js:187`), dispatched from `deleteOpenNotices.vue`'s "Delete
> Inbound Notice" button. Both stay open; only PUT closes.

**The store action and the popup are real. The thing that opens the popup is not.**

Traced end-to-end on `wms2-web-ui` `origin/develop` (`ad5159c`):

| Hop | Location | Status |
|---|---|---|
| 4. axios call | `store/receiving/inboundNotices.js:187` — `$delete('/advice/${…id}')` | exists |
| 3. store action | `store/receiving/inboundNotices.js:182` `deleteOpenInboundNotices` | exists |
| 2. dispatcher | `components/receiving/open/popups/deleteOpenNotices.vue:55` — `$store.dispatch('receiving/inboundNotices/deleteOpenInboundNotices', …)`, from the "Delete Inbound Notice" button at `:23` | exists |
| 1. popup opener | `components/receiving/open/openNotices.vue:322` `deleteOpenInboundNotices(notices)` — the only writer of `showDeleteNotice = true` (`:330`) | **no live caller** |

Hop 1 has exactly two call sites, and **both are inside HTML comments**:

- `components/receiving/open/openNotices.vue:31-33` — bulk "Delete Inbound Notice" button, wrapped in `<!-- … -->`
- `components/receiving/open/openNotices.vue:99-101` — per-row "Delete Notice" menu item, wrapped in `<!-- … -->`, immediately under the source comment `<!-- the following will be activated in later version not in v1.5 -->`

Complete enumeration of every mutation of the gating flag in `openNotices.vue` (`git grep` on
`origin/develop`, nothing omitted):

```
219:  showDeleteNotice: false,                          # init
330:  this.showDeleteNotice = true                      # inside the dead method at :322
333:  this.showDeleteNotice = item.showDeleteOpenNotice # child's cancel/complete emit — always false
```

So `showDeleteNotice` can never become `true`; the `<delete-inbound-open-notices>` dialog rendered
at `:118-122` never opens; its button is unreachable; the DELETE never fires. `deleteOpenNotices.vue`
is imported only by `openNotices.vue` (`:137`, registered `:145`) — no second host. The one other
component that looked like a candidate, `openNoticeDescription.vue:93-98`, passes its notice to
`close-open-notice-pop`, not the delete popup.

**Never live, not recently dead.** `git log -S'Delete Notice' -- components/receiving/open/openNotices.vue`
returns a single commit: `3462148 initial check in the code`. The button has been commented out for
the file's entire history.

**Corroborating negatives** (all at `origin/develop`, positive-controlled):

- `wms2-web-ui`: every write-verb axios call enumerated; the only two naming `advice` are the
  `$delete` at `inboundNotices.js:187` and the `$patch` at `:380`. No generic HAL/`_links.self`
  write helper exists that could produce a computed item URL (`git grep '_links\(\.self\|\[\)'`
  over `store/`, `components/`, `plugins/`, `utils/`, `mixins/` → zero hits).
- `wms2-mobile-ui` (`e8a2e97`): **zero** occurrences of `advice`, any case, in any `.js`/`.vue`.
  Its single `$put` is `/replenish/order/{id}` (`store/replenish.js:191`).
- `oms-laravel-api` (`8ccad384`): zero occurrences of `v3/advice` anywhere in the repo. Confirms
  the PR's other claim (see "Claims verified" below).

**Why this is High, not Low.** Three compounding effects:

1. **The claim is load-bearing and now wrong in the confident direction.** The prior comment said
   "pre-existing, unaudited residual" — honest, and it told the next reader to go check. The
   replacement says "checked […] genuinely live […] stays open by decision," which instructs the
   next reader *not* to check. A wrong audit result is worse than an admitted absence of one.
2. **It is pinned into a test rationale**, `src/test/java/net/aim_ai/wms/security/AdviceCollectionPostWithdrawalContextTest.java:82-87` — the `.as()` message on `itemDeleteRemainsExposed` reads
   "dispatched from `deleteOpenNotices.vue`'s 'Delete Inbound Notice' button — withdrawing the whole
   item route would break it." Nothing would break. That message is now the durable artifact future
   reviewers will trust, and the assertion actively **defends** the open verb.
3. **This PR series' own precedent says close it.** From
   `RestConfiguration.java:673-681` (the sweep landed in #295, two entries above `Advice`'s):
   - *`Location`* — item PUT withdrawn precisely because "`updateStorageLocation`, PUT's apparent
     caller, **is undispatched dead code** (independent review pass 2, M-3) — there was never a live
     PUT caller to begin with, this closes an already-dead route." Identical shape to this finding.
   - *`Cyclecount`* — item **PUT and DELETE both withdrawn**, "No PUT or DELETE caller anywhere."
     `Cyclecount` is `Advice`'s structural twin: same `MUST_STAY_WRITABLE` membership, same surviving
     verb (item PATCH via a `saveComment` action taking `{id, comment}`), same `state`
     `@ReadOnlyProperty` story (`SdrMustStayWritableStateNotPatchableContextTest:71` names the two
     together). `REQUIRED_ITEM_VERBS` at
     `MustStayWritableCollectionPostWithdrawalContextTest:87` lists `Cyclecount` → `{PATCH}` only.

   Under the sweep's stated rule — close the verbs "measured to have no caller AT ALL" — `Advice`
   item DELETE qualifies, and leaving it open makes `Advice` the sole inconsistent member of the set.

**Exposure.** `DELETE /v3/advice/{id}` is the bare SDR item route: reachable by any authenticated
zero-function `wms_user`, since SDR sits outside the `@PreAuthorize` function-gating layer (the
startup log in this worktree's own test run confirms it: *"3 annotation-marked handlers open by
design (excludes Spring Data REST — see SBDEV-3017)"*, and `Advice` is listed among the 30 *unruled*
SDR domain types). Destructive verb, no gate, no caller. Same threat model as every other verb this
ticket has withdrawn.

**Recommended remediation** (author's/Nam's call on 2 vs 3, but 1 is mandatory either way):

1. **Correct the claim.** `RestConfiguration.java:515-518` and `:553-558` must not say DELETE is
   live. State what was measured: the only openers are commented out at `openNotices.vue:31` and
   `:100`, since initial check-in — so DELETE has no live caller. Same for the `.as()` message on
   `itemDeleteRemainsExposed`.
2. **Preferred — close DELETE too**, matching `Location`'s dead-PUT precedent and `Cyclecount`'s
   verb set: add `HttpMethod.DELETE` to the `disable(...)` at `RestConfiguration.java:563`, flip
   `itemDeleteRemainsExposed` into `itemDeleteIsWithdrawn`, and record in the javadoc that a future
   activation of the commented-out button must re-open the verb in the same commit.
3. **Or leave DELETE open deliberately** — defensible if Nam wants the not-yet-shipped delete
   feature to work the moment the button is uncommented — but then the javadoc and the `.as()`
   message must say *that*: "no live caller today; held open for the deferred v1.5+ delete feature,"
   not "genuinely live."

Whichever of 2/3 is chosen, this is a sub-T3 finding on an open ticket, so per the ticket policy it
belongs on SBDEV-3183 itself rather than a new ticket.

### L-1 (Low) — the PR closes a residual whose "still open" note it leaves standing

`src/test/java/net/aim_ai/wms/security/MustStayWritableCollectionPostWithdrawalContextTest.java:79-83`
still reads:

> Measured while fixing this finding: `Advice` item PUT has no caller in either UI or OMS either, the
> same shape as the six types this method DOES close — a real, additional residual, **left out of
> this PR's scope** rather than folded in silently. Do not read
> `AdviceCollectionPostWithdrawalContextTest`'s green as proof `Advice`'s item verbs are fully
> audited.

PR #297 *is* the follow-up that closes it, so both sentences are now stale: the residual is closed,
and `AdviceCollectionPostWithdrawalContextTest`'s green now does pin item PUT. This is the same
defect class the PR gets credit for fixing in `RestConfiguration.java` — and the author demonstrably
read this file, since the new javadoc at `RestConfiguration.java:536-540` cites it by name as where
the finding came from. One of the two stale halves was updated; this one was not.

Fix: update `:79-83` to say the PUT residual was closed by
`RestConfiguration#configureAdviceItemVerbWriteExposure` and pinned by
`AdviceCollectionPostWithdrawalContextTest#itemPutIsWithdrawn`, keeping the "this sweep did not
audit Advice's item verbs" caveat narrowed to whatever genuinely remains after H-1 is resolved.

### L-2 (Low, informational — no action needed) — citation line drift

`RestConfiguration.java:552` cites `store/receiving/inboundNotices.js:378` for `saveComment`. On
`origin/develop` the `async saveComment` declaration is at `:378` and its `$patch` at `:380`, so the
citation resolves correctly. Flagged only because two other line citations in the same javadoc were
checked against `origin/develop` rather than a local checkout and all held — no drift found. No
change requested.

## Claims verified — all of these hold

### 1. Item PUT on `Advice` has zero legitimate callers — **CONFIRMED**

Measured at `origin/develop` of all three repos (freshly fetched; local checkouts lagged, e.g.
`wms2-web-ui` local `3117aca` vs `origin/develop` `ad5159c`), with a positive control on each grep
so a broken instrument could not read as a true zero:

- **`wms2-web-ui`** — full enumeration of `$put`/`$patch`/`$delete`, `$axios.put`-style non-`$`
  variants, and `method: 'PUT'` config-object forms across `store/`, `components/`, `pages/`,
  `plugins/`, `mixins/`, `utils/`. Zero `advice` PUTs. All 22 write-verb URLs are literal or
  literal-prefixed template strings (`'/userGroup' + urlPart`, `` `/sysprop/${id}` ``) — no
  fully-computed resource path anywhere, and no generic self-href writer, so the "dynamic URL"
  escape hatch the review brief warned about does not exist in this codebase.
- **`wms2-mobile-ui`** — zero `advice` mentions of any kind.
- **`oms-laravel-api`** — zero `v3/advice` occurrences repo-wide.

### 2. `WmsApiService::createReturnAdvice` targets `/rest/advice/create`, not `/v3/advice/{id}` — **CONFIRMED by reading the method**

`app/Services/WmsApiService.php:2137-2158` builds the URL from constants, not from any `advice_*`
config key that could point at `/v3`:

```php
$base = $this->getWmsBaseUrl($facility);
$host = $this->stripV3Suffix($base);          // strips a trailing /v3 — :934-937
$url  = $host . '/rest/advice/create';        // :2147, hard-coded literal
$response = $this->makeWmsRequest($url, $advice, 'PUT', $facility, true);   // :2158
```

`stripV3Suffix` (`:934-937`, `preg_replace('#/v3/?$#i', …)`) actively removes the `/v3` segment, so
this PUT cannot land on the authenticated `/v3` surface even for a facility whose `wms_url_lut`
base carries the suffix. The sibling `createAdvice` (`:2062`) resolves via
`getWmsEndpoint('advice_create')` → `config/wms.php:37` `'rest/advice/create'`, then
`resolveWmsUrl` (`:954-961`), which routes any `rest/`-prefixed path to the stripped host for the
same reason. No `id` appears in either path. The PR's "red herring" framing is accurate, and the
`config/wms.php:37` citation is correct.

### 3. Item PATCH stays open and is genuinely live — **CONFIRMED**

The diff touches only `withItemExposure(… disable(HttpMethod.PUT))` at
`RestConfiguration.java:560-564`. PATCH and DELETE are not named. Read the actual diff, not the
test names, per the brief — and separately proved by mutation (see below), where PATCH survived the
PUT-only disable and died the moment it was added to the list.

PATCH's caller is real, unlike DELETE's: `store/receiving/inboundNotices.js:378` `saveComment` is
dispatched from `components/receiving/closed/closedNoticeDescription.vue:242`
(`$store.dispatch('receiving/inboundNotices/saveComment', { id, comment })`) — a live component
method, not commented out. This asymmetry is itself evidence my method is sound: the same trace
applied to PATCH and DELETE returns live for one and dead for the other.

### 4. The new tests are non-vacuous in **both** directions — **CONFIRMED by mutation**

Both new tests query `ResourceMappings.getMetadataFor(Advice.class).getSupportedHttpMethods().getMethodsFor(ResourceType.ITEM)`
— the right instrument (the resolved SDR metadata, not a config-object echo).

Baseline, unmutated: `AdviceCollectionPostWithdrawalContextTest` → **5 / 0 / 0 / 0**.

| Mutation | Expected | Observed |
|---|---|---|
| Comment out `configureAdviceItemVerbWriteExposure(config)` at `RestConfiguration.java:736` | only the PUT assertion reds | **1 failure: `itemPutIsWithdrawn`**, message names `PUT`; pre-fix ITEM set printed as `[HEAD, DELETE, GET, OPTIONS, PUT, PATCH]`. Other 4 green — so the collection-POST config from #290 and this item config apply independently. |
| Widen `:563` to `disable(PUT, PATCH, DELETE)` | both entitled controls red | **2 failures: `itemPatchRemainsExposed` and `itemDeleteRemainsExposed`**, ITEM set collapsed to `[HEAD, GET, OPTIONS]`. Over-closure is caught. |

`RestConfiguration.java` restored byte-identical afterwards (md5 `2488f59e599b60ce0b12151d4ee76439`
before and after); `git status --short` clean. **Worktree left clean.**

Note the second row is what makes H-1 a *claim* defect rather than a *test* defect:
`itemDeleteRemainsExposed` works correctly and would catch an accidental over-closure. Its
assertion is sound; only its stated justification is false. If H-1 remediation option 2 is taken,
the test flips polarity rather than being deleted.

### 5. Suite claim `6266/0/0/67` — **CONFIRMED exactly, independently re-run**

`mvn -o clean test` in this worktree at `f92a0798`:

```
[WARNING] Tests run: 6266, Failures: 0, Errors: 0, Skipped: 67
[INFO] BUILD SUCCESS          (exit 0)
```

Matches the PR's claimed `6266/0/0/67` digit for digit — including the skip count, which is the
number most likely to drift silently. `clean` was used deliberately, since `mvn test` without it
re-runs deleted test classes out of a stale `target/test-classes`. No surefire-lane failures or
errors, so there is nothing to weigh against the SBDEV-2217 known-broken failsafe/`*IT` lane (not
exercised by `mvn test`, correctly out of scope).

### 6. Things the PR's framing might have missed — checked, nothing further found

- **Association resources.** `Advice` declares **no** `@OneToMany` / `@ManyToMany` / `@ManyToOne` /
  `@OneToOne` (`src/main/java/net/aim_ai/wms/model/Advice.java` — its only relevant annotation is
  the SBDEV-3215 `@ReadOnlyProperty` on `state` at `:31`). So there is no
  `/v3/advice/{id}/<assoc>` sub-resource whose PUT/PATCH/DELETE per-verb item exposure would fail to
  cover. `Adviceposition` is a separate exported domain type with its own mappings, out of scope
  here and already handled by `SdrUncalledSurfaceNotExportedContextTest:137`.
- **Interaction with #290 (`Advice.state` `@ReadOnlyProperty`).** None, and no vacuity introduced.
  `AdviceStateReadOnlyContextTest` exercises the **merge/PATCH** path only (`:58` — "read-only over
  SDR PATCH"; AC-1 at `:65`, entitled control AC-2 at `:78`), so withdrawing PUT cannot turn any of
  its assertions green-for-the-wrong-reason. Withdrawing a verb only removes surface; it cannot
  re-open the collection-POST `em.merge` bypass, which is closed separately by
  `configureAdviceCollectionCreateWriteExposure` and still pinned green by
  `collectionPostIsWithdrawn` under both my mutations.
- **Interaction with #295 (the `MUST_STAY_WRITABLE` item-verb sweep).** No conflicting assertion.
  `SdrWriteWithdrawalContextTest#resourcesWithLiveWritersRemainWritable` (`:290-305`) only asserts
  each listed type retains a *non-empty* write-verb set, which `Advice` still does via PATCH and
  DELETE. `MustStayWritableCollectionPostWithdrawalContextTest` keeps `Advice` in
  `COVERED_ELSEWHERE` (`:60`) and so never reaches it. The only #295 artifact needing an edit is
  the stale javadoc in L-1.
- **MVC route collision.** `AdviceController` (`@RequestMapping("/v3/advice")`) declares no
  `@PutMapping` at all — its seven write handlers are all `@PostMapping` on named subpaths
  (`/create`, `/update`, `/setPurchaseOrderNumber`, `/closeInboundBol`,
  `/fixHubAndSpokePalletIssues`, `/exportInboundNotice`). Nothing MVC-side is shadowed by the SDR
  item-PUT withdrawal.
- **Other stale "unaudited DELETE" comments.** Grepped `src/main` + `src/test` for
  `unaudited` / `pre-existing.*residual` / `out of this fix's scope`. The only `Advice`-DELETE
  occurrence is the one this PR rewrites (`RestConfiguration.java:516`); the other five hits concern
  `SystemPropertyController`, `PutawayConfigRepositoryEventHandler` and two ArchUnit tests, all
  unrelated. **The PR's comment-correction scope was complete on that axis** — the gap is L-1, in a
  different file and phrased differently ("left out of this PR's scope" rather than "unaudited"),
  which is exactly why a grep for the old wording missed it.

## Verification performed

| Instrument | Result |
|---|---|
| PR metadata + diff (`gh pr view/diff 297`) | 2 files, +70/−4; read in full |
| Cross-repo caller audit at `origin/develop` ×3 repos, positive-controlled | PUT: zero callers. DELETE: zero *live* callers (H-1). PATCH: one live caller. |
| OMS `createReturnAdvice` / `createAdvice` read by hand | both resolve to `<host>/rest/advice/create`; `/v3` actively stripped |
| Dispatch-chain trace, component → dispatch → store → axios, for DELETE and PATCH | DELETE dead at hop 1; PATCH live end-to-end |
| `git log -S` on the delete button | commented out since initial commit |
| `Advice` entity association scan | none |
| `AdviceController` verb scan | no PUT mappings |
| Target class baseline | 5 / 0 / 0 / 0 |
| Mutation — remove exposure call | 1 red, correct test, correct verb named |
| Mutation — widen to PUT+PATCH+DELETE | 2 reds, both entitled controls |
| Restore check | md5 identical, `git status` clean |
| Full `mvn -o clean test` | **6266 / 0 / 0 / 67, BUILD SUCCESS** — matches the PR claim exactly |

**Worktree state on exit: clean, no residual mutation** (`git status --short` empty;
`RestConfiguration.java` md5 identical to pre-mutation).

Sole Maven process in this worktree throughout — concurrent builds in one worktree produce
spurious mass reds, so the green above is trustworthy rather than a racing artifact.
