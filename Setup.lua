CastAheadSetup = {}

local OFFSET_MAX = 120
local SNAP_AXIS = 8
local READOUT_SECONDS = 1.5
local ARROWS = { UP = { 0, 1 }, DOWN = { 0, -1 }, LEFT = { -1, 0 }, RIGHT = { 1, 0 } }

local function Clamp(v, limit)
    return math.max(-limit, math.min(limit, math.floor(v + 0.5)))
end

local function Within(v, low, high)
    return math.max(low, math.min(high, v))
end

function CastAheadSetup.SnapAxis(x, y)
    local snapX, snapY = math.abs(x) <= SNAP_AXIS, math.abs(y) <= SNAP_AXIS
    return snapX and 0 or x, snapY and 0 or y, snapX, snapY
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
local TIMELINE_LEAD = 5

local active = false
local rows = {}
local tracks = {}
local page
local refeedAt = 0
local selected = "row"
local dragging = false
local readoutUntil
local centerBox

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
table.insert(UISpecialFrames, PANEL_NAME)
CastAheadSetup.panel = panel

local readout = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
readout:Hide()

local function Guide(vertical)
    local line = panel:CreateTexture(nil, "OVERLAY")
    line:SetColorTexture(1, 0.82, 0, 0.8)
    if vertical then
        line:SetWidth(1)
        line:SetPoint("TOP", UIParent, "TOP")
        line:SetPoint("BOTTOM", UIParent, "BOTTOM")
    else
        line:SetHeight(1)
        line:SetPoint("LEFT", UIParent, "LEFT")
        line:SetPoint("RIGHT", UIParent, "RIGHT")
    end
    line:Hide()
    return line
end
local guideX, guideY = Guide(true), Guide(false)

