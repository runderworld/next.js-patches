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

# Patch metadata (shared)
MANIFEST_PATH="patches/manifest.json"
FINGERPRINT_TOKEN="runderworld.node.options.patch"

# ── Patch configuration ─────────────────────────────────────────────────────
# Resolved after TAG is known (see resolve_patch_config below).
# These variables are set by resolve_patch_config():
#   SRC_PATCH_NAME   – source patch filename  (e.g. fix-node-options-v16-2.patch)
#   PR_BRANCH        – origin branch that contains the fix commits
#   PATCHED_FILES    – dist files affected by the patch
#   PR_COMMITS       – hardcoded array of fix commit hashes (cherry-pick order)

resolve_patch_config() {
  local tag="$1"
  local major minor patch_minor patch_variant
  major="$(echo "${tag#v}" | cut -d. -f1)"
  minor="$(echo "${tag#v}" | cut -d. -f2)"

  # ── Resolve patch variant by minor-range fallback ─────────────────────
  # A defined variant applies from its minor up to (but not including)
  # the next higher defined minor. The highest defined variant applies to
  # all higher minors in the same major.
  case "$major" in
    15)
      # Defined variants: 15.4+
      if (( minor >= 4 )); then
        patch_minor=4
      fi
      ;;
    16)
      # Defined variants: 16.0-16.1 => 16.0, 16.2+ => 16.2
      if (( minor >= 2 )); then
        patch_minor=2
      elif (( minor >= 0 )); then
        patch_minor=0
      fi
      ;;
    *)
      patch_minor=""
      ;;
  esac

  if [[ -z "${patch_minor:-}" ]]; then
    echo "🛑 No patch variant mapped for v${major}.${minor} (tag: $tag)"
    echo "   Known lower bounds: 15.4, 16.0, 16.2"
    exit 1
  fi

  patch_variant="${major}.${patch_minor}"

  # ── Naming convention ─────────────────────────────────────────────────
  # Branch:     fix/node-options-v<major>-<resolved-minor>
  # Patch file: fix-node-options-v<major>-<resolved-minor>.patch
  PR_BRANCH="fix/node-options-v${major}-${patch_minor}"
  SRC_PATCH_NAME="fix-node-options-v${major}-${patch_minor}.patch"

  # ── Dist files affected (shared across all versions) ──────────────────
  local shared_files=(
    node_modules/next/dist/cli/next-dev.js
    node_modules/next/dist/cli/next-dev.js.map
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

  # ── Per-major version: extra patched files ─────────────────────────────
  case "$major" in
    15)
      # v15.x bundles utils into compiled runtime bundles
      PATCHED_FILES=(
        "${shared_files[@]}"
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
      )
      ;;
    16)
      # v16.x does not bundle utils into compiled runtimes
      PATCHED_FILES=("${shared_files[@]}")
      ;;
    *)
      echo "🛑 Unsupported major version: $major (tag: $tag)"
      echo "   Only v15.x and v16.x are supported."
      exit 1
      ;;
  esac

  # ── Hardcoded fix commits per major.minor ────────────────────────────────
  # These are the commits on origin/<PR_BRANCH> AFTER the base tag commit.
  # Order: oldest → newest (cherry-pick order).
  case "$patch_variant" in
    15.4)
      PR_COMMITS=(
        2f67c2628d   # Account for positional option values and support repeated options
        9effe5e72a   # Safely extract the first inspect value
        c68c2c6589   # fix: wrap node option assignments in arrays for compatibility
        8c772ac17f   # chore: add build-time fingerprint for patch verification
      )
      ;;
    16.0)
      PR_COMMITS=(
        8604ded8b3   # fix: correct parseNodeArgs and formatNodeOptions processing
        781a6ee519   # chore: add build-time fingerprint for patch verification
      )
      ;;
    16.2)
      PR_COMMITS=(
        f829467a9c   # fix: correct parseNodeArgs and formatNodeOptions processing
        fb888e493a   # chore: add build-time fingerprint for patch verification
      )
      ;;
    *)
      echo "🛑 No fix commits defined for resolved variant v${patch_variant} (tag: $tag)"
      echo "   Known variants: 15.4, 16.0, 16.2"
      exit 1
      ;;
  esac

  PATCH_FILE="$PATCHES_REPO/patches/$SRC_PATCH_NAME"
  echo "📋 Resolved patch config for v${major}.${minor}:"
  echo "   Patch variant: v${patch_variant}"
  echo "   Source patch:  $SRC_PATCH_NAME"
  echo "   PR branch:    $PR_BRANCH"
  echo "   Fix commits:  ${#PR_COMMITS[@]}"
}

