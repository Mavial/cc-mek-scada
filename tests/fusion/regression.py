"""Run the fusion extension in Lua 5.2 with ComputerCraft host APIs simulated.

Install lupa (and Pillow for previews), then run python tests/fusion/regression.py.
The shipped collector, NIC/HMAC, graphics and transaction installer execute here.
No world, reactor actuator, or external service is accessed.
"""
from __future__ import annotations
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent / 'scada-seven-wide/.test-deps'))
from lupa.lua52 import LuaRuntime
from cc_filesystem import CCFilesystem, SimulatedPowerLoss

MANIFEST = json.loads((ROOT/'fusion/install-manifest.json').read_text())
INSTALLER = (ROOT/'install-fusion.lua').read_text()
COUNT = 0

def lua_value(value):
    if hasattr(value, 'items'):
        pairs = dict(value.items())
        if pairs and set(pairs) == set(range(1, len(pairs)+1)):
            return [lua_value(pairs[i]) for i in range(1,len(pairs)+1)]
        return {str(k):lua_value(v) for k,v in pairs.items()}
    return value

def runtime():
    lua=LuaRuntime(unpack_returned_tuples=True,encoding='latin1')
    lua.globals().package.path = str(ROOT/'?.lua').replace('\\','/')+';'+str(ROOT/'?/init.lua').replace('\\','/')
    lua.execute((HERE/'cc_fixture.lua').read_text())
    lua.execute('os.getComputerID=function() return 9 end; sleep=function() end')
    lua.globals().textutils=lua.table_from({
        'serialize':lambda v,*_:json.dumps(lua_value(v),sort_keys=True,separators=(',',':')),
        'serializeJSON':lambda v:json.dumps(lua_value(v),separators=(',',':')),
        'unserializeJSON':lambda v:lua.table_from(json.loads(v),recursive=True)})
    return lua

def snapshot(lua, seq=1):
    report=lua.execute('return '+(HERE/'server-probe.txt').read_text())
    lua.globals().report=report
    # Two capacity getters were listed but not read by the commissioning probe.
    # Their positive fixture values are synthetic, not claimed server readings.
    lua.execute('''
      getter_calls={}
      function probe_call(name,method)
        getter_calls[#getter_calls+1]={name,method}
        assert(method:sub(1,3)=="get" or method:sub(1,2)=="is","ACTUATOR CALLED")
        for _,p in ipairs(report.peripherals) do
          if p.name==name then
            local known=false
            for _,m in ipairs(p.methods) do known=known or m==method end
            assert(known,"Unlisted server method: "..method)
            if p.readings[method] and p.readings[method].ok then return p.readings[method].values[1] end
            if method=="getDeuteriumCapacity" or method=="getTritiumCapacity" then return 1000 end
            error("Probe reading unavailable")
          end
        end
        error("Peripheral not attached")
      end
      agent_config={reactor="fusionReactorLogicAdapter_0",port="fusionReactorPort_0",laser="laserAmplifier_0",
        modem="left",auth_key="",role="agent",channel=16245}
    ''')
    result=lua.eval('require("fusion.model").collect')(lua.globals().probe_call,lua.globals().agent_config,1000000,999999,seq)
    lua.globals().sample=result
    return result

def check(condition, message):
    global COUNT
    assert condition,message
    COUNT+=1

