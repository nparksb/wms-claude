---
name: flyway-collision-sweep-cannot-catch-a-branch-pushed-later
description: A point-in-time Flyway version sweep cannot catch a collision with a branch pushed after it ran — three correct sweeps still missed one; run wms2-api's check-migration-version-collision.sh immediately before merge
metadata:
  type: feedback
---

Measured 2026-08-22. SBDEV-3010 (PR #184) and SBDEV-2967-C (PR #185) **both claimed `V2.2.20`**. Caught only
at merge time, by chance, because 3010 was merged first and its own new checker was then available.

**Why the existing rule was insufficient.** [[flyway-version-pick-sweep-all-remote-branches]] says to sweep
all remote branches at PR time — and that sweep ran **three times** on 2967-C (twice by me, once by a
conformance review lane). All three reported `V2.2.19` as the maximum, and **all three were correct when they
ran.** #184's branch was pushed in between. A point-in-time sweep structurally cannot see a branch that does
not exist yet, so *"I swept at PR time"* is not a defence — **the collision window stays open until the merge
lands.**

**What actually works:** `v2/wms2-api/src/main/resources/db/migration/../db/check-migration-version-collision.sh`
(added by PR #184, now on `develop`). It compares the local migration directory against every remote branch
and prints the highest version claimed *anywhere*, including on branches whose files never reached `develop`
and on abandoned pushed states. **Run it immediately before every merge that carries a migration**, not at PR
time. It reported `RESULT: clear` after renumbering 2967-C to `V2.2.21`.

**Consequence had it shipped:** Flyway finds two files at one version and fails **on every tenant** — and a
tenant migration failure never aborts application boot, so nothing reports it. See
[[wms2-tenant-object-ownership-blocks-flyway]].

**The same merge exposed a second defect no test could see.** `db/audit-access-invariants.sql` conflicted
because both branches appended a new `SET` at EOF — no semantic conflict, but git cannot tell. Resolving it
revealed that 2967-C had labelled its block **"SET 5" when the file already carried SETs 1–9**. A duplicate
section label is invisible to every test and verify row in the repo; only the merge surfaced it. **When
appending a numbered section to a shared file, grep the existing labels first.**

Corollary for any shared append-only file (`audit-access-invariants.sql`, sysprop seeds, migration
directories): two branches will both append at EOF and both pick "the next number" from a stale view. Expect
the conflict, and re-derive the number at merge rather than at authoring time.
