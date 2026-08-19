# Review — the `X-Authz-Denied` header contract (SBDEV-2968 §3.1-A2b)

**Reviewing:** `REVIEW-BRIEF-a2b-header-contract.md` (five decisions in one ~2-page subsection, added 2026-08-17)
**Reviewed against:** `origin/develop` = `27e2f21`, with a live `wms2-api` on `localhost:8088`
**Date:** 2026-08-19 · **Reviewer:** Nam Park
**Scope honoured:** decisions ①–⑤ only. SBDEV-2968's mechanism, its 66-endpoint surface and the pre-existing
verify rows were not reviewed.

---

## VERDICT SUMMARY

| # | Decision | Verdict |
|---|---|---|
| ① | SBDEV-2968 owns the header contract | **Sound**, with one structural addition |
| ② | Extend `containsExactly` to two headers | **Sound-with-changes** — the prescribed assertion adds an order coupling |
| ③ | M23's evidence is a browser test | **Sound**, with "curl is inadmissible" narrowed — **checked, not reasoned** |
| ④ | The credential-free variant was dropped | **Sound**, with the rationale's wording tightened |
| ⑤ | R13's mitigation is prose | **Inadequate as written** — structural replacement proposed |

The brief asked to be pressed on ④. It was — hard enough that this review first reached the opposite verdict
(*wrong, reinstate it*) on the grounds that origin-pattern drift is env-configurable and unchecked. Checking the
deployed configuration retired that objection; the reasoning is recorded under ④ because the near-miss is itself
informative about what the rationale should say. No decision in §3.1-A2b is judged wrong.

---

## What was executed

| Check | Result |
|---|---|
| Two-origin browser probe: 403 + `X-Authz-Denied`, one route listing it in `Access-Control-Expose-Headers`, one omitting it | `headers.get('x-authz-denied')` → `null` when not exposed, `"true"` when exposed |
| Same two responses via `curl -i` | `X-Authz-Denied: true` present in **both** — the header line is byte-identical |
| Live API, credential-free, `Origin: http://localhost:3001` → `/v3/system/mobileUiUrl` | 401 carrying `Vary: Origin`, `Access-Control-Allow-Origin`, `Access-Control-Expose-Headers: X-Export-Skipped-Cycle-Counts` |
| Same with a doubled path separator (`/v3//system/…`) | **400 from Tomcat before the filter chain — no CORS headers at all** |
| `grep -rln "FunctionGuardInterceptor\|AUTHZ_DENIED\|RequiresFunction" src/` | empty, consistent with F1 |
| Deployed-environment override of the CORS origin patterns (repo-wide grep, Dockerfile, `.gitlab-ci.yml`, `.github/workflows/`, profile files) | **None found** — see ④ |

Re-read rather than re-derived: `SecurityConfiguration.java:153-172`, `SecurityProperties.java:11`,
`application.properties:98,106`, `SecurityConfigurationTest.java:52-85`, `wms2-mobile-ui/plugins/axios.js:36-45`,
`nuxt.config.js:61,67`, `verify-…-2968.sh:118-135,282-287`.

F1–F9 were not re-derived except where noted. F3, F5, F7 and F8 were incidentally confirmed.

---

## DECISION ① — Sound, with one structural addition. Recommendation: **2968 owns it.**

F2 holds and is decisive: no `AccessDeniedHandler`, no `exceptionHandling(...)` block anywhere in the chain, so
2870's `@PreAuthorize` gates genuinely could not emit the header without new machinery.
Ownership-follows-the-emitter is the right principle.

**The reason that decides it against the standalone prerequisite PR:** that PR's payload — constant, CORS entry,
test — is **inert without an emitter**. Merging it alone ships an exposed header nothing writes, and extends the
`containsExactly` list to pin an element no code produces. Dead config plus a test asserting it is worse than the
coupling it removes.

But the rejection reasoning is incomplete. The re-home history (2870 → 2967 → 2968, two orphans) is a real
signal, and "assign to whoever lands first" is the mechanism that produced both. **Add the cheap half of the
prerequisite PR's benefit:**

1. Land the constant + CORS entry in 2968's **first** commit, not buried mid-branch.
2. Require 2967's Fix E to reference `Authority.AUTHZ_DENIED_HEADER` **by symbol**, never a string literal.

