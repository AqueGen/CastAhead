# Debuff calls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Say "defensive" / "dodge" / "dispel" the moment a listed trash debuff lands on the player, and show it in the centre block when the game lets us read the aura.

**Architecture:** `tools/debuffs.py` turns own combat logs into a review TSV and the reviewed TSV into generated `Debuffs.lua`. `DebuffCalls.lua` registers one `C_UnitAuras.AddAuraSound` per row of the current instance and keeps the list of readable debuffs on the player; Core.lua forwards PLAYER_ENTERING_WORLD, PLAYER_REGEN_ENABLED, UNIT_AURA and Reapply to it and merges its centre lines.

**Tech Stack:** WoW 12.1 Lua 5.1 (headless `lua test.lua`, `lua test_core.lua` in WSL `~/luaenv/bin/lua`), Python 3 + pytest for tools, Azure TTS via tools/voice.py.

**Spec:** docs/superpowers/specs/2026-10-07-debuff-calls-design.md

## Global Constraints

- React values are exactly `DEFENSIVE`, `DODGE`, `DISPEL`.
- Review TSV lives in `../CastAheadTools/curation/debuffs_review.tsv` (private, not in git); `Debuffs.lua` ships.
- Only `Sounds/en` clips; path `Interface\AddOns\CastAhead\Sounds\en\<FILE>.ogg`.
- `SAVE` stays `M.ADVICE.SAVE = M.ADVICE.TANK`.
- No comments by default; no AI attribution; commits in English.
- Tests: `MSYS_NO_PATHCONV=1 wsl --cd "/mnt/g/Games/World of Warcraft/_retail_/Interface/AddOns/CastAhead" bash -lc '~/luaenv/bin/lua test.lua | tail -1 && ~/luaenv/bin/lua test_core.lua | tail -1'` prints `OK` twice; `python -m pytest -q tools` passes.

## Review Focus

- Settings change in combat (Reapply from SPELLS_CHANGED): must not drop the registered sounds mid-pull (test in Task 3).
- Leaving the dungeon: every registered sound removed, nothing left registered in the open world (test in Task 3).
- A debuff with no expiry (expirationTime 0): centre line without "-1e9" style numbers (test in Task 4).
- An aura still read after it expired (stale UNIT_AURA): not shown past its end (test in Task 4).
- A player death line for a player with no open debuff window must not crash the scan (test in Task 2).

---

### Task 1: DEFENSIVE call and its clips

**Files:** Modify `Match.lua` (ADVICE table near BLEED), `tools/voice.py` (`LINES`); Create `Sounds/en/DEFENSIVE.ogg`, `Sounds/en/DEFENSIVE_soon.ogg`.

- [ ] Add `DEFENSIVE = { label = "DEFENSIVE", say = "defensive", r = 1.00, g = 0.55, b = 0.20 },` to `M.ADVICE`.
- [ ] Run test.lua. Expected: FAIL "voice clip missing: Sounds/en/DEFENSIVE.ogg" (the existing clip loop covers every ADVICE key).
- [ ] Add `"DEFENSIVE": "defensive",` to `LINES`; run `python tools/voice.py` from the addon folder (renders only missing clips).
- [ ] Run test.lua and test_core.lua: OK. Commit `feat: a DEFENSIVE call with its voice clips`.

### Task 2: debuffs.py scan and gen, seed Debuffs.lua

**Files:** Create `tools/debuffs.py`, `tools/test_debuffs.py`, `Debuffs.lua`; Modify `CastAhead.toc` (Debuffs.lua after Packs.lua), `.github/workflows/test.yml` (luac list), `test.lua` (react values are ADVICE keys).

**Interfaces:** Produces `CastAheadDebuffs[instanceID][spellID] = "DEFENSIVE"|"DODGE"|"DISPEL"`.

- [ ] Tests (pytest, inline log written to tmp_path, lines in the verified format, e.g. `10/6/2026 20:23:52.3413  SPELL_AURA_APPLIED,Creature-0-3111-2521-1-188244-0000C52E92,"Primal Juggernaut",0xa48,0x80000000,Player-1-AAAA,"A-Realm-EU",0x512,0x80000000,1305201,"Excavating Blast",0x8,DEBUFF`): three applications on two keys with one death inside the window give applications 3, keys 2, deaths 1; damage during the window gives the share (amount - max(0, overkill) + absorbed) / maxHP summed per window; a window inside ENCOUNTER_START..END and a BUFF are ignored; UNIT_DIED of a player with no window is ignored; rows under 3 applications are left out; rerunning scan keeps a hand-set react; gen writes `[2521] = {` and `[373693] = "DEFENSIVE",` and raises on react `SAVE`.
- [ ] Run `python -m pytest -q tools/test_debuffs.py`: FAIL (module missing).
- [ ] Implement `tools/debuffs.py` with `scan(paths) -> dict`, `write_review(stats, path)`, `gen(review_path, out_path)` and a CLI `scan <glob> <tsv>` / `gen <tsv> <lua>`. Field indexes after `csv.reader` of the part after the double space: event 0, source GUID 1, dest GUID 5, spellID 9, name 10, aura type 12; damage events `SPELL_DAMAGE`/`SPELL_PERIODIC_DAMAGE` max health 15, amount 31, overkill 33, absorbed 37; `UNIT_DIED` dest GUID 5. Keys from `CHALLENGE_MODE_START,"zone",instanceID,...` to `CHALLENGE_MODE_END`.
- [ ] Run pytest: PASS.
- [ ] Run scan on the own log on disk into the review TSV, set react DEFENSIVE on 373693, run gen into `Debuffs.lua`; add it to the TOC and the CI luac list; add to test.lua: every value in `CastAheadDebuffs` is a key of `CastAheadMatch.ADVICE` and not `SAVE`.
- [ ] test.lua, test_core.lua OK, pytest PASS. Commit `feat: debuff candidates from own logs, and the generated Debuffs.lua`.

