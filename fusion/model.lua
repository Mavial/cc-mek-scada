-- Read-only fusion telemetry. All peripheral access goes through a getter list.
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
            -- Read only the known single chemical tank in Mekanism's item component.
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

-- Copy known fields only; never retain or execute incoming objects.
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
