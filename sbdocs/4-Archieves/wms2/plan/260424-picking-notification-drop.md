# Debug Plan: OMS Picking Notifications Silently Dropped — v2 Migration Review

**Date:** 2026-04-01
**Priority:** High
**Source:** Original v2 plan `docs/plan/v2-fixes/260424-picking-notification-drop.md` (dated 2026-03-27)
**Target Branch:** `tmp/np106-v1-fixes-migration` (wms2-api)

---

## 1. Problem Summary

During the mobile picking flow, OMS notifications (`assignedToteID`, `picking`, `finishedPicking`) are silently dropped and no Service Log records appear. The root causes are:

1. `MessageService.createServiceLog()` throws `EntityNotFoundException` if the `anonymous` user row is missing from the tenant database — this kills the entire message creation inside `afterCommit` callbacks, where the exception is swallowed.
2. `ManageOrderService.getRequiredOmsUrl()` returns `null` when the OMS URL system property is missing — `httpRestService.post(null, payload)` throws, and if the catch block's `createMessage()` also fails (due to #1), zero audit trail is left.

## 2. Applicability Analysis

| Original Fix | v2 Status | Applicable? |
|:-------------|:----------|:------------|
| **Fix A:** `createServiceLog` — change `orElseThrow` to `orElse(null)` for anonymous user | **NOT applied.** Line 76 still uses `orElseThrow()` | **YES — needed** |
| **Fix B:** Add `@Transactional(REQUIRES_NEW)` to `createServiceLog` | **Already applied.** Line 67 has `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)` | **NO — already done** |
| **Fix C:** Flyway migration to seed `anonymous` user | **Already exists.** `V1.0.04__wms_init_data.sql` inserts the `anonymous` user at line 6 | **NO — already done** (but Fix A is still needed as a safety net) |
| **Fix D:** Improve `afterCommit` catch blocks with fallback audit record | **Low priority.** Current catch blocks log the error — adding a raw fallback record adds complexity | **DEFER — low value** |
| **Fix E:** Null-URL guard in `ManageOrderService` before `httpRestService.post` | **Partially applied.** `getRequiredOmsUrl()` (line 470-476) logs an error but still returns `null`. The null URL then causes `httpRestService.post(null, payload)` to throw, which IS caught by the outer `catch (Exception e)` block. The catch block calls `createMessage()` with `urlPath=null` — which works IF `createServiceLog` doesn't throw (it will if anonymous user is missing) | **YES — needed** (early return prevents unnecessary exception) |

### What's already working in v2

- **`@Transactional(REQUIRES_NEW)` on `createServiceLog`** — ensures message saves always run in their own tenant transaction, even from `afterCommit` callbacks
- **Anonymous user seeded via migration** — `V1.0.04__wms_init_data.sql` inserts the row
- **Catch blocks in all `afterCommit` callbacks** — exceptions are caught and logged (lines 267-269 in PickingorderBusinessService, lines 503-505, lines 484-487 in MobilePickingService)
- **Catch blocks in `ManageOrderService` notification methods** — all 7 methods have try-catch that attempts to create a FAILED message record

### What's still broken

1. **`createServiceLog` line 76:** If the anonymous user was somehow deleted or the migration didn't run for a tenant, `orElseThrow()` kills the entire message creation. This is the single point of failure that explains zero Service Log records.
2. **`getRequiredOmsUrl` returns null silently:** The `httpRestService.post(null, ...)` call throws an exception that's caught, but it's wasteful — an early return with a FAILED message record is cleaner and avoids the cascading exception.

---

## 3. Implementation Plan

### Fix A (CRITICAL): Make `createServiceLog` resilient to missing anonymous user

**File:** `src/main/java/net/aim_ai/wms/service/MessageService.java`

**Replace lines 72-76:**

```java
// BEFORE (lines 72-76):
        User user = null;
        if (userOpt.isPresent())
            user = userOpt.get();
        else
            user = userRepository.findByName(WmsConstants.USER_ANONYMOUS).orElseThrow(() -> new EntityNotFoundException("User not found by name: " + WmsConstants.USER_ANONYMOUS));

// AFTER:
        User user = null;
        if (userOpt.isPresent()) {
            user = userOpt.get();
        } else {
            user = userRepository.findByName(WmsConstants.USER_ANONYMOUS).orElse(null);
        }
```

