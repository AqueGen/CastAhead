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

local ICON_SIZE = 26
local BAR_GAP = 6        -- distance from the plate's left edge
local LABEL_HEIGHT = 11  -- one line of advice under the icon; two are measured
local BAR_SPACING = 5    -- gap between one row's label and the next icon
local H_STEP = 68        -- fallback sideways step, before any label is measured
local LABEL_GAP = 2      -- clear space between one icon's label and the next
local ICON_GAP = 4       -- ... and the floor, when both labels are short
local DEMO_PER_PLATE = 3 -- calls the test drive puts on each nameplate
local DEMO_PLATES = 4    -- ... and how many nameplates it uses at all
local COMBAT_POLL_BATCH = 8      -- nameplates re-checked per tick
local PREDICTION_MATCH_WINDOW = 4.0  -- how far off a predicted cast may start
local ESTIMATE_NOW = 2.0             -- an estimate this close just reads as "now"
local STALE_PREDICTION = 60.0        -- an overdue cast this old is abandoned
local THIN_EVIDENCE = 5              -- rows backed by less are always estimates
local COMBAT_POLL_INTERVAL = 0.1
local MAX_NAMEPLATES = 40

-- Created up front: the main chunk is at Lua 5.1's 200-local limit, so helpers
-- shared between distant sections hang here instead of taking a local each.
CastAheadCore = {}

-- Declared up front because the bar code above needs them: Lua resolves an
-- undeclared local as a global, which is nil at call time.
local RefreshBar
local GetTrack, NewTrack, SpellTrack
local FinishHeld
local recentCasts
local StartPreview
local RefineByNPC
local ResolvedNPCs, LockedNPCs
local Probe, ProbeCast, ProbeAnchor, ProbeRestore, ProbeCall -- /ca probe, defined next to Debug; the event handler calls them
local Identify
local LockNPC
local diag = { plates = 0, casts = 0, identified = 0, shown = 0, published = 0 }

local function Record(kind, slot, ...)
    local recorder = CastAheadRecorder
    if recorder and recorder.Enabled() then recorder.Note(kind, slot, ...) end
end

local function Ids(rows)
    local ids = {}
    for i = 1, #(rows or {}) do ids[i] = rows[i].spell end
    return ids
end
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
            local spell = rows[i].spell
            rows[i].prio = CastAheadPriority and CastAheadPriority[spell] or nil
            rows[i].dispel = learned and learned[spell] or nil
            rows[i].save = CastAheadMatch.SaveRow(spell)
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
    --  - targetNarrow on: in a Murder Row key the game's answer matched the
    --    log's cast target on every ordinary cast; channels did not, so their
    --    rows only carry `targeted` once the game itself was seen answering.
    --    Replay of our logs: 583 right / 67 wrong without it, 631 / 57 with.
    targetNarrow = true,       -- whether the cast has a target, read at its start, narrows candidates
    observedBelowOnly = true,  -- an observed interval replaces the tabled cooldown only when shorter
    --  - claimWindow 2 and lateClaimMax 4: a start more than 2 s from its
    --    prediction, or more than 4 s overdue, was a wrong call about as
    --    often as a right one. Replays with game-read targets, voiced start
    --    calls right/wrong: public 2129/341 -> 1992/124, own keys 149/19 ->
    --    142/6; completed-cast identification improved slightly.
    --  - claimMargin 1: when two of one creature's predictions with different
    --    calls are almost equally close to the start (their distances to it
    --    differ by under 1 s - Devour and Dreadbellow, both untargeted), the
    --    nearer one used to win. Public replay -13 right / -11 wrong, own
    --    Voidscar keys -0 / -1.
    claimWindow = 2.0,         -- how far from its prediction a start may be claimed by it
    lateClaimMax = 4.0,        -- how long an overdue prediction may still claim a start
    claimMargin = 1.0,         -- a rival with another call almost as close to the start leaves it unclaimed
    firstChannel = true,       -- a plate's first channel is the only channel its creatures have
    history = true,            -- one creature's same-length casts are told apart by each spell's own history
    historyOffset = true,      -- a spell not yet seen on the plate may be placed by its opening order
    historyTolerance = 4.0,    -- how far a spell's first cast may land from its opening order
    deferBusy = true,          -- a prediction that fell inside another cast of the mob moves to that cast's end
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
    -- Not UI_RAID_BOSS_WHISPER_WARNING: DBM mutes that file (876098) with its
    -- boss-emote option, and the STUN row went silent for every DBM user.
    CC = "ALARM_CLOCK_WARNING_1",
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
    ADDS = "RAID_WARNING",
    ALERT = "RAID_WARNING",
    DEFENSIVE = "RAID_WARNING",
    SOON = "ALARM_CLOCK_WARNING_1",
    BURST = "RAID_WARNING",
}

-- Default on: only casts in the curated priority set matter enough for icons,
-- voice and the timeline. Switching it off brings every measured spell back.
local function ImportantOnly()
    return CastAheadConfig.Enabled("importantOnly")
end
CastAheadMatch.ImportantOnly = ImportantOnly

-- What a run shows and calls: "Important casts only" and "My role only"
-- each trim it on their own (Match.Shown).
local function Announceable(candidates, interruptible)
    if not candidates or #candidates == 0 then return not ImportantOnly() end
    return CastAheadMatch.AnyShown(candidates, interruptible)
end

-- UnitIsUnit("focus", plate) answered a plain boolean in live keys; a Secret answer would silence focus kicks.
local function FocusState(unit)
    if not (UnitExists("focus") and UnitCanAttack("player", "focus") and not UnitIsDead("focus")) then
        return "none"
    end
    if not unit then return "other" end
    local same = UnitIsUnit("focus", unit)
    if issecretvalue and issecretvalue(same) then return "secret" end
    return same == true and "this" or "other"
end

local function FocusOnly()
    return CastAheadConfig.Get("kickFocusOnly") == true
end

local function KickVoiceAllowed(unit, advice)
    if not advice or advice.label ~= "KICK" or not FocusOnly() then
        return true
    end
    local focus = FocusState(unit)
    return focus == "none" or focus == "this"
end

-- Only a prediction this solid is worth putting on Blizzard's timeline: one
-- candidate, enough observations behind its time - a measured schedule for a
-- repeat cast, a measured opening for a first cast projected from the mob's
-- kit. Everything softer stays on the nameplate, where an estimate can be
-- shown as one.
local function ConfidentRow(track)
    local candidates = track.candidates
    if track.ambiguous or #candidates ~= 1 then return nil end
    local row = candidates[1]
    if row.filler or row.approx or (row.n or 0) < THIN_EVIDENCE then return nil end
    if track.projected then
        return CastAheadMatch.HasOpening(row) and row or nil
    end
    return CastAheadMatch.HasSchedule(row) and row or nil
end

-- A nil time cancels: unimportant casts stay off the timeline.
local function SyncTimeline(track)
    if not (CastAheadTimeline and track and track.candidates) then return end
    local row = ConfidentRow(track)
    CastAheadTimeline.Sync(track, Announceable(track.candidates) and track.nextAt or nil,
        row or track.candidates[1], CastAheadMatch.ConsensusAdvice(track.candidates), row ~= nil)
end

-- Role filter (default on): the priority set is trimmed to what the current
-- spec can act on. Off, or outside the game, every curated cast counts.
CastAheadMatch.PlayerRole = function()
    if not CastAheadConfig.Enabled("roleFilter") then return nil end
    if not (GetSpecialization and GetSpecializationRole) then return nil end
    local spec = GetSpecialization()
    return spec and GetSpecializationRole(spec) or nil
end

CastAheadMatch.SpecRole = function()
    if not CastAheadConfig.SaveCalls() then return nil end
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

CastAheadMatch.OwnImportant = function(spellID) return CastAheadConfig.SpellImportant(spellID) end

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

local function PlayClip(file, lead)
    if not (PlaySoundFile and file) then return false end
    local lang = CastAheadDB and CastAheadDB.voiceLang or "en"
    local path = SOUND_ROOT .. lang .. "\\" .. file .. (lead and "_soon" or "") .. ".ogg"
    local ok, willPlay = pcall(PlaySoundFile, path, CastAheadConfig.SoundChannel())
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
        -- The game's own alert kits, so the picker has a spread of beeps even
        -- with no sound pack installed. Stored as kit numbers; Beep plays those.
        local GAME_SOUNDS = {
            { "Raid warning", "RAID_WARNING" },
            { "Alarm clock 1", "ALARM_CLOCK_WARNING_1" },
            { "Alarm clock 2", "ALARM_CLOCK_WARNING_2" },
            { "Alarm clock 3", "ALARM_CLOCK_WARNING_3" },
            { "Ready check", "READY_CHECK" },
            { "Raid boss emote", "RAID_BOSS_EMOTE_WARNING" },
            { "GM chat", "GM_CHAT_WARNING" },
            { "LFG role check", "LFG_ROLE_CHECK" },
            { "LFG denied", "LFG_DENIED" },
            { "PvP queue pop", "PVP_THROUGH_QUEUE" },
            { "Power aura", "UI_POWER_AURA_GENERIC" },
            { "Battle.net toast", "UI_BNET_TOAST" },
            { "Auto quest complete", "UI_AUTO_QUEST_COMPLETE" },
            { "Tutorial popup", "TUTORIAL_POPUP" },
        }
        for _, entry in ipairs(GAME_SOUNDS) do
            local kit = SOUNDKIT and SOUNDKIT[entry[2]]
            if kit then lsm:Register("sound", "Game: " .. entry[1], kit) end
        end
    end
end

-- Voice chain: our clip, else the game's combat voice, else a beep. Every
-- caller (in-run alerts, the lead warning, the window's speaker buttons, the
-- test drive) goes through here so they cannot disagree.
local ttsHintShown = false

local function Voice(advice, lead)
    local file, say = advice.file, advice.say
    local text = lead and (say .. " soon") or say
    if CastAheadDB and CastAheadDB.voiceTTS then
        -- The player prefers the game's voice; the clip covers for it when it
        -- cannot speak (alerts disabled in the game options) - and says so
        -- once, or the switch looks like it does nothing.
        if Speak(text) then return true end
        if not ttsHintShown then
            ttsHintShown = true
            print("|cff33ff99CastAhead|r the game's TTS voice could not speak - enable Combat Audio Alerts"
                .. " (Options > Accessibility) and give its categories volume. Playing the clip instead.")
        end
        return PlayClip(file, lead)
    end
    return PlayClip(file, lead) or Speak(text)
end

-- The player's own pick for this spell, else for this category, from
-- LibSharedMedia (every sound any installed addon registered); nil when left
-- on Voice. A spell pick counts only once the cast is that one spell.
local function SpellSound(candidates)
    local picks = CastAheadDB and CastAheadDB.spellSounds
    if not (picks and candidates) then return nil end
    local name
    for _, row in ipairs(candidates) do
        local pick = picks[row.spell]
        if not pick or pick == "" or (name and pick ~= name) then return nil end
        name = pick
    end
    return name
end

local function CustomSound(advice, candidates)
    local name = SpellSound(candidates)
        or CastAheadDB and CastAheadDB.sounds and CastAheadDB.sounds[advice.sound or advice.key]
    if not name or name == "" then return nil end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    return lsm and lsm:Fetch("sound", name, true) or nil
end

-- A file the game can play on its own for a boss event, where the addon is
-- never told the event happened: the player's pick when it is a file, else our clip.
local function AdviceFile(advice)
    if not CastAheadConfig.Enabled("sound") then return nil end
    local custom = CustomSound(advice)
    if type(custom) == "string" then return custom end
    if not (advice.file and CastAheadConfig.Enabled("voice")) then return nil end
    local lang = CastAheadDB and CastAheadDB.voiceLang or "en"
    return SOUND_ROOT .. lang .. "\\" .. advice.file .. ".ogg"
end

local function PlayMedia(sound)
    local channel = CastAheadConfig.SoundChannel()
    if type(sound) == "number" then PlaySound(sound, channel) else PlaySoundFile(sound, channel) end
end

local function Beep(advice)
    if not SOUNDKIT then return end
    local kit = SOUNDKIT[ADVICE_SOUND[advice.sound or advice.key] or ""]
    if kit then PlaySound(kit, CastAheadConfig.SoundChannel()) end
end

