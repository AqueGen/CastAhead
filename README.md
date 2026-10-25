# Cast Ahead

Predicts trash casts in Mythic+ and tells you what to do about them. On top of that it can call defensives (trash, dangerous debuffs, boss abilities) and burst windows on bosses.

## What it does

- **Names the cast before the game does.** In 12.1 an addon may not read what a hostile unit is casting, so Cast Ahead measures the cast bar's length and matches it against a database of every trash cast in the season's dungeons, narrowed by the interval between casts and by which spells the creature owns.
- **Says the answer, not the spell name.** "Interrupt", "dispel poison", "tank buster", "dodge", "adds incoming" - spoken by recorded clips or the game's own combat voice, shown as a countdown icon beside the nameplate and as a call in the middle of the screen.
- **Counts down to the next one.** Cooldowns are stored as rotations, not averages: a mob that cycles 4.8 / 4.8 / 8.7 seconds is predicted on the right slot.
- **Filters to what you can act on.** By default only hand-picked important casts, and only the ones your role can answer.
- **Feeds Blizzard's encounter timeline** with predictions confident enough to be shown as exact.

## Commands

| Command | What it does |
| --- | --- |
| `/castahead` or `/ca` | Opens the window |
| `/ca options` | Opens the settings |
| `/ca setup` | On-screen setup: place and size the icons and the centre call on samples |
| `/ca test` | Test drive: sample calls on nearby enemies, through the outputs switched on in General |
| `/ca move` | Drag the centre-screen call where you want it |
| `/ca debug` | What the addon sees right now: dungeon, plates, identification, voice chain |
| `/ca hide` | Clears every icon the addon drew |
| `/ca report` | The text of your marked wrong calls (Development mode) |
| `/ca mark <note>` | Marks a wrong call from chat (Development mode) |

## The window

A menu on the left: **Settings** (General, Sounds, Defensives while defensive calls are on), **Dungeon** (Guide, Saves, Casts, with the dungeon picked on top), **Raid** (Guide and Saves per difficulty, shown while the Raid switch is on) and **Feedback** (a Report page that prepares the text of a bug report or idea for a [GitHub issue](https://github.com/AqueGen/CastAhead/issues/new?template=report.yml) or a CurseForge comment).

- **General**: what gets called and the outputs (nameplate icons, centre call, timeline, sound, voice). Sizes and positions live in Set up on screen. The early warning ("tank buster soon") is off by default: on top of the real call it can read as two casts.
- **Sounds**: each category keeps the voice or plays any sound your other addons registered, and the game sound channel (Master, Dialog or SFX) sets the volume slider that controls the calls.
- **Casts**: every tracked cast with its call. Untick a cast to ignore it entirely; the Sound override column swaps the voice for a sound on one cast. Development mode adds the evidence columns.
- **Guide** and **Saves**: per boss, the defensive calls for your role and the burst windows, as text and as a table.

**Set up on screen**, the first button in General (or `/ca setup`), hides the window and shows sample icons, a sample centre call and sample timeline entries. With no enemy nameplate in view the icons sit on a sample plate; with enemies around you edit the row on your target's plate, or on the plate nearest the screen centre. Drag the icons or the centre call where you want them, use the mouse wheel to resize and the arrow keys for single pixels; the camera still turns with the left button anywhere else. A small panel holds every size and position setting as exact numbers (hold - or + to repeat), and the switches for the nameplate icons, the centre call and the Blizzard timeline, the same ones as in General. The timeline itself moves only in the game's Edit Mode (Esc > Edit Mode). Reset puts the numbers back, and Done or Esc closes it. Not available in combat.

## Defensive calls (alpha)

Off by default: "Defensive calls in dungeons" in General - Features. Cast Ahead says "defensive" and shows up to three icons of the buttons you can press right now. The calls come from trash casts, from dangerous debuffs landing on you (sound only), and from boss abilities in DBM or BigWigs timers.

A hit gets a call when the whole episode (the hit plus its damage over time, pulses and stacks) would take you below zero at +20 without a defensive, and top players at +20 press one for it. Calls are judged at +20 whatever key you run. Tanks get calls for tank busters only. A cast aimed at one player says "targeted" instead, because the game does not tell addons whom it is aimed at.

Each spec ships one ordered list of personal defensives; the top ready button is the one shown. The Defensives page edits the list (add a spell or item by id, name or link), sets the defensive early warning (0 to 10 s, off by default) and switches the DBM / BigWigs boss calls. Boss coverage is partial: a boss ability gets a call only while a boss mod runs a timer for it.

## Raid debuff calls (alpha)

In Heroic and Mythic, with "Defensive calls in raids" on under "Raid (experimental)", Cast Ahead says "defensive" when a boss debuff that kills its carrier without a defensive lands on you. A debuff is on the list when, in top-player fights, the worst 8 seconds while it is up take at least the carrier's whole health in half the cases or more, a personal defensive is pressed in at least a quarter of them, fewer than half of the carriers die anyway, and the deadly part comes within 12 seconds of the debuff landing. Heroic and Mythic are judged separately; a debuff too rare on Mythic to judge borrows its Heroic verdict. Tank debuffs call tanks, the rest call damage dealers and healers, and a healer who can remove it hears the dispel. The game lets an addon hear these debuffs only as they land, so a later call is the same line after up to 3 seconds of silence. The Raid Guide lists them per boss, with the checked debuffs that get no call greyed out and the reason.

## Burst windows (alpha)

With "Burst windows" on under "Raid (experimental)", Cast Ahead says "burst soon" five seconds before a boss phase worth bursting into and "burst now" when it starts. The phases come from top-player runs and are kept only where at least three specs agree; a boss without one gets no call: burst on the pull, then on cooldown. Healers get their own moments for group-healing cooldowns. A phase the boss starts at a health mark is called on the game's own boss warning instead. A defensive call within two seconds of a burst call goes first. The Guide pages show every boss's phases, key bosses in the Dungeon Guide and raid bosses in the Raid Guide.

## Reporting a wrong call

Turn on Development mode (General - Advanced). Its Development tab records the combat log, a journal of each key and what the game reveals about each enemy cast; the "Mark panel" switch there adds a panel to mark a wrong call on a mob you pick, with an optional note. The same marks can be bound under Key Bindings > Cast Ahead. After the key, `/ca report` gives the text for a [wrong call issue](https://github.com/AqueGen/CastAhead/issues/new?template=wrong-call.yml) or a CurseForge comment. The journal holds spell and creature ids and timings, no names of people.

## Where the data comes from

The timings ship in `Data.lua`, generated from combat logs of real Mythic+ runs; `Priority.lua` marks which casts a human decided are worth reacting to; `Traits.lua` holds what the game still reveals about a creature on sight (level, classification, packmates). The tools that rebuild them live in `tools/` and are not needed to play.

## Status

Alpha, tested headlessly on every push and used by one person in one region. Please report a cast that gets named wrong.
