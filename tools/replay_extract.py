"""Turn combat logs into a replay script for test_replay.lua.

The addon never sees spell IDs in game - only cast bars starting and stopping
on nameplate units, and a level. This extracts exactly that from our own
logs, plus the truth (which spell it really was), so the real matcher can be
run headless over real fights and scored.

    python tools/replay_extract.py "<WoW>/Logs/WoWCombatLog*.txt" replay.lua [mdt.json]

With mdt.json, every START also says whether the game would flag the cast
interruptible, the way UNIT_SPELLCAST_[NOT_]INTERRUPTIBLE does in play.

Writes a Lua table, one entry per keystone run:

    CastAheadReplay = {
      { instance = 2813, name = "Murder Row", events = {
          { t = 0.0, e = "ADD",   u = 1, level = 90, power = 0, npc = 236085 },
          { t = 1.2, e = "START", u = 1, spell = 1216571, kick = true },
          { t = 3.7, e = "STOP",  u = 1, spell = 1216571 },   -- completed
          { t = 9.0, e = "KICK",  u = 1, spell = 1216571 },   -- interrupted
          { t = 9.5, e = "FAIL",  u = 1, spell = 1216571 },   -- stopped otherwise
          { t = 30.0, e = "REMOVE", u = 1 },
          { t = 40.0, e = "ENC", on = true },                  -- boss encounter
      } },
    }

`u` is a nameplate slot, 1..40, recycled the way the game recycles unit
tokens. A pure channel (no cast bar, listed as a channel in the client's spell
data passed with --channels) replays as CHAN at its SPELL_CAST_SUCCESS and
CHANEND at the later of its aura leaving and its caster's last tick under the
same spell name, capped at the client length; `full` when it ran at least 90%
of that length. The aura usually sits on the channel's target, so its removal
alone can come before the channel ends.
"""
import csv
import glob
import io
import json
import sys
from collections import defaultdict

PLATES = 40
LINGER = 45.0          # a creature quiet this long has left the nameplate range
LEVEL_INDEX = 30       # advanced block on SPELL_CAST_SUCCESS: caster level
POWER_INDEX = 22       # ... and its power type (0 mana, 1 rage, 3 energy, ...)
HOSTILE = 0x40
CHANNEL_FULL = 0.9     # a channel ending past this share of its length ran in full
TICKS = ("SPELL_PERIODIC_DAMAGE", "SPELL_HEAL", "SPELL_PERIODIC_HEAL", "SPELL_MISSED", "SPELL_PERIODIC_MISSED")


def stamp(s):
    h, m, sec = s.split(" ")[1].split(":")
    return int(h) * 3600 + int(m) * 60 + float(sec)


def npc_of(guid):
    try:
        return int(guid.split("-")[5])
    except (IndexError, ValueError):
        return None


