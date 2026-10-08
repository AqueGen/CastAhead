-- The settings panels. They are pages of the main window (UI.lua owns the
-- frame and the tab strip); this file only knows how to build and show them.
-- A second floating window was the first attempt and it overlapped the table
-- it was meant to configure.

CastAheadOptions = {}

-- Development is last on purpose: it is hidden unless the player asks for
-- it, and hiding the final tab leaves the strip intact.
CastAheadOptions.TABS = { "General", "Sounds", "Defensives", "Development" }
local panels
-- One row of groups, each in its own column, so nothing is stacked and every
-- setting is reachable without reading up and down the page. UI.lua takes the
-- total as the window's resize floor: the panels do not scroll, so a narrower
-- window would simply draw the last column outside the frame.
local COL_W, COL_GAP, COL_X = 250, 8, 8
local COLUMNS = 5
local SLIDER_W = COL_W - 40
CastAheadOptions.MIN_WIDTH = COL_X * 2 + COLUMNS * COL_W + (COLUMNS - 1) * COL_GAP
-- The tallest column: the nameplate group, where the anchor square sits above
-- three sliders and their reset.
CastAheadOptions.MIN_HEIGHT = 404
-- Forward declarations: BuildWindow calls these, and Lua resolves a local by
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
    local slider = CreateFrame("Slider", nil, panel, "UISliderTemplateWithLabels")
    slider:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 6, -12)
    slider:SetSize(spec.width or SLIDER_W, 16)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(spec.min, spec.max)
    slider:SetValueStep(spec.step or 1)
    slider:SetObeyStepOnDrag(true)
    slider.Low:SetText(spec.low or tostring(spec.min))
    slider.High:SetText(spec.high or tostring(spec.max))

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
    show(read())
    slider:SetScript("OnValueChanged", function(_, value)
        if suppress then return end
        value = math.floor(value / (spec.step or 1) + 0.5) * (spec.step or 1)
        CastAheadConfig.Set(spec.key, value)
        paint(value)
        if spec.after then spec.after(value) end
    end)
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
        tip = "The game's combat log with advanced logging in every dungeon (off again when you leave, unless you had started it yourself), a journal of each key, and what the game lets an addon read off each enemy cast. Keeps the last 12 keys. No names of people are recorded. /reload after a key saves it to disk." },
    saveCalls = { label = "Defensive calls",
        tip = "Call a small or big defensive ahead of damage that needs one, and show your button for it in the centre." },
    bossAdapter = { label = "Boss calls from DBM / BigWigs",
        tip = "Also call defensives for boss abilities announced by DBM or BigWigs." },
    healCalls = { label = "Heal up after a big hit",
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

-- A titled box. Widgets are anchored to what it returns, so a group can be
-- moved by changing one SetPoint.
local function BuildGroup(panel, title, column, height, point)
    local box = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    box:SetSize(COL_W, height)
    if point then
        box:SetPoint(unpack(point))
    else
        box:SetPoint("TOPLEFT", panel, "TOPLEFT",
            COL_X + (column - 1) * (COL_W + COL_GAP), -6)
    end
    box:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    box:SetBackdropColor(0, 0, 0, 0.25)
    box:SetBackdropBorderColor(0.45, 0.45, 0.45, 0.8)
    box.title = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    box.title:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -8)
    box.title:SetText(title)
    return box
end

-- One switch, placed against whatever the caller anchors it to.
local function BuildSwitch(panel, key, point, onClick)
    local option = SWITCHES[key]
    local box = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    box:SetSize(22, 22)
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
    local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reset:SetSize(70, 20)
    reset:SetPoint(unpack(point))
    reset:SetText("Reset")
    reset:SetScript("OnClick", function()
        for _, key in ipairs(keys) do CastAheadConfig.Set(key, nil) end
        for _, refresh in ipairs(refreshers) do refresh() end
        if after then after() end
    end)
    return reset
end

function CastAheadOptions.DevMode()
    return CastAheadConfig.Dev()
end

-- Built once, the first time a settings tab is opened, as children of the
-- host frame the main window hands over.
local function Build(host)
    panels = {}
    for _, name in ipairs(CastAheadOptions.TABS) do
        local panel = CreateFrame("Frame", nil, host)
        panel:SetAllPoints(host)
        panel:Hide()
        panels[name] = panel
    end

    BuildGeneral(panels.General)
    BuildSounds(panels.Sounds)
    BuildDefensives(panels.Defensives)
    BuildDevelopment(panels.Development)
end

-- Show one settings page inside `host`, building them all on first use.
-- Every stateful widget is repainted first: the slash commands write the same
-- storage from outside, so what was drawn last time may be stale.
function CastAheadOptions.ShowPanel(host, name)
    if not panels then Build(host) end
    for _, refresh in ipairs(refreshers) do refresh() end
    for tab, panel in pairs(panels) do
        panel:SetShown(tab == name)
    end
end

-- The main window switching to a non-settings tab.
function CastAheadOptions.HideAll()
    if not panels then return end
    for _, panel in pairs(panels) do panel:Hide() end
end

