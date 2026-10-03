# Key Recorder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Journal every key (engage, casts with their candidates and calls, predictions, timeline events, player marks), export it as text for GitHub issues, and audit it against the combat log or the shipped data.

**Architecture:** A new `Recorder.lua` owns the journal in `CastAheadDB.journal` and the export text; Core and Timeline only call `Record(...)`, a nil-safe wrapper, at the points that already exist (Trace steps, RefreshBar, OnCastStart/Stop, LockNPC, plate add/remove, heads-up, timeline Sync/Finish/Cancel). `ReportWindow.lua` holds the `/ca report` window and the mark button; `Bindings.xml` adds the mark key. `tools/audit.py` parses exports and SavedVariables and joins them with the combat log.

**Tech Stack:** WoW 12.1 Lua 5.1 (headless tests in WSL `~/luaenv/bin/lua`), Python 3 with pytest for tools.

**Spec:** `docs/superpowers/specs/2026-10-03-key-recorder-design.md`

## Global Constraints

- Display name in every player-facing string: "Cast Ahead". Identifiers stay `CastAhead*`.
- No names of people (player, realm, guild, party) anywhere in the journal or export.
- Never read, compare or boolean-test a value 12.x may return Secret; the recorder only stores numbers and strings the addon already holds as plain Lua values.
- At most 5 keys in the journal, at most 20000 lines per key; hitting a cap writes a `TRIM` line and sets `truncated`.
- Line format: `t|TYPE|slot|field|field...`, `t` integer milliseconds since key start, `slot` the nameplate number or `-`, lists joined with `,`.
- Export header starts `CastAhead-Report 1 `, footer is `CastAhead-Report end lines=<n>`; human summary lines start with `# `.
- Core must keep working when `CastAheadRecorder` is nil (replay harness and first load after a TOC change).
- No code comments except facts nobody can re-check on demand (user rule).
- `docs` goes on the `.pkgmeta` ignore list.
- Tests: `MSYS_NO_PATHCONV=1 wsl bash -lc 'cd "/mnt/g/Games/World of Warcraft/_retail_/Interface/AddOns/CastAhead" && ~/luaenv/bin/lua test.lua | tail -1 && ~/luaenv/bin/lua test_core.lua | tail -1'` must print `OK` twice; `python -m pytest -q tools` must pass.

## Review Focus

1. A `/reload` in the middle of a key must continue the same key, not open a second one or lose lines - pinned in Task 1.
2. A mark pressed when no plate is tracked (between pulls, in a city) must still record a `MARK` line and export cleanly - pinned in Task 3.
3. A pasted export that lost its tail (CurseForge comment limit, partial copy) must be reported as truncated, not parsed as complete - pinned in Task 5.
4. A plate token recycled to another mob mid-pull (`nameplate3` reused) must not glue two mobs into one history - the `PLATE added` line carries the new level/npc so the audit splits on it - pinned in Task 2.
5. An export of a very busy key must stay under GitHub's 65536-character body limit or offer one pull at a time - pinned in Task 4.

---

### Task 1: Recorder core - keys, lines, caps, checksum, reload

**Files:**
- Create: `Recorder.lua`
- Modify: `CastAhead.toc` (add `Recorder.lua` after `Core.lua`)
- Modify: `test_core.lua` (load `Recorder.lua` after `Core.lua`; new cases at the end, before the final `print`)

**Interfaces:**
- Produces:
  - `CastAheadRecorder.Enabled() -> boolean` (true when `reportCalls` or `devMode` is on)
  - `CastAheadRecorder.StartKey(info)` where `info = { instance = number, name = string, level = number, affixes = string, role = string }`
  - `CastAheadRecorder.EndKey(result)` with `result` one of `"completed"`, `"left"`, `"reset"`
  - `CastAheadRecorder.Note(kind, slot, ...)`; `slot` is a unit token, a number or nil; extra args become fields (tables are joined with `,`)
  - `CastAheadRecorder.Current() -> key table or nil`
  - `CastAheadRecorder.Keys() -> array of key tables, oldest first`
  - `CastAheadRecorder.Checksum() -> string` (8 hex digits)
  - key table: `{ format = 1, addon = string, data = string, instance = number, name = string, level = number, affixes = string, role = string, startedAt = number (GetTime seconds), ended = string or nil, endedAt = number or nil, truncated = number or nil, lines = { string, ... } }`

- [ ] **Step 1: Write the failing tests** (append to `test_core.lua` before the final `print`)

```lua
-- Recorder -------------------------------------------------------------------
CastAheadDB = { reportCalls = true }
local R = CastAheadRecorder
check(R and R.Enabled(), "the recorder is on with the report switch")
R.StartKey({ instance = 1877, name = "Test", level = 12, affixes = "9,10", role = "HEALER" })
advance(1.5)
R.Note("PLATE", "nameplate3", "added", 91, 1, "elite")
local key = R.Current()
check(key and key.level == 12 and key.instance == 1877, "a key opens with its header")
check(key.lines[1] == "1500|PLATE|3|added|91|1|elite", "lines carry ms, type, slot number and fields, got " .. tostring(key.lines[1]))
R.Note("START", nil, 100, "AOE", { 100, 200 })
check(key.lines[2] == "1500|START|-|100|AOE|100,200", "a nil slot is '-' and a list joins with commas, got " .. tostring(key.lines[2]))
check(R.Checksum():match("^%x%x%x%x%x%x%x%x$"), "the data checksum is 8 hex digits")
check(key.data == R.Checksum(), "the key records the data checksum")

-- A reload keeps the journal and the same key continues.
local saved = CastAheadDB
CastAheadRecorder = nil
dofile("Recorder.lua")
CastAheadDB = saved
CastAheadRecorder.Restore()
check(CastAheadRecorder.Current() == saved.journal.keys[#saved.journal.keys], "after a reload the open key continues")
CastAheadRecorder.Note("PULL", nil, "in")
check(#CastAheadRecorder.Current().lines == 3, "and new lines land in it")
R = CastAheadRecorder

-- Caps: five keys, a line limit with a visible trim.
for i = 1, 6 do
    R.EndKey("completed")
    R.StartKey({ instance = 1877, name = "Test", level = i, affixes = "", role = "DAMAGER" })
end
check(#R.Keys() == 5, "only five keys are kept, got " .. #R.Keys())
local savedMax = R.MAX_LINES
R.MAX_LINES = 3
R.Note("A") R.Note("B") R.Note("C") R.Note("D")
local k = R.Current()
check(#k.lines == 4 and k.lines[4]:match("|TRIM|") and k.truncated, "the line cap writes one TRIM line and flags the key")
R.MAX_LINES = savedMax
CastAheadDB = nil
```

- [ ] **Step 2: Run to verify it fails**

Run: `MSYS_NO_PATHCONV=1 wsl bash -lc 'cd "/mnt/g/Games/World of Warcraft/_retail_/Interface/AddOns/CastAhead" && ~/luaenv/bin/lua test_core.lua | tail -3'`
Expected: an error loading `Recorder.lua` (file missing) after adding `dofile("Recorder.lua")` below `dofile("Core.lua")`.

