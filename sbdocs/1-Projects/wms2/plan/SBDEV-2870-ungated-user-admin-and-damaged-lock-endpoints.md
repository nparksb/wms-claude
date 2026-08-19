---
title: "WMSv2: 5 ungated user-administration endpoints on AdminController (damaged-lock pair relocated to SBDEV-2967)"
ticket: "SBDEV-2870"
ticket_url: "https://app.clickup.com/t/868knqrwr"
type: "bugfix"
priority: "urgent"
status: "pr submitted — wms2-api PR #166 (commit 989611e) into develop, 2026-08-17. Independently code-reviewed. 6 of 7 ACs met. Residual: AC-5 for the ONE @PreAuthorize endpoint (1 curl), and AC-7 wording (identity creation still open via ticket SBDEV-2984). Fix C/D relocated to SBDEV-2967 Fix E 2026-08-17."
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-17
updated: 2026-08-17
db_verified: true
related:
  - SBDEV-2967-web-ui-function-gating-enforcement.md
  - SBDEV-2968-mobile-ui-function-gating-enforcement.md
  - ../../../3-Resources/architecture/wms2-keycloak-role-matrix.md
tags:
  - plan
  - security
  - authorization
  - retroactive
---

# SBDEV-2870 — Ungated user-administration endpoints

*(The damaged-lock pair is enumerated here as the record of the finding; its implementation moved to SBDEV-2967 Fix E — §3.3.)*

