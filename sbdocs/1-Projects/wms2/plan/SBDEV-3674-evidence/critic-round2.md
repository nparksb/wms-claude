# SBDEV-3674 — adversarial review, round 2 (corrections only)

**Lane:** critic, round 2. **Scope:** only what changed since round 1 — `revision: 2` of the v2 plan,
the v1 sibling's §4 (round 3 of corrections on that section), the `wms2/plan/README.md` MOC entry, and
the lead's correction block in `architect-fix-shape.md`. Round-1 findings are not re-litigated.

**Instruments:** `git show` / `git grep` on `v2/wms2-api` `origin/develop` @ `ce454c68`; read-only SQL
on `nywh-hydra-prd`, `nywh-hydra-uat`, `wsl-wineco-uat`. No worktree, no `mvn`, no branch checkout.

**Verdict: REVISE.** The v2 plan itself is in good shape — every HIGH and MED from round 1 landed
correctly in it, and I re-derived its headline numbers against the databases without finding a
material error. **The failure is the sibling sweep.** Two of the three sibling documents still carry
claims the v2 plan explicitly labels false, including the one sentence round 1 called operationally
unsafe. Separately, the one genuinely new acceptance criterion (AC-4b) cannot be written as described
and grades nothing, which leaves Fix C untested.

Escalation: started THOROUGH, escalated to ADVERSARIAL after the second surviving copy in
`architect-fix-shape.md` — the pattern is the known one (a correction block added at the top of a
document while the body keeps asserting what the block retracts), not an isolated slip.

---

## Pre-commitment (written before reading the diffs)

Predicted: (1) the sibling copies would be qualified rather than swept; (2) the day-granularity
numbers would not reproduce under a single convention; (3) at least one new AC would not be red-first;
(4) the "lower bound" hedge on 2026 would be hiding a materially larger post-cutover rate;
(5) a new point-in-time count would be added for every one removed.

Outcome: (1) **confirmed, twice**; (2) **confirmed, minor**; (3) **confirmed — AC-4b, and worse than
predicted: it also cannot discriminate the thing it claims to grade**; (4) **confirmed — 22.2% → 31.9%
and 31.1% → 38.3%**; (5) **confirmed, mildly**. Not predicted: the v1 sibling's three-way split now
sums to 38 and its UAT percentages do not match the fractions printed beside them.

---

# A. High

## HIGH-1 — `architect-fix-shape.md` was qualified, not swept. Three retracted claims are still asserted in it, one of them the "operationally unsafe" sentence.

The lead's correction block got a second-order paragraph about `518 of 522`. Nothing else in the file
moved. Still live:

**(a) The claim round 1 called operationally unsafe — fourth copy, inside the correction block itself.**

> `architect-fix-shape.md` — **"A burned number therefore means the notification WAS delivered and only
> the audit record was lost; a zero-row process type with no burn means nothing was ever sent."**

This is verbatim the sentence round 1's HIGH-3 replaced in three other places, and the v2 plan's §2.3
now says in bold *"⚠ **A burn does NOT mean the notification was delivered**, and an earlier revision of
this plan said it did, in three places."* It said it in **four**. `doSend` burns on all three exits —
I re-read them at `OmsNotificationService.doSend`: the `isSuccess` arm (SENT), the `else` arm below
`LOG.error("OMS notification NOT DELIVERED …")` (FAILED + the real HTTP code), and `catch (Exception e)`
(FAILED + `"503"`). The last two are the cases where resending is the right action.

**(b) The claim the block above it explicitly retracts — twice, still asserted as fact.**

> § Summary: **"At least 267 of the 402 missing rows (66%) are one process type**, measured by an
> instrument independent of the sequence-gap count."
> §A.1: **"So ≥267 of 402 (66%) is one process type on one branch."**

The correction block 50 lines above opens with *"**Retracted:** …≥66% of the 402 is one process type"*
and gives the measurement that kills it (265 of the 267 tote assignments fall in intervals that burned
nothing). A reader who starts at the Summary — which is what a summary is for — reads the retracted
claim as the lane's conclusion.

