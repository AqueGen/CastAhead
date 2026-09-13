"""Turn casts.json (combat-log harvest) into CastAhead/Data.lua.

A spell earns a place if it is rare enough to be worth a countdown, or if the
group visibly deals with it - kicks it - or if it hurts. All of that is read
off the logs: interrupts, players hit, and damage as a share of their health.
overrides.json may force spells in ("include") or out ("exclude").

Cooldowns come out as a rotation, not one number: many mobs cycle uneven gaps
(4.8, 4.8, 8.7, ...), and averaging those predicts every cast wrong. Position i
of the rotation is the median of the i-th interval across every spawn seen.
"""
import sys, json, re, statistics

MIN_CAST = 1.0
MIN_CD = 8.0
MIN_SAMPLES = 4
KICK_SHARE = 0.25       # kicked this often -> people clearly interrupt it
AOE_TARGETS = 3         # lands on this many players -> group damage
HEAVY_DAMAGE = 0.20     # takes this share of the victim's health -> defensive
MIN_DAMAGE_SAMPLES = 3
MIN_PER_POSITION = 3    # samples needed before a rotation slot is trusted
MAX_ROTATION = 8
FLAT_SPREAD = 0.15      # rotation this tight collapses to a single value
OFFSET_SPREAD = 8.0     # opening order this loose is still worth an estimate
CD_WINDOW = 0.5
FIRST_WINDOW = 1.0
CD_TOLERANCE_FLAT = 1.0  # Match.lua CD_TOLERANCE_FLAT / CD_TOLERANCE_REL
CD_TOLERANCE_REL = 0.05
APPROX_SUPPORT = 0.5    # fewer intervals than this share fit the schedule -> approximate
ROTATION_GAIN = 0.10    # a rotation must predict this much more than one flat cooldown
FRESH_RUN = re.compile(r"#0\+*$")
# The previous Data.lua is kept field by field unless a new value would change
# what the addon does: cross one of these in-game thresholds (Match.lua,
# Core.lua) or move further than the matcher's own tolerance allows.
CC_SHARE = 0.25
HEAVY_SINGLE = 0.15
THIN_EVIDENCE = 5
MIN_OPENING_SAMPLES = 3
SHARE_MARGIN = 0.02
SHARE_STEP = 0.10
CAST_STEP = 0.12        # half of CAST_TOLERANCE
FIRST_STEP = 2.0        # half of FIRST_TOLERANCE
OFFSET_STEP = 1.0
APPROX_MARGIN = 0.05


