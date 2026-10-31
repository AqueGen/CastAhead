-- Copyright (c) 2026 AqueGen. All rights reserved. See LICENSE.
local lib = LibStub("LibVelvet-1.0")
if not lib.loading then return end

local T = lib.T

function lib.SetPrimary(button, on)
    button:SetBackdropBorderColor(unpack(on and T.gold or T.control))
    button.label:SetTextColor(unpack(on and T.gold or T.text))
end

function lib.Button(parent, text, width, primary)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(width, 22)
    button:SetBackdrop(lib.FLAT)
    button:SetBackdropColor(unpack(T.panel))
    button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.label:SetPoint("CENTER")
    button:SetFontString(button.label)
    button:SetText(text)
    local hover = button:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(unpack(T.hover))
    button:SetHighlightTexture(hover)
    lib.SetPrimary(button, primary)
    return button
end
