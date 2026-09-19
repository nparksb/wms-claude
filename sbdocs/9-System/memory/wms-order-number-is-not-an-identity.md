---
name: wms-order-number-is-not-an-identity
description: "customerorder.number is minted sequentially per tenant, so dev/UAT numbers COLLIDE with real production orders; externalnumber is the cross-system identity — check it before inferring business impact"
metadata:
  node_type: memory
  type: project
---

**`customerorder.number` is not an identity.** WMS mints it sequentially per tenant, and non-production
DBs are seeded from migration snapshots — so a number on dev/UAT can collide with a completely different
real order in production. **`customerorder.externalnumber` is the cross-system identity** (WMS sends it to
OMS as `unique_id`, and OMS resolves it against `parcel.parcel_id_str`).

**Measured on SBDEV-3363 (2026-09-16).** Two orders were carried through an entire T3 ticket — title,
description, ACs, an OMS-contract investigation — as *"2 customer orders stranded since February, a
customer has been waiting seven months"*. Their `externalnumber`s were **`DaveTest20240205-05_1`** and
**`DaveTest20240207-02_1`**: hand-made test orders on `wms2-wineco-dev`, `created`/`modified` about a
minute apart. In WineCo's live v1 the same *numbers* belong to orders that reached `FINISHED(700)` and
shipped. Nobody was waiting. The planned data repair would have been a guaranteed no-op, because that
`externalnumber` matches no OMS parcel.

**Cheap tells that a row is hand-made test data:**
- `externalnumber` that is prose rather than an id (`DaveTest…`, `test`, a person's name);
- `created` and `modified` seconds-to-minutes apart on an order that should have lived for days;
- present on a dev/UAT DB but absent — or in a different state — in the source-of-truth environment.

**The methodological half, which generalises past this table.** Two censuses in that ticket (a flag census
and a stranded-shape census) **agreed with each other**, were **both right about the data**, and both
invited the wrong conclusion — because they shared a blind spot, not because either was broken. That is
sharper than the usual "two instruments disagree and the disagreement is the finding":
**agreement between instruments that share an assumption is not corroboration.**

So: when a row's significance depends on it representing something in *another* system, verify the
cross-system identity field before inferring impact — and before writing the impact into a ticket title.

Related: [[a-zero-scan-needs-a-positive-control]] (the instrument was fine; the interpretation was
unvalidated), [[advertised-capability-is-not-exploitable-capability]].
