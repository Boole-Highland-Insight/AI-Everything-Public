#!/bin/bash
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$AIE_PROJECT/tools/swift_package.sh" build --product AIEPopup -c debug -j 4
python3 - "$AIE_PROJECT/apps/macos/AIEPopup/build/spm/debug/AIEPopup" <<'PY'
from pathlib import Path
import os,subprocess,sys,tempfile,sqlite3
with tempfile.TemporaryDirectory(prefix='aie-storage-') as directory:
    base=Path(directory).resolve(); library=base/'library'; library.mkdir()
    db=base/'db/content.sqlite'
    env=dict(os.environ,AIE_DATABASE_PATH=str(db),AIE_TRASH_PATH=str(base/'trash'))
    subprocess.run([sys.argv[1],'--verify-storage',str(library)],env=env,check=True,timeout=30)
    backup=base/'backup.sqlite'
    subprocess.run([sys.argv[1],'--backup-database',str(backup)],env=env,check=True,timeout=30)
    con=sqlite3.connect(backup)
    assert con.execute('pragma integrity_check').fetchone()[0]=='ok'
    assert con.execute('select count(*) from analysis_records').fetchone()[0]>=2
    assert not con.execute('pragma foreign_key_check').fetchall()
    assert backup.stat().st_mode & 0o777 == 0o600
    compact=base/'compact.sqlite'
    subprocess.run([sys.argv[1],'--compact-database',str(compact)],env=env,check=True,timeout=30)
    con=sqlite3.connect(compact)
    assert con.execute('pragma integrity_check').fetchone()[0]=='ok'
    assert not con.execute('pragma foreign_key_check').fetchall()
    assert compact.stat().st_mode & 0o777 == 0o600
    print('Backup and compact-copy integrity with private permissions passed.')
PY
