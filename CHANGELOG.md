# Changelog

## [0.1.0] - 2026-09-01

First alpha.

### Features

- Identifies trash casts by measured cast length, narrowed by the interval between casts, the opening delay, and the creature's own spell list - none of which the 12.1 API hands out directly.
- Countdown icons beside enemy nameplates, in any of nine positions with a configurable growth direction and distance.
- Spoken calls: recorded clips for every response category, with the game's own combat voice and a beep as fallbacks; each category's sound can be replaced from any LibSharedMedia source.
- Centre-screen call showing the icon, the response in words and the seconds left, draggable anywhere.
- Confident predictions are pushed to Blizzard's encounter timeline.
- Channelled abilities are identified and predicted like casts.
- Filters: hand-picked important casts only, and calls the character can actually answer (dispels are gated on knowing a matching dispel, tank busters on being a tank or healer).
- Per-content-type settings: keys and raids keep independent values for what gets announced.
- Configurable early warning, 0 to 15 seconds, off by default.
- Database browser with per-spell switches, sortable by every measured column.
- Test drive that replays sample calls on nearby enemies without a dungeon.
