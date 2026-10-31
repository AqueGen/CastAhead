-- Copyright (c) 2026 AqueGen. All rights reserved. See LICENSE.
local lib = LibStub("LibVelvet-1.0")
if not lib.loading then return end

local T = lib.T

function lib.PaintGroup(box, title)
    box:SetBackdrop(lib.FLAT)
    box:SetBackdropColor(unpack(T.panel))
    box:SetBackdropBorderColor(unpack(T.border))
    if not title then return nil end
    title:SetTextColor(unpack(T.title))
    local rule = box.velvetRule or box:CreateTexture(nil, "ARTWORK")
    box.velvetRule = rule
    rule:ClearAllPoints()
    rule:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    rule:SetPoint("RIGHT", box, "RIGHT", -lib.PAD, 0)
    rule:SetHeight(1)
    rule:SetColorTexture(1, 1, 1, 1)
    local r, g, b = unpack(T.title)
    rule:SetGradient("HORIZONTAL", CreateColor(r, g, b, 0.55), CreateColor(r, g, b, 0))
    return rule
end
