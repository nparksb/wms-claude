# SBDEV-3873 decisions (Nam, 2026-10-22, before plan review)

- **D1 Cycle Count:** option B. The web PR deletes the cycle-count `saveComment` action and the `comment` watcher in
  `plannedCycleCountDescription.vue`; the box is `readonly` on `origin/main`, `release` and `develop` alike (checked
  2026-10-22). No new cycle-count endpoint. PR 2 withdraws PATCH on both types.
- **D2 Endpoint:** `POST /v3/advice/setComment`, body `{id, comment}`, `@RequiresFunction(WEB_UI_VIEW_INBOUND_BOL)`.
- **D3 Length:** reject a comment over 255 characters with 400, and leave the row unchanged. The web PR adds
  `maxlength="255"` to the closed-notice textarea.
- **D4 PR 2 timing:** PR 1 and the web PR go first. PR 2 merges to wms2-api `develop` only once the web change is confirmed
  on web-ui `main` (PRD).

## After ralplan round 1 (Nam, 2026-10-22)
- **D5 Stop-gap in PR 1:** mark every field declared on `Advice` except `comment`, and every field declared on `Cyclecount`,
  `@ReadOnlyProperty`, so the existing SDR PATCH can change only the Advice comment. Withdrawal still follows in PR 2.
- **D3 amended:** an over-long comment returns **422** (`ApiInvalidParameterException`, house convention; SBDEV-3545
  precedent), not 400.
