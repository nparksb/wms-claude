---
name: sdr-exported-false-grep-matches-method-level
description: "Grepping a repository file for `exported = false` matches METHOD-level @RestResource and reads as class-level, inverting the SDR exposure verdict"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 15746052-ae44-4afd-b8c8-c905718fbdb5
  modified: 2026-09-11T12:10:27.992Z
---

Measured 2026-08-25 on SBDEV-3017 §8.11, where it produced a **false claim posted to a ClickUp
ticket**: I reported that the five access-chain join repositories were `exported = false` (i.e. SDR
writes closed). All five actually carry a plain `@RepositoryRestResource(collectionResourceRel=…,
path=…)` with **no `exported` attribute** — class-level EXPORTED. What matched my grep were individual
`@RestResource(exported = false)` annotations on `@Query` methods (bulk deletes, projections).

The bad command:
```bash
git show origin/develop:"$p" | grep -oE "exported *= *(false|true)"   # WRONG — no scope
```

**Why:** `@RestResource(exported = false)` on a method withdraws only that finder. Class-level exposure
is the `@RepositoryRestResource` annotation's own `exported` attribute. `UserRoleRepository.java:28`
warns about exactly this: *"`@RestResource(exported = false)` on repository methods does not reach [the
item/collection endpoints]."*

**How to actually answer "is this entity SDR-writable":** read the `@RepositoryRestResource` line
itself, then check `RestConfiguration.java` for a per-domain-type `ExposureConfiguration`
(`configureRoleFunctionWriteExposure`, `configureAccessChainMembershipWriteExposure` around :64-215) —
that is where wms2 actually withdraws write verbs, per-verb and per-item-vs-collection. It is narrower
than it looks: `UserGroup` item disables only PATCH+DELETE, so `PUT /v3/userGroup/{id}` and
`POST /v3/userGroup` stay live.

**Why it matters beyond the grep:** the same pass wrongly claimed `functionGuardMappedInterceptor` puts
SDR inside the gate. `FunctionGuardInterceptor:87-92` says the opposite verbatim — it *reaches* SDR but
SDR handlers declare `RepositoryEntityController`, absent from `GUARDED`, so they fall through allowed:
*"Do not read a green suite as evidence that SDR is gated: it is reachable, and still open."* So
**GUARDED membership can never gate an SDR route** — `exported = false` is the only lever there.

Live consequence found the same day, still open: `UserFunctionRepository` is plainly exported with no
withdrawal, so `POST/PUT/PATCH/DELETE /v3/userFunction` are open to any `wms_user`. Gates resolve by
`f.name` (`UserRepository.java:77-84`), so renaming a function you hold impersonates any function —
defeating **every** function gate in the codebase. See [[wms2-function-gates-are-self-grantable-via-ungated-usercontroller]] and
[[wms2-gating-programme-is-live-on-prd]].

**⚠ RECURRED 2026-09-08 (SBDEV-3262), in the direction this memory already warned about — reading the
class annotation is NOT sufficient on its own.** I read `PickingorderRepository`'s class-level
`@RepositoryRestResource(path = "pickingorder")`, saw no `exported = false`, and concluded
`PATCH /pickingorder/{id}` was live — then used that as the published design rationale for enforcing an
invariant in a setter. FALSE: `Pickingorder` is one of ~61 types listed in
**`RestConfiguration.SDR_WRITE_WITHDRAWN`** (a bulk `Class<?>[]` array, ~:441-543), whose loop
`configureUnwrittenResourceWriteExposure` disables `WRITE_VERBS` = POST/PUT/PATCH/DELETE on the item,
collection AND association exposures. So the type is exported for READS only and PATCH is 405.

That array is a THIRD mechanism, newer than the per-type `configure*WriteExposure` methods named above,
and a grep for the entity name inside `RestConfiguration` is what finds it.

**⚠ There is a FOURTH, and it is not in `RestConfiguration` at all — `@ReadOnlyProperty` on the ENTITY
FIELD** (found 2026-09-11 triaging SBDEV-3315; landed by SBDEV-3215 as `Advice.state`). It closes one
field while the verb stays open, via `DomainObjectReader.doMerge`, which strips the field JSON-side once
`MappedProperties.isWritableField` sees `PersistentProperty.isWritable() == false` — before Jackson ever
applies it. Internal Java callers are unaffected: this is SDR's own web-binding check, not
`@Column(updatable = false)`, so `service.setState()` still works.

**This one is invisible to every instrument aimed at the repository or at `RestConfiguration`**, and it
inverts the verdict in the *safe* direction, so a reviewer reading only those two concludes "open" and
files a live-exposure ticket against code that was fixed a week earlier. SBDEV-3315 is exactly that
ticket. So check all four:
1. the class-level `@RepositoryRestResource(exported = ...)`,
2. per-type `ExposureConfiguration` methods,
3. membership of the `SDR_WRITE_WITHDRAWN` array,
4. **`@ReadOnlyProperty` on the specific field** in `model/<Entity>.java`.

**Grading trap this creates: a field-level closure returns 200, not 405.** The PATCH succeeds and the
field is silently unchanged, so **the status code cannot grade it — assert the resulting value.** This is
the same failure as [[sdr-withdrawal-405-vs-rule-403]] one level down: the remedy determines the
observable, and an AC written before the remedy is chosen grades the wrong thing. A 200 here reads as
"exploit confirmed" to anyone following the AC literally.

Pin it with a context test asserting `PersistentProperty.isWritable()` on the named property, plus an
over-gating rail on a sibling field that must stay writable (`AdviceStateReadOnlyContextTest` does both:
`state` false, `comment` true). Sweep the invariant across all must-stay-writable types, not the one
instance — `SdrMustStayWritableStateNotPatchableContextTest`.

**The transferable form: "the repository is exported" does NOT imply "the write verb is reachable."**
Exposure is configured programmatically and can be withdrawn far from the annotation.

**How to apply:** never conclude SDR exposure from an unscoped grep, and never from the class annotation
alone — always finish in `RestConfiguration`. Run a review lane before posting an authz claim to a
ticket: §8.11 shipped publicly because it was authored and published in a single pass, and the 3262
version was caught only because an adversarial lane was told to attack the claim specifically.
