# Cast Ahead

Predicts trash casts in Mythic+ and tells you what to do about them.

Cast Ahead watches enemy nameplates, works out which spell a mob is casting and when its next one is due, then puts a countdown icon beside the plate, says the response out loud, and shows the call in the middle of the screen. It covers trash only: bosses have boss mods, and this is what they leave uncovered.

## What it actually does

- **Names the cast before the game does.** In 12.1 an addon may not read what a hostile unit is casting, so Cast Ahead measures the cast bar's length and matches it against a database of every trash cast in the season's dungeons, narrowing further by the interval between casts and by which spells the creature owns.
- **Says the answer, not the spell name.** "Interrupt", "dispel poison", "tank buster", "dodge", "adds incoming" - the response you have to pick, spoken by recorded clips or the game's own combat voice.
- **Counts down to the next one.** Cooldowns are stored as rotations, not averages: a mob that cycles 4.8 / 4.8 / 8.7 seconds is predicted on the right slot instead of being averaged into a number that is wrong every time.
- **Filters to what you can act on.** Only hand-picked important casts by default, and only the ones your character can answer - no dispel calls for a spec that cannot dispel, no tank busters for damage dealers.
- **Feeds Blizzard's encounter timeline** with predictions confident enough to be shown as exact.

## Commands

| Command | What it does |
| --- | --- |
| `/castahead` or `/ca` | Opens the database browser |
| `/ca options` | Settings: outputs, filters, sounds, per-content-type |
| `/ca test` | Test drive - plays sample calls on nearby enemies through the outputs switched on in General |
| `/ca move` | Drag the centre-screen call where you want it |
| `/ca debug` | What the addon sees right now: dungeon, plates, identification, voice chain |
| `/ca hide` | Clear every icon the addon drew (proves what belongs to it) |
| `/ca report` | The text of your marked wrong calls, ready to paste into an issue |
| `/ca mark <note>` | Mark a wrong call from chat, with an optional note |

`/forecast` and `/fcast` still work: the addon was called Forecast before 2026-09-01.

## Settings that are worth knowing about

