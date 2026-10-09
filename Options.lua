CastAheadOptions = {}

CastAheadOptions.TABS = { "General", "Sounds", "Defensives", "Development" }
local panels = {}
local T = CastAheadWindow.THEME
local FLAT = { bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 }
local COL_W, COL_GAP, COL_X = 250, 8, 8
local SLIDER_W = COL_W - 40

function CastAheadOptions.Flow(width, colWidth, gap, heights)
    local columns = math.max(1, math.floor((width + gap) / (colWidth + gap)))
    local bottoms = {}
    for c = 1, columns do bottoms[c] = 0 end
    local positions, total = {}, 0
    for i, h in ipairs(heights) do
        local c = 1
        for k = 2, columns do
            if bottoms[k] < bottoms[c] then c = k end
        end
        positions[i] = { x = (c - 1) * (colWidth + gap), y = bottoms[c] }
        bottoms[c] = bottoms[c] + h + gap
        total = math.max(total, bottoms[c] - gap)
    end
    return positions, total
end

function CastAheadOptions.RelayoutGroups(panel)
    local shown, heights = {}, {}
    for _, g in ipairs(panel.groups) do
        if g:IsShown() then
            shown[#shown + 1] = g
            heights[#heights + 1] = g:GetHeight()
        end
    end
    local pos, total = CastAheadOptions.Flow(panel:GetWidth() - COL_X, COL_W, COL_GAP, heights)
    local top = panel.flowTop or 6
    if type(top) == "function" then top = top() end
    for i, g in ipairs(shown) do
        g:ClearAllPoints()
        g:SetPoint("TOPLEFT", panel, "TOPLEFT", COL_X + pos[i].x, -(top + pos[i].y))
    end
    panel:SetHeight(top + total + (panel.flowBottom and panel.flowBottom() or 0) + 12)
end

-- Forward declarations: Build calls these, and Lua resolves a local by
-- what it holds at call time, so they must exist as upvalues before it runs.
local BuildGeneral, BuildSounds, BuildDefensives, BuildDevelopment
-- Widgets are painted once, when a panel is first built, but storage can
-- change behind their back: the /ca anchor|grow|offset|center slash commands
-- and the Move button all write it. Every widget that displays stored state
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
        CastAheadConfig.Set(spec.key, value)
        paint(value)
        if spec.after then spec.after(value) end
    end, slider)
    table.insert(refreshers, function() show(read()) end)
    return slider, label
end

local function Redraw()
    if CastAheadCore and CastAheadCore.Reapply then CastAheadCore.Reapply() end
end

local function SaveRefresh()
    if CastAheadSaves then CastAheadSaves.Refresh() end
end

local function RedrawAndSaves()
    Redraw()
    SaveRefresh()
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
        tip = "Show, speak and time only the casts marked with a star - the hand-picked set that needs a reaction." },
    roleFilter = { label = "My role only",
        tip = "Hide calls this character cannot act on: dispels you do not have, tank busters for tanks and healers." },
    nameplates = { label = "Show icons on nameplates",
        tip = "Countdown icons next to enemy nameplates." },
    centerText = { label = "Show the centre call", defaultOff = true,
        tip = "The response in words, big, near the middle of the screen while an important cast goes out." },
    timeline = { label = "Feed the Blizzard timeline",
        tip = "Feed confident predictions to the game's own encounter timeline." },
    sound = { label = "Sound",
        tip = "Master switch for everything the addon plays." },
    voice = { label = "Voice",
        tip = "Speak the response out loud: \"tank buster\", \"dodge\", \"interrupt\"." },
    fixedSpacing = { label = "Fixed spacing", defaultOff = true,
        tip = "Step sideways by the icon plus the gap below, whatever the words under the icons measure. Every row packs the same; two wide verdicts side by side may overlap." },
    fullLabels = { label = "Full labels", defaultOff = true,
        tip = "Spell the longest verdicts out under a nameplate icon - BUSTER becomes TANKBUSTER. The icons step sideways by the width of the words under them, so the full words spread the row out; off, every plate's widest word is six characters and the rows pack evenly. The cast table and the spoken call always use the whole word either way." },
    devMode = { label = "Development mode", defaultOff = true,
        tip = "Adds the Development tab and starts recording everything for improving the addon's data (the Record everything switch there, on by default). Nothing here changes what the addon calls out." },
    recordAll = { label = "Record everything",
        tip = "The game's combat log with advanced logging in every dungeon (off again when you leave, unless you had started it yourself), a journal of each key, and what the game lets an addon read off each enemy cast. Holds 12 keys: when the journal fills up it asks you to reload so it reaches the disk, then you copy it off and clear it on this tab. No names of people are recorded." },
    saveCalls = { label = "Defensive calls",
        tip = "Call a small or big defensive ahead of damage that needs one, and show your button for it in the centre." },
    bossAdapter = { label = "Boss calls from DBM / BigWigs",
        tip = "Also call defensives for boss abilities announced by DBM or BigWigs." },
    smallCalls = { label = "Small defensive calls",
        tip = "Say \"small defensive\" ahead of hits that need a small save." },
    bigCalls = { label = "Big defensive calls",
        tip = "Say \"big defensive\" ahead of hits that need a big save." },
    healCalls = { label = "Heal up after a big hit", defaultOff = true,
        tip = "Right after a hit that called a big defensive, say \"heal up\" when your Healthstone or potion is ready." },
    showMarkPanel = { label = "Mark panel", defaultOff = true,
        tip = "A panel on screen to mark a wrong call on a mob you pick, with an optional note, and to open the report. Only while recording. The key bindings and /ca mark work without it." },
}

