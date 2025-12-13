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

# Prompt for tag
DEFAULT_TAG="v15.5.1-canary.27"
read -rp "📦 Enter Next.js tag to publish [default: $DEFAULT_TAG]: " TAG
TAG="${TAG:-$DEFAULT_TAG}"
VERSION="${TAG#v}"
PATCH_FILE="$PATCHES_DIR/dist-${TAG}-pr71759++.patch"

# Validate branch
EXPECTED_BRANCH="patch-${TAG}"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "$EXPECTED_BRANCH" ]; then
  echo "❌ Expected branch '$EXPECTED_BRANCH' but currently on '$CURRENT_BRANCH'" >&2
  exit 1
fi

# Validate patch file
if [ ! -f "$PATCH_FILE" ]; then
  echo "❌ Patch file not found: $PATCH_FILE" >&2
  exit 1
fi

# Prepare package directory
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"
cp "$PATCH_FILE" "$PACKAGE_DIR/dist.patch"

# Create package.json
cat > "$PACKAGE_DIR/package.json" <<EOF
{
  "name": "@runderworld/next.js-patches",
  "version": "$VERSION",
  "description": "Dist patch overlay for Next.js $TAG",
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
  echo "✅ Published successfully."
else
  echo "❌ NPM publish failed." >&2
  exit 1
fi
popd >/dev/null

# Cleanup
rm -rf "$PACKAGE_DIR"