### Task 3: aura sounds per instance

**Files:** Create `DebuffCalls.lua`; Modify `CastAhead.toc` (DebuffCalls.lua after Debuffs.lua), CI luac list, `Core.lua` (PLAYER_ENTERING_WORLD, PLAYER_REGEN_ENABLED, Reapply), `Options.lua` (SWITCHES + BuildSwitch under voice, Sound group height 86 -> 114), `test_core.lua` (stubs + cases).

**Interfaces:** Produces `CastAheadDebuffCalls.Refresh()`, `.AfterCombat()`, `.OnPlayerAura()`, `.Picks(now, out)`.

- [ ] test_core stubs: `C_UnitAuras.AddAuraSound` records `{ trigger, info }` and returns an increasing id; `RemoveAuraSound` records removed ids; `Enum.UnitAuraSoundTrigger = { Added = 0 }`; `InCombatLockdown` reads a local flag; `dofile("Debuffs.lua")` and `dofile("DebuffCalls.lua")` before Core.lua; tests set `CastAheadDebuffs[1877] = { [900] = "DEFENSIVE", [901] = "DODGE" }`.
- [ ] Cases: PLAYER_ENTERING_WORLD in 1877 registers 900 and 901 for `player` with `...\\Sounds\\en\\DEFENSIVE.ogg` / `DODGE.ogg`; instance 2000 without rows removes both and registers none; `debuffCalls = false` or `sound = false` registers none; `disabled[901]` registers only 900; with InCombatLockdown true a Reapply neither removes nor adds, and PLAYER_REGEN_ENABLED then refreshes.
- [ ] Run test_core: FAIL.
- [ ] Implement `DebuffCalls.lua` (Refresh: if in combat set pending and return; remove ours; rows = switches on and instance rows; AddAuraSound per enabled row via pcall, error sets pending), wire Core: `CastAheadDebuffCalls.Refresh()` after `LoadDungeon()` and at the end of `CastAheadCore.Reapply`, `.AfterCombat()` on PLAYER_REGEN_ENABLED; add the switch `debuffCalls = { label = "Call debuffs on you", tip = "Says the answer - defensive, dodge, dispel - the moment a dangerous trash debuff lands on you. Works in combat; the centre call shows it too when the game lets the addon read that debuff." }`.
- [ ] test_core OK, test.lua OK. Commit `feat: call listed debuffs the moment they land on you`.

### Task 4: centre line for readable debuffs

**Files:** Modify `DebuffCalls.lua` (OnPlayerAura, Picks), `Core.lua` (UNIT_AURA branch, CenterPick merge and sort, UpdateCenter no-expiry text), `test_core.lua`.

- [ ] Stubs: `C_Secrets.ShouldSpellAuraBeSecret = function(id) return id == 901 end`; `C_UnitAuras.GetPlayerAuraBySpellID` from a local table.
- [ ] Cases (centerText = true): with 900 (expires in 5 s) and 901 on the player and a cast call live, UNIT_AURA then advance puts "Defensive  5.0" on the first centre line and nothing for 901; an aura with expirationTime 0 shows "Defensive" with no number; after the expiry time passes without a new UNIT_AURA the line is gone; debuffCalls off shows nothing.
- [ ] Run test_core: FAIL.
- [ ] Implement OnPlayerAura (rows only, readable rows only, pcall, secret checks, endAt = expiration or math.huge), Picks (endAt > now), CenterPick appends `CastAheadDebuffCalls.Picks(now, centerPicks)` and sorts debuff lines first, UpdateCenter prints `say` alone when `endAt == math.huge`.
- [ ] test_core OK, test.lua OK, pytest PASS. Commit `feat: readable debuffs on you lead the centre call`.

### Task 5: ship to the working branch

- [ ] Final review of the branch (most capable model), fix Critical/Important.
- [ ] Push `feat/debuff-calls`, PR #53 ready for review, merge `feat/debuff-calls` into `fix/report-window`, tests OK there, push.
- [ ] Memory note; tell the user what to check in game (Living Bomb in Ruby Life Pools, `/run print(C_Secrets.ShouldSpellAuraBeSecret(373693))`).
