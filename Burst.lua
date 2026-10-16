CastAheadBurst = {}
local B = CastAheadBurst
local M = CastAheadMatch

B.Lists = CastAheadLists.New({
    dbKey = "burstButtons",
    shipped = function() return CastAheadBurstButtons end,
    keys = { "full", "mini" },
    offerOwnShipped = true,
    specID = function() return CastAheadSaves and CastAheadSaves.SpecID() end,
    onChange = function() end,
})

if StaticPopupDialogs then
    StaticPopupDialogs.CASTAHEAD_RESET_BURSTS = {
        text = "Reset Full and Mini burst lists for this specialization to the defaults?",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function()
            B.Lists.ResetSpec()
            if CastAheadOptions and CastAheadOptions.RefreshDefensives then CastAheadOptions.RefreshDefensives() end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

local SAVE_GAP = 2
local HOLD_MIN = 5
local BURST_SHOWN = 5
local ICON = "Interface\\Icons\\Spell_Nature_Bloodlust"
local entries = {}
local pending = {}

local function Role()
    if not (GetSpecialization and GetSpecializationRole) then return nil end
    local spec = GetSpecialization()
    return spec and GetSpecializationRole(spec) or nil
end

local function On()
    if CastAheadConfig.Get("burstCalls") ~= true then return false end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return false end
    return Role() ~= nil
end

-- Healers get their own windows (heavy group damage); a boss-event window is for everyone.
local function ForRole(w, role)
    return w.event ~= nil or (w.role == "HEALER") == (role == "HEALER")
end

local function Offsets(w, spec)
    local off = w.specs and spec and w.specs[spec]
    if type(off) == "number" then return off, nil end
    if type(off) == "table" then return off.full, off.mini end
    return nil, nil
end

local function DeferUntil(now)
    local S = CastAheadSaves
    if not (S and S.LastFiredAt) then return nil end
    local last, nextAt = S.LastFiredAt(), S.NextFireAt(now)
    local at
    if last ~= nil and now - last < SAVE_GAP then at = last + SAVE_GAP end
    if nextAt ~= nil and nextAt - now < SAVE_GAP then at = math.max(at or 0, nextAt + SAVE_GAP) end
    return at
end

local function AfterBurst(now)
    local at
    for _, e in ipairs(entries) do
        local t = e.advice == M.ADVICE.BURST and (e.firedAt or e.fireAt)
        if t and math.abs(t - now) < SAVE_GAP then at = math.max(at or 0, t + SAVE_GAP) end
    end
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
    local spec = CastAheadSaves and CastAheadSaves.SpecID()
    local listed = CastAheadBurstButtons and spec and CastAheadBurstButtons[spec] ~= nil
    local function TierOn(tier)
        return #B.Lists.ListFor(spec, tier) > 0 or not listed and not B.Lists.Emptied(spec, tier)
    end
    local fullOn, miniOn = TierOn("full"), TierOn("mini")
    local role, events = Role(), {}
    for _, w in ipairs(windows) do
        local mine = ForRole(w, role)
        if mine and w.event then
            if fullOn then events[#events + 1] = w.event end
        elseif mine then
            local full, mini = Offsets(w, spec)
            local burstAt = math.max(now + w.release + (full or 0), now)
            if fullOn and now + w.hold < burstAt - HOLD_MIN then
                entries[#entries + 1] = { fireAt = now + w.hold, endAt = burstAt, advice = M.ADVICE.HOLD, tier = "full" }
            end
            if fullOn then
                entries[#entries + 1] = { fireAt = burstAt, endAt = burstAt + BURST_SHOWN, advice = M.ADVICE.BURST, tier = "full" }
            end
            if miniOn and mini then
                local miniAt = math.max(now + w.release + mini, now)
                entries[#entries + 1] = { fireAt = miniAt, endAt = miniAt + BURST_SHOWN, advice = M.ADVICE.MINI, tier = "mini" }
            end
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
    if #entries == 0 then return end
    if IsEncounterInProgress and not IsEncounterInProgress() then wipe(entries) return end
    if not On() then return end
    for _, e in ipairs(entries) do
        if not e.fired and now >= e.fireAt and now < e.endAt then
            local at = not e.deferred and DeferUntil(now)
            local after = not at and e.advice == M.ADVICE.MINI and AfterBurst(now)
            if at then
                e.deferred, e.fireAt = true, at
            elseif after then
                e.endAt, e.fireAt = e.endAt + after - e.fireAt, after
            else
                e.fired, e.firedAt = true, now
                if CastAheadCore and CastAheadCore.Announce then CastAheadCore.Announce(e.advice) end
            end
        end
    end
end

local function SpellOf(entry)
    return type(entry) == "table" and entry.use or entry
end

local function Texture(entry)
    return C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(SpellOf(entry)) or nil
end

local function TierIcon(tier)
    local list = B.Lists.List(tier)
    local first = CastAheadSaves.FirstAvailable(list)
    return first and first.icon or list[1] ~= nil and Texture(list[1]) or ICON
end

function B.Pending(now)
    wipe(pending)
    if #entries == 0 or not On() then return pending end
    for _, e in ipairs(entries) do
        if e.fired and e.endAt > now then
            pending[#pending + 1] = { endAt = e.endAt, advice = e.advice, row = {}, icons = { TierIcon(e.tier) } }
        end
    end
    return pending
end

function B.Clock(seconds)
    local total = math.floor(seconds + 0.5)
    return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local function ButtonName(entry)
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(SpellOf(entry))
    return type(name) == "string" and name or "burst"
end

local function WindowLine(w, specID, fullList, miniList)
    local line
    if w.event then
        line = string.format("  %s - burst when the boss warning shows", w.target or "boss event")
    elseif w.target and w.hold < w.release then
        line = string.format("  %s hold - %s %s burst", B.Clock(w.hold), B.Clock(w.release), w.target)
    elseif w.target then
        line = string.format("  %s %s - burst", B.Clock(w.release), w.target)
    else
        line = string.format("  %s hold - %s burst", B.Clock(w.hold), B.Clock(w.release))
    end
    if #fullList == 0 and #miniList == 0 then
        return line .. " | no burst buttons known for this spec"
    end
    if w.event then
        return #fullList > 0 and string.format("%s | full: %s", line, ButtonName(fullList[1])) or line
    end
    local full, mini = Offsets(w, specID)
    if #fullList > 0 then
        line = string.format("%s | full: %s %s", line, ButtonName(fullList[1]),
            full and B.Clock(math.max(w.release + full, 0)) or B.Clock(w.release) .. " (shared timing)")
    end
    if #miniList > 0 and mini then
        line = string.format("%s | mini: %s %s", line, ButtonName(miniList[1]),
            B.Clock(math.max(w.release + mini, 0)))
    end
    return line
end

function B.GuideLines(difficultyID, specID)
    local bosses = {}
    for _, byDifficulty in pairs(CastAheadBurstWindows or {}) do
        local list = byDifficulty[difficultyID]
        if list then bosses[#bosses + 1] = list end
    end
    table.sort(bosses, function(a, b) return (a.name or "") < (b.name or "") end)
    local lines = {}
    local fullList, miniList = B.Lists.ListFor(specID, "full"), B.Lists.ListFor(specID, "mini")
    local role = GetSpecializationRoleByID and specID and GetSpecializationRoleByID(specID)
    for _, list in ipairs(bosses) do
        local own = {}
        for _, w in ipairs(list) do
            if ForRole(w, role) then own[#own + 1] = WindowLine(w, specID, fullList, miniList) end
        end
        if #own > 0 then
            lines[#lines + 1] = list.name or "?"
            for _, line in ipairs(own) do lines[#lines + 1] = line end
        end
    end
    return lines
end
