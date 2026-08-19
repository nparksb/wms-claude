---
title: "Review brief — the X-Authz-Denied header contract (SBDEV-2968 §3.1-A2b)"
type: "review-brief"
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-08-18
updated: 2026-08-19
status: reviewed
review_report: reviews/SBDEV-2968-review-a2b-header-contract.md
related:
  - SBDEV-2968-mobile-ui-function-gating-enforcement.md
  - SBDEV-2967-web-ui-function-gating-enforcement.md
  - SBDEV-2870-ungated-user-admin-and-damaged-lock-endpoints.md
tags:
  - review-brief
  - security
  - authorization
---

# Review brief — the `X-Authz-Denied` header contract (SBDEV-2968 §3.1-A2b)

> ✅ **Reviewed 2026-08-19 — [reviews/SBDEV-2968-review-a2b-header-contract.md](reviews/SBDEV-2968-review-a2b-header-contract.md).**
> Verdicts: ① sound (+ structural addition) · ② sound-with-changes (`containsExactlyInAnyOrder`) · ③ sound,
> narrowed — the CORS claim was **checked in a browser**, not reasoned · ④ sound, wording tightened to "no
> *silent* env-specific drift" after a near-miss reversal · ⑤ inadequate, replaced by the `[inherited]`
> verify-row class (2968 §14.7). **All recommendations applied**; see the report's disposition addendum.
> Outstanding and unaffected: M23 still has no test subject (F10 / 2968 §14.6).

