local model = require("fusion.model")
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
