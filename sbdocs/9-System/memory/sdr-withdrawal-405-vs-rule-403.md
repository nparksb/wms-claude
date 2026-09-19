---
name: sdr-withdrawal-405-vs-rule-403
description: SDR write-withdrawal answers 405 to EVERY caller at OFF; an SdrFunctionRules rule answers 403 per-caller only at ENFORCE_RULED — an AC written for one cannot grade the other
metadata: 
  node_type: memory
  type: project
  originSessionId: a34585a3-3583-4328-a4f9-c2ab43b8dc7c
  modified: 2026-09-09T17:50:14.587Z
---

In wms2-api there are two different remedies for an exposed Spring Data REST surface, and they are
**not interchangeable as observables**:

| | `SdrFunctionRules` rule | `RestConfiguration.SDR_WRITE_WITHDRAWN` |
|---|---|---|
| Status | **403** | **405 Method Not Allowed** |
| Who is denied | callers lacking the function | **everyone**, fully entitled included |
| Effective when | only at `ENFORCE_RULED` — as of 2026-09-09 **no tenant is there**, all at `OFF` | immediately, at `OFF` |
| Verb scope | verb-blind — takes the reads too | write verbs only (`collection:POST`, `item:PUT/PATCH/DELETE`) |

**Why it matters:** SBDEV-3183's AC-3 demanded `PATCH /v3/customerorder/{id}` move *"open → 403 for a
zero-function caller, with an **entitled control** proving the fix is not deny-all."* The fix that
shipped was withdrawal. Graded literally, a **correct** fix fails that AC — and the failure reads as
the gate being broken. The entitled-control clause is unsatisfiable against withdrawal, which is
deny-all on the write verbs by design. Reworded 2026-09-09 (Nam).

**How to apply:**
- Before writing an authz AC for an SDR surface, decide which remedy it is for, and state the status
  code that remedy actually produces. Do not write `403` reflexively.
- The over-gating rail for a **withdrawal** cannot be an entitled write control — there is none.
  Put the rail on the **read** axis instead (the UI's searches and item reads must still return 200).
- Prefer withdrawal when the type has no live writer: it closes at `OFF`, so it works today, whereas a
  rule closes nothing until the guard-mode rollout happens. See [[wms2-sdr-is-gatable-via-mappedinterceptor-bean]].
- Withdrawal is a same-hand list — pin it **behaviourally** off `ResourceMappings.getSupportedHttpMethods`,
  not by list membership, or moving a name between lists keeps the test green. Note such a pin
  typically iterates `COLLECTION` and `ITEM` only, **not** `ASSOCIATION` — see
  [[wms2-sdr-association-resource-verb-reality]].

Related: [[consolidate-tickets-dont-file-one-per-finding]], [[green-tests-that-prove-nothing]].
