"""Count, per hostile spell, how many of its casts landed on a target.

In game the addon can read whether a cast has a target the moment it starts;
the combat log only names the target when the cast lands, on SPELL_CAST_SUCCESS.
The share is a property of the spell, so any logs will do - the history in
casts.json is not needed.

    python tools/targets.py "<WoW>/Logs/WoWCombatLog*.txt" targets.json
"""
import csv
import glob
import json
import sys

HOSTILE = 0x40
NO_TARGET = ("0000000000000000", "")


def scan(path, counts):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if "  SPELL_CAST_SUCCESS,Creature-" not in line:
                continue
            try:
                p = next(csv.reader([line.split("  ", 1)[1]]))
                if not int(p[3], 16) & HOSTILE:
                    continue
                spell = p[9]
            except (ValueError, IndexError, StopIteration):
                continue
            row = counts.setdefault(spell, [0, 0])
            row[0] += 1
            row[1] += p[5] not in NO_TARGET


def main(pattern, out_path):
    counts = {}
    files = sorted(glob.glob(pattern))
    for path in files:
        sys.stderr.write("reading %s\n" % path)
        scan(path, counts)
    json.dump(counts, open(out_path, "w", encoding="utf-8"), sort_keys=True)
    print("%d spells from %d files -> %s" % (len(counts), len(files), out_path))


if __name__ == "__main__":
    main(*sys.argv[1:])
