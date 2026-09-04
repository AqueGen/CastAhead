-- Settings storage.
--
-- One flat table. Settings were briefly split per content type (keys vs
-- raid), which cost a whole tab and bought nothing: the cast database holds
-- keystone dungeons only, so in a raid the addon has nothing to say and a
-- second set of switches just gave the player a way to change settings that
-- never fire.
--
-- Convention: nil means on, false means off. Nothing ever stores true for an
-- on-by-default option, or a fresh profile would read as "explicitly
-- enabled" and defeat later default changes.

CastAheadConfig = {}
local C = CastAheadConfig

-- Off: the heads-up before a cast reads as noise more often than as warning,
-- so the call lands when the cast starts unless the player asks for lead.
C.LEAD_DEFAULT = 0
C.LEAD_MAX = 15

function C.Get(key)
    return CastAheadDB and CastAheadDB[key]
end

function C.Set(key, value)
    CastAheadDB = CastAheadDB or {}
    CastAheadDB[key] = value
end

function C.Enabled(key)
    return C.Get(key) ~= false
end

function C.SetEnabled(key, enabled)
    if enabled then
        C.Set(key, nil)
    else
        C.Set(key, false)
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

-- One-shot, run at login. Two older profile shapes exist and both would
-- otherwise read as a reset: the per-context one (CastAheadDB.ctx.key) and
-- the flat one from before the early warning became a number.
function C.Migrate()
    CastAheadDB = CastAheadDB or {}
    if type(CastAheadDB.ctx) == "table" then
        -- The key context was the one that ever fired; the raid one is
        -- dropped along with the tab that edited it.
        for key, value in pairs(CastAheadDB.ctx.key or {}) do
            if CastAheadDB[key] == nil then CastAheadDB[key] = value end
        end
        CastAheadDB.ctx = nil
    end
    if CastAheadDB.leadWarning ~= nil then
        -- The old boolean said only on or off, and on meant five seconds.
        if CastAheadDB.leadSeconds == nil then
            CastAheadDB.leadSeconds = CastAheadDB.leadWarning == true and 5 or 0
        end
        CastAheadDB.leadWarning = nil
    end
end
