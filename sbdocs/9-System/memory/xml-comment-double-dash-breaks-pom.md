---
name: xml-comment-double-dash-breaks-pom
description: "`--` inside a pom.xml comment makes the POM unparseable; text-scanning rails (JUnitTagWiringArchTest) stay green — parse the POM before committing"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 6aa2670b-eed0-4a5e-bab9-37b3afb51578
  modified: 2026-10-09T14:45:42.974Z
---

An XML comment may not contain `--`. Writing prose like "the full --log-failed of each" or a CLI flag (`--activate-profiles`, `--define`) inside a `<!-- -->` block in pom.xml makes Maven fail at project load ("in comment after two dashes (--) next character must be >"). Committed once on SBDEV-3294 (2026-10-09); caught only by the next full `mvn verify`.

**Why:** the POM-reading unit rails (JUnitTagWiringArchTest, etc.) read pom.xml as TEXT with regexes, so they stay green on an unparseable POM, and a scoped `-Dtest=` run after a prose-only edit is easy to skip. It produced a broken-build commit, which [[commit-without-asking-use-judgement]] forbids.

**How to apply:** after any pom.xml edit, run `python3 -c "import xml.dom.minidom as m; m.parse('pom.xml')"` before committing. In POM comments write flags without the leading dashes or describe them in words.
