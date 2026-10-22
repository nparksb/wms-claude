# Each mutant: list of (file, old, new). Applied with exact-once replacement; harness asserts it.
C='src/main/java/net/aim_ai/wms/controller/AdviceController.java'
S='src/main/java/net/aim_ai/wms/service/AdviceService.java'
A='src/main/java/net/aim_ai/wms/model/Advice.java'
Y='src/main/java/net/aim_ai/wms/model/Cyclecount.java'
R='src/main/java/net/aim_ai/wms/repo/jpa/AdviceRepository.java'
T8='src/test/java/net/aim_ai/wms/security/SdrCommentOnlyWritableContextTest.java'
G='    @RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_INBOUND_BOL)\n    @PostMapping(path= "/setComment"'
M={
 'm1':[(C,G,'    @PostMapping(path= "/setComment"')],
 'm1b':[(C,G,G.replace('WEB_UI_VIEW_INBOUND_BOL','WEB_UI_VIEW_CYCLECOUNT'))],
 'm2':[(S,'        advice.setComment(comment);\n        return adviceRepository.save(advice);','        advice.setComment(comment);\n        advice.setType(WmsConstants.AdviceType.REGULAR);\n        return adviceRepository.save(advice);')],
 'm3':[(S,'if (comment != null && comment.length() > ADVICE_COMMENT_MAX_LENGTH) {','if (false) {')],
 'm4':[(S,'        advice.setComment(comment);\n        return adviceRepository.save(advice);','        adviceRepository.mutantUpdateComment(id, comment);\n        return adviceRepository.findById(id).orElseThrow();'),
       (R,'public interface AdviceRepository extends JpaRepository<Advice, Long>, PagingAndSortingRepository<Advice, Long> {\n','public interface AdviceRepository extends JpaRepository<Advice, Long>, PagingAndSortingRepository<Advice, Long> {\n    @RestResource(exported = false) @Modifying @Transactional @Query("update Advice a set a.comment = :c where a.id = :id") int mutantUpdateComment(@Param("id") Long id, @Param("c") String c);\n')],
 'm4b':[(S,'        advice.setComment(comment);\n        return adviceRepository.save(advice);','        advice.setComment(comment);\n        advice.setNote(advice.getNote() == null ? "" : advice.getNote() + " ");\n        return adviceRepository.save(advice);')],
 'm5':[(A,'    @ReadOnlyProperty\n    private String externalid;','    private String externalid;')],
 'm5b':[(Y,'    @ReadOnlyProperty\n    private String name;','    private String name;')],
 'm6':[(A,'    @ReadOnlyProperty\n    private String supplier;','    private String supplier;')],
 'm6b':[(T8,'p.getField().getDeclaringClass() == type && p.isWritable()','p.getOwner().getType() == type && p.isWritable()'),(T8,'p.getField().getDeclaringClass() == type) {','p.getOwner().getType() == type) {')],
 'm7':[(S,'        advice.setComment(comment);\n        return adviceRepository.save(advice);','        advice.setComment(comment);\n        outboxService.isKeyPresent("mutant");\n        return adviceRepository.save(advice);')],
 'm8':[(S,'        advice.setComment(comment);\n        return adviceRepository.save(advice);','        if (comment != null) advice.setComment(comment);\n        return adviceRepository.save(advice);')],
 'm9':[(C,'        Advice advice = adviceService.setComment(request.id(), request.comment());','        Advice advice;\n        try { advice = adviceService.setComment(request.id(), request.comment()); }\n        catch (EntityNotFoundException e) { return ResponseEntity.ok(new HashMap<>()); }')],
 'm10':[(S,'        if (id == null) {\n            throw new ApiInvalidParameterException("id is required", "id");\n        }\n','')],
}
