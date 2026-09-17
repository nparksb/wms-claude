---
title: SBDEV-1512 — independent review of D6 (the `notifieddamagedamount` column + V2.2.31 migration)
ticket: SBDEV-1512
scope: D6 ONLY — §3.2 data-model delta, §3.4 (only where it relies on D6), §4 rows 0/1a/1b, §5.1 rows 1/1a/1b/5, §5.2 D6 checkboxes, §6 schema + notifiedamount rows, §8 constraint 2
lane: rev3 (independent; D6 was added after the Architect rev1 and Critic rev2 lanes closed)
date: 2026-09-15
derived_from: origin/develop @ 9e294d4b (fetched 2026-09-15) + live MCP reads of 6 tenant DBs + 2 landlord DBs
---

# Verdict: **SOUND WITH CHANGES**

D6's *design intent* is right and I would not drop it. But as **specified**, it ships:

- one defect that 500s every existing caller of a `permitAll()` endpoint (H2),
- one unauthenticated unvalidated write path (H3),
- and a recovery mechanism whose only query is **inert** — it returns every damaged position
  forever, so it cannot tell a recovered one from an unrecovered one (H1).

H1 matters most for the *decision*, because "the recovery worklist" is the entire stated
justification for the column and therefore for the Flyway migration. H2 matters most for the
*schedule*, because it is one line and it is an outage.

**The migration itself is the safest part of D6.** `V2.2.31` is free, the app role owns
`adviceposition` on all six active tenant DBs, and the ALTER is catalog-only. Priority 1 and
priority 2 of the review brief come back essentially clean; priorities 3, 4 and 5 do not.

---

## Correction to the brief's premise

> ⚠ The local `v2/wms2-api` checkout is **56 commits behind** `origin/develop`.

Not as of this lane. After `git fetch origin`, local `develop` and `origin/develop` are the **same
commit**, `9e294d4b` ("Merge pull request #358 from SiteBossInc/bugfix/SBDEV-2778-soft-fail-return-auto-receive"),
and `git rev-list --count HEAD..origin/develop` returns `0`. Every claim below is still derived from
`origin/develop` explicitly (`git show origin/develop:<path>`, `git grep … origin/develop`), so the
correction changes nothing about the evidence — recording it only so the next lane does not re-do the
sync.

---

## Priority 1 — the migration itself

### `V2.2.31` is free ✔

*Method:* swept **all 287 refs under `refs/remotes/`** (not `ls`), listing
`src/main/resources/db/migration/` in each ref's tree and taking the version-sorted max.

```
highest across all remote refs: V2.2.30__outbox_message_lane.sql
```

*Positive control:* the same sweep reports `V2.2.30` present on **12 distinct refs** (`origin/develop`,
`origin/release`, `origin/SBDEV-3340`, five `bugfix/*`, three `feature/*`, `origin/fix/outbox-latency-config`,
`origin/claude/owl-v2.0.141-promote`). A broken sweep and a true "nothing above 2.2.30" look identical
without that, and it is non-empty, so the instrument works.

*Blind spot, stated by the plan and still true:* a sweep cannot see a branch pushed after it ran.
§5.1 row 1's "re-run immediately before writing the file" is the right instruction; keep it.

*Historical note the plan does not mention, and should:* this directory **has** collided before.
The all-ref sweep shows three duplicated version numbers across refs — two different `V2.2.01`
(`los_sequencenumber_init` and `replenishment_monitor_view_add_section_and_ro_id`), two `V2.2.02`, two
`V2.2.03`. Those are historical branch-local reuses, not a live conflict on `develop`, but they are the
concrete reason row 1's instruction exists.

### Conventions of the existing `V2.2.2x` files — **two idioms, the plan picked the older one** (L2)

*Method:* `git show origin/develop:<file>` over every `V2.2.*` file, grepping `add column`.
Three files add columns:

| file | form |
|---|---|
| `V2.2.03__replenishorder_finish_audit_snapshot.sql` | `ALTER TABLE replenishorder ADD COLUMN moved_amount NUMERIC(17,4);` — bare, unqualified |
| `V2.2.13__putaway_destination_hierarchy.sql` | `ALTER TABLE public.client ADD COLUMN IF NOT EXISTS defaultputawaylocation_id bigint;` |
| `V2.2.30__outbox_message_lane.sql` | `ALTER TABLE outbox_message ADD COLUMN IF NOT EXISTS lane character varying(32) NOT NULL DEFAULT 'DEFAULT';` |

