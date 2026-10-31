-- Copyright (c) 2026 AqueGen. All rights reserved. See LICENSE.
local lib = LibStub("LibVelvet-1.0")
if not lib.loading then return end

local T = lib.T
local WIDTH = 8

local function cursorX()
    local x = GetCursorPosition()
    return x / UIParent:GetEffectiveScale()
end

function lib.Splitter(parent, onMove, onDone)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetWidth(WIDTH)
    bar:EnableMouse(true)
    bar.line = bar:CreateTexture(nil, "ARTWORK")
    bar.line:SetPoint("TOP", bar, "TOP", 0, 0)
    bar.line:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
    bar.line:SetWidth(1)
    bar.line:SetColorTexture(unpack(T.control))
    bar:SetScript("OnEnter", function(self) self.line:SetColorTexture(unpack(T.underline)) end)
    bar:SetScript("OnLeave", function(self)
        if not self.startX then self.line:SetColorTexture(unpack(T.control)) end
    end)
    bar:SetScript("OnMouseDown", function(self)
        self.startX = cursorX()
        self:SetScript("OnUpdate", function()
            onMove(cursorX() - self.startX)
        end)
    end)
    bar:SetScript("OnMouseUp", function(self)
        self:SetScript("OnUpdate", nil)
        self.startX = nil
        self.line:SetColorTexture(unpack(T.control))
        if onDone then onDone() end
    end)
    return bar
end
