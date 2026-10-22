# SBDEV-3418 — DB field evidence

Measured 2026-09-22 against Hydra UAT (`nywh-hydra-uat`) and Hydra prd (`wms2-hydra`).
Every scan whose expected answer is zero carries a positive control whose answer is known non-zero.

---

## 1. The ticket's headline figures — reproduced exactly

| tenant | duplicate `(billoflading_id, number)` groups | childless top-level positions | positive control |
|---|---|---|---|
| Hydra UAT | **4** (8 rows) | **8** | 28,329 rows / 996 BOLs / 1,060 top-level — all non-zero |
| Hydra prd | 0 | 0 | 671 rows / 37 BOLs / 41 top-level — all non-zero |

The ticket recorded prd as `663 rows / 37 BOLs`; it is now 671 / 37. Consistent growth, same shape.

"Childless top-level position" is defined here as `carrier_id IS NULL AND NOT EXISTS (child WHERE
child.carrier_id = p.id)`. **Blind spot:** that definition counts any top-level row with no children,
which includes a legitimately childless BOL position if such a thing exists; it is not proof that
every one of the 8 came from a partial write. Rows 1938190 and 2371386 are the strongest cases —
see §3.

---

## 2. ⚠ The duplicate numbers are NOT a concurrency artifact

All 8 duplicate rows, with timestamps:

| id | bol | number | created | shape |
|---|---|---|---|---|
| 625314 | 625302 | OBOL000292-000011 | 2023-08-17 **14:24:03** | stock (itemdata+amount, carrier=625312) |
| 625316 | 625302 | OBOL000292-000011 | 2023-08-17 **14:26:59** | pallet (carrier NULL, source 31097813) |
| 625315 | 625302 | OBOL000292-000012 | 2023-08-17 **14:24:03** | stock (itemdata+amount, carrier=625312) |
| 625317 | 625302 | OBOL000292-000012 | 2023-08-17 **14:26:59** | parcel (carrier=625316, order 30092049) |
| 987534 | 987526 | OBOL000424-000008 | 2024-02-19 **16:39:22** | parcel (carrier=987533, order 48635686) |
| 987536 | 987526 | OBOL000424-000008 | 2024-02-19 **16:39:36** | pallet (carrier NULL, source 48862932) |
| 987535 | 987526 | OBOL000424-000009 | 2024-02-19 **16:39:22** | stock (itemdata+amount, carrier=987534) |
| 987539 | 987526 | OBOL000424-000009 | 2024-02-19 **16:39:44** | pallet (carrier NULL, source 48862933) |

**The two members of each colliding pair are separated by 14 s, 22 s and ~3 min — and share the same
`operator_id` (69250).** That is a sequence of *separate* `scanGate` invocations by one operator, not
two concurrent requests racing.

### 2.1 The mechanism, proven arithmetically — it is `size()` over a set that SHRINKS

`BillofladingPositionService.createEntity` derives the number from a **count of the rows that exist
right now**, not from a max or a sequence:

```java
List<BillofladingPosition> bolPositions = billofladingPositionRepository.findByBillofladingId(billOfLading.getId());
String number = basicService.generatePositionNumber(billOfLading.getNumber(), bolPositions.size());
```

`BasicService.generatePositionNumber` is pure formatting — `String.format(prefix + getFormat(),
positionIndex)` — so `number = size() + 1`, zero-padded.

Every position on BOL 987526 that survives today, in creation order. For each, the number it was
issued tells us what `size()` must have been at that instant; comparing that against the rows that
survive from before that instant reveals how many rows had already been deleted.

| time | first id created | number issued | ⇒ `size()` was | surviving rows created earlier | ⇒ deleted rows alive at that instant |
|---|---|---|---|---|---|
| 16:39:10 | 987527 | 000001 | 0 | 0 | 0 |
| 16:39:15 | 987530 | 000004 | 3 | 1 | **2** |
| 16:39:22 | 987533 | 000007 | 6 | 4 | **2** |
| 16:39:36 | 987536 | **000008** ← collision | 7 | 7 | **0** |
| 16:39:44 | 987539 | **000009** ← collision | 8 | 8 | 0 |
| 16:40:28 | 987542 | 000012 | 11 | 11 | 0 |

**The model accounts for every number exactly, at all six points, including both collisions**, and
it is over-determined — six independent equations, one free parameter. Read off the last column:
two rows (necessarily numbered 000002 and 000003, the only numbers never observed) existed from
16:39:10, were still alive at 16:39:22, and **were deleted between 16:39:22 and 16:39:36** — i.e. by
the `handleTruckOffLoading` of the 16:39:36 scan. That deletion is what drops `size()` from 9 to 7
and makes the very next `createEntity` re-issue `000008`.

