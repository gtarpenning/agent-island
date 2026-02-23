# Agent Island

Agent Island is my fork of the original project.

It keeps the notch-style macOS companion workflow and adds support for **Codex** in addition to Claude Code.

## Build

```bash
xcodebuild -scheme ClaudeIsland -configuration Release build
```

## Release DMG + GitHub upload

Required:

- `GITHUB_REPO` (format: `owner/repo`)
- `NOTARY_KEYCHAIN_PROFILE` (unless `SKIP_NOTARIZATION=1`)

Example:

```bash
GITHUB_REPO=yourname/agent-island \
NOTARY_KEYCHAIN_PROFILE=ClaudeIsland \
./scripts/create-release.sh
```

If the app has not been exported yet:

```bash
GITHUB_REPO=yourname/agent-island \
NOTARY_KEYCHAIN_PROFILE=ClaudeIsland \
BUILD_IF_MISSING=1 \
./scripts/create-release.sh
```

For all options:

```bash
./scripts/create-release.sh --help
```
