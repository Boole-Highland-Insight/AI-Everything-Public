#!/bin/bash
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
AIE_SOURCE="$AIE_PROJECT/apps/macos/AIEPopup/Sources"
AIE_OUTPUT="$AIE_PROJECT/apps/macos/AIEPopup/build/checks"
AIE_APP="$AIE_OUTPUT/DesktopBehaviorChecks.app"
AIE_BINARY="$AIE_APP/Contents/MacOS/DesktopBehaviorChecks"
rm -rf "$AIE_APP"
mkdir -p "$AIE_APP/Contents/MacOS"
cat > "$AIE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>DesktopBehaviorChecks</string>
<key>CFBundleIdentifier</key><string>local.aieverything.desktop-checks</string>
<key>CFBundleName</key><string>DesktopBehaviorChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -module-cache-path "$AIE_PROJECT/apps/macos/AIEPopup/build/ModuleCache" \
  "$AIE_SOURCE/AppWindowPresence.swift" "$AIE_SOURCE/SearchShortcut.swift" \
  "$AIE_SOURCE/OwnedModelProcesses.swift" "$AIE_PROJECT/tests/DesktopBehaviorChecks.swift" \
  -o "$AIE_BINARY"
codesign --force --sign - "$AIE_APP" >/dev/null
AIE_LOG="$AIE_OUTPUT/desktop-behavior-checks.log"
rm -f "$AIE_LOG"
open -W -n "$AIE_APP" --stdout "$AIE_LOG" --stderr "$AIE_LOG"
cat "$AIE_LOG"
grep -F "Desktop checks passed:" "$AIE_LOG" >/dev/null
