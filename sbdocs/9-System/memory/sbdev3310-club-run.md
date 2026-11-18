---
name: sbdev3310-club-run
description: SBDEV-3310 real state — #351 in production since Sept despite the "on dev" status; #623/#625 (V2.2.48) unreleased; rest of scope moved to 4007
metadata:
  type: project
---

SBDEV-3310 (ClickUp `868m3z08h`) as of 2026-11-07. **The ClickUp status `on dev` does not mean "not in production".**

- **#351** (club OMS chunking, merge `414c2892`, V2.2.29 + V2.2.30) has been **in production** since mid-September: it's on `main` and first shipped in `v0.0.26`. V2.2.29 was applied on hydra PRD 2026-09-15 and on c1wh/nywh-shipitez PRD 2026-09-18. It is inert, because chunk size stays 1 by decision ([[club-oms-chunking-rollout-dropped]]).
- **#623** (comments plus V2.2.48 "Keep at 1" sysprop description, `ec37eb13`) and **#625** (test-only, `05f962b3`) are on develop/dev only and in no release tag. That is why the status stays `on dev`: move it only after V2.2.48 ships, and the steps past `on dev` belong to QA/DevOps.
- **Everything else** in the original §6 scope moved to SBDEV-4007 (`868mrmhn7`) on 2026-11-04. Step 2 (the super-linearity cause) is moot: v2 did 1,200 orders in 57.8 s.
- **Description:** on 2026-11-07 I prepended a Status block and a "superseded" list to the description (§1 "never observed running", §2 the 45–70 min quadratic estimate, §6 scope, §7 exposure). The original 2026-09-10 text is kept below them, so read the top block first.

**Why:** a status-only reading says the code hasn't shipped, and the original description says v2 never ran clubs. Both are wrong.
**How to apply:** when asked about 3310, check the release tags and PRD `flyway_schema_history`, not the ClickUp status. Close or advance it once V2.2.48 reaches a release cut.