The plan (§3.2, §4 row 0, §5.1 row 1) specifies the **bare** form. The two most recent both use
`IF NOT EXISTS`; `V2.2.13` also schema-qualifies. `V2.2.03` is additionally the file this repo's own
`CLAUDE.md` singles out as **"not replay-safe"** — copying its idiom is copying the one that was
called out. Use:

```sql
ALTER TABLE public.adviceposition
    ADD COLUMN IF NOT EXISTS notifieddamagedamount numeric(19,2);
```

Second convention gap: **every** `V2.2.2x` file I read opens with a multi-paragraph `-- WHY` header
(`V2.2.26` runs ~45 comment lines before its first statement, `V2.2.30` ~23). The plan's migration is
a bare one-liner with no header. Cheap to fix and it is what the next reader will look for.

*Transactional behaviour:* nothing to change. Flyway on PostgreSQL runs each script in a transaction,
DDL is transactional here, and a single `ALTER TABLE` needs no explicit `BEGIN`/`COMMIT` — matching
all three files above, none of which declares one.

### Would it run clean on both provisioning paths? ✔

*V2.2.00 base-dump path:* `V2.2.00__base_v2_schema.sql` declares
`CREATE TABLE public.adviceposition (… notifiedamount numeric(19,2), …)` with **19 columns**.
*v1→v2 onboarded path:* `v1-to-v2-onboarding/schema/V1.0.01__wms_tables.sql:43` declares the same
`notifiedamount numeric(19,2)`.

Both paths produce the same table, and an `ADD COLUMN` of a brand-new name is independent of the ids
and types that differ between them. Measured confirmation on live tenants from *both* lineages:
`information_schema.columns` returns **19** columns for `adviceposition` on `wh01_hydra_v2` (prd,
v1→v2 lineage) and **19** on `wh01_shipitez_v2` (UAT), and `notifieddamagedamount` count = **0** on
both, so the name is not already taken anywhere I can reach.

### L4 — §6 says the wrong column count

§6's schema row reads "20 columns → +1 nullable". It is **19**. Derivation: the `V2.2.00` DDL block
(counted) and `information_schema.columns` on two tenants. Trivial, but §6 is the table a reader
checks the migration against.

### L5 — lock and rewrite risk is negligible; say so once

PostgreSQL 11+ adds a **nullable column with no default** as a catalog-only change — no table
rewrite. Sizing on the largest tenant I can reach (`wh01_shipitez_v2`): `adviceposition` is
**9,613 rows / 2832 kB**, with 1,037 RETURN advices. The `ACCESS EXCLUSIVE` lock is taken and
released immediately. One line in §5.1 stops the next reviewer re-deriving this.

---

## Priority 2 — ownership and stall risk

### The 42501 risk is real in this repo but **not present today** — measured, not reasoned ✔

The brief is right that `ADD COLUMN IF NOT EXISTS` does not exempt you: Postgres checks ownership
before `IF NOT EXISTS`, and this estate has the scar (`wh01_hydra_v2` frozen at `V2.2.06` on
`42501 must be owner of function stock_history`). So I measured it rather than argued it.

*Method:* per tenant DB, over MCP, `pg_get_userbyid(pg_class.relowner)` for
`adviceposition` (and `advice`, `outbox_message`, `receiving_dto_view`), cross-referenced against
`tenant_db_configuration.db_user_name` read from **both** landlord DBs so the connecting role is
known to be the app role.

| env | database | app role (`db_user_name`) | owner of `adviceposition` |
|---|---|---|---|
| prd | `wh01_hydra_v2` | `wh01_hydra_v2_app` | `wh01_hydra_v2_app` ✔ |
| UAT | `wh01_hydra_v2` | `wh03_om1` | `wh03_om1` ✔ |
| UAT | `wh01_om1_v2` (WineCo wsl) | `wh01_om1` | `wh01_om1` ✔ |
| UAT | `wh01_shipitez_v2` (c1wh) | `wh04_om1` | `wh04_om1` ✔ |
| UAT | `wh02_shipitez_v2` (nywh) | `wh05_om1` | `wh05_om1` ✔ |
| dev | `dev_wh01_om1` | `wh01_om1` | `wh01_om1` ✔ |

