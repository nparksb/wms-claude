---
title: "{{title}}"
type: design
status: draft
version: ""
scope: ""
owner: ""
created: ""
updated: ""
last_verified: ""
verified_by: ""
related: []
tags:
  - design
---

# {{title}}

**Module / Subsystem:** {{scope}} | **Version:** {{version}}
**Owner:** {{owner}} | **Last verified:** {{last_verified}} ({{verified_by}})

---

## 1. Purpose

<!-- What this module does, what business capability it supports, what it deliberately does NOT do. -->

---

## 2. Public API / Contract

<!-- Endpoints, method signatures, events emitted or consumed. For each: input, output, errors. -->

| Entry point | Type | Input | Output | Error behavior |
|-------------|------|-------|--------|----------------|
| | | | | |

---

## 3. Key Classes / Services

| Class | File | Responsibility | Notes |
|-------|------|---------------|-------|
| | | | |

---

## 4. Data Model

<!-- Entity-relationship view limited to what this module touches. Include FKs, unique constraints, enum values. -->

### 4.1 Entities

| Entity | Table | Key Fields | Invariants |
|--------|-------|-----------|------------|
| | | | |

### 4.2 Relationships

<!-- Parent → child FKs, mandatory vs optional associations. -->

---

## 5. State Machines

<!-- For every stateful entity, the allowed transitions. -->

### 5.1 `{{EntityName}} State`

| From | Event / Method | To | Guard / Precondition | Side effects |
|------|---------------|----|---------------------|--------------|
| | | | | |

---

## 6. Key Flows / Algorithms

<!-- Sequence-style description of non-trivial flows. ASCII sequence diagrams welcome. -->

### 6.1 {{Flow name}}

```
Actor    Controller    Service    Repository    DB
  |          |            |            |         |
  |---req--->|            |            |         |
  |          |---call---->|            |         |
  |          |            |---query--->|         |
  ...
```

---

## 7. Dependencies

### 7.1 Internal

| Depends on | Why |
|-----------|-----|
| | |

### 7.2 External

| System / Library | Purpose | Version |
|------------------|---------|---------|
| | | |

---

## 8. Extension Points

<!-- Where new behavior can be plugged in: strategy interfaces, config toggles, overrides. -->

---

## 9. Error Handling

| Failure | Detected by | Converted to | Client-visible |
|---------|------------|--------------|----------------|
| | | | |

---

## 10. Testing Approach

- Unit test classes: <!-- list -->
- Integration test classes: <!-- list -->
- What is deliberately not tested: <!-- list -->

---

## 11. Known Limitations

- <!-- item, impact, mitigation or ticket -->

---

## 12. Related ADRs & Docs

- <!-- link -->

---

## 13. Verification Log

| Date | What was checked | Result | Checked by |
|------|-----------------|--------|------------|
| | | | |
