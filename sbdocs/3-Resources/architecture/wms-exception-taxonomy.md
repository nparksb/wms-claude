---
type: architecture
status: active
system: wms1+wms2
last_verified: 2026-08-19
verified_by: SBDEV-2994 implementation — code read of v2 StockunitService, StockUnitController, DestinationEligibilityService, RestExceptionHandler + both message bundles
---

# WMS Exception Taxonomy

Reference for adding new error conditions to v1/wms-api or v2/wms2-api. Covers which exception type to throw, HTTP status mapping, transaction rollback implications, and i18n.

---

## §1 — v1 Exception Hierarchy

All classes live in `net.aim_ai.wms.exceptions`.

```
java.lang.Exception (checked)
├── BusinessException                          # Domain rule violations (i18n via ResourceBundle "messages")
├── FacadeException                            # External-service / integration boundary errors (i18n via ResourceBundle "messages")
└── ApiException (abstract, checked)          # REST input validation — always has getErrorObject()
    ├── ApiInvalidParameterException           # Bad / malformed input parameter
    ├── ApiConstraintViolationException        # Uniqueness / DB constraint conflict
    ├── ApiMissingUserException                # Required user not found in Keycloak
    └── SsoException                           # General Keycloak/SSO error (wraps WebApplicationException status)
        ├── SsoCreateUserException (HTTPException, implements ApiExceptionInterface)
        └── SsoGroupMembershipException        # Group join/leave failure (holds UserRepresentation)

java.lang.RuntimeException (unchecked)
└── WebserviceBusinessExceptionServerSide      # Unrecoverable server-side OMS error (propagates as 500)

java.lang.Exception (checked)
└── WebserviceBusinessExceptionClientSide      # OMS-facing validation error — caught by /rest/ controllers,
                                               # returned as HTTP 400 + {status:"failure", description:...}
```

### Supporting / Message POJOs
- `ApiErrorMessage` — `{errorMessage: String}` — base response body for ApiException subclasses
- `ApiParameterErrorMessage extends ApiErrorMessage` — adds `parameterErrors: List<{name, error}>` for field-level errors
- `SsoMessage` — `{message, operation}` — body for SsoException
- `SsoGroupMembershipMessage` — `{message, group, user}` — body for SsoGroupMembershipException
- `ApiExceptionInterface` — contract requiring `getErrorObject(): ApiErrorMessage`

---

## §2 — v2 Exception Hierarchy

All classes live in `net.aim_ai.wms.exceptions`. Classes marked with (*new*) do not exist in v1.

```
java.lang.Exception (checked)
├── BusinessException                          # Domain rule violations (i18n via ResourceBundle "messages")
├── FacadeException                            # External-service / integration boundary errors (i18n)
├── DuplicateReplenishmentException  (*new*)   # Replenish-create idempotency skip; caught in ReplenishOrderController → HTTP 409 (SBDEV-2690)
└── ApiException (abstract, checked)
    ├── ApiInvalidParameterException           # Bad / malformed input parameter
    ├── ApiConstraintViolationException        # Uniqueness / DB constraint conflict
    ├── ApiMissingUserException                # Required user not found
    └── SsoException
        ├── SsoCreateUserException
        └── SsoGroupMembershipException

java.lang.RuntimeException (unchecked)
├── WebserviceBusinessExceptionServerSide      # OMS server-side error
├── EntityNotFoundException  (*new*)           # Entity lookup failure — replaces Optional.get() NPE patterns
└── TenantException  (*new*)                   # Tenant routing / configuration failure
    (implements ApiExceptionInterface)
```

### v2-only additions explained
- **`EntityNotFoundException`** — thrown from service `.orElseThrow()` calls in place of raw `NoSuchElementException`. Takes `(entityName, id)` or `(entityName, identifier)` overloads. Mapped to 404 + RFC 9457 `ProblemDetail` by `RestExceptionHandler`.
- **`TenantException`** — thrown by `TenantDynamicRoutingDataSource` and `TenantHealthService` when tenant DB config or Keycloak config cannot be resolved. Unchecked; not currently mapped in `RestExceptionHandler` (propagates as 500 unless caught upstream).
- **`DuplicateReplenishmentException`** (SBDEV-2690) — checked; thrown by `ReplenishorderService.create` when `ReplenishGeneratorService.calculateOrder` skips creation because a pending replenish order already exists for the same item + destination. **Deliberately not a `BusinessException`** so the controller's local `catch (BusinessException)` cannot swallow it into a 200. Carries the blocking order number (`getExistingOrderNumber()`); message is hardcoded English (does not use the `messages` ResourceBundle). **Not** registered in `RestExceptionHandler` — instead caught locally in `ReplenishOrderController.create` and mapped to **HTTP 409** with an `{errors:[{field,message}]}` body.

