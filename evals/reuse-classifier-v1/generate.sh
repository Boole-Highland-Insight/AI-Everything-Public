#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${PYTHON:-python3}"

"$PYTHON" "$ROOT/generate_non_pptx.py"
"$PYTHON" "$ROOT/generate_pptx.py"
"$PYTHON" "$ROOT/validate_dataset.py"
