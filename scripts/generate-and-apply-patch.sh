#!/usr/bin/env bash
set -euo pipefail

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCHES_REPO="$REPO_ROOT"
NEXTJS_REPO="$REPO_ROOT/../next.js"

# Patch metadata
PATCH_NAME="pr-71759++.patch"
PATCH_FILE="$PATCHES_REPO/patches/$PATCH_NAME"
MANIFEST_PATH="$PATCHES_REPO/patches/manifest.json"

# Commits to include
PR_COMMITS=(
  ed127bb230748d7471b74c16b0532aaf42a0f808
  ea98aea563173245e989ca2af84ad274c979f581
  3017607daab6161721dcdeba286374c7f7725c19
)

# Prompt for upstream tag
read -rp "Enter upstream Next.js tag (e.g. v15.5.2): " TAG
BRANCH_NAME="patch-${TAG}"
DIST_PATCH_NAME="dist-${TAG}-pr71759++.patch"
DIST_PATCH_PATH="$PATCHES_REPO/patches/$DIST_PATCH_NAME"
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
  read -rp "Overwrite existing patch? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "🛑 Aborting: patch not overwritten."
    exit 0
  fi
fi

echo "🧩 Generating dist patch..."
diff -ruN "$ORIGINAL_DIR" "$DIST_PATH" > "$DIST_PATCH_PATH"
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
echo "📦 Committing dist patch to branch: $BRANCH_NAME"
pushd "$PATCHES_REPO" > /dev/null
git branch -D "$BRANCH_NAME" 2>/dev/null || true
git checkout -b "$BRANCH_NAME"
git add "patches/$DIST_PATCH_NAME" "patches/manifest.json"
git commit -m "Add dist patch for Next.js $TAG with pr-71759++"
popd > /dev/null

echo "✅ Patch committed on branch: $BRANCH_NAME"

