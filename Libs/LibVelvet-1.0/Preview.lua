-- Copyright (c) 2026 AqueGen. All rights reserved. See LICENSE.
local lib = LibStub("LibVelvet-1.0")
if not lib.loading then return end

local T = lib.T
local OFF_ALPHA = 0.35
local LINE_H = 14
local WORLD_TOP, WORLD_BOTTOM = { 0.16, 0.19, 0.15, 1 }, { 0.07, 0.08, 0.07, 1 }

function lib.PreviewLayout(contentW, columnMin, zoneMin, zoneMax)
    if contentW >= columnMin + lib.GAP + zoneMin then
        local zoneW = math.min(zoneMax, contentW - columnMin - lib.GAP)
        return { mode = "side", columnW = contentW - zoneW - lib.GAP, zoneW = zoneW }
    end
    return { mode = "band", columnW = contentW, zoneW = contentW }
end

function lib.FitScale(w, h, availW, availH)
    if not w or not h or w <= 0 or h <= 0 or not availW or availW <= 0 or not availH or availH <= 0 then return 1 end
    return math.min(1, availW / w, availH / h)
end

local Pane = {}

function Pane:SetCaption(text)
    self.caption:SetText(text)
end

local function placeStage(pane, lineH)
    pane.stage:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -lib.PAD, lib.PAD + lineH)
end

function Pane:SetOff(text)
    self.stage:SetAlpha(text and OFF_ALPHA or 1)
    self.offLine:SetText(text or "")
    self.offLine:SetShown(text ~= nil)
    placeStage(self, text and math.max(LINE_H, self.offLine:GetStringHeight() + 2) or LINE_H)
end

local function refit(pane)
    local fit = pane.fitting
    if not fit then return end
    local stageW, stageH = pane.stage:GetSize()
    fit.content:SetScale(lib.FitScale(fit.w, fit.h, stageW, stageH))
end

function Pane:Fit(content, w, h)
    self.fitting = { content = content, w = w, h = h }
    content:ClearAllPoints()
    content:SetPoint("CENTER", self.stage, "CENTER", 0, 0)
    refit(self)
end

function lib.PreviewPane(parent)
    local pane = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    pane:SetBackdrop(lib.FLAT)
    pane:SetBackdropColor(unpack(T.panel))
    pane:SetBackdropBorderColor(unpack(T.border))
    for k, fn in pairs(Pane) do pane[k] = fn end

    pane.caption = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pane.caption:SetPoint("TOPLEFT", lib.PAD, -lib.PAD)
    pane.caption:SetPoint("RIGHT", pane, "RIGHT", -lib.PAD, 0)
    pane.caption:SetJustifyH("LEFT")
    pane.caption:SetTextColor(unpack(T.muted))

    pane.offLine = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pane.offLine:SetPoint("BOTTOMLEFT", lib.PAD, lib.PAD)
    pane.offLine:SetPoint("RIGHT", pane, "RIGHT", -lib.PAD, 0)
    pane.offLine:SetJustifyH("LEFT")
    pane.offLine:SetTextColor(unpack(T.text))
    pane.offLine:Hide()

    pane.stage = CreateFrame("Frame", nil, pane)
    pane.stage:SetPoint("TOPLEFT", pane.caption, "BOTTOMLEFT", 0, -lib.GAP)
    placeStage(pane, LINE_H)
    pane.stage:SetClipsChildren(true)
    pane.stage:SetScript("OnSizeChanged", function() refit(pane) end)

    pane.world = pane:CreateTexture(nil, "BACKGROUND", nil, 1)
    pane.world:SetAllPoints(pane.stage)
    pane.world:SetColorTexture(1, 1, 1, 1)
    pane.world:SetGradient("VERTICAL", CreateColor(unpack(WORLD_BOTTOM)), CreateColor(unpack(WORLD_TOP)))
    return pane
end