def densest(xs, width):
    """(median, size) of the densest window of this width, independent of sample order."""
    if not xs:
        return None, 0
    xs = sorted(xs)
    overall = statistics.median(xs)
    best, lo = None, 0
    for hi in range(len(xs)):
        while xs[hi] - xs[lo] > width:
            lo += 1
        mid = (xs[(lo + hi) // 2] + xs[(lo + hi + 1) // 2]) / 2
        key = (hi - lo + 1, -abs(mid - overall), -mid)
        if best is None or key > best[0]:
            best = (key, mid)
    size, mid = best[0][0], best[1]
    if size == 1 and len(xs) > 1:
        return round(overall, 1) + 0.0, 1
    return round(mid, 1) + 0.0, size


def fits(interval, cd):
    return abs(interval - cd) <= CD_TOLERANCE_FLAT + cd * CD_TOLERANCE_REL


def support(xs, slots):
    """How many intervals a live matcher would accept against one of these slots."""
    return sum(1 for x in xs if any(fits(x, s) for s in slots))


def shortest_period(slots):
    """Collapse a repeating sequence to one turn of it.

    Positional medians can yield {A,B,C,A,B}: cycling that list wraps from slot 5
    to A when the truth is C. Only a whole period cycles correctly.
    """
    for period in range(1, len(slots) + 1):
        if all(abs(slots[i] - slots[i % period]) <= max(0.5, slots[i % period] * 0.1)
               for i in range(len(slots))):
            return slots[:period]
    return slots


def rotation(runs, fallback):
    """Median interval per rotation slot, across all spawns of this mob.

    Only sequences that start at a spawn's first cast know their phase; one
    restarted after a missed cast begins at an unknown slot.
    """
    fresh = [seq for key, seq in sorted(runs.items()) if FRESH_RUN.search(key)]
    slots = []
    for i in range(MAX_ROTATION):
        column = [r[i] for r in fresh if len(r) > i]
        value, _ = densest(column, CD_WINDOW)
        if value is None or support(column, [value]) < MIN_PER_POSITION:
            break
        slots.append(value)
    if not slots:
        return [fallback] if fallback else None
    lo, hi = min(slots), max(slots)
    if lo and (hi - lo) / lo <= FLAT_SPREAD:
        return [round(statistics.median(slots), 1)]
    cycle = shortest_period(slots)
    if fallback and positional_fit(fresh, cycle) < positional_fit(fresh, [fallback]) + ROTATION_GAIN:
        return [fallback]
    return cycle


def positional_fit(runs, slots):
    """Share of observed intervals a cycled schedule predicts within the live tolerance."""
    total = hit = 0
    for seq in runs:
        for i, v in enumerate(seq):
            total += 1
            hit += fits(v, slots[i % len(slots)])
    return hit / total if total else 0.0


def threat(r):
    """What this cast does to the group, and how people deal with it.

    hits - players it typically lands on. dmg - share of the victim's own max
    health, so it stays meaningful across gear and key levels. kick/cc - what
    the group was actually seen doing about it: real interrupts, versus casts
    that died some other way (a stun, a knock, a disorient).
    """
    measured = len(r["dmg"]) >= MIN_DAMAGE_SAMPLES
    hits = round(float(statistics.median(r["hits"])), 1) if measured else None
    dmg = round(statistics.median(r["dmg"]), 3) if measured else None
    finished = len(r["cast"])
    kicked = r.get("kicked", 0)
    # Channels log no START, so attempts have to be counted from what we did
    # see rather than trusting the start counter alone.
    attempts = max(r.get("starts", 0), finished + kicked)
    stopped_otherwise = max(0, attempts - finished - kicked)
    return {
        "hits": hits,
        "dmg": dmg,
        # Shares of all attempts, so a spell kicked twice out of a hundred does
        # not read the same as one kicked every time.
        "kick": round(kicked / attempts, 2) if attempts else 0,
        "cc": round(stopped_otherwise / attempts, 2) if attempts else 0,
    }


def worth_showing(cast, cd, samples, t):
    """A spell earns a slot if it is rare, kicked, or hurts.

    The cooldown threshold alone was wrong: the casts people actually kick are
    the short-cycle fillers it was designed to drop.
    """
    if cast < MIN_CAST:
        return False                      # no cast bar to hang anything on
    if t["kick"] >= KICK_SHARE:
        return True
    if (t["hits"] or 0) >= AOE_TARGETS or (t["dmg"] or 0) >= HEAVY_DAMAGE:
        return True
    return bool(cd) and min(cd) >= MIN_CD and samples >= MIN_SAMPLES


ANCHOR_ZONE = re.compile(r'^\s*\[(\d+)\] = \{ name = "([^"]*)",')
ANCHOR_ROW = re.compile(r'\{ spell = (\d+), npc = (\d+), mob = "([^"]*)", name = "([^"]*)",'
                        r' cast = ([\d.]+), cd = \{ ([^}]*)\}, (.*)\},\s*$')
ANCHOR_FIELD = re.compile(r"(\w+) = ([^,]+),")
FLAGS = ("kickable", "filler", "approx", "channel")


def lua_value(s):
    s = s.strip()
    if s == "nil":
        return None
    if s == "true":
        return True
    return float(s) if "." in s else int(s)


def read_anchor(path):
    """{(instance, spell, npc): row} and {instance: zone} from a previously generated Data.lua."""
    rows, zones, instance = {}, {}, None
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except FileNotFoundError:
        return rows, zones
    for line in lines:
        m = ANCHOR_ZONE.match(line)
        if m:
            instance = int(m.group(1))
            zones[instance] = m.group(2)
            continue
        m = ANCHOR_ROW.search(line)
        if not m or instance is None:
            continue
        row = {k: lua_value(v) for k, v in ANCHOR_FIELD.findall(m.group(7))}
        row.update(spell=int(m.group(1)), npc=int(m.group(2)), mob=m.group(3), name=m.group(4),
                   cast=float(m.group(5)), cd=[float(v) for v in m.group(6).split(",") if v.strip()])
        row["samples"] = row.pop("n")
        for flag in FLAGS:
            row[flag] = bool(row.get(flag))
        rows[(instance, row["spell"], row["npc"])] = row
    return rows, zones


def moved(old, new, step):
    return (old is None) != (new is None) or (old is not None and abs(new - old) > step)


def crossed(old, new, threshold, margin=SHARE_MARGIN):
    if old is None or new is None:
        return False
    return new >= threshold + margin if old < threshold else new < threshold - margin


def count_moved(old, new, threshold):
    return new != old and ((old < threshold) != (new < threshold) or new >= 2 * old or 2 * new <= old)


def same_cd(old, new):
    if not old or not new:
        return not old and not new
    return all(abs(new[i % len(new)] - old[i % len(old)])
               <= (CD_TOLERANCE_FLAT + old[i % len(old)] * CD_TOLERANCE_REL) / 2
               for i in range(max(len(old), len(new))))


def settle(new, old):
    """(row, changed fields): the anchor's value wherever the new one would not change behaviour."""
    row, changed = dict(new), []
    if old is None:
        changed.append("added")
    else:
        def hold(field, material):
            if material:
                changed.append(field)
            else:
                row[field] = old[field]

        cd_moved = not same_cd(old["cd"], new["cd"])
        hold("cast", abs(new["cast"] - old["cast"]) > CAST_STEP or new["channel"] != old["channel"])
        hold("cd", cd_moved)
        hold("first", moved(old["first"], new["first"], FIRST_STEP))
        hold("firstN", count_moved(old["firstN"], new["firstN"], MIN_OPENING_SAMPLES))
        hold("offset", moved(old["offset"], new["offset"], OFFSET_STEP))
        hold("hits", moved(old["hits"], new["hits"], 1.0) or crossed(old["hits"], new["hits"], AOE_TARGETS, 0))
        hold("dmg", moved(old["dmg"], new["dmg"], SHARE_STEP) or crossed(old["dmg"], new["dmg"], HEAVY_DAMAGE)
             or crossed(old["dmg"], new["dmg"], HEAVY_SINGLE))
        hold("kick", moved(old["kick"], new["kick"], SHARE_STEP) or crossed(old["kick"], new["kick"], KICK_SHARE))
        hold("cc", moved(old["cc"], new["cc"], SHARE_STEP) or crossed(old["cc"], new["cc"], CC_SHARE))
        hold("samples", count_moved(old["samples"], new["samples"], THIN_EVIDENCE))
        if not cd_moved:
            row["approx"] = new["fit"] < APPROX_SUPPORT + (APPROX_MARGIN if old["approx"] else -APPROX_MARGIN)
    row["filler"] = not row["cd"] or min(row["cd"]) < MIN_CD
    row["kickable"] = row["mdt_kick"] if row["mdt_kick"] is not None else row["kick"] >= KICK_SHARE
    if old is not None:
        changed += [f for f in ("approx", "filler", "kickable", "level", "mob", "name") if row[f] != old[f]]
    return row, changed


def shown(value):
    if isinstance(value, list):
        return "{ %s }" % ", ".join(str(v) for v in value)
    return "nil" if value is None else str(value)


def print_report(report, total):
    for sign, zone, row, old, changed in sorted(report, key=lambda e: (e[1], e[2]["mob"], e[2]["name"], e[0])):
        line = "%s %s: %s / %s" % (sign, zone, row["mob"], row["name"])
        if sign == "~":
            line += "  " + "; ".join("%s %s -> %s" % (f, shown(old[f]), shown(row[f])) for f in changed)
        print(line)
    signs = [e[0] for e in report]
    print("%d rows: %d unchanged, %d changed, %d added, %d removed"
          % (total, total - signs.count("~") - signs.count("+"), signs.count("~"), signs.count("+"), signs.count("-")))


def main(casts_path, out_path, mdt_path=None, overrides_path=None, channels_path=None, fresh=False):
    data = json.load(open(casts_path, encoding="utf-8"))
    # MDT knows what the logs cannot: which creature owns a spell, whether that
    # spell is interruptible, and which creatures are bosses.
    mdt = json.load(open(mdt_path, encoding="utf-8")) if mdt_path else {}
    ov = json.load(open(overrides_path, encoding="utf-8")) if overrides_path else {}
    exclude = set(ov.get("exclude", []))
    include = set(ov.get("include", []))
    # Pure channels leave no SPELL_CAST_START in the log, so their length is
    # not measurable from it; it comes from this file, our logs supply the rest.
    channels = {int(k): float(v) for k, v in
                json.load(open(channels_path, encoding="utf-8")).items()} if channels_path else {}

    anchor, anchor_zones = ({}, {}) if fresh else read_anchor(out_path)
    dungeons, seen, report = {}, set(), []
    for key, mobs in data.items():
        instance_id, zone = key.split("|", 1)
        instance_id = int(instance_id)
        rows = dungeons.setdefault(instance_id, (zone, []))[1]
        for npcid, spells in mobs.items():
            for spellid, r in spells.items():
                facts = mdt.get(str(npcid))
                if facts and facts.get("encounter"):
                    # Boss abilities are DBM's job, and letting them compete to
                    # identify a trash cast is how Melidrussa's kickable Frigid
                    # Shard ended up labelling Primal Juggernaut's Crushing Smash.
                    #
                    # The test is the encounter id, not the route data's "boss"
                    # flag: that flag also covers the mini-bosses and rares a
                    # group walks into on the way - Flamegullet, Defier Draghar,
                    # High Channeler Ryvati - which no boss mod announces, and
                    # which our own logs show casting outside every
                    # ENCOUNTER_START window.
                    continue
                if facts and facts["spells"] and str(spellid) not in facts["spells"]:
                    # The logs attributed a spell this creature does not own.
                    continue
                cast = statistics.median(r["cast"]) if r["cast"] else 0.0
                is_channel = cast < MIN_CAST and int(spellid) in channels
                if is_channel:
                    cast = channels[int(spellid)]
                flat, _ = densest(r["iv"], CD_WINDOW)
                cd = rotation(r.get("runs", {}), flat)
                cdn = support(r["iv"], cd) if cd else 0
                approx = bool(cd) and cdn < APPROX_SUPPORT * len(r["iv"])
                first, firstN = densest(r["first"], FIRST_WINDOW)
                # Delay from the mob's very first cast to this spell's first.
                # Measured across all logs this is far tighter than anything
                # counted from engage (0.4s vs 3.0s median spread), because a
                # mob starts acting whenever it reaches the group, but keeps
                # its opening order once it does.
                offsets = sorted(r.get("offset", []))
                offset = None
                if len(offsets) >= 3:
                    lo, hi = offsets[len(offsets) // 10], offsets[-1 - len(offsets) // 10]
                    if hi - lo <= OFFSET_SPREAD:
                        offset = round(statistics.median(offsets), 1)
                t = threat(r)
                forced = spellid in include
                if spellid in exclude and not forced:
                    continue
                row_key = (instance_id, int(spellid), int(npcid))
                seen.add(row_key)
                old = anchor.get(row_key)
                row, changed = settle({
                    "spell": int(spellid), "npc": int(npcid),
                    "cast": round(cast, 1), "cd": cd or [], "first": first,
                    "approx": approx, "fit": cdn / len(r["iv"]) if r["iv"] else 1.0,
                    "name": r["name"].replace('"', "'"), "mob": r["mob"].replace('"', "'"),
                    # From MDT when MDT knows the creature: its word beats the
                    # tally (a boss spell with the same cast time once made an
                    # uninterruptible cast look kickable). For a creature MDT
                    # does not list, the tally is the only evidence there is.
                    "mdt_kick": bool(facts["spells"].get(str(spellid))) if facts and facts["spells"] else None,
                    # UnitLevel still reads off a hostile nameplate, so this
                    # narrows candidates the moment the mob enters combat.
                    "level": (facts or {}).get("level"),
                    # How many samples the opening delay rests on. It is the
                    # loosest number in the table, so a thin one is worse than
                    # none: Primal Juggernaut's three samples spanned 11s.
                    "firstN": firstN,
                    "offset": offset,
                    "samples": len(r["cast"]) + r.get("kicked", 0),
                    "channel": is_channel,
                    **t,
                }, old)
                if not forced and not worth_showing(row["cast"], row["cd"], cdn, row):
                    if old:
                        report.append(("-", zone, old, old, []))
                    continue
                rows.append(row)
                if changed:
                    report.append(("+" if old is None else "~", zone, row, old, changed))

    for row_key, old in anchor.items():
        if row_key in seen:
            continue
        instance_id, spellid, npcid = row_key
        facts = mdt.get(str(npcid))
        zone = dungeons.get(instance_id, (anchor_zones[instance_id],))[0]
        if (str(spellid) in exclude or facts and (facts.get("encounter")
                or facts["spells"] and str(spellid) not in facts["spells"])):
            report.append(("-", zone, old, old, []))
            continue
        dungeons.setdefault(instance_id, (zone, []))[1].append(old)

    dungeons = {i: (zone, rows) for i, (zone, rows) in dungeons.items() if rows}
    for _, rows in dungeons.values():
        rows.sort(key=lambda x: (x["cast"], x["cd"][0] if x["cd"] else 0, x["npc"], x["spell"]))

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("-- Generated from combat logs by gen.py. Do not edit by hand.\n")
        f.write("-- cast: measured cast time. cd: start-to-start rotation, cycled.\n")
        f.write("-- first: seconds from the mob entering combat to its first cast.\n")
        f.write("-- npc: groups spells that belong to one creature. Never read from the\n")
        f.write("-- game - unit identity is Secret; it only cross-checks that two casts\n")
        f.write("-- seen on the same nameplate come from the same kind of mob.\n\n")
        f.write("CastAheadData = {\n")
        for instance_id, (zone, rows) in sorted(dungeons.items()):
            f.write("    [%d] = { name = \"%s\",\n" % (instance_id, zone))
            for r in rows:
                f.write("        { spell = %d, npc = %d, mob = \"%s\", name = \"%s\", cast = %s,"
                        " cd = { %s }, first = %s, hits = %s, dmg = %s, kick = %s, cc = %s,"
                        " n = %d, firstN = %d, level = %s, offset = %s,%s%s },\n"
                        % (r["spell"], r["npc"], r["mob"].replace('"', "'"),
                           r["name"].replace('"', "'"), r["cast"],
                           ", ".join(str(v) for v in r["cd"]),
                           r["first"] if r["first"] is not None else "nil",
                           r["hits"] if r["hits"] is not None else "nil",
                           r["dmg"] if r["dmg"] is not None else "nil",
                           r["kick"], r["cc"], r["samples"],
                           r["firstN"],
                           r["level"] if r["level"] is not None else "nil",
                           r["offset"] if r["offset"] is not None else "nil",
                           " kickable = true," if r["kickable"] else "",
                           (" filler = true," if r["filler"] else "")
                           + (" approx = true," if r["approx"] else "")
                           + (" channel = true," if r.get("channel") else "")))
            f.write("    },\n")
        f.write("}\n")

    total = sum(len(rows) for _, rows in dungeons.values())
    cycles = sum(1 for _, rows in dungeons.values() for r in rows if len(r["cd"]) > 1)
    if anchor:
        print_report(report, total)
    print("%d dungeons, %d spells (%d with an uneven rotation) -> %s"
          % (len(dungeons), total, cycles, out_path))


if __name__ == "__main__":
    main(*[a for a in sys.argv[1:] if a != "--fresh"], fresh="--fresh" in sys.argv)
