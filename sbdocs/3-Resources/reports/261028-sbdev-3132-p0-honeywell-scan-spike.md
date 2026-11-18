---
title: "SBDEV-3132 P0 — Honeywell scan-detection spike (WineCo)"
type: report
status: pending-device
version: v2
scope: wms2-mobile-ui
ticket: "SBDEV-3132"
ticket_url: "https://app.clickup.com/t/868kxnbpb"
created: 2026-10-28
updated: 2026-10-28
related:
  - "[[SBDEV-3132-mobile-force-scan-manager-override]]"
tags: [report, spike, mobile, scanner, sbdev-3132]
---

# SBDEV-3132 P0: Honeywell scan-detection spike

**Status: waiting for a device run.** The harness is built (v5.1, reworked after a review and three re-reviews; v5.1 made its test suite deterministic) and has been tested headlessly. No measurement from a real WineCo Honeywell exists yet.

**Why this exists:** P2 needs a signal that tells a barcode scan apart from typing on the device. The plan (§5 "P0: device spike", §3.5 "Detection") makes detection a pluggable strategy, chosen in this order:

1. **native**: an Enterprise Browser scan callback;
2. **per-app prefix**: a prefix that can't be typed, or prefix and timing together;
3. **timing**: inter-key gaps.

If no signal separates scans from typing, the decision goes back to Nam (O3). **P2 is blocked until this report is filled in.**

## How to run it (about 20 minutes per device)

1. Copy [`assets/sbdev-3132-p0-scan-spike.html`](assets/sbdev-3132-p0-scan-spike.html) onto the device and open it in Enterprise Browser.
   - Open it as a `file://` copy or from an **https://** static host. **Not plain http://**: there `navigator.clipboard` does not exist, so section 3 says "API absent", which tells you nothing about the WMS (served over https). The page prints `secure context: true/false (protocol)` next to the clipboard result; if it says `false`, the clipboard row is inconclusive.
   - It is one self-contained file with no network calls and no external scripts.
2. **What the export contains.**
   - By default: lengths and character *classes* (`d` digit, `A`/`a` letter, `p` punctuation, `<02>` for a control character), timings, and key names such as `Enter`, `Tab`, `F5`, `Control`.
   - It does **not** contain the scanned or typed values. Of the key identifiers, `keyCode` is kept only for keys that type no character, and `code` only for value-free keys (`Enter`, `Tab`, `Escape`, arrows, F-keys, modifiers); every other `code` is `redacted`, including on `Process`/`Unidentified` keys.
   - The common start of all scans (if any) is exported as length and classes only.
   - It **does** contain your free-text answers in section 6, the full user-agent string and the screen size.
   - It **does** contain what the API probe finds: the names and member names of non-standard globals, and the first 80 characters of each one's string form. If Enterprise Browser injects a licence key or configuration string as a global, it can land in the file. Read the `apis` block before sharing the JSON outside the team.
   - Ticking "include full character codes" exports every value in recoverable form. Do that only with approval, and only with test labels.
   - Never scan or type a password or personal data. The on-screen keyboard may learn what is typed.
