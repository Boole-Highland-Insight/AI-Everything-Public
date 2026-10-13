#!/bin/bash
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
AIE_BUILD="$AIE_PROJECT/apps/macos/AIEPopup/build"
mkdir -p "$AIE_BUILD/ModuleCache" "$AIE_BUILD/spm-config" "$AIE_BUILD/spm-security"
export CLANG_MODULE_CACHE_PATH="$AIE_BUILD/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$AIE_BUILD/ModuleCache"
AIE_SUBCOMMAND="${1:?Expected build or package}"
shift
exec xcrun swift "$AIE_SUBCOMMAND" --package-path "$AIE_PROJECT" --disable-sandbox \
  --scratch-path "$AIE_BUILD/spm" --cache-path "$AIE_BUILD/spm-cache" \
  --config-path "$AIE_BUILD/spm-config" --security-path "$AIE_BUILD/spm-security" "$@"
