-- Replays real fights through the real matcher and scores what it decided.
--
-- The addon only ever sees cast bars starting and stopping on nameplate units
-- and a level; tools/replay_extract.py pulls exactly that out of our combat
-- logs, together with the truth. Every completed cast is then judged:
--
--   correct    one candidate, and it is the spell that was really cast
--   wrong      one candidate, some other spell - the call the player heard was wrong
--   ambiguous  several candidates (the icon shows "?" and no call is made)
--   none       nothing matched - silent
--   untabled   the real spell is not in Data.lua for this dungeon at all,
--              so the matcher never had a chance; listed apart from its errors
--
-- Run from the CastAhead folder:
--   lua test_replay.lua ../CastAheadTools/replay.lua
--
-- Data.lua, Priority.lua and Traits.lua are the shipped ones, not fixtures.

local replayPath = arg and arg[1] or "../CastAheadTools/replay.lua"
-- A second argument swaps the cast table, so two builds of Data.lua can be
-- scored against the same fights.
local dataPath = arg and arg[2] or "Data.lua"

-- The WoW stubs are test_core.lua's, loaded from its source so there is one
-- copy to maintain. Its state lives in locals there; the handful the replay
-- has to drive are turned into globals before the chunk runs.
local source = assert(io.open("test_core.lua")):read("*a")
local stubs = source:sub(1, assert(source:find("%-%- Data the addon will match against%.")) - 1)
-- Declarations that share a line are handled by name, before the generic pass.
stubs = stubs:gsub("\nlocal eventHandler, updateHandler\n", "\neventHandler, updateHandler = nil, nil\n")
stubs = stubs:gsub("\nlocal framesMade, shownCount = 0, 0", "\nlocal framesMade = 0\nshownCount = 0")
stubs = stubs:gsub("\nlocal combat, hostile, dead = {}, {}, {}", "\ncombat, hostile, dead = {}, {}, {}")
for _, name in ipairs({ "now", "levels", "allFrames" }) do
    local n
    stubs, n = stubs:gsub("\nlocal " .. name .. " = ", "\n" .. name .. " = ")
    assert(n == 1, name .. " declaration not found in test_core.lua stubs")
end
local chunk, err = (loadstring or load)(stubs, "test_core stubs")
assert(chunk, err)
chunk()

-- The dungeon changes per run.
local currentInstance = 0
IsInInstance = function() return true end
GetInstanceInfo = function() return "d", "party", 0, "", 0, 0, false, currentInstance end
-- Power type per plate, from the log: it is what Traits.lua uses to tell two
-- same-level creatures apart, so a constant here would blame the matcher for
-- confusions the game never has.
local powers = {}
UnitPowerType = function(unit) return powers[unit] or 0 end

dofile("Config.lua")
dofile(dataPath)
dofile("Priority.lua")
dofile("Traits.lua")
dofile("Packs.lua")
dofile("Match.lua")
dofile("Timeline.lua")
UISpecialFrames = {}
SlashCmdList = {}
SearchBoxTemplate_OnTextChanged = function() end
GameTooltip = setmetatable({}, { __index = function() return function() end end })
GameTooltip_Hide = function() end
dofile("UI.lua")
dofile("Core.lua")
dofile(replayPath)

local function fire(event, ...) eventHandler(nil, event, ...) end