That is **every row in both landlord `tenant_db_configuration` tables** — prd has exactly 1, UAT has
exactly 4, plus dev. On the two DBs where I ran the grouped form, a **single** owner covers all public
relations (`wh01_hydra_v2`: 67 public relations, one owner; `wh01_om1_v2`: 72; `wh01_hydra_v2` UAT: 68).

*Positive control for the zero:* the identical query on `wh01_hydra_v2` widened to `pg_catalog`
returns `postgres` as owner of **134** relations alongside `wh01_hydra_v2_app` for 67 in `public`. So
`pg_get_userbyid` demonstrably reports an owner other than the connecting role; the "no divergence"
result is a true zero, not a broken instrument.

**Conclusion: D6's migration will not raise 42501 on any currently-active tenant.** This is the
cleanest part of D6.

### M2 — but the prerequisite does **not** detect it, and the plan claims it does

§5.1 row 1a's check is:

```sql
SELECT count(*) FILTER (WHERE success IS FALSE) AS failed, max(version) FILTER (WHERE success) AS max_ok, max(installed_on) FROM flyway_schema_history;
```

That detects a tenant **already stalled**. It cannot detect "the app role does not own
`adviceposition`", which is the condition that would make `V2.2.31` *become* the stall. Those are
different questions, and row 1b's own evidence shows why conflating them is unsafe: ShipItEZ's two
DBs are at `V2.2.30` with **0 failed** — I re-measured `wh01_shipitez_v2` and confirm 31 history
rows, 0 failed, latest `2.2.30` — and being fully caught up tells you nothing about ownership of a
table that arrived by `pg_restore`. Note that `V2.2.30`, the most recent ALTER, targets
`outbox_message`, a table **created** by `V2.1.11` under the app role; succeeding on it proves
ownership of a Flyway-created table, not of a v1-inherited one.

**Change:** add one row to the §5.1 row 1a probe, per tenant:

```sql
SELECT pg_get_userbyid(c.relowner) AS owner, current_user
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname = 'adviceposition';
```

It costs nothing, it is the check that would have caught the `V2.2.06` incident a boot earlier, and
right now it passes everywhere — which is exactly when it is cheap to institutionalise.

### M1 — §5.1 row 1a's *mitigation* claim is inverted, and this is the highest-impact Medium

Row 1a's Notes say:

> The column is nullable, so a tenant that misses the migration fails at Hibernate's schema
> validation rather than silently — but `Hibernate validate` reports the **first** mismatch and stops…

Production does not run `validate`.

- `src/main/resources/application.properties:105` — `spring.jpa.hibernate.ddl-auto=none`
  (with `#spring.jpa.hibernate.ddl-auto=validate` commented out directly above it, at `:104`).
- `validate` appears only in the test tree: `src/test/resources/application.properties:45` and
  `src/test/resources/application-postgres-integration.properties:163` — the latter's own comment
  says *"This DIVERGES from production, which is `none`"*.
- Both `TenantDatabaseConfig` and `LandlordDatabaseConfig` read it as
  `@Value("${spring.jpa.hibernate.ddl-auto:none}")`, defaulting to `none`.

So a tenant that misses `V2.2.31` does **not** fail fast. It boots green and then throws
`42703 column … does not exist` on **every** query that materialises an `Adviceposition`, per request,
behind passing health probes. `V2.2.13`'s own header names this exact mode: *"ddl-auto is none, so that
is a per-request failure behind green probes."*

The blast radius is also understated. `git grep -ln "Adviceposition" origin/develop -- src/main/java`
returns **18 files** — including `ReceivingService`, `AdviceService`, `GoodsReceiptPositionService`,
`ReportService`, `FileImportController`, `PutawayDestinationQueryService` and `ReceivingDtoView`. A
stalled tenant loses **the whole receiving stack**, not the return path. *Blind spot of that
instrument:* it counts files naming the type, so a consumer reaching the table only through native
SQL would be missed; `ReceivingDtoViewRepository`'s native query is such a case and it is
`SELECT`-listed, so it survives an extra column either way.

Rewrite the Notes cell to say: **nothing checks at startup; a missed migration surfaces as a
per-request 42703 across the receiving stack, so the pre-merge per-tenant probe is the only control.**

---

## Priority 3 — the entity writes in `AdviceRestController`

