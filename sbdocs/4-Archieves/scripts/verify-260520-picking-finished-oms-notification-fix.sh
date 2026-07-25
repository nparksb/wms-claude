#!/usr/bin/env bash
# verify-260520-picking-finished-oms-notification-fix.sh
#
# Verifies acceptance criteria for:
#   "Fix: PICKING_FINISHED OMS Notification Silently Dropped (Double afterCommit)"
#   Plan: sbdocs/1-Projects/wms2/plan/260520-picking-finished-oms-notification-fix.md
#
# Usage:
#   bash sbdocs/9-System/scripts/verify-260520-picking-finished-oms-notification-fix.sh
#   bash sbdocs/9-System/scripts/verify-260520-picking-finished-oms-notification-fix.sh --pr-a-only
#   bash sbdocs/9-System/scripts/verify-260520-picking-finished-oms-notification-fix.sh --skip-compile
#
# Checks:
#   PR-A: OmsNotificationService guard (AC #1, #2)
#   PR-B: PickingorderBusinessService outbox enqueue (AC #7, #8, #11)
#   PR-B: ManageOrderService helpers retained + deprecated (AC #12)
#   Compile gate (AC #4 pre-condition)
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WMS2_SRC="$REPO_ROOT/v2/wms2-api/src/main/java/net/aim_ai/wms"

PASS=0
FAIL=0
PR_A_ONLY=false
SKIP_COMPILE=false

for arg in "$@"; do
  case "$arg" in
    --pr-a-only)   PR_A_ONLY=true ;;
    --skip-compile) SKIP_COMPILE=true ;;
  esac
done

pass() { echo "  ✅ PASS: $1"; ((PASS++)) || true; }
fail() { echo "  ❌ FAIL: $1"; ((FAIL++)) || true; }
info() { echo ""; echo "==> $1"; }

# ---------------------------------------------------------------------------
# PR-A checks
# ---------------------------------------------------------------------------
info "PR-A: OmsNotificationService guard (AC #1, #2)"

OMS_NOTIF="$WMS2_SRC/service/OmsNotificationService.java"

if [[ -f "$OMS_NOTIF" ]]; then
  # AC #1 / #2: isActualTransactionActive() must be present
  if grep -q "isActualTransactionActive" "$OMS_NOTIF"; then
    pass "OmsNotificationService uses isActualTransactionActive() guard"
  else
    fail "OmsNotificationService does NOT contain isActualTransactionActive() — PR-A not applied"
  fi

  # AC #1: Guard must combine both conditions (&&)
  # The condition may span two lines (e.g. isSynchronizationActive() on line N,
  # && isActualTransactionActive() on line N+1), so use grep -A1 to look within
  # the next line as well as the same line.
  if grep -A1 "isSynchronizationActive()" "$OMS_NOTIF" | grep -q "isActualTransactionActive"; then
    pass "Guard combines isSynchronizationActive() && isActualTransactionActive() (same or adjacent line)"
  else
    fail "Guard does not combine both conditions with && — may still produce 3-branch logic"
  fi
else
  fail "OmsNotificationService.java not found at expected path"
fi

if $PR_A_ONLY; then
  echo ""
  echo "-- PR-A only mode; skipping PR-B checks --"
else

# ---------------------------------------------------------------------------
# PR-B checks — PickingorderBusinessService
# ---------------------------------------------------------------------------
info "PR-B: PickingorderBusinessService (AC #7, #8, #11)"

POBS="$WMS2_SRC/service/PickingorderBusinessService.java"

