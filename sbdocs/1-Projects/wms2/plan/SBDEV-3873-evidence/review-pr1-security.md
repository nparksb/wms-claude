---
head: 76f60dc2
lane: Phase 3b — independent security review, PR 1 (wms2-api)
date: 2026-10-22
verdict: APPROVE
---

head: 76f60dc2

# SBDEV-3873 PR 1 — security review

**Scope:** `git diff origin/develop...76f60dc2` in `.claude/worktrees/wms2-api/SBDEV-3873`. Main code is
`Advice.java`, `Cyclecount.java`, `AdviceController.setComment`, `AdviceCommentRequest`, `AdviceService.setComment`.
I also traced `RestConfiguration` (exposure), `FunctionGuardInterceptor`, `AccessService.checkAnyAccess`,
`RestExceptionHandler`, `AbstractBaseEntity`, and Spring Data REST 4.5.7 / Commons 3.5.7 sources
(`DomainObjectReader`, `MappedProperties`, `PersistentEntityResourceHandlerMethodArgumentResolver`,
`json/patch/*`). I did not run mvn, per the hard rule, so nothing here was observed at runtime. Every claim is read from source.

**Risk level:** LOW. PR 1 removes a High (any `wms_user` could rewrite `clientId` / `type` / `externalid` / `transferId` / ... on
any advice). It does not add an access path that is wider than what exists today.

**Counts:** Critical 0 · High 0 · Medium 0 · Low 3 · Info 3

## 1. Remaining SDR write routes on Advice / Cyclecount (all traced)

| Route | State at 76f60dc2 | Evidence |
|---|---|---|
| Collection POST `/v3/advice`, `/v3/cyclecount` | 405 | `configureAdviceCollectionCreateWriteExposure` (`RestConfiguration.java:640-643`); Cyclecount in `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN` (`:798-799`) |
| Item PUT (incl. PUT-for-create) / DELETE | 405 on both | `:682-685` `disable(HttpMethod.PUT, HttpMethod.DELETE)` for Advice; `:878-880` same for Cyclecount. PUT disabled as a verb, so the `isNew` create branch of `putItemResource` is unreachable |
| Association resources | none exist | no `@ManyTo*`/`@OneTo*`/`@Embedded`/`@ElementCollection` on either class |
| Item PATCH, merge-patch JSON | binds only `comment` (Advice), nothing declared (Cyclecount); inherited fields still bind (see L1/I1) | `DomainObjectReader.doMerge` strips every field where `!mappedProperties.isWritableField(fieldName)` → `property.isWritable()`, which `@ReadOnlyProperty` drives false. Unknown or setter-only names return `anySetterFound` (false, no `@JsonAnySetter`), so they are stripped too |
| Item PATCH, JSON-Patch `add/remove/replace/move/copy` | fenced | Every op calls `path.bindForWrite(...)` → `JsonPointerMapping.forWrite` → `BindContext::getWritableProperty`. `move` binds **both** `from` and `to` for write (`SpelPath.java:356-358`), so it cannot null a read-only source. `copy from:/externalid path:/comment` only writes `comment` and copies data the caller can already GET |
| `id` in a PATCH body | neutralised | the resolver re-sets the identifier from the loaded object after the merge (`PersistentEntityResourceHandlerMethodArgumentResolver` "Transfer identifier from existing object") |

All Advice setters are plain field assignments, so no setter has a side effect that a bindable `comment` could trigger.
`SdrCommentOnlyWritableContextTest` builds from runtime `PersistentEntities`, cross-checks against reflection and fails on a
writable property with no field. That makes it a real invariant, not a list.

## 2. New endpoint `POST /v3/advice/setComment`

- **Gate enforced:** `FunctionGuardInterceptor.preHandle` reads the method-level `@RequiresFunction` and calls
  `accessService.checkAnyAccess`, whether or not `GUARDED` contains the class. The `GUARDED` set matters only for *unannotated*
  handlers (`FunctionGuardInterceptor.java:258-285`). `checkAnyAccess` has no mode or log-only bypass
  (`AccessService.java:134-159`). The interceptor is mapped on `/**` (`WebConfig.java:87`). The gate runs before the lookup, so a
  non-holder gets 403 and cannot probe ids by 404 vs 403.
