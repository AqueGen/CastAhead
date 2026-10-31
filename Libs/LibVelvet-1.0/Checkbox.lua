-- Copyright (c) 2026 AqueGen. All rights reserved. See LICENSE.
local lib = LibStub("LibVelvet-1.0")
if not lib.loading then return end

local T = lib.T
local OFF_ALPHA = 0.45

-- Dims only the box art: callers hang their labels on the box and grey those themselves.
local function Paint(box)
    local on = box:GetChecked() and true or false
    local a = box:IsEnabled() and 1 or OFF_ALPHA
    local well, edge = on and T.wellOn or T.well, on and T.trackFill or T.control
    box:SetBackdropColor(well[1], well[2], well[3], a)
    box:SetBackdropBorderColor(edge[1], edge[2], edge[3], a)
    box.check:SetShown(on)
    box.check:SetAlpha(a)
end

function lib.Checkbox(parent, size)
    size = size or 22
    local box = CreateFrame("CheckButton", nil, parent, "BackdropTemplate")
    box:SetSize(size, size)
    box:SetBackdrop(lib.FLAT)
    box.check = box:CreateTexture(nil, "OVERLAY")
    box.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    box.check:SetPoint("TOPLEFT", -2, 2)
    box.check:SetPoint("BOTTOMRIGHT", 2, -2)
    box.check:SetDesaturated(true)
    box.check:SetVertexColor(unpack(T.tick))
    local hover = box:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(unpack(T.hover))
    box:SetHighlightTexture(hover)

    local setChecked, setEnabled = box.SetChecked, box.SetEnabled
    function box:SetChecked(on)
        setChecked(self, on)
        Paint(self)
    end
    function box:SetEnabled(on)
        setEnabled(self, on)
        Paint(self)
    end
    function box:Enable() self:SetEnabled(true) end
    function box:Disable() self:SetEnabled(false) end
    box:SetScript("PostClick", Paint)
    box:SetChecked(false)
    return box
end
