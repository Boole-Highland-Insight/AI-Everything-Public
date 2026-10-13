#!/bin/bash
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$AIE_PROJECT/tools/swift_package.sh" build --product AIEPopup -c debug -j 4
python3 - "$AIE_PROJECT/apps/macos/AIEPopup/build/spm/debug/AIEPopup" <<'PY'
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import json, os, sqlite3, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix='aie-xlsx-') as tmp:
    root=Path(tmp)/'library'; root.mkdir(); book=root/'budget.xlsx'
    db=Path(tmp)/'content.sqlite'; env=dict(os.environ,AIE_DATABASE_PATH=str(db))
    def write_book(final='XLSXTAILARCHIVE731'):
        with ZipFile(book,'w',ZIP_DEFLATED) as z:
            z.writestr('xl/workbook.xml','''<workbook xmlns:r="urn:relationships"><sheets><sheet name="项目预算" sheetId="9" r:id="r2"/><sheet name="隐藏资料" state="hidden" sheetId="2" r:id="r1"/></sheets></workbook>''')
            z.writestr('xl/_rels/workbook.xml.rels','''<Relationships><Relationship Id="r1" Target="worksheets/sheet7.xml"/><Relationship Id="r2" Target="/xl/worksheets/sheet3.xml"/><Relationship Id="external" TargetMode="External" Target="https://example.invalid/never-fetch"/></Relationships>''')
            z.writestr('xl/sharedStrings.xml','''<sst><si><r><t>项目</t></r><r><t>名称 &amp; 内容</t></r><rPh><t>phonetic-not-source</t></rPh></si><si><t>太阳能电池采购</t></si></sst>''')
            rows=['<row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="inlineStr"><is><t>预算金额</t></is></c></row>',
                  '<row r="5"><c r="A5" t="s"><v>1</v></c><c r="C5"><v>1200</v></c><c r="D5"><f>C5*2</f><v>2400</v></c><c r="E5" t="b"><v>1</v></c><c r="F5"><f>1+2</f></c></row>']
            rows += [f'<row r="{i}"><c r="A{i}" t="inlineStr"><is><t>第{i}项日常工作记录</t></is></c></row>' for i in range(6,66)]
            rows += [f'<row r="100"><c r="B100" t="inlineStr"><is><t>{"长单元格"*1000} {final}</t></is></c></row>']
            z.writestr('xl/worksheets/sheet3.xml','<worksheet><sheetData>'+''.join(rows)+'</sheetData><mergeCells><mergeCell ref="A1:B1"/></mergeCells></worksheet>')
            z.writestr('xl/worksheets/sheet7.xml','<worksheet><sheetData><row r="12"><c r="H12" t="inlineStr"><is><t>隐藏工作表检索标记</t></is></c></row></sheetData></worksheet>')
    def run(query):
        return json.loads(subprocess.run([sys.argv[1],'--verify-index',str(root),query],env=env,check=True,capture_output=True,text=True,timeout=60).stdout)
    write_book()
    report=run('太阳能电池采购'); assert report['hits'][0]['name']=='budget.xlsx',report
    assert report['hits'][0]['chunkID'] and '工作表：项目预算' in report['hits'][0]['snippet'],report
    assert run('XLSXTAILARCHIVE731')['hits'], 'Long cell tail was lost'
    assert '隐藏资料' in run('隐藏工作表检索标记')['hits'][0]['snippet']
    con=sqlite3.connect(db)
    records=con.execute("SELECT c.text,c.location_json FROM chunks c JOIN files f ON c.version_id=f.current_version_id WHERE c.kind='sheet_rows'").fetchall()
    text='\n'.join(r[0] for r in records)
    assert 'A1：项目名称 & 内容' in text and 'D5：缓存值：2400（公式：=C5*2）' in text
    assert 'E5：TRUE' in text and 'F5：无缓存结果（公式：=1+2）' in text
    assert 'phonetic-not-source' not in text
    locations=[json.loads(r[1]) for r in records]
    assert any(x['sheet']=='隐藏资料' and x['state']=='hidden' and x['rowStart']==12 for x in locations)
    assert any(x['rowStart']==100 for x in locations)
    assert len(records)>5 and max(len(r[0]) for r in records)<1700
    count=con.execute('SELECT count(*) FROM chunks').fetchone()[0]; run('太阳能')
    assert count==con.execute('SELECT count(*) FROM chunks').fetchone()[0], 'Reload duplicated chunks'
    write_book('XLSXTAILREPLACED842')
    assert not run('XLSXTAILARCHIVE731')['hits'], 'Old workbook body remained searchable'
    assert run('XLSXTAILREPLACED842')['hits']
    assert not con.execute('PRAGMA foreign_key_check').fetchall()
    print('Spreadsheet checks passed: relationships, shared/inline/rich strings, sparse rows, hidden sheets, formula caches, long cells, row locations, reload and edit invalidation. No cloud calls.')
PY
