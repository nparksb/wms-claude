# SBDEV-3410 — Analysis Bundle

**Ticket**: WMSv2 — Reports → Stock Unit Record: no Shipper/Brand filter and no product name (split from SBDEV-2976 Gap 1)
**Tier**: T3. **Design is DECIDED** (Nam): a `stockrecord_view` DB VIEW via Flyway `V2.2.33`, mapped as `@Entity StockrecordView`, mirroring `stock_view`/`StockView`; the endpoint stays on Spring Data REST returning `Page<StockrecordView>`.
**This document is analysis only.** No repo code was written; no branches or worktrees created.

**Provenance of every code citation below**: `git show origin/develop:<path>` at
`wms2-api` `origin/develop` = `29ce240db0c9edb747346e2b6fe42287afcd0b63` (2026-09-18 10:26 -0400, "Merge PR #383 SBDEV-3428") and
`wms2-web-ui` `origin/develop` = `a27703eb32f9f8f4fede697fe82ce13ba6e62a6c` (2026-09-17 15:37 -0400).
Line numbers are given for navigation only; the quoted snippet is the citation.

**DB used for every measurement**: `dev_wh01_om1` @ `localhost:25060` (the `wms2-wineco-dev` target).
⚠ The `mcp__wms2-wineco-dev__*` tools were **not surfaced in this session's tool registry** (only `wms1-*`, `*-prd` and `landlord-prd` were). Per the standing note *"DB MCP tools absent ≠ DB unreachable"*, the connection string was read from `~/.claude.json` `mcpServers["wms2-wineco-dev"].args` and driven with `psql` using `PGPASSWORD` (never a concatenated libpq URL — the password contains `@`). Same database, different transport.

---

## §0. Affected sites — by enumeration

Derivation method for each row is stated. **Blind spots of the method are stated at the end of the table.**

### 0.1 `v2/wms2-api`

| # | file | construct (quoted) | in scope? | phase |
|---|---|---|---|---|
| 1 | `src/main/resources/db/migration/V2.2.33__*.sql` | *(new file)* `CREATE OR REPLACE VIEW public.stockrecord_view` | **YES** | P1 DB |
| 2 | `src/main/java/net/aim_ai/wms/model/StockrecordView.java` | *(new)* `@Entity @Table(name = "stockrecord_view")` | **YES** | P2 model |
| 3 | `src/main/java/net/aim_ai/wms/repo/jpa/StockrecordViewRepository.java` | *(new)* `@RepositoryRestResource(collectionResourceRel = "stockrecordView", path = "stockrecordView")` | **YES** | P2 repo |
| 4 | `.../repo/jpa/StockrecordRepository.java:43-45` | `@RestResource(path = "findByKeyword", rel = "findByKeyword")` / `Page<Stockrecord> findByKeyword(@Param("keyword") String keyword, Pageable p);` | **YES** — the endpoint the UI table reads today (`/stockrecord/search/findByKeyword`). Decide: keep (legacy) or `exported = false` | P2 |
| 5 | `.../repo/jpa/StockrecordRepository.java:47-52` | `@RestResource(path = "findByOffsetAndLimit", ...)` / `List<Stockrecord> findByOffsetAndLimit(@Param("keyword") String keyword, @Param("offset") int offset, @Param("limit") int limit);` | **YES** — the **Export** query (AC-2) | P3 export |
| 6 | `.../service/ReportService.java:352` | `List<Stockrecord> views = stockrecordRepository.findByOffsetAndLimit(keyword, offset, limit);` | **YES** | P3 export |
| 7 | `.../service/ReportService.java:347` | `public void exportStockUnitRecord(HttpServletResponse response, int offset, int limit, String keyword) throws BusinessException` | **YES** — signature gains the shipper filter | P3 export |
| 8 | `.../controller/ReportController.java:250-261` | `@PostMapping(path= "/exportStockUnitRecord")` … `String keyword = (String) reqMap.get("keyword");` … `reportService.exportStockUnitRecord(response , offset, limit, keyword);` | **YES** — must read `filter` from `reqMap` | P3 export |
| 9 | `.../controller/DashboardController.java` | `DashboardController extends ReportController` — see §5.3. Inherits `/v3/dashboard/exportStockUnitRecord` with **no code of its own** | **YES (no edit, but the gate pins must stay green)** | P3 |
| 10 | `.../controller/StockRecordController.java:36-41` | `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_STOCK_UNIT_RECORD)` / `@GetMapping(path= "/stockRecordDetailsById/{id}")` → `losStockUnitRecordService.getStockRecordDetails(id)` | **YES** — AC-3 popup half | P4 |
| 11 | `.../service/StockrecordService.java:585-617` | `public Map<String, Object> getStockRecordDetails(Long id)` … `details.put("clientNumber", client.getClNr()); details.put("clientName", client.getName());` — **no item name** | **YES** — add `itemName` | P4 |
| 12 | `.../controller/ClientController.java:218-228` | `@RequiresFunction({WEB_UI_VIEW_CLIENT, …11 entries…})` on `@GetMapping(path = "/allClients")` — **`WEB_UI_VIEW_STOCK_UNIT_RECORD` is NOT in the list** | **YES** — see §5.4, latent 403 on the new dropdown | P5 authz |
| 13 | `.../RestConfiguration.java:884-886` | `config.exposeIdsFor(… ParcelMonitorView.class, … Stockrecord.class, Stockunit.class, StockView.class, …)` | **YES** — `StockrecordView.class` **must** be added or `id` is absent from the HAL payload and `showDetails(item)` breaks (§5.5) | P2 |
| 14 | `.../RestConfiguration.java:533` (`SDR_WRITE_WITHDRAWN`) | `net.aim_ai.wms.model.StockView.class,` / `net.aim_ai.wms.model.Stockrecord.class,` | **YES** — add `StockrecordView.class` for parity | P2 |
| 15 | `.../security/SdrFunctionRules.java` | `rules.put(net.aim_ai.wms.model.User.class, USER_ADMIN_VIEW);` … 7 rules total; **neither `Stockrecord` nor `StockView` has one** | **Decide** — §7.4. Status quo is "unruled"; adding `StockrecordView` without a rule preserves it | P5 authz |
| 16 | `.../service/StockrecordService.java:209/260/302/356/412/464/523` | `Stockrecord rec = new Stockrecord();` — **7 write sites** | **NO** — writes stay on the table entity. The view is read-only | — |
| 17 | `.../service/StockunitBusinessService.java:137` | `Stockrecord stockrecord = new Stockrecord();` | **NO** (write path) | — |
| 18 | `.../service/FixLocationAssignmentService.java:175` | `stockrecordService.recordRelocation(su, oldLocation, destination, …)` | **NO** (write path) | — |
| 19 | `.../repo/jpa/StockrecordRepository.java:78-94` | `findAdjustmentAlerts` — `"FROM stockrecord sr JOIN client c ON sr.client_id = c.id "` | **NO** — already joins `client` itself; unaffected | — |
| 20 | `.../repo/jpa/StockrecordRepository.java:21-41` | `transactionDetailByClientNumberAndSkuBetweenDates` / `transactionSummaryByClientNumberBetweenDates` (both `nativeQuery`, `@RestResource(exported = false)`) | **NO** — call PL/pgSQL functions, not the table | — |

**Existing callers of the two finders (exhaustive within `src/`, derived by `git grep -n 'findByKeyword\|findByOffsetAndLimit' origin/develop -- src/`, restricted to `stockrecordRepository.`):**
- `findByOffsetAndLimit` → exactly one caller, `ReportService.java:352`. Plus SDR exposes it at `/api/stockrecord/search/findByOffsetAndLimit` (it is **not** `exported = false`).
- `findByKeyword` → **zero Java callers**. Its only consumer is the HTTP route `/stockrecord/search/findByKeyword`, dispatched from `store/reports/stockUnit.js:51`.

### 0.2 `v2/wms2-web-ui`

