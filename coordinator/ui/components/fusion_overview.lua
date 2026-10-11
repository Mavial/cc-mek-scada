local core = require("graphics.core")
local style = require("coordinator.ui.style")
local fusion = require("coordinator.fusion")
local Div = require("graphics.elements.Div")
local TextBox = require("graphics.elements.TextBox")
return function(parent,x,y,width)
    local root = Div{parent=parent,x=x,y=y,width=width,height=17}
    TextBox{parent=root,y=1,text="FUSION / GENERATION",alignment=core.ALIGN.CENTER,fg_bg=style.theme.header}
    local state = TextBox{parent=root,x=2,y=3,width=width-2,text="NO LIVE DATA",fg_bg=style.lg_white}
    state.register(fusion.ps,"status",state.set_value)
    local fields = {{"Fusion: ","fusion"},{"Fission: ","fission"},{"Total: ","total"},{"Telemetry age: ","age"}}
    for i,item in ipairs(fields) do
        local line = TextBox{parent=root,x=2,y=3+i*2,width=width-2,text=item[1].."--"}
        local prefix = item[1]
        line.register(fusion.ps,item[2],function(value) line.set_value(prefix..value) end)
    end
    TextBox{parent=root,x=2,y=14,width=width-2,text="Fusion telemetry only",fg_bg=style.lg_gray}
    TextBox{parent=root,x=2,y=16,width=width-2,text="Total = fission turbines + fusion",fg_bg=style.lg_gray}
    return root
end
