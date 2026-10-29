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

local host, rows, rowParent, headers, headerStrip, tableFrame, sideScroll, listButton
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
    local advice = CastAheadMatch.Call(CastAheadMatch.Advice(entry), { entry })
    return advice and CastAheadDB and CastAheadDB.sounds and CastAheadDB.sounds[advice.sound or advice.key]
end

local function SetOwn(field, entry, value)
    CastAheadDB = CastAheadDB or {}
    CastAheadDB[field] = CastAheadDB[field] or {}
    CastAheadDB[field][entry.spell] = value
end

local function SetSpellLead(entry, seconds) SetOwn("spellLead", entry, seconds) end

-- Starred by the player, else curated and fit for this character.
local function Starred(entry)
    return CastAheadMatch.Important(entry)
end

-- What this cast does differently from the global settings, in a few words;
-- empty when nothing.
local function OverrideSummary(entry)
    local parts = {}
    local own = CastAheadConfig.SpellImportant(entry.spell)
    if own ~= nil then parts[#parts + 1] = own and "Important" or "Not important" end
    if CastAheadConfig.SpellMuted(entry.spell) then parts[#parts + 1] = "Muted" end
    local sound = SpellSound(entry)
    if sound then parts[#parts + 1] = sound ~= "" and sound or "Own sound: voice" end
    local lead = CastAheadConfig.SpellLead(entry.spell)
    if lead then parts[#parts + 1] = lead > 0 and string.format("Early %ds", lead) or "Early off" end
    return table.concat(parts, ", ")
end
CastAheadUI.OverrideSummary = OverrideSummary

local function HasOverrides(entry)
    for _, field in ipairs({ "spellImportant", "spellMute", "spellSounds", "spellLead" }) do
        if CastAheadDB and CastAheadDB[field] and CastAheadDB[field][entry.spell] ~= nil then return true end
    end
    return false
end

-- What a run does with the cast once the global settings apply: shown at all,
-- called out loud, and the reason when not.
local function RunState(entry)
    local hidden = "Not shown or called in combat: "
    if IsDisabled(entry.spell) then return false, false, hidden .. "switched off here." end
    if not CastAheadMatch.Shown(entry) then
        if CastAheadConfig.SpellImportant(entry.spell) == false and CastAheadMatch.ImportantOnly() then
            return false, false, hidden .. "you marked it not important, and \"Important casts only\" is on in General."
        end
        if not CastAheadMatch.FitsPlayer(entry) then
            return false, false, hidden .. "not for your role (\"My role only\" in General). Mark it important to show it anyway."
        end
        return false, false, hidden .. "not important, and \"Important casts only\" is on in General. Mark it important to show it."
    end
    local silent = "Shown in combat without a call: "
    if not CastAheadMatch.Advice(entry) then return true, false, silent .. "the logs give it no call, so only its icon and timer show." end
    if not CastAheadConfig.Enabled("sound") then return true, false, silent .. "Sound is off in General." end
    if CastAheadConfig.SpellMuted(entry.spell) then return true, false, silent .. "muted on this cast." end
    return true, true, nil
end
CastAheadUI.RunState = RunState

-- One tick when any setting of the cast differs from the global ones.
local function OverrideMark(entry)
    return HasOverrides(entry) and "|A:common-icon-checkmark:14:14|a" or ""
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
    return table.concat(parts, " / ") .. "s", entry.cd[1]
end

-- One definition per column drives the header, the cell and the sort, so a
-- header can never end up over the wrong values.
local COLUMNS = {
    { key = "check", header = "Enabled", width = 52 },
    -- Speaker: plays the row's voice line / alert on demand, so the calls can
    -- be auditioned outside a pull.
    { key = "hear", width = 18 },
    { key = "icon", width = 20 },
    -- A star marks what "Only important casts" keeps: the curated set unless
    -- the player starred or unstarred the cast; a click on it toggles that.
    { key = "prio", header = "Important", width = 70, justify = "CENTER",
      text = function(e) return Starred(e) and "|A:auctionhouse-icon-favorite:14:14|a" or "" end,
      sort = function(e) return Starred(e) and 1 or 0 end },
    {
        key = "advice", header = "Do", width = 88,
        text = function(e)
            local advice = CastAheadMatch.Advice(e)
            -- Neither curated nor loud enough in the logs to earn a verdict:
            -- say so, rather than leave a cell that looks like a glitch.
            if not advice then return "|cff555555-|r" end
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
    -- Only what differs from the global settings; a click on the row opens the panel.
    { key = "overrides", header = "Overrides", width = 80,
      text = function(e)
          if not CastAheadMatch.Advice(e) then return "|cff555555-|r" end
          return OverrideMark(e)
      end,
      sort = OverrideSummary },
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
        "Important casts are the ones worth reacting to. |cffffd100Important casts only|r in the General tab hides everything else. An important kick says \"must kick\", any other kick \"kick\", and so does a cast that could still be a not important one. Click a cell to mark a cast important or not." },
    advice = { "What to do",
        "The call made when this cast starts. A dash means the cast is tracked but has no call: it is rare in the logs and not important." },
    spell = { "Spell",
        "The cast being tracked. Hover a row for the spell tooltip." },
    overrides = { "Overrides",
        "A tick when any setting of the cast differs from the global ones: important or not, mute, its own sound or early warning. Hover a row for the details, click it to change them." },
    mob = { "Caster",
        "Which creature casts it. In 12.1 a nameplate never reveals a creature's name or ID, so this comes from combat logs - the addon only guesses which of them is in front of you." },
    level = { "Mob level",
        "One of the few things a hostile nameplate still reveals, so it is used to tell apart casts that look identical." },
    cast = { "Cast time",
        "How long the cast bar runs. |cffffd100ch|r marks a channel." },
    cd = { "Rotation",
        "Seconds from one start of this cast to the next. Several numbers are a repeating cycle, used in order." },
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
        "|cff40dd60Green|r means the game lets this cast be interrupted at all; |cff886666grey|r means it does not, whatever anyone tries. The number is how often the group actually landed a kick on it, so |cffffd100-|r on green only means no kick on it is logged yet." },
    cc = { "Stopped another way",
        "How often the cast started and never finished without an interrupt being logged - a stun, a knock, a fear. This is the column that says \"you cannot kick it, but you can stop it\". |cffffd100-|r means nobody in our logs ever stopped it, which is not proof that it cannot be stopped." },
}

-- Widgets ------------------------------------------------------------------

local Refresh, ToggleEditor, SetImportant

-- One cast's own settings, docked right of the table when the page has room
-- for it, else along the bottom. Unticked, a value setting follows the global
-- one, shown greyed so the player sees what the cast gets anyway.
local PANEL_W, PANEL_GAP, COL_W = 250, 12, 230
local editor, tableClipped

local function Reapply()
    if CastAheadCore and CastAheadCore.Reapply then CastAheadCore.Reapply() end
end

local function Check(parent, text, point, tip)
    local check = CreateFrame("CheckButton", nil, parent, "MinimalCheckboxTemplate")
    check:SetSize(WIDGET_HEIGHT, WIDGET_HEIGHT)
    check:SetPoint(unpack(point))
    check.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
    check.label:SetText(text)
    check:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(text)
        GameTooltip:AddLine(tip, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    check:SetScript("OnLeave", GameTooltip_Hide)
    return check
end

local function PaintEditor()
    local e = editor.entry
    editor.title:SetText(SpellName(e))
    editor.mob:SetText("|cff9999ff" .. (e.mob or "?") .. "|r")
    editor.important:SetChecked(Starred(e))
    -- The curated choice is worth a word only once the player overrode it.
    local curated = ""
    if CastAheadConfig.SpellImportant(e.spell) ~= nil then
        curated = CastAheadMatch.Curated(e) and "|cff888888curated: important|r" or "|cff888888curated: not important|r"
    end
    editor.curated:SetText(curated)
    local resettable = HasOverrides(e)
    editor.reset:SetEnabled(resettable)
    editor.reset:SetAlpha(resettable and 1 or 0.4)
    editor.mute:SetChecked(CastAheadConfig.SpellMuted(e.spell))
    local own = SpellSound(e)
    editor.ownSound:SetChecked(own ~= nil)
    editor.sound:SetEnabled(own ~= nil)
    editor.sound:GenerateMenu()
    local lead = CastAheadConfig.SpellLead(e.spell)
    editor.ownLead:SetChecked(lead ~= nil)
    editor.lead:SetEnabled(lead ~= nil)
    editor.lead.Repaint()
end

local function EditorChanged()
    PaintEditor()
    Refresh()
end

-- The player's star; matching the curated choice stores nothing.
function SetImportant(entry, on)
    if on == CastAheadMatch.Curated(entry) then on = nil end
    SetOwn("spellImportant", entry, on)
    Reapply()
    if editor and editor:IsShown() then PaintEditor() end
    Refresh()
end

-- Right of the table when it fits there, else a strip along the bottom. Both
-- hang off the scroll frame, so they stay put while the table scrolls.
-- `clip` cuts the table at that width, else it spans the page.
local function FitTable(clip)
    sideScroll:ClearAllPoints()
    sideScroll:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -TABLE_TOP)
    if clip then
        sideScroll:SetWidth(clip)
        sideScroll:SetHorizontalScroll(0)
    else
        sideScroll:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, -TABLE_TOP)
    end
end

-- Returns the height a bottom strip adds to the page, and whether the table
-- was cut short for a panel on the right.
local function LayoutEditor()
    if not (editor and editor:IsShown()) then
        FitTable(nil)
        return 0, false
    end
    local scroll, width = host:GetParent(), host:GetWidth()
    -- Short of room on the right, the table drops its Overrides column while
    -- the panel is open: that column only repeats what the panel shows.
    local last = tableColumns[#tableColumns]
    local covered = last.key == "overrides" and last.width + COLUMN_GAP or 0
    local fits = width - TableWidth() >= PANEL_W + PANEL_GAP
    local right = fits or width - TableWidth() + covered >= PANEL_W + PANEL_GAP
    FitTable(right and not fits and TableWidth() - covered or nil)
    editor:ClearAllPoints()
    editor.colB:ClearAllPoints()
    -- The two halves side by side only where both fit, else one under the other.
    local sideBySide = not right and width >= 2 * COL_W + 40
    if sideBySide then
        editor.colB:SetPoint("TOPLEFT", editor.colA, "TOPRIGHT", 20, 0)
    else
        editor.colB:SetPoint("TOPLEFT", editor.colA, "BOTTOMLEFT", 0, -10)
    end
    local height = sideBySide and 156 or 236
    -- Pinned to the scroll frame's edges rather than an offset from the page
    -- width, so the panel moves with the window edge while it is resized.
    if right then
        editor:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, -TABLE_TOP)
        editor:SetSize(PANEL_W, height)
        return 0, not fits
    end
    editor:SetPoint("BOTTOMLEFT", scroll, "BOTTOMLEFT", 0, 0)
    editor:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 0, 0)
    editor:SetHeight(height)
    return height, false
end

local function BuildEditor()
    editor = CreateFrame("Frame", nil, host)
    editor:SetFrameLevel(host:GetFrameLevel() + 50)
    editor:EnableMouse(true)
    editor:Hide()
    local edge = editor:CreateTexture(nil, "BACKGROUND")
    edge:SetAllPoints()
    edge:SetColorTexture(1, 1, 1, 0.25)
    local bg = editor:CreateTexture(nil, "BORDER")
    bg:SetPoint("TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", -1, 1)
    bg:SetColorTexture(0.05, 0.05, 0.07, 1)

    editor.title = editor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    editor.title:SetPoint("TOPLEFT", 10, -10)
    editor.title:SetPoint("TOPRIGHT", -110, -10)
    editor.title:SetJustifyH("LEFT")
    editor.title:SetWordWrap(false)
    editor.mob = editor:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    editor.mob:SetPoint("TOPLEFT", editor.title, "BOTTOMLEFT", 0, -4)
    local close = CreateFrame("Button", nil, editor, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function() ToggleEditor(nil) end)

    editor.colA = CreateFrame("Frame", nil, editor)
    editor.colA:SetSize(COL_W, 96)
    editor.colA:SetPoint("TOPLEFT", 10, -48)
    local a = editor.colA
    editor.important = Check(a, "Important", { "TOPLEFT", a, "TOPLEFT", 0, 0 },
        "Counts for \"Important casts only\" in General, and a kick on this cast says \"must kick\" instead of \"kick\". Starts as our curated choice.")
    editor.curated = a:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    editor.curated:SetPoint("LEFT", editor.important.label, "RIGHT", 8, 0)
    editor.important:SetScript("OnClick", function(self) SetImportant(editor.entry, self:GetChecked()) end)
    editor.mute = Check(a, "Mute", { "TOPLEFT", a, "TOPLEFT", 0, -26 },
        "No call for this cast. Its icon and bar still show.")
    editor.mute:SetScript("OnClick", function(self)
        SetOwn("spellMute", editor.entry, self:GetChecked() or nil)
        EditorChanged()
    end)
    editor.ownSound = Check(a, "Own sound", { "TOPLEFT", a, "TOPLEFT", 0, -52 },
        "A sound in place of the voice for this cast. Unticked, it uses its category's choice from the Sounds tab.")
    editor.ownSound:SetScript("OnClick", function(self)
        local e = editor.entry
        SetSpellSound(e, self:GetChecked() and (SpellSound(e) or "") or nil)
        EditorChanged()
    end)
    editor.sound = CreateFrame("DropdownButton", nil, a, "WowStyle1DropdownTemplate")
    editor.sound:SetSize(190, WIDGET_HEIGHT)
    editor.sound:SetPoint("TOPLEFT", a, "TOPLEFT", 24, -76)
    editor.sound:SetupMenu(function(_, root)
        local e = editor.entry
        if not (e and CastAheadOptions and CastAheadOptions.SoundMenu) then return end
        CastAheadOptions.SoundMenu(root,
            function()
                local own = SpellSound(e)
                if own == nil then return CategorySound(e) end
                return own ~= "" and own or nil
            end,
            function(name)
                SetSpellSound(e, name or "")
                EditorChanged()
            end,
            CastAheadMatch.Call(CastAheadMatch.Advice(e), { e }))
    end)

    editor.colB = CreateFrame("Frame", nil, editor)
    editor.colB:SetSize(COL_W, 80)
    local b = editor.colB
    editor.ownLead = Check(b, "Own early warning", { "TOPLEFT", b, "TOPLEFT", 0, 0 },
        "Seconds before this cast to announce it, 0 for none. Unticked, it uses the early warning from General.")
    editor.ownLead:SetScript("OnClick", function(self)
        SetSpellLead(editor.entry, self:GetChecked() and CastAheadConfig.Lead() or nil)
        EditorChanged()
    end)
    editor.lead = CastAheadOptions.BuildSlider(b, {
        min = 0, max = CastAheadConfig.LEAD_MAX,
        low = "off", high = CastAheadConfig.LEAD_MAX .. "s",
        width = 180,
        point = { "TOPLEFT", editor.ownLead, "BOTTOMLEFT", 24, -2 },
        read = function()
            local e = editor.entry
            return e and CastAheadConfig.SpellLead(e.spell) or CastAheadConfig.Lead()
        end,
        write = function(value)
            SetSpellLead(editor.entry, value)
            Refresh()
        end,
        caption = function(value)
            local e = editor.entry
            local suffix = value > 0 and string.format("%ds", value) or "off"
            if e and CastAheadConfig.SpellLead(e.spell) then return "Early warning: " .. suffix end
            return "|cff888888Early warning: global " .. suffix .. "|r"
        end,
    })

    local reset = CastAheadWindow.Button(editor, "Reset", 60)
    reset:SetPoint("RIGHT", close, "LEFT", -20, 0)
    editor.reset = reset
    reset:SetScript("OnClick", function()
        local e = editor.entry
        for _, field in ipairs({ "spellImportant", "spellMute", "spellSounds", "spellLead" }) do
            SetOwn(field, e, nil)
        end
        Reapply()
        EditorChanged()
    end)
end

-- Opens the panel on a cast, or closes it when that cast is already open
-- (or for nil).
function ToggleEditor(entry)
    if not editor then BuildEditor() end
    if not entry or editor:IsShown() and editor.entry == entry then
        editor:Hide()
    else
        editor.entry = entry
        editor:Show()
        PaintEditor()
    end
    Refresh()
end

local mobModel

local function ShowMobModel(owner, entry)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(string.format("%s (npc %d)", entry.mob or "?", entry.npc or 0), 0.6, 0.6, 1)
    GameTooltip:Show()
    if not entry.npc then return end
    if not mobModel then
        mobModel = CreateFrame("PlayerModel", nil, UIParent)
        mobModel:SetSize(200, 200)
        mobModel:SetFrameStrata("TOOLTIP")
        local bg = mobModel:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.85)
    end
    mobModel:ClearAllPoints()
    mobModel:SetPoint("TOPLEFT", GameTooltip, "BOTTOMLEFT", 0, -2)
    mobModel:ClearModel()
    mobModel:SetCreature(entry.npc)
    mobModel:Show()
