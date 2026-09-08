-- CastAhead: predicts when a trash mob will cast next, and names the cast.
--
-- In 12.1 enemy identity and cast info are Secret: no GUID, no unit name, no
-- spell id, no cast duration from the API. What is left is the bare
-- UNIT_SPELLCAST_* events on a nameplate unit, UnitAffectingCombat, and
-- GetTime(). So a cast is identified by how long it took, matched against a
-- table harvested from combat logs (Data.lua), and the schedule runs on dead
-- reckoning from there.
--
-- Identification narrows in three steps:
--   engage:   time from entering combat to the first cast (row.first)
--   1st cast: candidates = spells in this dungeon with a matching cast time
--   2nd cast: the measured interval picks one of them, and pins the rotation
-- A measured interval always beats the table - the mob is the authority on its
-- own cooldown.
--
-- Each cast length gets its own schedule. A mob with two abilities alternates
-- between them, so a single per-nameplate timer would measure the gap between
-- *different* spells and predict nonsense.

-- Updating the addon in place and typing /reload does not re-scan the TOC, so
-- a client that started before Config.lua joined the file list loads this file
-- but not that one. The fallback keeps the addon alive until the next full
-- restart, behaving as it did before the settings file existed.
CastAheadConfig = CastAheadConfig or { LEAD_DEFAULT = 0, LEAD_MAX = 15,
    Get = function() end, Set = function() end, SetEnabled = function() end,
    Enabled = function() return true end, Lead = function() return 0 end, Migrate = function() end }

local ICON_SIZE = 26
local BAR_GAP = 6        -- distance from the plate's left edge
local LABEL_HEIGHT = 11  -- one line of advice under the icon; two are measured
local BAR_SPACING = 5    -- gap between one row's label and the next icon
local H_STEP = 68        -- fallback sideways step, before any label is measured
local LABEL_GAP = 8      -- clear space between one icon's label and the next
local ICON_GAP = 4       -- ... and the floor, when both labels are short
local DEMO_PER_PLATE = 3 -- calls the test drive puts on each nameplate
local DEMO_PLATES = 4    -- ... and how many nameplates it uses at all
local COMBAT_POLL_BATCH = 8      -- nameplates re-checked per tick
local PREDICTION_MATCH_WINDOW = 4.0  -- how far off a predicted cast may start
local ESTIMATE_NOW = 2.0             -- an estimate this close just reads as "now"
local STALE_PREDICTION = 60.0        -- an overdue cast this old is abandoned
local THIN_EVIDENCE = 5              -- rows backed by less are always estimates

-- Only a prediction this solid is worth putting on Blizzard's timeline: one
-- candidate, a real measured schedule, enough observations, and not projected
-- from another spell's opening order. Everything softer stays on the nameplate,
-- where an estimate can be shown as one.
local function IsConfident(track)
    if not track or track.projected or track.ambiguous then return false end
    local row = track.candidates and #track.candidates == 1 and track.candidates[1]
    return row and CastAheadMatch.HasSchedule(row) and (row.n or 0) >= THIN_EVIDENCE
        and not row.approx and row or false
end
local COMBAT_POLL_INTERVAL = 0.1
local MAX_NAMEPLATES = 40

-- Declared up front because the bar code above needs them: Lua resolves an
-- undeclared local as a global, which is nil at call time.
local RefreshBar
local GetTrack
local recentCasts
local StartPreview
local RefineByNPC
local ResolvedNPCs, LockedNPCs
local Probe                 -- /ca probe, defined next to Debug; the event handler calls it
local Identify
local LockNPC
local diag = { plates = 0, casts = 0, identified = 0, shown = 0, published = 0 }
local plates = {}                -- unit -> state
local dungeon = nil              -- rows for the current instance
local traitRows = nil            -- creature identity traits for the current instance
local pollIndex = 1
local pollAt = 0
local frame = CreateFrame("Frame")

-- Data --------------------------------------------------------------------

local byNPC = {}

-- Folds the curated priority set into the data once: every row learns its
-- category, and prioritised casts our logs have not captured yet are
-- appended with provisional timings. Runs over all dungeons, not just the
-- current one, because the /castahead window browses any of them.
local extrasMerged = false
local function MergeCuration()
    if extrasMerged or not CastAheadData then return end
    extrasMerged = true
    for instanceID, rows in pairs(CastAheadData) do
        local extras = CastAheadExtra and CastAheadExtra[instanceID]
        if extras then
            for e = 1, #extras do
                local extra = extras[e]
                local present = false
                for i = 1, #rows do
                    if rows[i].spell == extra.spell and rows[i].npc == extra.npc then
                        present = true
                        break
                    end
                end
                if not present then table.insert(rows, extra) end
            end
        end
        local learned = CastAheadDB and CastAheadDB.dispel
        for i = 1, #rows do
            rows[i].prio = CastAheadPriority and CastAheadPriority[rows[i].spell] or nil
            rows[i].dispel = learned and learned[rows[i].spell] or nil
        end
    end
end

-- Matcher switches the replay harness can flip to measure a rule against real
-- fights. Defaults are the shipped behaviour, each settled by that harness:
--  - traitsNarrow on: switching it off cost 4-5 points of correct calls on
--    both our own and public logs and removed no wrong ones;
--  - trustUnsureTrack off: a single candidate that was never confirmed used
--    to be inherited by every later cast of the same length on that plate,
--    so one guess became a run of wrong calls ("never: track" was the single
--    largest source of them). Re-identifying each cast cut wrong calls by a
--    quarter for two points of correct ones, which the wider opening
--    tolerance in Match.lua then won back.
local tuning = {
    traitsNarrow = true,       -- let the trait-derived creature set pick among candidates
    trustUnsureTrack = false,  -- a single unconfirmed candidate is re-identified, not inherited
    --  - population off: MDT counts the creatures it places, not the ones a
    --    dungeon spawns (Kings' Rest lists two Interment Constructs and the
    --    waves bring more), so "every one is dead" came true early and the
    --    real creature was excluded - 20 wrong Entomb calls in our own runs,
    --    and fewer right calls on both sources. Stays off until a spawn
    --    table exists; the counting itself is sound and stays in.
    --  - packsNarrow / packsCompany off: preferring a locked neighbour's
    --    packmates buys about one wrong call per extra right one (own logs
    --    +34 right / +24 wrong, public +44 / +45), and turns cross-creature
    --    ties into same-creature ties, which nothing here can settle. A
    --    wrong call costs more than silence, so neither is on by default.
    population = false,        -- a creature seen dying as many times as MDT places it is out
    packsNarrow = false,       -- a locked neighbour's packmates are preferred among cast candidates
    packsCompany = false,      -- ... and among trait matches, instead of the trait rows' own `co`
}

-- Population: how many of each creature MDT places in this dungeon (Packs.lua,
-- keyed by the dungeon's English name), how many of each we have watched die,
-- and which kinds are therefore gone. A key restarts the count; a /reload does
-- not, so the count only ever lags behind the truth, never runs ahead of it.
local packs                 -- { total = { [npc] = n }, packs = { { [npc] = n }, ... } }
local killed = {}
local exhausted = {}
local countedInstance

local function ResetPopulation()
    wipe(killed)
    wipe(exhausted)
end

-- MDT and our table spell a name apart ("King's Rest" against "Kings' Rest"),
-- so the lookup ignores everything but letters and digits.
local function PacksFor(name)
    if not (name and CastAheadPacks) then return nil end
    local want = name:lower():gsub("[^%w]", "")
    for key, data in pairs(CastAheadPacks) do
        if key:lower():gsub("[^%w]", "") == want then return data end
    end
    return nil
end

local function LoadDungeon()
    MergeCuration()
    local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    dungeon = IsInInstance() and instanceID and CastAheadData and CastAheadData[instanceID] or nil
    traitRows = dungeon and CastAheadTraits and CastAheadTraits[instanceID] or nil
    packs = dungeon and PacksFor(dungeon.name) or nil
    if instanceID ~= countedInstance then
        ResetPopulation()
        countedInstance = instanceID
    end
    wipe(byNPC)
    if dungeon then
        for i = 1, #dungeon do
            local row = dungeon[i]
            -- Tolerate a gap rather than erroring out on the whole dungeon.
            if row and row.npc then
                byNPC[row.npc] = byNPC[row.npc] or {}
                table.insert(byNPC[row.npc], row)
            end
        end
    end
    return dungeon ~= nil
end

-- UnitLevel carries no Secret marker in the docs, but a hostile unit can still
-- hand back something unusable (a secret value, or -1 for a skull-level mob),
-- and comparing a secret throws - which would kill the handler that tracks the
-- plate at all. Anything not a plain positive number is treated as "unknown".
local function SafeLevel(unit)
    if type(UnitLevel) ~= "function" then return nil end
    local ok, level = pcall(UnitLevel, unit)
    if not ok then return nil end
    if issecretvalue and issecretvalue(level) then return nil end
    level = tonumber(level)
    if not level or level <= 0 then return nil end
    return level
end

-- One alert per kind of response, so the sound alone says what to press. Kept
-- here rather than in Match.lua, which stays free of WoW API so it can be
-- tested outside the game.
local ADVICE_SOUND = {           -- keyed by CastAheadMatch.ADVICE key
    KICK = "RAID_WARNING",
    TANK = "ALARM_CLOCK_WARNING_3",
    AOE = "ALARM_CLOCK_WARNING_2",
    CC = "UI_RAID_BOSS_WHISPER_WARNING",
    -- Curated categories share one fallback beep; the voice line carries the
    -- distinction when the combat TTS is available.
    DODGE = "RAID_WARNING",
    FRONTAL = "RAID_WARNING",
    TARGET = "RAID_WARNING",
    DISPEL = "RAID_WARNING",
    POISON = "RAID_WARNING",
    CURSE = "RAID_WARNING",
    MAGIC = "RAID_WARNING",
    SOOTHE = "RAID_WARNING",
    PURGE = "RAID_WARNING",
    DISEASE = "RAID_WARNING",
    BLEED = "ALARM_CLOCK_WARNING_3",
    SWITCH = "RAID_WARNING",
    ALERT = "RAID_WARNING",
}

-- Default on: only casts in the curated priority set matter enough for icons,
-- voice and the timeline. Switching it off brings every measured spell back.
local function ImportantOnly()
    return CastAheadConfig.Enabled("importantOnly")
end

local function Announceable(candidates)
    return not ImportantOnly() or CastAheadMatch.AnyImportant(candidates)
end

-- Role filter (default on): the priority set is trimmed to what the current
-- spec can act on. Off, or outside the game, every curated cast counts.
CastAheadMatch.PlayerRole = function()
    if not CastAheadConfig.Enabled("roleFilter") then return nil end
    if not (GetSpecialization and GetSpecializationRole) then return nil end
    local spec = GetSpecialization()
    return spec and GetSpecializationRole(spec) or nil
end

-- Which abilities answer each dispel-school category. A category is shown
-- when the character knows any of them (IsPlayerSpell sees talents too), so a
-- dps druid still gets poison calls and a priest healer never does.
local DISPEL_SPELLS = {
    -- Remove Corruption, Nature's Cure, Poison Cleansing Totem, Cleanse
    -- Toxins, Cleanse, Detox (both), Naturalize, Expunge, Cauterizing Flame
    POISON  = { 2782, 88423, 383013, 213644, 4987, 115450, 218164, 360823, 365585, 374251 },
    -- Remove Corruption, Nature's Cure, Remove Curse, Purify Spirit, Cleanse
    -- Spirit, Cauterizing Flame
    CURSE   = { 2782, 88423, 475, 77130, 51886, 374251 },
    -- Purify, Purify Disease, Cleanse, Cleanse Toxins, Detox (both),
    -- Cauterizing Flame
    DISEASE = { 527, 213634, 4987, 213644, 115450, 218164, 374251 },
    -- Purify, Cleanse, Purify Spirit, Nature's Cure, Detox (MW), Naturalize,
    -- Mass Dispel
    MAGIC   = { 527, 4987, 77130, 88423, 115450, 360823, 32375 },
    -- Purge, Dispel Magic, Spellsteal, Consume Magic, Tranquilizing Shot
    PURGE   = { 370, 528, 30449, 278326, 19801 },
    -- Soothe, Tranquilizing Shot
    SOOTHE  = { 2908, 19801 },
}

local capabilityCache = {}

local function KnowsAny(list)
    for i = 1, #list do
        if IsPlayerSpell(list[i]) then return true end
    end
    return false
end

CastAheadMatch.PlayerCanHandle = function(category)
    if not CastAheadConfig.Enabled("roleFilter") then return true end
    if not IsPlayerSpell then return true end
    local known = capabilityCache[category]
    if known == nil then
        if category == "DISPEL" then
            -- Type unknown: anyone who can remove anything from a friend.
            known = KnowsAny(DISPEL_SPELLS.MAGIC) or KnowsAny(DISPEL_SPELLS.POISON)
                or KnowsAny(DISPEL_SPELLS.CURSE) or KnowsAny(DISPEL_SPELLS.DISEASE)
        else
            known = DISPEL_SPELLS[category] == nil or KnowsAny(DISPEL_SPELLS[category])
        end
        capabilityCache[category] = known
    end
    return known
end

local function InvalidateCapabilities()
    for k in pairs(capabilityCache) do capabilityCache[k] = nil end
end

-- Speaking the response beats any beep: "tank buster" says what to do, a chime
-- only says that something happened. 12.1 ships a combat alert voice, so no
-- sound files are needed; the beep stays as the fallback.
local function Speak(text)
    if not text then return false end
    local api = C_CombatAudioAlert
    if not (api and api.SpeakText and Enum and Enum.CombatAudioAlertCategory) then
        return false
    end
    -- The player can switch combat audio alerts off, or zero this category's
    -- volume; SpeakText then silently does nothing (MayReturnNothing), and a
    -- pcall that merely didn't error must not count as "was heard" - that
    -- swallowed the beep fallback and left everything mute.
    if api.IsEnabled and not api.IsEnabled() then return false end
    local category = Enum.CombatAudioAlertCategory.TargetCast
    if api.GetCategoryVolume then
        local okVol, volume = pcall(api.GetCategoryVolume, category)
        if okVol and tonumber(volume) and tonumber(volume) <= 0 then return false end
    end
    local ok, utteranceID = pcall(api.SpeakText, text, category, true)
    return ok and utteranceID ~= nil
end

-- Our own recorded clips (Sounds/<lang>/<KEY>.ogg, rendered by tools/voice.py):
-- the call is heard whatever the player's game-TTS setting is, in one
-- consistent voice. `CastAheadDB.voiceTTS` prefers the game's voice instead.
local SOUND_ROOT = "Interface\\AddOns\\CastAhead\\Sounds\\"

local function PlayClip(advice, lead)
    if not (PlaySoundFile and advice.file) then return false end
    local lang = CastAheadDB and CastAheadDB.voiceLang or "en"
    local path = SOUND_ROOT .. lang .. "\\" .. advice.file .. (lead and "_soon" or "") .. ".ogg"
    local ok, willPlay = pcall(PlaySoundFile, path, "Master")
    return ok and willPlay == true
end

-- Our clips join the shared sound list too, so they can be picked as the
-- "sound" of another category or by other addons.
do
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    if lsm then
        for key, advice in pairs(CastAheadMatch.ADVICE) do
            if key ~= "SAVE" then
                lsm:Register("sound", "CastAhead: " .. advice.say, SOUND_ROOT .. "en\\" .. advice.file .. ".ogg")
            end
        end
    end
end

-- Voice chain: our clip, else the game's combat voice, else a beep. Every
-- caller (in-run alerts, the lead warning, the window's speaker buttons, the
-- test drive) goes through here so they cannot disagree.
local ttsHintShown = false

local function Voice(advice, lead)
    local text = lead and (advice.say .. " soon") or advice.say
    if CastAheadDB and CastAheadDB.voiceTTS then
        -- The player prefers the game's voice; the clip covers for it when it
        -- cannot speak (alerts disabled in the game options) - and says so
        -- once, or the switch looks like it does nothing.
        if Speak(text) then return true end
        if not ttsHintShown then
            ttsHintShown = true
            print("|cff33ff99CastAhead|r the game's TTS voice could not speak - enable Combat Audio Alerts"
                .. " (Options > Sound) and give its categories volume. Playing the clip instead.")
        end
        return PlayClip(advice, lead)
    end
    return PlayClip(advice, lead) or Speak(text)
end

-- The player's own pick for this category, from LibSharedMedia (every sound
-- any installed addon registered); nil when left on the default.
local function CustomSound(advice)
    local name = CastAheadDB and CastAheadDB.sounds and CastAheadDB.sounds[advice.key]
    if not name or name == "" then return nil end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    return lsm and lsm:Fetch("sound", name, true) or nil
