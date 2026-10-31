-- Copyright (c) 2026 AqueGen. All rights reserved. See LICENSE.
local lib = LibStub("LibVelvet-1.0")
if not lib.loading then return end

local T = lib.T

function lib.NavEntry(parent, text, width, height)
    local entry = CreateFrame("Button", nil, parent)
    entry:SetSize(width, height)
    entry.fill = entry:CreateTexture(nil, "BACKGROUND")
    entry.fill:SetAllPoints()
    entry.fill:SetColorTexture(unpack(T.navSelected))
    entry.bar = entry:CreateTexture(nil, "OVERLAY")
    entry.bar:SetPoint("TOPLEFT")
    entry.bar:SetPoint("BOTTOMLEFT")
    entry.bar:SetWidth(2)
    entry.bar:SetColorTexture(unpack(T.underline))
    entry.label = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    entry.label:SetPoint("LEFT", 10, 0)
    entry.label:SetJustifyH("LEFT")
    entry:SetFontString(entry.label)
    entry:SetText(text)
    local hover = entry:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(unpack(T.hover))
    entry:SetHighlightTexture(hover)
    lib.PaintNav(entry, "normal")
    return entry
end

local LABEL = { selected = T.selLabel, normal = T.text, muted = T.muted }

function lib.PaintNav(entry, state)
    local selected = state == "selected"
    entry.fill:SetShown(selected)
    entry.bar:SetShown(selected)
    entry.label:SetTextColor(unpack(LABEL[state] or T.text))
end
