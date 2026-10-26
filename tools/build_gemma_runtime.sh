#!/bin/bash
set -euo pipefail

DEST="${1:?usage: build_gemma_runtime.sh destination-directory}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
REV='d8d92973c8c21bb4dd5d592f0fec26fe2cd1e654'
SOURCE="${AIE_LLAMA_CPP_SOURCE:-$PROJECT/apps/macos/AIEPopup/build/llama.cpp}"
CMAKE="${AIE_CMAKE_PATH:-cmake}"

if [ ! -d "$SOURCE/.git" ]; then
  mkdir -p "$SOURCE"
  git -C "$SOURCE" init -q
  git -C "$SOURCE" fetch --depth 1 https://github.com/ggml-org/llama.cpp.git "$REV"
  git -C "$SOURCE" checkout --detach -q FETCH_HEAD
fi
if [ "$(git -C "$SOURCE" rev-parse HEAD)" != "$REV" ]; then
  echo "Expected llama.cpp revision $REV in $SOURCE" >&2
  exit 1
fi

"$CMAKE" -S "$SOURCE" -B "$SOURCE/build-aie" \
  -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_USE_PREBUILT_UI=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_INSTALL_RPATH=@loader_path
"$CMAKE" --build "$SOURCE/build-aie" --target llama-server -j 6

BIN="$SOURCE/build-aie/bin"
mkdir -p "$DEST"
cp "$BIN/llama-server" "$DEST/"
cp -R "$BIN"/lib*.dylib "$DEST/"
cp "$SOURCE/LICENSE" "$DEST/llama.cpp-LICENSE.txt"
printf '%s\n' "$REV" > "$DEST/llama.cpp-REVISION.txt"
