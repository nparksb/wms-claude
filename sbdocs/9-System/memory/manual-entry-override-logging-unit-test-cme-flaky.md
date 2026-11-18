---
name: manual-entry-override-logging-unit-test-cme-flaky
description: ManualEntryOverrideLoggingUnitTest.logs_shouldNotContainValue_whenShapeInvalid throws ConcurrentModificationException in a full unit run; passes alone
metadata:
  node_type: memory
  type: project
  originSessionId: 602069ff-723f-49f9-b608-a82222bf9314
  modified: 2026-10-31T09:30:54.410Z
---

`ManualEntryOverrideLoggingUnitTest.logs_shouldNotContainValue_whenShapeInvalid` errored once with `java.util.ConcurrentModificationException` at `ArrayList$ArrayListSpliterator.forEachRemaining`. It was streaming a captured log list (a logback ListAppender) while another thread appended to the same logger. Seen 2026-10-31 in a full `mvn clean verify -Pci` on the SBDEV-3491 branch, which does not touch that class; it passed 3 of 3 runs alone.

**Why:** a ListAppender's `list` is a plain ArrayList. Any thread logging to that logger during the test (a scheduled job or a sibling test's worker) races the test's stream over it.

**How to apply:** if it reds in a full run, rerun the class alone before reading it as yours. The real fix is to copy the list under the appender's lock, or filter by thread, before streaming it. Tracked as proposal P39 in `sbdocs/2-Areas/proposals-register.md` (ride-along). When writing a new log-capture assertion, read `captured.list` only after every thread that logs into it has been joined (see [[hub-flaky-its]]).
