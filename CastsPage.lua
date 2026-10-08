-- /castahead - browse the tracked cast database and switch individual spells off.
--
-- This is an inspection tool: everything shown is harvested from combat logs and
-- MDT, so the point is to see how solid each row is - how many samples back it,
-- how tight the cooldown was, where the data is thin - and to sort by any of it.
-- Headers and cells are built from one column list, so they cannot drift apart.

local ROW_HEIGHT = 24
local WIDGET_HEIGHT = 20
local HEADER_HEIGHT = 18
local SEARCH_WIDTH = 182
local TABLE_TOP = WIDGET_HEIGHT + 6
local COLUMN_GAP = 4
local THIN_EVIDENCE = 5      -- fewer samples than this and the row is dimmed

local host, rows, rowParent, headers, headerStrip, tableFrame, sideScroll
local sortKey, sortDescending, searchText

local function IsDisabled(spellID)
    return CastAheadDB and CastAheadDB.disabled and CastAheadDB.disabled[spellID] == true
end

local function SetDisabled(spellID, disabled)
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.disabled = CastAheadDB.disabled or {}
    CastAheadDB.disabled[spellID] = disabled or nil
end

CastAheadUI = { IsDisabled = IsDisabled }

local function SpellSound(entry)
    return CastAheadDB and CastAheadDB.spellSounds and CastAheadDB.spellSounds[entry.spell]
end

local function SetSpellSound(entry, name)
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.spellSounds = CastAheadDB.spellSounds or {}
    CastAheadDB.spellSounds[entry.spell] = name
end

local function CategorySound(entry)
    local advice = CastAheadMatch.Advice(entry)
    return advice and CastAheadDB and CastAheadDB.sounds and CastAheadDB.sounds[advice.key]
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
    { key = "prio", dev = true, header = "Imp", width = 28,
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
            return advice and advice.label
        end,
    },
    { key = "spell", header = "Spell", width = 130, text = SpellName, sort = SpellName },
    { key = "mob", header = "Mob", width = 120,
      text = function(e) return "|cff9999ff" .. (e.mob or "?") .. "|r" end,
      sort = function(e) return e.mob or "" end },
    { key = "level", dev = true, header = "Lvl", width = 28, justify = "RIGHT",
      text = function(e) return e.level and tostring(e.level) or "-" end,
      sort = function(e) return e.level or 0 end },
    { key = "cast", header = "Cast", width = 46, justify = "RIGHT",
      text = function(e) return string.format("%.1fs%s", e.cast, e.channel and " ch" or "") end,
      sort = function(e) return e.cast end },
    { key = "cd", header = "Cooldown", width = 84, justify = "RIGHT",
      text = function(e) return (FormatRotation(e)) end,
      sort = function(e) return select(2, FormatRotation(e)) end },
    { key = "first", dev = true, header = "Open", width = 44, justify = "RIGHT",
      text = function(e) return e.first and string.format("%.1fs", e.first) or "-" end,
      sort = function(e) return e.first or -1 end },
    { key = "offset", dev = true, header = "After", width = 44, justify = "RIGHT",
      text = function(e) return e.offset and string.format("%.1fs", e.offset) or "-" end,
      sort = function(e) return e.offset or -1 end },
    { key = "n", dev = true, header = "Seen", width = 36, justify = "RIGHT",
      text = function(e) return tostring(e.n or 0) end,
      sort = function(e) return e.n or 0 end },
    { key = "hits", dev = true, header = "Tgt", width = 32, justify = "RIGHT",
      text = function(e) return e.hits and string.format("%.0f", e.hits) or "-" end,
      sort = function(e) return e.hits or -1 end },
    { key = "dmg", dev = true, header = "%HP", width = 40, justify = "RIGHT",
      text = function(e) return e.dmg and string.format("%d%%", e.dmg * 100) or "-" end,
      sort = function(e) return e.dmg or -1 end },
    -- Two different facts, deliberately side by side. "Kick" is capability -
    -- green when the game lets the cast be interrupted at all - with how often
    -- the group actually did it. "Stop" is everything else that ended the cast
    -- early, which in practice means a stun or another control.
    { key = "kick", dev = true, header = "Kick", width = 40, justify = "RIGHT",
      text = function(e)
          local seen = (e.kick or 0) > 0 and string.format("%d%%", e.kick * 100) or "-"
          return e.kickable and ("|cff40dd60" .. seen .. "|r") or ("|cff886666" .. seen .. "|r")
      end,
      sort = function(e) return (e.kickable and 100 or 0) + (e.kick or 0) end },
    { key = "cc", dev = true, header = "Stop", width = 40, justify = "RIGHT",
      text = function(e) return (e.cc or 0) > 0 and string.format("%d%%", e.cc * 100) or "-" end,
      sort = function(e) return e.cc or 0 end },
    -- Inherit ticked: the category's alert (Sounds tab), shown greyed. Unticked:
    -- the player's own pick for this one cast, ahead of the category's.
    { key = "sound", dev = true, header = "Sound override", width = 12 + 22 + 110,
      text = function(e) return CastAheadMatch.Advice(e) and "" or "|cff555555-|r" end,
      sort = function(e) return SpellSound(e) or "" end },
}