def model_tests():
    lua=runtime(); data=snapshot(lua); model=lua.eval('require("fusion.model")')
    check(len(data.errors)==0,'live commissioning getters failed')
    check(data.production==199825616 and data.dt==500 and data.hohlraum_fuel==10,'server values changed')
    check(model.status(data)[0]=='RUNNING','premixed feed incorrectly considered unavailable')
    check(all(lua.globals().getter_calls[i][2].startswith(('get','is')) for i in range(1,len(lua.globals().getter_calls)+1)),'write method used')
    receiver=model.receiver(9)
    check(receiver.accept(9,data,1000000),'fresh data rejected')
    for label, mutate in [('wrong id',None),('duplicate',None),('stale',{'sample_ms':994999}),
        ('future',{'sample_ms':1002001}),('nan',{'production':float('nan')}),('infinite',{'dt':float('inf')}),
        ('negative',{'production':-1}),('bad boolean',{'formed':'true'}),('bad schema',{'schema':2}),
        ('bad session',{'session':1000001}),('bad sequence',{'seq':0}),('bad mode',{'laser_mode':'BOGUS'})]:
        candidate=lua.table_from(lua_value(data),recursive=True)
        # Empty Lua lists serialize as {} in Python and remain valid empty tables.
        if mutate:
            for k,v in mutate.items(): candidate[k]=v
        check(not receiver.accept(8 if label=='wrong id' else 9,candidate,1000000),label+' accepted')
    candidate=snapshot(lua,2); candidate.ignited=False
    check(receiver.accept(9,candidate,1000000) and receiver.snapshot(1000000)[0].ignited is False,'false boolean lost')
    check(receiver.snapshot(1005000)[0] is None,'expired values shown live')
    candidate=snapshot(lua,1); candidate.session=1000001; candidate.sample_ms=1000001
    check(receiver.accept(9,candidate,1000001),'reboot sequence reset rejected')
    check(receiver.snapshot(1000000)[1]==0,'future tolerance produced negative age')
    check(not receiver.accept(9,data,1000001),'previous boot packet accepted')
    check(model.format(-10,'C')=='-10.00 C','negative Celsius lost')
    lua.execute('partial=require("fusion.model").collect(function() error("unplugged") end,agent_config,1000000,999999,1)')
    check(len(lua.globals().partial.errors)==8 and model.status(lua.globals().partial)[0]=='READ ERROR','disconnect did not produce bounded partial data')

def enable(lua, source=9, key=''):
    lua.execute('''
      peripheral={wrap=function() return nil end,hasType=function() return false end}
      options={role="coordinator",monitor="monitor_fusion",source=9,channel=16245}
      require("fusion.config").load=function() return options end
      bp={nics={}}
      ccfg={MainDisplay="monitor_main",FlowDisplay="monitor_flow",UnitDisplays={"monitor_unit"},
        SVR_Channel=16240,CRD_Channel=16241,PKT_Channel=16242,AuthKey=""}
    ''')
    lua.globals().options.source=source; lua.globals().ccfg.AuthKey=key
    lua.eval('require("coordinator.fusion").init')(lua.globals().bp,lua.globals().ccfg)

def network_tests():
    # Actual SCADA NIC, authenticated frames, and Coordinator receiver in one runtime;
    # the receive computer is changed only by the native frame destination being broadcast.
    for key in ['', 'fixture-only-secret']:
        lua=runtime(); snapshot(lua); enable(lua,key=key)
        lua.execute('''
          sent={}; opened={}; current_message=nil
          modem={isWireless=function() return true end,open=function(c) opened[c]=true end,
            close=function(c) opened[c]=nil end,closeAll=function() opened={} end,
            transmit=function(channel,reply,message) sent[#sent+1]={channel,reply,message} end}
          peripheral.getNames=function() return {"left"} end
          peripheral.getType=function() return "modem" end
          peripheral.wrap=function() return modem end
          local ppm=require("scada-common.ppm");ppm.mount_all()
          local net=require("scada-common.network")
          if #ccfg.AuthKey>=8 then net.init_mac(ccfg.AuthKey) end
          nic=net.nic(ppm.get_periph("left"));bp.nics.left=nic
          local frame=require("scada-common.comms").scada_frame()
          frame.make(require("scada-common.comms").BROADCAST,1,97,{sample})
          nic.transmit(16245,16245,frame)
          fusion=require("coordinator.fusion")
          assert(fusion.receive("left",16245,16245,sent[1][3],0))
          publish_samples();fusion.tick(db,true)
        ''')
        ps=lua.eval('require("coordinator.fusion").ps')
        check(ps.get('status')=='RUNNING','actual NIC telemetry not accepted with key='+str(bool(key)))
        check('201.83' in ps.get('total'),'total missing actual turbine + fusion output')
        check(lua.globals().opened[16245] is True,'Coordinator channel not opened')
        check(lua.eval('fusion.receive("left",16241,16241,{},0)') is False,'stock channel intercepted')
        if key:
            lua.execute('sample.seq=2;sample.production=7;local f=require("scada-common.comms").scada_frame();f.make(-1,2,97,{sample});nic.transmit(16245,16245,f)')
            lua.execute('sent[2][3][3]="invalid-mac";fusion.receive("left",16245,16245,sent[2][3],0);fusion.tick(db,true)')
            check(ps.get('fusion')!='7.00 FE/t','invalid-MAC packet accepted')
        lua.execute('os.epoch=function() return 1005001 end;fusion.tick(db,true)')
        check(ps.get('status')=='NO LIVE DATA' and ps.get('total')=='--','lost radio keeps stale total')
    # Configuration must never steal existing displays or channels.
    for field,value in [('monitor','monitor_main'),('channel',16241)]:
        lua=runtime(); enable(lua); lua.globals().options[field]=value
        lua.eval('require("coordinator.fusion").init')(lua.globals().bp,lua.globals().ccfg)
        check(not lua.eval('require("coordinator.fusion").enabled')(),'reserved SCADA resource accepted')

