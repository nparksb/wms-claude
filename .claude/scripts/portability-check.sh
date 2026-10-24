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

# Every tracked or new *.sh in owl, minus archives, retired/ and *-evidence/: those are records of a run on
# one specific machine and session (their paths are part of the record), never re-run as tools.
# From git, not globs: three globs missed the templates the plan skills copy, and an empty match would
# have graded "0 scripts" as a pass.
FILES=()
while IFS= read -r f; do FILES+=("$OWL/$f"); done < <(
  git -C "$OWL" ls-files --cached --others --exclude-standard -- '*.sh' | command grep -vE '^sbdocs/4-Archieves/|/retired/|-evidence/' | sort)
echo "portability-check: $(uname -s) $(uname -m), bash $BASH_VERSION, ${#FILES[@]} scripts"
# The file list is an instrument too: a floor and two known members, or a broken list passes vacuously.
[ ${#FILES[@]} -ge 70 ] || bad "only ${#FILES[@]} scripts found -- the file list is broken"
for must in .claude/scripts/ticket-lease.sh sbdocs/9-System/scripts/plan-state.sh sbdocs/9-System/templates/verify-plan-template.sh; do
  case " ${FILES[*]} " in *" $OWL/$must "*) ;; *) bad "file list is missing $must";; esac
done

# ── 1. parse ─────────────────────────────────────────────────────────────────────────────────────
echo "1. parse under bash $BASH_VERSION"
n=0; for f in "${FILES[@]}"; do "$BASH" -n "$f" 2>"$TMP/err" || { bad "parse: ${f#$OWL/}: $(head -1 "$TMP/err")"; n=1; }; done
[ $n -eq 0 ] && ok "all ${#FILES[@]} scripts parse"

