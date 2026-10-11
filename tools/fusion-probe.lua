-- Read-only commissioning probe for the fusion facility integration.
-- Import onto a CC:Tweaked computer sharing the fusion plant's wired network.
-- Calls an explicit getter whitelist. It never calls setters, transfers items,
-- emits redstone, sends packets, changes settings, or fires the laser.

local args = { ... }
local destination = args[1] or "fusion-probe.txt"
if fs.exists(destination) then
    error("Report already exists: " .. destination .. ". Choose another filename.", 0)
end

local readers = {
    "isFormed", "isIgnited", "getPlasmaTemperature", "getCaseTemperature",
    "getInjectionRate", "getDTFuel", "getDTFuelCapacity", "getDeuterium",
    "getTritium", "getHohlraum", "getProductionRate", "getEnergy",
    "getMaxEnergy", "getEnergyFilledPercentage", "getStored", "getCapacity",
    "getFilledPercentage", "getInput", "getOutput", "getLastInput",
    "getLastOutput", "getTransferCap", "getRedstoneMode", "getDirection",
    "getConfigurableTypes", "getDumpingMode", "getDelay", "getMinThreshold",
    "getMaxThreshold", "getRedstoneOutputMode", "getEnergyUsage"
}

local report = {
    schema = 1,
    computer_id = os.getComputerID(),
    utc_ms = os.epoch("utc"),
    peripherals = {}
}
local counts = { fusion = 0, ports = 0, laser = 0, tanks = 0, matrix = 0 }
local names = peripheral.getNames()
table.sort(names)

local function invoke(name, method, ...)
    local result = table.pack(pcall(peripheral.call, name, method, ...))
    if not result[1] then return { ok = false, error = tostring(result[2]) } end
    local values = {}
    for i = 2, result.n do values[i - 1] = result[i] end
    return { ok = true, values = values }
end

local function display(value)
    if type(value) == "table" then return textutils.serialize(value, { compact = true }) end
    return tostring(value)
end

print("Fusion facility commissioning probe")
print("Computer " .. report.computer_id)
for _, name in ipairs(names) do
    local types = table.pack(peripheral.getType(name))
    local type_list, relevant = {}, false
    for i = 1, types.n do
        local kind = tostring(types[i])
        type_list[#type_list + 1] = kind
        local lower = kind:lower()
        if lower:find("fusion", 1, true) or lower:find("chemicaltank", 1, true)
            or lower:find("laseramplifier", 1, true) or lower:find("chemicalinfuser", 1, true)
            or lower:find("inductionport", 1, true) or lower:find("resistiveheater", 1, true)
            or lower:find("redstone_relay", 1, true) then relevant = true end
    end
    local entry = { name = name, types = type_list }
    report.peripherals[#report.peripherals + 1] = entry
    if relevant then
        local method_list = peripheral.getMethods(name) or {}
        table.sort(method_list)
        entry.methods, entry.readings = method_list, {}
        local available = {}
        for _, method in ipairs(method_list) do available[method] = true end
        for _, method in ipairs(readers) do
            if available[method] then entry.readings[method] = invoke(name, method) end
        end
        if available.getIgnitionTemperature then
            entry.readings.getIgnitionTemperature = invoke(name, "getIgnitionTemperature", false)
        end
        if available.getSupportedModes then
            entry.readings.chemical_modes = invoke(name, "getSupportedModes", "CHEMICAL")
        end
        if available.getMode then
            entry.readings.chemical_sides = {}
            for _, side in ipairs({ "FRONT", "BACK", "LEFT", "RIGHT", "TOP", "BOTTOM" }) do
                entry.readings.chemical_sides[side] = invoke(name, "getMode", "CHEMICAL", side)
            end
        end
        local kind = table.concat(type_list, ","):lower()
        if kind:find("fusionreactorlogicadapter", 1, true) then counts.fusion = counts.fusion + 1 end
        if kind:find("fusionreactorport", 1, true) then counts.ports = counts.ports + 1 end
        if kind:find("laseramplifier", 1, true) then counts.laser = counts.laser + 1 end
        if kind:find("chemicaltank", 1, true) then counts.tanks = counts.tanks + 1 end
        if kind:find("inductionport", 1, true) then counts.matrix = counts.matrix + 1 end
        print(name .. " [" .. table.concat(type_list, ", ") .. "]")
        for _, method in ipairs({ "isIgnited", "getProductionRate", "getDTFuel", "getStored", "getEnergy", "getMaxEnergy", "getMinThreshold" }) do
            local reading = entry.readings[method]
            if reading then
                print(" " .. method .. " = " .. (reading.ok and display(reading.values[1]) or "ERROR"))
            end
        end
    end
end

local file = assert(fs.open(destination, "w"), "Cannot create report: " .. destination)
file.write(textutils.serialize(report))
file.close()
print("Found: " .. counts.fusion .. " fusion adapters, " .. counts.ports .. " ports")
print(counts.laser .. " amplifiers, " .. counts.tanks .. " tanks, " .. counts.matrix .. " matrices")
print("Report: " .. destination)
if counts.fusion == 0 then
    print("Connect/share a Fusion Reactor Logic Adapter on this wired network.")
end
