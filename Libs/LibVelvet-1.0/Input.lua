-- Copyright (c) 2026 AqueGen. All rights reserved. See LICENSE.
local lib = LibStub("LibVelvet-1.0")
if not lib.loading then return end

local T = lib.T
local OFF_ALPHA = 0.45

local function edge(box, color)
    box:SetBackdropBorderColor(unpack(color))
end

function lib.Input(parent, width, height)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetSize(width, height or 22)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetTextInsets(6, 6, 0, 0)
    box:SetBackdrop(lib.FLAT)
    box:SetBackdropColor(unpack(T.well))
    edge(box, T.control)
    box:SetScript("OnEditFocusGained", function(self) edge(self, T.underline) end)
    box:SetScript("OnEditFocusLost", function(self) edge(self, T.control) end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local setEnabled = box.SetEnabled
    function box:SetEnabled(on)
        setEnabled(self, on)
        self:SetAlpha(on and 1 or OFF_ALPHA)
    end
    function box:Enable() self:SetEnabled(true) end
    function box:Disable() self:SetEnabled(false) end
    return box
end