# Parse flags
DRY_RUN=false
FORCE_REFRESH=false
CLEAN_NEXT=false
PUBLISH_VERSION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --force-refresh) FORCE_REFRESH=true ;;
    --clean-next) CLEAN_NEXT=true ;;
    --publish-version)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "❌ --publish-version requires a version argument (e.g. --publish-version 16.2.3-1)" >&2
        exit 1
      fi
      shift
      PUBLISH_VERSION_OVERRIDE="$1"
      ;;
    --help)
      echo "Usage: ./generate-and-apply-patch.sh [--dry-run] [--force-refresh] [--clean-next] [--publish-version <ver>]"
      echo ""
      echo "Options:"
      echo "  --dry-run                Run without committing or publishing"
      echo "  --force-refresh          Delete and reclone Next.js workspace"
      echo "  --clean-next             Force clean rebuild of Next.js (dist + turbo cache)"
      echo "  --publish-version <ver>  Override the NPM publish version (e.g. 16.2.3-1)."
      echo "                           Use when the original version was already published."
      echo "                           The upstream tag is still used for patch generation."
      echo "  --help                   Show this help message"
      exit 0
      ;;
  esac
  shift
done

# Resolve upstream tag to patch (interactive prompt omitted in CI)
DEFAULT_TAG="$(npm info next dist-tags.canary 2>/dev/null || echo '16.2.0-canary.42')"
DEFAULT_TAG="v${DEFAULT_TAG#v}"  # ensure it starts with 'v'
echo "ℹ️ next@latest:   $(npm info next dist-tags.latest 2>/dev/null || echo 'n/a')"
echo "ℹ️ next@canary:   $(npm info next dist-tags.canary 2>/dev/null || echo 'n/a')"
echo "ℹ️ @runderworld/next.js-patches@latest: $(npm info @runderworld/next.js-patches dist-tags.latest 2>/dev/null || echo 'n/a')"

# Allow TAG to be passed in via env or --tag to support non-interactive CI runs.
if [[ -n "${TAG:-}" ]]; then
  echo "🔖 Using TAG from environment: $TAG"
elif [[ -n "${CI:-}" && -n "${DEFAULT_TAG:-}" ]]; then
  # In CI default to the canary tag when not provided
  TAG="$DEFAULT_TAG"
  echo "🔖 CI detected — using default TAG: $TAG"
else
  # Interactive fallback
  read -p "🔖 Enter Next.js tag to patch [default: $DEFAULT_TAG]: " TAG
  TAG="${TAG:-$DEFAULT_TAG}"
fi

[[ "$TAG" != v* ]] && TAG="v$TAG"

# Resolve v15/v16 patch config based on tag
resolve_patch_config "$TAG"

# Derive publish version — defaults to the upstream tag version unless overridden.
# PUBLISH_VERSION  = semver string for NPM (e.g. "16.2.3" or "16.2.3-1")
# PUBLISH_TAG      = git tag for the utility repo (e.g. "v16.2.3" or "v16.2.3-1")
if [[ -n "$PUBLISH_VERSION_OVERRIDE" ]]; then
  PUBLISH_VERSION="${PUBLISH_VERSION_OVERRIDE#v}"
  echo "📦 Publish version overridden: ${PUBLISH_VERSION} (upstream tag: ${TAG})"
else
  PUBLISH_VERSION="${TAG#v}"
fi
PUBLISH_TAG="v${PUBLISH_VERSION}"

BRANCH_NAME="patch-${TAG}"
# Dist patch: dist--<source-patch-name>  (e.g. dist--fix-node-options-v16-2.patch)
DIST_PATCH_NAME="dist--${SRC_PATCH_NAME}"
DIST_PATCH_PATH="$PATCHES_REPO/patches/$DIST_PATCH_NAME"

