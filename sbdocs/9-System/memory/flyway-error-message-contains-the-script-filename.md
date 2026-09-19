---
name: flyway-error-message-contains-the-script-filename
description: "Asserting on a Flyway failure message with hasMessageContaining(<column or table name>) passes for ANY failure of that script, because the message opens with the filename — assert SQLSTATE instead"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 97e6a0ad-0f09-4189-9d41-ce3c1c2f26cf
  modified: 2026-09-10T17:21:49.859Z
---

A Flyway failure message **opens with the script name and repeats its path**, before the `Message :`
line:

```
Script V2.2.26__billoflading_transfer_id_not_null.sql failed
SQL State  : 23502
Message    : ERROR: column "transfer_id" of relation "billoflading" contains null values
Location   : db/migration/V2.2.26__billoflading_transfer_id_not_null.sql (…)
```

So `hasMessageContaining("transfer_id")` — or any substring of the **filename**, which by convention
names the table and column the migration touches — is satisfied by **every** failure of that script:
a typo'd table (`42P01`), a privilege error (`42501`), a lock timeout. The assertion looks like it
pins the reason and pins only "this file failed somehow".

Measured on SBDEV-3295: a mutant changing the target table to `billoflading_TYPO` left **all three**
of that test's assertions green, including the message one, while the real cause was
`relation does not exist`. My own three mutants (no-op / silent-skip / inverted) all missed it, because
none of them made the migration fail for the *wrong* reason — which is the only mutant that assertion
was the sole detector for. A review lane found it.

**Assert the SQLSTATE, by walking the cause chain** — Flyway wraps the driver exception two deep, so
the state is not on the thrown object. There is in-repo precedent:
`StartupFlywayMigrator.firstSqlState(Throwable, String)` does exactly this walk (looking for `42501`),
including a self-referencing-cause guard. Useful states: `23502` not_null_violation,
`23505` unique_violation, `42501` insufficient_privilege, `42P01` undefined_table.

**Generalises past Flyway:** any assertion on an exception *message* is suspect when the message
embeds a file path, class name, SQL text or symbol that also appears in what you are matching. Match
a code, or a phrase that only the intended cause produces (`contains null values`), and mutate a
*wrong-reason* failure to prove it — not just an absent one.

Related: [[mutation-harness-traps]], [[green-tests-that-prove-nothing]],
[[a-zero-scan-needs-a-positive-control]], [[wms2-flyway-migration-facts-corrected]].