end

local function HideMobModel()
    GameTooltip:Hide()
    if mobModel then mobModel:Hide() end
end

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
    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(1, 0.82, 0, 0.12)
    row.selected:Hide()

    for i = 1, #tableColumns do
        local column = tableColumns[i]
        local x = ColumnOffset(i)
        if column.key == "check" then
            row.check = CreateFrame("CheckButton", nil, row, "MinimalCheckboxTemplate")
            row.check:SetSize(WIDGET_HEIGHT, WIDGET_HEIGHT)
            row.check:SetPoint("LEFT", row, "LEFT", x + (column.width - WIDGET_HEIGHT) / 2, 0)
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
            if column.key == "mob" then
                -- It takes the mouse over the cell, so a click is handed on to the row.
                local hover = CreateFrame("Button", nil, row)
                hover:SetPoint("TOPLEFT", row, "TOPLEFT", x, 0)
                hover:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", x, 0)
                hover:SetWidth(column.width)
                hover:SetScript("OnClick", function() row:Click() end)
                hover:SetScript("OnEnter", function(self)
                    row:LockHighlight()
                    if row.entry then ShowMobModel(self, row.entry) end
                end)
                hover:SetScript("OnLeave", function()
                    row:UnlockHighlight()
                    HideMobModel()
                end)
            end
            if column.key == "cd" then
                -- A "~" inside the text sits at the top of the line, so it gets
                -- its own font string, lowered to the middle.
                row.approx = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.approx:SetText("|cffff8800~|r")
            end
            if column.key == "prio" then
                local star = CreateFrame("Button", nil, row)
                star:SetPoint("TOPLEFT", row, "TOPLEFT", x, 0)
                star:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", x, 0)
                star:SetWidth(column.width)
                star:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                star:SetScript("OnClick", function()
                    local e = row.entry
                    if e and CastAheadMatch.Advice(e) then SetImportant(e, not Starred(e)) end
                end)
            end
        end
    end

    row:SetScript("OnEnter", function(self)
        if not self.entry then return end
        local e = self.entry
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(e.spell)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(string.format("%s (npc %d)", e.mob or "?", e.npc or 0), 0.6, 0.6, 1)
        local own = OverrideSummary(e)
        if own ~= "" then GameTooltip:AddLine("Own settings: " .. own, 1, 0.82, 0) end
        local _, _, why = RunState(e)
        if why then GameTooltip:AddLine(why, 1, 0.5, 0.2, true) end
        GameTooltip:AddLine(string.format("%d observations in the logs", e.n or 0), 0.7, 0.7, 0.7)
        GameTooltip:AddLine(string.format("Interrupted: %d%% of casts. Stopped another way: %d%%.",
            (e.kick or 0) * 100, (e.cc or 0) * 100), 0.7, 0.7, 0.7)
        if e.dmg then
            GameTooltip:AddLine(string.format("Hits about %.0f player(s); the worst hit takes %d%% of max health (absorbs included)",
                e.hits or 1, e.dmg * 100), 0.7, 0.7, 0.7)
        end
        if (e.n or 0) < THIN_EVIDENCE then
            GameTooltip:AddLine("Few casts seen - its timings are a rough estimate", 1, 0.5, 0.2)
        end
        if CastAheadMatch.Advice(e) then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click to edit this cast", 0.4, 0.8, 1)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row:SetScript("OnClick", function(self)
        if self.entry and CastAheadMatch.Advice(self.entry) then ToggleEditor(self.entry) end
    end)
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
    sideScroll:SetHorizontalScroll(0)
    for i = 1, #tableColumns do
        headers[i] = CreateHeader(headerStrip, i, tableColumns[i])
    end
