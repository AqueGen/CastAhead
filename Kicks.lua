-- Trial: party kicks and crowd control on enemies, off until turned on in
-- General - Features or with /ca kicks. Party kicks are seen only when the game lets the addon read
-- who interrupted or what a party member cast; a kick that misses is
-- invisible otherwise. Each source is also written to the key journal so one
-- key shows which of them are readable.
CastAheadKicks = {}
local K = CastAheadKicks

-- Cast spell id -> cooldown in seconds. The game reports some kicks under a
-- second id (Skull Bash 93985, Solar Beam 97547, Silence 220543).
K.KICKS = {
    [6552] = 15, [96231] = 15, [147362] = 24, [187707] = 15, [1766] = 15,
    [15487] = 30, [47528] = 15, [57994] = 12, [2139] = 25, [19647] = 24,
    [116705] = 15, [106839] = 15, [78675] = 60, [183752] = 15, [351338] = 20,
    [93985] = 15, [97547] = 60, [220543] = 30,
}

K.CLASS_KICK = {
    WARRIOR = 6552, PALADIN = 96231, HUNTER = 147362, ROGUE = 1766,
    PRIEST = 15487, DEATHKNIGHT = 47528, SHAMAN = 57994, MAGE = 2139,
    WARLOCK = 19647, MONK = 116705, DRUID = 106839, DEMONHUNTER = 183752,
    EVOKER = 351338,
}

local UNITS = { "player", "party1", "party2", "party3", "party4" }
local OWNER = { pet = "player", partypet1 = "party1", partypet2 = "party2", partypet3 = "party3", partypet4 = "party4" }
local DEDUPE = 1.5

local members = {}
local byUnit = {}
local castCounts = {}
local meterSeen = {}

local function Secret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

function K.State(v)
    if Secret(v) then return "secret" end
    if v == nil then return "nil" end
    return "ok"
end

function K.Active()
    return CastAheadConfig.Get("kickSpike") == true
end

local function Note(kind, slot, ...)
    if CastAheadRecorder and CastAheadConfig.Recording() then CastAheadRecorder.Note(kind, slot, ...) end
end

local function InCombat()
    return UnitAffectingCombat("player") and "1" or "0"
end

function K.Who(guid)
    if Secret(guid) or guid == nil then return nil end
    for _, unit in ipairs(UNITS) do
        if UnitGUID(unit) == guid then return unit end
    end
    for pet, owner in pairs(OWNER) do
        if UnitGUID(pet) == guid then return pet, owner end
    end
    return "other"
end

function K.Roster()
    wipe(members)
    wipe(byUnit)
    for _, unit in ipairs(UNITS) do
        if UnitExists(unit) then
            local _, class = UnitClass(unit)
            local m = {
                unit = unit,
                guid = UnitGUID(unit),
                name = UnitName(unit),
                class = class,
                role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit) or "NONE",
                kick = class and K.CLASS_KICK[class],
            }
            if m.kick then
                m.cd = K.KICKS[m.kick]
                members[#members + 1] = m
                byUnit[unit] = m
            end
        end
    end
    if K.Paint then K.Paint() end
end

function K.Members() return members end

-- Starts a member's cooldown unless one already started within DEDUPE, so a
-- kick seen both as a cast and as an interrupt counts once.
function K.Start(unit, spellID, source)
    local m = byUnit[unit]
    if not m then return end
    local now = GetTime()
    if m.startedAt and now - m.startedAt < DEDUPE then return end
    if spellID and K.KICKS[spellID] then
        m.kick, m.cd = spellID, K.KICKS[spellID]
    end
    m.startedAt, m.readyAt, m.source = now, now + m.cd, source
    if K.Paint then K.Paint() end
end

local function OnInterrupted(event, unit, interruptedBy)
    if not (type(unit) == "string" and unit:match("^nameplate%d+$")) then return end
    if event == "UNIT_SPELLCAST_CHANNEL_STOP" and interruptedBy == nil then return end
    local who, owner = K.Who(interruptedBy)
    Note("KINT", unit, event == "UNIT_SPELLCAST_CHANNEL_STOP" and "chan" or "int",
        Secret(interruptedBy) and "secret" or (who or "nil"), InCombat())
    if who and who ~= "other" then K.Start(owner or who, nil, "interrupt") end
end

local function OnSucceeded(unit, spellID)
    local owner = OWNER[unit]
    local member = owner or unit
    if not byUnit[member] then return end
    local party = unit ~= "player" and unit ~= "pet"
    if Secret(spellID) then
        if party then
            castCounts[unit] = castCounts[unit] or { ok = 0, secret = 0 }
            castCounts[unit].secret = castCounts[unit].secret + 1
        end
        return
    end
    if party then
        castCounts[unit] = castCounts[unit] or { ok = 0, secret = 0 }
        castCounts[unit].ok = castCounts[unit].ok + 1
    end
    if spellID and K.KICKS[spellID] then
        if party then Note("KCAST", nil, unit, spellID) end
        K.Start(member, spellID, "cast")
    end
end

local function FlushCounts()
    for unit, c in pairs(castCounts) do
        Note("KSUM", nil, unit, c.ok, c.secret)
    end
    wipe(castCounts)
end

local function MeterSources()
    if not (C_DamageMeter and C_DamageMeter.GetCombatSessionFromType and Enum and Enum.DamageMeterType) then return nil, "-" end
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
        Enum.DamageMeterSessionType.Current, Enum.DamageMeterType.Interrupts)
    if not ok then return nil, "err" end
    if Secret(session) or (issecrettable and issecrettable(session)) then return nil, "secret" end
    local sources = session and session.combatSources
    if sources == nil then return nil, "nil" end
    if Secret(sources) or (issecrettable and issecrettable(sources)) then return nil, "secret" end
    return sources, "ok"
