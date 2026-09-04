"""Turn casts.json (combat-log harvest) into CastAhead/Data.lua.

A spell earns a place if it is rare enough to be worth a countdown, or if the
group visibly deals with it - kicks it - or if it hurts. All of that is read
off the logs: interrupts, players hit, and damage as a share of their health.
overrides.json may force spells in ("include") or out ("exclude").

Cooldowns come out as a rotation, not one number: many mobs cycle uneven gaps
(4.8, 4.8, 8.7, ...), and averaging those predicts every cast wrong. Position i
of the rotation is the median of the i-th interval across every spawn seen.
"""
import sys, json, statistics
from collections import defaultdict

MIN_CAST = 1.0
MIN_CD = 8.0
MIN_SAMPLES = 4
KICK_SHARE = 0.25       # kicked this often -> people clearly interrupt it
AOE_TARGETS = 3         # lands on this many players -> group damage
HEAVY_DAMAGE = 0.20     # takes this share of the victim's health -> defensive
MIN_PER_POSITION = 3    # samples needed before a rotation slot is trusted
MAX_ROTATION = 8
FLAT_SPREAD = 0.15      # rotation this tight collapses to a single value
SPREAD_LIMIT = 0.20     # cd samples wider than this are flagged approximate
OFFSET_SPREAD = 8.0     # opening order this loose is still worth an estimate


def cluster(xs):
    """Densest 0.5s bucket -> (median, count, spread)."""
    if not xs:
        return None, 0, 0.0
    buckets = defaultdict(list)
    for v in xs:
        buckets[round(v * 2) / 2].append(v)
    best = max(buckets.values(), key=len)
    m = statistics.median(best)
    spread = (max(best) - min(best)) / m if m else 0.0
    return round(m, 1), len(best), spread


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
    """Median interval per rotation slot, across all spawns of this mob."""
    slots = []
    for i in range(MAX_ROTATION):
        column = [r[i] for r in runs if len(r) > i]
        value, n, _ = cluster(column)
        if value is None or n < MIN_PER_POSITION:
            break
        slots.append(value)
    if not slots:
        return [fallback] if fallback else None
    lo, hi = min(slots), max(slots)
    if lo and (hi - lo) / lo <= FLAT_SPREAD:
        return [round(statistics.median(slots), 1)]
    return shortest_period(slots)


def threat(r):
    """What this cast does to the group, and how people deal with it.

    hits - players it typically lands on. dmg - share of the victim's own max
    health, so it stays meaningful across gear and key levels. kick/cc - what
    the group was actually seen doing about it: real interrupts, versus casts
    that died some other way (a stun, a knock, a disorient).
    """
    hits = round(statistics.median(r["hits"]), 1) if r["hits"] else None
    dmg = round(statistics.median(r["dmg"]), 3) if r["dmg"] else None
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


def main(casts_path, out_path, mdt_path=None, overrides_path=None, channels_path=None):
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

    dungeons = {}
    for key, mobs in data.items():
        instance_id, zone = key.split("|", 1)
        rows = []
        for npcid, spells in mobs.items():
            for spellid, r in spells.items():
                facts = mdt.get(str(npcid))
                if facts and facts["boss"]:
                    # Boss abilities are DBM's job, and letting them compete to
                    # identify a trash cast is how Melidrussa's kickable Frigid
                    # Shard ended up labelling Primal Juggernaut's Crushing Smash.
                    continue
                if facts and facts["spells"] and str(spellid) not in facts["spells"]:
                    # The logs attributed a spell this creature does not own.
                    continue
                cast = statistics.median(r["cast"]) if r["cast"] else 0.0
                is_channel = cast < MIN_CAST and int(spellid) in channels
                if is_channel:
                    cast = channels[int(spellid)]
                flat, cdn, spread = cluster(r["iv"])
                cd = rotation(list(r.get("runs", {}).values()), flat)
                first, firstN, _ = cluster(r["first"])
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
                if not forced:
                    if spellid in exclude:
                        continue
                    if not worth_showing(cast, cd, cdn, t):
                        continue
                rows.append({
                    "spell": int(spellid), "npc": int(npcid),
                    "cast": round(cast, 1), "cd": cd or [], "first": first,
                    "n": cdn, "approx": spread > SPREAD_LIMIT,
                    "name": r["name"], "mob": r["mob"],
                    # From MDT when MDT knows the creature: its word beats the
                    # tally (a boss spell with the same cast time once made an
                    # uninterruptible cast look kickable). For a creature MDT
                    # does not list, the tally is the only evidence there is.
                    "kickable": (bool(facts["spells"].get(str(spellid))) if facts and facts["spells"]
                                 else t["kick"] >= KICK_SHARE),
                    # UnitLevel still reads off a hostile nameplate, so this
                    # narrows candidates the moment the mob enters combat.
                    "level": (facts or {}).get("level"),
                    # How many samples the opening delay rests on. It is the
                    # loosest number in the table, so a thin one is worse than
                    # none: Primal Juggernaut's three samples spanned 11s.
                    "firstN": firstN,
                    "offset": offset,
                    "samples": len(r["cast"]) + r.get("kicked", 0),
                    # A short cycle means the countdown is noise; the bar only
                    # names such a cast while it is happening.
                    # No rotation at all (cast once per pull) counts as filler too:
                    # there is nothing to count down to.
                    "filler": not cd or min(cd) < MIN_CD,
                    "channel": is_channel,
                    **t,
                })
        if rows:
            rows.sort(key=lambda x: (x["cast"], x["cd"][0] if x["cd"] else 0))
            dungeons[int(instance_id)] = (zone, rows)

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
                        " n = %d, firstN = %d, level = %s, offset = %s,%s%s }, -- seen %d\n"
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
                           + (" channel = true," if r.get("channel") else ""),
                           r["samples"]))
            f.write("    },\n")
        f.write("}\n")

    total = sum(len(rows) for _, rows in dungeons.values())
    cycles = sum(1 for _, rows in dungeons.values() for r in rows if len(r["cd"]) > 1)
    print("%d dungeons, %d spells (%d with an uneven rotation) -> %s"
          % (len(dungeons), total, cycles, out_path))


if __name__ == "__main__":
    main(*sys.argv[1:])
