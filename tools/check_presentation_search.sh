#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/apps/macos/AIEPopup/Sources"
OUT="$ROOT/apps/macos/AIEPopup/build/checks"
mkdir -p "$OUT" "$ROOT/apps/macos/AIEPopup/build/ModuleCache"
xcrun swiftc -parse-as-library -module-cache-path "$ROOT/apps/macos/AIEPopup/build/ModuleCache" \
  "$SRC/ArchiveEntryReader.swift" "$SRC/PresentationReader.swift" "$SRC/../../../../core/AIEData/NumericSearch.swift" \
  "$SRC/SearchArchitecture.swift" "$SRC/LibraryIndex.swift" \
  "$SRC/ScanRecovery.swift" "$SRC/ScanProgress.swift" \
  "$ROOT/tests/PresentationSearchChecks.swift" -o "$OUT/presentation-search-checks"
python3 - "$OUT/presentation-search-checks" <<'PY'
import subprocess, sys, tempfile
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
with tempfile.TemporaryDirectory(prefix='aie-presentation-check-') as directory:
    with ZipFile(Path(directory)/'sample.pptx','w',compression=ZIP_DEFLATED) as z:
        z.writestr('ppt/presentation.xml','<p:presentation xmlns:p="p" xmlns:r="r"><p:sldIdLst><p:sldId r:id="cover"/><p:sldId r:id="flow"/><p:sldId r:id="end"/></p:sldIdLst></p:presentation>')
        z.writestr('ppt/_rels/presentation.xml.rels','<Relationships><Relationship Id="cover" Target="slides/slide1.xml"/><Relationship Id="flow" Target="slides/slide10.xml"/><Relationship Id="end" Target="slides/slide2.xml"/></Relationships>')
        def slide(body): return '<p:sld xmlns:p="p" xmlns:a="a">'+body+'</p:sld>'
        z.writestr('ppt/slides/slide1.xml',slide('<a:p><a:r><a:t>'+('封面'*10000)+'</a:t></a:r></a:p>'))
        z.writestr('ppt/slides/slide10.xml',slide('<a:p><a:r><a:t>流程：提交</a:t></a:r><a:r><a:t>审批 &amp; 归档</a:t></a:r></a:p><a:prstGeom prst="downArrow"/>'))
        z.writestr('ppt/slides/slide2.xml',slide('<a:p><a:r><a:t>量子协同验收</a:t></a:r></a:p><a:prstGeom prst="flowChartConnector"/>'))
    subprocess.run([sys.argv[1],str(Path(directory).resolve())],check=True,timeout=30)
PY
