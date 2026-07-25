#!/usr/bin/env bash
# verify-260610-excel-export-localdatetime-unsupported-type.sh
set -u

PROJECT_ROOT="${PROJECT_ROOT:-/home/nampark/dev/wms-claude/v2/wms2-api}"
cd "$PROJECT_ROOT" || { echo "FATAL: PROJECT_ROOT=$PROJECT_ROOT not found"; exit 2; }

PASS=0; FAIL=0; SKIP=0

run() {
    local id=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then printf "  PASS  %-26s  %s\n" "$id" "$desc"; PASS=$((PASS+1))
    else printf "  FAIL  %-26s  %s\n" "$id" "$desc"; FAIL=$((FAIL+1)); fi
}
file_contains()     { grep -qE "$1" "$2"; }
file_not_contains() { ! grep -qE "$1" "$2"; }
# exact integer-count assertion on a single file
file_count_eq() { local pat=$1 file=$2 n=$3; [ "$(grep -cE "$pat" "$file" 2>/dev/null || echo 0)" -eq "$n" ]; }
# Exit-code based: `mvn -q` suppresses the BUILD SUCCESS banner and surefire summary,
# so grepping output false-fails on passing tests (verified 2026-06-10). Surefire fails
# the build (non-zero exit) on any test failure, so the exit code is the reliable signal.
mvn_test_passes() {
    mvn test -Dtest="$1" -DfailIfNoTests=false -q >/dev/null 2>&1
}
# mvn rows SKIP (not FAIL) when maven is unavailable in the verifying shell —
# grep checks remain authoritative; run the T-rows from a shell with mvn on PATH (e.g. SDKMAN:
# export PATH="$HOME/.sdkman/candidates/maven/current/bin:$PATH").
run_mvn() {
    local id=$1 desc=$2; shift 2
    if ! command -v mvn >/dev/null 2>&1; then
        printf "  SKIP  %-26s  %s (mvn not on PATH)\n" "$id" "$desc"; SKIP=$((SKIP+1)); return
    fi
    run "$id" "$desc" "$@"
}

SVC="src/main/java/net/aim_ai/wms/service"
CTL="src/main/java/net/aim_ai/wms/controller"
FES="$SVC/FileExportService.java"
RPTC="$CTL/ReportController.java"
ADVC="$CTL/AdviceController.java"
BOLC="$CTL/BillOfLadingController.java"
CCC="$CTL/CycleCountController.java"

# --- Fix A: FileExportService java.time branches + helper -------------------
check_fixA_localdatetime()   { file_contains 'instanceof LocalDateTime'  "$FES"; }
check_fixA_localdate()       { file_contains 'instanceof LocalDate'      "$FES"; }
check_fixA_instant()         { file_contains 'instanceof Instant'        "$FES"; }   # defensive
check_fixA_offsetdatetime()  { file_contains 'instanceof OffsetDateTime' "$FES"; }   # defensive
check_fixA_helper()          { file_contains 'private void setCellValue'  "$FES"; }
# NEGATIVE: exactly ONE throw site remains (in the helper), not four
check_fixA_single_throw()    { file_count_eq 'throw new UnsupportedOperationException' "$FES" 1; }

# --- Fix B: rename ----------------------------------------------------------
check_fixB_correct_name()    { file_contains 'public void exportContainerRecord\(' "$SVC/ReportService.java"; }
# NEGATIVE: typo eradicated everywhere in src/main + src/test (URL "exportContainerRecord" has the 't', won't match)
check_fixB_typo_gone()       { ! grep -rqE 'exporContainerRecord' src/main src/test; }