- **Access widening vs today:** none. Today any `wms_user` can PATCH any advice's comment with no function. The new route
  requires `WEB_UI_VIEW_INBOUND_BOL`, the same gate as the sibling `setPurchaseOrderNumber`, `closeInboundBol` and
  `adviceDetailsById`.
- **Tenant isolation:** the lookup is `adviceRepository.findById` under `tenantTransactionManager`. That is the same datasource
  routing every other handler uses, and it adds nothing new.
- **IDOR across clients:** the lookup has no client predicate, but v2 has **no** per-user client scoping anywhere (grep for
  client-scope helpers in `src/main` finds nothing). An INBOUND_BOL holder can already read and modify any client's advice
  through the screen's own endpoints. This matches today's model, so I raise no finding.
- **Mass assignment:** `record AdviceCommentRequest(Long id, String comment)` plus `FAIL_ON_UNKNOWN_PROPERTIES=false`. Extra
  keys have nowhere to bind. The service touches only `setComment` and then `save`. AC-2 seeds a RETURN advice and sends
  `externalid`/`clientId`/`type`/`state`, which pins this.
- **Side effects:** none. There are no `@RepositoryEventHandler`, `@PreUpdate` or `@PostUpdate` listeners on Advice, only
  `AuditingEntityListener`. The direct repository save fires no SDR events.
- **Input:** a null `id` returns 422 before the load. A null body returns 400, because Spring's required `@RequestBody` rejects
  a null argument. Length is checked as `String.length()` (UTF-16 units) against `varchar(255)` (code points). That is stricter
  than the column, so it never overflows (see L3 for the edge case).
- **Error responses:** the 422 text is fixed (`"comment must be at most 255 characters"`) and the 404 says `"Advice <id>"`.
  Neither echoes the comment. With no generic handler, unexpected errors fall to Boot's default body, which carries no message.
- **Logging/PII:** the controller logs `id` only at DEBUG. The service logs nothing. The comment content is never logged.
- **Downstream rendering:** there is no `v-html` on the receiving or cycle-count components (`origin/develop` web-ui). The xlsx
  export writes the comment through `setCellValue(String)`, which stores a string cell, never a formula, so there is no
  formula injection.
- **Secrets / dependencies:** the diff adds no credentials. Its only `UsernamePasswordAuthenticationToken(…, "n/a", …)` is in
  test fixtures. No `pom.xml` change, so the dependency audit is unchanged by this PR and I did not run it (mvn is prohibited).

## 3. Findings

### L1 — Inherited `created` remains rewritable via SDR PATCH on both types until PR 2 (accepted residual)
**Severity:** Low · **Category:** A01/A04 · **Location:** `AbstractBaseEntity.java` `@CreatedDate private LocalDateTime created;`
**Exploitability:** Remote. Any authenticated `wms_user` at SDR guard mode OFF can do it, with no function needed.
**Blast radius:** Display-only. `created` on Advice/Cyclecount feeds `getAdviceDetails`/`CyclecountService` details maps and
the cycle-count list projections (`CyclecountRepository.java:76,94`). I found no business decision keyed on it.
`PATCH /v3/cyclecount/{id} {"created":"2000-01-01T00:00:00"}` still persists, as does the JSON-Patch `replace /created`.
`{"created":null}` fails at the DB if the column is NOT NULL, which only produces a 500.
**Plan position:** §5 A1 "Residual until PR 2". **I agree.** Annotating the mapped superclass would change every exported
entity. PR 2's withdrawal closes the route for these two types with no field list at all.
**Remediation (PR 2, already planned):**
```java
// RestConfiguration — SDR_WRITE_WITHDRAWN
private static final Class<?>[] SDR_WRITE_WITHDRAWN = {
        /* ... */ net.aim_ai.wms.model.Advice.class, net.aim_ai.wms.model.Cyclecount.class, /* ... */ };
```

