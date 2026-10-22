# SBDEV-3873 PR 1 hand-mutant run (2026-10-22, branch head 37cfa4ee)

Harness: `/tmp/claude-1000/-home-nampark-dev-wms-claude/106c745f-922c-4987-90b6-23ad90878c48/scratchpad/mut/run.sh` + `mutants.py` (copies in this folder). Each mutant was applied with an exact-once anchor, all five classes were run (88 tests), and the tree was restored from git and checked clean. m6b was re-run with corrected anchors (the first anchor matched 3 times; the harness refused it).

```
=== m1 rc=1 ran=88 compileErr=0
  AdviceSetCommentContextTest.setComment_shouldReturn403AndLeaveRowUnchanged_whenCallerHoldsNoFunction:223 [route /v3/advice/setComment must be gated: a no-function caller gets 403 (mutant m1); body was
  AdviceSetCommentContextTest.setComment_shouldReturn403_whenCallerHoldsOnlyCyclecount:242 [route /v3/advice/setComment must deny a caller holding only WEB_UI_VIEW_CYCLECOUNT (mutant m1b); body was {"co
  Sbdev3017TrancheGateContextTest.everyTrancheRouteCarriesItsIntendedFunctions:1010 [SBDEV-3017 tranche 1 gate drift — 1 of 232 routes wrong.
=== m1b rc=1 ran=88 compileErr=0
  AdviceSetCommentContextTest.setComment_shouldEnqueueNoOmsOrOutboxMessage_whenCommentIsSaved:388 [route /v3/advice/setComment must answer 200; body was {"type":"about:blank","title":"Forbidden","status
  AdviceSetCommentContextTest.setComment_shouldLeaveVersionUnchanged_whenCommentIsAlreadyTheStoredValue:202 [route /v3/advice/setComment must answer 200 when the comment is unchanged; body was {"type":"
  AdviceSetCommentContextTest.setComment_shouldReturn200AndWrite_whenCallerHoldsInboundBol:258 [route /v3/advice/setComment must answer 200 to a WEB_UI_VIEW_INBOUND_BOL holder; body was {"type":"about:b
  AdviceSetCommentContextTest.setComment_shouldReturn200_whenCommentIsExactly255Chars:290 [route /v3/advice/setComment must accept a comment of exactly 255 characters; body was {"type":"about:blank","ti
  AdviceSetCommentContextTest.setComment_shouldReturn403AndLeaveRowUnchanged_whenCallerHoldsNoFunction:226 [the 403 for /v3/advice/setComment must name WEB_UI_VIEW_INBOUND_BOL as the required function] 
  AdviceSetCommentContextTest.setComment_shouldReturn403_whenCallerHoldsOnlyCyclecount:242 [route /v3/advice/setComment must deny a caller holding only WEB_UI_VIEW_CYCLECOUNT (mutant m1b); body was {"co
  AdviceSetCommentContextTest.setComment_shouldReturn404_whenAdviceIdIsUnknown:343 [route /v3/advice/setComment must answer 404 for an unknown advice id, never a 200 carrying errors (mutant m9); body wa
  AdviceSetCommentContextTest.setComment_shouldReturn422AndLeaveRowUnchanged_whenCommentExceeds255Chars:273 [route /v3/advice/setComment must reject comment.length() > 255 with 422 before the load (muta
  AdviceSetCommentContextTest.setComment_shouldReturn422_whenIdIsMissing:364 [route /v3/advice/setComment must answer 422 when the body has no id (mutant m10); body was {"type":"about:blank","title":"Fo
  AdviceSetCommentContextTest.setComment_shouldStoreEmptyString_whenCommentIsEmpty:303 [route /v3/advice/setComment must accept an empty comment; body was {"type":"about:blank","title":"Forbidden","stat
  AdviceSetCommentContextTest.setComment_shouldStoreNull_whenCommentIsNull:315 [route /v3/advice/setComment must accept a null comment; body was {"type":"about:blank","title":"Forbidden","status":403,"r
  AdviceSetCommentContextTest.setComment_shouldStoreNull_whenCommentKeyIsAbsent:328 [route /v3/advice/setComment must accept a body without a comment key; body was {"type":"about:blank","title":"Forbidd
  AdviceSetCommentContextTest.setComment_shouldWriteOnlyTheComment_whenBodyCarriesOtherAdviceFields:179 [route /v3/advice/setComment must answer 200 to an INBOUND_BOL holder; body was {"type":"about:bla
  Sbdev3017TrancheGateContextTest.everyTrancheRouteCarriesItsIntendedFunctions:1010 [SBDEV-3017 tranche 1 gate drift — 1 of 232 routes wrong.
=== m2 rc=1 ran=88 compileErr=0
  AdviceSetCommentContextTest.setComment_shouldLeaveVersionUnchanged_whenCommentIsAlreadyTheStoredValue:210 [Advice.version must be unchanged when the comment is unchanged — the closed-notice page re-
  AdviceSetCommentContextTest.setComment_shouldWriteOnlyTheComment_whenBodyCarriesOtherAdviceFields:186 [every declared Advice column other than comment must equal its seeded value — the endpoint must
=== m3 rc=1 ran=88 compileErr=0
  AdviceServiceUnitTest$SetComment.setComment_shouldRejectBeforeLoading_whenCommentExceeds255Chars:1786 [a 256-character comment must be refused with ApiInvalidParameterException (422)] 
  AdviceSetCommentContextTest.setComment_shouldReturn422AndLeaveRowUnchanged_whenCommentExceeds255Chars:268->postAs:402 » Servlet Request processing failed: org.springframework.dao.DataIntegrityViolati
=== m4 rc=1 ran=88 compileErr=0
  AdviceSetCommentContextTest.setComment_shouldWriteOnlyTheComment_whenBodyCarriesOtherAdviceFields:192 [Advice.version must be exactly seeded+1 — an entity save under @Version, not a @Modifying UPDAT
  AdviceServiceUnitTest$SetComment.setComment_shouldSaveOnlyTheCommentAndNotifyNoOne_whenAdviceExists:1775 [setComment must write the comment] 
=== m4b rc=1 ran=88 compileErr=0
  AdviceSetCommentContextTest.setComment_shouldLeaveVersionUnchanged_whenCommentIsAlreadyTheStoredValue:210 [Advice.version must be unchanged when the comment is unchanged — the closed-notice page re-
  AdviceSetCommentContextTest.setComment_shouldWriteOnlyTheComment_whenBodyCarriesOtherAdviceFields:186 [every declared Advice column other than comment must equal its seeded value — the endpoint must
=== m5 rc=1 ran=88 compileErr=0
  SdrCommentOnlyWritableContextTest.adviceDeclaredProperties_shouldBeWritableOnlyForComment_whenReadFromThePersistentEntity:46 [SDR-writable properties declared on Advice must be exactly {comment} — e
  SdrPatchFieldFenceContextTest.adviceJsonPatch_shouldReturn400AndLeaveExternalidUnchanged_whenReplacingExternalid:201 [a JSON-Patch replace of the non-writable /externalid must be refused with 400 (Jso
  SdrPatchFieldFenceContextTest.advicePatch_shouldBindOnlyComment_whenBodyAlsoCarriesExternalid:163 [Advice.externalid must be unchanged — it needs @ReadOnlyProperty so SDR's merge skips it (mutant m5
=== m5b rc=1 ran=88 compileErr=0
  SdrCommentOnlyWritableContextTest.cyclecountDeclaredProperties_shouldBeWritableForNone_whenReadFromThePersistentEntity:55 [SDR-writable properties declared on Cyclecount must be empty — every column
  SdrPatchFieldFenceContextTest.cyclecountPatch_shouldBindNothing_whenBodyCarriesName:185 [Cyclecount.name must be unchanged — it needs @ReadOnlyProperty so SDR's merge skips it (mutant m5b)] 
=== m6 rc=1 ran=88 compileErr=0
  SdrCommentOnlyWritableContextTest.adviceDeclaredProperties_shouldBeWritableOnlyForComment_whenReadFromThePersistentEntity:46 [SDR-writable properties declared on Advice must be exactly {comment} — e
src/test/java/net/aim_ai/wms/security/SdrCommentOnlyWritableContextTest.java: anchor count 3
m6b: APPLY FAILED
=== m7 rc=1 ran=88 compileErr=0
  AdviceServiceUnitTest$SetComment.setComment_shouldSaveOnlyTheCommentAndNotifyNoOne_whenAdviceExists:1779 
=== m8 rc=1 ran=88 compileErr=0
  AdviceSetCommentContextTest.setComment_shouldStoreNull_whenCommentIsNull:317 [Advice.comment must be NULL in the DB after posting comment:null (mutant m8)] 
  AdviceSetCommentContextTest.setComment_shouldStoreNull_whenCommentKeyIsAbsent:330 [Advice.comment must be NULL in the DB after posting {id} with no comment key] 
=== m9 rc=1 ran=88 compileErr=0
  AdviceSetCommentContextTest.setComment_shouldReturn404_whenAdviceIdIsUnknown:343 [route /v3/advice/setComment must answer 404 for an unknown advice id, never a 200 carrying errors (mutant m9); body wa
=== m10 rc=1 ran=88 compileErr=0
  AdviceServiceUnitTest$SetComment.setComment_shouldRejectBeforeLoading_whenIdIsMissing:1794 [a missing id must be refused with ApiInvalidParameterException (422)] 
  AdviceSetCommentContextTest.setComment_shouldReturn422_whenIdIsMissing:359->postAs:402 » Servlet Request processing failed: org.springframework.dao.InvalidDataAccessApiUsageException: The given id mu

=== m6b (re-run) — killed:
  SdrCommentOnlyWritableContextTest: 4 failures, incl. adviceDeclaredScan_shouldEqualReflection / cyclecountDeclaredScan_shouldEqualReflection
```

