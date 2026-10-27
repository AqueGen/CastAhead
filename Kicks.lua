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
    if CastAheadRecorder and CastAheadConfig.Recording() and CastAheadConfig.Enabled("kickProbe") then
        CastAheadRecorder.Note(kind, slot, ...)
    end
end

local function RowsOn() return K.Active() and CastAheadConfig.Enabled("kickRows") end
local function CCOn() return K.Active() and CastAheadConfig.Enabled("kickCC") end
local function DefsOn() return K.Active() and CastAheadConfig.Enabled("kickDefs") end

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

local demo

function K.Roster()
    if demo then return end
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

-- Focus probe: does a cast start reach the "focus" token, and can the addon
-- tell which nameplate the focus is (plate frame lookup, then UnitIsUnit).
local function FocusPlate()
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, "focus")
    if not ok then return nil, "err" end
    if Secret(plate) then return nil, "secret" end
    if not plate then return nil, "nil" end
    for i = 1, 40 do
        local token = "nameplate" .. i
        if C_NamePlate.GetNamePlateForUnit(token) == plate then return token, "ok" end
    end
    return nil, "nomatch"
end

local function SameUnit(token)
    if not token then return "-" end
    local ok, same = pcall(UnitIsUnit, "focus", token)
    if not ok then return "err" end
    if Secret(same) then return "secret" end
    return same and "yes" or "no"
end

local function OnFocusCast(channel)
    local token, plate = FocusPlate()
    Note("KFOC", token, channel and 1 or 0, plate, SameUnit(token), UnitCanAttack("player", "focus") and 1 or 0)
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
    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        OnFocusCast(event == "UNIT_SPELLCAST_CHANNEL_START")
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
if frame.RegisterUnitEvent then
    frame:RegisterUnitEvent("UNIT_SPELLCAST_START", "focus")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "focus")
end
frame:SetScript("OnEvent", function(_, event, ...) K.OnEvent(event, ...) end)

-- Display ---------------------------------------------------------------

local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local ROW_W, ROW_H, GAP = 180, 18, 2
local CC_H = 14
local CC_TOP = 6

K.X_DEFAULT, K.Y_DEFAULT = -350, 100
K.SCALE_DEFAULT, K.SCALE_MIN, K.SCALE_MAX = 100, 50, 200

local panel = CreateFrame("Frame", "CastAheadKicksPanel", UIParent)
panel:SetSize(ROW_W, ROW_H)
panel:Hide()
K.panel = panel

local title = panel:CreateFontString(nil, "OVERLAY")
title:SetFont(FONT, 11, "OUTLINE")
title:SetText("Kicks")

function K.GrowsUp()
    return CastAheadConfig.Get("kickGrow") == "UP"
end

-- X and Y are the panel's starting corner from the screen centre: its top
-- left when it grows down, its bottom left when it grows up.
local function Place()
    local up = K.GrowsUp()
    panel:ClearAllPoints()
    panel:SetPoint(up and "BOTTOMLEFT" or "TOPLEFT", UIParent, "CENTER",
        CastAheadConfig.Number("kickX", K.X_DEFAULT, -4000, 4000),
        CastAheadConfig.Number("kickY", K.Y_DEFAULT, -4000, 4000))
    panel:SetScale(CastAheadConfig.Number("kickScale", K.SCALE_DEFAULT, K.SCALE_MIN, K.SCALE_MAX) / 100)
    title:ClearAllPoints()
    if up then
        title:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 0, -2)
    else
        title:SetPoint("BOTTOMLEFT", panel, "TOPLEFT", 0, 2)
    end
end
K.Place = Place

-- While Size and position is open the panel can be dragged; the drop is
-- saved as the same X and Y the number fields show.
local editBg = panel:CreateTexture(nil, "BACKGROUND")
editBg:SetPoint("TOPLEFT", -4, 4)
editBg:SetPoint("BOTTOMRIGHT", 4, -4)
editBg:SetColorTexture(0.2, 0.6, 1, 0.25)
editBg:Hide()

panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
panel:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local cx, cy = UIParent:GetCenter()
    local own, ui = self:GetEffectiveScale(), UIParent:GetEffectiveScale()
    local y = K.GrowsUp() and self:GetBottom() or self:GetTop()
    CastAheadConfig.Set("kickX", math.floor((self:GetLeft() * own - cx * ui) / own + 0.5))
    CastAheadConfig.Set("kickY", math.floor((y * own - cy * ui) / own + 0.5))
    Place()
    if CastAheadSetup and CastAheadSetup.Refresh then CastAheadSetup.Refresh() end
