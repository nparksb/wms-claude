# SBDEV-3474 — architect consult: where the outbound-label guard goes

Worktree HEAD `67acb39d` (origin/develop). Read-only consult; no tests run.

## Recommendation: Option C = A's placement, with the guard as its own bean and mocked in the ITs

1. Extract the pure string check from `MobileTruckLoadingService.checkPallet` (`MobileTruckLoadingService.java:86-99`)
   into a new `@Component OutboundPalletLabelGuard` (service/mobile) with one method
   `void requireOutboundPalletLabel(String label) throws BusinessException`. It reads the two sysprops, applies the
   configured-only rule (below) and does **no** repository access.
2. `checkPallet` delegates to it, then goes on to `unitloadRepository.findByLabelid` (`:101`) as it does now.
3. `MobileTruckLoadingService.scanGate` (`:166`) calls the guard first, **before and outside** the
   `try { truckLoadingWriteService.scanGate(...) }` at `:171-175`. The facade is non-transactional, so a rejection
   opens no transaction, touches no entity and takes no lock. The SBDEV-3244 first-touch rule in the write service
   is untouched.
4. ITs: add `@MockitoBean OutboundPalletLabelGuard` (a no-op by default) to `AbstractTruckLoadingPgFixture` (which
   already carries `@MockitoBean ManageOrderService`, `:127`) and to `MobileTruckLoadingRollbackIT` (which already
   carries two, `:142`, `:145`). Both already have their own context key, so this changes the key but adds **no**
   extra Spring context. Labels, D0 branch, the PREFIX LIKE cleanup and the fixture javadoc all stay as they are.
5. Regression tests (unit, `MobileTruckLoadingServiceUnitTest`): a non-outbound label means the guard throws
   `noValidString` and `verifyNoInteractions(truckLoadingWriteService)`; an outbound label means `InOrder` guard, then
   write service. The write service is the only component that takes locks (the facade does no repository work
   before it), so "never reached" is the lock-free proof. The dev xmax measurement stays as the DB evidence.

## Why this placement, not A-as-stated or B
- **Invariant, not instance.** "Only outbound pallets go on a truck" belongs to the operation, not to the HTTP
  transport. The facade already owns the other things that must sit outside the transaction: lock-contention
  translation (`:173-174`, `lockContention` `:251`) and the OMS notify (`notifyOms` `:206`). Putting an admission
  check in the controller would be the only business rule in `TruckLoadingController` (`:112-133` is pure
  catch-and-wrap).
- **A-as-stated is costlier than it looks.** An outbound-shaped label needs `WC_\d{16}` (the only alternative in
  the V2.2.00 seed with room for a run key; `OUT-\d{6}`/`BOUT-\d{6}` do not have it, per the fixture javadoc
  `:86-89`). But `_` is a LIKE wildcard and `WC_` is a real production prefix, so the cross-build PREFIX sweep
  would need redesigning. A match also moves every scan onto D0's purge branch
  (`MobileMoveUnitloadService.java:563-571`). In RaceIT that may mean the second scanner purges the first
  scanner's committed position (not verified). Mocking the guard avoids all of that. The ITs test the write
  path, not label policy.
- **B leaves the invariant only at the edge.** It works today (the only src/main caller is
  `TruckLoadingController.java:120`), but whether it holds depends on nobody adding a caller. Under C, B's
  bypass does not exist.

## Risks / costs
- The mocked guard means no IT exercises the real guard. That is acceptable: its logic is pure, and it gets its
  own unit test (pattern hit, printing-pattern hit, neither, only-one-configured, null/empty label).
- `StringConverter.convertFormatToRegex` (`StringConverter.java:28-38`) throws an unchecked exception on a
  malformed printing format (`split[1]` / `substring`). Outside the transaction that gives a 500 but no lock.
  Behaviour is unchanged from checkPallet, and out of scope for this ticket.
- `MobileTruckLoadingWriteService.scanGate` (`:242`) is still a public bean method that skips the guard. Its
  javadoc (`:147-149`) already names this gap. Update that paragraph to say the guard now sits in the facade.

## Rail
- Under C, pin **"only `MobileTruckLoadingService` calls `MobileTruckLoadingWriteService.scanGate`"** with one
  ArchUnit rule, next to the existing `unit/config/*ArchTest`s. It costs about 15 lines and closes the one
  remaining bypass. It does have ArchUnit's known call-site blind spots (method refs, reflection, and callers
  in src/test, which must be excluded). That is still worth it here, because the failure it prevents is silent
  (a 336-row lock storm with no error until PHASE C).
- Under B the equivalent rail ("only the controller calls the facade's scanGate") would be **mandatory**, not
  defence in depth, because it would be the only thing protecting the invariant. That is a second reason to
  prefer C.

## Sub-question: what to do when NEITHER sysprop is configured
**Fail closed.** Throw a `BusinessException` so the handheld gets the controller's usual 200 + `errors` shape,
and also `LOG.warn` naming both keys (copy D0's message style, `MobileMoveUnitloadService.java:553-557`).
- D0 fails open because its action is a destructive **purge**, so skipping it is the safe direction there.
  This guard is an **admission** check, so the safe direction is to reject. The two rules differ because the
  actions differ, and both are the safe choice for their action.
- Take D0's **configured-only matching** as well (`:561-563`). Today checkPallet NPEs when only the printing
  pattern is set (`palletLabel.matches(null)`, `:96`). The guard should instead match whichever pattern is
  configured, and reject only when neither is configured or neither matches.
- Consistency: a tenant with neither pattern configured already cannot pass `checkPallet` (it NPEs, so a 500).
  Failing closed therefore blocks nobody who works today, and it turns an opaque 500 into a readable message.
- Do not throw an unchecked config error: the controller catches only `BusinessException`/`FacadeException`
  (`TruckLoadingController.java:121-125`), so it would surface as a 500. Reuse `noValidString` to avoid a new
  bundle key. Check first that `StringConverter.describeExpectedFormat` accepts null/"" arguments (its javadoc
  says the varargs tail tolerates absence; confirm the null head too).
