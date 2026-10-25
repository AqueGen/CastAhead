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
local HINT = "Drag to move, mouse wheel to resize, arrow keys for single pixels. To check on real nameplates, stand near enemies or training dummies."
local TIMELINE_NOTE = "Move the timeline in the game's Edit Mode: Esc > Edit Mode."
local RESET_KEYS = { "anchor", "grow", "offsetX", "nudgeX", "nudgeY", "iconSize", "labelScale", "timeScale",
                     "centerX", "centerY", "centerScale", "centerTextScale" }
local OUTPUTS = { { "nameplates", "Nameplate icons" }, { "centerText", "Centre call" }, { "timeline", "Timeline" } }
local PANEL_W, PAD, ROW_H = 280, 12, 24
local BASE_H, MORE_H = 262, 340
local HALF_SCREEN_FALLBACK = 1000
local GUESS = "Sample size is a guess until a real nameplate is seen."
local PEEK_SECONDS = 2

local active = false
local rows = {}
local tracks = {}
local page
local refeedAt = 0
local selected = "row"
local dragging = false
local readoutUntil
local centerBox
local peeking, peekGen = {}, 0

local panel = CreateFrame("Frame", PANEL_NAME, UIParent, "BackdropTemplate")
panel:SetSize(PANEL_W, BASE_H)
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

