#!/bin/bash

# Storage AI DMG Creation Script
# Creates a professional macOS DMG installer

set -e

# Configuration
APP_NAME="Storage AI"
BUNDLE_NAME="StorageAI"
VERSION="2.11.1"
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
    <string>28</string>
    <key>CFBundleShortVersionString</key>
    <string>2.11.1</string>
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

# Copy app icon from assets
echo "🎨 Setting app icon..."
CUSTOM_ICON="${DMG_ASSETS}/macos-icons/AppIcon.icns"
SYSTEM_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"

if [ -f "${CUSTOM_ICON}" ]; then
    echo "Using custom app icon from dmg-assets/macos-icons/"
    cp "${CUSTOM_ICON}" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
else
    echo "Custom icon not found, using system icon..."
    cp "${SYSTEM_ICON}" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

# Prepare DMG staging area
echo "📀 Preparing DMG..."
cp -R "${APP_BUNDLE}" "${DMG_STAGE}/"

# Create Applications symlink
ln -sf /Applications "${DMG_STAGE}/Applications"

# Create DMG background image with white background and arrow
echo "🎨 Creating DMG background..."
cat > /tmp/create_bg.py << 'PYTHON'
import os
import struct
import zlib

def create_dmg_background(filename, width, height):
    """Create a white background with arrow indicator for DMG"""
    
    def png_chunk(chunk_type, data):
        chunk_len = len(data)
        chunk = chunk_type + data
        crc = zlib.crc32(chunk) & 0xffffffff
        return struct.pack('>I', chunk_len) + chunk + struct.pack('>I', crc)
    
    # PNG signature
    signature = b'\x89PNG\r\n\x1a\n'
    
    # IHDR chunk (RGBA)
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    
    # Colors
    bg_color = (250, 250, 252, 255)  # Soft white/light gray
    arrow_color = (180, 180, 185, 255)  # Subtle gray arrow
    text_color = (140, 140, 145, 255)  # Gray text
    
    # Create image data
    raw_data = b''
    
    # Arrow parameters
    arrow_y_start = 175
    arrow_y_end = 195
    arrow_x_start = 285
    arrow_x_end = 375
    arrow_tip_x = 375
    arrow_tip_size = 15
    
    for y in range(height):
        raw_data += b'\x00'  # Filter byte
        for x in range(width):
            # Default background
            r, g, b, a = bg_color
            
            # Draw arrow shaft
            if arrow_y_start <= y <= arrow_y_end and arrow_x_start <= x <= arrow_x_end - arrow_tip_size:
                r, g, b, a = arrow_color
            
            # Draw arrow head (triangle pointing right)
            if arrow_x_end - arrow_tip_size <= x <= arrow_x_end:
                arrow_center_y = (arrow_y_start + arrow_y_end) // 2
                tip_progress = (x - (arrow_x_end - arrow_tip_size)) / arrow_tip_size
                half_height = int((1 - tip_progress) * 20)  # Triangle gets narrower
                if arrow_center_y - half_height <= y <= arrow_center_y + half_height:
                    r, g, b, a = arrow_color
            
            raw_data += bytes([r, g, b, a])
    
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
create_dmg_background('dmg-assets/background.png', 660, 400)
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
