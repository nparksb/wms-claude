---
name: wms2-gitignore-swallows-new-properties-files
description: wms2-api .gitignore blanket-ignores *.properties with per-file negations, so any NEW properties file is silently un-addable — the classic "works locally, doesn't reproduce from the branch" cause
metadata:
  type: project
---

`v2/wms2-api/.gitignore:59` is a blanket `*.properties`, followed by explicit negations only for the
files that already exist (`!application.properties`, `!application-integration.properties`,
`!messages*.properties`, `!archunit.properties`).

**So a NEW properties file cannot be committed.** `git add` refuses it and prints only a hint —
no error, and `git status` never shows it. Add the negation line first.

**Why it matters beyond the annoyance:** this is a silent producer of *unreproducible* work. Hit on
SBDEV-3239 / PR #308 — the author's Testcontainers lane genuinely measured "352 run, 0F, 0E", but
`application-postgres-integration.properties` never made it into the commit, so from the branch
**every** `BasePostgresIntegrationTest` subclass failed context load. The numbers were honest and
the branch was broken, at the same time.

**Symptom to recognise:** a lane that works on the author's machine and fails identically for
everyone else, with a config-shaped error (missing property, unresolvable `@Value` placeholder,
duplicate bean that a profile was supposed to suppress). Check `git check-ignore -v <file>` before
believing the code is wrong.

Note `TrackedPropertiesNoPlaintextSecretArchTest` derives its file list from these `!` un-ignores,
so adding a negation also brings the new file under the plaintext-secret guard — a reason to add the
negation rather than force-add with `-f`.
