#!/bin/bash
# Builds a release binary and wraps it into a proper, double-clickable
# MandelbrotExplorer.app bundle (with Info.plist, bundled Metal shader
# resource, and a generated icon), ad-hoc signed so Gatekeeper allows it to
# run locally without additional setup.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Mandelbrot Explorer"
BUNDLE_ID="com.jasonilization.mandelbrotexplorer"
VERSION="${MANDELBROT_VERSION:-1.0.0}"
BUILD_DIR=".build/release"
APP_DIR="dist/${APP_NAME}.app"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling app bundle at ${APP_DIR}"
rm -rf "dist"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/MandelbrotExplorer" "${APP_DIR}/Contents/MacOS/MandelbrotExplorer"

# SwiftPM resource bundle (contains Shaders.metal) -- must ship alongside the
# executable for Bundle.module to find it at runtime.
RESOURCE_BUNDLE=$(find "${BUILD_DIR}" -maxdepth 1 -name "*_MandelbrotExplorer.bundle" | head -n1)
if [ -n "${RESOURCE_BUNDLE}" ]; then
    cp -R "${RESOURCE_BUNDLE}" "${APP_DIR}/Contents/Resources/"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>MandelbrotExplorer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.graphics-design</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Mandelbrot Explorer</string>
</dict>
</plist>
PLIST

echo "==> Generating app icon"
ICON_SRC="/tmp/mandelbrot_icon_src.png"
ICONSET="/tmp/MandelbrotExplorer.iconset"
rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"
ICON_OUTPUT_PATH="${ICON_SRC}" "${BUILD_DIR}/MandelbrotExplorer" >/tmp/icon_gen.log 2>&1 || true

if [ -f "${ICON_SRC}" ]; then
    for size in 16 32 64 128 256 512 1024; do
        sips -z "${size}" "${size}" "${ICON_SRC}" --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
    done
    # @2x variants per Apple's iconset naming convention
    cp "${ICONSET}/icon_32x32.png"   "${ICONSET}/icon_16x16@2x.png"
    cp "${ICONSET}/icon_64x64.png"   "${ICONSET}/icon_32x32@2x.png"
    cp "${ICONSET}/icon_256x256.png" "${ICONSET}/icon_128x128@2x.png"
    cp "${ICONSET}/icon_512x512.png" "${ICONSET}/icon_256x256@2x.png"
    cp "${ICONSET}/icon_1024x1024.png" "${ICONSET}/icon_512x512@2x.png"
    rm -f "${ICONSET}/icon_64x64.png"
    iconutil -c icns "${ICONSET}" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"
else
    echo "    (icon render failed, shipping without a custom icon: see /tmp/icon_gen.log)"
fi

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "${APP_DIR}"

echo "==> Done: ${APP_DIR}"
