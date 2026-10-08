-- /castahead - browse the tracked cast database and switch individual spells off.
--
-- This is an inspection tool: everything shown is harvested from combat logs and
-- MDT, so the point is to see how solid each row is - how many samples back it,
-- how tight the cooldown was, where the data is thin - and to sort by any of it.
-- Headers and cells are built from one column list, so they cannot drift apart.

local ROW_HEIGHT = 24
local WIDGET_HEIGHT = 20
local HEADER_HEIGHT = 18
local SCALE_STEPS = { 75, 100, 125, 150 }
local SCALE_MIN, SCALE_MAX, SCALE_DEFAULT = 75, 150, 100
local TITLE_HEIGHT = 22
local LIST_WIDTH = 190
-- Default and minimum window size: wide enough for every column, so nothing
-- is ever cut off. The grip resizes
-- the window within that floor (more rows); the Scale dropdown scales the
-- whole frame, text and chrome alike, the way Details and Plater do it.
local WINDOW_HEIGHT = 560
local COLUMN_GAP = 4
local THIN_EVIDENCE = 5      -- fewer samples than this and the row is dimmed

local window, body, dungeonButtons, rows, rowParent, headers, headerStrip, tableFrame
local selectedInstanceID, sortKey, sortDescending, searchText
-- The window is a book: the casts page (dungeon list, search, table) and one
-- page per settings group, built by Options.lua into `settingsHost`.
local castsPage, settingsHost, tabButtons, testButton, listButton
local savesPage, dungeonList, saveRows, saveParent
-- Forward declaration: RefreshTabs falls back to another page when the
-- Development tab is switched off, and it is defined above ShowTab.
local ShowTab
local currentTab = "Casts"
local CASTS_TAB = "Casts"
local SAVES_TAB = "Saves"
local GUIDE_TAB = "Guide"
local guidePage, guideText
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
            return advice and advice.label or "~"
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

local MAX_SAVE_ICONS = 5
local TRIGGER_WORDS = { { "cast", "cast" }, { "bar", "boss bar" }, { "debuff", "debuff" } }

