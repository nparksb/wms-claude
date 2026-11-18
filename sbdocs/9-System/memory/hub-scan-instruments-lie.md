---
name: hub-scan-instruments-lie
description: grep/ugrep, regex and query instruments that return confident wrong answers. Hub: one line per member memory
metadata:
  type: reference
---

Hub for **Scan/census instruments that lie**. Moved out of MEMORY.md on 2026-10-15 to keep the index under its size limit; each line links the member memory.

- [[annotation-census-by-grep-is-wrong-by-default]]: Annotation census by grep is wrong
- [[grep-is-ugrep-skips-binary-without-dash-a]]: grep is ugrep: binary skipped
- [[a-zero-scan-needs-a-positive-control]]: Zero-scan needs a positive control
- [[correlated-subquery-unknown-column-binds-outer]]: Subquery unknown col binds outer
- [[a-control-on-a-literal-cannot-detect-a-narrowed-pattern]]: Control on a literal misses narrowing
- [[wms2-src-wide-scans-also-pick-up-test-classes]]: src-wide scans include test classes
- [[failed-regex-resolution-must-not-become-a-verdict]]: Failed regex must not become verdict
- [[unzip-glob-multiple-jars-is-a-false-green]]: unzip glob over 2+ jars lists nothing
- [[it-reproduces-a-bug-prd-did-not-have]]: IT red on a build PRD ran fine → runtime, not code (SBDEV-3854)
- [never-audit CHECK A doesn't find vacuity](never-audit-check-a-does-not-find-vacuity.md) — 0 noise in 104 [A] sites; the vacuous ones sit in the
- [never-audit can't see proxy-mediated calls](never-audit-cannot-see-proxy-mediated-calls.md) — "CUT doesn't reference it" ≠ vacuous; 3 landlord-TM
- [id watermark = false zero on a live wms2 DB](wms2-id-watermark-false-zero-on-live-db.md) — new rows get ids far below max(id); filter by natural key + created timestamp
- [stockrecord ids aren't monotonic on live wms2](wms2-stockrecord-id-not-monotonic-use-created.md) — an id watermark gave a false 0; watermark by `created`
- [ArchUnit: lambda calls count for the enclosing method](archunit-lambda-calls-attributed-to-enclosing-method.md) — anon class separate; method refs not calls; @Inherited not followed
