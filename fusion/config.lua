local config = { PATH = "/fusion/settings.json", DEFAULT_CHANNEL = 16245 }
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
