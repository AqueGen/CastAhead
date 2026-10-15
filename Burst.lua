CastAheadBurst = {}
local B = CastAheadBurst
local M = CastAheadMatch

B.Lists = CastAheadLists.New({
    dbKey = "burstButtons",
    shipped = function() return CastAheadBurstButtons end,
    keys = { "full", "mini" },
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

local function On()
    if CastAheadConfig.Get("burstCalls") ~= true then return false end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return false end
    if not (GetSpecialization and GetSpecializationRole) then return false end
    local spec = GetSpecialization()
    return spec ~= nil and GetSpecializationRole(spec) == "DAMAGER"
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

function B.OnEncounter(event, encounterID, difficultyID, now)
    wipe(entries)
    if event ~= "ENCOUNTER_START" then return end
    local byDifficulty = CastAheadBurstWindows and CastAheadBurstWindows[encounterID]
    local windows = byDifficulty and byDifficulty[difficultyID]
    if not windows then return end
    local spec = CastAheadSaves and CastAheadSaves.SpecID()
    for _, w in ipairs(windows) do
        local offset = w.specs and spec and w.specs[spec] or 0
        local burstAt = math.max(now + w.release + offset, now)
        if now + w.hold < burstAt - HOLD_MIN then
            entries[#entries + 1] = { fireAt = now + w.hold, endAt = burstAt, advice = M.ADVICE.HOLD }
        end
        entries[#entries + 1] = { fireAt = burstAt, endAt = burstAt + BURST_SHOWN, advice = M.ADVICE.BURST }
    end
end

function B.Tick(now)
    if #entries == 0 then return end
    if IsEncounterInProgress and not IsEncounterInProgress() then wipe(entries) return end
    if not On() then return end
    for _, e in ipairs(entries) do
        if not e.fired and now >= e.fireAt and now < e.endAt then
            local at = not e.deferred and DeferUntil(now)
            if at then
                e.deferred, e.fireAt = true, at
            else
                e.fired = true
                if CastAheadCore and CastAheadCore.Announce then CastAheadCore.Announce(e.advice) end
            end
        end
    end
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

local function ButtonName(spell)
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spell)
    return type(name) == "string" and name or "burst"
end

function B.GuideLines(difficultyID, specID)
    local bosses = {}
    for _, byDifficulty in pairs(CastAheadBurstWindows or {}) do
        local list = byDifficulty[difficultyID]
        if list then bosses[#bosses + 1] = list end
    end
    table.sort(bosses, function(a, b) return (a.name or "") < (b.name or "") end)
    local lines = {}
    local button = specID and CastAheadBurstButtons and CastAheadBurstButtons[specID]
    for _, list in ipairs(bosses) do
        lines[#lines + 1] = list.name or "?"
        for _, w in ipairs(list) do
            local head = w.target and string.format("  %s %s - burst", B.Clock(w.release), w.target)
                or string.format("  %s hold - %s burst", B.Clock(w.hold), B.Clock(w.release))
            local offset = w.specs and specID and w.specs[specID]
            if not button then
                lines[#lines + 1] = head .. " | no burst button known for this spec"
            elseif offset then
                lines[#lines + 1] = string.format("%s | your %s: %s", head, ButtonName(button),
                    B.Clock(math.max(w.release + offset, 0)))
            else
                lines[#lines + 1] = string.format("%s | your %s: %s (shared timing)", head, ButtonName(button),
                    B.Clock(w.release))
            end
        end
    end
    return lines
end