- [ ] **Step 3: Implement `Recorder.lua`**

```lua
CastAheadRecorder = {}
local R = CastAheadRecorder

R.FORMAT = 1
R.MAX_KEYS = 5
R.MAX_LINES = 20000
R.RESUME_WINDOW = 7200

local checksum

local function Journal()
    CastAheadDB = CastAheadDB or {}
    CastAheadDB.journal = CastAheadDB.journal or { keys = {} }
    return CastAheadDB.journal
end

function R.Enabled()
    return CastAheadConfig.Get("reportCalls") == true or CastAheadConfig.Get("devMode") == true
end

local function Hash(h, text)
    for i = 1, #text do
        h = (h * 33 + text:byte(i)) % 4294967296
    end
    return h
end

local function Serialize(value)
    if type(value) ~= "table" then return tostring(value) end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. Serialize(value[k]) end
    return "{" .. table.concat(parts, ";") .. "}"
end

function R.Checksum()
    if not checksum then
        local h = 5381
        h = Hash(h, Serialize(CastAheadData or {}))
        h = Hash(h, Serialize(CastAheadPriority or {}))
        h = Hash(h, Serialize(CastAheadTraits or {}))
        checksum = string.format("%08x", h)
    end
    return checksum
end

local function AddonVersion()
    local get = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    return get and get("CastAhead", "Version") or "?"
end

function R.Keys() return Journal().keys end

function R.Current()
    local keys = Journal().keys
    local last = keys[#keys]
    if last and not last.ended then return last end
end

function R.StartKey(info)
    local keys = Journal().keys
    if R.Current() then R.EndKey("reset") end
    keys[#keys + 1] = {
        format = R.FORMAT, addon = AddonVersion(), data = R.Checksum(),
        instance = info.instance, name = info.name, level = info.level or 0,
        affixes = info.affixes or "", role = info.role or "NONE",
        startedAt = GetTime(), lines = {},
    }
    while #keys > R.MAX_KEYS do table.remove(keys, 1) end
end

function R.EndKey(result)
    local key = R.Current()
    if not key then return end
    key.ended, key.endedAt = result or "completed", GetTime()
end

function R.Restore()
    local key = R.Current()
    if not key then return end
    local _, _, _, _, _, _, _, instance = GetInstanceInfo()
    if instance ~= key.instance or GetTime() < key.startedAt or GetTime() - key.startedAt > R.RESUME_WINDOW then
        R.EndKey("left")
    end
end

local function Field(value)
    if type(value) == "table" then
        local out = {}
        for i = 1, #value do out[i] = tostring(value[i]) end
        return table.concat(out, ",")
    end
    if value == nil then return "" end
    return tostring(value)
end

local function Slot(slot)
    if type(slot) == "number" then return tostring(slot) end
    if type(slot) == "string" then return slot:match("(%d+)$") or slot end
    return "-"
end

function R.Note(kind, slot, ...)
    local key = R.Current()
    if not key then return end
    local lines = key.lines
    if key.truncated then return end
    local t = math.floor((GetTime() - key.startedAt) * 1000 + 0.5)
    if #lines >= R.MAX_LINES then
        lines[#lines + 1] = t .. "|TRIM|-|" .. #lines
        key.truncated = t
        return
    end
    local fields = { tostring(t), kind, Slot(slot) }
    for i = 1, select("#", ...) do fields[#fields + 1] = Field((select(i, ...))) end
    lines[#lines + 1] = table.concat(fields, "|")
end
```

Note on the test: the line-cap test expects `#k.lines == 4` with `MAX_LINES = 3` - lines A, B, C fill the cap, D becomes the `TRIM` line.

- [ ] **Step 4: Add `Recorder.lua` to `CastAhead.toc`** right after the `Core.lua` line.

- [ ] **Step 5: Run the tests to verify they pass** (same command as Step 2; expect `OK`).

- [ ] **Step 6: Commit**

```bash
git add Recorder.lua CastAhead.toc test_core.lua
git commit -m "feat: key journal with caps, data checksum and reload continuation"
```

---

### Task 2: Core and Timeline write the journal

**Files:**
- Modify: `Core.lua` (a `Record` helper near the top; calls at the points below; key start/end; player anchors)
- Modify: `Timeline.lua` (`Sync`, `Finish`, `Cancel` record `TL` lines)
- Modify: `test_core.lua`