The same thing happens once more at 16:39:44, where the scan at 16:39:36 having added only its
pallet row leaves the count one short of the high-water mark.

*Note on an instrument that does NOT support this: the `id` gaps (987528, 987529, 987537, 987538) are
**not** evidence of deletion here. This schema allocates ids from a single shared sequence
(`pg_sequences` in `public` returns 4 sequences, one of them `seqentities`; none is
`billoflading_position`-specific), so a gap in one table's ids may simply be ids consumed by another
table. The argument above rests only on the issued `number` values, which are per-BOL and
count-derived, and it does not depend on the id gaps at all.*

So the duplicate numbers are **not** a concurrency race, and **not** a lost-update. They are a
count-vs-max defect: an index derived from `size()` of a collection that `handleTruckOffLoading`
shrinks.

### 2.2 ⚠ Consequence — the boundary does NOT close this half of the leak

A transaction boundary and row locks serialise *concurrent* writers. Here the writers are 14 seconds
and 22 seconds apart, by one operator, each already committed before the next began. Serialising them
changes nothing: the second invocation would still read a `size()` of 7 and still emit `000008`.

**This contradicts the ticket's framing** that *"the boundary closes a live data-quality leak"* — it
closes the childless-position half (§3), not the duplicate-number half. Escalation trigger 1 (the DB
query contradicts the ticket) fired here.

Concretely, for the plan:

- **Do not write an acceptance criterion claiming duplicate `(billoflading_id, number)` rows stop
  occurring.** It would be false, and it would pass anyway — see §4.
- The real fix for this is to derive the number from a high-water mark (`max`) or a durable
  per-BOL counter instead of `size()`. That is a separate change in
  `BillofladingPositionService.createEntity`, which is shared with other callers, so its blast
  radius is not SBDEV-3418's. **Propose it; do not fold it in.**

*Note where two instruments disagreed: the Lane A code read concluded this was a read-modify-write
race between concurrent `createEntity` calls. That mechanism is real and also possible, but it is not
what produced these eight rows — the timestamps rule out concurrency and the arithmetic above
accounts for every number exactly. Recorded rather than silently resolved.*

---

## 3. The 8 childless top-level positions — a plausible two-transaction mechanism

| id | bol | number | source label | siblings on BOL | created |
|---|---|---|---|---|---|
| 987527 | 987526 | OBOL000424-000001 | OUT-000040 | 38 | 2024-02-19 |
| 987536 | 987526 | OBOL000424-000008 | OUT-000043 | 38 | 2024-02-19 |
| 1257830 | 1257812 | OBOL000518-000018 | OUT-000790 | 21 | 2024-06-20 |
| 1537578 | 1537577 | OBOL000594-000001 | OUT-000931 | 7 | 2024-10-14 |
| 1779442 | 1779441 | OBOL000659-000001 | OUT-001006 | 36 | 2025-01-13 |
| 1938190 | 1938184 | OBOL000950 | OUT-001042 | **1** | 2025-03-13 |
| 2371386 | 2371344 | OBOL001369-000033 | AOUT-000089 | **1** | 2025-07-31 |
| 2488077 | 2488059 | OBOL001402-000000 | OUT-007194 | 9 | 2025-09-05 |

All 8 are `state = CLOSED`, i.e. they rode through to a closed BOL and onto the manifest, as the
ticket says. The two rows with `siblings_on_bol = 1` are a pallet position that is the *only* position
on its BOL — no parcels, no stock.

### 3.1 What §2.1's arithmetic proves about one of them — and what it leaves open

Row 987527 is the pallet position created at 16:39:10 for pallet `OUT-000040` (unitload 48862929).
§2.1 shows its two descendants — the numbers 000002 and 000003 — existed at 16:39:22 and were gone
by 16:39:36.

Those two rows are exactly what `deleteBolPositionsCarrierIds` deletes for that pallet, and nothing
else: `findBolCarrierIdListByUnitLoadLabelId` returns `{987528 (the parcel, whose carrier is 987527),
987527 (the pallet itself)}`, and `DELETE … WHERE bp.carrierId IN :carrierIds` then removes the stock
row (carrier 987528) and the parcel row (carrier 987527) — **two rows, matching exactly**. The very
next statement, `deleteBolPositionById(987527)`, should have removed 987527 too.

**It did not. So the first delete took effect and the second did not** — which is the childless
shape, and it is the strongest single piece of evidence here that the two deletes are not atomic
with respect to each other.

