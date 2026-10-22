# SBDEV-3183 ClickUp description update, 2026-10-21 (PR #550)

Re-fetched after clickup_update_task; status unchanged (in development). Verified present:
1. Counts paragraph: 35 exported, 27 ruled, 8 unruled (boot line on dev develop-cb692ee6, after PR #550)
2. Ruled (27) heading plus the new bullet
3. Unruled (8) line, must-stay-open set pinned by SdrMustStayOpenRailUnitTest
4. AC-5 bullet: counters-reset sentence appended; Open: AC-7, AC-8 kept
5. Merged this round: PR #550 bullet
6. "In progress" paragraph deleted
7. Section 1 title, "How the count fell" line, "Done in PR #550" prefix, Pickingorder replacement
8. Landmines: Printer ruled sentence appended to WMS_PRINTER_SEARCH_BY_TYPE_ENDPOINT bullet

AC checklist intact: AC-1,2,3,4,6,9 [x]; AC-5,7,8 [ ].

Known cosmetic artifact: ClickUp's round trip doubled the existing backslash escapes in two
pre-existing spots (the `\*\*\*\*` after "Every other tenant is at OFF" and the `\_\_` in the
REVERSED landmine). Text content unchanged; not edited further to avoid doubling again.
