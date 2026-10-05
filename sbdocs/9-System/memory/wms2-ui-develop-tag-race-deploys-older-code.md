---
name: wms2-ui-develop-tag-race-deploys-older-code
description: "Back-to-back merges in EITHER v2 repo (wms2-web-ui AND wms2-api) race on the mutable :develop image tag; the LATER-FINISHING build wins and can contain LESS. wms2-api HAS a concurrency: block and it does NOT prevent this - the key is the SHA"
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

---

## Addendum 2026-09-22 — `wms2-api` has the SAME race, and its `concurrency:` block does NOT stop it

⚠ **This corrects the "permanent fix" line above.** That line offers "`concurrency:` with
cancel-in-progress in the workflow" as the cure. `wms2-api`'s
`.github/workflows/docker-image-develop.yml` **already has one**, and it is no protection:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.sha }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

**On a push the key is `github.sha`**, so every merge lands in its own group. Distinct groups neither
cancel nor serialise, and `cancel-in-progress` is false on push anyway. The block's stated purpose is
to supersede a PR's own stale runs and *never* cancel a push — a deliberate, correct choice — but it
means back-to-back merges to `develop` still race to push the same mutable
`hub.impactathleticsny.com/wms2-api:develop` tag and fire the same two Portainer webhooks.

So: **seeing a `concurrency:` block in the workflow does not mean the deploy is serialised.** Read the
group key. A SHA-keyed group is per-commit and buys nothing for this race.

**Measured 2026-09-22** — SBDEV-3410 P2/P3/P4 merged 38s apart, three builds fully parallel:

| finished | merge commit | phase | result |
|---|---|---|---|
| 13:13:48Z | `5111e077` | P2 | success |
| 13:14:24Z | `75ed4841` | P3 | success |
| 13:14:39Z | `b87ec747` | P4 | success ← last writer, and also the newest commit |

Commit order and finish order happened to coincide, so dev got the right image. That was **luck, not a
guarantee** — 36 seconds of runner variance the other way and dev would have run P2-only code while
`develop` HEAD read P4.

**The probe is far easier here than on the UI.** No chunk-hash archaeology: the API workflow passes
`APP_VERSION=develop-${{ github.sha }}` into the image, and the version endpoint echoes it
unauthenticated:

```bash
curl -s https://wms-api.dev.sbo.li/api/public/version
# {"environment":"DEV","self":{"repository":"wms2-api",
#  "version":"develop-b87ec74729f6b443684937107783abe27c88889d"},"drift":false}
```

Compare that SHA to `git rev-parse origin/develop`. ⚠ `drift: false` in that payload does **not** grade
this — it reported `false` throughout, and the `environment` field is independently known to lie
([[wms2-version-endpoint-environment-field-lies]]). The **`version` SHA** is the only field that
settles it.

**Practice:** merge one PR, wait for its build, then merge the next. If several are already merged
back-to-back, check `/api/public/version` afterwards and `gh run rerun <run-for-the-newest-sha>` if the
wrong one won. Also note `wms2-api`'s develop workflow gates the image on `mvn clean verify`
(~16 min here), so its build window is much wider than the UI's ~3.5 min — more room to race, not less.
