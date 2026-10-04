import pathlib

from audit import coverage_report, issue_report, load_data_rows, owner_audit, parse_export, parse_line, read_journal

HERE = pathlib.Path(__file__).parent
SAMPLE = (HERE / "fixtures" / "export_sample.txt").read_text(encoding="utf-8")
ROWS = {100: {"name": "Big", "mob": "Caster", "cast": 3.0, "channel": False, "npc": 1}}


def test_the_export_written_by_the_addon_parses_completely():
    report = parse_export(SAMPLE)
    assert report.complete
    assert report.header["instance"] == "1877"
    assert [l.fields[0] for l in report.lines if l.kind == "MARK"] == ["1", "2", "3"]


def test_a_lost_tail_is_reported_not_taken_as_complete():
    report = parse_export("\n".join(SAMPLE.splitlines()[:-3]))
    assert not report.complete
    assert any("footer" in p for p in report.problems)


def test_a_missing_line_is_caught_by_the_footer_count():
    lines = SAMPLE.splitlines()
    report = parse_export("\n".join(lines[:-2] + [lines[-1]]))
    assert not report.complete


def test_channel_rows_and_dungeons_are_read_from_data_lua():
    data = ('CastAheadData = {\n    [1877] = { name = "T",\n'
            '        { spell = 100, npc = 1, mob = "A", name = "Big", cast = 3.0, cd = { 20.0 }, first = 5.0, n = 9, firstN = 9, level = 91, offset = 0.0, },\n'
            '        { spell = 101, npc = 1, mob = "A", name = "Beam", cast = 6.0, cd = { 30.0 }, first = nil, n = 9, firstN = 0, level = 91, offset = nil, channel = true, },\n'
            '    },\n    [2923] = { name = "V",\n'
            '        { spell = 100, npc = 9, mob = "B", name = "Other", cast = 2.0, cd = { 10.0 }, first = 1.0, n = 9, firstN = 9, level = 91, offset = 0.0, },\n'
            '    },\n}\n')
    rows = load_data_rows(data, 1877)
    assert rows[101]["channel"] and not rows[100]["channel"] and rows[100]["name"] == "Big"
    assert load_data_rows(data, 2923)[100]["name"] == "Other"


def test_a_paste_with_its_newlines_collapsed_still_parses():
    report = parse_export(" ".join(SAMPLE.splitlines()))
    assert report.complete and len(report.lines) == len(parse_export(SAMPLE).lines)


def test_rows_are_read_from_data_lua():
    rows = load_data_rows('CastAheadData = {\n    [1877] = { name = "T",\n        { spell = 100, npc = 1, mob = "Caster", name = "Big", cast = 3.0, cd = { 20.0 }, first = 5.0, n = 9, firstN = 9, level = 91, offset = 0.0, },\n    },\n}\n')
    assert rows[100]["name"] == "Big" and rows[100]["cast"] == 3.0 and not rows[100]["channel"]


def test_the_issue_report_walks_the_marked_mob_with_its_note():
    text = issue_report(parse_export(SAMPLE), ROWS)
    assert "Mark 1" in text and "tank buster was called swap" in text
    assert "Mark 2 at 00:23.0 on 1.1" in text
    assert "stop after 3000 ms -> Big (100)" in text
    assert "rows of that length: Big (100)" in text


