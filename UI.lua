-- /castahead - browse the tracked cast database and switch individual spells off.
--
-- This is an inspection tool: everything shown is harvested from combat logs and
-- MDT, so the point is to see how solid each row is - how many samples back it,
-- how tight the cooldown was, where the data is thin - and to sort by any of it.
-- Headers and cells are built from one column list, so they cannot drift apart.

local ROW_HEIGHT = 20
local HEADER_HEIGHT = 18
local LIST_WIDTH = 190
local WINDOW_WIDTH = 1000
local WINDOW_HEIGHT = 520
-- Resize floor. The width is derived from the column list below (see
-- MinWidth), so every header still fits inside the frame.
local MIN_HEIGHT = 420
local COLUMN_GAP = 4
local THIN_EVIDENCE = 5      -- fewer samples than this and the row is dimmed

local window, dungeonButtons, rows, rowParent, headers
local selectedInstanceID, sortKey, sortDescending, searchText
-- The window is a book: the casts page (dungeon list, search, table) and one
-- page per settings group, built by Options.lua into `settingsHost`.
local castsPage, settingsHost, tabButtons
local currentTab = "Casts"
local CASTS_TAB = "Casts"
-- Declared here because ShowTab, defined above BuildWindow, calls it.
local BuildWindow

local function IsDisabled(spellID)
    return CastAheadDB and CastAheadDB.disabled and CastAheadDB.disabled[spellID] == true
end

local function SetDisabled(spellID, disabled)
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.disabled = CastAheadDB.disabled or {}
    CastAheadDB.disabled[spellID] = disabled or nil
end

CastAheadUI = { IsDisabled = IsDisabled }

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

local function SpellName(entry)
    local info = C_Spell.GetSpellInfo(entry.spell)
    return (info and info.name) or entry.name or tostring(entry.spell)
end

local function FormatRotation(entry)
    if not CastAheadMatch.HasSchedule(entry) then
        return "|cff777777no timer|r", -1
    end
    local parts = {}
    for i = 1, #entry.cd do
        parts[i] = string.format("%.1f", entry.cd[i])
    end
    local text = table.concat(parts, " / ") .. "s"
    if entry.approx then
        text = "|cffff8800~|r" .. text
    end
    return text, entry.cd[1]
end

