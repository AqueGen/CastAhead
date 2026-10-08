# Window Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `/ca` window's tab strip and fixed-size layout with a side-menu shell in the modern Blizzard style that can be made small and never resizes itself.

**Architecture:** A new `Window.lua` owns the frame, title bar, side menu, dungeon button grid, page host and footer; pages register with it. The cast table moves to `CastsPage.lua`, the Saves and Guide pages to `SavesPage.lua`; `UI.lua` keeps slash commands, the test drive and the settings signpost. `Options.lua` panels stop using fixed columns and place their groups with a tested flow-layout function.

**Tech Stack:** WoW 12.x addon Lua 5.1, Blizzard frame API, tests in plain Lua (`test.lua`, `test_core.lua`) run under Lua 5.1 in WSL.

**Spec:** `docs/superpowers/specs/2026-10-09-window-redesign-design.md`

## Global Constraints

- Lua 5.1; no new libraries or dependencies.
- English UI text; files in English.
- No new comments except facts nobody can re-check on demand.
- The window never resizes itself (spec requirement 4): only the corner grip changes its size; page switches, dungeon switches, list growth, Development mode toggles and scale changes do not call the window's `SetSize`.
- Minimum window size 600 x 420 (spec requirement 5).
- Cast table outside Development mode shows exactly: check, hear, icon, advice (Do), spell, mob, cast, cd (spec requirement 6).
- Templates: `MinimalCheckboxTemplate`, `MinimalSliderWithSteppersTemplate`, `WowStyle1DropdownTemplate`; fallback to a flat widget of our own if one misbehaves.
- Every existing public name stays callable: `CastAheadUI.ShowTab`, `CastAheadUI.RefreshSaves`, `CastAheadUI.RefreshTest`, `CastAheadUI.RefreshTabs`, `CastAheadUI.IsDisabled`, `CastAheadUI.SetOption`, `CastAheadUI.OptionEnabled`, `CastAheadUI.SetAnchor`, `CastAheadUI.SetGrowth`, `CastAhead_Toggle`, `CastAheadOptions.ShowPanel`, `CastAheadOptions.HideAll`, `CastAheadOptions.RefreshDefensives`.
- Test command (both suites must print OK): `MSYS_NO_PATHCONV=1 wsl bash -lc 'cd "/mnt/g/Games/World of Warcraft/_retail_/Interface/AddOns/CastAhead" && ~/luaenv/bin/lua test.lua | tail -1 && ~/luaenv/bin/lua test_core.lua | tail -1'`
- Syntax check for files the suites do not load: `~/luaenv/bin/lua -e 'assert(loadfile("Options.lua")) assert(loadfile("Window.lua"))'` in the same folder.
- Work on branch `feat/window-redesign`; commit per task; push after each task.

## Review Focus

1. A saved window size from the old layout (about 1900 x 560) or below the new minimum: the window opens at the saved size clamped to at least 600 x 420, never jumps after that (Task 4 test).
2. Development mode switched off while the Development page is open: the window shows General, the menu entry disappears, the size stays (Task 4 test).
3. Slash commands that open a page (`/ca`, `/ca sounds`, `/ca anchor ...`) open the matching page in the new shell (Task 5 test).
4. A defensive list growing on the Defensives page: groups below it move down, nothing overlaps, the window keeps its size (Task 2 test on the flow function, Task 4 size test).
5. A window narrower than two settings columns: settings groups stack in one column and scroll; the cast table scrolls sideways (Task 1 and Task 3 tests).

---

### Task 1: Flow layout function

**Files:**
- Modify: `Options.lua` (add `CastAheadOptions.Flow` near the top, after the `COL_W` constants)
- Test: `test.lua`

**Interfaces:**
- Produces: `CastAheadOptions.Flow(width, colWidth, gap, heights) -> positions, totalHeight` where `heights` is an array of group heights in display order, `positions[i] = { x = number, y = number }` with `y` as a positive offset from the top, and `totalHeight` the bottom of the tallest column. Columns = `max(1, floor((width + gap) / (colWidth + gap)))`. Each group goes into the column whose current bottom is lowest (leftmost on ties); `y` of a group = that column's bottom (0 for the first), the column's bottom then grows by `height + gap`.

