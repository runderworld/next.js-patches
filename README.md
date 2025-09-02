# next.js-patches

This repository contains reproducible patch artifacts and automation scripts for overlaying custom changes onto upstream Next.js releases. It supports deterministic builds, dist-level patching, and version-specific overlays without maintaining a fork.

## 📁 Structure

next.js-patches/
├── patches/
│   ├── pr-71759++.patch                  # Consolidated source patch (3 commits)
│   ├── dist-v15.5.2-pr71759++.patch      # Diff of built dist output for v15.5.2
│   ├── dist-v15.6.0-pr71759++.patch      # Diff for future versions
│   └── manifest.json                     # Metadata for all generated patches
├── scripts/
│   └── generate-and-apply-patch.sh       # Full automation pipeline
├── README.md                             # This file

## 🔧 Patch Workflow

1. **Create consolidated patch**  
   Cherry-picks multiple commits (e.g. PR #71759 + local fixes) into a temporary branch and generates `pr-71759++.patch`.

2. **Apply patch to upstream release**  
   Rebases `runderworld/next.js` on a specified upstream tag (e.g. `v15.5.2`) and applies the patch.

3. **Build and diff dist output**  
   Builds the patched Next.js source and generates a diff against the original `packages/next/dist`.

4. **Commit dist patch**  
   Commits the resulting `dist-<version>-pr71759++.patch` to this repo on a branch named `patch-<version>`.

## 📜 Manifest Format

Each patch is tracked in `patches/manifest.json` with metadata:

{
  "dist-v15.5.2-pr71759++.patch": {
    "upstream": "v15.5.2",
    "sourcePatch": "pr-71759++.patch",
    "commits": [
      "ed127bb230748d7471b74c16b0532aaf42a0f808",
      "ea98aea563173245e989ca2af84ad274c979f581",
      "3017607daab6161721dcdeba286374c7f7725c19"
    ],
    "created": "2025-09-01T20:22:00Z"
  }
}

## 🛠 Requirements

- `pnpm` for reproducible builds
- `jq` for manifest updates
- Git access to both `vercel/next.js` and `runderworld/next.js`

## 🚫 What This Repo Does Not Do

- It does not publish patched packages to npm
- It does not maintain a fork of Next.js
- It does not modify upstream source beyond patch overlays

## ✅ Purpose

This repo enables deterministic patching of Next.js releases for enterprise consumption, CI-safe workflows, and reproducible dist overlays.