if [[ -f "$POBS" ]]; then
  # AC #7 / #11: zero registerSynchronization calls in non-comment code
  # Strip single-line // comments then count matches
  REGSYNC_COUNT=$(sed 's|//.*||' "$POBS" | grep -c "registerSynchronization" || true)
  if [[ "$REGSYNC_COUNT" -eq 0 ]]; then
    pass "PickingorderBusinessService has 0 registerSynchronization calls (non-comment code)"
  else
    fail "PickingorderBusinessService still has $REGSYNC_COUNT registerSynchronization call(s) — double-afterCommit pattern not removed"
  fi

  # AC #8: ordering — buildPickedPayloadJson must appear before setPickingconfirmationsent in finishPickingOrder
  BUILD_LINE=$(grep -n "buildPickedPayloadJson" "$POBS" | head -1 | cut -d: -f1 || echo "")
  FLAG_LINE=$(grep -n "setPickingconfirmationsent(true)" "$POBS" | head -1 | cut -d: -f1 || echo "")
  if [[ -n "$BUILD_LINE" && -n "$FLAG_LINE" ]]; then
    if [[ "$BUILD_LINE" -lt "$FLAG_LINE" ]]; then
      pass "buildPickedPayloadJson (line $BUILD_LINE) appears before setPickingconfirmationsent(true) (line $FLAG_LINE)"
    else
      fail "setPickingconfirmationsent(true) (line $FLAG_LINE) appears BEFORE buildPickedPayloadJson (line $BUILD_LINE) — ordering violated (AC #8)"
    fi
  elif [[ -z "$BUILD_LINE" ]]; then
    fail "buildPickedPayloadJson not found in PickingorderBusinessService — Fix A not applied"
  else
    fail "setPickingconfirmationsent not found in PickingorderBusinessService"
  fi

  # Check outboxService.enqueue is present (Fix A)
  if grep -q "outboxService.enqueue" "$POBS"; then
    pass "outboxService.enqueue present in PickingorderBusinessService (Fix A/C applied)"
  else
    fail "outboxService.enqueue NOT found in PickingorderBusinessService — PR-B Fix A not applied"
  fi

  # Check reenqueuePickingFinishedIfMissing exists (Fix B method)
  if grep -q "reenqueuePickingFinishedIfMissing" "$POBS"; then
    pass "reenqueuePickingFinishedIfMissing method present in PickingorderBusinessService"
  else
    fail "reenqueuePickingFinishedIfMissing NOT found — Fix B method not added"
  fi
else
  fail "PickingorderBusinessService.java not found"
fi

# ---------------------------------------------------------------------------
# PR-B checks — ManageOrderService (AC #12)
# ---------------------------------------------------------------------------
info "PR-B: ManageOrderService payload helpers (AC #12)"

MOS="$WMS2_SRC/service/ManageOrderService.java"

if [[ -f "$MOS" ]]; then
  # AC #12: both public methods retained
  if grep -q "public.*customerOrderPicked" "$MOS"; then
    pass "ManageOrderService.customerOrderPicked retained (public)"
  else
    fail "ManageOrderService.customerOrderPicked NOT found — CustomerorderBatchService caller broken"
  fi

  if grep -q "public.*customerOrderPickingStarted" "$MOS"; then
    pass "ManageOrderService.customerOrderPickingStarted retained (public)"
  else
    fail "ManageOrderService.customerOrderPickingStarted NOT found — CustomerorderBatchService caller broken"
  fi

  # AC #12: methods marked @Deprecated
  DEPRECATED_COUNT=$(grep -c "@Deprecated" "$MOS" || true)
  if [[ "$DEPRECATED_COUNT" -ge 2 ]]; then
    pass "ManageOrderService has ≥2 @Deprecated annotations (public methods marked deprecated)"
  else
    fail "ManageOrderService has only $DEPRECATED_COUNT @Deprecated annotation(s) — expected ≥2"
  fi

  # New helpers present
  if grep -q "buildPickedPayloadJson" "$MOS"; then
    pass "ManageOrderService.buildPickedPayloadJson helper present"
  else
    fail "ManageOrderService.buildPickedPayloadJson NOT found — Fix A helper not extracted"
  fi

  if grep -q "buildPickingStartedPayloadJson" "$MOS"; then
    pass "ManageOrderService.buildPickingStartedPayloadJson helper present"
  else
    fail "ManageOrderService.buildPickingStartedPayloadJson NOT found — Fix C helper not extracted"
  fi
else
  fail "ManageOrderService.java not found"
fi

# ---------------------------------------------------------------------------
# PR-B checks — MobilePickingService (Fix B safety net)
# ---------------------------------------------------------------------------
info "PR-B: MobilePickingService safety-net (Fix B)"

MPS="$WMS2_SRC/service/mobile/MobilePickingService.java"

