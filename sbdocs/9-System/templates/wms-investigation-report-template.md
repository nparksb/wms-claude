---
title: "{{title}}"
type: investigation
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
  - investigation
  - report
---

# {{title}}

**Topic:** {{scope}} | **Version:** {{version}}
**Started:** {{created}} | **Investigator:** {{owner}}
**Status:** {{status}}  <!-- open | concluded | archived -->

---

## 1. Context & Trigger

<!-- Why are we investigating? Incident, customer complaint, metric anomaly, tech-debt audit, pre-feature groundwork. Link ticket/alert/commit that prompted this. -->

---

## 2. Questions

<!-- The specific questions this investigation aims to answer. Keep to 1–5. If the list grows, split into multiple reports. -->

1. <!-- question -->
2.

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence | Rationale |
|---|-----------|-------------------|-----------|
| H1 | | low / medium / high | |
| H2 | | | |

---

## 4. Method

<!-- How the investigation was conducted: code read, log analysis, DB queries, metric inspection, reproduction steps, interviews. -->

- <!-- step or data source -->

---

## 5. Evidence

<!-- Structured findings. Tie each piece of evidence back to a hypothesis. -->

### 5.1 {{Finding name}}

**Source:** `file:line` / log / query / metric
**Observation:** <!-- what was seen -->
**Supports:** H1 | H2
**Contradicts:** <!-- if any -->

### 5.2 {{Finding name}}

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Key evidence |
|---|-----------|------------------|--------------|
| H1 | | | |
| H2 | | | |

---

## 7. Verdict

<!-- One or two paragraphs stating what is (likely) true, and what remains uncertain. Lead with the conclusion. -->

**Confidence:** <!-- low | medium | high -->

---

## 8. Recommendation

<!-- Pick one and justify: -->

- [ ] **Fix now** — open a bugfix plan: <!-- link -->
- [ ] **Fix later** — track under: <!-- ticket -->
- [ ] **Do NOT fix** — rationale:
- [ ] **Monitor** — signals to watch:
- [ ] **Investigate further** — what's needed:

---

## 9. Open Questions

<!-- What we could not answer with the evidence at hand. Each one is a candidate follow-up investigation or data-collection task. -->

- <!-- question + why it matters -->

---

## 10. References

- **Related plans:** <!-- -->
- **Related ADRs:** <!-- -->
- **Commits / PRs:** <!-- -->
- **Tickets:** <!-- -->
- **Logs / queries (preserved):** <!-- attach or link -->

---

## 11. Verification Log

| Date | What was re-checked | Result | Checked by |
|------|---------------------|--------|------------|
| | | | |
