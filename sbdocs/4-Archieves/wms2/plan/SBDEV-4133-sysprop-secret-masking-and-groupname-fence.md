---
title: "SBDEV-4133 slice 1 — Sysprop secret masking on every HTTP read + groupname/syskey fence on SDR PUT"
ticket: "SBDEV-4133"
ticket_url: "https://app.clickup.com/t/868mvmaag"
type: "bugfix"
priority: "high"
status: "archived"
project: [wms2]
version: "v2"
tier: T3
db_verified: true
requester: "Nam Park"
created: "2026-11-14"
updated: 2026-11-14
branch: "feature/SBDEV-4133-sysprop-secret-masking"
related:
  - "[[wms2-sysprop-catalog]]"
  - "[[wms2-function-to-docs-map]]"
  - "[[wms2-caching-strategy]]"
  - "[[SBDEV-3169-sdr-read-gating]]"
tags: [plan, security, sysprop, sdr, authz]
---
# SBDEV-4133 slice 1 — Sysprop secret masking + groupname/syskey fence

**Ticket:** [SBDEV-4133](https://app.clickup.com/t/868mvmaag) · **Tier:** T3 (credential exposure / authz) · **Base:** `v2/wms2-api` `origin/develop` @ `9f041590`
**Slice:** AC-1..AC-3 only. OUT: AC-4..6 (MD5 password migration, Keycloak rotation), register P98 (rotate live CUPS passwords), P99 (delete dead `WMS_LOGIN_SECRET` / `KEYCLOAK_API_USER`), P100 (HttpRestService Basic auth only to an allow-listed OMS host).
**Evidence (cited A§x):** `/Users/np1076/dev/spk/owl/.omc/research/SBDEV-4133-slice1-analysis.md`. Snippets re-read with `git show origin/develop:<path>`. Round-1 reviews: critic ITERATE, architect SOUND-WITH-CHANGES — all findings applied (changelog at end).

## RALPLAN-DR summary (mode: SHORT — T3, one round)

**Principles**
1. Key the secret decision on `syskey` — explicit list OR `SensitiveMapRedactor.isSensitive(syskey)` — never on `groupname`, and make `syskey`/`groupname` immutable over SDR PUT so the key the decision reads cannot be moved.
2. Mask at the serialization edge, never in `Sysprop.getSysvalue()` — `PrinterController.printLabel`, `HttpRestService` and the `sysprops` cache need the raw value.
3. The mask sentinel is never persisted; a write carrying it is refused, not "kept".
4. Before-hooks compare against the **committed** row (native read, own read-only tenant tx), never the SDR-merged instance.
5. Fail closed: unknown owner on serialization → mask; committed row missing on save → refuse.

**Decision drivers (top 3)**
1. Audience: SDR `GET /v3/sysprop/search/findByGroupname?groupName=Backend` needs only a login while `SdrFunctionGuard` is OFF on PRD (SBDEV-4131) — wider than the function-gated MVC route.
2. Round-trip safety: the web-ui edit dialog GETs a row over SDR and PUTs the whole body back (`editParamAndConfig.vue` `putIfMatch('/sysprop/{id}', writableBody(item), etag)`); a design that drops or nulls `sysvalue` on inbound bind silently wipes values.
3. Smallest construct covering the most routes: one entity-level construct reaches R2–R5 (§0) across MVC and SDR.

**Viable options — masking mechanism**
| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **A. Field-level `@JsonSerialize(using = SysvalueMaskingSerializer)` reading the owner via `JsonGenerator.currentValue()`** | Serialization only; property definition, setter and SDR merge untouched; no ObjectMapper registration | Relies on Jackson assigning the current value on SDR's path — library evidence below, pinned by the step-2 first IT | **Chosen** |
| B. `@JsonIgnore getSysvalue()` + `@JsonGetter`/`@JsonSetter("sysvalue")` split (A§4) | Pure annotations | Rewrites the property definition SDR uses to map PUT JSON → persistent property; a mis-split nulls `sysvalue` on every UI save (`User.password` WRITE_ONLY trap) | Fallback if the step-2 IT fails |
| C. `BeanSerializerModifier` module | Property definition untouched | Two homes (Boot mapper **and** SDR `configureJacksonObjectMapper`); missing one leaves a route open | Rejected |
| D. SDR `RepresentationModelProcessor<EntityModel<Sysprop>>` | SDR-native | Misses MVC `updateClient`/`create`/`updateValue` echoes; mutates the entity it is handed | Rejected |
| E. Per-route DTO masking only (MVC) | Smallest diff | Leaves R4/R5 (any `wms_user` on PRD) open — Nam rejected (§10 R1) | Rejected |

**Option A library evidence (architect, round 1):** jackson-databind 2.19.4 `BeanSerializer.serialize` and `UnwrappingBeanSerializer.serialize` both call `gen.assignCurrentValue(bean)` before writing fields; Spring HATEOAS 2.5.1 renders `EntityModel` content through the unwrapping serializer; SDR 4.5.7 `DomainObjectReader.readPut` binds through the **deserialization** config, which a `@JsonSerialize` never touches.

## 0. Affected sites

Enumeration: A§0 (`git grep` over `controller/**` for `Sysprop|getSysvalue(|findSysvalue|findByGroupname|getSystemByGroupname`, plus `setSysvalue(|setGroupname(|syspropRepository.save` over `src/main`). **Blind spot:** raw `los_sysprop` SQL in other repositories' `@Query` was not grepped; no `@Projection` for Sysprop exists.

| # | Site | Construct | In scope | Fix |
|---|---|---|---|---|
| R1 | `SystemController.searchSystemByGroupname` → `SyspropService.getSystemByGroupname`: `dto.put("sysvalue", result.getSysvalue());` | MVC, native projection → Map | yes (AC-1) | C |
| R2 | `SystemPropertyController.updateClient`: `sysProp = syspropRepository.save(sysProp); return ResponseEntity.ok(sysProp);` — any id | MVC read oracle (JSON; XML is unreachable — `produces = "application/json"` on `/updateClient`, `/create`, `/updateValue` → 406) | yes | B |
| R3 | `createSystemProperty` / `updateValue` `return ResponseEntity.ok(sysProp);` | MVC echo | yes, free | B |
| R4 | SDR `GET /v3/sysprop`, `/v3/sysprop/{id}`; 200 body of SDR PUT | SDR entity | yes | B |
| R5 | SDR searches `findBySyskey`, `findByGroupname`, `findBySyskeyContaining`, `findBySyskeyAndClientIdAndWorkstation`, `findBySyskeyAndClientId`, `findByClientId` | SDR entity | yes | B |
| R6 | SDR scalar searches `findSysvalueBySyskey`, `findSysvalueByClientIdAndSyskey` (`String`, bypasses any entity mask) | SDR scalar | yes | E (`exported = false`; 0 client callers, A§2) |
| R7 | `getSystemByGroupname` repo method | already `exported = false` | no | — |
| R8 | `printLabel`, `mobileUiUrl`, internal `getSysvalue` readers | internal / fixed public key | no — must stay raw (Principle 2) | — |
| W1 | SDR `PUT /v3/sysprop/{id}` — the **only** path that can change an existing row's `groupname`/`syskey` | SDR write | yes (AC-3) | D |
| W2/W3 | SDR `PATCH` (405, SBDEV-3157) / collection `POST` (withdrawn) | — | pinned by test only | — |
| W4 | SDR `DELETE` | cannot leak (re-create needs the value) | no | — |
| W5/W6 | MVC `/create`, `/updateValue` — can carry a sysvalue | MVC write | yes (sentinel refusal) | D2 |
| W7 | MVC `/updateClient` — client_id only | — | response only (R2) | B |
| X1 | **Indirect exfiltration:** PUT a `WEBSERVICE_*_URL` sysprop to an attacker host → `HttpRestService` sends `OMS_API_USER` there (`headers.setBasicAuth(apiUser[0], apiUser[1])`; URLs via `syspropService.getSysvalue(...WEBSERVICE_..._URL_KEY)` in `BolOmsNotificationService` / `CustomerorderBatchService`) | write → outbound | **excluded** — needs an outbound allow-list (P100, T3); residual risk §9 | — |
| X2 | **Integrity:** PUT a new `OMS_API_USER` value | SDR write | **excluded** — authz problem (SBDEV-4131 guard + role), not exposure | — |
| L1 | DEBUG of new values: `SyspropService.createSystemProperty` `LOG.debug("called with ... value={} ...")`; `SystemPropertyController` `LOG.debug("create system property /{}", reqMap.toString())` and `"update system property value/{}"` | log leak | yes (Nam #4c) | F |

## 1. Problem

On every tenant measured, three credential-bearing keys sit in group `Backend`, and `CUPS_SERVER_ADDRESS_PASSWORD` is still live in `System Settings` on PRD tenants that have not run V2.2.52:
- **dev_wh01_om1** (`los_sysprop`, 164 rows): Backend 48, Labels 9, Warehouse Details 15, System Settings 25; `OMS_API_USER`, `WMS_LOGIN_SECRET`, `KEYCLOAK_API_USER` in Backend, one row each (DEFAULT / client 0); CUPS row 0 (V2.2.52 applied); 1 default INBOUND printer.
- **PRD (read-only, 2026-11-13):** all 3 keys in Backend on `wh01_hydra_v2`, `wh02_shipitez_v2`, `wh01_shipitez_v2`; `CUPS_SERVER_ADDRESS_PASSWORD` non-blank there (System Settings). **WineCo PRD not measured** — `wsl-wineco-prd` MCP failed to connect.
- **`isSensitive` census (coordinator, exact 12-fragment normalisation):** on the 3 PRDs it matches only `WMS_LOGIN_SECRET` (Backend) + `CUPS_SERVER_ADDRESS_PASSWORD` (System Settings), both already listed; on dev only `WMS_LOGIN_SECRET` (positive control). So the OR widens nothing today. Evidence, not a prerequisite.

Symptoms: (1) `GET /v3/system/searchSystemByGroupname/Backend` returns `OMS_API_USER` (live HTTP Basic credential) in clear to any `WEB_UI_VIEW_SYSTEM_PROPERTY` holder; web-ui's System Settings tab shows the CUPS password on PRD today. (2) The same data comes back from SDR to **any** authenticated `wms_user` while the SDR guard is OFF. (3) An SDR PUT can set a secret row's `groupname` to `Labels`, after which `GET /v3/printer/printLabel/{key}` passes the SBDEV-4123 check (`GROUP_LABELS.equals(labelRow.getGroupname())`) and prints it.

## 2. Root cause

- **Bug 1 (AC-1):** no secret concept at any read edge. `getSystemByGroupname` copies `result.getSysvalue()` verbatim; `Sysprop.sysvalue` is a plain Jackson property; two SDR searches return the bare column.
- **Bug 2 (AC-2 precondition):** the UI PUTs the GET body unchanged, so a mask without a write-side rule would overwrite the real secret with the sentinel.
- **Bug 3 (AC-3):** SBDEV-4123 fenced `printLabel` on the **stored** `groupname`, but nothing fences writes to `groupname` or `syskey`. `PutawayConfigRepositoryEventHandler.onBeforeSave(Sysprop)` only refuses security-guard syskeys and putaway deltas (it stays as a second line for putaway renames).
- **Bug 4 (fold-in):** new values (incl. secrets) logged at DEBUG (enabled in prod per SBDEV-3080).

## 4. Architecture overview

```
read:  MVC /v3/system/searchSystemByGroupname ─► SyspropService.getSystemByGroupname ─► SyspropSecrets.mask(syskey, v)   [Fix C]
       MVC /v3/systemProperty/{create,updateValue,updateClient} ─┐
       SDR /v3/sysprop, /{id}, /search/find*, PUT 200 body ──────┴► Jackson (JSON)     ─► SysvalueMaskingSerializer       [Fix B]
       SDR /search/findSysvalue* (String) ─► 404, exported=false                                                        [Fix E]
write: SDR PUT /v3/sysprop/{id} ─► @HandleBeforeSave SyspropWriteFenceEventHandler (HIGHEST_PRECEDENCE)
          └► SyspropService.readCommittedKeyAndGroup(id) (native, own readOnly tenant tx) ─► refuse 422 or continue      [Fix D]
          └► PutawayConfigRepositoryEventHandler.onBeforeSave (unchanged) ─► save ─► SdrCacheEvictionEventHandler
       MVC /create, /updateValue ─► SyspropSecrets.refuseMaskSentinel(value) ─► 422                                     [Fix D2]
```

| File (`src/main/java/net/aim_ai/wms/…`) | Role |
|---|---|
| `service/WmsConstants.java` (`SystemProperty`) | home of `SECRET_SYSKEYS` |
| `util/SyspropSecrets.java` (new, same package as `SensitiveMapRedactor`) | `isSecret`, `mask`, `refuseMaskSentinel`, public `MASK` |
| `model/Sysprop.java`, `model/SysvalueMaskingSerializer.java` (new) | entity mask |
| `service/SyspropService.java` | R1 mask, committed read, log fixes |
| `config/SyspropWriteFenceEventHandler.java` (new) | AC-3 + sentinel fence |
| `exceptions/SyspropWriteRefusedException.java` (new), `exceptions/RestExceptionHandler.java` | 422 mapping (added) |
| `repo/jpa/SyspropRepository.java` | R6 withdrawal |
| `controller/SystemPropertyController.java` | sentinel refusal on W5/W6, log fix |

## 5. Fix design

### Fix A — one secret rule, one home
`WmsConstants.SystemProperty`: `public static final Set<String> SECRET_SYSKEYS = Set.of(SYSTEM_PROPERTY_OMS_API_USER_KEY, SYSTEM_PROPERTY_WMS_LOGIN_SECRET_KEY, SYSTEM_PROPERTY_KEYCLOAK_API_USER_KEY, "CUPS_SERVER_ADDRESS_PASSWORD");` (CUPS constant deleted by SBDEV-4125; javadoc: keep until V2.2.52 is on every tenant).
`util.SyspropSecrets` (same package as `SensitiveMapRedactor`, so its package-private `isSensitive` and `MASK` are callable **without widening their visibility**): `public static final String MASK = SensitiveMapRedactor.MASK;` · `isSecret(k)` = `k != null && (SECRET_SYSKEYS.contains(k) || SensitiveMapRedactor.isSensitive(k))` (§10 R5) · `mask(k, v)` = `v == null ? null : isSecret(k) ? MASK : v` · `refuseMaskSentinel(v)` throws `SyspropWriteRefusedException` when `MASK.equals(v)`.
*Why the list is still required:* `isSensitive` alone misses `OMS_API_USER`/`KEYCLOAK_API_USER` (normalised names carry no fragment, A§3); the OR is a fail-safe for future `*_PASSWORD`/`*_TOKEN` keys.

### Fix B — entity serialization mask (Option A)
Before: `@Column(columnDefinition = "text") private String sysvalue;` with plain getter/setter.
After:
```java
@Column(columnDefinition = "text")
@JsonSerialize(using = SysvalueMaskingSerializer.class)   // serialization ONLY; setter + SDR readPut untouched
private String sysvalue;
// getSysvalue()/setSysvalue() unchanged — Java callers (printLabel, HttpRestService, cache) see the raw value
```
```java
public final class SysvalueMaskingSerializer extends StdSerializer<String> {
    public SysvalueMaskingSerializer() { super(String.class); }          // no-arg ctor: Jackson instantiates it
    @Override public void serialize(String value, JsonGenerator gen, SerializerProvider p) throws IOException {
        Object owner = gen.currentValue();               // the Sysprop (assignCurrentValue in BeanSerializer/Unwrapping)
        gen.writeString(owner instanceof Sysprop s ? SyspropSecrets.mask(s.getSyskey(), value) : SyspropSecrets.MASK); // fail closed
    }
}
```
Null `sysvalue` never reaches the serializer → stays `null`. Applies to every Jackson mapper that serializes `Sysprop` (the MVC routes are `produces = "application/json"`, so XML is not reachable there). If the fail-closed branch ever fires for a non-secret, the UI echo is refused by Fix D (never stored) and AC-3 goes red. **Step 2 opens with a one-case IT proving `currentValue()` is the Sysprop on SDR item + search; red → switch to Option B** (tests are mechanism-agnostic).
*Why not WRITE_ONLY:* `User.java` javadoc — "PUT would null the column"; Sysprop PUT is live.

### Fix C — R1 DTO mask
Before: `dto.put("sysvalue", result.getSysvalue());` After: `dto.put("sysvalue", SyspropSecrets.mask(result.getSyskey(), result.getSysvalue()));`. `totalElements` and row count unchanged.

### Fix D — `SyspropWriteFenceEventHandler` (AC-2 write side + AC-3)
```java
@Component @RepositoryEventHandler
public class SyspropWriteFenceEventHandler {
    private final SyspropService syspropService;                       // constructor injection
    @Order(Ordered.HIGHEST_PRECEDENCE)                                  // per-method, as SdrCacheEvictionEventHandler
    @HandleBeforeSave
    public void onBeforeSave(Sysprop incoming) {
        SyspropService.KeyAndGroup committed = syspropService.readCommittedKeyAndGroup(incoming.getId())
            .orElseThrow(() -> new SyspropWriteRefusedException("System property not found"));          // fail closed
        if (!Objects.equals(committed.groupname(), incoming.getGroupname()))                                  // incl. null/omitted
            throw new SyspropWriteRefusedException("The group of an existing system property cannot be changed");
        if (!Objects.equals(committed.syskey(), incoming.getSyskey()))                                        // ANY rename (§10 R6)
            throw new SyspropWriteRefusedException("The key of an existing system property cannot be changed");
        SyspropSecrets.refuseMaskSentinel(incoming.getSysvalue());   // "Value is masked; type the new value to change it"
    }
}
```
`SyspropService.readCommittedKeyAndGroup(Long id)`: `@Transactional(value = "tenantTransactionManager", readOnly = true)`, `createNativeQuery("select syskey, groupname from los_sysprop where id = ?1")`, `getResultList()` → `Optional<KeyAndGroup>` — copied from `PutawayConfigService.readCommittedIdentity` ("Spring Data REST has already merged the payload into a detached instance by the time the hook fires"). EntityManager via **field** injection `@PersistenceContext(unitName = "tenant") private EntityManager entityManager;` — a constructor change would break `new SyspropService(...)` in `CacheEvictionOnWriteUnitTest` / `SdrCacheEvictionUnitTest`, and a bare `@PersistenceContext` binds the landlord unit. Lives in the service, **not** a derived repo method (auto-exported). Rows with stored `null` group (5 on dev) still save when the PUT echoes `null`.
`SyspropWriteRefusedException` is a **direct** `RuntimeException` subclass (an `IllegalArgumentException` subclass would be turned into 400 by SDR). `RestExceptionHandler` (`@Order(0)`) gets a **new** `@ExceptionHandler(SyspropWriteRefusedException.class)` → 422 `ProblemDetail`, title "Business Rule Violation", `retryable:false` (same shape as `handlePutawayConfigValidation`); `LOG.warn("Sysprop write refused: {}", ex.getMessage())` — message never carries a value.
*Why not `BusinessException`:* checked → 500 from a reflective handler (`PutawayConfigValidationException` javadoc). *Why a new bean, not the putaway handler:* scope argument in `SdrCacheEvictionEventHandler`'s javadoc; `PutawayConfigRepositoryEventHandler`'s own warning says a second handler needs its own firing evidence — the real-SDR ITs AC-5/AC-7 are that evidence.
**Fix D2:** `createSystemProperty` and `updateValue` call `SyspropSecrets.refuseMaskSentinel((String) reqMap.get("value"))` next to `rejectGuardedPutawayKey(...)`.

### Fix E — withdraw the scalar searches
Add `exported = false` to `@RestResource(path = "findSysvalueBySyskey", …)` and `findSysvalueByClientIdAndSyskey`. `SyspropService.getSysvalue` keeps calling it in-process. 0 callers in web-ui, mobile-ui, oms-laravel-api (A§2; blind spot: variable-built URLs, mitigated by the `/sysprop` fragment grep).

### Fix F — stop logging new values
`SystemPropertyController`: `LOG.debug("create system property /{}", reqMap.toString())` → `LOG.debug("create system property key={}", reqMap.get("key"))`; same for `updateValue`. `SyspropService.createSystemProperty`: drop `value={}` and its argument. Same commit: fix `getStringDefault`'s `LOG.debug("end with client={} workstation={} key={} defaultValue={}", client, workstation, key, defaultValue, value)` (5 args / 4 placeholders) — drop `value`; also drop `defaultValue` from both the start log (`LOG.debug("start with client={} workstation={} key={} defaultValue={}", …)`) and the end log, since `defaultValue` may be a secret seed.

## 6. File change summary
| File | Change |
|---|---|
| `WmsConstants` | `+SECRET_SYSKEYS` |
| `util/SyspropSecrets` (new) | ~35 lines |
| `model/Sysprop`, `model/SysvalueMaskingSerializer` (new) | 1 annotation, ~20 lines |
| `service/SyspropService` | R1 mask, `readCommittedKeyAndGroup` + `KeyAndGroup` record, `@PersistenceContext(unitName="tenant")` field, 2 log lines |
| `config/SyspropWriteFenceEventHandler` (new) | ~40 lines |
| `exceptions/SyspropWriteRefusedException` (new), `RestExceptionHandler` | new 422 handler |
| `repo/jpa/SyspropRepository` | 2× `exported = false` |
| `controller/SystemPropertyController` | 2 sentinel calls, 2 log lines |
| sbdocs: `wms2-sysprop-catalog.md` (4 key rows + "masked on every HTTP read"), `wms2-function-to-docs-map.md` §9 | docs |

## 7. Implementation steps

### 7.1 Prerequisites
| # | Item | Status |
|---|---|---|
| 1 | Scope vs SBDEV-4131 | Ship independently. Slice 1 closes the **read** exposure only. A user who can PUT sysprops (guard OFF: any `wms_user`; guard ON: still `SYSTEM_PROPERTY_VIEW`-class) can still redirect `OMS_API_USER` via a `WEBSERVICE_*_URL` rewrite (X1) or overwrite it (X2). Residual → P100 + 4131 |
| 2 | web-ui impact | None for Backend. Pre-V2.2.52 tenants: CUPS row shows the sentinel; editing it gets 422 (dead config). No web-ui change |
| 3 | `sysprops` cache | No change: mask is never applied to the cached String; a refused PUT throws Before-save so eviction never runs |
| 4 | Flyway | None |
| 5 | ETag / `If-Match` (SBDEV-4032/4046) | `@Version` unchanged; IT asserts `ETag` on GET |
| 6 | Ticket lease | `.claude/scripts/ticket-lease.sh claim SBDEV-4133` before the worktree |

### 7.2 Steps (one commit each)
1. Fix A + E + F with unit tests.
2. **First:** `SysvalueMaskingCurrentValueIT` one-case proof (SDR item + search mask a seeded secret) — decides A vs B. Then Fix B + C with unit + IT read cases.
3. Fix D + D2 with unit, registration and IT write cases.
4. Docs; rails (`*ArchTest`, `TenantCacheKeyUnitTest`, `*Contract*`, `SdrFunctionRulesUnitTest`, `SecurityConfigurationTest`) then full suite vs baseline.

## 8. Testing plan

**Unit** (`src/test/java/net/aim_ai/wms/unit/…`)
- `util/SyspropSecretsUnitTest`: `secretSyskeys_shouldEqualTheFourTicketKeys` (literal list), `mask_shouldMaskEachSecretKey` (`@ParameterizedTest`, literal four), `isSecret_shouldMatchFragmentOnlyKey` (`FOO_PASSWORD`), `isSecret_shouldNotMatchPlainKey` (`API_TIMESTAMP_FORMAT`), `mask_shouldKeepNull`, `refuseMaskSentinel_shouldThrowOnSentinel`.
- `service/SyspropServiceUnitTest` `@Nested GetSystemByGroupname`: `shouldMaskEverySecretKeyInAnyGroup`, `shouldNotMaskNonSecret`, `shouldKeepTotalElements`.
- `model/SysvalueMaskingSerializerUnitTest`: `serialize_shouldMaskSecret`, `serialize_shouldNotMaskNonSecret`, `deserialize_shouldBindSysvalue`.
- `config/SyspropWriteFenceEventHandlerUnitTest`: `shouldRefuseGroupChangeToLabels`, `shouldRefuseNullGroupWhenStoredNonNull`, `shouldAllowUnchangedGroup`, `shouldAllowNullWhenStoredNull`, `shouldFailClosedWhenRowMissing`, `shouldRefuseAnyRename`, `shouldAllowUnchangedSyskey`, `shouldRefuseMaskSentinel`.
- `config/SyspropWriteFenceRegistrationUnitTest` (real `AnnotatedEventHandlerInvoker`): `fence_shouldRunBeforePutawayHandlerAndAbortIt`.
- `controller/SystemPropertyControllerUnitTest`: `updateValue_shouldRefuseMaskSentinel`, `create_shouldRefuseMaskSentinel`.

**Integration** — `integration/controller/SyspropSecretMaskingIntegrationTest` (template `SyspropLegacyTimestampRoundTripIntegrationTest`: `BaseRollbackIntegrationTest` + `@AutoConfigureMockMvc`, `@MockitoBean SdrGuardModeProvider` (OFF), `AccessService`, `PrintService`). Seeds use **real** secret key names at `workstation = "IT-" + RUN_ID`, committed via `TransactionTemplate(tenantTransactionManager)`. **Shared-state:** these rows are visible to sibling ITs, and `updateValue` resolves `findBySyskey(key).get(0)` — so `@AfterEach` deletes seeds and restores the Flyway rows' `syskey`/`groupname`/`sysvalue` by native update; the class is `@Execution(SAME_THREAD)` and must not run concurrently with sysprop-reading ITs. The printLabel case seeds a default INBOUND printer so `never()` is meaningful. RestConfiguration `setReturnBodyForPutAndPost(true)` is asserted, not assumed.

**Acceptance criteria → tests (each mutation-checked by the gate)**
1. **AC-1 MVC:** `searchSystemByGroupname_shouldMaskEverySecretKey` — all 4 keys seeded in group `Backend` (`CUPS_SERVER_ADDRESS_PASSWORD` is absent from the IT DB after V2.2.52, so it must be seeded); each shows the sentinel, seeded raw value absent. *Mutant:* revert Fix C → red naming syskey + route.
2. **AC-1 SDR:** `sdrGetById_shouldMaskEverySecretKey`, `sdrFindByGroupname_shouldMaskEverySecretKey` (+ `ETag` present). *Mutant:* remove `@JsonSerialize` → red naming key + route.
3. **Positive control:** `nonSecretRow_shouldRoundTripUnmasked` on all read routes incl. `updateClient`. *Mutant:* `mask` always returns sentinel → red naming the non-secret key.
4. **R2:** `updateClient_responseShouldMaskSecret` (JSON). Pin: `updateClient_xmlAccept_shouldBe406` (passes before and after; documents that XML is unreachable). *Mutant:* remove `@JsonSerialize` → red naming `updateClient`.
5. **AC-2 refusal:** `putOfGetBody_forSecret_shouldBe422AndValueUnchanged` — GET → PUT unchanged → 422; stored value equals seed. Assertion message for the stored check: **"sysvalue nulled by echo PUT"** when null, "stored sysvalue overwritten with mask" when sentinel. *Mutants:* delete `refuseMaskSentinel` → red (sentinel); `@JsonProperty(access = WRITE_ONLY)` → GET has no `sysvalue`, echo PUT 200 nulls it → red ("sysvalue nulled by echo PUT"). This test is the one that kills WRITE_ONLY.
6. **AC-2 edit works:** `putNewValue_forSecret_shouldBe200AndPersist` — stored == new value **and** the 200 body shows the sentinel, not the new value; `putOfGetBody_forNonSecret_shouldBe200` — stored == seed (separate assertions). *Mutants:* fence refuses every PUT of a secret row (`isSecret(committed.syskey())` → throw) → red "secret edit refused"; serializer skipped on the PUT response → red naming the leaked 200 body.
7. **AC-3:** `putGroupToLabels_shouldBe422AndGroupUnchanged`, `putOmittingGroup_shouldBe422`, `putUnchangedGroup_shouldBe200`, `putRenamingNonSecretSyskey_shouldBe422AndKeyUnchanged`. *Mutants:* drop the groupname compare → red naming stored groupname `Labels`; drop the syskey compare → red naming the renamed key.
8. **R6:** `findSysvalueBySyskey_shouldBe404`, `findSysvalueByClientIdAndSyskey_shouldBe404`, each with in-test positive control `findBySyskey` → 200 under the same auth/guard. Gate records the pre-fix 200 of `findSysvalueBySyskey`. *Mutant:* remove `exported = false` → 200 → red naming the path.
9. **SBDEV-4123 e2e:** `groupMoveThenPrintLabel_shouldNotPrintSecret` — targets the **Flyway** `OMS_API_USER` row at workstation `DEFAULT` / system client (the row `PrinterController` resolves via `syspropService.getByKey(null, null, labelKey)`), NOT an `IT-` seed; precondition assertion: `getByKey(null, null, "OMS_API_USER").getId()` equals the id being PUT; `@AfterEach` restores its `groupname`. PUT group → `Labels` (422), then `GET /v3/printer/printLabel/OMS_API_USER` → "Unknown label", `printService.cupsPrintChecked` `never()` with a default INBOUND printer seeded. *Mutant:* drop fence → print invoked → red.
10. **Secret-list OR:** `isSecret_shouldMatchFragmentOnlyKey`. *Mutant:* drop the `|| isSensitive` → red naming `FOO_PASSWORD`.
11. **Pin:** `patch_shouldStay405` (SBDEV-3157).

**Manual test (dev, `wms-dev-probe`, `snapshot.sh` restore proof).** Never select a secret's `sysvalue`; compare `md5(sysvalue)` only. **Abort on failed precondition:** each step runs only if the prior step returned the expected status AND a DB check confirms `syskey`/`groupname`/md5 unchanged (2026-11-13: a failed flag flip sent a real label to SB1-TestLabel1). No manual step calls `printLabel` (dev has 1 default INBOUND printer; AC-9 IT covers it).
| Scenario | Env | Precondition query → dev count | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| M1 MVC mask | dev | Backend rows with secret key → 3 | GET `/v3/system/searchSystemByGroupname/Backend` | 48 rows; 3 show sentinel; `API_TIMESTAMP_FORMAT` raw || ✅ 2026-11-15: 48 rows, 3 masked, 0 non-secret masked, API_TIMESTAMP_FORMAT raw |
| M2 SDR mask | dev | same → 3 | GET `/v3/sysprop/search/findByGroupname?groupName=Backend` | sentinel on 3 rows || ✅ 48 rows, 3 masked; SDR item /133 masked too |
| M3 scalar withdrawn | dev | — | GET `/v3/sysprop/search/findSysvalueBySyskey?syskey=OMS_API_USER` | 404 || ✅ both searches 404; /search index still 200 and lists the other 6 |
| M4 echo refused | dev | rows storing sentinel → 0; record `md5(sysvalue)` of WMS_LOGIN_SECRET (dead key, P99 — never PUT the live OMS_API_USER on dev) | GET `/v3/sysprop/{id}`, PUT body back with `If-Match` | 422; md5 identical, else **abort + restore** || ✅ 422 "Value is masked…"; md5 + version unchanged |
| M5 group move | dev | Labels rows with secret key → 0; Labels total → 9 | PUT WMS_LOGIN_SECRET row with `groupname:"Labels"` | 422; counts 0 / 9; md5 unchanged || ✅ 422 "The group … cannot be changed" (group check runs before the mask check); 0 / 9; md5 unchanged |
| M6 Labels edit | dev | Labels rows with content → 9 | web-ui Admin → Labels → edit a description, save | 200, value unchanged, ETag advances || ✅ API replay of web-ui (GET ETag → PUT minus _links, If-Match): 200, ETag 0→1; reverted |
| M7 Warehouse Details | dev | Warehouse Details rows → 15 (0 secret) | web-ui Warehouse Details, change 2 rows, save (`configuration.js` per-row PUT) | 200 each; only changed rows modified || ✅ rows 105, 106: 200 each, ETag 6→7; neighbours 104/107 untouched; reverted |
| M8 System Settings | dev | System Settings rows → 25 (0 secret) | web-ui System Settings → edit one row via `editParamAndConfig.vue` | 200, value persisted || ✅ row 30262742 (test3): 200, value persisted, ETag 0→1; reverted |

## 9. Risks
1. **`currentValue()` not the Sysprop on SDR's path** → fail-closed masks all, UI edits refused (no corruption). Library evidence says it is set; step-2 first IT decides; fallback Option B.
2. **Committed read joins the request PC** → fence sees merged values. Own `readOnly` tenant tx + OSIV off (putaway precedent); AC-7 pins it.
3. **Handler order** — `@Order(HIGHEST_PRECEDENCE)` + registration test.
4. **List drift** — mitigated by the `isSensitive` OR for fragment-named keys; innocuous names still need the list + catalog review.
5. **Residual write-side exfiltration (X1) and integrity (X2)** — slice 1 does not close them; P100 (outbound allow-list, T3) and SBDEV-4131.
6. **IT cross-talk** — committed seeds with real key names; mitigated by the `@AfterEach` restore (no JUnit parallel config exists in `src/test/resources` or `pom.xml`, so `SAME_THREAD` adds nothing).
7. **CUPS row uneditable on pre-V2.2.52 tenants** — accepted. **WineCo PRD unmeasured** — assumed same shape.

**Horizontal scalability:** 1 in-JVM state No (immutable static set) · 2 pool math No (one short read per sysprop PUT) · 3 scheduled jobs N/A · 4 long tx No · 5 affinity No · 6 retry/idempotency No (deterministic refusal) · 7 tenant context No · 8 distributed lock N/A · 9 cache No (§7.1 #3) · 10 external notifications No.

**v2 constraints:** 1 `tenantTransactionManager` on the new read: Yes · 2 `readOnly = true`: Yes · 3 tenant persistence unit: `@PersistenceContext(unitName = "tenant")` (bare binds landlord): Yes · 4 constructor injection in the new handler (service keeps field-injected EM, see Fix D): Yes · 5 SLF4J `{}` params, no value logged: Yes · 6 `jakarta.*` only: Yes · 7 OSIV off, pinned by IT; Testcontainers not H2: Yes · 8 no Caffeine/metrics change: N/A.

## 10. Open questions / Resolved decisions
**Resolved (Nam, 2026-11-13/14 — do not reopen):**
- R1 AC-2 = mask everywhere (entity serialization + `getSystemByGroupname`); a write carrying the mask is refused 422.
- R2 Secret list = `OMS_API_USER`, `WMS_LOGIN_SECRET`, `KEYCLOAK_API_USER`, `CUPS_SERVER_ADDRESS_PASSWORD`; one set, keyed on syskey.
- R3 AC-3 = new `@RepositoryEventHandler`, `@HandleBeforeSave`, `@Order(HIGHEST_PRECEDENCE)`, native committed read, refuse ANY groupname change incl. null; unchecked → 422.
- R4 Fold-ins: `exported=false` on both scalar searches; mask `updateClient` response; DEBUG logs key only.
- R5 (was Q1) Secret = explicit list OR `SensitiveMapRedactor.isSensitive`, called from `util.SyspropSecrets` in the same package; visibility not widened.
- R6 (was Q2) The fence refuses EVERY `syskey` rename over SDR PUT.

**Open:** none.

## Completeness checklist
| # | Item | Status |
|---|---|---|
| 0 | DB verified | ✓ §1 (dev counts this round; 3 PRDs; WineCo PRD unmeasured) |
| 1 | Call sites enumerated | ✓ §0 (method + blind spot); indirect paths X1 (URL rewrite → Basic auth) and X2 (overwrite) **excluded with rationale** → P100 / SBDEV-4131 |
| 2 | Adjacent sites | ✓ R6, W5/W6, L1, getStringDefault log folded in |
| 3 | Back-compat | ✓ response shape unchanged; 2 searches 404 with 0 callers |
| 4 | Concurrency | ✓ groupname/syskey immutable over every HTTP path |
| 5 | Multi-tenant | ✓ rule is code; no tenant-specific logic |
| 6 | Errors | ✓ 422 ProblemDetail (new handler), no value in message or log |
| 7 | Observability | ✓ WARN per refusal |
| 8 | Migration | N/A — no Flyway |
| 9 | Tests | ✓ §8, 11 ACs with mutants |
| 10 | v1 | N/A — v1 reference-only |

**Verify script:** none. Every invariant is a JUnit/IT assertion; the only cross-file invariant (list ↔ catalog doc) is prose.

## ADR — SBDEV-4133 slice 1
- **Decision:** mask secret `sysvalue`s (explicit list OR `isSensitive`) at the serialization edge via a field-level contextual serializer plus the R1 DTO mask; withdraw the two scalar searches; fence SDR PUT in a dedicated HIGHEST_PRECEDENCE before-save handler that refuses any `groupname` change, any `syskey` rename and the mask sentinel.
- **Drivers:** any-`wms_user` SDR audience on PRD; GET→PUT echo in the web-ui; one construct for most routes.
- **Alternatives:** B (getter/setter split) — fallback; C (serializer modifier) — two homes; D (SDR processor) — misses MVC; E (MVC only) — rejected by Nam.
- **Why chosen:** smallest change that leaves deserialization and Java getters untouched, covers MVC and SDR JSON responses, and fails closed.
- **Consequences:** secret values are no longer readable over HTTP; an admin types a new value to change one; sysprop keys and groups are immutable over SDR PUT; CUPS row uneditable until V2.2.52; two SDR searches 404. **Not closed:** a sysprop writer can still redirect `OMS_API_USER` via a `WEBSERVICE_*_URL` rewrite or overwrite it.
- **Follow-ups:** slice 2 (AC-4..6 MD5 migration + Keycloak rotation); P98 rotate live CUPS passwords (devops); P99 delete dead `WMS_LOGIN_SECRET`/`KEYCLOAK_API_USER` (Flyway, T3); P100 HttpRestService Basic auth only to an allow-listed OMS host (T3); SBDEV-4131 guard ON.

## Changelog — round 1 → revised
Critic H1 (M4/M5 manual safety, no printLabel), M1 (Q1/Q2 absorbed + tests), M2 (census), M3 (tenant EM field injection), M4 (WRITE_ONLY kill), M5 (M7/M8), M6 (404 positive control), L1–L4; architect HIGH (read-only scope, X1/X2, P100), XML case, IT shared state, no-arg ctor, getStringDefault log, library evidence, new 422 handler / direct RuntimeException.

Round 2 (Critic, 2026-11-14): every round-1 item verified resolved. Text fixes applied: XML case → `updateClient_xmlAccept_shouldBe406` pin (MVC routes are produces=json); AC-9 pinned to the Flyway DEFAULT/system-client OMS_API_USER row; Fix F drops `defaultValue` from both getStringDefault logs; AC-1 seeds all 4 keys in Backend; SAME_THREAD claim removed; manual M4/M5 use the dead WMS_LOGIN_SECRET instead of the live OMS_API_USER.

## 11. Implementation Status (slice 1, 2026-11-14)

- **PR:** https://github.com/SiteBossInc/wms2-api/pull/678 into `develop`, branch `feature/SBDEV-4133-sysprop-secret-masking`, worktree `.claude/worktrees/wms2-api/SBDEV-4133`. It is cut from `9f041590`; a trial merge with `9fb7ad1f` (#677) is clean.
- **Commits:**
  - `14626dab`: gate tests.
  - `5d6a0c80`: Fix A + E + F.
  - `da4cb499`: Fix B + C, plus `SysvalueMaskingCurrentValueIT`. Option A held; fallback B was not needed.
  - `65f45153`: Fix D + D2.
  - Review fixes: `6f42fc5e` (S-L2), `3e992e1b` (S-L3), `a01bd181` (S-M1, S-L1, C-L1..C-L5), `c76c9d22` (final Lows plus the `sdrCollectionPost_shouldStay405` pin), `fea6619a` (Cc/Cf removed before strip), `87e1ad6b` (fragment rule on the normalised key).
- **Tests:**
  - Full unit suite at `87e1ad6b`: 10,483 run, 0 failures, 1 skipped (baseline 10,426 / 0 / 1).
  - `SyspropSecretMaskingIntegrationTest` 26/0; the 43 related IT classes 360/0.
  - Rails plus touched classes on the develop merge result: 319/0.
- **Mutation:** PIT killed 100% of mutants on the new lines. About 30 hand mutants each went red with an attributable message. The full table is in `.omc/research/SBDEV-4133-implementation-report.md`.
- **Reviews:**
  - Conformance verifier: PASS, 11/11 ACs.
  - Code review: 6 Low and 3 Nit fixed. C-L6 was deliberately left out (one extra committed-row read per PUT; ticket note).
  - Security review: 1 Medium and 3 Lows fixed.
  - Scoped reviews of every fix commit; the last is an APPROVE at `87e1ad6b`. One re-review Low ("SDR POST open") was dismissed, because `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN` includes Sysprop; it is now pinned by `sdrCollectionPost_shouldStay405`.
- **Deviations from the plan:**
  - (1) A mock `tenant` EntityManagerFactory bean was added to the `CacheEvictionOnWriteUnitTest` and `SdrCacheEvictionUnitTest` harnesses, because field injection is still resolved there.
  - (2) A `TestClassTransactionManagerArchTest` exemption was added for the `NOT_SUPPORTED` gate IT.
  - (3) The IT runs on `BasePostgresIntegrationTest`, not the H2 template, because AC-9 needs the Flyway `OMS_API_USER` row.
  - (4) `/updateClient` refuses only a client *change* on a secret row; the R2 gate pins 200 for an unchanged client.
  - (5) Additions beyond the plan, from review: printLabel `isSecret` refusal, `/create` secret-in-Labels refusal, workstation/client fence on secret rows, `reinitialize` branch removed.
- **Landmines:**
  - The shared Testcontainers DB carried another worktree's `V2.2.51` checksum (SBDEV-4138), so ITs were run with `TESTCONTAINERS_REUSE_ENABLE=false`.
  - On the unfixed build, a MockMvc failure dump copied a Flyway credential into a failsafe report. Printing is now off (`MockMvcPrint.NONE`), and assertions on Flyway rows are boolean only.
- **Carried to slice 2 / follow-ups:**
  - `SensitiveMapRedactor.normalize` should also remove Cc/Cf characters (log-redaction path; ticket note).
  - P98, P99 and P100 are in the register.

### Merge (2026-11-15)
- #678 merged into develop as `042f9a13` (head `87e1ad6b`, base `9fb7ad1f`) via `merge-one.sh`, pinned to the graded head. PR check `test` run 43587978428 graded that head against that base. No conflicts, so no resolution commits.
- `post-merge-verify.sh`: ALL PROVEN. Run 43660751243 (Docker Image CI develop) passed test and build; dev serves `develop-042f9a13…` with drift false.
- Doc markers flipped (2): `wms2-sysprop-catalog.md` and `wms2-function-to-docs-map.md`.
- Next: manual dev test M1 to M8 (`wms-dev-probe`). Slice 2 (AC-4..6) moved to SBDEV-4148 on 2026-11-15 (Nam); 4133 is `on dev` with AC-4..6 struck.

### Dev test (2026-11-15, dev serving 042f9a13)
M1–M8 all ✅ (results in the §8 table). M6–M8 replayed the web-ui's exact request (GET with ETag, then PUT minus `_links` with `If-Match`) through `api.sh`, not the browser. Restore proof: 163 of 164 `los_sysprop` rows are identical to the pre-test snapshot. The 1 diff is `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS`, the scheduler's last-run timestamp, which the test never touched. Side effects left: `version` +2 on rows 30628142, 105, 106 and 30262742 (edit plus revert). No printLabel call and no OMS message.

### Archive (2026-11-15)
> Archived 2026-11-15, after slice 1 merged (#678 `042f9a13`) and passed the dev test. Final state before archiving: on dev, with slice 2 moved to SBDEV-4148.
> Where each open item went:
> - Slice 2 (AC-4..6): SBDEV-4148 AC-1..3.
> - `SensitiveMapRedactor` Cc/Cf: SBDEV-4148 AC-4.
> - P99: SBDEV-4148 AC-5.
> - X1: proposed as P100. X2: proposed as P100, plus SBDEV-4131.
> - P98: proposed (devops).
> - Shared-DB checksum landmine: SBDEV-4138. MockMvc dump landmine: fixed in #678, and saved as a memory.
> - **C-L6** (a second committed-row read per sysprop PUT): **dropped** by Nam on 2026-11-15. Sysprop PUTs are rare admin edits, and one extra indexed single-row read costs nothing measurable.
> No acceptance script (T3, opted out).
> Implementation worktree removed 2026-11-15: wms2-api/SBDEV-4133.
