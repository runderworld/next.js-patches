#!/usr/bin/env bash
set -euo pipefail

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NEXTJS_REPO="$REPO_ROOT/../next.js"
PATCHES_REPO="$REPO_ROOT"
PATCH_FILE="$PATCHES_REPO/patches/pr-71759++.patch"

# Prompt for upstream tag
read -rp "Enter upstream Next.js tag (e.g. v15.5.2): " TAG
BRANCH_NAME="patch-${TAG}"

# Step 1: Update fork and rebase on upstream
pushd "$NEXTJS_REPO" > /dev/null
echo "🔄 Fetching upstream..."
git fetch upstream --tags

echo "📍 Checking out tag $TAG"
git checkout -b "$BRANCH_NAME" "tags/$TAG"

echo "🧵 Applying patch: $PATCH_FILE"
git apply "$PATCH_FILE"

# Step 2: Build
echo "📦 Installing dependencies..."
pnpm install --frozen-lockfile

echo "🔨 Building Next.js..."
pnpm build

# Step 3: Generate dist patch
DIST_PATH="packages/next/dist"
ORIGINAL_DIR="$NEXTJS_REPO/.dist-original"
PATCH_OUTPUT="$PATCHES_REPO/patches/dist-${TAG}-pr71759++.patch"

echo "📁 Capturing original dist for diff..."
rm -rf "$ORIGINAL_DIR"
cp -r "$DIST_PATH" "$ORIGINAL_DIR"

echo "📁 Rebuilding after patch..."
pnpm build

echo "🧩 Generating dist patch..."
diff -ruN "$ORIGINAL_DIR" "$DIST_PATH" > "$PATCH_OUTPUT"

# Step 4: Commit dist patch to utility repo
popd > /dev/null
pushd "$PATCHES_REPO" > /dev/null
git checkout -b "$BRANCH_NAME"
git add "patches/dist-${TAG}-pr71759++.patch"
git commit -m "Add dist patch for Next.js $TAG with pr-71759++"
echo "✅ Patch committed on branch: $BRANCH_NAME"
popd > /dev/null