class Run:
    def __init__(self, instance, name, t0):
        self.instance, self.name, self.t0 = instance, name, t0
        self.events = []
        self.slot = {}          # guid -> plate slot
        self.free = list(range(PLATES, 0, -1))
        self.last_seen = {}
        self.level = {}         # guid -> (level, power), from the first SUCCESS
        self.kickable = {}      # (npc, spell) -> bool, from MDT
        self.open = {}          # guid -> (spell, t) of the cast in progress
        self.channel = {}       # guid -> the pure channel in progress
        self.lengths = {}       # spell -> client channel length
        self.pending_add = {}   # guid -> npc, waiting for a level

    def touch(self, guid, t):
        """A creature did something: give it a plate if it has none."""
        self.expire(t)
        self.last_seen[guid] = t
        if guid in self.slot or guid in self.pending_add:
            return
        self.pending_add[guid] = npc_of(guid)
        self.place(guid, t)

    def place(self, guid, t):
        if guid not in self.pending_add:
            return
        seen = self.level.get(guid)
        if seen is None or not self.free:
            return
        level, power = seen
        slot = self.free.pop()
        self.slot[guid] = slot
        self.events.append({"t": t, "e": "ADD", "u": slot, "level": level,
                            "power": power, "npc": self.pending_add.pop(guid)})

    def end_channel(self, guid, closed_at=None):
        ch = self.channel.pop(guid, None)
        if not ch:
            return
        length = self.lengths[ch["spell"]]
        seen = [x for x in (ch["removed"], ch["tick"]) if x is not None]
        end = min(max(seen) if seen else ch["t"] + length, ch["t"] + length)
        if closed_at is not None:
            end = min(end, closed_at)
        full = end - ch["t"] >= length * CHANNEL_FULL
        event = self.cast("CHANEND", guid, ch["spell"], end)
        if event is not None and (seen or not full):
            event["full"] = full

    def channel_tick(self, guid, name, t):
        ch = self.channel.get(guid)
        if ch and name == ch["name"] and t <= ch["t"] + self.lengths[ch["spell"]] + 0.5:
            ch["tick"] = t

    def end_channels(self, closed_at=None):
        for guid in list(self.channel):
            self.end_channel(guid, closed_at)

    def remove(self, guid, t, dead=False):
        self.end_channel(guid, t)
        slot = self.slot.pop(guid, None)
        self.pending_add.pop(guid, None)
        self.open.pop(guid, None)
        if slot is not None:
            event = {"t": t, "e": "REMOVE", "u": slot}
            if dead:
                event["dead"] = True
            self.events.append(event)
            self.free.append(slot)

    def expire(self, t):
        for guid, seen in list(self.last_seen.items()):
            if t - seen > LINGER:
                self.remove(guid, t)
                self.last_seen.pop(guid, None)

    def cast(self, kind, guid, spell, t):
        slot = self.slot.get(guid)
        if slot is None:
            return
        event = {"t": t, "e": kind, "u": slot, "spell": spell}
        if kind == "START":
            flag = self.kickable.get((npc_of(guid), spell))
            if flag is None:
                flag = self.kickable.get((None, spell))
            if flag is not None:
                event["kick"] = flag
        self.events.append(event)
        return event


def levels_in(path):
    """Creature guid -> level, from every SPELL_CAST_SUCCESS in the file.

    Read ahead of the event pass so a creature has its level from its very
    first appearance, the way the game does.
    """
    levels = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if "SPELL_CAST_SUCCESS,Creature-" not in line:
                continue
            try:
                p = next(csv.reader([line.split("  ", 1)[1]]))
                levels.setdefault(p[1], (int(p[LEVEL_INDEX]), int(p[POWER_INDEX])))
            except (ValueError, IndexError, StopIteration):
                continue
    return levels


def kickable_from(mdt_path):
    """(npc, spell) -> interruptible, plus (None, spell) as the any-creature view."""
    if not mdt_path:
        return {}
    import json
    flags = {}
    for npc, entry in json.load(io.open(mdt_path, encoding="utf-8")).items():
        for spell, interruptible in (entry.get("spells") or {}).items():
            flags[(int(npc), int(spell))] = bool(interruptible)
            flags.setdefault((None, int(spell)), bool(interruptible))
    return flags


