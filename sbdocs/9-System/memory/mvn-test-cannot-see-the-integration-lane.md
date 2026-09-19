---
name: mvn-test-cannot-see-the-integration-lane
description: "wms2-api — mvn test runs surefire only; CI runs verify, and defects hide exclusively in the failsafe lane"
metadata: 
  node_type: memory
  type: project
  originSessionId: de93b3da-8de1-4f18-850d-adab1aa3f02b
  modified: 2026-09-11T20:52:50.739Z
---

In `v2/wms2-api`, **`mvn test` runs surefire only**. CI (`.github/workflows/docker-image-develop.yml`) runs `mvn -B -ntp clean verify`, and the image `build` job declares `needs: test` — so a red failsafe lane silently stops deploying while `mvn test` stays green.

Measured on SBDEV-3320 (2026-09-11): surefire **6522/0** while failsafe was **395 / 1 error**. The defect existed only in the integration lane. Running `verify` then found **two further** production defects in the same change.

Cheap targeted form (selects surefire to nothing so you don't pay for the ~6.5k-test unit run):
```
mvn -o verify -Dit.test=<Class> -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false
```

**`MobilePickingServiceIntegrationTest` and friends run on the H2 base (`BaseIntegrationTest`), which seeds almost nothing** — no `unitload_type` rows, no system client, no `los_sequencenumber`. A fixture there is not evidence about production seeding, and vice versa. That sparseness is *useful*: it is what exposes unguarded prerequisites.

**Seeding `los_sequencenumber` must be a COMMITTED JDBC insert, not a repository save** — `SequenceTransactionService.getNextSequenceNumber` is `REQUIRES_NEW` and cannot see a row the test method has merely written; a JPA `save()` yields `StaleObjectStateException`. Copy `AdviceServiceRollbackIntegrationTest.seedSequenceNumber` (note it injects `@Qualifier("landlordDataSource")`).

Related: [[enhancement-paths-must-fail-open-on-missing-config]], [[wms2-has-two-full-context-test-lanes]], [[wms2-api-29-it-classes-run-in-neither-test-lane]].

**Why:** "the unit suite is green" is not a claim about this repo's CI.

**How to apply:** before claiming a change is verified in `wms2-api`, run `verify`, not `test` — and compare failures against a measured baseline from `origin/develop`, not against a remembered number.
