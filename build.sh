#!/bin/bash
# Build FooBarSwift.app from Sources/*.swift
set -euo pipefail
cd "$(dirname "$0")"

APP=FooBarSwift.app
BIN=$APP/Contents/MacOS/FooBarSwift
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
    -framework AppKit -framework AVFoundation -framework MediaPlayer -framework Network \
    -o "$BIN.tmp" Sources/main.swift Sources/Config.swift Sources/Library.swift \
    Sources/Player.swift Sources/Lyrics.swift Sources/LyricsCache.swift Sources/LastFM.swift \
    Sources/Sftp.swift Sources/Settings.swift Sources/TagEditor.swift Sources/FmCache.swift
mv "$BIN.tmp" "$BIN"

# icon from the Python app's glyph
GLYPH="$HOME/dev/foobar-qt/musical-note.png"
if [ -f "$GLYPH" ]; then
    swift Sources/makeicon.swift "$GLYPH" "$APP/Contents/Resources/AppIcon.icns" \
        || echo "warn: icon build failed, continuing"
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FooBar Swift</string>
    <key>CFBundleDisplayName</key><string>FooBar Swift</string>
    <key>CFBundleIdentifier</key><string>com.breakeneck.foobar-swift</string>
    <key>CFBundleExecutable</key><string>FooBarSwift</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleVersion</key><string>0.2</string>
    <key>CFBundleShortVersionString</key><string>0.2</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleMusicUsageDescription</key><string>FooBar Swift сканує вашу fonoteku для відтворення.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>FooBar Swift відкриває музику з теки Завантаження.</string>
</dict>
</plist>
EOF

codesign --force --sign 7B228DEF19A88C43B09524F85DA99C9AB55E16EC "$APP" 2>/dev/null \
  || codesign --force --sign - "$APP" 2>/dev/null || true
echo "built: $(pwd)/$APP"