---

## §3 — Exception → HTTP Status Mapping

### v1 `RestExceptionHandler` (`@ControllerAdvice`)

| Exception | HTTP Status | Response Body Type |
|---|---|---|
| `ApiInvalidParameterException` | **422** Unprocessable Entity | `ApiErrorMessage` |
| `ApiConstraintViolationException` | **409** Conflict | `ApiErrorMessage` |
| `MethodArgumentNotValidException` (`@Valid`) | **422** Unprocessable Entity | `ApiParameterErrorMessage` |
| `ApiMissingUserException` | **422** Unprocessable Entity | `ApiErrorMessage` |
| `SsoCreateUserException` | **dynamic** (`ex.getStatusCode()`, default 400) | `ApiErrorMessage` |
| `SsoGroupMembershipException` | **400** Bad Request | `SsoGroupMembershipMessage` |
| `SsoException` | **dynamic** (`ex.getStatus()`, default 400) | `SsoMessage` |
| `BusinessException` (safety net) | **422** Unprocessable Entity | `{errors:[{type,message}]}` Map |
| `NoSuchElementException` (safety net) | **404** Not Found | `{errors:[{type,message}]}` Map |
| `NullPointerException` (safety net) | **500** Internal Server Error | `{errors:[{type,message}]}` Map |

> **Note:** `FacadeException` and `WebserviceBusinessExceptionServerSide` are **not** handled by `RestExceptionHandler` and will produce a raw Spring Boot 500 error page unless caught in the controller.

### v2 `RestExceptionHandler` (`@ControllerAdvice`)

| Exception | HTTP Status | Response Body Type |
|---|---|---|
| `ApiInvalidParameterException` | **422** Unprocessable Entity | `ApiErrorMessage` |
| `ApiConstraintViolationException` | **409** Conflict | `ApiErrorMessage` |
| `MethodArgumentNotValidException` (`@Valid`) | **422** Unprocessable Entity | `ApiParameterErrorMessage` |
| `ApiMissingUserException` | **422** Unprocessable Entity | `ApiErrorMessage` |
| `SsoCreateUserException` | **dynamic** (`ex.getStatusCode()`) | `ApiErrorMessage` |
| `SsoGroupMembershipException` | **400** Bad Request | `SsoGroupMembershipMessage` |
| `SsoException` | **dynamic** (`ex.getStatus()`) | `SsoMessage` |
| `EntityNotFoundException` | **404** Not Found | RFC 9457 `ProblemDetail` (`title`, `detail`) |
| `ObjectOptimisticLockingFailureException` | **409** Conflict | RFC 9457 `ProblemDetail` |
| `PessimisticLockingFailureException` | **409** Conflict | RFC 9457 `ProblemDetail` |

> **Note:** `TenantException`, `FacadeException`, and `BusinessException` are **not** registered handlers in v2's `RestExceptionHandler` as of last verification. Unhandled checked exceptions propagate as 500. `TenantException` is unchecked and will surface as 500.
>
> **Controller-local mapping (not via `RestExceptionHandler`):** `ReplenishOrderController.create` catches `DuplicateReplenishmentException` and returns **409** with `{errors:[{field,message}]}` (SBDEV-2690). This is the endpoint's first non-2xx response — `BusinessException`/`FacadeException` on the same endpoint are still caught locally and returned as **200** with an `{errors:[…]}` body.

### `/rest/**` OMS endpoints (both versions)

`/rest/` controllers are **unauthenticated** and use `WebserviceBusinessExceptionClientSide` rather than `ApiException`. They never rely on `RestExceptionHandler`. The contract is:

