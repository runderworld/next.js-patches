#!/usr/bin/env bash
set -euo pipefail

debug_dist_diff() {
  local original_dir="$1"

  # ← added: ensure debug-log dir exists so redirection never fails
  mkdir -p "$(dirname "$3")" || echo "⚠️ Could not create debug-log directory"
  local dist_dir="$2"
  local debug_log="$3"

  {
    echo "🧪 ENTERED debug_dist_diff"
    echo "original_dir=$original_dir"
    echo "dist_dir=$dist_dir"
    echo "debug_log=$debug_log"

    if [ ! -d "$original_dir" ] || [ ! -d "$dist_dir" ]; then
      echo "🛑 One or both directories missing — skipping debug"
      return 1
    fi

    echo
    echo "🔍 File counts:"
    echo "  $(find "$original_dir" -type f | wc -l) files in original"
    echo "  $(find "$dist_dir" -type f | wc -l) files in dist"

    echo
    echo "🔍 Directory structure differences:"
    diff -qr "$original_dir" "$dist_dir" || echo "⚠️ diff -qr failed"

    echo
    echo "🔍 Sample content diff (first 5 files):"
    find "$dist_dir" -type f | head -n 5 | while read -r dist_file; do
      rel_path="${dist_file#$dist_dir/}"
      orig_file="$original_dir/$rel_path"
      if [ -f "$orig_file" ]; then
        echo "🔸 Comparing: $rel_path"
        diff -u "$orig_file" "$dist_file" || echo "⚠️ diff failed for $rel_path"
      else
        echo "⚠️ Missing original file: $rel_path"
      fi
    done
  } >> "$debug_log" 2>&1 || echo "🛑 Failed to write to debug log: $debug_log"
}

generate_dist_patch() {
  local original_dir="$1"
  local dist_dir="$2"
  local output_path="$3"

  local tmp_diff
  local tmp_patch
  tmp_diff="$(mktemp)"
  tmp_patch="$(mktemp)"

  echo "📄 Diffing $original_dir → $dist_dir"
  (diff -ruN "$original_dir" "$dist_dir" > "$tmp_diff") || true
  diff_exit=$?

  if [ "$diff_exit" -eq 0 ]; then
    echo "⚠️ No differences found — running debug inspection"
    debug_dist_diff "$original_dir" "$dist_dir" "$PATCHES_REPO/debug-diff-$TAG.log"
    rm -f "$tmp_diff"
    return 0
  elif [ "$diff_exit" -eq 1 ]; then
    echo "✅ diff found changes"
    debug_dist_diff "$original_dir" "$dist_dir" "$PATCHES_REPO/debug-diff-$TAG.log"
  elif [ "$diff_exit" -eq 2 ]; then
    echo "🛑 diff failed with fatal error"
    debug_dist_diff "$original_dir" "$dist_dir" "$PATCHES_REPO/debug-diff-$TAG.log"
    exit 1
  else
    echo "⚠️ Unexpected diff exit code: $diff_exit"
    debug_dist_diff "$original_dir" "$dist_dir" "$PATCHES_REPO/debug-diff-$TAG.log"
    exit 1
  fi

  echo "✂️ Rewriting patch headers..."
  if ! sed -E \
    -e 's|^--- .*\.dist-original/|--- a/|' \
    -e 's|^\+\+\+ .*packages/next/dist/|+++ b/|' \
    "$tmp_diff" > "$tmp_patch"; then
    echo "🛑 sed failed during header rewrite"
    exit 1
  fi

  if [ ! -s "$tmp_patch" ]; then
    echo "🛑 Patch file is empty after rewrite"
    echo "🧪 Inspect raw diff at: $tmp_diff"
    exit 1
  fi

  mv "$tmp_patch" "$output_path"
  #debug_dist_diff "$ORIGINAL_DIR" "$DIST_PATH" "$PATCHES_REPO/debug-diff-$TAG.log"
  rm -f "$tmp_diff"
  echo "✅ Patch generated: $output_path ($(wc -l < "$output_path") lines)"
}

# Required tools
REQUIRED_TOOLS=(jq pnpm git diff grep awk)
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "❌ Required tool '$tool' is not installed or not in PATH."
    echo "Please install it before running this script."
    exit 1
  fi
