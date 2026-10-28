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

-- Every nameplate addon draws a different frame, so where our icons land and
-- how big they are has to be the player's call. Sizes are in pixels at the
-- default UI scale; the nudge shifts the whole row off the anchor point.
C.ICON_DEFAULT, C.ICON_MIN, C.ICON_MAX = 26, 14, 64
C.NUDGE_MAX = 100
-- Sideways spacing: by default each icon steps far enough that the labels
-- under neighbours never touch. Fixed spacing steps by icon plus this gap
-- instead, so every row packs the same and wide labels may overlap (#20).
C.GAP_DEFAULT, C.GAP_MAX = 4, 40
-- Where the icons draw relative to everything else. Nameplates live under
-- WorldFrame, below all of UIParent, so even BACKGROUND clears every plate
-- while staying under the whole UI, the way a plate does; DIALOG and above
-- are for a Plater profile that lifts plates into UIParent (#19).
C.STRATA = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }
C.STRATA_DEFAULT = "BACKGROUND"
C.CENTER_DEFAULT, C.CENTER_MIN, C.CENTER_MAX = 80, 50, 250
C.CENTER_Y_DEFAULT = 30
-- The advice under an icon is sized from the icon, so one setting keeps them
-- in proportion. This is the adjustment on top of that, in percent, for a
-- player who wants tighter rows or larger words than the icon implies.
C.LABEL_DEFAULT, C.LABEL_MIN, C.LABEL_MAX = 100, 50, 200
-- The countdown drawn on the icon, and the words in the centre call, are
-- adjusted the same way: a percentage of what the thing they sit on implies.
C.TIME_DEFAULT, C.TIME_MIN, C.TIME_MAX = 100, 50, 200
C.CENTER_TEXT_DEFAULT, C.CENTER_TEXT_MIN, C.CENTER_TEXT_MAX = 100, 50, 200

function C.Get(key)
    return CastAheadDB and CastAheadDB[key]
end

-- A saved variable can hold anything, so every number the drawing code reads
-- comes back through one clamp rather than being trusted where it is used.
function C.Number(key, default, low, high)
    local value = tonumber(C.Get(key))
    if not value then return default end
    if value < low then return low end
    if value > high then return high end
    return value
end

function C.IconSize()
    return C.Number("iconSize", C.ICON_DEFAULT, C.ICON_MIN, C.ICON_MAX)
end

function C.FixedGap()
    if C.Get("fixedSpacing") ~= true then return nil end
    return C.Number("iconGap", C.GAP_DEFAULT, 0, C.GAP_MAX)
end

function C.Strata()
    local value = C.Get("strata")
    for _, name in ipairs(C.STRATA) do
        if name == value then return value end
    end
    return C.STRATA_DEFAULT
end

-- The game gives a played file no volume of its own, only a channel, so the
-- channel is how a player sets our level apart from Master: each one has its
-- own slider in the game's Sound options.
C.CHANNELS = { "Master", "Dialog", "SFX" }
C.CHANNEL_DEFAULT = "Master"

function C.SoundChannel()
    local value = C.Get("soundChannel")
    for _, name in ipairs(C.CHANNELS) do
        if name == value then return value end
    end
    return C.CHANNEL_DEFAULT
end

function C.NudgeX()
    return C.Number("nudgeX", 0, -C.NUDGE_MAX, C.NUDGE_MAX)
end

function C.NudgeY()
    return C.Number("nudgeY", 0, -C.NUDGE_MAX, C.NUDGE_MAX)
end

-- Percent, so the slider reads the way a player expects.
function C.CenterScale()
    return C.Number("centerScale", C.CENTER_DEFAULT, C.CENTER_MIN, C.CENTER_MAX) / 100
end

function C.CenterY()
    return tonumber(C.Get("centerY")) or C.CENTER_Y_DEFAULT
end

function C.LabelScale()
    return C.Number("labelScale", C.LABEL_DEFAULT, C.LABEL_MIN, C.LABEL_MAX) / 100
end

function C.TimeScale()
    return C.Number("timeScale", C.TIME_DEFAULT, C.TIME_MIN, C.TIME_MAX) / 100
end

-- Only the words. The block's own scale moves the icon and the countdown with
-- them, so this is for a player who wants the call readable from further away
-- without a bigger block.
function C.CenterTextScale()
    return C.Number("centerTextScale", C.CENTER_TEXT_DEFAULT,
        C.CENTER_TEXT_MIN, C.CENTER_TEXT_MAX) / 100
end

-- Short by default. Measured on real rows: with the long verdicts spelled
-- out, three icons stretched across the whole nameplate and the spacing
-- depended on which verdict happened to come up; short, the widest word on a
-- plate is six characters and every row packs the same. The whole word is
-- still spoken and still shown in the cast table, so nothing is lost - but
-- the switch is there for anyone who wants it on the icons too.
function C.ShortLabels()
    return C.Get("fullLabels") ~= true
end

function C.CenterText()
    return C.Get("centerText") ~= false
end

function C.Set(key, value)
    CastAheadDB = CastAheadDB or {}
    CastAheadDB[key] = value
end

function C.Enabled(key)
    return C.Get(key) ~= false
end

function C.Dev()
    return C.Get("devMode") == true
end

function C.DungeonSaves()
    return C.Get("saveCalls") == true
end

function C.RaidSaves()
    return C.Get("raidMode") == true and C.Get("raidSaves") == true
end

function C.BurstCalls()
    return C.Get("raidMode") == true and C.Get("burstCalls") == true
end

function C.SaveCalls()
    if GetInstanceInfo and select(2, GetInstanceInfo()) == "raid" then return C.RaidSaves() end
    return C.DungeonSaves()
end

function C.Recording()
    return C.Dev() and C.Enabled("recordAll")
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
C.SAVE_LEAD_MAX = 10

function C.SaveLead()
    return C.Number("saveLeadSeconds", 0, 0, C.SAVE_LEAD_MAX)
end

C.BURST_LEAD_MAX = 10

-- Seconds of "burst soon" before a burst window; 0 leaves only "burst now".
function C.BurstLead()
    return C.Number("burstLeadSeconds", 0, 0, C.BURST_LEAD_MAX)
end

function C.Lead()
    local seconds = tonumber(C.Get("leadSeconds"))
    if not seconds then return C.LEAD_DEFAULT end
    if seconds < 0 then return 0 end
    if seconds > C.LEAD_MAX then return C.LEAD_MAX end
    return seconds
end

-- A cast's own early warning (Casts page) wins over the global one, even when
-- the global one is off. With several candidates the longest wins, so none of
-- them is announced late.
function C.SpellLead(spellID)
    local own = CastAheadDB and CastAheadDB.spellLead and tonumber(CastAheadDB.spellLead[spellID])
    return own and math.max(0, math.min(C.LEAD_MAX, own)) or nil
end

-- The player's own star for a cast: true or false when set on the Casts page,
-- nil to follow the curated set.
function C.SpellImportant(spellID)
    local own = CastAheadDB and CastAheadDB.spellImportant and CastAheadDB.spellImportant[spellID]
    if own == nil then return nil end
    return own == true
end

function C.SpellMuted(spellID)
    return CastAheadDB and CastAheadDB.spellMute and CastAheadDB.spellMute[spellID] == true or false
end

-- A bar is silent only when every spell it may be is muted.
function C.AllMuted(candidates)
    if not candidates or #candidates == 0 then return false end
    for _, row in ipairs(candidates) do
        if not C.SpellMuted(row.spell) then return false end
    end
    return true
end

function C.LeadFor(candidates)
    local global = C.Lead()
    if not candidates or #candidates == 0 then return global end
    local best = 0
    for _, row in ipairs(candidates) do
        best = math.max(best, C.SpellLead(row.spell) or global)
    end
    return best
end

-- Run once, the moment the saved variables arrive: by PLAYER_LOGIN the
-- minimap icon has already created the table, and a fresh install would
-- read as an old profile. Older profile shapes exist and each would
-- otherwise read as a reset: the per-context one (CastAheadDB.ctx.key), the
-- flat one from before the early warning became a number.
C.SCHEMA = 6

function C.Migrate()
    local existing = CastAheadDB ~= nil
    -- A new install has nothing to be told about what changed.
    C.newInstall = not existing
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
    for _, field in ipairs({ "sounds", "spellSounds" }) do
        local picks = CastAheadDB[field]
        for key, name in pairs(type(picks) == "table" and picks or {}) do
            if type(name) == "string" and name:sub(1, 12) == "Cast Ahead: " then
                picks[key] = "CastAhead: " .. name:sub(13)
            end
        end
    end
    for _, picks in pairs(type(CastAheadDB.saveButtons) == "table" and CastAheadDB.saveButtons or {}) do
        for size, value in pairs(type(picks) == "table" and picks or {}) do
            if type(value) == "number" then picks[size] = { value } end
        end
    end
    if existing and (tonumber(CastAheadDB.schema) or 0) < 3 and CastAheadDB.saveCalls == nil then
        CastAheadDB.saveCalls = true
    end
    if existing and (tonumber(CastAheadDB.schema) or 0) < 4 then
        local function same(a, b)
            if type(a) == "table" and type(b) == "table" then return a.use == b.use end
            return a == b
        end
        local function append(joined, list)
            for _, entry in ipairs(type(list) == "table" and list or {}) do
                local seen = false
                for _, have in ipairs(joined) do
                    if same(have, entry) then seen = true break end
                end
                if not seen then joined[#joined + 1] = entry end
            end
        end
        for spec, picks in pairs(type(CastAheadDB.saveButtons) == "table" and CastAheadDB.saveButtons or {}) do
            if type(picks) == "table" then
                local big, small = type(picks.big) == "table", type(picks.small) == "table"
                if type(picks.def) ~= "table" and (big or small) then
                    local joined = {}
                    append(joined, picks.small)
                    append(joined, picks.big)
                    if big and small then
                        picks.def = joined
                    elseif #joined > 0 then
                        local shipped = CastAheadSaveButtons and CastAheadSaveButtons[spec]
                        append(joined, shipped and shipped.def)
                        picks.def = joined
                    end
                end
                picks.small, picks.big, picks.heal = nil, nil, nil
            end
        end
        if CastAheadDB.smallCalls == false and CastAheadDB.bigCalls == false then
            CastAheadDB.saveCalls = false
        end
        CastAheadDB.smallCalls, CastAheadDB.bigCalls, CastAheadDB.healCalls = nil, nil, nil
        for _, field in ipairs({ "sounds", "spellSounds" }) do
            local picks = CastAheadDB[field]
            for key, name in pairs(type(picks) == "table" and picks or {}) do
                if name == "CastAhead: small defensive" or name == "CastAhead: big defensive" then
                    picks[key] = "CastAhead: defensive"
                elseif name == "CastAhead: heal up" then
                    picks[key] = nil
                end
            end
        end
        local sounds = CastAheadDB.sounds
        if type(sounds) == "table" then
            if sounds.DEFENSIVE == nil then sounds.DEFENSIVE = sounds.BIG or sounds.SMALL end
            sounds.SMALL, sounds.BIG, sounds.HEAL = nil, nil, nil
        end
    end
    if existing and (tonumber(CastAheadDB.schema) or 0) < 5 then
        for _, key in ipairs({ "saveCalls", "raidSaves" }) do
            if CastAheadDB[key] == true then
                CastAheadDB[key] = false
                CastAheadDB.saveCallsNotice = true
            end
        end
    end
    if existing and (tonumber(CastAheadDB.schema) or 0) < 6
            and (CastAheadDB.burstCalls == true or CastAheadDB.raidSaves == true) then
        CastAheadDB.raidMode = true
    end
    CastAheadDB.schema = C.SCHEMA
end

local RECORDED = { "journal", "probe", "phaseProbe", "sweep", "fingerprints", "diag", "combatLogOurs", "dispel" }

-- Every setting back to a new install; recorded data stays until the
-- Development tab clears it.
function C.ResetAll()
    local fresh = { schema = C.SCHEMA }
    for _, key in ipairs(RECORDED) do fresh[key] = CastAheadDB and CastAheadDB[key] end
    CastAheadDB = fresh
end
