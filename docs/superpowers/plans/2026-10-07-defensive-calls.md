# Defensive Calls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** CastAhead calls "small defensive" or "big defensive" with the icon of the player's own button, on trash casts, on debuffs landing on the player, and on boss abilities announced by DBM or BigWigs bars.

**Architecture:** A private Python pipeline in `CastAheadTools` harvests top-player damage taken and defensive presses from Warcraft Logs for 9 specs and writes `Defensives.lua` (per-spell verdict per role, lead seconds, aura flag, boss-mod id aliases). The shipped button table `SaveButtons.lua` is curated with the owner from a candidates report. In the addon, `Match.lua` gains `SMALL`/`BIG` advice that ranks below `KICK`/`CC` and above everything else; a new `Saves.lua` owns button lookup, scheduled calls and aura sounds; a new `BossAdapter.lua` turns DBM/BigWigs bars into scheduled calls; Core only wires the centre block, the heads-up lead and an exported `Announce`.

**Tech Stack:** WoW 12.1 Lua 5.1 (headless tests in WSL `~/luaenv/bin/lua`), Python 3 with pytest, Warcraft Logs v2 GraphQL (client credentials via `CastAheadTools/wcl.py` `Client`).

**Spec:** `docs/superpowers/specs/2026-10-07-defensive-calls-design.md`

## Spec refinements made while planning (win over the spec where they differ)

- `Defensives.lua` is written by a new private generator `CastAheadTools/def_build.py`, not by `tools/gen.py`: its input is Warcraft Logs player data, which never ships in the public repo.
- Fallback icon for a spec without a button table is the threatening spell's own icon (what the centre block shows today), not a shield icon: no generic shield texture id was verified.
- DBM timeline-only bars carry no callback and a Secret spell id (`DBM-Core/modules/EncounterEvents.lua:129-131`); only module timers fire `DBM_TimerBegin` with a spell id (`DBM-Core/modules/objects/Timer.lua:561-563`). Task 4 measures boss coverage before the adapter is built and stops for an owner decision if it is poor.
- BigWigs is not installed on the owner's machine today; the BigWigs half of the adapter is built against MRT's verified usage (`MRT/Reminder.lua:19272-19287`, `19347`) and tested with stubs only.

## Global Constraints