end)

function K.SetEditing(on)
    panel:SetMovable(on)
    panel:EnableMouse(on)
    editBg:SetShown(on)
end

-- Puts a child `offset` px from the panel's starting edge, in the grow direction.
local function Stack(child, offset, x)
    child:ClearAllPoints()
    if K.GrowsUp() then
        child:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", x or 0, offset)
    else
        child:SetPoint("TOPLEFT", panel, "TOPLEFT", x or 0, -offset)
    end
end
K.Stack = Stack

local rows = {}

local function Row(i)
    local row = rows[i]
    if row then return row end
    row = CreateFrame("StatusBar", nil, panel)
    row:SetSize(ROW_W - ROW_H - GAP, ROW_H)
    row:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
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

-- Where the crowd control part starts, past the kick rows.
function K.CCStart()
    return kickCount * (ROW_H + GAP) + (kickCount > 0 and CC_TOP or 0)
end

-- Solo there is no one else to track, and in a raid party1-4 is only your subgroup.
local function InParty()
    return IsInGroup() and not IsInRaid()
end

function K.Paint()
    if not K.Active() or not (demo or InParty()) then
        panel:Hide()
        return
    end
    local now = GetTime()
    kickCount = RowsOn() and #members or 0
    for i = 1, kickCount do
        local row = Row(i)
        Stack(row, (i - 1) * (ROW_H + GAP), ROW_H + GAP)
        PaintRow(row, members[i], now)
        row:Show()
    end
    for i = kickCount + 1, #rows do rows[i]:Hide() end
    title:SetText(kickCount > 0 and "Kicks" or "Group and enemy auras")
    panel:SetHeight(math.max(1, kickCount) * (ROW_H + GAP))
    if K.LayoutCC then K.LayoutCC() end
    panel:Show()
end

local elapsed = 0
panel:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 0.1 then return end
    elapsed = 0
    local now = GetTime()
    for i = 1, kickCount do
        if rows[i] and members[i] then PaintRow(rows[i], members[i], now) end
    end
end)

function K.Apply()
    if K.Demoing and K.Demoing() and not K.Active() then K.Demo(false) end
    Place()
    K.Roster()
    K.Paint()
    if K.ApplyCC then K.ApplyCC() end
end

function K.Toggle()
    local on = not K.Active()
    CastAheadConfig.Set("kickSpike", on)
    K.Apply()
    if CastAheadOptions and CastAheadOptions.Refresh then CastAheadOptions.Refresh() end
    print("|cff33ff99CastAhead|r party kicks and CC " .. (on and "on - place it in Size and position" or "off"))
end

-- Aura bars: party defensives and crowd control -------------------------
-- Blizzard aura containers filtered to spell ids (each checked in SpellEffect
-- to apply the aura): the game draws the bars, so Secret aura data in combat
-- is never read here. Defensives show while they are up on you (group
-- cooldowns and externals) or on a party member (externals only, so a group
-- cooldown is not listed five times); when they come back is unknown.
-- Crowd control shows per enemy nameplate; who cast it is unknown. All of it
-- is chained past the kick rows; an empty container has no height, so the
-- stack has no gaps.
K.GROUP_DEFS = {}
for _, id in ipairs({ 97463, 31821, 81782, 64844, 145629, 325174, 209426, 363534, 374227 }) do
    K.GROUP_DEFS[id] = true
end
K.EXTERNALS = {}
for _, id in ipairs({ 6940, 1022, 204018, 33206, 47788, 102342, 116849, 357170 }) do K.EXTERNALS[id] = true end
local MY_DEFS = {}
for id in pairs(K.GROUP_DEFS) do MY_DEFS[id] = true end
for id in pairs(K.EXTERNALS) do MY_DEFS[id] = true end

K.CC = {}
for _, id in ipairs({
    853, 408, 1833, 1776, 2094, 5211, 30283, 89766, 119381, 132168, 132169, 179057,
    211881, 205630, 91800, 91797, 118905, 64044, 200200, 24394, 117526, 255941, 372245,
    287712, 20549, 107079, 305485, 5246, 8122, 5484, 6789, 118699, 207167, 31661, 82691,
    118, 115078, 99, 207685, 217832, 3355, 213691, 2637, 6770, 20066, 105421, 10326,
    360806, 1513,
}) do K.CC[id] = true end

