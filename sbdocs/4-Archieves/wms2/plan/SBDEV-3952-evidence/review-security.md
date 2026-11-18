# SBDEV-3952 — security lane (2026-10-31)
head: 62b50d17. Reviewer: oh-my-claudecode:security-reviewer. Saved by the main session.
**Verdict: PASS.** Risk LOW. 0 Critical/High/Medium.

- **SQL injection:** no new exposure. The new sort columns are compile-time constants. The user sort goes through stableReportColumn and PagedListSort as a plain Sort.Order, not JpaSort.unsafe. All parameters are bound.
- **Data exposure:** none. ViewDtoService builds its 14-key map by hand, and the export uses Object[14]. The repository has exported=false. There is no projection.
- **Privileges:** CREATE OR REPLACE keeps the owner and the table-level grants. A view owned by another role fails closed with 42501. Every relation is schema-qualified with `public.`.
- **Cross-tenant:** none; the view reads only public.* in one DB.
- **Authorization:** @RequiresFunction(WEB_UI_VIEW_FLOWBIN_MONITOR) is unchanged on both endpoints.
- **Low (info):** a user can now sort by surrogate ids. No action.
- **Doc nit:** the migration header names `db/reassign-tenant-ownership.sh`; the file is at `src/main/resources/db/…`. The reviewer believed this was frozen. It is not: V2.2.43 has not been applied to any real DB, so the main session fixes it before push.
