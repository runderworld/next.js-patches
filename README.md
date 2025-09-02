# next.js-patches

This repository contains reproducible patch artifacts and automation scripts for overlaying custom changes onto upstream Next.js releases. It supports deterministic builds, dist-level patching, and version-specific overlays without maintaining a fork.

## 📁 Structure

next.js-patches/
├── patches/
│   ├── pr-71759++.patch                  # Consolidated source patch (3 commits)
│   ├── dist-v15.5.2-pr71759++.patch      # Diff of built dist output for v15.5.2
│   ├── manifest.json                     # Metadata for all generated patches
├── scripts/
│   └── generate-and-apply-patch.sh       # Full automation pipeline
├── README.md                             # This file

> Note: The `package/` directory is created temporarily during NPM publishing and automatically removed after publish. It is not versioned.

## 🔧 Patch Workflow

1. **Create consolidated patch**  
   Cherry-picks multiple commits (e.g. PR #71759 + local fixes) into a temporary branch and generates `pr-71759++.patch`.

2. **Apply patch to upstream release**  
   Rebases `runderworld/next.js` on a specified upstream tag (e.g. `v15.5.2`) and applies the patch.

3. **Build and diff dist output**  
   Builds the patched Next.js source and generates a diff against the original `packages/next/dist`.

4. **Commit dist patch**  
   Commits the resulting `dist-<version>-pr71759++.patch` to this repo on a branch named `patch-<version>` and tags it as `patch-<version>`.

5. **Publish to NPM**  
   The patch is published as `@runderworld/next.js-patches@<version>` where `<version>` matches the exact upstream Next.js version (e.g. `15.5.2`).

6. **Cleanup**  
   The temporary `package/` directory used for publishing is automatically removed after publish.

## 🧪 Dry-Run Mode

You can run the script in dry-run mode to preview patch generation without committing or publishing:

```bash
./scripts/generate-and-apply-patch.sh --dry-run

