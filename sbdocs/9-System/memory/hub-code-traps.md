---
name: hub-code-traps
description: Framework and SQL behaviours that surprised us, with the safe pattern. Hub: one line per member memory
metadata:
  type: reference
---

Hub for **Java/Spring/Hibernate/SQL behaviour traps**. Moved out of MEMORY.md on 2026-10-28 to keep the index under its load limit; each line links the member memory (newest last).

- [ResourceBundle parent chain hides child deletion](resourcebundle-parent-chain-hides-child-deletion.md) — only a per-file Properties.load works
- [wms2 response.reset() strips CORS headers](wms2-response-reset-strips-cors-headers.md) — use `resetBuffer()`; only JS `headers.get()` verifies
- [wms2 BusinessException key-vs-message traps](wms2-businessexception-key-vs-message-traps.md) — 1-arg ctor sets key="placeholder"; assert `getKey()`
- [Delete-all-then-reinsert isn't atomic](hibernate-delete-then-reinsert-same-key-needs-set-difference.md) — Hibernate emits inserts BEFORE deletes
- [wms2 UtilRestController is @Service](wms2-utilrestcontroller-is-service-not-restcontroller.md) — its 9 @RequestMapping methods DON'T route
- [wms2 join-table uniqueness is out-of-band](wms2-join-table-uniqueness-is-out-of-band.md) — migrations declare ZERO unique indexes; prd has none
- [v1 OSIV: off on UAT+prod, DEV may not be](wms1-osiv-not-pinned-dev-prod-divergence.md) — pinned nowhere in-repo, so a DEV repro may not match prod
- [Bare `%Ns` is not positional in Java](java-bare-percent-ns-is-not-positional.md) — that's `%N$s`; the base-bundle/LANG precedent misleads (the
- [Boxed-Long id `!=` works only under 128](wms2-boxed-long-id-comparison-works-under-128.md) — reference comparison; inverts past 127 and rejects
- [ArchUnit call-site rules have 5 blind spots](archunit-call-site-rules-have-five-blind-spots.md) — ctors, static init, `x::ref`, subtypes, field
- [pgjdbc wedged DB is bounded, not infinite](pgjdbc-wedged-db-is-bounded-not-infinite.md) — 11-21s/tenant/attempt measured
- [Tenant PU gets NO spring.jpa.properties.*](wms2-tenant-persistence-unit-gets-no-jpa-properties.md) — empty vendor-property map; dialect+ddl-auto work and hide it
- [.gitignore swallows NEW *.properties files](wms2-gitignore-swallows-new-properties-files.md) — silent un-addable; the "works locally, broken on the branch" cause on PR #308
- [Bare @Transactional differs by package](wms2-bare-transactional-differs-by-package.md) — landlord in `service`, TENANT in `repo.jpa`; don't widen the ArchUnit rule
- [Hibernate validate ignores extra cols + nullability](hibernate-validate-ignores-extra-columns-and-nullability.md) — only MAPPED column existence + type; reports the FIRST mismatch and stops
- [los_sysprop.modified dates the ROW, not the value](los-sysprop-modified-does-not-track-value-changes.md) — no audit trail; reads cached 2min, direct SQL skips @CacheEvict
- [Geometry branches inherit their arm's lock policy](geometry-branch-inherits-its-arms-lock-policy.md) — same action honours or ignores a lock by data shape; 2 sites in wms2
- [Orphan scans miss ctor-injected fields](orphan-scan-misses-constructor-injected-fields.md) — dead Spring dep sits at 3 occurrences, not 1
- [State constants have 3 spellings](java-state-constant-has-three-spellings.md) — qualified, static-import, numeric; one sweep is a false negative
- [v2 entity equals is id-based via AbstractBaseEntity](wms2-entity-equals-is-id-based-via-abstractbaseentity.md) — 44/74 inherit it; a single-file grep for `boolean equals` reads as identity and is wrong
- [ProblemDetail properties nest on every channel](wms2-problemdetail-properties-nest-on-every-channel.md) — $.properties.*, not root; standaloneSetup flattens so the unit lane tests a fake shape
- [wms2 ProblemDetail props: flat OR nested by path](wms2-problemdetail-custom-properties-are-nested.md) — controller-returned = flat (live), exception-handler = properties.X (IT); read both
- [set_config in LATERAL doesn't apply](set-config-in-lateral-does-not-parameterize-current-setting.md)
- [New sequence key first draw fails](wms2-new-sequence-key-first-draw-fails.md) — fixed dev, not PRD
- [Derived finder null → IS NULL](spring-data-derived-query-null-becomes-is-null.md)
- [PG partial index unusable with bind param](postgres-partial-index-unusable-with-bind-parameter.md) — inline the constant
- [`--` in a pom.xml comment breaks the build](xml-comment-double-dash-breaks-pom.md) — parse the POM
- [BusinessException(String,Throwable).getMessage() is null](wms2-businessexception-string-throwable-getmessage-is-null.md) — resolves from key
- [IdempotencyFilter caches /rest 200 failures](wms2-idempotency-filter-caches-rest-200-failures.md) — only cancelPositions excepted
- [Unordered finder = heap order; UPDATE moves row](derived-finder-row-order-is-heap-order-update-moves-it.md) — assert fixture order
- [Native-query sort qualifies subquery aliases](spring-data-native-sort-qualifies-subquery-aliases.md) — "(SELECT…) as x" sorts as a.x → 500; use ")::numeric as x", LATERAL is 18x slower
- [[wms2-native-null-integer-param-binds-typed]]: native null Integer @Param binds typed on PG14/Hibernate 6; CAST is convention (measured), not a fix
- [[wms2-report-list-rows-are-hand-built-dto-maps]]: report column needs view + entity + ViewDtoService dto.put + export row; the list DTO is hand-built (SBDEV-3552)
- [[wms2-syspropservice-parselongordefault-throws-on-garbage]]: parseLongOrDefault falls back only when ABSENT (garbage throws); getIntValue swallows. Read the body before refuting a review
- [[wms2-landlord-db-url-keeps-query-params]]: tenant db_url keeps the landlord ?params after the DB name; an end-anchored LIKE fails OPEN (SBDEV-3193 orphan-DROP gate)
