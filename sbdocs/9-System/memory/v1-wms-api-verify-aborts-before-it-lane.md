---
name: v1-wms-api-verify-aborts-before-it-lane
description: "v1/wms-api: `mvn verify` never reaches the failsafe/IT lane because surefire's 19 pre-existing errors fail the build first — plus the measured baseline for both lanes"
metadata:
  type: project
---

Measured 2026-09-09 on `v1/wms-api` `origin/develop` @ `2406e00`, both lanes, Java 8 + the overrides
in [[run-v1-wms-api-testcontainers-its-locally]].

**Baseline — compare against these, do not assume green:**

| lane | tests | failures | errors | skipped |
|---|---|---|---|---|
| surefire (`mvn test`) | 1788 | 0 | **19** | 1 |
| failsafe (`*IT`) | 90 | 0 | **55** | 4 |

The 19 surefire errors are 8 `LocationRepositoryH2Test` + 8 `ClientRepositoryH2Test` +
`StockunitServiceUnitTest.transferStock_toNewLocation_nonFlowbin_entireStockUnit_noFla_movesUnitload`
+ 2 `FixLocationAssignmentServiceUnitTest`. The 55 IT errors are the known offline/Keycloak
context-load breakage.

**The trap: `mvn verify` ABORTS BEFORE THE IT LANE.** Surefire runs first, its 19 pre-existing errors
fail the build at the `test` phase, and failsafe never executes — `target/failsafe-reports/` is not
even created. A `verify` run therefore *looks* like it covered the ITs and covered none of them. This
bit me directly: my final `verify` printed a "failsafe" summary line that was just surefire's line
echoed, with an empty IT report dir.

To actually run the IT lane, suppress the unit lane:

```bash
mvn verify -Dtest=SKIP_UNIT_TESTS_NONE -DfailIfNoTests=false \
  -Djacoco.skip=true -Dmaven.javadoc.skip=true -DargLine="-Dapi.version=1.41"
```

`-Dtest` scopes surefire only; failsafe takes `-Dit.test`, so this runs zero unit tests and every IT.

**Two more lane facts worth not re-deriving:**

- `pom.xml` surefire has `<exclude>**/*IT.java</exclude>`, failsafe has `<include>**/*IT.java</include>`.
  So a new `*IT` class is invisible to `mvn test` — if you add one and the surefire total does not
  move, that is correct, not a missing test. (Cousin of [[wms2-api-29-it-classes-run-in-neither-test-lane]],
  but here the wiring is right.)
- `-Dtest='A+B+C'` is **not** valid surefire syntax — it matches nothing and, with
  `-DfailIfNoTests=false`, reports **BUILD SUCCESS** having run zero tests. Use commas. A false green
  that looks exactly like a real one; see [[a-zero-scan-needs-a-positive-control]].

Also: a stale `target/surefire-reports/` from an earlier run will be read back as if current — `rm -rf`
it before any run whose counts you intend to trust ([[mvn-without-clean-runs-deleted-tests]]).
