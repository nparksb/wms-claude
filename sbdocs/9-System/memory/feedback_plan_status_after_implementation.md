---
name: Always update plan status at end of implementation
description: After git-master commits land for a WMS bugfix/feature plan, revisit the plan doc and replace placeholder SHAs / draft status / pending markers with concrete data BEFORE declaring the work complete.
type: feedback
originSessionId: 69e0636d-9b97-4601-9357-3930aa5fde93
---
After dispatching `git-master` and confirming commits land on a `tasks/SBDEV-####` branch, do a sweep of the plan file at `sbdocs/1-Projects/wms{1,2}/plan/SBDEV-####-*.md` BEFORE declaring the implementation phase complete. Replace every placeholder with concrete data:

1. **Frontmatter `status`**: `"draft"` → `"implemented"` (or `"merged"` once merged).
2. **Frontmatter `updated`**: bump to today's date.
3. **Body `**Status:**` header line**: same flip as frontmatter, plus add PR URL.
4. **Implementation Status section** (`§10` / `§13.4` / `§14` depending on plan template version):
   - Replace `_pending commit_`, `_(set by git-master)_`, `commit-pending` placeholders with actual SHAs from `git log --oneline -N`.
   - Add commit map (CN — subject — short SHA).
   - Record `mvn test` / `mvn verify` results with counts.
   - Record final verify-script line: `Result: N pass, 0 fail, M skip`.
   - Record any deferred follow-ups from code-reviewer minors.
5. **PR URL**: link from the plan body for traceability.

**Why:** In May 2026 I shipped 4 plans (SBDEV-2216 / 2217 / 2218 / 2219) where the executor populated the Implementation Status table with `_pending commit_` placeholders BEFORE git-master ran, and nobody resolved them after. The user had to explicitly ask "did you update the plans?" — meaning the audit trail in the plan docs was broken. Plan docs are the audit trail; if they still say `_pending` after the work has shipped, the trail is broken and someone reviewing the archive can't easily map plan → commits.

**How to apply:** This is the LAST step of any plan implementation flow — strictly AFTER git-master returns SHAs, BEFORE I tell the user "implementation complete" or move to push/PR. Trigger phrases that should fire this rule: "git-master returned", "commits landed", "pushing now", "PR created". The wms-bugfix-plan skill's "Post-implementation gate" section already prescribes step 3 of this list, but I treated it as advisory; it's now load-bearing.

If git-master returns 4 SHAs and I haven't yet edited the plan doc, I am not done. The trigger is "git-master successful" not "PR opened" — update the plan BEFORE pushing if possible (so the PR description can link to the same plan with concrete SHAs).
