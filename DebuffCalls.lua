local D = {}
CastAheadDebuffCalls = D

local CLIP_ROOT = "Interface\\AddOns\\CastAhead\\Sounds\\en\\"
local registered = {}
local pending = false
local rows

local function InCombat()
    return InCombatLockdown and InCombatLockdown()
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
    if InCombat() then
        pending = true
        return
    end
    pending = false
    RemoveOurs()
    local C = CastAheadConfig
    rows = C.Enabled("debuffCalls") and InstanceRows() or nil
    local add = C_UnitAuras and C_UnitAuras.AddAuraSound
    local trigger = Enum and Enum.UnitAuraSoundTrigger and Enum.UnitAuraSoundTrigger.Added
    if not (rows and add and trigger and C.Enabled("sound")) then return end
    for spellID, kind in pairs(rows) do
        local advice = CastAheadMatch.ADVICE[kind]
        if advice and not Off(spellID) then
            local ok, id = pcall(add, trigger, { unitToken = "player", spellID = spellID,
                soundFileName = CLIP_ROOT .. advice.file .. ".ogg", outputChannel = "Master" })
            if not ok then
                pending = true
            elseif id then
                registered[#registered + 1] = id
            end
        end
    end
end

function D.AfterCombat()
    if pending then D.Refresh() end
end
