---
head: ce9f4d67ab75077b81e38bd4eec7f4f5c9c87735
reviewer: code-reviewer (independent, read-only)
scope: ce9f4d67 only, answers R3-2
verdict: APPROVE
---
# SBDEV-3865 review round 4 (ce9f4d67)

Files reviewed: 2 (MobilePickingService.java:1396, MobilePickingServiceUnitTest.java:2752).
Severity count: CRITICAL 0, HIGH 0, MEDIUM 0, LOW 0. One INFO note below.

## R3-2 resolved
The throw at `MobilePickingService.java:1396` is now `new BusinessException("No picking order given")`. It no longer interpolates `postedPosition.getNumber()`, so "for pick null" cannot be rendered. R3-2 offered "fix or accept"; this takes the simplest form of the fix. The pick number added no information on this branch, because the refusal fires before any lookup and the caller already knows what it posted. No spec drift. Stage 1 passes.

## BusinessException message resolution (checked in source)
- `BusinessException(String)` calls `super(resolveMessage(default, "placeholder", message))` and stores `key="placeholder"`, `parameter={message}`. `getMessage()` re-resolves through the `messages` bundle.
- It does resolve a key, but the key is the constant `placeholder`, and the text is never looked up as a key.
- `messages.properties:10` and `messages_en_US.properties:338` both define `placeholder=%1$s`, so the message is returned verbatim.
- A message containing `%` is safe. The format is applied to the pattern `%1$s`, not to the argument.
- A future bundle entry named "No picking order given" cannot change the text, because the text is only ever the argument. The only way to change it is to edit the `placeholder` entry itself. That would break every message built through the single-String constructor, and this assertion would go red along with many others.
- If the bundle were missing, `concatenateKeyAndParameter` would yield `placeholder, 'No picking order given'` and the test would go red. This is acceptable: it is a loud signal.

## Test assertion
`.hasMessage("No picking order given")` at `MobilePickingServiceUnitTest.java:2752` is an exact equality check (AssertJ `hasMessage`), unlike the former `hasMessageContaining`. It goes red on any regression: reintroducing the "for pick ..." suffix, a prefix change, or a message swap. It also still pins `never()` on `findByIdForUpdate`. The old test had one weakness: its `containing` check would have stayed green on a longer message. That is fixed.

## Other asserters of the old text
`grep -rn "No picking order given"` over the worktree `src/` (main and test), `v2/wms2-api/src` and `v2/wms2-mobile-ui` (excluding node_modules and .nuxt) returns only the two edited lines. There is no other test, IT, resource bundle entry or mobile-UI string match, and no stale `"for pick"` consumer. The mobile UI renders the ProblemDetail text generically, so there is no coupling to the wording.

## INFO (not a defect)
The sibling check mentioned in round 3 (`rapidPickingScanSource:1408`, the same refusal shape) was not part of this commit. Worth a one-line grep by the author to confirm it carries no `+ getNumber()` interpolation. I did not find one in the diff's context, but I did not audit that line.

## Positive observations
- A minimal one-line fix paired with a strictly tighter assertion.
- The commit message names the finding ID and states the behavior change.

## Recommendation
APPROVE
