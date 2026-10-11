-- Optional read-only fusion extension; independent of fission control sessions.
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
    -- The NIC retains this channel across modem reconnects; registering is idempotent.
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
