CastAheadBossAdapter = {}
local A = CastAheadBossAdapter
local M = CastAheadMatch
local connected
local barsSeen, encounterAt, healthWarned = false, nil, false
local barSpells = {}
local HEALTH_WAIT = 30

local function Key(source, barKey) return source .. ":" .. tostring(barKey) end

local function Secret(...)
    if not issecretvalue then return false end
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then return true end
    end
    return false
end

local function Verdict(spellID)
    local row = M.SaveRow(spellID)
    local advice = row and M.SaveAdvice({ save = row })
    if not advice or not CastAheadConfig.Enabled("bossAdapter") then return nil end
    return spellID, row.lead or 3, advice
end

function A.OnBar(source, barKey, spellID, duration, now)
    barsSeen = true
    if not CastAheadSaves then return end
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
    if type(BigWigsLoader) == "table" and BigWigsLoader.RegisterMessage then
        BigWigsLoader.RegisterMessage(A, "BigWigs_StartBar", function(_, _, key, text, duration)
            if Secret(key, text, duration) then barsSeen = true return end
            A.OnBar("bw", text, key, duration, GetTime())
        end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_Timer", function(_, _, key, duration, _, text, _, _, _, isBarEnabled)
            if Secret(key, duration, text, isBarEnabled) then barsSeen = true return end
            if isBarEnabled then return end
            A.OnBar("bw", text, key, duration, GetTime())
        end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_StopBar", function(_, _, text)
            if Secret(text) then return end
            A.OnStop("bw", text)
        end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_PauseBar", function(_, _, text)
            if Secret(text) then return end
            A.OnPause("bw", text, GetTime())
        end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_ResumeBar", function(_, _, text)
            if Secret(text) then return end
            A.OnResume("bw", text, GetTime())
        end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_StopBars", function() A.OnStopAll("bw") end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_OnBossDisable", function() A.OnStopAll("bw") end)
        bw = true
    end
    connected = dbm and bw and "both" or dbm and "DBM" or bw and "BigWigs" or nil
    return connected
end

function A.Status()
    if connected == "both" then return "DBM and BigWigs connected" end
    if connected then return connected .. " connected" end
    return "No boss mod"
end

function A.OnEncounter(event)
    if event == "ENCOUNTER_START" then
        barsSeen, encounterAt = false, GetTime()
    else
        encounterAt = nil
        A.OnStopAll("dbm")
        A.OnStopAll("bw")
    end
end

function A.Tick(now)
    if encounterAt and connected and not barsSeen and not healthWarned and now - encounterAt > HEALTH_WAIT
        and CastAheadConfig.Enabled("saveCalls") and CastAheadConfig.Enabled("bossAdapter") then
        encounterAt, healthWarned = nil, true
        local name = connected == "both" and "DBM and BigWigs" or connected
        print("|cff33ff99Cast Ahead|r " .. name .. " sent no boss timers this fight - boss save calls are off until it does.")
    end
end
