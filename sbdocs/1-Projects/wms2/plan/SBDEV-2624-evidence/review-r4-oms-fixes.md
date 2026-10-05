# Review r4 - OMS c731dc43 (fixes r3 L1, L3)
head: c731dc43
Recommendation: APPROVE. Critical 0, High 0, Medium 0, Low 1 (cosmetic). Test suite NOT run by me (no PHP on host); mask checked in php:8.3-cli.

## Evidence
- Mask: `trim($s, "\x00..\x20")`. PHP double-quoted "\x00" and "\x20" are bytes 0 and 32; ".." is the charlist range operator (ascending, valid; same form as the PHP manual's "\x00..\x1F"). Run in php:8.3-cli with error_reporting=-1: no warning; for all 256 byte values, leading and trailing, `s !== trim(s, mask)` is true iff byte <= 0x20 (0 mismatches). Matches Java String.trim() (chars <= U+0020).
- Bytes >= 0x80 are not stripped (NBSP U+00A0 = C2 A0 stays), same as Java, whose trim() does not strip U+00A0.
- wms2 contract: SkuRestController.normalize (line 550-560) calls previous_sku.trim() - Java String.trim().
- Cannot block a heal: guard fires only when D != trim_java(D); wms2 then compares row code to trim(previous_sku) = trim(D) != D, so the CAS answers 108 again. No healable row is skipped. Mask is now exactly Java's set, so the old gap (\x01-\x08, \x0C, \x0E-\x1F) is closed. The guard cannot over-fire: D with only chars > 0x20 at the edges is untouched.
- Regex captures the control char: pattern uses /s and `(.+)`, so a trailing \x0C stays in $m[2] (not eaten before the guard). JSON round-trips \f as \u000c.

## Tests
- Form-feed case is real: default PHP trim() strips only " \t\n\r\0\x0B", not \x0C, so reverting the mask to bare trim() lets the D through to the holder query/reload/resend; the decoy is absent from this case (like the other edge_ws cases), and the arrange maps it to a 108 body. It is added to badMapCases (no resend expected) and skipReasonCases (reason asserted). Both fail on revert. Not executed by me.
- L3: `assertSame($reason, $context['reason'] ?? null)` pins key and value. A reason logged under another key now fails (null !== string).

## Issues
### [LOW] Docblock "Known limit" line is one 130+ char line, and wording says "whitespace or control characters (any char <= U+0020)" inline
File: app/Services/WmsApiService.php:1726 (diff hunk). Cosmetic: wrap it. Confidence: HIGH. No behaviour effect.

## Positive
- Fix is minimal, one expression; the comment states why the mask equals Java's range.
- Mutant name is embedded in the assertion message.
