---
ticket: SBDEV-3012
lane: transaction and persistence correctness
pr: wms2-api #182
reviewed_head: 51d8c09
reviewer: tx-lane (independent review lane)
date: 2026-08-21
verdict: SHIP WITH FIXES
---

# SBDEV-3012 — review lane: transaction and persistence correctness

**VERDICT: SHIP WITH FIXES** — no High findings. The transaction design is correct: the manager
qualifier, propagation, readOnly, statement order, set difference, composite key order, cascade
completeness and JPQL field selection all check out, and most of them are behaviourally pinned. The
three Medium findings are a **false premise in the javadoc that is false specifically on production**,
and two **coverage gaps where a wrong mutant survives the whole suite**. None of them is a defect in
the shipped behaviour; all three are cheap to close and all three are the kind of thing that makes the
*next* edit dangerous.

Scope: transaction and persistence correctness only. Authorization, HTTP contracts and general
test-adequacy are other lanes' — where I touch them (L-3, L-5) it is because a persistence fact drove
the observation, and I say so.

## Evidence base

- Reviewed **`51d8c09`** in an isolated `git worktree` at
  `/tmp/claude-1000/-home-nampark-dev-wms-claude/74e9ade3-54f9-40c9-b7fd-5f0d8ec80cce/scratchpad/tx-lane-3012`,
  **not** the shared ticket worktree. See "Operational note" at the bottom — the shared worktree was
  dirty with another lane's live mutation and my first test run was measuring their mutant, not the PR.
- **Targeted suite on the clean head: 76/76 green.**
- **Full suite on the clean head: `Tests run: 5407, Failures: 2, Errors: 0, Skipped: 67`** — the two
  failures are the known pre-existing `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses`
  and `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate`. **Baseline matches
  develop; this PR introduces no new failures.**
- **10 mutants applied and measured** (table below).
- `pg_constraint` / `pg_indexes` / row counts queried live on **hydra PRD, hydra UAT, hydra DEV2,
  wineco DEV, shipitez nywh UAT** (2026-08-21).

### Mutation results

| # | Mutant | Result |
|---|---|---|
| M1 | `replaceGroupRoles` composite key swapped → `UserGroupUserRoleId(roleId, groupId)` | **killed** (1) `replaceGroupRolesTouchesOnlyTheDifference` |
| M2 | `replaceUserGroups` composite key swapped → `UserGroupUserId(userId, groupId)` | **killed** (2) `…BuildsTheCompositeKeyInDeclaredOrder`, `…TouchesOnlyTheDifference` |
| M3 | `deleteUser` order swapped — user before memberships | **killed** (1) `deleteUserClearsMembershipsFirst` |
| M4 | `deleteGroup` order swapped — group **first** | **SURVIVED** → finding M-2 |
| M5 | `replaceGroupRoles` set difference → clear-then-reinsert | **killed** (2) `…TouchesOnlyTheDifference`, `…IsANoOpWhenNothingChanged` |
| M6 | `deleteByGroupId` JPQL field swapped → `r.id.rolelistId = :groupId` | **SURVIVED** → finding M-3 |
| M7 | `replaceGroupRoles` drops `rollbackFor` (keeps `value=`) | **SURVIVED** → finding L-1 |
| M8 | `replaceUserGroups` + `readOnly = true` | **killed** (1) `replaceUserGroupsTransactionDefinitionIsAWritableRequiredTransaction` |
| M9 | `deleteUser` + `propagation = NOT_SUPPORTED` | **killed** (1) `deleteUserTransactionDefinitionIsAWritableRequiredTransaction` |
| M10 | `deleteGroup` → bare `@Transactional` (landlord binding) | **killed** (3) incl. `deleteGroupTransactionDefinitionIsAWritableRequiredTransaction` |

M8/M9/M10 matter most: that is exactly the mutant class that was **measured 100% green on SBDEV-3005**
before the `TransactionDefinition`-capture assertions existed. It does not survive here. The
transaction boundary is genuinely pinned, not merely annotated.

---

## Findings

### M-1 · Medium · The javadoc's load-bearing premise is false on production

