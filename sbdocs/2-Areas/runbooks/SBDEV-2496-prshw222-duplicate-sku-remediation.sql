-- =============================================================================
-- SBDEV-2496 — WineCo / Pike Road — PRSHW222 "No fixed assigned location" hold
-- ***** SUPERSEDED / DO NOT RUN — INCIDENT ALREADY RESOLVED IN PRODUCTION *****
-- =============================================================================
--
-- STATUS (verified against wms1-wineco production, 2026-06-26, AFTER initial draft):
--   The duplicate was already consolidated by another actor (support/DBA) in the
--   OPPOSITE direction from the original draft of this script. Current good state:
--     * itemdata 33355356 ('PRSHW222 ', trailing space)  -> DELETED (no longer exists)
--     * itemdata 33714616 ('PRSHW222', clean)            -> now holds 60 @ 03-B05
--                                                           (5 stockunits) + the active
--                                                           fix_location_assignment
--     * order 33715135 line 33715138                     -> state 200 (ASSIGNED)
--     * order 33715135                                   -> state 200; parcel PR261039 RELEASED
--   Exactly ONE PRSHW222 row remains for client 512501: the clean 33714616.
--
-- ***** DANGER if the original consolidation steps below are run NOW *****
--   The original draft kept 33355356 as the "survivor" and repointed positions onto it,
--   then deleted 33714616. Since 33355356 is now DELETED and 33714616 is the live stocked
--   row, running those steps would repoint live positions to a non-existent itemdata id
--   and/or attempt to delete the row that holds all the stock — corrupting a released order.
--   The original executable steps have been REMOVED for safety. They remain in git/version
--   history of this file if ever needed for audit.
--
-- ACTION: none. Do not run any UPDATE/DELETE for this incident. If you must confirm the
--         resolved state, run the READ-ONLY assertion below.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- READ-ONLY verification of the resolved state (safe to run anytime).
-- Expect:
--   A) exactly ONE row: 33714616 / 'PRSHW222' (len 8) / stock_rows 5 / qty 60 / fla 1
--   B) line 33715138 -> itemdata 33714616, state 200; order 33715135 state 200
-- ---------------------------------------------------------------------------

-- A) single, clean, stocked master row for Pike Road PRSHW222
SELECT i.id,
       '['||i.item_nr||']'                                                       AS item_nr,
       length(i.item_nr)                                                          AS len,
       (SELECT count(*)            FROM stockunit s             WHERE s.itemdata_id=i.id) AS stock_rows,
       (SELECT coalesce(sum(amount),0) FROM stockunit s         WHERE s.itemdata_id=i.id) AS qty,
       (SELECT count(*)            FROM fix_location_assignment f WHERE f.itemdata_id=i.id) AS fla
FROM itemdata i
WHERE i.client_id = 512501 AND btrim(i.item_nr) = 'PRSHW222'
ORDER BY i.id;

-- B) the previously-held line is now ASSIGNED and bound to the surviving clean row
SELECT cop.id AS pos_id, cop.state AS pos_state, cop.itemdata_id,
       co.id AS order_id, co.state AS order_state, co.clientordernumber
FROM customerorder_position cop
JOIN customerorder co ON cop.order_id = co.id
WHERE cop.id = 33715138;

-- =============================================================================
-- PERMANENT FIX (prevents recurrence): see the code plan
--   sbdocs/1-Projects/wms1/plan/SBDEV-2496-prshw222-trailing-space-sku-duplication.md
-- The plan's one-time data migration trims the two REMAINING latent whitespace SKUs
-- (23WINERYBLOCKPN / client 419802, NVAYBMS / client 146700 — both zero stock, no
-- collisions), independent of this (now-resolved) incident.
-- =============================================================================