local function SwitchOn(key)
    if SWITCHES[key].defaultOff then return CastAheadConfig.Get(key) == true end
    return CastAheadConfig.Enabled(key)
end

local function SetSwitch(key, on)
    if SWITCHES[key].defaultOff then
        CastAheadConfig.Set(key, on or nil)
    else
        CastAheadConfig.SetEnabled(key, on)
    end
end

local function BuildGroup(panel, title, height)
    local box = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    box:SetFrameLevel(panel:GetFrameLevel())
    box:SetSize(COL_W, height)
    table.insert(panel.groups, box)
    box:SetBackdrop(FLAT)
    box:SetBackdropColor(unpack(T.panel))
    box:SetBackdropBorderColor(unpack(T.border))
    box.title = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    box.title:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -8)
    box.title:SetTextColor(unpack(T.gold))
    box.title:SetText(title)
    return box
end

-- One switch, placed against whatever the caller anchors it to.
local function BuildSwitch(panel, key, point, onClick)
    local option = SWITCHES[key]
    local box = CreateFrame("CheckButton", nil, panel, "MinimalCheckboxTemplate")
    box:SetPoint(unpack(point))
    box.text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    box.text:SetPoint("LEFT", box, "RIGHT", 2, 0)
    box.text:SetText(option.label)
    box:SetHitRectInsets(0, -(box.text:GetStringWidth() + 6), 0, 0)
    box:SetChecked(SwitchOn(key))
    box:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        SetSwitch(key, on)
        if onClick then onClick(on) else Redraw() end
    end)
    box:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(option.label, 1, 1, 1)
        GameTooltip:AddLine(option.tip, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    box:SetScript("OnLeave", GameTooltip_Hide)
    table.insert(refreshers, function() box:SetChecked(SwitchOn(key)) end)
    return box
end

-- Sizes and offsets belong to the group that draws with them, so each group
-- resets its own rather than one button clearing settings across the page.
local function BuildReset(panel, point, keys, after)
    local reset = CastAheadWindow.Button(panel, "Reset", 70)
    reset:SetPoint(unpack(point))
    reset:SetScript("OnClick", function()
        for _, key in ipairs(keys) do CastAheadConfig.Set(key, nil) end
        for _, refresh in ipairs(refreshers) do refresh() end
        if after then after() end
    end)
    return reset
end

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
    host:HookScript("OnSizeChanged", function() panel:Relayout() end)
    panels[name] = panel
    BUILDERS[name](panel)
    return panel
end

-- Every stateful widget is repainted first: the slash commands write the same
-- storage from outside, so what was drawn last time may be stale.
function CastAheadOptions.ShowPanel(host, name)
    local panel = panels[name] or Build(host, name)
    for _, refresh in ipairs(refreshers) do refresh() end
    panel:Relayout()
end

-- Groups in reading order: what is announced at all first, then the places
-- it is drawn. Each group carries its own on/off switch, so nothing has to be
-- traced across the page.
function BuildGeneral(panel)
    -- What is announced ---------------------------------------------------
    local what = BuildGroup(panel, "What to call out", 204)
    local important = BuildSwitch(panel, "importantOnly",
        { "TOPLEFT", what, "TOPLEFT", 10, -26 })
    local role = BuildSwitch(panel, "roleFilter",
        { "TOPLEFT", important, "BOTTOMLEFT", 0, -4 })
    local timeline = BuildSwitch(panel, "timeline",
        { "TOPLEFT", role, "BOTTOMLEFT", 0, -4 })
    BuildSlider(panel, {
        key = "leadSeconds",
        default = CastAheadConfig.LEAD_DEFAULT,
        min = 0, max = CastAheadConfig.LEAD_MAX,
        low = "off", high = CastAheadConfig.LEAD_MAX .. "s",
        point = { "TOPLEFT", timeline, "BOTTOMLEFT", 6, -12 },
        caption = function(value)
            return value > 0
                and string.format("Early warning: %ds", value)
                or "Early warning: off"
        end,
    })

    -- Sound ---------------------------------------------------------------
    local audio = BuildGroup(panel, "Sound", 100)
    local sound = BuildSwitch(panel, "sound", { "TOPLEFT", audio, "TOPLEFT", 10, -26 }, RedrawAndSaves)
    BuildSwitch(panel, "voice", { "TOPLEFT", sound, "BOTTOMLEFT", 0, -4 }, RedrawAndSaves)

    -- Development mode ----------------------------------------------------
    local extra = BuildGroup(panel, "Advanced", 70)
    BuildSwitch(panel, "devMode", { "TOPLEFT", extra, "TOPLEFT", 10, -26 }, function()
        if CastAheadCore and CastAheadCore.ApplyDevMode then CastAheadCore.ApplyDevMode() end
    end)

    -- Where the icons go --------------------------------------------------
    local plates = BuildGroup(panel, "Nameplate icons", 417)
    local platesOn = BuildSwitch(panel, "nameplates", { "TOPLEFT", plates, "TOPLEFT", 10, -26 })
    BuildSwitch(panel, "fullLabels", { "TOPLEFT", platesOn, "BOTTOMLEFT", 0, -4 })

    local anchorLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    anchorLabel:SetPoint("TOPLEFT", plates, "TOPLEFT", 16, -96)
    anchorLabel:SetText("Position around the plate")

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

    local offsetSlider = BuildSlider(panel, {
        key = "offsetX",
        default = 0, min = 0, max = 120, step = 2,
        point = { "TOPLEFT", square, "BOTTOMLEFT", -4, -16 },
        caption = function(value)
            return string.format("Distance from the plate: %d px", value)
        end,
        after = Redraw,
    })

    local nudgeXSlider = BuildSlider(panel, {
        key = "nudgeX",
        default = 0,
        min = -CastAheadConfig.NUDGE_MAX, max = CastAheadConfig.NUDGE_MAX, step = 1,
        point = { "TOPLEFT", offsetSlider, "BOTTOMLEFT", -6, -18 },
        caption = function(value) return string.format("Nudge sideways: %+d px", value) end,
        after = Redraw,
    })

    local nudgeYSlider = BuildSlider(panel, {
        key = "nudgeY",
        default = 0,
        min = -CastAheadConfig.NUDGE_MAX, max = CastAheadConfig.NUDGE_MAX, step = 1,
        point = { "TOPLEFT", nudgeXSlider, "BOTTOMLEFT", -6, -18 },
        caption = function(value) return string.format("Nudge up or down: %+d px", value) end,
        after = Redraw,
    })

    BuildReset(panel, { "TOPLEFT", nudgeYSlider, "BOTTOMLEFT", -6, -22 },
        { "anchor", "grow", "offsetX", "nudgeX", "nudgeY" }, Redraw)

    -- How big they are ----------------------------------------------------
    -- Everything drawn on a nameplate icon in one place: the icon sets the
    -- size and the two texts on it are a share of that, so changing the icon
    -- keeps them in proportion.
    local sizes = BuildGroup(panel, "Icon size", 413)

    local iconSlider = BuildSlider(panel, {
        key = "iconSize",
        default = CastAheadConfig.ICON_DEFAULT,
        min = CastAheadConfig.ICON_MIN, max = CastAheadConfig.ICON_MAX, step = 2,
        point = { "TOPLEFT", sizes, "TOPLEFT", 16, -26 },
        caption = function(value) return string.format("Icon: %d px", value) end,
        after = Redraw,
    })

    local labelSlider = BuildSlider(panel, {
        key = "labelScale",
        default = CastAheadConfig.LABEL_DEFAULT,
        min = CastAheadConfig.LABEL_MIN, max = CastAheadConfig.LABEL_MAX, step = 5,
        low = CastAheadConfig.LABEL_MIN .. "%", high = CastAheadConfig.LABEL_MAX .. "%",
        point = { "TOPLEFT", iconSlider, "BOTTOMLEFT", -6, -18 },
        caption = function(value) return string.format("Label: %d%% of the icon", value) end,
        after = Redraw,
    })

    local timeSlider = BuildSlider(panel, {
        key = "timeScale",
        default = CastAheadConfig.TIME_DEFAULT,
        min = CastAheadConfig.TIME_MIN, max = CastAheadConfig.TIME_MAX, step = 5,
        low = CastAheadConfig.TIME_MIN .. "%", high = CastAheadConfig.TIME_MAX .. "%",
        point = { "TOPLEFT", labelSlider, "BOTTOMLEFT", -6, -18 },
        caption = function(value) return string.format("Countdown: %d%% of the icon", value) end,
        after = Redraw,
    })

    local fixedSpacing = BuildSwitch(panel, "fixedSpacing", { "TOPLEFT", timeSlider, "BOTTOMLEFT", -12, -18 })
    local gapSlider = BuildSlider(panel, {
        key = "iconGap",
        default = CastAheadConfig.GAP_DEFAULT, min = 0, max = CastAheadConfig.GAP_MAX, step = 1,
        point = { "TOPLEFT", fixedSpacing, "BOTTOMLEFT", 6, -4 },
        caption = function(value) return string.format("Gap: %d px", value) end,
        after = Redraw,
    })

    local strataLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    strataLabel:SetPoint("TOPLEFT", gapSlider, "BOTTOMLEFT", -6, -18)
    strataLabel:SetText("Layer (frame strata)")
    local strataDropdown = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    strataDropdown:SetSize(170, 24)
    strataDropdown:SetPoint("TOPLEFT", strataLabel, "BOTTOMLEFT", 0, -4)
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
        GameTooltip:AddLine("Where the icons draw among other frames. BACKGROUND sits above every nameplate and under the rest of the UI, like a plate does; go higher if you want the icons over your bars and frames, DIALOG or above if a nameplate addon lifts its plates into the UI.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    strataDropdown:SetScript("OnLeave", GameTooltip_Hide)

    BuildReset(panel, { "TOPLEFT", strataDropdown, "BOTTOMLEFT", -6, -14 },
        { "iconSize", "labelScale", "timeScale", "iconGap", "fixedSpacing", "strata" }, Redraw)

    -- Centre call ---------------------------------------------------------
    local centre = BuildGroup(panel, "Centre call", 229)
    BuildSwitch(panel, "centerText", { "TOPLEFT", centre, "TOPLEFT", 10, -26 })

    local centerScale = function()
        if CastAheadCore and CastAheadCore.ResizeCenter then CastAheadCore.ResizeCenter() end
    end
    local centerSlider = BuildSlider(panel, {
        key = "centerScale",
        default = CastAheadConfig.CENTER_DEFAULT,
        min = CastAheadConfig.CENTER_MIN, max = CastAheadConfig.CENTER_MAX, step = 5,
        low = CastAheadConfig.CENTER_MIN .. "%", high = CastAheadConfig.CENTER_MAX .. "%",
        point = { "TOPLEFT", centre, "TOPLEFT", 16, -63 },
        caption = function(value) return string.format("Size: %d%%", value) end,
        after = centerScale,
    })

    local centerTextSlider = BuildSlider(panel, {
        key = "centerTextScale",
        default = CastAheadConfig.CENTER_TEXT_DEFAULT,
        min = CastAheadConfig.CENTER_TEXT_MIN, max = CastAheadConfig.CENTER_TEXT_MAX, step = 5,
        low = CastAheadConfig.CENTER_TEXT_MIN .. "%", high = CastAheadConfig.CENTER_TEXT_MAX .. "%",
        point = { "TOPLEFT", centerSlider, "BOTTOMLEFT", -6, -18 },
        caption = function(value) return string.format("Text: %d%% of the block", value) end,
        after = centerScale,
    })

    local move = CastAheadWindow.Button(panel, "Move it on screen", 140)
    move:SetPoint("TOPLEFT", centerTextSlider, "BOTTOMLEFT", -6, -18)
    move:SetScript("OnClick", function()
        if CastAheadCore and CastAheadCore.MoveCenter then CastAheadCore.MoveCenter() end
    end)

    BuildReset(panel, { "LEFT", move, "RIGHT", 6, 0 },
        { "centerScale", "centerTextScale", "centerX", "centerY" }, centerScale)
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
local LIST_ORDER = { "small", "big", "heal" }

local function ListRows()
    local n = LIST_MIN_ROWS
    for _, size in ipairs(LIST_ORDER) do n = math.max(n, #CastAheadSaves.List(size)) end
    return n
end

local function ListHeight(rows) return -LIST_TOP + rows * LIST_ROW_H + LIST_FOOT end
local LIST_TITLES = { small = "Small defensive", big = "Big defensive", heal = "Heal after the hit" }

local function RefreshAll()
    for _, refresh in ipairs(refreshers) do refresh() end
end

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

local function BuildSaveList(panel, size, hint)
    local S = CastAheadSaves
    local title = LIST_TITLES[size]
    local group = BuildGroup(panel, title, ListHeight(LIST_MIN_ROWS))
    if hint then
        local line = group:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", group.title, "BOTTOMLEFT", 0, -3)
        line:SetWidth(COL_W - 20)
        line:SetJustifyH("LEFT")
        line:SetText("|cffaaaaaa" .. hint .. "|r")
    end

    local function Remove(i)
        local list = {}
        for j, e in ipairs(S.List(size)) do
            if j ~= i then list[#list + 1] = e end
        end
        S.SetList(size, list)
        RefreshAll()
    end

    local function RowMenu(owner, i)
        if not (MenuUtil and MenuUtil.CreateContextMenu) or not S.List(size)[i] then return end
        MenuUtil.CreateContextMenu(owner, function(_, root)
            for _, target in ipairs(LIST_ORDER) do
                if target ~= size then
                    root:CreateButton("Move to " .. LIST_TITLES[target], function()
                        S.MoveEntry(size, i, target)
                        RefreshAll()
                    end)
                end
            end
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
        remove:SetPoint("TOPRIGHT", group, "TOPRIGHT", -8, y)
        remove:SetScript("OnClick", function() Remove(i) end)
        local function Arrow(dir, x, step, tip)
            local b = CreateFrame("Button", nil, group)
            b:SetSize(22, 22)
            b:SetPoint("TOPRIGHT", group, "TOPRIGHT", x, y + 1)
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
                S.Shift(size, i, step)
                RefreshAll()
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
        local entries = S.Addable(size)
        if #entries == 0 then
            root:CreateTitle("Nothing left to add")
            return
        end
        for _, e in ipairs(entries) do
            root:CreateButton(EntryLabel(e), function()
                local copy = { unpack(S.List(size)) }
                copy[#copy + 1] = type(e) == "table" and { use = e.use } or e
                S.SetList(size, copy)
                RefreshAll()
            end)
        end
    end)
    local reason = group:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    reason:SetPoint("TOPLEFT", pick, "BOTTOMLEFT", 0, -6)
    reason:SetWidth(COL_W - 24)
    reason:SetJustifyH("LEFT")

    local function Submit()
        local list = S.List(size)
        local entry, why = S.ParseEntry(box:GetText(), list)
        if not entry then
            reason:SetText(why)
            return
        end
        local copy = { unpack(list) }
        copy[#copy + 1] = entry
        S.SetList(size, copy)
        box:SetText("")
        box:ClearFocus()
        RefreshAll()
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
        local list = S.List(size)
        local n = ListRows()
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
            rows[1].text:SetText(size == "heal" and "|cffaaaaaaEmpty - no heal up call|r"
                or "|cffaaaaaaEmpty - this call shows no button|r")
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

local DEFENSIVES_H, DEFENSIVES_OFF_H = 366, 56

function BuildDefensives(panel)
    local group = BuildGroup(panel, "Defensive calls", DEFENSIVES_H)
    local Paint
    local calls = BuildSwitch(panel, "saveCalls", { "TOPLEFT", group, "TOPLEFT", 10, -26 }, function()
        SaveRefresh()
        Paint()
    end)
    local boss = BuildSwitch(panel, "bossAdapter", { "TOPLEFT", calls, "BOTTOMLEFT", 0, -4 }, function(on)
        Redraw()
        if not on and CastAheadSaves then
            CastAheadSaves.CancelPrefix("dbm:")
            CastAheadSaves.CancelPrefix("bw:")
        end
    end)
    local status = boss:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("LEFT", boss.text, "RIGHT", 6, 0)
    local small = BuildSwitch(panel, "smallCalls", { "TOPLEFT", boss, "BOTTOMLEFT", 0, -4 }, SaveRefresh)
    local big = BuildSwitch(panel, "bigCalls", { "TOPLEFT", small, "BOTTOMLEFT", 0, -4 }, SaveRefresh)
    local heal = BuildSwitch(panel, "healCalls", { "TOPLEFT", big, "BOTTOMLEFT", 0, -4 })
    local early, earlyLabel = BuildSlider(panel, {
        key = "saveLeadSeconds",
        default = 0,
        min = 0, max = CastAheadConfig.SAVE_LEAD_MAX,
        low = "off", high = CastAheadConfig.SAVE_LEAD_MAX .. "s",
        point = { "TOPLEFT", heal, "BOTTOMLEFT", 6, -12 },
        width = COL_W - 50,
        caption = function(value)
            return value > 0
                and string.format("Save early warning: %ds", value)
                or "Save early warning: off"
        end,
    })

    local lists = {
        BuildSaveList(panel, "small"),
        BuildSaveList(panel, "big"),
        BuildSaveList(panel, "heal", "Pressed right after a big hit lands: stone, potion, self-heal."),
    }

    local reset = CastAheadWindow.Button(panel, "Reset to default", 110)
    reset:SetPoint("TOPLEFT", early, "BOTTOMLEFT", -10, -24)
    reset:SetScript("OnClick", function()
        if StaticPopup_Show then StaticPopup_Show("CASTAHEAD_RESET_SAVES") end
    end)

    local note = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", group, "BOTTOMLEFT", 0, -10)
    note:SetJustifyH("LEFT")
    note:SetJustifyV("TOP")
    note:SetWordWrap(true)
    panel:HookScript("OnSizeChanged", function(self, width)
        note:SetWidth(math.max(width - 2 * COL_X, 1))
        if self:IsShown() then self:Relayout() end
    end)
    note:SetText("|cffaaaaaaNo shipped defensive lists for this specialization.|r")
    panel.flowBottom = function() return note:IsShown() and note:GetStringHeight() + 10 or 0 end

    Paint = function()
        local on = SwitchOn("saveCalls")
        local spec = CastAheadSaves and CastAheadSaves.SpecID()
        local shipped = spec and CastAheadSaveButtons and CastAheadSaveButtons[spec] and true or false
        status:SetText("|cffaaaaaa" .. (CastAheadBossAdapter and CastAheadBossAdapter.Status() or "No boss mod") .. "|r")
        for _, w in ipairs({ boss, small, big, heal, early, earlyLabel }) do w:SetShown(on) end
        group:SetHeight(on and DEFENSIVES_H or DEFENSIVES_OFF_H)
        note:SetShown(on and not shipped)
        for _, list in ipairs(lists) do list:SetShown(on and shipped) end
        reset:SetShown(on and shipped)
        panel:Relayout()
    end
    table.insert(refreshers, Paint)
    table.insert(listRefreshers, Paint)
end

local SOUND_ROWS = { "KICK", "CC", "TANK", "AOE", "DODGE", "FRONTAL", "TARGET", "DISPEL",
    "POISON", "CURSE", "MAGIC", "DISEASE", "BLEED", "SOOTHE", "PURGE", "SWITCH", "ALERT",
    "SMALL", "BIG", "HEAL" }
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
    local function PaintTTS()
        local api = C_CombatAudioAlert
        local gameOn = api and api.IsEnabled and api.IsEnabled()
        tts:SetEnabled(gameOn and true or false)
        tts.text:SetText(gameOn and "Game TTS voice"
            or "Game TTS voice |cffff6060(off in game Sound options)|r")
    end
    tts:SetChecked(CastAheadDB and CastAheadDB.voiceTTS == true)
    PaintTTS()
    tts:SetScript("OnClick", function(self)
        CastAheadDB = CastAheadDB or {}
        CastAheadDB.voiceTTS = self:GetChecked() and true or nil
    end)
    tts:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Game TTS voice", 1, 1, 1)
        GameTooltip:AddLine("Use the game's built-in combat text-to-speech instead of the addon's recorded clips. Needs Combat Audio Alerts enabled in the game's Sound options; when it cannot speak, the clips play instead.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    tts:SetScript("OnLeave", GameTooltip_Hide)
    table.insert(refreshers, function()
        tts:SetChecked(CastAheadDB and CastAheadDB.voiceTTS == true)
        PaintTTS()
    end)

    local body = CreateFrame("Frame", nil, panel)
    body:SetPoint("TOPLEFT", tts, "BOTTOMLEFT", 4, -8)
    body:SetSize(400, #SOUND_ROWS * SOUND_ROW_H)
    panel.flowTop = function()
        return 4 + hint:GetStringHeight() + 4 + tts:GetHeight() + 8 + #SOUND_ROWS * SOUND_ROW_H
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

BUILDERS = { General = BuildGeneral, Sounds = BuildSounds, Defensives = BuildDefensives, Development = BuildDevelopment }

for _, name in ipairs(CastAheadOptions.TABS) do
    local host
    CastAheadWindow.Register(name, "Settings",
        function(h) host = h end,
        function() CastAheadOptions.ShowPanel(host, name) end)
end
