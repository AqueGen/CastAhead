-- /ca options - every setting in one place.
--
-- The data browser used to carry the options along its bottom edge, which
-- ran out of room and mixed two jobs in one frame. Here they are grouped,
-- and the two announcement blocks (keys and raid) are literally the same
-- builder run twice against different contexts.

CastAheadOptions = {}

local TABS = { "General", "Keys", "Raid", "Sounds" }
local WIDTH, HEIGHT = 460, 520
local window, panels, tabButtons
-- Forward declarations: BuildWindow calls these, and Lua resolves a local by
-- what it holds at call time, so they must exist as upvalues before it runs.
local BuildGeneral, BuildAnnounce, BuildSounds
-- Widgets are painted once, when the window is first built, but storage can
-- change behind the window's back: the old option panel until Task 5 removes
-- it, and always the /ca anchor|grow|offset|center slash commands and the
-- Move button. Every widget that displays stored state registers a closure
-- here that re-reads it; ShowTab and Toggle run the lot before showing.
local refreshers = {}

local function ShowPanel(name)
    for tab, panel in pairs(panels) do
        panel:SetShown(tab == name)
        tabButtons[tab]:SetEnabled(tab ~= name)
    end
end

-- Seven of the eight per-context options; the eighth, leadSeconds, is the
-- slider built under them. Both contexts get the same widgets. The
-- accessor defaults to the ACTIVE context, so these widgets pass their own
-- context to it explicitly.
local ANNOUNCE = {
    { key = "importantOnly", label = "Important casts only",
      tip = "Show, speak and time only the casts marked with a star - the hand-picked set that needs a reaction." },
    { key = "roleFilter", label = "My role only",
      tip = "Hide calls this character cannot act on: dispels you do not have, tank busters for tanks and healers." },
    { key = "nameplates", label = "Nameplate icons",
      tip = "Countdown icons next to enemy nameplates." },
    { key = "centerText", label = "Centre call",
      tip = "The response in words, big, near the middle of the screen while an important cast goes out." },
    { key = "timeline", label = "Blizzard timeline",
      tip = "Feed confident predictions to the game's own encounter timeline." },
    { key = "sound", label = "Sound",
      tip = "Master switch for everything audible in this context." },
    { key = "voice", label = "Voice",
      tip = "Speak the response out loud: \"tank buster\", \"dodge\", \"interrupt\"." },
}

function BuildAnnounce(panel, context)
    local y = -4
    for _, option in ipairs(ANNOUNCE) do
        local box = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        box:SetSize(22, 22)
        box:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, y)
        box.text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        box.text:SetPoint("LEFT", box, "RIGHT", 2, 0)
        box.text:SetText(option.label)
        box:SetHitRectInsets(0, -(box.text:GetStringWidth() + 6), 0, 0)
        box:SetChecked(CastAheadConfig.Enabled(option.key, context))
        box:SetScript("OnClick", function(self)
            CastAheadConfig.SetEnabled(option.key, self:GetChecked() and true or false, context)
            if CastAheadCore and CastAheadCore.Reapply then CastAheadCore.Reapply() end
        end)
        box:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(option.label, 1, 1, 1)
            GameTooltip:AddLine(option.tip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        box:SetScript("OnLeave", GameTooltip_Hide)
        table.insert(refreshers, function()
            box:SetChecked(CastAheadConfig.Enabled(option.key, context))
        end)
        y = y - 26
    end

    local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, y - 8)
    local slider = CreateFrame("Slider", nil, panel, "UISliderTemplateWithLabels")
    slider:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 6, -12)
    slider:SetSize(200, 16)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(0, CastAheadConfig.LEAD_MAX)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider.Low:SetText("off")
    slider.High:SetText(CastAheadConfig.LEAD_MAX .. "s")
    local function paint(value)
        label:SetText(value > 0
            and string.format("Early warning: %d seconds before the cast", value)
            or "Early warning: off")
    end
    local suppress = false
    local stored = tonumber(CastAheadConfig.Get("leadSeconds", context)) or CastAheadConfig.LEAD_DEFAULT
    suppress = true
    slider:SetValue(stored)
    suppress = false
    paint(stored)
    slider:SetScript("OnValueChanged", function(self, value)
        if suppress then return end
        value = math.floor(value + 0.5)
        CastAheadConfig.Set("leadSeconds", value, context)
        paint(value)
    end)
    table.insert(refreshers, function()
        local value = tonumber(CastAheadConfig.Get("leadSeconds", context)) or CastAheadConfig.LEAD_DEFAULT
        suppress = true
        slider:SetValue(value)
        suppress = false
        paint(value)
    end)
end

