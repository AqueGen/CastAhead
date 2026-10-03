CastAheadReport = {}
local W = CastAheadReport

local ROWS = 8
local ROW_H = 20
local panel, noteBox, window, ticker
local pendingMark, keyIndex

local function SpellLabel(spell)
    local id = tonumber(spell)
    local info = id and C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
    return info and info.name or (spell or "?")
end

local function SpellIcon(spell)
    local id = tonumber(spell)
    return id and C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(id) or 136243
end

local function StateText(entry)
    if entry.state == "casting" then return "|cffffd100casting|r" end
    if entry.state == "dead" then return "|cff999999dead|r" end
    return string.format("%ds ago", math.floor(entry.ago + 0.5))
end

local function SaveNote()
    if noteBox and noteBox:IsShown() and pendingMark then
        CastAheadRecorder.AddNote(pendingMark.n, noteBox:GetText(), pendingMark.key)
        noteBox:SetText("")
        noteBox:ClearFocus()
        noteBox:Hide()
    end
    pendingMark = nil
end

local function Paint()
    if not panel or not panel:IsShown() then return end
    local list = CastAheadRecorder.Recent()
    for i = 1, ROWS do
        local row, entry = panel.rows[i], list[i]
        if entry then
            row.entry = entry
            row.icon:SetTexture(SpellIcon(entry.spell))
            row.text:SetText(string.format("%s  %s  %s", SpellLabel(entry.spell), entry.call or "-", StateText(entry)))
            row.selected:SetShown(entry.selected)
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end
    panel.empty:SetShown(#list == 0)
end

function W.Mark(withNote)
    if not (CastAheadRecorder and CastAheadRecorder.Enabled()) then return end
    SaveNote()
    local n, key = CastAheadRecorder.Mark()
    Paint()
    if withNote and n and noteBox and panel and panel:IsVisible() then
        pendingMark = { n = n, key = key }
        noteBox:Show()
        noteBox:SetFocus()
    end
end

local function Build()
    panel = CreateFrame("Frame", "CastAheadMarkPanel", UIParent, "BackdropTemplate")
    panel:SetSize(300, 64 + ROWS * ROW_H)
    panel:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)
    panel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    panel:SetBackdropColor(0, 0, 0, 0.6)
    panel:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relative, x, y = self:GetPoint()
        CastAheadDB = CastAheadDB or {}
        CastAheadDB.markPanel = { point, relative, x, y }
    end)
    local saved = CastAheadDB and CastAheadDB.markPanel
    if saved then
        panel:ClearAllPoints()
        panel:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
    end

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 6, -5)
    title:SetText("Cast Ahead - mark a wrong call")

    panel.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, panel)
        row:SetSize(288, ROW_H - 2)
        row:SetPoint("TOPLEFT", 6, -20 - (i - 1) * ROW_H)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.selected = row:CreateTexture(nil, "BACKGROUND")
        row.selected:SetAllPoints()
        row.selected:SetColorTexture(1, 0.82, 0, 0.25)
        row:SetScript("OnClick", function(self)
            if self.entry then CastAheadRecorder.Select(self.entry.id) Paint() end
        end)
        panel.rows[i] = row
    end
    panel.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.empty:SetPoint("TOPLEFT", 8, -24)
    panel.empty:SetText("No mobs yet - a mark records the whole moment")

    local mark = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    mark:SetSize(90, 20)
    mark:SetPoint("BOTTOMLEFT", 6, 6)
    mark:SetText("Mark")
    mark:SetScript("OnClick", function() W.Mark(false) end)
    local markNote = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    markNote:SetSize(110, 20)
    markNote:SetPoint("LEFT", mark, "RIGHT", 4, 0)
    markNote:SetText("Mark + note")
    markNote:SetScript("OnClick", function() W.Mark(true) end)

    noteBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    noteBox:SetSize(280, 20)
    noteBox:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 10, -2)
    noteBox:SetAutoFocus(false)
    noteBox:SetMaxLetters(200)
    noteBox:SetScript("OnEnterPressed", SaveNote)
    noteBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        SaveNote()
    end)
    noteBox:Hide()
end

function W.Refresh()
    local want = CastAheadRecorder and CastAheadRecorder.Enabled()
        and ((IsInInstance and IsInInstance()) or (UnitAffectingCombat and UnitAffectingCombat("player")))
    if want and not panel then Build() end
    if not panel then return end
    panel:SetShown(want and true or false)
    if want and not ticker and C_Timer and C_Timer.NewTicker then
        ticker = C_Timer.NewTicker(0.5, Paint)
    elseif not want and ticker then
        ticker:Cancel()
        ticker = nil
    end
    Paint()
end

local function BuildWindow()
    window = CreateFrame("Frame", "CastAheadReportWindow", UIParent, "BasicFrameTemplateWithInset")
    window:SetSize(640, 460)
    window:SetPoint("CENTER")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    local title = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Cast Ahead - report")
    local hint = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 12, -30)
    hint:SetText("Ctrl+C, then paste into an issue at github.com/AqueGen/CastAhead or a CurseForge comment.")
    window.keys = CreateFrame("DropdownButton", nil, window, "WowStyle1DropdownTemplate")
    window.keys:SetSize(300, 22)
    window.keys:SetPoint("TOPLEFT", 12, -48)
    local scroll = CreateFrame("ScrollFrame", nil, window, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -80)
    scroll:SetPoint("BOTTOMRIGHT", -30, 12)
    window.box = CreateFrame("EditBox", nil, scroll)
    window.box:SetMultiLine(true)
    window.box:SetFontObject(ChatFontNormal)
    window.box:SetWidth(580)
    window.box:SetAutoFocus(false)
    window.box:SetScript("OnEscapePressed", function() window:Hide() end)
    scroll:SetScrollChild(window.box)
    table.insert(UISpecialFrames, "CastAheadReportWindow")
end

local function Fill()
    local keys = CastAheadRecorder.Keys()
    if not keyIndex or not keys[keyIndex] then keyIndex = #keys end
    window.keys:SetupMenu(function(_, root)
        for i = #keys, 1, -1 do
            local k = keys[i]
            root:CreateRadio(string.format("%s +%s, %d marks", k.name or "?", k.level or 0, k.marks or 0),
                function() return keyIndex == i end, function() keyIndex = i Fill() end)
        end
    end)
    local key = keys[keyIndex]
    window.box:SetText(key and CastAheadRecorder.Export(key)
        or "Nothing recorded yet. Turn on Development mode and the key journal, then mark wrong calls in a key.")
    window.box:HighlightText()
    window.box:SetFocus()
end

function W.Toggle()
    if not CastAheadRecorder then return end
    if not window then BuildWindow() end
    if window:IsShown() then window:Hide() return end
    window:Show()
    Fill()
end