```
Success  → HTTP 204 (or 200) + {status: "success"}
Failure  → HTTP 400             + {status: "failure", description: "<error text>"}
```

The catch block in every `/rest/` controller:
```java
} catch (WebserviceBusinessExceptionClientSide e) {
    return new ResponseEntity<>(e.getErrorMap(), HttpStatus.BAD_REQUEST);
}
// e.getErrorMap() returns: {status: "failure", description: "..."}
```

---

### SBDEV-2732 — `PutawayConfigValidationException` (v2, PR #139 merged 2026-08-11)

| Exception | Extends | HTTP | Where it is thrown |
|---|---|---|---|
| `PutawayConfigValidationException` | `RuntimeException` (**unchecked**) | **422** via `RestExceptionHandler` | `PutawayConfigService.validateOnly`, and `PutawayConfigRepositoryEventHandler`'s `sysvalue` parse |

**Why unchecked, and why the handler is not optional.** A Spring Data REST `@HandleBefore*` method
cannot declare a checked exception, so a checked type there surfaces as a 500. Unchecked alone is not
enough either: the type originally shipped **without** an `@ExceptionHandler`, and an unhandled
unchecked exception is *also* a 500 — so every HAL rejection returned 500 while the class javadoc
claimed 422. Both halves are required. Caught by the SBDEV-2732 3b review.

---

### SBDEV-2994 — the operator-input vs internal-reference discriminator (v2)

**The rule, stated so it can be applied rather than argued:** a failed lookup on a value the **caller
supplied** is a `BusinessException`; a failed lookup on a value the **system already held** is an
`EntityNotFoundException`.

| Lookup key | Origin | Exception | Rationale |
|---|---|---|---|
| Scanned container label (`unitLoadLabelId`) | operator, via a scan | `BusinessException` | the operator can act on it — rescan, or pick a live container |
| Destination location name (`locationName`) | client request / a replayed audit value | `BusinessException` | client-supplied on every caller |
| `UnitloadType` by name, `Location` by id, `Client` by id, `FixLocationAssignment` … | resolved internally from reference data or an FK | `EntityNotFoundException` | referential-integrity fault; the operator can do nothing |
| Surrogate primary key (`stockUnit.id` from the request) | client, but not operator-visible | `EntityNotFoundException` | a bad surrogate key is a client-programming error, and stays a 404 |

**Why the distinction is load-bearing and not stylistic.** `StockUnitController.transferStock` wrapped
its service call in a `catch` for `BusinessException`/`FacadeException` only, so an
`EntityNotFoundException` escaped to `RestExceptionHandler` → **404**, and both UIs' axios layers render
a 4xx they do not recognise as *"Request failed due to a network or server issue. Please retry."* A
scanned label that no longer resolves is the single most likely failure on that screen, and it produced
the least informative message in the product. Converting **only** the operator-supplied lookups keeps a
corrupt FK distinguishable from a scan mistake — a blanket conversion would flatten both into one
indistinguishable string and leave non-HTTP callers (e.g. `CancellationReversalService`) unable to tell
them apart either.

**The controller-level net is complementary, not a substitute.** `transferStock` also gained the
`catch (EntityNotFoundException)` its sibling `bulkTransferStock` already had, so the internally-derived
failures return `200 {errors:[…]}` instead of a 404 — but with a **fixed, operator-safe** string plus the
stock-unit id as a support reference, never `e.getMessage()`. Those constructors build strings like
`"Location not found with id: 3421"`, and `store/moveStock.js` renders `errors[0].message` verbatim on a
handheld; routing raw entity names and primary keys to an operator would contradict the very
classification above.

**Estate-wide half.** `RestExceptionHandler`'s `EntityNotFoundException` handler logged at `debug` —
invisible in every environment — so a referential failure left no trace anywhere. Now `warn`, covering
all 61 controllers.

> [!warning] `orElseThrow` *can* throw a checked exception
> `Optional.orElseThrow(Supplier<? extends X>) throws X` is generic over `X extends Throwable`; the
> lambda only *constructs* the exception, so `X` infers to `BusinessException` wherever the enclosing
> method declares it. There are 30+ working examples in v2 (`ReceivingService`,
> `PutawayDestinationValidator`, `CancellationReversalService`). A belief to the contrary once produced a
> needlessly verbose `Optional`/`isEmpty()` shape in a plan draft.