3. **Section 1, scanning.**
   - Leave the scanner's suffix as it is configured for the floor, and note it in section 6. For "Suffix configured", write exactly `none` if there is none; the page shows how it read your answer ("read as: none / set / blank / unclear") next to the field. The same applies to the prefix answer.
   - **Prefix test, two runs.** If a prefix will be tested: first switch the prefix **off**, choose "SCANNING, no prefix set (baseline)" and scan **at least 5 labels** (10 is better). Then switch the prefix **on**, write it in the section 6 answer `prefix`, choose "I am SCANNING" and do the main run. A key the trigger or the wedge adds to every scan shows up in both runs; only a lead that is in the second run and not the first is the prefix. The page gives no prefix verdict other than `insufficient-data` until it has **30 configured scans, 30 typed entries and 5 baseline scans**; the summary says which of these is short ("need baseline scans 2 of 5"). With the `prefix` answer blank or `none` it says `unconfigured`.
   - If the baseline shows the lead because the prefix was still on (profile not yet re-applied), a real prefix is reported as `trigger-or-wedge-artefact`. Compare the printed baseline leads with the configured one before believing that verdict. If the trigger adds a key *and* the prefix is real, the configured lead is the combined sequence (for example `Unidentified(no text) Ctrl+B`). The verdict is then `non-typeable-prefix`, and P2 must expect that whole sequence.
   - Choose "I am SCANNING" and scan **100 real labels** if you can (30 is the bare minimum): locations, pallets, SKUs and totes, the same mix the floor uses. Leave **at least 2 s** between scans. Why 100: see "How sure 0 errors is" below.
   - **Do not press Enter after a scan.** The page ends an entry on Enter, on Tab (focus stays in the field), or on a line break or tab inside the text the scanner delivers. It records which of these ended each entry.
   - If nothing ends a scan within 0.3 s of its last character, the page closes it **"by silence"** (`finishedBy: idle`). That alone does not mean the scanner sends no suffix. What happens next decides:
     - more characters and then a terminator within about 1.5 s: most likely **one scan split by a stall**. The page re-joins it, keeps the stall as a gap of that scan (`rejoined.stallMs`, measured to the first *character* of the second part), and prints a `WARNING re-joined scan: a + b = n chars after a … ms stall` line with the median scan length. If the joined value is over 1.5× the median, it says **PROBABLY TWO SCANS**: the first lost its suffix and the second followed within 1.5 s. Then do not record a device stall; the timing verdict is blocked (`silenceProblem`). The median spans all label kinds, so with mixed lengths the flag can be wrong both ways. A long SKU re-joined among short locations is flagged although it was one scan. Two short locations among long SKUs are not flagged although they were two scans. Either way the timing verdict already fails (the joined gap is at least 300 ms); read the two part lengths in the warning line. Re-joining applies to scans only; a typed entry is never re-joined;
     - only a terminator within that window: a **late suffix** (`finishedBy: enter-late`, `lateSuffixMs`), not a missing one. If your `suffix` answer reads as none, the page warns instead: such an Enter was most likely pressed by habit;
     - nothing: the scan really ended without a terminator. Only if *every* scan ends this way, and your answer `suffix` agrees, does the scanner send no suffix. That is a finding (P2 then has no end-of-scan marker), not a harness error.
   - If some scans end by silence while others end on a suffix (or the `suffix` answer reads as set), or two silence-closed scans follow each other within 1.5 s, the page cannot rule out a hidden stall, and the timing verdict says `separable-but-silence-closed-scans`.
   - With no suffix, a stall longer than 1.5 s leaves two short silence-closed fragments. The page cannot tell them from two short labels, so it prints `AMBIGUOUS: n pairs of short silence-closed scans add up to about one scan` (both shorter than 2/3 of the median, together within 25% of it). Such a pair blocks the timing verdict (`separable-but-silence-closed-scans`) like the other silence problems. Look at those scans: if they really are two short labels, rescan with longer gaps between them. Fragments either side of the baseline/configured switch are never paired.
   - Two scans with no suffix less than 0.3 s apart become one entry, and an entry recorded in the wrong mode shifts the statistics. Both push towards not-separable, so they fail safe; use "Discard last entry" when you notice.
4. **Section 1, typing.**
   - Type 30 or more values as fast as a picker would, **pressing Enter after each one**.
   - Use "TYPING on keypad" for the hardware keys and "TYPING on screen keyboard" for the soft keyboard. They are different populations and the page keeps their statistics apart (`timingSeparation.keys` and `timingSeparation.soft`). Record 30 or more of each method pickers use, and say which in the section 6 answer `typing`.
   - Started an entry in the wrong mode? "Discard last entry" removes it. Switching mode discards an unfinished entry.
