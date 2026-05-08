#!/usr/bin/env bash
#
# ui-sync.sh — cherry-pick v1 UI commits forward to v2 (Lane A of the
#              weekly WMS v1→v2 sync sweep).
#
# Usage:
#   ui-sync.sh <v1-repo-path> <v2-repo-path>
#
# Example:
#   ui-sync.sh /Users/np1076/dev/spk/owl/v1/wms-web-ui \
#              /Users/np1076/dev/spk/owl/v2/wms2-web-ui
#
# Preconditions (one-time setup per v2 repo):
#   cd <v2-repo>
#   git remote add v1 <absolute-path-to-v1-repo>
#   git fetch v1
#   git tag v1-synced-upstream <sha-of-last-known-synced-v1-commit>
#
# What this script does:
#   1. Fetches v1/develop-arden into the v2 repo.
#   2. Checks out v2's develop.
#   3. Creates a disposable sync branch sync-YYYY-MM-DD from develop.
#   4. Shows the pending v1 commits (those after v1-synced-upstream).
#   5. Shows git-cherry output so you can see which are already patch-equivalent in v2.
#   6. Prompts for confirmation.
#   7. Cherry-picks the range with -x (preserves v1 SHA in the message).
#   8. If the cherry-pick completes cleanly, fast-forward-merges the sync branch
#      back into develop and moves v1-synced-upstream to v1/develop-arden.
#   9. Leaves the sync branch around for inspection; you can delete it after merge.
#
# What it deliberately does NOT do:
#   - Push. Review first.
#   - Force-anything. Any conflict halts the script with instructions.
#   - Touch the v1 repo state.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <v1-repo-path> <v2-repo-path>" >&2
  exit 2
fi

V1_REPO="$1"
V2_REPO="$2"

for p in "$V1_REPO" "$V2_REPO"; do
  if [[ ! -d "$p/.git" ]]; then
    echo "ERROR: $p is not a git repo" >&2
    exit 2
  fi
done

# All git commands use -C so cwd is irrelevant.
V2_BRANCH="develop"
V1_BRANCH="develop"
SYNC_BRANCH="sync-$(date +%Y-%m-%d)"

echo "=== Fetching v1 into v2 ==="
git -C "$V2_REPO" fetch v1

echo
echo "=== v2 current branch: $(git -C "$V2_REPO" branch --show-current) ==="
echo "=== Switching to $V2_BRANCH ==="
git -C "$V2_REPO" checkout "$V2_BRANCH"

if git -C "$V2_REPO" rev-parse --verify "$SYNC_BRANCH" >/dev/null 2>&1; then
  echo "ERROR: branch $SYNC_BRANCH already exists in $V2_REPO. Delete or rename it first." >&2
  exit 2
fi

ANCHOR="$(git -C "$V2_REPO" rev-parse v1-synced-upstream)"
V1_HEAD="$(git -C "$V2_REPO" rev-parse v1/$V1_BRANCH)"

echo
echo "=== Anchor (last-synced v1 SHA): $ANCHOR ==="
echo "=== v1/$V1_BRANCH HEAD:          $V1_HEAD ==="

if [[ "$ANCHOR" == "$V1_HEAD" ]]; then
  echo
  echo "Nothing to sync. v1-synced-upstream already equals v1/$V1_BRANCH."
  exit 0
fi

echo
echo "=== Pending v1 commits (oldest first) ==="
git -C "$V2_REPO" log --oneline --reverse "${ANCHOR}..v1/${V1_BRANCH}"

echo
echo "=== Patch-equivalence check (git cherry) ==="
echo "  '+' = not yet in v2/$V2_BRANCH (will be applied)"
echo "  '-' = already in v2/$V2_BRANCH by patch-id (will be skipped automatically)"
git -C "$V2_REPO" cherry -v "$V2_BRANCH" "v1/$V1_BRANCH" "$ANCHOR" || true

echo
read -r -p "Proceed with cherry-pick onto $SYNC_BRANCH? [y/N] " CONFIRM
if [[ "${CONFIRM:-N}" != "y" && "${CONFIRM:-N}" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

echo
echo "=== Creating sync branch: $SYNC_BRANCH ==="
git -C "$V2_REPO" checkout -b "$SYNC_BRANCH" "$V2_BRANCH"

echo
echo "=== Cherry-picking range ==="
if ! git -C "$V2_REPO" cherry-pick -x "${ANCHOR}..v1/${V1_BRANCH}"; then
  echo
  echo "Cherry-pick halted. Resolve conflicts, then run one of:"
  echo "  git -C $V2_REPO cherry-pick --continue   # after resolving"
  echo "  git -C $V2_REPO cherry-pick --skip       # skip a patch-equivalent commit"
  echo "  git -C $V2_REPO cherry-pick --abort      # discard sync attempt"
  echo
  echo "After you finish, fast-forward merge + re-tag manually:"
  echo "  git -C $V2_REPO checkout $V2_BRANCH"
  echo "  git -C $V2_REPO merge --ff-only $SYNC_BRANCH"
  echo "  git -C $V2_REPO tag -f v1-synced-upstream v1/$V1_BRANCH"
  exit 1
fi

echo
echo "=== Fast-forward merging $SYNC_BRANCH into $V2_BRANCH ==="
git -C "$V2_REPO" checkout "$V2_BRANCH"
git -C "$V2_REPO" merge --ff-only "$SYNC_BRANCH"

echo
echo "=== Moving v1-synced-upstream to v1/$V1_BRANCH ==="
git -C "$V2_REPO" tag -f v1-synced-upstream "v1/$V1_BRANCH"

echo
echo "Done. Review with: git -C $V2_REPO log --oneline --stat ${ANCHOR}..HEAD"
echo "Delete the sync branch when you're satisfied:"
echo "  git -C $V2_REPO branch -d $SYNC_BRANCH"
