local ROW_HEIGHT = 24
local HEADER_HEIGHT = 18
local COLUMN_GAP = 4
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

local SAVE_WIDTH = 0
for _, column in ipairs(SAVE_COLUMNS) do
    column.x = SAVE_WIDTH
    SAVE_WIDTH = SAVE_WIDTH + column.width + COLUMN_GAP
end

local ROLE_NAMES = { DAMAGER = "Damage", HEALER = "Healer", TANK = "Tank" }

local savesHost, saveRows, saveParent, saveSide, saveTable, guideHost, guideText
local savesTop, guideTop = 0, 0

local SPEC_W, SPEC_GAP, SPEC_BAR_H = 150, 4, 28
local specBars = {}

local function Specs()
    local out = {}
    if not (GetNumSpecializations and GetSpecializationInfo) then return out end
    for i = 1, GetNumSpecializations() or 0 do
        local id, name, _, icon = GetSpecializationInfo(i)
        if id then out[#out + 1] = { id = id, name = name, icon = icon } end
    end
    return out
end

local function PaintSpecBars()
    local S = CastAheadSaves
    local viewing = S and S.ViewSpecID()
    local T = CastAheadWindow.THEME
    for _, bar in ipairs(specBars) do
        for _, b in ipairs(bar.buttons) do
            local on = b.specID == viewing
            b:SetBackdropColor(unpack(on and T.selected or T.panel))
            b.label:SetTextColor(unpack(on and T.gold or T.text))
        end
    end
end

-- One row of the class's specs on top of a Dungeon page; picking one shows
-- that spec's buttons and role without changing spec. Returns the height
-- the page content has to leave above itself: 0 for a class with one spec.
local function BuildSpecBar(host)
    local specs = Specs()
    if #specs < 2 then return 0 end
    local bar = { buttons = {} }
    for i, spec in ipairs(specs) do
        local b = CastAheadWindow.Button(host, string.format("|T%s:14|t %s", spec.icon or "", spec.name or ""), SPEC_W)
        b.specID = spec.id
        b:SetPoint("TOPLEFT", host, "TOPLEFT", (i - 1) * (SPEC_W + SPEC_GAP), 0)
        b:SetScript("OnClick", function()
            CastAheadSaves.SetViewSpec(spec.id)
            CastAheadUI.RefreshSaves()
        end)
        bar.buttons[i] = b
    end
    specBars[#specBars + 1] = bar
    return SPEC_BAR_H
end

local function CreateSaveRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(SAVE_WIDTH, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row.cells, row.icons = {}, {}
    for _, column in ipairs(SAVE_COLUMNS) do
        if column.key == "buttons" then
            for j = 1, MAX_SAVE_ICONS do
                local icon = row:CreateTexture(nil, "ARTWORK")
                icon:SetSize(16, 16)
                icon:SetPoint("LEFT", row, "LEFT", column.x + (j - 1) * 18, 0)
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                row.icons[j] = icon
            end
        else
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            text:SetPoint("LEFT", row, "LEFT", column.x, 0)
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

local function RefreshGuide()
    if not (guideHost and guideHost:IsVisible()) then return end
    local lines = CastAheadSaves and CastAheadSaves.GuideLines and CastAheadSaves.GuideLines(CastAheadWindow.Dungeon()) or {}
    if #lines == 0 then
        lines = { CastAheadSaves.ViewRole() and "Nothing in this dungeon calls a save for this role."
            or "No specialization role - pick a spec to see your guide." }
    end
    guideText:SetText(table.concat(lines, "\n"))
    guideHost:SetHeight(guideTop + guideText:GetStringHeight() + 8)
    PaintSpecBars()
end

local function RefreshSaves()
    if not (savesHost and savesHost:IsVisible()) then return end
    local saves = CastAheadSaves and CastAheadSaves.ViewRows and CastAheadSaves.ViewRows(CastAheadWindow.Dungeon()) or {}
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
    local rowsHeight = math.max(#items, 1) * ROW_HEIGHT
    saveParent:SetHeight(rowsHeight)
    saveTable:SetHeight(HEADER_HEIGHT + 4 + rowsHeight)
    saveSide:SetHeight(HEADER_HEIGHT + 4 + rowsHeight)
    savesHost:SetHeight(savesTop + HEADER_HEIGHT + 4 + rowsHeight)

    local S = CastAheadSaves
    local role, own = S.ViewRole(), S.ViewSpecID() == S.SpecID()
    local line
    if not CastAheadConfig.Enabled("saveCalls") then
        line = "Defensive calls are off - switch them on in the Defensives tab."
    elseif not role then
        line = "No specialization role - pick a spec to see your saves."
    else
        line = "Role: " .. (ROLE_NAMES[role] or role) .. (own and "." or " - another spec's list, its buttons are not learned now.")
        if #saves == 0 then line = "Nothing here calls a save for this role. " .. line end
    end
    CastAheadWindow.SetFooter(line)
    CastAheadWindow.SideHint(saveSide, saveTable)
    PaintSpecBars()
end

function CastAheadUI.RefreshSaves()
    RefreshSaves()
    RefreshGuide()
end

local function BuildSaves(host)
    savesHost = host
    savesTop = BuildSpecBar(host)
    saveSide, saveTable = CastAheadWindow.SideScroll(host, savesTop)
    saveTable:SetWidth(SAVE_WIDTH)
    local saveHeader = CreateFrame("Frame", nil, saveTable)
    saveHeader:SetSize(SAVE_WIDTH, HEADER_HEIGHT)
    saveHeader:SetPoint("TOPLEFT", saveTable, "TOPLEFT", 0, 0)
    for _, column in ipairs(SAVE_COLUMNS) do
        local label = saveHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetSize(column.width, HEADER_HEIGHT)
        label:SetPoint("TOPLEFT", saveHeader, "TOPLEFT", column.x, 0)
        label:SetText("|cffaaaaaa" .. column.header .. "|r")
    end
    local saveRule = saveHeader:CreateTexture(nil, "ARTWORK")
    saveRule:SetPoint("TOPLEFT", saveHeader, "BOTTOMLEFT", 0, -1)
    saveRule:SetPoint("TOPRIGHT", saveHeader, "BOTTOMRIGHT", 0, -1)
    saveRule:SetHeight(1)
    saveRule:SetColorTexture(1, 1, 1, 0.25)
    saveParent = CreateFrame("Frame", nil, saveTable)
    saveParent:SetSize(SAVE_WIDTH, 1)
    saveParent:SetPoint("TOPLEFT", saveHeader, "BOTTOMLEFT", 0, -4)
    saveRows = {}
end

local function BuildGuide(host)
    guideHost = host
    guideTop = BuildSpecBar(host)
    guideText = host:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    guideText:SetPoint("TOPLEFT", host, "TOPLEFT", 4, -(guideTop + 4))
    guideText:SetWidth(math.max((host:GetWidth() or 0) - 8, 1))
    guideText:SetJustifyH("LEFT")
    guideText:SetSpacing(3)
    host:SetScript("OnSizeChanged", function(_, width)
        guideText:SetWidth(width - 8)
        RefreshGuide()
    end)
end

CastAheadWindow.Register("Guide", "Dungeon", BuildGuide, RefreshGuide, "Casts")
CastAheadWindow.Register("Saves", "Dungeon", BuildSaves, RefreshSaves, "Casts")
