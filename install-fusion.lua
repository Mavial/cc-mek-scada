-- Recovery-capable SCADA fusion monitoring installer. Stop the Coordinator first.
local SOURCES = {
["coordinator/fusion.lua"]=(([=[!
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
energy_label=db.energy_label,temp_convert=db.temp_convert,temp_label=db.temp_label})
end
end
function fusion.tick(db, ui_ready)
if not options then return end
for _, nic in pairs(backplane.nics) do nic.open(options.channel) end
if not db or not db.units or not db.energy_convert then return end
local ok,err = pcall(render,db,ui_ready)
if not ok and tostring(err) ~= last_error then
last_error = tostring(err)
log.warning("FUSION: optional display unavailable: " .. last_error)
elseif ok then last_error=nil end
end
return fusion
]=]):sub(2)),
["coordinator/threads.lua"]=(([=[!local log         = require("scada-common.log")
local mqueue      = require("scada-common.mqueue")
local ppm         = require("scada-common.ppm")
local tcd         = require("scada-common.tcd")
local util        = require("scada-common.util")
local backplane   = require("coordinator.backplane")
local coordinator = require("coordinator.coordinator")
local ioctl       = require("coordinator.ioctl")
local process     = require("coordinator.process")
local renderer    = require("coordinator.renderer")
local fusion      = require("coordinator.fusion")
local sounder     = require("coordinator.sounder")
local apisessions = require("coordinator.session.apisessions")
local core        = require("graphics.core")
local log_render = coordinator.log_render
local log_sys    = coordinator.log_sys
local log_comms  = coordinator.log_comms
local threads = {}
local MAIN_CLOCK   = 0.5
local RENDER_SLEEP = 100
function threads.thread__main(smem)
local public = {}
function public.exec()
ioctl.fp_rt_status("main", true)
log.debug("OS: main thread start")
local loop_clock = util.new_clock(MAIN_CLOCK)
loop_clock.start()
log_sys("system started successfully")
local crd_state       = smem.crd_state
local coord_comms     = smem.crd_sys.coord_comms
local conn_watchdog   = smem.crd_sys.conn_watchdog
fusion.init(backplane, coordinator.config)
local MQ__RENDER_CMD  = smem.q_types.MQ__RENDER_CMD
local MQ__RENDER_DATA = smem.q_types.MQ__RENDER_DATA
local function loop_tick()
ioctl.heartbeat()
backplane.periodic()
fusion.tick(ioctl.get_db(), renderer.ui_ready())
local ok, start_ui = coord_comms.manage_link()
if not ok then
crd_state.link_fail = true
crd_state.shutdown = true
log_sys("supervisor connection failed, shutting down...")
log.fatal("failed to connect to supervisor")
return true
elseif start_ui then
log_sys("supervisor connected, dispatching main UI start")
smem.q.mq_render.push_command(MQ__RENDER_CMD.START_MAIN_UI)
end
apisessions.iterate_all()
apisessions.free_all_closed()
process.clear_timed_out()
if renderer.ui_ready() then
ioctl.get_db().facility.ps.publish("date_time", os.date(smem.date_format))
end
loop_clock.start()
return false
end
while true do
local event, param1, param2, param3, param4, param5 = util.pull_event()
if event == "modem_message" then
if fusion.receive(param1, param2, param3, param4, param5) then
else
local packet = coord_comms.parse_packet(param1, param2, param3, param4, param5)
if coord_comms.handle_packet(packet) then
log_comms("supervisor closed connection")
smem.q.mq_render.push_command(MQ__RENDER_CMD.CLOSE_MAIN_UI)
coord_comms.close()
sounder.stop()
end
end
elseif event == "timer" then
if loop_clock.is_clock(param1) then
if loop_tick() then break end
elseif conn_watchdog.is_timer(param1) then
log_comms("supervisor server timeout")
smem.q.mq_render.push_command(MQ__RENDER_CMD.CLOSE_MAIN_UI)
coord_comms.close()
sounder.stop()
elseif not apisessions.check_all_watchdogs(param1) then
tcd.handle(param1)
end
elseif event == "speaker_audio_empty" then
sounder.continue()
elseif event == "monitor_touch" or event == "mouse_click" or event == "mouse_up" or
event == "mouse_drag" or event == "mouse_scroll" or event == "double_click" then
renderer.handle_mouse(core.events.new_mouse_event(event, param1, param2, param3))
elseif event == "monitor_resize" then
smem.q.mq_render.push_data(MQ__RENDER_DATA.MON_RESIZE, param1)
elseif event == "peripheral" then
local type, device = ppm.mount(param1)
if type ~= nil and device ~= nil then
backplane.attach(type, device, param1)
end
elseif event == "peripheral_detach" then
local type, device = ppm.handle_unmount(param1)
if type ~= nil and device ~= nil then
backplane.detach(type, device, param1)
end
end
if event == "terminate" or ppm.should_terminate() then
crd_state.shutdown = true
log.info("OS: terminate requested, main thread exiting")
elseif not crd_state.ui_ok then
crd_state.shutdown = true
log.info("OS: terminating due to fatal UI error")
end
if crd_state.shutdown then
coord_comms.manage_link(true)
if coord_comms.is_linked() then
log_comms("closing supervisor connection...")
else crd_state.link_fail = true end
coord_comms.close()
log_comms("supervisor connection closed")
log_comms("closing api sessions...")
apisessions.close_all()
log_comms("api sessions closed")
break
end
end
end
function public.p_exec()
local crd_state = smem.crd_state
while not crd_state.shutdown do
local status, result = pcall(public.exec)
if status == false then
log.fatal(util.strval(result))
end
ioctl.fp_rt_status("main", false)
if not crd_state.shutdown then
log.info("OS: main thread restarting now...")
end
end
end
return public
end
function threads.thread__render(smem)
local public = {}
function public.exec()
ioctl.fp_rt_status("render", true)
log.debug("OS: render thread start")
local crd_state       = smem.crd_state
local render_queue    = smem.q.mq_render
local MQ__RENDER_CMD  = smem.q_types.MQ__RENDER_CMD
local MQ__RENDER_DATA = smem.q_types.MQ__RENDER_DATA
local last_update = util.time()
while true do
while render_queue.ready() and not crd_state.shutdown do
local msg = render_queue.pop()
if msg ~= nil then
if msg.qtype == mqueue.TYPE.COMMAND then
if msg.message == MQ__RENDER_CMD.START_MAIN_UI then
if renderer.ui_ready() then
log_render("closing main UI before executing new request to start")
renderer.close_ui()
end
log_render("starting main UI...")
local draw_start = util.time_ms()
local ui_message
crd_state.ui_ok, ui_message = renderer.try_start_ui()
if not crd_state.ui_ok then
log_render(util.c("main UI error: ", ui_message))
log.fatal(util.c("main GUI render failed with error ", ui_message))
else
log_render("main UI draw took " .. (util.time_ms() - draw_start) .. "ms")
end
elseif msg.message == MQ__RENDER_CMD.CLOSE_MAIN_UI then
if renderer.ui_ready() then
log_render("closing main UI...")
renderer.close_ui()
log_render("main UI closed")
end
end
elseif msg.qtype == mqueue.TYPE.DATA then
local cmd = msg.message
if cmd.key == MQ__RENDER_DATA.MON_CONNECT then
renderer.handle_reconnect(cmd.val)
elseif cmd.key == MQ__RENDER_DATA.MON_DISCONNECT then
renderer.handle_disconnect(cmd.val)
elseif cmd.key == MQ__RENDER_DATA.MON_RESIZE then
local is_used, is_ok = renderer.handle_resize(cmd.val)
if is_used then
log_sys(util.c("configured monitor ", cmd.val, " resized, ", util.trinary(is_ok, "display fits", "display does not fit")))
end
end
end
end
util.nop()
end
if crd_state.shutdown then
log.info("OS: render thread exiting")
break
end
last_update = util.adaptive_delay(RENDER_SLEEP, last_update)
end
end
function public.p_exec()
local crd_state = smem.crd_state
while not crd_state.shutdown do
local status, result = pcall(public.exec)
if status == false then
log.fatal(util.strval(result))
end
ioctl.fp_rt_status("render", false)
if not crd_state.shutdown then
log.info("OS: render thread restarting in 5 seconds...")
util.psleep(5)
end
end
end
return public
end
return threads
]=]):sub(2)),
["coordinator/ui/components/fusion_overview.lua"]=(([=[!local core = require("graphics.core")
local style = require("coordinator.ui.style")
local fusion = require("coordinator.fusion")
local Div = require("graphics.elements.Div")
local TextBox = require("graphics.elements.TextBox")
return function(parent,x,y,width)
local root = Div{parent=parent,x=x,y=y,width=width,height=17}
TextBox{parent=root,y=1,text="FUSION / GENERATION",alignment=core.ALIGN.CENTER,fg_bg=style.theme.header}
local state = TextBox{parent=root,x=2,y=3,width=width-2,text="NO LIVE DATA",fg_bg=style.lg_white}
state.register(fusion.ps,"status",state.set_value)
local fields = {{"Fusion: ","fusion"},{"Fission: ","fission"},{"Total: ","total"},{"Telemetry age: ","age"}}
for i,item in ipairs(fields) do
local line = TextBox{parent=root,x=2,y=3+i*2,width=width-2,text=item[1].."--"}
local prefix = item[1]
line.register(fusion.ps,item[2],function(value) line.set_value(prefix..value) end)
end
TextBox{parent=root,x=2,y=14,width=width-2,text="Fusion telemetry only",fg_bg=style.lg_gray}
TextBox{parent=root,x=2,y=16,width=width-2,text="Total = fission turbines + fusion",fg_bg=style.lg_gray}
return root
end
]=]):sub(2)),
["coordinator/ui/layout/main_view.lua"]=(([=[!
local util          = require("scada-common.util")
local types         = require("scada-common.types")
local ioctl         = require("coordinator.ioctl")
local style         = require("coordinator.ui.style")
local ecore         = require("coordinator.ui.components.ecore")
local imatrix       = require("coordinator.ui.components.imatrix")
local process_ctl   = require("coordinator.ui.components.process_ctl")
local unit_overview = require("coordinator.ui.components.unit_overview")
local fusion        = require("coordinator.fusion")
local fusion_overview = require("coordinator.ui.components.fusion_overview")
local core          = require("graphics.core")
local TextBox       = require("graphics.elements.TextBox")
local DataIndicator = require("graphics.elements.indicators.DataIndicator")
local ALIGN = core.ALIGN
local function init(main)
local s_header = style.theme.header
local fac   = ioctl.get_db().facility
local units = ioctl.get_db().units
local compact = main.get_width() < 162
if compact then
assert(main.get_width() >= 141, "compact main display needs seven monitor blocks of width")
assert(fac.num_units == 1, "compact main display supports one reactor unit; use eight-wide for multiple units")
end
local header = TextBox{parent=main,y=1,text="Nuclear Generation Facility SCADA Coordinator",alignment=ALIGN.CENTER,fg_bg=s_header}
local ping = DataIndicator{parent=main,y=1,label="SVTT",format="%d",value=0,unit="ms",lu_colors=style.lg_white,width=12,fg_bg=s_header}
local datetime = TextBox{parent=main,x=(header.get_width()-42),y=1,text="",alignment=ALIGN.RIGHT,width=42,fg_bg=s_header}
ping.register(fac.ps, "sv_ping", ping.update)
datetime.register(fac.ps, "date_time", datetime.set_value)
local uo_1, uo_2, uo_3, uo_4
local cnc_y_start = 3
local row_1_height = 0
if fac.num_units >= 1 then
uo_1 = unit_overview(main, 2, 3, units[1])
row_1_height = uo_1.get_height()
end
if fac.num_units >= 2 then
uo_2 = unit_overview(main, 84, 3, units[2])
row_1_height = math.max(row_1_height, uo_2.get_height())
end
if fac.num_units == 1 and fusion.enabled() then
local fusion_x = util.trinary(compact, 107, 84)
local summary = fusion_overview(main, fusion_x, 3, main.get_width() - fusion_x)
row_1_height = math.max(row_1_height, summary.get_height())
end
cnc_y_start = cnc_y_start + row_1_height + 1
util.nop()
if fac.num_units >= 3 then
local row_2_offset = cnc_y_start
uo_3 = unit_overview(main, 2, row_2_offset, units[3])
cnc_y_start = row_2_offset + uo_3.get_height() + 1
if fac.num_units == 4 then
uo_4 = unit_overview(main, 84, row_2_offset, units[4])
cnc_y_start = math.max(cnc_y_start, row_2_offset + uo_4.get_height() + 1)
end
util.nop()
end
local cnc_bottom_align_start = main.get_height() - 26
assert(cnc_bottom_align_start >= cnc_y_start, "main display not of sufficient vertical resolution (add an additional row of monitors)")
TextBox{parent=main,y=cnc_bottom_align_start,text=string.rep("\x8c", header.get_width()),alignment=ALIGN.CENTER,fg_bg=style.lg_gray}
cnc_bottom_align_start = cnc_bottom_align_start + 2
process_ctl(main, 2, cnc_bottom_align_start, compact)
util.nop()
if fac.ess_type == types.ESS.INDUCTION_MATRIX then
imatrix(main, util.trinary(compact, 109, 131), cnc_bottom_align_start, fac.induction_ps_tbl[1])
elseif fac.ess_type == types.ESS.ENERGY_CORE then
ecore(main, util.trinary(compact, 109, 131), cnc_bottom_align_start, fac.ecore_ps_tbl[1])
end
end
return init
]=]):sub(2)),
["fusion/config.lua"]=(([=[!local config = { PATH = "/fusion/settings.json", DEFAULT_CHANNEL = 16245 }
function config.valid(c, role)
if type(c) ~= "table" or c.role ~= role or type(c.channel) ~= "number"
or c.channel % 1 ~= 0 or c.channel < 1 or c.channel > 65533 then return false end
if role == "coordinator" then
return type(c.monitor) == "string" and #c.monitor > 0 and type(c.source) == "number"
and c.source % 1 == 0 and c.source >= 0
end
return type(c.reactor) == "string" and #c.reactor > 0 and type(c.port) == "string"
and type(c.laser) == "string" and type(c.modem) == "string" and #c.modem > 0
and type(c.auth_key) == "string" and (#c.auth_key == 0 or #c.auth_key >= 8)
end
function config.load(role)
if not fs.exists(config.PATH) then return nil end
local f = fs.open(config.PATH, "r")
if not f then return nil end
local c = textutils.unserializeJSON(f.readAll())
f.close()
if config.valid(c, role) then return c end
return nil
end
return config
]=]):sub(2)),
["fusion/configure.lua"]=(([=[!package.path = "/?.lua;/?/init.lua;" .. package.path
local cfg = require("fusion.config")
local role = ({...})[1] or (fs.exists("/coordinator/startup.lua") and "coordinator" or "agent")
assert(role == "agent" or role == "coordinator", "Specify agent or coordinator")
local previous = cfg.load(role) or {}
local names = peripheral.getNames()
table.sort(names)
local function choose(label, filter, preferred, optional)
local found = {}
print("\n" .. label)
for _, name in ipairs(names) do
if filter(name) then
found[#found+1] = name
print(#found .. ": " .. name)
end
end
if #found == 0 then
if optional then print("Not connected; omitted.") return "" end
error("No matching peripheral. Check its modem and cable.", 0)
end
local default = 1
for i, name in ipairs(found) do if name == preferred then default = i end end
while true do
write("Choose [" .. default .. "]: ")
local answer = read()
local idx = answer == "" and default or tonumber(answer)
if idx and idx % 1 == 0 and found[idx] then return found[idx] end
print("Enter one of the numbers above.")
end
end
local function number(label, default, low, high)
while true do
write(label .. " [" .. default .. "]: ")
local answer = read()
local n = answer == "" and default or tonumber(answer)
if n and n % 1 == 0 and n >= low and n <= high then return n end
print("Enter a whole number from " .. low .. " to " .. high .. ".")
end
end
print("SCADA Fusion Monitoring Setup")
print("Computer ID: " .. os.getComputerID())
local c = { role=role }
if role == "coordinator" then
assert(settings.load("/coordinator.settings"), "Coordinator configuration not found")
local used = {[settings.get("MainDisplay", "")]=true,[settings.get("FlowDisplay", "")]=true}
for _, name in ipairs(settings.get("UnitDisplays", {})) do used[name] = true end
c.monitor = choose("Fusion display (existing SCADA displays excluded):", function(name)
if used[name] or not peripheral.hasType(name, "monitor") then return false end
local monitor = peripheral.wrap(name)
if not monitor.isColor() then return false end
monitor.setTextScale(0.5)
local w,h = monitor.getSize()
if w < 79 or h < 52 then return false end
monitor.setBackgroundColor(colors.black)
monitor.setTextColor(colors.white)
monitor.clear()
monitor.setCursorPos(1,1)
monitor.write("Fusion screen candidate: " .. name)
return true
end, previous.monitor)
c.source = number("Fusion computer ID", previous.source or 9, 0, 2147483647)
else
c.reactor = choose("Fusion reactor adapter:", function(n) return peripheral.hasType(n,"fusionReactorLogicAdapter") end, previous.reactor)
c.port = choose("Fusion reactor port:", function(n) return peripheral.hasType(n,"fusionReactorPort") end, previous.port, true)
c.laser = choose("Laser amplifier:", function(n) return peripheral.hasType(n,"laserAmplifier") end, previous.laser, true)
c.modem = choose("Wireless / Ender Modem:", function(n)
return peripheral.hasType(n,"modem") and peripheral.call(n,"isWireless")
end, previous.modem)
print("\nEnter the SCADA network authentication key.")
print("Leave blank if your SCADA network has no key.")
while true do
write(previous.auth_key and "Key [Enter keeps saved key]: " or "Key: ")
c.auth_key = read("*")
if c.auth_key == "" and previous.auth_key then c.auth_key = previous.auth_key end
if #c.auth_key == 0 or #c.auth_key >= 8 then break end
print("Use at least 8 characters, or leave it empty.")
end
end
c.channel = number("Fusion telemetry channel", previous.channel or cfg.DEFAULT_CHANNEL, 1, 65533)
if role == "coordinator" then
for _, key in ipairs({"SVR_Channel","CRD_Channel","PKT_Channel"}) do
assert(c.channel ~= settings.get(key), "Fusion channel must differ from " .. key)
end
end
assert(cfg.valid(c, role), "Configuration invalid")
fs.makeDir("/fusion")
local f = assert(fs.open(cfg.PATH, "w"))
f.write(textutils.serializeJSON(c))
f.close()
print("\nSaved. " .. (role == "agent" and "Run startup to send readings." or "Run startup to start the Coordinator."))
]=]):sub(2)),
["fusion/model.lua"]=(([=[!
local model = { PROTOCOL = 97, SCHEMA = 1, TIMEOUT = 5000 }
local numeric = {
"production", "plasma", "casing", "injection", "dt", "dt_capacity",
"deuterium", "deuterium_capacity", "tritium", "tritium_capacity",
"hohlraum_fuel", "port_energy", "port_capacity", "laser_energy",
"laser_capacity", "laser_min", "laser_max", "laser_delay"
}
local function finite(v) return type(v) == "number" and v == v and v >= 0 and v < math.huge end
local function integer(v) return finite(v) and v % 1 == 0 and v < 2^53 end
model.finite = finite
function model.collect(call, config, now, session, sequence)
local data = { schema=1, sample_ms=now, session=session, seq=sequence, errors={} }
local function fault(name, method)
if #data.errors < 8 then data.errors[#data.errors+1] = name .. ": " .. method .. " unavailable" end
end
local function read(name, method, field, kind)
if not name or name == "" then return end
local ok, value = pcall(call, name, method)
if not ok then fault(name, method) return end
if kind == "tank" then
if type(value) == "table" and finite(value.amount) then data[field] = value.amount else fault(name, method) end
elseif kind == "boolean" then
if type(value) == "boolean" then data[field] = value else fault(name, method) end
elseif kind == "mode" then
if value == "HIGH" or value == "LOW" or value == "DISABLED" then data[field] = value else fault(name, method) end
elseif finite(value) then data[field] = value
else fault(name, method) end
end
local reactor = config.reactor
read(reactor, "isFormed", "formed", "boolean")
read(reactor, "isIgnited", "ignited", "boolean")
read(reactor, "getProductionRate", "production")
read(reactor, "getPlasmaTemperature", "plasma")
read(reactor, "getCaseTemperature", "casing")
read(reactor, "getInjectionRate", "injection")
for _, item in ipairs({{"getDTFuel","dt"},{"getDeuterium","deuterium"},{"getTritium","tritium"}}) do
read(reactor, item[1], item[2], "tank")
read(reactor, item[1] .. "Capacity", item[2] .. "_capacity")
end
local ok, item = pcall(call, reactor, "getHohlraum")
if ok and type(item) == "table" and finite(item.count) then
data.hohlraum_present = item.count > 0 and item.name == "mekanismgenerators:hohlraum"
if data.hohlraum_present and type(item.components) == "string" then
if item.components:find("mekanismgenerators:fusion_fuel", 1, true) then
data.hohlraum_fuel = tonumber(item.components:match("amount:%s*(%d+)L?"))
end
end
else fault(reactor, "getHohlraum") end
read(config.port, "getEnergy", "port_energy")
read(config.port, "getMaxEnergy", "port_capacity")
read(config.laser, "getEnergy", "laser_energy")
read(config.laser, "getMaxEnergy", "laser_capacity")
read(config.laser, "getMinThreshold", "laser_min")
read(config.laser, "getMaxThreshold", "laser_max")
read(config.laser, "getDelay", "laser_delay")
read(config.laser, "getRedstoneMode", "laser_mode", "mode")
return data
end
function model.validate(data, now)
if type(data) ~= "table" or data.schema ~= 1 or not integer(data.sample_ms)
or not integer(data.session) or not integer(data.seq) or data.seq < 1
or data.session > data.sample_ms or now - data.sample_ms > model.TIMEOUT
or data.sample_ms - now > 2000 then return nil end
local clean = {schema=1,sample_ms=data.sample_ms,session=data.session,seq=data.seq,errors={}}
for _, field in ipairs(numeric) do
if data[field] ~= nil then
if not finite(data[field]) then return nil end
clean[field] = data[field]
end
end
for _, field in ipairs({"formed","ignited","hohlraum_present"}) do
if data[field] ~= nil then
if type(data[field]) ~= "boolean" then return nil end
clean[field] = data[field]
end
end
if data.laser_mode ~= nil then
if data.laser_mode ~= "HIGH" and data.laser_mode ~= "LOW" and data.laser_mode ~= "DISABLED" then return nil end
clean.laser_mode = data.laser_mode
end
if type(data.errors) ~= "table" or #data.errors > 8 then return nil end
for _, value in ipairs(data.errors) do
if type(value) ~= "string" or #value > 120 then return nil end
clean.errors[#clean.errors+1] = value:gsub("[%c]", " ")
end
return clean
end
function model.receiver(source)
local last, received
return {
accept = function(id, data, now)
if id ~= source then return false end
local clean = model.validate(data, now)
if not clean then return false end
if last and (clean.session < last.session or
(clean.session == last.session and clean.seq <= last.seq) or
clean.sample_ms < last.sample_ms) then return false end
last, received = clean, now
return true
end,
snapshot = function(now)
if last and now - received < model.TIMEOUT and now - last.sample_ms < model.TIMEOUT then
return last, math.max(0, now - last.sample_ms)
end
return nil, last and now - last.sample_ms or nil
end
}
end
function model.status(data)
if not data then return "NO LIVE DATA", "red" end
if data.formed == nil or data.ignited == nil then return "READ ERROR", "orange" end
if not data.formed then return "UNFORMED", "red" end
if #data.errors > 0 then return data.ignited and "RUNNING / PARTIAL DATA" or "IDLE / PARTIAL DATA", "orange" end
return data.ignited and "RUNNING" or "IDLE", data.ignited and "green" or "gray"
end
function model.format(value, unit)
if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return "--" end
local prefixes = {"", "k", "M", "G", "T", "P"}
local idx = 1
while math.abs(value) >= 1000 and idx < #prefixes do value, idx = value / 1000, idx + 1 end
return string.format("%.2f %s%s", value, prefixes[idx], unit)
end
return model
]=]):sub(2)),
["fusion/startup.lua"]=(([=[!
package.path = "/?.lua;/?/init.lua;" .. package.path
local config = require("fusion.config").load("agent")
if not config then error("Run fusion/configure agent first.", 0) end
local model = require("fusion.model")
local comms = require("scada-common.comms")
local network = require("scada-common.network")
local ppm = require("scada-common.ppm")
ppm.mount_all()
if #config.auth_key >= 8 then network.init_mac(config.auth_key) end
local nic = network.nic(ppm.get_periph(config.modem))
nic.open(config.channel)
local session, sequence = os.epoch("utc"), 0
print("SCADA Fusion Telemetry 1.0")
print("Computer " .. os.getComputerID() .. " | Channel " .. config.channel)
print("Read-only. Ctrl+T exits monitoring.")
local function sample()
sequence = sequence + 1
local snapshot = model.collect(peripheral.call, config, os.epoch("utc"), session, sequence)
local frame = comms.scada_frame()
frame.make(comms.BROADCAST, sequence, model.PROTOCOL, {snapshot})
nic.transmit(config.channel, config.channel, frame)
term.setCursorPos(1,5)
term.clearLine()
local status = model.status(snapshot)
print(status)
term.clearLine()
print("Generation: " .. model.format(snapshot.production and snapshot.production * 0.4, "FE/t"))
term.clearLine()
print(nic.is_connected() and "Transmitting to Coordinator" or "Modem disconnected")
end
sample()
local timer = os.startTimer(1)
while true do
local event,a,b,c,d,e = os.pullEventRaw()
if event == "terminate" then nic.close(config.channel) break end
if event == "timer" and a == timer then sample() timer=os.startTimer(1)
elseif event == "modem_message" and b == config.channel then nic.receive(a,b,c,d,e)
elseif event == "peripheral" then
ppm.mount(a)
if a == config.modem then nic.connect(ppm.get_periph(a)) end
elseif event == "peripheral_detach" then
ppm.handle_unmount(a)
if a == config.modem then nic.disconnect() end
end
end
]=]):sub(2)),
["fusion/view.lua"]=(([=[!local model = require("fusion.model")
local view = {}
function view.draw(monitor, data, context)
monitor.setTextScale(0.5)
local w,h = monitor.getSize()
monitor.setBackgroundColor(colors.black)
monitor.setTextColor(colors.white)
monitor.clear()
local function line(y, text, color, background)
if y > h then return end
monitor.setCursorPos(2,y)
monitor.setTextColor(color or colors.white)
monitor.setBackgroundColor(background or colors.black)
text = tostring(text):sub(1,w-2)
monitor.write(text .. string.rep(" ", math.max(0,w-2-#text)))
end
if w < 79 or h < 52 then line(1,"Fusion display needs a 4x4 Advanced Monitor.",colors.red) return end
local function number(value, unit)
return model.format(value,unit)
end
local function energy(value, rate)
return value and number(context.energy_convert(value), context.energy_label .. (rate and "/t" or "")) or "--"
end
local function temperature(value)
return value and number(context.temp_convert(value),context.temp_label) or "--"
end
local function tank(amount, capacity)
if amount == nil or capacity == nil then return "--" end
local percent = capacity > 0 and 100*amount/capacity or 0
return string.format("%.0f / %.0f mB   (%.1f%%)",amount,capacity,percent)
end
local function section(y,title) line(y,title,colors.white,colors.gray) end
local status,color = model.status(data)
line(1,"FUSION REACTOR - SCADA",colors.white,colors.blue)
line(3,status,colors.white,colors[color])
line(5, data and ("Live telemetry | Age " .. string.format("%.1fs",context.age/1000)) or "Telemetry unavailable - current values hidden", data and colors.lime or colors.red)
data = data or {}
section(7,"POWER GENERATION")
line(9,"Fusion output:              " .. energy(data.production,true),colors.cyan)
line(11,"Fission turbine output:     " .. energy(context.fission,true))
line(13,"Fission + fusion total:     " .. energy(data.production and context.fission and (data.production+context.fission),true),colors.lime)
line(14,"Generator output; Matrix input/output is a separate measurement.",colors.lightGray)
section(16,"REACTOR TEMPERATURES")
line(18,"Plasma:                     " .. temperature(data.plasma),colors.orange)
line(20,"Casing:                     " .. temperature(data.casing),colors.orange)
section(22,"FUEL")
line(24,"Premixed D-T:               " .. tank(data.dt,data.dt_capacity),colors.cyan)
line(26,"Deuterium:                  " .. tank(data.deuterium,data.deuterium_capacity))
line(28,"Tritium:                    " .. tank(data.tritium,data.tritium_capacity))
line(30,"Injection setting:          " .. (data.injection and tostring(data.injection).." mB/t" or "--"))
line(31,"Injection setting applies to separate D/T feeds, not premixed D-T.",colors.lightGray)
section(33,"ENERGY BUFFER AND IGNITION LASER")
line(35,"Reactor buffer:             " .. energy(data.port_energy,false) .. " / " .. energy(data.port_capacity,false))
line(37,"Laser stored:               " .. energy(data.laser_energy,false) .. " / " .. energy(data.laser_capacity,false),colors.cyan)
line(39,"Laser minimum threshold:    " .. energy(data.laser_min,false))
local threshold = "--"
if data.laser_energy and data.laser_min then
threshold = data.laser_energy >= data.laser_min and "THRESHOLD REACHED" or "CHARGING / BELOW THRESHOLD"
end
line(41,"Laser energy status:        " .. threshold,colors.yellow)
local hohlraum = "--"
if data.hohlraum_present == false then hohlraum="EMPTY"
elseif data.hohlraum_present then hohlraum=data.hohlraum_fuel and (data.hohlraum_fuel.." mB D-T") or "PRESENT / CHARGE UNKNOWN" end
line(43,"Hohlraum:                   " .. hohlraum)
line(45,"Laser redstone mode:        " .. (data.laser_mode or "--"))
if data.errors and #data.errors > 0 then line(47,data.errors[1],colors.orange)
elseif not data.production then line(47,"Check fusion computer, modems and peripheral sharing.",colors.orange)
elseif context.fission == nil then line(47,"Fission total unavailable until SCADA turbine data is live.",colors.orange)
else line(47,"Reactor operation remains under your existing controls.",colors.lightGray) end
line(50,"READ-ONLY MONITORING",colors.white,colors.blue)
end
return view
]=]):sub(2)),
["lockbox/digest/md5.lua"]=(([=[!local Bit = require("lockbox.util.bit");
local String = require("string");
local Math = require("math");
local Queue = require("lockbox.util.queue");
local SHIFT = {
7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,
5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,
4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,
6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21};
local CONSTANTS = {
0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391};
local AND = Bit.band;
local OR  = Bit.bor;
local NOT = Bit.bnot;
local XOR = Bit.bxor;
local LROT = Bit.lrotate;
local LSHIFT = Bit.lshift;
local RSHIFT = Bit.rshift;
local bytes2word = function(b0, b1, b2, b3)
local i = b3; i = LSHIFT(i, 8);
i = OR(i, b2); i = LSHIFT(i, 8);
i = OR(i, b1); i = LSHIFT(i, 8);
i = OR(i, b0);
return i;
end
local word2bytes = function(word)
local b0, b1, b2, b3;
b0 = AND(word, 0xFF); word = RSHIFT(word, 8);
b1 = AND(word, 0xFF); word = RSHIFT(word, 8);
b2 = AND(word, 0xFF); word = RSHIFT(word, 8);
b3 = AND(word, 0xFF);
return b0, b1, b2, b3;
end
local dword2bytes = function(i)
local b4, b5, b6, b7 = word2bytes(Math.floor(i / 0x100000000));
local b0, b1, b2, b3 = word2bytes(i);
return b0, b1, b2, b3, b4, b5, b6, b7;
end
local F = function(x, y, z) return OR(AND(x, y), AND(NOT(x), z)); end
local G = function(x, y, z) return OR(AND(x, z), AND(y, NOT(z))); end
local H = function(x, y, z) return XOR(x, XOR(y, z)); end
local I = function(x, y, z) return XOR(y, OR(x, NOT(z))); end
local MD5 = function()
local queue = Queue();
local A = 0x67452301;
local B = 0xefcdab89;
local C = 0x98badcfe;
local D = 0x10325476;
local public = {};
local processBlock = function()
local a = A;
local b = B;
local c = C;
local d = D;
local X = {};
for i = 1, 16 do
X[i] = bytes2word(queue.pop(), queue.pop(), queue.pop(), queue.pop());
end
for i = 0, 63 do
local f, g, temp;
if (0 <= i) and (i <= 15) then
f = F(b, c, d);
g = i;
elseif (16 <= i) and (i <= 31) then
f = G(b, c, d);
g = (5 * i + 1) % 16;
elseif (32 <= i) and (i <= 47) then
f = H(b, c, d);
g = (3 * i + 5) % 16;
elseif (48 <= i) and (i <= 63) then
f = I(b, c, d);
g = (7 * i) % 16;
end
temp = d;
d = c;
c = b;
b = b + LROT((a + f + CONSTANTS[i + 1] + X[g + 1]), SHIFT[i + 1]);
a = temp;
end
A = AND(A + a, 0xFFFFFFFF);
B = AND(B + b, 0xFFFFFFFF);
C = AND(C + c, 0xFFFFFFFF);
D = AND(D + d, 0xFFFFFFFF);
end
public.init = function()
queue.reset();
A = 0x67452301;
B = 0xefcdab89;
C = 0x98badcfe;
D = 0x10325476;
return public;
end
public.update = function(bytes)
for b in bytes do
queue.push(b);
if(queue.size() >= 64) then processBlock(); end
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
local  b0, b1, b2, b3 = word2bytes(A);
local  b4, b5, b6, b7 = word2bytes(B);
local  b8, b9, b10, b11 = word2bytes(C);
local b12, b13, b14, b15 = word2bytes(D);
return {b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15};
end
public.asHex = function()
local  b0, b1, b2, b3 = word2bytes(A);
local  b4, b5, b6, b7 = word2bytes(B);
local  b8, b9, b10, b11 = word2bytes(C);
local b12, b13, b14, b15 = word2bytes(D);
return String.format("%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15);
end
public.asString = function()
local b0, b1, b2, b3 = word2bytes(A);
local b4, b5, b6, b7 = word2bytes(B);
local b8, b9, b10, b11 = word2bytes(C);
local b12, b13, b14, b15 = word2bytes(D);
return string.pack(string.rep('B', 16),
b0, b1, b2, b3, b4, b5, b6, b7, b8,
b9, b10, b11, b12, b13, b14, b15
)
end
return public;
end
return MD5;
]=]):sub(2)),
["lockbox/digest/sha1.lua"]=(([=[!local Bit = require("lockbox.util.bit");
local String = require("string");
local Math = require("math");
local Queue = require("lockbox.util.queue");
local AND = Bit.band;
local OR  = Bit.bor;
local XOR = Bit.bxor;
local LROT = Bit.lrotate;
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
local F = function(x, y, z) return XOR(z, AND(x, XOR(y, z))); end
local G = function(x, y, z) return XOR(x, XOR(y, z)); end
local H = function(x, y, z) return OR(AND(x, OR(y, z)), AND(y, z)); end
local I = function(x, y, z) return XOR(x, XOR(y, z)); end
local SHA1 = function()
local queue = Queue();
local h0 = 0x67452301;
local h1 = 0xEFCDAB89;
local h2 = 0x98BADCFE;
local h3 = 0x10325476;
local h4 = 0xC3D2E1F0;
local public = {};
local processBlock = function()
local a = h0;
local b = h1;
local c = h2;
local d = h3;
local e = h4;
local temp;
local k;
local w = {};
for i = 0, 15 do
w[i] = bytes2word(queue.pop(), queue.pop(), queue.pop(), queue.pop());
end
for i = 16, 79 do
w[i] = LROT((XOR(XOR(w[i - 3], w[i - 8]), XOR(w[i - 14], w[i - 16]))), 1);
end
for i = 0, 79 do
if (i <= 19) then
temp = F(b, c, d);
k = 0x5A827999;
elseif (i <= 39) then
temp = G(b, c, d);
k = 0x6ED9EBA1;
elseif (i <= 59) then
temp = H(b, c, d);
k = 0x8F1BBCDC;
else
temp = I(b, c, d);
k = 0xCA62C1D6;
end
temp = LROT(a, 5) + temp + e + k + w[i];
e = d;
d = c;
c = LROT(b, 30);
b = a;
a = temp;
end
h0 = AND(h0 + a, 0xFFFFFFFF);
h1 = AND(h1 + b, 0xFFFFFFFF);
h2 = AND(h2 + c, 0xFFFFFFFF);
h3 = AND(h3 + d, 0xFFFFFFFF);
h4 = AND(h4 + e, 0xFFFFFFFF);
end
public.init = function()
queue.reset();
h0 = 0x67452301;
h1 = 0xEFCDAB89;
h2 = 0x98BADCFE;
h3 = 0x10325476;
h4 = 0xC3D2E1F0;
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
return {b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, b16, b17, b18, b19};
end
public.asHex = function()
local  b0, b1, b2, b3 = word2bytes(h0);
local  b4, b5, b6, b7 = word2bytes(h1);
local  b8, b9, b10, b11 = word2bytes(h2);
local b12, b13, b14, b15 = word2bytes(h3);
local b16, b17, b18, b19 = word2bytes(h4);
return String.format("%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15, b16, b17, b18, b19);
end
return public;
end
return SHA1;
]=]):sub(2)),
["lockbox/digest/sha2_256.lua"]=(([=[!local Bit = require("lockbox.util.bit");
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
]=]):sub(2)),
["lockbox/init.lua"]=(([=[!local Lockbox = {}
Lockbox.version = "1.2"
return Lockbox
]=]):sub(2)),
["lockbox/kdf/pbkdf2.lua"]=(([=[!local Bit = require("lockbox.util.bit");
local Array = require("lockbox.util.array");
local Stream = require("lockbox.util.stream");
local Math = require("math");
local AND = Bit.band;
local RSHIFT = Bit.rshift;
local word2bytes = function(word)
local b0, b1, b2, b3;
b3 = AND(word, 0xFF); word = RSHIFT(word, 8);
b2 = AND(word, 0xFF); word = RSHIFT(word, 8);
b1 = AND(word, 0xFF); word = RSHIFT(word, 8);
b0 = AND(word, 0xFF);
return b0, b1, b2, b3;
end
local PBKDF2 = function()
local public = {};
local blockLen = 16;
local dKeyLen = 256;
local iterations = 4096;
local salt;
local password;
local PRF;
local dKey;
public.setBlockLen = function(len)
blockLen = len;
return public;
end
public.setDKeyLen = function(len)
dKeyLen = len
return public;
end
public.setIterations = function(iter)
iterations = iter;
return public;
end
public.setSalt = function(saltBytes)
salt = saltBytes;
return public;
end
public.setPassword = function(passwordBytes)
password = passwordBytes;
return public;
end
public.setPRF = function(prf)
PRF = prf;
return public;
end
local buildBlock = function(i)
local b0, b1, b2, b3 = word2bytes(i);
local ii = {b0, b1, b2, b3};
local s = Array.concat(salt, ii);
local out = {};
PRF.setKey(password);
for c = 1, iterations do
PRF.init()
.update(Stream.fromArray(s));
s = PRF.finish().asBytes();
if(c > 1) then
out = Array.XOR(out, s);
else
out = s;
end
end
return out;
end
public.finish = function()
local blocks = Math.ceil(dKeyLen / blockLen);
dKey = {};
for b = 1, blocks do
local block = buildBlock(b);
dKey = Array.concat(dKey, block);
end
if(Array.size(dKey) > dKeyLen) then dKey = Array.truncate(dKey, dKeyLen); end
return public;
end
public.asBytes = function()
return dKey;
end
public.asHex = function()
return Array.toHex(dKey);
end
return public;
end
return PBKDF2;
]=]):sub(2)),
["lockbox/mac/hmac.lua"]=(([=[!local Bit = require("lockbox.util.bit");
local Stream = require("lockbox.util.stream");
local Array = require("lockbox.util.array");
local XOR = Bit.bxor;
local HMAC = function()
local public = {};
local blockSize = 64;
local Digest;
local outerPadding = {};
local innerPadding = {}
local digest;
public.setBlockSize = function(bytes)
blockSize = bytes;
return public;
end
public.setDigest = function(digestModule)
Digest = digestModule;
digest = Digest();
return public;
end
public.setKey = function(key)
local keyStream;
if(Array.size(key) > blockSize) then
keyStream = Stream.fromArray(Digest()
.update(Stream.fromArray(key))
.finish()
.asBytes());
else
keyStream = Stream.fromArray(key);
end
outerPadding = {};
innerPadding = {};
for i = 1, blockSize do
local byte = keyStream();
if byte == nil then byte = 0x00; end
outerPadding[i] = XOR(0x5C, byte);
innerPadding[i] = XOR(0x36, byte);
end
return public;
end
public.init = function()
digest.init()
.update(Stream.fromArray(innerPadding));
return public;
end
public.update = function(messageStream)
digest.update(messageStream);
return public;
end
public.finish = function()
local inner = digest.finish().asBytes();
digest.init()
.update(Stream.fromArray(outerPadding))
.update(Stream.fromArray(inner))
.finish();
return public;
end
public.asBytes = function()
return digest.asBytes();
end
public.asHex = function()
return digest.asHex();
end
return public;
end
return HMAC;
]=]):sub(2)),
["lockbox/util/array.lua"]=(([=[!local String = require("string");
local Bit = require("lockbox.util.bit");
local Queue = require("lockbox.util.queue");
local XOR = Bit.bxor;
local Array = {};
Array.size = function(array)
return #array;
end
Array.fromString = function(string)
local bytes = {};
local i = 1;
local byte = String.byte(string, i);
while byte ~= nil do
bytes[i] = byte;
i = i + 1;
byte = String.byte(string, i);
end
return bytes;
end
Array.toString = function(bytes)
local chars = {};
local i = 1;
local byte = bytes[i];
while byte ~= nil do
chars[i] = String.char(byte);
i = i + 1;
byte = bytes[i];
end
return table.concat(chars, "");
end
Array.fromStream = function(stream)
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
Array.readFromQueue = function(queue, size)
local array = {};
for i = 1, size do
array[i] = queue.pop();
end
return array;
end
Array.writeToQueue = function(queue, array)
local size = Array.size(array);
for i = 1, size do
queue.push(array[i]);
end
end
Array.toStream = function(array)
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
local fromHexTable = {};
for i = 0, 255 do
fromHexTable[String.format("%02X", i)] = i;
fromHexTable[String.format("%02x", i)] = i;
end
Array.fromHex = function(hex)
local array = {};
for i = 1, String.len(hex) / 2 do
local h = String.sub(hex, i * 2 - 1, i * 2);
array[i] = fromHexTable[h];
end
return array;
end
local toHexTable = {};
for i = 0, 255 do
toHexTable[i] = String.format("%02X", i);
end
Array.toHex = function(array)
local hex = {};
local i = 1;
local byte = array[i];
while byte ~= nil do
hex[i] = toHexTable[byte];
i = i + 1;
byte = array[i];
end
return table.concat(hex, "");
end
Array.concat = function(a, b)
local concat = {};
local out = 1;
local i = 1;
local byte = a[i];
while byte ~= nil do
concat[out] = byte;
i = i + 1;
out = out + 1;
byte = a[i];
end
i = 1;
byte = b[i];
while byte ~= nil do
concat[out] = byte;
i = i + 1;
out = out + 1;
byte = b[i];
end
return concat;
end
Array.truncate = function(a, newSize)
local x = {};
for i = 1, newSize do
x[i] = a[i];
end
return x;
end
Array.XOR = function(a, b)
local x = {};
for k, v in pairs(a) do
x[k] = XOR(v, b[k]);
end
return x;
end
Array.substitute = function(input, sbox)
local out = {};
for k, v in pairs(input) do
out[k] = sbox[v];
end
return out;
end
Array.permute = function(input, pbox)
local out = {};
for k, v in pairs(pbox) do
out[k] = input[v];
end
return out;
end
Array.copy = function(input)
local out = {};
for k, v in pairs(input) do
out[k] = v;
end
return out;
end
Array.slice = function(input, start, stop)
local out = {};
for i = start, stop do
out[i - start + 1] = input[i];
end
return out;
end
return Array;
]=]):sub(2)),
["lockbox/util/bit.lua"]=(([=[!
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
]=]):sub(2)),
["lockbox/util/queue.lua"]=(([=[!local Queue = function()
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
]=]):sub(2)),
["lockbox/util/stream.lua"]=(([=[!local Queue = require("lockbox.util.queue");
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
]=]):sub(2)),
["scada-common/comms.lua"]=(([=[!
local log = require("scada-common.log")
local type     = type
local insert   = table.insert
local TYPE_NUM = "number"
local TYPE_STR = "string"
local TYPE_TBL = "table"
local COMPUTER_ID = os.getComputerID()
local max_distance = nil
local comms = {}
comms.version = "3.4.0"
comms.api_version = "0.1.4"
local PROTOCOL = {
MODBUS_TCP = 0,      -- the "MODBUS TCP"-esque protocol
RPLC = 1,
SCADA_MGMT = 2,
SCADA_CRDN = 3
}
local RPLC_TYPE = {
STATUS = 0,
MEK_STRUCT = 1,
MEK_BURN_RATE = 2,
RPS_ENABLE = 3,
RPS_DISABLE = 4,
RPS_SCRAM = 5,
RPS_ASCRAM = 6,
RPS_STATUS = 7,
RPS_ALARM = 8,
RPS_RESET = 9,
RPS_AUTO_RESET = 10,
AUTO_BURN_RATE = 11
}
local MGMT_TYPE = {
ESTABLISH = 0,
KEEP_ALIVE = 1,
CLOSE = 2,
SWITCH_NET = 3,
RTU_ADVERT = 4,
RTU_DEV_REMOUNT = 5,
RTU_TONE_ALARM = 6,
DIAG_TONE_GET = 7,
DIAG_TONE_SET = 8,
DIAG_ALARM_SET = 9,
INFO_LIST_CMP = 10
}
local CRDN_TYPE = {
INITIAL_BUILDS = 0,
PROCESS_READY = 1,
FAC_BUILDS = 2,
FAC_STATUS = 3,
FAC_CMD = 4,
UNIT_BUILDS = 5,
UNIT_STATUSES = 6,
UNIT_CMD = 7,
API_GET_FAC = 8,
API_GET_FAC_DTL = 9,
API_GET_UNIT = 10,
API_GET_CTRL = 11,
API_GET_PROC = 12,
API_GET_WASTE = 13,
API_GET_RAD = 14
}
local ESTABLISH_ACK = {
ALLOW = 0,
DENY = 1,
COLLISION = 2,
BAD_VERSION = 3,
BAD_API_VERSION = 4
}
local DEVICE_TYPE = { PLC = 0, RTU = 1, SVR = 2, CRD = 3, PKT = 4 }
local PLC_AUTO_ACK = {
FAIL = 0,
DIRECT_SET_OK = 1,
RAMP_SET_OK = 2,
ZERO_DIS_OK = 3
}
local FAC_COMMAND = {
SCRAM_ALL = 0,
STOP = 1,
START = 2,
ACK_ALL_ALARMS = 3,
SET_WASTE_MODE = 4,
SET_PU_FB = 5,
SET_SPS_LP = 6
}
local UNIT_COMMAND = {
SCRAM = 0,
START = 1,
RESET_RPS = 2,
SET_BURN = 3,
SET_WASTE = 4,
ACK_ALL_ALARMS = 5,
ACK_ALARM = 6,
RESET_ALARM = 7,
SET_GROUP = 8
}
comms.PROTOCOL = PROTOCOL
comms.RPLC_TYPE = RPLC_TYPE
comms.MGMT_TYPE = MGMT_TYPE
comms.CRDN_TYPE = CRDN_TYPE
comms.ESTABLISH_ACK = ESTABLISH_ACK
comms.DEVICE_TYPE = DEVICE_TYPE
comms.PLC_AUTO_ACK = PLC_AUTO_ACK
comms.UNIT_COMMAND = UNIT_COMMAND
comms.FAC_COMMAND = FAC_COMMAND
comms.BROADCAST = -1
comms.CONN_TEST_FWV = "CONN_TEST"
function comms.set_trusted_range(distance)
if distance == 0 then max_distance = nil else max_distance = distance end
end
function comms.lld_frame()
local self = {
modem_frame = nil,
valid = false,
raw = {},
src_addr  = nil,
dest_addr = nil,
ack       = false
}
local public = {}
function public.make(dest_addr, ack)
self.valid = true
self.src_addr  = COMPUTER_ID
self.dest_addr = dest_addr
self.ack       = ack
self.raw = { COMPUTER_ID, dest_addr, ack }
end
function public.receive(side, sender, reply_to, message, distance)
self.modem_frame = {
iface = side, s_chan = sender, r_chan = reply_to, dist = distance, data = message
}
self.valid = false
self.raw   = self.modem_frame.data
if (type(max_distance) == TYPE_NUM) and (type(distance) == TYPE_NUM) and (distance > max_distance) then
elseif type(self.raw) == TYPE_TBL then
self.src_addr  = self.raw[1]
self.dest_addr = self.raw[2]
self.ack       = self.raw[3] == true
if (self.dest_addr == COMPUTER_ID) or (self.dest_addr == comms.BROADCAST) then
self.valid = type(self.src_addr) == TYPE_NUM and type(self.dest_addr) == TYPE_NUM
end
end
return self.valid
end
function public.modem_event() return self.modem_frame end
function public.raw_frame() return self.raw end
function public.interface() return self.modem_frame.iface end
function public.local_channel() return self.modem_frame.s_chan end
function public.remote_channel() return self.modem_frame.r_chan end
function public.is_valid() return self.valid end
function public.src_addr() return self.src_addr or comms.BROADCAST end
function public.dest_addr() return self.dest_addr or comms.BROADCAST end
function public.is_ack() return self.ack end
return public
end
function comms.scada_frame()
local self = {
modem_frame = nil,
valid         = false,
authenticated = false,
raw = {},
src_addr  = nil,
dest_addr = nil,
seq_num   = nil,
protocol  = nil,
length    = 0,
payload   = {}
}
local public = {}
function public.make(dest_addr, seq_num, protocol, payload)
self.valid = true
self.src_addr  = COMPUTER_ID
self.dest_addr = dest_addr
self.seq_num   = seq_num
self.protocol  = protocol
self.length    = #payload
self.payload   = payload
self.raw = { COMPUTER_ID, dest_addr, seq_num, protocol, payload }
end
function public.receive(side, sender, reply_to, message, distance)
self.modem_frame = {
iface = side, s_chan = sender, r_chan = reply_to, dist = distance, data = message
}
self.valid = false
self.raw   = self.modem_frame.data
if (type(max_distance) == TYPE_NUM) and (type(distance) == TYPE_NUM) and (distance > max_distance) then
elseif type(self.raw) == TYPE_TBL then
self.src_addr  = self.raw[1]
self.dest_addr = self.raw[2]
if ((self.dest_addr == COMPUTER_ID) or (self.dest_addr == comms.BROADCAST)) and (type(self.raw[5]) == TYPE_TBL) then
self.seq_num  = self.raw[3]
self.protocol = self.raw[4]
self.length   = #self.raw[5]
self.payload  = self.raw[5]
self.valid = type(self.src_addr) == TYPE_NUM and type(self.dest_addr) == TYPE_NUM and
type(self.seq_num) == TYPE_NUM and type(self.protocol) == TYPE_NUM
end
end
return self.valid
end
function public.stamp_authenticated() self.authenticated = true end
function public.modem_event() return self.modem_frame end
function public.raw_header() return { self.src_addr, self.dest_addr, self.seq_num, self.protocol } end
function public.raw_frame() return self.raw end
function public.interface() return self.modem_frame.iface end
function public.local_channel() return self.modem_frame.s_chan end
function public.remote_channel() return self.modem_frame.r_chan end
function public.is_valid() return self.valid end
function public.is_authenticated() return self.authenticated end
function public.src_addr() return self.src_addr or comms.BROADCAST end
function public.dest_addr() return self.dest_addr or comms.BROADCAST end
function public.seq_num() return self.seq_num or -1 end
function public.protocol() return self.protocol or PROTOCOL.SCADA_MGMT end
function public.length() return self.length or 0 end
function public.data() return self.payload or {} end
return public
end
function comms.authd_frame()
local self = {
modem_frame = nil,
valid = false,
raw = {},
src_addr  = nil,
dest_addr = nil,
mac       = "",
payload   = {}
}
local public = {}
function public.make(s_frame, mac)
self.valid = true
self.src_addr  = s_frame.src_addr()
self.dest_addr = s_frame.dest_addr()
self.mac       = mac(textutils.serialize(s_frame.raw_header(), { allow_repetitions = true, compact = true }))
self.raw = { self.src_addr, self.dest_addr, self.mac, s_frame.raw_frame() }
end
function public.receive(side, sender, reply_to, message, distance)
self.modem_frame = {
iface = side, s_chan = sender, r_chan = reply_to, data = message, dist = distance
}
self.valid = false
self.raw   = self.modem_frame.data
if (type(max_distance) == TYPE_NUM) and ((type(distance) ~= TYPE_NUM) or (distance > max_distance)) then
elseif type(self.raw) == TYPE_TBL then
self.src_addr  = self.raw[1]
self.dest_addr = self.raw[2]
if (self.dest_addr == COMPUTER_ID) or (self.dest_addr == comms.BROADCAST) then
self.mac     = self.raw[3]
self.payload = self.raw[4]
self.valid = type(self.src_addr) == TYPE_NUM and type(self.dest_addr) == TYPE_NUM and
type(self.mac) == TYPE_STR and type(self.payload) == TYPE_TBL
end
end
return self.valid
end
function public.modem_event() return self.modem_frame end
function public.raw_frame() return self.raw end
function public.local_channel() return self.modem_frame.s_chan end
function public.remote_channel() return self.modem_frame.r_chan end
function public.is_valid() return self.valid end
function public.src_addr() return self.src_addr or comms.BROADCAST end
function public.dest_addr() return self.dest_addr or comms.BROADCAST end
function public.mac() return self.mac or "" end
function public.data() return self.payload or {} end
return public
end
function comms.modbus_container()
local self = {
frame = nil,
raw = {},
txn_id    = -1,
length    = 0,
unit_id   = -1,
func_code = 0x80,
data      = {}
}
local public = {}
function public.make(txn_id, unit_id, func_code, data)
if type(data) == TYPE_TBL then
self.txn_id    = txn_id
self.length    = #data
self.unit_id   = unit_id
self.func_code = func_code
self.data      = data
self.raw = { self.txn_id, self.unit_id, self.func_code }
for i = 1, self.length do insert(self.raw, data[i]) end
return true
end
log.error("COMMS: [modbus_make] data not a table")
return false
end
function public.decode(frame)
if frame then
local data = frame.data()
self.frame = frame
self.raw   = data
if frame.protocol() == PROTOCOL.MODBUS_TCP then
self.txn_id    = data[1]
self.unit_id   = data[2]
self.func_code = data[3]
self.data      = { table.unpack(data, 4, #data) }
self.length    = #self.data
if type(self.txn_id) == TYPE_NUM and type(self.unit_id) == TYPE_NUM and type(self.func_code) == TYPE_NUM then
return public.get()
end
else log.debug("COMMS: [modbus_decode] attempted parse of incorrect protocol " .. frame.protocol(), true) end
else log.debug("COMMS: [modbus_decode] discarding nil frame", true) end
return nil
end
function public.raw_packet() return self.raw end
function public.get()
local adu = {
scada_frame = self.frame,
txn_id = self.txn_id,
length = self.length,
unit_id = self.unit_id,
func_code = self.func_code,
data = self.data
}
return adu
end
return public
end
function comms.rplc_container()
local self = {
frame = nil,
raw   = {},
id     = 0,
type   = 0,
length = 0,
data   = {}
}
local public = {}
function public.make(id, packet_type, data)
if type(data) == TYPE_TBL then
self.id     = id
self.type   = packet_type
self.length = #data
self.data   = data
self.raw = { self.id, self.type }
for i = 1, #data do insert(self.raw, data[i]) end
return true
end
log.error("COMMS: [rplc_make] data not a table")
return false
end
function public.decode(frame)
if frame then
local data = frame.data()
self.frame = frame
self.raw   = data
if frame.protocol() == PROTOCOL.RPLC then
self.id     = data[1]
self.type   = data[2]
self.data   = { table.unpack(data, 3, #data) }
self.length = #self.data
if type(self.id) == TYPE_NUM and type(self.type) == TYPE_NUM then
return public.get()
end
else log.debug("COMMS: [rplc_decode] attempted parse of incorrect protocol " .. frame.protocol(), true) end
else log.debug("COMMS: [rplc_decode] nil frame encountered", true) end
return nil
end
function public.raw_packet() return self.raw end
function public.get()
local packet = {
scada_frame = self.frame,
id = self.id,
type = self.type,
length = self.length,
data = self.data
}
return packet
end
return public
end
function comms.mgmt_container()
local self = {
frame = nil,
raw = {},
type   = 0,
length = 0,
data   = {}
}
local public = {}
function public.make(packet_type, data)
if type(data) == TYPE_TBL then
self.type   = packet_type
self.length = #data
self.data   = data
self.raw = { self.type }
for i = 1, #data do insert(self.raw, data[i]) end
return true
end
log.error("COMMS: [mgmt_make] data not a table")
return false
end
function public.decode(frame)
if frame then
local data = frame.data()
self.frame = frame
self.raw   = data
if frame.protocol() == PROTOCOL.SCADA_MGMT then
self.type   = data[1]
self.data   = { table.unpack(data, 2, #data) }
self.length = #self.data
if type(self.type) == TYPE_NUM then
return public.get()
end
else log.debug("COMMS: [mgmt_decode] attempted parse of incorrect protocol " .. frame.protocol(), true) end
else log.debug("COMMS: [mgmt_decode] nil frame encountered", true) end
return nil
end
function public.raw_packet() return self.raw end
function public.get()
local packet = {
scada_frame = self.frame,
type = self.type,
length = self.length,
data = self.data
}
return packet
end
return public
end
function comms.crdn_container()
local self = {
frame = nil,
raw = {},
type   = 0,
length = 0,
data   = {}
}
local public = {}
function public.make(packet_type, data)
if type(data) == TYPE_TBL then
self.type   = packet_type
self.length = #data
self.data   = data
self.raw = { self.type }
for i = 1, #data do insert(self.raw, data[i]) end
return true
end
log.error("COMMS: [crdn_make] data not a table")
return false
end
function public.decode(frame)
if frame then
local data = frame.data()
self.frame = frame
self.raw   = data
if frame.protocol() == PROTOCOL.SCADA_CRDN then
self.type   = data[1]
self.data   = { table.unpack(data, 2, #data) }
self.length = #self.data
if type(self.type) == TYPE_NUM then
return public.get()
end
else log.debug("COMMS: [crdn_decode] attempted parse of incorrect protocol " .. frame.protocol(), true) end
else log.debug("COMMS: [crdn_decode] nil frame encountered", true) end
return nil
end
function public.raw_packet() return self.raw end
function public.get()
local packet = {
scada_frame = self.frame,
type = self.type,
length = self.length,
data = self.data
}
return packet
end
return public
end
return comms
]=]):sub(2)),
["scada-common/constants.lua"]=(([=[!
local constants = {}
local rps = {}
rps.MAX_DAMAGE_PERCENT      = 90
rps.MAX_DAMAGE_TEMPERATURE  = 1200
rps.MIN_COOLANT_FILL        = 0.10
rps.MAX_WASTE_FILL          = 0.95
rps.MAX_HEATED_COOLANT_FILL = 0.95
constants.RPS_LIMITS = rps
local annunc = {}
annunc.RCSFlowLow_H2O     = -3.2
annunc.RCSFlowLow_NA      = -2.0
annunc.CoolantLevelLow    = 0.4
annunc.OpTempTolerance    = 5
annunc.ReactorHighDeltaT  = 50
annunc.FuelLevelLow       = 0.05
annunc.WasteLevelHigh     = 0.80
annunc.WaterLevelLow      = 0.4
annunc.SteamFeedMismatch  = 10
annunc.SFM_MaxSteamDT_H20 = 2.0
annunc.SFM_MinWaterDT_H20 = -3.0
annunc.SFM_MaxSteamDT_NA  = 2.0
annunc.SFM_MinWaterDT_NA  = -2.0
annunc.RadiationWarning   = 0.00001
constants.ANNUNCIATOR_LIMITS = annunc
local alarms = {}
alarms.HIGH_WASTE     = 0.85
alarms.HIGH_RADIATION = 0.00005   -- 50 uSv/h, not yet damaging but this isn't good
alarms.CHARGE_HIGH      = 1.0
alarms.CHARGE_RE_ENABLE = 0.95
alarms.FAC_HIGH_RAD     = 0.00001
constants.ALARM_LIMITS = alarms
local rs = {}
rs.ENERGY_CHARGE_LOW  = 0.05
rs.ENERGY_CHARGE_HIGH = 0.95
rs.AUX_COOL_ENABLE    = 0.85
rs.AUX_COOL_DISABLE   = 1.00
constants.RS_THRESHOLDS = rs
constants.ENERGY_MISMATCH_TOL = 0.01
constants.PU_FALLBACK_MIN_TIME_MS = 3000
constants.FLOW_STABILITY_DELAY_MS = 10000
constants.LOW_RADIATION       = 0.00001
constants.HAZARD_RADIATION    = 0.00006
constants.HIGH_RADIATION      = 0.001
constants.VERY_HIGH_RADIATION = 0.1
constants.SEVERE_RADIATION    = 8.0
constants.EXTREME_RADIATION   = 100.0
constants.WARN_RTT = 300
constants.HIGH_RTT = 500
local mek = {}
mek.STANDARD_FE_PER_MB = 80000
mek.REF_TURBINE_FLOW   = 4896000
mek.REF_TURBINE_CAP    = 108416000
mek.BASE_BOIL_TEMP          = 373.15
mek.STEAM_ENERGY_EFF        = 0.2
mek.BOILER_CASING_HEAT_CAP  = 50
mek.SODIUM_CONDUCTIVITY     = 1
mek.SODIUM_THERMAL_ENTHALPY = 5
mek.WATER_THERMAL_ENTHALPY = 10
mek.JOULES_PER_MB          = 1000000
mek.TURBINE_GAS_PER_TANK   = 64000
mek.TURBINE_DISPERSER_FLOW = 1280
mek.TURBINE_VENT_FLOW      = 32000
constants.mek = mek
return constants
]=]):sub(2)),
["scada-common/log.lua"]=(([=[!
local util = require("scada-common.util")
local DBG_TAG, INF_TAG, WRN_TAG, ERR_TAG, FTL_TAG = "[DBG] ", "[INF] ", "[WRN] ", "[ERR] ", "[FTL] "
local COLON, FUNC, ARROW = ":", "():", " > "
local MIN_SPACE    = 2048
local OUT_OF_SPACE = "Out of space"
local TIME_FMT     = "%F %T "
local log = {}
local MODE = { APPEND = 0, NEW = 1 }
log.MODE = MODE
log.MIN_SPACE = MIN_SPACE
local _log = {
not_ready = true,
path = "/log.txt",
mode = MODE.APPEND,
debug = false,
file = nil,
dmesg_out = nil,
dmesg_restore_coord = { 1, 1 },
dmesg_scroll_count = 0
}
local free_space = fs.getFreeSpace
local function check_out_of_space(err_msg)
return (free_space(_log.path) < MIN_SPACE) or ((err_msg ~= nil) and (string.find(err_msg, OUT_OF_SPACE) ~= nil))
end
local function write_log(msg_bits)
if _log.not_ready then return end
local time_stamp = os.date(TIME_FMT)
local stamped    = util.c(time_stamp, table.unpack(msg_bits))
local status, result = pcall(function ()
_log.file.writeLine(stamped)
_log.file.flush()
end)
if check_out_of_space() then
_log.file.close()
fs.delete(_log.path)
log.init(_log.path, _log.mode, _log.debug, _log.dmesg_out)
_log.file.writeLine(time_stamp .. WRN_TAG .. "recycled log file")
_log.file.writeLine(stamped)
_log.file.flush()
elseif (not status) and (result ~= nil) then
util.println("unexpected error writing to the log file: " .. result)
end
end
function log.init(path, write_mode, include_debug, dmesg_redirect)
local err_msg
_log.path = path
_log.mode = write_mode
_log.debug = include_debug
_log.file, err_msg = fs.open(path, util.trinary(_log.mode == MODE.APPEND, "a", "w"))
if dmesg_redirect then
_log.dmesg_out = dmesg_redirect
else
_log.dmesg_out = term.current()
end
local out_of_space = check_out_of_space(err_msg)
if _log.file == nil or out_of_space then
if out_of_space then
if fs.exists(_log.path) then
fs.delete(_log.path)
_log.file, err_msg = fs.open(path, util.trinary(_log.mode == MODE.APPEND, "a", "w"))
if _log.file then
_log.file.writeLine(os.date(TIME_FMT) .. WRN_TAG .. "init recycled log file")
_log.file.flush()
else error("failed to setup the log file: " .. err_msg) end
else error("failed to make space for the log file, please delete unused files") end
else error("unexpected error setting up the log file: " .. err_msg) end
end
_log.not_ready = false
end
function log.close() _log.file.close() end
function log.direct_dmesg(window) _log.dmesg_out = window end
function log.dmesg(msg, tag, tag_color)
local ts_coord = { x1 = 2, x2 = 3, y = 1 }
msg = util.strval(msg)
tag = util.strval(tag or "")
local t_stamp = string.format("%12.2f", os.clock())
local out = _log.dmesg_out
if out ~= nil then
local out_w, out_h = out.getSize()
local lines = { msg }
if string.len(msg) > out_w then
local remaining = true
local s_start = 1
local s_end = out_w
local i = 1
lines = {}
while remaining do
local line = string.sub(msg, s_start, s_end)
if line == "" then
remaining = false
else
lines[i] = line
s_start = s_end + 1
s_end = s_end + out_w
i = i + 1
end
end
end
local cur_x, cur_y = out.getCursorPos()
if cur_x > 1 then
if cur_y == out_h then
out.scroll(1)
out.setCursorPos(1, cur_y)
_log.dmesg_scroll_count = _log.dmesg_scroll_count + 1
else
out.setCursorPos(1, cur_y + 1)
end
end
local initial_color = out.getTextColor()
out.setTextColor(colors.white)
out.write("[")
out.setTextColor(colors.lightGray)
out.write(t_stamp)
ts_coord.x2, ts_coord.y = out.getCursorPos()
ts_coord.x2 = ts_coord.x2 - 1
out.setTextColor(colors.white)
out.write("] ")
if tag ~= "" then
out.write("[")
if tag_color then out.setTextColor(tag_color) end
out.write(tag)
out.setTextColor(colors.white)
out.write("] ")
end
out.setTextColor(initial_color)
for i = 1, #lines do
cur_x, cur_y = out.getCursorPos()
if i > 1 and cur_x > 1 then
if cur_y == out_h then
out.scroll(1)
out.setCursorPos(1, cur_y)
_log.dmesg_scroll_count = _log.dmesg_scroll_count + 1
else
out.setCursorPos(1, cur_y + 1)
end
end
out.write(lines[i])
end
_log.dmesg_restore_coord = { out.getCursorPos() }
write_log{"[", t_stamp, "] [", tag, "] ", msg}
end
return ts_coord
end
function log.dmesg_working(msg, tag, tag_color)
local ts_coord = log.dmesg(msg, tag, tag_color)
local initial_scroll = _log.dmesg_scroll_count
local out = _log.dmesg_out
local width = (ts_coord.x2 - ts_coord.x1) + 1
if out ~= nil then
local initial_color = out.getTextColor()
local counter = 0
local function update(sec_remaining)
local new_y = ts_coord.y - (_log.dmesg_scroll_count - initial_scroll)
if new_y < 1 then return end
local time = util.sprintf("%ds", sec_remaining)
local available = width - (string.len(time) + 2)
local progress = ""
out.setCursorPos(ts_coord.x1, new_y)
out.write(" ")
if counter % 4 == 0 then
progress = "|"
elseif counter % 4 == 1 then
progress = "/"
elseif counter % 4 == 2 then
progress = "-"
elseif counter % 4 == 3 then
progress = "\\"
end
out.setTextColor(colors.blue)
out.write(progress)
out.setTextColor(colors.lightGray)
out.write(util.spaces(available) .. time)
out.setTextColor(initial_color)
counter = counter + 1
out.setCursorPos(table.unpack(_log.dmesg_restore_coord))
end
local function done(ok)
local new_y = ts_coord.y - (_log.dmesg_scroll_count - initial_scroll)
if new_y < 1 then return end
out.setCursorPos(ts_coord.x1, new_y)
if ok or ok == nil then
out.setTextColor(colors.green)
out.write(util.pad("DONE", width))
else
out.setTextColor(colors.red)
out.write(util.pad("FAIL", width))
end
out.setTextColor(initial_color)
out.setCursorPos(table.unpack(_log.dmesg_restore_coord))
end
return update, done
else
return function () end, function () end
end
end
function log.debug(msg, trace)
if _log.debug then
if trace then
local info = debug.getinfo(2)
if info.name ~= nil then
write_log{DBG_TAG, info.short_src, COLON, info.name, FUNC, info.currentline, ARROW, msg}
else
write_log{DBG_TAG, info.short_src, COLON, info.currentline, ARROW, msg}
end
else
write_log{DBG_TAG, msg}
end
end
end
function log.info(msg) write_log{INF_TAG, msg} end
function log.warning(msg) write_log{WRN_TAG, msg} end
function log.error(msg, trace)
if trace then
local info = debug.getinfo(2)
if info.name ~= nil then
write_log{ERR_TAG, info.short_src, COLON, info.name, FUNC, info.currentline, ARROW, msg}
else
write_log{ERR_TAG, info.short_src, COLON, info.currentline, ARROW, msg}
end
else
write_log{ERR_TAG, msg}
end
end
function log.fatal(msg) write_log{FTL_TAG, msg} end
return log
]=]):sub(2)),
["scada-common/network.lua"]=(([=[!
local comms  = require("scada-common.comms")
local log    = require("scada-common.log")
local ppm    = require("scada-common.ppm")
local util   = require("scada-common.util")
local md5    = require("lockbox.digest.md5")
local sha1   = require("lockbox.digest.sha1")
local pbkdf2 = require("lockbox.kdf.pbkdf2")
local hmac   = require("lockbox.mac.hmac")
local stream = require("lockbox.util.stream")
local array  = require("lockbox.util.array")
local LINK_TIMEOUT_MS          = 5000
local DISCOVERY_PERIOD_UP_MS   = 3000
local DISCOVERY_PERIOD_DOWN_MS = 500
local network = {}
local _crypt = {
key = nil,
hmac = nil
}
function network.init_mac(passkey)
local start = util.time_ms()
local key_deriv = pbkdf2()
key_deriv.setPRF(hmac().setBlockSize(64).setDigest(sha1))
key_deriv.setBlockLen(20)
key_deriv.setDKeyLen(20)
key_deriv.setIterations(256)
key_deriv.setSalt("pepper")
key_deriv.setPassword(passkey)
key_deriv.finish()
_crypt.key = array.fromHex(key_deriv.asHex())
_crypt.hmac = hmac()
_crypt.hmac.setBlockSize(64)
_crypt.hmac.setDigest(md5)
_crypt.hmac.setKey(_crypt.key)
local init_time = util.time_ms() - start
log.info("NET: network.init_mac() completed in " .. init_time .. "ms")
return init_time
end
function network.deinit_mac()
_crypt.key, _crypt.hmac = nil, nil
end
local function compute_hmac(message)
_crypt.hmac.init()
_crypt.hmac.update(stream.fromString(message))
_crypt.hmac.finish()
local hash = _crypt.hmac.asHex()
return hash
end
function network.nic(modem, lld_tx_chan)
local self = {
iface = "?",
name = "?",
use_hash = false,
phy_up = false,
link_up = false,
last_lld_rx = 0,
last_lld_tx = 0,
channels = {}
}
local function _send_ll_discovery_frame(dest_addr, r_chan, l_chan, ack)
if not self.phy_up then return end
local reply = comms.lld_frame()
reply.make(dest_addr, ack)
modem.transmit(r_chan, l_chan, reply.raw_frame())
end
local public = {}
function public.phy_name() return self.name end
function public.is_connected() return self.phy_up end
function public.is_network_up() return self.link_up end
function public.connect(reconnected_modem)
modem = reconnected_modem
self.iface    = ppm.get_iface(modem)
self.name     = util.c(util.trinary(modem.isWireless(), "WLAN_PHY", "ETH_PHY"), "{", self.iface, "}")
self.use_hash = _crypt.hmac and modem.isWireless()
self.phy_up   = true
self.link_up  = false
modem.closeAll()
for _, channel in ipairs(self.channels) do
modem.open(channel)
end
for key, func in pairs(modem) do
if key ~= "transmit" and key ~= "open" and key ~= "close" and key ~= "closeAll" then public[key] = func end
end
end
function public.disconnect()
self.phy_up  = false
self.link_up = false
end
function public.is_modem(device) return device == modem end
if modem then public.connect(modem) end
function public.open(channel)
if modem then modem.open(channel) end
local already_open = false
for i = 1, #self.channels do
if self.channels[i] == channel then
already_open = true
break
end
end
if not already_open then
table.insert(self.channels, channel)
end
end
function public.close(channel)
if modem then modem.close(channel) end
for i = 1, #self.channels do
if self.channels[i] == channel then
table.remove(self.channels, i)
return
end
end
end
function public.closeAll()
if modem then modem.closeAll() end
self.channels = {}
end
function public.transmit(dest_channel, local_channel, frame)
if self.phy_up then
local tx_frame = frame
if self.use_hash then
tx_frame = comms.authd_frame()
tx_frame.make(frame, compute_hmac)
end
modem.transmit(dest_channel, local_channel, tx_frame.raw_frame())
else
log.debug("NET: " .. self.name ..".transmit() tx dropped, phy is down")
end
end
function public.receive(side, sender, reply_to, message, distance)
local frame = nil
if self.phy_up and side == self.iface then
local s_frame = comms.scada_frame()
if self.use_hash then
local a_frame = comms.authd_frame()
if a_frame.receive(side, sender, reply_to, message, distance) then
if s_frame.receive(side, sender, reply_to, a_frame.data(), distance) then
local computed_hmac = compute_hmac(textutils.serialize(s_frame.raw_header(), { allow_repetitions = true, compact = true }))
if a_frame.mac() == computed_hmac then
s_frame.stamp_authenticated()
else
end
end
end
else
s_frame.receive(side, sender, reply_to, message, distance)
end
if s_frame.is_valid() then
self.link_up     = true
self.last_lld_rx = util.time_ms()
frame = s_frame
else
local l_frame = comms.lld_frame()
if l_frame.receive(side, sender, reply_to, message, distance) then
self.link_up     = true
self.last_lld_rx = util.time_ms()
if not l_frame.is_ack() then
_send_ll_discovery_frame(l_frame.src_addr(), l_frame.remote_channel(), l_frame.local_channel(), true)
end
end
end
end
return frame
end
function public.periodic()
local now = util.time_ms()
if now >= (self.last_lld_rx + LINK_TIMEOUT_MS) then
if self.link_up then log.debug("NET: " .. self.name ..".periodic(): link timeout") end
self.link_up = false
end
if lld_tx_chan and self.phy_up then
if (now - self.last_lld_tx) > util.trinary(self.link_up, DISCOVERY_PERIOD_UP_MS, DISCOVERY_PERIOD_DOWN_MS) then
self.last_lld_tx = now
for _, channel in ipairs(self.channels) do
_send_ll_discovery_frame(comms.BROADCAST, lld_tx_chan, channel, false)
end
end
end
return self.link_up
end
return public
end
return network
]=]):sub(2)),
["scada-common/ppm.lua"]=(([=[!
local log  = require("scada-common.log")
local util = require("scada-common.util")
local ppm = {}
local ACCESS_FAULT        = nil
local UNDEFINED_FIELD     = "__PPM_UNDEF_FIELD__"
local VIRTUAL_DEVICE_TYPE = "ppm_vdev"
ppm.ACCESS_FAULT          = ACCESS_FAULT
ppm.UNDEFINED_FIELD       = UNDEFINED_FIELD
ppm.VIRTUAL_DEVICE_TYPE   = VIRTUAL_DEVICE_TYPE
local REPORT_FREQUENCY = 20
local _ppm = {
mounts = {},
next_vid = 0,
auto_cf = false,
faulted = false,
last_fault = "",
terminate = false,
mute = false
}
local function peri_init(iface)
local self = {
faulted = false,
last_fault = "",
fault_counts = {},
auto_cf = true,
type = VIRTUAL_DEVICE_TYPE,
device = {}
}
if iface ~= "__virtual__" then
self.type = peripheral.getType(iface)
self.device = peripheral.wrap(iface)
end
local function protect_peri_function(key, func)
return function (...)
local return_table = table.pack(pcall(func, ...))
local status = return_table[1]
table.remove(return_table, 1)
if status then
if self.auto_cf then self.faulted = false end
if _ppm.auto_cf then _ppm.faulted = false end
self.fault_counts[key] = 0
return table.unpack(return_table)
else
local result = return_table[1]
self.faulted = true
self.last_fault = result
_ppm.faulted = true
_ppm.last_fault = result
if not _ppm.mute and (self.fault_counts[key] % REPORT_FREQUENCY == 0) then
local count_str = ""
if self.fault_counts[key] > 0 then
count_str = " [" .. self.fault_counts[key] .. " total faults]"
end
log.error(util.c("PPM: [@", iface, "] protected ", key, "() -> ", result, count_str))
end
self.fault_counts[key] = self.fault_counts[key] + 1
if result == "Terminated" then _ppm.terminate = true end
return ACCESS_FAULT, result
end
end
end
local function clear_fault() self.faulted = false end
local function get_last_fault() return self.last_fault end
local function is_faulted() return self.faulted end
local function is_ok() return not self.faulted end
local function is_healthy()
for _, v in pairs(self.fault_counts) do if v > 0 then return false end end
return true
end
local function enable_afc() self.auto_cf = true end
local function disable_afc() self.auto_cf = false end
self.device.__p_clear_fault = clear_fault
self.device.__p_last_fault  = get_last_fault
self.device.__p_is_faulted  = is_faulted
self.device.__p_is_ok       = is_ok
self.device.__p_is_healthy  = is_healthy
self.device.__p_enable_afc  = enable_afc
self.device.__p_disable_afc = disable_afc
local dev = self.device
dev.__p_clear_fault = clear_fault
dev.__p_last_fault  = get_last_fault
dev.__p_is_faulted  = is_faulted
dev.__p_is_ok       = is_ok
dev.__p_is_healthy  = is_healthy
dev.__p_enable_afc  = enable_afc
dev.__p_disable_afc = disable_afc
for key, func in pairs(self.device) do
self.fault_counts[key] = 0
self.device[key] = protect_peri_function(key, func)
end
local mt = {
__index = function (_, key)
local funcs = peripheral.wrap(iface)
if (type(funcs) == "table") and (type(funcs[key]) == "function") then
self.fault_counts[key] = 0
self.device[key] = protect_peri_function(key, funcs[key])
log.info(util.c("PPM: [@", iface, "] initialized previously undefined field ", key, "()"))
return self.device[key]
end
return (function ()
if self.fault_counts[key] == nil then self.fault_counts[key] = 0 end
self.faulted = true
self.last_fault = UNDEFINED_FIELD
_ppm.faulted = true
_ppm.last_fault = UNDEFINED_FIELD
if not _ppm.mute and (self.fault_counts[key] % REPORT_FREQUENCY == 0) then
local count_str = ""
if self.fault_counts[key] > 0 then
count_str = " [" .. self.fault_counts[key] .. " total calls]"
end
log.error(util.c("PPM: [@", iface, "] caught undefined function ", key, "()", count_str))
end
self.fault_counts[key] = self.fault_counts[key] + 1
return ACCESS_FAULT, UNDEFINED_FIELD
end)
end
}
setmetatable(self.device, mt)
local entry = { type = self.type, dev = self.device }
return entry
end
function ppm.disable_reporting() _ppm.mute = true end
function ppm.enable_reporting() _ppm.mute = false end
function ppm.enable_afc() _ppm.auto_cf = true end
function ppm.disable_afc() _ppm.auto_cf = false end
function ppm.clear_fault() _ppm.faulted = false end
function ppm.is_faulted() return _ppm.faulted end
function ppm.get_last_fault() return _ppm.last_fault end
function ppm.should_terminate() return _ppm.terminate end
function ppm.mount_all()
local ifaces = peripheral.getNames()
_ppm.mounts = {}
for i = 1, #ifaces do
_ppm.mounts[ifaces[i]] = peri_init(ifaces[i])
log.info(util.c("PPM: found a ", _ppm.mounts[ifaces[i]].type, " (", ifaces[i], ")"))
end
if #ifaces == 0 then
log.warning("PPM: mount_all() -> no devices found")
end
end
function ppm.mount(iface)
local ifaces = peripheral.getNames()
local pm_dev = nil
local pm_type = nil
for i = 1, #ifaces do
if iface == ifaces[i] then
_ppm.mounts[iface] = peri_init(iface)
pm_type = _ppm.mounts[iface].type
pm_dev = _ppm.mounts[iface].dev
log.info(util.c("PPM: mount(", iface, ") -> found a ", pm_type))
break
end
end
return pm_type, pm_dev
end
function ppm.remount(iface)
local ifaces = peripheral.getNames()
local pm_dev = nil
local pm_type = nil
for i = 1, #ifaces do
if iface == ifaces[i] then
log.info(util.c("PPM: remount(", iface, ") -> is a ", pm_type))
ppm.unmount(_ppm.mounts[iface].dev)
_ppm.mounts[iface] = peri_init(iface)
pm_type = _ppm.mounts[iface].type
pm_dev = _ppm.mounts[iface].dev
log.info(util.c("PPM: remount(", iface, ") -> remounted a ", pm_type))
break
end
end
return pm_type, pm_dev
end
function ppm.mount_virtual()
local iface = "ppm_vdev_" .. _ppm.next_vid
_ppm.mounts[iface] = peri_init("__virtual__")
_ppm.next_vid = _ppm.next_vid + 1
log.info(util.c("PPM: mount_virtual() -> allocated new virtual device ", iface))
return _ppm.mounts[iface].type, _ppm.mounts[iface].dev
end
function ppm.unmount(device)
if device then
for iface, data in pairs(_ppm.mounts) do
if data.dev == device then
log.warning(util.c("PPM: manually unmounted ", data.type, " mounted to ", iface))
_ppm.mounts[iface] = nil
break
end
end
end
end
function ppm.handle_unmount(iface)
local pm_dev = nil
local pm_type = nil
local lost_dev = _ppm.mounts[iface]
if lost_dev then
pm_type = lost_dev.type
pm_dev = lost_dev.dev
log.warning(util.c("PPM: lost device ", pm_type, " mounted to ", iface))
else
log.error(util.c("PPM: lost device unknown to the PPM mounted to ", iface))
end
_ppm.mounts[iface] = nil
return pm_type, pm_dev
end
function ppm.log_mounts()
for iface, mount in pairs(_ppm.mounts) do
log.info(util.c("PPM: had found a ", mount.type, " (", iface, ")"))
end
if util.table_len(_ppm.mounts) == 0 then
log.warning("PPM: no devices had been found")
end
end
function ppm.list_avail() return peripheral.getNames() end
function ppm.list_mounts()
local list = {}
for k, v in pairs(_ppm.mounts) do list[k] = v end
return list
end
function ppm.get_iface(device)
if device then
for iface, data in pairs(_ppm.mounts) do
if data.dev == device then return iface end
end
end
return nil
end
function ppm.get_periph(iface)
if _ppm.mounts[iface] then
return _ppm.mounts[iface].dev
else return nil end
end
function ppm.get_type(iface)
if _ppm.mounts[iface] then
return _ppm.mounts[iface].type
else return nil end
end
function ppm.get_all_devices(type)
local devices = {}
for _, data in pairs(_ppm.mounts) do
if data.type == type then
table.insert(devices, data.dev)
end
end
return devices
end
function ppm.get_device(type)
local device, d_iface = nil, nil
for iface, data in pairs(_ppm.mounts) do
if data.type == type then
device = data.dev
d_iface = iface
break
end
end
return device, d_iface
end
function ppm.get_fission_reactor()
local dev, iface = ppm.get_device("fissionReactorLogicAdapter")
return dev, iface
end
function ppm.get_modem(iface)
local modem  = nil
local device = _ppm.mounts[iface]
if device and device.type == "modem" then modem = device.dev end
return modem
end
function ppm.get_wireless_modem()
local w_modem, w_iface = nil, nil
local emulated_env = periphemu ~= nil
for iface, device in pairs(_ppm.mounts) do
if device.type == "modem" and (emulated_env or device.dev.isWireless()) then
w_modem = device.dev
w_iface = iface
break
end
end
return w_modem, w_iface
end
function ppm.get_wired_modem_list()
local list = {}
for iface, device in pairs(_ppm.mounts) do
if device.type == "modem" and not device.dev.isWireless() then list[iface] = device end
end
return list
end
function ppm.get_monitor_list()
local list = {}
for iface, device in pairs(_ppm.mounts) do
if device.type == "monitor" then list[iface] = device end
end
return list
end
function ppm.monitor_block_size(width, height)
return math.floor((width - 15) / 21) + 1, math.floor((height - 10) / 14) + 1
end
return ppm
]=]):sub(2)),
["scada-common/util.lua"]=(([=[!
local cc_strings = require("cc.strings")
local const      = require("scada-common.constants")
local math = math
local string = string
local table = table
local os = os
local getmetatable = getmetatable
local print = print
local tostring = tostring
local type = type
local t_concat = table.concat
local t_insert = table.insert
local t_pack   = table.pack
local util = {}
util.version = "1.10.4"
util.TICK_TIME_S = 0.05
util.TICK_TIME_MS = 50
function util.trinary(cond, a, b)
if cond then return a else return b end
end
local p_time = "[%H:%M:%S] "
function util.print(message) term.write(tostring(message)) end
function util.println(message) print(tostring(message)) end
function util.print_ts(message) term.write(os.date(p_time) .. tostring(message)) end
function util.println_ts(message) print(os.date(p_time) .. tostring(message)) end
function util.strval(val)
local t = type(val)
if t == "string" then return val end
if (t == "table" and (getmetatable(val) == nil or getmetatable(val).__tostring == nil)) or t == "function" then
return t_concat{"[", tostring(val), "]"}
else return tostring(val) end
end
function util.strtok(str, sep)
local list = {}
for part in string.gmatch(str, "([^" .. sep .. "]+)") do t_insert(list, part) end
return list
end
function util.spaces(n) return string.rep(" ", n) end
function util.pad(str, n)
local len = string.len(str)
local lpad = math.floor((n - len) / 2)
local rpad = (n - len) - lpad
return t_concat{util.spaces(lpad), str, util.spaces(rpad)}
end
function util.trim(s)
local str = s:gsub("^%s*(.-)%s*$", "%1")
return str
end
function util.strwrap(str, limit)
assert(limit > 0, "util.strwrap() limit not greater than 0")
return cc_strings.wrap(str, limit)
end
function util.strminw(str, width) return cc_strings.ensure_width(str, width) end
function util.concat(...)
local args, strings = t_pack(...), {}
for i = 1, args.n do strings[i] = util.strval(args[i]) end
return t_concat(strings)
end
util.c = util.concat
function util.sprintf(format, ...) return string.format(format, ...) end
function util.comma_format(num)
local formatted = num
local commas = 0
local i = 1
while i > 0 do
formatted, i = formatted:gsub("^(%s-%d+)(%d%d%d)", "%1,%2")
if i > 0 then commas = commas + 1 end
end
local _, num_spaces = formatted:gsub(" %s-", "")
local remove = math.min(num_spaces, commas)
formatted = string.sub(formatted, remove + 1)
return formatted
end
function util.is_int(x) return type(x) == "number" and x == math.floor(x) end
function util.sign(x) return util.trinary(x < 0, -1, 1) end
function util.round(x) return math.floor(x + 0.5) end
function util.mov_avg(length)
local data = {}
local index = 1
local last_t = 0
local public = {}
function public.reset(x)
index = 1
data = {}
if x then
for _ = 1, length do t_insert(data, x) end
end
end
function public.record(x, t)
if type(t) == "number" and last_t == t then return end
data[index] = x
last_t = t
index = index + 1
if index > length then index = 1 end
end
function public.compute()
if #data == 0 then return 0 end
local sum = 0
for i = 1, #data do
sum = sum + data[i]
end
return sum / #data
end
return public
end
function util.ema_filter(alpha)
local state = nil
local last_t = 0
local public = {}
function public.reset(x) state = x end
function public.update(x, t)
if type(t) == "number" and last_t == t then return end
if state then
state = state + (alpha * (x - state))
else state = x end
last_t = t
end
function public.get() return state or 0.0 end
return public
end
function util.time_ms() return os.epoch("local") end
function util.time_s() return os.epoch("local") / 1000.0 end
function util.time() return util.time_ms() end
function util.get_tps()
local t_start = util.time_ms()
util.nop()
local t_end = util.time_ms()
return 1000 / (t_end - t_start)
end
function util.pull_event(target_event) return os.pullEventRaw(target_event) end
function util.push_event(event, param1, param2, param3, param4, param5)
return os.queueEvent(event, param1, param2, param3, param4, param5)
end
function util.start_timer(t) return os.startTimer(t) end
function util.cancel_timer(timer) os.cancelTimer(timer) end
function util.psleep(t) return pcall(os.sleep, t) end
function util.nop() util.psleep(0.05) end
function util.adaptive_delay(target_timing, last_update)
local sleep_for = target_timing - (util.time() - last_update)
if sleep_for >= 50 then util.psleep(sleep_for / 1000.0) end
return util.time()
end
function util.filter_table(t, f, on_delete)
local move_to = 1
for i = 1, #t do
local element = t[i]
if element ~= nil then
if f(element) then
if t[move_to] == nil then
t[move_to] = element
t[i] = nil
end
move_to = move_to + 1
else
if on_delete then on_delete(element) end
t[i] = nil
end
end
end
end
function util.table_contains(t, element)
for i = 1, #t do
if t[i] == element then return true end
end
return false
end
function util.table_len(t)
local n = 0
for _, _ in pairs(t) do n = n + 1 end
return n
end
function util.joules_to_fe_rf(J) return (J * 0.4) end
function util.fe_rf_to_joules(FE) return (FE * 2.5) end
function util.power_format(e, label, combine_label, format)
local unit, value
if type(format) ~= "string" then format = "%.2f" end
local a = math.abs(e)
if a < 1000.0 then
unit = ""
value = e
elseif a < 1000000.0 then
unit = "k"
value = e / 1000.0
elseif a < 1000000000.0 then
unit = "M"
value = e / 1000000.0
elseif a < 1000000000000.0 then
unit = "G"
value = e / 1000000000.0
elseif a < 1000000000000000.0 then
unit = "T"
value = e / 1000000000000.0
elseif a < 1000000000000000000.0 then
unit = "P"
value = e / 1000000000000000.0
elseif a < 1000000000000000000000.0 then
unit = "E"
value = e / 1000000000000000000.0
else
unit = "Z"
value = e / 1000000000000000000000.0
end
unit = unit .. label
if combine_label then
return util.sprintf(util.c(format, " %s"), value, unit), unit
else
return util.sprintf(format, value), unit
end
end
function util.turbine_rotation(turbine)
local build = turbine.build
local inner_vol = build.steam_cap / const.mek.TURBINE_GAS_PER_TANK
local disp_rate = (build.dispersers * const.mek.TURBINE_DISPERSER_FLOW) * inner_vol
local vent_rate = build.vents * const.mek.TURBINE_VENT_FLOW
local max_rate = math.min(disp_rate, vent_rate)
local flow = math.min(max_rate, turbine.tanks.steam.amount)
return (flow * (turbine.tanks.steam.amount / build.steam_cap)) / max_rate
end
function util.new_watchdog(timeout)
local self = { timeout = timeout, wd_timer = util.start_timer(timeout) }
local public = {}
function public.is_timer(timer) return self.wd_timer == timer end
function public.feed()
public.cancel()
self.wd_timer = util.start_timer(self.timeout)
end
function public.cancel()
if self.wd_timer ~= nil then util.cancel_timer(self.wd_timer) end
end
return public
end
function util.new_clock(period)
local self = { period = period, timer = nil }
local public = {}
function public.is_clock(timer) return self.timer == timer end
function public.start() self.timer = util.start_timer(self.period) end
return public
end
function util.new_validator()
local valid = true
local public = {}
function public.assert_type_bool(value) valid = valid and type(value) == "boolean" end
function public.assert_type_num(value) valid = valid and type(value) == "number" end
function public.assert_type_int(value) valid = valid and util.is_int(value) end
function public.assert_type_str(value) valid = valid and type(value) == "string" end
function public.assert_type_table(value) valid = valid and type(value) == "table" end
function public.assert(check) valid = valid and (check == true) end
function public.assert_eq(check, expect) valid = valid and check == expect end
function public.assert_min(check, min) valid = valid and check >= min end
function public.assert_min_ex(check, min) valid = valid and check > min end
function public.assert_max(check, max) valid = valid and check <= max end
function public.assert_max_ex(check, max) valid = valid and check < max end
function public.assert_range(check, min, max) valid = valid and check >= min and check <= max end
function public.assert_range_ex(check, min, max) valid = valid and check > min and check < max end
function public.assert_channel(channel) valid = valid and util.is_int(channel) and channel >= 0 and channel <= 65535 end
function public.valid() return valid end
return public
end
return util
]=]):sub(2)),
["startup.lua"]=(([=[!return shell.run("/fusion/startup")
]=]):sub(2)),
}
local BUNDLE = {
agent={
{path="fusion/model.lua",hash="fd9ad42695b3d6565b2fd067db2f313556a256a98638b8c4842e7c490998e6e2",allowed={}},
{path="fusion/config.lua",hash="c256c796aaa1dd6d07ddc9ef1b7efe3913696569d703c6732831104ab477b266",allowed={}},
{path="fusion/configure.lua",hash="11cf505560dd4a06fa03334c950b9326ab33258007449b8ac9c242a6d4cec8cd",allowed={}},
{path="fusion/startup.lua",hash="7b3e9f25f027e46e4c5ed13283d704353b005c81e4b8869e6e40d838b30ed206",allowed={}},
{path="startup.lua",hash="ba3004ec42152d6a44d55f1024ea194b1c81cab44bf66f4c9aea1ecdf18393f7",allowed={}},
{path="scada-common/constants.lua",hash="4a1048b19e7095b1930dffc96f5b3d06f8434537aa240930a4f73bbff61d33a8",allowed={}},
{path="scada-common/util.lua",hash="9bfd772caa6fe30af46b772a19ae30719a8eaf9af97237ba9808ca68400cfc73",allowed={}},
{path="scada-common/log.lua",hash="b5ac936995c7321d2007511eb7cb1afc5614661d515d8b853be22bee0f6ab1fd",allowed={}},
{path="scada-common/ppm.lua",hash="0088b7de4f819d49a48f7fece7e9a0efa21d25f48dd333379498aaa040e73106",allowed={}},
{path="scada-common/comms.lua",hash="404ec7b64d71374702f3ccfe668992dba77bc0e3bd325be6a65fcf18cb1cdd49",allowed={}},
{path="scada-common/network.lua",hash="eb50f4bb86eea1c04eb986024f6aa26468c5f1a74be88d80f1723ecaa3559841",allowed={}},
{path="lockbox/init.lua",hash="ddb5c9c2a4fd820a976e7493c71c2bf0a43786abd98839dc154ddb1995fc81f1",allowed={}},
{path="lockbox/util/bit.lua",hash="6762080b9e5e7a857ed6ffeedf3ef257f1af4d141af9fe3a4d8381593f38e17c",allowed={}},
{path="lockbox/util/queue.lua",hash="58eb1ec721cdf0193ab0255f25079e7a761794ed4160cca973e71c1326aa45e6",allowed={}},
{path="lockbox/util/stream.lua",hash="59d7705290ed92ab64615bca8795ee187b46a8ae5198318e1f19c894fc85cf4a",allowed={}},
{path="lockbox/util/array.lua",hash="c574cb8888231090bcb56dfdd70954a07c178e2b486d788d986813ac237f32b5",allowed={}},
{path="lockbox/digest/md5.lua",hash="3851258294aff07bb78bb3649477246e2d03dd495acc92751bac03748d2a6967",allowed={}},
{path="lockbox/digest/sha1.lua",hash="c0fa63938a21db44bd4cfed9d667d9413b05d652117692258e2c33ca3907adac",allowed={}},
{path="lockbox/digest/sha2_256.lua",hash="c62566f0a2fdc8d51019c14b54903dd7de29f64d578236ef5334d568f93f3417",allowed={}},
{path="lockbox/mac/hmac.lua",hash="e19212ff0ad739b953aa30e2a0ca6531c0d53c0724d25a1a6fa52e08aaf4bff8",allowed={}},
{path="lockbox/kdf/pbkdf2.lua",hash="3e96871872e279df4a784660fa76394f5816a13bcc089a6a43c5dac12577473e",allowed={}}
},
coordinator={
{path="fusion/model.lua",hash="fd9ad42695b3d6565b2fd067db2f313556a256a98638b8c4842e7c490998e6e2",allowed={}},
{path="fusion/config.lua",hash="c256c796aaa1dd6d07ddc9ef1b7efe3913696569d703c6732831104ab477b266",allowed={}},
{path="fusion/configure.lua",hash="11cf505560dd4a06fa03334c950b9326ab33258007449b8ac9c242a6d4cec8cd",allowed={}},
{path="fusion/view.lua",hash="5e231f41053dd43882fc9f3dae43c099cf11e54b2c7b6bbd9a218beb74253739",allowed={}},
{path="coordinator/fusion.lua",hash="080344cddbff571e3c52aed1566a5630de9baf9c6d39dc0019014978ac11369d",allowed={}},
{path="coordinator/ui/components/fusion_overview.lua",hash="051cbc1e5e20ff0e99dbfb240be87cee7bdfb2425e6ca77d7e0a3b991cb814aa",allowed={}},
{path="coordinator/threads.lua",hash="df7a4bf936c01467dc67aa2c0b26e6ce78a2144d206b185cf2d25bb2c48aba9c",allowed={"6fc2db022d6f371f8badf08e81678eaaeb8d4a41ce9d4783aa804b0ea413042e","b7cf1496f9ba52389f9f1a2f712660c1d57a16b9da4e934e37554a502867722c"}},
{path="coordinator/ui/layout/main_view.lua",hash="1e3ff65647ca93f01c2f069c566984fbeb653cfb8084c587113e7048beba24d0",allowed={"7c3ad00b43f0df24e853dd9bfe7a76ed2c2e26d1da46c9e265eb868886845b10","2e82b3ca43bdc7acbf4251a7930256f9ebd3d4fa15e7e585644359c7f6f9261f"}}
},
}

local args = {...}
local command,role = args[1] or "check",args[2]
if command == "agent" or command == "coordinator" then role,command=command,"install" end
role = role or (fs.exists("/coordinator/startup.lua") and "coordinator" or "agent")
assert(role == "agent" or role == "coordinator", "Specify agent or coordinator")
local rows = BUNDLE[role]
local root = "/.scada-fusion-1/" .. role
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
    print("Fusion monitoring restored to its pre-install state. Settings preserved.")
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
    if not fs.exists(root.."/complete") then fail("Interrupted installation. Run install-fusion recover "..role.." first.") end
    for _,row in ipairs(rows) do
        if not fs.exists("/"..row.path) or file_hash("/"..row.path) ~= row.hash then
            fail("Installed fusion file changed: "..row.path..". Keep the backup for undo.")
        end
    end
    print("Fusion monitoring is already installed.")
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
write_file(root.."/complete","fusion-monitoring-1\n")
print("Installed fusion monitoring. Backup: "..root)
print("Next: fusion/configure "..role)
