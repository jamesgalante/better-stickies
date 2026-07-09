#!/bin/zsh
# Builds Better Stickies.app and packages it as a distributable zip in dist/.
# Usage: Scripts/make_release.sh [version]   (default: 1.0)
set -e
cd "$(dirname "$0")/.."

VERSION="${1:-1.0}"

zsh Scripts/make_app.sh

mkdir -p dist
ZIP="dist/Better-Stickies-${VERSION}.zip"
rm -f "$ZIP"
# ditto preserves the bundle structure and extended attributes; plain zip
# tools can corrupt .app bundles.
ditto -c -k --keepParent "Better Stickies.app" "$ZIP"
echo "✓ Release zip: $ZIP"
