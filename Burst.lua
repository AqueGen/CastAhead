CastAheadBurst = {}
local B = CastAheadBurst
local M = CastAheadMatch

local SAVE_GAP = 2
local BURST_SHOWN = 5
local ICON = "Interface\\Icons\\Spell_Nature_Bloodlust"
B.ICON = ICON
local entries = {}
local pending = {}

local function Role()
    if not (GetSpecialization and GetSpecializationRole) then return nil end
    local spec = GetSpecialization()
    return spec and GetSpecializationRole(spec) or nil
end

local function On()
    if not CastAheadConfig.BurstCalls() then return false end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return false end
    return Role() ~= nil
end

-- Healers get their own windows (heavy group damage); a boss-event window is for everyone.
local function ForRole(w, role)
    return w.event ~= nil or (w.role == "HEALER") == (role == "HEALER")
end

local function DeferUntil(now)
    local S = CastAheadSaves
    if not (S and S.LastFiredAt) then return nil end
    local last, nextAt = S.LastFiredAt(), S.NextFireAt(now)
    local at
    if last ~= nil and now - last < SAVE_GAP then at = last + SAVE_GAP end
    if nextAt ~= nil and nextAt - now < SAVE_GAP then at = math.max(at or 0, nextAt + SAVE_GAP) end
    local warnAt, warnedCall = S.NextWarnAt(now)
    if warnAt ~= nil and warnAt - now < SAVE_GAP then at = math.max(at or 0, warnedCall + SAVE_GAP) end
    return at
end

local PROBE_ENCOUNTERS = { [3101] = true, [3429] = true }
local PROBE_SPELLS = { 1265412, 1230304, 1304028, 1304032 }
local PROBE_EVENTS = { "UNIT_AURA", "ENCOUNTER_WARNING", "UNIT_TARGETABLE_CHANGED",
    "CHAT_MSG_MONSTER_YELL", "ENCOUNTER_TIMELINE_EVENT_ADDED", "ENCOUNTER_END" }
local PROBE_SESSIONS, PROBE_ROWS = 12, 600
local probeFrame, probe

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function Fact(ok, ...)
    if not ok then return "E" end
    local value = ...
    if IsSecret(value) then return "S" end
    if value == nil then return "-" end
    if type(value) == "table" then return "+" end
    return tostring(value)
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return "-" end
    return Fact(pcall(fn, ...))
end

local function Field(info, key)
    return Fact(pcall(function() return info[key] end))
end

local function ProbeRow(row)
    row.t = math.floor((GetTime() - probe.startedAt) * 10 + 0.5) / 10
    if #probe.session.rows < PROBE_ROWS then probe.session.rows[#probe.session.rows + 1] = row end
end

local function ProbeStop(success)
    if probeFrame then probeFrame:UnregisterAllEvents() end
    if probe and not IsSecret(success) and (success == 0 or success == 1) then
        probe.session.result = success == 1 and "kill" or "wipe"
    end
    probe = nil
end

local function ProbeAura(unit, updateInfo)
    if IsSecret(unit) or type(unit) ~= "string" or not unit:match("^boss%d") then return end
    local s = probe.session
    s.auraEvents[unit] = (s.auraEvents[unit] or 0) + 1
    if s.infoSecret[unit] == nil then
        s.infoSecret[unit] = IsSecret(updateInfo) and "S" or type(updateInfo)
    end
    local auras = C_UnitAuras or {}
    for _, id in ipairs(PROBE_SPELLS) do
        local found = Call(auras.GetUnitAuraBySpellID, unit, id)
        local name = probe.names[id]
        local byName = name and Call(auras.GetAuraDataBySpellName, unit, name) or "-"
        local key, seen = unit .. ":" .. id, found .. "|" .. byName
        if (probe.last[key] or "-|-") ~= seen then
            probe.last[key] = seen
            ProbeRow({ kind = "aura", unit = unit, id = id, found = found, byName = byName })
        end
    end
end

