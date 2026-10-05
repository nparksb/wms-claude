# SBDEV-3493 floor evidence (author pass, 2026-09-24)

Commit under review: see `git log origin/develop..HEAD` on bugfix/SBDEV-3493-unset-pattern-npe (base 45433631).

## DB
Hydra prd + wineco dev: all five keys (STRING_PATTERN_OUTBOUND_PALLET, PRINTING_PATTERN_OUTBOUND_PALLET_LABEL,
STRING_PATTERN_INBOUND_PALLET, STRING_PATTERN_PICKING_TOTE, STRING_PATTERN_PICKING_PARCEL) set and non-empty.
V2.2.00 seeds all five. Exposure 0; reachable only by deleting/blanking a row. UAT not measured (MCP down).

## Sweep
`git grep -n "\.matches(" origin/develop -- src/main/java` → 7 unguarded sysprop-pattern sites (the ticket table);
LabelPrintingService.requireScannableToteId and ReceivingService.verifyPalletOrCartLabel already guarded; the rest are
compiled Pattern/Matcher on constants. Blind spot: a pattern applied via Pattern.compile(sysprop) would not match `.matches(`.

## Failing first (12 tests, all red on 45433631 for the right reason)
NPE `"this.pattern" is null` (purge x2, picking x2) or Wanted-but-not-invoked / wrong exception because the NPE fired before
the verified call (palletize x4, parcel monitor x2, inbound x2).

## Mutation (PIT, changed lines)
All KILLED on changed lines of OutboundPalletLabelGuard.matchesConfiguredPattern, MobilePickingService.isToteLabel/isParcelLabel,
ParcelMonitorViewService.palletise, MobilePalletizeWriteService.scanPallet/scanPalletBulk, MobileMoveUnitloadService.handleTruckOffLoading
and scanDestination. One survivor at handleTruckOffLoading :553 closed by stringPatternAloneStillPurges (re-run: all 7 killed).
Remaining survivors on OutboundPalletLabelGuard :70 are the untouched warn-log `if` in requireOutboundPalletLabel.
Not pinnable: handleTruckOffLoading's early return adds only a WARN (the helper returns false without it).

## Unit
401 run / 0 failed across the affected classes (+ truck-loading and palletize suites) before the extra purge test.