Everything lives in the addon window. A menu on the left has the same pages for dungeons and raids. **Settings** comes first (General, Sounds, Defensives while defensive calls are on in dungeons or raids, plus Development in Development mode). **Dungeon** has Guide, Saves and Casts, with eight buttons on top that pick the dungeon. **Raid** has Guide and Saves, with Normal, Heroic and Mythic buttons on top; it appears while the Raid switch is on with at least one raid feature. Each Guide shows every boss of the picked place with a Defensive section (what is called for your role, when, and how much health it took; checked debuffs that get no call are greyed with the reason) and a Burst section (the boss's burst phase and its calls); a section shows only while its calls are on. Saves is the same calls as a table with your buttons. **Feedback** holds the Report page: pick what the report is about (a wrong trash or defensive call, burst timing, a bug, an idea), finish the prepared text, which already holds the addon and game version and your spec, copy it and paste it into a new [GitHub issue](https://github.com/AqueGen/CastAhead/issues/new?template=report.yml) or a CurseForge comment. The window can be made as small as 600 x 420 by the grip in its bottom right corner, stays on screen, and keeps the size you give it until Reset size in the title bar brings back the default; settings groups rearrange into as many columns as fit, and anything taller scrolls. **General** holds the switches for what gets announced (the Features group has the dungeon defensive calls, then the "Raid (experimental)" master switch with "Defensive calls in raids" and "Burst windows" under it, greyed out until it is on; turning it off stops both and keeps their settings for when it comes back on), plus icon placement and the centre call's position; **Sounds** lets each category keep the voice or play any sound your other addons registered instead, and picks the game sound channel (Master, Dialog or SFX) whose volume slider controls the calls. The Casts page shows the columns a player needs, including the per-spell Sound override, whose pick wins over its category's; the evidence columns (samples, timings, damage, kick and stop rates) appear in Development mode.

The early warning ("tank buster soon") is a slider in seconds, off by default: on top of the real call it can read as two separate casts.

Icon rows step sideways by the words under them, so labels never touch; **Fixed spacing** in the Icon size group steps by icon plus a gap instead, for rows that pack identically every time. **Layer** in the same group is the icons' frame strata, BACKGROUND by default: above every nameplate and under the rest of the UI, like a plate; go higher to put the icons over your bars, DIALOG or above if a nameplate addon lifts its plates into the UI.

## Defensive calls (alpha)

Cast Ahead can also tell you when to press a defensive. It says "defensive" (DEFENSIVE on screen, DEF in short form) and shows up to three icons of the buttons you can press right now. There is one call, not a ladder of sizes. The calls come from three places: trash casts, dangerous debuffs on you (sound only), and boss abilities read from DBM or BigWigs bars. A cast aimed at one player says "targeted" rather than a defensive: the game does not tell addons whom it is aimed at, so a defensive call there would often be for someone else. The centre block still draws the save line under it, visible only when the cast is on you: the game lets an addon draw by that answer without reading it.

The rule is the same for damage dealers and healers: Cast Ahead calls a hit when the whole episode (the hit plus its damage over time, pulses and stacks from several mobs) would take you below zero without a defensive at +20, and top players at +20 actually press a defensive for it. Calls are judged at +20 whatever key you run, so a lower key teaches you what kills at +20 and the habit is there before it costs a key. Tanks get a call only for tank busters: hits that land on the tank alone in those runs, or casts the priority list marks as a tank buster. A hit that also lands on the rest of the group keeps its normal call for a tank. There is no call at all when your spec's list has no button you know or own. A button that works on one kind of damage only is skipped for a hit of another kind, and the next ready button in the list is shown instead, or none if the list has no other: Anti-Magic Shell, Cloak of Shadows and Spell Reflection only for magic hits, Blessing of Protection, Evasion and Demon Spikes only for physical ones, Feint only for area damage. This part is still experimental: the hits, their timings and the shipped button lists may be wrong or missing, so please report anything off: the Report button on the Defensives page prepares the text.

Each spec has one list of buttons, in order, with the one top players press most at the top. If the first one is on cooldown (when the game lets addons read it), the next ready one takes its place. The old "heal up" call is gone, and Healthstones and potions are no longer in the shipped lists; you can still add one yourself by typing its item id or pasting its link. Items in your list are found in your bags by what they do, so any rank or version works, and they drop off the icons while they are on cooldown or used up.

Every spec ships its own list, picked from what top players press in +18 keys. Only personal defensives are listed: externals and raid cooldowns are left out, and so are buttons pressed on rotation (Ironfur, Ignore Pain, Shield Block, Purifying Brew).

- Death Knight: Anti-Magic Shell and Icebound Fortitude, with Vampiric Blood first for Blood.
- Demon Hunter, Havoc and Devourer: Blur. Vengeance: Demon Spikes, Metamorphosis, Fiery Brand.
- Druid: Barkskin, then Bear Form for Balance and Restoration, Survival Instincts for Feral and Guardian.
- Evoker: Obsidian Scales.
- Hunter: Survival of the Fittest, Aspect of the Turtle.
- Mage: the spec's barrier (Prismatic Barrier, Blazing Barrier, Ice Barrier), then Mirror Image for Arcane, and Ice Cold for every spec.
- Monk: Brewmaster Celestial Infusion and Fortifying Brew, Windwalker Touch of Karma and Fortifying Brew, Mistweaver Fortifying Brew.
- Paladin: Protection Sentinel, Ardent Defender, Guardian of Ancient Kings, Divine Shield. Holy Divine Protection, Divine Shield, Blessing of Protection. Retribution the same.
- Priest: Power Word: Shield (Discipline and Shadow), Fade, Desperate Prayer, plus Dispersion for Shadow.
- Rogue: Feint, Cloak of Shadows, Evasion.
- Shaman: Astral Shift.
- Warlock: Dark Pact, Unending Resolve.
- Warrior: Spell Reflection, then Die by the Sword for Arms, Enraged Regeneration for Fury, Shield Wall for Protection.

The "Defensive calls in dungeons" switch under Features on the General page (off by default) turns the calls on. The update that introduced the one defensive call switched defensive calls (dungeons and raids) off once for every profile and says so in chat on first login. The Defensives page under Settings (shown while dungeon or raid defensive calls are on) has a "Boss calls from DBM / BigWigs" switch, a "Defensive early warning" slider (0 to 10 seconds, off by default: a defensive is called when the cast starts, not before) and the one list for the spec picked in the class and spec bar on top, your current one until you pick another. Calls always use your current spec's list. If you used the old small and big lists, they are joined into the new one. The arrows on a row move it up or down: the top ready button is the one called first. Click a row, or its X, to remove it. "Add from list" offers your class's defensives; the Add box takes a spell or item id, a name, or a shift-clicked link. Reset to default asks first, then restores the shipped list. The status line shows which boss mod is connected. Boss calls need DBM or BigWigs installed and work in dungeons; raid bosses need "Defensive calls in raids" under the "Raid (experimental)" switch in Features on the General page (it does not need the dungeon switch), and the raid calls are the debuff calls described below; without a boss mod, trash and debuff calls still work.

The Saves page in the `/ca` window lists, for the current dungeon or the one you pick, every hit that gets a call: your buttons, the mob or boss, what triggers it (cast, boss timer, debuff), how early it comes and its damage. Damage is always shown at +20, the level calls are judged at: the median whole hit on your role, with its DoT, pulses and stacks. A note above the table says so. A hit where a kick, dodge or other mechanic wins over the defensive says so.

The Guide page next to it reads the same data as plain text, a cheat sheet for the picked dungeon and your current spec and list: each boss in turn, then the trash, one line per hit, for example, what a warlock damage dealer sees: "Living Bomb from Primalist Cinderweaver (heard by: debuff on you): defensive - Dark Pact, then Unending Resolve. Takes about 119% of your health at +20". The percentage is the damage of the whole episode as a share of a player's health at +20, and the same note opens the guide text. Hits also say when they come: the first cast after the pull and the gap to the next one. For trash the gaps are the cycle the mob repeats; for bosses they are the typical gaps in order as measured in top-player runs, so a boss that pauses between phases shows the pause. Boss times are approximate. Hover a hit or a button for its game tooltip. The class dropdown and spec buttons above the text show the guide for any spec of any class; it works with the defensive calls switched off.

Boss coverage is partial today. A boss threat gets a call only when DBM or BigWigs runs a timer for it, because bars that exist only in Blizzard's own timeline give addons no callback. Schedules counted from the pull are the planned next step.

## Raid debuff calls (alpha)

In Heroic and Mythic raids, with "Defensive calls in raids" on, Cast Ahead says "defensive" when a boss debuff that kills its carrier without a defensive lands on you, for example Venomous Surge on Sszorak. A debuff is on the list when the worst 8 seconds while it is up take at least the carrier's whole health in top-player fights (half of them or more), those players press a personal defensive in at least a quarter of the cases, fewer than half of the carriers die anyway, and the deadly part comes within 12 seconds of the debuff landing. Heroic and Mythic are judged separately, so a debuff that only kills on Mythic stays silent on Heroic. Tank debuffs call tanks, the others call damage dealers and healers; a healer who can remove a dispellable one hears the dispel instead. The game lets an addon hear these debuffs only at the moment they land, so a call that should come later is the same voice line after a few seconds of silence (up to 3). The Raid Guide lists them boss by boss for the picked difficulty, with the debuffs that were checked and get no call greyed out with the reason.

## Burst windows (alpha)

Some bosses have a phase worth saving your burst for, such as Ula'tek's Venomous Heart or the moments on Vashnik where top players hold their cooldowns. With "Burst windows" switched on under "Raid (experimental)" (Features group on the General page, both off by default), the Guide pages show each boss's burst phase and Cast Ahead says "burst soon" five seconds before such a phase and "burst now" when it starts, with a countdown in the centre block when "Show the centre call" is on. It does not say which buttons to press. The phases are measured from the boss pull in top-player runs and kept only where at least three specs agree. A boss without such a phase gets no call: press your burst on the pull and then on cooldown. This is experimental too: the phases may not match your group, so please report anything off on the Report page.

Damage dealers and tanks share these phases. Healers get their own: the moments top healers press their big group-healing cooldown. A phase the boss starts at a health mark, like Kystia Manaheart's Light Infusion, has no time to count from, so there Cast Ahead puts "burst now" on the game's own boss warning for that phase. It plays the moment the warning shows, for every role. That needs the game's boss warnings switched on, and for that fight it replaces a boss mod's own sound on the same warning. When a defensive call comes within two seconds of a burst call, you hear the defensive first and the burst call two seconds after it.

Key bosses show theirs in the Dungeon Guide, raid bosses in the Raid Guide.

## Reporting a wrong call

Turn on Development mode in the settings, then the key journal on the Development tab. While you are in a dungeon a small panel lists the mobs Cast Ahead tracked in the last two minutes. Pick the one it got wrong (or none, to mark the whole moment) and press Mark, or Mark + note to type what really happened; Enter saves the note. The same two actions can be bound under Key Bindings > Cast Ahead. After the key, `/ca report` gives the text to paste into a [wrong call issue](https://github.com/AqueGen/CastAhead/issues/new?template=wrong-call.yml) or a CurseForge comment. The journal holds spell and creature ids and timings only, no names of people.

## Where the data comes from

The timings ship in `Data.lua`, generated from combat logs of real Mythic+ runs; `Priority.lua` marks which casts a human decided are worth reacting to; `Traits.lua` holds what the game still reveals about a creature on sight (level, classification, packmates), which names most mobs before they cast anything. The tools that rebuild them live in `tools/` and are not needed to play.

## Status

Alpha. It runs, it is tested headlessly on every push, and the season's data is current - but it has been used by one person in one region. Expect rough edges, and please report a cast that gets named wrong.
