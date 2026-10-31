-- Copyright (c) 2026 AqueGen. All rights reserved. See LICENSE.
local lib = LibStub("LibVelvet-1.0")
if not lib.loading then return end

local T = lib.T
local STEPPER_W, STEPPER_GAP, OFF_ALPHA = 14, 4, 0.45

local function Snap(self, value)
    local lo, hi, step = self.min, self.max, self.step
    value = math.max(lo, math.min(hi, value))
    value = lo + math.floor((value - lo) / step + 0.5) * step
    return tonumber(("%.4f"):format(math.min(hi, value)))
end

local function PaintFill(self)
    local span = self.max - self.min
    local share = span > 0 and (self.value - self.min) / span or 0
    self.fill:SetWidth(math.max(share * self.trackW, 0.001))
end

local function SetValue(self, value, silent)
    value = Snap(self, value)
    local changed = value ~= self.value
    self.value = value
    self.updating = true
    self.widget:SetValue(value)
    self.updating = nil
    PaintFill(self)
    if changed and not silent and self.onChange then self.onChange(value) end
end

local function GetValue(self) return self.value end

local function Setup(self, min, max, step)
    self.min, self.max, self.step = min, max, step or 1
    self.updating = true
    self.widget:SetMinMaxValues(min, max)
    self.widget:SetValueStep(self.step)
    self.updating = nil
    self:SetValue(self.value or min, true)
end

local function SetEnabled(self, on)
    self.enabled = on and true or false
    self.widget:SetEnabled(self.enabled)
    self.down:SetEnabled(self.enabled)
    self.up:SetEnabled(self.enabled)
    local alpha = self.enabled and 1 or OFF_ALPHA
    self.down:SetAlpha(alpha)
    self.up:SetAlpha(alpha)
    self.thumb:SetAlpha(alpha)
    self.fill:SetAlpha(alpha)
end

local function Stepper(self, text, point, delta)
    local button = CreateFrame("Button", nil, self)
    button:SetSize(STEPPER_W, 22)
    button:SetPoint(point)
    button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    button.label:SetPoint("CENTER")
    button.label:SetText(text)
    button.label:SetTextColor(unpack(T.muted))
    button:SetScript("OnEnter", function(b) b.label:SetTextColor(1, 1, 1) end)
    button:SetScript("OnLeave", function(b) b.label:SetTextColor(unpack(T.muted)) end)
    button:SetScript("OnClick", function() self:SetValue(self.value + delta * self.step) end)
    return button
end

function lib.Slider(parent, width)
    local self = CreateFrame("Frame", nil, parent)
    self:SetSize(width, 22)
    self.min, self.max, self.step, self.enabled = 0, 1, 1, true
    self.Setup, self.SetValue, self.GetValue, self.SetEnabled = Setup, SetValue, GetValue, SetEnabled
    self.down = Stepper(self, "-", "LEFT", -1)
    self.up = Stepper(self, "+", "RIGHT", 1)

    local inner = width - 2 * (STEPPER_W + STEPPER_GAP)
    self.trackW = inner
    local widget = CreateFrame("Slider", nil, self)
    widget:SetSize(inner, 22)
    widget:SetPoint("LEFT", STEPPER_W + STEPPER_GAP, 0)
    widget:SetOrientation("HORIZONTAL")
    widget:EnableMouse(true)
    widget:SetObeyStepOnDrag(true)
    self.widget = widget

    self.track = widget:CreateTexture(nil, "BACKGROUND")
    self.track:SetPoint("LEFT")
    self.track:SetSize(inner, 4)
    self.track:SetColorTexture(unpack(T.track))
    self.fill = widget:CreateTexture(nil, "BORDER")
    self.fill:SetPoint("LEFT", self.track, "LEFT")
    self.fill:SetHeight(4)
    self.fill:SetColorTexture(unpack(T.trackFill))
    self.thumb = widget:CreateTexture(nil, "OVERLAY")
    self.thumb:SetSize(9, 18)
    self.thumb:SetColorTexture(unpack(T.thumb))
    widget:SetThumbTexture(self.thumb)

    widget:SetScript("OnValueChanged", function(_, value)
        if self.updating then return end
        self:SetValue(value)
    end)
    return self
end