end

-- The Current session restarts with each combat, so the baseline is wiped
-- when combat starts (PLAYER_REGEN_DISABLED).
local function OnMeter(meterType)
    if Secret(meterType) or not (Enum and Enum.DamageMeterType) or meterType ~= Enum.DamageMeterType.Interrupts then return end
    local sources, state = MeterSources()
    if not sources then
        Note("KMTR", nil, InCombat(), state, "-")
        return
    end
    local fields = {}
    for i, s in ipairs(sources) do
        local amount, guid = s.totalAmount, s.sourceGUID
        fields[i] = tostring(s.classFilename or "?") .. ":" .. K.State(s.specIconID) .. ":" .. K.State(amount) .. ":" .. K.State(guid)
        if not Secret(amount) and not Secret(guid) and guid and type(amount) == "number" then
            local last = meterSeen[guid] or 0
            if amount > last then
                local who, owner = K.Who(guid)
                if who and who ~= "other" then K.Start(owner or who, nil, "meter") end
            end
            meterSeen[guid] = amount
        end
    end
    Note("KMTR", nil, InCombat(), "ok", #sources, unpack(fields))
end

local frame = CreateFrame("Frame")
K.frame = frame

function K.OnEvent(event, ...)
    if event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" then
        if K.Place and event == "PLAYER_ENTERING_WORLD" then K.Place() end
        K.Roster()
        if K.ApplyCC then K.ApplyCC() end
        return
    end
    if event == "NAME_PLATE_UNIT_ADDED" or event == "NAME_PLATE_UNIT_REMOVED" then
        if K.OnCCEvent then K.OnCCEvent(event, ...) end
        return
    end
    if not K.Active() then return end
    if event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        local unit, _, _, interruptedBy = ...
        OnInterrupted(event, unit, interruptedBy)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        OnSucceeded(unit, spellID)
    elseif event == "PLAYER_REGEN_ENABLED" then
        FlushCounts()
    elseif event == "DAMAGE_METER_COMBAT_SESSION_UPDATED" then
        OnMeter(...)
    elseif event == "DAMAGE_METER_RESET" or event == "PLAYER_REGEN_DISABLED" then
        wipe(meterSeen)
    end
end

for _, e in ipairs({
    "PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE", "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_REGEN_ENABLED",
    "PLAYER_REGEN_DISABLED",
}) do frame:RegisterEvent(e) end
-- Unknown events raise an error on older clients.
for _, e in ipairs({ "DAMAGE_METER_COMBAT_SESSION_UPDATED", "DAMAGE_METER_RESET" }) do
    pcall(frame.RegisterEvent, frame, e)
end
frame:SetScript("OnEvent", function(_, event, ...) K.OnEvent(event, ...) end)

-- Display ---------------------------------------------------------------

local FONT = STANDARD_TEXT_FONT or "Fonts\FRIZQT__.TTF"
local ROW_W, ROW_H, GAP = 180, 18, 2

local panel = CreateFrame("Frame", "CastAheadKicksPanel", UIParent)
panel:SetSize(ROW_W, ROW_H)
panel:SetMovable(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    CastAheadConfig.Set("kickSpikePos", { point = point, relPoint = relPoint, x = x, y = y })
end)

local function Place()
    local pos = CastAheadConfig.Get("kickSpikePos")
    panel:ClearAllPoints()
    if type(pos) == "table" and pos.point then
        panel:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    else
        panel:SetPoint("CENTER", UIParent, "CENTER", -350, 100)
    end
end
K.Place = Place
panel:Hide()
K.panel = panel

local title = panel:CreateFontString(nil, "OVERLAY")
title:SetFont(FONT, 11, "OUTLINE")
title:SetPoint("BOTTOMLEFT", panel, "TOPLEFT", 0, 2)
title:SetText("Kicks")

local rows = {}

local function Row(i)
    local row = rows[i]
    if row then return row end
    row = CreateFrame("StatusBar", nil, panel)
    row:SetSize(ROW_W - ROW_H - GAP, ROW_H)
    row:SetPoint("TOPLEFT", panel, "TOPLEFT", ROW_H + GAP, -(i - 1) * (ROW_H + GAP))
    row:SetStatusBarTexture("Interface\Buttons\WHITE8X8")
    row:SetMinMaxValues(0, 1)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(0, 0, 0, 0.6)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ROW_H, ROW_H)
    row.icon:SetPoint("RIGHT", row, "LEFT", -GAP, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.name = row:CreateFontString(nil, "OVERLAY")
    row.name:SetFont(FONT, 11, "OUTLINE")
    row.name:SetPoint("LEFT", 4, 0)
    row.time = row:CreateFontString(nil, "OVERLAY")
    row.time:SetFont(FONT, 11, "OUTLINE")
    row.time:SetPoint("RIGHT", -4, 0)
    rows[i] = row
    return row
end

local function ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 0.7, 0.7, 0.7
end

local function PaintRow(row, m, now)
    local r, g, b = ClassColor(m.class)
    row.icon:SetTexture(C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(m.kick) or 134400)
    row.name:SetText((m.unit == "player" and "> " or "") .. (m.name or "?"))
    local left = m.readyAt and m.readyAt - now or 0
    if left > 0 then
        row:SetStatusBarColor(r * 0.45, g * 0.45, b * 0.45, 0.9)
        row:SetValue(1 - left / m.cd)
        row.time:SetText(string.format("%d", math.ceil(left)))
        row.icon:SetDesaturated(true)
    else
        row:SetStatusBarColor(r, g, b, 0.9)
        row:SetValue(1)
        row.time:SetText("")
        row.icon:SetDesaturated(false)
    end
    row:SetAlpha(m.role == "HEALER" and m.class ~= "SHAMAN" and 0.5 or 1)
end

local kickCount = 0

function K.Paint()
    if not K.Active() then
        panel:Hide()
        return
    end
    local now = GetTime()
    kickCount = #members
    for i, m in ipairs(members) do
        local row = Row(i)
        PaintRow(row, m, now)
        row:Show()
    end
    for i = #members + 1, #rows do rows[i]:Hide() end
    panel:SetHeight(math.max(1, kickCount) * (ROW_H + GAP))
    if K.LayoutCC then K.LayoutCC(kickCount) end
    panel:Show()
end

local elapsed = 0
panel:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 0.1 then return end
    elapsed = 0
    local now = GetTime()
    for i, m in ipairs(members) do
        if rows[i] then PaintRow(rows[i], m, now) end
    end
end)