**Self-contained.** Everything needed is here or cited with `file:line`. You should not need to read the three
plans; their relevant content is reproduced below. All code facts were checked on `origin/develop` =
**`27e2f21`** (the merge of SBDEV-2870 PR #166, 2026-08-17).

**Your scope is five decisions**, all inside one ~2-page subsection added on 2026-08-17. **Do not review
SBDEV-2968 as a whole** — its mechanism, its 66-endpoint surface and its fail-closed design went through a
ralplan consensus pass (planner + critic, three must-fixes applied) and are not in scope. **Do not re-audit
the pre-existing verify rows**; only rows `A24`–`A31` and `H21`–`H28` are new.

**Be adversarial.** These decisions were made by one author with no second pass, and that author's error rate
*on this specific material, in this session* was as follows — assume comparable errors remain:

- drafted the acceptance evidence (M23) **twice as a `curl`** that cannot detect the failure it was written to
  detect (decision ③ below is the correction);
- wrote verify row `H24` asserting an exposed-header list "is not loosened to `contains(`" — **red on
  unmodified, correct code**, because one of the two existing tests legitimately uses `.contains(...)`;
- left row `A31` **passing on the unfixed tree while unlabelled**, in the same commit that introduced the
  `[pre-passes]` labelling convention;
- shipped a first cut in which **P10's entire client-side half had no verify row at all** — the script could
  have reported `0 fail` while every denial still logged the operator out;
- cited a test file at the wrong path (`unit/` vs `unit/config/`) and a mobile spec file that does not exist;
- **asserted that a usable `CS-REP`-shaped test account existed on WineCo dev, from plan prose rather than a
  query. It does not** (F10) — the shape is real at the *role* level and absent at the *user* level. Same
  failure mode as the item above it: an inherited claim repeated without checking.

Five of those six were caught only by *running* things. Weight the parts of §3.1-A2b that cannot be run
accordingly.

---

## Background in ten lines

Three tickets share an authorization theme:

- **SBDEV-2870** — gated 5 ungated user-administration endpoints. **Merged** as PR #166 (`27e2f21`).
- **SBDEV-2968** — builds the enforcement *mechanism* (`@RequiresFunction` + `FunctionGuardInterceptor`) and
  gates 66 mobile endpoints. **Lands next.**
- **SBDEV-2967** — web UI; *consumes* 2968's mechanism. **Lands after 2968.**

Both UIs' axios interceptors treat HTTP 403 exactly like 401: retry three times with a token refresh, then
`$kc.logout()`. So **every authorization denial currently presents as "the app logged me out"** rather than
"you lack permission" (`wms2-mobile-ui/plugins/axios.js:35-37` and `:69-100`; the same shape at
`wms2-web-ui/plugins/axios.js:33-34, :86`). The fix both plans depend on is an `X-Authz-Denied` response
header the client can key on to skip the retry.

**The problem being corrected.** That header was written on the 2870 branch, then **reverted** and re-homed in
2967 (2870 §11.4). But 2967 lands *after* 2968, and 2968 needs the same header — so the plan that ships first
was waiting on the plan that ships second, while 2968's text asserted the header "is already emitted by
SBDEV-2870's damaged-lock gate." **Verified on `27e2f21`: no `X-Authz-Denied` anywhere in `src/main/`.**
§3.1-A2b moves ownership into 2968. That move is what you are reviewing.

---

## Verified code facts (do not re-derive)

| # | Fact | Evidence |
|---|---|---|
| F1 | No `X-Authz-Denied` exists anywhere in `src/main/` | `grep -rn` on `27e2f21` — empty |
| F2 | **No `AccessDeniedHandler` and no `exceptionHandling(...)` block exists at all** in the security chain | `grep -rn "AccessDeniedHandler\|accessDeniedHandler\|exceptionHandling(" src/main/java/` — **empty** |
| F3 | `corsConfigurationSource` exposes exactly one header today, `CyclecountService.EXPORT_SKIPPED_HEADER`, additively behind a `contains()` guard | `SecurityConfiguration.java:167-188` |
| F4 | That method is **byte-identical** on `develop` and on the 2870 branch — PR #166 did not touch it | `git show <merge-base>:… \| diff` |
| F5 | `rest.security.cors.exposed-headers=X-Export-Skipped-Cycle-Counts` **is set**, so the `contains()` de-duplication guard is live, not theoretical | `application.properties:106` |
| F6 | Allowed origins include `http://localhost:3001` (mobile dev) and `https://*.sbo.li` | `application.properties:98` |
| F7 | `SecurityConfigurationTest` has **two** SBDEV-2632 cases: `…exposesSkippedCycleCountHeader_whenPropertyAbsent` uses `.contains(…)` (`:64`); `…doesNotDuplicateHeader_whenPropertyAlreadySuppliesIt` uses `.containsExactly("X-Export-Skipped-Cycle-Counts")` (`:83-84`). **Only the second is exact** | `src/test/java/net/aim_ai/wms/unit/config/SecurityConfigurationTest.java:52-85` |
| F8 | `wms2-mobile-ui` has **no `@nuxtjs/proxy`** — `modules: ['@nuxtjs/axios','@nuxtjs/toast']` (`:61`) — and `axios.baseURL` is `http://localhost:8088/v3` (`:67`) while the app serves on `:3001`, so local dev **is** cross-origin | `nuxt.config.js:61,:67` |
| F9 | The mobile logout lives in `onMaxRetryTimesExceeded`, which fires only after retries are exhausted — so returning `false` from `retryCondition` short-circuits the toast, the `localStorage` wipe and `$kc.logout()` | `plugins/axios.js:69-100` |
| **F10** | **No account on either reachable tenant can serve as M23's subject.** `CS-REP` on WineCo dev has the right shape (28 fns, `MOBILE_UI_LOG_IN`, **0** `MOBILE_UI_VIEW_*`), but all 3 live holders also carry `super-admin` (10–16 view fns); the only pure holder is `Z-mariaortiz(archived)`. On Hydra UAT, **zero** live users lack a view function. **A purpose-made account must be created before M23 can run at all.** | SELECT-only, 2026-08-18, via the `getAllRoles` chain; recorded in plan §14.6 |

---

## DECISION ① — SBDEV-2968 owns the header contract (constant + emitter + CORS entry)

**What was decided.** §3.1-A2b puts three things in 2968: `Authority.AUTHZ_DENIED_HEADER`; the emit in
`FunctionGuardInterceptor`; and the `addExposedHeader` entry in `SecurityConfiguration` plus the
`SecurityConfigurationTest` extension. 2967 §3.5.1-4 and §5.1-P8 were edited to **consume** rather than create.

**Rationale — "ownership follows the emitter."** `FunctionGuardInterceptor` writes the denial response itself,
so attaching a header costs one line. 2870 could not: its five gates are `@PreAuthorize`, which produces
Spring's *default* 403, and by **F2** there is no `AccessDeniedHandler` — nor any `exceptionHandling(...)`
configuration whatsoever — so emitting a header there meant building that machinery from scratch. 2967's Fix E
is a controller-level gate and *could* emit it, but lands second.

**The alternative that was rejected.** A **standalone prerequisite PR** carrying only the constant + CORS entry
+ test change, merged first and consumed by both 2967 and 2968. That **decouples the ordering** rather than
resolving it by assignment.

**Why this is the decision that matters.** This contract has now been re-homed **twice** (2870 → 2967 → 2968),
and both moves left an orphan: the first cost 2870 its §10.1 blocker, the second was this. A third re-home is
not unlikely — and assignment-to-whoever-lands-first is precisely the mechanism that produced the first two.

**If this is wrong:** 2968 carries scope that is not its own, and 2967's Fix E finds a half-built contract it
must either verify or rebuild. **Ask:** would you rather review one 3-file prerequisite PR, or find this
coupling again while reviewing 2967?

---

## DECISION ② — extend `containsExactly` to two headers; never relax it

**What was decided.** §3.1-A2b item 3 adds two new test cases *and* extends the existing exact-list assertion at
`SecurityConfigurationTest:83` from one header to two. Explicitly: **do not** relax it to `contains`.

**Rationale.** That assertion is the only thing in the repo that would notice `X-Authz-Denied` being silently
dropped from the exposed list later. Exactness forces a future change to be deliberate.

**Note the trap this decision sits on (F7).** SBDEV-2870 §3.5.1 property 5 states flatly that
"`SecurityConfigurationTest` asserts the exposed-header list **exactly**." **Only one of its two cases does.**
Taking that claim at face value sends you to the wrong test — it is what produced the `H24` error listed at the
top of this brief.

**If this is wrong:** the exact list becomes a two-element list nobody maintains, and it stops meaning anything.
This is a slow, quiet failure, not a loud one.

---

## DECISION ③ — M23's evidence is a browser test; `curl` and DevTools are inadmissible

**What was decided.** P10's and AC-31's acceptance evidence is a **local browser test** — sign in as a user
holding no mobile workflow function, tap a gated tile, assert (a) the denial message renders, (b) **no logout
and no "maximum unauthorized attempts" toast**, (c) `headers.get('x-authz-denied')` is non-null from JS.

**Rationale.** The defect guarded against is *"the header is emitted but the browser cannot read it."* Anything
not itself subject to CORS filtering cannot distinguish that from success:

| Instrument | Reads the header when it is **not** exposed? | Admissible |
|---|---|---|
| `SecurityConfigurationTest` (MockMvc, **no `CorsFilter`**) | yes — reads the bean's config, not a filtered response | proves the *list*, not the *reading* |
| `curl -H 'Origin: …' -i` | **yes** — curl applies no CORS policy | **no** |
| DevTools → Network → Response Headers | **yes** — the panel renders all headers; CORS restricts what *JS* may read | **no** |
| JS `response.headers.get(…)` from the app origin | **no** — returns `null` | **yes** |
| The behaviour itself (message renders, no logout) | **no** | **yes, strongest** |

**By F8 this runs on a laptop** — no deployed environment needed. F8 is also fragile: adding a Nuxt dev proxy
would make every request same-origin and hide this entire defect class locally while all tests stayed green.

⚠️ **Cost correction (F10, 2026-08-18).** This decision was written as though M23 were ready to run. It is not:
**no existing account on either tenant can serve as its subject**, so one must be created first. That does not
change the *conclusion* — a `curl` still cannot detect the failure, so the cheaper instrument remains
inadmissible however inconvenient the admissible one is — but it does change the **cost** you should weigh, and
it is the reason decision ④ below deserves a harder look than its "lowest stakes" label suggested.

**If the claim is wrong:** verification was made harder than necessary — annoying, safe. **If it is right and
ignored:** someone ships on a green `curl` and operators are still logged out on every denial. *This is
checkable in about a minute in a browser; prefer checking it to taking it on trust.*

---

## DECISION ④ — the credential-free variant was dropped, not deferred

**What was decided.** An *unauthenticated* cross-origin request still carries `Access-Control-Expose-Headers` on
its 401 (Spring Security's `CorsFilter` precedes authentication), which offered a CORS check needing no test
account. It was **dropped**.

**Rationale.** §3.1-A2b's `addExposedHeader` is additive and override-proof by construction, so no
environment's `REST_SECURITY_CORS_EXPOSED_HEADERS` can drop the header — there is no env-specific drift for such
a check to catch. It would be a row incapable of failing.

**If this is wrong:** a cheap per-environment smoke test was discarded. The reasoning depends on the
override-proof claim, which is **F3/F5** and is itself part of decision ①.

⚠️ **Re-weighted 2026-08-18 — this was labelled "lowest stakes of the five" and that label was wrong.** It was
written assuming a test account was easy to come by. **F10 shows there is none**, on either tenant, so the
credential-free variant's entire appeal — *verifiable with no account at all* — is far higher than when it was
dismissed. The technical argument is unchanged and, I think, still decisive: **a check that cannot fail is
worth nothing regardless of how cheap it is**, and an override-proof `addExposedHeader` means it can never
fail. But that is now a load-bearing claim rather than a throwaway one. **Reviewer: press on it.** If the
override-proof property does not hold as stated — or if a future change could make the CORS entry
conditional — then the credential-free check becomes both meaningful *and* the only zero-setup verification
available, and dropping it was a mistake.

---

## DECISION ⑤ — R13's mitigation is prose in three documents

**What was decided.** The risk that a scope move between 2870/2967/2968 leaves an orphan is mitigated by
recording ownership in all three plans and by the instruction: *"any future scope move between these three
tickets must end with a grep of the receiving branch for the thing being assumed, not a reading of the sending
plan."*

**The problem.** This exact control has now failed **twice**, and prose is the same class of control that failed.
The author could not think of a structural alternative.

**This is the decision where a suggestion is worth more than a verdict.** Candidates not evaluated: a compile-time
reference from the consuming plan's tests; a CI check that greps for orphaned cross-plan claims; merging the
contract into a shared PR so ownership cannot drift (which is decision ① again, from another angle).

⚠️ **The risk is broader than R13 states — third instance found 2026-08-18.** R13 is scoped to *scope moves
between 2870/2967/2968*. **F10 is the same failure with no scope move involved**: §3.5's "`CS-REP` shape"
claim was true of a *role*, was repeated across plans as though it described an available *user*, and nobody
queried it until it was needed. The general defect is **any inherited claim carried as fact**, not specifically
a relocation — which makes "grep the receiving branch after a scope move" too narrow a mitigation even if
prose were the right medium. **A reviewer proposing a structural control should aim at the general case.**

---

## What a good report looks like

- A **verdict per decision**: sound / sound-with-changes / wrong.
- For ①, a recommendation between *2968 owns it* and *standalone prerequisite PR*, with the reason that decides it.
- For ③, say whether you **checked** the CORS claim or reasoned about it.
- For ⑤, a concrete structural proposal if you have one.
- Any **interaction between decisions** — note that ④'s reasoning depends on ①'s override-proof property, and
  ②'s exactness argument is what makes ③'s test-vs-behaviour split necessary. Are those dependencies sound?
- Any **case §3.1-A2b misses entirely**, with `file:line`.
- State plainly what you did **not** examine.

**Do not** re-verify F1–F9 unless you doubt one — say which and why.

---

## Environments

- Repos: `v2/wms2-api` and `v2/wms2-mobile-ui`. The API work-in-progress is the worktree
  `.claude/worktrees/wms2-api/SBDEV-2968` on branch `bugfix/SBDEV-2968-mobile-function-gating`, currently at
  `origin/develop` = `27e2f21`. **No implementation code exists yet** — the only artifact is an uncommitted
  `src/test/java/net/aim_ai/wms/unit/security/FunctionGuardContractUnitTest.java`.
- Verify script: `sbdocs/9-System/scripts/verify-SBDEV-2968-mobile-ui-function-gating-enforcement.sh`, **92
  rows**, baseline on the unimplemented tree **`16 pass, 88 fail, 5 skip`**. Run it with `PROJECT_ROOT` pointed
  at a symlink shadow root (`v2/wms2-api` → the worktree, `v2/wms2-mobile-ui` → the repo), never at the main
  checkout. Four rows pass pre-implementation by design and are labelled `[pre-passes]`.
- Read-only MCP SQL is available for WineCo dev (`dev_wh01_om1`) and Hydra UAT; both were reachable on
  2026-08-18 and F10 was measured on them. Expect the first query after an idle period to drop once — retry
  before diagnosing.
- **There is no account you can log in as to reproduce a denial** (F10). If your review needs one, it must be
  created: a Keycloak user plus a `mywms_user` row in a group whose only role is `CS-REP`. Do **not**
  substitute a user with no `mywms_user` row — that path denies with `reason=USER_NOT_PROVISIONED` at `ERROR`
  severity and a different message, exercising a different branch.