def test_the_owner_audit_lines_up_with_the_log_and_scores_calls(tmp_path):
    mob = "Creature-0-1-2-3-200-0000000001"
    log = []
    for i in range(5):
        log.append('10/3/2026 12:00:%02d.000  SPELL_CAST_SUCCESS,Player-1-1,"Me",0x511,0x0,0000000000000000,nil,0x0,0x0,555,"Bolt",0x1' % (10 + i))
    log.append('10/3/2026 12:00:20.000  SPELL_DAMAGE,Player-1-1,"Me",0x511,0x0,%s,"Mob",0xa48,0x0,555,"Bolt",0x1' % mob)
    log.append('10/3/2026 12:00:22.000  SPELL_CAST_START,%s,"Mob",0xa48,0x0,0000000000000000,nil,0x0,0x0,100,"Big",0x1' % mob)
    log.append('10/3/2026 12:00:42.500  SPELL_CAST_START,%s,"Mob",0xa48,0x0,0000000000000000,nil,0x0,0x0,100,"Big",0x1' % mob)
    for k in range(3):
        log.insert(0, '10/3/2026 11:%02d:00.000  SPELL_CAST_SUCCESS,Player-1-1,"Me",0x511,0x0,0000000000000000,nil,0x0,0x0,555,"Bolt",0x1' % (10 * k))
    log.append('10/3/2026 12:00:11.000  SPELL_CAST_SUCCESS,Player-1-2,"Friend",0x512,0x0,0000000000000000,nil,0x0,0x0,555,"Bolt",0x1')
    path = tmp_path / "log.txt"
    path.write_text("\n".join(log) + "\n", encoding="utf-8")
    journal = [parse_line(s) for s in (
        "0|SELF|-|555", "1000|SELF|-|555", "2000|SELF|-|555", "3000|SELF|-|555", "4000|SELF|-|555",
        "11000|ENGAGE|1.1",
        "12000|START|1.1|0|100|AOE|100|0",
        "15000|PRED|1.1|100|32000|0|repeat",
        "32500|START|1.1|0|101|TANK|101|1",
    )]
    text = owner_audit(journal, str(path), {100: {"name": "Big", "cast": 3.0, "channel": False}})
    assert "start claims: 1 right, 1 wrong" in text
    assert "claimed 101, really Big (100)" in text
    assert "Big (100): n 1, median +0.5" in text
    assert "mob 1.1: +1.0" in text


def test_the_journal_is_read_back_from_saved_variables():
    sv = 'CastAheadDB = {\n["journal"] = {\n["keys"] = {\n{\n["lines"] = {\n"0|PULL|-|in",\n"1500|START|1.1|0|100|AOE|100|1",\n},\n},\n},\n},\n}\n'
    lines = read_journal(sv)
    assert [l.kind for l in lines] == ["PULL", "START"] and lines[1].mob == "1.1"


def test_coverage_splits_the_dungeon_into_missed_not_cast_and_shown(tmp_path):
    data = ('CastAheadData = {\n    [1877] = { name = "T",\n'
            '        { spell = 100, npc = 1, mob = "A", name = "Big", cast = 3.0, cd = { 20.0 }, first = 5.0, n = 9, firstN = 9, level = 91, offset = 0.0, },\n'
            '        { spell = 700, npc = 7, mob = "G", name = "Beam", cast = 2.0, cd = { 30.0 }, first = 6.0, n = 9, firstN = 9, level = 91, offset = 0.0, },\n'
            '        { spell = 610, npc = 11, mob = "D", name = "Drain", cast = 6.0, cd = { 22.0 }, first = 8.0, n = 9, firstN = 9, level = 91, offset = 0.0, channel = true, },\n'
            '    },\n}\n')
    sv = ('CastAheadDB = {\n["journal"] = {\n["keys"] = {\n{\n["instance"] = 1877,\n["level"] = 12,\n'
          '["lines"] = {\n"1500|START|1.1|0|100|AOE|100|1",\n"3000|STOP|1.1|0|3000|100|AOE",\n"9000|START|2.2|0|-|-||0",\n},\n},\n},\n},\n}\n')
    mob, golem = "Creature-0-1-2-3-1-0000000001", "Creature-0-1-2-3-7-0000000002"
    log = [
        '10/3/2026 12:00:00.000  CHALLENGE_MODE_START,"T",1877,1,12,[10]',
        '10/3/2026 12:00:01.500  SPELL_CAST_START,%s,"A",0xa48,0x0,0000000000000000,nil,0x0,0x0,100,"Big",0x1' % mob,
        '10/3/2026 12:00:09.000  SPELL_CAST_START,%s,"G",0xa48,0x0,0000000000000000,nil,0x0,0x0,700,"Beam",0x1' % golem,
        '10/3/2026 12:10:00.000  CHALLENGE_MODE_END,1877,1,12,600000',
        '10/3/2026 12:20:00.000  SPELL_CAST_START,%s,"G",0xa48,0x0,0000000000000000,nil,0x0,0x0,610,"Drain",0x1' % golem,
    ]
    path = tmp_path / "log.txt"
    path.write_text("\n".join(log) + "\n", encoding="utf-8")
    text = coverage_report(sv, [str(path)], data, {700: "DODGE"})
    missed = text.split("Missed")[1].split("Not cast")[0]
    not_cast = text.split("Not cast")[1].split("Shown")[0]
    assert "Beam (700) DODGE, cast 1" in missed and "Big" not in missed
    assert "Drain (610)" in not_cast
    assert "Big (100)" in text.split("Shown")[1]
