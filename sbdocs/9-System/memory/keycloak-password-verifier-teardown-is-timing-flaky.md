---
name: keycloak-password-verifier-teardown-is-timing-flaky
description: "KeycloakPasswordVerifierUnitTest tearDown \"logouts still running after the test\" reds CI at random; rerun the failed job first"
metadata:
  node_type: memory
  type: reference
  originSessionId: e41d3beb-fbf7-48ea-8367-f1afc8cd18dd
  modified: 2026-10-29T01:16:23.247Z
---

`KeycloakPasswordVerifierUnitTest.verify_shouldFetchDiscoveryAtMostTwice_whenTenWrongIssuerApprovals` failed in
`tearDown:147 -> awaitLogoutPoolsIdle:238 [logouts still running after the test]` on wms2-api PR #581 (SBDEV-2251,
CI run 40794781460, 2026-10-29). That diff touched no Keycloak code; the same suite was 9188/0 locally on the same
head, and `gh run rerun --failed` went green (9188/0, 1079/0). An async-logout-pool timing race, not a regression.

**How to apply:** a lone red on this teardown, with an unrelated diff, means rerun the failed job before
investigating. If it reds twice on the same head, it is real. Sibling of [[tenant-provisioning-busylock-it-is-timing-flaky]];
listed in [[hub-flaky-its]].
