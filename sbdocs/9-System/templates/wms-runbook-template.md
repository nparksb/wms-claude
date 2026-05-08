---
title: "Runbook: {{title}}"
type: runbook
status: active
version: ""
scope: ""
owner: ""
created: ""
updated: ""
last_verified: ""
verified_by: ""
alert: ""
severity: ""   # SEV1 | SEV2 | SEV3
escalation: ""
related: []
tags:
  - runbook
---

# Runbook: {{title}}

**Alert:** {{alert}} | **Severity:** {{severity}}
**Scope:** {{scope}} | **Version:** {{version}}
**Owner:** {{owner}} | **Last verified:** {{last_verified}} ({{verified_by}})

<!--
  Runbooks are for oncall use DURING an incident. Keep every section
  scannable. Command-level specificity. No paragraphs when a bullet works.
-->

---

## 1. When to Use This Runbook

<!-- Exact alert name, symptom, or user report that maps to this runbook. -->

- Triggered by: <!-- alert / customer report / metric -->
- Do NOT use this runbook if: <!-- the distinguishing signal -->

---

## 2. Severity & Impact

| Aspect | Detail |
|--------|--------|
| User impact | |
| Blast radius (tenants / facilities) | |
| Is it a paging event? | Yes / No |
| SLO burn? | |

---

## 3. First 5 Minutes — Triage

- [ ] Confirm the symptom (command / URL / screen)
- [ ] Note start time and affected tenant(s)
- [ ] Check current deploy version: <!-- command -->
- [ ] Check recent deploys (last 60 min): <!-- link -->
- [ ] Is any other team already engaged?

---

## 4. Diagnosis — Find the Cause

<!-- Numbered checklist. Each step has a command, expected vs unexpected output, next step. -->

1. **Check X**
   ```
   <command>
   ```
   - If output is {{A}}, jump to §5.1
   - If output is {{B}}, jump to §5.2

2. **Check Y**
   ```
   <command>
   ```

---

## 5. Recovery Actions

### 5.1 {{Scenario A}}

- [ ] Step 1: `<command>`
- [ ] Step 2: `<command>`
- [ ] Verify: `<command>` returns `<expected>`

### 5.2 {{Scenario B}}

---

## 6. Escalation

| When | Who | How |
|------|-----|-----|
| If not resolved in 15 min | | |
| If requires DB admin | | |
| If customer-facing outage > 30 min | | |

---

## 7. Verification — Confirm Resolved

- [ ] User-visible symptom is gone: <!-- check -->
- [ ] Error rate returned to baseline: <!-- metric/query -->
- [ ] No orphan state left in DB: <!-- query -->

---

## 8. Post-incident

- [ ] Open post-mortem ticket
- [ ] Link incident to this runbook; update §4/§5 if steps were missing or wrong
- [ ] Add regression test if appropriate
- [ ] Update `last_verified` date in frontmatter

---

## 9. Related Docs

- Architecture: <!-- -->
- Known issues: <!-- -->
- Past incidents using this runbook: <!-- -->