- [ ] **Step 1: Write the failing test** (append to `test.lua` before its final OK print; `test.lua` does not load `Options.lua`, so load it with stubs)

```lua
do
    local savedCreate = CreateFrame
    CastAheadOptions = nil
    assert(loadfile("Options.lua"))
    CastAheadConfig = CastAheadConfig or { Number = function(_, d) return d end }
    local ok = pcall(dofile, "Options.lua")
    check(ok and CastAheadOptions and CastAheadOptions.Flow, "Options.lua loads and exposes Flow")
    local Flow = CastAheadOptions.Flow
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
    CreateFrame = savedCreate
end
```

- [ ] **Step 2: Run the suites, confirm the new checks fail** (`Flow` is nil). If `dofile("Options.lua")` errors on a missing global at load, stub that global in the test block, not in `Options.lua`.

- [ ] **Step 3: Implement**

```lua
function CastAheadOptions.Flow(width, colWidth, gap, heights)
    local columns = math.max(1, math.floor((width + gap) / (colWidth + gap)))
    local bottoms = {}
    for c = 1, columns do bottoms[c] = 0 end
    local positions, total = {}, 0
    for i, h in ipairs(heights) do
        local c = 1
        for k = 2, columns do
            if bottoms[k] < bottoms[c] then c = k end
        end
        positions[i] = { x = (c - 1) * (colWidth + gap), y = bottoms[c] }
        bottoms[c] = bottoms[c] + h + gap
        total = math.max(total, bottoms[c] - gap)
    end
    return positions, total
end
```

- [ ] **Step 4: Run both suites: OK.**
- [ ] **Step 5: Commit** `feat: flow layout for settings groups`

### Task 2: Settings panels placed by the flow layout

**Files:**
- Modify: `Options.lua` (`BuildGroup`, every `BuildGroup(...)` call, `Build`, `ShowPanel`, the Defensives `Fit` functions, remove `CastAheadOptions.MIN_WIDTH`/`MIN_HEIGHT`)

**Interfaces:**
- Consumes: `CastAheadOptions.Flow`.
- Produces: `panel.groups` (array of group frames in build order), `panel:Relayout()` positions them with `Flow(panel:GetWidth(), COL_W, COL_GAP, heights)` and sets `panel:SetHeight(total + 12)`; `CastAheadOptions.ShowPanel(host, name)` calls `Relayout` on the shown panel; a group frame calls its panel's `Relayout` after any `SetHeight` on it (the Defensives `Fit` functions).

- [ ] **Step 1:** Change `BuildGroup(panel, title, column, height, point)` to `BuildGroup(panel, title, height)`: create the box as now, append it to `panel.groups`, do not set a point. Replace every call (12 calls: General, Sounds, Defensives incl. `BuildSaveList`, Development) dropping the column and point arguments; groups keep their build order, which is their display order. In `BuildDevelopment` the groups anchored to each other (`{ "TOPLEFT", recording, "TOPRIGHT", COL_GAP, 0 }` and similar) become plain flow groups. The Development intro text goes inside the first group's area or above via the panel top padding: anchor it to `panel` TOPLEFT and start the flow 30 px lower for that panel (`panel.flowTop = 30`).
- [ ] **Step 2:** Add to `Build`: for each panel, `panel.groups = {}` before its builder runs and

```lua
function panel:Relayout()
    local heights = {}
    for i, g in ipairs(self.groups) do heights[i] = g:GetHeight() end
    local pos, total = CastAheadOptions.Flow(self:GetWidth(), COL_W, COL_GAP, heights)
    local top = self.flowTop or 6
    for i, g in ipairs(self.groups) do
        g:ClearAllPoints()
        g:SetPoint("TOPLEFT", self, "TOPLEFT", COL_X + pos[i].x, -(top + pos[i].y))
    end
    self:SetHeight(top + total + 12)
end
```

  Panels stop using `SetAllPoints(host)`; they anchor `TOPLEFT`/`TOPRIGHT` to the host and get their height from `Relayout`. `ShowPanel` calls `panels[name]:Relayout()` after showing it. The host frame's `OnSizeChanged` (Task 4 page host) calls `Relayout` on the shown panel.
