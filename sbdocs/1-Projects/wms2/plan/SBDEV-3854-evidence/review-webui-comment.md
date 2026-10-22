# Review: web-ui comment, store/handlingUnits/container.js (b2b861b, SBDEV-3854)

Verdict: APPROVE (comment-only). Checked against origin/feature/SBDEV-3854-delete-container-with-stock-500.

1. No batch transaction, one tx per container: CONFIRMED. UnitLoadController is a plain @RestController with
   no @Transactional on class or bulkDeleteContainer; the loop calls unitloadService.deleteUnitLoad per
   container, which carries @Transactional(tenantTransactionManager, rollbackFor Business/FacadeException).
2. errors body => earlier ids already retired: CONFIRMED for failures inside the delete loop (earlier
   deleteUnitLoad calls committed). Nuance (LOW): a pre-check refusal (To Delete / unknown id) retires
   nothing; "ids BEFORE the failing one" is then vacuously true. Wording holds.
3. Retry refused as a whole, "already To Delete" (SBDEV-3500): CONFIRMED. The pre-loop pass loads every
   id, collects To-Delete labels and throws BusinessException "Nothing was deleted: already To Delete ..."
   before any delete; deleteUnitLoad also guards. Retired containers keep rows (see sendToNirvana
   check below). Caveat (LOW): unknown id throws EntityNotFoundException, not caught by the controller
   (it catches Business/Facade only) - not what the comment claims, unaffected.

Wording "since SBDEV-3854": acceptable provided the web-ui PR merges after wms2-api #552 (the merge order
the task states). If it merged first the sentence would be briefly false; merge order is the only
dependency.
