# SBDEV-1512 Phase 1 — SECURITY review

**Lane:** security-1512
**Date:** 2026-09-16
**Tree reviewed:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-1512-security`, this lane's own worktree, detached at `5136ed87` — 4 commits ahead of `origin/develop` @ `4bef7e77` (`5136ed87`, `17a9f062`, `6bf54176`, `e8bcbbe3`). Diff basis: `git diff origin/develop...HEAD`.

**No test run backs any finding here.** This lane ran **no** Maven at all: every finding is a source and control-flow read plus direct DB queries over MCP, so the concurrent-Maven false-red effect cannot have touched it. The one test-related observation (no overflow case exists) is a `git diff` grep over the test sources, not an executed suite. Findings were first drafted against the shared `SBDEV-1512` worktree and then re-verified in this lane's own tree: both were `git status --porcelain`-clean at the same HEAD `5136ed87`, and the load-bearing citations (the `AdviceRestController:457-458` overflow expression, the five-line cap census, the `< 1`-above-cap ordering at `ReturnAdviceAutoReceiveService:385-394`, and the 603 template at `WmsConstants:1749`) reproduce identically.

**Threat model:** taken as given — `PUT /rest/advice/create` is `permitAll()`, tenant selected from an unauthenticated header. Not re-derived.

---

## Verdict summary

| ID | Severity | Title |
|----|----------|-------|
| S1 | **High** | `int` overflow in the unconditional save loop persists a **negative** `notifiedamount`; the pre-change `>= 0` invariant is gone |
| S2 | Medium | The magnitude cap still lives **only** on the auto-receive path; the new field is a second uncapped attacker-controlled channel into `notifiedamount` |
| S3 | Medium | Amplification: the damage pass adds a lock, a REQUIRES_NEW sequence write, a stock split, an OMS notification and a per-SKU replenishment recalc **per position**, ×500 |
| S4 | Low | 603's template uses the bare `%Ns` form that its own sibling 600 documents as a trap |
| S5 | Low | Log injection: `sku` is unguarded at the new ERROR site (inherited from the pre-existing site, not a regression) |
| S6 | Info | Test display names say `V2.2.31`; the migration is `V2.2.32`, and `V2.2.31` is a **different, real** migration |
| — | **Pass** | Q2(a) cap-splitting: **not** possible. Q3 disclosure: **no leak found**. Q4 D4 exposure: **exactly as accepted, and narrower than the bare statement** |

---

## S1 — `int` overflow persists a negative `notifiedamount` (High)

`src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java`, inside the **unconditional** per-position save loop:

```java
Integer rawDamaged = advicePosition.getAmountOfBottlesDamaged();
int damaged = rawDamaged == null ? 0 : rawDamaged;
position.setNotifiedamount(new BigDecimal(advicePosition.getAmountOfBottles() + damaged));
position.setNotifieddamagedamount(rawDamaged == null ? null : new BigDecimal(rawDamaged));
```

Both operands are `int` after unboxing, so the sum is evaluated in 32-bit arithmetic. The only guards
in scope are the two per-field ones immediately above:

```java
if (advicePosition.getAmountOfBottles() < 0) { throw ... }
if (advicePosition.getAmountOfBottlesDamaged() != null
        && advicePosition.getAmountOfBottlesDamaged() < 0) { throw ... }
