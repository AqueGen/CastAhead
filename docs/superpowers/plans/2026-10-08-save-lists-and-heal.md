# Save Lists, Heal Calls and Saves View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Several buttons per save size (spells and bag items), a "heal up" call right after a big hit, and a Saves view in the `/ca` window that lists every hit that calls a save.

**Architecture:** `Saves.lua` gains an entry model (spell id or `{ use = spellID }` item) with availability (known spell; item in bags and off cooldown, resolved by a bag scan out of combat), multi-icon output and a heal decision. Core's centre block draws up to three icons per line and fires `HEAL` at the end of a trash cast that carried `BIG`; `Saves.Tick` fires `HEAL` at the end of a boss call that was `BIG`. The generator adds display fields to `Defensives.lua`; a new view in UI.lua reads them through a pure `CastAheadSaves.ViewRows`.

**Tech Stack:** WoW 12.1 Lua 5.1 (headless tests in WSL `~/luaenv/bin/lua`), Python 3 + pytest for the private generator.

**Spec:** `docs/superpowers/specs/2026-10-08-save-lists-and-heal-design.md` (builds on `docs/superpowers/specs/2026-10-07-defensive-calls-design.md`)

## Global Constraints

- Player-facing name "Cast Ahead". English UI text and voice, like the rest of the addon.
- Never compare/test a value 12.x may return Secret. `UnitHealth` is `SecretReturns`; do not use it. Item APIs `C_Item.GetItemCount`, `C_Item.GetItemCooldown` (returns `startTimeSeconds, durationSeconds, enableCooldownTimer`), `C_Item.GetItemSpell` (returns `spellName, spellID`), `C_Item.GetItemIconByID`, `C_Container.GetContainerNumSlots`, `C_Container.GetContainerItemID` carry no Secret marker (Blizzard_APIDocumentationGenerated ItemDocumentation.lua:412-435, 589, 948-962; ContainerDocumentation.lua:175, 313; event `BAG_UPDATE_DELAYED` at :677).
- Bag scan (item -> use spell) only out of combat; count and cooldown read live.
- Entry shape everywhere: a spell id number, or `{ use = <use spell id> }` for an item.
- One alert per call; HEAL is its own call after the hit (owner accepted 2026-10-08). HEAL fires only for a hit whose call was `BIG` for the player's role and only when a heal entry is available. No HEAL for aura-only hits.
- Switches: `saveCalls` off silences everything incl. HEAL; new `healCalls` (nil = on) silences only HEAL.
- Core keeps working when any new module or data global is absent (nil guards).
- Shipped heal default: Warlock specs 265/266/267 `heal = { { use = 452930 } }` (Demonic Healthstone use spell seen in top-player casts). No potion ids are shipped.
- Player override storage: `CastAheadDB.saveButtons[specID] = { small = {...}, big = {...}, heal = {...} }`; a size present in the override replaces the shipped list; an old single-number override (`saveButtons[spec].small = 108416`) migrates to `{ 108416 }`.
- No code comments except facts nobody can re-check. Tests: both Lua suites print OK (`MSYS_NO_PATHCONV=1 wsl bash -lc 'cd "/mnt/g/Games/World of Warcraft/_retail_/Interface/AddOns/CastAhead" && ~/luaenv/bin/lua test.lua | tail -1 && ~/luaenv/bin/lua test_core.lua | tail -1'`), `python -m pytest -q tools` in CastAhead, `python -m pytest -q test_defensives.py` in CastAheadTools.
- Branch `feat/defensive-calls`, push after each task (`gh auth switch -u AqueGen` first if push is rejected).

## Review Focus

1. A heal item that runs out mid-key (last Healthstone used) must stop showing and stop triggering HEAL without a reload - pinned in Task 1 (count read live) and Task 3.
2. A player whose override list contains an item they no longer carry, or a spell from another spec, must still get the next available entry, not nothing - pinned in Task 1.
3. Bag changes during combat must not trigger a scan in combat; the scan runs on the next out-of-combat point - pinned in Task 1.
4. A BIG trash cast that is interrupted (kicked) must not produce HEAL: the hit never landed - pinned in Task 3.
5. Typing garbage into the Add box (unknown name, an item without a use spell) must leave the list unchanged and say why - pinned in Task 5.