# --- Fix C: per-controller catch (Exception) + populated body ---------------
# POSITIVE catch (Exception) per file. ReportController has TWO endpoints → 2 occurrences.
check_fixC_rptc_catch()      { file_count_eq 'catch \(Exception '          "$RPTC" 2; }
check_fixC_advc_catch()      { file_contains 'catch \(Exception '          "$ADVC"; }
check_fixC_bolc_catch()      { file_contains 'catch \(Exception '          "$BOLC"; }
check_fixC_ccc_catch()       { file_contains 'catch \(Exception '          "$CCC"; }
# POSITIVE populated error body per controller (errors.toString(), not errorMap.toString())
check_fixC_rptc_body()       { file_contains 'response\.getWriter\(\)\.write\(errors\.toString\(\)\)' "$RPTC"; }
check_fixC_advc_body()       { file_contains 'response\.getWriter\(\)\.write\(errors\.toString\(\)\)' "$ADVC"; }
check_fixC_bolc_body()       { file_contains 'response\.getWriter\(\)\.write\(errors\.toString\(\)\)' "$BOLC"; }
check_fixC_ccc_body()        { file_contains 'response\.getWriter\(\)\.write\(errors\.toString\(\)\)' "$CCC"; }
# NEGATIVE: empty-map write gone from each export endpoint.
# ReportController is method-scoped: the file has 10 errorMap.toString() occurrences but only the
# two export endpoints are in Fix C's scope (the other 9 non-export endpoints keep the latent
# pattern — see §12). Anchored on method names, not line numbers, so the check survives drift.
report_export_method(){ awk "/public void $1\\(/,/^    \\}\$/" "$RPTC"; }
check_fixC_rptc_no_emptymap(){
  ! report_export_method exportStockUnitRecord | grep -q 'errorMap\.toString()' \
  && ! report_export_method exportContainerRecord | grep -q 'errorMap\.toString()'
}
check_fixC_advc_no_emptymap(){ file_not_contains 'errorMap\.toString\(\)' "$ADVC"; }
check_fixC_bolc_no_emptymap(){ file_not_contains 'errorMap\.toString\(\)' "$BOLC"; }
check_fixC_ccc_no_emptymap() { file_not_contains 'errorMap\.toString\(\)' "$CCC"; }
# NEGATIVE: no hard-coded timezone string introduced in controllers
check_fixC_no_hardcoded_tz() { ! grep -rqE 'America/Los_Angeles|ZoneId\.systemDefault' "$CTL"; }

echo
echo "verify-260610-excel-export — acceptance checks"
echo "  PROJECT_ROOT=$PROJECT_ROOT"
echo

run A-ldt   "Fix A: LocalDateTime branch present"        check_fixA_localdatetime
run A-ld    "Fix A: LocalDate branch present"            check_fixA_localdate
run A-inst  "Fix A: Instant branch present (defensive)"  check_fixA_instant
run A-odt   "Fix A: OffsetDateTime branch (defensive)"   check_fixA_offsetdatetime
run A-help  "Fix A: setCellValue helper extracted"       check_fixA_helper
run A-throw "Fix A: exactly 1 throw site (was 4)"        check_fixA_single_throw
echo
run B-name  "Fix B: exportContainerRecord present"       check_fixB_correct_name
run B-typo  "Fix B: typo eradicated (src/main+src/test)" check_fixB_typo_gone
echo
run C-rptc-c "Fix C: ReportController 2x catch(Exception)" check_fixC_rptc_catch
run C-advc-c "Fix C: AdviceController catch(Exception)"    check_fixC_advc_catch
run C-bolc-c "Fix C: BillOfLadingController catch(Exception)" check_fixC_bolc_catch
run C-ccc-c  "Fix C: CycleCountController catch(Exception)" check_fixC_ccc_catch
run C-rptc-b "Fix C: ReportController writes errors.toString()" check_fixC_rptc_body
run C-advc-b "Fix C: AdviceController writes errors.toString()" check_fixC_advc_body
run C-bolc-b "Fix C: BillOfLadingController writes errors.toString()" check_fixC_bolc_body
run C-ccc-b  "Fix C: CycleCountController writes errors.toString()" check_fixC_ccc_body
run C-rptc-n "Fix C: ReportController no errorMap.toString()"  check_fixC_rptc_no_emptymap
run C-advc-n "Fix C: AdviceController no errorMap.toString()"  check_fixC_advc_no_emptymap
run C-bolc-n "Fix C: BillOfLadingController no errorMap.toString()" check_fixC_bolc_no_emptymap
run C-ccc-n  "Fix C: CycleCountController no errorMap.toString()"   check_fixC_ccc_no_emptymap
run C-tz     "Fix C: no hard-coded timezone in controllers"   check_fixC_no_hardcoded_tz
echo
run_mvn T-fes   "FileExportServiceUnitTest passes"  mvn_test_passes FileExportServiceUnitTest
run_mvn T-rptc  "ReportControllerUnitTest passes"   mvn_test_passes ReportControllerUnitTest
run_mvn T-rpts  "ReportServiceUnitTest passes"      mvn_test_passes ReportServiceUnitTest

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