function K.Apply()
    K.Place()
    K.Roster()
    if K.ApplyCC then K.ApplyCC() end
end

function K.Toggle()
    local on = not K.Active()
    CastAheadConfig.Set("kickSpike", on)
    K.Apply()
    if CastAheadOptions and CastAheadOptions.Refresh then CastAheadOptions.Refresh() end
    print("|cff33ff99Cast Ahead|r party kicks and CC " .. (on and "on - drag the panel to move it" or "off"))
end

-- Crowd control on enemies ----------------------------------------------
-- One Blizzard aura container per nameplate token, filtered to these debuffs
-- (each checked in SpellEffect to apply a stun, fear or confuse aura). The
-- game draws the bars, so Secret aura data in combat is never read here, and
-- who cast the control is unknown. Containers are chained under the kick
-- rows; an empty container has no height, so the stack has no gaps.
K.CC = {}
for _, id in ipairs({
    853, 408, 1833, 1776, 2094, 5211, 30283, 89766, 119381, 132168, 132169, 179057,
    211881, 205630, 91800, 91797, 118905, 64044, 200200, 24394, 117526, 255941, 372245,
    287712, 20549, 107079, 305485, 5246, 8122, 5484, 6789, 118699, 207167, 31661, 82691,
    118, 115078, 99, 207685, 217832, 3355, 213691, 2637, 6770, 20066, 105421, 10326,
    360806, 1513,
}) do K.CC[id] = true end

