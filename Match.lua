-- Spell identification, kept free of WoW API so it can be tested standalone.
--
-- Cooldowns are rotations: cd = { 4.8, 4.8, 8.7 } means the gaps between casts
-- cycle through those values. Which slot a mob is on is only known once it has
-- shown us an interval, so before that every slot is a possible match.

CastAheadMatch = {
    CAST_TOLERANCE = 0.25,   -- how far a measured cast time may drift
    -- Event delivery jitter is a few tenths of a second, so the interval match
    -- is mostly absolute; the relative term only covers long cooldowns, where
    -- the table's own median is less exact.
    CD_TOLERANCE_FLAT = 1.0,
    CD_TOLERANCE_REL = 0.05,
    -- Time from engage to first cast varies with how fast the pull is walked
    -- into, so this is the loosest of the three. 4.0 was measured on 115 real
    -- runs (ours and public): against 2.5 it resolved 2-3 points more casts
    -- for a fraction of a point of wrong calls, while 6.0 doubled the wrong
    -- calls on public logs.
    FIRST_TOLERANCE = 4.0,
}

local M = CastAheadMatch

-- What the group is expected to do about a cast, read off what groups actually
-- did in the logs: how often it got interrupted, how often it died to something
-- else (a stun, a knock), how many people it hit and for what share of health.
M.KICK_SHARE = 0.25
M.CC_SHARE = 0.25
M.AOE_TARGETS = 3
M.HEAVY_DAMAGE = 0.20      -- share of health that makes group damage notable
M.HEAVY_SINGLE = 0.15      -- single-target hits are mitigated harder

-- `say` is spoken aloud by the addon; it has to name the response, not the
-- spell, because that is what the player has to decide in the moment.
M.ADVICE = {
    KICK = { label = "KICK", say = "interrupt", r = 1.00, g = 0.20, b = 0.20 },
    CC   = { label = "STUN", say = "stun", r = 0.70, g = 0.40, b = 1.00 },
    -- One target taking a large hit and the whole group taking one call for
    -- different answers - a personal cooldown versus everyone reacting - so
    -- they are separate verdicts rather than one "defensive".
    -- `plate` is the label as it appears under a nameplate icon, where width
    -- is the scarce thing: the icons step sideways by the width of the words
    -- under them, so the longest verdict pushed every one of its neighbours
    -- away. The table and the voice keep the whole word.
    --
    -- "BUSTER" rather than "TANK": the same four characters saved, and it
    -- still reads as the threat rather than as a role assignment. Stacking it
    -- over two lines was tried and is strictly worse - a two-line label is as
    -- wide as its longest line, which is "BUSTER" either way, for twice the
    -- height.
    TANK = { label = "TANKBUSTER", plate = "BUSTER", say = "tank buster", r = 1.00, g = 0.45, b = 0.10 },
    AOE  = { label = "AOE", say = "aoe damage", r = 1.00, g = 0.75, b = 0.15 },
    -- Categories assigned by the curated priority set (row.prio).
    DODGE   = { label = "DODGE", say = "dodge", r = 0.30, g = 0.90, b = 0.40 },
    FRONTAL = { label = "FRONT", say = "frontal", r = 0.95, g = 0.90, b = 0.30 },
    -- "Targets a player" - not necessarily you: the cast target is Secret in
    -- 12.1, so nobody (the source curation included) can tell whose it is.
    TARGET  = { label = "TARGETED", say = "targeted", r = 0.95, g = 0.35, b = 0.95 },
    DISPEL  = { label = "DISPEL", say = "dispel", r = 0.40, g = 0.80, b = 1.00 },
    -- Dispels by school: the voice line has to say whose job it is.
    POISON  = { label = "POISON", say = "dispel poison", r = 0.45, g = 0.90, b = 0.30 },
    CURSE   = { label = "CURSE", say = "dispel curse", r = 0.70, g = 0.35, b = 0.95 },
    MAGIC   = { label = "MAGIC", say = "dispel magic", r = 0.35, g = 0.65, b = 1.00 },
    SOOTHE  = { label = "SOOTHE", say = "soothe enrage", r = 1.00, g = 0.60, b = 0.60 },
    PURGE   = { label = "PURGE", say = "purge buff", r = 0.55, g = 0.85, b = 1.00 },
    DISEASE = { label = "DISEASE", say = "dispel disease", r = 0.75, g = 0.65, b = 0.30 },
    -- Nothing removes a bleed; the call is the defensive, not the dispel.
    BLEED   = { label = "BLEED", say = "bleed, defensive", r = 0.90, g = 0.25, b = 0.25 },
    SWITCH  = { label = "SWITCH", say = "switch target", r = 0.85, g = 0.85, b = 0.85 },
    ALERT   = { label = "WATCH", say = "danger", r = 1.00, g = 1.00, b = 1.00 },
}
-- Each verdict knows its own key: the voice clip on disk is named after it
-- (Sounds/<lang>/<key>.ogg), and labels with spaces ("ON YOU") are not file
-- names.
for key, advice in pairs(M.ADVICE) do
    advice.key = key
    advice.file = key:gsub(" ", "_")
    -- Only the verdicts long enough to crowd their neighbours carry a `plate`
    -- of their own; the rest read the same in both places.
    advice.plate = advice.plate or advice.label