The controller is on the `permitAll()` list: `SecurityConfiguration` includes `"/rest/**"` in the
`.requestMatchers("/", "/v3", "/v3/token", "/error", "/rest/**", "/api/**", …).permitAll()` block.
The brief's framing is correct, and it raises the bar on both findings below.

### H2 — `notifiedamount = undamaged + damaged`, written literally, NPEs for **every existing caller**

Today's line (`AdviceRestController`, inside the position save loop, `create()`):

```java
position.setNotifiedamount(new BigDecimal(advicePosition.getAmountOfBottles()));
```

`AdvicePositionDto.amountOfBottles` is a boxed **`Integer`** (`private Integer amountOfBottles;`), and
so is every other numeric field on that DTO. §4 row 1b and the §5.2 checkbox both specify the new
behaviour as, verbatim, `notifiedamount = undamaged + damaged` — an arithmetic expression over two
boxed `Integer`s. §6's first row asserts the *outcome* ("absent key → `null` → treated as 0") but no
section says **where** the coalescing happens, and no §7 test row grades it.

An implementer who writes the checkbox as stated produces `undamaged + damaged` with
`damaged == null` for **every request that omits the new key** — which is every REGULAR advice from
the OMS, every RETURN advice from a `qa-api` that has not deployed Phase 2, and every v1-era caller.
That is an unboxing NPE → HTTP 500 on an unauthenticated endpoint, for essentially all live traffic.
This repo already carries a standing note about `any()`/unboxing NPEs; this is the same trap on the
production side.

**Fix, and it belongs in the plan text, not left to the implementer:** state the expression as

```java
int damaged = advicePosition.getAmountOfBottlesDamaged() == null ? 0 : advicePosition.getAmountOfBottlesDamaged();
```

and add a §7 row that posts a body with **no** `amount_of_bottles_damaged` key and asserts a 2xx plus
`notifiedamount == amount_of_bottles` and `notifieddamagedamount == null`. Mutation-check it by
removing the coalescing.

This is **the single thing I would fix first.**

### H3 — the write is ungated by advice type and by the auto-receive sysprop; the validation is not

Ordering in `create()`, measured by reading the method top-to-bottom:

1. `boolean autoReceive = AdviceType.RETURN.equals(adviceDto.getType()) && adviceDto.getPositions() != null && !adviceDto.getPositions().isEmpty() && (… isAutoReceiveEnabled())`
2. `if (autoReceive) { validatedAutoReceive = returnAdviceAutoReceiveService.validate(adviceDto); }` — this is where `resolveRefs` runs, under the SBDEV-2778 C-1 comment *"validate BEFORE anything is persisted"*
3. `adviceEntity = adviceRepository.save(adviceEntity);`
4. **the position loop, unconditional** — `position.setNotifiedamount(…)`, `advicepositionRepository.save(position)`

§5.2 puts the new validation in **`resolveRefs`** — *"`resolveRefs`: `damaged >= 0`; relax
`undamaged >= 1` to `total >= 1`; `total <= MAX_UNITS_PER_POSITION`"* — i.e. inside step 2, which runs
only when `autoReceive` is true. The **write** is in step 4, which runs always.

The only validation step 4 has is the pre-existing pair on the *other* field:

```java
if (advicePosition.getAmountOfBottles() == null)  → FIELD_NOT_SET
if (advicePosition.getAmountOfBottles() < 0)      → FIELD_MALFORMED_FORMAT
```

So on any of these three shapes — a **REGULAR** advice; a RETURN advice on a tenant with
`RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED=false`; a RETURN advice with an empty `positions` list (the plan
itself notes v1 produced 133 of those) — an unauthenticated caller can send
`amount_of_bottles_damaged: -5000` or a value large enough to overflow the `int` addition to a
negative, and it is persisted straight into `notifiedamount`. `MAX_UNITS_PER_POSITION = 100_000` and
the `damaged >= 0` rule never run on those paths.

`notifiedamount` is not decorative: it drives `AdviceRepository`'s
`(SELECT COALESCE(SUM(ap.notifiedamount), 0) … ) as qtyRequired` (two queries) and
`ReceivingDtoViewRepository`'s `ap.notifiedamount AS orderedbottles`.

**Fix:** put the damaged-field validation in the save loop, beside the two checks it already has —
the place where the write happens — and keep the `resolveRefs` rules as the auto-receive-specific
*additional* tier. §6's "REGULAR advices … unchanged — the damage branch is gated on
`damagedAmount > 0`" is true of the *damage branch* and **false of the D6 write**, which has no gate
at all; that row needs correcting too.