- Display name in player-facing strings: "Cast Ahead". Identifiers stay `CastAhead*`.
- Alpha specs and their game spec ids: Affliction 265, Demonology 266, Destruction 267, Holy 65, Protection 66, Retribution 70, Havoc 577, Vengeance 581, Devourer 1480 (ids from `DBM-Core/Libs/LibSpecialization/LibSpecialization.lua:71-73,168-170` and Blizzard `TrackedCooldowns.lua:28-42`; verify Warlock and Paladin ids the same way in Task 3).
- Roles are the strings `GetSpecializationRole` returns: `"DAMAGER"`, `"TANK"`, `"HEALER"`.
- Verdict thresholds: `BIG` at 90th-percentile hit >= 60% of max HP or top players answer with their big button; `SMALL` at 30-60% or answered with the small button; nothing below 30%.
- One alert per call (PR #21): voice or a picked sound, never both. Priority `KICK` / `CC` > `BIG` > `SMALL` > the rest.
- Never read, compare or boolean-test a value 12.x may return Secret. Boss-mod spell ids arrive as plain numbers from addon callbacks; guard every one with `tonumber`.
- `C_UnitAuras.AddAuraSound` / `RemoveAuraSound` are called only out of combat and outside `C_ChatInfo.InChatMessagingLockdown()`.
- Warcraft Logs data and the harvesters stay in `CastAheadTools` (private, never packaged). Only the derived `Defensives.lua` ships.
- No code comments except facts nobody can re-check on demand (owner rule).
- Tests: `MSYS_NO_PATHCONV=1 wsl bash -lc 'cd "/mnt/g/Games/World of Warcraft/_retail_/Interface/AddOns/CastAhead" && ~/luaenv/bin/lua test.lua | tail -1 && ~/luaenv/bin/lua test_core.lua | tail -1'` must print `OK` twice; `python -m pytest -q tools` in `CastAhead` and `python -m pytest -q test_defensives.py` in `CastAheadTools` must pass.
- Work on branch `feat/defensive-calls` in the live AddOns folder; push after each task; PR #54 stays draft until Task 11.

## Review Focus

1. Changing spec mid-session (or a talent swap that removes the chosen button) must switch the icon and the aura-sound registrations to the new spec without a reload - pinned in Task 7 and Task 8.
2. A boss bar stopped, paused or restarted (DBM `DBM_TimerStop` / `Pause` / `Resume` / `Update`, BigWigs `StopBar` / `StopBars` / `OnBossDisable`) must never leave a stale call that fires after the ability already happened or was cancelled - pinned in Task 9.
3. A boss-mod spell id that is not a number (BigWigs option keys can be strings, DBM user timers pass nil) must be ignored without an error - pinned in Task 9.
4. `/reload` or a spec change during combat must not try to register aura sounds in combat; the registration waits for `PLAYER_REGEN_ENABLED` - pinned in Task 8.
5. A player with the role filter switched off must still get save calls for their real role, and a curated `KICK` cast with a `BIG` verdict must still say "interrupt" - pinned in Task 5.

---

### Task 1: Defensive data library (pure functions)

**Files:**
- Create: `CastAheadTools/defensives.py`
- Create: `CastAheadTools/test_defensives.py`

**Interfaces:**
- Produces:
  - `merge_hits(events, max_hp_default) -> list[dict]`: input are WCL `DamageTaken` events of one player (dicts with `timestamp` ms, `sourceID`, `targetID`, `sourceInstance`?, `abilityGameID`, `amount`, `absorbed`?, `maxHitPoints`?, `buffs`?); output hits `{"t": ms, "sid": int, "src": int, "taken": int, "max": int, "pct": float, "buffs": set[int]}`. Self-damage (`sourceID == targetID`) is dropped. Ticks from one `(sourceID, sourceInstance, abilityGameID)` merge while the gap is <= 1500 ms and the span <= 3000 ms. `max` is the last seen `maxHitPoints`, else the median of the run's values, else `max_hp_default`.
  - `press_anchors(hits, presses, window_ms) -> list[tuple[int, int, float, float]]`: for each press `(t_ms, spell_id)` the largest hit with `t <= hit.t <= t + window_ms`, returned as `(press_spell, hit_sid, hit_pct, lead_seconds)`.
  - `verdict(p90, small_answers, big_answers) -> str | None`: `"BIG"` when `big_answers >= 3` or `p90 >= 60`; else `"SMALL"` when `small_answers >= 3` or `p90 >= 30`; else `None`.
  - `percentile(values, q) -> float` (nearest-rank, `q` in 0..1, empty list -> 0.0).

- [ ] **Step 1: Write the failing tests**

```python
from defensives import merge_hits, press_anchors, verdict, percentile


def ev(t, sid, amount, src=5, inst=None, absorbed=0, mx=None, buffs=""):
    e = {"timestamp": t, "sourceID": src, "targetID": 1, "abilityGameID": sid,
         "amount": amount, "absorbed": absorbed, "buffs": buffs}
    if inst is not None:
        e["sourceInstance"] = inst
    if mx is not None:
        e["maxHitPoints"] = mx
    return e


def test_ticks_merge_within_gap_and_span():
    hits = merge_hits([ev(0, 7, 100, mx=1000), ev(1000, 7, 100), ev(2000, 7, 100), ev(3500, 7, 100)], 1000)
    assert [h["taken"] for h in hits] == [300, 100]
    assert hits[0]["pct"] == 30.0


def test_gap_over_1500_ms_splits():
    hits = merge_hits([ev(0, 7, 100, mx=1000), ev(1600, 7, 100)], 1000)
    assert len(hits) == 2


def test_absorbed_counts_and_self_damage_is_dropped():
    events = [ev(0, 7, 0, absorbed=500, mx=1000), {"timestamp": 10, "sourceID": 1, "targetID": 1,
              "abilityGameID": 9, "amount": 900}]
    hits = merge_hits(events, 1000)
    assert len(hits) == 1 and hits[0]["pct"] == 50.0


def test_two_sources_same_spell_stay_apart():
    hits = merge_hits([ev(0, 7, 100, src=5, mx=1000), ev(100, 7, 100, src=6)], 1000)
    assert len(hits) == 2


def test_buffs_are_parsed():
    hits = merge_hits([ev(0, 7, 100, mx=1000, buffs="104773.108416.")], 1000)
    assert hits[0]["buffs"] == {104773, 108416}


def test_press_anchor_picks_largest_hit_in_window():
    hits = merge_hits([ev(1000, 7, 200, mx=1000), ev(3000, 8, 600), ev(9500, 9, 900)], 1000)
    anchors = press_anchors(hits, [(500, 104773)], 8000)
    assert anchors == [(104773, 8, 60.0, 2.5)]


def test_press_with_no_hit_has_no_anchor():
    assert press_anchors([], [(0, 104773)], 8000) == []


def test_verdict_thresholds():
    assert verdict(65, 0, 0) == "BIG"
    assert verdict(40, 0, 3) == "BIG"
    assert verdict(45, 0, 0) == "SMALL"
    assert verdict(10, 3, 0) == "SMALL"
    assert verdict(29.9, 2, 2) is None


def test_percentile_nearest_rank():
    assert percentile([], 0.9) == 0.0
    assert percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9) == 10
```

- [ ] **Step 2: Run tests to verify they fail**

Run (in `CastAheadTools`): `python -m pytest -q test_defensives.py`
Expected: FAIL with `ModuleNotFoundError: No module named 'defensives'`

- [ ] **Step 3: Write the implementation**

```python
"""Pure helpers for the defensive-call pipeline: hit merging, press anchors, verdicts."""
from statistics import median


def percentile(values, q):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * q))]


def merge_hits(events, max_hp_default):
    known = [e["maxHitPoints"] for e in events if e.get("maxHitPoints")]
    current = median(known) if known else max_hp_default
    merged, open_ = [], {}
    for e in events:
        if e.get("maxHitPoints"):
            current = e["maxHitPoints"]
        if e["sourceID"] == e["targetID"]:
            continue
        key = (e["sourceID"], e.get("sourceInstance"), e["abilityGameID"])
        taken = e.get("amount", 0) + e.get("absorbed", 0)
        g = open_.get(key)
        t = e["timestamp"]
        if g and t - g["t1"] <= 1500 and t - g["t"] <= 3000:
            g["taken"] += taken
            g["t1"] = t
            continue
        g = {"t": t, "t1": t, "sid": e["abilityGameID"], "src": e["sourceID"], "taken": taken, "max": current,
             "buffs": {int(b) for b in e.get("buffs", "").split(".") if b}}
        open_[key] = g
        merged.append(g)
    for g in merged:
        g["pct"] = round(g["taken"] / g["max"] * 100, 1)
        del g["t1"]
    return merged


def press_anchors(hits, presses, window_ms):
    out = []
    for t, spell in presses:
        inside = [h for h in hits if t <= h["t"] <= t + window_ms]
        if inside:
            top = max(inside, key=lambda h: h["pct"])
            out.append((spell, top["sid"], top["pct"], round((top["t"] - t) / 1000, 1)))
    return out


def verdict(p90, small_answers, big_answers):
    if big_answers >= 3 or p90 >= 60:
        return "BIG"
    if small_answers >= 3 or p90 >= 30:
        return "SMALL"
    return None
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest -q test_defensives.py`
Expected: `9 passed`

- [ ] **Step 5: No commit** - `CastAheadTools` is not a git repository. Note the new files in the Task 11 summary.

---

### Task 2: Harvest 9 specs from Warcraft Logs

**Files:**
- Create: `CastAheadTools/def_harvest.py`

**Interfaces:**
- Consumes: `wcl.Client` (`CastAheadTools/wcl.py:54-93`; `gql(query, variables)` returns `data`, sleeps on rate limits; every query must select `rateLimitData { limitPerHour pointsSpentThisHour pointsResetIn }` or `Client.gql` raises `KeyError: 'limitPerHour'`).
- Produces: one JSON file per run at `F:/claude-data/castahead-defensives/wcl/<class>-<spec>/<code>_<fight>_<player>.json` with keys `dungeon, spec, role, player, level, start, end, pulls, names, abil, dmg, casts`, where `casts` is every `type == "cast"` event of the player reduced to `{"timestamp", "abilityGameID"}`, and `pulls` is `dungeonPulls { encounterID name startTime endTime }`.

Facts this task relies on (verified 2026-10-07 in the warlock spike): zone 55 encounter ids `12993 Altar of Fangs, 12825 Den of Nalorakk, 61762 Kings' Rest, 12813 Murder Row, 112521 Ruby Life Pools, 61877 Temple of Sethraliss, 12859 The Blinding Vale, 12923 Voidscar Arena`; `characterRankings(className, specName, bracket: 17)` returns +18 keys; some rankings have `report.fightID == null` and must be skipped; for `dataType: DamageTaken` the damaged player is `sourceID`; about 4 points per run.

- [ ] **Step 1: Write the harvester**

```python
"""Harvest top-player damage taken and casts per spec from Warcraft Logs (private tooling).

    python def_harvest.py F:/claude-data/castahead-defensives/wcl --per-spec 5
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wcl import Client  # noqa: E402

DUNGEONS = {12993: "Altar of Fangs", 12825: "Den of Nalorakk", 61762: "Kings' Rest", 12813: "Murder Row",
            112521: "Ruby Life Pools", 61877: "Temple of Sethraliss", 12859: "The Blinding Vale",
            12923: "Voidscar Arena"}
SPECS = [("Warlock", "Affliction", "DAMAGER"), ("Warlock", "Demonology", "DAMAGER"),
         ("Warlock", "Destruction", "DAMAGER"), ("Paladin", "Holy", "HEALER"),
         ("Paladin", "Protection", "TANK"), ("Paladin", "Retribution", "DAMAGER"),
         ("DemonHunter", "Havoc", "DAMAGER"), ("DemonHunter", "Vengeance", "TANK"),
         ("DemonHunter", "Devourer", "DAMAGER")]
RL = "rateLimitData { limitPerHour pointsSpentThisHour pointsResetIn }"
RANKS = '{ %s worldData { encounter(id: %%d) { characterRankings(className: "%%s", specName: "%%s", bracket: 17) } } }' % RL
META = """query($c:String!,$f:[Int]!){ %s reportData { report(code:$c) {
  masterData { actors { id name type } abilities { gameID name } }
  fights(fightIDs:$f) { id startTime endTime keystoneLevel dungeonPulls { encounterID name startTime endTime } } } } }""" % RL
EV = """query($c:String!,$f:Int!,$p:Int!,$s:Float!,$e:Float!){ %s reportData { report(code:$c) {
  events(fightIDs:[$f], dataType:%%s, sourceID:$p, includeResources:true, startTime:$s, endTime:$e, limit:10000)
  { data nextPageTimestamp } } } }""" % RL


def paged(client, dtype, v):
    out, start = [], v["s"]
    while start:
        page = client.gql(EV % dtype, dict(v, s=start))["reportData"]["report"]["events"]
        out.extend(page["data"])
        start = page["nextPageTimestamp"]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--per-spec", type=int, default=5)
    args = ap.parse_args()
    client = Client()
    for cls, spec, role in SPECS:
        folder = os.path.join(args.out, "%s-%s" % (cls, spec))
        os.makedirs(folder, exist_ok=True)
        for enc, dname in DUNGEONS.items():
            ranks = client.gql(RANKS % (enc, cls, spec))["worldData"]["encounter"]["characterRankings"]["rankings"]
            ranks = [r for r in ranks if r["report"].get("fightID")][:args.per_spec]
            for rk in ranks:
                code, fid, name = rk["report"]["code"], rk["report"]["fightID"], rk["name"]
                path = os.path.join(folder, "%s_%d_%s.json" % (code, fid, name))
                if os.path.exists(path):
                    continue
                try:
                    rep = client.gql(META, {"c": code, "f": [fid]})["reportData"]["report"]
                    pid = next(a["id"] for a in rep["masterData"]["actors"]
                               if a["name"] == name and a["type"] == "Player")
                    f = rep["fights"][0]
                    v = {"c": code, "f": fid, "p": pid, "s": f["startTime"], "e": f["endTime"]}
                    dmg = paged(client, "DamageTaken", v)
                    casts = [{"timestamp": e["timestamp"], "abilityGameID": e["abilityGameID"]}
                             for e in paged(client, "Casts", v) if e["type"] == "cast"]
                except Exception as ex:  # one broken report must not stop a 360-run harvest
                    sys.stderr.write("skip %s %s: %s\n" % (code, name, ex))
                    continue
                json.dump({"dungeon": dname, "spec": spec, "role": role, "player": name,
                           "level": f["keystoneLevel"], "start": f["startTime"], "end": f["endTime"],
                           "pulls": f["dungeonPulls"],
                           "names": {a["id"]: a["name"] for a in rep["masterData"]["actors"]},
                           "abil": {a["gameID"]: a["name"] for a in rep["masterData"]["abilities"]},
                           "dmg": dmg, "casts": casts}, open(path, "w", encoding="utf-8"))
                print(cls, spec, dname, name, f["keystoneLevel"], "points", client.points, flush=True)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Add debuffs to the harvest.** The 120 warlock runs from the 2026-10-07 spike (`F:/claude-data/warlock-defensives/wcl/`) kept only five defensive cast ids, so they are not reused; the harvester refetches Warlock. Debuffs on the player are needed for the aura flag (Task 4). Which id filters a friendly target's debuffs is not verified: probe one run (`FAgLZ6QprJHy7bGd`, fight 2, player `Fealth`) with `dataType: Debuffs` once with `sourceID: $p` and once with `targetID: $p`, and keep the form whose `applydebuff` events have `targetID == pid`. Then add to the per-run fetch:

```python
                    debuffs = [{"timestamp": e["timestamp"], "abilityGameID": e["abilityGameID"]}
                               for e in paged(client, "Debuffs", v) if e["type"] == "applydebuff"
                               and e.get("targetID") == pid]
```

and store it as `"debuffs": debuffs` in the run file (if the probe shows `targetID` is the filter, give `EV` a `targetID:$p` variant for this one call).

- [ ] **Step 3: Run the harvest in the background**

Run (in `CastAheadTools`): `python def_harvest.py F:/claude-data/castahead-defensives/wcl --per-spec 5`
Expected: about 360 lines `<class> <spec> <dungeon> <name> 18 points <n>`, under 3600 points in total; rerunning skips finished files.

- [ ] **Step 4: Verify counts**

Run: `python -c "import glob,collections;print(collections.Counter(p.split('\\\\')[-2] for p in glob.glob('F:/claude-data/castahead-defensives/wcl/*/*.json')))"`
Expected: 9 folders, each with 30-40 files (fewer only where WCL has fewer +18 rankings; note those specs in the Task 3 report).

---

### Task 3: Button candidates report and the owner's pick (OWNER GATE)

**Files:**
- Create: `CastAheadTools/def_candidates.py`
- Create: `CastAhead/SaveButtons.lua` (after the owner answers)
- Test: `CastAheadTools/test_defensives.py` (add `rank_candidates` cases)

**Interfaces:**
- Consumes: `merge_hits`, `press_anchors`, `percentile` (Task 1); run files (Task 2).
- Produces:
  - `defensives.rank_candidates(runs) -> list[dict]` with `{"spell": int, "runs": int, "presses": int, "big_share": float, "med_pct": float}` sorted by `big_share * runs` descending, where `big_share` is the share of presses whose 8 s anchor hit is >= 30% HP. Spells pressed in fewer than a third of the runs are dropped.
  - `CastAheadSaveButtons = { [specID] = { small = { spellID, ... }, big = { spellID, ... } } }` (first known spell in each list is the one shown).

- [ ] **Step 1: Write the failing test**

```python
from defensives import rank_candidates


def run_with(presses, hits):
    return {"dmg": [{"timestamp": t, "sourceID": 5, "targetID": 1, "abilityGameID": 7, "amount": a,
                     "maxHitPoints": 1000} for t, a in hits],
            "casts": [{"timestamp": t, "abilityGameID": s} for t, s in presses]}


def test_rank_candidates_prefers_spells_pressed_before_big_hits():
    runs = [run_with([(0, 111), (20000, 222)], [(2000, 700), (21000, 50)]) for _ in range(3)]
    ranked = rank_candidates(runs)
    assert ranked[0]["spell"] == 111 and ranked[0]["big_share"] == 1.0
    assert ranked[1]["spell"] == 222 and ranked[1]["big_share"] == 0.0


def test_rank_candidates_drops_rare_spells():
    runs = [run_with([(0, 111)], [(1000, 700)])] + [run_with([], [(1000, 700)]) for _ in range(5)]
    assert rank_candidates(runs) == []
```

- [ ] **Step 2: Run to verify failure**

Run: `python -m pytest -q test_defensives.py -k rank`
Expected: FAIL with `ImportError: cannot import name 'rank_candidates'`

- [ ] **Step 3: Implement `rank_candidates` in `defensives.py`**

```python
def rank_candidates(runs):
    stats = {}
    for i, run in enumerate(runs):
        hits = merge_hits(run["dmg"], 1)
        presses = [(c["timestamp"], c["abilityGameID"]) for c in run["casts"]]
        for spell, _, pct, _ in press_anchors(hits, presses, 8000):
            s = stats.setdefault(spell, {"runs": set(), "presses": 0, "big": 0, "pcts": []})
            s["big"] += pct >= 30
            s["pcts"].append(pct)
        for t, spell in presses:
            s = stats.setdefault(spell, {"runs": set(), "presses": 0, "big": 0, "pcts": []})
            s["runs"].add(i)
            s["presses"] += 1
    out = []
    for spell, s in stats.items():
        if len(s["runs"]) * 3 < len(runs) or not s["presses"]:
            continue
        out.append({"spell": spell, "runs": len(s["runs"]), "presses": s["presses"],
                    "big_share": round(s["big"] / s["presses"], 2),
                    "med_pct": percentile(s["pcts"], 0.5)})
    out.sort(key=lambda r: -r["big_share"] * r["runs"])
    return out
```
- [ ] **Step 4: Run tests** - `python -m pytest -q test_defensives.py` - Expected: all pass.

- [ ] **Step 5: Write `def_candidates.py`** that loads every run per spec folder, calls `rank_candidates`, keeps the top 12, resolves names from the runs' `abil` maps, and writes `F:/claude-data/castahead-defensives/candidates.md`: one table per spec with spell, name, runs, presses, big_share, med_pct. Cross-check each list against Blizzard's per-spec list in `G:/Games/wow-ui-source-live/Interface/AddOns/Blizzard_CooldownBroadcaster/TrackedCooldowns.lua` and mark rows that appear there. Rotation spells will rank (a press before a big hit happens by accident); `big_share` near the spec's average marks them.

- [ ] **Step 6: OWNER GATE.** Show the owner the 9 tables (link `claude-data/castahead-defensives/candidates.md`), propose one small and one big list per spec with the evidence, ask via `AskUserQuestion` per class (3 questions), and write only what the owner confirms.

- [ ] **Step 7: Verify spec ids for Warlock and Paladin** in `DBM-Core/Libs/LibSpecialization/LibSpecialization.lua` (same table as lines 71-73) and write `SaveButtons.lua`:

```lua
-- Shipped defensive buttons per specialization. Each list is tried in order and the first spell
-- the character knows is the one shown; the owner confirmed these from top-player presses (2026-10).
CastAheadSaveButtons = {
    [265] = { small = { 108416 }, big = { 104773 } },
}
```

(The one row above is the warlock spike result - Dark Pact small, Unending Resolve big; replace and extend with the owner's confirmed lists for all 9 specs.)

- [ ] **Step 8: Commit** `SaveButtons.lua` with `git commit -m "feat: shipped defensive buttons for warlock, paladin and demon hunter"` and push.

---

### Task 4: Verdict table, boss aliases and boss coverage (OWNER GATE on coverage)

**Files:**
- Create: `CastAheadTools/def_build.py`
- Create: `CastAhead/Defensives.lua` (generated)
- Test: `CastAheadTools/test_defensives.py` (add `build_table` and `dbm_timer_ids` cases)

**Interfaces:**
- Consumes: Task 1 helpers, Task 2 runs, `CastAheadSaveButtons` lists (parsed from `SaveButtons.lua` with a regex on `small = { ... }` / `big = { ... }`).
- Produces:
  - `defensives.build_table(runs_by_role, buttons) -> dict[int, dict]`: per spell id `{"DAMAGER": "BIG"|"SMALL", "TANK": ..., "HEALER": ..., "lead": float, "aura": bool}`; roles without a verdict are omitted; spells with no role verdict are dropped. A spell counts for a role only when it hit players of that role in at least half the role's runs of that dungeon (`runShare >= 0.5`, the spike's rule against avoidable damage). `lead` is the median anchor lead over all roles' big and small presses, else 3.0. `aura` is true when the same spell id appears as an aura applied to the player (`buffs` field never shows debuffs - take it from a `Debuffs` query instead: see Step 3).
  - `defensives.dbm_timer_ids(lua_source) -> set[int]`: spell ids of non-commented `mod:New...Timer(<id>` lines.
  - `Defensives.lua`: `CastAheadDefensives = { spells = { [id] = { DAMAGER = "BIG", lead = 2.5, aura = true }, ... }, alias = { [modId] = logId, ... } }`.

- [ ] **Step 1: Write the failing tests**

```python
from defensives import build_table, dbm_timer_ids


def test_dbm_timer_ids_skip_comments():
    src = 'local a = mod:NewCDTimer(1299680, nil)\n--local b = mod:NewNextTimer(1, nil)\n  local c = mod:NewCastTimer(42)\n'
    assert dbm_timer_ids(src) == {1299680, 42}


def run(role, hits, presses=()):
    return {"role": role, "dungeon": "D",
            "dmg": [{"timestamp": t, "sourceID": 5, "targetID": 1, "abilityGameID": sid, "amount": a,
                     "maxHitPoints": 1000} for t, sid, a in hits],
            "casts": [{"timestamp": t, "abilityGameID": s} for t, s in presses], "debuffs": []}


def test_build_table_gives_role_verdicts_and_lead():
    runs = [run("DAMAGER", [(3000, 7, 700)], [(500, 104773)]) for _ in range(4)]
    table = build_table(runs, {"small": {108416}, "big": {104773}})
    assert table[7]["DAMAGER"] == "BIG" and table[7]["lead"] == 2.5 and "TANK" not in table[7]


def test_build_table_drops_hits_most_runs_avoid():
    runs = [run("DAMAGER", [(3000, 7, 900)])] + [run("DAMAGER", []) for _ in range(3)]
    assert 7 not in build_table(runs, {"small": set(), "big": set()})
```

- [ ] **Step 2: Run to verify failure** - `python -m pytest -q test_defensives.py -k "build or dbm"` - Expected: ImportError.

- [ ] **Step 3: Implement** in `defensives.py`:

```python
import re

TIMER = re.compile(r"^\s*local\s+\w+\s*=\s*mod:New\w*Timer\((\d+)", re.M)


def dbm_timer_ids(lua_source):
    return {int(m) for m in TIMER.findall(lua_source)}


def build_table(runs, buttons):
    per = {}
    counts = {}
    for run in runs:
        key_runs = (run["role"], run["dungeon"])
        counts[key_runs] = counts.get(key_runs, 0) + 1
        hits = merge_hits(run["dmg"], 1)
        seen = set()
        for h in hits:
            s = per.setdefault((h["sid"], run["role"], run["dungeon"]),
                               {"pcts": [], "runs": 0, "small": 0, "big": 0, "leads": []})
            s["pcts"].append(h["pct"])
            if h["sid"] not in seen:
                s["runs"] += 1
                seen.add(h["sid"])
        presses = [(c["timestamp"], c["abilityGameID"]) for c in run["casts"]
                   if c["abilityGameID"] in buttons["small"] | buttons["big"]]
        for spell, sid, pct, lead in press_anchors(hits, presses, 8000):
            s = per[(sid, run["role"], run["dungeon"])]
            s["big" if spell in buttons["big"] else "small"] += 1
            s["leads"].append(lead)
    table = {}
    for (sid, role, dungeon), s in per.items():
        if s["runs"] * 2 < counts[(role, dungeon)]:
            continue
        v = verdict(percentile(s["pcts"], 0.9), s["small"], s["big"])
        if not v:
            continue
        row = table.setdefault(sid, {"leads": []})
        row[role] = "BIG" if row.get(role) == "BIG" else v
        row["leads"] += s["leads"]
    for sid, row in table.items():
        leads = row.pop("leads")
        row["lead"] = percentile(leads, 0.5) if leads else 3.0
        row["aura"] = False
    return table
```

Then in `build_table`, after the loop that sets `row["aura"] = False`, set `row["aura"] = True` for every table spell id that appears in any run's `debuffs` (harvested in Task 2 Step 2). Add a test: a run whose `debuffs` holds `[{"timestamp": 0, "abilityGameID": 7}]` yields `table[7]["aura"] is True`.

- [ ] **Step 4: Run tests** - Expected: all pass.

- [ ] **Step 5: Write `def_build.py`**: loads all runs, reads `SaveButtons.lua`, builds a per-role button union (small/big ids over the role's specs), calls `build_table`, builds `alias` by joining DBM timer variable names to log spell names exactly like the MRT pipeline did (`timerSeverCD` -> "Sever" against the runs' `abil` names; ids under 1000 are stage numbers and dropped), and writes `CastAhead/Defensives.lua` sorted by spell id, one row per line, with the header line `-- Generated by CastAheadTools/def_build.py from Warcraft Logs top-player runs; do not edit.`

- [ ] **Step 6: Coverage report**: for each boss spell in the table (a hit inside a pull with an `encounterID`), check whether its id or an alias is in `dbm_timer_ids` of the DBM module files of the 8 dungeons (`DBM-Party-Midnight/{AltarofFangs,DenofNalorakk,MurderRow,TheBlindingVale,VoidscarArena}/*.lua`, plus the BfA and Dragonflight party folders for Kings' Rest, Temple of Sethraliss and Ruby Life Pools). Write `F:/claude-data/castahead-defensives/boss-coverage.md`: per boss, covered / uncovered verdict spells.

- [ ] **Step 7: OWNER GATE.** If fewer than 70% of boss verdict spells are covered, stop and show the owner the report with the alternative the earlier MRT work proved: from-pull schedules (`ENCOUNTER_START` + measured times, `mrt-s2-reminder-packs` memory: dungeon schedules held +-0.0 s over 90 fights). Continue with Task 5 either way; Task 9 waits for the decision.

- [ ] **Step 8: Commit** `Defensives.lua` and add it to `CastAhead.toc` after `Priority.lua`; `git commit -m "feat: defensive verdict table from top-player runs"`; push.

---

### Task 5: SMALL / BIG advice in Match

**Files:**
- Modify: `Match.lua:35-87` (ADVICE), `Match.lua:104-135` (`Advice`), `Match.lua:339-355` (role hooks, `Important`)
- Test: `test.lua` (new cases before the final summary line)

**Interfaces:**
- Consumes: `row.save` (a `CastAheadDefensives.spells` entry, attached in Task 7).
- Produces:
  - `M.ADVICE.SMALL = { label = "SMALL SAVE", short = "SMALL", say = "small defensive", ... }`, `M.ADVICE.BIG = { label = "BIG SAVE", short = "BIG", say = "big defensive", ... }`, keys `SMALL` / `BIG`, files `SMALL` / `BIG`.
  - `M.SpecRole = function() return nil end` - Core replaces it with the real role, ignoring the role filter.
  - `M.SaveAdvice(row) -> advice | nil`.
  - `M.IsSave(advice) -> boolean`.
  - `M.Advice(row, interruptible)` returns the save advice unless the base advice is `KICK` or `CC`.
  - `M.Important(row)` is true for a row with a save advice for the player's role.

- [ ] **Step 1: Write the failing tests** (append to `test.lua` before `print`/`os.exit`):

```lua
-- Save verdicts: the player's real role picks the verdict, a kick still wins.
M.SpecRole = function() return "DAMAGER" end
local saveRow = { spell = 900, cast = 2.0, save = { DAMAGER = "BIG", TANK = "SMALL", lead = 2.5 }, hits = 5, dmg = 0.6 }
check(M.Advice(saveRow) == M.ADVICE.BIG, "a dps gets BIG where the table says BIG for dps")
check(M.Advice(saveRow) ~= M.ADVICE.AOE, "and BIG replaces the AOE the statistics would give")
M.SpecRole = function() return "HEALER" end
check(M.Advice(saveRow) == M.ADVICE.AOE, "a healer with no verdict keeps the old call")
M.SpecRole = function() return "TANK" end
check(M.Advice(saveRow) == M.ADVICE.SMALL, "a tank gets the tank verdict")
local kickRow = { spell = 901, cast = 2.0, kickable = true, save = { TANK = "BIG" } }
check(M.Advice(kickRow) == M.ADVICE.KICK, "a kickable cast still says interrupt")
check(M.Advice({ spell = 902, prio = "KICK", save = { TANK = "BIG" } }) == M.ADVICE.KICK, "a curated kick still wins")
check(M.Advice({ spell = 903, prio = "DODGE", save = { TANK = "BIG" } }) == M.ADVICE.BIG, "BIG outranks a curated dodge")
check(M.IsSave(M.ADVICE.BIG) and M.IsSave(M.ADVICE.SMALL) and not M.IsSave(M.ADVICE.AOE), "IsSave names the two save calls")
local savedPlayerRole = M.PlayerRole
M.PlayerRole = function() return nil end
check(M.Important({ spell = 904, save = { TANK = "SMALL" } }), "a save row is important even with the role filter off")
M.PlayerRole = savedPlayerRole
M.SpecRole = function() return nil end
check(M.Advice(saveRow) == M.ADVICE.AOE, "outside the game no role means no save call")
```

- [ ] **Step 2: Run to verify failure**

Run: `MSYS_NO_PATHCONV=1 wsl bash -lc 'cd "/mnt/g/Games/World of Warcraft/_retail_/Interface/AddOns/CastAhead" && ~/luaenv/bin/lua test.lua | tail -5'`
Expected: FAIL lines starting `FAIL: a dps gets BIG`; the clip check also fails for `Sounds/en/SMALL.ogg` once the ADVICE entries exist (fixed in Task 6).

- [ ] **Step 3: Implement** - in `M.ADVICE` after `TANK`/`AOE`:

```lua
    SMALL = { label = "SMALL SAVE", short = "SMALL", say = "small defensive", r = 0.55, g = 0.85, b = 1.00 },
    BIG   = { label = "BIG SAVE", short = "BIG", say = "big defensive", r = 1.00, g = 0.35, b = 0.85 },
```

Rename the current `function M.Advice(row, interruptible)` body to `local function BaseAdvice(row, interruptible)` and add after it:

```lua
M.SpecRole = function() return nil end

function M.SaveAdvice(row)
    local save = row and row.save
    local role = save and M.SpecRole()
    local key = role and save[role]
    return key and M.ADVICE[key] or nil
end

function M.IsSave(advice)
    return advice == M.ADVICE.SMALL or advice == M.ADVICE.BIG
end

function M.Advice(row, interruptible)
    if not row then return nil end
    local base = BaseAdvice(row, interruptible)
    if base == M.ADVICE.KICK or base == M.ADVICE.CC then return base end
    return M.SaveAdvice(row) or base
end
```

`BaseAdvice` must be declared above `M.Advice`; keep its first line `if not row then return nil end`. In `M.Important` add as the first line: `if M.SaveAdvice(row) then return true end`.

- [ ] **Step 4: Run tests** - same command; Expected: only the two clip failures for `SMALL`/`BIG` remain.

- [ ] **Step 5: Commit** `git add Match.lua test.lua && git commit -m "feat: small and big defensive verdicts in the matcher"` and push.

---

### Task 6: Voice clips

**Files:**
- Modify: `tools/voice.py:29-47` (`LINES`)
- Create: `Sounds/en/SMALL.ogg`, `Sounds/en/SMALL_soon.ogg`, `Sounds/en/BIG.ogg`, `Sounds/en/BIG_soon.ogg`

- [ ] **Step 1: Add the lines** to `LINES`: `"SMALL": "small defensive",` and `"BIG": "big defensive",`.
- [ ] **Step 2: Render** - `python tools/voice.py` (credentials `AZURE_SPEECH_KEY` / `AZURE_SPEECH_REGION` by name from the user environment, never printed; ffmpeg on PATH). Expected: four new files listed.
- [ ] **Step 3: Run `test.lua`** - Expected: `OK`.
- [ ] **Step 4: Commit** `git add tools/voice.py Sounds/en/SMALL*.ogg Sounds/en/BIG*.ogg && git commit -m "feat: voice clips for small and big defensive"`; push.

---

### Task 7: Saves module, Core wiring for trash calls

**Files:**
- Create: `Saves.lua`
- Modify: `CastAhead.toc` (add `SaveButtons.lua` and `Defensives.lua` after `Priority.lua` if not already there, `Saves.lua` after `Match.lua`)
- Modify: `Core.lua:96-100` (`MergeCuration` attaches `row.save`), `Core.lua:278-283` (set `CastAheadMatch.SpecRole`), `Core.lua:479-486` (`PlayAdviceSound` lets a save call through with lead 0), `Core.lua:2412-2445` (`CenterPick` adds pending save calls and icons), `Core.lua:2467` (icon), `Core.lua:2529-2537` (heads-up lead for saves), the event handler's `PLAYER_SPECIALIZATION_CHANGED` / `SPELLS_CHANGED` branch (call `CastAheadSaves.Refresh()`), and after `CastAheadCore = {}` (export `CastAheadCore.Announce = PlayAdviceSound`)
- Test: `test_core.lua` (load `Saves.lua` after `Match.lua`; new cases before the final `print`)

**Interfaces:**
- Consumes: `CastAheadMatch.IsSave`, `CastAheadMatch.SaveAdvice`, `CastAheadSaveButtons`, `CastAheadDefensives`.
- Produces:
  - `CastAheadSaves.SpecID() -> number | nil` (`GetSpecializationInfo(GetSpecialization())`).
  - `CastAheadSaves.Button(size) -> spellID | nil` where `size` is `"small"` or `"big"`: the override `CastAheadDB.saveButtons[specID][size]` if set and known (`IsPlayerSpell`), else the first known id in `CastAheadSaveButtons[specID][size]`.
  - `CastAheadSaves.Icon(advice) -> texture | nil`: `C_Spell.GetSpellTexture(Button(...))` for a save advice, else nil.
  - `CastAheadSaves.Lead(spellID) -> number | nil`: `CastAheadDefensives.spells[id].lead`.
  - `CastAheadSaves.Schedule(key, spellID, fireAt, endAt, advice)`, `Cancel(key)`, `CancelPrefix(prefix)`, `Pause(key, now)`, `Resume(key, now)`, `Pending(now) -> array of { endAt, advice, row = { spell = id }, icon }`, `Tick(now)` (fires due calls through `CastAheadCore.Announce(advice, true)` once each).
  - `CastAheadSaves.Refresh()` (re-reads spec, re-registers aura sounds - the aura part lands in Task 8; here it only clears the icon cache).
  - `CastAheadCore.Announce(advice, lead, candidates)`.

- [ ] **Step 1: Write the failing tests** (append to `test_core.lua`; the harness helpers `enter()`, `castFor(seconds)`, `advance(seconds)`, `reset()`, `Alerts()` already exist):

```lua
-- Save calls on trash: the dps verdict replaces AOE, the centre shows the player's button.
local specRole2 = "DAMAGER"
GetSpecialization = function() return 1 end
GetSpecializationRole = function() return specRole2 end
GetSpecializationInfo = function() return 265 end
IsPlayerSpell = function(id) return id == 104773 or id == 108416 end
textures[104773] = 2001
textures[108416] = 2002
CastAheadSaveButtons = { [265] = { small = { 108416 }, big = { 104773 } } }
CastAheadDefensives = { spells = { [100] = { DAMAGER = "BIG", lead = 4.0 } }, alias = {} }
CastAheadSaves.Refresh()
CastAheadDB = { centerText = true }
check(CastAheadSaves.Button("big") == 104773, "the shipped big button for the spec")
check(CastAheadSaves.Icon(CastAheadMatch.ADVICE.BIG) == 2001, "its icon")
CastAheadDB.saveButtons = { [265] = { big = 108416 } }
check(CastAheadSaves.Button("big") == 108416, "an override wins")
CastAheadDB.saveButtons = { [265] = { big = 999 } }
check(CastAheadSaves.Button("big") == 104773, "an override the character does not know falls back")
CastAheadDB.saveButtons = nil
GetSpecializationInfo = function() return 70 end
CastAheadSaves.Refresh()
check(CastAheadSaves.Button("big") == nil, "a spec without a table has no button")
GetSpecializationInfo = function() return 265 end
CastAheadSaves.Refresh()
```

```lua
-- Heads-up for a save call fires at the row's own lead even with the global lead off.
reset()
CastAheadDB = { centerText = true, leadSeconds = 0 }
CastAheadCore.ReapplyData()
enter()
castFor(3.0)                  -- spell 100 identified, next one in 20 s
sounds, spoken, clips = 0, 0, 0
advance(15.0)                 -- 5 s before the next cast: nothing yet
check(Alerts() == 0, "no heads-up before the save lead")
advance(1.5)                  -- 3.5 s before: inside lead 4.0
check(Alerts() == 1, string.format("one save heads-up inside the lead, got %d", Alerts()))
reset()
```

```lua
-- A scheduled save call fires once at its time and shows in the centre until it ends.
reset()
CastAheadDB = { centerText = true }
enter()
CastAheadSaves.Schedule("test:1", 100, now + 2, now + 5, CastAheadMatch.ADVICE.BIG)
sounds, spoken, clips = 0, 0, 0
advance(1.0)
check(Alerts() == 0, "a scheduled call is quiet before its time")
advance(1.5)
check(Alerts() == 1, "and speaks once at its time")
advance(1.0)
check(Alerts() == 1, "only once")
check(#CastAheadSaves.Pending(now) == 1, "it stays in the centre until the hit")
advance(2.0)
check(#CastAheadSaves.Pending(now) == 0, "and leaves after it")
CastAheadSaves.Schedule("test:2", 100, now + 2, now + 5, CastAheadMatch.ADVICE.BIG)
CastAheadSaves.Cancel("test:2")
sounds, spoken, clips = 0, 0, 0
advance(3.0)
check(Alerts() == 0, "a cancelled call never fires")
reset()
GetSpecialization, GetSpecializationRole, GetSpecializationInfo, IsPlayerSpell = nil, nil, nil, nil
```

Core runs `MergeCuration` once (`extrasMerged`), so the test needs `CastAheadCore.ReapplyData`, added in Step 4. Spell 100 in the fixture is curated `AOE` (`test_core.lua:256`); with the dps verdict above its call becomes `BIG`. Its cooldown is 20 s (`test_core.lua:228`); adjust the two `advance` values if the harness's identification timing differs, keeping one check before and one inside the 4.0 s lead.

- [ ] **Step 2: Run to verify failure** - `MSYS_NO_PATHCONV=1 wsl bash -lc 'cd "/mnt/g/Games/World of Warcraft/_retail_/Interface/AddOns/CastAhead" && ~/luaenv/bin/lua test_core.lua | tail -5'` - Expected: error `attempt to index global 'CastAheadSaves' (a nil value)`.

- [ ] **Step 3: Write `Saves.lua`**

```lua
CastAheadSaves = {}
local S = CastAheadSaves
local M = CastAheadMatch

local scheduled = {}
local iconCache = {}

function S.SpecID()
    if not (GetSpecialization and GetSpecializationInfo) then return nil end
    local index = GetSpecialization()
    return index and GetSpecializationInfo(index) or nil
end

local function Known(id)
    return type(id) == "number" and IsPlayerSpell and IsPlayerSpell(id)
end

function S.Button(size)
    local spec = S.SpecID()
    if not spec then return nil end
    local picks = CastAheadDB and CastAheadDB.saveButtons and CastAheadDB.saveButtons[spec]
    local pick = picks and picks[size]
    if Known(pick) then return pick end
    local shipped = CastAheadSaveButtons and CastAheadSaveButtons[spec]
    for _, id in ipairs(shipped and shipped[size] or {}) do
        if Known(id) then return id end
    end
    return nil
end

function S.Icon(advice)
    if not M.IsSave(advice) then return nil end
    local size = advice == M.ADVICE.BIG and "big" or "small"
    if iconCache[size] == nil then
        local id = S.Button(size)
        iconCache[size] = id and C_Spell and C_Spell.GetSpellTexture(id) or false
    end
    return iconCache[size] or nil
end

function S.Lead(spellID)
    local row = CastAheadDefensives and CastAheadDefensives.spells[spellID]
    return row and row.lead or nil
end

function S.Refresh()
    wipe(iconCache)
end

function S.Schedule(key, spellID, fireAt, endAt, advice)
    scheduled[key] = { spell = spellID, fireAt = fireAt, endAt = endAt, advice = advice }
end

function S.Cancel(key)
    scheduled[key] = nil
end

function S.CancelPrefix(prefix)
    for key in pairs(scheduled) do
        if key:sub(1, #prefix) == prefix then scheduled[key] = nil end
    end
end

function S.Pause(key, now)
    local c = scheduled[key]
    if c and not c.pausedAt then c.pausedAt = now end
end

function S.Resume(key, now)
    local c = scheduled[key]
    if c and c.pausedAt then
        local held = now - c.pausedAt
        c.fireAt, c.endAt, c.pausedAt = c.fireAt + held, c.endAt + held, nil
    end
end

local pending = {}
function S.Pending(now)
    wipe(pending)
    for _, c in pairs(scheduled) do
        if not c.pausedAt and c.fired and c.endAt > now then
            pending[#pending + 1] = { endAt = c.endAt, advice = c.advice, row = { spell = c.spell },
                                      icon = S.Icon(c.advice) }
        end
    end
    return pending
end

function S.Tick(now)
    for key, c in pairs(scheduled) do
        if not c.pausedAt then
            if not c.fired and now >= c.fireAt then
                c.fired = true
                if CastAheadCore and CastAheadCore.Announce then CastAheadCore.Announce(c.advice, true) end
            end
            if now >= c.endAt then scheduled[key] = nil end
        end
    end
end
```

- [ ] **Step 4: Wire Core**
  - `MergeCuration` loop (`Core.lua:97-100`): add `rows[i].save = CastAheadDefensives and CastAheadDefensives.spells[rows[i].spell] or nil`.
  - After `CastAheadMatch.PlayerRole = ...` (`Core.lua:278-283`):

```lua
CastAheadMatch.SpecRole = function()
    if not (GetSpecialization and GetSpecializationRole) then return nil end
    local spec = GetSpecialization()
    return spec and GetSpecializationRole(spec) or nil
end
```

  - `PlayAdviceSound` (`Core.lua:484`): `if lead and CastAheadConfig.Lead() <= 0 and not CastAheadMatch.IsSave(advice) then return end`.
  - Heads-up (`Core.lua:2529`): replace `local lead = CastAheadConfig.Lead()` with

```lua
                        local heads = CastAheadMatch.ConsensusAdvice(entry.candidates)
                        local lead = CastAheadConfig.Lead()
                        if CastAheadMatch.IsSave(heads) and CastAheadConfig.Enabled("saveCalls") then
                            lead = math.max(lead, CastAheadSaves.Lead(entry.candidates[1].spell) or 3)
                        end
```

    and reuse `heads` in the block below instead of calling `ConsensusAdvice` again.
  - `CenterPick` (`Core.lua:2417-2419`): store `icon = CastAheadSaves.Icon(advice)` in the pick; before the `table.sort`, append every entry of `CastAheadSaves.Pending(now)` when `CastAheadConfig.Enabled("saveCalls")`.
  - `UpdateCenter` (`Core.lua:2467`): `line.icon:SetTexture(pick.icon or SpellIcon(pick.row.spell))`.
  - OnUpdate (`Core.lua:2482`, after `local now = GetTime()`): `CastAheadSaves.Tick(now)`.
  - Event handler, `PLAYER_SPECIALIZATION_CHANGED` and `SPELLS_CHANGED` branch (find with `grep -n "PLAYER_SPECIALIZATION_CHANGED" Core.lua`, next to `InvalidateCapabilities()`): call `CastAheadSaves.Refresh()`.
  - After `CastAheadCore = {}` (`Core.lua:2598`): `CastAheadCore.Announce = PlayAdviceSound` and `CastAheadCore.ReapplyData = function() extrasMerged = false; MergeCuration() end`.
  - `test_core.lua`: `dofile("Saves.lua")` after `dofile("Match.lua")`, and define `CastAheadSaveButtons`, `CastAheadDefensives` as empty tables before the dofiles so existing cases keep their old behaviour.

- [ ] **Step 5: Run both suites** - Expected: `OK` twice. If an older case now hears `BIG` instead of `AOE`, the fixture `CastAheadDefensives` leaked; reset it to `{ spells = {}, alias = {} }` after the new block.

- [ ] **Step 6: Commit** `git add Saves.lua Core.lua CastAhead.toc test_core.lua && git commit -m "feat: save calls on trash with the player's own button"`; push.

---

### Task 8: Aura sounds for debuffs on the player

**Files:**
- Modify: `Saves.lua` (aura registration), `Core.lua` event handler (`PLAYER_ENTERING_WORLD`, `PLAYER_REGEN_ENABLED` call `CastAheadSaves.Refresh()`)
- Test: `test_core.lua`

**Interfaces:**
- Consumes: `CastAheadDefensives.spells[id].aura`, `M.SaveAdvice`.
- Produces: `CastAheadSaves.Refresh()` now also (re)registers aura sounds; `CastAheadSaves.AuraSoundCount() -> number` for tests.

Fact: `C_UnitAuras.AddAuraSound(trigger, { unitToken, spellID, soundFileName, soundFileID, outputChannel }) -> auraSoundID` and `C_UnitAuras.RemoveAuraSound(auraSoundID)` (`Blizzard_APIDocumentationGenerated/UnitAuraDocumentation.lua:11-26,490-498`, `UnitConstantsDocumentation.lua:43-52`); `Enum.UnitAuraSoundTrigger.Added == 0` (`UnitAuraConstantsDocumentation.lua:6-16`).

- [ ] **Step 1: Write the failing test**

```lua
-- Aura sounds: registered for the player's role out of combat only, replaced on spec change.
local added, removed, lockdown, inCombat = {}, {}, false, false
C_UnitAuras.AddAuraSound = function(trigger, info) added[#added + 1] = info.spellID return #added end
C_UnitAuras.RemoveAuraSound = function(id) removed[#removed + 1] = id end
C_ChatInfo = { InChatMessagingLockdown = function() return lockdown end }
InCombatLockdown = function() return inCombat end
Enum.UnitAuraSoundTrigger = { Added = 0 }
GetSpecialization = function() return 1 end
local role3 = "DAMAGER"
GetSpecializationRole = function() return role3 end
GetSpecializationInfo = function() return 265 end
CastAheadDefensives = { spells = { [373693] = { DAMAGER = "BIG", aura = true }, [5] = { TANK = "BIG", aura = true },
                                   [6] = { DAMAGER = "SMALL" } }, alias = {} }
CastAheadDB = {}
inCombat = true
CastAheadSaves.Refresh()
check(#added == 0, "nothing is registered in combat")
inCombat = false
fire("PLAYER_REGEN_ENABLED")
check(#added == 1 and added[1] == 373693, "leaving combat registers the dps aura only")
role3 = "TANK"
fire("PLAYER_SPECIALIZATION_CHANGED", "player")
check(#removed == 1 and added[#added] == 5, "a spec change swaps the registrations")
CastAheadConfig.SetEnabled("saveCalls", false)
CastAheadSaves.Refresh()
check(CastAheadSaves.AuraSoundCount() == 0, "switching save calls off removes them")
CastAheadConfig.SetEnabled("saveCalls", true)
GetSpecialization, GetSpecializationRole, GetSpecializationInfo, InCombatLockdown = nil, nil, nil, nil
CastAheadDefensives = { spells = {}, alias = {} }
```

- [ ] **Step 2: Run to verify failure** - Expected: `FAIL: leaving combat registers the dps aura only`.

- [ ] **Step 3: Implement** in `Saves.lua`:

```lua
local SOUND_ROOT = "Interface\\AddOns\\CastAhead\\Sounds\\en\\"
local auraIDs = {}
local auraPending = false

local function ClearAuraSounds()
    for i = #auraIDs, 1, -1 do
        C_UnitAuras.RemoveAuraSound(auraIDs[i])
        auraIDs[i] = nil
    end
end

local function Blocked()
    return (InCombatLockdown and InCombatLockdown())
        or (C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown())
end

local function RegisterAuraSounds()
    if not (C_UnitAuras and C_UnitAuras.AddAuraSound and Enum and Enum.UnitAuraSoundTrigger) then return end
    if Blocked() then auraPending = true return end
    auraPending = false
    ClearAuraSounds()
    if not CastAheadConfig.Enabled("saveCalls") then return end
    for spellID, row in pairs(CastAheadDefensives and CastAheadDefensives.spells or {}) do
        local advice = row.aura and M.SaveAdvice({ save = row })
        if advice then
            local id = C_UnitAuras.AddAuraSound(Enum.UnitAuraSoundTrigger.Added, {
                unitToken = "player", spellID = spellID,
                soundFileName = SOUND_ROOT .. advice.file .. ".ogg", outputChannel = "Master" })
            if id then auraIDs[#auraIDs + 1] = id end
        end
    end
end

function S.AuraSoundCount() return #auraIDs end
```

Change `S.Refresh` to:

```lua
function S.Refresh()
    wipe(iconCache)
    RegisterAuraSounds()
end
```

Core event handler: `PLAYER_ENTERING_WORLD`, `PLAYER_SPECIALIZATION_CHANGED`, `SPELLS_CHANGED` and `PLAYER_REGEN_ENABLED` call `CastAheadSaves.Refresh()` (the last one is cheap: it only re-registers when `auraPending` or on first run; guard with `if event == "PLAYER_REGEN_ENABLED" and not CastAheadSaves.AuraPending() then` skip - add `function S.AuraPending() return auraPending end`).

- [ ] **Step 4: Run both suites** - Expected: `OK` twice.
- [ ] **Step 5: Commit** `git commit -am "feat: save sound when a dangerous debuff lands on the player"`; push.

---

### Task 9: Boss adapter (DBM and BigWigs)

Starts only after the owner's Task 4 coverage decision. If the owner picks from-pull schedules instead, stop and re-plan this task.

**Files:**
- Create: `BossAdapter.lua`
- Modify: `CastAhead.toc` (after `Saves.lua`), `Core.lua` event handler (`ENCOUNTER_START` / `ENCOUNTER_END` forward to `CastAheadBossAdapter.OnEncounter(event)`)
- Test: `test_core.lua`

**Interfaces:**
- Consumes: `CastAheadSaves.Schedule/Cancel/CancelPrefix/Pause/Resume`, `CastAheadDefensives.alias`, `M.SaveAdvice`.
- Produces:
  - `CastAheadBossAdapter.OnBar(source, barKey, spellID, duration, now)`, `OnStop(source, barKey)`, `OnStopAll(source)`, `OnPause(source, barKey, now)`, `OnResume(source, barKey, now)`, `OnUpdate(source, barKey, elapsed, total, now)`.
  - `CastAheadBossAdapter.Connect()` - registers with DBM (`DBM:RegisterCallback(event, fn)`, handler `fn(event, ...)`, per `DBM-Core/DBM-Nameplate.lua:766,855`) and BigWigs (`BigWigsLoader.RegisterMessage(owner, event, fn)`, handler `fn(event, ...)`, per `MRT/Reminder.lua:19347`); returns `"DBM"`, `"BigWigs"`, `"both"` or `nil`.
  - `CastAheadBossAdapter.Status() -> string`.
  - `CastAheadBossAdapter.OnEncounter(event)` - starts the 30 s health check on `ENCOUNTER_START`, clears on `ENCOUNTER_END`.

Callback arguments (verified):
- `DBM_TimerBegin`: `id, msg, timer, icon, simpType, spellId, colorId, modId, ...` (`Timer.lua:561`).
- `DBM_TimerStop`: `id` (`Timer.lua:760,860`); `DBM_TimerPause` / `DBM_TimerResume`: `id` (`Timer.lua:844,852`). `DBM_TimerUpdate`: `id, elapsed, totalTime` - verify the argument order with `grep -n 'FireEvent("DBM_TimerUpdate"' DBM-Core/modules/objects/Timer.lua` before wiring it; if absent, do not register it.
- `BigWigs_StartBar`: `module, key, text, duration, icon` (`MRT/Reminder.lua:19273`); `BigWigs_StopBar` / `PauseBar` / `ResumeBar`: `module, text`; `BigWigs_StopBars` / `BigWigs_OnBossDisable`: `module`. Bars are identified by `text`.

- [ ] **Step 1: Write the failing tests**

```lua
-- Boss bars: a DBM timer for a spell with a verdict schedules a call at bar end minus lead.
GetSpecialization = function() return 1 end
GetSpecializationRole = function() return "DAMAGER" end
CastAheadDefensives = { spells = { [1299684] = { DAMAGER = "BIG", lead = 3.0 } }, alias = { [1299680] = 1299684 } }
local A = CastAheadBossAdapter
reset()
enter()
sounds, spoken, clips = 0, 0, 0
A.OnBar("dbm", "t1", 1299680, 10, now)
advance(6.5)
check(Alerts() == 0, "quiet until bar end minus lead")
advance(1.0)
check(Alerts() == 1, "one call 3 s before the hit, through the alias")
A.OnBar("dbm", "t2", 1299684, 10, now)
A.OnStop("dbm", "t2")
sounds, spoken, clips = 0, 0, 0
advance(10)
check(Alerts() == 0, "a stopped bar never calls")
A.OnBar("dbm", "t3", 1299684, 10, now)
A.OnPause("dbm", "t3", now)
advance(20)
check(Alerts() == 0, "a paused bar waits")
A.OnResume("dbm", "t3", now)
advance(7.5)
check(Alerts() == 1, "and resumes where it stopped")
A.OnBar("bw", "Sever", "sever_option", 10, now)
A.OnBar("dbm", "t4", nil, 10, now)
A.OnBar("dbm", "t5", 4242, 10, now)
sounds, spoken, clips = 0, 0, 0
advance(12)
check(Alerts() == 0, "string keys, nil ids and spells without a verdict are ignored")
A.OnBar("bw", "Sever", 1299684, 10, now)
A.OnStopAll("bw")
advance(12)
check(Alerts() == 0, "StopBars clears every BigWigs call")
reset()
GetSpecialization, GetSpecializationRole = nil, nil
CastAheadDefensives = { spells = {}, alias = {} }
```

```lua
-- Connect: with a stub DBM the adapter registers and reports it.
local registered = {}
DBM = { RegisterCallback = function(_, event, fn) registered[event] = fn end }
check(CastAheadBossAdapter.Connect() == "DBM", "DBM is detected")
check(registered.DBM_TimerBegin and registered.DBM_TimerStop and registered.DBM_TimerPause and registered.DBM_TimerResume,
    "the four DBM timer callbacks are registered")
DBM = nil
```

- [ ] **Step 2: Run to verify failure** - Expected: `attempt to index local 'A' (a nil value)`.

- [ ] **Step 3: Write `BossAdapter.lua`**

```lua
CastAheadBossAdapter = {}
local A = CastAheadBossAdapter
local M = CastAheadMatch
local connected
local barsSeen, encounterAt = false, nil
local HEALTH_WAIT = 30

local function Key(source, barKey) return source .. ":" .. tostring(barKey) end

function A.OnBar(source, barKey, spellID, duration, now)
    spellID, duration = tonumber(spellID), tonumber(duration)
    if not (spellID and duration) then return end
    barsSeen = true
    local data = CastAheadDefensives
    if not data then return end
    local id = data.alias and data.alias[spellID] or spellID
    local row = data.spells and data.spells[id]
    local advice = row and M.SaveAdvice({ save = row })
    if not advice or not CastAheadConfig.Enabled("saveCalls") or not CastAheadConfig.Enabled("bossAdapter") then return end
    local endAt = now + duration
    CastAheadSaves.Schedule(Key(source, barKey), id, endAt - (row.lead or 3), endAt, advice)
end

function A.OnStop(source, barKey) CastAheadSaves.Cancel(Key(source, barKey)) end
function A.OnStopAll(source) CastAheadSaves.CancelPrefix(source .. ":") end
function A.OnPause(source, barKey, now) CastAheadSaves.Pause(Key(source, barKey), now) end
function A.OnResume(source, barKey, now) CastAheadSaves.Resume(Key(source, barKey), now) end

function A.Connect()
    local dbm, bw
    if DBM and DBM.RegisterCallback then
        DBM:RegisterCallback("DBM_TimerBegin", function(_, id, _, timer, _, _, spellId)
            A.OnBar("dbm", id, spellId, timer, GetTime())
        end)
        DBM:RegisterCallback("DBM_TimerStop", function(_, id) A.OnStop("dbm", id) end)
        DBM:RegisterCallback("DBM_TimerPause", function(_, id) A.OnPause("dbm", id, GetTime()) end)
        DBM:RegisterCallback("DBM_TimerResume", function(_, id) A.OnResume("dbm", id, GetTime()) end)
        dbm = true
    end
    if type(BigWigsLoader) == "table" and BigWigsLoader.RegisterMessage then
        BigWigsLoader.RegisterMessage(A, "BigWigs_StartBar", function(_, _, key, text, duration)
            A.OnBar("bw", text, key, duration, GetTime())
        end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_StopBar", function(_, _, text) A.OnStop("bw", text) end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_PauseBar", function(_, _, text) A.OnPause("bw", text, GetTime()) end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_ResumeBar", function(_, _, text) A.OnResume("bw", text, GetTime()) end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_StopBars", function() A.OnStopAll("bw") end)
        BigWigsLoader.RegisterMessage(A, "BigWigs_OnBossDisable", function() A.OnStopAll("bw") end)
        bw = true
    end
    connected = dbm and bw and "both" or dbm and "DBM" or bw and "BigWigs" or nil
    return connected
end

function A.Status()
    if connected == "both" then return "DBM and BigWigs connected" end
    if connected then return connected .. " connected" end
    return "No boss mod"
end

function A.OnEncounter(event)
    if event == "ENCOUNTER_START" then
        barsSeen, encounterAt = false, GetTime()
    else
        encounterAt = nil
        A.OnStopAll("dbm")
        A.OnStopAll("bw")
    end
end

function A.Tick(now)
    if encounterAt and connected and not barsSeen and now - encounterAt > HEALTH_WAIT then
        encounterAt = nil
        print("|cff33ff99Cast Ahead|r " .. connected .. " sent no boss timers this fight - boss save calls are off until it does.")
    end
end
```

Connect timing: add `"PLAYER_LOGIN"` to Core's event list (`Core.lua:2572-2582`; it is not registered today) and call `CastAheadBossAdapter.Connect()` once from that branch of the event handler. DBM-Core loads before `PLAYER_LOGIN` (it is not load-on-demand); BigWigs' loader likewise. Call `CastAheadBossAdapter.Tick(now)` from Core's OnUpdate next to `CastAheadSaves.Tick(now)`. Add a third test that fires `ENCOUNTER_START`, advances 31 s with no bar and checks one chat line (`print` stub counter in `test_core.lua` - add `local printed = 0; print = function(...) printed = printed + 1 end` around the case and restore it).

- [ ] **Step 4: Run both suites** - Expected: `OK` twice.
- [ ] **Step 5: Commit** `git add BossAdapter.lua Core.lua CastAhead.toc test_core.lua && git commit -m "feat: boss save calls from DBM and BigWigs bars"`; push.

---

### Task 10: Settings - Defensives tab

**Files:**
- Modify: `Options.lua` (new tab), `Config.lua` (no new functions; keys `saveCalls`, `bossAdapter`, `saveButtons`)
- Test: `test_core.lua` (config round-trip only)

**Interfaces:**
- Consumes: `CastAheadSaves.SpecID`, `CastAheadSaves.Button`, `CastAheadSaveButtons`, `CastAheadBossAdapter.Status`.
- Produces: tab "Defensives" with: checkbox "Defensive calls" (`saveCalls`, default on), checkbox "Boss calls from DBM / BigWigs" (`bossAdapter`, default on), status line from `CastAheadBossAdapter.Status()`, two dropdowns "Small defensive" and "Big defensive" listing every id in the current spec's shipped lists plus the current override, each item showing icon and name (`C_Spell.GetSpellName`), a "Reset to default" button that sets `CastAheadDB.saveButtons[spec] = nil`, and the line "Defensive buttons ship for Warlock, Paladin and Demon Hunter; more specs are coming." when the spec has no table.

- [ ] **Step 1: Read `Options.lua`** to find how an existing tab is declared (the tab list and the `refreshers` registration used for every stateful widget, as noted in the 2026-09-01 settings work) and copy that pattern for the new tab. Every widget registers a refresher; every write goes through `CastAheadConfig.Set` / `SetEnabled`; every write that changes buttons calls `CastAheadSaves.Refresh()`.
- [ ] **Step 2: Write the failing config test**

```lua
CastAheadDB = {}
check(CastAheadConfig.Enabled("saveCalls") and CastAheadConfig.Enabled("bossAdapter"), "save and boss calls are on by default")
CastAheadConfig.SetEnabled("bossAdapter", false)
check(CastAheadDB.bossAdapter == false and CastAheadConfig.Enabled("saveCalls"), "the boss switch is separate")
```

- [ ] **Step 3: Run** - it passes already (defaults are `nil` = on); keep it as the guard for the defaults.
- [ ] **Step 4: Build the tab** following the existing pattern. Open the window in game is the owner's check (Task 11); the headless test only loads `Options.lua` (it already does through `UI.lua`), so `test_core.lua` must still print `OK`.
- [ ] **Step 5: Commit** `git commit -am "feat: Defensives settings tab"`; push.

---

### Task 11: Docs, sync step, PR ready

**Files:**
- Modify: `README.md` (feature section, alpha specs), `C:/Users/artem/.claude/skills/castahead-sync/SKILL.md` (new step: rerun `def_harvest.py`, `def_build.py`, review the boss coverage report), PR #54 description.

- [ ] **Step 1: README** - a short "Defensive calls (alpha)" section: what is said, which specs ship buttons, how to change a button, that boss calls need DBM or BigWigs. Run the text through the humanizer skill (owner rule for outbound text).
- [ ] **Step 2: castahead-sync** - add the step after the data rebuild: `python CastAheadTools/def_harvest.py F:/claude-data/castahead-defensives/wcl --per-spec 5` (skips finished runs; delete the folder after a patch to refetch), then `python CastAheadTools/def_build.py`, then check `boss-coverage.md`.
- [ ] **Step 3: Full test run** - both Lua suites `OK`, both pytest suites pass.
- [ ] **Step 4: In-game checklist for the owner** (post on the PR): Ruby Life Pools trash (Living Bomb aura sound, Inferno cast call), one Voidscar boss with DBM (Taz'Rah Nether Dash bar call), spec swap Affliction > Demonology keeps the icon right, settings override shows the new icon.
- [ ] **Step 5: Update PR #54 body** (humanized), mark ready for review only after the owner's in-game check.
