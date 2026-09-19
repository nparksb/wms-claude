---
name: mvn-without-clean-runs-deleted-tests
description: "A deleted test class keeps running until `mvn clean` — stale target/test-classes inflates the suite count and can green a test whose source is gone"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 518ad76d-0650-4f08-b17a-74478c435d9d
  modified: 2026-08-30T13:21:48.072Z
---

`mvn test` does **not** prune `target/test-classes`. A test class whose `.java` was deleted keeps
being compiled-in and **keeps running**, indefinitely, until someone runs `mvn clean`.

Measured 2026-08-30 on SBDEV-2848: a throwaway `ScratchDiagTest.java` was deleted, but its `.class`
survived and ran in the next full suite, reporting **5768** tests. A fresh worktree reported **5767**
— the true count. I published 5768 in a PR body and a ClickUp comment before catching it.

**Why it matters beyond a wrong total:** the same mechanism can keep a *deleted or renamed* real test
green in your local runs while it no longer exists on the branch — the inverse of the usual worry. A
local green is not evidence the committed tree is green.

**How it was found, and the reusable technique:** diff **per-class** counts between two runs rather
than comparing totals:

```bash
grep -oE "Tests run: [0-9]+,.*-- in [A-Za-z0-9_.$]+" run.log \
  | sed -E 's/Tests run: ([0-9]+),.*-- in (.*)/\2 \1/' | sort > run.classes
diff a.classes b.classes
```

⚠️ My first attempt at that regex required `Skipped: N -- in` adjacently, which never matches (surefire
puts `Time elapsed` in between). It produced **zero** lines for both files, and the empty `diff` read as
"no differences" — a false green while investigating a false count. Always print the line count and the
sum and check they match the reported total before trusting the diff. See
[[failed-regex-resolution-must-not-become-a-verdict]].

**Practice:** run `mvn clean test` for any count you intend to quote, and never quote a total from an
incremental run. Related: [[wms2-develop-preexisting-test-failures]] (compare failures, not totals) and
[[green-tests-that-prove-nothing]].
