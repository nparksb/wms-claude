# SBDEV-3183 — review of `2a71843c` + `c4e18173`

**Range reviewed:** `6280d34c..c4e18173` on `feature/SBDEV-3183-customerorder-write-withdrawal`
**Base:** `origin/develop` @ `452d3ed4`
**Reviewer lane:** rev-mod · read-only against the reviewed worktree; all builds run in a private
detached worktree at `/tmp/.../scratchpad/rev-mod-wt` (`git worktree add … c4e18173 --detach`).

## Verdict

**Ship it.** The substantive change is correct and the invariant test is real, not theatre. I could not
break the no-caller claim on any of the five axes I tried, I independently re-derived the count of nine
with a static instrument that agrees exactly, and the two mutations I ran both red with the exact route
named.

**No High findings.** Saying so plainly rather than padding: I looked for a live caller five ways and a
missed `@Modifying` two ways, and found neither.

Two Mediums, both about the *test's* honesty rather than the fix: a stated blind spot that I confirmed is
**exploitable, not theoretical**, and a count in the shipped javadoc that is wrong by exactly the number of
methods this commit closed.

---

## What I RAN vs what I READ

### RAN (private worktree, Maven 3.9.15 / JDK 21.0.11-ms, `mvn -o test`)

| # | Mutation | Expected | Result |
|---|---|---|---|
| M0 | none (unmodified `c4e18173`) | green | **GREEN** `Tests run: 1, Failures: 0` |
| M1 | drop `exported = false` from `Client.toggleEnableReceivingById` | red, naming that route | **RED** — `Expecting empty but was: ["GET /v3/client/search/toggleEnableReceivingById -> Client.toggleEnableReceivingById"]` |
| M2 | drop `@RestResource(exported = false)` from `Customerorder.updateStateByIds` | red, naming that route | **RED** — `["GET /v3/customerorder/search/updateStateByIds -> Customerorder.updateStateByIds"]` |
| M3 | floor → `isGreaterThan(999999)` to force the real count out | reveals the traversal count | **RED**, `Expecting actual: 240` |
| M4 | add derived `void deleteByNumber(String number);` (no `@Modifying`) to the exported `CustomerorderRepository`, floor → 999999 | reveals whether a derived delete is exported as a search | **RED**, `Expecting actual: 241` — **+1, the derived delete IS an exported search** |

Worktree confirmed clean between and after all mutations (`git status --short` empty). Full `mvn -o clean
test` queued; result appended at the bottom.

Also run:
- A **static reconciliation** of every `@Modifying` in `src/main/java` (block comments and line comments
  stripped so javadoc mentions do not count), cross-joined against repository-level export status under the
  `ANNOTATED` detection strategy.
- **Bytecode inspection** of `spring-data-rest-core-4.5.7.jar` (`javap -c -p`) to settle the two
  "could it silently pass?" questions instead of arguing them from memory.
- **Caller sweeps** across `wms2-web-ui`, `wms2-mobile-ui`, `oms-laravel-api` — both `git grep <name>
  origin/develop` (tracked at the true base) and a plain recursive `grep` over each working tree
  (which ignores `.gitignore`, so it also covers untracked/ignored trees), plus a monorepo-wide sweep.

### READ (not executed)
The two commit messages, `RestConfiguration.SDR_WRITE_WITHDRAWN`, `SdrWriteWithdrawalContextTest`,
`SdrUncalledSurfaceNotExportedContextTest`, `SdrFunctionGuardUnitTest`, the four changed repositories, and
the ticket's own `SBDEV-3183-evidence/sdr-surface-inventory.tsv`.

---

## 1. Does un-exporting any of the nine break a live caller?

**No — and I could not break the claim.** Five axes, all empty:

1. **Bare method name, tracked at the true base.** `git grep <name> origin/develop` in all three repos, for
   all nine names, no leading-slash requirement → **zero hits**. (The three deliberately-named ones use
   `path = rel = <methodName>`, and SDR's default search path for the bare six is also the method name, so
   the bare-name axis is the correct instrument for all nine.)
2. **Working-tree grep including ignored files.** Plain `grep -r` over each repo directory (grep does not
   honour `.gitignore`), excluding only `node_modules`/`vendor`/`.git` → **zero hits**. This covers
   `cypress/`, `tests/e2e/`, `.env*`, and the `reports/`-pattern directories. On the `reports/` tree
   specifically: `.gitignore` line `reports/` matches `store/reports`, `pages/reports`,
   `components/reports`; there are **zero** tracked paths under a top-level `reports/` at `origin/develop`
   and no such directory in the checkout, and the nested ones were covered by both instruments.