if [[ -f "$MPS" ]]; then
  if grep -q "reenqueuePickingFinishedIfMissing" "$MPS"; then
    pass "MobilePickingService calls reenqueuePickingFinishedIfMissing in Case 1"
  else
    fail "MobilePickingService does NOT call reenqueuePickingFinishedIfMissing — Fix B not applied"
  fi
else
  fail "MobilePickingService.java not found"
fi

# ---------------------------------------------------------------------------
# Fix-A checks — NO_TOTE_SENTINEL (plan 260521)
# ---------------------------------------------------------------------------
info "Fix-A: NO_TOTE_SENTINEL constant + ManageOrderService sentinel branch (260521 AC-1/2)"

WMSC="$WMS2_SRC/service/WmsConstants.java"
MOS2="$WMS2_SRC/service/ManageOrderService.java"
WMS2_TEST="$REPO_ROOT/v2/wms2-api/src/test/java/net/aim_ai/wms"
MANAGE_TEST="$WMS2_TEST/unit/service/ManageOrderServiceUnitTest.java"

# A1 — constant declared in WmsConstants
if grep -q 'NO_TOTE_SENTINEL' "$WMSC" 2>/dev/null; then
  pass "A1: WmsConstants.NO_TOTE_SENTINEL constant declared"
else
  fail "A1: WmsConstants.NO_TOTE_SENTINEL NOT found in WmsConstants.java"
fi

# A2 — sentinel string is "NO_TOTE"
if grep -q '"NO_TOTE"' "$WMSC" 2>/dev/null; then
  pass "A2: NO_TOTE_SENTINEL value is \"NO_TOTE\" in WmsConstants.java"
else
  fail "A2: \"NO_TOTE\" string value NOT found in WmsConstants.java"
fi

# A3 — ManageOrderService references the constant (not a magic string)
if grep -q 'NO_TOTE_SENTINEL' "$MOS2" 2>/dev/null; then
  pass "A3: ManageOrderService references WmsConstants.NO_TOTE_SENTINEL (no magic string)"
else
  fail "A3: ManageOrderService does NOT reference NO_TOTE_SENTINEL"
fi

# A4 — setToteLabel(WmsConstants.NO_TOTE_SENTINEL) call exists in the else branch
if grep -q 'setToteLabel(WmsConstants.NO_TOTE_SENTINEL)' "$MOS2" 2>/dev/null; then
  pass "A4: setToteLabel(WmsConstants.NO_TOTE_SENTINEL) call present in ManageOrderService"
else
  fail "A4: setToteLabel(WmsConstants.NO_TOTE_SENTINEL) NOT found in ManageOrderService"
fi

# A5 — new no-tote sentinel test present
if grep -q 'buildPickedPayloadJson_nonClubNoTote_emitsSentinel' "$MANAGE_TEST" 2>/dev/null; then
  pass "A5: ManageOrderServiceUnitTest contains buildPickedPayloadJson_nonClubNoTote_emitsSentinel test"
else
  fail "A5: buildPickedPayloadJson_nonClubNoTote_emitsSentinel NOT found in ManageOrderServiceUnitTest"
fi

# A6a — CLUB regression test present
if grep -q 'buildPickedPayloadJson_clubOrder_producesUuidToteLabel' "$MANAGE_TEST" 2>/dev/null; then
  pass "A6a: ManageOrderServiceUnitTest contains CLUB regression test"
else
  fail "A6a: buildPickedPayloadJson_clubOrder_producesUuidToteLabel NOT found in ManageOrderServiceUnitTest"
fi

# A6b — tote-assigned regression test present
if grep -q 'buildPickedPayloadJson_nonClubWithTote_usesToteLabel' "$MANAGE_TEST" 2>/dev/null; then
  pass "A6b: ManageOrderServiceUnitTest contains tote-assigned regression test"
else
  fail "A6b: buildPickedPayloadJson_nonClubWithTote_usesToteLabel NOT found in ManageOrderServiceUnitTest"
fi

# ---------------------------------------------------------------------------
# Fix-B checks — OutboxDispatchService service-log (plan 260521)
# ---------------------------------------------------------------------------
info "Fix-B: OutboxDispatchService MessageService injection + writeServiceLog (260521 AC-5/6/7)"

