-- Copyright (c) 2026 AqueGen. All rights reserved. See LICENSE.
CastAheadBossAdapter = {}
local A = CastAheadBossAdapter
local M = CastAheadMatch
local connected
local barsSeen, encounterAt, healthWarned, inEncounter = false, nil, false, false
local barSpells = {}
local HEALTH_WAIT = 30
local STOP_SLACK = 1.5
local SAME_HIT = 3
local windowSpells = {}

local function Key(source, barKey) return source .. ":" .. tostring(barKey) end
local function BigWigsSource(module) return "bw:" .. tostring(module) end

local function Secret(...)
    if not issecretvalue then return false end
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then return true end
    end
    return false
end

local function Verdict(spellID, barSpell)
    if not CastAheadConfig.Enabled("bossAdapter") then return nil end
    local row, resolvedId = M.SaveRow(spellID)
    if not row then return nil end
    local prio = CastAheadPriority and ((barSpell and CastAheadPriority[barSpell]) or CastAheadPriority[spellID] or CastAheadPriority[resolvedId])
    local advice = M.Advice({ prio = prio, save = row })
    if not M.IsSave(advice) then return nil end
    return spellID, row.lead or 3, advice
end

local function Delay(spellID)
    return CastAheadBossDelays and CastAheadBossDelays[spellID] or 0
end

local function Window(spellID)
    local byRole = CastAheadBossWindows and CastAheadBossWindows[spellID]
    local role = byRole and M.SpecRole and M.SpecRole()
    return role and byRole[role] or nil
end

local function Offset(spellID)
    local w = Window(spellID)
    return w and w.main or Delay(spellID)
end

local function Call(spellID)
    local w = Window(spellID)
    local id, lead, advice = Verdict(w and w.spell or spellID, spellID)
    return id, lead, advice, w
end

local function Log(...)
    if CastAheadRecorder then CastAheadRecorder.Note("BAR", "-", ...) end
end

local function Seconds(at, now) return at and string.format("%.1f", at - now) or "-" end

local function Covered(ownKey, spell, hitAt)
    for key, other in pairs(windowSpells) do
        local c = key ~= ownKey and CastAheadSaves.Window(key)
        if c and other[spell] and math.abs(c.win.main - hitAt) <= SAME_HIT then return true end
    end
    return false
end

function A.OnBar(source, barKey, spellID, duration, now)
    barsSeen = true
    if not CastAheadSaves then return end
    local key = Key(source, barKey)
    if not (inEncounter or (IsEncounterInProgress and IsEncounterInProgress())) then
        Log("begin", key, spellID, duration, "outside")
        return
    end
    spellID, duration = tonumber(spellID), tonumber(duration)
    if not (spellID and duration) or duration <= 0 then return end
    local id, lead, advice, w = Call(spellID)
    if not id then
        Log("begin", key, spellID, duration, "noverdict")
        return
    end
    local endAt = now + duration + Offset(spellID)
    local _, hit = M.SaveRow(id)
    if Covered(key, hit or id, endAt) then
        Log("begin", key, spellID, duration, "covered")
        return
    end
    barSpells[key] = spellID
    local win
    if w then
        win = { first = now + duration + w.first, main = endAt, lead = lead }
        local spells = {}
        for _, s in ipairs(w.spells) do spells[s] = true end
        windowSpells[key] = spells
    end
    CastAheadSaves.Schedule(key, id, endAt - lead, endAt, advice, win)
    local fireAt, _, pick = CastAheadSaves.Peek(key)
    Log("begin", key, spellID, duration, w and "window" or "delay", Seconds(fireAt, now), Seconds(endAt, now), pick or "-")
end

function A.OnUpdate(source, barKey, elapsed, total, now)
    if not CastAheadSaves then return end
    local key = Key(source, barKey)
    local spellID = barSpells[key]
    elapsed, total = tonumber(elapsed), tonumber(total)
    if not (spellID and elapsed and total) then return end
    local id, lead = Call(spellID)
    if not id then return end
    Log("update", key, spellID, total - elapsed)
    if not CastAheadSaves.Move(key, total - elapsed + Offset(spellID), lead, now) then
        A.OnBar(source, barKey, spellID, total - elapsed, now)
    end
end

