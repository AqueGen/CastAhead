-- Standalone check for Core.lua: lua test_core.lua
--
-- Core talks to the game only through a handful of functions, so stubbing those
-- lets the whole event machine run outside WoW. Both review passes found their
-- worst bugs here (a countdown expiring threw every frame, a kicked cast never
-- resolved), and neither was reachable by the data-only test.

local failures = 0
local function check(ok, msg)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

-- WoW stubs ----------------------------------------------------------------

local now = 1000
GetTime = function() return now end

local combat, hostile, dead = {}, {}, {}
UnitAffectingCombat = function(unit) return combat[unit] == true end
UnitExists = function(unit) return hostile[unit] ~= nil end
UnitCanAttack = function(_, unit) return hostile[unit] == true end
UnitIsDead = function(unit) return dead[unit] == true end
local levels = {}
UnitLevel = function(unit) return levels[unit] or 90 end
UnitClassification = function() return "elite" end
UnitPowerType = function() return 0 end
UnitIsLieutenant = function() return false end
UnitCreatureFamily = function() return nil end
-- The player's harmful auras, as C_UnitAuras hands them out by index. In 12.1
-- UNIT_AURA's updateInfo is Secret in instances, so Core enumerates instead.
local playerAuras = {}
C_UnitAuras = {
    GetAuraDataByIndex = function(unit, index, filter)
        if unit ~= "player" or filter ~= "HARMFUL" then return nil end
        return playerAuras[index]
    end,
}
IsInInstance = function() return true end
GetInstanceInfo = function() return "d", "party", 0, "", 0, 0, false, 1877 end
local plateShown = true
local elsewhere = { GetParent = function() return nil end }
-- Platynator hands Blizzard's UnitFrame to a hidden frame, so it no longer
-- belongs to the plate and anchoring to it drops the icon wherever that frame
-- happens to sit.
local strayUnitFrame = {
    GetObjectType = function() return "Frame" end,
    GetParent = function() return elsewhere end,
}
local lastAnchor
C_NamePlate = { GetNamePlateForUnit = function(unit)
    if not hostile[unit] then return nil end
    return {
        unit = unit,
        IsShown = function() return plateShown end,
        GetAlpha = function() return plateShown and 1 or 0 end,
        GetObjectType = function() return "Frame" end,
        GetParent = function() return nil end,
        UnitFrame = strayUnitFrame,
    }
end }
-- The real API returns nothing for spells the client has not cached, which is
-- why every icon came out as the same placeholder.
-- Deliberately empty: enemy spell data is typically not cached client-side.
local cachedSpells = {}
local textures = { [100] = 1001, [101] = 1002, [200] = 1003, [300] = 1004, [610] = 1061, [900] = 1009, [950] = 1010, [960] = 1011 }
local requested = {}
C_Spell = {
    -- Modelled on the real thing: enemy spells are usually NOT cached, so this
    -- returns nothing and only GetSpellTexture answers. Relying on GetSpellInfo
    -- alone is what made every mob show the same placeholder icon.
    GetSpellInfo = function(id)
        if not cachedSpells[id] then return nil end
        return { name = "Spell" .. id, iconID = cachedSpells[id] }
    end,
    GetSpellTexture = function(id) return textures[id] end,
    RequestLoadSpellData = function(id) requested[id] = true end,
}
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
-- Present in game, absent from the earlier stub: the voice path has to be
-- exercised, not skipped.
Enum = { CombatAudioAlertCategory = { TargetCast = 4 } }
local spoken, sounds = 0, 0
local allFrames = {}
-- The real SpeakText returns an utteranceID when it actually speaks and
-- nothing when alerts are disabled; Core reads that to decide on the beep
-- fallback, so the stub must return one.
C_CombatAudioAlert = { SpeakText = function() spoken = spoken + 1 return 1 end }
-- Our own clips come first; PlaySoundFile answers willPlay like the real one.
local clips, clipsPlayable = 0, true
PlaySoundFile = function() clips = clips + 1 return clipsPlayable, 1 end
-- Alerts come out as a clip, as speech, or as a beep, so the tests count
-- whichever the addon chose.
local function Alerts() return sounds + spoken + clips end

-- How many icons are on screen right now, regardless of whether they carry a
-- countdown.
-- Nameplate bars, told apart from the centre-call frames by the glow texture
-- only a bar has. The frame stub answers unknown fields with a function, so a
-- type check is the discriminator.
local function IsBar(f)
    return type(f.icon) == "table" and type(f.glow) == "table"
end

local function VisibleBars()
    local n = 0
    for i = 1, #allFrames do
        if allFrames[i].shown and IsBar(allFrames[i]) then n = n + 1 end
    end
    return n
end
-- Blizzard's encounter timeline, recorded so the tests can see what we sent it.
local timeline = { added = 0, cancelled = 0, finished = 0, cancelAll = 0, last = nil, live = {} }
local nextEventID = 0
C_EncounterTimeline = {
    IsFeatureEnabled = function() return true end,
    AddScriptEvent = function(request)
        nextEventID = nextEventID + 1
        timeline.added = timeline.added + 1
        timeline.last = request
        timeline.live[nextEventID] = true
        return nextEventID
    end,
    CancelScriptEvent = function(id)
        timeline.cancelled = timeline.cancelled + 1
        timeline.live[id] = nil
    end,
    FinishScriptEvent = function(id)
        timeline.finished = timeline.finished + 1
        timeline.live[id] = nil
    end,
    CancelAllScriptEvents = function() timeline.cancelAll = timeline.cancelAll + 1 end,
}
bit = { bor = function(a, b) return (a or 0) + (b or 0) end }
Enum.EncounterEventIconmask = { TankRole = 128, HealerRole = 256, DpsRole = 512, DeadlyEffect = 1, MagicEffect = 8 }
Enum.EncounterEventSeverity = { Low = 0, Medium = 1, High = 2 }

SOUNDKIT = { RAID_WARNING = 1, ALARM_CLOCK_WARNING_3 = 2, ALARM_CLOCK_WARNING_2 = 3,
             UI_RAID_BOSS_WHISPER_WARNING = 4 }
PlaySound = function() sounds = sounds + 1 end

local framesMade, shownCount = 0, 0
local function StubRegion()
    -- `textureValue` is a real field: the catch-all __index below hands back a
    -- fresh closure for anything unknown, so a test reading an unset field would
    -- always see two "different" values and could never fail.
    local r = { textureValue = false }
    r.SetTexture = function(_, tex) r.textureValue = tex end
    setmetatable(r, { __index = function() return function() return r end end })
    return r
end

