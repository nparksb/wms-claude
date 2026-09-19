---
name: wms1-osiv-not-pinned-dev-prod-divergence
description: "v1/wms-api pins OSIV nowhere in-repo — prod runs it OFF via external config, a bare local run defaults ON, and two repo docs asserted opposite things"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 40648237-8207-4c72-9359-81f9619edc11
  modified: 2026-08-20T18:37:09.292Z
---

`v1/wms-api` has **no `spring.jpa.open-in-view` in any tracked file**. Per Nam (2026-08-20):

> **OSIV is OFF on UAT and Production. DEV may not be** — i.e. DEV can be running Spring Boot 2.x's
> default, which is ON.

It is set externally (env / external Spring config), never in a tracked file, so the guarantee is
per-environment and not visible from the repo. v2 does pin it:
`v2/wms2-api/src/main/resources/application.properties:55`.

**Practical rule: trust OSIV-off for UAT and prod; assume nothing for DEV.** A DEV-only repro of any
stale-entity / concurrency defect may be exercising the opposite persistence semantics from the
environment you are shipping to.

**Why this bites:** it changes whether a caller's entity arrives at a `@Transactional` service
**detached** or **managed**, which changes the failure mode of the same read-modify-write defect.

| | OSIV off (prod) | OSIV on (bare local) |
|---|---|---|
| caller entity into a `@Transactional` service | detached — re-fetch is a real DB read | managed — re-fetch may be an L1 hit returning the same object |
| JPQL `findByIdForUpdate` inside the tx | fresh row + fresh version | possibly the cached instance, **unrefreshed** |
| read-modify-write bug shows up as | silent lost update | `OptimisticLockException` → retry that can launder the stale value |

So a local reproduction is **not automatically faithful to production**. On SBDEV-3003 the DEV repro
left an orphaned `nextval('seqentities')` label (`UL317407` between two committed ULs) — the
signature of a rolled-back attempt, i.e. the OSIV-**on** column — while prod runs the other column.

**Two repo docs contradicted each other and neither was right** (both corrected 2026-08-20):
- `sbdocs/3-Resources/architecture/wms1-transaction-boundary-map.md` asserted OSIV *enabled* for v1
  in ~8 places, inferred from the missing property.
- `.claude/skills/wms-bugfix-plan/SKILL.md:210` asserted "disabled in **both** versions".

**How to apply:** for any v1 concurrency / stale-entity work, check the setting on the box you
reproduced on before reasoning about detached-vs-managed. Don't trust either doc's blanket claim.
Pinning `spring.jpa.open-in-view=false` in v1's `application.properties` would end the ambiguity —
not done as of 2026-08-20. Related: [[sbdev-3003-version-defeated-by-stale-operand]].