**Result: 14/14 killed.** Notes: m3 and m10 also fail the context test through the servlet exception (DataIntegrityViolation / InvalidDataAccessApiUsage) rather than a status assertion; their unit-test kills are attributable. m7's kill is Mockito NoInteractionsWanted naming `outboxService`.

## Review-fix mutants (head 61366313)
- **m11** (NUL check removed): killed by `AdviceSetCommentContextTest.setComment_shouldReturn422_whenCommentContainsNul` and
  `AdviceServiceUnitTest$SetComment.setComment_shouldRejectBeforeLoading_whenCommentContainsNul`.
- **m3b** (length error thrown without its parameter name): killed by the AC-4 test's new assertion, "the 422 for a
  256-character comment must name the `comment` parameter".
- **m5c** (`comment` made read-only too): killed by the JSON-Patch positive control, the AC-8 invariant and the AC-9 PATCH test.

**17/17 killed.**

## Full suite (CI command, at 76f60dc2)
- Unit: 8740 run, 0 failures, 0 errors, 1 skipped.
- Integration: 976 run, 0 failures, 0 errors, 23 skipped.
- The skipped and failing test names are identical to the baseline at 4960631d (unit 8716/0/0/1, integration 976/0/0/23).
  Compared by name with a diff of the extracted lists (24 lines, no differences).

The review-fix commit 61366313 ran 93 targeted tests green: the 6 touched classes.

## Re-review fix (head 610fda68)
- **m11b** (NUL error thrown without its parameter name): killed by the NUL context test, "must name the `comment` parameter", and by the NUL unit test, "the NUL rejection must name the `comment` field". **18/18 killed.**
