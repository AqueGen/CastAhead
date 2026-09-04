import sys, os, csv, json, glob
from collections import defaultdict

HOSTILE = 0x40
DMG_EVENTS = ("_DAMAGE", "_MISSED", "_HEAL", "_AURA_APPLIED")
# Damage landing this soon after a cast finished is taken to be that cast's
# payload. Long enough for a travel time, short enough to miss the next one.
# Known ceiling: a channel ticks for its whole length, so anything longer than
# this window under-counts its hits and damage. The numbers still rank casts
# against each other, which is all they are used for.
PAYLOAD_WINDOW = 2.0
# A mob idle this long has reset; its next pull is a fresh engage.
ENGAGE_RESET = 30.0
# Advanced-logging column offsets in SPELL_DAMAGE.
DMG_MAXHP, DMG_AMOUNT, DMG_ABSORBED = 15, 31, 37


def ts(s):
    t = s.split(" ")[1]
    h, m, sec = t.split(":")
    return int(h) * 3600 + int(m) * 60 + float(sec)


# out[dungeon][npcid][spellid] = {"cast":[], "iv":[], "first":[], "name":.., "mob":..}
def newrec():
    # "runs" holds one interval sequence per mob spawn, in cast order, so the
    # generator can rebuild a rotation like {4.8, 4.8, 8.7} instead of averaging
    # it into a single meaningless number.
    # "hits"/"dmg" measure what the cast did to the group - how many players it
    # landed on and for how much - which is what decides whether it deserves a
    # defensive. "kicked" counts real interrupts seen on it.
    # "starts" vs len("cast") is how often a cast never finished; subtract the
    # kicks and what is left was stopped some other way - a stun or other
    # control. That is the difference between "kick this" and "CC this".
    # "offset" is the delay from a spawn's FIRST cast of any spell to this
    # spell's first cast. Engage time is a poor anchor - a mob may still be
    # running in - but once it starts acting the order tends to hold.
    return {"cast": [], "iv": [], "runs": {}, "first": [], "offset": [],
            "name": "", "mob": "", "hits": [], "dmg": [], "kicked": 0,
            "starts": 0, "boss": False}


out = defaultdict(lambda: defaultdict(lambda: defaultdict(newrec)))


