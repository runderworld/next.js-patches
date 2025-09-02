#!/usr/bin/env bash
set -euo pipefail

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCHES_REPO="$REPO_ROOT"
NEXTJS_REPO="$REPO_ROOT/../next.js"
PACKAGE_DIR="$PATCHES_REPO/package"

# Patch metadata
PATCH_NAME="pr-71759++.patch"
PATCH_FILE="$PATCHES_REPO/patches/$PATCH_NAME"
MANIFEST_PATH="$PATCHES_REPO/patches/manifest.json"

# Commits to include in pr-71759++ patch
PR_COMMITS=(
  # Original PR commit from Martin Madsen (factbird)
  ed127bb230748d7471b74c16b0532aaf42a0f808

  # Follow-up commit from same contributor
  ea98aea563173245e989ca2af84ad274c979f581

  # Local fix authored by you (runderworld)
  3017607daab6161721dcdeba286374c7f7725c19
)

# Parse flags
DRY_RUN=false
if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: ./generate-and-apply-patch.sh [--dry-run]"
  echo ""
  echo "Automates patch generation, dist diffing, and NPM publishing for Next.js."
  echo ""
  echo "Options:"
  echo "  --dry-run    Run without committing or publishing"
  echo "  --help       Show this help message"
  exit 0
elif [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "🧪 Dry-run mode enabled: no commit or publish will occur."
fi

# Prompt for upstream tag
read -rp "Enter upstream Next.js tag (e.g. v15.5.2): " TAG
BRANCH_NAME="patch-${TAG}"
DIST_PATCH_NAME="dist-${TAG}-pr71759++.patch"
DIST_PATCH_PATH="$PATCHES_REPO/patches/$DIST_PATCH_NAME"
TAG_NAME="patch-${TAG}"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Step 0: Verify both repos are clean
check_clean() {
  local repo_path="$1"
  local label="$2"
  if ! git -C "$repo_path" diff --quiet || ! git -C "$repo_path" diff --cached --quiet; then
    echo "❌ $label repo is not clean. Please commit or stash changes before running this script."
    exit 1
  fi
}

echo "🔍 Checking repo cleanliness..."
check_clean "$NEXTJS_REPO" "Next.js"
check_clean "$PATCHES_REPO" "Utility"

# Step 1: Create consolidated patch from commits
echo "🔄 Fetching upstream Next.js..."
pushd "$NEXTJS_REPO" > /dev/null
git fetch upstream --tags

echo "📍 Creating patch-stack branch from upstream/canary"
git checkout upstream/canary
git branch -D patch-stack 2>/dev/null || true
git checkout -b patch-stack

echo "🧵 Cherry-picking commits into patch-stack..."
for commit in "${PR_COMMITS[@]}"; do
  git cherry-pick "$commit"
done

echo "📦 Generating consolidated patch: $PATCH_NAME"
mkdir -p "$PATCHES_REPO/patches"
BASE_COMMIT="$(git rev-parse upstream/canary)"
git format-patch "$BASE_COMMIT" --stdout > "$PATCH_FILE"

echo "🧹 Cleaning up patch-stack"
git checkout upstream/canary
git branch -D patch-stack
popd > /dev/null

# Step 2: Rebase fork on upstream tag and apply patch
echo "📍 Rebasing fork on upstream tag: $TAG"
pushd "$NEXTJS_REPO" > /dev/null
git branch -D "$BRANCH_NAME" 2>/dev/null || true
git checkout -b "$BRANCH_NAME" "tags/$TAG"

echo "🧵 Applying patch: $PATCH_NAME"
git apply "$PATCH_FILE"

echo "📦 Installing dependencies..."
pnpm install --frozen-lockfile

echo "🔨 Building Next.js..."
pnpm build

# Step 3: Generate dist patch
DIST_PATH="packages/next/dist"
ORIGINAL_DIR="$NEXTJS_REPO/.dist-original"
rm -rf "$ORIGINAL_DIR"
cp -r "$DIST_PATH" "$ORIGINAL_DIR"

echo "🔨 Rebuilding after patch..."
pnpm build

if [ -f "$DIST_PATCH_PATH" ]; then
  echo "⚠️ Patch already exists: $DIST_PATCH_PATH"

  TMP_PATCH="$(mktemp)"
  diff -ruN "$ORIGINAL_DIR" "$DIST_PATH" > "$TMP_PATCH"

  OLD_HASH="$(sha256sum "$DIST_PATCH_PATH" | awk '{print $1}')"
  NEW_HASH="$(sha256sum "$TMP_PATCH" | awk '{print $1}')"

  if [[ "$OLD_HASH" == "$NEW_HASH" ]]; then
    echo "✅ Patch content is identical. Skipping overwrite."
    rm "$TMP_PATCH"
  else
    echo "⚠️ Patch content differs."
    read -rp "Overwrite existing patch with new content? [y/N]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
      mv "$TMP_PATCH" "$DIST_PATCH_PATH"
      echo "✅ Patch updated."
    else
      rm "$TMP_PATCH"
      echo "🛑 Aborting: patch not overwritten."
      exit 0
    fi
  fi
else
  echo "🧩 Generating new dist patch..."
  diff -ruN "$ORIGINAL_DIR" "$DIST_PATH" > "$DIST_PATCH_PATH"
fi
popd > /dev/null

# Step 4: Update manifest
echo "🗂️ Updating manifest: $MANIFEST_PATH"
if [ ! -f "$MANIFEST_PATH" ]; then echo "{}" > "$MANIFEST_PATH"; fi

jq --arg tag "$TAG" \
   --arg patch "$DIST_PATCH_NAME" \
   --arg source "$PATCH_NAME" \
   --arg time "$TIMESTAMP" \
   --argjson commits "$(printf '%s\n' "${PR_COMMITS[@]}" | jq -R . | jq -s .)" \
   '. + {($patch): {upstream: $tag, sourcePatch: $source, commits: $commits, created: $time}}' \
   "$MANIFEST_PATH" > "$MANIFEST_PATH.tmp" && mv "$MANIFEST_PATH.tmp" "$MANIFEST_PATH"

# Step 5: Commit dist patch and manifest to utility repo
if [ "$DRY_RUN" = false ]; then
  echo "📦 Committing dist patch to branch: $BRANCH_NAME"
  pushd "$PATCHES_REPO" > /dev/null
  git branch -D "$BRANCH_NAME" 2>/dev/null || true
  git checkout -b "$BRANCH_NAME"
  git add "patches/$DIST_PATCH_NAME" "patches/manifest.json"
  git commit -m "Add dist patch for Next.js $TAG with pr-71759++"
  git tag -f "$TAG_NAME"
  popd > /dev/null
else
  echo "🧪 Dry-run: skipping commit and tag creation."
fi

# Step 6: Prepare and publish NPM package
if [ "$DRY_RUN" = false ]; then
  echo "📦 Preparing NPM package for version: $TAG"
  mkdir -p "$PACKAGE_DIR"
  cp "$DIST_PATCH_PATH" "$PACKAGE_DIR/dist.patch"

  cat > "$PACKAGE_DIR/package.json" <<EOF
{
  "name": "@runderworld/next.js-patches",
  "version": "${TAG#v}",
  "description": "Dist patch overlay for Next.js ${TAG} with PR #71759++",
  "main": "dist.patch",
  "files": ["dist.patch"],
  "keywords": ["next.js", "patch", "dist", "overlay", "enterprise"],
  "author": "runderworld",
  "license": "MIT",
  "publishConfig": {
    "access": "public"
  }
}
EOF

  echo "🚀 Publishing to NPM..."
  pushd "$PACKAGE_DIR" > /dev/null
  npm publish --access public
  popd > /dev/null

  echo "🧹 Cleaning up package directory..."
  rm -rf "$PACKAGE_DIR"

  echo "✅ Patch published as @runderworld/next.js-patches@${TAG#v}"
  echo "🏷️ Git tag created: $TAG_NAME"
else
  echo "🧪 Dry-run: skipping NPM publish and cleanup."
fi

# Step 7: Final cleanup
echo "🧹 Resetting Next.js fork to pristine state..."
pushd "$NEXTJS_REPO" > /dev/null
git reset --hard
git clean -fd
