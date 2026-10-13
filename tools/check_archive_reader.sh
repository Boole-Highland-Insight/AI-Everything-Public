#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/apps/macos/AIEPopup/build/checks"
mkdir -p "$OUT" "$ROOT/apps/macos/AIEPopup/build/ModuleCache"
xcrun swiftc -parse-as-library \
  -module-cache-path "$ROOT/apps/macos/AIEPopup/build/ModuleCache" \
  "$ROOT/apps/macos/AIEPopup/Sources/ArchiveEntryReader.swift" \
  "$ROOT/tests/ArchiveEntryReaderChecks.swift" -o "$OUT/archive-reader-checks"
python3 - "$OUT/archive-reader-checks" <<'PY'
from pathlib import Path
import subprocess
import sys
import tempfile
from zipfile import ZipFile, ZIP_DEFLATED

with tempfile.TemporaryDirectory(prefix="aie-archive-check-") as directory:
    archive = Path(directory) / "large-slide.pptx"
    with ZipFile(archive, "w", compression=ZIP_DEFLATED) as output:
        output.writestr("ppt/slides/slide1.xml", b"A" * (2 * 1024 * 1024))
    # The old wait-before-read ordering hangs; fail instead of waiting indefinitely.
    subprocess.run([sys.argv[1], str(archive)], check=True, timeout=10)
PY
