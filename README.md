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

- Prompts for upstream tag (e.g. `v15.5.2`)
- Uses hardcoded commit list for `pr-71759++` patch

### Output

- `patches/pr-71759++.patch` — Source patch
- `patches/dist-<tag>-pr71759++.patch` — Dist-level patch
- `patches/manifest.json` — Metadata registry
- `@runderworld/next.js-patches@<version>` — Published NPM package

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

