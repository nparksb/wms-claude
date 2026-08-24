# SBDEV-2968 re-review — pre-deploy audit SQL + V2.2.18 seed

status: COMPLETE
Reviewer: independent SQL review lane, 2026-08-21
Scope: commit `fa28026` in `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-2968`
- `src/main/resources/db/audit-access-invariants.sql`
- `src/main/resources/db/migration/V2.2.18__seed_mobile_workflow_functions.sql`

## Server fingerprints (established before trusting any query)

| MCP server | `current_database()` | users | funcs | roles | `mywms_role_mywms_function` rows | flyway head | rf PK/uniq |
|---|---|---|---|---|---|---|---|
| `wms2-hydra` (**PRD**) | `wh01_hydra_v2` | 9 | 80 | 9 | 143 | 2.2.16 | **0** |
| `wms2-hydra-uat` | `wh01_hydra_v2` | 19 | 80 | 14 | 148 | 2.2.17 | 1 (`..._pk`) |
| `wms2-wineco-dev` | `dev_wh01_om1` | 96 | 80 | 140 | 300 | 2.2.17 | 1 (`..._pkey`) |
| `wsl-wineco-uat` | `wh01_om1_v2` | 94 | — | — | — | — | 1 |
| `c1wh-shipitez-uat` | `wh01_shipitez_v2` | 36 | — | — | — | — | 1 |
| `nywh-shipitez-uat` | `wh02_shipitez_v2` | 11 | 80 | — | 143 | 2.2.17 | **0** |

prd and hydra-uat share the database *name* `wh01_hydra_v2` and are told apart only by user count / flyway head — the collision the brief warned about is real. All numbers below name the server they came from.

---

## F1 — Medium — the comment justifying `GROUP BY user_id` is factually false; `mywms_user.name` IS unique

**Proved by query.**
`audit-access-invariants.sql:125-126` and the verbatim duplicate at `:188-189`:

> `-- Grouped on user_id, NOT username: mywms_user.name carries no unique constraint in the base dump`

`V2.2.00__base_v2_schema.sql:3627-3628`:

```sql
ALTER TABLE ONLY public.mywms_user
    ADD CONSTRAINT uk_48pkipun1pytmies0wei11bhm UNIQUE (name);
```

Confirmed live: `uk_48pkipun1pytmies0wei11bhm UNIQUE (name)` present as both constraint and unique index on `wms2-wineco-dev`, `wms2-hydra-uat`; `contype='u'` count = 1 on `wms2-hydra` (prd) and `nywh-shipitez-uat`. No later migration drops it.

The **grouping itself is correct** (with `name` unique, grouping by `id` and by `name` are the same partition — it is not load-bearing, just harmless). The **rationale is wrong, and dangerously so in the other direction**: `UserRepository.java:27-33` — the query the runtime gate actually uses — resolves the caller by `where u.name = :username`. That is sound *only because* `UNIQUE (name)` exists. A comment of record asserting the constraint is absent invites someone to either "harden" `getAllRoles` against a non-problem, or to assume duplicate usernames are representable and write a migration that creates one. The same false claim is in the commit message.

**Failure scenario:** no runtime failure. The cost is a wrong fact in the two places (SQL comment ×2, commit message) that a future reviewer of the authorization chain will read first.
**Fix: comment-only.** Replace with: grouped on `user_id` because it is the join key; `mywms_user.name` is `UNIQUE` (`V2.2.00:3627`), which is also what makes `UserRepository.getAllRoles`' `u.name = :username` lookup single-valued.

---

## F2 — Medium — the header's case 1 is unsupportable. The brief's finding is CONFIRMED, and there is a second, independent reason

**Confirmed, proved by query.**
`audit-access-invariants.sql:8-9`:

> `*  genuinely safe — every user who can authenticate holds at least one gated function (Hydra UAT: 15 of 19 users hold all eleven; measured 2026-08-20);`

