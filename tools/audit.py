"""Read Cast Ahead key journals and wrong-call reports, and check them against the data and the combat log.

    python tools/audit.py issue <export.txt> [--data Data.lua]
    python tools/audit.py owner <SavedVariables CastAhead.lua> <combat log> [--key N] [--data Data.lua] [--out DIR]
    python tools/audit.py coverage <SavedVariables CastAhead.lua> <combat log> [...] [--data Data.lua] [--out DIR]
"""
import argparse
import csv
import datetime
import pathlib
import re
import statistics
import sys
from dataclasses import dataclass, field

HEADER = re.compile(r"^CastAhead-Report (\d+) (.*)$")
FOOTER = re.compile(r"^CastAhead-Report end lines=(\d+)$")
ROW = re.compile(r'\{ spell = (\d+), npc = (\d+), mob = "([^"]*)", name = "([^"]*)", cast = ([\d.]+),(.*)\},\s*$')
DUNGEON = re.compile(r'^\s*\[(\d+)\] = \{ name = ')
RECORD = re.compile(r"\s+(?=\d+\|[A-Z]+\||# mark |CastAhead-Report end)")
ANCHOR_BIN_MS = 250
AFFILIATION_MINE = 0x1
LENGTH_SLACK = 0.25


@dataclass
class Line:
    t: int
    kind: str
    mob: str
    fields: list


@dataclass
class Report:
    header: dict = field(default_factory=dict)
    summaries: list = field(default_factory=list)
    lines: list = field(default_factory=list)
    complete: bool = False
    problems: list = field(default_factory=list)


def parse_line(text):
    parts = text.split("|")
    return Line(int(parts[0]), parts[1], parts[2], parts[3:] + [""] * 6)


def parse_export(text):
    report = Report()
    text = RECORD.sub("\n", text.replace("^", "|"))
    rows = [r.strip() for r in text.splitlines() if r.strip()]
    if not rows or not HEADER.match(rows[0]):
        report.problems.append("no CastAhead-Report header")
        return report
    version, rest = HEADER.match(rows[0]).groups()
    report.header = dict(kv.split("=", 1) for kv in rest.split() if "=" in kv)
    report.header["format"] = version
    footer = FOOTER.match(rows[-1])
    for row in (rows[1:-1] if footer else rows[1:]):
        if row.startswith("# ") or re.match(r"^mark \d+ at ", row):
            report.summaries.append(row[2:] if row.startswith("# ") else row)
        elif re.match(r"^\d+\|", row):
            report.lines.append(parse_line(row))
        else:
            report.problems.append("unreadable line: " + row[:60])
    if not footer:
        report.problems.append("footer missing - the paste was cut short")
    elif int(footer.group(1)) != len(report.lines):
        report.problems.append("footer says %s lines, %d arrived" % (footer.group(1), len(report.lines)))
    if "truncated" in report.header:
        report.problems.append("the journal hit its line cap at %s ms" % report.header["truncated"])
    if "droppedMarks" in report.header:
        report.problems.append("the oldest %s marks were left out to fit the size limit" % report.header["droppedMarks"])
    if "droppedLines" in report.header:
        report.problems.append("the oldest %s lines were left out to fit the size limit" % report.header["droppedLines"])
    report.complete = not any(p.startswith(("no CastAhead", "footer", "unreadable")) for p in report.problems)
    return report


def load_data_rows(text, instance=None):
    rows, current = {}, None
    for line in text.splitlines():
        d = DUNGEON.match(line)
        if d:
            current = d.group(1)
            continue
        m = ROW.search(line)
        if not m or (instance is not None and current != str(instance)):
            continue
        rows.setdefault(int(m.group(1)), {"npc": int(m.group(2)), "mob": m.group(3), "name": m.group(4),
                                          "cast": float(m.group(5)), "channel": "channel = true" in m.group(6)})
    return rows


def name(rows, spell):
    try:
        row = rows.get(int(spell))
    except (TypeError, ValueError):
        return str(spell)
    return "%s (%s)" % (row["name"], spell) if row else str(spell)


def names(rows, ids):
    return ", ".join(name(rows, s) for s in ids.split(",") if s) or "none"


