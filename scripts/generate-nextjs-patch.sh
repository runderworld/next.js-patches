#!/usr/bin/env bash
set -euo pipefail

# Inputs
NEXT_REPO="https://github.com/vercel/next.js.git"
PR_COMMITS=(
  ed127bb230748d7471b74c16b0532aaf42a0f808
  ea98aea563173245e989ca2af84ad274c979f581
)

# Setup
rm -rf next-original next-patched
git clone "$NEXT_REPO" next-original
git clone "$NEXT_REPO" next-patched

# Checkout latest in both
cd next-original && git checkout origin/main && pnpm install && pnpm build && cd ..
cd next-patched && git checkout origin/main

# Apply PR commits
for commit in "${PR_COMMITS[@]}"; do
  git cherry-pick "$commit"
done

pnpm install
pnpm build

# Generate patch
mkdir -p patches
diff -ruN next-original/packages/next/dist next-patched/packages/next/dist > patches/next-dist-pr71759.patch

echo "✅ Patch generated: patches/next-dist-pr71759.patch"

