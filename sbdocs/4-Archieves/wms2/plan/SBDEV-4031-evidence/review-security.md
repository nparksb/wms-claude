---
lane: security-reviewer (Phase 3b)
head: 85daa64b
verdict: PASS (0 Critical / 0 High / 0 Medium, 2 Low, 1 Info)
saved_by: main session, summary of the lane's reply
---
- **L1 (Low, DoS).** `move` locks P and L′ before running its cheap refusal checks, so a looping VIEW-gated user could cause repeated pick 409s. The javadoc already records this as an accepted tension. Two possible fixes:
  - run the plain checks (destination exists, is a flowbin, has no holders at L′, has no in-process order) before the P → L′ prefix, if the lock order allows;
  - otherwise, gateway rate-limiting.
- **L2 (Low, log hygiene).** The R3 WARN logs `e.getMessage()`, which carries SQL text when the exception is a PLFE. Log the class name at WARN and keep the full throwable at DEBUG.
- **I1 (Info).** move and delete are gated on the VIEW function. This predates the change and is the "gate on the screen's function" decision; no action.

**Checks run:**
- All 7 finders are unexported and pinned by FunctionGuardArchTest.
- The JPQL is static and fully bound; there is no client scope to bypass, same as the siblings.
- Lock waits are bounded by the 3000 ms `SET LOCAL` on every transaction, and every lock site is transactional.
- Error bodies are generic.
- Authorization is unchanged, and the retired SDR search reduces surface.
- No secrets or PII in the new log lines.

**Main-session disposition**
- **L1:** reorder `move` so its plain checks run before the P → L′ prefix. Those checks are: destination exists, is a flowbin, has no holders at L′, and no order is in processing. Keep the reorder only if it adds no new lock edge (they are projection reads). Otherwise document it and close.
- **L2:** log the class name at WARN and the full throwable at DEBUG.
