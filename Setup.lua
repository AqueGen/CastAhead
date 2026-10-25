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
                 "PLAYER_TARGET_CHANGED", "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED" }
local TIMELINE_LEAD = 5
local HINT = "Drag the icons or the centre call, or type exact numbers."
local TIMELINE_NOTE = "Move the timeline in the game's Edit Mode: Esc > Edit Mode."
local RESET_KEYS = { "anchor", "grow", "offsetX", "nudgeX", "nudgeY", "iconSize", "labelScale", "timeScale",
                     "iconGap", "fixedSpacing", "strata", "centerX", "centerY", "centerScale", "centerTextScale" }
local PANEL_W, PAD, ROW_H, LABEL_W = 280, 12, 24, 72
local HALF_SCREEN_FALLBACK = 1000
local GUESS = "Sample size is a guess until a real nameplate is seen."
local PLATE_STRATA = "BACKGROUND"
local PLATE_LABEL = "Sample nameplate - stand near enemies or training dummies to edit on real ones"
local PLATE_RED = { 0.75, 0.10, 0.10, 0.9 }
local GOLD, WHITE = { 1, 0.82, 0, 1 }, { 1, 1, 1, 1 }
local DRAG_LABEL = "Drag to move"

local active = false
local rows = {}
local tracks = {}
local page
local refeedAt = 0
local selected = "row"
local dragging = false
local editKey, editFrame = "sample", nil
local readoutUntil
local centerBox

