#!/usr/bin/env bash
# portability-check.sh: do the repo's shell scripts run on BOTH dev machines (macOS and Linux)?
#
# usage: .claude/scripts/portability-check.sh            (from anywhere inside owl)
#        /bin/bash .claude/scripts/portability-check.sh  (on the Mac: grades under bash 3.2, the oldest)
#
# Run it on each machine after editing any .claude/ or sbdocs/9-System/scripts/ shell script. It is the
# only thing that executes the GNU branches of the dual-path helpers on Linux, and the BSD ones on the Mac.
#
# Three checks, exit 1 if any fails:
#   1. every script parses under the running bash (run under /bin/bash on the Mac to grade 3.2);
#   2. no Linux-only / bash-4-only idiom outside the dual-path helpers -- with a POSITIVE CONTROL: a planted
#      file carrying every banned idiom must be caught, or a broken scanner would report a clean zero;
#   3. the helpers return known answers on this platform, and their copies are byte-identical.
#
# The rule it enforces: write for bash 3.2 + POSIX tools; where GNU and BSD genuinely differ, use one of the
# helpers (epoch_of, mode_of, main_root) that tries both and returns NOTHING when neither works, so callers
# fail closed. History: 2026-10-23/24, scripts written on the Linux box failed on the Mac, two of them OPEN.
set -uo pipefail
export LC_ALL=C
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd -P) || exit 2
OWL=$(CDPATH= cd -- "$SELF_DIR/../.." >/dev/null && pwd -P) || exit 2
[ -f "$OWL/.claude/scripts/ticket-lease.sh" ] || { echo "cannot find owl from $SELF_DIR" >&2; exit 2; }
TMP=$(mktemp -d) || exit 2; trap 'rm -rf "$TMP"' EXIT INT TERM
FAILS=0
ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1  (got [$2], want [$3])"; fi; }

FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(
  { ls "$OWL"/.claude/scripts/*.sh "$OWL"/.claude/skills/*/scripts/*.sh "$OWL"/sbdocs/9-System/scripts/*.sh 2>/dev/null; } | sort)
echo "portability-check: $(uname -s) $(uname -m), bash $BASH_VERSION, ${#FILES[@]} scripts"

# ── 1. parse ─────────────────────────────────────────────────────────────────────────────────────
echo "1. parse under bash $BASH_VERSION"
n=0; for f in "${FILES[@]}"; do "$BASH" -n "$f" 2>"$TMP/err" || { bad "parse: ${f#$OWL/}: $(head -1 "$TMP/err")"; n=1; }; done
[ $n -eq 0 ] && ok "all ${#FILES[@]} scripts parse"

# ── 2. banned idioms ─────────────────────────────────────────────────────────────────────────────
# One ERE per idiom; the label says what to use instead. Lines inside the dual-path helpers are exempt,
# because their whole job is to try the GNU form first. Comment-only lines are exempt (usage examples).
BANNED='
date -d / date --date (GNU-only; use epoch_of)|(^|[^[:alnum:]_-])date[[:space:]]+(-[[:alpha:]]*d([[:space:]]|$)|--date)
date -I (GNU-only)|(^|[^[:alnum:]_-])date[[:space:]]+-I
stat -c (GNU-only; use mode_of)|(^|[^[:alnum:]_-])stat[[:space:]]+-c
grep -P (BSD grep has none; use -E or awk)|(^|[^[:alnum:]_-])grep[[:space:]]+-[[:alpha:]]*P
grep -z (GNU: whole file as one record; BSD: decompress!) -- use perl -0777 with a file guard|(^|[^[:alnum:]_-])grep[[:space:]]+-[[:alpha:]]*z
declare -A (bash 4; use a kv dir or parallel arrays)|declare[[:space:]]+-[[:alpha:]]*A
mapfile / readarray (bash 4; use a read loop)|(^|[^[:alnum:]_])(mapfile|readarray)([[:space:]]|$)
${v,,} / ${v^^} (bash 4; use tr)|\$\{[[:alnum:]_]+(,,|\^\^)\}
local -n (bash 4.3)|local[[:space:]]+-n[[:space:]]
pipe-ampersand or &>> (bash 4)|(\|&|&>>)
readlink -f (GNU-only)|readlink[[:space:]]+-f
sed -i without a suffix (GNU form; BSD needs -i "" and both take -i.bak)|(^|[^[:alnum:]_-])sed[[:space:]]+-i([[:space:]]+([^'\''"[:space:]]|'\''[^'\'']|"[^"])|$)
timeout (GNU coreutils; absent on macOS)|(^|[;&|(][[:space:]]*|^[[:space:]]*)timeout[[:space:]]+[0-9]
xargs -r (GNU-only)|xargs[[:space:]]+-[[:alpha:]]*r
find -printf (GNU-only)|find[[:space:]].*-printf
head -n -N (GNU-only)|head[[:space:]]+-n[[:space:]]+-[0-9]
machine-specific absolute path|/home/nampark|/Users/np1076
'
# The rules go to awk as a FILE, not via -v: BSD awk rejects a newline inside a -v string, crashed, and
# printed nothing, which read as "no banned idiom anywhere" (caught by the positive control on 2026-10-24).
printf '%s\n' "$BANNED" | command grep . > "$TMP/rules"
scan() {  # $1 = file -> prints "line:label" for each hit outside the exempt helpers; non-zero if awk fails
  awk '
    NR == FNR { p = index($0, "|"); k++; lab[k] = substr($0, 1, p - 1); re[k] = substr($0, p + 1); next }
    /^[[:space:]]*(epoch_of|mode_of|main_root|all_completed)\(\)[[:space:]]*\{/ { inhelper = 1 }
    inhelper && /^[[:space:]]*\}/ { inhelper = 0; next }
    inhelper { next }
    /^[[:space:]]*#/ { next }
    # a line carrying its own BSD fallback is a dual path, not a GNU-only one
    /date[[:space:]]+-j/ || /stat[[:space:]]+-f/ { next }
    { for (j = 1; j <= k; j++) if ($0 ~ re[j]) print FNR ":" lab[j] }
  ' "$TMP/rules" "$1"
}
echo "2. Linux-only / bash-4-only idioms"
# Positive control first: one planted line per idiom, every one must be caught.
cat > "$TMP/control.sh" <<'CONTROL'
x=$(date -d "$t" +%s)
x=$(date -Is)
x=$(stat -c %a f)
grep -qP '\t' f
grep -zoE 'a[^;]*b' f
declare -A M
mapfile -t A < f
y=${v,,}
f() { local -n r=$1; }
cmd |& tee log
readlink -f x
sed -i 's/a/b/' f
timeout 10 cmd
ls | xargs -r rm
find . -printf '%p'
head -n -2 f
p=/home/nampark/x
CONTROL
want=$(command grep -c . "$TMP/control.sh"); got=$(scan "$TMP/control.sh" | cut -d: -f1 | sort -u | command grep -c .)
CONTROL_OK=0; [ "$got" = "$want" ] && CONTROL_OK=1
chk "positive control: planted idioms caught" "$got" "$want"
# Negative control: the portable spellings must NOT be flagged.
cat > "$TMP/clean.sh" <<'CLEAN'
epoch_of() { date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s; }
mode_of() { stat -c %a "$1" 2>/dev/null && return; }
x=$(date +%s); y=$(date -u -r 0 +%F); z=$(stat -f %p f)
grep -qE 'a|b' f; sed -i '' 's/a/b/' f; sed -n 1p f; sed -i.bak 's/a/b/' f
# date -d in a comment is fine
CLEAN
chk "negative control: portable spellings not flagged" "$(scan "$TMP/clean.sh" | command grep -c .)" "0"
hits=0
for f in "${FILES[@]}"; do
  [ "$f" = "$SELF_DIR/portability-check.sh" ] && continue   # its rule table and controls are the idioms
  scan "$f" > "$TMP/hits" 2>"$TMP/scanerr" || { bad "scanner failed on ${f#$OWL/}: $(head -1 "$TMP/scanerr")"; hits=$((hits+1)); continue; }
  while IFS= read -r h; do [ -n "$h" ] || continue; bad "${f#$OWL/}:$h"; hits=$((hits+1)); done < "$TMP/hits"
done
if [ $CONTROL_OK -ne 1 ]; then bad "scan of ${#FILES[@]} scripts NOT TRUSTED: the positive control failed, so a zero means nothing"
elif [ $hits -eq 0 ]; then ok "no banned idiom in ${#FILES[@]} scripts"; fi

# ── 3. helpers: known answers on THIS platform, and copies identical ─────────────────────────────
echo "3. dual-path helpers"
body() { sed -n "/^$1() {/,/^}/p" "$2"; }   # multi-line definitions
line() { command grep -m1 "^$1() {" "$2"; } # one-line definitions
same_copies() {  # $1 = function name, rest = files
  local fn=$1 ref="" f b; shift
  for f in "$@"; do b=$(body "$fn" "$f"); [ -n "$b" ] || b=$(line "$fn" "$f")
    [ -n "$b" ] || { bad "$fn missing from ${f#$OWL/}"; return; }
    if [ -z "$ref" ]; then ref=$b; elif [ "$b" != "$ref" ]; then bad "$fn copy in ${f#$OWL/} differs"; return; fi
  done; ok "$fn: $# copies identical"
}
M=$OWL/.claude/skills/wms-merge/scripts
same_copies epoch_of "$M/merge-one.sh" "$M/merge-preflight.sh" "$M/post-merge-verify.sh"
same_copies main_root "$OWL/.claude/scripts/ticket-lease.sh" "$M/flip-pending-markers.sh"

eval "$(body epoch_of "$M/merge-one.sh")"
chk "epoch_of 2026-10-23T15:41:52Z"     "$(epoch_of 2026-10-23T15:41:52Z)" "1792770112"
chk "epoch_of 1970-01-01T00:00:00Z"     "$(epoch_of 1970-01-01T00:00:00Z)" "0"
for bad_in in "" null 2026-10-23T15:41:52Zjunk 2026-02-30T00:00:00Z 2026-10-23T11:02:55-04:00 2026-10-23T15:41:52.123Z 2026-10-23; do
  chk "epoch_of rejects [$bad_in]" "$(epoch_of "$bad_in")" ""
done

eval "$(body mode_of "$OWL/.claude/skills/wms-dev-probe/scripts/env.sh")"
mkdir "$TMP/d700" "$TMP/d1700"; chmod 700 "$TMP/d700"; chmod 1700 "$TMP/d1700"; : > "$TMP/f600"; chmod 600 "$TMP/f600"
chk "mode_of 700"  "$(mode_of "$TMP/d700")" "700"
chk "mode_of 1700 (sticky kept)" "$(mode_of "$TMP/d1700")" "1700"
chk "mode_of 600"  "$(mode_of "$TMP/f600")" "600"
chk "mode_of missing -> empty" "$(mode_of "$TMP/nope")" ""

eval "$(line all_completed "$M/post-merge-verify.sh")"
T=$'\t'
ac() { all_completed "$1"; echo $?; }
chk "all_completed: all done"            "$(ac "1${T}CI${T}completed${T}success")" "0"
chk "all_completed: one pending"         "$(ac "1${T}CI${T}completed${T}success"$'\n'"2${T}CI${T}in_progress${T}null")" "1"
chk "all_completed: workflow named completed" "$(ac "1${T}completed${T}queued${T}null")" "1"
chk "all_completed: malformed line"      "$(ac "1 CI completed success")" "1"

# main_root needs BASH_SOURCE to be its file, so run it through the real script.
chk "main_root via ticket-lease (from /)" "$(cd / && LEASE_DIR= "$OWL/.claude/scripts/ticket-lease.sh" list >/dev/null 2>&1; echo $?)" "0"
mkdir -p "$TMP/fake/.git"; cp "$OWL/.claude/scripts/ticket-lease.sh" "$TMP/fake/.git/"
chk "main_root refuses a copy outside any repo" "$(cd / && CLAUDE_CODE_SESSION_ID=x bash "$TMP/fake/.git/ticket-lease.sh" list >/dev/null 2>&1; echo $?)" "2"

echo
if [ $FAILS -eq 0 ]; then echo "portability-check: ALL PASS on $(uname -s) / bash $BASH_VERSION"; exit 0; fi
echo "portability-check: $FAILS FAIL(s) on $(uname -s) / bash $BASH_VERSION"; exit 1