---

## §4 — Transaction Rollback Matrix

### Background: checked vs unchecked and Spring's default

Spring `@Transactional` only rolls back on `RuntimeException` (unchecked) by default. **Checked exceptions (`BusinessException`, `FacadeException`) do NOT trigger rollback unless `rollbackFor` is declared explicitly.**

| Exception | Type | Rolls back by default? | `rollbackFor` needed? |
|---|---|---|---|
| `BusinessException` | checked (`extends Exception`) | **No** | **Yes** — add `rollbackFor = BusinessException.class` |
| `FacadeException` | checked (`extends Exception`) | **No** | **Yes** — add `rollbackFor = FacadeException.class` |
| `ApiException` subclasses | checked | **No** | Only if thrown inside `@Transactional` service (uncommon) |
| `WebserviceBusinessExceptionClientSide` | checked | **No** | Not applicable — thrown in controllers (outside TX) |
| `WebserviceBusinessExceptionServerSide` | unchecked (`extends RuntimeException`) | **Yes** | Not needed |
| `EntityNotFoundException` (v2 only) | unchecked | **Yes** | Not needed |
| `TenantException` (v2 only) | unchecked | **Yes** | Not needed |
| `RuntimeException` / `Error` | unchecked | **Yes** | Not needed |

### Established patterns in the codebase

**v1 standard pattern** (used by `AdviceService`, `MobilePickingService`, `GoodsReceiptPositionService`, `UnitloadService`, etc.):
```java
@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})
public void doSomething() throws BusinessException, FacadeException { ... }
```

**v1 job service pattern** (step isolation):
```java
@Transactional(propagation = Propagation.REQUIRES_NEW, rollbackFor = FacadeException.class)
```

**v1 broad pattern** (`ReplenishorderService`, `PickingorderPositionService`):
```java
@Transactional(rollbackFor = Exception.class)
```

**v2 standard pattern** (ALL tenant service methods must name the TM):
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public void doSomething() throws BusinessException, FacadeException { ... }
```

**v2 job / sequence pattern:**
```java
@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW, rollbackFor = FacadeException.class)
```

> **v2 critical rule:** A bare `@Transactional` (no `value`) defaults to `landlordTransactionManager` (the `@Primary` bean), which is the master/config database. Tenant writes then run in auto-commit mode — no rollback, no L1 cache, no connection sharing. Every `@Transactional` in `net.aim_ai.wms.service` must specify `value = "tenantTransactionManager"`.

---

## §5 — i18n / Message Keys

Both v1 and v2 share the same i18n mechanism and the same bundle name.

### How it works

`BusinessException` and `FacadeException` resolve their human-readable text from `ResourceBundle.getBundle("messages", locale)` at construction time. The bundle files live at:

```
v1/wms-api/src/main/resources/
  messages_en_US.properties    ← the ONLY bundle; there is no base

v2/wms2-api/src/main/resources/
  messages.properties          ← base / parent bundle
  messages_en_US.properties    ← en_US locale
