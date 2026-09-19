---
name: verify-a-contract-against-the-wire-not-the-comment
description: "A comment or design doc asserting what a CALLER sends is a claim about the system, not documentation of it — verify against producer traffic before deciding anything on it"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 75060194-ee15-400f-bfc3-b3e78707041b
  modified: 2026-09-15T18:46:43.485Z
---

**When a cross-system contract matters, derive it from what the producer actually sends. A code
comment, a docblock, or a design section describing the caller is a CLAIM, not documentation.**

Measured twice in one session (SBDEV-1512, 2026-09-15), same root, different layers:

- **E7 (cost: a reversed user decision).** `oms-laravel-api`'s `LegacyInventoryAdjustService` carries
  a comment stating *"shifting one unit from good to damaged is reported as normal -1 / damaged +1"*.
  I took it as the contract and concluded three WMS call sites were wrong. They were not — the
  comment was written by the very commit that broke the behaviour (`dd17b84f`), and described a
  convention that had never existed. One query against `message` on live prod: **173** rows of the
  real shape, **0** of the asserted one, over four years. Twenty seconds, and it inverted the whole
  finding — after Nam had already decided on it.
- **Integration test I5 (cost: a test that would have pinned the defect).** Its expected value was
  transcribed from the plan's own design section rather than derived from the consumer's behaviour.
  It happened to be *right*, which is the version that leaves no trace: a plausible contrary argument
  could have flipped it to the wrong value and it would have shipped as the pin proving correctness.

**Neither was careless, and that is the point.** The design *was* the best available description of
intent; the comment *was* written by the owners of that code. It does not feel like guessing at the
time.

**How to apply:**
- Before deciding anything on a cross-system contract, run one query against the producer's actual
  traffic — WMS `message.message` bodies persist payloads permanently and are the cheapest source.
- **Date the comment against the behaviour.** `git log -S` the comment text; if it landed with the
  change under suspicion, it is evidence of intent, not of the system.
- For any expected value in a test, **name a source independent of the change being made**. Provenance,
  not plausibility — a value that is right by transcription is right by luck.
- Corollary already learned the hard way here: acting on a reviewer's *finding* does not license
  adopting its *fix* unchecked. A review lane's suggested remedy for the same ticket (join
  `adviceposition -> goodsreceiptposition -> stockunit`) was itself wrong, because a partial move
  creates a **new** stock unit the goods-receipt position never references
  (`StockunitBusinessService:328`).

Related: [[a-zero-scan-needs-a-positive-control]],
[[review-lanes-under-audit-prerequisite-tables]], [[green-tests-that-prove-nothing]],
[[sbdev-1512-damaged-returns-decisions]].
