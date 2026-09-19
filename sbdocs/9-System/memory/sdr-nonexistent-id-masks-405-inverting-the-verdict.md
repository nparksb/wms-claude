---
name: sdr-nonexistent-id-masks-405-inverting-the-verdict
description: Probing an SDR verb with a non-existent id returns 404 whether the verb is withdrawn or published — it inverts the verdict; the id must exist
metadata: 
  node_type: memory
  type: feedback
  originSessionId: bbc132cd-dbfa-4a61-a3cf-d628f8d6ecd7
  modified: 2026-09-16T16:47:54.269Z
---

Spring Data REST resolves the **entity before the method**, so a request to a withdrawn verb on a
**missing** id answers `404`, exactly like a published verb on a missing id. A probe built on
"use a fake id so it can't break anything" therefore cannot tell the two apart, and reads every
`404` as "the verb is published."

Measured 2026-09-16, SBDEV-3321, `wms-api.dev.sbo.li` wineco/wsl, same run:

```
PATCH /v3/stockunit/999999999  -> 404   (id absent  — proves NOTHING)
PATCH /v3/stockunit/988306832  -> 405   (id present — the real answer)
```

The first version of `sbdocs/9-System/scripts/probe-SBDEV-3321-sdr-cancel-write-bypass-dev.sh`
printed **"VERDICT: bypass #4 is OPEN"** on the strength of those 404s, contradicting a correct
source reading (all four entities sit in `RestConfiguration.SDR_WRITE_WITHDRAWN`). With a real id,
`PATCH`/`PUT`/`DELETE` all returned `405` and the row was byte-identical afterwards.

**The id must exist, and prove it with a `GET` in the same run before reading any verdict.**

**Two controls, and both have a shape requirement:**

1. *A control must DISCRIMINATE, not merely respond.* The original control asserted only "not 405"
   for a write-published type — but it too returned `404`, so it passed while the instrument was
   blind. A control is only a control if it answers **differently** from a negative subject.
2. *Use the ITEM path, not the collection.* `withCollectionExposure` and `withItemExposure` are
   configured separately. `/v3/boxtype` advertises `HEAD,GET,OPTIONS` — identical to a withdrawn
   type — while `/v3/boxtype/1` advertises `HEAD,DELETE,GET,OPTIONS,PUT`. Controlling on the
   collection path makes a write-live type look withdrawn.

The safe way to run the decisive write is a **semantic no-op**: read the row first and send back the
value it already holds, so a published verb succeeds and changes nothing. Then re-read the row.

Related: [[advertised-capability-is-not-exploitable-capability]] (the inverse error — `OPTIONS Allow`
advertising a verb that is actually gated), [[a-zero-scan-needs-a-positive-control]],
[[sdr-exported-false-grep-matches-method-level]], [[sdr-withdrawal-405-vs-rule-403]].