end
M.ADVICE.SAVE = M.ADVICE.TANK   -- old name, kept so saved settings still resolve

-- A curated category (row.prio) wins outright. Below that, `interruptible` is
-- what the game said about the cast happening right now and overrides the
-- statistics, since a mob can be immune this pull.
--
-- Otherwise `row.kickable` decides, and that comes from MDT - a fact about the
-- spell, not a tally of how often a group managed to kick it. The tally used to
-- decide, and it labelled an uninterruptible cast KICK because a boss spell with
-- the same cast time had been kicked a lot.
-- What the game told us a cast leaves on the player, learned in play: the
-- player's own auras are not Secret, so the first time a curated "targeted"
-- cast lands a Poison the call becomes "dispel poison" from then on.
-- "Bleed" is a dispel type of its own since 11.0, so the game does name it.
M.DISPEL_CATEGORY = { Magic = "MAGIC", Poison = "POISON", Curse = "CURSE", Disease = "DISEASE", Bleed = "BLEED" }
local REFINABLE = { TARGET = true, ALERT = true, DISPEL = true }

function M.Advice(row, interruptible)
    if not row then return nil end
    if row.prio and REFINABLE[row.prio] and row.dispel and M.DISPEL_CATEGORY[row.dispel] then
        return M.ADVICE[M.DISPEL_CATEGORY[row.dispel]]
    end
    -- A curated category beats anything derived from statistics: the priority
    -- set is a human saying what this cast is, ours is a guess from tallies.
    -- The one exception is a KICK the game just declared uninterruptible -
    -- this pull it cannot be kicked, whatever the preset says.
    if row.prio and M.ADVICE[row.prio]
        and not (row.prio == "KICK" and interruptible == false) then
        return M.ADVICE[row.prio]
    end
    if interruptible == true then
        return M.ADVICE.KICK
    end
    if interruptible ~= false and row.kickable then
        return M.ADVICE.KICK
    end
    -- Not kickable: a stun or other control is the way to stop it, if the logs
    -- show the group stopping it at all.
    if not row.kickable and (row.cc or 0) >= M.CC_SHARE then
        return M.ADVICE.CC
    end
    if (row.hits or 0) >= M.AOE_TARGETS and (row.dmg or 0) >= M.HEAVY_DAMAGE then
        return M.ADVICE.AOE
    end
    if (row.dmg or 0) >= M.HEAVY_SINGLE then
        return M.ADVICE.TANK
    end
    return nil
end

M.MIN_OPENING_SAMPLES = 3

-- The opening delay is the loosest number in the table, so a thin one is worse
-- than none: Primal Juggernaut's rested on a single sample and claimed 17.8s
-- for a cast that lands in a couple of seconds.
function M.HasOpening(row)
    return row and row.first ~= nil and (row.firstN or 0) >= M.MIN_OPENING_SAMPLES
end

-- Spells on a short cycle, or seen only once per pull, get no countdown: the
-- bar only names them while they are being cast.
function M.HasSchedule(row)
    return row and not row.filler and row.cd and #row.cd > 0
end

-- Advice is only safe to show when every remaining candidate agrees. Six spells
-- share a 2.5s cast in Ruby Life Pools; taking the first one's verdict once told
-- the player to kick Primal Juggernaut's uninterruptible Crushing Smash.
function M.ConsensusAdvice(candidates, interruptible)
    if not candidates or #candidates == 0 then return nil end
    local first = M.Advice(candidates[1], interruptible)
    for i = 2, #candidates do
        if M.Advice(candidates[i], interruptible) ~= first then
            return nil
        end
    end
    return first
end

