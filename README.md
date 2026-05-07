# Next.js Patch Automation

This utility automates the process of generating, verifying, and publishing dist-level patches for Next.js. It overlays selected PRs and local fixes onto an upstream tag, builds the output, generates reproducible patch artifacts, and publishes them as NPM packages for enterprise consumption.

## 🔧 Script: `generate-and-apply-patch.sh`

### Features

- Cherry-picks selected commits onto `upstream/canary`
- Generates a consolidated `.patch` file
- Applies patch to a clean branch from upstream tag
- Builds Next.js using `pnpm`
- Diffs original and patched `dist/` output
- Generates reproducible dist patch
- Updates `manifest.json` with patch metadata
- Verifies fingerprint token in built output before publishing
- Publishes patch as an NPM package
- Pushes patch branch and tag to `origin`
- Cleans up Git state if fingerprint is missing or publish fails
- Validates required tools before execution

### Usage

```bash
./scripts/generate-and-apply-patch.sh [--dry-run]
```

### Options

- `--dry-run` — Run without committing, pushing, or publishing
- `--help` — Show usage instructions

### Inputs

- Prompts for upstream tag (e.g. `v16.2.3`)
- Derives fix branch (`fix/node-options-v<major>-<minor>`) and commits to cherry-pick from the tag's major.minor version

### Output

- `patches/fix-node-options-v<major>-<minor>.patch` — Source patch
- `patches/dist--fix-node-options-v<major>-<minor>.patch` — Dist-level patch
- `patches/manifest.json` — Metadata registry
- `@runderworld/next.js-patches@<version>` — Published NPM package

## 🏷 Adding a new variant

When a new major/minor variant is required, update `scripts/generate-and-apply-patch.sh` to add the new `patch_minor` mapping and hardcoded commit list for that resolved variant.

Then rerun the script for the first upstream tag in that variant. The script will generate both the source patch and the `dist--*.patch` file.

Because `publish-only.sh` relies on `patches/dist--*.patch`, the generated dist patch must be committed along with the variant script changes.

If you later rerun the script for the same variant, make sure the `dist--*.patch` file is kept under version control so the published package remains reproducible.

## 🧼 Workspace Hygiene

Before patching begins, the script verifies:

- Clean Git state in both repos
- Patch branch does not already exist
- Manifest includes expected patch entry

## 🔐 Fingerprint Verification

Before publishing, the script checks:

- That the literal token `runderworld.node.options.patch` exists in the built `dist/` output

If the token is missing, the script aborts and restores both repos to a clean state.

## 🚀 Patch Branch and Tag Publishing

After generating and committing the patch artifacts, the script:

- Pushes the patch branch (`patch-vX.Y.Z`) to `origin`
- Pushes the corresponding Git tag (`vX.Y.Z`) to `origin`

This ensures patch branches are discoverable, versioned, and CI-compatible.

## 🧹 Failure Recovery

If fingerprint verification or NPM publish fails:

- The patch branch and tag are deleted from the utility repo
- The last commit is rolled back
- The Next.js repo is reset to `upstream/canary`
- Untracked files (e.g. `.dist-original/`) are removed

## 📦 NPM Package Structure

```json
{
  "name": "@runderworld/next.js-patches",
  "version": "<tag>",
  "main": "dist.patch",
  "files": ["dist.patch"]
}
```

## 🛠 Required Tools

The following tools must be available in your `PATH`:

- `jq`
- `pnpm`
- `git`
- `diff`
- `grep`
- `awk`

The script will fail early if any are missing.

## 🧪 Dry-Run Mode

Use `--dry-run` to simulate the full flow without committing, pushing, or publishing. Useful for validation and inspection.

---

All patch artifacts are version-locked, fingerprinted, and reproducible. No surprises.