**(c)** Same § Summary: *"all **33** non-`afterCommit` sites are writing rows fine today"* — the
corrected split has 34 sites outside both the live-transaction and `afterCommit` buckets, and in any
case 33 was derived from the pre-correction 34/1/4.

- Confidence: **HIGH** (quoted verbatim; grep sweep over the whole `SBDEV-3674*` tree returned exactly
  these three plus the critic-round1 quotations of them).
- Why this matters: (a) is the one finding round 1 rated unsafe rather than merely wrong — it tells an
  operator reading a gap "delivered, do not resend" in exactly the cases where nothing arrived. (b) is
  a document that retracts a claim at the top and asserts it in the middle, which is strictly worse
  than never having retracted it.
- **Mitigation that keeps this from being worse:** both the v2 plan and the v1 sibling carry the
  correct wording, and this is an evidence lane rather than the deliverable. It stays HIGH because the
  brief named this file as a sibling copy to check hardest, and because it is the file an implementer
  opens for the fix shape.
- **Fix:** in (a) replace with the §2.3 wording — *"A burned number proves the attempt reached
  `createMessage`; it says nothing about the outcome. What it discriminates is the **double** deferral,
  which never reaches `createMessage` at all: a zero-row process type with **no** burn means the
  callback never ran."* In (b) strike both sentences and point at the correction block. In (c) write
  *"the sites outside `afterCommit` are writing rows fine today"* and drop the count.

## HIGH-2 — AC-4b is not implementable as written, is green on the unfixed tree, and cannot discriminate the placement it claims to grade. Fix C therefore has no acceptance criterion.

> **AC-4b** | *Grades Fix C.* On a **successful** `createAll`, exactly one `ORDER_BATCH_IMPORT` /
> `RECEIVED` row exists and it is written by `OrderRestController.create()` **after** `createAll`
> returns — **pinned by injecting a rollback into the controller after the call and asserting the row
> survives.**

Three separate problems:

**(a) There is no transaction in the controller to roll back.** `OrderRestController` carries
`@Tag`, `@RestController`, `@RequestMapping("/rest/order")` and nothing else; `create()` at
`OrderRestController.java:117` is `@PutMapping` only; `AbstractRestController` is a bare
`abstract class` with no annotations; `spring.jpa.open-in-view=false` (`application.properties:85`);
and the enumeration lane's E5/E6 already recorded zero `@Transactional` / `TransactionTemplate` /
`PlatformTransactionManager` in any filter, interceptor or calling file. After Fix C the write runs
with **no enclosing transaction at all**, so "inject a rollback and assert the row survives" has
nothing to act on.

**(b) The first half is green before the fix.** On a successful `createAll` today, exactly one
`ORDER_BATCH_IMPORT` / `RECEIVED` row exists. `wms-tdd-gate` cannot write it as a failing test, which
is the same defect round 1's MED-4 raised against AC-4 — reintroduced in the criterion added to fix it.

**(c) After Fix A the placement is behaviourally invisible on the success path.** Once
`createServiceLog` is genuinely `REQUIRES_NEW`, the row commits in its own transaction whether the call
sits inside `createAll` or in the controller. The only observable difference between the two placements
is on the **failure** path — which is exactly AC-4.

- Confidence: **HIGH**.
- Why this matters: the plan is `status: approved` and the next step is the TDD gate. As written, Fix C
  — the one fix that changes durability semantics — ships with no criterion that can go red.
- **Fix — delete AC-4b and re-label AC-4 instead.** AC-4 *can* go red first; just not on the unfixed
  tree. §5.2 orders B → A → C, so AC-4 is **green at step 0, red after step 2 (Fix A pins the false
  `"204"` row durable), green again after step 3**. That is the red-first sequence and it is the only
  behavioural test that distinguishes the two placements. Replace AC-4's parenthetical
  *"cannot be written as a failing test"* with: *"Red at the intermediate state — after Fix A and
  before Fix C, `REQUIRES_NEW` makes the `RECEIVED`/`"204"` row durable even though `createAll` threw
  and the controller returned 400. Write it before Fix A, confirm green, confirm red after Fix A,
  confirm green after Fix C."* If a structural pin on the placement is also wanted, make it an ArchUnit
  rule (`OrderBatchCreationService` contains no `createMessage` call) alongside Fix E — a rail, not a
  behavioural AC.