if [ "$FORCE_REFRESH" = true ]; then
  echo "🔁 Force-refresh: removing existing Next.js workspace..."
  rm -rf "$NEXTJS_REPO"
fi

if [ -d "$NEXTJS_REPO/.git" ]; then
  echo "🔄 Reusing existing Next.js workspace..."
  pushd "$NEXTJS_REPO" > /dev/null
  git fetch origin "${PR_BRANCH}:refs/remotes/origin/${PR_BRANCH}" --update-head-ok
  git fetch upstream "refs/tags/$TAG:refs/tags/$TAG" "+refs/heads/canary:refs/remotes/upstream/canary" --depth=1
  popd > /dev/null
else
  echo "🌐 Cloning Next.js fork into workspace..."
  # Allow CI to use HTTPS clone if SSH is not available. Set CLONE_PROTOCOL=https to force HTTPS.
  if [[ "${CLONE_PROTOCOL:-}" == "https" || -n "${CI:-}" && -z "${GIT_SSH_COMMAND:-}" ]]; then
    git clone https://github.com/runderworld/next.js.git "$NEXTJS_REPO"
  else
    git clone git@github.com:runderworld/next.js.git "$NEXTJS_REPO"
  fi
fi

# Fetch the fix branch so cherry-pick can resolve the commit hashes
echo "🌐 Fetching fix branch from origin ($PR_BRANCH)..."
git -C "$NEXTJS_REPO" fetch origin "${PR_BRANCH}:refs/remotes/origin/${PR_BRANCH}"

echo "📋 Will cherry-pick ${#PR_COMMITS[@]} hardcoded commit(s) from $PR_BRANCH:"
for commit in "${PR_COMMITS[@]}"; do
  MESSAGE=$(git -C "$NEXTJS_REPO" log --format='  %h %s' -n 1 "$commit" 2>/dev/null || echo "  $commit (not yet fetched)")
  echo "$MESSAGE"
done

echo "🌐 Adding upstream remote..."
git -C "$NEXTJS_REPO" remote get-url upstream >/dev/null 2>&1 || \
  git -C "$NEXTJS_REPO" remote add upstream https://github.com/vercel/next.js.git

# Step 0: Verify both repos are clean
check_clean() {
  local repo_path="$1"
  local label="$2"
  
  if ! git -C "$repo_path" diff --quiet || ! git -C "$repo_path" diff --cached --quiet; then
    if [[ "$label" == "Next.js" ]]; then
      echo "⚠️ $label repo is not clean (likely from a failed cherry-pick)."
      echo "🧹 Attempting auto-cleanup..."
      git -C "$repo_path" cherry-pick --abort 2>/dev/null || true
      git -C "$repo_path" rebase --abort 2>/dev/null || true
      git -C "$repo_path" am --abort 2>/dev/null || true
      git -C "$repo_path" checkout upstream/canary 2>/dev/null || true
      git -C "$repo_path" branch -D patch-stack 2>/dev/null || true
      git -C "$repo_path" reset --hard 2>/dev/null || true
      git -C "$repo_path" clean -fd 2>/dev/null || true
      
      if git -C "$repo_path" diff --quiet && git -C "$repo_path" diff --cached --quiet; then
        echo "✅ $label repo cleaned up successfully."
        return 0
      else
        echo "❌ Failed to clean $label repo. Please manually resolve."
        exit 1
      fi
    else
      echo "❌ $label repo is not clean. Please commit or stash changes before running this script."
      exit 1
    fi
  fi
}

echo "🔍 Checking repo cleanliness..."
check_clean "$NEXTJS_REPO" "Next.js"
check_clean "$PATCHES_REPO" "Utility"

# Step 0.5: Refuse to overwrite existing patch branch (utility repo)
PUBLISH_BRANCH="patch-v${PUBLISH_VERSION}"
if git -C "$PATCHES_REPO" rev-parse --verify --quiet "$PUBLISH_BRANCH"; then
  echo "🛑 Branch $PUBLISH_BRANCH already exists in utility repo. Refusing to overwrite."
  echo "   Use --publish-version to publish under a different version string."
  exit 1