-- Three columns of groups: what is announced at all on the left, the two
-- places it is drawn in the middle and on the right. Each group carries its
-- own on/off switch, so nothing has to be traced across the page.
function BuildGeneral(panel)
    -- What is announced ---------------------------------------------------
    local what = BuildGroup(panel, "What to call out", 1, 180)
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
    local audio = BuildGroup(panel, "Sound", 2, 86)
    local sound = BuildSwitch(panel, "sound", { "TOPLEFT", audio, "TOPLEFT", 10, -26 }, RedrawAndSaves)
    BuildSwitch(panel, "voice", { "TOPLEFT", sound, "BOTTOMLEFT", 0, -4 }, RedrawAndSaves)

    -- Development mode ----------------------------------------------------
    local extra = BuildGroup(panel, "Advanced", 2, 62,
        { "TOPLEFT", audio, "BOTTOMLEFT", 0, -12 })
    BuildSwitch(panel, "devMode", { "TOPLEFT", extra, "TOPLEFT", 10, -26 }, function()
        if CastAheadCore and CastAheadCore.ApplyDevMode then CastAheadCore.ApplyDevMode() end
    end)

    -- Where the icons go --------------------------------------------------
    local plates = BuildGroup(panel, "Nameplate icons", 3, 396)
    local platesOn = BuildSwitch(panel, "nameplates", { "TOPLEFT", plates, "TOPLEFT", 10, -26 })
    BuildSwitch(panel, "fullLabels", { "TOPLEFT", platesOn, "BOTTOMLEFT", 0, -4 })

    local anchorLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    anchorLabel:SetPoint("TOPLEFT", plates, "TOPLEFT", 16, -82)
    anchorLabel:SetText("Position around the plate")

    local square = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    square:SetSize(58, 58)
    square:SetPoint("TOPLEFT", anchorLabel, "BOTTOMLEFT", 4, -6)
    square:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    square:SetBackdropColor(0, 0, 0, 0.4)
    square:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.8)
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
    local sizes = BuildGroup(panel, "Icon size", 4, 396)

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
    local centre = BuildGroup(panel, "Centre call", 5, 218)
    BuildSwitch(panel, "centerText", { "TOPLEFT", centre, "TOPLEFT", 10, -26 })

    local centerScale = function()
        if CastAheadCore and CastAheadCore.ResizeCenter then CastAheadCore.ResizeCenter() end
    end
    local centerSlider = BuildSlider(panel, {
        key = "centerScale",
        default = CastAheadConfig.CENTER_DEFAULT,
        min = CastAheadConfig.CENTER_MIN, max = CastAheadConfig.CENTER_MAX, step = 5,
        low = CastAheadConfig.CENTER_MIN .. "%", high = CastAheadConfig.CENTER_MAX .. "%",
        point = { "TOPLEFT", centre, "TOPLEFT", 16, -56 },
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

    local move = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    move:SetSize(140, 22)
    move:SetPoint("TOPLEFT", centerTextSlider, "BOTTOMLEFT", -6, -18)
    move:SetText("Move it on screen")
    move:SetScript("OnClick", function()
        if CastAheadCore and CastAheadCore.MoveCenter then CastAheadCore.MoveCenter() end
    end)

    BuildReset(panel, { "LEFT", move, "RIGHT", 6, 0 },
        { "centerScale", "centerTextScale", "centerX", "centerY" }, centerScale)
end

local function DevButton(panel, label, width, point, command, tip)
    local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetPoint(unpack(point))
    button:SetText(label)
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
    intro:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -6)
    intro:SetWidth(600)
    intro:SetJustifyH("LEFT")
    intro:SetText("|cffaaaaaaRecord everything: combat log in dungeons, key journal, enemy casts. Nothing on this page changes what the addon calls out.|r")

    local recording = BuildGroup(panel, "Recording", 1, 86,
        { "TOPLEFT", intro, "BOTTOMLEFT", 0, -14 })
    local recordAll = BuildSwitch(panel, "recordAll", { "TOPLEFT", recording, "TOPLEFT", 10, -26 }, function()
        if CastAheadCore and CastAheadCore.ApplyDevMode then CastAheadCore.ApplyDevMode() end
    end)
    BuildSwitch(panel, "showMarkPanel", { "TOPLEFT", recordAll, "BOTTOMLEFT", 0, -4 }, function()
        if CastAheadReport then CastAheadReport.Refresh() end
    end)

    local group = BuildGroup(panel, "Recorded enemy data", 2, 62,
        { "TOPLEFT", recording, "TOPRIGHT", COL_GAP, 0 })
    local show = DevButton(panel, "Show", 70, { "TOPLEFT", group, "TOPLEFT", 16, -28 },
        "probe show", "Print which facts each unit API returned readable, secret or empty. /ca probe show")
    local sweep = DevButton(panel, "Sweep", 70, { "LEFT", show, "RIGHT", 4, 0 },
        "probe sweep", "Print every Unit* function that returned something readable. /ca probe sweep")
    DevButton(panel, "Clear", 60, { "LEFT", sweep, "RIGHT", 4, 0 },
        "probe clear", "Forget the collected probe results. /ca probe clear")
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
        or "Item with " .. (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(use) or tostring(use))
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

local function BuildSaveList(panel, size, column, hint)
    local S = CastAheadSaves
    local title = LIST_TITLES[size]
    local group = BuildGroup(panel, title, column, ListHeight(LIST_MIN_ROWS))
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
        hit:SetSize(COL_W - 44, LIST_ROW_H)
        hit:SetPoint("TOPLEFT", group, "TOPLEFT", 8, y)
        hit:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        hit:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        hit:SetScript("OnClick", function(self) RowMenu(self, i) end)
        local text = group:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT", group, "TOPLEFT", 12, y - 4)
        text:SetWidth(COL_W - 50)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        local remove = CreateFrame("Button", nil, group, "UIPanelCloseButton")
        remove:SetSize(20, 20)
        remove:SetPoint("TOPRIGHT", group, "TOPRIGHT", -8, y)
        remove:SetScript("OnClick", function() Remove(i) end)
        rows[i] = { text = text, remove = remove, hit = hit }
        return rows[i]
    end

    local box = CreateFrame("EditBox", nil, group, "InputBoxTemplate")
    box:SetSize(COL_W - 96, 20)
    box:SetAutoFocus(false)
    addBoxes[#addBoxes + 1] = box
    local add = CreateFrame("Button", nil, group, "UIPanelButtonTemplate")
    add:SetSize(56, 22)
    add:SetPoint("LEFT", box, "RIGHT", 6, 0)
    add:SetText("Add")
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
        end
        if #list == 0 then
            rows[1].text:SetText(size == "heal" and "|cffaaaaaaEmpty - no heal up call|r"
                or "|cffaaaaaaEmpty - this call shows no button|r")
        end
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", group, "TOPLEFT", 18, LIST_TOP - n * LIST_ROW_H - 6)
        group:SetHeight(ListHeight(n))
        reason:SetText("")
    end
    table.insert(refreshers, Paint)
    table.insert(listRefreshers, Paint)
    return group
end

function BuildDefensives(panel)
    local group = BuildGroup(panel, "Defensive calls", 1, ListHeight(LIST_MIN_ROWS))
    local function Fit() group:SetHeight(ListHeight(ListRows())) end
    table.insert(refreshers, Fit)
    table.insert(listRefreshers, Fit)
    local calls = BuildSwitch(panel, "saveCalls", { "TOPLEFT", group, "TOPLEFT", 10, -26 }, SaveRefresh)
    local boss = BuildSwitch(panel, "bossAdapter", { "TOPLEFT", calls, "BOTTOMLEFT", 0, -4 }, function(on)
        Redraw()
        if not on and CastAheadSaves then
            CastAheadSaves.CancelPrefix("dbm:")
            CastAheadSaves.CancelPrefix("bw:")
        end
    end)
    local heal = BuildSwitch(panel, "healCalls", { "TOPLEFT", boss, "BOTTOMLEFT", 0, -4 })

    local status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", heal, "BOTTOMLEFT", 4, -6)
    status:SetWidth(COL_W - 24)
    status:SetJustifyH("LEFT")
    table.insert(refreshers, function()
        status:SetText("|cffaaaaaa" .. (CastAheadBossAdapter and CastAheadBossAdapter.Status() or "No boss mod") .. "|r")
    end)

    local lists = {
        BuildSaveList(panel, "small", 2),
        BuildSaveList(panel, "big", 3),
        BuildSaveList(panel, "heal", 4, "Pressed right after a big hit lands: stone, potion, self-heal."),
    }

    local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reset:SetSize(110, 22)
    reset:SetPoint("TOPLEFT", status, "BOTTOMLEFT", -4, -14)
    reset:SetText("Reset to default")
    reset:SetScript("OnClick", function()
        if StaticPopup_Show then StaticPopup_Show("CASTAHEAD_RESET_SAVES") end
    end)

    local note = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", group, "BOTTOMLEFT", 0, -10)
    note:SetWidth(COL_W * 2)
    note:SetJustifyH("LEFT")
    note:SetText("|cffaaaaaaNo shipped defensive lists for this specialization.|r")

    local function PaintSpec()
        local spec = CastAheadSaves and CastAheadSaves.SpecID()
        local shipped = spec and CastAheadSaveButtons and CastAheadSaveButtons[spec] and true or false
        note:SetShown(not shipped)
        for _, list in ipairs(lists) do list:SetShown(shipped) end
        reset:SetShown(shipped)
    end
    table.insert(refreshers, PaintSpec)
    table.insert(listRefreshers, PaintSpec)
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
    hint:SetText("|cffaaaaaaVoice = the spoken call (a stock beep when it cannot speak). A sound plays instead of the voice.|r")

    -- Off by default: the shipped clips speak unless this is on. Gated on the
    -- game's own Combat Audio Alerts setting, which it cannot work without.
    local tts = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    tts:SetSize(22, 22)
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

    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", tts, "BOTTOMLEFT", 4, -8)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 4)
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(400, #SOUND_ROWS * SOUND_ROW_H)
    scroll:SetScrollChild(body)

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
