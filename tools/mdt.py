"""Pull enemy facts out of Mythic Dungeon Tools.

The combat logs know timing - how long a cast takes, how often it repeats - but
nothing about what a mob is. MDT knows exactly that: which spells belong to which
creature, which of them can be interrupted, and which creatures are bosses. Its
data files are plain Lua tables, so a targeted scan is enough; keying everything
by npcID means no dungeon-name mapping is needed.

Usage: mdt.py "<AddOns>/MythicDungeonTools" mdt.json
"""
import sys, os, re, json, glob

ENEMY = re.compile(r'\n  \[\d+\] = \{\n(.*?)(?=\n  \[\d+\] = \{|\n\};|\Z)', re.S)
NAME = re.compile(r'\["name"\]\s*=\s*"([^"]*)"')
NPC_ID = re.compile(r'\["id"\]\s*=\s*(\d+)')
IS_BOSS = re.compile(r'\["isBoss"\]\s*=\s*true')
LEVEL = re.compile(r'\["level"\]\s*=\s*(\d+)')
SPELLS = re.compile(r'\["spells"\]\s*=\s*\{(.*?)\n    \},', re.S)
SPELL = re.compile(r'\[(\d+)\] = \{(.*?)\},', re.S)


def parse(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    # Only the enemy table; the file also holds map POIs shaped similarly.
    start = text.find("MDT.dungeonEnemies")
    if start < 0:
        return {}
    out = {}
    for block in ENEMY.finditer(text[start:]):
        body = block.group(1)
        npc_id = NPC_ID.search(body)
        name = NAME.search(body)
        if not npc_id or not name:
            continue
        spells = {}
        spell_block = SPELLS.search(body)
        if spell_block:
            for spell in SPELL.finditer(spell_block.group(1)):
                spells[int(spell.group(1))] = "interruptible" in spell.group(2)
        level = LEVEL.search(body)
        out[int(npc_id.group(1))] = {
            "mob": name.group(1),
            "boss": bool(IS_BOSS.search(body)),
            # UnitLevel is one of the few things still readable off a hostile
            # nameplate, so it can narrow candidates before any cast happens.
            "level": int(level.group(1)) if level else None,
            "spells": spells,
        }
    return out


def main(mdt_dir, out_path):
    merged = {}
    files = []
    for sub in ("*/*.lua", "*.lua"):
        files.extend(glob.glob(os.path.join(mdt_dir, sub)))
    for path in sorted(set(files)):
        for npc_id, row in parse(path).items():
            existing = merged.get(npc_id)
            # A creature can appear in several dungeons; merge what is known.
            if existing:
                existing["boss"] = existing["boss"] or row["boss"]
                existing["level"] = existing["level"] or row["level"]
                existing["spells"].update(row["spells"])
            else:
                merged[npc_id] = row

    json.dump({str(k): v for k, v in merged.items()},
              open(out_path, "w", encoding="utf-8"), ensure_ascii=False)
    bosses = sum(1 for r in merged.values() if r["boss"])
    kickable = sum(1 for r in merged.values() for ok in r["spells"].values() if ok)
    spells = sum(len(r["spells"]) for r in merged.values())
    print("%d creatures (%d bosses), %d spells (%d interruptible) -> %s"
          % (len(merged), bosses, spells, kickable, out_path))


if __name__ == "__main__":
    main(*sys.argv[1:])