def frame(lua):
    w,h=lua.globals().screen.getSize()
    return [lua.globals().screen.getLine(i) for i in range(1,h+1)]

def preview(lua, name):
    try:
        from PIL import Image,ImageDraw,ImageFont
    except ImportError:
        return
    palette=['#f0f0f0','#f2b233','#e57fd8','#99b2f2','#dede6c','#7fcc19','#f2b2cc','#4c4c4c',
             '#999999','#4c99b2','#b266e5','#3366cc','#7f664c','#57a64e','#cc4c4c','#111111']
    w,h=lua.globals().screen.getSize(); img=Image.new('RGB',(w*10,h*16));draw=ImageDraw.Draw(img)
    fonts=[Path('C:/Windows/Fonts/consola.ttf'),Path('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf')]
    font=next((ImageFont.truetype(str(p),13) for p in fonts if p.exists()),ImageFont.load_default())
    for y,(text,fg,bg) in enumerate(frame(lua)):
        for x,ch in enumerate(text):
            draw.rectangle((x*10,y*16,(x+1)*10-1,(y+1)*16-1),fill=palette[int(bg[x],16)])
            if ch!=' ':draw.text((x*10,y*16),ch if 32<=ord(ch)<127 else '.',font=font,fill=palette[int(fg[x],16)])
    out=HERE/'previews';out.mkdir(exist_ok=True);img.save(out/(name+'.png'))