-- One alert per call, either the voice or a sound. A sound picked for the
-- spell or its category replaces the voice; on Voice, the line is spoken
-- (`lead` = "tank buster soon" before the cast) and the stock beep stands in
-- only when nothing could speak. `voice` false skips speaking, for the
-- General switch and for previews of just the sound.
local function Alert(advice, lead, candidates, voice)
    local custom = CustomSound(advice, candidates)
    if custom then
        PlayMedia(custom)
        return
    end
    if voice and Voice(advice, lead) then return end
    Beep(advice)
end

local function PlayAdviceSound(advice, lead, candidates)
    if not advice then return end
    if not CastAheadConfig.Enabled("sound") then return end
    if CastAheadConfig.AllMuted(candidates) then return end
    -- The heads-up is a number of seconds now; 0 means the player does not
    -- want it at all.
    if lead and CastAheadConfig.LeadFor(candidates) <= 0 and not CastAheadMatch.IsSave(advice) then return end
    Alert(advice, lead, candidates, CastAheadConfig.Enabled("voice"))
end

local function KickTrace(unit, kind, state, candidates, spell, interruptible, advice)
    if not CastAheadConfig.Dev() then return end
    local isKick = advice and (advice.label == "KICK" or advice.key == "KICK")
    local hasKickRow = false
    for _, row in ipairs(candidates or {}) do
        if row.prio == "KICK" then hasKickRow = true end
    end
    local now = GetTime()
    if not candidates then
        if state.kickTraceAt and now - state.kickTraceAt < 2 then return end
        state.kickTraceAt = now
    elseif not (isKick or hasKickRow) then
        return
    end
    local focus = FocusState(unit)
    local reason
    if not candidates then
        reason = "skip:unclaimed"
    elseif not Announceable(candidates, interruptible) then
        reason = "skip:not-shown"
    elseif not (advice and advice.label == "KICK") then
        reason = "skip:not-kick"
    elseif FocusOnly() and focus == "other" then
        reason = "skip:gate:focus-other"
    elseif FocusOnly() and focus == "secret" then
        reason = "skip:gate:focus-secret"
    elseif not CastAheadConfig.Enabled("sound") or CastAheadConfig.AllMuted(candidates) then
        reason = "skip:sound-off"
    else
        reason = "played"
    end
    print("|cff33ff99CastAhead|r kick voice: " .. unit .. " " .. kind
        .. " claimed=" .. (candidates and tostring(spell) or "-")
        .. " advice=" .. (advice and advice.key or "-")
        .. " focus=" .. focus .. " focusOnly=" .. (FocusOnly() and "on" or "off")
        .. " -> " .. reason)
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
    Record("LOCK", unit, npc, state.npcSource)
    state.npcSet = nil
    RefineByNPC(state, npc, nil)
    if state.inCombat then
        -- The lock may have come from a neighbour's cast, with nothing on this
        -- plate repainting: its tracks just changed, so its icons and timeline
        -- events must follow now, not at its next cast.
        for _, track in pairs(state.tracks) do
            SyncTimeline(track)
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
-- Friz Quadrata draws "~" at cap height (centre 0.68 em, digits 0.35 em) and
-- 0.7 em wide, so it gets its own string: dropped to the digits, pair centred.
local TILDE_DROP, TILDE_HALF = 0.335, 0.35

local function PlaceTime(bar)
    bar.time:SetPoint("CENTER", bar, "CENTER", bar._approx and bar._timeSize * TILDE_HALF or 0, 0)
end

local function SetApprox(bar, on)
    if bar._approx == on then return end
    bar._approx = on
    bar.tilde:SetShown(on)
    PlaceTime(bar)
end

local function SetBarStrata(bar, strata)
    if bar._strata == strata then return end
    bar._strata = strata
    -- Unfix, set, fix again: a fixed strata also ignores our own SetFrameStrata.
    if bar.SetFixedFrameStrata then bar:SetFixedFrameStrata(false) end
    bar:SetFrameStrata(strata)
    if bar.SetFixedFrameStrata then bar:SetFixedFrameStrata(true) end
end

local function ApplyBarSize(bar)
    local size = CastAheadConfig.IconSize()
    local labelScale = CastAheadConfig.LabelScale()
    local timeScale = CastAheadConfig.TimeScale()
    if not bar._preview then SetBarStrata(bar, CastAheadConfig.Strata()) end
    if bar._size == size and bar._labelScale == labelScale
        and bar._timeScale == timeScale then
        return size
    end
    bar._size, bar._labelScale, bar._timeScale = size, labelScale, timeScale
    local scale = size / ICON_SIZE
    bar:SetSize(size, size)
    bar.glow:SetPoint("TOPLEFT", -size * 0.42, size * 0.42)
    bar.glow:SetPoint("BOTTOMRIGHT", size * 0.42, -size * 0.42)
    bar._timeSize = math.max(7, math.floor(14 * scale * timeScale + 0.5))
    bar.time:SetFont(FONT, bar._timeSize, "OUTLINE")
    bar.tilde:SetFont(FONT, bar._timeSize, "OUTLINE")
    bar.tilde:SetPoint("RIGHT", bar.time, "LEFT", 0, -bar._timeSize * TILDE_DROP)
    PlaceTime(bar)
    bar.label:SetFont(FONT, math.max(6, math.floor(10 * scale * labelScale + 0.5)), "OUTLINE")
    return size
end