end

-- The table reads in blocks by what combat does with each cast, so the
-- outcome shows by where a row sits.
local SECTIONS = {
    { key = "call", title = "In combat with a call" },
    { key = "silent", title = "In combat without sound", why = "muted, no call for it, or Sound is off in General" },
    { key = "hidden", title = "Hidden in combat",
      why = "switched off, not important with Important casts only, or not for your role - hover a row" },
}
local SECTION_H = 26
local sectionRows = {}

local function SectionOf(entry)
    local shown, loud = RunState(entry)
    if not shown then return "hidden" end
    return loud and "call" or "silent"
end

local function Grouped(list)
    local groups = { call = {}, silent = {}, hidden = {} }
    for _, entry in ipairs(list) do
        local group = groups[SectionOf(entry)]
        group[#group + 1] = entry
    end
    return groups
end

-- The table's order, block by block, for Play list.
local function DisplayOrder()
    local groups, out = Grouped(SortedRows()), {}
    for _, section in ipairs(SECTIONS) do
        for _, entry in ipairs(groups[section.key]) do out[#out + 1] = entry end
    end
    return out
end

local function SectionRow(i)
    local s = sectionRows[i]
    if s then return s end
    s = CreateFrame("Frame", nil, rowParent)
    s:SetHeight(SECTION_H)
    s.text = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    s.text:SetPoint("BOTTOMLEFT", s, "BOTTOMLEFT", 4, 5)
    s.why = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    s.why:SetPoint("LEFT", s.text, "RIGHT", 12, 0)
    local line = s:CreateTexture(nil, "ARTWORK")
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    line:SetHeight(1)
    line:SetColorTexture(1, 0.82, 0, 0.3)
    sectionRows[i] = s
    return s
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

    local groups = Grouped(list)

    local editing, y, n, shownSections = false, 0, 0, 0
    for _, section in ipairs(SECTIONS) do
        local items = groups[section.key]
        if #items > 0 then
            shownSections = shownSections + 1
            local s = SectionRow(shownSections)
            s:ClearAllPoints()
            s:SetPoint("TOPLEFT", rowParent, "TOPLEFT", 0, -y)
            s:SetPoint("TOPRIGHT", rowParent, "TOPRIGHT", 0, -y)
            s.text:SetText(string.format("%s (%d)", section.title, #items))
            s.why:SetText(section.why or "")
            s:Show()
            y = y + SECTION_H
        end
        for _, entry in ipairs(items) do
            n = n + 1
            if not rows[n] then rows[n] = CreateRow(rowParent, n) end
            local row = rows[n]
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", rowParent, "TOPLEFT", 0, -y)
            y = y + ROW_HEIGHT
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
            local cd = row.cells.cd
            row.approx:SetShown(entry.approx and CastAheadMatch.HasSchedule(entry) or false)
            row.approx:ClearAllPoints()
            row.approx:SetPoint("RIGHT", cd, "RIGHT", -cd:GetStringWidth() - 1, -3)
            row.approx:SetAlpha(alpha)
            -- Nothing to say for a row with no verdict - no speaker, no sound.
            row.hear:SetShown(CastAheadMatch.Advice(entry) ~= nil)
            local selected = editor and editor:IsShown() and editor.entry == entry
            if selected then editing = true end
            row.selected:SetShown(selected or false)
            row.check:SetChecked(not IsDisabled(entry.spell))
            row.check:SetScript("OnClick", function(self)
                SetDisabled(entry.spell, not self:GetChecked())
                if CastAheadCore and CastAheadCore.Reapply then CastAheadCore.Reapply() end
                Refresh()
            end)
            row:Show()
        end
    end
    for i = shownSections + 1, #sectionRows do sectionRows[i]:Hide() end
    for i = n + 1, #rows do
        rows[i].entry = nil
        rows[i]:Hide()
    end

    -- The cast being edited left the table (another dungeon, a search).
    if editor and editor:IsShown() and not editing then editor:Hide() end
    -- A bottom strip covers the last rows, so the page grows by its height.
    local bottom
    bottom, tableClipped = LayoutEditor()

    local rowsHeight = math.max(y, ROW_HEIGHT)
    rowParent:SetHeight(rowsHeight)
    tableFrame:SetHeight(HEADER_HEIGHT + 4 + rowsHeight)
    sideScroll:SetHeight(HEADER_HEIGHT + 4 + rowsHeight)
    host:SetHeight(TABLE_TOP + HEADER_HEIGHT + 4 + rowsHeight + bottom)

    local dungeon = CastAheadWindow.Dungeon()
    local total = dungeon and #(CastAheadData[dungeon] or {}) or 0
    local starred = 0
    for i = 1, #list do
        if Starred(list[i]) then starred = starred + 1 end
    end
    local dungeons = 0
    for _ in pairs(CastAheadData) do dungeons = dungeons + 1 end
    local summary = string.format("%d of %d casts listed, %d important | %d dungeons in the database",
        #list, total, starred, dungeons)
    -- Both outputs off looks exactly like a broken addon, so say it plainly.
    if not CastAheadConfig.Enabled("nameplates") and not CastAheadConfig.Enabled("timeline") then
        summary = "|cffff3333Both outputs are off - nothing will be shown in combat|r"
    end
    CastAheadWindow.SetFooter(summary)
    -- A table cut for the panel has nothing to scroll sideways to.
    if tableClipped then
        CastAheadWindow.SetFooterHint("")
    else
        CastAheadWindow.SideHint(sideScroll, tableFrame)
    end
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

    listButton = CastAheadWindow.Button(host, "Play list", 80, false)
    listButton:SetPoint("LEFT", search, "RIGHT", 8, 0)
    listButton:SetScript("OnClick", function()
        if CastAheadCore and CastAheadCore.Test then
            CastAheadCore.Test(CastAheadWindow.Dungeon(), DisplayOrder())
        end
    end)
    listButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Play list", 1, 1, 1)
        GameTooltip:AddLine("Play every cast in the table, top to bottom in its current order, one at a time: the countdown, the call, the voice and the sound each one is set to. Click again to stop.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    listButton:SetScript("OnLeave", GameTooltip_Hide)
    local hint = host:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", listButton, "RIGHT", 12, 0)
    hint:SetText("Click a cast to change its settings")
    CastAheadUI.RefreshTest()

    sideScroll, tableFrame = CastAheadWindow.SideScroll(host, TABLE_TOP)
    sideScroll:SetScript("OnSizeChanged", function(self)
        if not tableClipped then CastAheadWindow.SideHint(self, tableFrame) end
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
    -- A resized window may move the edit panel between the right and the bottom.
    host:HookScript("OnSizeChanged", function()
        if editor and editor:IsShown() then Refresh() end
    end)
    if sortDescending == nil then sortDescending = true end
    RebuildTable()
end

function CastAheadUI.RefreshPlayList(running)
    if listButton then listButton:SetText(running and "Stop" or "Play list") end
end

CastAheadWindow.Register("Casts", "Dungeon", Build, Refresh)
