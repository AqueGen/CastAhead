local testButton, listButton
local DUNGEON_PAGES = { Casts = true, Saves = true, Guide = true }

-- Stored as nil when on, false when off, so a fresh profile defaults to on.
local function SetOption(key, enabled)
    CastAheadConfig.SetEnabled(key, enabled)
end

local function OptionEnabled(key)
    return CastAheadConfig.Enabled(key)
end

-- Exposed so the toggle logic can be tested outside the game: it has now been
-- written wrong twice, both times by collapsing it into an and/or chain.
CastAheadUI.SetOption = SetOption
CastAheadUI.OptionEnabled = OptionEnabled

-- Where the icons sit relative to the nameplate: one of the nine positions in
-- CastAheadAnchors (Core.lua). Loaded before this file, so it is available.
-- The widgets that show the choice live in Options.lua and repaint themselves
-- when that window opens, so nothing here has to be told about a change.
function CastAheadUI.SetAnchor(side)
    if not (CastAheadAnchors and CastAheadAnchors[side]) then return false end
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.anchor = side ~= "left" and side or nil   -- left is the default
    if CastAheadCore and CastAheadCore.Reapply then CastAheadCore.Reapply() end
    return true
end

-- Which way the second and later icons go. "auto" grows away from the plate
-- for the chosen position (see CastAheadAnchors in Core.lua).
function CastAheadUI.SetGrowth(direction)
    if direction ~= "auto" and not (CastAheadGrowth and CastAheadGrowth[direction]) then return false end
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.grow = direction ~= "auto" and direction or nil
    if CastAheadCore and CastAheadCore.Reapply then CastAheadCore.Reapply() end
    return true
end

-- The test drive stops by itself when the last sample cast runs out, so the
-- button is repainted from the addon's state rather than from what was
-- clicked. Core calls this when a run ends.
function CastAheadUI.RefreshTest()
    if not testButton then return end
    local running = CastAheadCore and CastAheadCore.Testing and CastAheadCore.Testing()
    testButton:SetText(running and "Stop test" or "Test drive")
    listButton:SetText(running and "Stop" or "Play list")
end

function CastAheadUI.RefreshTabs()
    CastAheadWindow.SetMenuShown("Development", CastAheadConfig.Dev())
end

-- Opens the window if it is closed, then selects a page. Used by the slash
-- commands and by anything that wants a particular settings group.
function CastAheadUI.ShowTab(name)
    CastAheadUI.RefreshTabs()
    CastAheadWindow.Show(name)
end

local function WindowShown()
    local frame = CastAheadWindow.Frame()
    return frame and frame:IsShown()
end