```

Each field passes independently while the **sum** wraps negative, and there is no magnitude cap on
this path.

**Cap census.** `git grep -n "MAX_UNITS_PER_POSITION\|MAX_POSITIONS_PER_ADVICE" -- src/main/java`
returns five lines and **all** of them are in `ReturnAdviceAutoReceiveService` — the two declarations
at `:84`/`:85` and the uses at `:260` and `:388`/`:391`, both inside `resolveRefs`, which runs only
`if (autoReceive)`. Blind spot: a grep census misses a cap expressed as a literal under a different
name; I did not find one, and `AdviceRestController`'s own new comment asserts the same absence.

**What changed.** Pre-change the line read `position.setNotifiedamount(new BigDecimal(advicePosition.getAmountOfBottles()))`,
which the `< 0` guard made non-negative **by construction**. The addition removes that invariant. The
author's comment on this hunk enumerates the three shapes that skip `resolveRefs` (REGULAR advice,
RETURN on an auto-receive-off tenant, RETURN with empty positions) and correctly adds a **negative**
check — but not an overflow or magnitude check, so the new second tier does not close the hole the
comment is reasoning about.

**Nothing downstream rejects it.** On `wms2-wineco-dev`:

- `pg_constraint` with `contype='c'` on `public.adviceposition` → **`[]`** — no CHECK constraint at all.
- `notifiedamount` is `numeric(19,2)`, `is_nullable = YES`. `numeric(19,2)` holds `-2147483648.00` comfortably.
- `SELECT count(*), count(*) FILTER (WHERE notifiedamount < 0) FROM public.adviceposition;`
  → **42,407 total, 14 already negative**. So a negative is not merely storable, it is already present
  and no consumer treats it as impossible.

Blast radius per the author's own comment: `notifiedamount` feeds `AdviceRepository`'s
`SUM(ap.notifiedamount)` as `qtyRequired` and `ReceivingDtoViewRepository`'s `orderedbottles`.

**Reachability.** The save loop first requires a resolvable `client_id`, an `sku` that resolves via
`itemdataService.findByClientIdAndItemNr` (`AdviceRestController:405-409`), and a `box_id` that
resolves (`:417-421`). So the caller needs valid tenant reference data — a real mitigating factor,
and the only one. It is not an authentication barrier.

**The auto-receive path is safe, but accidentally.** `ReturnAdviceAutoReceiveService:387` computes the
same expression, `int totalAmount = position.getAmountOfBottles() + damagedAmount;`, and overflows
identically — but the next statement is `if (totalAmount < 1) { throw ... }`. The sum of two
non-negative `int`s, when it wraps, always lands in `[-2^31, -2]`, so every overflow is caught there
and the cap at `:388` **cannot** be bypassed by overflow. Nothing states this. No comment names it and
no test covers it (`git diff origin/develop...HEAD -- '*/test/*' | grep -i "MAX_VALUE\|overflow"` →
zero hits; the only related hit is T1.18, which covers negatives). Reordering the two checks, or
hoisting the cap above the `< 1` guard, would silently open it.

**Recommended fix (invariant, not instance).** Compute in `long` and give the unconditional save loop
the same magnitude bound `resolveRefs` already has, so one rule covers all four paths:

```java
long total = (long) advicePosition.getAmountOfBottles() + damaged;
if (total > MAX_UNITS_PER_POSITION) { throw ...FIELD_MALFORMED_FORMAT... }
```

At minimum, widen to `long` and reject `> Integer.MAX_VALUE`. Add the missing test as an overflow case
beside T1.18 and mutation-check it by reverting the widening.

---

## S2 — cap coverage (Medium)

**Q2(a), splitting across the two fields: not possible on the receive path — confirmed.**
`ReturnAdviceAutoReceiveService:388` now grades the total:

```java
if (totalAmount > MAX_UNITS_PER_POSITION) {
    meterRegistry.counter("wms2.returns.autoreceive.rejected_amount_cap").increment();
```

and `executeInternal` receives `line.amount()`, which `ResolvedLine`/`AutoReceiveLine` carry as
`totalAmount` — `receivingService.receiveGoods(line.advicePositionId(), null, false, line.amount(), line.amount(), 1, ...)`.
So at most 100,000 units per position are received however the caller splits them. The move of the cap
from the undamaged field to the total is correct.

**Q2(b), "every path that receives": the receive paths are covered; the write path is not.**
Auto-receive is the only path this diff makes receive, and the dock path
(`ReceivingController` → `receiveGoods`) is authenticated and was never capped — unchanged, not a
regression. But `amount_of_bottles_damaged` is accepted and summed into `notifiedamount` on the
REGULAR and auto-receive-off paths with **no cap of any kind**, where nothing ever applies the damage.
The *class* of defect is pre-existing — `amount_of_bottles` is equally uncapped there — so I am not
calling this new. What is new is a second uncapped channel, and the loss of the sign invariant (S1),
which is why S1 carries the severity and this does not. The clean fix for both is the same one line in
S1.

---

## S3 — amplification (Medium)

Per position with `damagedAmount > 0` the new pass adds, on top of the existing `receiveGoods`:

- `stockunitRepository.findById` (`applyDamage`);
- inside `StockunitService.setLockDamaged` (`:738`): `locationRepository.findByName(STORAGE_LOCATION_DAMAGED)` and `unitloadTypeRepository.findByName(UNIT_LOAD_TYPE_BOX)`, neither cached, once per call (`:770`, `:773`);
- `unitloadService.mintUnitloadLabel()` (`:777`) — a **REQUIRES_NEW** sequence write that commits on its own, so the sequence is burned even on a later failure;
- `unitloadService.moveStockToNewDamagedContainer(...)` (`:778`) — opens with `findByIdForUpdate`, i.e. a **row lock** under the global 5s lock timeout, and creates a new `Unitload` + a new `Stockunit` + `stockrecord` rows;
- `itemdataService.getById` (`:785`);
- `messageService.sendStockChangeMessage` (`:788`) → `stockChangeNotificationService.sendAfterCommit` — an **OMS STOCK_UPDATE** per damaged position;
- `triggerReplenishmentMaintenance(stockUnit.getItemdataId())` (`:790`) → `recalculateForItem`, itself lock-taking, for the **whole SKU**, not just the new unit;
- then `self.stampDamageApplied(...)` in a **further separate transaction** (`findById` + `save`).

The caller controls `damagedAmount > 0` on every line, and the new `< 1` guard grades the **total**, so
a fully-damaged line `{"amount_of_bottles": 0, "amount_of_bottles_damaged": 1}` is now contract-legal
where before it was rejected. The cheapest maximal request is therefore 500 such positions. The
`seenClientSkus` distinctness requirement plus the `Itemdata` lookup means 500 distinct real SKUs are
needed; `SELECT count(*) FROM public.itemdata` on wineco-dev returns **8,807**, so that bar is met on a
normal tenant.

`MAX_POSITIONS_PER_ADVICE = 500` was sized against a receive-only pass and is not revisited here.
Two things bound this and are worth recording rather than leaving implicit: `execute` is deliberately
**not** `@Transactional` (`:624`, `:630`) so no single tenant connection is held across the whole pass
— this is DB-work and lock contention, not connection-hold — and the damage loop `break`s on the first
failure, so a failing tenant does not multiply it.

**Recommendation:** either a separate, lower cap on the number of positions carrying a damaged
quantity, or an explicit statement of the new worst case on the ticket so the accepted risk is the
measured one. Not a blocker on its own.

---

## S4 — 603 format string uses the trap form its sibling documents (Low)

`WmsConstants.java`, the 600 arm, carries an explicit warning:

```java
case RETURN_AUTO_RECEIVE_PARTIAL:
    // EXPLICITLY positional (%N$s), unlike the "%1s" forms elsewhere in this switch.
    // Bare "%1s" is NOT positional in Java — it is "%s" with a minimum width of 1, so
    // arguments are consumed in order ...
    description = "return advice '%1$s' partially received: failed on sku '%2$s' after "
        + "%3$s of %4$s positions (reason %5$s, correlation id %6$s)";
```

The new 603 arm uses the bare form anyway:

```java
case RETURN_AUTO_RECEIVE_DAMAGE_FAILED:
    description = "return advice '%1s' received all %2s position(s) but could not lock the "
        + "damaged quantity on sku '%3s'; the advice is complete and the damage move is "
        + "outstanding (correlationId %4s)";
```

**Arity is correct.** `AutoReceiveOutcome.damageFailed` calls
`getErrorCodeText(RETURN_AUTO_RECEIVE_DAMAGE_FAILED, adviceNumber, total, sku, correlationId)` — four
args, four conversions, and the template's textual order (advice, count, sku, correlationId) matches
the argument order, so it renders today and no literal `%4s` ships. The team lead's specific concern is
discharged.

Two residual defects:

1. `%2s`/`%3s`/`%4s` are **minimum widths**, so a single-digit `total` renders with a leading space
   (`received all  5 position(s)`) and a 1–2 character SKU is space-padded. Cosmetic, but it reaches an
   OMS operator banner.
2. Correctness depends on argument **order**, not on the numbers, while the code comment above it
   claims the numbers are load-bearing ("Four args, and the arity is load-bearing"). Since
   `getErrorCodeText` swallows `IllegalFormatException` and returns the raw template, a future arg
   reorder produces a **wrong sentence**, not an exception or a visible `%N$s`. The sibling's own
   comment is the argument for fixing this now.

**Fix:** change to `%1$s`/`%2$s`/`%3$s`/`%4$s`, matching 600.

---

## S5 — log injection at the new ERROR site (Low, inherited)

The new site, `ReturnAdviceAutoReceiveService` ~`:780`:

```java
LOG.error("RETURN auto-receive DAMAGE FAILED adviceId={} adviceNumber={} "
        + "failedSku={} failedPositionExternalId={} damagedAmount={} received={} "
        + "correlationId={}",
    plan.adviceId(), plan.adviceNumber(), line.sku(), line.positionExternalId(),
    line.damagedAmount(), received, correlationId, e);
```

- **`positionExternalId` is guarded.** It is `position.getReferenceId()`, and `resolveRefs:334` rejects
  it before any `ResolvedLine` is built: `if (isUnsafeReference(position.getReferenceId())) { throw ... }`,
  where `isUnsafeReference` is `reference.length() > 64 || reference.chars().anyMatch(c -> c < 0x20 || c == 0x7F)`.
  Correct, and at parity with `AdviceRestController:341`.
- **`sku` is not guarded.** `isUnsafeReference` is never applied to it. What bounds it is that
  `resolveRefs:402-405` requires `itemdataService.findByClientIdAndItemNr(...)` to resolve, so the value
  must already exist as `itemdata.item_nr`. DB check on wms2-wineco-dev:
  `SELECT count(*), count(*) FILTER (WHERE item_nr ~ '[\x00-\x1F\x7F]'), max(length(item_nr)) FROM public.itemdata;`
  → **8,807 rows, 0 with control characters, max length 41**. So an unauthenticated caller cannot forge
  a log line through `sku` today.

That is an existence lookup, not a sanitiser: an authenticated item-master write of an `item_nr`
containing CR/LF would turn the **unauthenticated** endpoint into a log-forging primitive. The
pre-existing site at `:736` has the identical shape, so this is **not a regression** — it is a gap the
new site inherits. One-line fix at both, matching `AdviceRestController:341`:
`isUnsafeReference(line.sku()) ? "<unsafe>" : line.sku()`.

Blind spots: one tenant queried; `item_nr` carries no DB-level character constraint; I did not audit
every log site in the file, only the ones this diff adds or that interpolate the same values.

---

## S6 — migration version stated wrongly in the tests (Info)

The migration file is `src/main/resources/db/migration/V2.2.32__adviceposition_notified_damaged_amount.sql`.
`AdvicePositionDamagedColumnsIntegrationTest` says `V2.2.31` in three places — its class javadoc
(`the plan's {@code V2.2.31} migration`) and both `@DisplayName`s.

This is actively misleading rather than merely stale: **`V2.2.31` is a real, different migration** —
`V2.2.31__cancellation_log_pickingorder_position_id.sql`, on `origin/develop` via `28a8a417` (SBDEV-3363).
An incident responder grepping `V2.2.31` from a failing test lands on the wrong script.

**Collision check (clean).** Sweeping all 289 `refs/remotes/origin` refs for `V2.2.3[0-9]` returns only
`V2.2.30__outbox_message_lane` and `V2.2.31__cancellation_log_pickingorder_position_id`. **`V2.2.32` is
free on every remote branch**, so the version choice is correct — only the test text is wrong. Blind
spot: a branch pushed after this sweep can still collide; `app.flyway.out-of-order` defaults to `true`
(`StartupFlywayMigrationRunner:60`), which makes a straggler survivable.

The migration itself is sound from a security standpoint: nullable, no default, no backfill, no DML, no
dynamic SQL, schema-qualified with `IF NOT EXISTS`.

---

## Q3 — does 603 leak anything across the `permitAll()` boundary? **No leak found.**

The 603 template carries exactly four values:

| Value | Provenance | Assessment |
|---|---|---|
| `adviceNumber` | WMS-generated advice number | Already disclosed by siblings 600 and 602 on the same endpoint |
| `total` | `plan.lines().size()` — the caller's own position count | Caller's own input |
| `sku` | Caller-supplied, echoed | Caller's own input |
| `correlationId` | `UUID.randomUUID()` | Opaque join key to the server log |

Absent, and deliberately so: the Damaged **location** name (`STORAGE_LOCATION_DAMAGED`, resolved inside
`setLockDamaged:770`), any **printer** name, any **entity id**, any SQL, and any **exception text** —
the exception `e` is passed only to `LOG.error`, never into the outcome. This matches the sanitisation
its siblings apply; compare `validate()`'s F4 comment, which withholds the DB printer name from the
caller on exactly this reasoning and logs it instead.

The controller's discrete `warning` map (`code`, `reason`, `correlation_id`, `advice`, `sku`,
`received`, `total`, `description`) adds nothing beyond what `description` already carries.
`reason` is `FailureReason.UNKNOWN` on this path, which discloses nothing.

