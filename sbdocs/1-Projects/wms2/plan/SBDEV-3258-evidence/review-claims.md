# SBDEV-3258 — independent fact-check of the branch's commit claims

- Worktree: `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3258`
- Branch: `bugfix/SBDEV-3258-pg-lane-residue`, HEAD `d6e17668`
- Reviewed: 2026-09-08. No files edited, no maven run.
- Topology check: `git rev-list --left-right --count origin/develop...HEAD` → `6  10`.
  The branch is 10 ahead **and 6 behind** current `origin/develop` (`41c3f7d0`). Merge base is
  `3530d87b` — the commit the merge commit pulled in. All "no src/main change" checks below use the
  three-dot form against that merge base, not the two-dot form (the two-dot diff shows six commits'
  worth of `origin/develop` work as spurious deletions).

**Headline.** The quantitative claims hold up again — every seeded-id constant, every schema fact,
every line citation, the `5407` provenance and the final suite numbers survive re-derivation. Nine
claims fail, and eight of the nine are the shape the brief predicted: a census or a completeness
word asserted without an instrument. Two of them (`@NotNull` on `Customerorder`, "location has no
seeded row") are shipped as javadoc inside `PgLaneFixtures` — the file whose stated purpose is to
stop the next author rediscovering these facts — so they will be read as authority.

---

## FALSE

### F1 — "grepping `@NotNull` finds only 6 and misses clientId, boxtypeId, orderbatchId"

> "The 8 violated fields came from the RUNTIME violation list. Grepping `@NotNull` on Customerorder
> finds only 6 and silently misses clientId, boxtypeId and orderbatchId - precisely the three that
> are ALSO foreign keys." — commit `6c7ae589`
>
> "⚠ **Do not derive the required-field list by grepping `@NotNull`.** On `Customerorder` that finds
> 6 and silently misses `clientId`, `boxtypeId` and `orderbatchId`" — `PgLaneFixtures.java:39-42`
> (shipped javadoc)

**FALSE.** `Customerorder` carries **nine** `@NotNull` annotations, and all three of the allegedly
missed fields are among them.

```
$ grep -c "@NotNull" src/main/java/net/aim_ai/wms/model/Customerorder.java
9
$ awk '/@NotNull/{f=1} f && /private /{print NR": "$0; f=0}' src/main/java/net/aim_ai/wms/model/Customerorder.java
15:     private String externalnumber;
18:     private Integer prio;
20:     private Integer state;
27:     private Long clientId;        <-- claimed missing
30:     private Long orderbatchId;    <-- claimed missing
37:     private Boolean pickingconfirmationsent;
39:     private Boolean markedforcancellation;
48:     private Long boxtypeId;       <-- claimed missing
53:     private Boolean markasvisited;
$ grep -n -B4 -E "clientId;|boxtypeId;|orderbatchId;" src/main/java/net/aim_ai/wms/model/Customerorder.java
25-    @NotNull
26-    @Column(name = "client_id")
27:    private Long clientId;
28-    @NotNull
29-    @Column(name = "orderbatch_id")
30:    private Long orderbatchId;
46-    @NotNull
47-    @Column(name = "boxtype_id")
48:    private Long boxtypeId;
```

Not a stale-file artifact: `Customerorder.java` is untouched on this branch
(`git diff --stat 3530d87b..HEAD -- src/main` → empty) and its last commit is `4a670fce`, long
before this ticket. The import is `jakarta.validation.constraints.NotNull` (line 6) — one class,
one annotation, no second `Customerorder.java` in the tree (`git ls-files "*Customerorder.java"`
→ one path).

The moral drawn from the claim ("a grep-derived fixture would have satisfied bean validation and
then failed at commit") is the exact inverse of the evidence: a `@NotNull` grep on this entity
yields a **superset** of what the fixture sets. What the grep genuinely cannot tell you is which of
those columns are also FKs — a true and useful point, attached to a false census.

### F2 — "move() throws BusinessException from nine distinct guards"

> "move() failed at a GUARD before writing, and my type-only assertion PASSED on that. move() throws
> BusinessException from nine distinct guards, so asserting the type alone is not a test."
> — commit `c2d6e605`; repeated verbatim at `FixLocationAssignmentServiceIT.java:196` and again in
> the assertion description at `:214` ("not one of move()'s nine pre-write guards").

**FALSE — there are eight.** `move()` spans lines 112–182 of
`src/main/java/net/aim_ai/wms/service/FixLocationAssignmentService.java`.

```
$ awk 'NR>=112 && NR<=182 && /throw new BusinessException/{print NR": "substr($0,1,80)}' \
    src/main/java/net/aim_ai/wms/service/FixLocationAssignmentService.java
124:  Destination is not a flowbin!
127:  Destination has already a fixed assignment!
131:  Destination has already a unit load!
143:  ReplenishmentOrder=... is currently in processing!
149:  No unit load on assigned location.
153:  Too many unit loads on assigned location.
158:  Assigned virtual container has no stock unit.
161:  Assigned virtual container has more than one stock unit.
$ awk 'NR>=112 && NR<=182 && /throw new BusinessException/' ... | wc -l
8
```

The six `orElseThrow` sites in the same range do not close the gap:
`EntityNotFoundException extends RuntimeException`
(`src/main/java/net/aim_ai/wms/exceptions/EntityNotFoundException.java:7`), not `BusinessException`.
Counting them would give 14, not 9.

The argument the number supports is unaffected — eight is still plenty to make a type-only assertion
worthless, and the sentinel design that replaced it is sound. But the figure is stated three times,
twice in shipped test source, and is the kind of number a later reader quotes.

### F3 — "the former parent still passes (15 tests across its five remaining @Nested groups)"

> "The former parent still passes (15 tests across its five remaining @Nested groups) — checked,
> because removing 113 lines from the middle of a file compiles cleanly and can quietly break a
> sibling." — commit `429b7da9`

**FALSE on both numbers.** 13 tests, 8 nested groups — at HEAD and at the commit that made the claim.

```
$ F=src/test/java/net/aim_ai/wms/integration/repository/ClientRepositoryIntegrationTest.java
$ grep -c "@Nested" $F ; grep -c "^    *@Test" $F
8
13
$ git show 429b7da9:$F | grep -c "@Nested" ; git show 429b7da9:$F | grep -cE "^\s+@Test"
8
13
```

Confirmed independently by the executing instrument — `post.log` lists eight nested groups summing
to 13 tests (`BasicCrudOperations` 3, `FindByName` 2, `FindByClNr` 2, `FindByClNrIgnoreCase` 1,
`FindByClientId` 2, `FindAllByOrderByName` 1, `GetDetailView` 1, `UpdatePrinterToNullByPrinterId` 1).
The underlying assertion — the sibling was not broken by the extraction — is **true**; only the
count attached to it is wrong. Note this is the one claim in the commit explicitly labelled
"checked".

### F4 — "putawaylocation_id → location has none [no seeded row]"

> "Itemdata needed three FKs: client_id and handlingunit_id -> itemunit both have seeded rows (0);
> **putawaylocation_id -> location has none**, so the caller passes a persisted
> PgLaneFixtures.location(). That is the third FK-to-an-unseeded-table on this lane after
> customerorder_batch." — commit `5f7d044a`
>
> "{@code putawaylocation_id} -> {@code location}, **which has no seeded row** and so must be
> supplied by the caller" — `PgLaneFixtures.java:145-147` (shipped javadoc)

**FALSE.** `V2.2.00__base_v2_schema.sql` seeds **35** `location` rows, ids 0–34.

```
$ F=src/main/resources/db/migration/V2.2.00__base_v2_schema.sql
$ grep -n -i "insert into public.location VALUES" $F
2460:INSERT INTO public.location VALUES
$ awk 'NR>=2461{ if ($0 ~ /^\t\(/) {n++; last=$0}; if ($0 ~ /;$/) {print "rows="n; print "last="last; exit} }' $F
rows=35
last=	(34, ..., 'TransferLane06', 0, 6, NULL, 7, false, true, false, false, false);
```

The branch contradicts itself on this within one hour: commit `429b7da9` states "**putawaylocation_id
0 a seeded system location**; both are real rows, checked", and `PgLaneFixtures` itself declares
`SEEDED_LOCATION_ID = 0L` with the javadoc "A seeded system `location` row". Both of those are
correct; F4 is the wrong half of the pair, and it is the half that sits on the method a future
author will call. (Ids 0–3 are the `Nirwana`/`Clearing`/`Spawn`/`CycleCount` system rows and 29–34
are `TransferLane01`–`06`.)

The *practical* instruction — have the caller pass a persisted `location()` — is still fine, and in
`FixLocationAssignmentServiceIT` it is required for an unrelated reason (the itemdata must point at
the same location the fixture later moves stock off). Only the justification is false.

### F5 — "The base schema seeds ids 0..2" (location)

> "A seeded system {@code location} row. **The base schema seeds ids 0..2**" — `PgLaneFixtures.java:47`

**FALSE** — 0..34, per the F4 command output. `SEEDED_LOCATION_ID = 0L` is itself valid.

### F6 — "location_area and location_type are seeded 0..3"

> "areaId/typeId 1 DO exist (location_area and location_type are seeded 0..3)" — commit `6c7ae589`
>
> "{@code location_area} / {@code location_type} — seeded {@code 0..3}; 1 is safe." — `PgLaneFixtures.java:31`

**FALSE** — both are seeded **0..7**.

```
$ sed -n '2502,2510p' $F   # location_area: 0 Default,1 users,2 Storage and Replenish, ... 7 Deep Storage
$ sed -n '2544,2552p' $F   # location_type: 0 System,1 NoRestriction,2 flowbin, ... 7 cases and pallets
```

The operative half — "1 is safe" — is **VERIFIED**. The range is understated by four rows in each
table, in a comment whose whole purpose is to be the reference for the next fixture.

### F7 — skip enumeration in AC-8 mis-splits by one, and omits the surefire skip

> "The 41 remaining skips are accounted for ... ReplenishorderRepositoryIntegrationTest 11,
> ReturnAdviceAutoReceiveIntegrationTest 6, the Message/Printer/Location/Cyclecount native-SQL
> groups 16 (SBDEV-3249's boolean-literal H2 incompatibility), KeycloakServiceIntegrationTest 3,
> BillofladingServiceFinishTransferPerformanceIT 2 ... and three singletons." — commit `1c74c0fa`

**Total right, split wrong.** Against `final2.log` (the pre-merge run the commit is quoting,
`358/0F/0E/40S`), the native-SQL groups are **15**, not 16:

```
Message   $GetDetailViewByKeyword 2 + $ArchiveMessages 1 + $FindAllFromDaysPeriod 2 = 5
Printer   $FindAllTypeAndProcessdefaultTrue 2 + $FindByTypeAndProcessdefaultTrue 2   = 4
Location  $NativeSqlQueries 3
Cyclecount $NativeSqlWithJoins 3
                                                                              total = 15
```

11 + 6 + 15 + 3 + 2 + 3 = **40**, which is exactly the printed failsafe figure. The 41st skip is
`TenantPoolEndpointSecurityTest` 1, in the **surefire** lane (`TODO(SBDEV-2608)`), and it is not in
the enumeration — it was absorbed into the native-SQL count. The claim "accounted for and all sit
OUTSIDE this ticket's scope" survives; the arithmetic does not.

### F8 — stale "STILL DISABLED" prose left standing in the class the ticket un-disabled

Commit `c2d6e605` lists as defect #5 "the class-level `@Disabled`, which I left on after
implementing AC-9 ... a green-looking line that ran nothing, in the ticket whose whole purpose is
deleting those." The annotation is indeed gone. The **paragraph asserting it** is not:

`src/test/java/net/aim_ai/wms/service/FixLocationAssignmentServiceIT.java:48-57`

> `<p><b>GATE STATUS — STILL DISABLED, BUT THE HARNESS IS NOT WHY.</b> ... What holds it back now is
> a result, not an environment — see the {@code @Disabled} reason below, and <b>SBDEV-3258</b>, which
> owns resolving it. **Read the marker, not this paragraph**, for the current blocker`

There is no marker below to read. `post.log` shows the class running 2/0/0/0. Two more orphan
javadoc blocks in the same file still assert falsehoods the commit itself refutes:

- `:82-93` — "This MUST fail today because move() has no `@Transactional(value="tenantTransactionManager")`"
  (it has carried exactly that, with `rollbackFor`, since before the ticket — verified at
  `FixLocationAssignmentService.java:111`);
- `:95-104` — "This fails today because the recordRelocation call site is not yet wired into move()"
  (it is wired, `FixLocationAssignmentService.java:175`).

The in-body comments correct both, so a reader who reaches line 120 is told the truth. A reader who
stops at the class javadoc is told this class is disabled. This is the AC-6 residue pattern
reproduced inside the AC-6 ticket.

### F9 — "Customerorder needs 8 columns at persist time"

> "the fixture built a Customerorder with state only, and Customerorder needs 8 columns at persist
> time, three of them foreign keys" — commit `0ba2c389`

**Imprecise.** `Customerorder` needs **9** — see F1. The runtime named 8 because `state` was already
set by the pre-existing fixture, which is what commit `6c7ae589` says correctly ("Customerorder: 8
violated **properties** at persist time"). `PgLaneFixtures.order()` sets all nine. The "three of
them foreign keys" half is correct (`client_id`, `boxtype_id`, `orderbatch_id`).

---

## VERIFIED

### V1 — the failsafe `<excludes>` is empty and all three classes run

`pom.xml:764` is `<excludes/>`, under a 19-line comment (`:745-763`) naming the three drained
entries. The failsafe `<includes>` is `**/*IT.java` (`:743`); all three class names end in `IT`.
No `<groups>`/`<excludedGroups>` anywhere in `pom.xml`, so `MessageCleanupBatchServiceIT`'s
`@Tag("postgres")` filters nothing.

None of the three carries `@Disabled`, an `assume*`, or a `@DisabledIf`:

```
$ for c in WarehouseStockReportServiceStreamIT MessageCleanupBatchServiceIT ParcelMonitorViewServiceConcurrencyIT; do
    git grep -n -E "Disabled|assum|Assum" -- "$(git ls-files "*/$c.java")"; done
(no output)
```

Positive control for the instrument: `git grep -l "@Disabled" -- src/test | wc -l` → **43**.
`BasePostgresIntegrationTest` itself has no `@Disabled` annotation and no assumption (its one
`@Disabled` hit is javadoc at `:34`).

Executing confirmation, from `post.log`:

```
Tests run: 2, Failures: 0, Errors: 0, Skipped: 0 -- WarehouseStockReportServiceStreamIT
Tests run: 1, Failures: 0, Errors: 0, Skipped: 0 -- MessageCleanupBatchServiceIT
Tests run: 1, Failures: 0, Errors: 0, Skipped: 0 -- ParcelMonitorViewServiceConcurrencyIT
```

### V2 — AC-5: zero real `System.setProperty` calls in `src/test`

```
$ git grep -n "System.setProperty" -- src/test
common/base/BasePostgresIntegrationTest.java:67:     * <p>{@code @DynamicPropertySource} rather than {@code System.setProperty}, ...
common/base/BaseRollbackIntegrationTest.java:22: * @TestPropertySource (scoped to this context only — no global System.setProperty
common/extension/AppPostgresDBSetupExtension.java:62:     * {@code System.setProperty("spring.datasource.url", ...)} and SBDEV-3239 extended ...
unit/config/LoggerAttributionUnitTest.java:105:     * that still armed 14 {@code System.setProperty} calls — so the hazard is gone. ...
```

All four are comment lines (`*` continuation). A widened `setProperty` scan adds only three more
comment hits (`CustomerOrderControllerIntegrationTest:170`, `TenantProbeStallTest:163` and `:434`,
the latter two about `Properties.setProperty`, a different API). **Zero real calls.** Positive
control: `git grep -c "System.setProperty" -- src/main` → `StartApplication.java:1`, so the pattern
does match live code when live code exists.

One nuance on the commit's own framing: it says "`git grep -c` reports four files. **Three** of them
... have ZERO real calls." All **four** do — `LoggerAttributionUnitTest:105` is javadoc too. The
conclusion is right; the count in the explanation implies a fourth file that has one.

`H2TestExtension`'s deletion checks out: at `fddae680^` the file contained exactly **14**
`System.setProperty` calls, and its only two references in `src` were javadoc mentions in
`LoggerAttributionUnitTest` (`:103`, `:238`) — no `@ExtendWith` anywhere.

### V3 — no `TODO(SBDEV-3258)`; no live marker cites SBDEV-3239 / 2217 / 2099

```
$ git grep -n "TODO(SBDEV-3258)" -- src ; echo exit=$?
exit=1
$ git grep -c "TODO(SBDEV-2608)" -- src        # positive control
landlord/config/TenantPoolEndpointSecurityTest.java:1
```

Every live `@Disabled` annotation in `src` (23 hits, comment lines filtered) cites SBDEV-3248,
SBDEV-2216, SBDEV-3249, SBDEV-2608 or SBDEV-3240, or an H2-incompatibility reason. **None** cites
SBDEV-3239, SBDEV-2217 or SBDEV-2099.

Two residues survive that a strict reading of the claim would catch:

- `TransferLaneLeakOnCancelIT.java:26-30` still contains the token `TODO SBDEV-2217` **and** the
  now-false sentence "The Postgres lane currently cannot boot a full Spring context". The next
  clause ("The harness is fixed as of SBDEV-3239") and a new SBDEV-3258 paragraph below correct it,
  and commit `6c7ae589` explicitly cleared the *other two* spellings at `:63` and `:99` — this is a
  **third** spelling, in the class javadoc, left in place. Given that commit's own point was "spelled
  two DIFFERENT ways, so a single string-replace would have fixed one and left the other", this is
  the same trap one level up.
- `src/main/resources/db/migration/V2.2.19__seed_web_view_function_grants.sql:55` — "(the
  Testcontainers IT harness is down, SBDEV-2217)". Out of this branch's reach (no `src/main` change),
  but it is a stale claim citing a closed ticket, in a migration file.

### V4 — the 5407 figure is sourced, not invented

```
$ git grep -n "5407" -- src
integration/repository/UserGroupUserRoleDeleteIT.java:23   (this ticket, citing it)
unit/repo/UserGroupQueryContractUnitTest.java:25           <-- the source
unit/service/UserGroupServiceTransactionBoundaryTest.java:303
$ git log --oneline -1 -S"5407" -- src/test/java/net/aim_ai/wms/unit/repo/UserGroupQueryContractUnitTest.java
060d4ed8 fix(review): SBDEV-3012 act on three independent review lanes
$ git merge-base --is-ancestor 060d4ed8 origin/develop && echo ancestor
ancestor
```

`UserGroupQueryContractUnitTest:23-29` records it: an independent review lane mutated
`deleteByGroupId` from `r.id.grouplistId` to `r.id.rolelistId` and it "SURVIVED the entire 5407-test
suite". Pre-existing repository javadoc from SBDEV-3012, on `origin/develop`. Correctly quoted.

The new test's design does kill that mutant on paper: `deleteByGroupId(G_TARGET=900100)` under the
mutant filters `rolelist_id = 900100`, which is `R_DECOY` (`UserGroupUserRoleDeleteIT.java:50`,
`R_DECOY = G_TARGET`), deleting the `(G_OTHER, R_DECOY)` row instead of `(G_TARGET, R_PLAIN)`. Both
delete exactly one row, so `assertThat(deleted).isEqualTo(1)` (`:76`) genuinely cannot separate them
and the two `linkExists` assertions (`:78-84`) can. The query text is as described:
`UserGroupUserRoleRepository.java:66` — `@Query("DELETE FROM UserGroupUserRole r WHERE r.id.grouplistId = :groupId")`.
`TestDataFactory.java:27` is `new AtomicLong(1000)`, so the reserved 900_000+ range is above it as
claimed. The mutation run itself I cannot re-execute (no maven).

### V5 — every seeded-id constant, verified row by row against `V2.2.00__base_v2_schema.sql`

| Constant | Value | Schema evidence | Verdict |
|---|---|---|---|
| `SYSTEM_CLIENT_ID` | 0 | `:2377-2378` — one row: `(0, ..., 'System-Client', 'System', ...)`, statement terminates on the next line | ✓ exactly one client, id 0 |
| `SEEDED_BOXTYPE_ID` | 0 | `:2312-2313` — `(0, ..., '12PK750C', ...)`, seeded 0..n | ✓ |
| `SEEDED_AREA_ID` | 1 | `:2502-2510` — `(1, ..., 'users', ...)` | ✓ (range 0..7, see F6) |
| `SEEDED_TYPE_ID` | 1 | `:2544-2552` — `(1, ..., 'NoRestriction', ...)` | ✓ (range 0..7, see F6) |
| `FLOWBIN_LOCATION_TYPE_ID` | 2 | `:2547` — `(2, NULL, ts, 0, ts, 0, NULL, NULL, 'flowbin', NULL, NULL)`; `sltname` is the 9th column per the DDL | ✓ |
| `SEEDED_ITEMUNIT_ID` | 0 | `:2451-2453` — `(0, ..., 'BOTTLE', 'BOTTLE', NULL)`, `(1, ..., 'pcs', 'PIECE', NULL)` | ✓ 0=BOTTLE, 1=PIECE |
| `SEEDED_UNITLOAD_TYPE_ID` | 0 | `:3152-3153` — `(0, ..., 'Default', ...)` | ✓ |
| `FLOWBIN_PERMITTED_UNITLOAD_TYPE_ID` | 1 | `:3154` — `(1, ..., 'PickLocation', ...)`; matched by the constraint row below | ✓ |
| `SEEDED_LOCATION_ID` | 0 | `:2461` — `(0, ..., 'Nirwana', ...)` | ✓ (but see F5 on the range) |

**`customerorder_batch` has ZERO seeded rows — VERIFIED.**
`grep -i "insert into (public\.)?customerorder_batch"` → no match. Positive control that the
instrument and the table both exist: the table is created at `:791`, has a PK at `:3235`, a unique
constraint at `:3688`, and is joined by three views (`:1680`, `:1772`, `:2034`) — only the
`-- Data for Name: customerorder_batch` header at `:2388` has no `INSERT` under it.

**`location_constraint` seeds `('only boxes allowed', storagelocationtype_id=2, unitloadtype_id=1)`
— VERIFIED exactly.** DDL column order is
`(id, additionalcontent, created, entity_lock, modified, version, name, number, storagelocationtype_id, unitloadtype_id)`;
row at `:2519` is
`(1, NULL, ts, 0, ts, 0, 'only boxes allowed', 'ULC000002', 2, 1)`. So the last two positional values
land on exactly the two columns named. The corollary in the javadoc — "location types with NO
constraint row (e.g. 1) permit anything" — is consistent with the eight seeded rows, which cover
storagelocationtype 2,3,4,5,6,7 only.

### V6 — `entity_lock` is nullable and the product dereferences it

Nullable: `CREATE TABLE public.location (... entity_lock integer, ...)` — `V2.2.00:963`, no
`NOT NULL`. `Location.java` has 12 `@NotNull` fields and `entityLock` is not among them, matching
`PgLaneFixtures.location()`'s claim of "all 12".

Dereference at the cited line — `UnitloadBusinessService.java:184`, inside
`transferUnitLoadToLocation` (declared `:154`), matching the javadoc's method attribution:

```java
184:  if (!ignoreLock && destinationLocation.getEntityLock() != BusinessObjectLockState.NOT_LOCKED) {
```

`WmsConstants.java:1365` — `public static final int NOT_LOCKED = 0;`. `Integer != int` forces
unboxing, so a null `entity_lock` NPEs. **The hazard is real and the line number is right.** The
wording is not: there is no `.intValue()` call there. The two sibling sites that *are* null-safe
(`:527`, `:761`, both `Integer.valueOf(CONST).equals(...)`) make the inconsistency at `:184` look
deliberate-by-omission rather than universal, which is worth knowing for anyone tempted to
generalise the fixture rule.

### V7 — BEGINNING/ENDING are string literals at `:360` and `:426`

```
$ grep -n -E "'BEGINNING'|'ENDING'" src/main/resources/db/migration/V2.2.00__base_v2_schema.sql
360:   ''BEGINNING''       AS transaction_name,
426:   ''ENDING''           AS transaction_name,
```

Both inside the `transaction_detail(...)` plpgsql body (function declared `:96`), and those are the
only two occurrences in the file. **Line numbers and literal-ness: VERIFIED.**

"**always** emits ... not data-dependent" needs one qualifier. Both bookends are `UNION` branches
whose source is `FROM stock_history($3) AS sh INNER JOIN itemdata i ON sh.item_id = i.id AND
i.item_nr LIKE $2 INNER JOIN client c ON i.client_id = c.id AND c.cl_nr = $1` (`:376-381`,
`:442-447`). So the *rows* are conditional on `stock_history` yielding a row for that client+sku.
That resolves in the claim's favour here, and for a reason the branch itself established and I
re-derived: `stock_view` (real definition, `:4685`) is
`FROM itemdata i LEFT JOIN stockunit LEFT JOIN client LEFT JOIN unitload GROUP BY i.id, i.item_nr, c.id, c.cl_nr`
— all LEFT, grouped per item+client, so **one `itemdata` row yields exactly one view row**. The test
seeds an `itemdata` row for its client and sku, so both bookends must appear and `isEmpty()` could
not have passed *in that test*. The general sentence "transaction_detail always emits" is still
over-broad — a query for a sku with no `itemdata` returns nothing at all.

(This also independently confirms commit `5f7d044a`'s reasoning for the 4b repair: "the joins are
all LEFT and the GROUP BY is per item+client, so ONE itemdata row yields exactly one view row".)

### V8 — `BusinessException` is checked, and Spring's default rollback excludes checked exceptions

`src/main/java/net/aim_ai/wms/exceptions/BusinessException.java:14` —
`public class BusinessException extends Exception {` → checked. Spring's declarative transaction
default (`DefaultTransactionAttribute.rollbackOn`) rolls back on `RuntimeException` and `Error`
only, so `rollbackFor` is load-bearing exactly as the commit argues. The pin it describes exists and
matches the product: `FixLocationAssignmentService.java:111` —
`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`,
asserted at `FixLocationAssignmentServiceIT.java:220-233` on all three axes (non-null, qualifier,
`rollbackFor` contains `BusinessException`).

### V9 — the final suite numbers, in `post.log`

```
$ grep -n -A3 "^\[INFO\] Results:" post.log
68227:[WARNING] Tests run: 6345, Failures: 0, Errors: 0, Skipped: 1     <- surefire
75830:[WARNING] Tests run: 358,  Failures: 0, Errors: 0, Skipped: 37    <- failsafe
75839:[INFO] BUILD SUCCESS
```

**Final surefire 6345/0/0/1 and failsafe 358/0/0/37: VERIFIED, build green.**

On the apparent mismatch with commit `1c74c0fa` ("failsafe 358/0F/0E/40S"): that commit is not
wrong, it is quoting an earlier run. `final2.log` (12:37, pre-merge; the commit is 12:38) reads
`358/0F/0E/40S`. `post.log` is 12:47, after the 12:40 merge of SBDEV-3257/3248-4b, which un-skipped
three `ReturnAdviceAutoReceiveIntegrationTest` cases (6 → 3) while leaving the run count at 358.
The commit's numbers are accurate as of the commit; `post.log`'s are accurate as of HEAD. Worth
recording, because a reader comparing the commit to the log will otherwise think one of them lies.

### V10 — SBDEV-3257's correction on `PutawayResolverContextLoadTest` is the accurate version

`src/test/java/net/aim_ai/wms/smoke/PutawayResolverContextLoadTest.java:50` —
`class PutawayResolverContextLoadTest extends BaseRollbackIntegrationTest`. That base is
`@SpringBootTest(classes = StartApplication.class)` (`:29`), `@ActiveProfiles("integration")`
(`:30`), and its own `@TestPropertySource` supplies
`landlord.datasource.jdbc-url=jdbc:h2:mem:rollback_landlord;...` (`:40`). So the missing-landlord-URL
defect never applied, exactly as the merge commit concedes. The class name ends in `…ContextLoadTest`,
and surefire excludes only `**/*IntegrationTest.java` and `**/*E2ETest.java` (`pom.xml:565-566`), so
it has always been in the unit lane. `post.log` shows it running: `Tests run: 1, Failures: 0,
Errors: 0, Skipped: 0`. **Taking THEIRS was correct**, and the merge commit's self-correction
("'SBDEV-3239 fixed it' was the wrong reason for the right conclusion") is itself accurate.

`OrderReleaseSectionQueryIT` likewise runs — `post.log`: `$DashboardBucket` 1, `$ReleaseQuery` 3.

---

## Additional findings (not claims — things I hit while checking)

### A1 — the eight summary assertions may still be vacuous, and nothing in the test would say so

Commit `429b7da9`'s stated payoff is: "fixing isEmpty() is what let the EIGHT summary assertions run
at all ... They are the actual product guarantee here, they now run, and they pass."

In `ClientRepositoryTransactionDetailIT.java` both new assertions pass on an **empty** result:

```java
assertThat(detailRows).allSatisfy(row -> ...);          // AssertJ allSatisfy: vacuously true on []
for (TransactionSummaryView row : summary) { ...8 asserts... }   // body never runs on []
```

There is no `isNotEmpty()` / `hasSizeGreaterThan(0)` on either collection. The reasoning in V7
suggests `summary` is in fact non-empty for this fixture, so the assertions probably do execute —
but the test cannot distinguish "eight assertions passed" from "eight assertions were skipped", and
it is the class replacing a stub that failed in precisely that way ("asserted count==0 on an
unseeded table — true unconditionally, so it passed VACUOUSLY"). One `assertThat(summary).isNotEmpty()`
before the loop, and one `assertThat(detailRows).isNotEmpty()`, would convert the claim from
inference to evidence. Cheap, and the ticket's own thesis argues for it.

### A2 — five unused imports in the extracted class

`ClientRepositoryTransactionDetailIT.java` imports `org.junit.jupiter.api.Disabled`,
`org.junit.jupiter.api.Nested`, `org.junit.jupiter.api.BeforeEach`,
`net.aim_ai.wms.repo.projection.ClientDetailView` and `java.util.Optional`; none appears in the body
(the only `@Nested` string in the file is a `{@code @Nested}` javadoc mention at `:24`). Extraction
residue — compiles fine, but `Disabled` and `Nested` in particular will read as "this used to be a
disabled nested class" to the next person.

### A3 — two `TestDataFactory` classes

`git ls-files "*TestDataFactory*"` → `common/fixtures/TestDataFactory.java` and
`unit/fixtures/TestDataFactory.java`. `PgLaneFixtures`' javadoc ("Why this is not
{@link TestDataFactory}") resolves against the one in its own package; the reasoning about
`nextId()`/`AtomicLong(1000)` was verified against `common/fixtures`. Not a defect, but the
unqualified name in the javadoc is ambiguous.

---

## Scope not covered

- Every "N run / 0 failures" and every mutation kill (M1, M3, the grouplistId mutant) is
  **UNVERIFIABLE** here — re-running them needs maven, which was excluded. Where `post.log` carries
  the class, I used it; the mutation runs leave no artifact I could re-read.
- The AC-8 **baseline** (`develop @ 743b03e0`: surefire `6345/0/0/3`, failsafe `353/0/0/46`) is
  **UNVERIFIABLE**. No log in the scratchpad matches either figure — I scanned all 47 `*.log` files
  for a `Results:` total; the closest are `baseline.log` (`6330/0/0/6`, `352/0/0/70`) and
  `remeasure.log` (`6348/0/0/6`, `354/0/0/70`), neither of which is it. The **delta** direction
  (skips down, failsafe tests up) is consistent with the drained exclusion list and the three
  un-stubbed classes, but the specific baseline pair is unsupported by any artifact on disk.
- `mvn` was not run for any part of this review, per instruction.