fi

# Step 1: Create consolidated patch from commits
pushd "$NEXTJS_REPO" > /dev/null

echo "📍 Creating patch-stack branch from upstream/canary"
git branch -D patch-stack 2>/dev/null || true
git checkout -b patch-stack "$TAG"

echo "🧵 Cherry-picking commits into patch-stack..."
for commit in "${PR_COMMITS[@]}"; do
  if ! git cherry-pick "$commit"; then
    echo "❌ Cherry-pick failed for $commit (likely merge conflict)"
    echo "🧹 Aborting cherry-pick and cleaning up..."
    git cherry-pick --abort || true
    git checkout upstream/canary 2>/dev/null || true
    git branch -D patch-stack 2>/dev/null || true
    popd > /dev/null
    echo "🧹 Cleaned up Next.js workspace. Please resolve the upstream divergence and try again."
    exit 1
  fi
done

NUM_COMMITS="${#PR_COMMITS[@]}"
echo "📦 Generating consolidated patch from $NUM_COMMITS commits: $SRC_PATCH_NAME"
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
# Run pnpm non-interactively to avoid prompting about removing modules directories
# See: https://github.com/pnpm/pnpm/issues/7727
pnpm install --frozen-lockfile --config.confirmModulesPurge=false

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
echo "🧵 Applying patch with git am: $SRC_PATCH_NAME"
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
rm -rf "$PATCH_TEMP"
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

# Step 4(b): Initialize Git and commit only the files we'll patch (clean baseline)
git init -q
for file in "${PATCHED_FILES[@]}"; do
  if [[ -f "$file" ]]; then
    git add "$file"
  else
    echo "❌ Missing expected baseline file: $file"
    popd > /dev/null
    rm -rf "$PATCH_TEMP"
    exit 1
  fi
done
git commit -q -m "clean next install"

