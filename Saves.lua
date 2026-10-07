CastAheadSaves = {}
local S = CastAheadSaves
local M = CastAheadMatch

local scheduled = {}
local iconCache = {}

function S.SpecID()
    if not (GetSpecialization and GetSpecializationInfo) then return nil end
    local index = GetSpecialization()
    return index and GetSpecializationInfo(index) or nil
end

local function Known(id)
    return type(id) == "number" and IsPlayerSpell and IsPlayerSpell(id)
end

function S.Button(size)
    local spec = S.SpecID()
    if not spec then return nil end
    local picks = CastAheadDB and CastAheadDB.saveButtons and CastAheadDB.saveButtons[spec]
    local pick = picks and picks[size]
    if Known(pick) then return pick end
    local shipped = CastAheadSaveButtons and CastAheadSaveButtons[spec]
    for _, id in ipairs(shipped and shipped[size] or {}) do
        if Known(id) then return id end
    end
    return nil
end

function S.Icon(advice)
    if not M.IsSave(advice) then return nil end
    local size = advice == M.ADVICE.BIG and "big" or "small"
    if iconCache[size] == nil then
        local id = S.Button(size)
        iconCache[size] = id and C_Spell and C_Spell.GetSpellTexture(id) or false
    end
    return iconCache[size] or nil
end

function S.Lead(spellID)
    local row = CastAheadDefensives and CastAheadDefensives.spells[spellID]
    return row and row.lead or nil
end

local SOUND_ROOT = "Interface\\AddOns\\CastAhead\\Sounds\\en\\"
local auraIDs = {}
local auraPending = false

local function ClearAuraSounds()
    for i = #auraIDs, 1, -1 do
        pcall(C_UnitAuras.RemoveAuraSound, auraIDs[i])
        auraIDs[i] = nil
    end
end

local function Blocked()
    return (InCombatLockdown and InCombatLockdown())
        or (C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown())
end

local function RegisterAuraSounds()
    if not (C_UnitAuras and C_UnitAuras.AddAuraSound and Enum and Enum.UnitAuraSoundTrigger) then return end
    if Blocked() then auraPending = true return end
    auraPending = false
    ClearAuraSounds()
    if not CastAheadConfig.Enabled("saveCalls") then return end
    for spellID, row in pairs(CastAheadDefensives and CastAheadDefensives.spells or {}) do
        local advice = row.aura and M.SaveAdvice({ save = row })
        if advice then
            local ok, id = pcall(C_UnitAuras.AddAuraSound, Enum.UnitAuraSoundTrigger.Added, {
                unitToken = "player", spellID = spellID,
                soundFileName = SOUND_ROOT .. advice.file .. ".ogg", outputChannel = "Master" })
            if ok and id then auraIDs[#auraIDs + 1] = id end
        end
    end
end

function S.AuraSoundCount() return #auraIDs end
function S.AuraPending() return auraPending end

function S.Refresh()
    wipe(iconCache)
    RegisterAuraSounds()
end

function S.Schedule(key, spellID, fireAt, endAt, advice)
    scheduled[key] = { spell = spellID, fireAt = fireAt, endAt = endAt, advice = advice }
end

function S.Cancel(key)
    scheduled[key] = nil
end

function S.CancelPrefix(prefix)
    for key in pairs(scheduled) do
        if key:sub(1, #prefix) == prefix then scheduled[key] = nil end
    end
end

function S.Pause(key, now)
    local c = scheduled[key]
    if c and not c.pausedAt then c.pausedAt = now end
end

function S.Resume(key, now)
    local c = scheduled[key]
    if c and c.pausedAt then
        local held = now - c.pausedAt
        c.fireAt, c.endAt, c.pausedAt = c.fireAt + held, c.endAt + held, nil
    end
end

local pending = {}
function S.Pending(now)
    wipe(pending)
    for _, c in pairs(scheduled) do
        if not c.pausedAt and c.fired and c.endAt > now then
            pending[#pending + 1] = { endAt = c.endAt, advice = c.advice, row = { spell = c.spell },
                                      icon = S.Icon(c.advice) }
        end
    end
    return pending
end

function S.Tick(now)
    for key, c in pairs(scheduled) do
        if not c.pausedAt then
            if not c.fired and now >= c.fireAt then
                c.fired = true
                if CastAheadCore and CastAheadCore.Announce then CastAheadCore.Announce(c.advice, true) end
            end
            if now >= c.endAt then scheduled[key] = nil end
        end
    end
end
