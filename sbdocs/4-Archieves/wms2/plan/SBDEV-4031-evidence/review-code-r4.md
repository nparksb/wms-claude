---
lane: code-reviewer round 4 (9b3eb0e4 + r3 doc fixes); saved by main session 2026-11-06
verdict: APPROVE, zero blocking findings
---
- A-1..A-3 fixed. The SLF4J placeholder counts were checked: the WARN gets the class name, and the DEBUG line passes the throwable last.
- B-1..B-4 and the nit are true against the code. Line evidence:
  - `lockIdByItemdataIdAndLocation`: repo :79-81
  - `delete(Long)` "Can't find fix assignment by ID." :415, MANDATORY :410
  - cron catch: ReplenishOrderJobService :88-94
  - move re-point: :219-265
- O-1 (Low/LOW): osiv §8.5 "gets empty" holds only for the scalar locks; the entity locks throw not-found. FIXED in the doc.
- O-2 (Low/LOW): the cron WARN depends on showLog(). FIXED in the doc.
