CastAheadBossAdapter = {}
local A = CastAheadBossAdapter
local M = CastAheadMatch
local connected
local barsSeen, encounterAt, healthWarned, inEncounter = false, nil, false, false
local barSpells = {}
local HEALTH_WAIT = 30

local function Key(source, barKey) return source .. ":" .. tostring(barKey) end
local function BigWigsSource(module) return "bw:" .. tostring(module) end

local function Secret(...)
    if not issecretvalue then return false end
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then return true end
    end
    return false
end

local function Verdict(spellID)
    if not CastAheadConfig.Enabled("bossAdapter") then return nil end
    local row, resolvedId = M.SaveRow(spellID)
    if not row then return nil end
    local advice = M.Advice({ prio = CastAheadPriority and (CastAheadPriority[spellID] or CastAheadPriority[resolvedId]),
                              save = row })
    if not M.IsSave(advice) then return nil end
    return spellID, row.lead or 3, advice
end

function A.OnBar(source, barKey, spellID, duration, now)
    barsSeen = true
    if not CastAheadSaves then return end
    if not (inEncounter or (IsEncounterInProgress and IsEncounterInProgress())) then return end
    spellID, duration = tonumber(spellID), tonumber(duration)
    if not (spellID and duration) or duration <= 0 then return end
    local id, lead, advice = Verdict(spellID)
    if not id then return end
    local key = Key(source, barKey)
    local endAt = now + duration
    barSpells[key] = spellID
    CastAheadSaves.Schedule(key, id, endAt - lead, endAt, advice)
end

function A.OnUpdate(source, barKey, elapsed, total, now)
    if not CastAheadSaves then return end
    local key = Key(source, barKey)
    local spellID = barSpells[key]
    elapsed, total = tonumber(elapsed), tonumber(total)
    if not (spellID and elapsed and total) then return end
    local id, lead = Verdict(spellID)
    if not id then return end
    if not CastAheadSaves.Move(key, total - elapsed, lead, now) then
        A.OnBar(source, barKey, spellID, total - elapsed, now)
    end
end

function A.OnStop(source, barKey)
    if not CastAheadSaves then return end
    local key = Key(source, barKey)
    barSpells[key] = nil
    CastAheadSaves.Cancel(key)
end

function A.OnStopAll(source)
    if not CastAheadSaves then return end
    local prefix = source .. ":"
    for key in pairs(barSpells) do
        if key:sub(1, #prefix) == prefix then barSpells[key] = nil end
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
        and CastAheadConfig.Enabled("saveCalls") and CastAheadConfig.Enabled("bossAdapter") then
        encounterAt, healthWarned = nil, true
        print("|cff33ff99Cast Ahead|r " .. connected .. " sent no boss timers this fight - boss save calls are off until it does.")
    end
end
