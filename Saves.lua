CastAheadSaves = {}
local S = CastAheadSaves
local M = CastAheadMatch

local scheduled = {}

function S.SpecID()
    if not (GetSpecialization and GetSpecializationInfo) then return nil end
    local index = GetSpecialization()
    return index and GetSpecializationInfo(index) or nil
end

local function Known(id)
    return type(id) == "number" and IsPlayerSpell and IsPlayerSpell(id)
end

local useToItem = {}
local bagsPending = false
local memo = {}

local function Shipped(spec, size)
    local s = CastAheadSaveButtons and CastAheadSaveButtons[spec]
    return s and s[size] or {}
end

function S.List(size)
    local spec = S.SpecID()
    if not spec then return {} end
    local o = CastAheadDB and CastAheadDB.saveButtons and CastAheadDB.saveButtons[spec]
    if o and type(o[size]) == "table" then return o[size] end
    return Shipped(spec, size)
end

function S.ScanBags()
    if InCombatLockdown and InCombatLockdown() then bagsPending = true return end
    bagsPending = false
    wipe(memo)
    wipe(useToItem)
    if not (C_Container and C_Item and C_Item.GetItemSpell) then return end
    for bag = 0, 5 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local item = C_Container.GetContainerItemID(bag, slot)
            if item then
                local _, use = C_Item.GetItemSpell(item)
                if use and not useToItem[use] then useToItem[use] = item end
            end
        end
    end
end

function S.BagsPending() return bagsPending end

local function ItemReady(item)
    if not (C_Item and C_Item.GetItemCount and (C_Item.GetItemCount(item) or 0) > 0) then return false end
    local start, duration = 0, 0
    if C_Item.GetItemCooldown then start, duration = C_Item.GetItemCooldown(item) end
    return (start or 0) == 0 or (start + (duration or 0)) <= GetTime()
end

function S.Available(size)
    local stamp = GetTime()
    local hit = memo[size]
    if hit and hit.stamp == stamp then return hit.list end
    local out = {}
    memo[size] = { stamp = stamp, list = out }
    for _, e in ipairs(S.List(size)) do
        if type(e) == "number" then
            if Known(e) then
                out[#out + 1] = { kind = "spell", id = e, icon = C_Spell and C_Spell.GetSpellTexture(e) }
            end
        elseif type(e) == "table" and e.use then
            local item = useToItem[e.use]
            if item and ItemReady(item) then
                out[#out + 1] = { kind = "item", id = item, icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(item) }
            end
        end
    end
    return out
end

function S.Button(size)
    for _, e in ipairs(S.Available(size)) do
        if e.kind == "spell" then return e.id end
    end
    return nil
end

local SIZE = { SMALL = "small", BIG = "big", HEAL = "heal" }
function S.Icons(advice)
    local size = advice and SIZE[advice.key]
    local out = {}
    if not size then return out end
    for _, e in ipairs(S.Available(size)) do
        if e.icon then out[#out + 1] = e.icon end
        if #out == 3 then break end
    end
    return out
end

function S.Icon(advice) return S.Icons(advice)[1] end

function S.HealReady()
    return CastAheadConfig.Enabled("saveCalls") and CastAheadConfig.Enabled("healCalls") and #S.Available("heal") > 0
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

local function PickedFile(advice)
    local name = CastAheadDB and CastAheadDB.sounds and CastAheadDB.sounds[advice.key]
    local lsm = name and LibStub and LibStub("LibSharedMedia-3.0", true)
    local sound = lsm and lsm:Fetch("sound", name, true)
    return type(sound) == "string" and sound or nil
end

local function RegisterAuraSounds()
    if not (C_UnitAuras and C_UnitAuras.AddAuraSound and Enum and Enum.UnitAuraSoundTrigger) then return end
    if Blocked() then auraPending = true return end
    auraPending = false
    ClearAuraSounds()
    if not (CastAheadConfig.Enabled("saveCalls") and CastAheadConfig.Enabled("sound")) then return end
    local voice = CastAheadConfig.Enabled("voice")
    for spellID, row in pairs(CastAheadDefensives and CastAheadDefensives.spells or {}) do
        local advice = row.aura and M.SaveAdvice({ save = row })
        local file = advice and (PickedFile(advice) or voice and SOUND_ROOT .. advice.file .. ".ogg")
        if file then
            local ok, id = pcall(C_UnitAuras.AddAuraSound, Enum.UnitAuraSoundTrigger.Added, {
                unitToken = "player", spellID = spellID, soundFileName = file, outputChannel = "Master" })
            if ok and id then auraIDs[#auraIDs + 1] = id end
        end
    end
end

function S.AuraSoundCount() return #auraIDs end
function S.AuraPending() return auraPending end

function S.Refresh()
    wipe(memo)
    RegisterAuraSounds()
end

function S.Schedule(key, spellID, fireAt, endAt, advice)
    scheduled[key] = { spell = spellID, fireAt = fireAt, endAt = endAt, advice = advice }
end

local flashes = 0
function S.Flash(advice, now, seconds)
    flashes = flashes + 1
    scheduled["flash:" .. flashes] = { fireAt = now, endAt = now + seconds, advice = advice, fired = true, firedAt = now }
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

function S.Move(key, remaining, lead, now)
    local c = scheduled[key]
    if not c then return false end
    c.endAt = (c.pausedAt or now) + remaining
    c.fireAt = c.endAt - lead
    if c.fired and c.fireAt > now and c.fireAt - (c.firedAt or now) >= lead then c.fired = nil end
    return true
end

local pending = {}
function S.Pending(now)
    wipe(pending)
    for _, c in pairs(scheduled) do
        if not c.pausedAt and c.fired and c.endAt > now then
            local icons = S.Icons(c.advice)
            if c.advice ~= M.ADVICE.HEAL or #icons > 0 then
                pending[#pending + 1] = { endAt = c.endAt, advice = c.advice, row = { spell = c.spell }, icons = icons }
            end
        end
    end
    return pending
end

function S.Tick(now)
    local healed = false
    for key, c in pairs(scheduled) do
        if not c.pausedAt then
            if not c.fired and now >= c.fireAt and now < c.endAt then
                c.fired, c.firedAt = true, now
                if CastAheadCore and CastAheadCore.Announce then CastAheadCore.Announce(c.advice, true) end
            end
            if now >= c.endAt then
                if c.fired and c.advice == M.ADVICE.BIG and S.HealReady()
                    and CastAheadCore and CastAheadCore.Announce then
                    CastAheadCore.Announce(M.ADVICE.HEAL)
                    healed = true
                end
                scheduled[key] = nil
            end
        end
    end
    if healed then S.Flash(M.ADVICE.HEAL, now, 3) end
end
