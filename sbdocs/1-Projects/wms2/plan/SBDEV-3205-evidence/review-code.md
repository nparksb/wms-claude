# SBDEV-3205 — independent code review

**Verdict: APPROVE WITH FIXES**

The polarity correction is right: the job's loop clears the hold, so the query has to select rows that
still carry it, and `lockedtooperator = true AND pickinginprogress = false AND modified < :timeOut AND
state < :state` is exactly that set. The test is a real regression pin — it reads the SQL off the
annotation, runs it against a real Postgres, and would have caught the original defect. The fixes below
are one unpinned predicate, one predicate whose necessity I dispute, and four factual claims in comments
that do not survive checking.

Reviewed at worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3205`, branch
`SBDEV-3205-pick-timeout-query-polarity`, base `origin/develop` `951b854c`. Read-only: no build, no git
mutation, no edit. DB evidence gathered 2026-09-02 over five tenant databases.

**Provenance of the repository quotes.** A mutation-check script was hand-editing
`PickingorderRepository.java` in that worktree during this review. Every line number and snippet quoted
below was re-verified against the authoritative fixed copy the team lead supplied
(`scratchpad/Repo.fixed.java`), which was byte-identical to the worktree file at verification time
(md5 `a5da5e08ef45e2db92af4f6ce2addc39` on both). No quote came from a mutant. The test file was not
under mutation and was read directly.

---

## Findings

### 1. MEDIUM — the diff's only new predicate is pinned by no test

`src/main/java/net/aim_ai/wms/repo/jpa/PickingorderRepository.java:78`

```sql
" AND po.operator_id IS NOT NULL " +
```

No fixture row in `ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest` has
`lockedtooperator = true AND operator_id IS NULL`. Walk the seven rows: `HELD_EXPIRED`,
`HELD_IN_PROGRESS`, `HELD_FRESH`, `HELD_TOTES`, `HELD_PICKED` all set `operator_id = OPERATOR`;
`ALREADY_RELEASED` and `RESERVED_NOT_LOCKED` both set `lockedtooperator = false`, so predicate 1 already
excludes them. Delete `AND po.operator_id IS NOT NULL` from the production query and all eight tests stay
green, including `releaseSetIsExactlyTheHeldExpiredOrder`, which is the one advertised as pinning the
conjunction.

That is the mutation check the floor requires, and the added line fails it. Whatever is decided in
finding 2, the fixture needs an eighth row — `ORPHAN_LOCKED`, `lockedtooperator = true`,
`operator_id NULL`, expired, RAPID_PICKING, not in progress — plus a test asserting the intended
behaviour, so the predicate is observable in one direction or the other.

### 2. MEDIUM — `operator_id IS NOT NULL` is redundant in every reachable state and excludes the one anomaly the job is best placed to repair

Same line. Both sites that ever set the hold set the operator in the same breath, one statement apart:

- `MobilePickingService.java:1065-1066` (`rapidPickingScanPackage`)
- `MobilePickingService.java:1180-1181` (`rapidPickingScanPackageAndType`)

Those are the only two `setLockedtooperator(true)` in `src/main` (grepped repo-wide; the only other
`lockedtooperator` writes are the false-setters and the schema default). So on every reachable path
`lockedtooperator = true` implies `operator_id IS NOT NULL`, and the new predicate adds nothing.

Where it is not a no-op is the reverse anomaly, `lockedtooperator = true AND operator_id IS NULL`. That
state is what a timeout job exists to clean up, and it is the state that most hurts: at
`MobilePickingService.java:1059`,

```java
if (pickingOrder.getLockedtooperator() && !pickingOrder.getOperatorId().equals(user.getId())) {
```

a locked row with a null operator throws NullPointerException, so every operator who scans that parcel
gets a 500 forever. The new predicate makes the timeout job unable to repair it.

I am rating this Medium, not High, because the anomaly is not currently reachable or present:

- The only path that could produce it is `MobilePickingService.releasePickingOrder(Pickingorder)` at
  `:316-319`, which sets `state = PROCESSABLE` and `operatorId = null` and never touches
  `lockedtooperator`. That overload has **no caller in `src/main`** — `PickingController:163` calls the
  `PickingorderPosition` overload at `:1352`. It is live only in `MobilePickingServiceUnitTest`, so a
  future caller could resurrect it.
- Measured across four tenant DBs (dev, hydra UAT, hydra PRD, wineco UAT): `orphan_locked = 0` in all
  four.

Suggested fix, in preference order. (a) Drop the predicate — `lockedtooperator = true` is the invariant
the job repairs, and it already excludes every already-released row the ticket worries about, so
`alreadyReleasedRowIsNotSelected` still passes without it. (b) Keep it, add the `ORPHAN_LOCKED` fixture
row and a `doesNotContain` test, and put a line in the comment block naming what repairs an orphan lock
instead. What is not acceptable is keeping it with neither.

### 3. MEDIUM — `pickinginprogress = false` is not SBDEV-1675's collision guard; the claim is wrong in two places

`PickingorderRepository.java:71-72`

```
// only the contradictory line: `operator_id is null` alone selects ALREADY-RELEASED rows and turns
// the job into an UPDATE per row per minute. `pickinginprogress = false` is the SBDEV-1675
// collision guard and stays.
```

and the test javadoc, `ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest.java`, AC3b:

```
// `pickinginprogress = false` is the predicate SBDEV-1675 was actually protecting
```

`git log -L` over the method shows `pickinginprogress = false` present in the **initial checkin**
`a685e07b`, years before SBDEV-1675. Commit `326b20dc` (SBDEV-1675) added exactly two lines to this
query and nothing else:

```
+        " AND po.operator_id is null " +
+        " AND po.lockedtooperator = FALSE " +
```

So SBDEV-1675 contributed only the defect. A future reader who trusts the comment will believe deleting
`pickinginprogress = false` reverts a deliberate 1675 guard, when it actually reverts the original
design. Reword to: "predates SBDEV-1675 — present in the initial checkin `a685e07b`; `326b20dc` added
only the two broken lines." The test javadoc's neighbouring sentence ("It pre-dates the two broken
lines") is correct and can stay.

### 4. MEDIUM — "measured 218 candidate rows on dev" does not reproduce

`ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest.java`, the "Why it is NOT a one-line fix"
section:

```
{@code modified} per row per tenant (measured 218 candidate rows on dev)
```

Run against `dev_wh01_om1` (the wineco dev tenant DB) on 2026-09-02, the variant's own result set —
`lockedtooperator = false AND operator_id IS NULL AND pickinginprogress = false AND modified < now() -
'40 seconds' AND state < 600 AND s.sectionpickingtype = 'RAPID_PICKING'`, joined through
`pickingorder_position` — returns **0**. Nearest numbers I could produce on that DB: 15 (same join and
section type, state filter dropped), 20 (`state < 600` alone), 6 (`lockedtooperator = false AND
operator_id IS NULL AND pickinginprogress = false AND state < 600`, no join). None is 218.

The number may come from a different tenant DB or an older snapshot, but as written it is
unattributed and does not check out. Either name the database and date, or delete the parenthetical —
the qualitative claim (that variant selects already-released rows and rewrites them) stands on its own
and is correct.

### 5. LOW — "eleven tests … every one of them stubs" is not literally true, and undercounts the files

Test javadoc, "Why this test is at the SQL layer":

```
{@code ReleaseExpiredPickingOrdersFromUserJobTest} has eleven tests over this job and every one
of them stubs {@code getPickingOrdersToReleaseExpiredPickingOrders}.
```

The file does have 11 `@Test`. Three of them do not stub the query — `shouldSkipWhenJobNotActivated` and
`shouldSkipWhenPickTimeoutSystemNotActivated` assert `verify(..., never())`, and
`shouldReturnEarlyWhenNoTenantsConfigured` never mentions it. Six test classes reference the method, not
one: add `ReleaseExpiredPickingOrdersFromUserJobUnitTest` (2 tests),
`ReleaseExpiredPickingOrdersFromUserJobMetricsUnitTest` (4), `AdminTriggerTenantScopeUnitTest`,
`WholeRunSuccessGaugeUnitTest`.

The load-bearing point survives and is worth keeping. Reword to something checkable: "every existing test
of this job across six unit-test classes drives the repository through a mock; none executes the SQL, so
none can fail on it."

### 6. LOW — `productionSql()` lets an unknown named parameter through silently

`ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest.productionSql()`

```java
String positional = sql
    .replace(":timeOut", "?")
    .replace(":pickingType", "?")
    .replace(":state", "?");
```

The positional binding itself is sound: offsets are taken on the original string, `TreeMap` orders them
by appearance, replacement preserves relative order, none of the three names is a prefix of another, and
each is asserted to occur exactly once — so the timeout cannot land in the state slot. That part I tried
to break and could not.

The gap is a *new* parameter. If a later edit adds `:sectionId`, the replace list misses it, the literal
`:sectionId` reaches Postgres, and the failure is a syntax error rather than the message this test is
built to give. One line after the replaces fixes it:

```java
assertThat(positional).as("query gained a named parameter this test does not bind").doesNotContain(":");
```

### 7. LOW — `HELD_TOTES` is a state the lifecycle cannot write

```java
/** Held and expired but in a TOTES_ON_CART section — outside the job's declared scope. */
private static final long HELD_TOTES = 320505L;
```

Only the two rapid-picking paths set `lockedtooperator = true`, so a locked order in a `TOTES_ON_CART`
section is not producible. The row is still worth keeping — it is the only negative row for the
`s.sectionpickingtype = :pickingType` predicate, and without it that predicate is unpinned. Say so in
the javadoc, so a later reader tidying up "impossible fixture rows" does not delete the only thing
holding that predicate down. The AC6 comment already explains the scope decision; it just does not say
the row is synthetic.

### 8. LOW — the exported search goes from always-empty to returning held orders

`PickingorderRepository.java:73`

```java
@RestResource(path = "getPickingOrdersToReleaseExpiredPickingOrders", rel = "getPickingOrdersToReleaseExpiredPickingOrders")
```

`GET /v3/pickingorder/search/getPickingOrdersToReleaseExpiredPickingOrders` is live and read-ungated:
`Pickingorder` sits in `RestConfiguration.SDR_WRITE_WITHDRAWN`, which withdraws write verbs only, and
that field's own javadoc says "Do not read this as 'SDR is gated'". Before the fix the route returned
`[]` to any authenticated caller; after it, it returns held orders including `operator_id`.

Materially this is small: `GET /v3/pickingorder` already exposes the same entity and the same fields, so
no new field becomes readable — only a convenient filter for "which operator is holding what, and for
how long". No UI calls it (checked both v2 UI checkouts; the only `/pickingorder/search/` reference
anywhere is `findByNumber` in `cypress/e2e/wms/smoke/phase2-pick.cy.js:97`).

Worth considering `@RestResource(exported = false)` here, matching what SBDEV-3169 did for
`findByIdForUpdate` and `findAllByIdForUpdate` two methods above — the internal Java caller is
unaffected. That is a scope call, not a defect in this diff; flagging so it is a decision rather than an
oversight.

### 9. LOW — the fix re-arms a 40-second timeout on two live tenants; nothing today satisfies even the corrected predicate

Not a defect in the change, but it belongs on the ticket before merge. Measured 2026-09-02:

| Database | Environment | `PICK_TIME_OUT_SYSTEM_ACTIVATED` | timeout (s) | `lockedtooperator = true` rows |
|---|---|---|---|---|
| `dev_wh01_om1` | wineco dev | true | 40 | 0 |
| `wh01_om1_v2` | wineco UAT | true | 40 | 0 |
| `wh01_hydra_v2` | hydra UAT | false | 40 | 0 |
| `wh01_hydra_v2` | hydra PRD | false | 40 | 0 |
| `wh02_shipitez_v2` | shipitez UAT | false | 40 | — |

Two consequences. First, the job goes live only on the two wineco databases; Hydra, the only v2
production client, has the flag off, so there is no production behaviour change on merge. Second, the
timeout is 40 seconds and the cron is `"40 * * * * *"`, hard-coded, once a minute (
`SchedulingConfiguration.java:57,95`) — so the comment's "per row per minute" is accurate.
`pickinginprogress` is set true only at `MobilePickingService.java:1285`, on the scan-source step, so an
order is locked-but-not-in-progress for the whole window between the package scan and the source scan. A
picker who pauses more than 40 seconds in that window will now have the order released underneath them.
That is the pre-SBDEV-1675 behaviour being restored, not a new bug, but it is the first time in months
this job will move a row, and it is worth watching the `release_expired_picking` job metrics on wineco
after the merge.

Also worth stating plainly in the ticket: with zero locked rows on all four DBs, "the fix releases stuck
orders" cannot be demonstrated against live data right now. The integration test is the evidence, not a
production count.

### 10. LOW — SBDEV-1675's actual defect is still open, and this ticket removes its misplaced guard without restoring it

The two deleted lines were meant for `findByStateAndBoxesPerCartAndSectionId`
(`PickingorderRepository.java:55-64`). That query is still guard-free, and it is not dead: `ReplenishOrderJob.java:279`
calls it with `State.RESERVED` over `TOTES_ON_CART` sections and feeds the result straight to
`PickingOrderMergeService.mergePickingOrders`. `RESERVED` is set together with `operator_id` in
`claimPickingOrderAtomically`, so those orders are already claimed by a picker.
`PickingOrderMergeService` (203 lines) contains **zero** occurrences of "operator" — positive control on
the same file: 29 occurrences of "Pickingorder", so the grep instrument works. The merge job therefore
still merges orders another picker is holding, which is what SBDEV-1675 was filed for.

This diff correctly declines to fix that here. Per the repo's ticket policy it is a sub-T3 finding on an
existing ticket, so it should go as a note on SBDEV-3205 with a recommendation to decide whether
SBDEV-1675 gets reopened — not silently dropped, since after this merge nothing anywhere carries a
reference to the intended guard.

---

## Checked and found fine

- **Predicate set versus the job's intent.** `ReleaseExpiredPickingOrdersFromUserJob.releaseExpiredPickingOrders`
  (`:147-163`) passes `State.PICKED`, `SectionPickingType.RAPID_PICKING`, and `now - timeout`, then
  clears operator and lock per row. `lockedtooperator = true` + `pickinginprogress = false` +
  `modified < timeOut` + `state < PICKED` is the correct still-held-and-idle set. The polarity flip is
  right and the deletion of `lockedtooperator = FALSE` is right.
- **`pickinginprogress = false` survives the correction.** Confirmed still present and pinned by
  `inProgressOrderIsNotSelected`.
- **Positional parameter binding.** Tried to make it bind the wrong slot: offsets computed pre-replace,
  `TreeMap` iteration is ascending, exactly-once assertions on all three names, no name is a prefix of
  another, no `::` casts in the SQL to confuse the `:name` scan. Sound as written; only finding 6's
  future-parameter case is open.
- **Argument-order equivalence.** The job calls `(state, pickingType, timeOut)`; the test binds by
  discovered SQL position, so the two agree without hard-coding either order.
- **Timeout constant.** `TIMEOUT_SECONDS = 40` matches `PICK_TIME_OUT_SYSTEM_TIME_OUT_VALUE` on all five
  DBs queried, so the javadoc's "matches what the job passes" is true.
- **No timezone hazard.** `pickingorder.modified` is `timestamp with time zone`
  (`V2.2.00__base_v2_schema.sql`), so `setTimestamp` from a JVM in any zone compares correctly against
  `now() - interval '10 minutes'`. A `timestamp without time zone` column would have made
  `heldExpiredOrderIsSelected` fail on a non-UTC developer machine; it does not.
- **Fixture schema fidelity.** Every `NOT NULL` column of `client`, `mywms_user`, `itemdata`, `section`,
  `pickingorder` and `pickingorder_position` is supplied. `SEEDED_ITEMUNIT = 0` / `SEEDED_LOCATION = 0`
  match rows inserted by `V2.2.00__base_v2_schema.sql` and follow the sibling's convention exactly.
- **State constants.** `PROCESSABLE 300 / RESERVED 400 / STARTED 500 / PICKED 600`. `HELD_PICKED` at 600
  is excluded by `state < 600`; `RESERVED_NOT_LOCKED` at 400 is excluded only by `lockedtooperator`,
  which is what makes that predicate observable. Both rows do what their names say.
- **`RESERVED_NOT_LOCKED` is a real lifecycle state**, not a synthetic one: `claimPickingOrderAtomically`
  (`:372-386`) sets operator + RESERVED without the lock, and four release paths
  (`MobilePickingService:411, 1312, 1321, 1392, 1400`) clear the lock while leaving `operator_id` set.
- **`ALREADY_RELEASED` is a real state** — `releasePickingOrder(PickingorderPosition)` at `:1363-1365`
  clears all three fields and leaves `state` at STARTED.
- **No flakiness in the time fixture.** `HELD_FRESH` seeds `modified = now()` against a 40-second cutoff;
  the margin is not tight enough to race.
- **`DISTINCT po.*`** still collapses the one-row-per-position fan-out from the
  `pickingorder_position` join; each fixture order has exactly one position, so the exactness assertion
  is not accidentally passing on de-duplication.
- **Naming and lane.** `*IntegrationTest` is correct and required — surefire excludes it, failsafe's
  `<includes>` lists it, and a `*IT` name would run in neither lane (`pom.xml`, SBDEV-3091 comment). The
  javadoc's run instructions match the pom.
- **Style consistency with the sibling.** Same package, same raw Testcontainers + Flyway + JDBC harness,
  same reflection-off-`@Query` technique, same seeded-id convention, same javadoc structure as
  `PickingStartedGuardScalarSubqueryIntegrationTest`. Nothing to flag.
- **No other test pins this query's SQL text**, so nothing breaks elsewhere; the five other classes
  referencing the method all mock it.
- **Comment claims that do check out:** "unsatisfiable, so the job selected nothing on every run" (true —
  `lockedtooperator = true AND lockedtooperator = FALSE`); "From SBDEV-1675 (`326b20dc`) until this fix"
  (true, verified by `git log -L`); the warning against deleting only the contradictory line (true);
  "per row per minute" (true, cron is `40 * * * * *`).