**Why:** Eliminates the hard throw inside `afterCommit`, allowing the message record to always be persisted. If `user` is null, `m.setOperatorId(null)` and `m.setClientId(null)` are called — both are nullable fields on the `Message` entity (confirmed: `operatorId` and `clientId` are `Long` fields, not primitives).

**Note:** The log line at 77 `user.getName()` would NPE if user is null. Must also guard that:

```java
// BEFORE (line 77):
        LOG.debug("create message with operator = {}", user.getName());

// AFTER:
        LOG.debug("create message with operator = {}", user != null ? user.getName() : "unknown");
```

And the field setters at lines 85-86:

```java
// BEFORE (lines 85-86):
        m.setOperatorId(user.getId());
        m.setClientId(user.getClientId());

// AFTER:
        m.setOperatorId(user != null ? user.getId() : null);
        m.setClientId(user != null ? user.getClientId() : null);
```

### Fix E (MEDIUM): Null-URL early return in `getRequiredOmsUrl` callers

**File:** `src/main/java/net/aim_ai/wms/service/ManageOrderService.java`

**Change `getRequiredOmsUrl()` at lines 470-476 to return null, and add a null guard at each call site before `httpRestService.post()`.**

The cleanest approach: modify each notification method to check `urlPath` before making the HTTP call. Since all 7 methods follow the identical pattern, a helper approach is best.

**Replace lines 470-476:**

```java
// BEFORE:
    private String getRequiredOmsUrl(String syspropKey) {
        String url = syspropService.getSysvalue(syspropKey);
        if (url == null || url.isBlank()) {
            LOG.error("OMS URL not configured for sysprop key: {}. Notification will not be sent.", syspropKey);
        }
        return url;
    }

// AFTER:
    private String getRequiredOmsUrl(String syspropKey) {
        String url = syspropService.getSysvalue(syspropKey);
        if (url == null || url.isBlank()) {
            LOG.error("OMS URL not configured for sysprop key: {}. Notification will not be sent.", syspropKey);
            return null;
        }
        return url;
    }
```

Then at each of the 7 call sites (lines 95, 150, 209, 258, 327, 383, 439), add after the `getRequiredOmsUrl` call:

```java
            urlPath = getRequiredOmsUrl(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_...);
            if (urlPath == null) {
                messageService.createMessage(
                    syspropService.getWmsInstanceName(),
                    syspropService.getOmsInstanceName(),
                    null,
                    WmsConstants.MessageProcessType.ORDER_BATCH_...,
                    "URL_NOT_CONFIGURED",
                    WmsConstants.MessageStatus.FAILED,
                    "503", null);
                return;
            }
```

**Why:** Prevents `httpRestService.post(null, payload)` from throwing. Instead, a FAILED message record is created with destination `"URL_NOT_CONFIGURED"`, making the misconfiguration visible in the Service Log.

**Note on the 7 call sites:** Each has a different `MessageProcessType` constant, so the null guard must be added individually. However, the pattern is identical across all 7.

---

## 4. Test Plan

### 4.1 `MessageServiceUnitTest` — update existing / add new tests

**File:** `src/test/java/net/aim_ai/wms/unit/service/MessageServiceUnitTest.java`

#### Test: createServiceLog succeeds when anonymous user is missing

```java
@Test
@DisplayName("createServiceLog succeeds with null operator when anonymous user is missing")
void createServiceLog_missingAnonymousUser_succeeds() {
    // Security context returns unknown user
    try (MockedStatic<SecurityContextUtils> mocked = mockStatic(SecurityContextUtils.class)) {
        mocked.when(SecurityContextUtils::getUserName).thenReturn("unknown-user");
        when(userRepository.findByName("unknown-user")).thenReturn(Optional.empty());
        when(userRepository.findByName(WmsConstants.USER_ANONYMOUS)).thenReturn(Optional.empty());
        when(messageRepository.save(any())).thenAnswer(inv -> inv.getArgument(0));

        // Should NOT throw
        Message result = messageService.createServiceLog("WMS", "OMS", "test", "PROCESS", "/url",
            WmsConstants.MessageStatus.SENT, "200", null);

        assertThat(result).isNotNull();
        assertThat(result.getOperatorId()).isNull();
        verify(messageRepository).save(any(Message.class));
    }
}
```

