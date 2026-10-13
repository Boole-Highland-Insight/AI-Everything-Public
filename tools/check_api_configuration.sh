#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/apps/macos/AIEPopup/Sources"
OUT="$ROOT/apps/macos/AIEPopup/build/checks"
mkdir -p "$OUT" "$ROOT/apps/macos/AIEPopup/build/ModuleCache"
xcrun swiftc -parse-as-library \
  -module-cache-path "$ROOT/apps/macos/AIEPopup/build/ModuleCache" \
  "$SRC/ScanConfiguration.swift" "$SRC/APIConfiguration.swift" "$SRC/AppLog.swift" "$SRC/GroqClient.swift" \
  "$ROOT/tests/APIConfigurationChecks.swift" -o "$OUT/api-configuration-checks"
"$OUT/api-configuration-checks"
