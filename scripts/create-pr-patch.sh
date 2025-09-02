#!/usr/bin/env bash
set -euo pipefail

# Resolve paths relative to script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UTIL_REPO_DIR="$REPO_ROOT"
PATCHED_REPO_DIR="$REPO_ROOT/../next.js"
PATCH_NAME="pr-71759++.patch"
PATCH_OUTPUT="$UTIL_REPO_DIR/patches/$PATCH_NAME"

# Upstream branch to base patch on
UPSTREAM_BRANCH="upstream/canary"

# Commits to include in patch
PR_COMMITS=(
  ed127bb230748d7471b74c16b0532aaf42a0f808
  ea98aea563173245e989ca2af84ad274c979f581
  3017607daab6161721dcdeba286374c7f7725c19
)

# Begin
echo "📦 Entering patched repo: $PATCHED_REPO_DIR"
pushd "$PATCHED_REPO_DIR" > /dev/null

echo "🔄 Fetching latest from upstream..."
git fetch --all

echo "📍 Checking out upstream branch: $UPSTREAM_BRANCH"
git checkout "$UPSTREAM_BRANCH"
git checkout -b patch-stack

# Apply commits
for commit in "${PR_COMMITS[@]}"; do
  echo "🔧 Cherry-picking commit: $commit"
  if git cat-file -e "$commit^{commit}"; then
    git cherry-pick "$commit"
  else
    echo "❌ Commit not found: $commit"
    exit 1
  fi
done

# Generate patch
mkdir -p "$UTIL_REPO_DIR/patches"
BASE_COMMIT="$(git rev-parse "$UPSTREAM_BRANCH")"
echo "🧵 Generating patch file: $PATCH_OUTPUT"
git format-patch "$BASE_COMMIT" --stdout > "$PATCH_OUTPUT"

# Cleanup
echo "🧹 Cleaning up temporary branch"
git checkout "$UPSTREAM_BRANCH"
git branch -D patch-stack
popd > /dev/null

echo "✅ Patch created: $PATCH_OUTPUT"