def scan(path, runs, kickable, channels=None):
    channels = channels or {}
    run = None
    in_boss = False
    known = levels_in(path)
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if "CHALLENGE_MODE_" in line:
                if run:
                    run.end_channels(stamp(line.split("  ", 1)[0]) - run.t0)
                    runs.append(run)
                    run = None
                if "CHALLENGE_MODE_START" in line:
                    head, rest = line.split("  ", 1)
                    p = next(csv.reader([rest]))
                    run = Run(int(p[2]), p[1], stamp(head))
                    run.level = known
                    run.kickable = kickable
                    run.lengths = channels
                continue
            if run is None or "Creature-" not in line and "ENCOUNTER_" not in line:
                continue
            try:
                head, rest = line.split("  ", 1)
                p = next(csv.reader([rest]))
                t = round(stamp(head) - run.t0, 3)
            except Exception:
                continue
            ev = p[0]
            if ev == "ENCOUNTER_START":
                in_boss = True
                run.events.append({"t": t, "e": "ENC", "on": True})
                continue
            if ev == "ENCOUNTER_END":
                in_boss = False
                run.events.append({"t": t, "e": "ENC", "on": False})
                continue
            if in_boss:
                continue

            src, dst = p[1], p[5]
            if ev == "UNIT_DIED" and dst.startswith("Creature-"):
                run.remove(dst, t, dead=True)
                continue
            if not src.startswith("Creature-"):
                if ev == "SPELL_INTERRUPT" and dst.startswith("Creature-"):
                    try:
                        spell = int(p[12])
                    except (ValueError, IndexError):
                        continue
                    if run.open.get(dst, (None,))[0] == spell:
                        run.open.pop(dst, None)
                        run.cast("KICK", dst, spell, t)
                continue
            try:
                if not int(p[3], 16) & HOSTILE:
                    continue
            except ValueError:
                continue
            if ev == "SPELL_CAST_SUCCESS":
                run.touch(src, t)
                try:
                    spell = int(p[9])
                except (ValueError, IndexError):
                    continue
                opened = run.open.get(src)
                if opened and opened[0] == spell:
                    run.open.pop(src, None)
                    # The game says at the start whether the cast has a target;
                    # the log only names it when the cast lands.
                    if opened[2] is not None:
                        opened[2]["target"] = dst not in ("0000000000000000", "")
                    run.cast("STOP", src, spell, t)
                elif not opened and spell in channels:
                    run.end_channel(src, t)
                    run.channel[src] = {"spell": spell, "name": p[10], "t": t, "removed": None, "tick": None}
                    run.cast("CHAN", src, spell, t)
                else:
                    run.channel_tick(src, p[10], t)
            elif ev == "SPELL_AURA_REMOVED":
                try:
                    spell = int(p[9])
                except (ValueError, IndexError):
                    continue
                running = run.channel.get(src)
                if running and running["spell"] == spell and running["removed"] is None:
                    running["removed"] = t
            elif ev == "SPELL_CAST_START":
                run.touch(src, t)
                run.end_channel(src, t)
                try:
                    spell = int(p[9])
                except (ValueError, IndexError):
                    continue
                if src in run.open:
                    run.cast("FAIL", src, run.open[src][0], t)
                run.open[src] = (spell, t, run.cast("START", src, spell, t))
            elif ev == "SPELL_CAST_FAILED":
                open_spell = run.open.pop(src, (None,))[0]
                if open_spell is not None:
                    run.cast("FAIL", src, open_spell, t)
            elif ev in ("SPELL_DAMAGE", "SWING_DAMAGE", "SPELL_AURA_APPLIED"):
                run.touch(src, t)
                if ev == "SPELL_DAMAGE":
                    run.channel_tick(src, p[10], t)
            elif ev in TICKS:
                run.channel_tick(src, p[10], t)
    if run:
        run.end_channels()
        runs.append(run)


def write(runs, out_path):
    out = io.open(out_path, "w", encoding="utf-8", newline="\n")
    out.write("-- Generated by tools/replay_extract.py from combat logs. Do not edit.\n")
    out.write("CastAheadReplay = {\n")
    for run in runs:
        run.events.sort(key=lambda e: e["t"])
        out.write('    { instance = %d, name = "%s", events = {\n'
                  % (run.instance, run.name.replace('"', "'")))
        for e in run.events:
            fields = ["t = %.3f" % e["t"], 'e = "%s"' % e["e"]]
            for key in ("u", "level", "power", "npc", "spell"):
                if key in e:
                    fields.append("%s = %d" % (key, e[key]))
            for key in ("on", "kick", "dead", "target", "full"):
                if key in e:
                    fields.append("%s = %s" % (key, "true" if e[key] else "false"))
            out.write("        { %s },\n" % ", ".join(fields))
        out.write("    } },\n")
    out.write("}\n")
    out.close()


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    args = sys.argv[1:]
    channels = {}
    for arg in [a for a in args if a.startswith("--channels=")]:
        args.remove(arg)
        for spell, times in json.load(io.open(arg.split("=", 1)[1], encoding="utf-8")).items():
            if times.get("channel") and not times.get("cast"):
                channels[int(spell)] = float(times["channel"])
    mdt_path = None
    if args[-1].endswith(".json"):
        mdt_path = args.pop()
    out_path = args.pop()
    files = []
    for pattern in args:
        files.extend(sorted(glob.glob(pattern)))
    kickable = kickable_from(mdt_path)
    runs = []
    for path in files:
        print("reading %s" % path)
        scan(path, runs, kickable, channels)
    write(runs, out_path)
    casts = sum(1 for r in runs for e in r.events if e["e"] == "STOP")
    print("%d runs, %d completed casts -> %s" % (len(runs), casts, out_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