local function Outline(parent, target)
    local box = CreateFrame("Frame", nil, parent)
    box:SetAllPoints(target or parent)
    for i, edge in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" },
                            { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local line = box:CreateTexture(nil, "OVERLAY")
        line:SetColorTexture(1, 0.82, 0, 1)
        line:SetPoint(edge[1])
        line:SetPoint(edge[2])
        Thin(line, i > 2)
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

local NUMBERS = {
    row = {
        unit = " px", notch = 1,
        { read = function() return CastAheadConfig.NudgeX() end,
          write = function(v) CastAheadConfig.Set("nudgeX", Clamp(v, CastAheadConfig.NUDGE_MAX)) end },
        { read = function() return CastAheadConfig.NudgeY() end,
          write = function(v) CastAheadConfig.Set("nudgeY", Clamp(v, CastAheadConfig.NUDGE_MAX)) end },
        { read = function() return CastAheadConfig.IconSize() end,
          write = function(v)
              local C = CastAheadConfig
              C.Set("iconSize", Within(Round(v), C.ICON_MIN, C.ICON_MAX))
          end },
    },
    center = {
        unit = "%", notch = 5,
        { read = function() return CenterNumber("centerX") end,
          write = function(v) CastAheadConfig.Set("centerX", Clamp(v, HalfScreen("GetWidth"))) end },
        { read = function() return CastAheadCore.CENTER_Y + CenterNumber("centerY") end,
          write = function(v)
              CastAheadConfig.Set("centerY", Clamp(v, HalfScreen("GetHeight")) - CastAheadCore.CENTER_Y)
          end },
        { read = function()
              local C = CastAheadConfig
              return C.Number("centerScale", C.CENTER_DEFAULT, C.CENTER_MIN, C.CENTER_MAX)
          end,
          write = function(v)
              local C = CastAheadConfig
              C.Set("centerScale", Within(Round(v), C.CENTER_MIN, C.CENTER_MAX))
          end },
    },
}

local function Refresh()
    if not panel.numbers then return end
    for i, number in ipairs(panel.numbers) do
        number.box:SetText(tostring(Round(NUMBERS[selected][i].read())))
        if number.center then number.center:SetShown(selected == "center") end
    end
    CastAheadOptions.Refresh()
end
CastAheadSetup.Refresh = Refresh

local function Apply()
    if selected == "center" then CastAheadCore.ResizeCenter() else CastAheadCore.Reapply() end
    Refresh()
end

local function SetNumber(i, value)
    NUMBERS[selected][i].write(value)
    Apply()
end

function CastAheadSetup.Select(which)
    selected = which
    grip.box:SetShown(which == "row")
    if centerBox then centerBox:SetShown(which == "center" and CastAheadCore.CenterFrame():IsShown()) end
    Refresh()
end

function CastAheadSetup.Nudge(dx, dy)
    local x, y = NUMBERS[selected][1], NUMBERS[selected][2]
    x.write(x.read() + dx)
    y.write(y.read() + dy)
    Apply()
end

function CastAheadSetup.Resize(notches)
    local numbers = NUMBERS[selected]
    local size = numbers[3]
    size.write(size.read() + notches * numbers.notch)
    Apply()
    ShowReadout(selected == "center" and CastAheadCore.CenterFrame() or grip, size.read() .. numbers.unit)
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
    Refresh()
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

local function CancelTimeline()
    if not CastAheadTimeline then return end
    for _, track in pairs(tracks) do CastAheadTimeline.Cancel(track) end
end

local function ShowOutput(key, on)
    if key == "nameplates" then
        CastAheadCore.Reapply()
    elseif key == "centerText" then
        CastAheadCore.ShowCenterSample(on)
        CastAheadSetup.Select(on and selected or "row")
    elseif on then
        FeedTimeline(GetTime())
    else
        CancelTimeline()
    end
end

local function Layout()
    local guess = panel.guess
    guess:SetShown(select(3, CastAheadCore.PlateSize()) == "guess")
    local first = panel.outputs.nameplates
    first:ClearAllPoints()
    first:SetPoint("TOPLEFT", guess:IsShown() and guess or panel.hint, "BOTTOMLEFT", -4, -8)
    local h = BASE_H + panel.hint:GetStringHeight()
    if guess:IsShown() then h = h + guess:GetStringHeight() + 4 end
    if panel.moreBody:IsShown() then h = h + MORE_H end
    if panel.note:IsShown() then h = h + panel.note:GetStringHeight() + 8 end
    panel:SetHeight(h)
end

local function BuildMore(body)
    local O = CastAheadOptions
    local last
    for i, key in ipairs({ "labelScale", "timeScale", "centerTextScale", "offsetX" }) do
        local point = i == 1 and { "TOPLEFT", body, "TOPLEFT", 6, -4 } or { "TOPLEFT", last, "BOTTOMLEFT", -6, -18 }
        last = O.BuildSlider(body, O.SliderSpec(key, point))
    end
    O.BuildPlacement(body, { "TOPLEFT", last, "BOTTOMLEFT", -6, -18 })
    body.built = true
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

    panel.outputs = {}
    local last = hint
    for i, output in ipairs(OUTPUTS) do
        local key = output[1]
        last = CastAheadOptions.BuildSwitch(panel, key,
            { "TOPLEFT", last, "BOTTOMLEFT", i == 1 and -4 or 0, i == 1 and -8 or -4 },
            function(on) ShowOutput(key, on) end, output[2])
        panel.outputs[key] = last
    end

    panel.numbers = {}
    for i, name in ipairs({ "X", "Y", "Size" }) do
        local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 4, -12 - (i - 1) * ROW_H)
        label:SetText(name)
        local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
        box:SetSize(48, 20)
        box:SetPoint("LEFT", label, "LEFT", 40, 0)
        box:SetAutoFocus(false)
        local function Commit(self)
            local value = tonumber(self:GetText())
            if value and value == value and math.abs(value) ~= math.huge then SetNumber(i, value) else Refresh() end
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
        local minus = W.Button(panel, "-", 20)
        minus:SetPoint("LEFT", box, "RIGHT", 6, 0)
        minus:SetScript("OnClick", function() SetNumber(i, NUMBERS[selected][i].read() - 1) end)
        local plus = W.Button(panel, "+", 20)
        plus:SetPoint("LEFT", minus, "RIGHT", 2, 0)
        plus:SetScript("OnClick", function() SetNumber(i, NUMBERS[selected][i].read() + 1) end)
        panel.numbers[i] = { label = label, box = box, minus = minus, plus = plus }
    end
    for i, text in ipairs({ "Center X", "Center Y" }) do
        local center = W.Button(panel, text, 64)
        center:SetPoint("LEFT", panel.numbers[i].plus, "RIGHT", 8, 0)
        center:SetScript("OnClick", function() SetNumber(i, 0) end)
        panel.numbers[i].center = center
    end

    local more = W.Button(panel, "More", 60)
    more:SetPoint("TOPLEFT", panel.numbers[3].label, "BOTTOMLEFT", 0, -14)
    local body = CreateFrame("Frame", nil, panel)
    body:SetSize(PANEL_W - 2 * PAD, MORE_H)
    body:SetPoint("TOPLEFT", more, "BOTTOMLEFT", 0, -8)
    body:Hide()
    more:SetScript("OnClick", function()
        if not body.built then BuildMore(body) end
        body:SetShown(not body:IsShown())
        Layout()
    end)
    panel.more, panel.moreBody = more, body

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
    peeking, peekGen = {}, peekGen + 1
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
    SizeThinLines()
    FeedTimeline(GetTime())
    for _, event in ipairs(EVENTS) do panel:RegisterEvent(event) end
    panel:EnableKeyboard(true)
    if not panel.numbers then Build() end
    panel.moreBody:Hide()
    panel.note:Hide()
    Layout()
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
    if not InCombatLockdown() then panel:SetPropagateKeyboardInput(true) end
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
    CancelTimeline()
    if StaticPopup_Hide then StaticPopup_Hide("CASTAHEAD_SETUP_RESET") end
    panel:Hide()
    if page then CastAheadWindow.Show(page) end
    page = nil
end

local function EndPeek(gen)
    if active or gen ~= peekGen then return end
    if peeking.row then
        HideRow("sample")
        CastAheadSetup.plate:Hide()
    end
    if peeking.center then CastAheadCore.ShowCenterSample(false) end
    peeking = {}
end

function CastAheadSetup.Peek(kind)
    if active then return end
    if kind == "row" then
        local plate = SamplePlate()
        SizePlate()
        plate:Show()
        ShowRow("sample", plate)
    else
        CastAheadCore.ShowCenterSample(true)
    end
    peeking[kind] = true
    peekGen = peekGen + 1
    local gen = peekGen
    C_Timer.After(PEEK_SECONDS, function() EndPeek(gen) end)
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
        SizeThinLines()
        CastAheadCore.Reapply()
    end
    if active then Layout() end
end)
panel:SetScript("OnKeyDown", function(self, key)
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