```

> **Corrected 2026-08-06.** This block previously listed seven v1 bundles
> (base, `en`, `en_US`, `de`, `fr`, `hu`, `ru`) and a single v2 bundle
> (`en_US` only). **Both were wrong, in opposite directions.** Verified against
> the filesystem and against each repo's git history: the `de`/`fr`/`hu`/`ru`
> bundles have never existed in v1 — there is no deletion commit, they were
> never tracked — and v2 grew a base `messages.properties` with SBDEV-2729,
> which SBDEV-2632 and SBDEV-2731 have since added keys to.
>
> **This mattered.** v1 having no base bundle is the reason a missing key there
> degrades to the concatenated-fallback text rather than inheriting anything,
> and v2 *having* one is what makes the duplication rule below load-bearing
> rather than ceremony.

### Constructor signatures

**`BusinessException`** — use the `(key, Object... parameter)` constructor:
```java
throw new BusinessException("BusinessException.ObjectNotFound", "StockUnit");
// Resolved: "Entity StockUnit not found"
```

**`FacadeException`** — use `(key, Object[] parameters)`:
```java
throw new FacadeException("MyKey", new Object[]{param1, param2});
```

Fallback behaviour: if the bundle or key is missing, the key and parameters are concatenated as plain text (`"key, 'param1', 'param2'"`). No exception is thrown for missing keys.

### Existing standard keys (en_US)

| Key | Template |
|---|---|
| `BusinessException.MissingField` | `Missing field: %1$s` |
| `BusinessException.ObjectNotFound` | `Entity %1$s not found` |
| `BusinessException.ObjectNotUnique` | `Entity %1$s not unique` |
| `BusinessException.SequenceExhausted` | `Cannot allocate sequence for key=%1$s after %2$s retries` (SBDEV-2217 — `BasicService.getNextSequenceNumber` retry exhaustion, replaces silent `-1` return) |
| `BusinessException.SequenceInvalid` | `Invalid sequence value=%2$s for key=%1$s` (SBDEV-2217 — caller-side defense-in-depth guard at format-helper sites) |
| `BusinessException.StockCountTooLarge` | `stock_view row count %1$s exceeds configured cap %2$s` (SBDEV-2219 — `WarehouseStockReportService.streamStockCount` hard-cap safety net; sysprop `STOCK_SUMMARY_EXPORT_MAX_ROWS_KEY`, default 1,000,000) |
| `BusinessException.InvalidSyspropValue` | `Invalid system property value: %1$s=%2$s` (SBDEV-2220 — surfaces malformed numeric sysprop values as domain errors instead of raw `NumberFormatException`; currently used by `CleanUpOldMessageJobService.readPeriod` for `CLEAN_UP_OLD_MESSAGES_PERIOD`) |
| `CLIENT_PERMISSION_DENIED` | `No permission for client %1$s` |
| `ENTITY_NOT_LONGER_PERTINENT` | `Entity no longer pertinent %1$s` |
| `OUT_OF_RANGE` | `Value out of range` |
| `UNAUTHENTICATED` | `Not authentificated` |

### Adding a new localized error message

1. Add the key+template to `src/main/resources/messages_en_US.properties`:
   ```
   MyModule.MyError=Widget %1$s cannot be moved to location %2$s
   ```
2. **On v2, add the SAME entry to `messages.properties` as well — this is required, not optional.**

   `BusinessException` resolves against `ResourceBundle.getBundle("messages", Locale.getDefault())` **at construction time**, and nothing pins the locale in the Dockerfile, in CI, or in `application.properties`. On a JVM whose default locale is not `en_US` — which depends on the base image — a key present only in `messages_en_US.properties` fails to resolve and the operator gets the concatenated fallback (`"MyModule.MyError, 'W-1', 'LOC-2'"`) instead of the message. Declared in the base bundle it holds for every locale.

   ⚠️ **A test that only asserts the rendered message cannot catch a missing base copy.** `messages.properties` is the *parent* of every locale bundle, so deleting the key from `messages_en_US.properties` changes nothing under an en_US JVM — resolution silently falls through to the base. Pin the base bundle explicitly with `getLocalizedMessage(Locale.ROOT)`, and pin each file's own copy by reading it directly (`Properties.load`, **with an explicit UTF-8 reader** — `Properties.load(InputStream)` is specified as ISO-8859-1 while `PropertyResourceBundle` reads UTF-8). See `UnitloadBusinessServiceUnitTest` T14b (SBDEV-2731) for the worked pattern.

   There are no `de`/`fr`/`hu`/`ru` bundles in either repo — do not add entries to files that do not exist.
3. Throw the exception with the key:
   ```java
   throw new BusinessException("MyModule.MyError", widgetId, locationCode);
   ```
4. The `%1$s`, `%2$s` placeholders use `String.format()` positional syntax.

> **ApiException subclasses do not use ResourceBundle.** Pass a plain English string to their constructor — it goes directly into `ApiErrorMessage.errorMessage`.

---

### SBDEV-2732 putaway destination keys (v2, PR #139 merged 2026-08-11)

Ten keys, present in **both** `messages.properties` and `messages_en_US.properties` — the ResourceBundle
parent chain hides a deletion from the child, so both files must carry every key.

| Key | Meaning |
|---|---|
| `putawayDestinationNotPermitted` | P1 failure at receipt: the unit-load type cannot sit on the destination |
| `putawayDestinationLocked` | Destination is entity-locked (P2.1, absolute at all three scopes) |
| `putawayDestinationIsALane` | Operational lane rejected — absolute for transfer/automation/gate, SKU-scope only for staging/cross-dock |
| `putawayDestinationFlowbinNotAllowedForScope` | Flowbin at merchant/warehouse scope (rule (e)) — putaway's FLA auto-bind would break every other SKU |
| `putawayDestinationAreaNotUsable` | Area is neither goods-in nor storage (P2.4) |
| `putawayDestinationBoundToAnotherSku` | Rule (f): the flowbin is another SKU's fixed pick face |
| `skuAlreadyBoundToAnotherPickFace` | Rule (f), other direction: this SKU already owns a different pick face |
| `putawayDestinationTypeIncompatible` | P2.6 write-time pre-check against the SKU's default unit-load type |
| `putawayDestinationIncompatibleForEverySku` | 100% of SKUs in scope incompatible — 422, no confirmation can override |
| `putawayDestinationUseTypedEndpoint` | The system-property screen refuses the guarded syskey; use `PUT /putawayConfig/warehouse` |

⚠ `putawayDestinationNotPermitted` takes **five** format args and its arg map is documented at the
throw site. `%3$s` is the incompatibility *sentence*, not a bare type id — passing an id there produces
a garbled message, which shipped once and was caught in review because no test rendered the template.

## §6 — When to Use Which Exception (Decision Guide)

```
Is the error caused by invalid HTTP request input (missing field, wrong type)?
  └─ Yes → ApiInvalidParameterException (single field: use field-name overload)
             or MethodArgumentNotValidException (via @Valid on the DTO — no throw needed)