# Step 4(c): Overwrite only the patched files with your patched output
# (Copying the entire dist tree causes git to choke on long filenames
#  inside dist/compiled when patch-package tries to diff.)
echo "📁 Copying patched files:"
for file in "${PATCHED_FILES[@]}"; do
  src="$NEXTJS_REPO/packages/next/${file#node_modules/next/}"
  if [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$file")"
    cp "$src" "$file"
    echo "  ✓ $file"
  else
    echo "❌ Missing patched source: $src"
    popd > /dev/null
    rm -rf "$PATCH_TEMP"
    exit 1
  fi
done

# Step 4(d): Stage only the affected patched files
for file in "${PATCHED_FILES[@]}"; do
  if [[ -f "$file" ]]; then
    git add "$file"
  else
    echo "❌ Missing expected patched file: $file"
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

STRIPPED_TAG="${TAG#v}"
BRANCH="patch-v${PUBLISH_VERSION}"
DIST_PATCH_NAME="$(basename "$DIST_PATCH_PATH")"

# ── Cleanup helper ──────────────────────────────────────────────────────────
# Centralised teardown so every failure path does the same thing.
#   $1 = "full"  → undo git branch/tag + nextjs workspace
#        "next"  → nextjs workspace only (git not yet touched)
cleanup_on_failure() {
  local scope="${1:-full}"

  if [[ "$scope" == "full" ]]; then
    echo "🧹 Rolling back git operations in patches repo..."
    # Remote tag
    git push origin ":refs/tags/${PUBLISH_TAG}" 2>/dev/null || true
    # Local tag
    git tag -d "${PUBLISH_TAG}" 2>/dev/null || true
    # Remote branch
    git push origin --delete "${BRANCH}" 2>/dev/null || true
    # Switch off the branch before deleting it
    git checkout main 2>/dev/null || git checkout - 2>/dev/null || true
    # Local branch
    git branch -D "${BRANCH}" 2>/dev/null || true
    # Reset any uncommitted leftovers
    git reset --hard HEAD 2>/dev/null || true
  fi

  echo "🧹 Cleaning up Next.js workspace..."
  git -C "$NEXTJS_REPO" checkout upstream/canary >/dev/null 2>&1 || true
  git -C "$NEXTJS_REPO" branch -D "$BRANCH_NAME" 2>/dev/null || true
  git -C "$NEXTJS_REPO" reset --hard
  git -C "$NEXTJS_REPO" clean -fd

  echo "🧹 Cleaning up package directory..."
  rm -rf "$PACKAGE_DIR"
}

# From this point on, any unexpected failure should trigger cleanup.
# (Explicit error paths call cleanup_on_failure directly, but this
# catches anything killed by set -e that we didn't wrap.)
trap 'echo "🛑 Unexpected failure — cleaning up..."; cleanup_on_failure full' ERR

# Step 5: Commit dist + source patches to a new branch, tag, and push
echo "📦 Creating and switching to branch: ${BRANCH}"
git checkout -b "${BRANCH}"

echo "📦 Staging patches..."
git add "patches/${DIST_PATCH_NAME}"
git add "patches/${SRC_PATCH_NAME}"

if [[ -f "$MANIFEST_PATH" ]]; then
  echo "📦 Staging manifest: ${MANIFEST_PATH##*/}"
  git add "$MANIFEST_PATH"
fi

echo "📦 Committing patches"
git commit -q -m "chore: add source & dist patches for next ${STRIPPED_TAG} (publish: ${PUBLISH_VERSION})"

if [ "$DRY_RUN" = false ]; then
  if ! git push --set-upstream origin "${BRANCH}"; then
    echo "🛑 git push failed (branch: ${BRANCH})." >&2
    cleanup_on_failure full
    exit 1
  fi

  git tag -f "${PUBLISH_TAG}"

  if ! git push origin "${PUBLISH_TAG}"; then
    echo "🛑 git push failed (tag: ${PUBLISH_TAG})." >&2
    cleanup_on_failure full
    exit 1
  fi

  echo "🏷️ Git tag created: ${PUBLISH_TAG}"
else
  echo "🧪 Dry-run: skipping git push and tag"
fi

# Step 6: Prepare and publish NPM package
if [ "$DRY_RUN" = false ]; then
  echo "📦 Preparing NPM package for version: ${PUBLISH_VERSION}"
  mkdir -p "$PACKAGE_DIR"
  cp "$DIST_PATCH_PATH" "$PACKAGE_DIR/dist.patch"

  cat > "$PACKAGE_DIR/package.json" <<EOF
{
  "name": "@runderworld/next.js-patches",
  "version": "${PUBLISH_VERSION}",
  "description": "Dist patch overlay for Next.js ${TAG} with ${SRC_PATCH_NAME%.patch}",
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

  if ! npm publish --access public; then
    echo "🛑 NPM publish failed." >&2
    echo "   (The dist patch is saved at: $DIST_PATCH_PATH)"
    popd > /dev/null
    cleanup_on_failure full
    exit 1
  fi

  echo "✅ Patch published as @runderworld/next.js-patches@${PUBLISH_VERSION}"
  popd > /dev/null
  rm -rf "$PACKAGE_DIR"
else
  echo "🧪 Dry-run: skipping NPM publish."
fi

# Step 7: Cleanup — clear the ERR trap first so normal teardown doesn't trigger it
trap - ERR

if [ "$DRY_RUN" = false ]; then
  echo "🧹 Cleaning up Next.js workspace..."
  git -C "$NEXTJS_REPO" checkout upstream/canary >/dev/null 2>&1 || true
  git -C "$NEXTJS_REPO" branch -D "$BRANCH_NAME" 2>/dev/null || true
  git -C "$NEXTJS_REPO" reset --hard
  git -C "$NEXTJS_REPO" clean -fd
fi

# Final cleanup
if [ "$DRY_RUN" = false ]; then
  if [ "$FORCE_REFRESH" = true ]; then
    echo "🧹 Removing cloned Next.js workspace..."
    rm -rf "$NEXTJS_REPO"
  else
    echo "🧪 Preserving cloned workspace for reuse."
  fi

  echo "🔀 Switching back to main branch..."
  git checkout main
else
  echo "🧪 Dry-run: preserving cloned workspace for inspection."
fi
