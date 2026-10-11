package.path = "/?.lua;/?/init.lua;" .. package.path
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
