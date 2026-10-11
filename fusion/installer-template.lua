-- Recovery-capable SCADA fusion monitoring installer. Stop the Coordinator first.
--@@BUNDLE@@
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