### L2 — The comment is still writable through the ungated SDR PATCH until PR 2, so the new gate is not yet an access control
**Severity:** Low · **Category:** A01 · **Location:** `Advice.java` `private String comment;` (deliberately left writable);
`RestConfiguration.java:684-685` leaves PATCH open.
**Issue:** Until PR 2, a user without INBOUND_BOL can still write any advice comment through `PATCH /v3/advice/{id}`. That path
has no length check, so more than 255 characters gives a DB error (500). These are today's semantics, so nothing regresses.
The `@RequiresFunction` on `setComment` only bites once PR 2 lands. Reviewers and the ticket should not describe PR 1 as
"comment writes are gated".
**Plan position:** this is implicit in the D5 stop-gap design. **I agree** that it is acceptable. G1/G2 sequence PR 2 behind
PR-W, and leaving `comment` writable is what keeps the deployed UI working between PR 1 and PR-W.
**Remediation:** none in PR 1. Make sure the PR description states that the comment stays writable through SDR until PR 2.

### L3 — Characters PostgreSQL rejects (`\u0000`) return 500 instead of 422; astral-plane text is over-counted
**Severity:** Low · **Category:** A03 (input validation) · **Location:** `AdviceService.java`
`if (comment != null && comment.length() > ADVICE_COMMENT_MAX_LENGTH)`
**Issue:** PostgreSQL text types reject NUL (`invalid byte sequence for encoding "UTF8": 0x00`). `{"id":1,"comment":"a\u0000b"}`
passes validation and fails at flush with a 500 and Boot's default body, which does not leak SQL. A comment of 128 or more
emoji (2 UTF-16 units each) gets 422 although it would fit `varchar(255)`. That is safe-direction strictness and matches the
UI's JS `maxlength`. No data or integrity exposure, only error-shape hygiene.
**Remediation (optional):**
```java
if (comment != null && comment.indexOf('\u0000') >= 0) {
    throw new ApiInvalidParameterException("comment must not contain NUL characters", "comment");
}
```

### I1 — The plan's note on `version` is slightly off (no security impact)
§5 A1 says the inherited `version` "takes part in the optimistic check". On an SDR PATCH the target is a **managed** entity.
Hibernate builds the version predicate from the persistence-context snapshot (`EntityEntry.getVersion()`) and increments from
that snapshot, so a body-supplied `version` does not drive the check. SDR's real optimistic hook is `If-Match`/ETag.
`{"version":null}` makes `SimpleJpaRepository.save` take the `isNew` → `em.persist` branch. On an already-managed instance
that is a cascade no-op, and the flush then writes the next version from the snapshot. I read this from source and did not run
it, so it carries medium confidence. I judge it harmless, and PR 2 removes the question. Suggest rewording the residual line to
"`version`: body value is ignored by Hibernate for the managed entity; at worst an unnecessary version bump".

### I2 — Gate uses a "VIEW" function for a write
`WEB_UI_VIEW_INBOUND_BOL` gates the write, as it already does for `setPurchaseOrderNumber`, `closeInboundBol` and
`fixHubAndSpokePalletIssues`. This is consistent with the settled screen-function decision (memory: *Gate route on its
SCREEN's function*). I raise no change and note it only for the record.

### I3 — `modified` and `id` residuals are correctly characterised
`modified` is reset by `AuditingEntityListener` on any dirty update, and `id` is re-set by the argument resolver. Both match the
plan.

## 4. Residual-risk agreement summary

| Plan residual | Agree? |
|---|---|
| Inherited `created` bindable until PR 2 | Yes (L1) |
| `version` bindable until PR 2 | Yes, but the plan's description is imprecise (I1) |
| `id` ignored by SDR merge | Yes (verified in resolver source) |
| `modified` overwritten by auditing | Yes |
| Comment writable via ungated SDR PATCH until PR 2 (implicit) | Yes. State it in the PR text (L2) |

## Security checklist
- [x] No hardcoded secrets in the diff
- [x] Inputs validated (id required, length ≤ 255; NUL edge in L3)
- [x] Injection: JPA entity save, no query strings; JSON-Patch SpEL paths bound through writable-property mapping; xlsx string cells
- [x] AuthZ: method-level `@RequiresFunction` enforced on a non-GUARDED controller; 403 before lookup; no widening vs today
- [x] Mass assignment: two-field record; SDR merge fenced to `comment` by a runtime invariant test
- [x] Logging: no comment content logged
- [x] Dependencies: no manifest change in this PR (audit not re-run, since mvn is prohibited in this lane)

**Verdict: APPROVE.** Critical 0 / High 0 / Medium 0 / Low 3 / Info 3. No Low blocks the merge. L2 needs one sentence in the PR
description. L3 is optional hardening. L1 is closed by PR 2.
