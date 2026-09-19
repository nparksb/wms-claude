---
name: a-control-on-a-literal-cannot-detect-a-narrowed-pattern
description: "A positive control on a hand-picked literal passes while the pattern's SPAN is narrowed; controls must run end-to-end at the reporting stage"
metadata: 
  node_type: memory
  type: reference
  originSessionId: bb937c20-4fcb-4d33-b6f5-9442c8be9915
  modified: 2026-09-08T14:12:08.685Z
---

**A positive control proves the instrument matched *one* string. It says nothing about how much the
pattern spans, nor about filters applied after matching.** Four ways one scanner reported a
plausible number — or a clean bill of health — with every control green
(`sbdocs/9-System/scripts/stale-lane-claim-scan.py`, SBDEV-3257, 2026-09-08):

| Break | Reported | Controls |
|---|---|---|
| gap `[^.]{0,140}?` → `{0,1}` | **0 across 0 files, exit 0** on the full population | all 4 PASSED |
| gap → `{0,40}` | a plausible 25/20 | all 4 PASSED |
| report only `origin == "block"` | 18 instead of 26 on develop | all 4 PASSED |
| drop `+` from the `//` run regex | spans still produced, 8 blocks lost | control 2 PASSED |

**Why the gap break is invisible:** the control literal was
`"the @SpringBootTest lane is down (SBDEV-2217)"` — subject and predicate **one space apart**. Real
claims put 20-100 chars between them. So `{0,1}` still matched the control and nothing else.

**The fixes, in order of value:**
1. **An end-to-end control over synthetic fixtures with REALISTIC shape** — a wide subject→predicate
   gap and a line break — one fixture per collector.
2. **Assert at the REPORTING stage, not by calling the detector.** A first version of that control
   called `tags_for()` directly, so a filter in the reporting path sailed past it. Drive the real
   `scan()` over a temp dir and inspect what it *returns*.
3. **A joining control must match the FLATTENED text and NOT the raw text.** Otherwise a later
   rewrap that puts the phrase on one line leaves the control green while it stops testing joining.
4. **Assert the anchor is unique before substituting** in a sabotage test, or the negative test is
   vacuous.

**A control also finds real defects.** Making control 2 strict exposed that `//` runs were joined
with the markers still embedded (`"installs no method // security advisor"`) because the newline sub
ran before the `//` sub — any pattern needing contiguous words across a break silently could not
match. Strip each line's marker BEFORE joining.

⚠ **Deleting a stale marker can red a live verify row.** `verify-SBDEV-2732…sh` asserted a file
*contains* `TODO(SBDEV-2217)`; removing that TODO made the row permanently red against a strictly
better state. `git grep` the literal you delete against `sbdocs/9-System/scripts/`.

Related: [[a-zero-scan-needs-a-positive-control]], [[verify-script-traps]],
[[mutation-harness-traps]], [[annotation-census-by-grep-is-wrong-by-default]].
