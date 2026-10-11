"""Build the two-file visual update for the already commissioned fusion extension."""
from pathlib import Path
import hashlib
import json
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASELINE = 'a5b921b205d25b45ce88bfc4a5ad55d211abd1c1'
# Also keep the full fresh-install bundle current; share its literal/minifier helpers.
helpers = runpy.run_path(str(ROOT/'tools/build-fusion-installer.py'))
minify, literal = helpers['minify'], helpers['literal']
digest = lambda value: hashlib.sha256(value.encode()).hexdigest()
sources,rows = {},[]
for path in ['fusion/view.lua','coordinator/fusion.lua']:
    sources[path]=minify((ROOT/path).read_text())
    old=subprocess.check_output(['git','show',f'{BASELINE}:{path}'],cwd=ROOT).decode()
    rows.append({'path':path,'hash':digest(sources[path]),'allowed':list(dict.fromkeys([digest(old),digest(minify(old))]))})
for path in ['lockbox/digest/sha2_256.lua','lockbox/util/stream.lua','lockbox/util/queue.lua','lockbox/util/bit.lua']:
    sources[path]=minify((ROOT/path).read_text())
source_lua='local SOURCES={\n'+''.join(f'[{json.dumps(k)}]={literal(v)},\n' for k,v in sorted(sources.items()))+'}\n'
def row_lua(row):
    return '{path='+json.dumps(row['path'])+',hash='+json.dumps(row['hash'])+',allowed={'+','.join(json.dumps(h) for h in row['allowed'])+'}}'
bundle='local BUNDLE={coordinator={\n'+',\n'.join(row_lua(row) for row in rows)+'\n}}\n'
template=(ROOT/'fusion/installer-template.lua').read_text()
template=template.replace('local rows = BUNDLE[role]','assert(role == "coordinator", "Run this visual update on the Coordinator.")\nlocal rows = BUNDLE[role]')
template=template.replace('/.scada-fusion-1/','/.scada-fusion-style-1/').replace('install-fusion recover','install-fusion-style recover')
template=template.replace('Fusion monitoring','Fusion display styling').replace('fusion-monitoring-1','fusion-style-1')
template=template.replace('print("Next: fusion/configure "..role)','print("Settings preserved. Next: startup")')
result=template.replace('--@@BUNDLE@@',source_lua+bundle)
(ROOT/'install-fusion-style.lua').write_text(result,encoding='utf-8',newline='\n')
(ROOT/'fusion/style-manifest.json').write_text(json.dumps({'baseline':BASELINE,'roles':{'coordinator':rows}},indent=2)+'\n',newline='\n')
print(f'Built install-fusion-style.lua: {len(result.encode())} bytes, two Coordinator files.')
