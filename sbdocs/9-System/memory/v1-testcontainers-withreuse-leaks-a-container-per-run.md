---
name: v1-testcontainers-withreuse-leaks-a-container-per-run
description: "v1/wms-api's AppPostgresDBContainer calls withReuse(true) while reuse is disabled locally, so every IT run leaks a postgres:12 container and Ryuk never reaps it"
metadata: 
  node_type: memory
  type: project
  originSessionId: 411e9e67-30d3-4d8d-9429-961ab41472f2
  modified: 2026-08-27T19:56:15.754Z
---

**Every `v1/wms-api` integration-test run leaks one `postgres:12` container.** Measured 2026-08-27: after a
session of repeated `ReplenishmentMonitorViewRepositoryIT` runs, **43 containers were running**, all ≥49
minutes old (34 at "2 hours", 4 at "3 hours" — the oldest predating the session). 40GB of local volumes
had accumulated.

**Cause — a two-part mismatch:**

1. `src/test/java/net/aim_ai/wms/AppPostgresDBContainer.java:15` calls `.withReuse(true)`.
2. `~/.testcontainers.properties` on this machine contains **only**
   `docker.client.strategy=…UnixSocketClientProviderStrategy` — there is **no
   `testcontainers.reuse.enable=true`**.

With `withReuse(true)`, Testcontainers stops registering the container with **Ryuk** (reuse means the
container is meant to outlive the JVM). But because reuse is not *enabled*, it is never actually reused
either. So each run creates a fresh container that nothing ever removes — neither reused nor reaped. No
Ryuk container was running at all when this was measured.

**Cleanup is safe when containers are stale.** A single v1 IT run is <60s and the full unit suite ~10min,
so anything older than ~30 minutes cannot be in active use:

```bash
docker ps --filter ancestor=postgres:12 --format '{{.ID}}|{{.Status}}'   # inspect ages first
docker rm -f $(docker ps -q --filter ancestor=postgres:12)
```

⚠️ **Check for other sessions first.** This machine routinely runs several concurrent Claude sessions with
their own worktrees and maven processes (`pgrep -f classworlds.launcher`). A container that is seconds or
minutes old may belong to someone else's in-flight test.

**Two possible real fixes, neither applied yet (needs Nam's call):**

- Add `testcontainers.reuse.enable=true` to `~/.testcontainers.properties` — makes the code's stated
  intent work, so one container is reused across runs and IT startup gets faster. Machine-local config.
- Or drop `.withReuse(true)` from `AppPostgresDBContainer` so Ryuk reaps normally. Repo change, affects CI.

Note v2 differs: my `ReplenishMonitorVisibilityIntegrationTest` uses `postgres:15-alpine` with an explicit
`@AfterAll PG.stop()` and leaked nothing.

Related: [[run-v1-wms-api-testcontainers-its-locally]], [[sbdev-3120-monitor-hides-job-holds]]
