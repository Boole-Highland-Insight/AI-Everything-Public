#!/bin/bash
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PROJECT/apps/macos/AIEPopup/build/AI Everything.app"
BIN="$APP/Contents/MacOS/AIEPopup"
test -x "$APP/Contents/Resources/GemmaRuntime/llama-server"
test -f "$APP/Contents/Resources/GemmaModels/embeddinggemma-2-Q8_0.gguf"
test -f "$APP/Contents/Resources/GemmaModels/mmproj-embeddinggemma-2-Q8_0.gguf"
test ! -e "$APP/Contents/Resources/digup"

TEMP="$(mktemp -d /tmp/aie-gemma-native.XXXXXX)"
trap 'rm -rf "$TEMP"' EXIT
mkdir "$TEMP/files"
printf 'A red square is shown in this image.\n' > "$TEMP/files/notes.txt"
python3 - "$TEMP/files/red.png" <<'PY'
import struct, sys, zlib
width = height = 256
scanline = b'\0' + b'\xff\0\0' * width
pixels = zlib.compress(scanline * height)
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
with open(sys.argv[1], 'wb') as output:
    output.write(b'\x89PNG\r\n\x1a\n')
    output.write(chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)))
    output.write(chunk(b'IDAT', pixels))
    output.write(chunk(b'IEND', b''))
PY
AIE_DATABASE_PATH="$TEMP/index.sqlite" "$BIN" --verify-gemma "$TEMP/files" 'red square'
