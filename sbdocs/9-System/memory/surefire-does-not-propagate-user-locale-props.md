---
name: surefire-does-not-propagate-user-locale-props
description: -Duser.language/-Duser.country on the mvn CLI never reach the surefire fork; use LANG/LC_ALL env instead
metadata:
  type: reference
---

**`mvn -Duser.language=xx -Duser.country=YY` does NOT change the locale the tests run under.**
Surefire forks a JVM and does not propagate those two into it, so the fork keeps the host locale and
the test **passes**. Use the **`LANG` / `LC_ALL` environment variables**, which the fork inherits:

```bash
LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8 mvn -o test -Dtest=Foo   # actually changes the fork
```
Java parses the LANG *string* and does not need the locale to be installed on the box, so this works
on any machine and inside minimal containers.

**Why this is dangerous rather than merely useless (measured 2026-09-07, SBDEV-3195):** the `-D` form
produces a **false negative that looks like a disproved hypothesis**. I was testing whether a CI
failure was locale-dependent, ran the `-D` form, saw a clean pass, and concluded locale was not the
cause. It was. The env form reproduced it immediately — 5 `can not resolve message` warnings and the
identical assertion failure, against 0 warnings and a pass under the normal environment.

This is [[a-zero-scan-needs-a-positive-control]] in its most expensive shape: the instrument agreed
with "nothing to see here". **Any locale experiment needs a control proving the fork's locale
actually changed** — count a locale-sensitive side effect (here, bundle-miss warnings), don't just
read the test result.

**Related wms2 fact:** `BusinessException.resolveMessage` calls
`ResourceBundle.getBundle("messages", Locale.getDefault())`, and **320 of 347 keys live only in
`messages_en_US.properties`** (base `messages.properties` has 27). Under any other default locale the
bundle still **resolves** — to the 27-key base — so there is **no "bundle not found" error**, just a
missing key and the raw key echoed to the user. Diagnose with the two log lines: `can not resolve
bundle` (= 0 means the bundle was found) vs `can not resolve message for key` (the real signal).
Tracked as SBDEV-3256; prod is safe only because `eclipse-temurin:21-jre-alpine` sets
`LANG=en_US.UTF-8`.