def render_tests():
    for width in [143,164]:
        for layout,height in [('main',52),('flow',38)]:
            for coolant in ['sodium','water']:
                lua=runtime()
                if coolant=='water':lua.execute('db.units[1].num_boilers=0;db.units[1].boiler_data_tbl={}')
                lua.globals().load_layout(layout,width,height)
                original=frame(lua)
                check(len(lua.globals().clips)==0,f'disabled extension clips {layout}/{width}/{coolant}')
                # Compare unchanged exact graphics with the existing seven-wide patch.
                ref=runtime(); ref.globals().package.path=str(ROOT.parent/'scada-seven-wide/patched/?.lua').replace('\\','/')+';'+ref.globals().package.path
                if coolant=='water':ref.execute('db.units[1].num_boilers=0;db.units[1].boiler_data_tbl={}')
                ref.globals().load_layout(layout,width,height)
                check(original==frame(ref),'disabled extension changed existing layout')
        lua=runtime(); snapshot(lua); enable(lua); lua.globals().load_layout('main',width,52)
        ps=lua.eval('require("coordinator.fusion").ps')
        for k,v in [('status','RUNNING'),('fusion','79.93 MFE/t'),('fission','800.00 kFE/t'),('total','80.73 MFE/t'),('age','0.1s')]:ps.publish(k,v)
        check(len(lua.globals().clips)==0,'enabled fusion summary clips')
        text='\n'.join(row[0] for row in frame(lua))
        check('FUSION / GENERATION' in text and '79.93' in text,'overview values absent')
        ref=runtime();ref.globals().load_layout('main',width,52)
        baseline=frame(ref); current=frame(lua); start=106 if width==143 else 83
        for y,(row,old) in enumerate(zip(current,baseline)):
            for content,prior in zip(row,old):
                if 2<=y<19:
                    check(content[:start]==prior[:start] and content[-1:]==prior[-1:],'fusion summary overwrote an existing panel')
                else:check(content==prior,'fusion summary changed an unrelated screen row')
        # Existing safety and operation buttons remain hit-testable and interlocked.
        for label,expected in [('FAC SCRAM','fac_scram'),('SAVE','save'),('START','process_start'),('STOP','process_stop')]:
            positions=[(line.index(label)+1,y+1) for y,line in enumerate(row[0] for row in frame(lua)) if label in line]
            check(len(positions)==1,'button duplicated or hidden: '+label)
            x,y=positions[0];before=len(lua.globals().calls)
            event=lua.eval('require("graphics.events").new_mouse_event')('monitor_touch','test',x,y)
            lua.globals().root.handle_mouse(event)
            check(expected in [lua.globals().calls[i].name for i in range(before+1,len(lua.globals().calls)+1)],'button not working: '+label)
        preview(lua,'main-'+str(width))
    lua=runtime(); data=snapshot(lua); lua.globals().setup_monitor(79,52);lua.execute('screen.setTextScale=function() end')
    context=lua.table_from({'age':100,'fission':2000000,'energy_label':'FE','temp_label':'K',
        'energy_convert':lua.eval('function(v) return v*0.4 end'),'temp_convert':lua.eval('function(v) return v end')})
    draw=lua.eval('require("fusion.view").draw');draw(lua.globals().screen,data,context)
    text='\n'.join(row[0] for row in frame(lua))
    check('79.93 MFE/t' in text and '80.73 MFE/t' in text,'4x4 generation units incorrect')
    check('10 mB D-T' in text and 'THRESHOLD' in text and 'READ-ONLY' in text,'4x4 ignition data absent')
    check(len(lua.globals().clips)==0,'4x4 screen clips')
    preview(lua,'fusion-running')
    draw(lua.globals().screen,None,context); text='\n'.join(row[0] for row in frame(lua))
    check('NO LIVE DATA' in text and '79.93' not in text,'offline screen retains stale readings')
    preview(lua,'fusion-offline')
    data.errors=lua.table_from(['fusionReactorLogicAdapter_0: getCaseTemperature unavailable']);data.casing=None
    draw(lua.globals().screen,data,context)
    check('RUNNING / PARTIAL DATA' in '\n'.join(row[0] for row in frame(lua)),'partial read hidden')
    data.formed=False;draw(lua.globals().screen,data,context)
    check('UNFORMED' in '\n'.join(row[0] for row in frame(lua)),'unformed reactor shown running')

def installer_runtime(fs,command,role):
    lua=runtime();fs.lua=lua;messages=[]
    api={name:getattr(fs,name) for name in ['exists','isDir','getDir','getFreeSpace','getSize','makeDir','move','delete','open']}
    def copy_file(src,dst):
        if fs.exists(dst):raise OSError('Copy destination exists')
        f=fs.open(dst,'wb');f.write(fs.files[fs.path(src)].decode('latin1'));f.close()
    api['copy']=copy_file
    lua.globals().fs=lua.table_from(api);lua.globals().print=lambda *a:messages.append(' '.join(map(str,a)))
    try:
        lua.execute(INSTALLER,command,role)
        return True,messages
    except Exception as ex:
        return False,str(ex)

def fixture(role):
    files={'/log.txt':b'unrelated log\n','/fusion/settings.json':b'{"preserve":"this configuration"}\n'}
    if role=='coordinator':
        files['/coordinator/startup.lua']=(ROOT/'coordinator/startup.lua').read_bytes()
        files['/coordinator.settings']=b'{MainDisplay="monitor_23"}\n'
        for row in MANIFEST['roles'][role]:
            if row['allowed']:
                files['/'+row['path']]=subprocess.check_output(['git','show',MANIFEST['baseline']+':'+row['path']],cwd=ROOT)
    return CCFilesystem(files)

def original(fs,files,role):
    for path,body in files.items():assert fs.files.get(path)==body,path+' not restored'
    for row in MANIFEST['roles'][role]:
        path='/'+row['path']
        if path not in files:assert path not in fs.files,path+' not removed'