#### Update existing anonymous user test

The existing test at line ~139 verifies the fallback to anonymous user works when the user IS present. This test remains valid. Add the new test alongside it.

### 4.2 `ManageOrderServiceUnitTest` — add null URL test

```java
@Test
@DisplayName("notification creates FAILED record when OMS URL is not configured")
void customerOrderToteAssigned_nullUrl_createFailedMessage() {
    when(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_PICKING_TOTE_ASSIGNED_URL_KEY))
        .thenReturn(null);

    // ... setup order batch ...

    manageOrderService.customerOrderToteAssigned(List.of(testOrder));

    verify(messageService).createMessage(any(), any(), isNull(), eq(WmsConstants.MessageProcessType.ORDER_BATCH_PICKING_TOTE_ASSIGNED),
        eq("URL_NOT_CONFIGURED"), eq(WmsConstants.MessageStatus.FAILED), eq("503"), isNull());
    verify(httpRestService, never()).post(any(), any());
}
```

---

## 5. Risks & Side Effects

| Risk | Impact | Mitigation |
|:-----|:-------|:-----------|
| Fix A: `operatorId = null` on Message — if DB has NOT NULL constraint | Insert would fail | Check `Message` entity: `operatorId` is `Long` (nullable). No DB constraint issue. |
| Fix A: Existing code that reads `message.getOperatorId()` may NPE | Unlikely — operator display in Service Log handles null gracefully | Audit Service Log UI code if concerned |
| Fix E: Early return in notification methods skips the HTTP call entirely | Intentional — no URL means no call to make | FAILED message record makes it visible |
| Fix E: 7 call sites modified — risk of copy-paste error | All follow identical pattern | Review each change carefully |

---

## 6. Task Checklist

- [x] ~~**Fix B:** Add `@Transactional(REQUIRES_NEW)` to `createServiceLog`~~ — Already done in v2
- [x] ~~**Fix C:** Seed anonymous user via migration~~ — Already done in v2 (`V1.0.04__wms_init_data.sql`)
- [x] **Fix A (Critical):** Change `orElseThrow` to `orElse(null)` in `MessageService.createServiceLog` line 76 ✓ Implemented 2026-04-01
- [x] **Fix A (Critical):** Guard `user.getName()` log at line 77 and `user.getId()`/`user.getClientId()` at lines 85-86 against null ✓ Implemented 2026-04-01
- [x] **Fix E (Medium):** Add null-URL early return with FAILED message record in all 7 notification methods in `ManageOrderService` ✓ Implemented 2026-04-01
- [x] **Tests:** Add `shouldCreateMessageWhenAnonymousUserMissing` test to `MessageServiceUnitTest` ✓ Implemented 2026-04-01
- [x] **Tests:** Updated 2 existing null-URL tests in `ManageOrderServiceUnitTest` to verify new early-return behavior (FAILED message record, no HTTP call) ✓ Implemented 2026-04-01
- [x] Run affected test suite and verify 0 new failures ✓ 63 tests across MessageServiceUnitTest (8) and ManageOrderServiceUnitTest (55) pass with 0 failures.
- [ ] Verify in staging — confirm Service Log shows entries for full picking cycle

### Files Changed

| File | Change |
|:-----|:-------|
| `src/main/java/net/aim_ai/wms/service/MessageService.java` | `orElseThrow` → `orElse(null)` for anonymous user, null-guard on `user.getName()`, `user.getId()`, `user.getClientId()` |
| `src/main/java/net/aim_ai/wms/service/ManageOrderService.java` | Null-URL early return with FAILED message record in 7 notification methods |
| `src/test/java/net/aim_ai/wms/unit/service/MessageServiceUnitTest.java` | New test for missing anonymous user |
| `src/test/java/net/aim_ai/wms/unit/service/ManageOrderServiceUnitTest.java` | New test for null URL behavior |