end

local function Beep(advice)
    local custom = CustomSound(advice)
    if custom then
        -- Master, not SFX: the point is to be heard over a busy pull.
        if type(custom) == "number" then PlaySound(custom, "Master") else PlaySoundFile(custom, "Master") end
        return
    end
    if not SOUNDKIT then return end
    local kit = SOUNDKIT[ADVICE_SOUND[advice.key] or ""]
    if kit then PlaySound(kit, "Master") end
end

-- `lead` is spoken before the cast ("tank buster soon"), nothing at cast time.
-- A category with a sound of the player's own choosing plays it every time,
-- alongside the voice; the stock beep only stands in when nothing spoke.
local function PlayAdviceSound(advice, lead)
    if not advice then return end
    if not CastAheadConfig.Enabled("sound") then return end
    -- The heads-up is a number of seconds now; 0 means the player does not
    -- want it at all.
    if lead and CastAheadConfig.Lead() <= 0 then return end
    local said = false
    if CastAheadConfig.Enabled("voice") then
        said = Voice(advice, lead)
    end
    if not said or CustomSound(advice) then Beep(advice) end
end

-- Creature identity ---------------------------------------------------------
--
-- Traits.lua ships, per dungeon, what the game still tells us about a hostile
-- nameplate - level, power type, classification, lieutenant flag, creature
-- family - for every creature, plus which creatures stand together in a pack
-- (co) and which segment of the dungeon they are found in (stage). Matching
-- those the moment a plate appears names most mobs before they act, and every
-- later cast is narrowed to that creature's own spells. Health is deliberately
-- absent: UnitHealth is SecretReturns, so the number on the nameplate can be
-- drawn but never read.
local function ReadTraits(unit)
    local traits = { level = SafeLevel(unit) }
    local ok, classification = pcall(UnitClassification, unit)
    if ok and type(classification) == "string" then
        traits.classification = classification
    end
    local okPower, power = pcall(UnitPowerType, unit)
    if okPower and type(power) == "number" then
        traits.power = power
    end
    if type(UnitIsLieutenant) == "function" then
        local okLt, lieutenant = pcall(UnitIsLieutenant, unit)
        if okLt and type(lieutenant) == "boolean" then
            traits.lieutenant = lieutenant
        end
    end
    if type(UnitCreatureFamily) == "function" then
        -- The family itself is Secret; whether there is one is not.
        local okFam, family = pcall(UnitCreatureFamily, unit)
        if okFam and not (issecretvalue and issecretvalue(family)) then
            traits.family = family ~= nil
        end
    end
    return traits
end

-- Which segment of the dungeon the group is in: bosses killed so far plus one,
-- read off the Mythic+ scenario. Nil outside a scenario, and then the stage
-- trait is simply not checked.
local function CurrentStage()
    local api = C_ScenarioInfo
    if not (api and api.GetCriteriaInfo) then return nil end
    local killed, any = 0, false
    for i = 1, 20 do
        local ok, info = pcall(api.GetCriteriaInfo, i)
        if not ok or type(info) ~= "table" then break end
        if not info.isWeightedProgress then          -- enemy forces is weighted
            any = true
            if info.completed then killed = killed + 1 end
        end
    end
    return any and (killed + 1) or nil
end

-- A trait the table does not know, or the game did not tell us, is not held
-- against a creature; only a known value that disagrees rules it out.
local function MatchTraits(row, obs, stage, state)
    if obs.level and row.level ~= obs.level then return false end
    if row.power and obs.power and row.power ~= obs.power then return false end
    if obs.classification and row.elite ~= (obs.classification == "elite") then
        return false
    end
    if row.lieutenant ~= nil and obs.lieutenant ~= nil and row.lieutenant ~= obs.lieutenant then
        return false
    end
    if row.family ~= nil and obs.family ~= nil and row.family ~= obs.family then
        return false
    end
    if row.stage and stage then
        local found = false
        for i = 1, #row.stage do
            if row.stage[i] == stage then found = true break end
        end
        if not found then return false end
    end
    -- Lengths already measured on this plate must all be ones the creature
    -- is known to use - cast lengths against `casts`, channel lengths against
    -- `channels`. A creature with no list for that kind is not judged on it.
    if state and next(state.tracks) then
        for _, track in pairs(state.tracks) do
            if track.measured then
                -- Never `channel and channels or casts`: a channel track on a
                -- creature with no `channels` would fall through to its cast
                -- list and be judged against the wrong lengths.
                local list = row.casts
                if track.channel then list = row.channels end
                local length = track.length
                if list then
                    local known = false
                    for i = 1, #list do
                        if math.abs(list[i] - length) <= CastAheadMatch.CAST_TOLERANCE then
                            known = true
                            break
                        end
                    end
                    if not known then return false end
                end
            end
        end
    end
    return true
end

-- Creatures pinned down on the other plates. Only a locked identity counts as
-- company; a plate still choosing between several says nothing.
-- A plate we knew the identity of has died: one fewer of that kind left.
local function NoteDeath(state)
    if not packs or not packs.total then return end
    local npc = state.npc
    if not npc then
        -- No lock, but every sure cast on the plate agreed on one creature.
        local known = ResolvedNPCs(state)
        if known then
            local only
            for id in pairs(known) do
                if only then only = nil break end
                only = id
            end
            npc = only
        end
    end
    if not npc then return end
    killed[npc] = (killed[npc] or 0) + 1
    local total = packs.total[npc]
    if total and killed[npc] >= total then exhausted[npc] = true end
end

-- Creatures that share a pack with any plate locked nearby. Nil when no pack
-- data or no lock, so callers fall back to whatever else they know.
local function PackMates(except)
    if not packs or not packs.packs then return nil end
    local locked = LockedNPCs(except)
    if not next(locked) then return nil end
    local mates
    for _, pack in ipairs(packs.packs) do
        local shared = false
        for npc in pairs(pack) do
            if locked[npc] then shared = true break end
        end
        if shared then
            mates = mates or {}
            for npc in pairs(pack) do mates[npc] = true end
        end
    end
    return mates
end

function LockedNPCs(except)
    local out = {}
    for unit, other in pairs(plates) do
        if unit ~= except and other.npc then out[other.npc] = true end
    end
    return out
end

local function IdentifyOthers(except)
    for unit, other in pairs(plates) do
        if unit ~= except and not other.npc then Identify(unit, other) end
    end
end

-- The plate is this creature and nothing else: its pending ambiguities are
-- settled, its kit is previewed, and its neighbours get another look at who
-- they might be standing next to.
function LockNPC(unit, state, npc, source)
    if not npc or state.npc == npc then return end
    state.npc = npc
    state.npcSource = source or "cast"
    state.npcSet = nil
    RefineByNPC(state, npc, nil)
    if state.inCombat then
        -- The lock may have come from a neighbour's cast, with nothing on this
        -- plate repainting: its tracks just changed, so its icons and timeline
        -- events must follow now, not at its next cast.
        if CastAheadTimeline then
            for _, track in pairs(state.tracks) do
                if track.candidates then
                    local confident = IsConfident(track)
                    CastAheadTimeline.Sync(track, Announceable(track.candidates) and track.nextAt or nil,
                        confident or track.candidates[1],
                        CastAheadMatch.ConsensusAdvice(track.candidates), confident and true or false)
                end
            end
        end
        RefreshBar(unit, state)
    else
        StartPreview(unit, state)
    end
    IdentifyOthers(unit)
end

-- A trait match alone never locks a plate. The trait table lists only the
-- creatures with casts worth calling, while the cast table knows more of the
-- pack, so a creature absent from the traits can look exactly like the one
-- listed neighbour - that is how a Bribed Captain wore Bribed Guard's spells.
-- The lock waits for a measured cast length that the matched creature is known
-- to use; until then the match only narrows.
local function CastsConfirm(row, state)
    for _, track in pairs(state.tracks) do
        if track.measured then              -- a projected sibling proves nothing
            local list = row.casts
            if track.channel then list = row.channels end
            if list then
                for i = 1, #list do
                    if math.abs(list[i] - track.length) <= CastAheadMatch.CAST_TOLERANCE then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- Name the creature on this plate from its traits. The matches are kept as
