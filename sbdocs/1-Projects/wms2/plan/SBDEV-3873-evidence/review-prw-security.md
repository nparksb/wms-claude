---
head: bcd9c29
lane: security (PR-W, wms2-web-ui)
date: 2026-10-22
verdict: APPROVE code; DO NOT MERGE until gate G1 holds
---

# SBDEV-3873 PR-W — security review

head: bcd9c29 (branch `bugfix/SBDEV-3873-savecomment-endpoint`, base `origin/develop` 98accaf, freshly fetched, HEAD contains it).
Scope: `git diff origin/develop...HEAD` (10 files), plus a sweep of the whole UI source tree for the questions below.

**Risk level: LOW for the code. The deploy-order gate is still open (Medium, process).** High 0 · Medium 1 · Low 4 · Info 3.

## Questions asked, and answers

| Check | Result | Evidence |
|---|---|---|
| Remaining UI write to `/advice/{id}` or `/cyclecount/{id}` via SDR | **None.** Every `$patch`/`.patch`/`$put` call site in store/components/pages/plugins/mixins/layouts/middleware/util was listed: PATCH only on `/customerorder/`, `/client/`; PUT only on sysprop, boxtype, userGroup, printer, putawayConfig, location. No `method: 'patch'` form exists. The only dynamic advice item path is `$delete(\`/advice/${…}\`)` at `store/receiving/inboundNotices.js:197` (plan S9, already 405). | grep sweep at bcd9c29 |
| Mobile UI (out of scope) | `wms2-mobile-ui` `origin/develop` 1497c3b: zero `$patch`/`.patch` call sites at all. | `git grep` on origin/develop |
| Cypress | No remaining `patchAdvice`, `patchCycleCount` or `'PATCH'` in `cypress/`. | grep |
| New call sends only `{id, comment}` | **Yes.** `this.$axios.$post('/advice/setComment', { id: data.id, comment: data.comment })` — an explicit literal, not `data`; the AC-W1 test pins it with extra caller keys (`externalid`, `state`) dropped. | `store/receiving/inboundNotices.js:410` |
| XSS on comment rendering | **Safe.** No `v-html`, `innerHTML`, `insertAdjacentHTML`, `document.write` anywhere in app source. Advice comment is shown only via `v-model` on a `v-textarea`; cycle-count comment via `{{ }}` mustache / `:value` (escaped) in `plannedFullDetails.vue:57,69`, `closedFullDetails.vue:58,70`, `plannedCycleCount.vue:98`, `closedCycleCount.vue:93`. | grep |
| Error responses rendered unsafely | **No.** `saveComment` toasts a static string; the 422/403/404 body is never relayed. And `plugins/toast.js` HTML-escapes every `$toast.*` argument anyway (only `infoHtml` is raw, one static call site). | `inboundNotices.js:414` |
| Cypress credential leakage | **None in the diff** (deletions only; no added line matches password/secret/token/api key). Pre-existing auth: `KC_PASSWORD` read from `cypress.env.json`, which is gitignored (`.gitignore:101`) and not tracked; the example file has placeholders only. | `git diff`, `git check-ignore` |
| Deploy-order gates | Stated correctly in the plan (§5.1 P1/G1, §9), but **not yet met and not yet carried into any artifact this repo's flow sees.** See M1. | below |

## Findings

### M1 — Medium (process / availability): G1 is open, and it lives only in sbdocs
- **Where:** plan §5.1 P1; commit `bcd9c29` message; no PR opened yet (`gh pr list --head bugfix/SBDEV-3873-savecomment-endpoint` empty).
- **State now:** `GET https://wms-api.sbo.li/api/public/version` → `{"environment":"PRD",…,"version":"0.0.42"}`. The plan records that the `path = "/setComment"` grep finds nothing on `v0.0.42`. **PR 1 is not on PRD; G1 is not satisfied.**
- **Release flow (this repo):** `.github/workflows/docker-develop-image.yml` builds on `develop` (dev), `docker-uat-image.yml` on `release` (UAT), `docker-image.yml` on `main` (PRD), plus `docker-develop-arden-image.yml` on `develop-arden`. Web and api are promoted independently by devops. So the only control point the team owns is the merge into `develop`, which is what G1 holds — the design is right.
- **Scenario if violated:** PR-W merged now → dev is fine (dev api serves `develop-f53a6eb2`, which has the endpoint), but the next web `develop → release → main` promotion can ship before the api release. On an api without the mapping, `POST /advice/setComment` is unmapped (or resolves to the SDR item `/advice/{id}` with a POST → 405). Because `closedNoticeDescription.vue:235-244` re-saves on every page open, every closed-notice view on that environment toasts an error and every comment edit is lost. Fail-closed (no data exposure), hence Medium not High.
- **Gaps in how the gate is stated for this repo:**
  1. sbdocs is not in git and devops never sees it; the commit message does not mention the dependency. The gate must be in the PR body, and the PR should be opened as **draft** (or labelled "blocked: wms2-api#561 on PRD") until G1 passes.
  2. G1 proves PRD only. It implicitly assumes UAT api ≥ PRD api. Add one line: also confirm the UAT api serves the mapping before merging (cheap: same version + `git grep` against the UAT version), since a UAT api rollback/hotfix branch would otherwise get a web `release` build that 405s.
  3. `develop-arden` builds its own dev image from a separate branch; if that branch takes `develop` while its api pairing lacks PR 1, the same 405 appears there. Informational — name it in the PR body.