### M4 — the entity default will silently contradict the documented NULL semantics

`Adviceposition.java:19` reads:

```java
@Column(columnDefinition = "numeric(19,2)")
private BigDecimal notifiedamount = BigDecimal.ZERO;
```

§4 row 1a says only "add `BigDecimal notifieddamagedamount` + accessors". An implementer matching the
sibling field two lines above writes `= BigDecimal.ZERO`, and then **every** post-deploy row carries
`0.00`, never `null` — which falsifies §5.1 row 5 and §6 ("`null` reads as 'this advice predates the
feature', which is exactly right") on day one. Specify the initialiser explicitly: **no initialiser**,
field stays `null`.

Independently, the "NULL = predates the feature" reading is already false for the **other** writers of
`Adviceposition`, none of which D6 touches — `AdviceRestController:610` (`createTransfer`),
`AdviceRestController:768` (`createHubAndSpoke`), `ReceivingService:256`
(`createAdviceWithPositions`), `ReceivingService:308` (`updateAdviceWithPositions`), and
`FileImportController:519` (spreadsheet import). All five keep writing `notifiedamount` and leave the
new column `null` forever. That is fine behaviourally, but it means `null` means "predates the feature
**or** came from one of five other paths", and §6 should say so.

*Out of D6's scope, flagged only because D6 adds a third unboxing to the same block:* the loop
already NPEs on `new BigDecimal(advicePosition.getAmountOfBoxes())` when `amount_of_boxes` is absent,
and on `Boxtype boxtype = optionalBoxtype.get();` when `box_id` is absent (`optionalBoxtype` is
initialised to `null` and only assigned inside `if (StringUtils.isNotEmpty(advicePosition.getBoxId()))`).
Pre-existing, not D6's doing, not something this ticket has to fix — but do not let H2's fix be
reviewed as "consistent with the neighbours", because the neighbours are broken.

---

## Priority 4 — read-back and recovery

### H1 — the §3.2 recovery worklist is **inert**. It returns every damaged position, forever.

This is the finding that most affects whether D6 earns its migration, because the worklist *is* the
justification. §3.2:

> One nullable column makes every one of those states queryable, and gives the recovery story an
> actual data source:
>
> ```sql
> SELECT ap.id, ap.externalid, ap.notifiedamount, ap.notifieddamagedamount
> FROM   adviceposition ap
> WHERE  ap.notifieddamagedamount > 0
>   AND  NOT EXISTS (SELECT 1 FROM stockrecord sr
>                    WHERE sr.activitycode = 'DAMAGED' AND sr.ordernumber = ap.number);
> ```

**A `stockrecord` row with `activitycode = 'DAMAGED'` never carries an `ordernumber`**, so the
correlated subquery matches nothing and the `NOT EXISTS` is true for every row — including every
position that was damaged *successfully*. The worklist cannot distinguish recovered from unrecovered.

*Measured*, on `wh01_shipitez_v2` (the tenant with real return volume):

| activitycode | rows | rows with a non-empty `ordernumber` |
|---|---|---|
| `DAMAGED` | **396** | **0** |
| `PICKING` | 886,310 | 886,310 |
| `RETURN` | 2,956 | 2,956 |
| `RECEIVING` | 9,639 | 9,639 |
| `MANAGE_INVENTORY` | 2,650 | 0 |

*Positive control:* the zero on `DAMAGED` is produced by the same
`count(*) FILTER (WHERE ordernumber IS NOT NULL AND ordernumber <> '')` expression that returns
886,310 for `PICKING` and 2,956 for `RETURN`. 13 of the 26 activity codes on that tenant come back
non-zero, so the instrument reads the column correctly and a populated `DAMAGED` would have shown.

*Structural cause, so this is not a per-tenant accident.* `StockunitService.setLockDamaged`
(discriminated by its **enclosing method signature**, per §4's citation trap — the `getStockChangeDTO`
literal it contains is byte-identical to the one in `transferStock`) uses `CODE_DAMAGED` in exactly
one place, and that place builds the **OMS message**, not a stockrecord:

```java
list.add(sharedService.getStockChangeDTO(itemData, 0, damagedStock.getAmount().intValue(), 0, 0, 0, comment, WmsConstants.CODE_DAMAGED));
```

The stockrecord is written one level down, by `UnitloadService.moveStockToNewDamagedContainer`:

```java
Stockunit damagedStock = stockunitBusinessService.transferStockToUnitLoad(
    stockUnit, container, amount, WmsConstants.CODE_DAMAGED, null, comment, false, true);
```

— and that `null` is the order number, which `StockrecordService` plants verbatim via
`rec.setOrdernumber(orderNumber);` beside `rec.setActivitycode(activityCode);`. So the column is
`NULL` for every DAMAGED stockrecord on every tenant, by construction. (Hydra prd independently shows
**no `DAMAGED` rows at all** in `stockrecord` — 10 codes, none of them `DAMAGED` — consistent with its
low damage volume.)

*Blind spot:* I measured two tenants (`wh01_shipitez_v2`, `wh01_hydra_v2`). I did not measure the
other four. The code path above is tenant-independent, so I am asserting the mechanism from source and
using the two measurements as confirmation, not as the derivation.

**Fix — pick one, and write it into §3.2 rather than leaving the query as-is:**

- Grade on the **outcome**, not on a stockrecord join: the damaged portion is a `Stockunit` at
  `entity_lock = QUALITY_FAULT` in a container at the `Damaged` location (`setLockDamaged` sets
  `damagedStock.setEntityLock(WmsConstants.BusinessObjectLockState.QUALITY_FAULT)` inside the
  boundary, explicitly so a crash cannot leave it pickable). Join
  `adviceposition → goodsreceiptposition → stockunit` and compare the QUALITY_FAULT amount against
  `notifieddamagedamount`. This works with no schema change beyond D6 itself.
- Or add a second column / timestamp recording that the damage was *applied*, and make the worklist
  `notifieddamagedamount > 0 AND damage_applied_at IS NULL`. Costs the same migration, and is by far
  the easiest thing to reason about — but it is a second column, so decide deliberately.

Either way the fix must be **negative-tested**: run it against a position that *was* successfully
damaged and confirm it is absent from the result. As written, the current query returns that row, and
because it is embedded in a plan rather than a script nothing would have caught it.

### M3 — the column is otherwise write-only in code

*Method:* `git grep -n "notifiedamount"` over `origin/develop -- src/main/java src/main/resources` as
the analogue census (the new column will have the same reach as its sibling at best), plus a read of
the repository's SDR annotations. Result: after D6 there is **no** repository method, projection,
JPQL/native query, view column or HTTP route that reads `notifieddamagedamount`.

`AdvicepositionRepository` is explicitly withdrawn from the HTTP surface:

```java
@RepositoryRestResource(collectionResourceRel = "adviceposition", path = "adviceposition", exported = false)
```

(SBDEV-3183 Slice 2), so there is not even an incidental Spring Data REST read. Adding a field to the
entity therefore does not surface it anywhere.

That is not fatal on its own — an operator-run SQL worklist is a legitimate recovery mechanism in this
estate — but combined with H1 it means: **as specified, D6 adds a Flyway migration for a column that
is written by one code path and read by nothing that works.** Fixing H1 is what converts it back into
the mechanism the plan says it is.

*Blind spot:* a consumer added on an unmerged branch. The all-ref sweep I ran was for migration
filenames, not for Java symbols.

---

## Priority 5 — backward compatibility

### The view and the report functions: no impact ✔

`receiving_dto_view` selects the column **explicitly** (`ap.notifiedamount AS orderedbottles`, with a
matching `GROUP BY … ap.notifiedamount`) — `V2.2.00__base_v2_schema.sql` and the mirrored definition
in `ReceivingDtoViewRepository`'s native query. A new column on a base table is invisible to an
explicit select list, and even a `SELECT *` view would be unaffected, because Postgres expands `*` at
view-creation time. **No view needs recreating, so D6 cannot trip the
`CREATE OR REPLACE`-ownership hazard that froze `V2.2.06`** — that hazard applies to migrations that
replace functions/views, and this one does not.

### L1 — the consumer census under-reports, and the plan states the wrong bound

§3.2 and §6 both say the blast radius is *"bounded to two Java consumers plus the view behind one of
them"*. `git grep -n "notifiedamount" origin/develop -- src/main/java` returns two further **read**
sites the plan never names, and they differ in kind — they are *behavioural guards*, not reporting:

- `AdviceService` — the **short**-delivery guard on the transition to FINISHED:
  `if (amountReceived < advicePosition.getNotifiedamount().intValue())` → `throw new BusinessException("Not all notified amount received for position:" …)`,
  inside `if (!advice.getAllowshortdelivery())`.
- `ReceivingService` — the over-delivery guard the plan *does* discuss:
  `int notifiedAmount = adviceposition.getNotifiedamount().intValue();` →
  `throw new BusinessException("Not allowed to receive more than notified! …")`, inside
  `if (!advice.getAllowoverdelivery())`.

Neither changes outcome on the auto-receive path, because `AdviceRestController` sets **both** flags
unconditionally, adjacent lines:

```java
adviceEntity.setAllowshortdelivery(true);
adviceEntity.setAllowoverdelivery(true);
```

But the plan makes a specific argument out of this — *"Setting `notifiedamount` to the total
**removes** the dependency instead of pinning it, so no test needs to guard that flag"* — and that
argument is only half true. D6 removes the dependency on `allowoverdelivery` and **silently acquires
the symmetric one on `allowshortdelivery`**: post-D6, `notifiedamount` is the total, so a mixed RETURN
advice that is finished having received only the undamaged portion (any path where the damage step
runs but the receive is partial) would now trip the short-delivery guard if that flag were ever
`false`. It is always `true` on this path today. Say so, rather than claiming no flag dependency
remains.

Also, no consumer sums or compares the **new** column — nothing reads it at all (M3) — so the brief's
NULL-handling question has a clean answer: **there is no NULL-handling risk, because there are no
consumers.** That is the same fact as M3 read from the other side.

---

## Priority 6 — does D6 still earn its place?

**Yes — but on a narrower basis than §3.2 states, and the two halves of D6 should be scored
separately, because only one of them needs the migration.**

**Half A — `notifiedamount = undamaged + damaged`.** Earns its place outright, and it is **not a
migration**: it is a one-line change to an existing column. It removes the accidental reliance on
`adviceEntity.setAllowoverdelivery(true)` being set ~130 lines earlier; it keeps E3's
`goodsreceiptposition.amount == notifiedamount` invariant (§6 is right that leaving `notifiedamount`
at the undamaged quantity would have broken the plan's own health check); and it makes the receiving
screen's `orderedbottles` show what physically arrives. Keep it regardless of what happens to Half B.
Its costs are H2 and H3, both fixable in the same edit.

**Half B — the `notifieddamagedamount` column and `V2.2.31`.** This is the half the migration is for,
and §3.2 justifies it *solely* as recovery data ("gives the recovery story an actual data source").
H1 shows the query that was the data source does not work, and M3 shows nothing else reads the column.
So the justification as written does not currently hold.

The brief asks whether D6 is now "carrying a Flyway migration for less benefit than when it was
decided". Partly — but not for the reason the brief suggests. The D8 withdrawal did not weaken it:
Half A still answers the over-delivery point, and Critic **H5** ("The recovery story for a failed
damage step has no data behind it") is still open and is still the thing Half B exists to close. What
weakens it is that Half B closes H5 only if the worklist works, and it does not.

**Recommendation: keep D6, fix the worklist. Do not drop it.** The deciding argument is that
`notifiedamount` alone does not decompose — once it is the total, nothing in the WMS records *how much
of it was damaged*, so after the fact you cannot tell a mixed line from a pure one, in any failure
state or in any audit. That is a permanent, unrecoverable loss of information about a quantity a
client reported as missing, and it is exactly the class of loss this whole ticket exists to stop. One
nullable column on a 2.8 MB table, on tenants that all own it, is a very cheap way to not lose it.

Dropping Half B and keeping Half A is **defensible** and would remove the Flyway run from Phase 1
entirely — if Nam wants the smallest possible Phase 1, that is the lever. It is not what I would
choose, and it should be an explicit decision rather than a consequence of H1 going unnoticed.

---

## Findings by severity

| # | Sev | Finding | Fix cost |
|---|---|---|---|
| **H1** | High | §3.2's recovery worklist is inert — `stockrecord` never carries `activitycode='DAMAGED'` *and* an `ordernumber` (396 rows / 0 with ordernumber on `wh01_shipitez_v2`; structurally, `transferStockToUnitLoad(…, CODE_DAMAGED, null, …)`). It returns every damaged position forever, so it cannot identify unrecovered ones. This is D6's stated justification. | rewrite the query (join via `goodsreceiptposition → stockunit.entity_lock = QUALITY_FAULT`), + a negative test |
| **H2** | High | `notifiedamount = undamaged + damaged` over two boxed `Integer`s NPEs for every caller omitting the new key → HTTP 500 on a `permitAll()` endpoint, for all current traffic. §6 asserts the outcome; no section specifies the coalescing and no test row grades it. | 1 line + 1 test |
| **H3** | High | The D6 write is unconditional in the save loop; the damaged-field validation lives in `resolveRefs`, which runs only under `autoReceive`. REGULAR advices / auto-receive-off tenants / empty-position RETURNs accept an arbitrary, unauthenticated `amount_of_bottles_damaged` into `notifiedamount`. §6's "REGULAR advices unchanged" row is false for the write. | move the validation to the loop |
| **M1** | Med | §5.1 row 1a claims a missed migration "fails at Hibernate's schema validation". Prod is `ddl-auto=none` (`application.properties:105`); `validate` is test-only. Real mode is a per-request `42703` behind green probes, across the 18 `src/main/java` files touching `Adviceposition`. | rewrite the Notes cell |
| **M2** | Med | Row 1a's probe detects a stalled tenant, not an unowned table — different questions. Measured answer is benign (all 6 tenant DBs: app role owns `adviceposition`), but add the ownership query to the probe. | +1 SQL row |
| **M3** | Med | The column is write-only: no repo method, projection, view or route reads it; `AdvicepositionRepository` is `exported = false`. Only reader is the query in H1. | resolved by fixing H1 |
| **M4** | Med | Sibling field is `= BigDecimal.ZERO`; copying that idiom makes every new row `0.00`, falsifying §5.1 row 5 / §6's "`null` = predates the feature". Also false already for the 5 other `Adviceposition` writers D6 does not touch. | specify "no initialiser" |
| **L1** | Low | Census says "bounded to two consumers"; grep returns two more *behavioural* readers (`AdviceService` short-delivery guard, `ReceivingService` over-delivery guard). D6 trades a dependency on `allowoverdelivery` for one on `allowshortdelivery` and claims it removed both. | reword §3.2/§6 |
| **L2** | Low | Migration idiom: plan uses `V2.2.03`'s bare unqualified `ADD COLUMN` (the file CLAUDE.md calls "not replay-safe"); `V2.2.13` and `V2.2.30` use `public.` + `IF NOT EXISTS`. Also no `-- WHY` header, which every `V2.2.2x` file has. | 2 lines |
| **L3** | Info | `V2.2.31` free across all 287 remote refs; positive control = `V2.2.30` found on 12 refs. Re-run before writing the file (a sweep can't see a later push). Directory has 3 historical duplicate version numbers across branches — worth a sentence in §5.1 row 1 as the reason the rule exists. | — |
| **L4** | Low | §6 says `adviceposition` has 20 columns. It has **19** (V2.2.00 DDL; `information_schema.columns` on 2 tenants). | 1 char |
| **L5** | Info | Lock/rewrite risk negligible: PG11+ nullable-no-default is catalog-only; table is 9,613 rows / 2832 kB on the largest tenant. Worth one line so it isn't re-derived. | 1 line |

## The single thing I would fix first

**H2** — the unboxing NPE. It is one line, it is specified wrongly in two places (§4 row 1b and the
§5.2 checkbox) with only an outcome-level assertion in §6 to contradict it, and an implementer
following the checkbox literally takes down `/rest/advice/create` for every OMS caller on a
`permitAll()` endpoint the moment Phase 1 reaches dev. H1 is the more interesting finding and the one
that decides whether the migration is worth shipping, but H2 is the one that breaks production.

## What I did not review

Everything outside D6, per the brief: the D1/D3 receive-then-damage design, §3.3's `setLockDamaged`
reuse, §3.5's pre-flight, §3.6's `printLabel`, §3.7's v1 tolerance test, the three qa-ui/qa-api
defects (§3.8–§3.9), §3.11's withdrawn D8 and the OMS netting argument, and the §7 test strategy
except where a row would have caught a D6 defect. I read §3.4 only for its dependence on D6 (the
"free choice" ordering argument), not for the `DAMAGE_FAILED` status design itself — note that that
argument rests on D6's recoverability claim, so **H1 partially undercuts §3.4's ordering rationale
too**: "with D6 neither state is unrecoverable" is only true once the worklist works.
