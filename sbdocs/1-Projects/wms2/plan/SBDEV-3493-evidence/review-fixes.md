# SBDEV-3493: review findings and how each was handled (author pass, 2026-09-24)

Reviews on 38ba14ac: code-review.md (APPROVE, 8 Low), completeness-review.md (REQUEST CHANGES: F1/F2 Medium, F3/F4 Low, F5 Info).
Fixes: 3be7aa6e.

| # | Finding | Action |
|---|---|---|
| CR-L1 | Sites 1-2 lost the guard's "neither configured" WARN | The WARN moved into matchesConfiguredPattern, so every admission site (1-3 and the guard) logs it; the purges return before calling it, with their own WARN. The ticket text now says the helper is used, not requireOutboundPalletLabel (which would need constructor wiring and makes the IT fixture's @MockitoBean a silent no-op) |
| CR-L2 | Tote/parcel give no configuration signal | LOG.warn naming the key when unset |
| CR-L3 | Stale NoClear inline comment ("NPE (the original's behaviour)") | Replaced: NoClear now calls the shared helper |
| CR-L4 | Stale LabelPrintingService javadoc ("already broken in isToteLabel") | Reworded |
| CR-L5 | Two implementations of the rule in the two purges | NoClear uses matchesConfiguredPattern; both use OutboundPalletLabelGuard.isConfigured |
| CR-L6 | "Unset" meant empty in outbound, blank elsewhere | isConfigured = non-null and not blank; convertFormatToRegex also treats blank as unset. All sites now agree |
| CR-L7 / CS-F3 | Ticket text drift (scanParcelBulk, "uses requireOutboundPalletLabel", 4 files, "fail open") | Ticket description rewritten |
| CR-L8 | Purge early return unpinned | notConfiguredRunsNoPositionQuery asserts the purge's own WARN; hand mutant (remove the block) killed there |
| CS-F1 | String.format(PRINTING_PATTERN...) at ParcelMonitor system pallet and BOL transferOrder; "" mints a shared "" unit load | StringConverter.formatConfiguredLabel refuses null/blank naming the key; applied to both, plus OrderMonitorViewService.printToteLabels (default tote pattern, same shape). Tests: ParcelMonitor (null and ""), BOL transferOrder (""), helper. OrderMonitor's call site has no unit test (printToteLabels has no test class; ~12 collaborators) |
| CS-F2 | Whitespace printing pattern → AIOOBE in convertFormatToRegex | isBlank; converter test; purge whitespace test |
| CS-F4 | Exposure line undersold reachability; ShipItEZ unmeasured | Ticket now names the admin Delete Setting button and the unchecked textarea, and lists ShipItEZ prd and UAT as unmeasured |
| CS-F5 | Tote/parcel rejection blames the label | Accepted: the new WARN gives the configuration signal in the log; the operator message is unchanged |
| CS proposal | Malformed non-blank printing pattern | Recorded on the ticket as proposed, not done (needs a design choice) |

Mutation checks on the new assertions (all attributable, by the test written for them):
Ma convertFormatToRegex isBlank→isEmpty — StringConverterUnitTest...shouldTreatWhitespaceAsUnset (AIOOBE);
Mb ParcelMonitor system pallet back to String.format — shouldRefuseSystemPallet_whenPrintingPatternIsUnset [null];
Mc BOL back to String.format — TransferOrder.refusesWhenPrintingPatternIsUnset;
Md purge early return removed — HandleTruckOffLoading.notConfiguredRunsNoPositionQuery (WARN);
Me isConfigured isBlank→isEmpty — matchesConfiguredPattern_neverTestsAWhitespaceOnlyPattern.
PIT on StringConverter + OutboundPalletLabelGuard helper methods: all KILLED.
Unit: 576 run / 0 failed across the affected classes.

Note for Nam: the completeness lane ran one `select *` on the prd landlord table, which returned tenant DB passwords in plaintext. It kept them out of its report.

## Correction to the section above
"OrderMonitor's call site has no unit test (printToteLabels has no test class)" was WRONG: OrderMonitorViewServiceUnitTest has a
PrintToteLabels suite; my search was truncated by `head -3`. Fixed below.

## re-review.md (3be7aa6e): APPROVE, 9 Low — fixed in 4163b178
| # | Action |
|---|---|
| R1 | Helper renamed requireConfiguredLabelPattern and placed after convertFormatToRegex, so describeExpectedFormat keeps its javadoc |
| R2 | whitespacePatternsCountAsUnset asserts the purge's skip WARN (the only thing that proves blank = unset there) |
| R3 | WARN assertions for OutboundPalletLabelGuard.matchesConfiguredPattern and MobilePickingService.isToteLabel/isParcelLabel |
| R4 | "null or empty" → "null or blank" (guard x2, MobileMoveUnitloadService); helper WARN text no longer claims "every pallet is rejected" |
| R5 | Ticket claims corrected in a comment ("single definition", #11 tested, 8–10 mutation-checked not failing-first) |
| R6 | OrderMonitor client-specific check isEmpty → isBlank, so a whitespace client row is refused at its own check. The existing message (naming the non-existent PRINTING_PATTERN_TOTE_LABEL) is kept: an existing test pins it and rewording operator messages is out of scope |
| R7 | Refusal before the sequence draw at all three format sites; tests assert never getNextSequenceNumber |
| R8 | @ParameterizedTest replaces the loop + Mockito.reset (ParcelMonitor) and the loop (StringConverter) |
| R9 | Closed by two real OrderMonitor tests (default unset → refused naming the default key, no sequence drawn; client row blank → refused at its own check) |
Also: the full suite on 3be7aa6e failed NeverMatcherNullBlindnessArchTest — my never() verifies used anyString(); now bare any()
(createUnitload's first argument cast to String to pick the 5-arg overload).

Mutants (hand, all killed by their own test): Mf/Mg sequence drawn before the refusal (ParcelMonitor, BOL); Mh OrderMonitor default
refusal removed; Mi client check back to isEmpty; Mj guard WARN removed; Mk tote WARN removed. Unit: 587 run / 0 failed.