⚠ **What is NOT established: which call site ran that cleanup.** It was not the 16:39:36 `scanGate`
— that scan's pallet is 48862932, which had no `billoflading_position` row yet, so
`findBolIdByUnitLoadLabelId` would have returned `null` and the `if (bolPositionId != null)` guard
would have skipped both deletes entirely. The remaining candidate is
`MobileMoveUnitloadService.scanDestination`, which calls `handleTruckOffLoading` at its other call
site — but **that method IS `@Transactional`**, so its two deletes join one transaction and should
commit or roll back together, which does not obviously produce this outcome either. Neither
candidate fully explains it on the evidence available.

**Do not resolve this by reasoning.** It is a good candidate for the integration test to settle,
and it does not block the work: both candidate mechanisms are closed by putting the two deletes
inside one boundary, which the fix does anyway.

### 3.2 The code-level mechanism

`handleTruckOffLoading` performs its cleanup as **two independent transactions** whenever it is
reached from `scanGate`, because `MobileTruckLoadingService` has no boundary and each `@Modifying`
finder carries its own `@Transactional(REQUIRED)`, which therefore opens a *new* transaction rather
than joining one:

1. `deleteBolPositionsCarrierIds(carrierIds)` — deletes rows whose `carrier_id` is the pallet position
   or one of its parcel positions, i.e. both the parcel and the stock levels;
2. `deleteBolPositionById(bolPositionId)` — deletes the pallet position itself.

If (1) commits and (2) does not, the pallet position survives with every descendant gone — exactly
the observed shape. Putting both inside one boundary closes this. **Stated as a candidate, not a
verdict:** the data is consistent with it, and so is the code, but nothing here rules out the
alternative that `scanGate` simply died after creating the pallet position and before creating the
parcel ones. Both are closed by the same fix, which is why this does not need resolving before work
starts.

---

## 4. ⚠ Recency — the defect has not recurred on UAT in the last 12 months

| measure | value |
|---|---|
| most recent `billoflading_position` created | 2026-07-10 20:45 |
| most recent top-level position created | 2026-07-10 20:45 |
| positions created in the last 365 days | 4,057 |
| top-level positions created in the last 365 days | **166** |
| BOLs created in the last 365 days | 165 |
| defective rows (childless or duplicate) in that window | **0** |

Every one of the 8 childless rows and all 4 duplicate groups predate 2025-09-06. All-time the childless
rate is 8/1,060 top-level = 0.75%; over the last 12 months it is 0/166.

**What this means and what it does not.** It does not mean the defect is fixed — nothing changed in
this code path, and 166 samples cannot distinguish a 0.75% rate from zero (at 0.75% you would expect
~1.2 occurrences in 166, so observing 0 is unremarkable). It does mean:

- an acceptance criterion of the form *"this count stays at zero"* is **ungradeable** — it is already
  zero over the recent window, so it would pass against the unfixed code;
- the urgency argument rests on prd, and **prd has never produced one of these** (0 of 41 top-level
  positions, 0 of 37 BOLs). prd volume on this path is ~1.6% of UAT's.

---

## 5. The non-unique-finder hazard is LATENT, not live

`handleTruckOffLoading` resolves the pallet through two finders that assume at most one
`billoflading_position` per unitload label:

- `findBolIdByUnitLoadLabelId` returns a scalar `Long` — more than one row raises
  `IncorrectResultSizeDataAccessException`;
- `findBolCarrierIdListByUnitLoadLabelId` contains `where bp.carrier_id = ( SELECT bp2.id … WHERE
  u.labelid = :unitLoadLabelId )` — a **scalar subquery**, which raises Postgres
  `21000 more than one row returned by a subquery used as an expression`.

Measured exposure:

| tenant | unitload labels with >1 `billoflading_position` | positive control |
|---|---|---|
| Hydra UAT | **0** | 10,462 labels, all with exactly 1; `max(rows per label) = 1` |
| Hydra prd | **0** | 233 labels, all with exactly 1; `max(rows per label) = 1` |

So this is a latent hazard with zero live exposure on either tenant today, and it is **not** part of
SBDEV-3418's scope. Recorded because it is the same defect class as the tote-reuse `Optional<>` finder
failures, and because a change that makes re-scanning a pallet more common would activate it.

---

## Queries

All four queries are reproduced in the ClickUp triage comment of 2026-09-22 and were run through the
`nywh-hydra-uat` and `wms2-hydra` MCP servers. Each aggregate query carries its controls in the same
`SELECT`, so a broken connection cannot return a silent zero — a failed call errors rather than
returning rows.
