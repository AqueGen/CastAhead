CastAheadOptions = {}

CastAheadOptions.TABS = { "General", "Sounds", "Defensives", "Development", "Report" }
local panels = {}
local T = CastAheadWindow.THEME
local FLAT = CastAheadWindow.FLAT
local COL_W, COL_GAP, COL_X = 250, 8, 8
local SLIDER_W = COL_W - 40

-- Shown groups stack in one column, each as wide as the page; a hidden one
-- leaves no gap. Controls inside keep COL_W-based widths from the left edge.
function CastAheadOptions.RelayoutGroups(panel)
    local top = panel.flowTop or 6
    if type(top) == "function" then top = top() end
    local y = 0
    for _, g in ipairs(panel.groups) do
        if g:IsShown() then
            local pad = g.flowPad or 0
            g:ClearAllPoints()
            g:SetPoint("TOPLEFT", panel, "TOPLEFT", COL_X, -(top + y + pad))
            g:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -COL_X, -(top + y + pad))
            y = y + pad + g:GetHeight() + COL_GAP
        end
    end
    local total = math.max(y - COL_GAP, 0)
    panel:SetHeight(top + total + (panel.flowBottom and panel.flowBottom(top + total) or 0) + 12)
end

-- Forward declarations: Build calls these, and Lua resolves a local by
-- what it holds at call time, so they must exist as upvalues before it runs.
local BuildGeneral, BuildSounds, BuildDefensives, BuildDevelopment, BuildReport
-- Widgets are painted once, when a panel is first built, but storage can
-- change behind their back: the /ca anchor|grow|offset|center slash commands
-- and the setup mode all write it. Every widget that displays stored state
-- registers a closure here that re-reads it; showing a panel runs the lot.
local refreshers = {}

-- Every stored number is edited the same way - a caption that reads back the
-- value, a slider under it, and a refresher so a slash command changing the
-- same setting is reflected here. `spec` carries min/max/step, the caption
-- text and what to do after a change.
local function BuildSlider(panel, spec)
    local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint(unpack(spec.point))
    local slider = CreateFrame("Frame", nil, panel, "MinimalSliderWithSteppersTemplate")
    slider:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 6, -12)
    slider:SetSize(spec.width or SLIDER_W, 19)
    for corner, edge in pairs({ BOTTOMLEFT = slider.MinText, BOTTOMRIGHT = slider.MaxText }) do
        edge:ClearAllPoints()
        edge:SetPoint("TOP", slider.Slider, corner, 0, -1)
        edge:SetFontObject("GameFontHighlightSmall")
        edge:SetTextColor(unpack(T.muted))
    end

    local suppress = false
    local function read()
        return spec.read and spec.read()
            or CastAheadConfig.Number(spec.key, spec.default, spec.min, spec.max)
    end
    local function paint(value)
        label:SetText(spec.caption(value))
    end
    local function show(value)
        suppress = true
        slider:SetValue(value)
        suppress = false
        paint(value)
    end
    local step = spec.step or 1
    local L = MinimalSliderWithSteppersMixin.Label
    slider:Init(read(), spec.min, spec.max, (spec.max - spec.min) / step, {
        [L.Min] = function() return spec.low or tostring(spec.min) end,
        [L.Max] = function() return spec.high or tostring(spec.max) end,
    })
    show(read())
    slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
        if suppress then return end
        value = math.floor(value / step + 0.5) * step
        if spec.write then spec.write(value) else CastAheadConfig.Set(spec.key, value) end
        paint(value)
        if spec.after then spec.after(value) end
    end, slider)
    table.insert(refreshers, function() show(read()) end)
    slider.Repaint = function() show(read()) end
    return slider, label
end
CastAheadOptions.BuildSlider = BuildSlider

local function Refresh()
    for _, refresh in ipairs(refreshers) do refresh() end
end
CastAheadOptions.Refresh = Refresh

local function Redraw()
    if CastAheadCore and CastAheadCore.Reapply then CastAheadCore.Reapply() end
end

local function OutputChanged()
    Redraw()
    if CastAheadSetup and CastAheadSetup.OutputsChanged then CastAheadSetup.OutputsChanged() end
end

local function SaveRefresh()
    if CastAheadSaves then CastAheadSaves.Refresh() end
end

local function RedrawAndSaves()
    Redraw()
    SaveRefresh()
end

function CastAheadOptions.SavesSwitchChanged()
    SaveRefresh()
    CastAheadOptions.RefreshDefensives()
    if CastAheadUI and CastAheadUI.RefreshTabs then CastAheadUI.RefreshTabs() end
    if CastAheadUI and CastAheadUI.RefreshSaves then CastAheadUI.RefreshSaves() end
    Refresh()
end

function CastAheadOptions.RaidSavesChanged()
    CastAheadOptions.SavesSwitchChanged()
    local inRaid = GetInstanceInfo and select(2, GetInstanceInfo()) == "raid"
    if not CastAheadConfig.RaidSaves() and inRaid and CastAheadSaves then
        CastAheadSaves.CancelPrefix("dbm:")
        CastAheadSaves.CancelPrefix("bw:")
    end
    Redraw()
end

-- Every switch the General page offers, with the group it belongs to. The
-- page used to be one flat column of checkboxes plus a pile of sliders on the
-- right, and nothing said which slider went with which switch - the centre
-- call's size sat next to the nameplate anchor.
--
-- `defaultOff` marks the ones that are off until asked for; everything else
-- follows the storage convention, where nil means on.
local SWITCHES = {
    importantOnly = { label = "Important casts only",
        tip = "Show, speak and time only the casts marked Important on the Casts page - the hand-picked set that needs a reaction." },
    roleFilter = { label = "My role only",
        tip = "Hide calls this character cannot act on: dispels you do not have, tank busters for tanks and healers." },
    nameplates = { label = "Show icons on nameplates",
        tip = "Countdown icons next to enemy nameplates." },
    centerText = { label = "Show the centre call",
        tip = "The response in words, big, near the middle of the screen while an important cast goes out." },
    timeline = { label = "Feed the Blizzard timeline",
        tip = "Feed confident predictions to the game's own encounter timeline." },
    bigwigsBars = { label = "Show in BigWigs bars",
        tip = "BigWigs turns the game's timeline off and leaves other addons' entries out of its bars. While the game's timeline is off, the same predictions show as BigWigs bars instead. It uses a part of BigWigs that is not an official addon API, so a BigWigs update may stop it working." },
    sound = { label = "Sound",
        tip = "Master switch for everything the addon plays." },
    voice = { label = "Voice",
        tip = "Speak the response out loud: \"tank buster\", \"dodge\", \"kick\"." },
    kickFocusOnly = { label = "Kick calls only for my focus", defaultOff = true,
        tip = "With an enemy focus, only its casts get the kick call; other mobs keep their icons. Without a focus, or with a friendly or dead one, every mob is called. The focus's raid mark does not matter." },
    fixedSpacing = { label = "Fixed spacing", defaultOff = true,
        tip = "Space the icons evenly: each step is the icon width plus the Gap, however long the words under the icons are. Every row looks the same; two long words side by side may overlap." },
    fullLabels = { label = "Full labels", defaultOff = true,
        tip = "Write the long calls out in full under a nameplate icon: TANKBUSTER instead of BUSTER. Unless Fixed spacing is on, longer words push the icons further apart. Off, the longest calls are shortened (BUSTER, DEF, SOON) and the rows stay tight. The cast table and the voice always use the full word." },
    devMode = { label = "Development mode", defaultOff = true,
        tip = "Adds the Development tab and starts recording data that helps improve the addon (the Record everything switch there, on by default). It does not change what the addon calls out." },
    recordAll = { label = "Record everything",
        tip = "Records the game's combat log with advanced logging in every dungeon (it stops when you leave, unless you started it yourself), a journal of each key, and what the game lets an addon read from each enemy cast. The journal holds 12 keys. When it is full it asks you to reload so the data reaches the disk; then copy it off and clear it on this tab. No player names are recorded." },
    saveCalls = { label = "Defensive calls in dungeons", defaultOff = true,
        tip = "In dungeons and the open world, call a defensive ahead of damage that needs one, and show your button for it in the centre. Raids have their own switch." },
    bossAdapter = { label = "Boss calls from DBM / BigWigs",
        tip = "Also call defensives for boss abilities announced by DBM or BigWigs." },
    raidMode = { label = "Raid (experimental)", defaultOff = true,
        tip = "Turns the raid features below on and off together. Off, none of them runs and the Raid section leaves the menu; each keeps its own setting for when you turn this back on." },
    raidSaves = { label = "Defensive calls in raids", defaultOff = true,
        tip = "In raids, call a defensive for a dangerous boss debuff on you, timed to when its damage hits in top-player fights. Does not need the dungeon switch." },
    burstCalls = { label = "Burst windows", defaultOff = true,
        tip = "On bosses with a phase worth bursting into, say \"burst now\" when it starts, with a countdown in the centre block, and \"burst soon\" ahead of it if the slider below is set. Healers get their own phases for group-healing cooldowns. On every other boss it stays silent: press on cooldown." },
    showMarkPanel = { label = "Mark panel", defaultOff = true,
        tip = "A panel on screen to mark a wrong call on a mob you pick, with an optional note, and to open the report. Only while recording. The key bindings and /ca mark work without it." },
}
CastAheadOptions.Switches = SWITCHES

