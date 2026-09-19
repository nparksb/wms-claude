---
name: burned-sequence-numbers-prove-a-code-path-ran
description: A REQUIRES_NEW counter commits independently, so gaps in it prove a discarded code path still executed
metadata:
  type: reference
---

`BasicService.getNextSequenceNumber` → `SequenceTransactionService.getNextSequenceNumber` is
`@Transactional(propagation = REQUIRES_NEW)` in BOTH v1/wms-api and v2/wms2-api. It commits in its
own transaction, so the counter advances **even when the surrounding work is discarded**.

That makes `los_sequencenumber` a forensic instrument: compare the counter against the rows that
should carry those numbers. A gap proves the allocating code path RAN and its row was lost; no gap
proves the path was never reached. Used on SBDEV/shipitez 2026-09-08 to prove
`MessageService.createServiceLog` was executing (so `httpRestService.post` had already returned)
while every `message` row it produced was silently dropped — see
[[wms1-aftercommit-message-rows-silently-lost]].

```sql
SELECT classname, sequencenumber FROM los_sequencenumber WHERE classname='WEBSERVICE_MESSAGE';
-- then, to DATE the burn (number is allocated monotonically over time):
SELECT date_trunc('month', created) AS mon, count(*) AS rows_present,
       (max(number::bigint) - min(number::bigint) + 1) - count(*) AS numbers_burned
FROM message GROUP BY 1 ORDER BY 1;
```

Burn was 0/0/0/1 for the four months before the regression and 14 562 in the month it shipped.
Check `message_archived` too (empty on shipitez1) or archival looks like a burn.

Blind spot: a burn only proves *some* caller reached the allocator; it does not name which. Pair it
with a date correlation or a per-process count. Relates to [[a-zero-scan-needs-a-positive-control]].