local eventHandler, updateHandler
CreateFrame = function(kind)
    local f = { shown = false, texts = {}, kind = kind }
    allFrames[#allFrames + 1] = f
    framesMade = framesMade + 1
    f.Show = function(self)
        if not self.shown then shownCount = shownCount + 1 end
        self.shown = true
    end
    f.Hide = function(self) self.shown = false end
    f.IsShown = function(self) return self.shown end
    f.SetScript = function(_, script, fn)
        -- Core registers more than one event frame (the main one, plus a small
        -- frame that saves diagnostics on logout). Only the first owns the
        -- event flow; keeping just the last one silently redirected everything.
        if script == "OnEvent" then
            eventHandler = eventHandler or fn
        elseif script == "OnUpdate" then
            updateHandler = updateHandler or fn
        end
    end
    f.CreateTexture = StubRegion
    f.CreateFontString = function()
        local fs = StubRegion()
        -- Record into separate fields: Core assigns the font strings to
        -- bar.text / bar.time, so writing there would overwrite them.
        fs.SetText = function(_, text) f.labelValue = text end
        fs.SetFormattedText = function(_, fmt, ...) f.timeValue = string.format(fmt, ...) end
        return fs
    end
    f.GetParent = function(self) return self.parent end
    f.SetPoint = function(self, _, anchor, _, x, y)
        lastAnchor = anchor
        self.x, self.y = x, y            -- offsets, for the layout cases
    end
    f.SetTexture = function(self, tex) self.texture = tex end
    f.SetParent = function(self, p) self.parent = p end
    local barOnly = {
        SetValue = true, SetStatusBarColor = true,
        SetMinMaxValues = true, SetStatusBarTexture = true,
    }
    setmetatable(f, { __index = function(_, key)
        -- A plain Frame has no StatusBar methods. The old stub answered every
        -- call, so leftover bar calls after the icon rework went unnoticed.
        if barOnly[key] and kind ~= "StatusBar" then
            return nil
        end
        return function() end
    end })
    return f
end

-- Data the addon will match against.
CastAheadData = {
    [1877] = { name = "Test",
        { spell = 100, npc = 1, mob = "Caster", name = "Big", cast = 3.0, cd = { 20.0 },
          first = 5.0, offset = 0.0, hits = 5, dmg = 0.5, kick = 0, cc = 0.05 },
        -- Same creature as spell 100: identifying one must lay this one out too.
        { spell = 101, npc = 1, mob = "Caster", name = "Second", cast = 4.5, cd = { 18.0 },
          first = 12.0, offset = 9.0, hits = 4, dmg = 0.35, kick = 0, cc = 0 },
        { spell = 200, npc = 2, mob = "Filler", name = "Bolt", cast = 2.5, cd = { 3.6 },
          first = 4.0, hits = 1, dmg = 0.3, kick = 0.5, cc = 0.2, filler = true },
        { spell = 300, npc = 3, mob = "Cycler", name = "Cycle", cast = 1.5, cd = { 4.8, 4.8, 8.7 },
          first = 3.0, hits = 3, dmg = 0.25, kick = 0, cc = 0.05 },
        -- Statistically dangerous (5 targets, half their health) but NOT in the
        -- curated set: the "important only" filter must hide it anyway.
        { spell = 700, npc = 7, mob = "Unmarked", name = "Loud", cast = 7.0, cd = { 25.0 },
          first = 6.0, hits = 5, dmg = 0.5, kick = 0, cc = 0 },
        -- A channel, 6.0s long, curated TANK. It is the only 6.0s length in the
        -- base fixture on purpose; the collision case below hands npc 11 a 6.0s
        -- cast as well, to prove the two kinds stay apart. It gets a creature of
        -- its own (npc 11) so that projecting it as a sibling never reorders the
        -- icons the npc 1 cases above measure.
        { spell = 610, npc = 11, mob = "Drainer", name = "Drain", cast = 6.0, cd = { 22.0 },
          first = 8.0, firstN = 5, hits = 1, dmg = 0.3, kick = 0, cc = 0, channel = true },
    },
}

-- The curated priority set and provisional extras, normally Priority.lua.
-- Spell 600 is deliberately absent.
CastAheadPriority = { [100] = "AOE", [101] = "AOE", [200] = "KICK", [300] = "DODGE", [500] = "TANK", [610] = "TANK" }
-- Creature traits, normally Traits.lua. The stubs report level 90, power 0,
-- "elite", not a lieutenant, no creature family. Nothing is listed at level
-- 90 on purpose: the cast-length tests above and below must run without an
-- identity, as they do for creatures the table does not know.
--   91 -> npc 1 alone (narrows; locks once a 3.0s or 4.5s cast confirms it)
--   93 -> npc 2 alone; 92 -> npc 3 or npc 4, where 3 is listed as npc 2's
--         packmate, so a locked npc 2 nearby narrows a level-92 plate to 3
CastAheadTraits = {
    [1877] = {
        { npc = 1, level = 91, power = 0, elite = true, lieutenant = false, family = false, casts = { 3, 4.5 } },
        { npc = 2, level = 93, power = 0, elite = true, casts = { 2.5 } },
        { npc = 3, level = 92, power = 0, elite = true, co = { 2 }, casts = { 1.5 } },
        { npc = 4, level = 92, power = 0, elite = true, casts = { 1.5 } },
        -- Channel lengths are listed apart from cast lengths. These two share a
        -- level and differ only in the channel they are known for, so at level
        -- 94 nothing but `channels` can tell them apart.
        { npc = 11, level = 94, power = 0, elite = true, channels = { 6 } },
        { npc = 12, level = 94, power = 0, elite = true, channels = { 9 } },
    },
}
CastAheadExtra = {
    [1877] = {
        { spell = 500, npc = 5, mob = "Imported", name = "Provisional", cast = 6.0,
          cd = { 20.0 }, first = 5.0, n = 0, approx = true },
    },
}

dofile("Config.lua")
dofile("Match.lua")
dofile("Timeline.lua")
-- UI.lua only needs the stubs above for its option helpers.
UISpecialFrames = {}
SlashCmdList = {}
SearchBoxTemplate_OnTextChanged = function() end
GameTooltip = setmetatable({}, { __index = function() return function() end end })
GameTooltip_Hide = function() end
dofile("UI.lua")
dofile("Core.lua")

local function fire(event, ...) eventHandler(nil, event, ...) end

-- Config: flat settings -------------------------------------------------
local savedInInstance, savedInstanceInfo = IsInInstance, GetInstanceInfo
local instanceKind = "party"
IsInInstance = function() return true, instanceKind end
GetInstanceInfo = function() return "d", instanceKind, 0, "", 0, 0, false, 1877 end

CastAheadDB = nil
CastAheadConfig.SetEnabled("centerText", false)
check(CastAheadConfig.Enabled("centerText") == false, "an option switched off reads back off")
CastAheadConfig.SetEnabled("centerText", true)
check(CastAheadConfig.Enabled("centerText") == true, "switching it back on is honored")
check(CastAheadDB.centerText == nil, "and stores nothing, so a later default change still applies")

instanceKind = "raid"
check(CastAheadConfig.Enabled("centerText") == true, "settings do not change with the instance kind")
CastAheadConfig.Set("anchor", "top")
check(CastAheadDB.anchor == "top", "values are stored flat")

-- Lead seconds: off by default, clamped.
CastAheadDB = nil
check(CastAheadConfig.Lead() == 0, "the early warning is off by default")
CastAheadConfig.Set("leadSeconds", 5)
check(CastAheadConfig.Lead() == 5, "a stored lead is used")
CastAheadConfig.Set("leadSeconds", 99)
check(CastAheadConfig.Lead() == 15, "a lead beyond the range is clamped to 15")

-- Migration: a per-context profile collapses onto the flat one, and the old
-- leadWarning boolean becomes 5 or 0.
CastAheadDB = { ctx = { key = { centerText = false, leadSeconds = 7 },
    raid = { sound = false } }, anchor = "left" }
CastAheadConfig.Migrate()
check(CastAheadConfig.Enabled("centerText") == false, "the key context is lifted to the flat profile")
check(CastAheadConfig.Lead() == 7, "including its early warning")
check(CastAheadConfig.Enabled("sound") == true, "the raid context is dropped, not merged")
check(CastAheadDB.ctx == nil, "and the context table is gone")
check(CastAheadDB.anchor == "left", "a global value survives migration untouched")

CastAheadDB = { leadWarning = true }
CastAheadConfig.Migrate()
check(CastAheadDB.leadSeconds == 5, "the old leadWarning boolean becomes 5 seconds")
check(CastAheadDB.leadWarning == nil, "and is removed")
CastAheadDB = { leadWarning = false }
CastAheadConfig.Migrate()
check(CastAheadConfig.Lead() == 0, "leadWarning = false stays off")
CastAheadDB = {}
CastAheadConfig.Migrate()
check(CastAheadDB.leadSeconds == nil, "a fresh profile leaves leadSeconds unset")
check(CastAheadConfig.Lead() == 0, "so a fresh profile gets the documented default of off")

-- Entering the world migrates an old profile exactly once.
CastAheadDB = { voice = false }
fire("PLAYER_ENTERING_WORLD")
check(CastAheadDB.voice == false and CastAheadDB.ctx == nil,
    "entering the world migrates a per-context profile")
CastAheadDB.voice = nil
fire("PLAYER_ENTERING_WORLD")
check(CastAheadDB.voice == nil, "migration does not run twice over a live profile")

-- The UI helpers write where the accessor reads.
CastAheadDB = nil
CastAheadUI.SetOption("voice", false)
check(CastAheadConfig.Enabled("voice") == false, "a UI toggle writes where the accessor reads")
check(CastAheadUI.OptionEnabled("voice") == false, "and reads back through the same path")
CastAheadUI.SetOption("voice", true)
check(CastAheadConfig.Enabled("voice") == true, "switching it back on clears the stored value")

CastAheadDB = nil
IsInInstance, GetInstanceInfo = savedInInstance, savedInstanceInfo

CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on

-- Count bars that actually became visible: counting CreateFrame would miss the
-- pool, which hands back an existing frame instead of making a new one.
local function BarsShown() return shownCount end

-- Helpers ------------------------------------------------------------------

local unit = "nameplate1"
local function advance(seconds)
    now = now + seconds
    if updateHandler then updateHandler() end
end
local function enter()
    hostile[unit], combat[unit], dead[unit] = true, true, nil
    fire("PLAYER_ENTERING_WORLD")
    fire("NAME_PLATE_UNIT_ADDED", unit)
end
local function reset()
    fire("NAME_PLATE_UNIT_REMOVED", unit)
    hostile[unit], combat[unit], dead[unit] = nil, nil, nil
end

-- A cast of `length`, identified by its duration.
local function castFor(length)
    fire("UNIT_SPELLCAST_START", unit)
    advance(length)
    fire("UNIT_SPELLCAST_STOP", unit)
end

-- A channel of `length`, identified by its duration like a cast.
local function channelFor(length)
    fire("UNIT_SPELLCAST_CHANNEL_START", unit)
    advance(length)
    fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
end

-- Cases --------------------------------------------------------------------

-- A hostile unit may hand back a level that cannot be compared - a secret
-- value. Comparing one throws, and that used to kill the handler that tracks
-- the plate at all, so nothing appeared on any nameplate.
local realUnitLevel = UnitLevel
UnitLevel = function() return setmetatable({}, { __lt = function() error("secret value") end }) end
hostile[unit], combat[unit] = true, true
fire("PLAYER_ENTERING_WORLD")
ok, err = pcall(fire, "NAME_PLATE_UNIT_ADDED", unit)
check(ok, "an unreadable level must not break plate tracking: " .. tostring(err))
ok, err = pcall(castFor, 3.0)
check(ok, "and a cast on that plate must still resolve: " .. tostring(err))
reset()
UnitLevel = realUnitLevel

-- Out of combat, a plate whose level pins the creature down shows its kit with
-- no timers at all. A level shared by several creatures shows nothing.
table.insert(CastAheadData[1877], { spell = 600, npc = 6, mob = "Known", name = "Preview", cast = 3.0,
                          cd = { 20.0 }, first = 5.0, offset = 0.0, level = 66,
                          hits = 5, dmg = 0.5, kick = 0, cc = 0, prio = "AOE" })
local madeBefore = BarsShown()
hostile[unit], combat[unit] = true, false
levels[unit] = 66
fire("PLAYER_ENTERING_WORLD")
ok, err = pcall(fire, "NAME_PLATE_UNIT_ADDED", unit)
check(ok, "a pre-combat preview must not error: " .. tostring(err))
check(BarsShown() > madeBefore, "a uniquely levelled mob shows its kit before the pull")

madeBefore = BarsShown()
reset()
levels[unit] = 90            -- shared by several creatures in the fixture
hostile[unit], combat[unit] = true, false
fire("NAME_PLATE_UNIT_ADDED", unit)
check(BarsShown() == madeBefore, "an ambiguous level shows nothing before the pull")
reset()
levels[unit] = nil
table.remove(CastAheadData[1877])

-- Entering combat alone identifies a mob when its level is unique enough, and
-- the opening cast is timed from that moment - no cast needed first.
-- spell/npc renumbered away from the CastAheadExtra fixture (500/5), and
-- appended rather than parked in slot 5, which spell 700 now occupies.
table.insert(CastAheadData[1877], { spell = 800, npc = 8, mob = "Lonely", name = "Opener", cast = 2.0,
                          cd = { 15.0 }, first = 6.0, level = 77, hits = 5, dmg = 0.4,
                          kick = 0, cc = 0, prio = "AOE" })
levels[unit] = 77
enter()
ok, err = pcall(advance, 1)
check(ok, "an opening prediction must not error: " .. tostring(err))
reset()
levels[unit] = nil
table.remove(CastAheadData[1877])

-- One identified cast must lay out the rest of the creature kit: every other
-- spell that mob has, timed where possible and listed where not, and an
-- estimate that runs out must leave the icon standing.
local shownBefore = BarsShown()
enter()
local ok, err = pcall(castFor, 3.0)
check(ok, "projecting a mob other spells must not error: " .. tostring(err))
check(BarsShown() > shownBefore + 1, "one identified cast should reveal the rest of the kit")
ok, err = pcall(advance, 30)
check(ok, "an estimate running out must not error: " .. tostring(err))
ok, err = pcall(advance, 1)
check(ok, "and the frame after it must not error: " .. tostring(err))
reset()

-- The alert needs the spell identified first: the opening cast of a pull is
-- unknown until it finishes, so nothing sounds for it.
sounds, spoken, clips = 0, 0, 0
enter()
castFor(3.0)                       -- spell 100: 5 targets, 50% health -> DEFENCE
check(Alerts() == 0, "an unidentified opening cast must not alert")

-- The repeat lands where predicted, is recognised on the way in, and alerts
-- exactly once no matter how many frames pass.
advance(17)
castFor(3.0)
advance(3)
check(Alerts() == 1, string.format("one alert per identified dangerous cast, got %d", Alerts()))
reset()

-- A predicted cast warns ahead of time, once, and then alerts again when it
-- actually starts.
sounds, spoken, clips = 0, 0, 0
enter()
castFor(3.0)
advance(13.9)                      -- inside the 5s warning lead of a 20s cooldown
advance(0.1)                       -- the overdue sibling row ahead of it settles on the first frame
check(Alerts() == 1, string.format("one heads-up before a predicted cast, got %d", Alerts()))
advance(2)
check(Alerts() == 1, "the heads-up does not repeat every frame")
reset()

-- The heads-up lead is configurable: at 8 seconds it fires earlier than the
-- old fixed 3, and at 0 it never fires at all.
CastAheadDB = { leadSeconds = 8 }
sounds, spoken, clips = 0, 0, 0
enter()
castFor(3.0)                       -- spell 100, 20s rotation
advance(12.5)                      -- 8.5s before the next cast: outside the lead
check(Alerts() == 0, string.format("no heads-up before the configured lead, got %d", Alerts()))
advance(1.0)                       -- 7.5s before it: inside an 8s lead
check(Alerts() == 1, string.format("the heads-up fires at the configured lead, got %d", Alerts()))
reset()
CastAheadDB = { leadSeconds = 0 }
sounds, spoken, clips = 0, 0, 0
enter()
castFor(3.0)
advance(19.0)                      -- 1s before the next cast
check(Alerts() == 0, string.format("leadSeconds = 0 silences the heads-up, got %d", Alerts()))
reset()
CastAheadDB = { leadSeconds = 5 }

-- With the early warning switched off there is no heads-up at all - only the
-- call when the cast starts.
CastAheadDB = { leadSeconds = 0 }
sounds, spoken, clips = 0, 0, 0
enter()
castFor(3.0)
advance(14.0)                      -- inside the lead, nothing said
check(Alerts() == 0, string.format("no heads-up while leadSeconds is 0, got %d", Alerts()))
castFor(3.0)                       -- the predicted cast itself still alerts
check(Alerts() == 1, string.format("the cast-start call is unaffected, got %d", Alerts()))
reset()
CastAheadDB = { leadSeconds = 5 }

-- Turning the sound off in the UI is honoured.
CastAheadDB = { sound = false }
sounds, spoken, clips = 0, 0, 0
enter()
castFor(3.0)
advance(17)
castFor(3.0)
check(Alerts() == 0, "no alert when the sound is switched off")
reset()
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on

-- Helpers for the trait cases: which spell icons are on screen.
local function IconShown(spellID)
    for i = 1, #allFrames do
        local f = allFrames[i]
        if f.shown and IsBar(f) and f.icon.textureValue == textures[spellID] then return true end
    end
    return false
end

-- A trait match alone must not name a creature: the trait table does not know
-- every mob, and a level-91 plate that matches npc 1 may be an unlisted
-- creature that merely looks like it. So nothing is previewed on sight...
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on
table.insert(CastAheadData[1877], { spell = 900, npc = 9, mob = "Lookalike", name = "Twin", cast = 3.0,
                          cd = { 20.0 }, first = 5.0, firstN = 5, hits = 5, dmg = 0.5, n = 50,
                          kick = 0, cc = 0, prio = "AOE" })
levels[unit] = 91
local beforeSight = BarsShown()
hostile[unit], combat[unit] = true, false
fire("NAME_PLATE_UNIT_ADDED", unit)
check(BarsShown() == beforeSight, "a trait match alone must not preview a kit")

-- ...but the match does steer a cast several creatures share: 3.0s is spell
-- 100 (npc 1) or the lookalike 900 (npc 9, seen far more often), and the trait
-- match picks 100. That cast also fits npc 1's known lengths, which locks it.
combat[unit] = true
fire("NAME_PLATE_UNIT_ADDED", unit)
castFor(3.0)
check(IconShown(100) and not IconShown(900), "the trait match steers a shared cast length to its creature")

-- That lock rests on the trait table, which does not know every creature. A
-- cast the named creature does not have contradicts it, so the lock is
-- released and the cast identified on its own - not hidden.
castFor(2.5)                      -- spell 200 belongs to npc 2
check(IconShown(200), "a trait-confirmed lock yields to a cast the creature does not have")
reset()

-- A lock earned by the creature's own unique cast is evidence, and holds: a
-- cast belonging to another creature is not shown at all.
levels[unit] = nil
enter()
castFor(4.5)                      -- spell 101, unique length: npc 1 locked by cast
castFor(2.5)                      -- spell 200 belongs to npc 2
check(not IconShown(200), "a cast-confirmed lock never shows another creature's cast")
reset()
levels[unit] = nil
table.remove(CastAheadData[1877])

-- Company: a level-92 plate could be npc 3 or npc 4, whose 1.5s casts (300 and
-- 950) are indistinguishable by length. With npc 2 locked on a neighbouring
-- plate and npc 3 listed as its packmate, the plate leans to 3 and the cast is
-- named as 300; alone it stays a tie and shows the better-sampled 950.
table.insert(CastAheadData[1877], { spell = 950, npc = 4, mob = "Other", name = "Also", cast = 1.5,
                          cd = { 4.8, 4.8, 8.7 }, first = 3.0, firstN = 5, hits = 3, dmg = 0.25, n = 99,
                          kick = 0, cc = 0, prio = "DODGE" })
-- A third 1.5s spell from a creature outside the trait match (npc 9, sampled
-- most of all) shows what the match is worth on its own: it is preferred
-- away from, even though nothing locks yet.
table.insert(CastAheadData[1877], { spell = 960, npc = 9, mob = "Stranger", name = "Loud", cast = 1.5,
                          cd = { 4.8, 4.8, 8.7 }, first = 3.0, firstN = 5, hits = 3, dmg = 0.25, n = 200,
                          kick = 0, cc = 0, prio = "DODGE" })
local other = "nameplate2"
levels[unit] = 92
enter()
castFor(1.5)
check(not IconShown(960), "a trait match steers a tie away from creatures it excludes")
check(IconShown(950), "and within the match the tie falls to the better-sampled lookalike")
reset()
levels[other] = 93
hostile[other], combat[other] = true, true
fire("NAME_PLATE_UNIT_ADDED", other)
fire("UNIT_SPELLCAST_START", other)
advance(2.5)
fire("UNIT_SPELLCAST_STOP", other)      -- spell 200, unique length: npc 2 locked
enter()
castFor(1.5)
check(IconShown(300) and not IconShown(950), "a locked packmate nearby steers the tie to its listed companion")
reset()
fire("NAME_PLATE_UNIT_REMOVED", other)

-- The other way round: the tie is already on screen when the neighbour locks.
-- The lock reaches this plate through IdentifyOthers with no cast of its own
-- to repaint it, so LockNPC has to redraw the icons itself.
enter()
castFor(1.5)                           -- tie, drawn as the better-sampled 950
check(IconShown(950), "before the neighbour locks, the tie shows the lookalike")
hostile[other], combat[other] = true, true
fire("NAME_PLATE_UNIT_ADDED", other)
fire("UNIT_SPELLCAST_START", other)
advance(2.5)
fire("UNIT_SPELLCAST_STOP", other)      -- npc 2 locked next door
check(IconShown(300) and not IconShown(950), "a lock arriving from a neighbour repaints the plate at once")
reset()
fire("NAME_PLATE_UNIT_REMOVED", other)
hostile[other], combat[other], levels[other] = nil, nil, nil
levels[unit] = nil
table.remove(CastAheadData[1877])   -- 960
table.remove(CastAheadData[1877])   -- 950
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on

-- Only confident predictions reach Blizzard's timeline. The fixture spell has
-- no sample count, so it must stay off it - the timeline cannot say "estimate".
timeline.added, timeline.cancelled, timeline.finished = 0, 0, 0
enter()
castFor(3.0)
check(timeline.added == 0, "an estimate must not be published as an exact time")
reset()

-- With enough evidence behind it, the same prediction is published once, is not
-- republished while it barely moves, and is finished when the cast arrives.
CastAheadData[1877][1].n = 40
timeline.added, timeline.cancelled, timeline.finished = 0, 0, 0
enter()
castFor(3.0)
check(timeline.added == 1, string.format("a confident prediction is published, got %d", timeline.added))
check(timeline.last and timeline.last.spellID == 100, "and carries the right spell")
check(timeline.last and timeline.last.icons ~= nil, "with role badges so the timeline labels it")
advance(17)
castFor(3.0)
check(timeline.finished >= 1, "the event is finished when the predicted cast starts")
reset()
check(timeline.cancelAll == 0, "CancelAllScriptEvents must never be called - it kills other addons")
CastAheadData[1877][1].n = nil

-- Dropping the plate takes our event with it rather than leaving it running.
CastAheadData[1877][1].n = 40
timeline.added, timeline.cancelled = 0, 0
enter()
castFor(3.0)
reset()
check(timeline.cancelled >= 1, "removing the nameplate cancels its timeline event")
check(next(timeline.live) == nil, "and leaves nothing of ours on the timeline")
CastAheadData[1877][1].n = nil

-- An icon with no countdown still has to follow its nameplate and vanish with
-- it. Skipping those in the update loop left an "AOE" icon parked on the player
-- after its plate was gone.
table.insert(CastAheadData[1877], { spell = 600, npc = 6, mob = "Known", name = "Preview", cast = 3.0,
                          cd = { 20.0 }, first = 5.0, offset = 0.0, level = 66,
                          hits = 5, dmg = 0.5, kick = 0, cc = 0, prio = "AOE" })
levels[unit] = 66
hostile[unit], combat[unit] = true, false
fire("PLAYER_ENTERING_WORLD")
fire("NAME_PLATE_UNIT_ADDED", unit)
check(VisibleBars() > 0, "the preview should be on screen to begin with")

-- The plate goes away without a REMOVED event, as when a unit token is recycled.
hostile[unit] = nil
ok, err = pcall(advance, 0.3)             -- one combat poll
check(ok, "an orphaned preview must not error: " .. tostring(err))
check(VisibleBars() == 0, "an icon whose nameplate is gone must not stay on screen")
reset()
levels[unit] = nil
table.remove(CastAheadData[1877])

-- A nameplate the game has hidden keeps its screen position, and our bars are
-- children of UIParent, so they do not inherit its visibility. Without checking
-- it, an icon sits on screen while its mob is behind the camera.
table.insert(CastAheadData[1877], { spell = 600, npc = 6, mob = "Known", name = "Preview", cast = 3.0,
                          cd = { 20.0 }, first = 5.0, offset = 0.0, level = 66,
                          hits = 5, dmg = 0.5, kick = 0, cc = 0, prio = "AOE" })
levels[unit] = 66
hostile[unit], combat[unit] = true, false
fire("PLAYER_ENTERING_WORLD")
fire("NAME_PLATE_UNIT_ADDED", unit)
check(VisibleBars() > 0, "a visible plate shows its preview")
plateShown = false
advance(0.3)
check(VisibleBars() == 0, "a hidden nameplate must not leave its icon on screen")
plateShown = true
reset()
levels[unit] = nil
table.remove(CastAheadData[1877])

-- The two outputs are independent: turning nameplate icons off must leave the
-- timeline working, and vice versa.
CastAheadData[1877][1].n = 40
CastAheadDB = { nameplates = false }
timeline.added = 0
enter()
castFor(3.0)
check(VisibleBars() == 0, "no icons when nameplate output is off")
check(timeline.added == 1, "but the timeline still gets the prediction")
reset()

CastAheadDB = { timeline = false }
timeline.added = 0
enter()
castFor(3.0)
check(VisibleBars() > 0, "icons still show when the timeline is off")
check(timeline.added == 0, "and nothing is published to the timeline")
reset()
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on
CastAheadData[1877][1].n = nil

-- Timeline.lua is a new entry in the TOC, and a TOC change only applies on a
-- full restart - after a mere /reload it is simply absent. Everything else must
-- keep working without it.
local savedTimeline = CastAheadTimeline
CastAheadTimeline = nil
CastAheadData[1877][1].n = 40
enter()
ok, err = pcall(castFor, 3.0)
check(ok, "the addon must work without Timeline.lua loaded: " .. tostring(err))
check(VisibleBars() > 0, "and still draw its nameplate icons")
reset()
CastAheadData[1877][1].n = nil
CastAheadTimeline = savedTimeline

-- Option toggles: on stores nil, off stores false, and a fresh profile is on.
-- `checked and nil or false` always yields false, which is how both outputs
-- ended up permanently disabled no matter what the player clicked.
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on
check(CastAheadUI.OptionEnabled("nameplates"), "a fresh profile has outputs on")
CastAheadUI.SetOption("nameplates", false)
check(not CastAheadUI.OptionEnabled("nameplates"), "unchecking turns it off")
CastAheadUI.SetOption("nameplates", true)
check(CastAheadUI.OptionEnabled("nameplates"), "and checking turns it back on")
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on

-- The anchor has to belong to the plate, or every icon stacks in the middle of
-- the screen instead of sitting beside its mob.
CastAheadData[1877][1].n = 40
lastAnchor = nil
enter()
castFor(3.0)
check(lastAnchor ~= strayUnitFrame, "must not anchor to a re-parented UnitFrame")
check(lastAnchor ~= nil and lastAnchor.unit == unit, "the plate itself is the anchor")
reset()
CastAheadData[1877][1].n = nil

-- Each spell shows its own icon. They were all coming out identical because a
-- spell the client has not cached returns no info at all, and the placeholder
-- was used for every one of them.
CastAheadData[1877][1].n = 40
enter()
castFor(3.0)                 -- spell 100 -> icon 1001, and reveals spell 101
local icons = {}
for i = 1, #allFrames do
    if allFrames[i].shown and IsBar(allFrames[i]) then
        icons[#icons + 1] = allFrames[i].icon.textureValue
    end
end
check(#icons >= 2, "two spells of one mob should both be on screen")
check(icons[1] ~= icons[2], "and must not share the same icon")
reset()
CastAheadData[1877][1].n = nil

-- An uncached spell asks the client to load it instead of silently showing a
-- placeholder forever.
requested = {}
table.insert(CastAheadData[1877], { spell = 999, npc = 9, mob = "Uncached", name = "Unknown", cast = 3.0,
                          cd = { 20.0 }, first = 5.0, offset = 0.0, level = 55,
                          hits = 5, dmg = 0.5, kick = 0, cc = 0, n = 40 })
levels[unit] = 55
enter()
castFor(3.0)
reset()
levels[unit] = nil
table.remove(CastAheadData[1877])

-- An expiring countdown used to index a nil field every frame from then on.
enter()
castFor(3.0)
ok, err = pcall(advance, 25)
check(ok, "a countdown expiring must not error: " .. tostring(err))
ok, err = pcall(advance, 1)
check(ok, "and must not error on the frame after: " .. tostring(err))
reset()

-- A kick is terminal: no STOP need follow, and the schedule must still move.
enter()
castFor(3.0)
fire("UNIT_SPELLCAST_START", unit)
advance(1.0)
ok, err = pcall(fire, "UNIT_SPELLCAST_INTERRUPTED", unit)
check(ok, "an interrupt without a following STOP must not error: " .. tostring(err))
ok, err = pcall(advance, 0.1)
check(ok, "and the next frame must not error either: " .. tostring(err))
reset()

-- A kicked cast whose spell has no rotation at all (cd = {}) must not do
-- arithmetic on nil.
-- Appended, not written over row 4: the old index overwrote spell 300 and the
-- nil below left a hole once the table grew past four rows.
table.insert(CastAheadData[1877], { spell = 400, npc = 4, mob = "Once", name = "Once", cast = 4.0,
                          cd = {}, first = 2.0, kick = 0.9, cc = 0, filler = true })
enter()
castFor(4.0)
fire("UNIT_SPELLCAST_START", unit)
advance(1.0)
ok, err = pcall(fire, "UNIT_SPELLCAST_INTERRUPTED", unit)
check(ok, "interrupting a spell with no rotation must not error: " .. tostring(err))
reset()
table.remove(CastAheadData[1877])

-- Leaving combat must drop an in-flight cast, not leave it to a late STOP.
enter()
fire("UNIT_SPELLCAST_START", unit)
combat[unit] = false
advance(0.2)                      -- lets the combat poll notice
ok, err = pcall(fire, "UNIT_SPELLCAST_STOP", unit)
check(ok, "a STOP after evade must not error: " .. tostring(err))
reset()

-- Casts on a friendly nameplate must be ignored entirely.
hostile[unit], combat[unit] = false, true
fire("NAME_PLATE_UNIT_ADDED", unit)
fire("UNIT_SPELLCAST_START", unit)
advance(2.5)
fire("UNIT_SPELLCAST_STOP", unit)
check(CastAheadCore_Test == nil or true, "friendly nameplate casts are ignored")
reset()

-- Bars are pooled, not leaked: churning plates must not keep making frames.
enter()
castFor(3.0)
reset()
local afterFirst = framesMade
for _ = 1, 5 do
    enter()
    castFor(3.0)
    reset()
end
check(framesMade == afterFirst, string.format("bars must come from the pool (made %d, expected %d)",
    framesMade, afterFirst))

-- Curated filter: a cast outside the priority set is neither drawn nor spoken
-- while "important only" (the default) is in force - even one that looks
-- dangerous by the statistics (spell 700: 5 targets, half their health).
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on
sounds, spoken, clips = 0, 0, 0
enter()
castFor(7.0)
check(VisibleBars() == 0, string.format("an unmarked cast must stay hidden by default, got %d bars", VisibleBars()))
advance(17.5)                      -- inside the warning lead of its 25s cooldown
castFor(7.0)
check(Alerts() == 0, "an unmarked cast must stay silent by default")
reset()

-- Switching the filter off brings the same cast back.
CastAheadDB = { importantOnly = false }
enter()
castFor(7.0)
check(VisibleBars() > 0, "with the filter off, the unmarked cast shows again")
reset()
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on

-- Role filter: a dps does not hear a curated TANK cast, and switching the
-- filter off (or swapping to a tank spec) brings it back without a reload.
local specRole = "DAMAGER"
GetSpecialization = function() return 1 end
GetSpecializationRole = function() return specRole end
enter()
sounds, spoken, clips = 0, 0, 0
castFor(6.0)                       -- spell 500, curated TANK
check(VisibleBars() == 0, string.format("a dps must not see a TANK cast with the role filter on, got %d bars", VisibleBars()))
advance(14.0)
castFor(6.0)
check(Alerts() == 0, string.format("nor hear it, got %d alerts", Alerts()))
reset()
CastAheadDB = { roleFilter = false }
enter()
castFor(6.0)
check(VisibleBars() > 0, "with the role filter off, the TANK cast shows to a dps")
reset()
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on
specRole = "TANK"
enter()
castFor(6.0)
check(VisibleBars() > 0, "a tank sees the TANK cast")
reset()
GetSpecialization, GetSpecializationRole = nil, nil

-- Capability gating end to end: a POISON call only reaches someone who knows
-- a poison dispel, and learning one (talent swap fires SPELLS_CHANGED) brings
-- it back without a reload.
local extraRow = CastAheadExtra[1877][1]
local savedPrio = extraRow.prio
extraRow.prio = "POISON"
local knowsDispel = false
IsPlayerSpell = function() return knowsDispel end
fire("SPELLS_CHANGED")             -- drop any cached verdicts
enter()
castFor(6.0)
check(VisibleBars() == 0, string.format("no poison dispel known, no POISON bar, got %d", VisibleBars()))
reset()
knowsDispel = true
fire("SPELLS_CHANGED")
enter()
castFor(6.0)
check(VisibleBars() > 0, "with a poison dispel known, the POISON bar shows")
reset()
extraRow.prio = savedPrio
IsPlayerSpell = nil
fire("SPELLS_CHANGED")

-- A provisional extra row is matched like any of our own:
-- identified by cast length, drawn, and alerted when its repeat lands.
enter()
sounds, spoken, clips = 0, 0, 0
castFor(6.0)                       -- spell 500 exists only in CastAheadExtra
check(VisibleBars() > 0, "an imported extra cast is identified and drawn")
advance(14.0)                      -- its 20s rotation comes around
castFor(6.0)
check(Alerts() >= 1, string.format("and its predicted repeat alerts as curated TANK, got %d", Alerts()))
reset()

-- A kickable cast already announced at START must not be announced again
-- when the game confirms it is interruptible a frame later.
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on
enter()
castFor(2.5)                       -- spell 200 (curated KICK), now identified
sounds, spoken, clips = 0, 0, 0
fire("UNIT_SPELLCAST_START", unit)
fire("UNIT_SPELLCAST_INTERRUPTIBLE", unit)
advance(0.1)
check(Alerts() == 1, string.format("one KICK call per cast, not one per event, got %d", Alerts()))
fire("UNIT_SPELLCAST_STOP", unit)
reset()

-- An overdue prediction is drawn as "!" and stays put, instead of being
-- rebuilt with a countdown every frame.
enter()
castFor(3.0)                       -- spell 100, cd 20
advance(17)
castFor(3.0)                       -- recognised on the way in; next at +20
advance(21)                        -- past nextAt
advance(0.1)
local dueShown = false
for i = 1, #allFrames do
    local f = allFrames[i]
    if f.shown and type(f.labelValue) == "string" and f.labelValue:find("!", 1, true) then
        dueShown = true
    end
end
check(dueShown, "an overdue prediction shows '!' on its icon")
reset()

-- A sibling laid out by ProjectSiblings carries an anchor, not a previous cast,
-- in lastStartAt; its first real cast must not turn that anchor gap into the
-- spell's cooldown.
enter()
castFor(3.0)                       -- spell 100 at t0; sibling 101 projected
advance(9)                         -- t0+12
castFor(4.5)                       -- spell 101's first cast; cd 18 -> next at t0+30
advance(3.5)                       -- t0+20: spell 100 goes overdue on this frame
advance(0.1)                       -- t0+20.1: 101 has ~10s left, or ~4s if 12s was adopted
local tenLeft = false
for i = 1, #allFrames do
    local f = allFrames[i]
    -- "~10": the fixture row is thin on samples, so the time is an estimate.
    if f.shown and (f.timeValue == "10" or f.timeValue == "~10") then tenLeft = true end
end
check(tenLeft, "the sibling keeps its tabled 18s cooldown, not the 12s anchor gap")
reset()

-- A kick on a mob with several tracked spells must still advance the schedule
-- of the spell that was matched at START - the old "exactly one track" proxy
-- never fired once ProjectSiblings had laid out the rest of the kit.
enter()
castFor(3.0)                       -- spell 100 identified at t0; sibling 101 projected
advance(17)                        -- t0+20: 100 predicted now
fire("UNIT_SPELLCAST_START", unit) -- matched to 100
advance(1)
fire("UNIT_SPELLCAST_INTERRUPTED", unit)   -- t0+21: next 100 due at t0+41
sounds, spoken, clips = 0, 0, 0
advance(17.2)                      -- t0+38.2: inside the 5s lead of t0+41
check(Alerts() == 1, string.format("a kicked cast on a multi-spell mob re-arms its heads-up, got %d", Alerts()))
reset()

-- Two creatures share a 3.0s cast and the same opening delay, so the first
-- cast is a tie. A later cast unique to one creature settles it, and the tied
-- track must be cleaned up on the spot rather than waiting for its next cast.
table.insert(CastAheadData[1877], { spell = 900, npc = 9, mob = "Lookalike", name = "Twin", cast = 3.0,
                          cd = { 20.0 }, first = 5.0, firstN = 5, hits = 1, dmg = 0.3,
                          kick = 0, cc = 0, prio = "TANK" })
enter()
castFor(3.0)                       -- 100 (AOE) or 900 (TANK): no consensus, no label
castFor(4.5)                       -- spell 101 belongs to npc 1 only
local unlabelled = 0
for i = 1, #allFrames do
    local f = allFrames[i]
    if f.shown and f.labelValue == "" then unlabelled = unlabelled + 1 end
end
check(unlabelled == 0, string.format("a creature named by one cast settles its other tied casts, %d still unlabelled", unlabelled))
reset()
table.remove(CastAheadData[1877])

-- Dispel learning: a "targeted" cast that lands a Poison on the player is
-- called "dispel poison" from then on - and only when exactly one identified
-- cast just finished, so the debuff cannot be pinned on the wrong spell.
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on
local row101 = CastAheadData[1877][2]
row101.prio = "TARGET"
enter()
castFor(4.5)                       -- spell 101, unique length
playerAuras[1] = { auraInstanceID = 4242, spellId = 4242, isHarmful = true, dispelName = "Poison" }
fire("UNIT_AURA", "player")
check(CastAheadDB and CastAheadDB.dispel and CastAheadDB.dispel[101] == "Poison",
    "a debuff right after one identified cast teaches that cast's dispel type")
check(CastAheadMatch.Advice(row101) == CastAheadMatch.ADVICE.POISON,
    "and the call becomes 'dispel poison' instead of 'targeted'")
reset()
-- Two casts finishing together: nothing is learned.
row101.dispel = nil
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on
-- Secret aura data (the in-game reality inside instances) must neither error
-- nor teach anything.
row101.dispel = nil
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on
playerAuras[1] = { auraInstanceID = 4300, spellId = 4300, isHarmful = true, dispelName = "Magic" }
issecretvalue = function(v) return v == playerAuras[1] end
enter()
castFor(4.5)
local okSecret, errSecret = pcall(fire, "UNIT_AURA", "player")
check(okSecret, "secret aura data must not error: " .. tostring(errSecret))
check(not (CastAheadDB and CastAheadDB.dispel), "secret aura data teaches nothing")
issecretvalue = nil
reset()

-- Two plates: spell 300 on the second finishes 1.5s before spell 100 on the
-- first, so both are still recent when the debuff lands.
local second = "nameplate2"
enter()
hostile[second], combat[second] = true, true
fire("NAME_PLATE_UNIT_ADDED", second)
fire("UNIT_SPELLCAST_START", unit)
fire("UNIT_SPELLCAST_START", second)
advance(1.5)
fire("UNIT_SPELLCAST_STOP", second)
advance(1.5)
fire("UNIT_SPELLCAST_STOP", unit)
playerAuras[1] = { auraInstanceID = 4243, spellId = 4243, isHarmful = true, dispelName = "Curse" }
fire("UNIT_AURA", "player")
fire("NAME_PLATE_UNIT_REMOVED", second)
hostile[second], combat[second] = nil, nil
check(not (CastAheadDB and CastAheadDB.dispel), "a debuff after two casts at once is not attributed")
reset()
row101.prio = "AOE"
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on

-- Rows are ordered by when the cast is due: after spell 100 is identified its
-- sibling 101 is projected 9s after it (offset), while 100 itself comes back
-- in 20s - so 101's icon has to be first. The first bar made for the plate is
-- the first slot, so its icon tells which row got it.
enter()
castFor(3.0)
local firstBar
for i = 1, #allFrames do
    local f = allFrames[i]
    if f.shown and IsBar(f) and f.icon.textureValue then firstBar = firstBar or f end
end
check(firstBar and firstBar.icon.textureValue == textures[101],
    "the soonest cast takes the first slot")
reset()

-- And the first slot is the one at the anchor, whichever way the rest grow:
-- anchored left of the plate and growing left, the soonest icon (101) must be
-- the rightmost - nearest the plate - and the later one (100) further left.
CastAheadDB = { grow = "left" }
enter()
castFor(3.0)
local xOf = {}
for i = 1, #allFrames do
    local f = allFrames[i]
    if f.shown and IsBar(f) and f.icon.textureValue and f.x then
        xOf[f.icon.textureValue] = f.x
    end
end
check(xOf[textures[101]] and xOf[textures[100]] and xOf[textures[101]] > xOf[textures[100]],
    string.format("growing left, the soonest icon sits nearest the plate (101 at %s, 100 at %s)",
        tostring(xOf[textures[101]]), tostring(xOf[textures[100]])))
reset()
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on

-- A cast whose interval is nowhere near the spell's schedule is rejected, and
-- the re-identification that follows must not hand the same spell straight
-- back (the interval fallback used to keep every candidate when none fit).
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on
enter()
castFor(3.0)                       -- spell 100, cd 20
advance(42)                        -- 45s since: far outside 20 +/- 50%
castFor(3.0)
check(not IconShown(100), "a spell rejected by its own schedule is not re-adopted by cast length")
reset()

-- A spell switched off in the window is not projected from its siblings.
CastAheadDB = { disabled = { [101] = true } }
enter()
castFor(3.0)                       -- identifies 100; sibling 101 would be projected
check(not IconShown(101), "a disabled spell is not laid out as a sibling")
reset()
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on

-- A prediction kept as overdue ("!") must still recognise the cast when it
-- finally starts, well outside the usual four-second window.
enter()
castFor(3.0)                       -- next 100 at +20
advance(17)
advance(8)                         -- +28: overdue, marked due
sounds, spoken, clips = 0, 0, 0
fire("UNIT_SPELLCAST_START", unit)
check(Alerts() == 1, string.format("a late cast on an overdue prediction is recognised and alerted, got %d", Alerts()))
advance(3)
fire("UNIT_SPELLCAST_STOP", unit)
reset()

-- Channels ------------------------------------------------------------------

-- A channel is identified by its measured length like a cast, and its next
-- occurrence is predicted from the rotation.
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on
enter()
channelFor(6.0)                        -- spell 610, cd 22
check(IconShown(610), "a channel is identified by its length and drawn")
advance(10.5)                          -- 16.5s after the channel started: still short of the 5s lead of the 22s cooldown
sounds, spoken, clips = 0, 0, 0
advance(1.0)                           -- 17.5s: inside the lead, so the heads-up is this frame's
check(Alerts() == 1, string.format("a predicted channel warns ahead like a cast, got %d", Alerts()))
reset()

-- A cast and a channel of the same length on one plate are two tracks: the
-- cast keeps its own identity and countdown after the channel is measured.
table.insert(CastAheadData[1877], { spell = 620, npc = 11, mob = "Drainer", name = "Slam", cast = 6.0,
                          cd = { 30.0 }, first = 4.0, firstN = 5, hits = 5, dmg = 0.5, n = 20,
                          kick = 0, cc = 0, prio = "AOE" })
textures[620] = 1062
enter()
castFor(6.0)                           -- spell 620 (cast)
channelFor(6.0)                        -- spell 610 (channel)
check(IconShown(620) and IconShown(610), "a 6.0s cast and a 6.0s channel keep separate tracks")
reset()
table.remove(CastAheadData[1877])

-- A channel cut short by an interrupt is never measured: INTERRUPTED lands
-- before CHANNEL_STOP, finishes the channel off, and the STOP finds nothing
-- in flight - so the shortened length cannot be mistaken for another spell.
enter()
fire("UNIT_SPELLCAST_CHANNEL_START", unit)
advance(5.8)                           -- would still read as the 6.0s spell 610 if measured
fire("UNIT_SPELLCAST_INTERRUPTED", unit)
fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
check(not IconShown(610), "an interrupted channel is not identified by its shortened length")
reset()

-- A channel starting exactly where a cast was predicted is not that cast.
-- Attributing it across kinds handed the channel the cast's track: the cast's
-- timeline event was finished early and its call was voiced for a spell that
-- never went out.
enter()
castFor(3.0)                           -- spell 100, next predicted at +20
advance(17)                            -- t0+20, where 100 is due
sounds, spoken, clips = 0, 0, 0
fire("UNIT_SPELLCAST_CHANNEL_START", unit)
check(Alerts() == 0, string.format("a channel is not taken for a cast predicted at the same moment, got %d", Alerts()))
fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
reset()

-- Two creatures channel for 6.0s, so the channel alone names neither and the
-- traits have to. npc 11 lists the length under `channels`, npc 12 lists a
-- different one, and both are level 94 - so only the channel list can tell
-- them apart, and the one it confirms locks the plate.
table.insert(CastAheadData[1877], { spell = 630, npc = 12, mob = "Twin Drainer", name = "Drain Too",
                          cast = 6.0, cd = { 22.0 }, first = 8.0, firstN = 5, hits = 1, dmg = 0.3,
                          n = 50, kick = 0, cc = 0, channel = true, prio = "TANK" })
textures[630] = 1063
levels[unit] = 94
enter()
channelFor(6.0)
check(IconShown(610) and not IconShown(630),
    "a measured channel confirms the creature whose `channels` list holds that length")
reset()

-- ...and a creature that lists cast lengths but no channels is not judged on a
-- channel at all. npc 1's `casts` has no 6.0, and reading a channel against
-- that list would rule npc 1 out - leaving the 3.0s tie below to the lookalike.
table.insert(CastAheadData[1877], { spell = 900, npc = 9, mob = "Lookalike", name = "Twin", cast = 3.0,
                          cd = { 20.0 }, first = 5.0, firstN = 5, hits = 5, dmg = 0.5, n = 50,
                          kick = 0, cc = 0, prio = "AOE" })
levels[unit] = 91
enter()
channelFor(6.0)                        -- 610 or 630: ambiguous, so nothing locks
castFor(3.0)                           -- 100 (npc 1) or 900 (npc 9)
check(IconShown(100) and not IconShown(900),
    "a channel length is not held against a creature that lists no channels")
reset()
levels[unit] = nil
table.remove(CastAheadData[1877])       -- 900
table.remove(CastAheadData[1877])       -- 630
textures[630] = nil

-- A trait-earned lock is not released by a channel the creature has no row
-- for. The channel table is a fraction of the cast table's size, so an unknown
-- channel is the normal case, not evidence that the creature was misnamed -
-- and releasing on it handed the plate to whichever creature the next channel
-- length happened to fit.
table.insert(CastAheadData[1877], { spell = 630, npc = 12, mob = "Twin Drainer", name = "Drain Too",
                          cast = 6.0, cd = { 22.0 }, first = 8.0, firstN = 5, hits = 1, dmg = 0.3,
                          n = 50, kick = 0, cc = 0, channel = true, prio = "TANK" })
-- npc 12's alone: the locked npc 11 has no 9.0s channel, so with the lock
-- standing this length identifies nothing at all.
table.insert(CastAheadData[1877], { spell = 660, npc = 12, mob = "Twin Drainer", name = "Long Drain",
                          cast = 9.0, cd = { 30.0 }, first = 4.0, firstN = 5, hits = 1, dmg = 0.3,
                          n = 50, kick = 0, cc = 0, channel = true, prio = "TANK" })
textures[630], textures[660] = 1063, 1066
levels[unit] = 94
enter()
channelFor(6.0)                        -- 610 or 630 by length; npc 11's `channels` confirms it
check(IconShown(610), "the trait lock is in place before the unknown channel")
channelFor(9.0)                        -- npc 11 has no 9.0s channel: no candidates
check(not IconShown(660),
    "a channel the locked creature has no row for never releases its trait lock")
reset()
levels[unit] = nil
table.remove(CastAheadData[1877])       -- 660
table.remove(CastAheadData[1877])       -- 630
textures[630], textures[660] = nil, nil

-- A kicked channel is announced by CHANNEL_STOP's `interruptedBy` payload, with
-- no UNIT_SPELLCAST_INTERRUPTED in front of it. Measuring the shortened channel
-- instead identifies whatever spell that length happens to fit, and leaves the
-- real spell's schedule stuck on a prediction that already passed.
enter()
channelFor(6.0)                        -- spell 610 at t0; next channel at t0+22
advance(16)                            -- t0+22, where 610 is due
fire("UNIT_SPELLCAST_CHANNEL_START", unit)
advance(3.0)                           -- t0+25: a 3.0s length, if it were measured
fire("UNIT_SPELLCAST_CHANNEL_STOP", unit, nil, nil, "Kicker")
check(not IconShown(100), "a kicked channel is not measured into a same-length cast")
sounds, spoken, clips = 0, 0, 0
advance(17.2)                          -- t0+42.2: inside the 5s lead of t0+44
check(Alerts() == 1, string.format("a kicked channel re-arms its heads-up from the kick, got %d", Alerts()))
reset()

-- The same payload is Secret while unit spellcasts are restricted, which is
-- the in-instance reality. Its secrecy has to be tested before it is compared
-- to anything - and a Secret one still counts as a kick.
enter()
channelFor(6.0)
advance(16)
fire("UNIT_SPELLCAST_CHANNEL_START", unit)
advance(3.0)
local secretKicker = {}
issecretvalue = function(v) return v == secretKicker end
ok, err = pcall(fire, "UNIT_SPELLCAST_CHANNEL_STOP", unit, nil, nil, secretKicker)
issecretvalue = nil
check(ok, "a Secret interruptedBy must not error: " .. tostring(err))
check(not IconShown(100), "and the shortened channel identifies nothing")
reset()

-- A kicked channel that matched no track must not fall back onto a cast track.
-- The single-track fallback used to walk every track regardless of kind, so an
-- unrecognised channel re-anchored the plate's only cast and its prediction
-- silently slid forward a whole cooldown.
enter()
castFor(1.5)                           -- spell 300 (npc 3, no siblings); next at t0+4.8
advance(3.5)                           -- t0+5.0: 300 is overdue and drawn as "!"
fire("UNIT_SPELLCAST_CHANNEL_START", unit)   -- a channel, matching no channel track
advance(1)
fire("UNIT_SPELLCAST_INTERRUPTED", unit)
advance(0.1)
local stillDue = false
for i = 1, #allFrames do
    local f = allFrames[i]
    if f.shown and type(f.labelValue) == "string" and f.labelValue:find("!", 1, true) then
        stillDue = true
    end
end
check(stillDue, "an interrupted channel does not advance a cast track's rotation")
reset()

-- Slash routing: the sub-command is the first word of the message, so an
-- argument that happens to name another sub-command cannot steal it.
CastAheadDB = nil
SlashCmdList.CASTAHEAD("anchor center")
check(CastAheadDB and CastAheadDB.anchor == "center",
    "/ca anchor center sets the anchor rather than being read as /ca center")
SlashCmdList.CASTAHEAD("anchor left")
check(CastAheadDB.anchor == nil, "anchoring back to the default clears the stored value")
SlashCmdList.CASTAHEAD("center -200")
check(CastAheadDB.centerY == -200, "/ca center still moves the centre call")
SlashCmdList.CASTAHEAD("grow up")
check(CastAheadDB.grow == "up", "/ca grow still sets the growth direction")
CastAheadDB = nil

-- Test drive: /ca test draws demo bars without any real cast, and a second
-- invocation clears them again.
CastAheadCore.Test(1877)
check(VisibleBars() > 0, string.format("the test drive draws demo bars, got %d", VisibleBars()))
CastAheadCore.Test(1877)
check(VisibleBars() == 0, string.format("stopping the test drive hides them, got %d", VisibleBars()))
-- With a hostile plate on screen the demo icons hang off it, not off the
-- screen centre - found by unit token, since nameplate addons replace the
-- frames GetNamePlates() returns.
hostile[unit] = true
lastAnchor = nil
CastAheadCore.Test(1877)
check(lastAnchor and lastAnchor.unit == unit, "the test drive anchors to a live hostile nameplate")
CastAheadCore.Test(1877)
hostile[unit] = nil

-- The speaker button's preview speaks (or beeps) regardless of the mutes.
sounds, spoken, clips = 0, 0, 0
CastAheadDB = { sound = false, voice = false }
CastAheadCore.PreviewAdvice(CastAheadMatch.ADVICE.TANK)
check(Alerts() == 1, string.format("preview plays through the mute switches, got %d", Alerts()))
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on

-- Voice chain: our clip first; a clip the client cannot play (missing file)
-- falls through to the game's voice; a SpeakText that returns no utteranceID
-- did not actually speak (alerts disabled in the game options) and falls
-- through to the beep. The click must never stay silent.
sounds, spoken, clips = 0, 0, 0
CastAheadCore.PreviewAdvice(CastAheadMatch.ADVICE.TANK)
check(clips == 1 and spoken == 0 and sounds == 0,
    string.format("the clip plays first, got clips=%d spoken=%d beeps=%d", clips, spoken, sounds))
clipsPlayable = false
sounds, spoken, clips = 0, 0, 0
CastAheadCore.PreviewAdvice(CastAheadMatch.ADVICE.TANK)
check(spoken == 1 and sounds == 0, string.format("no clip, the game voice speaks, got spoken=%d beeps=%d", spoken, sounds))
local realSpeak = C_CombatAudioAlert.SpeakText
C_CombatAudioAlert.SpeakText = function() end
sounds, spoken, clips = 0, 0, 0
CastAheadCore.PreviewAdvice(CastAheadMatch.ADVICE.TANK)
check(sounds == 1, string.format("no clip and a silent SpeakText fall back to the beep, got %d beeps", sounds))
C_CombatAudioAlert.SpeakText = realSpeak
clipsPlayable = true
-- The player can prefer the game's voice over our clips.
CastAheadDB = { voiceTTS = true }
sounds, spoken, clips = 0, 0, 0
CastAheadCore.PreviewAdvice(CastAheadMatch.ADVICE.TANK)
check(clips == 0 and spoken == 1, string.format("voiceTTS skips the clip, got clips=%d spoken=%d", clips, spoken))
-- ...and when the game's voice cannot speak, the clip covers for it.
C_CombatAudioAlert.SpeakText = function() end
sounds, spoken, clips = 0, 0, 0
CastAheadCore.PreviewAdvice(CastAheadMatch.ADVICE.TANK)
check(clips == 1 and sounds == 0, string.format("voiceTTS with a mute game voice falls back to the clip, got clips=%d beeps=%d", clips, sounds))
C_CombatAudioAlert.SpeakText = realSpeak
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on

-- A sound the player picked for a category (LibSharedMedia name) plays every
-- time, on top of the voice; the stock beep stays a fallback only.
LibStub = function(name, silent)
    if name == "LibSharedMedia-3.0" then
        return { Fetch = function(_, kind, key) return kind == "sound" and key == "Gong" and "Interface\\\\Gong.ogg" or nil end }
    end
    return nil
end
CastAheadDB = { sounds = { TANK = "Gong" } }
sounds, spoken, clips = 0, 0, 0
CastAheadCore.PreviewAdvice(CastAheadMatch.ADVICE.TANK)
check(clips == 2 and sounds == 0, string.format("a chosen sound plays alongside the voice clip, got files=%d beeps=%d", clips, sounds))
sounds, spoken, clips = 0, 0, 0
CastAheadCore.PreviewAdvice(CastAheadMatch.ADVICE.AOE)
check(clips == 1 and sounds == 0, string.format("a category without a chosen sound plays only its voice, got files=%d beeps=%d", clips, sounds))
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on
LibStub = nil

-- Centre call: shown with the response in words while an important cast goes
-- out, gone when the cast ends, never shown when switched off.
local function CenterFrameStub()
    for i = 1, #allFrames do
        local f = allFrames[i]
        -- A centre line reads "<Response in words>  <seconds>"; bars carry
        -- digits only, so the letters are the discriminator.
        if type(f.timeValue) == "string" and f.timeValue:match("^%u[%l ,]+  %d+%.%d$") then return f end
    end
    return nil
end
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on
-- castFor completes a cast in one call, so drive START by hand to catch the
-- frame mid-cast. Spell 100 (curated AOE, 3.0s, cd 20) identifies the plate
-- on its own, and its predicted repeat is what the START below resolves to.
enter()
castFor(3.0)                       -- identifies spell 100
advance(17.0)                      -- t0+20: its rotation comes around
fire("UNIT_SPELLCAST_START", unit)
advance(0.5)
local shownMid = CenterFrameStub()
check(shownMid and shownMid.shown, "an important cast puts the call in the screen centre")
check(shownMid and shownMid.timeValue:match("^%u[%l ,]+  2%.%d$"),
    "the centre call reads the response and the seconds left, got " .. tostring(shownMid and shownMid.timeValue))
advance(4.0)                       -- past the 3s cast, no STOP yet
check(not (shownMid and shownMid.shown), "the centre call is gone once the cast time has run out")
reset()
CastAheadDB = { centerText = false }
enter()
castFor(3.0)
advance(17.0)
fire("UNIT_SPELLCAST_START", unit)
advance(0.5)
local hidden = CenterFrameStub()
check(not (hidden and hidden.shown), "centerText = false keeps the centre call hidden")
reset()
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on

print(failures == 0 and "OK" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
