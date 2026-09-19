---
name: unzip-glob-multiple-jars-is-a-false-green
description: "`unzip -l target/*.jar` lists NOTHING when the glob matches 2+ jars — the extra paths become filename filters, so any grep over it returns 0 and reads as \"absent\""
metadata: 
  node_type: memory
  type: reference
  originSessionId: 518ad76d-0650-4f08-b17a-74478c435d9d
  modified: 2026-08-31T14:22:47.882Z
---

`unzip -l <archive> <path>...` treats every argument after the first as a **filename filter inside that
one archive**. So a glob matching more than one file silently produces an empty listing:

```bash
unzip -l target/*.jar | grep -c BOOT-INF/lib/   # 0   <- reads "clean", listed NOTHING
unzip -l target/wms-api-0.1.0.jar | grep -c BOOT-INF/lib/   # 244  <- the real answer
```

Measured 2026-08-31 in `v2/wms2-api`, which packages **two** jars (`wms-api-0.1.0.jar` 139 MB and
`wms-api-0.1.0-javadoc.jar`). `unzip -l a.jar b.jar` prints `0 files`. Direct consequence: a check of the
shape *"confirm artifact X is not in the fat jar"* **cannot fail** — `grep -ci jasypt` returns 0 whether
or not jasypt is there.

**This was my own instruction to a review lane**, and the lane caught it rather than inheriting it. The
tell was `grep -c BOOT-INF/lib/` returning 0 for a 139 MB Spring Boot jar — an impossible number, which is
the only reason it surfaced. A plausible-looking zero would have passed.

**Practice:** name the archive explicitly, never a glob. Where a glob is unavoidable, loop:
`for j in target/*.jar; do unzip -l "$j" | ...; done`. And sanity-check the *denominator* — if a listing
of a fat jar reports zero library entries, the instrument is broken, not the artifact clean.

Same family as [[failed-regex-resolution-must-not-become-a-verdict]] (an extraction that yields nothing
must not read as a negative finding) and [[mvn-without-clean-runs-deleted-tests]]. See
[[sbdev-3174-jasypt-removed-from-v2]] for the change this was verifying.