---

### Task 1: Entry model, availability and migration (Saves.lua)

**Files:**
- Modify: `Saves.lua` (replace `Button`/`Icon` internals; add entries API and bag scan)
- Modify: `Config.lua` `C.Migrate` (old single-number override to list)
- Modify: `SaveButtons.lua` (add warlock heal default)
- Modify: `Core.lua` event handler (call `CastAheadSaves.ScanBags()` on `BAG_UPDATE_DELAYED`, `PLAYER_ENTERING_WORLD`, `PLAYER_REGEN_ENABLED` when `CastAheadSaves.BagsPending()`; register `BAG_UPDATE_DELAYED`; all nil-guarded)
- Test: `test_core.lua`

**Interfaces:**
- Produces:
  - `CastAheadSaves.List(size) -> array of entries` - override list for the current spec if present for that size, else shipped list; `size` in `"small"|"big"|"heal"`.
  - `CastAheadSaves.Available(size) -> array of { kind = "spell"|"item", id = spellID|itemID, icon = texture }` in list order; spell entries need `IsPlayerSpell(id)`; item entries need a bag item whose use spell equals `entry.use`, `C_Item.GetItemCount(itemID) > 0`, and cooldown over (`start == 0 or start + duration <= GetTime()`).
  - `CastAheadSaves.Button(size) -> spellID|nil` - first available spell entry's id (kept for compatibility).
  - `CastAheadSaves.Icons(advice) -> array of textures (max 3)` for SMALL/BIG/HEAL advice; `CastAheadSaves.Icon(advice)` returns `Icons(advice)[1]`.
  - `CastAheadSaves.ScanBags()` - out of combat: rebuild `useSpell -> itemID` from bags 0..5 via `C_Container.GetContainerNumSlots/GetContainerItemID` and `C_Item.GetItemSpell`; in combat: set pending and return. `CastAheadSaves.BagsPending() -> bool`.
- Remove the per-size `iconCache` (availability is live now); `Refresh` keeps re-registering aura sounds.

- [ ] **Step 1: Write failing tests** (append to `test_core.lua`; restore every stub afterwards):

```lua
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
    CastAheadSaveButtons = { [265] = { small = { 108416, { use = 452930 } }, big = { 104773 }, heal = { { use = 452930 } } } }
    CastAheadDB = {}
    CastAheadSaves.ScanBags()
    local small = CastAheadSaves.Available("small")
    check(#small == 2 and small[1].kind == "spell" and small[2].kind == "item" and small[2].id == 5512, "spell then healthstone item")
    counts[5512] = 0
    check(#CastAheadSaves.Available("small") == 1, "an item with count 0 is not available, read live")
    counts[5512] = 3
    cds[5512] = { now - 10, 60 }
    check(#CastAheadSaves.Available("heal") == 0, "an item on cooldown is not available")
    cds[5512] = { 0, 0 }
    CastAheadDB.saveButtons = { [265] = { big = { 999, 104773 } } }
    check(CastAheadSaves.Available("big")[1].id == 104773, "an override skips an unknown spell to the next entry")
    check(#CastAheadSaves.Available("small") == 2, "a size missing from the override keeps the shipped list")
    CastAheadDB = { saveButtons = { [265] = { small = 108416 } } }
    CastAheadConfig.Migrate()
    check(type(CastAheadDB.saveButtons[265].small) == "table" and CastAheadDB.saveButtons[265].small[1] == 108416, "old single-number override migrates to a list")
    InCombatLockdown = function() return true end
    bags[0][3] = 191380
    CastAheadSaves.ScanBags()
    check(CastAheadSaves.BagsPending(), "no bag scan in combat, marked pending")
    InCombatLockdown = function() return false end
    fire("PLAYER_REGEN_ENABLED")
    check(not CastAheadSaves.BagsPending(), "the pending scan runs after combat")
    check(#CastAheadSaves.Icons(CastAheadMatch.ADVICE.SMALL) == 2, "icons follow the available list")
    C_Container, C_Item.GetItemCount = saved.C_Container, saved.GetItemCount
    C_Item.GetItemSpell, C_Item.GetItemCooldown, C_Item.GetItemIconByID = nil, nil, nil
    GetSpecialization, GetSpecializationRole, GetSpecializationInfo, IsPlayerSpell, InCombatLockdown = nil, nil, nil, nil, nil
    CastAheadSaveButtons = {}
    CastAheadDB = {}
end
```