def clock(ms):
    ms = int(ms)
    return "%02d:%04.1f" % (ms // 60000, (ms % 60000) / 1000)


def fitting(rows, measured_ms, channel):
    seconds = measured_ms / 1000
    return [s for s, r in rows.items() if r["channel"] == channel and abs(r["cast"] - seconds) <= LENGTH_SLACK]


def mob_history(lines, mob, before_t):
    return [l for l in lines if l.mob == mob and l.t <= before_t and l.kind in ("START", "STEP", "STOP", "CUT", "LOCK", "PLATE", "ENGAGE")]


def issue_report(report, rows):
    h = report.header
    out = ["## Cast Ahead report - instance %s, level %s, addon %s, data %s, role %s" % (
        h.get("instance"), h.get("level"), h.get("addon"), h.get("data"), h.get("role"))]
    if report.problems:
        out.append("Problems: " + "; ".join(report.problems))
    notes = {}
    for l in report.lines:
        if l.kind == "NOTE":
            notes.setdefault(l.fields[0], []).append(l.fields[1] if len(l.fields) > 1 else "")
    for i, l in enumerate(report.lines):
        if l.kind != "MARK":
            continue
        n, selected = l.fields[0], l.fields[1]
        out.append("\n### Mark %s at %s on %s - note: %s" % (n, clock(l.t), selected, " / ".join(notes.get(n, [])) or "-"))
        snaps = []
        for s in report.lines[i + 1:]:
            if s.kind != "SNAP" or s.t != l.t:
                break
            snaps.append(s)
        focus = [s for s in snaps if selected == "-" or s.mob == selected] or snaps
        for s in focus:
            state, claimed, call, cands = s.fields[0], s.fields[1], s.fields[2], s.fields[3]
            out.append("- mob %s (%s): last %s, call %s%s" % (
                s.mob, state, name(rows, claimed), call, "; casting candidates " + names(rows, cands) if cands else ""))
            for h_line in mob_history(report.lines, s.mob, l.t)[-20:]:
                if h_line.kind == "STOP":
                    ms = int(h_line.fields[1]) if h_line.fields[1].isdigit() else None
                    fits = fitting(rows, ms, h_line.fields[0] == "1") if ms is not None else []
                    out.append("  - %s stop after %s ms -> %s, call %s; rows of that length: %s" % (
                        clock(h_line.t), h_line.fields[1], names(rows, h_line.fields[2]), h_line.fields[3],
                        ", ".join(name(rows, f) for f in fits) or "none"))
                elif h_line.kind == "STEP":
                    out.append("    - step %s leaves %s" % (h_line.fields[0], names(rows, h_line.fields[1])))
                elif h_line.kind == "START":
                    out.append("  - %s start: claimed %s, call %s, target %s" % (
                        clock(h_line.t), name(rows, h_line.fields[1]), h_line.fields[2], h_line.fields[4]))
                elif h_line.kind == "CUT":
                    out.append("  - %s cut short after %s ms" % (clock(h_line.t), h_line.fields[0]))
                elif h_line.kind == "LOCK":
                    out.append("  - %s resolved as creature %s by %s" % (clock(h_line.t), h_line.fields[0], h_line.fields[1]))
    return "\n".join(out)


def read_journal(sv_text, index=None):
    keys = [[parse_line(s) for s in re.findall(r'"(\d+\|[A-Z]+\|[^"]*)"', block.group(1))]
            for block in re.finditer(r'\["lines"\] = \{(.*?)\n\s*\},', sv_text, re.S)]
    if not keys:
        return []
    return keys[index] if index is not None else keys[-1]


def log_events(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            stamp, _, rest = raw.partition("  ")
            if not rest:
                continue
            m = re.match(r"(\d+)/(\d+)/(\d+) (\d+):(\d+):(\d+)\.(\d+)", stamp.strip())
            if not m:
                continue
            mo, d, y, hh, mm, ss, frac = m.groups()
            when = datetime.datetime(int(y), int(mo), int(d), int(hh), int(mm), int(ss), int(frac.ljust(6, "0")[:6]))
            yield when.timestamp() * 1000, next(csv.reader([rest]))


def owner_audit(lines, log_path, rows):
    selfs = [l for l in lines if l.kind == "SELF"]
    player_casts, creature_starts, first_hit = [], [], {}
    for ms, p in log_events(log_path):
        if p[0] == "SPELL_CAST_SUCCESS" and p[1].startswith("Player-") and int(p[3], 16) & AFFILIATION_MINE:
            player_casts.append((ms, p[9]))
        elif p[0] == "SPELL_CAST_START" and p[1].startswith("Creature-"):
            creature_starts.append((ms, p[1], int(p[9])))
        elif p[0].endswith("_DAMAGE") and len(p) > 5 and p[5].startswith("Creature-"):
            first_hit.setdefault(p[5], ms)
    offsets = [ms - s.t for s in selfs for ms, spell in player_casts if spell == s.fields[0]]
    bins = {}
    for o in offsets:
        bins.setdefault(round(o / ANCHOR_BIN_MS), []).append(o)
    best = max(bins.values(), key=len, default=[])
    if len(best) < 5:
        return "Not enough player casts to line the journal up with the log (%d agree)." % len(best)
    base = statistics.median(best)
    out = ["## Owner audit", "clock offset agreed by %d of %d player casts" % (len(best), len(selfs))]
    right = wrong = 0
    guid_of = {}
    for start in (l for l in lines if l.kind == "START"):
        at = base + start.t
        truth = min(creature_starts, key=lambda c: abs(c[0] - at), default=None)
        if not truth or abs(truth[0] - at) > 400:
            continue
        guid_of.setdefault(start.mob, truth[1])
        claimed = start.fields[1]
        if claimed == "-":
            continue
        if int(claimed) == truth[2]:
            right += 1
        else:
            wrong += 1
            out.append("- %s mob %s: claimed %s, really %s" % (clock(start.t), start.mob, name(rows, claimed), name(rows, truth[2])))
    out.insert(2, "start claims: %d right, %d wrong" % (right, wrong))
    errors = {}
    for pred in (l for l in lines if l.kind == "PRED"):
        spell, due = int(pred.fields[0]), base + int(pred.fields[1])
        guid = guid_of.get(pred.mob)
        hits = [c for c in creature_starts if c[2] == spell and (guid is None or c[1] == guid) and abs(c[0] - due) <= 15000]
        if hits:
            real = min(hits, key=lambda c: abs(c[0] - due))
            errors.setdefault(spell, []).append((real[0] - due) / 1000)
    out.append("\n### Countdown error per spell (real start minus predicted, seconds)")
    for spell, errs in sorted(errors.items(), key=lambda kv: -statistics.median(abs(e) for e in kv[1])):
        out.append("- %s: n %d, median %+.1f, worst %+.1f" % (name(rows, spell), len(errs), statistics.median(errs), max(errs, key=abs)))
    out.append("\n### Engage seen by the addon minus first damage in the log (seconds)")
    for engage in (l for l in lines if l.kind == "ENGAGE"):
        guid = guid_of.get(engage.mob)
        if guid and guid in first_hit:
            out.append("- %s mob %s: %+.1f" % (clock(engage.t), engage.mob, (base + engage.t - first_hit[guid]) / 1000))
    return "\n".join(out)


SHOWN_FIELD = {"START": 1, "STOP": 2, "PRED": 0, "TL": 1}


LUA_TOKEN = re.compile(r'\s*(?:--[^\n]*|(\{|\}|=|,)|\[\s*("(?:[^"\\]|\\.)*"|-?[\d.]+)\s*\]'
                       r'|("(?:[^"\\]|\\.)*")|(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)|(true|false|nil)|([A-Za-z_]\w*))')


def lua_tokens(text):
    for m in LUA_TOKEN.finditer(text):
        punct, key, string, number, word, name_ = m.groups()
        if punct:
            yield ("p", punct)
        elif key is not None:
            yield ("k", lua_scalar(key))
        elif string is not None:
            yield ("v", lua_scalar(string))
        elif number is not None:
            yield ("v", float(number) if "." in number or "e" in number.lower() else int(number))
        elif word is not None:
            yield ("v", {"true": True, "false": False, "nil": None}[word])
        elif name_ is not None:
            yield ("n", name_)


def lua_scalar(text):
    if text.startswith('"'):
        return re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), text[1:-1])
    return float(text) if "." in text else int(text)


