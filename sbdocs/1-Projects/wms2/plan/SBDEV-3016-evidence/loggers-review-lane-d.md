# SBDEV-3016 — Review Lane D: 11 logger-label edits (follow-up batch)

**Scope**: exactly the 11 `LOG.*` label edits listed in the task, across 6 files
(`UserController.java` ×5, `BoxTypeController.java`, `PrinterController.java`,
`UserRoleController.java`, `SystemPropertyController.java` ×2, `BillOfLadingController.java`).
True base `2d56ac4c` (per instruction, never diffed against `origin/develop`). Worktree
read-only: no `mvn`, no `git stash`/`checkout`, no writes.

Diff command used:
```
git diff 2d56ac4c -- src/main/java/net/aim_ai/wms/controller/UserController.java \
  src/main/java/net/aim_ai/wms/controller/BoxTypeController.java \
  src/main/java/net/aim_ai/wms/controller/PrinterController.java \
  src/main/java/net/aim_ai/wms/controller/UserRoleController.java \
  src/main/java/net/aim_ai/wms/controller/SystemPropertyController.java \
  src/main/java/net/aim_ai/wms/controller/BillOfLadingController.java
```

**Pre-check finding (not a defect, logged for the record):** `git diff --stat` against these 6
files shows `UserController.java | 12 ++++++------` — **6** one-line hunks, not the 5 in the
task table. The 6th is `UserController.java:675` (`getAllRoles start` → `getUserDetails start`,
inside `getUserDetails()`). This is **not an unreviewed gap** — it is the edit lane C's report
(`loggers-review-lane-c.md` item 1 row 11, item 3) already reviewed and approved as part of its
own 12-edit batch, made in an earlier round than this one. Confirmed by grep: it is present,
correct, and untouched by anything in this review's scope. Excluded from everything below.

## Verdict: APPROVE