(Adjust only stub plumbing that conflicts with stubs already defined earlier in test_core.lua - e.g. if `C_Item` exists, extend it - keeping every assertion.)

- [ ] **Step 2: Run to verify failure** - Expected: `attempt to call field 'ScanBags' (a nil value)` or FAIL lines.

- [ ] **Step 3: Implement** in `Saves.lua`:

```lua
local useToItem = {}
local bagsPending = false

local function Shipped(spec, size)
    local s = CastAheadSaveButtons and CastAheadSaveButtons[spec]
    return s and s[size] or {}
end

function S.List(size)
    local spec = S.SpecID()
    if not spec then return {} end
    local o = CastAheadDB and CastAheadDB.saveButtons and CastAheadDB.saveButtons[spec]
    if o and type(o[size]) == "table" then return o[size] end
    return Shipped(spec, size)
end

function S.ScanBags()
    if InCombatLockdown and InCombatLockdown() then bagsPending = true return end
    bagsPending = false
    wipe(useToItem)
    if not (C_Container and C_Item and C_Item.GetItemSpell) then return end
    for bag = 0, 5 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local item = C_Container.GetContainerItemID(bag, slot)
            if item then
                local _, use = C_Item.GetItemSpell(item)
                if use and not useToItem[use] then useToItem[use] = item end
            end
        end
    end
end

function S.BagsPending() return bagsPending end

local function ItemReady(item)
    if not (C_Item and C_Item.GetItemCount and (C_Item.GetItemCount(item) or 0) > 0) then return false end
    local start, duration = 0, 0
    if C_Item.GetItemCooldown then start, duration = C_Item.GetItemCooldown(item) end
    return (start or 0) == 0 or (start + (duration or 0)) <= GetTime()
end

function S.Available(size)
    local out = {}
    for _, e in ipairs(S.List(size)) do
        if type(e) == "number" then
            if Known(e) then
                out[#out + 1] = { kind = "spell", id = e, icon = C_Spell and C_Spell.GetSpellTexture(e) }
            end
        elseif type(e) == "table" and e.use then
            local item = useToItem[e.use]
            if item and ItemReady(item) then
                out[#out + 1] = { kind = "item", id = item, icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(item) }
            end
        end
    end
    return out
end

function S.Button(size)
    for _, e in ipairs(S.Available(size)) do
        if e.kind == "spell" then return e.id end
    end
    return nil
end

local SIZE = { SMALL = "small", BIG = "big", HEAL = "heal" }
function S.Icons(advice)
    local size = advice and SIZE[advice.key]
    local out = {}
    if not size then return out end
    for _, e in ipairs(S.Available(size)) do
        if e.icon then out[#out + 1] = e.icon end
        if #out == 3 then break end
    end
    return out
end

function S.Icon(advice) return S.Icons(advice)[1] end
```

`Config.Migrate`: for each `spec, picks` in `CastAheadDB.saveButtons`, for each size whose value is a number, wrap it into `{ value }`. `SaveButtons.lua`: add `heal = { { use = 452930 } }` to 265, 266, 267. Core: register `BAG_UPDATE_DELAYED`; on it and on `PLAYER_ENTERING_WORLD` call `CastAheadSaves.ScanBags()`; on `PLAYER_REGEN_ENABLED` call it when `CastAheadSaves.BagsPending()` (all behind `if CastAheadSaves then`). Keep `HEAL` advice references safe: `M.ADVICE.HEAL` is added in Task 3; `SIZE` maps by key string so it works before that.

