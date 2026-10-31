-- Copyright (c) 2026 AqueGen. All rights reserved. See LICENSE.
local lib = LibStub("LibVelvet-1.0")
if not lib.loading then return end

local T = lib.T

local function Paint(set)
    for _, button in ipairs(set.buttons) do
        local on = not set.off and button.value == set.value
        button.fill:SetColorTexture(unpack(on and T.selected or T.segfill))
        button.label:SetTextColor(unpack(set.off and T.muted or on and T.selLabel or T.text))
        button.underline:SetShown(on)
    end
end

local function Select(set, value)
    set.value = value
    Paint(set)
end

local function SetOff(set, off)
    set.off = off and true or nil
    Paint(set)
end

function lib.Segments(parent, options, width, height, onSelect)
    local set = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    set:SetSize(width, height)
    set:SetBackdrop(lib.FLAT)
    set:SetBackdropColor(unpack(T.segfill))
    set:SetBackdropBorderColor(unpack(T.control))
    set.buttons, set.dividers = {}, {}
    set.Select, set.SetOff = Select, SetOff
    local count = #options
    local step = math.floor(width / count)
    for index, option in ipairs(options) do
        local w = index == count and width - step * (count - 1) or step
        local button = CreateFrame("Button", nil, set)
        button:SetSize(w, height)
        button:SetPoint("LEFT", set, "LEFT", (index - 1) * step, 0)
        button.value = option.value
        button.fill = button:CreateTexture(nil, "BACKGROUND")
        button.fill:SetPoint("TOPLEFT", 1, -1)
        button.fill:SetPoint("BOTTOMRIGHT", -1, 1)
        button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.label:SetPoint("CENTER")
        button.label:SetText(option.text)
        button.underline = button:CreateTexture(nil, "ARTWORK")
        button.underline:SetPoint("BOTTOMLEFT", 1, 1)
        button.underline:SetPoint("BOTTOMRIGHT", -1, 1)
        button.underline:SetHeight(2)
        button.underline:SetColorTexture(unpack(T.underline))
        local hover = button:CreateTexture(nil, "HIGHLIGHT")
        hover:SetAllPoints()
        hover:SetColorTexture(unpack(T.hover))
        button:SetHighlightTexture(hover)
        button:SetScript("OnClick", function(self)
            if set.off then return end
            if onSelect then onSelect(self.value) end
            set:Select(self.value)
        end)
        set.buttons[index] = button
        if index > 1 then
            local divider = set:CreateTexture(nil, "BORDER")
            divider:SetPoint("TOPLEFT", set, "TOPLEFT", (index - 1) * step, -1)
            divider:SetPoint("BOTTOMLEFT", set, "BOTTOMLEFT", (index - 1) * step, 1)
            divider:SetWidth(1)
            divider:SetColorTexture(unpack(T.divider))
            set.dividers[#set.dividers + 1] = divider
        end
    end
    Paint(set)
    return set
end
