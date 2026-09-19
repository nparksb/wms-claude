---
name: wms2-businessexception-key-vs-message-traps
description: "wms2-api BusinessException has two traps — the 1-arg ctor silently sets key=\"placeholder\", and getMessage() returns the key ONLY while it is absent from the messages bundle"
metadata: 
  node_type: memory
  type: reference
  originSessionId: efd01c9d-9df5-4c42-b917-c52bf750f2a6
  modified: 2026-08-10T00:36:17.938Z
---

`v2/wms2-api` `exceptions/BusinessException.java` — two traps that both produce silent, plausible-looking
wrong behaviour. Cost two debug cycles on SBDEV-2732.

**1. `new BusinessException("someKey")` is the MESSAGE constructor, not the key one.** It sets
`key = "placeholder"` and stores your string as a *parameter*. Only the varargs form
`BusinessException(String key, Object... parameter)` — with **at least one param** — produces a keyed
exception. So a 1-arg call expecting a key is silently non-keyed and `getKey()` returns `"placeholder"`.

**2. `getMessage()` resolves through the `messages` ResourceBundle**, so it returns the *key* only while
that key is **missing** (the `concatenateKeyAndParameter` fallback) and returns *rendered, localised text*
once present. Consequence for tests: `assertThat(ex).hasMessageContaining("<myKey>")` **passes only while
the feature is unbuilt and fails once the message is added** — a test that fails a correct implementation.
Assert `getKey()` instead (accessor added by SBDEV-2732; there was none before).

Corollary for verify scripts and tests generally: a gate test failing "for the right reason" is necessary
but **not sufficient** — also check it is *satisfiable*. Three defects of this family surfaced in one
SBDEV-2732 session: verify row `X-2732-authz` (asserted the absence of an annotation that is correct to
write), `A0-ctx1` (asserted a constant still held its pre-fix value), and two controller gate tests that
made the same call with opposite expectations.

Related: [[verify-script-traps]],
[[negative-test-verify-scripts-before-trusting-them]],
[[resourcebundle-parent-chain-hides-child-deletion]]
