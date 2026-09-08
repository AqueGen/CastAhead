-- The settings panels. They are pages of the main window (UI.lua owns the
-- frame and the tab strip); this file only knows how to build and show them.
-- A second floating window was the first attempt and it overlapped the table
-- it was meant to configure.

CastAheadOptions = {}

-- Development is last on purpose: it is hidden unless the player asks for
-- it, and hiding the final tab leaves the strip intact.
CastAheadOptions.TABS = { "General", "Sounds", "Development" }
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
local BuildGeneral, BuildSounds, BuildDevelopment
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
    centerText = { label = "Show the centre call",
        tip = "The response in words, big, near the middle of the screen while an important cast goes out." },
    timeline = { label = "Feed the Blizzard timeline",
        tip = "Feed confident predictions to the game's own encounter timeline." },
    sound = { label = "Sound",
        tip = "Master switch for everything the addon plays." },
    voice = { label = "Voice",
        tip = "Speak the response out loud: \"tank buster\", \"dodge\", \"interrupt\"." },
    fullLabels = { label = "Full labels", defaultOff = true,
        tip = "Spell the longest verdicts out under a nameplate icon - BUSTER becomes TANKBUSTER. The icons step sideways by the width of the words under them, so the full words spread the row out; off, every plate's widest word is six characters and the rows pack evenly. The cast table and the spoken call always use the whole word either way." },
    devMode = { label = "Development mode", defaultOff = true,
        tip = "Adds a Development tab with the data-collection tools. Nothing here changes what the addon calls out - it is for finding out what the game still lets an addon read." },
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
    return CastAheadConfig.Get("devMode") == true
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
    local sound = BuildSwitch(panel, "sound", { "TOPLEFT", audio, "TOPLEFT", 10, -26 })
    BuildSwitch(panel, "voice", { "TOPLEFT", sound, "BOTTOMLEFT", 0, -4 })

    -- Development mode ----------------------------------------------------
    local extra = BuildGroup(panel, "Advanced", 2, 62,
        { "TOPLEFT", audio, "BOTTOMLEFT", 0, -12 })
    BuildSwitch(panel, "devMode", { "TOPLEFT", extra, "TOPLEFT", 10, -26 }, function()
        if CastAheadUI and CastAheadUI.RefreshTabs then CastAheadUI.RefreshTabs() end
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
        { "offsetX", "nudgeX", "nudgeY" }, Redraw)

    -- How big they are ----------------------------------------------------
    -- Everything drawn on a nameplate icon in one place: the icon sets the
    -- size and the two texts on it are a share of that, so changing the icon
    -- keeps them in proportion.
    local sizes = BuildGroup(panel, "Icon size", 4, 244)

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

    BuildReset(panel, { "TOPLEFT", timeSlider, "BOTTOMLEFT", -6, -22 },
        { "iconSize", "labelScale", "timeScale" }, Redraw)

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

-- The tools that collect data rather than change what is called out. Behind
-- the Development mode switch: useful after a patch, noise the rest of the
-- time.
function BuildDevelopment(panel)
    local intro = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -6)
    intro:SetWidth(600)
    intro:SetJustifyH("LEFT")
    intro:SetText("|cffaaaaaaNothing on this page changes what the addon calls out. It measures what the game still lets an addon read about an enemy, which is worth re-checking after every patch.|r")

    -- The probe samples what the game still lets us read off a hostile plate
    -- (level, power, health...) while trash is being fought, and prints the
    -- results to chat. Same as /ca probe and /ca probe show.
    local group = BuildGroup(panel, "Nameplate probe", 1, 120,
        { "TOPLEFT", intro, "BOTTOMLEFT", 0, -14 })

    local probe = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    probe:SetSize(22, 22)
    probe:SetPoint("TOPLEFT", group, "TOPLEFT", 10, -26)
    probe.text = probe:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    probe.text:SetPoint("LEFT", probe, "RIGHT", 2, 0)
    -- Short: the group is one column wide like every other, and the whole
    -- explanation is a hover away.
    probe.text:SetText("Collect enemy data")
    probe:SetHitRectInsets(0, -(probe.text:GetStringWidth() + 6), 0, 0)
    probe:SetScript("OnClick", function(self)
        if CastAheadCore and CastAheadCore.Probe then
            CastAheadCore.Probe(self:GetChecked() and "on" or "off")
        end
    end)
    probe:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Probe", 1, 1, 1)
        GameTooltip:AddLine("While on, every hostile nameplate and cast is checked against the unit API to see which facts are readable and which come back secret. Pull some trash, then press Show. Costs nothing noticeable.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    probe:SetScript("OnLeave", GameTooltip_Hide)
    table.insert(refreshers, function()
        probe:SetChecked(CastAheadCore and CastAheadCore.Probing and CastAheadCore.Probing() or false)
    end)

    local show = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    show:SetSize(120, 22)
    show:SetPoint("TOPLEFT", probe, "BOTTOMLEFT", 6, -8)
    show:SetText("Show results")
    show:SetScript("OnClick", function()
        if CastAheadCore and CastAheadCore.Probe then CastAheadCore.Probe("show") end
    end)

    local clear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    clear:SetSize(60, 22)
    clear:SetPoint("LEFT", show, "RIGHT", 4, 0)
    clear:SetText("Clear")
    clear:SetScript("OnClick", function()
        if CastAheadCore and CastAheadCore.Probe then CastAheadCore.Probe("clear") end
    end)
end

local SOUND_ROWS = { "KICK", "CC", "TANK", "AOE", "DODGE", "FRONTAL", "TARGET", "DISPEL",
    "POISON", "CURSE", "MAGIC", "DISEASE", "BLEED", "SOOTHE", "PURGE", "SWITCH", "ALERT" }
local SOUND_ROW_H = 26

function BuildSounds(panel)
    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
    hint:SetText("|cffaaaaaaDefault = stock beep, only when nothing spoke. A chosen sound always plays.|r")

    -- Off by default: the shipped clips speak unless this is on. Gated on the
    -- game's own Combat Audio Alerts setting, which it cannot work without.
    local tts = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    tts:SetSize(22, 22)
    tts:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -2)
    tts.text = tts:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tts.text:SetPoint("RIGHT", tts, "LEFT", -4, 0)
    tts.text:SetJustifyH("RIGHT")
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
    scroll:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 4)
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(400, #SOUND_ROWS * SOUND_ROW_H)
    scroll:SetScrollChild(body)

    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
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
            if root.SetScrollMode then root:SetScrollMode(20 * 20) end
            root:CreateRadio("Default",
                function() return (CastAheadDB and CastAheadDB.sounds and CastAheadDB.sounds[key]) == nil end,
                function()
                    CastAheadDB = CastAheadDB or {}
                    CastAheadDB.sounds = CastAheadDB.sounds or {}
                    CastAheadDB.sounds[key] = nil
                end)
            if lsm then
                for _, name in ipairs(lsm:List("sound")) do
                    root:CreateRadio(name,
                        function() return (CastAheadDB and CastAheadDB.sounds and CastAheadDB.sounds[key]) == name end,
                        function()
                            CastAheadDB = CastAheadDB or {}
                            CastAheadDB.sounds = CastAheadDB.sounds or {}
                            CastAheadDB.sounds[key] = name
                        end)
                end
            end
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
