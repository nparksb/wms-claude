---
name: pool-exhaustion-counts-slots-not-milliseconds
description: A short extra connection on a path that already holds one for 20s is worse, not marginal — long holds are when the pool is fullest
metadata:
  type: feedback
---

I twice argued that adding a `REQUIRES_NEW` (one INSERT, milliseconds) to a path that **already**
pins a DB connection across a 5s-connect + 15s-read OMS POST was "marginal against that". A review
lane showed the reasoning is **backwards**.

Connection-pool exhaustion is a count of **simultaneously-held slots**, not a sum of elapsed
milliseconds. Precisely *because* those paths hold a connection for up to 20 s, they are the paths on
which every slot is most likely occupied at once — and that is exactly the instant the second
acquisition blocks for the full `connectionTimeout` and throws `SQLTransientConnectionException`.
N concurrent threads need N connections before; up to **2N** inside the suspend→inner-commit window.
The change is cheap in time and expensive in slots, and slots are what run out.

**Why:** "it's already slow there" feels like it licenses more cost, but duration and occupancy are
different axes. A long hold is evidence of *scarcity*, not of headroom.

**How to apply:** when adding a nested/suspended transaction, count how many callers hold an outer
connection **at the same moment**, not how long the addition takes. On SBDEV-3266 the honest count
was 3 of 9 (six had no transaction at all — four were `else`-of-`isSynchronizationActive()` branches,
which by construction run only when none is active), and those 3 were in a scheduled job off the
request path. That bound was both true and stronger than the argument I had been making.

Related: [[wms1-aftercommit-message-rows-silently-lost]],
[[fixing-a-false-claim-tends-to-produce-a-new-one]].
