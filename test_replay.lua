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
-- Whether the cast in flight has a target, taken from the log's cast result.
local targets = {}
UnitShouldDisplaySpellTargetName = function(unit) return targets[unit] end
-- Classification, lieutenant flag and creature family per plate, from the
-- creature's own Traits.lua row: the game shows them, and a constant here
-- dropped the true spell at the traits step on creatures the game tells apart.
local npcs = {}
local function TraitRow(unit)
    for _, row in ipairs(CastAheadTraits and CastAheadTraits[currentInstance] or {}) do
        if row.npc == npcs[unit] then return row end
    end
end
UnitClassification = function(unit)
    local row = TraitRow(unit)
    return row and row.elite == false and "normal" or "elite"
end
UnitIsLieutenant = function(unit)
    local row = TraitRow(unit)
    return row and row.lieutenant or false
end
UnitCreatureFamily = function(unit)
    local row = TraitRow(unit)
    return row and row.family and "Beast" or nil
end

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
if os.getenv("CA_FIRST_CHANNEL") == "0" then
    CastAheadCore.Tuning.firstChannel = false
    knobs[#knobs + 1] = "firstChannel=off"
end
if os.getenv("CA_CLAIM_WINDOW") then
    CastAheadCore.Tuning.claimWindow = tonumber(os.getenv("CA_CLAIM_WINDOW"))
    knobs[#knobs + 1] = "claimWindow=" .. os.getenv("CA_CLAIM_WINDOW")
end
if os.getenv("CA_LATE_MAX") then
    CastAheadCore.Tuning.lateClaimMax = tonumber(os.getenv("CA_LATE_MAX"))
    knobs[#knobs + 1] = "lateClaimMax=" .. os.getenv("CA_LATE_MAX")
end
if os.getenv("CA_CLAIM_MARGIN") then
    CastAheadCore.Tuning.claimMargin = tonumber(os.getenv("CA_CLAIM_MARGIN"))
    knobs[#knobs + 1] = "claimMargin=" .. os.getenv("CA_CLAIM_MARGIN")
end
if os.getenv("CA_TARGET") == "0" then
    CastAheadCore.Tuning.targetNarrow = false
    knobs[#knobs + 1] = "targetNarrow=off"
end
if os.getenv("CA_OBSERVED_BELOW") == "0" then
    CastAheadCore.Tuning.observedBelowOnly = false
    knobs[#knobs + 1] = "observedBelowOnly=off"
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
local WATCH = tonumber(os.getenv("CA_WATCH") or "")

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
local startRight, startWrong, startWrongPairs = 0, 0, {}
local voicedRight, voicedWrong, voicedWrongPairs = 0, 0, {}
local startsBySpell = {}   -- truth spell -> { n, right, wrong } over every start, finished or not
local cutChannels = 0

local function bump(t, key) t[key] = (t[key] or 0) + 1 end

-- CA_TRACE=<spellID> prints the plate's tracks as each start of that spell
-- arrives: which predictions existed and how far from now they pointed.
local TRACE = tonumber(os.getenv("CA_TRACE") or "")

local function traceStart(unit, spell, channel)
    if TRACE ~= spell then return end
    print(string.format("\nTRACE %d %s on %s at %.1f", spell, channel and "channel" or "cast", unit, now))
    for _, track in pairs(CastAheadCore.Tracks(unit) or {}) do
        local ids = {}
        for _, c in ipairs(track.candidates or {}) do ids[#ids + 1] = tostring(c.spell) end
        print(string.format("   track %-28s channel %-5s next %s", table.concat(ids, " "), tostring(track.channel == true),
            track.nextAt and string.format("%+.1f", track.nextAt - now) or "-"))
    end
end

local function judgeStart(unit, spell, instance)
    local tally = startsBySpell[spell] or { n = 0, right = 0, wrong = 0 }
    startsBySpell[spell] = tally
    tally.n = tally.n + 1
    local claim = CastAheadCore.Casting(unit)
    if not (claim and claim.row) then return end
    local truth = tabled[instance] and tabled[instance][spell]
    names[claim.row.spell] = claim.row.name
    if truth then names[spell] = truth.name end
    if truth and (claim.row.spell == spell
        or CastAheadMatch.Advice(truth) == CastAheadMatch.Advice(claim.row)) then
        startRight = startRight + 1
        tally.right = tally.right + 1
    else
        startWrong = startWrong + 1
        tally.wrong = tally.wrong + 1
        bump(startWrongPairs, spell .. " -> " .. claim.row.spell)
    end
    local said = CastAheadMatch.AnyImportant(claim.candidates)
        and CastAheadMatch.ConsensusAdvice(claim.candidates)
    if said then
        if truth and said == CastAheadMatch.Advice(truth) then
            voicedRight = voicedRight + 1
        else
            voicedWrong = voicedWrong + 1
            bump(voicedWrongPairs, spell .. " -> " .. claim.row.spell)
        end
    end
end

local CHANNELS = os.getenv("CA_CHANNELS") ~= "0"
if not CHANNELS then print("knobs: follow-up channels off") end
local CUT = tonumber(os.getenv("CA_CUT") or "")
if CUT then
    math.randomseed(1)
    print("knobs: " .. CUT .. " of follow-up channels cut short")
end
local channels = {}

local function score(unit, spell, instance, d, lost)
    local row = tabled[instance] and tabled[instance][spell]
    if row then names[spell] = row.name end
    local candidates = CastAheadCore.LastCandidates(unit)
    d.casts = d.casts + 1
    local verdict
    if not row then
        verdict = "untabled"
        bump(untabledSpells, spell)
    elseif lost or not candidates or #candidates == 0 then
        verdict = "none"
        bump(missed, spell)
    elseif #candidates == 1 then
        if candidates[1].spell == spell then
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
                bump(wrongPairs, spell .. " -> " .. candidates[1].spell)
                bump(blamed, blame(unit, spell))
                -- CA_WATCH=<spellID> prints every narrowing step of the
                -- casts that spell was called wrong on, so a handful of
                -- wrong calls can be read one by one instead of as a
                -- tally.
                if WATCH == spell then
                    print(string.format("\nWATCH %d (%s) called as %d (%s), plate %s",
                        spell, tostring(row and row.name), candidates[1].spell,
                        tostring(candidates[1].name), tostring(unit)))
                    for _, entry in ipairs(steps[unit] or {}) do
                        local ids = {}
                        for id in pairs(entry.has) do ids[#ids + 1] = id end
                        table.sort(ids)
                        print(string.format("   %-10s %2d left  %s%s",
                            entry.step, entry.n, table.concat(ids, " "),
                            entry.has[spell] and "" or "   <- truth gone"))
                    end
                end
            end
        end
    else
        verdict = "ambiguous"
        bump(missed, spell)
        if CastAheadMatch.ConsensusAdvice(candidates) then
            ambiguousAgree = ambiguousAgree + 1
        elseif CastAheadMatch.SplitAdvice(candidates) then
            ambiguousSplit = ambiguousSplit + 1
        end
        local sameNpc, hit = true, false
        for i = 1, #candidates do
            if candidates[i].npc ~= candidates[1].npc then sameNpc = false end
            if candidates[i].spell == spell then hit = true end
        end
        if sameNpc then ambiguousSameNpc = ambiguousSameNpc + 1 end
        if not hit then ambiguousMiss = ambiguousMiss + 1 end
    end
    totals[verdict] = totals[verdict] + 1
    d[verdict] = d[verdict] + 1
end

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
    local function endChannels(upTo, only)
        while true do
            local unit, due
            for u, pending in pairs(channels) do
                if (not only or u == only) and pending.at <= upTo
                    and (not due or pending.at < due.at or (pending.at == due.at and u < unit)) then
                    unit, due = u, pending
                end
            end
            if not due then return end
            channels[unit] = nil
            now = math.max(now, math.min(due.at, upTo))
            fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
            score(unit, due.spell, run.instance, d)
        end
    end
    for _, ev in ipairs(run.events) do
        endChannels(base + ev.t)
        now = base + ev.t
        local unit = ev.u and ("nameplate" .. ev.u)
        local settling
        if unit and channels[unit] and ev.e == "START" then
            settling, channels[unit] = channels[unit].spell, nil
        elseif unit and channels[unit] and (ev.e == "KICK" or ev.e == "FAIL") then
            local pending = channels[unit]
            channels[unit] = nil
            fire("UNIT_SPELLCAST_CHANNEL_STOP", unit, nil, nil, "kicker")
            score(unit, pending.spell, run.instance, d)
            settling = "kicked"
        elseif unit and channels[unit] and ev.e == "REMOVE" then
            score(unit, channels[unit].spell, run.instance, d, true)
            channels[unit] = nil
        elseif ev.e == "ENC" then
            for u, pending in pairs(channels) do score(u, pending.spell, run.instance, d, true) end
            for u in pairs(channels) do channels[u] = nil end
        end
        if ev.e == "ENC" then
            fire(ev.on and "ENCOUNTER_START" or "ENCOUNTER_END", 1)
        elseif ev.e == "ADD" then
            hostile[unit], combat[unit], dead[unit] = true, true, nil
            levels[unit] = ev.level
            powers[unit] = ev.power or 0
            npcs[unit] = ev.npc
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
            targets[unit] = ev.target
            traceStart(unit, ev.spell, false)
            fire("UNIT_SPELLCAST_START", unit)
            if settling and settling ~= "kicked" then score(unit, settling, run.instance, d) end
            judgeStart(unit, ev.spell, run.instance)
            -- The game says whether the cast can be kicked a moment after it
            -- starts; the extractor took the answer from MDT.
            if ev.kick == true then
                fire("UNIT_SPELLCAST_INTERRUPTIBLE", unit)
            elseif ev.kick == false then
                fire("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", unit)
            end
        elseif ev.e == "CHAN" then
            open[unit] = nil
            targets[unit] = nil
            traceStart(unit, ev.spell, true)
            fire("UNIT_SPELLCAST_CHANNEL_START", unit)
            judgeStart(unit, ev.spell, run.instance)
        elseif ev.e == "CHANEND" then
            fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
            if ev.full then
                score(unit, ev.spell, run.instance, d)
            else
                cutChannels = cutChannels + 1
            end
        elseif settling == "kicked" then
            open[unit] = nil
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
            local row = tabled[run.instance] and tabled[run.instance][ev.spell]
            if CHANNELS and row and row.follow and not row.channel then
                fire("UNIT_SPELLCAST_CHANNEL_START", unit)
                fire("UNIT_SPELLCAST_STOP", unit)
                local length = row.follow
                if CUT and math.random() < CUT then length = length * (0.1 + 0.8 * math.random()) end
                channels[unit] = { at = now + length, spell = ev.spell }
            else
                fire("UNIT_SPELLCAST_STOP", unit)
                score(unit, ev.spell, run.instance, d)
            end
        end
        if updateHandler then updateHandler() end
    end
    endChannels(math.huge)
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
print("")
print(string.format("claimed at cast start: %d with the right call, %d with a wrong one", startRight, startWrong))
print(string.format("  (%d pure channels cut short, judged at their start only)", cutChannels))
-- CA_SPELLS=<id,id,...> lists those spells' starts, finished or not.
for id in (os.getenv("CA_SPELLS") or ""):gmatch("%d+") do
    local tally = startsBySpell[tonumber(id)] or { n = 0, right = 0, wrong = 0 }
    print(string.format("  start %-8s %-24s starts %3d  right %3d  wrong %3d  unclaimed %3d", id,
        tostring(names[tonumber(id)]), tally.n, tally.right, tally.wrong, tally.n - tally.right - tally.wrong))
end
top(startWrongPairs, 12, "wrong calls at cast start, most frequent first:")
print(string.format("voiced at cast start: %d right, %d wrong", voicedRight, voicedWrong))
top(voicedWrongPairs, 12, "wrong voiced calls at cast start, most frequent first:")
