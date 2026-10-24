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

# What gets scanned, from git (not globs, which missed the templates the plan skills copy):
#   every tracked or new *.sh; extensionless files with a sh/bash shebang; and the ```bash blocks in the
#   skills and CLAUDE.md, which agents paste and run. Excluded: archives, retired/ and *-evidence/ --
#   records of a run on one machine and session (their paths are part of the record), never re-run.
LIST=$(git -C "$OWL" ls-files --cached --others --exclude-standard) || { bad "git ls-files failed in $OWL"; LIST=""; }
SKIP='^sbdocs/4-Archieves/|/retired/|-evidence/'
FILES=(); : > "$TMP/origin"
while IFS= read -r f; do
  [ -n "$f" ] || continue; printf '%s\n' "$f" | command grep -qE "$SKIP" && continue
  case "${f##*/}" in   # the BASENAME: a path like .claude/x has a dot that is not an extension
    *.sh) FILES+=("$OWL/$f") ;;
    *.*) ;;
    *) [ -f "$OWL/$f" ] && head -1 "$OWL/$f" 2>/dev/null | command grep -qE '^#!.*(/|env[[:space:]]+)(ba)?sh([[:space:]]|$)' && FILES+=("$OWL/$f") ;;
  esac
done <<EOF_LIST
$LIST
EOF_LIST
mkdir -p "$TMP/fence"; nf=0
for md in "$OWL"/.claude/skills/*/SKILL.md "$OWL"/CLAUDE.md; do
  [ -f "$md" ] || continue
  # one temp file per ```bash fence; $TMP/origin maps it back to "<md>:<line of the fence>"
  awk -v out="$TMP/fence/f_$(printf '%s' "${md#$OWL/}" | tr '/.' '__')" -v org="$TMP/origin" -v md="${md#$OWL/}" '
    /^[[:space:]]*```(bash|sh)[[:space:]]*$/ { n++; f = out "." n ".sh"; print f "\t" md ":" NR >> org; inb = 1; next }
    inb && /^[[:space:]]*```[[:space:]]*$/ { inb = 0; close(f); next }
    inb { print > f }' "$md"
done
for f in "$TMP"/fence/*.sh; do [ -f "$f" ] && { FILES+=("$f"); nf=$((nf+1)); }; done
# "<file>:<line>" for a hit -- for a code block, the line in the markdown file it came from
where() { local o; o=$(awk -F'\t' -v f="$1" '$1 == f { print $2 }' "$TMP/origin")
  if [ -n "$o" ]; then printf '%s:%s' "${o%:*}" "$(( ${o##*:} + $2 ))"; else printf '%s:%s' "${1#$OWL/}" "$2"; fi; }
echo "portability-check: $(uname -s) $(uname -m), bash $BASH_VERSION, ${#FILES[@]} scripts ($nf from markdown code blocks)"
# The file list is an instrument too: a floor and known members, or a broken list passes vacuously.
[ ${#FILES[@]} -ge 70 ] || bad "only ${#FILES[@]} scripts found -- the file list is broken"
for must in .claude/scripts/ticket-lease.sh sbdocs/9-System/scripts/plan-state.sh sbdocs/9-System/templates/verify-plan-template.sh; do
  case " ${FILES[*]} " in *" $OWL/$must "*) ;; *) bad "file list is missing $must";; esac
done
# every extracted block must be scanned: compare against the extractor's own count
nx=$(command grep -c . "$TMP/origin" 2>/dev/null || echo 0)
[ $nf -ge 20 ] && [ "$nf" = "$nx" ] || bad "markdown code blocks: extracted $nx, scanning $nf -- the fence extractor is broken"

# ── 1. parse ─────────────────────────────────────────────────────────────────────────────────────
echo "1. parse under bash $BASH_VERSION"
n=0; for f in "${FILES[@]}"; do case "$f" in "$TMP"/fence/*) continue;; esac   # snippets with placeholders need not parse
  "$BASH" -n "$f" 2>"$TMP/err" || { bad "parse: ${f#$OWL/}: $(head -1 "$TMP/err")"; n=1; }; done
[ $n -eq 0 ] && ok "all script files parse"

# ── 2. idioms that work on only ONE of the two machines ───────────────────────────────────────────
# Both directions: GNU-only/bash-4-only breaks the Mac, BSD-only breaks Linux. Rules match a flag in any
# position, quoted words included (`grep -e 'a|b' -P`), and the long spellings. This is a LINT, not a
# parser: it enforces the spellings this repo uses, and every way it was shown to pass vacuously is now a
# line in the positive control below, so a regression in the scanner reds the run instead of greening it.
# portability-check: off   (the rule table and the controls below ARE the idioms)
W='([[:space:]]+('\''[^'\'']*'\''|"[^"]*"|[^|;&()[:space:]]+))*'   # any words, quoted ones too
B='(^|[^[:alnum:]_./${-])'                                        # command boundary ($md5var is not md5)
: > "$TMP/rules"
rule() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$TMP/rules"; }
DATE_D=${B}'date'${W}'[[:space:]]+(-[[:alpha:]]*d([[:space:]]|$|["'\''@$])|--date)'
DATE_J=${B}'date'${W}'[[:space:]]+-[[:alpha:]]*[jv]([[:space:]]|[+-]|$)'
STAT_C=${B}'stat'${W}'[[:space:]]+(-[[:alpha:]]*c|--format|--printf)'
STAT_F=${B}'stat'${W}'[[:space:]]+-[[:alpha:]]*f'
# A dual path is exempt only when the two branches are JOINED by ||, not merely on the same line.
rule D1  'date -d / --date (GNU-only; use epoch_of)'                  "$DATE_D" "($DATE_D.*\|\|.*$DATE_J|$DATE_J.*\|\|.*$DATE_D)"
rule D2  'date -I / --iso-8601 (GNU-only)'                            ${B}'date'${W}'[[:space:]]+(-I|--iso)'
rule D3  'date -r (GNU: a FILE; BSD: seconds; use epoch_of)'          ${B}'date'${W}'[[:space:]]+-[[:alpha:]]*r([[:space:]]|$)'
rule D4  'date -j / -v (BSD-only; use epoch_of)'                      "$DATE_J" "($DATE_D.*\|\|.*$DATE_J|$DATE_J.*\|\|.*$DATE_D)"
rule D5  'date +%N (GNU-only nanoseconds)'                            ${B}'date'${W}'[[:space:]]+[^|;&]*%N'
rule S1  'stat -c / --format (GNU-only; use mode_of)'                 "$STAT_C" "($STAT_C.*\|\|.*$STAT_F|$STAT_F.*\|\|.*$STAT_C)"
rule S2  'stat -f (BSD-only: Linux reads it as "filesystem"; use mode_of)' "$STAT_F" "($STAT_C.*\|\|.*$STAT_F|$STAT_F.*\|\|.*$STAT_C)"
rule G1  'grep -P / --perl-regexp (BSD grep has none; use -E, awk or perl)' ${B}'"?grep"?'${W}'[[:space:]]+(-[[:alpha:]]*P|--perl-regexp)'
rule G2  'grep -z / --null-data (GNU: one record; BSD: DECOMPRESS) -- use the three-valued perl helper' ${B}'"?grep"?'${W}'[[:space:]]+(-[[:alpha:]]*z|--null-data)'
rule B1  'declare/typeset/local/readonly -A (bash 4; use parallel arrays)' '(declare|typeset|local|readonly)'${W}'[[:space:]]+-[[:alpha:]]*A'
rule B2  'nameref -n (bash 4.3; use an eval copy)'                    '(declare|typeset|local)'${W}'[[:space:]]+-[[:alpha:]]*n[[:alpha:]]*([[:space:]]|$)'
rule B3  'mapfile / readarray (bash 4; use a read loop)'              '(^|[^[:alnum:]_])(mapfile|readarray)([[:space:]]|$)'
rule B4  'case modification ${v,,} ${v^^} / declare -l -u (bash 4; use tr)' '(\$\{[[:alnum:]_]+(,,?|\^\^?)\}|(declare|typeset|local)'${W}'[[:space:]]+-[[:alpha:]]*[lu]([[:space:]]|$))'
rule B5  '|& or &>> (bash 4)'                                         '(\|&|&>>)'
rule B6  '${a[-1]} negative index (bash 4.3)'                          '\$\{[[:alnum:]_]+\[-[0-9]+\]\}'
rule B7  '-v VAR test (bash 4.2)'                                     '(\[\[?|test)[^]]*[[:space:]]-v[[:space:]]'
rule B8  '$EPOCHSECONDS / $EPOCHREALTIME / $BASHPID (bash 4-5)'       '(EPOCH(SECONDS|REALTIME)|BASHPID)'
rule B9  'wait -n / coproc / ;;& / shopt globstar|lastpipe (bash 4+)' '(wait[[:space:]]+-n|(^|[;&|][[:space:]]*)coproc[[:space:]]|;;&|shopt[[:space:]]+-s[[:space:]]+(globstar|lastpipe))'
rule B10 '`cd` inside $(…) or backticks without CDPATH= (an exported CDPATH makes cd PRINT the dir)' '(\$\(|`)[[:space:]]*((builtin|command)[[:space:]]+)?cd[[:space:]]'
rule B11 '${x@Q} transformations / printf %(…)T (bash 4.2-4.4)'      '(@[QEPAaUuLK]\}|%\([^)]*\)T)'
rule U1  'readlink -f / -e / -m (GNU; older macOS lacks it)'          ${B}'readlink'${W}'[[:space:]]+-[[:alpha:]]*[fem]'
rule U2  'sed -i with no suffix, --in-place, or -r (GNU forms) -- use -i.bak and -E' ${B}'sed'${W}'[[:space:]]+(-i([[:space:]]+([^'\''"[:space:]-]|'\''[^'\'']|"[^"])|[[:space:]]+-|'\'''\''([[:space:]]|$)|$)|--in-place|--regexp-extended|-[[:alpha:]]*r([[:space:]]|$))'
rule U3  "sed -i '' (BSD form; GNU reads '' as the script) -- use -i.bak" ${B}'sed'${W}'[[:space:]]+-i[[:space:]]+('\'''\''|"")([[:space:]]|$)'
rule U4  'timeout (GNU coreutils; absent on macOS)'                   '(^|[;&|(][[:space:]]*)timeout[[:space:]]+([0-9]|-|"|\$)'
rule U5  'xargs -r / -d (GNU-only)'                                   ${B}'xargs'${W}'[[:space:]]+-[[:alpha:]]*[rd]'
rule U6  'find -printf / -regextype (GNU-only)'                       ${B}'find[[:space:]].*-(f?printf|regextype)'
rule U7  'find -E (BSD-only)'                                         ${B}'find[[:space:]]+-E'
rule U8  'head -n -N (GNU-only)'                                      ${B}'head'${W}'[[:space:]]+-n[[:space:]]*-[0-9]'
rule U9  'tac / nproc / shuf (GNU-only)'                              '(^|[|;&(][[:space:]]*)(tac|nproc|shuf)([[:space:]]|$|\))'
rule U10 'base64 -w (GNU) / -D (BSD)'                                 ${B}'base64'${W}'[[:space:]]+-[[:alpha:]]*[wD]'
rule U11 'md5sum / sha*sum (GNU) or md5 (BSD) -- use shasum -a 256'   ${B}'(md5sum|sha[0-9]+sum|md5)([[:space:]]|$)'
rule U12 'gawk-only awk feature (macOS awk and Debian mawk lack it)'  '(gensub|asorti?|strftime|systime)\(|BEGINFILE|ENDFILE'
rule U13 'machine-specific absolute path (derive it)'                 '/home/nampark|/Users/np1076'
rule U14 'sed BRE \+ \? \| without -E (BSD sed reads them literally: the match silently fails)' ${B}'sed'${W}'[[:space:]]+('\''[^'\'']*\\[+?|][^'\'']*'\''|"[^"]*\\[+?|][^"]*"|[^|;&[:space:]]*\\[+?|])' ${B}'sed'${W}'[[:space:]]+-[[:alpha:]]*[Er]'
rule U15 'sed first~step address (GNU-only)'                          ${B}'sed'${W}'[[:space:]]+[^|;&]*[0-9]~[0-9]'
rule R1  'return N <word> -- a missing ; makes the next command an ARGUMENT, so it never runs' '(^|[;&|{][[:space:]]*)return[[:space:]]+[0-9]+[[:space:]]+[A-Za-z_"'\''$]'
rule R2  '! perl -- a perl error (bad regex, no perl) becomes a PASS; use a three-valued helper' '![[:space:]]*\(?[[:space:]]*([A-Z_]+=[^[:space:]]+[[:space:]]+)*perl[[:space:]]'
rule X1  'CRLF line ending (bash fails at RUN time; bash -n does not notice)' "$(printf '\r')"'$'
# portability-check: on
# The rules reach awk as a FILE, not via -v: BSD awk rejects a newline in a -v string, crashed, and
# printed nothing -- which read as "no banned idiom anywhere" until the positive control caught it.
cat > "$TMP/scan.awk" <<'AWK'
NR == FNR { split($0, f, "\t"); k++; id[k] = f[1]; re[k] = f[3]; ex[k] = f[4]; next }
function code(s,   t) { t = s; gsub(/'[^']*'/, "", t); gsub(/"([^"\\]|\\.)*"/, "", t); sub(/(^|[[:space:]])#.*$/, "", t); return t }
function check(l, at,   j) { for (j = 1; j <= k; j++) if (re[j] != "" && id[j] != "X1" && l ~ re[j] && !(ex[j] != "" && l ~ ex[j])) print at ":" id[j] }
FNR == 1 { inhelper = 0; hstart = 0; hdoc = ""; off = 0 }
{
  raw = $0; start = FNR
  if (raw ~ /\r$/) print start ":X1"
  line = raw; sub(/\r$/, "", line)
  if (line ~ /#[[:space:]]*portability-check:[[:space:]]*off/) { off = 1; next }
  if (line ~ /#[[:space:]]*portability-check:[[:space:]]*on/)  { off = 0; next }
  if (off) next
  # heredoc body: scanned (fail-safe), but never a helper definition or a heredoc start
  if (hdoc != "") { t = line; sub(/^\t+/, "", t); if (t == hdoc) { hdoc = ""; next }; check(line, start); next }
  # a comment is never continued; code is (CRLF continuations too)
  while (line !~ /^[[:space:]]*#/ && line ~ /\\$/ && (getline nxt) > 0) { if (nxt ~ /\r$/) print FNR ":X1"; sub(/\r$/, "", nxt); line = substr(line, 1, length(line) - 1) " " nxt }
  # a multi-line helper body ends at its own closing line "}" -- capped, and an unterminated one is an error
  if (inhelper) {
    if (line ~ /^[[:space:]]*\}[[:space:]]*(#.*)?$/) { inhelper = 0; next }
    if (FNR - hstart > 40) { print hstart ":H0"; inhelper = 0 }
    else next
  }
  if (line ~ /^[[:space:]]*#/) next
  c = code(line)
  # heredoc start: read from the line itself (the code-only copy has already lost the quoted 'EOF')
  if (line ~ /<<-?[[:space:]]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/ && line !~ /<<</) {
    h = line; sub(/.*<<-?[[:space:]]*['"]?/, "", h); sub(/['"]?([^A-Za-z0-9_].*)?$/, "", h); hdoc = h
  }
  if (line ~ /^[[:space:]]*(epoch_of|mode_of|main_root|all_completed)\(\)[[:space:]]*\{/) {
    # one-liner: walk the CODE (strings, comments stripped) to the brace that closes the body, then
    # scan whatever follows it; multi-line: exempt until the closing line
    d = 0; rest = ""; opened = 0
    for (i = 1; i <= length(c); i++) { ch = substr(c, i, 1)
      if (ch == "{") { d++; opened = 1 } else if (ch == "}") { d--; if (opened && d == 0) { rest = substr(c, i + 1); break } } }
    if (opened && d == 0) { if (rest ~ /[^[:space:];]/) check(rest, start); next }
    inhelper = 1; hstart = FNR; next
  }
  check(line, start)
}
END { if (inhelper) print hstart ":H0" }
AWK
printf 'H0\thelper body unterminated or longer than 40 lines (exemption refused)\t\t\n' >> "$TMP/rules"
scan() {  # $1 = file -> "line:RULEID" per hit; non-zero if awk fails
  awk -f "$TMP/scan.awk" "$TMP/rules" "$1"
}
label() { awk -F'\t' -v i="$1" '$1 == i { print $2 }' "$TMP/rules"; }
echo "2. idioms that run on only one of the two machines ($(command grep -c . "$TMP/rules") rules)"
# POSITIVE control: "<expected ids>|<code>". The check is the exact set of line:id pairs, so a rule that
# stops matching its own line is caught even when another rule still matches that line.
# portability-check: off
cat > "$TMP/control.spec" <<'CONTROL'
D1|x=$(date -d "$t" +%s)
D1|x=$(date -u -d "$t" +%s)
D1|x=$(date -d"$t" +%s)
D1|x=$(date --date="$t")
D2|x=$(date -Is)
D2|x=$(date --iso-8601)
D3|x=$(date -r f +%s)
D4|x=$(date -j -f %s 0)
D4|x=$(date -v+1d)
D5|x=$(date +%s%N)
S1|x=$(stat -c %a f)
S1|x=$(stat -L --format %a f)
S2|x=$(stat -f %p f)
G1|grep -qP '\t' f
G1|grep -e x --perl-regexp f
G1|grep -e 'a|b' -P f
G1|"grep" -P x f
G2|grep -zoE 'a[^;]*b' f
G2|grep --null-data x f
B1|declare -A M
B1|declare -g -A M
B1|readonly -A M
B2|f() { local -n r=$1; }
B2|declare -g -n r=x
B3|mapfile -t A < f
B3|readarray A < f
B4|y=${v,,}
B4|y=${v^}
B4|declare -l low=x
B5|cmd |& tee log
B5|cmd &>> log
B6|y=${a[-1]}
B7|[[ -v X ]] && echo y
B7|[ -v X ] && echo y
B8|t=$EPOCHSECONDS
B8|p=$BASHPID
B9|wait -n
B9|shopt -s globstar
B10|d=$(cd "$x" && pwd)
B10|d=`cd "$x" && pwd`
B10|d=$(builtin cd "$x" && pwd)
B11|echo "${x@Q}"
B11|printf '%(%s)T' -1
U1|readlink -f x
U1|readlink -nf x
U2|sed -i 's/a/b/' f
U2|sed -E -i 's/a/b/' f
U2|sed -i -e 's/a/b/' f
U2|sed -r 's/a+/b/' f
U2|sed --in-place 's/a/b/' f
U2|sed -i'' 's/a/b/' f
U3|sed -i '' 's/a/b/' f
U4|timeout 10 cmd
U4|x=$(timeout 5s cmd)
U4|timeout -s KILL 5 cmd
U5|ls | xargs -r rm
U5|ls | xargs -0 -r rm
U5|ls | xargs -d '\n' rm
U6|find . -printf '%p'
U6|find . -regextype egrep -regex 'x'
U7|find -E . -regex 'x'
U8|head -n -2 f
U9|cat f | tac
U9|n=$(nproc)
U10|base64 -w0 f
U10|base64 -D f
U11|sha256sum f
U11|md5 f
U12|awk '{ print gensub(/a/, "b", "g") }' f
U12|awk 'BEGINFILE { n++ }' f
U13|p=/home/nampark/x
U13|p=/Users/np1076/x
U14|id=$(sed -n 's/^| *\(P[0-9]\+\).*/\1/p' f)
U14|sed 's/a\|b/c/' f
U15|sed -n '1~2p' f
R1|[ -f "$2" ] || return 1 PATTERN="$1" perl -ne 1 "$2"
R1|[ -f "$2" ] || return 1 local p=$1
R2|! perl -0777 -ne 'exit 1 unless /x/s' f
R2|test -f f && ! ( PATTERN=x perl -ne 1 f )
-|all_completed() { printf '%s\n' "$1" | awk '{ x = 1 }'; }
G1|grep -P after-a-one-line-helper f
-|all_completed() { :; }; grep -qE ok f
G1|all_completed() { :; }; grep -P same-line-after-helper f
-|epoch_of() { date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y' "$1" +%s; }
G1|x=$(date -d "$t" 2>/dev/null || date -j -f %s 0); grep -P y f
D1|echo "use date -j"; x=$(date -d "$t")
G1|grep -q \
-|  -P continued f
-|mode_of() {
-|  printf '{'
-|  # strip the leading { too
-|  x="${y:-{}"
-|}
G1|grep -P after-a-multi-line-helper-with-stray-braces f
-|# a comment ending in a backslash \
G1|grep -P after-a-continued-comment f
-|cat <<'EOF'
-|epoch_of() {
-|EOF
G1|grep -P after-a-heredoc-that-defines-a-helper f
CONTROL
# portability-check: on
cut -d'|' -f2- "$TMP/control.spec" > "$TMP/control.sh"
# CRLF: a CRLF line, and a CRLF continuation that must still be joined
# portability-check: off
printf 'grep -qE ok f\r\ngrep -q \\\r\n  -P crlf-continued f\r\n' >> "$TMP/control.sh"
# portability-check: on
n=$(command grep -c '' "$TMP/control.spec")
{ awk -F'|' '$1 != "-" { print NR ":" $1 }' "$TMP/control.spec"
  printf '%s\n' "$((n+1)):X1" "$((n+2)):X1" "$((n+2)):G1" "$((n+3)):X1"; } | sort > "$TMP/want"
scan "$TMP/control.sh" | sort > "$TMP/got"
CONTROL_OK=0
if cmp -s "$TMP/want" "$TMP/got"; then CONTROL_OK=1; ok "positive control: $(command grep -c . "$TMP/want") planted line:rule pairs caught exactly"
else bad "positive control: missed [$(comm -23 "$TMP/want" "$TMP/got" | tr '\n' ' ')] extra [$(comm -13 "$TMP/want" "$TMP/got" | tr '\n' ' ')]"; fi
# NEGATIVE control: the portable spellings, and a multi-line helper, must NOT be flagged.
# portability-check: off
cat > "$TMP/clean.sh" <<'CLEAN'
mode_of() {
  stat -c %a "$1" 2>/dev/null && return
  local m; m=$(stat -f %p "$1") && printf '%s' "${m}"
}
x=$(date +%s); y=$(date -u +%F)
grep -qE 'a|b' f; sed -n 1p f; sed -i.bak 's/a/b/' f && rm f.bak; sed -E 's/a+/b/' f; grep 'a\|b' f
d=$(CDPATH= cd -- "$x" >/dev/null && pwd)
z=$md5sum_var; w=${md5}
# date -d and grep -P in a comment are fine
r=$(readlink "$l"); xargs rm < f; head -n 2 f; base64 f; shasum -a 256 f
[ -n "${a[0]}" ]; declare -a ok; local -r r=1; wait "$pid"; [ -n "$v" ]
[ -f "$2" ] || return 1
  [ -f "$2" ] || return 2  # a trailing comment is fine
_ml_rc "$1" "$2" s; [ $? -eq 1 ]
CLEAN
# portability-check: on
neg=$(scan "$TMP/clean.sh" | tr '\n' ' ')
chk "negative control: portable spellings not flagged" "$neg" ""
hits=0
for f in "${FILES[@]}"; do
  scan "$f" > "$TMP/hits" 2>"$TMP/scanerr" || { bad "scanner failed on ${f#$OWL/}: $(head -1 "$TMP/scanerr")"; hits=$((hits+1)); continue; }
  while IFS=: read -r ln rid; do [ -n "$ln" ] || continue; bad "$(where "$f" "$ln"): $(label "$rid")"; hits=$((hits+1)); done < "$TMP/hits"
done
if [ $CONTROL_OK -ne 1 ]; then bad "scan of ${#FILES[@]} scripts NOT TRUSTED: the positive control failed, so a zero means nothing"
elif [ ${#FILES[@]} -lt 70 ]; then bad "scan NOT TRUSTED: the file list is short (${#FILES[@]})"
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
