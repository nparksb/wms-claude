---
name: grep-is-ugrep-skips-binary-without-dash-a
description: grep on this workspace is ugrep, which silently skips binary files without -a and exits 1 — a false zero indistinguishable from a real no-match
metadata:
  type: reference
---

`grep` on this machine is **ugrep 7.8.4**, not GNU grep. It **silently skips binary files unless `-a` is
passed**, and exits **1** — byte-for-byte indistinguishable from a genuine no-match.

So `grep -r <pattern> target/classes --include='*.class'` returns a clean, confident **0** even when the
pattern is present in dozens of class files. Measured on SBDEV-3156 (2026-09-01): a bytecode scan for five
method-security annotation descriptors reported 0 for all five, including `@PreAuthorize`, which has 38
uses in `src/main` and 4 carrier classes in bytecode.

**Rules:**
- `grep -r` over `.class`, `.jar`, or any binary needs **`-a`**. `grep -rlaF` is the safe form.
- `git grep` is unaffected — it is git's own implementation and its targets are text. All the source-level
  counts in this workspace taken with `git grep` are sound.
- Inconsistency to know about: with a multi-file argument list from `find -exec grep -lF {} +` ugrep DID
  report the matches, while `-r` and a single explicit binary file argument did not. Do not rely on the
  difference — always pass `-a`.

The near-miss that makes this worth a memory: the false zero pointed at the **same conclusion** as the true
answer, so it would have shipped as the measurement justifying the change. Only a positive control
separated them — see [[a-zero-scan-needs-a-positive-control]].

Related: [[wms2-web-ui-gitignore-reports-hides-34-files-from-grep]] is a different grep trap in the same
workspace (ignored paths, fixed by `git grep`).