---

# B. Medium

## MED-1 — the `README.md` MOC entry still carries the pre-correction site split and the deadlock derivation the plan now calls false.

> `wms2/plan/README.md`, the SBDEV-3674 entry — **"34 sites have no enclosing transaction so the row
> commits by accident; **1** rolls back with its caller; **4** run inside an `afterCommit()` callback"**
> … **"Deadlock constraint measured **empty** (0 of 39 sites inside a lock-holding tx)."**

Both are the exact claims the plan now refutes in its own text. §2.1 is 34 / **2** / **3**, and §9 row 8
reads *"**No** — but by **table disjointness**, not by 'zero sites inside a lock-holding transaction',
**which is false**"*. The second one also survives in the plan's own §4 only as a quoted retraction; in
the README it is asserted.

Two smaller stale items in the same entry: it reads ***"🟡 DRAFT 2026-10-07, in independent review"***
against `status: approved` / `revision: 2`, and it prints `min(number)=1` without the plan's
`(3 on prd)` qualifier.

- Confidence: **HIGH**. Evidence: grep for `0 of 39` across the plan tree returns the README and, in the
  plan itself, only the line that quotes it in order to refute it.
- Why this matters: the MOC is the navigation surface. The two claims it still carries are precisely the
  two round 1 spent HIGH-1 on.
- **Fix:** 34 / 2 / 3; replace the deadlock clause with *"Deadlock verdict **No**, by table disjointness
  — the inner transaction touches only `message` and `los_sequencenumber` and no caller locks either.
  **Not** by 'zero sites inside a lock-holding tx', which is false: the inline `urlPath == null` site is
  reached from `MobilePickingService.processPick` while it holds `findByIdForUpdate`."* Flip the status
  banner to approved r2.

## MED-2 — §8 risk row 4 still says "exactly one such site exists (#37)". Round 1 named this and it was not applied; no AC covers site #9.

> §8, row 4 — *"Rows that *should* roll back now persist | a false durable record | **exactly one such
> site exists (#37)**; Fix C addresses it structurally, AC-4 pins it"*

§2.1 in the same document now puts **two** sites inside a live transaction, and both change from
"rolls back with the caller" to "persists" under Fix A. Site #9 (`OmsNotificationService`'s inline
`urlPath == null` FAILED write) is **not** touched by Fix C — §4 and §9 row 2 both say so — so after
the fix set there are two sites whose rows newly persist, one of them permanently. Round 1's HIGH-1
point 3 and its F-list item 7 (*"one AC added for site #9"*) both asked for this; neither was applied.

The enumeration lane argues the new behaviour is *desirable* (a standing misconfiguration must not be
hidden by a business rollback). That makes it a behaviour change the plan should **claim**, not one it
should deny.

- Confidence: **HIGH**. Verified `OmsNotificationService.sendAfterCommit`'s `if (urlPath == null) { … return; }`
  block returns before the deferral branch, and `MobilePickingService.processPick`
  (`:464` `@Transactional(value = "tenantTransactionManager", …)`, `:468-471` `findByIdForUpdate` first)
  reaches it.
- **Mitigated by:** the site is dormant on Hydra PRD — all relevant `WEBSERVICE_*` sysprops are
  populated, so `urlPath` is never null there. Real-world blast radius today is nil, which is why this
  is MEDIUM and not HIGH.
