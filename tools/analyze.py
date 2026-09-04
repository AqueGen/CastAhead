import sys, json, statistics
from collections import defaultdict

data = json.load(open(sys.argv[1], encoding="utf-8"))
MIN_OBS = int(sys.argv[2]) if len(sys.argv) > 2 else 3


def med(xs):
    return round(statistics.median(xs), 2) if xs else None


def mode_iv(xs):
    # cluster intervals to 0.5s buckets, take the densest cluster median
    if not xs:
        return None, 0
    buckets = defaultdict(list)
    for v in xs:
        buckets[round(v * 2) / 2].append(v)
    best = max(buckets.values(), key=len)
    return round(statistics.median(best), 1), len(best)


for dungeon, mobs in sorted(data.items()):
    print("=" * 78)
    print(dungeon)
    prints = {}
    rows = {}
    for npcid, spells in mobs.items():
        durs = []
        srows = []
        for spellid, r in spells.items():
            ct = med(r["cast"])
            iv, ivn = mode_iv(r["iv"])
            first = med(r["first"])
            n = len(r["cast"]) + len(r["iv"])
            if n < MIN_OBS:
                continue
            srows.append((spellid, r["name"], ct, iv, ivn, first, len(r["first"])))
            if ct:
                durs.append(ct)
        if not srows:
            continue
        key = tuple(sorted(set(durs)))
        prints.setdefault(key, []).append(npcid)
        rows[npcid] = (spells[list(spells)[0]]["mob"], srows)

    for key, npcs in sorted(prints.items(), key=lambda kv: -len(kv[1])):
        tag = "UNIQUE" if len(npcs) == 1 else "COLLIDE x%d" % len(npcs)
        print("  -- castTimes %s  [%s]" % (list(key), tag))
        for npcid in npcs:
            mob, srows = rows[npcid]
            print("     %-24s npc=%s" % (mob[:24], npcid))
            for spellid, name, ct, iv, ivn, first, fn in srows:
                print("        %-26s cast=%-5s cd~%-6s (n=%d) first=%-5s (n=%d)"
                      % (name[:26], ct, iv, ivn, first, fn))
