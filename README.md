# Cast Ahead

Predicts trash casts in Mythic+ and tells you what to do about them.

Cast Ahead watches enemy nameplates, works out which spell a mob is casting and when its next one is due, then puts a countdown icon beside the plate, says the response out loud, and shows the call in the middle of the screen. It covers trash only: bosses have boss mods, and this is what they leave uncovered.

## What it actually does

- **Names the cast before the game does.** In 12.1 an addon may not read what a hostile unit is casting, so Cast Ahead measures the cast bar's length and matches it against a database of every trash cast in the season's dungeons, narrowing further by the interval between casts and by which spells the creature owns.
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
| `/ca report` | The text of your marked wrong calls, ready to paste into an issue |
| `/ca mark <note>` | Mark a wrong call from chat, with an optional note |

`/forecast` and `/fcast` still work: the addon was called Forecast before 2026-09-01.

## Settings that are worth knowing about

Everything lives in the addon window, next to the cast table. **General** holds the eight switches for what gets announced, plus icon placement and the centre call's position; **Sounds** lets each category keep the voice or play any sound your other addons registered instead; the Sound override column of the casts table does the same for a single spell, and that pick wins over its category's.

The early warning ("tank buster soon") is a slider in seconds, off by default: on top of the real call it can read as two separate casts.

Icon rows step sideways by the words under them, so labels never touch; **Fixed spacing** in the Icon size group steps by icon plus a gap instead, for rows that pack identically every time. **Layer** in the same group is the icons' frame strata, BACKGROUND by default: above every nameplate and under the rest of the UI, like a plate; go higher to put the icons over your bars, DIALOG or above if a nameplate addon lifts its plates into the UI.

## Defensive calls (alpha)

Cast Ahead can also tell you when to press a defensive. It says "small defensive" or "big defensive" (SMALL SAVE and BIG SAVE on screen) and shows up to three icons of the buttons you can press right now. The calls come from three places: trash casts, dangerous debuffs on you (sound only), and boss abilities read from DBM or BigWigs bars. Which call a spell gets comes from a table built from measured top-player runs. Tanks get a save call only for tank busters: hits that land on the tank alone in those runs, or casts the priority list marks as a tank buster. A hit that also lands on the rest of the group keeps its normal call for a tank.

Each size has its own list of buttons, in order. If the first one is on cooldown (when the game lets addons read it), the next one in the same list takes its place; a small call never offers a big button and the other way round. Healthstones and potions are found in your bags by what they do, so any rank or version of the item works, and they drop off the icons while they are on cooldown or used up.

After a big hit lands, Cast Ahead says "heal up" (HEAL UP on screen) if something from your heal list is ready: a Healthstone, a potion, or a self-heal. This only follows a hit that got a big call, on trash when the cast finishes and on bosses when the bar runs out. Debuff calls never get a heal call.

Lists ship for these specs so far. Healthstones and the Silvermoon health potions sit in the heal list of every spec, not in the small one: they heal rather than reduce damage, so they are called after the hit, not before it. You can still add them to a list yourself.

- Warlock, all three specs: Dark Pact (small), Unending Resolve (big), Mortal Coil (heal).
- Paladin, Protection: Ardent Defender and Sentinel (small), Guardian of Ancient Kings and Divine Shield (big), Word of Glory and Lay on Hands (heal). Holy and Retribution: Divine Protection (small), Divine Shield and Blessing of Protection (big), Lay on Hands and Word of Glory (heal).
- Demon Hunter, Havoc and Devourer: Blur (small), Darkness (big). Vengeance: Demon Spikes (small), Fiery Brand and Metamorphosis (big).

Other specs get the generic call without button icons. More specs will follow.

The Defensives tab in the settings has a "Defensive calls" switch, a "Boss calls from DBM / BigWigs" switch, a "Heal up after a big hit" switch and the three lists for your current spec. Click a row to move it to another list or remove it. "Add from list" offers your class's defensives and the stones and potions; the Add box takes a spell or item id, a name, or a shift-clicked link. Reset to default asks first, then restores the shipped lists. The status line shows which boss mod is connected. Boss calls need DBM or BigWigs installed; without one, trash and debuff calls still work.

The Saves tab in the `/ca` window lists, for the current dungeon or the one you pick, every hit that gets a call: its size, your buttons, the mob or boss, what triggers it (cast, boss bar, debuff) and how early it comes. A hit where a kick, dodge or other mechanic wins over the save says so.

Boss coverage is partial today. A boss threat gets a call only when DBM or BigWigs runs a timer for it, because bars that exist only in Blizzard's own timeline give addons no callback. Schedules counted from the pull are the planned next step.

## Reporting a wrong call

Turn on Development mode in the settings, then the key journal on the Development tab. While you are in a dungeon a small panel lists the mobs Cast Ahead tracked in the last two minutes. Pick the one it got wrong (or none, to mark the whole moment) and press Mark, or Mark + note to type what really happened; Enter saves the note. The same two actions can be bound under Key Bindings > Cast Ahead. After the key, `/ca report` gives the text to paste into a [wrong call issue](https://github.com/AqueGen/CastAhead/issues/new?template=wrong-call.yml) or a CurseForge comment. The journal holds spell and creature ids and timings only, no names of people.

## Where the data comes from

The timings ship in `Data.lua`, generated from combat logs of real Mythic+ runs; `Priority.lua` marks which casts a human decided are worth reacting to; `Traits.lua` holds what the game still reveals about a creature on sight (level, classification, packmates), which names most mobs before they cast anything. The tools that rebuild them live in `tools/` and are not needed to play.

## Status

Alpha. It runs, it is tested headlessly on every push, and the season's data is current - but it has been used by one person in one region. Expect rough edges, and please report a cast that gets named wrong.
