#!/bin/bash
# Quick launch for development: builds (if needed) and runs the app directly,
# without packaging a full .app bundle. Use Scripts/build_app.sh +
# Scripts/make_dmg.sh to produce a distributable build instead.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
swift build -c "${CONFIG}"
exec ".build/${CONFIG}/MandelbrotExplorer"
