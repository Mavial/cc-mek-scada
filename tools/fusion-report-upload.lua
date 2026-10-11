-- Upload an existing commissioning report; never accesses reactor peripherals.
-- Usage: fusion-report-upload [fusion-probe.txt]

local args = { ... }
local path = args[1] or "fusion-probe.txt"
local endpoint = "https://paste.rs/"

if not http then error("HTTP is disabled on this server.", 0) end
if not fs.exists(path) or fs.isDir(path) then
    error("Report not found: " .. path .. ". Run fusion-probe first.", 0)
end
if fs.getSize(path) > 256 * 1024 then error("Report exceeds 256 KiB.", 0) end

local file = assert(fs.open(path, "r"), "Cannot read report: " .. path)
local contents = file.readAll()
file.close()
local report = textutils.unserialize(contents)
if type(report) ~= "table" or report.schema ~= 1 or type(report.peripherals) ~= "table" then
    error("This file is not a fusion commissioning report.", 0)
end

print("Uploading diagnostic report to paste.rs...")
local response, reason, error_response = http.post(endpoint, contents, {
    ["Content-Type"] = "text/plain; charset=utf-8"
})
local handle = response or error_response
if not handle then error("Upload failed: " .. tostring(reason), 0) end

local status = handle.getResponseCode()
local body = handle.readAll()
handle.close()
if status ~= 201 then
    error("Upload failed (HTTP " .. tostring(status) .. "): " .. body:sub(1, 200), 0)
end

local url = body:match("^%s*(https://paste%.rs/[A-Za-z0-9]+)%s*$")
if not url then error("Unexpected upload response: " .. body:sub(1, 200), 0) end
print("Uploaded as " .. url)
print("Send that link to Codex.")
