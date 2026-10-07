import json
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).parent
MOB = "Creature-0-4240-2521-17579-190206-0001C697CE"
OTHER = "Creature-0-4240-2521-17579-190206-0001C697CF"


def line(stamp, *fields):
    return "10/7/2026 22:%s  %s" % (stamp, ",".join(fields))


def channel(stamp, event, who=MOB):
    return line(stamp, event, who, '"Ashseer Flamelasher"', "0xa48", "0x0", who, '"Ashseer Flamelasher"',
                "0xa48", "0x0", "385536", '"Flaming Barrage"', "0x4", "BUFF")


def test_a_channel_keeps_how_long_it_lasted_and_a_death_does_not_count_as_a_stop(tmp_path):
    log = [
        line("05:00.000", "CHALLENGE_MODE_START", '"Ruby Life Pools"', "2521", "399", "12", "[10]"),
        channel("05:32.143", "SPELL_CAST_SUCCESS"),
        channel("05:33.550", "SPELL_AURA_REMOVED"),
        channel("06:10.000", "SPELL_CAST_SUCCESS"),
        channel("06:20.000", "SPELL_AURA_REMOVED"),
        channel("07:00.000", "SPELL_CAST_SUCCESS", OTHER),
        channel("07:03.000", "SPELL_AURA_REMOVED", OTHER),
        line("07:03.100", "UNIT_DIED", "0000000000000000", "nil", "0x80000000", "0x80000000", OTHER,
             '"Ashseer Flamelasher"', "0xa48", "0x0", "0"),
        line("09:00.000", "CHALLENGE_MODE_END", "2521", "1", "12", "600000"),
    ]
    path = tmp_path / "WoWCombatLog-1.txt"
    path.write_text("\n".join(log) + "\n", encoding="utf-8")
    out = tmp_path / "casts.json"
    subprocess.run([sys.executable, str(HERE / "collect.py"), str(path), str(out)], check=True, capture_output=True)
    rec = json.loads(out.read_text(encoding="utf-8"))["2521|Ruby Life Pools"]["190206"]["385536"]
    assert rec["chan"] == [1.41, 10.0]