`v2/wms2-api/src/main/java/net/aim_ai/wms/service/UserGroupService.java:130-134` and
`v2/wms2-api/src/main/java/net/aim_ai/wms/service/UserService.java:200-204` both assert the join table
carries a UNIQUE composite index, and that assertion is the stated reason for the set difference.
Measured 2026-08-21, count of UNIQUE indexes:

| DB | `mywms_group_mywms_role` | `mywms_group_mywms_user` |
|---|---|---|
| **hydra PRD** | **0** | **0** |
| **shipitez nywh UAT** | **0** | **0** |
| hydra UAT | 1 | 1 |
| hydra DEV2 | 1 | 1 |
| wineco DEV | 1 | 1 |

The root cause is in the Flyway baseline:
`v2/wms2-api/src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:4520` and `:4541` create
`mywms_group_mywms_role_grouplist_id_rolelist_id_index` and
`mywms_group_mywms_user_grouplist_id_userlist_id_index` as **plain `CREATE INDEX`**. Neither table has
a PK or unique constraint in `pg_constraint` either. The unique variants on the UAT/DEV boxes are
named `…_uindex` — a different object, created out-of-band, so **no Flyway-provisioned tenant has
uniqueness**. (Compare `mywms_role_mywms_function`, which *does* carry
`mywms_role_mywms_function_pk (rolelist_id, functionlist_id)` — hence the divergence from SBDEV-3011's
tables.)

**The conclusion still holds — the set difference is the right shape, arguably more so.** Without
uniqueness a clear-then-reinsert would not fail loudly with a duplicate key; it would *silently create
duplicate rows*. So the fix is correct and M5 confirms it is required. What is wrong is the reason,
on the two DBs where being wrong costs the most.

Failure scenario this actually enables today, on prd: two concurrent `POST /saveGroupRoles` for the
same group both adding role R. Under READ COMMITTED both `findByGrouplistId` calls return R absent,
both insert, and nothing rejects the second — the transaction added by this PR does not serialize
them (no lock, no unique index). Result: a duplicate `(grouplist_id, rolelist_id)` row. Once one
exists, `existing` at `UserGroupService.java:157-159` is a `HashMap` keyed on the role id and collapses
the duplicates to a single entry, so `replaceGroupRoles` can no longer reason about the row count.

**Fix (pick one, both cheap):**
1. Correct both javadocs to say uniqueness is **not** guaranteed, and give the real reason (avoid
   gratuitous churn on the dominant edit path; avoid creating duplicates where nothing rejects them).
2. Better: also add a migration creating the two unique indexes, de-duplicating first. Per repo
   memory, pick the version by sweeping **all remote branches**, not `ls db/migration/`.

Either way do not leave the current text — a maintainer trusting "the table carries UNIQUE(...)" could
reasonably revert to clear-then-reinsert on the grounds that the DB would catch it.

### M-2 · Medium · `deleteGroup`'s statement order is correct but unpinned — the mutant survives

`v2/wms2-api/src/main/java/net/aim_ai/wms/service/UserGroupService.java:222-224`

Moving `userGroupRepository.deleteGroupById(groupId)` to run **first**, before the two join-table
clears, leaves the entire suite green — 76/76, and the full 5407-test suite unchanged. M4.

The property is real and load-bearing: on hydra-uat both FKs referencing `mywms_group` are
`condeferrable = false` with `confdeltype = 'a'` (NO ACTION), so that mutant is an immediate SQLSTATE
23503 on **every** group delete — a total loss of the group-delete function, not an edge case.

The asymmetry is what makes this worth fixing: the **user** side *is* pinned — M3, the identical
mutant on `UserService.java:279-280`, is killed by `deleteUserClearsMembershipsFirst`. The group side
has `deleteGroupClearsBothJoinTables`
(`src/test/java/net/aim_ai/wms/unit/service/UserGroupServiceTransactionBoundaryTest.java:289`) which
asserts *that* both are cleared but not *when*.

**Fix:** add a Mockito `InOrder` assertion over all three statements to
`deleteGroupClearsBothJoinTables`, mirroring `deleteUserClearsMembershipsFirst`.

