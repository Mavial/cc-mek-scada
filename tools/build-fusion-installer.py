"""Build a self-contained installer for this user's validated SCADA baseline."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "b229b286f4dd60e78beda845f0e2c3a2cbf2e258"

def minify(source):
    source = re.sub(r' --+\[.+]]', '', source)
    source = re.sub(r'^[ \t]*--+.*', '', source, flags=re.MULTILINE)
    source = re.sub(r'''\s*--+(?!.*['"]).*''', '', source)
    source = re.sub(r'^[ \t]+', '', source, flags=re.MULTILINE)
    while '\n\n' in source:
        source = source.replace('\n\n', '\n')
    return source

def digest(source):
    return hashlib.sha256(source.encode()).hexdigest()

def literal(value):
    eq = '='
    while f']{eq}]' in value:
        eq += '='
    return f'([{eq}[!{value}]{eq}]):sub(2)'

SHARED = ['fusion/model.lua', 'fusion/config.lua', 'fusion/configure.lua']
AGENT = SHARED + ['fusion/startup.lua', 'startup.lua']
LIBS = [f'scada-common/{name}.lua' for name in ['constants','util','log','ppm','comms','network']]
LIBS += [f'lockbox/{name}.lua' for name in ['init','util/bit','util/queue','util/stream','util/array',
                                          'digest/md5','digest/sha1','digest/sha2_256','mac/hmac','kdf/pbkdf2']]
AGENT += LIBS
COORDINATOR = SHARED + ['fusion/view.lua', 'coordinator/fusion.lua',
    'coordinator/ui/components/fusion_overview.lua', 'coordinator/threads.lua',
    'coordinator/ui/layout/main_view.lua']
sources,roles = {},{}
for role,paths in [('agent',AGENT),('coordinator',COORDINATOR)]:
    rows=[]
    for path in paths:
        body = 'return shell.run("/fusion/startup")\n' if path == 'startup.lua' else (ROOT/path).read_text(encoding='utf-8')
        sources[path]=minify(body)
        old=[]
        if path in LIBS or path in ('coordinator/threads.lua','coordinator/ui/layout/main_view.lua'):
            baseline=subprocess.check_output(['git','show',f'{BASELINE}:{path}'],cwd=ROOT).decode()
            old=list(dict.fromkeys([digest(baseline),digest(minify(baseline))]))
        # Libraries are optional on an empty computer, while the Coordinator patch needs its exact baseline.
        rows.append({'path':path,'hash':digest(sources[path]),'allowed':old if role=='coordinator' else []})
    roles[role]=rows

serialized_sources='local SOURCES = {\n'+''.join(f'[{json.dumps(k)}]=({literal(v)}),\n' for k,v in sorted(sources.items()))+'}\n'
def row_lua(row):
    allowed=','.join(json.dumps(h) for h in row['allowed'])
    return '{path='+json.dumps(row['path'])+',hash='+json.dumps(row['hash'])+',allowed={'+allowed+'}}'
bundle='local BUNDLE = {\n'+''.join(f'{role}={{\n'+',\n'.join(row_lua(row) for row in rows)+'\n},\n' for role,rows in roles.items())+'}\n'
template=(ROOT/'fusion/installer-template.lua').read_text()
result=template.replace('--@@BUNDLE@@',serialized_sources+bundle)
(ROOT/'install-fusion.lua').write_text(result,encoding='utf-8',newline='\n')
(ROOT/'fusion/install-manifest.json').write_text(json.dumps({'baseline':BASELINE,'roles':roles},indent=2)+'\n',newline='\n')
print(f'Built install-fusion.lua: {len(result.encode())} bytes; agent {len(AGENT)} files; Coordinator {len(COORDINATOR)} files.')
