#!/bin/zsh
# Builds Better Stickies.app and packages it as a distributable zip in dist/.
# Usage: Scripts/make_release.sh [version]   (default: 1.0)
set -e
cd "$(dirname "$0")/.."

VERSION="${1:-1.0}"

zsh Scripts/make_app.sh

mkdir -p dist
# Stable asset name: /releases/latest/download/Better-Stickies.zip always
# fetches the newest build directly. The version lives in the release tag.
ZIP="dist/Better-Stickies.zip"
rm -f "$ZIP"
# ditto preserves the bundle structure and extended attributes; plain zip
# tools can corrupt .app bundles.
ditto -c -k --keepParent "Better Stickies.app" "$ZIP"
echo "✓ Release zip: $ZIP"
