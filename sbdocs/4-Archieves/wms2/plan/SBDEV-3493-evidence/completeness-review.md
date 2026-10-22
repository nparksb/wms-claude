# SBDEV-3493 — completeness + claim-discipline review (T2 lane 2 of 2)

- Reviewer: critic lane, 2026-09-24. Read-only. No Maven, no checkout.
- Subject: worktree `.claude/worktrees/wms2-api/SBDEV-3493` @ `38ba14ac` (base `45433631`).
- Ticket: SBDEV-3493 (ClickUp 868m9d9xn), `floor.md` in this dir.

## VERDICT: REQUEST CHANGES (small)

I found no defect in the diff, and tenants that have the patterns configured see no behaviour change. What I am
rejecting is the completeness claim, which is true only as the sweep framed it: "an unset label-pattern
sysprop reaches a **`.matches(`** call". Read by **key** — which is how the ticket title reads ("Unset
label-pattern sysprops crash 7 scan paths") — it is false:
- `PRINTING_PATTERN_OUTBOUND_PALLET_LABEL` is one of the five keys, and it crashes two more paths through
  `String.format`.
- A whitespace-only printing pattern still crashes all 6 `convertFormatToRegex` call sites the ticket touches.
  The admin UI accepts that value.

The fix is one line plus two small guards, all sub-T3, and I recommend adding them to this ticket (see "Candidates").

## Method (item 1) and its blind spots

The instrument was `git grep` on `HEAD -- src/main/java` for:
- `Pattern.compile(` with a non-literal argument
- `Pattern.matches(`, `::matches`, `.matcher(`, `asPredicate` / `asMatchPredicate`
- `.split(` / `replaceAll(` / `replaceFirst(` with a non-literal argument
- `String.format(` / `.formatted(` with a non-literal format argument
- `MessageFormat`, `SimpleDateFormat(var)`, `DateTimeFormatter.ofPattern(var)`
- every caller of `convertFormatToRegex` / `describeExpectedFormat`

I then traced each hit back to see whether its input is a sysprop.

Positive controls:
- the `String.format` pass found the already-known `ParcelMonitorViewService:131`.
- the `.matches(` pass found all 7 fixed sites plus the 2 guarded ones.

Blind spots:
- The trace went back only through local variables. A sysprop value carried through a field, a DTO or another
  bean before it reaches a regex/format call would be missed.
- Non-`String` sinks were not swept: `parseInt` on a sysprop throws NumberFormatException on null (5 sites).
  That is a different crash class and out of scope.
- `los_sysprop` values that the web UI consumes are not covered.

Results:
| Sink | Site | Input | State on HEAD |
|---|---|---|---|
| `Pattern.compile(var)` | — | — | 0 hits (every compile call is on a literal) |
| `.matcher(` / `.matches()` on a Pattern | IdempotencyFilter:256, LabelPrintingService:634/733/767/927, StringConverter:154 | constants | safe |
| `.split(var)` / `replaceAll(var)` | none on sysprops | — | safe |
| `String.format(sysprop, n)` | **ParcelMonitorViewService.palletise:131** (create-by-system branch) | PRINTING_PATTERN_OUTBOUND_PALLET_LABEL | **null → NPE → HTTP 500** (BillOfLadingController:526-531 catches only Business/FacadeException) |
| `String.format(sysprop, n)` | **BillofladingService.transferOrder:856** | PRINTING_PATTERN_OUTBOUND_PALLET_LABEL | **null → NPE** |
| `String.format(sysprop, n)` | **OrderMonitorViewService.printToteLabels:184** | PRINTING_PATTERN_DEFAULT_TOTE_LABEL (the client-specific `""` is rejected at :166; the default key is not guarded) | **null → NPE** |
| `String.format(sysprop, n)` | LabelPrintingService.formatToteId:974 | tote pattern | guarded (:906 null/blank) |
| `String.format` | BasicService:52-100 | hard-coded `%1$06d` | safe |
| `convertFormatToRegex(sysprop)` | ParcelMonitor:148, MoveUnitload:548/614, PalletizeWrite:276/465, Guard:66 | PRINTING_PATTERN_OUTBOUND_PALLET_LABEL | null/`""` → `""` (safe); **`" "` → ArrayIndexOutOfBounds** (see F2) |
| `describeExpectedFormat` | all callers | — | cannot throw (catches RuntimeException) |

## Findings

