# CastAhead

Predicts trash casts in Mythic+ and tells you what to do about them.

CastAhead watches enemy nameplates, works out which spell a mob is casting and when its next one is due, then puts a countdown icon beside the plate, says the response out loud, and shows the call in the middle of the screen. It covers trash only: bosses have boss mods, and this is what they leave uncovered.

## What it actually does

- **Names the cast before the game does.** In 12.1 an addon may not read what a hostile unit is casting, so CastAhead measures the cast bar's length and matches it against a database of every trash cast in the season's dungeons, narrowing further by the interval between casts and by which spells the creature owns.
- **Says the answer, not the spell name.** "Interrupt", "dispel poison", "tank buster", "dodge" - the response you have to pick, spoken by recorded clips or the game's own combat voice.
- **Counts down to the next one.** Cooldowns are stored as rotations, not averages: a mob that cycles 4.8 / 4.8 / 8.7 seconds is predicted on the right slot instead of being averaged into a number that is wrong every time.
- **Filters to what you can act on.** Only hand-picked important casts by default, and only the ones your character can answer - no dispel calls for a spec that cannot dispel, no tank busters for damage dealers.
- **Feeds Blizzard's encounter timeline** with predictions confident enough to be shown as exact.

## Commands

| Command | What it does |
| --- | --- |
| `/castahead` or `/ca` | Opens the database browser |
| `/ca options` | Settings: outputs, filters, sounds, per-content-type |
| `/ca test` | Test drive - draws and speaks sample calls on nearby enemies |
| `/ca move` | Drag the centre-screen call where you want it |
| `/ca debug` | What the addon sees right now: dungeon, plates, identification, voice chain |
| `/ca hide` | Clear every icon the addon drew (proves what belongs to it) |

`/forecast` and `/fcast` still work: the addon was called Forecast before 2026-09-01.

## Settings that are worth knowing about

Everything lives in the addon window, next to the cast table. **General** holds the eight switches for what gets announced, plus icon placement and the centre call's position; **Sounds** lets you pick any sound your other addons registered, per category.

The early warning ("tank buster soon") is a slider in seconds, off by default: on top of the real call it can read as two separate casts.

## Where the data comes from

The timings ship in `Data.lua`, generated from combat logs of real Mythic+ runs; `Priority.lua` marks which casts a human decided are worth reacting to; `Traits.lua` holds what the game still reveals about a creature on sight (level, classification, packmates), which names most mobs before they cast anything. The tools that rebuild them live in `tools/` and are not needed to play.

## Status

Alpha. It runs, it is tested headlessly on every push, and the season's data is current - but it has been used by one person in one region. Expect rough edges, and please report a cast that gets named wrong.
