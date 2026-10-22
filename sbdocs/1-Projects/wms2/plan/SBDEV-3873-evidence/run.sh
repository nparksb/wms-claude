#!/usr/bin/env bash
# Hand-mutant harness for SBDEV-3873 PR 1. Applies one mutant, runs the gate classes, records the failing tests
# and messages, restores from git and proves the tree is clean before the next mutant.
set -uo pipefail
WT=/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3873
D=/tmp/claude-1000/-home-nampark-dev-wms-claude/106c745f-922c-4987-90b6-23ad90878c48/scratchpad/mut
export JAVA_HOME="$HOME/.sdkman/candidates/java/21.0.11-ms" PATH="$HOME/.sdkman/candidates/java/21.0.11-ms/bin:$HOME/.sdkman/candidates/maven/current/bin:$PATH"
cd "$WT" || exit 2
[ -z "$(git status --porcelain)" ] || { echo "tree dirty before start"; exit 2; }
TESTS='Sbdev3017TrancheGateContextTest,AdviceSetCommentContextTest,SdrCommentOnlyWritableContextTest,SdrPatchFieldFenceContextTest,AdviceServiceUnitTest'
for m in ${MUTANTS:-m1 m1b m2 m3 m4 m4b m5 m5b m6 m6b m7 m8 m9 m10}; do
  python3 -I - "$m" <<'PY' || { echo "$m: APPLY FAILED"; git checkout -q -- .; continue; }
import sys; sys.path.insert(0,'/tmp/claude-1000/-home-nampark-dev-wms-claude/106c745f-922c-4987-90b6-23ad90878c48/scratchpad/mut')
from mutants import M
for f,a,b in M[sys.argv[1]]:
    s=open(f).read(); n=s.count(a)
    if n!=1: sys.exit(f"{f}: anchor count {n}")
    open(f,'w').write(s.replace(a,b))
PY
  [ -n "$(git status --porcelain)" ] || { echo "$m: no diff after apply"; continue; }
  rm -rf target/surefire-reports
  mvn -o -q test -Dtest="$TESTS" > "$D/$m.log" 2>&1; rc=$?
  ran=$(grep -h "Tests run:" target/surefire-reports/*.txt 2>/dev/null | awk -F'[ ,]+' '{s+=$3} END{print s+0}')
  fails=$(grep -hE "^\[ERROR\] +[A-Za-z$]+.*:[0-9]+ " "$D/$m.log" | sed -E 's/^\[ERROR\] +//' | cut -c1-200)
  comp=$(grep -c "COMPILATION ERROR" "$D/$m.log")
  echo "=== $m rc=$rc ran=$ran compileErr=$comp"; echo "${fails:-  (no failing tests: SURVIVED)}" | sed 's/^/  /'
  git checkout -q -- .
  [ -z "$(git status --porcelain)" ] || { echo "restore failed after $m"; exit 2; }
done