done

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCHES_REPO="$REPO_ROOT"
NEXTJS_REPO="$REPO_ROOT/.nextjs-fork"
PACKAGE_DIR="$PATCHES_REPO/package"

# Patch metadata
PATCH_NAME="pr-71759++.patch"
PATCH_FILE="$PATCHES_REPO/patches/$PATCH_NAME"
MANIFEST_PATH="$PATCHES_REPO/patches/manifest.json"
FINGERPRINT_TOKEN="runderworld.node.options.patch"

# Commits to include in pr-71759++ patch.
# NOTE: These commits should remain AT THE TOP of
# branch 'patch-pr71759++' in order for this to work.
PR_COMMITS=(
  # Original PR commit from Martin Madsen (factbird)
  fda4d5b1516490cea76650a80c8ecaac58f30c74

  # Follow-up commit from same contributor
  020f58dbef9bfe5e57b62e56870194fe62e02983

  # Local fix authored by you (runderworld)
  f80235400f160c4d1278ed3e336083c5c5d66a2a
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
DEFAULT_TAG="v15.5.1-canary.17"
read -p "🔖 Enter Next.js tag to patch [default: $DEFAULT_TAG]: " TAG
TAG="${TAG:-$DEFAULT_TAG}"
BRANCH_NAME="patch-${TAG}"
DIST_PATCH_NAME="dist-${TAG}-pr71759++.patch"
DIST_PATCH_PATH="$PATCHES_REPO/patches/$DIST_PATCH_NAME"
TAG_NAME="${TAG}" # ← updated: tag is now just "v15.5.2"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Clone Next.js fork into workspace
if [ -d "$NEXTJS_REPO" ]; then
  echo "🧹 Removing previous Next.js clone..."
  rm -rf "$NEXTJS_REPO"
fi

echo "🌐 Cloning Next.js fork into workspace..."
git clone --depth 10 git@github.com:runderworld/next.js.git "$NEXTJS_REPO"

# Ensures all three PR commits are available locally without triggering a massive packfile download
echo "🌐 Fetching branch on origin that contains all PR commits (patch-pr71759++)..."
git -C "$NEXTJS_REPO" fetch origin patch-pr71759++

echo "🔍 Validating presence of expected PR commits in fetched branch..."
for commit in "${PR_COMMITS[@]}"; do
  if git -C "$NEXTJS_REPO" cat-file -e "$commit" 2>/dev/null; then
    MESSAGE=$(git -C "$NEXTJS_REPO" log --format='%h %s' -n 1 "$commit")
    echo "✅ Found: $MESSAGE"
  else
    echo "🛑 Missing commit: $commit"
    exit 1
  fi
done

echo "🌐 Adding upstream remote..."
git -C "$NEXTJS_REPO" remote add upstream https://github.com/vercel/next.js.git

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

# Step 0.5: Refuse to overwrite existing patch branch
if git -C "$PATCHES_REPO" rev-parse --verify --quiet "$BRANCH_NAME"; then
  echo "🛑 Branch $BRANCH_NAME already exists. Refusing to overwrite."
  echo "This patch version has already been published. No variants allowed."
  exit 1
fi

# Step 1: Create consolidated patch from commits
echo "🔄 Fetching upstream Next.js tag and canary branch..."
pushd "$NEXTJS_REPO" > /dev/null
git fetch upstream "refs/tags/$TAG:refs/tags/$TAG" "refs/heads/canary:refs/remotes/upstream/canary" --depth=1

echo "📍 Creating patch-stack branch from upstream/canary"
git branch -D patch-stack 2>/dev/null || true
git checkout -b patch-stack "$TAG"

echo "🧵 Cherry-picking commits into patch-stack..."
for commit in "${PR_COMMITS[@]}"; do
  git cherry-pick "$commit"
done

NUM_COMMITS="${#PR_COMMITS[@]}"
echo "📦 Generating consolidated patch from $NUM_COMMITS commits: $PATCH_NAME"
mkdir -p "$PATCHES_REPO/patches"
git format-patch -"$NUM_COMMITS" --stdout > "$PATCH_FILE"

echo "🧹 Cleaning up patch-stack"
git checkout upstream/canary
git branch -D patch-stack
popd > /dev/null

# Step 2: Rebase fork on upstream tag and install deps
echo "📍 Rebasing fork on upstream tag: $TAG"
pushd "$NEXTJS_REPO" > /dev/null
git branch -D "$BRANCH_NAME" 2>/dev/null || true
git checkout -b "$BRANCH_NAME" "$TAG"

echo "📦 Installing dependencies..."
pnpm install --frozen-lockfile

echo "🔨 Building original Next.js (turbo run build --filter next)..."
# direct Turbo CLI rebuild of only the next package
pushd "$NEXTJS_REPO" > /dev/null
pnpm exec turbo run build --filter next
popd > /dev/null

# Step 3: Snapshot original dist output
DIST_PATH="$NEXTJS_REPO/packages/next/dist"
if [[ ! -d "$DIST_PATH" ]]; then
  echo "❌ Could not locate dist output directory after original build."
  exit 1
fi

ORIGINAL_DIR="$NEXTJS_REPO/.dist-original"
rm -rf "$ORIGINAL_DIR"
cp -r "$DIST_PATH" "$ORIGINAL_DIR"

# Step 3.5: Apply patch and rebuild
echo "🧵 Applying patch with git am: $PATCH_NAME"
git am "$PATCH_FILE"

# ← delete stale dist + turbo cache, then one forced rebuild
echo "🧹 Cleaning dist + Turbo cache..."
rm -rf "$DIST_PATH" "$NEXTJS_REPO/.turbo"

echo "🔨 Rebuilding patched Next.js (turbo run build --filter next --force)…"
# direct Turbo CLI: rebuild only next, force cache bust
pushd "$NEXTJS_REPO" > /dev/null
pnpm exec turbo run build --filter next --force
popd > /dev/null

# Step 3.6: Verify fingerprint before proceeding
echo "🔐 Verifying fingerprint in dist output..."
MATCH=$(grep -rnF "$FINGERPRINT_TOKEN" "$DIST_PATH" || true)
if [[ -z "$MATCH" ]]; then
  echo "❌ Fingerprint token not found in dist output."
  exit 1
else
  echo "✅ Fingerprint token found:"
  echo "$MATCH"
fi

# Step 3.7: Snapshot post-patch dist output      # ← added
PATCHED_DIR="$NEXTJS_REPO/.dist-patched"         # ← added
rm -rf "$PATCHED_DIR"                            # ← added
cp -r "$DIST_PATH" "$PATCHED_DIR"                # ← added

# Step 4: Generate dist patch
if [ -f "$DIST_PATCH_PATH" ]; then
  echo "⚠️ Patch already exists: $DIST_PATCH_PATH"

  TMP_PATCH="$(mktemp)"
  echo "🔍 Regenerating patch for comparison..."
  echo "  ORIGINAL_DIR: $ORIGINAL_DIR"
  echo "  DIST_PATH:    $DIST_PATH"
  echo "  TMP_PATCH:    $TMP_PATCH"

  pushd "$NEXTJS_REPO/packages/next" > /dev/null
  # ← modified to diff against post-patch snapshot
  generate_dist_patch "$ORIGINAL_DIR" "$PATCHED_DIR" "$TMP_PATCH"
  popd > /dev/null

  if [ ! -s "$TMP_PATCH" ]; then
    echo "🛑 TMP_PATCH is empty. Diff succeeded but no output was captured."
    rm -f "$TMP_PATCH"
    exit 1
  fi

  OLD_HASH="$(awk '{print $1}' <<< "$(shasum -a 256 "$DIST_PATCH_PATH")")"
  NEW_HASH="$(awk '{print $1}' <<< "$(shasum -a 256 "$TMP_PATCH")")"

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

  echo "🔍 Running diff between:"

  mkdir -p "$(dirname "$DIST_PATCH_PATH")"

  # Copy original snapshot into workspace for relative diffing
  cp -r "$ORIGINAL_DIR" "$NEXTJS_REPO/packages/next/original"

  pushd "$NEXTJS_REPO/packages/next" > /dev/null
  # ← modified to diff against post-patch snapshot
  generate_dist_patch "$ORIGINAL_DIR" "$PATCHED_DIR" "$DIST_PATCH_PATH"
  popd > /dev/null

  if [ ! -s "$DIST_PATCH_PATH" ]; then
    echo "🛑 Patch file is empty. Diff succeeded but no output was captured."
    exit 1
  fi

  echo "✅ Dist patch generated: $DIST_PATCH_PATH"

  if [ ! -s "$DIST_PATCH_PATH" ]; then
    echo "🛑 Patch file is empty. Diff succeeded but no output was captured."
    exit 1
  fi

  echo "✅ Dist patch generated: $DIST_PATCH_PATH"
fi
echo "✅ Reached end of patch generation block"
popd > /dev/null

# Step 5: Update manifest
echo "🗂️ Updating manifest: $MANIFEST_PATH"
if [ ! -f "$MANIFEST_PATH" ]; then echo "{}" > "$MANIFEST_PATH"; fi

jq --arg tag "$TAG" \
   --arg patch "$DIST_PATCH_NAME" \
   --arg source "$PATCH_NAME" \
   --arg time "$TIMESTAMP" \
   --argjson commits "$(printf '%s\n' "${PR_COMMITS[@]}" | jq -R . | jq -s .)" \
   '. + {($patch): {upstream: $tag, sourcePatch: $source, commits: $commits, created: $time}}' \
   "$MANIFEST_PATH" > "$MANIFEST_PATH.tmp"

echo "✅ Manifest update succeeded"
mv "$MANIFEST_PATH.tmp" "$MANIFEST_PATH"

# Step 5.5: Commit patch artifacts to utility repo
if [ "$DRY_RUN" = false ]; then
  echo "📦 Committing dist patch to branch: $BRANCH_NAME"
  pushd "$PATCHES_REPO" > /dev/null
  git checkout -b "$BRANCH_NAME"
  git add "patches/$PATCH_NAME" "patches/$DIST_PATCH_NAME" "patches/manifest.json"
  git commit -m "Add dist patch for Next.js $TAG with pr-71759++"
  git tag -f "$TAG_NAME"
  git push origin "$BRANCH_NAME"
  git push origin "$TAG_NAME"
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

  PUBLISH_SUCCESS=false
  if npm publish --access public; then
    echo "✅ Patch published as @runderworld/next.js-patches@${TAG#v}"
    echo "🏷️ Git tag created: $TAG_NAME"
    PUBLISH_SUCCESS=true
  else
    echo "🛑 NPM publish failed. Rolling back commit and tag..."

    # Remove tag and branch from utility repo
    git -C "$PATCHES_REPO" tag -d "$TAG_NAME" 2>/dev/null || true
    CURRENT_BRANCH="$(git -C "$PATCHES_REPO" rev-parse --abbrev-ref HEAD)"
    echo "🔁 Restoring utility repo to branch: $CURRENT_BRANCH"
    git -C "$PATCHES_REPO" checkout "$CURRENT_BRANCH"
    git -C "$PATCHES_REPO" branch -D "$BRANCH_NAME" 2>/dev/null || true
    git -C "$PATCHES_REPO" reset --hard HEAD~1
  fi

  popd > /dev/null

  # Always clean up Next.js workspace
  echo "🧹 Cleaning up Next.js workspace..."
  git -C "$NEXTJS_REPO" checkout upstream/canary > /dev/null 2>&1 || true
  git -C "$NEXTJS_REPO" branch -D "$BRANCH_NAME" 2>/dev/null || true
  git -C "$NEXTJS_REPO" reset --hard
  git -C "$NEXTJS_REPO" clean -fd

  # Always clean up package directory
  echo "🧹 Cleaning up package directory..."
  rm -rf "$PACKAGE_DIR"

  if [ "$PUBLISH_SUCCESS" = false ]; then
    echo "🛑 Aborted due to NPM publish failure."
    exit 1
  fi
else
  echo "🧪 Dry-run: skipping NPM publish and workspace cleanup."
fi

# Final cleanup
if [ "$DRY_RUN" = false ]; then
  echo "🧹 Removing cloned Next.js workspace..."
  rm -rf "$NEXTJS_REPO"
else
  echo "🧪 Dry-run: preserving cloned workspace for inspection."
fi