### F1 — MEDIUM: the same key crashes two more paths through `String.format` (item 4: in scope by key)
- Evidence: `ParcelMonitorViewService.java:131` reads `String palletLabel = String.format(patternOutboundPalletLabel, n);`
  in the `createPalletBySystem` branch. `BillOfLadingController:512-515` takes that branch whenever `palletName` is null or `""`.
- The branch is live on Hydra prd: `unitload` has 3 `AOUT-%` labels, which match Hydra's printing pattern `AOUT-%1$06d`.
- `BillofladingService.java:856` (transferOrder) does the same thing.
- If the row is unset, the value is null and `Formatter.parse(null)` throws NPE, which surfaces as a 500. This is
  exactly the failure the ticket is about, on one of its five keys, and only 16 lines above a line the commit changed.
- If the value is `""`, it is **worse than a crash**: `String.format("", n)` returns `""`, and
  `UnitloadService.createUnitload("")` (:199-211) finds or creates a unit load labelled `""`. Every
  system-created pallet would then collapse onto that one row, silently. The same thing happens with any
  pattern that has no `%d`.
- Fix: before the format call at both sites, add
  `if (p == null || p.isBlank()) throw new BusinessException(<names the key>)`.
  - Better: also reject a pattern whose output does not change with `n`. `LabelPrintingService.rejectNonIncrementingPattern:989` is prior art.
- Sub-T3 (T1 shape). **Add to this ticket.**

### F2 — MEDIUM: a whitespace-only printing pattern still crashes every site this commit touches
- Evidence: `StringConverter.convertFormatToRegex:29` only guards `format == null || format.isEmpty()`. For
  `" "`, `split("-")` returns `[" "]`, and `split[1]` throws `ArrayIndexOutOfBoundsException`.
- The exception is thrown **before** `matchesConfiguredPattern` runs, at all 6 call sites.
- `getSysvalue(String)` (SyspropService:334 → `findSysvalueBySyskey`, native query) does **not** trim. Only
  `getStringDefault` trims.
- The Admin > Patterns and Labels edit dialog stores the value from an unvalidated `v-textarea`
  (`wms2-web-ui components/admin/parametersAndConfiguration/editParamAndConfig.vue:43-50`, no `rules`) through
  `PUT /v3/sysprop/{id}`. `/v3/systemProperty/updateValue` (SystemPropertyController:148-176) also saves the
  value verbatim.
- Clearing the textarea to a space or a newline is therefore the same "blanked row" state the ticket counts as
  reachable, and it is still a 500.
- The new tests cover only null and `""` (diff of src/test: no `" "` case).
- Fix: change `convertFormatToRegex` to `format == null || format.isBlank()`. That is one line and covers all 6
  callers. Add one test per converter.
  - Optional consistency fix: `matchesConfiguredPattern` and `handleTruckOffLoading*` use `isEmpty` while
    `isToteLabel` and the inbound fallback use `isBlank`. With `pattern = " "` and no printing pattern, the purge
    runs, matches nothing, and **skips its WARN**. Use `isBlank` throughout.
- Malformed but non-blank printing patterns (no `-`, a width shorter than 2 digits, a non-digit width) also
  throw from the converter (AIOOBE / SIOOBE / NumberFormatException). That is "misconfigured", not "unset", so
  it is out of this ticket's claim. See Proposals.

### F3 — LOW: the ticket text disagrees with the commit in four places
1. Row 2 names `MobilePalletizeWriteService.scanParcelBulk`. The changed site is `scanPalletBulk` (:426).
   `scanParcelBulk` (:530) has no `.matches(`.
2. Row 1's fix shape says "Use `OutboundPalletLabelGuard.requireOutboundPalletLabel`". The commit instead adds
   and uses a new static `matchesConfiguredPattern`. Consequence: the guard's per-scan
   "neither pattern configured" WARN (Guard:70-77) does **not** fire at palletize sites 1-2 or at site 3.
   An operator on an unconfigured tenant gets `noValidString` with no log line naming the missing key.
3. "Tier T2: four production files". The commit changes five (`OutboundPalletLabelGuard.java` gained the helper).
4. Row 4 says "fail open". The code **skips** the destructive purge with a WARN. "Fail open" usually means
   "allow", which is the opposite of what the code does. Say "skip (fail safe)".

### F4 — LOW: the exposure statement understates how reachable the unset state is
- "Reachable only if a tenant's row is deleted or blanked" is true, but both are ordinary UI actions:
  - The Patterns tab has a **Delete Setting** button (`patterns.vue:64`, `deleteParamAndConfig.vue`). It sends
    `DELETE /v3/sysprop/{id}`, which is gated to sb_admin (`PutawayConfigService.requireWarehouseConfigWriteAuthority`).
  - The edit dialog accepts an empty value (F2).