Is the error a database uniqueness / FK constraint violation?
  └─ Yes → ApiConstraintViolationException

Is the required Keycloak user absent?
  └─ Yes → ApiMissingUserException

Is the error a Keycloak/SSO API call failure?
  └─ Yes → SsoException (general), SsoCreateUserException (user creation), SsoGroupMembershipException (group)

Is the error a domain/business rule violation (invalid state transition, insufficient stock,
  warehouse logic constraint) that a human operator can understand and act on?
  └─ Yes → BusinessException(key, params...)
             Declare rollbackFor = BusinessException.class on the enclosing @Transactional
             Add a message key to messages_en_US.properties if new

Is the error a failure in an external service call (OMS callback, external API, integration
  boundary) or an infrastructure fault that wraps another exception?
  └─ Yes → FacadeException(key, params, cause)
             Declare rollbackFor = FacadeException.class on the enclosing @Transactional

Is the error that a DB entity simply does not exist?
  └─ v1 → BusinessException("BusinessException.ObjectNotFound", entityName) — results in 422
  └─ v2 → EntityNotFoundException(entityName, id) — results in 404 + ProblemDetail (preferred)

Is the error inside a /rest/ controller (OMS integration endpoint)?
  └─ Yes → WebserviceBusinessExceptionClientSide(WmsConstants.<ERROR_CODE>, cause, params...)
             Caught immediately in the controller; returned as HTTP 400 + {status:"failure"}

Is the error an unrecoverable server-side condition in a /rest/ flow?
  └─ Yes → WebserviceBusinessExceptionServerSide (propagates as 500)

Is the error a tenant routing / config failure? (v2 only)
  └─ Yes → TenantException (propagates as 500 — infrastructure concern, not business logic)
