#!/bin/bash

# Storage AI DMG Creation Script
# Creates a professional macOS DMG installer

set -e

# Configuration
APP_NAME="Storage AI"
BUNDLE_NAME="StorageAI"
VERSION="1.7.0"
DMG_NAME="StorageAI-${VERSION}"
VOLUME_NAME="${APP_NAME} ${VERSION}"
BUILD_DIR="$(pwd)/.build/release"
DIST_DIR="$(pwd)/dist"
DMG_STAGE="$(pwd)/dmg-stage"
DMG_ASSETS="$(pwd)/dmg-assets"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"

echo "🚀 Building ${APP_NAME} v${VERSION} DMG..."

# Clean up
echo "📁 Cleaning up old files..."
rm -rf "${DIST_DIR}"
rm -rf "${DMG_STAGE}"
mkdir -p "${DIST_DIR}"
mkdir -p "${DMG_STAGE}"
mkdir -p "${DMG_ASSETS}"

# Create app bundle structure
echo "📦 Creating app bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy executable
cp "${BUILD_DIR}/${BUNDLE_NAME}" "${APP_BUNDLE}/Contents/MacOS/${BUNDLE_NAME}"

# Create Info.plist
cat > "${APP_BUNDLE}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Storage AI</string>
    <key>CFBundleDisplayName</key>
    <string>Storage AI</string>
    <key>CFBundleIdentifier</key>
    <string>com.storageai.app</string>
    <key>CFBundleVersion</key>
    <string>13</string>
    <key>CFBundleShortVersionString</key>
    <string>1.7.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>StorageAI</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
        <key>NSExceptionDomains</key>
        <dict>
            <key>localhost</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
                <key>NSIncludesSubdomains</key>
                <true/>
            </dict>
            <key>127.0.0.1</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
                <key>NSIncludesSubdomains</key>
                <true/>
            </dict>
        </dict>
    </dict>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Storage AI. All rights reserved.</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Create PkgInfo
echo -n "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# Create app icon
echo "🎨 Creating app icon..."
ICON_DIR="${APP_BUNDLE}/Contents/Resources/AppIcon.iconset"
mkdir -p "${ICON_DIR}"

# Use system icon as base and copy for each size
SYSTEM_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"

# Extract sizes from system icon or create colored squares
for size in 16 32 128 256 512; do
    # Try to extract from system icon
    sips -s format png -z $size $size "${SYSTEM_ICON}" --out "${ICON_DIR}/icon_${size}x${size}.png" 2>/dev/null || {
        # Fallback: create a simple colored PNG
        echo "Creating fallback icon ${size}x${size}..."
    }
    
    # Create @2x version
    size2x=$((size * 2))
    if [ $size -le 512 ]; then
        sips -s format png -z $size2x $size2x "${SYSTEM_ICON}" --out "${ICON_DIR}/icon_${size}x${size}@2x.png" 2>/dev/null || true
    fi
done

# Convert iconset to icns
iconutil -c icns "${ICON_DIR}" -o "${APP_BUNDLE}/Contents/Resources/AppIcon.icns" 2>/dev/null || {
    echo "Warning: Could not create icns, using fallback..."
    # Copy system icon as fallback
    cp "${SYSTEM_ICON}" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
}
rm -rf "${ICON_DIR}"

# Prepare DMG staging area
echo "📀 Preparing DMG..."
cp -R "${APP_BUNDLE}" "${DMG_STAGE}/"

# Create Applications symlink
ln -sf /Applications "${DMG_STAGE}/Applications"

# Create DMG background image
echo "🎨 Creating DMG background..."
cat > /tmp/create_bg.py << 'PYTHON'
import os
import struct
import zlib