### M-3 · Medium · None of the five new JPQL strings is covered by any test

`v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/UserGroupUserRoleRepository.java:53-55`,
`UserGroupUserRepository.java:42-44` and `:58-60`, `UserGroupRepository.java:76-78`,
`UserRepository.java:81-83`

Changing `deleteByGroupId` from `r.id.grouplistId = :groupId` to `r.id.rolelistId = :groupId` leaves
the suite green — 76/76. M6. Every test mocks the repositories, so the query text is invisible to the
suite, and the v2 Testcontainers lane is disabled (SBDEV-2217), so there is no integration lane behind
it either.

**I read all five and they are correct**, verified field-by-field against the mappings:

| Query | Resolves to | Verdict |
|---|---|---|
| `DELETE FROM UserGroupUserRole r WHERE r.id.grouplistId = :groupId` | `mywms_group_mywms_role.grouplist_id` | correct |
| `DELETE FROM UserGroupUser u WHERE u.id.grouplistId = :groupId` | `mywms_group_mywms_user.grouplist_id` | correct |
| `DELETE FROM UserGroupUser u WHERE u.id.userlistId = :userId` | `mywms_group_mywms_user.userlist_id` | correct |
| `DELETE FROM UserGroup g WHERE g.id = :groupId` | `mywms_group.id` | correct |
| `DELETE FROM User u WHERE u.id = :userId` | `mywms_user.id` | correct |

(`UserGroupUserRoleId` = `grouplistId`→`grouplist_id`, `rolelistId`→`rolelist_id`; `UserGroupUserId` =
`grouplistId`→`grouplist_id`, `userlistId`→`userlist_id`; `id` from `AbstractBaseEntity`. All four
column names confirmed present in `pg_attribute` on hydra-uat.)

So this is a coverage finding, not a defect. It matters because of the *shape* of the surviving
mutant: a wrong **field name** would fail loudly at EntityManagerFactory bootstrap (Spring Data
validates `@Query` when it builds the query method), so the only silent mutation is a
**valid-but-wrong field** — precisely `grouplistId`↔`rolelistId` and `grouplistId`↔`userlistId`, and
precisely the SBDEV-3005 defect class, on these very tables. A wrong one deletes the wrong rows
in production with zero test signal.

**Fix:** a reflection-based string-contract test in the shape of the one already in this repo —
`src/test/java/net/aim_ai/wms/unit/repo/UserRoleQueryContractUnitTest.java` — asserting each of the
five `@Query` values. Cheap, and it is the only lane that can see them at all.

### L-1 · Low · The `rollbackFor` sets are inert

`UserGroupService.java:150`, `:212`; `UserService.java:214`, `:268`

`BusinessException` and `FacadeException` both `extends Exception`, and **none of the four methods
declares or can throw a checked exception** — nothing they call is declared `throws`. Dropping
`rollbackFor` entirely from `replaceGroupRoles` leaves the suite green (M7), confirming it.

Harmless, and it matches the house style. But contrast `UserRoleService.java:231-233`, where
`rollbackFor = ApiInvalidParameterException.class` **is** load-bearing because `deleteRole` declares
`throws ApiInvalidParameterException`. The forward hazard is that if a future edit makes one of these
four throw a *different* checked exception, the current set will not cover it and the transaction will
**commit the partial write**. `ApiInvalidParameterException` is the obvious candidate — both
controllers already throw it, and the natural next step (moving the existence check or the
history refusal into the service) would do exactly that.

**Fix:** either add `ApiInvalidParameterException.class` pre-emptively, or add one comment saying the
set is deliberately unexercised so the next author knows to widen it.

### L-2 · Low · The bulk deletes drop the `@Version` predicate

`UserGroupRepository.java:76-78`, `UserRepository.java:81-83`

`UserGroup` and `User` both inherit `@Version private Integer version` from
`AbstractBaseEntity.java:34-35`. The old `deleteById` path emitted `DELETE … WHERE id=? AND version=?`
and raised `OptimisticLockingFailureException` when another admin had concurrently edited the row; the
new bulk statements emit `WHERE id=?` only, so a delete now silently wins over a concurrent edit.

