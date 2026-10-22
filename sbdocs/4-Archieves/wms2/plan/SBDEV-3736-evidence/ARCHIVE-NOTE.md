# SBDEV-3736 evidence: archived 2026-10-15

- **No plan document:** SBDEV-3736 ran as T2 bullets on the ticket. This folder is its evidence.
- **Status:** [SBDEV-3736](https://app.clickup.com/t/868mg9b5t) is `on dev`. PR #518 merged into wms2-api `develop` as `a05e8998` and was dev-tested (ticket comments of 2026-10-15).
- **Findings dispositions (archive gate).** Everything here is also recorded on the ticket.
  - **S4–S6 (oms-laravel-api):** [SBDEV-3768](https://app.clickup.com/t/868mhnnn8), filed.
  - **Returns Audit UI page:** [SBDEV-3769](https://app.clickup.com/t/868mhnnp9), filed.
  - **R3-L2 TRANSFER half:** [SBDEV-3775](https://app.clickup.com/t/868mhrfy3). Fixed in #519 and on dev.
  - **OMS↔WMS mismatch flag:** dropped by design. It is a support query, now part of SBDEV-3768.
  - **S7 (`return_item` signed tinyint) and the partial index on `unitload_record (ordernumber, label)`:** proposed T3, recorded on the ticket, not filed.
  - **`fixes-r1.md` "Not fixed" #1** (adjust after an over-key leaves the advice OPEN): fixed later on this ticket. The S8 finisher runs on adjust/delete (`0e9e3c5b`, dev-tested).
  - **`fixes-r1.md` #2** (decorative `@DateTimeFormat`) and **#3** (no advice-row lock): accepted as-is.
  - **Residual windows** (a finisher deadlock between two simultaneous completing receives; a late sibling adjust): documented on the ticket and accepted.
- **Worktrees:** `wms2-api/SBDEV-3736` was already removed before this archive. The local branch is gone.
- **Note:** the merge-time edits on #518 (`5d84a4d5`, `304f7925`, `f6445546`) are described in the 3755 archived plan, §12.1.