local function SwitchOn(key)
    if SWITCHES[key].defaultOff then return CastAheadConfig.Get(key) == true end
    return CastAheadConfig.Enabled(key)
end

local function SetSwitch(key, on)
    if SWITCHES[key].defaultOff then
        CastAheadConfig.Set(key, on and true or false)
    else
        CastAheadConfig.SetEnabled(key, on)
    end
end
CastAheadOptions.SetSwitch = SetSwitch

-- `free` keeps the group out of the column flow, for one the caller places itself.
-- No `title` leaves the heading to the caller, who puts a switch there.
local function BuildGroup(panel, title, height, free)
    local box = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    box:SetFrameLevel(panel:GetFrameLevel())
    box:SetSize(COL_W, height)
    if not free then table.insert(panel.groups, box) end
    box:SetBackdrop(FLAT)
    box:SetBackdropColor(unpack(T.panel))
    box:SetBackdropBorderColor(unpack(T.border))
    if title then
        box.title = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        box.title:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -8)
        box.title:SetTextColor(unpack(T.gold))
        box.title:SetText(title)
    end
    return box
end
CastAheadOptions.BuildGroup = BuildGroup

local STAGE_X, STAGE_MIN_W = COL_W + 10, 300

local function Desaturate(frame, off)
    for _, region in ipairs({ frame:GetRegions() }) do
        if region.SetDesaturated then region:SetDesaturated(off) end
    end
    for _, child in ipairs({ frame:GetChildren() }) do Desaturate(child, off) end
end