-- One definition per column drives the header, the cell and the sort, so a
-- header can never end up over the wrong values.
local COLUMNS = {
    { key = "check", width = 22 },
    -- Speaker: plays the row's voice line / alert on demand, so the calls can
    -- be auditioned outside a pull.
    { key = "hear", width = 18 },
    { key = "icon", width = 20 },
    -- A star marks the curated priority set - what "Only important casts"
    -- keeps. The enable checkbox is the player's own choice, this is ours.
    { key = "prio", header = "Imp", width = 28,
      text = function(e) return e.prio and "|A:auctionhouse-icon-favorite:12:12|a" or "" end,
      sort = function(e) return e.prio and 1 or 0 end },
    {
        key = "advice", header = "Do", width = 88,
        text = function(e)
            local advice = CastAheadMatch.Advice(e)
            -- Neither curated nor loud enough in the logs to earn a verdict:
            -- say so, rather than leave a cell that looks like a glitch.
            if not advice then return "|cff555555-|r" end
            -- Uncurated rows keep their statistical verdict but in grey: only
            -- starred casts are shown in a run, so only they earn the colour.
            if not e.prio then
                return "|cff777777" .. advice.label .. "|r"
            end
            return string.format("|cff%02x%02x%02x%s|r",
                advice.r * 255, advice.g * 255, advice.b * 255, advice.label)
        end,
        sort = function(e)
            local advice = CastAheadMatch.Advice(e)
            return advice and advice.label or "~"
        end,
    },
    { key = "spell", header = "Spell", width = 130, text = SpellName, sort = SpellName },
    { key = "mob", header = "Mob", width = 120,
      text = function(e) return "|cff9999ff" .. (e.mob or "?") .. "|r" end,
      sort = function(e) return e.mob or "" end },
    { key = "level", header = "Lvl", width = 28, justify = "RIGHT",
      text = function(e) return e.level and tostring(e.level) or "-" end,
      sort = function(e) return e.level or 0 end },
    { key = "cast", header = "Cast", width = 46, justify = "RIGHT",
      text = function(e) return string.format("%.1fs%s", e.cast, e.channel and " ch" or "") end,
      sort = function(e) return e.cast end },
    { key = "cd", header = "Cooldown", width = 84, justify = "RIGHT",
      text = function(e) return (FormatRotation(e)) end,
      sort = function(e) return select(2, FormatRotation(e)) end },
    { key = "first", header = "Open", width = 44, justify = "RIGHT",
      text = function(e) return e.first and string.format("%.1fs", e.first) or "-" end,
      sort = function(e) return e.first or -1 end },
    { key = "offset", header = "After", width = 44, justify = "RIGHT",
      text = function(e) return e.offset and string.format("%.1fs", e.offset) or "-" end,
      sort = function(e) return e.offset or -1 end },
    { key = "n", header = "Seen", width = 36, justify = "RIGHT",
      text = function(e) return tostring(e.n or 0) end,
      sort = function(e) return e.n or 0 end },
    { key = "hits", header = "Tgt", width = 32, justify = "RIGHT",
      text = function(e) return e.hits and string.format("%.0f", e.hits) or "-" end,
      sort = function(e) return e.hits or -1 end },
    { key = "dmg", header = "%HP", width = 40, justify = "RIGHT",
      text = function(e) return e.dmg and string.format("%d%%", e.dmg * 100) or "-" end,
      sort = function(e) return e.dmg or -1 end },
    { key = "kick", header = "Kick", width = 40, justify = "RIGHT",
      text = function(e) return (e.kick or 0) > 0 and string.format("%d%%", e.kick * 100) or "-" end,
      sort = function(e) return e.kick or 0 end },
}

local function ColumnOffset(index)
    local x = 0
    for i = 1, index - 1 do
        x = x + COLUMNS[i].width + COLUMN_GAP
    end
    return x
end

