#!/bin/bash
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
AIE_SOURCE="$AIE_PROJECT/apps/macos/AIEPopup/Sources"
AIE_OUTPUT="$AIE_PROJECT/apps/macos/AIEPopup/build/checks"
mkdir -p "$AIE_OUTPUT"
xcrun swiftc -parse-as-library -module-cache-path "$AIE_PROJECT/apps/macos/AIEPopup/build/ModuleCache" \
  "$AIE_SOURCE/AppWindowPresence.swift" "$AIE_SOURCE/MediaOpenPolicy.swift" "$AIE_SOURCE/MediaExternalOpener.swift" \
  "$AIE_SOURCE/MediaTimeWindow.swift" "$AIE_PROJECT/tests/MediaPlaybackChecks.swift" \
  -o "$AIE_OUTPUT/media-playback-checks"
"$AIE_OUTPUT/media-playback-checks" "$@"
