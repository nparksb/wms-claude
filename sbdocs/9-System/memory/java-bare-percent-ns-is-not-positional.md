---
name: java-bare-percent-ns-is-not-positional
description: In wms message bundles `%1s`/`%2s` are NOT positional (that is `%N$s`) — bare `%Ns` is minimum-width, so args stay in call order; plus the base-bundle/LANG story is subtler than SBDEV-2632/2731 claim
metadata:
  type: reference
---

Two traps in `v2/wms2-api/src/main/resources/messages*.properties`, both hit on SBDEV-3004.

**1. `%1s` is not positional.** Positional is `%N$s`. Bare `%Ns` means *minimum width N* with
conversion `s`, so arguments are still consumed **sequentially**. A key written
`No %2s found with label %1s.` called with `(label, type)` renders
`No IN-000123 found with label Pallet.` — a fluent sentence that **lies about which value is
which**, which is worse than the raw `key, 'arg'` fallback it replaced. Measured. Most existing
keys survive only because their args happen to be in declaration order; the bare form also
silently width-pads (a 1-char state through `%3s` gains two leading spaces — `unexpectedStateFound`
in en_US has this shape).

**2. The base-bundle gap is real but was NOT live — and the recorded precedent is wrong about why.**
`BusinessException` resolves `ResourceBundle.getBundle("messages", Locale.getDefault())`, so a key
declared only in `messages_en_US.properties` falls through to `messages.properties` and emits the
raw fallback. `messages.properties` documents this twice (SBDEV-2632 `placeholder`, SBDEV-2731 Fix C
`unitloadTypeNotPermittedOnLocation`) and **both say "nothing pins the locale in the Dockerfile or
CI". That is misleading**: the runtime base image `eclipse-temurin:21-jre-alpine` ships
`LANG=en_US.UTF-8`, and all three CI workflows build from that Dockerfile, so `Locale.getDefault()`
IS `en_US` on dev/UAT/prd. Measured JVM mapping:

| `LANG` | `Locale.getDefault()` |
|---|---|
| unset · `C` · `POSIX` · `en_US.UTF-8` | `en_US` |
| **`C.UTF-8`** | **`en`** ← falls through to base |

`C.UTF-8` is the default in many slim/distroless images, so a base-image bump would silently trip
it. Keep declaring keys in base (defence in depth) but do not claim it fixes a live defect.
`ENV LANG=en_US.UTF-8` in the repo Dockerfile would close the class for all ~354 keys at once;
duplicating keys per-ticket has now happened three times and covers ~21.

**Testing them:** load each file with `Properties.load(new InputStreamReader(in, UTF_8))` — a plain
`ResourceBundle` lookup is satisfied by the en_US child and hides an absent base key
([[resourcebundle-parent-chain-hides-child-deletion]]). Use the `Reader` overload:
`Properties.load(InputStream)` is ISO-8859-1 while `PropertyResourceBundle` is UTF-8, so the
stream form validates non-ASCII messages as mojibake and passes. Assert **both** that the two
bundles render identically (catches a swap in one) **and** the semantic slot order (catches a swap
applied to both). Precedent: `unit/i18n/ReceivingMessageKeyContractTest`.

Service tests here assert `getKey()`, not the text ([[wms2-businessexception-key-vs-message-traps]]),
which is right — and means argument order is unpinned unless a bundle test does it.
