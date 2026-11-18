# SBDEV-4108 B — connection-held probe result

Run 2026-11-11, branch bugfix/SBDEV-4108-io-outside-tx (base origin/develop df30fa62), JDK 21, Testcontainers postgres:14-alpine.
Command: `mvn -o verify -Dit.test=TenantConnectionReleasedBeforeAfterCommitIT -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false`
Instrument source: partB-probe-TenantConnectionReleasedBeforeAfterCommitIT.java.txt (beside this file; kept off the branch until the B fix shape is decided, since it is red by design).

```
SBDEV-4108 B probe: pid=27513 insideTx[closed=false alive=true] afterCommit[closed=false alive=true]
[ERROR] Tests run: 1, Failures: 1, Errors: 0, Skipped: 0, Time elapsed: 48.08 s <<< FAILURE! -- in net.aim_ai.wms.integration.TenantConnectionReleasedBeforeAfterCommitIT
[the tenant JDBC connection is still checked out while afterCommit runs, so an HTTP call there (OMS POST, CUPS print) pins a tenant pool slot] 
[ERROR]   TenantConnectionReleasedBeforeAfterCommitIT.afterCommit_shouldRunWithTheTenantConnectionAlreadyReturned:111 [the tenant JDBC connection is still checked out while afterCommit runs, so an HTTP call there (OMS POST, CUPS print) pins a tenant pool slot] 
```

Verdict: HELD. Inside afterCommit the transaction's java.sql.Connection is not closed and its backend pid is still in pg_stat_activity. Both read open/alive inside the transaction (positive control).
Limit: the IT datasource hands out raw DriverManager connections, not Hikari; the hold is decided by Hibernate's DELAYED_ACQUISITION_AND_HOLD, not the pool.