-- A bar on any parent but UIParent is a settings picture: it takes the
-- window's strata and clipping, and never enters the pool.
function CastAheadCore.NewBar(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetSize(ICON_SIZE, ICON_SIZE)
    bar:EnableMouse(false)
    bar._preview = parent ~= UIParent
    if not bar._preview then
        -- Nameplate addons draw at their own strata; without pinning ours above
        -- them the icon disappears behind the plate it belongs to. The strata
        -- itself is the player's (ApplyBarSize), fixed so no parent moves it.
        if bar.SetFixedFrameStrata then bar:SetFixedFrameStrata(true) end
        bar:SetFrameLevel(6200)
        if bar.SetFixedFrameLevel then bar:SetFixedFrameLevel(true) end
    end

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

    bar.tilde = bar:CreateFontString(nil, "OVERLAY")
    bar.tilde:SetFont(FONT, 14, "OUTLINE")
    bar.tilde:SetShadowColor(0, 0, 0, 1)
    bar.tilde:SetShadowOffset(1, -1)
    bar.tilde:SetTextColor(1, 0.82, 0.4)
    bar.tilde:SetText("~")
    bar.tilde:Hide()

    -- The advice sits under the icon so a long spell name never widens the row.
    bar.label = bar:CreateFontString(nil, "OVERLAY")
    bar.label:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    bar.label:SetPoint("TOP", bar, "BOTTOM", 0, -1)

    bar:Hide()
    ApplyBarSize(bar)
    return bar
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
    local bar = CastAheadCore.NewBar(UIParent)
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
    local fixed = CastAheadConfig.FixedGap()
    for i = 1, count do
        local bar = bars[i]
        local width = bar.label:GetStringWidth() or 0
        if i > 1 and fixed then
            offset = offset + (bar._size or ICON_SIZE) + fixed
        elseif i > 1 then
            offset = offset + math.max((bar._size or ICON_SIZE) + ICON_GAP,
                (previous + width) / 2 + LABEL_GAP)
        end
        bar._hOffset = offset
        previous = width
    end
end

-- Filled by RefreshBar on every repaint, so the spread costs no garbage.
local spread = {}

local function AnchorToFrame(plate, bar, index)
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
end

local function MeasurePlate(plate)
    local w, h, scale = plate:GetWidth(), plate:GetHeight(), plate:GetEffectiveScale()
    if issecretvalue and (issecretvalue(w) or issecretvalue(h) or issecretvalue(scale)) then return end
    local ratio = scale / UIParent:GetEffectiveScale()
    return math.floor(w * ratio * 10 + 0.5) / 10, math.floor(h * ratio * 10 + 0.5) / 10
end

local function RememberPlateSize(plate)
    if not (plate and plate.GetWidth and plate.GetEffectiveScale and UIParent and CastAheadDB) then return end
    local ok, w, h = pcall(MeasurePlate, plate)
    if not (ok and w and w > 0 and h > 0) then return end
    local size = CastAheadDB.plateSize
    if not size or size[1] ~= w or size[2] ~= h then CastAheadDB.plateSize = { w, h } end
end

local function AnchorBar(unit, bar, index)
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    -- The bar is a child of UIParent, not of the plate, so it does not inherit
    -- the plate's visibility: a plate that is gone or hidden would otherwise
    -- leave its icon floating at the last position it had.
    if not plate or (plate.IsShown and not plate:IsShown())
        or (CastAheadSetup and CastAheadSetup.Active()) then
        bar:Hide()
        return false
    end
    AnchorToFrame(plate, bar, index)
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
    kit = CastAheadMatch.OnlyShown(kit)
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
    candidates = CastAheadMatch.OnlyShown(candidates)
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
            local track = SpellTrack(state, sibling) or GetTrack(state, sibling.cast, sibling.channel)
            if track.candidates and not (#track.candidates == 1 and track.candidates[1] == sibling) then
                track = NewTrack(state, sibling.cast, sibling.channel)
            end
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
                    SyncTimeline(track)
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
    local kept = {}
    for i = 1, #rows do
        if CastAheadMatch.AnyShown(rows[i].candidates) then
            kept[#kept + 1] = rows[i]
        end
    end
    rows = kept
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
    if entry.preview or not entry.approximate then SetApprox(bar, false) end
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
    local key = CastAheadRecorder and CastAheadRecorder.Enabled() and CastAheadRecorder.Current()
    if key then
        for _, track in pairs(state.tracks) do
            if track.nextAt ~= track.recordedAt and track.candidates and #track.candidates == 1 then
                track.recordedAt = track.nextAt
                if track.nextAt then
                    Record("PRED", unit, track.candidates[1].spell,
                        math.floor((track.nextAt - key.startedAt) * 1000 + 0.5),
                        (track.projected or track.candidates[1].approx) and 1 or 0,
                        track.projected and "projected" or "repeat")
                end
            end
        end
    end
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

local function SameLength(track, duration, channel)
    local key = channel and (duration + CHANNEL_KEY) or duration
    return (track.channel == true) == (channel == true)
        and math.abs(track.key - key) <= CastAheadMatch.CAST_TOLERANCE
end

function NewTrack(state, duration, channel)
    local key = channel and (duration + CHANNEL_KEY) or duration
    local slot = key
    while state.tracks[slot] do slot = slot + 0.001 end
    local track = { channel = channel or nil, key = key, slot = slot }
    state.tracks[slot] = track
    return track
end

function GetTrack(state, duration, channel)
    local first
    for _, track in pairs(state.tracks) do
        if SameLength(track, duration, channel) and (not first or track.slot < first.slot) then
            first = track
        end
    end
    return first or NewTrack(state, duration, channel)
end

function SpellTrack(state, row, except)
    for _, track in pairs(state.tracks) do
        if track ~= except and track.candidates and #track.candidates == 1 and track.candidates[1] == row then
            return track
        end
    end
end

-- The latest real cast start of this length on the plate. A projected track is
-- not a cast: when one wins PickTrack, an ambiguous track may still hold the
-- plate's previous cast, and without it a repeat cast is judged as an opener.
local function LastRealStart(state, duration, channel)
    local last
    for _, track in pairs(state.tracks) do
        if not track.projected and track.lastStartAt and SameLength(track, duration, channel)
            and (not last or track.lastStartAt > last) then
            last = track.lastStartAt
        end
    end
    return last
end

-- One creature's same-length casts share a track, which mixes their intervals,
-- and the engage window is too loose to split them (Corrosive Essence / Rip and
-- Slice). Here each candidate is judged by its own history on this plate: its
-- cooldown since its own last cast, or, unseen yet, its firm opening order from
-- the mob's first cast. Nil when that decides nothing, so the interval and
-- opening checks still get their turn. One creature only: an offset counts from
-- that creature's own first cast, so across creatures every offset-0 row would
-- claim any plate's first cast.
local function NarrowByHistory(state, candidates, startAt)
    for i = 2, #candidates do
        if candidates[i].npc ~= candidates[1].npc then return nil end
    end
    -- Each candidate is "fits", "out" (sooner than it ever comes back), "unsure"
    -- (its own history here says neither) or unseen (no history, no firm offset).
    local fitting, open, unsure = {}, {}, false
    for i = 1, #candidates do
        local row = candidates[i]
        local own = SpellTrack(state, row)
        local verdict
        if own and not own.projected and own.lastStartAt and not own.sure then
            -- A history built on a guess only passes the guess on: a Call Lightning
            -- taken for Accumulate Charge once made the next real one "too soon".
            verdict = "unsure"
        elseif own and not own.projected and own.lastStartAt then
            local gap = startAt - own.lastStartAt
            if CastAheadMatch.SlotForInterval(row, gap, own.index) then
                verdict = "fits"
            elseif row.cdMin and gap < row.cdMin - CastAheadMatch.CD_TOLERANCE_FLAT and not own.kicked then
                -- cdMin is measured across completed casts only; a kicked one may come back sooner.
                verdict = "out"
            else
                verdict = "unsure"
            end
        elseif tuning.historyOffset and (state.actedAt or state.firstCastAt) and row.offset and row.offsetFirm
            and math.abs(startAt - (state.actedAt or state.firstCastAt) - row.offset) <= tuning.historyTolerance then
            verdict = "fits"
        end
        if verdict == "fits" then fitting[#fitting + 1] = row end
        if verdict ~= "out" then open[#open + 1] = row end
        if verdict == "unsure" then unsure = true end
    end
    -- One left standing, or one that fits against rivals that are out or unseen. A
    -- rival with history it cannot place blocks the call: Accumulate Charge 7.3s
    -- after itself is neither on schedule nor too soon, while Call Lightning 12.1s
    -- after itself happens to fit, and choosing it was wrong.
    if #open == 1 and #open < #candidates then return open end
    if #fitting == 1 and not unsure then return fitting end
    return nil
end

local function PickTrack(state, duration, channel, claimed, startAt)
    if claimed and state.tracks[claimed.slot] == claimed and SameLength(claimed, duration, channel) then
        return claimed
    end
    local best, bestDelta
    for _, track in pairs(state.tracks) do
        if SameLength(track, duration, channel) and track.nextAt then
            local delta = math.abs(startAt - track.nextAt)
            if not best or delta < bestDelta or (delta == bestDelta and track.slot < best.slot) then
                best, bestDelta = track, delta
            end
        end
    end
    return best or GetTrack(state, duration, channel)
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
    Record("STEP", unit, step, Ids(candidates))
end

-- Between ENCOUNTER_START and ENCOUNTER_END nothing is tracked: the data is
-- about trash, and a boss add whose cast happens to last as long as some
-- trash spell would otherwise wear that spell's schedule.
local inEncounter = false

local function DropUnit(unit, reason)
    local state = plates[unit]
    if state then
        Record("PLATE", unit, "removed", reason or "gone")
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
        local dead = UnitIsDead(unit)
        if dead then NoteDeath(state) end
        DropUnit(unit, dead and "died" or "gone")
        return
    end
    local inCombat = UnitAffectingCombat(unit)
    if inCombat and not state.inCombat then
        state.engagedAt = GetTime()
        Record("ENGAGE", unit)
        state.level = state.level or SafeLevel(unit)
        StartOpening(unit, state)
    elseif not inCombat and state.inCombat then
        -- Out of combat the mob resets its rotation, so nothing learned about
        -- it still holds - including a cast that was in flight when it evaded.
        ClearTimeline(state)
        wipe(state.tracks)
        state.engagedAt = nil
        state.actedAt = nil
        state.firstCastAt = nil
        state.castStartAt = nil
        state.casting = nil
        state.held = nil
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

local function SpellTargeted(unit)
    if not UnitShouldDisplaySpellTargetName then return nil end
    local ok, value = pcall(UnitShouldDisplaySpellTargetName, unit)
    if ok and type(value) == "boolean" and not (issecretvalue and issecretvalue(value)) then
        return value
    end
end

local function OnlyChannel(state)
    local npcs = state.npc and { [state.npc] = true } or state.npcSet
    if not npcs then return nil end
    local isDisabled = CastAheadUI and CastAheadUI.IsDisabled
    local only
    for npc in pairs(npcs) do
        for _, row in ipairs(byNPC[npc] or {}) do
            if row.channel and not (isDisabled and isDisabled(row.spell)) then
                if only then return nil end
                only = row
            end
        end
    end
    if not only then return nil end
    for _, trait in ipairs(traitRows or {}) do
        if npcs[trait.npc] and trait.npc ~= only.npc and trait.channels and #trait.channels > 0 then
            return nil
        end
    end
    return only
end

local function OnCastStart(unit, channel)
    -- Out-of-combat casts (patrol flavour channels) tell us nothing about a
    -- pull's rotation, so they are ignored - the poll may be up to a tick
    -- stale, so ask the unit directly rather than trusting cached state.
    if not UnitAffectingCombat(unit) or not IsHostileNameplate(unit) then return end
    local state = GetState(unit)
    if not state.inCombat then
        state.inCombat = true
        if not state.engagedAt then
            state.engagedAt = GetTime()
            Record("ENGAGE", unit)
        end
    end
    local now = GetTime()
    if channel and state.castStartAt and not state.channelling then
        state.held = { startAt = state.castStartAt, duration = now - state.castStartAt,
            claimed = state.casting and state.casting.track, target = state.spellTarget }
    elseif state.held then
        FinishHeld(unit, state)
    end
    state.castStartAt = now
    state.firstCastAt = state.firstCastAt or now
    state.channelling = channel or nil
    state.interrupted = false
    state.interruptible = nil
    state.casting = nil
    state.opening = nil
    state.spellTarget = SpellTargeted(unit)

    -- Which spell is this? The one we predicted for about now. Cast length is
    -- Secret, so the bar's length comes from the table instead.
    local best, bestDelta
    local eligible = {}
    local identified, identifiedCount = nil, 0
    for _, track in pairs(state.tracks) do
        -- Only tracks of the kind that just started may claim it. A channel
        -- landing where a cast was predicted is not that cast: taking it
        -- finished the cast's timeline event early, drew its bar, voiced its
        -- call, and handed its track to the interrupt path afterwards.
        if track.candidates and (track.channel == true) == (channel == true)
            and not (tuning.targetNarrow and CastAheadMatch.TargetRulesOut(track.candidates, state.spellTarget)) then
            identified, identifiedCount = track, identifiedCount + 1
            if track.nextAt then
                local delta = math.abs(now - track.nextAt)
                -- Inside the window, or overdue and still waiting: the "!"
                -- icon is kept precisely so a late cast is recognised.
                local late = track.due and now >= track.nextAt
                    and (not tuning.lateClaimMax or now - track.nextAt <= tuning.lateClaimMax)
                if delta <= tuning.claimWindow or late then
                    eligible[#eligible + 1] = { track = track, delta = delta }
                    if not bestDelta or delta < bestDelta or (delta == bestDelta and track.slot < best.slot) then
                        best, bestDelta = track, delta
                    end
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
    if not best and identifiedCount == 1 and not identified.nextAt and not identified.firstChannel then
        best = identified
    end
    if not best and channel and tuning.firstChannel and not state.channelSeen and identifiedCount == 0 then
        local row = OnlyChannel(state)
        if row then
            best = NewTrack(state, row.cast, true)
            best.candidates = { row }
            best.ambiguous = false
            best.firstChannel = true
        end
    end
    if channel then state.channelSeen = true end
    if best and tuning.claimMargin then
        local call = CastAheadMatch.ConsensusAdvice(best.candidates)
        for _, rival in ipairs(eligible) do
            if rival.track ~= best and rival.delta - bestDelta < tuning.claimMargin
                and CastAheadMatch.ConsensusAdvice(rival.track.candidates) ~= call then
                best = nil
                break
            end
        end
    end
    if best then
        if CastAheadTimeline then CastAheadTimeline.Finish(best) end
        local candidates = best.candidates
        if tuning.targetNarrow then
            candidates = CastAheadMatch.NarrowByTarget(candidates, state.spellTarget)
        end
        state.casting = {
            casting = true,
            track = best,
            row = CastAheadMatch.BestGuess(candidates),
            candidates = candidates,
            ambiguous = best.ambiguous and (not tuning.targetNarrow or #candidates > 1) or nil,
            startAt = now,
            endAt = now + CastAheadMatch.BestGuess(candidates).cast,
        }
    end
    if CastAheadConfig.Dev() then
        local c = state.casting
        KickTrace(unit, channel and "chan" or "cast", state, c and c.candidates, c and c.row.spell,
            state.interruptible, c and CastAheadMatch.ConsensusAdvice(c.candidates, state.interruptible))
    end
    -- Sound fires once, on the cast that needs answering - not on the timer
    -- that led up to it.
    if state.casting and Announceable(state.casting.candidates, state.interruptible) then
        local advice = CastAheadMatch.ConsensusAdvice(state.casting.candidates, state.interruptible)
        if KickVoiceAllowed(unit, advice) then
            PlayAdviceSound(advice, nil, state.casting.candidates)
        end
    end
    -- Repaint either way: an unrecognised cast must not leave the previous
    -- countdown on screen as if nothing were happening.
    RefreshBar(unit, state)
end

-- Only tracks of the kind that was in flight may be the fallback: a kicked
-- channel that matched nothing has no business advancing a cast track's
-- rotation just because it happens to be the plate's only one.
local function ExpectedTrack(state, startAt)
    local channel = state.channelling == true
    local count, only = 0, nil
    for _, track in pairs(state.tracks) do
        if (track.channel == true) == channel then
            count = count + 1
            only = track
        end
    end
    if count == 1 and only.nextAt and math.abs(startAt - only.nextAt) <= PREDICTION_MATCH_WINDOW then
        return only
    end
    return nil
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
    local only = matched or ExpectedTrack(state, startAt)
    if only and only.candidates and #only.candidates == 1
        and CastAheadMatch.HasSchedule(only.candidates[1]) then
        only.index = (only.index or 0) + 1
        only.lastStartAt = startAt
        only.kicked = true
        only.due = nil
        only.warned = nil        -- the next prediction earns its own heads-up
        only.projected = nil     -- anchored on a real cast start from here on
        local cd = only.observedCD or CastAheadMatch.CDAt(only.candidates[1], only.index)
        only.nextAt = cd and (startAt + cd) or nil
        SyncTimeline(only)
        RefreshBar(unit, state)
        return only
    end
    RefreshBar(unit, state)
end

-- A cast that finished on its own: its measured length is the identifying
-- fact, and so is the length of the channel it turned into (`follow`). Returns
-- whether that channel was one of the candidates' own.
local function FinishCast(unit, state, startAt, duration, channel, follow, claimed, target)
    diag.casts = diag.casts + 1
    local sole = channel and CastAheadMatch.SoleChannel(dungeon, duration)
    if sole then duration = sole.cast end
    local picked = PickTrack(state, duration, channel, claimed, startAt)
    local track = picked
    local candidates = track.candidates
    -- A projected sibling's lastStartAt is the anchor it was laid out from, not
    -- a cast of its own, so nothing below may read it as an interval - doing so
    -- adopted an engage-to-first-cast delay as the spell's cooldown.
    local previousCast = (not track.projected) and track.lastStartAt or nil
    local lastSeen = previousCast or (track.projected and LastRealStart(state, duration, channel)) or nil
    -- A spell the player switched off mid-pull may still sit on a track from
    -- before; it is re-identified like anything else, and drops out there.
    if candidates and #candidates == 1 and CastAheadUI and CastAheadUI.IsDisabled
        and CastAheadUI.IsDisabled(candidates[1].spell) then
        candidates = nil
    end
    local rejected, resetPicked, adapted, disproved
    -- A gap since a kicked cast says nothing about the schedule: the mob may recast it sooner.
    if candidates and #candidates == 1 and previousCast and not track.kicked
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
            if #candidates[1].cd == 1 then
                adapted = { (not tuning.observedBelowOnly or measured < tabled) and measured or nil }
            end
        else
            -- Nowhere near this spell's schedule: it was never this spell, and
            -- the re-identification below must not hand it straight back.
            rejected = candidates[1]
            candidates = nil
            resetPicked = true
        end
    end
    if follow ~= nil and candidates and #candidates == 1 then
        local pool = CastAheadMatch.NarrowByFollow(CastAheadMatch.NarrowByLevel(
            CastAheadMatch.ByCastTime(dungeon, duration, channel), state.level), follow)
        local kept = false
        for i = 1, #pool do
            if pool[i] == candidates[1] then kept = true end
        end
        if not kept then candidates = nil end
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
        if tuning.targetNarrow then
            candidates = CastAheadMatch.NarrowByTarget(candidates, target)
            Trace(unit, "target", candidates)
        end
        candidates = CastAheadMatch.NarrowByMob(candidates, KnownNPCs(state, track))
        Trace(unit, "mob", candidates)
        if type(follow) == "number" and state.npc then
            local fits = false
            for i = 1, #candidates do
                if CastAheadMatch.FollowFits(candidates[i], follow) then fits = true end
            end
            if not fits then
                local pool = CastAheadMatch.NarrowByLevel(CastAheadMatch.NarrowByEnabled(
                    CastAheadMatch.ByCastTime(dungeon, duration, channel), CastAheadUI and CastAheadUI.IsDisabled),
                    state.level)
                if tuning.targetNarrow then pool = CastAheadMatch.NarrowByTarget(pool, target) end
                local exact = {}
                for i = 1, #pool do
                    if pool[i] ~= rejected and CastAheadMatch.FollowExact(pool[i], follow) then
                        exact[#exact + 1] = pool[i]
                    end
                end
                pool = exact
                if pool[1] then
                    local wrong = state.npc
                    state.npc, state.npcSource, state.npcSet = nil, nil, nil
                    for slot, other in pairs(state.tracks) do
                        if other.candidates and #other.candidates == 1 and other.candidates[1].npc == wrong then
                            if other == track then
                                disproved = true
                            else
                                if CastAheadTimeline then CastAheadTimeline.Cancel(other) end
                                state.tracks[slot] = nil
                            end
                        end
                    end
                    candidates = pool
                    Trace(unit, "unlock", candidates)
                end
            end
        end
        if follow ~= nil then
            candidates = CastAheadMatch.NarrowByFollow(candidates, follow)
            Trace(unit, "follow", candidates)
        end
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
        local byHistory = tuning.history and #candidates > 1 and NarrowByHistory(state, candidates, startAt)
        if byHistory then
            candidates = byHistory
            Trace(unit, "history", candidates)
        elseif lastSeen then
            candidates = CastAheadMatch.NarrowByInterval(candidates, startAt - lastSeen)
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
        candidates = CastAheadMatch.NarrowByFollow(candidates, follow)
        if lastSeen then
            candidates = CastAheadMatch.NarrowByInterval(candidates, startAt - lastSeen)
        elseif state.engagedAt then
            candidates = CastAheadMatch.NarrowByFirst(candidates, startAt - state.engagedAt)
        end
    end
    lastIdentified[unit] = candidates
    if #candidates == 0 then
        -- The track goes, so its timeline event must go with it, or the id is
        -- lost and the icon lingers on Blizzard's timeline.
        if CastAheadTimeline then CastAheadTimeline.Cancel(track) end
        state.tracks[track.slot] = nil
        RefreshBar(unit, state)
        return false
    end

    if #candidates == 1 then
        local own = SpellTrack(state, candidates[1], track)
        local foreign = not disproved and track.candidates and #track.candidates == 1
            and track.candidates[1] ~= candidates[1]
        if own then
            if not foreign then
                if CastAheadTimeline then CastAheadTimeline.Cancel(track) end
                state.tracks[track.slot] = nil
            end
            track = own
        elseif foreign then
            track = NewTrack(state, duration, channel)
        end
        if track ~= picked then
            previousCast = (not track.projected) and track.lastStartAt or nil
        end
    end
    if disproved and track == picked then
        previousCast, adapted, resetPicked = nil, nil, nil
        track.index, track.observedCD = nil, nil
    end
    if resetPicked and track == picked then
        track.observedCD = nil
        track.index = nil
    end
    if adapted and track == picked then track.observedCD = adapted[1] end

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
                and #candidates[1].cd == 1
                and (not tuning.observedBelowOnly or measured < candidates[1].cd[1])) and measured or nil
        end
    end

    diag.identified = diag.identified + (#candidates == 1 and 1 or 0)
    diag.candidates = #candidates
    track.candidates = candidates
    track.lastStartAt = startAt
    track.kicked = nil
    track.measured = true
    track.firstChannel = nil
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
        local unique = CastAheadMatch.NarrowByFollow(CastAheadMatch.NarrowByLevel(
            CastAheadMatch.ByCastTime(dungeon, duration, channel), state.level), follow)
        track.sure = (#unique == 1 and unique[1] == candidates[1]) or slotMatched
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
    SyncTimeline(track)
    RefreshBar(unit, state)
    if type(follow) ~= "number" then return false end
    for i = 1, #candidates do
        if CastAheadMatch.FollowFits(candidates[i], follow) then return true end
    end
    return false
end

-- A mob casts one thing at a time: whatever was due while it was busy comes
-- right after. Devouring Brutalizer's Brutalize lands the moment its 9s Devour
-- ends, seconds past its own schedule. Only behind a cast we know and that is
-- not a filler: a mob chaining an unknown filler (Felfire Burst) starts the next
-- one right where the moved prediction lands, and that start got claimed.
local function DeferBusy(state, startAt, endAt, busy)
    if not tuning.deferBusy or not busy or #busy ~= 1 or busy[1].filler then return false end
    local moved = false
    for _, track in pairs(state.tracks) do
        if track.nextAt and track.nextAt > startAt and track.nextAt < endAt then
            track.nextAt = endAt
            track.due = nil
            SyncTimeline(track)
            moved = true
        end
    end
    return moved
end

function FinishHeld(unit, state)
    local held = state.held
    if not held then return end
    state.held = nil
    FinishCast(unit, state, held.startAt, held.duration, false, nil, held.claimed, held.target)
end

local function OnCastStop(unit, channel)
    local state = plates[unit]
    if not state or not state.castStartAt then return end
    -- A STOP of the other kind is not ours: a channel that follows a cast on
    -- the same creature raises CHANNEL_START first, which holds the cast.
    if (state.channelling == true) ~= (channel == true) then return end
    local startAt = state.castStartAt
    local claimed = state.casting and state.casting.track
    state.castStartAt = nil
    state.casting = nil
    local duration = GetTime() - startAt
    state.lastMeasured = duration
    local held = state.held
    state.held = nil
    local heldIdentified
    if held and channel then
        if FinishCast(unit, state, held.startAt, held.duration, false, duration, held.claimed, held.target) then
            -- The cast and the channel it turned into kept the mob busy as one.
            DeferBusy(state, held.startAt, GetTime(), lastIdentified[unit])
            RefreshBar(unit, state)
            return
        end
        heldIdentified = lastIdentified[unit]
    end
    local follow
    if not channel then follow = false end
    FinishCast(unit, state, startAt, duration, channel, follow, claimed, state.spellTarget)
    if heldIdentified and #lastIdentified[unit] == 0 then lastIdentified[unit] = heldIdentified end
    if DeferBusy(state, held and held.startAt or startAt, GetTime(), lastIdentified[unit]) then
        RefreshBar(unit, state)
    end
end

-- INTERRUPTED and FAILED are terminal: Blizzard's own cast bar clears on them
-- and never waits for a STOP, so the cast has to be finished off here rather
-- than parked in a flag that a later STOP may or may not come to read.
local function OnCastInterrupted(unit)
    local state = plates[unit]
    if not state or not state.castStartAt then return end
    FinishHeld(unit, state)
    local startAt = state.castStartAt
    local matched = state.casting and state.casting.track or nil
    state.interrupted = true
    if state.channelling and not matched and not ExpectedTrack(state, startAt)
        and CastAheadMatch.SoleChannel(dungeon, GetTime() - startAt) then
        OnCastStop(unit, true)
        return
    end
    state.castStartAt = nil
    state.casting = nil
    Record("CUT", unit, math.floor((GetTime() - startAt) * 1000 + 0.5))
    local resolved = ResolveInterrupted(unit, state, startAt, matched) or matched
    if DeferBusy(state, startAt, GetTime(), resolved and resolved.candidates) then
        RefreshBar(unit, state)
    end
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
local function RecordStart(unit, channel)
    local state = plates[unit]
    if not (state and state.castStartAt == GetTime()) then return end
    local casting = state and state.casting
    local advice = casting and Announceable(casting.candidates, state.interruptible)
        and CastAheadMatch.ConsensusAdvice(casting.candidates, state.interruptible)
    local target = state and state.spellTarget
    Record("START", unit, channel and 1 or 0, casting and casting.row and casting.row.spell or "-",
        advice and advice.key or "-", Ids(casting and casting.candidates),
        target == true and 1 or target == false and 0 or "?")
end

local function StopCast(unit, channel)
    local state = plates[unit]
    local open = state and state.castStartAt
    local casting = state and state.casting
    OnCastStop(unit, channel)
    state = plates[unit]
    if open and state and not state.castStartAt and state.lastMeasured then
        local final = lastIdentified[unit]
        local advice = final and Announceable(final) and CastAheadMatch.ConsensusAdvice(final)
        Record("STOP", unit, channel and 1 or 0, math.floor(state.lastMeasured * 1000 + 0.5),
            Ids(final), advice and advice.key or "-")
    end
end

local NOTICE_DELAY = 2
local noticePending

frame:SetScript("OnEvent", function(_, event, unit, arg2, arg3, arg4)
    if unit == "player" and (event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_START") then
        ProbeAnchor(arg3)
        if event == "UNIT_SPELLCAST_SUCCEEDED" and not IsSecret(arg3) then Record("SELF", nil, arg3) end
        if event == "UNIT_SPELLCAST_SUCCEEDED" then return end
    end
    if event == "UNIT_AURA" then
        if unit == "player" then LearnDispel() end
        return
    end
    if event == "PLAYER_SPECIALIZATION_CHANGED" or event == "SPELLS_CHANGED" then
        -- A new spec or talent loadout can change both the role and which
        -- dispels the character knows.
        if event == "SPELLS_CHANGED" or unit == "player" then
            InvalidateCapabilities()
            if CastAheadCore then CastAheadCore.ForgetSamples() end
            if CastAheadSaves and event == "PLAYER_SPECIALIZATION_CHANGED" then CastAheadSaves.SetViewSpec(nil) end
            if CastAheadSaves then CastAheadSaves.Refresh() end
            if CastAheadOptions and CastAheadOptions.RefreshDefensives then CastAheadOptions.RefreshDefensives() end
            if CastAheadUI and CastAheadUI.RefreshSaves then CastAheadUI.RefreshSaves() end
            if CastAheadCore then CastAheadCore.Reapply() end
            local window = CastAheadWindow and CastAheadWindow.Frame and CastAheadWindow.Frame()
            if CastAheadOptions and window and window:IsShown() then CastAheadOptions.Refresh() end
        end
        return
    end
    if event == "PLAYER_DIFFICULTY_CHANGED" then
        if CastAheadSaves then CastAheadSaves.Refresh() end
        return
    end
    if event == "PLAYER_REGEN_ENABLED" or event == "CHALLENGE_MODE_COMPLETED" or event == "ENCOUNTER_END" then
        if CastAheadSaves and CastAheadSaves.AuraPending() then CastAheadSaves.Refresh() end
    end
    if CastAheadSaves and (event == "BAG_UPDATE_DELAYED" or event == "PLAYER_ENTERING_WORLD"
        or (event == "PLAYER_REGEN_ENABLED" and CastAheadSaves.BagsPending())) then
        CastAheadSaves.ScanBags()
        if CastAheadOptions and CastAheadOptions.RefreshDefensives then CastAheadOptions.RefreshDefensives() end
    end
    if event == "ADDON_LOADED" then
        if unit == "CastAhead" then
            CastAheadConfig.Migrate()
        end
        return
    end
    if event == "PLAYER_LOGIN" then
        if CastAheadBossAdapter then CastAheadBossAdapter.Connect() end
        if CastAheadDB and CastAheadDB.saveCallsNotice then
            print("|cff33ff99CastAhead:|r defensive calls are now off by default. Turn them on in /ca - Features.")
            CastAheadDB.saveCallsNotice = nil
            noticePending = true
        elseif not noticePending then
            -- What's new: once per message, never on a new install, and
            -- never over another notice still waiting to be shown.
            local news = CastAheadWindow and CastAheadWindow.NEWS
            if news and CastAheadDB then
                if not CastAheadConfig.newInstall and (tonumber(CastAheadDB.newsSeen) or 0) < news.id then
                    noticePending = news
                end
                CastAheadDB.newsSeen = news.id
            end
        end
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        if noticePending then
            local message = noticePending ~= true and noticePending or nil
            noticePending = nil
            local function Show()
                if CastAheadUI and CastAheadUI.ShowUpdateNotice then CastAheadUI.ShowUpdateNotice(message) end
            end
            -- Shown straight at login the notice was gone by the time the world appeared.
            if C_Timer then C_Timer.After(NOTICE_DELAY, Show) else Show() end
        end
        ProbeRestore()
        if CastAheadRecorder then
            CastAheadRecorder.Restore()
            if CastAheadRecorder.Enabled() and IsInInstance() then CastAheadRecorder.EnsureKey() end
        end
        if CastAheadReport then CastAheadReport.Refresh() end
        if CastAheadSaves then CastAheadSaves.Refresh() end
        CastAheadCore.SyncCombatLog()
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
        if CastAheadRecorder and CastAheadRecorder.Enabled() then
            local name, _, _, _, _, _, _, instance = GetInstanceInfo()
            local level, affixes = 0, ""
            if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
                local ok, lvl, list = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
                if ok and type(lvl) == "number" then level = lvl end
                if ok and type(list) == "table" then affixes = table.concat(list, ",") end
            end
            local role = "NONE"
            if GetSpecialization and GetSpecializationRole then
                local spec = GetSpecialization()
                role = spec and GetSpecializationRole(spec) or "NONE"
            end
            CastAheadRecorder.StartKey({ instance = instance, name = name, level = level,
                affixes = affixes, role = role })
            for tracked, state in pairs(plates) do
                local traits = ReadTraits(tracked)
                Record("PLATE", tracked, "added", type(state.level) == "number" and state.level or "?",
                    traits.power or "?", traits.classification or "?")
                if state.engagedAt then Record("ENGAGE", tracked) end
            end
        end
        return
    end
    if event == "CHALLENGE_MODE_COMPLETED" then
        if CastAheadRecorder then CastAheadRecorder.EndKey("completed") end
        return
    end
    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        if event == "PLAYER_REGEN_DISABLED" and CastAheadRecorder and CastAheadRecorder.Enabled() then
            CastAheadRecorder.EnsureKey()
        end
        Record("PULL", nil, event == "PLAYER_REGEN_DISABLED" and "in" or "out")
        if event == "PLAYER_REGEN_ENABLED" and CastAheadRecorder and not IsInInstance() then
            CastAheadRecorder.EndKey("left")
        end
        if CastAheadReport then CastAheadReport.Refresh() end
        return
    end
    if event == "ENCOUNTER_START" or event == "ENCOUNTER_END" then
        inEncounter = event == "ENCOUNTER_START"
        if CastAheadBossAdapter then CastAheadBossAdapter.OnEncounter(event) end
        if CastAheadBurst then CastAheadBurst.OnEncounter(event, unit, arg3, GetTime()) end
        if inEncounter then
            -- Everything on screen belongs to the pull that just ended; the
            -- centre call clears itself once no plate is casting.
            for tracked in pairs(plates) do DropUnit(tracked) end
        end
        return
    end
    if event == "NAME_PLATE_UNIT_ADDED" and type(unit) == "string" and IsHostileNameplate(unit) then
        RememberPlateSize(C_NamePlate.GetNamePlateForUnit(unit))
    end
    if event == "NAME_PLATE_UNIT_REMOVED" then
        DropUnit(unit, "gone")
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
            state.held = nil
            state.castStartAt = nil
            state.casting = nil
            state.channelling = nil
            state.inCombat = nil
            state.engagedAt = nil
            state.actedAt = nil
            state.firstCastAt = nil
            HideBar(state)
            state.level = SafeLevel(unit)
            local traits = ReadTraits(unit)
            Record("PLATE", unit, "added", type(state.level) == "number" and state.level or "?",
                traits.power or "?", traits.classification or "?")
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
            DropUnit(unit, "died")
        end
    elseif event == "UNIT_SPELLCAST_START" then
        Probe(unit)
        local probed = ProbeCast(unit, false)
        OnCastStart(unit, false)
        ProbeCall(probed, unit)
        RecordStart(unit, false)
    elseif event == "UNIT_SPELLCAST_STOP" then
        StopCast(unit, false)
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        local probed = ProbeCast(unit, true)
        OnCastStart(unit, true)
        ProbeCall(probed, unit)
        RecordStart(unit, true)
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
            StopCast(unit, true)
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
                if advice and advice.label == "KICK" and advice ~= before then
                    KickTrace(unit, "late", state, state.casting.candidates, state.casting.row.spell,
                        state.interruptible, advice)
                end
                if advice and advice.label == "KICK" and advice ~= before
                    and Announceable(state.casting.candidates, state.interruptible)
                    and KickVoiceAllowed(unit, advice) then
                    PlayAdviceSound(advice, nil, state.casting.candidates)
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
-- nobody. Off only when `CastAheadDB.centerText = false`; `centerY` shifts it.
local CENTER_Y = -120
local center
local centerUnlocked = false   -- /ca move: the block is being dragged
local centerSample = false
local demo          -- the test drive's state, defined with CastAheadCore.Test

-- Where the block sits: offsets from the screen centre, set by dragging it
-- (/ca move) or by /ca center <px>.
local function CenterOffset()
    return (CastAheadDB and tonumber(CastAheadDB.centerX) or 0),
        CENTER_Y + CastAheadConfig.CenterY()
end

local CENTER_STRATA = "HIGH"
local CENTER_LINES = 3      -- a pack can cast three things at once; more is noise
local CENTER_LINE_H = 44

function CastAheadCore.BuildCenterBlock(parent, strata)
    local block = CreateFrame("Frame", nil, parent)
    block:SetSize(360, CENTER_LINE_H * CENTER_LINES)
    if strata then block:SetFrameStrata(strata) end
    block:EnableMouse(false)
    block.lines = {}
    for i = 1, CENTER_LINES do
        local line = CreateFrame("Frame", nil, block)
        line:SetSize(360, CENTER_LINE_H)
        line:SetPoint("TOP", block, "TOP", 0, -(i - 1) * CENTER_LINE_H)
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
        line.extra = {}
        for k = 1, 2 do
            local x = line:CreateTexture(nil, "ARTWORK")
            x:SetSize(20, 20)
            x:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            x:SetPoint("LEFT", k == 1 and line.icon or line.extra[k - 1], "RIGHT", 4, 0)
            x:Hide()
            line.extra[k] = x
        end
        line.text:SetShadowColor(0, 0, 0, 1)
        line.text:SetShadowOffset(2, -2)
        line:Hide()
        block.lines[i] = line
    end
    return block
end

local function CenterFrame()
    if center then return center end
    center = CastAheadCore.BuildCenterBlock(UIParent, CENTER_STRATA)
    -- Backdrop only while the block is being moved, so there is something to
    -- grab and see.
    -- Only the first line is shown while moving, so only it is boxed: the
    -- box's centre is exactly where the call will sit.
    center.grip = center:CreateTexture(nil, "BACKGROUND")
    center.grip:SetAllPoints(center.lines[1])
    center.grip:SetColorTexture(0, 0, 0, 0.5)
    center.grip:Hide()
    center.fill = center:CreateTexture(nil, "BACKGROUND")
    center.fill:SetAllPoints(center)
    center.fill:SetColorTexture(0, 0, 0, 0.35)
    center.fill:Hide()
    center:SetMovable(true)
    center:RegisterForDrag("LeftButton")
    center:SetScript("OnDragStart", function(self)
        if centerUnlocked then
            self.dragging = true
            self:StartMoving()
        end
    end)
    center:SetScript("OnDragStop", function() CastAheadCore.DropCenter() end)
    center:Hide()
    return center
end

local function CenterDragOffset()
    if not (center and center.dragging) then return end
    -- Back to offsets from the screen centre, so the saved position
    -- survives resolution and scale changes the way an anchor would.
    local cx, cy = center:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if not (cx and ux) then return end
    -- GetCenter reports in the frame's own scale, UIParent's in its
    -- own, so the block's side is converted before the subtraction.
    local scale = center:GetScale()
    return math.floor(cx * scale - ux + 0.5),
        math.floor(cy * scale - uy + (center:GetHeight() / 2 - CENTER_LINE_H / 2) * scale + 0.5)
end

-- The words have a size of their own on top of the block's: the icon and
-- the countdown beside them are already as big as the block makes them.
function CastAheadCore.ApplyCenterTextScale(f)
    local textScale = CastAheadConfig.CenterTextScale()
    if f._textScale ~= textScale then
        f._textScale = textScale
        for i = 1, #f.lines do
            f.lines[i].text:SetFont(FONT, math.max(10, math.floor(28 * textScale + 0.5)), "OUTLINE")
        end
    end
end

local function PlaceCenter(f)
    local x, y = CenterOffset()
    -- The block is scaled rather than rebuilt at a new size: one setting then
    -- moves the icon, the words and the countdown together, and the spacing
    -- between them stays right at any size.
    local scale = CastAheadConfig.CenterScale()
    CastAheadCore.ApplyCenterTextScale(f)
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

local function DropCenter()
    if not (center and center.dragging) then return end
    center:StopMovingOrSizing()
    local x, y = CenterDragOffset()
    center.dragging = nil
    if not x then return end
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.centerX, CastAheadDB.centerY = x, y - CENTER_Y
    center._x = nil          -- force the anchor to be re-applied
    PlaceCenter(center)
end

-- /ca move: show the block with a sample
-- line and let it be dragged; call again to lock it in place.
local function ToggleMoveCenter(quiet)
    if not centerUnlocked and CastAheadSetup and CastAheadSetup.Active() then CastAheadSetup.Leave() end
    local f = CenterFrame()
    centerUnlocked = not centerUnlocked
    f:EnableMouse(centerUnlocked)
    if centerUnlocked then
        PlaceCenter(f)
        local line = f.lines[1]
        line.icon:SetTexture(136243)
        line.icon:SetPoint("RIGHT", line.text, "LEFT", -10, 0)
        for k = 1, 2 do line.extra[k]:Hide() end
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
        if not quiet then print("|cff33ff99CastAhead|r call block locked") end
    end
end

-- Announceable casts going out right now, soonest-ending first, among live
-- plates and the test drive.
local centerPicks = {}
local function CenterPick(now)
    for i = #centerPicks, 1, -1 do centerPicks[i] = nil end
    for unit, state in pairs(plates) do
        local c = state.casting
        if c and c.endAt and c.endAt > now and Announceable(c.candidates, state.interruptible) then
            local advice = CastAheadMatch.ConsensusAdvice(c.candidates, state.interruptible)
            if advice then
                centerPicks[#centerPicks + 1] = { endAt = c.endAt, advice = advice, row = c.row,
                                                  icons = CastAheadSaves and CastAheadSaves.Icons(advice, c.candidates) or nil }
                local save = advice == CastAheadMatch.ADVICE.TARGET and CastAheadSaves and c.candidates[1]
                    and CastAheadMatch.SaveAdvice(c.candidates[1])
                if save then
                    centerPicks[#centerPicks + 1] = { endAt = c.endAt, advice = save, row = c.row,
                                                      icons = CastAheadSaves.Icons(save, c.candidates[1].spell), onlyIfTarget = unit }
                end
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
    if CastAheadSaves and CastAheadConfig.SaveCalls() then
        for _, pick in ipairs(CastAheadSaves.Pending(now)) do centerPicks[#centerPicks + 1] = pick end
    end
    if CastAheadBurst then
        for _, pick in ipairs(CastAheadBurst.Pending(now)) do centerPicks[#centerPicks + 1] = pick end
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

local function PaintCenter(f, picks, now)
    for i = 1, CENTER_LINES do
        local line, pick = f.lines[i], picks[i]
        if pick then
            local icons = pick.icons
            line.icon:SetTexture(icons and icons[1] or SpellIcon(pick.row.spell))
            local shownExtras = icons and math.min(math.max(#icons - 1, 0), 2) or 0
            line.icon:SetPoint("RIGHT", line.text, "LEFT", -(10 + 24 * shownExtras), 0)
            for k = 1, 2 do
                local x = line.extra[k]
                if k <= shownExtras then
                    x:SetTexture(icons[k + 1])
                    x:Show()
                else
                    x:Hide()
                end
            end
            -- "Tank buster 4.0": the response in words, not the category code.
            local say = pick.advice.say
            line.text:SetFormattedText("%s  %.1f", say:sub(1, 1):upper() .. say:sub(2), pick.endAt - now)
            line.text:SetTextColor(pick.advice.r, pick.advice.g, pick.advice.b)
            local ok, mine
            if pick.onlyIfTarget and PlayerIsSpellTarget and line.SetAlphaFromBoolean then
                ok, mine = pcall(PlayerIsSpellTarget, pick.onlyIfTarget)
            end
            if ok then
                line:SetAlphaFromBoolean(mine, 1, 0)
            else
                line:SetAlpha(pick.onlyIfTarget and 0 or 1)
            end
            line:Show()
        else
            line:Hide()
        end
    end
    f:Show()
end

local function UpdateCenter(now)
    if centerUnlocked or centerSample then return end     -- being dragged: leave the sample alone
    local picks = CastAheadConfig.CenterText() and CenterPick(now) or nil
    if not picks or #picks == 0 then
        HideCenter()
        return
    end
    local f = CenterFrame()
    PlaceCenter(f)
    PaintCenter(f, picks, now)
end

local sampleRows = {}

function CastAheadCore.SampleDataRow(key)
    local hit = sampleRows[key]
    if hit ~= nil then return hit or nil end
    for _, rows in pairs(CastAheadData) do
        for _, row in ipairs(rows) do
            local advice = CastAheadMatch.Advice(row)
            if advice and advice.key == key then
                sampleRows[key] = row
                return row
            end
        end
    end
    sampleRows[key] = false
end

function CastAheadCore.SamplePicks(keys, now)
    local A = CastAheadMatch.ADVICE
    local picks = {}
    for i = 1, #keys do
        local key = keys[i]
        if key == "KICK" then
            local kick = CastAheadCore.SampleDataRow("KICK")
            picks[#picks + 1] = { advice = A.KICK, endAt = now + 2.4,
                                  icons = { kick and SpellIcon(kick.spell) or FALLBACK_ICON } }
        elseif key == "DEFENSIVE" then
            local defensive = CastAheadSaves and CastAheadSaves.Icons(A.DEFENSIVE, nil)
            picks[#picks + 1] = { advice = A.DEFENSIVE, endAt = now + 4.0,
                                  icons = defensive and #defensive > 0 and defensive or { FALLBACK_ICON } }
        elseif key == "BURST" then
            picks[#picks + 1] = { advice = A.BURST, endAt = now + 6.0,
                                  icons = { CastAheadBurst and CastAheadBurst.ICON or FALLBACK_ICON } }
        end
    end
    return picks
end

function CastAheadCore.ShowCenterSample(on)
    if centerUnlocked then ToggleMoveCenter(true) end
    centerSample = (on and CastAheadConfig.CenterText()) and true or false
    if not centerSample then
        if center then center.fill:Hide() end
        HideCenter()
        return false
    end
    local f = CenterFrame()
    f.fill:Show()
    PlaceCenter(f)
    local now = GetTime()
    PaintCenter(f, CastAheadCore.SamplePicks({ "KICK", "DEFENSIVE", "BURST" }, now), now)
    return true
end

-- The settings picture of the centre call: a block of its own, painted by the
-- same code as the real one, at the player's text size.
CastAheadCore.NewCenterPreview = CastAheadCore.BuildCenterBlock

function CastAheadCore.PaintCenterPreview(block, keys)
    local now = GetTime()
    local picks = CastAheadCore.SamplePicks(keys, now)
    if #picks == 0 then
        for i = 1, CENTER_LINES do block.lines[i]:Hide() end
        block:Hide()
        return 0, 0
    end
    CastAheadCore.ApplyCenterTextScale(block)
    PaintCenter(block, picks, now)
    -- Measured about the block's centre, so a centred block shows all of it:
    -- the text sits 25 right of the centre, and the 40 icon, its 10 gap and
    -- up to two 24 extras hang off the text's left edge.
    local shown = math.min(#picks, CENTER_LINES)
    local width = 0
    for i = 1, shown do
        local icons = picks[i].icons
        local extras = icons and math.min(math.max(#icons - 1, 0), 2) or 0
        width = math.max(width, (block.lines[i].text:GetStringWidth() or 0) + 2 * (25 + 24 * extras))
    end
    return width, CENTER_LINE_H * shown
end

-- The settings' per-feature Test buttons: one defensive call or one burst
-- window through the real schedule, centre block and sounds. Outside a
-- dungeon the main ticker sleeps until the centre shows, so this frame ticks
-- until the sample ends.
local featureTest = { frame = CreateFrame("Frame"), untilAt = 0 }

local function FeatureTest(kind)
    local now = GetTime()
    local endAt
    if kind == "defensive" and CastAheadSaves and CastAheadConfig.SaveCalls() then
        local fireAt = now + 1 + CastAheadConfig.SaveLead()
        endAt = fireAt + 5
        CastAheadSaves.Schedule("demo:def", 0, fireAt, endAt, CastAheadMatch.ADVICE.DEFENSIVE)
    elseif kind == "burst" and CastAheadBurst and CastAheadBurst.Demo and CastAheadConfig.BurstCalls() then
        endAt = CastAheadBurst.Demo(now)
    end
    if not endAt then return false end
    featureTest.untilAt = math.max(featureTest.untilAt, endAt)
    featureTest.frame:SetScript("OnUpdate", function()
        local t = GetTime()
        if CastAheadSaves and CastAheadConfig.SaveCalls() then CastAheadSaves.Tick(t) end
        if CastAheadBurst then CastAheadBurst.Tick(t) end
        UpdateCenter(t)
        if t >= featureTest.untilAt then featureTest.frame:SetScript("OnUpdate", nil) end
    end)
    return true
end

local function StopFeatureTests()
    featureTest.frame:SetScript("OnUpdate", nil)
    featureTest.untilAt = 0
    if CastAheadSaves then CastAheadSaves.CancelPrefix("demo:") end
    if CastAheadBurst and CastAheadBurst.ClearDemo then CastAheadBurst.ClearDemo() end
end

frame:SetScript("OnUpdate", function()
    if not (dungeon or inEncounter or (center and center:IsShown())) then return end
    local now = GetTime()
    if CastAheadSaves and CastAheadConfig.SaveCalls() then CastAheadSaves.Tick(now) end
    if CastAheadBurst then CastAheadBurst.Tick(now) end
    UpdateCenter(now)
    if not dungeon then return end
    if CastAheadBossAdapter then CastAheadBossAdapter.Tick(now) end
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
                            SetApprox(bar, false)
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
                        if not entry.casting and entry.track and not entry.track.warned then
                            local lead = CastAheadConfig.LeadFor(entry.candidates)
                            local saveLead = CastAheadSaves and CastAheadConfig.SaveCalls()
                                and CastAheadConfig.LeadFor(entry.candidates, CastAheadConfig.SaveLead()) or 0
                            local window = math.max(lead, saveLead)
                            if window > 0 and remaining <= window then
                                local heads = CastAheadMatch.ConsensusAdvice(entry.candidates)
                                local isSave = CastAheadSaves and CastAheadMatch.IsSave(heads)
                                if isSave and remaining <= saveLead or not isSave and remaining <= lead then
                                    entry.track.warned = true
                                    Record("HEADS", unit, heads and heads.key or "-", Ids(entry.candidates))
                                    if heads and heads.label == "KICK" then
                                        KickTrace(unit, "soon", state, entry.candidates,
                                            CastAheadMatch.BestGuess(entry.candidates).spell, nil, heads)
                                    end
                                    if KickVoiceAllowed(unit, heads) then
                                        PlayAdviceSound(heads, true, entry.candidates)
                                    end
                                end
                            end
                        end
                        -- Tenths only in the last few seconds, where they
                        -- matter; whole numbers stay readable at a glance.
                        SetApprox(bar, entry.approximate and remaining >= ESTIMATE_NOW or false)
                        if entry.approximate and remaining < ESTIMATE_NOW then
                            -- Inside the estimate's own error bars. Printing
                            -- "~1" claims a precision this number never had.
                            bar.time:SetText("|cffffd100!|r")
                        elseif entry.approximate then
                            bar.time:SetFormattedText("%d", remaining + 0.5)
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
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_SPECIALIZATION_CHANGED", "SPELLS_CHANGED",
    "PLAYER_DIFFICULTY_CHANGED",
    "ENCOUNTER_START", "ENCOUNTER_END", "CHALLENGE_MODE_START", "CHALLENGE_MODE_COMPLETED",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "BAG_UPDATE_DELAYED",
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
    frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
else
    frame:RegisterEvent("UNIT_AURA")
    frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end

-- Diagnostics ---------------------------------------------------------------

-- /ca debug. Answers the questions that matter when nothing shows up: did
-- the dungeon table load, are plates being tracked, what level did we read, and
-- how far identification got on each one.
CastAheadCore.CENTER_Y = CENTER_Y
CastAheadCore.CenterFrame = CenterFrame
CastAheadCore.DropCenter = DropCenter
CastAheadCore.Announce = PlayAdviceSound
CastAheadCore.FeatureTest = FeatureTest
CastAheadCore.StopFeatureTests = StopFeatureTests
CastAheadCore.AdviceFile = AdviceFile
CastAheadCore.ReapplyData = function() extrasMerged = false; MergeCuration() end
CastAheadCore.LastCandidates = LastCandidates   -- replay harness only
CastAheadCore.Tracks = function(unit) return plates[unit] and plates[unit].tracks end
CastAheadCore.Casting = function(unit) return plates[unit] and plates[unit].casting end

function CastAheadCore.Snapshot()
    local out, now = {}, GetTime()
    local key = CastAheadRecorder and CastAheadRecorder.Current()
    for unit, state in pairs(plates) do
        local entry = { slot = tonumber(unit:match("(%d+)$")), preds = {} }
        local c = state.casting
        if c then
            local advice = Announceable(c.candidates)
                and CastAheadMatch.ConsensusAdvice(c.candidates, state.interruptible)
            entry.casting = { claimed = c.row and c.row.spell or "-", call = advice and advice.key or "-",
                candidates = Ids(c.candidates), sinceMs = math.floor((now - c.startAt) * 1000 + 0.5) }
        end
        for _, track in pairs(state.tracks) do
            if key and track.nextAt and track.candidates and #track.candidates == 1 then
                entry.preds[#entry.preds + 1] = { track.candidates[1].spell,
                    math.floor((track.nextAt - key.startedAt) * 1000 + 0.5),
                    (track.projected or track.candidates[1].approx) and 1 or 0 }
            end
        end
        if entry.slot then out[#out + 1] = entry end
    end
    return out
end
CastAheadCore.SetTrace = function(fn) narrowTrace = fn end
CastAheadCore.Tuning = tuning
CastAheadCore.SpreadBars = SpreadBars
CastAheadCore.Population = function() return killed, exhausted end
CastAheadCore.MoveCenter = ToggleMoveCenter
CastAheadCore.IsHostileNameplate = IsHostileNameplate
CastAheadCore.RememberPlateSize = RememberPlateSize

function CastAheadCore.PlateSize()
    local size = CastAheadDB and CastAheadDB.plateSize
    if size then return size[1], size[2] end
    if C_NamePlate.GetNamePlateSize then
        local w, h = C_NamePlate.GetNamePlateSize()
        return w, h, "guess"
    end
    return 110, 45, "guess"
end


-- The window's speaker buttons: hear a call exactly as it would play.
-- Deliberately ignores the sound/voice mute switches - an explicit click
-- wants to hear it. `voice` false plays it as the voice switch off would.
function CastAheadCore.PreviewAdvice(advice, candidates, voice)
    if advice then Alert(advice, nil, candidates, voice ~= false) end
end
CastAheadCore.PreviewSound = CastAheadCore.PreviewAdvice

-- One entry of the sound picker, before it is picked: a shared-media sound by
-- name, or the spoken call for the Voice entry.
function CastAheadCore.PreviewMedia(name, advice)
    if not name then
        if advice and not Voice(advice) then Beep(advice) end
        return
    end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local sound = lsm and lsm:Fetch("sound", name, true)
    if sound then PlayMedia(sound) end
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
        if not e.done and not e.hidden then
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
    local on = CastAheadConfig.Enabled("nameplates")
    if e.unit and AnchorBar(e.unit, e.bar, e.slot) then
        e.bar:SetShown(on)
        return
    end
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
            (i - 1) * step - ((demo.shown or #demo.entries) - 1) * step / 2, -160)
    end

    e.bar:SetShown(on)
end

-- With `list` (the table's rows, in its order) every one of them is played
-- in turn, one call at a time on the first hostile plate around: that is for
-- hearing each cast's sound rather than judging the layout.
function CastAheadCore.Test(instanceID, list)
    if CastAheadSetup and CastAheadSetup.Active() then CastAheadSetup.Leave() end
    if demo then
        StopTest()
        CastAheadCore.StopFeatureTests()
        return
    end
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
    -- One row per distinct call across every dungeon (this one's rows first),
    -- so every voice line can be heard. Only the per-spell mute applies: the
    -- role and Important filters would hide exactly the calls this character
    -- never gets.
    local pools = { list or rows }
    if not list then
        local ids = {}
        for k in pairs(CastAheadData) do ids[#ids + 1] = k end
        table.sort(ids)
        for _, k in ipairs(ids) do
            if CastAheadData[k] ~= rows then pools[#pools + 1] = CastAheadData[k] end
        end
    end
    local picked, seen = {}, {}
    for p = 1, #pools do
        for i = 1, #pools[p] do
            local row = pools[p][i]
            local advice = CastAheadMatch.Advice(row)
            if advice and (list or not seen[advice.label])
                and not (CastAheadUI and CastAheadUI.IsDisabled and CastAheadUI.IsDisabled(row.spell)) then
                seen[advice.label] = true
                picked[#picked + 1] = row
            end
        end
    end
    if #picked == 0 then
        print("|cff33ff99CastAhead|r nothing passes the current filters in " .. (rows.name or id))
        return
    end
    if CastAheadTimeline then CastAheadTimeline.NoteBigWigsAsleep() end
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
    -- One call at a time: the one counting down and the one going out.
    local spacing = CastAheadConfig.Lead() + 3
    local gap = list and spacing or nil
    if list then demo.shown = 2 end
    local now = GetTime()
    -- Several calls per plate, always: one icon per plate tells the player
    -- nothing about the spacing between them, which is the thing a test drive
    -- is usually run to judge. But only on the first few plates - the icons
    -- spread across the screen while the timeline stacks every one of them
    -- into a single column, so a room full of training dummies filled it top
    -- to bottom.
    local plates = math.min(#units, list and 1 or DEMO_PLATES)
    local total = list and #picked or math.max(#picked, plates * DEMO_PER_PLATE)
    local slots = {}
    for i = 1, total do
        local row = picked[(i - 1) % #picked + 1]
        local unit = units[(i - 1) % math.max(plates, 1) + 1]
        slots[unit or 0] = (slots[unit or 0] or 0) + 1
        local e = {
            row = row, candidates = { row },
            endAt = now + 2 + (i - 1) * spacing,
            track = {},
            unit = unit, slot = slots[unit or 0],
            hidden = (gap and i > 1) or nil,
        }
        e.bar = GetBar(demo.state, i)
        PaintBar(e.bar, e)
        DemoAnchor(e, i)
        e.bar:SetShown((not gap or i == 1) and CastAheadConfig.Enabled("nameplates"))
        if CastAheadTimeline and not gap then
            CastAheadTimeline.Sync(e.track, e.endAt, row,
                CastAheadMatch.Advice(row), true)
        end
        demo.entries[i] = e
    end
    DemoLayout()
    print(string.format("|cff33ff99CastAhead|r test: %d call(s) from %s on %d plate(s) (again to stop)",
        total, tostring(rows.name or id), plates))
    if CastAheadUI and CastAheadUI.RefreshTest then CastAheadUI.RefreshTest() end
    -- The whole-addon run: features that are switched on join with a sample each.
    if not list then
        CastAheadCore.FeatureTest("defensive")
        CastAheadCore.FeatureTest("burst")
    end
    demo.frame:SetScript("OnUpdate", function()
        if not demo then return end
        local t = GetTime()
        if not dungeon then UpdateCenter(t) end   -- in a dungeon the main ticker does it
        -- A call finished on the previous tick: close the row up before
        -- anything is placed again.
        if demo.repack then DemoLayout() end
        local alive, shown = 0, 0
        for i = 1, #demo.entries do
            local e = demo.entries[i]
            if not e.done and gap and e.endAt - t > gap then
                alive = alive + 1
                e.bar:Hide()
            elseif not e.done then
                alive = alive + 1
                shown = shown + 1
                if e.hidden then
                    e.hidden = nil
                    demo.repack = true
                end
                DemoAnchor(e, gap and shown or i)
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
                    PlayAdviceSound(CastAheadMatch.Advice(e.row), nil, { e.row })
                    if CastAheadTimeline then CastAheadTimeline.Finish(e.track) end
                else
                    local remaining = e.endAt - t
                    local advice = CastAheadMatch.Advice(e.row)
                    local lead = CastAheadConfig.LeadFor({ e.row }, CastAheadSaves
                        and CastAheadMatch.IsSave(advice) and CastAheadConfig.SaveLead() or nil)
                    if lead > 0 and remaining <= lead and not e.warned then
                        e.warned = true
                        PlayAdviceSound(advice, true, { e.row })
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
    -- The list above was written from memory and missed things. These come
    -- from Blizzard's own generated documentation instead: every function that
    -- takes a unit token, describes the creature rather than the group around
    -- it, and carries no secrecy flag. A flag is only a promise about the
    -- return value, not about what a hostile nameplate will actually answer -
    -- UnitThreatSituation is unflagged and still came back nil every time - so
    -- these are candidates to measure, not facts.
    --
    -- The first is the interesting one: a plain boolean about the cast going
    -- out right now, which is a property of the spell rather than the mob and
    -- would split candidates that tie on everything else.
    { "UnitShouldDisplaySpellTargetName", function(u) return UnitShouldDisplaySpellTargetName(u) end },
    { "UnitShouldDisplayName", function(u) return UnitShouldDisplayName(u) end },
    -- Summoned adds are not the pack's own creatures, and our tables should
    -- not be timing them as if they were.
    { "UnitIsMinion", function(u) return UnitIsMinion(u) end },
    -- Any of these would fingerprint a creature far harder than its level.
    { "UnitArmor.effective", function(u) return select(2, UnitArmor(u)) end },
    { "UnitAttackSpeed", function(u) return (UnitAttackSpeed(u)) end },
    { "UnitSpellHaste", function(u) return UnitSpellHaste(u) end },
    { "UnitPowerBarID", function(u) return UnitPowerBarID(u) end },
    { "UnitNumPowerBarTimers", function(u) return UnitNumPowerBarTimers(u) end },
    { "UnitWidgetSet", function(u) return UnitWidgetSet(u) end },
    { "UnitNameplateShowsWidgetsOnly", function(u) return UnitNameplateShowsWidgetsOnly(u) end },
    { "UnitSelectionType", function(u) return UnitSelectionType(u) end },
    { "UnitIsGameObject", function(u) return UnitIsGameObject(u) end },
    { "UnitAffectingCombat", function(u) return UnitAffectingCombat(u) end },
    -- Empowered casts have stages, which is a hard tell where it happens.
    { "UnitEmpoweredChannelDuration", function(u) return UnitEmpoweredChannelDuration(u) end },
    -- How long the cast in progress runs for. Identification rests on that
    -- length, and today it can only be measured after the cast ends, which is
    -- why nothing is named while the bar is still filling.
    --
    -- UnitCastingDuration is documented SecretReturns, so this is expected to
    -- come back secret - it is here to prove that rather than assume it.
    -- UnitChannelDuration carries no such flag, and a channel's length is the
    -- one thing combat logs never record, so if it reads we gain a fact we
    -- currently ship by hand.
    { "UnitCastingDuration", function(u) return UnitCastingDuration(u) end },
    { "UnitCastingDuration:GetTotalDuration", function(u)
        local d = UnitCastingDuration(u)
        return d and d:GetTotalDuration() or nil
    end },
    { "UnitChannelDuration", function(u) return UnitChannelDuration(u) end },
    { "UnitChannelDuration:GetTotalDuration", function(u)
        local d = UnitChannelDuration(u)
        return d and d:GetTotalDuration() or nil
    end },
    -- Almost certainly party-only, but the check costs one call.
    { "UnitPosition.x", function(u) return (UnitPosition(u)) end },
    { "UnitDistanceSquared", function(u) return (UnitDistanceSquared(u)) end },
}
local probing = false

local function Tally(db, name, ok, value)
    local row = db[name]
    if not row then row = { secret = 0, readable = 0, empty = 0 } db[name] = row end
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

function Probe(unit)
    if not probing then return end
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.probe = CastAheadDB.probe or {}
    for i = 1, #PROBES do
        Tally(CastAheadDB.probe, PROBES[i][1], pcall(PROBES[i][2], unit))
    end
end

-- Fingerprints: what the game still says about a cast at the moment it starts,
-- one row per hostile cast, joined offline against the combat log to learn
-- which readable facts tell spells apart. The player's own cast starts carry
-- readable spell ids and are the clock anchors that make that join possible.
-- The duration and name attempts ask whether a secret can still be measured
-- through something documented as safe: a curve, a formatter, a bar, a text
-- width. The sweep calls every documented Unit* function on the casting unit
-- and keeps only counts, to find readable facts nobody thought to try.
local FINGERPRINT_CAP = 4000
local SESSIONS_KEPT = 12
local session, sweep, identityCurve, secondsFormatter, widthProbe, barProbe

local function Now()
    return (GetTimePreciseSec or GetTime)()
end

local function Fact(ok, ...)
    if not ok then return "E" end
    local value = ...
    if value == nil then return "-" end
    if IsSecret(value) then return "S" end
    return tostring(value)
end

local function Try(fn, ...)
    return Fact(pcall(fn, ...))
end

local function Session()
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.fingerprints = CastAheadDB.fingerprints or {}
    if not session then
        session = { started = date("%Y-%m-%d %H:%M:%S"), startedAt = Now(),
                    player = UnitGUID("player"), rows = {}, anchors = {} }
        local list = CastAheadDB.fingerprints
        list[#list + 1] = session
        while #list > SESSIONS_KEPT do table.remove(list, 1) end
    end
    return session
end

function ProbeAnchor(spellID)
    if not probing then return end
    local s = Session()
    if #s.anchors < FINGERPRINT_CAP then
        s.anchors[#s.anchors + 1] = { Now(), Fact(true, spellID) }
    end
end

local function DurationFacts(row, duration)
    if type(duration) ~= "userdata" and type(duration) ~= "table" then return end
    if not identityCurve and C_CurveUtil and C_CurveUtil.CreateCurve then
        identityCurve = C_CurveUtil.CreateCurve()
        identityCurve:AddPoint(0, 0)
        identityCurve:AddPoint(600, 600)
    end
    if not secondsFormatter and C_StringUtil and C_StringUtil.CreateSecondsFormatter then
        secondsFormatter = C_StringUtil.CreateSecondsFormatter()
    end
    row.zero = Try(duration.IsZero, duration)
    row.modRate = Try(duration.GetModRate, duration)
    row.hasSecret = Try(duration.HasSecretValues, duration)
    row.total = Try(duration.GetTotalDuration, duration)
    row.curve = identityCurve and Try(duration.EvaluateTotalDuration, duration, identityCurve) or "-"
    row.formatted = secondsFormatter and Try(duration.FormatTotalDuration, duration, secondsFormatter) or "-"
    if not barProbe then
        barProbe = CreateFrame("StatusBar")
        barProbe:Hide()
    end
    row.bar = Try(function()
        barProbe:SetTimerDuration(duration)
        return select(2, barProbe:GetMinMaxValues())
    end)
end

local function BuildSweep()
    sweep = {}
    if C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "Blizzard_APIDocumentationGenerated")
    end
    local docs = APIDocumentation and APIDocumentation.functions
    for _, info in ipairs(docs or {}) do
        local args = info.Arguments
        local system = info.System
        local namespace = system and system.GetNamespaceName and system:GetNamespaceName()
        if (namespace == nil or namespace == "") and type(info.Name) == "string"
            and info.Name:match("^Unit") and not info.Name:match("^UnitSetRole")
            and args and args[1] and tostring(args[1].Type):match("UnitToken")
            and type(_G[info.Name]) == "function" then
            local other = args[2] and tostring(args[2].Type):match("UnitToken") and "player" or nil
            sweep[#sweep + 1] = { info.Name, other }
        end
    end
end

-- Loading the documentation mid-pull would stall the frame the pull starts on.
function ProbeRestore()
    probing = CastAheadConfig.Recording()
    if probing and not sweep then BuildSweep() end
end

local function Sweep(unit)
    if not sweep then BuildSweep() end
    CastAheadDB.sweep = CastAheadDB.sweep or {}
    for i = 1, #sweep do
        local name, other = sweep[i][1], sweep[i][2]
        Tally(CastAheadDB.sweep, name, pcall(_G[name], unit, other))
    end
end

function ProbeCall(row, unit)
    if not row then return end
    local state = plates[unit]
    local casting = state and state.casting
    row.claimed = casting and casting.row and casting.row.spell or "-"
    local advice = casting and Announceable(casting.candidates, state.interruptible)
        and CastAheadMatch.ConsensusAdvice(casting.candidates, state.interruptible)
    row.call = advice and advice.key or "-"
end

function ProbeCast(unit, channel)
    if not probing or not IsHostileNameplate(unit) then return end
    local s = Session()
    if #s.rows >= FINGERPRINT_CAP then return end
    local row = { t = Now(), unit = unit, channel = channel or nil }
    local info = { pcall(channel and UnitChannelInfo or UnitCastingInfo, unit) }
    if info[1] then
        row.startMs, row.endMs = Fact(true, info[5]), Fact(true, info[6])
        if channel then
            row.notInterruptible, row.empowered = Fact(true, info[8]), Fact(true, info[10])
            row.stages, row.castBarID = Fact(true, info[11]), Fact(true, info[12])
        else
            row.notInterruptible, row.castBarID, row.delayMs = Fact(true, info[9]), Fact(true, info[11]), Fact(true, info[12])
        end
        local name = info[2]
        if name ~= nil then
            if not widthProbe then
                widthProbe = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                widthProbe:Hide()
            end
            row.nameWidth = Try(function()
                widthProbe:SetText(name)
                return widthProbe:GetStringWidth()
            end)
        end
    else
        row.info = "E"
    end
    local target = unit .. "target"
    row.level = Try(UnitLevel, unit)
    row.classification = Try(UnitClassification, unit)
    row.power = Try(UnitPowerType, unit)
    row.lieutenant = Try(UnitIsLieutenant, unit)
    row.class = Try(function() return select(2, UnitClass(unit)) end)
    row.classID = Try(function() return select(3, UnitClass(unit)) end)
    row.spellTarget = Try(UnitShouldDisplaySpellTargetName, unit)
    row.spellTargetClass = Try(UnitSpellTargetClass, unit)
    row.spellTargetName = Try(UnitSpellTargetName, unit)
    row.targetExists = Try(UnitExists, target)
    row.targetIsMe = Try(UnitIsUnit, target, "player")
    row.targetIsPlayer = Try(UnitIsPlayer, target)
    row.targetRole = Try(UnitGroupRolesAssigned, target)
    row.threat = Try(UnitThreatSituation, "player", unit)
    local okDuration, duration = pcall(channel and UnitChannelDuration or UnitCastingDuration, unit)
    if okDuration then DurationFacts(row, duration) end
    s.rows[#s.rows + 1] = row
    Sweep(unit)
    return row
end

function CastAheadCore.Probing() return probing end

function CastAheadCore.SyncCombatLog()
    if not (LoggingCombat and CastAheadDB) then return end
    local _, kind = IsInInstance()
    local want = kind == "party" and CastAheadConfig.Recording()
    if want then
        if C_CVar and C_CVar.SetCVar then C_CVar.SetCVar("advancedCombatLogging", "1") end
        if not LoggingCombat() then
            LoggingCombat(true)
            CastAheadDB.combatLogOurs = true
            print("|cff33ff99CastAhead|r combat log on for this dungeon")
        end
    elseif CastAheadDB.combatLogOurs then
        CastAheadDB.combatLogOurs = nil
        if LoggingCombat() then
            LoggingCombat(false)
            print("|cff33ff99CastAhead|r combat log off")
        end
    end
end

function CastAheadCore.ApplyDevMode()
    ProbeRestore()
    CastAheadCore.SyncCombatLog()
    if CastAheadReport then CastAheadReport.Refresh() end
    if CastAheadUI and CastAheadUI.RefreshTabs then CastAheadUI.RefreshTabs() end
end

function CastAheadCore.Probe(command)
    if command == "clear" then
        if CastAheadDB then
            CastAheadDB.probe, CastAheadDB.sweep, CastAheadDB.fingerprints = nil, nil, nil
        end
        session = nil
        print("|cff33ff99CastAhead|r probe results cleared")
        return
    end
    if command == "sweep" then
        local db = CastAheadDB and CastAheadDB.sweep
        if not db then print("|cff33ff99CastAhead|r no sweep results yet") return end
        local names = {}
        for name, r in pairs(db) do
            if r.readable > 0 then names[#names + 1] = name end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local r = db[name]
            print(string.format("|cff33ff99CastAhead|r %-34s readable %4d  secret %4d  nil %4d  err %4d  distinct %s  e.g. %s",
                name, r.readable, r.secret, r.empty, r.errors or 0, tostring(r.distinct or 0), tostring(r.sample)))
        end
        return
    end
    local fp = CastAheadDB and CastAheadDB.fingerprints
    if fp and #fp > 0 then
        local last = fp[#fp]
        print(string.format("|cff33ff99CastAhead|r fingerprints: %d session(s), last %s with %d casts and %d anchors",
            #fp, tostring(last.started), #last.rows, #last.anchors))
    end
    local db = CastAheadDB and CastAheadDB.probe
    if not db then print("|cff33ff99CastAhead|r no probe results yet") return end
    local names = {}
    for name in pairs(db) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local r = db[name]
        print(string.format("|cff33ff99CastAhead|r %-26s readable %3d  secret %3d  nil %3d  err %3d  distinct %s  e.g. %s",
            name, r.readable, r.secret, r.empty, r.errors or 0, tostring(r.distinct or 0), tostring(r.sample)))
    end
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
        local okP, willPlay = pcall(PlaySoundFile, SOUND_ROOT .. "en\\TANK.ogg", CastAheadConfig.SoundChannel())
        say("clip TANK.ogg: willPlay=%s (voiceTTS=%s, voice=%s, sound=%s)",
            okP and tostring(willPlay) or "error", tostring(db.voiceTTS), tostring(db.voice), tostring(db.sound))
    else
        say("clip: PlaySoundFile missing")
    end
    if CastAheadSetup and CastAheadSetup.Active() then CastAheadSetup.Debug(say) end
end

-- Called by the options window when an output toggle changes, so bars and
-- timeline events already on screen follow the new setting instead of
-- lingering until the next cast happens to repaint them.
-- The centre call's size changed in the window: re-anchor it, and let a block
-- that is currently on screen (or being dragged) take the new scale at once.
function CastAheadCore.ResizeCenter()
    if center then PlaceCenter(center) end
end

CastAheadCore.SAMPLE_ROW = {
    { key = "KICK", time = 7, approx = true },
    { key = "DODGE", time = 3 },
    { key = "TANK", time = 12 },
}
CastAheadCore.SampleStates = {}

function CastAheadCore.ShowSampleRow(state, frame)
    local row = CastAheadCore.SAMPLE_ROW
    local on = CastAheadConfig.Enabled("nameplates") and (not frame.IsShown or frame:IsShown())
    for i = 1, #row do
        local sample = row[i]
        local bar = GetBar(state, i)
        PaintBar(bar, { row = CastAheadCore.SampleDataRow(sample.key) or { prio = sample.key }, approximate = sample.approx }, nil)
        SetApprox(bar, sample.approx == true)
        bar.time:SetFormattedText("%d", sample.time)
        spread[i] = bar
    end
    SpreadBars(spread, #row)
    for i = 1, #row do
        AnchorToFrame(frame, state.bars[i], i)
        state.bars[i]:SetShown(on)
    end
end

function CastAheadCore.HideSampleRow(state)
    ReleaseBars(state)
end

-- The settings picture of the row: bars of the holder's own around a stand-in
-- plate, painted and placed by the sample row's own code. Shown whatever the
-- nameplate switch says; the caller draws the off state. Returns the size of
-- plate, icons and labels together, so the caller can scale it to fit, and
-- where the plate's bottom-left corner sits inside that size.
function CastAheadCore.PreviewRow(holder, plate)
    holder.previewBars = holder.previewBars or {}
    local bars = holder.previewBars
    local row = CastAheadCore.SAMPLE_ROW
    -- Every slot is filled before the sample row runs, so GetBar never
    -- reaches the pool for these bars.
    for i = 1, #row do bars[i] = bars[i] or CastAheadCore.NewBar(holder) end
    CastAheadCore.ShowSampleRow({ bars = bars }, plate)
    local function fraction(point)
        return point:find("LEFT") and 0 or point:find("RIGHT") and 1 or 0.5,
            point:find("BOTTOM") and 0 or point:find("TOP") and 1 or 0.5
    end
    local pw, ph = plate:GetWidth() or 0, plate:GetHeight() or 0
    local minX, minY, maxX, maxY = 0, 0, pw, ph
    for i = 1, #row do
        local bar = bars[i]
        bar:Show()
        local point, _, relative, x, y = bar:GetPoint()
        local rx, ry = fraction(relative)
        local px, py = fraction(point)
        local size = bar._size or ICON_SIZE
        local left = rx * pw + x - px * size
        local bottom = ry * ph + y - py * size
        local half = math.max(size, bar.label:GetStringWidth() or 0) / 2
        local labelH = math.max(bar.label:GetStringHeight() or 0, LABEL_HEIGHT)
        minX = math.min(minX, left + size / 2 - half)
        maxX = math.max(maxX, left + size / 2 + half)
        minY = math.min(minY, bottom - 1 - labelH)
        maxY = math.max(maxY, bottom + size)
    end
    return maxX - minX, maxY - minY, -minX, -minY
end

-- A data row that "Important casts only" keeps (`important` true) or drops,
-- for a picture that shows what the filter does: with this call, or with
-- `key` nil any call but a kick or a tank buster that this character can act
-- on, so only that filter drops it. Nil when there is none.
function CastAheadCore.SampleRowWhere(key, important)
    local cacheKey = (key or "ANY") .. (important and ":important" or ":other")
    local hit = sampleRows[cacheKey]
    if hit ~= nil then return hit or nil end
    for _, rows in pairs(CastAheadData) do
        for _, row in ipairs(rows) do
            local advice = CastAheadMatch.Advice(row)
            local fits = advice and (key and advice.key == key
                or not key and advice.key ~= "KICK" and advice.key ~= "TANK" and advice.key ~= "BUSTER"
                    and CastAheadMatch.FitsPlayer(row))
            if fits and (CastAheadMatch.Important(row) and true or false) == important then
                sampleRows[cacheKey] = row
                return row
            end
        end
    end
    sampleRows[cacheKey] = false
end

-- One cast on a bar of the caller's (from NewBar), painted by the same code
-- as the sample row, for a picture that places its icons itself. `key` names
-- the sample whose timing it shows; `row` picks the cast, else the sample
-- row's own. Returns the icon size.
function CastAheadCore.PaintPreviewBar(bar, key, row)
    local sample = { time = 5 }
    for _, s in ipairs(CastAheadCore.SAMPLE_ROW) do
        if s.key == key then sample = s end
    end
    local size = ApplyBarSize(bar)
    row = row or CastAheadCore.SampleDataRow(key) or { prio = key }
    PaintBar(bar, { row = row, approximate = sample.approx }, nil)
    SetApprox(bar, sample.approx == true)
    bar.time:SetFormattedText("%d", sample.time)
    bar:Show()
    return size
end

-- The picked samples depend on the role and on whether defensive calls are on.
function CastAheadCore.ForgetSamples()
    wipe(sampleRows)
end

function CastAheadCore.Reapply()
    wipe(sampleRows)
    local isDisabled = CastAheadUI and CastAheadUI.IsDisabled
    for unit, state in pairs(plates) do
        for key, track in pairs(state.tracks) do
            -- A spell switched off in the window leaves its track right away.
            if track.candidates and isDisabled
                and #CastAheadMatch.NarrowByEnabled(track.candidates, isDisabled) == 0 then
                if CastAheadTimeline then CastAheadTimeline.Cancel(track) end
                state.tracks[key] = nil
            else
                -- Sync both ways: a switched-off timeline or an unimportant
                -- cast is cancelled, a re-enabled one is put back.
                SyncTimeline(track)
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
    for state, frame in pairs(CastAheadCore.SampleStates) do
        CastAheadCore.ShowSampleRow(state, frame)
    end
end

-- /ca hide: drop everything we draw. If an icon survives this, it is not
-- ours - which is worth knowing before hunting for a bug in this addon.
function CastAheadCore.HideAll()
    if CastAheadSetup and CastAheadSetup.Active() then CastAheadSetup.Leave() end
    StopTest(true)
    HideCenter()
    for unit in pairs(plates) do
        DropUnit(unit)
    end
    print("|cff33ff99CastAhead|r all icons cleared - anything still on screen belongs to another addon")
end