3. **The LockOverview failure mode — URLs assembled from variables.** I enumerated every `search/`
   reference in both UIs whose continuation is *not* a slash-literal. Exactly **one** site builds a search
   name dynamically: `wms2-mobile-ui/store/lookup.js` — ``$get(`/lookup/search/${data.value}`)`` — and it is
   on the `lookup` resource, so it cannot reach any of the nine. Every other dynamic site interpolates only
   the *query string* after a literal search name (e.g. `` `/section/search/findByName?name=${data.value}` ``).
4. **OMS.** `config/wms.php` contains exactly three SDR search entries — `client_find_by_number`,
   `itemdata_by_client`, `printer_search_by_type` — none of the nine. They are `env()`-overridable, which is
   a theoretical out-of-repo lever, but no deployment file in the monorepo sets them to any of the nine.
5. **Monorepo-wide.** Every hit for the nine names outside `v2/wms2-api` is **documentation** in `sbdocs/`
   (workflow docs, state-machine catalogue, this ticket's own evidence files). No code.

**Positive corroboration, not just absence.** The brief was right to weight the three explicitly-named ones
higher, so I checked whether the UI reaches the same fields another way — it does, which is *why* the
search is unused:
- `Client.toggleEnableReceivingById` — `wms2-web-ui/components/admin/shippers/addShipper.vue` binds
  `v-model="shipper.enablereceiving"` and submits it as a **field on the client resource**, not via the
  toggle route.
- `Client.updatePrinterToNullByPrinterId` — has an internal caller in
  `controller/PrinterController.java`: `clientRepository.updatePrinterToNullByPrinterId(printerId);`, i.e.
  it is reached through the MVC printer-delete path, not over SDR.
- `Advice.updateAdviceToStateById` — internal caller in `service/ReturnAdviceAutoReceiveService.java`:
  `adviceRepository.updateAdviceToStateById(AdviceState.FINISHED, adviceId);`.

**Residual risk, stated honestly:** an out-of-repo caller (ops script, Postman, a partner integration) for
the three deliberately-named routes is unfalsifiable from here. The commit already says this in the code.
I add one fact that shrinks it further — see finding L-2: `toggleEnableReceivingById`, the one with the
most "somebody meant this" signal, has **zero internal Java callers as well**, so nothing in this codebase
has used it by any route.

---

## 2. Is the invariant test correct and non-vacuous?

**Correct, and non-vacuous — settled by bytecode, not by reading the test.**

The two "could it silently pass?" questions both resolve against `spring-data-rest-core-4.5.7`:

- **`getSearchResourceMappings` never returns null.** `javap -c` on
  `RepositoryResourceMappings.getSearchResourceMappings` shows every path ends in a
  `new SearchResourceMappings(...)` / cache-hit `areturn`; there is no `aconst_null` return. The test's
  `if (searches == null) continue;` is unreachable defensive code — harmless, but it cannot hide anything.
- **`MethodResourceMapping.getMethod()` never returns null.** `RepositoryMethodResourceMapping` declares
  `private final java.lang.reflect.Method method` assigned from a constructor argument. The test's
  `method != null` guard likewise cannot hide an offender.
- **The traversal counts *exported* searches and only those.** The same bytecode shows the builder checks
  `ResourceMetadata.isExported()` and then, per query method,
  `RepositoryMethodResourceMapping.isExported()` **before** `List.add`. So a method carrying
  `exported = false` is never yielded. That is what makes `exportedSearches` correctly named — and it is
  independently confirmed empirically: `MessageRepository` is exported at repository level and holds two
  `@Modifying` methods already at `@RestResource(exported = false)`; the test is green, so those are being
  excluded rather than counted-and-flagged.

**Could it pass while a `@Modifying` search is exported?** Not by any mechanism I could construct. M1 and
M2 both red, from two different repositories, naming the exact route. The `getMethod()` return is the
interface declaration where `@Modifying` lives — proven by those reds, not assumed.

**Is `isGreaterThan(100)` theatre?** No, but it is loose. The real count is **240** (M3). A floor of 100
tolerates a 58% collapse in traversal before firing. In its defence, the looseness is deliberate and the
in-code comment says so — and it is justified: Slice 2 of this very ticket legitimately dropped the
exported-type count 62 → 35, which alone moved searches 336 → 249, a 26% drop. A tight floor would have
red against correct code. **Low finding L-4** suggests 200 as a middle setting.

### The blind spot is real and exploitable — M-1 (Medium)

The javadoc states the gap accurately:

> *"A method that mutates by other means — a native `INSERT`/`UPDATE` inside `@Query` without the
> annotation, or a mutation performed downstream of a read — is invisible here."*

That sentence is **true**, and I verified the population it describes is **currently empty**: across all 35
exported repositories there are **zero** `@Query` methods containing `INSERT INTO` / `UPDATE x` /
`DELETE FROM` without `@Modifying`. (The one near-miss, `StockunitRepository`, matches only on
`"FOR UPDATE OF stockunit"` inside a `SELECT` — a lock, not a mutation.)

**But the list omits the most likely way the defect comes back: a derived `deleteBy…` query method.**
Spring Data JPA derives those without needing `@Modifying`, so `method.getAnnotation(Modifying.class)`
returns null and the invariant cannot see it — while SDR still publishes it as a search.

I proved the export half rather than inferring it. **M4**: adding
`void deleteByNumber(String number);` — no `@Modifying`, no `@Query` — to the exported
`CustomerorderRepository` moved the traversal count from **240 → 241**. It is published as
`GET /v3/customerorder/search/deleteByNumber`, and the invariant is structurally blind to it.

Precision about what I proved: I demonstrated the route is **mapped and exported**. I did not execute it
over HTTP. But it is reachable by exactly the mechanism that makes the nine dangerous, and that mechanism
was already established by the security lane earlier in this ticket.

Population today: **zero** derived delete/remove methods on exported repositories, so this is a latent gap,
not a live hole. It matters because the test is the anti-regression mechanism and the hole sits precisely
where a regression would appear.

**Recommendation:** name derived deletes explicitly in the blind-spot list, and consider widening the
offender predicate beyond the annotation — e.g. also flag an exported search whose method name matches
`^(delete|remove)` . That is a genuine widening rather than a comment, and it would have caught M4.

---

## 3. Did the commit miss any `@Modifying` methods?

**No. Nine is exactly right, confirmed by a second, independent instrument.**

The commit derived nine from a runtime `ResourceMappings` probe. I re-derived it statically — parsing every
`@Modifying` site in `src/main/java` with comments stripped, and joining against repository-level export
status. Under `RestConfiguration`'s
`config.setRepositoryDetectionStrategy(RepositoryDetectionStrategy.RepositoryDetectionStrategies.ANNOTATED)`,
a repository with no `@RepositoryRestResource` is **not** exported, which is what keeps
`OutboxMessageRepository` and `RestIdempotencyRepository` out of scope.

| | count |
|---|---|
| `@Modifying` sites in `src/main/java` (code only) | 31 |
| …on **exported** repositories | **16** |
| …of those, already `exported = false` before this commit (`Message` 2, `User` 1, `UserGroup` 1, `UserGroupUser` 2, `UserRole` 1) | 7 |
| …**remaining, closed by `c4e18173`** | **9** ✅ |
| **exported repo AND exported method, after the commit** | **0** ✅ |

16 − 7 = 9. The two instruments agree exactly. The other 15 `@Modifying` sites sit on repositories that are
un-exported at class level (`Adviceposition`, `Billoflading`, `BillofladingPosition`,
`CustomerorderPosition`, `PickingorderPosition`, `UserGroupUserRole`, `UserRoleUserFunction`) or on
repositories SDR never detects (`OutboxMessage`, `RestIdempotency`).

Worth recording because it looks alarming and is not: several of those carry a deliberate
`@RestResource(path=…, rel=…)` on a **`DELETE`** — e.g. `BillofladingRepository`'s
`@Query("DELETE FROM Billoflading b WHERE b.number = :bolNumber")` named
`deleteBolPositionsByInternalBolName`. They are inert only because Slice 2 un-exported the repository. That
is a **single** point of failure: re-exporting any one of those repositories re-opens a bulk DELETE over
GET. The new invariant test is exactly what catches that, which is a strong argument for it existing.

---

## 4. Scope — were the six non-Customerorder withdrawals right to include?

**Yes, and I did not reach that by agreeing with the commit message.** The decisive argument is one the
commit does not quite make:

**You cannot ship this invariant test and leave six known offenders.** The test either passes or it does
not. Splitting `c4e18173` means either (a) shipping the test with six suppressions/an allow-list — which
converts a clean invariant into a stale exception list, the exact failure mode the SBDEV-3169 lesson is
about — or (b) shipping the three Customerorder annotations with **no** invariant, which is the path-pin
that leaves six live and "looks complete". Both are worse than the third option.

The alternative — defer all nine to a new ticket — is the only coherent split, and it is not better: the
defect is live on `develop` today, the fix is nine one-line annotations with zero callers and zero internal
impact, and the reviewed evidence exists now.

**The real cost, stated:** the PR's title and ticket say *Customerorder write withdrawal*, and six of nine
lines touch `Replenishorder`, `Client` and `Advice`. Someone bisecting a future replenishment-priority or
shipper-admin regression will not think to look in a Customerorder ticket. That is a genuine cost and it is
paid in discoverability, not risk. The commit already flags it for Nam and the code comments name
SBDEV-3183 at every one of the nine sites, which is the mitigation that matters.

**My recommendation:** keep it as one commit; make sure the ticket title/description mentions the four
entity types so the ClickUp record is greppable.

---

## 5. Is `2a71843c`'s prose now true?

All three claims the brief asked me to check are **TRUE**, verified mechanically by extracting both lists
and diffing them:

| Claim | Verdict |
|---|---|
| `SDR_WRITE_WITHDRAWN` and `SdrWriteWithdrawalContextTest.WITHDRAWN` are identical 48-name sets | **TRUE** — 48 and 48, zero difference in either direction, no duplicates |
| "TEN resources with a live UI writer" | **TRUE** — `MUST_STAY_WRITABLE` holds exactly 10: `Section, Advice, Boxtype, Client, Cyclecount, Location, LocationType, Sysprop, UserGroup, UserRole` |
| No file still asserts the old eleven/47/11 values | **TRUE for those values** — every surviving "47/11" and "eleven" reference is explicitly historical narration ("used to read…", "do not restore 47/11"), and `assertThat(WITHDRAWN).hasSize(48)` / `assertThat(MUST_STAY_WRITABLE).hasSize(10)` match |

48 + 10 = 58 reconciles against the documented writable-resource total, and the two sets do not overlap.

**But `c4e18173` introduced a new wrong count — see M-2 below.** The pattern the brief was worried about
did recur, just not in the places it named.

---

# Findings

## M-1 — Medium — the invariant's stated blind spot is exploitable, and omits derived deletes

`SdrModifyingSearchNotExportedContextTest`. Full detail in §2. In short: the blind-spot list is accurate in
what it says but does not name derived `deleteBy…` query methods, which need no `@Modifying`, are published
by SDR as exported searches (**proven: M4, 240 → 241**), and are invisible to the offender predicate. Zero
instances today, so latent rather than live.

Fix: name derived deletes in the javadoc, and consider also flagging exported searches whose method name
matches `^(delete|remove)`.

## M-2 — Medium — the shipped javadoc's "249 exported searches" is wrong; the real number is 240

`SdrModifyingSearchNotExportedContextTest`:

> *"249 exported searches were measured on 2026-09-01; asserting a floor rather than the exact number keeps
> this from becoming another count that drifts with every merge."*

The commit message repeats it: *"It carries a sensitivity floor so a green cannot mean 'the traversal found
nothing' — 249 exported searches measured."*

**Measured (M3): 240.** And the gap is exactly nine — the number of searches this commit un-exported. 249
was the correct **pre-commit** figure; withdrawing the nine dropped it to 240, and the javadoc states the
pre-fix number as the current measurement.

Rated Medium rather than Low despite being prose-only, for one reason: this figure sits in the file whose
entire stated purpose is anti-vacuity accounting, and the discrepancy is *the same size as the fix*. A
reader who re-derives will find 240, be short by exactly nine, and reasonably suspect the traversal lost
them. Downgrade to Low if you disagree — the code is unaffected.

The whole chain reconciles cleanly and is worth writing down:
**336** searches (pre-Slice-2, 62 exported types — the figure in the ticket's own
`sdr-surface-inventory.tsv`, which has 336 rows with `kind=SEARCH, exported=true`)
→ **249** after Slice 2 withdrew 27 types (62 → 35 exported)
→ **240** after `c4e18173` withdrew the nine searches.

Fix: change 249 → 240, and say it is post-withdrawal.

One related note: that same `sdr-surface-inventory.tsv` classifies all nine of these routes in its
`writable` column as **`read-only`** — e.g. `Customerorder /customerorder/search/updateStateByIds SEARCH
true GET  read-only`. That misclassification is arguably the artifact that let the defect survive AC-1. It
is a pre-existing evidence file, not code, but if it stays in the ticket folder it should carry a
correction note.

## L-1 — Low — three files still say Slice 2 withdrew "29" types; it is 27

Pre-existing — **identical at `452d3ed4` and at `c4e18173`**, so not introduced by this PR. Reported
because `2a71843c` is the count-reconciliation commit and touched one of the three files.

The authoritative figure is enforced by a test: `SdrUncalledSurfaceNotExportedContextTest` asserts
`assertThat(WITHDRAWN).hasSize(27)` above the comment *"62 exported before Slice 2 - 27 withdrawn = 35
exported; 35 - 5 ruled = 30 unruled."* The runtime startup log agrees — `SdrRuleStartupCheck` printed
*"35 exported domain type(s), 5 ruled, 30 unruled."*

Still asserting 29:
- `RestConfiguration.java` — *"SBDEV-3183 Slice 2 then withdrew / 29 whole types."*
- `PutawayConfigActionGuardUnitTest.java` — *"SBDEV-3183 Slice 2 withdrew 29 whole…"*
- `SdrFunctionGuardUnitTest.java` — *"Slice 2 withdrew 29, so the unauthenticated index now advertises 33."*

The last one derives a downstream number from the wrong subtrahend: 62 − 29 = 33, where 62 − 27 = 35, which
is the measured value. So the "33 advertised" claim is also suspect.

## L-2 — Low — `Client.toggleEnableReceivingById` is fully dead code, not merely un-exported

The commit says *"Internal Java callers are unaffected."* True for eight of the nine. This one has
**zero internal Java call sites** — I grepped `.toggleEnableReceivingById(` across all of `src/main/java`
and got nothing, while the other eight each resolve to one or two real callers.

Two consequences, both favourable:
1. It strengthens the safety case for the riskiest of the three deliberately-named routes — nothing in this
   codebase has reached it by any path, HTTP or Java.
2. It is now a `@Query` + `@Modifying` + `@Transactional` + `@CacheEvict` method with no caller at all — a
   deletion candidate. Not for this commit; worth a line on the ticket.

## L-3 — Low — `null` guards in the new test are unreachable

`if (searches == null) continue;` and `method != null` can never fire on `spring-data-rest-core-4.5.7`
(§2, bytecode). They are harmless and defensible as upgrade insurance, but a reader may take them as
evidence that a null case was observed. A half-line comment saying "defensive; 4.5.7 returns neither"
would prevent that.

## L-4 — Low — the sensitivity floor is loose

`isGreaterThan(100)` against an actual 240 tolerates a 58% collapse. The comment already argues for a floor
over an exact count and that argument is right. 200 would keep the anti-brittleness while actually
constraining: Slice 2 was the largest legitimate withdrawal this codebase has seen and it cost 26%.

## L-5 — Low — the five-line rationale comment is duplicated verbatim at six sites

The same block is copy-pasted at three `CustomerorderRepository` methods and three
`ReplenishorderRepository` methods, and a second six-line block at three more. Defensible — each site is
read in isolation and the comment is load-bearing where it sits — but the six copies will drift. Noting it
rather than recommending a change.

---

## Nothing found at these

- **No High findings.** No live caller on any of five axes; no missed `@Modifying`; no way to make the
  invariant pass with an offender present.
- No correctness defect in any of the nine annotations — `exported = false` removes the HTTP route only,
  and all eight methods that have internal Java callers keep them.
- No issue with `2a71843c`'s three named prose claims; all three verified true.

---

## Full-suite result (appended after the report body)

Run independently in my own detached worktree at `c4e18173`, `mvn -o clean test` (note: `clean`, so no
stale `target/test-classes` — deleted test classes cannot run):

```
[WARNING] Tests run: 6013, Failures: 0, Errors: 0, Skipped: 67
[INFO] BUILD SUCCESS
EXIT=0
```

**6013 / 0 failures / 0 errors / 67 skipped — exactly the figure `c4e18173`'s commit message claims.**
The commit's `+3 vs a 6010 baseline at 452d3ed4` is therefore consistent; I did not separately re-measure
the base, so the *delta* is unverified while the *absolute* is confirmed.