5. **Section 2:** tap the read-only field and scan once.
6. **Section 3:** long-press and try to paste, then press "Try clipboard read". A `NotAllowedError` is a permission outcome, not proof that MDM blocks the clipboard; the MDM question in section 6 answers that.
7. **Section 4:** watch whether the soft keyboard appears when the field is focused and during a scan, and write the answer in section 6. The viewport counter also moves on rotation and zoom, so what you see is what counts.
8. **Section 5:** if the Enterprise Browser documentation says its scan API needs a vendor script, meta tag or configuration, do that first, then press "Re-probe APIs". The page also probes at load and 2 s after load.
9. **Section 6:** answer the device and MDM questions from the Enterprise Browser and scanner settings.
10. **Section 7:** press Summarize, then **Download JSON**.
    - The page says "Download triggered", but Android WebViews often ignore downloads silently. Check the Downloads folder.
    - If the file is not there, use **Copy JSON**, **Show JSON (select all)** or **Open JSON in new window**. Copying leaves the JSON on the device clipboard, so copy something else afterwards.
    - If all of these fail, photograph the summary box: it holds every number the table below needs.
    - "Include raw events" makes the file much larger. Leave it off unless asked.

11. **Masked-field check (added 2026-10-28, security M2).** The override dialog's manager password is a plain text field shown as dots via `-webkit-text-security: disc` with `autocomplete="one-time-code"`, not `type="password"` (Nam's decision, so autofill never offers to save a manager's login on a shared handheld). In Enterprise Browser, open any page with `<input style="-webkit-text-security:disc" autocomplete="one-time-code">` and type into it. Record: (a) characters render as dots; (b) no "save password" or autofill prompt appears after leaving the page; (c) the soft keyboard is a normal text keyboard. A "no" on (a) or (b) goes back to Nam before P3.

Repeat on a second device model, if the floor has more than one.

## Exit criteria (plan §5, recorded as numbers)

| # | Criterion | Harness field | Result |
|---|---|---|---|
| 1 | **Delivery mode:** per-key keydown; per-char `input` (keydown `Unidentified`/229); text commit (one `input` carrying several characters); IME composition; paste | `scan.delivery`, `counts` per entry | — |
| 1a | **Suffix:** what ends a scan (Enter / Tab / line break in the text / late / nothing) | `scan.finishedBy`, `scan.silence` | — |
| 2 | **Native callback:** does EB expose a scan API, once the vendor's activation step is done? | `apis.everSeen`; `apis.latest.extraGlobals`, `details`, `navigatorExtras`; answer `api`; EB docs | — |
| 3 | **Per-app prefix:** can it be set, and can it be a character a person can't type (e.g. STX 0x02)? | answer `prefix` (`prefixAnswerReadAs`); baseline and configured runs; `prefixSignal.verdict`, `prefixSignal.nonTypeableLead` (configured / baseline / typed counts), `prefixSignal.typeableCommonStart`, `prefixSignal.scanOnlyFirstKeydown` | — |
| 4 | **Timing:** each entry's largest gap between characters, scans vs each typing method | `timingSeparation.keys` and `timingSeparation.soft`: `verdict`, `scanCeilingMs`, `typedFloorMs`, `margin`, `thresholdMs`, `headroomMs`, `falseRejectScans`, `falseAcceptTyped`, `confidence` | — |
| 5 | **Read-only fields:** does a `readonly` field still receive keydown? | `readonly.keydowns`, `readonly.valueChanged`, `eventsInOtherFields` | — |
| 6 | **Lock-down:** can EB/MDM block the clipboard and the soft keyboard? | `paste`, `softKeyboard`, answers `lock` and `sip` | — |
| 7 | **Desktop stations:** do any share these scanners? | answer `desktop` | — |

### What the timing numbers mean

The detector being evaluated is: an entry is a scan if its *largest* gap between two characters is below a threshold.
- A scan is wrongly rejected if its largest gap reaches the threshold.
- A typed entry is wrongly accepted if its largest gap stays below it.

