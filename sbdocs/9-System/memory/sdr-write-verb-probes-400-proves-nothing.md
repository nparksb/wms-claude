---
name: sdr-write-verb-probes-400-proves-nothing
description: A 400 from an SDR POST/PATCH/PUT proves NOTHING about whether the verb is withdrawn — the body is rejected before the exposure check; use OPTIONS Allow + body-free DELETE + well-formed {} PATCH
metadata:
  type: feedback
---

Measured live on `wms-api.dev.sbo.li` 2026-08-24 while QAing SBDEV-3077.

I probed withdrawn SDR write verbs with a deliberately malformed body (`{"zzz":`) so that an *allowed*
method could only reach 400 and never actually write. Every row came back **400**, and I read that as
"method allowed → fix not deployed." **The probe was measuring nothing.**

Proof it was worthless — a positive and a negative control returning the identical code:
- `POST /v3/userFunction` (verb **exposed**) → 400
- `POST /v3/userRoleUserFunction` (verb **withdrawn**, confirmed) → 400

Sending **no body at all** changes nothing: all of POST/PATCH/PUT still return 400 regardless of
exposure. The missing/unparseable body is rejected **before** the exposure check, so 400 is returned
for withdrawn and exposed verbs alike. Any "expect 405, got 400 ⇒ not deployed" conclusion is invalid.

**What actually works, in order of preference:**
1. **`OPTIONS <resource>` and read the `Allow:` header** — body-free, safe, enumerates every verb at
   once. `Allow: HEAD,GET,OPTIONS` = all writes withdrawn; `HEAD,GET,OPTIONS,PUT` = PATCH+DELETE
   withdrawn, PUT kept. Corroborate, never rely on it alone — see
   [[advertised-capability-is-not-exploitable-capability]].
2. **`DELETE <collection>/999999999`** — DELETE carries no body, so the exposure check is reached:
   **405 = withdrawn, 404 = exposed**, and a nonexistent id cannot destroy anything.
3. **`PATCH <item>` with a well-formed `{}`** — a genuine no-op merge, so 405-vs-200 is unambiguous
   and nothing changes.
4. **Never `PUT` with `{}`** to test exposure — PUT *replaces*, so it blanks fields. Confirm PUT
   retention via `OPTIONS`, or PUT the entity's own current state back.

**Two confounds that make a DELETE 405 mean something other than your fix** — check both before
crediting a withdrawal:
- the repository may extend `NoDeletePagingAndSortingRepository` (`UserRoleRepository` does), which
  withdraws item DELETE with no `RestConfiguration` involvement at all;
- a **composite-id** entity (`UserGroupUser`/`UserGroupUserId`) doesn't map a normal item route, so it
  405s regardless. Pick a probe type whose repository is a plain `CrudRepository` — `User` and
  `UserGroup` are, which is what finally dated the deployed build.

**Also:** `flyway_schema_history` dates the last boot only when a migration was *pending*. A redeploy
carrying no new migration leaves no row, so the newest `installed_on` is a **lower bound** on the
build date, never the build date. I wrongly concluded "build predates Aug 21" from it.