def installed(fs,role):
    for row in MANIFEST['roles'][role]:
        assert hashlib.sha256(fs.files['/'+row['path']].replace(b'\r\n',b'\n')).hexdigest()==row['hash'],row['path']

def installer_tests():
    for role in ['agent','coordinator']:
        fs=fixture(role);before=fs.snapshot()
        check(installer_runtime(fs,'check',role)[0] and fs.snapshot()==before,'check mutated '+role)
        ok,detail=installer_runtime(fs,'install',role);check(ok,'install failed '+role+': '+str(detail));installed(fs,role)
        mutations=list(fs.mutations);saved=fs.snapshot()
        check(installer_runtime(fs,'install',role)[0] and saved==fs.snapshot(),'repeat install not idempotent')
        check(installer_runtime(fs,'undo',role)[0],'undo failed');original(fs,before[0],role)
        check(not any(p.startswith('/.scada-fusion-1/'+role) for p in fs.files),'backup not removed')
        # Unknown existing source is refused before any write.
        fs=fixture(role);path='/'+MANIFEST['roles'][role][0]['path'];fs.files[path]=b'-- custom unrelated file\n';saved=fs.snapshot()
        check(not installer_runtime(fs,'install',role)[0] and saved==fs.snapshot(),'edited file overwritten')
        fs=fixture(role);fs.capacity=sum(map(len,fs.files.values()))+100;saved=fs.snapshot()
        check(not installer_runtime(fs,'install',role)[0] and saved==fs.snapshot(),'low-space preflight mutated')
        # Interrupt before/after every filesystem mutation, then recover in a new Lua VM.
        for index in range(1,len(mutations)+1):
            for when in ['before','after']:
                fs=fixture(role);files=copy.deepcopy(fs.files);fs.cut_at=(index,when)
                ok,_=installer_runtime(fs,'install',role)
                check(not ok,'power cut failed to interrupt')
                resumed=fs.resumed();ok,detail=installer_runtime(resumed,'recover',role)
                check(ok,f'recovery {role} #{index} {when}: {detail}')
                original(resumed,files,role)
        print(f'PASS {role}: {len(mutations)*2} installation interruption boundaries',flush=True)
    fs=fixture('agent');fs.files['/reactor-plc/startup.lua']=b'-- active PLC';saved=fs.snapshot()
    check(not installer_runtime(fs,'install','agent')[0] and saved==fs.snapshot(),'agent overwrote PLC computer')
    fs=fixture('coordinator');installer_runtime(fs,'install','coordinator')
    backup='/.scada-fusion-1/coordinator/original/coordinator/threads.lua';fs.files[backup]=b'corrupted backup';saved=fs.snapshot()
    check(not installer_runtime(fs,'undo','coordinator')[0] and saved==fs.snapshot(),'corrupt backup allowed partial undo')