All 11 assigned edits are correct, arity-preserving, and confined to `LOG.*` string literals.
One informational note on file-scope drift (not this ticket's to fix) and one Low on
descriptiveness. No blockers.

---

## Per-item findings

### 1. Enclosing method (brace-matched, not line-proximity) — PASS, all 11

`UserController` is the one place this specifically matters (three near-duplicate methods).
Read all three method bodies in full (`importUser` :320–362, `createUser` :365–421,
`updateUser` :424–479) and matched braces by hand rather than trusting line proximity:

| # | File:Line | Enclosing method (verified by brace match) | Correct? |
|---|---|---|---|
| 1 | UserController.java:358 | `importUser` (decl. :321, closes :362) | Yes |
| 2 | UserController.java:392 | `createUser` (decl. :366, closes :421) — nested inside the `if (!userOpt.isPresent())` else-branch at :391 | Yes |
| 3 | UserController.java:428 | `updateUser` (decl. :425, closes :479) | Yes |
| 4 | UserController.java:472 | `updateUser` (same method, `if (errors.size()==0)` branch) | Yes |
| 5 | UserController.java:475 | `updateUser` (same method, `else` branch) | Yes |
| 6 | BoxTypeController.java:69 | `createBoxType` (decl. :67, closes :92) — sits directly after the preceding `changeLocation`-style method's closing brace at :64 | Yes |
| 7 | PrinterController.java:193 | `setDefault` (decl. :191, closes :213) | Yes |
| 8 | UserRoleController.java:81 | `createRole` (decl. :80, closes :96) — bounded above by the constructor closing at :76, below by `deletRole` at :117 | Yes |
| 9 | SystemPropertyController.java:185 | `updateClient` (decl. :184, closes :212) | Yes |
| 10 | SystemPropertyController.java:198 | `updateClient` (same method) | Yes |
| 11 | BillOfLadingController.java:589 | `bolDetailsById` (decl. :588, a 3-line method) | Yes |

All 11 sit in the method the task table claims. No line-proximity mistakes found.

### 2. Arity — PASS, all 11

| # | Old label | New label | `{}` before | args before | `{}` after | args after |
|---|---|---|---|---|---|---|
| 1 | `end   create user with errors: {}` | `end   import user with errors: {}` | 1 | 1 | 1 | 1 |
| 2 | `import user - update` | `create user - update` | 0 | 0 | 0 | 0 |
| 3 | `create user: {}` | `update user: {}` | 1 | 1 | 1 | 1 |
| 4 | `end   create user` | `end   update user` | 0 | 0 | 0 | 0 |
| 5 | `end   create user with errors: {}` | `end   update user with errors: {}` | 1 | 1 | 1 | 1 |
| 6 | `create section` | `create box type` | 0 | 0 | 0 | 0 |
| 7 | `delete printer with Id {}` | `set default printer with Id {}` | 1 | 1 | 1 | 1 |
| 8 | `create printer /{}` | `create role /{}` | 1 | 1 | 1 | 1 |
| 9 | `create system property /{}` | `update client /{}` | 1 | 1 | 1 | 1 |
| 10 | `create system property finished` | `update client finished` | 0 | 0 | 0 | 0 |
| 11 | `orderDetailsByOrderId ={}` | `bolDetailsById ={}` | 1 | 1 | 1 | 1 |

Every edit is a pure text substitution inside the string literal — the arg list on each call
site is untouched, so arity cannot have drifted. Confirmed by re-reading each call site above,
not just the diff hunk.

### 3. `UserController` completeness and consistency — PASS

Enumerated **every** `LOG.*` call in the file (32 call sites, lines 164 through 683) and
checked each against its enclosing method:

- **(a) No remaining label names a different method.** Full sweep: `checkKeycloakUser` (:178,
  :182 — "get Keycloak user"), `isWmsUser` (:310), `importUser` (:324, :337 "import user -
  update", :344 "import user - create", :355), `createUser` (:369 "create user: {}", :384
  "create keycloak user", :387 "create WMS user", :414 "end create user", :417 "end create
  user with errors"), `updateUser` (:444 "update keycloak user", :447 "update WMS user"),
  `delet` (:508, :517, :537 — all say "delete"), `saveUserGroups` (:591, :593), `userDetailsById`
  (:613), `getAllRoles` (:627 — "getAllRoles start", self-naming and correct), `getUserDetails`
  (:675 — already fixed by lane C, see pre-check above), `bulkEditUsers` (:683). None of these
  remaining labels name a sibling method. Clean.
- **(b) The deliberate pairing at :414/:417 was NOT touched.** Confirmed by absence from the
  diff and by direct read: line 414 still reads `LOG.debug("end   create user");` and line 417
  still reads `LOG.debug("end   create user with errors: {}", errorMap.toString());` — both
  inside `createUser`, both legitimately say "create user", both untouched. Likewise line 337
  (`"import user - update"`, inside `importUser`) is untouched and correctly says "import" — it
  must not be confused with line 392 (`createUser`'s own copy of that branch, which **was**
  fixed from `"import user - update"` to `"create user - update"`). No correct label was
  altered.

### 4. Style consistency — informational, not a blocker

Confirmed: all 11 edits reuse each file's own pre-existing prose convention (`"create user"`,
`"create box type"`, `"set default printer"`) rather than switching to the mobile
controllers' camelCase (`createBoxType`, `setDefault`). This is the right call for this ticket:
the ticket's own stated fix discipline is a same-shape, minimal one-line label substitution
(confirmed under item 6 below — no other line in any of the 6 files changed), and unifying
prose-vs-camelCase across ~40 root controllers would be an unrelated, much larger style
refactor with zero functional payoff. Matching local convention keeps the diff auditable and
keeps this a T0/T1-shaped fix rather than growing it into a repo-wide style pass. The
inconsistency between mobile and root-controller logging styles is real but pre-existing and
out of scope — not introduced or worsened by this batch.

### 5. Semantic accuracy — PASS on both scrutinized items, plus one extra corroboration

- **`PrinterController.java:193` (`setDefault`).** Read the full method body (:191–213): it
  looks up the printer, checks whether it is already the default type-wide, and if not, flips
  the current default printer of that type to non-default and this one to default — a pure
  reassignment, no delete anywhere in the method or its call graph (no `deleteById`, no
  removal). The **old** label, `"delete printer with Id {}"`, is verbatim the label used by the
  real `deletePrinter` handler at line 157–158 in the same file (`GET /delete/{printerId}`) —
  confirmed by grep: that is a genuine, correctly-labeled, untouched sibling method. So the old
  label in `setDefault` was a copy-paste collision with a destructive sibling operation, logged
  at INFO (retained by default) — exactly the "worst line in the sweep" category the ticket's
  own CLAUDE.md note calls out. The new label, `"set default printer with Id {}"`, exactly
  matches both the method name and the URL path segment (`/setDefault/{printerId}`) and
  accurately describes what the method does. **Accurate, and the highest-value fix in this
  batch.**
- **`SystemPropertyController.java:185/198` (`updateClient`).** Read the full method
  (:183–212): it re-points a `Sysprop` row's `client_id` to a different `Client` (validates the
  new client exists, then `sysProp.setClientId(clientId); syspropRepository.save(sysProp)`).
  "update client" matches the method name (`updateClient`) and the URL (`/updateClient`)
  exactly; it is not maximally descriptive of the underlying effect (a reader unfamiliar with
  the endpoint could momentarily read it as "update a Client entity" rather than "re-point a
  sysprop's client_id"), but it satisfies the rule's actual purpose — a grep for `updateClient`
  traffic no longer returns `createSystemProperty` noise and vice versa. Not a defect; a
  reasonable candidate for a richer message in a future polish pass, not this ticket.
  Verified the **other** `"create system property"` labels in the same file (lines 102 and 137,
  inside `createSystemProperty`, decl. :101, closes :146 — bounded above by `updateValue` at
  :100's predecessor and below by `updateValue` at :148) belong to that genuine create handler
  and were correctly left untouched — confirmed by diff absence and direct read.
- **Extra corroboration on `BillOfLadingController.java:589`.** The old label,
  `"orderDetailsByOrderId ={}"`, does not name any live method in this file or anywhere else in
  `src/main/java/` — the only match repo-wide is a **commented-out** dead method in
  `ClubLineController.java:191-192` (`// public Map<String, Object>
  orderDetailsByOrderId(...) { // LOG.debug("orderDetailsByOrderId ={}", orderId); }`). So the
  old label was copy-pasted from what is now dead code — still worth fixing (a misleading label
  survives even when its origin doesn't), and the new label `"bolDetailsById ={}"` matches the
  enclosing method and endpoint exactly. Informational only; doesn't change the verdict.

### 6. Over-reach — PASS, all 6 files

Re-examined the full diff for all 6 files: every hunk is a single-line change entirely inside
a `LOG.debug(...)` / `LOG.info(...)` string-literal argument. `git diff --stat` for the 6 files
shows exactly 12 changed lines (1+1+1+2+6+1, matching BillOfLading/BoxType/Printer/UserRole at
1 each, SystemProperty at 2, UserController at 6 — 5 assigned + the 1 pre-existing lane-C fix
at :675 noted above). No signature changes, no added/removed statements, no changes to any
file outside these 6, and no change touches a line outside a `LOG.*` call. **PASS.**

---

## Summary

| # | Finding | Severity |
|---|---|---|
| 1 | `UserController.java:675` sits in the diff against `2d56ac4c` but is lane C's edit, already reviewed and approved — not a gap in this review's coverage | Informational |
| 2 | `SystemPropertyController.java:185/198` — "update client" is accurate but not maximally descriptive of the client_id re-pointing effect | Low |
| 3 | Mobile-vs-root-controller logging style stays inconsistent repo-wide | Low (pre-existing, out of scope) |

No Medium/High/Blocker findings. All 11 assigned edits are correct fixes for genuine
method-name collisions, confined strictly to `LOG.*` string literals, arity-safe, and
consistent with each file's local convention.

**File:** `/home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-3016-evidence/loggers-review-lane-d.md`
**Verdict: APPROVE**