local SAVE_COLUMNS = {
    { key = "size", header = "Save", width = 50,
      text = function(s)
          local advice = CastAheadMatch.ADVICE[s.size]
          return string.format("|cff%02x%02x%02x%s|r", advice.r * 255, advice.g * 255, advice.b * 255, advice.short)
      end },
    { key = "buttons", header = "Buttons", width = MAX_SAVE_ICONS * 18 },
    { key = "name", header = "Hit", width = 160, text = function(s) return s.name end },
    { key = "mob", header = "Mob", width = 150,
      text = function(s) return "|cff9999ff" .. (s.mob or "?") .. "|r" end },
    { key = "trigger", header = "Heard by", width = 130,
      text = function(s)
          local words = {}
          for _, w in ipairs(TRIGGER_WORDS) do
              if s.trigger[w[1]] then words[#words + 1] = w[2] end
          end
          return #words > 0 and table.concat(words, ", ") or "|cff777777not heard|r"
      end },
    { key = "lead", header = "Lead", width = 44, justify = "RIGHT",
      text = function(s) return s.lead and string.format("%.1fs", s.lead) or "-" end },
    { key = "wins", header = "", width = 110,
      text = function(s)
          local advice = s.wins and CastAheadMatch.ADVICE[s.wins]
          return advice and ("|cff777777says|r " .. advice.label) or ""
      end },
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

local tableColumns = COLUMNS

local function ColumnOffset(index, columns)
    columns = columns or tableColumns
    local x = 0
    for i = 1, index - 1 do
        x = x + columns[i].width + COLUMN_GAP
    end
    return x
end

local function TableWidth()
    return ColumnOffset(#tableColumns + 1)
end

local function WindowWidth()
    return LIST_WIDTH + 24 + ColumnOffset(#COLUMNS + 1, COLUMNS) + 34
end

local function WindowHeight()
    return WINDOW_HEIGHT
end

-- Never larger than the screen: a window that overflows it hides its own
-- controls, the Scale dropdown included, and there is no way back.
local function ApplyScale()
    local wanted = CastAheadConfig.Number("uiScale", SCALE_DEFAULT, SCALE_MIN, SCALE_MAX) / 100
    local fits = math.min(UIParent:GetWidth() / window:GetWidth(), UIParent:GetHeight() / window:GetHeight())
    window:SetScale(math.min(wanted, fits))
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
            row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
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
            row.inherit = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
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

-- Refresh ------------------------------------------------------------------

local function PaintDungeons()
    for i = 1, #dungeonButtons do
        local button = dungeonButtons[i]
        local selected = button.instanceID == selectedInstanceID
        button.text:SetTextColor(selected and 1 or 0.8, selected and 0.82 or 0.8, selected and 0 or 0.8)
    end
end

function Refresh()
    if not window or not window:IsShown() then return end
    local list = SortedRows()
    PaintDungeons()

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
    local width = TableWidth()
    tableFrame:SetWidth(width + 26)
    headerStrip:SetWidth(width)
    rowParent:SetWidth(width)
    for i = 1, #tableColumns do
        headers[i] = CreateHeader(headerStrip, i, tableColumns[i])
    end
    Refresh()
end

local function CreateSaveRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(ColumnOffset(#SAVE_COLUMNS + 1, SAVE_COLUMNS), ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row.cells, row.icons = {}, {}
    for i, column in ipairs(SAVE_COLUMNS) do
        local x = ColumnOffset(i, SAVE_COLUMNS)
        if column.key == "buttons" then
            for j = 1, MAX_SAVE_ICONS do
                local icon = row:CreateTexture(nil, "ARTWORK")
                icon:SetSize(16, 16)
                icon:SetPoint("LEFT", row, "LEFT", x + (j - 1) * 18, 0)
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                row.icons[j] = icon
            end
        else
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            text:SetPoint("LEFT", row, "LEFT", x, 0)
            text:SetWidth(column.width)
            text:SetJustifyH(column.justify or "LEFT")
            text:SetWordWrap(false)
            row.cells[column.key] = text
        end
    end
    row.group = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.group:SetPoint("LEFT", row, "LEFT", 0, 0)
    row:SetScript("OnEnter", function(self)
        if not self.save then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(self.save.id)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    return row
end

local ROLE_NAMES = { DAMAGER = "Damage", HEALER = "Healer", TANK = "Tank" }

local function RefreshGuide()
    if not (guidePage and guidePage:IsVisible()) then return end
    PaintDungeons()
    local lines = CastAheadSaves and CastAheadSaves.GuideLines and CastAheadSaves.GuideLines(selectedInstanceID) or {}
    if #lines == 0 then
        lines = { CastAheadMatch.SpecRole() and "Nothing in this dungeon calls a save for your role."
            or "No specialization role - pick a spec to see your guide." }
    end
    guideText:SetText(table.concat(lines, "\n"))
    guideText:GetParent():SetHeight(guideText:GetStringHeight() + 8)
end

local function RefreshSaves()
    if not (savesPage and savesPage:IsVisible()) then return end
    PaintDungeons()
    local saves = CastAheadSaves and CastAheadSaves.ViewRows and CastAheadSaves.ViewRows(selectedInstanceID) or {}
    local items, group = {}, nil
    for _, s in ipairs(saves) do
        if s.boss ~= group then
            group = s.boss
            items[#items + 1] = { header = s.boss ~= "" and ("Boss: " .. s.boss) or "Trash" }
        end
        items[#items + 1] = s
    end

    for i = 1, math.max(#items, #saveRows) do
        local item = items[i]
        if item and not saveRows[i] then saveRows[i] = CreateSaveRow(saveParent, i) end
        local row = saveRows[i]
        if item then
            local save = not item.header and item or nil
            row.save = save
            row.group:SetText(item.header or "")
            for _, column in ipairs(SAVE_COLUMNS) do
                local cell = row.cells[column.key]
                if cell then cell:SetText(save and column.text(save) or "") end
            end
            for j = 1, #row.icons do
                local button = save and save.buttons[j]
                row.icons[j]:SetTexture(button and button.icon or nil)
                row.icons[j]:SetShown(button and button.icon ~= nil or false)
                row.icons[j]:SetDesaturated(not (button and button.available))
                row.icons[j]:SetAlpha(button and button.available and 1 or 0.4)
            end
            row:Show()
        else
            row.save = nil
            row:Hide()
        end
    end
    saveParent:SetHeight(math.max(#items, 1) * ROW_HEIGHT)

    local role = CastAheadMatch.SpecRole()
    local line
    if not CastAheadConfig.Enabled("saveCalls") then
        line = "Defensive calls are off - switch them on in the Defensives tab."
    elseif not role then
        line = "No specialization role - pick a spec to see your saves."
    else
        line = "Role: " .. (ROLE_NAMES[role] or role) .. ". Change spec to see another role's list."
        if #saves == 0 then line = "Nothing here calls a save for your role. " .. line end
    end
    savesPage.role:SetText(line)
end

function CastAheadUI.RefreshSaves()
    RefreshSaves()
    RefreshGuide()
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

-- The Development page is the last tab and is off by default, so hiding its
-- button leaves the rest of the strip where it was. Called when the switch on
-- the General page is clicked, and once while the strip is built.
function CastAheadUI.RefreshTabs()
    if headerStrip and #SelectColumns(CastAheadConfig.Dev()) ~= #tableColumns then
        RebuildTable()
    end
    local button = tabButtons and tabButtons.Development
    if not button then return end
    local on = CastAheadOptions and CastAheadOptions.DevMode and CastAheadOptions.DevMode()
    button:SetShown(on and true or false)
    -- Switched off while its own page was open: fall back rather than leave
    -- the window showing a page with no way back to it.
    if not on and currentTab == "Development" then ShowTab("General") end
end

-- Switching pages. The casts page, the saves page and the settings host are
-- siblings filling the same area; exactly one of them is ever shown.
function ShowTab(name)
    currentTab = name
    for tab, button in pairs(tabButtons or {}) do
        button:SetEnabled(tab ~= name)
    end
    local settings = name ~= CASTS_TAB and name ~= SAVES_TAB and name ~= GUIDE_TAB
    if not settings and CastAheadOptions then CastAheadOptions.HideAll() end
    settingsHost:SetShown(settings)
    dungeonList:SetShown(not settings)
    castsPage:SetShown(name == CASTS_TAB)
    savesPage:SetShown(name == SAVES_TAB)
    guidePage:SetShown(name == GUIDE_TAB)
    if name == CASTS_TAB then
        Refresh()
    elseif name == SAVES_TAB then
        RefreshSaves()
    elseif name == GUIDE_TAB then
        RefreshGuide()
    elseif CastAheadOptions then
        CastAheadOptions.ShowPanel(settingsHost, name)
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
    window:SetSize(WindowWidth(), WindowHeight())
    window:SetPoint("CENTER")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:SetFrameStrata("DIALOG")
    window:SetResizable(true)
    if window.SetResizeBounds then
        window:SetResizeBounds(WindowWidth(), WindowHeight())
    end
    ApplyScale()

    body = CreateFrame("Frame", nil, window)
    body:SetPoint("TOPLEFT", window, "TOPLEFT", 0, -TITLE_HEIGHT)
    body:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", 0, 0)

    -- Whole-window scale, text included, for anyone the default is too small
    -- for. Bottom right next to the grip, on every page.
    local scale = CreateFrame("DropdownButton", nil, window, "WowStyle1DropdownTemplate")
    scale:SetSize(80, 20)
    scale:SetPoint("TOPRIGHT", window, "TOPRIGHT", -130, -28)
    scale.text = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    scale.text:SetPoint("RIGHT", scale, "LEFT", -6, 0)
    scale.text:SetText("Scale")
    local function Scale() return CastAheadConfig.Number("uiScale", SCALE_DEFAULT, SCALE_MIN, SCALE_MAX) end
    scale:SetupMenu(function(_, root)
        for _, value in ipairs(SCALE_STEPS) do
            root:CreateRadio(value .. "%", function() return Scale() == value end, function()
                CastAheadConfig.Set("uiScale", value ~= SCALE_DEFAULT and value or nil)
                ApplyScale()
            end)
        end
    end)

    local function RememberSize()
        CastAheadDB = CastAheadDB or {}
        CastAheadDB.window = CastAheadDB.window or {}
        CastAheadDB.window.width = window:GetWidth()
        CastAheadDB.window.height = window:GetHeight()
    end

    -- Grip in the bottom-right corner, as Blizzard resizable panels have.
    -- Resizing reveals more rows; the floor keeps every column on screen.
    local grip = CreateFrame("Button", nil, window)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    -- Doubled backslashes: Lua 5.1 quietly turns "\C" into "C", which left
    -- the grip with no texture at all.
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        -- Pin the top-left corner first: a CENTER-anchored frame grows from
        -- the middle, so the first drag frame jumped the window's size.
        local left, top = window:GetLeft(), window:GetTop()
        window:ClearAllPoints()
        window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        window:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        window:StopMovingOrSizing()
        RememberSize()
        ApplyScale()
        Refresh()
    end)
    table.insert(UISpecialFrames, "CastAheadWindow")   -- Escape closes it
    window.TitleText:SetText("Cast Ahead - tracked casts")

    -- Dry run of the selected dungeon's calls: icons, sounds, timeline. It sat
    -- squeezed against the close button, where nobody found it - it belongs on
    -- the tab row, which is the one strip visible on every page, and it says
    -- which half of the toggle it is rather than leaving the player guessing
    -- whether the run started.
    testButton = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    testButton:SetSize(110, 20)
    testButton:SetPoint("TOPRIGHT", body, "TOPRIGHT", -14, -6)
    testButton:SetScript("OnClick", function()
        if CastAheadCore and CastAheadCore.Test then CastAheadCore.Test(selectedInstanceID) end
    end)
    testButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Test drive", 1, 1, 1)
        GameTooltip:AddLine("Play the selected dungeon's calls with nothing pulled - icons on any nameplate in front of you, the centre call, the voice and the sounds. Click again to stop.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    testButton:SetScript("OnLeave", GameTooltip_Hide)

    listButton = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
    listButton:SetSize(90, 20)
    listButton:SetPoint("RIGHT", testButton, "LEFT", -4, 0)
    scale:ClearAllPoints()
    scale:SetPoint("RIGHT", listButton, "LEFT", -12, 0)
    listButton:SetScript("OnClick", function()
        if CastAheadCore and CastAheadCore.Test then CastAheadCore.Test(selectedInstanceID, SortedRows()) end
    end)
    listButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Play list", 1, 1, 1)
        GameTooltip:AddLine("Play every cast in the table, top to bottom in its current order, one at a time: the countdown, the call, the voice and the sound each one is set to. Click again to stop.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    listButton:SetScript("OnLeave", GameTooltip_Hide)
    CastAheadUI.RefreshTest()

    -- Tab strip: General first, then the casts and saves tables, then the other settings pages.
    tabButtons = {}
    local previousTab
    local names = {}
    for _, name in ipairs(CastAheadOptions and CastAheadOptions.TABS or {}) do
        names[#names + 1] = name
        if #names == 1 then
            names[#names + 1] = CASTS_TAB
            names[#names + 1] = SAVES_TAB
            names[#names + 1] = GUIDE_TAB
        end
    end
    if #names == 0 then names = { CASTS_TAB, SAVES_TAB, GUIDE_TAB } end
    for _, name in ipairs(names) do
        local button = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
        button:SetSize(78, 20)
        if previousTab then
            button:SetPoint("LEFT", previousTab, "RIGHT", 4, 0)
        else
            button:SetPoint("TOPLEFT", body, "TOPLEFT", 12, -6)
        end
        button:SetText(name)
        button:SetScript("OnClick", function() ShowTab(name) end)
        tabButtons[name] = button
        previousTab = button
    end
    CastAheadUI.RefreshTabs()

    -- The pages. All fill the area under the tab strip; the settings panels
    -- are built into the host on first use. The dungeon list belongs to both
    -- tables, so one selection drives either.
    castsPage = CreateFrame("Frame", nil, body)
    castsPage:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -30)
    castsPage:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)

    savesPage = CreateFrame("Frame", nil, body)
    savesPage:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -30)
    savesPage:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    savesPage:Hide()

    dungeonList = CreateFrame("Frame", nil, body)
    dungeonList:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -30)
    dungeonList:SetPoint("BOTTOMRIGHT", body, "BOTTOMLEFT", LIST_WIDTH + 24, 0)

    settingsHost = CreateFrame("Frame", nil, body)
    settingsHost:SetPoint("TOPLEFT", body, "TOPLEFT", 12, -34)
    settingsHost:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -12, 12)
    settingsHost:Hide()

    window.summary = castsPage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    window.summary:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 16, 12)

    -- Author's mark. Bottom centre because the left corner is the summary and the
    -- right one is the resize grip, and it belongs to the window rather than to a
    -- page so it stays put when the pages swap.
    window.madeIn = body:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    window.madeIn:SetPoint("BOTTOM", body, "BOTTOM", 0, 12)
    window.madeIn:SetText("|cFF0057B7Made|r |cFFFFD700in Ukraine|r")

    local search = CreateFrame("EditBox", nil, castsPage, "SearchBoxTemplate")
    search:SetSize(LIST_WIDTH - 8, 20)
    search:SetPoint("TOPLEFT", body, "TOPLEFT", 16, -34)
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
        local button = CreateFrame("Button", nil, dungeonList)
        button:SetSize(LIST_WIDTH, WIDGET_HEIGHT + 2)
        button:SetPoint("TOPLEFT", body, "TOPLEFT", 12, -60 - (i - 1) * (WIDGET_HEIGHT + 2))
        button.instanceID = entry.id
        button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.text:SetPoint("LEFT", button, "LEFT", 6, 0)
        button.text:SetText(string.format("%s |cff777777(%d)|r", entry.name, entry.count))
        button:SetScript("OnClick", function(self)
            selectedInstanceID = self.instanceID
            if currentTab == SAVES_TAB then RefreshSaves()
            elseif currentTab == GUIDE_TAB then RefreshGuide()
            else Refresh() end
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
    local sideScroll = CreateFrame("ScrollFrame", nil, castsPage)
    sideScroll:SetPoint("TOPLEFT", body, "TOPLEFT", LIST_WIDTH + 24, -36)
    sideScroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -8, 34)   -- above the summary line
    tableFrame = CreateFrame("Frame", nil, sideScroll)
    tableFrame:SetSize(1, 1)
    sideScroll:SetScrollChild(tableFrame)
    sideScroll:SetScript("OnSizeChanged", function(_, _, height) tableFrame:SetHeight(height) end)
    local function ScrollSideways(delta)
        local range = sideScroll:GetHorizontalScrollRange()
        sideScroll:SetHorizontalScroll(math.max(0, math.min(range, sideScroll:GetHorizontalScroll() - delta * 60)))
    end
    sideScroll:EnableMouseWheel(true)
    sideScroll:SetScript("OnMouseWheel", function(_, delta) ScrollSideways(delta) end)

    headerStrip = CreateFrame("Frame", nil, tableFrame)
    headerStrip:SetHeight(HEADER_HEIGHT)
    headerStrip:SetPoint("TOPLEFT", tableFrame, "TOPLEFT", 0, 0)
    local rule = headerStrip:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT", headerStrip, "BOTTOMLEFT", 0, -1)
    rule:SetPoint("TOPRIGHT", headerStrip, "BOTTOMRIGHT", 0, -1)
    rule:SetHeight(1)
    rule:SetColorTexture(1, 1, 1, 0.25)

    local scroll = CreateFrame("ScrollFrame", nil, tableFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", headerStrip, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", tableFrame, "BOTTOMRIGHT", -26, 0)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    local rowWheel = scroll:GetScript("OnMouseWheel")
    scroll:SetScript("OnMouseWheel", function(self, delta)
        if IsShiftKeyDown() then ScrollSideways(delta) else rowWheel(self, delta) end
    end)

    headers, rows = {}, {}
    rowParent = content
    RebuildTable()

    local saveClip = CreateFrame("Frame", nil, savesPage)
    saveClip:SetPoint("TOPLEFT", body, "TOPLEFT", LIST_WIDTH + 24, -36)
    saveClip:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -8, 34)
    if saveClip.SetClipsChildren then saveClip:SetClipsChildren(true) end
    local saveWidth = ColumnOffset(#SAVE_COLUMNS + 1, SAVE_COLUMNS)
    local saveHeader = CreateFrame("Frame", nil, saveClip)
    saveHeader:SetSize(saveWidth, HEADER_HEIGHT)
    saveHeader:SetPoint("TOPLEFT", saveClip, "TOPLEFT", 0, 0)
    for i, column in ipairs(SAVE_COLUMNS) do
        local label = saveHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetSize(column.width, HEADER_HEIGHT)
        label:SetPoint("TOPLEFT", saveHeader, "TOPLEFT", ColumnOffset(i, SAVE_COLUMNS), 0)
        label:SetText("|cffaaaaaa" .. column.header .. "|r")
    end
    local saveRule = saveHeader:CreateTexture(nil, "ARTWORK")
    saveRule:SetPoint("TOPLEFT", saveHeader, "BOTTOMLEFT", 0, -1)
    saveRule:SetPoint("TOPRIGHT", saveHeader, "BOTTOMRIGHT", 0, -1)
    saveRule:SetHeight(1)
    saveRule:SetColorTexture(1, 1, 1, 0.25)
    local saveScroll = CreateFrame("ScrollFrame", nil, saveClip, "UIPanelScrollFrameTemplate")
    saveScroll:SetPoint("TOPLEFT", saveHeader, "BOTTOMLEFT", 0, -4)
    saveScroll:SetPoint("BOTTOMRIGHT", saveClip, "BOTTOMRIGHT", -26, 0)
    saveParent = CreateFrame("Frame", nil, saveScroll)
    saveParent:SetSize(saveWidth, 1)
    saveScroll:SetScrollChild(saveParent)
    saveRows = {}
    savesPage.role = savesPage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    savesPage.role:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 16, 12)

    guidePage = CreateFrame("Frame", nil, body)
    guidePage:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -30)
    guidePage:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    guidePage:Hide()
    local guideScroll = CreateFrame("ScrollFrame", nil, guidePage, "UIPanelScrollFrameTemplate")
    guideScroll:SetPoint("TOPLEFT", body, "TOPLEFT", LIST_WIDTH + 24, -36)
    guideScroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -34, 34)
    local guideBody = CreateFrame("Frame", nil, guideScroll)
    guideBody:SetSize(600, 1)
    guideScroll:SetScrollChild(guideBody)
    guideText = guideBody:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    guideText:SetPoint("TOPLEFT", guideBody, "TOPLEFT", 4, -4)
    guideText:SetWidth(592)
    guideText:SetJustifyH("LEFT")
    guideText:SetSpacing(3)
    guideScroll:SetScript("OnSizeChanged", function(_, width)
        guideBody:SetWidth(width)
        guideText:SetWidth(width - 8)
        RefreshGuide()
    end)
    local saved = CastAheadDB and CastAheadDB.window
    if saved and saved.width and saved.height then
        window:SetSize(math.max(saved.width, WindowWidth()), math.max(saved.height, WindowHeight()))
    end
    ApplyScale()
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
        if window and window:IsShown() and currentTab ~= CASTS_TAB and currentTab ~= SAVES_TAB and currentTab ~= GUIDE_TAB then
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
        if not (window and window:IsShown()) then CastAhead_Toggle() end
    end)

    local category = Settings.RegisterCanvasLayoutCategory(panel, "Cast Ahead")
    category.ID = "CastAhead"
    Settings.RegisterAddOnCategory(category)
end

-- Registered as the file loads. The settings API is up before addons are, and
-- an event frame here would be the first OnEvent handler in the file, which is
-- what the stubbed API in the test suite hands events to.
RegisterSettingsCategory()
