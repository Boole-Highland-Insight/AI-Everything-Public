#!/bin/bash
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$AIE_PROJECT/tools/swift_package.sh" build --product AIEPopup -c debug -j 4
python3 - "$AIE_PROJECT/apps/macos/AIEPopup/build/spm/debug/AIEPopup" <<'PY'
from pathlib import Path
import hashlib, json, os, sqlite3, subprocess, sys, tempfile, shutil
from zipfile import ZipFile
with tempfile.TemporaryDirectory(prefix='aie-gateway-') as temporary:
    base=Path(temporary).resolve(); root=base/'library'; root.mkdir()
    ppt=root/'sample.pptx'
    with ZipFile(ppt,'w') as z:
        z.writestr('ppt/slides/slide1.xml','<p:sld xmlns:p="p" xmlns:a="a"><a:p><a:r><a:t>封面</a:t></a:r></a:p></p:sld>')
    note=root/'notes.md'; note.write_text('项目审批流程图\n'+'正文\n'*2000+'量子验收终点',encoding='utf8')
    stat=ppt.stat(); side=root/'scanner/sample.pptx.json'; side.parent.mkdir()
    side.write_text(json.dumps({'size':stat.st_size,'mtime':int(stat.st_mtime),'localScan':{'presentation':{'parserVersion':'1','coverage':'all_slide_text_and_shapes','slides':[{'page':3,'member':'ppt/slides/slide3.xml','text':'项目审批流程图','tags':['流程图']}]}},'quickScan':{'blurb_zh':'封面摘要'},'cloudUpload':{'uploadedAt':'fixture-marker'}},ensure_ascii=False),encoding='utf8')
    db=base/'index/content.sqlite'; env=dict(os.environ,AIE_DATABASE_PATH=str(db))
    lecture=root/'lecture.mp4'; lecture.write_bytes(b'fixture with independently saved transcript')
    (side.parent/'lecture.mp4.json').write_text(json.dumps({'localScan':{'mediaTranscript':{'sourceHash':hashlib.sha256(lecture.read_bytes()).hexdigest(),'status':'partial','segments':[{'index':2,'startSeconds':90.0,'endSeconds':135.0,'status':'ready','text':'专利申请证据'}]}}},ensure_ascii=False),encoding='utf8')
    clip=root/'clip.mp4'; clip.write_bytes(b'fixture with sampled visual evidence')
    clip_hash=hashlib.sha256(clip.read_bytes()).hexdigest()
    (side.parent/'clip.mp4.json').write_text(json.dumps({
        'localScan':{'sourceHash':clip_hash,'videoFrames':{'parserVersion':'video-samples-1','frames':[{
            'index':0,'startSeconds':12.0,'endSeconds':13.0,'vision':{'ocr':['站台 A17'],'tags':[]}}]}},
        'deepScan':{'blurb_zh':'画面中出现黄色汽车','keywords_zh':['黄色汽车'],
            'parse':{'sourceHash':clip_hash,'parserVersion':'video-deep-scan-2','model':'fixture'},
            'videoSegments':[{'index':0,'startSeconds':12.0,'endSeconds':13.0,'status':'ready',
                'blurb_zh':'画面中出现黄色汽车','keywords_zh':['黄色汽车']}]}
    },ensure_ascii=False),encoding='utf8')
    invalid=subprocess.run([sys.argv[1],'--verify-index',str(root),'test'],env=dict(env,AIE_DATABASE_PATH=''),capture_output=True,text=True,timeout=10)
    assert invalid.returncode==2, 'Blank database destination must not fall back to user data'
    def run(query):
        return json.loads(subprocess.run([sys.argv[1],'--verify-index',str(root),query],env=env,check=True,capture_output=True,text=True,timeout=60).stdout)
    (root/'accents.txt').write_text('café résumé',encoding='utf8')
    (root/'README.md').write_text('星桥项目发布说明',encoding='utf8')
    assert any(h['name']=='README.md' for h in run('星桥')['hits']), 'README documents must be searchable'
    report=run('流程图')
    assert any(h['name']=='accents.txt' and h['chunkID'] for h in run('cafe')['hits']), 'FTS-only candidate was dropped by memory matching'
    assert all(h['name'].endswith('.pptx') for h in run('流程图 .pptx')['hits']), 'FTS union escaped extension filter'
    audio_hit=run('专利申请')['hits'][0]
    assert audio_hit['name']=='lecture.mp4' and audio_hit['chunkID'] and '01:30–02:15' in audio_hit['snippet'],audio_hit
    assert audio_hit['startSeconds']==90 and audio_hit['endSeconds']==135, audio_hit
    assert audio_hit['tier']=='direct' and 'transcript' in audio_hit['evidenceSources'],audio_hit
    frame_ocr=run('站台')['hits'][0]
    assert frame_ocr['name']=='clip.mp4' and frame_ocr['tier']=='direct' and '00:12–00:13' in frame_ocr['snippet'],frame_ocr
    assert frame_ocr['startSeconds']==12 and frame_ocr['endSeconds']==13, frame_ocr
    assert not run('黄色汽车')['hits'], 'Model video descriptions must stay outside V1 FTS'
    ppt_hit=next(h for h in report['hits'] if h['name']=='sample.pptx')
    assert ppt_hit['page']==3 and ppt_hit['chunkID'] and '第 3 页' in ppt_hit['snippet'],report
    assert ppt_hit['tier']=='direct' and 'body' in ppt_hit['evidenceSources'],ppt_hit
    assert run('量子')['hits'][0]['name']=='notes.md'
    assert json.loads(side.read_text())['cloudUpload']['uploadedAt']=='fixture-marker'
    dbcon=sqlite3.connect(db)
    counts=dbcon.execute('select count(*) from chunks').fetchone()[0]
    run('流程图')
    assert dbcon.execute('select count(*) from chunks').fetchone()[0]==counts
    shutil.rmtree(side.parent)
    after=run('流程图')
    assert any(h['name']=='sample.pptx' and h['page']==3 for h in after['hits']),after
    assert run('专利申请')['hits'][0]['name']=='lecture.mp4'
    assert not side.parent.exists(), 'Runtime recreated scanner JSON directory'
    assert dbcon.execute('select count(*) from analysis_fields').fetchone()[0] > 20
    old_versions=dbcon.execute('select count(*) from file_versions').fetchone()[0]
    note.write_text('改成全新的苹果种植方案',encoding='utf8')
    assert not run('量子')['hits']
    assert dbcon.execute('select count(*) from file_versions').fetchone()[0]==old_versions+1
    assert not dbcon.execute('pragma foreign_key_check').fetchall()
    dbcon.close()
    bad=base/'bad-library'; (bad/'scanner').mkdir(parents=True)
    (bad/'note.md').write_text('可恢复文件')
    damaged=bad/'scanner/note.md.json'; damaged.write_text('{broken')
    bad_db=base/'bad-index.sqlite'; bad_env=dict(os.environ,AIE_DATABASE_PATH=str(bad_db))
    attempt=subprocess.run([sys.argv[1],'--verify-index',str(bad),'文件'],env=bad_env,capture_output=True,text=True,timeout=30)
    assert attempt.returncode==1, 'Corrupt legacy record was silently accepted'
    bad_con=sqlite3.connect(bad_db)
    assert bad_con.execute("select count(*) from migration_imports where source like 'legacy-root:%'").fetchone()[0]==0
    damaged.write_text(json.dumps({'cloudUpload':{'uploadedAt':'repaired'}}))
    subprocess.run([sys.argv[1],'--verify-index',str(bad),'文件'],env=bad_env,check=True,capture_output=True,text=True,timeout=30)
    assert bad_con.execute("select count(*) from migration_imports where source like 'legacy-root:%'").fetchone()[0]==1
    bad_con.close()
    print('Gateway checks passed: sidecar migration, page-labelled UI hits, long text, cloud marker preservation, idempotence, operation without scanner folder, edit invalidation, corrupt-import retry, SQLite foreign keys.')
PY
