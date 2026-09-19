---
name: wms2-sysprop-syskey-rename-defeats-guarded-key-hooks
description: "SBDEV-3103: any wms_user can silently remove the tier-3 putaway default, unaudited, by moving ANY of its three identity columns (syskey, client_id, workstation) over SDR — the guard compares syskey alone while the resolver reads the triple"
metadata:
  node_type: memory
  type: project
---

Found 2026-08-26 (security lane on SBDEV-3017 §8.13). **Live on develop. Pre-existing.**
**Filed as SBDEV-3103** (https://app.clickup.com/t/868kx255v), normal priority, 2026-08-26.

`PutawayConfigRepositoryEventHandler` guards the tier-3 warehouse default by syskey:
`:131-137` (`@HandleBeforeSave`) and `:151-155` (`@HandleBeforeDelete`) both do
`if (!isGuardedSyskey(incoming)) return;`, and `isGuardedSyskey:333-336` compares
**`incoming.getSyskey()`** to `SYSTEM_PROPERTY_DEFAULT_PUTAWAY_LOCATION_KEY`.

The entity is already **merged** by then — `PutawayConfigService:232-235`: *"SDR has already merged the
payload into a DETACHED instance by the time the handler fires, so the in-memory field holds the NEW
value."* So renaming the key away makes the guard evaluate the **new** name, miss, and early-return.

> `PATCH /v3/sysprop/30604812 {"syskey":"DEFAULT_PUTAWAY_LOCATION_OLD"}` as a plain `wms_user`
> → no authorization check, no validation, **no audit row**. Tier-3 default gone.

Reachable because `SyspropRepository:15` is `@RepositoryRestResource(path="sysprop")`,
`RestConfiguration` uses `ANNOTATED` detection (`:239`) and withdraws **no** verb for `Sysprop` (it
appears only in `exposeIdsFor`, `:227`), `Sysprop.syskey` is plain bindable with no `exported = false`,
and `SecurityConfiguration:130-133` grants `/v3/sysprop/**` to **`wms_user`** despite the block being
labelled "Admin-Only".

🔴 **CORRECTED 2026-08-26 — I originally scoped this to "rename-away only" and that was WRONG.**
The guarded row's identity is a **three-column natural key**. `isGuardedSyskey():333-336` compares
**`syskey` alone**, but `PutawayDestinationResolver.readWarehouseDefaultLocationId():218-222` resolves
tier 3 via `findBySyskeyAndClientIdAndWorkstation(GUARDED, systemClient.getId(), WORKSTATION_DEFAULT)`
— and its own comment says *"Workstation-PINNED, deliberately"*. `Sysprop.workstation` and
`Sysprop.clientId` are plain `@NotNull` scalars with no `@JsonIgnore` and no write restriction
(`RestConfiguration` restricts item PATCH for `UserGroup`/`UserRole` only). So

    PATCH /v3/sysprop/30604812 {"workstation":"WS1"}

neutralises tier 3 **identically** — unauthorized, unvalidated, unaudited. Same for `client_id`.

⚠ **And the unique index does NOT bound it — it is the clue I misread.**
`uk8tcoe23qui9q3ancbhx662iqb ON los_sysprop (client_id, syskey, workstation)` is on the **triple**, so
`(0, GUARDED, WS1)` collides with nothing and the save succeeds. The index only blocks a *second row at
the same triple* — the duplicate-row variant. **I quoted that index definition and then used it to
argue a one-column boundary.** A composite unique index is a statement that the identity is composite;
read it as the attack surface, not the fence. Found by a peer session re-deriving the surface.

**Two further corrections from the same review:**
1. **The one-liner `isGuardedSyskey(previousState) || isGuardedSyskey(incoming)` is INSUFFICIENT even
   for a rename.** `validateDelta:272` early-returns on `Objects.equals(previous, incomingDestination)`,
   and a rename does not touch `sysvalue` — so the row clears the widened guard and *still* reaches
   neither the gate nor the audit. Mutation-proved: that change alone leaves the test red. **An identity
   move must be an authorization event in its own right.**
2. **Build the predicate on a PRIMARY-KEY read of the committed triple, not on the natural-key finder.**
   The finder answers "is this the row currently resolved by the triple", not "was this row's committed
   identity guarded" — they diverge for a row holding the guarded syskey at another
   `client_id`/`workstation`, which the schema permits, and for such a row the finder-based predicate
   gates *every* save including a no-delta edit (the §3.9.3 edit-lock trap). A PK read also drops the
   `getSystemClient()` dependency, which returns null on a swallowed `NoSuchElementException` and would
   have made the guard silently no-op.

**Reproduced live** by the peer: the bypass returns HTTP 200 with `putaway_config_audit` unmoved at
8,806 rows, against a control (`sysvalue` PATCH → 403). Row restored afterwards; live state
`id=30604812, sysvalue='' (unconfigured), client_id=0, workstation=DEFAULT`.

Fix shape: one line — `isGuardedSyskey(previousState) || isGuardedSyskey(incoming)` — or withdraw
`PATCH`/`PUT` on `Sysprop` items. **Consequence for docs:** SBDEV-3017 §8.11.2's *"Nothing here is
currently reachable by a non-staff user"* is FALSE, and any AC that tests the guarded key cannot catch
this. Related: [[wms2-join-table-uniqueness-is-out-of-band]],
[[sdr-exported-false-grep-matches-method-level]].

⚠ **Do not "fix" it by annotating the `@HandleBefore*` method.** `PutawayConfigService:285-296`
records why the annotation lives on the `@Service` instead: SDR may capture the raw handler target
rather than the security proxy, leaving a handler-side annotation **inert and silently never firing**.

**It defeats a FUNCTION gate exactly as it defeats `@PreAuthorize`**, so it is not dissolved by the
[[wms2-authz-axis-keycloak-coarse-functions-fine]] migration and should ship ahead of it.
**No test lane in wms2-api evaluates `@PreAuthorize`**, so the 403 assertions need a live probe or a
`@SpringBootTest` lane — see [[wms2-wms-admin-confers-zero-functions]].
