# SBDEV-3410 — Revision log

Provenance for `SBDEV-3410-stock-unit-record-shipper-filter-and-product-name.md` (rounds 2–4; round 1 was the
original draft and narrated no log). Moved out of the
plan in round 4: no implementer reads it to build anything, and both the audiences that do read it
(the next reviewer, and Nam) are already in this directory.

### Round 4 — 2026-09-18 (planner lane, convergence pass after `review-architect-r3.md`)

**architect r3 — SOUND-WITH-CHANGES**, one blocker and five absorbable items. Nam approved converging after
this pass, so **status flipped `pending approval` → `approved`**; the next step is `wms-tdd-gate`.

| Finding | Severity | Verdict | What moved |
|---|---|---|---|
| **A-R3-1 — the `_embedded` fact is inverted** | HIGH (blocker) | **CONFIRMED BY MEASUREMENT. The architect was right and rounds 1–3 were wrong.** | This is the one item the round-3 review refused to settle by reading, and it was settled by **execution**. A `git archive` of `origin/develop = 7ebb9c83` into a scratchpad (no branch, no worktree, nothing written into the repo) plus two throwaway `*ContextTest` classes in the app's own MockMvc/H2 lane, dispatching **six** real SDR routes across four resource kinds. **All six returned `200` with `"_embedded": {"<rel>": []}` — present and empty.** Full bodies, method, positive control and blind spots: `SBDEV-3410-evidence/embedded-shape-measurement.md`. Three consequences, all applied: **(1)** §3.9 item 4's rationale is rewritten — `rowsOf` ships for the **renamed-`collectionResourceRel`** arm, which is live, not for a zero-row `TypeError`, which does not exist; the B-2 "grid keeps the previous shipper's rows under a network toast" failure mode both lanes graded HIGH **is not live**. **(2)** §7.4's zero-row fixture is corrected to `{_embedded:{stockrecordView:[]}, page:{totalElements:0}}` and a **new renamed-rel case** added, which is the only Jest surface that can grade `rowsOf`. **(3)** §7.8's `rowsOf` mutation row is **re-pointed**: against the real shape the "drop the guard" mutant **survives** the zero-row fixture, so the row now names the renamed-rel fixture and says so explicitly. §7.7's zero-row manual row moved **back to dev** (a non-matching keyword reaches a zero-row page; hydra PRD is kept as an optional second variant for a selectable zero-row shipper) and its pass condition restated — it grades AC-4's empty page, not `rowsOf`. Fourth consequence: `store/admin/group.js`'s SBDEV-3012 javadoc is **false**, measured on the association shape it describes, and is now §10.4 item 6 |
| **A-R3-2 — §3.9 item 2 still says "for both branches"** | MEDIUM | **Accepted. Round 3's log claimed this was fixed and it was not — re-read before re-claiming.** | Item 2 now reads *"Append from state — on the FILTERED branch only"*, keeps the from-state rationale, and states in the item itself that appending `&clientId=-1` on the unfiltered branch **reds §7.4**, because the unfiltered method has no such parameter |
| **A-R3-3 — N-3's recipe cites `OutboxItFlyway`** | LOW-MED | **Accepted** | §7.2's `constraintIsAsserted` recipe now cites **`BillofladingTransferIdNotNullIT`** — same package, carries `migrateTo(url, target)` **and** the SQLSTATE cause-chain walker — and quotes that class's own javadoc warning against copying `OutboxItFlyway`'s `executeInTransaction(false)`, which pins a `success=f` history row and blocks every later `V2.2.x` behind `Validate failed`. The "eight ITs" count is replaced with the derived figures: `Flyway.configure()` in 17 test files, `.target(` in exactly **two** |
| **A-R3-4 — `NATIVE_KEYWORD_CLAUSE` is not quoted and differs from `KEYWORD_CLAUSE`** | LOW | **Accepted** | §3.6 now quotes the constant in full, byte-for-byte from `origin/develop` including the leading space after `WHERE` and the trailing space before `order by`, and carries a ⚠ that it is **native SQL and quotes the column** — `LOWER(p.\"operator\")` — where the JPQL clause writes `LOWER(p.operator)`, that `operator` is unreserved so **both forms execute and return the same rows**, and therefore that the wrong copy is silent and breaks only the byte-identical property §6's "No" rests on |
| **A-R3-5 — §7.7 says `filter: 0`** | LOW | **Accepted** | Corrected to `filter: "0"` (a string, as DevTools shows it) — the tenth site of what was a nine-site sweep |
| **§7.8's B-4 row attributes one kill message** | nit | **Accepted** | The row now names **both**: assertion 1 for the four `contains`-killed mutants, assertion 2 (*the sliced tail contained `" OR "`*) for the un-parenthesised and lower-case-`or` tails, with an instruction not to "fix" a correct red because the message did not match |

