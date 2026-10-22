# SBDEV-3637 — CRITIC RE-REVIEW (ralplan round 2)

**Plan under review:** `sbdocs/1-Projects/wms2/plan/SBDEV-3637-replenish-redirect-lock-order.md` (r2, 667 lines; r1 was 549)
**My r1 review:** `SBDEV-3637-evidence/review-critic.md` (ITERATE, H1–H6 + M1–M10 + L1–L5)
**Code read:** `.claude/worktrees/wms2-api/SBDEV-3637-readonly`, detached at `ec42f43a` (confirmed `git log --oneline -1` → *"Merge pull request #453 from SiteBossInc/feature/SBDEV-2624-sku-rename-in-place"*). Read-only; no edits, no `mvn`, no HEAD change.
**Independence:** neither `review-architect.md` nor `review-architect-r2.md` was read. Where r2 says *"both reviewers"*, I verified only my own half against the code.

**Verdict: ITERATE — one blocker, and it is the exact failure mode the brief named.**

Five of my six blockers are genuinely cleared, verified in substance against `ec42f43a` and not by the presence of a tag. H2's **deletion** is done — the false sentence is gone and the residual is named in §0, AC-8 and P-7. But **the argumentative slot it vacated is now occupied by a different false claim**, and that claim is load-bearing for the half of the design r1's false claim was propping up. That is the repo's measured *fixing-a-false-claim-tends-to-produce-a-new-one* pattern, reproduced inside the fix for the very finding that named it.

---

## 1. Blocking findings H1–H6 — disposition

### H1 — §0 tabulated 10 of 17 sites → **CLEARED**

r2's §0 table now has 17 rows (one spanning 4 sites) and every one resolves. I re-ran the derivation and mapped every hit:

```
git grep -n "stockunitRepository\.findByIdForUpdate" -- src/main/java   → 17
git grep -c  (same pattern)  → 1+1+3+5+4+1+2 = 17   (two instruments agree)
```

| plan row | grep hit | enclosing method — verified by reading the declaration |
|---|---|---|
| 1 | `ReplenishmentOrderMaintenanceService:424` | `ensureValidSource` |
| 2 | `:579` | `redirectSource` (decl `:499`, `boolean recalcPath` is its 4th param) |
| 3 | `:256` | `reassignOrCancelForMovedStockUnit` |
| 4–7 | `ReplenishorderService:259,260,262,264` | `redirectSource(Long,Long)` |
| 8 | `ReplenishorderService:338` | `cancelReplenishmentOrder` |
| 9 | `MobileReplenishService:775` | `fulfillMultipleUnitLoadsTx` (decl `:719`) ✓ |
| 10 | `MobileReplenishService:218` | `finishReplenishmentOrderWithoutRefill` (decl `:211`) ✓ |
| 11–12 | `StockunitBusinessService:202`, `:277` | `transferStockToUnitLoad` (decl `:178`) ✓ |
| 13–14 | `:472`, `:509` | `changeAmount` (decl `:470`), `changeReservedAmount` (decl `:508`) ✓ |
| 15 | `StockunitService:1060` | reservation cut |
| 16 | `CustomerorderPositionService:148` | per-position loop |
| 17 | `PickingorderBusinessService:566` | nested per-position loop |

3 + 4 + 10 = 17, no row double-counts a hit, no hit is unaccounted. Derivations (b) and (c) also hold: `@Lock(` appears **once** in `StockunitRepository.java` (`grep -c` → 1), and of the two native `FOR UPDATE` texts in `src/main/java` the other is `OutboxMessageRepository.java:49` on `outbox_message`, so *"exactly one executable native **Stockunit** lock"* is true as qualified. The *"no `@Modifying` in `StockunitRepository`"* blind-spot note is also true — `grep -n "@Modifying"` returns one hit and it is inside a comment (`:77`).

### H2 — the false *"already globally ordered, therefore already deadlock-free"* → **PARTIALLY CLEARED. The replacement is also false. See NEW-1 below — this is the blocker.**

What is cleared: the sentence is deleted, the deletion is announced (*"**That is false and it is deleted from the plan and forbidden in the code**"*), `transferStockToUnitLoad` is tabulated at §0 rows 11–12 with the right method label, named in AC-8's rule output, named in the Fix F comment requirement, and proposed as **P-7** ranked second. All of that I verified in the code: `:202` and `:277` are two `PESSIMISTIC_WRITE` acquisitions in `transferStockToUnitLoad`, the dst SU really is chosen by `if (stockunit.getItemdataId().equals(sourceStockunit.getItemdataId()))`, and no id comparison appears anywhere between them.

