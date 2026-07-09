#!/bin/zsh
# Builds Better Stickies.app in the project root.
set -e
cd "$(dirname "$0")/.."

APP="Better Stickies.app"
NAME="Better Stickies"

# Liquid Glass (NSGlassEffectView) requires linking against the macOS 26 SDK.
# The system default is often the Command Line Tools (15.x SDK), so pin the
# toolchain to Xcode 26 explicitly.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "→ Building release binary ($(xcrun --show-sdk-version) SDK)…"
swift build -c release

if [[ ! -f Resources/AppIcon.icns ]]; then
    echo "→ Generating app icon…"
    mkdir -p Resources
    swift Scripts/make_icon.swift
fi

echo "→ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Stickies "$APP/Contents/MacOS/$NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleName</key><string>Better Stickies</string>
    <key>CFBundleDisplayName</key><string>Better Stickies</string>
    <key>CFBundleExecutable</key><string>Better Stickies</string>
    <key>CFBundleIdentifier</key><string>com.jamesgalante.better-stickies</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

codesign --force -s - "$APP" >/dev/null 2>&1 || true
echo "✓ Done: $(pwd)/$APP"

# Install to /Applications (fall back to ~/Applications if not writable).
DEST="/Applications"
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/"
echo "✓ Installed: $DEST/$APP"
