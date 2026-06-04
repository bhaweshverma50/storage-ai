#!/bin/bash

# Build + install Storage AI to /Applications with a STABLE code-signing identity.
#
# Why this exists: macOS TCC ties permission grants (folder access, Full Disk Access,
# media library) to the app's code identity. Ad-hoc signatures ("codesign --sign -")
# produce a new identity on every build, so each reinstall looked like a brand-new app
# and re-prompted for every permission. Signing with a real certificate (Developer ID
# or Apple Development) keeps the identity stable, so grants persist across rebuilds.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="/Applications/Storage AI.app"
ENTITLEMENTS="StorageAI/StorageAI.entitlements"

# Same preference order as create-dmg.sh: explicit > Developer ID > Apple Development > ad-hoc.
IDENTITY="${CODESIGN_IDENTITY:-}"
[ -z "${IDENTITY}" ] && IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')
[ -z "${IDENTITY}" ] && IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
if [ -z "${IDENTITY}" ]; then
    echo "⚠️  No signing certificate found — falling back to ad-hoc."
    echo "   Permissions will NOT persist across rebuilds. Create a certificate in"
    echo "   Xcode (Settings ▸ Accounts) or Keychain Access to fix this."
    IDENTITY="-"
fi

echo "🔨 Building release..."
swift build -c release

if [ ! -d "${APP}" ]; then
    echo "❌ ${APP} not found — run ./scripts/create-dmg.sh once to create the bundle, then"
    echo "   copy dist/Storage AI.app to /Applications."
    exit 1
fi

echo "🛑 Quitting running app (if any)..."
osascript -e 'tell application "Storage AI" to quit' 2>/dev/null || true
sleep 1

echo "📦 Installing binary + Info.plist..."
cp .build/release/StorageAI "${APP}/Contents/MacOS/StorageAI"
cp StorageAI/Info.plist "${APP}/Contents/Info.plist"
# Re-add bundle-only keys the source plist doesn't carry.
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${APP}/Contents/Info.plist" 2>/dev/null || true

echo "🔏 Signing with: ${IDENTITY}"
# No --timestamp: dev builds aren't notarized and the timestamp service needs network.
codesign --force --options runtime --entitlements "${ENTITLEMENTS}" --sign "${IDENTITY}" "${APP}/Contents/MacOS/StorageAI"
codesign --force --options runtime --entitlements "${ENTITLEMENTS}" --sign "${IDENTITY}" "${APP}"
codesign --verify --strict "${APP}"

open "${APP}"
echo "✅ Installed + launched — $(codesign -dvv "${APP}" 2>&1 | grep TeamIdentifier)"
