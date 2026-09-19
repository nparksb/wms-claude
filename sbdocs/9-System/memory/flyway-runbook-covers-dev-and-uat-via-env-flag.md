---
name: flyway-runbook-covers-dev-and-uat-via-env-flag
description: "The tenant-Flyway runbook + driver script cover DEV, UAT and PRODUCTION via a required --env flag; prd added 2026-07-30"
metadata:
  node_type: memory
  type: reference
  originSessionId: 23a3cf05-8405-4cd0-9d02-3604e4b4ee5f
  modified: 2026-08-04T12:34:08.097Z
---

**⚠️ 2026-08-04 — the "app never runs Flyway" premise this runbook rests on is DEAD on `develop`.**
SBDEV-2801 (PR #120, merge `27a1878`) made the app run Flyway on **every boot** against the landlord
plus every active tenant DB, **default-ON in every environment** — see
[[sbdev-2801-runtime-flyway-default-on]]. The runbook is *not* obsolete: it is still the only path for
legacy psql-provisioned DBs (auto-migration skips them) and for any stack pinned with
`APP_FLYWAY_MIGRATE_ON_STARTUP=false`. But on DEV, tenants may now already be migrated by the time you
run `--status`, so an unexpected "0 pending" is no longer automatically a wrong-env signal. Prod tracks
`main` and is unaffected until this is promoted.

**Run UAT/PRD from a throwaway worktree, never the primary checkout.** The working `wms2-api`
clone lives on `develop` and routinely carries uncommitted migration edits, so switching it
to `release`/`main` risks dragging those into a run. Instead:
`git worktree add -B <release|main> <scratch> origin/<release|main>` → clean checkout whose
branch name satisfies the script's §4.4 branch check (it reads `rev-parse --abbrev-ref HEAD`, so a
detached worktree would report `HEAD` and fail); remove the worktree *and* the temp branch
after. Verified 2026-07-30 taking all four UAT tenants `2.2.04` → `2.2.05`.

UAT has **no inactive tenant rows** (unlike DEV's three NEEDS-BASELINE scratch DBs), so
`--include-inactive` there discovers the same 4 and exit `0` is the clean-state signal.

Tenant Flyway migrations for wms2-api are driven by:

- `sbdocs/9-System/scripts/apply-pending-tenant-flyway.sh` (was `uat-apply-pending-tenant-flyway.sh`)
- `sbdocs/2-Areas/runbooks/wms2-apply-pending-tenant-flyway.md` (was `…-uat.md`)

Extended UAT-only → DEV+UAT on 2026-07-29, → **+PRD on 2026-07-30**. **`--env dev|uat|prd` is
required with no default** — all three answer on `localhost` and differ by one port digit, with
**prd's `25061` sitting BETWEEN dev's `25060` and uat's `25062`**, so the flag is the guard against
targeting the wrong fleet. It sets landlord host/port/DB **and role**, tenant port override, and the
expected branch (`develop` / `release` / `main`).

## Production specifics (all verified 2026-07-30)

- Landlord is **`wms2_landlord` as `wms2_landlord_app`** — a different DB name *and* a different
  role from dev/uat's `wms_landlord`, so the role had to become profile-driven (a hard-coded role
  makes a wrong-env mistake look like a password failure). MCP `landlord-prd`; tunnel
  `-L 25061:100.92.232.69:25060 npark@wms.siteboss.net` (Tailscale addr, not a public host).
- **Exactly ONE v2 prod DB**: `nywh` → `wh01_hydra_v2` (30 MB). LANDMINE: **six LIVE v1 DBs share
  that server** (`wh01_om1` 10 GB, `wh01_shipitez`, `wh02_hydra`, `wh01_hydra`, `wh02_shipitez`,
  `wh01_hmg`). Landlord discovery is the *only* thing scoping this correctly — never hand-name a DB
  on prd. The v2 DB is the *small* one.