-- The empty right part of a group, right of the control column: a live
-- picture or a plain sentence beside each control it explains, top to bottom
-- in the order they are added. The group grows when they need more height
-- than its controls.
local function BuildStage(panel, group)
    local stage, items = {}, {}
    local controlsHeight = group:GetHeight()
    group.stage = stage

    local function Muted(text)
        local fs = group:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        fs:SetTextColor(unpack(T.muted))
        fs:SetText(text)
        return fs
    end

    -- `spec.build(canvas)` makes the frames once, `spec.paint(canvas)` draws
    -- the current settings and returns the drawn size, `spec.on()` says
    -- whether the feature is on, `spec.off` names what is off.
    function stage.Picture(control, spec)
        local canvas = CreateFrame("Frame", nil, group)
        spec.build(canvas)
        items[#items + 1] = { control = control, canvas = canvas, spec = spec, off = Muted(spec.off) }
    end

    function stage.Line(control, text)
        items[#items + 1] = { control = control, line = Muted(text) }
    end

    -- Offsets are measured from the group's top edge, as SetPoint takes them.
    function stage.Paint()
        local width = group:GetWidth() - STAGE_X
        local wide = width >= STAGE_MIN_W
        local top = group:GetTop()
        local floor, need = -8, 0
        for _, item in ipairs(items) do
            local ctop, cbottom = item.control:GetTop(), item.control:GetBottom()
            local known = top and ctop and cbottom
            if item.line then
                local y = math.min(known and ctop - top or -26, floor)
                item.line:ClearAllPoints()
                item.line:SetPoint("TOPLEFT", group, "TOPLEFT", STAGE_X, y)
                item.line:SetPoint("RIGHT", group, "RIGHT", -10, 0)
                floor = y - item.line:GetStringHeight() - 6
                need = math.max(need, 4 - floor)
            elseif not wide then
                item.canvas:Hide()
                item.off:SetShown(false)
            else
                local canvas, on = item.canvas, item.spec.on()
                local w, h = item.spec.paint(canvas)
                local scale = w > 0 and math.min(1, (width - 10) / w) or 1
                local tall = h * scale
                local mid = known and (ctop + cbottom) / 2 - top or -36
                local y = math.min(mid + tall / 2, floor)
                canvas:SetScale(scale)
                canvas:ClearAllPoints()
                canvas:SetPoint("TOPLEFT", group, "TOPLEFT", STAGE_X / scale, y / scale)
                canvas:SetAlpha(on and 1 or 0.35)
                Desaturate(canvas, not on)
                canvas:Show()
                -- The line's room is kept while on, so the group keeps its shape.
                item.off:ClearAllPoints()
                item.off:SetPoint("TOPLEFT", group, "TOPLEFT", STAGE_X, y - tall - 4)
                item.off:SetShown(not on)
                floor = y - tall - 4 - item.off:GetStringHeight() - 6
                need = math.max(need, 4 - floor)
            end
        end
        local height = math.max(controlsHeight, need)
        if math.abs(group:GetHeight() - height) > 0.5 then
            group:SetHeight(height)
            panel:Relayout()
        end
        return need
    end

    group:HookScript("OnSizeChanged", stage.Paint)
    table.insert(refreshers, stage.Paint)
    return stage
end
CastAheadOptions.BuildStage = BuildStage

-- One switch, placed against whatever the caller anchors it to.
local function BuildSwitch(panel, key, point, onClick, label)
    local option = SWITCHES[key]
    label = label or option.label
    local box = CreateFrame("CheckButton", nil, panel, "MinimalCheckboxTemplate")
    box:SetPoint(unpack(point))
    box.text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    box.text:SetPoint("LEFT", box, "RIGHT", 2, 0)
    box.text:SetText(label)
    box:SetHitRectInsets(0, -(box.text:GetStringWidth() + 6), 0, 0)
    box:SetChecked(SwitchOn(key))
    box:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        SetSwitch(key, on)
        if onClick then onClick(on) else Redraw() end
    end)
    box:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(label, 1, 1, 1)
        GameTooltip:AddLine(option.tip, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    box:SetScript("OnLeave", GameTooltip_Hide)
    table.insert(refreshers, function() box:SetChecked(SwitchOn(key)) end)
    return box
end
CastAheadOptions.BuildSwitch = BuildSwitch

local function BuildPlacement(panel, point)
    local anchorLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    anchorLabel:SetPoint(unpack(point))
    anchorLabel:SetText("Side")

    local square = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    square:SetSize(58, 58)
    square:SetPoint("TOPLEFT", anchorLabel, "BOTTOMLEFT", 4, -6)
    square:SetBackdrop(FLAT)
    square:SetBackdropColor(unpack(T.bg))
    square:SetBackdropBorderColor(unpack(T.border))
    local grid = {
        { "topleft", "top", "topright" },
        { "left", "center", "right" },
        { "bottomleft", "bottom", "bottomright" },
    }
    local current = CastAheadConfig.Get("anchor") or "left"
    local dots = {}
    for row = 1, 3 do
        for column = 1, 3 do
            local side = grid[row][column]
            local dot = CreateFrame("CheckButton", nil, square, "UIRadioButtonTemplate")
            dot:SetPoint("TOPLEFT", square, "TOPLEFT", 4 + (column - 1) * 18, -(4 + (row - 1) * 18))
            dot:SetChecked(side == current)
            dot:SetScript("OnClick", function()
                CastAheadUI.SetAnchor(side)
                for _, other in ipairs({ square:GetChildren() }) do other:SetChecked(false) end
                dot:SetChecked(true)
            end)
            dots[side] = dot
        end
    end
    table.insert(refreshers, function()
        local side = CastAheadConfig.Get("anchor") or "left"
        for dotSide, dot in pairs(dots) do dot:SetChecked(dotSide == side) end
    end)

    local growLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    growLabel:SetPoint("TOPLEFT", square, "TOPRIGHT", 16, -2)
    growLabel:SetText("Grow")
    local growDropdown = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    growDropdown:SetSize(110, 24)
    growDropdown:SetPoint("TOPLEFT", growLabel, "BOTTOMLEFT", 0, -4)
    growDropdown:SetupMenu(function(_, root)
        for _, direction in ipairs({ "auto", "left", "down", "right", "up" }) do
            root:CreateRadio(direction,
                function() return (CastAheadConfig.Get("grow") or "auto") == direction end,
                function() CastAheadUI.SetGrowth(direction) end)
        end
    end)
    table.insert(refreshers, function() growDropdown:GenerateMenu() end)
    return square, growDropdown
end
CastAheadOptions.BuildPlacement = BuildPlacement

local function BuildStrata(panel, point)
    local strataDropdown = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    strataDropdown:SetSize(150, 24)
    strataDropdown:SetPoint(unpack(point))
    strataDropdown:SetupMenu(function(_, root)
        for _, name in ipairs(CastAheadConfig.STRATA) do
            root:CreateRadio(name,
                function() return CastAheadConfig.Strata() == name end,
                function()
                    CastAheadConfig.Set("strata", name ~= CastAheadConfig.STRATA_DEFAULT and name or nil)
                    Redraw()
                end)
        end
    end)
    table.insert(refreshers, function() strataDropdown:GenerateMenu() end)
    strataDropdown:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Layer", 1, 1, 1)
        GameTooltip:AddLine("Which layer the icons draw on. BACKGROUND sits above nameplates and under the rest of the UI, like a plate. Pick a higher layer to draw over your bars and frames, DIALOG or higher if your nameplate addon raises its plates.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    strataDropdown:SetScript("OnLeave", GameTooltip_Hide)
    return strataDropdown
end
CastAheadOptions.BuildStrata = BuildStrata

local BUILDERS

-- Each page is built once, inside the host the main window hands over for
-- it, and stays there. Moving one panel between hosts on every show left it
-- without a rect after its host had been hidden and shown again.
local function Build(host, name)
    local panel = CreateFrame("Frame", nil, host)
    panel:SetPoint("TOPLEFT", host, "TOPLEFT")
    panel:SetPoint("TOPRIGHT", host, "TOPRIGHT")
    panel.groups = {}
    panel.Relayout = function(self)
        CastAheadOptions.RelayoutGroups(self)
        if self:IsVisible() then self:GetParent():SetHeight(self:GetHeight()) end
    end
    -- Width comes from the anchors and reads 0 until the next layout, so
    -- the flow has to run again once the panel has its real size.
    panel:SetScript("OnSizeChanged", function(self, width)
        if width > 0 then self:Relayout() end
    end)
    panels[name] = panel
    BUILDERS[name](panel)
    return panel
end

-- Every stateful widget is repainted first: the slash commands write the same
-- storage from outside, so what was drawn last time may be stale.
function CastAheadOptions.ShowPanel(host, name)
    local panel = panels[name] or Build(host, name)
    Refresh()
    panel:Relayout()
end

if StaticPopupDialogs then
    StaticPopupDialogs.CASTAHEAD_RESET_ALL = {
        text = "Reset every CastAhead setting, list and window position to a new install, then reload the UI? Recorded data stays.",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function()
            CastAheadConfig.ResetAll()
            ReloadUI()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

-- Groups in reading order: what is announced at all first, then the places
-- it is drawn. Each group carries its own on/off switch, so nothing has to be
-- traced across the page.
function BuildGeneral(panel)
    local setup = CastAheadWindow.Button(panel, "Size and position", 160, true)
    setup:SetPoint("TOPLEFT", panel, "TOPLEFT", COL_X, -8)
    setup:SetScript("OnClick", function() CastAheadSetup.Enter() end)
    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", setup, "RIGHT", 12, 0)
    hint:SetTextColor(0.67, 0.67, 0.67)
    hint:SetText("Best done near training dummies, so the icons show on real nameplates.")
    local function PaintSetup(_, event)
        local fighting = event == "PLAYER_REGEN_DISABLED" or (event ~= "PLAYER_REGEN_ENABLED" and InCombatLockdown())
        setup:SetEnabled(not fighting)
    end
    setup:RegisterEvent("PLAYER_REGEN_DISABLED")
    setup:RegisterEvent("PLAYER_REGEN_ENABLED")
    setup:SetScript("OnEvent", PaintSetup)
    PaintSetup()
    table.insert(refreshers, PaintSetup)
    panel.flowTop = 40

    local how = BuildGroup(panel, "Limits", 60)
    local howText = how:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    howText:SetJustifyH("LEFT")
    howText:SetTextColor(0.8, 0.8, 0.8)
    howText:SetSpacing(3)
    howText:SetPoint("TOPLEFT", how, "TOPLEFT", 10, -26)
    howText:SetPoint("RIGHT", how, "RIGHT", -10, 0)
    howText:SetText("- The addon is often silent on the first cast of a mob. It starts with the second cast.\n"
        .. "- If you always interrupt a mob, the addon may say nothing for that mob.\n"
        .. "- Some calls are wrong: about 5 to 8 calls in 100.")
    how:SetScript("OnSizeChanged", function(self)
        local height = 26 + howText:GetStringHeight() + 10
        if math.abs(self:GetHeight() - height) > 0.5 then
            self:SetHeight(height)
            panel:Relayout()
        end
    end)

    local what = BuildGroup(panel, "What to call out", 262)
    local important = BuildSwitch(panel, "importantOnly",
        { "TOPLEFT", what, "TOPLEFT", 10, -26 })
    local role = BuildSwitch(panel, "roleFilter",
        { "TOPLEFT", important, "BOTTOMLEFT", 0, -4 })
    local timeline = BuildSwitch(panel, "timeline",
        { "TOPLEFT", role, "BOTTOMLEFT", 0, -4 }, OutputChanged)
    local PaintTimelineOff
    local bigwigs = BuildSwitch(panel, "bigwigsBars",
        { "TOPLEFT", timeline, "BOTTOMLEFT", 0, -4 }, function()
            OutputChanged()
            PaintTimelineOff()
        end)
    -- BigWigs turns the game's timeline off by default and leaves our entries
    -- out of its bars (DBM shows them as its own bars). A line appears only
    -- while the entries cannot be seen, and says what to do; the BigWigs
    -- switch only with BigWigs installed.
    local timelineOff = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    timelineOff:SetJustifyH("LEFT")
    timelineOff:SetTextColor(1, 0.5, 0.2)
    local _, leadLabel = BuildSlider(panel, {
        key = "leadSeconds",
        default = CastAheadConfig.LEAD_DEFAULT,
        min = 0, max = CastAheadConfig.LEAD_MAX,
        low = "off", high = CastAheadConfig.LEAD_MAX .. "s",
        point = { "TOPLEFT", timelineOff, "BOTTOMLEFT", 2, -10 },
        caption = function(value)
            return value > 0
                and string.format("Early warning: %ds", value)
                or "Early warning: off"
        end,
    })
    -- The box is as tall as what it holds: the warning line takes room only while it
    -- has something to say, and the slider moves up under the switches when it does not
    function PaintTimelineOff()
        local off = C_EncounterTimeline and C_EncounterTimeline.IsFeatureEnabled
            and not C_EncounterTimeline.IsFeatureEnabled()
        local bigWigs = type(BigWigsLoader) == "table"
        bigwigs:SetShown(bigWigs)
        local last = bigWigs and bigwigs or timeline
        local text
        if off and bigWigs and not CastAheadConfig.Enabled("bigwigsBars") then
            text = "BigWigs has the game's timeline off: tick Show in BigWigs bars, or turn on its Blizzard timeline."
        elseif off and not bigWigs then
            text = "The game's timeline is switched off."
        end
        timelineOff:ClearAllPoints()
        timelineOff:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 4, -2)
        timelineOff:SetPoint("RIGHT", what, "RIGHT", -10, 0) -- wraps to the box at any window width
        timelineOff:SetText(text or "")
        timelineOff:SetShown(text ~= nil)
        leadLabel:ClearAllPoints()
        leadLabel:SetPoint("TOPLEFT", text and timelineOff or last, "BOTTOMLEFT", text and 2 or 6, -10)
        local switches = bigWigs and 4 or 3
        what:SetHeight(26 + switches * 26 + (text and timelineOff:GetStringHeight() + 2 or 0) + 92)
        -- The boxes below were placed for the old height
        panel:Relayout()
    end
    PaintTimelineOff()
    table.insert(refreshers, PaintTimelineOff)

    local audio = BuildGroup(panel, "Sound", 126)
    local sound = BuildSwitch(panel, "sound", { "TOPLEFT", audio, "TOPLEFT", 10, -26 }, RedrawAndSaves)
    local voice = BuildSwitch(panel, "voice", { "TOPLEFT", sound, "BOTTOMLEFT", 0, -4 }, RedrawAndSaves)
    local focusOnly = BuildSwitch(panel, "kickFocusOnly", { "TOPLEFT", voice, "BOTTOMLEFT", 0, -4 })
    local kickNote = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    kickNote:SetJustifyH("LEFT")
    kickNote:SetTextColor(0.7, 0.7, 0.7)
    kickNote:SetSpacing(3)
    kickNote:SetPoint("TOPLEFT", focusOnly, "BOTTOMLEFT", 4, -2)
    kickNote:SetPoint("RIGHT", audio, "RIGHT", -10, 0)
    kickNote:SetText("On: only your focus target gets kick calls. If you have no focus, every mob gets them.\n"
        .. "Off: every mob gets kick calls.")
    audio:SetScript("OnSizeChanged", function(self)
        local height = 26 + 3 * focusOnly:GetHeight() + 2 * 4 + 2 + kickNote:GetStringHeight() + 12
        if math.abs(self:GetHeight() - height) > 0.5 then
            self:SetHeight(height)
            panel:Relayout()
        end
    end)

    local plates = BuildGroup(panel, "Nameplate icons", 100)
    local platesStage = BuildStage(panel, plates)
    local platesOn = BuildSwitch(panel, "nameplates", { "TOPLEFT", plates, "TOPLEFT", 10, -26 }, function()
        OutputChanged()
        platesStage.Paint()
    end)
    BuildSwitch(panel, "fullLabels", { "TOPLEFT", platesOn, "BOTTOMLEFT", 0, -4 }, function()
        Redraw()
        platesStage.Paint()
    end)
    platesStage.Picture(platesOn, {
        build = function(canvas)
            local plate = CreateFrame("Frame", nil, canvas)
            plate:SetSize(120, 10)
            local health = plate:CreateTexture(nil, "ARTWORK")
            health:SetAllPoints()
            health:SetColorTexture(0.75, 0.12, 0.1)
            local name = plate:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            name:SetPoint("BOTTOM", plate, "TOP", 0, 2)
            name:SetText("Training Dummy")
            canvas.plate = plate
        end,
        paint = function(canvas)
            local w, h, x, y = CastAheadCore.PreviewRow(canvas, canvas.plate)
            canvas.plate:ClearAllPoints()
            canvas.plate:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", x, y)
            -- The name sits above the plate and may reach past the icons.
            h = math.max(h, y + 10 + 16)
            canvas:SetSize(w, h)
            return w, h
        end,
        on = function() return CastAheadConfig.Enabled("nameplates") end,
        off = "Off - no icons on nameplates",
    })

    local centre = BuildGroup(panel, "Centre call", 70)
    BuildSwitch(panel, "centerText", { "TOPLEFT", centre, "TOPLEFT", 10, -26 }, OutputChanged)

    local features = BuildGroup(panel, "Features", 230)
    local calls = BuildSwitch(panel, "saveCalls", { "TOPLEFT", features, "TOPLEFT", 10, -26 }, CastAheadOptions.SavesSwitchChanged)
    local raidSaves, bursts, burstSoon, soonLabel
    local function PaintRaid()
        local on = SwitchOn("raidMode")
        local color = on and { 1, 1, 1 } or T.muted
        for _, child in ipairs({ raidSaves, bursts }) do
            child:SetEnabled(on)
            child.text:SetTextColor(unpack(color))
        end
        if burstSoon then
            burstSoon:SetAlpha(on and 1 or 0.5)
            soonLabel:SetTextColor(unpack(color))
        end
    end
    local function RaidChanged()
        CastAheadOptions.RaidSavesChanged()
        PaintRaid()
    end
    local raid = BuildSwitch(panel, "raidMode", { "TOPLEFT", calls, "BOTTOMLEFT", 0, -4 }, RaidChanged)
    raidSaves = BuildSwitch(panel, "raidSaves", { "TOPLEFT", raid, "BOTTOMLEFT", 16, -4 }, RaidChanged)
    bursts = BuildSwitch(panel, "burstCalls", { "TOPLEFT", raidSaves, "BOTTOMLEFT", 0, -4 }, RaidChanged)
    for _, child in ipairs({ raidSaves, bursts }) do
        if child.SetMotionScriptsWhileDisabled then child:SetMotionScriptsWhileDisabled(true) end
    end
    burstSoon, soonLabel = BuildSlider(panel, {
        key = "burstLeadSeconds",
        default = 0,
        min = 0, max = CastAheadConfig.BURST_LEAD_MAX,
        low = "off", high = CastAheadConfig.BURST_LEAD_MAX .. "s",
        point = { "TOPLEFT", bursts, "BOTTOMLEFT", 6, -8 },
        width = COL_W - 80,
        caption = function(value)
            return value > 0 and string.format("Burst soon: %ds before", value) or "Burst soon: off"
        end,
    })
    table.insert(refreshers, PaintRaid)

    -- A Test button at the right end of a feature's row shows that feature alone.
    local function TestButton(switch, indent, tip, run)
        local button = CastAheadWindow.Button(panel, "Test", 44)
        button:SetPoint("LEFT", switch, "LEFT", COL_W - 10 - indent - 52, 0)
        button:SetScript("OnClick", function()
            if not run() then print("|cff33ff99CastAhead|r switch it on first, then press Test") end
        end)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Test", 1, 1, 1)
            GameTooltip:AddLine(tip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", GameTooltip_Hide)
    end
    TestButton(calls, 0, "One sample defensive call with your buttons, in the centre and out loud.",
        function() return CastAheadCore.FeatureTest("defensive") end)
    TestButton(bursts, 16, "A sample \"burst soon\", then \"burst now\" with its countdown.",
        function() return CastAheadCore.FeatureTest("burst") end)

    local extra = BuildGroup(panel, "Advanced", 97)
    local dev = BuildSwitch(panel, "devMode", { "TOPLEFT", extra, "TOPLEFT", 10, -26 }, function()
        if CastAheadCore and CastAheadCore.ApplyDevMode then CastAheadCore.ApplyDevMode() end
    end)
    local resetAll = CastAheadWindow.Button(panel, "Reset all settings", 130)
    resetAll:SetPoint("TOPLEFT", dev, "BOTTOMLEFT", 0, -10)
    resetAll:SetScript("OnClick", function()
        if StaticPopup_Show then StaticPopup_Show("CASTAHEAD_RESET_ALL") end
    end)
end

local function DevButton(panel, label, width, point, command, tip)
    local button = CastAheadWindow.Button(panel, label, width)
    button:SetPoint(unpack(point))
    button:SetScript("OnClick", function()
        SlashCmdList.CASTAHEAD(type(command) == "function" and command() or command)
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(label, 1, 1, 1)
        GameTooltip:AddLine(tip, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    return button
end

-- One switch records everything; the rest of the page only looks at it.
function BuildDevelopment(panel)
    local intro = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", panel, "TOPLEFT", COL_X, -6)
    intro:SetJustifyH("LEFT")
    intro:SetWordWrap(true)
    intro:SetText("|cffaaaaaaRecord everything: combat log in dungeons, key journal, enemy casts. Nothing on this page changes what the addon calls out.|r")
    panel:HookScript("OnSizeChanged", function(self, width)
        intro:SetWidth(math.max(width - 2 * COL_X, 1))
        if self:IsShown() then self:Relayout() end
    end)

    panel.flowTop = function() return 6 + intro:GetStringHeight() + 12 end
    local recording = BuildGroup(panel, "Recording", 100)
    local recordAll = BuildSwitch(panel, "recordAll", { "TOPLEFT", recording, "TOPLEFT", 10, -26 }, function()
        if CastAheadCore and CastAheadCore.ApplyDevMode then CastAheadCore.ApplyDevMode() end
    end)
    BuildSwitch(panel, "showMarkPanel", { "TOPLEFT", recordAll, "BOTTOMLEFT", 0, -4 }, function()
        if CastAheadReport then CastAheadReport.Refresh() end
    end)

    local group = BuildGroup(panel, "Recorded enemy data", 62)
    local show = DevButton(panel, "Show", 70, { "TOPLEFT", group, "TOPLEFT", 16, -28 },
        "probe show", "Print which facts each unit API returned readable, secret or empty. /ca probe show")
    local sweep = DevButton(panel, "Sweep", 70, { "LEFT", show, "RIGHT", 4, 0 },
        "probe sweep", "Print every Unit* function that returned something readable. /ca probe sweep")
    DevButton(panel, "Clear", 60, { "LEFT", sweep, "RIGHT", 4, 0 },
        "probe clear", "Forget the collected probe results. /ca probe clear")

    local journal = BuildGroup(panel, "Key journal", 62)
    local count = DevButton(panel, "Count", 70, { "TOPLEFT", journal, "TOPLEFT", 16, -28 },
        "journal", "Print how many keys the journal holds. /ca journal")
    DevButton(panel, "Clear journal", 110, { "LEFT", count, "RIGHT", 4, 0 },
        "journal clear", "Empty the journal after you copied it off the disk; asks first. /ca journal clear")
end

local function IconLabel(icon, name)
    return icon and string.format("|T%s:16|t %s", icon, name) or name
end

local function EntryLabel(e)
    if type(e) == "number" then
        return IconLabel(C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(e),
            C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(e) or tostring(e))
    end
    local use = type(e) == "table" and e.use
    if not use then return tostring(e) end
    local item = CastAheadSaves.ItemFor(use)
    local name = item and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(item)
        or "|cff888888" .. (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(use) or tostring(use)) .. " (not in bags)|r"
    local icon = item and C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(item)
        or C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(use)
    return IconLabel(icon, name)
end

local LIST_MIN_ROWS, LIST_ROW_H = 4, 20
local LIST_TOP = -48
local LIST_FOOT = 92

local function ListRows(store)
    local n = LIST_MIN_ROWS
    for _, key in ipairs(store.Keys()) do n = math.max(n, #store.EditList(key)) end
    return n
end

local function ListHeight(rows) return -LIST_TOP + rows * LIST_ROW_H + LIST_FOOT end

local listRefreshers = {}
function CastAheadOptions.RefreshDefensives()
    for _, refresh in ipairs(listRefreshers) do refresh() end
end

local addBoxes = {}
local function InsertLink(text)
    for _, box in ipairs(addBoxes) do
        if text and box:IsVisible() and box:HasFocus() then box:SetText(text) end
    end
end
if ChatFrameUtil and ChatFrameUtil.InsertLink then
    hooksecurefunc(ChatFrameUtil, "InsertLink", InsertLink)
elseif ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", InsertLink)
end

local function BuildButtonList(panel, store, key, title, emptyText)
    local group = BuildGroup(panel, title, ListHeight(LIST_MIN_ROWS))

    local function Remove(i)
        local list = {}
        for j, e in ipairs(store.EditList(key)) do
            if j ~= i then list[#list + 1] = e end
        end
        store.SetList(key, list)
        Refresh()
    end

    local function RowMenu(owner, i)
        if not (MenuUtil and MenuUtil.CreateContextMenu) or not store.EditList(key)[i] then return end
        MenuUtil.CreateContextMenu(owner, function(_, root)
            root:CreateButton("Remove", function() Remove(i) end)
        end)
    end

    local rows = {}
    local function Row(i)
        if rows[i] then return rows[i] end
        local y = LIST_TOP - (i - 1) * LIST_ROW_H
        local hit = CreateFrame("Button", nil, group)
        hit:SetSize(COL_W - 92, LIST_ROW_H)
        hit:SetPoint("TOPLEFT", group, "TOPLEFT", 8, y)
        hit:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        hit:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        hit:SetScript("OnClick", function(self) RowMenu(self, i) end)
        local text = group:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT", group, "TOPLEFT", 12, y - 4)
        text:SetWidth(COL_W - 98)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        local remove = CastAheadWindow.Button(group, "X", 20)
        remove:SetPoint("TOPRIGHT", group, "TOPLEFT", COL_W - 8, y)
        remove:SetScript("OnClick", function() Remove(i) end)
        local function Arrow(dir, x, step, tip)
            local b = CreateFrame("Button", nil, group)
            b:SetSize(22, 22)
            b:SetPoint("TOPRIGHT", group, "TOPLEFT", COL_W + x, y + 1)
            local file = "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-"
            b:SetNormalTexture(file .. "Up")
            b:SetPushedTexture(file .. "Down")
            b:SetDisabledTexture(file .. "Disabled")
            b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
            if dir == "Up" then
                for _, tex in ipairs({ b:GetNormalTexture(), b:GetPushedTexture(), b:GetDisabledTexture() }) do
                    tex:SetTexCoord(0, 1, 1, 0)
                end
            end
            b:SetScript("OnClick", function()
                store.Shift(key, i, step)
                Refresh()
            end)
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(tip, 1, 1, 1)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", GameTooltip_Hide)
            return b
        end
        local up = Arrow("Up", -54, -1, "Move up: called before the one above")
        local down = Arrow("Down", -31, 1, "Move down")
        rows[i] = { text = text, remove = remove, hit = hit, up = up, down = down }
        return rows[i]
    end

    local box = CreateFrame("EditBox", nil, group, "InputBoxTemplate")
    box:SetSize(COL_W - 96, 20)
    box:SetAutoFocus(false)
    addBoxes[#addBoxes + 1] = box
    local add = CastAheadWindow.Button(group, "Add", 56)
    add:SetPoint("LEFT", box, "RIGHT", 6, 0)
    local pick = CreateFrame("DropdownButton", nil, group, "WowStyle1DropdownTemplate")
    pick:SetSize(COL_W - 28, 24)
    pick:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, -6)
    if pick.SetDefaultText then pick:SetDefaultText("Add from list") end
    pick:SetupMenu(function(_, root)
        local entries = store.Addable(key)
        if #entries == 0 then
            root:CreateTitle("Nothing left to add")
            return
        end
        for _, e in ipairs(entries) do
            root:CreateButton(EntryLabel(e), function()
                local copy = { unpack(store.EditList(key)) }
                copy[#copy + 1] = type(e) == "table" and { use = e.use } or e
                store.SetList(key, copy)
                Refresh()
            end)
        end
    end)
    local reason = group:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    reason:SetPoint("TOPLEFT", pick, "BOTTOMLEFT", 0, -6)
    reason:SetWidth(COL_W - 24)
    reason:SetJustifyH("LEFT")

    local function Submit()
        local list = store.EditList(key)
        local entry, why = store.ParseEntry(box:GetText(), list)
        if not entry then
            reason:SetText(why)
            return
        end
        local copy = { unpack(list) }
        copy[#copy + 1] = entry
        store.SetList(key, copy)
        box:SetText("")
        box:ClearFocus()
        Refresh()
    end
    add:SetScript("OnClick", Submit)
    box:SetScript("OnEnterPressed", Submit)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        GameTooltip:AddLine("A spell id or a spell name you know, an item id, or a shift-clicked spell or item link. An item is stored by its use effect, so any item in your bags with that effect counts.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    box:SetScript("OnLeave", GameTooltip_Hide)

    local function Paint()
        local list = store.EditList(key)
        local n = ListRows(store)
        for i = 1, math.max(#list, #rows, 1) do
            local row = Row(i)
            row.text:SetText(list[i] and EntryLabel(list[i]) or "")
            row.remove:SetShown(list[i] ~= nil)
            row.hit:SetShown(list[i] ~= nil)
            row.up:SetShown(list[i] ~= nil)
            row.down:SetShown(list[i] ~= nil)
            row.up:SetEnabled(i > 1)
            row.down:SetEnabled(list[i + 1] ~= nil)
        end
        if #list == 0 then
            rows[1].text:SetText("|cffaaaaaa" .. emptyText .. "|r")
        end
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", group, "TOPLEFT", 18, LIST_TOP - n * LIST_ROW_H - 6)
        group:SetHeight(ListHeight(n))
        panel:Relayout()
        reason:SetText("")
    end
    table.insert(refreshers, Paint)
    table.insert(listRefreshers, Paint)
    return group
end

local DEFENSIVES_H, SPEC_BAR_PAD, OFF_ALPHA = 302, 34, 0.35
local REPORT_URL = "https://github.com/AqueGen/CastAhead/issues/new?template=report.yml"

local function CopyBox(parent, text, width)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetText(text)
    box:SetCursorPosition(0)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnTextChanged", function(self, typed)
        if typed then
            self:SetText(text)
            self:HighlightText()
        end
    end)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnEnterPressed", box.ClearFocus)
    return box
end

local function Caveat(parent, text, kind)
    local c = {}
    c.text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.text:SetJustifyH("LEFT")
    c.text:SetJustifyV("TOP")
    c.text:SetWordWrap(true)
    c.text:SetText("|cffd9a54aExperimental:|r |cffaaaaaa" .. text .. " Tell the author if anything is off.|r")
    c.button = CastAheadWindow.Button(parent, "Report", 70)
    c.button:SetScript("OnClick", function() CastAheadOptions.ShowReport(kind) end)
    function c.Place(x, y, width)
        c.text:ClearAllPoints()
        c.text:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
        c.text:SetWidth(width - 80)
        c.button:ClearAllPoints()
        c.button:SetPoint("TOPLEFT", c.text, "TOPLEFT", c.text:GetStringWidth() + 10, 4)
        return math.max(c.text:GetStringHeight(), 20)
    end
    function c.SetShown(on)
        c.text:SetShown(on)
        c.button:SetShown(on)
    end
    return c
end

function BuildDefensives(panel)
    if not CastAheadSaves then
        local note = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        note:SetPoint("TOPLEFT", panel, "TOPLEFT", COL_X, -6)
        note:SetText("Restart the game to finish the CastAhead update - defensive calls are off until then.")
        return
    end
    local group = BuildGroup(panel, "Defensive calls", DEFENSIVES_H)
    local Paint
    local calls = BuildSwitch(panel, "saveCalls", { "TOPLEFT", group, "TOPLEFT", 10, -26 }, CastAheadOptions.SavesSwitchChanged)
    local raidSaves = BuildSwitch(panel, "raidSaves", { "TOPLEFT", calls, "BOTTOMLEFT", 16, -4 }, CastAheadOptions.RaidSavesChanged)
    local boss = BuildSwitch(panel, "bossAdapter", { "TOPLEFT", calls, "BOTTOMLEFT", 0, -4 }, function(on)
        Redraw()
        if not on and CastAheadSaves then
            CastAheadSaves.CancelPrefix("dbm:")
            CastAheadSaves.CancelPrefix("bw:")
        end
    end)
    local status = boss:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", boss.text, "BOTTOMLEFT", 0, -2)
    local early, earlyLabel = BuildSlider(panel, {
        key = "saveLeadSeconds",
        default = 0,
        min = 0, max = CastAheadConfig.SAVE_LEAD_MAX,
        low = "off", high = CastAheadConfig.SAVE_LEAD_MAX .. "s",
        point = { "TOPLEFT", boss, "BOTTOMLEFT", 6, -34 },
        width = COL_W - 50,
        caption = function(value)
            return value > 0
                and string.format("Defensive early warning: %ds", value)
                or "Defensive early warning: off"
        end,
    })

    local store = CastAheadSaves.Store
    local list = BuildButtonList(panel, store, "def", "Defensive", "Empty - no defensive call")
    CastAheadWindow.SpecBar(list, 0, -SPEC_BAR_PAD, Refresh, function()
        return (panel:GetRight() or 0) - (list:GetLeft() or 0)
    end)
    panel:HookScript("OnSizeChanged", CastAheadWindow.PaintSpecBars)
    list.flowPad = SPEC_BAR_PAD
    table.insert(refreshers, CastAheadWindow.PaintSpecBars)

    local reset = CastAheadWindow.Button(panel, "Reset to default", 110)
    reset:SetPoint("TOPLEFT", early, "BOTTOMLEFT", -10, -24)
    local caveat = Caveat(panel, "the hits, their timings and the shipped button lists come from logs and may be wrong or missing.", "save")
    reset:SetScript("OnClick", function()
        if StaticPopup_Show then StaticPopup_Show("CASTAHEAD_RESET_SAVES") end
    end)

    local note = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetJustifyH("LEFT")
    note:SetJustifyV("TOP")
    note:SetWordWrap(true)
    note:SetText("|cffaaaaaaNo shipped defensive lists for this specialization.|r")
    panel.flowBottom = function(y)
        local width, h = math.max(panel:GetWidth() - 2 * COL_X, 1), 0
        if note:IsShown() then
            note:ClearAllPoints()
            note:SetPoint("TOPLEFT", panel, "TOPLEFT", COL_X, -(y + 10))
            note:SetWidth(width)
            h = note:GetStringHeight() + 10
        end
        if caveat.text:IsShown() then h = h + 10 + caveat.Place(COL_X, y + h + 10, width) end
        return h
    end

    Paint = function()
        local on = CastAheadConfig.DungeonSaves() or CastAheadConfig.RaidSaves()
        local spec = CastAheadSaves and CastAheadSaves.ViewSpecID()
        local shipped = spec and CastAheadSaveButtons and CastAheadSaveButtons[spec] and true or false
        status:SetText("|cffaaaaaa" .. (CastAheadBossAdapter and CastAheadBossAdapter.Status() or "No boss mod") .. "|r")
        local raid = CastAheadConfig.Get("raidMode") == true
        raidSaves:SetShown(raid)
        boss:ClearAllPoints()
        if raid then
            boss:SetPoint("TOPLEFT", raidSaves, "BOTTOMLEFT", -16, -4)
        else
            boss:SetPoint("TOPLEFT", calls, "BOTTOMLEFT", 0, -4)
        end
        local alpha = on and 1 or OFF_ALPHA
        for _, w in ipairs({ boss, early, earlyLabel, list, reset, caveat.text, caveat.button, note }) do w:SetAlpha(alpha) end
        note:SetShown(not shipped)
        list:SetShown(shipped)
        reset:SetShown(shipped)
        panel:Relayout()
    end
    table.insert(refreshers, Paint)
    table.insert(listRefreshers, Paint)
end

local BURST_DIFFICULTIES = { { 14, "Normal" }, { 15, "Heroic" }, { 16, "Mythic" }, { 8, "Keys" } }
local REPORT_KINDS = {
    { key = "cast", label = "Wrong trash call", ask = "Anything else about what happened:",
      what = { "Called, but the mob never cast it", "Cast, but CastAhead said nothing", "Named the wrong spell",
               "Called too early", "Called too late", "Wrong call type (kick, dodge, AoE...)" } },
    { key = "save", label = "Wrong defensive call", ask = "Anything else about what happened:",
      what = { "Needed a defensive", "No defensive was needed", "No call at all",
               "Called too early", "Called too late" } },
    { key = "burst", label = "Burst timing off", ask = "The time it called and what fit your group better:",
      what = { "Called too early", "Called too late", "Not a phase worth bursting", "A burst phase it missed" } },
    { key = "bug", label = "Bug or error", ask = "What you did and what went wrong (paste any Lua error):",
      what = { "Lua error", "Something on screen looks wrong", "A setting does not work" } },
    { key = "idea", label = "Idea", ask = "What would help you:" },
}
local LEVEL_MIN, LEVEL_MAX, LEVEL_DEFAULT = 2, 40, 12
local REPORT_OFTEN = { "Every time", "Sometimes", "Once" }
local function NewPicks() return { level = LEVEL_DEFAULT } end
local reportKind, pick = "cast", NewPicks()

local function OnOff(on) return on and "on" or "off" end

local function KindOf(key)
    for _, k in ipairs(REPORT_KINDS) do if k.key == key then return k end end
    return REPORT_KINDS[1]
end

local function InPlay(key) return key == "cast" or key == "save" end

function CastAheadOptions.SetReportPicks(picks) pick = picks or NewPicks() end

function CastAheadOptions.ReportText(key)
    local kind = KindOf(key)
    local meta = C_AddOns and C_AddOns.GetAddOnMetadata
    local game, build
    if GetBuildInfo then game, build = GetBuildInfo() end
    local lines = {
        "CastAhead report: " .. kind.label,
        string.format("Addon %s, game %s (%s), %s", meta and meta("CastAhead", "Version") or "?", game or "?", build or "?",
            GetLocale and GetLocale() or "?"),
    }
    local spec = CastAheadSaves and CastAheadSaves.SpecID()
    local info = spec and GetSpecializationInfoByID and { GetSpecializationInfoByID(spec) }
    lines[#lines + 1] = "Spec: " .. (info and string.format("%s %s", info[2] or "?", info[7] or "?") or "none")
    local dungeon = pick.dungeon or CastAheadWindow.Dungeon and CastAheadWindow.Dungeon()
    if kind.key == "burst" then
        for _, d in ipairs(BURST_DIFFICULTIES) do
            if d[1] == (pick.boss and pick.boss.diff or CastAheadWindow.RaidDifficulty()) then
                lines[#lines + 1] = pick.boss and string.format("Boss: %s (%s, encounter %d)", pick.boss.name, d[2], pick.boss.id)
                    or "Burst guide: " .. d[2]
            end
        end
        if not pick.boss then
            lines[#lines + 1] = "Dungeon picked: " .. (dungeon and CastAheadData[dungeon] and CastAheadData[dungeon].name or "?")
        end
        lines[#lines + 1] = "Burst windows: " .. OnOff(CastAheadConfig.BurstCalls())
    elseif kind.key ~= "idea" then
        lines[#lines + 1] = "Dungeon picked: " .. (dungeon and CastAheadData[dungeon] and CastAheadData[dungeon].name or "?")
        lines[#lines + 1] = string.format("Defensive calls: dungeons %s, raids %s, boss mod: %s",
            OnOff(SwitchOn("saveCalls")), OnOff(CastAheadConfig.RaidSaves()),
            CastAheadBossAdapter and CastAheadBossAdapter.Status() or "none")
    end
    if InPlay(kind.key) and pick.spell then
        lines[#lines + 1] = string.format("Spell: %s (%d) from %s", pick.spell.name, pick.spell.id, pick.spell.mob or "?")
    end
    if kind.what and pick.what then lines[#lines + 1] = "Problem: " .. pick.what end
    if InPlay(kind.key) and pick.level then lines[#lines + 1] = "Key level: +" .. pick.level end
    if kind.key ~= "idea" and pick.often then lines[#lines + 1] = "How often: " .. pick.often end
    if kind.key == "cast" and CastAheadConfig.Dev() then
        lines[#lines + 1] = "Key journal: paste the /ca report text below for exact timings."
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = kind.ask
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

function CastAheadOptions.ShowReport(key)
    if key and key ~= reportKind then reportKind, pick.spell, pick.what = key, nil, nil end
    if CastAheadUI and CastAheadUI.ShowTab then CastAheadUI.ShowTab("Report") end
end

local function SortedBy(list, field)
    table.sort(list, function(a, b) return a[field] < b[field] end)
    return list
end

local function Radios(root, values, field, after)
    for _, v in ipairs(values) do
        root:CreateRadio(v, function() return pick[field] == v end, function() pick[field] = v after() end)
    end
end

function BuildReport(panel)
    local intro = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", panel, "TOPLEFT", COL_X, -6)
    intro:SetJustifyH("LEFT")
    intro:SetText("|cffaaaaaaPick what it is about, finish the text in the box, copy all of it and paste it into a new GitHub issue or a CurseForge comment. No names of people are included.|r")
    panel.flowTop = 30
    local kinds = BuildGroup(panel, "What to report", 36 + #REPORT_KINDS * 24)
    local details = BuildGroup(panel, "Details", 60)
    local box, shownKind, Rebuild
    local buttons, rows = {}, {}

    local function Row(label, menu, control)
        local row = {}
        row.label = details:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.control = control
        if not control then
            row.control = CreateFrame("DropdownButton", nil, details, "WowStyle1DropdownTemplate")
            row.control:SetSize(COL_W - 104, 24)
            row.control:SetupMenu(function(_, root) menu(root) end)
        end
        row.title = label
        rows[#rows + 1] = row
        return row
    end

    local function SpellRadio(root, text, s, chosen, choose)
        local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(s.id)
        local radio = root:CreateRadio(icon and string.format("|T%s:16|t %s", icon, text) or text, chosen, choose)
        if radio.SetTooltip then radio:SetTooltip(function(tooltip) tooltip:SetSpellByID(s.id) end) end
    end

    local place = Row(function() return reportKind == "burst" and "Boss" or "Dungeon" end, function(root)
        if reportKind == "burst" then
            for _, d in ipairs(BURST_DIFFICULTIES) do
                local bosses = {}
                for id, byDifficulty in pairs(CastAheadBurstWindows or {}) do
                    local w = byDifficulty[d[1]]
                    if w then bosses[#bosses + 1] = { id = id, diff = d[1], name = w.name or tostring(id) } end
                end
                local sub = root:CreateButton(d[2])
                for _, boss in ipairs(SortedBy(bosses, "name")) do
                    sub:CreateRadio(boss.name,
                        function() return pick.boss and pick.boss.id == boss.id and pick.boss.diff == boss.diff end,
                        function() pick.boss = boss Rebuild() end)
                end
            end
            return
        end
        local dungeons = {}
        for id, data in pairs(CastAheadData) do dungeons[#dungeons + 1] = { id = id, name = data.name or tostring(id) } end
        for _, d in ipairs(SortedBy(dungeons, "name")) do
            root:CreateRadio(d.name,
                function() return (pick.dungeon or CastAheadWindow.Dungeon()) == d.id end,
                function() pick.dungeon, pick.spell = d.id, nil Rebuild() end)
        end
    end)
    place.kinds = { cast = true, save = true, burst = true, bug = true }

    local spell = Row(function() return "Spell" end, function(root)
        local dungeon = pick.dungeon or CastAheadWindow.Dungeon()
        local function Choose(s) return function() pick.spell = s Rebuild() end end
        local function Chosen(s) return function() return pick.spell and pick.spell.id == s.id end end
        if reportKind == "save" then
            local hits = {}
            for _, r in ipairs(CastAheadSaves and CastAheadSaves.ViewRows(dungeon) or {}) do
                hits[#hits + 1] = { id = r.id, name = r.name, mob = r.mob }
            end
            for _, s in ipairs(SortedBy(hits, "name")) do
                SpellRadio(root, string.format("%s (%s)", s.name, s.mob or "?"), s, Chosen(s), Choose(s))
            end
            return
        end
        local byMob, mobs = {}, {}
        for _, c in ipairs(CastAheadData[dungeon] or {}) do
            local mob = c.mob or "?"
            if not byMob[mob] then byMob[mob] = {} mobs[#mobs + 1] = { name = mob } end
            byMob[mob][#byMob[mob] + 1] = { id = c.spell, name = c.name or tostring(c.spell), mob = mob }
        end
        for _, m in ipairs(SortedBy(mobs, "name")) do
            local sub = root:CreateButton(m.name)
            for _, s in ipairs(SortedBy(byMob[m.name], "name")) do SpellRadio(sub, s.name, s, Chosen(s), Choose(s)) end
        end
    end)
    spell.kinds = { cast = true, save = true }

    local what = Row(function() return "Problem" end, function(root)
        Radios(root, KindOf(reportKind).what or {}, "what", function() Rebuild() end)
    end)
    what.kinds = { cast = true, save = true, burst = true, bug = true }

    local stepper = CreateFrame("Frame", nil, details)
    stepper:SetSize(COL_W - 104, 24)
    local levelBox = CreateFrame("EditBox", nil, stepper, "InputBoxTemplate")
    levelBox:SetSize(44, 20)
    levelBox:SetPoint("LEFT", stepper, "LEFT", 36, 0)
    levelBox:SetAutoFocus(false)
    levelBox:SetNumeric(true)
    levelBox:SetMaxLetters(2)
    levelBox:SetJustifyH("CENTER")
    local function SetLevel(value)
        pick.level = value and math.min(LEVEL_MAX, math.max(LEVEL_MIN, value)) or nil
        levelBox:SetText(pick.level and tostring(pick.level) or "")
        Rebuild()
    end
    levelBox:SetScript("OnTextChanged", function(self, typed)
        if not typed then return end
        local value = tonumber(self:GetText())
        pick.level = value and math.min(LEVEL_MAX, math.max(LEVEL_MIN, value)) or nil
        Rebuild()
    end)
    levelBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() SetLevel(pick.level) end)
    levelBox:SetScript("OnEscapePressed", levelBox.ClearFocus)
    local minus = CastAheadWindow.Button(stepper, "-", 28)
    minus:SetPoint("LEFT", stepper, "LEFT", 0, 0)
    minus:SetScript("OnClick", function() SetLevel(pick.level and pick.level - 1 or LEVEL_DEFAULT) end)
    local plus = CastAheadWindow.Button(stepper, "+", 28)
    plus:SetPoint("LEFT", levelBox, "RIGHT", 4, 0)
    plus:SetScript("OnClick", function() SetLevel(pick.level and pick.level + 1 or LEVEL_DEFAULT) end)
    local level = Row(function() return "Key level" end, nil, stepper)
    level.kinds = { cast = true, save = true }
    level.refresh = function()
        if not levelBox:HasFocus() then levelBox:SetText(pick.level and tostring(pick.level) or "") end
    end

    local often = Row(function() return "How often" end, function(root)
        Radios(root, REPORT_OFTEN, "often", function() Rebuild() end)
    end)
    often.kinds = { cast = true, save = true, burst = true, bug = true }

    local function Paint()
        if shownKind ~= reportKind then
            shownKind = reportKind
            box:SetText(CastAheadOptions.ReportText(reportKind))
        end
        for i, k in ipairs(REPORT_KINDS) do
            local on = k.key == reportKind
            buttons[i]:SetBackdropColor(unpack(on and T.selected or T.panel))
            buttons[i].label:SetTextColor(unpack(on and T.gold or T.text))
        end
        local y = -28
        for _, row in ipairs(rows) do
            local on = row.kinds[reportKind] == true
            row.label:SetShown(on)
            row.control:SetShown(on)
            if on then
                row.label:SetText(row.title())
                row.label:SetPoint("TOPLEFT", details, "TOPLEFT", 10, y - 6)
                row.control:SetPoint("TOPLEFT", details, "TOPLEFT", 90, y)
                if row.control.SetDefaultText then row.control:SetDefaultText("Pick one") end
                if row.control.GenerateMenu then row.control:GenerateMenu() end
                if row.refresh then row.refresh() end
                y = y - 30
            end
        end
        details:SetShown(y < -28)
        details:SetHeight(-y + 6)
        panel:Relayout()
    end
    Rebuild = function()
        local ask = KindOf(reportKind).ask .. "\n"
        local old = box:GetText()
        local _, stop = old:find(ask, 1, true)
        box:SetText(CastAheadOptions.ReportText(reportKind) .. (stop and old:sub(stop + 1) or ""))
        Paint()
    end
    for i, k in ipairs(REPORT_KINDS) do
        local b = CastAheadWindow.Button(kinds, k.label, COL_W - 20)
        b:SetPoint("TOPLEFT", kinds, "TOPLEFT", 10, -26 - (i - 1) * 24)
        b:SetScript("OnClick", function()
            if reportKind ~= k.key then pick.spell, pick.what = nil, nil end
            reportKind, shownKind = k.key, nil
            Paint()
        end)
        buttons[i] = b
    end

    local area = BuildGroup(panel, "Report text", 300, true)
    local scroll = CreateFrame("ScrollFrame", nil, area, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", area, "TOPLEFT", 10, -26)
    scroll:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", -30, 74)
    box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetFontObject(ChatFontNormal)
    box:SetAutoFocus(false)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    scroll:SetScrollChild(box)
    local all = CastAheadWindow.Button(area, "Select all", 90)
    all:SetPoint("BOTTOMLEFT", area, "BOTTOMLEFT", 10, 44)
    all:SetScript("OnClick", function()
        box:SetFocus()
        box:HighlightText()
    end)
    local fresh = CastAheadWindow.Button(area, "Start over", 90)
    fresh:SetPoint("LEFT", all, "RIGHT", 6, 0)
    fresh:SetScript("OnClick", function()
        pick, shownKind = NewPicks(), nil
        Paint()
    end)
    local copyHint = area:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    copyHint:SetPoint("LEFT", fresh, "RIGHT", 10, 0)
    copyHint:SetText("|cffaaaaaaCtrl+C copies the selection.|r")
    local where = area:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    where:SetPoint("BOTTOMLEFT", area, "BOTTOMLEFT", 10, 16)
    where:SetText("New GitHub issue:")
    local link = CopyBox(area, REPORT_URL, 420)
    link:SetPoint("LEFT", where, "RIGHT", 12, 0)

    panel.flowBottom = function(y)
        local width = math.max(panel:GetWidth() - 2 * COL_X, COL_W)
        intro:SetWidth(width)
        area:ClearAllPoints()
        area:SetPoint("TOPLEFT", panel, "TOPLEFT", COL_X, -(y + COL_GAP))
        area:SetWidth(width)
        box:SetWidth(width - 50)
        return area:GetHeight() + COL_GAP
    end
    table.insert(refreshers, Paint)
end

local SOUND_ROWS = { "KICK", "CC", "TANK", "AOE", "DODGE", "FRONTAL", "TARGET", "DISPEL",
    "POISON", "CURSE", "MAGIC", "DISEASE", "BLEED", "SOOTHE", "PURGE", "SWITCH", "ADDS", "ALERT",
    "DEFENSIVE", "SOON", "BURST" }
local SOUND_ROW_H = 26

-- Default plus every sound LibSharedMedia knows. Shared with the casts
-- table, where each row offers the same list for its own spell.
-- Each entry carries a speaker on its right (Blizzard's own pattern, see
-- CooldownViewerUtil.AddSoundAlertRadio), so a sound can be heard before it
-- is picked. `advice` is what Default stands for here.
function CastAheadOptions.SoundMenu(root, read, write, advice)
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    if root.SetScrollMode then root:SetScrollMode(20 * 20) end
    local function Speaker(radio, name)
        if not (MenuTemplates and MenuTemplates.AttachUtilityButton) then return end
        radio:AddInitializer(function(button)
            local play = MenuTemplates.AttachUtilityButton(button)
            play.Texture:Hide()
            play:SetNormalAtlas("chatframe-button-icon-speaker-on")
            play:SetHighlightAtlas("chatframe-button-icon-speaker-on")
            MenuTemplates.SetUtilityButtonAnchor(play, MenuVariants.GearButtonAnchor, button, 0, 0)
            MenuTemplates.SetUtilityButtonClickHandler(play, function()
                if CastAheadCore and CastAheadCore.PreviewMedia then CastAheadCore.PreviewMedia(name, advice) end
            end)
            if button.Layout then button:Layout() end
        end)
    end
    Speaker(root:CreateRadio("Voice", function() return read() == nil end, function() write(nil) end), nil)
    if lsm then
        for _, name in ipairs(lsm:List("sound")) do
            Speaker(root:CreateRadio(name, function() return read() == name end, function() write(name) end), name)
        end
    end
end

function BuildSounds(panel)
    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
    hint:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -4)
    hint:SetJustifyH("LEFT")
    hint:SetJustifyV("TOP")
    hint:SetWordWrap(true)
    hint:SetText("|cffaaaaaaVoice = the spoken call (a stock beep when it cannot speak). A sound plays instead of the voice.|r")

    -- Off by default: the shipped clips speak unless this is on. Gated on the
    -- game's own Combat Audio Alerts setting, which it cannot work without.
    local tts = CreateFrame("CheckButton", nil, panel, "MinimalCheckboxTemplate")
    tts:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", -4, -4)
    tts.text = tts:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tts.text:SetPoint("LEFT", tts, "RIGHT", 2, 0)
    local openGame = CastAheadWindow.Button(panel, "Open game options", 130)
    openGame:SetPoint("LEFT", tts.text, "RIGHT", 10, 0)
    openGame:SetScript("OnClick", function()
        if not (Settings and Settings.OpenToCategory) then return end
        local id
        for _, c in ipairs(SettingsPanel and SettingsPanel:GetAllCategories() or {}) do
            if c:GetName() == ACCESSIBILITY_AUDIO_LABEL then id = c:GetID() break end
        end
        Settings.OpenToCategory(id, CAA_ENABLE_COMBAT_AUDIO_ALERTS)
    end)
    local function PaintTTS()
        local api = C_CombatAudioAlert
        local gameOn = api and api.IsEnabled and api.IsEnabled()
        tts:SetEnabled(gameOn and true or false)
        tts.text:SetText(gameOn and "Game TTS voice"
            or "Game TTS voice |cffff6060(Combat Audio Alerts are off in the game's Accessibility options)|r")
        openGame:SetShown(not gameOn)
    end
    tts:RegisterEvent("CVAR_UPDATE")
    tts:SetScript("OnEvent", PaintTTS)
    tts:SetChecked(CastAheadDB and CastAheadDB.voiceTTS == true)
    PaintTTS()
    tts:SetScript("OnClick", function(self)
        CastAheadDB = CastAheadDB or {}
        CastAheadDB.voiceTTS = self:GetChecked() and true or nil
    end)
    tts:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Game TTS voice", 1, 1, 1)
        GameTooltip:AddLine("Use the game's built-in combat text-to-speech instead of the addon's recorded clips. Needs Combat Audio Alerts enabled in the game's Accessibility options; when it cannot speak, the clips play instead.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    tts:SetScript("OnLeave", GameTooltip_Hide)
    table.insert(refreshers, function()
        tts:SetChecked(CastAheadDB and CastAheadDB.voiceTTS == true)
        PaintTTS()
    end)

    local channelLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    channelLabel:SetPoint("TOPLEFT", tts, "BOTTOMLEFT", 4, -12)
    channelLabel:SetText("Sound channel")
    local channel = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    channel:SetSize(140, 22)
    channel:SetPoint("TOPLEFT", tts, "BOTTOMLEFT", 100, -6)
    channel:SetupMenu(function(_, root)
        for _, name in ipairs(CastAheadConfig.CHANNELS) do
            root:CreateRadio(name,
                function() return CastAheadConfig.SoundChannel() == name end,
                function()
                    CastAheadConfig.Set("soundChannel", name ~= CastAheadConfig.CHANNEL_DEFAULT and name or nil)
                    SaveRefresh()
                end)
        end
    end)
    table.insert(refreshers, function() channel:GenerateMenu() end)
    channel:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Sound channel", 1, 1, 1)
        GameTooltip:AddLine("Which of the game's volume sliders (Options > Sound) controls the calls. Master follows the master volume only; pick Dialog to set the calls apart and turn the game's effects down without losing them.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    channel:SetScript("OnLeave", GameTooltip_Hide)

    local body = CreateFrame("Frame", nil, panel)
    body:SetPoint("TOPLEFT", channel, "BOTTOMLEFT", -100, -10)
    body:SetSize(400, #SOUND_ROWS * SOUND_ROW_H)
    panel.flowTop = function()
        return 4 + hint:GetStringHeight() + 4 + tts:GetHeight() + 6 + channel:GetHeight() + 10
            + #SOUND_ROWS * SOUND_ROW_H
    end

    for i, key in ipairs(SOUND_ROWS) do
        local advice = CastAheadMatch.ADVICE[key]
        local y = -(i - 1) * SOUND_ROW_H
        local label = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("TOPLEFT", body, "TOPLEFT", 0, y - 6)
        label:SetWidth(90)
        label:SetJustifyH("LEFT")
        label:SetText(string.format("|cff%02x%02x%02x%s|r",
            advice.r * 255, advice.g * 255, advice.b * 255, advice.label))

        local dropdown = CreateFrame("DropdownButton", nil, body, "WowStyle1DropdownTemplate")
        dropdown:SetSize(240, 22)
        dropdown:SetPoint("TOPLEFT", body, "TOPLEFT", 96, y)
        dropdown:SetupMenu(function(_, root)
            CastAheadOptions.SoundMenu(root,
                function() return CastAheadDB and CastAheadDB.sounds and CastAheadDB.sounds[key] end,
                function(name)
                    CastAheadDB = CastAheadDB or {}
                    CastAheadDB.sounds = CastAheadDB.sounds or {}
                    CastAheadDB.sounds[key] = name
                    SaveRefresh()
                end, advice)
        end)

        local hear = CreateFrame("Button", nil, body)
        hear:SetSize(18, 18)
        hear:SetPoint("LEFT", dropdown, "RIGHT", 8, 0)
        hear:SetNormalAtlas("chatframe-button-icon-speaker-on")
        hear:SetHighlightAtlas("chatframe-button-icon-speaker-on")
        hear:SetScript("OnClick", function()
            if CastAheadCore and CastAheadCore.PreviewSound then CastAheadCore.PreviewSound(advice) end
        end)
    end
end

BUILDERS = { General = BuildGeneral, Sounds = BuildSounds, Defensives = BuildDefensives, Development = BuildDevelopment,
             Report = BuildReport }
local MENU_GROUPS = { Report = "Feedback" }

for _, name in ipairs(CastAheadOptions.TABS) do
    local host
    CastAheadWindow.Register(name, MENU_GROUPS[name] or "Settings",
        function(h) host = h end,
        function() CastAheadOptions.ShowPanel(host, name) end,
        nil, name == "Defensives")
end
