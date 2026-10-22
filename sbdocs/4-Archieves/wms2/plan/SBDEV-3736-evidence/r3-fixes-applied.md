# SBDEV-3736 — round-3 fixes applied (2026-10-15)

Report: 3-Resources/reports/261013-returns-audit-linkage-field-map.md

- R3-1: §8 T2 bullet no longer promises the §5.10 flag in a WMS-only report; flag = ad-hoc two-step support query (option 3), built-in flag = option 2 / T3. §5.10 Consequence and decision 5 mirrored.
- R3-2: S3 is T1 on its own, rides the T2 deliverable (transaction_detail() output + V2.2.25 IT); same sentence in §8 and the S3 table row.
- R3-3: lane-wms.md §0 item 4 and §4 row 8 annotated (2025-26 second CREATED row); "ran this shape" line reworded (original label-join on UAT = superseded; current SQL on PRD 2026-10-15). Report §11 row added.
- R3-4: §5.10 query scoped to post-cutover cohort (WineCo created > 2026-09-26, 22 advices); v1-era cohort caveat added.
- R3-5: §10 reviews line (19 findings + r3), "applied or answered" in §4/§11, re-pin note for 371d8a09 / 4981db86 incl. SBDEV-3742 note; frontmatter verified_by SHAs re-pinned, updated: 2026-10-15.
- Report §8: decisions 1-6 marked ANSWERED; new "### Decisions (Nam, 2026-10-15)" subsection; §11 round-3 row.
