# Debuff calls on trash

Approved by the user on 2026-10-07.

## Problem

Some trash debuffs land with no cast and no target, Living Bomb (373693) in Ruby Life Pools being the example: it appears on the player and the answer (a defensive) has to come within a second. CastAhead predicts casts; it says nothing once a debuff is already on the player. Boss mods cover this unevenly on trash.

## What 12.x allows (checked in the generated API docs, G:/Games/wow-ui-source-live)

- `C_UnitAuras.AddAuraSound(trigger, soundInfo)` plays a sound when an aura with a given spell ID is added to a unit (`UnitAuraSoundInfo`: unitToken, spellID, soundFileName or soundFileID, outputChannel; trigger `Enum.UnitAuraSoundTrigger.Added`). The client does the matching, so secret aura data does not stop it. `RemoveAuraSound(auraSoundID)` undoes it. The function is flagged `HasRestrictions`.
- `C_Secrets.ShouldSpellAuraBeSecret(spellID)`: "Returns true if a given spell identifier would, if applied as an aura, produce secret values when queried."
- `C_UnitAuras.GetPlayerAuraBySpellID` is `SecretWhenUnitAuraRestricted` and `RequiresNonSecretAura`, so it answers in combat only for auras that are not secret.
- Who a hostile cast targets stays secret (`targetIsMe`, measured 2026-09-14), so "a mob casts at you" is out of scope.

## Decisions (user)

- The debuff list comes from logs (own logs plus the WCL harvest), reviewed by hand. No lists from other addons.
- Candidates are ranked by how often the player dies while the aura is on and how much health it takes, not by deaths alone.
- The call names the kind of answer, never a button (product boundary of 2026-09-01): SAVE (defensive), DODGE (move out / away from the group), DISPEL.

## Data

- `CastAheadTools/debuffs.py` reads the same inputs as the cast pipeline (own combat logs, WCL harvests) and, per dungeon, for every aura a creature applies to a player: applications, distinct keys, deaths of that player while the aura is on, median and p90 damage taken by that player from creatures during the aura as a share of max health, aura duration. Writes `CastAheadTools/curation/debuffs_review.tsv` sorted by deaths then damage share.
- The user marks each row SAVE / DODGE / DISPEL or leaves it empty. `debuffs.py --gen` writes the marked rows to `CastAhead/Debuffs.lua`: `CastAheadDebuffs = { [instanceID] = { [spellID] = "SAVE", ... } }`.
- Seed row so the feature can be tested before the first review: Ruby Life Pools (2521) Living Bomb 373693 = SAVE.

## Runtime (new file `Debuffs.lua` data + logic in `Core.lua` next to the centre block)

- On PLAYER_ENTERING_WORLD and ZONE_CHANGED_NEW_AREA: remove every aura sound we registered, then, if the feature is on and the instance has rows, register one `AddAuraSound(Added, { unitToken = "player", spellID = id, soundFileName = clip, outputChannel = "Master" })` per row. Calls go through `pcall`; a failure or a nil ID is skipped silently, and registration is retried on PLAYER_REGEN_ENABLED if it failed in combat.
- Clips: `Sounds/en/SAVE.ogg` (new, rendered by `tools/voice.py`, says "Defensive"), existing `DODGE.ogg` and `DISPEL.ogg`.
- Centre text: rows whose `ShouldSpellAuraBeSecret` is false are checked on UNIT_AURA for `player` with `GetPlayerAuraBySpellID`; while one is on the player the centre block shows its call (label and icon) above any cast call. Secret rows get the sound only.
- A spell in the existing per-spell `disabled` list is skipped.
- Setting `debuffCalls` (per context, default on in keys, off in raid), checkbox "Call debuffs on you" on the Keys tab.

## Out of scope

- Casts aimed at the player, boss debuffs, other players' debuffs, ability suggestions.
- Muting DBM's own aura sound for the same spell; if both play, the user turns one off.

## Testing

- test_core: entering an instance with rows registers one aura sound per row with the right clip; leaving or entering another instance removes them; the setting off registers nothing; a disabled spell is skipped; a non-secret row present on the player shows the call in the centre block and a secret row does not; registration that errors is retried after combat.
- test.lua: every call kind used in Debuffs.lua has a clip.
- tools: debuffs.py on a small fixture log gives the expected counts, deaths and damage share.
- In game: Living Bomb in Ruby Life Pools plays the call the moment it lands.
