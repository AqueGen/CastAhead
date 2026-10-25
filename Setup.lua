CastAheadSetup = {}

local OFFSET_MAX = 120

local function Clamp(v, limit)
    return math.max(-limit, math.min(limit, math.floor(v + 0.5)))
end

function CastAheadSetup.Snap(dx, dy, w, h, size, labelH)
    local halfW, halfH = w / 2, h / 2
    local sx = dx < -halfW and -1 or dx > halfW and 1 or 0
    local sy = dy > halfH and 1 or dy < -halfH and -1 or 0
    local side
    for name, spec in pairs(CastAheadAnchors) do
        if spec.dx == sx and spec.dy == sy then side = name end
    end

    local gap = CastAheadCore.BAR_GAP
    local lift = sy > 0 and labelH or 0
    local ax, ay = dx - sx * size / 2, dy - sy * size / 2
    local out
    if sx ~= 0 then out = math.abs(ax) - halfW end
    if sy ~= 0 then
        local outY = math.abs(ay) - halfH - lift
        out = out and math.min(out, outY) or outY
    end
    local offset = 0
    if out then
        offset = math.max(0, math.min(OFFSET_MAX, math.floor((out - gap) / 2 + 0.5) * 2))
    end

    local reach = out and (gap + offset) or 0
    local max = CastAheadConfig.NUDGE_MAX
    return side, offset,
        Clamp(ax - sx * (halfW + reach), max),
        Clamp(ay - sy * (halfH + reach + lift), max)
end

local PANEL_NAME = "CastAheadSetupPanel"
local EVENTS = { "PLAYER_REGEN_DISABLED", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
                 "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED" }
local TIMELINE_LEAD = 60

local active = false
local rows = {}
local tracks = {}
local page

local panel = CreateFrame("Frame", PANEL_NAME, UIParent)
panel:SetSize(280, 120)
panel:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -40, -160)
panel:SetFrameStrata("DIALOG")
panel:SetClampedToScreen(true)
panel:SetMovable(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
panel:Hide()
CastAheadSetup.panel = panel

local function SamplePlate()
    local plate = CastAheadSetup.plate
    if plate then return plate end
    plate = CreateFrame("Frame", nil, UIParent)
    plate:SetPoint("CENTER", UIParent, "CENTER", 0, 220)
    plate:SetFrameStrata("MEDIUM")
    plate:SetMovable(true)
    plate:EnableMouse(true)
    plate:RegisterForDrag("LeftButton")
    plate:SetScript("OnDragStart", plate.StartMoving)
    plate:SetScript("OnDragStop", plate.StopMovingOrSizing)
    local bar = plate:CreateTexture(nil, "ARTWORK")
    bar:SetAllPoints()
    bar:SetColorTexture(0.75, 0.10, 0.10, 0.9)
    local name = plate:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("BOTTOM", plate, "TOP", 0, 2)
    name:SetText("Nameplate (sample)")
    plate:Hide()
    CastAheadSetup.plate = plate
    return plate
end

local function SizePlate()
    local w, h = CastAheadCore.PlateSize()
    CastAheadSetup.plate:SetSize(w, h)
end

local function ShowRow(key, frame)
    local state = rows[key] or {}
    rows[key] = state
    CastAheadCore.ShowSampleRow(state, frame)
    CastAheadCore.SampleStates[state] = frame
end

local function HideRow(key)
    local state = rows[key]
    if not state then return end
    CastAheadCore.SampleStates[state] = nil
    CastAheadCore.HideSampleRow(state)
    rows[key] = nil
end

local function AddUnit(unit)
    if not CastAheadCore.IsHostileNameplate(unit) then return end
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if plate and (not plate.IsShown or plate:IsShown()) then ShowRow(unit, plate) end
end

local function TimelineRow(key)
    for _, dungeon in pairs(CastAheadData) do
        for _, row in ipairs(dungeon) do
            local advice = CastAheadMatch.Advice(row)
            if advice and advice.key == key then return row end
        end
    end
end

local function FeedTimeline()
    if not CastAheadTimeline then return end
    local now = GetTime()
    for i, sample in ipairs(CastAheadCore.SAMPLE_ROW) do
        local row = TimelineRow(sample.key)
        if row then
            tracks[i] = tracks[i] or {}
            CastAheadTimeline.Sync(tracks[i], now + TIMELINE_LEAD + sample.time, row,
                CastAheadMatch.ADVICE[sample.key], true)
        end
    end
end

function CastAheadSetup.Active()
    return active
end

function CastAheadSetup.Enter()
    if InCombatLockdown() then return false, "combat" end
    if active then return true end
    CastAheadCore.StopTest(true)
    local window = CastAheadWindow.Frame()
    page = window and window:IsShown() and CastAheadWindow.Current() or nil
    if window then window:Hide() end
    active = true
    local plate = SamplePlate()
    SizePlate()
    plate:Show()
    ShowRow("sample", plate)
    for i = 1, 40 do AddUnit("nameplate" .. i) end
    CastAheadCore.ShowCenterSample(true)
    FeedTimeline()
    for _, event in ipairs(EVENTS) do panel:RegisterEvent(event) end
    table.insert(UISpecialFrames, PANEL_NAME)
    panel:Show()
    return true
end

function CastAheadSetup.Leave()
    if not active then return end
    active = false
    for _, event in ipairs(EVENTS) do panel:UnregisterEvent(event) end
    for i = #UISpecialFrames, 1, -1 do
        if UISpecialFrames[i] == PANEL_NAME then table.remove(UISpecialFrames, i) end
    end
    for key in pairs(rows) do HideRow(key) end
    CastAheadSetup.plate:Hide()
    CastAheadCore.ShowCenterSample(false)
    if CastAheadTimeline then
        for _, track in pairs(tracks) do CastAheadTimeline.Cancel(track) end
    end
    panel:Hide()
    if page then CastAheadWindow.Show(page) end
    page = nil
end

panel:SetScript("OnHide", CastAheadSetup.Leave)
panel:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_REGEN_DISABLED" then
        CastAheadSetup.Leave()
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        AddUnit(unit)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        HideRow(unit)
    else
        SizePlate()
        CastAheadCore.Reapply()
    end
end)
