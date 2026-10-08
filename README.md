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

Cast Ahead can also tell you when to press a defensive. It says "small defensive" or "big defensive" (SMALL SAVE and BIG SAVE on screen) and shows up to three icons of the buttons you can press right now. The calls come from three places: trash casts, dangerous debuffs on you (sound only), and boss abilities read from DBM or BigWigs bars. A cast aimed at one player says "targeted" rather than a save: the game does not tell addons whom it is aimed at, so a save call there would often be for someone else. The centre block still draws the save line under it, visible only when the cast is on you: the game lets an addon draw by that answer without reading it. Which call a spell gets comes from a table built from top-player runs in +20 and +21 keys, so a hit that only kills at high keys is still called at lower ones: you learn the habit before it costs a key. A big call means the hit takes 80% of a top player's health or more at that level, or top players spend a big cooldown on it often; a small call means 50% or more, or a small save is often pressed. Tanks get a save call only for tank busters: hits that land on the tank alone in those runs, or casts the priority list marks as a tank buster. A hit that also lands on the rest of the group keeps its normal call for a tank.

Each size has its own list of buttons, in order. If the first one is on cooldown (when the game lets addons read it), the next one in the same list takes its place; a small call never offers a big button and the other way round. Healthstones and potions are found in your bags by what they do, so any rank or version of the item works, and they drop off the icons while they are on cooldown or used up.

If you switch it on (it is off by default), after a big hit lands Cast Ahead says "heal up" (HEAL UP on screen) if something from your heal list is ready: a Healthstone, a potion, or a self-heal. This only follows a hit that got a big call, on trash when the cast finishes and on bosses when the bar runs out. Debuff calls never get a heal call.

Every spec ships its own lists, picked from what top players press in +18 keys on Warcraft Logs. Only personal defensives are listed: externals and raid cooldowns are left out, and so are buttons pressed on rotation (Ironfur, Ignore Pain, Shield Block, Purifying Brew). A spec with a single personal defensive has it in both the small and the big list. Healthstones and the Silvermoon health potions sit in the heal list of every spec, not in the small one: they heal rather than reduce damage, so they are called after the hit, not before it. You can still add them to a list yourself.

- Death Knight: Anti-Magic Shell (small, plus Lichborne for Frost and Unholy), Icebound Fortitude (big, after Vampiric Blood for Blood), Death Pact (heal).
- Demon Hunter, Havoc and Devourer: Blur (small), Darkness (big). Vengeance: Demon Spikes (small), Fiery Brand and Metamorphosis (big).
- Druid: Barkskin (small). Big is Survival Instincts for Feral and Guardian, Bear Form for Balance and Restoration. Heal is Frenzied Regeneration for Balance, Feral and Guardian, plus Regrowth for Balance and Feral.
- Evoker: Obsidian Scales (small and big), Verdant Embrace (heal).
- Hunter: Survival of the Fittest (small), Aspect of the Turtle (big), Exhilaration (heal).
- Mage: the spec's barrier and Mirror Image (small), Ice Cold and Greater Invisibility (big), Alter Time (heal).
- Monk, Brewmaster: Celestial Infusion (small), Fortifying Brew (big), Expel Harm (heal). Windwalker: Touch of Karma (small), Fortifying Brew (big). Mistweaver: Fortifying Brew (small and big).
- Paladin, Protection: Ardent Defender and Sentinel (small), Guardian of Ancient Kings and Divine Shield (big), Word of Glory and Lay on Hands (heal). Holy and Retribution: Divine Protection (small), Divine Shield and Blessing of Protection (big), Lay on Hands and Word of Glory (heal).
- Priest: Fade (small, plus Power Word: Shield for Discipline and Shadow), Desperate Prayer (big, plus Dispersion for Shadow), Vampiric Embrace (heal, Shadow).
- Rogue: Feint (small), Cloak of Shadows and Evasion (big), Crimson Vial (heal).
- Shaman: Astral Shift (small and big), Healing Surge (heal, Elemental and Enhancement).
- Warlock: Dark Pact (small), Unending Resolve (big), Mortal Coil (heal).
- Warrior: Spell Reflection (small). Big is Die by the Sword for Arms, Enraged Regeneration for Fury, Shield Wall for Protection. Impending Victory (heal).

The Defensives tab in the settings has a "Defensive calls" switch for all of them, a "Boss calls from DBM / BigWigs" switch, one switch each for small and big calls (both on by default), a "Heal up after a big hit" switch (off by default), a "Save early warning" slider (0 to 10 seconds, off by default: a save is called when the cast starts, not before) and the three lists for your current spec. The arrows on a row move it up or down: the top ready button is the one called first, and the shipped lists put the button top players press most at the top. Click a row to move it to another list or remove it. "Add from list" offers your class's defensives and the stones and potions; the Add box takes a spell or item id, a name, or a shift-clicked link. Reset to default asks first, then restores the shipped lists. The status line shows which boss mod is connected. Boss calls need DBM or BigWigs installed; without one, trash and debuff calls still work.

The Saves tab in the `/ca` window lists, for the current dungeon or the one you pick, every hit that gets a call: its size, your buttons, the mob or boss, what triggers it (cast, boss bar, debuff) and how early it comes. A hit where a kick, dodge or other mechanic wins over the save says so.

The Guide tab next to it reads the same data as plain text, a cheat sheet for the picked dungeon and your current spec and lists: each boss in turn, then the trash, one line per hit, for example "Living Bomb from Primalist Cinderweaver (debuff on you): big save - Unending Resolve; heal up after the hit". Hits also say when they come: the first cast after the pull and the gap to the next one. For trash the gaps are the cycle the mob repeats; for bosses they are the typical gaps in order as measured in top-player runs, so a boss that pauses between phases shows the pause. Boss times are approximate.

Boss coverage is partial today. A boss threat gets a call only when DBM or BigWigs runs a timer for it, because bars that exist only in Blizzard's own timeline give addons no callback. Schedules counted from the pull are the planned next step.

## Reporting a wrong call

Turn on Development mode in the settings, then the key journal on the Development tab. While you are in a dungeon a small panel lists the mobs Cast Ahead tracked in the last two minutes. Pick the one it got wrong (or none, to mark the whole moment) and press Mark, or Mark + note to type what really happened; Enter saves the note. The same two actions can be bound under Key Bindings > Cast Ahead. After the key, `/ca report` gives the text to paste into a [wrong call issue](https://github.com/AqueGen/CastAhead/issues/new?template=wrong-call.yml) or a CurseForge comment. The journal holds spell and creature ids and timings only, no names of people.

## Where the data comes from

The timings ship in `Data.lua`, generated from combat logs of real Mythic+ runs; `Priority.lua` marks which casts a human decided are worth reacting to; `Traits.lua` holds what the game still reveals about a creature on sight (level, classification, packmates), which names most mobs before they cast anything. The tools that rebuild them live in `tools/` and are not needed to play.

## Status

Alpha. It runs, it is tested headlessly on every push, and the season's data is current - but it has been used by one person in one region. Expect rough edges, and please report a cast that gets named wrong.
