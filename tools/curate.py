"""Propose a priority set from our own combat logs.

Reads raw combat logs (advanced logging required) and works out, for every
hostile trash cast, what it did to the group: who it hit, how hard, who was
standing there and did NOT get hit, from which direction, what it left
behind, whether anyone kicked it, whether it brought friends. Those
observations decide two things - whether a cast is worth calling at all, and
what the call should be.

The negative evidence is the important half. A cast that hits everyone in
range is group damage; one that hits only the people in front of the caster
is a frontal; one that half the group in range avoided is something to move
out of. Without knowing who was standing there, all three look alike.

Writes a proposal, never the shipped file:

    Priority.curated.lua  same shape as Priority.lua
    review.md             every proposal with the evidence behind it

Read review.md, not the Lua. Corrections go in overrides.json under
"category" and survive the next run.

Usage:
    python tools/curate.py "<WoW>/Logs/WoWCombatLog*.txt" out/
    python tools/curate.py logs/*.txt out/ --mdt mdt.json --overrides overrides.json
"""
import csv
import glob
import io
import json
import math
import os
import sys
from collections import defaultdict

# Damage landing this soon after a cast is that cast's own payload.
PAYLOAD_WINDOW = 2.0
# A triggered effect - the pool it drops, the debuff it applies - keeps
# hurting after that. Credited to the cast, but only for spells that are
# never cast in their own right.
CHILD_WINDOW = 10.0
# A player's position is only worth using if it was seen this recently.
POSITION_AGE = 4.0
# Players further away than this were not in the cast's business at all.
IN_RANGE = 40.0

AOE_TARGETS = 3          # this many players hit -> group damage
TANK_SHARE = 0.20        # this share of the tank's health -> tank buster
GATE_SHARE = 0.15        # this much on anyone -> worth calling at all
KICK_SHARE = 0.25        # kicked this often -> people clearly interrupt it
CONE_DEGREES = 60.0      # half-angle counted as "in front of" the caster
CONE_PURITY = 0.85       # this share of victims inside the cone -> frontal
AVOID_SHARE = 0.40       # this share of bystanders untouched -> avoidable
AVOID_SPREAD = 0.50      # casts landing on this share fewer people -> dodged
MIN_PAYLOADS = 3         # observations before a shape verdict is trusted

HOSTILE = 0x40

# Column offsets, verified against 12.1 lines. The advanced block describes
# the DESTINATION on damage and healing events, and the SOURCE on
# SPELL_CAST_SUCCESS - so a mob hitting a player gives us that player's
# position, and a mob's own cast gives us the mob's.
SRC, SRC_NAME, SRC_FLAGS = 1, 2, 3
DST, DST_NAME = 5, 6
SPELL, SPELL_NAME = 9, 10
ADV_MAXHP, ADV_X, ADV_Y, ADV_FACING = 15, 26, 27, 29
DMG_AMOUNT, DMG_ABSORBED = 31, 37
AURA_TYPE = 12                # SPELL_AURA_APPLIED: DEBUFF or BUFF
EXTRA_SPELL = 12              # SPELL_INTERRUPT / SPELL_DISPEL: the spell acted on

# What each dispel ability can remove. A debuff removed by several different
# abilities is whatever they have in common - Cleanse Toxins and Remove
# Corruption can only agree on poison. Mirrors DISPEL_SPELLS in Core.lua.
DISPEL_ABILITY = {
    2782: {"POISON", "CURSE"},               # Remove Corruption
    88423: {"POISON", "CURSE", "MAGIC"},     # Nature's Cure
    383013: {"POISON"},                      # Poison Cleansing Totem
    213644: {"POISON", "DISEASE"},           # Cleanse Toxins
    4987: {"POISON", "DISEASE", "MAGIC"},    # Cleanse
    115450: {"POISON", "DISEASE", "MAGIC"},  # Detox
    218164: {"POISON", "DISEASE"},           # Detox (Brewmaster/Windwalker)
    360823: {"POISON", "MAGIC"},             # Naturalize
    365585: {"POISON"},                      # Expunge
    374251: {"POISON", "CURSE", "DISEASE"},  # Cauterizing Flame
    475: {"CURSE"},                          # Remove Curse
    77130: {"CURSE", "MAGIC"},               # Purify Spirit
    51886: {"CURSE"},                        # Cleanse Spirit
    527: {"DISEASE", "MAGIC"},               # Purify
    213634: {"DISEASE"},                     # Purify Disease
    32375: {"MAGIC"},                        # Mass Dispel
    370: {"PURGE"},                          # Purge
    528: {"PURGE"},                          # Dispel Magic
    30449: {"PURGE"},                        # Spellsteal
    278326: {"PURGE"},                       # Consume Magic
    2908: {"SOOTHE"},                        # Soothe
    19801: {"PURGE", "SOOTHE"},              # Tranquilizing Shot
}


