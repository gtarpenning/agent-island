#!/bin/bash
# Create release DMG and upload to GitHub using environment variables.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
DEFAULT_APP_PATH="$BUILD_DIR/export/Agent Island.app"

usage() {
    cat <<'EOF'
Usage:
  GITHUB_REPO=owner/repo [other env vars] ./scripts/create-release.sh

Required env vars:
  GITHUB_REPO              GitHub repo in owner/repo format.

Required unless SKIP_NOTARIZATION=1:
  NOTARY_KEYCHAIN_PROFILE  notarytool keychain profile name.

Optional env vars:
  APP_PATH                 Path to .app (default: ./build/export/Agent Island.app)
  RELEASE_DIR              Output directory for DMG (default: ./releases)
  APP_NAME                 Artifact prefix (default: ClaudeIsland)
  DMG_VOLUME_NAME          DMG volume name (default: Agent Island)
  SKIP_NOTARIZATION        Set to 1 to skip notarizing app and DMG.
  SKIP_GITHUB_UPLOAD       Set to 1 to skip GitHub release upload.
  BUILD_IF_MISSING         Set to 1 to run ./scripts/build.sh if APP_PATH is missing.
  RELEASE_TAG              Git tag name (default: v<CFBundleShortVersionString>)
  RELEASE_TITLE            GitHub release title (default: Agent Island v<version>)
  RELEASE_NOTES            GitHub release notes text.
EOF
}

if [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

APP_PATH="${APP_PATH:-$DEFAULT_APP_PATH}"
RELEASE_DIR="${RELEASE_DIR:-$PROJECT_DIR/releases}"
APP_NAME="${APP_NAME:-ClaudeIsland}"
DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-Agent Island}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"
SKIP_GITHUB_UPLOAD="${SKIP_GITHUB_UPLOAD:-0}"
BUILD_IF_MISSING="${BUILD_IF_MISSING:-0}"

echo "=== Creating Release ==="
echo ""

if [ ! -d "$APP_PATH" ] && [ "$BUILD_IF_MISSING" = "1" ]; then
    echo "App not found at $APP_PATH, running build script..."
    "$SCRIPT_DIR/build.sh"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found at $APP_PATH"
    echo "Run ./scripts/build.sh first or set BUILD_IF_MISSING=1"
    exit 1
fi

MISSING_ENV=0
if [ -z "${GITHUB_REPO:-}" ] && [ "$SKIP_GITHUB_UPLOAD" != "1" ]; then
    echo "ERROR: GITHUB_REPO is required unless SKIP_GITHUB_UPLOAD=1"
    MISSING_ENV=1
fi
if [ "$SKIP_NOTARIZATION" != "1" ] && [ -z "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    echo "ERROR: NOTARY_KEYCHAIN_PROFILE is required unless SKIP_NOTARIZATION=1"
    MISSING_ENV=1
fi
if [ "$MISSING_ENV" -ne 0 ]; then
    echo ""
    usage
    exit 1
fi

# Get version from app bundle
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
TAG="${RELEASE_TAG:-v$VERSION}"
TITLE="${RELEASE_TITLE:-Agent Island v$VERSION}"

echo "App: $APP_PATH"
echo "Version: $VERSION (build $BUILD)"
echo "Tag: $TAG"
echo ""

mkdir -p "$RELEASE_DIR"
DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"

if [ "$SKIP_NOTARIZATION" != "1" ]; then
    echo "=== Step 1: Notarizing app ==="
    if ! xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >/dev/null 2>&1; then
        echo "ERROR: notarytool keychain profile '$NOTARY_KEYCHAIN_PROFILE' is not available."
        echo "Create it with:"
        echo "  xcrun notarytool store-credentials \"$NOTARY_KEYCHAIN_PROFILE\" --apple-id <id> --team-id <team> --password <app-password>"
        exit 1
    fi

    ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION.zip"
    echo "Creating zip for notarization..."
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

    echo "Submitting app zip to notarytool..."
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait

    echo "Stapling app..."
    xcrun stapler staple "$APP_PATH"
    rm -f "$ZIP_PATH"
    echo ""
fi

echo "=== Step 2: Creating DMG ==="
rm -f "$DMG_PATH"

APP_BUNDLE_NAME="$(basename "$APP_PATH")"
APP_PARENT_DIR="$(dirname "$APP_PATH")"
if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
        --overwrite \
        --volname "$DMG_VOLUME_NAME" \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$APP_BUNDLE_NAME" 150 200 \
        --app-drop-link 450 200 \
        --hide-extension "$APP_BUNDLE_NAME" \
        "$DMG_PATH" \
        "$APP_PARENT_DIR"
else
    echo "create-dmg not found, using hdiutil."
    hdiutil create \
        -volname "$DMG_VOLUME_NAME" \
        -srcfolder "$APP_PATH" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
fi
echo "DMG created: $DMG_PATH"
echo ""

if [ "$SKIP_NOTARIZATION" != "1" ]; then
    echo "=== Step 3: Notarizing DMG ==="
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    echo "DMG notarized."
    echo ""
else
    echo "Skipping notarization (SKIP_NOTARIZATION=1)."
    echo ""
fi

if [ "$SKIP_GITHUB_UPLOAD" = "1" ]; then
    echo "Skipping GitHub upload (SKIP_GITHUB_UPLOAD=1)."
    echo ""
    echo "=== Release Complete ==="
    echo "DMG: $DMG_PATH"
    exit 0
fi

echo "=== Step 4: Uploading to GitHub Release ==="
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI not found. Install with: brew install gh"
    exit 1
fi

if [ -n "${GITHUB_TOKEN:-}" ] && [ -z "${GH_TOKEN:-}" ]; then
    export GH_TOKEN="$GITHUB_TOKEN"
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: GitHub CLI is not authenticated."
    echo "Run 'gh auth login' or export GITHUB_TOKEN."
    exit 1
fi

if gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    echo "Release $TAG exists, uploading DMG with --clobber..."
    gh release upload "$TAG" "$DMG_PATH" --repo "$GITHUB_REPO" --clobber
else
    if [ -n "${RELEASE_NOTES:-}" ]; then
        NOTES="$RELEASE_NOTES"
    else
        NOTES="$(printf 'Release %s (build %s)\n\nDownload the DMG and drag Agent Island to Applications.' "$VERSION" "$BUILD")"
    fi
    echo "Creating release $TAG..."
    gh release create "$TAG" "$DMG_PATH" \
        --repo "$GITHUB_REPO" \
        --title "$TITLE" \
        --notes "$NOTES"
fi

GITHUB_RELEASE_URL="https://github.com/$GITHUB_REPO/releases/tag/$TAG"
GITHUB_DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$TAG/$APP_NAME-$VERSION.dmg"

echo ""
echo "=== Release Complete ==="
echo "DMG: $DMG_PATH"
echo "GitHub release: $GITHUB_RELEASE_URL"
echo "Direct download: $GITHUB_DOWNLOAD_URL"