- **Fix:** risk row 4 → *"two such sites exist. #37 is removed structurally by Fix C. #9
  (`OmsNotificationService`'s inline `urlPath == null` FAILED write) is **not**, and its row changing
  from 'rolls back with the caller' to 'persists' is an intended improvement: an OMS-URL
  misconfiguration must not be erased by an unrelated business rollback. Dormant on PRD today (all
  sysprops populated)."* Add **AC-9**: *with `WEBSERVICE_STOCK_UPDATE` unset, a `sendStockChangeMessage`
  from a `@Transactional` method that then rolls back still leaves exactly one `STOCK_UPDATE` /
  `FAILED` / `"503"` row.* Red today, green after Fix A — and it is the negative twin of AC-2's fourth
  fixture trap, so the two share a fixture.

## MED-3 — §2.1's "34 of 39 — No enclosing transaction" is false for one of its 34. The corrected table has three rows where the mechanism needs four.

> §2.1 — *"| **No enclosing transaction** | **34 of 39** | `SimpleJpaRepository.save`'s own `REQUIRED`
> opens one and commits | **survives** — correct by accident |"*

Site #39, `BillofladingService:1707`, is one of those 34 and it is **neither**. The enumeration lane's
own §6.3 row 39 records `Proxy? = Y`, `Encl. tx = afterCommit — registered by
reportPendingReversalsOnShippedPallets, called from closeBOL (:686) and finishTransfer (:1618), both
@Transactional(tenantTransactionManager)`. Its row survives because it goes **through the proxy** into a
real `REQUIRES_NEW`, not because `save`'s `REQUIRED` opened a transaction, and it is not "correct by
accident" — it is the only site in the table that is correct **on purpose**.

That fourth outcome is not a curiosity: **it is the post-fix target state for all 39 sites**, and it is
what AC-1 grades. The table reads better with it than without.

- Confidence: **HIGH**. The plan's own §4 handles #39 correctly and separately, so nothing downstream
  rests on the misplacement — this is a precision defect in the table everything else cites.
- Why this matters: round 1's single largest finding was a site in the wrong bucket in this exact table.
  The correction fixed #9 and left #39.
- **Fix:** split the first row — *"No enclosing transaction | **33** | `save`'s own `REQUIRED` opens one
  and commits | survives — correct by accident"* and add a fourth row: *"Inside `afterCommit`, reached
  **through the proxy** | **1** — `BillofladingService:1707` (site #39), the only direct
  `createServiceLog` caller inside a callback | the real `REQUIRES_NEW` suspends the completing
  transaction and commits its own | **survives — correct on purpose. This is what Fix A makes true
  everywhere, and what AC-1 grades.**"* (`PendingReversalReconciliationJob:195`, the other direct
  caller, is genuinely in the no-transaction bucket.)

## MED-4 — the v1 sibling's §4 split now sums to 38, and its own parenthetical contradicts its headline two sentences later.

> `SBDEV-3266-oms-message-rows-lost-in-aftercommit.md` §4 — *"**34 of 39** sites have no enclosing
> transaction … **One** site (`OrderBatchCreationService`, `createAll`) is inside a live transaction and
> rolls back with it. **Three** (`OmsNotificationService.doSend`) run inside an `afterCommit()`
> callback. (A fourth `OmsNotificationService` site, the inline `urlPath == null` branch, `return`s
> *before* the deferral branch and so **belongs to the rollback case above**, not here …)"*

34 + 1 + 3 = **38** against a stated population of 39, and the parenthetical adds the 39th to the
"rollback case", which makes that case **2** — contradicting the "**One**" printed two sentences
earlier. The v2 plan says 2. This is round 3 of corrections on this section and the headline number was
not moved with the parenthetical.

- Confidence: **HIGH**. Arithmetic is on the page.
- **Fix:** *"**34 of 39** sites have no enclosing transaction … **Two** are inside a live transaction and
  roll back with it: `OrderBatchCreationService.createAll`, and `OmsNotificationService`'s inline
  `urlPath == null` branch, which `return`s *before* the deferral branch and so runs in whatever
  transaction the caller holds. **Three** (`OmsNotificationService.doSend` ×3) run inside an
  `afterCommit()` callback …"* — then delete the parenthetical, which exists only to patch the number
  the sentence now states. (If MED-3 is taken, the first figure becomes 33 + a fourth row here too.)

## MED-5 — the v1 sibling prints UAT rates as fractions whose arithmetic is false, with two different denominators in one sentence.

> `SBDEV-3266` §4 — *"Hydra PRD (all v2) **402 of 3,403 — 11.8%**; hydra-uat 2026 **1,612 / 5,650 —
> 22.2%** against 3 burns in 2021–2025; wineco-uat 2026 **42,285 / 93,698 — 31.1%** against 250 in
> 2019–2025."*

- `402 / 3,403` = 11.81% ✓ — burned / **issued**.
- `1,612 / 5,650` = **28.5%**, not 22.2%. 22.2% is `1,612 / (5,650 + 1,612)` = burned / **issued**.
- `42,285 / 93,698` = **45.1%**, not 31.1%. 31.1% is `42,285 / (93,698 + 42,285)`.

So the PRD fraction is burned/issued and the two UAT fractions are burned/**rows**, printed beside a
percentage computed the first way. The v2 plan's §1.1 does not have this problem — it uses a
`rows | burned | lost` table where the denominator is unambiguous. The README entry has the same
defect (`1,612/5,650 = 22.2%`, `42,285/93,698 = 31.1%`).

- Confidence: **HIGH**. All three percentages are correct; only the fractions printed beside them are not.
- Why this matters: it makes a verifiable number fail verification. The previous revision's
  `1,617 / 68,821 (2.35%)` was at least arithmetically self-consistent — the correction traded a wrong
  number for an inconsistent one.
- **Fix:** print the issued denominator everywhere — *"hydra-uat 2026 **1,612 of 7,262 issued — 22.2%**
  (5,650 surviving rows); wineco-uat 2026 **42,285 of 135,983 issued — 31.1%** (93,698 surviving rows)"* —
  or drop the fractions and keep rows / burned / rate as three labelled figures, as §1.1 does.

---

# C. Low

- **L1 — the day-granularity pair 304 / 98 does not reproduce under any single convention.** Four
  copies (v2 §2.2 table, v2 §10 O-5, v1 §4, README). Measured on `nywh-hydra-prd`, session TZ UTC:
  - net gaps (`n − COALESCE(pn,0) − 1`), leading gap included → **306 / 96**, sums to 402, **18.00 vs
    1.39 = 12.9×**
  - net gaps, leading gap dropped → **304 / 96**, sums to 400
  - positive gaps only (`GREATEST(…,0)`, which is where round 1's 98 came from) → **306 / 98**, sums to 404

  The plan pairs 304 (leading gap dropped) with 98 (leading gap kept). The 2-number difference is the
  gap before the first row — `min(number)` is 3 on PRD — and it belongs to **2026-07-12**, which is a
  receiving day (68 `goodsreceiptposition` rows, the first at 14:21:55 UTC, 30 minutes before the first
  `message` row). It cannot land in the non-receiving bucket. No conclusion changes; the ratio moves
  12.6× → 12.9×. **Fix:** use 306 / 96 (18.0 vs 1.39, 12.9×) and footnote that the pre-first-row gap of
  2 is attributed to go-live day. Update §10 O-5's *"98 of 402 fall on days with no receiving"* → 96.

- **L2 — §10 O-4's reconciliation calls a comment-stripped count "raw".** *"Reconciled against the raw
  occurrence count: **41** `createMessage(` occurrences = 37 external + 2 self-calls + 2 declarations."*
  A genuinely raw `git grep -c "createMessage(" origin/develop -- 'src/main'` returns **45** lines. The
  4 excluded are comments: `ItemDataController:184` (commented-out code), `SkuRestController:196` and
  `:334` (prose), `OutboxDispatchService:272` (javadoc). The 37 is **correct** — I reproduced 41 call
  lines minus those 4 — but a reader re-running the stated control gets 45 and reads the scan as having
  missed four sites. **Fix:** *"45 lines match `createMessage(` in `src/main`; 4 are comments
  (`ItemDataController:184`, `SkuRestController:196` and `:334`, `OutboxDispatchService:272`), leaving
  41 = 37 external + 2 self-calls + 2 declarations."*

- **L3 — §1.1's two v1-era row labels do not match their counts.**
  - *"Hydra UAT | 2021–2025 (v1) | 61,550"* — measured **61,551**.
  - *"WineCo UAT | 2019–2025 (v1) | 1,696,555"* — that is **2020–2025**; 2019's **470** rows (0 burns)
    are missing. 2019–2025 is 1,697,025.
  - Neither table accounts for the `created IS NULL` rows, which carry burns: 3 rows / **2** burns on
    hydra-uat, 51 rows / **7** burns on wineco-uat. They are the v1 `resendMessage` rows round 1
    identified. Rates are unaffected at this scale; the row labels should either be corrected or the
    null-`created` rows given a line.

- **L4 — Fix B part 2 needs a new overload, and part 1 alone already turns AC-6 green.** *"Pass
  `resent`/`redeliverId` into `createServiceLog`"* cannot be a signature change: `createServiceLog` has
  two external callers (`PendingReversalReconciliationJob:195`, `BillofladingService:1707`). Also worth
  stating on the record: once `createServiceLog` returns `save(m)`, the entity `resendMessage` mutates
  carries an id, so the subsequent `messageRepository.save(newMessage)` merges onto the existing row and
  **UPDATEs** instead of inserting — AC-6 goes green on part 1 alone. Part 2 is a write-count
  improvement, not an AC-6 prerequisite. The plan's *"the first is not optional"* already points the
  right way; say the rest so an implementer does not treat the overload as blocking.

- **L5 — over-specification (round 1's L6) went up, not down.** §4's "16 `@Lock` sites" count is gone ✓,
  but §1.1 grew from 3 rows to a 5 × 3 table and §2.2 / §10 added 138/402, 130/360, 334/360, 0.67, 210,
  264, 98, 304, 93,698, 1,696,555, 61,550. Several are wrong above (L1, L3) for exactly the reason L6
  predicted. **Fix:** keep in §1.1 the rate per environment, the step-function invariant and the
  positive control; move the per-era row and burn counts into the evidence file with their query text.

---

# D. Answers to the four questions the brief asked directly

**Q2 — is the "2026 calendar year = lower bound" hedge the right hedge?** It is honest and it is
directionally right, but it is also **material**, and the cutover is establishable to the day, so the
hedge should be replaced by the measured number.

First 2026 burn, and the zero-burn months before it:

| env | last zero-burn month | first 2026 burn | pre-cutover 2026 rows | pre-cutover 2026 burns |
|---|---|---|---|---|
| Hydra UAT | 2026-02 | **2026-03-06 19:46:57 UTC** | 2,207 (Jan+Feb) | **0** |
| WineCo UAT | 2026-02 | **2026-03-05 17:25:19 UTC** | 25,593 (Jan+Feb) | **0** |

Cutting the denominator at the cutover:

| env | stated (calendar 2026) | **post-cutover (Mar onward)** |
|---|---|---|
| Hydra UAT | 1,612 / 5,650 rows → **22.2%** | 1,612 / **3,443** rows → **31.9%** |
| WineCo UAT | 42,285 / 93,698 rows → **31.1%** | 42,285 / **68,105** rows → **38.3%** |

(Rate = burned / (rows + burned), the §1.1 convention.) Hydra PRD stays at **11.8%** and remains the
best of the three either way. Recommend replacing *"The 2026 figures are **lower bounds** — calendar
2026 includes pre-cutover months on both UAT boxes"* with the post-cutover rates and a one-line note
that Jan–Feb 2026 carry 2,207 and 25,593 rows and **zero** burns on the two boxes, which is itself the
sharpest form of the step-function argument.

Incidentally the plan **corrected round 1 here**: round 1's HIGH-5 quoted "~68,100 (Mar–Oct 2026)" for
WineCo and derived ~38%. 68,105 is the **post-cutover** count, not the calendar-2026 count (93,698), so
round 1 had mixed the two. The plan's 31.1% is right for the window it names, and 38.3% is right for
the window round 1 was describing.

**Q4 — do the revised ACs go red on the unfixed tree for the right reason?**

| AC | red first? | verdict |
|---|---|---|
| AC-1 | yes | ✅ sound |
| AC-2 | yes, **and the false green is closed** | ✅ sound. `WEBSERVICE_STOCK_UPDATE` is the correct sysprop literal (`WmsConstants.java:1152`). With it seeded, `sendAfterCommit` defers, `doSend` runs in `afterCommit`, the row is lost: 0 rows / sequence +1 = red. The `SENT` + `"200"` assertions are what stop the inline-branch `FAILED`/`"503"` row passing as a green. The arrange-phase sysprop precondition is the right belt. |
| AC-3 | yes | ✅ sound |
| AC-4 | **green today, but red at the intermediate state** | ⚠ see HIGH-2 — the label *"cannot be written as a failing test"* is false and should be replaced by the B→A→C red/green sequence |
| **AC-4b** | **no, and it grades nothing** | ❌ **HIGH-2** |
| AC-5 | yes | ✅ sound. Verified `MessageService.java:99` `m.setVersion(1);`, `:103` `messageRepository.save(m);`, `:106` `return m;` |
| AC-6 | yes | ✅ sound. Reproduced the PRD evidence exactly: ids 177449/177450 on number `0000002137` and 177451/177452 on `0000002138`, each pair `resent=false, redeliver_id=NULL` + `resent=true, redeliver_id=…`, created 8 ms apart. |
| AC-7, AC-8 | n/a | fine |
| *missing* | — | no AC covers site #9 — see MED-2 |

**Q5 — is Fix C implementable as approved? Yes, and the trap you named is not present.**

- **`createAll` has exactly one caller.** `git grep "createAll" origin/develop -- src/main` returns the
  declaration (`OrderBatchCreationService.java:70`) and one call site
  (`OrderRestController.java:351`). Nothing silently loses its audit row.
- **Everything the write needs is in scope at the return point.** `orderBatchList` is the method
  parameter; `messageService` and `syspropService` are already controller fields and are used by the
  FAILED sibling six lines below at `:357`; the status code is the literal
  `HttpStatus.NO_CONTENT.value()` the controller itself returns on the next line
  (`return ResponseEntity.status(HttpStatus.NO_CONTENT)…`). Serialization: the controller's FAILED
  branch uses `WmsObjectMapper.shared().writeValueAsString(orderBatchList)` where
  `OrderBatchCreationService` uses its own `OBJECT_MAPPER` — pick the controller's, which is already
  there and already wraps `IOException`.
- **One thing to state in the plan so it is not "fixed" unasked.** `createAll` declares
  `throws WebserviceBusinessExceptionClientSide, BusinessException`, and the controller's single catch
  is `catch (WebserviceBusinessExceptionClientSide e)`. On a plain `BusinessException` **neither** row
  is written — today and after Fix C alike. Not a regression and not in this ticket's scope; worth one
  sentence in Fix C so the implementer does not widen the catch.

**Q6 — over-specification:** net added. See **L5**.

---

# E. Corrections I checked and found sound — one line each, not re-reviewed

- **§1.1's v2-era rates.** All three calendar-window figures reproduce exactly: Hydra PRD 402 / 3,403 =
  11.8%; Hydra UAT 2026 1,612 burns over 5,650 rows = 22.2%; WineCo UAT 2026 42,285 over 93,698 =
  31.1%. v1-era burns are 3 (hydra-uat 2021–2025) and 250 (wineco-uat 2020–2025) — the step function is
  real and is the strongest single argument in the document.
- **The positive control.** `max(numeric number)` = sequence high-water on all three
  (prd 3,403; hydra-uat 68,821; wineco-uat 1,833,316), `message_archived` empty on all three.
- **§1.1's reworked deletion-exclusion paragraph.** The MED-2 rewrite is correct and correctly scoped:
  derivation named, the SDR `DELETE /v3/message/{id}` surface disclosed, reachability explicitly left
  untested, and the exclusion resting on empirical evidence instead of a path enumeration.
- **§2.1's placement of the inline site in the live-transaction bucket.** Correct — I read
  `OmsNotificationService.sendAfterCommit` on `origin/develop`: the `if (urlPath == null) { … return; }`
  block returns before the `isSynchronizationActive() && isActualTransactionActive()` branch.
- **§2.2's interval statistics.** Reproduced exactly, full table, no sampling: 130 of 360 burn intervals
  contain zero receipt activity and account for **138** of the 402 burns; 334 intervals burn exactly 1
  at **0.67** average positions; the burned-3 bucket has `max_grp = 210`. The "no dose-response"
  argument is correct and is the right one to lead with.
- **§2.2's retraction of the per-interval claim in place.** Right call — the 518/522 figure is true and
  does not support what it was placed under, and saying so beats deleting it.
- **§2.3's L5 note.** Verified verbatim: `// SBDEV-3267: call directly — sendAfterCommit ALREADY defers
  to afterCommit.` at `MobilePickingService.java:588` and `:1298`, with
  `manageOrderService.customerOrderToteAssigned(Collections.singletonList(…))` at `:604` and `:1307`.
  The "migrates **into** this ticket's population on deploy" framing is correct.
- **§2.3's burn-semantics rewrite.** The three-exit argument is right and I verified all three
  `createMessage` calls in `doSend`.
- **§3 Fix B.** `return messageRepository.save(m)` as the non-optional half is correct, and recording
  the `setVersion(1)` deletion as considered-and-rejected (version 0 vs 1 on an optimistic-lock column
  the admin UI edits) is the right disposition.
- **§3 Fix B's ordering withdrawal.** Correct: `createServiceLog` returns the merge source in every
  propagation scenario, so the double insert is already deterministic and Fix A is irrelevant to it.
- **§4's table-disjointness argument.** Correct, and strictly stronger than what it replaced.
  `MobilePickingService.processPick` is `@Transactional(value = "tenantTransactionManager", rollbackFor
  = {BusinessException.class, FacadeException.class})` at `:464` with the `findByIdForUpdate` lock note
  at `:468-471`.
- **§4's `closeBOL` precedent downgrade.** Correct — design precedent, not production proof.
- **§6's fourth fixture trap.** Correct and load-bearing.
- **§10 O-4's arity conclusion.** The 37-external figure verifies (41 call lines − 4 comment lines), as
  does 10 files for `createMessage` and 12 for all 39 external sites. Only the word "raw" is wrong (L2).
- **§1's 37-vs-39 qualification (round 1's L1).** Now parses correctly: 39 external = 37 via
  `createMessage` + 2 direct `createServiceLog`, with the latter two named as the exceptions.
- **§2.5.** The `spring-data-jpa-3.5.7` citation closes round 1's one open instrument question.
- **The v1 sibling outside §4.** Clean — no stale rate, burn-semantics or split claim survives anywhere
  else in that document.

---

# F. Could not verify either way

- Fix E's *"flags **exactly 1 site today**"*. Needs ArchUnit to run; this lane cannot. The rule's shape
  is sound and `ReplenishGeneratorService`'s same-propagation overload exists as described.
- Whether `DELETE /v3/message/{id}` is reachable past the function guard. Unchanged from round 1; the
  plan now correctly declines to claim it either way.
- §10 **O-2 is still owed.** `nywh-shipitez-prd`, `c1wh-shipitez-prd` and `wsl-wineco-prd` all failed to
  connect for me this session too (CONNECT_TIMEOUT, not access). The §2.4 retraction is still verified
  on Hydra only.
- Whether the 96 non-receiving-day burns are picking-lane `STOCK_UPDATE`. O-5's DEBUG-log probe is the
  right instrument and nothing read-only settles it.

---

# G. What would upgrade this to ACCEPT

1. `architect-fix-shape.md` swept, not qualified — the "WAS delivered" sentence replaced and the two
   `≥267 / 66%` survivors struck (HIGH-1).
2. AC-4b deleted and AC-4 re-labelled with the B→A→C red/green sequence, so Fix C has a criterion that
   can go red (HIGH-2).
3. `README.md` MOC entry corrected to 34/2/3, the "0 of 39 sites inside a lock-holding tx" clause
   replaced, status banner flipped (MED-1).
4. §8 risk row 4 restated as two sites, with AC-9 covering #9 (MED-2).
5. §2.1 split into four outcomes so site #39 is not in the "correct by accident" bucket (MED-3).
6. v1 §4's "One" → "Two" with the patch parenthetical deleted (MED-4), and the UAT fractions given the
   issued denominator in both the v1 sibling and the README (MED-5).
7. The day-granularity pair restated as 306 / 96 (L1), and §1.1's two era labels reconciled with their
   counts (L3).
8. §1.1's post-cutover rates (31.9% / 38.3%) replacing the "lower bounds" hedge (D/Q2).
