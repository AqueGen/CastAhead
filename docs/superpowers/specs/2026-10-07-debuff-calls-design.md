# Debuff calls on trash

Approved by the user on 2026-10-07. Revised the same day against the code (no per-context settings, no Keys tab, `SAVE` is already an alias of `TANK`, no zone-change event) and a real combat log.

## Problem

Some trash debuffs land with no cast and no target, Living Bomb (373693, Primalist Cinderweaver, 19 applications in the own log of 2026-10-06) in Ruby Life Pools being the example: it appears on the player and the answer (a defensive) has to come within a second. CastAhead predicts casts; it says nothing once a debuff is already on the player.

## What 12.x allows (checked in the generated API docs, G:/Games/wow-ui-source-live)

- `C_UnitAuras.AddAuraSound(trigger, soundInfo)` plays a sound when an aura with a given spell ID is added to a unit (`UnitAuraSoundInfo`: unitToken, spellID, soundFileName or soundFileID, outputChannel; trigger `Enum.UnitAuraSoundTrigger.Added`). The client does the matching, so secret aura data does not stop it. `RemoveAuraSound(auraSoundID)` undoes it. The function is flagged `HasRestrictions`.
- `C_Secrets.ShouldSpellAuraBeSecret(spellID)`: "Returns true if a given spell identifier would, if applied as an aura, produce secret values when queried."
- `C_UnitAuras.GetPlayerAuraBySpellID` is `SecretWhenUnitAuraRestricted` and `RequiresNonSecretAura`, so it answers in combat only for auras that are not secret.
- Who a hostile cast targets stays secret (`targetIsMe`, measured 2026-09-14), so "a mob casts at you" is out of scope.

## Decisions (user)

- The debuff list comes from logs, reviewed by hand. No lists from other addons.
- Candidates are ranked by how often the player dies while the aura is on and how much health it takes, not by deaths alone.
- The call names the kind of answer, never a button (product boundary of 2026-09-01): DEFENSIVE, DODGE (move out / away from the group), DISPEL.

## Data

- `tools/debuffs.py scan "<log glob>" <review.tsv>` reads own combat logs (the WCL harvest fetches casts only, so it is not an input yet). Inside keys and outside boss encounters, for every DEBUFF a creature applies to a player it records per dungeon and spell: applications, keys seen in, deaths of that player while the aura is on, median and p90 of the damage that player takes from creatures during the aura as a share of max health. Advanced-log damage fields as in collect.py (max health 15, amount 31, overkill 33, absorbed 37). Rows with at least 3 applications go to `CastAheadTools/curation/debuffs_review.tsv`, sorted by deaths then median share; an existing file keeps its hand-set `react` values.
- The user sets `react` to DEFENSIVE, DODGE or DISPEL, or leaves it empty. `tools/debuffs.py gen <review.tsv> Debuffs.lua` writes `CastAheadDebuffs = { [instanceID] = { [spellID] = "DEFENSIVE", ... } }`.
- Seed so the feature can be tested before the first review: Living Bomb 373693 in Ruby Life Pools (2521) = DEFENSIVE.

## Runtime

- New `Match.ADVICE.DEFENSIVE` (label DEFENSIVE, say "defensive"), clips `Sounds/en/DEFENSIVE.ogg` and `_soon` rendered by `tools/voice.py`. `SAVE` stays the alias of `TANK`.
- New `DebuffCalls.lua` (loaded before Core.lua) owns the logic; Core.lua only forwards events and asks it for centre lines.
- On PLAYER_ENTERING_WORLD and on every settings change (`CastAheadCore.Reapply`): remove the aura sounds we registered, then, if the instance has rows and both the `sound` and `debuffCalls` switches are on, register one `AddAuraSound(Added, { unitToken = "player", spellID = id, soundFileName = clip, outputChannel = "Master" })` per row. In combat nothing is removed or added; the refresh waits for PLAYER_REGEN_ENABLED. A call that errors is skipped and retried after the next combat.
- Centre text: on UNIT_AURA for `player`, rows whose `ShouldSpellAuraBeSecret` is false are looked up with `GetPlayerAuraBySpellID`; while one is on the player the centre block shows its call above any cast call, with the seconds left, or without a number when the aura has no expiry. Secret rows get the sound only. The centre block keeps its own switch and only runs in dungeons CastAhead has cast data for.
- A spell in the per-spell `disabled` list is skipped.
- Switch `debuffCalls` (flat, on unless turned off), "Call debuffs on you" in the Sound group of the General tab.

## Out of scope

- Casts aimed at the player, boss debuffs, other players' debuffs, ability suggestions.
- WCL as an input, the custom sound picker for debuff calls.
- Muting DBM's own aura sound for the same spell; if both play, the user turns one off.

## Testing

- test_core: entering an instance with rows registers one aura sound per row with the right clip path; entering another instance removes them; `debuffCalls` or `sound` off registers nothing; a disabled spell is skipped; in combat nothing changes until PLAYER_REGEN_ENABLED; a non-secret row on the player shows its call first in the centre block and a secret row does not.
- test.lua: every react value in Debuffs.lua is an ADVICE key (so its clips are checked by the existing clip loop).
- tools/test_debuffs.py: scan on an inline log gives the expected applications, keys, deaths and shares, skips boss encounters and buffs, keeps hand-set reacts; gen writes the Lua table and rejects an unknown react.
- In game: Living Bomb in Ruby Life Pools plays "defensive" the moment it lands.
