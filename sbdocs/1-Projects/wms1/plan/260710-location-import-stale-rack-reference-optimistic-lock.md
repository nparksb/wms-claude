---
title: "Location import: stale cached LocationRack reference (v1 pair of the v2 optimistic-lock fix)"
ticket: ""
ticket_url: ""
type: "bugfix"
priority: "medium"
status: "draft"
project: ["wms1"]
version: "v1"
requester: "v2 UAT incident 2026-07-10 (hydr-nywh) — v1 pair"
created: "2026-07-10"
updated: "2026-07-10"
db_verified: false
related:
  - "../wms2/plan/260710-location-import-stale-rack-reference-optimistic-lock.md"
tags:
  - plan
---

# Location import: stale cached LocationRack reference — v1 pair (STUB)

**Status:** draft stub — filed 2026-07-10 concurrently with the v2 plan per its Critic review, to eliminate follow-up forget-risk. Flesh out before implementation.

**Authoritative analysis:** `sbdocs/1-Projects/wms2/plan/260710-location-import-stale-rack-reference-optimistic-lock.md` (db_verified: true, Architect + Critic reviewed). Read it first — full RCA, DB evidence, fix rationale, and test design live there. This stub records only the v1 deltas.

## v1 affected sites (verified 2026-07-10 in `v1/wms-api`)

| # | File:line | Defect (identical to v2) |
|---|-----------|--------------------------|
| A | `src/main/java/net/aim_ai/wms/controller/FileImportController.java:239-243` | else-branch `rack.setRackrowId(...); rack = locationRackRepository.save(rack);` without refreshing `rackMap` — stale detached re-merge hazard |
| B | `.../FileImportController.java:200` | `rackRowMap.get(locationDto.getRackName())` — GET key mismatches the PUTs at `:206`/`:220` (keyed by `getRackRowName()`) |
| C | verify at flesh-out | copy-paste `"import inbound bol called with {}"` log strings in non-BOL import methods (mirror of v2 `:149`/`:312`) |

v1 differences to respect: Java 8 / Spring Boot 2.3.7 / Hibernate 5; `javax.persistence`; entities use `getNextId()` (`:226` area) not `@GeneratedValue`; Mockito 3.3.3 (no `mockStatic`); v1 ITs blocked by SBDEV-2384 (`ro_id` view drift).

## Key open question (blocks priority call)

The v2 failure's row-1 dirty-merge driver is inferred to be version/mapping-specific (`LocalDateTime` auditing fields vs `timestamptz` under Hibernate 6 — v2 plan §1.1). **Hibernate 5 may not exhibit it**, in which case v1's bug is latent rather than firing. Settle empirically before prioritizing: add a version-invariance unit test — persist an entity, detach, re-save without mutation in a fresh transaction, assert `version` unchanged. If it increments, v1 fires the same way and this becomes high priority.

Regardless of the answer, the three one-line fixes apply defensively (same shape as v2 Fixes A/B/C).

## TODO at flesh-out

- [ ] Confirm v1 line numbers against current v1 `develop`; enumerate the Fix-C log sites
- [ ] Version-invariance test (Hibernate 5 dirty-merge question above)
- [ ] Port the v2 unit-test trio (respect Mockito 3.3.3 limits) + author `verify-260710-...sh` with `PROJECT_ROOT` pointing at `v1/wms-api`
- [ ] DB check on a v1 tenant if an incident is ever reported there (`db_verified` currently false — no v1 incident observed)
