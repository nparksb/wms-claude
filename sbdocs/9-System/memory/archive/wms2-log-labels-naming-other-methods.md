---
name: wms2-log-labels-naming-other-methods
description: SBDEV-3186 — 42 log labels named a different method; needs TWO detector spellings; 90% FP so never gate it
metadata: 
  node_type: memory
  type: project
  originSessionId: 41868bc9-fa80-4349-b283-55928699953e
  modified: 2026-09-01T19:14:11.567Z
---

**SBDEV-3186** (PR #266, `c76ceb37`+`62d84878`, branch `chore/wms2-mobile-misattributed-loggers`).
Fixed **42 `LOG.*` labels across 19 files** that named a method other than the enclosing one —
19 in `controller/mobile/` (7 of 11), 22 in `controller/` (11 of 43), 1 in `KeycloakService`.
Grew out of [[sbdev-3016-mobile-controller-cleanups]] Fix 2. Suite 6010/0/0/67.

**A single-token matcher is NOT sufficient, and this is the reusable lesson.** `UserController`
spells method names as words — `"create user"` — so the token `createUser` never appears and a
token-matcher is structurally blind to it. **Five** cross-contaminated labels across its
near-duplicate `importUser`/`createUser`/`updateUser` hid there; a review lane found them, my
detector could not. Run BOTH: exact-token, and space/case/punct-normalized. I claimed "0 remaining"
off the single-token pass and would have shipped that claim.

**Never gate this with a test.** Both matchers repo-wide = **112 candidates, 101 false positives
(~90%)**: short method names collide with ordinary English (`export`, `cancel`, `location`,
`resolve`, `validate`), plus params quoted in the message (`orderBatchId={}`, `printLabel={}`,
`transferLane={}`) and pure normalization artifacts (`"damage transfer, stockUnit"` collapses to
match `transferStock`). Bytecode-constant-pool reading fixes parsing fragility but NOT the noise,
which is semantic. Convention is prose in `v2/wms2-api/CLAUDE.md` beside the handler-name rule.

**The two worst were outside the package the ticket named:**
- `PrinterController.setDefault:193` logged `"delete printer with Id {}"` **at INFO** — a
  set-default announcing a deletion that never happened, in prod-retained logs. `deletePrinter:157`
  legitimately owns that label.
- `UnitLoadController`'s three delete handlers all logged `"start reprintLabel"`.

**`LookupController`'s `search` is a REAL endpoint** (`GET /search/{keyword}`), not a generic verb —
4 of its 5 handlers logged under it, so a grep for that endpoint returned all five handlers.
That cluster is exactly what a "generic word" heuristic throws away.

**The rule that survived review: a label must not carry the name of a method that is not the
enclosing one.** It need NOT lead with the method name — verb-first (`"start orderList"` inside
`orderList()`) and name-free (`"Failed to release…"`) are fine, since neither misdirects a grep.
11 such were left alone deliberately. Name-matching was never the point; not misleading the reader
is — which is why `updateClient` logging `"update client"` still had to change: it re-points a
sysprop's `client_id`, it does not update a `Client`.

**Not a gap in the earlier sweep.** `chore/wms2-misattributed-loggers` = SBDEV-3177 / PR #251,
which fixed logger **field** identity (`LoggerFactory.getLogger(WrongClass.class)`) — a class-level,
reflection-catchable bug. Structurally different; it was never looking at label content. I asserted
"a genuine gap in that chore" and had to retract it.

Open follow-ups: `SystemPropertyController:198` logs `"…finished"` BEFORE the work runs;
`PickingController:89-121` is a fully commented-out dead handler; `PutawayController:54`/`:61` log
byte-identical messages from two different catch blocks; 22 candidates left as the noise floor.
See [[a-guard-fences-the-mechanism-you-aimed-at]], [[verify-script-traps]].
