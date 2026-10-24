local ROW_HEIGHT = 24
local HEADER_HEIGHT = 18
local COLUMN_GAP = 4
local MAX_SAVE_ICONS = 5
local TRIGGER_WORDS = { { "cast", "cast" }, { "bar", "boss timer" }, { "debuff", "debuff" } }

local SAVE_COLUMNS = {
    { key = "buttons", header = "Buttons", width = MAX_SAVE_ICONS * 18 },
    { key = "name", header = "Hit", width = 160,
      text = function(s)
          local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(s.id)
          return icon and ("|T" .. icon .. ":16|t " .. s.name) or s.name
      end },
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
    { key = "ep", header = "Damage at +20", width = 90, justify = "RIGHT",
      text = function(s) return s.ep and (s.ep .. "%") or "-" end },
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

local function CreateSaveRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(SAVE_WIDTH, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row.cells, row.icons, row.iconHits = {}, {}, {}
    for _, column in ipairs(SAVE_COLUMNS) do
        if column.key == "buttons" then
            for j = 1, MAX_SAVE_ICONS do
                local hit = CreateFrame("Button", nil, row)
                hit:SetSize(16, 16)
                hit:SetPoint("LEFT", row, "LEFT", column.x + (j - 1) * 18, 0)
                hit:SetScript("OnEnter", function(self)
                    local e = self.entry
                    if not e then return end
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if e.kind == "item" and e.id then
                        GameTooltip:SetItemByID(e.id)
                    else
                        GameTooltip:SetSpellByID(e.kind == "item" and e.use or e.id)
                    end
                    GameTooltip:Show()
                end)
                hit:SetScript("OnLeave", GameTooltip_Hide)
                local icon = hit:CreateTexture(nil, "ARTWORK")
                icon:SetAllPoints()
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                row.icons[j], row.iconHits[j] = icon, hit
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

local NOTE_H = 30

local function EpNote(host, y, text)
    if not CastAheadSaves then return 0 end
    local note = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", host, "TOPLEFT", 4, -y)
    note:SetPoint("TOPRIGHT", host, "TOPRIGHT", -4, -y)
    note:SetHeight(NOTE_H)
    note:SetJustifyH("LEFT")
    note:SetJustifyV("TOP")
    note:SetText(text or CastAheadSaves.EP_NOTE)
    return NOTE_H
end

local RESTART = "Restart the game to finish the Cast Ahead update - defensive calls are off until then."

-- One Saves page: a table of the save rows for the picked place (a dungeon, or a raid difficulty).
-- headers renames columns and note replaces the damage note where the dungeon wording does not fit.
local function SavesPage(rowsFor, callsOn, offText, headers, note)
    local host, rows, parent, side, tbl, top = nil, {}, nil, nil, nil, 0
    local function Refresh()
        if not (host and host:IsVisible()) then return end
        if not CastAheadSaves then
            CastAheadWindow.SetFooter(RESTART)
            return
        end
        local saves = rowsFor()
        local items, group = {}, nil
        for _, s in ipairs(saves) do
            if s.boss ~= group then
                group = s.boss
                items[#items + 1] = { header = s.boss ~= "" and ("Boss: " .. s.boss) or "Trash" }
            end
            items[#items + 1] = s
        end

        for i = 1, math.max(#items, #rows) do
            local item = items[i]
            if item and not rows[i] then rows[i] = CreateSaveRow(parent, i) end
            local row = rows[i]
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
                    row.iconHits[j].entry = button or nil
                    row.iconHits[j]:SetShown(button ~= nil and button.icon ~= nil)
                end
                row:Show()
            else
                row.save = nil
                row:Hide()
            end
        end
        local rowsHeight = math.max(#items, 1) * ROW_HEIGHT
        parent:SetHeight(rowsHeight)
        tbl:SetHeight(HEADER_HEIGHT + 4 + rowsHeight)
        side:SetHeight(HEADER_HEIGHT + 4 + rowsHeight)
        host:SetHeight(top + HEADER_HEIGHT + 4 + rowsHeight)

        local S = CastAheadSaves
        local role, own = S.ViewRole(), S.ViewSpecID() == S.SpecID()
        local line
        if not callsOn() then
            line = offText
        elseif not role then
            line = "No specialization role - pick a spec to see your saves."
        else
            line = "Role: " .. (ROLE_NAMES[role] or role) .. (own and "." or " - another spec's list, cooldowns not shown.")
            if #saves == 0 then line = "Nothing here calls a defensive for this role. " .. line end
        end
        CastAheadWindow.SetFooter(line)
        CastAheadWindow.SideHint(side, tbl)
        CastAheadWindow.PaintSpecBars()
    end
    local function Build(h)
        host = h
        top = CastAheadWindow.SpecBar(host, 0, 0, function() CastAheadUI.RefreshSaves() end)
        top = top + EpNote(host, top, note)
        side, tbl = CastAheadWindow.SideScroll(host, top)
        tbl:SetWidth(SAVE_WIDTH)
        local header = CreateFrame("Frame", nil, tbl)
        header:SetSize(SAVE_WIDTH, HEADER_HEIGHT)
        header:SetPoint("TOPLEFT", tbl, "TOPLEFT", 0, 0)
        for _, column in ipairs(SAVE_COLUMNS) do
            local label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetSize(column.width, HEADER_HEIGHT)
            label:SetPoint("TOPLEFT", header, "TOPLEFT", column.x, 0)
            label:SetText("|cffaaaaaa" .. (headers and headers[column.key] or column.header) .. "|r")
        end
        local rule = header:CreateTexture(nil, "ARTWORK")
        rule:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -1)
        rule:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -1)
        rule:SetHeight(1)
        rule:SetColorTexture(1, 1, 1, 0.25)
        parent = CreateFrame("Frame", nil, tbl)
        parent:SetSize(SAVE_WIDTH, 1)
        parent:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    end
    return Build, Refresh
end

-- One Guide page: the text for the picked place, under the class and spec bar.
local function GuidePage(textFor)
    local host, text, top = nil, nil, 0
    local function Refresh()
        if not (host and host:IsVisible()) then return end
        text:SetText(CastAheadSaves and textFor() or RESTART)
        host:SetHeight(top + text:GetStringHeight() + 8)
        CastAheadWindow.PaintSpecBars()
    end
    local function Build(h)
        host = h
        top = CastAheadWindow.SpecBar(host, 0, 0, function() CastAheadUI.RefreshSaves() end)
        text = host:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("TOPLEFT", host, "TOPLEFT", 4, -(top + 4))
        text:SetWidth(math.max((host:GetWidth() or 0) - 8, 1))
        text:SetJustifyH("LEFT")
        text:SetSpacing(3)
        host:SetScript("OnSizeChanged", function(_, width)
            text:SetWidth(width - 8)
            Refresh()
        end)
        host:SetHyperlinksEnabled(true)
        host:SetScript("OnHyperlinkEnter", function(self, link)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
            GameTooltip:SetHyperlink(link)
            GameTooltip:Show()
        end)
        host:SetScript("OnHyperlinkLeave", GameTooltip_Hide)
    end
    return Build, Refresh
end

local OFF = "Defensive calls are off - turn them on in General - Features."
local RAID_OFF = "Raid defensive calls are off - turn them on in General - Features."

local BuildGuide, RefreshGuide = GuidePage(function()
    return CastAheadSaves.GuideText(CastAheadWindow.Dungeon())
        or (CastAheadSaves.ViewRole() and "Nothing in this dungeon calls a defensive for this role."
            or "No specialization role - pick a spec to see your guide.")
end)
local BuildRaidGuide, RefreshRaidGuide = GuidePage(function()
    return CastAheadSaves.RaidGuideText(CastAheadWindow.RaidDifficulty())
end)
local BuildSaves, RefreshSaves = SavesPage(function()
    return CastAheadSaves.ViewRows and CastAheadSaves.ViewRows(CastAheadWindow.Dungeon()) or {}
end, function() return CastAheadConfig.DungeonSaves() end, OFF)
local BuildRaidSaves, RefreshRaidSaves = SavesPage(function()
    return CastAheadSaves.ViewRaidRows and CastAheadSaves.ViewRaidRows(CastAheadWindow.RaidDifficulty()) or {}
end, function() return CastAheadConfig.RaidSaves() end, RAID_OFF, { lead = "After it lands", ep = "Damage" },
    CastAheadSaves and (CastAheadSaves.RAID_EP_NOTE .. " After it lands: seconds from the debuff landing to the call."))

function CastAheadUI.RefreshSaves()
    RefreshSaves()
    RefreshGuide()
    RefreshRaidSaves()
    RefreshRaidGuide()
end

CastAheadWindow.Register("Guide", "Dungeon", BuildGuide, RefreshGuide, "Casts")
CastAheadWindow.Register("Saves", "Dungeon", BuildSaves, RefreshSaves, "Casts")
CastAheadWindow.Register("RaidGuide", "Raid", BuildRaidGuide, RefreshRaidGuide, nil, nil, "Guide")
CastAheadWindow.Register("RaidSaves", "Raid", BuildRaidSaves, RefreshRaidSaves, nil, nil, "Saves")