```


### SBDEV-2994 move-stock destination keys (v2)

Three keys, in **both** bundles for the same parent-chain reason.

| Key | Args | Meaning |
|---|---|---|
| `transferStockDestinationUnitloadNotFound` | `%1$s` = scanned label | The destination container does not resolve — emptied, removed, or label-mangled by `sendToNirvana` |
| `transferStockDestinationLocationNotFound` | `%1$s` = location name | The client-supplied destination location does not resolve |
| `transferStockDestinationNotUsable` | `%1$s` = label, `%2$s` = reason | The container exists but cannot receive stock |

`%2$s` is a reason token supplied per branch: `BusinessObjectLockState.getCodeText(lock)` (e.g.
`"To Delete"`, `"Shipped"`), the literal `"retired"` for the Nirvana sentinel, `"already shipped"` for a
destination parked at the Shipped location, and `"in an unknown state"` for a null lock. That last one is
deliberately **not** `getCodeText(NOT_FOUND)` = `"Not Found"`, which would read as *"Container UL1 is Not
Found and cannot receive stock"* about a container that demonstrably **was** found — colliding with
`transferStockDestinationUnitloadNotFound`.

⚠ Assert `getKey()`, never rendered text, and always construct with the **keyed** two-arg form. The
single-String overload `BusinessException(String)` silently sets `key = "placeholder"`, so an implementer
who omits the second argument gets a runtime `getKey()` mismatch rather than a compile error.

⚠ A key-presence test is not enough. `transferStockDestinationUnitloadNotFound=Container not found.`
would satisfy one while failing the entire point of the change, which is to **name** the container — so
the tests assert each value contains its `%1$s` (and `%2$s` where applicable), in both bundles, loaded
through an explicit UTF-8 `Reader`. `Properties.load(InputStream)` decodes ISO-8859-1 while
`PropertyResourceBundle` — what production uses — decodes UTF-8.

---

## §7 — OMS-Facing Exceptions (`/rest/` Endpoints)

The `/rest/**` path is **excluded from Spring Security** in both versions. OMS (the PHP caller) expects every response to be HTTP 200 or 400 with a JSON body — never a raw Spring error page.

### Contract

| Outcome | HTTP | Body |
|---|---|---|
| Success | 204 No Content (or 200) | `{"status": "success"}` |
| Client error | 400 Bad Request | `{"status": "failure", "description": "<text>"}` |
| Server error | 500 (unhandled) | Spring default error JSON |

### Error codes (`WmsConstants` integer constants)

Used exclusively with `WebserviceBusinessExceptionClientSide`:

| Constant | Int | Description template |
|---|---|---|
| `GENERIC_ERROR` | 0 | Generic — see stacktrace |
| `PARAMETER_IS_NULL` | 50 | given parameter must not be null |
| `WRONG_FACILITY_CODE` | 75 | wrong facility code %1s doesn't match expected id=%2s for %3s |
| `FIELD_NOT_SET` | 100 | field %1s not set for %2s |
| `ENTITY_ALREADY_EXITS` | 101 | entity %1s already exists for %2s |
| `ENTITY_DOES_NOT_EXISTS` | 102 | entity %1s does not exists with ID %2s for %3s |
| `FIELD_MALFORMED_FORMAT` | 103 | field %1s has wrong format for %2s |
| `NO_POSITION` | 104 | no position found for %1s |
| `NOT_UNIQUE_VALUE` | 105 | duplicate value %1s found in %2s |
| `WRONG_STATE` | 106 | action not allowed. position is in different state %1s for %2s |
| `CHILD_NOT_PART_OF_PARENT` | 107 | child %1s is not part of parent %2s |
| `DEFAULT_TYPE_NOT_EXIST` | 200 | default type does not exist for entity '%1s' |
| `CLUB_LINE_ERROR_POSITION_AMOUNT_DIFFER` | 300 | club line amount mismatch across positions |
| `CLUB_LINE_ERROR_POSITION_SKU_DIFFER` | 301 | club line missing sku in position |
| `TRANSFERS_ONLY_ONE_ORDER_ALLOWED_PER_BATCH` | 400 | batch must contain one transfer order only |
| `NOT_ENABLLED_FOR_RECEIVING` | 500 | shipper not enabled for receiving |

> Note: `ENTITY_ALREADY_EXITS` is a typo in the source (`EXITS` not `EXISTS`) — do not fix without a grep across all callers.

### Throw pattern
```java
throw new WebserviceBusinessExceptionClientSide(
    WmsConstants.ENTITY_DOES_NOT_EXISTS, null, "client", dto.getClientId(), dto);
```

### Catch pattern (in every `/rest/` controller method)
```java
try {
    // ... processing loop ...
    return new ResponseEntity<>(Collections.singletonMap("status", "success"), HttpStatus.NO_CONTENT);
} catch (WebserviceBusinessExceptionClientSide e) {
    return new ResponseEntity<>(e.getErrorMap(), HttpStatus.BAD_REQUEST);
}
```

`AbstractRestController.validateWarehouse()` performs facility-code validation and throws `WebserviceBusinessExceptionClientSide` for mismatches — always call it first in `/rest/` controller methods.

---

## §8 — v1 vs v2 Differences

| Concern | v1/wms-api | v2/wms2-api |
|---|---|---|
| **Java / Spring Boot** | Java 8 / Spring Boot 2.3.7 | Java 21 / Spring Boot 3.x |
| **Entity not found** | `BusinessException("BusinessException.ObjectNotFound", …)` → 422 | `EntityNotFoundException(name, id)` → 404 + `ProblemDetail` |
| **Optimistic lock** | Not handled by `RestExceptionHandler` — propagates as 500 | `ObjectOptimisticLockingFailureException` → 409 + `ProblemDetail` |
| **Pessimistic lock** | Not handled — propagates as 500 | `PessimisticLockingFailureException` → 409 + `ProblemDetail` |
| **Tenant errors** | No `TenantException` class | `TenantException` (unchecked) — not in `RestExceptionHandler`, surfaces as 500 |
| **Response body format** | Plain `Map<String,Object>` / `ApiErrorMessage` POJO | Same for `ApiException` family; RFC 9457 `ProblemDetail` for infrastructure exceptions |
| **`@Transactional` TM** | Single TM — bare `@Transactional` is fine | **Dual TM** — bare `@Transactional` silently uses landlord TM; always specify `value = "tenantTransactionManager"` |
| **Safety net handlers** | `BusinessException` → 422, `NoSuchElementException` → 404, `NullPointerException` → 500 | No safety-net handlers for `BusinessException` or `NoSuchElementException`; use `EntityNotFoundException` instead |
| **messages bundle** | **1 file — `messages_en_US.properties`, no base bundle** | **2 files — `messages.properties` (base) + `messages_en_US.properties`; new keys go in BOTH** (see §5) |
| **`WebserviceBusinessExceptionClientSide`** | Present (OMS integration) | Present (same interface, same catch pattern) |
| **`WebserviceBusinessExceptionServerSide`** | Present | Present |
| **`FacadeException` handler** | Not registered in `RestExceptionHandler` | Not registered in `RestExceptionHandler` |

## Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-08-06 | §5 i18n bundle inventory for both stacks, and the `messages bundle` row of the v1↔v2 delta table | **Both were wrong, in opposite directions, and are corrected.** v1 was documented as 7 locale files (base, `en`, `en_US`, `de`, `fr`, `hu`, `ru`); it has exactly **one**, `messages_en_US.properties`, and the other six have no history in the repo — no deletion commit, never tracked. v2 was documented as `en_US` only; it has had a base `messages.properties` since SBDEV-2729, with keys added by SBDEV-2632 and SBDEV-2731. The "add a new message" recipe pointed at `messages_de`/`messages_fr`, files that exist in neither repo, and omitted the v2 both-bundles rule entirely. **Scoped check — §1–§4 were NOT re-verified, so `last_verified` stays at 2026-07-22.** | Filesystem + `git ls-tree`/`git log --diff-filter=D` on both repos (SBDEV-2731) |

> **Why this was worth fixing rather than just re-dating.** The stale recipe actively produced the bug: it told implementers to add keys to `messages_en_US.properties` alone, which resolves correctly under an en_US default locale and degrades to concatenated fallback text under any other. Nothing in CI or the Dockerfile pins the locale.

### Key migration notes (v1 → v2)

1. Replace every `throw new BusinessException("BusinessException.ObjectNotFound", …)` in service layer with `throw new EntityNotFoundException(entityName, id)` — this gives callers a proper 404 instead of a misleading 422.
2. Add `value = "tenantTransactionManager"` to every `@Transactional` in `net.aim_ai.wms.service`. Missing it is silent and dangerous.
3. If you add a `BusinessException` safety-net handler to v2's `RestExceptionHandler`, match the v1 format `{errors:[{type, message}]}` for frontend compatibility.