local function SelectColumns(dev)
    local list = {}
    for _, column in ipairs(COLUMNS) do
        if dev or not column.dev then list[#list + 1] = column end
    end
    return list
end

function CastAheadUI.VisibleColumns(dev)
    local keys = {}
    for i, column in ipairs(SelectColumns(dev)) do keys[i] = column.key end
    return keys
end

function CastAheadUI.VisibleSortKey(key, dev)
    for _, column in ipairs(SelectColumns(dev)) do
        if column.key == key and column.sort then return key end
    end
    return "advice"
end

local tableColumns = COLUMNS

local function ColumnOffset(index)
    local x = 0
    for i = 1, index - 1 do
        x = x + tableColumns[i].width + COLUMN_GAP
    end
    return x
end

local function TableWidth()
    return ColumnOffset(#tableColumns + 1)
end

-- Data ---------------------------------------------------------------------

local function Matches(entry)
    if not searchText or searchText == "" then return true end
    local needle = searchText:lower()
    return SpellName(entry):lower():find(needle, 1, true) ~= nil
        or (entry.mob or ""):lower():find(needle, 1, true) ~= nil
end

local function SortedRows()
    local dungeon = CastAheadWindow.Dungeon()
    local data = dungeon and CastAheadData[dungeon] or {}
    local list = {}
    for i = 1, #data do
        if Matches(data[i]) then
            list[#list + 1] = data[i]
        end
    end

    local key = CastAheadUI.VisibleSortKey(sortKey or "n", CastAheadConfig.Dev())
    local descending = sortDescending ~= false
    local column
    for i = 1, #COLUMNS do
        if COLUMNS[i].key == key then column = COLUMNS[i] end
    end
    if column and column.sort then
        table.sort(list, function(a, b)
            local x, y = column.sort(a), column.sort(b)
            if x == y then return SpellName(a) < SpellName(b) end
            if x == nil then return false end
            if y == nil then return true end
            if descending then x, y = y, x end
            return x < y
        end)
    end
    return list
end

CastAheadUI.SortedRows = SortedRows

-- Every heading is an abbreviation, and half of them measure something the
-- game never shows anywhere else, so each one explains itself on hover.
local HEADER_TIPS = {
    check = { "Track this cast",
        "Unticked casts are ignored in a run: no bar, no call, no sound." },
    hear = { "Play the call",
        "Click to hear how this cast is announced, without waiting for a pull." },
    prio = { "Important",
        "Starred casts are the ones worth reacting to. |cffffd100Only important casts|r in the General tab hides everything else." },
    advice = { "What to do",
        "The call made when this cast starts. Grey means the cast is tracked but has earned no verdict - too rare in the logs, and not starred." },
    spell = { "Spell",
        "The cast being tracked. Hover a row for the spell tooltip." },
    sound = { "Sound override",
        "Ticked, the cast is announced like its category (Sounds tab): the voice, or the sound chosen there. Untick to pick a sound for this one cast instead of the voice; it plays once the cast is identified as this spell." },
    mob = { "Caster",
        "Which creature casts it. In 12.1 a nameplate never reveals a creature's name or ID, so this comes from combat logs - the addon only guesses which of them is in front of you." },
    level = { "Mob level",
        "One of the few things a hostile nameplate still reveals, so it is used to tell apart casts that look identical." },
    cast = { "Cast time",
        "How long the cast bar runs. |cffffd100ch|r marks a channel." },
    cd = { "Rotation",
        "Start-to-start seconds until this cast comes back. Several numbers = a repeating cycle, used in order." },
    first = { "Opener",
        "Seconds from the mob entering combat to this cast. This is what predicts the first cast of a pull, before anything has been seen." },
    offset = { "Offset",
        "Seconds from the mob's very first cast of the pull to this one - where the cast sits in the opening sequence." },
    n = { "Times seen",
        "How many casts the timings rest on. Small numbers mean a rough estimate; |cffffd100~|r on a timer means the same." },
    hits = { "Targets hit",
        "How many players the cast lands on, on average. |cffffd1001|r is single target, |cffffd1005|r hits the group." },
    dmg = { "Damage",
        "The worst hit as a share of that player's maximum health, averaged over the logs. Healing and utility casts have none." },
    kick = { "Interrupt",
        "|cff40dd60Green|r means the game lets this cast be interrupted at all; |cff886666grey|r means it does not, whatever anyone tries. The number is how often the group actually landed a kick on it, so |cffffd100-|r on green only means nobody has bothered yet." },
    cc = { "Stopped another way",
        "How often the cast started and never finished without an interrupt being logged - a stun, a knock, a fear. This is the column that says \"you cannot kick it, but you can stop it\". |cffffd100-|r means nobody in our logs ever stopped it, which is not proof that it cannot be stopped." },
}

-- Widgets ------------------------------------------------------------------

local Refresh

local function CreateHeader(parent, index, column)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(column.width, HEADER_HEIGHT)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", ColumnOffset(index), 0)
    if column.header then
        local bg = button:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.07)
    end
    button.text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.text:SetAllPoints()
    button.text:SetJustifyH("CENTER")

    local tip = HEADER_TIPS[column.key]
    if tip then
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            GameTooltip:AddLine(tip[1])
            GameTooltip:AddLine(tip[2], 0.8, 0.8, 0.8, true)
            if column.sort then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Click to sort by this column.", 0.5, 0.5, 0.5)
            end
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", GameTooltip_Hide)
    end

    if not column.sort then
        button:EnableMouse(tip ~= nil)
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

    for i = 1, #tableColumns do
        local column = tableColumns[i]
        local x = ColumnOffset(i)
        if column.key == "check" then
            row.check = CreateFrame("CheckButton", nil, row, "MinimalCheckboxTemplate")
            row.check:SetSize(WIDGET_HEIGHT, WIDGET_HEIGHT)
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
                    CastAheadCore.PreviewAdvice(CastAheadMatch.Advice(e), { e })
                end
            end)
        elseif column.key == "sound" then
            row.inherit = CreateFrame("CheckButton", nil, row, "MinimalCheckboxTemplate")
            row.inherit:SetSize(WIDGET_HEIGHT, WIDGET_HEIGHT)
            row.inherit:SetPoint("LEFT", row, "LEFT", x + 12, 0)
            row.inherit:SetScript("OnClick", function(self)
                local e = row.entry
                if not e then return end
                if self:GetChecked() then
                    SetSpellSound(e, nil)
                else
                    SetSpellSound(e, SpellSound(e) or "")
                end
                Refresh()
            end)
            row.sound = CreateFrame("DropdownButton", nil, row, "WowStyle1DropdownTemplate")
            row.sound:SetSize(column.width - 34, WIDGET_HEIGHT)
            row.sound:SetPoint("LEFT", row, "LEFT", x + 34, 0)
            row.sound:SetupMenu(function(_, root)
                local e = row.entry
                if not (e and CastAheadOptions and CastAheadOptions.SoundMenu) then return end
                CastAheadOptions.SoundMenu(root,
                    function()
                        local own = SpellSound(e)
                        if own == nil then return CategorySound(e) end
                        return own ~= "" and own or nil
                    end,
                    function(name) SetSpellSound(e, name or "") end,
                    CastAheadMatch.Advice(e))
            end)
            local dash = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            dash:SetPoint("LEFT", row, "LEFT", x + 12, 0)
            row.cells[column.key] = dash
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

local function RebuildTable()
    for i = 1, #headers do
        headers[i]:Hide()
        headers[i]:SetParent(nil)
    end
    for i = 1, #rows do
        rows[i]:Hide()
        rows[i]:SetParent(nil)
    end
    headers, rows = {}, {}
    tableColumns = SelectColumns(CastAheadConfig.Dev())
    sortKey = CastAheadUI.VisibleSortKey(sortKey or "n", CastAheadConfig.Dev())
    local width = TableWidth()
    tableFrame:SetWidth(width)
    headerStrip:SetWidth(width)
    rowParent:SetWidth(width)
    for i = 1, #tableColumns do
        headers[i] = CreateHeader(headerStrip, i, tableColumns[i])
    end
end

-- Refresh ------------------------------------------------------------------

function Refresh()
    if not (host and host:IsVisible()) then return end
    if #SelectColumns(CastAheadConfig.Dev()) ~= #tableColumns then RebuildTable() end
    local list = SortedRows()

    for i = 1, #headers do
        local column = tableColumns[i]
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
            -- Nothing to say for a row with no verdict - no speaker, no sound.
            row.hear:SetShown(CastAheadMatch.Advice(entry) ~= nil)
            local hasAdvice = CastAheadMatch.Advice(entry) ~= nil
            if row.sound then
                row.inherit:SetShown(hasAdvice)
                row.sound:SetShown(hasAdvice)
                row.inherit:SetChecked(SpellSound(entry) == nil)
                row.sound:SetEnabled(SpellSound(entry) ~= nil)
                row.sound:GenerateMenu()
            end
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

    local rowsHeight = math.max(#list, 1) * ROW_HEIGHT
    rowParent:SetHeight(rowsHeight)
    tableFrame:SetHeight(HEADER_HEIGHT + 4 + rowsHeight)
    sideScroll:SetHeight(HEADER_HEIGHT + 4 + rowsHeight)
    host:SetHeight(TABLE_TOP + HEADER_HEIGHT + 4 + rowsHeight)

    local dungeon = CastAheadWindow.Dungeon()
    local total = dungeon and #(CastAheadData[dungeon] or {}) or 0
    local starred = 0
    for i = 1, #list do
        if list[i].prio then starred = starred + 1 end
    end
    local dungeons = 0
    for _ in pairs(CastAheadData) do dungeons = dungeons + 1 end
    local summary = string.format("%d of %d spells shown, %d important | %d dungeons in the database",
        #list, total, starred, dungeons)
    -- Both outputs off looks exactly like a broken addon, so say it plainly.
    if not CastAheadConfig.Enabled("nameplates") and not CastAheadConfig.Enabled("timeline") then
        summary = "|cffff3333Both outputs are off - nothing will be shown in combat|r"
    end
    CastAheadWindow.SetFooter(summary)
end

local function Build(page)
    host = page
    local search = CreateFrame("EditBox", nil, host, "SearchBoxTemplate")
    search:SetSize(SEARCH_WIDTH, WIDGET_HEIGHT)
    search:SetPoint("TOPLEFT", host, "TOPLEFT", 6, 0)
    search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function(self)
        SearchBoxTemplate_OnTextChanged(self)
        searchText = self:GetText()
        Refresh()
    end)

    -- Header row, then the scrolling body beneath it, both on the same grid.
    -- The table lives in a clipping container: shrink the window and the
    -- rightmost columns are simply cut off at the frame edge instead of
    -- hanging outside it. Nothing forces the window to stay table-wide.
    sideScroll = CreateFrame("ScrollFrame", nil, host)
    sideScroll:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -TABLE_TOP)
    sideScroll:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, -TABLE_TOP)
    sideScroll:SetHeight(1)
    tableFrame = CreateFrame("Frame", nil, sideScroll)
    tableFrame:SetSize(1, 1)
    sideScroll:SetScrollChild(tableFrame)
    local function ScrollSideways(delta)
        local range = sideScroll:GetHorizontalScrollRange()
        sideScroll:SetHorizontalScroll(math.max(0, math.min(range, sideScroll:GetHorizontalScroll() - delta * 60)))
    end
    sideScroll:EnableMouseWheel(true)
    sideScroll:SetScript("OnMouseWheel", function(_, delta)
        if IsShiftKeyDown() then
            ScrollSideways(delta)
        else
            local outer = host:GetParent()
            outer:GetScript("OnMouseWheel")(outer, delta)
        end
    end)

    headerStrip = CreateFrame("Frame", nil, tableFrame)
    headerStrip:SetHeight(HEADER_HEIGHT)
    headerStrip:SetPoint("TOPLEFT", tableFrame, "TOPLEFT", 0, 0)
    local rule = headerStrip:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT", headerStrip, "BOTTOMLEFT", 0, -1)
    rule:SetPoint("TOPRIGHT", headerStrip, "BOTTOMRIGHT", 0, -1)
    rule:SetHeight(1)
    rule:SetColorTexture(1, 1, 1, 0.25)

    rowParent = CreateFrame("Frame", nil, tableFrame)
    rowParent:SetPoint("TOPLEFT", headerStrip, "BOTTOMLEFT", 0, -4)
    rowParent:SetSize(1, 1)

    headers, rows = {}, {}
    if sortDescending == nil then sortDescending = true end
    RebuildTable()
end

CastAheadWindow.Register("Casts", "Dungeon", Build, Refresh)
