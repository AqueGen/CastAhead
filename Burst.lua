CastAheadBurst = {}
local B = CastAheadBurst
local M = CastAheadMatch

local SAVE_GAP = 2
local BURST_SHOWN = 5
local ICON = "Interface\\Icons\\Spell_Nature_Bloodlust"
local entries = {}
local pending = {}

local function On()
    if CastAheadConfig.Get("burstCalls") ~= true then return false end
    if not (GetSpecialization and GetSpecializationRole) then return false end
    local spec = GetSpecialization()
    return spec ~= nil and GetSpecializationRole(spec) == "DAMAGER"
end

local function SaveNear(now)
    local S = CastAheadSaves
    if not (S and S.LastFiredAt) then return false end
    local last, nextAt = S.LastFiredAt(), S.NextFireAt(now)
    return (last ~= nil and now - last < SAVE_GAP) or (nextAt ~= nil and nextAt - now < SAVE_GAP)
end

function B.OnEncounter(event, encounterID, difficultyID, now)
    wipe(entries)
    if event ~= "ENCOUNTER_START" then return end
    local byDifficulty = CastAheadBurstWindows and CastAheadBurstWindows[encounterID]
    local windows = byDifficulty and byDifficulty[difficultyID]
    if not windows then return end
    for _, w in ipairs(windows) do
        entries[#entries + 1] = { fireAt = now + w.hold, endAt = now + w.release, advice = M.ADVICE.HOLD }
        entries[#entries + 1] = { fireAt = now + w.release, endAt = now + w.release + BURST_SHOWN,
                                  advice = M.ADVICE.BURST }
    end
end

function B.Tick(now)
    if not On() then return end
    for _, e in ipairs(entries) do
        if not e.fired and now >= e.fireAt and now < e.endAt then
            if not e.deferred and SaveNear(now) then
                e.deferred, e.fireAt = true, now + SAVE_GAP
            else
                e.fired = true
                if CastAheadCore and CastAheadCore.Announce then CastAheadCore.Announce(e.advice) end
            end
        end
    end
end

function B.Pending(now)
    wipe(pending)
    if not On() then return pending end
    for _, e in ipairs(entries) do
        if e.fired and e.endAt > now then
            pending[#pending + 1] = { endAt = e.endAt, advice = e.advice, row = {}, icons = { ICON } }
        end
    end
    return pending
end