| # | file | construct (quoted) | in scope? | phase |
|---|---|---|---|---|
| 21 | `components/reports/stockUnitRecord.vue:31-41` | `<v-data-table id="reportsStockUnitRecordTable" :headers="headers" …>` | **YES** — add the SKU Name column (AC-3) | P6 UI |
| 22 | `components/reports/stockUnitRecord.vue:1-30` | header block — **has no `<v-select>` and no `<v-container>`/`<v-row>` wrapper at all** (unlike `inventoryReport.vue:3-43`) | **YES** — add the dropdown (AC-1) | P6 UI |
| 23 | `components/reports/stockUnitRecord.vue:79-83` | `<export-report :show="showExport" :reportType="reportType" @close="closeExport" />` — **no `:filter`** | **YES** — add `:filter="shipper"` (AC-2). See §5.1: the prop already exists and already flows | P6 UI |
| 24 | `components/reports/stockUnitRecord.vue:88-106` | `:exclude-fields="['id', 'version']"` and `:field-names="{ … 'clientName': 'Shipper Name', 'clientNumber': 'Shipper Code', }"` | **YES** — add an `itemName` label (AC-3 popup half) | P6 UI |
| 25 | `components/reports/stockUnitRecord.vue:292-313` | `async updateTable() { const { sortBy, sortDesc, page, itemsPerPage } = this.options … sortUrl = 'created,desc' … dispatch('reports/stockUnit/searchReport', { page, itemsPerPage, keyword: this.keyword, sortUrl })` | **YES** — must also pass the shipper | P6 UI |
| 26 | `store/reports/stockUnit.js:49-53` | `const urlPart = '?page=' + (data.page - 1) + '&size=' + data.itemsPerPage + '&state=' + data.state + '&keyword=' + data.keyword + (data.sortUrl ? '&sort=' + data.sortUrl : '')` … `$get('/stockrecord/search/findByKeyword' + urlPart)` … `results._embedded.stockrecord` | **YES** — new path, new `_embedded` key, new filter param | P6 UI |
| 27 | `store/reports/stockUnit.js:1-14` | `export const state = () => ({ pagination: {…}, reportItems: [], list: { search: '', sortBy: [], sortDesc: [] } })` — **no `shipperFilter`, no `shippers`** | **YES** — mirror `store/reports/inventory.js:10-11` | P6 UI |
| 28 | `store/reports/stockUnit.js:59-94` | `async export(context, params) { … const exportData = { ...params.data, keyword: context.state.list?.search || '' }; … $post('/report/exportStockUnitRecord', exportData, …) }` | **Probably NO EDIT** — `params.data` already carries `filter`; see §5.1 | P6 UI |
| 29 | `components/reports/popups/exportReport.vue:92` | `props: ['show', 'reportType', 'filter', 'includeShipped'],` | **NO EDIT** — generic already | — |
| 30 | `components/reports/popups/exportReport.vue:136` | `filter: this.filter && this.filter != 'All Shippers' ? this.filter : null,` | **NO EDIT** — generic already | — |
| 31 | `components/reports/inventoryReport.vue:26-39` | `<label class="mr-4 mt-1">Filter by Shipper</label>` … `<v-select :items="shippers" item-text="label" item-value="clNr" v-model="shipper" id="shipper" placeholder="Choose Shipper / Brand" …>` | **REFERENCE** — the component to copy. ⚠ but see §5.2 on `item-value` | — |
| 32 | `components/reports/inventoryReport.vue:236-243` | `shipper: { get() { return this.$store.state.reports.inventory.shipperFilter }, set(newVal) { this.$store.commit('reports/inventory/setShipperFilter', newVal) } }` — a **computed**, not `data()` | **REFERENCE** — and load-bearing, see §5.6 | — |
| 33 | `components/reports/inventoryReport.vue:300-304` | `'$store.state.admin.client.clients'() { this.shippers = [{ name: null, label: 'All Shippers' }]; const tmpList = … map(client => Object.assign(client, { label: client.name + " (" + client.clNr + ")" })) … }` | **REFERENCE** — where "All Shippers" comes from | — |
| 34 | `components/reports/inventoryReport.vue:280` | `this.$store.dispatch('admin/client/getClients')` — fired inside the **`options` deep watcher**, i.e. on every table option change | **REFERENCE** — copy, but see §5.4 for the authz consequence | — |
| 35 | `store/admin/client.js:24-28` | `const urlPart = '/allClients'; … $get('/client' + urlPart) … context.commit('setClients', results.content)` | **NO EDIT** — shared dropdown source | — |
| 36 | `store/reports/inventory.js:64-66` | `if (data.clientNumber != null & data.clientNumber !== 'All Shippers') { urlPart += '&clientNumber=' + data.clientNumber }` | **REFERENCE — DO NOT COPY VERBATIM**, see §5.7 | — |
| 37 | `mixins/searchUrlSync.js:2` | `const possibleProps = ['search', 'keyword', 'filter', 'searchText', 'query', 'searchQuery'];` | **CONSTRAINT** — see §5.6 | P6 UI |
| 38 | `components/reports/{flowbin,lock,outboundParcel,parcelPicking,receiving,skuLocation}Report.vue` | each dispatches `admin/client/getClients` (derived by `git grep -n 'getClients' origin/develop -- '*.vue'`, 7 report files hit) | **NO** — sibling reports, untouched | — |

**Blind spots of the §0 derivation method.** The table was built by `git grep -n` over `origin/develop` for the literals `stockrecord`, `Stockrecord`, `stock_view`, `StockView`, `exportStockUnitRecord`, `findByKeyword`, `findByOffsetAndLimit`, `getClients`, plus `git ls-tree -r --name-only` over `components/reports/` and `store/reports/`. It therefore **cannot see**: (a) reflective or string-built references (e.g. a repository path assembled at runtime); (b) references in files `.gitignore`d out of the working tree — note `wms2-web-ui` ignores `reports/`, which hides 34 files from a plain `grep`, so **`git grep` was used throughout, not `grep`**; (c) `grep` here is `ugrep`, which silently skips binary files without `-a` — no binary file is relevant to this sweep, but that is an assumption, not a measurement; (d) anything on an unmerged branch.

---

## §1. The `stock_view` / `StockView` precedent, fully characterised

### 1.1 How `stock_view` is defined in `V2.2.00__base_v2_schema.sql`

`pg_dump` emits a view in **two pieces**, and both are in the base dump. This matters: a reader who greps `CREATE VIEW public.stock_view` finds only the placeholder.

**Piece 1 — the column-shape placeholder** (`V2.2.00__base_v2_schema.sql:2143-2158`):

```sql
--
-- Name: stock_view; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.stock_view AS
SELECT
    NULL::bigint AS row_id,
    NULL::character varying(255) AS item_nr,
    NULL::bigint AS item_id,
    NULL::character varying(255) AS item_name,
    NULL::bigint AS client_id,
    NULL::character varying(255) AS cl_nr,
    NULL::character varying(255) AS cl_name,
    NULL::numeric AS total_stock,
    NULL::numeric AS damaged,
    NULL::numeric AS on_hold,
    NULL::numeric AS not_found,
    NULL::numeric AS transfer;
```

**Piece 2 — the real body, emitted much later as a `RULE`** (`V2.2.00__base_v2_schema.sql:4682-4724`):

```sql
--
-- Name: stock_view _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.stock_view AS
 SELECT row_number() OVER () AS row_id,
    i.item_nr,
    i.id AS item_id,
    i.name AS item_name,
    c.id AS client_id,
    c.cl_nr,
    c.name AS cl_name,
    sum(CASE WHEN ((su.entity_lock <> ALL (ARRAY[405, 2])) AND (ul.entity_lock <> ALL (ARRAY[405, 2]))) THEN su.amount ELSE (0)::numeric END) AS total_stock,
    …
   FROM (((public.itemdata i
     LEFT JOIN public.stockunit su ON ((su.itemdata_id = i.id)))
     LEFT JOIN public.client c ON ((i.client_id = c.id)))
     LEFT JOIN public.unitload ul ON ((su.unitload_id = ul.id)))
  GROUP BY i.id, i.item_nr, c.id, c.cl_nr;
```

Note the split is a `pg_dump` artefact of a self-referencing view; it is **not** a pattern a hand-written `V2.2.33` should imitate. A new migration writes one `CREATE OR REPLACE VIEW`.

### 1.2 How `V2.2.07` / `V2.2.08` patch it

**Neither patches `stock_view`.** This is a correction to the task brief's premise, and it changes what the precedent teaches.

- `V2.2.07__fix_stock_history_client_id_aggregation.sql` replaces the **function** `stock_history(timestamptz)`, which *reads* `stock_view` (`"FROM stock_view sv"`, `V2.2.07:47`). Its header states the mechanism to copy: *"CREATE OR REPLACE, no DROP: the signature and RETURNS TABLE column list are unchanged, so the OID, ownership and ACLs are preserved … Idempotent."*
- `V2.2.08__fix_transaction_detail_null_amounts.sql` replaces the function `transaction_detail`; it only *mentions* `stock_view` in a comment (`V2.2.08:17`, *"symmetry (stock_view.total_stock is non-null on the canonical schema …)"*).

**So `stock_view` is not the migration precedent — the view-migration precedent is elsewhere.** Derived by `git grep -n 'CREATE OR REPLACE VIEW\|CREATE VIEW' origin/develop -- src/main/resources/db/migration/`, excluding the `V2.2.00` base dump, there are **exactly three** view statements in the whole delta set, in **two** files:

- `V2.2.01__replenishment_monitor_view_add_section_and_ro_id.sql:29` — `CREATE OR REPLACE VIEW public.replenishment_monitor_view AS`
- `V2.2.02__lock_report_exclude_shipped.sql:15` and `:39` — `CREATE OR REPLACE VIEW public.lock_overview_dto_view AS` / `…public.lock_overview_all_view AS`

`V2.2.01` is the one to read before writing `V2.2.33`; its header is the model for §2.3 and it states the replace rule explicitly:

> All existing columns keep their name/order/type, so CREATE OR REPLACE VIEW is legal and re-runnable. A single db/migration delta reaches every tenant: both brand-new and onboarded DBs apply db/migration V2.2.x after converging at the V2.1.16 watermark.

It also carries a **`Row-count invariance:`** paragraph justifying that its added join cannot change cardinality — the same obligation §2.3's draft discharges for the `(client_id, item_nr)` pair join, and §4.2 measures.