local panel = CreateFrame("Frame", PANEL_NAME, UIParent, "BackdropTemplate")
panel:SetWidth(PANEL_W)
panel:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -40, -120)
panel:SetFrameStrata("DIALOG")
panel:SetClampedToScreen(true)
panel:SetMovable(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
panel:Hide()
-- Not in UISpecialFrames: CloseSpecialWindows hides every listed frame, so it would hide the window Leave just reopened.
CastAheadSetup.panel = panel

local readout = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
readout:Hide()
CastAheadSetup.readout = readout

local thinLines = {}
local function Thin(line, vertical)
    line.vertical = vertical
    thinLines[#thinLines + 1] = line
end

local function SizeThinLines()
    for _, line in ipairs(thinLines) do
        local size = PixelUtil and PixelUtil.ConvertPixelsToUIForRegion(1, line) or 1
        if line.vertical then line:SetWidth(size) else line:SetHeight(size) end
    end
end

local function Guide(vertical)
    local line = panel:CreateTexture(nil, "OVERLAY")
    line:SetColorTexture(1, 0.82, 0, 0.8)
    Thin(line, vertical)
    if vertical then
        line:SetPoint("TOP", UIParent, "TOP")
        line:SetPoint("BOTTOM", UIParent, "BOTTOM")
    else
        line:SetPoint("LEFT", UIParent, "LEFT")
        line:SetPoint("RIGHT", UIParent, "RIGHT")
    end
    line:Hide()
    return line
end
local guideX, guideY = Guide(true), Guide(false)

local function Outline(parent, target, color)
    local box = CreateFrame("Frame", nil, parent)
    box:SetAllPoints(target or parent)
    box.lines = {}
    for i, edge in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" },
                            { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local line = box:CreateTexture(nil, "OVERLAY")
        line:SetColorTexture(unpack(color or GOLD))
        line:SetPoint(edge[1])
        line:SetPoint(edge[2])
        Thin(line, i > 2)
        box.lines[i] = line
    end
    box:Hide()
    return box
end

local function Highlight(box, on)
    for _, line in ipairs(box.lines) do line:SetColorTexture(unpack(on and WHITE or GOLD)) end
end

local catcher = CreateFrame("Frame", nil, UIParent)
catcher:SetAllPoints()
catcher:SetFrameStrata("BACKGROUND")
catcher:SetFrameLevel(0)
catcher:EnableMouse(true)
catcher:Hide()
CastAheadSetup.catcher = catcher

local grip = CreateFrame("Frame", nil, UIParent)
grip:SetFrameStrata("HIGH")
grip:EnableMouse(true)
grip:EnableMouseWheel(true)
grip:RegisterForDrag("LeftButton")
grip.box = Outline(grip)
local gripLabel = grip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
gripLabel:SetPoint("BOTTOM", grip, "TOP", 0, 2)
gripLabel:SetText(DRAG_LABEL)
CastAheadSetup.gripLabel = gripLabel
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
    plate:SetFrameStrata(PLATE_STRATA)
    plate:SetMovable(true)
    plate:EnableMouse(true)
    plate:RegisterForDrag("LeftButton")
    plate:SetScript("OnDragStart", plate.StartMoving)
    plate:SetScript("OnDragStop", plate.StopMovingOrSizing)
    Outline(plate, nil, PLATE_RED):Show()
    plate.bar = plate:CreateTexture(nil, "ARTWORK")
    plate.bar:SetPoint("LEFT")
    plate.bar:SetPoint("RIGHT")
    plate.bar:SetColorTexture(unpack(PLATE_RED))
    plate.label = plate:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    plate.label:SetPoint("BOTTOM", plate, "TOP", 0, 2)
    plate.label:SetText(PLATE_LABEL)
    plate:Hide()
    CastAheadSetup.plate = plate
    return plate
end

local function SizePlate()
    local w, h = CastAheadCore.PlateSize()
    CastAheadSetup.plate:SetSize(w, h)
    CastAheadSetup.plate.bar:SetHeight(math.max(6, h * 0.25))
    SizeThinLines()
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
    local bars = rows[editKey] and rows[editKey].bars
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

local function Shown(frame)
    return frame and (not frame.IsShown or frame:IsShown())
end

local function RealRect(plate)
    local x, y = plate:GetCenter()
    if issecretvalue and (issecretvalue(x) or issecretvalue(y)) then return end
    local w, h = CastAheadCore.MeasurePlate(plate)
    if not (x and w) then return end
    local ratio = plate:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return x * ratio, y * ratio, w, h
end

local function Rect(key, frame)
    if key == "sample" then
        local x, y = frame:GetCenter()
        local w, h = CastAheadCore.PlateSize()
        return x, y, w, h
    end
    local ok, x, y, w, h = pcall(RealRect, frame)
    if ok then return x, y, w, h end
end

local function IsTarget(key)
    local ok, same = pcall(function() return UnitIsUnit(key, "target") == true end)
    return ok and same
end

function CastAheadSetup.EditablePlate()
    if CastAheadCore.IsHostileNameplate("target") then
        for key in pairs(rows) do
            local plate = key ~= "sample" and IsTarget(key) and C_NamePlate.GetNamePlateForUnit(key)
            if Shown(plate) then return plate, key end
        end
    end
    local ok, ux, uy = pcall(function() return UIParent:GetCenter() end)
    local best, bestKey, bestD
    for key in pairs(rows) do
        local plate = key ~= "sample" and C_NamePlate.GetNamePlateForUnit(key)
        if Shown(plate) then
            local x, y = Rect(key, plate)
            local d = (ok and ux and x) and ((x - ux) ^ 2 + (y - uy) ^ 2) or math.huge
            if not bestD or d < bestD then best, bestKey, bestD = plate, key, d end
        end
    end
    if best then return best, bestKey end
    return CastAheadSetup.plate, "sample"
end

local function SyncSample()
    local plate = SamplePlate()
    SizePlate()
    for key in pairs(rows) do
        if key ~= "sample" then
            HideRow("sample")
            plate:Hide()
            return
        end
    end
    plate:Show()
    ShowRow("sample", plate)
end

local function Rechoose()
    if dragging or not active then return end
    SyncSample()
    editFrame, editKey = CastAheadSetup.EditablePlate()
    grip._a, grip._b = nil, nil
    PlaceGrip()
end

local function ShowReadout(target, text)
    readout:ClearAllPoints()
    readout:SetPoint("BOTTOMLEFT", target, "TOPRIGHT", 4, 4)
    readout:SetText(text)
    readout:Show()
    readoutUntil = GetTime() + READOUT_SECONDS
end

local function Round(v)
    return math.floor(v + 0.5)
end

local function CenterNumber(key)
    return tonumber(CastAheadConfig.Get(key)) or 0
end

local function HalfScreen(getter)
    local size = UIParent and UIParent[getter] and UIParent[getter](UIParent)
    return type(size) == "number" and size > 0 and size / 2 or HALF_SCREEN_FALLBACK
end

local function Ranged(key, default, low, high, step, center)
    return {
        step = step, center = center,
        read = function() return CastAheadConfig.Number(key, default, low, high) end,
        write = function(v) CastAheadConfig.Set(key, Within(Round(v), low, high)) end,
    }
end

local C = CastAheadConfig
local FIELDS = {
    offsetX = Ranged("offsetX", 0, 0, OFFSET_MAX, 2),
    nudgeX = Ranged("nudgeX", 0, -C.NUDGE_MAX, C.NUDGE_MAX, 1),
    nudgeY = Ranged("nudgeY", 0, -C.NUDGE_MAX, C.NUDGE_MAX, 1),
    iconSize = Ranged("iconSize", C.ICON_DEFAULT, C.ICON_MIN, C.ICON_MAX, 1),
    labelScale = Ranged("labelScale", C.LABEL_DEFAULT, C.LABEL_MIN, C.LABEL_MAX, 5),
    timeScale = Ranged("timeScale", C.TIME_DEFAULT, C.TIME_MIN, C.TIME_MAX, 5),
    iconGap = Ranged("iconGap", C.GAP_DEFAULT, 0, C.GAP_MAX, 1),
    centerX = {
        step = 1, center = true,
        read = function() return CenterNumber("centerX") end,
        write = function(v) CastAheadConfig.Set("centerX", Clamp(v, HalfScreen("GetWidth"))) end,
    },
    centerY = {
        step = 1, center = true,
        read = function() return CastAheadCore.CENTER_Y + CenterNumber("centerY") end,
        write = function(v)
            CastAheadConfig.Set("centerY", Clamp(v, HalfScreen("GetHeight")) - CastAheadCore.CENTER_Y)
        end,
    },
    centerScale = Ranged("centerScale", C.CENTER_DEFAULT, C.CENTER_MIN, C.CENTER_MAX, 5, true),
    centerTextScale = Ranged("centerTextScale", C.CENTER_TEXT_DEFAULT, C.CENTER_TEXT_MIN, C.CENTER_TEXT_MAX, 5, true),
}
local TARGETS = {
    row = { x = "nudgeX", y = "nudgeY", size = "iconSize", notch = 1, unit = " px" },
    center = { x = "centerX", y = "centerY", size = "centerScale", notch = 5, unit = "%" },
}

local function Refresh()
    if not panel.fields then return end
    for key, field in pairs(panel.fields) do field.box:SetText(tostring(Round(FIELDS[key].read()))) end
    CastAheadOptions.Refresh()
end
CastAheadSetup.Refresh = Refresh

local function Apply(key)
    if FIELDS[key].center then CastAheadCore.ResizeCenter() else CastAheadCore.Reapply() end
    Refresh()
end

local function SetField(key, value)
    FIELDS[key].write(value)
    Apply(key)
end

function CastAheadSetup.Select(which)
    selected = which
    grip.box:SetShown(which == "row")
    if centerBox then centerBox:SetShown(which == "center" and CastAheadCore.CenterFrame():IsShown()) end
end

function CastAheadSetup.Nudge(dx, dy)
    local target = TARGETS[selected]
    local x, y = FIELDS[target.x], FIELDS[target.y]
    x.write(x.read() + dx)
    y.write(y.read() + dy)
    Apply(target.x)
end

function CastAheadSetup.Resize(notches)
    local target = TARGETS[selected]
    local size = FIELDS[target.size]
    size.write(size.read() + notches * target.notch)
    Apply(target.size)
    ShowReadout(selected == "center" and CastAheadCore.CenterFrame() or grip, size.read() .. target.unit)
end

local function Wheel(which, delta)
    CastAheadSetup.Select(which)
    CastAheadSetup.Resize(delta * ((which == "row" and IsShiftKeyDown()) and 5 or 1))
end

local function StartRow()
    local state = rows[editKey]
    if dragging or not state then return end
    local x, y, w, h = Rect(editKey, editFrame)
    if not w then w, h = CastAheadCore.PlateSize() end
    ghost:SetSize(w, h)
    ghost:ClearAllPoints()
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
    local state = rows[editKey]
    if not state then
        ghost:Hide()
        Rechoose()
        return
    end
    local bar = state.bars[1]
    local bx, by = bar:GetCenter()
    local px, py, w, h = Rect(editKey, editFrame)
    ghost:Hide()
    CastAheadCore.SampleStates[state] = editFrame
    if not (bx and px) then
        CastAheadCore.Reapply()
        Rechoose()
        return
    end
    local side, offset, nudgeX, nudgeY = CastAheadSetup.Snap(bx - px, by - py, w, h, bar._size,
        math.max(bar.label:GetStringHeight() or 0, CastAheadCore.LABEL_HEIGHT))
    local C = CastAheadConfig
    C.Set("offsetX", offset)
    C.Set("nudgeX", nudgeX)
    C.Set("nudgeY", nudgeY)
    CastAheadUI.SetAnchor(side)
    CastAheadUI.SetGrowth("auto")
    Rechoose()
    Refresh()
end

grip:SetScript("OnMouseDown", function() CastAheadSetup.Select("row") end)
grip:SetScript("OnMouseWheel", function(_, delta) Wheel("row", delta) end)
grip:SetScript("OnDragStart", StartRow)
grip:SetScript("OnDragStop", function() CastAheadSetup.DropRow() end)

local function Hover(box, which, on)
    if on then SetCursor("UI_MOVE_CURSOR") else ResetCursor() end
    Highlight(box, on)
    box:SetShown(on or selected == which)
end
grip:SetScript("OnEnter", function() Hover(grip.box, "row", true) end)
grip:SetScript("OnLeave", function() Hover(grip.box, "row", false) end)

local function HookCenter()
    local f = CastAheadCore.CenterFrame()
    if not centerBox then
        centerBox = Outline(UIParent, f)
        CastAheadSetup.centerBox = centerBox
        f:SetScript("OnMouseDown", function() if active then CastAheadSetup.Select("center") end end)
        f:SetScript("OnMouseWheel", function(_, delta) if active then Wheel("center", delta) end end)
        f:SetScript("OnEnter", function() if active then Hover(centerBox, "center", true) end end)
        f:SetScript("OnLeave", function() if active then Hover(centerBox, "center", false) end end)
        local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("BOTTOM", f, "TOP", 0, 2)
        label:SetText(DRAG_LABEL)
        CastAheadSetup.centerLabel = label
    end
    return f
end

local function CancelTimeline()
    if not CastAheadTimeline then return end
    for _, track in pairs(tracks) do CastAheadTimeline.Cancel(track) end
end

local function Layout()
    local guess = panel.guess
    guess:SetShown(select(3, CastAheadCore.PlateSize()) == "guess")
    local body = panel.body
    body:ClearAllPoints()
    body:SetPoint("TOPLEFT", guess:IsShown() and guess or panel.hint, "BOTTOMLEFT", 0, -10)
    local h = 2 * PAD + panel.hint:GetStringHeight() + 10 + panel.bodyHeight + 8 + ROW_H
    if guess:IsShown() then h = h + guess:GetStringHeight() + 4 end
    if panel.note:IsShown() then h = h + panel.note:GetStringHeight() + 8 end
    panel:SetHeight(h)
end

local function BuildBody(body, W, T)
    local O = CastAheadOptions
    local y = 0
    local function Title(text)
        local title = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        title:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
        title:SetTextColor(unpack(T.gold))
        title:SetText(text)
        y = y + 18
        return title
    end
    local function Label(text)
        local label = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", body, "TOPLEFT", 4, -y - 10)
        label:SetText(text)
        return label
    end
    local function Number(key, text)
        local field = FIELDS[key]
        local label = Label(text)
        local box = CreateFrame("EditBox", nil, body, "InputBoxTemplate")
        box:SetSize(48, 20)
        box:SetPoint("TOPLEFT", body, "TOPLEFT", LABEL_W, -y)
        box:SetAutoFocus(false)
        local function Commit(self)
            local value = tonumber(self:GetText())
            if value and value == value and math.abs(value) ~= math.huge then SetField(key, value) else Refresh() end
        end
        box:SetScript("OnEditFocusLost", Commit)
        box:SetScript("OnEnterPressed", function(self)
            Commit(self)
            self:ClearFocus()
        end)
        box:SetScript("OnEscapePressed", function(self)
            Refresh()
            self:ClearFocus()
        end)
        local minus = W.Button(body, "-", 20)
        minus:SetPoint("LEFT", box, "RIGHT", 6, 0)
        minus:SetScript("OnClick", function() SetField(key, field.read() - field.step) end)
        local plus = W.Button(body, "+", 20)
        plus:SetPoint("LEFT", minus, "RIGHT", 2, 0)
        plus:SetScript("OnClick", function() SetField(key, field.read() + field.step) end)
        local row = { label = label, box = box, minus = minus, plus = plus }
        panel.fields[key] = row
        y = y + ROW_H
        return row
    end

    panel.iconsTitle = Title("Nameplate icons")
    panel.side, panel.grow = O.BuildPlacement(body, { "TOPLEFT", body, "TOPLEFT", 4, -y })
    y = y + 84
    Number("offsetX", "Distance")
    Number("nudgeX", "X")
    Number("nudgeY", "Y")
    Number("iconSize", "Icon")
    Number("labelScale", "Label")
    Number("timeScale", "Countdown")
    panel.fixedSpacing = O.BuildSwitch(body, "fixedSpacing", { "TOPLEFT", body, "TOPLEFT", 0, -y })
    y = y + 26
    Number("iconGap", "Gap")
    Label("Layer")
    panel.layer = O.BuildStrata(body, { "TOPLEFT", body, "TOPLEFT", LABEL_W, -y + 2 })
    y = y + 38

    panel.centreTitle = Title("Centre call")
    for _, axis in ipairs({ { "centerX", "X", "Center X" }, { "centerY", "Y", "Center Y" } }) do
        local key = axis[1]
        local row = Number(key, axis[2])
        row.center = W.Button(body, axis[3], 64)
        row.center:SetPoint("LEFT", row.plus, "RIGHT", 8, 0)
        row.center:SetScript("OnClick", function() SetField(key, 0) end)
    end
    Number("centerScale", "Size")
    Number("centerTextScale", "Text")
    body:SetHeight(y)
    panel.bodyHeight = y
end

local function Build()
    local W, T = CastAheadWindow, CastAheadWindow.THEME
    panel:SetBackdrop(W.FLAT)
    panel:SetBackdropColor(unpack(T.bg))
    panel:SetBackdropBorderColor(unpack(T.border))

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -PAD)
    hint:SetWidth(PANEL_W - 2 * PAD)
    hint:SetJustifyH("LEFT")
    hint:SetText(HINT)
    panel.hint = hint
    local guess = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    guess:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -4)
    guess:SetWidth(PANEL_W - 2 * PAD)
    guess:SetJustifyH("LEFT")
    guess:SetTextColor(unpack(T.muted))
    guess:SetText(GUESS)
    panel.guess = guess

    local body = CreateFrame("Frame", nil, panel)
    body:SetWidth(PANEL_W - 2 * PAD)
    panel.body = body
    panel.fields = {}
    BuildBody(body, W, T)

    local timeline = W.Button(panel, "Timeline...", 80)
    timeline:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD, PAD)
    local reset = W.Button(panel, "Reset", 60)
    reset:SetPoint("LEFT", timeline, "RIGHT", 6, 0)
    reset:SetScript("OnClick", function()
        if StaticPopup_Show then StaticPopup_Show("CASTAHEAD_SETUP_RESET") end
    end)
    local done = W.Button(panel, "Done", 60, true)
    done:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD, PAD)
    done:SetScript("OnClick", function() CastAheadSetup.Leave() end)
    local note = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("BOTTOMLEFT", timeline, "TOPLEFT", 0, 8)
    note:SetWidth(PANEL_W - 2 * PAD)
    note:SetJustifyH("LEFT")
    note:SetText(TIMELINE_NOTE)
    note:Hide()
    timeline:SetScript("OnClick", function()
        note:Show()
        Layout()
    end)
    panel.timeline, panel.reset, panel.done, panel.note = timeline, reset, done, note
