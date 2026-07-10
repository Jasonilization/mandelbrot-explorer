#!/bin/bash
# Packages the built .app into a distributable, drag-to-install .dmg.
# Run Scripts/build_app.sh first (this script does it for you if missing).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Mandelbrot Explorer"
VERSION="${MANDELBROT_VERSION:-1.0.0}"
APP_DIR="dist/${APP_NAME}.app"
DMG_STAGING="dist/dmg_staging"
DMG_PATH="dist/MandelbrotExplorer-${VERSION}.dmg"

if [ ! -d "${APP_DIR}" ]; then
    echo "==> ${APP_DIR} not found, building it first"
    "$(dirname "$0")/build_app.sh"
fi

echo "==> Staging DMG contents"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_DIR}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"

rm -f "${DMG_PATH}"
echo "==> Building ${DMG_PATH}"
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov -format UDZO \
    "${DMG_PATH}"

rm -rf "${DMG_STAGING}"
echo "==> Done: ${DMG_PATH}"
