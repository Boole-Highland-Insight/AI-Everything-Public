#!/bin/bash
# Installs a dedicated, loopback-only background vision runtime. Does not scan or upload files.
set -euo pipefail
AIE_SEMANTIC_HOME="${AIE_SEMANTIC_HOME:-$HOME/Library/Application Support/AI Everything/Semantic}"
AIE_VERSION=0.33.3
AIE_SHA256=342db03df80bb9db84ff64246031bd5f70c09b59ff52fa5cc9aaae3476cc4a9d
AIE_PACKAGE="${AIE_OLLAMA_ARCHIVE:-}"
AIE_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/aie-semantic.XXXXXX")"
AIE_SERVER_PID=""
cleanup() {
  if [ -n "$AIE_SERVER_PID" ]; then
    kill "$AIE_SERVER_PID" 2>/dev/null || true
    wait "$AIE_SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$AIE_SCRATCH"
}
trap cleanup EXIT
AIE_EXISTING_VERSION=""
if [ -x "$AIE_SEMANTIC_HOME/bin/ollama" ]; then
  AIE_EXISTING_VERSION="$("$AIE_SEMANTIC_HOME/bin/ollama" --version 2>/dev/null || true)"
fi
if [ ! -x "$AIE_SEMANTIC_HOME/bin/ollama" ] || {
  [ "$(cat "$AIE_SEMANTIC_HOME/runtime-version" 2>/dev/null || true)" != "$AIE_VERSION" ] &&
  [[ "$AIE_EXISTING_VERSION" != "ollama version is $AIE_VERSION" ]]
}; then
if [ -z "$AIE_PACKAGE" ]; then
  AIE_PACKAGE="$AIE_SCRATCH/ollama-darwin.tgz"
  curl -fL --retry 2 --connect-timeout 20 --max-time 600 \
    "https://github.com/ollama/ollama/releases/download/v$AIE_VERSION/ollama-darwin.tgz" -o "$AIE_PACKAGE"
fi
AIE_ACTUAL="$(LC_ALL=C shasum -a 256 "$AIE_PACKAGE" | cut -d ' ' -f 1)"
if [ "$AIE_ACTUAL" != "$AIE_SHA256" ]; then echo 'Runtime checksum mismatch' >&2; exit 1; fi
mkdir -p "$AIE_SEMANTIC_HOME/bin" "$AIE_SEMANTIC_HOME/models"
chmod 700 "$AIE_SEMANTIC_HOME" "$AIE_SEMANTIC_HOME/bin" "$AIE_SEMANTIC_HOME/models"
# Unpack beside the current runtime and swap it in: extracting over files that are in use fails,
# which previously turned a routine upgrade into a failed installation.
rm -rf "$AIE_SEMANTIC_HOME/bin.incoming" "$AIE_SEMANTIC_HOME/bin.previous"
mkdir -p "$AIE_SEMANTIC_HOME/bin.incoming"
LC_ALL=C tar -xzf "$AIE_PACKAGE" -C "$AIE_SEMANTIC_HOME/bin.incoming"
mv "$AIE_SEMANTIC_HOME/bin" "$AIE_SEMANTIC_HOME/bin.previous"
mv "$AIE_SEMANTIC_HOME/bin.incoming" "$AIE_SEMANTIC_HOME/bin"
rm -rf "$AIE_SEMANTIC_HOME/bin.previous"
chmod 700 "$AIE_SEMANTIC_HOME/bin"
printf '%s' "$AIE_VERSION" > "$AIE_SEMANTIC_HOME/runtime-version"
fi
# Model downloads are owned by the native installer; Gemma supplies embeddings.
echo "Runtime ready; model download is handled by the app."
