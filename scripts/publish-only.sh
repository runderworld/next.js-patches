#!/usr/bin/env bash
set -euo pipefail

# Required tools
REQUIRED_TOOLS=(jq npm)
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "❌ Required tool '$tool' is not installed or not in PATH." >&2
    exit 1
  fi
done

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCHES_DIR="$REPO_ROOT/patches"
PACKAGE_DIR="$REPO_ROOT/package"

# ── Resolve dist patch filename from tag ─────────────────────────────────────
# Matches the naming convention in generate-and-apply-patch.sh:
#   dist--fix-node-options-v<major>-<minor>.patch
resolve_dist_patch_name() {
  local tag="$1"
  local major minor
  major="$(echo "${tag#v}" | cut -d. -f1)"
  minor="$(echo "${tag#v}" | cut -d. -f2)"

  case "$major" in
    15|16) ;;
    *)
      echo "🛑 Unsupported major version: $major (tag: $tag)" >&2
      exit 1
      ;;
  esac

  SRC_PATCH_NAME="fix-node-options-v${major}-${minor}.patch"
  DIST_PATCH_NAME="dist--${SRC_PATCH_NAME}"
  DIST_PATCH_FILE="$PATCHES_DIR/$DIST_PATCH_NAME"
}

# Parse flags
PUBLISH_VERSION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish-version)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "❌ --publish-version requires a version argument (e.g. --publish-version 16.2.3-1)" >&2
        exit 1
      fi
      shift
      PUBLISH_VERSION_OVERRIDE="$1"
      ;;
    --help)
      echo "Usage: ./publish-only.sh [--publish-version <ver>]"
      echo ""
      echo "Options:"
      echo "  --publish-version <ver>  Override the NPM publish version (e.g. 16.2.3-1)."
      echo "                           Use when the original version was already published."
      echo "  --help                   Show this help message"
      exit 0
      ;;
  esac
  shift
done

# Prompt for tag
DEFAULT_TAG="$(npm info next dist-tags.canary 2>/dev/null || echo '16.2.0-canary.42')"
DEFAULT_TAG="v${DEFAULT_TAG#v}"
echo "ℹ️ next@latest:   $(npm info next dist-tags.latest 2>/dev/null || echo 'n/a')"
echo "ℹ️ next@canary:   $(npm info next dist-tags.canary 2>/dev/null || echo 'n/a')"
echo "ℹ️ @runderworld/next.js-patches@latest: $(npm info @runderworld/next.js-patches dist-tags.latest 2>/dev/null || echo 'n/a')"
read -rp "📦 Enter Next.js tag to publish [default: $DEFAULT_TAG]: " TAG
TAG="${TAG:-$DEFAULT_TAG}"
[[ "$TAG" != v* ]] && TAG="v$TAG"

# Derive publish version — defaults to upstream tag unless overridden
if [[ -n "$PUBLISH_VERSION_OVERRIDE" ]]; then
  VERSION="${PUBLISH_VERSION_OVERRIDE#v}"
  echo "📦 Publish version overridden: ${VERSION} (upstream tag: ${TAG})"
else
  VERSION="${TAG#v}"
fi

# Resolve patch filename
resolve_dist_patch_name "$TAG"

# Validate branch — accept either the publish branch or the upstream tag branch
EXPECTED_BRANCH="patch-v${VERSION}"
ALT_BRANCH="patch-${TAG}"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "$EXPECTED_BRANCH" ] && [ "$CURRENT_BRANCH" != "$ALT_BRANCH" ]; then
  echo "❌ Expected branch '$EXPECTED_BRANCH' (or '$ALT_BRANCH') but currently on '$CURRENT_BRANCH'" >&2
  exit 1
fi

# Validate patch file
if [ ! -f "$DIST_PATCH_FILE" ]; then
  echo "❌ Patch file not found: $DIST_PATCH_FILE" >&2
  echo "   Available patches:"
  ls -1 "$PATCHES_DIR"/dist--*.patch 2>/dev/null || echo "   (none)"
  exit 1
fi

# Prepare package directory
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"
cp "$DIST_PATCH_FILE" "$PACKAGE_DIR/dist.patch"

# Create package.json
cat > "$PACKAGE_DIR/package.json" <<EOF
{
  "name": "@runderworld/next.js-patches",
  "version": "$VERSION",
  "description": "Dist patch overlay for Next.js $TAG with ${SRC_PATCH_NAME%.patch}",
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

# Publish to npm
echo "🚀 Publishing @runderworld/next.js-patches@$VERSION to npm..."
pushd "$PACKAGE_DIR" >/dev/null

# Verify npm auth before publishing
if ! npm whoami >/dev/null 2>&1; then
  echo "❌ Not logged in to npm. Run 'npm login' first." >&2
  exit 1
fi

# We're now ready to publish
if npm publish --access public; then
  echo "✅ Published @runderworld/next.js-patches@$VERSION successfully."
else
  echo "❌ NPM publish failed." >&2
  exit 1
fi
popd >/dev/null

# Cleanup
rm -rf "$PACKAGE_DIR"

# Switch back to main branch
echo "🔀 Switching back to main branch..."
git checkout main