Defensible for a delete — "delete wins" is usually what an operator means — and the `…Removed == 0`
WARN branch is a deliberate tolerance of a lost race. But it is an undocumented behaviour change, and
both javadocs go into detail about *why* `deleteById` is avoided without mentioning that the version
check goes with it.

**Fix:** one sentence in each `@Query` javadoc.

### L-3 · Low · `deleteUser` will report the wrong reason for a user holding a direct role grant

`UserRepository.java:70-76` (the deliberate non-cascade) and
`v2/wms2-api/src/main/java/net/aim_ai/wms/controller/UserController.java:371-376` (the message)

`mywms_user_mywms_role.user_id → mywms_user` is a real, non-deferrable FK (confirmed in
`pg_constraint`, hydra-uat) and is deliberately not cleared. If it ever holds a row for the target
user, `deleteUserById` raises `DataIntegrityViolationException` and the controller answers 422 with
*"referenced by warehouse records (orders, receipts, bills of lading or messages). Operational history
is never removed."* — none of which is the actual reason, and unlike operational history a direct role
grant is an access grant, not an audit record.

**Currently unreachable**, which is why this is Low, not Medium:
- **0 rows** on hydra PRD, hydra UAT, hydra DEV2, wineco DEV and shipitez nywh UAT.
- `User` has no mapping to it — `User.java` declares only `groups`, so `deleteById` would not have
  cleared it either. **No regression.**
- No `src/main` code writes it.
- It has neither a PK nor any index, and its columns are `user_id` / `roles_id` — a Hibernate-default
  join table for a mapping that no longer exists in the entity model.

**Fix:** broaden the 422 wording rather than cascading. Do not add a cascade — that would delete
access grants on a path whose stated contract is "atomicity and an honest status, not a wider cascade".

### L-4 · Low · Two javadoc inaccuracies describing the EAGER hazard

`UserGroupUserRepository.java:33-36` says the table is "mapped a second time, by `UserGroup.groups`'
inverse side (`User.groups`, `@ManyToMany(fetch = EAGER)`)". Two errors: `UserGroup` has no `groups`
field at all (it has `roles`), and `User.groups` is an **owning** side — it carries its own
`@JoinTable` (`User.java:33-39`) and there is no `mappedBy` anywhere in either entity. The hazard
being described is real and the code is right; the description of the mapping is not.

`UserGroupUserRoleRepository.java:33-34` says the method is used "by both
`UserGroupService.deleteGroup` and the group-delete path" — those are the same thing.

**Fix:** correct both comments. Worth doing precisely because these comments are the artefact the next
author will reason from.

### L-5 · Low · informational · The same defect class survives untransacted in `AccessService`, but is unreachable

`v2/wms2-api/src/main/java/net/aim_ai/wms/service/AccessService.java:238-249` (`addRoleToUser`) writes
`mywms_group`, then `mywms_group_mywms_user`, then `mywms_group_mywms_role` — three separate
autocommits, no `@Transactional` anywhere in the class. A failure at the third leaves an orphan
connector group holding a member and no role. `:252-266` (`removeRoleFromUser`) does two per
connection and also orphans the connector group. Same two tables, same failure mode SBDEV-3012 fixes.

**Not reachable.** The only callers are `UtilRestController:255-271`, and that class is annotated
`@Service`, not `@RestController` (`UtilRestController.java:23-24`), so its `@RequestMapping` methods
do not route.

Flagging as an observation only — **do not file a ticket**. Per the repo ticket policy this is the same
fix visit as SBDEV-3012 (one code path, one owner), so if `UtilRestController` is ever made to route,
this should widen this ticket rather than get its own.

---

## RULED OUT — actively checked, found correct

1. **Transaction manager qualifier on all four methods.** Correct, and pinned *behaviourally*, not
   just by reflection: M10 (bare `@Transactional` on `deleteGroup`) turns 3 tests red, because the
   test config registers the landlord mock as `@Primary`, mirroring production.