A third re-home then breaks 2967's build instead of silently logging operators out. Verify row `A27` already
enforces the by-constant rule on the interceptor side (`file_not_contains '"X-Authz-Denied"'`,
`verify-…-2968.sh:118`); mirror it into 2967's row set.

---

## DECISION ② — Sound in principle; the prescribed assertion introduces an order coupling.

F7 confirmed by reading the file: `corsConfigurationSource_exposesSkippedCycleCountHeader_whenPropertyAbsent`
uses `.contains(...)` at `:64`; only `..._doesNotDuplicateHeader_whenPropertyAlreadySuppliesIt` uses
`.containsExactly(...)` at `:83-84`. Keeping list-exactness is right — it is the only thing in the repo that
would notice a silent drop.

**Change `containsExactly` → `containsExactlyInAnyOrder`.** AssertJ's `containsExactly` is order-sensitive. With
two elements the outcome depends on whether the property supplied `X-Export-Skipped-Cycle-Counts` before the code
added `X-Authz-Denied` — i.e. on the order of two `addExposedHeader` calls at `SecurityConfiguration.java:165-168`
that no requirement constrains. A reordering that changes nothing observable turns the test red.
`containsExactlyInAnyOrder` preserves exact membership, which is the property the decision actually wants. This
is **not** the relaxation the decision forbids; `contains` is.

**Interaction with the verify script — two rows, not one.** `H24` asserts the dedup test "still uses
`containsExactly` (not relaxed)" (`:282`) and `H25` greps `-A2` from the same literal (`:284-286`).
`containsExactlyInAnyOrder(` does **not** contain the substring `containsExactly(`, so **both rows go red on
correct code** under this change — the same failure shape as the `H24` error already listed at the top of the
brief. Both must accept either exact form and reject only `contains(`.

**Retracted — a second gap claimed here was wrong.** This review initially reported that the
`whenPropertyAbsent` path would never assert the new header. It will: plan `:506` adds a *new* case,
`corsConfigurationSource_exposesAuthzDeniedHeader_whenPropertyAbsent`, and plan `:238-239` deliberately leaves
the existing `.contains(…)` case alone. Parallel cases per header is a better design than the extension this
review recommended. **The gap does not exist**; `G3` in the gap table is withdrawn.

---

## DECISION ③ — Sound. The claim was **checked, not reasoned**; "curl is inadmissible" needs narrowing.

Verified on a two-origin mock (403 + `X-Authz-Denied`, one route listing the header in
`Access-Control-Expose-Headers`, one omitting it): `response.headers.get('x-authz-denied')` returns `null` when
the header is not exposed and `"true"` when it is, on otherwise byte-identical responses. `curl -i` shows
`X-Authz-Denied: true` in **both** cases. Rows 3 and 5 of the instrument table hold. CORS filtering applies to
error responses, so the 403 case behaves like a 200.

**The claim as written is too broad.** A curl assertion on the header's *presence* is inadmissible; a curl
assertion on the *expose list* detects the same defect with no browser and no account. Confirmed live against
`wms2-api` on `27e2f21`: `curl -s -i -H 'Origin: http://localhost:3001' http://localhost:8088/v3/system/mobileUiUrl`
returns `Access-Control-Expose-Headers: X-Export-Skipped-Cycle-Counts` on an unauthenticated 401. On the fixed
tree that line must carry two headers.

**The decision survives anyway.** Arm (b) of M23 — denial message renders, no logout, no max-unauthorized toast —
is behavioural, and only a browser produces it, given `retryCondition` at `wms2-mobile-ui/plugins/axios.js:36-45`
and the logout in `onMaxRetryTimesExceeded`.

**Recommended rewording:** *"a curl check on the header's presence is inadmissible; on the expose list it is
admissible but insufficient."*

**Any surviving curl row must assert the status line alongside the header.** A bare grep returns identical empty
output whether the header is missing (the defect) or the request never reached the filter chain (a typo). Observed
directly: `/v3//system/mobileUiUrl` is rejected by Tomcat at 400 before `CorsFilter` runs and carries no CORS
headers at all. Silent, indistinguishable failure — the same class as the `H24` error, red on correct code.

---

## DECISION ④ — Sound. Tighten the rationale's wording; the conclusion holds.