-- Matcher knobs for A/B runs, from the environment. Unset means shipped.
local knobs = {}
if os.getenv("CA_FIRST_TOL") then
    CastAheadMatch.FIRST_TOLERANCE = tonumber(os.getenv("CA_FIRST_TOL"))
    knobs[#knobs + 1] = "FIRST_TOLERANCE=" .. CastAheadMatch.FIRST_TOLERANCE
end
if os.getenv("CA_TRAITS") == "0" then
    CastAheadCore.Tuning.traitsNarrow = false
    knobs[#knobs + 1] = "traitsNarrow=off"
end
if os.getenv("CA_TRUST") == "0" then
    CastAheadCore.Tuning.trustUnsureTrack = false
    knobs[#knobs + 1] = "trustUnsureTrack=off"
end
if os.getenv("CA_POP") == "0" then
    CastAheadCore.Tuning.population = false
    knobs[#knobs + 1] = "population=off"
end
if os.getenv("CA_PACKS") == "0" then
    CastAheadCore.Tuning.packsNarrow = false
    CastAheadCore.Tuning.packsCompany = false
    knobs[#knobs + 1] = "packs=off"
end
if os.getenv("CA_PACKS_NARROW") == "0" then
    CastAheadCore.Tuning.packsNarrow = false
    knobs[#knobs + 1] = "packsNarrow=off"
end
if os.getenv("CA_PACKS_COMPANY") == "0" then
    CastAheadCore.Tuning.packsCompany = false
    knobs[#knobs + 1] = "packsCompany=off"
end
if #knobs > 0 then print("knobs: " .. table.concat(knobs, ", ")) end

-- The narrowing steps of the cast currently being resolved, per unit.
local steps = {}
CastAheadCore.SetTrace(function(unit, step, candidates)
    local list = steps[unit]
    if not list then list = {} steps[unit] = list end
    local ids = {}
    for i = 1, #candidates do ids[candidates[i].spell] = true end
    list[#list + 1] = { step = step, has = ids, n = #candidates }
end)

-- Which step first dropped the real spell, or where it never was.
local function blame(unit, truth)
    local list = steps[unit] or {}
    local previous
    for _, entry in ipairs(list) do
        if not entry.has[truth] then
            return previous and (previous .. " > " .. entry.step) or ("never: " .. entry.step)
        end
        previous = entry.step
    end
    return "kept to the end"
end
local blamed = {}          -- "pair | step" -> count

-- Which spells Data.lua knows per dungeon, so "untabled" can be told apart.
local tabled = {}
for instance, rows in pairs(CastAheadData) do
    tabled[instance] = {}
    for _, row in ipairs(rows) do tabled[instance][row.spell] = row end
end
for instance, rows in pairs(CastAheadExtra or {}) do
    tabled[instance] = tabled[instance] or {}
    for _, row in ipairs(rows) do tabled[instance][row.spell] = row end
end

local totals = { correct = 0, harmless = 0, wrong = 0, ambiguous = 0, none = 0, untabled = 0 }
local untabledSpells = {}  -- truth spells Data.lua does not carry
local open = {}            -- unit -> the spell whose START the matcher saw
local unpaired = 0
local ambiguousAgree, ambiguousSameNpc, ambiguousMiss, ambiguousSplit = 0, 0, 0, 0
local perDungeon = {}
local wrongPairs = {}      -- "truth -> guess" -> count
local missed = {}          -- truth spell -> count of none/ambiguous
local names = {}

local function bump(t, key) t[key] = (t[key] or 0) + 1 end

for _, run in ipairs(CastAheadReplay) do
    currentInstance = run.instance
    local d = perDungeon[run.name]
    if not d then
        d = { correct = 0, harmless = 0, wrong = 0, ambiguous = 0, none = 0, untabled = 0, casts = 0 }
        perDungeon[run.name] = d
    end
    now = 100000
    for k in pairs(hostile) do hostile[k] = nil end
    for k in pairs(combat) do combat[k] = nil end
    for k in pairs(dead) do dead[k] = nil end
    for k in pairs(levels) do levels[k] = nil end
    fire("PLAYER_ENTERING_WORLD")
    fire("CHALLENGE_MODE_START")
    local base = now
    for _, ev in ipairs(run.events) do
        now = base + ev.t
        local unit = ev.u and ("nameplate" .. ev.u)
        if ev.e == "ENC" then
            fire(ev.on and "ENCOUNTER_START" or "ENCOUNTER_END", 1)
        elseif ev.e == "ADD" then
            hostile[unit], combat[unit], dead[unit] = true, true, nil
            levels[unit] = ev.level
            powers[unit] = ev.power or 0
            fire("NAME_PLATE_UNIT_ADDED", unit)
        elseif ev.e == "REMOVE" then
            open[unit] = nil
            if ev.dead then
                dead[unit] = true
                fire("UNIT_HEALTH", unit)
            end
            fire("NAME_PLATE_UNIT_REMOVED", unit)
            hostile[unit], combat[unit], levels[unit], powers[unit], dead[unit] = nil, nil, nil, nil, nil
        elseif ev.e == "START" then
            open[unit] = ev.spell
            fire("UNIT_SPELLCAST_START", unit)
            -- The game says whether the cast can be kicked a moment after it
            -- starts; the extractor took the answer from MDT.
            if ev.kick == true then
                fire("UNIT_SPELLCAST_INTERRUPTIBLE", unit)
            elseif ev.kick == false then
                fire("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", unit)
            end
        elseif ev.e == "KICK" then
            open[unit] = nil
            fire("UNIT_SPELLCAST_INTERRUPTED", unit)
            fire("UNIT_SPELLCAST_STOP", unit)
        elseif ev.e == "FAIL" then
            open[unit] = nil
            fire("UNIT_SPELLCAST_FAILED", unit)
            fire("UNIT_SPELLCAST_STOP", unit)
        elseif ev.e == "STOP" and open[unit] ~= ev.spell then
            -- A STOP whose START the matcher never saw carries no verdict of its
            -- own; scoring it would read the previous occupant's result.
            unpaired = unpaired + 1
            fire("UNIT_SPELLCAST_STOP", unit)
        elseif ev.e == "STOP" then
            open[unit] = nil
            steps[unit] = nil
            fire("UNIT_SPELLCAST_STOP", unit)
            local row = tabled[run.instance] and tabled[run.instance][ev.spell]
            if row then names[ev.spell] = row.name end
            local candidates = CastAheadCore.LastCandidates(unit)
            d.casts = d.casts + 1
            local verdict
            if not row then
                verdict = "untabled"
                bump(untabledSpells, ev.spell)
            elseif not candidates or #candidates == 0 then
                verdict = "none"
                bump(missed, ev.spell)
            elseif #candidates == 1 then
                if candidates[1].spell == ev.spell then
                    verdict = "correct"
                else
                    -- The player hears a call, not a spell ID: a wrong row that
                    -- carries the same call (two AOEs, two kicks) does no harm.
                    local said = CastAheadMatch.Advice(candidates[1])
                    local meant = CastAheadMatch.Advice(row)
                    if said and meant and said == meant then
                        verdict = "harmless"
                    else
                        verdict = "wrong"
                        names[candidates[1].spell] = candidates[1].name
                        bump(wrongPairs, ev.spell .. " -> " .. candidates[1].spell)
                        bump(blamed, blame(unit, ev.spell))
                    end
                end
            else
                verdict = "ambiguous"
                bump(missed, ev.spell)
                if CastAheadMatch.ConsensusAdvice(candidates) then
                    ambiguousAgree = ambiguousAgree + 1
                elseif CastAheadMatch.SplitAdvice(candidates) then
                    ambiguousSplit = ambiguousSplit + 1
                end
                local sameNpc, hit = true, false
                for i = 1, #candidates do
                    if candidates[i].npc ~= candidates[1].npc then sameNpc = false end
                    if candidates[i].spell == ev.spell then hit = true end
                end
                if sameNpc then ambiguousSameNpc = ambiguousSameNpc + 1 end
                if not hit then ambiguousMiss = ambiguousMiss + 1 end
            end
            totals[verdict] = totals[verdict] + 1
            d[verdict] = d[verdict] + 1
        end
        if updateHandler then updateHandler() end
    end
end

local judged = totals.correct + totals.harmless + totals.wrong + totals.ambiguous + totals.none
local function pct(n, of) return of > 0 and string.format("%3.0f%%", 100 * n / of) or "  - " end

print(string.format("%d completed trash casts replayed, %d of them on spells the table knows",
    judged + totals.untabled, judged))
print(string.format("  correct   %5d  %s", totals.correct, pct(totals.correct, judged)))
print(string.format("  harmless  %5d  %s   (wrong row, same call)", totals.harmless, pct(totals.harmless, judged)))
print(string.format("  wrong     %5d  %s   <- a wrong call was made", totals.wrong, pct(totals.wrong, judged)))
print(string.format("  ambiguous %5d  %s   (icon shows ?, no call)", totals.ambiguous, pct(totals.ambiguous, judged)))
print(string.format("  none      %5d  %s   (silent)", totals.none, pct(totals.none, judged)))
print(string.format("  untabled  %5d        real spell absent from Data.lua", totals.untabled))
print(string.format("  (%d STOPs without a START seen were not scored)", unpaired))
print(string.format("  ambiguous, broken down: %d agree on the call (so it IS announced), "
    .. "%d are shown as two calls, %d are one creature at one cast length, %d do not even contain the truth",
    ambiguousAgree, ambiguousSplit, ambiguousSameNpc, ambiguousMiss))
print("")
print("per dungeon (correct+harmless / wrong / ambiguous / none / untabled):")
local dungeonNames = {}
for name in pairs(perDungeon) do dungeonNames[#dungeonNames + 1] = name end
table.sort(dungeonNames)
for _, name in ipairs(dungeonNames) do
    local d = perDungeon[name]
    local known = d.correct + d.harmless + d.wrong + d.ambiguous + d.none
    local fine = d.correct + d.harmless
    print(string.format("  %-22s %4d / %3d / %3d / %3d / %3d   right call %s of known",
        name, fine, d.wrong, d.ambiguous, d.none, d.untabled, pct(fine, known)))
end

local function top(t, n, label)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return t[a] > t[b] end)
    print("")
    print(label)
    for i = 1, math.min(n, #keys) do
        local k = keys[i]
        local truth, guess = tostring(k):match("^(%d+) %-> (%d+)$")
        if truth then
            print(string.format("  %4d x  %s (%d) called as %s (%d)", t[k],
                names[tonumber(truth)] or "?", truth, names[tonumber(guess)] or "?", guess))
        else
            print(string.format("  %4d x  %s (%s)", t[k], names[tonumber(k)] or "?", tostring(k)))
        end
    end
end
top(wrongPairs, 12, "wrong calls, most frequent first:")
top(blamed, 10, "where the real spell was lost (step before > step that dropped it):")
top(missed, 12, "left unidentified (ambiguous or none), most frequent first:")
top(untabledSpells, 12, "cast but absent from Data.lua, most frequent first:")
