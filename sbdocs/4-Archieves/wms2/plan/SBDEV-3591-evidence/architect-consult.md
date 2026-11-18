# SBDEV-3591 — architect consult (T2): Parcel Picking Report Status filter
Read from wms2-api `origin/develop` @ 5e05ab42 and wms2-web-ui `origin/develop` (2026-10-29). Read-only.

**VERDICT: OK with 4 changes** (1 required for correctness, 3 required for robustness/compile). No design-level blocker.

## (a) Null binding: native query needs `CAST(:state AS integer)` (REQUIRED); JPQL does not
- Native: a bare `:state IS NULL` with a null Integer reaches pgjdbc untyped, and PostgreSQL can reject it with
  "could not determine data type of parameter". The repo already has the fix for exactly this shape:
  `MessageRepository.java:107` `"where (CAST(:days AS INTEGER) IS NULL OR m.created <= current_date - CAST(:days AS INTEGER))"`,
  and `StockrecordRepository.java:~174` documents it: "a bare bind inside a comparison can draw *could not determine data type of parameter*".
  -> write `AND (CAST(:state AS integer) IS NULL OR p.state = CAST(:state AS integer))` (cast BOTH occurrences).
  Do not use the `CAST(COALESCE(:filter,'') as TEXT)` idiom: that's a String-sentinel pattern; for Integer use plain CAST + IS NULL arm.
- Keep the `IS NULL` arm. `StockrecordRepository.java:~150` warns that dropping it makes a null bind match **0 rows**.
  The non-indexable-OR concern (`StockunitRepository.java:~490`) does not bite here: the view is
  `SELECT row_number() OVER () ... FROM (SELECT DISTINCT ...) t1` (`V2.2.00__base_v2_schema.sql:1642-1683`). The window
  function blocks predicate pushdown, so the view is computed in full on every call regardless of predicate shape.
- JPQL (`findByKeyword`): `AND (:state IS NULL OR p.state = :state)` is fine as-is. Hibernate 6 infers the type from
  `p.state` (`OrderDetailMonitorView.java:25` `private Integer state;`), the same way the existing `:clientNumber IS NULL` arm works.
  The derived count query carries the predicate.

## (b) Callers: compile breaks are limited to test mocks
- Repo methods: one caller each. `ViewDtoService.java:1436` `orderDetailMonitorViewRepository.findByKeyword(keyword, clientNumber, p)` and
  `ReportService.java:284` `orderDetailMonitorViewRepository.findByClientOffsetAndLimit(keyword, filter, offset, limit)`. No src/test caller.
  Same-named methods on `FlowbinMonitorViewRepository`/`ParcelMonitorViewRepository` are separate interfaces and are not affected.
- Service signatures change, which breaks `ReportControllerUnitTest.java:320/328` (`exportParcelPickingReport(any(), eq(0), eq(100), eq("ready"), eq("PARCEL123"))`)
  and `:831/844/854/867` (`getParcelPickingReportViewByKeyword(eq("search"), eq("CLIENT01"), any(Pageable.class))`). Update those
  tests, and add one case each that pins `state` passed through and `state` absent -> null.

## (c) Filter by int code is correct, but limit the dropdown to the view's range
- The view's `state` column is `co.state` (`V2.2.00:1664` `co.state,`), stored as `state integer NOT NULL` (customerorder DDL in V2.2.00). Text is display-only:
  `ViewDtoService` `dto.put("state", WmsConstants.State.getCodeText(result.getState()))`. Filtering on text would mean reversing
  `getCodeText(int)` (`WmsConstants.java:149`), so the int code is the right contract.
- The view hard-filters `WHERE ((co.state >= 200) AND (co.state <= 600) ...)` (`V2.2.00:1683`; identical in onboarding
  `V1.2.04__utc_recreate_views.sql:~203`). Offer only codes in [200,600]: ASSIGNED 200, PROCESSABLE 300, RESERVED 400,
  STARTED 500, (505/510/520/525/527/530), PENDING 550, PICKED 600 (`WmsConstants.java:40-121`). Anything else, such as PACKED 650 or On Hold 55, always returns empty.
  The 5xx batch/transfer codes probably never occur on customerorder in this view. **Unverified**: DB MCPs failed to connect.
  Run `SELECT state, count(*) FROM order_detail_monitor_view GROUP BY 1` on dev before you fix the list.

## (d) Authz / SDR: unaffected
- No new endpoint. Both stay `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_PARCEL_PICKING)` (`ReportController.java:245, 484`), pinned
  by path in `Sbdev3017TrancheGateContextTest.java:216-229`. The repo is `exported = false` (`OrderDetailMonitorViewRepository.java:17`), and it is listed in
  `SdrUncalledSurfaceNotExportedContextTest.java:117`. A new `@Param` adds no HTTP surface. The `@RestResource` path annotations are inert.

## View definition: which one is authoritative
- Fresh v2 tenants: `src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:1642` (the only db/migration hit; it has `i.item_nr AS sku_id`).
- v1->v2 onboarded tenants: `db/v1-to-v2-onboarding/schema/V1.2.04__utc_recreate_views.sql:160` ("verbatim latest definition"), which also has `sku_id`
  and is guarded by `08-verify-utc.sh:20` `VIEWCOLS="order_detail_monitor_view:sku_id ..."` (SBDEV-1637). `db/backup/order_detail_monitor_view.sql` is stale. Ignore it.

## Required changes to the proposal
1. Native: `CAST(:state AS integer)` in both arms (above).
2. Export body: do not use `(Integer) reqMap.get("state")`. A JSON string `"300"` throws ClassCastException, which becomes a 500. Reuse
   `wholeNumberOrNull(reqMap, "state")` (`ReportController.java:104`). If the key is present and the value is non-null but the result is null, throw `ApiInvalidParameterException(..., "state")`.
3. UI GET: omit `&state=` for 'All Statuses', mirroring `store/reports/parcelPicking.js:59` `if (data.clientNumber != null & data.clientNumber !== 'All Shippers')`.
   If you send the sentinel text, the `Integer` @RequestParam fails conversion and returns a 400.
4. UI export: the export body comes from the SHARED popup `components/reports/popups/exportReport.vue:136` (`filter: this.filter && ...`), which
   every report uses. Inject `state` in the store's `export` action instead, as `keyword` already is
   (`parcelPicking.js:82-85` `keyword: context.state.list?.search || ''`), so the shared popup stays untouched.
   If you skip this, the Excel export silently ignores the Status filter.
