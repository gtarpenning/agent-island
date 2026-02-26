#!/bin/bash
# One-command release flow:
# 1) bump minor version + build number
# 2) update download links to direct DMG URL
# 3) build signed app
# 4) commit/tag/push
# 5) notarize/package/sign/upload/update website
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PBXPROJ="$PROJECT_DIR/AgentIsland.xcodeproj/project.pbxproj"
DOCS_FILE="$PROJECT_DIR/docs/index.html"
README_FILE="$PROJECT_DIR/README.md"
KEYCHAIN_PROFILE="AgentIsland"
GITHUB_REPO="gtarpenning/agent-island"
APP_NAME="AgentIsland"
AUTO_PUSH_WEBSITE="${AUTO_PUSH_WEBSITE:-1}"
DRY_RUN=0

if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $1"
        exit 1
    fi
}

for cmd in git gh xcodebuild xcrun perl rg; do
    require_command "$cmd"
done

if [ "$DRY_RUN" != "1" ]; then
    if ! gh auth status >/dev/null 2>&1; then
        echo "ERROR: gh is not authenticated. Run: gh auth login"
        exit 1
    fi

    if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
        echo "ERROR: notarytool profile '$KEYCHAIN_PROFILE' not configured."
        echo "Run:"
        echo "  xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" \\"
        echo "      --apple-id \"your@email.com\" \\"
        echo "      --team-id \"2DKS5U9LV4\" \\"
        echo "      --password \"xxxx-xxxx-xxxx-xxxx\""
        exit 1
    fi

    if ! git -C "$PROJECT_DIR" diff --quiet || ! git -C "$PROJECT_DIR" diff --cached --quiet; then
        echo "ERROR: Git working tree is not clean. Commit or stash changes first."
        exit 1
    fi
fi

BRANCH="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" = "HEAD" ]; then
    echo "ERROR: Detached HEAD is not supported for publish flow."
    exit 1
fi

CURRENT_VERSION="$(sed -nE 's/.*MARKETING_VERSION = ([0-9]+\.[0-9]+);/\1/p' "$PBXPROJ" | head -n1)"
if [[ ! "$CURRENT_VERSION" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    echo "ERROR: Could not parse 2-part MARKETING_VERSION from $PBXPROJ"
    exit 1
fi

MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
NEXT_MINOR=$((MINOR + 1))
NEXT_VERSION="$MAJOR.$NEXT_MINOR"

CURRENT_BUILD="$(sed -nE 's/.*CURRENT_PROJECT_VERSION = ([0-9]+);/\1/p' "$PBXPROJ" | head -n1)"
if [[ ! "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Could not parse CURRENT_PROJECT_VERSION from $PBXPROJ"
    exit 1
fi
NEXT_BUILD=$((CURRENT_BUILD + 1))

TAG="v$NEXT_VERSION"
DMG_URL="https://github.com/$GITHUB_REPO/releases/download/$TAG/$APP_NAME-$NEXT_VERSION.dmg"

if git -C "$PROJECT_DIR" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "ERROR: Tag $TAG already exists locally."
    exit 1
fi

if git -C "$PROJECT_DIR" ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "ERROR: Tag $TAG already exists on origin."
    exit 1
fi

echo "Preparing release $CURRENT_VERSION -> $NEXT_VERSION (build $CURRENT_BUILD -> $NEXT_BUILD)"
echo "Direct DMG URL: $DMG_URL"
echo "Branch: $BRANCH"
echo ""

if [ "$DRY_RUN" = "1" ]; then
    echo "Dry run only. No files were changed."
    exit 0
fi

perl -0pi -e "s/MARKETING_VERSION = [0-9]+\\.[0-9]+;/MARKETING_VERSION = $NEXT_VERSION;/g; s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $NEXT_BUILD;/g" "$PBXPROJ"

DMG_URL="$DMG_URL" perl -0pi -e 's#https://github\.com/gtarpenning/agent-island/releases/(?:latest|download/v[0-9]+(?:\.[0-9]+)+/AgentIsland-[0-9]+(?:\.[0-9]+)+\.dmg)#$ENV{DMG_URL}#g' "$DOCS_FILE"
DMG_URL="$DMG_URL" perl -0pi -e 's#\[(Download the latest release)\]\([^)]+\)#[\1]($ENV{DMG_URL})#g' "$README_FILE"

UPDATED_VERSION="$(sed -nE 's/.*MARKETING_VERSION = ([0-9]+\.[0-9]+);/\1/p' "$PBXPROJ" | head -n1)"
if [ "$UPDATED_VERSION" != "$NEXT_VERSION" ]; then
    echo "ERROR: Version bump verification failed."
    exit 1
fi

if ! rg -q "$DMG_URL" "$DOCS_FILE"; then
    echo "ERROR: docs/index.html link update failed."
    exit 1
fi

if ! rg -q "$DMG_URL" "$README_FILE"; then
    echo "ERROR: README.md link update failed."
    exit 1
fi

echo "Building release app..."
"$SCRIPT_DIR/build.sh"

echo "Committing release metadata..."
git -C "$PROJECT_DIR" add "$PBXPROJ" "$DOCS_FILE" "$README_FILE"
git -C "$PROJECT_DIR" commit -m "Release $TAG"
git -C "$PROJECT_DIR" tag "$TAG"
git -C "$PROJECT_DIR" push origin "$BRANCH"
git -C "$PROJECT_DIR" push origin "$TAG"

echo "Running notarization, DMG signing, GitHub release upload, and website update..."
AUTO_PUSH_WEBSITE="$AUTO_PUSH_WEBSITE" ALLOW_UNSIGNED_RELEASE=0 "$SCRIPT_DIR/create-release.sh"

echo ""
echo "Publish complete for $TAG"
echo "DMG URL: $DMG_URL"