def agent_boot_tests():
    # Boot only files delivered by the installer. No checkout module fallback.
    for key in ['', 'fixture-only-secret']:
        fs=fixture('agent');ok,detail=installer_runtime(fs,'install','agent');assert ok,detail
        lua=runtime();snapshot(lua);config=lua_value(lua.globals().agent_config);config['auth_key']=key
        fs.files['/fusion/settings.json']=json.dumps(config).encode();fs.lua=lua
        lua.globals().fs=lua.table_from({n:getattr(fs,n) for n in ['exists','open','getFreeSpace']})
        lua.globals().source_for_module=lambda path:fs.files.get('/'+path,b'').decode('latin1')
        lua.execute('''
          setup_monitor(51,19);print=function() end
          local builtin_strings=package.preload["cc.strings"]()
          local loaded={}
          function require(name)
            if name=="cc.strings" then return builtin_strings end
            if name=="bit32" then return bit32 end
            if name=="string" then return string end
            if name=="math" then return math end
            if loaded[name] then return loaded[name] end
            local path=name:gsub("%.","/")..".lua"
            local source=source_for_module(path)
            if source=="" then source=source_for_module(name:gsub("%.","/").."/init.lua") end
            assert(source~="","Missing delivered dependency: "..name)
            loaded[name]=assert(load(source,"@"..path))() or true
            return loaded[name]
          end
          sent={};opened={}
          function make_modem() return {isWireless=function() return true end,open=function(c) opened[c]=true end,
            close=function(c) opened[c]=nil end,closeAll=function() opened={} end,
            transmit=function(c,r,m) sent[#sent+1]={c,r,m} end} end
          peripheral={getNames=function() return {"left","fusionReactorLogicAdapter_0","fusionReactorPort_0","laserAmplifier_0"} end,
            getType=function(n) return n=="left" and "modem" or "machine" end,
            wrap=function(n) return n=="left" and make_modem() or {} end,call=probe_call}
          local timer=0
          os.startTimer=function() timer=timer+1;return timer end
          local events={{"timer",1},{"peripheral_detach","left"},{"timer",2},{"peripheral","left"},{"timer",3},{"terminate"}}
          os.pullEventRaw=function() return table.unpack(table.remove(events,1)) end
          shell={run=function() require("fusion.startup");return true end}
          assert(load(source_for_module("startup.lua"),"@startup.lua"))()
        ''')
        check(len(lua.globals().sent)==3,'agent timer/reconnect boot failed')
        check(lua.globals().opened[16245] is None,'agent exit did not close its channel')
        packet=lua.globals().sent[1][3]
        check(len(packet)==(4 if key else 5),'installed agent authentication framing wrong')

def configure_tests():
    lua=runtime();fs=fixture('agent');fs.lua=lua
    lua.globals().fs=lua.table_from({n:getattr(fs,n) for n in ['exists','open','makeDir']})
    lua.execute('''
      write=function() end;print=function() end;read=function() return "" end
      peripheral={getNames=function() return {"right","fusionReactorLogicAdapter_0","fusionReactorPort_0","laserAmplifier_0","left"} end,
        hasType=function(n,t)
          return n=="fusionReactorLogicAdapter_0" and t=="fusionReactorLogicAdapter" or
            n=="fusionReactorPort_0" and t=="fusionReactorPort" or
            n=="laserAmplifier_0" and t=="laserAmplifier" or (n=="left" or n=="right") and t=="modem"
        end,call=function(n,m) assert(m=="isWireless");return n=="left" end}
    ''')
    lua.execute((ROOT/'fusion/configure.lua').read_text(),'agent')
    settings=json.loads(fs.files['/fusion/settings.json'])
    check(settings['modem']=='left' and settings['reactor']=='fusionReactorLogicAdapter_0','wizard selected wired modem / wrong adapter')
    check(settings['channel']==16245 and settings['auth_key']=='','wizard default channel/key changed')
    lua=runtime();fs=fixture('coordinator');fs.lua=lua
    lua.globals().fs=lua.table_from({n:getattr(fs,n) for n in ['exists','open','makeDir']})
    lua.execute('''
      write=function() end;print=function() end;read=function() return "" end
      settings={load=function() return true end,get=function(k,d)
        local values={MainDisplay="main",FlowDisplay="flow",UnitDisplays={"unit"},SVR_Channel=16240,CRD_Channel=16241,PKT_Channel=16242}
        return values[k] or d
      end}
      local display=setup_monitor(79,52);display.setTextScale=function(s) assert(s==0.5) end
      peripheral={getNames=function() return {"main","flow","unit","monitor_fusion"} end,
        hasType=function(_,t) return t=="monitor" end,wrap=function(n) assert(n=="monitor_fusion","wizard touched an assigned display");return display end}
    ''')
    lua.execute((ROOT/'fusion/configure.lua').read_text(),'coordinator')
    settings=json.loads(fs.files['/fusion/settings.json'])
    check(settings['monitor']=='monitor_fusion' and settings['source']==9,'wizard rejected actual 4x4 screen / wrong computer')

if __name__=='__main__':
    for name,test in [('model',model_tests),('NIC/HMAC',network_tests),('graphics',render_tests),('installer',installer_tests),('agent boot',agent_boot_tests),('configure',configure_tests)]:
        test();print('PASS '+name,flush=True)
    print(f'{COUNT} checks passed',flush=True)
