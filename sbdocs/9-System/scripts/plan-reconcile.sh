#!/usr/bin/env bash
# plan-reconcile.sh — mechanical drift checks for wms2 plan documents.
#
# WHY THIS EXISTS
# Every check below encodes a defect that actually shipped into a plan and was caught late:
#   R1  SBDEV-2732 asserted four things about SBDEV-2731 that were true of 2731's PLAN and false
#       of its CODE (caller count, message wording, a retained literal, a removed assertion).
#   R2  A `:542` citation drifted to `:684` — and that stale line lived inside a Javadoc block the
#       implementer copies verbatim into production source.
#   R3  Three `Flowbin*` message keys were relocated 2731 -> 2732, then Fix B moved on to 2821 and
#       the keys did not follow. Third artifact orphaned the same way.
#   R4  `UBS-neg4` / `W-neg4` were bare negatives against symbols that exist in zero files —
#       trivially true, counted as load-bearing preservation checks.
#   R5  `PHASE=1a`, which a plan told implementers to run, filtered every check and exited 0.
#   R6  Flyway V2.2.08 taken by SBDEV-2801, then V2.2.10 taken by SBDEV-2854. Twice.
#
# Run at the TDD gate, and again after every prerequisite merge.
#
#   bash sbdocs/9-System/scripts/plan-reconcile.sh                    # all plans
#   bash sbdocs/9-System/scripts/plan-reconcile.sh --plan SBDEV-2732  # one ticket
#
# Exit 1 if any HIGH finding. Read-only: never writes to the repo or the plans.

set -uo pipefail

WMS_ROOT="${WMS_ROOT:-/home/nampark/dev/wms-claude}"
PLAN_DIR="$WMS_ROOT/sbdocs/1-Projects/wms2/plan"
SCRIPT_DIR="$WMS_ROOT/sbdocs/9-System/scripts"
API="$WMS_ROOT/v2/wms2-api"
UI="$WMS_ROOT/v2/wms2-web-ui"
FILTER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --plan) FILTER="$2"; shift 2 ;;
        --root) WMS_ROOT="$2"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "FATAL: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

HIGH=0; MED=0; LOW=0
hi()  { echo "  [HIGH] $*"; HIGH=$((HIGH+1)); }
med() { echo "  [MED ] $*"; MED=$((MED+1)); }
low() { echo "  [LOW ] $*"; LOW=$((LOW+1)); }
sec() { echo; echo "=== $* ==="; }

[ -d "$PLAN_DIR" ] || { echo "FATAL: plan dir not found: $PLAN_DIR" >&2; exit 2; }
[ -d "$API" ]      || { echo "FATAL: api repo not found: $API" >&2; exit 2; }

