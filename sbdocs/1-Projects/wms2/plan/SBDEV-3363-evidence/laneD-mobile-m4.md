# SBDEV-3363 lane D — Mobile M-4, the pick-list refresh signal (main session, 2026-09-15)

## The defect, stated as an arithmetic mismatch

`PickingorderBusinessService.isDemandCancelled` has **three** triggers. The mobile pick list removes a
row on **one** of them. The server rejects a pick on all three. So for two of the three, the row the
operator is standing on **stays on screen after the rejection**, and the re-query that was added to
remove it returns the same row — an unbreakable retry loop on the handheld.

**AC-5 makes it three of four**, because `markedforcancellation` becomes a fourth trigger that the
mobile filter also cannot see. **Shipping AC-5 without M-4 therefore adds a new infinite-retry shape
rather than only failing to fix the old one.** This is the concrete reason AC-5 and M-4 must ship
together.

## Server side — the three triggers

`PickingorderBusinessService`, `private static boolean isDemandCancelled(...)`. Body, verbatim
structure:

1. `pickingPosition.getState() == WmsConstants.State.CANCELED` → true
2. `coPosition.getState() == WmsConstants.State.CANCELED` → true
3. `customerOrder.getState() == WmsConstants.State.CANCELED` → true

A fourth is deliberately absent, with the reason recorded inline:

> `⚠ markedforcancellation is deliberately NOT a trigger — see SBDEV-3332. … Add this back only
> together with a completion path that works in regular picking.`

⚠ **Its javadoc is wrong and this ticket should fix it.** The javadoc opens *"TWO levels, and they are
not redundant"* and then lists two bullets — *picking position only* and *customer order state only* —
**omitting the `coPosition` check that sits in the body between them**. The body has three. The prior
art records this javadoc having drifted twice before (SPLIT M-1: *"the javadoc contradicts the method
body eight lines down"*; SPLIT-FU M-4: *"the test-class javadoc still asserts three levels"*), so this
is a third revision of the same sentence being wrong. **State the rule, not the count** — the javadoc
should say the levels are the chain `pick line → CO position → CO`, and stop asserting an integer that
every edit invalidates.

## Client side — the one signal

`wms2-mobile-ui`, `store/picking.js`. The list filter is:

```js
const livePositions = results.filter(position => position.pickStatus !== CANCELLED_PICK_STATUS)
```

with `const CANCELLED_PICK_STATUS = 'Cancelled'`. And `pickStatus` is derived server-side in
`MobilePickingService` as:

```java
map.put("pickStatus", WmsConstants.State.getCodeText(pos.getState()));
```

where `pos` is the **`PickingorderPosition`**. So `pickStatus` reflects **the pick line's own state and
nothing else**. It cannot observe trigger 2 (CO position) or trigger 3 (CO), and could not observe a
markedforcancellation trigger either.

`nextPickingPosition` tests the same string, so both the landing rule and the filter share the single
blind signal — fixing one without the other leaves the row reachable by hand via
`nextPosition`/`previousPosition`.

## Why the SBDEV-3319 refresh did not close it

Commit `f83bdaa` (*"SBDEV-3319 cancelled rows leave the pick list, and a cancel reaches the picker"*)
added the re-query on the rejection path. Its own message states the mechanism it relied on:

> "processPick now re-queries on the rejection path too, which is what actually removes the row."

The re-query is correct; the **removal** is what is partial. The re-query re-runs
`getPickingOrderPositionsInfo`, whose filter is the `pickStatus` test above — so it removes the row
only for trigger 1. For triggers 2 and 3 the re-query faithfully returns the row again.

## Verdict on the shape of the fix

The signal is at the wrong altitude: the client is inferring "is this demand cancelled?" from a field
that only carries one third of the answer. Two candidate shapes, and the second is better:

- **(a) Widen the client's test** — have the mobile filter also read CO-position and CO state. Requires
  `MobilePickingService` to emit both, and re-derives `isDemandCancelled`'s logic in JavaScript, where
  it will drift from the Java the first time a trigger is added. This is exactly how the current
  mismatch arose.
- **(b) Emit the answer, not the inputs** — have `MobilePickingService` add a boolean field (e.g.
  `demandCancelled`) computed by the **same** `isDemandCancelled` the pick guard uses, and have the
  mobile filter key on that. One authority, one spelling, and a trigger added later is picked up by
  the client for free. This is the invariant-over-instance form, and it makes AC-5 a one-line server
  change with no mobile follow-up.

**Recommend (b).** Note it requires exposing `isDemandCancelled` beyond `private static` — which
**Option 3 already requires for its own reasons**, so the two ACs share that refactor rather than each
paying for it.

## Caveat carried forward — an unverified commit is already on develop

`ef1dc76` (*"SBDEV-3319 fix pass for the re-review findings, mobile half"*) touches
`store/picking.js` and its two spec files, and its own message says:

> "⚠ NOT VERIFIED: the full Jest suite and the independent review over this fix pass had not run when
> the lane stopped. The green tests it carries are not a verdict."

It is on `origin/develop` (`wms2-mobile-ui` is 15 commits ahead of the local checkout). **Any mobile
work under this ticket must re-run the mobile Jest suite against a fresh `origin/develop` baseline
first** — the existing green is explicitly disclaimed by its author, so treating it as the baseline
would compare against an unmeasured number.