2. **Propagation and readOnly on all four.** Pinned by the four
   `…TransactionDefinitionIsAWritableRequiredTransaction` tests. M8 (`readOnly = true`) and M9
   (`propagation = NOT_SUPPORTED`) both killed. This is the mutant class that scored 100% green on
   SBDEV-3005; it does not survive here.
3. **Checked-exception commit hazard — none exists.** No method in the four declares `throws`, and
   nothing they invoke is declared `throws`. `EntityNotFoundException extends RuntimeException` and
   `DataIntegrityViolationException` is unchecked, so both roll back by default. This is the
   `UserRoleService.deleteRole` trap and it is not present here.
4. **Self-invocation / proxy bypass.** Ruled out by grep: the only callers of the four methods are
   `UserGroupController:112` and `:157` and `UserController:364` and `:420` — different beans, so the
   proxy applies. Ruled out again behaviourally, since the boundary tests observe the transaction
   manager at all, which only happens through the proxy. No call originates inside `UserService` or
   `UserGroupService`.
5. **Newly CGLIB-proxied beans.** `UserService` gains a proxy (it carried no `@Transactional` before).
   No constructor cycle is created: nothing in either service's dependency set (`ClientService`,
   `LocationService`, `BasicService`, the repositories) references either service back, and the full
   5407-test suite is at baseline.
6. **Set-difference functional equivalence.** Correct for every input I could construct: empty list
   (removes all — `replaceGroupRolesAcceptsAnEmptySet`), duplicates (`…DeduplicatesTheRequest`; the
   `LinkedHashSet` dedupes before either loop runs), all-retained (`…IsANoOpWhenNothingChanged`),
   all-new, disjoint, partial overlap. Removals and insertions are on provably disjoint key sets
   (`!desired.contains(k)` vs `!existing.containsKey(k)`), which is what makes Hibernate's
   insert-before-delete `ActionQueue` order unable to collide. The one divergent input is `null` in
   the id list, and it **fails closed** (NOT NULL violation → rollback, no partial write); the
   controllers reject it earlier in `requiredId`.
7. **The set difference is genuinely required, not decorative.** M5: replacing it with
   clear-then-reinsert turns two tests red.
8. **Composite key order in both replace methods.** Correct, and pinned — M1 kills 1 test, M2 kills 2.
9. **`flushAutomatically = true` is harmless.** In the only two call paths the persistence context is
   empty when the bulk deletes run: `existsById` materialises nothing, and neither delete method
   performs any entity-level operation, so there is never a queued action to interact with. It would
   become *protective* rather than dangerous if an outer transaction ever composed `replaceGroupRoles`
   with `deleteGroup` — without it the bulk delete would run before the queued INSERT, which would
   then re-insert a grant for a group that no longer exists. The author's "no-op under this shape"
   characterisation is accurate.
10. **`clearAutomatically` correctly absent.** No stale entity exists to evict in either path, and
    `em.clear()` would detach an outer caller's entire context and discard its pending changes.
11. **No `@Transactional` on the repository methods is correct.**
    `@EnableJpaRepositories(transactionManagerRef = "tenantTransactionManager")`
    (`landlord/config/TenantDatabaseConfig.java:22-26`) already binds repository-level transactions to
    the tenant manager, so a bare one would be actively wrong and a qualified one redundant. Because
    these are `@Modifying` interface query methods they also *require* an ambient transaction — calling
    one outside the service methods fails loudly, never silently. All call sites are grep-confirmed
    inside the transactional service methods.
12. **`deleteGroup` cascade completeness — exactly right.** `pg_constraint` on hydra-uat shows
    precisely two FKs referencing `mywms_group`: `mywms_group_mywms_role.grouplist_id` and
    `mywms_group_mywms_user.grouplist_id`. Nothing else. The three statements are exhaustive.
13. **`deleteUser` non-cascade inventory — exactly right.** Eleven FKs reference `mywms_user`: the
    nine operational ones the javadoc names (`billoflading`, `billoflading_position`,
    `cyclecount_position`, `goodsreceipt`, `goodsreceiptposition`, `message`, `pickingorder`,
    `pickingorder_position.pickedbyoperator_id`, `replenishorder`), plus
    `mywms_group_mywms_user.userlist_id` (cleared) and `mywms_user_mywms_role.user_id` (deliberately
    not — L-3). No FK is missing from the analysis and none is misattributed.