**This review initially judged ④ wrong.** The objection: `addExposedHeader` is override-proof for the expose
list, but the browser only receives `Access-Control-Expose-Headers` when the **Origin is allowed**, and
`rest.security.cors.allowed-origin-patterns` (`application.properties:98`) binds through
`@ConfigurationProperties(prefix = "rest.security")` (`SecurityProperties.java:11`) and is therefore overridable
per environment as `REST_SECURITY_CORS_ALLOWED_ORIGIN_PATTERNS`. That looked like exactly the env-specific drift
the rationale asserts cannot exist.

**Checking the deployed configuration retired the objection.**

| Probe | Result |
|---|---|
| Every `allowed-origin` declaration in the repo | Two: `application.properties:98`, and `allowed-origins=*` in test resources. **No override anywhere** |
| Profile-specific property files | **None exist.** `SPRING_PROFILES_ACTIVE=wineco` at `Dockerfile:45` is commented out |
| Config externalization | `ENTRYPOINT` is a bare `-jar app.jar` — no `--spring.config.location`, no config volume, no env injection in `Dockerfile`, `.gitlab-ci.yml`, or the three `.github/workflows/` files |
| `REST_SECURITY_*` anywhere | Only in two source comments (`SecurityConfiguration.java:159`, `SecurityConfigurationTest.java:50`) |
| Reach of the baked default | Spring compiles `*` in an origin pattern to `.*`, so `https://*.sbo.li` matches multi-level hosts such as `https://wms.wineco.dev.sbo.li` (the deployed host at `wms2-web-ui/nuxt.config.js:77`). Broad enough that no environment needs to touch it |

**And the decisive point, which the initial objection missed: a wrong origin pattern is loud, not silent.** It
breaks *every* cross-origin request, not one header read — the UI is comprehensively broken within seconds of a
deploy. Expose-list omission is the opposite: one header silently unreadable while everything else works. Only
the silent class needs a dedicated smoke row. So the credential-free check genuinely has no silent failure mode
to catch, and dropping it costs nothing even under F10's re-weighted account scarcity.

**Recommended change — wording only.** The rationale reads "there is no env-specific drift for such a check to
catch." Say **"no *silent* env-specific drift."** As written it claims a property of all CORS configuration that
is justified only for the expose list, and it is that overreach — not the conclusion — that made this decision
look wrong on first reading.

**One residual, stated for honesty.** Deployment is Kubernetes and the manifests live outside this repo
(`.gitlab-ci.yml:31`), so absence of an override is inferred from the image having no mechanism to receive one,
not observed in a manifest. If a k8s Deployment does set `REST_SECURITY_CORS_ALLOWED_ORIGIN_PATTERNS`, the
finding above is unaffected — the failure would still be loud.

---

## DECISION ⑤ — Inadequate as written. Structural replacement below.

Prose is the same class of control that already failed twice, and the brief's re-weighting is right that F10 makes
it three times with no scope move involved. The general defect is **any inherited claim carried as fact**, so a
mitigation scoped to relocations is too narrow even setting the medium aside.

**Proposal — an `[inherited]` verify-row class.** The repo already has the mechanism: the verify script's labelled
rows. Add a third label beside `[pre-passes]`:

> Every claim a plan makes about state it does not itself create must appear as a verify row that re-executes the
> check on the receiving branch.

- *"the header is already emitted by SBDEV-2870"* → `run X1 "[inherited] X-Authz-Denied exists in src/main" grep -rq …`
  — red on `27e2f21`, which is the orphan, caught the day the plan was written.
- *"a `CS-REP`-shaped account exists"* → a row running the SELECT. F10 found by machine, not by someone needing
  the account.

It is executable rather than prose, it runs on the receiving branch (which is "grep the receiving branch",
automated), and it generalises past relocation to the whole inherited-claim class.

**Reinforcement, cheap:** the compile-time reference from ① (an orphaned constant becomes a build break), and the
brief's own F-table format — claim, evidence, command, date — as a required plan section for any inherited claim.
The `[inherited]` row class is the load-bearing part; the other two are secondary.

---

## Interactions between decisions

- **④ depends on ①'s override-proof property, and the dependency holds — but only for the expose list.** ① is
  safe because the constant and the emitter travel together. ④ borrows that property to cover origin matching,
  which ① never claimed; the gap is closed not by ① but by origin failures being loud. The brief should say so,
  because as written ④ reads as though ① covers it.
- **②'s exactness argument correctly motivates ③'s test-vs-behaviour split.** `SecurityConfigurationTest` proves
  the list; only a browser proves the reading. That dependency holds.
