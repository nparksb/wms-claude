---
name: papa-dynamictyping-makes-csv-cells-numbers
description: "wms2-web-ui CSV uploads parse with Papa dynamicTyping:true — a \"0\" cell is the NUMBER 0, so `!x` rejects shipper 0; don't clear a truthiness guard as \"it's a CSV string\""
metadata:
  node_type: memory
  type: feedback
  originSessionId: 1a72a604-c3e2-417c-b189-8cae010ac5bb
  modified: 2026-10-06T22:25:14.696Z
---

The upload components in wms2-web-ui (`components/admin/systemManagement/uploads/*.vue`) parse CSV
with `Papa.parse(..., { dynamicTyping: true })`. Cells come back as numbers, booleans and `null`, not
as strings: `0` → `0`, `false` → `false`, blank → `null`, `0042` → `42`.

**Why:** in the SBDEV-3437 sweep I cleared `inboundBolUpload.vue`'s `if (!clientId)` with the
reasoning "a CSV cell is a string, so '0' is truthy". That was wrong; the independent review caught
it. The upload rejected System-Client (id 0) as "cannot be empty". Related: [[green-tests-that-prove-nothing]].

**How to apply:** when sweeping for truthiness guards on ids, check the parser options before
assuming a value's type. For a numeric-id cell, use `x == null || x === ''` for "empty" plus
`Number.isInteger(x)`, because the backend `Long.parseLong`s it and a bad cell fails the whole upload.
