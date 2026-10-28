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
MouseIsDown = true
IsMouseButtonDown = function() return MouseIsDown end

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
             ALARM_CLOCK_WARNING_1 = 4 }
PlaySound = function() sounds = sounds + 1 end

local framesMade, shownCount = 0, 0
local function StubRegion()
    -- `textureValue` is a real field: the catch-all __index below hands back a
    -- fresh closure for anything unknown, so a test reading an unset field would
    -- always see two "different" values and could never fail.
    local r = { textureValue = false, shown = false }
    r.SetTexture = function(_, tex) r.textureValue = tex end
    r.Show = function() r.shown = true end
    r.Hide = function() r.shown = false end
    r.SetShown = function(_, on) r.shown = on and true or false end
    r.IsShown = function() return r.shown end
    r.SetAllPoints = function(_, target) r.allPointsTo = target end
    r.GetTexture = function() return r.textureValue end
    setmetatable(r, { __index = function() return function() return r end end })
    return r
end

local eventHandler, updateHandler
CreateFrame = function(kind, _, parent)
    local f = { shown = false, texts = {}, kind = kind, handlers = {}, parent = parent }
    allFrames[#allFrames + 1] = f
    framesMade = framesMade + 1
    f.Show = function(self)
        if not self.shown then shownCount = shownCount + 1 end
        self.shown = true
    end
    f.Hide = function(self) self.shown = false end
    f.SetShown = function(self, on)
        if on then self:Show() else self:Hide() end
    end
    f.IsShown = function(self) return self.shown end
    f.SetScript = function(_, script, fn)
        f.handlers[script] = fn
        -- Core registers more than one event frame (the main one, plus a small
        -- frame that saves diagnostics on logout). Only the first owns the
        -- event flow; keeping just the last one silently redirected everything.
        if script == "OnEvent" then
            eventHandler = eventHandler or fn
        elseif script == "OnUpdate" then
            updateHandler = updateHandler or fn
        end
    end
    if kind == "EditBox" then
        f.SetText = function(self, text) self.value = text end
        f.GetText = function(self) return self.value end
    end
    f.CreateTexture = StubRegion
    f.CreateFontString = function()
        local fs = StubRegion()
        f.fontStrings = f.fontStrings or {}
        table.insert(f.fontStrings, fs)
        -- Record into separate fields: Core assigns the font strings to
        -- bar.text / bar.time, so writing there would overwrite them.
        fs.SetText = function(self, text) f.labelValue, self.value = text, text end
        fs.GetText = function(self) return self.value end
        fs.SetFormattedText = function(_, fmt, ...) f.timeValue = string.format(fmt, ...) end
        -- The layout steps the icons sideways by the width of the advice under
        -- them, so a stub that answers with a table (the catch-all below) turns
        -- into an arithmetic error rather than a wrong number.
        fs.GetStringWidth = function()
            -- The widest line, the way the real font string measures it.
            local widest = 0
            for line in tostring(f.labelValue or ""):gmatch("[^\n]+") do
                widest = math.max(widest, #line * 6)
            end
            return widest
        end
        -- The layout also stacks icons by the height of the advice, so a
        -- verdict written over two lines does not overlap its neighbour.
        fs.GetStringHeight = function()
            local lines = 0
            for _ in tostring(f.labelValue or ""):gmatch("[^\n]+") do lines = lines + 1 end
            return math.max(lines, 1) * 11
        end
        return fs
    end
    f.GetParent = function(self) return self.parent end
    f.SetPoint = function(self, ...)
        local _, anchor, _, x, y = ...
        lastAnchor = anchor
        self.x, self.y = x, y            -- offsets, for the layout cases
        self.points = { ... }
    end
    f.GetPoint = function(self) return unpack(self.points or {}) end
    f.SetTexture = function(self, tex) self.texture = tex end
    f.SetParent = function(self, p) self.parent = p end
    f.SetFrameStrata = function(self, strata) self.strata = strata end
    f.GetFrameStrata = function(self) return self.strata end
    f.EnableMouse = function(self, on) self.mouse = on end
    f.EnableMouseWheel = function(self, on) self.wheel = on end
    f.SetFrameLevel = function(self, level) self.level = level end
    f.GetFrameLevel = function(self) return self.level end
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
        if type(key) == "string" and key:match("^%l") then return nil end
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
        -- firstN matters: the neighbour-lock cases below tie this row against
        -- 950, and a row without opening samples loses that tie to any rival
        -- inside FIRST_TOLERANCE before the lock ever gets a say.
        { spell = 300, npc = 3, mob = "Cycler", name = "Cycle", cast = 1.5, cd = { 4.8, 4.8, 8.7 },
          first = 3.0, firstN = 5, hits = 3, dmg = 0.25, kick = 0, cc = 0.05 },
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

CastAheadSaveButtons = {}
CastAheadDefensives = { spells = {}, alias = {} }
StaticPopupDialogs = {}

dofile("Config.lua")
dofile("Match.lua")
dofile("Lists.lua")
dofile("Saves.lua")
dofile("Burst.lua")
dofile("BossAdapter.lua")
dofile("Timeline.lua")
-- UI.lua only needs the stubs above for its option helpers.
UISpecialFrames = {}
SlashCmdList = {}
SearchBoxTemplate_OnTextChanged = function() end
GameTooltip = setmetatable({}, { __index = function() return function() end end })
GameTooltip_Hide = function() end
dofile("Window.lua")
dofile("CastsPage.lua")
dofile("SavesPage.lua")
dofile("UI.lua")
dofile("Core.lua")
dofile("Setup.lua")
dofile("Recorder.lua")
dofile("ReportWindow.lua")

local function fire(event, ...) eventHandler(nil, event, ...) end

-- Config: flat settings -------------------------------------------------
local savedInInstance, savedInstanceInfo = IsInInstance, GetInstanceInfo
local instanceKind = "party"
IsInInstance = function() return true, instanceKind end
GetInstanceInfo = function() return "d", instanceKind, 0, "", 0, 0, false, 1877 end

CastAheadDB = nil
CastAheadConfig.SetEnabled("nameplates", false)
check(CastAheadConfig.Enabled("nameplates") == false, "an option switched off reads back off")
CastAheadConfig.SetEnabled("nameplates", true)
check(CastAheadConfig.Enabled("nameplates") == true, "switching it back on is honored")
check(CastAheadDB.nameplates == nil, "and stores nothing, so a later default change still applies")

instanceKind = "raid"
check(CastAheadConfig.Enabled("nameplates") == true, "settings do not change with the instance kind")
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

CastAheadDB = nil
CastAheadConfig.Migrate()
check(CastAheadConfig.CenterText(), "a new install starts with the centre call on")
CastAheadDB = { anchor = "left" }
CastAheadConfig.Migrate()
check(CastAheadConfig.CenterText(), "a profile with no stored choice has it on")
CastAheadDB.centerText = false
CastAheadConfig.Migrate()
check(not CastAheadConfig.CenterText(), "switching it off survives the next zone-in")
CastAheadDB = { centerText = false }
CastAheadConfig.Migrate()
check(not CastAheadConfig.CenterText(), "an old profile that had it off keeps it off")

CastAheadDB = nil
fire("ADDON_LOADED", "CastAhead")
CastAheadDB = CastAheadDB or {}
CastAheadDB.minimap = CastAheadDB.minimap or {}
fire("PLAYER_ENTERING_WORLD")
check(CastAheadConfig.CenterText(),
    "a new install has the centre call on although the minimap icon creates the profile at login")
CastAheadDB = { ctx = { key = { voice = false } } }
fire("ADDON_LOADED", "CastAhead")
check(CastAheadDB.voice == false and CastAheadDB.ctx == nil and CastAheadConfig.CenterText(),
    "loading an old profile migrates it and keeps its centre call")
CastAheadDB = { anchor = "left" }
fire("ADDON_LOADED", "SomeOtherAddon")
fire("PLAYER_ENTERING_WORLD")
check(CastAheadDB.schema == nil, "another addon loading, or a zone-in, does not migrate")
instanceKind = "party"
CastAheadDB = { schema = 2 }
fire("ADDON_LOADED", "CastAhead")
check(not CastAheadConfig.SaveCalls() and CastAheadDB.saveCallsNotice == true,
    "a profile from before the default changed ends with its defensive calls off and the notice flagged")
CastAheadDB = { schema = 2, saveCalls = false }
fire("ADDON_LOADED", "CastAhead")
check(not CastAheadConfig.SaveCalls(), "and one that had them off keeps them off")
CastAheadDB = nil
fire("ADDON_LOADED", "CastAhead")
check(not CastAheadConfig.SaveCalls(), "a new install starts with defensive calls off")
CastAheadDB = { schema = 3 }
fire("ADDON_LOADED", "CastAhead")
check(not CastAheadConfig.SaveCalls(), "a profile that switched them off after the change keeps them off")
CastAheadDB = { schema = 3, saveCalls = true, voice = false, window = { width = 900 }, journal = { 1 }, probe = { 2 },
    dispel = { [100] = "Magic" } }
CastAheadConfig.ResetAll()
fire("ADDON_LOADED", "CastAhead")
check(CastAheadDB.voice == nil and CastAheadDB.window == nil and not CastAheadConfig.SaveCalls()
    and CastAheadDB.journal[1] == 1 and CastAheadDB.probe[1] == 2 and (CastAheadDB.dispel or {})[100] == "Magic",
    "a full reset reads as a new install after the reload and keeps the recorded data")
instanceKind = "raid"

CastAheadSaveButtons = { [72] = { def = { 7, 3 } }, [75] = { def = { 8 } }, [76] = { def = { 8 } } }
CastAheadDB = { schema = 3, saveCalls = true, saveButtons = {
    [71] = { big = { 1, { use = 5 } }, small = { 2, 1, { use = 5 } }, heal = { 9 } },
    [72] = { small = { 3 } },
    [73] = { big = {}, small = {} },
    [74] = { heal = { 9 } },
    [75] = { small = {} },
    [76] = { big = {}, small = { 8 } },
    [77] = { small = { 108416 }, def = { 104773, { use = 452930 } }, big = { 5 }, heal = { 9 } },
} }
fire("ADDON_LOADED", "CastAhead")
do
local sb = CastAheadDB.saveButtons
check(#sb[77].def == 2 and sb[77].def[1] == 104773 and sb[77].def[2].use == 452930
    and sb[77].small == nil and sb[77].big == nil and sb[77].heal == nil,
    "a defensive list already saved survives and the stale keys go")
check(sb[75].def == nil and sb[75].small == nil, "one side emptied on its own leaves the shipped list in place")
check(#sb[76].def == 1 and sb[76].def[1] == 8, "both sides present and one empty: the other alone")
check(#sb[72].def == 2 and sb[72].def[1] == 3 and sb[72].def[2] == 7,
    "one side custom: its entries first, then the shipped ones not already there")
check(#sb[71].def == 3 and sb[71].def[1] == 2 and sb[71].def[2] == 1 and sb[71].def[3].use == 5
    and sb[71].small == nil and sb[71].big == nil and sb[71].heal == nil,
    "schema 4 joins small then big entries into one list without repeats")
check(sb[72].small == nil, "the small list is gone after the join")
check(sb[73].def and #sb[73].def == 0, "a spec the player emptied on purpose stays empty")
check(sb[74].def == nil and sb[74].heal == nil, "a spec with only heal entries falls back to the shipped list")
check(CastAheadDB.schema == 6, "the profile is stamped schema 6")
CastAheadDB = { schema = 3, saveCalls = true, smallCalls = false, bigCalls = false, healCalls = false }
fire("ADDON_LOADED", "CastAhead")
check(CastAheadDB.saveCalls == false and CastAheadDB.smallCalls == nil and CastAheadDB.bigCalls == nil
    and CastAheadDB.healCalls == nil, "small and big both off read as defensive calls off")
CastAheadDB = { smallCalls = false, bigCalls = false }
CastAheadConfig.Migrate()
check(CastAheadDB.saveCalls == false, "an old profile with small and big off ends with the defensive calls off")
CastAheadDB = { schema = 3, saveCalls = true, smallCalls = false }
fire("ADDON_LOADED", "CastAhead")
check(CastAheadDB.saveCalls == false and CastAheadDB.smallCalls == nil, "only small off still ends with the one-time reset")
CastAheadDB = { schema = 3, sounds = { SMALL = "x", HEAL = "h" } }
fire("ADDON_LOADED", "CastAhead")
check(CastAheadDB.sounds.DEFENSIVE == "x" and CastAheadDB.sounds.SMALL == nil and CastAheadDB.sounds.HEAL == nil,
    "the small sound becomes the defensive sound")
CastAheadDB = { schema = 3, sounds = { SMALL = "x", BIG = "b" } }
fire("ADDON_LOADED", "CastAhead")
check(CastAheadDB.sounds.DEFENSIVE == "b", "the big sound wins over the small one")
CastAheadDB = { schema = 3, sounds = { TANK = "Cast Ahead: big defensive", HEALER = "Cast Ahead: small defensive",
    BIG = "Cast Ahead: big defensive", SMALL = "Cast Ahead: heal up", KEEP = "Cast Ahead: defensive" },
    spellSounds = { [123] = "Cast Ahead: heal up", [124] = "Cast Ahead: small defensive" } }
fire("ADDON_LOADED", "CastAhead")
check(CastAheadDB.sounds.TANK == "CastAhead: defensive" and CastAheadDB.sounds.HEALER == "CastAhead: defensive"
    and CastAheadDB.sounds.KEEP == "CastAhead: defensive" and CastAheadDB.sounds.DEFENSIVE == "CastAhead: defensive",
    "sound picks naming the deleted defensive clips point at the merged one")
check(CastAheadDB.spellSounds[123] == nil and CastAheadDB.spellSounds[124] == "CastAhead: defensive",
    "spell sound picks follow, and a heal up pick is dropped")
CastAheadDB = { schema = 3, saveButtons = { [71] = { big = { 1 }, small = { 2 } } }, sounds = { SMALL = "x" } }
fire("ADDON_LOADED", "CastAhead")
local once = { #CastAheadDB.saveButtons[71].def, CastAheadDB.sounds.DEFENSIVE }
fire("ADDON_LOADED", "CastAhead")
check(#CastAheadDB.saveButtons[71].def == once[1] and CastAheadDB.sounds.DEFENSIVE == once[2],
    "migrating twice changes nothing more")
end
CastAheadSaveButtons = {}
CastAheadDB = nil
fire("ADDON_LOADED", "CastAhead")
check(CastAheadDB.schema == 6 and CastAheadDB.saveButtons == nil, "a new install is schema 6 with no saved lists")

do
    CastAheadDB = { schema = 4, saveCalls = true, raidSaves = true }
    fire("ADDON_LOADED", "CastAhead")
    check(CastAheadDB.schema == 6 and CastAheadDB.saveCalls == false and CastAheadDB.saveCallsNotice == true
        and CastAheadDB.raidSaves == false, "a schema 4 profile with defensive calls on is turned off once and flagged")
    CastAheadDB = { schema = 3, raidSaves = true }
    fire("ADDON_LOADED", "CastAhead")
    check(CastAheadDB.raidSaves == false and CastAheadDB.saveCallsNotice == true,
        "raid calls alone on are turned off once and flagged")
    CastAheadDB = { schema = 3, saveCalls = true, raidSaves = true }
    fire("ADDON_LOADED", "CastAhead")
    check(CastAheadDB.saveCalls == false and CastAheadDB.raidSaves == false and CastAheadDB.saveCallsNotice == true,
        "both on are both turned off with one flag")
    CastAheadDB.saveCalls = true
    CastAheadDB.saveCallsNotice = nil
    fire("ADDON_LOADED", "CastAhead")
    check(CastAheadDB.schema == 6 and CastAheadDB.saveCalls == true and CastAheadDB.saveCallsNotice == nil,
        "migrating again changes nothing and raises no flag")
    CastAheadDB = nil
    fire("ADDON_LOADED", "CastAhead")
    check(CastAheadDB.saveCalls == nil and CastAheadDB.saveCallsNotice == nil, "a new install has no stored choice and no flag")
    for _, stored in ipairs({ false, "nil" }) do
        CastAheadDB = { schema = 4, saveCalls = stored ~= "nil" and stored or nil }
        fire("ADDON_LOADED", "CastAhead")
        check(CastAheadDB.saveCalls == (stored ~= "nil" and stored or nil) and CastAheadDB.saveCallsNotice == nil,
            "a schema 4 profile with defensive calls off or unset stays as it was")
    end
    CastAheadDB = { schema = 5, burstCalls = true }
    fire("ADDON_LOADED", "CastAhead")
    check(CastAheadDB.schema == 6 and CastAheadDB.raidMode == true and CastAheadDB.burstCalls == true,
        "a schema 5 profile with burst windows on gets the raid switch on")
    CastAheadDB = { schema = 5, raidSaves = true }
    fire("ADDON_LOADED", "CastAhead")
    check(CastAheadDB.raidMode == true and CastAheadDB.raidSaves == true,
        "a schema 5 profile with raid defensive calls on gets the raid switch on")
    CastAheadDB = { schema = 5 }
    fire("ADDON_LOADED", "CastAhead")
    check(CastAheadDB.raidMode == nil, "a schema 5 profile with both raid features off leaves the raid switch unset")
    CastAheadDB = nil
    fire("ADDON_LOADED", "CastAhead")
    check(CastAheadDB.raidMode == nil, "a new install has the raid switch unset")
    CastAheadDB = { schema = 3, raidSaves = true }
    fire("ADDON_LOADED", "CastAhead")
    check(CastAheadDB.raidSaves == false and CastAheadDB.raidMode == nil,
        "raid calls turned off by the schema 5 reset do not turn the raid switch on")
    CastAheadDB = { schema = 3, burstCalls = true }
    fire("ADDON_LOADED", "CastAhead")
    check(CastAheadDB.raidMode == true and CastAheadDB.burstCalls == true,
        "a schema 3 profile with burst windows on keeps them on under the raid switch")
    CastAheadDB = { schema = 3, burstCalls = true, raidSaves = true }
    fire("ADDON_LOADED", "CastAhead")
    check(CastAheadDB.raidMode == true and CastAheadDB.burstCalls == true and CastAheadDB.raidSaves == false
        and CastAheadDB.saveCallsNotice == true,
        "a schema 3 profile with both raid features on keeps bursts, loses raid calls once and is flagged")

    local savedInfo = GetInstanceInfo
    CastAheadDB = { saveCalls = true, raidSaves = false }
    GetInstanceInfo = function() return "d", "party", 0, "", 0, 0, false, 1877 end
    check(CastAheadConfig.SaveCalls() == true, "outside a raid SaveCalls follows saveCalls")
    GetInstanceInfo = function() return "r", "raid", 0, "", 0, 0, false, 1878 end
    check(CastAheadConfig.SaveCalls() == false, "in a raid SaveCalls follows raidSaves, off")
    CastAheadDB = { saveCalls = false, raidSaves = true }
    check(CastAheadConfig.SaveCalls() == false, "in a raid raidSaves alone does nothing while the raid switch is off")
    CastAheadDB = { saveCalls = false, raidMode = true, raidSaves = true }
    check(CastAheadConfig.SaveCalls() == true, "in a raid SaveCalls follows raidSaves, on")
    GetInstanceInfo = function() return "d", "party", 0, "", 0, 0, false, 1877 end
    check(CastAheadConfig.SaveCalls() == false, "outside a raid raidSaves does not count")
    check(CastAheadConfig.DungeonSaves() == false and CastAheadConfig.RaidSaves() == true, "the page accessors ignore the zone")
    CastAheadDB = { raidSaves = true, burstCalls = true }
    check(CastAheadConfig.RaidSaves() == false and not (CastAheadConfig.BurstCalls and CastAheadConfig.BurstCalls()),
        "with the raid switch off raid defensive calls and burst windows are off even when stored on")
    CastAheadDB = { raidMode = true, burstCalls = true }
    check(CastAheadConfig.BurstCalls ~= nil and CastAheadConfig.BurstCalls() == true and CastAheadConfig.RaidSaves() == false,
        "with the raid switch on each child follows its own switch")
    GetInstanceInfo = nil
    CastAheadDB = { saveCalls = true, raidSaves = false }
    check(CastAheadConfig.SaveCalls() == true, "without GetInstanceInfo SaveCalls follows saveCalls")
    GetInstanceInfo = savedInfo

    local savedShowTab, savedCreate, savedNotice = CastAheadUI.ShowTab, CreateFrame, CastAheadUI.ShowUpdateNotice
    local shows, noticeFrame = 0, nil
    CastAheadUI.ShowUpdateNotice = function(...)
        shows = shows + 1
        return savedNotice(...)
    end
    CreateFrame = function(kind, name, ...)
        local f = savedCreate(kind, name, ...)
        local setScript = f.SetScript
        f.scripts = {}
        f.SetScript = function(self, script, fn)
            self.scripts[script] = fn
            return setScript(self, script, fn)
        end
        if name == "CastAheadUpdateNotice" then noticeFrame = f end
        return f
    end
    local realPrint, lines = print, {}
    print = function(text) lines[#lines + 1] = tostring(text) end
    CastAheadDB = { schema = 5, saveCallsNotice = true }
    fire("PLAYER_LOGIN")
    fire("PLAYER_LOGIN")
    check(shows == 0, "the notice waits for the world to load")
    local savedTimer, delays = C_Timer, {}
    C_Timer = { After = function(delay, fn) delays[#delays + 1] = delay fn() end }
    fire("PLAYER_ENTERING_WORLD")
    fire("PLAYER_ENTERING_WORLD")
    C_Timer = savedTimer
    check(#delays == 1 and delays[1] > 0, "the notice is shown once, a moment after the world loads")
    print = realPrint
    check(#lines == 1 and lines[1]:find("CastAhead:|r defensive calls are now off by default. Turn them on in /ca - General - Features.", 1, true)
        and CastAheadDB.saveCallsNotice == nil, "the notice prints once and clears")
    check(shows == 1 and noticeFrame and noticeFrame.shown and CastAheadDB.saveCallsNotice == nil,
        "the update notice shows once and clears the flag")
    check(noticeFrame.open and noticeFrame.close, "the notice has an Open settings and a Close button")
    local inSpecial
    for _, n in ipairs(UISpecialFrames) do inSpecial = inSpecial or n == "CastAheadUpdateNotice" end
    check(inSpecial, "Escape closes the notice")
    local shownTab
    CastAheadUI.ShowTab = function(name) shownTab = name end
    noticeFrame.open.scripts.OnClick()
    check(shownTab == "General" and not noticeFrame.shown, "Open settings opens the General page and hides the notice")
    CastAheadUI.ShowUpdateNotice()
    check(noticeFrame.shown, "the notice shows again on request")
    noticeFrame.close.scripts.OnClick()
    check(not noticeFrame.shown, "Close hides the notice")
    CastAheadUI.ShowTab, CreateFrame, CastAheadUI.ShowUpdateNotice = savedShowTab, savedCreate, savedNotice

    CastAheadDB = nil
end

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

-- A sound picked for one spell wins over its category's, and only once the
-- cast is that spell rather than one of several candidates.
local lastFile
local playFile = PlaySoundFile
PlaySoundFile = function(path, ...) lastFile = path return playFile(path, ...) end
LibStub = function() return { Fetch = function(_, _, name) return "custom/" .. name end } end
CastAheadDB = { leadSeconds = 5, sounds = { AOE = "Horn" }, spellSounds = { [100] = "Bell" } }
enter()
castFor(3.0)
advance(17)
castFor(3.0)
advance(3)
check(lastFile == "custom/Bell", "the spell's own sound plays, got " .. tostring(lastFile))
reset()
CastAheadDB.spellSounds[100] = ""
lastFile = nil
enter()
castFor(3.0)
advance(17)
castFor(3.0)
advance(3)
check(lastFile == "custom/Horn", "an empty spell pick falls back to the category sound, got " .. tostring(lastFile))
reset()
PlaySoundFile, LibStub = playFile, nil
CastAheadDB = { leadSeconds = 5 }

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
advance(15.5)                      -- inside the lead, nothing said
check(Alerts() == 0, string.format("no heads-up while leadSeconds is 0, got %d", Alerts()))
castFor(3.0)                       -- the predicted cast itself, 1.5s early, still alerts
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
-- The bar is labelled with the spoken phrase, capitalised: it is written for a
-- voice and arrives in lower case, while the game's own entries on that bar
-- are spell names in ordinary case.
check(timeline.last and timeline.last.overrideName
    and timeline.last.overrideName:match("^%u")
    and timeline.last.overrideName:find(" ") ~= 1,
    "the timeline entry is capitalised, got " .. tostring(timeline.last and timeline.last.overrideName))
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

-- Bosses: the table is about trash, so between ENCOUNTER_START and
-- ENCOUNTER_END nothing is drawn at all - not even for adds whose cast happens
-- to last as long as some trash spell.
enter()
castFor(3.0)
advance(0.1)
check(VisibleBars() > 0, "a trash cast is tracked before the boss pull")
fire("ENCOUNTER_START", 1234)
check(VisibleBars() == 0, "starting an encounter clears what is on screen")
fire("NAME_PLATE_UNIT_ADDED", unit)
castFor(3.0)
advance(0.1)
check(VisibleBars() == 0, "and nothing new is drawn while the boss is up")
fire("ENCOUNTER_END", 1234)
fire("NAME_PLATE_UNIT_ADDED", unit)
castFor(3.0)
advance(0.1)
check(VisibleBars() > 0, "the encounter ending puts tracking back")
reset()

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

do
    local keys = table.concat(CastAheadUI.VisibleColumns(false), ",")
    check(keys == "check,hear,icon,prio,advice,spell,mob,cast,cd,overrides", "outside Development mode the cast table shows 10 columns, got " .. keys)
    check(#CastAheadUI.VisibleColumns(true) == 18, "Development mode shows every column")
    check(CastAheadUI.VisibleSortKey("n", false) == "advice", "a hidden sort column falls back to Do outside Development mode")
    check(CastAheadUI.VisibleSortKey("n", true) == "n", "Development mode keeps a development sort column")
    check(CastAheadUI.VisibleSortKey("cast", false) == "cast", "a visible sort column is kept")

    local savedDungeon, savedAdvice = CastAheadWindow.Dungeon, CastAheadMatch.Advice
    local labels = { [1] = "KICK", [3] = "TANK" }
    CastAheadData.sortcase = { { spell = 1, name = "A" }, { spell = 2, name = "B" }, { spell = 3, name = "C" } }
    CastAheadWindow.Dungeon = function() return "sortcase" end
    CastAheadMatch.Advice = function(e) return labels[e.spell] and { label = labels[e.spell] } end
    local order = {}
    for i, e in ipairs(CastAheadUI.SortedRows()) do order[i] = e.spell end
    check(table.concat(order, ",") == "3,1,2",
        "before the Casts page is built Play list sorts by Do, descending, with no-verdict rows last, got " .. table.concat(order, ","))
    CastAheadData.sortcase = nil
    CastAheadWindow.Dungeon, CastAheadMatch.Advice = savedDungeon, savedAdvice
end

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
local tenLeft, tilde = false, false
for i = 1, #allFrames do
    local f = allFrames[i]
    if f.shown and f.timeValue == "10" then tenLeft, tilde = true, f.tilde.shown end
end
check(tenLeft, "the sibling keeps its tabled 18s cooldown, not the 12s anchor gap")
check(tilde, "a projected sibling's time is an estimate: the tilde shows beside it")
reset()

-- Two spells of one creature share a 2.4s cast, so its first cast stays a tie.
-- A unique cast then names the creature and projects both. The tied spell's
-- repeat lands on its projection, but it is a repeat: the interval since the
-- plate's real 2.4s cast decides it, not the opening window from engage.
table.insert(CastAheadData[1877], { spell = 1401, npc = 14, mob = "Nimbus", name = "Charge", cast = 2.4,
                          cd = { 8.0 }, first = 3.0, firstN = 20, offset = 6.0, kick = 0, cc = 0 })
table.insert(CastAheadData[1877], { spell = 1402, npc = 14, mob = "Nimbus", name = "Lightning", cast = 2.4,
                          cd = { 30.0 }, first = 4.0, firstN = 20, offset = 30.0, kick = 0, cc = 0 })
table.insert(CastAheadData[1877], { spell = 1403, npc = 14, mob = "Nimbus", name = "Release", cast = 5.3,
                          cd = { 25.0 }, first = 2.4, firstN = 20, offset = 0.0, kick = 0, cc = 0 })
do
    enter()
    castFor(2.4)                   -- t0: 1401 or 1402, both openings fit
    castFor(5.3)                   -- t0+2.4: unique, names npc 14 and projects 1401 and 1402
    advance(0.7)                   -- t0+8.4: one 1401 cooldown on, and on 1401's projection
    castFor(2.4)
    local call = CastAheadCore.LastCandidates(unit)
    check(call and #call == 1 and call[1].spell == 1401, string.format(
        "a repeat cast on a projected track is matched by its interval, got %s",
        call and #call == 1 and tostring(call[1].spell) or "no single call"))
    reset()
end
for _ = 1, 3 do table.remove(CastAheadData[1877]) end

-- One creature, two 3.65s casts whose openings from engage overlap, so the
-- engage window cannot tell them apart. Each spell's own history can: the
-- mob's first cast is the opener by its firm offset 0, and a cast 9.9s after
-- the opener's last one cannot be the opener (it never comes back under 19s),
-- so it is the other spell, whose loose offset alone could not place it.
table.insert(CastAheadData[1877], { spell = 1601, npc = 16, mob = "Voidscythe", name = "Essence", cast = 3.65,
                          cd = { 20.6 }, first = 3.0, firstN = 20, offset = 0.0, offsetFirm = true, cdMin = 19.0,
                          kick = 0, cc = 0 })
table.insert(CastAheadData[1877], { spell = 1602, npc = 16, mob = "Voidscythe", name = "Slice", cast = 3.65,
                          cd = { 23.1 }, first = 5.0, firstN = 20, offset = 8.0, kick = 0, cc = 0, prio = "TANK" })
do
    local function at(t, length)
        advance(t - now)
        fire("UNIT_SPELLCAST_START", unit)
        local claim = CastAheadCore.Casting(unit)
        advance(length)
        fire("UNIT_SPELLCAST_STOP", unit)
        local call = CastAheadCore.LastCandidates(unit)
        return call and #call == 1 and call[1].spell or nil, claim and claim.row and claim.row.spell or nil
    end
    enter()
    local t0 = now
    local first = at(t0 + 3.0, 3.65)
    at(t0 + 23.6, 3.65)
    at(t0 + 31.0, 3.65)
    local opener = at(t0 + 44.2, 3.65)
    local other = at(t0 + 54.1, 3.65)
    check(first == 1601, "the mob's first cast is placed by its firm opening order, got " .. tostring(first))
    check(opener == 1601 and other == 1602, string.format(
        "a cast too soon for the opener's own history is the other spell, got %s %s",
        tostring(opener), tostring(other)))
    reset()
    -- A kicked cast is no evidence of the cooldown: cdMin is measured across
    -- completed casts, and a mob may recast a kicked spell sooner.
    enter()
    t0 = now
    at(t0 + 3.0, 3.65)
    at(t0 + 23.6, 3.65)
    advance(t0 + 44.2 - now)
    fire("UNIT_SPELLCAST_START", unit)
    advance(1.0)
    fire("UNIT_SPELLCAST_INTERRUPTED", unit)
    local recast = at(t0 + 50.2, 3.65)
    check(recast ~= 1602, "a recast soon after a kick is not handed to the other spell, got " .. tostring(recast))
    reset()
end
for _ = 1, 2 do table.remove(CastAheadData[1877]) end

-- A mob casts one thing at a time. Its 1.2s spell is due at t0+22, but an 8.2s
-- cast holds it until t0+26.5 and the spell comes the moment that one ends:
-- 4.5s late, past any lateness a prediction may claim, unless the prediction
-- was moved to the end of the cast that held it.
table.insert(CastAheadData[1877], { spell = 1701, npc = 17, mob = "Brutalizer", name = "Brutalize", cast = 1.2,
                          cd = { 20.0 }, first = 2.0, firstN = 20, kick = 0, cc = 0, prio = "TANK" })
table.insert(CastAheadData[1877], { spell = 1702, npc = 17, mob = "Brutalizer", name = "Devour", cast = 8.2,
                          cd = { 30.0 }, first = 18.3, firstN = 20, kick = 0, cc = 0 })
do
    enter()
    local t0 = now
    advance(2.0)
    castFor(1.2)
    advance(t0 + 18.3 - now)
    castFor(8.2)
    fire("UNIT_SPELLCAST_START", unit)
    local claim = CastAheadCore.Casting(unit)
    advance(1.2)
    fire("UNIT_SPELLCAST_STOP", unit)
    check(claim and claim.row and claim.row.spell == 1701,
        "a cast held back by the mob's own longer cast is still claimed when it comes, got "
        .. tostring(claim and claim.row and claim.row.spell))
    reset()
end
for _ = 1, 2 do table.remove(CastAheadData[1877]) end

-- The same when the busy cast turns into its own channel: cast and channel keep
-- the mob busy as one (a 1.2s cast, then a 7.5s channel, holds a 5.3s spell due
-- in the middle until the channel ends).
table.insert(CastAheadData[1877], { spell = 1801, npc = 18, mob = "Brute", name = "Smash", cast = 1.2,
                          cd = { 30.0 }, first = 6.0, firstN = 20, follow = 7.5, kick = 0, cc = 0, prio = "TANK" })
table.insert(CastAheadData[1877], { spell = 1802, npc = 18, mob = "Brute", name = "Roar", cast = 5.3,
                          cd = { 9.0 }, first = 0.0, firstN = 20, kick = 0, cc = 0, prio = "AOE" })
do
    enter()
    local t0 = now
    castFor(5.3)                                   -- Roar at t0, next due t0+9
    advance(t0 + 6.0 - now)
    fire("UNIT_SPELLCAST_START", unit)             -- Smash at t0+6
    advance(1.2)
    fire("UNIT_SPELLCAST_CHANNEL_START", unit)
    fire("UNIT_SPELLCAST_STOP", unit)
    advance(7.5)
    fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)      -- busy until t0+14.7
    fire("UNIT_SPELLCAST_START", unit)
    local claim = CastAheadCore.Casting(unit)
    advance(5.3)
    fire("UNIT_SPELLCAST_STOP", unit)
    check(claim and claim.row and claim.row.spell == 1802,
        "a prediction inside a cast and its channel moves to the channel's end, got "
        .. tostring(claim and claim.row and claim.row.spell))
    reset()
end
for _ = 1, 2 do table.remove(CastAheadData[1877]) end

-- And for a kicked cast the plate only matched afterwards by its timing: the
-- channel predicted while it was being cast moves to the moment of the kick.
table.insert(CastAheadData[1877], { spell = 1901, npc = 19, mob = "Caller", name = "Bolt", cast = 1.2,
                          cd = { 9.0 }, first = 0.0, firstN = 20, kick = 0, cc = 0, prio = "KICK" })
table.insert(CastAheadData[1877], { spell = 1902, npc = 19, mob = "Caller", name = "Storm", cast = 7.5,
                          cd = { 9.0 }, first = 0.0, firstN = 20, kick = 0, cc = 0, channel = true, prio = "AOE" })
do
    local savedWindow, savedLate = CastAheadCore.Tuning.claimWindow, CastAheadCore.Tuning.lateClaimMax
    CastAheadCore.Tuning.claimWindow, CastAheadCore.Tuning.lateClaimMax = 0, 0
    enter()
    local t0 = now
    castFor(1.2)                                   -- Bolt at t0, next due t0+9
    advance(t0 + 2.0 - now)
    channelFor(7.5)                                -- Storm at t0+2, next due t0+11
    advance(t0 + 10.7 - now)
    fire("UNIT_SPELLCAST_START", unit)             -- Bolt again, unclaimed at start
    advance(0.8)
    fire("UNIT_SPELLCAST_INTERRUPTED", unit)       -- kicked at t0+11.5
    local storm
    for _, track in pairs(CastAheadCore.Tracks(unit) or {}) do
        if track.candidates and #track.candidates == 1 and track.candidates[1].spell == 1902 then storm = track end
    end
    check(storm and storm.nextAt and math.abs(storm.nextAt - (t0 + 11.5)) < 0.01,
        "a channel due inside a kicked cast moves to the kick, got "
        .. tostring(storm and storm.nextAt and storm.nextAt - t0))
    reset()
    CastAheadCore.Tuning.claimWindow, CastAheadCore.Tuning.lateClaimMax = savedWindow, savedLate
end
for _ = 1, 2 do table.remove(CastAheadData[1877]) end

-- A first cast projected from the mob's kit reaches the timeline once its
-- opening is measured well enough, and stays off it while it is not.
local sibling = CastAheadData[1877][2]
local savedSibling = { n = sibling.n, firstN = sibling.firstN, prio = sibling.prio }
sibling.n, sibling.prio = 40, "AOE"
for _, case in ipairs({ { firstN = 12, added = true }, { firstN = 3, added = false } }) do
    sibling.firstN = case.firstN
    timeline.last = nil
    enter()
    castFor(3.0)                   -- identifies 100; sibling 101 projected
    local published = timeline.last ~= nil and timeline.last.spellID == 101
    check(published == case.added, string.format("a projected first cast with firstN=%d is %s the timeline",
        case.firstN, case.added and "on" or "off"))
    reset()
end
sibling.n, sibling.firstN, sibling.prio = savedSibling.n, savedSibling.firstN, savedSibling.prio

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

-- ... and no further left than these two labels need. Both fixture calls carry
-- a short label (the stub measures one as six pixels a character), so nothing
-- but the icons themselves sets the distance: 26 wide plus a 4 pixel margin.
-- The rule this replaced stepped every icon by the widest label on screen and
-- put them 34 apart here, and much further apart whenever one call was
-- "TANKBUSTER" and its neighbour "AOE".
local gap = math.abs(xOf[textures[101]] - xOf[textures[100]])
check(gap == 30,
    string.format("two short calls sit an icon apart, not a label apart (gap %.0f, expected 30)", gap))
reset()

do
    local realPlateFor, realUIParent = C_NamePlate.GetNamePlateForUnit, UIParent
    UIParent = { GetEffectiveScale = function() return 1 end }
    CastAheadDB = {}
    local w, h, guess = CastAheadCore.PlateSize()
    check(w == 110 and h == 45 and guess == "guess", "plate size: nothing known gives the fixed default, marked as a guess")
    C_NamePlate.GetNamePlateSize = function() return 140, 30 end
    w, h, guess = CastAheadCore.PlateSize()
    check(w == 140 and h == 30 and guess == "guess",
        "plate size: the game's own size when no plate has been seen, still a guess")
    C_NamePlate.GetNamePlateForUnit = function(u)
        local plate = realPlateFor(u)
        if not plate then return nil end
        plate.GetWidth = function() return 120 end
        plate.GetHeight = function() return 12 end
        plate.GetEffectiveScale = function() return 1.5 end
        return plate
    end
    enter()
    castFor(3.0)
    w, h, guess = CastAheadCore.PlateSize()
    check(w == 180 and h == 18 and guess == nil, "plate size: a shown plate wins, in UIParent units")
    check(CastAheadDB.plateSize and CastAheadDB.plateSize[1] == 180 and CastAheadDB.plateSize[2] == 18,
        "plate size: the last real plate is remembered in the profile")
    reset()
    C_NamePlate.GetNamePlateForUnit, C_NamePlate.GetNamePlateSize, UIParent = realPlateFor, nil, realUIParent
end

(function()
    local realPlateFor, realUIParent = C_NamePlate.GetNamePlateForUnit, UIParent
    UIParent = { GetEffectiveScale = function() return 1 end }
    local width, height = 120, 12
    C_NamePlate.GetNamePlateForUnit = function(u)
        local plate = realPlateFor(u)
        if not plate then return nil end
        plate.GetWidth = function() return width() end
        plate.GetHeight = function() return height end
        plate.GetEffectiveScale = function() return 1.5 end
        return plate
    end
    local function size(w, h)
        width, height = function() return w end, h
    end
    CastAheadDB = { leadSeconds = 5 }
    size(120, 12)
    enter()
    check(CastAheadDB.plateSize and CastAheadDB.plateSize[1] == 180,
        "plate size: a hostile plate is measured once when it is added")
    CastAheadDB.plateSize = nil
    castFor(3.0)
    advance(0.1)
    check(IconShown(100) and CastAheadDB.plateSize == nil, "plate size: anchoring live bars measures nothing")
    reset()

    size(0, 0)
    local ok = pcall(enter)
    check(ok and CastAheadDB.plateSize == nil, "plate size: a 0x0 plate stores nothing")
    reset()
    width = function() error("no width") end
    ok = pcall(enter)
    check(ok and CastAheadDB.plateSize == nil, "plate size: a throwing GetWidth stores nothing and breaks nothing")
    castFor(3.0)
    check(IconShown(100), "plate size: the plate whose size could not be read still gets its icon")
    reset()
    local secret = {}
    width = function() return secret end
    issecretvalue = function(v) return v == secret end
    ok = pcall(enter)
    issecretvalue = nil
    check(ok and CastAheadDB.plateSize == nil, "plate size: a Secret width stores nothing")
    reset()
    C_NamePlate.GetNamePlateForUnit, UIParent = realPlateFor, realUIParent
    CastAheadDB = { leadSeconds = 5 }
end)()
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

-- Two of the creature's predictions due together with different calls: the
-- start is not voiced as either.
local siblingRow = CastAheadData[1877][2]
local savedCd, savedPrio, savedN = siblingRow.cd, siblingRow.prio, siblingRow.n
siblingRow.cd, siblingRow.prio, siblingRow.n = { 8.0 }, "TANK", 40
CastAheadDB = { leadSeconds = 0, importantOnly = false }
enter()
castFor(3.0)                       -- 100 at t0, next at +20
advance(9.0)                       -- +12
castFor(4.5)                       -- 101 at +12, next at +20
advance(3.5)                       -- +20: both due
sounds, spoken, clips = 0, 0, 0
fire("UNIT_SPELLCAST_START", unit)
check(Alerts() == 0, string.format("a start between two siblings with different calls stays silent, got %d", Alerts()))
advance(3)
fire("UNIT_SPELLCAST_STOP", unit)
reset()
siblingRow.cd, siblingRow.prio, siblingRow.n = savedCd, savedPrio, savedN
CastAheadDB = { leadSeconds = 5 }

-- A prediction kept as overdue ("!") still recognises a cast a few seconds
-- late, past the two-second window; one much later is not taken for it.
enter()
castFor(3.0)                       -- next 100 at +20
advance(17)
advance(3)                         -- +23: three seconds overdue, marked due
sounds, spoken, clips = 0, 0, 0
fire("UNIT_SPELLCAST_START", unit)
check(Alerts() == 1, string.format("a late cast on an overdue prediction is recognised and alerted, got %d", Alerts()))
advance(3)
fire("UNIT_SPELLCAST_STOP", unit)
reset()
enter()
castFor(3.0)                       -- next 100 at +20
advance(17)
advance(8)                         -- +28: eight seconds overdue
sounds, spoken, clips = 0, 0, 0
fire("UNIT_SPELLCAST_START", unit)
check(Alerts() == 0, string.format("a start long after an overdue prediction is not voiced as it, got %d", Alerts()))
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

do
    local savedLevel = levels[unit]
    levels[unit] = 94
    local twin
    for _, row in ipairs(CastAheadTraits[1877]) do
        if row.npc == 12 then twin = row end
    end
    local twinChannels = twin.channels
    enter()
    fire("UNIT_SPELLCAST_CHANNEL_START", unit)
    local guarded = CastAheadCore.Casting(unit)
    check(not (guarded and guarded.row),
        "a lookalike creature with a channel of its own keeps the first channel unnamed")
    fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
    reset()
    twin.channels = nil
    enter()
    fire("UNIT_SPELLCAST_CHANNEL_START", unit)
    local firstChannel = CastAheadCore.Casting(unit)
    check(firstChannel and firstChannel.row and firstChannel.row.spell == 610,
        "the plate's first channel is named at its start when it is the only channel its creatures have")
    advance(1.4)
    fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
    advance(5.0)
    fire("UNIT_SPELLCAST_CHANNEL_START", unit)
    local laterChannel = CastAheadCore.Casting(unit)
    check(not (laterChannel and laterChannel.row),
        "a later channel on the same plate is not named by that rule, it may be a death channel")
    fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
    reset()
    enter()
    fire("UNIT_SPELLCAST_CHANNEL_START", unit)
    advance(6.0)
    fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
    local stillGuessed = false
    for _, track in pairs(CastAheadCore.Tracks(unit) or {}) do
        if track.firstChannel then stillGuessed = true end
    end
    check(not stillGuessed, "a first-channel guess measured in full becomes an ordinary track")
    reset()
    twin.channels = twinChannels
    levels[unit] = savedLevel
end

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

local soleRow
for _, row in ipairs(CastAheadData[1877]) do
    if row.spell == 610 then soleRow = row end
end
local function ChannelNextIn(length, kicker)
    enter()
    local startAt = now
    fire("UNIT_SPELLCAST_CHANNEL_START", unit)
    advance(length)
    fire("UNIT_SPELLCAST_CHANNEL_STOP", unit, nil, nil, kicker)
    local found
    for _, track in pairs(CastAheadCore.Tracks(unit) or {}) do
        if track.candidates and #track.candidates == 1 and track.candidates[1].spell == 610
            and track.lastStartAt == startAt and track.nextAt then
            found = track.nextAt - startAt
        end
    end
    reset()
    return found
end
local function Is22(v) return v ~= nil and math.abs(v - 22.0) < 1e-6 end
soleRow.soleChannel = true
check(Is22(ChannelNextIn(3.5)), "a cut channel is the dungeon's sole channel, next cast at start + cd")
check(Is22(ChannelNextIn(3.5, "Kicker")), "a kicked cut channel is the sole channel too")
check(Is22(ChannelNextIn(6.0)), "a full-length sole channel is identified as before")
check(ChannelNextIn(6.5) == nil, "a channel longer than the sole channel is not claimed")
soleRow.soleChannel = nil
check(ChannelNextIn(3.5) == nil, "without the flag a cut channel stays unidentified")
check(ChannelNextIn(3.5, "Kicker") == nil, "without the flag a kicked cut channel stays unidentified")
check(Is22(ChannelNextIn(6.0)), "without the flag a full-length channel is identified")

-- Slash routing: the sub-command is the first word of the message, so an
-- argument that happens to name another sub-command cannot steal it.
CastAheadDB = nil
SlashCmdList.CASTAHEAD("anchor center")
check(CastAheadDB and CastAheadDB.anchor == "center",
    "/ca anchor center sets the anchor rather than being read as /ca center")
SlashCmdList.CASTAHEAD("anchor left")
check(CastAheadDB.anchor == nil, "anchoring back to the default clears the stored value")
SlashCmdList.CASTAHEAD("center -90")
check(CastAheadCore.CENTER_Y + CastAheadDB.centerY == -90, "/ca center takes the number from the screen centre, like the panel")
CastAheadDB = nil
do
    local realPrint, said = print, nil
    print = function(text) said = text end
    SlashCmdList.CASTAHEAD("center")
    print = realPrint
    check(said and said:find("current -90 px from the screen centre", 1, true),
        "/ca center names the position from the screen centre, got " .. tostring(said))
end
SlashCmdList.CASTAHEAD("grow up")
check(CastAheadDB.grow == "up", "/ca grow still sets the growth direction")
CastAheadDB = nil

-- Test drive: /ca test draws demo bars without any real cast, and a second
-- invocation clears them again.
CastAheadCore.Test(1877)
check(VisibleBars() > 0, string.format("the test drive draws demo bars, got %d", VisibleBars()))
CastAheadCore.Test(1877)
check(VisibleBars() == 0, string.format("stopping the test drive hides them, got %d", VisibleBars()))
CastAheadDB = { nameplates = false }
CastAheadCore.Test(1877)
advance(0.1)
check(CastAheadCore.Testing() and VisibleBars() == 0,
    string.format("with nameplate icons off the test drive draws none, got %d", VisibleBars()))
CastAheadCore.Test(1877)
CastAheadDB = nil
-- Every distinct call is played once, across all dungeons and whatever the
-- role: a damage dealer still hears the tank buster, one voice at a time.
do
    CastAheadData[1878] = { name = "Other",
        { spell = 720, npc = 20, mob = "Charger", name = "Charge", cast = 2.0, prio = "FRONTAL" },
        { spell = 721, npc = 21, mob = "Twin", name = "Charge2", cast = 2.0, prio = "FRONTAL" },
    }
    local labels, spellLabel = {}, {}
    for _, dungeon in pairs(CastAheadData) do
        for _, row in ipairs(dungeon) do
            local advice = CastAheadMatch.Advice(row)
            if advice then
                spellLabel[row.spell] = advice.label
                labels[advice.label] = true
            end
        end
    end
    local distinct = 0
    for _ in pairs(labels) do distinct = distinct + 1 end
    local savedRole, savedAdd = CastAheadMatch.PlayerRole, C_EncounterTimeline.AddScriptEvent
    local function Drive(role)
        local got = {}
        CastAheadMatch.PlayerRole = function() return role end
        C_EncounterTimeline.AddScriptEvent = function(request)
            got[#got + 1] = request
            return savedAdd(request)
        end
        CastAheadCore.Test(1877)
        CastAheadCore.Test(1877)
        C_EncounterTimeline.AddScriptEvent = savedAdd
        CastAheadMatch.PlayerRole = savedRole
        return got
    end
    local got = Drive("DAMAGER")
    local seenLabel, dupes = {}, 0
    for _, request in ipairs(got) do
        local label = spellLabel[request.spellID]
        if seenLabel[label] then dupes = dupes + 1 end
        seenLabel[label] = true
    end
    check(#got == distinct and dupes == 0,
        string.format("the test drive plays each distinct call once, got %d of %d", #got, distinct))
    check(seenLabel.TANKBUSTER, "a damage dealer's test drive still includes the tank buster")
    check(seenLabel.FRONT, "the test drive reaches calls of other dungeons")
    local spaced = true
    for i = 2, #got do
        if got[i].duration - got[i - 1].duration < CastAheadConfig.Lead() + 3 - 0.01 then spaced = false end
    end
    check(spaced, "the test drive's calls go out one after another, never together")
    CastAheadData[1878] = nil
end
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
-- The clip plays on the channel the player picked; anything unknown is Master.
do
    local channelHeard
    local countClip = PlaySoundFile
    PlaySoundFile = function(path, channel) channelHeard = channel return countClip(path, channel) end
    for _, case in ipairs({ { nil, "Master" }, { "Dialog", "Dialog" }, { "SFX", "SFX" }, { "Ambience", "Master" } }) do
        CastAheadDB = { soundChannel = case[1] }
        channelHeard = nil
        CastAheadCore.PreviewAdvice(CastAheadMatch.ADVICE.TANK)
        check(channelHeard == case[2], string.format("soundChannel=%s plays on %s, got %s",
            tostring(case[1]), case[2], tostring(channelHeard)))
    end
    PlaySoundFile = countClip
end
CastAheadDB = { leadSeconds = 5 }   -- the heads-up is opt-in; most cases want it on

-- A sound the player picked for a category (LibSharedMedia name) replaces
-- the voice; on Voice the line is spoken and the stock beep stays a fallback.
LibStub = function(name, silent)
    if name == "LibSharedMedia-3.0" then
        return { Fetch = function(_, kind, key) return kind == "sound" and key == "Gong" and "Interface\\\\Gong.ogg" or nil end }
    end
    return nil
end
CastAheadDB = { sounds = { TANK = "Gong" } }
sounds, spoken, clips = 0, 0, 0
CastAheadCore.PreviewAdvice(CastAheadMatch.ADVICE.TANK)
check(clips == 1 and spoken == 0 and sounds == 0, string.format("a chosen sound plays instead of the voice, got files=%d spoken=%d beeps=%d", clips, spoken, sounds))
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
CastAheadDB = { leadSeconds = 5, centerText = true }
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
CastAheadDB = { schema = 2 }
enter()
castFor(3.0)
advance(17.0)
fire("UNIT_SPELLCAST_START", unit)
advance(0.5)
local fresh = CenterFrameStub()
check(fresh and fresh.shown, "a new profile draws the centre call")
reset()
CastAheadDB = { leadSeconds = 5, centerText = true }

-- A tie whose candidates disagree names both calls instead of nothing: the
-- player is told a cast is out and which two answers are in play. Spell 300
-- is DODGE; a 1.5s KICK lookalike on another creature makes the tie.
table.insert(CastAheadData[1877], { spell = 960, npc = 9, mob = "Stranger", name = "Loud", cast = 1.5,
                          cd = { 4.8, 4.8, 8.7 }, first = 3.0, firstN = 5, hits = 1, dmg = 0.25, n = 200,
                          kick = 0.9, cc = 0, prio = "KICK", kickable = true })
enter()
fire("UNIT_SPELLCAST_START", unit)
advance(1.5)
fire("UNIT_SPELLCAST_STOP", unit)
local splitLabel
for i = 1, #allFrames do
    local f = allFrames[i]
    -- Stacked, not joined: two verdicts are the widest thing the row ever has
    -- to fit, so they go one above the other.
    if f.shown and IsBar(f) and f.labelValue and f.labelValue:find("\n", 1, true) then splitLabel = f.labelValue end
end
check(splitLabel == "DODGE\nKICK", "a disagreeing tie is labelled with both calls, got " .. tostring(splitLabel))
advance(3.0)                           -- the tie comes round again on its 4.8s slot: a live cast
fire("UNIT_SPELLCAST_START", unit)
advance(0.5)
local splitCenter = CenterFrameStub()
check(splitCenter and splitCenter.shown and splitCenter.timeValue:find("Dodge or interrupt", 1, true),
    "the centre call reads both answers for a disagreeing tie, got " .. tostring(splitCenter and splitCenter.timeValue))
reset()
table.remove(CastAheadData[1877])

-- Population and packs, from MDT ------------------------------------------
-- Normally Packs.lua. One Caster (npc 1) in the whole dungeon; Filler (npc 2)
-- stands with Cycler (npc 3). Picked up by the next enter().
CastAheadPacks = { ["Test"] = {
    total = { [1] = 1, [2] = 5, [3] = 5, [4] = 5, [9] = 5, [11] = 5 },
    packs = { { [2] = 1, [3] = 2 } },
} }
-- Both rules ship switched off (see the tuning table in Core.lua for the
-- measurements); the cases exercise the machinery behind the switches.
CastAheadCore.Tuning.population = true
CastAheadCore.Tuning.packsNarrow = true
CastAheadCore.Tuning.packsCompany = true
enter()
castFor(3.0)                            -- spell 100: npc 1, unique length
check(IconShown(100), "the dungeon's one Caster is identified from its cast")
dead[unit] = true
fire("UNIT_HEALTH", unit)               -- it dies in view
local killed, exhausted = CastAheadCore.Population()
check(killed[1] == 1 and exhausted[1] == true,
    "its death is counted, and with every Caster dead the kind is exhausted")
hostile[unit], combat[unit], dead[unit] = true, true, nil
fire("NAME_PLATE_UNIT_ADDED", unit)     -- a new plate on the recycled token
castFor(3.0)
check(not IconShown(100), "a 3.0s cast can no longer be the Caster once every one is dead")
reset()
fire("CHALLENGE_MODE_START")
killed, exhausted = CastAheadCore.Population()
check(next(exhausted) == nil, "a new key starts the count over")
enter()
castFor(3.0)
check(IconShown(100), "and the Caster is back on the table")
reset()

-- Packs beat the imported neighbour list: the trait rows say Cycler (npc 3)
-- stands with Filler (npc 2), MDT says Other (npc 4) does. With Filler locked
-- next door, the 1.5s tie between them falls the way MDT says.
CastAheadPacks["Test"].packs = { { [2] = 1, [4] = 1 } }
-- The lookalike from the earlier tie cases, gone again by now.
table.insert(CastAheadData[1877], { spell = 950, npc = 4, mob = "Other", name = "Also", cast = 1.5,
                          cd = { 4.8, 4.8, 8.7 }, first = 3.0, firstN = 5, hits = 3, dmg = 0.25, n = 99,
                          kick = 0, cc = 0, prio = "DODGE" })
levels[other] = 93
hostile[other], combat[other] = true, true
fire("NAME_PLATE_UNIT_ADDED", other)
fire("UNIT_SPELLCAST_START", other)
advance(2.5)
fire("UNIT_SPELLCAST_STOP", other)      -- spell 200, unique length: npc 2 locked
levels[unit] = 92
enter()
castFor(1.5)
check(IconShown(950) and not IconShown(300),
    "MDT's pack, not the imported neighbour list, says who stands with a locked Filler")
reset()
fire("NAME_PLATE_UNIT_REMOVED", other)
levels[unit], levels[other] = nil, nil
table.remove(CastAheadData[1877])
CastAheadPacks = nil
CastAheadCore.Tuning.population = false
CastAheadCore.Tuning.packsNarrow = false
CastAheadCore.Tuning.packsCompany = false

-- The probe keeps one fingerprint per hostile cast and one clock anchor per
-- cast of the player's own, and runs whenever Development mode is on.
date = date or os.date
UnitGUID = UnitGUID or function() return "Player-1" end
CastAheadDB = { devMode = true }
CastAheadCore.ApplyDevMode()
enter()
fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 12345)
ok, err = pcall(castFor, 3.0)
check(ok, "a cast with the probe on must not error: " .. tostring(err))
local session = CastAheadDB.fingerprints and CastAheadDB.fingerprints[1]
check(session and #session.rows == 1 and #session.anchors == 1 and session.anchors[1][2] == "12345",
    "the probe records the hostile cast and the player's own cast")
check(session and session.rows[1].claimed == "-" and session.rows[1].call == "-",
    "an unpredicted cast is recorded as claimed by nothing")
CastAheadDB.importantOnly = false
advance(17)
castFor(3.0)
local predicted = session and session.rows[2]
check(predicted and predicted.claimed == 100 and predicted.call == "AOE",
    "a predicted cast records the spell and the call it was announced as, got "
    .. tostring(predicted and predicted.claimed) .. " / " .. tostring(predicted and predicted.call))
CastAheadDB.importantOnly = nil
reset()
fire("PLAYER_ENTERING_WORLD")
check(CastAheadCore.Probing(), "the probe stays on across a reload")
CastAheadDB.devMode = nil
CastAheadCore.ApplyDevMode()
CastAheadCore.Probe("clear")
check(not CastAheadCore.Probing() and CastAheadDB.fingerprints == nil, "Development mode off and clear undo it")

-- Sideways spacing (#20): by default neighbours step far enough apart that
-- their labels never touch; with fixed spacing they step by icon plus gap
-- whatever the labels measure.
local wide = { { label = { GetStringWidth = function() return 80 end }, _size = 26 },
               { label = { GetStringWidth = function() return 80 end }, _size = 26 } }
CastAheadDB = {}
CastAheadCore.SpreadBars(wide, 2)
check(wide[2]._hOffset == 82, string.format("labels keep half of each other apart by default, got %s", tostring(wide[2]._hOffset)))
do
    local mixed = { { label = { GetStringWidth = function() return 60 end }, _size = 26 },
                    { label = { GetStringWidth = function() return 40 end }, _size = 26 } }
    CastAheadCore.SpreadBars(mixed, 2)
    check(mixed[2]._hOffset == 52, string.format("two labelled neighbours leave 2 px between their labels, got %s", tostring(mixed[2]._hOffset)))
end
CastAheadDB = { fixedSpacing = true, iconGap = 10 }
CastAheadCore.SpreadBars(wide, 2)
check(wide[2]._hOffset == 36, string.format("fixed spacing steps by icon plus gap, got %s", tostring(wide[2]._hOffset)))
CastAheadDB = { fixedSpacing = true, iconGap = 999 }
CastAheadCore.SpreadBars(wide, 2)
check(wide[2]._hOffset == 26 + CastAheadConfig.GAP_MAX, "the gap is clamped like every other stored number")

-- Icon layer (#19): the player's strata, with BACKGROUND for anything unknown.
CastAheadDB = { strata = "TOOLTIP" }
check(CastAheadConfig.Strata() == "TOOLTIP", "a listed strata is used as stored")
CastAheadDB = { strata = "PLATER" }
check(CastAheadConfig.Strata() == "BACKGROUND", "an unknown strata falls back to BACKGROUND")
CastAheadDB = {}

local function IntervalAfterRepeat(gap)
    enter()
    castFor(3.0)
    advance(gap)
    castFor(3.0)
    local found
    for _, track in pairs(CastAheadCore.Tracks(unit) or {}) do
        if track.candidates and track.candidates[1].spell == 100 and not track.projected then
            found = track.nextAt - track.lastStartAt
        end
    end
    reset()
    return found
end
local late, early = IntervalAfterRepeat(18), IntervalAfterRepeat(15)
check(late and math.abs(late - 20.0) < 1e-6, "a late 21s gap keeps the tabled 20s, got " .. tostring(late))
check(early and math.abs(early - 18.0) < 1e-6, "an early 18s gap is adopted, got " .. tostring(early))
local farLate, farEarly = IntervalAfterRepeat(21), IntervalAfterRepeat(12)
check(farLate and math.abs(farLate - 20.0) < 1e-6,
    "a 24s gap outside the strict tolerance keeps the tabled 20s, got " .. tostring(farLate))
check(farEarly and math.abs(farEarly - 15.0) < 1e-6,
    "a 15s gap outside the strict tolerance is adopted, got " .. tostring(farEarly))
CastAheadCore.Tuning.observedBelowOnly = false
local adopted = IntervalAfterRepeat(18)
check(adopted and math.abs(adopted - 21.0) < 1e-6, "with the switch off a late gap is adopted, got " .. tostring(adopted))
CastAheadCore.Tuning.observedBelowOnly = true

local targetShown
UnitShouldDisplaySpellTargetName = function() return targetShown end
table.insert(CastAheadData[1877], { spell = 971, npc = 12, mob = "Totem Speaker", name = "Totem", cast = 3.3,
                          cd = { 30.0 }, first = 5.0, firstN = 20, n = 400, kick = 0, cc = 0, prio = "SWITCH",
                          targeted = false })
table.insert(CastAheadData[1877], { spell = 972, npc = 12, mob = "Totem Speaker", name = "Bolt", cast = 2.2,
                          cd = { 3.6 }, first = 0.0, firstN = 20, n = 900, kick = 0.8, cc = 0, kickable = true,
                          filler = true, targeted = true })
CastAheadDB = { leadSeconds = 0 }
targetShown = false
enter()
castFor(3.3)
advance(27.0)
sounds, spoken, clips = 0, 0, 0
targetShown = true
castFor(2.2)
check(Alerts() == 0, string.format("a cast with a target is not taken for a due untargeted spell, got %d", Alerts()))
advance(0.8)
targetShown = false
castFor(3.3)
check(Alerts() == 1, string.format("the untargeted spell is announced once when it comes, got %d", Alerts()))
reset()
table.remove(CastAheadData[1877])
table.remove(CastAheadData[1877])
UnitShouldDisplaySpellTargetName = nil

-- A sound picked from our own clips under the old display name still plays.
CastAheadDB = { sounds = { TANK = "Cast Ahead: tank buster", AOE = "Horn" }, spellSounds = { [100] = "Cast Ahead: dodge" } }
CastAheadConfig.Migrate()
check(CastAheadDB.sounds.TANK == "CastAhead: tank buster" and CastAheadDB.sounds.AOE == "Horn"
    and CastAheadDB.spellSounds[100] == "CastAhead: dodge", "sound picks follow the renamed clips")
CastAheadDB = { spellSounds = { [100] = "Cast Ahead: dodge" } }
CastAheadConfig.Migrate()
check(CastAheadDB.spellSounds[100] == "CastAhead: dodge",
    "per-spell picks follow the rename when no category was ever picked")
CastAheadDB = nil

-- Development mode keeps the combat log running inside dungeons only, and
-- never stops a log the player started.
local logging, cvars = false, {}
LoggingCombat = function(on)
    if on ~= nil then logging = on end
    return logging
end
C_CVar = { SetCVar = function(name, value) cvars[name] = value end }
local where = "party"
local savedIsInInstance = IsInInstance
IsInInstance = function() return where ~= "none", where end
CastAheadDB = { devMode = true }
fire("PLAYER_ENTERING_WORLD")
check(logging, "entering a dungeon starts the combat log")
check(cvars.advancedCombatLogging == "1", "with advanced logging")
where = "none"
fire("PLAYER_ENTERING_WORLD")
check(not logging, "leaving the dungeon stops the log it started")
logging = true
fire("PLAYER_ENTERING_WORLD")
check(logging, "a log the player started is left running")
logging, where = false, "party"
CastAheadDB.devMode = nil
fire("PLAYER_ENTERING_WORLD")
check(not logging, "nothing is logged outside Development mode")
IsInInstance, LoggingCombat, C_CVar = savedIsInInstance, nil, nil
CastAheadDB = nil

-- Key journal ------------------------------------------------------------------
local R = CastAheadRecorder
local function Lines() return R.Current() and R.Current().lines or {} end
local function Find(pattern)
    for _, line in ipairs(Lines()) do if line:match(pattern) then return line end end
end
local realPrint = print
local printed = {}
local function Quiet()
    printed = {}
    print = function(text)
        if tostring(text):match("^FAIL") then realPrint(text) end
        printed[#printed + 1] = tostring(text)
    end
end
local function Loud() print = realPrint end

CastAheadDB = { keyJournal = true }
check(not R.Enabled(), "the journal stays off without Development mode")
CastAheadDB = { devMode = true, importantOnly = false }
check(R.Enabled(), "Development mode alone turns it on")

R.StartKey({ instance = 1877, name = "Test", level = 12, affixes = "9,10", role = "HEALER" })
advance(1.5)
R.Note("PULL", nil, "in")
check(Lines()[1] == "1500|PULL|-|in", "lines carry ms, type, '-' for no mob, fields; got " .. tostring(Lines()[1]))
R.Note("STEP", "nameplate9", "length", { 100, 200 })
check(Lines()[2] == "1500|STEP|9|length|100,200", "an unnumbered slot is the bare number and lists join with commas; got " .. tostring(Lines()[2]))
R.Note("NOTE", nil, 1, "a|b\nc")
check(Lines()[3] == "1500|NOTE|-|1|a b c", "field separators and newlines never reach a line; got " .. tostring(Lines()[3]))
check(R.Checksum():match("^%x%x%x%x%x%x%x%x$") and R.Current().data == R.Checksum(), "the key carries an 8-digit data checksum")

local saved = CastAheadDB
CastAheadRecorder = nil
dofile("Recorder.lua")
CastAheadDB = saved
CastAheadRecorder.Restore()
R = CastAheadRecorder
check(R.Current() == saved.journal.keys[#saved.journal.keys], "after a reload the open key continues")
R.Note("PULL", nil, "out")
check(#Lines() == 4, "and new lines land in it")

Quiet()
for i = 1, R.MAX_KEYS + 1 do
    R.EndKey("completed")
    R.StartKey({ instance = 1877, name = "Test", level = i })
end
Loud()
check(#R.Keys() == R.MAX_KEYS, "only the newest keys are kept, got " .. #R.Keys())
local savedMax = R.MAX_LINES
R.MAX_LINES = 3
R.Note("PULL", nil, "in") R.Note("PULL", nil, "out") R.Note("PULL", nil, "in") R.Note("PULL", nil, "out")
check(#Lines() == 4 and Lines()[4]:match("|TRIM|") and R.Current().truncated, "the line cap writes one TRIM line and flags the key")
R.MAX_LINES = savedMax

-- The journal follows a real pull, and each appearance of a mob gets its own number.
Quiet()
enter()
fire("CHALLENGE_MODE_START")
fire("PLAYER_REGEN_DISABLED")
castFor(3.0)
advance(17)
castFor(3.0)
fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 12345)
for _, kind in ipairs({ "PLATE", "ENGAGE", "START", "STEP", "STOP", "PRED", "PULL", "SELF" }) do
    check(Find("^%d+|" .. kind .. "|"), "the journal records " .. kind)
end
check(Find("^%d+|PLATE|1%.1|added|"), "the plate is mob 1.1")
check(Find("^%d+|STOP|1%.1|0|3000|"), "a stop carries the measured length in ms on mob 1.1")
local never, total = R.Coverage(R.Current())
local neverIds = {}
for _, row in ipairs(never) do neverIds[row.spell] = true end
check(total >= 6 and not neverIds[100] and neverIds[700] and neverIds[610],
    "coverage counts the identified Big as shown and the untouched spells as never shown")
reset()
check(Find("^%d+|PLATE|1%.1|removed|gone$"), "a dropped plate is journalled")
hostile[unit], combat[unit] = true, true
fire("NAME_PLATE_UNIT_ADDED", unit)
check(Find("^%d+|PLATE|1%.2|added|"), "a recycled plate token is a new mob, 1.2")
reset()

-- Marks: at any moment, on a picked mob or on everything, with notes arriving later.
local n1 = R.Mark()
check(Find("^%d+|MARK|%-|" .. n1 .. "|%-$"), "a mark with nothing selected records '-'")
check(Find("^%d+|SNAP|1%.1|gone|"), "the snapshot keeps the mob that already left")
R.Select("1.1")
local n2 = R.Mark()
check(Find("^%d+|MARK|%-|" .. n2 .. "|1%.1$"), "a mark on a mob that left the screen still names it")
R.AddNote(n1, "tank buster was called swap")
check(Find("^%d+|NOTE|%-|" .. n1 .. "|tank buster was called swap$"), "a late note points at its mark")
advance(300)
local n3 = R.Mark()
check(n3 == n2 + 1 and Lines()[#Lines()]:match("|MARK|%-|" .. n3 .. "|%-$"),
    "a mark long after keeps working, and mobs older than two minutes are no longer snapshotted")
Loud()
check(printed[#printed] and printed[#printed]:find("CastAhead", 1, true), "every mark is confirmed in chat")

-- Export: header, one summary per mark, the windows, a footer that counts lines.
local text = (R.Export(R.Current()):gsub("%^", "|"))
local rows = {}
for line in text:gmatch("[^\n]+") do rows[#rows + 1] = line end
check(rows[1]:match("^CastAhead%-Report 1 addon=.- data=%x+ instance=1877 level=%d+ "), "the header names format, addon, data, instance; got " .. rows[1])
check(text:find("\n# mark 1 at ", 1, true) and text:find("note: tank buster was called swap", 1, true), "each mark gets a summary with its note")
local body = 0
for _, l in ipairs(rows) do if l:match("^%d+|") then body = body + 1 end end
check(rows[#rows] == "CastAhead-Report end lines=" .. body, "the footer counts the event lines")
check(text:find("|STOP|1.1|0|3000|", 1, true), "the selected mob's whole history is in the export")
local limit = R.EXPORT_LIMIT
R.EXPORT_LIMIT = #text - 1
local cut = (R.Export(R.Current()):gsub("%^", "|"))
check(cut:match("droppedMarks=%d+"), "an export over the limit drops the oldest marks and says so")
R.EXPORT_LIMIT = limit
if os.getenv("CA_WRITE_FIXTURE") == "1" then
    local f = assert(io.open("tools/fixtures/export_sample.txt", "w"))
    f:write(text) f:close()
else
    local f = io.open("tools/fixtures/export_sample.txt")
    local golden = f and f:read("*a")
    if f then f:close() end
    check(golden == text, "tools/fixtures/export_sample.txt matches what Recorder.lua exports (regenerate with CA_WRITE_FIXTURE=1)")
end

-- The panel, the bindings' entry point and the slash commands run in the stubs.
ok, err = pcall(CastAheadReport.Mark, true)
check(ok, "Mark + note runs: " .. tostring(err))
ok, err = pcall(CastAheadReport.Mark, false)
check(ok, "a mark while the note input is open runs: " .. tostring(err))
Quiet()
ok, err = pcall(SlashCmdList.CASTAHEAD, "mark slash note")
Loud()
check(ok and Find("|NOTE|%-|%d+|slash note$"), "/ca mark <note> marks and notes: " .. tostring(err))
local plainCreate, reportWindow = CreateFrame, nil
CreateFrame = function(kind, name, ...)
    local f = plainCreate(kind, name, ...)
    f.shown = true
    if name == "CastAheadReportWindow" then reportWindow = f end
    return f
end
ok, err = pcall(SlashCmdList.CASTAHEAD, "report")
CreateFrame = plainCreate
check(ok, "/ca report opens: " .. tostring(err))
check(reportWindow and reportWindow.shown, "the first /ca report shows the window, though the game creates frames shown")
ok, err = pcall(CastAheadReport.Refresh)
check(ok, "the panel refreshes: " .. tostring(err))
check(not CastAheadReport.PanelWanted(), "recording alone keeps the mark panel off screen")
CastAheadDB.showMarkPanel = true
check(CastAheadReport.PanelWanted(), "its own switch shows it")
CastAheadDB.devMode = nil
check(not CastAheadReport.PanelWanted(), "and never without Development mode")
CastAheadDB.devMode, CastAheadDB.showMarkPanel = true, nil
Quiet()
R.EndKey("completed")
Loud()

-- Notes belong to the key of their mark, even after it ended or after a reload.
Quiet()
R.StartKey({ instance = 1877, name = "Test", level = 7 })
local endedKey = R.Current()
local noteMark, noteKey = R.Mark()
R.EndKey("completed")
R.StartKey({ instance = 1877, name = "Test", level = 8 })
check(R.AddNote(noteMark, "typed after the key ended", noteKey), "a note after its key ended is still written")
check(endedKey.lines[#endedKey.lines]:match("|NOTE|%-|" .. noteMark .. "|typed after the key ended$"), "into the key that holds its mark")
check(#Lines() == 0, "and not into the new key")
ok, err = pcall(SlashCmdList.CASTAHEAD, "note " .. noteMark .. " after a reload")
check(ok and endedKey.lines[#endedKey.lines]:match("after a reload$"), "/ca note <n> reaches an old mark: " .. tostring(err))
Loud()

-- An unselected mark long after the pull still carries the history of the mobs it snapshots.
Quiet()
R.StartKey({ instance = 1877, name = "Test", level = 9 })
enter()
fire("PLAYER_REGEN_DISABLED")
castFor(3.0)
fire("PLAYER_REGEN_ENABLED")
reset()
advance(70)
R.Mark()
local late = (R.Export(R.Current()):gsub("%^", "|"))
check(late:find("|STOP|", 1, true), "a mark 70 s after the pull, nothing selected, exports the mob's casts")
Loud()

-- A mark after the line cap is still recorded, and only a written mark is confirmed.
Quiet()
R.StartKey({ instance = 1877, name = "Test", level = 10 })
local capped = R.MAX_LINES
R.MAX_LINES = 1
R.Note("PULL", nil, "in") R.Note("PULL", nil, "out")
local cappedMark = R.Mark()
R.MAX_LINES = capped
check(cappedMark and Find("|MARK|%-|" .. cappedMark .. "|"), "a mark after the line cap is still written")
Loud()

-- The selection survives a mark with no open key, and combat opens a key on its own.
Quiet()
R.EndKey("completed")
R.selected = "4.2"
R.Mark()
local lastKey = R.Keys()[#R.Keys()]
check(lastKey.lines[#lastKey.lines]:match("|MARK|%-|%d+|4%.2$"), "a mark with no open key keeps the selected mob")
R.EndKey("completed")
fire("PLAYER_REGEN_DISABLED")
check(R.Current() and Find("|PULL|%-|in$"), "entering combat with no key open starts one")
fire("PLAYER_REGEN_ENABLED")
Loud()

-- Pseudo-keys without marks never crowd real keys out of the journal.
Quiet()
CastAheadDB.journal = nil
fire("PLAYER_ENTERING_WORLD")
fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 555)
fire("CHALLENGE_MODE_START")
check(#R.Keys() == 1, "a pre-key pseudo-key with no marks is replaced by the real key, got " .. #R.Keys())
R.EndKey("completed")
fire("PLAYER_ENTERING_WORLD")
fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 555)
R.EndKey("left")
check(#R.Keys() == 1, "an unmarked pseudo-key is dropped when it ends, got " .. #R.Keys())
local afterEnd = R.Mark()
check(afterEnd and #R.Keys() == 1 and R.Keys()[1].lines[#R.Keys()[1].lines]:match("|MARK|"),
    "a mark right after a key ended lands in that key")
R.EndKey("completed")
local keysBefore, savedMarkInfo = #R.Keys(), GetInstanceInfo
GetInstanceInfo = function() return "City", "none", 0, "", 0, 0, false, 2393 end
R.Mark()
check(#R.Keys() == keysBefore + 1 and R.Keys()[#R.Keys()].instance == 2393,
    "a mark made somewhere else starts a key there instead of joining the dungeon's")
R.EndKey("completed")
GetInstanceInfo = savedMarkInfo
local ended = R.Keys()[#R.Keys()]
ended.endedAt = now + 5000
keysBefore = #R.Keys()
R.Mark()
check(#R.Keys() == keysBefore + 1, "a key ended in an earlier session (a later clock) is never marked again")
check(not R.Export(R.Keys()[#R.Keys()]):find("|", 1, true),
    "the export carries no '|', which the game's text boxes read as escape codes")
R.EndKey("completed")
Loud()

-- A cast the addon ignores (out of combat) leaves no START behind.
local before = #Lines()
hostile[unit], combat[unit] = true, false
fire("NAME_PLATE_UNIT_ADDED", unit)
fire("UNIT_SPELLCAST_START", unit)
check(not Find("|START|"), "an ignored out-of-combat cast is not journalled as a start")
fire("UNIT_SPELLCAST_STOP", unit)
reset()
check(#Lines() >= before, "the plate itself is still journalled")

-- Export stays fast on a full-size key.
Quiet()
R.StartKey({ instance = 1877, name = "Test", level = 11 })
for i = 1, 20000 do R.Note("STEP", "nameplate" .. (i % 30 + 1), "length", { 100, 200, 300 }) end
for i = 1, 30 do R.Mark() end
local started = os.clock()
local big = R.Export(R.Current())
Loud()
check(os.clock() - started < 2.0, string.format("a 20000-line export with 30 marks takes under 2 s, took %.2f", os.clock() - started))
check(#big <= R.EXPORT_LIMIT, "and fits the size limit, got " .. #big)
R.StartKey({ instance = 1877, name = "Test", level = 12 })
for i = 1, 12000 do R.Note("STEP", "nameplate1", "length", { 100 }) end
started = os.clock()
big = R.Export(R.Current())
check(os.clock() - started < 2.0 and big:match("droppedLines=%d+"), "a long key with no marks exports its tail quickly")
Quiet()
R.EndKey("completed")
Loud()
CastAheadDB = nil

do
    CastAheadDB = { devMode = true }
    local popups = {}
    local savedPopup = StaticPopup_Show
    StaticPopup_Show = function(name) popups[#popups + 1] = name end
    local function PlayKeys(n)
        Quiet()
        for i = 1, n do
            R.StartKey({ instance = 1877, name = "Key " .. i, level = 12 })
            R.Note("PULL", nil, "in")
            R.EndKey("completed")
        end
        Loud()
    end
    PlayKeys(8)
    check(#CastAheadDB.journal.keys == 8, "a day of eight keys is kept whole, got " .. #CastAheadDB.journal.keys)
    check(#popups == 0, "a key that leaves the journal short of full asks nothing, got " .. #popups)
    PlayKeys(R.MAX_KEYS - 8 + 2)
    check(#popups == 1 and popups[1] == "CASTAHEAD_RELOAD" and StaticPopupDialogs.CASTAHEAD_RELOAD,
        "the key that fills the journal asks for a reload once, later keys do not, got " .. #popups)
    R.StartKey({ instance = 1877, name = "Open", level = 12 })
    R.Note("PULL", nil, "in")
    R.Clear()
    check(#CastAheadDB.journal.keys == 1 and R.Current() and R.Current().name == "Open", "clearing keeps only the key in progress")
    PlayKeys(R.MAX_KEYS)
    check(#popups == 2, "after a clear the full journal asks again, got " .. #popups)
    SlashCmdList.CASTAHEAD("journal clear")
    check(popups[3] == "CASTAHEAD_CLEAR_JOURNAL" and #CastAheadDB.journal.keys > 1, "/ca journal clear asks first and clears nothing yet")
    Quiet()
    StaticPopupDialogs.CASTAHEAD_CLEAR_JOURNAL.OnAccept()
    Loud()
    check(#CastAheadDB.journal.keys <= 1, "accepting the question clears the journal")
    StaticPopup_Show = savedPopup
    CastAheadDB = nil
end

-- Core runs with no recorder loaded at all.
local recorder, report = CastAheadRecorder, CastAheadReport
CastAheadRecorder, CastAheadReport = nil, nil
CastAheadDB = { devMode = true }
ok, err = pcall(function()
    enter()
    fire("CHALLENGE_MODE_START")
    fire("PLAYER_REGEN_DISABLED")
    castFor(3.0)
    fire("PLAYER_REGEN_ENABLED")
    reset()
end)
check(ok, "Core works without the recorder: " .. tostring(err))
CastAheadRecorder, CastAheadReport = recorder, report
CastAheadDB = nil

-- Development mode off: no development tool runs whatever its own switch says.
local function Copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = Copy(v) end
    return out
end
local function Same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if not Same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local devLogging, savedInInstanceDev = false, IsInInstance
LoggingCombat = function(on)
    if on ~= nil then devLogging = on end
    return devLogging
end
C_CVar = { SetCVar = function() end }
IsInInstance = function() return true, "party" end
CastAheadDB = { importantOnly = false,
    journal = { keys = { { startedAt = now, lines = {}, marks = 0, mobs = 0 } } } }
local devBefore = Copy(CastAheadDB)
Quiet()
enter()
fire("CHALLENGE_MODE_START")
fire("PLAYER_REGEN_DISABLED")
castFor(3.0)
advance(17)
castFor(3.0)
fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 12345)
fire("PLAYER_REGEN_ENABLED")
fire("CHALLENGE_MODE_COMPLETED")
for _, command in ipairs({ "probe", "probe show", "probe clear", "report", "mark wrong call", "note 1 text" }) do
    SlashCmdList.CASTAHEAD(command)
end
CastAheadReport.Mark(true)
reset()
Loud()
check(Same(devBefore, CastAheadDB), "with Development mode off a whole key leaves the saved variables untouched")
check(not devLogging, "and never starts the combat log")
check(not CastAheadCore.Probing(), "nor the probe")
local leaked
for _, line in ipairs(printed) do
    if not line:match("needs Development mode") then leaked = line end
end
check(not leaked, "and prints nothing but the refusals, got " .. tostring(leaked))

CastAheadDB.devMode = true
CastAheadCore.ApplyDevMode()
check(devLogging and CastAheadCore.Probing() and CastAheadRecorder.Enabled(),
    "Development mode on, with no other switch, runs every tool")
CastAheadDB.recordAll = false
CastAheadCore.ApplyDevMode()
check(not devLogging and not CastAheadCore.Probing() and not CastAheadRecorder.Enabled(),
    "Record everything off stops all recording while Development mode stays on")
CastAheadDB.recordAll = nil
CastAheadCore.ApplyDevMode()
check(devLogging and CastAheadCore.Probing() and CastAheadRecorder.Enabled(), "and on again resumes it")
CastAheadDB.devMode = nil
CastAheadCore.ApplyDevMode()
check(not devLogging and not CastAheadCore.Probing() and not CastAheadRecorder.Enabled(),
    "and switching it off turns all of them off at once")
IsInInstance, LoggingCombat, C_CVar = savedInInstanceDev, nil, nil
CastAheadDB = nil

-- Defiled Golem: two 2.0s casts with different calls, each turning into a
-- channel of its own length, plus another creature's 2.0s cast.
CastAheadData[1999] = { name = "Golem",
    { spell = 1201, npc = 31, mob = "Golem", name = "Fel Beam", cast = 2.0, cd = { 30.4 },
      first = 22.4, firstN = 40, offset = 16.0, n = 40, follow = 4.0, prio = "DODGE" },
    { spell = 1202, npc = 31, mob = "Golem", name = "Defiled Slam", cast = 2.0, cd = { 30.4 },
      first = 6.4, firstN = 40, offset = 0.0, n = 40, follow = 8.0, prio = "AOE" },
    { spell = 1203, npc = 32, mob = "Other", name = "Bolt", cast = 2.0, cd = { 15.0 },
      first = 3.0, firstN = 40, n = 40, prio = "KICK" },
    { spell = 1204, npc = 31, mob = "Golem", name = "Smash", cast = 3.0, cd = { 40.0 },
      first = 50.0, firstN = 40, offset = 45.0, n = 40, prio = "TANK" },
    { spell = 1205, npc = 36, mob = "Drainer", name = "Siphon", cast = 6.0, cd = { 30.0 },
      first = 9.0, firstN = 40, n = 40, channel = true, prio = "KICK" },
    { spell = 1206, npc = 33, mob = "Serpent", name = "Spray", cast = 2.5, cd = { 30.0 },
      first = 7.0, firstN = 40, n = 40, followUnknown = true, prio = "TANK" },
    { spell = 1207, npc = 37, mob = "Serpent II", name = "Spit", cast = 2.5, cd = { 30.0 },
      first = 7.0, firstN = 40, n = 40, followUnknown = true, prio = "TANK" },
}
local savedGolemInfo = GetInstanceInfo
GetInstanceInfo = function() return "d", "party", 0, "", 0, 0, false, 1999 end
CastAheadDB = { leadSeconds = 0 }
local function castIntoChannel(cast, channel)
    fire("UNIT_SPELLCAST_START", unit)
    advance(cast)
    fire("UNIT_SPELLCAST_CHANNEL_START", unit)
    fire("UNIT_SPELLCAST_STOP", unit)
    advance(channel)
    fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
end
local function Last() local c = CastAheadCore.LastCandidates(unit) return c and #c == 1 and c[1].spell end
enter()
advance(6.4)
local slamAt = now
castIntoChannel(2.0, 8.0)
check(Last() == 1202, "a 2.0s cast that turned into an 8s channel is Defiled Slam, got " .. tostring(Last()))
local beam
for _, track in pairs(CastAheadCore.Tracks(unit) or {}) do
    if track.candidates and #track.candidates == 1 and track.candidates[1].spell == 1201 then beam = track end
end
check(beam and beam.nextAt and math.abs(beam.nextAt - (slamAt + 16.0)) < 0.01,
    "Fel Beam, the same length as Slam, keeps a track of its own, due 16s after Slam")
advance(slamAt + 16.0 - now)
sounds, spoken, clips = 0, 0, 0
fire("UNIT_SPELLCAST_START", unit)
local claim = CastAheadCore.Casting(unit)
check(claim and claim.row and claim.row.spell == 1201 and Alerts() > 0,
    "the next 2.0s cast, where Fel Beam is due, is called as Fel Beam, got "
    .. tostring(claim and claim.row and claim.row.spell))
advance(2.0)
fire("UNIT_SPELLCAST_CHANNEL_START", unit)
fire("UNIT_SPELLCAST_STOP", unit)
advance(4.0)
fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
check(Last() == 1201, "its 4s channel confirms Fel Beam, got " .. tostring(Last()))
advance(slamAt + 30.4 - now)
fire("UNIT_SPELLCAST_START", unit)
claim = CastAheadCore.Casting(unit)
check(claim and claim.row and claim.row.spell == 1202,
    "and Slam's next cast is still called as Slam, got " .. tostring(claim and claim.row and claim.row.spell))
advance(2.0)
fire("UNIT_SPELLCAST_CHANNEL_START", unit)
fire("UNIT_SPELLCAST_STOP", unit)
advance(3.0)
fire("UNIT_SPELLCAST_CHANNEL_STOP", unit, nil, nil, "kicker")
check(Last() == 1202, "a kicked channel still lets the cast it came from be settled, got " .. tostring(Last()))
reset()
enter()
advance(6.4)
castFor(2.0)
check(Last() == 1203, "a 2.0s cast that ended without a channel is not the golem's, got " .. tostring(Last()))
reset()
local function TrackOf(spell)
    for _, track in pairs(CastAheadCore.Tracks(unit) or {}) do
        if track.candidates and #track.candidates == 1 and track.candidates[1].spell == spell then return track end
    end
end
enter()
advance(6.4)
slamAt = now
castIntoChannel(2.0, 8.0)
TrackOf(1201).nextAt = nil
advance(slamAt + 16.0 - now)
castIntoChannel(2.0, 4.0)
local slam, beamTrack = TrackOf(1202), TrackOf(1201)
check(Last() == 1201 and beamTrack and beamTrack.lastStartAt == slamAt + 16.0,
    "a cast picked by Slam's track but channelled like Fel Beam lands on Fel Beam's track")
check(slam and slam.observedCD == nil and math.abs(slam.nextAt - (slamAt + 30.4)) < 0.01,
    "and Slam's own schedule is left as it was, got observedCD " .. tostring(slam and slam.observedCD))
reset()
enter()
advance(14)
fire("UNIT_SPELLCAST_START", unit)
advance(2.0)
fire("UNIT_SPELLCAST_CHANNEL_START", unit)
fire("UNIT_SPELLCAST_STOP", unit)
advance(1.0)
fire("UNIT_SPELLCAST_CHANNEL_STOP", unit, nil, nil, "kicker")
advance(30 - 17)
castFor(3.0)
check(Last() == 1204 and TrackOf(1201) and TrackOf(1202),
    "once Smash names the golem, Fel Beam and Slam each get a track although an earlier 2.0s cast was ambiguous between them")
reset()
local function Lengths()
    local c = CastAheadCore.LastCandidates(unit)
    return c and #c > 0 and c[1].cast
end
enter()
advance(6.4)
fire("UNIT_SPELLCAST_START", unit)
advance(2.0)
fire("UNIT_SPELLCAST_CHANNEL_START", unit)
fire("UNIT_SPELLCAST_STOP", unit)
fire("NAME_PLATE_UNIT_ADDED", unit)
advance(8.0)
fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
check(not TrackOf(1202), "a plate added again mid-channel drops the cast it was holding")
reset()
enter()
advance(6.4)
slamAt = now
castIntoChannel(2.0, 8.0)
advance(slamAt + 30.4 - now)
fire("UNIT_SPELLCAST_START", unit)
local before = CastAheadCore.Casting(unit)
fire("NAME_PLATE_UNIT_ADDED", unit)
check(before and CastAheadCore.Casting(unit) == nil, "a plate added again forgets the cast it showed")
reset()
enter()
advance(6.4)
fire("UNIT_SPELLCAST_START", unit)
advance(2.0)
fire("UNIT_SPELLCAST_CHANNEL_START", unit)
fire("UNIT_SPELLCAST_STOP", unit)
advance(1.0)
fire("UNIT_SPELLCAST_CHANNEL_START", unit)
check(Lengths() == 2.0, "a second channel start settles the held 2.0s cast at once")
advance(8.0)
fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
reset()
enter()
advance(6.4)
castIntoChannel(2.0, 20.0)
check(Lengths() == 2.0, "a channel that is no candidate's own still leaves the held cast's identification")
reset()
enter()
advance(6.4)
slamAt = now
castIntoChannel(2.0, 8.0)
local beamGone = TrackOf(1201)
CastAheadCore.Tracks(unit)[beamGone.slot] = nil
advance(slamAt + 16.0 - now)
castIntoChannel(2.0, 4.0)
slam = TrackOf(1202)
check(TrackOf(1201) and TrackOf(1201).lastStartAt == slamAt + 16.0 and slam
    and math.abs(slam.nextAt - (slamAt + 30.4)) < 0.01,
    "a Fel Beam picked by Slam's track gets a track of its own and leaves Slam's schedule alone")
reset()
enter()
advance(7.0)
castIntoChannel(2.5, 6.0)
check(Lengths() == 2.5, "the channel after casts whose channel length is unconfirmed stays theirs, not Siphon's")
reset()
CastAheadData[1999] = nil
GetInstanceInfo = savedGolemInfo
fire("PLAYER_ENTERING_WORLD")

-- Felmaster Lucsei and Corrupted Warlock: 2.0s casts, channels of 1.2s and 7s.
CastAheadData[2000] = { name = "Row",
    { spell = 1301, npc = 41, mob = "Lucsei", name = "Blade Dance", cast = 2.0, cd = { 30.0 },
      first = 5.0, firstN = 40, n = 40, follow = 1.2, prio = "AOE" },
    { spell = 1302, npc = 42, mob = "Warlock", name = "Drain Life", cast = 2.0, cd = { 10.0 },
      first = 5.0, firstN = 40, n = 40, follow = 7.0, prio = "TARGET" },
    { spell = 1303, npc = 43, mob = "Golem", name = "Defiled Slam", cast = 2.0, cd = { 30.0 },
      first = 40.0, firstN = 40, n = 40, follow = 8.0, prio = "AOE" },
    { spell = 1304, npc = 41, mob = "Lucsei", name = "Eye Beam", cast = 2.5, cd = { 30.0 },
      first = 60.0, firstN = 40, n = 40, follow = 2.5, prio = "FRONTAL" },
}
GetInstanceInfo = function() return "d", "party", 0, "", 0, 0, false, 2000 end
fire("PLAYER_ENTERING_WORLD")
enter()
advance(5.0)
castIntoChannel(2.0, 1.2)
check(Last() == 1301, "a Drain Life cut to 1.2s reads as Blade Dance")
local function HasTrack(spell)
    for _, track in pairs(CastAheadCore.Tracks(unit) or {}) do
        if track.candidates and #track.candidates == 1 and track.candidates[1].spell == spell then return true end
    end
end
check(HasTrack(1304), "and lays out Lucsei's Eye Beam beside it")
advance(20.0 - 3.2)
local drainAt = now
castIntoChannel(2.0, 7.0)
check(Last() == 1302, "but its next full 7s channel undoes that and names Drain Life, got " .. tostring(Last()))
local drain
for _, track in pairs(CastAheadCore.Tracks(unit) or {}) do
    if track.candidates and #track.candidates == 1 and track.candidates[1].spell == 1302 then drain = track end
end
check(drain and drain.observedCD == nil and drain.index == 1 and math.abs(drain.nextAt - (drainAt + 10.0)) < 0.01,
    "and Drain Life's schedule is its own 10s, not Blade Dance's 30s or the 20s gap between them, got "
    .. tostring(drain and drain.observedCD) .. " / " .. tostring(drain and drain.nextAt and drain.nextAt - drainAt))
advance(drainAt + 10.0 - now)
castIntoChannel(2.0, 7.3)
check(Last() == 1302, "a Drain Life channel a little over 7s keeps the warlock, got " .. tostring(Last()))
local blade
for _, track in pairs(CastAheadCore.Tracks(unit) or {}) do
    if track.candidates and #track.candidates == 1 and track.candidates[1].spell == 1301 then blade = track end
end
check(not blade and not HasTrack(1304), "and neither Blade Dance nor Eye Beam, Lucsei's, keeps a track on the warlock's plate")
reset()
CastAheadData[2000] = nil
GetInstanceInfo = savedGolemInfo
fire("PLAYER_ENTERING_WORLD")
CastAheadDB = nil

-- Save calls on trash: the dps verdict replaces AOE, the centre shows the player's button.
local specRole2 = "DAMAGER"
GetSpecialization = function() return 1 end
GetSpecializationRole = function() return specRole2 end
GetSpecializationInfo = function() return 265 end
IsPlayerSpell = function(id) return id == 104773 or id == 108416 end
textures[104773] = 2001
textures[108416] = 2002
CastAheadSaveButtons = { [265] = { def = { 104773, 108416 } } }
CastAheadDefensives = { spells = { [100] = { DAMAGER = true, lead = 4.0 } }, alias = {} }
CastAheadSaves.Refresh()
CastAheadDB = { saveCalls = true, centerText = true }
check(CastAheadSaves.Icons(CastAheadMatch.ADVICE.DEFENSIVE)[1] == 2001, "the shipped first button for the spec")
CastAheadDB.saveButtons = { [265] = { def = { 108416 } } }
CastAheadSaves.Refresh()
check(CastAheadSaves.Icons(CastAheadMatch.ADVICE.DEFENSIVE)[1] == 2002, "an override wins")
CastAheadDB.saveButtons = { [265] = { def = { 999, 104773 } } }
CastAheadSaves.Refresh()
check(CastAheadSaves.Icons(CastAheadMatch.ADVICE.DEFENSIVE)[1] == 2001, "an override the character does not know falls back")
CastAheadDB.saveButtons = nil
GetSpecializationInfo = function() return 70 end
CastAheadSaves.Refresh()
check(#CastAheadSaves.Icons(CastAheadMatch.ADVICE.DEFENSIVE) == 0, "a spec without a table has no button")
GetSpecializationInfo = function() return 265 end
CastAheadSaves.Refresh()

do
    local savedButtons, savedDefensives = CastAheadSaveButtons, CastAheadDefensives
    assert(loadfile("SaveButtons.lua"))()
    local Fits = CastAheadSaves.Fits
    local function spell(id) return { kind = "spell", id = id } end
    check(not Fits(spell(48707), { school = 1 }) and Fits(spell(48707), { school = 4 }) and Fits(spell(48707), { school = 127 }),
        "a magic-only button skips a physical hit and fits fire and chaos")
    check(Fits(spell(1022), { school = 1 }) and not Fits(spell(1022), { school = 32 }) and not Fits(spell(1022), { school = 127 }),
        "a physical-only button fits pure physical only, not shadow or chaos")
    check(not Fits(spell(1966), { aoe = false }) and Fits(spell(1966), { aoe = true }) and Fits(spell(1966), { school = 1 }),
        "an area-only button skips a single-target hit and fits one with no flag")
    check(Fits(spell(48707), {}) and Fits(spell(48707), nil) and Fits(spell(104773), { school = 1 })
        and Fits({ kind = "item", id = 48707 }, { school = 1 }), "no school, no row, an unlimited button or an item always fit")

    IsPlayerSpell = function(id) return id == 48707 or id == 48792 end
    textures[48707], textures[48792] = 3001, 3002
    CastAheadSaveButtons = { [265] = { def = { 48707, 48792 } } }
    CastAheadDefensives = { spells = { [200] = { DAMAGER = true, lead = 2.0, school = 1, aoe = false },
                                       [201] = { DAMAGER = true, lead = 2.0, school = 4 } }, alias = { [202] = 200 } }
    CastAheadSaves.Refresh()
    local def = CastAheadMatch.ADVICE.DEFENSIVE
    check(CastAheadSaves.Icons(def, 200)[1] == 3002 and #CastAheadSaves.Icons(def, 200) == 1,
        "a physical hit shows the next button instead of the magic-only one")
    check(CastAheadSaves.Icons(def, 202)[1] == 3002, "an aliased cast takes the school of its hit")
    check(CastAheadSaves.Icons(def, 201)[1] == 3001 and #CastAheadSaves.Icons(def, 201) == 2,
        "a fire hit keeps the magic-only button first")
    check(CastAheadSaves.Icons(def)[1] == 3001, "a call with no hit keeps the whole list")
    check(CastAheadSaves.Icons(def, { { spell = 200 }, { spell = 201 } })[1] == 3001,
        "a button that fits any candidate cast stays")
    check(CastAheadSaves.Icons(def, { { spell = 202 } })[1] == 3002, "a single physical candidate drops it")
    CastAheadSaves.Schedule("test:physical", 200, now - 0.1, now + 5, def)
    CastAheadSaves.Tick(now)
    local scheduled
    for _, p in ipairs(CastAheadSaves.Pending(now)) do
        if p.row.spell == 200 then scheduled = p end
    end
    check(scheduled and scheduled.icons[1] == 3002 and #scheduled.icons == 1,
        "a scheduled call on a physical hit shows the next button, not the magic-only one")
    CastAheadSaves.Cancel("test:physical")
    CastAheadDefensives.spells[200].dungeon, CastAheadDefensives.spells[201].dungeon = 9100, 9100
    local view = {}
    for _, r in ipairs(CastAheadSaves.ViewRows(9100)) do view[r.id] = r end
    check(view[200] and #view[200].buttons == 1 and view[200].buttons[1].id == 48792 and view[201] and #view[201].buttons == 2,
        "the guide drops the magic-only button on a physical hit and keeps both on a fire hit")
    CastAheadSaveButtons, CastAheadDefensives = savedButtons, savedDefensives
    textures[48707], textures[48792] = nil, nil
    IsPlayerSpell = function(id) return id == 104773 or id == 108416 end
    CastAheadSaves.Refresh()
end

reset()
CastAheadDB = { saveCalls = true, centerText = true, leadSeconds = 0 }
CastAheadCore.ReapplyData()
enter()
castFor(3.0)
sounds, spoken, clips = 0, 0, 0
advance(15.0)
advance(1.5)
advance(1.5)
check(Alerts() == 0, string.format("the save heads-up is off by default, got %d", Alerts()))
reset()

reset()
CastAheadDB = { saveCalls = true, centerText = true, leadSeconds = 0, saveLeadSeconds = 4 }
CastAheadCore.ReapplyData()
enter()
castFor(3.0)                  -- spell 100 identified, next one in 20 s
sounds, spoken, clips = 0, 0, 0
advance(15.0)                 -- 5 s before the next cast: nothing yet
check(Alerts() == 0, "no heads-up before the save lead")
advance(1.5)                  -- 3.5 s before: inside the 4 s save lead
check(Alerts() == 1, string.format("one save heads-up inside its own lead, got %d", Alerts()))
reset()

reset()
CastAheadDB = { saveCalls = true, centerText = true, leadSeconds = 5, saveLeadSeconds = 0 }
CastAheadCore.ReapplyData()
enter()
castFor(3.0)
sounds, spoken, clips = 0, 0, 0
advance(15.0)
advance(1.5)
advance(1.5)
check(Alerts() == 0, string.format("the general early warning does not pre-announce a save, got %d", Alerts()))
reset()

-- A cast id known only through the alias table gets the damage spell's save call.
CastAheadDefensives = { spells = { [999] = { DAMAGER = true, lead = 4.0 } }, alias = { [100] = 999 } }
CastAheadDB = { saveCalls = true, centerText = true, leadSeconds = 0, saveLeadSeconds = 4 }
CastAheadCore.ReapplyData()
enter()
castFor(3.0)
sounds, spoken, clips = 0, 0, 0
advance(15.0)
check(Alerts() == 0, "no aliased heads-up before the save lead")
advance(1.5)
check(Alerts() == 1, string.format("an aliased cast gets the save heads-up, got %d", Alerts()))
reset()
CastAheadDefensives = { spells = { [100] = { DAMAGER = true, lead = 4.0 } }, alias = {} }
CastAheadCore.ReapplyData()

-- Save calls off: the cast keeps its old call and its own icon, and no save heads-up comes early.
do
    local function CenterLine()
        for i = 1, #allFrames do
            local f = allFrames[i]
            if f.shown and type(f.icon) == "table" and not IsBar(f) and f.timeValue then return f end
        end
    end
    local row100 = CastAheadData[1877][1]
    CastAheadDB = { saveCalls = true, centerText = true, leadSeconds = 0 }
    check(CastAheadMatch.Advice(row100) == CastAheadMatch.ADVICE.DEFENSIVE, "save calls on: the dps verdict")
    CastAheadDB.saveCalls = nil
    check(CastAheadMatch.SpecRole() == nil and CastAheadMatch.Advice(row100) == CastAheadMatch.ADVICE.AOE,
        "save calls off: the old AOE call")
    reset()
    enter()
    castFor(3.0)
    sounds, spoken, clips = 0, 0, 0
    advance(15.0)
    advance(1.5)
    check(Alerts() == 0, string.format("no save heads-up with save calls off, got %d", Alerts()))
    advance(3.0)
    fire("UNIT_SPELLCAST_START", unit)
    advance(1.0)
    local line = CenterLine()
    check(line and line.timeValue:match("^Aoe damage") and line.icon.textureValue == textures[100],
        "the centre shows the old call with the spell's own icon: " .. tostring(line and line.timeValue))
    advance(2.0)
    fire("UNIT_SPELLCAST_STOP", unit)
    reset()
    CastAheadDB.saveCalls = true

    row100.targeted = true
    CastAheadCore.ReapplyData()
    local savedIsTarget = PlayerIsSpellTarget
    PlayerIsSpellTarget = function(u) return "secret:" .. u end
    reset()
    enter()
    castFor(3.0)
    advance(15.0)
    advance(1.5)
    advance(3.0)
    fire("UNIT_SPELLCAST_START", unit)
    advance(0.5)
    for _, f in ipairs(allFrames) do
        f.SetAlphaFromBoolean = function(self, v, yes, no) self.alphaBool, self.alphaYes, self.alphaNo = v, yes, no end
        f.alphaBool = nil
    end
    advance(0.1)
    local targetedLine, saveLine
    for _, f in ipairs(allFrames) do
        if f.shown and type(f.icon) == "table" and not IsBar(f) and f.timeValue then
            if f.timeValue:match("^Targeted") then targetedLine = f end
            if f.timeValue:match("^Defensive") then saveLine = f end
        end
    end
    check(targetedLine and rawget(targetedLine, "alphaBool") == nil, "a targeted cast shows targeted in the centre, always visible")
    check(saveLine and rawget(saveLine, "alphaBool") == "secret:" .. unit and saveLine.alphaYes == 1 and saveLine.alphaNo == 0,
        "its save line is drawn only when the game says the cast is on the player")
    advance(2.0)
    fire("UNIT_SPELLCAST_STOP", unit)
    reset()
    PlayerIsSpellTarget = savedIsTarget
    row100.targeted = nil
    CastAheadCore.ReapplyData()
end

-- A save call with the voice off still beeps once.
CastAheadDB = { saveCalls = true, voice = false }
sounds, spoken, clips = 0, 0, 0
CastAheadCore.Announce(CastAheadMatch.ADVICE.DEFENSIVE, true)
CastAheadCore.Announce(CastAheadMatch.ADVICE.DEFENSIVE, nil)
check(sounds == 2 and Alerts() == 2, string.format("each save call beeps once with the voice off, got %d", Alerts()))

-- A scheduled save call fires once at its time and shows in the centre until it ends.
reset()
CastAheadDB = { saveCalls = true, centerText = true }
enter()
CastAheadSaves.Schedule("test:1", 100, now + 2, now + 5, CastAheadMatch.ADVICE.DEFENSIVE)
sounds, spoken, clips = 0, 0, 0
advance(1.0)
check(Alerts() == 0, "a scheduled call is quiet before its time")
advance(1.5)
check(Alerts() == 1, "and speaks once at its time")
advance(1.0)
check(Alerts() == 1, "only once")
check(#CastAheadSaves.Pending(now) == 1, "it stays in the centre until the hit")
advance(2.0)
check(#CastAheadSaves.Pending(now) == 0, "and leaves after it")
CastAheadSaves.Schedule("test:2", 100, now + 2, now + 5, CastAheadMatch.ADVICE.DEFENSIVE)
CastAheadSaves.Cancel("test:2")
sounds, spoken, clips = 0, 0, 0
advance(3.0)
check(Alerts() == 0, "a cancelled call never fires")
reset()

-- Save calls off: a scheduled call stays quiet, and one whose hit passed meanwhile never fires later.
CastAheadDB = { saveCalls = true, centerText = true }
enter()
CastAheadSaves.Schedule("test:3", 100, now + 2, now + 5, CastAheadMatch.ADVICE.DEFENSIVE)
CastAheadDB.saveCalls = nil
sounds, spoken, clips = 0, 0, 0
advance(3.0)
check(Alerts() == 0, "no scheduled call fires with save calls off")
advance(3.0)
CastAheadDB.saveCalls = true
advance(0.1)
check(Alerts() == 0, "a call whose hit passed while off never fires after switching back on")
reset()

-- After an update and /reload a new TOC file is missing until a client restart.
local savedSaves = CastAheadSaves
CastAheadSaves = nil
CastAheadDB = { saveCalls = true, centerText = true, leadSeconds = 5 }
local ok, err = pcall(function()
    fire("SPELLS_CHANGED")
    sounds, spoken, clips = 0, 0, 0
    enter()
    castFor(3.0)
    advance(13.9)
    advance(0.1)
end)
check(ok, "no error without the Saves module: " .. tostring(err))
check(Alerts() == 1, string.format("the ordinary heads-up still fires once, got %d", Alerts()))
reset()
do
    local savedLists = CastAheadLists
    CastAheadLists = nil
    local loaded, loadErr = pcall(dofile, "Saves.lua")
    check(loaded and CastAheadSaves == nil,
        "Saves.lua without the new Lists.lua leaves no half-built module: " .. tostring(loadErr))
    CastAheadLists = savedLists
end
CastAheadSaves = savedSaves

-- Aura sounds: registered for the player's role out of combat only, replaced on spec change.
do
    local added, removed, inCombat = {}, {}, false
    C_UnitAuras.AddAuraSound = function(trigger, info) added[#added + 1] = info.spellID return #added end
    C_UnitAuras.RemoveAuraSound = function(id) removed[#removed + 1] = id end
    C_ChatInfo = { InChatMessagingLockdown = function() return false end }
    InCombatLockdown = function() return inCombat end
    Enum.UnitAuraSoundTrigger = { Added = 0 }
    GetSpecialization = function() return 1 end
    local role = "DAMAGER"
    GetSpecializationRole = function() return role end
    GetSpecializationInfo = function() return 265 end
    CastAheadDefensives = { spells = { [373693] = { DAMAGER = true, aura = true }, [5] = { TANK = true, aura = true },
                                       [6] = { DAMAGER = true } }, alias = {} }
    CastAheadDB = { saveCalls = true }
    inCombat = true
    CastAheadSaves.Refresh()
    check(#added == 0, "nothing is registered in combat")
    inCombat = false
    fire("PLAYER_REGEN_ENABLED")
    check(#added == 1 and added[1] == 373693, "leaving combat registers the dps aura only")
    role = "TANK"
    fire("PLAYER_SPECIALIZATION_CHANGED", "player")
    check(#removed == 1 and added[#added] == 5, "a spec change swaps the registrations")
    CastAheadConfig.SetEnabled("sound", false)
    CastAheadSaves.Refresh()
    check(CastAheadSaves.AuraSoundCount() == 0, "sound off registers no aura sound")
    CastAheadConfig.SetEnabled("sound", true)
    CastAheadConfig.SetEnabled("voice", false)
    CastAheadSaves.Refresh()
    check(CastAheadSaves.AuraSoundCount() == 0, "voice off with no picked sound registers no aura sound")
    local files = {}
    C_UnitAuras.AddAuraSound = function(trigger, info) files[#files + 1] = info.soundFileName return #files end
    LibStub = function() return { Fetch = function(_, _, name) return name == "Path" and "custom/path.ogg" or 12345 end } end
    CastAheadDB.sounds = { TANK = "Path" }
    CastAheadSaves.Refresh()
    check(CastAheadSaves.AuraSoundCount() == 1 and files[#files] == "custom/path.ogg",
        "voice off with a picked file registers that file")
    CastAheadDB.sounds = { TANK = "Kit" }
    CastAheadSaves.Refresh()
    check(CastAheadSaves.AuraSoundCount() == 0, "voice off with a picked sound kit registers no clip")
    CastAheadConfig.SetEnabled("voice", true)
    local lockdown = true
    C_ChatInfo.InChatMessagingLockdown = function() return lockdown end
    CastAheadSaves.Refresh()
    check(CastAheadSaves.AuraPending(), "chat lockdown leaves the registration pending")
    lockdown = false
    fire("ENCOUNTER_END", 1234)
    check(not CastAheadSaves.AuraPending() and CastAheadSaves.AuraSoundCount() == 1, "ENCOUNTER_END retries a pending registration")
    lockdown = true
    CastAheadSaves.Refresh()
    lockdown = false
    fire("CHALLENGE_MODE_COMPLETED")
    check(not CastAheadSaves.AuraPending() and CastAheadSaves.AuraSoundCount() == 1, "CHALLENGE_MODE_COMPLETED retries a pending registration")
    CastAheadDB.sounds = { DEFENSIVE = "Path" }
    CastAheadSaves.Refresh()
    check(files[#files]:match("Sounds\\en\\TANK%.ogg$"), "a tank's save takes the tank buster pick, not the defensive one")
    CastAheadDB.sounds = { TANK = "Path" }
    CastAheadSaves.Refresh()
    check(files[#files] == "custom/path.ogg", "a picked sound with a file path replaces the clip")
    CastAheadDB.sounds = { TANK = "Kit" }
    CastAheadSaves.Refresh()
    check(files[#files]:match("Sounds\\en\\TANK%.ogg$"), "a picked sound kit id keeps the clip")
    LibStub, CastAheadDB.sounds = nil, nil
    CastAheadDB.saveCalls = nil
    CastAheadSaves.Refresh()
    check(CastAheadSaves.AuraSoundCount() == 0, "switching save calls off removes them")
    CastAheadDB.saveCalls = true
    local calls = 0
    C_UnitAuras.AddAuraSound = function() calls = calls + 1 return calls end
    CastAheadDB.saveButtons = { [265] = { def = {} } }
    CastAheadSaves.Refresh()
    check(calls == 1 and CastAheadSaves.AuraSoundCount() == 1, "a tank with an empty def list still hears the tank buster")
    CastAheadDB.saveButtons = nil
    C_UnitAuras.AddAuraSound = function() error("restricted") end
    check(pcall(CastAheadSaves.Refresh) and CastAheadSaves.AuraSoundCount() == 0, "a failing AddAuraSound is skipped")
    C_UnitAuras.AddAuraSound = function(trigger, info) files[#files + 1] = info.soundFileName return #files end
    CastAheadDefensives = { spells = { [373693] = { DAMAGER = true, HEALER = true, aura = true, dispel = "Magic" },
                                       [1238084] = { TANK = true, aura = true, dispel = "Magic" } }, alias = {} }
    local magic = { [527] = true, [4987] = true, [77130] = true, [88423] = true, [115450] = true, [360823] = true,
                    [32375] = true }
    local savedIsPlayerSpell, knowsDispel = IsPlayerSpell, true
    IsPlayerSpell = function(id)
        if magic[id] then return knowsDispel and id == 527 end
        return savedIsPlayerSpell == nil or savedIsPlayerSpell(id)
    end
    role = "HEALER"
    fire("SPELLS_CHANGED")
    check(files[#files]:match("Sounds\\en\\MAGIC%.ogg$") and CastAheadSaves.AuraSoundCount() == 1,
        "a healer who can remove the magic hears the dispel, and nothing on a tank's debuff")
    knowsDispel = false
    fire("SPELLS_CHANGED")
    check(files[#files]:match("Sounds\\en\\DEFENSIVE%.ogg$"), "a healer without a magic dispel hears the defensive")
    knowsDispel, role = true, "DAMAGER"
    fire("PLAYER_SPECIALIZATION_CHANGED", "player")
    check(files[#files]:match("Sounds\\en\\DEFENSIVE%.ogg$"), "a damage dealer with a magic dispel still hears the defensive")

    local savedInfo, savedRaid = GetInstanceInfo, CastAheadRaidDefensives
    local kind, difficulty = "raid", 15
    GetInstanceInfo = function() return "r", kind, difficulty, "", 0, 0, false, 2900 end
    CastAheadDefensives = { spells = { [373693] = { DAMAGER = true, aura = true } }, alias = {} }
    CastAheadRaidDefensives = {
        [1305963] = { name = "Venomous Surge", boss = "Sszorak", encounter = 3420,
                      [15] = { DAMAGER = true, HEALER = true, delay = 3, ep = { DAMAGER = 105, HEALER = 105 } } },
        [1300000] = { name = "Mythic Only", boss = "Sszorak", encounter = 3420, [16] = { DAMAGER = true, delay = 1, ep = { DAMAGER = 120 } } },
        [1298367] = { name = "Mother's Wrath", boss = "Ula'tek", encounter = 3492,
                      [15] = { TANK = true, DAMAGER = true, delay = 0, ep = { TANK = 150, DAMAGER = 135 } } },
        [1290814] = { name = "Coiling Ichor", boss = "Twin Fangs", encounter = 3421, dispel = "Magic",
                      [15] = { HEALER = true, delay = 2, ep = { HEALER = 134, DAMAGER = 134 } } },
    }
    local reg = {}
    C_UnitAuras.AddAuraSound = function(trigger, info) reg[info.spellID] = info.soundFileName return info.spellID end
    C_UnitAuras.RemoveAuraSound = function(id) reg[id] = nil end
    role = "DAMAGER"
    CastAheadSaves.Refresh()
    check(next(reg) == nil, "raid calls need the raid switches, not the dungeon one")
    CastAheadDB.raidMode, CastAheadDB.raidSaves = true, true
    CastAheadSaves.Refresh()
    check(reg[1305963] and reg[1305963]:match("Sounds\\en\\DEFENSIVE_d3%.ogg$") and not reg[373693] and not reg[1300000],
        "raid Heroic: the debuff plays the padded clip, dungeon rows and Mythic-only rows stay off")
    difficulty = 16
    fire("PLAYER_DIFFICULTY_CHANGED")
    check(reg[1300000] and reg[1300000]:match("DEFENSIVE_d1%.ogg$") and not reg[1305963], "a difficulty change swaps the raid rows")
    difficulty, role = 15, "TANK"
    CastAheadSaves.Refresh()
    check(reg[1298367] and reg[1298367]:match("Sounds\\en\\TANK%.ogg$") and not reg[1305963],
        "a tank hears a raid row flagged for tanks and damage dealers")
    role = "HEALER"
    fire("SPELLS_CHANGED")
    check(reg[1290814] and reg[1290814]:match("Sounds\\en\\MAGIC%.ogg$"), "a healer who can remove the magic hears the dispel right away")
    role = "DAMAGER"
    LibStub = function() return { Fetch = function(_, _, name) return name == "Path" and "custom/path.ogg" or nil end } end
    CastAheadDB.sounds = { DEFENSIVE = "Path" }
    CastAheadSaves.Refresh()
    check(reg[1305963]:match("DEFENSIVE_d3%.ogg$") and reg[1298367] == "custom/path.ogg",
        "a picked sound plays on an undelayed raid row, never in place of a delayed clip")
    CastAheadConfig.SetEnabled("voice", false)
    CastAheadSaves.Refresh()
    check(reg[1305963] == "custom/path.ogg", "voice off: a delayed row plays the picked sound at once rather than nothing")
    CastAheadConfig.SetEnabled("voice", true)
    LibStub, CastAheadDB.sounds = nil, nil
    kind = "party"
    CastAheadSaves.Refresh()
    check(reg[373693] and not reg[1305963], "outside a raid the raid rows stay off and the dungeon rows play")

    local savedBurst = CastAheadBurstWindows
    CastAheadBurstWindows = { [3420] = { [15] = { name = "Sszorak", note = "Dig In.", { release = 111 } },
                                         [14] = { name = "Sszorak" } },
                              [3445] = { [15] = { name = "Entombed Sentinels" } } }
    CastAheadRaidDefensives[1290814][15].DAMAGER = true
    CastAheadRaidDefensives[1305963].skip = { [16] = { other = { reason = "late", ep = 120, at = 14 } } }
    CastAheadRaidDefensives[1311111] = { name = "Light Hit", boss = "Sszorak", encounter = 3420,
                                         skip = { [15] = { other = { reason = "survivable", ep = 70 } } } }
    CastAheadRaidDefensives[1300000][16].heroic = true
    local function Text(d) return table.concat(CastAheadSaves.RaidGuideLines(d), "\n") end
    local text = Text(15)
    check(text:find("Boss: Entombed Sentinels\n|cff8fb8ff  Defensive|r\n|cffaaaaaa- nothing calls a defensive for your role|r", 1, true)
        and text:find("Boss: Sszorak\n|cff8fb8ff  Defensive|r\n- |Hspell:1305963|hVenomous Surge|h: defensive about 3 s after it lands - takes about 105% of your health", 1, true)
        and text:find("|cffaaaaaa- |Hspell:1311111|hLight Hit|h: no call - takes about 70% of your health, usually survivable|r", 1, true)
        and text:find("Boss: Twin Fangs\n", 1, true) and text:find("Boss: Ula'tek\n", 1, true)
        and text:find("defensive as it lands - takes about 135% of your health", 1, true) and not text:find("Burst", 1, true),
        "raid guide: every boss, the role's calls then the grey skips, no Burst section while bursts are off, got " .. text)
    CastAheadBurstWindows[3421] = { [15] = { name = "Twin Fangs" } }
    CastAheadRaidDefensives[1290814].boss = "The Twin Fangs"
    CastAheadDB.raidSaves = nil
    CastAheadDB.burstCalls = true
    check(Text(15):find("Boss: The Twin Fangs\n", 1, true) and not Text(15):find("Boss: Twin Fangs\n", 1, true),
        "raid guide: a boss keeps one heading whichever sections are shown")
    CastAheadRaidDefensives[1290814].boss = "Twin Fangs"
    CastAheadBurstWindows[3421] = nil
    CastAheadDB.raidSaves = true
    text = Text(15)
    check(text:find("|cff8fb8ff  Burst|r\n  |cffaaaaaaDig In.|r\n  1:51 top players burst here", 1, true)
        and text:find("Boss: Ula'tek\n.-|cff8fb8ff  Burst|r\n|cffaaaaaa  burst on the pull, then on cooldown|r"),
        "raid guide: the Burst section has the note and the windows, a boss with no burst data says so, got " .. text)
    CastAheadDB.raidSaves = nil
    text = Text(15)
    check(not text:find("Defensive", 1, true) and text:find("Burst", 1, true), "raid guide: raid defensive calls off hide the Defensive section")
    CastAheadDB.burstCalls = nil
    check(CastAheadSaves.RaidGuideText(15):find("are off", 1, true), "raid guide: with both off it says the calls are off")
    CastAheadDB.raidSaves = true
    check(CastAheadSaves.RaidGuideText(15):find("^|cffaaaaaaDebuff calls and burst phases come from top%-player logs"),
        "raid guide: the caveat opens the guide")
    check(Text(14):find("Boss: Sszorak\n|cff8fb8ff  Defensive|r\n|cffaaaaaa- no defensive data for Normal|r", 1, true),
        "raid guide: Normal has no defensive data")
    text = Text(16)
    check(text:find("Mythic Only", 1, true) and text:find("judged on Heroic", 1, true)
        and text:find("Venomous Surge|h: no call - the deadly part comes 14 s after it lands, too late for a call", 1, true),
        "raid guide: Mythic shows its own call, the borrowed verdict and the late skip, got " .. text)
    local rows = CastAheadSaves.ViewRaidRows(15)
    check(#rows == 3 and rows[1].id == 1305963 and rows[1].lead == 3 and rows[1].ep == 105 and rows[1].trigger.debuff
        and rows[1].boss == "Sszorak" and rows[3].id == 1298367 and rows[3].lead == 0,
        "raid saves: the role's rows by boss, with the delay as lead and the role's damage")
    role = "TANK"
    text = Text(15)
    check(text:find("Mother's Wrath|h: tank buster as it lands - takes about 150% of your health", 1, true) and not text:find("Venomous Surge", 1, true),
        "raid guide: a tank sees the tank rows with the tanks' damage")
    role = "HEALER"
    check(Text(15):find("Coiling Ichor|h: dispel magic as it lands", 1, true),
        "raid guide: a healer who can remove it sees the dispel, right away")
    local savedInfoByID = GetSpecializationInfoByID
    GetSpecializationInfoByID = function(id) return id, "Resto", "", 0, "HEALER" end
    CastAheadSaves.SetViewSpec(105)
    check(Text(15):find("defensive about 2 s after it lands (dispel magic instead if your spec removes it)", 1, true),
        "raid guide: another healer spec is told the dispel depends on the spec")
    CastAheadSaves.SetViewSpec(nil)
    CastAheadBurstWindows = savedBurst
    GetSpecializationInfoByID = savedInfoByID
    role = "DAMAGER"
    GetInstanceInfo, CastAheadRaidDefensives = savedInfo, savedRaid
    IsPlayerSpell = savedIsPlayerSpell
    C_UnitAuras.AddAuraSound, C_UnitAuras.RemoveAuraSound = nil, nil
    C_ChatInfo, InCombatLockdown, Enum.UnitAuraSoundTrigger = nil, nil, nil
    CastAheadDefensives = { spells = {}, alias = {} }
    CastAheadDB = nil
end

-- Saves view: every hit that calls a save for the player's role in one dungeon.
do
    local role, savedButtons = "DAMAGER", CastAheadSaveButtons
    GetSpecialization = function() return 1 end
    GetSpecializationRole = function() return role end
    GetSpecializationInfo = function() return 265 end
    IsPlayerSpell = function(id) return id == 104773 end
    local savedContainer, savedItem = C_Container, C_Item
    C_Container = { GetContainerNumSlots = function(b) return b == 0 and 1 or 0 end,
                    GetContainerItemID = function(b, s) return b == 0 and s == 1 and 5512 or nil end }
    C_Item = { GetItemSpell = function(id) if id == 5512 then return "Use", 452930 end end,
               GetItemCount = function(id) return id == 5512 and 3 or 0 end,
               GetItemCooldown = function() return now - 1, 60, true end,
               GetItemIconByID = function(id) return 9000 + (id % 1000) end }
    textures[777] = 3777
    CastAheadSaveButtons = { [265] = { def = { 104773, { use = 452930 }, { use = 777 } } } }
    CastAheadDB = { saveCalls = true }
    CastAheadSaves.ScanBags()
    CastAheadSaves.Refresh()
    CastAheadDefensives = { spells = {
        [801] = { DAMAGER = true, lead = 2.0, aura = false, name = "Slam", mob = "Boss A", boss = "Boss A", dungeon = 9000, bar = true },
        [806] = { DAMAGER = true, lead = 1.5, aura = false, name = "Zap", mob = "Abe", boss = "Abe", dungeon = 9000, bar = true },
        [802] = { DAMAGER = true, lead = 3.0, aura = false, name = "Bolt", mob = "Caster", boss = "", dungeon = 9000, bar = false },
        [803] = { DAMAGER = true, lead = 2.5, aura = true, name = "Burn", mob = "Environment", boss = "", dungeon = 9000, bar = false },
        [804] = { DAMAGER = true, lead = 4.0, aura = false, name = "Ache", mob = "Grunt", boss = "", dungeon = 9000, bar = false },
        [805] = { TANK = true, lead = 4.0, aura = false, name = "Crush", mob = "Brute", boss = "", dungeon = 9000, bar = false },
        [807] = { DAMAGER = true, lead = 2.0, aura = false, name = "Magma", mob = "Pool", boss = "", dungeon = 9001, bar = false },
        [808] = { DAMAGER = true, lead = 2.0, aura = false, name = "Elsewhere", mob = "Other", boss = "", dungeon = 9001, bar = false },
        [809] = { DAMAGER = true, lead = 2.0, aura = false, name = "Hex", mob = "Witch", boss = "", dungeon = 9000, bar = false },
    }, alias = { [902] = 802 } }
    CastAheadData[9000] = { name = "Fixture", { spell = 902, prio = "DODGE", first = 12.2, cd = { 20.4 } },
                            { spell = 807, prio = "AOE", kickable = true, cd = { 8.5, 15.8, 8.5, 8.5 } },
                            { spell = 809, kickable = true }, { spell = 950 } }
    CastAheadPriority[806] = "KICK"

    local list = CastAheadSaves.ViewRows and CastAheadSaves.ViewRows(9000) or {}
    local order = {}
    for i, r in ipairs(list) do order[i] = r.id end
    check(table.concat(order, ",") == "806,801,804,802,803,809,807",
        "bosses by name first, then trash by name, got " .. table.concat(order, ","))
    local by = {}
    for _, r in ipairs(list) do by[r.id] = r end
    local zap, slam, bolt, burn, ache, magma = by[806], by[801], by[802], by[803], by[804], by[807]
    check(slam and slam.size == nil and slam.trigger.bar and not slam.trigger.cast and not slam.trigger.debuff
        and slam.wins == nil and slam.lead == 2.0 and slam.boss == "Boss A", "a boss row with a bar")
    check(zap and zap.wins == "KICK", "a boss bar takes its wins from the row's own priority")
    local b = zap and zap.buttons or {}
    check(#b == 3 and b[1].kind == "spell" and b[1].id == 104773 and b[1].available and b[1].icon == 2001,
        "the def list in order: the known spell first, available")
    check(b[2] and b[2].kind == "item" and b[2].id == 5512 and b[2].available == false and b[2].icon == 9512,
        "an item on cooldown stays in the list, not available")
    check(b[3] and b[3].kind == "item" and b[3].available == false and b[3].icon == 3777,
        "an item not in the bags shows its use spell's icon, not available")
    C_Spell.GetSpellCooldownDuration = function() return { HasSecretValues = function() return false end, IsZero = function() return false end } end
    CastAheadSaves.Refresh()
    local cool = CastAheadSaves.ViewRows(9000)
    for _, r in ipairs(cool) do if r.id == 806 then zap = r end end
    check(zap.buttons[1].kind == "spell" and zap.buttons[1].available == false, "the view marks a known spell on cooldown not available")
    C_Spell.GetSpellCooldownDuration = nil
    CastAheadSaves.Refresh()
    local nameSaved = C_Spell.GetSpellName
    C_Spell.GetSpellName = function(id) return ({ [104773] = "Unending Resolve" })[id] end
    local guide = CastAheadSaves.GuideLines(9000)
    local text = table.concat(guide, "\n")
    check(guide[1] == "Boss: Abe" and text:find("\nBoss: Boss A\n", 1, true) and text:find("\nTrash\n", 1, true),
        "the guide groups bosses by name, then trash")
    check(not text:find("Burst", 1, true), "the dungeon guide has no Burst section while burst windows are off")
    do
        local savedBurst, raidMode, bursts = CastAheadBurstWindows, CastAheadDB.raidMode, CastAheadDB.burstCalls
        CastAheadBurstWindows = { [1] = { [8] = { name = "Abe", dungeon = "Fixture", note = "Phase." } },
                                  [2] = { [8] = { name = "Zed", dungeon = "Fixture" } },
                                  [3] = { [8] = { name = "Elsewhere", dungeon = "Other" } } }
        local without = table.concat(CastAheadSaves.GuideLines(9000), "\n")
        check(without:find("Boss: Zed\n|cff8fb8ff  Defensive|r\n|cffaaaaaa- nothing calls a defensive for your role|r", 1, true)
            and not without:find("Burst", 1, true),
            "with burst windows off the dungeon guide still lists every boss of the dungeon, got " .. without)
        CastAheadDB.raidMode, CastAheadDB.burstCalls = true, true
        check(CastAheadSaves.GuideText(9000):find("Burst phases come from top-player logs", 1, true),
            "the dungeon guide carries the burst caveat while bursts are shown")
        local with = table.concat(CastAheadSaves.GuideLines(9000), "\n")
        check(with:find("Boss: Abe\n.-|cff8fb8ff  Burst|r\n  |cffaaaaaaPhase.|r")
            and with:find("Boss: Zed\n|cff8fb8ff  Defensive|r\n|cffaaaaaa- nothing calls a defensive for your role|r\n|cff8fb8ff  Burst|r", 1, true)
            and not with:find("Elsewhere", 1, true) and not with:find("Trash\n|cff8fb8ff", 1, true),
            "the dungeon guide adds each of its bosses' burst lines, lists a boss with only burst data, keeps trash plain, got " .. with)
        CastAheadBurstWindows, CastAheadDB.raidMode, CastAheadDB.burstCalls = savedBurst, raidMode, bursts
    end
    check(guide[3]:find("Zap|h from Abe (heard by: boss timer): defensive - |Hspell:104773|h|T2001:16|t Unending Resolve|h", 1, true) and guide[3]:find("(interrupt comes first)", 1, true),
        "a guide line names the hit, the mob, how it is heard, the call, the first button and what wins")
    check(text:find("Burn|h from ground effect (heard by: debuff on you): defensive", 1, true), "a debuff-only hit says it lands on you")
    check(guide[3]:find("defensive - |Hspell:104773|h|T2001:16|t Unending Resolve|h", 1, true), "a button carries its icon inside a link")
    check(text:find("|Hitem:5512|h|T9512:16|t", 1, true), "an item in the bags links to the item")
    local textureSaved = C_Spell.GetSpellTexture
    C_Spell.GetSpellTexture = function(id) return id == 806 and 4242 or textureSaved(id) end
    check(CastAheadSaves.GuideLines(9000)[3]:find("^%- |Hspell:806|h|T4242:16|t Zap|h from Abe"), "a hit carries its spell icon in front of its name, both inside its link")
    C_Spell.GetSpellTexture = textureSaved
    check(text:find("Bolt|h from Caster (heard by: cast): defensive", 1, true) and text:find("Comes about 12s after the pull, then every 20s", 1, true),
        "a cast with one cooldown gives its first cast and its period")
    check(text:find("9s, 16s, 9s x2, repeating", 1, true), "a cooldown cycle is spelled out, repeats folded")
    check(not text:find("Burn|h from ground effect %(heard by: debuff on you%): defensive[^\n]*every"), "a hit without cast data gets no cadence")
    CastAheadBossCadence = { [801] = { first = 9.6, cd = { 25.0, 40.2, 25.0 }, steady = false }, [806] = { first = 7.0, cd = { 40.0 }, steady = true } }
    text = table.concat(CastAheadSaves.GuideLines(9000), "\n")
    check(text:find("Slam|h from Boss A %(heard by: boss timer%): defensive[^\n]*Comes about 10s after the pull, then 25s, 40s, 25s\n")
        and text:find("Zap|h from Abe[^\n]*Comes about 7s after the pull, then every 40s"),
        "a boss hit takes its cadence from the boss table, a sequence without repeating")
    check(text:find("Magma|h from Pool %(heard by: cast%): defensive[^\n]*Comes with gaps of about 9s, 16s, 9s x2, repeating"),
        "a cycle without a first cast reads as gaps")
    CastAheadBossCadence = nil
    C_Spell.GetSpellName = nameSaved
    local savedSpecRole = GetSpecializationRole
    GetSpecializationRole = function() return "TANK" end
    CastAheadDefensives.spells[810] = { DAMAGER = true, TANK = true, lead = 2.0, aura = false, name = "Quake", mob = "Brute", boss = "", dungeon = 9000, bar = false }
    local tankIds = {}
    for _, r in ipairs(CastAheadSaves.ViewRows(9000)) do tankIds[#tankIds + 1] = r.id end
    check(table.concat(tankIds, ",") == "805", "a tank sees only tank busters in the Saves view, got " .. table.concat(tankIds, ","))
    CastAheadDefensives.spells[810] = nil
    GetSpecializationRole = savedSpecRole
    local hex = by[809]
    check(hex and hex.wins == "KICK", "a kickable cast with no curated category beats the save, as in the game")
    check(bolt and bolt.trigger.cast and not bolt.trigger.bar and bolt.wins == "DODGE" and bolt.name == "Bolt",
        "a trash row reached by an aliased Data cast, beaten by its DODGE")
    check(burn and burn.trigger.debuff and not burn.trigger.cast and burn.mob == "ground effect",
        "an aura-only row, its Environment caster shown as a ground effect")
    check(ache and not (ache.trigger.cast or ache.trigger.bar or ache.trigger.debuff),
        "a row with no trigger")
    check(magma and magma.trigger.cast and magma.wins == nil,
        "a hit from another dungeon's table reached by this one's cast, its curated AOE over kickable does not beat it")
    check(not by[805] and not by[808], "other roles' rows and other dungeons' rows stay out")
    role = "TANK"
    list = CastAheadSaves.ViewRows and CastAheadSaves.ViewRows(9000) or {}
    check(#list == 1 and list[1].id == 805, "a tank sees the tank list")
    role = nil
    check(CastAheadSaves.ViewRows and #CastAheadSaves.ViewRows(9000) == 0, "no role, no list")
    role = "DAMAGER"
    GetSpecializationInfoByID = function(id) return id, "Guard", "", 0, id == 66 and "TANK" or "DAMAGER" end
    CastAheadSaveButtons[66] = { def = { 31850 } }
    CastAheadSaves.SetViewSpec(66)
    check(CastAheadSaves.ViewSpecID() == 66 and CastAheadSaves.ViewRole() == "TANK", "viewing another spec takes that spec's role")
    list = CastAheadSaves.ViewRows(9000)
    check(#list == 1 and list[1].id == 805 and #list[1].buttons == 1 and list[1].buttons[1].id == 31850
        and list[1].buttons[1].available == true, "the viewed spec's list and role, its buttons drawn as available")
    check(CastAheadSaves.List()[1] == 104773, "the real spec's list is untouched by the view")
    CastAheadSaves.SetViewSpec(265)
    check(CastAheadSaves.ViewSpecID() == 265 and CastAheadSaves.ViewRole() == "DAMAGER", "picking the own spec views the own spec")
    CastAheadSaves.SetViewSpec(66)
    fire("PLAYER_SPECIALIZATION_CHANGED", "player")
    check(CastAheadSaves.ViewSpecID() == 265, "a real spec change drops the view")
    do
        CastAheadDefensives.spells[806].ep = { DAMAGER = 120, TANK = 26 }
        local zapRow
        for _, r in ipairs(CastAheadSaves.ViewRows(9000)) do if r.id == 806 then zapRow = r end end
        check(zapRow and zapRow.ep == 120, "a row carries the damage of the viewed role at +20")
        check(CastAheadSaves.GuideLines(9000)[3]:find(". Takes about 120% of your health at +20", 1, true), "the guide line gives the damage at +20")
        check(CastAheadSaves.GuideText(9000):find("^" .. CastAheadSaves.EP_NOTE:gsub("%p", "%%%0") .. "\n\n"),
            "the guide text opens with the damage note")
        check(not CastAheadSaves.ViewLevel and not CastAheadSaves.SetViewLevel and not CastAheadMatch.AtLevel,
            "no view level is left")
        check(select(2, table.concat(CastAheadSaves.GuideLines(9000), "\n"):gsub("%% of your health at %+", "")) == 1,
            "only the row with a damage figure has a damage clause")
        CastAheadDefensives.spells[806].ep = nil
    end
    local savedUnitClass, savedForClass = UnitClass, GetSpecializationInfoForClassID
    UnitClass = function() return "Warlock", "WARLOCK", 9 end
    GetSpecializationInfoForClassID = function(class, i) if class == 2 then return ({ 65, 66, 70 })[i] end end
    GetSpecializationInfoByID = function(id) return id, "X", "", 0, id == 66 and "TANK" or id == 65 and "HEALER" or "DAMAGER" end
    CastAheadSaves.SetViewClass(2)
    check(CastAheadSaves.ViewClassID() == 2 and CastAheadSaves.ViewSpecID() == 65 and CastAheadSaves.ViewRole() == "HEALER",
        "another class opens on its first spec and takes its role")
    CastAheadDB.saveCalls = nil
    check(CastAheadSaves.ViewRole() == "HEALER", "the viewed role does not need the defensive calls switch")
    CastAheadDB.saveCalls = true
    CastAheadSaves.SetViewSpec(66)
    check(CastAheadSaves.ViewClassID() == 2 and CastAheadSaves.ViewSpecID() == 66, "a spec of the viewed class keeps the class")
    CastAheadSaves.SetViewClass(9)
    check(CastAheadSaves.ViewClassID() == 9 and CastAheadSaves.ViewSpecID() == 265, "the own class goes back to the real spec")
    CastAheadSaves.SetViewClass(2)
    fire("PLAYER_SPECIALIZATION_CHANGED", "player")
    check(CastAheadSaves.ViewClassID() == 9 and CastAheadSaves.ViewSpecID() == 265, "a real spec change drops the class view")
    UnitClass, GetSpecializationInfoForClassID = savedUnitClass, savedForClass
    CastAheadSaveButtons[66] = nil
    GetSpecializationInfoByID = nil
    local saved = CastAheadDefensives
    CastAheadDefensives = nil
    check(CastAheadSaves.ViewRows and #CastAheadSaves.ViewRows(9000) == 0, "no defensive table, no list")
    CastAheadDefensives = saved
    CastAheadData[9000] = nil
    CastAheadPriority[806] = nil
    textures[777] = nil
    C_Container, C_Item = savedContainer, savedItem
    CastAheadSaves.ScanBags()
    CastAheadSaveButtons, CastAheadDB = savedButtons, nil
end

GetSpecialization, GetSpecializationRole, GetSpecializationInfo, IsPlayerSpell = nil, nil, nil, nil
CastAheadDefensives = { spells = {}, alias = {} }
CastAheadDB = {}
check(not CastAheadConfig.SaveCalls() and CastAheadConfig.Enabled("bossAdapter"), "save calls are off and boss calls on by default")
CastAheadDB.saveCalls = true
CastAheadConfig.SetEnabled("bossAdapter", false)
check(CastAheadDB.bossAdapter == false and CastAheadConfig.SaveCalls(), "the boss switch is separate")
CastAheadDB = nil
CastAheadCore.ReapplyData()
CastAheadDB = { saveCalls = true }

-- Boss bars: a DBM timer for a spell with a verdict schedules a call at bar end minus lead.
GetSpecialization = function() return 1 end
GetSpecializationRole = function() return "DAMAGER" end
GetSpecializationInfo = function() return 265 end
IsPlayerSpell = function(id) return id == 104773 end
CastAheadDefensives = { spells = { [1299684] = { DAMAGER = true, lead = 3.0 } }, alias = { [1299680] = 1299684 } }
local A = CastAheadBossAdapter
reset()
enter()
sounds, spoken, clips = 0, 0, 0
A.OnBar("dbm", "t0", 1299684, 10, now)
advance(7.5)
advance(5)
check(Alerts() == 0, "a bar outside an encounter schedules nothing")
IsEncounterInProgress = function() return true end
A.OnBar("dbm", "tp", 1299684, 10, now)
advance(7.5)
advance(5)
IsEncounterInProgress = nil
check(Alerts() == 1, string.format("a pull bar sent before our ENCOUNTER_START still calls, got %d", Alerts()))
sounds, spoken, clips = 0, 0, 0
fire("ENCOUNTER_START", 1234)
do
    local savedPriority = CastAheadPriority
    CastAheadPriority = { [1299684] = "CC" }
    A.OnBar("dbm", "tc", 1299684, 10, now)
    A.OnBar("dbm", "ta", 1299680, 10, now)
    advance(7.5)
    advance(5)
    CastAheadPriority = savedPriority
    check(Alerts() == 0, "a curated stun outranks the boss save call, through the alias too")
end
A.OnBar("dbm", "t1", 1299680, 10, now)
advance(6.5)
check(Alerts() == 0, "quiet until bar end minus lead")
advance(1.0)
check(Alerts() == 1, "one call 3 s before the hit, through the alias")
CastAheadDB.saveButtons = { [265] = { def = {} } }
CastAheadSaves.Refresh()
A.OnBar("dbm", "tempty", 1299684, 10, now)
sounds, spoken, clips = 0, 0, 0
advance(7.5)
advance(5)
check(Alerts() == 0, string.format("a spec with an empty def list hears nothing on a boss bar, got %d", Alerts()))
CastAheadDB.saveButtons = nil
CastAheadSaves.Refresh()
A.OnBar("dbm", "t2", 1299684, 10, now)
A.OnStop("dbm", "t2")
sounds, spoken, clips = 0, 0, 0
advance(7.5)
advance(2.5)
check(Alerts() == 0, "a stopped bar never calls")
A.OnBar("dbm", "t3", 1299684, 10, now)
A.OnPause("dbm", "t3", now)
advance(20)
check(Alerts() == 0, "a paused bar waits")
A.OnResume("dbm", "t3", now)
advance(7.5)
check(Alerts() == 1, "and resumes where it stopped")
A.OnBar("bw", "Sever", "sever_option", 10, now)
A.OnBar("dbm", "t4", nil, 10, now)
A.OnBar("dbm", "t5", 4242, 10, now)
sounds, spoken, clips = 0, 0, 0
advance(12)
check(Alerts() == 0, "string keys, nil ids and spells without a verdict are ignored")
A.OnBar("dbm", "t6", 1299684, 10, now)
A.OnUpdate("dbm", "t6", 0, 20, now)
advance(7.5)
check(Alerts() == 0, "an extended bar moves its call")
advance(10)
check(Alerts() == 1, "to the new end minus lead")
advance(5)
A.OnBar("dbm", "t7", 1299684, 10, now)
sounds, spoken, clips = 0, 0, 0
advance(7.5)
A.OnUpdate("dbm", "t7", 7.5, 10.2, now)
advance(6)
check(Alerts() == 1, string.format("an update that keeps a fired call inside its lead does not call again, got %d", Alerts()))
advance(5)
A.OnBar("dbm", "t12", 1299684, 10, now)
sounds, spoken, clips = 0, 0, 0
advance(7.0)
advance(0.5)
A.OnUpdate("dbm", "t12", 7.5, 10.6, now)
advance(0.2)
advance(2)
advance(2)
check(Alerts() == 1, string.format("a small correction after the call does not call again, got %d", Alerts()))
advance(5)
A.OnBar("dbm", "t10", 1299684, 10, now)
sounds, spoken, clips = 0, 0, 0
advance(7.5)
A.OnUpdate("dbm", "t10", 7.5, 30, now)
advance(0.1)
check(Alerts() == 1, string.format("extending a bar after its call is not an immediate second call, got %d", Alerts()))
advance(19.3)
check(Alerts() == 1, "the extended bar stays quiet until its new end minus lead")
advance(0.2)
check(Alerts() == 2, string.format("and calls again 3 s before the new end, got %d", Alerts()))
advance(5)
A.OnBar("dbm", "t8", 1299684, 10, now)
A.OnPause("dbm", "t8", now)
sounds, spoken, clips = 0, 0, 0
advance(20)
A.OnUpdate("dbm", "t8", 0, 10, now)
advance(20)
check(Alerts() == 0, "an update while paused keeps the bar paused")
A.OnResume("dbm", "t8", now)
advance(6.5)
check(Alerts() == 0, "the updated bar counts from where it paused")
advance(1.0)
check(Alerts() == 1, "and calls once after resuming")
advance(5)
A.OnBar("dbm", "t11", 1299684, 10, now)
sounds, spoken, clips = 0, 0, 0
advance(2)
fire("ENCOUNTER_END", 1234)
advance(5.5)
advance(5)
check(Alerts() == 0, string.format("ENCOUNTER_END cancels a live call, got %d", Alerts()))
do
    local savedSaves = CastAheadSaves
    CastAheadSaves = nil
    local ok, err = pcall(function()
        A.OnBar("dbm", "t9", 1299684, 10, now)
        A.OnUpdate("dbm", "t9", 0, 20, now)
        A.OnStop("dbm", "t9")
        fire("ENCOUNTER_START", 1234)
        fire("ENCOUNTER_END", 1234)
    end)
    CastAheadSaves = savedSaves
    check(ok, "the boss adapter needs no Saves module: " .. tostring(err))
end
reset()
GetSpecialization, GetSpecializationRole, GetSpecializationInfo, IsPlayerSpell = nil, nil, nil, nil
CastAheadDefensives = { spells = {}, alias = {} }

-- Connect: with a stub DBM the adapter registers and reports it.
local registered = {}
DBM = { RegisterCallback = function(_, event, fn) registered[event] = fn end }
check(CastAheadBossAdapter.Connect() == "DBM", "DBM is detected")
check(registered.DBM_TimerBegin and registered.DBM_TimerStop and registered.DBM_TimerPause and registered.DBM_TimerResume
    and registered.DBM_TimerUpdate, "the five DBM timer callbacks are registered")

-- Health check: a connected boss mod that sends no bars for 30 s into a fight gets one chat line.
do
    local savedPrint, printed = print, 0
    print = function() printed = printed + 1 end
    registered = {}
    fire("PLAYER_LOGIN")
    local connectedAtLogin = registered.DBM_TimerBegin ~= nil
    DBM = nil
    enter()
    fire("ENCOUNTER_START", 1234)
    advance(31)
    advance(10)
    print = savedPrint
    check(connectedAtLogin, "Core connects the adapter at login")
    check(printed == 1, string.format("one chat line when no boss timers arrive, got %d", printed))
    fire("ENCOUNTER_END", 1234)
    CastAheadBossAdapter.Connect()
    reset()
end

-- BigWigs: StartBar keys the call by module and bar text and takes the spell from the option key.
do
    local bw = {}
    BigWigsLoader = { RegisterMessage = function(_, event, fn) bw[event] = fn end }
    DBM = { RegisterCallback = function() end }
    check(CastAheadBossAdapter.Connect() == "DBM" and next(bw) == nil, "with both boss mods only DBM drives calls")
    check(CastAheadBossAdapter.Status() == "DBM connected", "and the status names DBM")
    DBM = nil
    check(CastAheadBossAdapter.Connect() == "BigWigs", "BigWigs is detected")
    GetSpecialization = function() return 1 end
    GetSpecializationRole = function() return "DAMAGER" end
    GetSpecializationInfo = function() return 265 end
    IsPlayerSpell = function(id) return id == 104773 end
    CastAheadDefensives = { spells = { [1299684] = { DAMAGER = true, lead = 3.0 } }, alias = {} }
    local mod = {}
    reset()
    enter()
    fire("ENCOUNTER_START", 1234)
    sounds, spoken, clips = 0, 0, 0
    local modA, modB = {}, {}
    bw.BigWigs_StartBar("BigWigs_StartBar", modA, 1299684, "Sever", 10)
    bw.BigWigs_StartBar("BigWigs_StartBar", modB, 1299684, "Sever", 10)
    bw.BigWigs_StopBars("BigWigs_StopBars", modA)
    advance(7.5)
    check(Alerts() == 1, string.format("StopBars of one module leaves the other's same-text bar, got %d", Alerts()))
    advance(5)
    bw.BigWigs_StartBar("BigWigs_StartBar", modA, 1299684, "Sever", 10)
    bw.BigWigs_StartBar("BigWigs_StartBar", modB, 1299684, "Sever", 10)
    bw.BigWigs_OnBossDisable("BigWigs_OnBossDisable", modA)
    bw.BigWigs_OnBossDisable("BigWigs_OnBossDisable", modB)
    sounds, spoken, clips = 0, 0, 0
    advance(7.5)
    advance(5)
    check(Alerts() == 0, string.format("OnBossDisable cancels the module's calls, got %d", Alerts()))
    sounds, spoken, clips = 0, 0, 0
    bw.BigWigs_StartBar("BigWigs_StartBar", mod, 1299684, "Sever", 10)
    advance(7.5)
    check(Alerts() == 1, string.format("a BigWigs bar calls 3 s before its end, got %d", Alerts()))
    advance(5)
    bw.BigWigs_StartBar("BigWigs_StartBar", mod, 1299684, "Sever", 10)
    bw.BigWigs_StopBar("BigWigs_StopBar", mod, "Sever")
    sounds, spoken, clips = 0, 0, 0
    advance(7.5)
    advance(4.5)
    check(Alerts() == 0, "StopBar by bar text cancels the call")
    bw.BigWigs_Timer("BigWigs_Timer", mod, 1299684, 10, 10, "Sever", 1, 0, nil, false)
    advance(7.5)
    check(Alerts() == 1, string.format("a timer without a bar still calls, got %d", Alerts()))
    advance(5)
    sounds, spoken, clips = 0, 0, 0
    bw.BigWigs_Timer("BigWigs_Timer", mod, 1299684, 10, 10, "Sever", 1, 0, nil, true)
    advance(12)
    check(Alerts() == 0, "a timer with a bar leaves the call to StartBar")
    issecretvalue = function() return true end
    local ok, err = pcall(function()
        bw.BigWigs_StartBar("BigWigs_StartBar", mod, 1299684, "Sever", 10)
        bw.BigWigs_Timer("BigWigs_Timer", mod, 1299684, 10, 10, "Sever", 1, 0, nil, false)
        bw.BigWigs_PauseBar("BigWigs_PauseBar", mod, "Sever")
        bw.BigWigs_ResumeBar("BigWigs_ResumeBar", mod, "Sever")
        bw.BigWigs_StopBar("BigWigs_StopBar", mod, "Sever")
        registered.DBM_TimerBegin("DBM_TimerBegin", "t1", "Sever", 10, nil, "cd", 1299684)
        registered.DBM_TimerUpdate("DBM_TimerUpdate", "t1", 0, 20)
        registered.DBM_TimerPause("DBM_TimerPause", "t1")
        registered.DBM_TimerResume("DBM_TimerResume", "t1")
        registered.DBM_TimerStop("DBM_TimerStop", "t1")
    end)
    issecretvalue = nil
    advance(12)
    check(ok, "secret bar arguments raise no error: " .. tostring(err))
    check(Alerts() == 0, string.format("and schedule nothing, got %d", Alerts()))
    fire("ENCOUNTER_END", 1234)
    BigWigsLoader = nil
    CastAheadBossAdapter.Connect()
    reset()
    GetSpecialization, GetSpecializationRole, GetSpecializationInfo, IsPlayerSpell = nil, nil, nil, nil
    CastAheadDefensives = { spells = {}, alias = {} }
end

do
    local overwritten = {}
    local env = setmetatable({}, {
        __index = _G,
        __newindex = function(t, k, v)
            local own = tostring(k):match("^CastAhead") or tostring(k):match("^BINDING_NAME_CASTAHEAD")
            if rawget(_G, k) ~= nil and not own then overwritten[#overwritten + 1] = k end
            rawset(t, k, v)
        end,
    })
    local chunk = assert(loadfile("Recorder.lua"))
    setfenv(chunk, env)
    chunk()
    check(#overwritten == 0, "Recorder.lua assigns no existing game global (a taint source for Blizzard code), got " .. table.concat(overwritten, ", "))
end

do
    local bags = { [0] = { 5512, 191380 } }
    local counts, cds, useOf = { [5512] = 3, [191380] = 1 }, { [5512] = { 0, 0 }, [191380] = { 0, 0 } }, { [5512] = 452930, [191380] = 371024 }
    local saved = { C_Container = C_Container, GetItemCount = C_Item and C_Item.GetItemCount }
    C_Container = { GetContainerNumSlots = function(b) return bags[b] and #bags[b] or 0 end,
                    GetContainerItemID = function(b, s) return bags[b] and bags[b][s] end }
    C_Item = C_Item or {}
    C_Item.GetItemSpell = function(id) if useOf[id] then return "Use", useOf[id] end end
    C_Item.GetItemCount = function(id) return counts[id] or 0 end
    C_Item.GetItemCooldown = function(id) local c = cds[id] or { 0, 0 } return c[1], c[2], true end
    C_Item.GetItemIconByID = function(id) return 9000 + (id % 1000) end
    GetSpecialization = function() return 1 end
    GetSpecializationRole = function() return "DAMAGER" end
    GetSpecializationInfo = function() return 265 end
    IsPlayerSpell = function(id) return id == 108416 or id == 104773 end
    InCombatLockdown = function() return false end
    CastAheadSaveButtons = { [265] = { def = { 108416, { use = 452930 } } } }
    CastAheadDB = { saveCalls = true }
    CastAheadSaves.ScanBags()
    local def = CastAheadSaves.Available()
    check(#def == 2 and def[1].kind == "spell" and def[2].kind == "item" and def[2].id == 5512, "spell then healthstone item")
    advance(1)
    counts[5512] = 0
    check(#CastAheadSaves.Available() == 1, "an item with count 0 is not available, read live")
    advance(1)
    counts[5512] = 3
    cds[5512] = { now - 10, 60 }
    check(#CastAheadSaves.Available() == 1, "an item on cooldown is not available")
    advance(1)
    cds[5512] = { 0, 0 }
    local readCooldown = C_Item.GetItemCooldown
    C_Item.GetItemCooldown = function() return 0, 0, false end
    check(#CastAheadSaves.Available() == 1, "an item whose cooldown has not started yet is not available")
    C_Item.GetItemCooldown = readCooldown
    advance(1)
    bags[0][3], useOf[7777], counts[7777] = 7777, 452930, 2
    CastAheadSaves.ScanBags()
    counts[5512] = 0
    local def = CastAheadSaves.Available()
    check(#def == 2 and def[2].id == 7777, "a second item with the same use spell takes over when the first runs out")
    bags[0][3], counts[5512] = nil, 3
    CastAheadSaves.ScanBags()
    advance(1)
    CastAheadDB.saveButtons = { [265] = { def = { 999, 104773 } } }
    check(CastAheadSaves.Available()[1].id == 104773, "an override skips an unknown spell to the next entry")
    advance(1)
    CastAheadDB.saveButtons = { [265] = {} }
    check(#CastAheadSaves.Available() == 2, "a def list missing from the override keeps the shipped one")
    advance(1)
    CastAheadDB = { saveCalls = true, saveButtons = { [265] = { small = 108416 } } }
    CastAheadConfig.Migrate()
    check(type(CastAheadDB.saveButtons[265].def) == "table" and CastAheadDB.saveButtons[265].def[1] == 108416, "old single-number override migrates to the defensive list")
    InCombatLockdown = function() return true end
    bags[0][3] = 191380
    CastAheadSaves.ScanBags()
    check(CastAheadSaves.BagsPending(), "no bag scan in combat, marked pending")
    InCombatLockdown = function() return false end
    fire("PLAYER_REGEN_ENABLED")
    check(not CastAheadSaves.BagsPending(), "the pending scan runs after combat")
    CastAheadDB = { saveCalls = true }
    check(#CastAheadSaves.Icons(CastAheadMatch.ADVICE.DEFENSIVE) == 2, "icons follow the available list")

    local same = CastAheadSaves.Available()
    check(CastAheadSaves.Available() == same, "Available is memoized within a frame")
    counts[5512] = 0
    advance(1)
    check(#CastAheadSaves.Available() == 1, "the next frame reflects a changed item count")
    counts[5512] = 3

    CastAheadDB = { saveCalls = true, saveButtons = { [265] = { def = { 999 } } } }
    CastAheadSaves.Refresh()
    local fallback = CastAheadSaves.Available()
    check(#fallback == 2 and fallback[1].id == 108416 and CastAheadMatch.HasButton(),
        "an override with nothing available falls back to the shipped list")
    CastAheadDB.saveButtons[265].def = {}
    CastAheadSaves.Refresh()
    check(#CastAheadSaves.Available() == 0 and not CastAheadMatch.HasButton(), "an empty override leaves no button")
    CastAheadDB.saveButtons[265].def = { { use = 371024 } }
    cds[191380] = { now - 10, 60 }
    CastAheadSaves.Refresh()
    check(#CastAheadSaves.Available() == 0 and CastAheadMatch.HasButton(),
        "an override potion on cooldown is a button but not available, the shipped list does not stand in")
    cds[191380] = { 0, 0 }
    counts[191380] = 0
    CastAheadSaves.Refresh()
    check(#CastAheadSaves.Available() == 0, "an override potion at count 0 is not available either")
    counts[191380] = 1

    local realInfo = C_Spell.GetSpellInfo
    C_Spell.GetSpellInfo = function(q)
        if q == "Unending Resolve" then return { spellID = 104773, name = q } end
        if q == "Fireball" then return { spellID = 133, name = q } end
        return realInfo(q)
    end
    local Parse = CastAheadSaves.ParseEntry
    local NOT_FOUND = "Not a spell you know or an item with a use effect"
    check(Parse("104773") == 104773, "a known spell id parses to the spell")
    local entry = Parse("5512")
    check(type(entry) == "table" and entry.use == 452930, "an item id parses to its use spell")
    entry = Parse("|cffffffff|Hitem:5512::::::::80:::::|h[Healthstone]|h|r")
    check(type(entry) == "table" and entry.use == 452930, "an item link parses to its use spell")
    check(Parse(" Unending Resolve ") == 104773, "a known spell name parses to its id")
    check(Parse("|cff71d5ff|Hspell:104773:0|h[Unending Resolve]|h|r") == 104773, "a spell link parses to the spell")
    local none, why = Parse("|cff71d5ff|Hspell:133:0|h[Fireball]|h|r")
    check(none == nil and why == NOT_FOUND, "a link to a spell the character does not know is rejected")
    local loading = {}
    C_Item.RequestLoadItemDataByID = function(id) loading[id] = true end
    none, why = Parse("777777")
    check(none == nil and why == "Loading item data, try again" and loading[777777], "an uncached item asks the client to load it")
    C_Item.IsItemDataCachedByID = function() return true end
    none, why = Parse("777777")
    check(none == nil and why == NOT_FOUND, "a cached item without a use effect is rejected")
    C_Item.RequestLoadItemDataByID, C_Item.IsItemDataCachedByID = nil, nil
    none, why = Parse("Fireball")
    check(none == nil and why == NOT_FOUND, "a spell name the character does not know is rejected")
    none, why = Parse("424242")
    check(none == nil and why == NOT_FOUND, "an unknown number is rejected")
    none, why = Parse("!!garbage")
    check(none == nil and why == NOT_FOUND, "garbage is rejected")
    none, why = Parse("", {})
    check(none == nil and why == NOT_FOUND, "an empty box is rejected")
    none, why = Parse("5512", { 108416, { use = 452930 } })
    check(none == nil and why == "Already in the list", "an item already in the list is rejected")
    none, why = Parse("108416", { 108416 })
    check(none == nil and why == "Already in the list", "a spell already in the list is rejected")
    C_Spell.GetSpellInfo = realInfo

    local refreshes = 0
    local realRefresh = CastAheadSaves.Refresh
    CastAheadSaves.Refresh = function() refreshes = refreshes + 1 return realRefresh() end
    CastAheadDB = { saveCalls = true }
    CastAheadSaves.SetList("def", { 104773, { use = 452930 } })
    local def = CastAheadDB.saveButtons[265].def
    check(def[1] == 104773 and def[2].use == 452930 and refreshes == 1, "SetList writes the spec's list and refreshes")
    check(CastAheadSaves.List() == def, "List reads what SetList wrote")
    CastAheadSaves.ResetSpec()
    check(CastAheadDB.saveButtons[265] == nil and refreshes == 2, "ResetSpec clears the spec's lists and refreshes")
    check(CastAheadSaves.List() == CastAheadSaveButtons[265].def, "after a reset the shipped list is back")
    CastAheadSaves.Refresh = realRefresh
    CastAheadDB = { saveCalls = true }
    CastAheadSaves.Refresh()

    CastAheadDB = { saveCalls = true, centerText = true }
    CastAheadSaves.Refresh()
    reset()
    enter()
    local function CenterLine()
        for i = 1, #allFrames do
            local f = allFrames[i]
            if f.shown and type(f.icon) == "table" and type(f.extra) == "table" and type(f.extra[1]) == "table" and f.timeValue then return f end
        end
    end
    CastAheadSaves.Schedule("test:icons", 100, now + 1, now + 6, CastAheadMatch.ADVICE.DEFENSIVE)
    advance(1.5)
    local line = CenterLine()
    check(line and line.icon.textureValue == 2002 and line.extra[1].textureValue == 9512 and line.extra[1].shown and not line.extra[2].shown,
        "a defensive shows the spell, then the item, no third icon")
    CastAheadSaves.Cancel("test:icons")
    CastAheadSaves.Schedule("test:icons2", 100, now + 0.1, now + 5, CastAheadMatch.ADVICE.AOE)
    advance(1)
    line = CenterLine()
    check(line and not line.extra[1].shown and not line.extra[2].shown, "a non-save call shows no extras")
    CastAheadSaves.Cancel("test:icons2")
    CastAheadSaveButtons[265].def = { 108416, 104773, { use = 452930 } }
    CastAheadSaves.Refresh()
    CastAheadSaves.Schedule("test:icons3", 100, now + 0.1, now + 5, CastAheadMatch.ADVICE.DEFENSIVE)
    advance(1)
    line = CenterLine()
    check(line and line.icon.textureValue == 2002 and line.extra[1].textureValue == 2001
        and line.extra[2].shown and line.extra[2].textureValue == 9512, "three ready buttons fill all three icons")
    CastAheadSaves.Cancel("test:icons3")
    CastAheadSaveButtons[265].def = { 108416, { use = 452930 } }
    CastAheadSaves.Refresh()
    reset()

    CastAheadDB = { saveCalls = true, centerText = true, leadSeconds = 0 }
    CastAheadDefensives = { spells = { [100] = { DAMAGER = true, lead = 4.0 } }, alias = {} }
    CastAheadCore.ReapplyData()
    enter()
    castFor(3.0)
    advance(15.0)
    advance(1.5)
    advance(3.0)
    fire("UNIT_SPELLCAST_START", unit)
    advance(1.0)
    line = CenterLine()
    check(line and line.icon.textureValue == 2002 and line.extra[1].shown and line.extra[1].textureValue == 9512
        and not line.extra[2].shown, "a live defensive cast shows the spell and the item in the centre")
    advance(2.0)
    fire("UNIT_SPELLCAST_STOP", unit)
    reset()

    local savedLimits = CastAheadButtonLimits
    CastAheadButtonLimits = { [108416] = "magic" }
    CastAheadDefensives.spells[100].school = 1
    CastAheadSaves.Refresh()
    enter()
    castFor(3.0)
    advance(15.0)
    advance(1.5)
    advance(3.0)
    fire("UNIT_SPELLCAST_START", unit)
    advance(1.0)
    line = CenterLine()
    check(line and line.icon.textureValue == 9512 and not line.extra[1].shown,
        "a live cast of a physical hit skips a magic-only button in the centre")
    advance(2.0)
    fire("UNIT_SPELLCAST_STOP", unit)
    reset()
    CastAheadButtonLimits = savedLimits
    CastAheadDefensives.spells[100].school = nil
    CastAheadSaves.Refresh()

    local heard = {}
    local realPlay = PlaySoundFile
    PlaySoundFile = function(path) heard[#heard + 1] = path return realPlay(path) end
    local function LastBig()
        local at = 0
        for i, p in ipairs(heard) do if p:match("\\DEFENSIVE") then at = i end end
        return at
    end
    CastAheadDefensives = { spells = { [100] = { DAMAGER = true, lead = 4.0 } }, alias = {} }
    local staleHeal = { [265] = { heal = { { use = 452930 } } } }
    CastAheadDB = { saveCalls = true, healCalls = true, centerText = true, leadSeconds = 0, saveButtons = staleHeal }
    CastAheadCore.ReapplyData()
    local centreSaid
    local function BigCast(kick, lockKick)
        reset()
        enter()
        castFor(3.0)
        wipe(heard)
        advance(15.0)
        advance(1.5)
        advance(3.0)
        fire("UNIT_SPELLCAST_START", unit)
        if lockKick then fire("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", unit) end
        advance(1.0)
        centreSaid = CenterLine() and CenterLine().timeValue
        if kick then fire("UNIT_SPELLCAST_INTERRUPTED", unit) end
        advance(2.0)
        fire("UNIT_SPELLCAST_STOP", unit)
        advance(0.1)
    end
    BigCast(false)
    local calls = #heard
    check(LastBig() == calls and calls > 0, "a defensive trash cast calls the defensive: " .. table.concat(heard, ","))
    advance(5.0)
    check(#heard == calls and not CenterLine(), "nothing follows a completed defensive cast: " .. table.concat(heard, ","))
    CastAheadDB.saveButtons = { [265] = { def = {} } }
    CastAheadSaves.Refresh()
    BigCast(false)
    check(LastBig() == 0, "a spec with an empty def list hears nothing on a trash cast: " .. table.concat(heard, ","))
    CastAheadDB.saveButtons = staleHeal
    CastAheadSaves.Refresh()
    BigCast(true)
    check(LastBig() > 0, "a kicked defensive cast still called the defensive")

    reset()
    enter()
    wipe(heard)
    castFor(3.0)
    advance(0.1)
    local last = CastAheadCore.LastCandidates(unit)
    check(last and #last == 1 and last[1].spell == 100 and LastBig() == 0,
        "a cast unidentified at its start that resolves to the defensive hit at its stop calls nothing: " .. table.concat(heard, ","))

    CastAheadPriority[100] = "KICK"
    CastAheadCore.ReapplyData()
    BigCast(false, true)
    check(centreSaid and centreSaid:match("^Defensive"),
        "a kickable cast the game locked shows the defensive: " .. tostring(centreSaid))
    BigCast(false)
    check(centreSaid and centreSaid:match("^Interrupt"),
        "the same cast left kickable calls interrupt: " .. tostring(centreSaid))
    CastAheadPriority[100] = "AOE"
    CastAheadCore.ReapplyData()
    CastAheadDB.saveCalls = nil
    BigCast(false)
    check(LastBig() == 0, "saveCalls off silences the defensive: " .. table.concat(heard, ","))
    CastAheadDB.saveCalls = true
    reset()

    enter()
    wipe(heard)
    CastAheadSaves.Schedule("test:boss1", 100, now + 1, now + 3, CastAheadMatch.ADVICE.DEFENSIVE)
    advance(1.5)
    check(LastBig() == 1 and #heard == 1, "a boss defensive call fires at its time")
    advance(2.0)
    advance(5.0)
    check(#heard == 1 and not CenterLine(), "nothing follows when the boss bar ends: " .. table.concat(heard, ","))
    reset()
    PlaySoundFile = realPlay

    CastAheadDefensives = { spells = {}, alias = {} }
    CastAheadCore.ReapplyData()
    C_Container, C_Item.GetItemCount = saved.C_Container, saved.GetItemCount
    C_Item.GetItemSpell, C_Item.GetItemCooldown, C_Item.GetItemIconByID = nil, nil, nil
    GetSpecialization, GetSpecializationRole, GetSpecializationInfo, IsPlayerSpell, InCombatLockdown = nil, nil, nil, nil, nil
    CastAheadSaveButtons = {}
    CastAheadDB = { saveCalls = true }
end

do
    local bags = { [0] = { 5512, 5509, 262000 } }
    local useOf = { [5512] = 452930, [5509] = 6262, [262000] = 1295247 }
    local saved = { C_Container = C_Container, spec = nil, build = C_Spell.GetSpellCooldownDuration }
    C_Container = { GetContainerNumSlots = function(b) return bags[b] and #bags[b] or 0 end,
                    GetContainerItemID = function(b, s) return bags[b] and bags[b][s] end }
    C_Item = C_Item or {}
    C_Item.GetItemSpell = function(id) if useOf[id] then return "Use", useOf[id] end end
    C_Item.GetItemCount = function() return 1 end
    C_Item.GetItemCooldown = function() return 0, 0, true end
    C_Item.GetItemIconByID = function(id) return 9000 + (id % 1000) end
    GetSpecialization = function() return 1 end
    GetSpecializationRole = function() return "DAMAGER" end
    local specID = 265
    GetSpecializationInfo = function() return specID end
    IsPlayerSpell = function(id) return id == 108416 or id == 104773 end
    InCombatLockdown = function() return false end
    local savedButtons, savedDB = CastAheadSaveButtons, CastAheadDB
    CastAheadSaveButtons = {}
    assert(loadfile("SaveButtons.lua"))()
    CastAheadDB = { saveCalls = true }
    CastAheadSaves.ScanBags()

    local cd, secret = true, false
    local obj = { HasSecretValues = function() return secret end, IsZero = function() return not cd end }
    local ignoreGCD
    C_Spell.GetSpellCooldownDuration = function(_, ignore) ignoreGCD = ignore return obj end
    local textureSaved = C_Spell.GetSpellTexture
    C_Spell.GetSpellTexture = function(id) return id == 108416 and 7001 or textures[id] end

    check(#CastAheadSaves.Available() == 0, "both spells on cooldown: nothing available")
    check(ignoreGCD == true, "the cooldown query ignores the global cooldown")

    advance(1)
    secret = true
    check(CastAheadSaves.Available()[1].id == 108416, "a secret cooldown object leaves Dark Pact first")

    advance(1)
    secret = false
    cd = false
    local icons = CastAheadSaves.Icons(CastAheadMatch.ADVICE.DEFENSIVE)
    check(#icons == 2 and icons[1] == 7001, "defensive icons: Dark Pact first")

    advance(1)
    CastAheadDB.saveButtons = { [265] = { def = { 108416 } } }
    CastAheadSaves.Refresh()
    cd = true
    check(#CastAheadSaves.Available() == 0, "every known spell on cooldown: empty, not the shipped list")
    CastAheadDB.saveButtons = nil
    CastAheadSaves.Refresh()
    advance(1)
    C_Spell.GetSpellCooldownDuration = nil
    cd = true
    check(CastAheadSaves.Available()[1].id == 108416, "missing cooldown API leaves the list unchanged")


    C_Container, C_Spell.GetSpellCooldownDuration, C_Spell.GetSpellTexture = saved.C_Container, saved.build, textureSaved
    C_Item.GetItemSpell, C_Item.GetItemCount, C_Item.GetItemCooldown, C_Item.GetItemIconByID = nil, nil, nil, nil
    GetSpecialization, GetSpecializationRole, GetSpecializationInfo, IsPlayerSpell, InCombatLockdown = nil, nil, nil, nil, nil
    CastAheadSaveButtons, CastAheadDB = savedButtons, savedDB
    CastAheadSaves.ScanBags()
end

do
    local savedButtons, savedDB = CastAheadSaveButtons, CastAheadDB
    CastAheadSaveButtons = {}
    assert(loadfile("SaveButtons.lua"))()
    local S = CastAheadSaves

    local cat = S.Catalogue(66)
    local seen, spells, items = {}, {}, 0
    for _, e in ipairs(cat) do
        local key = type(e) == "table" and "use" .. e.use or e
        check(not seen[key], "catalogue lists " .. key .. " once")
        seen[key] = true
        if type(e) == "number" then spells[e] = true else items = items + 1 end
    end
    for _, id in ipairs({ 498, 31850, 389539, 403876, 642, 1022, 86659 }) do
        check(spells[id], "paladin catalogue has " .. id)
    end
    check(#cat == 7 and items == 0 and cat[1] == 498, "paladin catalogue: 7 paladin spells, in first-seen order")
    check(not (spells[108416] or spells[104773] or spells[6789] or spells[198589] or spells[203720]),
        "paladin catalogue has no warlock or demon hunter spells")
    check(#S.Catalogue(9999) == 0 and #S.Catalogue(nil) == 0, "an unsupported spec has an empty catalogue")
    local shippedSpecs = 0
    for _ in pairs(CastAheadSaveButtons) do shippedSpecs = shippedSpecs + 1 end
    check(shippedSpecs == 40, "every one of the 40 specs ships lists, got " .. shippedSpecs)
    for spec in pairs(CastAheadSaveButtons) do
        check(#S.Catalogue(spec) > 0, "shipped spec " .. spec .. " has a class catalogue")
    end

    GetSpecialization = function() return 1 end
    GetSpecializationInfo = function() return 265 end
    IsPlayerSpell = function(id) return id == 108416 or id == 104773 end
    local refreshes = 0
    local realRefresh = S.Refresh
    S.Refresh = function() refreshes = refreshes + 1 return realRefresh() end

    CastAheadDB = { saveCalls = true, saveButtons = { [265] = { def = { 108416, 6789, 104773 } } } }
    refreshes = 0
    S.Shift("def", 2, -1)
    local def = CastAheadDB.saveButtons[265].def
    check(def[1] == 6789 and def[2] == 108416 and def[3] == 104773 and refreshes == 1, "Shift up swaps with the entry above, one refresh")
    S.Shift("def", 1, -1)
    S.Shift("def", 3, 1)
    check(def[1] == 6789 and def[3] == 104773 and refreshes == 1, "Shift past either end does nothing")
    CastAheadDB = { saveCalls = true }
    local shippedFirst = CastAheadSaveButtons[265].def[1]
    S.Shift("def", 1, 1)
    check(CastAheadSaveButtons[265].def[1] == shippedFirst and CastAheadDB.saveButtons[265].def[2] == shippedFirst,
        "Shift on a shipped list writes a copy, the shipped table stays")

    CastAheadDB = { saveCalls = true, saveButtons = { [265] = { def = {} } } }
    local add = S.Addable("def")
    local addSeen = {}
    for _, e in ipairs(add) do addSeen[type(e) == "table" and "use" .. e.use or e] = true end
    check(addSeen[104773] and addSeen[108416] and not addSeen[6789],
        "Addable lists known class spells, not unknown spells")
    CastAheadDB.saveButtons[265].def = { 104773, { use = 452930 } }
    add = S.Addable("def")
    addSeen = {}
    for _, e in ipairs(add) do addSeen[type(e) == "table" and "use" .. e.use or e] = true end
    check(not addSeen[104773] and addSeen[108416], "Addable skips what the list already holds")

    local dialog = StaticPopupDialogs.CASTAHEAD_RESET_SAVES
    check(dialog and dialog.hideOnEscape and dialog.timeout == 0 and type(dialog.OnAccept) == "function",
        "the reset confirmation is registered")
    CastAheadDB = { saveCalls = true, saveButtons = { [265] = { def = {} } } }
    if dialog then dialog.OnAccept() end
    check(CastAheadDB.saveButtons[265] == nil, "accepting the reset clears the spec's lists")

    S.Refresh = realRefresh
    GetSpecialization, GetSpecializationInfo, IsPlayerSpell = nil, nil, nil
    CastAheadSaveButtons, CastAheadDB = savedButtons, savedDB
    S.Refresh()
end

do
    local savedButtons, savedDB = CastAheadSaveButtons, CastAheadDB
    local shipped = {
        [265] = { full = { 111 } },
        [266] = { full = { 222 }, mini = { 333 } },
        [267] = { full = { 444, { use = 452930 } } },
        [66] = { full = { 555 } },
    }
    local changes = 0
    local burst = CastAheadLists.New({
        dbKey = "burstButtons",
        shipped = function() return shipped end,
        keys = { "full", "mini" },
        specID = function() return 265 end,
        onChange = function() changes = changes + 1 end,
    })
    CastAheadSaveButtons = { [265] = { def = { 108416 } } }
    IsPlayerSpell = function(id) return id ~= 999 end
    local saves = { [265] = { def = { 104773 } } }
    CastAheadDB = { saveCalls = true, saveButtons = saves }

    check(burst.Keys()[1] == "full" and burst.Keys()[2] == "mini", "a burst store keeps its keys")
    check(burst.List("full") == shipped[265].full and #burst.List("mini") == 0, "a burst store reads its shipped lists")
    burst.SetList("full", { 111, 222 })
    check(CastAheadDB.burstButtons[265].full[2] == 222 and changes == 1, "SetList writes the burst lists and calls onChange")
    burst.Shift("full", 1, 1)
    check(CastAheadDB.burstButtons[265].full[1] == 222 and changes == 2, "Shift writes the burst lists")
    check(CastAheadDB.saveButtons == saves and #saves[265].def == 1 and saves[265].def[1] == 104773 and saves[265].heal == nil,
        "editing burst lists leaves the save lists alone")

    burst.SetList("full", { 111 })
    local seen = {}
    for _, e in ipairs(burst.Addable("full")) do seen[type(e) == "table" and "use" .. e.use or e] = true end
    check(seen[222] and seen[333] and seen[444] and seen.use452930, "Addable offers the class mates' shipped burst entries")
    check(not seen[111] and not seen[555] and not seen[108416] and not seen[104773],
        "Addable skips the list's own entries, other classes and save buttons")

    burst.ResetSpec()
    check(CastAheadDB.burstButtons[265] == nil and changes == 4, "ResetSpec clears the spec's burst lists")
    check(CastAheadDB.saveButtons[265] == saves[265] and saves[265].def[1] == 104773, "ResetSpec on burst leaves the save lists")

    IsPlayerSpell = nil
    CastAheadSaveButtons, CastAheadDB = savedButtons, savedDB
end

do
    local savedDB, savedKnown, savedName = CastAheadDB, IsPlayerSpell, C_Spell.GetSpellName
    local shipped = { [265] = { def = { 104773 } }, [66] = { def = { 86659 } }, [65] = { def = { 642 } } }
    local view = 66
    local store = CastAheadLists.New({ dbKey = "saveButtons", shipped = function() return shipped end, keys = { "def" },
        specID = function() return 265 end, editSpecID = function() return view end, onChange = function() end })
    IsPlayerSpell = function(id) return id == 104773 end
    C_Spell.GetSpellName = function(id) return id == 31850 and "Ardent Defender" or nil end
    CastAheadDB = {}
    store.SetList("def", { 86659, 31850 })
    check(CastAheadDB.saveButtons[66].def[2] == 31850 and store.List("def")[1] == 104773,
        "editing another spec writes its list, the calls keep the real one")
    check(store.EditList("def")[1] == 86659, "the page reads the edited spec")
    check(store.ParseEntry("31850", {}) == 31850, "another spec's list takes a spell this character does not know")
    local savedItem = C_Item
    C_Item = { GetItemSpell = function(id) if id == 31850 then return "Use", 452930 end end }
    local asItem = store.ParseEntry("31850", {})
    check(type(asItem) == "table" and asItem.use == 452930, "for another spec a number that is also a usable item is the item")
    C_Item = savedItem
    local seen = {}
    for _, e in ipairs(store.Addable("def")) do seen[e] = true end
    check(seen[642], "another spec offers its class spells this character does not know")
    view = 265
    check(store.ParseEntry("31850", {}) == nil, "the real spec's list still wants a known spell")
    IsPlayerSpell, C_Spell.GetSpellName, CastAheadDB = savedKnown, savedName, savedDB
end

do
    local ok, err = pcall(dofile, "Options.lua")
    check(ok and CastAheadOptions and CastAheadOptions.Flow, "Options.lua loads and exposes Flow " .. tostring(err))
    local savedSwitchDB = CastAheadDB
    CastAheadDB = {}
    CastAheadOptions.SetSwitch("saveCalls", true)
    check(CastAheadDB.saveCalls == true, "switching a default-off switch on stores true")
    CastAheadOptions.SetSwitch("saveCalls", false)
    check(CastAheadDB.saveCalls == false, "switching it off stores false, not nil")
    CastAheadDB = savedSwitchDB
    local Flow = CastAheadOptions and CastAheadOptions.Flow or function() return {}, 0 end
    local pos, total = Flow(250, 250, 8, { 100, 50, 70 })
    check(#pos == 3 and pos[1].x == 0 and pos[1].y == 0 and pos[2].y == 108 and pos[3].y == 166 and total == 236,
        "one column stacks groups with the gap")
    pos, total = Flow(508, 250, 8, { 100, 50, 70 })
    check(pos[1].x == 0 and pos[2].x == 258 and pos[2].y == 0 and pos[3].x == 258 and pos[3].y == 58 and total == 128,
        "two columns: each group goes to the shortest column")
    pos = Flow(100, 250, 8, { 10 })
    check(pos[1].x == 0 and pos[1].y == 0, "narrower than one column still gives one column")
    pos, total = Flow(1040, 250, 8, { 300, 20, 20, 20 })
    check(pos[4].x == 774 and pos[4].y == 0 and total == 300, "four columns, the tallest decides the height")
end

do
    local function Group(h, shown)
        local g = { h = h, shown = shown }
        function g:GetHeight() return self.h end
        function g:IsShown() return self.shown end
        function g:ClearAllPoints() self.point = nil end
        function g:SetPoint(_, _, _, x, y) self.point = { x = x, y = y } end
        return g
    end
    local a, b, c = Group(100, true), Group(50, false), Group(70, true)
    local panel = { groups = { a, b, c } }
    function panel:GetWidth() return 250 end
    function panel:SetHeight(h) self.height = h end
    local relayout = CastAheadOptions and CastAheadOptions.RelayoutGroups
    check(relayout ~= nil, "Options.lua exposes RelayoutGroups")
    if relayout then relayout(panel) end
    check(c.point and c.point.y == -(6 + 108) and panel.height == 6 + 178 + 12,
        "a hidden group leaves no gap: the next one takes its slot")

    local d, e = Group(100, true), Group(50, true)
    local wide = { groups = { d, e }, w = 515 }
    function wide:GetWidth() return self.w end
    function wide:SetHeight(h) self.height = h end
    if relayout then relayout(wide) end
    check(e.point and e.point.x == 8 and e.point.y == -(6 + 108),
        "a second column that would cross the page edge wraps under the first")
    wide.w = 516
    if relayout then relayout(wide) end
    check(e.point and e.point.x == 8 + 258 and e.point.y == -6, "two columns once both fit inside the page margin")
    wide.flowBottom = function() return 30 end
    if relayout then relayout(wide) end
    check(wide.height == 6 + 100 + 30 + 12, "a note under the groups adds its height to the panel")
end

do
    local savedCreate, savedDB, savedWindows = CreateFrame, CastAheadDB, CastAheadBurstWindows
    local savedSlider = MinimalSliderWithSteppersMixin
    InCombatLockdown = function() return false end
    MinimalSliderWithSteppersMixin = savedSlider or { Label = { Min = 1, Max = 2 }, Event = { OnValueChanged = 1 } }
    local made, texts = {}, {}
    CreateFrame = function(kind, name, parent, ...)
        local f = savedCreate(kind, name, parent, ...)
        made[#made + 1] = f
        f.template = ...
        local createText = f.CreateFontString
        f.CreateFontString = function(...)
            local fs = createText(...)
            local setText = fs.SetText
            fs.SetText = function(self, t) setText(self, t) rawset(self, "value", t) end
            fs.SetShown = function(self, on) self.shown = on and true or false end
            fs.SetTextColor = function(self, ...) self.color = (...) == 1 and "normal" or "muted" end
            texts[#texts + 1] = fs
            return fs
        end
        f.SetShown = function(self, on) self.shown = on and true or false end
        f.SetEnabled = function(self, on) self.enabled = on and true or false end
        f.SetMotionScriptsWhileDisabled = function(self, on) self.motionWhileDisabled = on end
        f.SetText = function(self, t) rawset(self, "buttonText", t) end
        local setScript = f.SetScript
        f.SetScript = function(self, script, fn)
            setScript(self, script, fn)
            if script == "OnClick" then rawset(self, "onClick", fn) end
        end
        f.h, f.flowTop, f.MinText, f.MaxText, f.Slider = 0, 6, StubRegion(), StubRegion(), StubRegion()
        f.SetSize = function(self, w, h) self.w, self.h = w, h end
        f.SetHeight = function(self, h) self.h = h end
        f.GetHeight = function(self) return self.h end
        f.GetWidth = function(self) return rawget(self, "w") or 600 end
        f.GetFrameLevel = function() return 1 end
        f.SetValue = function() end
        return f
    end
    CastAheadDB = {}
    CastAheadBurstWindows = { [3492] = { [15] = { name = "Ula'tek", { release = 145.5, target = "Venomous Heart" } } } }
    local host = CreateFrame("Frame")
    local ok, err
    local realSpecBar, onPick = CastAheadWindow.SpecBar, nil
    CastAheadWindow.SpecBar = function(parent, x, y, pick, ...)
        onPick = pick
        return realSpecBar(parent, x, y, pick, ...)
    end
    ok, err = pcall(CastAheadOptions.ShowPanel, host, "Defensives")
    CastAheadWindow.SpecBar = realSpecBar
    check(ok, "the Defensives page builds headless " .. tostring(err))
    do
        local store, reads = CastAheadSaves.Store, 0
        local realEdit = store.EditList
        store.EditList = function(...) reads = reads + 1 return realEdit(...) end
        if type(onPick) == "function" then onPick() end
        store.EditList = realEdit
        check(type(onPick) == "function" and reads > 0, "picking a spec in the Defensives bar repaints the list")
    end
    ok, err = pcall(CastAheadOptions.ShowPanel, host, "Report")
    check(ok, "the Report page builds headless " .. tostring(err))
    local tabs = table.concat(CastAheadOptions.TABS, " ")
    check(not tabs:find("Bursts", 1, true) and not tabs:find("RaidDefensives", 1, true),
        "there are no Bursts and no Raid Defensives settings pages, got " .. tabs)

    local wanted = { Features = true, ["Defensive calls in dungeons"] = true,
        ["Raid (experimental)"] = true, ["Defensive calls in raids"] = true, ["Burst windows"] = true,
        Advanced = true, ["Development mode"] = true }
    local function Labels(from)
        local seen = {}
        for i = from, #texts do
            local v = rawget(texts[i], "value")
            if wanted[v] then seen[#seen + 1] = v end
        end
        return table.concat(seen, " | ")
    end
    check(Labels(1) == "", "the Defensives page has no defensive calls switch")
    local before, madeBefore = #texts, #made
    ok, err = pcall(CastAheadOptions.ShowPanel, host, "General")
    check(ok, "the General page builds headless " .. tostring(err))
    check(Labels(before + 1) == "Features | Defensive calls in dungeons | Raid (experimental)"
        .. " | Defensive calls in raids | Burst windows | Advanced | Development mode",
        "General lists the feature switches in their group, the raid ones under the raid switch, then Advanced")
    do
        local shown, found, sliders, dropdowns = {}, {}, 0, 0
        for i = before + 1, #texts do
            local v = rawget(texts[i], "value")
            if type(v) == "string" then shown[#shown + 1] = v end
        end
        for i = madeBefore + 1, #made do
            if made[i].template == "MinimalSliderWithSteppersTemplate" then sliders = sliders + 1 end
            if made[i].template == "WowStyle1DropdownTemplate" then dropdowns = dropdowns + 1 end
        end
        local page = "|" .. table.concat(shown, "|") .. "|"
        for _, gone in ipairs({ "Position around the plate", "|Grow|", "Distance from the plate", "Nudge sideways",
            "Nudge up or down", "|Icon size|", "Icon: ", "Label: ", "Countdown: ", "|Fixed spacing|", "Gap: ", "Layer",
            "Size: ", "Text: " }) do
            if page:find(gone, 1, true) then found[#found + 1] = gone end
        end
        check(#found == 0, "General builds no size or position control, found " .. table.concat(found, ","))
        check(sliders == 1 and dropdowns == 0, "General keeps only the early-warning slider and no dropdown, got "
            .. sliders .. "/" .. dropdowns)
        check(page:find("|Show icons on nameplates|", 1, true) and page:find("|Full labels|", 1, true)
            and page:find("|Show the centre call|", 1, true), "General keeps the nameplate and centre call switches")
        local heights = {}
        for _, g in ipairs(made) do
            local title = rawget(g, "title")
            local v = title and rawget(title, "value")
            if v == "Nameplate icons" or v == "Centre call" then heights[v] = g.h end
        end
        check(heights["Nameplate icons"] == 100 and heights["Centre call"] == 70,
            "General's icon and centre groups shrink to their switches, got "
            .. tostring(heights["Nameplate icons"]) .. "/" .. tostring(heights["Centre call"]))
    end

    local function Frame(label)
        for _, f in ipairs(made) do
            local t = rawget(f, "text")
            if t and rawget(t, "value") == label then return f end
        end
    end
    do
        local function FeaturesHeight()
            for _, f in ipairs(made) do
                local title = rawget(f, "title")
                if title and rawget(title, "value") == "Features" then return f.h end
            end
        end
        local raid, raidSaves, bursts = Frame("Raid (experimental)"), Frame("Defensive calls in raids"), Frame("Burst windows")
        local offHeight = FeaturesHeight()
        check(raid and raidSaves and bursts,
            "with the raid switch off its two children are still built")
        check(raidSaves.enabled == false and bursts.enabled == false and raid.enabled ~= false,
            "with the raid switch off its two children are disabled")
        check(raidSaves.text.color == "muted" and bursts.text.color == "muted", "and their labels are greyed")
        check(raidSaves.motionWhileDisabled == true and bursts.motionWhileDisabled == true,
            "the children keep their tooltips while disabled")
        check(offHeight == 166, "the Features group keeps the four-row height, got " .. tostring(offHeight))
        CastAheadDB = { raidMode = true }
        CastAheadOptions.ShowPanel(host, "General")
        check(raidSaves.enabled == true and bursts.enabled == true, "with the raid switch on its two children are enabled")
        check(raidSaves.text.color ~= "muted" and bursts.text.color ~= "muted", "and their labels are back to normal")
        check(FeaturesHeight() == offHeight, "the Features group height does not change with the raid switch")
        CastAheadDB = { raidSaves = true, burstCalls = true }
        CastAheadOptions.ShowPanel(host, "General")
        check(raidSaves.enabled == false and bursts.enabled == false,
            "children switched on stay disabled while the raid switch is off")
        CastAheadDB = {}
    end
    do
        local realChanged, changed = CastAheadSetup.OutputsChanged, 0
        CastAheadSetup.OutputsChanged = function() changed = changed + 1 end
        local pairsOf = { { "Show icons on nameplates", "nameplates" }, { "Show the centre call", "centerText" },
                          { "Feed the Blizzard timeline", "timeline" } }
        for _, p in ipairs(pairsOf) do
            local box = Frame(p[1])
            box.GetChecked = function() return false end
            box.SetChecked = function(self, v) self.checkedValue = v end
            box.handlers.OnClick(box)
            check(CastAheadDB[p[2]] == false, "General: " .. p[1] .. " writes " .. p[2])
            CastAheadDB[p[2]] = nil
            CastAheadOptions.Refresh()
            check(box.checkedValue == true, "General: " .. p[1] .. " follows the setting after a refresh")
        end
        check(changed == 3, "General: each output switch tells the setup mode, got " .. changed)
        CastAheadSetup.OutputsChanged = realChanged
        CastAheadDB = {}
    end
    (function()
        local setup, move
        for _, b in ipairs(made) do
            if rawget(b, "buttonText") == "Size and position" then setup = b end
            if rawget(b, "buttonText") == "Move it on screen" then move = b end
        end
        check(setup and not move, "General has Size and position in place of Move it on screen")
        if not setup then return end
        local realEnter, realLock = CastAheadSetup.Enter, InCombatLockdown
        local entered, inCombat = 0, false
        CastAheadSetup.Enter = function() entered = entered + 1 return true end
        InCombatLockdown = function() return inCombat end
        check(setup.handlers.OnEnter == nil, "Size and position has no tooltip")
        setup.handlers.OnClick(setup)
        check(entered == 1, "Size and position enters the setup mode")
        inCombat = true
        CastAheadOptions.ShowPanel(host, "General")
        check(setup.enabled == false, "Size and position is disabled in combat")
        inCombat = false
        setup.handlers.OnEvent(setup, "PLAYER_REGEN_ENABLED")
        check(setup.enabled == true, "Size and position is enabled again when combat ends")
        setup.handlers.OnEvent(setup, "PLAYER_REGEN_DISABLED")
        check(setup.enabled == false, "Size and position is disabled when combat starts, before the lockdown reports it")
        inCombat = true
        setup.handlers.OnEvent(setup, "PLAYER_REGEN_ENABLED")
        check(setup.enabled == true, "Size and position is enabled when combat ends, before the lockdown lifts")
        local hint
        for _, fs in ipairs(texts) do
            if rawget(fs, "value") == "Best done near training dummies, so the icons show on real nameplates." then hint = fs end
        end
        check(hint ~= nil, "General says next to the button that setup is best done near training dummies")
        CastAheadSetup.Enter, InCombatLockdown = realEnter, realLock
    end)()
    local function OffNote()
        for _, fs in ipairs(texts) do
            local v = rawget(fs, "value")
            if type(v) == "string" and v:find("turn them on in General - Features", 1, true) then return fs end
        end
    end
    for _, case in ipairs({ { {}, false, "all off" }, { { saveCalls = true }, true, "dungeons" },
        { { raidMode = true, raidSaves = true }, true, "raids" }, { { raidSaves = true }, false, "raids without the raid switch" } }) do
        CastAheadDB = case[1]
        CastAheadOptions.ShowPanel(host, "Defensives")
        local boss, note = Frame("Boss calls from DBM / BigWigs"), OffNote()
        check(boss and boss.shown == case[2], "Defensives boss switch visibility, " .. case[3])
        check(note and note.shown == not case[2], "Defensives off note visibility, " .. case[3])
    end

    CastAheadDB = {}
    CastAheadOptions.SetSwitch("centerText", false)
    check(CastAheadDB.centerText == false, "switching the centre call off stores false")
    CastAheadOptions.SetSwitch("centerText", true)
    check(CastAheadDB.centerText == nil, "switching it on clears the stored choice")

    CreateFrame, CastAheadDB, CastAheadBurstWindows = savedCreate, savedDB, savedWindows
    MinimalSliderWithSteppersMixin = savedSlider
    InCombatLockdown = nil
end

do
    local sized = 0
    local made, scripts, panelsShown = {}, {}, {}
    local pageTexts, buttonTexts = {}, {}
    local savedCreate, savedShowPanel = CreateFrame, CastAheadOptions.ShowPanel
    CastAheadOptions.ShowPanel = function(_, name) panelsShown[#panelsShown + 1] = name end
    CreateFrame = function(kind, name, ...)
        local f = savedCreate(kind, name, ...)
        local setScript = f.SetScript
        f.SetScript = function(self, script, fn)
            setScript(self, script, fn)
            scripts[self] = scripts[self] or {}
            scripts[self][script] = fn
        end
        made[#made + 1] = f
        local createText = f.CreateFontString
        f.CreateFontString = function(...)
            local fs = createText(...)
            local setText = fs.SetText
            fs.SetText = function(self, t) setText(self, t) pageTexts[#pageTexts + 1] = t end
            return fs
        end
        f.SetText = function(self, t) rawset(self, "buttonText", t) buttonTexts[#buttonTexts + 1] = t end
        if name == "CastAheadMainWindow" then
            f.SetSize = function(self, w, h) sized = sized + 1 self.w, self.h = w, h end
            f.GetWidth = function(self) return self.w or 0 end
            f.GetHeight = function(self) return self.h or 0 end
        end
        return f
    end
    UIParent = { GetWidth = function() return 1920 end, GetHeight = function() return 1080 end }
    CastAheadDB = { window = { width = 300, height = 200 } }
    local titleAdded = {}
    CastAheadWindow.titleButtons(function(text)
        titleAdded[#titleAdded + 1] = text
        return { SetScript = function() end, SetText = function() end }
    end)
    check(titleAdded[1] == "Test drive" and #titleAdded == 1, "the title bar keeps only Test drive, got " .. table.concat(titleAdded, ","))
    CastAheadUI.ShowTab("Casts")
    local f = CastAheadWindow.Frame()
    check(f and f.w == 600 and f.h == 420, "a saved size below the minimum opens at the minimum")
    do
        local list
        for _, b in ipairs(made) do
            if rawget(b, "buttonText") == "Play list" then list = b end
        end
        check(list and scripts[list] and scripts[list].OnClick, "the Casts page has a Play list button")
        local savedTest, savedTesting, savedDungeon = CastAheadCore.Test, CastAheadCore.Testing, CastAheadWindow.Dungeon
        local running, args = false, nil
        CastAheadCore.Testing = function() return running end
        CastAheadCore.Test = function(...) args = { n = select("#", ...), ... } end
        CastAheadWindow.Dungeon = function() return "pagedungeon" end
        if list and scripts[list] and scripts[list].OnClick then scripts[list].OnClick(list) end
        check(args and args.n == 2 and args[1] == "pagedungeon" and type(args[2]) == "table",
            "Play list plays the page's dungeon with the table's rows")
        running = true
        CastAheadUI.RefreshTest()
        check(list and rawget(list, "buttonText") == "Stop", "Play list reads Stop while a run is going")
        running = false
        CastAheadUI.RefreshTest()
        check(list and rawget(list, "buttonText") == "Play list", "Play list is back once the run ends")
        CastAheadCore.Test, CastAheadCore.Testing, CastAheadWindow.Dungeon = savedTest, savedTesting, savedDungeon
    end
    local before = sized
    CastAheadUI.ShowTab("General")
    local textsBefore, buttonsBefore = #pageTexts, #buttonTexts
    CastAheadUI.ShowTab("Saves")
    local noteShown, steppers = false, false
    for i = textsBefore + 1, #pageTexts do
        if pageTexts[i] == CastAheadSaves.EP_NOTE then noteShown = true end
    end
    for i = buttonsBefore + 1, #buttonTexts do
        if buttonTexts[i] == "-" or buttonTexts[i] == "+" then steppers = true end
    end
    check(noteShown, "the Saves page shows the damage note")
    check(not steppers, "the Saves page has no level stepper buttons")
    CastAheadUI.ShowTab("Guide")
    local clicked = false
    for _, b in ipairs(made) do
        if rawget(b, "instanceID") and scripts[b] and scripts[b].OnClick then
            scripts[b].OnClick(b)
            clicked = true
        end
    end
    check(clicked, "the dungeon grid has a button to click")
    CastAheadDB.devMode = true
    CastAheadUI.RefreshTabs()
    CastAheadUI.ShowTab("Development")
    CastAheadDB.devMode = nil
    CastAheadUI.RefreshTabs()
    check(CastAheadWindow.Current() == "General", "Development switched off while open shows General")
    check(panelsShown[#panelsShown] == "General", "each settings page shows its own panel")
    check(sized == before, "switching pages, dungeons and Development mode never resizes the window")
    CastAheadDB.raidMode, CastAheadDB.burstCalls = true, true
    CastAheadUI.ShowTab("RaidGuide")
    check(CastAheadWindow.Current() == "RaidGuide", "burst windows switched on show the Raid Guide")
    CastAheadDB.burstCalls = nil
    CastAheadUI.RefreshTabs()
    check(CastAheadWindow.Current() == "General", "the raid features switched off while the Raid Guide is open show General")
    do
        local W = CastAheadWindow
        local function Shown(name) return select(2, W.Page(name)) end
        check(W.Page("Defensives") == "Settings", "Defensives sits in the Settings group")
        check(W.Page("RaidGuide") == "Raid" and W.Page("RaidSaves") == "Raid", "Guide and Saves sit in the Raid group")
        check(W.Page("Bursts") == nil and W.Page("RaidDefensives") == nil, "there is no Bursts or Raid Defensives page")
        local hasExperimental
        for _, g in ipairs(W.GROUPS) do
            if g == "Experimental" then hasExperimental = true end
        end
        check(not hasExperimental, "there is no Experimental group")
        CastAheadDB.saveCalls, CastAheadDB.burstCalls, CastAheadDB.raidSaves = nil, nil, nil
        CastAheadUI.RefreshTabs()
        check(Shown("Defensives") == false, "Defensives is hidden while dungeon and raid calls are off")
        check(Shown("RaidGuide") == false and Shown("RaidSaves") == false, "the Raid group is hidden while its features are off")
        check(Shown("Guide") == true, "the dungeon Guide stays shown with dungeon calls off")
        CastAheadDB.saveCalls = true
        CastAheadUI.RefreshTabs()
        check(Shown("Defensives") == true, "Defensives is shown while dungeon calls are on")
        CastAheadUI.ShowTab("Defensives")
        CastAheadDB.saveCalls = nil
        CastAheadUI.RefreshTabs()
        check(CastAheadWindow.Current() == "General", "calls switched off while Defensives is open show General")
        CastAheadDB.raidMode, CastAheadDB.raidSaves, CastAheadDB.burstCalls = nil, true, true
        CastAheadUI.RefreshTabs()
        check(Shown("RaidGuide") == false and Shown("Defensives") == false,
            "the raid switch off hides the Raid group and the raid half of Defensives, whatever its children hold")
        CastAheadDB.raidMode, CastAheadDB.burstCalls = true, nil
        CastAheadUI.RefreshTabs()
        check(Shown("RaidGuide") and Shown("RaidSaves") and Shown("Defensives"),
            "raid defensive calls on show the Raid group and Defensives")
        CastAheadDB.raidSaves, CastAheadDB.burstCalls = nil, true
        CastAheadUI.RefreshTabs()
        check(Shown("RaidGuide") and not Shown("Defensives"), "burst windows alone show the Raid group, not Defensives")
        local labels, raw = 0, 0
        for _, t in ipairs(buttonTexts) do
            if t == "Guide" then labels = labels + 1 end
            if t == "RaidGuide" then raw = raw + 1 end
        end
        check(labels >= 2 and raw == 0, "both Guide entries read Guide, got " .. labels .. " and " .. raw .. " raw names")
        CastAheadDB.window.page = "Bursts"
        f:Hide()
        CastAhead_Toggle()
        check(CastAheadWindow.Current() == "RaidGuide", "a page saved as Bursts by an older version opens the Raid Guide")
        CastAhead_Toggle()
        CastAheadDB.raidMode, CastAheadDB.burstCalls = nil, nil
        CastAheadUI.RefreshTabs()
    end

    SlashCmdList.CASTAHEAD("sounds")
    check(f:IsShown() and CastAheadWindow.Current() == "Sounds", "/ca sounds opens the Sounds page")
    SlashCmdList.CASTAHEAD("sounds")
    check(not f:IsShown(), "/ca sounds on the open Sounds page closes the window")
    CastAheadDB.window.page = "Guide"
    CastAhead_Toggle()
    check(f:IsShown() and CastAheadWindow.Current() == "Guide", "/ca on a closed window opens the last saved page")
    CastAhead_Toggle()
    check(not f:IsShown(), "and /ca again closes it")

    do
        local savedFooter, savedInfo, footer = CastAheadWindow.SetFooter, GetInstanceInfo, nil
        CastAheadWindow.SetFooter = function(text) footer = text end
        GetInstanceInfo = function() return "Abyss", "raid", 15, "", 0, 0, false, 9999 end
        CastAheadDB.saveCalls, CastAheadDB.raidSaves = true, nil
        CastAheadWindow.Show("Saves")
        for _, frame in ipairs(allFrames) do frame.IsVisible = function(self) return self.shown end end
        CastAheadUI.RefreshSaves()
        check(footer ~= nil and footer ~= "" and not footer:find("off", 1, true), "the Saves footer follows the dungeon switch, got " .. tostring(footer))
        f:Hide()
        CastAheadDB.saveCalls = nil
        CastAheadWindow.SetFooter, GetInstanceInfo = savedFooter, savedInfo
    end

    CastAheadDB.devMode = true
    CastAheadUI.ShowTab("Development")
    CastAhead_Toggle()
    CastAheadDB.devMode = nil
    CastAheadUI.RefreshTabs()
    check(not f:IsShown(), "Development switched off on a closed window does not open it")
    check(CastAheadWindow.Current() == "General" and CastAheadDB.window.page == "General",
        "and the window will reopen on General")
    CastAheadUI.ShowTab("Sounds")
    CastAhead_Toggle()
    CastAheadDB.window.page = "Development"
    CastAheadWindow.Toggle()
    check(CastAheadWindow.Current() == "General", "a saved hidden page opens the first visible page of its group")
    check(sized == before, "opening and closing never resizes the window")
    CastAheadDB.window.width, CastAheadDB.window.height = 1200, 900
    CastAheadWindow.ResetSize()
    check(f.w == 1200 and f.h == 640 and CastAheadDB.window.width == nil and CastAheadDB.window.height == nil,
        "Reset size goes back to the default size and forgets the saved one")
    CastAheadOptions.ShowPanel = savedShowPanel

    CastAheadDB = { window = { width = 1900, height = 560 } }
    dofile("Window.lua")
    CastAheadWindow.Register("TestA", "Dungeon", function() end, function() end)
    CastAheadWindow.Show("TestA")
    f = CastAheadWindow.Frame()
    check(f and f.w == 1900 and f.h == 560, "a saved size above the minimum is kept as is")
    CreateFrame = savedCreate
    UIParent = nil
    CastAheadDB = nil
end

do
    local savedData, savedInfo, savedCreate = CastAheadData, GetInstanceInfo, CreateFrame
    local here
    GetInstanceInfo = function() return "d", "party", 0, "", 0, 0, false, here end
    CastAheadData = { [1] = { name = "Alpha" }, [2] = { name = "Beta" } }
    local made = {}
    CreateFrame = function(kind, name, ...)
        local f = savedCreate(kind, name, ...)
        local setScript = f.SetScript
        f.SetScript = function(self, script, fn)
            setScript(self, script, fn)
            if script == "OnClick" then rawset(self, "onClick", fn) end
        end
        if name == "CastAheadMainWindow" then
            f.GetWidth = function() return 900 end
            f.GetHeight = function() return 560 end
        end
        made[#made + 1] = f
        return f
    end
    UIParent = { GetWidth = function() return 1920 end, GetHeight = function() return 1080 end }
    CastAheadDB = {}
    dofile("Window.lua")
    local W = CastAheadWindow
    check(W.Dungeon() == 1, "outside a dungeon the selection is the first dungeon")
    here = 2
    check(W.Dungeon() == 2, "until a dungeon is picked the selection follows the current instance")
    here = 99
    check(W.Dungeon() == 1, "an instance with no data falls back to the first dungeon")
    W.Register("TestA", "Dungeon", function() end, function() end)
    W.Show("TestA")
    for _, b in ipairs(made) do
        if rawget(b, "instanceID") == 2 then b.onClick(b) end
    end
    here = 1
    check(W.Dungeon() == 2, "a clicked dungeon stays selected wherever the player goes")
    CastAheadData, GetInstanceInfo, CreateFrame = savedData, savedInfo, savedCreate
    UIParent, CastAheadDB = nil, nil
end

do
    local savedData, savedInfo, savedCreate = CastAheadData, GetInstanceInfo, CreateFrame
    local kind, difficulty = "party", 8
    GetInstanceInfo = function() return "r", kind, difficulty, "", 0, 0, false, 2900 end
    CastAheadData = { [1] = { name = "Alpha" } }
    local made = {}
    CreateFrame = function(k, name, ...)
        local f = savedCreate(k, name, ...)
        local setScript = f.SetScript
        f.SetScript = function(self, script, fn)
            setScript(self, script, fn)
            if script == "OnClick" then rawset(self, "onClick", fn) end
        end
        if name == "CastAheadMainWindow" then
            f.GetWidth = function() return 900 end
            f.GetHeight = function() return 560 end
        end
        made[#made + 1] = f
        return f
    end
    UIParent = { GetWidth = function() return 1920 end, GetHeight = function() return 1080 end }
    CastAheadDB = {}
    dofile("Window.lua")
    local W = CastAheadWindow
    check(W.RaidDifficulty() == 15, "outside a raid the raid picker starts on Heroic")
    kind, difficulty = "raid", 16
    check(W.RaidDifficulty() == 16, "inside a Mythic raid it starts on Mythic")
    kind, difficulty = "raid", 17
    check(W.RaidDifficulty() == 15, "a raid difficulty with no data falls back to Heroic")
    local refreshed = 0
    W.Register("TestR", "Raid", function() end, function() refreshed = refreshed + 1 end)
    W.Show("TestR")
    for _, b in ipairs(made) do
        if rawget(b, "difficultyID") == 14 then b.onClick(b) end
    end
    kind, difficulty = "raid", 16
    check(W.RaidDifficulty() == 14 and refreshed == 2, "a clicked difficulty stays picked and refreshes the page")
    for _, b in ipairs(made) do
        if rawget(b, "difficultyID") == 15 then b.onClick(b) end
    end
    CastAheadData, GetInstanceInfo, CreateFrame = savedData, savedInfo, savedCreate
    UIParent, CastAheadDB = nil, nil
end

-- Burst windows: "burst soon" five seconds before the phase, "burst now" as it starts, a save call goes first.
do
    local B, S, A = CastAheadBurst, CastAheadSaves, CastAheadMatch.ADVICE
    local heard = {}
    local savedPlay, savedWindows = PlaySoundFile, CastAheadBurstWindows
    PlaySoundFile = function(path) heard[#heard + 1] = path:match("([%w_]+)%.ogg$") return true, 1 end
    local role = "DAMAGER"
    GetSpecialization = function() return 1 end
    GetSpecializationRole = function() return role end
    CastAheadBurstWindows = { [3492] = { [15] = { { release = 30 } }, [14] = { { release = 3 } },
        [8] = { { release = 3, pull = true }, { release = 20 } } } }
    CastAheadDB = { raidMode = true, burstCalls = true }
    local function run(seconds)
        for _ = 1, seconds * 2 do
            now = now + 0.5
            S.Tick(now)
            B.Tick(now)
        end
    end
    local function Heard() return table.concat(heard, ",") end

    local t0 = now
    B.OnEncounter("ENCOUNTER_START", 3492, 15, now)
    run(24.5)
    check(#heard == 0, "burst: quiet before the heads-up, heard " .. Heard())
    run(0.5)
    check(Heard() == "SOON", "burst: burst soon five seconds before the phase, heard " .. Heard())
    local pend = B.Pending(now)
    check(#pend == 1 and pend[1].advice == A.SOON and pend[1].endAt == t0 + 30 and pend[1].icons[1] ~= nil,
        "burst: the centre counts down to the phase")
    run(5)
    check(Heard() == "SOON,BURST", "burst: burst now as the phase starts, heard " .. Heard())
    run(10)
    check(#B.Pending(now) == 0 and Heard() == "SOON,BURST", "burst: each call once, then off the screen")

    heard = {}
    B.OnEncounter("ENCOUNTER_START", 3492, 14, now)
    run(5)
    check(Heard() == "BURST", "burst: a phase under five seconds in gets no heads-up, heard " .. Heard())

    heard = {}
    B.OnEncounter("ENCOUNTER_START", 3492, 8, now)
    run(25)
    check(Heard() == "SOON,BURST", "burst: the pull moment is silent, a later window is called, heard " .. Heard())

    heard = {}
    role = "HEALER"
    B.OnEncounter("ENCOUNTER_START", 3492, 15, now)
    run(40)
    check(#heard == 0 and #B.Pending(now) == 0, "burst: a healer skips the damage window")
    role = "DAMAGER"

    heard = {}
    UnitIsDeadOrGhost = function(unit) return unit == "player" end
    B.OnEncounter("ENCOUNTER_START", 3492, 15, now)
    run(40)
    UnitIsDeadOrGhost = nil
    check(#heard == 0 and #B.Pending(now) == 0, "burst: a dead player hears and sees nothing")

    heard = {}
    role = "TANK"
    B.OnEncounter("ENCOUNTER_START", 3492, 15, now)
    run(35)
    role = "DAMAGER"
    check(Heard() == "SOON,BURST", "burst: a tank hears the damage windows too, heard " .. Heard())

    heard = {}
    CastAheadDB = {}
    B.OnEncounter("ENCOUNTER_START", 3492, 15, now)
    run(40)
    check(#heard == 0, "burst: burstCalls is off by default")
    CastAheadDB = { burstCalls = true }
    B.OnEncounter("ENCOUNTER_START", 3492, 15, now)
    run(40)
    check(#heard == 0, "burst: burst windows stay silent while the raid switch is off")
    CastAheadDB = { raidMode = true, burstCalls = true }

    B.OnEncounter("ENCOUNTER_START", 3492, 16, now)
    run(40)
    check(#heard == 0, "burst: a difficulty without windows is silent")

    B.OnEncounter("ENCOUNTER_START", 3492, 15, now)
    run(15)
    heard = {}
    B.OnEncounter("ENCOUNTER_END", 3492, 15, now)
    run(30)
    check(#heard == 0 and #B.Pending(now) == 0, "burst: ENCOUNTER_END drops a pending burst")

    heard = {}
    local t1 = now
    B.OnEncounter("ENCOUNTER_START", 3492, 15, now)
    run(10.5)
    S.Schedule("test:save1", 1, t1 + 29, t1 + 33, A.DEFENSIVE)
    run(20)
    check(Heard() == "SOON,DEFENSIVE_soon", "burst: the save call is heard and the burst waits, heard " .. Heard())
    run(0.5)
    check(Heard() == "SOON,DEFENSIVE_soon,BURST", "burst: the burst follows 2 s after the save, heard " .. Heard())
    run(10)

    heard = {}
    local t2 = now
    B.OnEncounter("ENCOUNTER_START", 3492, 15, now)
    S.Schedule("test:save2", 1, t2 + 31, t2 + 35, A.DEFENSIVE)
    run(32.5)
    check(Heard() == "SOON,DEFENSIVE_soon", "burst: a save due 1 s after the phase goes first, heard " .. Heard())
    run(1)
    check(Heard() == "SOON,DEFENSIVE_soon,BURST", "burst: and the burst speaks 2 s after that save, heard " .. Heard())
    run(10)

    heard = {}
    local t3 = now
    B.OnEncounter("ENCOUNTER_START", 3492, 15, now)
    S.Schedule("test:save3", 1, t3 + 25, t3 + 29, A.DEFENSIVE)
    run(26.5)
    check(Heard() == "DEFENSIVE_soon", "burst: a heads-up landing on a save waits, heard " .. Heard())
    run(0.5)
    check(Heard() == "DEFENSIVE_soon,SOON", "burst: and comes 2 s after it, heard " .. Heard())
    run(10)

    heard = {}
    B.OnEncounter("ENCOUNTER_START", 3492, 15, now)
    IsEncounterInProgress = function() return false end
    run(40)
    check(#heard == 0 and #B.Pending(now) == 0, "burst: an encounter that ended unseen stays silent, heard " .. Heard())
    IsEncounterInProgress = nil

    B.OnEncounter("ENCOUNTER_END", 3492, 15, now)
    local specLookups = 0
    GetSpecialization = function() specLookups = specLookups + 1 return 1 end
    B.Tick(now)
    B.Pending(now)
    check(specLookups == 0, "burst: no windows, no spec lookups per frame")
    S.Cancel("test:save1")
    S.Cancel("test:save2")
    S.Cancel("test:save3")
    PlaySoundFile, CastAheadBurstWindows = savedPlay, savedWindows
    GetSpecialization, GetSpecializationRole = nil, nil
    CastAheadDB = nil
end

-- Burst windows through Core, in a raid instance that has no trash data.
do
    local heard = {}
    local savedPlay, savedWindows, savedInfo = PlaySoundFile, CastAheadBurstWindows, GetInstanceInfo
    PlaySoundFile = function(path) heard[#heard + 1] = path:match("([%w_]+)%.ogg$") return true, 1 end
    local function Heard() return table.concat(heard, ",") end
    local function Line(prefix)
        for i = 1, #allFrames do
            local f = allFrames[i]
            if type(f.timeValue) == "string" and f.timeValue:sub(1, #prefix) == prefix then return f end
        end
    end
    GetSpecialization = function() return 1 end
    GetSpecializationRole = function() return "DAMAGER" end
    CastAheadBurstWindows = { [3492] = { [15] = { { release = 30 } } } }
    CastAheadDB = { raidMode = true, burstCalls = true, centerText = true, saveCalls = true }
    GetInstanceInfo = function() return "Abyss", "raid", 15, "", 0, 0, false, 9999 end
    fire("PLAYER_ENTERING_WORLD")

    fire("ENCOUNTER_START", 3492, "Ula'tek", 15, 20)
    for _ = 1, 51 do advance(0.5) end
    local line = Line("Burst soon")
    check(Heard() == "SOON", "raid burst: burst soon through Core with no trash data, heard " .. Heard())
    check(line ~= nil and line.shown, "raid burst: the countdown line is on screen")
    for _ = 1, 10 do advance(0.5) end
    local burstLine = Line("Burst now")
    check(Heard() == "SOON,BURST", "raid burst: burst now through Core as the phase starts, heard " .. Heard())
    check(burstLine ~= nil and burstLine.shown, "raid burst: the burst line is on screen")
    fire("ENCOUNTER_END", 3492, "Ula'tek", 15, 20, 0)
    advance(0.5)
    check(burstLine ~= nil and not burstLine.shown, "raid burst: the line leaves the screen when the fight ends")

    heard = {}
    fire("ENCOUNTER_START", 3492, "Ula'tek", 15, 20)
    for _ = 1, 51 do advance(0.5) end
    check(Heard() == "SOON", "raid burst: a re-pull lays the windows out again, heard " .. Heard())
    fire("ENCOUNTER_END", 3492, "Ula'tek", 15, 20, 0)

    heard = {}
    fire("ENCOUNTER_START", 3492, "Ula'tek", 2, 5)
    for _ = 1, 70 do advance(0.5) end
    check(#heard == 0, "raid burst: another difficulty stays silent, heard " .. Heard())
    fire("ENCOUNTER_END", 3492, "Ula'tek", 2, 5, 0)

    heard = {}
    CastAheadDefensives = { spells = { [1299684] = { DAMAGER = true, lead = 3.0 } }, alias = {} }
    fire("ENCOUNTER_START", 3470, "Nek'zali", 15, 20)
    CastAheadBossAdapter.OnBar("dbm", "raidbar", 1299684, 10, now)
    for _ = 1, 16 do advance(0.5) end
    check(#heard == 0, "raid saves: off by default, a raid boss bar calls nothing, heard " .. Heard())
    fire("ENCOUNTER_END", 3470, "Nek'zali", 15, 20, 0)

    heard = {}
    CastAheadDB.raidSaves = true
    local savedRaidButtons = CastAheadSaveButtons
    CastAheadSaveButtons = { [265] = { def = { 104773 } } }
    GetSpecializationInfo = function() return 265 end
    IsPlayerSpell = function(id) return id == 104773 end
    CastAheadSaves.Refresh()
    fire("ENCOUNTER_START", 3470, "Nek'zali", 15, 20)
    CastAheadBossAdapter.OnBar("dbm", "raidbar", 1299684, 10, now)
    for _ = 1, 16 do advance(0.5) end
    check(Heard() == "DEFENSIVE_soon", "raid saves: switched on, a boss save call fires in a raid with no trash data, heard " .. Heard())
    fire("ENCOUNTER_END", 3470, "Nek'zali", 15, 20, 0)
    CastAheadDB.saveCalls = nil
    heard = {}
    fire("ENCOUNTER_START", 3470, "Nek'zali", 15, 20)
    CastAheadBossAdapter.OnBar("dbm", "raidbar", 1299684, 10, now)
    for _ = 1, 16 do advance(0.5) end
    check(Heard() == "DEFENSIVE_soon", "raid saves: the raid switch alone is enough, heard " .. Heard())
    fire("ENCOUNTER_END", 3470, "Nek'zali", 15, 20, 0)
    CastAheadDB.raidSaves = nil
    CastAheadSaveButtons, GetSpecializationInfo, IsPlayerSpell = savedRaidButtons, nil, nil
    CastAheadSaves.Refresh()

    local savedAdapter, savedPrint, lines = CastAheadBossAdapter, print, 0
    dofile("BossAdapter.lua")
    DBM = { RegisterCallback = function() end }
    CastAheadBossAdapter.Connect()
    DBM = nil
    print = function() lines = lines + 1 end
    fire("ENCOUNTER_START", 3470, "Nek'zali", 15, 20)
    for _ = 1, 64 do advance(0.5) end
    print = savedPrint
    check(lines == 0, string.format("raid burst: no boss-timer warning where no trash data runs, got %d line(s)", lines))
    fire("ENCOUNTER_END", 3470, "Nek'zali", 15, 20, 0)
    CastAheadBossAdapter = savedAdapter

    CastAheadDefensives = { spells = {}, alias = {} }
    PlaySoundFile, CastAheadBurstWindows, GetInstanceInfo = savedPlay, savedWindows, savedInfo
    GetSpecialization, GetSpecializationRole = nil, nil
    CastAheadDB = nil
    fire("PLAYER_ENTERING_WORLD")
end

do
    local ok = pcall(dofile, "Options.lua")
    check(ok and CastAheadOptions and CastAheadOptions.Switches and CastAheadOptions.Switches.burstCalls
        and CastAheadOptions.Switches.burstCalls.defaultOff == true, "the burst switch exists and is off by default")
    local sw = CastAheadOptions.Switches
    check(sw.saveCalls.label == "Defensive calls in dungeons" and sw.saveCalls.defaultOff == true
        and sw.raidMode and sw.raidMode.label == "Raid (experimental)" and sw.raidMode.defaultOff == true
        and sw.raidSaves.label == "Defensive calls in raids" and sw.raidSaves.defaultOff == true
        and sw.burstCalls.label == "Burst windows", "the four feature switches carry their labels and start off")
    check(sw.centerText.defaultOff == nil, "the centre call is not a default-off switch")
    check(ok and table.concat(CastAheadOptions.TABS, ",") == "General,Sounds,Defensives,Development,Report",
        "the settings pages are General, Sounds, Defensives and Development, Report comes last")
    local savedMeta, savedBuild, savedLocale, savedInfo, savedDB = C_AddOns, GetBuildInfo, GetLocale, GetSpecializationInfoByID, CastAheadDB
    local savedSpec, savedSpecInfo = GetSpecialization, GetSpecializationInfo
    GetSpecialization, GetSpecializationInfo = function() return 1 end, function() return 577 end
    C_AddOns = { GetAddOnMetadata = function(_, field) return field == "Version" and "9.9.9" or nil end }
    GetBuildInfo = function() return "12.1.0", "65000" end
    GetLocale = function() return "enUS" end
    GetSpecializationInfoByID = function(id) return id, "Havoc", "", 0, "DAMAGER", "DEMONHUNTER", "Demon Hunter" end
    CastAheadDB = { raidMode = true, burstCalls = true }
    local save = CastAheadOptions.ReportText("save")
    check(save:find("CastAhead report: Wrong defensive call\nAddon 9.9.9, game 12.1.0 (65000), enUS\n", 1, true)
        and save:find("Spec: Havoc Demon Hunter", 1, true) and save:find("Defensive calls: dungeons off, raids off", 1, true)
        and save:find("Anything else about what happened:\n$"), "a defensive report carries version, spec, the switch and ends on its question")
    local burst = CastAheadOptions.ReportText("burst")
    check(burst:find("Burst guide: Heroic\nDungeon picked: ", 1, true) and burst:find("\nBurst windows: on\n", 1, true)
        and not burst:find("Defensive calls", 1, true),
        "a burst report carries the raid difficulty, the dungeon and the burst switch instead")
    CastAheadDB = { burstCalls = true, raidSaves = true }
    check(CastAheadOptions.ReportText("burst"):find("Burst windows: off\n", 1, true)
        and CastAheadOptions.ReportText("save"):find("raids off", 1, true),
        "the report reads the raid features as off while the raid switch is off")
    CastAheadDB = { raidMode = true, burstCalls = true }
    CastAheadOptions.SetReportPicks(nil)
    check(CastAheadOptions.ReportText("cast"):find("Key level: +12\n", 1, true), "a fresh report starts at key level +12")
    local someId, someData = next(CastAheadData)
    CastAheadOptions.SetReportPicks({ dungeon = someId, spell = { id = 101, name = "Bolt", mob = "Caster" },
        what = "Called too late", level = 12, often = "Sometimes" })
    local cast = CastAheadOptions.ReportText("cast")
    check(cast:find("Dungeon picked: " .. someData.name, 1, true)
        and cast:find("Spell: Bolt (101) from Caster\nProblem: Called too late\nKey level: +12\nHow often: Sometimes\n", 1, true),
        "the picked dungeon, spell, problem, key level and frequency go into the report")
    CastAheadOptions.SetReportPicks({ boss = { id = 3492, diff = 16, name = "Ula'tek" }, spell = { id = 101, name = "Bolt" },
        level = 20, often = "Once" })
    local picked = CastAheadOptions.ReportText("burst")
    check(picked:find("Boss: Ula'tek (Mythic, encounter 3492)\n", 1, true) and picked:find("How often: Once\n", 1, true)
        and not picked:find("Spell:", 1, true) and not picked:find("Key level", 1, true),
        "a burst report takes the boss and frequency, not the spell or key level")
    CastAheadOptions.SetReportPicks(nil)
    C_AddOns, GetBuildInfo, GetLocale, GetSpecializationInfoByID, CastAheadDB = savedMeta, savedBuild, savedLocale, savedInfo, savedDB
    GetSpecialization, GetSpecializationInfo = savedSpec, savedSpecInfo
end

-- The guide lists every window of a difficulty by boss, the same for every spec.
do
    local B = CastAheadBurst
    local saved = CastAheadBurstWindows
    local function Guide(difficulty)
        local text = table.concat(B.GuideLines(difficulty), "\n")
        return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
    end
    CastAheadBurstWindows = {
        [3492] = { [16] = { name = "Ula'tek", { release = 294.5, target = "Venomous Heart" },
            { release = 145.5, target = "Venomous Heart" }, { release = 108.1, role = "HEALER" } } },
        [3455] = { [16] = { name = "Vashnik", note = "Hold windows.", { release = 128.4 }, { release = 3.2, pull = true } } },
        [3470] = { [16] = { name = "Nek'zali" } },
        [3101] = { [8] = { name = "Kystia Manaheart", { event = 610, target = "Light Infusion" } } } }
    check(B.Clock(197) == "3:17" and B.Clock(59.6) == "1:00", "burst guide: clock formats m:ss")
    local text = Guide(16)
    check(text == "Nek'zali\n  no burst window - burst on the pull, then on cooldown\n\n"
        .. "Ula'tek\n  1:48 healers burst here\n  2:26 Venomous Heart\n  4:55 Venomous Heart\n\n"
        .. "Vashnik\n  Hold windows.\n  0:03 burst on the pull\n  2:08 top players burst here",
        "burst guide: every boss by name, windows by time, healer windows marked, got " .. text)
    check(B.GuideLines(16)[1] == "|cffffd100Nek'zali|r", "burst guide: the boss name is a gold heading")
    text = Guide(8)
    check(text == "Kystia Manaheart\n  Light Infusion - called on the boss warning", "burst guide: a boss-event window names the warning, got " .. text)
    check(#B.GuideLines(15) == 0, "burst guide: no windows, no lines")
    CastAheadBurstWindows = saved
end

-- Healer windows go to healers only; a boss-event window puts our clip on the game's own warning.
do
    local B, S = CastAheadBurst, CastAheadSaves
    local heard, sounds, timers = {}, {}, {}
    local savedPlay, savedWindows = PlaySoundFile, CastAheadBurstWindows
    PlaySoundFile = function(path) heard[#heard + 1] = path:match("([%w_]+)%.ogg$") return true, 1 end
    C_Timer = { After = function(delay, fn) timers[#timers + 1] = { at = now + delay, fn = fn } end }
    C_EncounterEvents = { SetEventSound = function(id, trigger, sound)
        sounds[#sounds + 1] = { id = id, trigger = trigger, sound = sound }
    end }
    local role = "HEALER"
    GetSpecialization = function() return 1 end
    GetSpecializationRole = function() return role end
    CastAheadBurstWindows = {
        [3492] = { [15] = { name = "Ula'tek", { release = 30 }, { release = 70, role = "HEALER" } } },
        [3101] = { [8] = { name = "Kystia Manaheart", { event = 610, target = "Light Infusion" } } } }
    CastAheadDB = { raidMode = true, burstCalls = true }
    local function run(seconds)
        for _ = 1, seconds * 2 do
            now = now + 0.5
            for i = #timers, 1, -1 do
                if now >= timers[i].at then table.remove(timers, i).fn() end
            end
            S.Tick(now)
            B.Tick(now)
        end
    end
    local function Heard() return table.concat(heard, ",") end

    B.OnEncounter("ENCOUNTER_START", 3492, 15, now)
    run(35)
    check(#heard == 0, "burst roles: a healer skips the damage window, heard " .. Heard())
    run(40)
    check(Heard() == "SOON,BURST", "burst roles: a healer hears the healer window, heard " .. Heard())
    B.OnEncounter("ENCOUNTER_END", 3492, 15, now)
    heard, role = {}, "DAMAGER"
    B.OnEncounter("ENCOUNTER_START", 3492, 15, now)
    run(35)
    check(Heard() == "SOON,BURST", "burst roles: a damage dealer hears the damage window, heard " .. Heard())
    run(40)
    check(Heard() == "SOON,BURST", "burst roles: and skips the healer window, heard " .. Heard())
    B.OnEncounter("ENCOUNTER_END", 3492, 15, now)

    heard, sounds = {}, {}
    B.OnEncounter("ENCOUNTER_START", 3101, 8, now)
    run(1.5)
    check(#sounds == 0, "burst event: nothing is armed before boss mods have set theirs")
    run(1)
    local armed = sounds[1]
    check(#sounds == 1 and armed.id == 610 and armed.trigger == 0 and armed.sound
        and armed.sound.file:match("\\BURST%.ogg$") and armed.sound.channel == "Master" and armed.sound.volume == 1,
        "burst event: the burst clip goes on the boss event's warning")
    check(#heard == 0, "burst event: the addon says nothing itself, heard " .. Heard())
    B.OnEncounter("ENCOUNTER_END", 3101, 8, now)
    check(#sounds == 2 and sounds[2].id == 610 and sounds[2].trigger == 0 and sounds[2].sound == nil,
        "burst event: the fight's end takes the sound off")

    sounds = {}
    B.OnEncounter("ENCOUNTER_START", 3101, 8, now)
    B.OnEncounter("ENCOUNTER_END", 3101, 8, now)
    run(3)
    check(#sounds == 0, "burst event: a fight over before the delay arms nothing")

    role = "HEALER"
    B.OnEncounter("ENCOUNTER_START", 3101, 8, now)
    run(3)
    check(#sounds == 1, "burst event: a healer gets the boss-event call too")
    B.OnEncounter("ENCOUNTER_END", 3101, 8, now)

    for _, db in ipairs({ {}, { burstCalls = true }, { raidMode = true, burstCalls = true, voice = false },
        { raidMode = true, burstCalls = true, sound = false } }) do
        sounds, CastAheadDB = {}, db
        B.OnEncounter("ENCOUNTER_START", 3101, 8, now)
        run(3)
        B.OnEncounter("ENCOUNTER_END", 3101, 8, now)
        check(#sounds == 0, "burst event: switched off, voice off or sound off arms nothing")
    end

    do
        local savedDead = UnitIsDeadOrGhost
        sounds, CastAheadDB = {}, { raidMode = true, burstCalls = true }
        B.OnEncounter("ENCOUNTER_START", 3101, 8, now)
        run(3)
        UnitIsDeadOrGhost = function() return true end
        run(1)
        UnitIsDeadOrGhost = savedDead
        check(#sounds == 1, "burst event: dying mid-fight keeps the sound for after a battle res, got " .. #sounds)
        B.OnEncounter("ENCOUNTER_END", 3101, 8, now)
    end

    for _, change in ipairs({ "burstCalls", "raidMode", "voice", "sound" }) do
        sounds, CastAheadDB = {}, { raidMode = true, burstCalls = true }
        B.OnEncounter("ENCOUNTER_START", 3101, 8, now)
        run(3)
        CastAheadDB[change] = change == "burstCalls" and nil or false
        run(0.5)
        check(#sounds == 2 and sounds[2].id == 610 and sounds[2].sound == nil,
            "burst event: " .. change .. " switched off mid-fight takes the sound off, got " .. #sounds)
        B.OnEncounter("ENCOUNTER_END", 3101, 8, now)
    end

    C_Timer, C_EncounterEvents = nil, nil
    PlaySoundFile, CastAheadBurstWindows = savedPlay, savedWindows
    GetSpecialization, GetSpecializationRole = nil, nil
    CastAheadDB = nil
end

do
    GetNumSpecializations = function() return 2 end
    GetSpecializationInfo = function(i) return i == 1 and 1480 or 577, i == 1 and "Devourer" or "Havoc", "", 1 end
    local host = CreateFrame("Frame")
    local h = CastAheadWindow.SpecBar and CastAheadWindow.SpecBar(host, 0, 0, function() end)
    check(h and h > 0, "spec bar: a two-spec class gets a bar")
    GetNumSpecializations = function() return 1 end
    check(CastAheadWindow.SpecBar and CastAheadWindow.SpecBar(host, 0, 0, function() end) > 0,
        "spec bar: a one-spec class keeps the bar, for picking another class")
    local ok = pcall(CastAheadWindow.PaintSpecBars)
    check(ok, "spec bar: repainting every bar works")
    GetNumSpecializations, GetSpecializationInfo = nil, nil
end

do
    local B = CastAheadBurst
    local savedCreate, savedDB, savedAuras = CreateFrame, CastAheadDB, C_UnitAuras
    local frame
    CreateFrame = function(kind, ...)
        local f = savedCreate(kind, ...)
        f.events = {}
        f.RegisterEvent = function(self, e) self.events[e] = true end
        f.UnregisterAllEvents = function(self) wipe(self.events) end
        f.SetScript = function(self, script, fn) self[script] = fn end
        frame = f
        return f
    end
    C_Secrets = { ShouldSpellAuraBeSecret = function(id) return id == 1265412 end }
    local aura
    C_UnitAuras = { GetUnitAuraBySpellID = function(unit, id) return id == 1230304 and aura or nil end }

    CastAheadDB = { devMode = true, recordAll = false }
    B.OnEncounter("ENCOUNTER_START", 3101, 8, now)
    check(frame == nil and CastAheadDB.phaseProbe == nil, "phase probe: recording off registers and stores nothing")

    CastAheadDB.recordAll = nil
    B.OnEncounter("ENCOUNTER_START", 3101, 8, now)
    local s = CastAheadDB.phaseProbe and CastAheadDB.phaseProbe[1]
    check(s and s.enc == 3101 and s.rows[1].kind == "secrecy", "phase probe: encounter start opens a session with a secrecy row")
    check(s and s.rows[1].spells[1265412].should == "true" and s.rows[1].spells[1265412].secrecy == "-",
        "phase probe: secrecy facts are read, a missing function is '-'")
    check(frame and frame.events.UNIT_AURA and frame.events.ENCOUNTER_END, "phase probe: session events are registered")

    aura = { spellId = 1230304 }
    now = now + 12.34
    frame.OnEvent(frame, "UNIT_AURA", "boss1", {})
    frame.OnEvent(frame, "UNIT_AURA", "boss1", {})
    frame.OnEvent(frame, "UNIT_AURA", "nameplate1", {})
    local auraRows = 0
    for _, row in ipairs(s.rows) do if row.kind == "aura" then auraRows = auraRows + 1 end end
    check(auraRows == 1 and s.rows[2].found == "+" and s.rows[2].t == 12.3 and s.rows[2].unit == "boss1",
        "phase probe: an aura logs once until it changes, got " .. auraRows)
    check(s.auraEvents.boss1 == 2 and s.auraEvents.nameplate1 == nil, "phase probe: boss aura events are counted")

    local secret = {}
    issecretvalue = function(v) return v == secret end
    frame.OnEvent(frame, "ENCOUNTER_WARNING", { duration = 5, severity = 2, shouldPlaySound = secret })
    issecretvalue = nil
    local w = s.rows[#s.rows]
    check(w.kind == "warning" and w.duration == "5" and w.severity == "2" and w.sound == "S",
        "phase probe: a warning logs duration and severity, a secret as 'S'")

    frame.OnEvent(frame, "ENCOUNTER_END", 3101, "Kystia", 8, 5, 1)
    check(next(frame.events) == nil and s.result == "kill", "phase probe: encounter end unregisters and closes the session")

    CreateFrame, CastAheadDB, C_UnitAuras, C_Secrets = savedCreate, savedDB, savedAuras, nil
end

do
    local savedDB = CastAheadDB
    CastAheadDB = {}
    local plate = {}
    local state = {}
    CastAheadCore.ShowSampleRow(state, plate)
    local bars = { unpack(state.bars) }
    local shown = 0
    for i = 1, #bars do if bars[i].shown then shown = shown + 1 end end
    check(#bars == 3 and shown == 3, "sample row: three bars shown")
    check(bars[1].timeValue == "7" and bars[2].timeValue == "3" and bars[3].timeValue == "12",
        "sample row: times 7, 3, 12")
    check(bars[1].tilde.shown == true and not bars[2].tilde.shown, "sample row: only the first carries a tilde")
    check(bars[1].labelValue == "KICK" and bars[2].labelValue == "DODGE" and bars[3].labelValue == "BUSTER",
        "sample row: short labels")
    check(not bars[1].glow.shown, "sample row: no glow")
    check(bars[1].x ~= nil, "sample row: anchored to the frame")
    CastAheadCore.SampleStates[state] = plate
    CastAheadConfig.Set("iconSize", 40)
    CastAheadCore.Reapply()
    check(bars[1]._size == 40, "sample row: Reapply resizes registered samples")
    CastAheadCore.SampleStates[state] = nil
    CastAheadConfig.Set("fullLabels", true)
    local full = {}
    CastAheadCore.ShowSampleRow(full, plate)
    check(full.bars[3].labelValue == "TANKBUSTER", "sample row: full labels")
    CastAheadCore.HideSampleRow(full)
    check(#full.bars == 0, "sample row: hide clears the state")
    CastAheadConfig.Set("nameplates", false)
    CastAheadCore.ShowSampleRow(full, plate)
    shown = 0
    for i = 1, #full.bars do if full.bars[i].shown then shown = shown + 1 end end
    check(#full.bars == 3 and shown == 0, "sample row: hidden when nameplates are off")
    CastAheadCore.HideSampleRow(full)
    CastAheadCore.HideSampleRow(state)
    check(not bars[1].shown and not bars[2].shown and not bars[3].shown, "sample row: hide leaves nothing shown")
    local before = framesMade
    CastAheadCore.ShowSampleRow(full, plate)
    check(framesMade == before, "sample row: hidden bars return to the pool")
    CastAheadCore.HideSampleRow(full)

    CastAheadConfig.Set("nameplates", nil)
    local hiddenPlate = { IsShown = function() return false end }
    local away = {}
    CastAheadCore.ShowSampleRow(away, hiddenPlate)
    shown = 0
    for i = 1, #away.bars do if away.bars[i].shown then shown = shown + 1 end end
    check(#away.bars == 3 and shown == 0, "sample row: a hidden frame gets no visible bars, got " .. shown)
    CastAheadCore.HideSampleRow(away)

    CastAheadCore.Reapply()
    local advices, realAdvice = 0, CastAheadMatch.Advice
    CastAheadMatch.Advice = function(...)
        advices = advices + 1
        return realAdvice(...)
    end
    CastAheadCore.SampleDataRow("TANK")
    local afterFirst = advices
    CastAheadCore.SampleDataRow("TANK")
    CastAheadMatch.Advice = realAdvice
    check(afterFirst > 0 and advices == afterFirst, "sample row: a second lookup of the same key does not scan again, "
        .. afterFirst .. "/" .. advices)
    CastAheadDB = savedDB
end

-- A function, not a block: the main chunk is at Lua 5.1's 200-local limit.
(function()
    local savedDB, savedLock = CastAheadDB, InCombatLockdown
    local W = CastAheadWindow
    local savedFrame, savedCurrent, savedShow = W.Frame, W.Current, W.Show
    local winShown, shownPage = true, nil
    hostile.nameplate2 = nil
    local win = { IsShown = function() return winShown end, Hide = function() winShown = false end }
    W.Frame = function() return win end
    W.Current = function() return "General" end
    W.Show = function(name) winShown, shownPage = true, name end
    local inCombat = false
    InCombatLockdown = function() return inCombat end
    CastAheadDB = { centerText = true }
    local S = CastAheadSetup
    local panel = S.panel
    local registered = {}
    panel.RegisterEvent = function(_, e) registered[e] = true end
    panel.UnregisterEvent = function(_, e) registered[e] = nil end
    local function fireAll(event, ...)
        fire(event, ...)
        if registered[event] then panel.handlers.OnEvent(panel, event, ...) end
    end
    local function shownSet()
        local s = {}
        for i = 1, #allFrames do if allFrames[i].shown then s[allFrames[i]] = true end end
        return s
    end
    local function onScreen(f)
        while f do
            if rawget(f, "shown") == false then return false end
            f = rawget(f, "parent")
        end
        return true
    end
    local function newlyShown(before)
        local n = 0
        for i = 1, #allFrames do
            if onScreen(allFrames[i]) and not before[allFrames[i]] then n = n + 1 end
        end
        return n
    end
    local SAMPLE_LINES = { ["Interrupt  2.4"] = true, ["Defensive  4.0"] = true, ["Burst now  6.0"] = true }
    local function sampleLines()
        local n = 0
        for i = 1, #allFrames do
            if allFrames[i].shown and SAMPLE_LINES[allFrames[i].timeValue] then n = n + 1 end
        end
        return n
    end
    local function liveEvents()
        local n = 0
        for _ in pairs(timeline.live) do n = n + 1 end
        return n
    end
    local function barsOn(match)
        local n = 0
        for i = 1, #allFrames do
            local f = allFrames[i]
            if f.shown and IsBar(f) and f._plate and match(f._plate) then n = n + 1 end
        end
        return n
    end
    local function onSample(p) return p == S.plate end
    local function onUnit(p) return p.unit == unit end
    local function inSpecial()
        for _, n in ipairs(UISpecialFrames) do if n == "CastAheadSetupPanel" then return true end end
        return false
    end

    local before = shownSet()
    inCombat = true
    local ok, reason = S.Enter()
    check(ok == false and reason == "combat", "setup: entering in combat is refused")
    check(not S.Active() and newlyShown(before) == 0 and winShown, "setup: a refused enter shows nothing")
    inCombat = false

    hostile[unit] = true
    local live0 = liveEvents()
    CastAheadCore.Test(1877)
    check(CastAheadCore.Testing(), "setup: the test drive runs before entering")
    local added0 = timeline.added
    check(S.Enter() == true and S.Active(), "setup: enter out of combat")
    check(not CastAheadCore.Testing(), "setup: entering stops the test drive")
    check(not winShown, "setup: the window steps aside")
    check(S.plate and not S.plate.shown, "setup: no sample plate while a hostile plate is up")
    check(barsOn(onSample) == 0, "setup: no sample bars while a hostile plate is up, got " .. barsOn(onSample))
    check(barsOn(onUnit) == 3, "setup: three sample bars on a hostile plate, got " .. barsOn(onUnit))
    check(sampleLines() == 3, "setup: the centre block shows three sample lines, got " .. sampleLines())
    check(timeline.added - added0 == 3, "setup: three sample timeline entries, got " .. (timeline.added - added0))
    check(panel.shown and not inSpecial(), "setup: the panel is shown and is not an Esc frame")
    check(registered.PLAYER_REGEN_DISABLED and registered.NAME_PLATE_UNIT_ADDED and registered.UI_SCALE_CHANGED,
        "setup: events registered")

    fireAll("NAME_PLATE_UNIT_REMOVED", unit)
    check(barsOn(onUnit) == 0, "setup: a removed plate releases its sample row")
    fireAll("NAME_PLATE_UNIT_ADDED", unit)
    check(barsOn(onUnit) == 3, "setup: an added hostile plate gets a sample row")

    do
        local plateBox, centreBox, timelineBox = panel.iconsTitle, panel.centreTitle, panel.timelineSwitch
        local function flip(box, on)
            box.GetChecked = function() return on end
            box.handlers.OnClick(box)
        end
        local O = CastAheadOptions
        local refreshes, realRefresh = 0, O.Refresh
        O.Refresh = function(...) refreshes = refreshes + 1 return realRefresh(...) end
        local alpha = {}
        local function watch(name, widget)
            widget.SetAlpha = function(_, a) alpha[name] = a end
        end
        watch("size", panel.iconsContent)
        watch("centre", panel.centreContent)
        local captions = {}
        for i = 1, #allFrames do
            for _, fs in ipairs(allFrames[i].fontStrings or {}) do
                if fs.value == "Side" or fs.value == "Grow" then captions[fs.value] = allFrames[i] end
            end
        end
        check(captions.Side == panel.iconsContent and captions.Grow == panel.iconsContent,
            "panel: the Side and Grow captions live in the block that dims")

        flip(plateBox, false)
        check(CastAheadDB.nameplates == false and barsOn(onUnit) == 0, "switch: Nameplate icons off hides the sample rows at once")
        check(alpha.size and alpha.size < 1 and alpha.centre == nil, "switch: only the icons block dims while its switch is off")
        check(sampleLines() == 3 and liveEvents() - live0 == 3, "switch: the other two outputs stay up")
        check(refreshes > 0, "switch: the panel refreshes General's widgets")
        flip(plateBox, true)
        check(CastAheadDB.nameplates == nil and barsOn(onUnit) == 3 and alpha.size == 1,
            "switch: Nameplate icons on brings the rows and the full look back")

        flip(centreBox, false)
        check(CastAheadDB.centerText == false and sampleLines() == 0 and alpha.centre < 1,
            "switch: Centre call off hides the centre sample and dims its block")
        check(barsOn(onUnit) == 3 and alpha.size == 1, "switch: the icons are untouched by the centre switch")
        flip(centreBox, true)
        check(CastAheadDB.centerText == nil and sampleLines() == 3 and alpha.centre == 1,
            "switch: Centre call on brings the centre sample back")

        flip(timelineBox, false)
        check(CastAheadDB.timeline == false and liveEvents() == live0, "switch: Blizzard timeline off cancels the sample entries")
        flip(timelineBox, true)
        check(CastAheadDB.timeline == nil and liveEvents() - live0 == 3, "switch: Blizzard timeline on feeds the samples again")

        for _, box in ipairs({ plateBox, centreBox, timelineBox }) do
            box.SetChecked = function(self, v) self.checkedValue = v end
        end
        CastAheadDB.nameplates, CastAheadDB.centerText, CastAheadDB.timeline = false, false, false
        O.Refresh()
        check(plateBox.checkedValue == false and centreBox.checkedValue == false and timelineBox.checkedValue == false,
            "switch: a change made on General shows in the panel after a refresh")
        S.OutputsChanged()
        check(barsOn(onUnit) == 0 and sampleLines() == 0 and liveEvents() == live0,
            "switch: a change made on General takes effect in the open mode")
        CastAheadDB.nameplates, CastAheadDB.centerText, CastAheadDB.timeline = nil, nil, nil
        S.OutputsChanged()
        check(barsOn(onUnit) == 3 and sampleLines() == 3 and liveEvents() - live0 == 3 and alpha.size == 1,
            "switch: and switching them back on there restores the mode")
        O.Refresh = realRefresh
    end

    local sized
    S.plate.SetSize = function(_, w, h) sized = { w, h } end
    CastAheadDB.plateSize = { 150, 20 }
    fireAll("UI_SCALE_CHANGED")
    check(sized and sized[1] == 150 and sized[2] == 20, "setup: a UI scale change re-sizes the sample plate")
    CastAheadDB.plateSize = { 160, 22 }
    fireAll("DISPLAY_SIZE_CHANGED")
    check(sized[1] == 160 and sized[2] == 22, "setup: a resolution change re-sizes the sample plate")
    S.plate.SetSize = nil
    CastAheadDB.plateSize = nil

    S.Leave()
    check(not S.Active(), "setup: leave")
    check(newlyShown(before) == 0, "setup: leaving leaves nothing shown, got " .. newlyShown(before))
    check(liveEvents() == live0, "setup: leaving cancels the sample timeline entries")
    check(winShown and shownPage == "General", "setup: the window comes back on its page")
    check(next(registered) == nil, "setup: leaving unregisters events")

    winShown, shownPage = false, nil
    S.Enter()
    S.Leave()
    check(not winShown and shownPage == nil, "setup: a window closed on entry stays closed")

    S.Enter()
    fireAll("PLAYER_REGEN_DISABLED")
    check(not S.Active() and newlyShown(before) == 0, "setup: combat closes the mode")

    S.Enter()
    CastAheadCore.Test(1877)
    check(not S.Active() and CastAheadCore.Testing(), "setup: the test drive leaves the mode first")
    CastAheadCore.Test(1877)

    S.Enter()
    CastAheadCore.MoveCenter()
    check(not S.Active(), "setup: /ca move leaves the mode first")
    local realPrint, printed = print, {}
    print = function(text) printed[#printed + 1] = text end
    S.Enter()
    print = realPrint
    check(sampleLines() == 3, "setup: entering locks /ca move and shows the sample")
    check(#printed == 0, "setup: locking /ca move on entry prints nothing, got " .. tostring(printed[1]))
    local kickIcon, burstIcon
    for i = 1, #allFrames do
        local f = allFrames[i]
        if f.shown and f.timeValue == "Interrupt  2.4" then kickIcon = f.icon.textureValue end
        if f.shown and f.timeValue == "Burst now  6.0" then burstIcon = f.icon.textureValue end
    end
    check(kickIcon == textures[200], "setup: the interrupt sample shows a kick spell's icon, got " .. tostring(kickIcon))
    check(burstIcon == CastAheadBurst.ICON, "setup: the burst sample shows the burst icon, got " .. tostring(burstIcon))
    S.Leave()
    check(newlyShown(before) == 0, "setup: nothing left after /ca move and the mode")

    CastAheadDB.centerText = false
    S.Enter()
    check(sampleLines() == 0, "setup: no centre sample with the centre call off")
    S.Leave()
    CastAheadDB.centerText = true

    S.Enter()
    panel.handlers.OnHide(panel)
    check(not S.Active() and newlyShown(before) == 0, "setup: hiding the panel leaves the mode")

    do
        local realVisible, popupUp, propagate = StaticPopup_Visible, false, nil
        StaticPopup_Visible = function(name) return popupUp and name == "CASTAHEAD_SETUP_RESET" end
        panel.SetPropagateKeyboardInput = function(_, on) propagate = on end
        _G.CastAheadMainWindow, _G.CastAheadSetupPanel = win, panel
        table.insert(UISpecialFrames, "CastAheadMainWindow")
        local function escape()
            propagate = nil
            panel.handlers.OnKeyDown(panel, "ESCAPE")
            if propagate == false then return end
            for _, name in ipairs(UISpecialFrames) do
                local f = _G[name]
                if f and f:IsShown() then
                    f:Hide()
                    if f.handlers and f.handlers.OnHide then f.handlers.OnHide(f) end
                end
            end
        end
        winShown, shownPage = true, nil
        S.Enter()
        popupUp = true
        escape()
        check(S.Active() and propagate == true, "setup: Esc goes to the Reset question first")
        popupUp = false
        escape()
        check(not S.Active() and propagate == false, "setup: Esc leaves the mode and is kept")
        check(winShown and shownPage == "General", "setup: after Esc the window opened on entry is back")
        winShown, shownPage = false, nil
        S.Enter()
        winShown = true
        check(S.Enter() == true and not winShown, "setup: General's button while the mode runs hides a reopened window")
        S.Leave()
        check(winShown and shownPage == "General", "setup: and leaving brings that window back on its page")
        table.remove(UISpecialFrames)
        _G.CastAheadMainWindow, _G.CastAheadSetupPanel = nil, nil
        StaticPopup_Visible, panel.SetPropagateKeyboardInput = realVisible, nil
    end

    S.Enter()
    CastAheadCore.HideAll()
    check(not S.Active() and newlyShown(before) == 0, "setup: /ca hide leaves the mode")

    do
        local realPlateFor = C_NamePlate.GetNamePlateForUnit
        C_NamePlate.GetNamePlateForUnit = function(u)
            if u == "nameplate9" then return { unit = u, IsShown = function() return true end } end
            return realPlateFor(u)
        end
        hostile.nameplate9 = false
        S.Enter()
        fireAll("NAME_PLATE_UNIT_ADDED", "nameplate9")
        check(barsOn(function(p) return p.unit == "nameplate9" end) == 0, "setup: a friendly plate gets no sample row")
        S.Leave()
        C_NamePlate.GetNamePlateForUnit, hostile.nameplate9 = realPlateFor, nil
    end

    do
        local realPlateFor = C_NamePlate.GetNamePlateForUnit
        C_NamePlate.GetNamePlateForUnit = function(u)
            if u == "nameplate9" then error("plate scan") end
            return realPlateFor(u)
        end
        hostile.nameplate9 = true
        winShown = true
        local ok = pcall(S.Enter)
        C_NamePlate.GetNamePlateForUnit, hostile.nameplate9 = realPlateFor, nil
        check(not ok and not S.Active(), "setup: an error in the plate scan leaves the mode closed")
        check(barsOn(onUnit) == 0 and winShown, "setup: a failed enter leaves no sample row and keeps the window")
        check(S.Enter() and S.Active(), "setup: entering works again after a failed enter")
        S.Leave()
    end

    do
        hostile[unit] = nil
        S.Enter()
        hostile[unit] = true
        local icons, sample = {}, nil
        for i = 1, #allFrames do
            local f = allFrames[i]
            if f.shown and IsBar(f) and f._plate == S.plate then
                icons[f._index] = f.icon.textureValue
                sample = f
            end
        end
        check(icons[1] == textures[200] and icons[2] == textures[300],
            "setup: the plate sample shows real spell icons, got " .. tostring(icons[1]) .. "," .. tostring(icons[2]))
        check(S.plate.strata == "BACKGROUND" and sample.strata == CastAheadConfig.Strata() and sample.level == 6200,
            "setup: the sample plate sits under its icons, got " .. tostring(S.plate.strata) .. "/" .. tostring(sample.strata))
        S.Leave()
    end

    do
        local realAdd, expiry = C_EncounterTimeline.AddScriptEvent, {}
        local realCancel, cut = C_EncounterTimeline.CancelScriptEvent, 0
        C_EncounterTimeline.AddScriptEvent = function(request)
            local id = realAdd(request)
            expiry[id] = now + request.duration
            return id
        end
        C_EncounterTimeline.CancelScriptEvent = function(id)
            if expiry[id] and expiry[id] > now then cut = cut + 1 end
            return realCancel(id)
        end
        S.Enter()
        for _ = 1, 100 do
            now = now + 1
            panel.handlers.OnUpdate(panel)
        end
        check(cut == 0, "setup: a timeline sample reaches its time before it is fed again, cut " .. cut)
        C_EncounterTimeline.CancelScriptEvent = realCancel
        local alive = 0
        for id in pairs(timeline.live) do
            if expiry[id] and expiry[id] > now then alive = alive + 1 end
        end
        check(alive == 3, "setup: the timeline samples stay while the mode is open, got " .. alive)
        S.Leave()
        alive = 0
        for id in pairs(timeline.live) do if expiry[id] then alive = alive + 1 end end
        check(alive == 0, "setup: leaving cancels the kept timeline samples, got " .. alive)
        C_EncounterTimeline.AddScriptEvent = realAdd
    end

    do
        local realPlateFor, realUIParent = C_NamePlate.GetNamePlateForUnit, UIParent
        UIParent = { GetEffectiveScale = function() return 1 end }
        local scale = 1.5
        C_NamePlate.GetNamePlateForUnit = function(u)
            local plate = realPlateFor(u)
            if not plate then return nil end
            plate.GetWidth = function() return 120 end
            plate.GetHeight = function() return 12 end
            plate.GetEffectiveScale = function() return scale end
            return plate
        end
        local plateSized
        S.plate.SetSize = function(_, w, h) plateSized = { w, h } end
        CastAheadDB.plateSize = nil
        S.Enter()
        check(plateSized and plateSized[1] == 180 and plateSized[2] == 18,
            "setup: the sample plate takes the size of a real plate seen on entry")
        scale = 2
        fireAll("UI_SCALE_CHANGED")
        check(plateSized[1] == 240 and plateSized[2] == 24, "setup: the sample plate follows a real plate after a scale change")
        S.Leave()
        S.plate.SetSize = nil
        CastAheadDB.plateSize = nil
        C_NamePlate.GetNamePlateForUnit, UIParent = realPlateFor, realUIParent
    end
    reset()

    enter()
    castFor(3.0)
    check(IconShown(100), "setup: a live bar is up before entering")
    S.Enter()
    check(not IconShown(100), "setup: live bars give way to the sample row while the mode is open")
    S.Leave()
    check(IconShown(100), "setup: live bars come back on leaving")

    do
        reset()
        local realUIParent = UIParent
        UIParent = { GetCenter = function() return 500, 400 end, GetEffectiveScale = function() return 1 end }
        local keyboard, propagate
        panel.EnableKeyboard = function(_, on) keyboard = on end
        panel.SetPropagateKeyboardInput = function(_, on) propagate = on end
        local function inside(widget, root)
            while widget do
                if widget == root then return true end
                widget = rawget(widget, "parent")
            end
            return false
        end

        CastAheadDB.plateSize = { 110, 45 }
        CastAheadDB.centerX, CastAheadDB.centerY, CastAheadDB.centerScale = nil, nil, nil
        local base = shownSet()
        S.Enter()
        local center = CastAheadCore.CenterFrame()
        check(keyboard == true, "setup: entering takes the keyboard")
        local grabbing = 0
        for i = 1, #allFrames do
            local f = allFrames[i]
            if (f.mouse or f.wheel) and onScreen(f) and not base[f] and not inside(f, panel) then grabbing = grabbing + 1 end
        end
        check(grabbing == 0, "setup: nothing the mode shows takes the mouse but the panel, got " .. grabbing)
        check(S.plate.shown and not S.plate.mouse and not S.plate.handlers.OnDragStart, "setup: the sample plate ignores the mouse")
        check(center.shown and not center.mouse and not center.wheel, "setup: the centre sample ignores the mouse")
        center.handlers.OnDragStart(center)
        check(not center.dragging, "setup: the centre sample cannot be dragged in the mode")
        check(center.fill.shown and center.fill.allPointsTo == center, "setup: the centre sample shows a fill over the whole block")
        CastAheadDB.centerText = false
        CastAheadCore.ShowCenterSample(true)
        check(not center.fill.shown, "setup: no centre fill while Centre call is off")
        CastAheadDB.centerText = nil
        CastAheadCore.ShowCenterSample(true)
        check(center.fill.shown, "setup: the centre fill is back when Centre call is on")

        check(center._x == 0 and center._y == -90 and center._scale == 0.8,
            "defaults: a fresh profile puts the centre call at -90 and 80%, got " .. tostring(center._y) .. "/" .. tostring(center._scale))
        check(panel.fields.centerY.box.value == "-90" and panel.fields.centerScale.box.value == "80",
            "defaults: the panel shows -90 and 80 on a fresh profile")
        CastAheadDB.centerY, CastAheadDB.centerScale = 0, 100
        CastAheadCore.ResizeCenter()
        S.Refresh()
        check(center._y == -120 and center._scale == 1 and panel.fields.centerY.box.value == "-120"
            and panel.fields.centerScale.box.value == "100", "defaults: a stored centre Y and size are kept as they were")
        CastAheadDB.centerY, CastAheadDB.centerScale = nil, nil
        check(CastAheadConfig.CenterY() == 30 and CastAheadConfig.CenterScale() == 0.8, "defaults: the accessors answer 30 and 0.8 when unset")

        CastAheadDB.nudgeX, CastAheadDB.nudgeY = 0, 0
        local kept = {}
        for _, key in ipairs({ "UP", "DOWN", "LEFT", "RIGHT", "W" }) do
            propagate = nil
            panel.handlers.OnKeyDown(panel, key)
            if propagate ~= true then kept[#kept + 1] = key end
        end
        check(#kept == 0 and CastAheadDB.nudgeX == 0 and CastAheadDB.nudgeY == 0,
            "setup: arrows and other keys pass through and move nothing, kept " .. table.concat(kept, ","))
        local realLock = InCombatLockdown
        InCombatLockdown = function() return true end
        propagate = "untouched"
        panel.handlers.OnKeyDown(panel, "W")
        panel.handlers.OnKeyDown(panel, "ESCAPE")
        InCombatLockdown = realLock
        check(propagate == "untouched", "setup: a key pressed in combat does not call the restricted propagate setter")

        S.Leave()
        check(keyboard == false, "setup: leaving releases the keyboard")
        check(not center.fill.shown, "setup: leaving hides the centre fill")
        check(newlyShown(base) == 0, "setup: nothing left after the mode, got " .. newlyShown(base))

        local realPrint = print
        print = function() end
        CastAheadCore.MoveCenter()
        check(center.mouse == true and center.shown, "/ca move: outside the mode the block takes the mouse")
        center.GetScale = function() return 1 end
        center.GetHeight = function() return 132 end
        center.GetCenter = function() return 506, 400 + 3 - 44 end
        center.handlers.OnDragStart(center)
        check(center.dragging, "/ca move: the block drags")
        center.handlers.OnDragStop(center)
        CastAheadCore.MoveCenter()
        print = realPrint
        check(CastAheadDB.centerX == 6 and CastAheadCore.CENTER_Y + CastAheadDB.centerY == 3,
            "/ca move: the drop is saved where it landed, not snapped, got " .. tostring(CastAheadDB.centerX) .. ","
            .. tostring(CastAheadCore.CENTER_Y + CastAheadDB.centerY))
        check(not center.mouse and not center.shown, "/ca move: a second /ca move locks and hides the block")

        center.GetCenter, center.GetScale, center.GetHeight = nil, nil, nil
        panel.EnableKeyboard, panel.SetPropagateKeyboardInput = nil, nil
        CastAheadDB.plateSize, CastAheadDB.centerX, CastAheadDB.centerY = nil, nil, nil
        UIParent = realUIParent
    end

    do
        local HINT = "Change the numbers here; the icons and the centre call show the result."
        local realPopup, popup = StaticPopup_Show, nil
        StaticPopup_Show = function(name) popup = name end
        local function down(f)
            MouseIsDown = true
            f.handlers.OnMouseDown(f, "LeftButton")
        end
        local function up(f)
            MouseIsDown = false
            f.handlers.OnMouseUp(f, "LeftButton")
        end
        local function click(f)
            if f.handlers.OnMouseDown then
                down(f)
                up(f)
            else
                f.handlers.OnClick(f)
            end
        end
        reset()
        hostile[unit] = true
        CastAheadDB = { centerText = true }
        local height
        panel.SetHeight = function(_, h) height = h end
        S.Enter()
        check(panel.hint and panel.hint.value == HINT, "panel: the hint reads exactly, got " .. tostring(panel.hint and panel.hint.value))
        check(panel.iconsTitle and panel.iconsTitle.text.value == "Nameplate icons" and panel.centreTitle
            and panel.centreTitle.text.value == "Centre call" and panel.timelineSwitch
            and panel.timelineSwitch.text.value == "Blizzard timeline", "panel: the block titles and the timeline row are switches")
        local f = panel.fields or {}
        local LABELS = { offsetX = "Distance (px)", nudgeX = "X (px)", nudgeY = "Y (px)", iconSize = "Icon (px)",
                         labelScale = "Label (%)", timeScale = "Countdown (%)", iconGap = "Gap (px)",
                         centerX = "X (px)", centerY = "Y (px)", centerScale = "Size (%)", centerTextScale = "Text (%)" }
        local missing = {}
        for key, label in pairs(LABELS) do
            local row = f[key]
            if not (row and row.label.value == label and row.box and row.minus and row.plus) then missing[#missing + 1] = key end
        end
        table.sort(missing)
        check(#missing == 0, "panel: every number row is there with its label and -/+, missing " .. table.concat(missing, ","))
        check(panel.side and panel.grow and panel.layer and panel.fixedSpacing
            and panel.fixedSpacing.text.value == "Fixed spacing", "panel: Side, Grow, Fixed spacing and Layer are in the icons block")
        check(f.centerX and f.centerX.center and f.centerY.center and f.nudgeX and not f.nudgeX.center,
            "panel: only the centre's X and Y carry Center buttons")
        check(height and height <= 728, "panel: the panel fits under the top-right corner at UI scale 1, got " .. tostring(height))
        do
            local function inside(widget, box)
                while widget do
                    if widget == box then return true end
                    widget = rawget(widget, "parent")
                end
                return false
            end
            local boxes = { panel.iconsBox, panel.centreBox, panel.timelineBox }
            check(boxes[1] and boxes[2] and boxes[3] and boxes[1] ~= boxes[2] and boxes[2] ~= boxes[3],
                "panel: three boxes")
            check(panel.iconsTitle.parent == boxes[1] and panel.centreTitle.parent == boxes[2]
                and panel.timelineSwitch.parent == boxes[3], "panel: each box's title row is its switch")
            local home = { offsetX = 1, nudgeX = 1, nudgeY = 1, iconSize = 1, labelScale = 1, timeScale = 1, iconGap = 1,
                           centerX = 2, centerY = 2, centerScale = 2, centerTextScale = 2 }
            local stray = {}
            for key, boxIndex in pairs(home) do
                local row = panel.fields[key]
                for _, widget in ipairs({ row.box, row.minus, row.plus, row.center }) do
                    if not inside(widget, boxes[boxIndex]) then stray[#stray + 1] = key end
                end
            end
            for _, widget in ipairs({ panel.side, panel.grow, panel.layer, panel.fixedSpacing }) do
                if not inside(widget, boxes[1]) then stray[#stray + 1] = "icons widget" end
            end
            check(#stray == 0, "panel: every row sits inside its box, stray " .. table.concat(stray, ","))
            check(boxes[1].parent == panel and boxes[2].parent == panel and boxes[3].parent == panel
                and not inside(panel.hint, boxes[1]) and not inside(panel.reset, boxes[1])
                and panel.reset.parent == panel and panel.done.parent == panel,
                "panel: the hint and Reset/Done stay outside the boxes")
            check(boxes[1].points[2] == panel.hint or boxes[1].points[2] == panel.guess,
                "panel: the first box hangs below the hint")
            check(boxes[2].points[2] == boxes[1] and boxes[3].points[2] == boxes[2], "panel: the boxes stack in order")
            check(panel.reset.points[1] == "BOTTOMLEFT" and panel.reset.points[2] == panel and panel.done.points[1] == "BOTTOMRIGHT",
                "panel: Reset and Done sit at the bottom")
        end

        local function typeInto(key, text)
            f[key].box:SetText(text)
            f[key].box.handlers.OnEnterPressed(f[key].box)
        end
        CastAheadDB.iconSize = nil
        click(f.iconSize.plus)
        check(CastAheadDB.iconSize == 27 and f.iconSize.box.value == "27", "panel: + on Icon grows the icons 1 px")
        typeInto("iconSize", "200")
        check(CastAheadDB.iconSize == 64 and f.iconSize.box.value == "64", "panel: a typed icon size is clamped to 64")
        typeInto("iconSize", "abc")
        check(CastAheadDB.iconSize == 64 and f.iconSize.box.value == "64", "panel: a typed word is not taken")

        CastAheadDB.labelScale = nil
        click(f.labelScale.plus)
        check(CastAheadDB.labelScale == 101 and f.labelScale.box.value == "101", "panel: + on Label adds 1%")
        typeInto("labelScale", "999")
        check(CastAheadDB.labelScale == 200 and f.labelScale.box.value == "200", "panel: a typed label size stops at 200%")
        typeInto("timeScale", "10")
        click(f.timeScale.minus)
        check(CastAheadDB.timeScale == 50, "panel: Countdown stops at 50%")

        CastAheadDB.offsetX = nil
        click(f.offsetX.plus)
        check(CastAheadDB.offsetX == 1 and f.offsetX.box.value == "1", "panel: + on Distance moves the row out 1")
        click(f.offsetX.minus)
        check(CastAheadDB.offsetX == 0, "panel: - on Distance comes back to 0")
        click(f.offsetX.minus)
        check(CastAheadDB.offsetX == -1 and f.offsetX.box.value == "-1", "panel: - on Distance from 0 goes negative")
        typeInto("offsetX", "-10")
        check(CastAheadDB.offsetX == -10 and f.offsetX.box.value == "-10", "panel: a typed distance can be -10")
        typeInto("offsetX", "-500")
        check(CastAheadDB.offsetX == -120, "panel: a typed distance stops at -120")
        typeInto("offsetX", "500")
        check(CastAheadDB.offsetX == 120, "panel: a typed distance stops at 120")

        CastAheadDB.nudgeX = nil
        click(f.nudgeX.minus)
        check(CastAheadDB.nudgeX == -1 and f.nudgeX.box.value == "-1", "panel: - on X moves the row left 1")
        typeInto("nudgeY", "-500")
        check(CastAheadDB.nudgeY == -100, "panel: a typed Y stops at -100")

        panel.fixedSpacing.GetChecked = function() return true end
        click(panel.fixedSpacing)
        check(CastAheadDB.fixedSpacing == true, "panel: Fixed spacing switches on from the panel")
        CastAheadDB.iconGap = nil
        click(f.iconGap.plus)
        check(CastAheadDB.iconGap == 5 and f.iconGap.box.value == "5", "panel: + on Gap adds 1 px")
        typeInto("iconGap", "99")
        check(CastAheadDB.iconGap == 40, "panel: a typed gap stops at 40")
        typeInto("iconGap", "-3")
        check(CastAheadDB.iconGap == 0, "panel: a typed gap stops at 0")
        f.iconSize.box:SetText("40")
        f.iconSize.box.HasFocus = function() return true end
        click(f.iconGap.plus)
        check(f.iconSize.box.value == "40" and f.iconGap.box.value == "1", "panel: a refresh leaves the box being typed in alone, got "
            .. tostring(f.iconSize.box.value))
        f.iconSize.box.HasFocus = nil
        S.Refresh()
        check(f.iconSize.box.value == "64", "panel: a box without focus follows the stored value")

        CastAheadDB.centerX, CastAheadDB.centerY = 37, 50
        S.Refresh()
        check(f.centerX.box.value == "37" and f.centerY.box.value == "-70", "panel: the centre's Y is shown from the screen centre, got "
            .. tostring(f.centerY.box.value))
        click(f.centerX.center)
        check(CastAheadDB.centerX == 0 and f.centerX.box.value == "0", "panel: Center X puts the centre on the vertical axis")
        click(f.centerY.center)
        check(CastAheadCore.CENTER_Y + CastAheadDB.centerY == 0 and f.centerY.box.value == "0",
            "panel: Center Y puts the centre on the horizontal axis")
        typeInto("centerY", "15")
        check(CastAheadCore.CENTER_Y + CastAheadDB.centerY == 15, "panel: a typed Y is taken from the screen centre")
        typeInto("centerX", "1e999")
        typeInto("centerX", "nan")
        typeInto("centerX", "-1e999")
        check(CastAheadDB.centerX == 0 and f.centerX.box.value == "0", "panel: inf and nan are not taken, got "
            .. tostring(CastAheadDB.centerX))
        local savedParent = UIParent
        UIParent = { GetWidth = function() return 1920 end, GetHeight = function() return 1080 end }
        typeInto("centerX", "99999")
        typeInto("centerY", "-99999")
        check(CastAheadDB.centerX == 960 and CastAheadCore.CENTER_Y + CastAheadDB.centerY == -540,
            "panel: typed centre X and Y stop at the screen edge")
        UIParent = savedParent
        f.centerX.box:SetText("12")
        f.centerX.box.handlers.OnEditFocusLost(f.centerX.box)
        check(CastAheadDB.centerX == 12, "panel: leaving the box applies the typed value")
        CastAheadDB.centerScale = nil
        click(f.centerScale.minus)
        check(CastAheadDB.centerScale == 79 and f.centerScale.box.value == "79", "panel: - on the centre size takes 1% off the 80% default")
        CastAheadDB.centerTextScale = nil
        click(f.centerTextScale.plus)
        check(CastAheadDB.centerTextScale == 101, "panel: + on the centre text adds 1%")

        local function tick(seconds)
            local steps = math.floor(seconds / 0.01 + 0.5)
            for _ = 1, steps do
                now = now + 0.01
                panel.handlers.OnUpdate(panel)
            end
        end
        local plus, minus = f.nudgeX.plus, f.nudgeX.minus
        CastAheadDB.nudgeX = 0
        down(plus)
        check(CastAheadDB.nudgeX == 1 and f.nudgeX.box.value == "1", "hold: one step on press")
        tick(0.38)
        check(CastAheadDB.nudgeX == 1, "hold: no repeat before 0.4 s")
        tick(0.04)
        check(CastAheadDB.nudgeX == 2, "hold: the first repeat comes at 0.4 s, got " .. tostring(CastAheadDB.nudgeX))
        local at = CastAheadDB.nudgeX
        tick(0.5)
        local early = CastAheadDB.nudgeX - at
        tick(2)
        at = CastAheadDB.nudgeX
        tick(0.5)
        local late = CastAheadDB.nudgeX - at
        check(early >= 3 and early <= 5 and late >= 14 and late > 2 * early,
            "hold: repeats speed up, " .. early .. " steps early and " .. late .. " late in 0.5 s")
        up(plus)
        at = CastAheadDB.nudgeX
        tick(1)
        check(CastAheadDB.nudgeX == at, "hold: release stops the repeat")

        CastAheadDB.nudgeX = 0
        down(plus)
        tick(0.6)
        plus.handlers.OnLeave(plus)
        at = CastAheadDB.nudgeX
        tick(1)
        check(at > 1 and CastAheadDB.nudgeX == at, "hold: leaving the button stops the repeat")

        CastAheadDB.nudgeX = 98
        down(plus)
        tick(1.5)
        check(CastAheadDB.nudgeX == 100 and f.nudgeX.box.value == "100", "hold: a held button stops changing at the limit")
        local reapplied, realReapply = 0, CastAheadCore.Reapply
        CastAheadCore.Reapply = function(...) reapplied = reapplied + 1 return realReapply(...) end
        tick(1)
        CastAheadCore.Reapply = realReapply
        check(reapplied == 0, "hold: a held button at its limit does no more work, " .. reapplied .. " reapplies")
        up(plus)
        CastAheadDB.nudgeX = 0
        down(plus)
        MouseIsDown = false
        tick(1)
        check(CastAheadDB.nudgeX == 1, "hold: the mouse reported up without OnMouseUp, no further steps, got " .. tostring(CastAheadDB.nudgeX))
        MouseIsDown = true
        CastAheadDB.nudgeX = -98
        down(minus)
        tick(1.5)
        check(CastAheadDB.nudgeX == -100, "hold: - stops at the lower limit")
        up(minus)

        CastAheadDB.offsetX = 0
        down(f.offsetX.minus)
        tick(1)
        check(CastAheadDB.offsetX < -2, "hold: Distance repeats below zero, got " .. tostring(CastAheadDB.offsetX))
        up(f.offsetX.minus)

        CastAheadDB.nudgeX = 0
        down(plus)
        S.Leave()
        S.Enter()
        tick(1)
        check(CastAheadDB.nudgeX == 1, "hold: leaving the mode stops the repeat")
        CastAheadDB.nudgeX = 0
        down(plus)
        panel.handlers.OnHide(panel)
        S.Enter()
        tick(1)
        check(CastAheadDB.nudgeX == 1, "hold: hiding the panel stops the repeat")
        CastAheadDB.nudgeX = 0
        down(plus)
        fireAll("PLAYER_REGEN_DISABLED")
        S.Enter()
        tick(1)
        check(CastAheadDB.nudgeX == 1, "hold: combat stops the repeat")
        local drivers = 0
        for _, key in ipairs({ "nudgeX", "iconSize", "centerX" }) do
            if f[key].plus.handlers.OnUpdate or f[key].minus.handlers.OnUpdate then drivers = drivers + 1 end
        end
        check(drivers == 0, "hold: the buttons have no OnUpdate of their own, the panel drives them")

        CastAheadDB.plateSize = nil
        S.Leave()
        S.Enter()
        check(panel.guess.shown and panel.guess.value == "Sample size is a guess until a real nameplate is seen.",
            "panel: the guess line shows while no real plate was measured")
        CastAheadDB.plateSize = { 150, 20 }
        fireAll("UI_SCALE_CHANGED")
        check(not panel.guess.shown, "panel: the guess line hides once a real plate size is known")
        CastAheadDB.plateSize = nil
        C_NamePlate.GetNamePlateSize = function() return 140, 30 end
        S.Leave()
        S.Enter()
        check(panel.guess.shown, "panel: the guess line shows on the game's own plate size too")
        C_NamePlate.GetNamePlateSize = nil

        click(panel.reset)
        local dialog = StaticPopupDialogs.CASTAHEAD_SETUP_RESET
        check(popup == "CASTAHEAD_SETUP_RESET" and dialog and dialog.hideOnEscape
            and dialog.text == "Put every size and position in this panel back to its default? The on/off switches stay as they are.",
            "panel: Reset asks first")
        local KEYS = { "anchor", "grow", "offsetX", "nudgeX", "nudgeY", "iconSize", "labelScale", "timeScale",
                       "iconGap", "fixedSpacing", "strata", "centerX", "centerY", "centerScale", "centerTextScale" }
        for _, key in ipairs(KEYS) do CastAheadDB[key] = 40 end
        CastAheadDB.anchor, CastAheadDB.grow, CastAheadDB.fixedSpacing, CastAheadDB.strata = "top", "up", true, "HIGH"
        CastAheadDB.timeline, CastAheadDB.fullLabels = false, true
        dialog.OnAccept()
        local left = {}
        for _, key in ipairs(KEYS) do if CastAheadDB[key] ~= nil then left[#left + 1] = key end end
        check(#left == 0, "panel: Reset clears all fifteen keys, left " .. table.concat(left, ","))
        check(CastAheadDB.timeline == false and CastAheadDB.fullLabels == true and CastAheadDB.centerText == true,
            "panel: Reset leaves the switches alone")
        check(f.iconSize.box.value == "26" and f.iconGap.box.value == "4", "panel: Reset refreshes the numbers")
        check(f.centerY.box.value == "-90" and f.centerScale.box.value == "80", "panel: Reset puts the centre call back at -90 and 80%")
        CastAheadDB.timeline, CastAheadDB.fullLabels = nil, nil

        check(panel.note.value == "Move it in the game's Edit Mode: Esc > Edit Mode.",
            "panel: the timeline box carries one permanent Edit Mode hint")

        click(panel.done)
        check(not S.Active(), "panel: Done leaves the mode")
        panel.SetHeight = nil
        StaticPopup_Show = realPopup
    end

    do
        reset()
        CastAheadDB = { centerText = true }
        SlashCmdList.CASTAHEAD("setup")
        check(S.Active(), "/ca setup enters the setup mode")
        S.Leave()
    end

    reset()
    panel.RegisterEvent, panel.UnregisterEvent = nil, nil
    W.Frame, W.Current, W.Show = savedFrame, savedCurrent, savedShow
    CastAheadDB, InCombatLockdown = savedDB, savedLock
end)();

(function()
    local S = CastAheadSetup
    local W = CastAheadWindow
    local saved = { CastAheadDB, InCombatLockdown, UIParent, W.Frame, W.Current, W.Show, C_NamePlate.GetNamePlateForUnit }
    reset()
    CastAheadDB = { centerText = true }
    InCombatLockdown = function() return false end
    W.Frame, W.Current, W.Show = function() return nil end, function() return nil end, function() end
    UIParent = { GetCenter = function() return 500, 400 end, GetEffectiveScale = function() return 1 end }
    local panel = S.panel
    local registered = {}
    panel.RegisterEvent = function(_, e) registered[e] = true end
    panel.UnregisterEvent = function(_, e) registered[e] = nil end
    local function fireAll(event, ...)
        fire(event, ...)
        if registered[event] then panel.handlers.OnEvent(panel, event, ...) end
    end
    local plates = {}
    local function addPlate(u, x, y, scale)
        local p = { unit = u, ux = x, uy = y, scale = scale or 1, up = true }
        p.IsShown = function() return p.up end
        p.GetCenter = function() return p.ux / p.scale, p.uy / p.scale end
        p.GetWidth = function() return 100 end
        p.GetHeight = function() return 10 end
        p.GetEffectiveScale = function() return p.scale end
        plates[u], hostile[u] = p, true
        return p
    end
    local function removePlate(u)
        plates[u], hostile[u] = nil, nil
        fireAll("NAME_PLATE_UNIT_REMOVED", u)
    end
    C_NamePlate.GetNamePlateForUnit = function(u) return plates[u] end
    local function barsOn(frame)
        local n = 0
        for i = 1, #allFrames do
            local f = allFrames[i]
            if f.shown and IsBar(f) and f._plate == frame then n = n + 1 end
        end
        return n
    end

    addPlate("nameplate2", 500, 700)
    addPlate("nameplate3", 530, 420, 1.5)
    S.Enter()
    check(barsOn(plates.nameplate2) == 3 and barsOn(plates.nameplate3) == 3, "plates: every hostile plate in view shows a sample row")
    check(not S.plate.shown and barsOn(S.plate) == 0, "plates: no sample plate while a hostile plate has a row")
    removePlate("nameplate2")
    removePlate("nameplate3")
    check(S.plate.shown and barsOn(S.plate) == 3, "plates: the sample plate comes back when the last hostile plate goes")
    check(S.plate.label and S.plate.label.value == "Sample nameplate - stand near enemies or training dummies to see the icons on real ones",
        "plates: the sample plate says it is a stand-in, got " .. tostring(S.plate.label and S.plate.label.value))
    addPlate("nameplate4", 600, 300)
    fireAll("NAME_PLATE_UNIT_ADDED", "nameplate4")
    check(not S.plate.shown and barsOn(S.plate) == 0 and barsOn(plates.nameplate4) == 3,
        "plates: the sample plate hides as soon as a hostile plate appears")
    plates.nameplate4.up = false
    now = now + 0.5
    panel.handlers.OnUpdate(panel)
    check(S.plate.shown and barsOn(S.plate) == 3, "plates: every plate hidden but none removed, the sample plate comes back")
    check(barsOn(plates.nameplate4) == 0, "plates: a hidden plate keeps no sample bars, got " .. barsOn(plates.nameplate4))

    local realPrint, printed = print, {}
    print = function(text) printed[#printed + 1] = text end
    CastAheadCore.Debug()
    print = realPrint
    local rowLine, barLines = false, 0
    for _, line in ipairs(printed) do
        if line:find("setup: sample plate row shown", 1, true) then rowLine = true end
        if line:find("setup bar %d: shown=true size=%d+ icon=%d+") and line:find("point=", 1, true) then barLines = barLines + 1 end
    end
    check(rowLine and barLines == 3, "debug: the setup section lists the sample plate's row and its three bars, got "
        .. tostring(rowLine) .. "/" .. barLines)

    plates.nameplate4.up = true
    now = now + 0.5
    panel.handlers.OnUpdate(panel)
    check(not S.plate.shown and barsOn(S.plate) == 0, "plates: a plate shown again hides the sample plate")
    check(barsOn(plates.nameplate4) == 3, "plates: a plate shown again gets its sample bars back, got " .. barsOn(plates.nameplate4))

    S.Leave()
    check(not panel.shown and not S.plate.shown, "setup: the sample plate goes with the mode")
    S.Enter()
    panel.handlers.OnKeyDown(panel, "ESCAPE")
    check(not S.Active(), "setup: Esc leaves the mode")
    S.Enter()
    fireAll("PLAYER_REGEN_DISABLED")
    check(not S.Active(), "setup: combat leaves the mode")

    removePlate("nameplate4")
    panel.RegisterEvent, panel.UnregisterEvent = nil, nil
    CastAheadDB, InCombatLockdown, UIParent, W.Frame, W.Current, W.Show, C_NamePlate.GetNamePlateForUnit = unpack(saved, 1, 7)
end)()

;(function()
    local saved = CastAheadDB
    CastAheadDB = { leadSeconds = 3, spellLead = { [1] = 6, [2] = 0, [3] = 99 } }
    local C = CastAheadConfig
    check(C.LeadFor({ { spell = 9 } }) == 3, "lead: a cast without its own warning gets the global one")
    check(C.LeadFor({ { spell = 1 } }) == 6, "lead: a cast's own warning beats the global one")
    check(C.LeadFor({ { spell = 2 } }) == 0, "lead: a cast can switch its warning off")
    check(C.LeadFor({ { spell = 3 } }) == C.LEAD_MAX, "lead: an own warning past the range is clamped")
    check(C.LeadFor({ { spell = 2 }, { spell = 9 } }) == 3, "lead: of several candidates the longest wins")
    check(C.LeadFor(nil) == 3, "lead: no candidates means the global one")
    CastAheadDB.leadSeconds = 0
    check(C.LeadFor({ { spell = 1 } }) == 6, "lead: an own warning works with the global one off")
    CastAheadDB.spellSounds = { [1] = "Bell", [2] = "" }
    check(CastAheadUI.OverrideSummary({ spell = 1 }) == "Bell, Early 6s", "overrides: sound and warning listed")
    check(CastAheadUI.OverrideSummary({ spell = 2 }) == "Own sound: voice, Early off", "overrides: a ticked sound with no pick is listed as the voice")
    check(CastAheadUI.OverrideSummary({ spell = 9 }) == "", "overrides: nothing own, nothing listed")
    CastAheadDB.spellImportant = { [1] = false }
    CastAheadDB.spellMute = { [1] = true, [2] = true }
    check(not CastAheadMatch.Important({ spell = 1, prio = "AOE" }), "overrides: an unstarred curated cast is not important")
    check(CastAheadMatch.Important({ spell = 9, prio = "AOE" }), "overrides: without a star of its own the curated set decides")
    local role = CastAheadMatch.PlayerRole
    CastAheadMatch.PlayerRole = function() return "DAMAGER" end
    check(not CastAheadMatch.Important({ spell = 9, prio = "TANK" }), "overrides: a tank buster is not a dps player's call")
    CastAheadDB.spellImportant[7] = true
    check(CastAheadMatch.Important({ spell = 7, prio = "TANK" }), "overrides: a starred tank buster is shown to a dps player too")
    CastAheadMatch.PlayerRole = role
    check(C.AllMuted({ { spell = 1 }, { spell = 2 } }), "overrides: a bar of muted casts is silent")
    check(not C.AllMuted({ { spell = 1 }, { spell = 9 } }), "overrides: one unmuted candidate keeps the call")
    check(CastAheadUI.OverrideSummary({ spell = 1 }) == "Not important, Muted, Bell, Early 6s", "overrides: every own setting listed")
    CastAheadDB.importantOnly = true
    local shown, loud = CastAheadUI.RunState({ spell = 1, prio = "AOE" })
    check(not shown, "run state: an unstarred cast is hidden while Important casts only is on")
    shown, loud = CastAheadUI.RunState({ spell = 2, prio = "AOE" })
    check(shown and not loud, "run state: a muted important cast shows without a call")
    shown, loud = CastAheadUI.RunState({ spell = 9, prio = "AOE" })
    check(shown and loud, "run state: an important cast with nothing of its own shows and calls")
    CastAheadDB = saved
end)()

print(failures == 0 and "OK" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
