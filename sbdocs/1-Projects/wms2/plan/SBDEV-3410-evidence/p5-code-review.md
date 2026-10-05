# SBDEV-3410 P5 — code review lane

**Reviewer:** p5-code-review subagent
**Date:** 2026-09-22
**Worktree reviewed:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410-p5`
**Branch:** `feature/SBDEV-3410-p5-allclients-stock-unit-record-function`, 1 commit ahead of `origin/develop` (`1aa726d5 wip: p5 for suite run`)
**Diff:** 2 files, +65/-11 — `ClientController.java`, `Sbdev3017TrancheGateContextTest.java`
**Maven:** NOT run (instructed). Every Java claim below is from reading source, not from a build.
**DB:** six tenant databases queried read-only, each with positive controls. Detailed below.

---

## Verdict

**The code change is correct and I found no Critical or High defect.** Both sides of the pin move
together, the three constants exist and are already granted, the widening is safe, and the
derivation that produced the gap set survives every attempt I made to break it.

**Eight findings, all in the PROSE and one pre-existing method-body issue.** The most important is
**F1 (Medium): the invariant as stated is false, and I have a verified counterexample.** F2
(Medium) is a second over-claim in the same comment block — the one Nam asked me to hunt for.

| # | Sev | Where | One line |
|---|---|---|---|
| F1 | **Medium** | `ClientController.java` "THE RULE" block | Rule is stated on appearance, not mechanism — verified counterexample would cause a future *over*-widening |
| F2 | **Medium** | `ClientController.java`, last clause of the P5 paragraph | "nobody gains data they could not already see" asserts more than was measured, and is false structurally |
| F3 | Low | `ClientController.java` derivation recipe | Greps the store-action axis not the route axis; `-l` can't yield "26 sites"; omits `wms2-mobile-ui` |
| F4 | Low | `ClientController.java` Q6 caveat | "prd tenants are unmeasured" is stale — I measured 5 more tenants incl. the only v2 PRD DB |
| F5 | Low | `ClientController.java` | "every dispatcher is a shipper-**filter** dropdown" — one of the 15 is a create-form selector |
| F6 | Low | `ClientController.java:255-259` (pre-existing) | `allClients` returns the full `Client` entity, unbounded; `PageRequest.of(0,0)` throws when count = 0 |
| F7 | Low | `ClientController.java` | The "26 dispatch sites" figure is load-bearing for nothing and is the fastest-rotting number in the block |
| F8 | Low (info) | — | Watch item: `containerRecord.vue` is the most likely fifteenth screen. Not a gap today (verified) |

---

## What I VERIFIED

### The change itself

1. **Both sides carry the identical 14-element set, no duplicates.** Extracted the tokens from
   `ClientController.java:239-253` and from the pin row at `Sbdev3017TrancheGateContextTest.java:687-693`
   and diffed them: 14 each, 14 distinct each, **sets identical**. (Duplicates matter here: both
   `row()` and `resolve()` build a `Set.of(...)`, which *throws* `IllegalArgumentException` on a
   duplicate rather than failing the assertion — see the note at the end.)

2. **All three constants exist**, `WmsConstants.java:379-381`.

3. **The "a new `FunctionEnum` constant needs three things" trap does not apply** — these are not new
   constants. All three already carry an `initDB` super-admin grant line
   (`UtilRestController.java:363, 396, 398`) and all three already appear in the seeded-grants list at
   `UtilRestController.java:481-483`. Nothing else was owed.

4. **Bidirectional equality — the claim in the test comment is TRUE.**
   `row()` (line 66-68): `EXPECTED.put(class + " " + path, String.join("+", new TreeSet<>(Set.of(functions))))`.
   `resolve()` (line 858-866): `String.join("+", new TreeSet<>(Set.of(r.value())))`.
   Compared with `.equals()` at line 968. Exact set equality in both directions, order-insensitive.
   Changing either side alone reddens the test. Nam's correction to the plan's §3.8 bullet 2 is right.

5. **`hasSize(227)` needs no change.** `row()` keys on `class + " " + path`; widening an existing
   row's varargs mutates a value, never adds a key. The size pin is a separate `@Test`
   (line 1086-1090) precisely so it is reached when the drift test fails.

6. **"exactly 1 of 227 routes wrong" is structurally sound.** Nothing in `src/` extends
   `ClientController` (grep for `extends ClientController`: no hits), so `allClients` registers under
   exactly one path and only its one key can change. Contrast `ReportController`/`DashboardController`,
   which the file documents as a dual registration.

7. **The ungated-row requirement is untouched.** P5 widens an already-gated row; it consumes no
   UNGATED proxy. The §0.C OMS carve-out rows and the `ClubLine`/`Transfers`/`AdminAction`
   class-level tripwire `@Test`s are all unaffected.

8. **Sibling sweep confirmed.** `allClients` appears in `src/test` in exactly two files:
   this pin, and `ClientControllerLegacyIntegrationTest.java:195-201`, which grants **only**
   `WEB_UI_VIEW_CLIENT` through the real user→group→role→function chain and asserts `200`. Widening an
   ANY-of gate cannot turn a 200 into anything else, so that test is genuinely unaffected. There is no
   negative (403) test on `allClients` anywhere that could flip.

9. **Encoding is safe.** The block adds `──`, `⚠`, `—`, `→`. `pom.xml` inherits
   `spring-boot-starter-parent` 3.5.9, which sets `project.build.sourceEncoding=UTF-8`, and the file
   already carries 16 non-ASCII characters on `origin/develop`. No trailing whitespace introduced.

### The dispatcher re-derivation — reproduced exactly

`wms2-web-ui` @ `origin/develop` = `9254bf506b9cc6e7d1c6eb799e30783cbd6dba9d`, as the comment states.

- `git grep -l "admin/client/getClients" -- '*.vue' '*.js'` → **15 files** ✓
- `git grep -c` on the same → per-file counts summing to **26 sites** ✓
- **seven** reports (flowbin, inventory, lock, outboundParcel, parcelPicking, receiving, skuLocation) ✓
- The old 13-file enumeration was exactly the new 15 **minus** `handlingUnits/containerTable.vue` and
  `handlingUnits/stockUnitsTable.vue` ✓ — so the claim "the two screens it omitted were exactly the
  Handling Units pair" is TRUE.

### I tried four ways to break the derivation. It survived all four.

| Attempt | Result |
|---|---|
| **Route axis ≠ store-action axis** — someone calling `/client/allClients` outside `store/admin/client.js` | Swept `allClients` across the whole web-ui repo: the only non-test source hit is `store/admin/client.js:24` (`const urlPart = '/allClients'`). The two axes coincide **today**. (But the recipe encodes the weaker one — F3.) |
| **`wms2-mobile-ui`** — a mobile screen calling the same route | `origin/develop` `5b1d3363`: **zero** hits for `allClients` and zero for `v3/client`. Its `replenish/getClients` hits `/replenish/clientList`, a different route. No mobile exposure. |
| **A dispatcher component mounted on a second page with a different `fn`** | Enumerated every reference to all 15 components across `pages/`, `components/`, `layouts/`. Every extra hit is a **comment mentioning the file by name** (`recoverStuckPallets.vue:3`, `effectivePutawayRow.vue:11`, `deleteConfirmation.vue:102`, `adjustAmount.vue:62,72`, `transferToDamaged.vue:63`, `fullDetails.vue:71`) — no second mount site. The 15 → `fn` mapping is one-to-one. `EXTRA_ROUTES` confirms the cycle-count detail pages are `WEB_UI_VIEW_CYCLECOUNT` and the receiving detail pages `WEB_UI_VIEW_INBOUND_BOL`. |
| **A sibling report that will need it next** | `/reports/container-record` (`fn: WEB_UI_VIEW_UNIT_LOAD_RECORD`) renders `clientName`/`clientNumber` columns but `containerRecord.vue` contains **no** `clients` reference and no `getClients` dispatch. Not a gap. Logged as F8. |

**Conclusion: there is no fourth screen. The gap set {STOCK_UNIT, CONTAINER} + this ticket's
{STOCK_UNIT_RECORD} is complete as of `9254bf5`.**

### Blast radius — independently reproduced, then extended past Q6

I re-ran the traversal `mywms_user → mywms_group_mywms_user → mywms_group_mywms_role →
mywms_role_mywms_function → mywms_function` myself, with **both** controls on every database:
a bogus *allow-list* (must return the full holder count) and a bogus *probe function* (must return 0).

| Database | env | RECORD | STOCK_UNIT | CONTAINER | blocked today | controls |
|---|---|---|---|---|---|---|
| `dev_wh01_om1` | dev | 45 | 44 | 45 | **0 / 0 / 0** | both green |
| `wh01_hydra_v2` (prd) | **PRD** | 7 | 7 | 7 | **0 / 0 / 0** | both green |
| `wh01_hydra_v2` (uat host) | UAT | 16 | 16 | 16 | **0 / 0 / 0** | both green |
| `wh01_om1_v2` (WineCo) | UAT | 42 | 41 | 42 | **0 / 0 / 0** | both green |
| `wh01_shipitez_v2` | UAT | 26 | 26 | 26 | **0 / 0 / 0** | both green |
| `wh02_shipitez_v2` | UAT | 9 | 9 | 9 | **0 / 0 / 0** | both green |

**Nam's dev figures (45 / 44 / 45, 0 / 0 / 0) reproduce exactly.** And **Q6 is now discharged on the
only v2 PRD database I can reach** plus four UAT tenants: nobody is unblocked anywhere. This is the
strongest safety evidence available and it should replace the caveat currently in the comment (F4).

Also verified on `dev_wh01_om1`: `WEB_UI_VIEW_CLIENT` is held by exactly `ROLE000056` (0 users),
`ROLE000101` (0 users) and `super-admin` (37 users) — the comment's claim is accurate. The roles
that gain a path through the three new disjuncts are `CS-REP` (4), `inventory-manager` (12),
`ROLE000072` (3) and `super-admin` (37); every one of them already holds at least one of the eleven.

### Is the ANY-of the right shape?

**Yes, for this ticket.** `allClients` is a shared lookup feeding a dropdown on N unrelated screens.
The alternatives are worse: a dedicated function would have to be granted to every role that holds
any of the fourteen (a bigger, hand-maintained mapping with the same rot problem, plus a migration);
gating on `WEB_UI_VIEW_CLIENT` alone is the H1 defect this list was created to fix. ANY-of, derived
from the callers, is the right shape. The real weakness is not the shape — it is that `allClients`
returns far more than the dropdown needs (F6).

---

## Findings

### F1 — **Medium** — the stated invariant is false; it is on the wrong axis

**File:** `src/main/java/net/aim_ai/wms/controller/ClientController.java`, the `── THE RULE, not the list ──`
block (≈ lines 208-213), and its restatement in `Sbdev3017TrancheGateContextTest.java` (≈ lines 665-667).

**Text:** *"Every screen that renders a shipper dropdown contributes its own view function to this
ANY-of set."*

**Verified counterexample.** `v2/wms2-web-ui @ origin/develop`
`components/homepage/pickPackMonitor/sortingFiltering/shipperBrandFiltering.vue:5-8` renders a
**Shipper / Brand `<v-select>`** on the Dashboard (`appMenuList.js:39`, `fn: 'WEB_UI_VIEW_ORDER_MONITOR'`).
Its items come from `shipperBrandList` (line 33), built from rows the monitor already loaded — it
does **not** dispatch `admin/client/getClients` and does **not** call `allClients`.
`WEB_UI_VIEW_ORDER_MONITOR` is correctly **absent** from the fourteen.

**Why it matters.** The rule is written to direct the next maintainer's edit to an **authorization
gate**. Applied literally it instructs them to add `WEB_UI_VIEW_ORDER_MONITOR` — widening an authz
gate for a screen that never calls the route. A rule that produces a wrong widening is worse than the
count it replaced, because the count at least failed loudly. This is the mechanism-vs-appearance trap:
the guard must fence the mechanism you aimed at.

**Fix (both files, same wording):**

> Every screen that **calls `GET /v3/client/allClients`** contributes its own view function to this
> ANY-of set. Today every such call goes through `store/admin/client.js#getClients`, which is the
> only place in `wms2-web-ui` that names the route — so the dispatcher grep below is a valid proxy,
> but the route is the rule. A shipper dropdown populated from already-loaded rows (e.g. the
> Dashboard's Shipper/Brand `<v-select>`) is **not** a caller and must **not** be added here.

---

### F2 — **Medium** — the closing clause asserts more than was measured

**File:** `ClientController.java`, end of the `SBDEV-3410 P5` paragraph (≈ line 245).

**Text:** *"So this is strictly widening and latent — nobody is unblocked today, and **nobody gains
data they could not already see on the screen that carries the dropdown**."*

The first two clauses are correct and measured. The third is neither.

- `allClients` returns `Page<Client>` — the **whole entity**, not an id/name projection:
  `id, created, modified, version` (`AbstractBaseEntity`) plus `additionalcontent, entityLock, name,
  clNr, sectionId, enablereceiving, printerreceivingId, defaultputawaylocationId` (`Client.java:10-33`).
  There is no `@JsonIgnore` on any of them.
- Several of those are **Admin > Shippers** configuration — `printerreceivingId`,
  `defaultputawaylocationId`, `enablereceiving`, `sectionId`, `additionalcontent` — a screen gated
  `WEB_UI_VIEW_CLIENT`, which on dev is held only by `super-admin` and two zero-user roles.
- It returns **every** client, including clients with no rows on the caller's grid.

So a holder of only `WEB_UI_VIEW_CONTAINER` would gain the full shipper roster plus their receiving
configuration — data the Handling Units grid does not show. The clause is **vacuously** true today
only because the measurement found 0 newly-admitted users; it is phrased as a **structural** property,
and it is the sentence a future reader will lean on when adding a fifteenth function.

**Fix.** Delete the clause. Replace with what is actually true and measured:

> …so this is strictly widening: nobody is newly admitted on any tenant measured below. ⚠ Note what
> the route returns before widening it again — `allClients` is **not** an id/name projection. It
> serialises the whole `Client` entity (incl. `clNr`, `sectionId`, `enablereceiving`,
> `printerreceivingId`, `defaultputawaylocationId`, `additionalcontent`) for **every** client. Each
> function added here hands that to its holders.

---

### F3 — **Low** — the re-derivation recipe encodes the weaker axis and omits a repo

**File:** `ClientController.java` ≈ lines 214-215:
`git grep -l "admin/client/getClients" origin/develop -- '*.vue' '*.js'   (in wms2-web-ui)`

Three defects, all verified:

**(a) wrong axis.** It greps the Vuex action path, not the route. A new store module calling
`/client/allClients` directly is invisible to it. Today the axes coincide — `allClients` appears in
exactly one non-test source file (`store/admin/client.js:24`) — so this is latent, not live. But F1's
fix restates the rule on the route, and the recipe must match it.

**(b) `-l` cannot produce the number on the next line.** `-l` lists files; the comment then states
"15 files, **26 dispatch sites**". Reproducing 26 needs `git grep -c`.

**(c) only one repo is named.** I checked `wms2-mobile-ui` @ `origin/develop 5b1d3363`: **zero**
hits for `allClients`, zero for `v3/client`; its `replenish/getClients` hits `/replenish/clientList`.
Recording that saves the next reader the derivation and stops them assuming the opposite.

**Fix:**
```
//     (wms2-web-ui)    git grep -n  "allClients"              origin/develop -- '*.vue' '*.js'   # the ROUTE — authoritative
//     (wms2-web-ui)    git grep -c  "admin/client/getClients" origin/develop -- '*.vue' '*.js'   # the dispatchers + site counts
//     (wms2-mobile-ui) git grep -n  "allClients"              origin/develop                     # 0 hits, measured 2026-09-22 @ 5b1d3363
```

---

### F4 — **Low** — the Q6 caveat is stale inside its own commit

**File:** `ClientController.java`, last line of the P5 paragraph:
*"⚠ One tenant at one instant. The prd tenants are unmeasured (SBDEV-3410 Q6)."*

I measured five more tenants today, including the only v2 PRD database, all with both positive
controls green — see the table above. All show 0 blocked.

**Fix.** Replace with the table (or a one-line summary: *"Measured 2026-09-22 on six databases —
dev_wh01_om1, wh01_hydra_v2 (prd and uat), wh01_om1_v2, wh01_shipitez_v2, wh02_shipitez_v2 — with a
bogus-allow-list and a bogus-function control on each: 0 users blocked on every one."*) and mark Q6
discharged in the plan. **Genuinely still unmeasured:** any prd tenant with no connection from this
session — `mcp__wms2-hydra__` resolves to `wh01_hydra_v2` only, so if a separate Hydra `nywh` prd
database exists it was not covered. Say that rather than "the prd tenants are unmeasured".

---

### F5 — **Low** — "shipper-**filter** dropdown" mis-describes one of the fifteen

**File:** `ClientController.java` ≈ line 207 and the test's line ≈ 664.

`components/receiving/open/create/createPurchaseOrder.vue` is a **create form**; its shipper widget
selects the new PO's shipper, it does not filter a grid. The comment says *"every ... dispatcher is a
shipper-filter dropdown on some OTHER screen"*. Small, but the entire point of this edit is that
imprecise prose rots into wrong prose.

**Fix:** "a shipper picker — a grid filter on thirteen of them, the create-form selector on
`createPurchaseOrder.vue`".

---

### F6 — **Low, pre-existing** — `allClients` over-returns and is unbounded (PROPOSE, do not fix in P5)

**File:** `ClientController.java:255-259`

```java
Long count = clientRepository.count();
Page<Client> clients = clientRepository.findAll(PageRequest.of(0, count.intValue(), Sort.by("name")));
```

1. **Over-return** — the full entity where all 15 consumers bind `item-value="id"` / `item-text="name"`.
   This is what makes F2's clause false, and it is the reason each added function costs more than it
   looks.
2. **`PageRequest.of(0, 0)` throws.** `Spring Data` rejects a page size below 1
   (`IllegalArgumentException: Page size must not be less than one`), so a tenant whose `client`
   table is empty gets a **500**, not an empty page. Latent: every tenant seeds a `System` client
   (id=0). Still a genuine unguarded edge.
3. The one-shot unbounded page ignores `api.paging.max-size`, which this controller's own base class
   is constructed with.

**Recommendation: do NOT fix in P5.** A projection change touches all 15 consumer screens and needs a
consumer sweep for `clNr` usage — out of proportion to a gate widening, and it would make a
three-line commit un-reviewable. Per the ticket policy this is sub-T3 and belongs on the existing
SBDEV-3410 ticket as a proposal; the `PageRequest.of(0,0)` guard is a genuine one-liner if Nam wants
it separately. The cheap mitigation that *does* belong in P5 is F2's comment fix, which records the
hazard where the next widener will read it.

---

### F7 — **Low** — the "26 dispatch sites" figure earns nothing

It is stated, used by nothing, and rots faster than the file count (2 of the 15 files carry the
dispatch two or three times — `mounted` plus a watcher). In a block whose thesis is "state the rule,
not the count", carrying the most volatile count is off-message. Either drop it or label it as
colour. If it stays, F3(b) applies: the given command cannot produce it.

---

### F8 — **Low, informational** — watch item for the next widening

`/reports/container-record` (`containerRecord.vue`, `fn: WEB_UI_VIEW_UNIT_LOAD_RECORD`) is this
ticket's screen's direct sibling: same report shape, already renders `clientName`/`clientNumber`
columns (`containerRecord.vue:87-88`). **Verified not a gap today** — no `clients` reference, no
`getClients` dispatch. If SBDEV-3410's dropdown is copied to it, `WEB_UI_VIEW_UNIT_LOAD_RECORD`
becomes the fifteenth entry. Worth one line in the comment as the named next candidate.

---

## Plan conformance (§5.2 P5)

| Item | Status |
|---|---|
| `@RequiresFunction` + pin row, **same commit**, three constants, eleven → fourteen | ✅ Done and verified — sets identical, 14/14 distinct |
| Restate both files' rotting count comments as the invariant | ⚠ Done, but the invariant as written is **false** (F1) and carries a second over-claim (F2) |
| Mutation-check: remove each of the three in turn, red each time, full varargs, ungated row kept | ✅ Recorded by Nam. **I could not re-run it** (maven forbidden). Structurally sound: unique key, nothing extends `ClientController`, so "exactly 1 of 227" must hold. Full varargs ✓, ungated rows untouched ✓ |
| Re-run blast radius on `dev_wh01_om1` with positive control, all three, record the date | ✅ Done by Nam, **independently reproduced by me**, and extended to five more tenants incl. PRD |

**Process note (Low):** the branch's only commit is `1aa726d5 wip: p5 for suite run`. It needs a real
`SBDEV-3410 P5: …` message before the PR — the plan's atomicity argument is about the *commit*, and a
`wip:` message doesn't carry it.

---

## Things I could not verify — please measure if you want them closed

1. **The mutation runs and the TDD-gate red/green.** Maven was off-limits. I confirmed they are
   structurally sound but I did not observe `Tests run: 5, Failures: 1` / `Failures: 0` myself.
2. **A Hydra `nywh` PRD database**, if one exists separately from `wh01_hydra_v2` — no connection
   from this session. This is the only remaining Q6 gap and F4's wording should name it.
3. **Whether `additionalcontent` ever carries anything sensitive** on a live tenant. I did not query
   its contents. It affects how hard F6 should be pushed, not whether F2 is wrong.

## One note, below finding threshold

`row()` and `resolve()` both build `Set.of(functions)`, which **throws** `IllegalArgumentException` on
a duplicate element rather than deduplicating. The current 14 are distinct so nothing is wrong today,
but if someone later pastes a constant twice into either side they get an
`ExceptionInInitializerError` out of the static block, not the carefully-worded drift message the
comment promises. Pre-existing, no action needed — recorded so the next person reading that message
isn't confused when they get a different one.