local function BuildWindow()
    window = CreateFrame("Frame", "CastAheadOptionsWindow", UIParent, "BasicFrameTemplateWithInset")
    window:SetSize(WIDTH, HEIGHT)
    window:SetPoint("CENTER")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:SetFrameStrata("DIALOG")
    table.insert(UISpecialFrames, "CastAheadOptionsWindow")
    window.TitleText:SetText("CastAhead - settings")

    panels, tabButtons = {}, {}
    local previous
    for _, name in ipairs(TABS) do
        local button = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
        button:SetSize(96, 20)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            button:SetPoint("TOPLEFT", window, "TOPLEFT", 12, -30)
        end
        button:SetText(name)
        button:SetScript("OnClick", function() ShowPanel(name) end)
        tabButtons[name] = button
        previous = button

        local panel = CreateFrame("Frame", nil, window)
        panel:SetPoint("TOPLEFT", window, "TOPLEFT", 12, -58)
        panel:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -12, 12)
        panel:Hide()
        panels[name] = panel
    end

    BuildGeneral(panels.General)
    BuildAnnounce(panels.Keys, "key")
    BuildAnnounce(panels.Raid, "raid")
    BuildSounds(panels.Sounds)
end

local function RefreshAll()
    for _, refresh in ipairs(refreshers) do refresh() end
end

function CastAheadOptions.ShowTab(name)
    if not window then BuildWindow() end
    RefreshAll()
    window:Show()
    ShowPanel(name)
end

-- UI.lua asks so the Sounds button can close the window it opened.
function CastAheadOptions.Current()
    if not window or not window:IsShown() then return nil end
    for tab, panel in pairs(panels) do
        if panel:IsShown() then return tab end
    end
end

function CastAheadOptions.Toggle()
    if not window then BuildWindow() end
    if window:IsShown() then
        window:Hide()
    else
        RefreshAll()
        window:Show()
        ShowPanel("General")
    end
end

-- Layout is global: the icons sit in the same place whatever the content.
function BuildGeneral(panel)
    local anchorLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    anchorLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
    anchorLabel:SetText("Icon position around the nameplate")

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

    local offsetLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    offsetLabel:SetPoint("TOPLEFT", square, "BOTTOMLEFT", -4, -16)
    local offsetSlider = CreateFrame("Slider", nil, panel, "UISliderTemplateWithLabels")
    offsetSlider:SetPoint("TOPLEFT", offsetLabel, "BOTTOMLEFT", 6, -12)
    offsetSlider:SetSize(200, 16)
    offsetSlider:SetOrientation("HORIZONTAL")
    offsetSlider:SetMinMaxValues(0, 120)
    offsetSlider:SetValueStep(2)
    offsetSlider:SetObeyStepOnDrag(true)
    offsetSlider.Low:SetText("0")
    offsetSlider.High:SetText("120")
    local function paintOffset(value)
        offsetLabel:SetText(string.format("Distance from the nameplate: %d px", value))
    end
    local suppressOffset = false
    local offset = tonumber(CastAheadConfig.Get("offsetX")) or 0
    suppressOffset = true
    offsetSlider:SetValue(offset)
    suppressOffset = false
    paintOffset(offset)
    offsetSlider:SetScript("OnValueChanged", function(_, value)
        if suppressOffset then return end
        value = math.floor(value + 0.5)
        CastAheadConfig.Set("offsetX", value)
        paintOffset(value)
        if CastAheadCore and CastAheadCore.Reapply then CastAheadCore.Reapply() end
    end)
    table.insert(refreshers, function()
        local value = tonumber(CastAheadConfig.Get("offsetX")) or 0
        suppressOffset = true
        offsetSlider:SetValue(value)
        suppressOffset = false
        paintOffset(value)
    end)

    local move = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    move:SetSize(160, 22)
    move:SetPoint("TOPLEFT", offsetSlider, "BOTTOMLEFT", -6, -20)
    move:SetText("Move the centre call")
    move:SetScript("OnClick", function()
        if CastAheadCore and CastAheadCore.MoveCenter then CastAheadCore.MoveCenter() end
    end)
end

local SOUND_ROWS = { "KICK", "CC", "TANK", "AOE", "DODGE", "FRONTAL", "TARGET", "DISPEL",
    "POISON", "CURSE", "MAGIC", "DISEASE", "BLEED", "SOOTHE", "PURGE", "SWITCH", "ALERT" }
local SOUND_ROW_H = 26

function BuildSounds(panel)
    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
    hint:SetText("|cffaaaaaaDefault = stock beep, only when nothing spoke. A chosen sound always plays.|r")

    -- Global, off by default: the shipped clips speak unless this is on. Gated
    -- only on the game's own Combat Audio Alerts setting - a global switch
    -- cannot follow the per-context "voice" option, which has its own value
    -- in Keys and Raid.
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