Method: read the 603 template and its `getErrorCodeName` arm, the `damageFailed` factory, and the
controller's `warning` map construction, and compared each field against the 600/602 arms.
Blind spots: I did not audit what OMS renders from these values downstream; `adviceNumber` is a
WMS-internal sequence that this endpoint already returned before this change.

---

## Q4 — is the accepted D4 exposure exactly as accepted, or wider? **Exactly as accepted, and in three respects narrower than the bare statement.** Not re-litigated.

The gate is real: `StockUnitController:531`,
`@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_ACTION_ADJUST_LOCK_DAMAGED)` on
`POST /transferToDamaged`, which calls `stockunitService.setLockDamaged(stockUnit, adjustAmount, comment, printLabel, principal)`
at `:553`. `setLockDamaged` itself carries no gate and no `@Transactional`.

What the new `permitAll()` caller actually gets is a **proper subset** of that gated capability:

1. **The stock unit is not caller-selectable.** `applyDamage` takes its id from
   `createdByPosition.get(line.advicePositionId())`, a map populated exclusively from
   `receivingService.receiveGoods(...)`'s new return value **in this same request**, and reads
   `createdStockunitIds.get(0)`. The gated controller path takes an arbitrary `id` from the request
   body. An unauthenticated caller therefore cannot aim `setLockDamaged` at pre-existing stock — only
   at stock it just created.
