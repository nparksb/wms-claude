---
name: hub-locking-tx
description: Lock and transaction behaviour traps (REQUIRES_NEW deadlock, inert timeouts, FOR UPDATE). Hub: one line per member memory
metadata:
  type: reference
---

Hub for **Locking / transaction traps**. Moved out of MEMORY.md on 2026-10-15 to keep the index under its size limit; each line links the member memory.

- [[wms2-requires-new-in-lock-holding-tx-deadlock]]: REQUIRES_NEW in lock tx = deadlock
- [[wms2-lock-timeouts-are-inert-on-postgres]]: lock timeouts inert, fixed 3250
- [[wms1-has-no-lock-timeout-or-leak-detection]]: v1 no lock timeout
- [[findbyidforupdate-throws-at-the-lock-read-not-at-flush]]: findByIdForUpdate throws at lock read
- [[for-update-on-a-missing-row-takes-no-lock]]: FOR UPDATE on missing row: no lock
- [[pool-exhaustion-counts-slots-not-milliseconds]]: pool exhaustion counts slots
