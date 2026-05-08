---
type: architecture
status: active
system: wms1+wms2
last_verified: 2026-05-08
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
  messages.properties          ← default (base)
  messages_en.properties
  messages_en_US.properties    ← primary English locale (committed to git)
  messages_de.properties
  messages_fr.properties
  messages_hu.properties
  messages_ru.properties

v2/wms2-api/src/main/resources/
  messages_en_US.properties    ← primary English locale
```

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
| `CLIENT_PERMISSION_DENIED` | `No permission for client %1$s` |
| `ENTITY_NOT_LONGER_PERTINENT` | `Entity no longer pertinent %1$s` |
| `OUT_OF_RANGE` | `Value out of range` |
| `UNAUTHENTICATED` | `Not authentificated` |

### Adding a new localized error message

1. Add the key+template to `src/main/resources/messages_en_US.properties`:
   ```
   MyModule.MyError=Widget %1$s cannot be moved to location %2$s
   ```
2. Add matching entries to the other locale files (`messages_de.properties`, `messages_fr.properties`, etc.) if translations are available; otherwise the bundle falls back to the base `messages.properties`.
3. Throw the exception with the key:
   ```java
   throw new BusinessException("MyModule.MyError", widgetId, locationCode);
   ```
4. The `%1$s`, `%2$s` placeholders use `String.format()` positional syntax.

> **ApiException subclasses do not use ResourceBundle.** Pass a plain English string to their constructor — it goes directly into `ApiErrorMessage.errorMessage`.

---

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
| **messages bundle** | 7 locale files (de, en, en_US, fr, hu, ru + base) | 1 locale file (en_US only) |
| **`WebserviceBusinessExceptionClientSide`** | Present (OMS integration) | Present (same interface, same catch pattern) |
| **`WebserviceBusinessExceptionServerSide`** | Present | Present |
| **`FacadeException` handler** | Not registered in `RestExceptionHandler` | Not registered in `RestExceptionHandler` |

### Key migration notes (v1 → v2)

1. Replace every `throw new BusinessException("BusinessException.ObjectNotFound", …)` in service layer with `throw new EntityNotFoundException(entityName, id)` — this gives callers a proper 404 instead of a misleading 422.
2. Add `value = "tenantTransactionManager"` to every `@Transactional` in `net.aim_ai.wms.service`. Missing it is silent and dangerous.
3. If you add a `BusinessException` safety-net handler to v2's `RestExceptionHandler`, match the v1 format `{errors:[{type, message}]}` for frontend compatibility.
