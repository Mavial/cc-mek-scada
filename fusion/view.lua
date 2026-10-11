-- Fusion detail display built from the Coordinator's native SCADA graphics.
local model = require("fusion.model")
local util = require("scada-common.util")
local style = require("coordinator.ui.style")
local core = require("graphics.core")
local DisplayBox = require("graphics.elements.DisplayBox")
local Rectangle = require("graphics.elements.Rectangle")
local TextBox = require("graphics.elements.TextBox")
local DataIndicator = require("graphics.elements.indicators.DataIndicator")
local PowerIndicator = require("graphics.elements.indicators.PowerIndicator")
local IndicatorLight = require("graphics.elements.indicators.IndicatorLight")
local StateIndicator = require("graphics.elements.indicators.StateIndicator")
local HorizontalBar = require("graphics.elements.indicators.HorizontalBar")

local view, cached = {}, nil
local cpair, ALIGN = core.cpair, core.ALIGN
local function numeric(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function bounded(text, width)
    text = tostring(text)
    return #text <= width and text or text:sub(1, width - 3) .. "..."
end

function view.reset()
    if cached then cached.root.hide() end
    cached = nil
end

local function create(monitor, context, width, height)
    for _, entry in ipairs(style.theme.colors) do monitor.setPaletteColor(entry.c, entry.hex) end
    for _, entry in ipairs(style.theme.color_modes[context.color_mode or 1] or {}) do
        monitor.setPaletteColor(entry.c, entry.hex)
    end
    local ui = {key=context.name or monitor,width=width,height=height,theme=style.theme,
        color_mode=context.color_mode,energy_label=context.energy_label,temp_label=context.temp_label}
    ui.root = DisplayBox{window=monitor,fg_bg=style.root}
    local root = ui.root
    local panel_width = math.floor((width - 5) / 2)
    local right = panel_width + 4
    local field = style.theme.field_box
    local function text(parent, x, y, w, value, colors_pair, alignment)
        return TextBox{parent=parent,x=x,y=y,width=w,height=1,text=bounded(value,w),
            fg_bg=colors_pair or style.label,alignment=alignment or ALIGN.LEFT}
    end
    local function panel(x, y, h, title, accent)
        local header = accent and cpair(colors.black,accent) or style.theme.header
        text(root,x,y,panel_width,title,header,ALIGN.CENTER)
        return Rectangle{parent=root,x=x,y=y+1,width=panel_width,height=h-1,
            border=core.border(1,accent or colors.gray,true),thin=true}
    end
    -- Unknown values have their own field, rather than masquerading as zero.
    local function value(parent, x, y, w, indicator, format, unit)
        local unknown = text(parent,x,y,w,"--",field,ALIGN.RIGHT)
        indicator.hide()
        return function(v)
            local rendered = numeric(v) and format(v) or nil
            if rendered and #rendered <= w then
                unknown.hide()
                indicator.update(v)
                indicator.show(false)
            else
                indicator.hide()
                unknown.set_value(rendered and bounded(string.format("%.3e %s",v,unit),w) or "--")
                unknown.show(false)
            end
        end
    end
    local function power(parent, y, label, rate)
        text(parent,2,y,11,label)
        local w = panel_width - 17
        local indicator = PowerIndicator{parent=parent,x=13,y=y,width=w,label="",value=0,
            format="%10.2f",unit=context.energy_label,rate=rate,lu_colors=style.lu_colors,fg_bg=field}
        local update = value(parent,13,y,w,indicator,function(v)
            local number, unit = util.power_format(v,context.energy_label,false,"%10.2f")
            unit = util.strminw(unit .. (rate and "/t" or ""),5)
            return util.comma_format(number) .. " " .. unit
        end,context.energy_label .. (rate and "/t" or ""))
        return function(v) update(v ~= nil and context.energy_convert(v) or nil) end
    end
    local function bar(parent, y, color)
        local w = panel_width - 6
        local gauge = HorizontalBar{parent=parent,x=2,y=y,width=w,height=1,show_percent=true,
            fg_bg=style.text_colors,bar_fg_bg=cpair(color,style.ind_bkg)}
        local unknown = text(parent,2,y,w,"--",style.theme.highlight_box,ALIGN.CENTER)
        gauge.hide()
        return function(amount, capacity)
            if numeric(amount) and numeric(capacity) and capacity > 0 then
                unknown.hide()
                gauge.update(amount/capacity)
                gauge.show(false)
            else
                gauge.hide()
                unknown.show(false)
            end
        end
    end
    text(root,1,1,width,"Fusion Reactor",style.theme.header,ALIGN.CENTER)
    local status_box = Rectangle{parent=root,x=2,y=3,width=panel_width,height=4,
        border=core.border(1,colors.gray,true),thin=true}
    local states = {}
    for _, def in ipairs({{"NO LIVE DATA",colors.red},{"READ ERROR",colors.orange},
        {"UNFORMED",colors.orange},{"IDLE",colors.gray},{"RUNNING",style.ind_grn.fgd},
        {"IDLE / PARTIAL DATA",colors.orange},{"RUNNING / PARTIAL DATA",colors.orange}}) do
        states[#states+1] = {text=def[1],color=cpair(def[2] == colors.gray and colors.white or colors.black,def[2])}
    end
    ui.state = StateIndicator{parent=status_box,x=1,y=1,min_width=panel_width-2,states=states,value=1}
    text(status_box,1,2,panel_width-2,"Read-only reactor telemetry",style.label,ALIGN.CENTER)
    local link_box = Rectangle{parent=root,x=right,y=3,width=panel_width,height=4,
        border=core.border(1,colors.gray,true),thin=true}
    ui.live = IndicatorLight{parent=link_box,x=2,y=1,label="Link Online",colors=style.ind_grn}
    ui.formed = IndicatorLight{parent=link_box,x=20,y=1,label="Formed",colors=style.ind_grn}
    ui.link = text(link_box,2,2,17,"Source -- / --",style.label)
    ui.fault = IndicatorLight{parent=link_box,x=20,y=2,label="Read Fault",colors=style.ind_yel}

    local reactor = panel(2,8,10,"FUSION CORE",colors.cyan)
    local function temperature(y,label)
        text(reactor,2,y,panel_width-6,label)
        local w = panel_width-6
        local indicator = DataIndicator{parent=reactor,x=2,y=y+1,width=w,label="",value=0,
            format="%26.2f",unit=context.temp_label,commas=true,lu_colors=style.lu_colors,fg_bg=field}
        local update = value(reactor,2,y+1,w,indicator,function(v)
            return util.comma_format(string.format("%26.2f",v)) .. " " .. context.temp_label
        end,context.temp_label)
        return function(v) update(v ~= nil and context.temp_convert(v) or nil) end
    end
    ui.plasma = temperature(1,"Plasma Temperature")
    ui.casing = temperature(4,"Casing Temperature")
    text(reactor,2,7,panel_width-6,"Measured reactor temperatures",style.label,ALIGN.CENTER)

    local generation = panel(right,8,10,"POWER GENERATION")
    ui.fusion = power(generation,1,"Fusion",true)
    ui.fission = power(generation,3,"Fission",true)
    ui.total = power(generation,5,"Total",true)
    text(generation,2,7,panel_width-6,"Total generator output",style.label,ALIGN.CENTER)

    local fuel = panel(2,19,17,"FUEL TANKS",colors.brown)
    ui.tanks = {}
    for i, def in ipairs({{"Premixed D-T","dt",colors.purple},{"Deuterium","deuterium",colors.lightBlue},
        {"Tritium","tritium",colors.cyan}}) do
        local y = 1+(i-1)*4
        text(fuel,2,y,14,def[1])
        local amount = text(fuel,17,y,panel_width-21,"--",field,ALIGN.RIGHT)
        local gauge = bar(fuel,y+1,def[3])
        ui.tanks[i] = function(data)
            local current,capacity = data[def[2]],data[def[2].."_capacity"]
            amount.set_value(current ~= nil and capacity ~= nil and
                bounded(string.format("%.0f / %.0f mB",current,capacity),panel_width-21) or "--")
            gauge(current,capacity)
        end
    end
    text(fuel,2,13,17,"Injection setting")
    ui.injection = text(fuel,20,13,panel_width-24,"--",field,ALIGN.RIGHT)
    text(fuel,2,14,panel_width-6,"Injection applies to D/T feeds",style.label,ALIGN.CENTER)

    local buffer = panel(2,37,12,"REACTOR ENERGY BUFFER",colors.blue)
    ui.buffer = power(buffer,1,"Stored",false)
    ui.buffer_cap = power(buffer,3,"Capacity",false)
    text(buffer,2,5,panel_width-6,"Buffer Fill")
    ui.buffer_fill = bar(buffer,6,colors.blue)
    text(buffer,2,8,panel_width-6,"Direct electrical generation",style.label,ALIGN.CENTER)

    local laser = panel(right,19,30,"LASER AND IGNITION",colors.purple)
    ui.laser = power(laser,1,"Stored",false)
    ui.laser_cap = power(laser,3,"Capacity",false)
    ui.laser_min = power(laser,5,"Minimum",false)
    ui.laser_max = power(laser,7,"Maximum",false)
    text(laser,2,9,panel_width-6,"Charge to Minimum Threshold")
    ui.charge = bar(laser,10,colors.purple)
    ui.threshold = StateIndicator{parent=laser,x=2,y=13,min_width=panel_width-6,value=1,states={
        {text="UNKNOWN",color=cpair(style.theme.text,style.ind_bkg)},
        {text="BELOW THRESHOLD",color=cpair(colors.black,colors.yellow)},
        {text="THRESHOLD REACHED",color=cpair(colors.black,style.ind_grn.fgd)}}}
    text(laser,2,16,14,"Redstone Mode")
    ui.laser_mode = text(laser,17,16,panel_width-21,"--",field,ALIGN.RIGHT)
    ui.hohlraum = IndicatorLight{parent=laser,x=2,y=19,label="Hohlraum Loaded",colors=style.ind_grn}
    text(laser,2,21,11,"Fuel Charge")
    ui.charge_text = text(laser,13,21,panel_width-17,"--",field,ALIGN.RIGHT)
    text(laser,2,24,panel_width-6,"Laser threshold is an energy",style.label,ALIGN.CENTER)
    text(laser,2,25,panel_width-6,"reading; ignition is separate.",style.label,ALIGN.CENTER)
    ui.notice = text(root,2,50,width-3,"Waiting for telemetry",style.label)
    text(root,1,52,width,"READ-ONLY MONITORING",style.theme.header,ALIGN.CENTER)
    return ui
end

function view.draw(monitor, data, context)
    monitor.setTextScale(0.5)
    local width,height = monitor.getSize()
    if width < 79 or height < 52 then
        view.reset()
        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.red)
        monitor.clear()
        monitor.setCursorPos(1,1)
        monitor.write("Fusion display needs a 4x4 Advanced Monitor.")
        return
    end
    if not cached or cached.key ~= (context.name or monitor) or cached.width ~= width or cached.height ~= height
        or cached.theme ~= style.theme or cached.color_mode ~= context.color_mode
        or cached.energy_label ~= context.energy_label or cached.temp_label ~= context.temp_label then
        view.reset()
        cached = create(monitor,context,width,height)
    end
    local ui = cached
    local status = model.status(data)
    local state = { ["NO LIVE DATA"]=1,["READ ERROR"]=2,["UNFORMED"]=3,["IDLE"]=4,
        ["RUNNING"]=5,["IDLE / PARTIAL DATA"]=6,["RUNNING / PARTIAL DATA"]=7 }
    ui.state.update(state[status])
    ui.live.update(data ~= nil)
    ui.link.set_value(bounded("#"..tostring(context.source or "--").." / "..
        (data and string.format("%.1fs",(context.age or 0)/1000) or "OFFLINE"),17))
    local current = data or {}
    ui.formed.update(current.formed == true)
    ui.fault.update(current.errors ~= nil and #current.errors > 0)
    ui.plasma(current.plasma)
    ui.casing(current.casing)
    ui.fusion(current.production)
    ui.fission(context.fission)
    ui.total(current.production ~= nil and context.fission ~= nil and (current.production+context.fission) or nil)
    for _, update in ipairs(ui.tanks) do update(current) end
    ui.injection.set_value(current.injection ~= nil and bounded(tostring(current.injection).." mB/t",ui.injection.get_width()) or "--")
    ui.buffer(current.port_energy)
    ui.buffer_cap(current.port_capacity)
    ui.buffer_fill(current.port_energy,current.port_capacity)
    ui.laser(current.laser_energy)
    ui.laser_cap(current.laser_capacity)
    ui.laser_min(current.laser_min)
    ui.laser_max(current.laser_max)
    ui.charge(current.laser_energy,current.laser_min)
    local threshold = 1
    if current.laser_energy ~= nil and current.laser_min ~= nil then
        threshold = current.laser_energy >= current.laser_min and 3 or 2
    end
    ui.threshold.update(threshold)
    ui.laser_mode.set_value(current.laser_mode or "--")
    ui.hohlraum.update(current.hohlraum_present == true)
    local charge = "--"
    if current.hohlraum_present == false then charge="EMPTY"
    elseif current.hohlraum_present then charge=current.hohlraum_fuel and (current.hohlraum_fuel.." mB D-T") or "UNKNOWN" end
    ui.charge_text.set_value(bounded(charge,ui.charge_text.get_width()))
    local notice = "Generator totals exclude Matrix input/output."
    if not data then notice="NO LIVE DATA - check the fusion computer and modem link."
    elseif current.errors and #current.errors > 0 then notice=current.errors[1]
    elseif context.fission == nil then notice="Fission total unavailable until SCADA turbine data is live." end
    ui.notice.set_value(bounded(notice,ui.notice.get_width()))
    ui.notice.recolor(not data and colors.red or (#(current.errors or {}) > 0 and colors.orange or style.theme.label))
end
return view
