# Window redesign - design

Date: 2026-10-09. Status: implemented on feat/window-redesign, awaiting the in-game check.

## Goal

The `/ca` window looks dated, has seven tabs in one strip that are hard to tell apart, and refuses to shrink below a hard-coded size (the full 16-column cast table, about 1900 px wide, and four fixed settings columns, 404 px tall). We rebuild the window shell so that it looks like the game's modern settings, groups its pages in a side menu, can be made small, and never changes size by itself.

## Requirements

1. Layout B: a side menu with two groups, "Dungeon" (Guide, Saves, Casts) and "Settings" (General, Sounds, Defensives, Development). Development is listed only in Development mode.
2. The Dungeon pages show the 8 dungeons as buttons, 4 per row, above the page. No dropdown. Settings pages have no dungeon row.
3. Look: modern Blizzard style - slate background and frames drawn with colours, gold group and menu headers, a gold bar on the selected menu entry, flat buttons with a thin border (the main action, Test drive, in gold). No red panel buttons. Checkboxes, sliders and dropdowns use the game's own templates: `MinimalCheckboxTemplate`, `MinimalSliderWithSteppersTemplate`, `WowStyle1DropdownTemplate` (all present in wow-ui-source: SharedXML CheckButtonTemplates.xml:74, MinimalSlider.xml:34, Blizzard_Menu MenuTemplates.xml:3).
4. The window never resizes itself. Only the player resizes it, by the corner grip. Switching pages, switching dungeons, lists growing, Development mode turning on or off, and changing the scale leave the window's size untouched. Content that does not fit scrolls inside its page.
5. Minimum size: 600 x 420 (the side menu plus one settings column). No other hard-coded minimum.
6. The cast table shows 8 columns outside Development mode (on, sound, icon, Do, Spell, Mob, Cast, Cooldown). Lvl, Open, After, Seen, Tgt, %HP, Kick, Stop and Sound override appear only in Development mode. The table scrolls sideways when it is wider than the page.
7. Settings groups are placed by a flow layout instead of fixed coordinates: as many columns as fit the page width, each group goes into the currently shortest column. The layout re-runs when the page width changes or a group's height changes (the defensive lists grow).

## Structure

- `Window.lua` (new): the shell. Frame, title bar (title, Scale dropdown, Play list, Test drive, close), side menu, dungeon button grid, page host with vertical scrolling, footer (role line, "Made in Ukraine"). One theme table holds the colours. Pages register with `CastAheadWindow.Register(name, group, build, refresh)`; the shell builds a page on first show and calls `refresh` on every show and on dungeon change. `CastAheadWindow.Show(name)`, `CastAheadWindow.Dungeon()`.
- `CastsPage.lua` (new): the cast table, moved out of `UI.lua`, with the Development-only column flag.
- `SavesPage.lua` (new): the Saves and Guide pages, moved out of `UI.lua`.
- `UI.lua`: keeps slash commands, the test drive and the settings-category signpost; everything window-related moves out.
- `Options.lua`: panels keep their builders; `BuildGroup` stops using fixed `COL_X` columns and registers the group with the flow layout. `CastAheadOptions.MIN_WIDTH` / `MIN_HEIGHT` are removed.
- Flow layout: a pure function `Flow(width, gap, colWidth, heights) -> positions` in `Options.lua`, so it can be unit-tested.

## Unchanged

Calls, sounds, nameplates, the centre block, data files, the key-journal report window (`ReportWindow.lua`), slash commands, the Addon Compartment entry and the game-settings signpost. Saved settings carry over; a saved window size below the new minimum grows to it, a larger one is kept. `/ca` opens the last page shown (saved), and commands that open a tab open the matching page.

## Testing

- test_core: the flow layout (1-4 columns, a group growing, shortest-column placement), the cast table's visible columns with and without Development mode, and that showing pages, switching dungeons and toggling Development mode never call the window's `SetSize` (requirement 4).
- All existing suites keep passing.
- In game (PR checklist): narrow and wide window, every page, scale changes, test drive, the defensive lists growing, no size jumps.

## Risks

- A Blizzard template may not behave as expected outside its home panel; fallback is a small flat widget of our own.
- Resizing and reflow can only be checked in game.

## Out of scope

The mark panel and report window, any change to what is called out, new pages.