def lua_table(tokens):
    table, index = {}, 1
    for kind, value in tokens:
        if (kind, value) == ("p", "}"):
            return table
        if kind == "k":
            next(tokens)
            vkind, item = next(tokens)
            table[value] = lua_table(tokens) if (vkind, item) == ("p", "{") else item
        elif (kind, value) == ("p", "{"):
            table[index], index = lua_table(tokens), index + 1
        elif kind == "v":
            table[index], index = value, index + 1
    return table


def saved_variable(sv_text, name_):
    tokens = lua_tokens(sv_text)
    for kind, value in tokens:
        if (kind, value) == ("n", name_):
            next(tokens)
            next(tokens)
            return lua_table(tokens)
    return {}


def journal_keys(sv_text):
    keys = saved_variable(sv_text, "CastAheadDB").get("journal", {}).get("keys", {})
    out = []
    for i in sorted(k for k in keys if isinstance(k, int)):
        key = keys[i]
        lines = key.get("lines", {})
        out.append((key.get("instance"), int(key.get("level") or 0),
                    [parse_line(lines[j]) for j in sorted(k for k in lines if isinstance(k, int))]))
    return out


def shown_spells(lines):
    shown = {}
    for l in lines:
        index = SHOWN_FIELD.get(l.kind)
        if index is None or (l.kind == "TL" and l.fields[0] != "added"):
            continue
        value = l.fields[index]
        if value.isdigit():
            shown[int(value)] = shown.get(int(value), 0) + 1
    return shown


def key_windows(log_paths):
    windows = []
    for path in log_paths:
        open_key = None
        for ms, p in log_events(path):
            if p[0] == "CHALLENGE_MODE_START":
                open_key = (int(p[2]), int(p[4]), ms)
            elif p[0] == "CHALLENGE_MODE_END" and open_key:
                windows.append((open_key[0], open_key[1], open_key[2], ms, path))
                open_key = None
    return windows


