---
name: wms2-dargline-logback-override-silently-ignored
description: "mvn test -DargLine=-Dlogback.configurationFile=... has NO effect in wms2-api; a logging control built on it is vacuous"
metadata:
  type: feedback
---

In wms2-api, `mvn -o test -DargLine="-Dlogback.configurationFile=<file>"` did **not** change logging in the
test fork (measured 2026-11-02, SBDEV-3993). A config that set `net.aim_ai.wms.controller` to OFF left a
log-capture test green **both with and without** the code it was meant to control for, so the run proved nothing.
The pom's surefire config owns `argLine` (jacoco late-binding `@{argLine}`, see
[[wms2-test-suite-baseline-and-h2-verdict]]), and the command-line value never takes effect.

**Why:** a negative control that cannot go red reads as a pass. It was caught only because the
control was re-run with the fix removed, and it stayed green.

**How to apply:** for logging or level behaviour in a test, put the control **in-process**. Set the level
with `((ch.qos.logback.classic.Logger) LoggerFactory.getLogger(X.class)).setLevel(Level.OFF)` inside
the test, restore it in `finally`, and mutation-check that removing the fix turns it red. Never trust any
`-DargLine` system-property override in this repo without first showing it changes an outcome. The pattern
is in `common/fixtures/ErrorLogCapture` + `unit/common/ErrorLogCaptureTest`.
