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

local function On()
    if CastAheadConfig.Get("burstCalls") ~= true then return false end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return false end
    if not (GetSpecialization and GetSpecializationRole) then return false end
    local spec = GetSpecialization()
    return spec ~= nil and GetSpecializationRole(spec) == "DAMAGER"
end

local function Offsets(w, spec)
    local off = w.specs and spec and w.specs[spec]
    if type(off) == "number" then return off, nil end
    if type(off) == "table" then return off.full, off.mini end
    return nil, nil
end

local function DeferUntil(now, entry)
    local S = CastAheadSaves
    local at
    if S and S.LastFiredAt then
        local last, nextAt = S.LastFiredAt(), S.NextFireAt(now)
        if last ~= nil and now - last < SAVE_GAP then at = last + SAVE_GAP end
        if nextAt ~= nil and nextAt - now < SAVE_GAP then at = math.max(at or 0, nextAt + SAVE_GAP) end
    end
    if entry.advice ~= M.ADVICE.MINI then return at end
    for _, e in ipairs(entries) do
        local t = e.advice == M.ADVICE.BURST and (e.firedAt or e.fireAt)
        if t and math.abs(t - now) < SAVE_GAP then at = math.max(at or 0, t + SAVE_GAP) end
    end
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
        local full, mini = Offsets(w, spec)
        local burstAt = math.max(now + w.release + (full or 0), now)
        if now + w.hold < burstAt - HOLD_MIN then
            entries[#entries + 1] = { fireAt = now + w.hold, endAt = burstAt, advice = M.ADVICE.HOLD, tier = "full" }
        end
        entries[#entries + 1] = { fireAt = burstAt, endAt = burstAt + BURST_SHOWN, advice = M.ADVICE.BURST, tier = "full" }
        if mini then
            local miniAt = math.max(now + w.release + mini, now)
            entries[#entries + 1] = { fireAt = miniAt, endAt = miniAt + BURST_SHOWN, advice = M.ADVICE.MINI, tier = "mini" }
        end
    end
end

function B.Tick(now)
    if #entries == 0 then return end
    if IsEncounterInProgress and not IsEncounterInProgress() then wipe(entries) return end
    if not On() then return end
    for _, e in ipairs(entries) do
        if not e.fired and now >= e.fireAt and now < e.endAt then
            local at = not e.deferred and DeferUntil(now, e)
            if at then
                e.deferred, e.fireAt = true, at
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
    for _, e in ipairs(list) do
        if CastAheadLists.Known(e) and CastAheadSaves.SpellReady(e) then return Texture(e) or ICON end
    end
    return list[1] ~= nil and Texture(list[1]) or ICON
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

function B.GuideLines(difficultyID, specID)
    local bosses = {}
    for _, byDifficulty in pairs(CastAheadBurstWindows or {}) do
        local list = byDifficulty[difficultyID]
        if list then bosses[#bosses + 1] = list end
    end
    table.sort(bosses, function(a, b) return (a.name or "") < (b.name or "") end)
    local lines = {}
    local fullList, miniList = B.Lists.ListFor(specID, "full"), B.Lists.ListFor(specID, "mini")
    for _, list in ipairs(bosses) do
        lines[#lines + 1] = list.name or "?"
        for _, w in ipairs(list) do
            local line = w.target and string.format("  %s %s - burst", B.Clock(w.release), w.target)
                or string.format("  %s hold - %s burst", B.Clock(w.hold), B.Clock(w.release))
            local full, mini = Offsets(w, specID)
            if #fullList == 0 and #miniList == 0 then
                line = line .. " | no burst buttons known for this spec"
            end
            if #fullList > 0 then
                line = string.format("%s | full: %s %s", line, ButtonName(fullList[1]),
                    full and B.Clock(math.max(w.release + full, 0)) or B.Clock(w.release) .. " (shared timing)")
            end
            if #miniList > 0 and mini then
                line = string.format("%s | mini: %s %s", line, ButtonName(miniList[1]),
                    B.Clock(math.max(w.release + mini, 0)))
            end
            lines[#lines + 1] = line
        end
    end
    return lines
end