- [ ] **Step 4: Run both suites** - Expected: OK twice. Update any earlier test that relied on the removed icon cache or on a single-number override shape.
- [ ] **Step 5: Commit** `feat: save sizes hold several spells and bag items` and push.

---

### Task 2: Centre block shows up to three icons

**Files:**
- Modify: `Core.lua` (`CenterFrame` line construction, `CenterPick`, `UpdateCenter`; picks carry `icons`)
- Modify: `Saves.lua` `S.Pending` (pending rows carry `icons = S.Icons(c.advice)`)
- Test: `test_core.lua`

**Interfaces:**
- Consumes: `CastAheadSaves.Icons(advice)`.
- Produces: each centre line has `line.icon` (large, existing) and `line.extra[1..2]` (small textures to the right of the large icon, hidden by default); a pick may carry `icons` (array). `UpdateCenter` sets `line.icon` to `icons[1]` (or the existing fallback `pick.icon or SpellIcon(pick.row.spell)`), shows `extra[i]` for `icons[i+1]`, hides the rest.

- [ ] **Step 1: Failing test** - with the Task 1 stubs (spell 108416 known, healthstone in bags), a live trash cast whose call is SMALL shows two icons: `line.icon` texture = spell texture, `line.extra[1]` shown with the item icon, `line.extra[2]` hidden. Use the existing StubRegion `textureValue` field to read textures (see test_core.lua:149-152). A non-save call shows no extras.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.** In `CenterFrame` create two extra textures per line at half the icon size, anchored left-to-right after `line.icon`, with the text anchored after the last visible icon (re-anchor the text's LEFT point to the last shown icon each update). In `CenterPick` set `icons = CastAheadSaves and CastAheadSaves.Icons(advice) or nil` for save advice. Keep `CENTER_LINES` and existing layout otherwise.
- [ ] **Step 4: Both suites OK.**
- [ ] **Step 5: Commit** `feat: centre call shows every ready button for the size` and push.

---

### Task 3: HEAL call after a big hit

**Files:**
- Modify: `Match.lua` (`M.ADVICE.HEAL = { label = "HEAL UP", short = "HEAL", say = "heal up", r = 0.40, g = 0.95, b = 0.45 }`; HEAL is never returned by `M.Advice`)
- Modify: `tools/voice.py` (`"HEAL": "heal up"`), render `Sounds/en/HEAL.ogg` and `HEAL_soon.ogg` with `python tools/voice.py` (AZURE_SPEECH_KEY/REGION read by name inside the script; never print them)
- Modify: `Saves.lua` (`S.HealReady() -> bool`: `CastAheadConfig.Enabled("saveCalls") and CastAheadConfig.Enabled("healCalls") and #S.Available("heal") > 0`; in `S.Tick`, when an entry that fired with `advice == M.ADVICE.BIG` reaches `endAt`, call `CastAheadCore.Announce(M.ADVICE.HEAL)` once if `S.HealReady()`, then remove the entry)
- Modify: `Core.lua` `StopCast` (after the existing Record: if the cast completed - not interrupted - and the final consensus advice is `BIG` and `CastAheadSaves and CastAheadSaves.HealReady()`, call `PlayAdviceSound(CastAheadMatch.ADVICE.HEAL)` and push a 3-second centre line via `CastAheadSaves.Flash(CastAheadMatch.ADVICE.HEAL, now, 3)`)
- Modify: `Saves.lua` add `S.Flash(advice, now, seconds)` - a short-lived pending row with `fired = true` so it shows in the centre (with `Icons(HEAL)`) and never announces.
- Modify: `Options.lua` `SOUND_ROWS` add `"HEAL"`; Defensives tab add switch `healCalls` ("Heal up after a big hit") under "Defensive calls".
- Test: `test.lua` (ADVICE clip loop covers HEAL), `test_core.lua`

**Interfaces:**
- Consumes: `CastAheadSaves.Available("heal")`, existing `StopCast`/interrupt handling (`OnCastInterrupted` marks the cast interrupted before STOP - verify how Core tells a kicked cast from a completed one by reading `OnCastStop`/`OnCastInterrupted` around Core.lua:1960-2030 and use that flag).
- Produces: `CastAheadSaves.HealReady()`, `CastAheadSaves.Flash(advice, now, seconds)`, `CastAheadMatch.ADVICE.HEAL`.

- [ ] **Step 1: Failing tests** (test_core):
  - trash: a cast whose call is BIG completes -> exactly one HEAL alert after the BIG call(s); same cast interrupted (fire the interrupt event the existing kick tests use) -> no HEAL; with healthstone count 0 -> no HEAL; `healCalls=false` -> no HEAL; `saveCalls=false` -> no HEAL and no BIG.
  - boss: a scheduled BIG boss call fires at fireAt, then at endAt exactly one HEAL alert; a SMALL boss call produces no HEAL; a cancelled bar produces no HEAL.
  - aura-only: registering aura sounds never registers HEAL.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** as listed under Files.
- [ ] **Step 4: Both suites OK; `python -m pytest -q tools` passes.**
- [ ] **Step 5: Commit** `feat: heal up call right after a big hit` (+ clips) and push.

---

### Task 4: Display fields in Defensives.lua (generator)

**Files:**
- Modify: `CastAheadTools/def_build.py`, `CastAheadTools/test_defensives.py` (private, not in git)
- Regenerate: `Defensives.lua`
- Test: `test.lua` (data audit)

**Interfaces:**
- Produces: each `CastAheadDefensives.spells[id]` row also has `name` (string, the hit's spell name), `mob` (string, most frequent source name), `boss` (string, encounter name or `""` for trash), `dungeon` (number, the CastAhead instance id: map the WCL dungeon name to the `CastAheadData[instanceID].name` key in Data.lua after normalizing to letters only), `bar` (boolean: a DBM module timer id or its alias resolves to this row).

- [ ] **Step 1: Failing pytest** for a helper `display_fields(runs, row_ids, dungeon_ids, timer_ids, alias)` returning per id `{name, mob, boss, dungeon, bar}` from two tiny synthetic runs (one trash hit, one boss hit inside a pull), choosing the most frequent mob, `bar` True only for the id reached by a timer or alias.
- [ ] **Step 2: Implement** and wire into the Lua writer (strings escaped with `%q`-equivalent: replace `\` and `"`); regenerate with `python def_build.py F:/claude-data/castahead-defensives/wcl <CastAhead>/SaveButtons.lua <CastAhead>/Defensives.lua F:/claude-data/castahead-defensives/boss-coverage.md`.
- [ ] **Step 3: test.lua audit:** every spells row has string `name`, `mob`, `boss`, number `dungeon` that is a key of `CastAheadData`, boolean `bar`.
- [ ] **Step 4: All suites pass.**
- [ ] **Step 5: Commit** `feat: defensive table carries names, mobs, bosses and trigger flags` and push.

---

### Task 5: Settings - three editable lists

**Files:**
- Modify: `Options.lua` `BuildDefensives` (replace the two dropdowns and `SaveChoices`/`CLASS_SPECS` with three list editors), `Saves.lua` (pure parser)
- Test: `test_core.lua` (parser and list writes)

**Interfaces:**
- Produces:
  - `CastAheadSaves.ParseEntry(text) -> entry|nil, reason` - accepts: a number that is a known spell (`IsPlayerSpell`) -> spell id; a number that is an item with a use spell (`C_Item.GetItemSpell`) -> `{ use = spellID }`; an item link `|Hitem:<id>:` -> same as item number; a spell name -> `C_Spell.GetSpellInfo(name).spellID` when `IsPlayerSpell`. Otherwise `nil, "Not a spell you know or an item with a use effect"`.
  - `CastAheadSaves.SetList(size, list)` - writes `CastAheadDB.saveButtons[spec][size] = list` (creating tables) and calls `S.Refresh()`; `CastAheadSaves.ResetSpec()` clears `CastAheadDB.saveButtons[spec]` and refreshes.
- UI per size (Small, Big, Heal): rows of current `S.List(size)` entries (icon + name; item rows show the item name if in bags, else "Item with <use spell name>") each with a remove button; an EditBox + "Add" button using `ParseEntry`, showing the reason text on failure; "Reset to default" for the spec. Hide editors and show the existing note for a spec with no shipped table. Every write goes through `SetList`/`ResetSpec`. Keep the `saveCalls`, `bossAdapter`, `healCalls` switches and status line.

- [ ] **Step 1: Failing tests** for `ParseEntry` (known spell id, unknown number, item id with use spell, item link string, known spell name, garbage) and `SetList`/`ResetSpec` writing the right shape and a refresh happening.
- [ ] **Step 2: Implement parser and setters; then rebuild `BuildDefensives`** with the existing `BuildGroup`/`BuildSwitch`/`refreshers` patterns; group height grows to fit three lists (up to 4 rows each, then a "+N more" line).
- [ ] **Step 3: Both suites OK** (Options.lua is parse-checked by test_core loading UI.lua; verify the file loads).
- [ ] **Step 4: Commit** `feat: edit small, big and heal button lists in settings` and push.

---

### Task 6: Saves view in the /ca window

**Files:**
- Modify: `UI.lua` (new tab/view "Saves" next to the casts page; dungeon selector reused; rows rendered from `ViewRows`)
- Modify: `Saves.lua` (pure `S.ViewRows(instanceID)`)
- Test: `test_core.lua` (ViewRows)

**Interfaces:**
- Consumes: `CastAheadDefensives.spells[id]` display fields (Task 4), `CastAheadData[instanceID]` rows, `CastAheadMatch.SaveRow`, `CastAheadMatch.SpecRole()`, `CastAheadPriority`, `S.Available`.
- Produces: `CastAheadSaves.ViewRows(instanceID) -> array of { id, name, mob, boss, size = "SMALL"|"BIG", trigger = { cast = bool, bar = bool, debuff = bool }, wins = categoryString|nil, lead, buttons = Available(size) }` for the player's current role, sorted boss rows first (by boss name), then trash; within a group BIG before SMALL, then by name. `cast` is true when any `CastAheadData[instanceID]` row's spell resolves through `SaveRow` to this id; `wins` is the curated category of such a cast when it is one of KICK, CC, DODGE, FRONTAL, SWITCH or a dispel school.
- UI: a "Saves" tab button beside the existing ones; the page shows the dungeon selector (current instance by default) and a scrolling table: size chip, button icons, hit name, mob, Boss/Trash group headers, trigger words ("cast", "DBM bar", "debuff", "not heard" when none), lead seconds, and "says <WINS>" when `wins` is set. A line under the table: "Role: <role>. Change spec to see another role's list."

- [ ] **Step 1: Failing tests** for `ViewRows` on a fixture: one boss row with `bar`, one trash row reached by a Data cast, one aura-only row, one row with no trigger, one Data cast with prio DODGE; check sizes for the current role, the trigger flags, `wins = "DODGE"`, ordering.
- [ ] **Step 2: Implement `ViewRows`, then the UI page** following the casts page's frame/row pooling pattern in UI.lua (read `BuildWindow`, `CreateRow`, `Refresh`, `ShowTab` first).
- [ ] **Step 3: Both suites OK.**
- [ ] **Step 4: Commit** `feat: Saves view lists every hit that calls a save` and push.

---

### Task 7: Docs and PR

- [ ] README "Defensive calls (alpha)" section: several buttons per size, items found in bags, heal up after a big hit, Saves view, the three lists in settings (humanizer style, no em/en dashes).
- [ ] Spec status line: implemented.
- [ ] PR #54 comment (humanized) with the new in-game checks: Healthstone shows next to Dark Pact and disappears after use until it is off cooldown; heal up after a big trash cast and after a big boss bar; Saves view lists the current dungeon; adding a potion by link works.
- [ ] Full test run; commit `docs: save lists and heal calls in the README`; push.
