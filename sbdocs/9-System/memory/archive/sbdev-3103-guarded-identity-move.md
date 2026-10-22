---
name: sbdev-3103-guarded-identity-move
description: SBDEV-3103 — tier-3 putaway guard must key on the committed (syskey, client_id, workstation) triple; PR #205; and why those two gates stay on sb_admin
metadata:
  type: project
---

Any `wms_user` could neutralise the warehouse-wide Default Putaway Location over SDR —
unauthorized, unvalidated, unaudited. **Measured live on dev**, then restored: renaming the
guarded syskey returned HTTP 200 with `putaway_config_audit` unmoved, while a `sysvalue` PATCH
by the same user correctly 403'd. PR **#205** (`bugfix/SBDEV-3103-guarded-syskey-rename-bypass`).

**The load-bearing facts, all measured:**
- The guarded row's identity is the **three-column** natural key `(syskey, client_id, workstation)`
  — the same triple `PutawayDestinationResolver:218-222` resolves tier 3 through. Gating on
  `syskey` alone left `client_id`/`workstation` open with identical impact, and the unique index
  does **not** help: it is on the triple, so `(0, GUARDED, WS1)` does not collide.
- **Fixing the guard is not enough.** `validateDelta` early-returns when the destination is
  unchanged, and an identity move never touches `sysvalue` — so the row clears the guard and still
  reaches neither the gate nor the audit. An identity move must be an authorization event in its
  own right.
- Read committed identity **by primary key**, not via `findWarehouseRow()`: the natural-key finder
  answers "is this the row currently *resolved by* the triple", not "was this row's committed
  identity guarded". It also drops the `getSystemClient()` dependency, which returns null on a
  swallowed `NoSuchElementException` — a silent **fail-open** in a security predicate.
- The audit's new value must be decided in the **Before** phase and carried. The After phase
  cannot re-derive it: by then the committed identity *is* the new one.

**Carve-out decision (Nam, 2026-08-26):** `PutawayConfigService:257`/`:287` stay on
`@PreAuthorize(IS_SB_ADMIN)`, **not** migrated to `@RequiresFunction` — SBDEV-3017 split 15/5.
`@RequiresFunction` cannot enforce them (`FunctionGuardInterceptor:159-166` resolves off
`getDeclaringClass()`, which for an SDR write is SDR's generic controller), and `sb_admin` is
unforgeable through the app while a function grant is not — see
[[sb-admin-is-siteboss-super-admin-via-groups-claim]] for the corrected mechanism.

⚠ **The test suite is coupled to `:287` having an EMPTY body.** `verify(...)
.requireWarehouseConfigWriteAuthority()` means "authorized" only while the annotation *is* the
behaviour. Give that method a real body and a mutant gutting the check leaves every test green.

**Process lesson, and the reason this took four review lanes:** 13 findings, **8 of them defects I
introduced**, none surfaced by my own checks. Two repeatable causes — I chose mutants matching
failure modes I had already imagined (the `||` and away-only mutants both survived the first
attempt), and I pinned the half of the change I was thinking about (the gate) while leaving the
other half (the audit) entirely unasserted. Related:
[[green-tests-that-prove-nothing]].