**Ticket:** [SBDEV-2870](https://app.clickup.com/t/868knqrwr) · **urgent**
**Branch:** `bugfix/SBDEV-2870-restrict-csv-user-import-to-wms-admin` (worktree `.claude/worktrees/wms2-api/SBDEV-2870`)
**PR:** [wms2-api #166](https://github.com/SiteBossInc/wms2-api/pull/166) → `develop` · commit `989611e` · based on `2be4ea5`
**Follow-up ticket:** [SBDEV-2984](https://app.clickup.com/t/868kt73f9) — `/user/create`, `/user/importUser`, `/user/delete` still ungated (§10.10)

> The branch name predates the 2026-08-17 decision that the CSV endpoint takes `sb_admin`, not `wms_admin`. Kept as-is because the docs and the pushed ref reference it; the PR title is the accurate description.
**Repos:** `v2/wms2-api` only

> ⚠️ **THIS PLAN IS RETROACTIVE.** The code was written first, incrementally, from a small request
> ("if it's relatively easy, restrict the CSV import to `wms_admin`") that grew to 6 files / 311
> insertions across two authorization mechanisms plus a global CORS change. No plan and no verify
> script existed while that happened. This document reconstructs what a plan would have contained
> **and records what its absence cost** (§11.2) — three of the four open items in §10 are exactly the
> things a §0 enumeration or §5.1 prerequisite list would have surfaced up front. It is written to
> make the remaining work trackable, not to imply the sequence was clean.

---

## 0. Affected sites

### 0.A In scope — the user-administration endpoints (5 from the ticket, +1 found by review)

All were reachable by **any authenticated `wms_user`**: `/v3/**` → `hasAnyAuthority("wms_user")` (`SecurityConfiguration:143`) was the only gate.

| # | Endpoint | Prior guard state | Now (revised 2026-08-17) |
|---|---|---|---|
| 0.1 | `GET /v3/admin/importUsersFromCsvText` (`AdminController:190`) | commented out — **deliberate** (`5ac0262c`, 2024-10-16, before the SBDEV-2863 rename) | `@PreAuthorize(IS_SB_ADMIN)` — stays in `AdminController`, tied to **no** function |
| 0.2 | `POST /v3/user/addUserToWarehouseGroup` (`:261`) | commented out — **collateral** of SBDEV-2863 | function `WEB_UI_VIEW_USER_MANAGEMENT`, in new `UserAdministrationController` |
| 0.3 | `POST /v3/user/removeUserFromWarehouseGroup` (`:285`) | commented out — collateral | function `WEB_UI_VIEW_USER_MANAGEMENT` |
| 0.4 | `GET /v3/user/isWarehouseUser` (`:315`) | commented out — collateral | function `WEB_UI_VIEW_USER_MANAGEMENT` |
| 0.5 | `GET /v3/user/existsInKeycloak` (`:359`) | **never annotated** | function `WEB_UI_VIEW_USER_MANAGEMENT` |
| **0.16** | `POST /v3/user/saveUserGroups` (`UserController:263`) | **never annotated** — found by code review 2026-08-17, NOT in the original ticket | function `WEB_UI_VIEW_USER_MANAGEMENT` (**Fix E**, §3.2.1) — without this, 0.2–0.5 are bypassable in one request |

0.2–0.4 were committed already-commented by `c8ce58d9` (2026-02-01), which *replaced* three previously-**guarded** endpoints — three months into the window when `@PreAuthorize(IS_SB_ADMIN)` returned HTTP 500 to everyone. They are accidental authorization losses, not decisions.

> [!important] The axis changed on 2026-08-17, at Nam Park's direction
> The first implementation put all five on the `wms_admin` **Keycloak group**. That is a *different axis* from the one that already grants the screen (the `WEB_UI_VIEW_USER_MANAGEMENT` **function**, held by 39 live users via `super-admin` on WineCo dev), which is what made AC-4 an unanswerable-from-here question and left AC-5 untestable. 0.2–0.5 now gate on that function. Two consequences, both good: AC-4 **dissolves** (nothing left to confirm in Keycloak), and AC-5 becomes **testable** (see §6). 0.1 is unchanged — by standing instruction it is tied to no function at all.

### 0.A.1 ⚠ `AdminController` is a base class for 43 controllers — the real ungated surface was ~5× larger

Found 2026-08-17 while implementing. `AdminController` is not only a controller; **43 other controllers extend it**, and every one declares its own class-level `@RequestMapping`. That is what stops Spring failing on ambiguous mappings — and it also means each of `AdminController`'s mapped methods is **re-registered under all 43 prefixes**:

```
/v3/user/isWarehouseUser          <- the only one the UI calls
/v3/picking/user/isWarehouseUser  <- inherited via PickingController      @RequestMapping("/v3/picking")
/v3/report/user/existsInKeycloak  <- inherited via ReportController       @RequestMapping("/v3/report")
/v3/stockUnit/user/addUserToWarehouseGroup                              … × 43
```

So the four ungated endpoints were reachable on **176 paths**, not 4. Extracting them into `UserAdministrationController` (§3.2) collapses that to the 4 the UI actually calls — the fix *removes* surface rather than only gating it.

This also means **the endpoint inventories in SBDEV-2967 §0.B and SBDEV-2968 are understated** for anything inherited from `AdminController`. Recorded as §10.8.

### 0.B ⚠ Every route to a damaged lock — the enumeration that was missing

**This table is the one whose absence cost the most.** `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` is widely believed to be enforced. Enumerating every writer of `BusinessObjectLockState.QUALITY_FAULT` (103) shows **four** routes, of which one is still open:

| # | Route | Writer | Guard | Covered? |
|---|---|---|---|---|
| 0.6 | `POST /v3/stockUnit/transferStock` → `StockunitService.transferStock` (`:150`) | `StockunitService:244` | `doesUserHaveAccess` at `:232` — **inside a conditional branch** (destination `DAMAGED` **and** lock already `QUALITY_FAULT`) | pre-existing ✅ |
| 0.7 | `POST /v3/stockUnit/transferToDamaged` (`:444`) → `setLockDamaged` (`:360`) | `StockunitService:397` | **none** | ➡️ **SBDEV-2967 Fix E** (§3.3) |
| 0.8 | `POST /v3/stockUnit/bulkTransferToDamaged` (`:485`) → same | `StockunitService:397` | **none** | ➡️ **SBDEV-2967 Fix E** (§3.3) |
| 0.9 | mobile move-unitload damage flow | `MobileMoveUnitloadService:511` | `doesUserHaveAccess` at `:277`/`:282` | pre-existing ✅ |
| 0.10 | 🔴 **`PATCH /v3/stockunit/{id}` — Spring Data REST** | direct property write | **NONE** | ❌ **open — §10.2** |

**The figure "1 of 80 functions is enforced" needs this footnote.** The one enforced function is checked in *one conditional branch of one unrelated method* (0.6); its own dedicated endpoints (0.7/0.8) were open, and a fourth route (0.10) bypasses the service layer entirely.

### 0.C Supporting sites

| # | Site | Role |
|---|---|---|
| 0.11 | `Authority.java` | gains `WMS_ADMIN_ROLE` only — `IS_WMS_ADMIN` was added then **deleted** once 0.1 moved to `sb_admin` and 0.2–0.5 + 0.16 to the function model, leaving it unreferenced (§3.1). *(`AUTHZ_DENIED_HEADER` went to 2967 with Fix C — §11.4.)* |
| 0.12 | `SecurityConfiguration:120` | `/actuator/**` — the pre-existing `wms_admin` gate; literal replaced with the constant |
| 0.13 | `SecurityConfiguration:167-188` | CORS exposed-headers — **unchanged by this ticket**; the `X-Authz-Denied` entry moved out (§11.4). ⚠️ **Its destination is SBDEV-2968 §3.1-A2b, not 2967** (reassigned 2026-08-17 on ordering — 2968 lands first). Retained here only as the site 2968 must edit. |
| 0.14 | `StockunitRepository:27` | `@RepositoryRestResource(path="stockunit")` over `CrudRepository`, `exported=false` on query methods only — the 0.10 surface |
| 0.15 | `RestConfiguration:24,32` | SDR base path set to `/v3` **programmatically**, not by property — so 0.10 *is* behind the `wms_user` floor, not open to a zero-authority principal |

---

## 1. Problem Statement

### 1.1 Symptom

**Five** endpoints performed privileged Keycloak-identity operations with no authorization beyond "is a WMS user" — including `importUsersFromCsvText`, which **bulk-creates users from a CSV string**. A privilege-escalation path open to any warehouse operator.

*(A further two — the damaged-lock pair — were found ungated during this work and are enumerated at §0.B rows 0.7/0.8. Their fix moved to SBDEV-2967 Fix E; see §3.3.)*

### 1.2 DB verification (`db_verified: true`)

Queried live on `wms2-wineco-dev` 2026-08-16/17:

| Query | Result |
|---|---|
| Roles holding `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` | **`super-admin` only** |
| Non-`super-admin` roles holding **any** `WEB_UI_ACTION_*` | **none** (0 across all 10 named roles) |
| Live users (excl. `Z-` archived) | 52 — 39 in `super-admin`, 13 not |

**So gating 0.7/0.8 would remove the damaged-lock capability from ~13 of 52 live users**, including all 4 `CS-REP` users. That is a real behaviour change — and it is the reason Fix C moved: gating **one of six** sibling row actions on the same page would have produced an unexplainable state. The measurement now serves SBDEV-2967 §5.1-P2, which covers all six at once.

### 1.3 Scope

**In scope:** authorization on the **five** user-administration endpoints. *(Originally seven — the damaged-lock pair moved to SBDEV-2967 Fix E on 2026-08-17, and the `X-Authz-Denied`/CORS work to SBDEV-2968 §3.1-A2b later that day; see §3.3 and §11.4.)*
**Out of scope:** the SDR bypass (§10.2 — own ticket), the `printLabel` unboxing NPE (§10.5), and the audit-comment defect ([SBDEV-2979](https://app.clickup.com/t/868kt336b)).

---

## 2. Root Cause Analysis

**RC-1 — four of the five user-admin guards were casualties of SBDEV-2863, not decisions.** `@PreAuthorize(IS_SB_ADMIN)` named a non-existent SpEL method from 2025-10-29 to 2026-08-07 and returned HTTP 500 to every caller. A developer adding a guard, seeing a 500, and commenting it out is the obvious reading of `c8ce58d9`. `:190` is the genuine exception.

**RC-2 — the ticket was blocked on a false dichotomy.** Its recorded blocker was *"restoring the annotations would 403 the User Management screen for every non-`sb_admin` admin."* True — **for `sb_admin`.** The target-state decision (role matrix §1.1: no function should be `sb_admin`-only) opened a third option that did not exist when the ticket was written: **`wms_admin`**, which a customer admin holds and a warehouse operator does not.

**RC-3 — the damaged-lock gap was invisible because the constant appears at the wrong layer.** `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` is referenced in `StockunitService`, so a reader concludes the action is guarded. The check is in `transferStock`'s conditional branch; `setLockDamaged` — the method the dedicated endpoints call — never had one. Only an enumeration of *writers of the lock value* (§0.B) exposes this; grepping the constant does not.

**RC-4 — no test could have caught any of it.** `standaloneSetup` (`BaseControllerUnitTest:50`) installs no method-security advisor, so no controller test in this repo evaluates `@PreAuthorize`, and the `@SpringBootTest` lane is down (SBDEV-2217). The five annotations are inspection-only by construction. **This is why §3.3's gate was deliberately placed where it *is* testable.**

---

## 3. Fix Design

### 3.1 Fix A — `Authority` constants

`WMS_ADMIN_ROLE = "wms_admin"` — **that is all that remains.** Its only purpose is to remove the bare `"wms_admin"` string literal from the `/actuator/**` matcher at `SecurityConfiguration:120`, which is its **single** consumer (pinned by verify row `A4`).

**There is deliberately no `IS_WMS_ADMIN` expression.** An earlier revision added one to gate all five endpoints; it was removed once 0.2–0.6 went to the function model and 0.1 went to `sb_admin` (§3.2), leaving it with zero references. A dead SpEL constant in a security class invites exactly the kind of misuse this ticket exists to fix, and §1.1's target state reserves `wms_admin` for `/actuator/**` alone. The `Authority.java` javadoc records this so nobody reintroduces it speculatively; verify rows `A2`/`A3` assert it stays gone.

Retained for whoever *does* add a future expression here: it must be a `hasAuthority` **literal**, never a custom SpEL method name — that is the SBDEV-2863 defect exactly. And `hasAuthority`, not `hasRole`: `JwtAccessTokenCustomizer.extractRoles` emits bare names, so `hasRole` would look for `ROLE_wms_admin` and never match. Any such constant must also be declared *below* `WMS_ADMIN_ROLE` — a simple-name forward reference in a field initializer does not compile.

⚠ **Compile-time constants are inlined by javac and `pom.xml:440` disables incremental compilation. Verify only against `mvn clean`** — a warm `target/` reproduces the old value.

### 3.2 Fix B — the user-administration gates (REDESIGNED 2026-08-17)

Two mechanisms, because the five endpoints are not one category.

**0.1 `importUsersFromCsvText` → `@PreAuthorize(Authority.IS_SB_ADMIN)`.** It manufactures identities rather than performing a warehouse operation, and by standing instruction (Nam Park, 2026-08-16) it must not be tied to *any* `FunctionEnum` function.

**`sb_admin`, not `wms_admin`** (owner-confirmed 2026-08-17): the intended caller is **SiteBoss staff** running a client onboarding by hand, and staff carry `sb_admin`. An interim revision used `wms_admin`, which would have returned **403 to the only people the endpoint was retained for** while every other endpoint on the same class accepted them — the reviewer caught the inconsistency between the gate and the comment three lines above it. This also *restores* what `5ac0262c` commented out: the original intent was already `sb_admin`, and unlike 0.2–0.5 that comment-out predates the SBDEV-2863 rename and was a real decision.

Consequence worth recording: that left `Authority.IS_WMS_ADMIN` with **zero references**, so it was deleted. A dead SpEL constant in a security class invites misuse, and per role-matrix §1.1 `wms_admin` gates `/actuator/**` and nothing else. `WMS_ADMIN_ROLE` survives as the actuator matcher's constant — exactly one consumer, pinned by verify row `A4`, with a javadoc note so nobody re-adds the expression speculatively.

**0.2–0.5 → the function `WEB_UI_VIEW_USER_MANAGEMENT`, in a new `UserAdministrationController`.**

```java
private void denyUnlessUserManagementAllowed() {
    if (!accessService.doesUserHaveAccess(WmsConstants.FunctionEnum.WEB_UI_VIEW_USER_MANAGEMENT)) {
        LOG.warn("Denied user-administration call for {}: missing function {}", …);
        throw new AccessDeniedException("Missing function " + …);   // -> 403
    }
}
```

Three design points, each load-bearing:

1. **The function, not the group.** `WEB_UI_VIEW_USER_MANAGEMENT` already exists and is already granted, via `super-admin`, to exactly the intended users (39 live on WineCo dev). Gating on it keeps the screen gate and the API gate on **one axis**, so no current user loses access — which is what dissolves AC-4. Gating on `wms_admin` would have 403'd any function-holder outside that Keycloak group, and because both UIs' axios interceptors treat 403 like 401 (retry ×3, then `$kc.logout()`), those users would have been **logged out on opening the screen**.
2. **A plain method call, not `@PreAuthorize`.** SpEL cannot express a per-tenant DB lookup without a custom expression-root method — and a custom method name that fails to resolve *is* SBDEV-2863, which returned HTTP 500 to everyone for nine months. Decisively: `standaloneSetup` (`BaseControllerUnitTest:50`) installs no method-security advisor, so **no controller test in this repo can evaluate `@PreAuthorize`**, and the `@SpringBootTest` lane is down (SBDEV-2217). An ordinary call is assertable. This is the whole reason AC-5 moves from "manual curl matrix" to "covered by tests".
3. **A separate controller.** Necessary, not cosmetic. `AccessService` could not be constructor-injected into `AdminController` without threading the new argument through all **43** subclasses and their tests, for a dependency four methods use — and extraction additionally collapses the 176-path inherited surface of §0.A.1 down to 4.

> [!warning] The guard MUST be the first statement, outside the `try`
> All four endpoints wrap their body in `catch (Exception e)` → HTTP 500 with `e.getMessage()`. A guard placed *inside* the `try` is swallowed into a 500 that also **leaks the denial reason to an unauthorized caller**. Same shape as the SBDEV-2632 defect (`parseLongs` outside the try at `:111` vs inside at `:123`). Pinned two ways: verify row `C8` parses each method and asserts the call precedes `try {`, and each deny test asserts the call *throws* rather than returning a `ResponseEntity`. **Ablation-proven** — moving one guard inside its try failed exactly that endpoint's test (§6.4).

### 3.2.1 Fix E — `saveUserGroups`, the hole that defeated Fix B (added 2026-08-17 at owner's direction)

Fix B gates four endpoints on a function resolved through `mywms_group_mywms_user`. `POST /v3/user/saveUserGroups` (`UserController:263-286`) **writes that table** — it takes `userId` and `groups` from the request body, deletes every existing row for that user, and inserts the supplied ones — and it carried no authorization whatsoever. `UserController` has **zero** `@PreAuthorize` and **zero** function checks across all 12 of its endpoints.

So before this fix, Fix B was defeated in one request: a caller holding only `wms_user` grants themselves the `super-admin` group and walks straight back through all four gated endpoints. The destructive direction is just as bad — `{"userId": <admin id>, "groups": []}` strips a real administrator of every function, locking the tenant out of User Management.

```java
saveUserGroups(...) {
    denyUnlessUserManagementAllowed();   // MUST precede the first repository call
    ...
```

Gated on the **same** function as the screen, for the same one-axis reason as Fix B. Note the deliberate self-reference: you cannot grant yourself group membership unless you can already administer users. A holder of the function can still grant themselves more — that is an administrator's job, not a bypass.

> [!warning] The guard must precede the DELETE, not merely exist
> `saveUserGroups` deletes before it inserts, so a guard placed after the `findByUserlistId`/`delete` loop would still wipe the target's memberships while returning 403. Verify row `E6` parses the method and asserts the call precedes any `userGroupUserRepository` reference; `shouldDenyWithoutTheUserManagementFunction` additionally asserts `never()).delete(...)`, not just the throw.

Tests are by **direct invocation**, not MockMvc: `setupMockMvc` uses `standaloneSetup`, which installs no `ExceptionTranslationFilter`, so an `AccessDeniedException` surfaces there as a nested servlet exception rather than a 403. Ablation-proven (removing the guard fails both new tests). ⚠ The `@Nested` class reports separately and the outer class shows `Tests run: 0` — row `E8` reads the `$SaveUserGroups` surefire report directly rather than trusting the outer count.

**Explicitly NOT closed here:** `/v3/user/create`, `/user/importUser` and `/user/delete/{userId}` on the same class remain ungated and still manufacture Keycloak identities with warehouse-group membership. Split out at the owner's direction as **[SBDEV-2984](https://app.clickup.com/t/868kt73f9)** (§10.10). This plan must not be read as closing that.

### 3.3 Fix C — RELOCATED to SBDEV-2967 Fix E (decision 2026-08-17)

**The damaged-lock gate is no longer in this ticket.** It was written, tested and ablation-proven here, then moved on a consistency argument raised during review:

> "Transfer To Damaged" is **one of six sibling row actions** on the web UI's Stock Units page — alongside Lock, Unlock, Adjust Amount, Adjust Reserved and Transfer Stock. All six dispatch from the same table, all twelve endpoints (each action has a single and a bulk variant) live on `StockUnitController`, and all are gated by `WEB_UI_ACTION_*` functions through the same group→role→function chain.

Gating **one of six** would have shipped a state that is hard to explain and hard to justify: because only `super-admin` holds any `WEB_UI_ACTION_*` on WineCo, ~13 live users would have **lost Transfer To Damaged** while keeping Adjust Amount, both locks and Transfer Stock — all still open to every `wms_user`. The six belong in one tranche, with one grant decision.

**Where it went:** [SBDEV-2967](SBDEV-2967-web-ui-function-gating-enforcement.md) §3.5 (Fix E), rows 0.B.1–0.B.2 of its §0.B.1. **The design is carried over intact and is proven in code, not proposed** — controller-level placement, the gate before the bulk loop, 403 + `X-Authz-Denied`, and four ablation-tested unit tests. See §11.4 for what was reverted.

**What this ticket keeps:** Fix A (the `Authority` constants) and Fix B (the five user-administration gates) — see §0.A. Rows 0.7 and 0.8 of §0.B remain in the enumeration as the *record of the finding*, because that enumeration is what exposed the fourth route (§10.2); their **implementation** is 2967's.

### 3.4 Fix D — RELOCATED to SBDEV-2967 Fix E, with the reason it could not stay

The `X-Authz-Denied` header and its CORS exposure went with Fix C — **not** as a bundling convenience, but because **nothing left in this ticket can emit it.**

The five remaining gates are `@PreAuthorize`, which produces Spring's *default* 403. There is **no custom `AccessDeniedHandler` anywhere in this codebase** (verified 2026-08-17), so there is no interception point at which to attach a response header to those denials. Keeping the constant and the CORS entry would have shipped dead config.

🔴 **The problem it was meant to solve does not go away.** Both UIs' axios interceptors treat 403 exactly like 401 — retry three times with a token refresh, then `$kc.logout()` on an authenticated session. This branch's five gates emit 403s, so **an admin lacking the `wms_admin` group is logged out rather than told they lack permission**, and with the header work gone there is no mechanism here to soften it. Adding an `AccessDeniedHandler` would be new work and new risk on a security branch.

That is why §10.1 is the blocker rather than a caveat: the failure mode is not "sees a 403", it is "gets logged out on opening the screen, with no graceful path available."

### 3.5 Rejected alternatives

| Option | Why rejected |
|---|---|
| Restore `@PreAuthorize(IS_SB_ADMIN)` | The ticket's own blocker: 403s User Management for every customer admin. |
| `wms_admin or sb_admin` via `Authority.getExpAppAdminGroupOrSbAdminGroup` | Considered and dropped. Adds a fourth mechanism that the §1.1 target state immediately removes. |
| Map the five to a `FunctionEnum` function | Contradicts §1.1 — user administration is not a warehouse operation. Also depends on SBDEV-2968 for enforcement; `wms_admin` works today. |
| Damaged-lock gate at the service layer | Returns **HTTP 200** on the bulk path (§3.3). |

---

## 4. Architecture Overview

```
 request ──▶ TenantFilter ──▶ SecurityFilterChain
                                 ├ /actuator/**            → ADMIN | wms_admin   (pre-existing)
                                 ├ /v3/**                  → wms_user  ← the ONLY prior gate
                                 └ CorsFilter → writes Access-Control-Allow-Origin
                                                + Access-Control-Expose-Headers
                                                  [X-Export-Skipped…]   (unchanged here)
                                      │
                     ┌────────────────┴───────────────────────────────┐
                     ▼                                               ▼
        AdminController (1 endpoint: the CSV utility)     UserAdministrationController (4) + UserController (1)
        @PreAuthorize(IS_SB_ADMIN)           ← Fix B/0.1   denyUnlessUserManagementAllowed()  ← Fix B/0.2-0.5 + Fix E
        ⚠ untestable — standaloneSetup has                 ├ accessService.doesUserHaveAccess(WEB_UI_VIEW_USER_MANAGEMENT)
          no method-security advisor (RC-4);                └ ✅ testable: ordinary code, 7+3 tests, ablation-proven
          this is AC-5's whole residual
                                                              (never response.reset() — CorsFilter
                                                               already wrote ACAO; SBDEV-2632)
                                                         ✅ testable — ordinary code
        ────────────────────────────────────────────────────────────────────────
        NOT COVERED: PATCH /v3/stockunit/{id}  (Spring Data REST, §0.10 / §10.2)
        RepositoryRestHandlerMapping — writes entityLock directly, skipping both.
```

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Blocking? |
|---|---|---|
| **P1** | 🔴 **Confirm that every principal holding `WEB_UI_VIEW_USER_MANAGEMENT` also holds the bare `wms_admin` Keycloak group**, per tenant. If not, opening Admin → User Management **logs the admin out** (§10.1). Cannot be checked from the DB — it is Keycloak-side. | **YES** |
| **P2** | ~~Decide the damaged-lock grant.~~ **MOVED to SBDEV-2967 §5.1-P2** with Fix C — and it now covers all six Stock Units row actions at once rather than one. | n/a |
| **P3** | Run the **manual 403 checks** — AC-5 reduces to these because RC-4 makes the five gates untestable. Four curls, §6.3 M1–M4. | **YES** |
| **P4** | Verify with `mvn clean` — `Authority` constants are inlined and incremental compilation is disabled (§3.1). | **YES** |
| **P5** | **Revert `src/test/resources/archunit_store/…` before committing.** `mvn test` mutates that tracked file; it has been reverted twice already in this work. | **YES** |
| **P6** | File the §10.2 SDR bypass as its own ticket. | No |
| **P7** | Decide §10.3 and §10.4 (test-setup scope; null-as-success). | No |

### 5.2 Implementation checklist — status

1. ✅ `Authority`: `WMS_ADMIN_ROLE` only (`IS_WMS_ADMIN` added then deleted as dead — §3.1)
2. ✅ `@PreAuthorize(IS_SB_ADMIN)` on the CSV endpoint (0.1); the other 4 extracted to `UserAdministrationController` on the function model
2b. ✅ **Fix E** — `saveUserGroups` gated on the same function (§3.2.1), without which 2 was bypassable in one request
3. ➡️ ~~`denyUnlessDamagedLockAllowed()` + 2 call sites~~ — **moved to SBDEV-2967 Fix E** (§3.3)
4. ➡️ ~~`X-Authz-Denied` via CORS + 2 `SecurityConfigurationTest` cases~~ — **moved to SBDEV-2967** (§3.4)
5. ✅ `SecurityConfiguration:120` uses `Authority.WMS_ADMIN_ROLE`
6. ➡️ ~~4 `DamagedLockAuthorizationGate` tests, ablation-proven~~ — **moved to SBDEV-2967** (design carried over intact, §3.3)
7. ❌ **No `wms2-web-ui` change** (AC-4 — §10.1)
8. ❌ **No manual 403 verification** (AC-5 — P3)

---

## 6. Test Plan

### 6.1 What can and cannot be tested

Rewritten 2026-08-17. **The redesign is what changed this table** — moving 0.2–0.5 off `@PreAuthorize` and onto an ordinary method call is precisely what made them testable.

| Fix | Testable? | Why |
|---|---|---|
| B / 0.2–0.5 — function gate | ✅ **Yes** | ordinary method call → assertable with plain Mockito. 5 tests, ablation-proven. |
| B / 0.1 — the one `@PreAuthorize` | ❌ **No** | `standaloneSetup` installs no method-security advisor (RC-4); `@SpringBootTest` down (SBDEV-2217). **Bytecode inspection is not a test** — it proves the annotation is attached, nothing about runtime. This is the entire residual of AC-5: one endpoint, one curl. |
| ~~C / D~~ | n/a | relocated to SBDEV-2967 Fix E |

### 6.2 Tests written

**`unit/controller/UserAdministrationControllerUnitTest`** — 19 tests: 14 delegation tests moved verbatim from `AdminControllerUnitTest` with the endpoints, plus 5 new in `$UserManagementFunctionGate`:

| Test | Pins |
|---|---|
| `addUserToWarehouseGroupDeniedWithoutFunction` | 403 not 500, service untouched |
| `removeUserFromWarehouseGroupDeniedWithoutFunction` | ″ |
| `isWarehouseUserDeniedWithoutFunction` | ″ |
| `existsInKeycloakDeniedWithoutFunction` | ″ |
| `gateReadsOnlyTheUserManagementFunctionOncePerCall` | granted path still reaches the service (guards against deny-always) + exactly 1 authz read + no other function consulted |

Each deny test asserts the call **throws** `AccessDeniedException` rather than returning a `ResponseEntity`. That is deliberate: it is simultaneously the deny assertion *and* the "not swallowed into a 500" assertion, because a guard inside the `try` would produce a 500 body instead of propagating.

The `gateReadsOnly…` test stubs **grant**, not deny — the mistake made on this branch's earlier Fix C, where stubbing deny made the handler return before the loop and rendered `times(1)` the only reachable outcome. A test written that way passes with the check in the wrong place, i.e. it pins nothing.

### 6.3 Manual test plan — now only 2 rows (was AC-5 in full)

| # | Setup | Action | Expected | Result |
|---|---|---|---|---|
| M1 | plain `wms_user` token, **no** `wms_admin` group | `GET /v3/admin/importUsersFromCsvText?csvText=x` | **403** — the only untestable gate left | |
| M2 | token holding `WEB_UI_VIEW_USER_MANAGEMENT` | Admin → User Management loads; add/remove warehouse membership works | **200** throughout | |
| ~~M3~~ | *obsolete* — the inherited-alias paths (`/v3/picking/user/isWarehouseUser`, §0.A.1) **no longer exist** for these 4 endpoints; extraction removed all 172 | | | n/a |
| M4 | plain `wms_user` token | `PATCH /v3/stockunit/{id}` body `{"entityLock":103}` | **should be 403** — if it succeeds, §10.2 is confirmed; the gate itself now lives in SBDEV-2967 | |

### 6.4 Test execution (2026-08-17, post-redesign)

| Command | Result |
|---|---|
Numbers below are post-rebase onto `origin/develop` (`2be4ea5`) and post-code-review.

| Command | Result |
|---|---|
| `mvn -o clean compile` | ✅ exit 0 |
| `mvn -o clean test -Dtest=UserController…,UserAdministration…,AdminController…,SecurityConfigurationTest,FileImportControllerTest` | ✅ **70 run, 0 failures** |
| `mvn -o clean test` (full) | ⚠ **5122 run, 2 failures, 0 errors** — `MobilePalletizingServiceTest.testScanParcelBulkPalletAlreadyAssignedToGate` and `OptionalSafetyArchTest.noNewOptionalGetCallsInServiceClasses`, **both pre-existing on `develop`**. No new regressions. `archunit_store` mutation reverted. |

> [!warning] A full-suite-only failure, and what it exposed — worth reading before writing any authorization test here
> Adding the §10.12 sentinel check produced `UnnecessaryStubbing` on `removeUserFromWarehouseGroupDeniedWithoutFunction` **in the full suite only**; every targeted run passed. Root cause was **not** in this change: `FileImportControllerTest:163-165` binds a Mockito **mock** `SecurityContext` to `SecurityContextHolder` and never cleared it. Surefire reuses threads, so the mock leaked forward; `SecurityContextHolder.getContext().setAuthentication(...)` then mutated *the mock* — a silent no-op — and `getUserName()` degraded to `ANONYMOUS`, so the new sentinel check short-circuited before the function stub was used.
>
> Three fixes, one per layer: (1) this class now builds a fresh context via `createEmptyContext()` + `setContext()` instead of mutating the ambient one; (2) `setUp` asserts `getUserName()` equals `"testuser"` as a **precondition**, so a future recurrence fails loudly instead of silently flipping which branch of the guard fires; (3) `FileImportControllerTest` got an `@AfterEach clearContext()` to stop the leak at source.
>
> **The generalisable point:** without the L1 hardening, that leaked mock would have gone on quietly making every future authorization test in this suite exercise the *anonymous* path while appearing to test an authenticated one. `getContext().setAuthentication(...)` is unsafe in any suite where some other class may have bound a mock — always `createEmptyContext()` + `setContext()`, and always clear in `@AfterEach`.
| **Ablation 1** — all 4 guard calls removed | ✅ **5/5 gate tests fail** (the pre-fix / ungated state) |
| **Ablation 2** — one guard moved *inside* its `try` | ✅ **exactly 1 test fails**, `existsInKeycloakDeniedWithoutFunction` — so the "outside the try" property is genuinely pinned, not assumed |
| **Ablation 3** — guard dropped from `isWarehouseUser` only | ✅ **2 tests fail**, and critically the **reflective** `everyHandlerOnThisControllerIsGated` catches it *independently* of the hand-written deny test — which is the whole point of §10.13 |
| **Ablation 4** — `ANONYMOUS` sentinel check removed | ✅ `anonymousSentinelDeniedWithoutReadingTheFunction` fails, so §10.12 is pinned and not decorative |
| **Ablation 5** — `saveUserGroups` guard removed (the self-grantable state) | ✅ both Fix E tests fail |
| Verify script, post-fix | ✅ **46 pass, 0 fail, 5 skip** (T6–T9 + E1–E8 added for the review fixes and Fix E) |
| Verify script, **replayed against pre-fix `HEAD`** | ✅ **11 pass, 35 fail** — the 11 are the deliberately-vacuous pins (`A2`,`A3`,`B5`) and the relocation/hygiene negatives (`R1`–`R4`,`H1`–`H3`) |

**Five verify rows were themselves defective, in two distinct directions.** Three *failed a correct implementation* (false red — the kind that gets waved away): `C6` matched the word `@PreAuthorize` in the new class's own *javadoc prose*; `C8`'s `ResponseEntity<[^>]+>` cannot match the nested generics these methods actually return, so it found zero bodies; `T5`'s `ls` glob lost the `$` in the `@Nested` surefire filename through two levels of shell quoting.

Two *passed on the broken tree* (false green — strictly worse), and **only the pre-fix replay caught them**: after switching `B1`/`B2` from `IS_WMS_ADMIN` to `IS_SB_ADMIN`, both were satisfied by the **commented-out** `// @PreAuthorize(Authority.IS_SB_ADMIN)` that the pre-fix tree carries directly above the CSV endpoint — i.e. the rows were satisfied by exactly the defect the ticket exists to fix. This is the **second** appearance of that failure mode in this one script (see the note on `B9`), so the fix went into the shared helpers — `annotated_within` and the new `file_contains_n_live` now strip comment lines — rather than into the two rows.

**Process rule this earns:** a post-fix green run cannot detect a row that also passes on the broken tree. Re-run the pre-fix replay after *any* edit to this script, and label rows that are trivially true pre-fix as `[pin: vacuous pre-fix]` so a reader never mistakes them for evidence.

---

## 7. Horizontal Scalability Validation

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | **No** | stateless |
| 2 | Connection pool | **No** | one uncached `getAllRoles` per request — the gate sits **before** the bulk loop, so not per-id |
| 3 | Scheduled jobs | **N/A** | none |
| 4 | Long transactions | **No** | runs at method entry, before business work |
| 5 | Request affinity | **No** | stateless |
| 6 | Retry / idempotency | ⚠ **Yes — see §10** | a denied action never executes, but the **client** retries the 403 3× and then logs out (Fix D is the server half of the remedy) |
| 7 | Tenant context | **Yes — load-bearing** | `getAllRoles` reads the tenant DB inside request scope, after `TenantFilter` |
| 8 | Distributed locks | **N/A** | none |
| 9 | Cache invalidation | **N/A** | no cache |
| 10 | External notifications | **N/A** | none |

### v2-only constraint checklist

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV disabled | ✓ OK — `List<String>` / `Optional<User>`, no lazy proxy escapes |
| 2 | `tenantTransactionManager` | ✓ N/A — no `@Transactional` added; a bare one would bind to the **landlord** TM |
| 3 | `readOnly = true` | ✓ N/A |
| 4 | Caffeine invalidation | ✓ N/A |
| 5 | Jakarta namespace | ✓ N/A — no new servlet code |
| 6 | H2-compatible test SQL | ✓ N/A — Mockito only |
| 7 | `BaseControllerTest` | ⚠ **shared setup changed** — see §10.3 |
| 8 | Micrometer | ✓ N/A — no metric added (arguably should be; §10.6) |

---

## 8. Risks & Mitigations

| # | Risk | Sev | Mitigation | Residual |
|---|---|---|---|---|
| **R1** | 🔴 **User Management logs admins out** instead of 403-ing. `store/admin/user.js:175,193` fires on screen entry, and axios turns a 403 into `$kc.logout()`. | **High** | §5.1-P1 must be answered before merge. Fix D is the server half; the UI half is in 2967/2968. | **Unresolved.** This is the top blocker. |
| **R2** | ~13 of 52 live users lose the damaged-lock capability. | **High** | §5.1-P2 — confirm usage or grant the function. | Accepted once P2 answers. |
| **R3** | 🔴 **The damaged-lock gate is bypassable via Spring Data REST** (§0.10). | **High** | Out of scope; §10.2 ticket. Behind the `wms_user` floor, so not open to a zero-authority principal — but open to every operator. | **Unresolved, and it means the *capability* is not gated even though the *route* is.** |
| **R4** | The 5 `@PreAuthorize` gates are unverifiable by test (RC-4) — a typo or misplacement ships silently. This is precisely how SBDEV-2863 lasted 9 months. | **High** | Bytecode verification (`javap` confirms `hasAuthority('wms_admin')` on the right methods) + inspection + M1–M3. **A durable guard for the class is SBDEV-2872.** | Accepted, mitigated only by manual checks. |
| **R5** | `X-Authz-Denied` inert if dropped from CORS exposure. | Medium | Fix D + 2 tests asserting the list **exactly**, so a future change must update them deliberately. | Low. |
| **R6** | The class-wide lenient permissive stub makes any *future* gate on this controller silently permissive in existing tests. | Medium | §10.3 — recorded, not yet fixed. | Open. |
| **R7** | `denyUnlessDamagedLockAllowed()` returns `null` for "allowed"; a third call site could discard it. | Medium | §10.4 — recorded, not yet fixed. | Open. |
| **R8** | `mvn test` mutates the tracked `archunit_store` file. | Low | §5.1-P5. Already caught twice. | Low. |

---

## 9. Acceptance & Implementation

### 9.1 The ticket's own acceptance criteria

| # | Criterion | State |
|---|---|---|
| AC-1 | Decide the authorization level for each of the five | ✅ 0.1 → `sb_admin` (staff-only utility); 0.2–0.5 **and the newly-found 0.6** → function `WEB_UI_VIEW_USER_MANAGEMENT` |
| AC-2 | `importUsersFromCsvText` is gated | ✅ |
| AC-3 | `existsInKeycloak` gets an explicit decision | ✅ |
| AC-4 | The 3 UI-consumed endpoints changed **together with `wms2-web-ui`** | ✅ **dissolved by the redesign** — the gate now reads the same function that already grants the screen (39 live holders via `super-admin` on WineCo dev), so no UI change and no Keycloak group check is needed. See §10.1. |
| AC-5 | **A test proves a non-authorized caller gets 403** | ⚠ **5 of 6 endpoints ✅** — 0.2–0.5 by `$UserManagementFunctionGate`, 0.6 by `$SaveUserGroups`, all ablation-proven in both directions. Residual: 0.1's `@PreAuthorize` cannot be evaluated by any test in this repo → **1 curl, §6.3 M1** |
| AC-7 | *(added by review)* the ticket's claim must be TRUE as shipped | ⚠ **partly** — Fix E closes the self-grant bypass (§10.9), but identity creation via `/v3/user/create` remains open (§10.10, ticket [SBDEV-2984](https://app.clickup.com/t/868kt73f9)). **Do not close this ticket with wording that implies Keycloak identity creation is locked down.** |
| AC-6 | Role matrix updated | ✅ 2026-08-17, twice (target state, then the function-model correction) |

**3 of 6.** Do **not** merge this as "closes SBDEV-2870."

### 9.2 Verify script

`sbdocs/9-System/scripts/verify-SBDEV-2870-ungated-user-admin-and-damaged-lock-endpoints.sh` — authored with this plan, negative-tested against a shadow of the pre-fix tree.

---

## 10. Open Questions

- ✅ **10.1 (was AC-4, blocking) — CLOSED 2026-08-17 by removing the axis mismatch, not by answering it.** The question was: do `WEB_UI_VIEW_USER_MANAGEMENT` holders also hold the `wms_admin` Keycloak group? It was unanswerable from here — group membership is not in the tenant DB — and getting it wrong would have logged 39 WineCo admins out of the screen (403 → axios retry ×3 → `$kc.logout()`). Nam Park's decision was to gate on the **function** instead, so the API gate and the screen gate read the same thing and the question no longer has to be answered. Recorded because the *shape* recurs: same as SBDEV-2947, where tier and eligibility sat on different axes. **When a guard lands on a different axis from the one that already grants access, prefer moving the guard to the existing axis over verifying the two populations coincide.**
- 🟢 **10.9 — CLOSED in this branch** (owner directed it into this PR, 2026-08-17). See **§3.2.1 Fix E**. Original finding retained below because the *shape* is the transferable lesson: **gating on a DB table is only as strong as the weakest writer of that table** — enumerate the writers, not just the readers. Original text: **the gate is self-grantable.** `UserController` carries **zero** `@PreAuthorize` and **zero** function checks across all 12 of its endpoints (verified: `grep -c` returns 0 for both). `POST /v3/user/saveUserGroups` (`:263-286`) takes `userId` + `groups` from the request body, **deletes every** `mywms_group_mywms_user` row for that user, then inserts the supplied ones — and that table is exactly what `AccessService.doesUserHaveAccess` traverses (`UserRepository:27-34`). So any `wms_user` can grant themselves the `super-admin` group in **one request** and walk back through all four newly-gated endpoints; or send `{"userId": <admin id>, "groups": []}` and strip a real administrator of every function, locking the tenant out of User Management. **This is pre-existing, not introduced here** — but it means the ticket's claim "a `wms_user` can no longer add or remove Keycloak warehouse-group membership" is **false as shipped**, so SBDEV-2870 must not be closed on that wording. Fix is one guard per endpoint on a class Spring already proxies.
- 🔴 **10.10 — STILL OPEN, split out as its own ticket [SBDEV-2984](https://app.clickup.com/t/868kt73f9)** (high priority, filed 2026-08-17 at the owner's direction to keep this PR reviewable). `UserController` already has `AccessService` injected and a `denyUnlessUserManagementAllowed()` helper from Fix E, so each endpoint is a one-line change. Original text: **the CSV capability is still open through two ungated siblings.** `POST /v3/user/create` (`UserController:121`) calls `KeycloakService.createSingleUser`, which at `:716-724` adds the new account to the WMS group **and** the warehouse group (verified by reading both). `POST /v3/user/importUser` (`:78`) calls `addUserToWmsGroup` for an arbitrary username. So a `wms_user` scripting `/v3/user/create` manufactures Keycloak identities *with* warehouse-group membership — the exact capability gated on `wms_admin` at `AdminController:204` — one at a time instead of in bulk. `/v3/user/delete/{userId}` (`:234`) is likewise ungated. **Do not describe the identity-creation hole as fixed.** Same one-line fix shape as 10.9.
- 🟢 **10.11 — RESOLVED 2026-08-17: the operator is SiteBoss staff**, so the endpoint is gated on `IS_SB_ADMIN` (see §3.2). Note this made `Authority.IS_WMS_ADMIN` dead code; it was deleted rather than left as a loaded gun. Original question: is `importUsersFromCsvText`'s intended operator **SiteBoss staff** or the **customer's own admin**? `IS_WMS_ADMIN` is a single-authority `hasAuthority('wms_admin')` check with no `sb_admin` fallback, while the comment three lines above it describes client-migration work — which is staff work, and staff carry `sb_admin`, not `wms_admin`. If the operator is staff, they get **403** from the one endpoint retained for them, while every other endpoint on that class accepts them. Fix if so: `IS_WMS_ADMIN_OR_SB_ADMIN = "hasAnyAuthority('wms_admin','sb_admin')"` (a built-in, so no SBDEV-2863 resolution risk). If the operator is the customer's admin, the code is already right.
- 🟢 **10.12 (new, same review — CLOSED in this branch)** — `SecurityContextUtils.getUserName()` degrades to the literal `"anonymous"`, and Hydra UAT **has** a `mywms_user` row of that name (id 1). It holds no functions, so the gate failed closed — but on a *data* fact, not a code property; one INSERT anywhere would have made it an auth bypass. The guard now rejects the sentinel **before** consulting the function, pinned by `anonymousSentinelDeniedWithoutReadingTheFunction` and ablation-proven. Adding it initially broke all 20 tests, which is how it was confirmed reachable: an empty `SecurityContextHolder` yields exactly that sentinel, so the tests now install an authenticated principal and clear it in `@AfterEach`.
- 🟢 **10.13 (new, same review — CLOSED in this branch)** — the deny tests named their endpoints by hand, so a fifth handler added without a guard would have gone fully green. Replaced by `everyHandlerOnThisControllerIsGated`, which derives subjects via reflection and carries a `hasSize(4)` premise guard so adding an endpoint forces a conscious bump. Ablation-confirmed: dropping one guard fails the reflective test *independently* of the hand-written one.
- 🔵 **10.14 (new, same review)** — a `wms2-web-ui` **Cypress** row exercises `GET /v3/user/isWarehouseUser` (`cypress/e2e/wms/admin/admin.cy.js:488`, helper `cypress/support/helpers/wmsHelpers.js:1207`) and will 403 unless the Cypress service user holds the function. It does **not** fail the build — `:493` degrades `PASS` to `INFO` on a non-200 — which is worse in one respect: the e2e report silently stops covering the endpoint. Mention in the PR body.
- 🟡 **10.8 (new)** — §0.A.1's inheritance finding means the endpoint inventories in **SBDEV-2967 §0.B** and **SBDEV-2968** are understated: every `AdminController`-inherited mapping is registered under 43 additional prefixes. Neither plan's gating design is *wrong* (a method-level guard is inherited too), but the counts are, and the reflection-built golden map that 2968 makes a blocking prerequisite must enumerate inherited mappings or it will silently miss them. Needs folding into both plans before 2967 starts.
- 🔴 **10.2** — the Spring Data REST bypass (§0.10). `PATCH /v3/stockunit/{id}` with `{"entityLock":103}`. High confidence from code reading; **not runtime-verified** (M4). Needs its own ticket. Note this is the SBDEV-1666 landmine class: a service- or controller-layer guard cannot cover an `@RepositoryRestResource` surface.
- **10.3** — the class-wide `lenient()` permissive stub. Reviewer's alternative (per-nested-class stubs, so unstubbed means *deny*, failing closed like production) is better and is 2 lines. Deliberately not self-applied.
- **10.4** — null-as-success. Preferred shape: `requireDamagedLockAccess()` throwing a dedicated exception mapped in `RestExceptionHandler`, which would also converge the mobile paths onto one denial contract.
- **10.5** — `printLabel` is documented optional but unboxed into a primitive `boolean`; omitting it NPEs into a 500. Own ticket.
- **10.6** — no Micrometer counter on denial, unlike 2968's `wms2.authz.denied`. Worth adding for the 24h deploy watch.
- **10.7** — `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` now has **two denial contracts**: `BusinessException` at 4 sites, `403` + `X-Authz-Denied` at 2. The UI is being told to key on a header covering 2 of 6.

---

## 11. Notes

### 11.1 Review

One independent code-review pass, 2026-08-17. Verdict **DON'T SHIP**. Findings HIGH-1 (→ §10.1), HIGH-2 (→ §10.2), MEDIUM-1 (the vacuous test — **fixed**), MEDIUM-2 (CORS exposure — **fixed**), MEDIUM-3 (→ §10.7), MEDIUM-4 (→ §10.3), MEDIUM-5 (→ §10.4), plus a LOW that was fixed (the `wms_admin` literal at `SecurityConfiguration:120`).

> [!warning] That review does not cover the current branch state
> It reviewed the **6-file** version, which still contained Fix C, Fix D and the `wms_admin` gates on all five endpoints. Since then Fix C/D were reverted (§11.4) *and* Fix B was redesigned onto the function model (§3.2), which added a new controller, a new test class, and moved 4 endpoints. **HIGH-1 is now closed by construction rather than by argument** (§10.1). Nothing has independently reviewed the 6-file diff that exists today. Two of the errors on this branch were introduced by the *revert* itself — a truncated `SecurityConfigurationTest` and a verify script left with an undefined `$SUC` that died silently under `set -u` — so removal carries its own risk and warrants a fresh pass before merge.

**One review claim was wrong** and is corrected here: it held that the SDR resource is served at `/stockunit/{id}` and falls through to `anyRequest().authenticated()` — i.e. reachable with zero authorities. `RestConfiguration:24,32` sets the base path to `/v3` **programmatically** (which is why it looked unset), so the `wms_user` floor does apply. §0.10 is still a real bypass, one severity step lower.

### 11.2 What the missing plan cost — recorded so the lesson survives

Each item maps to a section that did not exist when the code was written:

| Missing section | Consequence |
|---|---|
| **§0.B enumeration** | The SDR bypass was found under review, not up front. Grepping the *constant* finds the guard; only enumerating *writers of the lock value* finds the hole. |
| **§9.1 acceptance criteria** | "All five closed" was reported before the ACs were checked. 3 of 6 was the truth. |
| **§5.1 prerequisites** | The ~13-user blast radius and the `wms_admin` membership question surfaced late — the latter had been baked into a code comment as fact. |
| **§8 risks** | The axios-403-logout consequence was found by accident while doing unrelated work. |
| **Verify script** | The branch had no machine-checkable baseline for its first ~3 hours. |

The trigger for writing a plan was crossed silently: a one-annotation request became two authorization mechanisms, three new constants, a global CORS change, and edits to two other plans. **The threshold to watch is not the initial ask but the second mechanism.**

### 11.3 Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ §1.2 — WineCo dev live |
| 1 | All callsites enumerated | ✓ §0.A/§0.B — incl. the 4th route missed originally |
| 2 | Adjacent bugs | ✓ §10.2, §10.5, SBDEV-2979 |
| 3 | Backward compatibility | ⚠ §1.2 — ~13 users lose a capability; P2 |
| 4 | Concurrency | ✓ §7 rows 4–6 |
| 5 | Multi-tenant | ✓ §7 row 7 |
| 6 | Error handling | ⚠ §10.7 — two denial contracts for one function |
| 7 | Observability | ⚠ §10.6 — no metric |
| 8 | Rollback / migration | ✓ no migration; revert is the annotations + CORS line |
| 9 | Test coverage | ✓ §6.1–§6.3, with the untestable half named explicitly |
| 10 | Cross-version | no — v2-only; v1 has its own `AdminController` lineage, unexamined |

### 11.4 What was reverted when Fix C moved (2026-08-17)

Removed from this branch and re-homed in SBDEV-2967 Fix E:

| Reverted | Why it went with Fix C |
|---|---|
| `StockUnitController.denyUnlessDamagedLockAllowed()` + its 2 call sites | the gate itself |
| `AccessService` constructor injection into `StockUnitController` | unused once the gate left |
| `Authority.AUTHZ_DENIED_HEADER` | **no emitter remains here.** The five `@PreAuthorize` gates produce Spring's *default* 403, and there is **no custom `AccessDeniedHandler`** in this codebase (verified), so nothing in this branch can attach a response header to a denial. Keeping the constant + CORS entry would have been dead config. **Landed in SBDEV-2968 §3.1-A2b, not 2967** — see the correction below. |
| The `X-Authz-Denied` CORS exposure in `SecurityConfiguration` | same — **now SBDEV-2968 §3.1-A2b** |
| 4 `DamagedLockAuthorizationGate` tests, the `@Mock AccessService`, the lenient permissive stub | test surface for the gate |

⚠️ **A consequence that stays behind, and it sharpens §10.1.** This branch's five gates *do* emit 403s, and both UIs' axios interceptors retry a 403 three times then call `$kc.logout()`. With the header work gone there is **no mechanism in this branch to make those denials graceful** — and because no `AccessDeniedHandler` exists, adding one is new work rather than a one-line change. So the User Management risk is not "an admin might see a 403"; it is **"an admin without the `wms_admin` group is logged out on opening the screen, and we currently have no way to soften that."** §10.1 is the blocker; this is why.

> ⚠️ **Correction, 2026-08-17 (later the same day).** The two header rows above say the work was "re-homed in
> SBDEV-2967 Fix E." **Only the damaged-lock gate went there.** The `AUTHZ_DENIED_HEADER` constant and its CORS
> exposure are now owned by **SBDEV-2968 §3.1-A2b**, because 2968 lands *before* 2967 (2967 §12) and needs the
> same header for its own `retryCondition` fix — as written, the first plan to ship would have been waiting on the
> second. 2968 is also the better owner on the merits: its `FunctionGuardInterceptor` writes the denial response
> itself, so emitting a header costs one line there and an `AccessDeniedHandler` anywhere else. Recorded as 2968
> R13 and §14-Δ1. **The revert from this branch stands and was correct** — only the destination changed.

Kept: Fix A (`WMS_ADMIN_ROLE`, `IS_WMS_ADMIN`), Fix B (5 gates), and the `SecurityConfiguration:120` literal→constant tidy-up. Branch was then **3 files / 72 insertions**; full suite **5113 run, 2 failures, both pre-existing on `develop`**.

> ⚠️ **Superseded — this paragraph is a snapshot of 2026-08-17 mid-morning, kept as the revert record only.** Fix B was afterwards redesigned onto the function model (§3.2), `IS_WMS_ADMIN` was **deleted** as dead (§3.1), and Fix E was added (§3.2.1). Current state: **6 files + 2 new**, full suite **5122 run, 2 failures**. Do not read the file/insertion counts here as current.
