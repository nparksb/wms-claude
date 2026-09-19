---
name: wms2-ui-openobserve-rum-rollout
description: "OpenObserve RUM in both v2 UIs (web PR #100 / mobile PR #52) — enable switch, the SDK API traps, and the three deferred decisions"
metadata: 
  node_type: memory
  type: project
  originSessionId: 9d095c90-6260-4686-be95-6cc8629e0c55
  modified: 2026-09-02T19:56:51.055Z
---

Both v2 UIs got the same OpenObserve RUM + browser-logs port (web-ui PR #100 `44d5b1e`,
mobile-ui PR #52 `219163b`, both onto `develop`, reviewed 2026-09-02). `util/telemetry.js`
+ `plugins/telemetry.client.js` are byte-identical across the two apps except
`SERVICE_NAME` (`Siteboss-WMS-Web-v2` / `Siteboss-WMS-Mobile-v2`) — **fix both or
neither**.

**Enable switch:** `OO_APP_ID` unset ⇒ zero telemetry. A stack that enables RUM must set
`OO_ENV` too, or replay defaults to 100% instead of prod's 50%.

**SDK API traps** (`@openobserve/browser-*@0.4.1`, a Datadog browser-sdk fork):
- The real method is **`clearUser`**. There is no `removeUser` — `RumPublicApi` has
  `clearUser` + `removeUserProperty` only. Mocking `removeUser` in a test makes
  `clearUser || removeUser` resolve to the mock-only branch, so the logout test passes
  while never exercising production's call. See [[green-tests-that-prove-nothing]].
- **`trackAnonymousUser` defaults to `true`** (`browser-core/configuration.js:79`) and
  persists a device id in a long-lived cookie that `clearUser()` does NOT clear. Now
  pinned `false` in both apps — on shared workstations/handhelds it would otherwise
  correlate every operator under one device identity.
- **`startSessionReplayRecordingManually` defaults to `sessionReplaySampleRate === 0`**,
  so replay auto-starts and an explicit `startSessionReplayRecording()` call is a no-op
  unless you pin that flag true. Now pinned true, which makes the
  `if (replaySample > 0)` guard the actual switch.

**Deferred, not defects — decisions for Nam:**
1. **~81 KB gz on every page load even when telemetry is off** (`openobserve-rum.js`
   61 KB gz + `openobserve-logs.js` 20 KB gz, measured on the published bundles). The
   imports are static top-level, so webpack bundles them regardless of `OO_APP_ID` —
   "unset = no-op" is about behavior, not bytes. Matters most on mobile handhelds over
   warehouse wifi. Fix would be a dynamic `await import()` inside `initTelemetry()`.
2. **Session replay records rendered DOM text.** `defaultPrivacyLevel:
   'mask-user-input'` masks form *inputs* only, and `trackUserInteractions: true`
   derives action names from clicked element text. WMS pack/ship/BOL screens render
   customer names and addresses → those reach logs.sbo.li at 100% (dev/qa) / 50% (prod).
   Same posture as the oms-frontend rollout, so likely intended.
3. **web-ui has no yarn.lock at all** (`.gitignore:9`) while its Dockerfile builds with
   `yarn install`. Mitigated for the two new deps by exact-pinning them in
   `package.json`; the general gap stands. See
   [[wms2-ui-dockerfile-never-reads-the-lockfile]].

`forwardErrorsToLogs: true` forwards `console.error` only, so the
`console.log('token:', tokenParsed)` sites (web `pages/index.vue:84`, mobile `:93`) are
NOT shipped — but they would be the moment anyone adds `forwardConsoleLogs`.