- Measured 0 today, and I confirm that:
  - Hydra prd `wh01_hydra_v2` has all 5 keys plus the default tote printing key set, all on `client_id=0` / `DEFAULT`.
  - WineCo dev `dev_wh01_om1` has the same.
  - Landlord-prd maps Hydra to that single DB (warehouse `nywh`), so "Hydra prd" is fully measured.
- Landlord-prd also lists active ShipItEZ DBs (`wh01_shipitez_v2`, `wh02_shipitez_v2`, created 2026-09-18). No
  MCP reaches them, so they are unmeasured. The ticket should say so rather than imply that prd is 0.
- V2.2.00 seeding is verified: lines 2614-2617 and 2638 insert all five keys, plus `PRINTING_PATTERN_DEFAULT_TOTE_LABEL` at 2641.

### F5 — INFO: the operator message on an unconfigured tenant misdiagnoses the fault
When the key is unset, `isToteLabel` returns false, which yields `PickingController:353-354` "X is not a tote.
Please scan a tote.". `isParcelLabel` returning false yields "X is not a parcel ID!" (MobilePickingService:1139,
:1244). Every scan is rejected with a message that blames the label, not the missing sysprop. That beats a 500,
but a one-time WARN naming the key (as in Guard:70) would make it diagnosable. Optional.

## Item 2 — behaviour change for tenants with the patterns configured
None reachable. Callers checked:
- `isToteLabel`: PickingController:353.
- `isParcelLabel`: MobilePickingService:1139 and :1244.
- `handleTruckOffLoading`: MobileMoveUnitloadService:428.
- `matchesConfiguredPattern`: 5 sites.

With both patterns set, the new logic is identical to the old. With only `pattern` set, the old code evaluated
`label.matches("")`, which is true only for label `""`. Empty labels are rejected earlier at:
- PalletizeWrite:227, :429
- ParcelMonitor:140 (the `palletName` empty check)
- BillOfLadingController:514, where empty means create-by-system

`handleTruckOffLoading` receives the label of an already-resolved unit load (0 rows with `labelid=''` on
Hydra prd). So the one semantic difference ("" no longer matches) cannot be reached, and it is an improvement anyway.

## Candidates — sub-T3, for THIS ticket (it is `in development`, not `on dev`)
In priority order:
1. **F2**: `convertFormatToRegex` null-or-**blank**, plus a test. One line, covers all 6 sites. I would do this first.
2. **F1**: guard `ParcelMonitorViewService:131` and `BillofladingService:856` against a null/blank printing
   pattern, with a BusinessException that names the key. Same key, same crash class, 2 small hunks + 2 tests.
3. **F3**: correct the ticket text (scanPalletBulk, the fix shape of row 1, 5 files, "skip" instead of "fail open").
   **F4**: add the ShipItEZ-unmeasured line.
4. Optional: `isEmpty` → `isBlank` in `matchesConfiguredPattern` and in `handleTruckOffLoading*` (F2 note).

## Proposals — do NOT file; for Nam
- `OrderMonitorViewService.printToteLabels:184`: an unset `PRINTING_PATTERN_DEFAULT_TOTE_LABEL` gives an NPE,
  and `""` gives a tote labelled `""`.
  - Different key, but the same shape as F1.
  - Blast radius: web tote-label printing only. Cost: about 5 lines.
  - Fold it into this ticket if Nam accepts widening the key set, since its tier is under T3.
- `StringConverter.convertFormatToRegex` throws on any printing pattern that is non-blank but malformed
  (`AOUT%06d`, `AOUT-%6d`).
  - Blast radius: all 6 outbound-pallet admission and purge sites become 500s after one admin typo.
  - Cost: validate on write (SystemPropertyController / SDR handler), or catch in the converter and treat the
    pattern as unconfigured.
  - Needs a design call on whether to reject or ignore, so propose it separately.

## Self-audit
- F1: HIGH confidence. `String.format(null, …)` NPEs in `Formatter.parse`, and the code path is read directly.
- F2: HIGH confidence. The `split` indexing is read directly, and the untrimmed `getSysvalue` was verified at SyspropService:334-336.
- Neither is a stylistic preference.
- Realist check: exposure is 0 on every DB measured. Both findings need an admin action to trigger, and both are
  fast to detect (a 500 or a visible bad label). That keeps them MEDIUM, not HIGH.
- F1's `""` → shared `""` pallet is a silent data-integrity failure, which is why it is not rated LOW.
