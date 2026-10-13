#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --show-sdk-path)"
ARCH="${AIE_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;; esac
APP="$ROOT/build/AIELocalScan.app"
BIN="$APP/Contents/MacOS/local-scan"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$ROOT/build/ModuleCache"

xcrun swiftc -O \
  -module-cache-path "$ROOT/build/ModuleCache" \
  -target "$ARCH-apple-macos14" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework Vision \
  -framework AVFoundation \
  -framework Speech \
  -framework NaturalLanguage \
  -framework PDFKit \
  -o "$BIN" \
  "$ROOT/main.swift"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null
ln -sfn "$BIN" "$ROOT/local-scan"
echo "built: $APP"