def stamp(s):
    h, m, sec = s.split(" ")[1].split(":")
    return int(h) * 3600 + int(m) * 60 + float(sec)


def npc_of(guid):
    try:
        return int(guid.split("-")[5])
    except (IndexError, ValueError):
        return None


def record():
    return {
        "name": "", "mob": "", "npc": None, "dungeon": "",
        "starts": 0, "casts": 0, "kicked": 0, "summons": 0,
        "payloads": [],                 # one entry per observed cast
        "auras": defaultdict(int),      # child debuff -> times seen after it
        "children": defaultdict(int),   # damage spellIDs it triggers
    }


class Scan:
    """One pass over the logs, gathering evidence per hostile cast spell."""

    def __init__(self, bosses=frozenset()):
        self.bosses = bosses
        self.spells = defaultdict(record)
        self.cast_ids = set()               # every spellID seen as a cast
        self.aura_by_spell = defaultdict(lambda: defaultdict(int))
        self.dispels = defaultdict(set)     # debuff -> dispel abilities used
        self.periodic = set()               # debuffs that tick for damage
        self.dungeon = None
        self.in_boss = False
        self.tanks = set()
        self.reset_run()

    def reset_run(self):
        self.pending = {}       # caster guid -> the cast awaiting its payload
        self.swings = defaultdict(int)      # player -> melee swings taken
        self.where = {}         # player -> (time, x, y), last known position

    # -- payload bookkeeping ------------------------------------------------
    def close(self, guid):
        row = self.pending.pop(guid, None)
        if not row or not row["seen"]:
            return
        hit = row["targets"]
        direct = {p: v for p, v in hit.items() if p in row["direct"]}
        rec = row["rec"]
        rec["payloads"].append({
            "hits": len(direct or hit),
            "worst": round(max([s for s, _ in hit.values()], default=0.0), 3),
            "victims": sorted(direct or hit),
            "cone_hit": row["cone_hit"], "cone_miss": row["cone_miss"],
            "wide_hit": row["wide_hit"], "wide_miss": row["wide_miss"],
            "bystanders": 0,
            "child_only": row["child_only"],
            "around": row["around"],
        })

    def close_all(self):
        for guid in list(self.pending):
            self.close(guid)

    def end_run(self):
        """Close the books on a keystone run: payloads, and who tanked it."""
        self.close_all()
        if self.swings:
            self.tanks.add(max(self.swings, key=self.swings.get))
        self.reset_run()

    # -- the pass -----------------------------------------------------------
    def line(self, line):
        if "CHALLENGE_MODE_" in line:
            self.end_run()
            if "CHALLENGE_MODE_START" in line:
                f = line.split("CHALLENGE_MODE_START,")[1].split(",")
                self.dungeon = "%s|%s" % (f[1].strip(), f[0].strip('"'))
            else:
                self.dungeon = None
            return
        if self.dungeon is None:
            return
        if "ENCOUNTER_START" in line[:60]:
            self.in_boss = True
            return
        if "ENCOUNTER_END" in line[:60]:
            self.in_boss = False
            return

        try:
            head, rest = line.split("  ", 1)
            p = next(csv.reader([rest]))
            t = stamp(head)
        except Exception:
            return
        ev = p[0]

        if ev.startswith("SWING_"):
            if ev == "SWING_DAMAGE" and p[DST].startswith("Player-"):
                self.swings[p[DST]] += 1
            return
        if ev in ("SPELL_CAST_SUCCESS", "SPELL_CAST_START"):
            self.on_cast(t, ev, p)
        elif ev in ("SPELL_DAMAGE", "SPELL_PERIODIC_DAMAGE"):
            self.on_damage(t, ev, p)
        elif ev in ("SPELL_HEAL", "SPELL_PERIODIC_HEAL"):
            if p[DST].startswith("Player-"):
                self.mark(t, p[DST], p, ADV_X, ADV_Y)
        elif ev == "SPELL_AURA_APPLIED":
            self.on_aura(t, p)
        elif ev == "SPELL_DISPEL":
            self.on_dispel(p)
        elif ev == "SPELL_INTERRUPT":
            self.on_interrupt(p)
        elif ev == "SPELL_SUMMON" and self.hostile(p[SRC], p[SRC_FLAGS]):
            try:
                self.spells[int(p[SPELL])]["summons"] += 1
            except (ValueError, IndexError):
                pass

    def mark(self, t, player, p, xi, yi):
        """Remember where a player was standing, from any event about them."""
        try:
            self.where[player] = (t, float(p[xi]), float(p[yi]))
        except (ValueError, IndexError):
            pass

    def hostile(self, guid, flags):
        if not guid.startswith("Creature-"):
            return False
        try:
            return bool(int(flags, 16) & HOSTILE)
        except ValueError:
            return False

    def on_cast(self, t, ev, p):
        guid = p[SRC]
        if self.in_boss or not self.hostile(guid, p[SRC_FLAGS]):
            return
        try:
            spell = int(p[SPELL])
        except (ValueError, IndexError):
            return
        if npc_of(guid) in self.bosses:
            return
        self.cast_ids.add(spell)
        rec = self.spells[spell]
        if ev == "SPELL_CAST_START":
            rec["starts"] += 1
            return

        rec["name"] = p[SPELL_NAME].strip('"')
        rec["mob"] = p[SRC_NAME].strip('"')
        rec["npc"] = npc_of(guid)
        rec["dungeon"] = self.dungeon
        rec["casts"] += 1

        self.close(guid)
        try:
            x, y, facing = float(p[ADV_X]), float(p[ADV_Y]), float(p[ADV_FACING])
        except (ValueError, IndexError):
            x = y = facing = None
        row = {"rec": rec, "spell": spell, "t": t, "targets": {}, "direct": set(),
               "x": x, "y": y, "facing": facing, "seen": False,
               "cone_hit": 0, "cone_miss": 0, "wide_hit": 0, "wide_miss": 0,
               "bystanders": 0, "child_only": True}
        row["around"] = self.bystanders(t, x, y, facing)
        self.pending[guid] = row

    def bystanders(self, t, x, y, facing):
        """Everyone standing near the caster when it cast, and where.

        Positions come from the last event that mentioned each player, so a
        stale one is dropped rather than guessed at.
        """
        if x is None:
            return {}
        near = {}
        for player, (seen, px, py) in self.where.items():
            if t - seen > POSITION_AGE:
                continue
            if math.hypot(px - x, py - y) > IN_RANGE:
                continue
            near[player] = self.in_cone(x, y, facing, px, py)
        return near

    def in_cone(self, x, y, facing, px, py):
        if facing is None:
            return False
        dx, dy = px - x, py - y
        if abs(dx) < 0.01 and abs(dy) < 0.01:
            return True
        delta = abs((math.atan2(dy, dx) - facing + math.pi) % (2 * math.pi) - math.pi)
        return math.degrees(delta) <= CONE_DEGREES

    def on_damage(self, t, ev, p):
        if p[DST].startswith("Player-"):
            self.mark(t, p[DST], p, ADV_X, ADV_Y)
        row = self.pending.get(p[SRC])
        if row is None or not p[DST].startswith("Player-"):
            return
        try:
            spell = int(p[SPELL])
        except (ValueError, IndexError):
            return
        child = spell != row["spell"]
        if t - row["t"] > (CHILD_WINDOW if child else PAYLOAD_WINDOW):
            if not child:
                self.close(p[SRC])
            return
        if child:
            if spell in self.cast_ids:
                return       # a cast in its own right, not this one's doing
            row["rec"]["children"][spell] += 1
            if ev == "SPELL_PERIODIC_DAMAGE":
                self.periodic.add(spell)
        else:
            row["child_only"] = False
            row["direct"].add(p[DST])
        try:
            max_hp = int(p[ADV_MAXHP])
            taken = int(p[DMG_AMOUNT]) + int(p[DMG_ABSORBED])
        except (ValueError, IndexError):
            return
        if max_hp <= 0:
            return
        row["seen"] = True
        share = taken / max_hp
        old = row["targets"].get(p[DST], (0.0, None))
        row["targets"][p[DST]] = (max(old[0], share), p[DST])

    def on_aura(self, t, p):
        row = self.pending.get(p[SRC])
        if row is None or t - row["t"] > PAYLOAD_WINDOW:
            return
        if not p[DST].startswith("Player-"):
            return
        try:
            aura = int(p[SPELL])
        except (ValueError, IndexError):
            return
        if len(p) > AURA_TYPE and p[AURA_TYPE] != "DEBUFF":
            return
        row["seen"] = True
        row["rec"]["auras"][aura] += 1
        self.aura_by_spell[aura][row["spell"]] += 1

    def on_dispel(self, p):
        try:
            self.dispels[int(p[EXTRA_SPELL])].add(int(p[SPELL]))
        except (ValueError, IndexError):
            pass

    def on_interrupt(self, p):
        if not p[DST].startswith("Creature-"):
            return
        try:
            self.spells[int(p[EXTRA_SPELL])]["kicked"] += 1
        except (ValueError, IndexError):
            pass


