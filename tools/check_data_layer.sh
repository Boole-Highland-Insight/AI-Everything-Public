#!/bin/bash
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$AIE_PROJECT/tools/swift_package.sh" build --product AIEDataChecks -c debug -j 4
"$AIE_PROJECT/apps/macos/AIEPopup/build/spm/debug/AIEDataChecks"