local DEF_COLOR = { 0.2, 0.75, 0.35 }
local CC_COLOR = { 0.85, 0.65, 0.1 }
local DEF_UNITS = { "player", "party1", "party2", "party3", "party4" }

local containers = {}
local plates = {}

local function Initializer(color)
    return function(btn)
        btn:SetSize(ROW_W, CC_H)
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetSize(CC_H, CC_H)
        icon:SetPoint("LEFT")
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local bar = CreateFrame("StatusBar", nil, btn)
        bar:SetPoint("TOPLEFT", icon, "TOPRIGHT", GAP, 0)
        bar:SetPoint("BOTTOMRIGHT")
        bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        bar:SetStatusBarColor(color[1], color[2], color[3], 0.9)
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
end
local InitCC, InitDef = Initializer(CC_COLOR), Initializer(DEF_COLOR)

-- `key` names the container: "def:<unit>" or "cc:<nameplate token>".
local function Container(key, unit, filter, spells, init)
    local c = containers[key]
    if c ~= nil then return c or nil end
    local ok, made = pcall(CreateFrame, "AuraContainer", nil, panel, "CustomAuraContainerTemplate")
    if not ok or not made then
        containers[key] = false
        return nil
    end
    c = made
    if c.SetEditModePreviewEnabled then c:SetEditModePreviewEnabled(false) end
    c:SetFlowLayoutMaximumLineSize(ROW_W)
    c:SetUnit(unit)
    c:AddAuraGroup("bars", filter, {
        candidateFilters = { includeSpellIDs = spells },
        initializeFrame = init,
        sortMethod = AuraContainerSortMethod.Expiration,
        maxFrameCount = 3,
        layout = { elementWidth = ROW_W, elementHeight = CC_H, lineSpacing = GAP, forceNewLine = true },
    })
    containers[key] = c
    return c
end

local order = {}
for _, unit in ipairs(DEF_UNITS) do order[#order + 1] = "def:" .. unit end
for i = 1, 40 do order[#order + 1] = "cc:nameplate" .. i end

-- Chains the shown containers past the kick rows, defensives first, in the
-- grow direction; each container's own bars grow the same way.
function K.LayoutCC()
    local up = K.GrowsUp()
    local prev
    for _, key in ipairs(order) do
        local c = containers[key]
        if c and c:IsShown() then
            if c.growsUp ~= up and AnchorUtil and AnchorUtil.FlowDirection then
                c.growsUp = up
                c:SetFlowLayoutAnchorPoint(up and "BOTTOMLEFT" or "TOPLEFT")
                c:SetFlowLayoutGrowthDirection(AnchorUtil.FlowDirection.Right,
                    up and AnchorUtil.FlowDirection.Up or AnchorUtil.FlowDirection.Down)
            end
            if prev then
                c:ClearAllPoints()
                if up then
                    c:SetPoint("BOTTOMLEFT", prev, "TOPLEFT", 0, 0)
                else
                    c:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, 0)
                end
            else
                K.Stack(c, K.CCStart())
            end
            prev = c
        end
    end
end

local function ShowPlate(token, on)
    local key = "cc:" .. token
    local c = on and Container(key, token, "HARMFUL", K.CC, InitCC) or containers[key]
    if not c then return end
    if on then
        c:SetUnit(token)
        c:Show()
    else
        c:Hide()
    end
end

local function ApplyDefs(on)
    for _, unit in ipairs(DEF_UNITS) do
        local key = "def:" .. unit
        local show = on and UnitExists(unit)
        local c = show and Container(key, unit, "HELPFUL", unit == "player" and MY_DEFS or K.EXTERNALS, InitDef)
            or containers[key]
        if c then c:SetShown(show and true or false) end
    end
end

function K.ApplyCC()
    ApplyDefs(DefsOn() and not demo)
    local on = CCOn() and not demo
    for token in pairs(plates) do ShowPlate(token, on) end
    if not on then
        for i = 1, 40 do
            local c = containers["cc:nameplate" .. i]
            if c then c:Hide() end
        end
    end
    K.LayoutCC()
end

function K.OnCCEvent(event, token)
    if type(token) ~= "string" or not token:match("^nameplate%d+$") then return end
    if event == "NAME_PLATE_UNIT_ADDED" then
        if UnitCanAttack("player", token) then
            plates[token] = true
            if CCOn() and not demo then ShowPlate(token, true) end
        end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        plates[token] = nil
        ShowPlate(token, false)
    end
    K.LayoutCC()
end

frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")

-- Demo ------------------------------------------------------------------
-- A made-up key group (you plus four) whose kicks go on cooldown in turn,
-- and a few crowd control bars that run out and start again. Runs with the
-- test drive or /ca kicks demo, while the panel is on.
local DEMO_GROUP = {
    { unit = "player" },
    { name = "Warrior", class = "WARRIOR", role = "TANK" },
    { name = "Mage", class = "MAGE" },
    { name = "Rogue", class = "ROGUE" },
    { name = "Priest", class = "PRIEST", role = "HEALER" },
}
local DEMO_BARS = {
    { id = 97463, len = 10, def = true }, { id = 33206, len = 8, def = true },
    { id = 119381, len = 3 }, { id = 30283, len = 3 }, { id = 118, len = 8 },
}
local DEMO_KICK_EVERY = 2.5

local demoBars = {}

local function DemoBar(i)
    local bar = demoBars[i]
    if bar then return bar end
    bar = CreateFrame("StatusBar", nil, panel)
    bar:SetSize(ROW_W - CC_H - GAP, CC_H)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    local color = DEMO_BARS[i].def and DEF_COLOR or CC_COLOR
    bar:SetStatusBarColor(color[1], color[2], color[3], 0.9)
    bar:SetMinMaxValues(0, 1)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)
    bar.icon = bar:CreateTexture(nil, "ARTWORK")
    bar.icon:SetSize(CC_H, CC_H)
    bar.icon:SetPoint("RIGHT", bar, "LEFT", -GAP, 0)
    bar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    bar.name = bar:CreateFontString(nil, "OVERLAY")
    bar.name:SetFont(FONT, 10, "OUTLINE")
    bar.name:SetPoint("LEFT", 3, 0)
    bar.time = bar:CreateFontString(nil, "OVERLAY")
    bar.time:SetFont(FONT, 10, "OUTLINE")
    bar.time:SetPoint("RIGHT", -3, 0)
    demoBars[i] = bar
    return bar