end

StaticPopupDialogs.CASTAHEAD_SETUP_RESET = {
    text = "Put every setting this mode changes back to its default?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function()
        for _, key in ipairs(RESET_KEYS) do CastAheadConfig.Set(key, nil) end
        CastAheadCore.Reapply()
        CastAheadCore.ResizeCenter()
        Refresh()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function CastAheadSetup.Active()
    return active
end

function CastAheadSetup.Enter()
    if InCombatLockdown() then return false, "combat" end
    if active then return true end
    local ok, err = pcall(function()
        for i = 1, 40 do AddUnit("nameplate" .. i) end
    end)
    if not ok then
        for key in pairs(rows) do HideRow(key) end
        error(err, 0)
    end
    CastAheadCore.StopTest(true)
    local window = CastAheadWindow.Frame()
    page = window and window:IsShown() and CastAheadWindow.Current() or nil
    if window then window:Hide() end
    active = true
    editKey, editFrame = "sample", nil
    if catcher.SetPassThroughButtons then catcher:SetPassThroughButtons("RightButton") end
    catcher:Show()
    Rechoose()
    CastAheadCore.Reapply()
    CastAheadCore.ShowCenterSample(true)
    HookCenter():EnableMouseWheel(true)
    SizeThinLines()
    FeedTimeline(GetTime())
    for _, event in ipairs(EVENTS) do panel:RegisterEvent(event) end
    panel:EnableKeyboard(true)
    if not panel.fields then Build() end
    panel.note:Hide()
    Layout()
    panel:Show()
    CastAheadSetup.Select("row")
    Refresh()
    return true
end

function CastAheadSetup.Leave()
    if not active then return end
    CastAheadSetup.DropRow()
    CastAheadCore.DropCenter()
    active = false
    if not InCombatLockdown() then panel:SetPropagateKeyboardInput(true) end
    panel:EnableKeyboard(false)
    HookCenter():EnableMouseWheel(false)
    catcher:Hide()
    grip:Hide()
    grip._a, grip._b = nil, nil
    editKey, editFrame = "sample", nil
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
    CancelTimeline()
    if StaticPopup_Hide then StaticPopup_Hide("CASTAHEAD_SETUP_RESET") end
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
        Rechoose()
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        HideRow(unit)
        Rechoose()
    elseif event == "PLAYER_TARGET_CHANGED" then
        Rechoose()
    else
        for key, state in pairs(rows) do
            local plate = key ~= "sample" and C_NamePlate.GetNamePlateForUnit(key)
            if plate then
                CastAheadCore.RememberPlateSize(plate)
                CastAheadCore.SampleStates[state] = plate
            end
        end
        SizePlate()
        SizeThinLines()
        CastAheadCore.Reapply()
    end
    if active then Layout() end
end)
panel:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" and not (StaticPopup_Visible and StaticPopup_Visible("CASTAHEAD_SETUP_RESET")) then
        CastAheadSetup.Leave()
        self:SetPropagateKeyboardInput(false)
        return
    end
    local dir = ARROWS[key]
    self:SetPropagateKeyboardInput(not dir)
    if dir then
        local step = IsShiftKeyDown() and 10 or 1
        CastAheadSetup.Nudge(dir[1] * step, dir[2] * step)
    end
end)
panel:SetScript("OnKeyUp", function(self, key)
    self:SetPropagateKeyboardInput(not ARROWS[key])
end)
panel:SetScript("OnUpdate", function()
    local now = GetTime()
    if editKey ~= "sample" and not Shown(editFrame) then Rechoose() end
    PlaceGrip()
    if CastAheadSetup.centerLabel then CastAheadSetup.centerLabel:SetShown(CastAheadCore.CenterFrame():IsShown()) end
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

function CastAheadSetup.Debug(say)
    say("setup: editable %s%s", editKey, dragging and " (dragging)" or "")
    local state = rows[editKey]
    for i, bar in ipairs(state and state.bars or {}) do
        local point, rel, relPoint, x, y = bar:GetPoint(1)
        say("setup bar %d: shown=%s size=%s icon=%s iconShown=%s label=%s point=%s %s %s %s %s", i,
            tostring(bar:IsShown()), tostring(bar._size), tostring(bar.icon:GetTexture()),
            tostring(bar.icon:IsShown()), tostring(bar.label:GetText()), tostring(point),
            rel and (rel.GetName and rel:GetName() or tostring(rel)) or "nil", tostring(relPoint), tostring(x), tostring(y))
    end
end
