#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
ARCH="${AIE_ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;;
esac
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Install Xcode Command Line Tools first: xcode-select --install" >&2
  exit 1
fi
mkdir -p "$ROOT/build/ModuleCache"
STAGE="$(mktemp -d "$ROOT/build/.stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/AI Everything.app"
BIN="$APP/Contents/MacOS/AIEPopup"
SDK="$(xcrun --show-sdk-path)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

PROJECT="$(cd "$ROOT/../../.." && pwd)"
bash "$PROJECT/tools/swift_package.sh" build --product AIEPopup -c release --arch "$ARCH" -j 4 \
  -Xswiftc -file-prefix-map -Xswiftc "$PROJECT=/AI-Everything" \
  -Xswiftc -debug-prefix-map -Xswiftc "$PROJECT=/AI-Everything"
SPM_OUT="$(bash "$PROJECT/tools/swift_package.sh" build -c release --arch "$ARCH" --show-bin-path)"
cp "$SPM_OUT/AIEPopup" "$BIN"
# Do not distribute local source paths or debug symbols in the application.
strip -S "$BIN"
# GRDB's only packaged resource is its privacy manifest (no runtime Bundle.module lookup).
# Keep resources inside Contents/Resources so the macOS app can be signed and relocated.
for BUNDLE in "$SPM_OUT/"*.bundle; do
  [ -d "$BUNDLE" ] || continue
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
done
cp "$ROOT/build/spm/checkouts/GRDB.swift/LICENSE" "$APP/Contents/Resources/GRDB-LICENSE.txt"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [ -n "${AIE_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $AIE_VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${AIE_BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $AIE_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
GEMMA_MODELS_SOURCE="${AIE_GEMMA_MODELS_SOURCE:-$HOME/Library/Application Support/AI Everything/Semantic/models}"
bash "$PROJECT/tools/fetch_gemma_models.sh" "$GEMMA_MODELS_SOURCE"
mkdir -p "$APP/Contents/Resources/GemmaModels"
cp "$GEMMA_MODELS_SOURCE/embeddinggemma-2-Q8_0.gguf" "$APP/Contents/Resources/GemmaModels/"
cp "$GEMMA_MODELS_SOURCE/mmproj-embeddinggemma-2-Q8_0.gguf" "$APP/Contents/Resources/GemmaModels/"
cp "$ROOT/Resources/EmbeddingGemma2-SOURCE.txt" "$APP/Contents/Resources/GemmaModels/"
cp "$ROOT/Resources/EmbeddingGemma2-APACHE-2.0.txt" "$APP/Contents/Resources/GemmaModels/"
bash "$PROJECT/tools/build_gemma_runtime.sh" "$APP/Contents/Resources/GemmaRuntime"
cp "$ROOT/Resources/OnboardingDemo-"*.mp4 "$ROOT/Resources/OnboardingDemo-"*.png "$APP/Contents/Resources/"
cp "$PROJECT/tools/setup_local_quickscan.sh" "$APP/Contents/Resources/"
cp "$PROJECT/tools/setup_local_semantic.sh" "$APP/Contents/Resources/"
cp "$PROJECT/tools/pull_local_model.py" "$APP/Contents/Resources/"
if [ -n "${AIE_SIGN_IDENTITY:-}" ]; then
  while IFS= read -r -d '' FILE; do
    codesign --force --options runtime --timestamp --sign "$AIE_SIGN_IDENTITY" "$FILE"
  done < <(find "$APP/Contents/Resources/GemmaRuntime" -type f \( -name '*.dylib' -o -name 'llama-server' \) -print0)
  codesign --force --options runtime --timestamp --sign "$AIE_SIGN_IDENTITY" "$APP"
else
  while IFS= read -r -d '' FILE; do
    codesign --force --sign - "$FILE" >/dev/null
  done < <(find "$APP/Contents/Resources/GemmaRuntime" -type f \( -name '*.dylib' -o -name 'llama-server' \) -print0)
  codesign --force --sign - "$APP" >/dev/null
fi
codesign --verify --deep --strict "$APP"
DEST="$ROOT/build/AI Everything.app"
rm -rf "$DEST"
mv "$APP" "$DEST"
echo "built ($ARCH): $DEST"
