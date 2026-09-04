-- Settings storage: which options are shared and which follow the content.
--
-- A key run and a raid want different answers to "what should be announced"
-- (a raid has its own boss mod, a key does not), but the same answer to
-- "where do the icons sit". So the eight announcement options live per
-- context under CastAheadDB.ctx, everything else stays flat.
--
-- Convention, unchanged from before: nil means on, false means off. Nothing
-- ever stores true for an on-by-default option, or a fresh profile would
-- read as "explicitly enabled" and defeat later default changes.

CastAheadConfig = {}
local C = CastAheadConfig

C.PER_CONTEXT = {
    importantOnly = true, roleFilter = true, nameplates = true, centerText = true,
    timeline = true, sound = true, voice = true, leadSeconds = true,
}

C.LEAD_DEFAULT = 5
C.LEAD_MAX = 15

-- Two contexts only. Everywhere that is neither a raid nor a party instance
-- the addon is inert anyway, and the test drive should behave like a key.
function C.Context()
    local inside, kind = IsInInstance()
    if inside and kind == "raid" then return "raid" end
    return "key"
end

-- context is optional everywhere: omitted means "whatever context the player
-- is in right now", named means that context regardless of where the player
-- is. The settings window needs the second form - the Keys tab edits the key
-- context while the player stands in a raid.
local function bucket(create, context)
    if not CastAheadDB then
        -- A read must not materialise the profile: Migrate treats an existing
        -- CastAheadDB.ctx as "already migrated", and a table conjured by a
        -- getter would be indistinguishable from a real one.
        if not create then return nil end
        CastAheadDB = {}
    end
    local name = context or C.Context()
    if not CastAheadDB.ctx then
        if not create then return nil end
        CastAheadDB.ctx = {}
    end
    if not CastAheadDB.ctx[name] then
        if not create then return nil end
        CastAheadDB.ctx[name] = {}
    end
    return CastAheadDB.ctx[name]
end

function C.Get(key, context)
    if not C.PER_CONTEXT[key] then
        return CastAheadDB and CastAheadDB[key]
    end
    local store = bucket(false, context)
    return store and store[key]
end

function C.Set(key, value, context)
    CastAheadDB = CastAheadDB or {}
    if not C.PER_CONTEXT[key] then
        CastAheadDB[key] = value
        return
    end
    bucket(true, context)[key] = value
end

function C.Enabled(key, context)
    return C.Get(key, context) ~= false
end

function C.SetEnabled(key, enabled, context)
    if enabled then
        C.Set(key, nil, context)
    else
        C.Set(key, false, context)
    end
end

-- Seconds before a predicted cast to announce it; 0 switches the heads-up
-- off. Clamped rather than rejected: a saved variable can hold anything.
function C.Lead()
    local seconds = tonumber(C.Get("leadSeconds"))
    if not seconds then return C.LEAD_DEFAULT end
    if seconds < 0 then return 0 end
    if seconds > C.LEAD_MAX then return C.LEAD_MAX end
    return seconds
end

-- The addon was called Forecast until 2026-09-01. Its saved variables live
-- under the old global for one more load: the TOC now declares CastAheadDB,
-- so ForecastDB arrives populated only while the old file is still on disk.
-- Adopt it once, then let it go.
function C.AdoptOldName()
    if CastAheadDB == nil and type(ForecastDB) == "table" then
        CastAheadDB = ForecastDB
    end
end

-- One-shot: settings saved before contexts existed are flat, and dropping
-- them would silently reset a profile. Both contexts start from what the
-- player already had.
function C.Migrate()
    CastAheadDB = CastAheadDB or {}
    if CastAheadDB.ctx then return end
    local seed = {}
    local flat = false
    for key in pairs(C.PER_CONTEXT) do
        if CastAheadDB[key] ~= nil then
            seed[key] = CastAheadDB[key]
            CastAheadDB[key] = nil
            flat = true
        end
    end
    -- The old boolean said only on or off; the slider needs a number. Only a
    -- profile that is recognisably pre-context gets seeded: a fresh one must
    -- leave leadSeconds unset so C.Lead() returns LEAD_DEFAULT. CastAheadDB
    -- itself is no evidence - Minimap.lua and bucket() both materialise it.
    if seed.leadSeconds == nil and (CastAheadDB.leadWarning ~= nil or flat) then
        seed.leadSeconds = CastAheadDB.leadWarning == true and C.LEAD_DEFAULT or 0
    end
    CastAheadDB.leadWarning = nil
    CastAheadDB.ctx = { key = {}, raid = {} }
    for _, name in ipairs({ "key", "raid" }) do
        for key, value in pairs(seed) do
            CastAheadDB.ctx[name][key] = value
        end
    end
end
