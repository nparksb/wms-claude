# SBDEV-3873 DB verification (dev_wh01_om1, q.sh, 2026-10-22)

## 1. The symptom: live probe (it writes)
Run as panderson on dev `develop-b399ae5d`.
- `PATCH /v3/advice/87150 {"externalid":"P3-PROBE"}` returned 2xx, and the row changed.
- `PATCH /v3/cyclecount/742350 {"name":"P3-PROBE"}` returned 2xx, and the row changed.
- Controls: comment-only PATCHes also landed.
- Restore: PATCH back to the original values, then guarded SQL for `version` and `modified`. `snapshot.sh diff` printed
  `restored` for p3-advice and p3-cc.
- Side effects: `outbox_message` 20 → 20 and `message` 1535206 → 1535206, with 0 rows created after 13:32:29Z.

## 2. Reach of the fields the PATCH exposes
```sql
select 'advice' t, count(*) total, count(*) filter (where coalesce(comment,'')<>'') with_comment,
       max(modified) filter (where coalesce(comment,'')<>'') last_comment_row from advice
union all
select 'cyclecount', count(*), count(*) filter (where coalesce(comment,'')<>''),
       max(modified) filter (where coalesce(comment,'')<>'') from cyclecount;
-- advice     | 12626 | 6443 | 2025-03-28 19:26:53+00
-- cyclecount |   178 |  113 | 2026-10-19 19:48:00+00   (that is the SBDEV-3183 dev test's comment PATCH)

select count(distinct a.client_id) clients, count(distinct a.type) types, string_agg(distinct a.type, ',') from advice a;
-- 122 | 3 | REGULAR,RETURN,TRANSFER
```

**Reading:**
- Advice spans 122 clients and 3 types, so a `clientId` or `type` write can move an advice to another client or turn a
  RETURN or TRANSFER into REGULAR.
- Half the advices carry a comment. That count does **not** show how many were written through saveComment rather than
  at creation (OMS or import); `modified` cannot tell them apart.
- Function holders on dev (from the SBDEV-3183 census, 2026-10-22): 42 of the 53 function-holding users hold
  INBOUND_BOL and 44 hold CYCLECOUNT. While the tenant is at OFF, any `wms_user` can PATCH.

## 3. Manual-test precondition counts (2026-10-22, q.sh)
```sql
select state, count(*), count(*) filter (where coalesce(comment,'')<>'') with_comment, max(length(comment)) from advice group by 1 order by 2 desc;
-- FINISHED | 12530 | 6443 | 89
-- OPEN     |    96 |    0 |
-- So every one of the 6,443 commented advices is FINISHED: the all-states and FINISHED figures coincide.
select state, count(*), count(*) filter (where coalesce(comment,'')<>'') from cyclecount where state not in ('FINISHED','CANCELLED') group by 1;
-- CREATED | 99 | 55
```
