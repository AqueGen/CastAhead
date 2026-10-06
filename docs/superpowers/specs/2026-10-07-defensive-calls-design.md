# Defensive calls - design

Date: 2026-10-07. Status: approved in conversation, awaiting written-spec review.

## Goal

CastAhead tells the player when to press a defensive and which size: "small save" or "big save", with the icon of the button their spec uses for it. It covers trash, debuffs landing on the player, and boss abilities, in one addon.

Why: an audit of the owner's warlock keys (+17/18) against 120 top Warcraft Logs warlock runs found 7 of 20 Unending Resolve presses made below 40% HP, after the hit (top players: 12%, median HP 77% at press), and no wasted early presses. Per-hit damage matched the top players, so the problem is timing. Audit page: https://claude.ai/artifact/HfeuFKW1FwS5qeauE9pGYP.

## Scope

- Alpha/beta: 9 specs with a shipped button table - Warlock (Affliction, Demonology, Destruction), Paladin (Holy, Protection, Retribution), Demon Hunter (Havoc, Vengeance, Devourer). Every other spec gets the generic call (no button icon) and a "more specs coming" note.
- Content: the 8 Mythic+ Season 2 dungeons, trash and bosses. Raid is out of scope for this version.
- Voice: English, rendered like the existing clips (Azure en-US GuyNeural, `tools/voice.py`).

## Product boundary change

This feature reverses two earlier decisions for itself only: the 2026-10-01 feature freeze and the 2026-09-01 "no ability suggestions" rule. Boss support does not make CastAhead a boss mod: it does not predict boss casts (encounter timeline fields are Secret, see the 2026-09-01 decision). It listens to the bars BigWigs or DBM already show and adds the defensive layer on top.

## Data pipeline (private, CastAheadTools)

1. Harvest from Warcraft Logs, zone 55, `characterRankings(className, specName, bracket: 17)` (returns +18 keys), about 5 runs per spec per dungeon (about 360 runs, about 1500 points). Per run: `DamageTaken` with `sourceID` = the player (for this data type the damaged player is `sourceID`; `targetID` returns only self-damage), `Casts` by the player, `masterData` names, `dungeonPulls` for boss windows. Every damage event carries a `buffs` string with the auras on the player at hit time.
2. Hit = damage from one source instance and ability within 3 s (ticks merged at gaps up to 1.5 s), counted as amount + absorbed, as a share of the player's max HP.
3. Button candidates per spec: rank the spells top players of that spec press shortly before their largest hits (the old `candidates.py` approach). The owner confirms the small and big list for each spec. Talent names are not taken from memory; 12.1 pruned many.
4. Verdict per (ability, role): `BIG` when top players of that role answer it with their big button or the 90th percentile hit is at least 60% HP; `SMALL` when they answer with the small button or the hit is 30-60%; nothing below. Tanks keep `TANK` and gain a verdict from tank specs.
5. Lead per ability: median seconds between the top players' press and the hit.
6. Boss ids: BigWigs and DBM sometimes broadcast a different spell id than the log records (Sever 1299680 vs 1299684). Join by name through the boss module source, as the MRT `build_alias.py` did.
7. Output: a generated `Defensives.lua` data file (verdicts, leads, aura flags, aliases) written by the private `CastAheadTools/def_build.py` (its input is Warcraft Logs player data, which never ships), plus the curated `SaveButtons.lua`.
8. Boss coverage: DBM timeline-only bars carry no callback and a Secret spell id; only module timers fire `DBM_TimerBegin` with a spell id. Before the adapter is built, a coverage report checks which boss verdict spells have a module timer; if coverage is poor, the owner decides between the adapter and from-pull schedules.

## Runtime

### Calls

- New advice keys `SMALL` (label `SMALL SAVE`, say "small defensive") and `BIG` (label `BIG SAVE`, say "big defensive") in `Match.ADVICE`, with `_soon` clips.
- One alert per call, as settled in PR #21. Priority: `KICK` / `CC` > `BIG` > `SMALL` > `TANK` / `AOE` / the rest. A cast that has a verdict for the player's role replaces the generic `AOE` call for that player.
- Centre block shows the icon of the first spell in the spec's list for that size, the label and the countdown. Specs without a table show the threatening spell's own icon, as the centre block does today.

### Triggers

- Trash: the existing identified-cast path. Warn at predicted time minus the ability's lead, and again at cast start.
- Debuffs on the player: `C_UnitAuras.AddAuraSound(Enum.UnitAuraSoundTrigger.Added, { unitToken = "player", spellID, soundFileName, outputChannel })` with the matching clip. Registration only out of combat and outside `C_ChatInfo.InChatMessagingLockdown()`; sound only, because reading the aura for an icon may be Secret (`C_Secrets.ShouldSpellAuraBeSecret`).
- Bosses: new module `BossAdapter.lua`.
  - BigWigs: `BigWigsLoader.RegisterMessage` for `BigWigs_StartBar` (module, key, text, duration, icon), `BigWigs_Timer`, `BigWigs_StopBar`, `BigWigs_PauseBar`, `BigWigs_ResumeBar`, `BigWigs_StopBars`, `BigWigs_OnBossDisable`. MRT's Reminder.lua listens to the same set.
  - DBM: `DBM:RegisterCallback` for `DBM_TimerBegin`, `DBM_TimerStop`, `DBM_TimerPause`, `DBM_TimerResume`, `DBM_TimerUpdate`.
  - A bar whose spell id has a verdict schedules a call at bar end minus lead; stop, pause and resume follow the bar.
  - Health check: if a boss mod is loaded and no bar arrives within 30 s of `ENCOUNTER_START`, print one chat line. DBM renamed its timer callback once and MRT went silent without a word; this guards that.
  - Disabled with a setting; silent when no boss mod is loaded.

### Settings

New Defensives tab in `Options.lua`, reads and writes through `Config.lua`:
- small and big button for the current spec, picked from the player's spellbook, plus "Reset to default";
- boss adapter on/off;
- status line: "BigWigs connected", "DBM connected" or "No boss mod".

## Testing

`test_core.lua` harness additions:
- verdict priority (`KICK` beats `BIG`, `BIG` replaces `AOE` for a matching role);
- button lookup per spec, override from settings, generic fallback for an unsupported spec;
- a stubbed BigWigs bar and DBM timer produce a call at bar end minus lead, and stop/pause cancel or hold it;
- `AddAuraSound` registration never happens in combat;
- `test.lua` data audit: every shipped spec has at least one small and one big spell, every verdict row has a clip.

## Data upkeep

`castahead-sync` gains a step that re-harvests the 9 specs and rebuilds `Defensives.lua` after a patch. The button table stays editable in settings, so a pruned talent can be fixed in game without waiting for a rebuild.

## Out of scope for v1

- Cooldown-aware fallback ("big save on cooldown, say small"): `C_Spell.GetSpellCooldown` is `SecretWhenCooldownsRestricted`. Counting cooldowns from the player's own `UNIT_SPELLCAST_SUCCEEDED` events may work; to be probed in game during alpha.
- Raid encounters, other classes, healer group cooldowns.

## Open questions for alpha

- Whether `BigWigs_StartBar` keys for Midnight dungeon modules are the spell ids we expect for every boss (MRT's BW_TIMER profile relies on them for the 8 dungeons).
- Whether the 60% / 30% thresholds feel right in game for all three roles.