def own_auras(scan, rec, spell):
    """Debuffs this spell really applies, not ones a neighbour cast did.

    A caster can finish two casts inside one window, and the aura would be
    booked against whichever finished last. Each aura therefore belongs to
    the cast that applied it most often across the whole corpus.
    """
    mine = []
    for aura in rec["auras"]:
        sources = scan.aura_by_spell.get(aura)
        if sources and max(sources, key=sources.get) == spell:
            mine.append(aura)
    return mine


def dispel_type(scan, aura):
    """What removed this debuff, narrowed by everything that ever removed it."""
    abilities = scan.dispels.get(aura)
    if not abilities:
        return None
    kinds = None
    for ability in abilities:
        known = DISPEL_ABILITY.get(ability)
        if known is None:
            continue
        kinds = set(known) if kinds is None else (kinds & known)
    if not kinds:
        return None
    for preferred in ("SOOTHE", "PURGE", "POISON", "CURSE", "DISEASE", "MAGIC"):
        if preferred in kinds:
            return preferred
    return None


def shape(loads):
    """Aggregate the geometry: hits and misses, inside the cone and outside."""
    total = {"cone_hit": 0, "cone_miss": 0, "wide_hit": 0, "wide_miss": 0,
             "bystanders": 0}
    for load in loads:
        for key in total:
            total[key] += load[key]
    return total