-- the set its casts are narrowed to; one match confirmed by a cast locks it.
-- Company narrows the set only positively, as a creature listed next to one
-- already locked nearby - a missing neighbour never rules anyone out.
function Identify(unit, state)
    if state.npc or not traitRows then return end
    local obs = ReadTraits(unit)
    if not obs.level then return end
    local stage = CurrentStage()
    local matched = {}
    for i = 1, #traitRows do
        if not (tuning.population and exhausted[traitRows[i].npc])
            and MatchTraits(traitRows[i], obs, stage, state) then
            matched[#matched + 1] = traitRows[i]
        end
    end
    if #matched > 1 then
        -- Company narrows: packmates of a locked neighbour, from MDT's packs
        -- when they are known, else from the trait rows' own neighbour list.
        local mates = tuning.packsCompany and PackMates(unit) or nil
        local locked = LockedNPCs(unit)
        if mates or next(locked) then
            local kept = {}
            for i = 1, #matched do
                if mates then
                    if mates[matched[i].npc] then kept[#kept + 1] = matched[i] end
                else
                    local co = matched[i].co
                    for j = 1, #(co or {}) do
                        if locked[co[j]] then
                            kept[#kept + 1] = matched[i]
                            break
                        end
                    end
                end
            end
            if #kept > 0 then matched = kept end
        end
    end
    state.npcSet = nil
    if #matched == 1 and CastsConfirm(matched[1], state) then
        LockNPC(unit, state, matched[1].npc, "traits")
    elseif #matched > 0 then
        state.npcSet = {}
        for i = 1, #matched do state.npcSet[matched[i].npc] = true end
    end
end

-- The spell's own icon, with a fallback chain: GetSpellInfo returns nothing at
-- all for spells the client has not cached, which is why every mob was showing
-- the same generic placeholder. GetSpellTexture answers for more of them, and
-- anything still missing is requested so it is there next time.
local FALLBACK_ICON = 136243
local iconCache = {}

local function SpellIcon(spellID)
    if not spellID then return FALLBACK_ICON end
    local cached = iconCache[spellID]
    if cached then return cached end

    local icon
    if C_Spell.GetSpellTexture then
        icon = C_Spell.GetSpellTexture(spellID)
    end
    if not icon then
        local info = C_Spell.GetSpellInfo(spellID)
        icon = info and (info.iconID or info.originalIconID)
    end
    if icon then
        iconCache[spellID] = icon
        return icon
    end
    -- Not loaded yet: ask for it, and use the placeholder just this once.
    if C_Spell.RequestLoadSpellData then
        C_Spell.RequestLoadSpellData(spellID)
    end
    return FALLBACK_ICON
end

local function IsHostileNameplate(unit)
    return UnitExists(unit)
        and UnitCanAttack("player", unit)
        and not UnitIsDead(unit)
end

-- Bar ---------------------------------------------------------------------

-- Frames are never garbage collected in WoW, and nameplates churn constantly in
-- a dungeon, so retired bars go back in the pool instead of being abandoned.
local barPool = {}

local function ReleaseBars(state)
    if not state.bars then return end
    for i = #state.bars, 1, -1 do
        local bar = state.bars[i]
        bar:Hide()
        bar:ClearAllPoints()
        bar._plate = nil
        barPool[#barPool + 1] = bar
        state.bars[i] = nil
    end
end

-- One icon per tracked spell with the seconds left written on it, the way a
-- cooldown reads. No progress bar: the number is the information.
-- The icon size is the player's, so everything drawn on the icon is measured
-- from it rather than from the constant: the countdown, the advice under it
-- and the alert ring all keep their proportions at any size.
local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local function ApplyBarSize(bar)
    local size = CastAheadConfig.IconSize()
    local labelScale = CastAheadConfig.LabelScale()
    if bar._size == size and bar._labelScale == labelScale then return size end
    bar._size, bar._labelScale = size, labelScale
    local scale = size / ICON_SIZE
    bar:SetSize(size, size)
    bar.glow:SetPoint("TOPLEFT", -size * 0.42, size * 0.42)
    bar.glow:SetPoint("BOTTOMRIGHT", size * 0.42, -size * 0.42)
    bar.time:SetFont(FONT, math.max(8, math.floor(14 * scale + 0.5)), "OUTLINE")
    bar.label:SetFont(FONT, math.max(6, math.floor(10 * scale * labelScale + 0.5)), "OUTLINE")
    return size
end

local function GetBar(state, index)
    state.bars = state.bars or {}
    if state.bars[index] then
        ApplyBarSize(state.bars[index])
        return state.bars[index]
    end
    local pooled = table.remove(barPool)
    if pooled then
        state.bars[index] = pooled
        ApplyBarSize(pooled)
        return pooled
    end
    local bar = CreateFrame("Frame", nil, UIParent)
    bar:SetSize(ICON_SIZE, ICON_SIZE)
    bar:EnableMouse(false)
    -- Nameplate addons draw at their own strata; without pinning ours above
    -- them the icon disappears behind the plate it belongs to.
    bar:SetFrameStrata("DIALOG")
    if bar.SetFixedFrameStrata then bar:SetFixedFrameStrata(true) end
    bar:SetFrameLevel(6200)
    if bar.SetFixedFrameLevel then bar:SetFixedFrameLevel(true) end

    bar.border = bar:CreateTexture(nil, "BACKGROUND")
    bar.border:SetPoint("TOPLEFT", -1.5, 1.5)
    bar.border:SetPoint("BOTTOMRIGHT", 1.5, -1.5)

    bar.icon = bar:CreateTexture(nil, "ARTWORK")
    bar.icon:SetAllPoints()
    bar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)   -- trim the stock icon border

    -- Pulsing alert ring for a dangerous cast in progress. Blizzard's own
    -- ActionButtonSpellAlertManager only takes action buttons, so this is the
    -- same idea built from its texture directly.
    bar.glow = bar:CreateTexture(nil, "OVERLAY")
    bar.glow:SetTexture("Interface\\SpellActivationOverlay\\IconAlert")
    bar.glow:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
    bar.glow:SetBlendMode("ADD")
    bar.glow:SetPoint("TOPLEFT", -ICON_SIZE * 0.42, ICON_SIZE * 0.42)
    bar.glow:SetPoint("BOTTOMRIGHT", ICON_SIZE * 0.42, -ICON_SIZE * 0.42)
    bar.glow:Hide()

    local pulse = bar.glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(0.35)
    fade:SetToAlpha(1)
    fade:SetDuration(0.5)
    bar.pulse = pulse

    bar.time = bar:CreateFontString(nil, "OVERLAY")
    bar.time:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    bar.time:SetPoint("CENTER", bar, "CENTER", 0, 0)
    bar.time:SetShadowColor(0, 0, 0, 1)
    bar.time:SetShadowOffset(1, -1)

    -- The advice sits under the icon so a long spell name never widens the row.
    bar.label = bar:CreateFontString(nil, "OVERLAY")
    bar.label:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    bar.label:SetPoint("TOP", bar, "BOTTOM", 0, -1)

    bar:Hide()
    ApplyBarSize(bar)
    state.bars[index] = bar
    return bar
end

-- The nameplate itself is the anchor. It is positioned over the mob by the
-- game, so it is always in the right place, whatever addon draws on top of it.
-- Earlier versions dug for each nameplate addon's own health bar and kept
-- finding frames that live elsewhere - Platynator re-parents Blizzard's
-- UnitFrame into a hidden frame - which stacked every icon in the middle of
-- the screen.

-- Nine positions around (and on) the plate. dx/dy push away from it; `grow`
-- is where the second and later icons go when the player leaves growth on
-- "auto": always away from the plate, so the first icon - the soonest cast -
-- is the one touching it. Sides grow outwards, top and bottom rows stack
-- vertically, the centre runs along the health bar.
local ANCHORS = {
    topleft     = { point = "BOTTOMRIGHT", relative = "TOPLEFT",     dx = -1, dy = 1,  grow = "up" },
    top         = { point = "BOTTOM",      relative = "TOP",         dx = 0,  dy = 1,  grow = "up" },
    topright    = { point = "BOTTOMLEFT",  relative = "TOPRIGHT",    dx = 1,  dy = 1,  grow = "up" },
    left        = { point = "RIGHT",       relative = "LEFT",        dx = -1, dy = 0,  grow = "left" },
    center      = { point = "CENTER",      relative = "CENTER",      dx = 0,  dy = 0,  grow = "right" },
    right       = { point = "LEFT",        relative = "RIGHT",       dx = 1,  dy = 0,  grow = "right" },
    bottomleft  = { point = "TOPRIGHT",    relative = "BOTTOMLEFT",  dx = -1, dy = -1, grow = "down" },
    bottom      = { point = "TOP",         relative = "BOTTOM",      dx = 0,  dy = -1, grow = "down" },
    bottomright = { point = "TOPLEFT",     relative = "BOTTOMRIGHT", dx = 1,  dy = -1, grow = "down" },
}
CastAheadAnchors = ANCHORS   -- the options window builds its grid from this
local GROW = { left = true, down = true, right = true, up = true }
CastAheadGrowth = GROW

-- Sideways, the icons cannot simply sit an icon's width apart: the advice
-- under them is wider than the icon and centred on it, so two neighbours need
-- half of each label between them. Only half of each - stepping everything by
-- the widest label on screen puts "TANKBUSTER"'s full width beside "AOE" and
-- leaves a hole the size of a third icon.
--
-- Each bar therefore carries its own distance from the first, and the floor is
-- the icon itself, for the case where both labels are short or empty.
local function SpreadBars(bars, count)
    local offset, previous = 0, 0
    for i = 1, count do
        local bar = bars[i]
        local width = bar.label:GetStringWidth() or 0
        if i > 1 then
            offset = offset + math.max((bar._size or ICON_SIZE) + ICON_GAP,
                (previous + width) / 2 + LABEL_GAP)
        end
        bar._hOffset = offset
        previous = width
    end
end

-- Filled by RefreshBar on every repaint, so the spread costs no garbage.
local spread = {}

local function AnchorBar(unit, bar, index)
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    -- The bar is a child of UIParent, not of the plate, so it does not inherit
    -- the plate's visibility: a plate that is gone or hidden would otherwise
    -- leave its icon floating at the last position it had.
    if not plate or (plate.IsShown and not plate:IsShown()) then
        bar:Hide()
        return false
    end
    -- Bars stay children of UIParent rather than the plate: plates are recycled
    -- and carry their own alpha, scale and frame level, all of which would drag
    -- the bar around with them.
    -- Which side of the plate the icons sit on (/ca anchor, or the window),
    -- and how far out (/ca offset N) - so they clear whatever the nameplate
    -- addon draws in the same spot. Left and right stack downwards; above and
    -- below run sideways, first icon centred.
    local side = CastAheadDB and CastAheadDB.anchor or "left"
    local spec = ANCHORS[side] or ANCHORS.left
    local gap = BAR_GAP + (CastAheadDB and tonumber(CastAheadDB.offsetX) or 0)
    local growSetting = CastAheadDB and CastAheadDB.grow or "auto"
    local size = bar._size or ICON_SIZE
    local nudgeX, nudgeY = CastAheadConfig.NudgeX(), CastAheadConfig.NudgeY()
    -- SpreadBars measured this one against its neighbours; the fallback only
    -- covers a bar anchored before anything has been painted.
    local hOffset = bar._hOffset or (index - 1) * H_STEP
    -- Measured, not assumed: a verdict too long for one line is written over
    -- two, and stacking icons by a constant would then overlap them.
    local labelH = math.max(bar.label:GetStringHeight() or 0, LABEL_HEIGHT)
    if bar._plate ~= plate or bar._index ~= index or bar._gap ~= gap or bar._side ~= side
        or bar._grow ~= growSetting or bar._placed ~= hOffset or bar._sized ~= size
        or bar._labelH ~= labelH
        or bar._nudgeX ~= nudgeX or bar._nudgeY ~= nudgeY then
        bar._plate = plate
        bar._index = index
        bar._gap = gap
        bar._side = side
        bar._grow = growSetting
        bar._placed = hOffset
        bar._sized = size
        bar._labelH = labelH
        bar._nudgeX = nudgeX
        bar._nudgeY = nudgeY
        bar._anchor = plate
        bar:ClearAllPoints()
        local step = size + labelH + BAR_SPACING
        local x = spec.dx * gap + nudgeX
        -- Above the plate the label hangs under the icon, so lift it clear.
        local y = spec.dy * (gap + (spec.dy > 0 and labelH or 0)) + nudgeY
        -- Growth direction: the player's choice, or the position's own.
        local grow = CastAheadDB and CastAheadDB.grow
        if not GROW[grow] then grow = spec.grow end
        local n = index - 1
        if grow == "right" then
            x = x + hOffset
        elseif grow == "left" then
            x = x - hOffset
        elseif grow == "up" then
            y = y + n * step
        else
            y = y - n * step
        end
        bar:SetPoint(spec.point, plate, spec.relative, x, y)
    end
    return true
end

local function HideBar(state)
    if state.bars then
        for i = 1, #state.bars do state.bars[i]:Hide() end
    end
    state.shown = nil
end

-- Before a mob has cast anything there is still one readable fact - its level.
-- When every spell a creature of this level could open with belongs to the same
-- creature, the mob is identified, and its opening cast can be timed from the
-- moment it entered combat.
-- Before the pull: if the level pins the creature down, show what it will cast
-- at all - no times, just the kit and what to do about each part of it.
function StartPreview(unit, state)
    state.preview = nil
    if not dungeon then return end
    -- A locked identity names the creature outright. Failing that, fall back
    -- to the level, which only helps when it is unique in this dungeon.
    local npc = state.npc
    if not npc and state.level then
        local candidates = CastAheadMatch.OpeningCandidates(dungeon, state.level, false, true)
        if #candidates == 0 then return end
        npc = CastAheadMatch.SharedNPC(candidates)
    end
    if not npc then return end
    local kit = CastAheadMatch.SpellsOfNPC(dungeon, npc)
    kit = CastAheadMatch.NarrowByEnabled(kit, CastAheadUI and CastAheadUI.IsDisabled)
    if ImportantOnly() then kit = CastAheadMatch.OnlyImportant(kit) end
    if #kit == 0 then return end
    local rows = {}
    for i = 1, #kit do
        rows[i] = { preview = true, order = i, row = kit[i], candidates = { kit[i] } }
    end
    state.preview = rows
    RefreshBar(unit, state)
end

local function StartOpening(unit, state)
    state.opening = nil
    if not dungeon or not state.engagedAt then return end
    local candidates
    if state.npc then
        candidates = {}
        local kit = CastAheadMatch.SpellsOfNPC(dungeon, state.npc)
        for i = 1, #kit do
            if CastAheadMatch.HasOpening(kit[i]) then candidates[#candidates + 1] = kit[i] end
        end
    else
        candidates = CastAheadMatch.OpeningCandidates(dungeon, state.level, true, true)
    end
    candidates = CastAheadMatch.NarrowByEnabled(candidates, CastAheadUI and CastAheadUI.IsDisabled)
    if #candidates == 0 or not CastAheadMatch.SharedNPC(candidates) then
        return
    end
    -- Identification ran on the full kit above; only what gets shown is
    -- filtered, and the soonest *shown* opener is wanted - returning when the
    -- very first one was a filler hid every important opener behind it.
    if ImportantOnly() then candidates = CastAheadMatch.OnlyImportant(candidates) end
    local soonest = CastAheadMatch.SoonestOpening(candidates)
    if not soonest then return end
    state.opening = {
        opening = true,
        approximate = true,      -- built on `first`, which scatters by about 3s
        row = soonest,
        candidates = { soonest },
        startAt = state.engagedAt,
        endAt = state.engagedAt + soonest.first,
    }
    RefreshBar(unit, state)
end

-- Once one spell is pinned down, the rest of that creature's kit follows: the
-- delay between a mob's first cast and each of its other openers is tight
-- (0.4s median spread across the logs, against 3.0s when measured from engage).
-- So a single identified cast lays out the whole pull instead of each spell
-- waiting to be seen once.
local function ProjectSiblings(state, row, startAt, now)
    local siblings = byNPC[row.npc]
    if not siblings then return end
    if row.offset then
        state.actedAt = state.actedAt or (startAt - row.offset)
    end
    local isDisabled = CastAheadUI and CastAheadUI.IsDisabled
    for i = 1, #siblings do
        local sibling = siblings[i]
        if sibling ~= row and not (isDisabled and isDisabled(sibling.spell)) then
            local track = GetTrack(state, sibling.cast, sibling.channel)
            if not track.candidates then
                track.candidates = { sibling }
                track.ambiguous = false
                -- No cast of its own yet: the first real one is cast #1, so
                -- the gap after it is rotation slot 1. Seeding index = 1 here
                -- made that first cast count as #2 and skip a slot.
                track.index = nil
                -- Best estimate available, earliest first: the opening order
                -- measured from this mob's own first cast is tight, the delay
                -- from combat start is loose but still better than nothing.
                local anchor, at
                if state.actedAt and sibling.offset then
                    anchor, at = state.actedAt, state.actedAt + sibling.offset
                elseif state.engagedAt and CastAheadMatch.HasOpening(sibling) then
                    anchor, at = state.engagedAt, state.engagedAt + sibling.first
                end
                if at and at > now then
                    track.projected = true
                    track.lastStartAt = anchor
                    track.nextAt = at
                end
                -- Whether or not it could be timed, the icon is shown: the mob
                -- is identified, so the player should see its whole dangerous
                -- kit rather than only the parts with a usable schedule.
                track.listed = true
            end
        end
    end
end

-- Every tracked spell gets its own row. Rows are ordered by when the cast is
-- due: the one being cast right now first, then the nearest countdown, and
-- rows with no time (previews, overdue "!") last, in cast-length order. The
-- first icon is therefore always the next thing to react to.
local function RowSort(a, b)
    if (a.casting or false) ~= (b.casting or false) then return a.casting end
    if a.endAt and b.endAt and a.endAt ~= b.endAt then return a.endAt < b.endAt end
    if (a.endAt ~= nil) ~= (b.endAt ~= nil) then return a.endAt ~= nil end
    return a.order < b.order
end

local function CollectRows(state)
    local rows = {}
    if not next(state.tracks) then
        if state.opening then
            state.opening.order = -1
            rows[#rows + 1] = state.opening
        elseif state.preview then
            for i = 1, #state.preview do
                rows[#rows + 1] = state.preview[i]
            end
        end
    end
    for length, track in pairs(state.tracks) do
        local casting = state.casting and state.casting.track == track
        if casting or track.nextAt or track.listed then
            local source = casting and state.casting or track
            rows[#rows + 1] = {
                -- The measured length, not the table key: a channel's key is
                -- pushed past every cast length, which would park every channel
                -- at the end of the untimed rows instead of in length order.
                order = track.length or length,
                track = track,
                -- Times we cannot stand behind: projected from the mob's
                -- opening order, still ambiguous between candidates, or built
                -- on a cooldown whose samples were scattered. These are shown
                -- as "when to start paying attention", not as a promise.
                approximate = track.projected == true or source.ambiguous == true
                    or (track.candidates and track.candidates[1].approx == true)
                    or (track.candidates and (track.candidates[1].n or 0) < THIN_EVIDENCE)
                    or nil,
                casting = casting,
                -- Listed but untimed: identified, no countdown to show. An
                -- overdue prediction counts as untimed too - it is drawn as
                -- "!" and kept until the cast arrives or it goes stale.
                -- Rebuilding its endAt here is what made the overdue branch
                -- of OnUpdate repaint the plate every frame.
                preview = (not casting and (not track.nextAt or track.due)) or nil,
                due = track.due or nil,
                candidates = source.candidates or track.candidates,
                row = casting and source.row or CastAheadMatch.BestGuess(track.candidates),
                ambiguous = source.ambiguous,
                startAt = casting and source.startAt or track.lastStartAt,
                endAt = casting and source.endAt or (not track.due and track.nextAt) or nil,
            }
        end
    end
    -- Display filter only: identification above used every row, or a kicked
    -- filler could no longer name the mob it belongs to.
    if ImportantOnly() then
        local kept = {}
        for i = 1, #rows do
            if CastAheadMatch.AnyImportant(rows[i].candidates) then
                kept[#kept + 1] = rows[i]
            end
        end
        rows = kept
    end
    table.sort(rows, RowSort)
    return rows
end

local function PaintBar(bar, entry, interruptible)
    local row = entry.row
    -- Only advise when the whole candidate set agrees.
    local advice = CastAheadMatch.ConsensusAdvice(entry.candidates or { row }, interruptible)
    -- No agreement: name the calls in play instead of nothing, in white, so
    -- the player decides between them rather than being told the wrong one.
    local split = not advice and CastAheadMatch.SplitAdvice(entry.candidates, interruptible) or nil
    bar.icon:SetTexture(SpellIcon(row.spell))
    local short = CastAheadConfig.ShortLabels()
    if advice then
        bar.label:SetText(short and advice.short or advice.label)
        bar.label:SetTextColor(advice.r, advice.g, advice.b)
        bar.border:SetColorTexture(advice.r, advice.g, advice.b, entry.casting and 1 or 0.7)
    elseif split then
        -- Stacked, not joined by a slash: two verdicts side by side are the
        -- widest thing the layout ever has to make room for, and they read
        -- just as well one above the other.
        bar.label:SetText((short and split[1].short or split[1].label)
            .. "\n" .. (short and split[2].short or split[2].label))
        bar.label:SetTextColor(0.9, 0.9, 0.9)
        bar.border:SetColorTexture(0.7, 0.7, 0.7, entry.casting and 1 or 0.7)
    else
        bar.label:SetText("")
        bar.border:SetColorTexture(0, 0, 0, 0.8)
    end
    -- A cast happening right now is the urgent case, so it desaturates nothing
    -- and gets a full-strength icon; a pending timer is dimmed.
    -- Glow only while a dangerous cast is actually going out: that is the
    -- moment something has to be pressed, and a ring that is always on would
    -- stop meaning anything.
    if entry.casting and advice then
        bar.glow:SetVertexColor(advice.r, advice.g, advice.b)
        bar.glow:Show()
        if not bar.pulse:IsPlaying() then bar.pulse:Play() end
    else
        bar.pulse:Stop()
        bar.glow:Hide()
    end
    bar.icon:SetVertexColor(1, 1, 1, entry.casting and 1 or (entry.preview and 0.55 or 0.75))
    if entry.preview then
        -- An estimate that has elapsed: the cast is due, so say so instead of
        -- leaving a blank icon.
        if entry.due then
            bar.time:SetText("|cffffd100!|r")
        else
            bar.time:SetText("")
        end
    end
    -- Amber for a time that is an estimate, plain white for a measured one.
    if entry.approximate then
        bar.time:SetTextColor(1, 0.82, 0.4)
    else
        bar.time:SetTextColor(1, 1, 1)
    end
    if bar.icon.SetDesaturated then
        bar.icon:SetDesaturated(entry.ambiguous == true)
    end
end

function RefreshBar(unit, state)
    -- Nameplate icons are one output among two; the timeline is fed elsewhere
    -- and keeps working when these are switched off.
    if not CastAheadConfig.Enabled("nameplates") then
        state.shown = nil
        if state.bars then
            for i = 1, #state.bars do state.bars[i]:Hide() end
        end
        return
    end
    local entries = CollectRows(state)
    state.shown = entries
    -- Painted before being placed: sideways the icons step by the width of the
    -- widest advice under them, not by the icon, so two short calls sit close
    -- together instead of leaving a hole the size of a third icon.
    for i = 1, #entries do
        local entry = entries[i]
        local bar = GetBar(state, i)
        -- The game's own verdict only applies to the cast happening now.
        local interruptible
        if entry.casting then interruptible = state.interruptible end
        PaintBar(bar, entry, interruptible)
        entry.bar = bar
        spread[i] = bar
    end
    SpreadBars(spread, #entries)
    for i = 1, #entries do
        local bar = entries[i].bar
        if AnchorBar(unit, bar, i) then
            bar:Show()
            diag.shown = diag.shown + 1
        end
    end
    if state.bars then
        for i = #entries + 1, #state.bars do
            state.bars[i]:Hide()
        end
    end
end

-- State -------------------------------------------------------------------

local function GetState(unit)
    local state = plates[unit]
    if not state then
        state = { tracks = {} }
        plates[unit] = state
    end
    return state
end

-- Channel tracks live in the same table as cast tracks but under keys pushed
-- past any real cast length, so a 6.0s cast and a 6.0s channel on one plate
-- never share a schedule. One constant, nothing else knows about it.
local CHANNEL_KEY = 1000

-- One track per cast length, within the same tolerance the matcher uses.
function GetTrack(state, duration, channel)
    local key = channel and (duration + CHANNEL_KEY) or duration
    for length, track in pairs(state.tracks) do
        if (track.channel == true) == (channel == true)
            and math.abs(length - key) <= CastAheadMatch.CAST_TOLERANCE then
            return track, length
        end
    end
    local track = { channel = channel or nil }
    state.tracks[key] = track
    return track, key
end

-- Creatures the plate's other, already identified casts point at. A mob only
-- casts its own spells, so this rules out lookalikes with the same cast time.
-- Only tracks whose identification stood on its own (a cast length unique in
-- the dungeon, or an interval that matched the schedule) get to name the
-- creature: the narrowing this feeds is strict, and a single candidate left
-- over by a fallback would rule out the right spells.
function ResolvedNPCs(state, exclude)
    local known
    for _, track in pairs(state.tracks) do
        if track ~= exclude and track.sure and track.candidates and #track.candidates == 1 then
            known = known or {}
            known[track.candidates[1].npc] = true
        end
    end
    return known
end

-- The plate's creature is now known: other tracks that were still choosing
-- between several creatures' spells keep only this one's, and a track holding
-- none of them was never this mob's cast at all. Without this, a Blazebound
-- Destroyer's 3.5s Inferno stayed tied with Primal Juggernaut's Excavating
-- Blast until the next time it was cast.
function RefineByNPC(state, npc, except)
    for key, other in pairs(state.tracks) do
        if other ~= except and other.candidates and #other.candidates > 1 then
            local kept = CastAheadMatch.NarrowByMob(other.candidates, { [npc] = true })
            if #kept == 0 then
                if CastAheadTimeline then CastAheadTimeline.Cancel(other) end
                state.tracks[key] = nil
            elseif #kept < #other.candidates then
                other.candidates = kept
                other.ambiguous = #kept > 1
                if other.lastStartAt and not other.projected and other.index then
                    local cd = other.observedCD or CastAheadMatch.ConsensusCD(kept, other.index)
                    if cd then other.nextAt = other.lastStartAt + cd end
                end
            end
        end
    end
end

-- Creatures this plate is known to be, strictly: a locked identity, or casts
-- that stood on their own. The trait match is softer and applied separately.
local function KnownNPCs(state, track)
    if state.npc then return { [state.npc] = true } end
    return ResolvedNPCs(state, track)
end

local function ClearTimeline(state)
    if not (state and state.tracks and CastAheadTimeline) then return end
    for _, track in pairs(state.tracks) do
        CastAheadTimeline.Cancel(track)
    end
end

-- What the last finished cast on each unit was identified as - the candidate
-- rows, possibly none. Read by the replay harness (test_replay.lua) to score
-- the matcher against real combat logs; nothing in the addon reads it.
local lastIdentified = {}
local function LastCandidates(unit) return lastIdentified[unit] end
-- Optional observer of the narrowing steps in OnCastStop: trace(unit, step,
-- candidates). Set by the replay harness, nil in the game.
local narrowTrace
local function Trace(unit, step, candidates)
    if narrowTrace then narrowTrace(unit, step, candidates) end
end

-- Between ENCOUNTER_START and ENCOUNTER_END nothing is tracked: the data is
-- about trash, and a boss add whose cast happens to last as long as some
-- trash spell would otherwise wear that spell's schedule.
local inEncounter = false

local function DropUnit(unit)
    local state = plates[unit]
    if state then
        state.shown = nil
        ClearTimeline(state)
        ReleaseBars(state)
        plates[unit] = nil
    end
end

-- Combat ------------------------------------------------------------------

-- There is no event for a nameplate entering combat, so poll a slice of them
-- per tick. engagedAt is what row.first is measured from.
local function RefreshCombat(unit)
    local state = plates[unit]
    if not state then return end
    if not IsHostileNameplate(unit) or not C_NamePlate.GetNamePlateForUnit(unit) then
        -- Not attackable any more, dead, or the plate is simply gone: the unit
        -- token may already have been recycled onto something else.
        if UnitIsDead(unit) then NoteDeath(state) end
        DropUnit(unit)
        return
    end
    local inCombat = UnitAffectingCombat(unit)
    if inCombat and not state.inCombat then
        state.engagedAt = GetTime()
        state.level = state.level or SafeLevel(unit)
        StartOpening(unit, state)
    elseif not inCombat and state.inCombat then
        -- Out of combat the mob resets its rotation, so nothing learned about
        -- it still holds - including a cast that was in flight when it evaded.
        ClearTimeline(state)
        wipe(state.tracks)
        state.engagedAt = nil
        state.actedAt = nil
        state.castStartAt = nil
        state.casting = nil
        state.interrupted = nil
        state.interruptible = nil
        state.opening = nil
        HideBar(state)
        StartPreview(unit, state)
    end
    state.inCombat = inCombat
end

local function PollCombat()
    for _ = 1, COMBAT_POLL_BATCH do
        RefreshCombat("nameplate" .. pollIndex)
        pollIndex = pollIndex + 1
        if pollIndex > MAX_NAMEPLATES then pollIndex = 1 end
    end
end

-- Events ------------------------------------------------------------------

local function OnCastStart(unit, channel)
    -- Out-of-combat casts (patrol flavour channels) tell us nothing about a
    -- pull's rotation, so they are ignored - the poll may be up to a tick
    -- stale, so ask the unit directly rather than trusting cached state.
    if not UnitAffectingCombat(unit) or not IsHostileNameplate(unit) then return end
    local state = GetState(unit)
    if not state.inCombat then
        state.inCombat = true
        state.engagedAt = state.engagedAt or GetTime()
    end
    local now = GetTime()
    state.castStartAt = now
    state.channelling = channel or nil
    state.interrupted = false
    state.interruptible = nil
    state.casting = nil
    state.opening = nil

    -- Which spell is this? The one we predicted for about now. Cast length is
    -- Secret, so the bar's length comes from the table instead.
    local best, bestDelta
    local identified, identifiedCount = nil, 0
    for _, track in pairs(state.tracks) do
        -- Only tracks of the kind that just started may claim it. A channel
        -- landing where a cast was predicted is not that cast: taking it
        -- finished the cast's timeline event early, drew its bar, voiced its
        -- call, and handed its track to the interrupt path afterwards.
        if track.candidates and (track.channel == true) == (channel == true) then
            identified, identifiedCount = track, identifiedCount + 1
            if track.nextAt then
                local delta = math.abs(now - track.nextAt)
                -- Inside the window, or overdue and still waiting: the "!"
                -- icon is kept precisely so a late cast is recognised.
                local late = track.due and now >= track.nextAt
                if (delta <= PREDICTION_MATCH_WINDOW or late) and (not bestDelta or delta < bestDelta) then
                    best, bestDelta = track, delta
                end
            end
        end
    end
    -- Fillers carry no countdown to match against, but if the plate has shown
    -- only one spell so far, this is it - and naming a kickable filler is the
    -- whole point.
    -- Only a track with no countdown may claim it: one with a schedule that
    -- put the cast elsewhere just said this is not its spell, and taking it
    -- anyway finished its timeline event early and voiced the wrong call.
    if not best and identifiedCount == 1 and not identified.nextAt then
        best = identified
    end
    if best then
        if CastAheadTimeline then CastAheadTimeline.Finish(best) end
        state.casting = {
            casting = true,
            track = best,
            row = CastAheadMatch.BestGuess(best.candidates),
            candidates = best.candidates,
            ambiguous = best.ambiguous,
            startAt = now,
            endAt = now + CastAheadMatch.BestGuess(best.candidates).cast,
        }
    end
    -- Sound fires once, on the cast that needs answering - not on the timer
    -- that led up to it.
    if state.casting and Announceable(state.casting.candidates) then
        PlayAdviceSound(CastAheadMatch.ConsensusAdvice(state.casting.candidates, state.interruptible))
    end
    -- Repaint either way: an unrecognised cast must not leave the previous
    -- countdown on screen as if nothing were happening.
    RefreshBar(unit, state)
end

-- Advances the schedule for a cast that was stopped before it finished. Its
-- length is unknown, so it can only be attributed when the plate tracks exactly
-- one spell and the timing matches what we were waiting for.
local function ResolveInterrupted(unit, state, startAt, matched)
    -- A kick does not refund the ability's cooldown, so the schedule still
    -- moves: re-anchor it on the cast start.
    --
    -- `matched` is the track OnCastStart attributed the cast to. Without it
    -- (a cast that matched nothing on the way in) fall back to the plate's
    -- only track, and then only when the timing says it really was that spell:
    -- a kicked filler leaves no track of its own, so without the check its
    -- interrupt would re-anchor an unrelated spell's schedule.
    local only = matched
    if not only then
        -- Only tracks of the kind that was in flight may be the fallback: a
        -- kicked channel that matched nothing has no business advancing a cast
        -- track's rotation just because it happens to be the plate's only one.
        local channel = state.channelling == true
        local count = 0
        for _, track in pairs(state.tracks) do
            if (track.channel == true) == channel then
                count = count + 1
                only = track
            end
        end
        local expected = count == 1 and only.nextAt
            and math.abs(startAt - only.nextAt) <= PREDICTION_MATCH_WINDOW
        if not expected then only = nil end
    end
    if only and only.candidates and #only.candidates == 1
        and CastAheadMatch.HasSchedule(only.candidates[1]) then
        only.index = (only.index or 0) + 1
        only.lastStartAt = startAt
        only.due = nil
        only.warned = nil        -- the next prediction earns its own heads-up
        only.projected = nil     -- anchored on a real cast start from here on
        local cd = only.observedCD or CastAheadMatch.CDAt(only.candidates[1], only.index)
        only.nextAt = cd and (startAt + cd) or nil
        if CastAheadTimeline then
            local sure = IsConfident(only)
            -- A nil time cancels: unimportant casts stay off the timeline.
            CastAheadTimeline.Sync(only, Announceable(only.candidates) and only.nextAt or nil,
                sure or only.candidates[1],
                CastAheadMatch.ConsensusAdvice(only.candidates), sure and true or false)
        end
    end
    RefreshBar(unit, state)
end

-- A cast that finished on its own: its measured length is the identifying fact.
local function OnCastStop(unit, channel)
    local state = plates[unit]
    if not state or not state.castStartAt then return end
    -- A STOP of the other kind is not ours: a channel that follows a cast on
    -- the same creature raises CHANNEL_START first, which resets the clock.
    if (state.channelling == true) ~= (channel == true) then return end
    local startAt = state.castStartAt
    state.castStartAt = nil
    state.casting = nil

    diag.casts = diag.casts + 1
    local duration = GetTime() - startAt
    local track, trackKey = GetTrack(state, duration, channel)
    local candidates = track.candidates
    -- A projected sibling's lastStartAt is the anchor it was laid out from, not
    -- a cast of its own, so nothing below may read it as an interval - doing so
    -- adopted an engage-to-first-cast delay as the spell's cooldown.
    local previousCast = (not track.projected) and track.lastStartAt or nil
    -- A spell the player switched off mid-pull may still sit on a track from
    -- before; it is re-identified like anything else, and drops out there.
    if candidates and #candidates == 1 and CastAheadUI and CastAheadUI.IsDisabled
        and CastAheadUI.IsDisabled(candidates[1].spell) then
        candidates = nil
    end
    local rejected
    if candidates and #candidates == 1 and previousCast
        and CastAheadMatch.HasSchedule(candidates[1])
        and not CastAheadMatch.SlotForInterval(candidates[1], startAt - previousCast, track.index) then
        local measured = startAt - previousCast
        local tabled = CastAheadMatch.CDAt(candidates[1], track.index) or measured
        if math.abs(measured - tabled) <= tabled * 0.5 then
            -- Close but outside the strict tolerance. The table is a median over
            -- a handful of pulls; the mob in front of us is the authority on its
            -- own cooldown, so adopt what it did instead of dropping the match -
            -- but only for a single-slot cooldown: one noisy gap must not
            -- flatten a {4.8, 4.8, 8.7} rotation into a scalar.
            if #candidates[1].cd == 1 then track.observedCD = measured end
        else
            -- Nowhere near this spell's schedule: it was never this spell, and
            -- the re-identification below must not hand it straight back.
            rejected = candidates[1]
            candidates = nil
            track.observedCD = nil
            track.index = nil
        end
    end
    if candidates and #candidates == 1 and not track.sure and not tuning.trustUnsureTrack then
        -- The track's one candidate was a guess, not a confirmed identity:
        -- identify this cast on its own merits instead of inheriting it.
        candidates = nil
    end
    if candidates and #candidates == 1 then
        Trace(unit, "track", candidates)
    else
        candidates = CastAheadMatch.ByCastTime(dungeon, duration, channel)
        Trace(unit, "length", candidates)
        if tuning.population and next(exhausted) then
            candidates = CastAheadMatch.DropNPCs(candidates, exhausted)
            Trace(unit, "population", candidates)
        end
        if rejected then
            local kept = {}
            for i = 1, #candidates do
                if candidates[i] ~= rejected then kept[#kept + 1] = candidates[i] end
            end
            candidates = kept
            Trace(unit, "rejected", candidates)
        end
        candidates = CastAheadMatch.NarrowByEnabled(candidates, CastAheadUI and CastAheadUI.IsDisabled)
        candidates = CastAheadMatch.NarrowByLevel(candidates, state.level)
        Trace(unit, "level", candidates)
        candidates = CastAheadMatch.NarrowByMob(candidates, KnownNPCs(state, track))
        Trace(unit, "mob", candidates)
        -- The trait match prefers its own creatures but cannot exclude: a
        -- creature the trait table does not list still has to be recognised
        -- from the cast table alone.
        if state.npcSet and #candidates > 1 and tuning.traitsNarrow then
            local within = CastAheadMatch.NarrowByMob(candidates, state.npcSet)
            if #within > 0 then candidates = within end
            Trace(unit, "traits", candidates)
        end
        -- A neighbour we are sure of narrows this plate to its packmates -
        -- preferred, never exclusive, since patrols and mixed pulls exist.
        if #candidates > 1 and tuning.packsNarrow then
            local mates = PackMates(unit)
            if mates then
                local within = CastAheadMatch.NarrowByMob(candidates, mates)
                if #within > 0 then candidates = within end
                Trace(unit, "packs", candidates)
            end
        end
        if previousCast then
            candidates = CastAheadMatch.NarrowByInterval(candidates, startAt - previousCast)
            Trace(unit, "interval", candidates)
        elseif state.engagedAt then
            candidates = CastAheadMatch.NarrowByFirst(candidates, startAt - state.engagedAt)
            Trace(unit, "first", candidates)
        end
    end
    if #candidates == 0 and not channel and state.npc and state.npcSource == "traits" then
        -- The creature the traits named does not cast this at all. A lock
        -- confirmed by a shared cast length is only as good as the trait
        -- table's coverage - a creature listed in neither table can wear a
        -- neighbour's identity - so the lock is released rather than obeyed,
        -- and the cast is identified again without it. A lock from a cast of
        -- its own is kept: that was evidence, not a guess.
        --
        -- Channels are excluded from this release entirely. The channel table
        -- is a fraction of the cast table's size, so most channels a creature
        -- has land here with nothing to match - an absence that says far more
        -- about our coverage than about the creature, and is no reason to throw
        -- an identification away.
        state.npc, state.npcSource, state.npcSet = nil, nil, nil
        candidates = CastAheadMatch.ByCastTime(dungeon, duration, channel)
        candidates = CastAheadMatch.NarrowByEnabled(candidates, CastAheadUI and CastAheadUI.IsDisabled)
        candidates = CastAheadMatch.NarrowByLevel(candidates, state.level)
        candidates = CastAheadMatch.NarrowByMob(candidates, ResolvedNPCs(state, track))
        if previousCast then
            candidates = CastAheadMatch.NarrowByInterval(candidates, startAt - previousCast)
        elseif state.engagedAt then
            candidates = CastAheadMatch.NarrowByFirst(candidates, startAt - state.engagedAt)
        end
    end
    lastIdentified[unit] = candidates
    if #candidates == 0 then
        -- The track goes, so its timeline event must go with it, or the id is
        -- lost and the icon lingers on Blizzard's timeline.
        if CastAheadTimeline then CastAheadTimeline.Cancel(track) end
        state.tracks[trackKey] = nil
        RefreshBar(unit, state)
        return
    end

    -- Line the rotation up with reality: the interval we just saw says which
    -- slot the mob is on, and a measured cooldown beats the table's median.
    local index = (track.index or 0) + 1
    local slotMatched = false
    if previousCast and #candidates == 1 then
        local measured = startAt - previousCast
        local slot = CastAheadMatch.SlotForInterval(candidates[1], measured, track.index)
        if slot then
            slotMatched = true
            index = slot + 1
            -- Only a spell allowed a countdown may pin one from observation,
            -- or fillers smuggle their 3.6s bar back in through this path.
            track.observedCD = (CastAheadMatch.HasSchedule(candidates[1])
                and #candidates[1].cd == 1) and measured or nil
        end
    end

    diag.identified = diag.identified + (#candidates == 1 and 1 or 0)
    diag.candidates = #candidates
    track.candidates = candidates
    track.lastStartAt = startAt
    track.measured = true
    track.length = duration
    track.index = index
    track.due = nil
    track.warned = nil
    track.listed = true
    track.ambiguous = #candidates > 1
    track.projected = nil
    -- Sure means the identification needed no fallback: the cast length (with
    -- the level) is unique in this dungeon, or the interval fit the schedule.
    if #candidates == 1 then
        local unique = CastAheadMatch.NarrowByLevel(
            CastAheadMatch.ByCastTime(dungeon, duration, channel), state.level)
        track.sure = (#unique == 1) or slotMatched
        if track.sure then LockNPC(unit, state, candidates[1].npc) end
    else
        track.sure = nil
    end
    if not state.npc then Identify(unit, state) end
    if #candidates == 1 then
        recentCasts[#recentCasts + 1] = { row = candidates[1], at = GetTime() }
    end
    if #candidates == 1 then
        ProjectSiblings(state, candidates[1], startAt, GetTime())
    end
    local cd = track.observedCD or CastAheadMatch.ConsensusCD(candidates, index)
    track.nextAt = cd and (startAt + cd) or nil
    local confident = IsConfident(track)
    if CastAheadTimeline then
        -- A nil time cancels: unimportant casts stay off the timeline.
        CastAheadTimeline.Sync(track, Announceable(candidates) and track.nextAt or nil,
            confident or candidates[1],
            CastAheadMatch.ConsensusAdvice(candidates), confident and true or false)
    end
    RefreshBar(unit, state)
end

-- INTERRUPTED and FAILED are terminal: Blizzard's own cast bar clears on them
-- and never waits for a STOP, so the cast has to be finished off here rather
-- than parked in a flag that a later STOP may or may not come to read.
local function OnCastInterrupted(unit)
    local state = plates[unit]
    if not state or not state.castStartAt then return end
    local startAt = state.castStartAt
    local matched = state.casting and state.casting.track or nil
    state.castStartAt = nil
    state.casting = nil
    state.interrupted = true
    ResolveInterrupted(unit, state, startAt, matched)
end

-- Dispel learning ---------------------------------------------------------
--
-- A harmful aura arriving on the player within this long of exactly one
-- identified cast finishing is taken to be that cast's debuff, and its dispel
-- type ("dispel poison" beats "targeted") is remembered for the spell.
--
-- UNIT_AURA's updateInfo is Secret inside instances (even addedAuras on the
-- player), so it is not read at all. Instead the player's harmful auras are
-- enumerated and a new auraInstanceID is the arrival. Every value that comes
-- back is checked for secrecy before it is compared, and anything secret ends
-- the attempt quietly - the fallback is simply "targeted".
local DEBUFF_WINDOW = 2.5
recentCasts = {}
local seenAuras = {}

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function RecentSingleCast()
    local now = GetTime()
    local recent
    for i = #recentCasts, 1, -1 do
        if now - recentCasts[i].at > DEBUFF_WINDOW then
            table.remove(recentCasts, i)
        elseif recent then
            return nil                  -- two casts just finished: ambiguous
        else
            recent = recentCasts[i]
        end
    end
    return recent
end

local function LearnDispel()
    local api = C_UnitAuras
    if not (api and api.GetAuraDataByIndex) then return end
    local recent = RecentSingleCast()
    for i = 1, 40 do
        local ok, aura = pcall(api.GetAuraDataByIndex, "player", i, "HARMFUL")
        if not ok then break end
        if IsSecret(aura) then return end   -- before even the nil test: comparing a Secret throws
        if aura == nil then break end
        local id, kind = aura.auraInstanceID, aura.dispelName
        if IsSecret(id) or IsSecret(kind) then return end
        if id and not seenAuras[id] then
            seenAuras[id] = true
            -- New since last look. Auras present before the first look are
            -- swallowed the same way, so nothing old is pinned on a cast.
            if recent and type(kind) == "string" and CastAheadMatch.DISPEL_CATEGORY[kind] then
                CastAheadDB = CastAheadDB or {}
                CastAheadDB.dispel = CastAheadDB.dispel or {}
                CastAheadDB.dispel[recent.row.spell] = kind
                recent.row.dispel = kind
                recent = nil            -- one debuff per cast
            end
        end
    end
end

-- The payload past `unit` differs per event: UNIT_AURA's arg2 is updateInfo
-- (never read - it is Secret in instances), the spellcast events carry
-- castGUID, spellID and, on CHANNEL_STOP, interruptedBy.
frame:SetScript("OnEvent", function(_, event, unit, arg2, arg3, arg4)
    if event == "UNIT_AURA" then
        if unit == "player" then LearnDispel() end
        return
    end
    if event == "PLAYER_SPECIALIZATION_CHANGED" or event == "SPELLS_CHANGED" then
        -- A new spec or talent loadout can change both the role and which
        -- dispels the character knows.
        if event == "SPELLS_CHANGED" or unit == "player" then
            InvalidateCapabilities()
            if CastAheadCore then CastAheadCore.Reapply() end
        end
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        -- Order matters: the profile saved under the addon's old name is
        -- adopted before anything reads or writes settings.
        if CastAheadConfig.AdoptOldName then CastAheadConfig.AdoptOldName() end
        CastAheadConfig.Migrate()
        wipe(seenAuras)
        wipe(recentCasts)
        for _, state in pairs(plates) do
            ClearTimeline(state)
        end
        LoadDungeon()
        if not dungeon then
            for tracked in pairs(plates) do DropUnit(tracked) end
        end
        return
    end
    if event == "CHALLENGE_MODE_START" then
        ResetPopulation()
        return
    end
    if event == "ENCOUNTER_START" or event == "ENCOUNTER_END" then
        inEncounter = event == "ENCOUNTER_START"
        if inEncounter then
            -- Everything on screen belongs to the pull that just ended; the
            -- centre call clears itself once no plate is casting.
            for tracked in pairs(plates) do DropUnit(tracked) end
        end
        return
    end
    if event == "NAME_PLATE_UNIT_REMOVED" then
        DropUnit(unit)
        return
    end
    if not dungeon or inEncounter
        or type(unit) ~= "string" or not unit:match("^nameplate%d+$") then
        return
    end
    if event == "NAME_PLATE_UNIT_ADDED" then
        diag.plates = diag.plates + 1
        if IsHostileNameplate(unit) then
            Probe(unit)
            diag.hostilePlates = (diag.hostilePlates or 0) + 1
            local state = GetState(unit)
            ClearTimeline(state)
            wipe(state.tracks)
            state.inCombat = nil
            state.engagedAt = nil
            state.actedAt = nil
            HideBar(state)
            state.level = SafeLevel(unit)
            state.npc = nil                 -- the unit token may be recycled
            state.npcSource = nil
            state.npcSet = nil
            Identify(unit, state)
            if not state.npc then StartPreview(unit, state) end
            RefreshCombat(unit)
        end
    elseif event == "UNIT_HEALTH" then
        if plates[unit] and UnitIsDead(unit) then
            NoteDeath(plates[unit])
            DropUnit(unit)
        end
    elseif event == "UNIT_SPELLCAST_START" then
        Probe(unit)
        OnCastStart(unit, false)
    elseif event == "UNIT_SPELLCAST_STOP" then
        OnCastStop(unit, false)
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        OnCastStart(unit, true)
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        -- A kicked channel is told apart from one that ran its course by the
        -- fourth payload value, `interruptedBy` - which is where Blizzard's own
        -- cast bar reads it. UNIT_SPELLCAST_INTERRUPTED is not guaranteed to
        -- arrive first, or at all, so waiting for it measured the shortened
        -- channel and identified the wrong spell from its length.
        --
        -- The value is Secret while unit spellcasts are restricted, so secrecy
        -- is tested before anything is compared to it; nil is never secret, so
        -- this order is safe.
        if IsSecret(arg4) or arg4 ~= nil then
            OnCastInterrupted(unit)     -- a second call from INTERRUPTED is a no-op
        else
            OnCastStop(unit, true)
        end
    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE" or event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        local state = plates[unit]
        if state and state.castStartAt then
            local was = state.interruptible
            state.interruptible = (event == "UNIT_SPELLCAST_INTERRUPTIBLE")
            if state.casting and was ~= state.interruptible then
                -- The verdict can change once the game reports interruptibility,
                -- and a cast that just became kickable deserves its own alert -
                -- but only if it was not already called KICK at cast start, or
                -- every kickable cast is announced twice.
                local before = CastAheadMatch.ConsensusAdvice(state.casting.candidates, was)
                local advice = CastAheadMatch.ConsensusAdvice(state.casting.candidates, state.interruptible)
                if advice and advice.label == "KICK" and advice ~= before
                    and Announceable(state.casting.candidates) then
                    PlayAdviceSound(advice)
                end
            end
            RefreshBar(unit, state)
        end
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED"
        or event == "UNIT_SPELLCAST_FAILED_QUIET" then
        OnCastInterrupted(unit)
    end
end)

-- Centre-screen call: while an important cast is going out, its icon, the
-- response in words and the seconds left, big, where the eyes already are.
-- One at a time - the cast ending soonest - since two lines of shouting help
-- nobody. `CastAheadDB.centerText = false` switches it off; `centerY` shifts it.
local CENTER_Y = -120
local center
local centerUnlocked = false   -- /ca move: the block is being dragged
local demo          -- the test drive's state, defined with CastAheadCore.Test

-- Where the block sits: offsets from the screen centre, set by dragging it
-- (/ca move) or by /ca center <px>.
local function CenterOffset()
    return (CastAheadDB and tonumber(CastAheadDB.centerX) or 0),
        CENTER_Y + (CastAheadDB and tonumber(CastAheadDB.centerY) or 0)
end

local CENTER_LINES = 3      -- a pack can cast three things at once; more is noise
local CENTER_LINE_H = 44

local function CenterFrame()
    if center then return center end
    center = CreateFrame("Frame", nil, UIParent)
    center:SetSize(360, CENTER_LINE_H * CENTER_LINES)
    center:SetFrameStrata("HIGH")
    center:EnableMouse(false)
    center.lines = {}
    for i = 1, CENTER_LINES do
        local line = CreateFrame("Frame", nil, center)
        line:SetSize(360, CENTER_LINE_H)
        line:SetPoint("TOP", center, "TOP", 0, -(i - 1) * CENTER_LINE_H)
        line.icon = line:CreateTexture(nil, "ARTWORK")
        line.icon:SetSize(40, 40)
        -- Icon and text are centred as a pair, so the block's middle is the
        -- text's middle - what the player drags into place.
        line.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        line.text = line:CreateFontString(nil, "OVERLAY")
        line.text:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 28, "OUTLINE")
        -- Text centred (nudged right by half an icon), icon hanging off its
        -- left edge, so the pair stays centred whatever the words' length.
        line.text:SetPoint("CENTER", line, "CENTER", 25, 0)
        line.icon:SetPoint("RIGHT", line.text, "LEFT", -10, 0)
        line.text:SetShadowColor(0, 0, 0, 1)
        line.text:SetShadowOffset(2, -2)
        line:Hide()
        center.lines[i] = line
    end
    -- Backdrop only while the block is being moved, so there is something to
    -- grab and see.
    -- Only the first line is shown while moving, so only it is boxed: the
    -- box's centre is exactly where the call will sit.
    center.grip = center:CreateTexture(nil, "BACKGROUND")
    center.grip:SetAllPoints(center.lines[1])
    center.grip:SetColorTexture(0, 0, 0, 0.5)
    center.grip:Hide()
    center:SetMovable(true)
    center:RegisterForDrag("LeftButton")
    center:SetScript("OnDragStart", function(self)
        if centerUnlocked then self:StartMoving() end
    end)
    center:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Back to offsets from the screen centre, so the saved position
        -- survives resolution and scale changes the way an anchor would.
        local cx, cy = self:GetCenter()
        local ux, uy = UIParent:GetCenter()
        if cx and ux then
            CastAheadDB = CastAheadDB or {}
            -- GetCenter reports in the frame's own scale, UIParent's in its
            -- own, so the block's side is converted before the subtraction.
            local scale = self:GetScale()
            CastAheadDB.centerX = math.floor(cx * scale - ux + 0.5)
            CastAheadDB.centerY = math.floor(cy * scale - uy
                + (self:GetHeight() / 2 - CENTER_LINE_H / 2) * scale - CENTER_Y + 0.5)
            self._x = nil          -- force the anchor to be re-applied
        end
    end)
    center:Hide()
    return center
end

local function PlaceCenter(f)
    local x, y = CenterOffset()
    -- The block is scaled rather than rebuilt at a new size: one setting then
    -- moves the icon, the words and the countdown together, and the spacing
    -- between them stays right at any size.
    local scale = CastAheadConfig.CenterScale()
    if f._x ~= x or f._y ~= y or f._scale ~= scale then
        f._x, f._y, f._scale = x, y, scale
        f:SetScale(scale)
        f:ClearAllPoints()
        -- The saved offsets are screen pixels, while SetPoint measures in the
        -- frame's own scale, so they are divided back out - the block stays
        -- where it was dragged when the size changes.
        f:SetPoint("TOP", UIParent, "CENTER", x / scale, y / scale + CENTER_LINE_H / 2)
    end
end

-- /ca move (or the window's Move button): show the block with a sample
-- line and let it be dragged; call again to lock it in place.
local function ToggleMoveCenter()
    local f = CenterFrame()
    centerUnlocked = not centerUnlocked
    f:EnableMouse(centerUnlocked)
    if centerUnlocked then
        PlaceCenter(f)
        local line = f.lines[1]
        line.icon:SetTexture(136243)
        line.text:SetText("Tank buster  4.0")
        line.text:SetTextColor(1, 0.45, 0.10)
        line:Show()
        for i = 2, CENTER_LINES do f.lines[i]:Hide() end
        f.grip:Show()
        f:Show()
        print("|cff33ff99CastAhead|r drag the call block, then /ca move again to lock it")
    else
        f.grip:Hide()
        f:Hide()
        print("|cff33ff99CastAhead|r call block locked")
    end
end

-- Announceable casts going out right now, soonest-ending first, among live
-- plates and the test drive.
local centerPicks = {}
local function CenterPick(now)
    for i = #centerPicks, 1, -1 do centerPicks[i] = nil end
    for _, state in pairs(plates) do
        local c = state.casting
        if c and c.endAt and c.endAt > now and Announceable(c.candidates) then
            local advice = CastAheadMatch.ConsensusAdvice(c.candidates, state.interruptible)
            if advice then
                centerPicks[#centerPicks + 1] = { endAt = c.endAt, advice = advice, row = c.row }
            else
                -- Disagreement is still a cast going out: show both answers
                -- and let the player pick. Nothing is spoken for these.
                local split = CastAheadMatch.SplitAdvice(c.candidates, state.interruptible)
                if split then
                    centerPicks[#centerPicks + 1] = { endAt = c.endAt, row = c.row,
                        advice = { say = split[1].say .. " or " .. split[2].say,
                                   r = 0.9, g = 0.9, b = 0.9 } }
                end
            end
        end
    end
    if demo then
        for i = 1, #demo.entries do
            local e = demo.entries[i]
            if e.casting and not e.done and e.castEnd > now then
                local advice = CastAheadMatch.Advice(e.row)
                if advice then
                    centerPicks[#centerPicks + 1] = { endAt = e.castEnd, advice = advice, row = e.row }
                end
            end
        end
    end
    table.sort(centerPicks, function(a, b) return a.endAt < b.endAt end)
    return centerPicks
end

-- Lines are hidden one by one as well as the block: a stale line must not
-- flash back when the block reappears with fewer calls than last time.
local function HideCenter()
    if not center then return end
    for i = 1, CENTER_LINES do center.lines[i]:Hide() end
    center:Hide()
end

local function UpdateCenter(now)
    if centerUnlocked then return end     -- being dragged: leave the sample alone
    local picks = CastAheadConfig.Enabled("centerText") and CenterPick(now) or nil
    if not picks or #picks == 0 then
        HideCenter()
        return
    end
    local f = CenterFrame()
    PlaceCenter(f)
    for i = 1, CENTER_LINES do
        local line, pick = f.lines[i], picks[i]
        if pick then
            line.icon:SetTexture(SpellIcon(pick.row.spell))
            -- "Tank buster 4.0": the response in words, not the category code.
            local say = pick.advice.say
            line.text:SetFormattedText("%s  %.1f", say:sub(1, 1):upper() .. say:sub(2), pick.endAt - now)
            line.text:SetTextColor(pick.advice.r, pick.advice.g, pick.advice.b)
            line:Show()
        else
            line:Hide()
        end
    end
    f:Show()
end

frame:SetScript("OnUpdate", function()
    if not dungeon then return end
    local now = GetTime()
    UpdateCenter(now)
    if now >= pollAt then
        pollAt = now + COMBAT_POLL_INTERVAL
        PollCombat()
    end
    for unit, state in pairs(plates) do
        local shown = state.shown
        if shown then
            for i = 1, #shown do
                local entry, bar = shown[i], shown[i].bar
                if bar and bar:IsShown() and not entry.endAt then
                    -- No countdown to run, but it still has to follow its plate
                    -- and disappear with it.
                    AnchorBar(unit, bar, i)
                    -- An overdue prediction is kept so a late cast is still
                    -- recognised, and only dropped once it is clearly never
                    -- coming.
                    local track = entry.track
                    if track and track.due and track.nextAt
                        and now - track.nextAt > STALE_PREDICTION then
                        track.nextAt = nil
                        track.due = nil
                        RefreshBar(unit, state)
                        break
                    end
                elseif bar and bar:IsShown() and entry.endAt then
                    local remaining = entry.endAt - now
                    if remaining <= 0 then
                        if entry.casting then
                            -- Cast outlasted the length the table predicted, so
                            -- let the stop event decide what happens next.
                            bar.time:SetText("")
                        else
                            -- Due, not gone: mark it and repaint once; the
                            -- untimed branch above owns it from here.
                            if entry.track then
                                entry.track.due = true
                            end
                            entry.endAt = nil
                            RefreshBar(unit, state)
                            break
                        end
                    else
                        -- Heads-up shortly before a predicted cast, once each.
                        -- Not for a cast already going out: its own alert
                        -- fired at START, and "soon" is wrong for it anyway.
                        local lead = CastAheadConfig.Lead()
                        if lead > 0 and remaining <= lead and not entry.casting
                            and entry.track and not entry.track.warned then
                            entry.track.warned = true
                            PlayAdviceSound(
                                CastAheadMatch.ConsensusAdvice(entry.candidates), true)
                        end
                        -- Tenths only in the last few seconds, where they
                        -- matter; whole numbers stay readable at a glance.
                        if entry.approximate and remaining < ESTIMATE_NOW then
                            -- Inside the estimate's own error bars. Printing
                            -- "~1" claims a precision this number never had.
                            bar.time:SetText("|cffffd100!|r")
                        elseif entry.approximate then
                            bar.time:SetFormattedText("~%d", remaining + 0.5)
                        elseif remaining < 5 then
                            bar.time:SetFormattedText("%.1f", remaining)
                        else
                            bar.time:SetFormattedText("%d", remaining + 0.5)
                        end
                        AnchorBar(unit, bar, i)
                    end
                end
            end
        end
    end
end)

local persist = CreateFrame("Frame")
persist:RegisterEvent("PLAYER_LOGOUT")
persist:SetScript("OnEvent", function()
    CastAheadDB = CastAheadDB or {}
    diag.dungeonLoaded = dungeon ~= nil
    diag.dungeonSize = dungeon and #dungeon or 0
    local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    diag.instanceID = instanceID
    diag.dataLoaded = CastAheadData ~= nil
    diag.timelineLoaded = CastAheadTimeline ~= nil
    CastAheadDB.diag = diag
end)

for _, event in ipairs({
    "PLAYER_ENTERING_WORLD", "PLAYER_SPECIALIZATION_CHANGED", "SPELLS_CHANGED",
    "ENCOUNTER_START", "ENCOUNTER_END", "CHALLENGE_MODE_START",
    "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "UNIT_HEALTH",
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP",
    "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_INTERRUPTIBLE", "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
    "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_FAILED_QUIET",
}) do
    frame:RegisterEvent(event)
end
if frame.RegisterUnitEvent then
    frame:RegisterUnitEvent("UNIT_AURA", "player")
else
    frame:RegisterEvent("UNIT_AURA")
end

-- Diagnostics ---------------------------------------------------------------

-- /ca debug. Answers the questions that matter when nothing shows up: did
-- the dungeon table load, are plates being tracked, what level did we read, and
-- how far identification got on each one.
CastAheadCore = {}
CastAheadCore.LastCandidates = LastCandidates   -- replay harness only
CastAheadCore.SetTrace = function(fn) narrowTrace = fn end
CastAheadCore.Tuning = tuning
CastAheadCore.Population = function() return killed, exhausted end
CastAheadCore.MoveCenter = ToggleMoveCenter

-- The options window's speaker buttons: hear a category's call on demand.
-- Deliberately ignores the sound/voice mute switches - an explicit click
-- wants to hear it.
function CastAheadCore.PreviewAdvice(advice)
    if not advice then return end
    local said = Voice(advice)
    if not said or CustomSound(advice) then Beep(advice) end
end

-- The sound picker's own preview: just the chosen sound, no voice.
function CastAheadCore.PreviewSound(advice)
    if advice then Beep(advice) end
end

-- Test drive: /ca test (or the window's Test button). Runs a scripted
-- sequence of predicted casts through the real display pipeline - countdown
-- icons, lead warning, voice/sound at "cast", timeline events - without a
-- dungeon, so the configured look and sound can be checked anywhere. Icons
-- hang off a live hostile nameplate when one is around (a training dummy),
-- otherwise off the middle of the screen.
local function StopTest(quiet)
    if not demo then return end
    demo.frame:SetScript("OnUpdate", nil)
    HideCenter()
    for i = 1, #demo.entries do
        local e = demo.entries[i]
        if CastAheadTimeline then CastAheadTimeline.Cancel(e.track) end
        if e.bar then
            e.bar:Hide()
            e.bar:ClearAllPoints()
            e.bar._plate = nil
            barPool[#barPool + 1] = e.bar
        end
    end
    demo = nil
    -- The run also ends on its own, so the window's toggle is repainted here
    -- rather than only where it was clicked.
    if CastAheadUI and CastAheadUI.RefreshTest then CastAheadUI.RefreshTest() end
    if not quiet then print("|cff33ff99CastAhead|r test finished") end
end
CastAheadCore.StopTest = StopTest

-- The window's button is a toggle, so it has to be able to say which half of
-- the toggle it currently is. The test also stops on its own once every
-- sample cast has run out.
function CastAheadCore.Testing()
    return demo ~= nil
end

-- Lay out each plate's own icons against each other, the way a live plate is
-- laid out - otherwise the test drive shows a spacing the game never uses.
-- Run again whenever a call finishes: the survivors have to close up against
-- the plate rather than leave a hole where the finished one was, which is what
-- the live path does on every repaint.
local demoPlates = {}
local function DemoLayout()
    if not demo then return end
    for key in pairs(demoPlates) do demoPlates[key] = nil end
    for i = 1, #demo.entries do
        local e = demo.entries[i]
        if not e.done then
            local key = e.unit or "loose"
            local list = demoPlates[key]
            if not list then
                list = {}
                demoPlates[key] = list
            end
            list[#list + 1] = e.bar
            e.slot = #list
        end
    end
    for _, list in pairs(demoPlates) do
        SpreadBars(list, #list)
    end
    demo.repack = nil
end

local function DemoAnchor(e, i)
    if e.unit and AnchorBar(e.unit, e.bar, e.slot) then return end
    -- No plate (or it went away): park the icon mid-screen instead.
    e.unit = nil
    -- Wide enough for the advice under the icon, and never narrower than the
    -- icon itself, so the row still reads at the largest size.
    local step = math.max(H_STEP, (e.bar._size or ICON_SIZE) + LABEL_GAP)
    if e.bar._plate ~= UIParent or e.bar._demoStep ~= step then
        e.bar._plate = UIParent
        e.bar._demoStep = step
        e.bar:ClearAllPoints()
        e.bar:SetPoint("CENTER", UIParent, "CENTER",
            (i - 1) * step - (#demo.entries - 1) * step / 2, -160)
    end

    e.bar:Show()
end

function CastAheadCore.Test(instanceID)
    if demo then StopTest() return end
    local id = instanceID
    if not (id and CastAheadData[id]) then
        id = select(8, GetInstanceInfo())
        if not (id and CastAheadData[id]) then
            id = nil
            for k in pairs(CastAheadData) do id = math.min(id or k, k) end
        end
    end
    local rows = id and CastAheadData[id]
    if not rows then
        print("|cff33ff99CastAhead|r no dungeon data to test with")
        return
    end
    -- One row per distinct call, the way a pull mixes them; the current
    -- filters apply, so the test previews exactly what a run would show.
    local picked, seen = {}, {}
    for i = 1, #rows do
        local row = rows[i]
        local advice = CastAheadMatch.Advice(row)
        local important = not ImportantOnly() or CastAheadMatch.Important(row)
        if advice and important and #picked < 4 and not seen[advice.label]
            and not (CastAheadUI and CastAheadUI.IsDisabled and CastAheadUI.IsDisabled(row.spell)) then
            seen[advice.label] = true
            picked[#picked + 1] = row
        end
    end
    if #picked == 0 then
        print("|cff33ff99CastAhead|r nothing passes the current filters in " .. (rows.name or id))
        return
    end
    -- Every hostile plate on screen gets icons (training dummies, a pack),
    -- rows dealt round-robin, so the layout can be judged on real plates.
    -- By unit token, not via GetNamePlates(): nameplate addons replace the
    -- frames and the token field goes missing with them.
    local units = {}
    for i = 1, 40 do
        local token = "nameplate" .. i
        if IsHostileNameplate(token) and C_NamePlate.GetNamePlateForUnit(token) then
            units[#units + 1] = token
        end
    end
    demo = { frame = CreateFrame("Frame"), entries = {}, state = { bars = {} } }
    local now = GetTime()
    -- Several calls per plate, always: one icon per plate tells the player
    -- nothing about the spacing between them, which is the thing a test drive
    -- is usually run to judge. But only on the first few plates - the icons
    -- spread across the screen while the timeline stacks every one of them
    -- into a single column, so a room full of training dummies filled it top
    -- to bottom.
    local plates = math.min(#units, DEMO_PLATES)
    local total = math.max(#picked, plates * DEMO_PER_PLATE)
    local slots = {}
    for i = 1, total do
        local row = picked[(i - 1) % #picked + 1]
        local unit = units[(i - 1) % math.max(plates, 1) + 1]
        slots[unit or 0] = (slots[unit or 0] or 0) + 1
        local e = {
            row = row, candidates = { row },
            endAt = now + 2 + i * (CastAheadConfig.Lead() + 2) / math.max(1, math.ceil(total / 4)),
            track = {},
            unit = unit, slot = slots[unit or 0],
        }
        e.bar = GetBar(demo.state, i)
        PaintBar(e.bar, e)
        DemoAnchor(e, i)
        e.bar:Show()
        if CastAheadTimeline then
            CastAheadTimeline.Sync(e.track, e.endAt, row,
                CastAheadMatch.Advice(row), true)
        end
        demo.entries[i] = e
    end
    DemoLayout()
    print(string.format("|cff33ff99CastAhead|r test: %d call(s) from %s on %d plate(s) (again to stop)",
        total, tostring(rows.name or id), plates))
    if CastAheadUI and CastAheadUI.RefreshTest then CastAheadUI.RefreshTest() end
    demo.frame:SetScript("OnUpdate", function()
        if not demo then return end
        local t = GetTime()
        if not dungeon then UpdateCenter(t) end   -- in a dungeon the main ticker does it
        -- A call finished on the previous tick: close the row up before
        -- anything is placed again.
        if demo.repack then DemoLayout() end
        local alive = 0
        for i = 1, #demo.entries do
            local e = demo.entries[i]
            if not e.done then
                alive = alive + 1
                DemoAnchor(e, i)
                if e.casting then
                    if t >= e.castEnd then
                        e.done = true
                        e.bar:Hide()
                        demo.repack = true
                    end
                elseif t >= e.endAt then
                    -- The predicted cast "starts": glow, alert, timeline done.
                    e.casting = true
                    e.castEnd = t + (e.row.cast or 2)
                    PaintBar(e.bar, e)
                    e.bar.time:SetText("")
                    PlayAdviceSound(CastAheadMatch.Advice(e.row))
                    if CastAheadTimeline then CastAheadTimeline.Finish(e.track) end
                else
                    local remaining = e.endAt - t
                    local lead = CastAheadConfig.Lead()
                    if lead > 0 and remaining <= lead and not e.warned then
                        e.warned = true
                        PlayAdviceSound(CastAheadMatch.Advice(e.row), true)
                    end
                    e.bar.time:SetFormattedText(remaining < ESTIMATE_NOW and "%.1f" or "%.0f", remaining)
                end
            end
        end
        if alive == 0 then StopTest() end
    end)
end

-- Probe: which unit facts a hostile nameplate still hands out in 12.x, and
-- which come back Secret. The matcher can only narrow on the readable ones,
-- so this is the list of possible new columns for Traits.lua. Every API is
-- called under pcall and the value classified; a readable sample is kept.
local PROBES = {
    { "UnitHealthMax", function(u) return UnitHealthMax(u) end },
    { "UnitHealth", function(u) return UnitHealth(u) end },
    { "UnitPowerMax", function(u) return UnitPowerMax(u) end },
    { "UnitPowerType", function(u) return UnitPowerType(u) end },
    { "UnitLevel", function(u) return UnitLevel(u) end },
    { "UnitEffectiveLevel", function(u) return UnitEffectiveLevel(u) end },
    { "UnitClassification", function(u) return UnitClassification(u) end },
    { "UnitCreatureType", function(u) return UnitCreatureType(u) end },
    { "UnitCreatureFamily", function(u) return UnitCreatureFamily(u) end },
    { "UnitIsBossMob", function(u) return UnitIsBossMob(u) end },
    { "UnitIsLieutenant", function(u) return UnitIsLieutenant(u) end },
    { "UnitName", function(u) return UnitName(u) end },
    { "UnitGUID", function(u) return UnitGUID(u) end },
    { "UnitSex", function(u) return UnitSex(u) end },
    { "UnitReaction", function(u) return UnitReaction("player", u) end },
    { "UnitThreatSituation", function(u) return UnitThreatSituation("player", u) end },
    { "UnitCastingInfo.name", function(u) return (UnitCastingInfo(u)) end },
    { "UnitCastingInfo.texture", function(u) local _, _, t = UnitCastingInfo(u) return t end },
    { "UnitCastingInfo.spellID", function(u) local _, _, _, _, _, _, _, _, id = UnitCastingInfo(u) return id end },
    { "UnitChannelInfo.name", function(u) return (UnitChannelInfo(u)) end },
    { "GetCreatureFamily(GUID)", function(u)
        local guid = UnitGUID(u)
        return guid and select(6, strsplit("-", guid)) or nil
    end },
}
local probing = false

function Probe(unit)
    if not probing then return end
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.probe = CastAheadDB.probe or {}
    local db = CastAheadDB.probe
    for i = 1, #PROBES do
        local name, fn = PROBES[i][1], PROBES[i][2]
        local row = db[name]
        if not row then row = { secret = 0, readable = 0, empty = 0 } db[name] = row end
        local ok, value = pcall(fn, unit)
        if not ok then
            row.errors = (row.errors or 0) + 1
        elseif value == nil then
            row.empty = row.empty + 1
        elseif IsSecret(value) then
            row.secret = row.secret + 1
        else
            row.readable = row.readable + 1
            if row.sample == nil then row.sample = tostring(value) end
            -- Several distinct readable values means it can tell creatures apart.
            row.values = row.values or {}
            local key = tostring(value)
            if not row.values[key] and (row.distinct or 0) < 12 then
                row.values[key] = true
                row.distinct = (row.distinct or 0) + 1
            end
        end
    end
end

function CastAheadCore.Probing() return probing end

function CastAheadCore.Probe(command)
    if command == "off" then
        probing = false
        print("|cff33ff99CastAhead|r probe off")
        return
    end
    if command == "clear" then
        if CastAheadDB then CastAheadDB.probe = nil end
        print("|cff33ff99CastAhead|r probe results cleared")
        return
    end
    if command == "show" then
        local db = CastAheadDB and CastAheadDB.probe
        if not db then print("|cff33ff99CastAhead|r no probe results yet") return end
        local names = {}
        for name in pairs(db) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local r = db[name]
            print(string.format("|cff33ff99CastAhead|r %-26s readable %3d  secret %3d  nil %3d  distinct %s  e.g. %s",
                name, r.readable, r.secret, r.empty, tostring(r.distinct or 0), tostring(r.sample)))
        end
        return
    end
    probing = true
    print("|cff33ff99CastAhead|r probe on - pull some trash, then /ca probe show")
end

function CastAheadCore.Debug()
    local function say(fmt, ...)
        print("|cff33ff99CastAhead|r " .. string.format(fmt, ...))
    end
    local db = CastAheadDB or {}
    say("output: nameplates=%s timeline=%s | alerts=%s voice=%s",
        db.nameplates == false and "|cffff3333OFF|r" or "on",
        db.timeline == false and "|cffff3333OFF|r" or "on",
        db.sound == false and "OFF" or "on",
        db.voice == false and "OFF" or "on")
    if db.nameplates == false and db.timeline == false then
        say("|cffff3333both outputs are off - nothing will be shown anywhere|r")
    end
    local name, kind, _, _, _, _, _, instanceID = GetInstanceInfo()
    say("zone=%s type=%s instanceID=%s inInstance=%s",
        tostring(name), tostring(kind), tostring(instanceID), tostring(IsInInstance()))
    say("dungeon table: %s (%d spells, %d creature traits)", dungeon and "loaded" or "MISSING",
        dungeon and #dungeon or 0, traitRows and #traitRows or 0)
    if not dungeon and CastAheadData then
        local ids = {}
        for id in pairs(CastAheadData) do ids[#ids + 1] = tostring(id) end
        say("data has instanceIDs: %s", table.concat(ids, ", "))
    end

    local tracked = 0
    for unit, state in pairs(plates) do
        tracked = tracked + 1
        local trackCount, named = 0, {}
        for _, track in pairs(state.tracks) do
            trackCount = trackCount + 1
            if track.candidates and #track.candidates == 1 then
                named[#named + 1] = (track.candidates[1].name or "?") .. (track.channel and " ch" or "")
                    .. (track.nextAt and string.format(" in %.1fs", track.nextAt - GetTime()) or "")
            elseif track.candidates then
                named[#named + 1] = string.format("%d candidates", #track.candidates)
            end
        end
        local who = state.npc and ("npc " .. state.npc)
            or (state.npcSet and (function() local n = 0 for _ in pairs(state.npcSet) do n = n + 1 end return n .. " possible" end)())
            or "unknown"
        say("%s combat=%s level=%s id=%s tracks=%d preview=%s opening=%s %s",
            unit, tostring(state.inCombat), tostring(state.level), who, trackCount,
            state.preview and #state.preview or "-",
            state.opening and "yes" or "-",
            table.concat(named, ", "))
    end
    if tracked == 0 then
        say("no plates tracked - are enemy nameplates enabled, and is this a supported dungeon?")
    end

    -- What is actually drawn right now, and against what. An icon nobody can
    -- account for is the first sign it belongs to another addon.
    local visible = 0
    for unit, state in pairs(plates) do
        for i = 1, #(state.bars or {}) do
            local bar = state.bars[i]
            if bar:IsShown() then
                visible = visible + 1
                local plate = C_NamePlate.GetNamePlateForUnit(unit)
                say("bar %d on %s: plate=%s anchor=%s visible=%s", i, unit,
                    plate and "yes" or "MISSING",
                    bar._anchor and (bar._anchor.GetName and bar._anchor:GetName() or "unnamed") or "none",
                    tostring(bar._anchor and bar._anchor.IsVisible and bar._anchor:IsVisible()))
            end
        end
    end
    say("%d icon(s) drawn by CastAhead. Anything else on screen is another addon.", visible)
    -- Voice chain, both legs tried for real so "the switch does nothing" can
    -- be pinned on the leg that is silent.
    local api = C_CombatAudioAlert
    if api and api.SpeakText and Enum and Enum.CombatAudioAlertCategory then
        local cat = Enum.CombatAudioAlertCategory.TargetCast
        local okV, vol = pcall(api.GetCategoryVolume, cat)
        local okS, id = pcall(api.SpeakText, "cast ahead voice test", cat, true)
        say("game TTS: enabled=%s volume=%s spoke=%s", tostring(api.IsEnabled and api.IsEnabled()),
            okV and tostring(vol) or "?", okS and tostring(id ~= nil) or "error")
    else
        say("game TTS: API missing")
    end
    if PlaySoundFile then
        local okP, willPlay = pcall(PlaySoundFile, SOUND_ROOT .. "en\\TANK.ogg", "Master")
        say("clip TANK.ogg: willPlay=%s (voiceTTS=%s, voice=%s, sound=%s)",
            okP and tostring(willPlay) or "error", tostring(db.voiceTTS), tostring(db.voice), tostring(db.sound))
    else
        say("clip: PlaySoundFile missing")
    end
end

-- Called by the options window when an output toggle changes, so bars and
-- timeline events already on screen follow the new setting instead of
-- lingering until the next cast happens to repaint them.
-- The centre call's size changed in the window: re-anchor it, and let a block
-- that is currently on screen (or being dragged) take the new scale at once.
function CastAheadCore.ResizeCenter()
    if center then PlaceCenter(center) end
end

function CastAheadCore.Reapply()
    local isDisabled = CastAheadUI and CastAheadUI.IsDisabled
    for unit, state in pairs(plates) do
        for key, track in pairs(state.tracks) do
            -- A spell switched off in the window leaves its track right away.
            if track.candidates and isDisabled
                and #CastAheadMatch.NarrowByEnabled(track.candidates, isDisabled) == 0 then
                if CastAheadTimeline then CastAheadTimeline.Cancel(track) end
                state.tracks[key] = nil
            elseif CastAheadTimeline and track.candidates then
                -- Sync both ways: a switched-off timeline or an unimportant
                -- cast is cancelled, a re-enabled one is put back.
                local confident = IsConfident(track)
                CastAheadTimeline.Sync(track, Announceable(track.candidates) and track.nextAt or nil,
                    confident or track.candidates[1],
                    CastAheadMatch.ConsensusAdvice(track.candidates), confident and true or false)
            end
        end
        RefreshBar(unit, state)
    end
    -- The test drive keeps its own bars, outside `plates`. Without this a size
    -- or position change made while it runs is only seen after restarting it,
    -- which is exactly when the player is trying to judge the change.
    if demo then
        for i = 1, #demo.entries do
            local e = demo.entries[i]
            if e.bar then
                ApplyBarSize(e.bar)
                DemoAnchor(e, i)
            end
        end
    end
end

-- /ca hide: drop everything we draw. If an icon survives this, it is not
-- ours - which is worth knowing before hunting for a bug in this addon.
function CastAheadCore.HideAll()
    StopTest(true)
    HideCenter()
    for unit in pairs(plates) do
        DropUnit(unit)
    end
    print("|cff33ff99CastAhead|r all icons cleared - anything still on screen belongs to another addon")
end