**Interfaces:**
- Consumes: `CastAheadRecorder.Enabled`, `StartKey`, `EndKey`, `Note`, `Restore` from Task 1.
- Produces (line types written, field order fixed - Task 4 and Task 5 parse them):
  - `PLATE|slot|added|level|power|classification` and `PLATE|slot|removed|reason` (reason `died`, `gone`, `reset`)
  - `ENGAGE|slot`
  - `LOCK|slot|npc|source`
  - `START|slot|channel(0/1)|claimed spell or -|call key or -|candidate ids|target(1/0/?)`
  - `STEP|slot|step name|candidate ids`
  - `STOP|slot|channel(0/1)|measured ms|final candidate ids|call key or -`
  - `KICK|slot` and `FAIL|slot`
  - `PRED|slot|spell|due ms (key clock)|approx(0/1)|source (repeat/projected)`
  - `HEADS|slot|call key|candidate ids`
  - `TL|-|added|spell|due ms` , `TL|-|finished|spell`, `TL|-|cancelled|spell`
  - `PULL|-|in` / `PULL|-|out`
  - `SELF|-|spell id` (player's own successful cast, for clock alignment with the log)

- [ ] **Step 1: Write the failing test** (append before the final `print`)

```lua
-- The journal follows a pull.
CastAheadDB = { reportCalls = true, importantOnly = false }
enter()
fire("CHALLENGE_MODE_START")
local journal = CastAheadRecorder.Current()
check(journal ~= nil, "a keystone start opens a key")
fire("PLAYER_REGEN_DISABLED")
castFor(3.0)
advance(17)
castFor(3.0)
fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 12345)
fire("PLAYER_REGEN_ENABLED")
local seen = {}
for _, line in ipairs(journal.lines) do seen[line:match("^%d+|(%u+)|")] = true end
for _, kind in ipairs({ "PLATE", "ENGAGE", "START", "STEP", "STOP", "PRED", "PULL", "SELF" }) do
    check(seen[kind], "the journal records " .. kind)
end
local stop
for _, line in ipairs(journal.lines) do if line:match("|STOP|") then stop = line break end end
check(stop and stop:match("|STOP|1|0|3000|"), "a stop carries the measured length in ms, got " .. tostring(stop))
reset()
local removed = journal.lines[#journal.lines]
check(removed:match("|PLATE|1|removed|"), "a dropped plate is journalled, got " .. tostring(removed))
fire("NAME_PLATE_UNIT_ADDED", unit)
check(journal.lines[#journal.lines]:match("|PLATE|1|added|"), "a recycled plate token starts a new PLATE line")
reset()
CastAheadRecorder.EndKey("completed")
CastAheadDB = nil
```

- [ ] **Step 2: Run to verify it fails.** Expected: FAIL lines for the missing kinds.

- [ ] **Step 3: Add the helper and key lifecycle in `Core.lua`**

Near the other forward declarations at the top of `Core.lua`:

```lua
local function Record(kind, slot, ...)
    local recorder = CastAheadRecorder
    if recorder and recorder.Enabled() then recorder.Note(kind, slot, ...) end
end

local function Ids(rows)
    local ids = {}
    for i = 1, #(rows or {}) do ids[i] = rows[i].spell end
    return ids
end
```

In the main event handler, register and handle (add the events to the registration list next to `CHALLENGE_MODE_START`):

```lua
    if event == "CHALLENGE_MODE_START" then
        ResetPopulation()
        if CastAheadRecorder and CastAheadRecorder.Enabled() then
            local _, _, _, _, _, _, _, instance = GetInstanceInfo()
            local level, affixes = 0, ""
            if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
                local ok, lvl, list = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
                if ok and type(lvl) == "number" then level = lvl end
                if ok and type(list) == "table" then affixes = table.concat(list, ",") end
            end
            local role = GetSpecialization and GetSpecializationRole
                and GetSpecializationRole(GetSpecialization() or 0) or "NONE"
            CastAheadRecorder.StartKey({ instance = instance, name = (GetInstanceInfo()), level = level,
                affixes = affixes, role = role or "NONE" })
        end
        return
    end
    if event == "CHALLENGE_MODE_COMPLETED" then
        if CastAheadRecorder then CastAheadRecorder.EndKey("completed") end
        return
    end
    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        Record("PULL", nil, event == "PLAYER_REGEN_DISABLED" and "in" or "out")
        return
    end
```

In `PLAYER_ENTERING_WORLD`, after `ProbeRestore()`:

```lua
        if CastAheadRecorder then CastAheadRecorder.Restore() end
```

At the top of the `unit == "player"` branch for `UNIT_SPELLCAST_SUCCEEDED` (third payload value is the spell id):

```lua
        if event == "UNIT_SPELLCAST_SUCCEEDED" then Record("SELF", nil, arg3) end
```

- [ ] **Step 4: Record at the existing points**

`Trace(unit, step, candidates)` becomes:

```lua
local function Trace(unit, step, candidates)
    if narrowTrace then narrowTrace(unit, step, candidates) end
    Record("STEP", unit, step, Ids(candidates))
end
```

`DropUnit(unit)` takes a reason and records it; callers pass `"died"` where `UnitIsDead(unit)` was true, `"gone"` otherwise, and the `NAME_PLATE_UNIT_REMOVED` branch passes `"gone"`:

```lua
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
```

In `NAME_PLATE_UNIT_ADDED`, after `state.level = SafeLevel(unit)`:

```lua
            Record("PLATE", unit, "added", type(state.level) == "number" and state.level or "?",
                ReadTraits and ReadTraits(unit).power or "?", ReadTraits and ReadTraits(unit).classification or "?")
```

(If `ReadTraits` returns a table without those keys, read the same fields Traits matching uses; check `ReadTraits` at its definition and use its field names.)

Where `state.engagedAt = GetTime()` is set in `RefreshCombat`, and where `OnCastStart` sets `state.engagedAt = state.engagedAt or GetTime()` only when it was nil, add `Record("ENGAGE", unit)` right after.

In `LockNPC(unit, state, npc, source)` after `state.npcSource = source or "cast"`: `Record("LOCK", unit, npc, state.npcSource)`.

In `OnCastStop`, right after `local duration = GetTime() - startAt` (and the sole-channel override), store it: `state.lastMeasured = duration`.

In the event handler, after the existing `OnCastStart(unit, channel)` calls (cast and channel), add:

```lua
        local state = plates[unit]
        local casting = state and state.casting
        local advice = casting and Announceable(casting.candidates)
            and CastAheadMatch.ConsensusAdvice(casting.candidates, state.interruptible)
        Record("START", unit, channel and 1 or 0,
            casting and casting.row and casting.row.spell or "-",
            advice and advice.key or "-", Ids(casting and casting.candidates),
            state and state.spellTarget == true and 1 or state and state.spellTarget == false and 0 or "?")
```

After `OnCastStop(unit, false)` and the channel stop:

```lua
        local state = plates[unit]
        local final = lastIdentified[unit]
        local advice = final and Announceable(final) and CastAheadMatch.ConsensusAdvice(final)
        Record("STOP", unit, channel and 1 or 0,
            state and state.lastMeasured and math.floor(state.lastMeasured * 1000 + 0.5) or "?",
            Ids(final), advice and advice.key or "-")
```

In `OnCastInterrupted(unit)` record `KICK` when the interrupt flag is set and `FAIL` otherwise (read the function to pick the existing branch).

At the very top of `RefreshBar(unit, state)` (before the nameplates switch return):

```lua
    if CastAheadRecorder and CastAheadRecorder.Enabled() then
        local key = CastAheadRecorder.Current()
        for _, track in pairs(state.tracks) do
            local due = track.nextAt
            if due ~= track.recordedAt and track.candidates and #track.candidates == 1 then
                track.recordedAt = due
                if due and key then
                    Record("PRED", unit, track.candidates[1].spell,
                        math.floor((due - key.startedAt) * 1000 + 0.5),
                        (track.projected or track.candidates[1].approx) and 1 or 0,
                        track.projected and "projected" or "repeat")
                end
            end
        end
    end
```

Where the heads-up plays (`PlayAdviceSound(CastAheadMatch.ConsensusAdvice(entry.candidates), true, entry.candidates)` in the update loop), add before it:

```lua
                            local headsAdvice = CastAheadMatch.ConsensusAdvice(entry.candidates)
                            Record("HEADS", unit, headsAdvice and headsAdvice.key or "-", Ids(entry.candidates))
```

`Timeline.lua`: at the successful add in `T.Sync`, `T.Finish` and `T.Cancel` (non-demo only; the demo path passes `demo = true`):

```lua
local function Record(kind, ...)
    local recorder = CastAheadRecorder
    if recorder and recorder.Enabled() then recorder.Note(kind, nil, ...) end
end
```

- Sync, after `track.timelineSpell = row.spell`: `if not demo then local key = CastAheadRecorder and CastAheadRecorder.Current() Record("TL", "added", row.spell, key and math.floor((targetAt - key.startedAt) * 1000 + 0.5) or "?") end`
- Finish: `Record("TL", "finished", track.timelineSpell)` before clearing the id.
- Cancel: `Record("TL", "cancelled", track.timelineSpell)` before clearing the id.

- [ ] **Step 5: Run the tests** (expect `OK` twice). Also run the replay harness once to prove the recorder-less path still works: `~/luaenv/bin/lua test_replay.lua ../CastAheadTools/replay_1003.lua | tail -3` in WSL from the CastAhead folder; expect the same numbers as before (`210 right / 2 wrong` start claims).

- [ ] **Step 6: Commit**

```bash
git add Core.lua Timeline.lua test_core.lua
git commit -m "feat: core and timeline write the key journal"
```

---

### Task 3: Marks - binding, button, snapshot, screenshot

**Files:**
- Modify: `Recorder.lua` (`Mark`)
- Modify: `Core.lua` (`CastAheadCore.Snapshot`)
- Create: `Bindings.xml`
- Modify: `test_core.lua`

**Interfaces:**
- Consumes: Task 1 and Task 2 line formats.
- Produces:
  - `CastAheadCore.Snapshot(window) -> array of { slot = number, casting = { claimed, call, candidates, sinceMs } or nil, preds = { { spell, dueMs, approx } } }` for plates with any tracked state
  - `CastAheadRecorder.Mark(note)`: writes `MARK|-|n|screenshot(0/1)|note`, then one `SNAP|slot|casting claimed|call|candidate ids|since ms|preds` line per snapshot entry, `preds` as `spell@dueMs~approx` joined with `,`; prints `Cast Ahead: mark n recorded`
  - `CastAheadRecorder.marks` count lives in the key: `key.marks`
  - setting `markScreenshot` (default on when the call is available)

- [ ] **Step 1: Write the failing test**

```lua
-- Marks record a snapshot, even with nothing on screen.
CastAheadDB = { reportCalls = true }
fire("CHALLENGE_MODE_START")
local printed = {}
local realPrint = print
print = function(text) printed[#printed + 1] = tostring(text) end
CastAheadRecorder.Mark("nothing there")
print = realPrint
local mk = CastAheadRecorder.Current()
check(mk.lines[#mk.lines]:match("|MARK|%-|1|%d|nothing there$"), "a mark with no plates still records, got " .. tostring(mk.lines[#mk.lines]))
check(printed[1] and printed[1]:find("Cast Ahead", 1, true), "the mark is confirmed in chat")
enter()
castFor(3.0)
fire("UNIT_SPELLCAST_START", unit)
CastAheadRecorder.Mark()
local snap = mk.lines[#mk.lines]
check(snap:match("|SNAP|1|"), "a mark snapshots the casting plate, got " .. tostring(snap))
advance(3.0)
fire("UNIT_SPELLCAST_STOP", unit)
reset()
CastAheadRecorder.EndKey("completed")
CastAheadDB = nil
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: `CastAheadCore.Snapshot` in `Core.lua`** (next to `CastAheadCore.Tracks`)

```lua
function CastAheadCore.Snapshot()
    local out, now = {}, GetTime()
    local key = CastAheadRecorder and CastAheadRecorder.Current()
    local function Ms(at) return key and math.floor((at - key.startedAt) * 1000 + 0.5) or "?" end
    for unit, state in pairs(plates) do
        local entry = { slot = tonumber(unit:match("(%d+)$")), preds = {} }
        local c = state.casting
        if c then
            local advice = Announceable(c.candidates) and CastAheadMatch.ConsensusAdvice(c.candidates, state.interruptible)
            entry.casting = { claimed = c.row and c.row.spell or "-", call = advice and advice.key or "-",
                candidates = Ids(c.candidates), sinceMs = math.floor((now - c.startAt) * 1000 + 0.5) }
        end
        for _, track in pairs(state.tracks) do
            if track.nextAt and track.candidates and #track.candidates == 1 then
                entry.preds[#entry.preds + 1] = { track.candidates[1].spell, Ms(track.nextAt),
                    (track.projected or track.candidates[1].approx) and 1 or 0 }
            end
        end
        if entry.casting or #entry.preds > 0 then out[#out + 1] = entry end
    end
    return out
end
```

- [ ] **Step 4: `Mark` in `Recorder.lua`**

```lua
function R.Mark(note)
    if not R.Enabled() then return end
    if not R.Current() then
        local name, _, _, _, _, _, _, instance = GetInstanceInfo()
        R.StartKey({ instance = instance or 0, name = name or "?", level = 0 })
    end
    local key = R.Current()
    key.marks = (key.marks or 0) + 1
    local shot = 0
    if CastAheadConfig.Get("markScreenshot") ~= false and Screenshot then
        shot = pcall(Screenshot) and 1 or 0
    end
    R.Note("MARK", nil, key.marks, shot, note or "")
    for _, entry in ipairs(CastAheadCore and CastAheadCore.Snapshot and CastAheadCore.Snapshot() or {}) do
        local c = entry.casting or {}
        local preds = {}
        for i, p in ipairs(entry.preds) do preds[i] = p[1] .. "@" .. p[2] .. "~" .. p[3] end
        R.Note("SNAP", entry.slot, c.claimed or "-", c.call or "-", c.candidates or {}, c.sinceMs or "-", table.concat(preds, ","))
    end
    print("|cff33ff99Cast Ahead|r mark " .. key.marks .. " recorded" .. (shot == 1 and " with a screenshot" or ""))
end
```

- [ ] **Step 5: `Bindings.xml`** (repo root; the client loads it without a TOC entry) and the binding labels at the top of `Recorder.lua`:

```xml
<Bindings>
  <Binding name="CASTAHEAD_MARK" category="Cast Ahead">
    CastAheadRecorder.Mark()
  </Binding>
</Bindings>
```

```lua
BINDING_NAME_CASTAHEAD_MARK = "Mark a wrong call"
```

- [ ] **Step 6: In-game check of `Screenshot()` from an addon in combat** (manual, before shipping): `/run CastAheadRecorder.Mark("test")` in combat on a dummy; a file must appear in `_retail_/Screenshots`. If it does not, set the default of `markScreenshot` to off and hide its switch (Task 6).

- [ ] **Step 7: Run tests, commit**

```bash
git add Recorder.lua Core.lua Bindings.xml test_core.lua
git commit -m "feat: mark a wrong call with a snapshot and a screenshot"
```

---

### Task 4: Export text and the post-key chat line

**Files:**
- Modify: `Recorder.lua` (`Export`, `Summary`, end-of-key chat line)
- Create: `tools/fixtures/export_sample.txt` (golden file written by the test when `CA_WRITE_FIXTURE=1`)
- Modify: `test_core.lua`

**Interfaces:**
- Produces:
  - `CastAheadRecorder.Export(key, pull) -> string`; `pull` nil means every pull that contains a mark (or the whole key when there are no marks), a number means that pull only
  - `CastAheadRecorder.Pulls(key) -> array of { first = line index, last = line index, marks = number }`
  - `CastAheadRecorder.EXPORT_LIMIT = 60000`; `Export` returns `nil, "too long"` above it when `pull` is nil
  - end of key prints `Cast Ahead: <casts> casts, <calls> calls, <marks> marks recorded - /ca report`

- [ ] **Step 1: Write the failing test**

```lua
-- Export: header, summaries, the marked pull, a footer that counts lines.
CastAheadDB = { reportCalls = true, importantOnly = false }
enter()
fire("CHALLENGE_MODE_START")
fire("PLAYER_REGEN_DISABLED")
castFor(3.0)
CastAheadRecorder.Mark("called wrong")
fire("PLAYER_REGEN_ENABLED")
fire("PLAYER_REGEN_DISABLED")
castFor(3.0)
fire("PLAYER_REGEN_ENABLED")
reset()
local ek = CastAheadRecorder.Current()
local text = CastAheadRecorder.Export(ek)
local lines = {}
for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
check(lines[1]:match("^CastAhead%-Report 1 addon=.- data=%x+ instance=1877 level=%d+"), "the header names format, addon, data and instance, got " .. lines[1])
check(text:find("\n# mark 1 ", 1, true), "each mark gets a human summary line")
local body = 0
for _, l in ipairs(lines) do if l:match("^%d+|") then body = body + 1 end end
check(lines[#lines] == "CastAhead-Report end lines=" .. body, "the footer counts the event lines, got " .. lines[#lines])
local pulls = CastAheadRecorder.Pulls(ek)
check(#pulls == 2 and pulls[1].marks == 1 and pulls[2].marks == 0, "pulls are split on PULL lines with their marks")
check(not text:find("|PULL|-|in\n.*|PULL|-|in", 1), "only the marked pull is exported")
if os.getenv("CA_WRITE_FIXTURE") == "1" then
    local f = assert(io.open("tools/fixtures/export_sample.txt", "w"))
    f:write(text) f:close()
end
CastAheadRecorder.EndKey("completed")
CastAheadDB = nil
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement**

```lua
R.EXPORT_LIMIT = 60000

local function Kind(line) return line:match("^%d+|(%u+)|") end

function R.Pulls(key)
    local pulls, current = {}, nil
    for i, line in ipairs(key.lines) do
        if line:find("|PULL|-|in", 1, true) then
            current = { first = i, last = i, marks = 0 }
            pulls[#pulls + 1] = current
        elseif current then
            current.last = i
            if Kind(line) == "MARK" then current.marks = current.marks + 1 end
            if line:find("|PULL|-|out", 1, true) then current = nil end
        end
    end
    return pulls
end

local function Clock(ms)
    ms = tonumber(ms) or 0
    return string.format("%02d:%04.1f", math.floor(ms / 60000), (ms % 60000) / 1000)
end

local function Summaries(key, first, last)
    local out = {}
    for i = first, last do
        local line = key.lines[i]
        if Kind(line) == "MARK" then
            local t, n, _, note = line:match("^(%d+)|MARK|%-|(%d+)|(%d)|(.*)$")
            local snap = key.lines[i + 1]
            local claim = snap and snap:match("|SNAP|%d+|(%d+)|") or "-"
            local call = snap and snap:match("|SNAP|%d+|[^|]*|([^|]*)|") or "-"
            out[#out + 1] = string.format("# mark %s at %s: claimed %s/%s; note: %s", n, Clock(t), claim, call, note ~= "" and note or "-")
        end
    end
    return out
end

function R.Export(key, pull)
    local first, last = 1, #key.lines
    local ranges = {}
    local pulls = R.Pulls(key)
    if pull then
        ranges[1] = pulls[pull]
    else
        for _, p in ipairs(pulls) do if p.marks > 0 then ranges[#ranges + 1] = p end end
        for i, line in ipairs(key.lines) do
            if Kind(line) == "MARK" then
                local inside = false
                for _, p in ipairs(ranges) do if i >= p.first and i <= p.last then inside = true end end
                if not inside then ranges[#ranges + 1] = { first = i, last = math.min(#key.lines, i + 40), marks = 1 } end
            end
        end
        if #ranges == 0 then ranges[1] = { first = first, last = last, marks = 0 } end
    end
    local out = { string.format("CastAhead-Report %d addon=%s data=%s instance=%s level=%s affixes=%s role=%s len=%d%s",
        key.format, key.addon, key.data, key.instance, key.level, key.affixes, key.role,
        math.floor(((key.endedAt or GetTime()) - key.startedAt) * 1000 + 0.5),
        key.truncated and (" truncated=" .. key.truncated) or "") }
    local body = 0
    for _, r in ipairs(ranges) do
        for _, s in ipairs(Summaries(key, r.first, r.last)) do out[#out + 1] = s end
    end
    for _, r in ipairs(ranges) do
        for i = r.first, r.last do
            out[#out + 1] = key.lines[i]
            body = body + 1
        end
    end
    out[#out + 1] = "CastAhead-Report end lines=" .. body
    local text = table.concat(out, "\n")
    if not pull and #text > R.EXPORT_LIMIT then return nil, "too long" end
    return text
end

function R.Summary(key)
    local casts, calls = 0, 0
    for _, line in ipairs(key.lines) do
        local kind = Kind(line)
        if kind == "STOP" then casts = casts + 1 end
        if kind == "START" and not line:match("|START|%d+|%d|[^|]*|%-|") then calls = calls + 1 end
    end
    return string.format("|cff33ff99Cast Ahead|r %d casts, %d calls, %d marks recorded - /ca report", casts, calls, key.marks or 0)
end
```

Make `R.EndKey` print `R.Summary(key)` when `result == "completed"` and the key has at least one `STOP` line.

- [ ] **Step 4: Run tests; then write the golden fixture once:** `MSYS_NO_PATHCONV=1 wsl bash -lc 'cd ".../CastAhead" && CA_WRITE_FIXTURE=1 ~/luaenv/bin/lua test_core.lua | tail -1'` and check `tools/fixtures/export_sample.txt` exists.

- [ ] **Step 5: Commit**

```bash
git add Recorder.lua test_core.lua tools/fixtures/export_sample.txt
git commit -m "feat: export text with mark summaries and a counted footer"
```

---

### Task 5: tools/audit.py - parse, issue report, owner audit

**Files:**
- Create: `tools/audit.py`
- Create: `tools/test_audit.py`

**Interfaces:**
- Consumes: the line formats of Tasks 2-4 and `tools/fixtures/export_sample.txt`.
- Produces:
  - `parse_export(text) -> Report(header: dict, summaries: list[str], lines: list[Line], complete: bool, problems: list[str])`
  - `Line(t: int, kind: str, slot: str, fields: list[str])`
  - `load_data_rows(data_lua_text) -> dict[int, dict]` (spell id -> row with `name`, `mob`, `cast`, `channel`)
  - `issue_report(report, rows) -> str` (Markdown)
  - `owner_audit(journal_key, log_path, rows) -> str` (Markdown)
  - CLI: `python tools/audit.py issue <export.txt> [--data Data.lua]` and `python tools/audit.py owner <SavedVariables CastAhead.lua> <combat log> [--key N] [--data Data.lua] [--out F:/claude-data/castahead-audit/]`

- [ ] **Step 1: Write the failing tests**

```python
import pathlib
from audit import parse_export, load_data_rows, issue_report

HERE = pathlib.Path(__file__).parent
SAMPLE = (HERE / "fixtures" / "export_sample.txt").read_text(encoding="utf-8")


def test_the_golden_export_parses_completely():
    report = parse_export(SAMPLE)
    assert report.complete and not report.problems
    assert report.header["instance"] == "1877"
    assert any(line.kind == "MARK" for line in report.lines)
    assert all(line.t >= 0 for line in report.lines)


def test_a_lost_tail_is_reported_not_parsed_as_complete():
    cut = "\n".join(SAMPLE.splitlines()[:-3])
    report = parse_export(cut)
    assert not report.complete
    assert any("footer" in p for p in report.problems)


def test_a_line_count_mismatch_is_reported():
    lines = SAMPLE.splitlines()
    report = parse_export("\n".join(lines[:-2] + [lines[-1]]))
    assert not report.complete


def test_rows_are_read_from_data_lua():
    rows = load_data_rows('CastAheadData = {\n    [1877] = { name = "T",\n        { spell = 100, npc = 1, mob = "Caster", name = "Big", cast = 3.0, cd = { 20.0 }, first = 5.0, n = 9, firstN = 9, level = 91, offset = 0.0, },\n    },\n}\n')
    assert rows[100]["name"] == "Big" and rows[100]["cast"] == 3.0


def test_the_issue_report_names_the_marked_claim():
    report = parse_export(SAMPLE)
    text = issue_report(report, {100: {"name": "Big", "mob": "Caster", "cast": 3.0, "channel": False}})
    assert "mark 1" in text and "Big" in text
```

- [ ] **Step 2: Run to verify they fail:** `python -m pytest -q tools/test_audit.py` -> import error.

- [ ] **Step 3: Implement `tools/audit.py`**

```python
"""Read Cast Ahead key journals and wrong-call reports, and check them against the data and the combat log.

    python tools/audit.py issue <export.txt> [--data Data.lua]
    python tools/audit.py owner <SavedVariables CastAhead.lua> <combat log> [--key N] [--data Data.lua] [--out DIR]
"""
import argparse
import csv
import datetime
import pathlib
import re
import statistics
import sys
from dataclasses import dataclass, field

HEADER = re.compile(r"^CastAhead-Report (\d+) (.*)$")
FOOTER = re.compile(r"^CastAhead-Report end lines=(\d+)$")
ROW = re.compile(r'\{ spell = (\d+), npc = (\d+), mob = "([^"]*)", name = "([^"]*)", cast = ([\d.]+),(.*?)\},')


@dataclass
class Line:
    t: int
    kind: str
    slot: str
    fields: list


@dataclass
class Report:
    header: dict = field(default_factory=dict)
    summaries: list = field(default_factory=list)
    lines: list = field(default_factory=list)
    complete: bool = False
    problems: list = field(default_factory=list)


def parse_line(text):
    parts = text.split("|")
    return Line(int(parts[0]), parts[1], parts[2], parts[3:])


def parse_export(text):
    report = Report()
    rows = [r.strip() for r in text.splitlines() if r.strip()]
    if not rows or not HEADER.match(rows[0]):
        report.problems.append("no CastAhead-Report header")
        return report
    version, rest = HEADER.match(rows[0]).groups()
    report.header = dict(kv.split("=", 1) for kv in rest.split() if "=" in kv)
    report.header["format"] = version
    footer = FOOTER.match(rows[-1])
    body = rows[1:-1] if footer else rows[1:]
    for row in body:
        if row.startswith("# "):
            report.summaries.append(row[2:])
        elif re.match(r"^\d+\|", row):
            report.lines.append(parse_line(row))
        else:
            report.problems.append("unreadable line: " + row[:60])
    if not footer:
        report.problems.append("footer missing - the paste was cut short")
    elif int(footer.group(1)) != len(report.lines):
        report.problems.append("footer says %s lines, %d arrived" % (footer.group(1), len(report.lines)))
    report.complete = not report.problems
    return report


def load_data_rows(text):
    rows = {}
    for m in ROW.finditer(text):
        rows[int(m.group(1))] = {"npc": int(m.group(2)), "mob": m.group(3), "name": m.group(4),
                                 "cast": float(m.group(5)), "channel": "channel = true" in m.group(6)}
    return rows


def name(rows, spell):
    try:
        row = rows.get(int(spell))
    except (TypeError, ValueError):
        return str(spell)
    return "%s (%s)" % (row["name"], spell) if row else str(spell)


def clock(ms):
    ms = int(ms)
    return "%02d:%04.1f" % (ms // 60000, (ms % 60000) / 1000)


def issue_report(report, rows):
    out = ["## Cast Ahead report, %s level %s, addon %s, data %s" % (
        report.header.get("instance"), report.header.get("level"), report.header.get("addon"), report.header.get("data"))]
    if report.problems:
        out.append("Problems: " + "; ".join(report.problems))
    lines = report.lines
    for i, line in enumerate(lines):
        if line.kind != "MARK":
            continue
        out.append("\n### mark %s at %s - note: %s" % (line.fields[0], clock(line.t), line.fields[2] or "-"))
        for snap in (l for l in lines[i + 1:] if l.kind == "SNAP"):
            claimed, call, cands, since, preds = snap.fields[:5]
            out.append("- plate %s: casting %s, claimed %s, call %s, candidates %s" % (
                snap.slot, "-" if since == "-" else clock(since), name(rows, claimed), call,
                ", ".join(name(rows, c) for c in cands.split(",") if c) or "-"))
            history = [l for l in lines[:i] if l.slot == snap.slot and l.kind in ("STOP", "START", "STEP")][-12:]
            for h in history:
                if h.kind == "STOP":
                    out.append("  - %s stop after %s ms -> %s, call %s" % (
                        clock(h.t), h.fields[1], ", ".join(name(rows, c) for c in h.fields[2].split(",") if c) or "none", h.fields[3]))
                    measured = int(h.fields[1]) / 1000 if h.fields[1].isdigit() else None
                    if measured is not None:
                        fits = [name(rows, s) for s, r in rows.items() if abs(r["cast"] - measured) <= 0.25]
                        out.append("    - rows with that cast length: " + (", ".join(fits) or "none"))
                elif h.kind == "STEP":
                    out.append("    - step %s: %s" % (h.fields[0], ", ".join(name(rows, c) for c in h.fields[1].split(",") if c) or "none"))
            if snap.kind != "SNAP":
                break
    return "\n".join(out)


def read_journal(sv_text, index=None):
    """Pull the key journals out of SavedVariables without a full Lua parser: each key's lines are plain strings."""
    keys = []
    for block in re.finditer(r'\["lines"\] = \{(.*?)\n\s*\}', sv_text, re.S):
        keys.append([parse_line(s) for s in re.findall(r'"(\d+\|[^"]*)"', block.group(1))])
    return keys[index] if index is not None else keys[-1]


def log_events(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            stamp, _, rest = raw.partition("  ")
            if not rest:
                continue
            try:
                when = datetime.datetime.strptime(stamp.strip()[:23], "%m/%d/%Y %H:%M:%S.%f")
            except ValueError:
                continue
            yield when, next(csv.reader([rest]))


def owner_audit(lines, log_path, rows):
    selfs = [l for l in lines if l.kind == "SELF"]
    player_casts, creature_starts, first_hit = [], [], {}
    for when, p in log_events(log_path):
        if p[0] == "SPELL_CAST_SUCCESS" and p[1].startswith("Player-"):
            player_casts.append((when, p[9]))
        elif p[0] == "SPELL_CAST_START" and p[1].startswith("Creature-"):
            creature_starts.append((when, p[1], int(p[9])))
        elif p[0].endswith("_DAMAGE") and len(p) > 5 and p[5].startswith("Creature-"):
            first_hit.setdefault(p[5], when)
    offsets = []
    for s in selfs:
        for when, spell in player_casts:
            if spell == s.fields[0]:
                offsets.append(when.timestamp() * 1000 - s.t)
    if len(offsets) < 5:
        return "Not enough player casts to align the journal with the log (%d)." % len(offsets)
    base = statistics.median(offsets)
    out = ["## Owner audit", "clock offset %.0f ms from %d anchors" % (base, len(offsets))]
    wrong = right = 0
    guid_of = {}
    for start in (l for l in lines if l.kind == "START"):
        at = base + start.t
        truth = min(creature_starts, key=lambda c: abs(c[0].timestamp() * 1000 - at), default=None)
        if not truth or abs(truth[0].timestamp() * 1000 - at) > 400:
            continue
        guid_of.setdefault(start.slot, truth[1])
        claimed = start.fields[1]
        if claimed == "-":
            continue
        if int(claimed) == truth[2]:
            right += 1
        else:
            wrong += 1
            out.append("- %s plate %s: claimed %s, really %s" % (clock(start.t), start.slot, name(rows, claimed), name(rows, truth[2])))
    out.insert(2, "start claims: %d right, %d wrong" % (right, wrong))

    errors = {}
    for pred in (l for l in lines if l.kind == "PRED"):
        spell, due = int(pred.fields[0]), base + int(pred.fields[1])
        guid = guid_of.get(pred.slot)
        hits = [c for c in creature_starts if c[2] == spell and (guid is None or c[1] == guid)
                and abs(c[0].timestamp() * 1000 - due) <= 15000]
        if hits:
            real = min(hits, key=lambda c: abs(c[0].timestamp() * 1000 - due))
            errors.setdefault(spell, []).append((real[0].timestamp() * 1000 - due) / 1000)
    out.append("\n### Countdown error per spell (real start minus predicted, seconds)")
    for spell, errs in sorted(errors.items(), key=lambda kv: -statistics.median(abs(e) for e in kv[1])):
        out.append("- %s: n %d, median %+.1f, worst %+.1f" % (name(rows, spell), len(errs), statistics.median(errs), max(errs, key=abs)))

    out.append("\n### Engage seen by the addon vs first damage in the log (seconds)")
    for engage in (l for l in lines if l.kind == "ENGAGE"):
        guid = guid_of.get(engage.slot)
        if guid and guid in first_hit:
            delta = (base + engage.t - first_hit[guid].timestamp() * 1000) / 1000
            out.append("- %s plate %s: %+.1f" % (clock(engage.t), engage.slot, delta))
    return "\n".join(out)


def main(argv):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="mode", required=True)
    a = sub.add_parser("issue")
    a.add_argument("export")
    a.add_argument("--data", default=str(pathlib.Path(__file__).parent.parent / "Data.lua"))
    b = sub.add_parser("owner")
    b.add_argument("saved")
    b.add_argument("log")
    b.add_argument("--key", type=int)
    b.add_argument("--data", default=str(pathlib.Path(__file__).parent.parent / "Data.lua"))
    b.add_argument("--out")
    args = ap.parse_args(argv)
    rows = load_data_rows(pathlib.Path(args.data).read_text(encoding="utf-8"))
    if args.mode == "issue":
        print(issue_report(parse_export(pathlib.Path(args.export).read_text(encoding="utf-8")), rows))
        return
    lines = read_journal(pathlib.Path(args.saved).read_text(encoding="utf-8"), args.key)
    text = owner_audit(lines, args.log, rows)
    if args.out:
        out = pathlib.Path(args.out)
        out.mkdir(parents=True, exist_ok=True)
        target = out / (datetime.date.today().isoformat() + "-audit.md")
        target.write_text(text, encoding="utf-8")
        print("wrote", target)
    else:
        print(text)


if __name__ == "__main__":
    main(sys.argv[1:])
```

When the export's `data` checksum differs from the current `Data.lua`, the caller passes `--data` with the file from the matching release tag (`git show v<addon>:Data.lua > /tmp/Data_<addon>.lua`); `issue_report` prints the header so the mismatch is visible.

- [ ] **Step 4: Run** `python -m pytest -q tools/test_audit.py` -> all pass. Also `python -m pytest -q tools` (gen tests keep passing).

- [ ] **Step 5: Commit**

```bash
git add tools/audit.py tools/test_audit.py
git commit -m "feat: audit tool for journals and wrong-call reports"
```

---

### Task 6: Switches, /ca report window, mark button

**Files:**
- Modify: `Options.lua` (`reportCalls` and `markScreenshot` in `SWITCHES`; Advanced group grows)
- Create: `ReportWindow.lua` (window, key dropdown, export box, per-mark notes, mark button); add to `CastAhead.toc` after `Recorder.lua`
- Modify: `UI.lua` (`/ca report`, `/ca mark [note]` in the slash handler)
- Modify: `test_core.lua`

**Interfaces:**
- Consumes: `CastAheadRecorder.Keys`, `Export`, `Pulls`, `Mark`.
- Produces: `CastAheadReport.Toggle()`, `CastAheadReport.RefreshButton()`.

- [ ] **Step 1: Write the failing test**

```lua
-- The report window and the mark command build without errors in the stubs.
CastAheadDB = { reportCalls = true }
fire("CHALLENGE_MODE_START")
ok, err = pcall(SlashCmdList.CASTAHEAD, "mark slash note")
check(ok, "/ca mark works: " .. tostring(err))
check(CastAheadRecorder.Current().lines[#CastAheadRecorder.Current().lines]:find("slash note", 1, true)
    or table.concat(CastAheadRecorder.Current().lines, "\n"):find("slash note", 1, true), "the slash note reaches the mark")
ok, err = pcall(SlashCmdList.CASTAHEAD, "report")
check(ok, "/ca report opens: " .. tostring(err))
CastAheadRecorder.EndKey("completed")
CastAheadDB = nil
```

Add `dofile("ReportWindow.lua")` after `dofile("Recorder.lua")` in `test_core.lua`.

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Options** - in `SWITCHES`:

```lua
    reportCalls = { label = "Report wrong calls", defaultOff = true,
        tip = "Keeps a journal of each key and lets you mark a wrong call with a key binding or the Mark button. /ca report gives you the text to paste into a GitHub issue or a CurseForge comment. No names of people are recorded." },
    markScreenshot = { label = "Screenshot on mark",
        tip = "Takes a game screenshot when you mark a wrong call, so the moment can be seen as it was." },
```

In the Advanced group: height `62 -> 114`, and below the `devMode` switch:

```lua
    local reportSwitch = BuildSwitch(panel, "reportCalls", { "TOPLEFT", devSwitch, "BOTTOMLEFT", 0, -4 }, function()
        if CastAheadReport then CastAheadReport.RefreshButton() end
    end)
    BuildSwitch(panel, "markScreenshot", { "TOPLEFT", reportSwitch, "BOTTOMLEFT", 0, -4 })
```

(`devSwitch` is the return value of the existing `BuildSwitch(panel, "devMode", ...)` call; capture it.)

- [ ] **Step 4: `ReportWindow.lua`**

```lua
CastAheadReport = {}
local W = CastAheadReport
local window, keyIndex, button

local function Build()
    window = CreateFrame("Frame", "CastAheadReportWindow", UIParent, "BasicFrameTemplateWithInset")
    window:SetSize(640, 460)
    window:SetPoint("CENTER")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window.title = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    window.title:SetPoint("TOP", 0, -5)
    window.title:SetText("Cast Ahead - report")
    window.hint = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    window.hint:SetPoint("TOPLEFT", 12, -30)
    window.hint:SetText("Ctrl+A, Ctrl+C, then paste into a GitHub issue (github.com/AqueGen/CastAhead/issues) or a CurseForge comment.")
    window.keys = CreateFrame("DropdownButton", nil, window, "WowStyle1DropdownTemplate")
    window.keys:SetSize(300, 22)
    window.keys:SetPoint("TOPLEFT", 12, -48)
    local scroll = CreateFrame("ScrollFrame", nil, window, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -80)
    scroll:SetPoint("BOTTOMRIGHT", -30, 12)
    window.box = CreateFrame("EditBox", nil, scroll)
    window.box:SetMultiLine(true)
    window.box:SetFontObject(ChatFontNormal)
    window.box:SetWidth(580)
    window.box:SetAutoFocus(false)
    window.box:SetScript("OnEscapePressed", function() window:Hide() end)
    scroll:SetScrollChild(window.box)
    tinsert(UISpecialFrames, "CastAheadReportWindow")
end

local function Fill()
    local keys = CastAheadRecorder.Keys()
    keyIndex = keyIndex or #keys
    window.keys:SetupMenu(function(_, root)
        for i = #keys, 1, -1 do
            local k = keys[i]
            root:CreateRadio(string.format("%s +%s (%d marks)", k.name or "?", k.level or 0, k.marks or 0),
                function() return keyIndex == i end, function() keyIndex = i Fill() end)
        end
    end)
    local key = keys[keyIndex]
    local text, problem = key and CastAheadRecorder.Export(key)
    if not key then
        text = "Nothing recorded yet. Turn on Report wrong calls, play a key, mark wrong calls with the key binding or the Mark button."
    elseif problem then
        text = "This key is too long for one paste. Pick a single pull with /ca report <pull number>."
    end
    window.box:SetText(text)
    window.box:HighlightText()
    window.box:SetFocus()
end

function W.Toggle(pull)
    if not window then Build() end
    if window:IsShown() and not pull then window:Hide() return end
    window:Show()
    Fill()
    if pull then
        local key = CastAheadRecorder.Keys()[keyIndex]
        if key then window.box:SetText(CastAheadRecorder.Export(key, pull) or "") window.box:HighlightText() end
    end
end

function W.RefreshButton()
    local want = CastAheadRecorder and CastAheadRecorder.Enabled() and CastAheadConfig.Get("reportCalls") == true
    if want and not button then
        button = CreateFrame("Button", "CastAheadMarkButton", UIParent, "UIPanelButtonTemplate")
        button:SetSize(64, 22)
        button:SetPoint("CENTER", UIParent, "CENTER", 0, -260)
        button:SetText("Mark")
        button:SetMovable(true)
        button:RegisterForDrag("LeftButton")
        button:SetScript("OnDragStart", button.StartMoving)
        button:SetScript("OnDragStop", button.StopMovingOrSizing)
        button:SetScript("OnClick", function() CastAheadRecorder.Mark() end)
    end
    if button then button:SetShown(want and true or false) end
end
```

- [ ] **Step 5: Slash commands in `UI.lua`** (next to the `timeline`/`debug` words):

```lua
    if word == "report" then
        if CastAheadReport then CastAheadReport.Toggle(tonumber(msg:match("^%s*%a+%s+(%d+)"))) end
        return
    end
    if word == "mark" then
        if CastAheadRecorder then CastAheadRecorder.Mark(msg:match("^%s*%a+%s+(.+)$")) end
        return
    end
```

Call `CastAheadReport.RefreshButton()` on `PLAYER_ENTERING_WORLD` from Core's handler (guarded by `if CastAheadReport then`).

- [ ] **Step 6: Run tests, commit**

```bash
git add Options.lua ReportWindow.lua UI.lua CastAhead.toc Core.lua test_core.lua
git commit -m "feat: report switch, /ca report window and the Mark button"
```

---

### Task 7: Issue form, README, packaging, end-to-end check

**Files:**
- Create: `.github/ISSUE_TEMPLATE/wrong-call.yml`
- Modify: `README.md` (a "Reporting a wrong call" section and the new commands)
- Modify: `.pkgmeta` (ignore `docs`)

- [ ] **Step 1: Issue form**

```yaml
name: Wrong call
description: Cast Ahead named the wrong spell or called at the wrong time
labels: ["wrong call"]
body:
  - type: markdown
    attributes:
      value: Turn on "Report wrong calls" (Settings > Advanced), mark the moment with the key binding or the Mark button, then run /ca report and paste the text below.
  - type: textarea
    id: report
    attributes:
      label: Report text from /ca report
      render: text
    validations:
      required: true
  - type: textarea
    id: truth
    attributes:
      label: What really happened (optional)
      description: The spell or the moment you saw, in any language.
```

- [ ] **Step 2: README** - add under Commands: `/ca report` (copy the report text), `/ca mark [note]` (mark a wrong call); add a short "Reporting a wrong call" section describing the switch, the key binding under Key Bindings > Cast Ahead, and the issue link.

- [ ] **Step 3: `.pkgmeta`** - add `- docs` to the `ignore:` list.

- [ ] **Step 4: End-to-end on the Voidscar log** (owner audit): with v0.12.0 data there is no journal, so build the check from a fresh key instead: play one key with Development mode on, `/reload`, then `python tools/audit.py owner "<WTF>/Account/*/SavedVariables/CastAhead.lua" "<WoW>/Logs/WoWCombatLog-<date>.txt" --out F:/claude-data/castahead-audit`. Expect a clock offset from 5+ anchors and a start-claim count matching the replay of the same log within a few casts.

- [ ] **Step 5: CPU check** - run `~/luaenv/bin/lua test_replay.lua ../CastAheadTools/replay_1003.lua` with `CastAheadDB = { reportCalls = true }` set in a small wrapper and without; compare wall time with `time`; the difference must stay under 5%.

- [ ] **Step 6: Full test run and commit**

```bash
git add .github/ISSUE_TEMPLATE/wrong-call.yml README.md .pkgmeta
git commit -m "docs: wrong-call issue form, README section, keep docs out of the package"
```