-- Dry run of the selected dungeon's calls: icons, sounds, timeline.
function CastAheadWindow.titleButtons(add)
    testButton = add("Test drive", 90, true, function()
        if CastAheadCore and CastAheadCore.Test then CastAheadCore.Test(CastAheadWindow.Dungeon()) end
    end)
    testButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Test drive", 1, 1, 1)
        GameTooltip:AddLine("Play the selected dungeon's calls with nothing pulled - icons on any nameplate in front of you, the centre call, the voice and the sounds. Click again to stop.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    testButton:SetScript("OnLeave", GameTooltip_Hide)

    listButton = add("Play list", 80, false, function()
        if CastAheadCore and CastAheadCore.Test then
            CastAheadCore.Test(CastAheadWindow.Dungeon(), CastAheadUI.SortedRows())
        end
    end)
    listButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Play list", 1, 1, 1)
        GameTooltip:AddLine("Play every cast in the table, top to bottom in its current order, one at a time: the countdown, the call, the voice and the sound each one is set to. Click again to stop.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    listButton:SetScript("OnLeave", GameTooltip_Hide)
    CastAheadUI.RefreshTest()
end

function CastAhead_Toggle()
    CastAheadUI.RefreshTabs()
    CastAheadWindow.Toggle()
end

-- Kept as the name other code already calls; it selects the Sounds page,
-- and selecting it twice closes the window the way a toggle should.
function CastAheadUI.ToggleSounds()
    if WindowShown() and CastAheadWindow.Current() == "Sounds" then
        CastAheadWindow.Frame():Hide()
    else
        CastAheadUI.ShowTab("Sounds")
    end
end

SLASH_CASTAHEAD1 = "/castahead"
SLASH_CASTAHEAD2 = "/ca"
-- The old names still work: they were in the player's muscle memory before
-- the addon was renamed, and nothing else claims them.
SLASH_CASTAHEAD3 = "/forecast"
SLASH_CASTAHEAD4 = "/fcast"
local DEV_COMMANDS = { probe = true, report = true, mark = true, note = true }
SlashCmdList.CASTAHEAD = function(msg)
    msg = msg and msg:lower() or ""
    -- The sub-command is the FIRST word: `msg:find` anywhere in the string
    -- meant "/ca anchor center" was answered by the `center` branch.
    local word = msg:match("^%s*(%a+)") or ""
    if DEV_COMMANDS[word] and not CastAheadConfig.Dev() then
        print("|cff33ff99Cast Ahead|r /ca " .. word .. " needs Development mode (/ca options, Advanced)")
        return
    end
    if word == "probe" then
        if CastAheadCore and CastAheadCore.Probe then
            CastAheadCore.Probe(msg:match("^%s*%a+%s+(%a+)"))
        end
        return
    end
    if word == "report" then
        if CastAheadReport then CastAheadReport.Toggle() end
        return
    end
    if word == "journal" then
        if msg:match("^%s*%a+%s+clear") and StaticPopup_Show then
            StaticPopup_Show("CASTAHEAD_CLEAR_JOURNAL")
        elseif CastAheadRecorder then
            print(string.format("|cff33ff99Cast Ahead|r key journal: %d of %d keys - /ca journal clear empties it",
                #CastAheadRecorder.Keys(), CastAheadRecorder.MAX_KEYS))
        end
        return
    end
    if word == "mark" then
        if CastAheadRecorder and CastAheadRecorder.Enabled() then
            local n, key = CastAheadRecorder.Mark()
            CastAheadRecorder.AddNote(n, msg:match("^%s*%a+%s+(.+)$"), key)
        end
        return
    end
    if word == "note" then
        local n, text = msg:match("^%s*%a+%s+(%d+)%s+(.+)$")
        if CastAheadRecorder and n and CastAheadRecorder.AddNote(n, text) then
            print("|cff33ff99Cast Ahead|r note added to mark " .. n)
        else
            print("|cff33ff99Cast Ahead|r usage: /ca note <mark number> <text>")
        end
        return
    end
    if word == "debug" then
        if CastAheadCore and CastAheadCore.Debug then CastAheadCore.Debug() end
        return
    end
    if word == "option" or word == "options" or word == "config" or word == "settings" then
        if WindowShown() and not DUNGEON_PAGES[CastAheadWindow.Current()] then
            CastAheadWindow.Frame():Hide()
        else
            CastAheadUI.ShowTab("General")
        end
        return
    end
    if word == "sound" or word == "sounds" then
        CastAheadUI.ToggleSounds()
        return
    end
    if word == "move" then
        if CastAheadCore and CastAheadCore.MoveCenter then CastAheadCore.MoveCenter() end
        return
    end
    if word == "test" then
        if CastAheadCore and CastAheadCore.Test then CastAheadCore.Test(CastAheadWindow.Dungeon()) end
        return
    end
    if word == "hide" then
        if CastAheadCore and CastAheadCore.HideAll then CastAheadCore.HideAll() end
        return
    end
    -- /ca offset 40: push the icon column this many pixels further from the
    -- plate, past whatever the nameplate addon draws there.
    local offset = msg:match("^%s*offset%s+(-?%d+)")
    if offset then
        CastAheadDB = CastAheadDB or {}
        CastAheadDB.offsetX = tonumber(offset)
        if CastAheadCore and CastAheadCore.Reapply then CastAheadCore.Reapply() end
        print("|cff33ff99Cast Ahead|r icons offset by " .. offset .. " px")
        return
    elseif word == "offset" then
        print("|cff33ff99Cast Ahead|r usage: /ca offset <pixels>  (current "
            .. tostring(CastAheadDB and CastAheadDB.offsetX or 0) .. ")")
        return
    end
    -- /ca center -200: move the centre call up/down (pixels from the
    -- default spot just below the middle of the screen).
    local centerY = msg:match("^%s*center%s+(-?%d+)")
    if centerY then
        CastAheadDB = CastAheadDB or {}
        CastAheadDB.centerY = tonumber(centerY)
        print("|cff33ff99Cast Ahead|r centre call shifted by " .. centerY .. " px")
        return
    elseif word == "center" then
        print("|cff33ff99Cast Ahead|r usage: /ca center <pixels>  (current "
            .. tostring(CastAheadDB and CastAheadDB.centerY or 0) .. ")")
        return
    end
    local side = msg:match("^%s*anchor%s+(%a+)")
    if side and CastAheadUI.SetAnchor(side) then
        print("|cff33ff99Cast Ahead|r icons anchored to the " .. side .. " of the nameplate")
        return
    elseif word == "anchor" then
        print("|cff33ff99Cast Ahead|r usage: /ca anchor topleft|top|topright|left|center|right|bottomleft|bottom|bottomright  (current "
            .. tostring(CastAheadDB and CastAheadDB.anchor or "left") .. ")")
        return
    end
    local grow = msg:match("^%s*grow%s+(%a+)")
    if grow and CastAheadUI.SetGrowth(grow) then
        print("|cff33ff99Cast Ahead|r icons grow " .. grow)
        return
    elseif word == "grow" then
        print("|cff33ff99Cast Ahead|r usage: /ca grow left|down|right|up|auto  (current "
            .. tostring(CastAheadDB and CastAheadDB.grow or "auto") .. ")")
        return
    end
    CastAhead_Toggle()
end

-- Entry in the game's addon compartment (the button list on the minimap).
function CastAhead_OnCompartmentClick()
    CastAhead_Toggle()
end

-- An entry in the game's own AddOns list, which is where a player who does not
-- know the slash command looks first. Every setting lives in our window, so
-- this page is a signpost to it rather than a second copy of the settings that
-- would then have to be kept in step.
local function RegisterSettingsCategory()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end

    local panel = CreateFrame("Frame")
    panel.name = "Cast Ahead"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Cast Ahead")

    local blurb = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    blurb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    blurb:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    blurb:SetJustifyH("LEFT")
    blurb:SetText("Everything Cast Ahead has is in its own window: the tracked casts, "
        .. "what gets called out, where it is drawn and how it sounds.\n\n"
        .. "Open it with |cffffd100/ca|r, the minimap button, or the button below.")

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetSize(180, 24)
    open:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", 0, -16)
    open:SetText("Open Cast Ahead")
    open:SetScript("OnClick", function()
        -- Close the game's settings first: our window would otherwise open
        -- behind it, which reads as the button doing nothing.
        if SettingsPanel and SettingsPanel:IsShown() then
            HideUIPanel(SettingsPanel)
        end
        if not WindowShown() then CastAhead_Toggle() end
    end)

    local category = Settings.RegisterCanvasLayoutCategory(panel, "Cast Ahead")
    category.ID = "CastAhead"
    Settings.RegisterAddOnCategory(category)
end

-- Registered as the file loads. The settings API is up before addons are, and
-- an event frame here would be the first OnEvent handler in the file, which is
-- what the stubbed API in the test suite hands events to.
RegisterSettingsCategory()
