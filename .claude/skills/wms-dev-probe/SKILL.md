---
name: wms-dev-probe
description: Run a manual/dev test of WMS v2 changes against the DEV environment (wms-api.dev.sbo.li, tenant wineco/wsl, DB dev_wh01_om1) — token, API calls, SQL, seeding test data, and proving the data was restored. Use when the user says "test on dev", "test the PRs with <user>", "run the manual test plan", "dev test SBDEV-####", or a plan's manual-test section is next after wms-merge. Dev only: the scripts refuse any other host or DB.
---

# wms-dev-probe

A reusable kit for testing merged changes on **dev**. It packages the pieces rebuilt by hand on 2026-10-15
for SBDEV-3775, 3736 and 3755: token, API wrapper, psql fallback, and seed-and-restore. It also keeps
credentials out of the conversation.

## Setup (once per machine, by the USER, in their own terminal)

⚠ **Not through Claude, and not with a `!` command.** A `!` command and its output are added to the
conversation. Ask the user to run this in a normal terminal. The password is read silently and never goes into
shell history or argv:

```bash
mkdir -p -m 700 ~/.config/wms-dev-probe
IFS= read -rp 'WMS dev user: ' U; IFS= read -rsp 'WMS dev password: ' P; echo
( umask 077; printf 'WMS_DEV_USER=%s\nWMS_DEV_PASSWORD=%s\n' "$U" "$P" > ~/.config/wms-dev-probe/credentials ); unset U P
```

- **Format:** the file is **parsed, not shell-sourced**, so any character in the password is safe.
- **Allowed keys:** only `WMS_DEV_USER`, `WMS_DEV_PASSWORD`, `WMS_DEV_KEY` (default `wsl-wineco`), `WMS_DEV_TENANT`
  (`wineco`) and `WMS_DEV_FACILITY` (`wsl`).
- **Not overridable:** the API host and the DB allow-list.
- **Refusals:** the scripts refuse the file unless you own it and it is mode 600.

Never write a password into a file, a command or a message yourself. If the file is missing, stop and ask.

## Scripts (`.claude/skills/wms-dev-probe/scripts/`)

| Script | Does |
|---|---|
| `token.sh` | Fetches a token for the configured user. The realm and client come from `/api/public/authConfig`. The Keycloak URL must be `https://*.dev.sbo.li`. The password goes over stdin. The token is cached per user, mode 600, in `$XDG_RUNTIME_DIR` |
| `api.sh METHOD PATH [JSON]` | Calls dev with tenant headers. The token goes as a header **file** and the body on stdin, so neither is in argv. `/api/public/*` is sent without a token. **Exit 0 only for 2xx**, 1 for any other status, 2 for transport failure |
| `q.sh "<SQL>"` | psql against **`dev_wh01_om1` only**: host localhost, port 25060, DB on the allow-list, no URI query params. The password goes through `PGPASSWORD`. It can write |
| `snapshot.sh save\|diff <name> ["SELECT"]` | The restore proof. Rows are stored as sorted `to_jsonb` lines, so NULL and `''` differ. Refuses an empty snapshot (`--allow-empty`) and overwriting one (`--force`). Snapshots persist in `~/.cache/wms-dev-probe/snap` |

The DB MCP (`mcp__wms2-wineco-dev__execute_sql`) is fine for reads while it's connected. Use `q.sh` when it
drops, which it did mid-session on 2026-10-15, and for writes.

## Procedure

1. **What's deployed?** `.claude/skills/wms-dev-probe/scripts/api.sh GET /api/public/version`. The version SHA must
   contain the merge you're testing.
2. **Feasibility.** Run each scenario's precondition query (from the plan's manual-test table) **before** building
   it. Examples from 2026-10-15 where dev's data could not express a scenario:
   - 0 items with 2+ active FLAs;
   - every replen PROCESSABLE (blocking needs STARTED);
   - every held stock unit fully reserved, so Move Stock's availability check refuses first.

   Decide whether to seed or skip, and say so.
3. **Snapshot** every row the test may touch:
   ```bash
   .claude/skills/wms-dev-probe/scripts/snapshot.sh save item778 "select id, amount, reservedamount from stockunit where itemdata_id=778629387"
   ```
4. **A control for every negative result.**
   - **"No message sent":** also run a case that **should** send one, on the same path.
   - **"Refused":** read the message. It must name the guard under test, not an earlier one. On 2026-10-15 an
     availability check and "Mixed stock not allowed" both fired before the new guard.
5. **Seed only when needed**, and only in a way you can remove:
   - out-of-band ids (`99000000NN`; that range is empty on dev) and a recognisable number prefix (`REPL-T<ticket>-A`);
   - one transaction (`begin; …; commit;`) so a constraint error rolls the whole seed back;
   - guard every field edit on its old value (`update … where id=X and reservedamount=12`);
   - respect the unique indexes, e.g. `idx_replenishorder_active_item_dest`: one active replen per (item, destination).
6. **Clean up through the product where possible.** Cancel through the API (it releases reservations correctly).
   Check `api.sh`'s exit code **and** the body for `"errors"` before the next step. Then delete the seed rows once
   nothing references them, move containers back and restore edited fields.
7. **Prove it:** `snapshot.sh diff <name>` must print `restored`. Anything else gets reported, not explained away.
   ⚠ It covers **only the rows your SELECT returns.** Side effects outside them aren't undone: `message` / outbox
   rows sent to OMS, `stockrecord` history, burned sequence ids. **List them in the report.**
8. **Record it** on the ticket:
   - each scenario and its result;
   - every deviation (seeded non-FLA destinations; HTTP 200 + `errors` instead of 422);
   - what was not run, and why;
   - the restore proof and the side effects left behind.

## Traps

- **Unqualified subquery columns** bind to the outer query if their own table lacks them. The filter then goes
  always-true with no error (a 64 MB result on 2026-10-15). Alias-qualify every subquery column.
- **Dual-island id space:** a newly created row's id can be *below* the current `max(id)`. Find new rows by
  `created > now() - interval '5 minutes'`, not `id > max`.
- **OMS dev rejects about a third of `STOCK_UPDATE`s** (unknown SKUs, e.g. `teko1`). A `FAILED` status is not, by
  itself, a WMS defect.
- **Business errors from `StockUnitController`** come back as HTTP 200 with `{"errors":[...]}`, so `api.sh`
  exits 0. Check the body.
- **State changes that can't be undone** (finishing a real replen, moving stock to Damaged) need the user's
  explicit go-ahead, even inside an approved test run.
- **Never run these scripts under `bash -x`.** They `set +x` themselves, but a caller's trace of the call line
  could still show arguments.

## Exit

Report one line per scenario (✅, ❌ or ⏸, plus the reason), the restore-proof result, the side effects left on
dev, and where the results were posted.