14. **Statement order in `deleteUser`.** Correct and pinned (M3).
15. **No stale-persistence-context hazard for a later caller inside these transactions.** The bulk
    deletes materialise nothing and the two replace methods use no bulk deletes, so nothing goes stale
    intra-method. The outer-transaction staleness that the absent `clearAutomatically` implies has no
    caller today.
16. **Access decisions are not cached, so no eviction is missing.**
    `AccessService.doesUserHaveAccess` / `doesUserHaveAnyAccess` read `UserRepository.getAllRoles`
    live; there is no `@Cacheable` / `@CacheEvict` / `@CachePut` anywhere on the user, group or access
    path. A committed membership change takes effect immediately.
17. **No `deleteById` on `User` or `UserGroup` remains anywhere in `src/main`** — grep-confirmed, only
    a javadoc mention.
18. **OSIV is off** (`src/main/resources/application.properties:55
    spring.jpa.open-in-view=false`). This is what makes the whole "the service must not materialise
    the entity" design actually hold: the controllers' pre-transaction `existsById` reads cannot leave
    an EAGER `User` / `UserGroup` in the service transaction's persistence context, because there is
    no request-scoped context to share.
19. **`deleteGroup` / `deleteUser` check existence before any write** — so an unknown id can never
    partially clear anything, and the check itself materialises nothing.

## Could NOT verify

- **That the exception `UserController.delet` catches is really a `DataIntegrityViolationException` at
  runtime.** The v2 Testcontainers lane is disabled (SBDEV-2217) and I would not run a destructive
  delete against a shared UAT DB. The reasoning is sound — `HibernateJpaDialect` translates
  Hibernate's `ConstraintViolationException`, and a bulk JPQL `executeUpdate` raises at statement time
  *inside* the service method, so the interceptor rolls back before the controller's catch runs — but
  it is reasoning, not measurement. Note the unit test simulates it by throwing a
  `DataIntegrityViolationException`, which assumes the answer. **This is the single largest unverified
  claim in the PR** and it is the one the 422 contract rests on. Worth one manual curl on dev against a
  user with picking history before merge.
- **Hibernate 6's row-count expectation for a non-versioned `@EmbeddedId` delete matching two duplicate
  rows** — the M-1 corollary on a DB without the unique index. Both plausible outcomes (silently
  deleting both, or `StaleStateException`) are a loud rollback rather than silent data loss, so I did
  not chase it further; but nobody has measured it.
- **Behaviour on a tenant DB that lacks the unique index.** hydra PRD and shipitez nywh UAT both lack
  it; neither is a DB I would write to.
- **The TOCTOU window between the controllers' `existsById` (`UserGroupController:150`,
  `UserController:415`) and the service transaction.** A group or user deleted in that window makes the
  insert raise an FK violation → 500 rather than a clean 4xx. It fails closed and rolls back, so it is
  not a data-integrity issue; I did not attempt to reproduce the race.

## Operational note for the team lead

The shared ticket worktree
`/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3012` was **dirty** while I was
reviewing — another lane was live-mutating `service/UserGroupService.java` (line 150 had `rollbackFor`
stripped) and had touched `controller/UserController.java`, and `target/classes` held bytecode from a
*third*, fully-bare `@Transactional` state. My first test run there reported 3 failures in
`UserGroupServiceTransactionBoundaryTest` that were **their mutant, not the PR**. Anyone else running
tests in that worktree should expect the same contamination — it was **still moving** when I finished
(by then the dirty pair was `UserService.java` + `UserController.java`), so treat any test result from
that path as unattributable until the tree is clean. I re-ran everything in a private
`git worktree --detach 51d8c09`; all numbers in this report come from that clean copy, and the
`archunit_store` mutation `mvn test` performs was confined to the disposable worktree.

If two lanes both need to mutate, each should take its own detached worktree.
