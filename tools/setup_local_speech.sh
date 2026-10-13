#!/bin/bash
set -euo pipefail
AIE_BREW="$(command -v brew || true)"
if [ -z "$AIE_BREW" ]; then
  echo "Install Homebrew from https://brew.sh, then rerun this script." >&2
  exit 1
fi
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "$AIE_BREW" install whisper-cpp
AIE_SPEECH="$HOME/Library/Application Support/AI Everything/Speech"
mkdir -p "$AIE_SPEECH"
chmod 700 "$AIE_SPEECH"
AIE_MODEL="$AIE_SPEECH/ggml-small.bin"
AIE_SHA="1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
if [ -f "$AIE_MODEL" ] && [ "$(LC_ALL=C shasum -a 256 "$AIE_MODEL" | cut -d ' ' -f 1)" = "$AIE_SHA" ]; then
  echo "Whisper small model already installed and verified."
  exit 0
fi
AIE_TEMP="$(mktemp "$AIE_SPEECH/.download.XXXXXX")"
trap 'rm -f "$AIE_TEMP"' EXIT
curl -fL --retry 2 https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin -o "$AIE_TEMP"
[ "$(LC_ALL=C shasum -a 256 "$AIE_TEMP" | cut -d ' ' -f 1)" = "$AIE_SHA" ] || { echo "Model checksum mismatch" >&2; exit 1; }
mv "$AIE_TEMP" "$AIE_MODEL"
echo "Local Whisper model ready. Restart AI Everything to resume audio scanning."
