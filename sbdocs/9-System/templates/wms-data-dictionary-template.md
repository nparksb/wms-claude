---
title: "{{title}}"
type: data-dictionary
status: draft
version: ""
scope: ""
owner: ""
created: ""
updated: ""
last_verified: ""
verified_by: ""
database: ""    # mysql-oms-v1 | mysql-oms-v2 | postgres-wms-v1 | postgres-wms-v2 | mongo-oms-v2
schema: ""
table: ""
related: []
tags:
  - data-dictionary
---

# {{title}}

**Database:** {{database}} | **Schema:** {{schema}} | **Table:** {{table}}
**Scope:** {{scope}} | **Version:** {{version}}
**Owner:** {{owner}} | **Last verified:** {{last_verified}} ({{verified_by}})

<!--
  One doc per logically-significant table (or per domain: "stockunit family").
  The goal is that anyone diagnosing a data issue can answer: what do
  these columns MEAN, what values are valid, and what guarantees hold.
-->

---

## 1. Purpose

<!-- What business concept does this table represent? Single sentence. -->

---

## 2. Source of Truth

<!-- Where is this data written from? Which service / controller / stored proc? -->

| Writer | File / Proc | Operation |
|--------|-------------|-----------|
| | | INSERT / UPDATE / DELETE |

---

## 3. Columns

| # | Column | Type | Nullable | Default | Meaning | Valid values / range | Notes |
|---|--------|------|----------|---------|---------|----------------------|-------|
| 1 | id | bigint | NO | auto | | | |
| 2 | | | | | | | |

<!-- For enum-like columns, spell out EVERY valid value and what it means.
     Enum-like fields are the most common source of cross-system confusion. -->

### 3.1 Enum Values — {{column}}

| Value | Meaning | When set | Terminal? |
|-------|---------|----------|-----------|
| | | | |

---

## 4. Primary Key & Uniqueness

- **PK:** <!-- -->
- **Unique constraints:** <!-- -->

---

## 5. Foreign Keys

| Column | References | On delete | On update | Enforced? |
|--------|-----------|-----------|-----------|-----------|
| | | | | DB / app-level |

---

## 6. Indexes

| Index | Columns | Used by |
|-------|---------|---------|
| | | |

---

## 7. Invariants (what MUST always be true)

- <!-- e.g., `state >= 600` implies `picking_completed_at IS NOT NULL` -->

---

## 8. Cross-Database Relationships

<!-- CRITICAL for OMS ↔ WMS reconciliation work. List the logical joins that cross database boundaries, even though they are not enforced. -->

| This column | Points to (conceptually) | Other DB | Other table.column | Reconciliation query |
|-------------|--------------------------|----------|--------------------|-----------------------|
| | | | | |

---

## 9. Lifecycle

| Phase | Triggered by | Columns affected | Notes |
|-------|-------------|------------------|-------|
| Insert | | | |
| Update | | | |
| Soft-delete | | | |
| Hard-delete | | | |

---

## 10. Known Issues / Gotchas

- <!-- e.g., "orphaned rows when picking order canceled before Phase 7 rollout" -->

---

## 11. Common Diagnostic Queries

<!-- Snippets that answer frequent operator questions. Read-only only. -->

```sql
-- {{what this answers}}
SELECT ...
```

---

## 12. Related Docs

- Schema migration: <!-- -->
- Architecture (owning subsystem): <!-- -->
- Reconciliation runbook: <!-- -->

---

## 13. Verification Log

| Date | What was re-checked | Against what | Result | Checked by |
|------|---------------------|--------------|--------|------------|
| | | | | |