local function TableWidth()
    return ColumnOffset(#COLUMNS + 1)
end

local function MinWidth()
    return LIST_WIDTH + 24 + 520
end

-- Data ---------------------------------------------------------------------

local function DungeonList()
    local list = {}
    for instanceID, data in pairs(CastAheadData) do
        list[#list + 1] = { id = instanceID, name = data.name or tostring(instanceID), count = #data }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function CurrentInstanceID()
    local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    return instanceID
end

local function Matches(entry)
    if not searchText or searchText == "" then return true end
    local needle = searchText:lower()
    return SpellName(entry):lower():find(needle, 1, true) ~= nil
        or (entry.mob or ""):lower():find(needle, 1, true) ~= nil
end

local function SortedRows()
    local data = selectedInstanceID and CastAheadData[selectedInstanceID] or {}
    local list = {}
    for i = 1, #data do
        if Matches(data[i]) then
            list[#list + 1] = data[i]
        end
    end

    local column
    for i = 1, #COLUMNS do
        if COLUMNS[i].key == sortKey then column = COLUMNS[i] end
    end
    if column and column.sort then
        table.sort(list, function(a, b)
            local x, y = column.sort(a), column.sort(b)
            if x == y then return SpellName(a) < SpellName(b) end
            if sortDescending then x, y = y, x end
            return x < y
        end)
    end
    return list
end

-- Widgets ------------------------------------------------------------------

local Refresh

local function CreateHeader(parent, index, column)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(column.width, HEADER_HEIGHT)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", ColumnOffset(index), 0)
    button.text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.text:SetAllPoints()
    button.text:SetJustifyH(column.justify or "LEFT")
    if not column.sort then
        button:EnableMouse(false)
        return button
    end
    button:SetScript("OnClick", function()
        if sortKey == column.key then
            sortDescending = not sortDescending
        else
            sortKey, sortDescending = column.key, true
        end
        Refresh()
    end)
    button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    return button
end

local function CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(TableWidth(), ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row.cells = {}

    for i = 1, #COLUMNS do
        local column = COLUMNS[i]
        local x = ColumnOffset(i)
        if column.key == "check" then
            row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            row.check:SetSize(ROW_HEIGHT, ROW_HEIGHT)
            row.check:SetPoint("LEFT", row, "LEFT", x, 0)
        elseif column.key == "hear" then
            row.hear = CreateFrame("Button", nil, row)
            row.hear:SetSize(16, 16)
            row.hear:SetPoint("LEFT", row, "LEFT", x, 0)
            row.hear:SetNormalAtlas("chatframe-button-icon-speaker-on")
            row.hear:SetHighlightAtlas("chatframe-button-icon-speaker-on")
            row.hear:SetScript("OnClick", function(self)
                local e = self:GetParent().entry
                if e and CastAheadCore and CastAheadCore.PreviewAdvice then
                    CastAheadCore.PreviewAdvice(CastAheadMatch.Advice(e))
                end
            end)
        elseif column.key == "icon" then
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(16, 16)
            row.icon:SetPoint("LEFT", row, "LEFT", x + 2, 0)
            row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        else
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            text:SetPoint("LEFT", row, "LEFT", x, 0)
            text:SetWidth(column.width)
            text:SetJustifyH(column.justify or "LEFT")
            text:SetWordWrap(false)
            row.cells[column.key] = text
        end
    end

    row:SetScript("OnEnter", function(self)
        if not self.entry then return end
        local e = self.entry
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(e.spell)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(string.format("%s (npc %d)", e.mob or "?", e.npc or 0), 0.6, 0.6, 1)
        GameTooltip:AddLine(string.format("%d observations in the logs", e.n or 0), 0.7, 0.7, 0.7)
        GameTooltip:AddLine(string.format("Interrupted in %d%% of attempts, stopped otherwise in %d%%",
            (e.kick or 0) * 100, (e.cc or 0) * 100), 0.7, 0.7, 0.7)
        if e.dmg then
            GameTooltip:AddLine(string.format("Hits %.0f player(s) for %d%% of max health incoming (absorbs included)",
                e.hits or 1, e.dmg * 100), 0.7, 0.7, 0.7)
        end
        if (e.n or 0) < THIN_EVIDENCE then
            GameTooltip:AddLine("Thin evidence - run this dungeon more and regenerate", 1, 0.5, 0.2)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    return row
end

-- Refresh ------------------------------------------------------------------

function Refresh()
    if not window or not window:IsShown() then return end
    local list = SortedRows()

    for i = 1, #dungeonButtons do
        local button = dungeonButtons[i]
        local selected = button.instanceID == selectedInstanceID
        button.text:SetTextColor(selected and 1 or 0.8, selected and 0.82 or 0.8, selected and 0 or 0.8)
    end

    for i = 1, #headers do
        local column = COLUMNS[i]
        if column.header then
            local arrow = ""
            if sortKey == column.key then
                arrow = sortDescending and " |cffffd100v|r" or " |cffffd100^|r"
            end
            headers[i].text:SetText("|cffaaaaaa" .. column.header .. "|r" .. arrow)
        end
    end

    for i = 1, math.max(#list, #rows) do
        local entry = list[i]
        if entry and not rows[i] then
            rows[i] = CreateRow(rowParent, i)
        end
        local row = rows[i]
        if entry then
            row.entry = entry
            row.icon:SetTexture((C_Spell.GetSpellInfo(entry.spell) or {}).iconID or 136243)
            -- Rows resting on almost no observations are shown, but muted: the
            -- numbers are real, they are just not yet worth much.
            local alpha = (entry.n or 0) < THIN_EVIDENCE and 0.45 or 1
            for j = 1, #COLUMNS do
                local column = COLUMNS[j]
                local cell = row.cells[column.key]
                if cell then
                    cell:SetText(column.text(entry))
                    cell:SetAlpha(alpha)
                end
            end
            row.icon:SetAlpha(alpha)
            -- Nothing to say for a row with no verdict - no speaker either.
            row.hear:SetShown(CastAheadMatch.Advice(entry) ~= nil)
            row.check:SetChecked(not IsDisabled(entry.spell))
            row.check:SetScript("OnClick", function(self)
                SetDisabled(entry.spell, not self:GetChecked())
                if CastAheadCore and CastAheadCore.Reapply then CastAheadCore.Reapply() end
            end)
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end

    rowParent:SetHeight(math.max(#list, 1) * ROW_HEIGHT)
    local total = selectedInstanceID and #(CastAheadData[selectedInstanceID] or {}) or 0
    local starred = 0
    for i = 1, #list do
        if list[i].prio then starred = starred + 1 end
    end
    local summary = string.format("%d of %d spells shown, %d important | %d dungeons in the database",
        #list, total, starred, #DungeonList())
    -- Both outputs off looks exactly like a broken addon, so say it plainly.
    if not CastAheadConfig.Enabled("nameplates") and not CastAheadConfig.Enabled("timeline") then
        summary = "|cffff3333Both outputs are off - nothing will be shown in combat|r"
    end
    window.summary:SetText(summary)
end

-- Switching pages. The casts page and the settings host are siblings filling
-- the same area; exactly one of them is ever shown.
local function ShowTab(name)
    currentTab = name
    for tab, button in pairs(tabButtons or {}) do
        button:SetEnabled(tab ~= name)
    end
    if name == CASTS_TAB then
        if CastAheadOptions then CastAheadOptions.HideAll() end
        settingsHost:Hide()
        castsPage:Show()
        Refresh()
    else
        castsPage:Hide()
        settingsHost:Show()
        if CastAheadOptions then CastAheadOptions.ShowPanel(settingsHost, name) end
    end
end

-- Opens the window if it is closed, then selects a page. Used by the slash
-- commands and by anything that wants a particular settings group.
function CastAheadUI.ShowTab(name)
    if not window then BuildWindow() end
    window:Show()
    ShowTab(name)
end

function BuildWindow()
    window = CreateFrame("Frame", "CastAheadWindow", UIParent, "BasicFrameTemplateWithInset")
    window:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    window:SetPoint("CENTER")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:SetFrameStrata("DIALOG")
    window:SetResizable(true)
    if window.SetResizeBounds then
        window:SetResizeBounds(MinWidth(), MIN_HEIGHT)
    end

    local function RememberSize()
        CastAheadDB = CastAheadDB or {}
        CastAheadDB.window = CastAheadDB.window or {}
        CastAheadDB.window.width = window:GetWidth()
        CastAheadDB.window.height = window:GetHeight()
    end

    -- Grip in the bottom-right corner, as Blizzard resizable panels have. The
    -- column widths stay fixed - resizing simply reveals more rows and more of
    -- the columns that were cut off.
    local grip = CreateFrame("Button", nil, window)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    -- Doubled backslashes: Lua 5.1 quietly turns "\C" into "C", which left
    -- the grip with no texture at all.
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        window:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        window:StopMovingOrSizing()
        RememberSize()
        Refresh()
    end)
    table.insert(UISpecialFrames, "CastAheadWindow")   -- Escape closes it
    window.TitleText:SetText("CastAhead - tracked casts")

    -- Dry run of the selected dungeon's calls: icons, sounds, timeline.
    local test = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    test:SetSize(50, 18)
    if window.CloseButton then
        test:SetPoint("RIGHT", window.CloseButton, "LEFT", -2, 0)
    else
        test:SetPoint("TOPRIGHT", window, "TOPRIGHT", -26, -3)
    end
    test:SetText("Test")
    test:SetScript("OnClick", function()
        if CastAheadCore and CastAheadCore.Test then CastAheadCore.Test(selectedInstanceID) end
    end)

    -- Tab strip: the casts table first, then one page per settings group.
    tabButtons = {}
    local previousTab
    local names = { CASTS_TAB }
    for _, name in ipairs(CastAheadOptions and CastAheadOptions.TABS or {}) do
        names[#names + 1] = name
    end
    for _, name in ipairs(names) do
        local button = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
        button:SetSize(78, 20)
        if previousTab then
            button:SetPoint("LEFT", previousTab, "RIGHT", 4, 0)
        else
            button:SetPoint("TOPLEFT", window, "TOPLEFT", 12, -28)
        end
        button:SetText(name)
        button:SetScript("OnClick", function() ShowTab(name) end)
        tabButtons[name] = button
        previousTab = button
    end

    -- The two pages. Both fill the area under the tab strip; the settings
    -- panels are built into the host on first use.
    castsPage = CreateFrame("Frame", nil, window)
    castsPage:SetPoint("TOPLEFT", window, "TOPLEFT", 0, -52)
    castsPage:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", 0, 0)

    settingsHost = CreateFrame("Frame", nil, window)
    settingsHost:SetPoint("TOPLEFT", window, "TOPLEFT", 12, -56)
    settingsHost:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -12, 12)
    settingsHost:Hide()

    window.summary = castsPage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    window.summary:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 16, 12)

    local search = CreateFrame("EditBox", nil, castsPage, "SearchBoxTemplate")
    search:SetSize(LIST_WIDTH - 8, 20)
    search:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -56)
    search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function(self)
        SearchBoxTemplate_OnTextChanged(self)
        searchText = self:GetText()
        Refresh()
    end)

    dungeonButtons = {}
    local list = DungeonList()
    local current = CurrentInstanceID()
    for i, entry in ipairs(list) do
        local button = CreateFrame("Button", nil, castsPage)
        button:SetSize(LIST_WIDTH, ROW_HEIGHT + 2)
        button:SetPoint("TOPLEFT", window, "TOPLEFT", 12, -82 - (i - 1) * (ROW_HEIGHT + 2))
        button.instanceID = entry.id
        button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.text:SetPoint("LEFT", button, "LEFT", 6, 0)
        button.text:SetText(string.format("%s |cff777777(%d)|r", entry.name, entry.count))
        button:SetScript("OnClick", function(self)
            selectedInstanceID = self.instanceID
            Refresh()
        end)
        button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        dungeonButtons[i] = button
        if entry.id == current then selectedInstanceID = entry.id end
    end
    selectedInstanceID = selectedInstanceID or (list[1] and list[1].id)

    -- Header row, then the scrolling body beneath it, both on the same grid.
    -- The table lives in a clipping container: shrink the window and the
    -- rightmost columns are simply cut off at the frame edge instead of
    -- hanging outside it. Nothing forces the window to stay table-wide.
    local clip = CreateFrame("Frame", nil, castsPage)
    clip:SetPoint("TOPLEFT", window, "TOPLEFT", LIST_WIDTH + 24, -58)
    clip:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -8, 34)   -- above the summary line
    if clip.SetClipsChildren then clip:SetClipsChildren(true) end

    local headerStrip = CreateFrame("Frame", nil, clip)
    headerStrip:SetSize(TableWidth(), HEADER_HEIGHT)
    headerStrip:SetPoint("TOPLEFT", clip, "TOPLEFT", 0, 0)
    headers = {}
    for i = 1, #COLUMNS do
        headers[i] = CreateHeader(headerStrip, i, COLUMNS[i])
    end

    local scroll = CreateFrame("ScrollFrame", nil, clip, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", headerStrip, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", clip, "BOTTOMRIGHT", -26, 0)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(TableWidth(), 1)
    scroll:SetScrollChild(content)

    rows = {}
    rowParent = content
    local saved = CastAheadDB and CastAheadDB.window
    if saved and saved.width and saved.height then
        window:SetSize(math.max(saved.width, MinWidth()), math.max(saved.height, MIN_HEIGHT))
    end
    sortKey = sortKey or "n"
    if sortDescending == nil then sortDescending = true end
end

function CastAhead_Toggle()
    if not window then
        BuildWindow()
        -- A fresh frame is shown by default, so without this the first click
        -- "toggled" an already-visible window straight back off.
        window:Hide()
    end
    if window:IsShown() then
        window:Hide()
    else
        window:Show()
        -- Always come back to the casts page: the window's job is the table,
        -- and reopening it on whatever settings tab was last used hides that.
        ShowTab(CASTS_TAB)
    end
end

-- Kept as the name other code already calls; it selects the Sounds page,
-- and selecting it twice closes the window the way a toggle should.
function CastAheadUI.ToggleSounds()
    if window and window:IsShown() and currentTab == "Sounds" then
        window:Hide()
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
SlashCmdList.CASTAHEAD = function(msg)
    msg = msg and msg:lower() or ""
    -- The sub-command is the FIRST word: `msg:find` anywhere in the string
    -- meant "/ca anchor center" was answered by the `center` branch.
    local word = msg:match("^%s*(%a+)") or ""
    if word == "debug" then
        if CastAheadCore and CastAheadCore.Debug then CastAheadCore.Debug() end
        return
    end
    if word == "option" or word == "options" or word == "config" or word == "settings" then
        if window and window:IsShown() and currentTab ~= CASTS_TAB then
            window:Hide()
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
        if CastAheadCore and CastAheadCore.Test then CastAheadCore.Test(selectedInstanceID) end
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
        print("|cff33ff99CastAhead|r icons offset by " .. offset .. " px")
        return
    elseif word == "offset" then
        print("|cff33ff99CastAhead|r usage: /ca offset <pixels>  (current "
            .. tostring(CastAheadDB and CastAheadDB.offsetX or 0) .. ")")
        return
    end
    -- /ca center -200: move the centre call up/down (pixels from the
    -- default spot just below the middle of the screen).
    local centerY = msg:match("^%s*center%s+(-?%d+)")
    if centerY then
        CastAheadDB = CastAheadDB or {}
        CastAheadDB.centerY = tonumber(centerY)
        print("|cff33ff99CastAhead|r centre call shifted by " .. centerY .. " px")
        return
    elseif word == "center" then
        print("|cff33ff99CastAhead|r usage: /ca center <pixels>  (current "
            .. tostring(CastAheadDB and CastAheadDB.centerY or 0) .. ")")
        return
    end
    local side = msg:match("^%s*anchor%s+(%a+)")
    if side and CastAheadUI.SetAnchor(side) then
        print("|cff33ff99CastAhead|r icons anchored to the " .. side .. " of the nameplate")
        return
    elseif word == "anchor" then
        print("|cff33ff99CastAhead|r usage: /ca anchor topleft|top|topright|left|center|right|bottomleft|bottom|bottomright  (current "
            .. tostring(CastAheadDB and CastAheadDB.anchor or "left") .. ")")
        return
    end
    local grow = msg:match("^%s*grow%s+(%a+)")
    if grow and CastAheadUI.SetGrowth(grow) then
        print("|cff33ff99CastAhead|r icons grow " .. grow)
        return
    elseif word == "grow" then
        print("|cff33ff99CastAhead|r usage: /ca grow left|down|right|up|auto  (current "
            .. tostring(CastAheadDB and CastAheadDB.grow or "auto") .. ")")
        return
    end
    CastAhead_Toggle()
end

-- Entry in the game's addon compartment (the button list on the minimap).
function CastAhead_OnCompartmentClick()
    CastAhead_Toggle()
end