So the harness uses each entry's largest gap on both sides, once per typing method (keypad and screen keyboard are never pooled):
- **Scan ceiling:** the largest gap over all scans. It is the max, not a percentile. With 30 scans the p99 *is* the max, and a p95 would quietly let 1 scan in 20 trigger a manager override. A scan re-joined after a stall carries that stall as a gap.
- **Typed floor:** the smallest such gap over the typed entries of that method. It is the fastest typist *in the sample*; a faster picker is not in it.
- **Margin:** typed floor ÷ scan ceiling. It must be **at least 2**, so that a slower device, a busier WebView or a faster typist does not close the gap. This factor is a judgement call, not a statistical guarantee.
- **Threshold:** when the two do not overlap, the **midpoint** of ceiling and floor, so the threshold has the same headroom in milliseconds on both sides (`headroomMs`). The headroom must be **at least 20 ms**, because Android delivers input on display frames (about 16.7 ms apart) and one frame of delay must not cross the threshold. (v2 used the geometric mean, which put the threshold at 9.5 ms for a 1 ms ceiling and a 90 ms floor: inside that jitter.) When they overlap, the threshold is the value that misclassifies the fewest entries. `thresholdRule` says which was used. The threshold is a starting point for P2, not a tuned setting.
- **Which clock.** Gaps are measured on the event's own timestamp (`e.timeStamp`), set when the input was created, and **P2's detector must use `e.timeStamp` too**. Handler time (`performance.now()` inside the listener) adds main-thread delay (jank, GC), which hits scans and typing differently: a burst of scan keys queued behind a 50 ms task arrives spread out, while slow typing barely moves. The page measures both for every entry: `scanCeilingHandlerMs` and `typedFloorHandlerMs` sit next to the event-time numbers, and `scan.timing.clockDiffMs` gives the per-entry difference. If the handler-time ceiling reaches the threshold, the verdict is `separable-but-handler-time-differs`: the event clock separates, but a detector built on handler time would reject scans. (Since the threshold is the midpoint, this is the same as the handler-time ceiling exceeding the event-time ceiling by more than the headroom.) One main-thread stall among 100 scans is enough to trigger it, which is deliberately conservative. Look at `clockDiffMs`: if a single entry is the outlier and P2 will use `e.timeStamp`, say so to Nam rather than reading the run as not separable. If the event-time ceiling is (near) 0 while the handler clock sees real spacing, the verdict is `timestamps-suspect` instead.

**How sure 0 errors is.** `confidence` gives the exact (Clopper-Pearson) one-sided 95% upper bound on the false-reject and false-accept rates. With 0 false rejects in 30 scans the true rate can still be up to **9.5%**: about one scan in ten could trigger a manager override and 30 scans would not show it. 59 clean scans bound it at 5%, 99 at 3%. The same holds for false accepts on the typed side. The summary prints both bounds and says "record more scans" or "record more typed entries" while either is above 5%. `separates: true` in the JSON still means only "separable at this sample size": give Nam the bound with the verdict.

`verdict` is one of:
- `separable`: ceiling below floor, margin at least 2, headroom at least 20 ms, no unexplained silence-closed scans, and 30 or more measurable entries on each side;
- `not-separable`: the populations overlap;
- `separable-but-handler-time-differs` (see "Which clock"), `separable-but-margin-under-2x`, `separable-but-headroom-under-20ms`, `separable-but-silence-closed-scans` (see step 3 above; `silenceProblem` says why) or `insufficient-data`;
- `timestamps-suspect`: by event time every scan is (near) instant, ceiling 0 ms or under 1 ms, while the page's own clock (`scanCeilingHandlerMs`) saw 5 ms or more. The wedge stamps a scan's events together, so the event-time gaps prove nothing;
- `not-measurable`, with the reason, when one side has no per-character signal (for example a text-commit or IME-composition wedge);
- `no-data`: no typed entries with that method.

The `perGap` block is stricter: the largest scan gap against the smallest typed gap, over every single gap. It matters only if P2 must decide before the entry ends.

### Decision rule