⚠ `V2.2.01`'s header also contains a **known-false** sentence — *"Hibernate resolves it to column `ro_id` via CamelCaseToUnderscoresNamingStrategy"* — left deliberately unedited because the file is applied everywhere and its Flyway CRC32 covers comments. The retraction lives only in `ReplenishmentMonitorViewSchemaIT`'s javadoc (see §7.1, naming strategy). **Copy `V2.2.01`'s shape, not its naming-strategy claim.**

(The function-replacement precedents — `V2.2.07`, `V2.2.08`, `V2.2.12`, `V2.2.25` — are what the ownership/`42501` guidance in §2.2 comes from.)

### 1.3 How `StockView.java` maps it — and the `@Id` question

`src/main/java/net/aim_ai/wms/model/StockView.java`:

```java
@Entity
@Table(name = "stock_view")
public class StockView {

    @Id
    @Column(name = "row_id")
    private Long rowId;
```

and it does **not** extend `AbstractBaseEntity`. It defines its own `equals`/`hashCode`:

```java
    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof StockView other)) return false;
        return getRowId() != null && getRowId().equals(other.getRowId());
    }
```

`stock_view` has **no natural key** — it is a `GROUP BY` aggregate — so its `@Id` is the synthetic `row_number() OVER () AS row_id`. That is a genuinely fragile identifier (unstable across executions, and `row_number() OVER ()` with no `ORDER BY` has no defined ordering), and it exists only because there was nothing better.

**`StockrecordView` does not have that problem, and must not copy that part of the precedent.** `stockrecord` carries a real PK:

```
Indexes:
    "stockrecord_pkey" PRIMARY KEY, btree (id)
```
(`\d stockrecord` on `dev_wh01_om1`, 2026-09-18.)

The view is a per-row projection of `stockrecord` (no `GROUP BY`, no window function), so `sr.id` passes straight through and is unique **provided both joins are provably non-multiplying** — which §4.2 measures. So:

```java
@Entity
@Table(name = "stockrecord_view")
public class StockrecordView {
    @Id
    private Long id;          // = stockrecord.id, the real PK
```

**⚠ `StockrecordView` must NOT extend `AbstractBaseEntity`.** That superclass carries

```java
    @Id
    @GeneratedValue(strategy = GenerationType.SEQUENCE, generator = "entity_gen")
    …
    @Version
    private Integer version;
```

A `@Version` column on a read-only view entity invites Hibernate to attempt optimistic-lock bookkeeping, and `@GeneratedValue` from `seqentities` is meaningless for a view. `StockView` avoids both by standing alone; `StockrecordView` must do the same. Consequence to carry into P2: `created` and `modified` must be **re-declared** on `StockrecordView` (they live on `AbstractBaseEntity` as `LocalDateTime`, mapped to `timestamp with time zone` columns).

### 1.4 How `StockViewRepository.findByKeyword` filters — the template for AC-1/AC-4

```java
@RepositoryRestResource(collectionResourceRel = "stockView", path = "stockView")
public interface StockViewRepository extends ReadOnlyPagingAndSortingRepository<StockView, Long> {

    @RestResource(path = "findByKeyword", rel = "findByKeyword")
    @Query("SELECT p FROM StockView p " +
        " WHERE (CONCAT(LOWER(p.itemName), ' ', LOWER(p.itemNr), ' ', LOWER(p.clName), ' ', LOWER(p.clName)) LIKE LOWER(concat('%', :keyword,'%')) or :keyword = '')" +
        " AND (p.clNr = :clientNumber OR :clientNumber IS NULL OR :clientNumber = '') ")
    Page<StockView> findByKeyword(@Param("keyword") String keyword, @Param("clientNumber") String clientNumber,  Pageable p);
```

Four things to carry, and **one to reject**:

1. **Carry**: the three-way null/empty escape `(p.X = :p OR :p IS NULL OR :p = '')` — that is what makes "All Shippers" a no-op filter on one endpoint rather than two endpoints.
2. **Carry**: `or :keyword = ''` on the keyword clause. `StockrecordRepository.findByKeyword` **lacks** it (`"… LIKE LOWER(concat('%', :keyword,'%'))"`, no escape), and §4.1 measures what that costs.
3. **Carry**: `ReadOnlyPagingAndSortingRepository`, which suppresses `save`/`saveAll` from both REST and Swagger (`repo/cinterface/ReadOnlyPagingAndSortingRepository.java`: `@Hidden @RestResource(exported = false) @Override <S extends T> S save(S n);`).
4. **Carry**: the three `findAll` suppressions, with the reason given verbatim in the source — *"Per critic M3, all three overloads must be suppressed — omitting findAll(Sort) leaves a sorted-by-default bypass."* `/api/stockrecordView` unbounded over 9.7M rows is an OOM, so this is not optional.
5. **REJECT**: `p.clNr = :clientNumber` as the filter predicate. §4.3 measures it at **4.3× slower** than filtering on `client_id`. This is the single most consequential deviation from the precedent.

The sibling `findByClientOffsetAndLimit` (the export query) shows the native-SQL form of the same escape:

```java
    @Query(value="SELECT * FROM Stock_view p " +
        "WHERE (CONCAT(LOWER(p.item_name), …) LIKE LOWER(concat('%', :keyword,'%')) or :keyword = '') " +
        "AND (COALESCE(p.cl_nr,'') = CAST(COALESCE(:filter,'') as TEXT) OR :filter IS NULL) " +
        "OFFSET :offset LIMIT :limit", nativeQuery = true)
```

Note the export idiom names the parameter **`filter`**, and the table-read idiom names it **`clientNumber`**. The UI sends `filter` in the export POST body and `clientNumber` in the table GET query string. Both names must be kept as-is for the wire contract.

---

## §2. Draft `V2.2.33` migration SQL

### 2.1 Version choice

`V2.2.33` is next free (established, swept across 40 remote refs; `V2.2.32` is max and is on `develop`/`main`/`release`). `db/migration/README.md` requires re-running the sweep **immediately before merge**, not only when the file is named:

> Run it **before** naming the file and **again just before merge** — a version that was free when you branched may have been taken while your PR sat in review.

```bash
bash src/main/resources/db/check-migration-version-collision.sh V2.2.33
```
⚠ Path is relative to the **repo root**; the script `cd`s to `git rev-parse --show-toplevel` itself. `V2.2.11` is permanently burned (README, "Reserved / skipped version numbers") — do not reuse.

### 2.2 The `42501 must be owner` hazard, and why it is real here

`db/migration/README.md` records this as a production incident, not a theory:

> It hit prod for real on 2026-08-05 — `V2.2.07` (`CREATE OR REPLACE FUNCTION stock_history`) failed on `wh01_hydra_v2` because `stock_history` had been hotfixed as the superuser, so the tenant stuck at `V2.2.06`.

and

> because Flyway stops at the first failing migration, that **one** non-owned object freezes the whole tenant at its current version: every later `V2.2.x` delta is skipped on every boot.

**Why `V2.2.33` is materially safer than `V2.2.07` was**: `stockrecord_view` **does not exist yet on any tenant**. `CREATE OR REPLACE VIEW` on a name that does not exist is a plain `CREATE`, which requires only `CREATE` on schema `public` — not object ownership. The `42501` failure mode of `V2.2.07` came from *replacing* an object owned by someone else. So the ownership risk here is **schema-level, not object-level**.

That is not zero. Mitigation, in the migration and in the runbook:
- Write it as `CREATE OR REPLACE VIEW` (idempotent on re-run, and correct if a future `V2.2.x` needs to amend it — but see the caveat below).
- ⚠ **`CREATE OR REPLACE VIEW` cannot change the column list.** PostgreSQL only permits *adding* columns at the end and forbids renaming, reordering or retyping. If a later ticket needs to change a column, that migration must `DROP VIEW … CASCADE` first — which is exactly the step that re-introduces the ownership requirement. Say so in the header now.
- Do **not** add `IF NOT EXISTS` reasoning by analogy with `V2.2.32`'s `ADD COLUMN IF NOT EXISTS`: that file's own header records that *"Postgres checks ownership BEFORE IF NOT EXISTS, so `IF NOT EXISTS` does not make this safe on such a tenant."* The same applies here.
- Post-deploy, verify per tenant — `V2.2.32`'s header is explicit: *"Verify per tenant after deploy; do not infer it from a healthy application."* The existing tool is `src/main/resources/db/reassign-tenant-ownership.sh`.

### 2.3 Draft SQL

Header style is modelled on `V2.2.32` (long prose WHY, explicit risk statements, schema-qualified, no explicit `BEGIN`/`COMMIT`) and on `V2.2.01`, the nearest view precedent — including its `Row-count invariance:` obligation, discharged here by the pair-join paragraph. Flyway wraps each script in a transaction and DDL is transactional on PostgreSQL, so no explicit `BEGIN`/`COMMIT`.

