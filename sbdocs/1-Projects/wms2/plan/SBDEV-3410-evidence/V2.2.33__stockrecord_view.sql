-- SBDEV-3410 — DRAFT of src/main/resources/db/migration/V2.2.33__stockrecord_view.sql
--
-- Copy this file into v2/wms2-api/src/main/resources/db/migration/ in P1. Re-run the version-collision
-- sweep across ALL remote branches immediately before merge and rename if 2.2.33 is taken.
--
-- ⚠ PROOF-READ THE NUMBERS IN THIS HEADER BEFORE THE FIRST APPLY. Flyway's CRC32 covers comments, so once
-- this script runs on any tenant the text cannot be corrected without a new migration file. The two
-- figures below are DIFFERENT QUANTITIES: 71 item_nr STRINGS are shared between shippers; 87 is the
-- EXCESS ROW count (8,808 itemdata rows carrying 8,721 distinct item_nr values). Measured on
-- dev_wh01_om1, 2026-09-18.
--
-- Rationale that is about the plan rather than about the migration stays in the plan's §3.1.
--
-- ===== FIRST STATEMENT: the view =====
-- Project the Stock Unit Record report over its shipper and product, so the report can be filtered by
-- shipper and can show the product name.
--
-- WHY A VIEW. SBDEV-3417 (b20eb9f1, on develop) established that Spring Data REST cannot render a
-- collection of interface projections, and Page<T> is not exempt. The Stock Unit Record table is served
-- by SDR and stays there, so the two columns the report needs that stockrecord does not carry -- the
-- product name and the shipper name/number -- have to arrive as mapped columns of a real relation. That
-- is what stock_view already does for the Inventory report; this is the same construction applied to the
-- audit table.
--
-- WHY THE JOIN KEY IS THE PAIR (client_id, item_nr) AND NEVER item_nr ALONE. stockrecord.itemdata holds
-- a SKU *string*, with no foreign key to itemdata. itemdata enforces UNIQUE (client_id, item_nr)
-- (constraint uk3l3dgof3l6mc1dl7s3lmida65), and nothing enforces uniqueness of item_nr on its own:
-- measured on dev_wh01_om1 2026-09-18, 8,808 itemdata rows carry only 8,721 distinct item_nr values --
-- 71 item_nr STRINGS are shared between shippers, accounting for 87 excess ROWS (the 8,808-8,721
-- difference is the row surplus, not a string count). Joining on item_nr alone MULTIPLIES rows -- for
-- shipper ARW (client_id 60500) it turns 873,021 stockrecord rows into 887,856, inventing 14,835
-- phantom audit entries. The pair join multiplies exactly 0 (873,021 -> 873,021), and over the whole
-- table 9,726,795 -> 9,726,795.
--
-- ROW-COUNT INVARIANCE, AND WHY THE THIRD STATEMENT EXISTS. Neither join can multiply: client.id is a
-- primary key, and (client_id, item_nr) is unique on itemdata. Both are LEFT, so neither can drop a row
-- either. The view therefore has exactly the cardinality of stockrecord, measured above.
-- That guarantee is a property of THIS TENANT'S SCHEMA, not of this view's text. The unique constraint
-- is declared only in V2.2.00__base_v2_schema.sql, the base dump legacy tenants were BASELINED PAST
-- rather than ran. So this script asserts it (third statement below) instead of trusting it: without the
-- constraint the view multiplies, and the symptom is NOT visible duplicate rows -- Hibernate dedupes by
-- @Id inside the persistence context, so the page content silently repeats one row while
-- page.totalElements (an undeduplicated count) reports the inflated figure. Defending the view itself
-- with DISTINCT ON or a LATERAL ... LIMIT 1 is not an option: it is precisely what would destroy the
-- join elimination below, because the planner's proof of non-multiplication IS the constraint.
--
-- WHY BOTH JOINS ARE LEFT. stockrecord is an append-only audit log; itemdata and client rows are not. An
-- INNER JOIN would silently DELETE history whenever a SKU string stops resolving -- the failure mode
-- being that rows vanish from an audit report, which no error surfaces. On dev_wh01_om1 today 0 of
-- 9,726,795 rows fail to resolve, so an INNER JOIN would look correct in every test; that is precisely
-- why it must not be used. (client_id is NOT NULL with an FK to client, so that join cannot drop a row
-- today -- LEFT is belt-and-braces there and costs nothing; see the next paragraph.)
--
-- LEFT JOIN + UNIQUE IS ALSO WHAT KEEPS THE DEFAULT VIEW FAST. Because client.id is a primary key and
-- itemdata carries UNIQUE (client_id, item_nr), PostgreSQL can PROVE neither join multiplies, and
-- eliminates both whenever the query references no column from them. Measured on dev_wh01_om1: the
-- unfiltered "All Shippers" count over this view plans as a bare Parallel Seq Scan on stockrecord --
-- byte-for-byte the plan the report has today -- at 7,356/7,647 ms against the 7,288/7,261 ms the same
-- count costs directly on the table. Replacing either LEFT with INNER, or dropping the unique
-- constraint, defeats join elimination and the default page pays the full hash join.
--
-- DO NOT WIDEN THE KEYWORD SEARCH TO item_name OR cl_name. That references a joined column in the WHERE
-- clause, which defeats the elimination above: measured, the unfiltered count goes from ~7.3 s to
-- ~17.9 s (2.5x) because both hash joins must run over all 9.7 M rows before the count. If product-name
-- search is ever wanted it needs its own design, not a longer CONCAT.
--
-- COLUMN SET. Every stockrecord column is projected unchanged so the view is a strict superset of the
-- table, plus item_id/item_name from itemdata and cl_nr/cl_name from client. version and entity_lock are
-- projected for shape parity only; the mapped entity must NOT declare @Version on them (a view is
-- read-only).
--
-- OWNERSHIP AND REPLAY. stockrecord_view does not exist on any tenant, so this is a plain CREATE and
-- needs only CREATE on schema public -- not the object ownership that froze wh01_hydra_v2 at V2.2.06 on
-- 2026-08-05 (see db/migration/README.md). CREATE OR REPLACE makes re-runs a no-op.
-- A LATER migration that needs to rename, reorder or retype any column here CANNOT use
-- CREATE OR REPLACE VIEW -- PostgreSQL only allows appending columns -- and its DROP VIEW ... CASCADE
-- will need ownership. Adding a column at the end is safe; anything else is not.
--
-- NO STARTUP SAFETY NET, FOR A MISSING VIEW *OR* A DRIFTED ONE. Production runs
-- spring.jpa.hibernate.ddl-auto=none (src/main/resources/application.properties, with
-- "#spring.jpa.hibernate.ddl-auto=validate" commented directly above it), so a tenant that misses this
-- migration BOOTS GREEN and then throws 42P01 "relation stockrecord_view does not exist" on every Stock
-- Unit Record page load, behind passing health probes. Tenant Flyway failures never abort the boot.
-- A tenant whose stockrecord_view is REDEFINED with a different shape has even less: nothing detects it
-- at runtime at all, and a report column silently becomes wrong or 500s. The only lane that validates is
-- the Testcontainers postgres-integration profile, whose own properties file records that its
-- ddl-auto=validate "DIVERGES from production, which is none" -- and even there the validator checks
-- only that a MAPPED column exists with a compatible type: it ignores extra columns, ignores
-- nullability, and reports the FIRST mismatch and stops. Verify per tenant after deploy; do not infer it
-- from a healthy application.

