---
title: SBDEV-3183 re-review — SdrMustStayOpenRailUnitTest (03a32957)
type: review
ticket: SBDEV-3183
date: 2026-10-18
reviewer: code-reviewer lane (independent, read-only, no build run)
verdict: COMMENT (approve-able); one LOW new inaccuracy
---

# Re-review: `03a32957` (fixes F1-F6 from review-must-stay-open-rail.md)

Scope: `git show 03a32957`, one test file. Sources checked at fresh `origin/develop`:
oms-laravel-api `59039e8c`, wms2-mobile-ui `f51dc6c5` (both heads equal the pins in the javadoc, so the pins are current),
wms2-api `origin/develop`.

## Disposition

| ID | Status | Evidence |
|---|---|---|
| F1 (Medium) Client also read by mobile | FIXED | Javadoc mobile bullet, Client caller string, "What this cannot see" and the guard message all name `pick.vue`. Source confirmed: `components/picking/pick.vue:252-254` does `$get(\n '/client/search/findByClNr?clNr=System')` in `created()`. `ClientRepository.java:25` (`repo/jpa/`) exports `findByClNr` via `@RestResource`. It is the only `/client` read in the mobile UI. |
| F2 audit file only comments | FIXED, with a small new inaccuracy (N1) | The audit's `DO NOT grant anonymous or oms_integration` is a comment at `:521`; G-3 filters `u.name IN ('anonymous','anonymousUser')` (`:537`, `:547`), so `oms_integration` is unchecked. The javadoc now says "a comment ... says not to grant it any; that audit's query checks only anonymous, so nothing enforces it". |
| F3 auth modes not exhaustive | FIXED | `applyAuthentication` (`WmsApiService.php:3610`) switch has `basic`, `token`, `keycloak` (per-facility S2S identity via `keycloakOverridesFromAuthConfig`, else user-JWT passthrough, else tenant/env service account) and default `none`. The javadoc lists all five shapes. The softened claim ("none of those identities is guaranteed a mywms_user row") is correct and no longer overclaims. |
| F4 printer override | FIXED | `config/wms.php:226`: `env('WMS_PRINTER_SEARCH_BY_TYPE_ENDPOINT', 'rest/printer/findByType')`; the comment says the v3 form is Keycloak-gated SDR. `WmsApiService.php:2939` reads it, and the code handles the HAL envelope. The javadoc reports default and override correctly and makes the "ninth entry" statement conditional. |
| F5 FAIL_CLOSED | FIXED | `SdrGuardMode.deniesUnruled()` is `this == FAIL_CLOSED` (`:76-77`); the table at `:18-19` shows ENFORCE_RULED allows unruled and FAIL_CLOSED denies it. `SdrFunctionGuard.java:270,289` agrees. The new "What this does not cover" paragraph is accurate. |
| F6 exact set | FIXED | `containsExactlyInAnyOrder` of the eight classes on a `toList()` (not `distinct()`), so it also fails on duplicates and on a swapped-in type. The message counts (OMS 6 = Client, Itemdata, Shipperid, Boxtype, Customerorder, CustomerorderBatch; mobile 3 = Section, Stockunit, Client) match the list. All eight classes were already imported; `Collectors` is still used at `:115`. |

## New findings

| ID | Sev | Conf | Where | Issue | Fix |
|---|---|---|---|---|---|
| N1 | LOW | HIGH | javadoc, OMS bullet ("that audit's query checks only `anonymous`") | The G-3 query checks `anonymous` AND `anonymousUser` (`audit-access-invariants.sql:537,547`). The audit's own comment explains `anonymousUser` is the name the guard actually sees. "only anonymous" is false in detail, though the point (oms_integration is unchecked) stands. | Reword: "checks only `anonymous`/`anonymousUser`". |
| N2 | LOW | HIGH | `SdrMustStayOpenRailUnitTest.java:35` | One javadoc line is 121 chars (the "Measured 2026-10-18 on ..." line was rewrapped badly, leaving a run-on). Style only. | Re-wrap. |
| N3 | LOW | MEDIUM | javadoc Printer sentence | "A tenant that sets it makes Printer a ninth entry" is fine, but the config comment says the override exists for WMS releases predating `rest/printer/findByType`; the javadoc does not say no tenant is known to use it. Not false, just unmeasured; no env census was done in this commit. | Optional: add "no tenant is known to set it (unmeasured)". |

No new false or unproven claim of substance. The commit message's statement that the sweep missed `pick.vue` because the path was on the next line matches the source. The "whose screens no web function covers" claim for the mobile bullet is carried over unchanged and not re-verified for `pick.vue`; it does not affect the rail.

## Verdict: COMMENT (approve-able)

F1-F6 all fixed. Only N1-N3 (LOW, wording) remain. No HIGH/CRITICAL. Not run: build and the mutation checks, per the brief.
