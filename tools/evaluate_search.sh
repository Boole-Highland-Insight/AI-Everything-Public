#!/bin/bash
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="${1:?Usage: evaluate_search.sh /path/to/suite.json [mode]}"
MODE="${2:-}"
: "${AIE_LIBRARY_ROOT:?Set AIE_LIBRARY_ROOT to the library matching your evaluation suite}"
export AIE_LIBRARY_ROOT
EVAL_SCRATCH=""
if [ -z "${AIE_DATABASE_PATH:-}" ]; then
  PRODUCTION_DATABASE="$HOME/Library/Application Support/AI Everything/Index/content.sqlite"
  if [ ! -f "$PRODUCTION_DATABASE" ]; then
    echo "本机索引不存在；请先在应用中完成资料库初始化。" >&2
    exit 2
  fi
  EVAL_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/aie-search-evaluation.XXXXXX")"
  trap 'rm -rf "$EVAL_SCRATCH"' EXIT
  export AIE_DATABASE_PATH="$EVAL_SCRATCH/content.sqlite"
  sqlite3 "$PRODUCTION_DATABASE" ".backup '$AIE_DATABASE_PATH'"
fi
bash "$AIE_PROJECT/tools/swift_package.sh" build --product AIEPopup -c debug -j 4 >&2
ARGS=(--evaluate-search "$SUITE")
if [ -n "$MODE" ]; then ARGS+=("$MODE"); fi
"$AIE_PROJECT/apps/macos/AIEPopup/build/spm/debug/AIEPopup" "${ARGS[@]}"