local function Outline(parent, target)
    local box = CreateFrame("Frame", nil, parent)
    box:SetAllPoints(target or parent)
    for i, edge in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" },
                            { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local line = box:CreateTexture(nil, "OVERLAY")
        line:SetColorTexture(1, 0.82, 0, 1)
        line:SetPoint(edge[1])
        line:SetPoint(edge[2])
        if i <= 2 then line:SetHeight(1) else line:SetWidth(1) end
    end
    box:Hide()
    return box
end

local grip = CreateFrame("Frame", nil, UIParent)
grip:SetFrameStrata("HIGH")
grip:EnableMouse(true)
grip:EnableMouseWheel(true)
grip:RegisterForDrag("LeftButton")
grip.box = Outline(grip)
grip:Hide()
CastAheadSetup.grip = grip

local ghost = CreateFrame("Frame", nil, UIParent)
ghost:SetMovable(true)
ghost:Hide()

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
    if not (plate and (not plate.IsShown or plate:IsShown())) then return end
    CastAheadCore.RememberPlateSize(plate)
    ShowRow(unit, plate)
end

local function FeedTimeline(now)
    if not CastAheadTimeline then return end
    for i, sample in ipairs(CastAheadCore.SAMPLE_ROW) do
        local track = tracks[i] or {}
        tracks[i] = track
        local row = (not track.timelineTargetAt or now >= track.timelineTargetAt)
            and CastAheadCore.SampleDataRow(sample.key)
        if row then
            CastAheadTimeline.Sync(track, now + TIMELINE_LEAD + sample.time, row,
                CastAheadMatch.ADVICE[sample.key], true)
        end
    end
end

local function PlaceGrip()
    local bars = rows.sample and rows.sample.bars
    local first = bars and bars[1]
    local shown = first and first:IsShown() or false
    grip:SetShown(shown)
    if not shown then return end
    local db = CastAheadDB or {}
    local spec = CastAheadAnchors[db.anchor or "left"] or CastAheadAnchors.left
    local grow = CastAheadGrowth[db.grow] and db.grow or spec.grow
    local back = grow == "left" or grow == "up"
    local a, b = back and bars[#bars] or first, back and first or bars[#bars]
    if grip._a == a and grip._b == b then return end
    grip._a, grip._b = a, b
    grip:ClearAllPoints()
    grip:SetPoint("TOPLEFT", a, "TOPLEFT", -2, 2)
    grip:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 2, -2)
end

local function ShowReadout(target, text)
    readout:ClearAllPoints()
    readout:SetPoint("BOTTOMLEFT", target, "TOPRIGHT", 4, 4)
    readout:SetText(text)
    readout:Show()
    readoutUntil = GetTime() + READOUT_SECONDS
end

function CastAheadSetup.Select(which)
    selected = which
    grip.box:SetShown(which == "row")
    if centerBox then centerBox:SetShown(which == "center" and CastAheadCore.CenterFrame():IsShown()) end
end

function CastAheadSetup.Nudge(dx, dy)
    local C = CastAheadConfig
    if selected == "center" then
        C.Set("centerX", (tonumber(C.Get("centerX")) or 0) + dx)
        C.Set("centerY", (tonumber(C.Get("centerY")) or 0) + dy)
        CastAheadCore.ResizeCenter()
    else
        C.Set("nudgeX", Clamp(C.NudgeX() + dx, C.NUDGE_MAX))
        C.Set("nudgeY", Clamp(C.NudgeY() + dy, C.NUDGE_MAX))
        CastAheadCore.Reapply()
    end
end

function CastAheadSetup.Resize(notches)
    local C = CastAheadConfig
    if selected == "center" then
        local scale = Within(C.Number("centerScale", C.CENTER_DEFAULT, C.CENTER_MIN, C.CENTER_MAX) + 5 * notches,
            C.CENTER_MIN, C.CENTER_MAX)
        C.Set("centerScale", scale)
        CastAheadCore.ResizeCenter()
        ShowReadout(CastAheadCore.CenterFrame(), scale .. "%")
    else
        local size = Within(C.IconSize() + notches, C.ICON_MIN, C.ICON_MAX)
        C.Set("iconSize", size)
        CastAheadCore.Reapply()
        ShowReadout(grip, size .. " px")
    end
end

local function Wheel(which, delta)
    CastAheadSetup.Select(which)
    CastAheadSetup.Resize(delta * ((which == "row" and IsShiftKeyDown()) and 5 or 1))
end

local function StartRow()
    local state, plate = rows.sample, CastAheadSetup.plate
    if dragging or not state then return end
    ghost:SetSize(CastAheadCore.PlateSize())
    ghost:ClearAllPoints()
    local x, y = plate:GetCenter()
    ghost:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
    ghost:Show()
    CastAheadCore.SampleStates[state] = ghost
    CastAheadCore.ShowSampleRow(state, ghost)
    ghost:StartMoving()
    dragging = true
end

function CastAheadSetup.DropRow()
    if not dragging then return end
    dragging = false
    ghost:StopMovingOrSizing()
    local state, plate = rows.sample, CastAheadSetup.plate
    local bar = state.bars[1]
    local bx, by = bar:GetCenter()
    local px, py = plate:GetCenter()
    ghost:Hide()
    CastAheadCore.SampleStates[state] = plate
    if not (bx and px) then
        CastAheadCore.Reapply()
        return
    end
    local w, h = CastAheadCore.PlateSize()
    local side, offset, nudgeX, nudgeY = CastAheadSetup.Snap(bx - px, by - py, w, h, bar._size,
        math.max(bar.label:GetStringHeight() or 0, CastAheadCore.LABEL_HEIGHT))
    local C = CastAheadConfig
    C.Set("offsetX", offset)
    C.Set("nudgeX", nudgeX)
    C.Set("nudgeY", nudgeY)
    CastAheadUI.SetAnchor(side)
    CastAheadUI.SetGrowth("auto")
end

grip:SetScript("OnMouseDown", function() CastAheadSetup.Select("row") end)
grip:SetScript("OnMouseWheel", function(_, delta) Wheel("row", delta) end)
grip:SetScript("OnDragStart", StartRow)
grip:SetScript("OnDragStop", function() CastAheadSetup.DropRow() end)

local function HookCenter()
    local f = CastAheadCore.CenterFrame()
    if not centerBox then
        centerBox = Outline(UIParent, f)
        CastAheadSetup.centerBox = centerBox
        f:SetScript("OnMouseDown", function() if active then CastAheadSetup.Select("center") end end)
        f:SetScript("OnMouseWheel", function(_, delta) if active then Wheel("center", delta) end end)
    end
    return f
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
    for i = 1, 40 do AddUnit("nameplate" .. i) end
    SizePlate()
    plate:Show()
    ShowRow("sample", plate)
    CastAheadCore.Reapply()
    CastAheadCore.ShowCenterSample(true)
    HookCenter():EnableMouseWheel(true)
    FeedTimeline(GetTime())
    for _, event in ipairs(EVENTS) do panel:RegisterEvent(event) end
    panel:EnableKeyboard(true)
    panel:Show()
    PlaceGrip()
    CastAheadSetup.Select("row")
    return true
end

function CastAheadSetup.Leave()
    if not active then return end
    CastAheadSetup.DropRow()
    CastAheadCore.DropCenter()
    active = false
    panel:EnableKeyboard(false)
    HookCenter():EnableMouseWheel(false)
    grip:Hide()
    grip._a, grip._b = nil, nil
    grip.box:Hide()
    centerBox:Hide()
    readout:Hide()
    readoutUntil = nil
    guideX:Hide()
    guideY:Hide()
    for _, event in ipairs(EVENTS) do panel:UnregisterEvent(event) end
    for key in pairs(rows) do HideRow(key) end
    CastAheadSetup.plate:Hide()
    CastAheadCore.Reapply()
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
        SizePlate()
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        HideRow(unit)
    else
        for key, state in pairs(rows) do
            local plate = key ~= "sample" and C_NamePlate.GetNamePlateForUnit(key)
            if plate then
                CastAheadCore.RememberPlateSize(plate)
                CastAheadCore.SampleStates[state] = plate
            end
        end
        SizePlate()
        CastAheadCore.Reapply()
    end
end)
panel:SetScript("OnKeyDown", function(self, key)
    local dir = ARROWS[key]
    self:SetPropagateKeyboardInput(not dir)
    if dir then
        local step = IsShiftKeyDown() and 10 or 1
        CastAheadSetup.Nudge(dir[1] * step, dir[2] * step)
    end
end)
panel:SetScript("OnUpdate", function()
    local now = GetTime()
    PlaceGrip()
    local x, y = CastAheadCore.CenterDragOffset()
    local snapX, snapY
    if x then snapX, snapY = select(3, CastAheadSetup.SnapAxis(x, y)) end
    guideX:SetShown(snapX or false)
    guideY:SetShown(snapY or false)
    if readoutUntil and now >= readoutUntil then
        readout:Hide()
        readoutUntil = nil
    end
    if now < refeedAt then return end
    refeedAt = now + 1
    FeedTimeline(now)
end)