CREATE OR REPLACE VIEW public.stockrecord_view AS
 SELECT sr.id,
        sr.additionalcontent,
        sr.created,
        sr.entity_lock,
        sr.modified,
        sr.version,
        sr.activitycode,
        sr.amount,
        sr.amountstock,
        sr.fromstockunitidentity,
        sr.fromstoragelocation,
        sr.fromunitload,
        sr.itemdata,
        sr.operator,
        sr.ordernumber,
        sr.scale,
        sr.tostockunitidentity,
        sr.tostoragelocation,
        sr.tounitload,
        sr.type,
        sr.unitloadtype,
        sr.client_id,
        sr.reservedamountchange,
        sr.reservedamountstock,
        i.id   AS item_id,
        i.name AS item_name,
        c.cl_nr,
        c.name AS cl_name
   FROM public.stockrecord sr
        LEFT JOIN public.itemdata i ON i.client_id = sr.client_id AND i.item_nr = sr.itemdata
        LEFT JOIN public.client   c ON c.id = sr.client_id;

-- ===== SECOND STATEMENT: the companion index (plan §3.2) =====
-- The shipper filter is useless without this. See the plan's 3.2 for the measured 300-900x regression
-- without it and the 0.455 ms worst case with it. Build cost measured in a rolled-back transaction on
-- the 9,726,795-row table: 6.3 s, 276 MB.
-- NOT CONCURRENTLY: CREATE INDEX CONCURRENTLY cannot run inside a transaction and Flyway wraps every
-- script in one; this repo has no precedent for Flyway's transactional-control escape.
CREATE INDEX index_stockrecord_client_created ON stockrecord (client_id, created DESC);

-- ===== THIRD STATEMENT: assert the constraint the view depends on (plan §3.1) =====
-- Fail loudly here rather than silently multiplying rows on a tenant that lost the constraint.
-- Matched on the COLUMN SET, not on the generated name uk3l3dgof3l6mc1dl7s3lmida65: a tenant rebuilt by
-- a different Hibernate run carries a different generated name, and a name-match would fail a tenant
-- that is in fact correct.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.itemdata'::regclass AND contype = 'u'
      AND conkey = (SELECT array_agg(attnum ORDER BY attnum) FROM pg_attribute
                    WHERE attrelid = 'public.itemdata'::regclass AND attname IN ('client_id','item_nr'))
  ) THEN
    RAISE EXCEPTION 'stockrecord_view requires UNIQUE(client_id, item_nr) on itemdata; without it the view multiplies rows and join elimination is lost';
  END IF;
END $$;