2. **The amount is bounded twice.** By `totalAmount > MAX_UNITS_PER_POSITION` at `:388`, and again by
   `setLockDamaged`'s own clamp at `StockunitService:762`:
   `if (stockUnit.getAmount().compareTo(amount) < 0) { amount = stockUnit.getAmount(); }`.
   Since `totalAmount = undamaged + damaged`, `damagedAmount <= totalAmount` always holds, so the clamp
   is not even reached in normal operation.
3. **`printLabel = false`**, so `setLockDamaged`'s INBOUND-printer side effect is never reached — the
   author's stated reason, and it also removes a side channel.

`principal = null` is correct, not an oversight: `setLockDamaged` declares the parameter and never reads
it (checked the full method body, `:738-800`); attribution comes from the surrounding
`executeAsIntegrationUser` block.

**Stated plainly, since it is the one thing that reaches beyond the new stock unit:** `setLockDamaged`
also fires `messageService.sendStockChangeMessage` (an OMS STOCK_UPDATE, deferred via `sendAfterCommit`)
and `triggerReplenishmentMaintenance(stockUnit.getItemdataId())`, a replenishment recalculation for the
**whole SKU**. Those are inherent to reusing the method — which is the substance of what D4 accepted —
so they are not a widening of the capability. They are the reason S3 exists, and they are the honest
answer to "is the exposure exactly what was accepted": the *capability* is, the *per-request cost* is
larger than a bare reading of D4 suggests.

Blind spot: verified by reading `applyDamage`, `setLockDamaged` in full, and the controller gate. I did
not execute the endpoint, and I did not audit the `@RequiresFunction` interceptor's own coverage — that
gate's enforcement is established elsewhere and was out of scope here.

---

## Blocking / non-blocking

- **Blocking: S1.** One line, and it restores an invariant the pre-change code held by construction.
- **Should fix in the same pass: S4, S5, S6** — all one-line, and per the standing instruction to address Low findings rather than defer them.
- **Decide, do not silently accept: S3.** Either cap the damaged-position count or record the measured worst case on the ticket.
- **S2** resolves as a side effect of the S1 fix if the fix is the cap form.
