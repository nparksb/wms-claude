---
title: "{{title}}"
type: workflow
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
  - workflow
---

# {{title}}

**Workflow:** {{scope}} | **Version:** {{version}}
**Owner:** {{owner}} | **Last verified:** {{last_verified}} ({{verified_by}})

---

## 1. Purpose

<!-- What business outcome this workflow delivers. Who benefits. -->

---

## 2. Actors

| Actor | Role | Access method |
|-------|------|---------------|
| | | |

---

## 3. Triggers

<!-- What starts this workflow: UI action, scheduled job, incoming event, external webhook. -->

| Trigger | Where | Precondition |
|---------|-------|--------------|
| | | |

---

## 4. Preconditions

- <!-- e.g., inventory state, user permissions, config toggles -->

---

## 5. Happy Path

<!-- Numbered step-by-step. Cite the controller/service/screen that implements each step. -->

1. **{{Step}}** — *Actor* does X → *System* records Y at `File.java:NN` / `screen.vue:NN`
2.

---

## 6. Swimlane (optional)

```
User            UI                API                DB
 |              |                  |                  |
 |---action---->|                  |                  |
 |              |---POST---------->|                  |
 |              |                  |---INSERT-------->|
 ...
```

---

## 7. State Transitions

| Entity | From | Event | To | Enforced by |
|--------|------|-------|----|-------------|
| | | | | |

---

## 8. Alternate Paths & Edge Cases

<!-- One sub-section per variant. -->

### 8.1 {{Variant}}

### 8.2 {{Variant}}

---

## 9. Error & Exception Flows

| Error | User-visible | System action | Recovery |
|-------|-------------|---------------|----------|
| | | | |

---

## 10. Business Rules

<!-- Rules that MUST hold. Cite the code location that enforces each one. -->

- **Rule:** <!-- statement --> | **Enforced by:** `File.java:NN`

---

## 11. Cross-system Interactions

<!-- OMS ↔ WMS calls, Keycloak checks, notification channels, external carriers. -->

---

## 12. Screens / UI references

| Screen | Path | UI project | Purpose |
|--------|------|-----------|---------|
| | | | |

---

## 13. Glossary

| Term | Definition |
|------|-----------|
| | |

---

## 14. Related Docs & ADRs

- <!-- link -->

---

## 15. Verification Log

| Date | What was checked | Result | Checked by |
|------|-----------------|--------|------------|
| | | | |