PLANS=()
while IFS= read -r f; do PLANS+=("$f"); done < <(
    if [ -n "$FILTER" ]; then ls "$PLAN_DIR"/*"$FILTER"*.md 2>/dev/null
    else ls "$PLAN_DIR"/SBDEV-*.md 2>/dev/null; fi)
[ ${#PLANS[@]} -gt 0 ] || { echo "FATAL: no plans matched '${FILTER:-SBDEV-*}'" >&2; exit 2; }

echo "plan-reconcile — $(basename "$WMS_ROOT") — ${#PLANS[@]} plan(s)"

# ---------------------------------------------------------------------------
# R6 — Flyway version collision across ALL refs (local + remote, merged or not)
# Unmerged branches hold invisible versions; `ls db/migration/` cannot see them.
# ---------------------------------------------------------------------------
sec "R6 — Flyway version collisions"
MIGMAP=$(mktemp); trap 'rm -f "$MIGMAP"' EXIT
# Only origin/develop + refs NOT merged into it. Merged history replays old renumbers and would
# report long-settled duplicates as live collisions; unmerged refs are where invisible versions hide.
MERGED=$(git -C "$API" for-each-ref --format='%(refname)' --merged origin/develop refs/heads refs/remotes 2>/dev/null)
REFS=$(git -C "$API" for-each-ref --format='%(refname)' refs/heads refs/remotes 2>/dev/null \
       | grep -vxF "$MERGED" ; echo refs/remotes/origin/develop)
for ref in $REFS; do
    git -C "$API" ls-tree -r --name-only "$ref" -- src/main/resources/db/migration 2>/dev/null \
      | grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+__[A-Za-z0-9_]+\.sql' \
      | while read -r m; do echo "$(echo "$m" | grep -oE '^V[0-9.]+')|$m|$ref"; done
done | sort -u > "$MIGMAP"

for v in $(cut -d'|' -f1 "$MIGMAP" | sort -u); do
    n=$(awk -F'|' -v v="$v" '$1==v {print $2}' "$MIGMAP" | sort -u | wc -l)
    if [ "$n" -gt 1 ]; then
        hi "$v claimed by $n DIFFERENT migrations — duplicate version fails startup for every tenant:"
        awk -F'|' -v v="$v" '$1==v {printf "         %s  (%s)\n", $2, $3}' "$MIGMAP" | sort -u
    fi
done
for p in "${PLANS[@]}"; do
    base=$(basename "$p" .md)
    for v in $(grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+__[a-z0-9_]+\.sql' "$p" 2>/dev/null | grep -oE '^V[0-9.]+' | sort -u); do
        owner=$(awk -F'|' -v v="$v" '$1==v {print $2}' "$MIGMAP" | sort -u | head -1)
        if [ -n "$owner" ] && ! grep -q "$owner" "$p"; then
            hi "$base claims $v, but $v is already taken on a branch by: $owner"
        fi
    done
done
[ $HIGH -eq 0 ] && echo "  ok — no duplicate Flyway versions across any ref"

# ---------------------------------------------------------------------------
# R2 — line-reference drift. Bare :NNN citations rot every time develop moves.
# ---------------------------------------------------------------------------
sec "R2 — stale line references"
for p in "${PLANS[@]}"; do
    base=$(basename "$p" .md); reported=0
    while IFS= read -r cite; do
        file="${cite%%:*}"; line="${cite##*:}"
        case "$line" in ''|*[!0-9]*) continue ;; esac
        hits=$(find "$API/src" "$UI" -name "$file" -not -path '*/node_modules/*' -not -path '*/target/*' 2>/dev/null)
        cnt=$(echo "$hits" | grep -c . )
        [ "$cnt" -eq 1 ] || continue                     # 0 or ambiguous -> cannot judge
        eof=$(wc -l < "$hits")
        if [ "$line" -gt "$eof" ]; then
            med "$base cites $cite but that file has only $eof lines"
            reported=$((reported+1))
        fi
        [ $reported -ge 8 ] && { low "$base — more citations beyond EOF, truncated at 8"; break; }
    done < <(grep -oE '[A-Za-z][A-Za-z0-9_]*\.(java|vue|js|sql):[0-9]+' "$p" | sort -u)
done
echo "  note: only citations past end-of-file are provable here. A citation that still resolves may"
echo "        point at unrelated code — prefer a symbol anchor (grep -n 'symbolName') over a bare :NNN."

# ---------------------------------------------------------------------------
# R1 — claims about other tickets that were never pinned to merged code
# ---------------------------------------------------------------------------
sec "R1 — dependency pinning"
# STRUCTURAL, not textual. An earlier version grepped prose for "<ticket> ... ships|owns|delivers"
# and reported 4/4 false positives — including a plan's own changelog entry ABOUT this defect, and a
# sentence merely comparing two tickets' staging. Prose cannot distinguish a load-bearing dependency
# from commentary. Front-matter can.
#
# Declare dependencies explicitly:
#   depends_on:
#     - {ticket: SBDEV-2731, sha: 89de3f0}      # pinned to reviewed code
#     - {ticket: SBDEV-2854, sha: UNMERGED}     # known-unmerged, must resolve before the TDD gate
for p in "${PLANS[@]}"; do
    base=$(basename "$p" .md); self=$(echo "$base" | grep -oE 'SBDEV-[0-9]+')
    fm=$(sed -n '1,80p' "$p")
    if ! echo "$fm" | grep -q '^depends_on:'; then
        # only nag when the plan actually leans on an unmerged sibling
        while read -r dep; do
            [ "$dep" = "$self" ] && continue
            git -C "$API" for-each-ref --format='%(refname:short)' 2>/dev/null | grep -qi "$dep" || continue
            [ "$(git -C "$API" for-each-ref --merged origin/develop --format='%(refname)' refs/heads refs/remotes 2>/dev/null | grep -ci "$dep")" -eq 0 ] || continue
            med "$base references $dep, which has an UNMERGED branch, but declares no depends_on front-matter"
            echo "         add:  depends_on:\n                 - {ticket: $dep, sha: UNMERGED}"
            break
        done < <(grep -oE 'SBDEV-[0-9]+' "$p" | sort -u)
        continue
    fi
    # process substitution, NOT a pipe: `... | while read` runs the body in a SUBSHELL, so hi()/med()
    # increment a copy of the counters and a HIGH here would print but never set the exit code.
    # That is the same fail-open class this script exists to catch. Fixed 2026-08-06.
    while read -r entry; do
        dep=$(echo "$entry" | grep -oE 'SBDEV-[0-9]+')
        sha=$(echo "$entry" | sed -E 's/.*sha: *//')
        if [ "$sha" = "UNMERGED" ]; then
            if [ "$(git -C "$API" for-each-ref --merged origin/develop --format='%(refname)' refs/heads refs/remotes 2>/dev/null | grep -ci "$dep")" -gt 0 ]; then
                med "$base pins $dep as UNMERGED but it IS now merged — re-verify every claim and re-pin"
            else
                low "$base depends on $dep (declared UNMERGED) — resolve before the TDD gate"
            fi
        elif ! git -C "$API" cat-file -e "$sha^{commit}" 2>/dev/null; then
            hi "$base pins $dep to sha $sha, which does NOT exist in wms2-api — rebased or rewritten"
        else
            low "$base pins $dep @ $sha — re-verify claims if that branch moves"
        fi
    done < <(echo "$fm" | sed -n '/^depends_on:/,/^[a-z_]*:/p' | grep -oE 'ticket: *SBDEV-[0-9]+, *sha: *[A-Za-z0-9]+')
done

# ---------------------------------------------------------------------------
# R3 — relocated artifacts with no receiving owner
# ---------------------------------------------------------------------------
sec "R3 — orphaned relocations"
for p in "${PLANS[@]}"; do
    base=$(basename "$p" .md)
    # process substitution, not a pipe — same subshell fail-open fixed in R1.
    while IFS= read -r hit; do
        ln="${hit%%:*}"
        target=$(echo "$hit" | grep -oE 'SBDEV-[0-9]+' | head -1)
        [ -n "$target" ] || continue
        tplan=$(ls "$PLAN_DIR"/*"$target"*.md 2>/dev/null | head -1)
        # Code identifiers only. Exclude filenames (*.properties/.js/.java/.sql/.vue) and field access
        # (location.typeId — lowercase after the dot); keep CamelCase symbols and BusinessException.Key.
        ids=$(sed -n "${ln},$((ln+12))p" "$p" \
              | grep -oE '`[A-Za-z][A-Za-z0-9_.]{5,}`' | tr -d '`' \
              | grep -E '([a-z][A-Z]|_)' \
              | grep -vE '\.(properties|js|java|sql|vue|md|sh)$' \
              | grep -vE '\.[a-z]' \
              | sort -u | head -6)
        for id in $ids; do
            grep -rq "$id" "$API/src" 2>/dev/null && continue        # exists in source -> not orphaned
            if [ -z "$tplan" ]; then
                low "$base:$ln relocates '$id' to $target, which has NO plan document"
                echo "         -> verify ownership on the $target ticket itself; this check only reads plan files"
            elif ! grep -q "$id" "$tplan"; then
                med "$base:$ln relocates '$id' to $target, but $target's plan does not mention it"
                echo "         and it exists nowhere in the API source — orphaned artifact"
            fi
        done
    done < <(grep -nE 'RELOCATED to|relocated to|moved to SBDEV-|belongs to SBDEV-' "$p" 2>/dev/null)
done
echo "  (heuristic: flags code identifiers named at a relocation notice that the destination never picked up)"

# ---------------------------------------------------------------------------
# R4/R5 — verify-script integrity
# ---------------------------------------------------------------------------
sec "R4/R5 — verify-script integrity"
for p in "${PLANS[@]}"; do
    tk=$(basename "$p" .md | grep -oE 'SBDEV-[0-9]+')
    vs=$(ls "$SCRIPT_DIR"/verify-*"$tk"*.sh 2>/dev/null | head -1)
    [ -n "$vs" ] || { low "$tk — no verify script found"; continue; }
    vb=$(basename "$vs")

    # Only scripts that FILTER checks on a mode variable can silently all-green. A binary opt-in
    # (RUN_TESTS=1) that merely skips extra work and says so is not this defect — an earlier version
    # of this check flagged verify-2731 and verify-2854 for lacking a guard they have no need of.
    if grep -qE '_selected\(\)|^FILTERED=|filtered out' "$vs"; then
        grep -qE 'case +"?\$\{?[A-Z_]+' "$vs" \
          || hi "$vb FILTERS checks on a mode variable but never validates it — an unrecognised value filters every check and exits 0"
    fi

    # vacuous negatives: file_not_contains on an identifier that exists in zero source files,
    # in a function that does not also assert presence somewhere (i.e. not conjoined)
    while IFS= read -r fn; do
        name="${fn%%(*}"
        body=$(awk -v f="$name" '$0 ~ "^"f"\\(\\)" {p=1} p {print} p && /^}/ {exit} p && /;\s*}/ {exit}' "$vs")
        echo "$body" | grep -q 'file_contains' && continue          # conjoined -> fine
        sym=$(echo "$body" | grep -oE "file_not_contains(_ml)? +'[^']+'" | head -1 \
              | sed -E "s/.*'([^']+)'.*/\1/" | grep -oE '^[A-Za-z][A-Za-z0-9_]{5,}$')
        [ -n "$sym" ] || continue
        n=$(grep -rl "$sym" "$API/src" "$UI/components" 2>/dev/null | grep -c . )
        [ "$n" -eq 0 ] && hi "$vb :: $name() is VACUOUS — '$sym' exists in 0 files, so the negative is trivially true (conjoin it)"
    done < <(grep -oE '^check_[A-Za-z0-9_]+\(\)' "$vs")

    grep -qiE 'pre-[0-9a-z-]*merge|baseline .*(re-?record|expires)' "$vs" "$p" \
      || med "$tk baseline is not labelled with the prerequisite state it was measured against — it expires silently"
done

# ---------------------------------------------------------------------------
# R5b — db_verified sample: fresh-seed alone validates the case that cannot fail
# ---------------------------------------------------------------------------
sec "R5b — db_verified tenant sample"
for p in "${PLANS[@]}"; do
    base=$(basename "$p" .md)
    grep -qE '^db_verified: *true' "$p" || continue
    fm=$(sed -n '1,60p' "$p")
    migrated=$(echo "$fm" | grep -ciE 'wineco|hydra_v2\b|wms2-hydra[^-]|PRD|prod')
    fresh=$(echo "$fm" | grep -ciE 'v2t|fresh')
    if [ "$migrated" -eq 0 ] && [ "$fresh" -gt 0 ]; then
        hi "$base is db_verified on FRESH-SEED tenants only — that is the sample that structurally cannot"
        echo "         exhibit migrated-tenant hazards (this is how 726 wineco + 58 HMG prod locations were missed)"
    elif [ "$migrated" -eq 0 ]; then
        med "$base db_verified but no migrated tenant named in front-matter — state which tenants and why representative"
    fi
done

echo
echo "───────────────────────────────────────────────"
echo "  HIGH $HIGH   MED $MED   LOW $LOW"
[ "$HIGH" -gt 0 ] && { echo "  HIGH findings present — do not pass the TDD gate."; exit 1; }
echo "  no HIGH findings"
exit 0
