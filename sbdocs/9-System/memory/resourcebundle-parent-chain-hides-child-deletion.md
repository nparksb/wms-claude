---
name: resourcebundle-parent-chain-hides-child-deletion
description: wms2-api message keys live in two bundles; any ResourceBundle-based assertion (even ROOT-vs-US equality) cannot detect deletion from the child bundle — only a direct Properties.load per file can
metadata: 
  node_type: memory
  type: project
  originSessionId: 33329edc-8595-4c45-9986-057c85b50bc6
  modified: 2026-08-02T12:48:50.760Z
---

`v2/wms2-api` resolves `BusinessException` keys via
`ResourceBundle.getBundle("messages", Locale.getDefault())` **at construction time**, against two files:
`src/main/resources/messages.properties` (base) and `messages_en_US.properties`.

**`messages.properties` is the PARENT of every locale bundle.** So deleting a key from
`messages_en_US.properties` alone changes nothing observable — `Locale.US` resolution falls through the
parent chain and returns the base string. Proven on SBDEV-2731 (2026-08-02): with the en_US key deleted,
the whole class stayed green at 39/39.

**Consequence for tests:** any assertion that goes *through* `ResourceBundle` — including a
`getLocalizedMessage(Locale.ROOT)` vs `getLocalizedMessage(Locale.US)` equality check — catches
**divergence** between the two copies but **cannot catch deletion** from the child. A code reviewer
proposed exactly that equality check as a complete fix and it was insufficient.

**Only a direct `Properties.load` of each file** (`getClass().getResourceAsStream("/messages_en_US.properties")`)
bypasses the chain and pins presence in both. Compare the **raw template** (`A %1$s unit load ...`), not
the rendered message — `String.format` is applied downstream, and comparing against the formatted string
fails.

**Why the duplication is required at all:** resolution happens under the JVM default locale, so a key
present only in `messages_en_US.properties` fails to resolve on a non-en_US default. Precedent
`BusinessException.MissingReceivingConfiguration` (SBDEV-2729). SBDEV-2732 §5.1 row 0 / `:1474` also
*requires* `unitloadTypeNotPermittedOnLocation` in both files — a requirement that had zero test
enforcement until the per-file read was added.

Reference implementation: `UnitloadBusinessServiceUnitTest.shouldResolveConstraintMessageFromBaseBundle`
(T14b) does all three — ROOT resolution through the real code path, ROOT==US equality, and direct
per-file reads.

Same family as [[verify-script-traps]]: an assertion that looks like a guard
but silently cannot fail. See also [[sbdev-2731-pr1-display-and-message-only]].