1. **native** if criterion 2 shows a scan API the page can subscribe to, once the vendor's activation step has been tried (answer `api`). "Nothing found" without that step does not rule native out: ask the vendor before moving on.
2. Otherwise **prefix**, but only if *all three* hold:
   - criterion 3 shows a non-typeable prefix can be provisioned per app profile;
   - with it set, `prefixSignal.verdict` is `non-typeable-prefix`. The harness sets that only when:
     - the run has at least 30 configured scans, 30 typed entries and 5 baseline scans (else `insufficient-data`; `prefixNeeds` lists what is short);
     - the `prefix` answer is not blank or `none` (else `unconfigured`);
     - at most floor(5% of n) configured-run scans miss the same non-typeable lead (`configuredWithLead` of `configuredScans`, `configuredMissingLead`);
     - at most max(1, floor(5% of n)) typed entries carry that lead (`typedWithLead`);
     - at most floor(5% of n) baseline scans carry it (`baselineWithLead`). If more do, the verdict is `trigger-or-wedge-artefact`: the trigger or the wedge adds that key to every scan, prefix or not.

     floor(5% of n) is 0 below 20, so a baseline of 5 to 19 scans tolerates **no** scan with the lead, and fewer than 20 configured scans would need 100%. At 30 configured scans 29 must carry the lead; at 40, 38. The tolerance is never looser than 5%.

     Every stray is counted in the summary line "Lead …: configured run a of n (missing b); baseline run c of m; typed d of e". Leads are control characters, Ctrl/Alt/Meta combinations, named keys other than Backspace, Delete, the arrows, `Dead` and `Clear` (for example `Escape`, `F13`, `Home`), and `Unidentified` keys that produced no text. Soft-keyboard and IME typing (keydown 229 with composition) is not a lead;
   - criterion 7 says no desktop station shares these scanners, or that the desktop UI strips or ignores that prefix. Without this, desktop users would see the prefix in the web UI.

   Check the lead against the device's keypad: if pickers can press it there (some Honeywell keypads have Esc or F-keys), it is a typeable prefix after all.
   If `prefixSignal.verdict` is `typeable-prefix-needs-timing`, every configured-run scan starts with the same typeable characters, at most max(1, 5%) typed entries and at most 5% of baseline scans do. That is either a configured typeable prefix (check answer `prefix`) or a run that scanned only one kind of label. A typeable prefix is usable only **together with timing**: choose "prefix and timing" only if step 3 also passes.
   If the verdict is `trigger-or-wedge-artefact`, the prefix is **not usable as configured**: the page cannot tell the prefix from the key the scan path adds. Go to step 3, or ask Nam whether another prefix character is worth a second run. Tell Nam anyway if `typedWithLead` is 0: a key the scan path adds to every scan and that no picker types is itself a possible scan-only signal (`scanOnlyFirstKeydown` lists it). The same holds for `unconfigured` and `insufficient-data`: no prefix decision, go to step 3.
3. Otherwise **timing**, only if `timingSeparation.<method>.verdict` is `separable`, on every model measured, for each method named in answer `typing` (both, if pickers use both). Report the `confidence` bound with it.
4. Otherwise go back to Nam.

Also tell Nam if `deliveryAloneSeparates` is true, for example all scans are text commits and all typing is per-key. Delivery shape is then a possible fourth signal the plan does not list.

Criterion 5 decides whether P2 may use `readonly`. If `eventsInOtherFields` shows the read-only scan landing in another field, that is a focus problem, not an answer to criterion 5.

## Results

_Not yet measured. Fill in from the harness JSON, or from the photographed summary. Keep the JSON attached to SBDEV-3132._

| Device / EB version | Delivery (scan / typed) | Scan ends by | Native API | Prefix verdict (same lead / scans) | Typing method | Scan ceiling (ms) | Typed floor (ms) | Margin | Verdict | False-reject bound (95%) | Read-only keydown | Clipboard/SIP lock | Desktop shares |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| | | | | | | | | | | | | | |

**Chosen strategy:** _pending_

## Harness verification (2026-10-28, headless Chrome, not a device)

The harness was reworked three times: v2 after the review in `.omc/research/SBDEV-3132-p0-harness-review.md`, v3 after the re-review in `.omc/research/SBDEV-3132-p0-harness-rereview.md`, v4 after the second re-review in `.omc/research/SBDEV-3132-p0-harness-rereview2.md`, v5 after the third in `.omc/research/SBDEV-3132-p0-harness-rereview3.md`. The finding-by-finding mapping, with the test and the mutant for each, is in `.omc/research/SBDEV-3132-p0-harness-fix.md` (Round 2 covers v3, Round 3 v4, Round 4 v5). I drove the page with `puppeteer-core` against desktop Chrome. The scripts are in the session scratchpad and are not committed.

