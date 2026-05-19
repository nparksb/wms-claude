---
id: ADR-006
title: Single-warehouse per WMS instance (v2)
status: accepted
date: 2026-05-19
deciders: [Nam Park, David Oppenheim]
relates_to: [SBDEV-2238 sub-item 4.3]
tags: [v2, architecture, rest, multi-warehouse]
---

# ADR-006 — Single-warehouse per WMS instance (v2)

## Context

`AbstractRestController.validateWarehouse()` (`v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/AbstractRestController.java:17-28`) enforces that every inbound `/rest/**` request's `facility_code` matches the single system property `SYSTEM_PROPERTY_MULTIWAREHOUSE_IDENTIFIER_KEY`. This is a binary comparison — the code does not support a per-request warehouse ACL or an allowed set of facility codes.

SBDEV-2238 sub-item 4.3 flagged this as a potential gap for multi-warehouse deployments.

## Decision

**Single-warehouse per WMS instance is the intended design. No change to `validateWarehouse()` is required.**

Each WMS client is deployed to a dedicated database (via `TenantDynamicRoutingDataSource`) and each WMS instance serves a single physical warehouse identified by `SYSTEM_PROPERTY_MULTIWAREHOUSE_IDENTIFIER_KEY`. A request carrying a `facility_code` that doesn't match that identifier belongs to a different warehouse/instance entirely — rejecting it is correct behaviour.

The existing code at `AbstractRestController.java:25-26` is the right enforcement mechanism: it rejects cross-warehouse requests before any business logic runs.

## Rationale

| Factor | Detail |
|---|---|
| **Per-tenant DB isolation** | Each tenant already gets a dedicated database (see ADR-002). There is no shared-DB scenario where multiple warehouses would live in the same WMS instance. |
| **OMS routing** | OMS routes inbound REST calls to the WMS instance for the matching warehouse. A single-warehouse contract simplifies the trust boundary — the WMS does not need to maintain an allow-list of warehouses. |
| **Operational simplicity** | A multi-warehouse ACL would require a new sysprop list, per-request lookups, and additional test coverage. The benefit is zero given the single-warehouse-per-instance deployment model. |

## Consequences

- `AbstractRestController.validateWarehouse()` remains unchanged.
- Any future multi-warehouse deployment would require: (1) a new sysprop holding an allowed set of `facility_code` values, (2) a refactor of `validateWarehouse()` to iterate that set, and (3) explicit per-tenant configuration. This ADR is the breadcrumb for that work.
- Sub-item 4.3 of SBDEV-2238 is closed: "document explicitly that this WMS instance is single-warehouse" — done here.

## Current code (for reference)

```java
// AbstractRestController.java:17-28
void validateWarehouse(AbstractWebServiceDto dto) throws WebserviceBusinessExceptionClientSide {
    String warehouseId = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_MULTIWAREHOUSE_IDENTIFIER_KEY);

    if (StringUtils.isEmpty(dto.getFacilityCode())) {
        throw new WebserviceBusinessExceptionClientSide(WmsConstants.FIELD_NOT_SET, null, "facility_code", dto);
    }

    if (!warehouseId.equals(dto.getFacilityCode())) {
        throw new WebserviceBusinessExceptionClientSide(WmsConstants.WRONG_FACILITY_CODE, null, dto.getFacilityCode(), warehouseId, dto);
    }
}
```

This is correct. The single-warehouse assumption is enforced at the first point of entry into the business logic layer.
