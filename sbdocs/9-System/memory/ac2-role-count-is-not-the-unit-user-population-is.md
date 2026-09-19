---
name: ac2-role-count-is-not-the-unit-user-population-is
description: When judging whether a WMS v2 function gate will 403 real operators, count USERS not roles — the role axis was wrong in both directions on three checks
metadata:
  type: reference
---

Measured 2026-08-28 on `dev_wh01_om1` while implementing SBDEV-3017 tranche 1.

**A function's role list tells you nothing about who it denies.** `WEB_UI_VIEW_SYSTEM_PROPERTY` has
**1 role** (`super-admin`) and **38 users** — the narrowest-looking constant in the catalogue is among
the widest, because one role hangs off the group everyone is in. Conversely `WEB_UI_VIEW_CLIENT` and
`WEB_UI_VIEW_PRINTER` list 3 roles of which 2 are opaque `ROLE000xxx` rows, which reads as "no named
business role holds this" — they also reach 38 users.

Three separate role-name verdicts were re-checked against user populations. **Two were wrong, in
OPPOSITE directions**, so the failure mode is not a consistent bias — the role axis is uninformative:

| claim | source | measured |
|---|---|---|
| `_VIEW_CLIENT`/`_PRINTER` gate screens no named role holds | my own | ❌ 38 users each |
| gating `advice/create` + `receiving/*` breaks CS-REP | plan §9.7.1 | ❌ 1 user, and it is `Z-…(archived)` |
| `WEB_UI_ACTION_PRINT_TOTE_LABELS` would cause an outage | plan §8.2 | ✅ 7 LIVE users — right conclusion, but NOT for the stated reason ("super-admin-only" is false; it has 38 users, just a *different* 38 from the screen's 46) |

**The query.** AC-2′ ("every role that can reach the dispatching screen must hold a function in the
endpoint's set") must be evaluated as *users holding the screen's function minus users holding the
endpoint's*:

```sql
mywms_function -> mywms_role_mywms_function(functionlist_id, rolelist_id)
              -> mywms_role -> mywms_group_mywms_role(rolelist_id, grouplist_id)
              -> mywms_group -> mywms_group_mywms_user(grouplist_id, userlist_id) -> mywms_user
```

Validate the join direction against a known-good pair before trusting it (`WEB_UI_VIEW_RECEIVING`
= `{receiving, super-admin}`) — see [[sbdev-3005-role-function-composite-key-swap]], the key has been
reversed before. **Include a self-pair control row** (screen fn = endpoint fn, must yield 0 victims);
without it a query that returns 0 everywhere looks like good news.

**Discount `Z-…(archived)` accounts** before calling anything a break — they are the majority of the
"denied" population on most of these pairs.

Related: [[sbdev-3017-tranche1-mvc-gating]], [[wms2-wms-admin-confers-zero-functions]],
[[advertised-capability-is-not-exploitable-capability]].