What is **not** cleared is the sentence that replaced it. See NEW-1.

### H3 — AC-8's *"two pre-existing residuals"* count → **CLEARED, with one omission (NEW-3, non-blocking)**

r2 replaces the count with a rule, a named derivation method and three named blind spots, then lists what the rule returns. The rule is *"every site that takes two or more `Stockunit` row locks in one transaction without comparing their ids, plus every site that takes a `Stockunit` lock before a lock it will also need on another resource type."* Derivation named (the 17-site grep + per-method read + the native-lock grep), blind spots named (bulk `@Modifying` row locks, dirty-checked flush `UPDATE`s, locks via another repository's join), and the answer set is explicitly called *"a lower bound, not a census."* That is the right shape and it is the single largest improvement in r2.

I spot-checked the returned set against the code and each member is genuinely returned by the rule as stated: `transferStockToUnitLoad :202`/`:277` (two SU locks, no id compare — verified); `cancelReplenishmentOrder` (verified in-code comment, verbatim: *"The order row is not locked first; that SU-then-order order is a known, bounded residual."*); `getStockUnitsByItemDataIdForUpdate` (`StockunitRepository:275`, `"FOR UPDATE OF stockunit", nativeQuery = true`, `ORDER BY stockUnit.amount DESC`, no LIMIT); `CustomerorderPositionService:148` and `PickingorderBusinessService:566` (both inside `for` loops over positions). Site 9's `TreeSet` is correctly excluded — it compares ids.

The omission is NEW-3.

### H4 — inverted name/javadoc vs body → **CLEARED as to the inversion; the new javadoc over-claims (NEW-2, non-blocking)**

`holdsLowerSourceLock` → `targetIsBelowHeldSource`, javadoc now reads *"Returns true when {@code currentSource}'s id is above {@code targetId}"* over body `currentSource.getId() > targetId`. Name, doc and body agree, three ways. The added *"Do not 'simplify' `>` to `>=`, `<`, `compareTo` or `Objects.equals`"* paragraph correctly scopes the repo's boxed-`Long` reference-comparison defect to `==`/`!=` and not to `>`, which is right — `>` unboxes. The `ReplenishorderService` precedent it cites (`if (oldStockUnitId != null && oldStockUnitId < newStockUnitId)`) is verbatim at `:258`-ish and is indeed identically shaped.

### H5 — M-6 was an equivalent mutant → **CLEARED**

M-6 is now `>` → `<`, and the old `>` → `>=` is retained as **M-6b, explicitly marked EQUIVALENT and expected to SURVIVE**, with the reason (the equal-id case returns from the SBDEV-3618 Fix E block above the predicate) and the note that *"No fixture can rescue M-6b."* I re-verified the unreachability in the code: the Fix E block at `ReplenishmentOrderMaintenanceService` returns from **both** arms (`if (!recalcPath) { return false; }` … `replenishorderRepository.save(order); return true;`), and between it and the target lock there are exactly two statements — `BigDecimal newRequested = safe(order.getRequestedamount()).min(candidate.getAvailable());` and `if (newRequested.compareTo(BigDecimal.ZERO) <= 0) { return false; }`. The plan's derivation (*"the region is six statements and all were read"*) is honest.

M-6's kill is reachable and attributable on **both** sides, which I checked rather than assuming: under `<`, the `asc` row (10 → 11) flips from plain to skip-locked and the `desc` row (11 → 10) flips the other way, so each dies with a message naming which finder ran. Expected-green side: the `null-source` row short-circuits at `currentSource != null`, and the three `move-*` rows short-circuit at `!recalcPath`, so none of them flips — no collateral red that would blur attribution.

### H6 — the fixture cannot build §7.2's shape → **CLEARED, and cleared better than I asked for**

r2 declines to subclass `AbstractReplenishRedirectPgFixture` at all and models the new IT on `ReplenReassignOnNonReplenishableMoveIT` instead. I verified both halves:

- `AbstractReplenishRedirectPgFixture` really does declare `private void area(long id, String name)` and `private void location(long id, String name, long areaId, Long rackId, long typeId)` — private, and the SQL hard-codes the flags.
- `ReplenReassignOnNonReplenishableMoveIT` really does declare `private void area(long id, String name, boolean useForReplenish)` (`:171`) and `private void location(long id, String name, long areaId, boolean transferLane)` (`:180`), plus `unitload` (`:190`), `stockunit` (`:198`), `replen` (`:206`) and its own `wipe()` (`:162`), and it `extends BasePostgresIntegrationTest` with `@Transactional(propagation = Propagation.NOT_SUPPORTED)` (`:74`–`:75`) — exactly as the plan states.
- The named AC2 test resolves: `:283 void moveOntoLaneWithAlternate_reassignsSameOrder()`, and its class javadoc carries the mutant line the plan says must be updated (`:59` *"make {@code redirectSource} never succeed → kills <b>AC2</b> and <b>AC8</b>"*).

§5 now carries the "no change to the fixture, and that is a decision" row. Nothing is shed.

---

## 2. The ten Mediums — disposition

| # | disposition | evidence |
|---|---|---|
| **M1** IT-2's raw JDBC holder contradicts §7.1 | **CLEARED** | §7.1 now carries the `[A-8/M1]` paragraph naming (a) the `TransactionTemplate(tenantTransactionManager)` holder as preferred and (b) a `Connection` with `setAutoCommit(false)` held across a `CyclicBarrier` and rolled back in a `finally`, and §7.2's IT-2 paragraph repeats the constraint rather than contradicting it |
| **M2** AC-11 covers ~7 of ~19 assertions | **MOSTLY CLEARED — two holes left, NEW-4** | 12 mutant rows now, and three assertions named as uncovered-by-construction. But U-I and M-4's second leg still have no killer (NEW-4) |
| **M3** skip-locked miss conflates contended with vanished | **CLEARED** | `existsById` disambiguation in Fix B's code, the ⚠ paragraph in Fix C, the WARN comment, U-J, M-9, AC-14, and the §7.6 operator row. `StockunitRepository extends PagingAndSortingRepository<Stockunit, Long>, CrudRepository<Stockunit, Long>` — `existsById` is available with no new method. Soundness analysis below |
| **M4** §0 row 9 cited `transferStockToUnitLoad:202` under the `changeReservedAmount` label | **CLEARED** | rows 11 and 14 now carry the right method for each snippet; verified against the declarations at `:178` and `:508` |
| **M5** `deadlocks = 0` has no control in the environment measured | **CLEARED** | §1 now carries the ⚠ naming the test-lane/live-server gap, the unread `stats_reset`, the exact re-measurement query, and *"nothing below rests on it"* |
| **M6** the unique index caps per destination, not per item | **CLEARED everywhere it leans on it** | I checked all four load points: the §0 header ⚠, §2.3 shape 4, §7.2's *"the index **permits** the two-order configuration this IT needs … it only forbids sharing a destination"*, and Fix F's *"must **not** repeat the … ceiling as a bound."* §5 says only that the indexes *exist*, which is true. No surviving per-item framing |
| **M7** three alternatives unrepresented | **CLEARED** | native `FOR UPDATE SKIP LOCKED` is now named with its in-repo precedent (verified: `OutboxMessageRepository.java:49` carries `FOR UPDATE SKIP LOCKED` literally) and rejected on two stated reasons, the second of which is **self-flagged as a mechanism claim that was not disassembled** — that self-limitation is the right move. Do-nothing and retry-on-`40P01` both now argued |
| **M8** the replacement comment's *"matches D7"* | **CLEARED** | Fix B's drafted comment opens *"Role-ordered acquisition is RETAINED … This is NOT the ascending-id discipline of ReplenishorderService.redirectSource's D7 branch or of MobileReplenishService's TreeSet — those genuinely reorder their acquisitions; this one cannot"*, and Fix F forbids the old opening by name |
| **M9** AC-2 has no red-first | **CLEARED** | §6.2 step 1 declares the deviation and gives a real substitute (write IT-3b/3c against `findByIdForUpdate` first; 3b red because it waits, 3c red because the SQL has `for update` and no `skip locked`), with *"a gate that skips this has not red-firsted Fix A"* |
| **M10** IT-1e passes for a do-nothing move path | **CLEARED** | IT-1e now asserts a specific post-state (`state = 300`, `stockunit_id` unchanged on both, `reservedamount` unchanged, one WARN each) and M-8 adds the always-CONTENDED mutant killed by `ReplenReassignOnNonReplenishableMoveIT` AC2 |

**Lows.** L1 moot (no longer a subclass). L2 cleared (§7.2 declares its own single vocabulary). L3 cleared (M-3 labelled manual/lane-wide with the IT-1b-fails-first caveat spelled out). L4 cleared — the `targetId != null` guard replaces the asserted comment, and the derivation is true: `toLong` at `:882` has exactly the two null-returning branches the plan cites (`if (value == null) { return null; }` and the `catch` around `Long.parseLong`). L5 **not cleared — it was replaced with a less accurate statement, see NEW-5.**

---

## 3. New text, reviewed on its own merits

### NEW-1 (HIGH, BLOCKING) — the vacated slot holds a new false claim, and it is false in both halves

§4 Fix B, the paragraph headed *"Why the ascending edge keeps waiting — the honest justification `[A-7/H2]`"*, ends:

> The actual reason to keep waiting is narrower: **the ascending edge agrees with the counterparties that *are* id-ordered (`ReplenishorderService.redirectSource`'s D7 branch, `MobileReplenishService`'s `TreeSet`), and converting it to skip-locked would buy nothing against either residual above, because neither of those cycles runs through two stock units.**

Two sentences earlier, the same section constructs this counterexample, which I verified line by line against `StockunitBusinessService`:

> recalc holds `S_low` (site 1) and waits on `S_high` (site 2, ascending, plain); `transferStockToUnitLoad` holds `S_high` (`:202`) and waits on `S_low` (`:277`). ABBA, `40P01`, unchanged by this ticket.

**(a) *"neither of those cycles runs through two stock units"* is false for the first residual.** Every resource in that cycle is a `Stockunit`: `S_low` and `S_high`. The plan contradicts itself inside one section. (The clause *is* true of the second residual, `cancelReplenishmentOrder`, whose cycle runs SU ↔ order row — I verified that one: `:338` locks the SU, then `markCancelled` writes the order row.)

**(b) *"converting it to skip-locked would buy nothing"* is false, and it is false in the direction that matters.** If the ascending branch were skip-locked, recalc would never wait on a second stock unit on either branch — site 2 would be a non-waiting acquisition unconditionally. Recalc then cannot be the waiting party in **any** SU↔SU cycle, so the `transferStockToUnitLoad` ABBA the plan just constructed cannot form. Always-skip-locked buys exactly the closure of the residual the plan says it buys nothing against. (Checked for a loophole: recalc's *first* SU acquisition, site 1, is a plain wait and stays one — but at that point recalc holds no stock-unit lock, so no SU↔SU cycle can close through it.)

Why this blocks rather than being a wording nit:

1. **It is the only justification left standing for the hybrid's ascending half inside Fix B.** r1's justification was withdrawn; this one replaces it in the same position and fails for a related reason — reasoning from an enumeration of counterparties (now two instead of two others) without asking what the conversion actually removes.
2. **Fix F puts it in the code.** The replacement comment is specified to state *"the residuals that remain open"*; this framing travels with them into the file that the old ⚠ block's history exists to warn about.
3. **It mis-prices P-7.** P-7's real standing is that it closes that cycle *without* paying the cadence cost — which is a genuinely strong argument, and the plan forfeits it by claiming the cost would buy nothing in the first place.

I am **not** reopening hybrid vs always-skip-locked; the brief settles that and the 77%/unmeasured-contention-rate argument under *"Why not always-skip-locked"* is intact, honest and sufficient on its own. What must change is the false support.

**Clears when:** the clause *"because neither of those cycles runs through two stock units"* is deleted along with *"would buy nothing against either residual"*, and the true version is written, e.g. — *"Converting the ascending edge to skip-locked **would** close the `transferStockToUnitLoad` cycle, because recalc would then never wait on a second stock unit at all. It is rejected anyway: it pays the spurious-defer cost on 77% of second-lock edges at a contention rate this plan cannot measure (above), and the same cycle is closed more cheaply and more locally by id-ordering `transferStockToUnitLoad`'s own pair (P-7), which costs nothing on the recalc path. It buys nothing against `cancelReplenishmentOrder`, whose cycle runs through an order row, not a second stock unit."* That is true, it still selects the hybrid, and it makes P-7's ranking follow from the argument instead of sitting beside it.

### NEW-2 (MEDIUM) — the repaired javadoc's first sentence over-claims the branch

`targetIsBelowHeldSource`'s javadoc opens:

> The branch invariant, stated once: **skip-locked exactly when this acquisition would DESCEND**

The branch is `boolean skipLocked = !recalcPath || targetIsBelowHeldSource(currentSource, candidate.stockUnitId);`. On the move path it is skip-locked on **ascending** pairs too — which the case table, AC-4 and U-param's `move-asc` row all state correctly. So "exactly when" is false about the branch, in the one comment labelled *"the branch invariant, stated once."* The rest of the javadoc (*"Returns true when `currentSource`'s id is above `targetId`"*) is correct about the method.

Not High: an implementer who acts on it would drop the `!recalcPath ||` term, and U-param's `move-asc` row kills that with an attributable message. But H4's whole lesson was that this comment is the one place a wrong sentence is invisible in production, and the repair installed a second wrong sentence at the same site. **Clears by:** scoping it — *"Returns true exactly when this acquisition would DESCEND. The caller skip-locks on that **or** on the move path (see the case table); this predicate is only the recalc half."*

### NEW-3 (MEDIUM) — AC-8's rule returns the method this ticket is fixing, and the stated answer set omits it

The rule is *"every site that takes two or more `Stockunit` row locks in one transaction without comparing their ids."* Post-fix, the move path does exactly that: site 3 (`findByIdForUpdate(movedStock.getId())`, plain) then site 2 (skip-locked), with no id comparison — `!recalcPath` short-circuits the predicate. The recalc path's descending branch likewise takes site 1 then site 2 with the comparison used only to choose a finder, not to order the acquisitions.

The plan is honest about this elsewhere (*"It does **not** make the move path deadlock-free"*, and §0 row 2 is labelled the defect), so the rule is arguably returning the right answer and the **list** is what is incomplete. Either way AC-8 is the one AC whose grading is "does the rule return the right set", so it should not have its own subject missing. **Clears by:** adding to *"What the rule currently returns"* a first entry — *"`ReplenishmentOrderMaintenanceService` itself, on both paths: this fix removes the WAIT on the inverting edge, it does not introduce an id ordering, so the method remains in the rule's answer set by construction"* — or by narrowing the rule to *"…without comparing their ids **and waiting on the second**."* The first is better; the second re-opens the question of what "comparing" buys.

### NEW-4 (MEDIUM) — AC-11's narrowed claim is still not quite true: three assertions have no killer

AC-11 now reads *"Every new assertion is mutation-checked with an attributable kill **except the three §7.5 names as uncovered by construction**"* — IT-3a, IT-2, IT-4. Checking the remainder:

- **U-I** (the main `REDIRECT_CONTENDED` WARN: emitted exactly once, carrying order number, target id, path, state) has no mutant row and is not in the exception list. M-10 drops the *`NO_HEAL`* WARN and kills U-K; nothing drops the primary one. One row fixes it: *"drop the `REDIRECT_CONTENDED` WARN → U-I."*
- **M-4's second leg is mis-attributed.** M-4 is *"collapse the two `targetStock == null` cases to one outcome"*, killed by *"U-F (if collapsed to `NO_CANDIDATE`) **or U-H** (if to `CONTENDED`)."* U-H grades the `catch (FacadeException)` arm, which a collapse of the two null cases does not touch. Collapsing to `CONTENDED` makes the **plain**-finder miss defer instead of cancel, and no named test asserts "recalc, ascending edge, target row vanished → order `CANCELED`". So that direction of M-4 currently has no killer. **Clears by:** naming the existing `…UnitTest` case that covers it (the class has 76 `@Test`s, so one plausibly exists) or adding one, and re-pointing M-4's second leg at it.
- **U-param's `null-target` row does not exist.** AC-3 grades *"A null `candidate.stockUnitId` … raises the named `InvalidDataAccessApiUsageException` rather than a bare NPE"* against *"U-param rows `null-source`, **`null-target`**"*, and M-11 is killed by *"the null-target row added to U-param."* §7.4's table has eight rows — `asc`, `asc-boundary`, `desc`, `desc-boundary`, `null-source`, `move-asc`, `move-desc`, `move-null-source` — and none of them is `null-target`. The parameterization's declared axes (*"`(recalcPath, id relation, null source)`"*) cannot express it either. This is not hypothetical: `toLong` really can return null (verified at `:882`), the Fix E `Objects.equals` check passes a null id through, and `newRequested` is computed from `candidate.getAvailable()` not the id, so a null id does reach the lock line. **Clears by:** adding the row and the fourth axis.

### NEW-5 (MEDIUM) — P-6's "correction" of L5 replaced a correct description with a less accurate one, and accuses it of being wrong

r2's P-6 says:

> ⚠ **r1 described this as `src-SU → src-UL → src-location → dst-UL → dst-SU → dst-location` and framed the SU→SU hazard as needing a `Location` to close it `[L5]`. That is wrong in both halves**

Only the second half was wrong. The acquisition order r1 quoted is **correct** — it is the code's own comment, verbatim: *"Stable order: src-stockunit (held above) → src-unitload → src-location → dst-unitload (hoisted before findByUnitloadId) → dst-stockunit → dst-location"* — and the code matches it (`unitloadRepository.findByIdForUpdate` `:238`, `locationRepository.findByIdForUpdate` `:243`, `unitloadRepository.findByIdForUpdate` `:250`, SU `:277`, `locationRepository.findByIdForUpdate` `:283`). r2's replacement, *"the acquisition order on that path is src-SU → dst-SU → dst-Location"*, drops three real lock acquisitions. (It also cites the destination `Location` lock as `:281`; it is `:283`.)

Consequence beyond tidiness: it feeds **NEW-6**.

### NEW-6 (MEDIUM) — P-7's "can be reordered cheaply, no sequencing obstacle" is NOT ESTABLISHED, and the code suggests the opposite

P-7 says:

> Unlike site 2 it **can** be reordered cheaply: both ids are known before either lock, so a `TreeSet`-style ascending acquisition is available with no sequencing obstacle.

The pre-lock read exists (`List<Stockunit> destinationStockunitList = stockunitRepository.findByUnitloadId(destinationUnitload.getId());` near the top), so a candidate `dstSuId` *is* knowable early. But the code deliberately does **not** use that read to pick the destination SU. It re-reads the list after taking the dst-unit-load lock, under a comment that says why: *"Lock destination unitload BEFORE reading its stockunit list to prevent a concurrent same-itemdata insert from bypassing the merge branch below"* and *"Re-read destination stockunit list after holding the unitload lock (post-lock snapshot)."* Selecting the dst SU from the **pre**-lock read in order to id-sort the two acquisitions is exactly the race that re-read closes — structurally the same objection this plan makes against pre-querying candidates at site 2.

P-7 is a proposal, not scope, so this does not touch the PR. But it sizes P-7 at ~½ day on a premise the code contradicts, and P-7 is ranked second of seven. **Clears by:** replacing the clause with *"NOT ESTABLISHED — a `TreeSet` acquisition would have to pick `dstSuId` from the pre-lock `findByUnitloadId` read, which is the read the post-lock re-read deliberately replaced; whether the two can be reconciled needs its own trace, so treat ~½ day as a floor."*

### NEW-7 (LOW) — U-param's two "boundary" rows are duplicates of the rows they are supposed to flank

```
| asc           | true | 10 | 11 | plain findByIdForUpdate(11L), never() skip-locked |
| asc-boundary  | true | 10 | 11 | (same row with target = source + 1) — exercises the > boundary from above |
| desc          | true | 11 | 10 | skip-locked findByIdForUpdateSkipLocked(10L), never() plain on 10 |
| desc-boundary | true | 11 | 10 | (target = source − 1) — exercises the > boundary from below |
```

`11` already *is* `10 + 1`, and `10` already *is* `11 − 1`, so each boundary row is byte-identical to the row above it. The ⚠ underneath justifies them against *"only `source = 10, target = 99` style pairs"* — but the table contains no such wide pair at all, so the fixture is adjacent-only rather than spanning the band the note asks for. Harmless to the mutants actually listed (M-6 dies on both rows either way, M-6b is equivalent), so: LOW. Fix by widening `asc`/`desc` to a far pair (`10 → 99`, `99 → 10`) and leaving the boundary rows adjacent, which is what the note describes.

### The `existsById` disambiguation — sound, and safe in the right direction

Asked specifically by the brief, so stated explicitly. The check is available with no new repository method (`StockunitRepository extends PagingAndSortingRepository<Stockunit, Long>, CrudRepository<Stockunit, Long>`). It is racy, and the plan says so twice (*"it narrows the window, it does not close it"* in both Fix B's comment and Fix C). What the plan does **not** say, and should, is which way a wrong answer errs — I worked it through and the answer favours the design:

| state of the target row | `SKIP LOCKED` | `existsById` | outcome | correct? |
|---|---|---|---|---|
| locked by another tx, not deleted | empty | **true** | CONTENDED | ✓ |
| deleted **and committed** before the check | empty | **false** | NO_CANDIDATE → cancel | ✓ (same as today's plain finder) |
| deleted, **uncommitted**, lock held | empty | **true** (row still visible) | CONTENDED | defer, then heals next tick |
| deleted **after** the check | empty | true | CONTENDED | defer, then heals next tick |

There is no path on which `existsById` returns false for a row that merely exists-and-is-locked, so the check can only ever err toward **defer**, never toward a spurious **cancel**. That matters because cancel is the destructive outcome and defer is the reversible one, and it is what makes a racy check acceptable here at all. It holds under READ COMMITTED and under REPEATABLE READ alike, so it does not depend on an isolation level the plan has not pinned. **Add one sentence to Fix C saying it** — it is the strongest thing available about this check and the plan currently leaves it on the table.

One consequence the plan does state but worth confirming: on the recalc path the disambiguation makes a vanished target **cancel** the order, which is today's behaviour through the plain finder (`targetStock == null → return false → cancelOrder`), so it is not a new outcome.

### Other new material, checked and sound

- **Fix D's `[A-6]` non-`PROCESSABLE` analysis.** Verified in code: `recalculateOrder` re-guards `!Objects.equals(order.getState(), WmsConstants.State.PROCESSABLE) { return; }`, while the move path probes `findIdByStateLessThanAndStockunitId(WmsConstants.State.FINISHED, movedStock.getId())` (`:236`) and rejects only `order.getState() >= WmsConstants.State.STARTED` (`:243`). The wider band on the move path is real, so the no-heal hazard is real, and the cheap-guard choice (a distinct WARN rather than narrowing the cancel) is the right call under D1. The measurement that sizes it carries its blind spots inline (two tenants, ShipItEZ denied, native-UPDATE invisible to the grep).
- **`[A-2]`'s correction of the enum javadoc.** Verified: `alignDestination` really does `order.setDestinationId(assignment.getAssignedlocationId()); replenishorderRepository.save(order);` and then `return false`, and `recalculateOrder` calls it at `:303` **before** `ensureValidSource` at `:307`. So r1's *"the transaction is NOT rollback-marked / nothing was written"* was indeed false at transaction scope, and AC-5's rescoping to the method is correct.
- **`[A-4]`'s (move, null source) row.** Verified reachable: `Stockunit lockedSource = stockunitRepository.findByIdForUpdate(movedStock.getId()).orElse(null);` then `redirectSource(order, lockedSource, share, false)` with no null guard between them.
- **The `REDIRECT_CONTENDED_NO_HEAL` WARN** is well-formed, fires only on the narrow condition, and §7.6 gives the operator a row for it with the right expectation (**zero**) and the right remedy. Its only gap is NEW-4's U-I sibling.
- **D2's expiry condition** is a genuinely good addition: tying the hybrid's survival to P-3 landing, and saying so in the code, is the honest form of a provisional design.
- **The measured-zero discipline** is now consistent at every point of use — frontmatter, §0, §1, §2.3 shape 4, Fix D's state histogram, R-1 and §6.1 row 2 each carry the three-tenant / ShipItEZ-denied caveat, and §1 adds the unread `stats_reset`. I found no surviving sentence that reads a fleet claim out of those zeros.

---

## 4. The five enforcement questions, re-answered

1. **Principle–option consistency** — **PASSES now except for NEW-1.** The ascending framing is gone from Fix B's comment and from Fix F; the case table's row 3 explicitly says *"It is **not** 'already deadlock-free'"*. The one remaining inconsistency is that the sentence replacing it is also false.
2. **Fair alternatives** — **PASS.** Six are now represented (NOWAIT, pre-query-and-lock-both, always-skip-locked, native `FOR UPDATE SKIP LOCKED`, retry-on-`40P01`, do-nothing), each at strength, and the native-query rejection even self-flags one of its two reasons as underived.
3. **Risk mitigation clarity** — **PASS.** Unchanged from r1; every R-row still carries a checkable action.
4. **Testable acceptance criteria** — **PASS with the NEW-4 holes.** AC-8 is now a rule with a derivation (modulo NEW-3), AC-11 is narrowed (modulo U-I and M-4), AC-5's IT-1e leg is specific. AC-3's second leg points at a row that does not exist.
5. **Concrete verification (the floor)** — **PASS.** DB query ✓ with blind spots. Failing test first ✓ for the ABBA and now ✓ for Fix A via a declared substitute. Mutation with attributable kills ✓ (12 rows, one correctly marked EQUIVALENT, three correctly named as uncovered) minus NEW-4. Independent review ✓. Full suite vs an adjacent baseline ✓ with the flaky-IT rule and the `pgrep` rule carried.

**Overclaiming check.** r2 is materially cleaner than r1: *"two pre-existing residuals"*, *"its fourth subclass"*, *"already globally ordered"*, the unique-index ceiling and AC-11's blanket claim are all gone or qualified, and several completeness sentences now carry their derivation and blind spots inline. The violations I can still name: NEW-1 (*"neither of those cycles runs through two stock units"* / *"would buy nothing"*), NEW-2 (*"skip-locked exactly when this acquisition would DESCEND"*), NEW-6 (*"no sequencing obstacle"*), and NEW-5's *"wrong in both halves"*, which is itself an overclaim about r1.

**Zero-result controls.** Every zero-scan in r2 that I checked carries a positive control in the same scan — the `switchSourceToUnitLoad` absence (control: `redirectSource` returns 23+ hits), the `@Modifying` absence (control: 8+ other repositories), the `State.RESERVED` absence (control: `State.PROCESSABLE` across 5+ files), the unresolvable `c99ddaff` (control: six genuinely unmerged branches found by the same sweep). I re-ran the first and it holds.

---

## VERDICT

ITERATE

**Blocking (one):**

1. **NEW-1 (High)** — §4 Fix B's replacement justification is false in both halves. *"Neither of those cycles runs through two stock units"* contradicts the `transferStockToUnitLoad` counterexample the same section constructs (both resources in it are stock units), and *"converting it to skip-locked would buy nothing against either residual"* is wrong — always-skip-locked would stop recalc ever waiting on a second stock unit and would close that cycle. **Clears by:** deleting both clauses and replacing them with the true version — always-skip-locked *would* close the `transferStockToUnitLoad` cycle, and is rejected anyway because it pays the spurious-defer cost on 77% of second-lock edges at an unmeasured contention rate while P-7 closes the same cycle locally and for free; it buys nothing only against `cancelReplenishmentOrder`, whose cycle runs through an order row. The corrected text must also be what Fix F puts in the code.

**Non-blocking, worth fixing in the same pass:** NEW-2 (the repaired javadoc's *"exactly when"* is false of the branch on the move path — scope it to the predicate); NEW-3 (AC-8's rule returns `ReplenishmentOrderMaintenanceService` itself and the answer set omits it); NEW-4 (U-I has no mutant and is not in the uncovered list; M-4's collapse-to-`CONTENDED` leg is attributed to U-H, which grades a different arm; AC-3 and M-11 both cite a `null-target` U-param row that the table does not contain and the declared axes cannot express); NEW-6 (P-7's *"no sequencing obstacle"* is contradicted by the post-lock re-read — mark NOT ESTABLISHED); NEW-5 (P-6's accusation that r1 was *"wrong in both halves"* is itself wrong — r1's acquisition order matches the code's own comment verbatim; and the destination `Location` lock is `:283`, not `:281`). Plus the one-sentence addition to Fix C stating that `existsById` can only err toward defer, never toward a spurious cancel — the plan has earned that sentence and is not claiming it.

**Low:** NEW-7 (U-param's two boundary rows are byte-identical to the rows they flank, so the fixture is adjacent-only and the ⚠ justifying them describes a wide pair the table does not contain).

**Not re-litigated, per the brief:** D1 (CONTENDED defers on both paths), hybrid vs always-skip-locked as a *design choice*, the sequencing against SBDEV-3626, and the absence of a verify script. NEW-1 is raised strictly as a false statement made in support of the settled choice, which the brief asks for explicitly; the choice itself survives the correction, and survives it better.
