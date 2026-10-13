#!/bin/bash
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$AIE_PROJECT/tools/swift_package.sh" build --product AIEDataChecks -c debug -j 4
python3 - "$AIE_PROJECT/apps/macos/AIEPopup/build/spm/debug/AIEDataChecks" <<'PY'
from pathlib import Path
import subprocess,sys,tempfile,sqlite3
with tempfile.TemporaryDirectory(prefix='aie-db-lock-') as tmp:
    db=Path(tmp)/'record.sqlite'
    # Initialize schema once, then prove separate processes preserve every concurrent update.
    subprocess.run([sys.argv[1],'--analysis-worker',str(db),'seed'],check=True,timeout=30)
    processes=[subprocess.Popen([sys.argv[1],'--analysis-worker',str(db),str(i)]) for i in range(4)]
    for p in processes: assert p.wait(timeout=30)==0
    con=sqlite3.connect(db)
    assert con.execute("select text_value from analysis_fields where name='count'").fetchone()[0]=='500'
    assert con.execute("select count(*) from analysis_fields where name in ('0','1','2','3') and value_type='bool' and text_value='1'").fetchone()[0]==4
    assert con.execute("select text_value from analysis_fields where name='marker'").fetchone()[0]=='preserved'
    assert con.execute("select text_value from analysis_fields where name='source'").fetchone()[0]=='fixture'
    assert not con.execute('pragma foreign_key_check').fetchall()
    print('Database concurrency checks passed: four processes, 500 merged updates, cloud/provenance preserved.')
PY