def classify(scan, spell, rec, tanks):
    """First rule that fires wins. Returns (category, why) or (None, why)."""
    loads = rec["payloads"]
    hits = [load["hits"] for load in loads]
    worst = max([load["worst"] for load in loads], default=0.0)
    attempts = max(rec["casts"] + rec["kicked"], rec["starts"], 1)
    kick_rate = rec["kicked"] / attempts
    auras = own_auras(scan, rec, spell)

    reasons = []
    if kick_rate >= KICK_SHARE:
        reasons.append("kicked %d of %d" % (rec["kicked"], attempts))
    if auras:
        reasons.append("applies %s" % ", ".join(str(a) for a in auras))
    if worst >= GATE_SHARE:
        reasons.append("takes %.0f%% health" % (worst * 100))
    if hits and max(hits) >= AOE_TARGETS:
        reasons.append("hits %d players" % max(hits))
    if rec["summons"]:
        reasons.append("summons %d times" % rec["summons"])
    if not reasons:
        return None, "nothing to say about it (worst %.0f%%, %d hit at most)" % (
            worst * 100, max(hits, default=0))
    why = "; ".join(reasons)

    if kick_rate >= KICK_SHARE:
        return "KICK", why

    for aura in auras:
        kind = dispel_type(scan, aura)
        if kind:
            return kind, why + "; %d was dispelled off" % aura
    bleeds = [a for a in auras
              if (a in scan.periodic or a in rec["children"]) and a not in scan.dispels]
    if bleeds and worst > 0 and max(hits, default=0) <= 2:
        return "BLEED", why + "; %d ticks and nothing removes it" % bleeds[0]

    if rec["summons"] >= max(1, rec["casts"] // 3):
        return "SWITCH", why + "; it brings friends"

    # Payloads that only applied a debuff say nothing about the cast's shape.
    landed = [load for load in loads if load["hits"] > 0]
    single = [load for load in landed if load["hits"] == 1]
    if landed and len(single) == len(landed):
        on_tank = sum(1 for load in single if load["victims"][0] in tanks)
        if on_tank >= max(1, len(single) // 2):
            if worst >= TANK_SHARE:
                return "TANK", why + "; always the tank, and it lands hard"
            return None, why + "; small hit on the tank, not worth a call"
        return "TARGET", why + "; one player at a time, never the tank"

    geometry = shape(landed)
    if len(landed) >= MIN_PAYLOADS and geometry["bystanders"]:
        struck = geometry["cone_hit"] + geometry["wide_hit"]
        if struck and geometry["cone_hit"] / struck >= CONE_PURITY \
                and geometry["wide_miss"]:
            return "FRONTAL", why + "; %d of %d victims stood in front, %d beside it were untouched" % (
                geometry["cone_hit"], struck, geometry["wide_miss"])
        missed = geometry["cone_miss"] + geometry["wide_miss"]
        if missed and max(hits) >= 2 and missed / (missed + struck) >= AVOID_SHARE:
            return "DODGE", why + "; %d of %d in range took nothing" % (
                missed, missed + struck)

    # The same cast landing on five people once and on one the next time is a
    # cast people move out of. One that always lands on everyone is not.
    if len(landed) >= MIN_PAYLOADS and max(hits) >= AOE_TARGETS:
        spread = (max(hits) - min(load["hits"] for load in landed)) / max(hits)
        if spread >= AVOID_SPREAD:
            return "DODGE", why + "; lands on %d players some casts and %d others" % (
                max(hits), min(load["hits"] for load in landed))

    if hits and max(hits) >= AOE_TARGETS:
        return "AOE", why + "; it lands on the group"
    if landed and all(load["child_only"] for load in landed):
        return "DODGE", why + "; the damage comes from what it leaves behind"
    return "ALERT", why + "; no rule fits it"


def write_priority(path, chosen):
    out = io.open(path, "w", encoding="utf-8", newline="\n")
    out.write("-- Curated priority set. Generated - do not edit by hand.\n--\n"
              "-- CastAheadPriority: which casts are worth calling out, and what kind of\n"
              "-- response each one asks for. Keys match CastAheadMatch.ADVICE.\n"
              "-- CastAheadExtra: prioritised casts our own logs have not captured yet,\n"
              "-- with provisional timings; merged into the dungeon table at load.\n\n")
    out.write("CastAheadPriority = {\n")
    for spell in sorted(chosen):
        out.write("    [%d] = \"%s\",\n" % (spell, chosen[spell]))
    out.write("}\n\nCastAheadExtra = {\n}\n")
    out.close()


def write_review(path, rows, tanks):
    out = io.open(path, "w", encoding="utf-8", newline="\n")
    out.write("# Curation review\n\n")
    out.write("Proposals from our own logs. Confirm or correct each row, and record "
              "corrections in `overrides.json` under `category`.\n\n")
    out.write("Tank(s), by melee swings taken: %s\n\n"
              % (", ".join(sorted(tanks)) or "none identified"))
    by_dungeon = defaultdict(list)
    for row in rows:
        by_dungeon[row["dungeon"]].append(row)
    for dungeon in sorted(by_dungeon):
        out.write("## %s\n\n" % dungeon)
        out.write("| Spell | Cast | Mob | Casts | Worst | Hit | Near | Proposal | Evidence |\n")
        out.write("|---|---|---|---|---|---|---|---|---|\n")
        for row in sorted(by_dungeon[dungeon], key=lambda r: (-r["worst"], r["spell"])):
            out.write("| %d | %s | %s | %d | %.0f%% | %d | %d | **%s** | %s |\n" % (
                row["spell"], row["name"], row["mob"], row["casts"],
                row["worst"] * 100, row["targets"], row["near"],
                row["category"] or "-", row["why"]))
        out.write("\n")
    out.close()


def score_geometry(scan):
    """Fill in each payload's hit/miss counts now that victims are known."""
    for rec in scan.spells.values():
        for load in rec["payloads"]:
            victims = set(load["victims"])
            for player, in_cone in load.pop("around", {}).items():
                load["bystanders"] += 1
                if player in victims:
                    load["cone_hit" if in_cone else "wide_hit"] += 1
                else:
                    load["cone_miss" if in_cone else "wide_miss"] += 1


def main():
    argv = sys.argv[1:]
    def option(name):
        return argv[argv.index(name) + 1] if name in argv else None
    mdt_path, overrides_path = option("--mdt"), option("--overrides")
    skip = set()
    for name in ("--mdt", "--overrides"):
        if name in argv:
            i = argv.index(name)
            skip.update((i, i + 1))
    args = [a for i, a in enumerate(argv) if i not in skip]
    if len(args) < 2:
        print(__doc__)
        return 1
    patterns, outdir = args[:-1], args[-1]

    overrides = {}
    if overrides_path:
        overrides = json.load(io.open(overrides_path, encoding="utf-8")).get("category", {})
    bosses = set()
    if mdt_path:
        mdt = json.load(io.open(mdt_path, encoding="utf-8"))
        for key, entry in (mdt.items() if isinstance(mdt, dict) else []):
            if isinstance(entry, dict) and entry.get("isBoss"):
                try:
                    bosses.add(int(key))
                except ValueError:
                    pass

    files = []
    for pattern in patterns:
        files.extend(sorted(glob.glob(pattern)))
    if not files:
        print("no log files matched")
        return 1

    scan = Scan(bosses)
    for path in files:
        print("reading %s (%.0f MB)" % (os.path.basename(path),
                                        os.path.getsize(path) / 1e6))
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                scan.line(line)
        scan.end_run()
    score_geometry(scan)

    rows, chosen = [], {}
    for spell, rec in scan.spells.items():
        if not rec["casts"]:
            continue
        category, why = classify(scan, spell, rec, scan.tanks)
        if str(spell) in overrides:
            category, why = overrides[str(spell)], why + "; set by hand"
        loads = rec["payloads"]
        rows.append({
            "spell": spell, "name": rec["name"], "mob": rec["mob"],
            "dungeon": rec["dungeon"], "casts": rec["casts"],
            "worst": max([load["worst"] for load in loads], default=0.0),
            "targets": max([load["hits"] for load in loads], default=0),
            "near": max([load["bystanders"] for load in loads], default=0),
            "category": category, "why": why,
        })
        if category:
            chosen[spell] = category

    if not os.path.isdir(outdir):
        os.makedirs(outdir)
    write_priority(os.path.join(outdir, "Priority.curated.lua"), chosen)
    write_review(os.path.join(outdir, "review.md"), rows, scan.tanks)
    counts = defaultdict(int)
    for category in chosen.values():
        counts[category] += 1
    print("%d cast spells seen, %d pass the gate" % (len(rows), len(chosen)))
    print(", ".join("%s=%d" % kv for kv in sorted(counts.items(), key=lambda kv: -kv[1])))
    print("wrote %s" % outdir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
