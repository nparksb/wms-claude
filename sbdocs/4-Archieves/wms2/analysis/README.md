---
title: "Archived — WMS v2 Closed Investigations"
type: index
status: active
version: v2
scope: archives
updated: 2026-06-16
tags: [moc, index, archive, wms2, analysis]
---

# Archived — WMS v2 Closed Investigations

Cold storage for finished WMS **v2** investigations & root-cause reports (the v2 counterpart to [../../wms1/analysis/](../../wms1/analysis/)). Active investigations live in [../../../1-Projects/](../../../1-Projects/); reports-in-progress live in [../../../3-Resources/reports/](../../../3-Resources/reports/).

See also: [archives index](../../README.md) · [vault index](../../../INDEX.md)

---

## Contents

*(currently empty — no v2 investigations have been archived here yet.)*

Closed v2 investigations land here when they graduate from `3-Resources/reports/` or `1-Projects/`. Until then this folder reserves the documented category referenced by [../../README.md](../../README.md) and [../../../INDEX.md](../../../INDEX.md).

---

## Dataview — archived v2 investigations

```dataview
TABLE type AS "Type", scope AS "Scope", updated AS "Archived"
FROM "4-Archieves/wms2/analysis"
WHERE type != "index"
SORT updated DESC
```
