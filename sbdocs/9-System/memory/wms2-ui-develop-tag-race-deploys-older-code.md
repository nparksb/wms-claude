---
name: wms2-ui-develop-tag-race-deploys-older-code
description: "Two wms2-web-ui merges inside one ~3.5min build window race on the mutable :develop image tag; the LATER-FINISHING build wins and can contain LESS, so dev silently runs older code with a NEWER image timestamp"
metadata: 
  node_type: memory
  type: project
  originSessionId: 090d6843-67d6-490d-ba93-46e2f9cddd8e
  modified: 2026-08-28T13:51:31.774Z
---

**Measured 2026-08-28.** Merged PRs #90 and #91 to `wms2-web-ui` `develop` six seconds apart. Both
pushes triggered `.github/workflows/docker-develop-image.yml`, which builds and pushes the **mutable**
tag `hub.impactathleticsny.com/wms2-web-ui:develop`, then POSTs a Portainer webhook to redeploy.

| CI run | built from | had the new feature | finished |
|---|---|---|---|
| 33174755462 (#91) | `6e68b31` | YES | 13:21:**12**Z |
| 33174748590 (#90) | `73a51b7` | NO | 13:21:**15**Z ← last writer |

`actions/checkout` uses the **triggering push's SHA**, so #90's build was pre-#91 content. It finished
3s later, overwrote `:develop`, and dev ran code from one commit earlier — for 25 minutes, through two
container refreshes.

**Why it is so hard to see, and the two traps that cost the most time:**

1. **The served asset's `last-modified` was NEWER than the merge** (13:20:19Z, inside the build window),
   so every "is it deployed?" heuristic based on freshness says YES. The image *is* new; its *contents*
   are older. Check for a **string unique to your change**, never a timestamp.
2. **The chunk hash did not change either.** PR #90 was comments-and-tests only, so it produced
   byte-identical runtime output to pre-merge — same `_nuxt/<hash>.js` filename, same 36177 bytes.
   So "the bundle hash changed" is ALSO not a deploy signal.
3. Polling the **root HTML's script srcs is useless** for component changes: it lists only the 4 entry
   chunks. Vue components live in lazily-loaded ROUTE chunks, discoverable only after navigating to the
   page. My first "not deployed" verdict scanned 0 bundles and was right by luck.

**The probe that actually works** — unauthenticated, no browser:
```bash
curl -s https://wsl-wineco.wms.dev.sbo.li/_nuxt/<route-chunk>.js | grep -c <newIdentifier>
# and: when a NEW build lands, the old content-hashed chunk 404s
```
Find `<route-chunk>` once by loading the page in a browser and listing fetched `*.js`.

**Fix:** `gh run rerun <the-run-whose-sha-has-your-change>` makes it the last writer — confirm no other
`develop` build is in flight first. Permanent fix is tagging by commit SHA, or `concurrency:` with
cancel-in-progress in the workflow.

**A plain container restart does not re-pull a mutable tag** — Portainer must recreate with pull. Here
the webhook does pull (proven: asset timestamps moved), so the tag content was the only problem.

⚠ Same workflow file carries the **container-registry username and password in PLAINTEXT** plus an
unauthenticated Portainer redeploy webhook URL, both in git history. Rotate and move to Actions
secrets. Related: [[deploy-only-to-develop-release-and-main-are-devops]],
[[wms2-merge-to-develop-is-a-dev-deploy-and-runs-flyway]].
