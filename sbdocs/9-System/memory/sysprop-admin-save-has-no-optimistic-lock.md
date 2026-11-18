---
name: sysprop-admin-save-has-no-optimistic-lock
description: "wms2 web-ui SDR writes send If-Match: sysprop (4032/4046), group/shipper/packaging edits + packaging/section/location deletes (4066); SDR PUT nulls omitted fields; SDR FK 409 body leaks SQL"
metadata:
  node_type: memory
  type: project
  originSessionId: 6e6ca462-0151-46bb-8bff-76d02a0cf5f6
  modified: 2026-11-05T19:50:48.960Z
---

Measured on dev on 2026-11-06 (SBDEV-3310, PR #623). `wms2-web-ui` `store/admin/configuration.js` saves with `$put('/sysprop/{id}', item)`. The SDR JSON for sysprop has no `version` field, and the UI sends no `If-Match`. A stale PUT carrying the old text returned 200 and overwrote the row (version 2→3), with no conflict.

The server side works. GET returns `ETag: "<version>"`, and a PUT with a stale `If-Match` gets **412** with nothing written. Only the UI never sends `If-Match`. Filed as **SBDEV-4032** (2026-11-06), with option 1 preferred: the edit dialog GETs the item for its ETag. A collection (`findByGroupname`) response has no per-item ETag. To read response headers on dev without printing the token, `curl -D - -H @$HDR_FILE` after sourcing the probe's `env.sh`.

**Why:** V2.2.48 bumped `version` claiming that it would make a stale admin save fail, and the review approved that claim. It was false, and the applied migration's comment cannot be corrected. Two admins editing one sysprop silently overwrite each other.

**How to apply:** don't cite `@Version` as protection for any SDR-exposed entity until you've confirmed that the client sends `If-Match`. Test the stale save on dev (snapshot first) before writing that claim into an immutable file. Related: [[club-oms-chunking-rollout-dropped]], [[wms2-flyway-migration-facts-corrected]].

**Fixed (SBDEV-4032, on dev 2026-11-06):** wms2-api #632 exposes `ETag` via CORS. Before, the browser could not read it at all: `access-control-expose-headers` listed only two custom headers. wms2-web-ui #196 sends `If-Match` from `util/ifMatch.js`. Other screens that PUT Spring Data REST `@Version` entities without `If-Match` are still open and listed on SBDEV-4032: client, cyclecount, customerorder, boxtype, advice, userGroup. Reuse `util/ifMatch.js` for them.

**Sysprop DELETE guarded (SBDEV-4046, wms2-web-ui #199 `ff2f42e8`, on dev 2026-11-06):** SDR checks `If-Match` on DELETE as on PUT (stale gets 412, row kept; none deletes a changed row). `deleteIfMatch` is in `util/ifMatch.js`. The delete dialog reads the row on open, the same way the edit dialog does. A 404 on DELETE is reported as "already deleted" (info toast). Trap: `adminReadLoggingSweep` reads any line-start `name({` in a store file as a new action, so a call like `reloadList({ clear: true })` inside an action breaks the log-label check. Use a plain argument.

**Spring Data REST PUT trap (measured):** a PUT nulls every field the body omits (`DomainObjectReader.mergeForPut`). `@CreatedDate` is never re-stamped on update, so stripping `created` from a PUT body erases it. The old sysprop dialog did exactly that: PRD has 2–7 `los_sysprop` rows with `created IS NULL` per tenant, and dev has 8. Drop only `_links`.

**Siblings guarded (SBDEV-4066, wms2-web-ui #200 `0db4246d` + #201 `71b70ba6`, on dev 2026-11-07):** group, shipper and packaging edits read with ETag on open (`util/sdrRead.js` readWithEtag); packaging, section and storage-location deletes go through `mixins/guardedDelete.js` (read before confirming, refuse if the list row's `modified` moved: `changedSinceList`) and `deleteRowIfMatch`. The "6 sibling screens" list was wrong in three ways, all found by probing, not by reading the list: the advice item DELETE answers **405** (RestConfiguration withdraws PUT/DELETE) and its buttons are commented out; cyclecount/advice comment PATCHes belong to SBDEV-3873 (#180); `updateCustomerOrder` had no caller (removed); and section + location had live unguarded DELETEs nobody had listed. `/locationType` DELETE is 405 too.

**Trap: an SDR DELETE refused by a foreign key is a 409 whose body is SDR's own `{cause, message}` with the raw Hibernate SQL in `message`.** `apiErrorReason` relays it, so any store that toasts `classified.message` shows SQL. **Fixed centrally by SBDEV-4069 (#202 `885929e7`, on dev 2026-11-07):** `isSdrConstraintConflict` (409 + `cause` + no `title`) — `apiErrorReason` returns null for it, `adminWriteError` gives CONSTRAINT_CONFLICT_ERROR with `conflict: true`, deleteRowIfMatch reads that flag. Any NEW code that reads `data.message` / `data.detail` itself (putawayWriteError and labelPrinting detailOf did) bypasses the guard: check `isSdrConstraintConflict` first. wms2-api's `handleConstraintException` writes an UNtitled `{error}` 409, so 'no title' alone is not the SDR shape. Measure a refusal's body on dev before relying on its message: the unit fixture was hand-written and could not show this; only the dev browser test did.

