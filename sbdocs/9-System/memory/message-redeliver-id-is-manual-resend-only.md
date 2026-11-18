---
name: message-redeliver-id-is-manual-resend-only
description: "wms2 message.redeliver_id is set only by a manual Service Log resend; \"redeliver_id null\" does not mean an OMS notification was never redelivered — match md5(message) instead"
metadata:
  node_type: memory
  type: project
  originSessionId: 9836283e-d192-455f-be56-9acf97836704
  modified: 2026-10-28T00:41:27.614Z
---

`message.redeliver_id` is set only when an operator resends from the Service Log. Outbox retries write fresh `message` rows with no link back. So "FAILED rows with redeliver_id null → 0 redelivered" is a false alarm.

**Why:** On 2026-10-27 a SBDEV-3672 comment flagged 28 WineCo `ORDER_BATCH_SHIPPED` FAILED rows as never redelivered. Matching on `md5(message)` showed all 23 distinct payloads were later sent with 200 Success. Outbox rows that seem to "exist only from date X" are the SENT retention purge, not a direct send path.

**How to apply:** To prove delivery, match a later non-FAILED `message` row with the same `md5(message)` and `created` > the failure. Never use `redeliver_id` for this.

Related: the same session found SBDEV-3672 marked "parked" in ClickUp and the plan while its PRs had merged and shipped to PRD. Check `gh pr view` state before trusting a parked label (see [[plan-state-probe-beats-reading-plan-status]]).