def scan(path):
    cur = None
    engaged = {}
    open_cast = {}
    last_start = {}
    completed = set()
    seen_first = {}     # guid -> spells whose opening delay is already recorded
    breaks = {}         # (guid, spell) -> how many times its sequence was broken
    last_seen = {}      # guid -> last time it did anything
    acted_at = {}       # guid -> when this spawn first cast anything
    pending = {}        # caster guid -> what its last finished cast has hit
    in_encounter = False  # inside a boss fight: those casts are not trash

    def flush(guid):
        """Book a finished cast's damage against the spell that caused it."""
        row = pending.pop(guid, None)
        if not row or not row["targets"]:
            return
        row["rec"]["hits"].append(len(row["targets"]))
        row["rec"]["dmg"].append(round(max(row["targets"].values()), 3))

    def flush_all():
        for guid in list(pending):
            flush(guid)

    def run_for(rec, key):
        """The interval sequence currently being recorded for this caster.

        A cast that never completed leaves no interval, and appending across
        that hole would slide every later interval one rotation slot to the
        left. Each break therefore starts a fresh sequence.
        """
        return rec["runs"].setdefault("%s#%d" % (key[0], breaks.get(key, 0)), [])

    def note_opening(rec, guid, spellid, t):
        """Record when this spawn first used this spell, once per spawn.

        Both a cast's START and a pure channel's SUCCESS come through here: a
        channel has no START to anchor on, so its SUCCESS is the anchor, the
        same one its intervals are measured from.
        """
        if spellid in seen_first.get(guid, ()):
            return
        seen_first.setdefault(guid, set()).add(spellid)
        if guid in engaged:
            d = round(t - engaged[guid], 1)
            if -2 <= d <= 60:
                rec["first"].append(d)
        if guid in acted_at:
            rec["offset"].append(round(t - acted_at[guid], 1))
        else:
            acted_at[guid] = t
            rec["offset"].append(0.0)
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if "ENCOUNTER_" in line[:60]:
                # Anything cast between these belongs to a boss encounter, and
                # boss spells have no business competing to identify trash.
                if "ENCOUNTER_START" in line:
                    in_encounter = True
                elif "ENCOUNTER_END" in line:
                    in_encounter = False
                continue
            if "CHALLENGE_MODE_" in line:
                if "CHALLENGE_MODE_START" in line:
                    # CHALLENGE_MODE_START,"zone",instanceID,challengeModeID,level,[affixes]
                    f2 = line.split("CHALLENGE_MODE_START,")[1].split(",")
                    cur = "%s|%s" % (f2[1].strip(), f2[0].strip('"'))
                    engaged.clear()
                    open_cast.clear()
                    last_start.clear()
                    completed.clear()
                    breaks.clear()
                    seen_first.clear()
                    last_seen.clear()
                    acted_at.clear()
                    pending.clear()
                    in_encounter = False
                else:
                    flush_all()
                    cur = None
                continue
            if cur is None or "Creature-" not in line:
                continue
            iscast = "SPELL_CAST_" in line
            isdmg = any(e in line for e in DMG_EVENTS)
            iskick = "SPELL_INTERRUPT" in line
            if not iscast and not isdmg and not iskick:
                continue
            try:
                stamp, rest = line.split("  ", 1)
                # Names are quoted and may contain commas ("Zul, Reborn"), so a
                # plain split silently shifts every column after them.
                p = next(csv.reader([rest]))
                ev = p[0]
                t = ts(stamp)
            except Exception:
                continue
            if isdmg:
                for gi, fi in ((1, 3), (5, 7)):
                    try:
                        g = p[gi]
                        if not g.startswith("Creature-") or not (int(p[fi], 16) & HOSTILE):
                            continue
                        if g not in engaged or t - last_seen.get(g, t) > ENGAGE_RESET:
                            engaged[g] = t
                            seen_first.pop(g, None)
                        last_seen[g] = t
                    except Exception:
                        pass
                # What a cast threw at the group, as a share of the victim's own
                # max health. Absorbs count: a shielded hit was still a hit that
                # size, and dropping it would mark tank busters harmless.
                if ev == "SPELL_DAMAGE" and p[1] in pending and p[5].startswith("Player-"):
                    row = pending[p[1]]
                    if t - row["t"] <= PAYLOAD_WINDOW:
                        try:
                            max_hp = int(p[DMG_MAXHP])
                            taken = int(p[DMG_AMOUNT]) + int(p[DMG_ABSORBED])
                            if max_hp > 0:
                                share = taken / max_hp
                                row["targets"][p[5]] = max(row["targets"].get(p[5], 0.0), share)
                        except (ValueError, IndexError):
                            pass
                    else:
                        flush(p[1])
                continue
            if ev == "SPELL_INTERRUPT":
                # p[12] is the spell that got kicked, on the mob in p[5].
                try:
                    if p[5].startswith("Creature-"):
                        kicked_npc = int(p[5].split("-")[5])
                        out[cur][kicked_npc][int(p[12])]["kicked"] += 1
                except (ValueError, IndexError):
                    pass
                continue
            if ev not in ("SPELL_CAST_START", "SPELL_CAST_SUCCESS"):
                continue
            try:
                guid = p[1]
                if not guid.startswith("Creature-"):
                    continue
                if not (int(p[3], 16) & HOSTILE):
                    continue
                mob = p[2].strip('"')
                spellid = int(p[9])
                spellname = p[10].strip('"')
            except Exception:
                continue
            npcid = int(guid.split("-")[5])
            rec = out[cur][npcid][spellid]
            rec["name"] = spellname
            rec["mob"] = mob
            if in_encounter:
                rec["boss"] = True
            key = (guid, spellid)
            if ev == "SPELL_CAST_START":
                open_cast[key] = t
                rec["starts"] += 1
                note_opening(rec, guid, spellid, t)
                # start-to-start interval, only across a cast that actually completed
                prev = last_start.get(key)
                if prev is not None:
                    if key in completed:
                        gap = round(t - prev, 1)
                        rec["iv"].append(gap)
                        run_for(rec, key).append(gap)
                    else:
                        # Previous attempt never finished - the gap across it is
                        # not a cooldown, so the rotation restarts here.
                        breaks[key] = breaks.get(key, 0) + 1
                last_start[key] = t
                completed.discard(key)
            else:
                st = open_cast.pop(key, None)
                if st is not None:
                    rec["cast"].append(round(t - st, 2))
                else:
                    # instant cast / channel: no START, treat SUCCESS as the anchor
                    # here too, or a pure channel would carry no opening delay
                    # and no order at all - and its `first`-less generated row
                    # would then shadow the curated Extra row that has one.
                    note_opening(rec, guid, spellid, t)
                    prev = last_start.get(key)
                    if prev is not None and key in completed:
                        gap = round(t - prev, 1)
                        rec["iv"].append(gap)
                        run_for(rec, key).append(gap)
                    last_start[key] = t
                    rec["cast"].append(0.0)
                completed.add(key)
                flush(guid)
                pending[guid] = {"rec": rec, "t": t, "targets": {}}
    # End of file: whatever damage is still booked would otherwise be dropped.
    flush_all()


logs = sorted(glob.glob(sys.argv[1]))
for i, p in enumerate(logs):
    sys.stderr.write("[%d/%d] %s %dMB\n" % (i + 1, len(logs), os.path.basename(p), os.path.getsize(p) // 1024 // 1024))
    sys.stderr.flush()
    scan(p)


def plain(d):
    if isinstance(d, dict):
        return {str(k): plain(v) for k, v in d.items()}
    return d


json.dump(plain(out), open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
sys.stderr.write("done\n")