def create_gradient_png(filename, width, height):
    """Create a simple gradient PNG without external dependencies"""
    
    def png_chunk(chunk_type, data):
        chunk_len = len(data)
        chunk = chunk_type + data
        crc = zlib.crc32(chunk) & 0xffffffff
        return struct.pack('>I', chunk_len) + chunk + struct.pack('>I', crc)
    
    # PNG signature
    signature = b'\x89PNG\r\n\x1a\n'
    
    # IHDR chunk
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    
    # Create image data with gradient
    raw_data = b''
    for y in range(height):
        raw_data += b'\x00'  # Filter byte (none)
        for x in range(width):
            # Dark gradient from top-left to bottom-right
            r = int(20 + (y / height) * 15 + (x / width) * 5)
            g = int(25 + (y / height) * 20 + (x / width) * 5)
            b = int(45 + (y / height) * 25 + (x / width) * 10)
            raw_data += bytes([min(r, 255), min(g, 255), min(b, 255)])
    
    # Compress the data
    compressed = zlib.compress(raw_data, 9)
    
    # Write PNG file
    with open(filename, 'wb') as f:
        f.write(signature)
        f.write(png_chunk(b'IHDR', ihdr))
        f.write(png_chunk(b'IDAT', compressed))
        f.write(png_chunk(b'IEND', b''))

# Create background
os.makedirs('dmg-assets', exist_ok=True)
create_gradient_png('dmg-assets/background.png', 660, 400)
print("Background created successfully")
PYTHON

cd "$(pwd)" && python3 /tmp/create_bg.py

# Create the DMG
echo "💿 Creating DMG file..."

# First create a temporary DMG
TEMP_DMG="${DIST_DIR}/temp_${DMG_NAME}.dmg"
FINAL_DMG="${DIST_DIR}/${DMG_NAME}.dmg"

# Remove old DMG if exists
rm -f "${TEMP_DMG}" "${FINAL_DMG}"

# Create DMG from folder
hdiutil create -volname "${VOLUME_NAME}" \
    -srcfolder "${DMG_STAGE}" \
    -ov -format UDRW \
    "${TEMP_DMG}"

# Mount the DMG
echo "🔧 Configuring DMG appearance..."
MOUNT_OUTPUT=$(hdiutil attach -readwrite -noverify "${TEMP_DMG}" 2>&1)
echo "${MOUNT_OUTPUT}"
MOUNT_DIR=$(echo "${MOUNT_OUTPUT}" | grep "Volumes" | awk -F'\t' '{print $NF}' | xargs)

echo "Mount dir: ${MOUNT_DIR}"

if [ -n "${MOUNT_DIR}" ] && [ -d "${MOUNT_DIR}" ]; then
    # Wait for mount
    sleep 2
    
    # Copy background
    mkdir -p "${MOUNT_DIR}/.background"
    cp "${DMG_ASSETS}/background.png" "${MOUNT_DIR}/.background/background.png"
    
    # Set DMG window appearance using AppleScript
    echo "Setting window appearance..."
    osascript << APPLESCRIPT
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 760, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 100
        set background picture of viewOptions to file ".background:background.png"
        set position of item "Storage AI.app" of container window to {165, 180}
        set position of item "Applications" of container window to {495, 180}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT
    
    # Sync and unmount
    sync
    sleep 2
    hdiutil detach "${MOUNT_DIR}" -force 2>/dev/null || hdiutil detach "${MOUNT_DIR}" 2>/dev/null || true
else
    echo "Warning: Could not configure DMG appearance"
    # Try to unmount anyway
    hdiutil detach "/Volumes/${VOLUME_NAME}" -force 2>/dev/null || true
fi

# Convert to compressed DMG
echo "📦 Compressing DMG..."
hdiutil convert "${TEMP_DMG}" -format UDZO -imagekey zlib-level=9 -o "${FINAL_DMG}"
rm -f "${TEMP_DMG}"

# Clean up
rm -rf "${DMG_STAGE}"

# Get file size
DMG_SIZE=$(du -h "${FINAL_DMG}" | cut -f1)

echo ""
echo "✅ DMG created successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 File: ${FINAL_DMG}"
echo "📏 Size: ${DMG_SIZE}"
echo "🏷️  Version: ${VERSION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "To install: Open the DMG and drag Storage AI to Applications"
