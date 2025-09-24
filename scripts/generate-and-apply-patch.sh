#!/usr/bin/env bash
set -euo pipefail

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
MANIFEST_PATH="patches/manifest.json"
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
FORCE_REFRESH=false
CLEAN_NEXT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --force-refresh) FORCE_REFRESH=true ;;
    --clean-next) CLEAN_NEXT=true ;;
    --tag=*) TAG="${1#*=}" ;;
    --help)
      echo "Usage: ./generate-and-apply-patch.sh [--tag=VERSION] [--dry-run] [--force-refresh] [--clean-next]"
      echo ""
      echo "Options:"
      echo "  --tag=VERSION    Specify Next.js version tag (e.g. v13.5.6)"
      echo "  --dry-run        Run without committing or publishing"
      echo "  --force-refresh  Delete and reclone Next.js workspace"
      echo "  --clean-next     Force clean rebuild of Next.js (dist + turbo cache)"
      echo "  --help           Show this help message"
      exit 0
      ;;
  esac
  shift
done

# Prompt for upstream tag (and provide current canary version as default)
DEFAULT_TAG="$(npm info next dist-tags.canary 2>/dev/null || echo '15.6.0-canary.10')"
DEFAULT_TAG="v${DEFAULT_TAG#v}"  # ensure it starts with 'v'
echo "ℹ️ next@latest:   $(npm info next dist-tags.latest 2>/dev/null || echo 'n/a')"
echo "ℹ️ next@canary:   $(npm info next dist-tags.canary 2>/dev/null || echo 'n/a')"
echo "ℹ️ @runderworld/next.js-patches@latest: $(npm info @runderworld/next.js-patches dist-tags.latest 2>/dev/null || echo 'n/a')"
if [[ -z "${TAG:-}" ]]; then
  echo "🔖 No tag provided via --tag; using default: $DEFAULT_TAG"
  TAG="$DEFAULT_TAG"
else
  echo "🔖 Using provided tag: $TAG"
fi
[[ "$TAG" != v* ]] && TAG="v$TAG"
BRANCH_NAME="patch-${TAG}"
DIST_PATCH_NAME="dist-${TAG}-pr71759++.patch"
DIST_PATCH_PATH="$PATCHES_REPO/patches/$DIST_PATCH_NAME"

if [ "$FORCE_REFRESH" = true ]; then
  echo "🔁 Force-refresh: removing existing Next.js workspace..."
  rm -rf "$NEXTJS_REPO"
fi

if [ -d "$NEXTJS_REPO/.git" ]; then
  echo "🔄 Reusing existing Next.js workspace..."
  pushd "$NEXTJS_REPO" > /dev/null
  git fetch origin patch-pr71759++ --update-head-ok
  git fetch upstream "refs/tags/$TAG:refs/tags/$TAG" "+refs/heads/canary:refs/remotes/upstream/canary" --depth=1
  popd > /dev/null
else
  echo "🌐 Cloning Next.js fork into workspace..."
  git clone git@github.com:runderworld/next.js.git "$NEXTJS_REPO"
fi

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
git -C "$NEXTJS_REPO" remote get-url upstream >/dev/null 2>&1 || \
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
pushd "$NEXTJS_REPO" > /dev/null

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

# Step 3.5: Apply patch and rebuild
echo "🧵 Applying patch with git am: $PATCH_NAME"
git am "$PATCH_FILE"

if [ "$CLEAN_NEXT" = true ]; then
  echo "🧹 Cleaning dist + Turbo cache (--clean-next enabled)..."
  rm -rf "$DIST_PATH" "$NEXTJS_REPO/.turbo"
else
  echo "🧪 Skipping dist cleanup (default; no --clean-next flag)"
fi

if [ "$CLEAN_NEXT" = true ]; then
  echo "🔨 Clean rebuilding Next.js (--clean-next enabled)"
  pnpm exec turbo run build --filter next --force --no-cache
else
  echo "🔄 Incremental rebuild of Next.js (default; no --clean-next flag)"
  pnpm exec turbo run build --filter next
fi
popd > /dev/null

# ← now snapshot the rebuilt `dist` into `.dist-patched`
echo "📸 Capturing patched snapshot..."

