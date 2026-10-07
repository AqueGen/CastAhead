CastAheadBossAdapter = {}
local A = CastAheadBossAdapter
local M = CastAheadMatch
local connected
local barsSeen, encounterAt = false, nil
local barSpells = {}
local HEALTH_WAIT = 30

local function Key(source, barKey) return source .. ":" .. tostring(barKey) end

function A.OnBar(source, barKey, spellID, duration, now)
    spellID, duration = tonumber(spellID), tonumber(duration)
    if not (spellID and duration) then return end
    barsSeen = true
    local data = CastAheadDefensives
    if not data then return end
    local id = data.alias and data.alias[spellID] or spellID
    local row = data.spells and data.spells[id]
    local advice = row and M.SaveAdvice({ save = row })
    if not advice or not CastAheadConfig.Enabled("saveCalls") or not CastAheadConfig.Enabled("bossAdapter") then return end
    local key = Key(source, barKey)
    local endAt = now + duration
    barSpells[key] = spellID
    CastAheadSaves.Schedule(key, id, endAt - (row.lead or 3), endAt, advice)
end

function A.OnUpdate(source, barKey, elapsed, total, now)
    local spellID = barSpells[Key(source, barKey)]
    elapsed, total = tonumber(elapsed), tonumber(total)
    if spellID and elapsed and total then A.OnBar(source, barKey, spellID, total - elapsed, now) end
end

function A.OnStop(source, barKey)
    local key = Key(source, barKey)
    barSpells[key] = nil
    CastAheadSaves.Cancel(key)
end

function A.OnStopAll(source)
    local prefix = source .. ":"
    for key in pairs(barSpells) do
        if key:sub(1, #prefix) == prefix then barSpells[key] = nil end
    end
    CastAheadSaves.CancelPrefix(prefix)
end

function A.OnPause(source, barKey, now) CastAheadSaves.Pause(Key(source, barKey), now) end
function A.OnResume(source, barKey, now) CastAheadSaves.Resume(Key(source, barKey), now) end

function A.Connect()
    local dbm, bw
    if DBM and DBM.RegisterCallback then
        DBM:RegisterCallback("DBM_TimerBegin", function(_, id, _, timer, _, _, spellId)
            A.OnBar("dbm", id, spellId, timer, GetTime())
        end)
        DBM:RegisterCallback("DBM_TimerStop", function(_, id) A.OnStop("dbm", id) end)
        DBM:RegisterCallback("DBM_TimerPause", function(_, id) A.OnPause("dbm", id, GetTime()) end)
        DBM:RegisterCallback("DBM_TimerResume", function(_, id) A.OnResume("dbm", id, GetTime()) end)
        DBM:RegisterCallback("DBM_TimerUpdate", function(_, id, elapsed, total)
            A.OnUpdate("dbm", id, elapsed, total, GetTime())
        end)
        dbm = true
    end
    if type(BigWigsLoader) == "table" and BigWigsLoader.RegisterMessage then
        BigWigsLoader.RegisterMessage(A, "BigWigs_StartBar", function(_, _, key, text, duration)
            A.OnBar("bw", text, key, duration, GetTime())
        end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_StopBar", function(_, _, text) A.OnStop("bw", text) end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_PauseBar", function(_, _, text) A.OnPause("bw", text, GetTime()) end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_ResumeBar", function(_, _, text) A.OnResume("bw", text, GetTime()) end)
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
    if encounterAt and connected and not barsSeen and now - encounterAt > HEALTH_WAIT then
        encounterAt = nil
        local name = connected == "both" and "DBM and BigWigs" or connected
        print("|cff33ff99Cast Ahead|r " .. name .. " sent no boss timers this fight - boss save calls are off until it does.")
    end
end
