---
name: wms2-syspropservice-parselongordefault-throws-on-garbage
description: "wms2 SyspropService.parseLongOrDefault falls back ONLY when the sysprop is absent; an unparseable value THROWS. Read the body, never trust the name"
metadata:
  node_type: memory
  type: reference
  originSessionId: c918a9c4-41c6-4656-b2f1-e9ba979834ff
  modified: 2026-11-03T13:01:08.471Z
---

`SyspropService.parseLongOrDefault(value, defaultValue)` on wms2-api is
`Long.parseLong(value == null ? defaultValue : value)`: the default applies only when the row is
**absent**. An unparseable value throws `NumberFormatException`. Its javadoc says so ("the write paths
let it fail, the display path maps it to SYSTEM_INVALID"), but the name reads like "parse, or default
on failure".

Its sibling `getIntValue(key, defaultValue)` is the opposite: it swallows the parse error and returns
the default. So the same sysprop can mean "throw" on one path and "fall back" on another; that is
SBDEV-3998 (the FLA default triple has four readers with three rules).

**Why it matters:** on SBDEV-3991 (2026-11-02) I refuted review finding F8 ("reset fails under
SYSTEM_INVALID") from the method name, kept the reset enabled, and wrote a test pinning the wrong
behaviour. The next review round caught it as a Medium. The refutation cost a full extra round.

**How to apply:** before relying on any `*OrDefault` / `*OrElse` / fallback helper to argue that a path
succeeds, read its body for which inputs actually fall back. Refuting a reviewer's claim needs the
same evidence as making one. Related: [[hub-code-traps]].
