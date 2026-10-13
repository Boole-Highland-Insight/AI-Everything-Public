#!/bin/bash
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$AIE_PROJECT/tools/swift_package.sh" build --product AIEDataChecks -c debug -j 4
python3 - "$AIE_PROJECT/apps/macos/AIEPopup/build/spm/debug/AIEDataChecks" <<'PY'
from pathlib import Path
import subprocess, sys, tempfile, time, sqlite3
with tempfile.TemporaryDirectory(prefix='aie-crash-') as temporary:
    for iteration in range(3):
        root=Path(temporary); db=root/f'{iteration}.sqlite'; ready=root/f'{iteration}.ready'
        worker=subprocess.Popen([sys.argv[1],'--crash-worker',str(db),str(ready),'write'])
        try:
            deadline=time.monotonic()+15
            while not ready.exists() and worker.poll() is None and time.monotonic()<deadline:
                time.sleep(.02)
            assert ready.exists(), 'Worker failed before committing checkpoint'
            worker.kill()
            assert worker.wait(timeout=5) == -9
            subprocess.run([sys.argv[1],'--crash-worker',str(db),str(ready),'recover'],check=True,timeout=15)
            with sqlite3.connect(db) as connection:
                assert connection.execute('pragma integrity_check').fetchone()[0]=='ok'
                assert not connection.execute('pragma foreign_key_check').fetchall()
        finally:
            if worker.poll() is None: worker.kill(); worker.wait(timeout=5)
print('Crash recovery: three independently killed/restarted processes passed; no personal files used.')
PY