```sql
-- Project the Stock Unit Record report over its shipper and product, so the report can be filtered by
-- shipper and can show the product name.
--
-- WHY A VIEW. SBDEV-3417 (b20eb9f1, on develop) established that Spring Data REST cannot render a
-- collection of interface projections, and Page<T> is not exempt. The Stock Unit Record table is served
-- by SDR (/api/stockrecord/search/findByKeyword) and stays there, so the two columns the report needs
-- that stockrecord does not carry -- the product name and the shipper name/number -- have to arrive as
-- mapped columns of a real relation. That is what stock_view already does for the Inventory report, and
-- this view is the same construction applied to the audit table.
--
-- WHY THE JOIN KEY IS THE PAIR (client_id, item_nr) AND NEVER item_nr ALONE. stockrecord.itemdata holds
-- a SKU *string*, with no foreign key to itemdata. itemdata enforces UNIQUE (client_id, item_nr)
-- (constraint uk3l3dgof3l6mc1dl7s3lmida65), and nothing enforces uniqueness of item_nr on its own:
-- measured on dev_wh01_om1 2026-09-18, 8,808 itemdata rows carry only 8,721 distinct item_nr values, so
-- 87 SKU strings are shared between shippers. Joining on item_nr alone therefore MULTIPLIES rows -- for
-- shipper ARW (client_id 60500) it turns 873,021 stockrecord rows into 887,856, inventing 14,835
-- phantom audit entries. The pair join multiplies exactly 0 (873,021 -> 873,021), and over the whole
-- table 9,726,795 -> 9,726,795.
--
-- WHY BOTH JOINS ARE LEFT. stockrecord is an append-only audit log; itemdata and client rows are not.
-- An INNER JOIN would silently DELETE history whenever a SKU string stops resolving -- the failure mode
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
-- ⚠ DO NOT WIDEN THE KEYWORD SEARCH TO item_name OR cl_name. That references a joined column in the
-- WHERE clause, which defeats the elimination above: measured, the unfiltered count goes from ~7.3 s to
-- ~17.9 s (2.5x) because both hash joins must now run over all 9.7 M rows before the count. If product-
-- name search is ever wanted it needs its own design, not a longer CONCAT.
--
-- COLUMN SET. Every stockrecord column is projected unchanged so the view is a strict superset of the
-- table and the report's detail popup keeps working, plus item_id/item_name from itemdata and
-- cl_nr/cl_name from client. version and entity_lock are projected for shape parity only; the mapped
-- entity must NOT declare @Version on them (a view is read-only).
--
-- OWNERSHIP AND REPLAY. stockrecord_view does not exist on any tenant, so this is a plain CREATE and
-- needs only CREATE on schema public -- not the object ownership that froze wh01_hydra_v2 at V2.2.06 on
-- 2026-08-05 (see db/migration/README.md). CREATE OR REPLACE makes re-runs a no-op.
-- ⚠ A LATER migration that needs to rename, reorder or retype any column here CANNOT use
-- CREATE OR REPLACE VIEW -- PostgreSQL only allows appending columns -- and its DROP VIEW ... CASCADE
-- will need ownership. Adding a column at the end is safe; anything else is not.
--
-- LOCK AND REWRITE RISK: none. Creating a view is a catalog-only change; no data is touched and no lock
-- is taken on stockrecord (largest reachable tenant: dev_wh01_om1, 9,726,795 rows).
--
-- NO STARTUP SAFETY NET. Production runs spring.jpa.hibernate.ddl-auto=none, so a tenant that misses
-- this migration BOOTS GREEN and then throws 42P01 "relation stockrecord_view does not exist" on every
-- Stock Unit Record page load, behind passing health probes. Tenant Flyway failures never abort the
-- boot. Verify per tenant after deploy; do not infer it from a healthy application.

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
```

### 2.4 The companion index — NOT optional

**This is a second DDL statement the plan must carry, and §4.4 is the measurement that forces it.**

```sql
-- The shipper filter is useless without this. ORDER BY created DESC LIMIT 10 with a client_id predicate
-- walks index_stockrecord_created backwards and discards every other shipper's rows until it finds ten:
-- measured on dev_wh01_om1 for client_id 419803 (4,366 rows, newest 2022-03-17), "Rows Removed by
-- Filter: 7,564,825" at 1,987-2,865 ms -- SLOWER than the same page with no filter at all (5-7 ms).
-- With this index the same page plans as Index Scan Backward using (client_id, created) and runs in
-- 0.455 ms. Build cost measured in a rolled-back transaction on the 9,726,795-row table: 6.3 s, 276 MB.
CREATE INDEX IF NOT EXISTS index_stockrecord_client_id_created
    ON public.stockrecord (client_id, created);
```

⚠ **Decide before writing it**: plain `CREATE INDEX` takes a `SHARE` lock and blocks writes to `stockrecord` for the build. 6.3 s measured on dev. `stockrecord` is written by every stock movement, so on a busy tenant that is a 6-second write stall. `CREATE INDEX CONCURRENTLY` avoids it but **cannot run inside a transaction**, and Flyway wraps each script in one — the escape is Flyway's `-- <script> ... ` transactional control, which this repo has no precedent for. Options, in order of preference:
1. Plain `CREATE INDEX` in `V2.2.33`, accepting a ~6 s write stall per tenant during the deploy boot. (Recommended — it is one migration, at boot, and the measured cost is seconds.)
2. Split it into its own `V2.2.34` run out-of-band by an operator with `CONCURRENTLY`.
This is an **open question for Nam** (§9, Q3).

---

## §3. Where each requested item landed

The analysis request numbered its asks 1-9; this document numbers its sections 0-10. Map:

| requested | here |
|---|---|
| 1. §0 Affected Sites table, by enumeration | **§0** (0.1 API, 0.2 UI, plus the method's blind spots) |
| 2. the `stock_view` / `StockView` precedent | **§1** — incl. the `@Id` question at §1.3 |
| 3. draft the `V2.2.33` migration SQL | **§2** — incl. §2.4, a **second** DDL statement §4.4 forces |
| 4. measure the VIEW, do not assume | **§4** — the headline answer is §4.1 |
| 5. the Export path, end to end | **§5** — plus four adjacent traps at §5.3-§5.7 |
| 6. sorting through SDR over a view | **§6** |
| 7. v2 constraint + horizontal-scalability checklists | **§7** — incl. the H2 verdict at §7.2 |
| 8. testing surface | **§8** |
| 9. open questions | **§9** |
| *(not requested)* | **§10** — what this bundle did **not** establish |

---

## §4. Measurements against the real view

**Method.** The view defined in §2.3 was created on `dev_wh01_om1` as `stockrecord_view_probe`, measured with `EXPLAIN (ANALYZE, BUFFERS)`, then dropped. The composite index was built and measured inside an explicit `BEGIN … ROLLBACK`. **Leave-as-found was verified**: `information_schema.views` shows 0 rows matching `%probe%`; `pg_indexes` for `stockrecord` shows the same 13 indexes as before (12 + `stockrecord_pkey`); `count(*) = 9,726,795` unchanged.

**Instrument caveat.** All numbers below use *literal* predicates. Hibernate sends bind parameters; pgjdbc uses a custom plan (parameters substituted as constants at plan time) for the first `prepareThreshold=5` executions, after which it may switch to a generic plan. Constant folding of `:keyword = ''` therefore happens on the custom-plan path measured here but is **not guaranteed** on the generic-plan path. Every conclusion below that depends on folding is flagged.

Every figure is two consecutive runs (warm cache), reported as `run1/run2`.

### 4.1 The headline: does the "All Shippers" default regress?

| # | query | plan | time |
|---|---|---|---|
| **A0** | `count(id)` on **`stockrecord`** with the *current* `findByKeyword` predicate (`CONCAT(...) LIKE '%%'`, **no** `or :keyword=''` escape) | `Parallel Seq Scan on stockrecord` | **7,288 / 7,261 ms** |
| **A1** | same predicate, over **`stockrecord_view_probe`** | `Parallel Seq Scan on stockrecord sr` — *both LEFT JOINs eliminated* | **7,356 / 7,647 ms** |
| **A2** | over the view, with the `StockView`-style `or :keyword = ''` escape added | `Parallel Seq Scan on stockrecord sr`, filter constant-folded away entirely | **4,945 / 5,031 ms** |

**Verdict: the unfiltered "All Shippers" default does NOT regress.** A1 vs A0 is +1% to +5%, inside run-to-run noise on a shared dev box. The view is free on the default page because PostgreSQL eliminates both LEFT JOINs — `client.id` is a PK and `itemdata` carries `UNIQUE (client_id, item_nr)`, so neither can multiply, and the count references no column from either.

Plan evidence for A1 (the whole join tree is gone):
```
Finalize Aggregate
   ->  Gather  (Workers Planned: 4)
         ->  Partial Aggregate
               ->  Parallel Seq Scan on stockrecord sr  (actual rows=1945359 loops=5)
```

A2 shows a free ~30% win available by adopting the `StockView` escape clause — but it depends on constant folding, so treat it as a bonus, not a guarantee (see the instrument caveat).

**The 4,700 ms figure in the brief is reproducible but methodology-sensitive**: the same A0 query with `TIMING OFF` measures **3,170 ms**. `EXPLAIN ANALYZE` per-node timing is itself expensive on a 9.7M-row scan. Use one methodology throughout; the **A0↔A1 comparison is what matters**, and it is like-for-like.

### 4.2 Join safety, re-derived with positive controls

| measurement | result |
|---|---|
| `count(*)` through the view vs base table | **9,726,795 / 9,726,795** — multiplies 0 rows |
| rows where `(client_id, itemdata)` does not resolve to an `itemdata` row | **0** |
| positive control — same query with the predicate poisoned (`i.item_nr = sr.itemdata \|\| '_NOPE'`) | **9,726,795** → the instrument *can* report non-matches |
| naive `item_nr`-only join, shipper ARW (`client_id=60500`) | 873,021 → **887,856** (+14,835 phantom rows) |
| pair join, same shipper | 873,021 → **873,021** |
| NULLs in the five keyword columns (`activitycode, fromstoragelocation, fromunitload, itemdata, operator`) | **0 / 0 / 0 / 0 / 0** |

Both brief-supplied figures reproduce exactly. The zero-result rows each carry their own positive control, so the zeros are measurements and not broken instruments.

The NULL census matters separately: the JPQL `CONCAT(...)` renders on PostgreSQL as `a || b || …`, and `||` with any NULL operand yields NULL, so a NULL in any of those five columns would make the row invisible to the report. On this tenant there are none — so the existing report is not silently dropping rows — but the invariant is **not** enforced by the schema (`fromunitload`, `itemdata` are nullable) and the view does not change it either way.

### 4.3 The shipper filter — **filter on `client_id`, not on `cl_nr`**

All three forms return the same 873,021 rows for shipper ARW.

| # | filter expression | plan | time |
|---|---|---|---|
| **B1** | `p.cl_nr = 'ARW'` — **the `StockView` idiom** | serial `Nested Loop`: index scan on `client.uk_e2cgvit466blvvac3y77crsyg`, then `Index Scan using index_stockrecord_client_id` — **no parallelism** | **4,090 / 4,280 ms** |
| **B2** | `p.client_id = 60500` | `Parallel Index Scan using index_stockrecord_client_id`, 4 workers | **987 / 943 ms** |
| **B3** | `p.client_id = (SELECT c2.id FROM client c2 WHERE c2.cl_nr='ARW')` | `InitPlan` + `Parallel Index Scan`, 2 workers | **1,554 / 1,597 ms** |

**B1 is 4.3× slower than B2.** Root cause, visible in the plan: with the predicate on the joined column the planner cannot propagate selectivity across the join, so it estimates `rows=47,082` against an actual `873,021` — an **18× underestimate** — and picks a serial nested loop. B2 has real MCV statistics on `stockrecord.client_id` and gets a parallel plan.

**Recommendation: the repository method takes `Long clientId`, not `String clientNumber`.** The wire contract then becomes `&clientId=60500` instead of `&clientNumber=ARW`, and the UI's `<v-select>` uses `item-value="id"` rather than `item-value="clNr"` — the `admin/client/getClients` payload already carries `id` (it is `Page<Client>` of the full entity, `ClientController.allClients`).

If Nam prefers to keep `cl_nr` on the wire for consistency with the Inventory report, **B3 is the fallback** — expressible in JPQL because `Client` is a mapped entity (`p.clientId = (SELECT c.id FROM Client c WHERE c.clNr = :clientNumber)`), and it recovers most of the win. **B1 must not be used.**

### 4.4 The content page — this is where the feature breaks without an index

`select * … order by created desc limit 10 offset 0`, i.e. the default first page.

| # | case | plan | time |
|---|---|---|---|
| **C1** | unfiltered | `Limit` → nested-loop left joins over `Index Scan Backward using index_stockrecord_created`, 10 rows | **5.1 / 6.6 ms** |
| **C2** | `client_id = 60500` (ARW, 873k rows, newest 2023-08-14) | same shape, but the backward walk must skip every other shipper | **4,709 / 1,531 ms** |
| **C3** | `client_id = 419803` (C24, 4,366 rows, newest 2022-03-17) — worst case | `Rows Removed by Filter: 7,564,825` | **2,865 / 1,987 ms** |

**Applying the shipper filter makes the first page 300–900× SLOWER than not applying it.** That is the exact opposite of what the ticket promises, and it is entirely invisible to any test that does not use a large, time-skewed dataset.

With `CREATE INDEX index_stockrecord_client_id_created ON stockrecord (client_id, created)` (built in a rolled-back transaction: **6.3 s**, **276 MB**):

| case | plan | time | speed-up |
|---|---|---|---|
| C3 worst case | `Index Scan Backward using probe_sr_client_created`, `Index Cond: (client_id = 419803)` | **0.455 ms** | **6,300×** |
| C2 ARW | same | **0.350 ms** | **4,400×** |
| B2 filtered count | unchanged (`index_stockrecord_client_id` still chosen) | 899 ms | — |

Note the index also turns the `itemdata` lookup into `Index Cond: ((client_id = 419803) AND ((item_nr)::text = (sr.itemdata)::text))` — a 10-loop unique index probe at 0.005 ms/loop. The join genuinely costs nothing on a paged read.

### 4.5 Sorting by `item_name` — an 18-second page, one click away

`order by item_name asc limit 10 offset 0`:

| # | case | plan | time |
|---|---|---|---|
| **D1** | unfiltered | `Sort (top-N heapsort)` over `Hash Left Join` × 2 over `Parallel Seq Scan` on all 9.7M rows | **17,942 ms** |
| **D2** | `client_id = 60500` | `Sort Method: external merge  Disk: 54,984 kB` **per worker** (4 workers ≈ 215 MB of temp I/O) | **1,853 ms** |
| **control** | status quo, `order by operator` on the bare table, unfiltered | `Sort (top-N heapsort)` over `Parallel Seq Scan` | **7,847 ms** |
| **control** | status quo, `order by itemdata`, unfiltered | same | **7,575 ms** |

**Reading**: an unindexed sort on this report is *already* a ~7.6 s query today — every header in `stockUnitRecord.vue` except `actions` carries `sortable: true`, and only `created` has a usable index. So D1 is not a new class of problem. But it is **2.3× worse** than the existing worst case, because the joins must be materialized before the sort, and D2 spills to disk.

**Recommendation for the plan**: ship the SKU Name column with `sortable: false`. AC-4 requires *"keyword search, sorting and pagination continue to work in combination with the shipper filter"* — it does not require the *new* column to be sortable, and making it sortable hands every user a one-click 18-second query. If Nam wants it sortable, say so explicitly and accept the number (§9, Q4).

⚠ **Whatever is decided, it must be enforced in the entity, not only in the UI.** SDR passes `&sort=` straight through to JPA. A user who types `?sort=itemName,asc` on the URL gets D1 regardless of what the header array says. The only hard stop is not mapping a sortable property — which conflicts with AC-3. So this is a *policy* decision with no technical enforcement; record it as such.

---

## §5. The Export path, end to end — and the traps around it

### 5.1 The trace

```
components/reports/stockUnitRecord.vue:25   <v-btn … @click="openExport">
  → openExport()           this.reportType = 'Stock Unit'; this.showExport = true
  → <export-report :show="showExport" :reportType="reportType" @close="closeExport" />   [NO :filter]
components/reports/popups/exportReport.vue:131-139
  → let data = { offset, limit, dateFormat, fileName,
                 filter: this.filter && this.filter != 'All Shippers' ? this.filter : null,
                 includeShipped: this.includeShipped === true }
exportReport.vue:160-161
  → } else if (this.reportType == 'Stock Unit') { this.$store.dispatch('reports/stockUnit/export', params) }
store/reports/stockUnit.js:67-76
  → const exportData = { ...params.data, keyword: context.state.list?.search || '' };
  → $post('/report/exportStockUnitRecord', exportData, { responseType: 'blob', … })
ReportController.java:250-261   @RequiresFunction(WEB_UI_VIEW_STOCK_UNIT_RECORD) @PostMapping("/exportStockUnitRecord")
  → Integer offset = (Integer) reqMap.get("offset");
    Integer limit  = (Integer) reqMap.get("limit");
    String keyword = (String)  reqMap.get("keyword");     // ← `filter` is NEVER read
  → reportService.exportStockUnitRecord(response, offset, limit, keyword);
ReportService.java:347-390
  → List<Stockrecord> views = stockrecordRepository.findByOffsetAndLimit(keyword, offset, limit);
  → 15-column Object[] … fileExportService.exportExcelFile(null, "Receiving", null, headerNames, rows, response);
StockrecordRepository.java:47-52   nativeQuery, "SELECT * FROM Stockrecord p WHERE (… LIKE …) order by p.created DESC offset :offset limit :limit"
```

**Key result: `filter` is ALREADY in the POST body and already reaches the controller.** `exportReport.vue` builds it unconditionally for every report type, and `store/reports/stockUnit.js` spreads `...params.data`. Today `stockUnitRecord.vue` passes no `:filter` prop, so `this.filter` is `undefined` and the field serialises as `null` — the controller then never reads the key.

So AC-2's export half is:
- **UI**: one attribute — `:filter="shipper"` on the `<export-report>` tag (site #23). `store/reports/stockUnit.js` needs **no change at all** for the filter (site #28).
- **API**: `ReportController.exportStockUnitRecord` reads `String filter = (String) reqMap.get("filter");` and passes it through; `ReportService.exportStockUnitRecord` gains the parameter; `StockrecordRepository.findByOffsetAndLimit` gains the predicate.

**⚠ The `filter` value is whatever the dropdown's `item-value` yields.** If §4.3's recommendation is taken (`item-value="id"`), then `filter` arrives as a **number, not a String**, and `(String) reqMap.get("filter")` throws `ClassCastException` — caught by `exportStockUnitRecord`'s own `} catch (Exception e) { LOG.error("export failed unexpectedly: {}", …); errors.add(getErrorMessage("Runtime Error", e.getMessage()));` block — note this second catch exists on `exportStockUnitRecord` and **not** on its siblings `exportInventory`/`exportOutboundParcel` — and turned into a 200 with an error body, which the UI renders as a downloaded `.xlsx` containing an error string. That is a silent-ish failure. Read it as `Object` / `Number` and convert, or keep the export's wire type as String and parse.

### 5.2 Does the export share a query with the table read?

**No. They are fully disjoint code paths**, which is why this is the part most likely to be missed:

| | table read | export |
|---|---|---|
| transport | `GET /api/stockrecord/search/findByKeyword` (Spring Data REST) | `POST /v3/report/exportStockUnitRecord` (MVC) |
| repository method | `findByKeyword` — **JPQL**, `Page<Stockrecord>` | `findByOffsetAndLimit` — **nativeQuery**, `List<Stockrecord>` |
| keyword escape | **none** (`LIKE LOWER(concat('%', :keyword,'%'))`) | **has one** (`… or :keyword = ''`) |
| ordering | from `&sort=`, UI default `created,desc` | hard-coded `order by p.created DESC` |
| paging | `Pageable` (`&page=&size=`) | `offset :offset limit :limit` from the popup |
| function gate | **none** (SDR is unruled for `Stockrecord`, §7.4) | `@RequiresFunction(WEB_UI_VIEW_STOCK_UNIT_RECORD)` |

The two keyword semantics **already differ today**: on the table read, `keyword=''` still evaluates `LIKE '%%'`; on the export it short-circuits. Any test asserting "export output == table output" must account for that, or it will chase a phantom.

**Decision the plan must make**: does the export read `stockrecord_view` too, or stay on `stockrecord`? It does not need `item_name` (the 15 export columns are all base columns) and it does not need `cl_name` — but AC-2 says *"Export output"* must respect the shipper. Filtering the export on `client_id` requires **no view at all**. Recommended: **leave the export on the `stockrecord` table** and add `AND (p.client_id = :clientId OR :clientId IS NULL)`; it is the smaller change and avoids adding `item_name`/`cl_name` to the export's 15-column contract by accident. If the product owner wants the SKU name in the exported spreadsheet as well, that is a *scope addition* to AC-2 and should be confirmed (§9, Q2).

### 5.3 `DashboardController extends ReportController` — the twin endpoint

`Sbdev3017TrancheGateContextTest.java:186-213` states the mechanism and pins it:

> Both prefixes are pinned for all 13 ReportController-declared handlers … the dual mapping is INHERITANCE (DashboardController extends ReportController), one method-level annotation covers both … **The web UI never calls the /v3/dashboard export twins, so no UI test can catch that — only these rows can.**

```java
row("ReportController",    "/v3/report/exportStockUnitRecord",       "WEB_UI_VIEW_STOCK_UNIT_RECORD");
row("ReportController",    "/v3/dashboard/exportStockUnitRecord",    "WEB_UI_VIEW_STOCK_UNIT_RECORD");
```

Changing the `exportStockUnitRecord` signature changes **both** routes. No edit is needed, but both pins must stay green, and any new export endpoint would need two new rows.

### 5.4 `/v3/client/allClients` does not list `WEB_UI_VIEW_STOCK_UNIT_RECORD` — latent 403 on the new dropdown

`ClientController.java:218-228` gates the dropdown's data source on an ANY-of list of **eleven** functions. `WEB_UI_VIEW_STOCK_UNIT_RECORD` is not one of them. The list is pinned in `Sbdev3017TrancheGateContextTest.java:665-671`.

Adding a shipper dropdown to the Stock Unit Record report makes that report a twelfth caller of `admin/client/getClients` — so the function must be added, or a user holding only `WEB_UI_VIEW_STOCK_UNIT_RECORD` gets a 403 and an **empty dropdown**. That is the exact failure `SdrFunctionGuard`'s javadoc warns about: *"An over-gated read renders an empty screen rather than an error, so it is invisible to every test and to the denial counter."*

**Measured blast radius on `dev_wh01_om1` (2026-09-18), user → group → role → function:**

| | |
|---|---|
| users holding `WEB_UI_VIEW_STOCK_UNIT_RECORD` | **45** |
| of those, users holding **none** of the 11 | **0** |
| positive control — same query, allow-list replaced by a non-existent function | **45** (so the zero is a measurement, not a broken query) |
| positive control — count of holders of `WEB_UI_VIEW_NOT_A_REAL_FUNCTION` | **0** |

Three of the eleven (`PARCEL_MONITOR`, `FLOWBIN_MONITOR`, `STOCK_UNIT_LOCK_OVERVIEW`) each cover all 45 today.

**So this is latent, not live — on this one tenant, today.** ⚠ The claim "0 users are blocked" is scoped to `dev_wh01_om1` at one instant; I did not measure any other tenant, and role assignments change. Fix it anyway: the invariant is *"every screen carrying a shipper dropdown contributes its view function to `allClients`"*, and the 11-entry list is the kind of prose enumeration that rots.

**Two edits**: `ClientController.java` `@RequiresFunction` list, and the matching `row(...)` in `Sbdev3017TrancheGateContextTest.java`. Changing only the first turns that test red; changing only the second is a false green.

### 5.5 `exposeIdsFor` — omit `StockrecordView` and the details popup breaks

`RestConfiguration.java:875-886`:
```java
config.exposeIdsFor(Advice.class, Adviceposition.class, …, Stockrecord.class,
    Stockunit.class, StockView.class, Unitload.class, …);
```
Spring Data REST **omits `id` from the HAL body** unless the domain type is listed. `stockUnitRecord.vue:321` does:
```js
this.details = await this.$store.dispatch('reports/stockUnit/getStockUnitDetail', {id: item.id})
```
→ `/stockrecord/stockRecordDetailsById/${data.id}`. With `id` absent, that becomes `/stockRecordDetailsById/undefined` and the eye icon 400s. `StockView` is in the list; `StockrecordView` must be added.

Likewise add `StockrecordView.class` to `SDR_WRITE_WITHDRAWN` (`RestConfiguration.java:508-543`) for parity with `StockView.class` and `Stockrecord.class`, both already there.

### 5.6 `searchUrlSync` claims the first matching `data()` key

`mixins/searchUrlSync.js:2`:
```js
const possibleProps = ['search', 'keyword', 'filter', 'searchText', 'query', 'searchQuery'];
```
and `setupSearchSync()` binds the URL `?search=` to the **first** of those that is `in this.$data`.

`stockUnitRecord.vue` has `keyword` in `data()`, so `keyword` wins — and `keyword` must keep winning, because SBDEV-2658's adjustment-alert toast deep-links via `?search={sku}` (`stockUnitRecord.vue:331-335`, and the `'$route.query.search'` watcher at :227). **If the shipper filter is added as a `data()` property named `filter`, nothing breaks** (`keyword` still sorts first) — but if it is ever named `search`, the deep link silently starts populating the shipper instead of the keyword.

`inventoryReport.vue` sidesteps this entirely by making `shipper` a **computed** backed by Vuex (site #32) — `'filter' in this.$data` never sees a computed. **Copy that.** It also gives the filter the same cross-navigation persistence the Inventory report has.

### 5.7 Two hazards in `store/reports/inventory.js` not to copy verbatim

```js
if (data.clientNumber != null & data.clientNumber !== 'All Shippers') {
```
(`store/reports/inventory.js:64`)

- **`&` is the bitwise AND, not `&&`.** With two booleans it coerces to 0/1 and happens to behave like `&&`, so it works — by accident. Write `&&`.
- The `!== 'All Shippers'` guard is **vestigial**. The "All Shippers" entry is `{ name: null, label: 'All Shippers' }` with **no `clNr` key** (`inventoryReport.vue:301`), and the select's `item-value="clNr"` therefore yields `undefined`, which `undefined != null` already rejects. The guard only fires if someone changes `item-value`. If §4.3's `item-value="id"` recommendation is taken, re-derive this condition from scratch rather than porting it.

---

## §6. Sorting through SDR over a view

### 6.1 What is sortable today

`stockUnitRecord.vue:140-205` declares nine sortable columns; `updateTable()` (:292-299) turns the first into `sortUrl` and `store/reports/stockUnit.js:49` appends `&sort=` verbatim:

```js
sortUrl = sortBy[0] + ',' + (sortDesc[0] ? 'desc' : 'asc')
…
(data.sortUrl ? '&sort=' + data.sortUrl : '')
```

| header `value` | maps to entity property | on the base table? |
|---|---|---|
| `created` | `created` (from `AbstractBaseEntity`) | yes — `index_stockrecord_created` |
| `type` | `type` | yes |
| `activitycode` | `activitycode` | yes |
| `itemdata` | `itemdata` | yes |
| `fromstoragelocation` | `fromstoragelocation` | yes |
| `tostoragelocation` | `tostoragelocation` | yes |
| `amount` | `amount` | yes |
| `amountstock` | `amountstock` | yes |
| `operator` | `operator` | yes |

Derived by reading the `headers` array against `Stockrecord.java`. All nine resolve to mapped fields, so all nine work today. Only `created` has a usable index (the others' indexes are on `lower(col)` and cannot serve an `ORDER BY col`).

### 6.2 What happens when sorting by a joined column on a view

Nothing special at the SDR or JPA layer — `item_name` is an ordinary mapped column of `stockrecord_view`, so `&sort=itemName,asc` produces `ORDER BY srv.item_name`. It resolves and returns correct results.

The cost is the problem, measured in §4.5: **17,942 ms unfiltered**, and **54 MB/worker of disk-spilled external merge sort** when filtered. Contrast the unfiltered `created,desc` default at 5–7 ms.

**Hard rule the plan must state**: *every column the UI can sort by must exist as a mapped property on `StockrecordView`.* An SDR sort on an unmapped property throws `PropertyReferenceException` → HTTP 500, not a graceful fallback. Since `StockrecordView` will project every `stockrecord` column, all nine existing sorts survive. But note **`id` and `version` must also be mapped** if anything sorts on them — the details-popup exclude list (`:exclude-fields="['id', 'version']"`) proves the payload carries both today.

**Two sorts to NOT introduce**: `cl_name`/`cl_nr` sorting has the same shape as `item_name` (joined column, no index) and would be a third 18-second path.

---

## §7. v2 constraint checklist + horizontal-scalability checklist

### 7.1 v2 constraints

| constraint | status for this change | evidence |
|---|---|---|
| **Jakarta namespace** | `StockrecordView` must `import jakarta.persistence.*`, not `javax` | `StockView.java:3` `import jakarta.persistence.*;` |
| **OSIV** | **OFF**, in main and in both test profiles. A read-only view entity with no lazy associations is unaffected — the repository returns a fully materialized flat entity | `src/main/resources/application.properties:85` `spring.jpa.open-in-view=false`; same line in `src/test/resources/application-integration.properties:31` and `application-postgres-integration.properties:189` |
| **Transaction manager** | Not applicable: SDR reads open their own read-only tx. If any new service method is added it must follow the package rule — bare `@Transactional` means **landlord** in `service`, **tenant** in `repo.jpa` | standing repo rule |
| **`readOnly`** | `ReportService` deliberately runs its exports **outside** a transaction; the reason is recorded in-source and applies verbatim to `exportStockUnitRecord`: *"Not @Transactional: the repository returns a fully materialized list of a flat view entity (no lazy associations), so OSIV-off is a non-issue; wrapping the Excel build + response streaming in a tx would only pin a tenant connection for the whole HTTP response."* (`ReportService.java`, `exporLockReport` javadoc) | do not add `@Transactional` to the export |
| **Caffeine cache invalidation** | **No new cache.** The view is not cached. The shipper dropdown's source already is: `CacheConfig.java:37` `buildCaffeineCache("clients", 100, Duration.ofMinutes(5))`, evicted by `ClientController.java:90/140/159` `@CacheEvict(value = "clients", allEntries = true)`. Nothing to add | — |
| **Micrometer** | No new metric required. Note `wms2.authz.sdr.unruled{domainType=...}` will start counting a new label if `StockrecordView` is exported without an `SdrFunctionRules` entry — expected, not a regression | `SdrFunctionGuard.java` `METRIC_SDR_UNRULED` |
| **`exposeIdsFor`** | **must add `StockrecordView.class`** — see §5.5 | `RestConfiguration.java:884` |
| **`SDR_WRITE_WITHDRAWN`** | should add `StockrecordView.class` | `RestConfiguration.java:508-543` |
| **`ReadOnlyPagingAndSortingRepository`** | use it, and additionally suppress all three `findAll` overloads | `StockViewRepository.java:29-39` |
| **`.gitignore` swallows new `*.properties`** | not applicable — no new properties file | standing repo trap |
| **Hibernate naming strategy** | ⚠ **The tenant persistence unit gets NO naming strategy.** `ReplenishmentMonitorViewSchemaIT`'s javadoc: *"Hibernate falls back to `PhysicalNamingStrategyStandardImpl` — identity — and an unannotated `roId` resolves to the literal column `roId`, which does not exist. That is SBDEV-3247."* **Therefore every camelCase field on `StockrecordView` needs an explicit `@Column(name = "…")`** — exactly as `StockView` does for all eleven of its columns. An unannotated `itemName` resolves to column `itemName` and 500s at runtime. This is the single easiest way to ship a broken entity | `ReplenishmentMonitorViewSchemaIT` javadoc; `StockView.java:12-33` |

### 7.2 H2 — and why the checklist row is mostly moot

**There is no live H2 lane.** `src/test/resources/application.properties` has the H2 datasource **commented out**:
```properties
## database
#spring.datasource.url=jdbc:h2:mem:wms
#spring.jpa.database-platform=org.hibernate.dialect.H2Dialect

spring.datasource.url=jdbc:postgresql://localhost:5432/wms_test
…
spring.jpa.database-platform=org.hibernate.dialect.PostgreSQLDialect
```

So "H2-compatible test SQL" is not a real constraint for this change. The real constraint is the **Testcontainers/Flyway** lane, which is the only place PostgreSQL view DDL can be exercised:

```java
static final String MIGRATION_LOCATION = "classpath:db/migration";
```
(`src/test/java/net/aim_ai/wms/common/extension/AppPostgresDBSetupExtension.java:49`)

Corrected in `db/migration/README.md` (SBDEV-3295): the harness scans `classpath:db/migration` — **not** the onboarding set — as of SBDEV-3239. `test/resources/flyway.conf` still names the onboarding set and **is not read by the ITs**.

### 7.3 Horizontal scalability

| item | verdict |
|---|---|
| new shared mutable state | **none** — the view is read-only, the entity is stateless |
| per-replica cache | `clients` Caffeine cache is JVM-local under `@Profile("!redis")`; a `@CacheEvict` on one replica clears only that replica. **Unchanged by this ticket** — the dropdown already has this property on six other reports |
| connection pinning | the export deliberately runs outside a transaction (§7.1) — keep it that way. A 10,000-row export that pinned a tenant connection for the whole HTTP response would be a pool-slot regression |
| the `CREATE INDEX` write stall | ~6.3 s `SHARE` lock on `stockrecord` per tenant at deploy boot, blocking every stock movement for that window. See §2.4 and §9 Q3 |
| `StartupFlywayMigrator` | runs on **every boot, every tenant**; concurrent replicas serialize on Flyway's per-DB lock. Merging to `develop` **is** a dev deploy and **does** run Flyway |

### 7.4 SDR authorization posture

`SdrFunctionRules` holds **7 rules** (`User`, `UserFunction`, `UserGroup`, `UserGroupUser`, `UserRole`, `Sysprop`, `Message`). **Neither `Stockrecord` nor `StockView` has one**, so both are "unruled" and allowed at `ENFORCE_RULED` — i.e. `/api/stockrecord/search/findByKeyword` is served to any authenticated user today, while `/v3/report/exportStockUnitRecord` requires `WEB_UI_VIEW_STOCK_UNIT_RECORD`.

Adding `StockrecordView` with no rule **preserves that asymmetry exactly**. Adding a rule would *close* a gap but is scope beyond this ticket and would need its own shadow-mode measurement. **Recommend: no rule; note the asymmetry on the ticket** (per the standing policy, a sub-T3 finding goes on the existing ticket).

---

## §8. Testing surface

### 8.1 Lane facts that decide where each test goes

- `*IT.java` **does** run in failsafe, since SBDEV-3239. The pom comment is explicit and corrects the older claim.
- `mvn verify`, not `mvn test`. And: *"LIES: `mvn failsafe:integration-test -Dit.test=<Class>` — the standalone goal reports 'Tests run: 0' + BUILD SUCCESS for ANY class."*
- Running one IT: `mvn verify -Dit.test=<Class> -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false`
- `failsafe.excludedGroups` defaults to `performance` and is **one slot, not a list you append to**.
- `mvn` without `clean` runs **deleted** test classes from stale `target/test-classes`.
- A `-Dtest` selector that matches nothing leaves **stale surefire XML** — you read a verdict for code you never ran. Use `,` not `+`.
- **A Flyway view change HAS a Testcontainers surface, so this change does NOT qualify for the "no Java test surface" gate-skip.**

### 8.2 Concrete test classes per AC

| AC | test | class (new / existing) | lane |
|---|---|---|---|
| **pre-AC** | the view exists after a full `db/migration` migrate, and every `@Column` on `StockrecordView` resolves to a real column of it | **new** `src/test/java/net/aim_ai/wms/integration/schema/StockrecordViewSchemaIT.java`, modelled field-for-field on `ReplenishmentMonitorViewSchemaIT` (which already does exactly this reflection-vs-`information_schema` reconciliation and is the class that would have caught SBDEV-3247) | failsafe (Testcontainers) |
| **pre-AC** | the view **multiplies zero rows** — `count(*)` through the view equals `count(*)` on `stockrecord`, on a fixture containing **at least two clients sharing one `item_nr`** | **new**, same IT | failsafe |
| **pre-AC** | a `stockrecord` row whose `itemdata` string resolves to **no** `itemdata` row still appears, with `item_name IS NULL` (the LEFT-vs-INNER mutant) | **new**, same IT | failsafe |
| **AC-1** | the dropdown renders with "All Shippers" selected by default and is populated from `admin/client/getClients` | **new** `test/components/reports/stockUnitRecordShipperFilter.spec.js` (jest, `yarn test`); nearest existing shapes: `test/components/handlingUnits/shipperSkuFilterBinding.spec.js`, `test/store/handlingUnitsShipperSkuFilter.spec.js` | web-ui jest |
| **AC-2 (rows + totals)** | `findByKeyword(keyword, clientId, pageable)` returns only the selected shipper's rows **and** the correct `page.totalElements` | **new** `StockrecordViewRepositoryFilterIT` (or extend the schema IT) | failsafe |
| **AC-2 (export)** | `ReportController.exportStockUnitRecord` **reads `filter` from `reqMap` and passes it through** | **extend** `src/test/java/net/aim_ai/wms/unit/controller/ReportControllerUnitTest.java` — existing nested class `ExportStockUnitRecord` (:375-460), currently `verify(reportService).exportStockUnitRecord(any(HttpServletResponse.class), eq(0), eq(100), eq("STOCK789"))` | surefire |
| **AC-2 (export query)** | `ReportService.exportStockUnitRecord` forwards the filter to `findByOffsetAndLimit` and builds the same 15 columns | **extend** `src/test/java/net/aim_ai/wms/unit/service/ReportServiceUnitTest.java` — existing nested class `ExportStockUnitRecord` (:415-530) | surefire |
| **AC-3 (row)** | the table row carries `itemName` | covered by the repository IT + the jest spec | both |
| **AC-3 (popup)** | `getStockRecordDetails` puts `itemName` in the map, and leaves it absent/null when the SKU does not resolve | **extend** `src/test/java/net/aim_ai/wms/unit/service/StockrecordServiceUnitTest.java`. The existing method already resolves `Client` the same way, so the shape is established. `ItemdataRepository.findByClientIdAndItemNr(clientId, itemNr)` already exists — no new finder | surefire |
| **AC-4** | keyword + shipper + sort + page compose: 4 combinations, asserting row set **and** `totalElements` | **new**, repository IT | failsafe |
| **AC-4 / regression** | all nine existing sortable columns still resolve as properties of `StockrecordView` — assert by reflection over the header list, not by nine hand-written cases (a prose enumeration rots) | **new**, schema IT | failsafe |
| **authz** | `/v3/client/allClients` lists `WEB_UI_VIEW_STOCK_UNIT_RECORD` | **extend** `src/test/java/net/aim_ai/wms/security/Sbdev3017TrancheGateContextTest.java:665-671` — add the constant to the existing `row(...)` varargs | surefire |
| **authz** | the two `exportStockUnitRecord` pins stay green (`/v3/report/...` **and** `/v3/dashboard/...`) | **existing**, `Sbdev3017TrancheGateContextTest:212-213` — no edit, must not go red | surefire |
| **perf guard** | the unfiltered count plan still eliminates both joins | **manual, documented in the plan, not a test.** An `EXPLAIN`-asserting test is a flake generator. Record §4.1's numbers as the baseline and re-measure once on dev after merge | — |

### 8.3 Mutation checks each new assertion must survive

Per the five-item floor, every new assertion needs its guarded behaviour broken and confirmed red:

| assertion | mutant that must turn it red |
|---|---|
| zero-multiplication | change `LEFT JOIN itemdata i ON i.client_id = sr.client_id AND i.item_nr = sr.itemdata` → `ON i.item_nr = sr.itemdata`. **Requires a fixture with two clients sharing one `item_nr`** — without that row the mutant survives (cf. "mutation fixtures need a row in the dominant band") |
| LEFT vs INNER | `LEFT JOIN` → `JOIN`. **Requires a fixture row whose `itemdata` string resolves to nothing** — on real data that set is empty, so the fixture must construct it |
| column resolution | drop one `@Column(name = "…")` from `StockrecordView` and confirm the schema IT fails, not the app at runtime |
| export filter | make `ReportController` ignore `filter`; the controller unit test must go red |
| `allClients` gate | remove `WEB_UI_VIEW_STOCK_UNIT_RECORD` from the annotation; `Sbdev3017TrancheGateContextTest` must go red |

⚠ Repo traps that apply directly: **repository tests commit, they do not roll back** — assert by id, never `isEmpty()`/`hasSize()`, because a sibling's fixture leaks. And **`@PersistenceContext` with no qualifier is the landlord EM**.

### 8.4 Baseline

Both lanes must be compared against the known-green baseline, not read absolutely. `OutboxConcurrentEnqueueIT` is timing-flaky (SBDEV-3280) and a red `develop` **silently stops deploying**. Counts rot — derive the baseline fresh on the branch point before writing any code.

---

## §9. Open questions

**Q1 — `client_id` or `cl_nr` on the wire? (blocking for P2/P6)**
§4.3 measures `p.cl_nr = :clientNumber` (the `StockView` idiom) at **4,090–4,280 ms** versus **943–987 ms** for `p.client_id = :clientId`. Recommend `clientId` (`item-value="id"` on the `<v-select>`). Cost: the Stock Unit Record report's dropdown then differs from the six sibling reports', which all send `clNr`. Fallback if consistency wins: the scalar-subquery form at **1,554–1,597 ms**. *Decision changes the repository signature, the query-string key, the `<v-select>` binding, and the export's `filter` type (§5.1).*

**Q2 — does AC-2's "Export output" mean filtered-only, or also product name in the spreadsheet?**
The 15 export columns today are all base-table columns, so filtering needs no view. Adding `item_name` to the export changes the spreadsheet's column contract (someone's downstream macro may key on column positions). Recommend: filter only; confirm with the requester.

**Q3 — `CREATE INDEX` vs `CREATE INDEX CONCURRENTLY` for `(client_id, created)`?**
Measured build: **6.3 s / 276 MB** on 9.7 M rows. Plain `CREATE INDEX` inside the Flyway migration takes a `SHARE` lock and stalls every stock movement for that window, per tenant, at deploy boot. `CONCURRENTLY` cannot run inside Flyway's transaction and has no precedent in this repo. Recommend option 1 (accept the ~6 s stall); needs Nam's yes.

**Q4 — is the new SKU Name column sortable?**
`sortable: true` gives every user a one-click **17.9 s** unfiltered query (§4.5), 2.3× the existing worst case. Recommend `sortable: false`. Note there is **no technical enforcement** — a hand-typed `?sort=itemName` reaches JPA regardless — so this is a policy decision to record, not a guarantee.

**Q5 — keep or withdraw `/api/stockrecord/search/findByKeyword` once the UI moves to `stockrecordView`?**
It has **zero Java callers**; its only consumer is `store/reports/stockUnit.js:51`. Leaving it exported keeps an unruled 9.7 M-row SDR search alive with no caller. Withdrawing it (`@RestResource(exported = false)`) is a one-line cleanup — but it is an externally-visible route, so it is a contract change. Recommend withdrawing, but flag it.

**Q6 — is the "0 users blocked" figure in §5.4 good enough?**
It is one tenant (`dev_wh01_om1`) at one instant, with a positive control. I did not measure `wh01_hydra_v2`, `wh01_shipitez_v2` or the other prd tenants. If the answer matters for the rollout order, that is a cheap extra query against the prd MCPs, which **are** in this session's registry.

**Q7 — `V2.2.33` collision re-check timing.**
Established as free by a 40-ref sweep. `db/migration/README.md` requires the sweep to be **re-run immediately before merge**. Whoever merges must run `bash src/main/resources/db/check-migration-version-collision.sh V2.2.33` from the repo root, not trust this document.

---

## §10. Things this bundle did NOT establish

Stated so ralplan does not read absence as evidence.

1. **Measured on one tenant only.** Every number is `dev_wh01_om1`. Row counts, client distribution, recency skew and the plan shapes that follow from them will differ on `wh01_hydra_v2` and `wh01_shipitez_v2`. The **relative** results (join elimination, `client_id` vs `cl_nr`, the composite index) are structural and should port; the absolute milliseconds will not.
2. **Literals, not bind parameters.** See the instrument caveat in §4. The constant-folding win in A2 in particular may not hold on pgjdbc's generic-plan path.
3. **No Hibernate-generated SQL was captured.** §4 reconstructs the query shapes from the JPQL by hand. A `hibernate.SQL` log capture on a running app would be a second instrument, and it was not taken.
4. **`v2/wms2-mobile-ui` was not examined.** The Stock Unit Record report is a web-UI screen; I did not verify the mobile UI has no counterpart.
5. **No `pg_stat_statements` evidence** of how often the unfiltered default page is actually served, so the "is 7.3 s acceptable" question is answered only as "it is the status quo".
6. **I did not run either test suite.** No baseline was taken; §8.4 says it must be.