# Step 3.6: Verify fingerprint before proceeding
echo "🔐 Verifying fingerprint in dist output..."
MATCH=$(grep -rnF "$FINGERPRINT_TOKEN" "$DIST_PATH" || true)
if [[ -z "$MATCH" ]]; then
  echo "❌ Fingerprint token not found in dist output."
  exit 1
else
  echo "✅ Fingerprint token found!"
  #echo "$MATCH"
fi

# Step 4: Generate dist patch with patch-package using a temp workspace
echo "🧩 Generating dist patch with patch-package..."

PATCH_TEMP="$PATCHES_REPO/.patch-temp"
mkdir -p "$PATCH_TEMP"
pushd "$PATCH_TEMP" > /dev/null

# Step 4(a): Install official registry version of Next.js
cat > package.json <<EOF
{
  "name": "patch-temp",
  "version": "1.0.0",
  "dependencies": {
    "next": "${TAG#v}"
  }
}
EOF

if ! npm install --silent; then
  echo "🛑 Failed to install registry version of Next.js"
  popd > /dev/null
  rm -rf "$PATCH_TEMP"
  exit 1
fi

# Step 4(b): Initialize Git and commit clean baseline
git init -q
git add node_modules/next
git commit -q -m "clean next install"

# Step 4(c): Overwrite dist/ with your patched output
rm -rf node_modules/next/dist
cp -R "$NEXTJS_REPO/packages/next/dist" "node_modules/next/"
echo "📁 Verifying copied dist files:"
ls node_modules/next/dist/cli/next-dev.js \
  || echo "❌ Missing: next-dev.js"
ls node_modules/next/dist/compiled/next-server/pages.runtime.dev.js \
  || echo "❌ Missing: pages.runtime.dev.js"

# Step 4(d): Unstage everything and stage only the affected files
git reset

PATCHED_FILES=(
  node_modules/next/dist/cli/next-dev.js
  node_modules/next/dist/cli/next-dev.js.map
  node_modules/next/dist/compiled/next-server/app-page-experimental.runtime.dev.js
  node_modules/next/dist/compiled/next-server/app-page-experimental.runtime.dev.js.map
  node_modules/next/dist/compiled/next-server/app-page-turbo-experimental.runtime.dev.js
  node_modules/next/dist/compiled/next-server/app-page-turbo-experimental.runtime.dev.js.map
  node_modules/next/dist/compiled/next-server/app-page-turbo.runtime.dev.js
  node_modules/next/dist/compiled/next-server/app-page-turbo.runtime.dev.js.map
  node_modules/next/dist/compiled/next-server/app-page.runtime.dev.js
  node_modules/next/dist/compiled/next-server/app-page.runtime.dev.js.map
  node_modules/next/dist/compiled/next-server/pages-api-turbo.runtime.dev.js
  node_modules/next/dist/compiled/next-server/pages-api-turbo.runtime.dev.js.map
  node_modules/next/dist/compiled/next-server/pages-api.runtime.dev.js
  node_modules/next/dist/compiled/next-server/pages-api.runtime.dev.js.map
  node_modules/next/dist/compiled/next-server/pages-turbo.runtime.dev.js
  node_modules/next/dist/compiled/next-server/pages-turbo.runtime.dev.js.map
  node_modules/next/dist/compiled/next-server/pages.runtime.dev.js
  node_modules/next/dist/compiled/next-server/pages.runtime.dev.js.map
  node_modules/next/dist/esm/lib/worker.js
  node_modules/next/dist/esm/lib/worker.js.map
  node_modules/next/dist/esm/server/lib/utils.js
  node_modules/next/dist/esm/server/lib/utils.js.map
  node_modules/next/dist/lib/worker.js
  node_modules/next/dist/lib/worker.js.map
  node_modules/next/dist/server/lib/utils.d.ts
  node_modules/next/dist/server/lib/utils.js
  node_modules/next/dist/server/lib/utils.js.map
)

for file in "${PATCHED_FILES[@]}"; do
  if [[ -f "$file" ]]; then
    git add "$file"
  else
    echo "❌ Missing expected file: $file"
    popd > /dev/null
    rm -rf "$PATCH_TEMP"
    exit 1
  fi
done

