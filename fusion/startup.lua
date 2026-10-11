-- Fusion telemetry agent: reads getters and sends status, with no actuator path.
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