- [ ] **Step 3:** In `BuildDefensives`, each `Fit`/`Paint` that calls `group:SetHeight(...)` calls `panel:Relayout()` afterwards. Remove `SWITCHES_H`-style height juggling only if `Relayout` makes it unnecessary; keep heights as content needs.
- [ ] **Step 4:** Delete `CastAheadOptions.MIN_WIDTH` and `CastAheadOptions.MIN_HEIGHT` and their uses in `UI.lua` (`WindowWidth`, `WindowHeight`); Task 4 replaces those functions.
- [ ] **Step 5:** Syntax check `Options.lua`; both suites OK (the Flow tests still pass).
- [ ] **Step 6: Commit** `feat: settings groups flow by width`

### Task 3: Cast table columns by mode, sideways scrolling

**Files:**
- Modify: `UI.lua` (`COLUMNS`, `ColumnOffset`, `TableWidth`, header and row builders, the cast table's clip/scroll frames)
- Test: `test_core.lua`

**Interfaces:**
- Produces: `dev = true` on the column specs `level`, `first`, `offset`, `n`, `hits`, `dmg`, `kick`, `cc`, `sound`, `prio`; `CastAheadUI.VisibleColumns(dev) -> array of column keys` in order.

- [ ] **Step 1: Failing test** in `test_core.lua` after UI.lua is loaded:

```lua
local keys = table.concat(CastAheadUI.VisibleColumns(false), ",")
check(keys == "check,hear,icon,advice,spell,mob,cast,cd", "outside Development mode the cast table shows 8 columns, got " .. keys)
check(#CastAheadUI.VisibleColumns(true) == 18, "Development mode shows every column")
```

- [ ] **Step 2:** Run; expect FAIL (`VisibleColumns` nil).
- [ ] **Step 3:** Add the `dev = true` flags; `VisibleColumns(dev)` filters `COLUMNS`; header strip, rows, `ColumnOffset` and `TableWidth` iterate the visible list (rebuild cells when Development mode changes - `CastAheadUI.RefreshTabs` is already called on that switch; make it also rebuild the table's header and rows). Wrap the header strip and rows in a horizontal `ScrollFrame` (child width = `TableWidth()`), with the existing vertical row scroll inside it, so a narrow page scrolls sideways instead of clipping.
- [ ] **Step 4:** Both suites OK.
- [ ] **Step 5: Commit** `feat: cast table hides development columns outside Development mode`

### Task 4: Window shell

**Files:**
- Create: `Window.lua`
- Modify: `CastAhead.toc` (add `Window.lua` before `UI.lua`)
- Test: `test_core.lua`

**Interfaces:**
- Produces:
  - `CastAheadWindow.THEME` = `{ bg = {0.063,0.075,0.09,0.97}, panel = {0.082,0.098,0.125,1}, border = {0.235,0.251,0.282,1}, line = {0.125,0.145,0.176,1}, gold = {1,0.82,0}, text = {0.9,0.9,0.9}, muted = {0.545,0.576,0.627}, selected = {0.165,0.192,0.251,1} }`
  - `CastAheadWindow.Register(name, group, build, refresh)` - `group` is `"Dungeon"` or `"Settings"`; `build(host)` runs once on first show; `refresh()` on every show and on dungeon change.
  - `CastAheadWindow.Show(name)`, `CastAheadWindow.Toggle()`, `CastAheadWindow.Current() -> name`, `CastAheadWindow.Dungeon() -> instanceID`, `CastAheadWindow.Frame() -> frame or nil`.
  - `CastAheadWindow.SetMenuShown(name, shown)` - hides or shows a menu entry; hiding the current page shows the first registered page of the same group (for `Development` that is `General`).
  - `CastAheadWindow.Button(parent, text, width, primary) -> button` (flat button: `BackdropTemplate` frame with `THEME.panel` fill and `THEME.border` edge, gold edge and text when `primary`).
  - `CastAheadWindow.MIN_W, MIN_H = 600, 420`.

- [ ] **Step 1: Failing tests** in `test_core.lua` (after `dofile("UI.lua")`; add `dofile("Window.lua")` before it in the test's load list):

```lua
do
    local sized = 0
    local savedCreate = CreateFrame
    CreateFrame = function(kind, name, ...)
        local f = savedCreate(kind, name, ...)
        if name == "CastAheadWindow" then
            f.SetSize = function(self, w, h) sized = sized + 1 self.w, self.h = w, h end
            f.GetWidth = function(self) return self.w or 0 end
            f.GetHeight = function(self) return self.h or 0 end
        end
        return f
    end
    CastAheadDB = { window = { width = 300, height = 200 } }
    CastAheadWindow.Register("TestA", "Dungeon", function() end, function() end)
    CastAheadWindow.Register("TestB", "Settings", function() end, function() end)
    CastAheadWindow.Show("TestA")
    local f = CastAheadWindow.Frame()
    check(f and f.w == 600 and f.h == 420, "a saved size below the minimum opens at the minimum")
    local before = sized
    CastAheadWindow.Show("TestB")
    CastAheadWindow.Show("TestA")
    CastAheadDB.devMode = true
    if CastAheadUI.RefreshTabs then CastAheadUI.RefreshTabs() end
    CastAheadDB.devMode = nil
    if CastAheadUI.RefreshTabs then CastAheadUI.RefreshTabs() end
    check(sized == before, "switching pages and Development mode never resizes the window")
    CreateFrame = savedCreate
    CastAheadDB = nil
end
```

  Also: Development switched off while `Development` is current shows `General` (`CastAheadWindow.Current() == "General"`), and a saved size of 1900 x 560 is kept as is.
- [ ] **Step 2:** Run; expect FAIL (no `CastAheadWindow`).
- [ ] **Step 3: Implement `Window.lua`.** Frame `CreateFrame("Frame", "CastAheadWindow", UIParent, "BackdropTemplate")` with the theme backdrop, movable, `DIALOG` strata, resizable with `SetResizeBounds(MIN_W, MIN_H)`, in `UISpecialFrames`. Size set once at build: saved `CastAheadDB.window.width/height` clamped up to the minimum, else 900 x 560. Title bar 26 px: title "Cast Ahead" in gold, on the right Scale dropdown (move `ApplyScale`, `SCALE_*` and the dropdown from `UI.lua`), Play list and Test drive (created by `UI.lua` through a hook `CastAheadWindow.titleButtons` callback so the test-drive logic stays in `UI.lua`), close button. Left menu 120 px wide: group headers in gold, entries as flat buttons, selected entry with `THEME.selected` fill and a 2 px gold bar. Dungeon grid shown only for `Dungeon` pages: 8 flat buttons from `CastAheadData` sorted by name, 4 per row, each `(pageWidth - 3*4) / 4` wide, re-laid in the page host's `OnSizeChanged`; default selection = current instance, else first; clicking sets the dungeon and calls the current page's `refresh`. Page host: a `ScrollFrame` with `UIPanelScrollFrameTemplate` below the grid (or below the title for Settings pages); each page's host frame is the scroll child, width follows the scroll frame. Footer 20 px: a left text set by pages (`CastAheadWindow.SetFooter(text)`) and "Made in Ukraine" centred. Grip bottom-right as in the current `UI.lua` (`OnMouseDown` pins TOPLEFT then `StartSizing`; `OnMouseUp` saves size). `Show(name)` remembers `CastAheadDB.window.page`. Nothing in `Show`, the dungeon grid or the menu calls `SetSize`.
- [ ] **Step 4:** Both suites OK.
- [ ] **Step 5: Commit** `feat: window shell with side menu and dungeon buttons`

### Task 5: Pages move into the shell

**Files:**
- Create: `CastsPage.lua`, `SavesPage.lua`
- Modify: `UI.lua`, `Options.lua`, `CastAhead.toc` (order: `Window.lua`, `CastsPage.lua`, `SavesPage.lua`, `UI.lua`, ... `Options.lua` as now)
- Test: `test_core.lua`

**Interfaces:**
- Consumes: `CastAheadWindow.Register/Show/Dungeon/SetFooter/Button/SetMenuShown`.
- Produces: pages `Guide`, `Saves`, `Casts` (group `Dungeon`) and `General`, `Sounds`, `Defensives`, `Development` (group `Settings`); `CastAheadUI.ShowTab(name)` = `CastAheadWindow.Show(name)`; `CastAhead_Toggle()` = `CastAheadWindow.Toggle()`.

- [ ] **Step 1: Failing test:** with stub frames, `SlashCmdList.CASTAHEAD("sounds")` (or whatever the current sounds command is - read `UI.lua` near line 1053) leaves `CastAheadWindow.Current() == "Sounds"`; `CastAhead_Toggle()` on a closed window shows the last saved page (`CastAheadDB.window.page = "Guide"` -> `Current() == "Guide"`).
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Move the cast-table code (columns, `SortedRows`, header tips, rows, search, sorting, `Refresh`) from `UI.lua` into `CastsPage.lua` as `build(host)`/`refresh()`; it reads the dungeon from `CastAheadWindow.Dungeon()` and writes its summary line with `SetFooter`. Move `RefreshSaves`, `RefreshGuide`, `SAVE_COLUMNS` and the saves/guide builders into `SavesPage.lua`, registered as `Saves` and `Guide`. `CastAheadUI.RefreshSaves` calls both pages' refresh when visible. Register the four settings pages from `Options.lua` with `build = function(host) CastAheadOptions.ShowPanel(host, name) end`-style adapters so `Build(host)` still creates all panels once under the first host and each page shows its own panel. `CastAheadUI.RefreshTabs` calls `CastAheadWindow.SetMenuShown("Development", dev)` and falls back to `General`. Delete the old tab strip, `settingsHost`, `dungeonList`, `WindowWidth`/`WindowHeight` and `BuildWindow` from `UI.lua`.
- [ ] **Step 4:** Both suites OK; syntax check all new files.
- [ ] **Step 5: Commit** `refactor: pages register with the window shell`

### Task 6: Widgets in the new style

**Files:**
- Modify: `Options.lua` (`BuildSwitch`, `BuildSlider`, `BuildReset`, `DevButton`, the Add/Reset buttons on the Defensives tab, `BuildGroup` backdrop), `CastsPage.lua`/`SavesPage.lua` buttons, `UI.lua` Play list/Test drive.

**Interfaces:**
- Consumes: `CastAheadWindow.THEME`, `CastAheadWindow.Button`.

- [ ] **Step 1:** `BuildGroup` backdrop: `THEME.panel` fill, 1 px `THEME.border` edge (`edgeFile = "Interface\\Buttons\\WHITE8X8"`, `edgeSize = 1`), title in gold.
- [ ] **Step 2:** `BuildSwitch` uses `MinimalCheckboxTemplate` (size from the template; keep the label, hit rect and tooltip logic).
- [ ] **Step 3:** `BuildSlider` uses `MinimalSliderWithSteppersTemplate`: `slider:Init(value, min, max, steps, { [MinimalSliderWithSteppersMixin.Label.Right] = function(v) return ... end })` and `slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, handler, owner)` - read `Blizzard_SharedXML/Shared/Slider/MinimalSlider.lua` in `G:/Games/wow-ui-source-live` for the exact `Init` signature before writing; if it does not fit the caption-above layout, keep `UISliderTemplateWithLabels` and only recolour it, and note that in the commit message.
- [ ] **Step 4:** Every `UIPanelButtonTemplate` in the window becomes `CastAheadWindow.Button(...)`; Test drive is the primary (gold) button.
- [ ] **Step 5:** Both suites OK; syntax check.
- [ ] **Step 6: Commit** `feat: settings widgets in the modern style`

### Task 7: Docs and PR

**Files:**
- Modify: `README.md` (window section: side menu, dungeon buttons, smallest size, Development-only columns), spec status line.

- [ ] **Step 1:** Update README and the spec's status to "implemented".
- [ ] **Step 2:** Both suites OK.
- [ ] **Step 3: Commit** `docs: window redesign in the README`; push; open a draft PR to `main` with an in-game checklist: narrow (600 x 420) and wide window on every page; resizing reflows settings groups; switching pages, dungeons and Development mode never changes the size; scale 75-150 %; test drive and play list; defensive lists growing; `/ca`, `/ca sounds`, the minimap button and the game-settings signpost open the window.