Each scenario runs on a fresh page: **41 in `run.mjs`, 4 in `probe.mjs`**. (The v2 text said 15 in `run.mjs`; there were 14. v3 had 30, v4 39, v5 40.)

**Correction (round 5): the suite was flaky until v5.1.** The earlier "all pass" results came from runs on an idle machine. On a loaded machine, four scenarios failed intermittently: `timing_separable`, `stall_long_unjoined`, `split_pairs_ambiguous` and `export_ui`. A fifth, `per_method_stats`, failed 4 of 4 times under CPU load. None of it was a harness defect; in every failure dump the harness reported exactly the input it received. The causes were in the tests:
- **Real-time keystrokes with upper-bound assertions.** Puppeteer typed "4 ms" scans in real time. Under load, Chrome delivered one keystroke 55–118 ms late (event time and handler time agreed, so the delay was in input delivery), and the harness correctly reported `not-separable` / `margin-under-2x`. `per_method_stats` had the same problem with CDP input 25 ms apart arriving 197–403 ms apart.
- **A race with the real 300 ms idle timer.** `export_ui` leaves a scan open and then clicks a mode button; a step slower than 300 ms let the timer close the scan first. A check script shows 0 ms lag passes and 400 ms lag fails exactly as reported.

Fix: the harness has a **test-only clock seam**. If `window.__spikeTestClock` exists (the suite injects it before load), the idle timer, the reset-arm timer and handler time use it; on a device it does not exist and the page uses `performance.now()` and `setTimeout()`. Every scenario except one runs on that clock, which moves only when the test advances it. Timing scenarios dispatch synthetic key, input and composition events stamped with that clock, so gaps and silences are exact. One scenario, `smoke_real_timing`, is the only one on real time and real keystrokes, with wide margins: no-delay scans against 250 ms typing, and a 2 s wait for a 300 ms silence close. Lower-bound checks on real sleeps (for example `unidentified_229`'s "max gap > 40 ms" after 60 ms sleeps) cannot be broken by load and stay real.

Acceptance after the fix (2026-10-28, macOS, 12 cores): `run.mjs` 10 consecutive runs, 41/41 each, 0 failures; `probe.mjs` 3/3; ES5 check passes; under load (12 CPU hogs plus two suites in parallel) 3 rounds × 2 runs, all pass; mutation 91 mutants, 0 survivors, 0 control failures. The 12 mutants previously killed only in the flaky scenarios were all killed again by the deterministic versions. Every scenario also checks that no summary line prints `null`, `undefined` or `NaN`.

Round 1 drove the page only with what desktop Chrome's keyboard and CDP can emit. Round 2 also builds device-like event sequences in the page itself, because every defect the re-review found came from one: Gboard-style `keydown 229` + composition, an IME scan wedge, a stall in the middle of a scan, a late suffix, a non-cancelable `beforeinput` with no `input`, an engine without `beforeinput`, events of one scan sharing one timestamp, and a WebView without `KeyboardEvent.key`.

**Terminators and silence**
- Enter ends an entry. Tab ends an entry, focus stays in the field, and nothing reaches the other fields.
- One text commit `PAL-1\nPAL-22\nPAL-333\n` splits into 3 entries of lengths 5, 6 and 7. A commit with no trailing break stays open, then is closed by silence. Every piece, the tail included, is classed `text-commit`; the shared event is counted once.
- Scans with no suffix, 1.8 s apart, close by silence, are flagged `unterminated`, and the summary says "closed by silence", not "no suffix".
- `LOC-`, a 350 ms stall, `1000`, Enter: **one** entry of 8 characters ending on Enter, with `rejoined.stallMs` ≥ 340 and the stall as its largest gap. Against typed entries the verdict is `not-separable`. (v2 gave two fast entries and could read `separable`.)
- The same with an 1.8 s stall (too long to re-join): the fragment stays closed by silence, and because other scans end on Enter the verdict is `separable-but-silence-closed-scans`.
- Two silence-closed fragments 500 ms apart: counted as back-to-back; verdict blocked.
- `LOC-1000`, 400 ms, Enter: one entry ending `enter-late` with `lateSuffixMs` ≥ 390, no stray, no FINDING. A typed entry with a 3.4 s pause before Enter ends `enter-late` too. A line break that arrives 400 ms late as text gives `linebreak-in-text-late`.
- Slow typing (400 ms per key) is not chopped.

**Round 3 (v4)**: the second re-review's reproductions are now permanent scenarios.
- A trigger key (`Unidentified` with keyCode 0, or `F13`) before every scan, in both the baseline and configured runs: `trigger-or-wedge-artefact`. The same data with a blank `prefix` answer gives `unconfigured`. With no baseline run, v4 said `not-established-no-baseline`; v5 says `insufficient-data (need baseline scans 0 of 5)`. v3 said `non-typeable-prefix` for all three.
- Escape prefix on 20 of 21 configured scans, plus one typed entry starting with Escape: still `non-typeable-prefix`, with the strays printed. A second typed Escape: `no-prefix-signal`.
- Scan 1 loses its Enter and scan 2 follows 1 s later: re-joined into 8 + 8 = 16 characters, printed as `PROBABLY TWO SCANS`, and the timing verdict is blocked. An ordinary 350 ms stall prints the re-join warning without that flag.
- A typist pausing 3.3 s mid-value: two typed entries, no re-join.
- A Shift keydown 120 ms before the first character after a stall: the stall is measured to the character (≥ 460 ms).
- No-suffix scanner, 1.8 s stall: the two fragments are reported as `AMBIGUOUS` (one pair). In v5 the pair also blocks the timing verdict, and fragments on either side of the baseline/configured switch are not paired.

**Round 4 (v5)**
- The reviewer's 3 configured / 1 baseline / 2 typed run (one typed entry starting with Escape) gives `insufficient-data`, listing all three shortfalls. 29/5/30, 30/4/30 and 30/5/29 each give `insufficient-data` naming the one short count; 30/5/30 gives `non-typeable-prefix` (positive control).
- Suffix answers `CR/LF`, `Enter/Tab`, `Return/Enter`, `CR+LF`, `cr,lf`, `Ctrl+B`, `\r` and `^B` read as set (v4: `unclear`).
- Answer `suffix` = `None.`, Enter pressed 1 s after a scan: warned as an Enter pressed by habit.
- Suffix answers `none`, `None.`, `no suffix`, `None (disabled)`, `n/a`, `none / disabled` read as none; `Enter`, `CR LF`, `Tab` as set; blank as blank. The reading is shown next to the field. `None.` no longer blocks a no-suffix run; `Enter` does.
- Event stamps 2 ms apart with handlers running 60 ms apart: `separable-but-handler-time-differs`, with the per-entry clock difference reported.

**No phantom entries:** wedge Enter plus operator Enter, a lone Tab then Enter, `A\n\nB\n`, Shift+Enter, and an `Unidentified` keydown with no text followed by Enter give exactly 3 real entries; the strays are counted. A non-cancelable `beforeinput` carrying a line break that never reaches an `input` does not split the next entry.

**Delivery:** `keydown Unidentified/229` with one `input` per character is per-char input, with gaps from the `input` events.

**Prefix**
- Ctrl+B before each of 10 scans is reported as "10 of 10 … Ctrl+B"; typed entries have none. STX inside a text commit is `U+0002`.
- Soft-keyboard typing as `keydown 229` + composition, as batched 229 keydowns, as `input` without `data`, and with the data only on `beforeinput`: **no** lead in 6 typed entries. (v2 reported `Unidentified(no text)` for each.)
- An IME scan wedge with no prefix: no lead, verdict `no-prefix-signal`. Ctrl+B followed by an IME-delivered value: found, 5 of 5, verdict `non-typeable-prefix`. A 229 keydown that produced no text, then per-key characters: still a lead.
- Escape before each scan: lead `Escape` 5 of 5, listed as a scan-only first key. A typist's leading Backspace is not a lead, and Backspace corrections do not count as "keystrokes that inserted nothing".
- `~` before every scan, not in typed values: `typeable-prefix-needs-timing`, 1 character of class `p`; its code only with the opt-in. Scans that all start `LOC-` while a typed entry does too: `no-prefix-signal`.
- With no `KeyboardEvent.key`, keys are derived from `keyCode`: Ctrl+B is still found and no label prints `null`.

**Timing**
- 30 scans at 4 ms per key against 30 keypad entries at 90 ms: `separable`, 0 false rejects and 0 false accepts, threshold at the midpoint, the 0-of-30 bound reported as 9.5% with "record more scans".
- Overlapping populations: `not-separable`. One slow scan in 30: `not-separable`, bound for 1 of 30 ≈ 14.9%.
- Keypad entries at 120 ms and screen-keyboard entries at 25 ms are reported separately (floors ≥ 100 and < 80 ms).
- Margin over 2 but headroom under 20 ms: `separable-but-headroom-under-20ms`.
- Every event of a scan stamped with one time: ceiling 0 ms, `timestamps-suspect`, margin printed as `n/a`, handler-time gaps exported. Stamps 0.4 ms apart while the events arrive about 8 ms apart: also `timestamps-suspect`. Identical stamps with no spacing on the page's clock either: `timestamps-suspect`, not a verdict that hangs on a null margin. (A first version checked only for exactly 0 ms; its test was flaky because loop-created events sometimes differ by 0.1 ms, and with enough data that case would have read `separable`. The test now pins `timeStamp` on each event.)
- Text commits only: `not-measurable`; no entries of a method: `no-data`.

**Privacy**
- The default export, even with raw events on, holds only classes (`LOC-1000` → `AAApdddd`): no value text, no value codes, no printable `keyCode`s, and no `code` except for value-free keys (`Process` + `Minus` → `redacted`; `Escape` stays).
- Ticking "full codes" exports the codes. That is the positive control.

**Export UI:** switching mode discards an open entry and clears the field; discard-last, the size indicator, the download message and Show JSON work; Reset needs two taps.

**API probe**
- The positive control injects into *every* frame: `EB`; an object like a JavascriptInterface, whose methods only `for..in` can see; a bound function that prints as `[native code]`; a revoked Proxy that throws when enumerated; `navigator.hwScanner`. All are found and described.
- A global added after load is found by "Re-probe". If the iframe cannot be created, the probe says instrument A is unavailable instead of listing about 1200 native names.
- A scanner-like global that sorts after 120 other page globals is still listed and described.

**ES5:** an esprima AST walk finds no arrow functions, `let`/`const`, template strings, classes, spread, destructuring, or shorthand/computed properties, and flags a known ES6 snippet as a control.

**Mutation check**
- 91 deliberate mutants (27 kept from v2, 35 added for v3, 21 added for v4 less 1 retired, 9 added for v5), one per guarantee above, re-run in v5.1 against the deterministic suite. One v2 mutant was retired because v3 guards the same case twice, so removing either guard alone changes nothing. One v4 mutant was retired with the code it mutated (the `not-established-no-baseline` branch, replaced by the baseline floor). Examples: "no re-join after a stall", "late suffix counted as stray", "composition keeps the 229 lead", "Escape not a lead", "typed methods pooled", "geometric-mean threshold", "rule of three instead of the exact bound", "margin prints null", "tail fragment shares the event".
- Each one turns its scenario red for the intended reason; 0 survive. The runner rejects a find-string that does not occur exactly once, and does not count a red caused by a page error.

**Not tested (needs a device)**
- Real wedge behaviour: whether a Honeywell keystroke wedge sends STX as Ctrl+B, as a raw `\x02` key, or drops it; how long its real stalls and suffix delays are; whether the trigger or the wedge adds a key event to every scan (the baseline run answers that).
- How far `e.timeStamp` and handler time drift apart on the device under load.
- The real Gboard/Honeywell IME event order. The modelled order (keydown 229, compositionstart, beforeinput, compositionupdate, input, keyup, compositionend) follows Chrome on Android; another order is handled as long as text follows the 229 keydown.
- Whether an old System WebView fires `beforeinput`. Without it, a line break inside a text commit is split only if the `input` event keeps it in `data`.
- Enterprise Browser APIs and their activation step, and real `addJavascriptInterface` objects.
- Blob downloads in EB, MDM settings, and the soft keyboard.