- **②'s recommended change collides with verify row `H24`.** Fix the row in the same commit.
- **③ and ④ judge the same instrument by different tests, and neither says so.** ③ rejects curl because it
  cannot *detect* the defect; ④ rejects it because there is nothing left to detect. Both hold, but a reader who
  applies ③'s stated reason to ④'s variant will wrongly conclude the two contradict each other — ③'s narrowing
  (curl reads the expose list fine) is exactly what makes ④'s variant technically capable and merely redundant.
  One sentence connecting them would prevent the misreading this review made on first pass.

---

## Cases §3.1-A2b misses entirely

| # | Gap | Evidence |
|---|---|---|
| G1 | **Allowed-origin drift is unchecked** — header readability depends on the Origin being allowed, not only on the expose list. Low severity: no environment overrides it and the failure would be loud (see ④), but no document states why it is safe to ignore | `application.properties:98`, `SecurityProperties.java:11` |
| G2 | **Absent CORS configuration bypasses the whole block**, including the "override-proof" add. Also loud rather than silent, and unreachable given the baked default | `SecurityConfiguration.java:155` |
| ~~G3~~ | **WITHDRAWN** — the plan adds a parallel `…_exposesAuthzDeniedHeader_whenPropertyAbsent` case; the path is covered. See ② | plan `:506` |
| G4 | **Curl-shaped rows can return empty for reasons unrelated to the property under test** (container-level 400 before `CorsFilter`); no row asserts a status line | observed on `/v3//system/mobileUiUrl` |

---

## Not examined

- SBDEV-2968's mechanism, its 66-endpoint surface, its fail-closed design, and the pre-existing verify rows —
  out of scope per the brief.
- **M23 end-to-end.** Blocked by F10: no account exists on either tenant, and no interceptor code exists to deny
  with. The browser evidence above is from a mock reproducing the CORS shape, not from the real denial path.
- 2967's Fix E controller gate — read only as described in the brief.
- The verify script was not run; rows were read, not executed.
- F1, F4, F6 and F9 were taken on trust.
- **The Kubernetes manifests.** They are not in this repo, so the ④ finding rests on the image having no
  mechanism to receive an override, not on reading a Deployment spec.


---

## Addendum — disposition (2026-08-19)

Every recommendation in this report has been applied. Nothing is left as prose-only.

| Verdict | Change | Landed in |
|---|---|---|
| ① | Constant + CORS entry in 2968's first commit; 2967 must reference `Authority.AUTHZ_DENIED_HEADER` by symbol; `A27` mirrored | 2968 §11.2 row 10; 2967 §3.5.1-4 |
| ② | `containsExactlyInAnyOrder` prescribed, with the order-sensitivity reasoning | 2968 §3.1-A2b item 3; 2967 §3.5.1-5 |
| ② | `H24` **and** `H25` widened to accept either exact form, reject only `contains(` | verify script `:282-289` |
| ③ | "curl is inadmissible" narrowed to the header's *presence*; status-line rule added to every curl row; the probe result recorded | 2968 §14.4, §9 M-table preamble, M2 |
| ④ | "no ***silent*** env-specific drift"; the near-miss and the deployed-config probe recorded | 2968 §5.1-P8 note, §14.4a (new), §14 |
| ⑤ | `[inherited]` row class; rows `X1`/`X2`/`X3` implemented | 2968 §14.7; verify script, new "Inherited preconditions" section |
| — | `R13` ID collision fixed (observability row → `R14`) | 2968 §8 |

**Row behaviour verified, not assumed.** `H24`/`H25` were exercised against three inputs: `containsExactly(`
→ pass, `containsExactlyInAnyOrder(` (multi-line) → pass, `contains(` → fail. `X2` was exercised in three
states: evidence file correct → pass, present but wrong shape → fail, absent → fail with the explanatory label.

**Two blockers this review does not resolve.**

1. **`X2` is red and stays red** until §14.6's purpose-made account exists. M23 cannot run; AC-31 and P10 have
   no acceptance evidence until then. This needs Keycloak plus DB write access.
2. **The verify script requires bash ≥ 4** — `declare -A` at `:151` aborts under macOS's stock bash 3.2 with
   `mobile: unbound variable`, so the full 95-row baseline could not be re-measured here. Pre-existing, unrelated
   to these edits, but it means the script silently grades *nothing past line 151* on a default macOS shell.
