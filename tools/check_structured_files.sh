#!/bin/bash
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$AIE_PROJECT/tools/swift_package.sh" build --product AIEPopup -c debug -j 4
python3 - "$AIE_PROJECT/apps/macos/AIEPopup/build/spm/debug/AIEPopup" <<'PY'
from pathlib import Path
from zipfile import ZipFile
import json, os, sqlite3, struct, subprocess, sys, tempfile
END=0xfffffffe; FREE=0xffffffff

def msg(body):
    payload=(body+'\0').encode('utf-16-le'); small=len(payload)<4096
    sectors=(len(payload)+511)//512; start=3 if small else 2
    header=bytearray(512);header[:8]=bytes.fromhex('d0cf11e0a1b11ae1')
    for off,val in [(24,62),(26,3),(28,0xfffe),(30,9),(32,6)]:struct.pack_into('<H',header,off,val)
    for off,val in [(44,1),(48,1),(56,4096),(60,2 if small else END),(64,1 if small else 0),(68,END),(72,0)]:struct.pack_into('<I',header,off,val)
    struct.pack_into('<109I',header,76,0,*([FREE]*108))
    fat=[FREE]*128;fat[0]=0xfffffffd;fat[1]=END
    if small:fat[2]=END
    for i in range(sectors):fat[start+i]=start+i+1 if i<sectors-1 else END
    directory=bytearray(512)
    def entry(offset,name,kind,child,sector,size):
        label=(name+'\0').encode('utf-16-le');directory[offset:offset+len(label)]=label
        struct.pack_into('<H',directory,offset+64,len(label));directory[offset+66]=kind;directory[offset+67]=1
        for pos,value in [(68,FREE),(72,FREE),(76,child),(116,sector),(120,size)]:struct.pack_into('<I',directory,offset+pos,value)
    entry(0,'Root Entry',5,1,start if small else END,sectors*512 if small else 0)
    entry(128,'__substg1.0_1000001F',2,FREE,0 if small else start,len(payload))
    mini=[FREE]*128
    for i in range((len(payload)+63)//64 if small else 0):mini[i]=i+1 if i<(len(payload)+63)//64-1 else END
    return bytes(header)+struct.pack('<128I',*fat)+bytes(directory)+(struct.pack('<128I',*mini) if small else b'')+payload.ljust(sectors*512,b'\0')
with tempfile.TemporaryDirectory(prefix='aie-structured-') as tmp:
    root=Path(tmp)/'library';root.mkdir();db=Path(tmp)/'content.sqlite'
    (root/'short.msg').write_bytes(msg('微型流正文 mini message search'))
    (root/'large.msg').write_bytes(msg('标准流长正文\n'*700+' regularbodytail731'))
    (root/'corrupt.msg').write_bytes(b'not an OLE file')
    (root/'feed.xml').write_text('<rss><item version="42"><title>版本发布通知</title><description><![CDATA[修复导入与检索问题]]></description></item></rss>')
    secret=Path(tmp)/'secret.txt';secret.write_text('externalentitymustneverappear')
    (root/'entity.xml').write_text(f'<!DOCTYPE a [<!ENTITY x SYSTEM "{secret.as_uri()}">]><a>&x;</a>')
    with ZipFile(root/'bundle.zip','w') as z:
        z.writestr('资料/guide.md','归档正文 archivebodytail842')
        z.writestr('../escape.md','traversalcontentmustneverappear')
    def run(query):
        r=subprocess.run([sys.argv[1],'--verify-index',str(root),query],env=dict(os.environ,AIE_DATABASE_PATH=str(db)),check=True,capture_output=True,text=True,timeout=60)
        return json.loads(r.stdout)
    assert run('微型流正文')['hits'][0]['name']=='short.msg'
    assert run('regularbodytail731')['hits'][0]['name']=='large.msg'
    assert run('版本发布通知')['hits'][0]['name']=='feed.xml'
    hit=run('archivebodytail842')['hits'][0]
    assert hit['name']=='bundle.zip' and '资料/guide.md' in hit['snippet'] and hit['chunkID']
    con=sqlite3.connect(db)
    text='\n'.join(x[0] for x in con.execute('select text from chunks'))
    assert '修复导入与检索问题' in text and '@version：42' in text
    assert 'externalentitymustneverappear' not in text and 'traversalcontentmustneverappear' not in text
    assert con.execute("select count(*) from chunks c join files f on c.version_id=f.current_version_id where f.relative_path='corrupt.msg'").fetchone()[0]==1
    assert not con.execute('pragma foreign_key_check').fetchall()
    assert not (Path(tmp)/'escape.md').exists()
    print('Structured checks passed: MSG mini/regular streams, corrupt file, XML CDATA/attributes, external entity exclusion, archive member evidence and traversal exclusion. No cloud calls.')
PY