- **Remediation (PR body text):**
  ```markdown
  ⛔ Merge gate G1: do not merge until wms2-api #561 (merge f53a6eb2) is served on PRD
  AND UAT. Proof: /api/public/version → v<ver>; `git grep -nE 'path *= *"/setComment"' v<ver>
  -- src/main/java/net/aim_ai/wms/controller/AdviceController.java` matches.
  Rollback: never roll web back past this PR once wms2-api PR 2 is live.
  ```

### L1 — Low: the closed-notice page still writes on every open
- `components/receiving/closed/closedNoticeDescription.vue:235-244` — `setInitialComment()` assigns `this.comment`, which trips the `comment` watcher and POSTs the loaded value 700 ms after open.
- Not introduced here and now benign (comment-only endpoint, no UPDATE when unchanged per plan A2), but it means a pure read issues an authenticated write, and the write is gated by a **view** function (`WEB_UI_VIEW_INBOUND_BOL`). Any user who can see a closed notice can set its comment — same as before, so no new exposure.
- Fix (follow-up, not required for this PR): only save on user input.
  ```js
  // GOOD: save on user edits, not on load
  <v-textarea v-model="comment" maxlength="255" @input="onCommentInput" … />
  methods: {
    onCommentInput() {
      clearTimeout(this.timeout)
      this.timeout = setTimeout(() => this.$store.dispatch('receiving/inboundNotices/saveComment',
        { id: this.noticeDetails.id, comment: this.comment }), 700)
    },
  },
  beforeDestroy() { clearTimeout(this.timeout) },
  ```

### L2 — Low: lost update on stale tabs (plan §5 A2 overstates the `@Version` protection)
- The request carries no version, and the service re-loads the row inside the transaction, so `@Version` only catches two *overlapping transactions*. A stale tab editing an hour-old comment silently overwrites a newer one; no 409. Comment field only, user-attributable, low impact. Correct the plan wording ("409 only on concurrent commits"), or send `version` if this ever matters.

### L3 — Low: AC-W3 scanner has blind spots (by design, documented)
- `test/store/noSdrPatchOnAdviceCyclecount.spec.js:28` regex misses: path in a variable, `$axios({ method: 'patch' })`, `$axios.request`/`$request`, `_links.self.href`-driven URLs, `cypress/` (not in `SCANNED_DIRS`), and PUT/DELETE. The header comment states the first two honestly; the sweep above confirms none exist today. The durable fence is PR 2 (server-side withdrawal); after PR 2 lands this test is belt-and-braces. Optional: add `cypress` to `SCANNED_DIRS` and a `method:\s*['"]patch` branch.

### L4 — Low: `maxlength="255"` is client-side only
- `closedNoticeDescription.vue:101`. Trivially bypassed, but the server enforces `> 255 → 422` (PR 1 A2), and the UI's toast is static. Correct layering; noted only so nobody treats the attribute as the control. Browser `maxlength` counts UTF-16 code units, matching the server's `length()` check.

### Info
- I1: `saveComment` still logs the server result with `console.log` (`inboundNotices.js:411`) — comment text and id only, no secrets.
- I2: Cycle-count Cypress P1.5 now only reads the detail; no write remains against a shared dev DB from that step.
- I3: Removing the cycle-count echo removes a write that previously fired on every open of a planned count under any user who could view it — a net reduction of authenticated write surface.

## OWASP pass (applicable)
A01 access control: unchanged; new endpoint gated server-side (PR 1). A03 injection/XSS: no HTML sinks for comment; toast escaped. A04 design: mass-assignment closed on the client by an explicit body literal. A05: n/a. A06: no dependency change in the diff (package*.json untouched) — `npm audit` not re-run as nothing changed. A07/A02: no auth/crypto code touched. A08: CI files untouched. A09: n/a. A10 SSRF: n/a (fixed relative path).

## Checklist
- [x] No hardcoded secrets (diff + Cypress env handling)
- [x] Inputs constrained (explicit `{id, comment}`; server 255 cap)
- [x] Injection/XSS: no `v-html`; mustache/v-model only
- [x] Authz: server-side gate (PR 1); UI adds no new route
- [x] Dependencies: unchanged
- [ ] **Deploy gate G1 satisfied — NO (PRD on 0.0.42 at review time)**
