# SBDEV-3410 — what Spring Data REST actually puts on the wire for a ZERO-ROW page

**Resolves A-R3-1.** Three rounds of this plan asserted, as fact, that *"`_embedded` is ABSENT, not empty,
when Spring Data REST returns an empty collection"*. Two review lanes agreed — but they **shared one source**:
a single in-repo comment in `wms2-web-ui/store/admin/group.js` (SBDEV-3012) that carries no measurement and
was written about a different endpoint. The round-3 architect read the dependency chain and concluded the
opposite. Neither reading is a measurement, so this is one.

**Date:** 2026-09-18 · **Code:** `v2/wms2-api` `origin/develop = 7ebb9c83` (`git archive`d into a scratchpad
directory — nothing was written into the repo, no branch and no worktree) · **Lane:** the app's own
`*ContextTest` surefire lane, `BaseControllerIntegrationTest` (`@SpringBootTest` + `@AutoConfigureMockMvc`,
`@ActiveProfiles("integration")`, H2 `ddl-auto=create-drop`), so every table is empty by construction and
every route is dispatched through the **real** `RepositoryRestHandlerMapping` with this application's real
`RestConfiguration`. SDR guard mode stubbed `OFF` and `AccessService` stubbed to allow, so no 403 can be
mistaken for a shape.

## VERDICT: `_embedded` is PRESENT with an EMPTY ARRAY. The plan's claim was inverted.

Six routes, four resource kinds, **6 of 6 identical**. `Tests run: 2, Failures: 0, Errors: 0` · `BUILD SUCCESS`.

| # | route | resource kind | status | `_embedded` | `page` block |
|---|---|---|---|---|---|
| A | `/v3/stockrecord/search/findByKeyword?keyword=ZZZNOPE&page=0&size=1` | **paged `@Query` search — the exact shape SBDEV-3410 adds** | 200 | `{"stockrecord": []}` | present, `totalElements: 0` |
| B | `/v3/stockrecord?page=0&size=1` | collection resource | 200 | `{"stockrecord": []}` | present, `totalElements: 0` |
| C | `/v3/pickingorder/search/findByStateAndSectionId?state=0&sectionId=1` | `List`-returning search | 200 | `{"pickingorder": []}` | **absent** |
| D | `/v3/client?page=0&size=1` | collection resource | 200 | `{"client": []}` | present, `totalElements: 0` |
| E | `/v3/userGroup/1/roles` (parent seeded, zero roles) | **association resource — the shape `group.js`'s comment is actually about** | 200 | `{"userRole": []}` | **absent** |
| F | `/v3/userGroupUser/search/findByGrouplistId?grouplistId=1` | `List`-returning search | 200 | `{"userGroupUser": []}` | **absent** |

Probe A verbatim:

```json
{
  "_embedded" : { "stockrecord" : [ ] },
  "_links" : { "self" : { "href" : "http://localhost/v3/stockrecord/search/findByKeyword?keyword=ZZZNOPE&page=0&size=1" } },
  "page" : { "size" : 1, "totalElements" : 0, "totalPages" : 0, "number" : 0 }
}
```

Probe E verbatim (the association resource):

```json
{
  "_embedded" : { "userRole" : [ ] },
  "_links" : { "self" : { "href" : "http://localhost/v3/userGroup/1/roles" } }
}
```

## What this settles, and what it changes

1. **`store/admin/group.js`'s SBDEV-3012 comment is FALSE**, measured on the very shape it describes
   (probe E, an association collection). Its `rowsOf` helper is still correct — the `!embedded → []` arm is
   simply unreachable on this stack, and the `_embedded`-without-the-rel `throw` arm is the live one. Proposed
   as a comment correction in the plan's §10.4.
2. **A zero-row page is NOT a `TypeError`.** `results._embedded.stockrecord` on a zero-row page evaluates to
   `[]`, so the unguarded read in `store/reports/stockUnit.js` does **not** throw, and the "grid keeps the
   previous shipper's rows under a network toast" failure mode both review lanes graded HIGH **is not live**.
   `rowsOf` stays in the plan as the renamed-`collectionResourceRel` detector and as hardening — not as a
   live-defect fix.
3. **The `page` block is emitted only for `Page`-returning resources.** A `List`-returning search has no
   `page` block at all (probes C, E, F), which is why the plan's `countOf` falls back to `0` rather than
   throwing. SBDEV-3410's own routes are all `Page`, so they always carry it.

