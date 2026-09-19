---
name: wms2-seqentities-dual-island-id-space
description: "wms2 entities share one seqentities sequence; on migrated DBs the id space is dual-island (low block fed by seqentities + a foreign-origin high block) — verify the next seqentities value lands in a free gap before cutover, don't panic at seqentities << max(id)"
metadata:
  node_type: memory
  type: project
  originSessionId: 09087e48-61e7-4a85-8e78-e71504455952
---

All wms2-api entities that extend `AbstractBaseEntity` (Stockunit, Unitload, Customerorder,
Stockrecord, UnitloadRecord, PickingorderPosition, Advice, etc.) draw their PK from a **single shared
native sequence `seqentities`** (`@SequenceGenerator(sequenceName="seqentities", allocationSize=1)` in
`src/main/java/net/aim_ai/wms/model/AbstractBaseEntity.java`). `los_sequencenumber` (table generator:
classname→sequencenumber) is a SEPARATE, parallel mechanism for business numbers (PICKING_ORDER_POSITION,
WEBSERVICE_MESSAGE, BILL_OF_LADING, …), NOT entity PKs.

**Non-obvious finding (WineCo uat `wh01_om1_v2` @10.0.0.6, 2026-06-28):** `seqentities.last_value` was
~31.1 M while `max(id)` on the big tables was ~988 M — looks like a catastrophic under-set generator that
would dup-key on first insert. **It is NOT broken.** The id space is **dual-island**: a low block
(~0–31 M) that `seqentities` actively feeds (advice/inventory_record max ~31.1 M, right under the cursor),
PLUS a foreign-origin high block (~585 M–988 M, from historical import / OMS-origin ids) with a clean
EMPTY gap between them (first occupied id above the cursor was 585,000,350). `pg_dump`/restore preserves
`setval`, and no UTC-migration script touches `seqentities`, so the v2 value is faithful to v1 — which ran
fine this way. ~554 M free ids before the cursor could ever reach the high block (decades of runway).

**Cutover check (do this, don't assume):** the only real failure is `seqentities` handing out an id that
already exists. Verify `nextval`-to-be (last_value+1) through the next chunk is unoccupied, e.g.
`SELECT count(*) FILTER (WHERE id >= <last_value+1>), min(id) FILTER (WHERE id >= <last_value+1>)` on the
high-volume seqentities tables (unitload, stockunit, stockrecord, customerorder). If the immediate range is
free → safe, regardless of how far `seqentities` sits below `max(id)`. Also confirm NEW v2 sequences
(`outbox_message_id_seq`, `customerorder_cancellation_log_id_seq`) that start at 1 sit over empty tables.
Related: [[wineco-wsl-v1-v2-migration-status]].