Two independent reasons an empty `SET 4` cannot support that sentence:

1. **Population scoping (the brief's point).** `per_user:122` drives off `(SELECT DISTINCT user_id, username FROM projected_held)`, and `projected_held` ⊆ `held`, which requires at least one `mywms_role_mywms_function` row. A user holding **zero** functions is not in the query's universe and can never be a `SET 4` row. `SET 4` therefore means *"nobody holding something is left with nothing"* — never *"nobody is locked out."*

2. **Keycloak is invisible to this file.** "Can authenticate" is decided by Keycloak, and the E1-P join is still owed (§5.1-P1). No set in this file can support any claim about who can authenticate. `MOBILE_UI_LOG_IN` is not a substitute: grepping `wms2-api/src` and the whole `wms2-mobile-ui` worktree, `MOBILE_UI_LOG_IN` appears **only** in seed data (`V2.2.00:2805`, `V1.1.02:253`), in `UtilRestController`'s provisioning, and in this audit's own `SET 3`. Nothing enforces it, so holding it does not permit mobile login and lacking it does not prevent it.

Also wrong in the same sentence: **"hold all eleven"** — the `gated` list has **12** pairs, and re-running the committed CTE chain verbatim on `wms2-hydra-uat` gives `SET 4b = 15` rows, all with `workflows_retained = 12`, `SET 4 = 0`. It is twelve, not eleven.

**A third gap in the same shape**, not currently stated anywhere: a user who *is* in a group whose groups have zero roles (or roles with zero functions) holds zero functions, so appears in neither `SET 1` (which tests group membership, not function count) nor `SET 4`. Measured `users_in_group_but_zero_functions` = **0** on all six databases, so the `users_total − SET_4b = SET_1` arithmetic in the brief and in §5.1-P2 holds **by data, not by construction**. One tenant with a role stripped of its functions breaks it silently.

**Failure scenario:** an operator reads case 1, sees `SET 4 = 0` on Hydra prd, and signs off on "nobody is locked out" — while the two prd users with no group membership (`users_zero_group = 2`, measured) plus any zero-function-in-a-group user are outside the query entirely. Enforcement is hard-on with no flag, so that sign-off is the only gate.
**Fix: comment-only for the header** (the queries are sound and `SET 1` already covers the main sub-population — §5.1-P2 and §14.21 item 4 of the plan already state this correctly; only the SQL file's operator-facing header does not). Recommended wording: delete "every user who can authenticate holds at least one gated function"; state instead that `SET 4` is scoped to users holding ≥1 function, that `SET 1` is the disjoint zero-grant population, that neither can see Keycloak, and that `SET 2`'s empty-role findings are the third population. Fix "eleven" → "twelve".

---

## F3 — Medium — `projected_held` does **not** mirror all of `V2.2.18`, and the guard/gate column split makes one divergence undetectable

**Diff of the two predicates, explicitly.**

| | `V2.2.18` | audit `projected_held` (`:106-116`) |
|---|---|---|
| step 1 — create `MOBILE_UI_VIEW_REPLENISH_REQUEST` | guard `e.function = f.name **OR** e.name = f.name` (`:38-41`) | n/a |
| step 2 — grant REQUEST | to every **role** in `mywms_role_mywms_function` joined to `proc.name = 'MOBILE_UI_VIEW_REPLENISHMENT'` (`:50-57`) | to every **user** whose `held` set contains `MOBILE_UI_VIEW_REPLENISHMENT` (`:113-115`) |
| step 3 — CANCELLATION → `outbound-worker, outbound-manager, super-admin` (`:75-83`) | — | **not projected** |
| step 4 — TRANSFER_ORDER → `outbound-manager, inventory-manager` (`:85-93`) | — | **not projected** |

**(a) Step 2 is equivalent at user granularity** — role-keyed and user-keyed reachability coincide, so this half of the claim holds. ✔

**(b) Steps 3 and 4 are not projected at all**, so `SET 4` under-credits retention. Direction is conservative (false lockout alarms, never a false all-clear), but on a criterion that reads "must be empty on prd" a false alarm *is* a deploy blocker. Measured impact today: none — `SET 4` is already 0 on prd.

**(c) The real hazard — the seed's widened guard keys on a column no functional path uses.** Step 1 now guards on `function` OR `name`, but every path that *acts* keys on `name` alone:
- `V2.2.18:54` — `CROSS JOIN (SELECT id FROM mywms_function WHERE name = 'MOBILE_UI_VIEW_REPLENISH_REQUEST') req`
- `V2.2.18:79`, `:89` — `WHERE f.name = …`
- `UserRepository.java:27` — the runtime gate: `SELECT DISTINCT f.name … join mywms_function f`

So on a tenant holding a row with `function = 'MOBILE_UI_VIEW_REPLENISH_REQUEST'` and a NULL or divergent `name`: step 1 skips (guard hit, correctly avoiding 23505), step 2's `CROSS JOIN` subquery returns zero rows so the whole INSERT inserts nothing **without error**, and `getAllRoles` can never return the string — `/v3/replenish/request/**` is denied for **every user on that tenant**, permanently. Meanwhile `projected_held:113-115` unconditionally credits `MOBILE_UI_VIEW_REPLENISH_REQUEST` to every REPLENISHMENT holder, so `SET 4` stays 0 and the audit reports the tenant safe.

Widening the guard was the right call — it prevents the 23505/silent-chain-freeze the previous version risked — but it **traded a loud failure for a silent one that this audit cannot see.** `name IS DISTINCT FROM function` = **0** on all five reachable tenants and on prd, so latent, not firing.

**Failure scenario:** any tenant onboarded from a hand-edited dump or a v1→v2 migration that writes `mywms_function` with `name` unset. Post-deploy, replenish-request is dead for everyone on that tenant, the migration reports success, and the pre-deploy audit reported zero findings.
**Fix: not comment-only — add a probe.** Two read-only rows, appended as `SET 8`:

```sql
SELECT 'function_name_function_divergence' AS probe, count(*) AS value
FROM mywms_function WHERE name IS DISTINCT FROM function;              -- expect 0, ALWAYS
SELECT 'seeded_rows_reachable_by_gate' AS probe, count(*) AS value
FROM mywms_function
WHERE name = function
  AND name IN ('MOBILE_UI_VIEW_REPLENISH_REQUEST','MOBILE_UI_VIEW_CANCELLATION');  -- expect 2 POST-migration
```

Also correct the `projected_held` comment: it mirrors step 2 only, and its projection is valid only while row 1 above is zero.

---

## F4 — Medium — `held` is now *more* permissive than the gate it predicts, so the audit can produce a false all-clear

**Proved by query (zero rows today) + code read.**
`audit-access-invariants.sql:96-104` UNIONs the direct `mywms_user_mywms_role` path into `held`. The gate's actual query, `UserRepository.java:27-33`, has **only** the group path. So a user whose grants arrive solely through `/v3/userUserRole` is credited by the audit with retaining workflows and is denied by the gate at runtime (`AccessDecision.Reason.NO_FUNCTIONS`).

The commit message acknowledges the gate's blind spot as "pre-existing, out of scope, recorded in §14.19" — but the consequence for *this artifact* is that the regression predictor is now unsound in the dangerous direction, and the SQL file does not say so. `mywms_user_mywms_role` has **0 rows** on all six databases (and no PK, no unique index, on any of them), so nothing fires today.

**Failure scenario:** the first operator to grant a role directly via `/v3/userUserRole` on any tenant. The audit says that user retains their workflows; after deploy they get 403 on everything. On Hydra prd, where all 7 real users are super-admins reached by group, the first *new* user provisioned the direct way is the one who breaks.
**Fix:** a regression predictor must mirror the gate. Either drop the direct-path UNION from `held` (and add a separate one-line probe: `SELECT 'direct_user_role_rows', count(*) FROM mywms_user_mywms_role` — expect 0, non-zero means the audit and the gate now disagree), or keep the UNION and add a `via` column so a direct-only row is visibly not gate-reachable. The count probe is the cheaper and clearer of the two.

---

## F5 — Medium — `V2.2.18` steps 3–4 **do** silently widen access for existing users, contradicting the comment that says that is why the divergence was left alone, and no audit set reports it

**Proved by query.**
`V2.2.18:73-74`: *"Left alone because reconciling it is a PRIVILEGE-SCOPE decision, not a correctness fix: widening this migration to match initDB would silently grant new access to existing users inside a security change."*

Measured on `wsl-wineco-uat` (`wh01_om1_v2`) — the one tenant with real role separation — step 4 (`WEB_UI_VIEW_TRANSFER_ORDER` → `outbound-manager`, `inventory-manager`) newly grants that function to **7 named existing users** who do not hold it today: `danielvalentim, estellavasquez, marthamina, ursulajimenez, josiemarks, markchilcote, fulfillment`. (Step 3, CANCELLATION: 0 newly granted there.) On Hydra prd: 0 newly granted for both — the 4 users reaching those roles already hold TRANSFER_ORDER via `super-admin`. Role-level state on prd: only `receiving` and `super-admin` hold REPLENISHMENT; only `super-admin` holds TRANSFER_ORDER; `inventory-manager` (4 users) holds none of the three.

The widening is *intended* (plan §D4 — the Transfer tile must be reachable by a mobile persona), so this is not a correctness defect. Two things are:
1. The comment's stated reason for not reconciling with `initDB` is **contradicted by the same file two statements earlier**. A reviewer reading it will believe `V2.2.18` is grant-neutral for existing users. It is not.
2. `SET 5` covers C1's split blast radius (`MOBILE_UI_VIEW_REPLENISHMENT` holders) and nothing covers steps 3–4's. **The audit reports every access the deploy takes away and none of the access it adds** — on a pre-deploy gate for a change shipping hard-on with no flag.

`WEB_UI_VIEW_TRANSFER_ORDER` is a **WEB** function reused by the mobile tile by deliberate choice (§10.6). Once SBDEV-2967 gates the web UI on the same table, those 7 warehouse users also gain the web Transfer Order page. That consequence is **reasoned, not proved** — the `wms2-web-ui` worktree contains no reference to `WEB_UI_VIEW_TRANSFER_ORDER` yet.

**Failure scenario:** wsl-wineco-uat / any tenant with role separation. Seven users gain a function nobody signed off on, invisibly to the audit, inside a change whose whole framing is "this only removes access."
**Fix:** reword the comment to state plainly what steps 3–4 grant and why, and add a `SET 9` listing the users each of steps 3–4 newly grants, per tenant (the same `gain` / `have` shape used to measure it above). Consider making it a P2 sign-off row alongside the lockout criterion.

---

## F6 — Low — the third `V2.2.18`-vs-`initDB` divergence is the largest and is undocumented

**Proved by query + code read.** `V2.2.18:62-74` documents two divergences (TRANSFER_ORDER, CANCELLATION) accurately against `UtilRestController:436` / `:430`. It omits the third, and the third is the function this migration exists to create:

| | `V2.2.18` | `initDB` (`UtilRestController:439-440`) |
|---|---|---|
| `MOBILE_UI_VIEW_REPLENISH_REQUEST` | wherever `MOBILE_UI_VIEW_REPLENISHMENT` already is — measured on prd and wsl-wineco-uat that is `receiving` + `super-admin` | `inventory_manager, outbound_manager, outbound_worker, super_admin` |

The two sets overlap in `super-admin` only. `receiving` gets it on an existing tenant and not on a fresh one; `inventory-manager` / `outbound-*` the reverse. A fresh tenant and a migrated tenant end up with materially different replenish-request authorization.
(Minor, same area: `WEB_UI_VIEW_TRANSFER_ORDER` is granted to `super_admin` twice in `initDB` — `:362` and `:436`. Harmless, `addFunctionToRole` is idempotent in effect.)

**Fix:** add the third row to the existing comment table. Agreeing with the commit's judgement that reconciliation is a scope decision, not this ticket's fix.

---

## F7 — Low — `SET 3` lacks the `connector` exclusion that `SET 2` has, and 3 of its 4 rows are connector noise on the tenant that matters

**Proved by query.** `SET 2:32-34` excludes `connector` rows because "counting them as findings buries the real ones." `SET 3:49-58` has no such filter. Measured on `wsl-wineco-uat`, `SET 3` returns 4 rows: `ROLE000033 (connector)`, `ROLE000020 (connector)`, `CS-REP (real)`, `ROLE000026 (connector)`. 3 of 4 are exactly the noise `SET 2` is careful to suppress. 3 connector roles on that tenant hold `MOBILE_UI_LOG_IN` and 19 hold some `MOBILE_UI_VIEW_*`, so this grows as `AccessService.addFunctionToUser` is used.

Related, and the reason `SET 3` looks cleaner than it is: its `MOBILE_UI_LOG_IN` filter is doing accidental connector-suppression, not the semantic job its comment claims ("roles that can log in to mobile" — see F2, nothing enforces that function). Excluding connectors, the filter hides **0** real roles on `wsl-wineco-uat` today, so it works by coincidence.

**Fix:** add `AND COALESCE(r.connector, false) = false` to `SET 3` and reword its comment to say the `MOBILE_UI_LOG_IN` filter is a provisioning-intent proxy, not an enforced gate.

---

## F8 — Low — `V2.2.18` leaves `created`/`modified` NULL, against the directory's own precedent

`V2.2.18:22-23` inserts `(id, version, client_id, name, number, function)` only. `V2.2.09:73-75` — the nearest precedent in the same directory — sets `now(), now()`. Both columns are nullable (`information_schema` on `wms2-hydra-uat`: `created` / `modified` = `YES`), so nothing fails; but `mywms_function` has `created IS NULL` on **0** of its 80 rows on prd and on `wms2-wineco-dev`, so the two seeded rows would be the only NULLs in the table and lose the "when did this appear" trail.
**Fix:** add `now(), now()` to the column list and the SELECT.

---

## Ruled out, with the evidence

- **`ON CONFLICT` in either form** — not present anywhere in `V2.2.18`; all four INSERTs use `WHERE NOT EXISTS`. The brief's constraint reality confirmed independently: `mywms_role_mywms_function` has **0** PK/unique constraints on `wms2-hydra` (prd) and `nywh-shipitez-uat`, `..._pk` on `wms2-hydra-uat`, `..._pkey` on `wms2-wineco-dev`, 1 each on `wsl-wineco-uat` / `c1wh-shipitez-uat`, and none in `V2.2.00:1512-1515`. The named form and the column-inference form would each have failed on some live tenant. **Correct as committed.**
- **Double-run idempotency** — step 1's guard matches on `function OR name` and a post-run row has the literal in both, so it re-skips; steps 2–4 guard on the exact `(rolelist_id, functionlist_id)` pair. All four statements insert 0 rows on a second run. No unguarded INSERT in the file.
- **Empty-source safety** — if step 1 skips, step 2's `CROSS JOIN` subquery is empty and steps 3–4 match no `f`, so the file completes with 0 rows rather than erroring. (This is *why* F3(c) is silent rather than loud.)
- **22001 / `varchar(255)`** — `mywms_function` has no `description` column (`id, created, modified, name, number, version, function, client_id`). Longest literal is 32 chars. Not reachable in this file.
- **FK 23503 on `client_id = 0`** — `client` id 0 = `System-Client` exists on prd, `wms2-hydra-uat` and `wms2-wineco-dev`; all 80 existing `mywms_function` rows use `client_id = 0`. Safe. (`mywms_function` has one FK, `fk3d93v8yyfvlgv1r04fuc1rk8c → client(id)`.)
- **`number` uniqueness** — `mywms_function` carries only `mywms_function_pkey (id)` and `uk_hxqe1tp0v5sk4le8ij6wmtrq1 (function)`. Seeding `number = name` cannot collide.
- **`SELECT DISTINCT` in step 2** — correct, and the stated reason (per-source-row `NOT EXISTS` against the pre-statement snapshot) is right. Measured 0 duplicate `(rolelist_id, functionlist_id)` pairs on all six databases, so prophylactic exactly as claimed.
- **The 12 `gated` pairs** — exact bijection with the 12 distinct `FunctionEnum` constants named by `@RequiresFunction` across the 11 controllers in `controller/mobile/`; all 12 exist in `WmsConstants.java` (1 declaration each). Nothing missing (which would inflate `workflows_retained`), nothing extra. `@RequiresFunction` occurs nowhere outside `controller/mobile/` except the `security` package and javadoc.
- **`SET 4` vs `SET 4b` CTE chains** — diffed; byte-identical apart from the final `SELECT`'s `WHERE`/`ORDER BY`, as the comment claims.
- **`SET 4` reproduced verbatim** — `wms2-hydra-uat` 0 (4b = 15, all 12/12); `wms2-wineco-dev` 4 (`sbtest`, `Z-AdamPetersen(archived)`, `Z-Warehouse(archived)`, `Z-mariaortiz(archived)`); `wsl-wineco-uat` 3 (all `Z-…(archived)`). Matches §14.20/§14.21. The criterion is now both satisfiable and met.
- **`per_user` aggregation** — `COUNT(g.workflow)` over the `LEFT JOIN gated` counts matched gated functions correctly; `gated` has 12 distinct `function_name`s and `projected_held` is distinct per `(user, function)`, so no fan-out inflation.
- **Read-only** — no INSERT/UPDATE/DELETE/DDL anywhere in `audit-access-invariants.sql`. Confirmed by read.
- **`UtilRestController` unreachable** — confirmed `@Service` at `:23`, not `@RestController`. The `V2.2.18` comment's claim is accurate; the divergence is a documentation matter *today*, and becomes live the moment anyone corrects that annotation (see F6 for what would then diverge).

---

## Verdict

**REQUEST CHANGES — no blocker, six fixes, only one of which needs SQL.**

`SET 4` is now a real gate: it filters correctly, it is satisfiable, it was validated in both directions, and I reproduced its numbers on four databases. `V2.2.18` is idempotent, cannot hit either `ON CONFLICT` trap, cannot raise 22001 or 23503, and is a no-op on a second run. The brief's finding against the header is **CONFIRMED** and the fix there is comment-only.

Must fix before merge:
- **F3(c)** — the only one requiring a query change: add the `name`-vs-`function` divergence probe. Without it the widened guard is a silent, audit-invisible total lockout of replenish-request on any tenant with a divergent row.
- **F5** — reword the self-contradicting comment and add a grant-widening set; 7 named users on `wsl-wineco-uat` gain a function no set reports.
- **F4** — make the audit mirror `getAllRoles` or flag when it cannot.
- **F1, F2, F6** — comment-only corrections of statements that are measurably false (`UNIQUE (name)` exists; "every user who can authenticate"; "all eleven" → twelve; the third `initDB` divergence).
- **F7, F8** — Low, fix while in the file.

Nothing here blocks the prd deploy on its own numbers: on `wh01_hydra_v2` (prd) `SET 4 = 0` measured, `name IS DISTINCT FROM function = 0`, `mywms_user_mywms_role = 0` rows, and steps 3–4 newly grant nothing. The exposure is on UAT and on the next tenant onboarded.
