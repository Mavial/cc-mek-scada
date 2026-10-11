-- Headless CC:Tweaked fixture. Real SCADA graphics, layouts, psil and events run unchanged.
-- No peripheral, network, filesystem write or real reactor APIs are available.
colors = {}
local names = {"white","orange","magenta","lightBlue","yellow","lime","pink","gray","lightGray","cyan","purple","blue","brown","green","red","black"}
for i,n in ipairs(names) do colors[n] = 2^(i-1) end
function colors.toBlit(c)
    if c == 3 then return "0" end -- SCADA's inherit sentinel before resolution
    for i=0,15 do if c == 2^i then return ("0123456789abcdef"):sub(i+1,i+1) end end
    error("invalid color "..tostring(c))
end
function colors.fromBlit(c) return 2^tonumber(c,16) end
keys = {tab=15,enter=28,numPadEnter=156,space=57,backspace=14,delete=211,left=203,right=205,home=199,["end"]=207,up=200,down=208}
os.epoch = function() return 1000000 end
os.sleep = function() end
os.startTimer = function() return 1 end
os.cancelTimer = function() end
os.queueEvent = function() end
package.preload["cc.strings"] = function()
    return {
        ensure_width=function(s,n) s=tostring(s); return s:sub(1,n)..string.rep(" ",math.max(0,n-#s)) end,
        wrap=function(s,n)
            local out = {}
            for line in (s.."\n"):gmatch("(.-)\n") do
                while #line > n do
                    local cut=n
                    local prefix=line:sub(1,n+1)
                    local last=prefix:match(".*() ")
                    if last and last>1 then cut=last-1 end
                    out[#out+1]=line:sub(1,cut)
                    line=line:sub(cut+1):gsub("^ +","")
                end
                out[#out+1]=line
            end
            return out
        end
    }
end
package.preload["scada-common.log"] = function() return setmetatable({}, {__index=function() return function() end end}) end
package.preload["coordinator.coordinator"] = function() return {config={WasteMode=1,FlowDisable=false,TempScale=1,EnergyScale=1},STATE={}} end
package.preload["coordinator.process"] = function() return setmetatable({}, {__index=function(_,k) return function(...) record_call(k,...) end end}) end

calls = {}
function record_call(name, ...) calls[#calls+1]={name=name,args={...}} end
clips = {}
all_windows = {}
window = {}
local function create_window(parent,x,y,w,h,visible)
    local win={_parent=parent,_x=x,_y=y,_w=w,_h=h,_visible=visible~=false,_rows={},_cx=1,_cy=1,_fg=colors.white,_bg=colors.black}
    all_windows[#all_windows+1]=win
    function win.getSize() return win._w,win._h end
    function win.getPosition() return win._x,win._y end
    function win.getCursorPos() return win._cx,win._cy end
    function win.setCursorPos(cx,cy) win._cx,win._cy=cx,cy end
    function win.setCursorBlink() end
    function win.getCursorBlink() return false end
    function win.setTextColor(c) win._fg=c end
    win.setTextColour=win.setTextColor
    function win.setBackgroundColor(c) win._bg=c end
    win.setBackgroundColour=win.setBackgroundColor
    function win.getTextColor() return win._fg end
    win.getTextColour=win.getTextColor
    function win.getBackgroundColor() return win._bg end
    win.getBackgroundColour=win.getBackgroundColor
    function win.isColor() return true end
    win.isColour=win.isColor
    win._palette={}
    function win.setPaletteColor(c,hex,g,b)
        if g then hex=math.floor(hex*255)*65536+math.floor(g*255)*256+math.floor(b*255) end
        win._palette[c]=hex
    end
    win.setPaletteColour=win.setPaletteColor
    function win.getPaletteColor() return 0,0,0 end
    win.getPaletteColour=win.getPaletteColor
    local function paintline(yy)
        if parent and win._visible and yy>=1 and yy<=h then
            local row=win._rows[yy]
            parent.setCursorPos(win._x,win._y+yy-1)
            parent.blit(row[1],row[2],row[3],true)
        end
    end
    function win.blit(s,fg,bg,internal)
        assert(#s==#fg and #s==#bg,"blit length mismatch")
        local xx,yy=win._cx,win._cy
        local right=xx+#s-1
        if not internal and (#s>0) and (yy<1 or yy>h or xx<1 or right>w) then
            local lost=(yy<1 or yy>h) and s or s:sub(1,math.max(0,1-xx))..s:sub(math.max(1,w-xx+2))
            if lost:find("[^ ]") then
                clips[#clips+1]={x=xx,y=yy,w=w,h=h,text=s,lost=lost,trace=debug.traceback("",2)}
            end
        end
        if yy>=1 and yy<=h then
            local row=win._rows[yy]
            local first,last=math.max(1,xx),math.min(w,right)
            if first<=last then
                local a,b=first-xx+1,last-xx+1
                row[1]=row[1]:sub(1,first-1)..s:sub(a,b)..row[1]:sub(last+1)
                row[2]=row[2]:sub(1,first-1)..fg:sub(a,b)..row[2]:sub(last+1)
                row[3]=row[3]:sub(1,first-1)..bg:sub(a,b)..row[3]:sub(last+1)
                paintline(yy)
            end
        end
        win._cx=right+1
    end
    function win.write(s) s=tostring(s);win.blit(s,string.rep(colors.toBlit(win._fg),#s),string.rep(colors.toBlit(win._bg),#s)) end
    function win.clear()
        for yy=1,h do
            win._rows[yy]={string.rep(" ",w),string.rep(colors.toBlit(win._fg),w),string.rep(colors.toBlit(win._bg),w)}
            paintline(yy)
        end
    end
    function win.clearLine()
        local yy=win._cy
        if yy>=1 and yy<=h then win._rows[yy]={string.rep(" ",w),string.rep(colors.toBlit(win._fg),w),string.rep(colors.toBlit(win._bg),w)};paintline(yy) end
    end
    function win.getLine(yy) return table.unpack(win._rows[yy]) end
    function win.redraw() for yy=1,h do paintline(yy) end end
    function win.isVisible() return win._visible end
    function win.setVisible(v) win._visible=v;if v then win.redraw() end end
    function win.reposition(nx,ny,nw,nh) assert(not nw and not nh,"resizing fixture windows is not implemented");win._x,win._y=nx,ny;win.redraw() end
    function win.restoreCursor() end
    function win.scroll() error("scroll not expected in fixed layouts") end
    win.clear()
    return win
end
window.create=create_window
function setup_monitor(w,h) screen=create_window(nil,1,1,w,h,true);term=screen;term.current=function() return screen end;return screen end

local psil=require("scada-common.psil")
local types=require("scada-common.types")
db={
    temp_label="K",energy_label="FE",temp_convert=function(v) return v end,
    energy_convert=function(v) return v end,energy_convert_to_fe=function(v) return v end,energy_convert_from_fe=function(v) return v end,
    config={FlowDisable=false},units={},
    process={fac_ack={},unit_ack={{}},fac_scram=function() record_call("fac_scram") end,fac_ack_alarms=function() record_call("fac_ack_alarms") end,
        process_start=function() record_call("process_start") end,process_stop=function() record_call("process_stop") end}
}
db.facility={num_units=1,ess_type=types.ESS.INDUCTION_MATRIX,combined_waste=false,
    tank_defs={0},tank_conns={1},tank_list={0},tank_fluid_types={types.COOLANT_TYPE.WATER},tank_mode=0,
    ps=psil.create(),induction_ps_tbl={psil.create()},ecore_ps_tbl={psil.create()},sps_ps_tbl={psil.create()},tank_ps_tbl={},
    induction_data_tbl={{build={transfer_cap=10000000}}},auto_active=false,auto_ready=true}
db.units[1]={unit_id=1,num_boilers=1,num_turbines=1,has_tank=false,aux_coolant=false,
    boiler_data_tbl={{}},turbine_data_tbl={{}},boiler_ps_tbl={psil.create()},turbine_ps_tbl={psil.create()},tank_ps_tbl={},
    unit_ps=psil.create(),reactor_data={mek_status={status=false},rps_tripped=false},annunciator={AutoControl=false},a_group=0,
    set_burn=function(v) record_call("set_burn",v) end,start=function() record_call("unit_start") end,
    scram=function() record_call("unit_scram") end,ack_alarms=function() record_call("unit_ack_alarms") end,reset_rps=function() record_call("unit_reset") end,
    set_waste=function(v) record_call("set_waste",v) end,set_group=function(v) record_call("set_group",v) end}
package.preload["coordinator.ioctl"]=function() return {get_db=function() return db end} end
local style=require("coordinator.ui.style")
style.set_themes(1,1,1)
-- CC's patched Lua preserves enough frames for the diagnostic decorator;
-- vanilla Lua 5.2 tail-call elimination can drop those frames. Keep assertions.
require("graphics.element").assert=function(condition,message) assert(condition,message) end

function publish_samples()
    local f=db.facility.ps
    local u=db.units[1].unit_ps
    local function pub(ps,values) for k,v in pairs(values) do ps.publish(k,v) end end
    pub(f,{date_time="12:34:56 - Sunday, October 11 2026",sv_ping=24,burn_sum=5.25,po_rate=0.525,pu_rate=0,po_pl_rate=0,po_am_rate=0,
        spent_waste_rate=0.525,rtu_count=1,all_sys_ok=true,auto_ready=true,auto_active=false,auto_scram=false,
        process_mode=1,process_burn_target=5.25,process_charge_target=1000000000,process_gen_target=2000000,
        process_charge_mode=1,process_charge_start=30,process_charge_stop=90,process_alt_mode=false,
        current_waste_product=2,process_waste_product=2,process_pu_fallback=true,process_sps_low_power=false,
        status_line_1="MANUAL OPERATION",status_line_2="Awaiting automatic start",radiation={radiation=0.000000001,unit="Sv"}})
    pub(u,{computed_status=5,temp=450.25,act_burn_rate=5.25,heating_rate=1050000,fuel_fill=0.8,ccool_fill=0.98,hcool_fill=0.1,waste_fill=0.05,
        ccool_type=types.FLUID.SODIUM,hcool_type=types.FLUID.SUPERHEATED_SODIUM,boiler_boil_sum=105000,turbine_flow_sum=105000,
        sna_count=4,sna_peak_rate=2,sna_max_rate_out=2,sna_max_rate_in=20,sna_in=5.25,po_rate=0.525,pu_rate=0,po_pl_rate=0,po_am_rate=0,ws_rate=0.525,
        U_AutoReady=true,U_AutoDegraded=false,U_AutoWaste=false,U_WasteProduct=2,auto_group_id=0,U_AutoWaste=false})
    pub(db.units[1].boiler_ps_tbl[1],{computed_status=4,temperature=400,water_fill=0.9,steam_fill=0.1,ccool_fill=0.95,hcool_fill=0.1,boil_rate=105000})
    pub(db.units[1].turbine_ps_tbl[1],{computed_status=4,energy_fill=0.25,steam_fill=0.05,steam_input_rate=105000,prod_rate=2000000,SteamDumpOpen=false})
    pub(db.facility.induction_ps_tbl[1],{computed_status=1,max_energy=1000000000,energy=500000000,energy_fill=0.5,last_input=2000000,last_output=1000000,
        avg_charge=500000000,avg_inflow=2000000,avg_outflow=1000000,transfer_cap=10000000,cells=4,providers=2,eta_string="ETA 8m 20s"})
end

function load_layout(name,w,h)
    setup_monitor(w,h)
    local DisplayBox=require("graphics.elements.DisplayBox")
    root=DisplayBox{window=screen,fg_bg=style.root}
    require("coordinator.ui.layout."..name.."_view")(root)
    publish_samples()
    return root
end
