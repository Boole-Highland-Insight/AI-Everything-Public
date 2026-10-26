#!/bin/bash
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
AIE_SOURCE="$AIE_PROJECT/apps/macos/AIEPopup/Sources"
AIE_OUTPUT="$AIE_PROJECT/apps/macos/AIEPopup/build/checks"
mkdir -p "$AIE_OUTPUT"
xcrun swiftc -parse-as-library -module-cache-path "$AIE_PROJECT/apps/macos/AIEPopup/build/ModuleCache" \
  "$AIE_SOURCE/../../../../core/AIEData/NumericSearch.swift" "$AIE_SOURCE/SearchArchitecture.swift" \
  "$AIE_SOURCE/LibraryIndex.swift" "$AIE_SOURCE/GroqRerank.swift" "$AIE_SOURCE/JevRerank.swift" "$AIE_SOURCE/GroqClient.swift" \
  "$AIE_SOURCE/MediaOpenPolicy.swift" \
  "$AIE_SOURCE/ScanConfiguration.swift" "$AIE_SOURCE/APIConfiguration.swift" "$AIE_SOURCE/AppLog.swift" "$AIE_PROJECT/tests/RerankChecks.swift" \
  -o "$AIE_OUTPUT/rerank-checks"
"$AIE_OUTPUT/rerank-checks"
