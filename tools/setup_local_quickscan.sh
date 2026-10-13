#!/bin/bash
# Installs the pinned local vision model into AI Everything's private Ollama directory.
set -euo pipefail

AIE_HOME="${AIE_SEMANTIC_HOME:-$HOME/Library/Application Support/AI Everything/Semantic}"
AIE_RUNTIME="$AIE_HOME/bin/ollama"
AIE_MODEL="${AIE_QUICKSCAN_MODEL:-qwen3-vl:8b-instruct-q4_K_M}"
case "$AIE_MODEL" in
  qwen3-vl:2b-instruct-q4_K_M) AIE_DIGEST="ea422f1e73652a95479954d8572d3c8c6022f628ce2d38a1a04aae1b7f2d5300" ;;
  qwen3-vl:4b-instruct-q4_K_M) AIE_DIGEST="ee4b975b58c17ce268cd19d40db35d5edc64603035d2ffc1fee1968eb0947f7b" ;;
  qwen3-vl:8b-instruct-q4_K_M) AIE_DIGEST="0533d74300e4f9bc367d675d4e64ffd073d50ff16a2b4096cc2e8a1cf8c96319" ;;
  *) echo "Unsupported local scan model: $AIE_MODEL" >&2; exit 2 ;;
esac
AIE_ENDPOINT="http://127.0.0.1:11435"
AIE_SERVER_PID=""
AIE_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/aie-local-quickscan.XXXXXX")"

cleanup() {
  if [ -n "$AIE_SERVER_PID" ]; then
    kill "$AIE_SERVER_PID" 2>/dev/null || true
    wait "$AIE_SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$AIE_SCRATCH"
}
trap cleanup EXIT

if [ ! -x "$AIE_RUNTIME" ]; then
  echo "Installing AI Everything's private Ollama runtime first..."
  bash "$(cd "$(dirname "$0")" && pwd)/setup_local_semantic.sh"
fi

export OLLAMA_HOST=127.0.0.1:11435
export OLLAMA_MODELS="$AIE_HOME/models"
export OLLAMA_NO_CLOUD=1
export OLLAMA_NUM_PARALLEL=1

if ! curl -fsS --max-time 2 "$AIE_ENDPOINT/api/tags" >/dev/null 2>&1; then
  "$AIE_RUNTIME" serve >"$AIE_SCRATCH/server.log" 2>&1 &
  AIE_SERVER_PID=$!
  for _ in {1..30}; do
    if curl -fsS --max-time 2 "$AIE_ENDPOINT/api/tags" >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
fi

python3 "$(cd "$(dirname "$0")" && pwd)/pull_local_model.py" "$AIE_MODEL" --digest "$AIE_DIGEST"
