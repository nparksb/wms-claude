---
title: "{{title}}"
type: architecture
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
  - architecture
---

# {{title}}

**Scope:** {{scope}} | **Version:** {{version}}
**Owner:** {{owner}} | **Last verified:** {{last_verified}} ({{verified_by}})

---

## 1. Overview

<!-- What system/subsystem does this doc describe? Who uses it? What does it do? Keep to 2–4 sentences. -->

---

## 2. Topology

<!-- ASCII box diagram of major components and their connections. External systems on the edges. -->

```
[Client]  →  [Controller]  →  [Service]  →  [Repository]  →  [PostgreSQL]
                                  ↓
                           [Business Service]
                                  ↓
                           [External: Keycloak | OMS | Printer]
```

---

## 3. Tech Stack

| Layer | Technology | Version | Notes |
|-------|-----------|---------|-------|
| Runtime | | | |
| Framework | | | |
| Database | | | |
| Auth | | | |
| Build | | | |
| Observability | | | |

---

## 4. Layered Architecture

<!-- One sub-section per layer. Cite representative classes with file paths. -->

### 4.1 Controller Layer

### 4.2 Service Layer

### 4.3 Business / Domain Layer

### 4.4 Repository / Persistence Layer

### 4.5 Data Layer

---

## 5. Key Components

| Component | Responsibility | Representative File |
|-----------|---------------|---------------------|
| | | |

---

## 6. Integrations

| System | Protocol | Direction | Purpose | Auth |
|--------|---------|-----------|---------|------|
| | | | | |

---

## 7. Deployment Topology

<!-- Environments, replica count, DB topology per tenant, CI/CD pipeline shape. -->

---

## 8. Cross-cutting Concerns

### 8.1 Multi-tenancy
### 8.2 Authentication & authorization
### 8.3 Caching
### 8.4 Metrics, tracing, logging
### 8.5 Transaction management

---

## 9. Non-functional Characteristics

| Attribute | Current | Target / SLO | Measurement method |
|-----------|---------|--------------|---------------------|
| Throughput | | | |
| Latency (p95) | | | |
| Availability | | | |
| Max tenants / replica | | | |

---

## 10. Known Limitations & Tech Debt

- <!-- item, impact, tracking ticket -->

---

## 11. Related ADRs

- <!-- link to decisions/ADR-XXXX.md -->

---

## 12. Verification Log

| Date | What was checked | Result | Checked by |
|------|-----------------|--------|------------|
| | | | |