if ! git commit -q -m "patched dist files"; then
  echo "🛑 Git commit failed—no files staged"
  popd > /dev/null
  rm -rf "$PATCH_TEMP"
  exit 1
fi

# Step 4(e): Run forked patch-package@8 to generate patch in v8 format
if ! npx @unts/patch-package@^8 next --patch-dir "../patches"; then
  echo "🛑 @unts/patch-package v8 failed"
  popd > /dev/null
  rm -rf "$PATCH_TEMP"
  exit 1
fi

# Step 4(f): Cleanup
popd > /dev/null
rm -rf "$PATCH_TEMP"

# Step 4(g): Output patch summary and rename
STRIPPED_TAG="${TAG#v}"
PATCH_NAME="next+${STRIPPED_TAG}.patch"
PATCH_FILE_PATH="$PATCHES_REPO/patches/$PATCH_NAME"

echo "📁 Files touched:"
grep '^+++' "$PATCH_FILE_PATH" | sort | uniq -c

if [[ -f "$PATCH_FILE_PATH" ]]; then
  mv "$PATCH_FILE_PATH" "$DIST_PATCH_PATH"
  echo "✅ Dist patch generated: $DIST_PATCH_PATH"
else
  echo "🛑 patch-package did not produce 'next+${STRIPPED_TAG}.patch'"
  exit 1
fi

echo "✅ Reached end of patch generation block"

# Step 5: Commit dist + source patches to a new branch and push
STRIPPED_TAG="${TAG#v}"
BRANCH="patch-v${STRIPPED_TAG}"
PATCH_NAME="pr-71759++.patch"    # ← restore the source-patch filename here

# Derive these from your existing DIST_PATCH_PATH and PATCH_NAME
DIST_PATCH_NAME="$(basename "$DIST_PATCH_PATH")"   # e.g. dist-v15.6.0-canary.14-pr71759++.patch

echo "📦 Creating and switching to branch: ${BRANCH}"
git checkout -b "${BRANCH}"

echo "📦 Staging patches..."
git add "patches/${DIST_PATCH_NAME}"
git add "patches/${PATCH_NAME}"

if [[ -f "$MANIFEST_PATH" ]]; then
  echo "📦 Staging manifest: ${MANIFEST_PATH##*/}"
  git add "$MANIFEST_PATH"
fi

echo "📦 Committing patches"
git commit -q -m "chore: add source & dist patches for next ${STRIPPED_TAG}"

# Push to remote
if [ "$DRY_RUN" = false ]; then
  git push --set-upstream origin "${BRANCH}"
  git tag -f "${TAG}"
  git push origin "${TAG}"
else
  echo "🧪 Dry-run: skipping push"
fi

# Step 6: Prepare and publish NPM package
if [ "$DRY_RUN" = false ]; then
  echo "📦 Preparing NPM package for version: ${TAG#v}"
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
    echo "🏷️ Git tag created: ${TAG}"
    PUBLISH_SUCCESS=true
  else
    echo "🛑 NPM publish failed. Rolling back commit and tag..."
    git -C "$PATCHES_REPO" tag -d "${TAG}" 2>/dev/null || true
    CURRENT_BRANCH="$(git -C "$PATCHES_REPO" rev-parse --abbrev-ref HEAD)"
    git -C "$PATCHES_REPO" checkout "$CURRENT_BRANCH"
    git -C "$PATCHES_REPO" branch -D "${BRANCH}" 2>/dev/null || true
    git -C "$PATCHES_REPO" reset --hard HEAD~1
  fi

  popd > /dev/null

  # Cleanup Next.js workspace
  echo "🧹 Cleaning up Next.js workspace..."
  git -C "$NEXTJS_REPO" checkout upstream/canary >/dev/null 2>&1 || true
  git -C "$NEXTJS_REPO" branch -D "${BRANCH}" 2>/dev/null || true
  git -C "$NEXTJS_REPO" reset --hard
  git -C "$NEXTJS_REPO" clean -fd

  # Cleanup package directory
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
  if [ "$FORCE_REFRESH" = true ]; then
    echo "🧹 Removing cloned Next.js workspace..."
    rm -rf "$NEXTJS_REPO"
  else
    echo "🧪 Preserving cloned workspace for reuse."
  fi
else
  echo "🧪 Dry-run: preserving cloned workspace for inspection."
fi
