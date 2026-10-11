-- Recovery-capable SCADA fusion monitoring installer. Stop the Coordinator first.
local SOURCES={
["coordinator/fusion.lua"]=([=[!
local model = require("fusion.model")
local config = require("fusion.config")
local psil = require("scada-common.psil")
local view = require("fusion.view")
local log = require("scada-common.log")
local fusion = { ps = psil.create() }
local options, coordinator_config, receiver, backplane
local display, last_error
function fusion.enabled() return options ~= nil end
function fusion.init(bp, cfg)
backplane, coordinator_config = bp, cfg
options = config.load("coordinator")
if not options then return end
local reserved = options.monitor == cfg.MainDisplay or options.monitor == cfg.FlowDisplay
for _, name in ipairs(cfg.UnitDisplays) do reserved = reserved or options.monitor == name end
for _, channel in ipairs({cfg.SVR_Channel,cfg.CRD_Channel,cfg.PKT_Channel}) do
reserved = reserved or options.channel == channel
end
if reserved then
log.error("FUSION: configuration overlaps an existing SCADA display/channel; disabled")
options = nil
return
end
receiver = model.receiver(options.source)
end
function fusion.receive(side, channel, reply, message, distance)
if not options or channel ~= options.channel then return false end
local nic = backplane.nics[side]
if not nic then return true end
local frame = nic.receive(side,channel,reply,message,distance)
if frame and frame.protocol() == model.PROTOCOL and frame.seq_num() > 0 and frame.length() == 1 then
local require_auth = #coordinator_config.AuthKey >= 8 and nic.isWireless()
if not require_auth or frame.is_authenticated() then
local data = frame.data()[1]
if type(data) == "table" and frame.seq_num() == data.seq then
receiver.accept(frame.src_addr(),data,os.epoch("utc"))
end
end
end
return true
end
local function render(db, ui_ready)
local now = os.epoch("utc")
local data,age = receiver.snapshot(now)
local fission = ui_ready and 0 or nil
if ui_ready then
for _, unit in ipairs(db.units) do
for _, ps in ipairs(unit.turbine_ps_tbl) do
local rate,status = ps.get("prod_rate"),ps.get("computed_status")
if not model.finite(rate) or not status or status < 4 then fission=nil break end
fission = fission and fission + rate
end
end
end
local state = model.status(data)
local function power(value) return value and model.format(db.energy_convert(value),db.energy_label.."/t") or "--" end
fusion.ps.publish("status",state)
fusion.ps.publish("fusion",power(data and data.production))
fusion.ps.publish("fission",power(fission))
fusion.ps.publish("total",power(data and data.production and fission and (data.production+fission)))
fusion.ps.publish("age",data and string.format("%.1fs",age/1000) or "OFFLINE")
display = peripheral.wrap(options.monitor)
if display and peripheral.hasType(options.monitor,"monitor") then
view.draw(display,data,{age=age,fission=fission,energy_convert=db.energy_convert,
energy_label=db.energy_label,temp_convert=db.temp_convert,temp_label=db.temp_label,
name=options.monitor,source=options.source,color_mode=coordinator_config.ColorMode})
else
view.reset()
end
end
function fusion.tick(db, ui_ready)
if not options then return end
for _, nic in pairs(backplane.nics) do nic.open(options.channel) end
if not db or not db.units or not db.energy_convert then return end
local ok,err = pcall(render,db,ui_ready)
if not ok and tostring(err) ~= last_error then
view.reset()
last_error = tostring(err)
log.warning("FUSION: optional display unavailable: " .. last_error)
elseif ok then last_error=nil end
end
return fusion
]=]):sub(2),
["fusion/view.lua"]=([=[!
local model = require("fusion.model")
local util = require("scada-common.util")
local style = require("coordinator.ui.style")
local core = require("graphics.core")
local DisplayBox = require("graphics.elements.DisplayBox")
local Rectangle = require("graphics.elements.Rectangle")
local TextBox = require("graphics.elements.TextBox")
local DataIndicator = require("graphics.elements.indicators.DataIndicator")
local PowerIndicator = require("graphics.elements.indicators.PowerIndicator")
local IndicatorLight = require("graphics.elements.indicators.IndicatorLight")
local StateIndicator = require("graphics.elements.indicators.StateIndicator")
local HorizontalBar = require("graphics.elements.indicators.HorizontalBar")
local view, cached = {}, nil
local cpair, ALIGN = core.cpair, core.ALIGN
local function numeric(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function bounded(text, width)
text = tostring(text)
return #text <= width and text or text:sub(1, width - 3) .. "..."
end
function view.reset()
if cached then cached.root.hide() end
cached = nil
end
local function create(monitor, context, width, height)
for _, entry in ipairs(style.theme.colors) do monitor.setPaletteColor(entry.c, entry.hex) end
for _, entry in ipairs(style.theme.color_modes[context.color_mode or 1] or {}) do
monitor.setPaletteColor(entry.c, entry.hex)
end
local ui = {key=context.name or monitor,width=width,height=height,theme=style.theme,
color_mode=context.color_mode,energy_label=context.energy_label,temp_label=context.temp_label}
ui.root = DisplayBox{window=monitor,fg_bg=style.root}
local root = ui.root
local panel_width = math.floor((width - 5) / 2)
local right = panel_width + 4
local field = style.theme.field_box
local function text(parent, x, y, w, value, colors_pair, alignment)
return TextBox{parent=parent,x=x,y=y,width=w,height=1,text=bounded(value,w),
fg_bg=colors_pair or style.label,alignment=alignment or ALIGN.LEFT}
end
local function panel(x, y, h, title, accent)
local header = accent and cpair(colors.black,accent) or style.theme.header
text(root,x,y,panel_width,title,header,ALIGN.CENTER)
return Rectangle{parent=root,x=x,y=y+1,width=panel_width,height=h-1,
border=core.border(1,accent or colors.gray,true),thin=true}
end
local function value(parent, x, y, w, indicator, format, unit)
local unknown = text(parent,x,y,w,"--",field,ALIGN.RIGHT)
indicator.hide()
return function(v)
local rendered = numeric(v) and format(v) or nil
if rendered and #rendered <= w then
unknown.hide()
indicator.update(v)
indicator.show(false)
else
indicator.hide()
unknown.set_value(rendered and bounded(string.format("%.3e %s",v,unit),w) or "--")
unknown.show(false)
end
end
end
local function power(parent, y, label, rate)
text(parent,2,y,11,label)
local w = panel_width - 17
local indicator = PowerIndicator{parent=parent,x=13,y=y,width=w,label="",value=0,
format="%10.2f",unit=context.energy_label,rate=rate,lu_colors=style.lu_colors,fg_bg=field}
local update = value(parent,13,y,w,indicator,function(v)
local number, unit = util.power_format(v,context.energy_label,false,"%10.2f")
unit = util.strminw(unit .. (rate and "/t" or ""),5)
return util.comma_format(number) .. " " .. unit
end,context.energy_label .. (rate and "/t" or ""))
return function(v) update(v ~= nil and context.energy_convert(v) or nil) end
end
local function bar(parent, y, color)
local w = panel_width - 6
local gauge = HorizontalBar{parent=parent,x=2,y=y,width=w,height=1,show_percent=true,
fg_bg=style.text_colors,bar_fg_bg=cpair(color,style.ind_bkg)}
local unknown = text(parent,2,y,w,"--",style.theme.highlight_box,ALIGN.CENTER)
gauge.hide()
return function(amount, capacity)
if numeric(amount) and numeric(capacity) and capacity > 0 then
unknown.hide()
gauge.update(amount/capacity)
gauge.show(false)
else
gauge.hide()
unknown.show(false)
end
end
end
text(root,1,1,width,"Fusion Reactor",style.theme.header,ALIGN.CENTER)
local status_box = Rectangle{parent=root,x=2,y=3,width=panel_width,height=4,
border=core.border(1,colors.gray,true),thin=true}
local states = {}
for _, def in ipairs({{"NO LIVE DATA",colors.red},{"READ ERROR",colors.orange},
{"UNFORMED",colors.orange},{"IDLE",colors.gray},{"RUNNING",style.ind_grn.fgd},
{"IDLE / PARTIAL DATA",colors.orange},{"RUNNING / PARTIAL DATA",colors.orange}}) do
states[#states+1] = {text=def[1],color=cpair(def[2] == colors.gray and colors.white or colors.black,def[2])}
end
ui.state = StateIndicator{parent=status_box,x=1,y=1,min_width=panel_width-2,states=states,value=1}
text(status_box,1,2,panel_width-2,"Read-only reactor telemetry",style.label,ALIGN.CENTER)
local link_box = Rectangle{parent=root,x=right,y=3,width=panel_width,height=4,
border=core.border(1,colors.gray,true),thin=true}
ui.live = IndicatorLight{parent=link_box,x=2,y=1,label="Link Online",colors=style.ind_grn}
ui.formed = IndicatorLight{parent=link_box,x=20,y=1,label="Formed",colors=style.ind_grn}
ui.link = text(link_box,2,2,17,"Source -- / --",style.label)
ui.fault = IndicatorLight{parent=link_box,x=20,y=2,label="Read Fault",colors=style.ind_yel}
local reactor = panel(2,8,10,"FUSION CORE",colors.cyan)
local function temperature(y,label)
text(reactor,2,y,panel_width-6,label)
local w = panel_width-6
local indicator = DataIndicator{parent=reactor,x=2,y=y+1,width=w,label="",value=0,
format="%26.2f",unit=context.temp_label,commas=true,lu_colors=style.lu_colors,fg_bg=field}
local update = value(reactor,2,y+1,w,indicator,function(v)
return util.comma_format(string.format("%26.2f",v)) .. " " .. context.temp_label
end,context.temp_label)
return function(v) update(v ~= nil and context.temp_convert(v) or nil) end
end
ui.plasma = temperature(1,"Plasma Temperature")
ui.casing = temperature(4,"Casing Temperature")
text(reactor,2,7,panel_width-6,"Measured reactor temperatures",style.label,ALIGN.CENTER)
local generation = panel(right,8,10,"POWER GENERATION")
ui.fusion = power(generation,1,"Fusion",true)
ui.fission = power(generation,3,"Fission",true)
ui.total = power(generation,5,"Total",true)
text(generation,2,7,panel_width-6,"Total generator output",style.label,ALIGN.CENTER)
local fuel = panel(2,19,17,"FUEL TANKS",colors.brown)
ui.tanks = {}
for i, def in ipairs({{"Premixed D-T","dt",colors.purple},{"Deuterium","deuterium",colors.lightBlue},
{"Tritium","tritium",colors.cyan}}) do
local y = 1+(i-1)*4
text(fuel,2,y,14,def[1])
local amount = text(fuel,17,y,panel_width-21,"--",field,ALIGN.RIGHT)
local gauge = bar(fuel,y+1,def[3])
ui.tanks[i] = function(data)
local current,capacity = data[def[2]],data[def[2].."_capacity"]
amount.set_value(current ~= nil and capacity ~= nil and
bounded(string.format("%.0f / %.0f mB",current,capacity),panel_width-21) or "--")
gauge(current,capacity)
end
end
text(fuel,2,13,17,"Injection setting")
ui.injection = text(fuel,20,13,panel_width-24,"--",field,ALIGN.RIGHT)
text(fuel,2,14,panel_width-6,"Injection applies to D/T feeds",style.label,ALIGN.CENTER)
local buffer = panel(2,37,12,"REACTOR ENERGY BUFFER",colors.blue)
ui.buffer = power(buffer,1,"Stored",false)
ui.buffer_cap = power(buffer,3,"Capacity",false)
text(buffer,2,5,panel_width-6,"Buffer Fill")
ui.buffer_fill = bar(buffer,6,colors.blue)
text(buffer,2,8,panel_width-6,"Direct electrical generation",style.label,ALIGN.CENTER)
local laser = panel(right,19,30,"LASER AND IGNITION",colors.purple)
ui.laser = power(laser,1,"Stored",false)
ui.laser_cap = power(laser,3,"Capacity",false)
ui.laser_min = power(laser,5,"Minimum",false)
ui.laser_max = power(laser,7,"Maximum",false)
text(laser,2,9,panel_width-6,"Charge to Minimum Threshold")
ui.charge = bar(laser,10,colors.purple)
ui.threshold = StateIndicator{parent=laser,x=2,y=13,min_width=panel_width-6,value=1,states={
{text="UNKNOWN",color=cpair(style.theme.text,style.ind_bkg)},
{text="BELOW THRESHOLD",color=cpair(colors.black,colors.yellow)},
{text="THRESHOLD REACHED",color=cpair(colors.black,style.ind_grn.fgd)}}}
text(laser,2,16,14,"Redstone Mode")
ui.laser_mode = text(laser,17,16,panel_width-21,"--",field,ALIGN.RIGHT)
ui.hohlraum = IndicatorLight{parent=laser,x=2,y=19,label="Hohlraum Loaded",colors=style.ind_grn}
text(laser,2,21,11,"Fuel Charge")
ui.charge_text = text(laser,13,21,panel_width-17,"--",field,ALIGN.RIGHT)
text(laser,2,24,panel_width-6,"Laser threshold is an energy",style.label,ALIGN.CENTER)
text(laser,2,25,panel_width-6,"reading; ignition is separate.",style.label,ALIGN.CENTER)
ui.notice = text(root,2,50,width-3,"Waiting for telemetry",style.label)
text(root,1,52,width,"READ-ONLY MONITORING",style.theme.header,ALIGN.CENTER)
return ui
end
function view.draw(monitor, data, context)
monitor.setTextScale(0.5)
local width,height = monitor.getSize()
if width < 79 or height < 52 then
view.reset()
monitor.setBackgroundColor(colors.black)
monitor.setTextColor(colors.red)
monitor.clear()
monitor.setCursorPos(1,1)
monitor.write("Fusion display needs a 4x4 Advanced Monitor.")
return
end
if not cached or cached.key ~= (context.name or monitor) or cached.width ~= width or cached.height ~= height
or cached.theme ~= style.theme or cached.color_mode ~= context.color_mode
or cached.energy_label ~= context.energy_label or cached.temp_label ~= context.temp_label then
view.reset()
cached = create(monitor,context,width,height)
end
local ui = cached
local status = model.status(data)
local state = { ["NO LIVE DATA"]=1,["READ ERROR"]=2,["UNFORMED"]=3,["IDLE"]=4,
["RUNNING"]=5,["IDLE / PARTIAL DATA"]=6,["RUNNING / PARTIAL DATA"]=7 }
ui.state.update(state[status])
ui.live.update(data ~= nil)
ui.link.set_value(bounded("#"..tostring(context.source or "--").." / "..
(data and string.format("%.1fs",(context.age or 0)/1000) or "OFFLINE"),17))
local current = data or {}
ui.formed.update(current.formed == true)
ui.fault.update(current.errors ~= nil and #current.errors > 0)
ui.plasma(current.plasma)
ui.casing(current.casing)
ui.fusion(current.production)
ui.fission(context.fission)
ui.total(current.production ~= nil and context.fission ~= nil and (current.production+context.fission) or nil)
for _, update in ipairs(ui.tanks) do update(current) end
ui.injection.set_value(current.injection ~= nil and bounded(tostring(current.injection).." mB/t",ui.injection.get_width()) or "--")
ui.buffer(current.port_energy)
ui.buffer_cap(current.port_capacity)
ui.buffer_fill(current.port_energy,current.port_capacity)
ui.laser(current.laser_energy)
ui.laser_cap(current.laser_capacity)
ui.laser_min(current.laser_min)
ui.laser_max(current.laser_max)
ui.charge(current.laser_energy,current.laser_min)
local threshold = 1
if current.laser_energy ~= nil and current.laser_min ~= nil then
threshold = current.laser_energy >= current.laser_min and 3 or 2
end
ui.threshold.update(threshold)
ui.laser_mode.set_value(current.laser_mode or "--")
ui.hohlraum.update(current.hohlraum_present == true)
local charge = "--"
if current.hohlraum_present == false then charge="EMPTY"
elseif current.hohlraum_present then charge=current.hohlraum_fuel and (current.hohlraum_fuel.." mB D-T") or "UNKNOWN" end
ui.charge_text.set_value(bounded(charge,ui.charge_text.get_width()))
local notice = "Generator totals exclude Matrix input/output."
if not data then notice="NO LIVE DATA - check the fusion computer and modem link."
elseif current.errors and #current.errors > 0 then notice=current.errors[1]
elseif context.fission == nil then notice="Fission total unavailable until SCADA turbine data is live." end
ui.notice.set_value(bounded(notice,ui.notice.get_width()))
ui.notice.recolor(not data and colors.red or (#(current.errors or {}) > 0 and colors.orange or style.theme.label))
end
return view
]=]):sub(2),
["lockbox/digest/sha2_256.lua"]=([=[!local Bit = require("lockbox.util.bit");
local String = require("string");
local Math = require("math");
local Queue = require("lockbox.util.queue");
local CONSTANTS = {
0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2  };
local fmt = "%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x" ..
"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x"
local AND = Bit.band;
local OR  = Bit.bor;
local NOT = Bit.bnot;
local XOR = Bit.bxor;
local RROT = Bit.rrotate;
local LSHIFT = Bit.lshift;
local RSHIFT = Bit.rshift;
local bytes2word = function(b0, b1, b2, b3)
local i = b0; i = LSHIFT(i, 8);
i = OR(i, b1); i = LSHIFT(i, 8);
i = OR(i, b2); i = LSHIFT(i, 8);
i = OR(i, b3);
return i;
end
local word2bytes = function(word)
local b0, b1, b2, b3;
b3 = AND(word, 0xFF); word = RSHIFT(word, 8);
b2 = AND(word, 0xFF); word = RSHIFT(word, 8);
b1 = AND(word, 0xFF); word = RSHIFT(word, 8);
b0 = AND(word, 0xFF);
return b0, b1, b2, b3;
end
local dword2bytes = function(i)
local b4, b5, b6, b7 = word2bytes(i);
local b0, b1, b2, b3 = word2bytes(Math.floor(i / 0x100000000));
return b0, b1, b2, b3, b4, b5, b6, b7;
end
local SHA2_256 = function()
local queue = Queue();
local h0 = 0x6a09e667;
local h1 = 0xbb67ae85;
local h2 = 0x3c6ef372;
local h3 = 0xa54ff53a;
local h4 = 0x510e527f;
local h5 = 0x9b05688c;
local h6 = 0x1f83d9ab;
local h7 = 0x5be0cd19;
local public = {};
local processBlock = function()
local a = h0;
local b = h1;
local c = h2;
local d = h3;
local e = h4;
local f = h5;
local g = h6;
local h = h7;
local w = {};
for i = 0, 15 do
w[i] = bytes2word(queue.pop(), queue.pop(), queue.pop(), queue.pop());
end
for i = 16, 63 do
local s0 = XOR(RROT(w[i - 15], 7), XOR(RROT(w[i - 15], 18), RSHIFT(w[i - 15], 3)));
local s1 = XOR(RROT(w[i - 2], 17), XOR(RROT(w[i -  2], 19), RSHIFT(w[i - 2], 10)));
w[i] = AND(w[i - 16] + s0 + w[i - 7] + s1, 0xFFFFFFFF);
end
for i = 0, 63 do
local s1 = XOR(RROT(e, 6), XOR(RROT(e, 11), RROT(e, 25)));
local ch = XOR(AND(e, f), AND(NOT(e), g));
local temp1 = h + s1 + ch + CONSTANTS[i + 1] + w[i];
local s0 = XOR(RROT(a, 2), XOR(RROT(a, 13), RROT(a, 22)));
local maj = XOR(AND(a, b), XOR(AND(a, c), AND(b, c)));
local temp2 = s0 + maj;
h = g;
g = f;
f = e;
e = d + temp1;
d = c;
c = b;
b = a;
a = temp1 + temp2;
end
h0 = AND(h0 + a, 0xFFFFFFFF);
h1 = AND(h1 + b, 0xFFFFFFFF);
h2 = AND(h2 + c, 0xFFFFFFFF);
h3 = AND(h3 + d, 0xFFFFFFFF);
h4 = AND(h4 + e, 0xFFFFFFFF);
h5 = AND(h5 + f, 0xFFFFFFFF);
h6 = AND(h6 + g, 0xFFFFFFFF);
h7 = AND(h7 + h, 0xFFFFFFFF);
end
public.init = function()
queue.reset();
h0 = 0x6a09e667;
h1 = 0xbb67ae85;
h2 = 0x3c6ef372;
h3 = 0xa54ff53a;
h4 = 0x510e527f;
h5 = 0x9b05688c;
h6 = 0x1f83d9ab;
h7 = 0x5be0cd19;
return public;
end
public.update = function(bytes)
for b in bytes do
queue.push(b);
if queue.size() >= 64 then processBlock(); end
end
return public;
end
public.finish = function()
local bits = queue.getHead() * 8;
queue.push(0x80);
while ((queue.size() + 7) % 64) < 63 do
queue.push(0x00);
end
local b0, b1, b2, b3, b4, b5, b6, b7 = dword2bytes(bits);
queue.push(b0);
queue.push(b1);
queue.push(b2);
queue.push(b3);
queue.push(b4);
queue.push(b5);
queue.push(b6);
queue.push(b7);
while queue.size() > 0 do
processBlock();
end
return public;
end
public.asBytes = function()
local  b0, b1, b2, b3 = word2bytes(h0);
local  b4, b5, b6, b7 = word2bytes(h1);
local  b8, b9, b10, b11 = word2bytes(h2);
local b12, b13, b14, b15 = word2bytes(h3);
local b16, b17, b18, b19 = word2bytes(h4);
local b20, b21, b22, b23 = word2bytes(h5);
local b24, b25, b26, b27 = word2bytes(h6);
local b28, b29, b30, b31 = word2bytes(h7);
return {  b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15
, b16, b17, b18, b19, b20, b21, b22, b23, b24, b25, b26, b27, b28, b29, b30, b31};
end
public.asHex = function()
local  b0, b1, b2, b3 = word2bytes(h0);
local  b4, b5, b6, b7 = word2bytes(h1);
local  b8, b9, b10, b11 = word2bytes(h2);
local b12, b13, b14, b15 = word2bytes(h3);
local b16, b17, b18, b19 = word2bytes(h4);
local b20, b21, b22, b23 = word2bytes(h5);
local b24, b25, b26, b27 = word2bytes(h6);
local b28, b29, b30, b31 = word2bytes(h7);
return String.format(fmt, b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15
, b16, b17, b18, b19, b20, b21, b22, b23, b24, b25, b26, b27, b28, b29, b30, b31);
end
return public;
end
return SHA2_256;
]=]):sub(2),
["lockbox/util/bit.lua"]=([=[!
local ok, e = nil, nil
if not ok then
ok, e = pcall(require, "bit32")
end
if not ok then
ok, e = pcall(require, "bit")
end
if not ok then
error("no bitwise support found", 2)
end
assert(type(e) == "table", "invalid bit module")
return e
]=]):sub(2),
["lockbox/util/queue.lua"]=([=[!local Queue = function()
local queue = {};
local tail = 0;
local head = 0;
local public = {};
public.push = function(obj)
queue[head] = obj;
head = head + 1;
return;
end
public.pop = function()
if tail < head
then
local obj = queue[tail];
queue[tail] = nil;
tail = tail + 1;
return obj;
else
return nil;
end
end
public.size = function()
return head - tail;
end
public.getHead = function()
return head;
end
public.getTail = function()
return tail;
end
public.reset = function()
queue = {};
head = 0;
tail = 0;
end
return public;
end
return Queue;
]=]):sub(2),
["lockbox/util/stream.lua"]=([=[!local Queue = require("lockbox.util.queue");
local String = require("string");
local Stream = {};
Stream.fromString = function(string)
local i = 0;
return function()
i = i + 1;
return String.byte(string, i);
end
end
Stream.toString = function(stream)
local array = {};
local i = 1;
local byte = stream();
while byte ~= nil do
array[i] = String.char(byte);
i = i + 1;
byte = stream();
end
return table.concat(array);
end
Stream.fromArray = function(array)
local queue = Queue();
local i = 1;
local byte = array[i];
while byte ~= nil do
queue.push(byte);
i = i + 1;
byte = array[i];
end
return queue.pop;
end
Stream.toArray = function(stream)
local array = {};
local i = 1;
local byte = stream();
while byte ~= nil do
array[i] = byte;
i = i + 1;
byte = stream();
end
return array;
end
local fromHexTable = {};
for i = 0, 255 do
fromHexTable[String.format("%02X", i)] = i;
fromHexTable[String.format("%02x", i)] = i;
end
Stream.fromHex = function(hex)
local queue = Queue();
for i = 1, String.len(hex) / 2 do
local h = String.sub(hex, i * 2 - 1, i * 2);
queue.push(fromHexTable[h]);
end
return queue.pop;
end
local toHexTable = {};
for i = 0, 255 do
toHexTable[i] = String.format("%02X", i);
end
Stream.toHex = function(stream)
local hex = {};
local i = 1;
local byte = stream();
while byte ~= nil do
hex[i] = toHexTable[byte];
i = i + 1;
byte = stream();
end
return table.concat(hex);
end
return Stream;
]=]):sub(2),
}
local BUNDLE={coordinator={
{path="fusion/view.lua",hash="3edbde1680af1159ed97a0fa091379245c63397c9c4b9f1ec4f845fc7618fa45",allowed={"eab1bc742027b9726a5e5d1644878a3bc0bd3868e52417597e793dfdab9fb880","5e231f41053dd43882fc9f3dae43c099cf11e54b2c7b6bbd9a218beb74253739"}},
{path="coordinator/fusion.lua",hash="76aa68e4048aa6ccc3b91d54e3dfc2aa90a3688734232c51495ed05d4b73b406",allowed={"7d710f9ab1b48aa82ec5a31c585643b2182b00fa8c8b250cb415725f506cf20f","080344cddbff571e3c52aed1566a5630de9baf9c6d39dc0019014978ac11369d"}}
}}

local args = {...}
local command,role = args[1] or "check",args[2]
if command == "agent" or command == "coordinator" then role,command=command,"install" end
role = role or (fs.exists("/coordinator/startup.lua") and "coordinator" or "agent")
assert(role == "agent" or role == "coordinator", "Specify agent or coordinator")
assert(role == "coordinator", "Run this visual update on the Coordinator.")
local rows = BUNDLE[role]
local root = "/.scada-fusion-style-1/" .. role
local journal_path = root .. "/journal.json"
local function fail(value) error(value,0) end
local function read_file(path)
    local f,err=fs.open(path,"rb")
    if not f then fail("Cannot read " .. path .. ": " .. tostring(err)) end
    local body=f.readAll() f.close()
    return (body:gsub("\r\n","\n"))
end
local function write_file(path,body)
    fs.makeDir(fs.getDir(path))
    local f,err=fs.open(path,"wb")
    if not f then fail("Cannot write " .. path .. ": " .. tostring(err)) end
    local ok,detail=pcall(f.write,body)
    f.close()
    if not ok then fail(detail) end
end
-- Bundled upstream hash modules also work on a new, empty fusion computer.
local modules = {}
local function library(name)
    if name == "bit32" then return bit32 end
    if name == "string" then return string end
    if name == "math" then return math end
    if modules[name] then return modules[name] end
    local path = name:gsub("%.","/") .. ".lua"
    assert(SOURCES[path],"Missing hash library: " .. path)
    local env=setmetatable({require=library},{__index=_G})
    local chunk=assert(load(SOURCES[path],"@"..path,"t",env))
    modules[name]=chunk()
    return modules[name]
end
local Sha,Stream=library("lockbox.digest.sha2_256"),library("lockbox.util.stream")
local function digest(body)
    local h=Sha() h.init()
    for i=1,#body,2048 do
        h.update(Stream.fromString(body:sub(i,i+2047)))
        if sleep then sleep(0) end
    end
    return h.finish().asHex():lower()
end
local function file_hash(path) return digest(read_file(path)) end
local function allowed(row,hash)
    if hash == row.hash then return true end
    for _,old in ipairs(row.allowed) do if hash == old then return true end end
    return false
end
local function load_journal()
    if not fs.exists(journal_path) then return nil end
    local j=textutils.unserializeJSON(read_file(journal_path))
    if type(j) ~= "table" or j.schema ~= 1 or j.role ~= role or type(j.rows) ~= "table" or #j.rows ~= #rows then
        fail("Invalid recovery journal. Keep " .. root .. " intact.")
    end
    for i,row in ipairs(rows) do
        if type(j.rows[i]) ~= "table" or j.rows[i].path ~= row.path or
            (j.rows[i].before ~= nil and not allowed(row,j.rows[i].before)) then fail("Invalid journal entry.") end
    end
    return j
end
local function rollback()
    local j=load_journal()
    if not j then
        -- A power cut before the atomic journal rename cannot have changed live files.
        if fs.exists(root) then
            if fs.exists(root.."/original") or fs.exists(root.."/stage") or fs.exists(root.."/complete") then
                fail("Recovery journal missing. Keep "..root.." intact.")
            end
            fs.delete(root)
        end
        print("No fusion installation to restore.")
        return
    end
    -- Check every path before restoring or removing any live file.
    for i,row in ipairs(rows) do
        local live,backup="/"..row.path,root.."/original/"..row.path
        local before=j.rows[i].before
        local hash
        if fs.exists(live) then
            hash=file_hash(live)
            if hash ~= row.hash and hash ~= before then fail("Edited file: " .. live .. ". Nothing restored.") end
        end
        if before and hash ~= before then
            if fs.exists(backup) then
                if file_hash(backup) ~= before then fail("Damaged backup: "..row.path) end
            elseif not fs.exists(live) or file_hash(live) ~= before then
                fail("Missing backup: "..row.path)
            end
        end
    end
    for i,row in ipairs(rows) do
        local live,backup="/"..row.path,root.."/original/"..row.path
        local before=j.rows[i].before
        if before then
            if not fs.exists(live) or file_hash(live) ~= before then
                local temp=root.."/restore/"..row.path
                if fs.exists(temp) then fs.delete(temp) end
                fs.makeDir(fs.getDir(temp)) fs.copy(backup,temp)
                if file_hash(temp) ~= before then fail("Restore checksum failed: "..row.path) end
                if fs.exists(live) then fs.delete(live) end
                fs.makeDir(fs.getDir(live)) fs.move(temp,live)
            end
        elseif fs.exists(live) then fs.delete(live) end
    end
    fs.delete(root)
    print("Fusion display styling restored to its pre-install state. Settings preserved.")
end
if command == "undo" or command == "recover" then rollback() return end
assert(command == "check" or command == "install", "Use check, install, undo or recover, followed by the role")
if role == "agent" then
    for _,app in ipairs({"reactor-plc","rtu","supervisor","coordinator"}) do
        if fs.exists("/"..app.."/startup.lua") then fail("Use a separate fusion computer; "..app.." is installed here.") end
    end
else
    if not fs.exists("/coordinator/startup.lua") then fail("Run this on the Coordinator.") end
    local version=read_file("/coordinator/startup.lua"):match('COORDINATOR_VERSION%s*=%s*"([^"]+)"')
    if version ~= "1.10.1" then fail("Unsupported Coordinator version: "..tostring(version)) end
end
local j=load_journal()
if j then
    if not fs.exists(root.."/complete") then fail("Interrupted installation. Run install-fusion-style recover "..role.." first.") end
    for _,row in ipairs(rows) do
        if not fs.exists("/"..row.path) or file_hash("/"..row.path) ~= row.hash then
            fail("Installed fusion file changed: "..row.path..". Keep the backup for undo.")
        end
    end
    print("Fusion display styling is already installed.")
    return
end
j={schema=1,role=role,rows={}}
local space=16384
for _,row in ipairs(rows) do
    local body=SOURCES[row.path]
    if digest(body) ~= row.hash then fail("Bundle checksum failed: "..row.path) end
    local chunk,err=load(body,"@"..row.path,"t",{})
    if not chunk then fail("Bundle syntax error: "..tostring(err)) end
    local live="/"..row.path
    local before
    if fs.exists(live) then
        if fs.isDir(live) then fail("File path is a directory: "..live) end
        before=file_hash(live)
        if not allowed(row,before) then fail("Unsupported or edited file: "..live..". Nothing installed.") end
        space=space+fs.getSize(live)
    elseif #row.allowed > 0 then fail("Required SCADA file missing: "..live) end
    j.rows[#j.rows+1]={path=row.path,before=before}
    space=space+#body
end
if fs.getFreeSpace("/") < space then fail("Not enough free space for installation and backups.") end
print("Validated "..#rows.." files for "..role..".")
if command == "check" then print("Check passed; nothing installed.") return end
write_file(root.."/journal.new",textutils.serializeJSON(j))
fs.move(root.."/journal.new",journal_path)
-- Finish all backups and staged files before replacing the first live file.
for i,row in ipairs(rows) do
    if j.rows[i].before then
        local backup=root.."/original/"..row.path
        fs.makeDir(fs.getDir(backup)) fs.copy("/"..row.path,backup)
        if file_hash(backup) ~= j.rows[i].before then fail("Backup checksum failed.") end
    end
    write_file(root.."/stage/"..row.path,SOURCES[row.path])
    if file_hash(root.."/stage/"..row.path) ~= row.hash then fail("Staging checksum failed.") end
end
for _,row in ipairs(rows) do
    local live="/"..row.path
    fs.makeDir(fs.getDir(live))
    if fs.exists(live) then fs.delete(live) end
    fs.move(root.."/stage/"..row.path,live)
end
write_file(root.."/complete","fusion-style-1\n")
print("Installed fusion monitoring. Backup: "..root)
print("Settings preserved. Next: startup")