**Nam's decisions applied this pass.**

- **`<v-autocomplete>`, not `<v-select>`** — round 3's one open AC-visible choice, now closed on the measured
  shipper counts (125–164 across four environments, all past the sibling's stated threshold). Updated in §3.9,
  **AC-1** (which had mandated a `{ id: null, label: 'All Shippers' }` first item and no longer does), §0.2
  row 25, §4, §5.2 P6 and §7.7. **Three behaviour differences a `<v-select>` would not have had are written
  into §7.4 as required Jest cases**: type-ahead filters on `item-text` (`name (clNr)`) so a fragment of the
  name *or* the `cl_nr` matches and **nothing matches on `id`** — the System-Client case must be selected,
  not typed; `clearable` replaces the sentinel row, so clearing sets the model to `null`; and `shippers`
  carries **no** "All Shippers" entry.
- **Two spin-off tickets filed by the orchestrator.** §10.4 items 1+5 (the two live truthiness bugs on other
  screens) and item 3 (`getDetailViewByKeyword`'s non-indexable predicate) are converted from proposals to
  **references**, with an explicit statement that this plan does not carry them and no §5.2 phase touches
  them. The IDs landed before the pass closed and are in §10.4: **SBDEV-3437** (the truthiness guards,
  absorbing round 3's items 1 and 5) and **SBDEV-3436** (the non-indexable `getDetailViewByKeyword`
  predicate, item 3), both priority high on the Fulfillment Development Backlog and both naming SBDEV-3410
  as where they were found.

**Length — the architect's two cuts taken in full, and the number missed on purpose.**

| Move | Lines |
|---|---|
| `## Revision log` → `SBDEV-3410-evidence/revision-log.md` (this file), 3-line pointer left | **−93** |
| §3.1's SQL → `SBDEV-3410-evidence/V2.2.33__stockrecord_view.sql`, a real file the implementer copies; all **three** statements in one artefact (view + index + `DO $$` assertion), with the CRC32 proof-read warning and the corrected *71 shared strings / 87 excess rows* figure in its header | **−124** |
| §10.4's filed items compressed to one-line references | −3 |

**2,044 → 1,905 (−139 net).** The architect's target was ~1,850 and it is missed by 55 lines, **because the
required additions cost more than the cuts saved**: the `_embedded` measurement and its four corrected
surfaces, the renamed-rel Jest case, the re-pointed mutation row, the three `<v-autocomplete>` behaviour
consequences, the quoted `NATIVE_KEYWORD_CLAUSE`, and the `BillofladingTransferIdNotNullIT` recipe. **Nothing
was trimmed to reach a number**, per the instruction; the remaining content is load-bearing and the row says
so rather than rounding.

**One thing this pass did NOT do.** The `_embedded` measurement is MockMvc in the application's own context,
not a request to a deployed dev or prd server. HAL serialisation sits above JDBC and no `HalConfiguration` /
`LinkRelationProvider` / `RelProvider` bean exists in `src/main` (positive control: `exposeIdsFor` → 2 hits),
so a deployed server could differ only through a bean this build does not have — but that asymmetry is
recorded in the measurement file's blind-spot list rather than argued away.

### Round 3 — 2026-09-18 (planner lane, after the round-2 architect and critic reviews)

**architect r2 — SOUND-WITH-CHANGES** (3 blocking + 2 low) and **critic r2 — ITERATE** (4 blocking). Neither
asked for a rewrite. Both reviews landed on `_embedded` independently, and that item is resolved once rather
than twice. Status is `pending approval`, unchanged.

**⚠ Revision history now lives here and nowhere else.** Round 2 narrated its own corrections inline across
§3 (64 "round 2" mentions, eight of them multi-paragraph "what the previous draft said" passages). Those are
converted to direct statements of the corrected fact; the corrections themselves are all kept. An implementer
reading §3 should not have to separate "what to build" from "what an earlier draft said".

| Finding | Severity | Verdict | What moved |
|---|---|---|---|
| **B-1 / C-1 is unfixed** — `:filter="shipper == null ? -1 : shipper"` maps `null → -1` and leaves `0` alone; the falsy collapse is downstream *inside* `exportReport.vue` | HIGH | **Accepted, reproduced by execution** | Re-derived with `node -e` over the guard quoted from `origin/develop`, across `{null, 0, 60500}`, for all three candidate bindings. The reviewer's table reproduces exactly: the round-2 fix and the mutant are **byte-identical on `0`**. Fix is **`:filter="String(shipper == null ? -1 : shipper)"`** — `"0"` is truthy, survives the guard, `toFilterId("0")` → `0L`. §3.6 now carries the executed table; the binding is corrected at **all nine** sites (§0.2 row 28, §3.6 ×2, §3.9, §4, §5.2 P6 ×2, §7.8, AC-2). §7.8's row is re-pointed at a mutant that kills (**drop the `String(...)`**, not `→ :filter="shipper"`, which cannot), and §7.4 now says the assertion is on the **emitted POST body**, never the prop. **Option B (widen the shared guard) is recorded with its measured blast radius of nil** — the reviewer is right that it is safe; it is still not taken, and the reason is stated rather than the old unexamined caution |
| **B-2 / A-R2-1 `_embedded` is ABSENT on a zero-row page** | HIGH | **Accepted; both lanes confirmed independently** | §3.9 gains item 4 and an absence-tolerant `rowsOf`/`countOf` accessor copied from `store/admin/group.js`, with the asymmetry stated (missing `_embedded` → `[]`; `_embedded` **without the rel** → throw, because that is a renamed `collectionResourceRel`, not a zero). Four surfaces gain the case: `StockrecordViewRepositoryFilterIT.clientWithNoRowsReturnsAnEmptyPage`, a Jest zero-row case with the fixture shape spelled out (**no `_embedded` key at all** — `_embedded: { stockrecordView: [] }` does not reproduce it), a §7.8 mutation row (⚠ assert on committed state: the store's own `catch` swallows the `TypeError`), and a §7.7 manual row **run on hydra PRD, not dev** — dev cannot reproduce it, because System-Client owns 16 rows there and 0 on prd |
| **B-3 AC-1's wire contract contradicts §3.9** | MEDIUM | **Accepted; the design was right and the AC was wrong** | AC-1 restated to grade the **route** as well as the parameter: "All Shippers" targets `findByKeyword` and carries **no `clientId`**; shipper *N* targets `findByKeywordAndClient` with `&clientId=N`. That is the critic's stronger option, and it is the one the split makes correct — the unfiltered method has no `clientId` parameter, so `&clientId=-1` there would be an inert string SDR discards. The `-1` sentinel is explicitly relocated to the store's state and the export body. §3.9's "for both branches" wording and §7.4 follow |
| **B-4 the index-condition mutant cannot kill** | MEDIUM | **Accepted, and the prescription was verified before adopting** | The repo's only EXPLAIN precedent (`OutboxClaimExplainIT`) hand-copies its SQL into a constant, so the mutant's edit to the `@Query` never reaches it. New **surefire** test `StockrecordViewRepositoryQueryShapeUnitTest.queryShapeForbidsADisjunction`, on the repo's own idiom (`StockrecordRepositoryAdjustmentAlertQueryTest` already does `getAnnotation(Query.class).value()`). ⚠ **The reviewer's literal prescription `assertThat(jpql).doesNotContain(" OR ")` would be wrong** — the keyword arm legitimately carries a lower-case ` or :keyword = ''`, so a whole-string scan either reds on correct code or passes vacuously. Corrected to *slice at the `clientId` conjunct, then upper-case the tail*, and **executed** against the correct text and **five** mutants (3-arm `OR`, un-parenthesised tail, the `COALESCE` sibling form, conjunct deleted, lower-case `or`): green once, red five times. `filteredSearchKeepsAnIndexCondition` is kept for what it does grade, with §1.4's `enable_seqscan = off` discrimination recorded so nobody removes the control as unproven |
| **A-R2-2 the filtered export's plan is unmeasured** | MEDIUM | **Accepted** | §3.2 gains the architect's measured export plan (`Index Cond` survives, but a `Sort (Sort Key: created DESC)` on a **1,560× row underestimate**) and states that the open question is index *selection*, not reachability. P1's re-measurement bullet now covers **both** shapes, with **"the `Sort` node is gone"** as the export's acceptance — and says explicitly that a planner that keeps the narrow index plus the sort is a finding for the ticket, not something to leave unrecorded |
| **A-R2-4 the `CONCAT` clause is duplicated across the split** | MEDIUM | **Accepted, the cheaper option, and extended** | One `KEYWORD_CLAUSE` constant concatenated into both `@Query` values, on the repo's own precedent `FixLocationAssignmentRepository.REFILL_ELIGIBILITY_FROM_WHERE`. **Extended to §3.6's native pair too** (`NATIVE_KEYWORD_CLAUSE`), which has the same hazard and neither review named — invariant, not instance. Verified it composes with B-4: a `String` constant is a compile-time constant expression, so the annotation carries the folded text and reflection still sees the whole string (re-executed against the final text). §3.10's "widen the keyword search" row now names the two constants as the edit point |
| **A-R2-3 `SDR_WRITE_WITHDRAWN` "for parity", F4's fourth copy** | LOW | **Accepted** | §7.5 row 5 restated as required-not-parity with the reason (`ReadOnlyPagingAndSortingRepository` suppresses only `save`/`saveAll`). Swept for the **literal** "parity", not the symbol |
| **A-R2-5 §0.1 row 21's "no edit needed" is false** | LOW | **Accepted — and both reviews undercounted** | Both lanes said five call sites (4 + 1). The real figure, by `git grep -n '\.exportStockUnitRecord(' origin/develop -- src/test`, is **11 in 2 files**: `ReportServiceUnitTest` **4** (443/474/488/522) and `ReportControllerUnitTest` **7** (387/395/407/415/428/436/452 — four `when(...)` and three `verify(...)`, not one). A third file, `ReportReadGateUnitTest`, references only the route string and does not break. Row 21, §3.6's compile-break sentence, §4 and P3's checklist all corrected |
| **N-2** the HAL test's fixture is "none" in an H2 lane | LOW-MED | **Accepted** | §7.3 and §7.8 now state the lane (`ddl-auto=create-drop`, `flyway.enabled=false` → an empty Hibernate table, not the migrated view), the fix (seed one row in `@BeforeEach` and **flush**, because the base class is `@Transactional("tenantTransactionManager")`), and the trap (weakening to `status().isOk()` un-kills the mutant) |
| **N-3** `constraintIsAsserted` feasibility + assertion form | LOW-MED | **Accepted** | §7.2 names the `Flyway.configure().target("2.2.32")` recipe and the eight ITs that already use it, so nobody concludes the case is unwritable; and requires asserting **SQLSTATE P0001**, because Flyway's message quotes the script filename and a text match passes for any failure of that script |
| **N-4** the guard sweep's enumeration is incomplete | LOW | **Accepted** | Three sites added (`replenishments.js` ×2 — already correct; `outboundParcel.js` — a `\|\|` fold on a String, unreachable; `cycleCount.js` — **a second expression shape** in a file already listed). None changes a verdict, which is stated as such. §10.4 item 1 now says Cycle Count carries the defect at **two expressions**, so it is not half-fixed |
| **Length** | — | **~160 lines cut, ~215 added** | Cut: `RALPLAN-DR` moved to `SBDEV-3410-evidence/ralplan-dr.md` (**−103**, nothing in §5.2 pointed at it); §2 halved to the two subsections §3 depends on (**−17**); §7.6's seven pure-"No" rows compressed to a paragraph; ~25 inline round-2 narration passages converted to direct statements. **No measurement content removed.** Added: the executed truth table, the `_embedded` accessor and its four test surfaces, the query-shape test, the export plan, AC-1, the two clause constants, N-2/N-3/N-4 and the 11-call-site correction. **Net: 1,985 → 2,042 (+57). The ~330-line reduction was NOT achieved, and this row says so rather than rounding.** The target was set against the round-2 document, before round 3's required additions. The two structural cuts the architect named were taken in full (RALPLAN-DR out, §2 halved); the third — the inline narration, called the highest-value cut — yielded far less than its 64 mentions suggest, because most were a *clause* framing a fact both reviewers verified, not a deletable paragraph, and the fact has to stay. **The remaining fat is not narration; it is content.** §3.1's 80-line SQL header (the artefact that ships, CRC-locked once applied), §3.1's 24-column `SELECT` (what §3.3 maps and `everyMappedColumnResolves` grades), §3.5's six-rail table (M-6's resolution) and §3.8's derivation are the four largest remaining blocks, and each was checked for redundancy and found not to have any. If the document must be shorter, the decision to take is **which of those four moves to `SBDEV-3410-evidence/`** — a question for Nam, not one to settle by trimming until the number is met |

**Two review prescriptions not adopted verbatim, both with evidence.** (1) The critic's
`assertThat(jpql).doesNotContain(" OR ")` — wrong against the keyword arm's lower-case `or`; corrected form
above, executed. (2) Both lanes' "five call sites" — the enumeration is 11; the finding's direction is right
and its count was not. Each is recorded rather than silently corrected, because a reviewer who reads the
next round should see that the count moved and why.

**Open for Nam, unchanged from round 2:** (1) `<v-select>` or `<v-autocomplete>` (§3.9) — either satisfies
AC-1; (2) the §10.4 proposals, ranked, item 1 (the live Cycle Count truthiness bug, now known to be **two**
expressions) recommended first; (3) Q5 and Q6, both correctly left open.


### Round 2 — 2026-09-18 (planner lane, after the architect and critic reviews)

*Kept for provenance. Where round 3 supersedes a row, the row says so inline.*

Two independent reviews landed: **architect — SOUND-WITH-CHANGES** (7 required, 2 recommended) and
**critic — ITERATE** (3 blocking, 7 medium, 6 drifted claims). This is the only point at which they were
combined. Every finding below was **re-derived with my own instruments before being acted on**; nothing was
taken on a reviewer's word. Status is `pending approval`, unchanged.

**Where the two reviews touched the same ground, they are resolved once, not twice.** A-1 (the predicate is
not indexable) and C-2 (the export predicate drops the `IS NULL` arm) are the **same defect in two places**,
and adding the `IS NULL` arm — C-2's literal fix — would have re-created A-1 on the export path. Both are
resolved by the **same move**: split each method into an unfiltered and a filtered variant with a plain
equality, so no `OR` arm exists on either path and `findByOffsetAndLimit` keeps its exact signature. That is
also why §6 can still say "No breaking" for that route, and why `ReportServiceUnitTest`'s four existing stubs
still compile.

| Finding | Severity | Verdict | What moved |
|---|---|---|---|
| **A-1** three-valued `OR` makes the index unreachable | HIGH | **Accepted, reproduced** | §3.4 rewritten: `findByKeyword` + `findByKeywordAndClient`. Paired control re-run by me under `force_generic_plan`: `= $1` → `Index Cond`; the 3-arm `OR` **and** the sibling's `COALESCE` 2-arm form → `Parallel Seq Scan`. Both plan modes now recorded (§3.2). New IT `filteredSearchKeepsAnIndexCondition` + a mutation row. **0.455 ms re-labelled custom-plan/literal**; P1 must re-measure under a generic plan once the index exists — I could not (`hypopg` absent, control: 61 extensions; building a 276 MB index is a mutation) |
| **C-1** `client.id = 0` is a real shipper | HIGH | **Accepted, reproduced** | Confirmed: `min(id)` = 0 = `System-Client`, 16 `stockrecord` rows on dev, present on **5/5** reachable DBs incl. prd (53 unit loads). §3.6 rewritten with a **ten-site guard sweep** naming every `clientId`/`filter` absence check in both repos and its verdict. Fix was `:filter="shipper == null ? -1 : shipper"` in the one component, not a change to the 9-caller `exportReport.vue` — ⚠ **superseded in round 3: that fold does not survive the guard for `0` (see B-1 above); the shipped form is `String(shipper == null ? -1 : shipper)`**. AC-2 gains the value matrix with the `0` row; new Jest case, new manual row, new mutation row |
| **C-2** export predicate drops `IS NULL` on an exported route | HIGH | **Accepted, reproduced** | Verified `findByOffsetAndLimit` has no `exported = false`, and the proposed predicate with `NULL` returns **0** where the unfiltered query returns 873,021. Resolved jointly with A-1 by the split; §6 gains **three** rows |
| **C-3** §0 sweep scoped too narrowly | HIGH (process) | **Accepted, reproduced** | Repo-wide `getClients` → **26 sites / 15 files**, not 7. `handlingUnits/{containerTable,stockUnitsTable}` + their stores are now the **primary** reference (§0 rows 37–40); `inventoryReport` demoted. **Q1's "accepted cost" corrected: there is no divergence** — `clientId` + `-1` + `toFilterId` is the convention, and I found it on the API side too (`StockUnitController#getDetailView`). §9.4's price corrected with it |
| **F2** join-elimination protection is prose | HIGH | **Accepted** | `V2.2.33` gains a **third statement** asserting `UNIQUE (client_id, item_nr)` on the column set (not the generated name); new IT `constraintIsAsserted` + mutation row; prereq 8 gains the constraint check |
| **F3** a drifted view has no detector | MEDIUM | **Accepted** | SQL header states it, with what `validate` does and does not see |
| **F4** `SDR_WRITE_WITHDRAWN` is load-bearing | MEDIUM | **Accepted** | Re-labelled required; I read `ReadOnlyPagingAndSortingRepository` in full (26 lines) — only `save`/`saveAll` suppressed, delete verbs exported |
| **F5 / F6** tenant coverage + per-env index cost | MEDIUM | **Accepted, reproduced** | All three prd aliases → `wh01_hydra_v2` @ 172.18.0.3, verified by me. Per-environment size table measured across 5 DBs (dev 9.7 M / 2,196 MB … prd hydra 3,373 / 728 kB, ÷2,884). Prereq 1, §3.2, §6, §7.7 and Q6 all restated; recorded as an instrument blind spot in §10.3 |
| **F7** SDR count missing from the cost model | MEDIUM | **Accepted, reproduced** | Measured 1,743 ms in my lane vs the architect's 602 ms, `Heap Fetches: 873021` — 0.6–1.7 s across two runs. §3.2 gains it; §7.7's "well under a second" replaced with ~1–2 s dominated by the count |
| **F8** "preserves that asymmetry exactly" | MEDIUM (recommended) | **Taken** | True of the rule count, false of the payload. §3.5 and §6 restated: no new *enforcement* gap (read guard OFF everywhere measured), but a real payload widening, and the rule belongs on SBDEV-3222/3183 |
| **F9 / S3** phase boundaries and revert order | LOW-MED | **Accepted** | Prereq 4 gains P6-before-P2 = blank report; rollout step 5 gates on `/api/public/version`; §8 states **P6 reverts first** |
| **F10** `@Id` safety should carry its condition | LOW (recommended) | **Taken** | §3.3 rule 1 names the constraint and the real symptom (deduplicated `content` vs inflated `totalElements`) |
| **AC-1…AC-4 not encodable** | blocking | **Accepted** | All four rewritten as assertions: AC-1 gains the wire contract, AC-2 the value matrix, AC-3 the unresolved-SKU clause, AC-4 the **named** `totalElements` regression and its four combinations |
| **M-1** `ClassCastException` failure shape | MEDIUM | **Accepted, reproduced** | All 7 `(String) reqMap.get("filter")` reads verified above their `try {` (lines 66/93/…/229 vs 72/100/…/235). Restated as a thrown CCE / nested `ServletException`, not a 200. Sibling note corrected: `exportContainerRecord` has a second catch too |
| **M-2** invariant asserted, not applied | MEDIUM | **Accepted** | P5 goes **eleven → fourteen**. Derivation of the gap set from `appMenuList.js` recorded, with its blind spot |
| **M-3** the computed mutant cannot kill | MEDIUM | **Accepted** | Assertion changed to `'shipper' in $data`; the reason is recorded so it is not "simplified" back |
| **M-4** `exposeIdsFor` mutant has no test | MEDIUM | **Accepted** | New `StockrecordViewHalContextTest` in the MockMvc lane `SdrReadGateEnforcementContextTest` already uses (surefire, `*ContextTest`) |
| **M-5** existing rails mis-grade one mutant | MEDIUM | **Accepted** | Column mutant **dropped** as unattributable; `everyMappedColumnResolves` re-justified on the "stops at the first mismatch" gap; both rails cited |
| **M-6** `SdrWriteWithdrawalContextTest` omission is silent | MEDIUM | **Accepted** | Named as an explicit P2 task (§0 row 6a); the six SDR rails checked and tabulated so nobody re-checks them |
| **M-7** P1→P2 is a build-order dependency | MEDIUM | **Accepted** | Prereq 4 and P2's preamble both say branch after P1 merges |
| **Drifted claims ×6** | — | **All corrected** | **#1 "87 SKU strings" → 71 strings / 87 excess rows**, fixed in the prose **and in the CRC-locked SQL header**, re-measured by me — this was the urgent one · #2 22-key map → 22+2 conditional · #3 `StockView` 12 fields / 11 `@Column(name=…)` · #4 `V2.2.11` is **not** burned (the README is stale) · #5 "six" sibling reports → **seven** · #6 "40 remote refs" → **310** (conclusion unaffected) |
| **Length** | — | **~200 lines of duplication cut** | §3.1 prose→header pointer (~55) · §9.1/9.2/9.4 → RALPLAN-DR pointers (~45) · §0's sixteen "NO" rows → one paragraph (~30) · §7.1 repo-wide lane facts (~20). **No measurement content was removed.** The added content (the guard sweep, the plan-mode table, the per-env sizes, the AC rewrites) roughly offsets it |

**One review claim I did not simply adopt.** The critic proposed withdrawing `findByOffsetAndLimit` from SDR
as the preferred fix for C-2. I did not, because the split makes it unnecessary — the route's behaviour is
now provably unchanged — and withdrawing it is an independent contract change that belongs with Q5, where
the repo's own rail (`SdrUncalledSurfaceNotExportedContextTest`'s message) already states the default. Both
are recorded rather than silently merged.

**New in round 2, not from either review:** §3.4's measurement that the **sibling convention's own predicate**
(`COALESCE(…) = -1 OR …`) carries the identical generic-plan hazard — which is what turns the split from a
reviewer preference into a documented divergence with a reason; §3.9's `<v-select>` vs `<v-autocomplete>`
decision, reopened against measured shipper counts (125–164 across four environments, all past the sibling's
stated threshold) and **flagged for Nam**; the six-rail SDR ratchet check (§3.5); and §10.4's five proposed
follow-ups, ranked.

**Open for Nam, both new:** (1) `<v-select>` or `<v-autocomplete>` (§3.9) — either satisfies AC-1; (2) the
§10.4 proposals, ranked, with item 1 (the live Cycle Count truthiness bug) recommended first.