- **PRD is PostgreSQL 14**; dev/uat are 16. A migration using a 15+ feature passes UAT, fails prod.
- **Prod tracks `main`, which LAGS `release`** — reached by promotion merge, so a migration live on
  UAT is *not* pending for prod until promoted. On 2026-07-30 prod was already at `2.2.04` = main's
  highest (v0.0.9); `V2.2.05` sat on `release` (v0.0.10) unpromoted, so there was **nothing to
  apply**. Check `git log origin/main..origin/release` before assuming work exists.
- **On `main` the semver tag is never ON HEAD** (promotion merge puts it on the merged-in commit),
  so `git tag --points-at HEAD` returns empty and that is NORMAL. Use `git describe --abbrev=0`,
  which is what `docker-image.yml` does. The script mirrors this for prd only — deliberately not for
  dev/uat, where an empty tag is a signal worth seeing (on develop `describe` returns `v0.0.1`).
- Prod deploy is **manual**: the Portainer webhook in `docker-image.yml` is commented out. Image is
  `wms2-api:<version>-prod` + `:latest`. No `owl-v*` tag is reachable from main, so prod images
  carry an empty `PLATFORM_RELEASE`.
- **Do NOT pull a migration forward into prod ahead of its release.** §5.4's additive pre-merge
  logic is DEV-only; on prod it strands the one no-cushion DB on an unblessed version, and a later
  amendment to that same `V2.2.x` lands as simultaneous checksum + description drift.

Safety guards, all negative-tested:
- **L001 landlord preflight** — refuses if the landlord lacks the `active` columns. Doubles as a
  wrong-landlord detector on DEV (see [[wms2-dev-landlord-is-dev-landlord-not-landlord]]).
  Prod already had L001.
- **Branch-mismatch refusal on `--apply`** — a `develop` checkout aimed at `--env uat` reports
  develop-only migrations as UAT-pending and would apply them ahead of the release. `--status` only
  warns. Escape hatch `--allow-branch-mismatch` exists for the DEV pre-merge flow.
- **`--confirm-production`** — required alongside `--apply` on `--env prd`. Needed because the
  branch check is weaker on `main`: a stale `main` checkout is on the *right branch, wrong commit*,
  which under-reports the pending set (silent) rather than over-reporting it.
- **Behind-upstream staleness check** — warns on any env, and *refuses* `--apply` to prod when the
  checkout is behind `origin/main`. Read `--status`'s green together with the preflight's
  `migration set: N scripts, highest = X` line; that is the only place the pending computation's
  input is visible.

`--apply` against `--env prd` has **not yet run on a real pending migration** — treat the first one
as first-run. Per [[negative-test-verify-scripts-before-trusting-them]], the prod "no pending" green
was proven a true green by re-running `--status` from a `release` worktree and getting
`1 pending [2.2.05]`, exit 2.

The runbook's §6.1 baseline probe table is **manual** — add a row for each new `V2.2.x`.

**⚠️ 2026-07-30 — the V2.2.05 amendment was UNDONE.** An earlier note here (and in
[[wms2-sysprop-live-keys-exceed-code-constants]]) said `V2.2.05` was amended post-apply to seed two rows.
That was reverted the same day: UAT's four tenants were migrated to `2.2.05` from `release` (the original
file), which made the amendment an edit to a *published* migration. `V2.2.05` is back to
`V2.2.05__seed_outbox_reject_on_error_sysprop.sql` / checksum `2141461053` on **all five** tenants, and the
second seed now lives in `V2.2.06__seed_outbox_stuck_aggregate_metric_sysprop.sql` (PR #110, merged `ed4ed25`, SBDEV-2785). So: **no
amended `V2.2.05` exists any more — do not expect a checksum mismatch on it.**

**Recovery recipe that worked, for a genuinely-needed re-apply:** `DELETE FROM flyway_schema_history WHERE
version='<v>';` then `--apply`. Safe only when every statement in the migration is idempotent. `flyway repair`
is the wrong tool for a content change — it restamps the checksum without re-executing.