function A.OnStop(source, barKey)
    if not CastAheadSaves then return end
    local key = Key(source, barKey)
    local spellID, endAt = barSpells[key], CastAheadSaves.EndAt(key)
    barSpells[key] = nil
    if spellID and endAt and GetTime() >= endAt - Offset(spellID) - STOP_SLACK then
        Log("stop", key, spellID, "kept")
        return
    end
    if spellID then Log("stop", key, spellID, "cancelled") end
    windowSpells[key] = nil
    CastAheadSaves.Cancel(key)
end

function A.OnStopAll(source)
    if not CastAheadSaves then return end
    local prefix = source .. ":"
    for key in pairs(barSpells) do
        if key:sub(1, #prefix) == prefix then barSpells[key] = nil end
    end
    for key in pairs(windowSpells) do
        if key:sub(1, #prefix) == prefix then windowSpells[key] = nil end
    end
    CastAheadSaves.CancelPrefix(prefix)
end

function A.OnPause(source, barKey, now)
    if not CastAheadSaves then return end
    CastAheadSaves.Pause(Key(source, barKey), now)
end

function A.OnResume(source, barKey, now)
    if not CastAheadSaves then return end
    CastAheadSaves.Resume(Key(source, barKey), now)
end

function A.Connect()
    local dbm, bw
    if DBM and DBM.RegisterCallback then
        DBM:RegisterCallback("DBM_TimerBegin", function(_, id, _, timer, _, _, spellId)
            if Secret(id, timer, spellId) then barsSeen = true return end
            A.OnBar("dbm", id, spellId, timer, GetTime())
        end)
        DBM:RegisterCallback("DBM_TimerStop", function(_, id)
            if Secret(id) then return end
            A.OnStop("dbm", id)
        end)
        DBM:RegisterCallback("DBM_TimerPause", function(_, id)
            if Secret(id) then return end
            A.OnPause("dbm", id, GetTime())
        end)
        DBM:RegisterCallback("DBM_TimerResume", function(_, id)
            if Secret(id) then return end
            A.OnResume("dbm", id, GetTime())
        end)
        DBM:RegisterCallback("DBM_TimerUpdate", function(_, id, elapsed, total)
            if Secret(id, elapsed, total) then return end
            A.OnUpdate("dbm", id, elapsed, total, GetTime())
        end)
        dbm = true
    end
    if not dbm and type(BigWigsLoader) == "table" and BigWigsLoader.RegisterMessage then
        BigWigsLoader.RegisterMessage(A, "BigWigs_StartBar", function(_, module, key, text, duration)
            if Secret(module, key, text, duration) then barsSeen = true return end
            A.OnBar(BigWigsSource(module), text, key, duration, GetTime())
        end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_Timer", function(_, module, key, duration, _, text, _, _, _, isBarEnabled)
            if Secret(module, key, duration, text, isBarEnabled) then barsSeen = true return end
            if isBarEnabled then return end
            A.OnBar(BigWigsSource(module), text, key, duration, GetTime())
        end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_StopBar", function(_, module, text)
            if Secret(module, text) then return end
            A.OnStop(BigWigsSource(module), text)
        end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_PauseBar", function(_, module, text)
            if Secret(module, text) then return end
            A.OnPause(BigWigsSource(module), text, GetTime())
        end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_ResumeBar", function(_, module, text)
            if Secret(module, text) then return end
            A.OnResume(BigWigsSource(module), text, GetTime())
        end)
        local function StopModule(_, module)
            if Secret(module) then return end
            A.OnStopAll(BigWigsSource(module))
        end
        BigWigsLoader.RegisterMessage(A, "BigWigs_StopBars", StopModule)
        BigWigsLoader.RegisterMessage(A, "BigWigs_OnBossDisable", StopModule)
        bw = true
    end
    connected = dbm and "DBM" or bw and "BigWigs" or nil
    return connected
end

function A.Status()
    if connected then return connected .. " connected" end
    return "No boss mod"
end

function A.OnEncounter(event)
    if event == "ENCOUNTER_START" then
        barsSeen, encounterAt, inEncounter = false, GetTime(), true
    else
        encounterAt, inEncounter = nil, false
        A.OnStopAll("dbm")
        A.OnStopAll("bw")
    end
end

function A.Tick(now)
    if encounterAt and connected and not barsSeen and not healthWarned and now - encounterAt > HEALTH_WAIT
        and CastAheadConfig.SaveCalls() and CastAheadConfig.Enabled("bossAdapter") then
        encounterAt, healthWarned = nil, true
        print("|cff33ff99CastAhead|r " .. connected .. " sent no boss timers this fight - boss save calls are off until it does.")
    end
end
