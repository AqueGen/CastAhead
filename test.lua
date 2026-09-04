-- Standalone check: lua test.lua  (no WoW, no framework)
dofile("Data.lua")
dofile("Priority.lua")
dofile("Traits.lua")
dofile("Match.lua")

local M = CastAheadMatch
local failures = 0

local function check(ok, msg)
    if not ok then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

local rows = {
    { spell = 1, npc = 10, cast = 2.5, cd = { 8.5 }, first = 3.9, firstN = 6 },
    { spell = 2, npc = 20, cast = 2.5, cd = { 29.1 }, first = 20.6, firstN = 6 },
    { spell = 3, npc = 20, cast = 4.5, cd = { 21.9, 27.9, 19.5 }, first = 6.1, firstN = 6 },
}

-- Cast time picks the field of candidates.
check(#M.ByCastTime(rows, 2.5) == 2, "cast time 2.5 should match two rows")
check(#M.ByCastTime(rows, 2.6) == 2, "cast time within tolerance should still match")
check(#M.ByCastTime(rows, 3.5) == 0, "cast time outside tolerance should match nothing")

-- A channel and a cast of the same length are different things; the caller
-- says which kind it measured and only that kind may match.
local mixed = {
    { spell = 10, npc = 1, cast = 6.0, cd = { 20 } },
    { spell = 11, npc = 1, cast = 6.0, cd = { 20 }, channel = true },
}
check(#M.ByCastTime(mixed, 6.0) == 1 and M.ByCastTime(mixed, 6.0)[1].spell == 10,
    "a measured cast matches only cast rows")
check(#M.ByCastTime(mixed, 6.0, true) == 1 and M.ByCastTime(mixed, 6.0, true)[1].spell == 11,
    "a measured channel matches only channel rows")

-- An observed interval narrows it and pins the rotation slot.
local both = M.ByCastTime(rows, 2.5)
check(#M.NarrowByInterval(both, 8.4) == 1, "an observed 8.4s interval should pick one spell")
check(M.NarrowByInterval(both, 8.4)[1].spell == 1, "and it should be the 8.5s one")
check(#M.NarrowByInterval(both, 60) == 2, "an interval matching nothing must not erase candidates")
check(M.SlotForInterval(rows[3], 27.5) == 2, "27.5s belongs to the second rotation slot")
check(M.SlotForInterval(rows[3], 40) == nil, "an interval in no slot returns nil")

-- The rotation cycles, so slot 4 is slot 1 again.
check(M.CDAt(rows[3], 1) == 21.9, "rotation starts at its first value")
check(M.CDAt(rows[3], 4) == 21.9, "rotation wraps around")
check(M.CDAt(rows[1], 7) == 8.5, "a single-value rotation is constant")
check(M.ConsensusCD(both, 1) == 8.5, "consensus cooldown is the shortest one")

-- An opening delay backed by one sample must not be used at all.
check(M.HasOpening({ first = 5, firstN = 4 }), "a well-sampled opening delay is usable")
check(not M.HasOpening({ first = 17.8, firstN = 1 }), "a single-sample one is not")
check(not M.HasOpening({ firstN = 9 }), "and neither is a missing one")

-- Time to the opening cast separates candidates before any interval exists.
check(#M.NarrowByFirst(both, 3.6) == 1, "a 3.6s opening should pick the 3.9s spell")
check(M.NarrowByFirst(both, 3.6)[1].spell == 1, "and it should be that one")
check(#M.NarrowByFirst(both, 90) == 2, "an opening matching nothing must not erase candidates")
check(#M.NarrowByFirst(both, nil) == 2, "no engage time means no narrowing")

-- A spell switched off in the UI disappears, with no fallback.
check(#M.NarrowByEnabled(both, function(id) return id == 1 end) == 1, "a disabled spell drops out")
check(#M.NarrowByEnabled(both, function() return true end) == 0, "disabling all leaves nothing")
check(#M.NarrowByEnabled(both, nil) == 2, "no filter means no narrowing")

-- A cast already identified on the plate rules out other creatures' spells.
check(#M.NarrowByMob(both, { [20] = true }) == 1, "a known mob should drop the other candidate")
check(M.NarrowByMob(both, { [20] = true })[1].spell == 2, "and keep its own spell")
check(#M.NarrowByMob(both, { [99] = true }) == 0, "a known mob rules out every other creature's spell")
check(#M.NarrowByMob(both, nil) == 2, "nothing identified yet means no narrowing")

-- What to do about a cast: kicked often -> kick it, stopped some other way ->
-- control it, big or wide damage -> defensive. The game's own interruptible
-- flag overrides the table.
local kicked = { spell = 4, cast = 2.5, cd = { 3.6 }, kickable = true, kick = 0.5, cc = 0.2,
                 dmg = 0.3, filler = true }
local heavy = { spell = 5, cast = 4.0, cd = { 30.4 }, kick = 0, cc = 0.06, hits = 5, dmg = 0.5 }
local stunned = { spell = 6, cast = 5.0, cd = {}, kick = 0.05, cc = 0.34, filler = true }
check(M.Advice(kicked).label == "KICK", "an interruptible spell says KICK")
-- A spell people often kicked but MDT says is not interruptible must never say
-- KICK: that is how Primal Juggernaut got a KICK label it could not obey.
check(M.Advice({ spell = 8, cast = 2.5, cd = { 20 }, kick = 0.9, cc = 0.05, dmg = 0.05 }) == nil,
    "kick statistics alone must not produce KICK")
check(M.Advice(kicked, false).label ~= "KICK", "an immune cast must not say KICK")
check(M.Advice(heavy).label == "AOE", "damage across the group says AOE")
-- One target taking a big hit is a different call from the group taking one.
check(M.Advice({ spell = 9, cast = 3, cd = { 20 }, hits = 1, dmg = 0.45 }).key == "TANK",
    "one target taking a big hit says TANK")
-- Crushing Smash lands for 17.7%% and was silently unlabelled under the old bar.
check(M.Advice({ spell = 10, cast = 2.5, cd = { 20 }, hits = 1, dmg = 0.177 }).key == "TANK",
    "a mitigated tank hit still says TANK")
check(M.Advice(heavy, true).label == "KICK", "but if the game says kickable, kick it")
check(M.Advice(stunned).label == "STUN", "casts stopped without kicks say STUN")

-- Advice is only shown when every remaining candidate agrees.
check(M.ConsensusAdvice({ kicked, kicked }).label == "KICK", "agreeing candidates keep their advice")
check(M.ConsensusAdvice({ kicked, heavy }) == nil, "disagreeing candidates give no advice")
check(M.ConsensusAdvice({}) == nil, "no candidates, no advice")
check(M.BestGuess({ { n = 3, spell = 1 }, { n = 40, spell = 2 } }).spell == 2,
    "the best guess is the most-seen candidate")
check(M.Advice({ spell = 7, cast = 2, cd = { 20 }, kick = 0, cc = 0, dmg = 0.05 }) == nil,
    "a harmless cast gets no label")
check(M.Advice(nil) == nil, "no row, no advice")

-- Short-cycle and one-off casts get named, never counted down to.
check(M.HasSchedule(heavy) == true, "a real rotation schedules")
check(not M.HasSchedule(kicked), "a filler does not schedule")
check(not M.HasSchedule(stunned), "a spell with no rotation does not schedule")
check(M.CDAt(stunned, 1) == nil, "no rotation means no cooldown value")
check(M.ConsensusCD({ kicked, stunned }, 1) == nil, "fillers contribute no timer")

-- The shipped data has to be sane, and resolvable in at most two casts.
local dungeons, spells, stuck = 0, 0, 0
for instanceID, rowsForMap in pairs(CastAheadData) do
    dungeons = dungeons + 1
    for i = 1, #rowsForMap do
        local row = rowsForMap[i]
        spells = spells + 1
        check(row.cast >= 1.0, string.format("spell %d has no real cast bar", row.spell))
        check(type(row.cd) == "table", string.format("spell %d has no cd table", row.spell))
        check(type(row.kick) == "number" and type(row.cc) == "number",
            string.format("spell %d is missing its threat numbers", row.spell))
        if M.HasSchedule(row) then
            for slot = 1, #row.cd do
                check(row.cd[slot] >= 8.0,
                    string.format("spell %d slot %d would count down a filler (%.1f)",
                        row.spell, slot, row.cd[slot]))
            end
        else
            -- Anything without a timer must justify its place some other way.
            check(M.Advice(row) ~= nil,
                string.format("spell %d has neither a timer nor a reason to show", row.spell))
        end
        -- After cast time and interval, candidates may still share a slot. That
        -- only hurts when their cooldowns differ - then the bar shows the wrong
        -- time, not merely the wrong name.
        local same = M.HasSchedule(row)
            and M.NarrowByInterval(M.ByCastTime(rowsForMap, row.cast), row.cd[1]) or {}
        for j = 1, #same do
            if same[j].spell ~= row.spell and same[j].npc ~= row.npc and M.HasSchedule(same[j])
                and math.abs(M.CDAt(same[j], 1) - row.cd[1]) > 2.0 then
                stuck = stuck + 1
                print(string.format("  wrong-timer risk in %d: spell %d vs %d (cast %.1f, cd %.1f/%.1f)",
                    instanceID, row.spell, same[j].spell, row.cast, row.cd[1], M.CDAt(same[j], 1)))
                break
            end
        end
    end
end

-- Where cast time and interval both collide, only the mob check can save it.
local rescued = 0
for _, rowsForMap in pairs(CastAheadData) do
    for i = 1, #rowsForMap do
        local row = rowsForMap[i]
        local same = M.HasSchedule(row)
            and M.NarrowByInterval(M.ByCastTime(rowsForMap, row.cast), row.cd[1]) or {}
        if #same > 1 and #M.NarrowByMob(same, { [row.npc] = true }) < #same then
            rescued = rescued + 1
        end
    end
end

-- Creature traits (Traits.lua) ---------------------------------------------

-- Every trait row must be usable by the matcher as written: a dungeon we have
-- data for, a level to match on, and well-formed optional lists.
local traitRows, traitDungeons = 0, 0
for instanceID, rows in pairs(CastAheadTraits) do
    traitDungeons = traitDungeons + 1
    check(CastAheadData[instanceID] ~= nil,
        string.format("traits reference unknown instance %s", tostring(instanceID)))
    for i = 1, #rows do
        local row = rows[i]
        traitRows = traitRows + 1
        check(type(row.npc) == "number" and type(row.level) == "number",
            string.format("trait row %d in %s lacks npc or level", i, tostring(instanceID)))
        check(type(row.elite) == "boolean", string.format("trait row for npc %s has no elite flag", tostring(row.npc)))
        for _, key in ipairs({ "stage", "co", "casts", "channels" }) do
            check(row[key] == nil or (type(row[key]) == "table" and #row[key] > 0),
                string.format("trait row for npc %s has a malformed %s list", tostring(row.npc), key))
        end
        -- The generator drops the source's 604800 (one week) "unknown length"
        -- sentinel; anything past a real channel's ceiling means it leaked in.
        for j = 1, #(row.channels or {}) do
            check(row.channels[j] > 0 and row.channels[j] <= 60,
                string.format("npc %s has a channel length %.1fs outside (0, 60]", tostring(row.npc), row.channels[j]))
        end
    end
end
check(traitRows > 0, "no creature traits at all")

-- The matcher rejects a creature over any measured cast length its trait row
-- does not list, so every length Data.lua knows for the creature must be there.
for instanceID, rows in pairs(CastAheadTraits) do
    for i = 1, #rows do
        local row = rows[i]
        if row.casts then
            for _, spell in ipairs(CastAheadData[instanceID] or {}) do
                -- Channel rows are checked against `channels` below.
                if spell.npc == row.npc and not spell.channel then
                    local listed = false
                    for j = 1, #row.casts do
                        if math.abs(row.casts[j] - spell.cast) <= M.CAST_TOLERANCE then listed = true end
                    end
                    check(listed, string.format("npc %d: cast %.1fs (%s) is missing from its trait row",
                        row.npc, spell.cast, spell.name or "?"))
                end
            end
        end
    end
end

-- Channel lengths get the same guarantee as cast lengths, against `channels`.
for instanceID, rows in pairs(CastAheadTraits) do
    for i = 1, #rows do
        local row = rows[i]
        for _, spell in ipairs(CastAheadData[instanceID] or {}) do
            if spell.npc == row.npc and spell.channel then
                local listed = false
                for j = 1, #(row.channels or {}) do
                    if math.abs(row.channels[j] - spell.cast) <= M.CAST_TOLERANCE then listed = true end
                end
                check(listed, string.format("npc %d: channel %.1fs (%s) is missing from its trait row",
                    row.npc, spell.cast, spell.name or "?"))
            end
        end
    end
end
-- Channels reach the game either harvested into Data.lua (channels.json gives
-- the length) or as provisional Extra rows; either way some must exist.
local channelRows = 0
for _, extras in pairs(CastAheadExtra) do
    for i = 1, #extras do
        if extras[i].channel then channelRows = channelRows + 1 end
    end
end
for _, rowsForMap in pairs(CastAheadData) do
    for i = 1, #rowsForMap do
        if rowsForMap[i].channel then channelRows = channelRows + 1 end
    end
end
check(channelRows > 0, "no channel rows were generated at all")

-- Curated priorities (Priority.lua) ----------------------------------------

-- Every category written by the generator must resolve to an advice entry, or
-- a prioritised cast would show an icon with no label and no voice line.
for spellID, category in pairs(CastAheadPriority) do
    check(M.ADVICE[category] ~= nil,
        string.format("spell %d has unknown priority category %s", spellID, tostring(category)))
end

-- The curation must actually cut the noise: a fair share of measured spells
-- stays unmarked, or "important only" filters nothing.
local marked, total = 0, 0
for _, rowsForMap in pairs(CastAheadData) do
    for i = 1, #rowsForMap do
        total = total + 1
        if CastAheadPriority[rowsForMap[i].spell] then marked = marked + 1 end
    end
end
check(marked > 0, "no measured spell carries a priority mark")
check(marked < total, "every measured spell is marked - the filter would be a no-op")

-- Extra rows carry provisional timings and must be usable by the same
-- matching pipeline as our own rows.
for instanceID, extras in pairs(CastAheadExtra) do
    check(CastAheadData[instanceID] ~= nil,
        string.format("extras reference unknown instance %d", instanceID))
    for i = 1, #extras do
        local row = extras[i]
        check(type(row.cast) == "number" and row.cast > 0,
            string.format("extra spell %d has no cast time", row.spell))
        check(CastAheadPriority[row.spell] ~= nil,
            string.format("extra spell %d is not in the priority set", row.spell))
        check(row.approx == true,
            string.format("extra spell %d must be marked approximate", row.spell))
        for j = 1, #(CastAheadData[instanceID] or {}) do
            local ours = CastAheadData[instanceID][j]
            check(not (ours.spell == row.spell and ours.npc == row.npc),
                string.format("extra spell %d duplicates a measured row", row.spell))
        end
        check(row.channel == nil or row.channel == true,
            string.format("extra spell %d has a malformed channel flag", row.spell))
    end
end

-- Advice: the curated category wins over statistics, except a KICK the game
-- says is uninterruptible right now.
check(M.Advice({ prio = "TANK", kickable = true }) == M.ADVICE.TANK,
    "curated TANK must beat the kickable flag")
check(M.Advice({ prio = "KICK" }, false) ~= M.ADVICE.KICK,
    "curated KICK must yield when the game says uninterruptible")
check(M.Advice({ prio = "KICK" }, nil) == M.ADVICE.KICK,
    "curated KICK holds when interruptibility is unknown")
check(M.Advice({ kickable = true }) == M.ADVICE.KICK,
    "rows without a curated category keep the statistical verdict")

-- Importance helpers drive the display filter and the sound gate.
check(M.AnyImportant({ { prio = "AOE" }, {} }), "one marked candidate makes the set important")
check(not M.AnyImportant({ {}, {} }), "no marked candidate, not important")
check(not M.AnyImportant(nil), "nil candidate set is not important")
check(#M.OnlyImportant({ { prio = "AOE" }, {} }) == 1, "OnlyImportant keeps just marked rows")

-- Every verdict has both voice clips on disk (tools/voice.py renders them);
-- a missing one would silently drop to the game voice or the beep.
for key, advice in pairs(M.ADVICE) do
    if key ~= "SAVE" then
        check(advice.key == key and advice.file, "ADVICE." .. key .. " lacks key/file")
        for _, suffix in ipairs({ "", "_soon" }) do
            local path = "Sounds/en/" .. advice.file .. suffix .. ".ogg"
            local f = io.open(path, "rb")
            check(f ~= nil, "voice clip missing: " .. path)
            if f then f:close() end
        end
    end
end

-- The filter hides what the player cannot act on: TANK by role, dispel
-- schools by whether a matching ability is known. Unknown role/permissive
-- capability hides nothing.
for role, hides in pairs(M.ROLE_HIDES) do
    for category in pairs(hides) do
        check(M.ADVICE[category], "ROLE_HIDES." .. role .. " names unknown category " .. category)
    end
end
for category in pairs(M.CAPABILITY_GATED) do
    check(M.ADVICE[category], "CAPABILITY_GATED names unknown category " .. category)
end
local savedRole, savedCan = M.PlayerRole, M.PlayerCanHandle
M.PlayerRole = function() return "DAMAGER" end
check(not M.Important({ prio = "TANK" }), "a dps is not told about tank busters")
check(M.Important({ prio = "KICK" }), "a dps still gets kicks")
check(#M.OnlyImportant({ { prio = "TANK" }, { prio = "DODGE" }, {} }) == 1, "OnlyImportant applies the role")
M.PlayerRole = function() return "TANK" end
check(M.Important({ prio = "TANK" }), "a tank sees tank busters")
M.PlayerCanHandle = function(category) return category ~= "POISON" end
check(not M.AnyImportant({ { prio = "POISON" } }), "no poison dispel known, no poison call")
check(M.Important({ prio = "CURSE" }), "other schools stay while known")
check(M.Important({ prio = "DODGE" }), "role-blind categories are never capability-gated")
M.PlayerCanHandle = function() return false end
check(M.Important({ prio = "AOE" }), "AOE is not capability-gated")
check(not M.Important({ prio = "SOOTHE" }), "soothe needs a soothe ability")
check(not M.Important({ prio = "PURGE" }), "purge needs a purge ability")
check(not M.Important({ prio = "DISPEL" }), "generic dispel needs any friendly dispel")
M.PlayerRole = function() return nil end
M.PlayerCanHandle = function() return true end
check(M.Important({ prio = "POISON" }), "outside the game nothing is hidden")
M.PlayerRole, M.PlayerCanHandle = savedRole, savedCan

print(string.format("%d dungeons, %d spells, %d unresolvable after two casts, %d needing the mob check",
    dungeons, spells, stuck, rescued))
print(failures == 0 and "OK" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