end

local function DemoTick()
    if not demo then return end
    local now = GetTime()
    if now >= demo.nextKick then
        demo.nextKick = now + DEMO_KICK_EVERY
        local ready = {}
        for _, m in ipairs(members) do
            if m.role ~= "HEALER" and (not m.readyAt or m.readyAt <= now) then ready[#ready + 1] = m end
        end
        if #ready > 0 then K.Start(ready[math.random(#ready)].unit, nil, "demo") end
    end
    local showCC, showDefs, slot = CCOn(), DefsOn(), 0
    for i, sample in ipairs(DEMO_BARS) do
        local bar = DemoBar(i)
        local state = demo.cc[i]
        if now >= state.endsAt + 1.5 then
            state.endsAt = now + sample.len
        end
        local left = state.endsAt - now
        if (sample.def and showDefs or not sample.def and showCC) and left > 0 then
            K.Stack(bar, K.CCStart() + slot * (CC_H + GAP), CC_H + GAP)
            slot = slot + 1
            bar.icon:SetTexture(C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sample.id) or 134400)
            bar.name:SetText(C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sample.id) or "")
            bar.time:SetText(string.format("%.1f", left))
            bar:SetValue(left / sample.len)
            bar:Show()
        else
            bar:Hide()
        end
    end
end

local demoFrame = CreateFrame("Frame")

function K.Demo(on)
    on = on and K.Active() or false
    if on == (demo ~= nil) then return end
    if on then
        local now = GetTime()
        demo = { nextKick = now + 1, cc = {} }
        for i, sample in ipairs(DEMO_BARS) do demo.cc[i] = { endsAt = now + sample.len - (i - 1) } end
        wipe(members)
        wipe(byUnit)
        local _, myClass = UnitClass("player")
        for i, d in ipairs(DEMO_GROUP) do
            local class = d.class or myClass
            local m = {
                unit = d.unit or ("demo" .. i),
                name = d.name or UnitName("player"),
                class = class,
                role = d.role or "DAMAGER",
                kick = K.CLASS_KICK[class],
            }
            if m.kick then
                m.cd = K.KICKS[m.kick]
                members[#members + 1] = m
                byUnit[m.unit] = m
            end
        end
        demoFrame:SetScript("OnUpdate", DemoTick)
        K.ApplyCC()
        K.Paint()
    else
        demo = nil
        demoFrame:SetScript("OnUpdate", nil)
        for _, bar in ipairs(demoBars) do bar:Hide() end
        K.Roster()
        K.ApplyCC()
    end
end

function K.Demoing() return demo ~= nil end
