#!/bin/bash
set -euo pipefail

DEST="${1:?usage: fetch_gemma_models.sh destination-directory}"
BASE='https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/main'
mkdir -p "$DEST"

fetch() {
  local name="$1" expected="$2" file="$DEST/$1" partial="$DEST/$1.partial" actual
  if [ -f "$file" ]; then
    actual="$(openssl dgst -sha256 "$file" | awk '{print $NF}')"
    if [ "$actual" = "$expected" ]; then return; fi
    echo "Gemma model checksum mismatch: $file" >&2
    exit 1
  fi
  curl --fail --location --retry 3 --output "$partial" "$BASE/$name"
  actual="$(openssl dgst -sha256 "$partial" | awk '{print $NF}')"
  if [ "$actual" != "$expected" ]; then
    rm -f "$partial"
    echo "Gemma model download checksum mismatch: $name" >&2
    exit 1
  fi
  mv "$partial" "$file"
}

fetch embeddinggemma-2-Q8_0.gguf 2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135
fetch mmproj-embeddinggemma-2-Q8_0.gguf c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f
