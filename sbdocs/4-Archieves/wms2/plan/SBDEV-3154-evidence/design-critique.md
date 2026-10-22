# SBDEV-3154 — design-critique lane

Lane: APPROACH + TEST STRATEGY only. Facts, migration mechanics and authorization reach are other lanes'.
Everything below derived from `origin/develop` **`2e9ddcfa`** (wms2-api) and `origin/develop` (wms2-web-ui) via
`git show` / `git grep`, plus read-only SQL on all six v2 tenant DBs. No worktree, no maven, no file edits
outside this directory.

**Verdict: BLOCK.** Two Critical findings. The plan's central instrument (two new seeded function rows) is
the instrument its own parent ticket rejected twice, and I measured that the cheaper instrument produces an
**identical user population on all six tenants**. The migration, the T3 tier and roughly half the plan buy
nothing. Separately, the plan's risk model rests on "no menu entry and no UI caller", which is false — there
are six live buttons.

---

## C1 — CRITICAL. A new function constant is the wrong instrument, and the cheap one is population-identical

**Position: mint zero constants. Gate all four routes on the existing `WEB_UI_VIEW_IMPORT_DATA`.**
That deletes `V2.2.23` entirely, deletes §2 (its whole 2.1/2.2/2.3), deletes AC-1's INSERT clause, AC-3 and
AC-6, and drops the tier T3 → T2.

### The rule already exists and Nam set it twice

`SBDEV-3017-B1` §9.16 (Nam, 2026-08-27, "Option **B**"): *each site takes the function that already gates the
screen it is reached from. No new constant is created.* §9.16.2 records that this is not a shortcut but the
already-established rule — §9.15 decision 4 sent `ItemDataController:105` onto existing
`WEB_UI_VIEW_ITEM_DATA`, R6 gated `ShipperIdController` on `WEB_UI_VIEW_CLIENT`. §9.17 then traced the
consequence and struck the migration: *"R8 creates zero new constants … ⇒ `V2.2.22` is not needed at all …
⇒ The tier drops."*

§9.17.1 names one of this plan's two constants explicitly as having **fallen out**:

| §2.3 constant | §9.17.1's disposition |
|---|---|
| `WEB_UI_VIEW_SYSTEM_MANAGEMENT` | dropped — "it existed for class-level defaults on `AdminActionController` … both are now in the STAY set" |

SBDEV-3154 revives it, renamed `WEB_UI_ACTION_SYSTEM_MANAGEMENT`, and does not engage §9.16/§9.17 anywhere.
The plan's `related:` frontmatter cites the parent, so this is an omission, not an unavailable source.

### The screen, and its existing constant

The four routes are dispatched from **Admin → System Management → Actions**:

- `wms2-web-ui/components/admin/systemManagement/actions.vue:10,16,22,34,40` — six `v-btn`s
- → `components/admin/systemManagement/actionConfirmation.vue:65,68,71,76`
- → `store/admin/mgmt/action.js:17,27,37,47,63,74` — the six axios calls

That pane's gate is a single existing constant:

- `pages/admin.vue:56` — `{ text: 'System Management', fn: 'WEB_UI_VIEW_IMPORT_DATA', … }`
- `util/appMenuList.js:132` — `'WEB_UI_VIEW_IMPORT_DATA', // System Management`
- pinned by `wms2-web-ui/test/pages/admin.spec.js`

So the screen's own constant — the one §9.16 mandates — is **`WEB_UI_VIEW_IMPORT_DATA`**, which exists in
`FunctionEnum` today and has a `mywms_function` row on every tenant.

### Measured: the two options reach the same users, everywhere

Counted by USER population through `mywms_group_mywms_role` → `mywms_group_mywms_user` (AC-2′ axis, not by
role name), 2026-09-01, all six tenant DBs. Note the join columns are `rolelist_id` / `functionlist_id` /
`grouplist_id` / `userlist_id`, and I verified empirically that `rolelist_id` resolves against `mywms_role`
(335/335) and not against `mywms_function` (0/335) before trusting the direction:

| tenant DB | `WEB_UI_VIEW_IMPORT_DATA` users | roles holding it | plan's `super-admin` grant reach |
|---|---|---|---|
| `dev_wh01_om1` (WineCo dev) | 37 | super-admin **only** | 37 |
| `wh01_om1_v2` (WineCo UAT) | 35 | super-admin only | 35 |
| `wh01_hydra_v2` (Hydra **PRD**) | 7 | super-admin only | 7 |
| `wh01_hydra_v2` (Hydra UAT server) | 15 | super-admin only | 15 |
| `wh01_shipitez_v2` (c1wh UAT) | 23 | super-admin only | 23 |
| `wh02_shipitez_v2` (nywh UAT) | 9 | super-admin only | 9 |

126 either way — the plan's own fleet total. **The migration changes the reachable population by zero users
on every tenant that exists.** §9.16.1's invariant then holds trivially, as it did for the putaway tiers:
anyone who can open the pane already holds the gate.

### The honest counter-argument, stated so Nam can overrule me

`WEB_UI_VIEW_IMPORT_DATA` is *delegable* in a way a fresh super-admin-only row is not: a tenant could later
grant the CSV-import tab to a data-entry role, and that role would then also hold "Manual Allocation" and
"Test CRM Connectivity". If Nam wants those permanently separable from the import tab, a distinct constant is
the right instrument. But note that buying that separation **requires UI work this plan explicitly excludes**
(§6.4) — see C2 — so as scoped, the constant buys the separation only in the form of visible buttons that
403. Recommend Option B; if Nam wants the separation, the ticket grows a UI slice and should say so.

**Ruled out, so the next round does not spend time on it:** `@PreAuthorize(Authority.IS_SB_ADMIN)`, the
in-file precedent five lines below at `AdminActionController:341` (`accessAudit`). Retired by decision —
SBDEV-3017 §8.15 (Nam, 2026-08-26): Keycloak carries coarse access only and *no business endpoint may gate on
`wms_admin` or `sb_admin`*.

**Recommendation.** Rewrite §1's table onto `WEB_UI_VIEW_IMPORT_DATA`; delete §2 entirely; delete AC-1's
migration half, AC-3 and AC-6; re-tier to T2 (2 lanes, gate, no verify script) citing §9.17's precedent for
the identical re-tier; retitle (the current title asserts the deliverable that is being deleted).

---

## C2 — CRITICAL. Over-gating is a live regression, and §6.1's mitigation rests on a false premise

§6.1 and §2.2 both lean on *"the console has no menu entry and no UI caller"*. Measured, it has six buttons
and a modal, all with live store actions (citations in C1). §6.4 compounds it: *"the constants are
deliberately not added to `wms2-web-ui util/appMenuList.js` — there is no menu entry to gate."* There is a
menu entry: `appMenuList.js:128-133` row 30 (`/admin`), an ANY-of its seven tab functions, `IMPORT_DATA`
among them.