## Method, and its blind spots

- **Instrument:** two throwaway `*ContextTest` classes in a `git archive` copy of `origin/develop` at
  `7ebb9c83`, run with `mvn -o test -Dtest=<Class> -Dsurefire.failIfNoSpecifiedTests=false`. Each dumps the
  raw `MockMvcResponse` body. Sources and full logs: the scratchpad run recorded in this file; the two test
  classes are reproduced below.
- **Positive control is built in:** all six routes returned **200 with the rel present**, and the rel names
  are the non-default `collectionResourceRel` values (`stockrecord`, `userGroupUser`), so the traversal
  demonstrably reached the real mappings rather than a 404/403 that would have rendered no `_embedded` at all.
  A broken instrument here would show a non-200 or a missing `_links.self`, and neither occurred.
- **Blind spot 1 — this is H2, not PostgreSQL.** Irrelevant to the question: HAL serialisation happens above
  JDBC, and the shape is produced by `PagedResourcesAssembler.toEmptyModel` → `EmbeddedWrappers.emptyCollectionOf`
  → `HalEmbeddedBuilder`, none of which sees the database. The database decides only that the result is empty.
- **Blind spot 2 — this is MockMvc, not a deployed server.** Same application context, same `RestConfiguration`,
  same `spring-data-rest-webmvc 4.5.7` / `spring-data-commons 3.5.7` / `spring-hateoas 2.5.1`. A deployed
  server could differ only through a bean this build does not have; `git grep 'HalConfiguration\|LinkRelationProvider\|RelProvider'
  origin/develop -- src/main` returns **0** (positive control: `exposeIdsFor` → 2 hits in the same tree).
- **Blind spot 3 — `stockrecordView` does not exist yet**, so probe A used `stockrecord`'s `findByKeyword`,
  which is the same `Page<Entity>` + `@Query` + `@RestResource` construct on the same repository family. The
  shape is a property of the assembler, not of the domain type.
- **Not measured:** an `Optional`-returning search (SDR answers 404, a different branch), and a projection
  collection (500 on this stack — `SdrNonEntityCollectionSearchNotExportedContextTest`).

## The probe classes

```java
// src/test/java/net/aim_ai/wms/security/ZzzEmbeddedShapeProbeContextTest.java  (probes A–D)
class ZzzEmbeddedShapeProbeContextTest extends BaseControllerIntegrationTest {
    @MockitoBean private SdrGuardModeProvider modeProvider;
    @MockitoBean private AccessService accessService;

    @BeforeEach void allowEverything() {
        when(modeProvider.current()).thenReturn(SdrGuardMode.OFF);
        when(accessService.checkAnyAccess(anyString(), any(String[].class))).thenReturn(AccessDecision.allow());
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken("sbtest", "n/a", Collections.emptyList()));
    }

    private void dump(String label, String url) throws Exception {
        var res = mockMvc.perform(get(url)).andReturn().getResponse();
        System.out.println("### PROBE " + label + " STATUS=" + res.getStatus()
                         + " BODY=" + res.getContentAsString());
    }

    @Test void probeZeroRowShapes() throws Exception {
        dump("A", "/v3/stockrecord/search/findByKeyword?keyword=ZZZNOPE&page=0&size=1");
        dump("B", "/v3/stockrecord?page=0&size=1");
        dump("C", "/v3/pickingorder/search/findByStateAndSectionId?state=0&sectionId=1");
        dump("D", "/v3/client?page=0&size=1");
    }
}
```

```java
// src/test/java/net/aim_ai/wms/security/ZzzAssocShapeProbeContextTest.java  (probes E–F)
// same @MockitoBean / @BeforeEach as above, plus:
@PersistenceContext(unitName = "tenant") private EntityManager tenantEm;

@Test void probeAssociationZeroRows() throws Exception {
    UserGroup g = new UserGroup();
    g.setName("zzz-probe"); g.setNumber("ZZZ1"); g.setClientId(0L);
    tenantEm.persist(g); tenantEm.flush();
    dump("E", "/v3/userGroup/" + g.getId() + "/roles");
    dump("F", "/v3/userGroupUser/search/findByGrouplistId?grouplistId=" + g.getId());
}
```