# ── 2. idioms that work on only ONE of the two machines ───────────────────────────────────────────
# Both directions: GNU-only/bash-4-only breaks the Mac, BSD-only breaks Linux. A rule matches the flag in
# any position (`date -u -d`, `sed -E -i`) and the long spelling. Exempt: comment-only lines; the bodies
# of the dual-path helpers (brace-depth tracked, so a one-line helper exempts only itself); and, PER RULE,
# a line that also carries the other platform's branch (`date -d ... || date -j ...`).
W='([[:space:]]+[^|;&()[:space:]]+)*'        # any words before the flag
B='(^|[^[:alnum:]_./${-])'                    # command boundary ($md5var or ${md5} is not a command)
: > "$TMP/rules"
rule() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$TMP/rules"; }
DATE_D=${B}'date'${W}'[[:space:]]+(-[[:alpha:]]*d([[:space:]]|$)|--date)'
DATE_J=${B}'date'${W}'[[:space:]]+-[[:alpha:]]*[jv]([[:space:]]|[+-]|$)'
STAT_C=${B}'stat'${W}'[[:space:]]+(-[[:alpha:]]*c|--format|--printf)'
STAT_F=${B}'stat'${W}'[[:space:]]+-[[:alpha:]]*f'
rule D1  'date -d / --date (GNU-only; use epoch_of)'                  "$DATE_D" "$DATE_J"
rule D2  'date -I (GNU-only)'                                         ${B}'date'${W}'[[:space:]]+-I'
rule D3  'date -r (GNU: a FILE; BSD: seconds; use epoch_of)'          ${B}'date'${W}'[[:space:]]+-[[:alpha:]]*r([[:space:]]|$)'
rule D4  'date -j / -v (BSD-only; use epoch_of)'                      "$DATE_J" "$DATE_D"
rule S1  'stat -c / --format (GNU-only; use mode_of)'                 "$STAT_C" "$STAT_F"
rule S2  'stat -f (BSD-only: Linux reads it as "filesystem"; use mode_of)' "$STAT_F" "$STAT_C"
rule G1  'grep -P / --perl-regexp (BSD grep has none; use -E, awk or perl)' ${B}'grep'${W}'[[:space:]]+(-[[:alpha:]]*P|--perl-regexp)'
rule G2  'grep -z / --null-data (GNU: one record; BSD: DECOMPRESS) -- use perl -0777 with a file guard' ${B}'grep'${W}'[[:space:]]+(-[[:alpha:]]*z|--null-data)'
rule B1  'declare/typeset/local -A (bash 4; use parallel arrays or a kv dir)' '(declare|typeset|local)[[:space:]]+-[[:alpha:]]*A'
rule B2  'nameref -n (bash 4.3; use an eval copy)'                    '(declare|typeset|local)[[:space:]]+-[[:alpha:]]*n[[:alpha:]]*[[:space:]]'
rule B3  'mapfile / readarray (bash 4; use a read loop)'              '(^|[^[:alnum:]_])(mapfile|readarray)([[:space:]]|$)'
rule B4  '${v,,} / ${v^^} case modification (bash 4; use tr)'        '\$\{[[:alnum:]_]+(,,?|\^\^?)\}'
rule B5  '|& or &>> (bash 4)'                                         '(\|&|&>>)'
rule B6  '${a[-1]} negative index (bash 4.3)'                          '\$\{[[:alnum:]_]+\[-[0-9]+\]\}'
rule B7  '[[ -v ]] (bash 4.2)'                                        '\[\[[[:space:]]+-v[[:space:]]'
rule B8  '$EPOCHSECONDS / $EPOCHREALTIME (bash 5)'                    'EPOCH(SECONDS|REALTIME)'
rule B9  'wait -n (bash 4.3)'                                         ${B}'wait[[:space:]]+-n'
rule B10 '$(cd ...) without CDPATH= (an exported CDPATH makes cd PRINT the dir into the capture)' '\$\([[:space:]]*cd[[:space:]]'
rule U1  'readlink -f / -e / -m (GNU; older macOS lacks it)'          ${B}'readlink'${W}'[[:space:]]+-[[:alpha:]]*[fem]'
rule U2  'sed -i with no suffix (GNU form; BSD takes the NEXT arg as the suffix) -- use -i.bak' ${B}'sed'${W}'[[:space:]]+-i([[:space:]]+([^'\''"[:space:]-]|'\''[^'\'']|"[^"])|[[:space:]]+-|$)'
rule U3  "sed -i '' (BSD form; GNU reads '' as the script) -- use -i.bak" ${B}'sed'${W}'[[:space:]]+-i[[:space:]]+('\'''\''|"")'
rule U4  'timeout (GNU coreutils; absent on macOS)'                   '(^|[;&|(][[:space:]]*)timeout[[:space:]]+[0-9]'
rule U5  'xargs -r (GNU-only)'                                        ${B}'xargs'${W}'[[:space:]]+-[[:alpha:]]*r'
rule U6  'find -printf (GNU-only)'                                    ${B}'find[[:space:]].*-f?printf'
rule U7  'find -E (BSD-only)'                                         ${B}'find[[:space:]]+-E'
rule U8  'head -n -N (GNU-only)'                                      ${B}'head'${W}'[[:space:]]+-n[[:space:]]*-[0-9]'
rule U9  'tac (GNU-only; use awk)'                                    '(^|[|;&(][[:space:]]*)tac([[:space:]]|$)'
rule U10 'base64 -w (GNU) / -D (BSD)'                                 ${B}'base64'${W}'[[:space:]]+-[[:alpha:]]*[wD]'
rule U11 'md5sum / sha*sum (GNU) or md5 (BSD) -- use shasum -a 256'   ${B}'(md5sum|sha[0-9]+sum|md5)([[:space:]]|$)'
rule U12 'gawk-only awk function (macOS awk and Debian mawk lack it)'  '(gensub|asorti?|strftime|systime)\('
rule U13 'machine-specific absolute path (derive it)'                 '/home/nampark|/Users/np1076'
# The rules reach awk as a FILE, not via -v: BSD awk rejects a newline in a -v string, crashed, and
# printed nothing -- which read as "no banned idiom anywhere" until the positive control caught it.
scan() {  # $1 = file -> "line:RULEID" per hit; non-zero if awk fails
  awk '
    NR == FNR { split($0, f, "\t"); k++; id[k] = f[1]; re[k] = f[3]; ex[k] = f[4]; next }
    {
      line = $0; start = FNR
      while (line ~ /\\$/ && (getline nxt) > 0) line = substr(line, 1, length(line) - 1) " " nxt
      if (depth > 0) { o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line); depth += o - c; next }
      if (line ~ /^[[:space:]]*(epoch_of|mode_of|main_root|all_completed)\(\)[[:space:]]*\{/) {
        o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line); depth = o - c; if (depth < 0) depth = 0; next
      }
      if (line ~ /^[[:space:]]*#/) next
      for (j = 1; j <= k; j++) if (line ~ re[j] && !(ex[j] != "" && line ~ ex[j])) print start ":" id[j]
    }
  ' "$TMP/rules" "$1"
}
label() { awk -F'\t' -v i="$1" '$1 == i { print $2 }' "$TMP/rules"; }
echo "2. idioms that run on only one of the two machines ($(command grep -c . "$TMP/rules") rules)"
# POSITIVE control: "<expected ids>|<code>". The check is the exact set of line:id pairs, so a rule that
# stops matching its own line is caught even when another rule still matches that line.
cat > "$TMP/control.spec" <<'CONTROL'
D1|x=$(date -d "$t" +%s)
D1|x=$(date -u -d "$t" +%s)
D1|x=$(date --date="$t")
D2|x=$(date -Is)
D3|x=$(date -r f +%s)
D4|x=$(date -j -f %s 0)
D4|x=$(date -v+1d)
S1|x=$(stat -c %a f)
S1|x=$(stat -L --format %a f)
S2|x=$(stat -f %p f)
G1|grep -qP '\t' f
G1|grep -e x --perl-regexp f
G1|grep -e x -P f
G2|grep -zoE 'a[^;]*b' f
G2|grep --null-data x f
B1|declare -A M
B1|local -A M
B2|f() { local -n r=$1; }
B2|declare -nr r=x
B3|mapfile -t A < f
B3|readarray A < f
B4|y=${v,,}
B4|y=${v^}
B5|cmd |& tee log
B5|cmd &>> log
B6|y=${a[-1]}
B7|[[ -v X ]] && echo y
B8|t=$EPOCHSECONDS
B9|wait -n
B10|d=$(cd "$x" && pwd)
U1|readlink -f x
U1|readlink -nf x
U2|sed -i 's/a/b/' f
U2|sed -E -i 's/a/b/' f
U2|sed -i -e 's/a/b/' f
U3|sed -i '' 's/a/b/' f
U4|timeout 10 cmd
U4|x=$(timeout 5s cmd)
U5|ls | xargs -r rm
U5|ls | xargs -0 -r rm
U6|find . -printf '%p'
U7|find -E . -regex 'x'
U8|head -n -2 f
U9|cat f | tac
U10|base64 -w0 f
U10|base64 -D f
U11|sha256sum f
U11|md5 f
U12|awk '{ print gensub(/a/, "b", "g") }' f
U13|p=/home/nampark/x
U13|p=/Users/np1076/x
-|all_completed() { printf '%s\n' "$1" | awk '{ x = 1 }'; }
G1|grep -P after-a-one-line-helper f
-|epoch_of() { date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y' "$1" +%s; }
G1|x=$(date -d "$t" 2>/dev/null || date -j -f %s 0); grep -P y f
G1|grep -q \
-|  -P continued f
CONTROL
cut -d'|' -f2- "$TMP/control.spec" > "$TMP/control.sh"
awk -F'|' '$1 != "-" { print NR ":" $1 }' "$TMP/control.spec" | sort > "$TMP/want"
scan "$TMP/control.sh" | sort > "$TMP/got"
CONTROL_OK=0
if cmp -s "$TMP/want" "$TMP/got"; then CONTROL_OK=1; ok "positive control: $(command grep -c . "$TMP/want") planted line:rule pairs caught exactly"
else bad "positive control: missed [$(comm -23 "$TMP/want" "$TMP/got" | tr '\n' ' ')] extra [$(comm -13 "$TMP/want" "$TMP/got" | tr '\n' ' ')]"; fi
# NEGATIVE control: the portable spellings, and a multi-line helper, must NOT be flagged.
cat > "$TMP/clean.sh" <<'CLEAN'
mode_of() {
  stat -c %a "$1" 2>/dev/null && return
  local m; m=$(stat -f %p "$1") && printf '%s' "${m}"
}
x=$(date +%s); y=$(date -u +%F)
grep -qE 'a|b' f; sed -n 1p f; sed -i.bak 's/a/b/' f && rm f.bak
d=$(CDPATH= cd -- "$x" >/dev/null && pwd)
z=$md5sum_var; w=${md5}
# date -d and grep -P in a comment are fine
r=$(readlink "$l"); xargs rm < f; head -n 2 f; base64 f; shasum -a 256 f
[ -n "${a[0]}" ]; declare -a ok; local -r r=1; wait "$pid"
CLEAN
neg=$(scan "$TMP/clean.sh" | tr '\n' ' ')
chk "negative control: portable spellings not flagged" "$neg" ""
hits=0
for f in "${FILES[@]}"; do
  [ "$f" = "$SELF_DIR/portability-check.sh" ] && continue   # its rule table and controls ARE the idioms
  scan "$f" > "$TMP/hits" 2>"$TMP/scanerr" || { bad "scanner failed on ${f#$OWL/}: $(head -1 "$TMP/scanerr")"; hits=$((hits+1)); continue; }
  while IFS=: read -r ln rid; do [ -n "$ln" ] || continue; bad "${f#$OWL/}:$ln: $(label "$rid")"; hits=$((hits+1)); done < "$TMP/hits"
done
if [ $CONTROL_OK -ne 1 ]; then bad "scan of ${#FILES[@]} scripts NOT TRUSTED: the positive control failed, so a zero means nothing"
elif [ $hits -eq 0 ]; then ok "no single-platform idiom in ${#FILES[@]} scripts"; fi

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
chk "main_root via ticket-lease (from /)" "$(CDPATH= cd / && LEASE_DIR= "$OWL/.claude/scripts/ticket-lease.sh" list >/dev/null 2>&1; echo $?)" "0"
mkdir -p "$TMP/fake/.git"; cp "$OWL/.claude/scripts/ticket-lease.sh" "$TMP/fake/.git/"
chk "main_root refuses a copy outside any repo" "$(CDPATH= cd / && CLAUDE_CODE_SESSION_ID=x bash "$TMP/fake/.git/ticket-lease.sh" list >/dev/null 2>&1; echo $?)" "2"

echo
if [ $FAILS -eq 0 ]; then echo "portability-check: ALL PASS on $(uname -s) / bash $BASH_VERSION"; exit 0; fi
echo "portability-check: $FAILS FAIL(s) on $(uname -s) / bash $BASH_VERSION"; exit 1