The consequence is not a residual risk, it is the shipped behaviour. `actions.vue` has **no per-button
function check** — no `hasFunction`, no `require-function` — so every button renders enabled for anyone who
can open the pane. Under the plan's design (four routes on new constants granted only to `super-admin`), any
user who holds `WEB_UI_VIEW_IMPORT_DATA` but not `super-admin` sees six enabled buttons and gets a 403 toast
on four of them. Today that set is empty on all six tenants (C1's table) — which is precisely why nobody will
notice the design is wrong until a tenant delegates the import tab, at which point the console breaks with no
signal other than a toast.

Under C1's Option B the class of defect cannot exist: the API gate *is* the screen gate.

**Recommendation.** Delete the "no menu entry / no UI caller" claim wherever it appears (§2.2, §6.1, §6.4)
and re-derive the risk paragraph from the six buttons. If C1 is rejected and constants are minted anyway, the
ticket must grow a UI slice adding a per-button function check — otherwise it ships buttons that 403, which is
the exact silent-failure shape SBDEV-3017 §9.26/R15 exists to prevent.

---

## H1 — HIGH. AC-4's instrument cannot fail on denial, and the sibling ticket's own precedent is missing

Read `Sbdev3017TrancheGateContextTest` end to end (410 lines). Its single substantive assertion compares
`resolve(hm)` — `AnnotatedElementUtils.findMergedAnnotation` on method then declaring class, lines 282-289 —
against a static `EXPECTED` map. There is **no HTTP request, no principal, no `AccessService`, no 403**. It is
an annotation-presence-and-identity pin over the deployed mapping, and its own javadoc says so: *"What this
slice adds is **data** — which constant sits on which route — and the failure mode that actually threatens it
is **drift**."* The 403 mechanism it defers to is `FunctionGateEnforcementPointContextTest`, which states in
its own javadoc that it *"asserts **reach and arity**, not denial."*

So the parent's AC — *a caller denied the function receives 403* — is not closed by extending this pin, and
the plan's AC-4 reads stronger than it is. §4.3 is admirably honest about the migration and about `GUARDED`,
but it does not list denial itself among the things no test here can see.

Two further gaps the plan does not name:

1. **`AdminActionControllerUnitTest` is guard-less.** `src/test/java/net/aim_ai/wms/unit/controller/AdminActionControllerUnitTest.java:106` calls `setupMockMvc(controller)`, not `setupMockMvcWithGuard`. Its five existing tests assert 200 on exactly the routes this ticket gates, and they will keep passing after the annotations land — i.e. the repo's only behavioural coverage of these four routes is coverage that is *blind* to the gate. `ReportReadGateUnitTest`'s javadoc calls this out as the SBDEV-2863 failure mode: *"Plain `standaloneSetup` installs no interceptor, so a gate test written on it passes whether or not any gate exists."*
2. **The affordable instrument already exists, from the immediately preceding sibling ticket.** SBDEV-3142 shipped `src/test/java/net/aim_ai/wms/unit/controller/ReportReadGateUnitTest.java` (571 lines) using `BaseControllerUnitTest.setupMockMvcWithGuard(controller, interceptor)` (base class lines 95-104) with a real `FunctionGuardInterceptor` over a stubbed `AccessService`, asserting **403 specifically** on the deny path *and* pinning which function by reflection. Its javadoc explains why both halves are needed: a status assertion proves only that *a* gate exists (a reviewer swapped one constant and 34 tests stayed green), and a reflection pin proves only that an annotation is present.

**Recommendation.** Keep the `Sbdev3017TrancheGateContextTest` extension (it is the right ratchet for *which*
constant), and add the missing half: switch `AdminActionControllerUnitTest` to `setupMockMvcWithGuard` with
`allowEverything()` for its five existing cases, then add four deny cases asserting 403 and four allow cases
asserting 200. That is ~60 lines against an existing class with an existing in-repo template — cheap, and it
is what makes the parent's AC true rather than asserted. Restate AC-4 as two instruments.

---

## H2 — HIGH. The migration's failure mode is total denial, and the plan does not name it

`AccessService.checkAnyAccess` (lines 134-159) is a pure string-membership test:
`userRepository.getAllRoles(username).contains(function)`. A `@RequiresFunction` naming a constant with **no
`mywms_function` row** is therefore held by nobody — `MISSING_FUNCTION` → 403 for **every** caller, super-admin
included. `FunctionGuardInterceptor:243-264` confirms there is no unknown-function branch and no fail-open.

The plan already knows two of the three facts and does not join them: §4.3 says *"a clean Flyway run is not
proof. Tenant migration failures never abort boot"*, and §2.3 says five of six tenants still owe `V2.2.22`.
Joined: if `V2.2.23` fails on a tenant, that tenant boots the gated code with no function rows and the
operator console goes **completely dark for all users**, with the only signal a `wms2.authz.denied` counter and
a per-request WARN. This is not hypothetical on this fleet — tenant object-ownership drift has already frozen
a PRD tenant's Flyway chain at `V2.2.06`.

Under C1's Option B this failure mode does not exist, because `WEB_UI_VIEW_IMPORT_DATA` already has a row on
all six tenants (measured, C1's table).

**Recommendation.** If the migration survives C1, §6 must carry this as a named risk with the rollback
(revert the four annotations, not the migration), and AC-3 must be a **blocking pre-promotion gate** per
tenant, not a post-deploy check. Better: adopt C1 and the risk disappears.

---

## H3 — HIGH. §7's out-of-scope boundary is drawn on ticket lineage, not on cost, and it splits one modal

§7 justifies leaving four siblings ungated with *"it needs its own constants, its own migration and its own
tier assessment."* Under this plan's own design that is factually wrong: C31-C33 **share** one constant, so
adding `triggerUpdateStock` to that annotation set costs **zero** new constants and **zero** extra migration.
Under C1's Option B it costs zero for all four.

What the boundary actually produces:

| console button / call | after 3154 |
|---|---|
| Manual Allocation / Replenishment | gated (C31) |
| **Manual Full Stock Update** → `triggerUpdateStock` → `StockSummaryExportJob` | **open to any `wms_user`** |
| Archive Old Messages | gated (C32) |
| Test SiteBossOWL Connectivity | gated (C33) |
| Recover Stuck Pallets → **modal list** `listRecoverableStuckPallets` | **open** |
| Recover Stuck Pallets → **confirm** `recoverStuckPallets` | gated (C30) |

Two specific harms:

1. **The modal is split-brained.** `recoverStuckPallets.vue:135` loads the list, `:148` posts the recovery. An operator lacking the new function opens the modal, sees the stuck-pallet list populate normally, selects pallets, clicks Recover, and gets a toast. That is exactly the "unexplainable state" the parent plan warned about — and it is strictly worse than gating both or neither.
2. **Risk ordering is inverted.** The one left open, `triggerUpdateStock`, fires a full stock export to OMS — plausibly the highest-consequence of the six — while the CRM connectivity *ping* gets gated.

`finishStuckPickingOrder` has no UI caller (grep over both UIs' `origin/develop`), so it is a defensible
API-only exclusion; the other three are not.

**Recommendation.** Extend scope to `triggerUpdateStock` and `listRecoverableStuckPallets` in this PR — under
C1 that is two more annotations and nothing else. Keep `finishStuckPickingOrder` out and say *why* (no UI
caller, distinct blast radius), not "it was not in §1's slice".

---

## M1 — MEDIUM. §1.1(b)'s stated justification is false as measured

§1.1(b) justifies `ACTION_` over `VIEW_` with *"in this codebase `VIEW_*` is granted far more freely than
`ACTION_*`."* Measured on `dev_wh01_om1`, by user population:

| family | constants | min users | avg users | max users |
|---|---|---|---|---|
| `WEB_UI_ACTION_*` | 8 | 37 | **41** | 43 |
| `WEB_UI_VIEW_*` | 58 | 37 | **42** | 46 |

The families are indistinguishable. `WEB_UI_ACTION_PRINT_TOTE_LABELS` = 37 (super-admin only) — identical to
`WEB_UI_VIEW_IMPORT_DATA`, `_CLIENT` and `_SYSTEM_PROPERTY`.

It also contradicts a finding the parent already checked rather than assumed. §9.16.2: *"using a
`WEB_UI_VIEW_*` constant to gate a write looks like a convention break, but review lane 2 verified on R6 that
`WEB_UI_VIEW_*` constants name **screens**, not entities and not read-only-ness."* And
`Sbdev3017TrancheGateContextTest`'s own comment above the `GoodsReceiptPosition` rows records this exact class
of error being corrected once already: *"NOT for §0.G's stated reason, which is a role-name claim and is
false … The real reason is caller-based."*

The naming preference may still be right. The *argument* is not, and it is flagged as load-bearing ("both
load-bearing", "This mattered now rather than later"), so it will be cited later as settled.

**Recommendation.** If C1 is rejected and one constant is minted, justify the name as a naming convention and
say so, or drop the paragraph. Do not carry a measured-false premise forward as a correction.

---

## M2 — MEDIUM. Two constants is the wrong split axis, if any are minted

Asked directly: **argue against the 1+3 split.** Two reasons.

1. **The grouping tracks ticket scope, not privilege.** C31-C33 are grouped as "job triggers", yet the fourth job trigger on the same pane (`triggerUpdateStock`) is excluded (H3). A grouping whose boundary is the ticket's slice list, not a privilege boundary, will not survive the next slice — and by then the row is seeded on six tenants and, as the plan itself notes, cannot be renamed without a second migration plus a data fix.
2. **`WEB_UI_ACTION_SYSTEM_MANAGEMENT` creates a permanent two-names-for-one-screen trap.** The pane is `WEB_UI_VIEW_IMPORT_DATA` in `pages/admin.vue` and `appMenuList.js`; a second constant named after the same screen guarantees that a future reader gates the wrong half. `WEB_UI_VIEW_SYSTEM_MANAGEMENT` was already retired once for a related reason (§9.17.1).

If Nam wants a constant minted despite C1, mint **one** covering all six console actions (C30-C33 plus the two
in H3), not two. That is one INSERT — which incidentally removes §2.1's most dangerous bullet (the
two-separate-INSERTs / same-`MAX(id)` hazard) rather than mitigating it, the same argument §9.16.3 made in the
parent.

---

## M3 — MEDIUM. Sequencing: one PR is correct; a two-PR split does not buy the window it appears to buy

Asked directly. **Recommendation: one PR. Do not split.**

- **On dev**, the split is unavailable in a useful form: a merge to `develop` *is* the deploy and runs Flyway in the same artifact, so "grants land first" is at best minutes and at worst a same-build race.
- **On UAT/PRD**, code and migration ride the *same tag*, and Flyway runs at boot before traffic. A two-PR split in `develop` collapses to one artifact by the time it reaches an environment where the window would matter. It is slower and buys nothing.
- The window a split is supposed to protect against does not exist as feared: with only `super-admin` granted and (measured) that population identical to the existing screen constant's, no non-super-admin loses anything they have today. The real exposure is the **inverse** — migration *failure* leaving the gate live with no rows (H2) — and PR ordering cannot help with that. Only a per-tenant pre-promotion check can, which is why AC-3 should become blocking rather than post-deploy.

Under C1 the question is moot: no migration, one PR, nothing to sequence.

---

## Over-specification — paragraphs to cut (question 6)

Lows, but each is real maintenance:

- **L1. The Flyway version in the title and §1.** `SBDEV-3154-…: "… + Flyway V2.2.23"` plus §1.1(a)'s three-sentence derivation. This has **already gone stale once inside this ticket's own lifetime** (the ticket said `V2.2.22`), and §2.3 + AC-6 correctly say to re-run the collision script at merge. Asserting a specific version in a title guarantees the title is wrong again. Cut to "the next free version, determined by `check-migration-version-collision.sh` immediately before merge". (Moot under C1 — the whole line goes.)
- **L2. §2.1's eight-bullet hazard catalogue.** Every bullet is a restatement of `V2.2.19`/`V2.2.21` plus SBDEV-3017 §2.4. This repo has a measured history of exactly this: the parent's §9.14 records a table being deleted rather than corrected *because* multiple copies each read as authoritative and said opposite things. Replace with a pointer to `V2.2.19` STEP 1 plus the one file-specific line ("two rows ⇒ two separate INSERTs"). Delete outright under C1.
- **L3. §6.3, the `seqentities` id-island paragraph.** Four sentences that conclude "pre-existing, out of scope, not made worse here" — i.e. analysis with no action and no AC. Cut to one sentence or drop.
- **L4. §4.2's fourth mutant row.** *"add `AdminActionController` to `GUARDED` → covered elsewhere — state this explicitly, the pin does not see GUARDED membership."* A mutant whose expected kill is "elsewhere" is not a mutant; it is a note, and it is already made in §4.3. Delete the row, keep the §4.3 sentence. (Worth stating plainly: the boot assertion at `FunctionGuardStartupAssertion:74` means this mutant does not merely go unnoticed — the context refuses to start, so the pin cannot even load.)
- **L5. `tier:` frontmatter.** Re-derive after C1. The parent recorded the identical re-tier when its migration fell out (§9.17.1: *"⇒ The tier drops … That is **T2**"*). Carrying T3 forward costs four review lanes and an open-ended budget on what is four annotations.

## What I did NOT check (other lanes' scope, and stated so this is not read as a clean bill)

Flyway version freeness, the six-tenant row counts and `flyway_schema_history` state, the SQL's column/index
claims, and whether the four routes are reachable by a non-super-admin today over an equivalent SDR or MVC
sibling route (the SBDEV-3142 "closes zero datasets" hazard applies here too and the plan does not assess it).