def casts_in(window, spells):
    _, _, start, end, path = window
    counts = {}
    boss = False
    for ms, p in log_events(path):
        if p[0] in ("ENCOUNTER_START", "ENCOUNTER_END"):
            boss = p[0] == "ENCOUNTER_START"
        elif not boss and start <= ms <= end and p[0] in ("SPELL_CAST_START", "SPELL_CAST_SUCCESS") and p[1].startswith("Creature-"):
            spell = int(p[9])
            if spell in spells and (p[0] == "SPELL_CAST_START" or spells[spell]["channel"]):
                counts[spell] = counts.get(spell, 0) + 1
    return counts


def coverage_report(sv_text, log_paths, data_text, priority):
    windows = key_windows(log_paths)
    used, out = set(), ["# Cast Ahead coverage"]
    for n, (instance, level, lines) in enumerate(journal_keys(sv_text), 1):
        rows = load_data_rows(data_text, instance)
        if not rows or not level:
            continue
        match = next((w for w in windows if w[0] == instance and w[1] == level and w not in used), None)
        shown = shown_spells(lines)
        out.append("\n## Key %d: instance %s +%d%s" % (n, instance, level, "" if match else " (no matching key in the logs)"))
        if not match:
            continue
        used.add(match)
        cast = casts_in(match, rows)

        def entry(spell):
            return "- %s%s, cast %d, shown %d" % (name(rows, spell), " " + priority[spell] if spell in priority else "",
                                                cast.get(spell, 0), shown.get(spell, 0))
        missed = sorted((s for s in rows if cast.get(s) and not shown.get(s)), key=lambda s: (s not in priority, -cast[s]))
        idle = sorted(s for s in rows if not cast.get(s) and not shown.get(s))
        fine = sorted((s for s in rows if shown.get(s)), key=lambda s: -shown[s])
        out.append("### Missed - cast but never shown (%d)" % len(missed))
        out += [entry(s) for s in missed]
        out.append("### Not cast and not shown (%d)" % len(idle))
        out += [entry(s) for s in idle]
        out.append("### Shown (%d)" % len(fine))
        out += [entry(s) for s in fine]
    return "\n".join(out)


def read_priority(text):
    block = text.split("CastAheadPriority = {", 1)[-1].split("}", 1)[0]
    return {int(k): v for k, v in re.findall(r'\[(\d+)\] = "(\w+)"', block)}


def main(argv):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="mode", required=True)
    a = sub.add_parser("issue")
    a.add_argument("export")
    a.add_argument("--data", default=str(pathlib.Path(__file__).resolve().parent.parent / "Data.lua"))
    b = sub.add_parser("owner")
    b.add_argument("saved")
    b.add_argument("log")
    b.add_argument("--key", type=int)
    b.add_argument("--data", default=str(pathlib.Path(__file__).resolve().parent.parent / "Data.lua"))
    b.add_argument("--out")
    c = sub.add_parser("coverage")
    c.add_argument("saved")
    c.add_argument("logs", nargs="+")
    c.add_argument("--data", default=str(pathlib.Path(__file__).resolve().parent.parent / "Data.lua"))
    c.add_argument("--priority", default=str(pathlib.Path(__file__).resolve().parent.parent / "Priority.lua"))
    c.add_argument("--out")
    args = ap.parse_args(argv)
    data = pathlib.Path(args.data).read_text(encoding="utf-8")
    if args.mode == "coverage":
        text = coverage_report(pathlib.Path(args.saved).read_text(encoding="utf-8"), args.logs, data,
                               read_priority(pathlib.Path(args.priority).read_text(encoding="utf-8")))
        if args.out:
            target = pathlib.Path(args.out)
            target.mkdir(parents=True, exist_ok=True)
            target = target / (datetime.date.today().isoformat() + "-coverage.md")
            target.write_text(text, encoding="utf-8")
            print("wrote", target)
        else:
            print(text)
        return
    if args.mode == "issue":
        report = parse_export(pathlib.Path(args.export).read_text(encoding="utf-8"))
        print(issue_report(report, load_data_rows(data, report.header.get("instance"))))
        return
    rows = load_data_rows(data)
    lines = read_journal(pathlib.Path(args.saved).read_text(encoding="utf-8"), args.key)
    text = owner_audit(lines, args.log, rows)
    if args.out:
        target = pathlib.Path(args.out)
        target.mkdir(parents=True, exist_ok=True)
        target = target / (datetime.date.today().isoformat() + "-audit.md")
        target.write_text(text, encoding="utf-8")
        print("wrote", target)
    else:
        print(text)


if __name__ == "__main__":
    main(sys.argv[1:])