local function ProbeEvent(_, event, ...)
    if not probe then return end
    if not CastAheadConfig.Recording() then return ProbeStop() end
    if event == "UNIT_AURA" then
        ProbeAura(...)
    elseif event == "ENCOUNTER_WARNING" then
        local info = ...
        ProbeRow({ kind = "warning", duration = Field(info, "duration"), severity = Field(info, "severity"),
            sound = Field(info, "shouldPlaySound"), show = Field(info, "shouldShowWarning") })
    elseif event == "UNIT_TARGETABLE_CHANGED" then
        local unit = ...
        ProbeRow({ kind = "targetable", unit = IsSecret(unit) and "S" or unit })
    elseif event == "CHAT_MSG_MONSTER_YELL" then
        ProbeRow({ kind = "yell" })
    elseif event == "ENCOUNTER_TIMELINE_EVENT_ADDED" then
        local info = ...
        ProbeRow({ kind = "timeline", duration = Field(info, "duration"), id = Field(info, "id") })
    elseif event == "ENCOUNTER_END" then
        ProbeStop((select(5, ...)))
    end
end

local function ProbeStart(encounterID, difficultyID)
    ProbeStop()
    if not (CastAheadConfig.Recording() and PROBE_ENCOUNTERS[encounterID]) then return end
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.phaseProbe = CastAheadDB.phaseProbe or {}
    local list = CastAheadDB.phaseProbe
    local session = { enc = encounterID, diff = difficultyID, started = date("%Y-%m-%d %H:%M:%S"),
        rows = {}, auraEvents = {}, infoSecret = {} }
    list[#list + 1] = session
    while #list > PROBE_SESSIONS do table.remove(list, 1) end
    probe = { session = session, startedAt = GetTime(), last = {}, names = {} }
    local secrets, spells = C_Secrets or {}, {}
    for _, id in ipairs(PROBE_SPELLS) do
        spells[id] = { should = Call(secrets.ShouldSpellAuraBeSecret, id), secrecy = Call(secrets.GetSpellAuraSecrecy, id) }
        local ok, name = pcall(C_Spell.GetSpellName, id)
        if ok and not IsSecret(name) and type(name) == "string" then probe.names[id] = name end
    end
    ProbeRow({ kind = "secrecy", spells = spells })
    if not probeFrame then
        probeFrame = CreateFrame("Frame")
        probeFrame:SetScript("OnEvent", ProbeEvent)
    end
    for _, e in ipairs(PROBE_EVENTS) do pcall(probeFrame.RegisterEvent, probeFrame, e) end
end

local EVENT_SHOWN = Enum and Enum.EncounterEventSoundTrigger
    and Enum.EncounterEventSoundTrigger.OnTextWarningShown or 0
-- Boss mods set their own sound on the same event as the fight starts; ours goes on after theirs.
local ARM_DELAY = 2
local armed, armToken = {}, 0

local function Disarm()
    for id in pairs(armed) do pcall(C_EncounterEvents.SetEventSound, id, EVENT_SHOWN, nil) end
    wipe(armed)
end

local function Arm(events)
    local file = CastAheadCore and CastAheadCore.AdviceFile and CastAheadCore.AdviceFile(M.ADVICE.BURST)
    if not (file and On()) then return end
    for _, id in ipairs(events) do
        if pcall(C_EncounterEvents.SetEventSound, id, EVENT_SHOWN,
                { file = file, channel = CastAheadConfig.SoundChannel(), volume = 1 }) then
            armed[id] = true
        end
    end
end

function B.OnEncounter(event, encounterID, difficultyID, now)
    if event == "ENCOUNTER_START" then ProbeStart(encounterID, difficultyID) end
    wipe(entries)
    Disarm()
    armToken = armToken + 1
    if event ~= "ENCOUNTER_START" then return end
    local byDifficulty = CastAheadBurstWindows and CastAheadBurstWindows[encounterID]
    local windows = byDifficulty and byDifficulty[difficultyID]
    if not windows then return end
    local role, events, soon = Role(), {}, CastAheadConfig.BurstLead()
    for _, w in ipairs(windows) do
        local mine = ForRole(w, role)
        if mine and w.event then
            events[#events + 1] = w.event
        elseif mine and not w.pull then
            local at = now + w.release
            if soon > 0 and w.release >= soon then
                entries[#entries + 1] = { fireAt = at - soon, endAt = at, advice = M.ADVICE.SOON }
            end
            entries[#entries + 1] = { fireAt = at, endAt = at + BURST_SHOWN, advice = M.ADVICE.BURST }
        end
    end
    if #events > 0 and C_EncounterEvents and C_EncounterEvents.SetEventSound and C_Timer then
        local token = armToken
        C_Timer.After(ARM_DELAY, function()
            if token == armToken then Arm(events) end
        end)
    end
end

function B.Tick(now)
    if next(armed) and not (CastAheadConfig.BurstCalls() and CastAheadCore and CastAheadCore.AdviceFile
            and CastAheadCore.AdviceFile(M.ADVICE.BURST)) then
        Disarm()
    end
    if #entries == 0 then return end
    if IsEncounterInProgress and not IsEncounterInProgress() and not entries[1].demo then wipe(entries) return end
    if not On() then return end
    for _, e in ipairs(entries) do
        if not e.fired and now >= e.fireAt and now < e.endAt then
            local at = not e.deferred and DeferUntil(now)
            if at then
                e.deferred, e.fireAt = true, at
                if e.advice == M.ADVICE.BURST then e.endAt = math.max(e.endAt, at + BURST_SHOWN) end
            else
                e.fired = true
                if CastAheadCore and CastAheadCore.Announce then CastAheadCore.Announce(e.advice) end
            end
        end
    end
end

-- One "burst soon" then "burst now" for the settings' Test button. It runs
-- outside an encounter, so Tick keeps entries marked `demo`. Returns when the
-- window ends.
function B.Demo(now)
    wipe(entries)
    local soon = CastAheadConfig.BurstLead()
    local at = now + soon + 1
    if soon > 0 then
        entries[#entries + 1] = { fireAt = at - soon, endAt = at, advice = M.ADVICE.SOON, demo = true }
    end
    entries[#entries + 1] = { fireAt = at, endAt = at + BURST_SHOWN, advice = M.ADVICE.BURST, demo = true }
    return at + BURST_SHOWN
end

function B.ClearDemo()
    if entries[1] and entries[1].demo then wipe(entries) end
end

function B.Pending(now)
    wipe(pending)
    if #entries == 0 or not On() then return pending end
    for _, e in ipairs(entries) do
        if e.fired and e.endAt > now then
            pending[#pending + 1] = { endAt = e.endAt, advice = e.advice, row = {}, icons = { ICON } }
        end
    end
    return pending
end

function B.Clock(seconds)
    local total = math.floor(seconds + 0.5)
    return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local GREY, GOLD = "|cffaaaaaa", "|cffffd100"

local function WindowLine(w)
    if w.event then
        return string.format("  %s %s- called on the boss warning|r", w.target or "Boss event", GREY)
    end
    if w.pull then return string.format("  %s %sburst on the pull|r", B.Clock(w.release), GREY) end
    local what = w.target or (w.role == "HEALER" and "healers burst here") or "top players burst here"
    if w.target and w.role == "HEALER" then what = what .. " " .. GREY .. "(healers)|r" end
    return string.format("  %s %s", B.Clock(w.release), what)
end

-- One boss on one difficulty: its note, then its windows by time.
function B.BossLines(list)
    local sorted, lines = {}, {}
    for i, w in ipairs(list) do sorted[i] = w end
    table.sort(sorted, function(a, b) return (a.release or -1) < (b.release or -1) end)
    if list.note then lines[#lines + 1] = "  " .. GREY .. list.note .. "|r" end
    for _, w in ipairs(sorted) do lines[#lines + 1] = WindowLine(w) end
    if #sorted == 0 then lines[#lines + 1] = "  " .. GREY .. "no burst window - burst on the pull, then on cooldown|r" end
    return lines
end

-- The bosses on a difficulty (a dungeon's own when one is named), sorted by name.
function B.Bosses(difficultyID, dungeon)
    local bosses = {}
    for encounterID, byDifficulty in pairs(CastAheadBurstWindows or {}) do
        local list = byDifficulty[difficultyID]
        if list and (not dungeon or list.dungeon == dungeon) then
            bosses[#bosses + 1] = { encounter = encounterID, name = list.name or "?", list = list }
        end
    end
    table.sort(bosses, function(a, b) return a.name < b.name end)
    return bosses
end

-- Every window on the difficulty, the healers' own marked: the guide is the same for every spec.
function B.GuideLines(difficultyID)
    local lines = {}
    for _, boss in ipairs(B.Bosses(difficultyID)) do
        if #lines > 0 then lines[#lines + 1] = "" end
        lines[#lines + 1] = GOLD .. boss.name .. "|r"
        for _, line in ipairs(B.BossLines(boss.list)) do lines[#lines + 1] = line end
    end
    return lines
end
