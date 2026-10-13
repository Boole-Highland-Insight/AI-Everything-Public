#!/bin/bash
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
AIE_OUTPUT="$AIE_PROJECT/apps/macos/AIEPopup/build/checks"
mkdir -p "$AIE_OUTPUT"
xcrun swiftc -O -parse-as-library -module-cache-path "$AIE_PROJECT/apps/macos/AIEPopup/build/ModuleCache" \
  "$AIE_PROJECT/core/AIEData/Binary16.swift" "$AIE_PROJECT/tests/Binary16Checks.swift" \
  -o "$AIE_OUTPUT/binary16-checks"
"$AIE_OUTPUT/binary16-checks"