ODS="$WMS2_SRC/service/job/OutboxDispatchService.java"
DISPATCH_TEST="$WMS2_TEST/unit/service/job/OutboxDispatchServiceUnitTest.java"

# B1 — MessageService field injected
if grep -q 'MessageService messageService' "$ODS" 2>/dev/null; then
  pass "B1: MessageService field declared in OutboxDispatchService"
else
  fail "B1: MessageService field NOT found in OutboxDispatchService"
fi

# B2 — SyspropService field injected
if grep -q 'SyspropService syspropService' "$ODS" 2>/dev/null; then
  pass "B2: SyspropService field declared in OutboxDispatchService"
else
  fail "B2: SyspropService field NOT found in OutboxDispatchService"
fi

# B3 — writeServiceLog called at ≥4 call sites (pattern matches call sites only, not the definition)
WSLCALLS=$(grep -c 'writeServiceLog(msg,' "$ODS" 2>/dev/null || true)
if [[ "$WSLCALLS" -ge 4 ]]; then
  pass "B3: writeServiceLog(msg, ...) called at ≥4 sites in OutboxDispatchService (found $WSLCALLS)"
else
  fail "B3: writeServiceLog(msg, ...) has only $WSLCALLS call site(s) in OutboxDispatchService — expected ≥4"
fi

# B4 — BusinessException caught and swallowed in writeServiceLog
if grep -q 'catch.*BusinessException' "$ODS" 2>/dev/null; then
  pass "B4: BusinessException catch present in OutboxDispatchService"
else
  fail "B4: BusinessException catch NOT found in OutboxDispatchService"
fi

# B5 — message_log.failed counter present in ≥2 locations (both catch blocks)
COUNTER_COUNT=$(grep -c 'message_log.failed' "$ODS" 2>/dev/null || true)
if [[ "$COUNTER_COUNT" -ge 2 ]]; then
  pass "B5: wms2.outbox.message_log.failed counter in ≥2 locations (found $COUNTER_COUNT)"
else
  fail "B5: wms2.outbox.message_log.failed counter found only $COUNTER_COUNT time(s) — expected ≥2"
fi

# B6 — OutboxDispatchServiceUnitTest exists with 2xx success test
if grep -q 'createsMessageLogWithSentStatus\|createMessage.*SENT\|MessageStatus.SENT' "$DISPATCH_TEST" 2>/dev/null; then
  pass "B6: OutboxDispatchServiceUnitTest present and contains SENT-status assertion"
else
  fail "B6: OutboxDispatchServiceUnitTest NOT found or missing SENT-status assertion"
fi

fi  # end PR_A_ONLY block

# ---------------------------------------------------------------------------
# Compile gate
# ---------------------------------------------------------------------------
if ! $SKIP_COMPILE; then
  info "Compile gate"
  # Resolve mvn: honour PATH first, then sdkman current symlink.
  MVN_BIN="$(command -v mvn 2>/dev/null || echo "${SDKMAN_DIR:-$HOME/.sdkman}/candidates/maven/current/bin/mvn")"

  WMS2_DIR="$REPO_ROOT/v2/wms2-api"
  if [[ -f "$WMS2_DIR/pom.xml" ]]; then
    if [[ ! -x "$MVN_BIN" ]]; then
      echo "  ⚠️  SKIP: mvn not found on PATH or via sdkman; use --skip-compile or add mvn to PATH"
    else
      echo "  Running: cd v2/wms2-api && $MVN_BIN -q -DskipTests compile"
      if (cd "$WMS2_DIR" && "$MVN_BIN" -q -DskipTests compile 2>&1); then
        pass "mvn compile succeeded"
      else
        fail "mvn compile FAILED — check output above"
      fi
    fi
  else
    echo "  ⚠️  SKIP: v2/wms2-api/pom.xml not found; run from repo root or use --skip-compile"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "=========================================="
if [[ $FAIL -gt 0 ]]; then
  echo "  ❌ Verification FAILED — see failures above"
  exit 1
else
  echo "  ✅ All checks passed"
  exit 0
fi
