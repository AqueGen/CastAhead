# Save lists, heal-after calls and the Saves view - design

Date: 2026-10-08. Status: approved in conversation, awaiting written-spec review. Builds on `2026-10-07-defensive-calls-design.md` (same branch, PR #54).

## Goal

Three extensions the owner asked for after seeing the first version:

1. Each size holds several buttons, not one. A warlock's small save is Dark Pact or a Healthstone; another spec may add a potion.
2. A third kind of call, "heal up", for things that only help after the hit lands (Healthstone, healing potion). Pressing them before the hit is wasted.
3. The player can see, inside the addon, which hits call a save, what size, which buttons and what triggers the call. Today only a web page shows it.

## Facts this design rests on (checked 2026-10-08)

- `C_Item.GetItemCount`, `C_Item.GetItemCooldown`, `C_Item.IsUsableItem`, `C_Item.GetItemIconByID` and `C_Item.GetItemSpell` carry no Secret marker (`Blizzard_APIDocumentationGenerated/ItemDocumentation.lua:412-435, 589, 948, 1590`). Item availability and item cooldowns are readable in combat. Spell cooldowns are not (`C_Spell.GetSpellCooldown` is `SecretWhenCooldownsRestricted`).
- `UnitHealth` is `SecretReturns` for every unit (`UnitDocumentation.lua:1452-1455`), so a heal call cannot be triggered by "health below X". It is timed off the hit instead.
- Healthstone and potion item ids for Midnight are not verified. Top-player casts in our harvest show the use-spell `452930 Demonic Healthstone`. Items are therefore resolved by their use spell, by scanning the bags out of combat (`C_Item.GetItemSpell(itemID)` returns the use spell).

## Model

- `SaveButtons.lua` per spec: `small`, `big`, `heal`, each an ordered list. An entry is a spell id (number) or `{ use = <use spell id> }` for an item, resolved to whatever bag item has that use spell.
- Shipped defaults: the current small/big picks stay. Warlock (265, 266, 267) adds `{ use = 452930 }` to `heal`. Other specs ship `heal` empty. Healing potions are added by the player (their ids are not verified, and potion choice differs per player).
- Player overrides: `CastAheadDB.saveButtons[specID] = { small = {...}, big = {...}, heal = {...} }`, lists of the same entry shape, replacing the shipped list for that size when present. Migration: an old single-number override becomes a one-entry list.

## Runtime

- Availability: a spell entry is available when `IsPlayerSpell` knows it. An item entry is available when a bag item with that use spell exists (`GetItemCount > 0`) and is off cooldown (`GetItemCooldown`). The bag-to-item resolution runs out of combat on `BAG_UPDATE_DELAYED`, `PLAYER_ENTERING_WORLD` and spec change, and is cached. Count and cooldown are read live.
- Centre block: a save call shows the icons of every available entry of its size, up to 3, first one large and the rest small after it. Spells are always shown (their cooldown cannot be read); items only when ready.
- Heal call: new advice key `HEAL` (label `HEAL UP`, say "heal up", clip `HEAL.ogg`, no `_soon` variant needed but rendered for symmetry). It fires once, at the hit, only for a hit whose save call was `BIG` for the player's role, and only when at least one `heal` entry is available:
  - trash: when the identified cast that carried the BIG call finishes (`UNIT_SPELLCAST_STOP` / `CHANNEL_STOP` handling that already exists);
  - boss: when the scheduled boss call reaches its `endAt` (Saves.Tick).
  - Aura-only hits get no heal call: the aura sound is the single call there.
- One alert per call still holds for each call. Heal is a separate call after the hit, which the owner accepted (2026-10-08).
- Switches: `saveCalls` off silences heal too. A new switch `healCalls` (nil = on) turns only the heal call off.

## Saves view in `/ca`

- A new view in the existing cast window (UI.lua): "Saves", the same rows as the web page, for the current dungeon (or the one picked in the window's dungeon selector): size chip, the player's buttons for that size, hit name, mob, boss or trash, trigger (cast, DBM bar, debuff, not heard), lead seconds, and the mechanic that wins over the save when one does.
- Data: the generator adds `name`, `mob`, `boss`, `dungeon` (instance id) and `bar` (a DBM module timer resolves to the row) to each `CastAheadDefensives.spells` row. "cast" is computed at runtime from the Data rows already loaded; "debuff" from `aura`.

## Settings

The Defensives tab replaces the two single-pick dropdowns with three lists (Small, Big, Heal): each shows its entries with icon and name and a remove button, plus an "Add" box that takes a spell id, a spell name the character knows, an item id or a pasted item link (the item's use spell becomes the stored entry). "Reset to default" restores the shipped lists for the spec. Every write calls `CastAheadSaves.Refresh()`.

## Testing

- test_core: list order and availability (spell known/unknown, item in bags/absent/on cooldown via a stubbed `C_Item`), override replaces shipped list, old single-number override migrates, centre shows up to 3 icons, heal call fires once at trash cast end and at boss bar end only for BIG and only with a ready heal entry, `healCalls` off and `saveCalls` off silence it, no heal for aura-only hits.
- test.lua: data audit for the new Defensives fields; every ADVICE key has its clip (covers HEAL).
- Python: generator writes the new fields; pytest for `bar` and the name/mob/boss pick.

## Out of scope

- Health-threshold heal calls (health is Secret).
- Shipping potion ids.
- Raid encounters.
