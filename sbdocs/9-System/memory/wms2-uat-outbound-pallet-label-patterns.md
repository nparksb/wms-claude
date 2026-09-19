---
name: wms2-uat-outbound-pallet-label-patterns
description: "\"String is not valid\" on mobile palletizing = scanned pallet label failed two sysprop regexes; Hydra UAT accepts only AOUT-/OUT-/WC_ forms, and Postgres ~ lies about them"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 3a4dfda1-ae96-4231-b8fb-1643f798e979
  modified: 2026-08-14T17:27:53.329Z
---

`noValidString` → `String is not valid: '<scanned>'` on the **mobile** palletizing screen means the scanned
pallet label neither already exists as a unit load nor matches either configured pattern. Thrown from
`MobilePalletizingService` `scanPallet:189,227` / `scanPalletBulk:282,309`. The accepted set is the OR of
`STRING_PATTERN_OUTBOUND_PALLET` (used as a regex directly) and `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL`
(converted by `StringConverter.convertFormatToRegex`).

On **Hydra UAT** (2026-08-14) that resolves to exactly: `AOUT-######`, `OUT-######`, `OUT######`,
`WC_<16 digits>` — nothing else. Filed as SBDEV-2962 (message never states the expected format).

**How to apply:** to unblock a palletizing test, read both sysprops for the tenant and hand QA a conforming
label (next in sequence — on Hydra UAT the last outbound pallet was `AOUT-000118`). Absence of any new
`Pallet`-type `unitload` row on the test date confirms the label was rejected rather than something upstream.
Only the **mobile** path throws this: `scanPallet.vue:43` sends the raw scanned value with no auto-generate,
whereas the **web** popup (`palletizeOutboundParcel.vue` → `/billOfLading/palletize`) offers
"Leave blank to create new pallet". So this error localises the failure to mobile.

LANDMINE — never test these patterns with Postgres `~`. `'AOUT-000119' ~ ('^'||sysvalue||'$')` returns **true**
because `^`/`$` bind only to the first/last alternative of an unparenthesised alternation, so it matched the
middle branch `OUT-\d{6}` unanchored; Java's `String.matches` is fully anchored and returns **false** for that
sysprop. Do check `length(sysvalue)` though — a doubled backslash would break *every* label, and length is the
cheap way to rule it out (28 chars = single-backslash on Hydra UAT).

Related: [[wms2-client-without-section-silently-stalls-pickpack]],
[[wms2-businessexception-key-vs-message-traps]] (assert `getKey()`, not the rendered message).
