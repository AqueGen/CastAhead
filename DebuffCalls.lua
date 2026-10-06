local D = {}
CastAheadDebuffCalls = D

local CLIP_ROOT = "Interface\\AddOns\\CastAhead\\Sounds\\en\\"
local registered = {}
local pending = false
local rows
local active = {}

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v)
end

local function AddingBlocked()
    if InCombatLockdown and InCombatLockdown() then return true end
    local chat = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
    return chat ~= nil and chat() == true
end

local function Off(spellID)
    return CastAheadUI and CastAheadUI.IsDisabled and CastAheadUI.IsDisabled(spellID)
end

local function InstanceRows()
    if not (IsInInstance() and CastAheadDebuffs) then return nil end
    local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    return instanceID and CastAheadDebuffs[instanceID]
end

local function RemoveOurs()
    local remove = C_UnitAuras and C_UnitAuras.RemoveAuraSound
    for i = #registered, 1, -1 do
        if remove then pcall(remove, registered[i]) end
        registered[i] = nil
    end
end

function D.Refresh()
    local C = CastAheadConfig
    rows = C.Enabled("debuffCalls") and InstanceRows() or nil
    local add = C_UnitAuras and C_UnitAuras.AddAuraSound
    local trigger = Enum and Enum.UnitAuraSoundTrigger and Enum.UnitAuraSoundTrigger.Added
    local speak = rows and add and trigger and C.Enabled("sound") and C.Enabled("voice")
    pending = false
    if speak and AddingBlocked() then
        pending = true
    else
        RemoveOurs()
        if speak then
            for spellID, kind in pairs(rows) do
                local advice = CastAheadMatch.ADVICE[kind]
                if advice and not Off(spellID) then
                    local ok, id = pcall(add, trigger, { unitToken = "player", spellID = spellID,
                        soundFileName = CLIP_ROOT .. advice.file .. ".ogg", outputChannel = "Master" })
                    if ok and id then
                        registered[#registered + 1] = id
                    else
                        pending = true
                    end
                end
            end
        end
    end
    D.OnPlayerAura()
end

function D.Retry()
    if pending then D.Refresh() end
end

local function Readable(spellID)
    local ask = C_Secrets and C_Secrets.ShouldSpellAuraBeSecret
    if not ask then return false end
    local ok, secret = pcall(ask, spellID)
    return ok and secret == false
end

function D.OnPlayerAura()
    wipe(active)
    local get = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
    if not (rows and get) then return end
    for spellID in pairs(rows) do
        if not Off(spellID) and Readable(spellID) then
            local ok, aura = pcall(get, spellID)
            if ok and not IsSecret(aura) and aura ~= nil then
                local expires = aura.expirationTime
                if not IsSecret(expires) then
                    active[spellID] = (type(expires) == "number" and expires > 0) and expires or math.huge
                end
            end
        end
    end
end

function D.Picks(now, out)
    for spellID, endAt in pairs(active) do
        local advice = rows and CastAheadMatch.ADVICE[rows[spellID]]
        if advice and endAt > now then
            out[#out + 1] = { endAt = endAt, advice = advice, row = { spell = spellID }, debuff = true }
        end
    end
end