-- When the candidates disagree, the distinct calls they would make, in a
-- stable order - "KICK / DODGE" is still worth more to the player than a
-- blank: they know something is coming and which two answers are on the
-- table. Nil when there is agreement (ConsensusAdvice covers that) or when
-- nothing here has a call at all.
function M.SplitAdvice(candidates, interruptible)
    if not candidates or #candidates < 2 then return nil end
    local seen, out = {}, {}
    for i = 1, #candidates do
        local advice = M.Advice(candidates[i], interruptible)
        if advice and not seen[advice] then
            seen[advice] = true
            out[#out + 1] = advice
        end
    end
    if #out < 2 then return nil end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

-- Which candidate to name while several are still possible: the one seen most
-- often, rather than whichever happened to sort first.
function M.BestGuess(candidates)
    local best
    for i = 1, #candidates do
        if not best or (candidates[i].n or 0) > (best.n or 0) then
            best = candidates[i]
        end
    end
    return best
end

local function IntervalMatches(cd, interval)
    return math.abs(cd - interval) <= M.CD_TOLERANCE_FLAT + cd * M.CD_TOLERANCE_REL
end

-- Rotation slot to use for the cast after `index` casts, 1-based and cycling.
function M.CDAt(row, index)
    local cd = row.cd
    if not cd or #cd == 0 then return nil end
    index = tonumber(index) or 1
    return cd[(index - 1) % #cd + 1]
end

-- Which slot an observed interval fits, or nil. Used to line the rotation up
-- with where the mob actually is.
--
-- `expected` is the slot we thought was due, and it is tried first on purpose:
-- a rotation like {4.8, 4.8, 8.7} has two identical slots, and always taking
-- the first match would pin the mob to slot 1 forever and never predict the 8.7.
function M.SlotForInterval(row, interval, expected)
    if not row.cd or #row.cd == 0 then return nil end
    expected = tonumber(expected)
    if expected then
        local slot = (expected - 1) % #row.cd + 1
        if IntervalMatches(row.cd[slot], interval) then
            return slot
        end
    end
    for i = 1, #row.cd do
        if IntervalMatches(row.cd[i], interval) then
            return i
        end
    end
    return nil
end

-- Every spell in the dungeon whose length matches what we just measured.
-- `channel` says which kind was measured: a channel and a cast of the same
-- length are different abilities and never match each other.
function M.ByCastTime(rows, duration, channel)
    local out = {}
    if type(rows) ~= "table" then return out end
    local wantChannel = channel == true
    for i = 1, #rows do
        local row = rows[i]
        if (row.channel == true) == wantChannel
            and math.abs(row.cast - duration) <= M.CAST_TOLERANCE then
            out[#out + 1] = row
        end
    end
    return out
end

-- The interval a mob actually showed us separates candidates that share a cast
-- time. If nothing matches, the observation was off (interrupt, lag) - keep the
-- candidates rather than throwing the identification away.
function M.NarrowByInterval(candidates, interval)
    local out = {}
    for i = 1, #candidates do
        if M.SlotForInterval(candidates[i], interval) then
            out[#out + 1] = candidates[i]
        end
    end
    return #out > 0 and out or candidates
end

-- Time from the mob entering combat to this cast. Separates candidates on the
-- very first cast, before any interval exists - Sand-Sworn Rider opens at 20.6s
-- where Corrupted Guardian opens at 3.5s.
function M.NarrowByFirst(candidates, elapsed)
    if not elapsed then return candidates end
    -- A row with no opening data is dropped when a rival fits the window. That
    -- reads harsh, and the gentler rule (keep the unknowns) was measured on 115
    -- real runs: it resolved 1.5 points fewer casts and removed no wrong calls.
    -- Rows without an opening are the rarely seen ones, and rarely seen is
    -- itself evidence against them.
    local out = {}
    for i = 1, #candidates do
        local first = M.HasOpening(candidates[i]) and candidates[i].first or nil
        if first and math.abs(first - elapsed) <= M.FIRST_TOLERANCE then
            out[#out + 1] = candidates[i]
        end
    end
    return #out > 0 and out or candidates
end

-- A tank buster is nobody's call but the tank's and the healer's; the other
-- role-blind categories (kicks, dodges, AOE, frontals) are everyone's.
M.ROLE_HIDES = {
    DAMAGER = { TANK = true },
}

-- Dispel-school categories are not a role question at all: a dps druid can
-- remove poison, a priest healer never can. Whether the character actually
-- knows a matching ability is the game's to answer, so Core supplies the
-- check; outside the game (or with the filter off) everything passes.
M.CAPABILITY_GATED = {
    DISPEL = true, POISON = true, CURSE = true, MAGIC = true, DISEASE = true,
    SOOTHE = true, PURGE = true,
}

-- Supplied by Core from the game (nil / permissive outside it or when the
-- filter is off).
M.PlayerRole = function() return nil end
M.PlayerCanHandle = function() return true end

-- "Important" means a human curated this cast into the priority set, and the
-- player can act on it. Kept as functions here so the display filter and the
-- sound gate agree on the meaning.
function M.Important(row)
    if not row.prio then return false end
    local hides = M.ROLE_HIDES[M.PlayerRole()]
    if hides and hides[row.prio] then return false end
    if M.CAPABILITY_GATED[row.prio] and not M.PlayerCanHandle(row.prio) then
        return false
    end
    return true
end

function M.AnyImportant(candidates)
    if not candidates then return false end
    for i = 1, #candidates do
        if M.Important(candidates[i]) then return true end
    end
    return false
end

function M.OnlyImportant(rows)
    local out = {}
    for i = 1, #rows do
        if M.Important(rows[i]) then out[#out + 1] = rows[i] end
    end
    return out
end

-- Spells switched off in the UI drop out entirely. Unlike the other filters
-- this one does not fall back to the full list: an empty result means the user
-- asked for no bar here.
function M.NarrowByEnabled(candidates, isDisabled)
    if type(isDisabled) ~= "function" then return candidates end
    local out = {}
    for i = 1, #candidates do
        if not isDisabled(candidates[i].spell) then
            out[#out + 1] = candidates[i]
        end
    end
    return out
end

-- UnitLevel is one of the few facts still readable off a hostile nameplate, so
-- it narrows candidates the moment a mob enters combat - before any cast. Rows
-- without a level (MDT did not list the creature) are kept rather than guessed
-- away.
function M.NarrowByLevel(candidates, level)
    if not level or level <= 0 then return candidates end
    local out = {}
    for i = 1, #candidates do
        local rowLevel = candidates[i].level
        if not rowLevel or rowLevel == level then
            out[#out + 1] = candidates[i]
        end
    end
    return #out > 0 and out or candidates
end

-- Every spell in the dungeon a creature of this level could be about to cast.
-- If they all belong to one creature, the mob is identified before it acts.
-- `needFirst` restricts it to spells with a known opening delay, which is what
-- timing an opener requires; a preview wants the creature's whole kit.
-- `strict` demands the level actually match. Elsewhere a missing level counts
-- as compatible so nothing is lost, but for identifying a mob before it acts
-- that leniency lets every unlevelled row in and the answer is always ambiguous.
function M.OpeningCandidates(rows, level, needFirst, strict)
    local out = {}
    if type(rows) ~= "table" then return out end
    for i = 1, #rows do
        local row = rows[i]
        local levelOk
        if strict then
            levelOk = level and row.level == level
        else
            levelOk = not level or not row.level or row.level == level
        end
        if levelOk and (M.HasOpening(row) or not needFirst) then
            out[#out + 1] = row
        end
    end
    return out
end

-- Every spell belonging to one creature, in the order it opens with them.
function M.SpellsOfNPC(rows, npc)
    local out = {}
    for i = 1, #rows do
        if rows[i].npc == npc then
            out[#out + 1] = rows[i]
        end
    end
    table.sort(out, function(a, b) return (a.offset or a.first or 0) < (b.offset or b.first or 0) end)
    return out
end

function M.SharedNPC(candidates)
    local npc
    for i = 1, #candidates do
        if npc and candidates[i].npc ~= npc then return nil end
        npc = candidates[i].npc
    end
    return npc
end

-- Soonest opening cast among candidates that all belong to one creature.
function M.SoonestOpening(candidates)
    local best
    for i = 1, #candidates do
        if not best or candidates[i].first < best.first then
            best = candidates[i]
        end
    end
    return best
end

-- Casts already identified on this nameplate say which creature it is, so
-- candidates belonging to a different one are dropped - even if that leaves
-- nothing. The fallback that used to keep them is how a Shivan Punisher got
-- six other creatures' 2.0s spells for a cast of its own that is not in the
-- table. The caller only passes creatures it is sure about (track.sure). This is the cheap half of what
-- a shipped trait table would provide, using nothing the game keeps Secret: the
-- npc field is a grouping key inside our own data, never queried from a unit.
function M.NarrowByMob(candidates, knownNPCs)
    if not knownNPCs or not next(knownNPCs) then return candidates end
    local out = {}
    for i = 1, #candidates do
        if knownNPCs[candidates[i].npc] then
            out[#out + 1] = candidates[i]
        end
    end
    return out
end

-- Creatures that cannot be it any more: every one MDT placed in the dungeon
-- has already been seen dying. Unlike the other narrowings this one may
-- empty the list - a cast from a creature that no longer exists was never
-- that creature's, and an empty answer is the honest one.
function M.DropNPCs(candidates, exhausted)
    if not exhausted or not next(exhausted) then return candidates end
    local out = {}
    for i = 1, #candidates do
        if not exhausted[candidates[i].npc] then
            out[#out + 1] = candidates[i]
        end
    end
    return out
end

-- Shortest upcoming cooldown among candidates: warn early rather than late.
function M.ConsensusCD(candidates, index)
    local best
    for i = 1, #candidates do
        local cd = M.HasSchedule(candidates[i]) and M.CDAt(candidates[i], index) or nil
        if cd and (not best or cd < best) then best = cd end
    end
    return best
end
