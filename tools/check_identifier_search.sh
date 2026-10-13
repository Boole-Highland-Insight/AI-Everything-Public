#!/bin/bash
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$AIE_PROJECT/tools/swift_package.sh" build --product AIEPopup -c debug -j 4
python3 - "$AIE_PROJECT/apps/macos/AIEPopup/build/spm/debug/AIEPopup" <<'PY'
import json, os, pathlib, sqlite3, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix='aie-identifier-') as temporary:
    base=pathlib.Path(temporary); root=base/'library'; root.mkdir(); db=base/'index.sqlite'
    (root/'员工信息.txt').write_text('测试员工的工号是 EMP-12844209。', encoding='utf8')
    (root/'完整编号.txt').write_text('测试工号 844。', encoding='utf8')
    (root/'前缀编号.txt').write_text('测试工号 844209。', encoding='utf8')
    (root/'其他.txt').write_text('其他编号 84411 和 442，不是一个连续编号。', encoding='utf8')
    (root/'英文.txt').write_text('Research project. The approvals workflow is documented here.', encoding='utf8')
    env=dict(os.environ,AIE_DATABASE_PATH=str(db))
    def run(q, mode='--verify-index'):
        return json.loads(subprocess.run([sys.argv[1],mode,str(root),q],env=env,check=True,capture_output=True,text=True,timeout=60).stdout)
    for q in ['12844209','128','844','209','８４４']:
        assert any(h['name']=='员工信息.txt' and '12844209' in h['snippet'] and h['chunkID'] for h in run(q)['hits']), q
    hits=run('844')['hits']
    assert hits[0]['name']=='完整编号.txt', hits
    assert not any(h['name']=='其他.txt' for h in run('8442')['hits'])
    assert not run('sea')['hits'], 'Numeric fragment support must not loosen English word matching'
    assert not run('missingconcept approvals')['hits'], 'Fast path must keep AND semantics'
    fallback=run('missingconcept approvals .txt','--verify-fallback')['hits']
    assert any(h['name']=='英文.txt' and 'approvals' in h['snippet'] for h in fallback), fallback
    assert not run('missingconcept approvals .pptx','--verify-fallback')['hits'], 'Fallback escaped file-type filter'
    con=sqlite3.connect(db)
    vector_count=lambda: con.execute("select count(*) from features where feature_type='text_embedding'").fetchone()[0]
    assert vector_count()==0, 'Test should not require any vectors'
    before=[con.execute('select count(*) from '+t).fetchone()[0] for t in ['chunks','file_versions','analysis_fields']]+[vector_count()]
    # Emulate an already-deployed v8 database, then open through a DB-only command.
    con.execute("create virtual table chunk_fts using fts5(chunk_id unindexed, terms, tokenize='unicode61')")
    con.execute("insert into chunk_fts(chunk_id,terms) select id,text from chunks")
    con.execute("delete from grdb_migrations where identifier='v9_retire_legacy_chunk_fts'")
    con.commit(); con.close()
    subprocess.run([sys.argv[1],'--backup-database',str(base/'migrated-backup.sqlite')],env=env,check=True,capture_output=True,timeout=60)
    con=sqlite3.connect(db)
    after=[con.execute('select count(*) from '+t).fetchone()[0] for t in ['chunks','file_versions','analysis_fields']]+[vector_count()]
    assert after==before, 'FTS migration changed stored analysis or versions'
    assert not con.execute("select 1 from sqlite_master where name='chunk_fts'").fetchall()
    assert con.execute("select count(*) from search_documents_fts where search_documents_fts match '844'").fetchone()[0]>0
    assert con.execute('pragma integrity_check').fetchone()[0]=='ok'
    assert not con.execute('pragma foreign_key_check').fetchall()
    print('Identifier gateway checks passed: full/prefix/interior/suffix queries, evidence, ranking, zero-vector text fallback, type filters and legacy FTS retirement without rescanning.')
PY