local CC_H = 14
local containers = {}
local plates = {}

local function InitButton(btn)
    btn:SetSize(ROW_W, CC_H)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(CC_H, CC_H)
    icon:SetPoint("LEFT")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local bar = CreateFrame("StatusBar", nil, btn)
    bar:SetPoint("TOPLEFT", icon, "TOPRIGHT", GAP, 0)
    bar:SetPoint("BOTTOMRIGHT")
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    bar:SetStatusBarColor(0.85, 0.65, 0.1, 0.9)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)
    local text = bar:CreateFontString(nil, "OVERLAY")
    text:SetFont(FONT, 10, "OUTLINE")
    text:SetPoint("RIGHT", -3, 0)
    local name = bar:CreateFontString(nil, "OVERLAY")
    name:SetFont(FONT, 10, "OUTLINE")
    name:SetPoint("LEFT", 3, 0)
    btn:SetIcon(icon)
    btn:SetDurationBar(bar, {})
    btn:SetDurationText(text, {})
    btn:SetSpellName(name)
    if btn.SetHideTooltipInCombat then btn:SetHideTooltipInCombat(true) end
end

local function Container(token)
    local c = containers[token]
    if c ~= nil then return c or nil end
    local ok, made = pcall(CreateFrame, "AuraContainer", nil, panel, "CustomAuraContainerTemplate")
    if not ok or not made then
        containers[token] = false
        return nil
    end
    c = made
    if c.SetEditModePreviewEnabled then c:SetEditModePreviewEnabled(false) end
    c:SetFlowLayoutMaximumLineSize(ROW_W)
    c:SetUnit(token)
    c:AddAuraGroup("cc", "HARMFUL", {
        candidateFilters = { includeSpellIDs = K.CC },
        initializeFrame = InitButton,
        sortMethod = AuraContainerSortMethod.Expiration,
        maxFrameCount = 3,
        layout = { elementWidth = ROW_W, elementHeight = CC_H, lineSpacing = GAP, forceNewLine = true },
    })
    containers[token] = c
    return c
end

-- Chains the shown containers in nameplate order under the kick rows.
function K.LayoutCC(kickRows)
    local prev
    for i = 1, 40 do
        local c = containers["nameplate" .. i]
        if c and c:IsShown() then
            c:ClearAllPoints()
            if prev then
                c:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, 0)
            else
                c:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -(kickRows * (ROW_H + GAP)) - 6)
            end
            prev = c
        end
    end
end

local function ShowPlate(token, on)
    local c = on and Container(token) or containers[token]
    if not c then return end
    if on then
        c:SetUnit(token)
        c:Show()
    else
        c:Hide()
    end
end

function K.ApplyCC()
    local on = K.Active()
    for token in pairs(plates) do ShowPlate(token, on) end
    if not on then
        for _, c in pairs(containers) do
            if c then c:Hide() end
        end
    end
    K.LayoutCC(#members)
end

function K.OnCCEvent(event, token)
    if type(token) ~= "string" or not token:match("^nameplate%d+$") then return end
    if event == "NAME_PLATE_UNIT_ADDED" then
        if UnitCanAttack("player", token) then
            plates[token] = true
            if K.Active() then ShowPlate(token, true) end
        end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        plates[token] = nil
        ShowPlate(token, false)
    end
    K.LayoutCC(#members)
end

frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
